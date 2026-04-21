# Soria

[![Sponsor](https://img.shields.io/badge/Sponsor-GitHub%20Sponsors-EA4AAA)](https://github.com/sponsors/Ssojux2)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-ssojux2-FFDD00?logo=buymeacoffee&logoColor=000000)](https://buymeacoffee.com/ssojux2)
[![Release macOS assets](https://github.com/Ssojux2/Soria/actions/workflows/release-dmg.yml/badge.svg)](https://github.com/Ssojux2/Soria/actions/workflows/release-dmg.yml)

Soria is a local-first macOS DJ mix assistant. It scans folders you choose,
indexes your music library locally, analyzes track structure, recommends
compatible next tracks, and exports DJ-library-friendly playlists without
uploading raw audio.

Languages: [English](#english) | [한국어](#한국어) | [日本語](#日本語)

## English

### What Soria Does

- Builds a local track library from user-selected music folders.
- Extracts intro, middle, and outro segments for mix planning.
- Reads local audio metadata and optional DJ-library metadata.
- Generates descriptor embeddings from analysis summaries and metadata.
- Stores the library in SQLite and vectors in local Chroma persistence.
- Recommends transition candidates with transparent score breakdowns.
- Exports Rekordbox XML and a non-destructive Serato-safe package.

Soria is designed for DJs who want recommendation support without handing their
music collection to a remote service. Audio analysis stays on your Mac. Embedding
requests use descriptor text derived from analysis and metadata, not raw audio.

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
and [Buy Me a Coffee](https://buymeacoffee.com/ssojux2). Sponsorship helps
cover future Developer ID signing/notarization costs, test fixtures,
documentation, and continued macOS packaging work.

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

### Build From Source

Requirements:

- macOS with a recent Xcode version.
- Python 3.11+ recommended for the analysis worker.
- A Gemini API key if you want embedding-based recommendations.

Set up the Python worker:

```bash
cd analysis-worker
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cd ..
```

Configure environment variables in your Xcode scheme or shell:

- `GEMINI_API_KEY`
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

1. **Create your local worker environment.** Install the Python dependencies in
   `analysis-worker/.venv` and set `SORIA_PYTHON` and `SORIA_WORKER_SCRIPT`.

2. **Add music folders.** Open Soria, go to Settings or Library, and add one or
   more root folders that contain your tracks.

3. **Scan the library.** Start a scan to index supported audio files. Soria uses
   modified time and content hashing to skip unchanged files on later scans.

4. **Import DJ metadata when available.** Import Rekordbox XML or Serato CSV
   metadata if you already maintain cue points, BPM, keys, crates, or playlists
   in DJ software.

5. **Analyze tracks.** Analyze one track or batch-analyze pending tracks. The
   worker extracts audio features, waveform previews, segment summaries, and
   descriptors for recommendation.

6. **Review track details.** Use the track detail view to inspect metadata,
   waveform-derived previews, analysis confidence, cue information, and segment
   structure.

7. **Generate recommendations.** Select a seed track and ask Soria for compatible
   next-track candidates. Scores combine segment similarity, tempo/key context,
   energy shape, and available DJ metadata.

8. **Build playlist paths.** Use recommendations to assemble a candidate path
   through your library, then refine the order manually before export.

9. **Export for DJ software.** Export Rekordbox XML or the Serato-safe package.
   Serato export is intentionally non-destructive and does not directly rewrite
   local crate files.

10. **Check logs when needed.** If analysis fails, inspect Soria logs and worker
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
└── docs/                  Release and distribution notes
```

### Validation

Useful checks:

```bash
make build
python3 -m pytest analysis-worker/tests
VERSION=0.1.0 make release-dmg
```

The Python tests require the active interpreter to have the worker dependencies
installed. macOS UI/unit tests may require local system services that are not
available in every sandboxed environment.

### Known Limitations

- Early DMGs are not notarized, so Gatekeeper warnings are expected.
- Audio feature extraction depends on local Python packages.
- The waveform preview is derived analysis data, not a sample-accurate editor.
- Rekordbox XML import/export targets common XML structures; unusual vendor
  versions may need more adapters.
- Serato export is deliberately conservative and non-destructive.
- Recommendation quality depends on local metadata quality and embedding
  availability.

### Contributing

Issues, discussions, and focused pull requests are welcome after the repository
is public. Good first areas include metadata fixtures, export compatibility,
performance on large libraries, and documentation for DJ workflows.

Before making the repository fully public, choose and add an open-source license.

---

## 한국어

Soria는 DJ를 위한 로컬 우선 macOS 믹스 어시스턴트입니다. 사용자가 선택한 음악
폴더를 스캔하고, 트랙의 intro/middle/outro 구간을 분석하며, 로컬 메타데이터와
분석 결과를 바탕으로 다음에 믹스하기 좋은 트랙을 추천합니다. 원본 오디오는
업로드하지 않고, 라이브러리와 벡터 데이터도 Mac 안에 저장합니다.

### 주요 기능

- 선택한 폴더 기반 로컬 음악 라이브러리 생성
- 트랙 구간, 파형 미리보기, BPM/key/에너지 관련 분석
- Rekordbox XML 및 Serato CSV 메타데이터 가져오기
- Gemini Embeddings 기반 설명자 임베딩
- SQLite와 로컬 Chroma 저장소 사용
- 전환 후보 추천 및 점수 근거 확인
- Rekordbox XML, Serato-safe 패키지 내보내기

### 설치

1. [Releases](https://github.com/Ssojux2/Soria/releases)에서 최신
   `Soria-<version>-macOS-unnotarized.dmg` 또는
   `Soria-<version>-macOS-unnotarized.zip`을 받습니다.
2. DMG는 파일을 열고 `Soria.app`을 `Applications`로 옮깁니다.
3. ZIP은 압축을 풀어 나온 `Soria.app`을 `Applications`로 옮깁니다.
4. GitHub의 **Source code (zip)** 파일은 설치용 앱이 아니라 소스 코드입니다.
5. 초기 빌드는 Developer ID 서명 및 Apple notarization이 되어 있지 않으므로
   macOS 경고가 뜰 수 있습니다.
6. 신뢰할 수 있는 소스라고 판단하면 **시스템 설정 > 개인정보 보호 및 보안 >
   Open Anyway**로 실행하거나, Xcode로 직접 빌드합니다.

### 소스에서 빌드

```bash
cd analysis-worker
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cd ..
make run
```

필요한 환경 변수:

- `GEMINI_API_KEY`
- `SORIA_PYTHON`
- `SORIA_WORKER_SCRIPT`

### 기본 사용 방법

1. Settings 또는 Library에서 음악 루트 폴더를 추가합니다.
2. Scan을 실행해 로컬 라이브러리를 만듭니다.
3. 필요하면 Rekordbox XML 또는 Serato CSV 메타데이터를 가져옵니다.
4. 트랙 분석을 실행합니다.
5. seed track을 선택하고 추천 후보를 확인합니다.
6. 후보를 바탕으로 플레이리스트 경로를 다듬습니다.
7. Rekordbox XML 또는 Serato-safe 패키지로 내보냅니다.

개발을 후원하려면 [GitHub Sponsors](https://github.com/sponsors/Ssojux2) 또는
[Buy Me a Coffee](https://buymeacoffee.com/ssojux2)를 이용해 주세요. 후원은
향후 Developer ID 서명, notarization, 테스트 fixture, 문서화 작업에 사용됩니다.

---

## 日本語

SoriaはDJ向けのローカルファーストなmacOSミックスアシスタントです。選択した
音楽フォルダをスキャンし、トラックのintro/middle/outroを解析し、ローカルの
メタデータと解析結果を使って次にミックスしやすい曲を推薦します。元の音声は
アップロードせず、ライブラリとベクトルデータもMac上に保存します。

### 主な機能

- 選択したフォルダからローカル音楽ライブラリを作成
- トラック構造、波形プレビュー、BPM/key/エネルギー情報を解析
- Rekordbox XMLとSerato CSVメタデータの取り込み
- Gemini Embeddingsを使った説明文ベースの埋め込み
- SQLiteとローカルChromaストレージ
- 次の候補曲の推薦とスコア内訳の確認
- Rekordbox XMLとSerato-safeパッケージの書き出し

### インストール

1. [Releases](https://github.com/Ssojux2/Soria/releases)から最新の
   `Soria-<version>-macOS-unnotarized.dmg`または
   `Soria-<version>-macOS-unnotarized.zip`をダウンロードします。
2. DMGの場合は開いて、`Soria.app`を`Applications`へドラッグします。
3. ZIPの場合は展開して、出てきた`Soria.app`を`Applications`へ移動します。
4. GitHubの**Source code (zip)**はインストール用アプリではなく、ソースコードです。
5. 初期ビルドはDeveloper ID署名とApple notarizationがないため、macOSの警告が表示されます。
6. ソースを信頼できる場合は、**System Settings > Privacy & Security > Open Anyway**から開くか、Xcodeで自分でビルドしてください。

### ソースからビルド

```bash
cd analysis-worker
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cd ..
make run
```

必要な環境変数:

- `GEMINI_API_KEY`
- `SORIA_PYTHON`
- `SORIA_WORKER_SCRIPT`

### 基本的な使い方

1. SettingsまたはLibraryで音楽フォルダを追加します。
2. Scanを実行してローカルライブラリを作成します。
3. 必要に応じてRekordbox XMLまたはSerato CSVメタデータを取り込みます。
4. トラック解析を実行します。
5. seed trackを選び、推薦候補を確認します。
6. 候補をもとにプレイリストの流れを調整します。
7. Rekordbox XMLまたはSerato-safeパッケージとして書き出します。

開発支援は[GitHub Sponsors](https://github.com/sponsors/Ssojux2)または
[Buy Me a Coffee](https://buymeacoffee.com/ssojux2)から可能です。支援は今後の
Developer ID署名、notarization、テストfixture、ドキュメント整備に使われます。
