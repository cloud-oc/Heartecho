import AudioToolbox
import Foundation
import HeartechoCore

public final class AudioQueueMonitorPlaybackSession: @unchecked Sendable {
    public let monitorID: UUID
    public let monitorName: String
    public let deviceIdentifier: String?

    private let monitorSession: MonitorOutputSession
    private let sampleRate: Double
    private let channelCount: Int
    private let framesPerBuffer: Int
    private var queue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef] = []
    private var renderedFrameCount = 0
    private var phase: MonitorPlaybackPhase = .idle
    private var status = "Not playing"
    private let lock = NSLock()

    public init(
        monitor: Monitor,
        monitorSession: MonitorOutputSession,
        sampleRate: Double = 48_000,
        channelCount: Int = 2,
        framesPerBuffer: Int = 512
    ) {
        self.monitorID = monitor.id
        self.monitorName = monitor.name
        self.deviceIdentifier = monitor.deviceIdentifier
        self.monitorSession = monitorSession
        self.sampleRate = sampleRate
        self.channelCount = max(1, channelCount)
        self.framesPerBuffer = max(64, framesPerBuffer)
    }

    deinit {
        stop()
    }

    public func prepare() throws {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard queue == nil else {
            return
        }

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * channelCount),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * channelCount),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
        var createdQueue: AudioQueueRef?
        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()
        var statusCode = AudioQueueNewOutput(
            &format,
            audioQueueMonitorPlaybackCallback,
            unmanagedSelf,
            nil,
            nil,
            0,
            &createdQueue
        )

        guard statusCode == noErr, let createdQueue else {
            throw MonitorPlaybackError.audioQueueCreateFailed(statusCode)
        }

        queue = createdQueue

        if let deviceIdentifier {
            let cfDevice = deviceIdentifier as CFString
            statusCode = withUnsafePointer(to: cfDevice) { pointer in
                AudioQueueSetProperty(
                    createdQueue,
                    kAudioQueueProperty_CurrentDevice,
                    pointer,
                    UInt32(MemoryLayout<CFString>.size)
                )
            }

            guard statusCode == noErr else {
                throw MonitorPlaybackError.audioQueueSetDeviceFailed(statusCode)
            }
        }

        let bufferByteSize = UInt32(framesPerBuffer * channelCount * MemoryLayout<Float>.size)

        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            statusCode = AudioQueueAllocateBuffer(createdQueue, bufferByteSize, &buffer)
            guard statusCode == noErr, let buffer else {
                throw MonitorPlaybackError.audioQueueAllocateBufferFailed(statusCode)
            }
            buffers.append(buffer)
            fill(buffer: buffer)
            statusCode = AudioQueueEnqueueBuffer(createdQueue, buffer, 0, nil)
            guard statusCode == noErr else {
                throw MonitorPlaybackError.audioQueueEnqueueFailed(statusCode)
            }
        }

        phase = .idle
        status = deviceIdentifier == nil
            ? "Prepared for default output"
            : "Prepared for output \(deviceIdentifier ?? "unknown")"
    }

    public func start() throws {
        try prepare()

        lock.lock()
        defer {
            lock.unlock()
        }

        guard let queue else {
            throw MonitorPlaybackError.audioQueueUnavailable
        }

        let statusCode = AudioQueueStart(queue, nil)
        guard statusCode == noErr else {
            phase = .failed
            status = "AudioQueueStart failed with \(statusCode)"
            throw MonitorPlaybackError.audioQueueStartFailed(statusCode)
        }

        phase = .running
        status = deviceIdentifier == nil
            ? "Playing default output"
            : "Playing output \(deviceIdentifier ?? "unknown")"
    }

    public func stop() {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard let queue else {
            phase = .idle
            status = "Not playing"
            return
        }

        AudioQueueStop(queue, true)
        AudioQueueDispose(queue, true)
        self.queue = nil
        buffers.removeAll()
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

    fileprivate func enqueue(buffer: AudioQueueBufferRef, queue: AudioQueueRef) {
        fill(buffer: buffer)
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    private func fill(buffer: AudioQueueBufferRef) {
        let source = monitorSession.read(frameCount: framesPerBuffer)
        let output = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)

        for frameIndex in 0..<framesPerBuffer {
            for channelOffset in 0..<channelCount {
                output[frameIndex * channelCount + channelOffset] = source.sample(
                    channelIndex: (channelOffset % max(1, source.channels.count)) + 1,
                    frameIndex: frameIndex
                )
            }
        }

        buffer.pointee.mAudioDataByteSize = UInt32(framesPerBuffer * channelCount * MemoryLayout<Float>.size)
        renderedFrameCount += framesPerBuffer
    }
}

private let audioQueueMonitorPlaybackCallback: AudioQueueOutputCallback = { userData, queue, buffer in
    guard let userData else {
        return
    }

    let session = Unmanaged<AudioQueueMonitorPlaybackSession>
        .fromOpaque(userData)
        .takeUnretainedValue()
    session.enqueue(buffer: buffer, queue: queue)
}
