from __future__ import annotations

import hashlib
import json
import math
import os
import time
from pathlib import Path
from typing import Any, Callable

import requests


class GeminiEmbeddingClient:
    def __init__(
        self,
        api_key: str | None,
        cache_dir: str,
        model: str = "gemini-embedding-2-preview",
        progress_callback: Callable[[str, float | None], None] | None = None,
    ) -> None:
        self.api_key = api_key
        self.model = model
        self.api_version = "v1beta"
        self.cache_path = Path(cache_dir) / "embedding-cache"
        self.cache_path.mkdir(parents=True, exist_ok=True)
        self.batch_size = max(1, int(os.environ.get("SORIA_EMBED_BATCH_SIZE", "8")))
        self.session = requests.Session()
        self.timeout_sec = float(os.environ.get("SORIA_EMBED_TIMEOUT_SEC", "30"))
        self._last_error: str | None = None
        self._progress_callback = progress_callback

    def embed_batch(self, texts: list[str]) -> list[list[float] | None]:
        if not texts:
            return []
        if not self.api_key:
            self._last_error = "Google API key is missing."
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
            batch_number = (i // self.batch_size) + 1
            batch_count = max(1, math.ceil(len(pending) / self.batch_size))
            self._notify_progress(
                f"Embedding descriptor batch {batch_number}/{batch_count}",
                0.74 + (0.12 * batch_number / batch_count),
            )
            embedded = self._embed_batch_with_retry([item[1] for item in batch], batch_number=batch_number, batch_count=batch_count)
            for (index, text), vector in zip(batch, embedded):
                outputs[index] = vector
                if vector is not None:
                    self._write_cache(text, vector)
        return outputs

    def validate(self, probe_text: str) -> list[float] | None:
        if not self.api_key:
            self._last_error = "Google API key is missing."
            return None
        return self._embed_single_with_retry(probe_text)

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

    def _set_error(self, message: str | None) -> None:
        self._last_error = message

    def _notify_progress(self, message: str, fraction: float | None = None) -> None:
        if self._progress_callback is not None:
            self._progress_callback(message, fraction)

    def _read_api_error(self, response: requests.Response) -> str:
        try:
            body = response.json()
            if isinstance(body, dict):
                error = body.get("error")
                if isinstance(error, dict):
                    message = error.get("message")
                    if isinstance(message, str) and message:
                        return message
                    code = error.get("code")
                    status = error.get("status")
                    if code is not None or status is not None:
                        return f"code={code or ''} status={status or ''}".strip()
                if isinstance(error, str) and error:
                    return error
        except Exception:
            pass

        text = response.text.strip()
        if text:
            return text[:300]
        return f"HTTP {response.status_code}"

    def _api_versions(self) -> tuple[str, ...]:
        if self.api_version == "v1":
            return ("v1",)
        return ("v1", self.api_version)

    def _candidate_models(self) -> tuple[str, ...]:
        return (self.model,)

    def _build_url(self, api_version: str, operation: str, model: str) -> str:
        base = f"https://generativelanguage.googleapis.com/{api_version}/models"
        return f"{base}/{model}:{operation}?key={self.api_key}"

    def _extract_values(self, payload: dict[str, Any] | Any) -> list[float] | None:
        if not isinstance(payload, dict):
            return None

        values = payload.get("values")
        if isinstance(values, list):
            return [float(x) for x in values]

        nested = payload.get("embedding")
        if isinstance(nested, dict):
            values = nested.get("values")
            if isinstance(values, list):
                return [float(x) for x in values]
        return None

    def _embed_batch_with_retry(
        self,
        texts: list[str],
        batch_number: int = 1,
        batch_count: int = 1,
    ) -> list[list[float] | None]:
        # 한국어: 배치 요청으로 API 호출 횟수를 줄이고 대형 라이브러리 처리량을 높입니다.
        if len(texts) == 1:
            return [self._embed_single_with_retry(texts[0])]
        self._set_error(None)
        retries = 4
        should_fallback_to_single = False
        for model in self._candidate_models():
            payload = {"requests": [{"model": f"models/{model}", "content": {"parts": [{"text": text}]}} for text in texts]}
            for api_version in self._api_versions():
                url = self._build_url(api_version, "batchEmbedContents", model)
                for i in range(retries):
                    try:
                        r = self.session.post(url, json=payload, timeout=self.timeout_sec)
                        if r.status_code == 429:
                            self._set_error(f"Google API rate limited (HTTP {r.status_code})")
                            self._notify_progress(
                                f"Rate limited while embedding batch {batch_number}/{batch_count}; retrying in {1.5 * (i + 1):.1f}s",
                                0.78,
                            )
                            time.sleep(1.5 * (i + 1))
                            continue
                        if r.status_code >= 500:
                            if i == retries - 1:
                                return [None for _ in texts]
                            self._notify_progress(
                                f"Google API temporary failure for batch {batch_number}/{batch_count}; retrying",
                                0.78,
                            )
                            time.sleep(1.0 * (i + 1))
                            continue
                        if r.status_code >= 400:
                            if r.status_code in (404, 405, 501):
                                should_fallback_to_single = True
                                self._set_error(f"Batch endpoint not supported on model {model} version {api_version} (HTTP {r.status_code})")
                                self._notify_progress("Batch endpoint unavailable; switching to single descriptor requests", 0.80)
                                break
                            self._set_error(f"Google API returned {r.status_code}: {self._read_api_error(r)}")
                            if i == retries - 1:
                                return [None for _ in texts]
                            self._notify_progress(
                                f"Retrying batch {batch_number}/{batch_count} after Google API error",
                                0.78,
                            )
                            time.sleep(0.7 * (i + 1))
                            continue
                        body: dict[str, Any] = r.json()
                        embeddings = body.get("embeddings")
                        if not isinstance(embeddings, list):
                            return [None for _ in texts]
                        output: list[list[float] | None] = []
                        for item in embeddings:
                            values = self._extract_values(item)
                            output.append(values)
                        if len(output) != len(texts):
                            output.extend([None] * max(0, len(texts) - len(output)))
                        self._set_error(None)
                        self._notify_progress(
                            f"Embedded descriptor batch {batch_number}/{batch_count}",
                            0.82 + (0.08 * batch_number / max(batch_count, 1)),
                        )
                        return output
                    except Exception as exc:
                        self._set_error(f"Batch request error: {exc!s}")
                        if i == retries - 1:
                            return [None for _ in texts]
                        self._notify_progress(
                            f"Batch request error for batch {batch_number}/{batch_count}; retrying",
                            0.78,
                        )
                        time.sleep(0.8 * (i + 1))
                if should_fallback_to_single:
                    break
                if self._last_error and not should_fallback_to_single:
                    break

        if should_fallback_to_single:
            return [self._embed_single_with_retry(text) for text in texts]

        return [None for _ in texts]

    def _embed_single_with_retry(self, text: str) -> list[float] | None:
        payload = {"model": f"models/{self.model}", "content": {"parts": [{"text": text}]}}

        retries = 4
        self._set_error(None)
        for model in self._candidate_models():
            payload["model"] = f"models/{model}"
            for api_version in self._api_versions():
                url = self._build_url(api_version, "embedContent", model)
                for i in range(retries):
                    try:
                        r = self.session.post(url, json=payload, timeout=self.timeout_sec)
                        if r.status_code == 429:
                            self._set_error(f"Google API rate limited (HTTP {r.status_code})")
                            self._notify_progress(
                                f"Rate limited on single descriptor request; retrying in {1.5 * (i + 1):.1f}s",
                                0.80,
                            )
                            time.sleep(1.5 * (i + 1))
                            continue
                        if r.status_code >= 500:
                            if i == retries - 1:
                                self._set_error(f"Google API returned {r.status_code}")
                                return None
                            self._notify_progress("Temporary Google API failure; retrying descriptor request", 0.80)
                            time.sleep(1.0 * (i + 1))
                            continue
                        if r.status_code >= 400:
                            if r.status_code in (404, 405, 501):
                                self._set_error(f"Endpoint not supported on model {model} version {api_version} (HTTP {r.status_code})")
                                break
                            self._set_error(f"Google API returned {r.status_code}: {self._read_api_error(r)}")
                            if i == retries - 1:
                                return None
                            self._notify_progress("Retrying descriptor request after Google API error", 0.80)
                            time.sleep(0.7 * (i + 1))
                            continue
                        body: dict[str, Any] = r.json()
                        values = self._extract_values(body)
                        if values is not None:
                            self._set_error(None)
                            self._notify_progress("Embedded descriptor request", 0.88)
                            return values
                        return None
                    except Exception as exc:
                        self._set_error(f"Single request error: {exc!s}")
                        if i == retries - 1:
                            return None
                        self._notify_progress("Single descriptor request error; retrying", 0.80)
                        time.sleep(0.8 * (i + 1))
            # Try next model when the previous one is not available
            if self._last_error and "not supported" not in self._last_error.lower():
                break

        return None
