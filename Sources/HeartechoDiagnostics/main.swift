import Foundation
import HALDriverC
import HALDriverStub
import HeartechoAudio
import HeartechoCore

let skipsSharedMemory = CommandLine.arguments.contains("--skip-shared-memory")
let sharedMemorySkippedStatus = "skipped (--skip-shared-memory)"
let stressHALTransport = CommandLine.arguments.contains("--stress-hal-transport")

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print("""
    Usage: HeartechoDiagnostics [options]

    Options:
      --skip-shared-memory       Skip POSIX shared-memory diagnostics for sandboxed/CI environments.
      --wait-hal-device SECONDS  Wait for an installed HAL virtual device to become visible.
      --prepare-process-tap      Attempt process-tap aggregate creation.
      --prepare-hardware-input   Attempt hardware input IOProc creation.
      --start-monitor-playback   Attempt monitor output playback start/stop.
      --stress-hal-transport     Run a longer HAL audio transport read/write stress diagnostic.
    """)
    exit(0)
}

let graph = RoutingGraph()
let halConfiguration = try HALDriverBridge.runtimeConfiguration(from: graph)
let halSharedConfigData = try HALDriverBridge.sharedConfigurationData(from: halConfiguration)
let halSharedConfig = try HALDriverBridge.decodeSharedConfigurationData(halSharedConfigData)
let halBundleTemplateCheck = verifyHALBundleTemplate()
let cHALLoadCheck = try verifyCHALSharedConfigLoader(data: halSharedConfigData, expected: halSharedConfig)
let cHALSharedMemoryCheck: Bool
if skipsSharedMemory {
    cHALSharedMemoryCheck = true
} else {
    cHALSharedMemoryCheck = try verifyCHALSharedMemoryLoader(configuration: halConfiguration, expected: halSharedConfig)
}
let cHALConfigChangeCheck = try verifyCHALConfigChangeSummary(configuration: halConfiguration)
let cHALDevicePropertyCheck = verifyCHALDeviceRuntimeProperties(deviceObjectID: HALSharedConfigLayout.objectIDBase)
let helperPublicationCheck: Bool
if skipsSharedMemory {
    helperPublicationCheck = true
} else {
    helperPublicationCheck = try verifyHeartechoHelperRuntimePublication(graph: graph)
}

guard let device = graph.selectedDevice else {
    fatalError("Expected a starter virtual device.")
}

let issues = RoutingGraphValidator.validate(device: device)
let errors = issues.filter { $0.severity == .error }

if !errors.isEmpty {
    print("Routing validation failed:")
    for issue in errors {
        print("- \(issue.message)")
    }
    exit(1)
}

let discovery = CoreAudioDeviceDiscovery()
let systemDevices = discovery.allDevices()
let driverProbeReport = HALDriverProbe().probe(systemDevices: systemDevices)
let helperServiceReport = HelperServiceProbe().probe()
let outputDevices = systemDevices.filter { $0.direction == .output || $0.direction == .duplex }
let runningApplications = await MainActor.run {
    ApplicationAudioSourceDiscovery().runningApplications()
}
var monitorTargetGraph = graph
let selectedOutputIdentifier = outputDevices.first.flatMap { $0.uid ?? $0.id }

if let selectedOutputIdentifier,
   let deviceIndex = monitorTargetGraph.devices.firstIndex(where: { $0.id == device.id }),
   let monitorIndex = monitorTargetGraph.devices[deviceIndex].monitors.firstIndex(where: { _ in true }) {
    monitorTargetGraph.devices[deviceIndex].monitors[monitorIndex].deviceIdentifier = selectedOutputIdentifier
}

let sourceBuffers = Dictionary(uniqueKeysWithValues: device.sources.map { source in
    (
        source.id,
        SourceAudioBuffer(
            sourceID: source.id,
            channels: [
                [0.10, 0.20, 0.30, 0.40],
                [0.40, 0.30, 0.20, 0.10]
            ]
        )
    )
})
let mixResult = RoutingMixer.mix(device: device, sourceBuffers: sourceBuffers, frameCount: 4)
let levels = LevelMeter.measure(mixResult.buffer)
let halAudioBufferCheck = verifyHALAudioBufferBridge(mixResult: mixResult)
let halRealtimeSafetyCheck = verifyHALRealtimeSafetyStats()
let runtimeReport = RuntimeRoutingEngine().render(
    graph: graph,
    captureSessions: [:],
    injectedBuffers: sourceBuffers,
    frameCount: 4
)
let halRenderPublicationCheck = verifyHALRenderPublisher(
    runtimeReport: runtimeReport,
    configuration: halConfiguration,
    mixResult: mixResult
)
let multiDeviceHALRenderPublicationCheck = verifyMultiDeviceHALRenderPublisher()
let halAudioTransportStressCheck = verifyHALAudioTransportStress()
let halAudioSharedMemoryCheck = skipsSharedMemory ? true : verifyHALAudioSharedMemoryPublication()
let halAudioLiveSharedMemoryCheck = skipsSharedMemory ? true : verifyHALAudioLiveSharedMemoryPublication()
let halAudioSharedMemoryStressStatus: String
if stressHALTransport {
    if skipsSharedMemory {
        halAudioSharedMemoryStressStatus = sharedMemorySkippedStatus
    } else {
        halAudioSharedMemoryStressStatus = verifyHALAudioSharedMemoryStress() ? "OK" : "failed"
    }
} else {
    halAudioSharedMemoryStressStatus = "skipped"
}
let passThruRoutingCheck = verifyPassThruRoutingExpansion()
let nestedVirtualDeviceRoutingCheck = verifyNestedVirtualDeviceRouting()
let sampleRateConversionCheck = verifyRuntimeSampleRateConversion()
let deviceMasterGainCheck = verifyDeviceMasterGain(device: device, sourceBuffers: sourceBuffers)
let sourceMuteCheck = verifySourceMuteBehavior(device: device, sourceBuffers: sourceBuffers)
let processTapMuteBehaviorCheck = verifyProcessTapMuteBehaviorPersistence()
let virtualDeviceLifecycleCheck = verifyVirtualDeviceLifecycleBehavior()
let specialApplicationSourceCheck = verifySpecialApplicationSourceBehavior()
let renamedGraphPersistenceCheck = verifyRenamedGraphPersistenceAndHALConfig()
let presetRoundTripCheck = verifyPresetRoundTripAndHALConfig()
let presetLibraryCheck = verifyPresetLibraryBehavior()
let runtimeRender = runtimeReport.renders.first
let monitorStates = MonitorOutputEngine().process(graph: graph, renderReport: runtimeReport)
let firstMonitorState = device.monitors.first.flatMap { monitorStates[$0.id] }
let monitorControlCheck = verifyMonitorGainMuteRoutingAndEnableBehavior(graph: graph, renderReport: runtimeReport)

let smokeChecks: [(String, Bool)] = [
    ("active route count", mixResult.report.activeRouteCount == 2),
    ("left mix samples", mixResult.buffer.channel(index: 1) == [0.10, 0.20, 0.30, 0.40]),
    ("right mix samples", mixResult.buffer.channel(index: 2) == [0.40, 0.30, 0.20, 0.10]),
    ("level peak", levels.first?.peak == 0.40),
    ("runtime left mix", runtimeRender?.result.buffer.channel(index: 1) == mixResult.buffer.channel(index: 1)),
    ("runtime active route count", runtimeReport.totalActiveRouteCount == 2),
    ("source level peak", mixResult.report.peakBySourceID[device.sources[0].id] == 0.40),
    ("route level peaks", device.routes.allSatisfy { mixResult.report.peakByRouteID[$0.id] == 0.40 }),
    ("monitor receiving", firstMonitorState?.phase == .receiving),
    ("monitor peak", firstMonitorState?.peak == 0.40),
    ("monitor gain, mute, routing, and enable behavior", monitorControlCheck),
    ("HAL config channel count", halConfiguration.devices.first?.channelCount == device.outputChannels.count),
    ("HAL shared config byte count", halSharedConfigData.count == HALSharedConfigLayout.totalByteCount),
    ("HAL shared config device count", halSharedConfig.deviceCount == 1),
    ("HAL shared config device object", halSharedConfig.devices.first?.deviceObjectID == HALSharedConfigLayout.objectIDBase),
    ("HAL shared config input stream", halSharedConfig.devices.first?.inputStreamObjectID == HALSharedConfigLayout.objectIDBase + 1),
    ("HAL shared config output stream", halSharedConfig.devices.first?.outputStreamObjectID == HALSharedConfigLayout.objectIDBase + 2),
    ("HAL shared config channel count", halSharedConfig.devices.first?.channelCount == UInt32(device.outputChannels.count)),
    ("HAL shared config sample rate", halSharedConfig.devices.first?.sampleRate == device.sampleRate),
    ("HAL shared config latency", halSharedConfig.devices.first?.latencyFrames == UInt16(device.latencyFrames)),
    ("HAL shared config safety offset", halSharedConfig.devices.first?.safetyOffsetFrames == UInt16(device.safetyOffsetFrames)),
    ("HAL shared config buffer frame size", halSharedConfig.devices.first?.bufferFrameSize == UInt16(device.bufferFrameSize)),
    ("HAL shared config name", halSharedConfig.devices.first?.name == device.name),
    ("HAL shared config UID", halSharedConfig.devices.first?.uid == halConfiguration.devices.first?.uid),
    ("HAL bundle template", halBundleTemplateCheck),
    ("HAL build artifact structure", driverProbeReport.buildArtifact.map({ !$0.exists || $0.isStructurallyValid }) == true),
    ("C HAL file config loader", cHALLoadCheck),
    ("C HAL shared-memory config loader", cHALSharedMemoryCheck),
    ("C HAL config change summary", cHALConfigChangeCheck),
    ("C HAL runtime device properties", cHALDevicePropertyCheck),
    ("helper publication runtime", helperPublicationCheck),
    ("HAL audio buffer bridge", halAudioBufferCheck),
    ("HAL realtime safety stats", halRealtimeSafetyCheck),
    ("HAL render publisher", halRenderPublicationCheck),
    ("multi-device HAL render publisher", multiDeviceHALRenderPublicationCheck),
    ("HAL audio transport stress", halAudioTransportStressCheck),
    ("HAL audio shared-memory publication", halAudioSharedMemoryCheck),
    ("HAL audio live shared-memory transport", halAudioLiveSharedMemoryCheck),
    ("HAL audio shared-memory stress", !stressHALTransport || skipsSharedMemory || halAudioSharedMemoryStressStatus == "OK"),
    ("Pass-Thru routing expansion", passThruRoutingCheck),
    ("nested virtual-device routing", nestedVirtualDeviceRoutingCheck),
    ("runtime sample-rate conversion", sampleRateConversionCheck),
    ("device master gain", deviceMasterGainCheck),
    ("source mute behavior", sourceMuteCheck),
    ("process tap mute behavior", processTapMuteBehaviorCheck),
    ("virtual-device lifecycle behavior", virtualDeviceLifecycleCheck),
    ("special application source behavior", specialApplicationSourceCheck),
    ("renamed graph persistence and HAL config", renamedGraphPersistenceCheck),
    ("preset round-trip and HAL config", presetRoundTripCheck),
    ("preset library behavior", presetLibraryCheck)
]

let failedSmokeChecks = smokeChecks.filter { !$0.1 }
guard failedSmokeChecks.isEmpty else {
    print("Routing smoke test failed:")
    for check in failedSmokeChecks {
        print("- \(check.0)")
    }
    exit(1)
}

let ringBuffer = AudioRingBuffer(channelCount: 2, capacity: 3)
ringBuffer.write(SourceAudioBuffer(
    sourceID: device.sources[0].id,
    channels: [
        [1, 2, 3, 4],
        [5, 6, 7, 8]
    ],
    sampleRate: 44_100
))
let ringSnapshot = ringBuffer.snapshot()
let ringRead = ringBuffer.read(frameCount: 3, sourceID: device.sources[0].id)

guard ringSnapshot.availableFrameCount == 3,
      ringSnapshot.droppedFrameCount == 1,
      ringSnapshot.sampleRate == 44_100,
      ringRead.sampleRate == 44_100,
      ringRead.channel(index: 1) == [2, 3, 4],
      ringRead.channel(index: 2) == [6, 7, 8] else {
    print("Audio ring buffer smoke test failed.")
    exit(1)
}

let captureStateSmokePassed = await MainActor.run {
    let engineController = AudioEngineController()
    let idleState = engineController.captureState(for: device.sources[0].id)
    engineController.prepareApplicationCapture(source: device.sources[0])
    let rejectedState = engineController.captureState(for: device.sources[0].id)
    let hardwareInputSource = AudioSource(
        name: "Diagnostics Hardware Input",
        kind: .hardwareInput,
        sourceIdentifier: "com.heartecho.Heartecho.Diagnostics.MissingInput"
    )
    engineController.prepareHardwareInputCapture(source: hardwareInputSource)
    let rejectedHardwareInputState = engineController.captureState(for: hardwareInputSource.id)
    let idlePlaybackState = engineController.monitorPlaybackState(for: device.monitors[0].id)

    return idleState.phase == .idle &&
        rejectedState.phase == .failed &&
        rejectedHardwareInputState.phase == .failed &&
        idlePlaybackState.phase == .idle &&
        (selectedOutputIdentifier == nil || monitorTargetGraph.devices.first?.monitors.first?.deviceIdentifier == selectedOutputIdentifier)
}

guard captureStateSmokePassed else {
    print("Capture state smoke test failed.")
    exit(1)
}

let tapManager = CoreAudioProcessTapManager()
let tapCapability = tapManager.capability
let processTapDiagnostics = runningApplications.map { application in
    let processObjectID = tapManager.processObjectID(for: application.processIdentifier)
    return ProcessTapProcessDiagnostic(
        applicationID: application.id,
        processIdentifier: application.processIdentifier,
        name: application.name,
        processObjectID: processObjectID,
        isRunningOutput: processObjectID.map {
            tapManager.isProcessRunningOutput(processObjectID: $0)
        } ?? false
    )
}
let processObjectMatches = runningApplications.compactMap { application in
    tapManager.processObjectID(for: application.processIdentifier)
}.count
let microphonePermissionStatus = MicrophonePermissionProbe.currentStatus()
let readinessPublicationReport: HALRenderPublicationReport?
if skipsSharedMemory {
    readinessPublicationReport = nil
} else {
    let readinessSharedMemoryName = "/LBSR-\(UUID().uuidString.prefix(8))"
    HALAudioBufferBridge.closeSharedMemory()
    HALAudioBufferBridge.reset()
    readinessPublicationReport = HALRenderPublisher.publishToSharedMemory(
        renderReport: runtimeReport,
        configuration: halConfiguration,
        sharedMemoryName: readinessSharedMemoryName
    )
    HALAudioBufferBridge.closeSharedMemory()
    HALAudioBufferBridge.reset()
    _ = HALAudioBufferBridge.unlinkSharedMemory(name: readinessSharedMemoryName)
}
let readinessReport = AudioReadinessReporter.makeReport(
    driverProbeReport: driverProbeReport,
    systemDevices: systemDevices,
    runningApplications: runningApplications,
    processTapCapability: tapCapability,
    processTapDiagnostics: processTapDiagnostics,
    microphonePermissionStatus: microphonePermissionStatus,
    helperServiceReport: helperServiceReport,
    halPublicationReport: readinessPublicationReport,
    halRealtimeSafetyReport: HALRealtimeSafetyProbe.currentReport()
)
let microphoneReadinessReport = AudioReadinessReporter.makeReport(
    driverProbeReport: driverProbeReport,
    systemDevices: systemDevices,
    runningApplications: runningApplications,
    processTapCapability: tapCapability,
    processTapDiagnostics: [],
    microphonePermissionStatus: microphonePermissionStatus,
    helperServiceReport: helperServiceReport,
    halPublicationReport: nil
)

guard readinessReport.items.count == 10,
      readinessReport.item(kind: .halDriverInstallation)?.isRequired == true,
      readinessReport.item(kind: .helperService)?.isRequired == true,
      readinessReport.item(kind: .virtualDeviceVisibility)?.isRequired == true,
      readinessReport.item(kind: .microphonePermission)?.state == microphoneReadinessReport.item(kind: .microphonePermission)?.state,
      readinessReport.item(kind: .halAudioTransport)?.state == (skipsSharedMemory ? .unknown : .ready) else {
    print("Audio readiness report smoke test failed.")
    print("- item count: \(readinessReport.items.count)")
    for item in readinessReport.items {
        print("- \(item.kind.rawValue): \(item.state.rawValue) / required=\(item.isRequired) / \(item.summary)")
        print("  \(item.detail)")
    }
    exit(1)
}
let outputDeviceUIDCount = outputDevices.filter { $0.uid != nil }.count
var capturePrepareStatus = "skipped"
var hardwareInputPrepareStatus = "skipped"
var playbackProbeStatus = "skipped"
let halVisibilityWaitResult = waitForHALDeviceIfRequested()

if CommandLine.arguments.contains("--prepare-process-tap") {
    capturePrepareStatus = "not attempted"

    if tapCapability.isSupported,
       let candidate = runningApplications.first(where: {
           tapManager.processObjectID(for: $0.processIdentifier) != nil
       }) {
        let session = ProcessTapCaptureSession(configuration: ProcessTapCaptureConfiguration(
            sourceID: UUID(),
            processIdentifier: candidate.processIdentifier,
            name: "Diagnostics \(candidate.name)",
            ringBufferCapacity: 512
        ))

        do {
            let state = try session.prepare()
            capturePrepareStatus = "prepared aggregate \(state.aggregateDeviceID), tap \(state.tapID)"
            try session.tearDown()
        } catch {
            capturePrepareStatus = "prepare failed: \(error)"
        }
    }
}

if CommandLine.arguments.contains("--prepare-hardware-input") {
    hardwareInputPrepareStatus = "not attempted"

    if let candidate = systemDevices.first(where: { $0.direction == .input || $0.direction == .duplex }) {
        let session = HardwareInputCaptureSession(configuration: HardwareInputCaptureConfiguration(
            sourceID: UUID(),
            deviceID: candidate.audioObjectID,
            name: "Diagnostics \(candidate.name)",
            channelCount: max(1, candidate.channelCount),
            ringBufferCapacity: 512
        ))

        do {
            let state = try session.prepare()
            hardwareInputPrepareStatus = "prepared device \(state.deviceID)"
            try session.tearDown()
        } catch {
            hardwareInputPrepareStatus = "prepare failed: \(error)"
        }
    }
}

if CommandLine.arguments.contains("--start-monitor-playback") {
    playbackProbeStatus = "not attempted"

    if var monitor = device.monitors.first,
       let monitorState = monitorStates[monitor.id],
       monitorState.phase == .receiving {
        monitor.deviceIdentifier = selectedOutputIdentifier
        let monitorEngine = MonitorOutputEngine()
        let states = monitorEngine.process(graph: graph, renderReport: runtimeReport)

        if let state = states[monitor.id],
           state.phase == .receiving,
           let session = monitorEngine.session(for: monitor.id) {
            let playback = HardwareMonitorPlaybackSession(monitor: monitor, monitorSession: session)
            do {
                try playback.start()
                playback.stop()
                playbackProbeStatus = "started and stopped"
            } catch {
                playbackProbeStatus = "start failed: \(error)"
            }
        }
    }
}

print("Heartecho diagnostics")
print("- Starter graph: OK")
print("- HAL runtime config: OK")
print("- HAL shared config ABI: OK (\(halSharedConfigData.count) bytes)")
print("- HAL bundle template: OK")
print("- HAL build artifact probe: \(driverProbeReport.buildArtifact?.isStructurallyValid == true ? "OK" : "missing")")
print("- HAL installed bundles: \(driverProbeReport.installedBundles.count)")
print("- HAL visible devices: \(driverProbeReport.deviceProbe.matchingDevices.count)")
print("- Helper LaunchAgent: \(helperServiceReport.summary)")
print("- HAL visibility wait: \(halVisibilityWaitResult)")
print("- C HAL shared config loader: OK")
print("- C HAL shared memory config loader: \(skipsSharedMemory ? sharedMemorySkippedStatus : "OK")")
print("- C HAL config change summary: OK")
print("- C HAL runtime device properties: OK")
print("- Helper publication runtime: \(skipsSharedMemory ? sharedMemorySkippedStatus : "OK")")
print("- HAL audio buffer bridge: OK")
print("- HAL realtime safety audit: OK")
print("- HAL render publisher: OK")
print("- Multi-device HAL render publisher: OK")
print("- HAL audio transport stress: OK")
print("- HAL audio shared memory publication: \(skipsSharedMemory ? sharedMemorySkippedStatus : "OK")")
print("- HAL audio live shared memory transport: \(skipsSharedMemory ? sharedMemorySkippedStatus : "OK")")
print("- HAL audio shared memory stress: \(halAudioSharedMemoryStressStatus)")
print("- Routing mixer: OK")
print("- Pass-Thru channel expansion: OK")
print("- Nested virtual-device routing: OK")
print("- Runtime sample-rate conversion: OK")
print("- Device master gain: OK")
print("- Source mute controls: OK")
print("- Process tap mute-when-capturing setting: OK")
print("- Virtual device lifecycle controls: OK")
print("- Renamed graph persistence and HAL config: OK")
print("- Preset import/export round-trip: OK")
print("- Audio readiness report: \(readinessReport.overallState.rawValue) / \(readinessReport.summary)")
print("- Runtime routing engine: OK")
print("- Monitor output engine: OK")
print("- Monitor gain, mute, routing, and enable controls: OK")
print("- Audio ring buffer: OK")
print("- Level meter: OK")
print("- Capture state model: OK")
print("- Hardware input capture state model: OK")
print("- Monitor playback state model: OK")
print("- Monitor output device selection model: OK")
print("- Process taps: \(tapCapability.isSupported ? "available" : "unavailable")")
print("- Process tap capture session: \(capturePrepareStatus)")
print("- Hardware input capture session: \(hardwareInputPrepareStatus)")
print("- Monitor hardware playback probe: \(playbackProbeStatus)")
print("- Microphone permission: \(microphonePermissionStatus.rawValue)")
print("- System audio devices: \(systemDevices.count)")
print("- Output devices with Core Audio UID: \(outputDeviceUIDCount)")
print("- Running application sources: \(runningApplications.count)")
print("- Core Audio process object matches: \(processObjectMatches)")

for device in systemDevices.prefix(8) {
    print("  - \(device.name) [\(device.direction.rawValue), \(device.channelCount) ch]")
}

for application in runningApplications.prefix(8) {
    print("  - \(application.name) [pid \(application.processIdentifier)]")
}

private func verifyCHALSharedConfigLoader(data: Data, expected: HALSharedConfigSnapshot) throws -> Bool {
    let fileURL = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("HeartechoHALSharedConfig-\(UUID().uuidString).bin")
    try data.write(to: fileURL, options: [.atomic])
    defer {
        try? FileManager.default.removeItem(at: fileURL)
        HeartechoHALDriverResetSharedConfig()
    }

    let loaded = fileURL.path.withCString { path in
        HeartechoHALDriverLoadSharedConfigFromFile(path)
    }
    guard loaded, let firstDevice = expected.devices.first else {
        return false
    }

    return activeCHALConfigMatches(firstDevice: firstDevice, expectedActiveDeviceCount: UInt32(expected.devices.filter(\.isEnabled).count))
}

private func waitForHALDeviceIfRequested() -> String {
    guard CommandLine.arguments.contains("--wait-hal-device") else {
        return "skipped"
    }

    let timeoutSeconds = commandLineIntegerValue(after: "--wait-hal-device", defaultValue: 30)
    let deadline = Date().addingTimeInterval(TimeInterval(max(0, timeoutSeconds)))
    let discovery = CoreAudioDeviceDiscovery()
    let probe = HALDriverProbe()

    repeat {
        let report = probe.probe(systemDevices: discovery.allDevices())
        if report.deviceProbe.isVisible {
            return "visible \(report.deviceProbe.matchingDevices.count)"
        }
        Thread.sleep(forTimeInterval: 1)
    } while Date() < deadline

    let finalReport = probe.probe(systemDevices: discovery.allDevices())
    return "timed out after \(timeoutSeconds)s; installed \(finalReport.installedBundles.count), visible \(finalReport.deviceProbe.matchingDevices.count)"
}

private func commandLineIntegerValue(after option: String, defaultValue: Int) -> Int {
    guard let index = CommandLine.arguments.firstIndex(of: option) else {
        return defaultValue
    }

    let valueIndex = CommandLine.arguments.index(after: index)
    guard CommandLine.arguments.indices.contains(valueIndex),
          let value = Int(CommandLine.arguments[valueIndex]) else {
        return defaultValue
    }

    return value
}

private func verifyHALBundleTemplate() -> Bool {
    let plistURL = URL(fileURLWithPath: "HALBundle/Heartecho.driver/Contents/Info.plist")
    guard let data = try? Data(contentsOf: plistURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          plist["CFBundleExecutable"] as? String == "HeartechoHALDriver",
          plist["CFBundleIdentifier"] as? String == HALDriverBridge.bundleIdentifier,
          let factories = plist["CFPlugInFactories"] as? [String: String],
          factories.values.contains("HeartechoHALDriverFactory"),
          let types = plist["CFPlugInTypes"] as? [String: [String]],
          types.values.flatMap({ $0 }).contains(where: { factories.keys.contains($0) }) else {
        return false
    }

    return true
}

private func verifyCHALSharedMemoryLoader(
    configuration: HALRuntimeConfiguration,
    expected: HALSharedConfigSnapshot
) throws -> Bool {
    let sharedMemoryName = "/LBSD-\(UUID().uuidString.prefix(8))"
    let publication = try HALDriverBridge.publishSharedConfiguration(
        configuration,
        sharedMemoryName: sharedMemoryName
    )
    defer {
        HALSharedMemoryPublication.unlink(name: publication.name)
        HeartechoHALDriverResetSharedConfig()
    }

    let loaded = publication.name.withCString { name in
        HeartechoHALDriverLoadSharedConfigFromSharedMemory(name)
    }
    guard loaded, let firstDevice = expected.devices.first else {
        return false
    }

    return publication.byteCount == HALSharedConfigLayout.totalByteCount &&
        activeCHALConfigMatches(firstDevice: firstDevice, expectedActiveDeviceCount: UInt32(expected.devices.filter(\.isEnabled).count))
}

private func verifyCHALConfigChangeSummary(configuration: HALRuntimeConfiguration) throws -> Bool {
    guard let firstDevice = configuration.devices.first else {
        return false
    }

    defer {
        HeartechoHALDriverResetSharedConfig()
    }

    let baselineData = try HALDriverBridge.sharedConfigurationData(from: configuration)
    guard try baselineData.withTemporaryHALConfigFile({ url in
        guard url.path.withCString({ HeartechoHALDriverLoadSharedConfigFromFile($0) }) else {
            return false
        }
        return true
    }) else {
        return false
    }

    var changedConfiguration = configuration
    changedConfiguration.devices[0].name = "\(firstDevice.name) Updated"
    changedConfiguration.devices[0].uid = "\(firstDevice.uid).updated"
    changedConfiguration.devices[0].sampleRate = firstDevice.sampleRate == 48_000 ? 44_100 : 48_000
    changedConfiguration.devices[0].channelCount = min(firstDevice.channelCount + 2, HALSharedConfigLayout.maxChannels)
    let changedData = try HALDriverBridge.sharedConfigurationData(from: changedConfiguration)
    guard try changedData.withTemporaryHALConfigFile({ url in
        guard url.path.withCString({ HeartechoHALDriverLoadSharedConfigFromFile($0) }) else {
            return false
        }
        return true
    }) else {
        return false
    }

    let summary = HeartechoHALDriverLastConfigChangeSummary()
    let matches = summary.deviceListChanged == 0 &&
        summary.deviceMetadataChanged == 1 &&
        summary.deviceFormatChanged == 1 &&
        summary.streamFormatChanged == 2 &&
        summary.notifiedObjectCount == 3
    if !matches {
        print("HAL config change summary mismatch: list=\(summary.deviceListChanged), metadata=\(summary.deviceMetadataChanged), deviceFormat=\(summary.deviceFormatChanged), streamFormat=\(summary.streamFormatChanged), notifiedObjects=\(summary.notifiedObjectCount)")
    }
    return matches
}

private func verifyCHALDeviceRuntimeProperties(
    deviceObjectID: UInt32,
    expectedLatencyFrames: UInt32 = 0,
    expectedSafetyOffsetFrames: UInt32 = 0,
    expectedBufferFrameSize: UInt32 = 512
) -> Bool {
    var latency = UInt32.max
    var latencySize = UInt32(0)
    let latencyOK = HeartechoHALDriverCopyPropertyDataForDiagnostics(
        AudioObjectID(deviceObjectID),
        kAudioDevicePropertyLatency,
        UInt32(MemoryLayout<UInt32>.size),
        &latencySize,
        &latency
    )

    var safetyOffset = UInt32.max
    var safetyOffsetSize = UInt32(0)
    let safetyOffsetOK = HeartechoHALDriverCopyPropertyDataForDiagnostics(
        AudioObjectID(deviceObjectID),
        kAudioDevicePropertySafetyOffset,
        UInt32(MemoryLayout<UInt32>.size),
        &safetyOffsetSize,
        &safetyOffset
    )

    var bufferFrameSize = UInt32(0)
    var bufferFrameSizeSize = UInt32(0)
    let bufferFrameSizeOK = HeartechoHALDriverCopyPropertyDataForDiagnostics(
        AudioObjectID(deviceObjectID),
        kAudioDevicePropertyBufferFrameSize,
        UInt32(MemoryLayout<UInt32>.size),
        &bufferFrameSizeSize,
        &bufferFrameSize
    )

    var bufferFrameSizeRange = AudioValueRange()
    var bufferFrameSizeRangeSize = UInt32(0)
    let bufferFrameSizeRangeOK = HeartechoHALDriverCopyPropertyDataForDiagnostics(
        AudioObjectID(deviceObjectID),
        kAudioDevicePropertyBufferFrameSizeRange,
        UInt32(MemoryLayout<AudioValueRange>.size),
        &bufferFrameSizeRangeSize,
        &bufferFrameSizeRange
    )

    var transportType = UInt32(0)
    var transportTypeSize = UInt32(0)
    let transportTypeOK = HeartechoHALDriverCopyPropertyDataForDiagnostics(
        AudioObjectID(deviceObjectID),
        kAudioDevicePropertyTransportType,
        UInt32(MemoryLayout<UInt32>.size),
        &transportTypeSize,
        &transportType
    )

    return latencyOK &&
        latency == expectedLatencyFrames &&
        latencySize == UInt32(MemoryLayout<UInt32>.size) &&
        safetyOffsetOK &&
        safetyOffset == expectedSafetyOffsetFrames &&
        safetyOffsetSize == UInt32(MemoryLayout<UInt32>.size) &&
        bufferFrameSizeOK &&
        bufferFrameSize == expectedBufferFrameSize &&
        bufferFrameSizeSize == UInt32(MemoryLayout<UInt32>.size) &&
        bufferFrameSizeRangeOK &&
        bufferFrameSizeRange.mMinimum > 0 &&
        bufferFrameSizeRange.mMinimum <= Double(bufferFrameSize) &&
        bufferFrameSizeRange.mMaximum >= Double(bufferFrameSize) &&
        bufferFrameSizeRangeSize == UInt32(MemoryLayout<AudioValueRange>.size) &&
        transportTypeOK &&
        transportType == kAudioDeviceTransportTypeVirtual &&
        transportTypeSize == UInt32(MemoryLayout<UInt32>.size)
}

private func verifyHeartechoHelperRuntimePublication(graph: RoutingGraph) throws -> Bool {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HeartechoHelperDiagnostics-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let graphURL = directory.appendingPathComponent("RoutingGraph.json")
    let configSharedMemoryName = "/LBHC-\(UUID().uuidString.prefix(8))"
    let audioSharedMemoryName = "/LBHA-\(UUID().uuidString.prefix(8))"

    try RoutingGraphStore(fileURL: graphURL).save(graph)
    defer {
        try? FileManager.default.removeItem(at: directory)
        HALSharedMemoryPublication.unlink(name: configSharedMemoryName)
        HALAudioBufferBridge.closeSharedMemory()
        _ = HALAudioBufferBridge.unlinkSharedMemory(name: audioSharedMemoryName)
        HALAudioBufferBridge.reset()
        HeartechoHALDriverResetSharedConfig()
    }

    let report = try HeartechoHelperRuntime.publish(options: HeartechoHelperRuntimeOptions(
        graphURL: graphURL,
        frameCount: 8,
        publishAudio: true,
        createStarterGraphIfMissing: false,
        configSharedMemoryName: configSharedMemoryName,
        audioSharedMemoryName: audioSharedMemoryName
    ))

    let loadedConfig = configSharedMemoryName.withCString { name in
        HeartechoHALDriverLoadSharedConfigFromSharedMemory(name)
    }
    HALAudioBufferBridge.closeSharedMemory()
    HALAudioBufferBridge.reset()
    let loadedAudio = HALAudioBufferBridge.loadSharedMemory(name: audioSharedMemoryName)
    let firstObjectID = HALSharedConfigLayout.deviceObjectID(for: 0)
    let snapshot = HALAudioBufferBridge.snapshot(deviceObjectID: firstObjectID)

    let singlePublishOK = report.graphURL == graphURL &&
        report.deviceCount == graph.devices.count &&
        report.enabledDeviceCount == graph.devices.filter(\.isEnabled).count &&
        report.configSharedMemoryName == configSharedMemoryName &&
        report.configByteCount == HALSharedConfigLayout.totalByteCount &&
        report.audioPublication?.didPublishSharedMemory == true &&
        report.audioPublication?.sharedMemoryName == audioSharedMemoryName &&
        report.audioPublication?.sharedMemoryByteCount == HALAudioBufferBridge.sharedMemoryByteCount &&
        loadedConfig &&
        loadedAudio &&
        HeartechoHALDriverActiveDeviceCount() == UInt32(graph.devices.filter(\.isEnabled).count) &&
        snapshot.availableFrames == 8 &&
        snapshot.totalWrittenFrames == 8

    HALAudioBufferBridge.closeSharedMemory()
    HALAudioBufferBridge.reset()
    _ = HALAudioBufferBridge.unlinkSharedMemory(name: audioSharedMemoryName)

    let runLoopReport = try HeartechoHelperRuntime.run(options: HeartechoHelperRunLoopOptions(
        publicationOptions: HeartechoHelperRuntimeOptions(
            graphURL: graphURL,
            frameCount: 2,
            publishAudio: true,
            createStarterGraphIfMissing: false,
            configSharedMemoryName: configSharedMemoryName,
            audioSharedMemoryName: audioSharedMemoryName
        ),
        intervalMilliseconds: 1,
        iterationLimit: 3
    ))

    let runLoopSnapshot = HALAudioBufferBridge.snapshot(deviceObjectID: firstObjectID)

    let checks: [(String, Bool)] = [
        ("single publish", singlePublishOK),
        ("run loop iteration count", runLoopReport.iterationCount == 3),
        ("run loop iteration limit", runLoopReport.stoppedAfterIterationLimit),
        ("run loop total frames", runLoopReport.totalPublishedFrameCount == 6),
        ("run loop shared memory", runLoopReport.lastPublication?.audioPublication?.didPublishSharedMemory == true),
        ("run loop written frames", runLoopSnapshot.totalWrittenFrames == 6)
    ]
    let failures = checks.filter { !$0.1 }
    if !failures.isEmpty {
        print("Helper runtime verification failed:")
        for failure in failures {
            print("- \(failure.0)")
        }
        print("- iterations: \(runLoopReport.iterationCount)")
        print("- total frames: \(runLoopReport.totalPublishedFrameCount)")
        print("- written frames: \(runLoopSnapshot.totalWrittenFrames)")
    }

    return failures.isEmpty
}

private func verifyMonitorGainMuteRoutingAndEnableBehavior(graph: RoutingGraph, renderReport: RuntimeRenderReport) -> Bool {
    guard var device = graph.selectedDevice,
          var monitor = device.monitors.first else {
        return false
    }

    monitor.gain = 0.5
    device.monitors = [monitor]
    let halfGainGraph = RoutingGraph(devices: [device], selectedDeviceID: device.id)
    let halfGainStates = MonitorOutputEngine().process(graph: halfGainGraph, renderReport: renderReport)
    guard halfGainStates[monitor.id]?.phase == .receiving,
          halfGainStates[monitor.id]?.peak == 0.20 else {
        return false
    }

    monitor.channels = AudioChannel.numbered(count: 2)
    monitor.routes = [
        MonitorRoute(sourceChannelIndex: 2, monitorChannelIndex: 1),
        MonitorRoute(sourceChannelIndex: 1, monitorChannelIndex: 2, gain: 0.5),
        MonitorRoute(sourceChannelIndex: 1, monitorChannelIndex: 1, isMuted: true)
    ]
    let mappedBuffer = MonitorOutputSession.mappedBuffer(
        buffer: renderReport.renders.first?.result.buffer ?? MixedAudioBuffer(channels: []),
        monitor: monitor,
        monitorID: monitor.id
    )
    guard mappedBuffer.channel(index: 1) == [0.20, 0.15, 0.10, 0.05],
          mappedBuffer.channel(index: 2) == [0.025, 0.05, 0.075, 0.10] else {
        return false
    }

    monitor.isMuted = true
    device.monitors = [monitor]
    let mutedGraph = RoutingGraph(devices: [device], selectedDeviceID: device.id)
    let mutedStates = MonitorOutputEngine().process(graph: mutedGraph, renderReport: renderReport)
    guard mutedStates[monitor.id]?.phase == .muted,
          mutedStates[monitor.id]?.peak == 0,
          mutedStates[monitor.id]?.status == "Monitor muted" else {
        return false
    }

    monitor.isMuted = false
    monitor.isEnabled = false
    device.monitors = [monitor]
    let disabledGraph = RoutingGraph(devices: [device], selectedDeviceID: device.id)
    let disabledStates = MonitorOutputEngine().process(graph: disabledGraph, renderReport: renderReport)

    guard disabledStates[monitor.id]?.phase == .disabled,
          disabledStates[monitor.id]?.peak == 0 else {
        return false
    }

    let legacyJSON = """
    {
      "id" : "\(UUID().uuidString)",
      "isEnabled" : true,
      "gain" : 1,
      "name" : "Legacy Monitor"
    }
    """

    do {
        let decoded = try JSONDecoder().decode(Monitor.self, from: Data(legacyJSON.utf8))
        return decoded.isMuted == false &&
            decoded.channels.map(\.index) == [1, 2] &&
            decoded.routes.map { "\($0.sourceChannelIndex):\($0.monitorChannelIndex)" } == ["1:1", "2:2"]
    } catch {
        return false
    }
}

private func verifyHALAudioBufferBridge(mixResult: MixResult) -> Bool {
    let deviceObjectID = HALSharedConfigLayout.objectIDBase
    let channelCount = mixResult.report.outputChannelCount
    HALAudioBufferBridge.reset()
    defer {
        HALAudioBufferBridge.reset()
    }

    guard HALAudioBufferBridge.write(
        buffer: mixResult.buffer,
        deviceObjectID: deviceObjectID,
        channelCount: channelCount
    ) else {
        return false
    }

    let beforeRead = HALAudioBufferBridge.snapshot(deviceObjectID: deviceObjectID)
    let initialHealth = HALAudioBufferBridge.healthReport(previous: nil, current: beforeRead)
    let interleaved = HALAudioBufferBridge.readInterleaved(
        deviceObjectID: deviceObjectID,
        channelCount: channelCount,
        frameCount: mixResult.report.frameCount
    )
    let afterRead = HALAudioBufferBridge.snapshot(deviceObjectID: deviceObjectID)
    let readHealth = HALAudioBufferBridge.healthReport(previous: beforeRead, current: afterRead)
    let staleHealth = HALAudioBufferBridge.healthReport(previous: afterRead, current: afterRead)

    let expectedInterleaved: [Float] = (0..<mixResult.report.frameCount).flatMap { frameIndex in
        (0..<channelCount).map { channelIndex in
            mixResult.buffer.channels[channelIndex][frameIndex]
        }
    }

    return beforeRead.availableFrames == UInt32(mixResult.report.frameCount) &&
        beforeRead.totalWrittenFrames == UInt64(mixResult.report.frameCount) &&
        beforeRead.writerHeartbeat == UInt64(mixResult.report.frameCount) &&
        initialHealth.writerAdvanced &&
        initialHealth.isHealthy &&
        afterRead.availableFrames == 0 &&
        afterRead.totalReadFrames == UInt64(mixResult.report.frameCount) &&
        afterRead.readerHeartbeat == UInt64(mixResult.report.frameCount) &&
        readHealth.readerAdvanced &&
        staleHealth.isWriterStale &&
        interleaved == expectedInterleaved
}

private func verifyHALRealtimeSafetyStats() -> Bool {
    let deviceObjectID = HALSharedConfigLayout.objectIDBase
    let frames: [Float] = [
        0.10, 0.20,
        0.30, 0.40
    ]
    var output = [Float](repeating: -1, count: 8)

    HeartechoHALDriverResetAudioBuffer()
    HeartechoHALDriverResetRealtimeSafetyStats()
    defer {
        HeartechoHALDriverResetAudioBuffer()
        HeartechoHALDriverResetRealtimeSafetyStats()
    }

    guard frames.withUnsafeBufferPointer({ pointer in
        HeartechoHALDriverWriteAudioFrames(
            AudioObjectID(deviceObjectID),
            2,
            2,
            pointer.baseAddress
        )
    }) else {
        return false
    }

    let status = output.withUnsafeMutableBufferPointer { pointer in
        HeartechoHALDriverRunIOOperationForDiagnostics(
            AudioObjectID(deviceObjectID),
            4,
            pointer.baseAddress
        )
    }
    let stats = HeartechoHALDriverRealtimeSafetyStats()

    return status == noErr &&
        output == [0.10, 0.20, 0.30, 0.40, 0, 0, 0, 0] &&
        stats.ioOperationCount == 1 &&
        stats.audioReadCallCount == 1 &&
        stats.audioReadFrameCount == 2 &&
        stats.zeroFillFrameCount == 2 &&
        stats.renderPathLockCount == 0 &&
        stats.renderPathAllocationCount == 0 &&
        stats.renderPathFileIOCount == 0 &&
        stats.renderPathSharedMemoryOpenCount == 0
}

private func verifyHALRenderPublisher(
    runtimeReport: RuntimeRenderReport,
    configuration: HALRuntimeConfiguration,
    mixResult: MixResult
) -> Bool {
    let deviceObjectID = HALSharedConfigLayout.objectIDBase
    let channelCount = mixResult.report.outputChannelCount
    HALAudioBufferBridge.reset()
    defer {
        HALAudioBufferBridge.reset()
    }

    let report = HALRenderPublisher.publish(
        renderReport: runtimeReport,
        configuration: configuration
    )
    guard report.allWritesSucceeded,
          report.failedWriteCount == 0,
          report.skippedDeviceIDs.isEmpty,
          report.totalPublishedFrameCount == mixResult.report.frameCount,
          let publication = report.publications.first,
          publication.deviceObjectID == deviceObjectID,
          publication.channelCount == channelCount,
          publication.frameCount == mixResult.report.frameCount,
          publication.snapshot.availableFrames == UInt32(mixResult.report.frameCount) else {
        return false
    }

    let interleaved = HALAudioBufferBridge.readInterleaved(
        deviceObjectID: deviceObjectID,
        channelCount: channelCount,
        frameCount: mixResult.report.frameCount
    )
    let expectedInterleaved: [Float] = (0..<mixResult.report.frameCount).flatMap { frameIndex in
        (0..<channelCount).map { channelIndex in
            mixResult.buffer.channels[channelIndex][frameIndex]
        }
    }

    return interleaved == expectedInterleaved
}

private func verifyMultiDeviceHALRenderPublisher() -> Bool {
    let firstSource = AudioSource(name: "First Pass-Thru", kind: .passThru)
    let secondSource = AudioSource(name: "Second Pass-Thru", kind: .passThru)
    let firstDevice = VirtualAudioDevice(
        name: "First Diagnostics Device",
        sources: [firstSource],
        routes: [
            ChannelRoute(sourceID: firstSource.id, sourceChannelIndex: 1, outputChannelIndex: 1),
            ChannelRoute(sourceID: firstSource.id, sourceChannelIndex: 2, outputChannelIndex: 2)
        ]
    )
    let secondDevice = VirtualAudioDevice(
        name: "Second Diagnostics Device",
        sources: [secondSource],
        routes: [
            ChannelRoute(sourceID: secondSource.id, sourceChannelIndex: 1, outputChannelIndex: 1),
            ChannelRoute(sourceID: secondSource.id, sourceChannelIndex: 2, outputChannelIndex: 2)
        ]
    )
    let graph = RoutingGraph(devices: [firstDevice, secondDevice], selectedDeviceID: firstDevice.id)
    let buffers: [UUID: SourceAudioBuffer] = [
        firstSource.id: SourceAudioBuffer(
            sourceID: firstSource.id,
            channels: [
                [0.11, 0.12, 0.13],
                [0.21, 0.22, 0.23]
            ]
        ),
        secondSource.id: SourceAudioBuffer(
            sourceID: secondSource.id,
            channels: [
                [0.51, 0.52, 0.53],
                [0.61, 0.62, 0.63]
            ]
        )
    ]
    let runtimeReport = RuntimeRoutingEngine().render(
        graph: graph,
        captureSessions: [:],
        injectedBuffers: buffers,
        frameCount: 3
    )

    HALAudioBufferBridge.reset()
    defer {
        HALAudioBufferBridge.reset()
    }

    guard let configuration = try? HALDriverBridge.runtimeConfiguration(from: graph) else {
        return false
    }

    let publicationReport = HALRenderPublisher.publish(
        renderReport: runtimeReport,
        configuration: configuration
    )

    let firstObjectID = HALSharedConfigLayout.deviceObjectID(for: 0)
    let secondObjectID = HALSharedConfigLayout.deviceObjectID(for: 1)
    let firstRead = HALAudioBufferBridge.readInterleaved(
        deviceObjectID: firstObjectID,
        channelCount: 2,
        frameCount: 3
    )
    let secondRead = HALAudioBufferBridge.readInterleaved(
        deviceObjectID: secondObjectID,
        channelCount: 2,
        frameCount: 3
    )

    return publicationReport.allWritesSucceeded &&
        publicationReport.publications.count == 2 &&
        publicationReport.totalPublishedFrameCount == 6 &&
        firstRead == [0.11, 0.21, 0.12, 0.22, 0.13, 0.23] &&
        secondRead == [0.51, 0.61, 0.52, 0.62, 0.53, 0.63]
}

private func verifyHALAudioTransportStress() -> Bool {
    let source = AudioSource(name: "Transport Stress Pass-Thru", kind: .passThru)
    let device = VirtualAudioDevice(
        name: "Transport Stress Device",
        sources: [source],
        routes: [
            ChannelRoute(sourceID: source.id, sourceChannelIndex: 1, outputChannelIndex: 1),
            ChannelRoute(sourceID: source.id, sourceChannelIndex: 2, outputChannelIndex: 2)
        ]
    )
    let graph = RoutingGraph(devices: [device], selectedDeviceID: device.id)
    guard let configuration = try? HALDriverBridge.runtimeConfiguration(from: graph) else {
        return false
    }

    let engine = RuntimeRoutingEngine()
    let deviceObjectID = HALSharedConfigLayout.deviceObjectID(for: 0)
    let frameCount = 16
    let iterationCount = 24
    var previousSnapshot: HALAudioBufferSnapshot?
    var expectedWrittenFrames = 0
    var expectedReadFrames = 0

    HALAudioBufferBridge.reset()
    HeartechoHALDriverResetRealtimeSafetyStats()
    defer {
        HALAudioBufferBridge.reset()
        HeartechoHALDriverResetRealtimeSafetyStats()
    }

    for iteration in 0..<iterationCount {
        let buffer = transportStressBuffer(sourceID: source.id, iteration: iteration, frameCount: frameCount)
        let renderReport = engine.render(
            graph: graph,
            captureSessions: [:],
            injectedBuffers: [source.id: buffer],
            frameCount: frameCount
        )
        let publicationReport = HALRenderPublisher.publish(
            renderReport: renderReport,
            configuration: configuration
        )
        guard publicationReport.allWritesSucceeded,
              publicationReport.totalPublishedFrameCount == frameCount,
              let publication = publicationReport.publications.first,
              publication.snapshot.totalWrittenFrames == UInt64(expectedWrittenFrames + frameCount) else {
            return false
        }

        let afterWrite = HALAudioBufferBridge.snapshot(deviceObjectID: deviceObjectID)
        let writeHealth = HALAudioBufferBridge.healthReport(previous: previousSnapshot, current: afterWrite)
        guard writeHealth.writerAdvanced,
              writeHealth.isHealthy,
              afterWrite.writerHeartbeat == UInt64(expectedWrittenFrames + frameCount),
              afterWrite.availableFrames == UInt32(frameCount) else {
            return false
        }

        var output = [Float](repeating: -1, count: frameCount * 2)
        let status = output.withUnsafeMutableBufferPointer { pointer in
            HeartechoHALDriverRunIOOperationForDiagnostics(
                AudioObjectID(deviceObjectID),
                UInt32(frameCount),
                pointer.baseAddress
            )
        }
        guard status == noErr,
              output == transportStressInterleaved(iteration: iteration, frameCount: frameCount) else {
            return false
        }

        expectedWrittenFrames += frameCount
        expectedReadFrames += frameCount
        let afterRead = HALAudioBufferBridge.snapshot(deviceObjectID: deviceObjectID)
        let readHealth = HALAudioBufferBridge.healthReport(previous: afterWrite, current: afterRead)
        guard readHealth.readerAdvanced,
              afterRead.availableFrames == 0,
              afterRead.totalWrittenFrames == UInt64(expectedWrittenFrames),
              afterRead.totalReadFrames == UInt64(expectedReadFrames),
              afterRead.writerHeartbeat == UInt64(expectedWrittenFrames),
              afterRead.readerHeartbeat == UInt64(expectedReadFrames),
              afterRead.droppedFrameCount == 0 else {
            return false
        }
        previousSnapshot = afterRead
    }

    let finalSnapshot = HALAudioBufferBridge.snapshot(deviceObjectID: deviceObjectID)
    let idleHealth = HALAudioBufferBridge.healthReport(previous: finalSnapshot, current: finalSnapshot)
    let stats = HeartechoHALDriverRealtimeSafetyStats()

    guard idleHealth.isWriterStale,
          !idleHealth.didOverflow,
          stats.ioOperationCount == UInt64(iterationCount),
          stats.audioReadCallCount == UInt64(iterationCount),
          stats.audioReadFrameCount == UInt64(expectedReadFrames),
          stats.zeroFillFrameCount == 0,
          stats.renderPathLockCount == 0,
          stats.renderPathAllocationCount == 0,
          stats.renderPathFileIOCount == 0,
          stats.renderPathSharedMemoryOpenCount == 0 else {
        return false
    }

    HALAudioBufferBridge.reset()

    let overflowBuffer = SourceAudioBuffer(
        sourceID: source.id,
        channels: [
            (0..<4_120).map { Float($0) / 10_000 },
            (0..<4_120).map { Float($0 + 1) / 10_000 }
        ]
    )
    let overflowReport = engine.render(
        graph: graph,
        captureSessions: [:],
        injectedBuffers: [source.id: overflowBuffer],
        frameCount: 4_120
    )
    let overflowPublication = HALRenderPublisher.publish(
        renderReport: overflowReport,
        configuration: configuration
    )
    let overflowSnapshot = HALAudioBufferBridge.snapshot(deviceObjectID: deviceObjectID)
    let overflowHealth = HALAudioBufferBridge.healthReport(previous: nil, current: overflowSnapshot)

    return overflowPublication.allWritesSucceeded &&
        overflowSnapshot.capacityFrames == 4_096 &&
        overflowSnapshot.availableFrames == 4_096 &&
        overflowSnapshot.totalWrittenFrames == 4_120 &&
        overflowSnapshot.totalReadFrames == 24 &&
        overflowSnapshot.droppedFrameCount == 24 &&
        overflowSnapshot.writerHeartbeat == 4_120 &&
        overflowHealth.didOverflow &&
        !overflowHealth.isHealthy
}

private func verifyHALAudioSharedMemoryStress() -> Bool {
    let source = AudioSource(name: "Shared Stress Pass-Thru", kind: .passThru)
    let device = VirtualAudioDevice(
        name: "Shared Stress Device",
        sources: [source],
        routes: [
            ChannelRoute(sourceID: source.id, sourceChannelIndex: 1, outputChannelIndex: 1),
            ChannelRoute(sourceID: source.id, sourceChannelIndex: 2, outputChannelIndex: 2)
        ]
    )
    let graph = RoutingGraph(devices: [device], selectedDeviceID: device.id)
    guard let configuration = try? HALDriverBridge.runtimeConfiguration(from: graph) else {
        return false
    }

    let engine = RuntimeRoutingEngine()
    let deviceObjectID = HALSharedConfigLayout.deviceObjectID(for: 0)
    let frameCount = 8
    let iterationCount = 12
    let sharedMemoryName = "/LBST-\(UUID().uuidString.prefix(8))"

    HALAudioBufferBridge.closeSharedMemory()
    _ = HALAudioBufferBridge.unlinkSharedMemory(name: sharedMemoryName)
    defer {
        HALAudioBufferBridge.closeSharedMemory()
        HALAudioBufferBridge.reset()
        _ = HALAudioBufferBridge.unlinkSharedMemory(name: sharedMemoryName)
    }

    guard HALAudioBufferBridge.openSharedMemory(name: sharedMemoryName, createIfMissing: true) else {
        return false
    }

    for iteration in 0..<iterationCount {
        let renderReport = engine.render(
            graph: graph,
            captureSessions: [:],
            injectedBuffers: [
                source.id: transportStressBuffer(sourceID: source.id, iteration: iteration, frameCount: frameCount)
            ],
            frameCount: frameCount
        )
        let publication = HALRenderPublisher.publish(
            renderReport: renderReport,
            configuration: configuration
        )
        guard publication.allWritesSucceeded else {
            return false
        }
    }

    let writerSnapshot = HALAudioBufferBridge.snapshot(deviceObjectID: deviceObjectID)
    guard writerSnapshot.availableFrames == UInt32(frameCount * iterationCount),
          writerSnapshot.totalWrittenFrames == UInt64(frameCount * iterationCount),
          writerSnapshot.writerHeartbeat == UInt64(frameCount * iterationCount) else {
        return false
    }

    HALAudioBufferBridge.closeSharedMemory()
    guard HALAudioBufferBridge.openSharedMemory(name: sharedMemoryName, createIfMissing: false) else {
        return false
    }

    for iteration in 0..<iterationCount {
        let interleaved = HALAudioBufferBridge.readInterleaved(
            deviceObjectID: deviceObjectID,
            channelCount: 2,
            frameCount: frameCount
        )
        guard interleaved == transportStressInterleaved(iteration: iteration, frameCount: frameCount) else {
            return false
        }
    }

    let readerSnapshot = HALAudioBufferBridge.snapshot(deviceObjectID: deviceObjectID)
    return readerSnapshot.availableFrames == 0 &&
        readerSnapshot.totalWrittenFrames == UInt64(frameCount * iterationCount) &&
        readerSnapshot.totalReadFrames == UInt64(frameCount * iterationCount) &&
        readerSnapshot.readerHeartbeat == UInt64(frameCount * iterationCount) &&
        readerSnapshot.droppedFrameCount == 0
}

private func transportStressBuffer(sourceID: UUID, iteration: Int, frameCount: Int) -> SourceAudioBuffer {
    SourceAudioBuffer(
        sourceID: sourceID,
        channels: [
            (0..<frameCount).map { Float(iteration * 1_000 + $0) / 10_000 },
            (0..<frameCount).map { Float(iteration * 1_000 + 500 + $0) / 10_000 }
        ]
    )
}

private func transportStressInterleaved(iteration: Int, frameCount: Int) -> [Float] {
    var interleaved: [Float] = []
    interleaved.reserveCapacity(frameCount * 2)

    for frameIndex in 0..<frameCount {
        interleaved.append(Float(iteration * 1_000 + frameIndex) / 10_000)
        interleaved.append(Float(iteration * 1_000 + 500 + frameIndex) / 10_000)
    }

    return interleaved
}

private func verifyPassThruRoutingExpansion() -> Bool {
    let passThru = AudioSource(name: "Diagnostics Pass-Thru", kind: .passThru)
    var device = VirtualAudioDevice(
        name: "Pass-Thru Expansion Device",
        outputChannels: AudioChannel.numbered(count: 6),
        sources: [passThru],
        routes: [
            ChannelRoute(sourceID: passThru.id, sourceChannelIndex: 1, outputChannelIndex: 1),
            ChannelRoute(sourceID: passThru.id, sourceChannelIndex: 2, outputChannelIndex: 2)
        ]
    )

    PassThruRouting.syncChannelsAndRoutes(device: &device)

    guard let expanded = device.sources.first(where: { $0.id == passThru.id }) else {
        return false
    }

    let expectedIndexes = Array(1...6)
    let routePairs = Set(device.routes.map { "\($0.sourceChannelIndex):\($0.outputChannelIndex)" })
    let expectedPairs = Set(expectedIndexes.map { "\($0):\($0)" })

    return expanded.channels.map(\.index) == expectedIndexes &&
        expectedPairs.isSubset(of: routePairs) &&
        RoutingGraphValidator.validate(device: device).filter { $0.severity == .error }.isEmpty
}

private func verifyNestedVirtualDeviceRouting() -> Bool {
    let baseSource = AudioSource(name: "Nested Base Pass-Thru", kind: .passThru)
    let baseDevice = VirtualAudioDevice(
        name: "Nested Base Device",
        sources: [baseSource],
        routes: [
            ChannelRoute(sourceID: baseSource.id, sourceChannelIndex: 1, outputChannelIndex: 1),
            ChannelRoute(sourceID: baseSource.id, sourceChannelIndex: 2, outputChannelIndex: 2)
        ]
    )
    let nestedSource = AudioSource(
        name: "Nested Device Source",
        kind: .virtualDevice,
        sourceIdentifier: baseDevice.id.uuidString,
        channels: baseDevice.outputChannels
    )
    let receivingDevice = VirtualAudioDevice(
        name: "Nested Receiving Device",
        sources: [nestedSource],
        routes: [
            ChannelRoute(sourceID: nestedSource.id, sourceChannelIndex: 1, outputChannelIndex: 1),
            ChannelRoute(sourceID: nestedSource.id, sourceChannelIndex: 2, outputChannelIndex: 2)
        ]
    )
    let graph = RoutingGraph(devices: [baseDevice, receivingDevice], selectedDeviceID: receivingDevice.id)
    let injected: [UUID: SourceAudioBuffer] = [
        baseSource.id: SourceAudioBuffer(
            sourceID: baseSource.id,
            channels: [
                [0.12, 0.34, 0.56],
                [0.65, 0.43, 0.21]
            ]
        )
    ]
    let report = RuntimeRoutingEngine().render(
        graph: graph,
        captureSessions: [:],
        injectedBuffers: injected,
        frameCount: 3
    )

    guard let baseRender = report.renders.first(where: { $0.deviceID == baseDevice.id }),
          let receivingRender = report.renders.first(where: { $0.deviceID == receivingDevice.id }) else {
        return false
    }

    let nestedMixOK = receivingRender.result.buffer.channel(index: 1) == baseRender.result.buffer.channel(index: 1) &&
        receivingRender.result.buffer.channel(index: 2) == baseRender.result.buffer.channel(index: 2) &&
        receivingRender.sourceFrameAvailability[nestedSource.id] == 3 &&
        receivingRender.capturedSourceIDs.contains(nestedSource.id)

    var cycleA = VirtualAudioDevice(name: "Cycle A")
    var cycleB = VirtualAudioDevice(name: "Cycle B")
    let sourceA = AudioSource(
        name: "Cycle B Source",
        kind: .virtualDevice,
        sourceIdentifier: cycleB.id.uuidString,
        channels: cycleB.outputChannels
    )
    let sourceB = AudioSource(
        name: "Cycle A Source",
        kind: .virtualDevice,
        sourceIdentifier: cycleA.id.uuidString,
        channels: cycleA.outputChannels
    )
    cycleA.sources = [sourceA]
    cycleA.routes = [ChannelRoute(sourceID: sourceA.id, sourceChannelIndex: 1, outputChannelIndex: 1)]
    cycleB.sources = [sourceB]
    cycleB.routes = [ChannelRoute(sourceID: sourceB.id, sourceChannelIndex: 1, outputChannelIndex: 1)]
    let cycleReport = RuntimeRoutingEngine().render(
        graph: RoutingGraph(devices: [cycleA, cycleB], selectedDeviceID: cycleA.id),
        captureSessions: [:],
        frameCount: 2
    )
    let cycleDidRender = cycleReport.renders.count == 2 &&
        cycleReport.renders.allSatisfy { $0.result.report.frameCount == 2 }

    return nestedMixOK && cycleDidRender
}

private func verifyRuntimeSampleRateConversion() -> Bool {
    let source = AudioSource(
        name: "Half Rate Source",
        kind: .application,
        sourceIdentifier: "com.example.HalfRateSource",
        channels: AudioChannel.stereo()
    )
    let device = VirtualAudioDevice(
        name: "Sample Rate Conversion Device",
        sampleRate: 48_000,
        sources: [source],
        routes: [
            ChannelRoute(sourceID: source.id, sourceChannelIndex: 1, outputChannelIndex: 1),
            ChannelRoute(sourceID: source.id, sourceChannelIndex: 2, outputChannelIndex: 2)
        ]
    )
    let injected = SourceAudioBuffer(
        sourceID: source.id,
        channels: [
            [0.0, 1.0, 0.0],
            [1.0, 0.0, 1.0]
        ],
        sampleRate: 24_000
    )
    let render = RuntimeRoutingEngine().render(
        device: device,
        captureSessions: [:],
        injectedBuffers: [source.id: injected],
        frameCount: 4
    )

    let directConversion = AudioSampleRateConverter.convert(
        injected,
        targetSampleRate: 48_000,
        targetFrameCount: 4,
        quality: .linear
    )

    let balancedConversion = AudioSampleRateConverter.convert(
        injected,
        targetSampleRate: 48_000,
        targetFrameCount: 4
    )

    guard directConversion.buffer.channel(index: 1) == [0.0, 0.5, 1.0, 0.5],
          directConversion.buffer.channel(index: 2) == [1.0, 0.5, 0.0, 0.5],
          balancedConversion.report?.quality == .balanced,
          balancedConversion.buffer.channel(index: 1).count == 4,
          balancedConversion.buffer.channel(index: 1).allSatisfy({ $0.isFinite }),
          render.result.buffer.frameCount == 4,
          render.resamplingReports.count == 1,
          render.resamplingReports.first?.sourceID == source.id,
          render.resamplingReports.first?.sourceSampleRate == 24_000,
          render.resamplingReports.first?.targetSampleRate == 48_000,
          render.resamplingReports.first?.effectiveSourceSampleRate != 24_000,
          render.resamplingReports.first?.inputFrameCount == 3,
          render.resamplingReports.first?.outputFrameCount == 4,
          render.resamplingReports.first?.driftCorrectionPPM == -62.5,
          render.resamplingReports.first?.quality == .balanced,
          directConversion.buffer.sampleRate == 48_000,
          directConversion.report?.ratio == 0.5 else {
        return false
    }

    guard let lowWaterCorrection = AudioDriftController.correction(availableFrameCount: 3, targetBufferedFrameCount: 8),
          lowWaterCorrection.correctionPPM == -62.5,
          let highWaterCorrection = AudioDriftController.correction(availableFrameCount: 16, targetBufferedFrameCount: 8),
          highWaterCorrection.correctionPPM == 100,
          let steadyCorrection = AudioDriftController.correction(availableFrameCount: 8, targetBufferedFrameCount: 8),
          steadyCorrection.correctionPPM == 0 else {
        return false
    }

    let sameRate = AudioSampleRateConverter.convert(
        SourceAudioBuffer(sourceID: source.id, channels: [[0.25, 0.75]], sampleRate: 48_000),
        targetSampleRate: 48_000,
        targetFrameCount: 2
    )

    guard sameRate.buffer.channels == [[0.25, 0.75]], sameRate.report == nil else {
        return false
    }

    let phaseSource = SourceAudioBuffer(
        sourceID: source.id,
        channels: [[0, 1, 2]],
        sampleRate: 36_000
    )
    var converterState = AudioResamplingState()
    let firstPhaseConversion = AudioSampleRateConverter.convert(
        phaseSource,
        targetSampleRate: 48_000,
        targetFrameCount: 4,
        state: &converterState
    )
    let secondPhaseConversion = AudioSampleRateConverter.convert(
        phaseSource,
        targetSampleRate: 48_000,
        targetFrameCount: 4,
        state: &converterState
    )

    guard firstPhaseConversion.report?.inputPhase == 0,
          firstPhaseConversion.report?.nextInputPhase == 0,
          secondPhaseConversion.report?.inputPhase == 0,
          firstPhaseConversion.report?.quality == .balanced,
          firstPhaseConversion.buffer.channel(index: 1).count == 4,
          secondPhaseConversion.buffer.channel(index: 1).count == 4,
          firstPhaseConversion.buffer.channel(index: 1).allSatisfy({ $0.isFinite }),
          secondPhaseConversion.buffer.channel(index: 1).allSatisfy({ $0.isFinite }) else {
        return false
    }

    let shortPhaseSource = SourceAudioBuffer(
        sourceID: source.id,
        channels: [[0, 1]],
        sampleRate: 36_000
    )
    let statefulEngine = RuntimeRoutingEngine()
    let firstStatefulRender = statefulEngine.render(
        device: device,
        captureSessions: [:],
        injectedBuffers: [source.id: shortPhaseSource],
        frameCount: 4
    )
    let secondStatefulRender = statefulEngine.render(
        device: device,
        captureSessions: [:],
        injectedBuffers: [source.id: shortPhaseSource],
        frameCount: 4
    )

    return firstStatefulRender.resamplingReports.first?.inputPhase == 0 &&
        firstStatefulRender.resamplingReports.first?.nextInputPhase ?? 0 > 0 &&
        secondStatefulRender.resamplingReports.first?.inputPhase ?? 0 > 0
}

private func verifyDeviceMasterGain(device: VirtualAudioDevice, sourceBuffers: [UUID: SourceAudioBuffer]) -> Bool {
    var quietDevice = device
    quietDevice.masterGain = 0.5
    let result = RoutingMixer.mix(device: quietDevice, sourceBuffers: sourceBuffers, frameCount: 4)

    return result.buffer.channel(index: 1) == [0.05, 0.10, 0.15, 0.20] &&
        result.buffer.channel(index: 2) == [0.20, 0.15, 0.10, 0.05] &&
        result.report.peakByOutputChannel[1] == 0.20
}

private func verifySourceMuteBehavior(device: VirtualAudioDevice, sourceBuffers: [UUID: SourceAudioBuffer]) -> Bool {
    guard let source = device.sources.first else {
        return false
    }

    var mutedDevice = device
    guard let sourceIndex = mutedDevice.sources.firstIndex(where: { $0.id == source.id }) else {
        return false
    }

    mutedDevice.sources[sourceIndex].isMuted = true
    let mutedResult = RoutingMixer.mix(device: mutedDevice, sourceBuffers: sourceBuffers, frameCount: 4)

    mutedDevice.sources[sourceIndex].isMuted = false
    mutedDevice.sources[sourceIndex].isEnabled = false
    let disabledResult = RoutingMixer.mix(device: mutedDevice, sourceBuffers: sourceBuffers, frameCount: 4)

    return mutedResult.report.activeRouteCount == 0 &&
        mutedResult.buffer.channels.allSatisfy { $0 == [0, 0, 0, 0] } &&
        disabledResult.report.activeRouteCount == 0 &&
        disabledResult.buffer.channels.allSatisfy { $0 == [0, 0, 0, 0] }
}

private func verifyProcessTapMuteBehaviorPersistence() -> Bool {
    let mutedAppSource = AudioSource(
        name: "Muted Capture App",
        kind: .application,
        sourceIdentifier: "com.example.MutedCaptureApp",
        mutesWhenCaptured: true
    )
    let unmutedAppSource = AudioSource(
        name: "Unmuted Capture App",
        kind: .application,
        sourceIdentifier: "com.example.UnmutedCaptureApp"
    )
    let hardwareSource = AudioSource(
        name: "Hardware Capture Source",
        kind: .hardwareInput,
        sourceIdentifier: "com.example.HardwareInput",
        mutesWhenCaptured: true
    )
    let graph = RoutingGraph(devices: [
        VirtualAudioDevice(
            name: "Process Tap Mute Diagnostics",
            sources: [mutedAppSource, unmutedAppSource, hardwareSource]
        )
    ])

    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoder = JSONDecoder()
        let data = try encoder.encode(graph)
        let decoded = try decoder.decode(RoutingGraph.self, from: data)
        let decodedSources = decoded.devices.first?.sources ?? []

        guard decodedSources.first(where: { $0.id == mutedAppSource.id })?.mutesWhenCaptured == true,
              decodedSources.first(where: { $0.id == unmutedAppSource.id })?.mutesWhenCaptured == false,
              decodedSources.first(where: { $0.id == hardwareSource.id })?.mutesWhenCaptured == true else {
            return false
        }

        let mutedConfiguration = ProcessTapCaptureConfiguration(
            applicationSource: mutedAppSource,
            processIdentifier: 123
        )
        let unmutedConfiguration = ProcessTapCaptureConfiguration(
            applicationSource: unmutedAppSource,
            processIdentifier: 456
        )
        guard mutedConfiguration.muteBehavior == .mutedWhenTapped,
              unmutedConfiguration.muteBehavior == .unmuted else {
            return false
        }

        let multiProcessConfiguration = ProcessTapCaptureConfiguration(
            applicationSource: mutedAppSource,
            processIdentifiers: [456, 123, 456]
        )
        guard multiProcessConfiguration.processIdentifier == 123,
              multiProcessConfiguration.processIdentifiers == [123, 456],
              multiProcessConfiguration.muteBehavior == .mutedWhenTapped else {
            return false
        }

        let legacyJSON = """
        {
          "devices" : [
            {
              "id" : "\(UUID().uuidString)",
              "isEnabled" : true,
              "isMuted" : false,
              "masterGain" : 1,
              "monitors" : [],
              "name" : "Legacy Device",
              "outputChannels" : [
                { "id" : "\(UUID().uuidString)", "index" : 1, "name" : "Left" },
                { "id" : "\(UUID().uuidString)", "index" : 2, "name" : "Right" }
              ],
              "routes" : [],
              "sampleRate" : 48000,
              "sources" : [
                {
                  "channels" : [
                    { "id" : "\(UUID().uuidString)", "index" : 1, "name" : "Left" },
                    { "id" : "\(UUID().uuidString)", "index" : 2, "name" : "Right" }
                  ],
                  "gain" : 1,
                  "id" : "\(UUID().uuidString)",
                  "isEnabled" : true,
                  "isMuted" : false,
                  "kind" : "application",
                  "name" : "Legacy App",
                  "sourceIdentifier" : "com.example.LegacyApp"
                }
              ]
            }
          ]
        }
        """
        let legacyGraph = try decoder.decode(RoutingGraph.self, from: Data(legacyJSON.utf8))
        return legacyGraph.devices.first?.sources.first?.mutesWhenCaptured == false &&
            legacyGraph.devices.first?.latencyFrames == 0 &&
            legacyGraph.devices.first?.safetyOffsetFrames == 0 &&
            legacyGraph.devices.first?.bufferFrameSize == 512
    } catch {
        return false
    }
}

private func verifyVirtualDeviceLifecycleBehavior() -> Bool {
    let activeSource = AudioSource(name: "Lifecycle Active Pass-Thru", kind: .passThru)
    let disabledSource = AudioSource(name: "Lifecycle Disabled Pass-Thru", kind: .passThru)
    let activeDevice = VirtualAudioDevice(
        name: "Lifecycle Active Device",
        sampleRate: 44_100,
        latencyFrames: 12,
        safetyOffsetFrames: 4,
        bufferFrameSize: 1024,
        sources: [activeSource],
        routes: [
            ChannelRoute(sourceID: activeSource.id, sourceChannelIndex: 1, outputChannelIndex: 1),
            ChannelRoute(sourceID: activeSource.id, sourceChannelIndex: 2, outputChannelIndex: 2)
        ]
    )
    let disabledDevice = VirtualAudioDevice(
        name: "Lifecycle Disabled Device",
        isEnabled: false,
        sampleRate: 96_000,
        outputChannels: AudioChannel.numbered(count: 4),
        sources: [disabledSource],
        routes: [
            ChannelRoute(sourceID: disabledSource.id, sourceChannelIndex: 1, outputChannelIndex: 1)
        ]
    )
    let nestedSource = AudioSource(
        name: "Lifecycle Nested Device",
        kind: .virtualDevice,
        sourceIdentifier: disabledDevice.id.uuidString,
        channels: disabledDevice.outputChannels
    )
    let dependentDevice = VirtualAudioDevice(
        name: "Lifecycle Dependent Device",
        sources: [nestedSource],
        routes: [
            ChannelRoute(sourceID: nestedSource.id, sourceChannelIndex: 1, outputChannelIndex: 1)
        ]
    )
    let graph = RoutingGraph(
        devices: [activeDevice, disabledDevice, dependentDevice],
        selectedDeviceID: disabledDevice.id
    )

    do {
        let configuration = try HALDriverBridge.runtimeConfiguration(from: graph)
        let data = try HALDriverBridge.sharedConfigurationData(from: configuration)
        let snapshot = try HALDriverBridge.decodeSharedConfigurationData(data)
        let cRuntimePropertiesMatch = try data.withTemporaryHALConfigFile { url in
            guard url.path.withCString({ HeartechoHALDriverLoadSharedConfigFromFile($0) }) else {
                return false
            }
            return verifyCHALDeviceRuntimeProperties(
                deviceObjectID: snapshot.devices[0].deviceObjectID,
                expectedLatencyFrames: 12,
                expectedSafetyOffsetFrames: 4,
                expectedBufferFrameSize: 1024
            )
        }
        guard snapshot.devices.count == 3,
              snapshot.devices[0].sampleRate == 44_100,
              snapshot.devices[0].latencyFrames == 12,
              snapshot.devices[0].safetyOffsetFrames == 4,
              snapshot.devices[0].bufferFrameSize == 1024,
              snapshot.devices[1].sampleRate == 96_000,
              snapshot.devices[1].channelCount == 4,
              !snapshot.devices[1].isEnabled,
              cRuntimePropertiesMatch,
              try verifyDisabledDeviceHALFiltering(data: data, snapshot: snapshot) else {
            return false
        }

        let buffers = [
            activeSource.id: SourceAudioBuffer(
                sourceID: activeSource.id,
                channels: [[0.5, 0.6], [0.7, 0.8]]
            ),
            disabledSource.id: SourceAudioBuffer(
                sourceID: disabledSource.id,
                channels: [[0.9, 1.0]]
            )
        ]
        let runtimeReport = RuntimeRoutingEngine().render(
            graph: graph,
            captureSessions: [:],
            injectedBuffers: buffers,
            frameCount: 2
        )
        HALAudioBufferBridge.reset()
        defer {
            HALAudioBufferBridge.reset()
        }
        let publication = HALRenderPublisher.publish(
            renderReport: runtimeReport,
            configuration: configuration
        )
        guard publication.publications.count == 2,
              publication.skippedDeviceIDs == Set([disabledDevice.id]),
              publication.publications.allSatisfy(\.didWrite) else {
            return false
        }

        var deletionGraph = graph
        guard deletionGraph.removeDevice(id: disabledDevice.id),
              deletionGraph.devices.count == 2,
              deletionGraph.selectedDeviceID == dependentDevice.id,
              deletionGraph.devices.allSatisfy({ device in
                  !device.sources.contains { source in
                      source.kind == .virtualDevice && source.sourceIdentifier == disabledDevice.id.uuidString
                  }
              }),
              deletionGraph.devices.allSatisfy({ device in
                  !device.routes.contains { $0.sourceID == nestedSource.id }
              }) else {
            return false
        }

        var singleDeviceGraph = RoutingGraph(devices: [activeDevice], selectedDeviceID: activeDevice.id)
        return !singleDeviceGraph.removeDevice(id: activeDevice.id) &&
            singleDeviceGraph.devices.count == 1 &&
            singleDeviceGraph.selectedDeviceID == activeDevice.id
    } catch {
        return false
    }
}

private func verifySpecialApplicationSourceBehavior() -> Bool {
    let defaultSources = SpecialApplicationSource.defaults
    guard defaultSources.count == 8,
          defaultSources.map(\.name) == [
              "Finder",
              "Siri",
              "Sound Effects",
              "VoiceOver",
              "Background Sounds",
              "Notification Center",
              "Spoken Content",
              "System AirPlay Receiver"
          ],
          Set(defaultSources.map(\.id)).count == defaultSources.count,
          defaultSources.allSatisfy({ !$0.capturedIdentifiers.isEmpty }),
          defaultSources[0].capturedIdentifiers.contains("com.apple.quicklook.ui.helper"),
          defaultSources[1].capturedIdentifiers.contains("com.apple.assistant_service"),
          SpecialApplicationSource.defaults(supportedOnMajorOSVersion: 14).count == defaultSources.count,
          SpecialApplicationSource.defaults(supportedOnMajorOSVersion: 12).isEmpty else {
        return false
    }

    let finder = defaultSources[0]
    let fallback = SpecialApplicationSource(id: "diagnostic-special-source", name: "Diagnostic Special Source")
    let finderSource = AudioSource(
        name: finder.name,
        kind: .application,
        sourceIdentifier: finder.sourceIdentifier,
        channels: AudioChannel.stereo()
    )
    let fallbackSource = AudioSource(
        name: fallback.name,
        kind: .application,
        sourceIdentifier: fallback.sourceIdentifier,
        channels: AudioChannel.stereo()
    )
    let device = VirtualAudioDevice(
        name: "Special Sources Device",
        sources: [finderSource, fallbackSource],
        routes: [
            ChannelRoute(sourceID: finderSource.id, sourceChannelIndex: 1, outputChannelIndex: 1),
            ChannelRoute(sourceID: finderSource.id, sourceChannelIndex: 2, outputChannelIndex: 2),
            ChannelRoute(sourceID: fallbackSource.id, sourceChannelIndex: 1, outputChannelIndex: 1)
        ]
    )
    let graph = RoutingGraph(devices: [device], selectedDeviceID: device.id)

    do {
        let decoded = try RoutingGraphStore.decode(RoutingGraphStore.encode(graph))
        let halData = try HALDriverBridge.sharedConfigurationData(from: decoded)
        let snapshot = try HALDriverBridge.decodeSharedConfigurationData(halData)
        let rendered = RuntimeRoutingEngine().render(
            graph: decoded,
            captureSessions: [:],
            injectedBuffers: [
                finderSource.id: SourceAudioBuffer(
                    sourceID: finderSource.id,
                    channels: [[0.1, 0.2], [0.3, 0.4]]
                ),
                fallbackSource.id: SourceAudioBuffer(
                    sourceID: fallbackSource.id,
                    channels: [[0.5, 0.6], [0.7, 0.8]]
                )
            ],
            frameCount: 2
        )

        return decoded.selectedDevice?.sources.first?.sourceIdentifier == "special:finder" &&
            decoded.selectedDevice?.sources.last?.sourceIdentifier == "special:diagnostic-special-source" &&
            decoded.selectedDevice?.routes.count == 3 &&
            snapshot.devices.first?.name == "Special Sources Device" &&
            rendered.renders.first?.result.report.activeRouteCount == 3 &&
            rendered.renders.first?.result.buffer.channel(index: 1) == [0.6, 0.8]
    } catch {
        return false
    }
}

private func verifyDisabledDeviceHALFiltering(data: Data, snapshot: HALSharedConfigSnapshot) throws -> Bool {
    defer {
        HeartechoHALDriverResetSharedConfig()
    }

    return try data.withTemporaryHALConfigFile { url in
        guard url.path.withCString({ HeartechoHALDriverLoadSharedConfigFromFile($0) }) else {
            return false
        }

        var firstNameBuffer = [CChar](repeating: 0, count: HALSharedConfigLayout.maxNameBytes)
        var secondNameBuffer = [CChar](repeating: 0, count: HALSharedConfigLayout.maxNameBytes)
        HeartechoHALDriverCopyActiveDeviceName(0, &firstNameBuffer, firstNameBuffer.count)
        HeartechoHALDriverCopyActiveDeviceName(1, &secondNameBuffer, secondNameBuffer.count)

        return HeartechoHALDriverActiveDeviceCount() == 2 &&
            HeartechoHALDriverActiveDeviceObjectID(0) == snapshot.devices[0].deviceObjectID &&
            HeartechoHALDriverActiveDeviceSampleRate(0) == 44_100 &&
            HeartechoHALDriverActiveDeviceIsEnabled(0) &&
            stringFromNullTerminatedBuffer(firstNameBuffer) == "Lifecycle Active Device" &&
            HeartechoHALDriverActiveDeviceObjectID(1) == snapshot.devices[2].deviceObjectID &&
            stringFromNullTerminatedBuffer(secondNameBuffer) == "Lifecycle Dependent Device"
    }
}

private func verifyRenamedGraphPersistenceAndHALConfig() -> Bool {
    let source = AudioSource(name: "Renamed Source", kind: .passThru)
    let monitor = Monitor(name: "Renamed Monitor")
    let device = VirtualAudioDevice(
        name: "Renamed Virtual Device",
        sources: [source],
        routes: [
            ChannelRoute(sourceID: source.id, sourceChannelIndex: 1, outputChannelIndex: 1),
            ChannelRoute(sourceID: source.id, sourceChannelIndex: 2, outputChannelIndex: 2)
        ],
        monitors: [monitor]
    )
    let graph = RoutingGraph(devices: [device], selectedDeviceID: device.id)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LoopbackRenameDiagnostics-\(UUID().uuidString)", isDirectory: true)
    let graphURL = directory.appendingPathComponent("RoutingGraph.json")

    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let store = RoutingGraphStore(fileURL: graphURL)
        try store.save(graph)
        let loaded = try store.load()
        let data = try HALDriverBridge.sharedConfigurationData(from: loaded)
        let snapshot = try HALDriverBridge.decodeSharedConfigurationData(data)

        return loaded.selectedDevice?.name == "Renamed Virtual Device" &&
            loaded.selectedDevice?.sources.first?.name == "Renamed Source" &&
            loaded.selectedDevice?.monitors.first?.name == "Renamed Monitor" &&
            snapshot.devices.first?.name == "Renamed Virtual Device"
    } catch {
        return false
    }
}

private func verifyPresetRoundTripAndHALConfig() -> Bool {
    let source = AudioSource(
        name: "Preset Pass-Thru",
        kind: .passThru,
        channels: AudioChannel.numbered(count: 4),
        gain: 0.75
    )
    let monitor = Monitor(
        name: "Preset Monitor",
        gain: 0.8,
        channels: AudioChannel.numbered(count: 4),
        routes: [
            MonitorRoute(sourceChannelIndex: 4, monitorChannelIndex: 1),
            MonitorRoute(sourceChannelIndex: 1, monitorChannelIndex: 2, gain: 0.5)
        ]
    )
    let device = VirtualAudioDevice(
        name: "Preset Device",
        sampleRate: 96_000,
        bufferFrameSize: 2048,
        outputChannels: AudioChannel.numbered(count: 4),
        sources: [source],
        routes: [
            ChannelRoute(sourceID: source.id, sourceChannelIndex: 1, outputChannelIndex: 1),
            ChannelRoute(sourceID: source.id, sourceChannelIndex: 2, outputChannelIndex: 2),
            ChannelRoute(sourceID: source.id, sourceChannelIndex: 3, outputChannelIndex: 3),
            ChannelRoute(sourceID: source.id, sourceChannelIndex: 4, outputChannelIndex: 4)
        ],
        monitors: [monitor],
        masterGain: 0.9
    )
    let graph = RoutingGraph(devices: [device], selectedDeviceID: device.id)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LoopbackPresetDiagnostics-\(UUID().uuidString)", isDirectory: true)
    let presetURL = directory.appendingPathComponent("Preset.json")

    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let exportedData = try RoutingGraphStore.encode(graph)
        try exportedData.write(to: presetURL, options: [.atomic])
        let importedGraph = try RoutingGraphStore.decode(Data(contentsOf: presetURL))
        let storeURL = directory.appendingPathComponent("ImportedRoutingGraph.json")
        let store = RoutingGraphStore(fileURL: storeURL)
        try store.save(importedGraph)
        let loadedGraph = try store.load()
        let halData = try HALDriverBridge.sharedConfigurationData(from: loadedGraph)
        let snapshot = try HALDriverBridge.decodeSharedConfigurationData(halData)

        guard loadedGraph == graph,
              loadedGraph.selectedDevice?.monitors.first?.routes.count == 2,
              snapshot.devices.first?.name == "Preset Device",
              snapshot.devices.first?.sampleRate == 96_000,
              snapshot.devices.first?.bufferFrameSize == 2048,
              snapshot.devices.first?.channelCount == 4 else {
            return false
        }

        return (try? RoutingGraphStore.decode(Data("not json".utf8))) == nil
    } catch {
        return false
    }
}

private func verifyPresetLibraryBehavior() -> Bool {
    let source = AudioSource(
        name: "Library Source",
        kind: .passThru,
        channels: AudioChannel.numbered(count: 4)
    )
    let device = VirtualAudioDevice(
        name: "Library Device",
        sampleRate: 88_200,
        outputChannels: AudioChannel.numbered(count: 4),
        sources: [source],
        routes: [
            ChannelRoute(sourceID: source.id, sourceChannelIndex: 1, outputChannelIndex: 1),
            ChannelRoute(sourceID: source.id, sourceChannelIndex: 2, outputChannelIndex: 2)
        ]
    )
    let graph = RoutingGraph(devices: [device], selectedDeviceID: device.id)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LoopbackPresetLibraryDiagnostics-\(UUID().uuidString)", isDirectory: true)
    let library = RoutingPresetLibrary(directoryURL: directory)
    let firstDate = Date(timeIntervalSince1970: 10)
    let secondDate = Date(timeIntervalSince1970: 20)

    do {
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let firstMetadata = try library.save(
            name: "Library First",
            graph: graph,
            now: firstDate,
            tags: ["Podcast", "#Calls", "calls", "  "]
        )
        var secondGraph = graph
        secondGraph.devices[0].name = "Library Second Device"
        let secondMetadata = try library.save(
            name: "Library Second",
            graph: secondGraph,
            now: secondDate,
            tags: ["Streaming"]
        )
        let listed = try library.list()
        guard listed.map(\.id) == [secondMetadata.id, firstMetadata.id],
              listed.first?.deviceCount == 1,
              listed.first?.tags == ["Streaming"],
              listed.last?.tags == ["Calls", "Podcast"],
              try library.load(id: firstMetadata.id).graph == graph else {
            return false
        }

        let searchByName = try library.search(query: "second")
        let searchByTag = try library.search(query: "pod")
        let searchByRequiredTag = try library.search(tags: ["calls"])
        let availableTags = try library.availableTags()
        guard searchByName.map(\.id) == [secondMetadata.id],
              searchByTag.map(\.id) == [firstMetadata.id],
              searchByRequiredTag.map(\.id) == [firstMetadata.id],
              availableTags == ["Calls", "Podcast", "Streaming"] else {
            return false
        }

        let envelopeData = try RoutingPresetLibrary.encode(RoutingPreset(
            name: "Envelope Import",
            graph: secondGraph,
            now: secondDate,
            tags: ["Studio"]
        ))
        let importedEnvelope = try library.importPresetData(
            envelopeData,
            fallbackName: "Ignored",
            now: Date(timeIntervalSince1970: 30),
            tags: ["Archive"]
        )
        let legacyGraphData = try RoutingGraphStore.encode(graph)
        let importedLegacy = try library.importPresetData(legacyGraphData, fallbackName: "Legacy Import", now: Date(timeIntervalSince1970: 40))
        let migrated = try RoutingPresetLibrary.decodePresetOrGraph(legacyGraphData, fallbackName: "Migrated")
        let retagged = try library.updateTags(id: firstMetadata.id, tags: ["Broadcast", "#Studio"], now: Date(timeIntervalSince1970: 50))

        guard importedEnvelope.name == "Envelope Import",
              importedEnvelope.tags == ["Archive", "Studio"],
              importedLegacy.name == "Legacy Import",
              importedLegacy.tags.isEmpty,
              migrated.metadata.name == "Migrated",
              migrated.metadata.tags.isEmpty,
              migrated.graph == graph,
              try library.load(id: importedLegacy.id).graph == graph,
              retagged.tags == ["Broadcast", "Studio"],
              try library.search(tags: ["studio"]).map(\.id).contains(firstMetadata.id) else {
            return false
        }

        try library.delete(id: secondMetadata.id)
        let afterDelete = try library.list()
        let emptyGraphSaveFailed = (try? library.save(name: "Empty", graph: RoutingGraph(devices: []))) == nil
        return emptyGraphSaveFailed &&
            !afterDelete.contains(where: { $0.id == secondMetadata.id }) &&
            afterDelete.contains(where: { $0.id == firstMetadata.id }) &&
            afterDelete.contains(where: { $0.id == importedEnvelope.id }) &&
            afterDelete.contains(where: { $0.id == importedLegacy.id })
    } catch {
        return false
    }
}

private func verifyHALAudioSharedMemoryPublication() -> Bool {
    let firstSource = AudioSource(name: "Shared First Pass-Thru", kind: .passThru)
    let secondSource = AudioSource(name: "Shared Second Pass-Thru", kind: .passThru)
    let firstDevice = VirtualAudioDevice(
        name: "Shared First Diagnostics Device",
        sources: [firstSource],
        routes: [
            ChannelRoute(sourceID: firstSource.id, sourceChannelIndex: 1, outputChannelIndex: 1),
            ChannelRoute(sourceID: firstSource.id, sourceChannelIndex: 2, outputChannelIndex: 2)
        ]
    )
    let secondDevice = VirtualAudioDevice(
        name: "Shared Second Diagnostics Device",
        sources: [secondSource],
        routes: [
            ChannelRoute(sourceID: secondSource.id, sourceChannelIndex: 1, outputChannelIndex: 1),
            ChannelRoute(sourceID: secondSource.id, sourceChannelIndex: 2, outputChannelIndex: 2)
        ]
    )
    let graph = RoutingGraph(devices: [firstDevice, secondDevice], selectedDeviceID: firstDevice.id)
    let buffers: [UUID: SourceAudioBuffer] = [
        firstSource.id: SourceAudioBuffer(
            sourceID: firstSource.id,
            channels: [
                [0.14, 0.15],
                [0.24, 0.25]
            ]
        ),
        secondSource.id: SourceAudioBuffer(
            sourceID: secondSource.id,
            channels: [
                [0.54, 0.55],
                [0.64, 0.65]
            ]
        )
    ]
    let runtimeReport = RuntimeRoutingEngine().render(
        graph: graph,
        captureSessions: [:],
        injectedBuffers: buffers,
        frameCount: 2
    )
    let sharedMemoryName = "/LBSA-\(UUID().uuidString.prefix(8))"

    HALAudioBufferBridge.closeSharedMemory()
    HALAudioBufferBridge.reset()
    defer {
        HALAudioBufferBridge.closeSharedMemory()
        HALAudioBufferBridge.reset()
        _ = HALAudioBufferBridge.unlinkSharedMemory(name: sharedMemoryName)
    }

    guard let configuration = try? HALDriverBridge.runtimeConfiguration(from: graph) else {
        return false
    }

    let publicationReport = HALRenderPublisher.publishToSharedMemory(
        renderReport: runtimeReport,
        configuration: configuration,
        sharedMemoryName: sharedMemoryName
    )
    guard publicationReport.allWritesSucceeded,
          publicationReport.didPublishSharedMemory,
          publicationReport.sharedMemoryByteCount == HALAudioBufferBridge.sharedMemoryByteCount else {
        return false
    }

    HALAudioBufferBridge.closeSharedMemory()
    HALAudioBufferBridge.reset()
    guard HALAudioBufferBridge.loadSharedMemory(name: sharedMemoryName) else {
        return false
    }

    let firstObjectID = HALSharedConfigLayout.deviceObjectID(for: 0)
    let secondObjectID = HALSharedConfigLayout.deviceObjectID(for: 1)
    let firstRead = HALAudioBufferBridge.readInterleaved(
        deviceObjectID: firstObjectID,
        channelCount: 2,
        frameCount: 2
    )
    let secondRead = HALAudioBufferBridge.readInterleaved(
        deviceObjectID: secondObjectID,
        channelCount: 2,
        frameCount: 2
    )

    return firstRead == [0.14, 0.24, 0.15, 0.25] &&
        secondRead == [0.54, 0.64, 0.55, 0.65]
}

private func verifyHALAudioLiveSharedMemoryPublication() -> Bool {
    let source = AudioSource(name: "Live Shared Pass-Thru", kind: .passThru)
    let device = VirtualAudioDevice(
        name: "Live Shared Diagnostics Device",
        sources: [source],
        routes: [
            ChannelRoute(sourceID: source.id, sourceChannelIndex: 1, outputChannelIndex: 1),
            ChannelRoute(sourceID: source.id, sourceChannelIndex: 2, outputChannelIndex: 2)
        ]
    )
    let graph = RoutingGraph(devices: [device], selectedDeviceID: device.id)
    let buffers: [UUID: SourceAudioBuffer] = [
        source.id: SourceAudioBuffer(
            sourceID: source.id,
            channels: [
                [0.31, 0.32, 0.33],
                [0.41, 0.42, 0.43]
            ]
        )
    ]
    let runtimeReport = RuntimeRoutingEngine().render(
        graph: graph,
        captureSessions: [:],
        injectedBuffers: buffers,
        frameCount: 3
    )
    let sharedMemoryName = "/LBSL-\(UUID().uuidString.prefix(8))"

    HALAudioBufferBridge.closeSharedMemory()
    _ = HALAudioBufferBridge.unlinkSharedMemory(name: sharedMemoryName)
    defer {
        HALAudioBufferBridge.closeSharedMemory()
        HALAudioBufferBridge.reset()
        _ = HALAudioBufferBridge.unlinkSharedMemory(name: sharedMemoryName)
    }

    guard let configuration = try? HALDriverBridge.runtimeConfiguration(from: graph) else {
        return false
    }

    let publicationReport = HALRenderPublisher.publishToSharedMemory(
        renderReport: runtimeReport,
        configuration: configuration,
        sharedMemoryName: sharedMemoryName
    )
    guard publicationReport.allWritesSucceeded,
          publicationReport.didPublishSharedMemory else {
        return false
    }

    HALAudioBufferBridge.closeSharedMemory()
    guard HALAudioBufferBridge.openSharedMemory(name: sharedMemoryName, createIfMissing: false) else {
        return false
    }

    let objectID = HALSharedConfigLayout.deviceObjectID(for: 0)
    let snapshot = HALAudioBufferBridge.snapshot(deviceObjectID: objectID)
    let interleaved = HALAudioBufferBridge.readInterleaved(
        deviceObjectID: objectID,
        channelCount: 2,
        frameCount: 3
    )

    return snapshot.availableFrames == 3 &&
        snapshot.totalWrittenFrames == 3 &&
        interleaved == [0.31, 0.41, 0.32, 0.42, 0.33, 0.43]
}

private func activeCHALConfigMatches(firstDevice: HALSharedDeviceSnapshot, expectedActiveDeviceCount: UInt32) -> Bool {
    var nameBuffer = [CChar](repeating: 0, count: HALSharedConfigLayout.maxNameBytes)
    var uidBuffer = [CChar](repeating: 0, count: HALSharedConfigLayout.maxUIDBytes)
    HeartechoHALDriverCopyActiveDeviceName(0, &nameBuffer, nameBuffer.count)
    HeartechoHALDriverCopyActiveDeviceUID(0, &uidBuffer, uidBuffer.count)
    let loadedName = stringFromNullTerminatedBuffer(nameBuffer)
    let loadedUID = stringFromNullTerminatedBuffer(uidBuffer)

    return HeartechoHALDriverActiveDeviceCount() == expectedActiveDeviceCount &&
        HeartechoHALDriverActiveDeviceObjectID(0) == firstDevice.deviceObjectID &&
        HeartechoHALDriverActiveDeviceChannelCount(0) == firstDevice.channelCount &&
        HeartechoHALDriverActiveDeviceSampleRate(0) == firstDevice.sampleRate &&
        HeartechoHALDriverActiveDeviceIsEnabled(0) &&
        loadedName == firstDevice.name &&
        loadedUID == firstDevice.uid &&
        verifyCHALDeviceRuntimeProperties(
            deviceObjectID: firstDevice.deviceObjectID,
            expectedLatencyFrames: UInt32(firstDevice.latencyFrames),
            expectedSafetyOffsetFrames: UInt32(firstDevice.safetyOffsetFrames),
            expectedBufferFrameSize: UInt32(firstDevice.bufferFrameSize)
        )
}

private func stringFromNullTerminatedBuffer(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

private extension Data {
    func withTemporaryHALConfigFile<T>(_ body: (URL) throws -> T) throws -> T {
        let fileURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("HeartechoHALSharedConfig-\(UUID().uuidString).bin")
        try write(to: fileURL, options: [.atomic])
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }
        return try body(fileURL)
    }
}
