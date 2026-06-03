import CoreAudio
import Foundation
import HeartechoCore

@MainActor
public final class AudioEngineController: ObservableObject {
    @Published public private(set) var systemDevices: [SystemAudioDevice] = []
    @Published public private(set) var runningApplications: [RunningApplicationSource] = []
    @Published public private(set) var captureCandidateProcesses: [ApplicationProcessSource] = []
    @Published public private(set) var processTapCapability: ProcessTapCapability
    @Published public private(set) var processTapDiagnostics: [ProcessTapProcessDiagnostic] = []
    @Published public private(set) var captureStates: [UUID: SourceCaptureState] = [:]
    @Published public private(set) var lastRenderReport: RuntimeRenderReport?
    @Published public private(set) var lastHALPublicationReport: HALRenderPublicationReport?
    @Published public private(set) var halRealtimeSafetyReport: HALRealtimeSafetyReport?
    @Published public private(set) var halAudioTransportHealthReports: [UInt32: HALAudioTransportHealthReport] = [:]
    @Published public private(set) var monitorStates: [UUID: MonitorOutputState] = [:]
    @Published public private(set) var monitorPlaybackStates: [UUID: MonitorPlaybackState] = [:]
    @Published public private(set) var driverStatus: DriverStatus = .notInstalled
    @Published public private(set) var driverProbeReport: HALDriverProbeReport?
    @Published public private(set) var helperServiceReport: HelperServiceProbeReport?
    @Published public private(set) var microphonePermissionStatus: MicrophonePermissionState
    @Published public private(set) var readinessReport: AudioReadinessReport = .empty

    private let discovery: CoreAudioDeviceDiscovery
    private let driverProbe: HALDriverProbe
    private let helperServiceProbe: HelperServiceProbe
    private let applicationDiscovery: ApplicationAudioSourceDiscovery
    private let processTapManager: CoreAudioProcessTapManager
    private let runtimeRoutingEngine: RuntimeRoutingEngine
    private let monitorOutputEngine: MonitorOutputEngine
    private var captureSessions: [UUID: ProcessTapCaptureSession] = [:]
    private var hardwareCaptureSessions: [UUID: HardwareInputCaptureSession] = [:]
    private var monitorPlaybackSessions: [UUID: HardwareMonitorPlaybackSession] = [:]
    private var activeGraph: RoutingGraph?
    private var previousHALAudioSnapshots: [UInt32: HALAudioBufferSnapshot] = [:]

    public init(
        discovery: CoreAudioDeviceDiscovery = CoreAudioDeviceDiscovery(),
        driverProbe: HALDriverProbe = HALDriverProbe(),
        helperServiceProbe: HelperServiceProbe = HelperServiceProbe(),
        applicationDiscovery: ApplicationAudioSourceDiscovery? = nil,
        processTapManager: CoreAudioProcessTapManager = CoreAudioProcessTapManager(),
        runtimeRoutingEngine: RuntimeRoutingEngine = RuntimeRoutingEngine(),
        monitorOutputEngine: MonitorOutputEngine = MonitorOutputEngine()
    ) {
        self.discovery = discovery
        self.driverProbe = driverProbe
        self.helperServiceProbe = helperServiceProbe
        self.applicationDiscovery = applicationDiscovery ?? ApplicationAudioSourceDiscovery()
        self.processTapManager = processTapManager
        self.runtimeRoutingEngine = runtimeRoutingEngine
        self.monitorOutputEngine = monitorOutputEngine
        self.processTapCapability = processTapManager.capability
        self.microphonePermissionStatus = MicrophonePermissionProbe.currentStatus()
        refreshReadiness()
    }

    public func refreshDevices() {
        systemDevices = discovery.allDevices()
        refreshDriverProbe()
    }

    public func refreshApplications() {
        runningApplications = applicationDiscovery.runningApplications()
        captureCandidateProcesses = applicationDiscovery.captureCandidateProcesses()
        refreshProcessTapDiagnostics()
    }

    public func refreshSources() {
        refreshDevices()
        refreshApplications()
        refreshHelperServiceProbe()
        refreshMicrophonePermissionStatus()
        refreshReadiness()
    }

    public func refreshDriverProbe() {
        let report = driverProbe.probe(systemDevices: systemDevices)
        driverProbeReport = report
        if report.deviceProbe.isVisible {
            driverStatus = .running
        } else if report.hasInstalledBundle {
            driverStatus = .notVisible
        } else if report.buildArtifact?.exists == true {
            driverStatus = .builtNotInstalled
        } else {
            driverStatus = .notInstalled
        }
        refreshReadiness()
    }

    public func refreshHelperServiceProbe() {
        helperServiceReport = helperServiceProbe.probe()
        refreshReadiness()
    }

    public func refreshProcessTapDiagnostics() {
        processTapCapability = processTapManager.capability
        processTapDiagnostics = runningApplications.map { application in
            let processObjectID = processTapManager.processObjectID(for: application.processIdentifier)
            return ProcessTapProcessDiagnostic(
                applicationID: application.id,
                processIdentifier: application.processIdentifier,
                name: application.name,
                processObjectID: processObjectID,
                isRunningOutput: processObjectID.map {
                    processTapManager.isProcessRunningOutput(processObjectID: $0)
                } ?? false
            )
        }
        refreshReadiness()
    }

    public func refreshMicrophonePermissionStatus() {
        microphonePermissionStatus = MicrophonePermissionProbe.currentStatus()
        refreshReadiness()
    }

    public func requestMicrophoneAccess() async {
        microphonePermissionStatus = await MicrophonePermissionProbe.requestAccess()
        refreshReadiness()
    }

    public func refreshReadiness() {
        readinessReport = AudioReadinessReporter.makeReport(
            driverProbeReport: driverProbeReport,
            systemDevices: systemDevices,
            runningApplications: runningApplications,
            processTapCapability: processTapCapability,
            processTapDiagnostics: processTapDiagnostics,
            microphonePermissionStatus: microphonePermissionStatus,
            helperServiceReport: helperServiceReport,
            halPublicationReport: lastHALPublicationReport,
            halRealtimeSafetyReport: halRealtimeSafetyReport,
            halAudioTransportHealthReports: Array(halAudioTransportHealthReports.values)
        )
    }

    public func apply(graph: RoutingGraph) async {
        activeGraph = graph
        let report = runtimeRoutingEngine.render(
            graph: graph,
            captureSessions: captureSessions,
            hardwareCaptureSessions: hardwareCaptureSessions,
            frameCount: 512
        )
        lastRenderReport = report
        publishToHAL(renderReport: report, graph: graph)
        monitorStates = monitorOutputEngine.process(graph: graph, renderReport: report)
        syncMonitorPlaybackSessions(with: graph)
    }

    public func monitorState(for monitorID: UUID) -> MonitorOutputState? {
        monitorStates[monitorID] ?? monitorOutputEngine.state(for: monitorID)
    }

    public func outputChannelPeaks(for deviceID: UUID) -> [Int: Float] {
        lastRenderReport?.renders.first { $0.deviceID == deviceID }?.result.report.peakByOutputChannel ?? [:]
    }

    public func sourcePeak(for sourceID: UUID, in deviceID: UUID) -> Float {
        lastRenderReport?.renders.first { $0.deviceID == deviceID }?.result.report.peakBySourceID[sourceID] ?? 0
    }

    public func routePeak(for routeID: UUID, in deviceID: UUID) -> Float {
        lastRenderReport?.renders.first { $0.deviceID == deviceID }?.result.report.peakByRouteID[routeID] ?? 0
    }

    public func monitorPlaybackState(for monitorID: UUID) -> MonitorPlaybackState {
        monitorPlaybackStates[monitorID] ?? MonitorPlaybackState(
            monitorID: monitorID,
            phase: .idle,
            status: "Not playing",
            renderedFrameCount: 0
        )
    }

    public func startMonitorPlayback(monitor: Monitor) {
        guard let session = monitorOutputEngine.session(for: monitor.id) else {
            monitorPlaybackStates[monitor.id] = MonitorPlaybackState(
                monitorID: monitor.id,
                phase: .failed,
                status: MonitorPlaybackError.monitorSessionUnavailable(monitor.id).description,
                renderedFrameCount: 0
            )
            return
        }

        do {
            let playbackSession = monitorPlaybackSessions[monitor.id] ?? HardwareMonitorPlaybackSession(
                monitor: monitor,
                monitorSession: session
            )
            monitorPlaybackSessions[monitor.id] = playbackSession
            try playbackSession.start()
            monitorPlaybackStates[monitor.id] = playbackSession.state()
        } catch {
            monitorPlaybackStates[monitor.id] = MonitorPlaybackState(
                monitorID: monitor.id,
                phase: .failed,
                status: String(describing: error),
                renderedFrameCount: monitorPlaybackStates[monitor.id]?.renderedFrameCount ?? 0
            )
        }
    }

    public func stopMonitorPlayback(monitorID: UUID) {
        guard let session = monitorPlaybackSessions[monitorID] else {
            monitorPlaybackStates[monitorID] = MonitorPlaybackState(
                monitorID: monitorID,
                phase: .idle,
                status: "Not playing",
                renderedFrameCount: 0
            )
            return
        }

        session.stop()
        monitorPlaybackStates[monitorID] = session.state()
    }

    public func captureState(for sourceID: UUID) -> SourceCaptureState {
        captureStates[sourceID] ?? SourceCaptureState(
            sourceID: sourceID,
            phase: .idle,
            status: "Not prepared",
            availableFrameCount: 0,
            droppedFrameCount: 0,
            peak: 0
        )
    }

    public func prepareApplicationCapture(source: AudioSource) {
        guard source.kind == .application else {
            setCaptureState(sourceID: source.id, phase: .failed, status: "Only application sources can use process taps.")
            return
        }

        let processIdentifiers = processIdentifiers(for: source)
        guard !processIdentifiers.isEmpty else {
            setCaptureState(sourceID: source.id, phase: .failed, status: "No running application matches this source.")
            return
        }

        do {
            let session = applicationCaptureSession(source: source, processIdentifiers: processIdentifiers)
            captureSessions[source.id] = session
            let state = try session.prepare()
            updateCaptureState(
                sourceID: source.id,
                phase: .prepared,
                status: "Prepared tap \(state.tapID) for \(processIdentifiers.count) process(es)"
            )
        } catch {
            setCaptureState(sourceID: source.id, phase: .failed, status: String(describing: error))
        }
    }

    public func startApplicationCapture(source: AudioSource) {
        guard source.kind == .application else {
            setCaptureState(sourceID: source.id, phase: .failed, status: "Only application sources can use process taps.")
            return
        }

        let processIdentifiers = processIdentifiers(for: source)
        guard !processIdentifiers.isEmpty else {
            setCaptureState(sourceID: source.id, phase: .failed, status: "No running application matches this source.")
            return
        }

        do {
            let session = applicationCaptureSession(source: source, processIdentifiers: processIdentifiers)
            captureSessions[source.id] = session
            let state = try session.start()
            updateCaptureState(
                sourceID: source.id,
                phase: .running,
                status: "Capturing aggregate \(state.aggregateDeviceID) from \(processIdentifiers.count) process(es)"
            )
        } catch {
            setCaptureState(sourceID: source.id, phase: .failed, status: String(describing: error))
        }
    }

    public func prepareHardwareInputCapture(source: AudioSource) {
        guard source.kind == .hardwareInput else {
            setCaptureState(sourceID: source.id, phase: .failed, status: "Only hardware input sources can use device capture.")
            return
        }

        guard let device = hardwareInputDevice(for: source) else {
            setCaptureState(sourceID: source.id, phase: .failed, status: "No input device matches this source.")
            return
        }

        do {
            let session = hardwareCaptureSessions[source.id] ?? HardwareInputCaptureSession(configuration: HardwareInputCaptureConfiguration(
                sourceID: source.id,
                deviceID: device.audioObjectID,
                name: source.name,
                channelCount: max(1, source.channels.count)
            ))
            hardwareCaptureSessions[source.id] = session
            let state = try session.prepare()
            updateCaptureState(sourceID: source.id, phase: .prepared, status: "Prepared input device \(state.deviceID)")
        } catch {
            setCaptureState(sourceID: source.id, phase: .failed, status: String(describing: error))
        }
    }

    public func startHardwareInputCapture(source: AudioSource) {
        guard source.kind == .hardwareInput else {
            setCaptureState(sourceID: source.id, phase: .failed, status: "Only hardware input sources can use device capture.")
            return
        }

        guard let device = hardwareInputDevice(for: source) else {
            setCaptureState(sourceID: source.id, phase: .failed, status: "No input device matches this source.")
            return
        }

        do {
            let session = hardwareCaptureSessions[source.id] ?? HardwareInputCaptureSession(configuration: HardwareInputCaptureConfiguration(
                sourceID: source.id,
                deviceID: device.audioObjectID,
                name: source.name,
                channelCount: max(1, source.channels.count)
            ))
            hardwareCaptureSessions[source.id] = session
            let state = try session.start()
            updateCaptureState(sourceID: source.id, phase: .running, status: "Capturing input device \(state.deviceID)")
        } catch {
            setCaptureState(sourceID: source.id, phase: .failed, status: String(describing: error))
        }
    }

    public func stopCapture(sourceID: UUID) {
        if let session = captureSessions[sourceID] {
            do {
                try session.stop()
                updateCaptureState(sourceID: sourceID, phase: .prepared, status: "Stopped")
            } catch {
                setCaptureState(sourceID: sourceID, phase: .failed, status: String(describing: error))
            }
            return
        }

        if let session = hardwareCaptureSessions[sourceID] {
            do {
                try session.stop()
                updateCaptureState(sourceID: sourceID, phase: .prepared, status: "Stopped")
            } catch {
                setCaptureState(sourceID: sourceID, phase: .failed, status: String(describing: error))
            }
            return
        }

        if captureStates[sourceID] == nil {
            setCaptureState(sourceID: sourceID, phase: .idle, status: "Not prepared")
            return
        }
    }

    public func tearDownCapture(sourceID: UUID) {
        if let session = captureSessions[sourceID] {
            do {
                try session.tearDown()
                captureSessions.removeValue(forKey: sourceID)
                setCaptureState(sourceID: sourceID, phase: .idle, status: "Released")
            } catch {
                setCaptureState(sourceID: sourceID, phase: .failed, status: String(describing: error))
            }
            return
        }

        if let session = hardwareCaptureSessions[sourceID] {
            do {
                try session.tearDown()
                hardwareCaptureSessions.removeValue(forKey: sourceID)
                setCaptureState(sourceID: sourceID, phase: .idle, status: "Released")
            } catch {
                setCaptureState(sourceID: sourceID, phase: .failed, status: String(describing: error))
            }
            return
        }

        if captureStates[sourceID] == nil {
            captureStates.removeValue(forKey: sourceID)
            return
        }
    }

    public func refreshCaptureMeters() {
        for (sourceID, session) in captureSessions {
            let snapshot = session.ringBuffer.snapshot()
            let buffer = session.read(frameCount: min(512, max(0, snapshot.availableFrameCount)))
            let peak = LevelMeter.measure(buffer).map(\.peak).max() ?? 0
            var state = captureState(for: sourceID)
            state.availableFrameCount = session.ringBuffer.snapshot().availableFrameCount
            state.droppedFrameCount = session.ringBuffer.snapshot().droppedFrameCount
            state.peak = peak
            captureStates[sourceID] = state
        }

        for (sourceID, session) in hardwareCaptureSessions {
            let snapshot = session.ringBuffer.snapshot()
            let buffer = session.read(frameCount: min(512, max(0, snapshot.availableFrameCount)))
            let peak = LevelMeter.measure(buffer).map(\.peak).max() ?? 0
            var state = captureState(for: sourceID)
            state.availableFrameCount = session.ringBuffer.snapshot().availableFrameCount
            state.droppedFrameCount = session.ringBuffer.snapshot().droppedFrameCount
            state.peak = peak
            captureStates[sourceID] = state
        }

        if let activeGraph {
            let report = runtimeRoutingEngine.render(
                graph: activeGraph,
                captureSessions: captureSessions,
                hardwareCaptureSessions: hardwareCaptureSessions,
                frameCount: 512
            )
            lastRenderReport = report
            publishToHAL(renderReport: report, graph: activeGraph)
            monitorStates = monitorOutputEngine.process(graph: activeGraph, renderReport: report)
            syncMonitorPlaybackSessions(with: activeGraph)
            for (monitorID, session) in monitorPlaybackSessions {
                monitorPlaybackStates[monitorID] = session.state()
            }
        }
    }

    private func publishToHAL(renderReport: RuntimeRenderReport, graph: RoutingGraph) {
        do {
            lastHALPublicationReport = try HALRenderPublisher.publishToSharedMemory(
                renderReport: renderReport,
                graph: graph,
                sharedMemoryName: defaultHALAudioSharedMemoryName
            )
            updateHALAudioTransportHealth(from: lastHALPublicationReport)
            let publicationReady = lastHALPublicationReport?.failedWriteCount == 0 &&
                lastHALPublicationReport?.didPublishSharedMemory == true
            if publicationReady {
                halRealtimeSafetyReport = HALRealtimeSafetyProbe.currentReport()
                refreshDriverProbe()
            } else {
                halRealtimeSafetyReport = HALRealtimeSafetyProbe.currentReport()
                driverStatus = .error
                refreshReadiness()
            }
        } catch {
            lastHALPublicationReport = nil
            halAudioTransportHealthReports = [:]
            halRealtimeSafetyReport = HALRealtimeSafetyProbe.currentReport()
            driverStatus = .error
            refreshReadiness()
        }
    }

    private func updateHALAudioTransportHealth(from publicationReport: HALRenderPublicationReport?) {
        guard let publicationReport else {
            halAudioTransportHealthReports = [:]
            return
        }

        var nextReports: [UInt32: HALAudioTransportHealthReport] = [:]
        for publication in publicationReport.publications {
            let previous = previousHALAudioSnapshots[publication.deviceObjectID]
            nextReports[publication.deviceObjectID] = HALAudioBufferBridge.healthReport(
                previous: previous,
                current: publication.snapshot
            )
            previousHALAudioSnapshots[publication.deviceObjectID] = publication.snapshot
        }
        halAudioTransportHealthReports = nextReports
    }

    private func processIdentifiers(for source: AudioSource) -> [pid_t] {
        guard let sourceIdentifier = source.sourceIdentifier else {
            return []
        }

        let directPIDs = captureCandidateProcesses.filter { application in
            application.id == sourceIdentifier || application.bundleIdentifier == sourceIdentifier
        }.map(\.processIdentifier)
        if !directPIDs.isEmpty {
            return directPIDs
        }

        guard sourceIdentifier.hasPrefix("special:") else {
            return []
        }

        let specialID = String(sourceIdentifier.dropFirst("special:".count))
        guard let specialSource = SpecialApplicationSource.defaults.first(where: { $0.id == specialID }) else {
            return []
        }
        let identifiers = Set(specialSource.capturedIdentifiers)

        return captureCandidateProcesses.filter { application in
            identifiers.contains(application.bundleIdentifier ?? "") ||
                identifiers.contains(application.id)
        }.map(\.processIdentifier)
    }

    private func applicationCaptureSession(
        source: AudioSource,
        processIdentifiers: [pid_t]
    ) -> ProcessTapCaptureSession {
        let configuration = ProcessTapCaptureConfiguration(
            applicationSource: source,
            processIdentifiers: processIdentifiers
        )

        guard let existing = captureSessions[source.id],
              existing.configuration == configuration else {
            if let existing = captureSessions[source.id] {
                try? existing.tearDown()
            }
            let session = ProcessTapCaptureSession(configuration: configuration)
            captureSessions[source.id] = session
            return session
        }

        return existing
    }

    private func hardwareInputDevice(for source: AudioSource) -> SystemAudioDevice? {
        guard let sourceIdentifier = source.sourceIdentifier else {
            return nil
        }

        return systemDevices.first { device in
            guard device.direction == .input || device.direction == .duplex else {
                return false
            }

            return device.uid == sourceIdentifier ||
                device.id == sourceIdentifier ||
                String(device.audioObjectID) == sourceIdentifier
        }
    }

    private func syncMonitorPlaybackSessions(with graph: RoutingGraph) {
        let activeMonitors = Dictionary(
            uniqueKeysWithValues: graph.devices.flatMap { device in
                device.monitors.map { monitor in (monitor.id, monitor) }
            }
        )

        for (monitorID, session) in monitorPlaybackSessions {
            guard let monitor = activeMonitors[monitorID], monitor.isEnabled else {
                session.stop()
                monitorPlaybackSessions.removeValue(forKey: monitorID)
                monitorPlaybackStates[monitorID] = MonitorPlaybackState(
                    monitorID: monitorID,
                    phase: .idle,
                    status: "Not playing",
                    renderedFrameCount: 0
                )
                continue
            }
        }
    }

    private func updateCaptureState(sourceID: UUID, phase: SourceCapturePhase, status: String) {
        let snapshot = captureSessions[sourceID]?.ringBuffer.snapshot()
        captureStates[sourceID] = SourceCaptureState(
            sourceID: sourceID,
            phase: phase,
            status: status,
            availableFrameCount: snapshot?.availableFrameCount ?? 0,
            droppedFrameCount: snapshot?.droppedFrameCount ?? 0,
            peak: captureStates[sourceID]?.peak ?? 0
        )
    }

    private func setCaptureState(sourceID: UUID, phase: SourceCapturePhase, status: String) {
        captureStates[sourceID] = SourceCaptureState(
            sourceID: sourceID,
            phase: phase,
            status: status,
            availableFrameCount: captureStates[sourceID]?.availableFrameCount ?? 0,
            droppedFrameCount: captureStates[sourceID]?.droppedFrameCount ?? 0,
            peak: captureStates[sourceID]?.peak ?? 0
        )
    }
}

private let defaultHALAudioSharedMemoryName = "/HeartechoHALAudioBuffers"

public enum SourceCapturePhase: String, Hashable, Sendable {
    case idle = "Idle"
    case prepared = "Prepared"
    case running = "Running"
    case failed = "Failed"
}

public struct SourceCaptureState: Identifiable, Hashable, Sendable {
    public var id: UUID {
        sourceID
    }

    public var sourceID: UUID
    public var phase: SourceCapturePhase
    public var status: String
    public var availableFrameCount: Int
    public var droppedFrameCount: Int
    public var peak: Float

    public init(
        sourceID: UUID,
        phase: SourceCapturePhase,
        status: String,
        availableFrameCount: Int,
        droppedFrameCount: Int,
        peak: Float
    ) {
        self.sourceID = sourceID
        self.phase = phase
        self.status = status
        self.availableFrameCount = availableFrameCount
        self.droppedFrameCount = droppedFrameCount
        self.peak = peak
    }
}

public struct ProcessTapProcessDiagnostic: Identifiable, Hashable, Sendable {
    public var id: String {
        applicationID
    }

    public var applicationID: String
    public var processIdentifier: pid_t
    public var name: String
    public var processObjectID: AudioObjectID?
    public var isRunningOutput: Bool

    public init(
        applicationID: String,
        processIdentifier: pid_t,
        name: String,
        processObjectID: AudioObjectID?,
        isRunningOutput: Bool
    ) {
        self.applicationID = applicationID
        self.processIdentifier = processIdentifier
        self.name = name
        self.processObjectID = processObjectID
        self.isRunningOutput = isRunningOutput
    }
}

public enum DriverStatus: String, Sendable {
    case notInstalled = "Driver not installed"
    case builtNotInstalled = "Driver built, not installed"
    case notVisible = "Driver installed, not visible"
    case configurationReady = "Configuration ready"
    case running = "Driver running"
    case error = "Driver error"
}
