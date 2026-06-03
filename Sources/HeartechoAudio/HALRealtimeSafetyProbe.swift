import Foundation
import HALDriverC

public struct HALRealtimeSafetyReport: Hashable, Sendable {
    public var ioOperationCount: UInt64
    public var audioReadCallCount: UInt64
    public var audioReadFrameCount: UInt64
    public var zeroFillFrameCount: UInt64
    public var renderPathLockCount: UInt64
    public var renderPathAllocationCount: UInt64
    public var renderPathFileIOCount: UInt64
    public var renderPathSharedMemoryOpenCount: UInt64

    public init(
        ioOperationCount: UInt64,
        audioReadCallCount: UInt64,
        audioReadFrameCount: UInt64,
        zeroFillFrameCount: UInt64,
        renderPathLockCount: UInt64,
        renderPathAllocationCount: UInt64,
        renderPathFileIOCount: UInt64,
        renderPathSharedMemoryOpenCount: UInt64
    ) {
        self.ioOperationCount = ioOperationCount
        self.audioReadCallCount = audioReadCallCount
        self.audioReadFrameCount = audioReadFrameCount
        self.zeroFillFrameCount = zeroFillFrameCount
        self.renderPathLockCount = renderPathLockCount
        self.renderPathAllocationCount = renderPathAllocationCount
        self.renderPathFileIOCount = renderPathFileIOCount
        self.renderPathSharedMemoryOpenCount = renderPathSharedMemoryOpenCount
    }

    public var hasRenderPathRisk: Bool {
        renderPathLockCount > 0 ||
            renderPathAllocationCount > 0 ||
            renderPathFileIOCount > 0 ||
            renderPathSharedMemoryOpenCount > 0
    }

    public var summary: String {
        if hasRenderPathRisk {
            return "Realtime path risk detected"
        }

        return "\(ioOperationCount) IO op(s), \(audioReadFrameCount) frame(s) read, \(zeroFillFrameCount) zero-filled"
    }

    public var detail: String {
        "reads \(audioReadCallCount), locks \(renderPathLockCount), allocations \(renderPathAllocationCount), file I/O \(renderPathFileIOCount), shared-memory opens \(renderPathSharedMemoryOpenCount)"
    }
}

public enum HALRealtimeSafetyProbe {
    public static func reset() {
        HeartechoHALDriverResetRealtimeSafetyStats()
    }

    public static func currentReport() -> HALRealtimeSafetyReport {
        let stats = HeartechoHALDriverRealtimeSafetyStats()
        return HALRealtimeSafetyReport(
            ioOperationCount: stats.ioOperationCount,
            audioReadCallCount: stats.audioReadCallCount,
            audioReadFrameCount: stats.audioReadFrameCount,
            zeroFillFrameCount: stats.zeroFillFrameCount,
            renderPathLockCount: stats.renderPathLockCount,
            renderPathAllocationCount: stats.renderPathAllocationCount,
            renderPathFileIOCount: stats.renderPathFileIOCount,
            renderPathSharedMemoryOpenCount: stats.renderPathSharedMemoryOpenCount
        )
    }
}
