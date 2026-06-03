import AudioToolbox
import CoreAudio
import Foundation

public struct HardwareInputCaptureConfiguration: Hashable, Sendable {
    public var sourceID: UUID
    public var deviceID: AudioDeviceID
    public var name: String
    public var channelCount: Int
    public var ringBufferCapacity: Int

    public init(
        sourceID: UUID,
        deviceID: AudioDeviceID,
        name: String,
        channelCount: Int,
        ringBufferCapacity: Int = 48_000
    ) {
        self.sourceID = sourceID
        self.deviceID = deviceID
        self.name = name
        self.channelCount = max(1, channelCount)
        self.ringBufferCapacity = ringBufferCapacity
    }
}

public struct HardwareInputCaptureState: Sendable {
    public var deviceID: AudioDeviceID
    public var ioProcID: AudioDeviceIOProcID?
    public var format: AudioStreamBasicDescription?
    public var isRunning: Bool
    public var ringBufferSnapshot: AudioRingBufferSnapshot

    public init(
        deviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID?,
        format: AudioStreamBasicDescription?,
        isRunning: Bool,
        ringBufferSnapshot: AudioRingBufferSnapshot
    ) {
        self.deviceID = deviceID
        self.ioProcID = ioProcID
        self.format = format
        self.isRunning = isRunning
        self.ringBufferSnapshot = ringBufferSnapshot
    }
}

public final class HardwareInputCaptureSession: @unchecked Sendable {
    public let configuration: HardwareInputCaptureConfiguration
    public let ringBuffer: AudioRingBuffer

    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false
    private let lock = NSLock()

    public init(configuration: HardwareInputCaptureConfiguration) {
        self.configuration = configuration
        self.ringBuffer = AudioRingBuffer(
            channelCount: configuration.channelCount,
            capacity: configuration.ringBufferCapacity
        )
    }

    deinit {
        try? stop()
        try? tearDown()
    }

    public func prepare() throws -> HardwareInputCaptureState {
        lock.lock()
        defer {
            lock.unlock()
        }

        if ioProcID == nil {
            ioProcID = try createIOProcID()
        }

        return currentStateLocked()
    }

    public func start() throws -> HardwareInputCaptureState {
        lock.lock()
        defer {
            lock.unlock()
        }

        if ioProcID == nil {
            ioProcID = try createIOProcID()
        }

        if !isRunning {
            let status = AudioDeviceStart(configuration.deviceID, ioProcID)
            guard status == noErr else {
                throw HardwareInputCaptureError.startFailed(status)
            }
            isRunning = true
        }

        return currentStateLocked()
    }

    public func stop() throws {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard isRunning else {
            return
        }

        let status = AudioDeviceStop(configuration.deviceID, ioProcID)
        guard status == noErr else {
            throw HardwareInputCaptureError.stopFailed(status)
        }

        isRunning = false
    }

    public func tearDown() throws {
        lock.lock()
        defer {
            lock.unlock()
        }

        if isRunning {
            let stopStatus = AudioDeviceStop(configuration.deviceID, ioProcID)
            guard stopStatus == noErr else {
                throw HardwareInputCaptureError.stopFailed(stopStatus)
            }
            isRunning = false
        }

        if let ioProcID {
            let status = AudioDeviceDestroyIOProcID(configuration.deviceID, ioProcID)
            guard status == noErr else {
                throw HardwareInputCaptureError.destroyIOProcFailed(status)
            }
            self.ioProcID = nil
        }

        ringBuffer.clear()
    }

    public func read(frameCount: Int) -> SourceAudioBuffer {
        ringBuffer.read(frameCount: frameCount, sourceID: configuration.sourceID)
    }

    public func snapshot() -> HardwareInputCaptureState? {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard ioProcID != nil else {
            return nil
        }

        return currentStateLocked()
    }

    private func createIOProcID() throws -> AudioDeviceIOProcID {
        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()
        var createdIOProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(
            configuration.deviceID,
            hardwareInputCaptureIOProc,
            unmanagedSelf,
            &createdIOProcID
        )

        guard status == noErr, let createdIOProcID else {
            throw HardwareInputCaptureError.createIOProcFailed(status)
        }

        return createdIOProcID
    }

    fileprivate func ingest(inputData: UnsafePointer<AudioBufferList>?, frameCount: Int) {
        guard let inputData, frameCount > 0 else {
            return
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        var channels = Array(
            repeating: Array(repeating: Float(0), count: frameCount),
            count: configuration.channelCount
        )
        var destinationChannelIndex = 0

        for buffer in bufferList {
            guard let data = buffer.mData else {
                destinationChannelIndex += Int(buffer.mNumberChannels)
                continue
            }

            let channelCount = Int(buffer.mNumberChannels)
            let samples = data.assumingMemoryBound(to: Float.self)

            if channelCount <= 1 {
                guard channels.indices.contains(destinationChannelIndex) else {
                    break
                }

                for frameIndex in 0..<frameCount {
                    channels[destinationChannelIndex][frameIndex] = samples[frameIndex]
                }
                destinationChannelIndex += 1
            } else {
                for channelOffset in 0..<channelCount {
                    let channelIndex = destinationChannelIndex + channelOffset
                    guard channels.indices.contains(channelIndex) else {
                        continue
                    }

                    for frameIndex in 0..<frameCount {
                        channels[channelIndex][frameIndex] = samples[frameIndex * channelCount + channelOffset]
                    }
                }
                destinationChannelIndex += channelCount
            }
        }

        ringBuffer.write(SourceAudioBuffer(
            sourceID: configuration.sourceID,
            channels: channels,
            sampleRate: inputStreamFormat(deviceID: configuration.deviceID)?.mSampleRate
        ))
    }

    private func currentStateLocked() -> HardwareInputCaptureState {
        HardwareInputCaptureState(
            deviceID: configuration.deviceID,
            ioProcID: ioProcID,
            format: inputStreamFormat(deviceID: configuration.deviceID),
            isRunning: isRunning,
            ringBufferSnapshot: ringBuffer.snapshot()
        )
    }
}

private let hardwareInputCaptureIOProc: AudioDeviceIOProc = {
    _,
    _,
    inputData,
    _,
    _,
    _,
    clientData in

    guard let clientData else {
        return noErr
    }

    let session = Unmanaged<HardwareInputCaptureSession>
        .fromOpaque(clientData)
        .takeUnretainedValue()
    let frameCount = audioBufferListFrameCount(inputData)
    session.ingest(inputData: inputData, frameCount: frameCount)
    return noErr
}

private func audioBufferListFrameCount(_ inputData: UnsafePointer<AudioBufferList>?) -> Int {
    guard let inputData, inputData.pointee.mNumberBuffers > 0 else {
        return 0
    }

    let buffer = inputData.pointee.mBuffers
    return Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / max(1, Int(buffer.mNumberChannels))
}

private func inputStreamFormat(deviceID: AudioDeviceID) -> AudioStreamBasicDescription? {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamFormat,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var format = AudioStreamBasicDescription()
    var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

    let status = AudioObjectGetPropertyData(
        deviceID,
        &propertyAddress,
        0,
        nil,
        &dataSize,
        &format
    )

    return status == noErr ? format : nil
}

public enum HardwareInputCaptureError: Error, CustomStringConvertible, Sendable {
    case createIOProcFailed(OSStatus)
    case destroyIOProcFailed(OSStatus)
    case startFailed(OSStatus)
    case stopFailed(OSStatus)

    public var description: String {
        switch self {
        case .createIOProcFailed(let status):
            return "AudioDeviceCreateIOProcID failed with OSStatus \(status)."
        case .destroyIOProcFailed(let status):
            return "AudioDeviceDestroyIOProcID failed with OSStatus \(status)."
        case .startFailed(let status):
            return "AudioDeviceStart failed with OSStatus \(status)."
        case .stopFailed(let status):
            return "AudioDeviceStop failed with OSStatus \(status)."
        }
    }
}
