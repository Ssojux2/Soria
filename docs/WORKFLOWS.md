# Soria Program Workflows

Last reviewed: 2026-04-21

This document is the repo-local wiki for how Soria currently behaves. It is
based on the app code, worker code, scripts, and tests in this repository.

## Scope

Soria is a local-first macOS DJ mix assistant. The product workflow is:

1. Configure the local analysis runtime and Gemini API key.
2. Scan local music folders into a SQLite library.
3. Optionally attach Rekordbox or Serato metadata.
4. Analyze tracks through the Python worker.
5. Generate and curate next-track recommendations.
6. Build a playlist path from curated recommendations.
7. Optionally normalize suggested queue tracks.
8. Export the queue for Rekordbox or Serato.

Full source audio files and the library database stay on the user's Mac. Gemini
is used for embedding-based recommendations, so a Gemini API key is required for
that part of the workflow. The current Gemini path can send short derived audio
segment payloads and text queries to Google for embedding.

## Main Entry Points

- `Soria/ContentView.swift` defines the macOS sidebar: Library, Mix Assistant,
  Exports, and Settings.
- `Soria/ViewModels/AppViewModel.swift` coordinates setup, scan, analysis,
  recommendations, queue normalization, and export.
- `Soria/Services/LibraryDatabase.swift` persists tracks, segments, external
  metadata, memberships, embeddings, and score sessions in SQLite.
- `Soria/Services/PythonWorkerClient.swift` is the Swift-to-Python worker IPC
  layer.
- `analysis-worker/main.py` dispatches worker commands such as `analyze`,
  `validate_embedding_profile`, `search_tracks`, `normalize_audio_file`, and
  vector-index maintenance.

## Runtime Setup

### Installed DMG/ZIP

The current GitHub Releases path creates an ad-hoc signed, unnotarized macOS app
inside DMG and ZIP assets. The release workflow is in:

- `Scripts/create_release_dmg.sh`
- `.github/workflows/release-dmg.yml`
- `docs/RELEASING.md`

The app bundle includes the `analysis-worker` source scripts, but
`Scripts/copy_analysis_worker.sh` intentionally excludes `.venv`. That means
the current zero-cost package is not a fully self-contained Python runtime. The
app can launch without `SORIA_PYTHON` or `SORIA_WORKER_SCRIPT`, but analysis
features still need a compatible Python environment with the worker
dependencies installed.

When validation fails, use Settings to select or detect:

- Python executable path
- `analysis-worker/main.py`
- Gemini API key

### Source Build

For source builds, create the worker venv:

```bash
cd analysis-worker
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cd ..
```

Then either let the app detect repo defaults, or set:

```bash
export GEMINI_API_KEY="..."
export SORIA_PYTHON="$PWD/analysis-worker/.venv/bin/python"
export SORIA_WORKER_SCRIPT="$PWD/analysis-worker/main.py"
```

`AppSettingsStore` also accepts `GOOGLE_AI_API_KEY` and `GOOGLE_API_KEY` as API
key overrides.

## Workflow Coverage

| Workflow | Status in app | Primary code |
| --- | --- | --- |
| First-run setup | Implemented | `AppViewModel.completeInitialSetup`, `ContentView.InitialSetupSheet` |
| Music folder scan | Implemented | `LibraryScannerService.scan` |
| Incremental scan skip | Implemented | `LibraryScannerService.scan`, `LibraryScannerService.refreshTrack` |
| Rekordbox native metadata sync | Implemented with common DB/XML paths | `RekordboxLibraryService`, `DJLibrarySyncService` |
| Rekordbox XML import | Implemented | `ExternalMetadataService.importRekordboxXMLRecords` |
| Serato native metadata sync | Implemented for detected `master.sqlite` | `SeratoLibraryService`, `DJLibrarySyncService` |
| Serato CSV import | Implemented | `ExternalMetadataService.importSeratoCSVRecords` |
| Cue point presentation | Implemented | `ExternalCuePointParser`, `TrackCuePresentation`, `LibraryView` |
| Track analysis | Implemented through worker | `PythonWorkerClient.analyze`, `analysis-worker/audio/features.py` |
| Segment embedding | Implemented through Gemini or supported profile | `PythonWorkerClient.embedAudioSegments`, `analysis-worker/main.py` |
| Vector index maintenance | Implemented | `AnalysisCommitActor`, `ChromaVectorStore`, `repairVectorIndexIfNeeded` |
| Library preview and waveform seek | Implemented | `LibraryView`, `AppViewModel` preview methods |
| Recommendation generation | Implemented | `RecommendationEngine`, worker vector search |
| Recommendation curation | Implemented | `RecommendationsView`, `AppViewModel` curation methods |
| Playlist path building | Implemented | `AppViewModel.buildPlaylistPath` |
| Queue normalization inspection | Implemented | `AudioNormalizationService.inspectTracks` |
| Queue normalization mutation | Implemented for supported formats | `AudioNormalizationService.normalizeQueuedTracks` |
| Rekordbox M3U8 export | Implemented | `PlaylistExportService`, `RekordboxPlaylistWriter` |
| Rekordbox XML export | Implemented | `PlaylistExportService`, `RekordboxXMLWriter` |
| Serato crate export | Implemented, marked experimental | `PlaylistExportService`, `SeratoCrateWriter` |
| Developer ID signing/notarization | Not implemented | `docs/RELEASING.md` documents later path |

## Detailed Workflows

### 1. First-Run Setup

The first-run sheet asks for a Gemini API key when the active embedding profile
requires one. It also asks for a local music folder when no library source is
configured.

`completeInitialSetup` validates the active embedding profile, adds the selected
music folder as a fallback library root, scans local files, detects native DJ
sources, and refreshes vendor metadata when available.

If validation fails, setup remains open and surfaces the worker/API-key error.

### 2. Library Scanning

The scanner discovers regular audio files under the configured roots. Supported
extensions are:

- `mp3`
- `wav`
- `aiff`
- `aif`
- `m4a`
- `aac`
- `flac`

Hidden files and symlinked directories are skipped. The scanner records file
path, file name, audio tag metadata, duration, sample rate, modification time,
and content hash.

Incremental behavior:

- Previously scanned unchanged files are skipped quickly.
- Changed files clear prior analysis and vector state.
- Duplicate content hashes are skipped for current local scans.
- Tracks no longer seen in scanned roots are removed from active local-scan
  membership queries.

### 3. External DJ Metadata

Soria can enrich scanned local tracks with vendor metadata.

Supported sources:

- Rekordbox native database directory detection.
- Rekordbox XML import and automatic candidate search.
- Serato `master.sqlite` detection.
- Serato CSV import.

Metadata is attached only to scanned local tracks. Matching prefers normalized
path matches and can use content hashes when file paths differ but files are
available. Attached metadata includes BPM, key, genre/tags, comments, ratings,
play counts, playlist memberships, cue counts, and cue point details where
available.

Playlist and crate memberships are normalized into `membership_catalog` and
`track_memberships`, which power the Library and Mix Assistant reference filters.

### 4. Track Analysis

Analysis runs through `PythonWorkerClient` and `analysis-worker/main.py`.

The worker extracts:

- estimated BPM and key
- brightness, onset density, rhythmic density, and frequency balance
- waveform preview and waveform envelope
- intro, middle, and outro segment boundaries
- segment descriptor text
- energy arc
- mixability tags
- confidence
- track and segment embeddings

Swift commits analysis in `AnalysisCommitActor`. It stores the track analysis,
segments, embeddings, and local Chroma vector entries. A track is considered
ready only when the SQLite row has a valid profile/pipeline, a track embedding,
and embedded segment vectors.

If an audio file changes later, `LibraryScannerService.refreshTrack` clears the
stale analysis and invalidates vector entries.

### 5. Worker Health and Vector Repair

Settings validation calls `validate_embedding_profile`. The worker healthcheck
reports dependency availability, embedding profile support, API-key presence,
and vector index state.

When the SQLite ready-track set and Chroma vector index drift apart, Soria can
automatically rebuild the vector index from stored track and segment embeddings.
This is handled in `AppViewModel.repairVectorIndexIfNeeded`.

### 6. Library Preview

Selecting one track in Library enables the preview strip when the file is
playable. The preview supports:

- play/pause
- waveform tap/drag seeking
- cue marker seeking
- automatic stop when the search field takes focus

Waveform envelope backfill is handled through the worker when stored envelope
data is missing.

### 7. Recommendation Generation

Mix Assistant can generate recommendations from:

- a ready reference track
- a semantic text query
- a hybrid of text and reference track context

The worker builds query embeddings or searches the local Chroma index. Swift
then applies deterministic scoring with:

- embedding similarity
- BPM compatibility
- Camelot-style key compatibility
- energy flow
- intro/outro transition suitability
- external metadata confidence

Advanced controls in Mix Assistant let the user adjust final-score weights,
intro/middle/outro vector weights, BPM range, max duration, key strictness,
genre lens, genre continuity, external metadata priority, analysis focus, tag
filters, and folder filters.

Generated recommendations are persisted as score sessions. The database keeps
the latest sessions per profile/kind and stores score snapshots for later
debugging.

### 8. Recommendation Curation and Playlist Path

Generated matches can be hidden and restored before building a path. The path
builder starts from the current seed and repeatedly chooses the next best
candidate from the curated pool. It updates visible progress while ordering the
queue.

The final ordered tracks are copied into the export playlist queue and the app
navigates to Exports.

### 9. Queue Normalization

Exports have a playlist queue panel that inspects normalization state.

Normalization policy:

- Target peak: `1.0`
- High priority: peak `<= 0.8`
- Medium priority: peak `<= 0.9`
- Low priority: peak below target but above `0.9`
- Queue auto-normalizes suggested medium/high priority tracks.
- Low-priority tracks are reported but skipped by the queue action.

Supported normalization paths:

- `.wav`, `.aiff`, `.aif`, `.flac`, and `.mp3` through Python `soundfile`
  when runtime support is available.
- AAC-based `.m4a` through the native AVFoundation path.
- Raw `.aac` is marked unsupported in v1.

Mutation safety:

- The normalized output is first written to a temporary replacement directory.
- The original active library file is moved to macOS Trash with the original
  file name.
- The normalized copy is moved into the original path.
- If moving the normalized copy fails, Soria tries to restore the trashed
  original.
- If Trash is unavailable, Soria falls back to a timestamped backup beside the
  track, using `-soria-backup-YYYYMMDD-HHMMSS`.

Because the original is sent to Trash with the same file name, Finder's
**Put Back** action can restore it more naturally.

### 10. Export

Exports run from `PlaylistExportService` after `VendorExportPreflight` prepares
and validates the queue.

Current targets:

- Rekordbox 6/7 playlist `.m3u8`
- Rekordbox-compatible library `.xml`
- Serato `.crate`

Rekordbox M3U8 is intended for `File > Import > Import Playlist`.
Rekordbox XML is intended for the Imported Library / Bridge flow.

Serato crate export writes directly into the detected `_Serato_/Subcrates`
folder and is marked experimental. It validates that the selected output path is
inside the detected Subcrates folder. Existing crates are handled by the writer,
and warnings are shown through the Exports view.

Exports do not automatically run normalization. The user explicitly reviews and
runs "Normalize Suggested" from the queue.

### 11. Release Packaging

`make release-dmg` runs `Scripts/create_release_dmg.sh`.

The script:

- builds the Release app with code signing disabled in Xcode
- copies the app to a staging directory
- adds an `/Applications` symlink and `README-FIRST.txt`
- clears extended attributes
- ad-hoc signs the app
- creates a ZIP and DMG
- writes `.sha256` checksums
- verifies that the app exists inside both artifacts

The GitHub Actions workflow creates or updates a draft GitHub Release when a
`v*` tag is pushed or when the workflow is manually dispatched.

Current limitation: artifacts are not Developer ID signed or notarized, so
Gatekeeper warnings are expected.

## Data Storage

Soria stores app data under Application Support through `AppPaths`.

Important local state:

- SQLite library database
- Python worker cache directory
- Chroma vector persistence
- logs
- generated export helpers
- UserDefaults settings
- Gemini API key in Keychain

Soria does not upload full source audio files or the SQLite library database.
Embedding workflows can send short derived audio segment payloads and
descriptor/query data to the selected embedding backend through the worker.

## Verification Points

Useful checks:

```bash
make build
python3 -m pytest analysis-worker/tests
VERSION=0.1.0 make release-dmg
```

Relevant coverage found in the repo:

- Library scanning, duplicate handling, membership filtering, and source sync in
  `SoriaTests/SoriaTests.swift`.
- Analysis progress, runtime validation, and library sync presentation in
  `SoriaTests/AnalysisProgressTests.swift`.
- Recommendation navigation, curation, playlist build progress, library preview,
  and export queue UI in `SoriaUITests/SoriaUITests.swift`.
- Worker normalization, semantic search, waveform envelopes, and feature
  extraction in `analysis-worker/tests`.
- Queue normalization mutation safety and Trash/backup behavior in
  `SoriaTests/SoriaTests.swift`.

## Current Gaps and Guardrails

- Early release artifacts are not notarized.
- The DMG/ZIP path does not yet ship a portable Python runtime.
- Recommendation quality depends on scanned metadata, analysis quality, and
  valid embeddings.
- Rekordbox and Serato formats can vary by version; the code targets common
  structures and includes fixtures/tests for known paths.
- Serato crate export is intentionally conservative and marked experimental.
- Normalization mutates the active library file only after writing a separate
  normalized output and preserving the original in Trash or a fallback backup.
