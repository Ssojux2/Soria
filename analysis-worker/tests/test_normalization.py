from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

TESTS_ROOT = Path(__file__).resolve().parents[1]
if str(TESTS_ROOT) not in sys.path:
    sys.path.insert(0, str(TESTS_ROOT))

sf = pytest.importorskip("soundfile")

from audio.normalization import inspect_audio_normalization, normalize_audio_file


def _write_audio(
    path: Path,
    data: np.ndarray,
    samplerate: int,
    format_name: str,
    subtype: str,
    metadata: dict[str, str] | None = None,
) -> None:
    metadata = metadata or {}
    with sf.SoundFile(
        str(path),
        mode="w",
        samplerate=samplerate,
        channels=1 if data.ndim == 1 else data.shape[1],
        format=format_name,
        subtype=subtype,
    ) as destination:
        for key, value in metadata.items():
            setattr(destination, key, value)
        destination.write(data.astype(np.float32))


def test_inspect_audio_normalization_uses_largest_absolute_sample_across_channels(tmp_path: Path) -> None:
    path = tmp_path / "stereo.wav"
    samples = np.array(
        [
            [0.10, -0.25],
            [0.20, 0.40],
            [-0.75, 0.15],
            [0.30, -0.10],
        ],
        dtype=np.float32,
    )
    _write_audio(path, samples, samplerate=44_100, format_name="WAV", subtype="PCM_16")

    result = inspect_audio_normalization(str(path))

    assert result["state"] == "needsNormalize"
    assert result["peakAmplitude"] == pytest.approx(0.75, abs=5e-4)
    assert result["channelCount"] == 2


def test_inspect_audio_normalization_marks_supra_unity_absolute_peak_as_ready(tmp_path: Path) -> None:
    path = tmp_path / "supra-unity.wav"
    samples = np.array([0.10, -1.20, 0.35], dtype=np.float32)
    _write_audio(path, samples, samplerate=44_100, format_name="WAV", subtype="FLOAT")

    result = inspect_audio_normalization(str(path))

    assert result["state"] == "ready"
    assert result["peakAmplitude"] == pytest.approx(1.20, abs=1e-6)


def test_inspect_audio_normalization_marks_sub_unity_peak_as_needs_normalize(tmp_path: Path) -> None:
    path = tmp_path / "sub-unity.wav"
    samples = np.array([0.10, -0.9781, 0.35], dtype=np.float32)
    _write_audio(path, samples, samplerate=44_100, format_name="WAV", subtype="FLOAT")

    result = inspect_audio_normalization(str(path))

    assert result["state"] == "needsNormalize"
    assert result["peakAmplitude"] == pytest.approx(0.9781, abs=1e-6)


def test_normalize_audio_file_scales_peak_to_one(tmp_path: Path) -> None:
    input_path = tmp_path / "input.wav"
    output_path = tmp_path / "output.wav"
    samples = np.array([0.10, -0.20, 0.50, -0.80, 0.25], dtype=np.float32)
    _write_audio(input_path, samples, samplerate=44_100, format_name="WAV", subtype="PCM_16")

    result = normalize_audio_file(str(input_path), str(output_path))

    assert result["didNormalize"] is True
    assert result["state"] == "ready"
    assert result["normalizedPeakAmplitude"] == pytest.approx(1.0, abs=2e-4)
    normalized = inspect_audio_normalization(str(output_path))
    assert normalized["state"] == "ready"
    assert normalized["peakAmplitude"] == pytest.approx(1.0, abs=2e-4)


def test_normalize_audio_file_skips_silence(tmp_path: Path) -> None:
    input_path = tmp_path / "silent.wav"
    output_path = tmp_path / "silent-output.wav"
    samples = np.zeros(1_024, dtype=np.float32)
    _write_audio(input_path, samples, samplerate=44_100, format_name="WAV", subtype="PCM_16")

    result = normalize_audio_file(str(input_path), str(output_path))

    assert result["didNormalize"] is False
    assert result["state"] == "silent"
    assert not output_path.exists()


def test_normalize_audio_file_copies_wav_metadata(tmp_path: Path) -> None:
    input_path = tmp_path / "metadata.wav"
    output_path = tmp_path / "metadata-output.wav"
    metadata = {
        "title": "Peak Track",
        "artist": "Soria",
        "genre": "House",
    }
    samples = np.array([0.1, -0.2, 0.3, -0.4], dtype=np.float32)
    _write_audio(
        input_path,
        samples,
        samplerate=44_100,
        format_name="WAV",
        subtype="PCM_16",
        metadata=metadata,
    )

    result = normalize_audio_file(str(input_path), str(output_path))

    assert result["state"] == "ready"
    with sf.SoundFile(str(output_path)) as normalized:
        copied = normalized.copy_metadata()
    assert copied["title"] == "Peak Track"
    assert copied["artist"] == "Soria"
    assert copied["genre"] == "House"


def test_normalize_audio_file_round_trips_mp3_when_runtime_supports_it(tmp_path: Path) -> None:
    if "MP3" not in sf.available_formats():
        pytest.skip("MP3 format is not available in the current soundfile runtime.")
    if "MPEG_LAYER_III" not in sf.available_subtypes("MP3"):
        pytest.skip("MP3 write subtype is not available in the current soundfile runtime.")

    input_path = tmp_path / "input.mp3"
    output_path = tmp_path / "output.mp3"
    duration_sec = 0.5
    samplerate = 44_100
    t = np.linspace(0, duration_sec, int(duration_sec * samplerate), endpoint=False)
    samples = (0.25 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    _write_audio(
        input_path,
        samples,
        samplerate=samplerate,
        format_name="MP3",
        subtype="MPEG_LAYER_III",
    )

    result = normalize_audio_file(str(input_path), str(output_path))

    assert result["didNormalize"] is True
    assert result["state"] == "ready"
    inspected = inspect_audio_normalization(str(output_path))
    assert inspected["state"] == "ready"
