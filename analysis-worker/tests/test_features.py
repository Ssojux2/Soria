from __future__ import annotations

import tempfile
import wave
from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("librosa")

from audio.features import analyze_track


def _write_test_wave(path: Path, samples: np.ndarray, sr: int) -> None:
    pcm = np.clip(samples * 32767.0, -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sr)
        wav_file.writeframes(pcm.tobytes())


def test_analyze_track_returns_three_segments() -> None:
    sr = 22050
    duration_sec = 40
    t = np.linspace(0, duration_sec, sr * duration_sec, endpoint=False)
    y = 0.07 * np.sin(2 * np.pi * 220 * t)
    y[12 * sr : 24 * sr] *= 4.2

    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "sample.wav"
        _write_test_wave(path, y, sr)
        result = analyze_track(
            str(path),
            {
                "genre": "House",
                "tags": ["Warmup", "Peak"],
                "playlistMemberships": ["Main Set"],
                "hasRekordboxMetadata": True,
            },
        )

    segments = result["segments"]
    assert len(segments) == 3
    assert {segment.segment_type for segment in segments} == {"intro", "middle", "outro"}
    assert len(result["waveform_preview"]) == 256
    assert result["waveform_envelope"]["binCount"] == 2048
    assert len(result["waveform_envelope"]["upperPeaks"]) == 2048
    assert len(result["waveform_envelope"]["lowerPeaks"]) == 2048
    assert result["brightness"] >= 0.0
    assert all("playlists=" not in segment.descriptor_text for segment in segments)
