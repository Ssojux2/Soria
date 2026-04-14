from __future__ import annotations

import json
import importlib.util
import logging
import os
import sys
import uuid
from pathlib import Path
from typing import Any

import numpy as np

LOGGER = logging.getLogger("soria.worker")


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read() or "{}")
        cache_dir = payload.get("options", {}).get("cacheDirectory") or str(Path.home() / ".soria-cache")
        _configure_logging(cache_dir)

        command = payload.get("command")
        if command == "healthcheck":
            _print_json(handle_healthcheck(payload))
            return 0
        if command == "analyze":
            _print_json(handle_analyze(payload))
            return 0
        if command == "query_similar":
            _print_json(handle_query_similar(payload))
            return 0

        _print_json({"error": f"Unsupported command: {command}"})
        return 2
    except Exception as exc:
        LOGGER.exception("Worker command failed")
        _print_json({"error": str(exc)})
        return 1


def handle_analyze(payload: dict[str, Any]) -> dict[str, Any]:
    analyze_track = _load_analyze_track()
    ChromaVectorStore = _load_vector_store()

    file_path = payload["filePath"]
    track_metadata = payload.get("trackMetadata") or {}
    options = payload.get("options") or {}
    cache_dir = options.get("cacheDirectory") or str(Path.home() / ".soria-cache")

    analysis = analyze_track(file_path=file_path, track_metadata=track_metadata)
    segments = analysis["segments"]

    api_key = options.get("geminiAPIKey") or os.environ.get("GEMINI_API_KEY")
    vector_dir = str(Path(cache_dir) / "vectordb")
    Path(vector_dir).mkdir(parents=True, exist_ok=True)
    embedding_provider = _resolve_embedding_provider(payload=payload, vector_dir=vector_dir)
    embedding_client = _load_embedding_client(embedding_provider)(
        api_key=api_key,
        cache_dir=cache_dir,
    )
    segment_texts = [segment.descriptor_text for segment in segments]
    segment_embeddings = embedding_client.embed_batch(segment_texts)
    weighted_track_embedding = _weighted_embedding(segment_embeddings, segments)

    store = ChromaVectorStore(persist_dir=vector_dir)
    track_id = _stable_track_id(file_path)
    scan_version = f"{track_metadata.get('contentHash', '')}|{track_metadata.get('modifiedTime', '')}"
    store.upsert_segments(
        track_id=track_id,
        scan_version=scan_version,
        track_metadata={
            "file_path": file_path,
            "bpm": track_metadata.get("bpm") or analysis.get("estimated_bpm"),
            "musical_key": track_metadata.get("musicalKey") or analysis.get("estimated_key") or "",
            "genre": track_metadata.get("genre") or "",
            "duration_sec": track_metadata.get("duration") or 0,
        },
        segments=[
            {
                "segment_id": str(uuid.uuid4()),
                "segment_type": segment.segment_type,
                "start_sec": segment.start_sec,
                "end_sec": segment.end_sec,
                "energy_score": segment.energy_score,
                "descriptor_text": segment.descriptor_text,
                "embedding": embedding,
            }
            for segment, embedding in zip(segments, segment_embeddings)
        ],
    )

    return {
        "estimatedBPM": analysis["estimated_bpm"],
        "estimatedKey": analysis["estimated_key"],
        "brightness": analysis["brightness"],
        "onsetDensity": analysis["onset_density"],
        "rhythmicDensity": analysis["rhythmic_density"],
        "lowMidHighBalance": analysis["low_mid_high_balance"],
        "waveformPreview": analysis["waveform_preview"],
        "trackEmbedding": weighted_track_embedding,
        "segments": [
            {
                "segmentType": segment.segment_type,
                "startSec": segment.start_sec,
                "endSec": segment.end_sec,
                "energyScore": segment.energy_score,
                "descriptorText": segment.descriptor_text,
                "embedding": embedding,
            }
            for segment, embedding in zip(segments, segment_embeddings)
        ],
    }


def handle_query_similar(payload: dict[str, Any]) -> dict[str, Any]:
    if not payload.get("queryEmbedding"):
        return {"results": []}

    ChromaVectorStore = _load_vector_store()
    options = payload.get("options") or {}
    cache_dir = options.get("cacheDirectory") or str(Path.home() / ".soria-cache")
    vector_dir = str(Path(cache_dir) / "vectordb")
    Path(vector_dir).mkdir(parents=True, exist_ok=True)
    _resolve_embedding_provider(payload=payload, vector_dir=vector_dir)

    store = ChromaVectorStore(persist_dir=vector_dir)
    response = store.query(
        embedding=payload["queryEmbedding"],
        n_results=max(10, int(payload.get("limit") or 50) * 4),
        where=_build_where(payload.get("filters") or {}),
    )

    distances = (response.get("distances") or [[]])[0] if response.get("distances") else []
    metadatas = (response.get("metadatas") or [[]])[0] if response.get("metadatas") else []
    excluded_paths = set(payload.get("excludeTrackPaths") or [])

    results_by_track: dict[str, dict[str, Any]] = {}
    for metadata, distance in zip(metadatas, distances):
        file_path = str(metadata.get("file_path", ""))
        if not file_path or file_path in excluded_paths:
            continue
        similarity = 1.0 / (1.0 + float(distance))
        existing = results_by_track.get(file_path)
        if existing is None or similarity > float(existing["vectorSimilarity"]):
            results_by_track[file_path] = {"filePath": file_path, "vectorSimilarity": similarity}

    ordered = sorted(results_by_track.values(), key=lambda item: item["vectorSimilarity"], reverse=True)
    return {"results": ordered[: int(payload.get("limit") or 50)]}


def handle_healthcheck(payload: dict[str, Any]) -> dict[str, Any]:
    options = payload.get("options") or {}
    api_key = options.get("geminiAPIKey") or os.environ.get("GEMINI_API_KEY")
    cache_dir = options.get("cacheDirectory") or str(Path.home() / ".soria-cache")
    vector_dir = str(Path(cache_dir) / "vectordb")
    lock_info = _read_embedding_lock(vector_dir)
    return {
        "ok": True,
        "apiKeyConfigured": bool(api_key),
        "pythonExecutable": sys.executable,
        "workerScriptPath": str(Path(__file__).resolve()),
        "embeddingProviderLocked": lock_info["locked"],
        "embeddingProvider": lock_info["provider"],
        "dependencies": {
            "librosa": _module_available("librosa"),
            "chromadb": _module_available("chromadb"),
            "requests": _module_available("requests"),
        },
    }


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


def _weighted_embedding(embeddings: list[list[float] | None], segments: list[Any]) -> list[float] | None:
    weights = {"intro": 1.0, "middle": 3.0, "outro": 1.0}
    valid: list[tuple[np.ndarray, float]] = []
    for embedding, segment in zip(embeddings, segments):
        if not embedding:
            continue
        valid.append((np.array(embedding, dtype=np.float64), weights.get(segment.segment_type, 1.0)))

    if not valid:
        return None
    total_weight = sum(weight for _, weight in valid)
    aggregate = sum(vector * weight for vector, weight in valid) / total_weight
    norm = np.linalg.norm(aggregate)
    if norm > 0:
        aggregate = aggregate / norm
    return [float(value) for value in aggregate.tolist()]


def _stable_track_id(file_path: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, file_path))


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


def _load_embedding_client(provider: str):
    if provider == "google_embedding_2":
        from embedding.gemini_client import GeminiEmbeddingClient

        return GeminiEmbeddingClient
    if provider == "clap_embedding":
        from embedding.clap_client import CLAPEmbeddingClient

        return CLAPEmbeddingClient
    raise ValueError(f"Unsupported embedding provider: {provider}")


def _embedding_lock_path(vector_dir: str) -> Path:
    return Path(vector_dir) / ".embedding_provider.lock"


def _read_embedding_lock(vector_dir: str) -> dict[str, Any]:
    lock_path = _embedding_lock_path(vector_dir)
    if not lock_path.exists():
        return {"locked": False, "provider": None}
    try:
        payload = json.loads(lock_path.read_text(encoding="utf-8"))
    except Exception:
        return {"locked": False, "provider": None}
    provider = str(payload.get("provider") or "").strip() or None
    if provider is None:
        return {"locked": False, "provider": None}
    return {"locked": True, "provider": provider}


def _resolve_embedding_provider(payload: dict[str, Any], vector_dir: str) -> str:
    requested_provider = str(payload.get("options", {}).get("embeddingProvider") or "google_embedding_2").strip()
    if not requested_provider:
        requested_provider = "google_embedding_2"

    lock_path = _embedding_lock_path(vector_dir)
    lock_info = _read_embedding_lock(vector_dir)
    if lock_info["locked"]:
        locked_provider = str(lock_info["provider"])
        if requested_provider != locked_provider:
            raise ValueError(
                "This project already uses a different embedding provider for vector DB. "
                f"Locked: {locked_provider}, requested: {requested_provider}."
            )
        return locked_provider

    lock_path.write_text(json.dumps({"provider": requested_provider}), encoding="utf-8")
    return requested_provider


def _load_vector_store():
    from vectordb.chroma_store import ChromaVectorStore

    return ChromaVectorStore


def _print_json(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False))
    sys.stdout.flush()


if __name__ == "__main__":
    raise SystemExit(main())
