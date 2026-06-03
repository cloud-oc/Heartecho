import Foundation

public struct Monitor: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var deviceIdentifier: String?
    public var isEnabled: Bool
    public var gain: Double
    public var isMuted: Bool
    public var channels: [AudioChannel]
    public var routes: [MonitorRoute]

    public init(
        id: UUID = UUID(),
        name: String,
        deviceIdentifier: String? = nil,
        isEnabled: Bool = true,
        gain: Double = 1.0,
        isMuted: Bool = false,
        channels: [AudioChannel] = AudioChannel.stereo(),
        routes: [MonitorRoute]? = nil
    ) {
        self.id = id
        self.name = name
        self.deviceIdentifier = deviceIdentifier
        self.isEnabled = isEnabled
        self.gain = gain
        self.isMuted = isMuted
        self.channels = channels
        self.routes = routes ?? Self.defaultRoutes(channelCount: channels.count)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case deviceIdentifier
        case isEnabled
        case gain
        case isMuted
        case channels
        case routes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        deviceIdentifier = try container.decodeIfPresent(String.self, forKey: .deviceIdentifier)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        gain = try container.decode(Double.self, forKey: .gain)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        channels = try container.decodeIfPresent([AudioChannel].self, forKey: .channels) ?? AudioChannel.stereo()
        routes = try container.decodeIfPresent([MonitorRoute].self, forKey: .routes) ?? Self.defaultRoutes(channelCount: channels.count)
    }

    public static func defaultRoutes(channelCount: Int) -> [MonitorRoute] {
        (1...max(1, channelCount)).map {
            MonitorRoute(sourceChannelIndex: $0, monitorChannelIndex: $0)
        }
    }
}
