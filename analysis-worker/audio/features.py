from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any

import numpy as np

try:
    import librosa
except ModuleNotFoundError as exc:  # pragma: no cover - exercised by runtime env
    librosa = None
    _LIBROSA_IMPORT_ERROR = exc
else:
    _LIBROSA_IMPORT_ERROR = None


@dataclass
class SegmentFeature:
    segment_type: str
    start_sec: float
    end_sec: float
    energy_score: float
    descriptor_text: str
    numeric_features: dict[str, float]


def analyze_track(file_path: str, track_metadata: dict[str, Any] | None = None) -> dict[str, Any]:
    _ensure_librosa()
    track_metadata = track_metadata or {}
    analysis_focus = _normalized_analysis_focus(track_metadata.get("analysisFocus"))

    y, sr = librosa.load(file_path, sr=22050, mono=True)
    if y.size == 0:
        raise ValueError("Empty audio file")

    frame_length = 2048
    hop_length = 512
    duration = y.size / sr
    rms = librosa.feature.rms(y=y, frame_length=frame_length, hop_length=hop_length)[0]
    onset_env = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop_length)
    spectral_flux = np.abs(np.diff(onset_env, prepend=onset_env[:1]))
    frame_times = librosa.frames_to_time(np.arange(rms.shape[0]), sr=sr, hop_length=hop_length)

    combined_energy = 0.72 * _normalize_array(rms) + 0.28 * _normalize_array(spectral_flux)
    middle_start, middle_end = _detect_middle_region(duration, sr, hop_length, combined_energy, frame_times)
    intro_start, intro_end, outro_start, outro_end = _derive_transition_regions(duration, middle_start, middle_end)
    intro_start, intro_end, middle_start, middle_end, outro_start, outro_end = _apply_analysis_focus(
        analysis_focus,
        duration,
        intro_start,
        intro_end,
        middle_start,
        middle_end,
        outro_start,
        outro_end,
    )

    segments = [
        ("intro", intro_start, intro_end),
        ("middle", middle_start, middle_end),
        ("outro", outro_start, outro_end),
    ]

    estimated_bpm = _safe_float(_estimate_bpm(y, sr))
    estimated_key = _estimate_key(y, sr)
    genre = (track_metadata.get("genre") or "").strip()
    has_serato = bool(track_metadata.get("hasSeratoMetadata") or False)
    has_rekordbox = bool(track_metadata.get("hasRekordboxMetadata") or False)
    overall_features = _extract_segment_features(y, sr)
    waveform_preview = _waveform_preview(y)
    energy_arc = _energy_arc_for_segments(segments, combined_energy, frame_times)
    mixability_tags = _build_mixability_tags(
        intro_length_sec=intro_end - intro_start,
        outro_length_sec=outro_end - outro_start,
        estimated_bpm=estimated_bpm,
        brightness=float(overall_features["brightness"]),
        rhythmic_density=float(overall_features["rhythmic_density"]),
        energy_arc=energy_arc,
        comment=track_metadata.get("comment"),
    )
    confidence = _estimate_confidence(
        duration=duration,
        estimated_bpm=estimated_bpm,
        estimated_key=estimated_key,
        cue_count=track_metadata.get("cueCount"),
        energy_arc=energy_arc,
    )

    segment_features: list[SegmentFeature] = []
    for segment_type, start_sec, end_sec in segments:
        start_sample = int(start_sec * sr)
        end_sample = int(end_sec * sr)
        segment_y = y[start_sample:end_sample]
        if segment_y.size < frame_length:
            segment_y = np.pad(segment_y, (0, max(0, frame_length - segment_y.size)))

        feature_map = _extract_segment_features(segment_y, sr)
        descriptor_text = _descriptor_text(
            segment_type=segment_type,
            bpm=track_metadata.get("bpm") or estimated_bpm,
            musical_key=track_metadata.get("musicalKey") or estimated_key,
            genre=genre,
            features=feature_map,
            has_serato=has_serato,
            has_rekordbox=has_rekordbox,
            tags=track_metadata.get("tags") or [],
            rating=track_metadata.get("rating"),
            play_count=track_metadata.get("playCount"),
            playlist_memberships=track_metadata.get("playlistMemberships") or [],
            cue_count=track_metadata.get("cueCount"),
            comment=track_metadata.get("comment"),
            analysis_focus=analysis_focus,
            mixability_tags=mixability_tags,
        )

        segment_features.append(
            SegmentFeature(
                segment_type=segment_type,
                start_sec=float(start_sec),
                end_sec=float(end_sec),
                energy_score=float(feature_map["energy"]),
                descriptor_text=descriptor_text,
                numeric_features=feature_map,
            )
        )

    return {
        "estimated_bpm": estimated_bpm,
        "estimated_key": estimated_key,
        "brightness": float(overall_features["brightness"]),
        "onset_density": float(overall_features["onset_density"]),
        "rhythmic_density": float(overall_features["rhythmic_density"]),
        "low_mid_high_balance": [
            float(overall_features["low_balance"]),
            float(overall_features["mid_balance"]),
            float(overall_features["high_balance"]),
        ],
        "waveform_preview": waveform_preview,
        "analysis_focus": analysis_focus,
        "intro_length_sec": float(max(0.0, intro_end - intro_start)),
        "outro_length_sec": float(max(0.0, outro_end - outro_start)),
        "energy_arc": energy_arc,
        "mixability_tags": mixability_tags,
        "confidence": confidence,
        "segments": segment_features,
    }


def _ensure_librosa() -> None:
    if librosa is None:
        raise RuntimeError(
            "librosa is not installed. Create the analysis-worker venv and install "
            "analysis-worker/requirements.txt before running analysis."
        ) from _LIBROSA_IMPORT_ERROR


def _detect_middle_region(
    duration: float,
    sr: int,
    hop_length: int,
    combined_energy: np.ndarray,
    frame_times: np.ndarray,
) -> tuple[float, float]:
    if duration <= 45:
        return max(0.0, duration * 0.2), max(duration * 0.8, duration * 0.35)

    window_sec = min(110.0, max(32.0, duration * 0.30))
    window_frames = max(8, int(window_sec * sr / hop_length))
    kernel = np.ones(window_frames, dtype=np.float64) / window_frames
    smoothed = np.convolve(combined_energy, kernel, mode="same")
    peak_index = int(np.argmax(smoothed))
    peak_time = float(frame_times[min(peak_index, len(frame_times) - 1)])

    start = max(0.0, min(duration - window_sec, peak_time - window_sec * 0.45))
    end = min(duration, start + window_sec)
    return start, end


def _derive_transition_regions(duration: float, middle_start: float, middle_end: float) -> tuple[float, float, float, float]:
    if duration <= 45:
        intro_end = max(6.0, duration * 0.2)
        outro_start = min(duration - 6.0, duration * 0.8)
        return 0.0, intro_end, max(intro_end, outro_start), duration

    intro_target = min(45.0, max(12.0, duration * 0.20))
    intro_end = min(max(10.0, middle_start), intro_target)
    if middle_start - intro_end < 4.0:
        intro_end = max(8.0, middle_start - 4.0)

    outro_target = max(duration - min(45.0, max(12.0, duration * 0.20)), middle_end)
    outro_start = max(middle_end, min(duration - 8.0, outro_target))
    if outro_start - middle_end < 4.0:
        outro_start = min(duration - 6.0, middle_end + 4.0)

    intro_end = min(intro_end, middle_start)
    outro_start = max(outro_start, middle_end)
    return 0.0, intro_end, outro_start, duration


def _normalized_analysis_focus(raw_value: Any) -> str:
    value = str(raw_value or "balanced").strip().lower()
    allowed = {"balanced", "transition_safe", "peak_time", "warm_up_deep", "outro_friendly"}
    return value if value in allowed else "balanced"


def _apply_analysis_focus(
    analysis_focus: str,
    duration: float,
    intro_start: float,
    intro_end: float,
    middle_start: float,
    middle_end: float,
    outro_start: float,
    outro_end: float,
) -> tuple[float, float, float, float, float, float]:
    intro_length = max(0.0, intro_end - intro_start)
    outro_length = max(0.0, outro_end - outro_start)

    if analysis_focus == "transition_safe":
        intro_end = min(middle_start, intro_start + intro_length * 1.15 + 4.0)
        outro_start = max(middle_end, outro_end - (outro_length * 1.15 + 4.0))
    elif analysis_focus == "peak_time":
        intro_end = min(middle_start, max(8.0, intro_start + intro_length * 0.82))
        outro_start = max(middle_end, min(duration - 6.0, outro_end - outro_length * 0.82))
    elif analysis_focus == "warm_up_deep":
        intro_end = min(middle_start, intro_start + intro_length * 1.20 + 6.0)
    elif analysis_focus == "outro_friendly":
        outro_start = max(middle_end, outro_end - (outro_length * 1.28 + 6.0))

    intro_end = max(intro_start + 4.0, min(intro_end, middle_start))
    outro_start = min(outro_end - 4.0, max(outro_start, middle_end))
    middle_start = max(intro_end, middle_start)
    middle_end = min(outro_start, middle_end)
    if middle_end <= middle_start:
        midpoint = duration / 2.0
        middle_start = min(max(intro_end, midpoint - 8.0), max(intro_end, duration * 0.4))
        middle_end = max(min(outro_start, midpoint + 8.0), min(outro_start, duration * 0.6))
    return intro_start, intro_end, middle_start, middle_end, outro_start, outro_end


def _estimate_bpm(y: np.ndarray, sr: int) -> float | None:
    try:
        tempo, _ = librosa.beat.beat_track(y=y, sr=sr)
        return float(tempo)
    except Exception:
        return None


def _estimate_key(y: np.ndarray, sr: int) -> str | None:
    try:
        chroma = librosa.feature.chroma_stft(y=y, sr=sr)
        profile = chroma.mean(axis=1)
        note_index = int(np.argmax(profile))
        keys = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return keys[note_index]
    except Exception:
        return None


def _extract_segment_features(y: np.ndarray, sr: int) -> dict[str, float]:
    rms = librosa.feature.rms(y=y)[0]
    centroid = librosa.feature.spectral_centroid(y=y, sr=sr)[0]
    onset_env = librosa.onset.onset_strength(y=y, sr=sr)
    onset_count = float(librosa.onset.onset_detect(onset_envelope=onset_env, sr=sr).size)
    duration = max(1e-6, y.size / sr)
    onset_density = onset_count / duration
    zcr = librosa.feature.zero_crossing_rate(y)[0]

    stft = np.abs(librosa.stft(y))
    freqs = librosa.fft_frequencies(sr=sr)
    low = _band_energy(stft, freqs, 20, 250)
    mid = _band_energy(stft, freqs, 250, 4000)
    high = _band_energy(stft, freqs, 4000, 14000)
    total = max(low + mid + high, 1e-6)

    energy = float(np.mean(rms))
    brightness = float(np.mean(centroid) / (sr / 2))
    rhythmic_density = float(np.mean(np.abs(np.diff(onset_env)))) if onset_env.size > 1 else 0.0
    danceability_like = _clamp(
        0.50 * _normalize(energy)
        + 0.30 * _normalize(onset_density)
        + 0.10 * _normalize(rhythmic_density)
        + 0.10 * _normalize(1.0 - float(np.mean(zcr)))
    )

    return {
        "energy": energy,
        "spectral_centroid_mean": float(np.mean(centroid)),
        "spectral_centroid_std": float(np.std(centroid)),
        "brightness": brightness,
        "rhythmic_density": rhythmic_density,
        "onset_density": onset_density,
        "low_balance": low / total,
        "mid_balance": mid / total,
        "high_balance": high / total,
        "danceability_like": danceability_like,
    }


def _band_energy(stft: np.ndarray, freqs: np.ndarray, low: float, high: float) -> float:
    idx = np.where((freqs >= low) & (freqs < high))[0]
    if idx.size == 0:
        return 0.0
    return float(np.mean(stft[idx, :]))


def _waveform_preview(y: np.ndarray, bins: int = 256) -> list[float]:
    if y.size == 0:
        return [0.0] * bins
    splits = np.array_split(np.abs(y), bins)
    values = np.array([float(np.max(chunk)) if chunk.size else 0.0 for chunk in splits], dtype=np.float64)
    max_value = float(np.max(values)) if values.size else 0.0
    if max_value > 0:
        values /= max_value
    values = np.sqrt(values)
    return [float(v) for v in values.tolist()]


def _descriptor_text(
    segment_type: str,
    bpm: float | None,
    musical_key: str | None,
    genre: str,
    features: dict[str, float],
    has_serato: bool,
    has_rekordbox: bool,
    tags: list[str],
    rating: int | None,
    play_count: int | None,
    playlist_memberships: list[str],
    cue_count: int | None,
    comment: str | None,
    analysis_focus: str,
    mixability_tags: list[str],
) -> str:
    bpm_value = f"{bpm:.2f}" if bpm is not None else "unknown"
    tag_text = "|".join(tags) if tags else "unknown"
    playlists_text = "|".join(playlist_memberships) if playlist_memberships else "unknown"
    mixability_text = "|".join(mixability_tags) if mixability_tags else "unknown"
    return (
        f"segment_type={segment_type}; "
        f"analysis_focus={analysis_focus}; "
        f"bpm={bpm_value}; "
        f"key={musical_key or 'unknown'}; "
        f"genre={genre or 'unknown'}; "
        f"energy={features['energy']:.5f}; "
        f"spectral_centroid_mean={features['spectral_centroid_mean']:.3f}; "
        f"spectral_centroid_std={features['spectral_centroid_std']:.3f}; "
        f"brightness={features['brightness']:.4f}; "
        f"rhythmic_density={features['rhythmic_density']:.5f}; "
        f"onset_density={features['onset_density']:.5f}; "
        f"band_balance_low_mid_high={features['low_balance']:.4f},{features['mid_balance']:.4f},{features['high_balance']:.4f}; "
        f"danceability_like={features['danceability_like']:.4f}; "
        f"tags={tag_text}; "
        f"rating={rating if rating is not None else 'unknown'}; "
        f"play_count={play_count if play_count is not None else 'unknown'}; "
        f"playlists={playlists_text}; "
        f"cue_count={cue_count if cue_count is not None else 'unknown'}; "
        f"mixability_tags={mixability_text}; "
        f"comment_present={int(bool(comment))}; "
        f"serato_metadata_detected={int(has_serato)}; "
        f"rekordbox_metadata_detected={int(has_rekordbox)}"
    )


def _energy_arc_for_segments(
    segments: list[tuple[str, float, float]],
    combined_energy: np.ndarray,
    frame_times: np.ndarray,
) -> list[float]:
    output: list[float] = []
    for _, start_sec, end_sec in segments:
        indices = np.where((frame_times >= start_sec) & (frame_times <= end_sec))[0]
        if indices.size == 0:
            output.append(0.0)
            continue
        output.append(float(np.mean(combined_energy[indices])))
    return [_clamp(value) for value in output]


def _build_mixability_tags(
    intro_length_sec: float,
    outro_length_sec: float,
    estimated_bpm: float | None,
    brightness: float,
    rhythmic_density: float,
    energy_arc: list[float],
    comment: Any,
) -> list[str]:
    tags: list[str] = []
    if intro_length_sec >= 28:
        tags.append("long_intro")
    if outro_length_sec >= 28:
        tags.append("clean_outro")
    if brightness >= 0.34:
        tags.append("high_brightness")
    if rhythmic_density >= 0.22:
        tags.append("percussive")
    if len(energy_arc) == 3 and abs(energy_arc[1] - energy_arc[0]) <= 0.18 and abs(energy_arc[2] - energy_arc[1]) <= 0.18:
        tags.append("steady_groove")
    if estimated_bpm is not None and estimated_bpm < 118:
        tags.append("warmup_ready")
    if isinstance(comment, str) and any(token in comment.lower() for token in ("vocal", "lyrics", "vox", "acapella")):
        tags.append("vocal_heavy")
    return tags


def _estimate_confidence(
    duration: float,
    estimated_bpm: float | None,
    estimated_key: str | None,
    cue_count: Any,
    energy_arc: list[float],
) -> float:
    score = 0.4
    if duration >= 60:
        score += 0.15
    if estimated_bpm is not None:
        score += 0.2
    if estimated_key:
        score += 0.1
    if isinstance(cue_count, int) and cue_count > 0:
        score += 0.1
    if len(energy_arc) == 3 and max(energy_arc) - min(energy_arc) > 0.08:
        score += 0.1
    return _clamp(score)


def _normalize_array(values: np.ndarray) -> np.ndarray:
    if values.size == 0:
        return values
    min_value = float(np.min(values))
    max_value = float(np.max(values))
    if max_value - min_value <= 1e-9:
        return np.zeros_like(values, dtype=np.float64)
    return (values - min_value) / (max_value - min_value)


def _normalize(value: float) -> float:
    return _clamp(1.0 / (1.0 + math.exp(-5.0 * (value - 0.5))))


def _clamp(value: float) -> float:
    return float(max(0.0, min(1.0, value)))


def _safe_float(value: Any) -> float | None:
    try:
        return float(value) if value is not None and not np.isnan(value) else None
    except Exception:
        return None
