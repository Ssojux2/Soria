from __future__ import annotations

from pathlib import Path
from typing import Any, Callable

import numpy as np

try:
    import soundfile as sf
except ModuleNotFoundError as exc:  # pragma: no cover - exercised by runtime env
    sf = None
    _SOUNDFILE_IMPORT_ERROR = exc
else:
    _SOUNDFILE_IMPORT_ERROR = None


PEAK_TOLERANCE = 1e-4
BLOCK_SIZE = 65_536
SUPPORTED_EXTENSIONS = {".wav", ".aiff", ".aif", ".flac", ".mp3"}


def inspect_audio_normalization(
    file_path: str,
    progress_callback: Callable[[str, str, float | None], None] | None = None,
) -> dict[str, Any]:
    _ensure_soundfile()
    path = Path(file_path)

    if path.suffix.lower() not in SUPPORTED_EXTENSIONS:
        return _unsupported_result(detail=f"Unsupported file extension: {path.suffix or '(none)'}")

    with sf.SoundFile(file_path) as source:
        if progress_callback:
            progress_callback("inspect_audio", "Scanning peak amplitude", 0.35)
        metadata = source.copy_metadata() if hasattr(source, "copy_metadata") else {}
        peak = _scan_peak(source)
        source.seek(0)
        return _inspection_result(
            state=_state_for_peak(peak),
            peak=peak,
            source=source,
            has_metadata=bool(metadata),
            detail=None,
        )


def normalize_audio_file(
    file_path: str,
    output_path: str,
    progress_callback: Callable[[str, str, float | None], None] | None = None,
) -> dict[str, Any]:
    _ensure_soundfile()
    input_path = Path(file_path)
    output = Path(output_path)

    if input_path.suffix.lower() not in SUPPORTED_EXTENSIONS:
        return {
            "state": "unsupported",
            "originalPeakAmplitude": None,
            "normalizedPeakAmplitude": None,
            "appliedGain": None,
            "didNormalize": False,
            "outputPath": None,
            "formatName": None,
            "subtype": None,
            "endian": None,
            "sampleRate": None,
            "channelCount": None,
            "frameCount": None,
            "hasMetadata": False,
            "isLossy": False,
            "detailMessage": f"Unsupported file extension: {input_path.suffix or '(none)'}",
        }

    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        output.unlink()

    with sf.SoundFile(file_path) as source:
        if progress_callback:
            progress_callback("inspect_audio", "Scanning peak amplitude", 0.15)
        metadata = source.copy_metadata() if hasattr(source, "copy_metadata") else {}
        original_peak = _scan_peak(source)
        is_lossy = _is_lossy_format(source.format, source.subtype, input_path.suffix)
        state = _state_for_peak(original_peak)
        inspection = _inspection_result(
            state=state,
            peak=original_peak,
            source=source,
            has_metadata=bool(metadata),
            detail=None,
        )

        if state != "needsNormalize":
            return {
                "state": inspection["state"],
                "originalPeakAmplitude": original_peak,
                "normalizedPeakAmplitude": original_peak,
                "appliedGain": 1.0 if state == "ready" else None,
                "didNormalize": False,
                "outputPath": None,
                "formatName": inspection["formatName"],
                "subtype": inspection["subtype"],
                "endian": inspection["endian"],
                "sampleRate": inspection["sampleRate"],
                "channelCount": inspection["channelCount"],
                "frameCount": inspection["frameCount"],
                "hasMetadata": inspection["hasMetadata"],
                "isLossy": inspection["isLossy"],
                "detailMessage": inspection["detailMessage"],
            }

        source_format = source.format
        source_subtype = source.subtype
        source_endian = source.endian
        source_samplerate = source.samplerate
        source_channels = source.channels
        source_frames = source.frames

    best_peak: float | None = None
    best_gain: float | None = None
    best_detail: str | None = None
    attempts = 4 if is_lossy else 1
    gain = 1.0 / max(original_peak, np.finfo(np.float32).eps)

    for attempt_index in range(attempts):
        if progress_callback:
            progress_callback(
                "normalize_audio",
                f"Writing normalized audio ({attempt_index + 1}/{attempts})",
                0.45 + (0.35 * attempt_index / max(attempts, 1)),
            )
        _write_normalized_copy(
            file_path=file_path,
            output_path=str(output),
            gain=gain,
            format_name=source_format,
            subtype=source_subtype,
            endian=source_endian,
            metadata=metadata,
        )

        with sf.SoundFile(str(output)) as normalized_file:
            normalized_peak = _scan_peak(normalized_file)
            best_peak = normalized_peak
            best_gain = gain
            best_detail = _validate_output(
                source_format=source_format,
                source_subtype=source_subtype,
                source_endian=source_endian,
                source_samplerate=source_samplerate,
                source_channels=source_channels,
                normalized_file=normalized_file,
            )
            if best_detail:
                break

        if best_peak is None or best_peak <= 0 or _state_for_peak(best_peak) == "ready":
            break
        gain *= 1.0 / best_peak

    final_state = "failed"
    if best_peak is not None and not best_detail and _state_for_peak(best_peak) == "ready":
        final_state = "ready"
    final_detail = best_detail
    if final_state == "failed" and final_detail is None:
        final_detail = "Normalized output failed peak validation."

    return {
        "state": final_state,
        "originalPeakAmplitude": original_peak,
        "normalizedPeakAmplitude": best_peak,
        "appliedGain": best_gain,
        "didNormalize": final_state == "ready",
        "outputPath": str(output) if final_state == "ready" else None,
        "formatName": source_format,
        "subtype": source_subtype,
        "endian": source_endian,
        "sampleRate": source_samplerate,
        "channelCount": source_channels,
        "frameCount": source_frames,
        "hasMetadata": bool(metadata),
        "isLossy": is_lossy,
        "detailMessage": final_detail,
    }


def _ensure_soundfile() -> None:
    if sf is None:
        raise RuntimeError(
            "soundfile is not installed. Create the analysis-worker venv and install "
            "analysis-worker/requirements.txt before running normalization."
        ) from _SOUNDFILE_IMPORT_ERROR


def _write_normalized_copy(
    file_path: str,
    output_path: str,
    gain: float,
    format_name: str,
    subtype: str,
    endian: str,
    metadata: dict[str, str],
) -> None:
    with sf.SoundFile(file_path) as source:
        with sf.SoundFile(
            output_path,
            mode="w",
            samplerate=source.samplerate,
            channels=source.channels,
            format=format_name,
            subtype=subtype,
            endian=endian,
        ) as destination:
            for key, value in metadata.items():
                try:
                    setattr(destination, key, value)
                except Exception:
                    continue

            for block in source.blocks(blocksize=BLOCK_SIZE, dtype="float32", always_2d=True):
                normalized = np.clip(block * gain, -1.0, 1.0)
                destination.write(normalized)


def _scan_peak(source: Any) -> float:
    source.seek(0)
    peak = 0.0
    for block in source.blocks(blocksize=BLOCK_SIZE, dtype="float32", always_2d=True):
        if block.size == 0:
            continue
        block_peak = float(np.max(np.abs(block)))
        if block_peak > peak:
            peak = block_peak
    source.seek(0)
    return peak


def _state_for_peak(peak: float) -> str:
    if not np.isfinite(peak) or peak < 0:
        return "failed"
    if peak == 0:
        return "silent"
    if peak + PEAK_TOLERANCE >= 1.0:
        return "ready"
    return "needsNormalize"


def _is_lossy_format(format_name: str | None, subtype: str | None, suffix: str) -> bool:
    normalized_format = (format_name or "").strip().upper()
    normalized_subtype = (subtype or "").strip().upper()
    normalized_suffix = suffix.strip().lower()
    return normalized_format == "MP3" or normalized_subtype.startswith("MPEG_") or normalized_suffix == ".mp3"


def _inspection_result(
    state: str,
    peak: float | None,
    source: Any,
    has_metadata: bool,
    detail: str | None,
) -> dict[str, Any]:
    return {
        "state": state,
        "peakAmplitude": peak,
        "formatName": source.format,
        "subtype": source.subtype,
        "endian": source.endian,
        "sampleRate": source.samplerate,
        "channelCount": source.channels,
        "frameCount": source.frames,
        "hasMetadata": has_metadata,
        "isLossy": _is_lossy_format(source.format, source.subtype, ""),
        "detailMessage": detail,
    }


def _unsupported_result(detail: str) -> dict[str, Any]:
    return {
        "state": "unsupported",
        "peakAmplitude": None,
        "formatName": None,
        "subtype": None,
        "endian": None,
        "sampleRate": None,
        "channelCount": None,
        "frameCount": None,
        "hasMetadata": False,
        "isLossy": False,
        "detailMessage": detail,
    }


def _validate_output(
    source_format: str,
    source_subtype: str,
    source_endian: str,
    source_samplerate: int,
    source_channels: int,
    normalized_file: Any,
) -> str | None:
    if normalized_file.format != source_format:
        return f"Output format mismatch: expected {source_format}, got {normalized_file.format}."
    if normalized_file.subtype != source_subtype:
        return f"Output subtype mismatch: expected {source_subtype}, got {normalized_file.subtype}."
    if normalized_file.endian != source_endian:
        return f"Output endian mismatch: expected {source_endian}, got {normalized_file.endian}."
    if normalized_file.samplerate != source_samplerate:
        return f"Output sample rate mismatch: expected {source_samplerate}, got {normalized_file.samplerate}."
    if normalized_file.channels != source_channels:
        return f"Output channel count mismatch: expected {source_channels}, got {normalized_file.channels}."
    return None
