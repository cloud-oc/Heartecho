import Foundation

public struct ChannelLevel: Hashable, Sendable {
    public var channelIndex: Int
    public var peak: Float
    public var rms: Float

    public init(channelIndex: Int, peak: Float, rms: Float) {
        self.channelIndex = channelIndex
        self.peak = peak
        self.rms = rms
    }
}

public enum LevelMeter {
    public static func measure(_ buffer: SourceAudioBuffer) -> [ChannelLevel] {
        buffer.channels.enumerated().map { index, samples in
            measure(samples: samples, channelIndex: index + 1)
        }
    }

    public static func measure(_ buffer: MixedAudioBuffer) -> [ChannelLevel] {
        buffer.channels.enumerated().map { index, samples in
            measure(samples: samples, channelIndex: index + 1)
        }
    }

    private static func measure(samples: [Float], channelIndex: Int) -> ChannelLevel {
        guard !samples.isEmpty else {
            return ChannelLevel(channelIndex: channelIndex, peak: 0, rms: 0)
        }

        var peak = Float(0)
        var sumSquares = Float(0)

        for sample in samples {
            let absolute = abs(sample)
            peak = max(peak, absolute)
            sumSquares += sample * sample
        }

        return ChannelLevel(
            channelIndex: channelIndex,
            peak: peak,
            rms: sqrt(sumSquares / Float(samples.count))
        )
    }
}
