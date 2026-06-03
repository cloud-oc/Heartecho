import AudioToolbox
import CoreAudio
import Foundation
import HeartechoCore

public struct ProcessTapCaptureConfiguration: Hashable, Sendable {
    public var sourceID: UUID
    public var processIdentifier: pid_t
    public var processIdentifiers: [pid_t]
    public var name: String
    public var ringBufferCapacity: Int
    public var muteBehavior: CATapMuteBehavior

    public init(
        sourceID: UUID,
        processIdentifier: pid_t,
        name: String,
        ringBufferCapacity: Int = 48_000,
        muteBehavior: CATapMuteBehavior = .unmuted
    ) {
        self.init(
            sourceID: sourceID,
            processIdentifiers: [processIdentifier],
            name: name,
            ringBufferCapacity: ringBufferCapacity,
            muteBehavior: muteBehavior
        )
    }

    public init(
        sourceID: UUID,
        processIdentifiers: [pid_t],
        name: String,
        ringBufferCapacity: Int = 48_000,
        muteBehavior: CATapMuteBehavior = .unmuted
    ) {
        self.sourceID = sourceID
        self.processIdentifiers = Array(
            Set(processIdentifiers.filter { $0 > 0 })
        ).sorted()
        self.processIdentifier = self.processIdentifiers.first ?? 0
        self.name = name
        self.ringBufferCapacity = ringBufferCapacity
        self.muteBehavior = muteBehavior
    }

    public init(
        applicationSource source: AudioSource,
        processIdentifier: pid_t,
        ringBufferCapacity: Int = 48_000
    ) {
        self.init(
            sourceID: source.id,
            processIdentifier: processIdentifier,
            name: source.name,
            ringBufferCapacity: ringBufferCapacity,
            muteBehavior: source.mutesWhenCaptured ? .mutedWhenTapped : .unmuted
        )
    }

    public init(
        applicationSource source: AudioSource,
        processIdentifiers: [pid_t],
        ringBufferCapacity: Int = 48_000
    ) {
        self.init(
            sourceID: source.id,
            processIdentifiers: processIdentifiers,
            name: source.name,
            ringBufferCapacity: ringBufferCapacity,
            muteBehavior: source.mutesWhenCaptured ? .mutedWhenTapped : .unmuted
        )
    }
}

public struct ProcessTapCaptureState: Sendable {
    public var tapID: AudioObjectID
    public var aggregateDeviceID: AudioObjectID
    public var ioProcID: AudioDeviceIOProcID?
    public var format: AudioStreamBasicDescription?
    public var isRunning: Bool
    public var ringBufferSnapshot: AudioRingBufferSnapshot

    public init(
        tapID: AudioObjectID,
        aggregateDeviceID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID?,
        format: AudioStreamBasicDescription?,
        isRunning: Bool,
        ringBufferSnapshot: AudioRingBufferSnapshot
    ) {
        self.tapID = tapID
        self.aggregateDeviceID = aggregateDeviceID
        self.ioProcID = ioProcID
        self.format = format
        self.isRunning = isRunning
        self.ringBufferSnapshot = ringBufferSnapshot
    }
}

public final class ProcessTapCaptureSession: @unchecked Sendable {
    public let configuration: ProcessTapCaptureConfiguration
    public let ringBuffer: AudioRingBuffer

    private let tapManager: CoreAudioProcessTapManager
    private var tapHandle: ProcessTapHandle?
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false
    private let lock = NSLock()

    public init(
        configuration: ProcessTapCaptureConfiguration,
        tapManager: CoreAudioProcessTapManager = CoreAudioProcessTapManager()
    ) {
        self.configuration = configuration
        self.tapManager = tapManager
        self.ringBuffer = AudioRingBuffer(channelCount: 2, capacity: configuration.ringBufferCapacity)
    }

    deinit {
        try? stop()
        try? tearDown()
    }

    public func prepare() throws -> ProcessTapCaptureState {
        lock.lock()
        defer {
            lock.unlock()
        }

        if tapHandle == nil {
            tapHandle = try tapManager.createStereoMixdownTap(
                processIdentifiers: configuration.processIdentifiers,
                name: configuration.name,
                muteBehavior: configuration.muteBehavior
            )
        }

        if aggregateDeviceID == kAudioObjectUnknown {
            aggregateDeviceID = try createAggregateDevice(tapID: requireTapHandle().tapID)
        }

        if ioProcID == nil {
            ioProcID = try createIOProcID(deviceID: aggregateDeviceID)
        }

        return currentStateLocked()
    }

    public func start() throws -> ProcessTapCaptureState {
        lock.lock()
        defer {
            lock.unlock()
        }

        if tapHandle == nil {
            tapHandle = try tapManager.createStereoMixdownTap(
                processIdentifiers: configuration.processIdentifiers,
                name: configuration.name,
                muteBehavior: configuration.muteBehavior
            )
        }

        if aggregateDeviceID == kAudioObjectUnknown {
            aggregateDeviceID = try createAggregateDevice(tapID: requireTapHandle().tapID)
        }

        if ioProcID == nil {
            ioProcID = try createIOProcID(deviceID: aggregateDeviceID)
        }

        if !isRunning {
            let status = AudioDeviceStart(aggregateDeviceID, ioProcID)
            guard status == noErr else {
                throw ProcessTapCaptureError.startFailed(status)
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

        let status = AudioDeviceStop(aggregateDeviceID, ioProcID)
        guard status == noErr else {
            throw ProcessTapCaptureError.stopFailed(status)
        }

        isRunning = false
    }

    public func tearDown() throws {
        lock.lock()
        defer {
            lock.unlock()
        }

        if isRunning {
            let stopStatus = AudioDeviceStop(aggregateDeviceID, ioProcID)
            guard stopStatus == noErr else {
                throw ProcessTapCaptureError.stopFailed(stopStatus)
            }
            isRunning = false
        }

        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            guard status == noErr else {
                throw ProcessTapCaptureError.destroyIOProcFailed(status)
            }
            self.ioProcID = nil
        }

        if aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            guard status == noErr else {
                throw ProcessTapCaptureError.destroyAggregateDeviceFailed(status)
            }
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if let tapHandle {
            try tapManager.destroyTap(tapHandle)
            self.tapHandle = nil
        }

        ringBuffer.clear()
    }

    public func read(frameCount: Int) -> SourceAudioBuffer {
        ringBuffer.read(frameCount: frameCount, sourceID: configuration.sourceID)
    }

    public func snapshot() -> ProcessTapCaptureState? {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard tapHandle != nil, aggregateDeviceID != kAudioObjectUnknown else {
            return nil
        }

        return currentStateLocked()
    }

    private func createAggregateDevice(tapID: AudioObjectID) throws -> AudioObjectID {
        guard let tapUID = tapManager.tapUID(tapID: tapID) else {
            throw ProcessTapCaptureError.tapUIDUnavailable
        }

        let uid = "com.heartecho.Heartecho.ProcessTap.\(configuration.sourceID.uuidString)"
        let tapDescription: [String: Any] = [
            String(kAudioSubTapUIDKey): tapUID,
            String(kAudioSubTapDriftCompensationKey): true
        ]
        let aggregateDescription: [String: Any] = [
            String(kAudioAggregateDeviceUIDKey): uid,
            String(kAudioAggregateDeviceNameKey): "\(configuration.name) Capture",
            String(kAudioAggregateDeviceIsPrivateKey): true,
            String(kAudioAggregateDeviceTapListKey): [tapDescription],
            String(kAudioAggregateDeviceTapAutoStartKey): true
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateID
        )

        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            throw ProcessTapCaptureError.createAggregateDeviceFailed(status)
        }

        return aggregateID
    }

    private func createIOProcID(deviceID: AudioObjectID) throws -> AudioDeviceIOProcID {
        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()
        var createdIOProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(
            deviceID,
            processTapCaptureIOProc,
            unmanagedSelf,
            &createdIOProcID
        )

        guard status == noErr, let createdIOProcID else {
            throw ProcessTapCaptureError.createIOProcFailed(status)
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
            count: max(1, bufferList.reduce(0) { $0 + Int($1.mNumberChannels) })
        )
        var destinationChannelIndex = 0

        for buffer in bufferList {
            guard let data = buffer.mData else {
                destinationChannelIndex += Int(buffer.mNumberChannels)
                continue
            }

            let samples = data.assumingMemoryBound(to: Float.self)

            if buffer.mNumberChannels <= 1 {
                for frameIndex in 0..<frameCount {
                    channels[destinationChannelIndex][frameIndex] = samples[frameIndex]
                }
                destinationChannelIndex += 1
            } else {
                for channelOffset in 0..<Int(buffer.mNumberChannels) {
                    for frameIndex in 0..<frameCount {
                        channels[destinationChannelIndex + channelOffset][frameIndex] =
                            samples[frameIndex * Int(buffer.mNumberChannels) + channelOffset]
                    }
                }
                destinationChannelIndex += Int(buffer.mNumberChannels)
            }
        }

        ringBuffer.write(SourceAudioBuffer(
            sourceID: configuration.sourceID,
            channels: channels,
            sampleRate: tapHandle?.format?.mSampleRate
        ))
    }

    private func requireTapHandle() throws -> ProcessTapHandle {
        guard let tapHandle else {
            throw ProcessTapCaptureError.notPrepared
        }
        return tapHandle
    }

    private func currentStateLocked() -> ProcessTapCaptureState {
        let handle = tapHandle
        return ProcessTapCaptureState(
            tapID: handle?.tapID ?? AudioObjectID(kAudioObjectUnknown),
            aggregateDeviceID: aggregateDeviceID,
            ioProcID: ioProcID,
            format: handle?.format ?? tapManager.tapFormat(tapID: handle?.tapID ?? AudioObjectID(kAudioObjectUnknown)),
            isRunning: isRunning,
            ringBufferSnapshot: ringBuffer.snapshot()
        )
    }
}

private let processTapCaptureIOProc: AudioDeviceIOProc = {
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

    let session = Unmanaged<ProcessTapCaptureSession>
        .fromOpaque(clientData)
        .takeUnretainedValue()
    let frameCount = inputData.pointee.mNumberBuffers > 0
        ? Int(inputData.pointee.mBuffers.mDataByteSize) / MemoryLayout<Float>.size / max(1, Int(inputData.pointee.mBuffers.mNumberChannels))
        : 0
    session.ingest(inputData: inputData, frameCount: frameCount)
    return noErr
}

public enum ProcessTapCaptureError: Error, CustomStringConvertible, Sendable {
    case notPrepared
    case tapUIDUnavailable
    case createAggregateDeviceFailed(OSStatus)
    case destroyAggregateDeviceFailed(OSStatus)
    case createIOProcFailed(OSStatus)
    case destroyIOProcFailed(OSStatus)
    case startFailed(OSStatus)
    case stopFailed(OSStatus)

    public var description: String {
        switch self {
        case .notPrepared:
            return "The process tap capture session is not prepared."
        case .tapUIDUnavailable:
            return "The process tap did not expose a UID."
        case .createAggregateDeviceFailed(let status):
            return "AudioHardwareCreateAggregateDevice failed with OSStatus \(status)."
        case .destroyAggregateDeviceFailed(let status):
            return "AudioHardwareDestroyAggregateDevice failed with OSStatus \(status)."
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
