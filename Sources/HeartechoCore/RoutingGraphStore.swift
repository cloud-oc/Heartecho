import Foundation

public struct RoutingGraphStore: Sendable {
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> RoutingGraph {
        let data = try Data(contentsOf: fileURL)
        return try Self.decode(data)
    }

    public func save(_ graph: RoutingGraph) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try Self.encode(graph)
        try data.write(to: fileURL, options: [.atomic])
    }

    public static func decode(_ data: Data) throws -> RoutingGraph {
        try JSONDecoder.loopback.decode(RoutingGraph.self, from: data)
    }

    public static func encode(_ graph: RoutingGraph) throws -> Data {
        try JSONEncoder.loopback.encode(graph)
    }
}

extension JSONEncoder {
    static var loopback: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var loopback: JSONDecoder {
        JSONDecoder()
    }
}
