from __future__ import annotations

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
    def __init__(self, persist_dir: str) -> None:
        if chromadb is None or Settings is None:
            raise RuntimeError(
                "chromadb is not installed. Create the analysis-worker venv and install "
                "analysis-worker/requirements.txt before using vector search."
            ) from _CHROMA_IMPORT_ERROR
        self.client = chromadb.PersistentClient(path=persist_dir, settings=Settings(anonymized_telemetry=False))
        self.collection = self.client.get_or_create_collection("soria_segments")

    def upsert_segments(
        self,
        track_id: str,
        scan_version: str,
        segments: list[dict[str, Any]],
        track_metadata: dict[str, Any] | None = None,
    ) -> None:
        track_metadata = track_metadata or {}
        # 한국어: 동일 트랙 재분석 시 이전 세그먼트를 제거해 중복 결과를 방지합니다.
        self.collection.delete(where={"track_id": track_id})

        ids: list[str] = []
        embeddings: list[list[float]] = []
        metadatas: list[dict[str, Any]] = []
        docs: list[str] = []

        for segment in segments:
            emb = segment.get("embedding")
            if not emb:
                continue
            seg_id = segment["segment_id"]
            ids.append(seg_id)
            embeddings.append(emb)
            metadatas.append(
                {
                    "track_id": track_id,
                    "file_path": str(track_metadata.get("file_path", "")),
                    "bpm": float(track_metadata.get("bpm")) if track_metadata.get("bpm") is not None else -1.0,
                    "musical_key": str(track_metadata.get("musical_key", "") or ""),
                    "genre": str(track_metadata.get("genre", "") or ""),
                    "duration_sec": float(track_metadata.get("duration_sec", 0)),
                    "segment_type": segment["segment_type"],
                    "start_sec": float(segment["start_sec"]),
                    "end_sec": float(segment["end_sec"]),
                    "energy_score": float(segment["energy_score"]),
                    "scan_version": scan_version,
                }
            )
            docs.append(segment["descriptor_text"])

        if ids:
            self.collection.upsert(ids=ids, embeddings=embeddings, metadatas=metadatas, documents=docs)

    def query(
        self,
        embedding: list[float],
        n_results: int = 20,
        where: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        return self.collection.query(query_embeddings=[embedding], n_results=n_results, where=where, include=["metadatas", "distances"])
