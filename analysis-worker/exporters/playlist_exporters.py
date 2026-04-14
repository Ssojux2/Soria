from __future__ import annotations

import csv
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any


def export_rekordbox_xml(playlist_name: str, tracks: list[dict[str, Any]], output_path: str) -> str:
    root = ET.Element("DJ_PLAYLISTS", {"Version": "1.0.0"})
    collection = ET.SubElement(root, "COLLECTION", {"Entries": str(len(tracks))})
    for t in tracks:
        ET.SubElement(
            collection,
            "TRACK",
            {
                "TrackID": str(t.get("id", "")),
                "Name": str(t.get("title", "")),
                "Artist": str(t.get("artist", "")),
                "Genre": str(t.get("genre", "")),
                "Location": "file://localhost" + str(t.get("file_path", "")),
                "AverageBpm": str(t.get("bpm", "")),
                "Tonality": str(t.get("musical_key", "")),
            },
        )

    playlists = ET.SubElement(root, "PLAYLISTS")
    node_root = ET.SubElement(playlists, "NODE", {"Type": "0", "Name": "ROOT"})
    node_playlist = ET.SubElement(node_root, "NODE", {"Type": "1", "Name": playlist_name, "Entries": str(len(tracks))})
    for t in tracks:
        ET.SubElement(node_playlist, "TRACK", {"Key": str(t.get("id", ""))})

    out = Path(output_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(out, encoding="utf-8", xml_declaration=True)
    return str(out)


def export_serato_safe_package(playlist_name: str, tracks: list[dict[str, Any]], output_dir: str) -> list[str]:
    out_dir = Path(output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    m3u = out_dir / f"{playlist_name}.m3u"
    csv_path = out_dir / f"{playlist_name}-ranked.csv"
    txt = out_dir / f"{playlist_name}-serato-import.txt"

    m3u.write_text("\n".join([str(t.get("file_path", "")) for t in tracks]) + "\n", encoding="utf-8")
    with open(csv_path, "w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["rank", "title", "artist", "bpm", "key", "genre", "path"])
        for i, t in enumerate(tracks):
            writer.writerow([i + 1, t.get("title"), t.get("artist"), t.get("bpm"), t.get("musical_key"), t.get("genre"), t.get("file_path")])

    txt.write_text(
        "Serato Safe Import Package\n"
        "1) Open Serato DJ Pro.\n"
        "2) Drag this M3U file into Crates.\n"
        "3) Use CSV for ranking reference.\n",
        encoding="utf-8",
    )
    return [str(m3u), str(csv_path), str(txt)]
