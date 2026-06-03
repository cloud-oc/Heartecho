import Foundation

public struct ChannelRoute: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var sourceID: UUID
    public var sourceChannelIndex: Int
    public var outputChannelIndex: Int
    public var gain: Double
    public var isMuted: Bool

    public init(
        id: UUID = UUID(),
        sourceID: UUID,
        sourceChannelIndex: Int,
        outputChannelIndex: Int,
        gain: Double = 1.0,
        isMuted: Bool = false
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceChannelIndex = sourceChannelIndex
        self.outputChannelIndex = outputChannelIndex
        self.gain = gain
        self.isMuted = isMuted
    }
}
