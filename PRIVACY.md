# Privacy

Soria is designed as a local-first DJ mix assistant. The app should help with
library analysis and recommendations without uploading full source audio files
or the local library database.

## Data Stored Locally

Soria can store the following on your Mac:

- Library roots selected by the user.
- Track paths, file names, audio metadata, content hashes, and modification
  times.
- Analysis summaries, segment boundaries, waveform previews, cue presentation
  data, and recommendation scores.
- Imported Rekordbox or Serato metadata that can be matched to scanned local
  tracks.
- SQLite database files and local Chroma vector persistence.
- A Gemini API key in the macOS Keychain when the user saves one in Settings.

## Data Sent to External Services

Embedding-based recommendations use Gemini when the active embedding profile
requires it. That path can send short derived audio-segment payloads, descriptor
text, query text, and metadata context needed for embeddings.

Soria does not intentionally upload full source music files or the local Soria
library database.

## Local Files and Exports

- Folder scanning reads files under user-selected music roots.
- Normalization can replace the active library file with a normalized copy and
  move the original to macOS Trash when possible.
- Rekordbox and Serato export files are written to destinations chosen by the
  user or to detected vendor-safe package locations.
- Early release builds bundle the worker source scripts, not a portable Python
  virtual environment.

## Issue Reports and Logs

Before sharing logs, screenshots, sample libraries, or exports publicly, remove:

- API keys and tokens.
- User names and home-directory paths.
- Private music collection paths and metadata.
- Private Rekordbox, Serato, or Soria database files.
- Real music files unless you have the rights and intentionally want to share
  them.

Security or privacy problems should be reported through the private process in
[SECURITY.md](SECURITY.md).
