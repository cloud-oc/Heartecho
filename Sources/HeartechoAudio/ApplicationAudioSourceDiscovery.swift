import AppKit
import Foundation

public struct ApplicationProcessSource: Identifiable, Hashable, Sendable {
    public var id: String
    public var processIdentifier: pid_t
    public var name: String
    public var bundleIdentifier: String?
    public var isActive: Bool
    public var isRegularApplication: Bool

    public init(
        id: String,
        processIdentifier: pid_t,
        name: String,
        bundleIdentifier: String?,
        isActive: Bool,
        isRegularApplication: Bool
    ) {
        self.id = id
        self.processIdentifier = processIdentifier
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.isActive = isActive
        self.isRegularApplication = isRegularApplication
    }
}

public typealias RunningApplicationSource = ApplicationProcessSource

@MainActor
public final class ApplicationAudioSourceDiscovery {
    public init() {}

    public func runningApplications() -> [RunningApplicationSource] {
        applicationProcesses(includeBackgroundProcesses: false)
    }

    public func captureCandidateProcesses() -> [ApplicationProcessSource] {
        applicationProcesses(includeBackgroundProcesses: true)
    }

    private func applicationProcesses(includeBackgroundProcesses: Bool) -> [ApplicationProcessSource] {
        NSWorkspace.shared.runningApplications
            .filter { application in
                application.processIdentifier > 0 &&
                    (includeBackgroundProcesses || application.activationPolicy == .regular)
            }
            .compactMap { application in
                let bundleIdentifier = application.bundleIdentifier
                let name = application.localizedName ?? bundleIdentifier ?? "pid \(application.processIdentifier)"
                guard !name.isEmpty else {
                    return nil
                }

                let id = bundleIdentifier ?? "pid:\(application.processIdentifier)"

                return ApplicationProcessSource(
                    id: id,
                    processIdentifier: application.processIdentifier,
                    name: name,
                    bundleIdentifier: bundleIdentifier,
                    isActive: !application.isTerminated,
                    isRegularApplication: application.activationPolicy == .regular
                )
            }
            .uniqued(by: \.id)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private extension Sequence {
    func uniqued<ID: Hashable>(by keyPath: KeyPath<Element, ID>) -> [Element] {
        var seen = Set<ID>()
        return filter { element in
            seen.insert(element[keyPath: keyPath]).inserted
        }
    }
}
