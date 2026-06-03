import Foundation

public enum HelperServicePlistLocation: String, Hashable, Sendable {
    case buildArtifact
    case userLaunchAgents
    case systemLaunchAgents

    public var displayName: String {
        switch self {
        case .buildArtifact:
            return "build artifact"
        case .userLaunchAgents:
            return "user LaunchAgent"
        case .systemLaunchAgents:
            return "system LaunchAgent"
        }
    }
}

public struct HelperServicePlistProbe: Hashable, Sendable {
    public var location: HelperServicePlistLocation
    public var url: URL
    public var exists: Bool
    public var label: String?
    public var programArguments: [String]
    public var runAtLoad: Bool
    public var keepAlive: Bool
    public var helperExists: Bool
    public var helperIsExecutable: Bool
    public var graphPath: String?
    public var publishesAudio: Bool
    public var servesContinuously: Bool
    public var configSharedMemoryName: String?
    public var audioSharedMemoryName: String?

    public init(
        location: HelperServicePlistLocation,
        url: URL,
        exists: Bool,
        label: String?,
        programArguments: [String],
        runAtLoad: Bool,
        keepAlive: Bool,
        helperExists: Bool,
        helperIsExecutable: Bool,
        graphPath: String?,
        publishesAudio: Bool,
        servesContinuously: Bool,
        configSharedMemoryName: String?,
        audioSharedMemoryName: String?
    ) {
        self.location = location
        self.url = url
        self.exists = exists
        self.label = label
        self.programArguments = programArguments
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.helperExists = helperExists
        self.helperIsExecutable = helperIsExecutable
        self.graphPath = graphPath
        self.publishesAudio = publishesAudio
        self.servesContinuously = servesContinuously
        self.configSharedMemoryName = configSharedMemoryName
        self.audioSharedMemoryName = audioSharedMemoryName
    }

    public var helperPath: String? {
        programArguments.first
    }

    public var isStructurallyValid: Bool {
        exists &&
            label == HelperServiceProbe.defaultLabel &&
            runAtLoad &&
            keepAlive &&
            helperIsExecutable &&
            publishesAudio &&
            servesContinuously &&
            configSharedMemoryName?.hasPrefix("/") == true &&
            audioSharedMemoryName?.hasPrefix("/") == true
    }
}

public struct HelperServiceProbeReport: Hashable, Sendable {
    public var plists: [HelperServicePlistProbe]

    public init(plists: [HelperServicePlistProbe]) {
        self.plists = plists
    }

    public var buildArtifact: HelperServicePlistProbe? {
        plists.first { $0.location == .buildArtifact }
    }

    public var installedUserAgent: HelperServicePlistProbe? {
        plists.first { $0.location == .userLaunchAgents }
    }

    public var installedSystemAgent: HelperServicePlistProbe? {
        plists.first { $0.location == .systemLaunchAgents }
    }

    public var installedAgents: [HelperServicePlistProbe] {
        plists.filter {
            ($0.location == .userLaunchAgents || $0.location == .systemLaunchAgents) && $0.exists
        }
    }

    public var validInstalledAgent: HelperServicePlistProbe? {
        installedAgents.first { $0.isStructurallyValid }
    }

    public var installedAgent: HelperServicePlistProbe? {
        validInstalledAgent ?? installedAgents.first
    }

    public var hasInstalledAgent: Bool {
        !installedAgents.isEmpty
    }

    public var hasValidInstalledAgent: Bool {
        validInstalledAgent != nil
    }

    public var summary: String {
        if let validInstalledAgent {
            return "Helper LaunchAgent installed (\(validInstalledAgent.location.displayName))"
        }

        if let installedAgent {
            return "Helper LaunchAgent installed but invalid (\(installedAgent.location.displayName))"
        }

        if buildArtifact?.exists == true {
            return "Helper LaunchAgent built but not installed"
        }

        return "Helper LaunchAgent not built"
    }
}

public final class HelperServiceProbe: Sendable {
    public static let defaultLabel = "com.heartecho.Heartecho.Helper"

    public init() {}

    public func probe() -> HelperServiceProbeReport {
        HelperServiceProbeReport(plists: [
            plistProbe(location: .buildArtifact, url: buildArtifactURL()),
            plistProbe(location: .userLaunchAgents, url: userLaunchAgentURL()),
            plistProbe(location: .systemLaunchAgents, url: systemLaunchAgentURL())
        ])
    }

    private func plistProbe(location: HelperServicePlistLocation, url: URL) -> HelperServicePlistProbe {
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: url.path)
        let plist = readPlist(url)
        let programArguments = plist?["ProgramArguments"] as? [String] ?? []
        let helperPath = programArguments.first

        return HelperServicePlistProbe(
            location: location,
            url: url,
            exists: exists,
            label: plist?["Label"] as? String,
            programArguments: programArguments,
            runAtLoad: plist?["RunAtLoad"] as? Bool ?? false,
            keepAlive: plist?["KeepAlive"] as? Bool ?? false,
            helperExists: helperPath.map { fileManager.fileExists(atPath: $0) } ?? false,
            helperIsExecutable: helperPath.map { fileManager.isExecutableFile(atPath: $0) } ?? false,
            graphPath: value(after: "--graph", in: programArguments),
            publishesAudio: programArguments.contains("--publish-audio"),
            servesContinuously: programArguments.contains("--serve"),
            configSharedMemoryName: value(after: "--config-shm", in: programArguments),
            audioSharedMemoryName: value(after: "--audio-shm", in: programArguments)
        )
    }

    private func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        return plist
    }

    private func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option) else {
            return nil
        }

        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            return nil
        }

        return arguments[valueIndex]
    }

    private func buildArtifactURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/launchd/\(Self.defaultLabel).plist")
    }

    private func userLaunchAgentURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.defaultLabel).plist")
    }

    private func systemLaunchAgentURL() -> URL {
        URL(fileURLWithPath: "/Library/LaunchAgents/\(Self.defaultLabel).plist")
    }
}
