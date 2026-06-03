import Foundation

public struct MonitorRoute: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var sourceChannelIndex: Int
    public var monitorChannelIndex: Int
    public var gain: Double
    public var isMuted: Bool

    public init(
        id: UUID = UUID(),
        sourceChannelIndex: Int,
        monitorChannelIndex: Int,
        gain: Double = 1.0,
        isMuted: Bool = false
    ) {
        self.id = id
        self.sourceChannelIndex = sourceChannelIndex
        self.monitorChannelIndex = monitorChannelIndex
        self.gain = gain
        self.isMuted = isMuted
    }
}
