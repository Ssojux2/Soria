from __future__ import annotations

import hashlib
import json
import os
import time
from pathlib import Path
from typing import Any

import requests


class GeminiEmbeddingClient:
    def __init__(self, api_key: str | None, cache_dir: str, model: str = "text-embedding-004") -> None:
        self.api_key = api_key
        self.model = model
        self.api_version = "v1beta"
        self.cache_path = Path(cache_dir) / "embedding-cache"
        self.cache_path.mkdir(parents=True, exist_ok=True)
        self.batch_size = max(1, int(os.environ.get("SORIA_EMBED_BATCH_SIZE", "8")))
        self.session = requests.Session()
        self.timeout_sec = float(os.environ.get("SORIA_EMBED_TIMEOUT_SEC", "30"))

    def embed_batch(self, texts: list[str]) -> list[list[float] | None]:
        if not texts:
            return []
        if not self.api_key:
            return [None for _ in texts]

        outputs: list[list[float] | None] = [None] * len(texts)
        pending: list[tuple[int, str]] = []
        for index, text in enumerate(texts):
            cached = self._load_cache(text)
            if cached is not None:
                outputs[index] = cached
            else:
                pending.append((index, text))

        for i in range(0, len(pending), self.batch_size):
            batch = pending[i : i + self.batch_size]
            embedded = self._embed_batch_with_retry([item[1] for item in batch])
            for (index, text), vector in zip(batch, embedded):
                outputs[index] = vector
                if vector is not None:
                    self._write_cache(text, vector)
        return outputs

    def _cache_key(self, text: str) -> str:
        return hashlib.sha256((self.api_version + "::" + self.model + "::" + text).encode("utf-8")).hexdigest()

    def _load_cache(self, text: str) -> list[float] | None:
        h = self._cache_key(text)
        cache_file = self.cache_path / f"{h}.json"
        if cache_file.exists():
            try:
                return json.loads(cache_file.read_text(encoding="utf-8"))
            except Exception:
                return None
        return None

    def _write_cache(self, text: str, vector: list[float]) -> None:
        h = self._cache_key(text)
        cache_file = self.cache_path / f"{h}.json"
        cache_file.write_text(json.dumps(vector), encoding="utf-8")

    def _embed_batch_with_retry(self, texts: list[str]) -> list[list[float] | None]:
        # 한국어: 배치 요청으로 API 호출 횟수를 줄이고 대형 라이브러리 처리량을 높입니다.
        if len(texts) == 1:
            return [self._embed_single_with_retry(texts[0])]
        base = f"https://generativelanguage.googleapis.com/{self.api_version}/models"
        url = f"{base}/{self.model}:batchEmbedContents?key={self.api_key}"
        requests_payload = [
            {
                "model": f"models/{self.model}",
                "content": {"parts": [{"text": text}]},
            }
            for text in texts
        ]
        payload = {"requests": requests_payload}

        retries = 4
        for i in range(retries):
            try:
                r = self.session.post(url, json=payload, timeout=self.timeout_sec)
                if r.status_code == 429:
                    time.sleep(1.5 * (i + 1))
                    continue
                if r.status_code >= 500:
                    if i == retries - 1:
                        return [None for _ in texts]
                    time.sleep(1.0 * (i + 1))
                    continue
                if r.status_code >= 400:
                    if r.status_code in (404, 405, 501):
                        return [self._embed_single_with_retry(text) for text in texts]
                    if i == retries - 1:
                        return [None for _ in texts]
                    time.sleep(0.7 * (i + 1))
                    continue
                body: dict[str, Any] = r.json()
                embeddings = body.get("embeddings")
                if not isinstance(embeddings, list):
                    return [None for _ in texts]
                output: list[list[float] | None] = []
                for item in embeddings:
                    values = (item or {}).get("values")
                    if isinstance(values, list):
                        output.append([float(x) for x in values])
                    else:
                        output.append(None)
                if len(output) != len(texts):
                    output.extend([None] * max(0, len(texts) - len(output)))
                return output
            except Exception:
                if i == retries - 1:
                    return [None for _ in texts]
                time.sleep(0.8 * (i + 1))
        return [None for _ in texts]

    def _embed_single_with_retry(self, text: str) -> list[float] | None:
        base = f"https://generativelanguage.googleapis.com/{self.api_version}/models"
        url = f"{base}/{self.model}:embedContent?key={self.api_key}"
        payload = {"model": f"models/{self.model}", "content": {"parts": [{"text": text}]}}

        retries = 4
        for i in range(retries):
            try:
                r = self.session.post(url, json=payload, timeout=self.timeout_sec)
                if r.status_code == 429:
                    time.sleep(1.5 * (i + 1))
                    continue
                if r.status_code >= 500:
                    if i == retries - 1:
                        return None
                    time.sleep(1.0 * (i + 1))
                    continue
                if r.status_code >= 400:
                    if i == retries - 1:
                        return None
                    time.sleep(0.7 * (i + 1))
                    continue
                body: dict[str, Any] = r.json()
                values = body.get("embedding", {}).get("values")
                if isinstance(values, list):
                    return [float(x) for x in values]
                return None
            except Exception:
                if i == retries - 1:
                    return None
                time.sleep(0.8 * (i + 1))
        return None
