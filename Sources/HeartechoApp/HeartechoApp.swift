import HeartechoAudio
import HeartechoCore
import SwiftUI

@main
struct HeartechoApp: App {
    @StateObject private var store = RoutingStore()
    @StateObject private var audioEngine = AudioEngineController()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(audioEngine)
                .environmentObject(settings)
                .preferredColorScheme(settings.preferredColorScheme)
                .frame(minWidth: 1100, minHeight: 680)
                .task {
                    audioEngine.refreshSources()
                }
        }
        .windowStyle(.titleBar)

        Settings {
            AppSettingsView()
                .environmentObject(settings)
                .preferredColorScheme(settings.preferredColorScheme)
        }
    }
}
