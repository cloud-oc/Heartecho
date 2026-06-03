import AudioToolbox
import CoreAudio
import Foundation

public final class CoreAudioDeviceDiscovery: Sendable {
    public init() {}

    public func allDevices() -> [SystemAudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(), count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else {
            return []
        }

        return deviceIDs.compactMap(device)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func device(from id: AudioDeviceID) -> SystemAudioDevice? {
        let inputChannels = channelCount(for: id, scope: kAudioDevicePropertyScopeInput)
        let outputChannels = channelCount(for: id, scope: kAudioDevicePropertyScopeOutput)
        let direction: SystemAudioDevice.Direction

        switch (inputChannels > 0, outputChannels > 0) {
        case (true, true):
            direction = .duplex
        case (true, false):
            direction = .input
        case (false, true):
            direction = .output
        default:
            direction = .unknown
        }

        return SystemAudioDevice(
            id: String(id),
            audioObjectID: id,
            uid: stringProperty(id: id, selector: kAudioDevicePropertyDeviceUID),
            name: stringProperty(id: id, selector: kAudioObjectPropertyName) ?? "Device \(id)",
            manufacturer: stringProperty(id: id, selector: kAudioObjectPropertyManufacturer) ?? "Unknown",
            direction: direction,
            channelCount: max(inputChannels, outputChannels)
        )
    }

    private func stringProperty(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        var value: Unmanaged<CFString>?

        let status = AudioObjectGetPropertyData(
            id,
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

    private func channelCount(for id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        let sizeStatus = AudioObjectGetPropertyDataSize(id, &propertyAddress, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else {
            return 0
        }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        defer {
            rawBufferList.deallocate()
        }

        let dataStatus = AudioObjectGetPropertyData(
            id,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            audioBufferList
        )

        guard dataStatus == noErr else {
            return 0
        }

        return UnsafeMutableAudioBufferListPointer(audioBufferList).reduce(0) { count, buffer in
            count + Int(buffer.mNumberChannels)
        }
    }
}
