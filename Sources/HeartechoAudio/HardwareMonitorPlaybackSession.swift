import AVFoundation
import Foundation
import HeartechoCore

public enum MonitorPlaybackPhase: String, Hashable, Sendable {
    case idle = "Idle"
    case running = "Playing"
    case failed = "Failed"
}

public struct MonitorPlaybackState: Identifiable, Hashable, Sendable {
    public var id: UUID {
        monitorID
    }

    public var monitorID: UUID
    public var phase: MonitorPlaybackPhase
    public var status: String
    public var renderedFrameCount: Int

    public init(
        monitorID: UUID,
        phase: MonitorPlaybackPhase,
        status: String,
        renderedFrameCount: Int
    ) {
        self.monitorID = monitorID
        self.phase = phase
        self.status = status
        self.renderedFrameCount = renderedFrameCount
    }
}

public final class HardwareMonitorPlaybackSession: @unchecked Sendable {
    public let monitorID: UUID
    public let monitorName: String
    public let deviceIdentifier: String?

    private let monitorSession: MonitorOutputSession
    private let audioQueueSession: AudioQueueMonitorPlaybackSession
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var renderedFrameCount = 0
    private var phase: MonitorPlaybackPhase = .idle
    private var status = "Not playing"
    private let lock = NSLock()

    public init(monitor: Monitor, monitorSession: MonitorOutputSession) {
        self.monitorID = monitor.id
        self.monitorName = monitor.name
        self.deviceIdentifier = monitor.deviceIdentifier
        self.monitorSession = monitorSession
        self.audioQueueSession = AudioQueueMonitorPlaybackSession(
            monitor: monitor,
            monitorSession: monitorSession
        )
    }

    deinit {
        stop()
    }

    public func prepare(sampleRate: Double = 48_000, channelCount: Int = 2) throws {
        if deviceIdentifier != nil {
            try audioQueueSession.prepare()
            let state = audioQueueSession.state()
            phase = state.phase
            status = state.status
            renderedFrameCount = state.renderedFrameCount
            return
        }

        lock.lock()
        defer {
            lock.unlock()
        }

        guard sourceNode == nil else {
            return
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(max(1, channelCount)),
            interleaved: false
        ) else {
            throw MonitorPlaybackError.formatUnavailable
        }

        let node = AVAudioSourceNode { [weak self] _, _, frameCount, outputData in
            guard let self else {
                return noErr
            }
            self.render(frameCount: Int(frameCount), outputData: outputData)
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.outputNode, format: format)
        sourceNode = node
        phase = .idle
        status = deviceIdentifier == nil
            ? "Prepared for default output"
            : "Prepared for target \(deviceIdentifier ?? "unknown"); AVAudioEngine uses default output"
    }

    public func start(sampleRate: Double = 48_000, channelCount: Int = 2) throws {
        if deviceIdentifier != nil {
            try audioQueueSession.start()
            let state = audioQueueSession.state()
            lock.lock()
            phase = state.phase
            status = state.status
            renderedFrameCount = state.renderedFrameCount
            lock.unlock()
            return
        }

        try prepare(sampleRate: sampleRate, channelCount: channelCount)

        lock.lock()
        defer {
            lock.unlock()
        }

        guard !engine.isRunning else {
            phase = .running
            status = "Playing"
            return
        }

        do {
            try engine.start()
            phase = .running
            status = deviceIdentifier == nil
                ? "Playing default output"
                : "Playing default output; target \(deviceIdentifier ?? "unknown") pending Core Audio device binding"
        } catch {
            phase = .failed
            status = error.localizedDescription
            throw error
        }
    }

    public func stop() {
        if deviceIdentifier != nil {
            audioQueueSession.stop()
            let state = audioQueueSession.state()
            lock.lock()
            phase = state.phase
            status = state.status
            renderedFrameCount = state.renderedFrameCount
            lock.unlock()
            return
        }

        lock.lock()
        defer {
            lock.unlock()
        }

        engine.stop()
        phase = .idle
        status = "Stopped"
    }

    public func state() -> MonitorPlaybackState {
        lock.lock()
        defer {
            lock.unlock()
        }

        return MonitorPlaybackState(
            monitorID: monitorID,
            phase: phase,
            status: status,
            renderedFrameCount: renderedFrameCount
        )
    }

    private func render(frameCount: Int, outputData: UnsafeMutablePointer<AudioBufferList>) {
        let source = monitorSession.read(frameCount: frameCount)
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        let sourceChannelCount = max(1, source.channels.count)

        for outputBufferIndex in outputBuffers.indices {
            let channel = outputBuffers[outputBufferIndex]
            guard let data = channel.mData else {
                continue
            }

            let samples = data.assumingMemoryBound(to: Float.self)
            let channelCount = max(1, Int(channel.mNumberChannels))
            let frameCapacity = Int(channel.mDataByteSize) / MemoryLayout<Float>.size / channelCount
            let framesToWrite = min(frameCount, frameCapacity)

            for frameIndex in 0..<framesToWrite {
                for channelOffset in 0..<channelCount {
                    let sourceChannelIndex = ((outputBufferIndex + channelOffset) % sourceChannelCount) + 1
                    samples[frameIndex * channelCount + channelOffset] = source.sample(
                        channelIndex: sourceChannelIndex,
                        frameIndex: frameIndex
                    )
                }
            }
        }

        lock.lock()
        renderedFrameCount += frameCount
        lock.unlock()
    }
}

public enum MonitorPlaybackError: Error, CustomStringConvertible, Sendable {
    case formatUnavailable
    case monitorSessionUnavailable(UUID)
    case audioQueueUnavailable
    case audioQueueCreateFailed(OSStatus)
    case audioQueueSetDeviceFailed(OSStatus)
    case audioQueueAllocateBufferFailed(OSStatus)
    case audioQueueEnqueueFailed(OSStatus)
    case audioQueueStartFailed(OSStatus)

    public var description: String {
        switch self {
        case .formatUnavailable:
            return "Could not create an AVAudioFormat for monitor playback."
        case .monitorSessionUnavailable(let monitorID):
            return "No monitor output session exists for monitor \(monitorID)."
        case .audioQueueUnavailable:
            return "No AudioQueue exists for monitor playback."
        case .audioQueueCreateFailed(let status):
            return "AudioQueueNewOutput failed with OSStatus \(status)."
        case .audioQueueSetDeviceFailed(let status):
            return "AudioQueueSetProperty(kAudioQueueProperty_CurrentDevice) failed with OSStatus \(status)."
        case .audioQueueAllocateBufferFailed(let status):
            return "AudioQueueAllocateBuffer failed with OSStatus \(status)."
        case .audioQueueEnqueueFailed(let status):
            return "AudioQueueEnqueueBuffer failed with OSStatus \(status)."
        case .audioQueueStartFailed(let status):
            return "AudioQueueStart failed with OSStatus \(status)."
        }
    }
}
