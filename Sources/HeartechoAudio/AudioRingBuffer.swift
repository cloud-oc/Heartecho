import Foundation

public struct AudioRingBufferSnapshot: Hashable, Sendable {
    public var availableFrameCount: Int
    public var capacity: Int
    public var droppedFrameCount: Int
    public var sampleRate: Double?

    public init(availableFrameCount: Int, capacity: Int, droppedFrameCount: Int, sampleRate: Double? = nil) {
        self.availableFrameCount = availableFrameCount
        self.capacity = capacity
        self.droppedFrameCount = droppedFrameCount
        self.sampleRate = sampleRate
    }
}

public final class AudioRingBuffer: @unchecked Sendable {
    private let channelCount: Int
    private let capacity: Int
    private var channels: [[Float]]
    private var readIndex = 0
    private var writeIndex = 0
    private var availableFrameCount = 0
    private var droppedFrameCount = 0
    private var sampleRate: Double?
    private let lock = NSLock()

    public init(channelCount: Int, capacity: Int) {
        self.channelCount = max(1, channelCount)
        self.capacity = max(1, capacity)
        self.channels = Array(
            repeating: Array(repeating: 0, count: max(1, capacity)),
            count: max(1, channelCount)
        )
    }

    public func write(_ buffer: SourceAudioBuffer) {
        guard !buffer.channels.isEmpty else {
            return
        }

        lock.lock()
        defer {
            lock.unlock()
        }

        sampleRate = buffer.sampleRate ?? sampleRate

        for frameIndex in 0..<buffer.frameCount {
            if availableFrameCount == capacity {
                readIndex = (readIndex + 1) % capacity
                availableFrameCount -= 1
                droppedFrameCount += 1
            }

            for channelIndex in 0..<channelCount {
                channels[channelIndex][writeIndex] = buffer.sample(
                    channelIndex: channelIndex + 1,
                    frameIndex: frameIndex
                )
            }

            writeIndex = (writeIndex + 1) % capacity
            availableFrameCount += 1
        }
    }

    public func read(frameCount requestedFrameCount: Int, sourceID: UUID) -> SourceAudioBuffer {
        let framesToRead = max(0, requestedFrameCount)
        var output = Array(
            repeating: Array(repeating: Float(0), count: framesToRead),
            count: channelCount
        )

        lock.lock()
        defer {
            lock.unlock()
        }

        let readableFrameCount = min(framesToRead, availableFrameCount)

        for frameIndex in 0..<readableFrameCount {
            for channelIndex in 0..<channelCount {
                output[channelIndex][frameIndex] = channels[channelIndex][readIndex]
            }

            readIndex = (readIndex + 1) % capacity
            availableFrameCount -= 1
        }

        return SourceAudioBuffer(sourceID: sourceID, channels: output, sampleRate: sampleRate)
    }

    public func clear() {
        lock.lock()
        defer {
            lock.unlock()
        }

        readIndex = 0
        writeIndex = 0
        availableFrameCount = 0
        droppedFrameCount = 0
        sampleRate = nil
        channels = Array(
            repeating: Array(repeating: 0, count: capacity),
            count: channelCount
        )
    }

    public func snapshot() -> AudioRingBufferSnapshot {
        lock.lock()
        defer {
            lock.unlock()
        }

        return AudioRingBufferSnapshot(
            availableFrameCount: availableFrameCount,
            capacity: capacity,
            droppedFrameCount: droppedFrameCount,
            sampleRate: sampleRate
        )
    }
}
