import Foundation
import HeartechoCore

public struct SourceAudioBuffer: Hashable, Sendable {
    public var sourceID: UUID
    public var channels: [[Float]]
    public var sampleRate: Double?

    public init(sourceID: UUID, channels: [[Float]], sampleRate: Double? = nil) {
        self.sourceID = sourceID
        self.channels = channels
        self.sampleRate = sampleRate
    }

    public var frameCount: Int {
        channels.map(\.count).max() ?? 0
    }

    public func sample(channelIndex: Int, frameIndex: Int) -> Float {
        let zeroBasedChannel = channelIndex - 1
        guard zeroBasedChannel >= 0,
              channels.indices.contains(zeroBasedChannel),
              channels[zeroBasedChannel].indices.contains(frameIndex) else {
            return 0
        }
        return channels[zeroBasedChannel][frameIndex]
    }

    public func channel(index: Int) -> [Float] {
        let zeroBasedIndex = index - 1
        guard channels.indices.contains(zeroBasedIndex) else {
            return []
        }
        return channels[zeroBasedIndex]
    }
}

public struct MixedAudioBuffer: Hashable, Sendable {
    public var channels: [[Float]]

    public init(channels: [[Float]]) {
        self.channels = channels
    }

    public var frameCount: Int {
        channels.map(\.count).max() ?? 0
    }

    public func sample(channelIndex: Int, frameIndex: Int) -> Float {
        let zeroBasedChannel = channelIndex - 1
        guard zeroBasedChannel >= 0,
              channels.indices.contains(zeroBasedChannel),
              channels[zeroBasedChannel].indices.contains(frameIndex) else {
            return 0
        }
        return channels[zeroBasedChannel][frameIndex]
    }

    public func channel(index: Int) -> [Float] {
        let zeroBasedIndex = index - 1
        guard channels.indices.contains(zeroBasedIndex) else {
            return []
        }
        return channels[zeroBasedIndex]
    }
}

public struct MixReport: Hashable, Sendable {
    public var outputChannelCount: Int
    public var frameCount: Int
    public var activeRouteCount: Int
    public var missingSourceRouteCount: Int
    public var peakByOutputChannel: [Int: Float]
    public var peakBySourceID: [UUID: Float]
    public var peakByRouteID: [UUID: Float]

    public init(
        outputChannelCount: Int,
        frameCount: Int,
        activeRouteCount: Int,
        missingSourceRouteCount: Int,
        peakByOutputChannel: [Int: Float],
        peakBySourceID: [UUID: Float] = [:],
        peakByRouteID: [UUID: Float] = [:]
    ) {
        self.outputChannelCount = outputChannelCount
        self.frameCount = frameCount
        self.activeRouteCount = activeRouteCount
        self.missingSourceRouteCount = missingSourceRouteCount
        self.peakByOutputChannel = peakByOutputChannel
        self.peakBySourceID = peakBySourceID
        self.peakByRouteID = peakByRouteID
    }
}

public struct MixResult: Hashable, Sendable {
    public var buffer: MixedAudioBuffer
    public var report: MixReport

    public init(buffer: MixedAudioBuffer, report: MixReport) {
        self.buffer = buffer
        self.report = report
    }
}

public enum RoutingMixer {
    public static func mix(
        device: VirtualAudioDevice,
        sourceBuffers: [UUID: SourceAudioBuffer],
        frameCount requestedFrameCount: Int? = nil
    ) -> MixResult {
        let frameCount = max(
            0,
            requestedFrameCount ?? sourceBuffers.values.map(\.frameCount).max() ?? 0
        )
        var output = Array(
            repeating: Array(repeating: Float(0), count: frameCount),
            count: device.outputChannels.count
        )
        var activeRouteCount = 0
        var missingSourceRouteCount = 0
        var peakBySourceID: [UUID: Float] = [:]
        var peakByRouteID: [UUID: Float] = [:]

        guard device.isEnabled, !device.isMuted else {
            return result(output: output, activeRouteCount: 0, missingSourceRouteCount: 0)
        }

        for source in device.sources where source.isEnabled && !source.isMuted {
            guard let sourceBuffer = sourceBuffers[source.id] else {
                continue
            }

            peakBySourceID[source.id] = sourceBuffer.channels
                .flatMap { $0 }
                .reduce(Float(0)) { peak, sample in
                    max(peak, abs(sample * Float(source.gain)))
                }
        }

        for route in device.routes where !route.isMuted {
            guard let source = device.sources.first(where: { $0.id == route.sourceID }),
                  source.isEnabled,
                  !source.isMuted else {
                continue
            }

            guard let sourceBuffer = sourceBuffers[source.id] else {
                missingSourceRouteCount += 1
                continue
            }

            guard let outputArrayIndex = device.outputChannels.firstIndex(where: { $0.index == route.outputChannelIndex }) else {
                continue
            }

            activeRouteCount += 1
            let gain = Float(source.gain * route.gain * device.masterGain)
            var routePeak = Float(0)

            for frameIndex in 0..<frameCount {
                let sample = sourceBuffer.sample(
                    channelIndex: route.sourceChannelIndex,
                    frameIndex: frameIndex
                )
                let routedSample = sample * gain
                output[outputArrayIndex][frameIndex] += routedSample
                routePeak = max(routePeak, abs(routedSample))
            }

            peakByRouteID[route.id] = routePeak
        }

        return result(
            output: output,
            activeRouteCount: activeRouteCount,
            missingSourceRouteCount: missingSourceRouteCount,
            peakBySourceID: peakBySourceID,
            peakByRouteID: peakByRouteID
        )
    }

    private static func result(
        output: [[Float]],
        activeRouteCount: Int,
        missingSourceRouteCount: Int,
        peakBySourceID: [UUID: Float] = [:],
        peakByRouteID: [UUID: Float] = [:]
    ) -> MixResult {
        var peaks: [Int: Float] = [:]

        for (index, samples) in output.enumerated() {
            peaks[index + 1] = samples.reduce(Float(0)) { peak, sample in
                max(peak, abs(sample))
            }
        }

        let report = MixReport(
            outputChannelCount: output.count,
            frameCount: output.map(\.count).max() ?? 0,
            activeRouteCount: activeRouteCount,
            missingSourceRouteCount: missingSourceRouteCount,
            peakByOutputChannel: peaks,
            peakBySourceID: peakBySourceID,
            peakByRouteID: peakByRouteID
        )

        return MixResult(buffer: MixedAudioBuffer(channels: output), report: report)
    }
}
