# Heartecho

[English](README.md) | [简体中文](docs/README.zh-CN.md) | [日本語](docs/README.ja.md)

Heartecho is a native macOS audio-routing workbench for creating virtual audio devices, mapping app or hardware inputs to output channels, monitoring levels, and packaging the supporting Core Audio HAL driver pieces needed for real system integration.

The product direction is inspired by tools like Rogue Amoeba Loopback, but this repository is currently an engineering preview: the SwiftUI app, routing model, diagnostics, helper runtime, installer scripts, and C HAL driver skeleton are present; a polished signed/notarized production release still depends on Developer ID signing, notarization, and full installed-driver validation.

## Product Snapshot

- Native macOS SwiftUI/AppKit app for routing graph configuration.
- Core routing model for virtual devices, sources, channel maps, monitors, gains, mutes, presets, and graph validation.
- Runtime audio scaffolding for app taps, hardware input capture, sample-rate conversion, monitor playback, meters, and HAL shared-memory publication.
- C HAL Audio Server Driver skeleton plus Swift bridge, bundle generation, verification, install, uninstall, and diagnostics scripts.
- Release packaging pipeline for app bundle, HAL driver bundle, helper LaunchAgent, installer package, uninstaller package, distribution package, and JSON release manifest.

Deeper implementation notes live in [docs/architecture.md](docs/architecture.md), [docs/feature-map.md](docs/feature-map.md), [docs/hal-driver.md](docs/hal-driver.md), and [docs/implementation-plan.md](docs/implementation-plan.md).

## Requirements

- macOS 14 or newer.
- Swift 6 toolchain.
- Xcode 16 or newer for release builds, signing, package tooling, and HAL driver work. Command Line Tools are enough for some local SwiftPM development tasks.
- Python with Pillow for icon generation. The GitHub Actions workflow creates a local virtual environment automatically.

## Download

Most users should download the latest `Heartecho-<version>.dmg` from [GitHub Releases](https://github.com/cloud-oc/goal-loopback-https-rogueamoeba-com-loopback/releases/latest).

Open the DMG, then run `Install Heartecho.pkg`. The package installs the app plus the required system audio components. The Release also includes raw `.pkg` files and `release-manifest.json` for debugging, automation, and artifact verification; the DMG is the recommended user-facing download.

### Gatekeeper Notice

The current community release is unsigned and not notarized because the project does not yet have an Apple Developer Program account. macOS may show "Apple cannot verify" or "damaged" warnings on first install.

If the installer is blocked:

1. Open the DMG and run `Install Heartecho.pkg`.
2. Open `System Settings > Privacy & Security`.
3. Click `Open Anyway` for `Install Heartecho.pkg`.
4. If macOS still blocks it after installation, remove the quarantine attribute:

```sh
sudo xattr -r -d com.apple.quarantine /Applications/Heartecho.app
sudo xattr -r -d com.apple.quarantine "/Library/Audio/Plug-Ins/HAL/Heartecho.driver"
```

Only use this for releases downloaded from this repository. This is a community workaround, not a replacement for Apple notarization.

### Homebrew

Install from this repository's third-party cask:

```sh
brew tap cloud-oc/goal-loopback-https-rogueamoeba-com-loopback https://github.com/cloud-oc/goal-loopback-https-rogueamoeba-com-loopback
brew install --cask --no-quarantine heartecho
```

Uninstall:

```sh
brew uninstall --cask heartecho
```

## Quick Start

Run the app from Swift Package Manager:

```sh
swift run Heartecho
```

Run diagnostics without making system changes:

```sh
CLANG_MODULE_CACHE_PATH=.build/clang-module-cache \
swift run --disable-sandbox HeartechoDiagnostics --skip-shared-memory
```

Build and verify a local app bundle:

```sh
scripts/build-icons.sh
scripts/build-app-bundle.sh debug
scripts/verify-app-bundle.sh
```

Build release artifacts locally:

```sh
scripts/build-release-artifacts.sh --configuration release
```

The release artifact command writes the user-facing DMG and packages to `build/pkg/`, and writes the release manifest to `build/release-manifest.json`.

## GitHub Release Automation

`VERSION` is the source of truth for GitHub Release versioning. The workflow in [.github/workflows/release.yml](.github/workflows/release.yml) runs on pushes to `main` and on manual dispatch.

The release job runs on `macos-15` and selects Xcode 16.4 so the Swift 6 package tools version in [Package.swift](Package.swift) is supported. `scripts/check-swift-toolchain.sh` fails early with a readable message if a runner falls back to an older Swift toolchain.

By default, the workflow publishes a `community-unsigned` release. Manual workflow dispatch can choose `notarized` after Developer ID certificates and Apple notarization credentials are available.

On a successful run, the workflow:

1. Reads `VERSION`.
2. Installs the Python icon-build dependency.
3. Builds and verifies the app, HAL driver, installer package, uninstaller package, distribution package, user-facing DMG, and manifest.
4. In `notarized` mode, imports Developer ID certificates, signs the deliverables, submits them for Apple notarization, and staples the accepted tickets.
5. Creates `v$(cat VERSION)` when missing, or updates the existing Release assets with `--clobber`.

GitHub Secrets required for `notarized` mode:

- `DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`: base64-encoded `.p12` for the Developer ID Application certificate.
- `DEVELOPER_ID_INSTALLER_CERTIFICATE_BASE64`: base64-encoded `.p12` for the Developer ID Installer certificate.
- `DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD` and `DEVELOPER_ID_INSTALLER_CERTIFICATE_PASSWORD`, or a shared `DEVELOPER_ID_CERTIFICATE_PASSWORD`.
- `DEVELOPER_ID_APPLICATION_IDENTITY`: for example `Developer ID Application: Your Name (TEAMID)`.
- `DEVELOPER_ID_INSTALLER_IDENTITY`: for example `Developer ID Installer: Your Name (TEAMID)`.
- `NOTARY_APPLE_ID`: Apple Developer account email.
- `NOTARY_TEAM_ID`: Apple Developer Team ID.
- `NOTARY_PASSWORD`: app-specific password for Apple notarization.
- `SIGNING_KEYCHAIN_PASSWORD`: optional temporary CI keychain password. The import script generates one when this is omitted.

For local publishing after GitHub CLI authentication:

```sh
scripts/build-release-artifacts.sh --configuration release
scripts/publish-github-release.sh
```

Use `scripts/build-release-artifacts.sh --configuration release --require-notarized` only when Developer ID signing and Apple notarization credentials are configured.

## System Integration

Heartecho cannot become a Loopback-equivalent product as a plain sandboxed app. Virtual devices require a Core Audio HAL Audio Server Driver installed in a system or user plug-in location. Per-application capture requires macOS process taps and user-granted audio capture permission. Hardware input capture requires microphone permission.

Use the install, uninstall, validation, and recovery scripts as dry runs first:

```sh
scripts/install-heartecho.sh --wait 30
scripts/uninstall-heartecho.sh --unload-helper --reload-core-audio
scripts/validate-installation.sh --wait 30
scripts/validate-installed-audio.sh --iterations 3 --wait 30
```

Add `--execute` only when signing, notarization, install locations, and local system impact are understood.

## Project Map

- `Sources/HeartechoApp`: native configuration and monitoring app.
- `Sources/HeartechoCore`: product model, presets, persistence, and graph validation.
- `Sources/HeartechoAudio`: discovery, capture scaffolds, routing runtime, mixer, monitor playback, HAL publication, and diagnostics helpers.
- `Sources/HeartechoHelper`: command-line helper for graph bootstrap and HAL config/audio publication.
- `Sources/HALDriverStub` and `Sources/HALDriverC`: Swift bridge and C HAL driver skeleton.
- `scripts`: build, verify, sign, notarize, install, uninstall, validate, recover, release, and publishing automation.
- `docs`: architecture, HAL, feature, and implementation references.

## Maintenance Model

Keep this README as the product entry point. Put detailed engineering notes in `docs/`, keep release behavior in scripts, and update the three localized README files together when product-facing behavior changes.
