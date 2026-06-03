import Foundation

public struct VirtualAudioDevice: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var sampleRate: Double
    public var latencyFrames: Int
    public var safetyOffsetFrames: Int
    public var bufferFrameSize: Int
    public var outputChannels: [AudioChannel]
    public var sources: [AudioSource]
    public var routes: [ChannelRoute]
    public var monitors: [Monitor]
    public var masterGain: Double
    public var isMuted: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case isEnabled
        case sampleRate
        case latencyFrames
        case safetyOffsetFrames
        case bufferFrameSize
        case outputChannels
        case sources
        case routes
        case monitors
        case masterGain
        case isMuted
    }

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        sampleRate: Double = 48_000,
        latencyFrames: Int = 0,
        safetyOffsetFrames: Int = 0,
        bufferFrameSize: Int = 512,
        outputChannels: [AudioChannel] = AudioChannel.stereo(),
        sources: [AudioSource] = [],
        routes: [ChannelRoute] = [],
        monitors: [Monitor] = [],
        masterGain: Double = 1.0,
        isMuted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.sampleRate = sampleRate
        self.latencyFrames = max(0, latencyFrames)
        self.safetyOffsetFrames = max(0, safetyOffsetFrames)
        self.bufferFrameSize = max(16, bufferFrameSize)
        self.outputChannels = outputChannels
        self.sources = sources
        self.routes = routes
        self.monitors = monitors
        self.masterGain = masterGain
        self.isMuted = isMuted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        sampleRate = try container.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 48_000
        latencyFrames = max(0, try container.decodeIfPresent(Int.self, forKey: .latencyFrames) ?? 0)
        safetyOffsetFrames = max(0, try container.decodeIfPresent(Int.self, forKey: .safetyOffsetFrames) ?? 0)
        bufferFrameSize = max(16, try container.decodeIfPresent(Int.self, forKey: .bufferFrameSize) ?? 512)
        outputChannels = try container.decodeIfPresent([AudioChannel].self, forKey: .outputChannels) ?? AudioChannel.stereo()
        sources = try container.decodeIfPresent([AudioSource].self, forKey: .sources) ?? []
        routes = try container.decodeIfPresent([ChannelRoute].self, forKey: .routes) ?? []
        monitors = try container.decodeIfPresent([Monitor].self, forKey: .monitors) ?? []
        masterGain = try container.decodeIfPresent(Double.self, forKey: .masterGain) ?? 1.0
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    }

    public static func starterDevice() -> VirtualAudioDevice {
        let passThru = AudioSource(name: "Pass-Thru", kind: .passThru)
        return VirtualAudioDevice(
            name: "Studio Virtual Mic",
            sources: [passThru],
            routes: [
                ChannelRoute(sourceID: passThru.id, sourceChannelIndex: 1, outputChannelIndex: 1),
                ChannelRoute(sourceID: passThru.id, sourceChannelIndex: 2, outputChannelIndex: 2)
            ],
            monitors: [
                Monitor(name: "Built-in Output")
            ]
        )
    }
}
