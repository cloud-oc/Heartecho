import Foundation
import HeartechoCore

public struct RuntimeDeviceRender: Hashable, Sendable {
    public var deviceID: UUID
    public var deviceName: String
    public var result: MixResult
    public var sourceFrameAvailability: [UUID: Int]
    public var capturedSourceIDs: Set<UUID>
    public var resamplingReports: [AudioResamplingReport]

    public init(
        deviceID: UUID,
        deviceName: String,
        result: MixResult,
        sourceFrameAvailability: [UUID: Int],
        capturedSourceIDs: Set<UUID>,
        resamplingReports: [AudioResamplingReport] = []
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.result = result
        self.sourceFrameAvailability = sourceFrameAvailability
        self.capturedSourceIDs = capturedSourceIDs
        self.resamplingReports = resamplingReports
    }
}

public struct RuntimeRenderReport: Hashable, Sendable {
    public var renders: [RuntimeDeviceRender]

    public init(renders: [RuntimeDeviceRender]) {
        self.renders = renders
    }

    public var totalActiveRouteCount: Int {
        renders.reduce(0) { $0 + $1.result.report.activeRouteCount }
    }

    public var totalMissingSourceRouteCount: Int {
        renders.reduce(0) { $0 + $1.result.report.missingSourceRouteCount }
    }

    public var totalResampledSourceCount: Int {
        renders.reduce(0) { $0 + $1.resamplingReports.count }
    }
}

public struct RuntimeRoutingEngine: Sendable {
    private let resamplingStateStore: RuntimeResamplingStateStore

    public init() {
        self.resamplingStateStore = RuntimeResamplingStateStore()
    }

    public func render(
        graph: RoutingGraph,
        captureSessions: [UUID: ProcessTapCaptureSession],
        hardwareCaptureSessions: [UUID: HardwareInputCaptureSession] = [:],
        injectedBuffers: [UUID: SourceAudioBuffer] = [:],
        frameCount: Int
    ) -> RuntimeRenderReport {
        var cache: [UUID: RuntimeDeviceRender] = [:]
        var renders: [RuntimeDeviceRender] = []

        for device in graph.devices {
            let render = renderDevice(
                device: device,
                graph: graph,
                captureSessions: captureSessions,
                hardwareCaptureSessions: hardwareCaptureSessions,
                injectedBuffers: injectedBuffers,
                frameCount: frameCount,
                visiting: [],
                cache: &cache
            )
            renders.append(render)
        }

        return RuntimeRenderReport(renders: renders)
    }

    public func render(
        device: VirtualAudioDevice,
        captureSessions: [UUID: ProcessTapCaptureSession],
        hardwareCaptureSessions: [UUID: HardwareInputCaptureSession] = [:],
        injectedBuffers: [UUID: SourceAudioBuffer] = [:],
        frameCount: Int
    ) -> RuntimeDeviceRender {
        var cache: [UUID: RuntimeDeviceRender] = [:]
        return renderDevice(
            device: device,
            graph: RoutingGraph(devices: [device], selectedDeviceID: device.id),
            captureSessions: captureSessions,
            hardwareCaptureSessions: hardwareCaptureSessions,
            injectedBuffers: injectedBuffers,
            frameCount: frameCount,
            visiting: [],
            cache: &cache
        )
    }

    private func renderDevice(
        device: VirtualAudioDevice,
        graph: RoutingGraph,
        captureSessions: [UUID: ProcessTapCaptureSession],
        hardwareCaptureSessions: [UUID: HardwareInputCaptureSession],
        injectedBuffers: [UUID: SourceAudioBuffer],
        frameCount: Int,
        visiting: Set<UUID>,
        cache: inout [UUID: RuntimeDeviceRender]
    ) -> RuntimeDeviceRender {
        if let cached = cache[device.id] {
            return cached
        }

        if visiting.contains(device.id) {
            return emptyRender(device: device, frameCount: frameCount)
        }

        var sourceBuffers = injectedBuffers
        var availability: [UUID: Int] = [:]
        var capturedSourceIDs = Set<UUID>()
        var driftCorrectableSourceIDs = Set<UUID>()
        var nextVisiting = visiting
        nextVisiting.insert(device.id)

        for source in device.sources {
            if let injected = injectedBuffers[source.id] {
                availability[source.id] = injected.frameCount
                if injected.sampleRate != nil {
                    driftCorrectableSourceIDs.insert(source.id)
                }
                continue
            }

            switch source.kind {
            case .application:
                guard let session = captureSessions[source.id] else {
                    continue
                }

                let snapshot = session.ringBuffer.snapshot()
                availability[source.id] = snapshot.availableFrameCount
                sourceBuffers[source.id] = session.read(frameCount: frameCount)
                capturedSourceIDs.insert(source.id)
                driftCorrectableSourceIDs.insert(source.id)
            case .hardwareInput:
                guard let session = hardwareCaptureSessions[source.id] else {
                    continue
                }

                let snapshot = session.ringBuffer.snapshot()
                availability[source.id] = snapshot.availableFrameCount
                sourceBuffers[source.id] = session.read(frameCount: frameCount)
                capturedSourceIDs.insert(source.id)
                driftCorrectableSourceIDs.insert(source.id)
            case .virtualDevice:
                guard let sourceIdentifier = source.sourceIdentifier,
                      let sourceDeviceID = UUID(uuidString: sourceIdentifier),
                      let nestedDevice = graph.devices.first(where: { $0.id == sourceDeviceID }) else {
                    continue
                }

                let nestedRender = renderDevice(
                    device: nestedDevice,
                    graph: graph,
                    captureSessions: captureSessions,
                    hardwareCaptureSessions: hardwareCaptureSessions,
                    injectedBuffers: injectedBuffers,
                    frameCount: frameCount,
                    visiting: nextVisiting,
                    cache: &cache
                )
                sourceBuffers[source.id] = SourceAudioBuffer(
                    sourceID: source.id,
                    channels: nestedRender.result.buffer.channels,
                    sampleRate: nestedDevice.sampleRate
                )
                availability[source.id] = nestedRender.result.report.frameCount
                capturedSourceIDs.insert(source.id)
            case .passThru:
                continue
            }
        }

        var resamplingReports: [AudioResamplingReport] = []
        for (sourceID, buffer) in sourceBuffers {
            let driftCorrection = driftCorrectableSourceIDs.contains(sourceID)
                ? AudioDriftController.correction(
                    availableFrameCount: availability[sourceID],
                    targetBufferedFrameCount: max(1, frameCount * 2)
                )
                : nil
            var resamplingState = resamplingStateStore.state(deviceID: device.id, sourceID: sourceID)
            let conversion = AudioSampleRateConverter.convert(
                buffer,
                targetSampleRate: device.sampleRate,
                targetFrameCount: frameCount,
                driftCorrection: driftCorrection,
                state: &resamplingState
            )
            resamplingStateStore.update(resamplingState, deviceID: device.id, sourceID: sourceID)
            sourceBuffers[sourceID] = conversion.buffer

            if let report = conversion.report {
                resamplingReports.append(report)
                availability[sourceID] = report.inputFrameCount
            }
        }

        let result = RoutingMixer.mix(
            device: device,
            sourceBuffers: sourceBuffers,
            frameCount: frameCount
        )

        let render = RuntimeDeviceRender(
            deviceID: device.id,
            deviceName: device.name,
            result: result,
            sourceFrameAvailability: availability,
            capturedSourceIDs: capturedSourceIDs,
            resamplingReports: resamplingReports
        )
        cache[device.id] = render
        return render
    }

    private func emptyRender(device: VirtualAudioDevice, frameCount: Int) -> RuntimeDeviceRender {
        let result = MixResult(
            buffer: MixedAudioBuffer(
                channels: Array(
                    repeating: Array(repeating: 0, count: max(0, frameCount)),
                    count: device.outputChannels.count
                )
            ),
            report: MixReport(
                outputChannelCount: device.outputChannels.count,
                frameCount: max(0, frameCount),
                activeRouteCount: 0,
                missingSourceRouteCount: device.routes.count,
                peakByOutputChannel: Dictionary(
                    uniqueKeysWithValues: device.outputChannels.map { ($0.index, Float(0)) }
                )
            )
        )

        return RuntimeDeviceRender(
            deviceID: device.id,
            deviceName: device.name,
            result: result,
            sourceFrameAvailability: [:],
            capturedSourceIDs: [],
            resamplingReports: []
        )
    }
}

private final class RuntimeResamplingStateStore: @unchecked Sendable {
    private var states: [RuntimeResamplingStateKey: AudioResamplingState] = [:]
    private let lock = NSLock()

    func state(deviceID: UUID, sourceID: UUID) -> AudioResamplingState {
        lock.lock()
        defer {
            lock.unlock()
        }

        return states[RuntimeResamplingStateKey(deviceID: deviceID, sourceID: sourceID)] ?? AudioResamplingState()
    }

    func update(_ state: AudioResamplingState, deviceID: UUID, sourceID: UUID) {
        lock.lock()
        defer {
            lock.unlock()
        }

        states[RuntimeResamplingStateKey(deviceID: deviceID, sourceID: sourceID)] = state
    }
}

private struct RuntimeResamplingStateKey: Hashable {
    var deviceID: UUID
    var sourceID: UUID
}
