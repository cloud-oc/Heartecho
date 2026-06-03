import Foundation

public enum AudioSourceKind: String, Codable, CaseIterable, Sendable {
    case application
    case hardwareInput
    case passThru
    case virtualDevice
}

public struct AudioSource: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: AudioSourceKind
    public var isEnabled: Bool
    public var sourceIdentifier: String?
    public var channels: [AudioChannel]
    public var gain: Double
    public var isMuted: Bool
    public var mutesWhenCaptured: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        kind: AudioSourceKind,
        isEnabled: Bool = true,
        sourceIdentifier: String? = nil,
        channels: [AudioChannel] = AudioChannel.stereo(),
        gain: Double = 1.0,
        isMuted: Bool = false,
        mutesWhenCaptured: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isEnabled = isEnabled
        self.sourceIdentifier = sourceIdentifier
        self.channels = channels
        self.gain = gain
        self.isMuted = isMuted
        self.mutesWhenCaptured = mutesWhenCaptured
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case isEnabled
        case sourceIdentifier
        case channels
        case gain
        case isMuted
        case mutesWhenCaptured
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(AudioSourceKind.self, forKey: .kind)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        sourceIdentifier = try container.decodeIfPresent(String.self, forKey: .sourceIdentifier)
        channels = try container.decode([AudioChannel].self, forKey: .channels)
        gain = try container.decode(Double.self, forKey: .gain)
        isMuted = try container.decode(Bool.self, forKey: .isMuted)
        mutesWhenCaptured = try container.decodeIfPresent(Bool.self, forKey: .mutesWhenCaptured) ?? false
    }
}
