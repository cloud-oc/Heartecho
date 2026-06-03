import Foundation

public struct RoutingIssue: Identifiable, Hashable, Sendable {
    public enum Severity: String, Sendable {
        case warning
        case error
    }

    public var id: String
    public var severity: Severity
    public var message: String

    public init(id: String, severity: Severity, message: String) {
        self.id = id
        self.severity = severity
        self.message = message
    }
}

public enum RoutingGraphValidator {
    public static let maximumChannelCount = 64

    public static func validate(device: VirtualAudioDevice) -> [RoutingIssue] {
        var issues: [RoutingIssue] = []

        if device.outputChannels.isEmpty {
            issues.append(RoutingIssue(
                id: "no-output-channels",
                severity: .error,
                message: "The virtual device needs at least one output channel."
            ))
        }

        if device.outputChannels.count > maximumChannelCount {
            issues.append(RoutingIssue(
                id: "too-many-output-channels",
                severity: .error,
                message: "Virtual devices support up to \(maximumChannelCount) channels."
            ))
        }

        for route in device.routes {
            guard let source = device.sources.first(where: { $0.id == route.sourceID }) else {
                issues.append(RoutingIssue(
                    id: "missing-source-\(route.id)",
                    severity: .error,
                    message: "A route references a missing source."
                ))
                continue
            }

            if !source.channels.contains(where: { $0.index == route.sourceChannelIndex }) {
                issues.append(RoutingIssue(
                    id: "missing-source-channel-\(route.id)",
                    severity: .error,
                    message: "\(source.name) does not have source channel \(route.sourceChannelIndex)."
                ))
            }

            if !device.outputChannels.contains(where: { $0.index == route.outputChannelIndex }) {
                issues.append(RoutingIssue(
                    id: "missing-output-channel-\(route.id)",
                    severity: .error,
                    message: "\(device.name) does not have output channel \(route.outputChannelIndex)."
                ))
            }
        }

        if device.sources.isEmpty {
            issues.append(RoutingIssue(
                id: "no-sources",
                severity: .warning,
                message: "Add at least one app, hardware input, or pass-thru source."
            ))
        }

        return issues
    }
}
