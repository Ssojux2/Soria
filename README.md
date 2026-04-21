# Soria

[![Sponsor](https://img.shields.io/badge/Sponsor-GitHub%20Sponsors-EA4AAA)](https://github.com/sponsors/Ssojux2)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-ssojux2-FFDD00?logo=buymeacoffee&logoColor=000000)](https://buymeacoffee.com/ssojux2)
[![Release macOS assets](https://github.com/Ssojux2/Soria/actions/workflows/release-dmg.yml/badge.svg)](https://github.com/Ssojux2/Soria/actions/workflows/release-dmg.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Soria is a local-first macOS DJ mix assistant. It scans folders you choose,
indexes your music library locally, analyzes track structure, recommends
compatible next tracks, and exports DJ-library-friendly playlists without
uploading your full music files or library database.

Languages: [English](#english) | [한국어](#한국어) | [日本語](#日本語)

## English

### What Soria Does

- Builds a local track library from user-selected music folders.
- Extracts intro, middle, and outro segments for mix planning.
- Reads local audio metadata and optional DJ-library metadata.
- Generates embeddings from analyzed track segments, query text, and metadata
  context.
- Stores the library in SQLite and vectors in local Chroma persistence.
- Recommends transition candidates with transparent score breakdowns.
- Exports Rekordbox XML and a non-destructive Serato-safe package.

Soria is designed for DJs who want recommendation support without handing their
music collection to a remote service. Audio analysis stays on your Mac. Embedding
requests can send short derived audio-segment payloads and query text to Gemini;
full source files and the local library database stay on your Mac.

### Current Release Status

Soria is in an early open-source distribution phase.

- Source code is published on GitHub.
- Early builds are distributed as DMG and ZIP files through GitHub Releases.
- Release app artifacts are ad-hoc signed, but not Developer ID signed or notarized.
- macOS Gatekeeper warnings are expected for these early builds.

If you trust the source, you can open the app through **System Settings >
Privacy & Security > Open Anyway**, or build it yourself with Xcode.

### Support Development

Soria is supported through [GitHub Sponsors](https://github.com/sponsors/Ssojux2)
and [Buy Me a Coffee](https://buymeacoffee.com/ssojux2). Sponsorship supports
future music-related app development.

### License

Soria is released under the [MIT License](LICENSE). Contributions are accepted
under the same license unless a contributor explicitly states otherwise.

### Documentation

- [Program Workflows](docs/WORKFLOWS.md) explains how the app moves through
  setup, scanning, analysis, recommendation, normalization, and export.
- [Release Notes](docs/RELEASING.md) explains the current GitHub Releases,
  DMG, ZIP, checksum, and Gatekeeper-warning workflow.
- [Privacy](PRIVACY.md) explains local storage, Keychain usage, Gemini embedding
  requests, and safe issue-reporting practices.
- [Contributing](CONTRIBUTING.md), [Support](SUPPORT.md), and
  [Security](SECURITY.md) explain how to participate safely.
- [Third-Party Notices](THIRD_PARTY_NOTICES.md) summarizes direct dependency
  license metadata for the current source and release approach.

### Install Directly From GitHub Releases

1. Open the [Releases](https://github.com/Ssojux2/Soria/releases) page.
2. Download one of the release assets:
   - `Soria-<version>-macOS-unnotarized.dmg` for the drag-and-drop installer.
   - `Soria-<version>-macOS-unnotarized.zip` for a direct app archive.
3. Optionally verify the downloaded file with the matching `.sha256` file.

   ```bash
   shasum -a 256 Soria-0.1.0-macOS-unnotarized.dmg
   cat Soria-0.1.0-macOS-unnotarized.dmg.sha256

   shasum -a 256 Soria-0.1.0-macOS-unnotarized.zip
   cat Soria-0.1.0-macOS-unnotarized.zip.sha256
   ```

4. For the DMG, open it and drag `Soria.app` to `Applications`.
5. For the ZIP, double-click it to extract `Soria.app`, then move the app to
   `Applications`.
6. Launch Soria. If macOS blocks the app, use **System Settings > Privacy &
   Security > Open Anyway**.

GitHub also shows a **Source code (zip)** download for every release. That file
is source code only; use the app ZIP or DMG above if you want to install Soria
without building it yourself.

DMG and app ZIP installs include the app and the bundled analysis-worker source
scripts, so `SORIA_WORKER_SCRIPT` is not part of normal user setup. The current
zero-cost package does not vendor a portable Python virtual environment. If
worker validation fails in an installed app, use **Settings > Analysis Worker**
to point Soria at a compatible Python environment, or build from source and use
the repo `analysis-worker/.venv`. `SORIA_PYTHON` and `SORIA_WORKER_SCRIPT` are
developer/runtime overrides. Set or paste a Gemini API key only if you want
embedding-based recommendations.

### Build From Source

Requirements:

- macOS with a recent Xcode version.
- Python 3.11+ recommended for the analysis worker.
- A Gemini API key is required for embedding-based recommendations. Create and
  manage one from the [Google AI Studio API Keys page](https://aistudio.google.com/app/apikey),
  then set it as `GEMINI_API_KEY`.

Gemini API free tier note:

Google's pricing page currently lists
[Gemini Embedding 2 Preview](https://ai.google.dev/gemini-api/docs/pricing#gemini-embedding-2-preview)
and [Gemini Embedding](https://ai.google.dev/gemini-api/docs/pricing#gemini-embedding)
standard input as free in the Gemini API Free Tier. Google's
[rate-limit documentation](https://ai.google.dev/gemini-api/docs/rate-limits)
also says limits are project-level, RPD resets at midnight Pacific time, and
active limits can vary, so confirm your project's current quota in AI Studio
before a large batch. If AI Studio shows about 1,000 RPD for Gemini Embedding,
read that as about 1,000 embedding API requests per day, not necessarily 1,000
tracks; Soria can make one uncached audio embedding request per segment, while
text embeddings can be batched with `SORIA_EMBED_BATCH_SIZE`.

Set up the Python worker:

```bash
cd analysis-worker
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cd ..
```

Configure environment variables in your Xcode scheme or shell:

- `GEMINI_API_KEY`, issued from Google AI Studio
- `SORIA_PYTHON`, for example `analysis-worker/.venv/bin/python`
- `SORIA_WORKER_SCRIPT`, for example `analysis-worker/main.py`
- Optional: `SORIA_EMBED_BATCH_SIZE`
- Optional: `SORIA_EMBED_TIMEOUT_SEC`

Build from Terminal:

```bash
make build
```

Build and launch:

```bash
make run
```

Clean, build, and launch:

```bash
make run-clean
```

Create early release DMG and ZIP assets:

```bash
VERSION=0.1.0 make release-dmg
```

Generated release artifacts are written to `dist/`:

```text
dist/Soria-0.1.0-macOS-unnotarized.dmg
dist/Soria-0.1.0-macOS-unnotarized.dmg.sha256
dist/Soria-0.1.0-macOS-unnotarized.zip
dist/Soria-0.1.0-macOS-unnotarized.zip.sha256
```

See [docs/RELEASING.md](docs/RELEASING.md) for the GitHub Releases workflow.

### Full Usage Guide

1. **Choose an install path.** Use the release DMG/ZIP for early manual installs,
   or build from source if you want full control over the Python worker runtime.
   Embedding-based recommendations require a Gemini API key from Google AI
   Studio. You can paste it in Soria Settings or provide it as `GEMINI_API_KEY`.

2. **Validate analysis settings.** In release builds, open Settings and validate
   the active embedding profile. In source builds, install
   `analysis-worker/requirements.txt` into `analysis-worker/.venv`, then set or
   detect `SORIA_PYTHON` and `SORIA_WORKER_SCRIPT` if needed.

3. **Add music folders.** Open Soria, go to Settings or Library, and add one or
   more root folders that contain your tracks.

4. **Scan the library.** Start a scan to index supported audio files. Soria uses
   modified time and content hashing to skip unchanged files on later scans.

5. **Import DJ metadata when available.** Import Rekordbox XML or Serato CSV
   metadata if you already maintain cue points, BPM, keys, crates, or playlists
   in DJ software.

6. **Analyze tracks.** Analyze one track or batch-analyze pending tracks. The
   worker extracts audio features, waveform previews, segment summaries, and
   descriptors for recommendation.

7. **Review track details.** Use the track detail view to inspect metadata,
   waveform-derived previews, analysis confidence, cue information, and segment
   structure.

8. **Generate recommendations.** Select a seed track and ask Soria for compatible
   next-track candidates. Scores combine segment similarity, tempo/key context,
   energy shape, and available DJ metadata.

9. **Normalize audio when needed.** Suggested normalization replaces the active
   library file with the normalized copy. The original file is moved to macOS
   Trash with its original file name, so Finder's **Put Back** can restore it
   more naturally. If Trash is unavailable, Soria keeps a timestamped backup
   next to the track and shows a warning.

10. **Build playlist paths.** Use recommendations to assemble a candidate path
   through your library, then refine the order manually before export.

11. **Export for DJ software.** Export Rekordbox XML or the Serato-safe package.
   Serato export is intentionally non-destructive and does not directly rewrite
   local crate files.

12. **Check logs when needed.** If analysis fails, inspect Soria logs and worker
    stderr. Most failures are missing Python packages, missing API keys, or audio
    files the local decoder cannot read.

### Architecture

```text
Soria/
├── Soria/                 SwiftUI macOS app
│   ├── Models/            Track, segment, recommendation, metadata models
│   ├── Services/          SQLite, scanner, worker IPC, export, logging
│   ├── ViewModels/        App workflow and background state
│   └── Views/             Library, recommendations, exports, settings
├── analysis-worker/       Python audio analysis and vector worker
│   ├── audio/             Feature extraction and segmentation
│   ├── embedding/         Gemini embedding client
│   ├── vectordb/          Local Chroma vector persistence
│   ├── dj_metadata/       External metadata adapters
│   └── exporters/         Shared export helpers
├── SoriaTests/            macOS unit tests
├── SoriaUITests/          macOS UI tests
├── Scripts/               Local build, run, and DMG scripts
└── docs/                  Workflow, release, and distribution notes
```

### Validation

Useful checks:

```bash
make build
make test-worker
make test-swift
VERSION=0.1.0 make release-dmg
```

The Python tests require the active interpreter to have the worker dependencies
installed. `make test-swift` runs the CI Swift unit-test set. Use
`make test-swift-full` when changing playback preview, waveform seeking, or
timing behavior. macOS UI/unit tests may require local system services that are
not available in every sandboxed environment.

### Known Limitations

- Early DMGs are not notarized, so Gatekeeper warnings are expected.
- Direct DMG/ZIP builds currently bundle worker scripts, not a portable Python
  virtual environment.
- Audio feature extraction depends on local Python packages.
- The waveform preview is derived analysis data, not a sample-accurate editor.
- Rekordbox XML import/export targets common XML structures; unusual vendor
  versions may need more adapters.
- Serato export is deliberately conservative and non-destructive.
- Recommendation quality depends on local metadata quality and embedding
  availability.

### Privacy and Security

Soria stores the library database, analysis summaries, waveform previews, and
vector persistence on your Mac. Gemini embedding profiles can send short derived
segment payloads, descriptor text, query text, and metadata context for
embedding requests, but Soria does not intentionally upload full source music
files or the local library database.

Before opening issues or pull requests, remove API keys, private music files,
private DJ databases, unredacted home-directory paths, and private logs. Report
security issues privately through the process in [SECURITY.md](SECURITY.md).

### Contributing

Issues, discussions, and focused pull requests are welcome. Good first areas
include metadata fixtures, export compatibility, performance on large libraries,
and documentation for DJ workflows.

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.
For larger changes, open an issue first and keep each pull request tied to one
issue or one clear root cause.

---

## 한국어

Soria는 로컬 우선 macOS DJ 믹스 어시스턴트입니다. 사용자가 선택한 폴더를
스캔하고, 음악 라이브러리를 로컬에서 색인하며, 트랙 구조를 분석하고, 다음에
믹스하기 좋은 호환 트랙을 추천하며, DJ 라이브러리 친화적인 플레이리스트를
내보냅니다. 전체 음악 파일이나 라이브러리 데이터베이스는 업로드하지 않습니다.

### 주요 기능

- 사용자가 선택한 음악 폴더에서 로컬 트랙 라이브러리를 만듭니다.
- 믹스 계획을 위해 intro, middle, outro 구간을 추출합니다.
- 로컬 오디오 메타데이터와 선택적인 DJ 라이브러리 메타데이터를 읽습니다.
- 분석된 트랙 구간, query text, 메타데이터 context에서 임베딩을 생성합니다.
- 라이브러리는 SQLite에, 벡터는 로컬 Chroma persistence에 저장합니다.
- 투명한 점수 breakdown과 함께 전환 후보를 추천합니다.
- Rekordbox XML과 비파괴적인 Serato-safe 패키지를 내보냅니다.

Soria는 음악 컬렉션을 원격 서비스에 맡기지 않고 추천 지원을 받고 싶은 DJ를
위해 설계되었습니다. 오디오 분석은 Mac 안에서 이루어집니다. 임베딩 요청은
짧은 파생 오디오 세그먼트 payload와 query text를 Gemini로 보낼 수 있지만,
원본 전체 파일과 로컬 라이브러리 데이터베이스는 Mac에 남습니다.

### 현재 릴리스 상태

Soria는 초기 오픈소스 배포 단계입니다.

- 소스 코드는 GitHub에 공개되어 있습니다.
- 초기 빌드는 GitHub Releases를 통해 DMG와 ZIP 파일로 배포됩니다.
- 릴리스 앱 산출물은 ad-hoc 서명되어 있지만 Developer ID 서명이나 notarization은
  되어 있지 않습니다.
- 이 초기 빌드에서는 macOS Gatekeeper 경고가 예상됩니다.

소스를 신뢰한다면 **시스템 설정 > 개인정보 보호 및 보안 > Open Anyway**로 앱을
열거나, Xcode로 직접 빌드할 수 있습니다.

### 개발 후원

Soria는 [GitHub Sponsors](https://github.com/sponsors/Ssojux2)와
[Buy Me a Coffee](https://buymeacoffee.com/ssojux2)를 통해 후원할 수 있습니다.
후원은 향후 음악 관련 앱 개발에 사용됩니다.

### 라이선스

Soria는 [MIT License](LICENSE)로 배포됩니다. 기여자가 명시적으로 다른 조건을
밝히지 않는 한, 기여 역시 같은 라이선스로 받습니다.

### 문서

- [Program Workflows](docs/WORKFLOWS.md)는 앱이 setup, scanning, analysis,
  recommendation, normalization, export를 어떻게 거치는지 설명합니다.
- [Release Notes](docs/RELEASING.md)는 현재 GitHub Releases, DMG, ZIP,
  checksum, Gatekeeper 경고 workflow를 설명합니다.
- [Privacy](PRIVACY.md)는 로컬 저장소, Keychain 사용, Gemini embedding 요청,
  안전한 이슈 보고 방식을 설명합니다.
- [Contributing](CONTRIBUTING.md), [Support](SUPPORT.md),
  [Security](SECURITY.md)는 안전하게 참여하는 방법을 설명합니다.
- [Third-Party Notices](THIRD_PARTY_NOTICES.md)는 현재 소스와 릴리스 방식에서
  직접 의존성의 라이선스 메타데이터를 요약합니다.

### GitHub Releases에서 직접 설치

1. [Releases](https://github.com/Ssojux2/Soria/releases) 페이지를 엽니다.
2. 다음 릴리스 asset 중 하나를 다운로드합니다.
   - drag-and-drop 설치용 `Soria-<version>-macOS-unnotarized.dmg`
   - 직접 앱 archive용 `Soria-<version>-macOS-unnotarized.zip`
3. 필요하면 matching `.sha256` 파일로 다운로드한 파일을 검증합니다.

   ```bash
   shasum -a 256 Soria-0.1.0-macOS-unnotarized.dmg
   cat Soria-0.1.0-macOS-unnotarized.dmg.sha256

   shasum -a 256 Soria-0.1.0-macOS-unnotarized.zip
   cat Soria-0.1.0-macOS-unnotarized.zip.sha256
   ```

4. DMG는 파일을 열고 `Soria.app`을 `Applications`로 드래그합니다.
5. ZIP은 더블클릭해 `Soria.app`을 추출한 뒤 `Applications`로 옮깁니다.
6. Soria를 실행합니다. macOS가 앱을 막으면 **시스템 설정 > 개인정보 보호 및
   보안 > Open Anyway**를 사용합니다.

GitHub는 모든 릴리스에 **Source code (zip)** 다운로드도 표시합니다. 이 파일은
소스 코드일 뿐입니다. 직접 빌드하지 않고 Soria를 설치하려면 위의 앱 ZIP 또는
DMG를 사용하세요.

DMG 또는 앱 ZIP은 실행 자체를 위해 `SORIA_PYTHON`과 `SORIA_WORKER_SCRIPT`를
직접 설정할 필요가 없습니다. 앱과 bundled analysis-worker source scripts가 함께
포함되기 때문입니다. 현재 zero-cost package는 portable Python virtual environment를
vendor하지 않습니다. 설치된 앱에서 worker validation이 실패하면 **Settings >
Analysis Worker**에서 호환되는 Python 환경을 지정하거나, 소스에서 빌드하고 repo의
`analysis-worker/.venv`를 사용하세요. `SORIA_PYTHON`과 `SORIA_WORKER_SCRIPT`는
developer/runtime override입니다. 임베딩 기반 추천을 사용하려는 경우에만 Gemini API
key를 설정하거나 붙여 넣으면 됩니다.

### 소스에서 빌드

요구사항:

- 최신 Xcode 버전이 설치된 macOS.
- analysis worker용 Python 3.11 이상 권장.
- 임베딩 기반 추천에는 Gemini API key가 필요합니다.
  [Google AI Studio API Keys page](https://aistudio.google.com/app/apikey)에서
  발급 및 관리한 뒤 `GEMINI_API_KEY`로 설정하세요.

Gemini API 무료 티어 참고:

Google 공식 가격 문서는
[Gemini Embedding 2 Preview](https://ai.google.dev/gemini-api/docs/pricing#gemini-embedding-2-preview)와
[Gemini Embedding](https://ai.google.dev/gemini-api/docs/pricing#gemini-embedding)의
standard input을 Gemini API Free Tier에서 무료로 표시합니다. 다만
[rate limit 문서](https://ai.google.dev/gemini-api/docs/rate-limits)에 따르면
한도는 project 단위이고, RPD는 태평양 시간 자정에 reset되며, 실제 active limit은
달라질 수 있습니다. 큰 배치 분석 전에는 AI Studio에서 현재 quota를 확인하세요.
AI Studio에 Gemini Embedding이 약 1,000 RPD로 표시된다면 이는 하루 약 1,000개의
embedding API request라는 뜻이지, 1,000곡 처리를 보장한다는 뜻은 아닙니다. Soria는
캐시되지 않은 오디오 세그먼트마다 embedding request를 보낼 수 있고, text embedding은
`SORIA_EMBED_BATCH_SIZE`로 batch 처리될 수 있습니다.

Python worker 설정:

```bash
cd analysis-worker
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cd ..
```

Xcode scheme 또는 shell에 환경 변수를 설정합니다.

- `GEMINI_API_KEY`, Google AI Studio에서 발급한 값
- `SORIA_PYTHON`, 예: `analysis-worker/.venv/bin/python`
- `SORIA_WORKER_SCRIPT`, 예: `analysis-worker/main.py`
- 선택: `SORIA_EMBED_BATCH_SIZE`
- 선택: `SORIA_EMBED_TIMEOUT_SEC`

Terminal에서 빌드:

```bash
make build
```

빌드 후 실행:

```bash
make run
```

clean, build, launch:

```bash
make run-clean
```

초기 릴리스 DMG와 ZIP asset 생성:

```bash
VERSION=0.1.0 make release-dmg
```

생성된 릴리스 산출물은 `dist/`에 기록됩니다.

```text
dist/Soria-0.1.0-macOS-unnotarized.dmg
dist/Soria-0.1.0-macOS-unnotarized.dmg.sha256
dist/Soria-0.1.0-macOS-unnotarized.zip
dist/Soria-0.1.0-macOS-unnotarized.zip.sha256
```

GitHub Releases workflow는 [docs/RELEASING.md](docs/RELEASING.md)를 참고하세요.

### 전체 사용 가이드

1. **설치 경로를 선택합니다.** 초기 수동 설치에는 release DMG/ZIP을 사용하고,
   Python worker runtime을 완전히 제어하고 싶다면 소스에서 빌드합니다. 임베딩 기반
   추천에는 Google AI Studio의 Gemini API key가 필요합니다. Soria Settings에
   붙여 넣거나 `GEMINI_API_KEY`로 제공할 수 있습니다.

2. **분석 설정을 검증합니다.** 릴리스 빌드에서는 Settings를 열어 active embedding
   profile을 검증합니다. 소스 빌드에서는 `analysis-worker/requirements.txt`를
   `analysis-worker/.venv`에 설치한 뒤, 필요하면 `SORIA_PYTHON`과
   `SORIA_WORKER_SCRIPT`를 설정하거나 감지합니다.

3. **음악 폴더를 추가합니다.** Soria를 열고 Settings 또는 Library에서 트랙이 들어
   있는 하나 이상의 root folder를 추가합니다.

4. **라이브러리를 스캔합니다.** scan을 시작해 지원되는 오디오 파일을 색인합니다.
   Soria는 이후 scan에서 변경되지 않은 파일을 건너뛰기 위해 modification time과
   content hash를 사용합니다.

5. **사용 가능한 DJ 메타데이터를 가져옵니다.** DJ software에서 cue point, BPM,
   key, crate, playlist를 이미 관리하고 있다면 Rekordbox XML 또는 Serato CSV
   metadata를 가져옵니다.

6. **트랙을 분석합니다.** 트랙 하나를 분석하거나 pending track을 batch analyze합니다.
   worker는 추천을 위해 audio feature, waveform preview, segment summary, descriptor를
   추출합니다.

7. **트랙 세부 정보를 검토합니다.** track detail view에서 metadata, waveform-derived
   preview, analysis confidence, cue information, segment structure를 확인합니다.

8. **추천을 생성합니다.** seed track을 선택하고 Soria에 호환되는 다음 트랙 후보를
   요청합니다. 점수는 segment similarity, tempo/key context, energy shape,
   사용 가능한 DJ metadata를 결합합니다.

9. **필요하면 오디오를 normalize합니다.** 제안된 normalization은 활성 라이브러리 파일을
   정규화된 파일로 교체하고, 원본 파일은 원래 파일명 그대로 macOS 휴지통으로
   보냅니다. 그래서 Finder의 **Put Back**으로 더 자연스럽게 복구할 수 있습니다.
   휴지통 이동을 사용할 수 없는 경우에는 트랙 옆에 timestamp backup을 남기고
   경고를 표시합니다.

10. **플레이리스트 경로를 만듭니다.** 추천을 사용해 라이브러리 안의 candidate path를
    조립하고, export 전에 순서를 직접 다듬습니다.

11. **DJ software용으로 내보냅니다.** Rekordbox XML 또는 Serato-safe package를
    내보냅니다. Serato export는 의도적으로 비파괴적이며 local crate file을 직접
    rewrite하지 않습니다.

12. **필요하면 로그를 확인합니다.** 분석이 실패하면 Soria log와 worker stderr를
    확인합니다. 대부분의 실패는 누락된 Python package, 누락된 API key, 또는 local
    decoder가 읽을 수 없는 오디오 파일 때문입니다.

### 아키텍처

```text
Soria/
├── Soria/                 SwiftUI macOS 앱
│   ├── Models/            Track, segment, recommendation, metadata 모델
│   ├── Services/          SQLite, scanner, worker IPC, export, logging
│   ├── ViewModels/        App workflow와 background state
│   └── Views/             Library, recommendations, exports, settings
├── analysis-worker/       Python audio analysis 및 vector worker
│   ├── audio/             Feature extraction 및 segmentation
│   ├── embedding/         Gemini embedding client
│   ├── vectordb/          Local Chroma vector persistence
│   ├── dj_metadata/       External metadata adapter
│   └── exporters/         Shared export helper
├── SoriaTests/            macOS unit tests
├── SoriaUITests/          macOS UI tests
├── Scripts/               Local build, run, DMG scripts
└── docs/                  Workflow, release, distribution notes
```

### 검증

유용한 확인 명령:

```bash
make build
make test-worker
make test-swift
VERSION=0.1.0 make release-dmg
```

Python 테스트는 active interpreter에 worker dependency가 설치되어 있어야 합니다.
`make test-swift`는 CI Swift unit-test set을 실행합니다. playback preview,
waveform seeking, timing behavior를 바꿀 때는 `make test-swift-full`을 사용하세요.
macOS UI/unit test는 일부 sandboxed environment에서 사용할 수 없는 local system
service가 필요할 수 있습니다.

### 알려진 제한사항

- 초기 DMG는 notarized 상태가 아니므로 Gatekeeper 경고가 예상됩니다.
- 직접 만든 DMG/ZIP build는 현재 worker script만 포함하고 portable Python virtual
  environment는 포함하지 않습니다.
- 오디오 feature extraction은 local Python package에 의존합니다.
- waveform preview는 파생 분석 데이터이며 sample-accurate editor가 아닙니다.
- Rekordbox XML import/export는 일반적인 XML 구조를 대상으로 합니다. 특이한 vendor
  version은 추가 adapter가 필요할 수 있습니다.
- Serato export는 의도적으로 보수적이고 비파괴적입니다.
- 추천 품질은 local metadata quality와 embedding availability에 따라 달라집니다.

### 개인정보 보호 및 보안

Soria는 library database, analysis summary, waveform preview, vector persistence를
Mac에 저장합니다. Gemini embedding profile은 embedding 요청을 위해 짧은 파생 segment
payload, descriptor text, query text, metadata context를 보낼 수 있지만, Soria는
원본 전체 음악 파일이나 로컬 라이브러리 데이터베이스를 의도적으로 업로드하지 않습니다.

이슈나 pull request를 열기 전에 API key, private music file, private DJ database,
redaction되지 않은 home-directory path, private log를 제거하세요. 보안 문제는
[SECURITY.md](SECURITY.md)의 절차에 따라 비공개로 보고해 주세요.

### 기여

이슈, Discussions, focused pull request를 환영합니다. metadata fixture, export
compatibility, 대규모 라이브러리 성능, DJ workflow 문서는 좋은 첫 기여 영역입니다.

pull request를 열기 전에 [CONTRIBUTING.md](CONTRIBUTING.md)를 읽어 주세요. 큰 변경은
먼저 issue를 열고, 각 pull request는 하나의 issue 또는 하나의 명확한 root cause에
연결해 주세요.

---

## 日本語

SoriaはローカルファーストなmacOS DJミックスアシスタントです。ユーザーが選択した
フォルダをスキャンし、音楽ライブラリをローカルでインデックス化し、トラック構造を
解析し、互換性のある次の候補曲を推薦し、DJライブラリで扱いやすいプレイリストを
書き出します。音楽ファイル全体やライブラリデータベースはアップロードしません。

### 主な機能

- ユーザーが選択した音楽フォルダからローカルトラックライブラリを作成します。
- ミックス計画のためにintro、middle、outroセグメントを抽出します。
- ローカルのオーディオメタデータと任意のDJライブラリメタデータを読み込みます。
- 解析済みトラックセグメント、query text、メタデータcontextから埋め込みを生成します。
- ライブラリはSQLiteに、ベクトルはローカルChroma persistenceに保存します。
- 透明なスコア内訳付きでトランジション候補を推薦します。
- Rekordbox XMLと非破壊のSerato-safeパッケージを書き出します。

Soriaは、音楽コレクションをリモートサービスに預けずに推薦支援を使いたいDJ向けに
設計されています。オーディオ解析はMac上に残ります。埋め込みリクエストでは、短い
派生オーディオセグメントpayloadとquery textがGeminiへ送信される場合がありますが、
元のファイル全体とローカルライブラリデータベースはMac上に残ります。

### 現在のリリース状況

Soriaは初期のオープンソース配布段階です。

- ソースコードはGitHubで公開されています。
- 初期ビルドはGitHub Releasesを通じてDMGとZIPファイルとして配布されます。
- リリースアプリの成果物はad-hoc署名されていますが、Developer ID署名や
  notarizationは行われていません。
- これらの初期ビルドではmacOS Gatekeeperの警告が想定されます。

ソースを信頼できる場合は、**System Settings > Privacy & Security > Open Anyway**
からアプリを開くか、Xcodeで自分でビルドできます。

### 開発支援

Soriaは[GitHub Sponsors](https://github.com/sponsors/Ssojux2)と
[Buy Me a Coffee](https://buymeacoffee.com/ssojux2)で支援できます。支援は今後の
音楽関連アプリ開発に使われます。

### ライセンス

Soriaは[MIT License](LICENSE)で公開されています。コントリビューターが明示的に
別の条件を示さない限り、コントリビューションも同じライセンスで受け入れます。

### ドキュメント

- [Program Workflows](docs/WORKFLOWS.md)では、アプリがsetup、scanning、
  analysis、recommendation、normalization、exportをどのように進むかを説明します。
- [Release Notes](docs/RELEASING.md)では、現在のGitHub Releases、DMG、ZIP、
  checksum、Gatekeeper警告のworkflowを説明します。
- [Privacy](PRIVACY.md)では、ローカル保存、Keychainの使用、Gemini embedding
  request、安全なissue報告方法を説明します。
- [Contributing](CONTRIBUTING.md)、[Support](SUPPORT.md)、
  [Security](SECURITY.md)では、安全に参加する方法を説明します。
- [Third-Party Notices](THIRD_PARTY_NOTICES.md)では、現在のソースとリリース方式に
  関する直接依存関係のライセンスメタデータを要約しています。

### GitHub Releasesから直接インストール

1. [Releases](https://github.com/Ssojux2/Soria/releases)ページを開きます。
2. 次のいずれかのリリースassetをダウンロードします。
   - drag-and-dropインストーラー用の`Soria-<version>-macOS-unnotarized.dmg`
   - 直接アプリarchiveとして使う`Soria-<version>-macOS-unnotarized.zip`
3. 必要に応じて、対応する`.sha256`ファイルでダウンロードしたファイルを検証します。

   ```bash
   shasum -a 256 Soria-0.1.0-macOS-unnotarized.dmg
   cat Soria-0.1.0-macOS-unnotarized.dmg.sha256

   shasum -a 256 Soria-0.1.0-macOS-unnotarized.zip
   cat Soria-0.1.0-macOS-unnotarized.zip.sha256
   ```

4. DMGの場合は開いて、`Soria.app`を`Applications`へドラッグします。
5. ZIPの場合はダブルクリックして`Soria.app`を展開し、`Applications`へ移動します。
6. Soriaを起動します。macOSがアプリをブロックする場合は、**System Settings >
   Privacy & Security > Open Anyway**を使います。

GitHubは各リリースに**Source code (zip)**ダウンロードも表示します。このファイルは
ソースコードのみです。自分でビルドせずにSoriaをインストールしたい場合は、上記の
アプリZIPまたはDMGを使ってください。

DMGまたはアプリZIPは、起動そのものに`SORIA_PYTHON`と
`SORIA_WORKER_SCRIPT`の手動設定を必要としません。アプリとbundled
analysis-worker source scriptsが含まれているためです。現在のzero-cost packageは
portable Python virtual environmentをvendorしていません。インストール済みアプリで
worker validationが失敗する場合は、**Settings > Analysis Worker**で互換性のある
Python環境を指定するか、ソースからビルドしてrepoの`analysis-worker/.venv`を使って
ください。`SORIA_PYTHON`と`SORIA_WORKER_SCRIPT`はdeveloper/runtime overrideです。
埋め込みベースの推薦を使う場合にのみGemini API keyを設定または貼り付けてください。

### ソースからビルド

要件:

- 最近のXcodeがインストールされたmacOS。
- analysis workerにはPython 3.11以上を推奨。
- 埋め込みベースの推薦にはGemini API keyが必要です。
  [Google AI Studio API Keys page](https://aistudio.google.com/app/apikey)で
  作成・管理し、`GEMINI_API_KEY`として設定してください。

Gemini API無料枠の注意:

Googleの公式価格ページでは、
[Gemini Embedding 2 Preview](https://ai.google.dev/gemini-api/docs/pricing#gemini-embedding-2-preview)と
[Gemini Embedding](https://ai.google.dev/gemini-api/docs/pricing#gemini-embedding)の
standard inputがGemini API Free Tierで無料とされています。ただし
[rate limit documentation](https://ai.google.dev/gemini-api/docs/rate-limits)では、
上限はproject単位で、RPDはPacific timeの午前0時にresetされ、active limitは変わる
場合があると説明されています。大きなbatch解析の前にAI Studioで現在のquotaを確認
してください。AI StudioでGemini Embeddingが約1,000 RPDと表示される場合、それは
1日あたり約1,000件のembedding API requestという意味であり、1,000曲の処理を保証する
ものではありません。Soriaはcacheされていないaudio segmentごとにembedding requestを
送る場合があり、text embeddingは`SORIA_EMBED_BATCH_SIZE`でbatch処理できます。

Python workerの設定:

```bash
cd analysis-worker
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cd ..
```

Xcode schemeまたはshellで環境変数を設定します。

- `GEMINI_API_KEY`: Google AI Studioで発行した値
- `SORIA_PYTHON`: 例 `analysis-worker/.venv/bin/python`
- `SORIA_WORKER_SCRIPT`: 例 `analysis-worker/main.py`
- 任意: `SORIA_EMBED_BATCH_SIZE`
- 任意: `SORIA_EMBED_TIMEOUT_SEC`

Terminalからビルド:

```bash
make build
```

ビルドして起動:

```bash
make run
```

clean、build、launch:

```bash
make run-clean
```

初期リリースのDMGとZIP assetを作成:

```bash
VERSION=0.1.0 make release-dmg
```

生成されたリリース成果物は`dist/`に書き込まれます。

```text
dist/Soria-0.1.0-macOS-unnotarized.dmg
dist/Soria-0.1.0-macOS-unnotarized.dmg.sha256
dist/Soria-0.1.0-macOS-unnotarized.zip
dist/Soria-0.1.0-macOS-unnotarized.zip.sha256
```

GitHub Releases workflowについては[docs/RELEASING.md](docs/RELEASING.md)を参照してください。

### 詳細な使い方

1. **インストール方法を選びます。** 初期の手動インストールにはrelease DMG/ZIPを
   使い、Python worker runtimeを完全に制御したい場合はソースからビルドします。
   埋め込みベースの推薦にはGoogle AI StudioのGemini API keyが必要です。Soria
   Settingsに貼り付けるか、`GEMINI_API_KEY`として提供できます。

2. **解析設定を検証します。** リリースビルドではSettingsを開き、active embedding
   profileを検証します。ソースビルドでは`analysis-worker/requirements.txt`を
   `analysis-worker/.venv`へインストールし、必要に応じて`SORIA_PYTHON`と
   `SORIA_WORKER_SCRIPT`を設定または検出します。

3. **音楽フォルダを追加します。** Soriaを開き、SettingsまたはLibraryでトラックを
   含む1つ以上のroot folderを追加します。

4. **ライブラリをスキャンします。** scanを開始して、対応するオーディオファイルを
   インデックス化します。Soriaは後続のscanで未変更ファイルをスキップするために
   modification timeとcontent hashを使います。

5. **利用可能なDJメタデータを取り込みます。** DJ softwareでcue point、BPM、key、
   crate、playlistをすでに管理している場合は、Rekordbox XMLまたはSerato CSV
   metadataを取り込みます。

6. **トラックを解析します。** 1曲を解析するか、pending trackをbatch analyzeします。
   workerは推薦のためにaudio feature、waveform preview、segment summary、descriptorを
   抽出します。

7. **トラック詳細を確認します。** track detail viewでmetadata、waveform-derived
   preview、analysis confidence、cue information、segment structureを確認します。

8. **推薦を生成します。** seed trackを選択し、互換性のある次の候補曲をSoriaに
   生成させます。スコアはsegment similarity、tempo/key context、energy shape、
   利用可能なDJ metadataを組み合わせます。

9. **必要に応じてオーディオをnormalizeします。** 提案されたnormalizationはアクティブな
   ライブラリファイルを正規化済みファイルに置き換え、元ファイルは元の
   ファイル名のままmacOSのTrashへ移動します。そのためFinderの**Put Back**で
   より自然に復元できます。Trashを使えない場合は、トラックの横にtimestamp
   backupを残して警告を表示します。

10. **プレイリストの流れを作ります。** 推薦を使ってライブラリ内のcandidate pathを
    組み立て、export前に順序を手動で調整します。

11. **DJ software向けに書き出します。** Rekordbox XMLまたはSerato-safe packageを
    書き出します。Serato exportは意図的に非破壊で、local crate fileを直接rewrite
    しません。

12. **必要に応じてログを確認します。** 解析が失敗した場合は、Soria logとworker
    stderrを確認します。多くの失敗は、Python packageの不足、API keyの不足、または
    local decoderが読めないオーディオファイルが原因です。

### アーキテクチャ

```text
Soria/
├── Soria/                 SwiftUI macOSアプリ
│   ├── Models/            Track、segment、recommendation、metadataモデル
│   ├── Services/          SQLite、scanner、worker IPC、export、logging
│   ├── ViewModels/        App workflowとbackground state
│   └── Views/             Library、recommendations、exports、settings
├── analysis-worker/       Python audio analysisとvector worker
│   ├── audio/             Feature extractionとsegmentation
│   ├── embedding/         Gemini embedding client
│   ├── vectordb/          Local Chroma vector persistence
│   ├── dj_metadata/       External metadata adapter
│   └── exporters/         Shared export helper
├── SoriaTests/            macOS unit tests
├── SoriaUITests/          macOS UI tests
├── Scripts/               Local build、run、DMG scripts
└── docs/                  Workflow、release、distribution notes
```

### 検証

有用な確認コマンド:

```bash
make build
make test-worker
make test-swift
VERSION=0.1.0 make release-dmg
```

Python testsを実行するには、active interpreterにworker dependenciesがインストール
されている必要があります。`make test-swift`はCI Swift unit-test setを実行します。
playback preview、waveform seeking、timing behaviorを変更する場合は
`make test-swift-full`を使ってください。macOS UI/unit testsは、一部のsandboxed
environmentでは利用できないlocal system servicesを必要とする場合があります。

### 既知の制限

- 初期DMGはnotarizedされていないため、Gatekeeper警告が想定されます。
- 直接作成するDMG/ZIP buildは現在worker scriptsを同梱しますが、portable Python
  virtual environmentは同梱しません。
- オーディオfeature extractionはlocal Python packagesに依存します。
- waveform previewは派生解析データであり、sample-accurate editorではありません。
- Rekordbox XML import/exportは一般的なXML構造を対象にしています。特殊なvendor
  versionには追加adapterが必要になる場合があります。
- Serato exportは意図的に保守的かつ非破壊です。
- 推薦品質はlocal metadata qualityとembedding availabilityに依存します。

### プライバシーとセキュリティ

Soriaはlibrary database、analysis summary、waveform preview、vector persistenceを
Mac上に保存します。Gemini embedding profileは、embedding requestのために短い派生
segment payload、descriptor text、query text、metadata contextを送信する場合が
ありますが、Soriaは元の音楽ファイル全体やローカルライブラリデータベースを意図的に
アップロードしません。

issueやpull requestを開く前に、API key、private music file、private DJ database、
redactionされていないhome-directory path、private logを削除してください。セキュリティ
問題は[SECURITY.md](SECURITY.md)の手順に従って非公開で報告してください。

### コントリビューション

Issues、Discussions、focused pull requestsを歓迎します。metadata fixtures、export
compatibility、大規模ライブラリでのperformance、DJ workflow documentationはよい最初の
コントリビューション領域です。

pull requestを開く前に[CONTRIBUTING.md](CONTRIBUTING.md)を読んでください。大きな変更は
先にissueを開き、各pull requestは1つのissueまたは1つの明確なroot causeに紐づけて
ください。
