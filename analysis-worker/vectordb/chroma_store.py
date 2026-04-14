from __future__ import annotations

import re
from typing import Any

try:
    import chromadb
    from chromadb.config import Settings
except ModuleNotFoundError as exc:  # pragma: no cover - depends on local env
    chromadb = None
    Settings = None
    _CHROMA_IMPORT_ERROR = exc
else:
    _CHROMA_IMPORT_ERROR = None


class ChromaVectorStore:
    COLLECTION_KEYS = ("tracks", "intro", "middle", "outro")
    SCORE_FIELDS = {
        "tracks": "trackScore",
        "intro": "introScore",
        "middle": "middleScore",
        "outro": "outroScore",
    }

    def __init__(self, persist_dir: str, profile_id: str) -> None:
        if chromadb is None or Settings is None:
            raise RuntimeError(
                "chromadb is not installed. Create the analysis-worker venv and install "
                "analysis-worker/requirements.txt before using vector search."
            ) from _CHROMA_IMPORT_ERROR

        self.client = chromadb.PersistentClient(path=persist_dir, settings=Settings(anonymized_telemetry=False))
        self.profile_id = profile_id
        self.profile_slug = sanitize_profile_id(profile_id)
        self.collections = {
            key: self.client.get_or_create_collection(self._collection_name(key))
            for key in self.COLLECTION_KEYS
        }

    def upsert_track_embeddings(
        self,
        track_id: str,
        scan_version: str,
        track_metadata: dict[str, Any] | None,
        track_embedding: list[float] | None,
        segments: list[dict[str, Any]],
    ) -> None:
        track_metadata = track_metadata or {}
        self.delete_track(track_id)

        base_metadata = {
            "track_id": track_id,
            "app_track_id": str(track_metadata.get("app_track_id", "") or ""),
            "file_path": str(track_metadata.get("file_path", "") or ""),
            "bpm": float(track_metadata.get("bpm")) if track_metadata.get("bpm") is not None else -1.0,
            "musical_key": str(track_metadata.get("musical_key", "") or ""),
            "genre": str(track_metadata.get("genre", "") or ""),
            "duration_sec": float(track_metadata.get("duration_sec", 0) or 0),
            "scan_version": scan_version,
        }

        if track_embedding:
            descriptor_document = " ".join(
                str(segment.get("descriptor_text", "") or "")
                for segment in segments
                if str(segment.get("descriptor_text", "") or "").strip()
            )
            self.collections["tracks"].upsert(
                ids=[f"{track_id}::track"],
                embeddings=[track_embedding],
                metadatas=[{**base_metadata, "collection_key": "tracks"}],
                documents=[descriptor_document or base_metadata["file_path"]],
            )

        grouped: dict[str, list[dict[str, Any]]] = {key: [] for key in self.COLLECTION_KEYS if key != "tracks"}
        for segment in segments:
            collection_key = str(segment.get("segment_type", "") or "").strip()
            if collection_key not in grouped:
                continue
            embedding = segment.get("embedding")
            if not embedding:
                continue
            grouped[collection_key].append(segment)

        for collection_key, collection_segments in grouped.items():
            if not collection_segments:
                continue

            ids: list[str] = []
            embeddings: list[list[float]] = []
            metadatas: list[dict[str, Any]] = []
            documents: list[str] = []
            for segment in collection_segments:
                ids.append(str(segment["segment_id"]))
                embeddings.append(segment["embedding"])
                metadatas.append(
                    {
                        **base_metadata,
                        "collection_key": collection_key,
                        "segment_type": collection_key,
                        "start_sec": float(segment["start_sec"]),
                        "end_sec": float(segment["end_sec"]),
                        "energy_score": float(segment["energy_score"]),
                    }
                )
                documents.append(str(segment["descriptor_text"]))

            self.collections[collection_key].upsert(
                ids=ids,
                embeddings=embeddings,
                metadatas=metadatas,
                documents=documents,
            )

    def delete_track(self, track_id: str) -> None:
        for collection in self.collections.values():
            collection.delete(where={"track_id": track_id})

    def search(
        self,
        query_embeddings: dict[str, list[float]],
        weights: dict[str, float],
        n_results: int = 20,
        where: dict[str, Any] | None = None,
    ) -> list[dict[str, Any]]:
        aggregated: dict[str, dict[str, Any]] = {}

        for collection_key, query_embedding in query_embeddings.items():
            if collection_key not in self.collections or not query_embedding:
                continue

            response = self.collections[collection_key].query(
                query_embeddings=[query_embedding],
                n_results=n_results,
                where=where,
                include=["metadatas", "distances"],
            )
            distances = (response.get("distances") or [[]])[0] if response.get("distances") else []
            metadatas = (response.get("metadatas") or [[]])[0] if response.get("metadatas") else []

            best_by_path: dict[str, tuple[dict[str, Any], float]] = {}
            for metadata, distance in zip(metadatas, distances):
                file_path = str(metadata.get("file_path", "") or "")
                if not file_path:
                    continue
                similarity = 1.0 / (1.0 + float(distance))
                current = best_by_path.get(file_path)
                if current is None or similarity > current[1]:
                    best_by_path[file_path] = (metadata, similarity)

            for file_path, (metadata, similarity) in best_by_path.items():
                entry = aggregated.setdefault(
                    file_path,
                    {
                        "trackID": str(metadata.get("app_track_id") or metadata.get("track_id") or ""),
                        "filePath": file_path,
                        "fusedScore": 0.0,
                        "trackScore": 0.0,
                        "introScore": 0.0,
                        "middleScore": 0.0,
                        "outroScore": 0.0,
                        "bestMatchedCollection": collection_key,
                    },
                )
                score_field = self.SCORE_FIELDS[collection_key]
                entry[score_field] = max(float(entry[score_field]), similarity)
                entry["fusedScore"] = float(entry["fusedScore"]) + float(weights.get(collection_key, 0.0)) * similarity

                best_collection = str(entry["bestMatchedCollection"])
                best_field = self.SCORE_FIELDS[best_collection]
                if similarity > float(entry[best_field]):
                    entry["bestMatchedCollection"] = collection_key

        return sorted(aggregated.values(), key=lambda item: float(item["fusedScore"]), reverse=True)

    def _collection_name(self, key: str) -> str:
        return f"{key}__{self.profile_slug}"


def sanitize_profile_id(profile_id: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9._-]+", "_", profile_id).strip("._-")
    return slug or "default_profile"
