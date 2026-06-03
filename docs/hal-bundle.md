# HAL Bundle

`Sources/HALDriverC` contains a compiling C `AudioServerPlugInDriverInterface` skeleton. `HALBundle/Heartecho.driver` is the bundle template that macOS Core Audio expects.

## Build Shape

The final installable bundle should look like:

```text
Heartecho.driver/
  Contents/
    Info.plist
    MacOS/
      HeartechoHALDriver
```

The current SwiftPM target verifies that the C driver source compiles against the local SDK. `scripts/build-hal-bundle.sh debug` now builds a local bundle artifact at `build/HAL/Heartecho.driver` and places the compiled binary at `Contents/MacOS/HeartechoHALDriver`.

Verify the local bundle without installing it:

```sh
scripts/verify-hal-bundle.sh
```

The verifier checks the bundle directory, `Info.plist`, executable name, bundle identifier, icon metadata/resources, factory symbol mapping, exported `_HeartechoHALDriverFactory`, and Mach-O dynamic-library type.

Build product icon assets explicitly:

```sh
scripts/build-icons.sh
```

The app and HAL bundle builders call this automatically when icon assets are missing. The script generates complete `.iconset` resources and attempts to produce `.icns` files with `iconutil`; in restricted local environments where provenance metadata prevents `iconutil` from accepting generated iconsets, verifiers still require the complete iconset PNG resource set.

`HeartechoHelper` is a separate Swift executable scaffold. It is not part of the `.driver` bundle; the production shape should install it as a signed helper/launchd component that owns graph validation and shared-memory publication.

Generate and lint a non-installed LaunchAgent plist for the current helper executable:

```sh
scripts/build-helper-launch-agent.sh
```

The generated plist lives under `build/launchd` by default and points at `HeartechoHelper --publish-audio --serve`. It is a dry-run artifact only; do not copy it into `~/Library/LaunchAgents` or load it with `launchctl` until the helper has a real signed install location and lifecycle policy.

Preview helper launchd recovery without modifying the system:

```sh
scripts/recover-helper-service.sh --kickstart
```

Use `--restart` to preview a bootout/bootstrap cycle, and add `--execute` only after the helper, LaunchAgent, and install scope have passed signing and validation checks.

Preview helper signing:

```sh
scripts/sign-helper.sh --identity "Developer ID Application: Your Team"
```

Add `--execute` only after the helper binary has been built in the intended install shape and a real signing identity is available.

## Install Locations

During development, use the user HAL plug-in directory when possible:

```sh
~/Library/Audio/Plug-Ins/HAL
```

For all-user production installation:

```sh
/Library/Audio/Plug-Ins/HAL
```

Production installation requires code signing, notarization, and an installer/uninstaller flow.

The build/verify scripts intentionally do not copy anything into these install locations.

## Install Scaffold

Preview installation into the user HAL directory:

```sh
scripts/install-hal-bundle.sh
```

Preview removal from the user HAL directory:

```sh
scripts/uninstall-hal-bundle.sh
```

Both scripts are dry-run by default. Add `--execute` to actually copy or remove `Heartecho.driver` under `~/Library/Audio/Plug-Ins/HAL`. Use `--system` to target `/Library/Audio/Plug-Ins/HAL`, which generally requires elevated permissions and should only be used after signing/notarization work is complete.

Inspect the current signing state:

```sh
scripts/check-hal-signing.sh
```

Preview signing:

```sh
scripts/sign-hal-bundle.sh --identity "Developer ID Application: Your Team"
```

Preview notarization after signing:

```sh
scripts/notarize-hal-bundle.sh --keychain-profile "notary-profile"
```

Add `--execute` to actually invoke `codesign` or submit with `xcrun notarytool`. `scripts/notarize-hal-bundle.sh` creates a dry-run plan by default, reports whether the bundle signature is currently valid, and only requires valid signing/credentials when `--execute` is provided. Production installation requires a Developer ID signature, notarization, and a user-facing installer/uninstaller flow. The local debug bundle is expected to be unsigned or ad-hoc signed until a real identity is supplied.

When `scripts/install-hal-bundle.sh --execute` is used, the installer requires `scripts/check-hal-signing.sh --require-valid` to pass before copying. Add `--allow-unsigned` only for temporary development installs into an isolated destination.

After an install, preview a Core Audio reload:

```sh
scripts/reload-core-audio.sh
```

Add `--execute` to run `killall coreaudiod`. Then wait for the virtual device to appear:

```sh
swift run HeartechoDiagnostics --wait-hal-device 30
```

To audit the installed app, HAL driver, helper executable, LaunchAgent, launchd state, and optional HAL visibility wait without modifying the system:

```sh
scripts/validate-installation.sh --wait 30
```

Use `--strict` in CI or after a real install when any missing component should fail the command.

The app and diagnostics also run a non-invasive HAL driver probe. It reports:

- whether the local build artifact exists and has valid bundle metadata,
- whether user or system HAL install locations contain `Heartecho.driver`,
- whether those installed bundles pass code-signature verification,
- whether Core Audio currently exposes devices with the expected `com.heartecho.Heartecho.Driver.` UID prefix.

The helper service probe reports the generated build plist plus both user and system LaunchAgent install locations. This matches the product package payload, which stages the production LaunchAgent under `/Library/LaunchAgents`.

For an end-to-end dry-run of the development install workflow:

```sh
scripts/install-heartecho.sh --wait 30
```

This orchestrates app bundle verification, HAL bundle verification, optional signing when `--identity` is supplied, HAL install planning, helper LaunchAgent generation/install planning, optional Core Audio reload, and optional post-install visibility waiting. It remains dry-run unless `--execute` is supplied. Use the paired uninstaller workflow to preview cleanup:

```sh
scripts/uninstall-heartecho.sh --unload-helper --reload-core-audio
```

To build a local unsigned installer package artifact without running the installer:

```sh
scripts/build-installer-pkg.sh --execute
scripts/verify-installer-pkg.sh
scripts/build-uninstaller-pkg.sh --execute
scripts/verify-uninstaller-pkg.sh
```

The package payload currently stages:

- `/Applications/Heartecho.app`
- `/Library/Audio/Plug-Ins/HAL/Heartecho.driver`
- `/Library/Application Support/Heartecho/HeartechoHelper`
- `/Library/LaunchAgents/com.heartecho.Heartecho.Helper.plist`

Use `--identity` to preview app/HAL/helper signing commands and `--sign-pkg-identity` when a Developer ID Installer identity is available. The current package workflow is a local build artifact; production still needs signed/notarized distribution, installer scripts for service load/reload policy, and real post-install validation.

The generated package includes lifecycle scripts:

- `preinstall` unloads any existing helper LaunchAgent and removes old app, HAL driver, helper, and LaunchAgent payloads.
- `postinstall` fixes helper/LaunchAgent modes, attempts to bootstrap the helper LaunchAgent for the active GUI user, and requests a `coreaudiod` restart.
- `postuninstall` is emitted as a cleanup script for the paired package workflow and mirrors helper unload plus app/HAL/helper removal.

`scripts/verify-installer-pkg.sh` expands the package, checks these script bodies parse with `sh -n`, and verifies the primary payload paths. On local APFS volumes, macOS provenance metadata can appear as AppleDouble entries in `pkgutil --payload-files`; the verifier reports that as a warning while still requiring the primary payload and lifecycle scripts.

The uninstaller package is script-only (`pkgbuild --nopayload`). Its `preinstall` and `postinstall` scripts unload the helper LaunchAgent, remove app/HAL/helper/LaunchAgent artifacts, and request a `coreaudiod` restart. `scripts/verify-uninstaller-pkg.sh` verifies the package has no payload and that its scripts parse successfully.

To wrap the installer and uninstaller component packages in a distribution product package:

```sh
scripts/build-distribution-product.sh --execute
scripts/verify-distribution-product.sh
```

The product package workflow generates `build/pkg/Distribution.xml`, a small resources folder, and `build/pkg/Heartecho-Distribution-0.1.0.pkg`. The generated Distribution XML exposes separate install and uninstall choices while reusing the component packages above. Use `--sign-pkg-identity "Developer ID Installer: Your Team"` to sign the distribution package when a real installer identity is available.

Inspect the complete release signing state:

```sh
scripts/check-product-signing.sh
```

Add `--require-valid` in a release gate after the app, HAL driver, helper, installer, uninstaller, and distribution package have all been signed with real Developer ID identities.

Run the local release preflight before handing artifacts to signing/notarization:

```sh
scripts/release-preflight.sh
```

This rebuilds and verifies the app bundle, HAL bundle, helper LaunchAgent plist, installer package, uninstaller package, and distribution product package; runs sandbox-safe diagnostics; previews helper recovery; validates `.vscode/tasks.json`; checks product signing state; and writes `build/release-preflight-report.txt`. It does not install the HAL driver, load launchd, restart Core Audio, or submit to Apple notarization. Use `scripts/release-preflight.sh --require-signed` only after real Developer ID Application signatures are expected for the app/HAL/helper and Developer ID Installer signatures are expected for the packages; ad-hoc signatures do not satisfy the release gate.

Preview product package notarization:

```sh
scripts/notarize-product-pkg.sh --keychain-profile "notary-profile"
```

Add `--execute --staple` only for a signed distribution package with Apple notary credentials. This submits the product package with `xcrun notarytool` and staples the ticket after acceptance when requested.

## Current Driver Behavior

- Publishes enabled virtual device objects from the active shared configuration snapshot.
- Publishes one input stream and one output stream per configured virtual device.
- Reports the configured sample rate and channel count for each enabled device.
- Reports name, manufacturer, UID, stream configuration, alive/running state.
- Accepts start/stop IO.
- Reads from prototype C audio buffer slots in IO operations and zero-fills missing frames while maintaining sample time.
- Can load prototype audio buffer state from POSIX shared memory for diagnostics.
- Exposes realtime safety stats for diagnostics of the `DoIOOperation` read path.
- Receives runtime mixes after Swift-side source buffers have been converted to the configured virtual-device sample rate, with conservative buffer-watermark drift correction and continuous resampling phase for live/external sources.

The next driver step is to run real Developer ID signing/notarization, validate the helper launchd load path after a real install, prove Core Audio-visible virtual devices, and then harden the live buffer path with production SRC quality, tighter clock recovery, long-run drift validation, installed-driver realtime callback validation, and real-time safety review.
