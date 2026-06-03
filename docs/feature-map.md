# Feature Map

This is the working map from Loopback-style product behavior to this repository.

## Implemented In App Model/UI

- Multiple virtual devices.
- Editable virtual device, source, and monitor names.
- Native app appearance preference for Match System, Light, and Dark themes, exposed from the Settings window and toolbar.
- Generated app and HAL driver icon assets, `CFBundleIconFile` metadata, and bundle verifier coverage for `.icns` or complete iconset resources.
- Local macOS `.app` bundle build and verification scripts for packaging previews.
- Installer `.pkg` staging, build, and payload verification scripts for app, HAL driver, helper, and LaunchAgent payloads.
- Script-only uninstaller `.pkg` build and verification scripts for clean app, HAL driver, helper, LaunchAgent removal, and Core Audio reload requests.
- Distribution product `.pkg` build and verification scripts that wrap installer and uninstaller component packages.
- Product signing audit and product package notarization dry-run scripts for release preflight.
- Release manifest script that records app/HAL/helper/package paths, sizes, file counts, SHA-256 digests, bundle plist metadata, signing status, notarization staple status, and release gate outcomes.
- No-system-changes release preflight script that builds app/HAL/helper/package artifacts, runs sandbox-safe diagnostics, verifies package structure, previews helper recovery, validates VSCode task JSON, checks signing state, and writes a consolidated report.
- Installer lifecycle scripts for preinstall cleanup, helper LaunchAgent bootstrap, and Core Audio reload requests.
- Virtual device enable/disable controls, with disabled devices hidden from the HAL active device list.
- Virtual device sample-rate selection for 44.1, 48, 88.2, and 96 kHz.
- Virtual device buffer-frame-size, latency-frame, and safety-offset-frame controls.
- Virtual device buffer-frame-size selection for 128, 256, 512, 1024, 2048, and 4096 frames.
- Virtual device deletion with safe fallback selection and cleanup of nested sources that reference the deleted device.
- Application sources from currently running apps.
- OS-aware special application source presets for Finder, Siri, Sound Effects, VoiceOver, Background Sounds, Notification Center, Spoken Content, and System AirPlay Receiver, including stable `special:` source identifiers and captured-process identifier sets for multi-process system sources.
- Hardware input sources from Core Audio devices.
- Pass-thru sources.
- Virtual-device sources for nesting one virtual device inside another.
- Editable output channel count up to 64 channels.
- Device master mute/gain and source enable/disable, mute, and gain controls.
- Route gain, mute, add, and remove.
- Monitor enable/disable, mute, gain, channel routing, target output selection, playback controls, and removal.
- Monitor entries in the device model.
- Persistent routing graph JSON.
- File-based routing graph preset import/export.
- Local preset library with save, apply, import, delete, envelope metadata, tags, search/filter, tag updates, imported-tag merging, and legacy bare-graph migration.
- Offline route mixing reference.
- Runtime routing engine for rendering every virtual device from injected buffers, live capture sessions, or nested virtual-device sources with cycle protection.
- Runtime sample-rate conversion for source buffers whose capture sample rate differs from the target virtual-device sample rate, with balanced/mastering windowed-sinc quality modes and linear fallback.
- Conservative buffer-watermark drift correction with continuous resampling phase for resampled live/injected external source buffers.
- Source, route, and virtual device output-channel meters in the native UI backed by the latest runtime render report.
- Monitor output engine for receiving rendered virtual-device output, buffering monitor audio, and reporting monitor peaks.
- Monitor output engine applies monitor-level channel maps from virtual-device output channels into monitor output channels.
- Hardware monitor playback sessions for selected Core Audio output-device UIDs and default-output fallback.
- Monitor target output selection backed by Core Audio device UIDs.
- C AudioServerPlugIn HAL driver skeleton.
- `.driver` bundle Info.plist template.
- Local HAL `.driver` bundle build and verification scripts.
- HAL dry-run signing, signing inspection, signature-gated install, and dry-run uninstall scripts.
- HAL notarization dry-run plan script with notarytool/stapler command preview.
- HAL driver probe for local bundle artifact, installed user/system bundles, signature state, and Core Audio-visible virtual devices.
- Optional post-install Core Audio reload dry-run and HAL visibility wait diagnostics.
- Product-level install/uninstall workflow dry-run scripts that orchestrate app bundle verification, HAL verification, optional signing, HAL install/uninstall, helper LaunchAgent install/uninstall, optional Core Audio reload, and post-install visibility waits.
- Product package workflow can stage `/Applications`, `/Library/Audio/Plug-Ins/HAL`, `/Library/Application Support/Heartecho`, and `/Library/LaunchAgents` payloads into a local `.pkg` artifact and verify the package payload plus lifecycle scripts.
- Product uninstaller package workflow can build a no-payload `.pkg` whose scripts unload the helper, remove app/HAL/helper/LaunchAgent artifacts, and request Core Audio reload.
- Product distribution workflow can produce a `productbuild` package with selectable install/uninstall choices, generated Distribution XML, and package resources.
- Post-install validation script audits app bundle, HAL driver structure/signature, helper executable, LaunchAgent plist, launchd load state, and optional HAL virtual-device visibility wait.
- Installed-driver audio validation script runs repeated no-system-changes diagnostics against installed payloads, launchd helper state, Core Audio virtual-device visibility, readiness state, and live HAL audio transport when shared memory is available.
- Diagnostics support a `--skip-shared-memory` mode for CI/sandbox smoke tests that cannot create POSIX shared-memory objects.
- HAL runtime configuration generated from the routing graph.
- Fixed HAL shared configuration ABI generated by Swift and mirrored in the C driver.
- User-edited virtual device names, enabled state, channel count, sample rate, latency, safety offset, and buffer frame size flow into the HAL shared configuration ABI.
- App-side POSIX shared-memory publication of the HAL config snapshot.
- Helper executable scaffold for graph bootstrap and HAL config/audio shared-memory publication.
- Helper signing plan, LaunchAgent plist generation, linting, install dry-run, uninstall dry-run, and app/diagnostic probing of built, user-installed, or system-installed helper plists.
- Helper launchd recovery dry-run planner for stale transport kickstart/restart workflows.
- C HAL shared-configuration file and shared-memory loaders verified by diagnostics.
- C HAL config-change summary and property notification model verified by diagnostics.
- C HAL active-device filtering for disabled virtual devices verified by diagnostics.
- C HAL runtime device properties for latency, safety offset, buffer frame size/range, and virtual transport type verified by diagnostics.
- Prototype multi-device C HAL audio buffer ABI.
- Swift HAL audio buffer bridge for writing and reading interleaved mixed frames.
- Runtime render publisher that maps `RuntimeRenderReport` device mixes to HAL object IDs and writes them into live POSIX shared-memory audio slots.
- HAL audio transport writer/reader heartbeat counters, health reports, stale-writer warnings, and overflow readiness blocking.
- Multi-iteration HAL audio transport stress diagnostics for writer/reader heartbeat movement, read/write counters, overflow detection, and realtime-read counters, with optional POSIX shared-memory stress when not running in sandbox skip mode.
- C HAL realtime safety stats for the `DoIOOperation` audio read path, including IO/read/zero-fill counts and zero render-path lock/allocation/file/shared-memory-open counters.
- Source audio ring buffer primitive.
- Level meter primitive plus native source, route, and output-channel meter strips.
- Core Audio process tap capability detection.
- PID to Core Audio process object diagnostics.
- Special application source configuration, OS-version availability, captured-identifier metadata, persistence, default routing, and HAL config compatibility verified by diagnostics.
- Process tap aggregate capture session lifecycle, with background capture-candidate discovery and multi-process tap configuration used by special system sources.
- Application source mute-when-capturing option backed by Core Audio tap mute behavior.
- Hardware input capture session lifecycle.
- Application and hardware input source cards expose prepare/start/stop/release capture controls.
- Capture state model tracks idle/prepared/running/failed, buffered frames, dropped frames, and peak.
- Audio readiness report and Inspector panel for HAL driver build/install state, virtual-device visibility, system audio/process-tap access, microphone permission, application capture, hardware inputs, monitor outputs, helper service state, and live HAL audio transport.
- Manual microphone-access request from the Inspector readiness panel, while diagnostics only read the current permission state by default.
- App bundle privacy purpose strings for microphone input (`NSMicrophoneUsageDescription`) and application/system audio capture (`NSAudioCaptureUsageDescription`), with bundle verification enforcing both keys.
- Sandbox-safe diagnostics keep routing, HAL config encoding, C HAL file loading, device property, mixer/render/monitor/meter, capture state, preset tag/search behavior, app/device discovery, and packaging probes runnable while explicitly skipping shared-memory transport checks.

## In Progress

- Real source capture buffers. Current status: application process taps and hardware input IOProcs write into `AudioRingBuffer`; readiness/permission status is visible in the app, while sustained capture validation remains.
- Hardware input capture. Current status: `HardwareInputCaptureSession` creates a device IOProc for selected Core Audio input devices and feeds `AudioRingBuffer`; default diagnostics keep it opt-in.
- Application process tap capture. Current status: tap + private aggregate + IOProc session exists and app source cards can control it; readiness UX exists and sustained capture testing is next.
- Monitor output playback. Current status: monitor buffer/level pipeline exists, monitors target Core Audio output-device UIDs, gain/enable state is applied before buffering/playback, AudioQueue playback binds to selected UIDs, and AVAudioEngine remains as default-output fallback.
- Level metering. Current status: source and mixed buffer measurement exists; source cards, route rows, and virtual device output channels render native meter strips from runtime peak reports.
- HAL audio data plane. Current status: diagnostics can publish rendered Swift mixes into per-device live POSIX shared-memory slots, close/reopen the mapping, and read the same frames back through the C HAL API; runtime render defaults to balanced windowed-sinc resampling for mismatched source buffers, can fall back to linear conversion for low-cost diagnostics, applies conservative buffer-watermark drift correction with continuous phase state to live/external sources, and surfaces heartbeat-based stale/overflow transport health; diagnostics include multi-iteration in-memory transport stress and optional POSIX shared-memory stress; diagnostics also have an explicit shared-memory skip mode for sandboxed CI; production still needs signed installed-driver validation and deeper real-time safety hardening.
- C HAL realtime path. Current status: diagnostics can drive the C `DoIOOperation` read path, verify read/zero-fill accounting, and assert that tracked render-path lock/allocation/file/shared-memory-open counters remain zero; production still needs installed-driver long-run validation under real Core Audio callback scheduling.
- Helper service. Current status: `HeartechoHelper` command-line scaffold loads or bootstraps a graph, publishes config/audio shared memory, can keep refreshing it in a finite or continuous run loop, has dry-run signing plus LaunchAgent generation/install/uninstall scripts, and is probed by app/diagnostics across build, user, and system LaunchAgent locations; launchd load validation and privilege separation are next.
- Installed driver visibility. Current status: app/diagnostics can report local build artifact, installed user/system bundles, signature validity, matching Core Audio devices, and can wait for a post-install device to appear; shell post-install validation also audits installed app/helper/LaunchAgent/launchd state; real signed installation and loaded-device validation are next.

## Not Yet Implemented

- Production HAL Audio Server Driver plug-in.
- Signed and validated production audio transport between helper and installed HAL driver.
- Fully signed/notarized installer, uninstaller, and distribution packages with production lifecycle scripts.
- Signed launchd/helper service.
- Signed, loaded, system-visible virtual audio input/output devices.
- Long-run validation and tuning for windowed-sinc sample-rate conversion quality plus clock recovery beyond the current conservative watermark/phase controller.
- Installed-driver realtime callback validation under sustained Core Audio load.
- Executed Developer ID code signing, notarization, stapling, and recovery validation on an installed macOS system.
