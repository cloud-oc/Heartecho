import Foundation

public struct RoutingGraph: Codable, Hashable, Sendable {
    public var devices: [VirtualAudioDevice]
    public var selectedDeviceID: UUID?

    public init(devices: [VirtualAudioDevice] = [VirtualAudioDevice.starterDevice()], selectedDeviceID: UUID? = nil) {
        self.devices = devices
        self.selectedDeviceID = selectedDeviceID ?? devices.first?.id
    }

    public var selectedDevice: VirtualAudioDevice? {
        guard let selectedDeviceID else {
            return devices.first
        }
        return devices.first { $0.id == selectedDeviceID } ?? devices.first
    }

    @discardableResult
    public mutating func removeDevice(id: UUID) -> Bool {
        guard devices.count > 1,
              let removedIndex = devices.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let removedDeviceID = devices[removedIndex].id
        let selectedID = selectedDeviceID
        let nextSelectionID: UUID?

        if let selectedID,
           selectedID != removedDeviceID,
           devices.contains(where: { $0.id == selectedID }) {
            nextSelectionID = selectedID
        } else {
            let nextSelectionIndex = removedIndex == devices.count - 1 ? removedIndex - 1 : removedIndex + 1
            nextSelectionID = devices[nextSelectionIndex].id
        }

        devices.remove(at: removedIndex)
        selectedDeviceID = nextSelectionID.flatMap { id in
            devices.contains(where: { $0.id == id }) ? id : devices.first?.id
        }
        removeNestedSourcesReferencing(deviceID: removedDeviceID)
        return true
    }

    private mutating func removeNestedSourcesReferencing(deviceID: UUID) {
        let removedDeviceIdentifier = deviceID.uuidString

        for index in devices.indices {
            let removedSourceIDs = Set(devices[index].sources.compactMap { source in
                source.kind == .virtualDevice && source.sourceIdentifier == removedDeviceIdentifier ? source.id : nil
            })

            guard !removedSourceIDs.isEmpty else {
                continue
            }

            devices[index].sources.removeAll { removedSourceIDs.contains($0.id) }
            devices[index].routes.removeAll { removedSourceIDs.contains($0.sourceID) }
        }
    }
}
