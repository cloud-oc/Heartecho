import Foundation

public struct SpecialApplicationSource: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var bundleIdentifier: String?
    public var capturedIdentifiers: [String]
    public var minimumMajorOSVersion: Int

    public init(
        id: String,
        name: String,
        bundleIdentifier: String? = nil,
        capturedIdentifiers: [String] = [],
        minimumMajorOSVersion: Int = 14
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.capturedIdentifiers = capturedIdentifiers.isEmpty
            ? bundleIdentifier.map { [$0] } ?? []
            : capturedIdentifiers
        self.minimumMajorOSVersion = minimumMajorOSVersion
    }

    public var sourceIdentifier: String {
        "special:\(id)"
    }

    public func isSupported(onMajorOSVersion majorVersion: Int) -> Bool {
        majorVersion >= minimumMajorOSVersion
    }

    public static func defaults(supportedOnMajorOSVersion majorVersion: Int) -> [SpecialApplicationSource] {
        defaults.filter { $0.isSupported(onMajorOSVersion: majorVersion) }
    }

    public static let defaults: [SpecialApplicationSource] = [
        SpecialApplicationSource(
            id: "finder",
            name: "Finder",
            bundleIdentifier: "com.apple.finder",
            capturedIdentifiers: [
                "com.apple.finder",
                "com.apple.quicklook.ThumbnailsAgent",
                "com.apple.quicklook.ui.helper"
            ]
        ),
        SpecialApplicationSource(
            id: "siri",
            name: "Siri",
            bundleIdentifier: "com.apple.Siri",
            capturedIdentifiers: [
                "com.apple.Siri",
                "com.apple.assistant_service"
            ]
        ),
        SpecialApplicationSource(
            id: "sound-effects",
            name: "Sound Effects",
            bundleIdentifier: "com.apple.systemsoundserver",
            capturedIdentifiers: [
                "com.apple.systemsoundserver",
                "com.apple.audio.SystemSoundServer"
            ]
        ),
        SpecialApplicationSource(
            id: "voiceover",
            name: "VoiceOver",
            bundleIdentifier: "com.apple.VoiceOver",
            capturedIdentifiers: [
                "com.apple.VoiceOver",
                "com.apple.VoiceOverUtility"
            ]
        ),
        SpecialApplicationSource(
            id: "background-sounds",
            name: "Background Sounds",
            bundleIdentifier: "com.apple.ComfortSounds",
            capturedIdentifiers: [
                "com.apple.ComfortSounds",
                "com.apple.backgroundsounds"
            ],
            minimumMajorOSVersion: 13
        ),
        SpecialApplicationSource(
            id: "notification-center",
            name: "Notification Center",
            bundleIdentifier: "com.apple.notificationcenterui"
        ),
        SpecialApplicationSource(
            id: "spoken-content",
            name: "Spoken Content",
            bundleIdentifier: "com.apple.speech.synthesisserver",
            capturedIdentifiers: [
                "com.apple.speech.synthesisserver",
                "com.apple.speech.speechsynthesisd"
            ]
        ),
        SpecialApplicationSource(
            id: "system-airplay-receiver",
            name: "System AirPlay Receiver",
            bundleIdentifier: "com.apple.controlcenter",
            capturedIdentifiers: [
                "com.apple.controlcenter",
                "com.apple.AirPlayXPCHelper"
            ]
        )
    ]
}
