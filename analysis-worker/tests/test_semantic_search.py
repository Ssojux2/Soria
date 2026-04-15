from __future__ import annotations

import math
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

ANALYSIS_WORKER_ROOT = Path(__file__).resolve().parents[1]
if str(ANALYSIS_WORKER_ROOT) not in sys.path:
    sys.path.insert(0, str(ANALYSIS_WORKER_ROOT))

import main as worker_main
import vectordb.chroma_store as chroma_store


class FakeCollection:
    def __init__(self, name: str) -> None:
        self.name = name
        self.records: dict[str, dict[str, object]] = {}

    def upsert(
        self,
        ids: list[str],
        embeddings: list[list[float]],
        metadatas: list[dict[str, object]],
        documents: list[str],
    ) -> None:
        for record_id, embedding, metadata, document in zip(ids, embeddings, metadatas, documents):
            self.records[record_id] = {
                "embedding": [float(value) for value in embedding],
                "metadata": dict(metadata),
                "document": document,
            }

    def delete(self, where: dict[str, object] | None = None) -> None:
        if where is None:
            self.records.clear()
            return

        doomed = [
            record_id
            for record_id, payload in self.records.items()
            if _matches_where(payload["metadata"], where)
        ]
        for record_id in doomed:
            self.records.pop(record_id, None)

    def query(
        self,
        query_embeddings: list[list[float]],
        n_results: int,
        where: dict[str, object] | None = None,
        include: list[str] | None = None,
    ) -> dict[str, list[list[object]]]:
        query_vector = query_embeddings[0]
        scored: list[tuple[float, dict[str, object]]] = []

        for payload in self.records.values():
            metadata = payload["metadata"]
            if not _matches_where(metadata, where):
                continue
            distance = _euclidean_distance(query_vector, payload["embedding"])
            scored.append((distance, metadata))

        scored.sort(key=lambda item: item[0])
        limited = scored[:n_results]
        return {
            "distances": [[distance for distance, _ in limited]],
            "metadatas": [[metadata for _, metadata in limited]],
        }

    def get(self, include: list[str] | None = None) -> dict[str, list[dict[str, object]]]:
        return {
            "metadatas": [payload["metadata"] for payload in self.records.values()],
        }

    def count(self) -> int:
        return len(self.records)


class FakePersistentClient:
    stores: dict[str, dict[str, FakeCollection]] = {}

    def __init__(self, path: str, settings: object | None = None) -> None:
        self.path = path
        self.collections = self.stores.setdefault(path, {})

    def get_or_create_collection(self, name: str) -> FakeCollection:
        return self.collections.setdefault(name, FakeCollection(name))

    def delete_collection(self, name: str) -> None:
        self.collections.pop(name, None)


class FakeSettings:
    def __init__(self, anonymized_telemetry: bool = False) -> None:
        self.anonymized_telemetry = anonymized_telemetry


def _euclidean_distance(lhs: list[float], rhs: list[float]) -> float:
    return math.sqrt(sum((float(a) - float(b)) ** 2 for a, b in zip(lhs, rhs)))


def _matches_where(metadata: dict[str, object], where: dict[str, object] | None) -> bool:
    if where is None:
        return True
    if "$and" in where:
        return all(_matches_where(metadata, clause) for clause in where["$and"])

    for key, condition in where.items():
        value = metadata.get(key)
        if not isinstance(condition, dict):
            return value == condition
        if "$eq" in condition and value != condition["$eq"]:
            return False
        if "$gte" in condition and float(value) < float(condition["$gte"]):
            return False
        if "$lte" in condition and float(value) > float(condition["$lte"]):
            return False
    return True


def _install_fake_chroma(monkeypatch: pytest.MonkeyPatch) -> None:
    FakePersistentClient.stores.clear()
    monkeypatch.setattr(
        chroma_store,
        "chromadb",
        SimpleNamespace(PersistentClient=FakePersistentClient),
    )
    monkeypatch.setattr(chroma_store, "Settings", FakeSettings)


def _make_track_metadata(track_id: str, file_path: str) -> dict[str, object]:
    return {
        "app_track_id": track_id,
        "file_path": file_path,
        "bpm": 124,
        "musical_key": "8A",
        "genre": "House",
        "duration_sec": 300,
    }


def _make_segments(track_id: str, vector_by_type: dict[str, list[float]]) -> list[dict[str, object]]:
    output: list[dict[str, object]] = []
    for index, segment_type in enumerate(("intro", "middle", "outro"), start=1):
        output.append(
            {
                "segment_id": f"{track_id}-{segment_type}-{index}",
                "segment_type": segment_type,
                "start_sec": float((index - 1) * 30),
                "end_sec": float(index * 30),
                "energy_score": 0.5,
                "descriptor_text": f"{track_id} {segment_type}",
                "embedding": vector_by_type[segment_type],
            }
        )
    return output


def test_validate_embedding_profile_success(monkeypatch: pytest.MonkeyPatch) -> None:
    class FakeEmbeddingClient:
        def validate(self, probe_text: str) -> list[float]:
            assert "validation probe" in probe_text
            return [0.2, 0.4]

    monkeypatch.setattr(worker_main, "_build_embedding_client", lambda payload, profile: FakeEmbeddingClient())

    result = worker_main.handle_validate_embedding_profile(
        {"options": {"embeddingProfileID": "google/gemini-embedding-2-preview"}}
    )

    assert result == {
        "ok": True,
        "profileID": "google/gemini-embedding-2-preview",
        "modelName": "gemini-embedding-2-preview",
    }


def test_validate_embedding_profile_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    class FakeEmbeddingClient:
        def validate(self, probe_text: str) -> list[float] | None:
            return None

    monkeypatch.setattr(worker_main, "_build_embedding_client", lambda payload, profile: FakeEmbeddingClient())

    with pytest.raises(ValueError, match="Failed to validate"):
        worker_main.handle_validate_embedding_profile(
            {"options": {"embeddingProfileID": "google/gemini-embedding-2-preview"}}
        )


def test_embed_descriptors_requires_non_empty_embeddings(monkeypatch: pytest.MonkeyPatch) -> None:
    class FakeEmbeddingClient:
        _last_error = "Synthetic embedding failure"

        def embed_batch(self, texts: list[str]) -> list[list[float] | None]:
            return [None for _ in texts]

    monkeypatch.setattr(worker_main, "_build_embedding_client", lambda payload, profile: FakeEmbeddingClient())

    with pytest.raises(ValueError, match="Synthetic embedding failure"):
        worker_main.handle_embed_descriptors(
            {
                "filePath": "/tracks/failing.mp3",
                "segments": [
                    {
                        "segmentType": "intro",
                        "startSec": 0,
                        "endSec": 10,
                        "energyScore": 0.4,
                        "descriptorText": "warm pads",
                    }
                ],
                "options": {"embeddingProfileID": "google/gemini-embedding-2-preview"},
            }
        )


def test_search_tracks_applies_deterministic_late_fusion(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _install_fake_chroma(monkeypatch)

    class FakeEmbeddingClient:
        def embed_batch(self, texts: list[str]) -> list[list[float]]:
            assert texts == ["rolling house groove"]
            return [[1.0, 0.0]]

    monkeypatch.setattr(worker_main, "_build_embedding_client", lambda payload, profile: FakeEmbeddingClient())

    store = chroma_store.ChromaVectorStore(
        persist_dir=str(tmp_path / "vectordb"),
        profile_id="google/gemini-embedding-2-preview",
    )
    store.upsert_track_embeddings(
        track_id="track-a",
        scan_version="v1",
        track_metadata=_make_track_metadata("app-track-a", "/tracks/a.mp3"),
        track_embedding=[1.0, 0.0],
        segments=_make_segments(
            "track-a",
            {
                "intro": [0.0, 1.0],
                "middle": [1.0, 0.0],
                "outro": [0.0, 1.0],
            },
        ),
    )
    store.upsert_track_embeddings(
        track_id="track-b",
        scan_version="v1",
        track_metadata=_make_track_metadata("app-track-b", "/tracks/b.mp3"),
        track_embedding=[0.0, 1.0],
        segments=_make_segments(
            "track-b",
            {
                "intro": [1.0, 0.0],
                "middle": [0.0, 1.0],
                "outro": [0.0, 1.0],
            },
        ),
    )

    result = worker_main.handle_search_tracks(
        {
            "command": "search_tracks",
            "mode": "text",
            "queryText": "rolling house groove",
            "limit": 10,
            "excludeTrackPaths": [],
            "filters": {
                "bpmMin": 120,
                "bpmMax": 128,
                "durationMaxSec": 400,
                "musicalKey": "8A",
                "genre": "House",
            },
            "weights": {
                "tracks": 0.45,
                "intro": 0.15,
                "middle": 0.25,
                "outro": 0.15,
            },
            "options": {
                "cacheDirectory": str(tmp_path),
                "embeddingProfileID": "google/gemini-embedding-2-preview",
            },
        }
    )

    assert [item["filePath"] for item in result["results"]] == ["/tracks/a.mp3", "/tracks/b.mp3"]

    top = result["results"][0]
    runner_up = result["results"][1]
    assert top["bestMatchedCollection"] in {"tracks", "middle"}
    assert top["fusedScore"] > runner_up["fusedScore"]
    assert top["fusedScore"] == pytest.approx(
        0.45 * top["trackScore"] +
        0.15 * top["introScore"] +
        0.25 * top["middleScore"] +
        0.15 * top["outroScore"]
    )


def test_hybrid_query_embeddings_blend_text_and_reference_evenly(monkeypatch: pytest.MonkeyPatch) -> None:
    class FakeEmbeddingClient:
        def embed_batch(self, texts: list[str]) -> list[list[float]]:
            assert texts == ["sunrise warmup"]
            return [[1.0, 0.0]]

    monkeypatch.setattr(worker_main, "_build_embedding_client", lambda payload, profile: FakeEmbeddingClient())

    embeddings = worker_main._search_query_embeddings(
        {
            "queryText": "sunrise warmup",
            "queryTrackEmbedding": [0.0, 1.0],
            "querySegments": [
                {"segmentType": "intro", "embedding": [0.0, 1.0]},
                {"segmentType": "middle", "embedding": [0.0, 1.0]},
                {"segmentType": "outro", "embedding": [0.0, 1.0]},
            ],
        },
        {
            "id": "google/gemini-embedding-2-preview",
            "backend": "google_ai",
            "model": "gemini-embedding-2-preview",
        },
        "hybrid",
    )

    expected = [math.sqrt(0.5), math.sqrt(0.5)]
    assert embeddings["tracks"] == pytest.approx(expected)
    assert embeddings["intro"] == pytest.approx(expected)
    assert embeddings["middle"] == pytest.approx(expected)
    assert embeddings["outro"] == pytest.approx(expected)


def test_profile_namespace_separates_collections(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _install_fake_chroma(monkeypatch)

    google_store = chroma_store.ChromaVectorStore(
        persist_dir=str(tmp_path / "vectordb"),
        profile_id="google/gemini-embedding-2-preview",
    )
    clap_store = chroma_store.ChromaVectorStore(
        persist_dir=str(tmp_path / "vectordb"),
        profile_id="local/clap-htsat-unfused",
    )

    google_store.upsert_track_embeddings(
        track_id="shared-track",
        scan_version="g1",
        track_metadata=_make_track_metadata("app-google", "/tracks/shared.mp3"),
        track_embedding=[1.0, 0.0],
        segments=_make_segments(
            "shared-track-google",
            {"intro": [1.0, 0.0], "middle": [1.0, 0.0], "outro": [1.0, 0.0]},
        ),
    )
    clap_store.upsert_track_embeddings(
        track_id="shared-track",
        scan_version="c1",
        track_metadata=_make_track_metadata("app-clap", "/tracks/shared.mp3"),
        track_embedding=[0.0, 1.0],
        segments=_make_segments(
            "shared-track-clap",
            {"intro": [0.0, 1.0], "middle": [0.0, 1.0], "outro": [0.0, 1.0]},
        ),
    )

    google_results = google_store.search(
        query_embeddings={"tracks": [1.0, 0.0]},
        weights={"tracks": 1.0},
    )
    clap_results = clap_store.search(
        query_embeddings={"tracks": [1.0, 0.0]},
        weights={"tracks": 1.0},
    )

    assert google_results[0]["trackID"] == "app-google"
    assert google_results[0]["trackScore"] > clap_results[0]["trackScore"]
    assert set(FakePersistentClient.stores[str(tmp_path / "vectordb")].keys()) == {
        "tracks__google_gemini-embedding-2-preview",
        "intro__google_gemini-embedding-2-preview",
        "middle__google_gemini-embedding-2-preview",
        "outro__google_gemini-embedding-2-preview",
        "tracks__local_clap-htsat-unfused",
        "intro__local_clap-htsat-unfused",
        "middle__local_clap-htsat-unfused",
        "outro__local_clap-htsat-unfused",
    }


def test_reembedding_replaces_existing_profile_entries(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _install_fake_chroma(monkeypatch)

    store = chroma_store.ChromaVectorStore(
        persist_dir=str(tmp_path / "vectordb"),
        profile_id="google/gemini-embedding-2-preview",
    )
    track_metadata = _make_track_metadata("app-track", "/tracks/reembed.mp3")

    store.upsert_track_embeddings(
        track_id="track-reembed",
        scan_version="v1",
        track_metadata=track_metadata,
        track_embedding=[1.0, 0.0],
        segments=_make_segments(
            "track-reembed-v1",
            {"intro": [1.0, 0.0], "middle": [1.0, 0.0], "outro": [1.0, 0.0]},
        ),
    )
    first_results = store.search(
        query_embeddings={"tracks": [1.0, 0.0]},
        weights={"tracks": 1.0},
    )
    assert first_results[0]["trackScore"] == pytest.approx(1.0)

    store.upsert_track_embeddings(
        track_id="track-reembed",
        scan_version="v2",
        track_metadata=track_metadata,
        track_embedding=[0.0, 1.0],
        segments=_make_segments(
            "track-reembed-v2",
            {"intro": [0.0, 1.0], "middle": [0.0, 1.0], "outro": [0.0, 1.0]},
        ),
    )

    stale_query_results = store.search(
        query_embeddings={"tracks": [1.0, 0.0]},
        weights={"tracks": 1.0},
    )
    fresh_query_results = store.search(
        query_embeddings={"tracks": [0.0, 1.0]},
        weights={"tracks": 1.0},
    )

    assert stale_query_results[0]["trackScore"] < 1.0
    assert fresh_query_results[0]["trackScore"] == pytest.approx(1.0)
    assert len(store.collections["tracks"].records) == 1
    assert len(store.collections["intro"].records) == 1
    assert len(store.collections["middle"].records) == 1
    assert len(store.collections["outro"].records) == 1


def test_analyze_does_not_mutate_vector_store(monkeypatch: pytest.MonkeyPatch) -> None:
    class FakeSegment:
        def __init__(self, segment_type: str, descriptor_text: str) -> None:
            self.segment_type = segment_type
            self.start_sec = 0.0
            self.end_sec = 30.0
            self.energy_score = 0.5
            self.descriptor_text = descriptor_text

    def fake_analyze_track(file_path: str, track_metadata: dict[str, object]) -> dict[str, object]:
        return {
            "segments": [FakeSegment("intro", "bright intro")],
            "estimated_bpm": 124.0,
            "estimated_key": "8A",
            "brightness": 0.5,
            "onset_density": 0.5,
            "rhythmic_density": 0.5,
            "low_mid_high_balance": [0.3, 0.4, 0.3],
            "waveform_preview": [0.1, 0.2],
        }

    class FakeEmbeddingClient:
        def embed_batch(self, texts: list[str]) -> list[list[float]]:
            return [[1.0, 0.0] for _ in texts]

    monkeypatch.setattr(worker_main, "_load_analyze_track", lambda: fake_analyze_track)
    monkeypatch.setattr(worker_main, "_build_embedding_client", lambda payload, profile: FakeEmbeddingClient())
    monkeypatch.setattr(worker_main, "_vector_store", lambda payload, profile: pytest.fail("vector store should not be touched"))

    result = worker_main.handle_analyze(
        {
            "filePath": "/tracks/analyze.mp3",
            "trackMetadata": {"trackID": "track-1"},
            "options": {"embeddingProfileID": "google/gemini-embedding-2-preview"},
        }
    )

    assert result["trackEmbedding"] == pytest.approx([1.0, 0.0])
    assert result["segments"][0]["embedding"] == pytest.approx([1.0, 0.0])


def test_vector_maintenance_commands_update_profile_index(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _install_fake_chroma(monkeypatch)

    payload = {
        "options": {
            "cacheDirectory": str(tmp_path),
            "embeddingProfileID": "google/gemini-embedding-2-preview",
        },
        "track": {
            "trackID": "track-1",
            "filePath": "/tracks/one.mp3",
            "scanVersion": "v1",
            "bpm": 124,
            "musicalKey": "8A",
            "genre": "House",
            "duration": 300,
            "trackEmbedding": [1.0, 0.0],
            "segments": [
                {
                    "segmentID": "seg-intro",
                    "segmentType": "intro",
                    "startSec": 0,
                    "endSec": 30,
                    "energyScore": 0.5,
                    "descriptorText": "intro",
                    "embedding": [1.0, 0.0],
                }
            ],
        },
    }

    upsert_result = worker_main.handle_upsert_track_vectors({"command": "upsert_track_vectors", **payload})
    assert upsert_result["indexedTrackCount"] == 1

    health = worker_main.handle_healthcheck(
        {
            "command": "healthcheck",
            "options": {
                "cacheDirectory": str(tmp_path),
                "embeddingProfileID": "google/gemini-embedding-2-preview",
            },
        }
    )
    assert health["vectorIndexState"]["trackCount"] == 1
    assert health["vectorIndexState"]["manifestHash"]

    delete_result = worker_main.handle_delete_track_vectors(
        {
            "command": "delete_track_vectors",
            "trackID": "track-1",
            "deleteAllProfiles": True,
            "options": {
                "cacheDirectory": str(tmp_path),
                "embeddingProfileID": "google/gemini-embedding-2-preview",
            },
        }
    )
    assert delete_result["deletedProfileIDs"] == [
        "google/gemini-embedding-001",
        "google/gemini-embedding-2-preview",
        "local/clap-htsat-unfused",
    ]

    rebuilt = worker_main.handle_rebuild_vector_index(
        {
            "command": "rebuild_vector_index",
            "tracks": [payload["track"]],
            "options": {
                "cacheDirectory": str(tmp_path),
                "embeddingProfileID": "google/gemini-embedding-2-preview",
            },
        }
    )
    assert rebuilt["indexedTrackCount"] == 1
