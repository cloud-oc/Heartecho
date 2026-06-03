import Foundation

public struct SystemAudioDevice: Identifiable, Hashable, Sendable {
    public enum Direction: String, Sendable {
        case input
        case output
        case duplex
        case unknown
    }

    public var id: String
    public var audioObjectID: UInt32
    public var uid: String?
    public var name: String
    public var manufacturer: String
    public var direction: Direction
    public var channelCount: Int

    public init(
        id: String,
        audioObjectID: UInt32,
        uid: String?,
        name: String,
        manufacturer: String,
        direction: Direction,
        channelCount: Int
    ) {
        self.id = id
        self.audioObjectID = audioObjectID
        self.uid = uid
        self.name = name
        self.manufacturer = manufacturer
        self.direction = direction
        self.channelCount = channelCount
    }
}
