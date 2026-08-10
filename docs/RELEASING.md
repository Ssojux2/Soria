# Releasing Soria

This is the initial zero-cost distribution path for public open-source builds:
GitHub source, GitHub Releases, and ad-hoc signed macOS DMG/ZIP assets.

## Distribution Status

The macOS app produced by this repo is:

- Built from the `Soria` Xcode scheme.
- Ad-hoc signed with `codesign --sign -`.
- Not signed with an Apple Developer ID certificate.
- Not notarized by Apple.
- Bundled with the `analysis-worker` source scripts and an arch-specific
  portable Python worker runtime.

That means macOS Gatekeeper warnings are expected. This avoids Apple Developer
Program cost for the early phase, but it is less friendly for non-technical
users than a Developer ID signed and notarized release.

Analysis features in DMG/ZIP installs use the bundled worker runtime. Source
builds should use `analysis-worker/.venv` with `analysis-worker/requirements.txt`
installed.

## Local Release Build

Build the app and create release DMG/ZIP assets:

```bash
make release-dmg
```

Build a specific version:

```bash
VERSION=0.1.0 make release-dmg
```

Clean first if you want a fully fresh package:

```bash
./Scripts/create_release_dmg.sh --clean --version 0.1.0
```

Artifacts are written to `dist/`:

```text
dist/Soria-0.1.0-macOS-arm64-unnotarized.dmg
dist/Soria-0.1.0-macOS-arm64-unnotarized.dmg.sha256
dist/Soria-0.1.0-macOS-arm64-unnotarized.zip
dist/Soria-0.1.0-macOS-arm64-unnotarized.zip.sha256
```

Set `SORIA_RELEASE_ARCH=x86_64` to build the Intel artifact on an Intel runner.
Universal Python runtime merging is intentionally out of scope for the early
release path.

## GitHub Releases

The release workflow runs when a `v*` tag is pushed:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The workflow creates or updates a draft GitHub Release and uploads the DMG/ZIP
files plus SHA-256 checksums. Review the draft notes on GitHub before publishing.
The release should remain a draft until the install warning, checksum list, and
release notes have been reviewed.

## Release Notes Template

Use this warning in early release notes:

```text
This is an early open-source macOS build. It is ad-hoc signed, but it is not
Developer ID signed or notarized by Apple. macOS will show a security warning.
If you trust this source, open System Settings > Privacy & Security and choose
Open Anyway, or build the app from source with Xcode.

Soria source code is distributed under the MIT License.
```

## Public Repository Checklist

- Confirm the MIT `LICENSE` file is present and detected by GitHub.
- Confirm `.env`, API keys, sample music paths, and local caches are not tracked.
- Confirm private Xcode `xcuserdata` files are not tracked.
- Confirm `CONTRIBUTING.md`, `SECURITY.md`, `SUPPORT.md`, `PRIVACY.md`, issue
  templates, and the pull request template are present.
- Run `make release-dmg` and verify the DMG mounts and ZIP extracts.
- Verify the bundled worker runtime with Settings validation or a worker
  healthcheck from inside the app bundle.
- Check `THIRD_PARTY_NOTICES.md` before changing bundled dependencies.
- Upload the DMG, ZIP, and matching `.sha256` checksums.
- Keep the release marked as draft until the README and install warning are clear.

## Later Upgrade Path

When the app has real users, the next packaging step is Developer ID signing and
Apple notarization. After that, Homebrew Cask and Sparkle updates become much
more practical.
