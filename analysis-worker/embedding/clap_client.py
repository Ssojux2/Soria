from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Callable

import numpy as np


class CLAPEmbeddingClient:
    def __init__(
        self,
        api_key: str | None,
        cache_dir: str,
        model: str = "laion/clap-htsat-unfused",
        progress_callback: Callable[[str, float | None], None] | None = None,
    ) -> None:
        _ = api_key
        self.model_name = model
        self.cache_path = Path(cache_dir) / "embedding-cache"
        self.cache_path.mkdir(parents=True, exist_ok=True)
        self._progress_callback = progress_callback
        self._last_error: str | None = None

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
        self.audio_sampling_rate = int(
            getattr(getattr(self._processor, "feature_extractor", None), "sampling_rate", 48_000)
        )
        self.audio_input_kind = "waveform"

    def embed_batch(self, texts: list[str]) -> list[list[float] | None]:
        return self.embed_text_batch(texts)

    def embed_text_batch(self, texts: list[str]) -> list[list[float] | None]:
        if not texts:
            return []

        outputs: list[list[float] | None] = [None] * len(texts)
        pending: list[tuple[int, str]] = []
        for index, text in enumerate(texts):
            cached = self._load_cache("text", text.encode("utf-8"))
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
                    self._write_cache("text", text.encode("utf-8"), vector)
        return outputs

    def embed_audio_batch(
        self,
        audio_payloads: list[np.ndarray],
        sample_rate: int | None = None,
        mime_type: str = "audio/wav",
    ) -> list[list[float] | None]:
        _ = mime_type
        if not audio_payloads:
            return []

        outputs: list[list[float] | None] = [None] * len(audio_payloads)
        pending: list[tuple[int, np.ndarray]] = []
        for index, audio in enumerate(audio_payloads):
            normalized_audio = np.asarray(audio, dtype=np.float32)
            cached = self._load_cache("audio", normalized_audio.tobytes())
            if cached is not None:
                outputs[index] = cached
            else:
                pending.append((index, normalized_audio))

        if pending:
            vectors = self._embed_audio_segments(
                [item[1] for item in pending],
                sample_rate=sample_rate or self.audio_sampling_rate,
            )
            for (index, audio), vector in zip(pending, vectors):
                outputs[index] = vector
                if vector is not None:
                    self._write_cache("audio", audio.tobytes(), vector)
        return outputs

    def validate(self, probe_text: str) -> list[float] | None:
        return self._embed_texts([probe_text])[0]

    def validate_audio(self, audio_bytes: bytes, mime_type: str = "audio/wav") -> list[float] | None:
        _ = mime_type
        waveform = np.frombuffer(audio_bytes, dtype=np.uint8)
        if waveform.size == 0:
            return None
        # Validation only needs to prove the audio feature path is operational.
        probe = np.sin(np.linspace(0.0, np.pi * 4, self.audio_sampling_rate, dtype=np.float32)) * 0.1
        return self._embed_audio_segments([probe], sample_rate=self.audio_sampling_rate)[0]

    def _notify_progress(self, message: str, fraction: float | None = None) -> None:
        if self._progress_callback is not None:
            self._progress_callback(message, fraction)

    def _set_error(self, message: str | None) -> None:
        self._last_error = message

    def _embed_texts(self, texts: list[str]) -> list[list[float] | None]:
        try:
            self._set_error(None)
            self._notify_progress("Embedding text queries locally with CLAP", 0.80)
            inputs = self._processor(text=texts, return_tensors="pt", padding=True, truncation=True)
            with self._torch.no_grad():
                features = self._tensor_from_features(self._model.get_text_features(**inputs))
            features = self._torch.nn.functional.normalize(features, dim=-1)
            self._notify_progress("Local CLAP text embeddings ready", 0.90)
            return [[float(v) for v in row] for row in features.cpu().tolist()]
        except Exception as exc:
            self._set_error(str(exc))
            return [None for _ in texts]

    def _embed_audio_segments(
        self,
        audio_segments: list[np.ndarray],
        sample_rate: int,
    ) -> list[list[float] | None]:
        try:
            self._set_error(None)
            self._notify_progress("Embedding audio segments locally with CLAP", 0.80)
            normalized_segments = [np.asarray(segment, dtype=np.float32) for segment in audio_segments]
            inputs = self._processor_audio_inputs(normalized_segments, sample_rate)
            with self._torch.no_grad():
                features = self._tensor_from_features(self._model.get_audio_features(**inputs))
            features = self._torch.nn.functional.normalize(features, dim=-1)
            self._notify_progress("Local CLAP audio embeddings ready", 0.90)
            return [[float(v) for v in row] for row in features.cpu().tolist()]
        except Exception as exc:
            self._set_error(str(exc))
            return [None for _ in audio_segments]

    def _tensor_from_features(self, features):
        if isinstance(features, self._torch.Tensor):
            return features

        pooler_output = getattr(features, "pooler_output", None)
        if pooler_output is not None:
            return pooler_output

        if isinstance(features, tuple) and features:
            first_item = features[0]
            if isinstance(first_item, self._torch.Tensor):
                return first_item

        raise TypeError(f"Unsupported CLAP feature output type: {type(features)!r}")

    def _processor_audio_inputs(self, audio_segments: list[np.ndarray], sample_rate: int):
        processor_kwargs = {
            "sampling_rate": sample_rate,
            "return_tensors": "pt",
            "padding": True,
        }
        try:
            return self._processor(audio=audio_segments, **processor_kwargs)
        except TypeError as exc:
            if "unexpected keyword argument 'audio'" not in str(exc):
                raise
        return self._processor(audios=audio_segments, **processor_kwargs)

    def _cache_key(self, kind: str, payload: bytes) -> str:
        return hashlib.sha256((self.model_name + "::" + kind + "::").encode("utf-8") + payload).hexdigest()

    def _load_cache(self, kind: str, payload: bytes) -> list[float] | None:
        cache_file = self.cache_path / f"{self._cache_key(kind, payload)}.json"
        if not cache_file.exists():
            return None
        try:
            raw_payload = json.loads(cache_file.read_text(encoding="utf-8"))
            if isinstance(raw_payload, list):
                return [float(value) for value in raw_payload]
        except Exception:
            return None
        return None

    def _write_cache(self, kind: str, payload: bytes, vector: list[float]) -> None:
        cache_file = self.cache_path / f"{self._cache_key(kind, payload)}.json"
        cache_file.write_text(json.dumps(vector), encoding="utf-8")
