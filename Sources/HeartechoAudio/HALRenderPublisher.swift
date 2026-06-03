import Foundation
import HALDriverStub
import HeartechoCore

public struct HALDeviceRenderPublication: Hashable, Sendable {
    public var deviceID: UUID
    public var deviceName: String
    public var deviceObjectID: UInt32
    public var channelCount: Int
    public var frameCount: Int
    public var didWrite: Bool
    public var snapshot: HALAudioBufferSnapshot

    public init(
        deviceID: UUID,
        deviceName: String,
        deviceObjectID: UInt32,
        channelCount: Int,
        frameCount: Int,
        didWrite: Bool,
        snapshot: HALAudioBufferSnapshot
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceObjectID = deviceObjectID
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.didWrite = didWrite
        self.snapshot = snapshot
    }
}

public struct HALRenderPublicationReport: Hashable, Sendable {
    public var publications: [HALDeviceRenderPublication]
    public var skippedDeviceIDs: Set<UUID>
    public var sharedMemoryName: String?
    public var sharedMemoryByteCount: Int?
    public var didPublishSharedMemory: Bool

    public init(
        publications: [HALDeviceRenderPublication],
        skippedDeviceIDs: Set<UUID>,
        sharedMemoryName: String? = nil,
        sharedMemoryByteCount: Int? = nil,
        didPublishSharedMemory: Bool = false
    ) {
        self.publications = publications
        self.skippedDeviceIDs = skippedDeviceIDs
        self.sharedMemoryName = sharedMemoryName
        self.sharedMemoryByteCount = sharedMemoryByteCount
        self.didPublishSharedMemory = didPublishSharedMemory
    }

    public var allWritesSucceeded: Bool {
        !publications.isEmpty && publications.allSatisfy(\.didWrite)
    }

    public var totalPublishedFrameCount: Int {
        publications.reduce(0) { $0 + $1.frameCount }
    }

    public var failedWriteCount: Int {
        publications.filter { !$0.didWrite }.count
    }
}

public enum HALRenderPublisher {
    public static func publish(
        renderReport: RuntimeRenderReport,
        graph: RoutingGraph
    ) throws -> HALRenderPublicationReport {
        try publish(
            renderReport: renderReport,
            configuration: HALDriverBridge.runtimeConfiguration(from: graph)
        )
    }

    public static func publishToSharedMemory(
        renderReport: RuntimeRenderReport,
        graph: RoutingGraph,
        sharedMemoryName: String
    ) throws -> HALRenderPublicationReport {
        try publishToSharedMemory(
            renderReport: renderReport,
            configuration: HALDriverBridge.runtimeConfiguration(from: graph),
            sharedMemoryName: sharedMemoryName
        )
    }

    public static func publishToSharedMemory(
        renderReport: RuntimeRenderReport,
        configuration: HALRuntimeConfiguration,
        sharedMemoryName: String
    ) -> HALRenderPublicationReport {
        let didOpenSharedMemory = HALAudioBufferBridge.openSharedMemory(
            name: sharedMemoryName,
            createIfMissing: true
        )
        var report = publish(renderReport: renderReport, configuration: configuration)
        report.sharedMemoryName = sharedMemoryName
        report.sharedMemoryByteCount = HALAudioBufferBridge.sharedMemoryByteCount
        report.didPublishSharedMemory = didOpenSharedMemory
        return report
    }

    public static func publish(
        renderReport: RuntimeRenderReport,
        configuration: HALRuntimeConfiguration
    ) -> HALRenderPublicationReport {
        let indexedConfigurations = configuration.devices
            .prefix(HALSharedConfigLayout.maxDevices)
            .enumerated()
            .map { index, device in
                (
                    device.id,
                    HALRenderDeviceTarget(
                        objectID: HALSharedConfigLayout.deviceObjectID(for: index),
                        channelCount: device.channelCount,
                        isEnabled: device.isEnabled
                    )
                )
            }

        let targetsByDeviceID = Dictionary(uniqueKeysWithValues: indexedConfigurations)
        var publications: [HALDeviceRenderPublication] = []
        var skipped = Set<UUID>()

        for render in renderReport.renders {
            guard let target = targetsByDeviceID[render.deviceID], target.isEnabled else {
                skipped.insert(render.deviceID)
                continue
            }

            let channelCount = max(1, min(target.channelCount, HALAudioBufferBridge.maximumChannelCount))
            let didWrite = HALAudioBufferBridge.write(
                buffer: render.result.buffer,
                deviceObjectID: target.objectID,
                channelCount: channelCount
            )
            let snapshot = HALAudioBufferBridge.snapshot(deviceObjectID: target.objectID)

            publications.append(HALDeviceRenderPublication(
                deviceID: render.deviceID,
                deviceName: render.deviceName,
                deviceObjectID: target.objectID,
                channelCount: channelCount,
                frameCount: render.result.report.frameCount,
                didWrite: didWrite,
                snapshot: snapshot
            ))
        }

        return HALRenderPublicationReport(publications: publications, skippedDeviceIDs: skipped)
    }
}

private struct HALRenderDeviceTarget {
    var objectID: UInt32
    var channelCount: Int
    var isEnabled: Bool
}
