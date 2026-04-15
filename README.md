# Soria DJ Mix Assistant

Soria is a local-first macOS app for DJs. It scans user-selected music folders, extracts intro/middle/outro segments, derives embedding descriptors from audio analysis plus DJ metadata, stores vectors locally, recommends compatible next tracks, and exports DJ-library-friendly playlists.

## 1. Implementation Plan

1. Build a native SwiftUI macOS shell with a sidebar-driven workflow for library, analysis, recommendations, exports, and settings.
2. Persist the local library in SQLite with incremental rescans, content-hash deduplication, segment storage, and imported Serato / rekordbox metadata.
3. Run audio-heavy work in a Python worker process over JSON stdin/stdout IPC so the UI stays responsive.
4. Use energy-aware segmentation to isolate intro, climax/middle, and outro, then embed descriptor text with Gemini Embeddings instead of uploading raw audio.
5. Store segment vectors in local Chroma persistence, combine them into a weighted track embedding, and use transparent scoring to recommend transitions.
6. Export Rekordbox XML and a non-destructive Serato-safe package (M3U + ranked CSV + import instructions).

## 2. Architecture

### macOS app (`Soria/`)
- `Models/`: track, segment, recommendation, and external metadata domain models
- `Services/`: SQLite persistence, scanner, worker IPC, export logic, metadata parsing, hashing, logging
- `ViewModels/`: app orchestration and background workflow state
- `Views/`: native SwiftUI desktop views for browsing, analysis, recommendations, and export

### Python worker (`analysis-worker/`)
- `audio/`: librosa-based feature extraction, waveform preview generation, energy-aware segmentation
- `embedding/`: Gemini Embeddings client with local cache, retry, and rate-limit handling
- `vectordb/`: local Chroma persistence for segment vectors
- `dj_metadata/`: helper adapters for external library formats
- `exporters/`: shared export utilities
- `tests/`: worker unit tests

### Shared assumptions
- Audio analysis remains local.
- Vector search remains local.
- DJ-library ingestion is read-only.
- Serato direct crate write remains disabled by default for safety.

## 3. Project Tree

```text
Soria/
├── Soria.xcodeproj
├── Soria/
│   ├── ContentView.swift
│   ├── SoriaApp.swift
│   ├── Models/
│   │   ├── AppModels.swift
│   │   ├── ExternalMetadataModels.swift
│   │   ├── RecommendationModels.swift
│   │   └── TrackModels.swift
│   ├── Services/
│   │   ├── AppLogger.swift
│   │   ├── AppPaths.swift
│   │   ├── AudioMetadataReader.swift
│   │   ├── ExternalMetadataService.swift
│   │   ├── FileHashingService.swift
│   │   ├── LibraryDatabase.swift
│   │   ├── LibraryRootsStore.swift
│   │   ├── LibraryScannerService.swift
│   │   ├── PlaylistExportService.swift
│   │   ├── PythonWorkerClient.swift
│   │   └── RecommendationEngine.swift
│   ├── ViewModels/
│   │   └── AppViewModel.swift
│   └── Views/
│       ├── AnalysisView.swift
│       ├── ExportsView.swift
│       ├── LibraryView.swift
│       ├── RecommendationsView.swift
│       ├── ScanJobsView.swift
│       ├── SettingsView.swift
│       └── TrackDetailView.swift
├── SoriaTests/
│   └── SoriaTests.swift
├── analysis-worker/
│   ├── audio/
│   │   ├── __init__.py
│   │   └── features.py
│   ├── dj_metadata/
│   │   ├── __init__.py
│   │   └── adapters.py
│   ├── embedding/
│   │   ├── __init__.py
│   │   └── gemini_client.py
│   ├── exporters/
│   │   ├── __init__.py
│   │   └── playlist_exporters.py
│   ├── tests/
│   │   └── test_features.py
│   ├── vectordb/
│   │   ├── __init__.py
│   │   └── chroma_store.py
│   ├── main.py
│   └── requirements.txt
├── shared/
│   └── config.sample.json
├── .env.example
└── DEVELOPER_NOTES.md
```

## 4. Setup Instructions

### Python worker
```bash
cd /Users/ssojux2/Documents/BluePenguin/Soriga/Soria/analysis-worker
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### Environment
Set these in your Xcode scheme or shell environment:

- `GEMINI_API_KEY`
- `SORIA_PYTHON`
- `SORIA_WORKER_SCRIPT`
- Optional: `SORIA_EMBED_BATCH_SIZE`
- Optional: `SORIA_EMBED_TIMEOUT_SEC`

Use `.env.example` as the baseline.

### Build
Open `Soria.xcodeproj` in Xcode and run the `Soria` scheme.

For CLI validation inside restricted environments:
```bash
xcodebuild build \
  -scheme Soria \
  -project Soria.xcodeproj \
  -derivedDataPath .build/DerivedData \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

To build and launch the desktop app from Terminal, use:
```bash
./Scripts/run_debug_app.sh
```

If you need a clean rebuild first:
```bash
./Scripts/run_debug_app.sh --clean
```

Use `open .../Soria.app`, not `.../Contents/MacOS/Soria`, when launching from Terminal. The app is a macOS bundle and is more reliable when started through Launch Services.

### App workflow
1. Add one or more music root folders in Settings or Library.
2. Run a scan to index local files and skip unchanged tracks.
3. Import Rekordbox XML or Serato CSV metadata if available.
4. Analyze a selected track or batch-analyze pending tracks.
5. Generate recommendations or build a full playlist path from a seed track.
6. Export to Rekordbox XML or the Serato-safe package.

## 5. Validation Notes

- `python3 -m pytest analysis-worker/tests` currently skips when `librosa` is not installed in the active interpreter.
- macOS unit tests can fail inside this sandbox because `xcodebuild test` cannot communicate with `testmanagerd`; the app code itself builds successfully with signing disabled.

## 6. Known Limitations

1. Audio feature extraction depends on local Python packages being installed into the worker environment.
2. The SwiftUI waveform is a derived preview, not a sample-accurate editable waveform editor.
3. Rekordbox XML import/export targets common XML structures; uncommon vendor/version variations may need extra adapters.
4. Serato export remains intentionally non-destructive. Direct crate writing is not claimed or enabled.
5. Embedding quality depends on Gemini availability, quota, and the fidelity of local metadata/features.

## 7. Next-Step Improvements

1. Add explicit scan-job persistence and cancellation/resume controls.
2. Add richer key normalization and full Camelot / Open Key conversion utilities.
3. Add user-editable segment boundaries and playlist energy-curve presets.
4. Add batch-analysis scheduling with bounded worker concurrency.
5. Add fixture-based integration tests with real rekordbox exports and larger music libraries.
