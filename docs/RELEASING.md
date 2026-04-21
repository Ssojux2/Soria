# Releasing Soria

This is the initial zero-cost distribution path for public open-source builds:
GitHub source, GitHub Releases, and an ad-hoc signed DMG.

## Distribution Status

The DMG produced by this repo is:

- Built from the `Soria` Xcode scheme.
- Ad-hoc signed with `codesign --sign -`.
- Not signed with an Apple Developer ID certificate.
- Not notarized by Apple.

That means macOS Gatekeeper warnings are expected. This avoids Apple Developer
Program cost for the early phase, but it is less friendly for non-technical
users than a Developer ID signed and notarized release.

## Local DMG Build

Build the app and create a release DMG:

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
dist/Soria-0.1.0-macOS-unnotarized.dmg
dist/Soria-0.1.0-macOS-unnotarized.dmg.sha256
```

## GitHub Releases

The release workflow runs when a `v*` tag is pushed:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The workflow creates or updates a draft GitHub Release and uploads the DMG plus
SHA-256 checksum. Review the draft notes on GitHub before publishing.

## Release Notes Template

Use this warning in early release notes:

```text
This is an early open-source macOS build. It is ad-hoc signed, but it is not
Developer ID signed or notarized by Apple. macOS will show a security warning.
If you trust this source, open System Settings > Privacy & Security and choose
Open Anyway, or build the app from source with Xcode.
```

## Public Repository Checklist

- Choose and add an open-source license before making the repository public.
- Confirm `.env`, API keys, sample music paths, and local caches are not tracked.
- Run `make release-dmg` and verify the DMG mounts.
- Upload both the DMG and `.sha256` checksum.
- Keep the release marked as draft until the README and install warning are clear.

## Later Upgrade Path

When the app has real users, the next packaging step is Developer ID signing and
Apple notarization. After that, Homebrew Cask and Sparkle updates become much
more practical.
