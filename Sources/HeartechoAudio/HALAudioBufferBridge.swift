import Foundation
import HALDriverC

public struct HALAudioBufferSnapshot: Hashable, Sendable {
    public var deviceObjectID: UInt32
    public var channelCount: UInt32
    public var capacityFrames: UInt32
    public var availableFrames: UInt32
    public var totalWrittenFrames: UInt64
    public var totalReadFrames: UInt64
    public var droppedFrameCount: UInt64
    public var writerHeartbeat: UInt64
    public var readerHeartbeat: UInt64

    public init(
        deviceObjectID: UInt32,
        channelCount: UInt32,
        capacityFrames: UInt32,
        availableFrames: UInt32,
        totalWrittenFrames: UInt64,
        totalReadFrames: UInt64,
        droppedFrameCount: UInt64,
        writerHeartbeat: UInt64 = 0,
        readerHeartbeat: UInt64 = 0
    ) {
        self.deviceObjectID = deviceObjectID
        self.channelCount = channelCount
        self.capacityFrames = capacityFrames
        self.availableFrames = availableFrames
        self.totalWrittenFrames = totalWrittenFrames
        self.totalReadFrames = totalReadFrames
        self.droppedFrameCount = droppedFrameCount
        self.writerHeartbeat = writerHeartbeat
        self.readerHeartbeat = readerHeartbeat
    }
}

public struct HALAudioTransportHealthReport: Hashable, Sendable {
    public var previous: HALAudioBufferSnapshot?
    public var current: HALAudioBufferSnapshot
    public var writerAdvanced: Bool
    public var readerAdvanced: Bool
    public var didOverflow: Bool
    public var isWriterStale: Bool
    public var isReaderStale: Bool

    public init(previous: HALAudioBufferSnapshot?, current: HALAudioBufferSnapshot) {
        self.previous = previous
        self.current = current
        self.writerAdvanced = previous.map { current.writerHeartbeat > $0.writerHeartbeat } ?? (current.writerHeartbeat > 0)
        self.readerAdvanced = previous.map { current.readerHeartbeat > $0.readerHeartbeat } ?? (current.readerHeartbeat > 0)
        self.didOverflow = previous.map { current.droppedFrameCount > $0.droppedFrameCount } ?? (current.droppedFrameCount > 0)
        self.isWriterStale = previous != nil && !writerAdvanced
        self.isReaderStale = previous != nil && current.availableFrames > 0 && !readerAdvanced
    }

    public var isHealthy: Bool {
        !isWriterStale && !didOverflow
    }

    public var summary: String {
        if didOverflow {
            return "Audio transport overflowed"
        }
        if isWriterStale {
            return "Audio transport writer is stale"
        }
        if isReaderStale {
            return "Audio transport reader is idle"
        }
        return "Audio transport is moving"
    }

    public var detail: String {
        "writer heartbeat \(current.writerHeartbeat), reader heartbeat \(current.readerHeartbeat), available \(current.availableFrames), dropped \(current.droppedFrameCount)"
    }
}

public enum HALAudioBufferBridge {
    public static let maximumChannelCount = 64
    public static let maximumDeviceCount = 16

    public static func reset() {
        HeartechoHALDriverResetAudioBuffer()
    }

    public static var sharedMemoryByteCount: Int {
        HeartechoHALDriverAudioSharedMemoryByteCount()
    }

    public static func openSharedMemory(name: String, createIfMissing: Bool = true) -> Bool {
        guard name.hasPrefix("/"), name.utf8.count > 1 else {
            return false
        }

        return name.withCString { rawName in
            HeartechoHALDriverOpenAudioBuffersSharedMemory(rawName, createIfMissing)
        }
    }

    public static func closeSharedMemory() {
        HeartechoHALDriverCloseAudioBuffersSharedMemory()
    }

    public static func write(
        buffer: MixedAudioBuffer,
        deviceObjectID: UInt32,
        channelCount: Int? = nil
    ) -> Bool {
        let channelsToWrite = max(1, min(channelCount ?? buffer.channels.count, maximumChannelCount))
        let frameCount = buffer.frameCount
        guard frameCount > 0 else {
            return true
        }

        var interleaved = [Float](repeating: 0, count: frameCount * channelsToWrite)
        for frameIndex in 0..<frameCount {
            for channelIndex in 0..<channelsToWrite {
                if buffer.channels.indices.contains(channelIndex),
                   buffer.channels[channelIndex].indices.contains(frameIndex) {
                    interleaved[frameIndex * channelsToWrite + channelIndex] = buffer.channels[channelIndex][frameIndex]
                }
            }
        }

        return interleaved.withUnsafeBufferPointer { pointer in
            HeartechoHALDriverWriteAudioFrames(
                deviceObjectID,
                UInt32(channelsToWrite),
                UInt32(frameCount),
                pointer.baseAddress
            )
        }
    }

    public static func readInterleaved(
        deviceObjectID: UInt32,
        channelCount: Int,
        frameCount: Int
    ) -> [Float] {
        let channelsToRead = max(1, min(channelCount, maximumChannelCount))
        let framesToRead = max(0, frameCount)
        var interleaved = [Float](repeating: 0, count: framesToRead * channelsToRead)

        interleaved.withUnsafeMutableBufferPointer { pointer in
            _ = HeartechoHALDriverReadAudioFrames(
                deviceObjectID,
                UInt32(channelsToRead),
                UInt32(framesToRead),
                pointer.baseAddress
            )
        }

        return interleaved
    }

    public static func snapshot(deviceObjectID: UInt32) -> HALAudioBufferSnapshot {
        let snapshot = HeartechoHALDriverAudioBufferStats(deviceObjectID)
        return HALAudioBufferSnapshot(
            deviceObjectID: snapshot.deviceObjectID,
            channelCount: snapshot.channelCount,
            capacityFrames: snapshot.capacityFrames,
            availableFrames: snapshot.availableFrames,
            totalWrittenFrames: snapshot.totalWrittenFrames,
            totalReadFrames: snapshot.totalReadFrames,
            droppedFrameCount: snapshot.droppedFrameCount,
            writerHeartbeat: snapshot.writerHeartbeat,
            readerHeartbeat: snapshot.readerHeartbeat
        )
    }

    public static func healthReport(
        previous: HALAudioBufferSnapshot?,
        current: HALAudioBufferSnapshot
    ) -> HALAudioTransportHealthReport {
        HALAudioTransportHealthReport(previous: previous, current: current)
    }

    public static func publishSharedMemory(name: String) -> Bool {
        guard name.hasPrefix("/"), name.utf8.count > 1 else {
            return false
        }

        return name.withCString { rawName in
            HeartechoHALDriverPublishAudioBuffersToSharedMemory(rawName)
        }
    }

    public static func loadSharedMemory(name: String) -> Bool {
        guard name.hasPrefix("/"), name.utf8.count > 1 else {
            return false
        }

        return name.withCString { rawName in
            HeartechoHALDriverLoadAudioBuffersFromSharedMemory(rawName)
        }
    }

    public static func unlinkSharedMemory(name: String) -> Bool {
        guard name.hasPrefix("/"), name.utf8.count > 1 else {
            return false
        }

        return name.withCString { rawName in
            HeartechoHALDriverUnlinkAudioBuffersSharedMemory(rawName)
        }
    }
}
