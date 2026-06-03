import HeartechoAudio
import HeartechoCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: RoutingStore
    @EnvironmentObject private var audioEngine: AudioEngineController
    @EnvironmentObject private var settings: AppSettings
    private let meterTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    @State private var isImportingPreset = false
    @State private var isImportingPresetToLibrary = false
    @State private var exportedPresetDocument = RoutingGraphPresetDocument()
    @State private var isExportingPreset = false

    var body: some View {
        NavigationSplitView {
            DeviceSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } content: {
            if let selectedDevice = store.selectedDevice {
                DeviceWorkspace(device: selectedDevice)
                    .navigationTitle(selectedDevice.name)
            } else {
                EmptyStateView(title: "No Device", detail: "Create a virtual device to begin routing audio.")
            }
        } detail: {
            InspectorPanel()
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
        }
        .toolbar {
            ToolbarItemGroup {
                SourceMenu()

                Button {
                    audioEngine.refreshSources()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Divider()

                Button {
                    store.addSource(kind: .passThru)
                } label: {
                    Label("Pass-Thru", systemImage: "arrow.left.arrow.right")
                }

                Divider()

                PresetLibraryMenu {
                    isImportingPresetToLibrary = true
                }

                Divider()

                Button {
                    isImportingPreset = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }

                Button {
                    preparePresetExport()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }

                Divider()

                AppearanceMenu()

                Divider()

                Button {
                    Task {
                        store.save()
                        await audioEngine.apply(graph: store.graph)
                    }
                } label: {
                    Label("Apply", systemImage: "checkmark.circle")
                }
                .keyboardShortcut("s", modifiers: [.command])
            }
        }
        .onReceive(meterTimer) { _ in
            audioEngine.refreshCaptureMeters()
        }
        .fileImporter(
            isPresented: $isImportingPreset,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            importPreset(result)
        }
        .fileImporter(
            isPresented: $isImportingPresetToLibrary,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            importPresetToLibrary(result)
        }
        .fileExporter(
            isPresented: $isExportingPreset,
            document: exportedPresetDocument,
            contentType: .json,
            defaultFilename: defaultPresetFilename
        ) { result in
            switch result {
            case .success:
                store.setPresetMessage("Preset exported.")
            case .failure(let error):
                store.setPresetMessage("Preset export failed: \(error)")
            }
        }
        .alert(
            "Preset",
            isPresented: Binding(
                get: { store.lastPresetMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.clearPresetMessage()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                store.clearPresetMessage()
            }
        } message: {
            Text(store.lastPresetMessage ?? "")
        }
    }

    private var defaultPresetFilename: String {
        let name = store.selectedDevice?.name ?? "HeartechoPreset"
        let sanitized = name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "\(sanitized.isEmpty ? "HeartechoPreset" : sanitized).json"
    }

    private func preparePresetExport() {
        do {
            exportedPresetDocument = RoutingGraphPresetDocument(data: try store.presetData())
            isExportingPreset = true
        } catch {
            store.setPresetMessage("Preset export failed: \(error)")
        }
    }

    private func importPreset(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }

            do {
                let shouldStopAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if shouldStopAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                store.importPresetData(try Data(contentsOf: url))
            } catch {
                store.setPresetMessage("Preset import failed: \(error)")
            }
        case .failure:
            break
        }
    }

    private func importPresetToLibrary(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }

            do {
                let shouldStopAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if shouldStopAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                store.importPresetDataToLibrary(
                    try Data(contentsOf: url),
                    fallbackName: url.deletingPathExtension().lastPathComponent
                )
            } catch {
                store.setPresetMessage("Preset library import failed: \(error)")
            }
        case .failure:
            break
        }
    }

    private struct PresetLibraryMenu: View {
        @EnvironmentObject private var store: RoutingStore
        var openImport: () -> Void
        @State private var saveTagsText = ""

        var body: some View {
            Menu {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Save Tags")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("streaming, calls", text: $saveTagsText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }

                Button {
                    store.saveCurrentGraphToPresetLibrary(tagsText: saveTagsText)
                    saveTagsText = ""
                } label: {
                    Label("Save Current", systemImage: "tray.and.arrow.down")
                }

                Button {
                    store.refreshPresetLibrary()
                } label: {
                    Label("Refresh Library", systemImage: "arrow.clockwise")
                }

                Button {
                    openImport()
                } label: {
                    Label("Import Library", systemImage: "folder.badge.plus")
                }

                Divider()

                TextField("Search presets", text: $store.presetLibrarySearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)

                if !store.presetLibraryAvailableTags.isEmpty {
                    Menu("Tags") {
                        ForEach(store.presetLibraryAvailableTags, id: \.self) { tag in
                            Button {
                                store.togglePresetLibraryTag(tag)
                            } label: {
                                Label(tag, systemImage: store.presetLibrarySelectedTags.contains(tag) ? "checkmark.circle.fill" : "circle")
                            }
                        }

                        Divider()

                        Button {
                            store.clearPresetLibraryFilters()
                        } label: {
                            Label("Clear Filters", systemImage: "line.3.horizontal.decrease.circle")
                        }
                    }
                }

                Divider()

                if store.filteredPresetLibraryItems.isEmpty {
                    Text(store.presetLibraryItems.isEmpty ? "No library presets" : "No matching presets")
                } else {
                    ForEach(store.filteredPresetLibraryItems) { item in
                        PresetLibraryItemMenu(item: item)
                    }
                }
            } label: {
                Label("Presets", systemImage: "tray.full")
            }
            .onAppear {
                store.refreshPresetLibrary()
            }
        }
    }

    private struct PresetLibraryItemMenu: View {
        @EnvironmentObject private var store: RoutingStore
        let item: RoutingPresetMetadata
        @State private var tagsText: String

        init(item: RoutingPresetMetadata) {
            self.item = item
            self._tagsText = State(initialValue: item.tags.joined(separator: ", "))
        }

        var body: some View {
            Menu(item.name) {
                Button {
                    store.applyPresetFromLibrary(id: item.id)
                } label: {
                    Label("Apply", systemImage: "checkmark.circle")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Tags")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("streaming, calls", text: $tagsText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }

                Button {
                    store.updatePresetLibraryTags(id: item.id, tagsText: tagsText)
                } label: {
                    Label("Update Tags", systemImage: "tag")
                }

                Button(role: .destructive) {
                    store.deletePresetFromLibrary(id: item.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }

                Text("\(item.deviceCount) device(s)")

                if item.tags.isEmpty {
                    Text("No tags")
                } else {
                    Text(item.tags.map { "#\($0)" }.joined(separator: " "))
                }
            }
            .onChange(of: item.tags) { _, newValue in
                tagsText = newValue.joined(separator: ", ")
            }
        }
    }
}

private struct AppearanceMenu: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Menu {
            Picker("Appearance", selection: appearanceBinding) {
                ForEach(AppAppearance.allCases) { appearance in
                    Label(appearance.title, systemImage: appearance.iconName)
                        .tag(appearance)
                }
            }
        } label: {
            Label(settings.appearance.title, systemImage: settings.appearance.iconName)
        }
        .help("Choose app appearance")
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { settings.appearance },
            set: { settings.appearance = $0 }
        )
    }
}

struct SourceMenu: View {
    @EnvironmentObject private var store: RoutingStore
    @EnvironmentObject private var audioEngine: AudioEngineController

    var body: some View {
        Menu {
            Menu("Applications") {
                if audioEngine.runningApplications.isEmpty {
                    Text("No running apps")
                } else {
                    ForEach(audioEngine.runningApplications) { application in
                        Button(application.name) {
                            store.addSource(from: ApplicationSourceReference(
                                id: application.id,
                                name: application.name
                            ))
                        }
                    }
                }
            }

            Menu("Special Sources") {
                ForEach(SpecialApplicationSource.defaults(supportedOnMajorOSVersion: currentMajorOSVersion)) { source in
                    Button(source.name) {
                        store.addSource(from: source)
                    }
                }
            }

            Menu("Hardware Inputs") {
                let inputDevices = audioEngine.systemDevices.filter {
                    $0.direction == .input || $0.direction == .duplex
                }

                if inputDevices.isEmpty {
                    Text("No input devices")
                } else {
                    ForEach(inputDevices) { device in
                        Button(device.name) {
                            store.addSource(from: SystemDeviceReference(
                                id: device.id,
                                uid: device.uid,
                                name: device.name,
                                channelCount: max(1, device.channelCount)
                            ))
                        }
                    }
                }
            }

            Menu("Virtual Devices") {
                let candidates = store.graph.devices.filter { $0.id != store.selectedDevice?.id }

                if candidates.isEmpty {
                    Text("No other virtual devices")
                } else {
                    ForEach(candidates) { device in
                        Button(device.name) {
                            store.addSource(from: device)
                        }
                    }
                }
            }

            Divider()

            Button("Pass-Thru") {
                store.addSource(kind: .passThru)
            }
        } label: {
            Label("Add Source", systemImage: "plus")
        }
    }

    private var currentMajorOSVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }
}

struct DeviceSidebar: View {
    @EnvironmentObject private var store: RoutingStore

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selectedDeviceID) {
                Section("Virtual Devices") {
                    ForEach(store.graph.devices) { device in
                        DeviceRow(device: device)
                            .tag(device.id)
                    }
                }
            }

            Divider()

            Button {
                store.addVirtualDevice()
            } label: {
                Label("Add Device", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
    }

    private var selectedDeviceID: Binding<UUID?> {
        Binding(
            get: { store.graph.selectedDeviceID },
            set: { newValue in
                guard let newValue else {
                    return
                }
                store.select(deviceID: newValue)
            }
        )
    }
}

struct DeviceRow: View {
    let device: VirtualAudioDevice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.isEnabled ? "dot.radiowaves.left.and.right" : "pause.circle")
                .foregroundStyle(device.isEnabled ? .green : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body)
                    .lineLimit(1)
                Text("\(device.sources.count) sources / \(device.outputChannels.count) ch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct DeviceWorkspace: View {
    @EnvironmentObject private var store: RoutingStore
    let device: VirtualAudioDevice

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DeviceHeader(device: device)
                SourceSection(device: device)
                RoutingMatrix(device: device)
                MonitorSection(device: device)
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct DeviceHeader: View {
    @EnvironmentObject private var store: RoutingStore
    @EnvironmentObject private var audioEngine: AudioEngineController
    let device: VirtualAudioDevice
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                EditableNameField(
                    name: device.name,
                    font: .largeTitle.weight(.semibold),
                    commit: { store.renameSelectedDevice($0) }
                )
                .frame(minWidth: 240, maxWidth: 420, alignment: .leading)
                Text("\(sampleRateLabel(device.sampleRate)) / \(device.bufferFrameSize) frame buffer / \(device.latencyFrames) latency / \(device.safetyOffsetFrames) safety / \(device.outputChannels.count) output channels")
                    .foregroundStyle(.secondary)
                OutputLevelStrip(
                    channels: device.outputChannels,
                    peaks: audioEngine.outputChannelPeaks(for: device.id)
                )
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 12) {
                    Toggle("Enabled", isOn: Binding(
                        get: { device.isEnabled },
                        set: { store.setSelectedDeviceEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .help(device.isEnabled ? "Disable virtual device" : "Enable virtual device")

                    Picker("Sample Rate", selection: Binding(
                        get: { device.sampleRate },
                        set: { store.setSelectedDeviceSampleRate($0) }
                    )) {
                        ForEach(RoutingStore.supportedSampleRates, id: \.self) { sampleRate in
                            Text(sampleRateLabel(sampleRate)).tag(sampleRate)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)

                    Picker("Buffer", selection: Binding(
                        get: { device.bufferFrameSize },
                        set: { store.setSelectedDeviceBufferFrameSize($0) }
                    )) {
                        ForEach(RoutingStore.supportedBufferFrameSizes, id: \.self) { frameSize in
                            Text("\(frameSize) frames").tag(frameSize)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)

                    HStack(spacing: 8) {
                        Image(systemName: device.masterGain == 0 ? "speaker.slash" : "speaker.wave.2")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Slider(
                            value: Binding(
                                get: { device.masterGain },
                                set: { store.setDeviceMasterGain($0) }
                            ),
                            in: 0...2
                        )
                        .frame(width: 120)
                        Text("\(Int(device.masterGain * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                HStack(spacing: 8) {
                    Stepper(
                        "Latency \(device.latencyFrames)",
                        value: Binding(
                            get: { device.latencyFrames },
                            set: { store.setSelectedDeviceLatencyFrames($0) }
                        ),
                        in: 0...4096,
                        step: 16
                    )
                    .frame(width: 132)
                    .help("Set reported device latency in frames")

                    Stepper(
                        "Safety \(device.safetyOffsetFrames)",
                        value: Binding(
                            get: { device.safetyOffsetFrames },
                            set: { store.setSelectedDeviceSafetyOffsetFrames($0) }
                        ),
                        in: 0...4096,
                        step: 16
                    )
                    .frame(width: 132)
                    .help("Set reported safety offset in frames")

                    Button {
                        store.addOutputChannels(count: 2)
                    } label: {
                        Label("Add Pair", systemImage: "plus.square.on.square")
                    }

                    Button {
                        store.removeOutputChannelPair()
                    } label: {
                        Label("Remove Pair", systemImage: "minus.square")
                    }
                    .disabled(device.outputChannels.count <= 2)

                    Button {
                        store.toggleDeviceMute()
                    } label: {
                        Label(device.isMuted ? "Unmute" : "Mute", systemImage: device.isMuted ? "speaker.wave.2" : "speaker.slash")
                    }

                    Button {
                        store.addMonitor()
                    } label: {
                        Label("Add Monitor", systemImage: "speaker.wave.2")
                    }

                    MonitorMenu()

                    Button(role: .destructive) {
                        isShowingDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(store.graph.devices.count <= 1)
                    .help(store.graph.devices.count <= 1 ? "At least one virtual device is required" : "Delete virtual device")
                }
            }
        }
        .confirmationDialog(
            "Delete \(device.name)?",
            isPresented: $isShowingDeleteConfirmation
        ) {
            Button("Delete Device", role: .destructive) {
                store.removeSelectedDevice()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nested sources that use this virtual device will be removed from other devices.")
        }
    }

    private func sampleRateLabel(_ sampleRate: Double) -> String {
        "\(Int(sampleRate)) Hz"
    }
}

struct MonitorMenu: View {
    @EnvironmentObject private var store: RoutingStore
    @EnvironmentObject private var audioEngine: AudioEngineController

    var body: some View {
        Menu {
            let outputDevices = audioEngine.systemDevices.filter {
                $0.direction == .output || $0.direction == .duplex
            }

            if outputDevices.isEmpty {
                Text("No output devices")
            } else {
                ForEach(outputDevices) { device in
                    Button(device.name) {
                        store.addMonitor(from: SystemDeviceReference(
                            id: device.id,
                            uid: device.uid,
                            name: device.name,
                            channelCount: max(1, device.channelCount)
                        ))
                    }
                }
            }
        } label: {
            Label("Add Output", systemImage: "speaker.badge.plus")
        }
    }
}

struct SourceSection: View {
    let device: VirtualAudioDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Sources", subtitle: "Applications, hardware inputs, and pass-thru audio")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(device.sources) { source in
                    SourceCard(deviceID: device.id, source: source)
                }
            }
        }
    }
}

struct SourceCard: View {
    @EnvironmentObject private var store: RoutingStore
    @EnvironmentObject private var audioEngine: AudioEngineController
    let deviceID: UUID
    let source: AudioSource

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(source.isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                EditableNameField(
                    name: source.name,
                    font: .headline,
                    commit: { store.renameSource(source, name: $0) }
                )
                Spacer()
                LevelPill(value: audioEngine.sourcePeak(for: source.id, in: deviceID))
                Button {
                    store.toggleSource(source)
                } label: {
                    Image(systemName: source.isEnabled ? "power.circle.fill" : "power.circle")
                        .foregroundStyle(source.isEnabled ? .green : .secondary)
                }
                .buttonStyle(.borderless)
            }

            Text(source.kind.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach(source.channels) { channel in
                    Text("\(channel.index)")
                        .font(.caption2.monospacedDigit())
                        .frame(width: 24, height: 20)
                        .background(Color(nsColor: .quaternaryLabelColor), in: RoundedRectangle(cornerRadius: 4))
                }
            }

            HStack(spacing: 8) {
                Button {
                    store.toggleSourceMute(source)
                } label: {
                    Image(systemName: source.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(source.isMuted ? .orange : .secondary)
                .help(source.isMuted ? "Unmute source" : "Mute source")

                Slider(
                    value: Binding(
                        get: { source.gain },
                        set: { store.setSourceGain(source, gain: $0) }
                    ),
                    in: 0...2
                )

                Text("\(Int(source.gain * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)

                Button {
                    store.removeSource(source)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            if source.kind == .application || source.kind == .hardwareInput {
                CaptureControls(source: source, state: audioEngine.captureState(for: source.id))
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var iconName: String {
        switch source.kind {
        case .application:
            return "app"
        case .hardwareInput:
            return "waveform"
        case .passThru:
            return "arrow.left.arrow.right"
        case .virtualDevice:
            return "dot.radiowaves.left.and.right"
        }
    }
}

struct CaptureControls: View {
    @EnvironmentObject private var store: RoutingStore
    @EnvironmentObject private var audioEngine: AudioEngineController
    let source: AudioSource
    let state: SourceCaptureState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(state.phase.rawValue, systemImage: phaseIcon)
                    .font(.caption)
                    .foregroundStyle(phaseColor)
                    .lineLimit(1)

                Spacer()

                LevelPill(value: state.peak)
            }

            Text(state.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if source.kind == .application {
                Toggle("Mute when capturing", isOn: Binding(
                    get: { source.mutesWhenCaptured },
                    set: { store.setSourceMutesWhenCaptured(source, isEnabled: $0) }
                ))
                .font(.caption)
                .toggleStyle(.checkbox)
                .help("Mute this app on the hardware output while its process tap is being read")
            }

            HStack(spacing: 6) {
                Button {
                    prepareCapture()
                } label: {
                    Image(systemName: "rectangle.connected.to.line.below")
                }
                .help(source.kind == .hardwareInput ? "Prepare input capture" : "Prepare process tap")
                .buttonStyle(.borderless)
                .disabled(state.phase == .running)

                Button {
                    startCapture()
                } label: {
                    Image(systemName: "record.circle")
                }
                .help("Start capture")
                .buttonStyle(.borderless)
                .disabled(state.phase == .running)

                Button {
                    audioEngine.stopCapture(sourceID: source.id)
                } label: {
                    Image(systemName: "stop.circle")
                }
                .help("Stop capture")
                .buttonStyle(.borderless)
                .disabled(state.phase != .running)

                Button {
                    audioEngine.tearDownCapture(sourceID: source.id)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("Release capture session")
                .buttonStyle(.borderless)
                .disabled(state.phase == .idle)

                Spacer()

                Text("\(state.availableFrameCount)f")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private func prepareCapture() {
        switch source.kind {
        case .application:
            audioEngine.prepareApplicationCapture(source: source)
        case .hardwareInput:
            audioEngine.prepareHardwareInputCapture(source: source)
        case .passThru, .virtualDevice:
            break
        }
    }

    private func startCapture() {
        switch source.kind {
        case .application:
            audioEngine.startApplicationCapture(source: source)
        case .hardwareInput:
            audioEngine.startHardwareInputCapture(source: source)
        case .passThru, .virtualDevice:
            break
        }
    }

    private var phaseIcon: String {
        switch state.phase {
        case .idle:
            return "circle"
        case .prepared:
            return "checkmark.circle"
        case .running:
            return "waveform"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    private var phaseColor: Color {
        switch state.phase {
        case .idle:
            return .secondary
        case .prepared:
            return .blue
        case .running:
            return .green
        case .failed:
            return .orange
        }
    }
}

struct LevelPill: View {
    let value: Float

    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: .quaternaryLabelColor))
                RoundedRectangle(cornerRadius: 2)
                    .fill(levelColor)
                    .frame(width: max(3, CGFloat(clampedValue) * 34), height: 5)
            }
            .frame(width: 34, height: 5)

            Text("\(Int(clampedValue * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .frame(width: 72, alignment: .trailing)
    }

    private var clampedValue: Float {
        max(0, min(value, 1))
    }

    private var levelColor: Color {
        if clampedValue > 0.85 {
            return .red
        }
        if clampedValue > 0.55 {
            return .orange
        }
        return clampedValue > 0 ? .green : .secondary.opacity(0.5)
    }
}

struct OutputLevelStrip: View {
    let channels: [AudioChannel]
    let peaks: [Int: Float]

    private let columns = [
        GridItem(.adaptive(minimum: 26, maximum: 30), spacing: 5)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(channels, id: \.id) { channel in
                OutputChannelMeter(
                    channelIndex: channel.index,
                    peak: peaks[channel.index] ?? 0
                )
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .accessibilityLabel("Output channel levels")
    }
}

struct OutputChannelMeter: View {
    let channelIndex: Int
    let peak: Float

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(levelColor)
                        .frame(height: max(2, geometry.size.height * CGFloat(clampedPeak)))
                }
            }
            .frame(width: 18, height: 34)

            Text("\(channelIndex)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .lineLimit(1)
        }
        .help("Output \(channelIndex): \(Int(clampedPeak * 100))%")
    }

    private var clampedPeak: Float {
        max(0, min(peak, 1))
    }

    private var levelColor: Color {
        if clampedPeak > 0.85 {
            return .red
        }
        if clampedPeak > 0.55 {
            return .orange
        }
        return clampedPeak > 0 ? .green : .secondary.opacity(0.5)
    }
}

struct RoutingMatrix: View {
    @EnvironmentObject private var store: RoutingStore
    let device: VirtualAudioDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Channel Routing", subtitle: "Map every source channel into virtual output channels")
            RouteComposer(device: device)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Source")
                        .font(.caption.weight(.semibold))
                    Text("From")
                        .font(.caption.weight(.semibold))
                    Text("To")
                        .font(.caption.weight(.semibold))
                    Text("Gain")
                        .font(.caption.weight(.semibold))
                    Text("Level")
                        .font(.caption.weight(.semibold))
                    Text("State")
                        .font(.caption.weight(.semibold))
                    Text("")
                }

                ForEach(device.routes) { route in
                    RouteRow(device: device, route: route)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct RouteRow: View {
    @EnvironmentObject private var store: RoutingStore
    @EnvironmentObject private var audioEngine: AudioEngineController
    let device: VirtualAudioDevice
    let route: ChannelRoute

    var body: some View {
        GridRow {
            Text(source?.name ?? "Missing Source")
                .lineLimit(1)
                .frame(minWidth: 170, alignment: .leading)

            Text("Ch \(route.sourceChannelIndex)")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)

            Text("Out \(route.outputChannelIndex)")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { route.gain },
                    set: { store.setRouteGain(route, gain: $0) }
                ),
                in: 0...2
            )
            .frame(width: 120)

            LevelPill(value: audioEngine.routePeak(for: route.id, in: device.id))

            Button {
                store.toggleRoute(route)
            } label: {
                Image(systemName: route.isMuted ? "speaker.slash" : "speaker.wave.2")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)

            Button {
                store.removeRoute(route)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    private var source: AudioSource? {
        device.sources.first { $0.id == route.sourceID }
    }
}

struct RouteComposer: View {
    @EnvironmentObject private var store: RoutingStore
    let device: VirtualAudioDevice
    @State private var sourceID: UUID?
    @State private var sourceChannelIndex = 1
    @State private var outputChannelIndex = 1

    var body: some View {
        HStack(spacing: 10) {
            Picker("Source", selection: sourceSelection) {
                Text("Choose Source").tag(Optional<UUID>.none)
                ForEach(device.sources) { source in
                    Text(source.name).tag(Optional(source.id))
                }
            }
            .frame(minWidth: 180)

            Picker("From", selection: $sourceChannelIndex) {
                ForEach(selectedSource?.channels ?? [], id: \.index) { channel in
                    Text("Ch \(channel.index)").tag(channel.index)
                }
            }
            .frame(width: 110)
            .disabled(selectedSource == nil)

            Picker("To", selection: $outputChannelIndex) {
                ForEach(device.outputChannels, id: \.index) { channel in
                    Text("Out \(channel.index)").tag(channel.index)
                }
            }
            .frame(width: 110)

            Button {
                guard let sourceID else {
                    return
                }
                store.addRoute(
                    sourceID: sourceID,
                    sourceChannelIndex: sourceChannelIndex,
                    outputChannelIndex: outputChannelIndex
                )
            } label: {
                Label("Add Route", systemImage: "plus")
            }
            .disabled(sourceID == nil)

            Spacer()
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
            if sourceID == nil {
                sourceID = device.sources.first?.id
                sourceChannelIndex = device.sources.first?.channels.first?.index ?? 1
                outputChannelIndex = device.outputChannels.first?.index ?? 1
            }
        }
    }

    private var sourceSelection: Binding<UUID?> {
        Binding(
            get: { sourceID },
            set: { newValue in
                sourceID = newValue
                sourceChannelIndex = selectedSource?.channels.first?.index ?? 1
            }
        )
    }

    private var selectedSource: AudioSource? {
        guard let sourceID else {
            return nil
        }
        return device.sources.first { $0.id == sourceID }
    }
}

struct MonitorSection: View {
    @EnvironmentObject private var audioEngine: AudioEngineController
    let device: VirtualAudioDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Monitors", subtitle: "Send virtual device audio to hardware outputs")

            if device.monitors.isEmpty {
                EmptyStateView(title: "No Monitors", detail: "Add a monitor to hear this virtual device locally.")
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                VStack(spacing: 8) {
                    ForEach(device.monitors) { monitor in
                        MonitorRow(
                            device: device,
                            monitor: monitor,
                            state: audioEngine.monitorState(for: monitor.id),
                            playbackState: audioEngine.monitorPlaybackState(for: monitor.id)
                        )
                    }
                }
            }
        }
    }
}

struct MonitorRow: View {
    @EnvironmentObject private var audioEngine: AudioEngineController
    @EnvironmentObject private var store: RoutingStore
    let device: VirtualAudioDevice
    let monitor: Monitor
    let state: MonitorOutputState?
    let playbackState: MonitorPlaybackState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: iconName)
                    .frame(width: 24)
                    .foregroundStyle(iconColor)
                EditableNameField(
                    name: monitor.name,
                    font: .body,
                    commit: { store.renameMonitor(monitorID: monitor.id, name: $0) }
                )
                Spacer()
                Text("\(Int(monitor.gain * 100))%")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    store.toggleMonitor(monitorID: monitor.id)
                } label: {
                    Image(systemName: monitor.isEnabled ? "power.circle.fill" : "power.circle")
                        .foregroundStyle(monitor.isEnabled ? .green : .secondary)
                }
                .buttonStyle(.borderless)
                .help(monitor.isEnabled ? "Disable monitor" : "Enable monitor")
            }

            HStack(spacing: 8) {
                Label(state?.phase.rawValue ?? "Idle", systemImage: "waveform.path")
                    .font(.caption)
                    .foregroundStyle(iconColor)
                Text(state?.status ?? "No monitor audio")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                LevelPill(value: state?.peak ?? 0)
                Text("\(state?.availableFrameCount ?? 0)f")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Picker("Output", selection: outputSelection) {
                Text("Default Output").tag(Optional<String>.none)
                ForEach(outputDevices) { device in
                    Text(device.name).tag(Optional(device.uid ?? device.id))
                }
            }
            .labelsHidden()

            MonitorRoutingView(device: device, monitor: monitor)

            HStack(spacing: 8) {
                Button {
                    store.toggleMonitorMute(monitorID: monitor.id)
                } label: {
                    Image(systemName: monitor.isMuted || monitor.gain == 0 ? "speaker.slash.fill" : "speaker.wave.2")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(monitor.isMuted ? .orange : .secondary)
                .help(monitor.isMuted ? "Unmute monitor" : "Mute monitor")

                Slider(
                    value: Binding(
                        get: { monitor.gain },
                        set: { store.setMonitorGain(monitorID: monitor.id, gain: $0) }
                    ),
                    in: 0...2
                )

                Text("\(Int(monitor.gain * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)

                Button {
                    store.removeMonitor(monitorID: monitor.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove monitor")
            }

            HStack(spacing: 8) {
                Label(playbackState.phase.rawValue, systemImage: playbackIcon)
                    .font(.caption)
                    .foregroundStyle(playbackColor)
                Text(playbackState.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    audioEngine.startMonitorPlayback(monitor: monitor)
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .disabled(playbackState.phase == .running || !monitor.isEnabled)

                Button {
                    audioEngine.stopMonitorPlayback(monitorID: monitor.id)
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .disabled(playbackState.phase != .running)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        if !monitor.isEnabled {
            return "speaker.slash"
        }

        switch state?.phase {
        case .receiving:
            return "speaker.wave.2.fill"
        case .muted:
            return "speaker.slash.fill"
        case .disabled:
            return "speaker.slash"
        case .idle, nil:
            return "speaker.wave.2"
        }
    }

    private var iconColor: Color {
        if !monitor.isEnabled {
            return .secondary
        }

        switch state?.phase {
        case .receiving:
            return .green
        case .muted:
            return .orange
        case .disabled:
            return .secondary
        case .idle, nil:
            return .secondary
        }
    }

    private var playbackIcon: String {
        switch playbackState.phase {
        case .idle:
            return "play.circle"
        case .running:
            return "speaker.wave.2.circle"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    private var playbackColor: Color {
        switch playbackState.phase {
        case .idle:
            return .secondary
        case .running:
            return .green
        case .failed:
            return .orange
        }
    }

    private var outputDevices: [SystemAudioDevice] {
        audioEngine.systemDevices.filter {
            $0.direction == .output || $0.direction == .duplex
        }
    }

    private var outputSelection: Binding<String?> {
        Binding(
            get: {
                monitor.deviceIdentifier
            },
            set: { newValue in
                let selectedDevice = outputDevices.first { ($0.uid ?? $0.id) == newValue }
                store.setMonitorDevice(
                    monitorID: monitor.id,
                    deviceIdentifier: newValue,
                    name: selectedDevice?.name
                )
            }
        )
    }
}

struct MonitorRoutingView: View {
    @EnvironmentObject private var store: RoutingStore
    let device: VirtualAudioDevice
    let monitor: Monitor
    @State private var sourceChannelIndex = 1
    @State private var monitorChannelIndex = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("\(monitor.channels.count) monitor channels", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    store.addMonitorChannels(monitorID: monitor.id, count: 2)
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .buttonStyle(.borderless)
                .help("Add monitor channel pair")

                Button {
                    store.removeMonitorChannelPair(monitorID: monitor.id)
                } label: {
                    Image(systemName: "minus.square")
                }
                .buttonStyle(.borderless)
                .disabled(monitor.channels.count <= 2)
                .help("Remove monitor channel pair")
            }

            HStack(spacing: 8) {
                Picker("From", selection: $sourceChannelIndex) {
                    ForEach(device.outputChannels, id: \.index) { channel in
                        Text("Out \(channel.index)").tag(channel.index)
                    }
                }
                .frame(width: 110)

                Picker("To", selection: $monitorChannelIndex) {
                    ForEach(monitor.channels, id: \.index) { channel in
                        Text("Mon \(channel.index)").tag(channel.index)
                    }
                }
                .frame(width: 110)

                Button {
                    store.addMonitorRoute(
                        monitorID: monitor.id,
                        sourceChannelIndex: sourceChannelIndex,
                        monitorChannelIndex: monitorChannelIndex
                    )
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(device.outputChannels.isEmpty || monitor.channels.isEmpty)
                .help("Add monitor route")

                Spacer()
            }

            if monitor.routes.isEmpty {
                Text("Default one-to-one routing")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                    ForEach(monitor.routes) { route in
                        MonitorRouteRow(monitor: monitor, route: route)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .onAppear {
            syncSelections()
        }
        .onChange(of: device.outputChannels.count) { _, _ in
            syncSelections()
        }
        .onChange(of: monitor.channels.count) { _, _ in
            syncSelections()
        }
    }

    private func syncSelections() {
        sourceChannelIndex = device.outputChannels.first?.index ?? 1
        monitorChannelIndex = monitor.channels.first?.index ?? 1
    }
}

struct MonitorRouteRow: View {
    @EnvironmentObject private var store: RoutingStore
    let monitor: Monitor
    let route: MonitorRoute

    var body: some View {
        GridRow {
            Text("Out \(route.sourceChannelIndex)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text("Mon \(route.monitorChannelIndex)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)

            Slider(
                value: Binding(
                    get: { route.gain },
                    set: { store.setMonitorRouteGain(monitorID: monitor.id, route: route, gain: $0) }
                ),
                in: 0...2
            )
            .frame(width: 90)

            Button {
                store.toggleMonitorRoute(monitorID: monitor.id, route: route)
            } label: {
                Image(systemName: route.isMuted ? "speaker.slash" : "speaker.wave.2")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help(route.isMuted ? "Unmute monitor route" : "Mute monitor route")

            Button {
                store.removeMonitorRoute(monitorID: monitor.id, route: route)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove monitor route")
        }
    }
}

struct InspectorPanel: View {
    @EnvironmentObject private var store: RoutingStore
    @EnvironmentObject private var audioEngine: AudioEngineController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Readiness")
                        .font(.headline)
                    Label(audioEngine.readinessReport.summary, systemImage: readinessIcon(audioEngine.readinessReport.overallState))
                        .foregroundStyle(readinessColor(audioEngine.readinessReport.overallState))
                    Text("Required items: \(audioEngine.readinessReport.requiredItems.filter { $0.state == .ready }.count)/\(audioEngine.readinessReport.requiredItems.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 8) {
                        ForEach(audioEngine.readinessReport.items) { item in
                            ReadinessRow(item: item)
                        }
                    }

                    HStack(spacing: 8) {
                        Button {
                            audioEngine.refreshSources()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }

                        Button {
                            Task {
                                await audioEngine.requestMicrophoneAccess()
                            }
                        } label: {
                            Label("Microphone", systemImage: "mic")
                        }
                        .disabled(audioEngine.microphonePermissionStatus == .authorized)
                    }
                    .font(.caption)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Driver")
                        .font(.headline)
                    Label(audioEngine.driverStatus.rawValue, systemImage: "puzzlepiece.extension")
                        .foregroundStyle(.secondary)
                    if let probe = audioEngine.driverProbeReport {
                        Label(
                            probe.summary,
                            systemImage: probe.deviceProbe.isVisible ? "checkmark.circle" : "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(probe.deviceProbe.isVisible ? Color.green : Color.orange)

                        Text("Installed \(probe.installedBundles.count) / visible \(probe.deviceProbe.matchingDevices.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let report = audioEngine.lastRenderReport {
                        Label(
                            "\(report.totalActiveRouteCount) active routes / \(report.totalMissingSourceRouteCount) missing",
                            systemImage: "point.3.connected.trianglepath.dotted"
                        )
                        .font(.caption)
                        .foregroundStyle(report.totalMissingSourceRouteCount > 0 ? .orange : .secondary)

                        if report.totalResampledSourceCount > 0 {
                            Label(
                                resamplingSummary(report),
                                systemImage: "waveform.path.ecg"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    if let publication = audioEngine.lastHALPublicationReport {
                        Label(
                            "\(publication.publications.count) HAL buffers / \(publication.totalPublishedFrameCount) frames / \(publication.didPublishSharedMemory ? "shared" : "local")",
                            systemImage: publication.failedWriteCount == 0 && publication.didPublishSharedMemory ? "waveform.path" : "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(publication.failedWriteCount == 0 && publication.didPublishSharedMemory ? Color.secondary : Color.orange)
                    }
                    ForEach(Array(audioEngine.halAudioTransportHealthReports.values), id: \.current.deviceObjectID) { health in
                        Label(
                            health.summary,
                            systemImage: health.isHealthy ? "arrow.left.arrow.right.circle" : "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(health.isHealthy ? Color.secondary : Color.orange)
                        Text(health.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let realtime = audioEngine.halRealtimeSafetyReport {
                        Label(
                            realtime.summary,
                            systemImage: realtime.hasRenderPathRisk ? "exclamationmark.triangle" : "speedometer"
                        )
                        .font(.caption)
                        .foregroundStyle(realtime.hasRenderPathRisk ? Color.orange : Color.secondary)
                        Text(realtime.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Label(
                        audioEngine.processTapCapability.isSupported ? "Process taps available" : "Process taps unavailable",
                        systemImage: "waveform.path.badge.plus"
                    )
                    .foregroundStyle(audioEngine.processTapCapability.isSupported ? .green : .orange)
                    .font(.caption)
                    Text(audioEngine.processTapCapability.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                if let device = store.selectedDevice {
                    let issues = RoutingGraphValidator.validate(device: device)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Validation")
                            .font(.headline)

                        if issues.isEmpty {
                            Label("Routing graph is valid", systemImage: "checkmark.seal")
                                .foregroundStyle(.green)
                        } else {
                            ForEach(issues) { issue in
                                Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                                    .foregroundStyle(issue.severity == .error ? .red : .orange)
                                    .font(.caption)
                            }
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("System Audio")
                            .font(.headline)
                        Spacer()
                        Button {
                            audioEngine.refreshSources()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                    }

                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(audioEngine.systemDevices) { device in
                                SystemDeviceRow(device: device)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Running Apps")
                        .font(.headline)
                    Text("\(audioEngine.processTapDiagnostics.filter { $0.processObjectID != nil }.count) can be mapped to Core Audio process objects")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(audioEngine.runningApplications.prefix(8)) { application in
                                let diagnostic = audioEngine.processTapDiagnostics.first { $0.applicationID == application.id }
                                HStack {
                                    Image(systemName: diagnostic?.processObjectID == nil ? "app.badge" : "app")
                                        .frame(width: 22)
                                        .foregroundStyle(diagnostic?.processObjectID == nil ? .orange : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(application.name)
                                            .lineLimit(1)
                                        Text(appDiagnosticText(application: application, diagnostic: diagnostic))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button {
                                        store.addSource(from: ApplicationSourceReference(
                                            id: application.id,
                                            name: application.name
                                        ))
                                    } label: {
                                        Image(systemName: "plus")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(8)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func readinessIcon(_ state: AudioReadinessState) -> String {
        switch state {
        case .ready:
            return "checkmark.seal"
        case .warning:
            return "exclamationmark.triangle"
        case .blocked:
            return "xmark.octagon"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private func resamplingSummary(_ report: RuntimeRenderReport) -> String {
        let reports = report.renders.flatMap(\.resamplingReports)
        let qualities = Set(reports.map(\.quality))
        let qualityText = qualities.count == 1
            ? qualities.first?.rawValue.capitalized ?? "Unknown"
            : "\(qualities.count) modes"
        return "\(reports.count) SRC source(s) / \(qualityText)"
    }

    private func readinessColor(_ state: AudioReadinessState) -> Color {
        switch state {
        case .ready:
            return .green
        case .warning:
            return .orange
        case .blocked:
            return .red
        case .unknown:
            return .secondary
        }
    }

    private func appDiagnosticText(
        application: RunningApplicationSource,
        diagnostic: ProcessTapProcessDiagnostic?
    ) -> String {
        guard let diagnostic else {
            return "pid \(application.processIdentifier)"
        }

        if let processObjectID = diagnostic.processObjectID {
            return "pid \(application.processIdentifier) / process \(processObjectID) / \(diagnostic.isRunningOutput ? "audio active" : "idle")"
        }

        return "pid \(application.processIdentifier) / not connected to HAL"
    }
}

struct ReadinessRow: View {
    let item: AudioReadinessItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: iconName)
                    .frame(width: 20)
                    .foregroundStyle(color)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                        if item.isRequired {
                            Text("Required")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(item.summary)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }

                Spacer()

                Text(item.state.rawValue)
                    .font(.caption2)
                    .foregroundStyle(color)
                    .lineLimit(1)
            }

            Text(item.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let recommendedAction = item.recommendedAction {
                Text(recommendedAction)
                    .font(.caption2)
                    .foregroundStyle(color)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        switch item.state {
        case .ready:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .blocked:
            return "xmark.octagon.fill"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private var color: Color {
        switch item.state {
        case .ready:
            return .green
        case .warning:
            return .orange
        case .blocked:
            return .red
        case .unknown:
            return .secondary
        }
    }
}

struct SystemDeviceRow: View {
    let device: SystemAudioDevice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .frame(width: 22)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .lineLimit(1)
                Text("\(device.manufacturer) / \(device.channelCount) ch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        switch device.direction {
        case .input:
            return "mic"
        case .output:
            return "speaker.wave.2"
        case .duplex:
            return "arrow.triangle.2.circlepath"
        case .unknown:
            return "questionmark.circle"
        }
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct EditableNameField: View {
    let name: String
    let font: Font
    let commit: (String) -> Void
    @State private var draftName = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $draftName)
            .font(font)
            .textFieldStyle(.plain)
            .lineLimit(1)
            .focused($isFocused)
            .onAppear {
                draftName = name
            }
            .onChange(of: name) { _, newValue in
                if !isFocused {
                    draftName = newValue
                }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commitDraft()
                }
            }
            .onSubmit {
                commitDraft()
                isFocused = false
            }
    }

    private func commitDraft() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            draftName = name
        } else if trimmed != name {
            commit(trimmed)
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
