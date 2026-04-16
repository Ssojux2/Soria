from __future__ import annotations

import base64
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
        self.audio_sampling_rate = 16_000
        self.audio_input_kind = "wav_bytes"
        self._last_error: str | None = None
        self._progress_callback = progress_callback

    def embed_batch(self, texts: list[str]) -> list[list[float] | None]:
        return self.embed_text_batch(texts)

    def embed_text_batch(self, texts: list[str]) -> list[list[float] | None]:
        if not texts:
            return []
        if not self.api_key:
            self._last_error = "Google API key is missing."
            return [None for _ in texts]

        outputs: list[list[float] | None] = [None] * len(texts)
        pending: list[tuple[int, str]] = []
        for index, text in enumerate(texts):
            cached = self._load_cache("text", text.encode("utf-8"))
            if cached is not None:
                outputs[index] = cached
            else:
                pending.append((index, text))

        for i in range(0, len(pending), self.batch_size):
            batch = pending[i : i + self.batch_size]
            batch_number = (i // self.batch_size) + 1
            batch_count = max(1, math.ceil(len(pending) / self.batch_size))
            self._notify_progress(
                f"Embedding text batch {batch_number}/{batch_count}",
                0.74 + (0.12 * batch_number / batch_count),
            )
            embedded = self._embed_text_batch_with_retry(
                [item[1] for item in batch],
                batch_number=batch_number,
                batch_count=batch_count,
            )
            for (index, text), vector in zip(batch, embedded):
                outputs[index] = vector
                if vector is not None:
                    self._write_cache("text", text.encode("utf-8"), vector)
        return outputs

    def embed_audio_batch(
        self,
        audio_payloads: list[bytes],
        sample_rate: int | None = None,
        mime_type: str = "audio/wav",
    ) -> list[list[float] | None]:
        _ = sample_rate
        if not audio_payloads:
            return []
        if not self.api_key:
            self._last_error = "Google API key is missing."
            return [None for _ in audio_payloads]

        outputs: list[list[float] | None] = [None] * len(audio_payloads)
        for index, audio_bytes in enumerate(audio_payloads, start=1):
            cached = self._load_cache("audio", audio_bytes)
            if cached is not None:
                outputs[index - 1] = cached
                continue

            self._notify_progress(
                f"Embedding audio segment {index}/{len(audio_payloads)}",
                0.76 + (0.12 * index / max(len(audio_payloads), 1)),
            )
            vector = self._embed_single_audio_with_retry(
                audio_bytes=audio_bytes,
                mime_type=mime_type,
                segment_index=index,
                segment_count=len(audio_payloads),
            )
            outputs[index - 1] = vector
            if vector is not None:
                self._write_cache("audio", audio_bytes, vector)
        return outputs

    def validate(self, probe_text: str) -> list[float] | None:
        return self._embed_single_text_with_retry(probe_text)

    def validate_audio(self, audio_bytes: bytes, mime_type: str = "audio/wav") -> list[float] | None:
        if not self.api_key:
            self._last_error = "Google API key is missing."
            return None
        return self._embed_single_audio_with_retry(audio_bytes, mime_type, segment_index=1, segment_count=1)

    def _cache_key(self, kind: str, payload: bytes) -> str:
        return hashlib.sha256(
            (self.api_version + "::" + self.model + "::" + kind + "::").encode("utf-8") + payload
        ).hexdigest()

    def _load_cache(self, kind: str, payload: bytes) -> list[float] | None:
        cache_file = self.cache_path / f"{self._cache_key(kind, payload)}.json"
        if cache_file.exists():
            try:
                return json.loads(cache_file.read_text(encoding="utf-8"))
            except Exception:
                return None
        return None

    def _write_cache(self, kind: str, payload: bytes, vector: list[float]) -> None:
        cache_file = self.cache_path / f"{self._cache_key(kind, payload)}.json"
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

    def _embed_text_batch_with_retry(
        self,
        texts: list[str],
        batch_number: int = 1,
        batch_count: int = 1,
    ) -> list[list[float] | None]:
        if len(texts) == 1:
            return [self._embed_single_text_with_retry(texts[0])]

        retries = 4
        should_fallback_to_single = False
        self._set_error(None)
        for model in self._candidate_models():
            payload = {
                "requests": [
                    {
                        "model": f"models/{model}",
                        "content": {"parts": [{"text": text}]},
                    }
                    for text in texts
                ]
            }
            for api_version in self._api_versions():
                url = self._build_url(api_version, "batchEmbedContents", model)
                for i in range(retries):
                    try:
                        response = self.session.post(url, json=payload, timeout=self.timeout_sec)
                        if response.status_code == 429:
                            self._set_error(f"Google API rate limited (HTTP {response.status_code})")
                            self._notify_progress(
                                f"Rate limited while embedding text batch {batch_number}/{batch_count}; retrying in {1.5 * (i + 1):.1f}s",
                                0.78,
                            )
                            time.sleep(1.5 * (i + 1))
                            continue
                        if response.status_code >= 500:
                            if i == retries - 1:
                                return [None for _ in texts]
                            self._notify_progress(
                                f"Google API temporary failure for text batch {batch_number}/{batch_count}; retrying",
                                0.78,
                            )
                            time.sleep(1.0 * (i + 1))
                            continue
                        if response.status_code >= 400:
                            if response.status_code in (404, 405, 501):
                                should_fallback_to_single = True
                                self._set_error(
                                    f"Batch endpoint not supported on model {model} version {api_version} (HTTP {response.status_code})"
                                )
                                self._notify_progress("Batch endpoint unavailable; switching to single text requests", 0.80)
                                break
                            self._set_error(f"Google API returned {response.status_code}: {self._read_api_error(response)}")
                            if i == retries - 1:
                                return [None for _ in texts]
                            self._notify_progress("Retrying text batch after Google API error", 0.78)
                            time.sleep(0.7 * (i + 1))
                            continue
                        body: dict[str, Any] = response.json()
                        embeddings = body.get("embeddings")
                        if not isinstance(embeddings, list):
                            return [None for _ in texts]
                        output: list[list[float] | None] = []
                        for item in embeddings:
                            output.append(self._extract_values(item))
                        if len(output) != len(texts):
                            output.extend([None] * max(0, len(texts) - len(output)))
                        self._set_error(None)
                        self._notify_progress(
                            f"Embedded text batch {batch_number}/{batch_count}",
                            0.82 + (0.08 * batch_number / max(batch_count, 1)),
                        )
                        return output
                    except Exception as exc:
                        self._set_error(f"Batch request error: {exc!s}")
                        if i == retries - 1:
                            return [None for _ in texts]
                        self._notify_progress("Text batch request error; retrying", 0.78)
                        time.sleep(0.8 * (i + 1))
                if should_fallback_to_single:
                    break
                if self._last_error and not should_fallback_to_single:
                    break

        if should_fallback_to_single:
            return [self._embed_single_text_with_retry(text) for text in texts]

        return [None for _ in texts]

    def _embed_single_text_with_retry(self, text: str) -> list[float] | None:
        payload = {"content": {"parts": [{"text": text}]}}
        retries = 4
        self._set_error(None)
        for model in self._candidate_models():
            url_payload = dict(payload)
            url_payload["model"] = f"models/{model}"
            for api_version in self._api_versions():
                url = self._build_url(api_version, "embedContent", model)
                for i in range(retries):
                    try:
                        response = self.session.post(url, json=url_payload, timeout=self.timeout_sec)
                        if response.status_code == 429:
                            self._set_error(f"Google API rate limited (HTTP {response.status_code})")
                            self._notify_progress(
                                f"Rate limited on single text request; retrying in {1.5 * (i + 1):.1f}s",
                                0.80,
                            )
                            time.sleep(1.5 * (i + 1))
                            continue
                        if response.status_code >= 500:
                            if i == retries - 1:
                                self._set_error(f"Google API returned {response.status_code}")
                                return None
                            self._notify_progress("Temporary Google API failure; retrying text request", 0.80)
                            time.sleep(1.0 * (i + 1))
                            continue
                        if response.status_code >= 400:
                            if response.status_code in (404, 405, 501):
                                self._set_error(
                                    f"Endpoint not supported on model {model} version {api_version} (HTTP {response.status_code})"
                                )
                                break
                            self._set_error(f"Google API returned {response.status_code}: {self._read_api_error(response)}")
                            if i == retries - 1:
                                return None
                            self._notify_progress("Retrying text request after Google API error", 0.80)
                            time.sleep(0.7 * (i + 1))
                            continue
                        body: dict[str, Any] = response.json()
                        values = self._extract_values(body)
                        if values is not None:
                            self._set_error(None)
                            self._notify_progress("Embedded text request", 0.88)
                            return values
                        return None
                    except Exception as exc:
                        self._set_error(f"Single request error: {exc!s}")
                        if i == retries - 1:
                            return None
                        self._notify_progress("Single text request error; retrying", 0.80)
                        time.sleep(0.8 * (i + 1))
            if self._last_error and "not supported" not in self._last_error.lower():
                break

        return None

    def _embed_single_audio_with_retry(
        self,
        audio_bytes: bytes,
        mime_type: str,
        segment_index: int,
        segment_count: int,
    ) -> list[float] | None:
        retries = 4
        encoded_audio = base64.b64encode(audio_bytes).decode("ascii")
        self._set_error(None)
        for model in self._candidate_models():
            payload = {
                "content": {
                    "parts": [
                        {
                            "inline_data": {
                                "mime_type": mime_type,
                                "data": encoded_audio,
                            }
                        }
                    ]
                }
            }
            for api_version in self._api_versions():
                url = self._build_url(api_version, "embedContent", model)
                for i in range(retries):
                    try:
                        response = self.session.post(url, json=payload, timeout=self.timeout_sec)
                        if response.status_code == 429:
                            self._set_error(f"Google API rate limited (HTTP {response.status_code})")
                            self._notify_progress(
                                f"Rate limited on audio segment {segment_index}/{segment_count}; retrying in {1.5 * (i + 1):.1f}s",
                                0.80,
                            )
                            time.sleep(1.5 * (i + 1))
                            continue
                        if response.status_code >= 500:
                            if i == retries - 1:
                                self._set_error(f"Google API returned {response.status_code}")
                                return None
                            self._notify_progress(
                                f"Temporary Google API failure on audio segment {segment_index}/{segment_count}; retrying",
                                0.80,
                            )
                            time.sleep(1.0 * (i + 1))
                            continue
                        if response.status_code >= 400:
                            if response.status_code in (404, 405, 501):
                                self._set_error(
                                    f"Endpoint not supported on model {model} version {api_version} (HTTP {response.status_code})"
                                )
                                break
                            self._set_error(f"Google API returned {response.status_code}: {self._read_api_error(response)}")
                            if i == retries - 1:
                                return None
                            self._notify_progress(
                                f"Retrying audio segment {segment_index}/{segment_count} after Google API error",
                                0.80,
                            )
                            time.sleep(0.7 * (i + 1))
                            continue
                        body: dict[str, Any] = response.json()
                        values = self._extract_values(body)
                        if values is not None:
                            self._set_error(None)
                            self._notify_progress(
                                f"Embedded audio segment {segment_index}/{segment_count}",
                                0.88,
                            )
                            return values
                        return None
                    except Exception as exc:
                        self._set_error(f"Audio request error: {exc!s}")
                        if i == retries - 1:
                            return None
                        self._notify_progress(
                            f"Audio request error on segment {segment_index}/{segment_count}; retrying",
                            0.80,
                        )
                        time.sleep(0.8 * (i + 1))
            if self._last_error and "not supported" not in self._last_error.lower():
                break

        return None
