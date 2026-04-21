# Third-Party Notices

Soria is licensed under the MIT License. This file summarizes the direct
third-party software used by the current source tree and release process.

This notice is informational and not legal advice. Before shipping a release
that vendors a Python environment, regenerate a complete dependency notice from
the exact packaged environment and include transitive licenses.

## macOS App

The Swift macOS app uses Apple platform frameworks provided with macOS and Xcode,
including SwiftUI, AppKit, Foundation, AVFoundation, AudioToolbox, Security,
CryptoKit, SQLite3, and UniformTypeIdentifiers.

## Python Worker Direct Dependencies

The Python worker dependencies are declared in
`analysis-worker/requirements.txt`.

| Package | Version in requirements | License metadata or classifier to verify |
| --- | --- | --- |
| `numpy` | `1.26.4` | BSD-style license with bundled component notices |
| `librosa` | `0.10.2.post1` | ISC |
| `soundfile` | `0.12.1` | BSD 3-Clause |
| `requests` | `2.32.3` | Apache-2.0 |
| `chromadb` | `0.5.11` | Apache Software License classifier |
| `pytest` | `8.3.3` | MIT |
| `torch` | `2.5.1` | BSD-3-Clause |
| `transformers` | `4.46.3` | Apache 2.0 |

`pytest` is used for tests. `torch` and `transformers` support optional CLAP
embedding paths.

## Release Artifacts

Current DMG/ZIP release artifacts bundle the Soria app and the
`analysis-worker` source scripts. They do not vendor the repository
`analysis-worker/.venv` directory or a portable Python runtime.

If a future release vendors Python wheels, native libraries, or a portable
runtime, update this file with the complete transitive license inventory for
that exact bundle.

## Dependency Audit Command

The table above follows `analysis-worker/requirements.txt`. A local virtual
environment can drift from those pinned versions, so audit the exact environment
used for a release before bundling it.

For a local worker virtual environment, inspect package license metadata with:

```bash
analysis-worker/.venv/bin/python -m pip show \
  numpy librosa soundfile requests chromadb pytest torch transformers
```
