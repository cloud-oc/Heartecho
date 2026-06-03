import Foundation

public enum AudioSampleRateConversionQuality: String, Codable, Hashable, Sendable {
    case linear
    case balanced
    case mastering

    var usesWindowedSinc: Bool {
        self != .linear
    }

    var kernelRadius: Int {
        switch self {
        case .linear:
            return 1
        case .balanced:
            return 12
        case .mastering:
            return 24
        }
    }

    var cutoffHeadroom: Double {
        switch self {
        case .linear:
            return 1
        case .balanced:
            return 0.94
        case .mastering:
            return 0.98
        }
    }
}

public struct AudioResamplingReport: Hashable, Sendable {
    public var sourceID: UUID
    public var sourceSampleRate: Double
    public var targetSampleRate: Double
    public var effectiveSourceSampleRate: Double
    public var inputFrameCount: Int
    public var outputFrameCount: Int
    public var ratio: Double
    public var driftCorrection: Double
    public var driftCorrectionPPM: Double
    public var inputPhase: Double
    public var nextInputPhase: Double
    public var quality: AudioSampleRateConversionQuality

    public init(
        sourceID: UUID,
        sourceSampleRate: Double,
        targetSampleRate: Double,
        effectiveSourceSampleRate: Double,
        inputFrameCount: Int,
        outputFrameCount: Int,
        ratio: Double,
        driftCorrection: Double = 0,
        driftCorrectionPPM: Double = 0,
        inputPhase: Double = 0,
        nextInputPhase: Double = 0,
        quality: AudioSampleRateConversionQuality = .balanced
    ) {
        self.sourceID = sourceID
        self.sourceSampleRate = sourceSampleRate
        self.targetSampleRate = targetSampleRate
        self.effectiveSourceSampleRate = effectiveSourceSampleRate
        self.inputFrameCount = inputFrameCount
        self.outputFrameCount = outputFrameCount
        self.ratio = ratio
        self.driftCorrection = driftCorrection
        self.driftCorrectionPPM = driftCorrectionPPM
        self.inputPhase = inputPhase
        self.nextInputPhase = nextInputPhase
        self.quality = quality
    }
}

public struct AudioResamplingState: Hashable, Sendable {
    public var inputPhase: Double

    public init(inputPhase: Double = 0) {
        self.inputPhase = max(0, inputPhase)
    }
}

public struct AudioDriftCorrection: Hashable, Sendable {
    public var targetBufferedFrameCount: Int
    public var availableFrameCount: Int
    public var correction: Double
    public var correctionPPM: Double

    public init(
        targetBufferedFrameCount: Int,
        availableFrameCount: Int,
        correction: Double,
        correctionPPM: Double
    ) {
        self.targetBufferedFrameCount = max(0, targetBufferedFrameCount)
        self.availableFrameCount = max(0, availableFrameCount)
        self.correction = correction
        self.correctionPPM = correctionPPM
    }
}

public enum AudioDriftController {
    public static func correction(
        availableFrameCount: Int?,
        targetBufferedFrameCount: Int,
        maxCorrectionPPM: Double = 100
    ) -> AudioDriftCorrection? {
        guard let availableFrameCount else {
            return nil
        }

        let safeTarget = max(1, targetBufferedFrameCount)
        let errorFrames = availableFrameCount - safeTarget
        guard errorFrames != 0 else {
            return AudioDriftCorrection(
                targetBufferedFrameCount: safeTarget,
                availableFrameCount: availableFrameCount,
                correction: 0,
                correctionPPM: 0
            )
        }

        let normalizedError = Double(errorFrames) / Double(safeTarget)
        let boundedPPM = max(-abs(maxCorrectionPPM), min(abs(maxCorrectionPPM), normalizedError * abs(maxCorrectionPPM)))
        return AudioDriftCorrection(
            targetBufferedFrameCount: safeTarget,
            availableFrameCount: availableFrameCount,
            correction: boundedPPM / 1_000_000,
            correctionPPM: boundedPPM
        )
    }
}

public enum AudioSampleRateConverter {
    public static func needsConversion(
        sourceSampleRate: Double?,
        targetSampleRate: Double,
        tolerance: Double = 0.01
    ) -> Bool {
        guard let sourceSampleRate, sourceSampleRate > 0, targetSampleRate > 0 else {
            return false
        }

        return abs(sourceSampleRate - targetSampleRate) > tolerance
    }

    public static func convert(
        _ buffer: SourceAudioBuffer,
        targetSampleRate: Double,
        targetFrameCount: Int,
        quality: AudioSampleRateConversionQuality = .balanced,
        driftCorrection: AudioDriftCorrection? = nil
    ) -> (buffer: SourceAudioBuffer, report: AudioResamplingReport?) {
        var state = AudioResamplingState()
        let result = convert(
            buffer,
            targetSampleRate: targetSampleRate,
            targetFrameCount: targetFrameCount,
            quality: quality,
            driftCorrection: driftCorrection,
            state: &state
        )
        return (result.buffer, result.report)
    }

    public static func convert(
        _ buffer: SourceAudioBuffer,
        targetSampleRate: Double,
        targetFrameCount: Int,
        quality: AudioSampleRateConversionQuality = .balanced,
        driftCorrection: AudioDriftCorrection? = nil,
        state: inout AudioResamplingState
    ) -> (buffer: SourceAudioBuffer, report: AudioResamplingReport?) {
        guard let sourceSampleRate = buffer.sampleRate,
              needsConversion(sourceSampleRate: sourceSampleRate, targetSampleRate: targetSampleRate) || driftCorrection != nil else {
            state.inputPhase = 0
            return (buffer, nil)
        }

        let outputFrameCount = max(0, targetFrameCount)
        let correction = driftCorrection?.correction ?? 0
        let effectiveSourceSampleRate = sourceSampleRate * (1 + correction)
        let inputPhase = min(state.inputPhase, max(0, Double(max(0, buffer.frameCount - 1))))
        let convertedChannels = buffer.channels.map { samples in
            resample(
                samples: samples,
                sourceSampleRate: effectiveSourceSampleRate,
                targetSampleRate: targetSampleRate,
                outputFrameCount: outputFrameCount,
                inputPhase: inputPhase,
                quality: quality
            )
        }
        let sourceFramesPerTargetFrame = effectiveSourceSampleRate / targetSampleRate
        let consumedSourceFrames = Double(outputFrameCount) * sourceFramesPerTargetFrame
        let nextInputPhase = max(0, inputPhase + consumedSourceFrames - Double(max(0, buffer.frameCount)))
        state.inputPhase = nextInputPhase

        let report = AudioResamplingReport(
            sourceID: buffer.sourceID,
            sourceSampleRate: sourceSampleRate,
            targetSampleRate: targetSampleRate,
            effectiveSourceSampleRate: effectiveSourceSampleRate,
            inputFrameCount: buffer.frameCount,
            outputFrameCount: outputFrameCount,
            ratio: effectiveSourceSampleRate / targetSampleRate,
            driftCorrection: correction,
            driftCorrectionPPM: driftCorrection?.correctionPPM ?? 0,
            inputPhase: inputPhase,
            nextInputPhase: nextInputPhase,
            quality: quality
        )

        return (
            SourceAudioBuffer(sourceID: buffer.sourceID, channels: convertedChannels, sampleRate: targetSampleRate),
            report
        )
    }

    private static func resample(
        samples: [Float],
        sourceSampleRate: Double,
        targetSampleRate: Double,
        outputFrameCount: Int,
        inputPhase: Double,
        quality: AudioSampleRateConversionQuality
    ) -> [Float] {
        guard outputFrameCount > 0 else {
            return []
        }

        guard !samples.isEmpty else {
            return Array(repeating: 0, count: outputFrameCount)
        }

        guard samples.count > 1 else {
            return Array(repeating: samples[0], count: outputFrameCount)
        }

        if quality.usesWindowedSinc {
            return windowedSincResample(
                samples: samples,
                sourceSampleRate: sourceSampleRate,
                targetSampleRate: targetSampleRate,
                outputFrameCount: outputFrameCount,
                inputPhase: inputPhase,
                quality: quality
            )
        }

        let sourceFramesPerTargetFrame = sourceSampleRate / targetSampleRate
        return (0..<outputFrameCount).map { outputFrameIndex in
            let sourcePosition = inputPhase + Double(outputFrameIndex) * sourceFramesPerTargetFrame
            let lowerIndex = min(samples.count - 1, max(0, Int(sourcePosition.rounded(.down))))
            let upperIndex = min(samples.count - 1, lowerIndex + 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))

            if lowerIndex == upperIndex {
                return samples[lowerIndex]
            }

            return samples[lowerIndex] + (samples[upperIndex] - samples[lowerIndex]) * fraction
        }
    }

    private static func windowedSincResample(
        samples: [Float],
        sourceSampleRate: Double,
        targetSampleRate: Double,
        outputFrameCount: Int,
        inputPhase: Double,
        quality: AudioSampleRateConversionQuality
    ) -> [Float] {
        let sourceFramesPerTargetFrame = sourceSampleRate / targetSampleRate
        let cutoff = min(1, targetSampleRate / max(sourceSampleRate, .leastNonzeroMagnitude)) * quality.cutoffHeadroom
        let radius = quality.kernelRadius

        return (0..<outputFrameCount).map { outputFrameIndex in
            let sourcePosition = inputPhase + Double(outputFrameIndex) * sourceFramesPerTargetFrame
            let centerIndex = Int(sourcePosition.rounded(.down))
            var weightedSample = Double(0)
            var weightSum = Double(0)

            for tapIndex in (centerIndex - radius + 1)...(centerIndex + radius) {
                let distance = sourcePosition - Double(tapIndex)
                let window = blackmanWindow(distance: distance, radius: radius)
                guard window > 0 else {
                    continue
                }

                let weight = normalizedSinc(distance * cutoff) * cutoff * window
                let clampedIndex = min(samples.count - 1, max(0, tapIndex))
                weightedSample += Double(samples[clampedIndex]) * weight
                weightSum += weight
            }

            guard abs(weightSum) > .leastNonzeroMagnitude else {
                return 0
            }

            return Float(weightedSample / weightSum)
        }
    }

    private static func normalizedSinc(_ x: Double) -> Double {
        guard abs(x) >= 1.0e-8 else {
            return 1
        }

        let argument = Double.pi * x
        return sin(argument) / argument
    }

    private static func blackmanWindow(distance: Double, radius: Int) -> Double {
        guard radius > 0 else {
            return 1
        }

        let normalizedDistance = abs(distance) / Double(radius)
        guard normalizedDistance < 1 else {
            return 0
        }

        return 0.42 + 0.5 * cos(Double.pi * normalizedDistance) + 0.08 * cos(2 * Double.pi * normalizedDistance)
    }
}
