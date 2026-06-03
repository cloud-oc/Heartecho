import Foundation
import HeartechoCore

public struct MonitorOutputState: Identifiable, Hashable, Sendable {
    public var id: UUID {
        monitorID
    }

    public var monitorID: UUID
    public var deviceID: UUID
    public var monitorName: String
    public var phase: MonitorOutputPhase
    public var status: String
    public var availableFrameCount: Int
    public var droppedFrameCount: Int
    public var peak: Float

    public init(
        monitorID: UUID,
        deviceID: UUID,
        monitorName: String,
        phase: MonitorOutputPhase,
        status: String,
        availableFrameCount: Int,
        droppedFrameCount: Int,
        peak: Float
    ) {
        self.monitorID = monitorID
        self.deviceID = deviceID
        self.monitorName = monitorName
        self.phase = phase
        self.status = status
        self.availableFrameCount = availableFrameCount
        self.droppedFrameCount = droppedFrameCount
        self.peak = peak
    }
}

public enum MonitorOutputPhase: String, Hashable, Sendable {
    case idle = "Idle"
    case receiving = "Receiving"
    case muted = "Muted"
    case disabled = "Disabled"
}

public final class MonitorOutputSession: @unchecked Sendable {
    public let monitorID: UUID
    public let deviceID: UUID
    public let monitorName: String
    public let channelCount: Int
    public let ringBuffer: AudioRingBuffer

    private let lock = NSLock()
    private var lastPeak = Float(0)
    private var phase: MonitorOutputPhase = .idle
    private var status = "No monitor audio"

    public init(
        monitorID: UUID,
        deviceID: UUID,
        monitorName: String,
        channelCount: Int,
        capacity: Int = 48_000
    ) {
        self.monitorID = monitorID
        self.deviceID = deviceID
        self.monitorName = monitorName
        self.channelCount = max(1, channelCount)
        self.ringBuffer = AudioRingBuffer(channelCount: self.channelCount, capacity: capacity)
    }

    public func receive(
        buffer: MixedAudioBuffer,
        monitor: Monitor
    ) {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard monitor.isEnabled else {
            phase = .disabled
            status = "Monitor disabled"
            lastPeak = 0
            return
        }

        guard !monitor.isMuted else {
            phase = .muted
            status = "Monitor muted"
            lastPeak = 0
            return
        }

        let scaled = Self.mappedBuffer(
            buffer: buffer,
            monitor: monitor,
            monitorID: monitorID
        )
        ringBuffer.write(scaled)
        lastPeak = LevelMeter.measure(scaled).map(\.peak).max() ?? 0
        phase = .receiving
        status = "Receiving \(scaled.channels.count) monitor channels"
    }

    public func read(frameCount: Int) -> SourceAudioBuffer {
        ringBuffer.read(frameCount: frameCount, sourceID: monitorID)
    }

    public func clear() {
        lock.lock()
        defer {
            lock.unlock()
        }

        ringBuffer.clear()
        lastPeak = 0
        phase = .idle
        status = "No monitor audio"
    }

    public static func mappedBuffer(
        buffer: MixedAudioBuffer,
        monitor: Monitor,
        monitorID: UUID
    ) -> SourceAudioBuffer {
        let channelCount = max(1, monitor.channels.count)
        let frameCount = buffer.frameCount
        var channels = Array(
            repeating: Array(repeating: Float(0), count: frameCount),
            count: channelCount
        )
        let routes = monitor.routes.isEmpty
            ? Monitor.defaultRoutes(channelCount: channelCount)
            : monitor.routes

        for route in routes where !route.isMuted {
            let targetIndex = route.monitorChannelIndex - 1
            guard channels.indices.contains(targetIndex) else {
                continue
            }

            let gain = Float(monitor.gain * route.gain)
            for frameIndex in 0..<frameCount {
                channels[targetIndex][frameIndex] += buffer.sample(
                    channelIndex: route.sourceChannelIndex,
                    frameIndex: frameIndex
                ) * gain
            }
        }

        return SourceAudioBuffer(sourceID: monitorID, channels: channels)
    }

    public func state() -> MonitorOutputState {
        lock.lock()
        defer {
            lock.unlock()
        }

        let snapshot = ringBuffer.snapshot()
        return MonitorOutputState(
            monitorID: monitorID,
            deviceID: deviceID,
            monitorName: monitorName,
            phase: phase,
            status: status,
            availableFrameCount: snapshot.availableFrameCount,
            droppedFrameCount: snapshot.droppedFrameCount,
            peak: lastPeak
        )
    }
}

public final class MonitorOutputEngine: @unchecked Sendable {
    private var sessions: [UUID: MonitorOutputSession] = [:]
    private let lock = NSLock()

    public init() {}

    public func process(graph: RoutingGraph, renderReport: RuntimeRenderReport) -> [UUID: MonitorOutputState] {
        lock.lock()
        defer {
            lock.unlock()
        }

        var states: [UUID: MonitorOutputState] = [:]
        let rendersByDeviceID = Dictionary(uniqueKeysWithValues: renderReport.renders.map { ($0.deviceID, $0) })
        let activeMonitorIDs = Set(graph.devices.flatMap { $0.monitors.map(\.id) })

        sessions = sessions.filter { activeMonitorIDs.contains($0.key) }

        for device in graph.devices {
            guard let render = rendersByDeviceID[device.id] else {
                continue
            }

            for monitor in device.monitors {
                let targetChannelCount = max(1, monitor.channels.count)
                let existingSession = sessions[monitor.id]
                let session = existingSession?.channelCount == targetChannelCount
                    ? existingSession!
                    : MonitorOutputSession(
                        monitorID: monitor.id,
                        deviceID: device.id,
                        monitorName: monitor.name,
                        channelCount: targetChannelCount
                    )
                sessions[monitor.id] = session
                session.receive(
                    buffer: render.result.buffer,
                    monitor: monitor
                )
                states[monitor.id] = session.state()
            }
        }

        return states
    }

    public func state(for monitorID: UUID) -> MonitorOutputState? {
        lock.lock()
        defer {
            lock.unlock()
        }

        return sessions[monitorID]?.state()
    }

    public func session(for monitorID: UUID) -> MonitorOutputSession? {
        lock.lock()
        defer {
            lock.unlock()
        }

        return sessions[monitorID]
    }

    public func clear(monitorID: UUID) {
        lock.lock()
        defer {
            lock.unlock()
        }

        sessions[monitorID]?.clear()
    }
}
