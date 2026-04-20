from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

TESTS_ROOT = Path(__file__).resolve().parents[1]
if str(TESTS_ROOT) not in sys.path:
    sys.path.insert(0, str(TESTS_ROOT))

from audio.features import WAVEFORM_SOURCE_VERSION, _waveform_envelope, _waveform_preview


def test_waveform_envelope_v2_normalizes_bounds() -> None:
    waveform = np.array([0.0, 0.4, -0.8, 0.6, -0.2, 0.1], dtype=np.float32)

    result = _waveform_envelope(waveform, sr=6, bins=3)

    assert result["sourceVersion"] == WAVEFORM_SOURCE_VERSION
    assert result["binCount"] == 3
    assert len(result["upperPeaks"]) == 3
    assert len(result["lowerPeaks"]) == 3
    assert max(result["upperPeaks"]) == pytest.approx(0.75)
    assert min(result["lowerPeaks"]) == pytest.approx(-1.0)
    assert all(0.0 <= value <= 1.0 for value in result["upperPeaks"])
    assert all(-1.0 <= value <= 0.0 for value in result["lowerPeaks"])


def test_waveform_envelope_v2_handles_sparse_bins() -> None:
    waveform = np.array([0.5, -0.25], dtype=np.float32)

    result = _waveform_envelope(waveform, sr=2, bins=5)

    assert result["binCount"] == 5
    assert len(result["upperPeaks"]) == 5
    assert len(result["lowerPeaks"]) == 5
    assert max(result["upperPeaks"]) == pytest.approx(1.0)
    assert min(result["lowerPeaks"]) == pytest.approx(-0.5)
    assert sum(1 for value in result["upperPeaks"] if abs(value) > 1e-9) == 1
    assert sum(1 for value in result["lowerPeaks"] if abs(value) > 1e-9) == 1


def test_waveform_preview_v2_stays_normalized() -> None:
    waveform = np.array([0.0, 0.25, -1.0, 0.81], dtype=np.float32)

    preview = _waveform_preview(waveform, bins=4)

    assert len(preview) == 4
    assert preview == pytest.approx([0.0, 0.5, 1.0, 0.9])
    assert all(0.0 <= value <= 1.0 for value in preview)
