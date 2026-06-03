import CoreAudio
import Foundation
import HALDriverC
import HeartechoCore

public enum HALDriverBridge {
    public static let bundleIdentifier = "com.heartecho.Heartecho.Driver"
    public static let defaultSharedMemoryName = "/HeartechoHALSharedConfig"

    public static func validateRuntimeGraph(_ graph: RoutingGraph) -> Bool {
        graph.devices.allSatisfy { device in
            RoutingGraphValidator.validate(device: device).allSatisfy { $0.severity != .error }
        }
    }

    public static func runtimeConfiguration(from graph: RoutingGraph) throws -> HALRuntimeConfiguration {
        guard validateRuntimeGraph(graph) else {
            throw HALRuntimeConfigurationError.invalidGraph
        }

        return HALRuntimeConfiguration(
            bundleIdentifier: bundleIdentifier,
            devices: graph.devices.map { device in
                HALRuntimeDeviceConfiguration(
                    id: device.id,
                    name: device.name,
                    uid: "\(bundleIdentifier).\(device.id.uuidString)",
                    sampleRate: device.sampleRate,
                    channelCount: device.outputChannels.count,
                    latencyFrames: device.latencyFrames,
                    safetyOffsetFrames: device.safetyOffsetFrames,
                    bufferFrameSize: device.bufferFrameSize,
                    isEnabled: device.isEnabled
                )
            }
        )
    }

    public static func sharedConfigurationData(from graph: RoutingGraph) throws -> Data {
        try sharedConfigurationData(from: runtimeConfiguration(from: graph))
    }

    public static func sharedConfigurationData(from configuration: HALRuntimeConfiguration) throws -> Data {
        guard configuration.devices.count <= HALSharedConfigLayout.maxDevices else {
            throw HALRuntimeConfigurationError.tooManyDevices(
                count: configuration.devices.count,
                maximum: HALSharedConfigLayout.maxDevices
            )
        }

        var data = Data()
        data.reserveCapacity(HALSharedConfigLayout.totalByteCount)
        data.appendLittleEndian(UInt32(HALSharedConfigLayout.magic))
        data.appendLittleEndian(UInt16(HALSharedConfigLayout.version))
        data.appendLittleEndian(UInt16(HALSharedConfigLayout.headerByteCount))
        data.appendLittleEndian(UInt16(HALSharedConfigLayout.deviceByteCount))
        data.appendLittleEndian(UInt16(configuration.devices.count))
        data.appendLittleEndian(UInt32(HALSharedConfigLayout.maxDevices))
        data.appendZeroes(count: 16)

        for (index, device) in configuration.devices.enumerated() {
            try appendSharedDevice(device, index: index, to: &data)
        }

        let missingDeviceSlots = HALSharedConfigLayout.maxDevices - configuration.devices.count
        if missingDeviceSlots > 0 {
            data.appendZeroes(count: missingDeviceSlots * HALSharedConfigLayout.deviceByteCount)
        }

        guard data.count == HALSharedConfigLayout.totalByteCount else {
            throw HALRuntimeConfigurationError.invalidSharedConfigSize(
                expected: HALSharedConfigLayout.totalByteCount,
                actual: data.count
            )
        }

        return data
    }

    private static func appendSharedDevice(
        _ device: HALRuntimeDeviceConfiguration,
        index: Int,
        to data: inout Data
    ) throws {
        guard device.channelCount >= 1, device.channelCount <= HALSharedConfigLayout.maxChannels else {
            throw HALRuntimeConfigurationError.invalidChannelCount(
                deviceName: device.name,
                channelCount: device.channelCount,
                maximum: HALSharedConfigLayout.maxChannels
            )
        }

        let objectID = HALSharedConfigLayout.deviceObjectID(for: index)
        data.appendLittleEndian(objectID)
        data.appendLittleEndian(objectID + 1)
        data.appendLittleEndian(objectID + 2)
        data.appendLittleEndian(UInt32(device.channelCount))
        data.appendLittleEndianDouble(device.sampleRate)
        data.append(device.isEnabled ? 1 : 0)
        data.append(0)
        data.appendLittleEndian(UInt16(clamping: device.latencyFrames))
        data.appendLittleEndian(UInt16(clamping: device.safetyOffsetFrames))
        data.appendLittleEndian(UInt16(clamping: device.bufferFrameSize))
        data.appendFixedUTF8(device.name, byteCount: HALSharedConfigLayout.maxNameBytes)
        data.appendFixedUTF8(device.uid, byteCount: HALSharedConfigLayout.maxUIDBytes)
    }

    public static func decodeSharedConfigurationData(_ data: Data) throws -> HALSharedConfigSnapshot {
        try HALSharedConfigSnapshot(data: data)
    }

    public static func publishSharedConfiguration(
        _ configuration: HALRuntimeConfiguration,
        sharedMemoryName: String = defaultSharedMemoryName
    ) throws -> HALSharedMemoryPublication {
        let data = try sharedConfigurationData(from: configuration)
        return try HALSharedMemoryPublication.publish(data: data, name: sharedMemoryName)
    }

    public static func publishSharedConfiguration(
        from graph: RoutingGraph,
        sharedMemoryName: String = defaultSharedMemoryName
    ) throws -> HALSharedMemoryPublication {
        try publishSharedConfiguration(
            runtimeConfiguration(from: graph),
            sharedMemoryName: sharedMemoryName
        )
    }
}

public enum HALSharedConfigLayout {
    public static let magic: UInt32 = 0x4353_4548
    public static let version = 1
    public static let maxDevices = 16
    public static let maxChannels = 64
    public static let maxNameBytes = 96
    public static let maxUIDBytes = 128
    public static let headerByteCount = 32
    public static let deviceByteCount = 256
    public static let objectIDBase: UInt32 = 2
    public static let objectIDStride: UInt32 = 3
    public static let totalByteCount = headerByteCount + deviceByteCount * maxDevices

    public static func deviceObjectID(for index: Int) -> UInt32 {
        objectIDBase + UInt32(index) * objectIDStride
    }
}

public struct HALSharedConfigSnapshot: Hashable, Sendable {
    public var magic: UInt32
    public var version: UInt16
    public var headerByteCount: UInt16
    public var deviceByteCount: UInt16
    public var deviceCount: UInt16
    public var maxDevices: UInt32
    public var devices: [HALSharedDeviceSnapshot]

    public init(data: Data) throws {
        guard data.count == HALSharedConfigLayout.totalByteCount else {
            throw HALRuntimeConfigurationError.invalidSharedConfigSize(
                expected: HALSharedConfigLayout.totalByteCount,
                actual: data.count
            )
        }

        magic = try data.readLittleEndian(UInt32.self, at: 0)
        version = try data.readLittleEndian(UInt16.self, at: 4)
        headerByteCount = try data.readLittleEndian(UInt16.self, at: 6)
        deviceByteCount = try data.readLittleEndian(UInt16.self, at: 8)
        deviceCount = try data.readLittleEndian(UInt16.self, at: 10)
        maxDevices = try data.readLittleEndian(UInt32.self, at: 12)

        guard magic == HALSharedConfigLayout.magic,
              version == HALSharedConfigLayout.version,
              headerByteCount == HALSharedConfigLayout.headerByteCount,
              deviceByteCount == HALSharedConfigLayout.deviceByteCount,
              maxDevices == HALSharedConfigLayout.maxDevices,
              deviceCount <= HALSharedConfigLayout.maxDevices else {
            throw HALRuntimeConfigurationError.invalidSharedConfigHeader
        }

        devices = try (0..<Int(deviceCount)).map { index in
            let offset = HALSharedConfigLayout.headerByteCount + index * HALSharedConfigLayout.deviceByteCount
            return try HALSharedDeviceSnapshot(data: data, offset: offset)
        }
    }
}

public struct HALSharedDeviceSnapshot: Hashable, Sendable {
    public var deviceObjectID: UInt32
    public var inputStreamObjectID: UInt32
    public var outputStreamObjectID: UInt32
    public var channelCount: UInt32
    public var sampleRate: Double
    public var isEnabled: Bool
    public var latencyFrames: UInt16
    public var safetyOffsetFrames: UInt16
    public var bufferFrameSize: UInt16
    public var name: String
    public var uid: String

    fileprivate init(data: Data, offset: Int) throws {
        deviceObjectID = try data.readLittleEndian(UInt32.self, at: offset)
        inputStreamObjectID = try data.readLittleEndian(UInt32.self, at: offset + 4)
        outputStreamObjectID = try data.readLittleEndian(UInt32.self, at: offset + 8)
        channelCount = try data.readLittleEndian(UInt32.self, at: offset + 12)
        sampleRate = try data.readLittleEndianDouble(at: offset + 16)
        isEnabled = try data.readByte(at: offset + 24) != 0
        latencyFrames = try data.readLittleEndian(UInt16.self, at: offset + 26)
        safetyOffsetFrames = try data.readLittleEndian(UInt16.self, at: offset + 28)
        bufferFrameSize = try data.readLittleEndian(UInt16.self, at: offset + 30)
        name = try data.readFixedUTF8(at: offset + 32, byteCount: HALSharedConfigLayout.maxNameBytes)
        uid = try data.readFixedUTF8(at: offset + 128, byteCount: HALSharedConfigLayout.maxUIDBytes)
    }
}

public struct HALSharedMemoryPublication: Hashable, Sendable {
    public var name: String
    public var byteCount: Int

    public static func publish(data: Data, name: String) throws -> HALSharedMemoryPublication {
        guard name.hasPrefix("/"), name.utf8.count > 1 else {
            throw HALRuntimeConfigurationError.invalidSharedMemoryName(name)
        }

        guard data.count == HALSharedConfigLayout.totalByteCount else {
            throw HALRuntimeConfigurationError.invalidSharedConfigSize(
                expected: HALSharedConfigLayout.totalByteCount,
                actual: data.count
            )
        }

        let result = try name.withCString { rawName in
            let published = data.withUnsafeBytes { bytes in
                HeartechoHALDriverPublishSharedConfigToSharedMemory(
                    rawName,
                    bytes.baseAddress,
                    data.count
                )
            }
            guard published else {
                throw HALRuntimeConfigurationError.sharedMemoryOpenFailed(name: name, errno: errno)
            }
            return HALSharedMemoryPublication(name: name, byteCount: data.count)
        }

        return result
    }

    public static func unlink(name: String) {
        name.withCString { rawName in
            _ = HeartechoHALDriverUnlinkSharedMemory(rawName)
        }
    }
}

public struct HALRuntimeConfiguration: Codable, Hashable, Sendable {
    public var bundleIdentifier: String
    public var devices: [HALRuntimeDeviceConfiguration]

    public init(bundleIdentifier: String, devices: [HALRuntimeDeviceConfiguration]) {
        self.bundleIdentifier = bundleIdentifier
        self.devices = devices
    }
}

public struct HALRuntimeDeviceConfiguration: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var uid: String
    public var sampleRate: Double
    public var channelCount: Int
    public var latencyFrames: Int
    public var safetyOffsetFrames: Int
    public var bufferFrameSize: Int
    public var isEnabled: Bool

    public init(
        id: UUID,
        name: String,
        uid: String,
        sampleRate: Double,
        channelCount: Int,
        latencyFrames: Int = 0,
        safetyOffsetFrames: Int = 0,
        bufferFrameSize: Int = 512,
        isEnabled: Bool
    ) {
        self.id = id
        self.name = name
        self.uid = uid
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.latencyFrames = max(0, latencyFrames)
        self.safetyOffsetFrames = max(0, safetyOffsetFrames)
        self.bufferFrameSize = max(16, bufferFrameSize)
        self.isEnabled = isEnabled
    }
}

public enum HALRuntimeConfigurationError: Error, CustomStringConvertible, Sendable {
    case invalidGraph
    case tooManyDevices(count: Int, maximum: Int)
    case invalidChannelCount(deviceName: String, channelCount: Int, maximum: Int)
    case invalidSharedConfigHeader
    case invalidSharedConfigSize(expected: Int, actual: Int)
    case invalidSharedConfigRead(offset: Int, byteCount: Int, dataSize: Int)
    case invalidSharedConfigString(offset: Int, byteCount: Int)
    case invalidSharedMemoryName(String)
    case sharedMemoryOpenFailed(name: String, errno: Int32)

    public var description: String {
        switch self {
        case .invalidGraph:
            return "The routing graph cannot be converted into a HAL runtime configuration."
        case let .tooManyDevices(count, maximum):
            return "The HAL shared configuration supports \(maximum) devices, but \(count) were provided."
        case let .invalidChannelCount(deviceName, channelCount, maximum):
            return "\(deviceName) has \(channelCount) channels; HAL shared configuration supports 1...\(maximum)."
        case .invalidSharedConfigHeader:
            return "The HAL shared configuration header does not match the expected ABI."
        case let .invalidSharedConfigSize(expected, actual):
            return "The HAL shared configuration is \(actual) bytes; expected \(expected) bytes."
        case let .invalidSharedConfigRead(offset, byteCount, dataSize):
            return "Cannot read \(byteCount) bytes at offset \(offset) from a \(dataSize)-byte HAL shared configuration."
        case let .invalidSharedConfigString(offset, byteCount):
            return "Cannot decode UTF-8 string at offset \(offset) with length \(byteCount)."
        case let .invalidSharedMemoryName(name):
            return "Invalid HAL shared-memory name '\(name)'; POSIX shared-memory names must start with '/'."
        case let .sharedMemoryOpenFailed(name, error):
            return "Cannot publish HAL shared memory '\(name)': errno \(error)."
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndianDouble(_ value: Double) {
        appendLittleEndian(value.bitPattern)
    }

    mutating func appendZeroes(count: Int) {
        guard count > 0 else { return }
        append(contentsOf: repeatElement(UInt8(0), count: count))
    }

    mutating func appendFixedUTF8(_ value: String, byteCount: Int) {
        guard byteCount > 0 else { return }
        let bytes = Array(value.utf8.prefix(byteCount - 1))
        append(contentsOf: bytes)
        appendZeroes(count: byteCount - bytes.count)
    }

    func readByte(at offset: Int) throws -> UInt8 {
        guard offset >= 0, offset < count else {
            throw HALRuntimeConfigurationError.invalidSharedConfigRead(offset: offset, byteCount: 1, dataSize: count)
        }

        return self[offset]
    }

    func readLittleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) throws -> T {
        let byteCount = MemoryLayout<T>.size
        guard offset >= 0, offset + byteCount <= count else {
            throw HALRuntimeConfigurationError.invalidSharedConfigRead(offset: offset, byteCount: byteCount, dataSize: count)
        }

        var value: T = 0
        for index in 0..<byteCount {
            value |= T(self[offset + index]) << T(index * 8)
        }
        return value
    }

    func readLittleEndianDouble(at offset: Int) throws -> Double {
        Double(bitPattern: try readLittleEndian(UInt64.self, at: offset))
    }

    func readFixedUTF8(at offset: Int, byteCount: Int) throws -> String {
        guard offset >= 0, offset + byteCount <= count else {
            throw HALRuntimeConfigurationError.invalidSharedConfigRead(offset: offset, byteCount: byteCount, dataSize: count)
        }

        let rawBytes = self[offset..<(offset + byteCount)]
        let trimmedBytes = rawBytes.prefix { $0 != 0 }
        guard let value = String(data: Data(trimmedBytes), encoding: .utf8) else {
            throw HALRuntimeConfigurationError.invalidSharedConfigString(offset: offset, byteCount: byteCount)
        }

        return value
    }
}

@_cdecl("Heartecho_HALDriverFactory")
public func Heartecho_HALDriverFactory(_: CFAllocator?, _: CFUUID?) -> UnsafeMutableRawPointer? {
    nil
}
