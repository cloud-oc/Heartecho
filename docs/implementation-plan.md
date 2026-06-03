# Implementation Plan

## Phase 1: Native App Scaffold

- Swift Package Manager project.
- SwiftUI shell with device list, virtual-device lifecycle controls, source list, channel mapping, and monitor controls.
- Native settings surface with Match System, Light, and Dark app appearance preference.
- Codable routing graph.
- Core Audio device enumeration.
- VSCode build and run tasks.
- Current status: complete enough for ongoing development; local `.app` bundle build and verification scripts exist for macOS packaging previews.

## Phase 2: Audio Graph Prototype

- Implement an in-process mixer for hardware inputs. Current status: offline graph mixer exists in `HeartechoAudio.RoutingMixer`.
- Add pass-thru channels. Current status: pass-thru sources are modeled and included in the starter route graph.
- Add stereo and multi-channel mapping. Current status: editable source-to-output routes support up to 64 output channels.
- Add runtime render coordinator. Current status: `RuntimeRoutingEngine` renders all virtual devices from injected buffers or live capture sessions.
- Add source sample-rate conversion. Current status: source buffers can carry capture sample-rate metadata, `RuntimeRoutingEngine` defaults to balanced windowed-sinc resampling for mismatched buffers, still supports explicit linear conversion for low-cost diagnostics, applies conservative buffer-watermark drift correction with continuous per-device/per-source phase state for live/external sources, and diagnostics verify the converted render/report path.
- Publish runtime render output to the HAL prototype. Current status: `HALRenderPublisher` maps render reports to shared HAL object IDs, writes mixed frames into C audio buffer slots, and can publish the fixed audio state through POSIX shared memory for diagnostics.
- Add file-based presets. Current status: SwiftUI import/export uses JSON routing graph presets, the app has a local preset library for save/apply/import/delete/tag/search/filter, and diagnostics verify preset round-trip, library envelope metadata, tag normalization/search/update behavior, imported-tag merging, legacy bare-graph migration, and HAL config generation.
- Add level metering. Current status: meter primitive exists, capture and monitor rows show peak state, and source cards, route rows, and virtual device output channels render native meter strips from the latest runtime render report.
- Add monitor output playback. Current status: monitor output engine maps rendered device channels into monitor channels, buffers rendered device output, reports peaks, stores target output-device UIDs, and uses AudioQueue playback for selected output devices.

## Phase 3: Application Capture

- Add macOS process tap discovery. Current status: running app discovery exists, background capture-candidate process discovery feeds special-source capture, OS-aware Loopback-style special application source presets are available in Add Source, and process tap binding is next.
- Capture selected app/process audio into source buffers. Current status: `ProcessTapCaptureSession` owns tap, private aggregate device, IOProc, ring buffer, multi-process process tap configuration for special system sources, and a per-application mute-when-capturing option that maps to Core Audio tap mute behavior.
- Add permission prompts and diagnostics. Current status: Inspector readiness panel reports HAL driver state, virtual-device visibility, system audio/process-tap access, microphone permission, application capture candidates, input/output devices, and live HAL audio transport; the app bundle includes microphone and system/application audio-capture purpose strings and bundle verification enforces both; microphone access is requested only from a user action, and diagnostics read permission state without prompting.
- Add sandbox/CI-safe diagnostics. Current status: `HeartechoDiagnostics --skip-shared-memory` keeps non-POSIX-shared-memory smoke checks runnable in restricted environments while explicitly skipping live shared-memory transport checks.
- Represent muted/silent/missing app states in the UI. Current status: process-object mapping, idle/audio-active diagnostics, and capture phase are shown.

## Phase 4: HAL Virtual Device

- Build a real Audio Server Driver plug-in bundle. Current status: compiling C AudioServerPlugIn skeleton, bundle template, local build/verify scripts, dry-run signing, signing inspection, signature-gated install scaffold, and dry-run uninstall scripts exist; notarization and real installation are next.
- Publish one or more virtual devices. Current status: HAL skeleton reads the active shared configuration and exposes enabled devices with dynamic names, UIDs, channel counts, sample rates, latency, safety offsets, buffer frame sizes, and streams; app controls can enable/disable/delete devices and change sample rates, buffer frame sizes, latency frames, and safety offsets, and diagnostics verify disabled-device filtering plus runtime property propagation.
- Bridge app configuration to the driver through a helper service or shared app group store. Current status: app persistence writes a fixed shared-config file and publishes a POSIX shared-memory snapshot; signed helper ownership is next.
- Bridge rendered audio to the driver. Current status: Swift can write runtime mix output into per-device live POSIX shared-memory HAL buffer slots and diagnostics can close/reopen the mapping and read frames back; transport writer/reader heartbeat counters now surface stale writer and overflow health in readiness; diagnostics stress the in-memory HAL transport across multiple render/read iterations and can optionally stress the POSIX shared-memory loop with `--stress-hal-transport`; sandbox-safe diagnostics can skip POSIX shared-memory checks without marking them verified; the installed-driver path still needs signed validation and deeper real-time safety hardening.
- Audit realtime HAL read path. Current status: C HAL diagnostics expose realtime safety stats for `DoIOOperation` audio reads, counting IO/read/zero-fill work and asserting tracked render-path lock/allocation/file/shared-memory-open counters remain zero.
- Add helper executable/service. Current status: `HeartechoHelper` can bootstrap a starter graph, load `RoutingGraph.json`, publish HAL config shared memory, and write live audio shared memory; helper signing dry-run, LaunchAgent generation, install/uninstall dry-run scripts, product-level install/uninstall dry-runs, VSCode tasks, and app/diagnostic service probing across build, user, and system LaunchAgent locations exist; signed launchd load validation is next.
- Implement real-time safe render and device property handling.
- Add installer/uninstaller flow. Current status: product-level dry-run shell workflow orchestrates app bundle verification, HAL verification/signing plan, HAL install/uninstall, helper LaunchAgent install/uninstall, optional Core Audio reload, and post-install visibility wait; local installer `.pkg` staging/build/verification can package app, HAL driver, helper, and LaunchAgent payloads with preinstall/postinstall cleanup/bootstrap scripts; local no-payload uninstaller `.pkg` build/verification removes app/HAL/helper/LaunchAgent artifacts and requests Core Audio reload; distribution product `.pkg` build/verification wraps install and uninstall component packages; product signing audit, product-package notarization dry-run scripts, a no-system-changes release preflight report, and a JSON release manifest with hashes/signing/notarization gates exist; post-install validation audits installed app/HAL/helper/LaunchAgent/launchd state and optional HAL visibility, and installed-driver audio validation can repeat readiness/Core Audio visibility/live transport diagnostics without modifying the system; real Developer ID signing/notarization plus post-install validation on an installed system are next.
- See `docs/hal-driver.md`.

## Phase 5: Production Hardening

- Code signing and notarization.
- Recovery for stale driver state. Current status: heartbeat-based stale/overflow detection is implemented for the app/readiness panel, and `scripts/recover-helper-service.sh` previews launchd kickstart/restart recovery commands; automated installed-helper restart/recovery still requires signed launchd validation.
- Long-run validation and tuning for windowed-sinc sample-rate conversion quality.
- Production clock recovery between hardware clocks beyond the current conservative buffer-watermark/phase correction.
- Latency controls.
- Sustained installed-driver realtime callback validation.
- Preset library production polish beyond current tag/search/filter support, including richer naming workflows and exportable preset collections.
- Automated tests for routing graph validation.
