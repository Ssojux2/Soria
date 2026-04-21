# Soria

[![Sponsor](https://img.shields.io/badge/Sponsor-GitHub%20Sponsors-EA4AAA)](https://github.com/sponsors/Ssojux2)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-ssojux2-FFDD00?logo=buymeacoffee&logoColor=000000)](https://buymeacoffee.com/ssojux2)
[![Release macOS assets](https://github.com/Ssojux2/Soria/actions/workflows/release-dmg.yml/badge.svg)](https://github.com/Ssojux2/Soria/actions/workflows/release-dmg.yml)

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

### Documentation

- [Program Workflows](docs/WORKFLOWS.md) explains how the app moves through
  setup, scanning, analysis, recommendation, normalization, and export.
- [Release Notes](docs/RELEASING.md) explains the current GitHub Releases,
  DMG, ZIP, checksum, and Gatekeeper-warning workflow.

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
python3 -m pytest analysis-worker/tests
VERSION=0.1.0 make release-dmg
```

The Python tests require the active interpreter to have the worker dependencies
installed. macOS UI/unit tests may require local system services that are not
available in every sandboxed environment.

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

### Contributing

Issues, discussions, and focused pull requests are welcome after the repository
is public. Good first areas include metadata fixtures, export compatibility,
performance on large libraries, and documentation for DJ workflows.

Before making the repository fully public, choose and add an open-source license.

---

## 한국어

Soria는 DJ를 위한 로컬 우선 macOS 믹스 어시스턴트입니다. 사용자가 선택한 음악
폴더를 스캔하고, 트랙의 intro/middle/outro 구간을 분석하며, 로컬 메타데이터와
분석 결과를 바탕으로 다음에 믹스하기 좋은 트랙을 추천합니다. 전체 음악 파일과
라이브러리 DB는 업로드하지 않고 Mac 안에 저장합니다. 임베딩 기반 추천에는 짧은
오디오 세그먼트 payload와 query text가 Gemini로 전송될 수 있습니다.

### 주요 기능

- 선택한 폴더 기반 로컬 음악 라이브러리 생성
- 트랙 구간, 파형 미리보기, BPM/key/에너지 관련 분석
- Rekordbox XML 및 Serato CSV 메타데이터 가져오기
- Gemini Embeddings 기반 오디오 세그먼트 및 query text 임베딩
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

DMG 또는 앱 ZIP은 실행 자체를 위해 `SORIA_PYTHON`과 `SORIA_WORKER_SCRIPT`를
직접 설정할 필요가 없습니다. 이 두 값은 개발자용 runtime override에 가깝습니다.
다만 현재 초기 패키지는 portable Python venv를 앱 안에 포함하지 않으므로, 분석
검증이 실패하면 Settings에서 호환되는 Python 환경을 지정하세요. 임베딩 기반 추천을
쓰려면 Gemini API key도 필요합니다.

### 소스에서 빌드

임베딩 기반 추천을 사용하려면
[Google AI Studio API Keys](https://aistudio.google.com/app/apikey)에서
Gemini API key를 발급받아 `GEMINI_API_KEY`로 설정해야 합니다.

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

```bash
cd analysis-worker
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cd ..
make run
```

필요한 환경 변수:

- `GEMINI_API_KEY`: Google AI Studio에서 발급한 Gemini API key
- `SORIA_PYTHON`
- `SORIA_WORKER_SCRIPT`

위 worker 환경변수는 소스 빌드에서 repo의 worker runtime을 명시하고 싶을 때
사용합니다. DMG/ZIP에서 분석 runtime을 바꾸고 싶다면 Settings의 Analysis Worker
경로를 사용하는 편이 더 자연스럽습니다.

### 문서

- [프로그램 워크플로우](docs/WORKFLOWS.md): setup, scan, analysis,
  recommendation, normalization, export 흐름을 저장소 안에서 확인할 수 있습니다.
- [릴리스 문서](docs/RELEASING.md): GitHub Releases, DMG/ZIP, checksum,
  Gatekeeper 경고 처리 흐름을 정리합니다.

### 기본 사용 방법

1. Settings 또는 Library에서 음악 루트 폴더를 추가합니다.
2. Settings에서 Gemini API key와 분석 worker 설정을 검증합니다.
3. Scan을 실행해 로컬 라이브러리를 만듭니다.
4. 필요하면 Rekordbox XML 또는 Serato CSV 메타데이터를 가져옵니다.
5. 트랙 분석을 실행합니다.
6. seed track을 선택하고 추천 후보를 확인합니다.
7. 필요하면 오디오 normalization을 실행합니다. Soria는 활성 라이브러리 파일을
   정규화된 파일로 교체하고, 원본 파일은 원래 파일명 그대로 macOS 휴지통으로
   보냅니다. 그래서 Finder의 **Put Back**으로 더 자연스럽게 복구할 수 있습니다.
   휴지통 이동을 사용할 수 없는 경우에는 트랙 옆에 timestamp backup을 남기고
   경고를 표시합니다.
8. 후보를 바탕으로 플레이리스트 경로를 다듬습니다.
9. Rekordbox XML 또는 Serato-safe 패키지로 내보냅니다.

개발을 후원하려면 [GitHub Sponsors](https://github.com/sponsors/Ssojux2) 또는
[Buy Me a Coffee](https://buymeacoffee.com/ssojux2)를 이용해 주세요. 후원은
향후 음악 관련 앱 개발에 사용됩니다.

---

## 日本語

SoriaはDJ向けのローカルファーストなmacOSミックスアシスタントです。選択した
音楽フォルダをスキャンし、トラックのintro/middle/outroを解析し、ローカルの
メタデータと解析結果を使って次にミックスしやすい曲を推薦します。音楽ファイル
全体とライブラリDBはアップロードせずMac上に保存します。埋め込みベースの推薦では、
短いオーディオセグメントpayloadとquery textがGeminiへ送信される場合があります。

### 主な機能

- 選択したフォルダからローカル音楽ライブラリを作成
- トラック構造、波形プレビュー、BPM/key/エネルギー情報を解析
- Rekordbox XMLとSerato CSVメタデータの取り込み
- Gemini Embeddingsを使ったオーディオセグメントとquery textの埋め込み
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

DMGまたはアプリZIPは、起動そのものに`SORIA_PYTHON`と
`SORIA_WORKER_SCRIPT`の手動設定を必要としません。この2つは主に開発者向けの
runtime overrideです。ただし現在の初期パッケージはportable Python venvを同梱して
いないため、解析の検証に失敗する場合はSettingsで互換性のあるPython環境を指定して
ください。埋め込みベースの推薦にはGemini API keyも必要です。

### ソースからビルド

埋め込みベースの推薦を使うには、
[Google AI Studio API Keys](https://aistudio.google.com/app/apikey)で
Gemini API keyを発行し、`GEMINI_API_KEY`として設定する必要があります。

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

```bash
cd analysis-worker
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cd ..
make run
```

必要な環境変数:

- `GEMINI_API_KEY`: Google AI Studioで発行したGemini API key
- `SORIA_PYTHON`
- `SORIA_WORKER_SCRIPT`

上記のworker環境変数は、ソースビルドでrepo内のworker runtimeを明示したい場合に
使います。DMG/ZIPで解析runtimeを変更したい場合は、SettingsのAnalysis Worker
パスを使う方が自然です。

### ドキュメント

- [Program Workflows](docs/WORKFLOWS.md): setup、scan、analysis、
  recommendation、normalization、exportの流れをリポジトリ内で確認できます。
- [Release Notes](docs/RELEASING.md): GitHub Releases、DMG/ZIP、checksum、
  Gatekeeper警告の扱いをまとめています。

### 基本的な使い方

1. SettingsまたはLibraryで音楽フォルダを追加します。
2. SettingsでGemini API keyとanalysis worker設定を検証します。
3. Scanを実行してローカルライブラリを作成します。
4. 必要に応じてRekordbox XMLまたはSerato CSVメタデータを取り込みます。
5. トラック解析を実行します。
6. seed trackを選び、推薦候補を確認します。
7. 必要に応じてオーディオnormalizationを実行します。Soriaはアクティブな
   ライブラリファイルを正規化済みファイルに置き換え、元ファイルは元の
   ファイル名のままmacOSのTrashへ移動します。そのためFinderの**Put Back**で
   より自然に復元できます。Trashを使えない場合は、トラックの横にtimestamp
   backupを残して警告を表示します。
8. 候補をもとにプレイリストの流れを調整します。
9. Rekordbox XMLまたはSerato-safeパッケージとして書き出します。

開発支援は[GitHub Sponsors](https://github.com/sponsors/Ssojux2)または
[Buy Me a Coffee](https://buymeacoffee.com/ssojux2)から可能です。支援は今後の
音楽関連アプリ開発に使われます。
