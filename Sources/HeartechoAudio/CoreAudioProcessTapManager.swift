import AudioToolbox
import CoreAudio
import Foundation

public struct ProcessTapCapability: Hashable, Sendable {
    public var isSupported: Bool
    public var reason: String

    public init(isSupported: Bool, reason: String) {
        self.isSupported = isSupported
        self.reason = reason
    }
}

public struct ProcessTapHandle: Sendable {
    public var tapID: AudioObjectID
    public var processObjectID: AudioObjectID
    public var processObjectIDs: [AudioObjectID]
    public var processIdentifier: pid_t
    public var processIdentifiers: [pid_t]
    public var format: AudioStreamBasicDescription?

    public init(
        tapID: AudioObjectID,
        processObjectID: AudioObjectID,
        processObjectIDs: [AudioObjectID]? = nil,
        processIdentifier: pid_t,
        processIdentifiers: [pid_t]? = nil,
        format: AudioStreamBasicDescription?
    ) {
        self.tapID = tapID
        self.processObjectID = processObjectID
        self.processObjectIDs = processObjectIDs ?? [processObjectID]
        self.processIdentifier = processIdentifier
        self.processIdentifiers = processIdentifiers ?? [processIdentifier]
        self.format = format
    }
}

public final class CoreAudioProcessTapManager: Sendable {
    public init() {}

    public var capability: ProcessTapCapability {
        if #available(macOS 14.2, *) {
            return ProcessTapCapability(
                isSupported: true,
                reason: "Core Audio process taps are available on this macOS version."
            )
        } else {
            return ProcessTapCapability(
                isSupported: false,
                reason: "Core Audio process taps require macOS 14.2 or newer."
            )
        }
    }

    public func processObjectID(for processIdentifier: pid_t) -> AudioObjectID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = processIdentifier
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &dataSize,
            &processObjectID
        )

        guard status == noErr, processObjectID != kAudioObjectUnknown else {
            return nil
        }

        return processObjectID
    }

    public func isProcessRunningOutput(processObjectID: AudioObjectID) -> Bool {
        boolProperty(
            objectID: processObjectID,
            selector: kAudioProcessPropertyIsRunningOutput
        )
    }

    public func createStereoMixdownTap(
        processIdentifier: pid_t,
        name: String,
        muteBehavior: CATapMuteBehavior = .unmuted
    ) throws -> ProcessTapHandle {
        try createStereoMixdownTap(
            processIdentifiers: [processIdentifier],
            name: name,
            muteBehavior: muteBehavior
        )
    }

    public func createStereoMixdownTap(
        processIdentifiers: [pid_t],
        name: String,
        muteBehavior: CATapMuteBehavior = .unmuted
    ) throws -> ProcessTapHandle {
        guard #available(macOS 14.2, *) else {
            throw ProcessTapError.unsupportedOS
        }

        let uniqueProcessIdentifiers = Array(Set(processIdentifiers.filter { $0 > 0 })).sorted()
        let processObjectIDs = uniqueProcessIdentifiers.compactMap { processObjectID(for: $0) }
        guard let processObjectID = processObjectIDs.first else {
            throw ProcessTapError.processObjectUnavailable(uniqueProcessIdentifiers.first ?? 0)
        }

        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.name = name
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = muteBehavior

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)

        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw ProcessTapError.createFailed(status)
        }

        return ProcessTapHandle(
            tapID: tapID,
            processObjectID: processObjectID,
            processObjectIDs: processObjectIDs,
            processIdentifier: uniqueProcessIdentifiers.first ?? 0,
            processIdentifiers: uniqueProcessIdentifiers,
            format: tapFormat(tapID: tapID)
        )
    }

    public func destroyTap(_ handle: ProcessTapHandle) throws {
        guard #available(macOS 14.2, *) else {
            throw ProcessTapError.unsupportedOS
        }

        let status = AudioHardwareDestroyProcessTap(handle.tapID)
        guard status == noErr else {
            throw ProcessTapError.destroyFailed(status)
        }
    }

    public func tapFormat(tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let status = AudioObjectGetPropertyData(
            tapID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &format
        )

        guard status == noErr else {
            return nil
        }

        return format
    }

    public func tapUID(tapID: AudioObjectID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        var value: Unmanaged<CFString>?

        let status = AudioObjectGetPropertyData(
            tapID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &value
        )

        guard status == noErr else {
            return nil
        }

        return value?.takeRetainedValue() as String?
    }

    private func boolProperty(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            objectID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &value
        )

        guard status == noErr else {
            return false
        }

        return value != 0
    }
}

public enum ProcessTapError: Error, CustomStringConvertible, Sendable {
    case unsupportedOS
    case processObjectUnavailable(pid_t)
    case createFailed(OSStatus)
    case destroyFailed(OSStatus)

    public var description: String {
        switch self {
        case .unsupportedOS:
            return "Core Audio process taps require macOS 14.2 or newer."
        case .processObjectUnavailable(let pid):
            return "No Core Audio process object is available for pid \(pid)."
        case .createFailed(let status):
            return "AudioHardwareCreateProcessTap failed with OSStatus \(status)."
        case .destroyFailed(let status):
            return "AudioHardwareDestroyProcessTap failed with OSStatus \(status)."
        }
    }
}
