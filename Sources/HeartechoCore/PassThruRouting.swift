import Foundation

public enum PassThruRouting {
    public static func syncChannelsAndRoutes(device: inout VirtualAudioDevice) {
        let targetChannelCount = min(
            max(1, device.outputChannels.count),
            RoutingGraphValidator.maximumChannelCount
        )

        for sourceIndex in device.sources.indices where device.sources[sourceIndex].kind == .passThru {
            if device.sources[sourceIndex].channels.count < targetChannelCount {
                let existingIndexes = Set(device.sources[sourceIndex].channels.map(\.index))
                for index in 1...targetChannelCount where !existingIndexes.contains(index) {
                    device.sources[sourceIndex].channels.append(AudioChannel(index: index, name: "Channel \(index)"))
                }
            }

            let source = device.sources[sourceIndex]
            for channel in source.channels {
                guard device.outputChannels.contains(where: { $0.index == channel.index }) else {
                    continue
                }

                let routeExists = device.routes.contains {
                    $0.sourceID == source.id &&
                        $0.sourceChannelIndex == channel.index &&
                        $0.outputChannelIndex == channel.index
                }

                if !routeExists {
                    device.routes.append(ChannelRoute(
                        sourceID: source.id,
                        sourceChannelIndex: channel.index,
                        outputChannelIndex: channel.index
                    ))
                }
            }
        }
    }
}
