import Foundation
import HALDriverStub
import HeartechoCore

@MainActor
final class RoutingStore: ObservableObject {
    static let supportedSampleRates: [Double] = [44_100, 48_000, 88_200, 96_000]
    static let supportedBufferFrameSizes: [Int] = [128, 256, 512, 1024, 2048, 4096]

    @Published var graph: RoutingGraph
    @Published private(set) var lastPresetMessage: String?
    @Published private(set) var presetLibraryItems: [RoutingPresetMetadata] = []
    @Published private(set) var presetLibraryAvailableTags: [String] = []
    @Published var presetLibrarySearchText = ""
    @Published var presetLibrarySelectedTags = Set<String>()
    private let persistence: RoutingGraphStore
    private let presetLibrary: RoutingPresetLibrary
    private let halSharedConfigURL: URL

    init(graph: RoutingGraph? = nil) {
        let supportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Heartecho", isDirectory: true)
        let fileURL = supportDirectory.appendingPathComponent("RoutingGraph.json")
        self.persistence = RoutingGraphStore(fileURL: fileURL)
        self.presetLibrary = RoutingPresetLibrary(directoryURL: supportDirectory.appendingPathComponent("Presets", isDirectory: true))
        self.halSharedConfigURL = supportDirectory.appendingPathComponent("HALSharedConfig.bin")
        self.graph = graph ?? (try? persistence.load()) ?? RoutingGraph()
        refreshPresetLibrary()
        save()
    }

    var selectedDevice: VirtualAudioDevice? {
        graph.selectedDevice
    }

    var filteredPresetLibraryItems: [RoutingPresetMetadata] {
        let query = presetLibrarySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedTagKeys = Set(presetLibrarySelectedTags.map(normalizedTagKey))

        return presetLibraryItems.filter { item in
            let itemTagKeys = Set(item.tags.map(normalizedTagKey))
            let tagsMatch = selectedTagKeys.isEmpty || selectedTagKeys.isSubset(of: itemTagKeys)
            let queryMatches = query.isEmpty ||
                item.name.localizedCaseInsensitiveContains(query) ||
                item.tags.contains { $0.localizedCaseInsensitiveContains(query) }

            return tagsMatch && queryMatches
        }
    }

    var selectedDeviceBinding: BindingValue<VirtualAudioDevice>? {
        guard let selectedID = graph.selectedDevice?.id,
              let index = graph.devices.firstIndex(where: { $0.id == selectedID }) else {
            return nil
        }

        return BindingValue(
            get: { self.graph.devices[index] },
            set: { self.graph.devices[index] = $0 }
        )
    }

    func addVirtualDevice() {
        let device = VirtualAudioDevice.starterDevice().renamed("Virtual Device \(graph.devices.count + 1)")
        graph.devices.append(device)
        graph.selectedDeviceID = device.id
        save()
    }

    func select(deviceID: UUID) {
        graph.selectedDeviceID = deviceID
        save()
    }

    func renameSelectedDevice(_ name: String) {
        let trimmed = sanitizedName(name)
        guard !trimmed.isEmpty else {
            return
        }

        mutateSelectedDevice { device in
            device.name = trimmed
        }
    }

    func toggleSelectedDeviceEnabled() {
        mutateSelectedDevice { device in
            device.isEnabled.toggle()
        }
    }

    func setSelectedDeviceEnabled(_ isEnabled: Bool) {
        mutateSelectedDevice { device in
            device.isEnabled = isEnabled
        }
    }

    func setSelectedDeviceSampleRate(_ sampleRate: Double) {
        guard Self.supportedSampleRates.contains(sampleRate) else {
            return
        }

        mutateSelectedDevice { device in
            device.sampleRate = sampleRate
        }
    }

    func setSelectedDeviceBufferFrameSize(_ frameSize: Int) {
        guard Self.supportedBufferFrameSizes.contains(frameSize) else {
            return
        }

        mutateSelectedDevice { device in
            device.bufferFrameSize = frameSize
        }
    }

    func setSelectedDeviceLatencyFrames(_ frameCount: Int) {
        mutateSelectedDevice { device in
            device.latencyFrames = min(max(0, frameCount), 4096)
        }
    }

    func setSelectedDeviceSafetyOffsetFrames(_ frameCount: Int) {
        mutateSelectedDevice { device in
            device.safetyOffsetFrames = min(max(0, frameCount), 4096)
        }
    }

    func removeSelectedDevice() {
        guard let selectedID = graph.selectedDeviceID ?? graph.devices.first?.id,
              graph.removeDevice(id: selectedID) else {
            return
        }

        save()
    }

    func addSource(kind: AudioSourceKind) {
        mutateSelectedDevice { device in
            let source = AudioSource(
                name: defaultSourceName(for: kind, count: device.sources.count + 1),
                kind: kind,
                channels: kind == .passThru ? AudioChannel.numbered(count: passThruChannelCount(for: device)) : AudioChannel.stereo()
            )
            device.sources.append(source)
            addDefaultRoutes(for: source, to: &device)
            if kind == .passThru {
                PassThruRouting.syncChannelsAndRoutes(device: &device)
            }
        }
    }

    func addSource(from systemDevice: SystemDeviceReference) {
        mutateSelectedDevice { device in
            let source = AudioSource(
                name: systemDevice.name,
                kind: .hardwareInput,
                sourceIdentifier: systemDevice.uid ?? systemDevice.id,
                channels: AudioChannel.numbered(count: systemDevice.channelCount)
            )
            device.sources.append(source)
            addDefaultRoutes(for: source, to: &device)
        }
    }

    func addSource(from application: ApplicationSourceReference) {
        mutateSelectedDevice { device in
            let source = AudioSource(
                name: application.name,
                kind: .application,
                sourceIdentifier: application.id,
                channels: AudioChannel.stereo()
            )
            device.sources.append(source)
            addDefaultRoutes(for: source, to: &device)
        }
    }

    func addSource(from specialSource: SpecialApplicationSource) {
        mutateSelectedDevice { device in
            let source = AudioSource(
                name: specialSource.name,
                kind: .application,
                sourceIdentifier: specialSource.sourceIdentifier,
                channels: AudioChannel.stereo()
            )
            device.sources.append(source)
            addDefaultRoutes(for: source, to: &device)
        }
    }

    func addSource(from virtualDevice: VirtualAudioDevice) {
        mutateSelectedDevice { device in
            guard virtualDevice.id != device.id else {
                return
            }
            let source = AudioSource(
                name: virtualDevice.name,
                kind: .virtualDevice,
                sourceIdentifier: virtualDevice.id.uuidString,
                channels: virtualDevice.outputChannels
            )
            device.sources.append(source)
            addDefaultRoutes(for: source, to: &device)
        }
    }

    func addOutputChannels(count: Int) {
        mutateSelectedDevice { device in
            guard device.outputChannels.count < RoutingGraphValidator.maximumChannelCount else {
                return
            }
            let currentCount = device.outputChannels.count
            let targetCount = min(currentCount + max(1, count), RoutingGraphValidator.maximumChannelCount)
            let newChannels = ((currentCount + 1)...targetCount).map {
                AudioChannel(index: $0, name: "Channel \($0)")
            }
            device.outputChannels.append(contentsOf: newChannels)
            PassThruRouting.syncChannelsAndRoutes(device: &device)
        }
    }

    func removeOutputChannelPair() {
        mutateSelectedDevice { device in
            guard device.outputChannels.count > 2 else {
                return
            }
            let removedIndexes = Set(device.outputChannels.suffix(2).map(\.index))
            device.outputChannels.removeLast(min(2, device.outputChannels.count - 2))
            device.routes.removeAll { removedIndexes.contains($0.outputChannelIndex) }
        }
    }

    func addMonitor(name: String = "Monitor") {
        mutateSelectedDevice { device in
            device.monitors.append(defaultMonitor(
                name: "\(name) \(device.monitors.count + 1)",
                channelCount: min(max(1, device.outputChannels.count), 2),
                sourceChannelCount: device.outputChannels.count
            ))
        }
    }

    func addMonitor(from systemDevice: SystemDeviceReference) {
        mutateSelectedDevice { device in
            device.monitors.append(defaultMonitor(
                name: systemDevice.name,
                deviceIdentifier: systemDevice.uid ?? systemDevice.id,
                channelCount: systemDevice.channelCount,
                sourceChannelCount: device.outputChannels.count
            ))
        }
    }

    func setMonitorDevice(monitorID: UUID, deviceIdentifier: String?, name: String? = nil) {
        mutateSelectedDevice { device in
            guard let index = device.monitors.firstIndex(where: { $0.id == monitorID }) else {
                return
            }
            device.monitors[index].deviceIdentifier = deviceIdentifier
            if let name {
                device.monitors[index].name = name
            }
        }
    }

    func setMonitorGain(monitorID: UUID, gain: Double) {
        mutateSelectedDevice { device in
            guard let index = device.monitors.firstIndex(where: { $0.id == monitorID }) else {
                return
            }
            device.monitors[index].gain = max(0, min(gain, 2))
        }
    }

    func addMonitorChannels(monitorID: UUID, count: Int) {
        mutateSelectedDevice { device in
            guard let index = device.monitors.firstIndex(where: { $0.id == monitorID }) else {
                return
            }

            let currentCount = device.monitors[index].channels.count
            let targetCount = min(currentCount + max(1, count), RoutingGraphValidator.maximumChannelCount)
            guard targetCount > currentCount else {
                return
            }

            let newChannels = ((currentCount + 1)...targetCount).map {
                AudioChannel(index: $0, name: "Channel \($0)")
            }
            device.monitors[index].channels.append(contentsOf: newChannels)
            addDefaultMonitorRoutes(for: &device.monitors[index], sourceChannelCount: device.outputChannels.count)
        }
    }

    func removeMonitorChannelPair(monitorID: UUID) {
        mutateSelectedDevice { device in
            guard let index = device.monitors.firstIndex(where: { $0.id == monitorID }),
                  device.monitors[index].channels.count > 2 else {
                return
            }

            let removeCount = min(2, device.monitors[index].channels.count - 2)
            let removedIndexes = Set(device.monitors[index].channels.suffix(removeCount).map(\.index))
            device.monitors[index].channels.removeLast(removeCount)
            device.monitors[index].routes.removeAll { removedIndexes.contains($0.monitorChannelIndex) }
        }
    }

    func addMonitorRoute(monitorID: UUID, sourceChannelIndex: Int, monitorChannelIndex: Int) {
        mutateSelectedDevice { device in
            guard device.outputChannels.contains(where: { $0.index == sourceChannelIndex }),
                  let monitorIndex = device.monitors.firstIndex(where: { $0.id == monitorID }),
                  device.monitors[monitorIndex].channels.contains(where: { $0.index == monitorChannelIndex }) else {
                return
            }

            let exists = device.monitors[monitorIndex].routes.contains {
                $0.sourceChannelIndex == sourceChannelIndex &&
                    $0.monitorChannelIndex == monitorChannelIndex
            }
            guard !exists else {
                return
            }

            device.monitors[monitorIndex].routes.append(MonitorRoute(
                sourceChannelIndex: sourceChannelIndex,
                monitorChannelIndex: monitorChannelIndex
            ))
        }
    }

    func removeMonitorRoute(monitorID: UUID, route: MonitorRoute) {
        mutateSelectedDevice { device in
            guard let monitorIndex = device.monitors.firstIndex(where: { $0.id == monitorID }) else {
                return
            }
            device.monitors[monitorIndex].routes.removeAll { $0.id == route.id }
        }
    }

    func toggleMonitorRoute(monitorID: UUID, route: MonitorRoute) {
        mutateSelectedDevice { device in
            guard let monitorIndex = device.monitors.firstIndex(where: { $0.id == monitorID }),
                  let routeIndex = device.monitors[monitorIndex].routes.firstIndex(where: { $0.id == route.id }) else {
                return
            }
            device.monitors[monitorIndex].routes[routeIndex].isMuted.toggle()
        }
    }

    func setMonitorRouteGain(monitorID: UUID, route: MonitorRoute, gain: Double) {
        mutateSelectedDevice { device in
            guard let monitorIndex = device.monitors.firstIndex(where: { $0.id == monitorID }),
                  let routeIndex = device.monitors[monitorIndex].routes.firstIndex(where: { $0.id == route.id }) else {
                return
            }
            device.monitors[monitorIndex].routes[routeIndex].gain = max(0, min(gain, 2))
        }
    }

    func toggleMonitor(monitorID: UUID) {
        mutateSelectedDevice { device in
            guard let index = device.monitors.firstIndex(where: { $0.id == monitorID }) else {
                return
            }
            device.monitors[index].isEnabled.toggle()
        }
    }

    func toggleMonitorMute(monitorID: UUID) {
        mutateSelectedDevice { device in
            guard let index = device.monitors.firstIndex(where: { $0.id == monitorID }) else {
                return
            }
            device.monitors[index].isMuted.toggle()
        }
    }

    func removeMonitor(monitorID: UUID) {
        mutateSelectedDevice { device in
            device.monitors.removeAll { $0.id == monitorID }
        }
    }

    func renameMonitor(monitorID: UUID, name: String) {
        let trimmed = sanitizedName(name)
        guard !trimmed.isEmpty else {
            return
        }

        mutateSelectedDevice { device in
            guard let index = device.monitors.firstIndex(where: { $0.id == monitorID }) else {
                return
            }
            device.monitors[index].name = trimmed
        }
    }

    func toggleRoute(_ route: ChannelRoute) {
        mutateSelectedDevice { device in
            guard let index = device.routes.firstIndex(where: { $0.id == route.id }) else {
                return
            }
            device.routes[index].isMuted.toggle()
        }
    }

    func addRoute(sourceID: UUID, sourceChannelIndex: Int, outputChannelIndex: Int) {
        mutateSelectedDevice { device in
            guard device.sources.contains(where: { source in
                source.id == sourceID && source.channels.contains(where: { $0.index == sourceChannelIndex })
            }) else {
                return
            }

            guard device.outputChannels.contains(where: { $0.index == outputChannelIndex }) else {
                return
            }

            let exists = device.routes.contains {
                $0.sourceID == sourceID &&
                    $0.sourceChannelIndex == sourceChannelIndex &&
                    $0.outputChannelIndex == outputChannelIndex
            }

            if !exists {
                device.routes.append(ChannelRoute(
                    sourceID: sourceID,
                    sourceChannelIndex: sourceChannelIndex,
                    outputChannelIndex: outputChannelIndex
                ))
            }
        }
    }

    func removeRoute(_ route: ChannelRoute) {
        mutateSelectedDevice { device in
            device.routes.removeAll { $0.id == route.id }
        }
    }

    func removeSource(_ source: AudioSource) {
        mutateSelectedDevice { device in
            device.sources.removeAll { $0.id == source.id }
            device.routes.removeAll { $0.sourceID == source.id }
        }
    }

    func renameSource(_ source: AudioSource, name: String) {
        let trimmed = sanitizedName(name)
        guard !trimmed.isEmpty else {
            return
        }

        mutateSelectedDevice { device in
            guard let index = device.sources.firstIndex(where: { $0.id == source.id }) else {
                return
            }
            device.sources[index].name = trimmed
        }
    }

    func toggleSource(_ source: AudioSource) {
        mutateSelectedDevice { device in
            guard let index = device.sources.firstIndex(where: { $0.id == source.id }) else {
                return
            }
            device.sources[index].isEnabled.toggle()
        }
    }

    func toggleSourceMute(_ source: AudioSource) {
        mutateSelectedDevice { device in
            guard let index = device.sources.firstIndex(where: { $0.id == source.id }) else {
                return
            }
            device.sources[index].isMuted.toggle()
        }
    }

    func setSourceMutesWhenCaptured(_ source: AudioSource, isEnabled: Bool) {
        guard source.kind == .application else {
            return
        }

        mutateSelectedDevice { device in
            guard let index = device.sources.firstIndex(where: { $0.id == source.id }) else {
                return
            }
            device.sources[index].mutesWhenCaptured = isEnabled
        }
    }

    func setSourceGain(_ source: AudioSource, gain: Double) {
        mutateSelectedDevice { device in
            guard let index = device.sources.firstIndex(where: { $0.id == source.id }) else {
                return
            }
            device.sources[index].gain = gain
        }
    }

    func toggleDeviceMute() {
        mutateSelectedDevice { device in
            device.isMuted.toggle()
        }
    }

    func setDeviceMasterGain(_ gain: Double) {
        mutateSelectedDevice { device in
            device.masterGain = max(0, min(gain, 2))
        }
    }

    func save() {
        try? persistence.save(graph)
        try? saveHALSharedConfig()
    }

    func presetData() throws -> Data {
        try RoutingGraphStore.encode(graph)
    }

    func setPresetMessage(_ message: String) {
        lastPresetMessage = message
    }

    func importPresetData(_ data: Data) {
        do {
            let importedGraph = try RoutingGraphStore.decode(data)
            guard !importedGraph.devices.isEmpty else {
                lastPresetMessage = "Preset does not contain any virtual devices."
                return
            }

            graph = importedGraph
            if graph.selectedDeviceID == nil || graph.selectedDevice == nil {
                graph.selectedDeviceID = graph.devices.first?.id
            }
            save()
            lastPresetMessage = "Preset imported."
        } catch {
            lastPresetMessage = "Preset import failed: \(error)"
        }
    }

    func importPresetDataToLibrary(_ data: Data, fallbackName: String, tagsText: String = "") {
        do {
            let metadata = try presetLibrary.importPresetData(
                data,
                fallbackName: fallbackName,
                tags: tags(from: tagsText)
            )
            refreshPresetLibrary()
            lastPresetMessage = "Preset saved to library: \(metadata.name)."
        } catch {
            lastPresetMessage = "Preset library import failed: \(error)"
        }
    }

    func saveCurrentGraphToPresetLibrary(name: String? = nil, tagsText: String = "") {
        do {
            let presetName = sanitizedName(name ?? selectedDevice?.name ?? "Heartecho Preset")
            let metadata = try presetLibrary.save(
                name: presetName,
                graph: graph,
                tags: tags(from: tagsText)
            )
            refreshPresetLibrary()
            lastPresetMessage = "Preset saved to library: \(metadata.name)."
        } catch {
            lastPresetMessage = "Preset save failed: \(error)"
        }
    }

    func applyPresetFromLibrary(id: UUID) {
        do {
            let preset = try presetLibrary.load(id: id)
            graph = preset.graph
            if graph.selectedDeviceID == nil || graph.selectedDevice == nil {
                graph.selectedDeviceID = graph.devices.first?.id
            }
            save()
            refreshPresetLibrary()
            lastPresetMessage = "Preset applied: \(preset.metadata.name)."
        } catch {
            lastPresetMessage = "Preset apply failed: \(error)"
        }
    }

    func deletePresetFromLibrary(id: UUID) {
        do {
            try presetLibrary.delete(id: id)
            refreshPresetLibrary()
            lastPresetMessage = "Preset deleted."
        } catch {
            lastPresetMessage = "Preset delete failed: \(error)"
        }
    }

    func refreshPresetLibrary() {
        presetLibraryItems = (try? presetLibrary.list()) ?? []
        presetLibraryAvailableTags = (try? presetLibrary.availableTags()) ?? []
        let availableTagKeys = Set(presetLibraryAvailableTags.map(normalizedTagKey))
        presetLibrarySelectedTags = presetLibrarySelectedTags.filter {
            availableTagKeys.contains(normalizedTagKey($0))
        }
    }

    func togglePresetLibraryTag(_ tag: String) {
        if presetLibrarySelectedTags.contains(tag) {
            presetLibrarySelectedTags.remove(tag)
        } else {
            presetLibrarySelectedTags.insert(tag)
        }
    }

    func clearPresetLibraryFilters() {
        presetLibrarySearchText = ""
        presetLibrarySelectedTags = []
    }

    func updatePresetLibraryTags(id: UUID, tagsText: String) {
        do {
            let metadata = try presetLibrary.updateTags(id: id, tags: tags(from: tagsText))
            refreshPresetLibrary()
            lastPresetMessage = "Preset tags updated: \(metadata.name)."
        } catch {
            lastPresetMessage = "Preset tag update failed: \(error)"
        }
    }

    func clearPresetMessage() {
        lastPresetMessage = nil
    }

    func setRouteGain(_ route: ChannelRoute, gain: Double) {
        mutateSelectedDevice { device in
            guard let index = device.routes.firstIndex(where: { $0.id == route.id }) else {
                return
            }
            device.routes[index].gain = gain
        }
    }

    private func mutateSelectedDevice(_ update: (inout VirtualAudioDevice) -> Void) {
        guard let selectedID = graph.selectedDeviceID,
              let index = graph.devices.firstIndex(where: { $0.id == selectedID }) else {
            return
        }
        update(&graph.devices[index])
        save()
    }

    private func saveHALSharedConfig() throws {
        let data = try HALDriverBridge.sharedConfigurationData(from: graph)
        try FileManager.default.createDirectory(at: halSharedConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: halSharedConfigURL, options: [.atomic])
        _ = try HALDriverBridge.publishSharedConfiguration(from: graph)
    }

    private func defaultSourceName(for kind: AudioSourceKind, count: Int) -> String {
        switch kind {
        case .application:
            return "Application \(count)"
        case .hardwareInput:
            return "Hardware Input \(count)"
        case .passThru:
            return "Pass-Thru \(count)"
        case .virtualDevice:
            return "Virtual Device \(count)"
        }
    }

    private func addDefaultRoutes(for source: AudioSource, to device: inout VirtualAudioDevice) {
        for channel in source.channels.prefix(device.outputChannels.count) {
            guard let output = device.outputChannels.first(where: { $0.index == channel.index }) else {
                continue
            }
            device.routes.append(ChannelRoute(
                sourceID: source.id,
                sourceChannelIndex: channel.index,
                outputChannelIndex: output.index
            ))
        }
    }

    private func defaultMonitor(
        name: String,
        deviceIdentifier: String? = nil,
        channelCount: Int,
        sourceChannelCount: Int
    ) -> Monitor {
        let channels = AudioChannel.numbered(count: min(max(1, channelCount), RoutingGraphValidator.maximumChannelCount))
        let defaultRoutes = (1...min(channels.count, max(1, sourceChannelCount))).map {
            MonitorRoute(sourceChannelIndex: $0, monitorChannelIndex: $0)
        }
        return Monitor(
            name: name,
            deviceIdentifier: deviceIdentifier,
            channels: channels,
            routes: defaultRoutes
        )
    }

    private func addDefaultMonitorRoutes(for monitor: inout Monitor, sourceChannelCount: Int) {
        for channel in monitor.channels where channel.index <= sourceChannelCount {
            let exists = monitor.routes.contains {
                $0.sourceChannelIndex == channel.index &&
                    $0.monitorChannelIndex == channel.index
            }

            if !exists {
                monitor.routes.append(MonitorRoute(
                    sourceChannelIndex: channel.index,
                    monitorChannelIndex: channel.index
                ))
            }
        }
    }

    private func passThruChannelCount(for device: VirtualAudioDevice) -> Int {
        min(max(1, device.outputChannels.count), RoutingGraphValidator.maximumChannelCount)
    }

    private func sanitizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tags(from text: String) -> [String] {
        RoutingPresetMetadata.normalizedTags(
            text.components(separatedBy: CharacterSet(charactersIn: ",#\n"))
        )
    }

    private func normalizedTagKey(_ tag: String) -> String {
        tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct BindingValue<Value> {
    var get: () -> Value
    var set: (Value) -> Void
}

extension VirtualAudioDevice {
    func renamed(_ name: String) -> VirtualAudioDevice {
        var copy = self
        copy.name = name
        return copy
    }
}

struct SystemDeviceReference: Hashable {
    var id: String
    var uid: String?
    var name: String
    var channelCount: Int
}

struct ApplicationSourceReference: Hashable {
    var id: String
    var name: String
}
