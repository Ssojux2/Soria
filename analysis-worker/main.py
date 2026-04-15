from __future__ import annotations

import importlib.util
import json
import logging
import os
import sys
import uuid
from datetime import datetime, timezone
import inspect
from pathlib import Path
from typing import Any, Callable

import numpy as np

LOGGER = logging.getLogger("soria.worker")
VALIDATION_PROBE_TEXT = "Soria validation probe for semantic DJ track search."
PROGRESS_PREFIX = "SORIA_PROGRESS "
EMBEDDING_PROFILES: dict[str, dict[str, Any]] = {
    "google/gemini-embedding-001": {
        "backend": "google_ai",
        "model": "gemini-embedding-001",
        "requires_api_key": True,
    },
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
        _disable_telemetry_noise()
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
        if command == "build_query_embeddings":
            _print_json(handle_build_query_embeddings(payload))
            return 0
        if command == "search_tracks":
            _print_json(handle_search_tracks(payload))
            return 0
        if command == "upsert_track_vectors":
            _print_json(handle_upsert_track_vectors(payload))
            return 0
        if command == "delete_track_vectors":
            _print_json(handle_delete_track_vectors(payload))
            return 0
        if command == "rebuild_vector_index":
            _print_json(handle_rebuild_vector_index(payload))
            return 0
        if command == "healthcheck":
            _print_json(handle_healthcheck(payload))
            return 0

        _print_json({"error": f"Unsupported command: {command}"})
        return 2
    except BrokenPipeError:
        return 0
    except Exception as exc:
        LOGGER.exception("Worker command failed")
        if _print_json({"error": str(exc)}):
            return 1
        return 0


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
    progress = _progress_emitter(file_path)
    track_metadata = dict(payload.get("trackMetadata") or {})
    track_metadata["analysisFocus"] = (payload.get("options") or {}).get("analysisFocus")
    progress("launching", "Launching analysis worker", 0.02)
    analysis = _call_with_optional_keyword(
        analyze_track,
        "progress_callback",
        progress,
        file_path=file_path,
        track_metadata=track_metadata,
    )
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

    embedding_result = _embed_track(
        payload=payload,
        file_path=file_path,
        track_metadata=track_metadata,
        normalized_segments=segments,
        progress_callback=progress,
    )

    return {
        "estimatedBPM": analysis["estimated_bpm"],
        "estimatedKey": analysis["estimated_key"],
        "brightness": analysis["brightness"],
        "onsetDensity": analysis["onset_density"],
        "rhythmicDensity": analysis["rhythmic_density"],
        "lowMidHighBalance": analysis["low_mid_high_balance"],
        "waveformPreview": analysis["waveform_preview"],
        "analysisFocus": analysis.get("analysis_focus", "balanced"),
        "introLengthSec": analysis.get("intro_length_sec", 0.0),
        "outroLengthSec": analysis.get("outro_length_sec", 0.0),
        "energyArc": analysis.get("energy_arc", []),
        "mixabilityTags": analysis.get("mixability_tags", []),
        "confidence": analysis.get("confidence", 0.5),
        "trackEmbedding": embedding_result["trackEmbedding"],
        "segments": embedding_result["segments"],
        "embeddingProfileID": embedding_result["embeddingProfileID"],
    }


def handle_embed_descriptors(payload: dict[str, Any]) -> dict[str, Any]:
    file_path = payload["filePath"]
    progress = _progress_emitter(file_path)
    progress("launching", "Preparing descriptor embedding", 0.02)
    track_metadata = payload.get("trackMetadata") or {}
    normalized_segments = _normalize_payload_segments(payload.get("segments") or [])
    if not normalized_segments:
        raise ValueError("No valid descriptor segments were provided for embedding.")

    return _embed_track(
        payload=payload,
        file_path=file_path,
        track_metadata=track_metadata,
        normalized_segments=normalized_segments,
        progress_callback=progress,
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


def handle_build_query_embeddings(payload: dict[str, Any]) -> dict[str, Any]:
    profile = _resolve_embedding_profile(payload)
    mode = str(payload.get("mode") or "text").strip()
    query_embeddings = _search_query_embeddings(payload, profile, mode)
    return {
        "queryEmbeddings": query_embeddings,
        "embeddingProfileID": profile["id"],
    }


def handle_healthcheck(payload: dict[str, Any]) -> dict[str, Any]:
    requested_profile_id = str(payload.get("options", {}).get("embeddingProfileID") or "").strip()
    if not requested_profile_id:
        requested_profile_id = "google/gemini-embedding-001"
    api_key = _resolve_google_ai_api_key(payload.get("options") or {})
    profile_status_by_id = _profile_statuses(payload)
    vector_index_state = None
    if requested_profile_id in EMBEDDING_PROFILES:
        vector_index_state = _vector_index_state(payload, requested_profile_id)
    return {
        "ok": True,
        "apiKeyConfigured": bool(api_key),
        "pythonExecutable": sys.executable,
        "workerScriptPath": str(Path(__file__).resolve()),
        "embeddingProfileID": requested_profile_id,
        "dependencies": {
            "librosa": _module_available("librosa"),
            "chromadb": _module_available("chromadb"),
            "requests": _module_available("requests"),
        },
        "profileStatusByID": profile_status_by_id,
        "vectorIndexState": vector_index_state,
    }


def handle_upsert_track_vectors(payload: dict[str, Any]) -> dict[str, Any]:
    profile = _resolve_embedding_profile(payload)
    track_payload = payload.get("track") or {}
    normalized_track = _normalize_index_track(track_payload)
    store = _vector_store(payload, profile)
    _upsert_index_track(store, normalized_track)
    return {
        "ok": True,
        "indexedTrackCount": 1,
        "embeddingProfileID": profile["id"],
    }


def handle_delete_track_vectors(payload: dict[str, Any]) -> dict[str, Any]:
    profile_ids = _profile_ids_from_payload(payload)
    track_id = str(payload.get("trackID") or "").strip()
    if not track_id:
        raise ValueError("trackID is required to delete vector entries.")

    deleted_profiles: list[str] = []
    for profile_id in profile_ids:
        if profile_id not in EMBEDDING_PROFILES:
            continue
        profile = {"id": profile_id, **EMBEDDING_PROFILES[profile_id]}
        store = _vector_store(payload, profile)
        store.delete_track(track_id)
        deleted_profiles.append(profile_id)

    return {
        "ok": True,
        "deletedProfileIDs": deleted_profiles,
        "trackID": track_id,
    }


def handle_rebuild_vector_index(payload: dict[str, Any]) -> dict[str, Any]:
    profile = _resolve_embedding_profile(payload)
    store = _vector_store(payload, profile)
    store.reset_profile()

    indexed_count = 0
    for track_payload in payload.get("tracks") or []:
        normalized_track = _normalize_index_track(track_payload)
        _upsert_index_track(store, normalized_track)
        indexed_count += 1

    return {
        "ok": True,
        "indexedTrackCount": indexed_count,
        "embeddingProfileID": profile["id"],
    }


def _embed_track(
    payload: dict[str, Any],
    file_path: str,
    track_metadata: dict[str, Any],
    normalized_segments: list[dict[str, Any]],
    progress_callback: Callable[[str, str, float | None], None] | None = None,
) -> dict[str, Any]:
    if not normalized_segments:
        raise ValueError("No valid segments are available for embedding.")

    profile = _resolve_embedding_profile(payload)
    if progress_callback:
        progress_callback("embedding_descriptors", "Embedding descriptor text", 0.72)
    client = _call_with_optional_keyword(
        _build_embedding_client,
        "progress_callback",
        (
            None
            if progress_callback is None
            else lambda message, fraction=None: progress_callback(
                "embedding_descriptors",
                message,
                fraction,
            )
        ),
        payload,
        profile,
    )
    segment_texts = [segment["descriptor_text"] for segment in normalized_segments]
    segment_embeddings = client.embed_batch(segment_texts)
    segment_embeddings = _require_non_empty_embeddings(segment_embeddings, client)
    if progress_callback:
        progress_callback("embedding_descriptors", "Descriptor embeddings ready", 0.92)
    weighted_track_embedding = _weighted_embedding(segment_embeddings, normalized_segments)
    if not weighted_track_embedding:
        raise ValueError("Failed to compute a track embedding from the analyzed segments.")
    if progress_callback:
        progress_callback("returning_result", "Returning analyzed result", 0.98)

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
        return _text_query_embeddings(payload, profile)

    if mode == "reference":
        return _reference_query_embeddings(payload)

    if mode == "hybrid":
        return _blend_query_embeddings(
            text_embeddings=_text_query_embeddings(payload, profile),
            reference_embeddings=_reference_query_embeddings(payload),
        )

    raise ValueError(f"Unsupported search mode: {mode}")


def _text_query_embeddings(
    payload: dict[str, Any],
    profile: dict[str, Any],
) -> dict[str, list[float]]:
    query_text = str(payload.get("queryText") or "").strip()
    if not query_text:
        return {}
    client = _build_embedding_client(payload, profile)
    query_vector = client.embed_batch([query_text])[0]
    if not query_vector:
        return {}
    normalized = _normalize_query_vector(query_vector)
    return {
        "tracks": normalized,
        "intro": normalized,
        "middle": normalized,
        "outro": normalized,
    }


def _reference_query_embeddings(payload: dict[str, Any]) -> dict[str, list[float]]:
    output: dict[str, list[float]] = {}
    track_embedding = payload.get("queryTrackEmbedding")
    if isinstance(track_embedding, list) and track_embedding:
        output["tracks"] = _normalize_query_vector(track_embedding)
    for segment in payload.get("querySegments") or []:
        segment_type = str(segment.get("segmentType") or "").strip()
        embedding = segment.get("embedding")
        if segment_type in {"intro", "middle", "outro"} and isinstance(embedding, list) and embedding:
            output[segment_type] = _normalize_query_vector(embedding)
    return output


def _blend_query_embeddings(
    text_embeddings: dict[str, list[float]],
    reference_embeddings: dict[str, list[float]],
) -> dict[str, list[float]]:
    output: dict[str, list[float]] = {}
    for collection in ("tracks", "intro", "middle", "outro"):
        vectors: list[np.ndarray] = []
        if collection in text_embeddings:
            vectors.append(np.array(text_embeddings[collection], dtype=np.float64) * 0.5)

        reference_vector = reference_embeddings.get(collection) or reference_embeddings.get("tracks")
        if reference_vector:
            vectors.append(np.array(reference_vector, dtype=np.float64) * 0.5)

        if not vectors:
            continue

        aggregate = sum(vectors)
        norm = np.linalg.norm(aggregate)
        if norm > 0:
            aggregate = aggregate / norm
        output[collection] = [float(value) for value in aggregate.tolist()]
    return output


def _normalize_query_vector(vector: list[float]) -> list[float]:
    array = np.array([float(value) for value in vector], dtype=np.float64)
    norm = np.linalg.norm(array)
    if norm > 0:
        array = array / norm
    return [float(value) for value in array.tolist()]


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
    embeddings: list[list[float]],
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


def _normalize_index_track(track_payload: dict[str, Any]) -> dict[str, Any]:
    track_id = str(track_payload.get("trackID") or "").strip()
    file_path = str(track_payload.get("filePath") or "").strip()
    if not track_id or not file_path:
        raise ValueError("Vector index updates require both trackID and filePath.")

    track_embedding = track_payload.get("trackEmbedding")
    if not isinstance(track_embedding, list) or not track_embedding:
        raise ValueError(f"Track {track_id} is missing a non-empty trackEmbedding.")

    normalized_segments = _normalize_index_segments(track_payload.get("segments") or [], track_id)
    if not normalized_segments:
        raise ValueError(f"Track {track_id} has no indexable segment embeddings.")

    return {
        "track_id": track_id,
        "file_path": file_path,
        "scan_version": str(track_payload.get("scanVersion") or ""),
        "track_embedding": [float(value) for value in track_embedding],
        "track_metadata": {
            "app_track_id": track_id,
            "file_path": file_path,
            "bpm": track_payload.get("bpm"),
            "musical_key": str(track_payload.get("musicalKey") or ""),
            "genre": str(track_payload.get("genre") or ""),
            "duration_sec": float(track_payload.get("duration") or 0),
        },
        "segments": normalized_segments,
    }


def _normalize_index_segments(segments: list[dict[str, Any]], track_id: str) -> list[dict[str, Any]]:
    normalized: list[dict[str, Any]] = []
    for segment in segments:
        segment_type = str(segment.get("segmentType") or "").strip()
        descriptor_text = str(segment.get("descriptorText") or "").strip()
        embedding = segment.get("embedding")
        if segment_type not in {"intro", "middle", "outro"} or not descriptor_text:
            continue
        if not isinstance(embedding, list) or not embedding:
            continue
        normalized.append(
            {
                "segment_id": str(segment.get("segmentID") or f"{track_id}:{segment_type}:{uuid.uuid4()}"),
                "segment_type": segment_type,
                "start_sec": float(segment.get("startSec") or 0),
                "end_sec": float(segment.get("endSec") or 0),
                "energy_score": float(segment.get("energyScore") or 0),
                "descriptor_text": descriptor_text,
                "embedding": [float(value) for value in embedding],
            }
        )
    return normalized


def _upsert_index_track(store: Any, normalized_track: dict[str, Any]) -> None:
    store.upsert_track_embeddings(
        track_id=normalized_track["track_id"],
        scan_version=normalized_track["scan_version"],
        track_metadata=normalized_track["track_metadata"],
        track_embedding=normalized_track["track_embedding"],
        segments=normalized_track["segments"],
    )


def _require_non_empty_embeddings(
    embeddings: list[list[float] | None],
    client: Any,
) -> list[list[float]]:
    normalized: list[list[float]] = []
    for index, embedding in enumerate(embeddings):
        if embedding:
            normalized.append([float(value) for value in embedding])
            continue
        detail = getattr(client, "_last_error", None)
        if detail:
            raise ValueError(f"Failed to embed descriptor segment {index + 1}. {detail}")
        raise ValueError(f"Failed to embed descriptor segment {index + 1}.")
    return normalized


def _stable_track_id(file_path: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, file_path))


def _profile_statuses(payload: dict[str, Any]) -> dict[str, dict[str, Any]]:
    status_by_id: dict[str, dict[str, Any]] = {}
    for profile_id, profile in EMBEDDING_PROFILES.items():
        dependency_errors: list[str] = []
        if not _module_available("chromadb"):
            dependency_errors.append("Missing dependency: chromadb")
        if profile["backend"] == "clap":
            if not _module_available("torch"):
                dependency_errors.append("Missing dependency: torch")
            if not _module_available("transformers"):
                dependency_errors.append("Missing dependency: transformers")

        status_by_id[profile_id] = {
            "supported": not dependency_errors,
            "requiresAPIKey": bool(profile.get("requires_api_key")),
            "dependencyErrors": dependency_errors,
        }
    return status_by_id


def _vector_index_state(payload: dict[str, Any], profile_id: str) -> dict[str, Any]:
    if not _module_available("chromadb"):
        return {
            "trackCount": 0,
            "trackIDs": [],
            "trackFilePaths": [],
            "collectionCounts": {},
        }
    profile = {"id": profile_id, **EMBEDDING_PROFILES[profile_id]}
    store = _vector_store(payload, profile)
    return store.index_state()


def _resolve_embedding_profile(payload: dict[str, Any]) -> dict[str, Any]:
    requested_profile_id = str(payload.get("options", {}).get("embeddingProfileID") or "").strip()
    if not requested_profile_id:
        requested_profile_id = "google/gemini-embedding-001"
    profile = EMBEDDING_PROFILES.get(requested_profile_id)
    if profile is None:
        raise ValueError(f"Unsupported embedding profile: {requested_profile_id}")
    return {"id": requested_profile_id, **profile}


def _profile_ids_from_payload(payload: dict[str, Any]) -> list[str]:
    requested = payload.get("profileIDs")
    if isinstance(requested, list):
        output = [str(value).strip() for value in requested if str(value).strip()]
        if output:
            return output

    if payload.get("deleteAllProfiles"):
        return list(EMBEDDING_PROFILES.keys())

    return [_resolve_embedding_profile(payload)["id"]]


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


def _build_embedding_client(
    payload: dict[str, Any],
    profile: dict[str, Any],
    progress_callback: Callable[[str, float | None], None] | None = None,
):
    cache_dir = str((payload.get("options") or {}).get("cacheDirectory") or Path.home() / ".soria-cache")
    api_key = _resolve_google_ai_api_key(payload.get("options") or {})

    if profile["backend"] == "google_ai":
        from embedding.gemini_client import GeminiEmbeddingClient

        return GeminiEmbeddingClient(
            api_key=api_key,
            cache_dir=cache_dir,
            model=profile["model"],
            progress_callback=progress_callback,
        )
    if profile["backend"] == "clap":
        from embedding.clap_client import CLAPEmbeddingClient

        return CLAPEmbeddingClient(
            api_key=api_key,
            cache_dir=cache_dir,
            model=profile["model"],
            progress_callback=progress_callback,
        )
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


def _disable_telemetry_noise() -> None:
    os.environ["ANONYMIZED_TELEMETRY"] = "FALSE"
    os.environ["CHROMA_PRODUCT_TELEMETRY_IMPL"] = "chromadb.telemetry.product.posthog.Posthog"
    os.environ["POSTHOG_DISABLED"] = "true"
    try:
        import posthog

        posthog.disabled = True
        posthog.capture = lambda *args, **kwargs: None
    except Exception:
        return


def _progress_emitter(file_path: str) -> Callable[[str, str, float | None], None]:
    def emit(stage: str, message: str, fraction: float | None = None) -> None:
        _emit_progress(
            stage=stage,
            message=message,
            fraction=fraction,
            track_path=file_path,
        )

    return emit


def _emit_progress(
    *,
    stage: str,
    message: str,
    fraction: float | None = None,
    track_path: str | None = None,
) -> None:
    payload = {
        "stage": stage,
        "message": message,
        "fraction": fraction,
        "trackPath": track_path,
        "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    try:
        sys.stderr.write(PROGRESS_PREFIX + json.dumps(payload, ensure_ascii=False) + "\n")
        sys.stderr.flush()
    except BrokenPipeError:
        return


def _call_with_optional_keyword(
    function: Callable[..., Any],
    keyword: str,
    value: Any,
    *args: Any,
    **kwargs: Any,
) -> Any:
    try:
        parameters = inspect.signature(function).parameters
    except (TypeError, ValueError):
        parameters = {}

    if keyword in parameters:
        kwargs[keyword] = value
    return function(*args, **kwargs)


def _module_available(module_name: str) -> bool:
    return importlib.util.find_spec(module_name) is not None


def _load_analyze_track():
    from audio.features import analyze_track

    return analyze_track


def _load_vector_store():
    from vectordb.chroma_store import ChromaVectorStore

    return ChromaVectorStore


def _print_json(payload: dict[str, Any]) -> bool:
    try:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False))
        sys.stdout.flush()
        return True
    except BrokenPipeError:
        try:
            devnull = os.open(os.devnull, os.O_WRONLY)
            os.dup2(devnull, sys.stdout.fileno())
            os.close(devnull)
        except OSError:
            pass
        return False


if __name__ == "__main__":
    raise SystemExit(main())
