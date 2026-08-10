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

The app bundle includes the `analysis-worker` source scripts and an
arch-specific bundled Python worker runtime under
`Contents/Resources/analysis-worker/python`. Release installs do not require
`SORIA_PYTHON` or `SORIA_WORKER_SCRIPT`; those variables remain developer
overrides.

When source-build validation fails, use Settings to select or detect:

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
| Durable folder access in sandboxed builds | Implemented | `SecurityScopedBookmarkStore`, `LibraryRootsStore.rememberAccess` |
| Soria Trash quarantine and restore | Implemented | `LibraryQuarantineService`, `QuarantineReviewView` |
| Local folder organization | Implemented | `LibraryOrganizationPlanner`, `LibraryFileOrganizerService`, `OrganizerPlanView` |
| Soria collections | Implemented | `soria_collections`, `LibraryOrganizerModel` |
| Batch vendor export | Implemented | `PlaylistExportService.exportMany`, `RekordboxXMLWriter` |
| Prompt-folder organization | Planner implemented, UI gated on a shared text/audio model | `LibraryOrganizationPlanner.makePlan(kind:)` |
| CLAP local embedding profile | Not implemented; planned as an optional post-install add-on | — |
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

### 11. Soria Trash (Quarantine)

Selecting tracks in the Library and choosing **Move to Soria Trash** hands them
to `LibraryQuarantineService`, which moves each file into a
`Soria Quarantine/<timestamp>/` folder and records the move in
`track_quarantine`.

The quarantine folder is chosen on the track's own volume — the containing
library root first, then the volume root, and only as a last resort
`Application Support/Soria/quarantine`. Staying on one volume keeps the move an
atomic rename instead of a copy of a potentially huge library.

Quarantining nulls `tracks.last_seen_in_local_scan_at`, which is what removes
the track from the library list, and `LibraryScannerService` is told to skip
quarantine folders so a later scan does not re-index discarded files. The
pre-quarantine timestamp is stored on the quarantine row and replayed on
restore, so a restored track reappears without a rescan.

The Organizer's **Soria Trash** tab lists everything set aside, with:

- **Restore Selected** / **Restore All** — moves files back to their original
  paths. Restore is refused when another file already occupies that path.
- **Delete Permanently** — hands the files to the system Trash. This is the only
  path that leaves Soria's control, and it never calls `removeItem`.

Quarantine is deliberately not the system Trash: macOS gives an app no way to
list or selectively restore its own trashed items, and reviewing a cull is the
point of the feature.

### 12. Local Folder Organization

The Organizer's **Plan** tab turns prepared tracks into a folder tree.

Planning (`LibraryOrganizationPlanner`) is pure — it takes track embeddings and
genre-label embeddings as inputs and touches no files:

1. Each genre family in `GenreTaxonomy` is embedded as a short text label
   through the worker's `embed_text_labels` command. Vectors are cached per
   embedding profile in `worker-cache/label-embeddings/`, so only labels missing
   from the cache cost an API call.
2. Every track is assigned the family whose label vector is closest to its
   track embedding. Genre tags and folder names only break near-ties within
   0.025.
3. Tracks are clustered by similarity inside each family, producing
   `<destination>/<Genre>/Cluster NN - <Representative Artist>/`.

The preview table lists every proposed move with a checkbox. Unchecked moves are
neither applied nor recorded — this is the main thing the earlier, unshipped
folder-organization workflow lacked.

Applying (`LibraryFileOrganizerService`) moves files one at a time. Each move
refuses to overwrite an existing target, checks readability, and rolls the file
back if the database write fails — unless something reappeared at the source
path, in which case rollback is refused rather than clobbering it. A failed move
becomes a warning and the batch continues.

Successful moves record the old path in `track_path_aliases`, so the next vendor
sync still matches Serato and rekordbox entries that point at pre-move paths.
They also write the `soria_collections` tree mirroring the folders created, plus
`organization_batches` / `organization_moves` history.

Plans carry a low-confidence warning when more than 85% of tracks land in one
folder, which is what an embedding model without a shared text/audio space looks
like.

### 13. Batch Vendor Export

**Export Organized Folders** sends every organized collection to Serato or
rekordbox in one action through `PlaylistExportService.exportMany`.

- Serato: one `.crate` per collection, named with `%%` separators so the folder
  tree becomes a crate tree.
- rekordbox XML: one document with a single deduplicated `COLLECTION` and a
  merged `PLAYLISTS` tree whose folder nodes are shared between playlists.
- rekordbox M3U8: one file per collection in the chosen output folder.

The Serato crate root is resolved once over the union of all tracks, so a
selection spanning two drives fails before anything is written. Collections
record `last_exported_at`, and the Organizer warns when organizing happened
after the last export — the window in which vendor libraries still hold
pre-move paths.

### 14. Release Packaging

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

- SQLite library database, including `soria_collections`,
  `soria_collection_tracks`, `track_quarantine`, `organization_batches`, and
  `organization_moves`
- Python worker cache directory
- Chroma vector persistence
- genre/prompt label embedding cache (`worker-cache/label-embeddings/`)
- logs
- generated export helpers
- UserDefaults settings, including security-scoped bookmarks for library roots
  under `security.bookmarks.v1`
- Gemini API key in Keychain

Quarantined audio is **not** stored under Application Support in the normal
case: it stays on its own volume in a `Soria Quarantine/` folder so moves remain
atomic renames.

Soria does not upload full source audio files or the SQLite library database.
Embedding workflows can send short derived audio segment payloads and
descriptor/query data to the selected embedding backend through the worker.

## Verification Points

Useful checks:

```bash
make build
make test-worker
make test-swift
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
- The DMG/ZIP path ships arch-specific Python worker runtimes, not a universal
  merged Python runtime.
- Recommendation quality depends on scanned metadata, analysis quality, and
  valid embeddings.
- Rekordbox and Serato formats can vary by version; the code targets common
  structures and includes fixtures/tests for known paths.
- Serato crate export is intentionally conservative and marked experimental.
- Normalization mutates the active library file only after writing a separate
  normalized output and preserving the original in Trash or a fallback backup.
- Organizing **moves** files. Existing Serato crates and rekordbox playlists
  keep pointing at the old paths until you export again. `track_path_aliases`
  lets the next vendor sync re-match those entries, but Soria never rewrites the
  vendor databases in place.
- Quarantine is a Soria-managed folder, not the system Trash, so it does not
  free disk space until you use **Delete Permanently**.
- Genre detection compares text label embeddings against audio embeddings. That
  is only well-defined in a shared text/audio embedding space; with the Google
  profile the numbers are usable but unvalidated, which is why lopsided plans
  carry a low-confidence warning and why prompt folders are not exposed in the
  UI yet.
- In sandboxed Release builds, moving files requires a security-scoped bookmark
  minted when the folder was selected. Music Folders chosen before bookmarks
  existed show a re-authorization banner; organizing and quarantining stay
  disabled for those roots until the user re-selects them.
