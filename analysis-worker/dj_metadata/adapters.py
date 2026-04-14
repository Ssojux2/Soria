from __future__ import annotations

import csv
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any


def load_rekordbox_xml(path: str) -> list[dict[str, Any]]:
    data: list[dict[str, Any]] = []
    root = ET.parse(path).getroot()
    for track in root.findall(".//TRACK"):
        location = track.attrib.get("Location", "")
        data.append(
            {
                "track_path": location.replace("file://localhost", ""),
                "bpm": _to_float(track.attrib.get("AverageBpm")),
                "musical_key": track.attrib.get("Tonality"),
                "genre": track.attrib.get("Genre"),
                "rating": _to_int(track.attrib.get("Rating")),
                "source": "rekordbox",
            }
        )
    return data


def load_serato_csv(path: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with open(path, "r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(
                {
                    "track_path": row.get("path", ""),
                    "bpm": _to_float(row.get("bpm")),
                    "musical_key": row.get("key"),
                    "tags": (row.get("tags") or "").split("|"),
                    "play_count": _to_int(row.get("play_count")),
                    "source": "serato",
                }
            )
    return rows


def _to_float(v: Any) -> float | None:
    try:
        return float(v) if v not in (None, "") else None
    except Exception:
        return None


def _to_int(v: Any) -> int | None:
    try:
        return int(v) if v not in (None, "") else None
    except Exception:
        return None
