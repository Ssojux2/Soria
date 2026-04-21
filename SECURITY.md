# Security Policy

Soria is a local-first macOS app, but security and privacy issues can still
affect users through local library indexing, Python worker execution, export
files, release packaging, and API-key handling.

## Supported Versions

Soria is in an early `0.1.x` public distribution phase. Security fixes are
targeted at the latest release and the `main` branch.

## Reporting a Vulnerability

Please do not open a public issue for vulnerabilities.

Use GitHub private vulnerability reporting for this repository when available,
or contact the maintainer privately through GitHub if private reporting is not
available for your account.

Include:

- A concise description of the issue.
- Steps to reproduce in a clean checkout or with synthetic sample data.
- The affected version, commit, or release asset.
- Whether the issue exposes API keys, local file paths, local music metadata, or
  generated export files.

Do not include:

- Gemini API keys or other credentials.
- Real music files.
- Private Rekordbox, Serato, or Soria library databases.
- Raw logs containing home directories, user names, file paths, or private
  collection metadata unless they are carefully redacted.

## Security-Sensitive Areas

- API-key storage and Keychain access.
- Python worker command execution and environment overrides.
- Local SQLite and Chroma persistence paths.
- File scanning, normalization, backup, and Trash behavior.
- Rekordbox and Serato import/export parsing.
- Release DMG/ZIP packaging and checksums.

## Release Integrity

Early release assets are ad-hoc signed and not Apple Developer ID signed or
notarized. macOS Gatekeeper warnings are expected. Verify downloaded DMG/ZIP
files with the matching `.sha256` checksums and build from source when in doubt.
