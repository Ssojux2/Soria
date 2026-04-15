from __future__ import annotations

import importlib.util
import json
import logging
import os
import sys
import uuid
from pathlib import Path
from typing import Any

import numpy as np

LOGGER = logging.getLogger("soria.worker")
VALIDATION_PROBE_TEXT = "Soria validation probe for semantic DJ track search."
EMBEDDING_PROFILES: dict[str, dict[str, Any]] = {
    "google/gemini-embedding-2-preview": {
        "backend": "google_ai",
        "model": "gemini-embedding-2-preview",
        "requires_api_key": True,
    },
    "local/clap-htsat-unfused": {
        "backend": "clap",
        "model": "laion/clap-htsat-unfused",
        "requires_api_key": False,
    },
}


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read() or "{}")
        cache_dir = payload.get("options", {}).get("cacheDirectory") or str(Path.home() / ".soria-cache")
        _configure_logging(cache_dir)

        command = payload.get("command")
        if command == "validate_embedding_profile":
            _print_json(handle_validate_embedding_profile(payload))
            return 0
        if command == "analyze":
            _print_json(handle_analyze(payload))
            return 0
        if command == "embed_descriptors":
            _print_json(handle_embed_descriptors(payload))
            return 0
        if command == "search_tracks":
            _print_json(handle_search_tracks(payload))
            return 0
        if command == "healthcheck":
            _print_json(handle_healthcheck(payload))
            return 0

        _print_json({"error": f"Unsupported command: {command}"})
        return 2
    except Exception as exc:
        LOGGER.exception("Worker command failed")
        _print_json({"error": str(exc)})
        return 1


def handle_validate_embedding_profile(payload: dict[str, Any]) -> dict[str, Any]:
    profile = _resolve_embedding_profile(payload)
    client = _build_embedding_client(payload, profile)
    vector = client.validate(VALIDATION_PROBE_TEXT)
    if not vector:
        detail = getattr(client, "_last_error", None)
        if detail:
            raise ValueError(f"Failed to validate the active embedding profile. {detail}")
        raise ValueError("Failed to validate the active embedding profile.")

    return {
        "ok": True,
        "profileID": profile["id"],
        "modelName": profile["model"],
    }


def handle_analyze(payload: dict[str, Any]) -> dict[str, Any]:
    analyze_track = _load_analyze_track()

    file_path = payload["filePath"]
    track_metadata = payload.get("trackMetadata") or {}
    analysis = analyze_track(file_path=file_path, track_metadata=track_metadata)
    segments = [
        {
            "segment_type": segment.segment_type,
            "start_sec": segment.start_sec,
            "end_sec": segment.end_sec,
            "energy_score": segment.energy_score,
            "descriptor_text": segment.descriptor_text,
        }
        for segment in analysis["segments"]
    ]

    embedding_result = _embed_and_store_track(
        payload=payload,
        file_path=file_path,
        track_metadata=track_metadata,
        normalized_segments=segments,
    )

    return {
        "estimatedBPM": analysis["estimated_bpm"],
        "estimatedKey": analysis["estimated_key"],
        "brightness": analysis["brightness"],
        "onsetDensity": analysis["onset_density"],
        "rhythmicDensity": analysis["rhythmic_density"],
        "lowMidHighBalance": analysis["low_mid_high_balance"],
        "waveformPreview": analysis["waveform_preview"],
        "trackEmbedding": embedding_result["trackEmbedding"],
        "segments": embedding_result["segments"],
        "embeddingProfileID": embedding_result["embeddingProfileID"],
    }


def handle_embed_descriptors(payload: dict[str, Any]) -> dict[str, Any]:
    track_metadata = payload.get("trackMetadata") or {}
    normalized_segments = _normalize_payload_segments(payload.get("segments") or [])
    if not normalized_segments:
        return {
            "trackEmbedding": None,
            "segments": [],
            "embeddingProfileID": _resolve_embedding_profile(payload)["id"],
        }

    return _embed_and_store_track(
        payload=payload,
        file_path=payload["filePath"],
        track_metadata=track_metadata,
        normalized_segments=normalized_segments,
    )


def handle_search_tracks(payload: dict[str, Any]) -> dict[str, Any]:
    profile = _resolve_embedding_profile(payload)
    store = _vector_store(payload, profile)
    weights = payload.get("weights") or {}
    limit = max(1, int(payload.get("limit") or 20))
    mode = str(payload.get("mode") or "text").strip()
    query_embeddings = _search_query_embeddings(payload, profile, mode)
    if not query_embeddings:
        return {"results": []}

    results = store.search(
        query_embeddings=query_embeddings,
        weights=weights,
        n_results=max(limit * 4, 20),
        where=_build_where(payload.get("filters") or {}),
    )

    excluded_paths = set(payload.get("excludeTrackPaths") or [])
    filtered = [
        item
        for item in results
        if item.get("filePath") and str(item["filePath"]) not in excluded_paths
    ]
    return {"results": filtered[:limit]}


def handle_healthcheck(payload: dict[str, Any]) -> dict[str, Any]:
    profile = _resolve_embedding_profile(payload)
    api_key = _resolve_google_ai_api_key(payload.get("options") or {})
    return {
        "ok": True,
        "apiKeyConfigured": bool(api_key),
        "pythonExecutable": sys.executable,
        "workerScriptPath": str(Path(__file__).resolve()),
        "embeddingProfileID": profile["id"],
        "dependencies": {
            "librosa": _module_available("librosa"),
            "chromadb": _module_available("chromadb"),
            "requests": _module_available("requests"),
        },
    }


def _embed_and_store_track(
    payload: dict[str, Any],
    file_path: str,
    track_metadata: dict[str, Any],
    normalized_segments: list[dict[str, Any]],
) -> dict[str, Any]:
    profile = _resolve_embedding_profile(payload)
    client = _build_embedding_client(payload, profile)
    segment_texts = [segment["descriptor_text"] for segment in normalized_segments]
    segment_embeddings = client.embed_batch(segment_texts)
    weighted_track_embedding = _weighted_embedding(segment_embeddings, normalized_segments)

    segments_with_embeddings = []
    for segment, embedding in zip(normalized_segments, segment_embeddings):
        segments_with_embeddings.append(
            {
                "segment_id": str(uuid.uuid4()),
                "segment_type": segment["segment_type"],
                "start_sec": float(segment["start_sec"]),
                "end_sec": float(segment["end_sec"]),
                "energy_score": float(segment["energy_score"]),
                "descriptor_text": segment["descriptor_text"],
                "embedding": embedding,
            }
        )

    store = _vector_store(payload, profile)
    track_id = str(track_metadata.get("trackID") or _stable_track_id(file_path))
    scan_version = f"{track_metadata.get('contentHash', '')}|{track_metadata.get('modifiedTime', '')}"
    store.upsert_track_embeddings(
        track_id=track_id,
        scan_version=scan_version,
        track_metadata={
            "app_track_id": track_metadata.get("trackID") or "",
            "file_path": file_path,
            "bpm": track_metadata.get("bpm"),
            "musical_key": track_metadata.get("musicalKey") or "",
            "genre": track_metadata.get("genre") or "",
            "duration_sec": track_metadata.get("duration") or 0,
        },
        track_embedding=weighted_track_embedding,
        segments=segments_with_embeddings,
    )

    return {
        "trackEmbedding": weighted_track_embedding,
        "segments": [
            {
                "segmentType": segment["segment_type"],
                "startSec": float(segment["start_sec"]),
                "endSec": float(segment["end_sec"]),
                "energyScore": float(segment["energy_score"]),
                "descriptorText": segment["descriptor_text"],
                "embedding": embedding,
            }
            for segment, embedding in zip(normalized_segments, segment_embeddings)
        ],
        "embeddingProfileID": profile["id"],
    }


def _search_query_embeddings(
    payload: dict[str, Any],
    profile: dict[str, Any],
    mode: str,
) -> dict[str, list[float]]:
    if mode == "text":
        query_text = str(payload.get("queryText") or "").strip()
        if not query_text:
            return {}
        client = _build_embedding_client(payload, profile)
        query_vector = client.embed_batch([query_text])[0]
        if not query_vector:
            return {}
        return {
            "tracks": query_vector,
            "intro": query_vector,
            "middle": query_vector,
            "outro": query_vector,
        }

    if mode == "reference":
        output: dict[str, list[float]] = {}
        track_embedding = payload.get("queryTrackEmbedding")
        if isinstance(track_embedding, list) and track_embedding:
            output["tracks"] = [float(value) for value in track_embedding]
        for segment in payload.get("querySegments") or []:
            segment_type = str(segment.get("segmentType") or "").strip()
            embedding = segment.get("embedding")
            if segment_type in {"intro", "middle", "outro"} and isinstance(embedding, list) and embedding:
                output[segment_type] = [float(value) for value in embedding]
        return output

    raise ValueError(f"Unsupported search mode: {mode}")


def _build_where(filters: dict[str, Any]) -> dict[str, Any] | None:
    clauses: list[dict[str, Any]] = []
    bpm_min = filters.get("bpmMin")
    bpm_max = filters.get("bpmMax")
    duration_max = filters.get("durationMaxSec")
    musical_key = str(filters.get("musicalKey") or "").strip()
    genre = str(filters.get("genre") or "").strip()

    if bpm_min is not None:
        clauses.append({"bpm": {"$gte": float(bpm_min)}})
    if bpm_max is not None:
        clauses.append({"bpm": {"$lte": float(bpm_max)}})
    if duration_max is not None:
        clauses.append({"duration_sec": {"$lte": float(duration_max)}})
    if musical_key:
        clauses.append({"musical_key": {"$eq": musical_key}})
    if genre:
        clauses.append({"genre": {"$eq": genre}})

    if not clauses:
        return None
    if len(clauses) == 1:
        return clauses[0]
    return {"$and": clauses}


def _weighted_embedding(
    embeddings: list[list[float] | None],
    segments: list[dict[str, Any]],
) -> list[float] | None:
    weights = {"intro": 1.0, "middle": 3.0, "outro": 1.0}
    valid: list[tuple[np.ndarray, float]] = []
    for embedding, segment in zip(embeddings, segments):
        if not embedding:
            continue
        valid.append((np.array(embedding, dtype=np.float64), weights.get(segment["segment_type"], 1.0)))

    if not valid:
        return None
    total_weight = sum(weight for _, weight in valid)
    aggregate = sum(vector * weight for vector, weight in valid) / total_weight
    norm = np.linalg.norm(aggregate)
    if norm > 0:
        aggregate = aggregate / norm
    return [float(value) for value in aggregate.tolist()]


def _normalize_payload_segments(segments: list[dict[str, Any]]) -> list[dict[str, Any]]:
    normalized: list[dict[str, Any]] = []
    for segment in segments:
        descriptor_text = str(segment.get("descriptorText") or "").strip()
        segment_type = str(segment.get("segmentType") or "").strip()
        if not descriptor_text or segment_type not in {"intro", "middle", "outro"}:
            continue
        normalized.append(
            {
                "segment_type": segment_type,
                "start_sec": float(segment.get("startSec") or 0),
                "end_sec": float(segment.get("endSec") or 0),
                "energy_score": float(segment.get("energyScore") or 0),
                "descriptor_text": descriptor_text,
            }
        )
    return normalized


def _stable_track_id(file_path: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, file_path))


def _resolve_embedding_profile(payload: dict[str, Any]) -> dict[str, Any]:
    requested_profile_id = str(payload.get("options", {}).get("embeddingProfileID") or "").strip()
    if not requested_profile_id:
        requested_profile_id = "google/gemini-embedding-2-preview"
    profile = EMBEDDING_PROFILES.get(requested_profile_id)
    if profile is None:
        raise ValueError(f"Unsupported embedding profile: {requested_profile_id}")
    return {"id": requested_profile_id, **profile}


def _resolve_google_ai_api_key(options: dict[str, Any]) -> str | None:
    if isinstance(options.get("googleAIAPIKey"), str):
        trimmed = options["googleAIAPIKey"].strip()
        if trimmed:
            return trimmed

    for key in ("GOOGLE_AI_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY"):
        raw_value = os.environ.get(key, "").strip()
        if raw_value:
            return raw_value
    return None


def _build_embedding_client(payload: dict[str, Any], profile: dict[str, Any]):
    cache_dir = str((payload.get("options") or {}).get("cacheDirectory") or Path.home() / ".soria-cache")
    api_key = _resolve_google_ai_api_key(payload.get("options") or {})

    if profile["backend"] == "google_ai":
        from embedding.gemini_client import GeminiEmbeddingClient

        return GeminiEmbeddingClient(api_key=api_key, cache_dir=cache_dir, model=profile["model"])
    if profile["backend"] == "clap":
        from embedding.clap_client import CLAPEmbeddingClient

        return CLAPEmbeddingClient(api_key=api_key, cache_dir=cache_dir, model=profile["model"])
    raise ValueError(f"Unsupported embedding backend: {profile['backend']}")


def _vector_store(payload: dict[str, Any], profile: dict[str, Any]):
    ChromaVectorStore = _load_vector_store()
    options = payload.get("options") or {}
    cache_dir = options.get("cacheDirectory") or str(Path.home() / ".soria-cache")
    vector_dir = str(Path(cache_dir) / "vectordb")
    Path(vector_dir).mkdir(parents=True, exist_ok=True)
    return ChromaVectorStore(persist_dir=vector_dir, profile_id=profile["id"])


def _configure_logging(cache_dir: str) -> None:
    log_dir = Path(cache_dir)
    log_dir.mkdir(parents=True, exist_ok=True)
    if LOGGER.handlers:
        return
    handler = logging.FileHandler(log_dir / "worker.log", encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
    LOGGER.setLevel(logging.INFO)
    LOGGER.addHandler(handler)


def _module_available(module_name: str) -> bool:
    return importlib.util.find_spec(module_name) is not None


def _load_analyze_track():
    from audio.features import analyze_track

    return analyze_track


def _load_vector_store():
    from vectordb.chroma_store import ChromaVectorStore

    return ChromaVectorStore


def _print_json(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False))
    sys.stdout.flush()


if __name__ == "__main__":
    raise SystemExit(main())
