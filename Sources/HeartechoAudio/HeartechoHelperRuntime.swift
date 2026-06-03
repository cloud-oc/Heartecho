import Foundation
import HALDriverStub
import HeartechoCore

public struct HeartechoHelperRuntimeOptions: Hashable, Sendable {
    public var graphURL: URL
    public var frameCount: Int
    public var publishAudio: Bool
    public var createStarterGraphIfMissing: Bool
    public var configSharedMemoryName: String
    public var audioSharedMemoryName: String

    public init(
        graphURL: URL,
        frameCount: Int = 512,
        publishAudio: Bool = false,
        createStarterGraphIfMissing: Bool = false,
        configSharedMemoryName: String = HALDriverBridge.defaultSharedMemoryName,
        audioSharedMemoryName: String = "/HeartechoHALAudioBuffers"
    ) {
        self.graphURL = graphURL
        self.frameCount = frameCount
        self.publishAudio = publishAudio
        self.createStarterGraphIfMissing = createStarterGraphIfMissing
        self.configSharedMemoryName = configSharedMemoryName
        self.audioSharedMemoryName = audioSharedMemoryName
    }
}

public struct HeartechoHelperPublicationReport: Hashable, Sendable {
    public var graphURL: URL
    public var deviceCount: Int
    public var enabledDeviceCount: Int
    public var configSharedMemoryName: String
    public var configByteCount: Int
    public var audioSharedMemoryName: String?
    public var audioSharedMemoryByteCount: Int?
    public var audioPublication: HALRenderPublicationReport?

    public init(
        graphURL: URL,
        deviceCount: Int,
        enabledDeviceCount: Int,
        configSharedMemoryName: String,
        configByteCount: Int,
        audioSharedMemoryName: String?,
        audioSharedMemoryByteCount: Int?,
        audioPublication: HALRenderPublicationReport?
    ) {
        self.graphURL = graphURL
        self.deviceCount = deviceCount
        self.enabledDeviceCount = enabledDeviceCount
        self.configSharedMemoryName = configSharedMemoryName
        self.configByteCount = configByteCount
        self.audioSharedMemoryName = audioSharedMemoryName
        self.audioSharedMemoryByteCount = audioSharedMemoryByteCount
        self.audioPublication = audioPublication
    }
}

public struct HeartechoHelperRunLoopOptions: Hashable, Sendable {
    public var publicationOptions: HeartechoHelperRuntimeOptions
    public var intervalMilliseconds: Int
    public var iterationLimit: Int?

    public init(
        publicationOptions: HeartechoHelperRuntimeOptions,
        intervalMilliseconds: Int = 10,
        iterationLimit: Int? = nil
    ) {
        self.publicationOptions = publicationOptions
        self.intervalMilliseconds = max(1, intervalMilliseconds)
        self.iterationLimit = iterationLimit.map { max(1, $0) }
    }
}

public struct HeartechoHelperRunLoopReport: Hashable, Sendable {
    public var iterationCount: Int
    public var intervalMilliseconds: Int
    public var iterationLimit: Int?
    public var totalPublishedFrameCount: Int
    public var lastPublication: HeartechoHelperPublicationReport?

    public init(
        iterationCount: Int,
        intervalMilliseconds: Int,
        iterationLimit: Int?,
        totalPublishedFrameCount: Int,
        lastPublication: HeartechoHelperPublicationReport?
    ) {
        self.iterationCount = iterationCount
        self.intervalMilliseconds = intervalMilliseconds
        self.iterationLimit = iterationLimit
        self.totalPublishedFrameCount = totalPublishedFrameCount
        self.lastPublication = lastPublication
    }

    public var stoppedAfterIterationLimit: Bool {
        iterationLimit != nil && iterationCount >= (iterationLimit ?? 0)
    }
}

public enum HeartechoHelperRuntime {
    public static func defaultGraphURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Heartecho", isDirectory: true)
            .appendingPathComponent("RoutingGraph.json")
    }

    public static func publish(options: HeartechoHelperRuntimeOptions) throws -> HeartechoHelperPublicationReport {
        try publish(options: options, audioSharedMemoryIsOpen: false, didOpenAudioSharedMemory: false)
    }

    private static func publish(
        options: HeartechoHelperRuntimeOptions,
        audioSharedMemoryIsOpen: Bool,
        didOpenAudioSharedMemory: Bool
    ) throws -> HeartechoHelperPublicationReport {
        let store = RoutingGraphStore(fileURL: options.graphURL)
        if options.createStarterGraphIfMissing && !FileManager.default.fileExists(atPath: options.graphURL.path) {
            try store.save(RoutingGraph())
        }

        let graph = try store.load()
        let configuration = try HALDriverBridge.runtimeConfiguration(from: graph)
        let configPublication = try HALDriverBridge.publishSharedConfiguration(
            configuration,
            sharedMemoryName: options.configSharedMemoryName
        )

        var audioPublication: HALRenderPublicationReport?
        if options.publishAudio {
            let report = RuntimeRoutingEngine().render(
                graph: graph,
                captureSessions: [:],
                injectedBuffers: silenceBuffers(for: graph, frameCount: options.frameCount),
                frameCount: options.frameCount
            )
            if audioSharedMemoryIsOpen {
                var publication = HALRenderPublisher.publish(
                    renderReport: report,
                    configuration: configuration
                )
                publication.sharedMemoryName = options.audioSharedMemoryName
                publication.sharedMemoryByteCount = HALAudioBufferBridge.sharedMemoryByteCount
                publication.didPublishSharedMemory = didOpenAudioSharedMemory
                audioPublication = publication
            } else {
                audioPublication = HALRenderPublisher.publishToSharedMemory(
                    renderReport: report,
                    configuration: configuration,
                    sharedMemoryName: options.audioSharedMemoryName
                )
            }
        }

        return HeartechoHelperPublicationReport(
            graphURL: options.graphURL,
            deviceCount: configuration.devices.count,
            enabledDeviceCount: configuration.devices.filter(\.isEnabled).count,
            configSharedMemoryName: configPublication.name,
            configByteCount: configPublication.byteCount,
            audioSharedMemoryName: audioPublication?.sharedMemoryName,
            audioSharedMemoryByteCount: audioPublication?.sharedMemoryByteCount,
            audioPublication: audioPublication
        )
    }

    public static func run(
        options: HeartechoHelperRunLoopOptions,
        onIteration: ((HeartechoHelperPublicationReport) -> Void)? = nil
    ) throws -> HeartechoHelperRunLoopReport {
        var iterationCount = 0
        var totalPublishedFrameCount = 0
        var lastPublication: HeartechoHelperPublicationReport?
        let didOpenAudioSharedMemory = options.publicationOptions.publishAudio
            ? HALAudioBufferBridge.openSharedMemory(name: options.publicationOptions.audioSharedMemoryName, createIfMissing: true)
            : false

        while options.iterationLimit == nil || iterationCount < (options.iterationLimit ?? 0) {
            let report = try publish(
                options: options.publicationOptions,
                audioSharedMemoryIsOpen: options.publicationOptions.publishAudio,
                didOpenAudioSharedMemory: didOpenAudioSharedMemory
            )
            iterationCount += 1
            totalPublishedFrameCount += report.audioPublication?.totalPublishedFrameCount ?? 0
            lastPublication = report
            onIteration?(report)

            if options.iterationLimit != nil && iterationCount >= (options.iterationLimit ?? 0) {
                break
            }

            Thread.sleep(forTimeInterval: Double(options.intervalMilliseconds) / 1_000)
        }

        return HeartechoHelperRunLoopReport(
            iterationCount: iterationCount,
            intervalMilliseconds: options.intervalMilliseconds,
            iterationLimit: options.iterationLimit,
            totalPublishedFrameCount: totalPublishedFrameCount,
            lastPublication: lastPublication
        )
    }

    private static func silenceBuffers(for graph: RoutingGraph, frameCount: Int) -> [UUID: SourceAudioBuffer] {
        let frames = max(0, frameCount)
        var buffers: [UUID: SourceAudioBuffer] = [:]

        for source in graph.devices.flatMap(\.sources) {
            guard buffers[source.id] == nil else {
                continue
            }

            let channelCount = max(1, source.channels.count)
            buffers[source.id] = SourceAudioBuffer(
                sourceID: source.id,
                channels: Array(repeating: Array(repeating: 0, count: frames), count: channelCount)
            )
        }

        return buffers
    }
}
