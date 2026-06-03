import AVFoundation
import Foundation

public enum AudioReadinessState: String, Hashable, Sendable {
    case ready = "Ready"
    case warning = "Needs Attention"
    case blocked = "Blocked"
    case unknown = "Unknown"
}

public enum AudioReadinessItemKind: String, Hashable, Sendable {
    case halDriverBuildArtifact
    case halDriverInstallation
    case virtualDeviceVisibility
    case systemAudioAccess
    case microphonePermission
    case applicationCapture
    case hardwareInputCapture
    case monitorOutputDevices
    case helperService
    case halAudioTransport
}

public struct AudioReadinessItem: Identifiable, Hashable, Sendable {
    public var id: String { kind.rawValue }

    public var kind: AudioReadinessItemKind
    public var title: String
    public var state: AudioReadinessState
    public var isRequired: Bool
    public var summary: String
    public var detail: String
    public var recommendedAction: String?

    public init(
        kind: AudioReadinessItemKind,
        title: String,
        state: AudioReadinessState,
        isRequired: Bool,
        summary: String,
        detail: String,
        recommendedAction: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.state = state
        self.isRequired = isRequired
        self.summary = summary
        self.detail = detail
        self.recommendedAction = recommendedAction
    }
}

public struct AudioReadinessReport: Hashable, Sendable {
    public var generatedAt: Date
    public var items: [AudioReadinessItem]

    public init(generatedAt: Date = Date(), items: [AudioReadinessItem]) {
        self.generatedAt = generatedAt
        self.items = items
    }

    public static var empty: AudioReadinessReport {
        AudioReadinessReport(items: [])
    }

    public var requiredItems: [AudioReadinessItem] {
        items.filter(\.isRequired)
    }

    public var requiredIssueItems: [AudioReadinessItem] {
        requiredItems.filter { $0.state != .ready }
    }

    public var warningItems: [AudioReadinessItem] {
        items.filter { $0.state == .warning || $0.state == .unknown }
    }

    public var blockedItems: [AudioReadinessItem] {
        items.filter { $0.state == .blocked }
    }

    public var overallState: AudioReadinessState {
        if requiredItems.contains(where: { $0.state == .blocked }) {
            return .blocked
        }

        if requiredItems.contains(where: { $0.state == .warning || $0.state == .unknown }) {
            return .warning
        }

        if requiredItems.isEmpty {
            return .unknown
        }

        return .ready
    }

    public var summary: String {
        switch overallState {
        case .ready:
            return "All required audio prerequisites are ready."
        case .warning:
            return "\(requiredIssueItems.count) required prerequisite(s) need attention."
        case .blocked:
            return "\(blockedItems.filter(\.isRequired).count) required prerequisite(s) are blocked."
        case .unknown:
            return "Audio readiness has not been checked yet."
        }
    }

    public func item(kind: AudioReadinessItemKind) -> AudioReadinessItem? {
        items.first { $0.kind == kind }
    }
}

public enum MicrophonePermissionState: String, Hashable, Sendable {
    case authorized = "Authorized"
    case denied = "Denied"
    case restricted = "Restricted"
    case notDetermined = "Not Determined"
    case unknown = "Unknown"
}

public enum MicrophonePermissionProbe {
    public static func currentStatus() -> MicrophonePermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unknown
        }
    }

    public static func requestAccess() async -> MicrophonePermissionState {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                continuation.resume(returning: currentStatus())
            }
        }
    }
}

public enum AudioReadinessReporter {
    public static func makeReport(
        driverProbeReport: HALDriverProbeReport?,
        systemDevices: [SystemAudioDevice],
        runningApplications: [RunningApplicationSource],
        processTapCapability: ProcessTapCapability,
        processTapDiagnostics: [ProcessTapProcessDiagnostic],
        microphonePermissionStatus: MicrophonePermissionState,
        helperServiceReport: HelperServiceProbeReport?,
        halPublicationReport: HALRenderPublicationReport?,
        halRealtimeSafetyReport: HALRealtimeSafetyReport? = nil,
        halAudioTransportHealthReports: [HALAudioTransportHealthReport] = []
    ) -> AudioReadinessReport {
        let inputDevices = systemDevices.filter { $0.direction == .input || $0.direction == .duplex }
        let outputDevices = systemDevices.filter { $0.direction == .output || $0.direction == .duplex }
        let processObjectCount = processTapDiagnostics.filter { $0.processObjectID != nil }.count

        return AudioReadinessReport(items: [
            halDriverBuildArtifactItem(driverProbeReport: driverProbeReport),
            halDriverInstallationItem(driverProbeReport: driverProbeReport),
            virtualDeviceVisibilityItem(driverProbeReport: driverProbeReport),
            systemAudioAccessItem(
                processTapCapability: processTapCapability,
                processObjectCount: processObjectCount
            ),
            microphonePermissionItem(status: microphonePermissionStatus),
            applicationCaptureItem(
                runningApplicationCount: runningApplications.count,
                processObjectCount: processObjectCount,
                processTapCapability: processTapCapability
            ),
            hardwareInputCaptureItem(
                inputDeviceCount: inputDevices.count,
                microphonePermissionStatus: microphonePermissionStatus
            ),
            monitorOutputDevicesItem(outputDeviceCount: outputDevices.count),
            helperServiceItem(report: helperServiceReport),
            halAudioTransportItem(
                halPublicationReport: halPublicationReport,
                halRealtimeSafetyReport: halRealtimeSafetyReport,
                halAudioTransportHealthReports: halAudioTransportHealthReports
            )
        ])
    }

    private static func halDriverBuildArtifactItem(driverProbeReport: HALDriverProbeReport?) -> AudioReadinessItem {
        guard let buildArtifact = driverProbeReport?.buildArtifact else {
            return AudioReadinessItem(
                kind: .halDriverBuildArtifact,
                title: "Driver Build",
                state: .unknown,
                isRequired: false,
                summary: "Local driver bundle has not been checked.",
                detail: "The HAL bundle artifact is used before signing and installation.",
                recommendedAction: "Run the HAL bundle verifier."
            )
        }

        if buildArtifact.isStructurallyValid {
            return AudioReadinessItem(
                kind: .halDriverBuildArtifact,
                title: "Driver Build",
                state: buildArtifact.isSignatureValid ? .ready : .warning,
                isRequired: false,
                summary: buildArtifact.isSignatureValid ? "Local driver bundle is built and signed." : "Local driver bundle is built but unsigned.",
                detail: buildArtifact.url.path,
                recommendedAction: buildArtifact.isSignatureValid ? nil : "Sign the bundle before installing it for production use."
            )
        }

        return AudioReadinessItem(
            kind: .halDriverBuildArtifact,
            title: "Driver Build",
            state: buildArtifact.exists ? .warning : .unknown,
            isRequired: false,
            summary: buildArtifact.exists ? "Local driver bundle is incomplete." : "No local driver bundle has been built.",
            detail: buildArtifact.url.path,
            recommendedAction: "Run scripts/build-hal-bundle.sh debug."
        )
    }

    private static func halDriverInstallationItem(driverProbeReport: HALDriverProbeReport?) -> AudioReadinessItem {
        guard let driverProbeReport else {
            return AudioReadinessItem(
                kind: .halDriverInstallation,
                title: "HAL Driver",
                state: .unknown,
                isRequired: true,
                summary: "Installed driver has not been checked.",
                detail: "System-wide virtual devices require an installed Core Audio HAL driver.",
                recommendedAction: "Refresh audio readiness."
            )
        }

        if driverProbeReport.hasValidInstalledBundle {
            return AudioReadinessItem(
                kind: .halDriverInstallation,
                title: "HAL Driver",
                state: .ready,
                isRequired: true,
                summary: "A structurally valid signed driver is installed.",
                detail: "\(driverProbeReport.installedBundles.count) installed bundle(s) found."
            )
        }

        if driverProbeReport.hasInstalledBundle {
            return AudioReadinessItem(
                kind: .halDriverInstallation,
                title: "HAL Driver",
                state: .blocked,
                isRequired: true,
                summary: "Installed driver is unsigned or structurally invalid.",
                detail: "\(driverProbeReport.installedBundles.count) installed bundle(s) found.",
                recommendedAction: "Sign and reinstall the HAL bundle."
            )
        }

        return AudioReadinessItem(
            kind: .halDriverInstallation,
            title: "HAL Driver",
            state: .blocked,
            isRequired: true,
            summary: "No HAL driver is installed.",
            detail: "The app can edit routing graphs, but macOS apps cannot see virtual devices until the driver is installed.",
            recommendedAction: "Build, sign, and install Heartecho.driver."
        )
    }

    private static func virtualDeviceVisibilityItem(driverProbeReport: HALDriverProbeReport?) -> AudioReadinessItem {
        guard let driverProbeReport else {
            return AudioReadinessItem(
                kind: .virtualDeviceVisibility,
                title: "Virtual Devices",
                state: .unknown,
                isRequired: true,
                summary: "Virtual device visibility has not been checked.",
                detail: "Enabled devices should appear in Core Audio after the HAL driver loads.",
                recommendedAction: "Refresh audio readiness."
            )
        }

        if driverProbeReport.deviceProbe.isVisible {
            return AudioReadinessItem(
                kind: .virtualDeviceVisibility,
                title: "Virtual Devices",
                state: .ready,
                isRequired: true,
                summary: "\(driverProbeReport.deviceProbe.matchingDevices.count) virtual device(s) visible to Core Audio.",
                detail: "Matching UID prefix: \(driverProbeReport.deviceProbe.expectedUIDPrefix)"
            )
        }

        return AudioReadinessItem(
            kind: .virtualDeviceVisibility,
            title: "Virtual Devices",
            state: driverProbeReport.hasInstalledBundle ? .warning : .blocked,
            isRequired: true,
            summary: "No Heartecho virtual devices are visible to Core Audio.",
            detail: "Matching UID prefix: \(driverProbeReport.deviceProbe.expectedUIDPrefix)",
            recommendedAction: driverProbeReport.hasInstalledBundle ? "Reload Core Audio after installing a signed driver." : "Install the HAL driver first."
        )
    }

    private static func systemAudioAccessItem(
        processTapCapability: ProcessTapCapability,
        processObjectCount: Int
    ) -> AudioReadinessItem {
        guard processTapCapability.isSupported else {
            return AudioReadinessItem(
                kind: .systemAudioAccess,
                title: "System Audio",
                state: .blocked,
                isRequired: true,
                summary: "Process taps are unavailable.",
                detail: processTapCapability.reason,
                recommendedAction: "Run on macOS 14.2 or newer."
            )
        }

        if processObjectCount > 0 {
            return AudioReadinessItem(
                kind: .systemAudioAccess,
                title: "System Audio",
                state: .ready,
                isRequired: true,
                summary: "\(processObjectCount) running app(s) can be mapped to Core Audio process objects.",
                detail: processTapCapability.reason
            )
        }

        return AudioReadinessItem(
            kind: .systemAudioAccess,
            title: "System Audio",
            state: .warning,
            isRequired: true,
            summary: "Process taps are supported, but no running app is currently mappable.",
            detail: processTapCapability.reason,
            recommendedAction: "Refresh while an audio-producing app is running."
        )
    }

    private static func microphonePermissionItem(status: MicrophonePermissionState) -> AudioReadinessItem {
        switch status {
        case .authorized:
            return AudioReadinessItem(
                kind: .microphonePermission,
                title: "Microphone",
                state: .ready,
                isRequired: true,
                summary: "Microphone access is authorized.",
                detail: "Hardware input capture can access user-approved input devices."
            )
        case .notDetermined:
            return AudioReadinessItem(
                kind: .microphonePermission,
                title: "Microphone",
                state: .warning,
                isRequired: true,
                summary: "Microphone access has not been requested.",
                detail: "Hardware input capture needs microphone permission before it can read input devices.",
                recommendedAction: "Request microphone access."
            )
        case .denied, .restricted:
            return AudioReadinessItem(
                kind: .microphonePermission,
                title: "Microphone",
                state: .blocked,
                isRequired: true,
                summary: "Microphone access is \(status.rawValue.lowercased()).",
                detail: "Hardware input sources cannot capture until macOS privacy settings allow access.",
                recommendedAction: "Enable microphone access in System Settings."
            )
        case .unknown:
            return AudioReadinessItem(
                kind: .microphonePermission,
                title: "Microphone",
                state: .unknown,
                isRequired: true,
                summary: "Microphone access status is unknown.",
                detail: "macOS returned an authorization state this build does not recognize.",
                recommendedAction: "Check System Settings privacy permissions."
            )
        }
    }

    private static func applicationCaptureItem(
        runningApplicationCount: Int,
        processObjectCount: Int,
        processTapCapability: ProcessTapCapability
    ) -> AudioReadinessItem {
        guard processTapCapability.isSupported else {
            return AudioReadinessItem(
                kind: .applicationCapture,
                title: "App Capture",
                state: .blocked,
                isRequired: true,
                summary: "Application audio capture is unavailable.",
                detail: processTapCapability.reason,
                recommendedAction: "Run on macOS 14.2 or newer."
            )
        }

        if processObjectCount > 0 {
            return AudioReadinessItem(
                kind: .applicationCapture,
                title: "App Capture",
                state: .ready,
                isRequired: true,
                summary: "\(processObjectCount) of \(runningApplicationCount) running app(s) are capture candidates.",
                detail: "Process taps can be prepared from the source cards."
            )
        }

        return AudioReadinessItem(
            kind: .applicationCapture,
            title: "App Capture",
            state: .warning,
            isRequired: true,
            summary: "No running app is currently ready for process-tap capture.",
            detail: "\(runningApplicationCount) running app(s) were discovered.",
            recommendedAction: "Launch or refresh an app that is producing audio."
        )
    }

    private static func hardwareInputCaptureItem(
        inputDeviceCount: Int,
        microphonePermissionStatus: MicrophonePermissionState
    ) -> AudioReadinessItem {
        guard inputDeviceCount > 0 else {
            return AudioReadinessItem(
                kind: .hardwareInputCapture,
                title: "Input Devices",
                state: .warning,
                isRequired: false,
                summary: "No hardware input devices are currently available.",
                detail: "Hardware input sources need at least one Core Audio input or duplex device.",
                recommendedAction: "Connect or enable an input device."
            )
        }

        let isAuthorized = microphonePermissionStatus == .authorized
        return AudioReadinessItem(
            kind: .hardwareInputCapture,
            title: "Input Devices",
            state: isAuthorized ? .ready : .warning,
            isRequired: false,
            summary: "\(inputDeviceCount) input-capable device(s) available.",
            detail: isAuthorized ? "Input devices can be prepared from source cards." : "Input devices are present, but microphone access is not fully authorized.",
            recommendedAction: isAuthorized ? nil : "Resolve microphone access before starting capture."
        )
    }

    private static func monitorOutputDevicesItem(outputDeviceCount: Int) -> AudioReadinessItem {
        guard outputDeviceCount > 0 else {
            return AudioReadinessItem(
                kind: .monitorOutputDevices,
                title: "Monitor Outputs",
                state: .warning,
                isRequired: false,
                summary: "No output devices are currently available.",
                detail: "Monitor playback needs at least one Core Audio output or duplex device.",
                recommendedAction: "Connect or enable an output device."
            )
        }

        return AudioReadinessItem(
            kind: .monitorOutputDevices,
            title: "Monitor Outputs",
            state: .ready,
            isRequired: false,
            summary: "\(outputDeviceCount) output-capable device(s) available.",
            detail: "Monitor rows can target default output or a specific Core Audio device."
        )
    }

    private static func helperServiceItem(report: HelperServiceProbeReport?) -> AudioReadinessItem {
        guard let report else {
            return AudioReadinessItem(
                kind: .helperService,
                title: "Helper Service",
                state: .unknown,
                isRequired: true,
                summary: "Helper LaunchAgent has not been checked.",
                detail: "The helper keeps HAL config and live audio shared memory refreshed.",
                recommendedAction: "Refresh audio readiness."
            )
        }

        if report.hasValidInstalledAgent {
            return AudioReadinessItem(
                kind: .helperService,
                title: "Helper Service",
                state: .ready,
                isRequired: true,
                summary: "Helper LaunchAgent is installed and structurally valid.",
                detail: report.validInstalledAgent?.url.path ?? "Installed LaunchAgent"
            )
        }

        if report.hasInstalledAgent {
            return AudioReadinessItem(
                kind: .helperService,
                title: "Helper Service",
                state: .blocked,
                isRequired: true,
                summary: "Helper LaunchAgent is installed but invalid.",
                detail: report.installedAgent?.url.path ?? "Installed LaunchAgent",
                recommendedAction: "Regenerate and reinstall the helper LaunchAgent."
            )
        }

        if report.buildArtifact?.exists == true {
            return AudioReadinessItem(
                kind: .helperService,
                title: "Helper Service",
                state: .warning,
                isRequired: true,
                summary: "Helper LaunchAgent is built but not installed.",
                detail: report.buildArtifact?.url.path ?? "Build artifact",
                recommendedAction: "Install and load the LaunchAgent after signing the helper."
            )
        }

        return AudioReadinessItem(
            kind: .helperService,
            title: "Helper Service",
            state: .blocked,
            isRequired: true,
            summary: "Helper LaunchAgent has not been generated.",
            detail: "A production Loopback-style device needs a background helper to publish config/audio to the HAL driver.",
            recommendedAction: "Run scripts/build-helper-launch-agent.sh."
        )
    }

    private static func halAudioTransportItem(
        halPublicationReport: HALRenderPublicationReport?,
        halRealtimeSafetyReport: HALRealtimeSafetyReport?,
        halAudioTransportHealthReports: [HALAudioTransportHealthReport]
    ) -> AudioReadinessItem {
        guard let halPublicationReport else {
            return AudioReadinessItem(
                kind: .halAudioTransport,
                title: "Audio Transport",
                state: .unknown,
                isRequired: true,
                summary: "No rendered audio has been published in this session.",
                detail: "The HAL driver reads rendered device audio from live shared memory.",
                recommendedAction: "Apply the current graph to publish a test render."
            )
        }

        if halRealtimeSafetyReport?.hasRenderPathRisk == true {
            return AudioReadinessItem(
                kind: .halAudioTransport,
                title: "Audio Transport",
                state: .blocked,
                isRequired: true,
                summary: "HAL realtime path risk detected.",
                detail: halRealtimeSafetyReport?.detail ?? "Realtime stats unavailable.",
                recommendedAction: "Inspect the HAL render path before relying on live audio."
            )
        }

        if let overflow = halAudioTransportHealthReports.first(where: { $0.didOverflow }) {
            return AudioReadinessItem(
                kind: .halAudioTransport,
                title: "Audio Transport",
                state: .blocked,
                isRequired: true,
                summary: "HAL audio transport overflow detected.",
                detail: overflow.detail,
                recommendedAction: "Restart the helper publication loop and inspect buffer sizing."
            )
        }

        if let staleWriter = halAudioTransportHealthReports.first(where: { $0.isWriterStale }) {
            return AudioReadinessItem(
                kind: .halAudioTransport,
                title: "Audio Transport",
                state: .warning,
                isRequired: true,
                summary: "HAL audio transport writer may be stale.",
                detail: staleWriter.detail,
                recommendedAction: "Restart or reload the helper service before relying on live audio."
            )
        }

        if halPublicationReport.failedWriteCount == 0 && halPublicationReport.didPublishSharedMemory {
            let realtimeDetail = halRealtimeSafetyReport.map { " Realtime: \($0.summary); \($0.detail)." } ?? ""
            let healthDetail = halAudioTransportHealthReports.isEmpty
                ? ""
                : " Transport: \(halAudioTransportHealthReports.map(\.summary).joined(separator: "; "))."
            return AudioReadinessItem(
                kind: .halAudioTransport,
                title: "Audio Transport",
                state: .ready,
                isRequired: true,
                summary: "\(halPublicationReport.publications.count) device buffer(s) published.",
                detail: "\(halPublicationReport.totalPublishedFrameCount) frame(s) written to \(halPublicationReport.sharedMemoryName ?? "shared memory").\(realtimeDetail)\(healthDetail)"
            )
        }

        return AudioReadinessItem(
            kind: .halAudioTransport,
            title: "Audio Transport",
            state: .blocked,
            isRequired: true,
            summary: "Live HAL audio publication failed.",
            detail: "\(halPublicationReport.failedWriteCount) failed write(s); shared memory open: \(halPublicationReport.didPublishSharedMemory).",
            recommendedAction: "Reapply the graph and inspect HAL audio shared-memory setup."
        )
    }
}
