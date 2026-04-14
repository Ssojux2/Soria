# Developer Notes

## Architecture assumptions
- The macOS shell remains native SwiftUI for table-heavy desktop interaction.
- SQLite is the system of record for the local track index, segment metadata, analysis summaries, and imported external DJ metadata.
- The Python worker is launched per request over stdin/stdout JSON IPC to keep the app bundle simple while still using librosa and Chroma.
- Segment embeddings are generated from descriptor text built from audio features and DJ metadata, not from raw audio uploads.

## Important implementation choices
- Intro / middle / outro segmentation follows a 1:3:1 weighting strategy, with the middle window centered on the strongest sustained energy region rather than a naive equal split.
- Imported Serato and rekordbox metadata are stored per source so one import does not overwrite the other.
- Rekordbox export is XML-only. Serato export is intentionally limited to a safe package.
- Worker dependencies fail with explicit error messages so local setup issues are diagnosable.

## Risks and boundaries
- Rekordbox XML is more stable than direct DB parsing, but still not completely vendor-version-proof.
- Serato local formats are intentionally treated conservatively. No direct write path is enabled.
- `xcodebuild test` can fail inside restricted sandboxes because the macOS test runner needs system services that are blocked here.
- Large-library performance is helped by modified-time short-circuiting, content hashing, cached embeddings, and local vector persistence, but a future batch scheduler would improve throughput further.

## Safe TODOs
- Validate direct Serato crate/subcrate writing only after testing against real user libraries and backups.
- Add true waveform editing if the product needs manual segment correction.
- Add persistent scan-job history and cancellation checkpoints.
- Add richer external metadata ingestion beyond XML/CSV export formats when documented and validated.
