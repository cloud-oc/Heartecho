import Foundation

public struct AudioChannel: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var index: Int
    public var name: String

    public init(id: UUID = UUID(), index: Int, name: String) {
        self.id = id
        self.index = index
        self.name = name
    }

    public static func stereo() -> [AudioChannel] {
        [
            AudioChannel(index: 1, name: "Left"),
            AudioChannel(index: 2, name: "Right")
        ]
    }

    public static func numbered(count: Int) -> [AudioChannel] {
        (1...max(1, count)).map { AudioChannel(index: $0, name: "Channel \($0)") }
    }
}
