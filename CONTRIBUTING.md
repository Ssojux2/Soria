# Contributing to Soria

Thanks for helping improve Soria. This project is early, so focused reports,
small pull requests, and real DJ-library compatibility notes are especially
valuable.

## Ways to Contribute

- Report reproducible bugs with the issue template.
- Improve docs for setup, DJ workflows, release installation, or troubleshooting.
- Add small, well-scoped fixes for SwiftUI macOS behavior or Python worker logic.
- Add metadata/export fixtures that do not contain private music files, API keys,
  user names, or real library paths.
- Share compatibility notes for Rekordbox XML, Serato CSV, and exported playlist
  packages.

## Before You Start

- Open an issue first for larger features, export-format changes, direct vendor
  library writes, privacy-sensitive changes, or changes that alter recommendation
  scoring.
- Keep one pull request tied to one issue or one clear root cause.
- Avoid pure formatting changes in files you are not otherwise editing.
- Do not include private audio files, private DJ library databases, API keys,
  screenshots with personal paths, or raw logs with user-identifying data.

## Local Setup

Requirements:

- macOS with a recent Xcode version.
- Python 3.11 or newer for the analysis worker.
- A Gemini API key only when validating embedding-based recommendations.

Set up the Python worker:

```bash
cd analysis-worker
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cd ..
```

Build the app:

```bash
make build
```

Run the app locally:

```bash
make run
```

Useful test commands:

```bash
make test-worker
make test-swift
make test-swift-full
make test
```

`make test-swift` runs the Swift unit tests used by CI. `make test-swift-full`
also runs the preview timing tests; use it when changing playback preview,
waveform seeking, or timing behavior. Swift tests may need local macOS services
that are not available in every sandbox. If a runner cannot launch the macOS
test host, include the failure output in the pull request.

## Pull Request Expectations

- Explain the user-visible impact.
- Link the related issue when there is one.
- Include tests or explain why tests are not practical.
- Add screenshots for visible UI changes.
- Update docs when setup, privacy, release, or workflow behavior changes.
- Confirm that no API keys, private paths, private logs, or real music files are
  included.

## Contribution License

Soria is licensed under the MIT License. Unless you explicitly state otherwise,
any contribution intentionally submitted for inclusion in Soria is submitted
under the same MIT License, without additional terms.

## Community

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md). For usage help, start
with [Support](SUPPORT.md). For private security reports, follow
[Security](SECURITY.md) instead of opening a public issue.
