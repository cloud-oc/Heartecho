import Foundation
import HALDriverStub

public enum HALDriverInstallationLocation: String, Hashable, Sendable {
    case user
    case system
    case buildArtifact
}

public struct HALDriverBundleProbe: Hashable, Sendable {
    public var location: HALDriverInstallationLocation
    public var url: URL
    public var exists: Bool
    public var hasInfoPlist: Bool
    public var hasExecutable: Bool
    public var bundleIdentifier: String?
    public var executableName: String?
    public var factorySymbol: String?
    public var isSignatureValid: Bool

    public init(
        location: HALDriverInstallationLocation,
        url: URL,
        exists: Bool,
        hasInfoPlist: Bool,
        hasExecutable: Bool,
        bundleIdentifier: String?,
        executableName: String?,
        factorySymbol: String?,
        isSignatureValid: Bool
    ) {
        self.location = location
        self.url = url
        self.exists = exists
        self.hasInfoPlist = hasInfoPlist
        self.hasExecutable = hasExecutable
        self.bundleIdentifier = bundleIdentifier
        self.executableName = executableName
        self.factorySymbol = factorySymbol
        self.isSignatureValid = isSignatureValid
    }

    public var isStructurallyValid: Bool {
        exists &&
            hasInfoPlist &&
            hasExecutable &&
            bundleIdentifier == HALDriverBridge.bundleIdentifier &&
            executableName == "HeartechoHALDriver" &&
            factorySymbol == "HeartechoHALDriverFactory"
    }
}

public struct HALDriverDeviceProbe: Hashable, Sendable {
    public var expectedUIDPrefix: String
    public var matchingDevices: [SystemAudioDevice]

    public init(expectedUIDPrefix: String, matchingDevices: [SystemAudioDevice]) {
        self.expectedUIDPrefix = expectedUIDPrefix
        self.matchingDevices = matchingDevices
    }

    public var isVisible: Bool {
        !matchingDevices.isEmpty
    }
}

public struct HALDriverProbeReport: Hashable, Sendable {
    public var bundles: [HALDriverBundleProbe]
    public var deviceProbe: HALDriverDeviceProbe

    public init(bundles: [HALDriverBundleProbe], deviceProbe: HALDriverDeviceProbe) {
        self.bundles = bundles
        self.deviceProbe = deviceProbe
    }

    public var installedBundles: [HALDriverBundleProbe] {
        bundles.filter { $0.location == .user || $0.location == .system }.filter(\.exists)
    }

    public var hasInstalledBundle: Bool {
        !installedBundles.isEmpty
    }

    public var hasValidInstalledBundle: Bool {
        installedBundles.contains { $0.isStructurallyValid && $0.isSignatureValid }
    }

    public var buildArtifact: HALDriverBundleProbe? {
        bundles.first { $0.location == .buildArtifact }
    }

    public var summary: String {
        if deviceProbe.isVisible {
            return "\(deviceProbe.matchingDevices.count) virtual device(s) visible"
        }

        if hasValidInstalledBundle {
            return "Installed driver not visible to Core Audio"
        }

        if hasInstalledBundle {
            return "Installed driver is unsigned or invalid"
        }

        if buildArtifact?.exists == true {
            return "Driver bundle built but not installed"
        }

        return "Driver not installed"
    }
}

public final class HALDriverProbe: Sendable {
    public init() {}

    public func probe(systemDevices: [SystemAudioDevice]) -> HALDriverProbeReport {
        let bundles = [
            bundleProbe(location: .user, url: userInstallURL()),
            bundleProbe(location: .system, url: systemInstallURL()),
            bundleProbe(location: .buildArtifact, url: buildArtifactURL())
        ]
        let uidPrefix = "\(HALDriverBridge.bundleIdentifier)."
        let matchingDevices = systemDevices.filter { device in
            device.uid?.hasPrefix(uidPrefix) ?? false
        }

        return HALDriverProbeReport(
            bundles: bundles,
            deviceProbe: HALDriverDeviceProbe(
                expectedUIDPrefix: uidPrefix,
                matchingDevices: matchingDevices
            )
        )
    }

    private func bundleProbe(location: HALDriverInstallationLocation, url: URL) -> HALDriverBundleProbe {
        let infoPlistURL = url.appendingPathComponent("Contents/Info.plist")
        let executableURL = url.appendingPathComponent("Contents/MacOS/HeartechoHALDriver")
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: url.path)
        let hasInfoPlist = fileManager.fileExists(atPath: infoPlistURL.path)
        let hasExecutable = fileManager.isExecutableFile(atPath: executableURL.path)
        let plist = readPlist(infoPlistURL)
        let factories = plist?["CFPlugInFactories"] as? [String: String]

        return HALDriverBundleProbe(
            location: location,
            url: url,
            exists: exists,
            hasInfoPlist: hasInfoPlist,
            hasExecutable: hasExecutable,
            bundleIdentifier: plist?["CFBundleIdentifier"] as? String,
            executableName: plist?["CFBundleExecutable"] as? String,
            factorySymbol: factories?.values.first,
            isSignatureValid: signatureIsValid(bundleURL: url)
        )
    }

    private func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        return plist
    }

    private func signatureIsValid(bundleURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", bundleURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func userInstallURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Audio/Plug-Ins/HAL/Heartecho.driver")
    }

    private func systemInstallURL() -> URL {
        URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/Heartecho.driver")
    }

    private func buildArtifactURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/HAL/Heartecho.driver")
    }
}
