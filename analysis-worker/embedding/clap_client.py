from __future__ import annotations

import hashlib
import json
from pathlib import Path


class CLAPEmbeddingClient:
    def __init__(self, api_key: str | None, cache_dir: str, model: str = "laion/clap-htsat-unfused") -> None:
        self.model_name = model
        self.cache_path = Path(cache_dir) / "embedding-cache"
        self.cache_path.mkdir(parents=True, exist_ok=True)

        try:
            import torch
            from transformers import AutoProcessor, ClapModel
        except Exception as exc:
            raise RuntimeError(
                "CLAP embedding requires `torch` and `transformers`. "
                "Install them in analysis-worker venv before using CLAP mode."
            ) from exc

        self._torch = torch
        self._processor = AutoProcessor.from_pretrained(self.model_name)
        self._model = ClapModel.from_pretrained(self.model_name)
        self._model.eval()

    def embed_batch(self, texts: list[str]) -> list[list[float] | None]:
        if not texts:
            return []

        outputs: list[list[float] | None] = [None] * len(texts)
        pending: list[tuple[int, str]] = []
        for index, text in enumerate(texts):
            cached = self._load_cache(text)
            if cached is not None:
                outputs[index] = cached
            else:
                pending.append((index, text))

        if pending:
            pending_texts = [item[1] for item in pending]
            vectors = self._embed_texts(pending_texts)
            for (index, text), vector in zip(pending, vectors):
                outputs[index] = vector
                if vector is not None:
                    self._write_cache(text, vector)
        return outputs

    def validate(self, probe_text: str) -> list[float] | None:
        return self._embed_texts([probe_text])[0]

    def _embed_texts(self, texts: list[str]) -> list[list[float] | None]:
        try:
            inputs = self._processor(text=texts, return_tensors="pt", padding=True, truncation=True)
            with self._torch.no_grad():
                features = self._model.get_text_features(**inputs)
            features = self._torch.nn.functional.normalize(features, dim=-1)
            return [[float(v) for v in row] for row in features.cpu().tolist()]
        except Exception:
            return [None for _ in texts]

    def _cache_key(self, text: str) -> str:
        return hashlib.sha256((self.model_name + "::" + text).encode("utf-8")).hexdigest()

    def _load_cache(self, text: str) -> list[float] | None:
        cache_file = self.cache_path / f"{self._cache_key(text)}.json"
        if not cache_file.exists():
            return None
        try:
            payload = json.loads(cache_file.read_text(encoding="utf-8"))
            if isinstance(payload, list):
                return [float(value) for value in payload]
        except Exception:
            return None
        return None

    def _write_cache(self, text: str, vector: list[float]) -> None:
        cache_file = self.cache_path / f"{self._cache_key(text)}.json"
        cache_file.write_text(json.dumps(vector), encoding="utf-8")
