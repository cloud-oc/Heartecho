import Foundation

public struct RoutingPresetMetadata: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deviceCount: Int
    public var tags: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deviceCount: Int,
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deviceCount = deviceCount
        self.tags = Self.normalizedTags(tags)
    }

    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for tag in tags {
            let cleaned = tag
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "#", with: "")
            guard !cleaned.isEmpty else {
                continue
            }

            let folded = cleaned.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !seen.contains(folded) else {
                continue
            }

            seen.insert(folded)
            normalized.append(cleaned)
        }

        return normalized.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt
        case updatedAt
        case deviceCount
        case tags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        deviceCount = try container.decode(Int.self, forKey: .deviceCount)
        tags = Self.normalizedTags(try container.decodeIfPresent([String].self, forKey: .tags) ?? [])
    }
}

public struct RoutingPreset: Codable, Hashable, Sendable {
    public var metadata: RoutingPresetMetadata
    public var graph: RoutingGraph

    public init(metadata: RoutingPresetMetadata, graph: RoutingGraph) {
        self.metadata = metadata
        self.graph = graph
    }

    public init(name: String, graph: RoutingGraph, now: Date = Date(), tags: [String] = []) {
        self.metadata = RoutingPresetMetadata(
            name: name,
            createdAt: now,
            updatedAt: now,
            deviceCount: graph.devices.count,
            tags: tags
        )
        self.graph = graph
    }
}

public enum RoutingPresetLibraryError: Error, CustomStringConvertible, Sendable {
    case emptyName
    case emptyGraph
    case presetNotFound(UUID)
    case invalidFileName

    public var description: String {
        switch self {
        case .emptyName:
            return "Preset name cannot be empty."
        case .emptyGraph:
            return "Preset must contain at least one virtual device."
        case .presetNotFound(let id):
            return "Preset \(id.uuidString) was not found."
        case .invalidFileName:
            return "Preset file name is invalid."
        }
    }
}

public struct RoutingPresetLibrary: Sendable {
    public var directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func list() throws -> [RoutingPresetMetadata] {
        try ensureDirectory()
        let urls = try presetFileURLs()
        let presets = urls.compactMap { url in
            try? load(from: url).metadata
        }
        return presets.sorted {
            if $0.updatedAt == $1.updatedAt {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.updatedAt > $1.updatedAt
        }
    }

    public func search(query: String = "", tags: [String] = []) throws -> [RoutingPresetMetadata] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requiredTags = Set(RoutingPresetMetadata.normalizedTags(tags).map(normalizedTagKey))

        return try list().filter { metadata in
            let metadataTags = Set(metadata.tags.map(normalizedTagKey))
            let tagsMatch = requiredTags.isEmpty || requiredTags.isSubset(of: metadataTags)
            let queryMatches = trimmedQuery.isEmpty ||
                metadata.name.localizedCaseInsensitiveContains(trimmedQuery) ||
                metadata.tags.contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }

            return tagsMatch && queryMatches
        }
    }

    public func availableTags() throws -> [String] {
        RoutingPresetMetadata.normalizedTags(try list().flatMap(\.tags))
    }

    @discardableResult
    public func save(name: String, graph: RoutingGraph, now: Date = Date(), tags: [String] = []) throws -> RoutingPresetMetadata {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw RoutingPresetLibraryError.emptyName
        }
        guard !graph.devices.isEmpty else {
            throw RoutingPresetLibraryError.emptyGraph
        }

        try ensureDirectory()
        let preset = RoutingPreset(name: trimmedName, graph: graph, now: now, tags: tags)
        let url = fileURL(for: preset.metadata.id, name: trimmedName)
        try encode(preset).write(to: url, options: [.atomic])
        return preset.metadata
    }

    @discardableResult
    public func updateTags(id: UUID, tags: [String], now: Date = Date()) throws -> RoutingPresetMetadata {
        guard let url = try presetFileURLs().first(where: { presetID(from: $0) == id }) else {
            throw RoutingPresetLibraryError.presetNotFound(id)
        }

        var preset = try load(from: url)
        preset.metadata.tags = RoutingPresetMetadata.normalizedTags(tags)
        preset.metadata.updatedAt = now
        preset.metadata.deviceCount = preset.graph.devices.count
        try encode(preset).write(to: url, options: [.atomic])
        return preset.metadata
    }

    public func load(id: UUID) throws -> RoutingPreset {
        guard let url = try presetFileURLs().first(where: { presetID(from: $0) == id }) else {
            throw RoutingPresetLibraryError.presetNotFound(id)
        }
        return try load(from: url)
    }

    public func delete(id: UUID) throws {
        guard let url = try presetFileURLs().first(where: { presetID(from: $0) == id }) else {
            throw RoutingPresetLibraryError.presetNotFound(id)
        }
        try FileManager.default.removeItem(at: url)
    }

    public func importPresetData(_ data: Data, fallbackName: String, now: Date = Date(), tags: [String] = []) throws -> RoutingPresetMetadata {
        let preset = try Self.decodePresetOrGraph(data, fallbackName: fallbackName, now: now)
        let mergedTags = RoutingPresetMetadata.normalizedTags(preset.metadata.tags + tags)
        return try save(name: preset.metadata.name, graph: preset.graph, now: now, tags: mergedTags)
    }

    public static func decodePresetOrGraph(_ data: Data, fallbackName: String, now: Date = Date()) throws -> RoutingPreset {
        if let preset = try? JSONDecoder.loopback.decode(RoutingPreset.self, from: data) {
            return preset
        }

        let graph = try RoutingGraphStore.decode(data)
        let name = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
        return RoutingPreset(name: name.isEmpty ? "Imported Preset" : name, graph: graph, now: now)
    }

    public static func encode(_ preset: RoutingPreset) throws -> Data {
        try JSONEncoder.loopback.encode(preset)
    }

    private func load(from url: URL) throws -> RoutingPreset {
        try Self.decodePresetOrGraph(
            Data(contentsOf: url),
            fallbackName: url.deletingPathExtension().lastPathComponent
        )
    }

    private func encode(_ preset: RoutingPreset) throws -> Data {
        try Self.encode(preset)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func presetFileURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return []
        }

        return try FileManager.default
            .contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    private func fileURL(for id: UUID, name: String) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString)-\(slug(name)).json")
    }

    private func presetID(from url: URL) -> UUID? {
        let fileName = url.deletingPathExtension().lastPathComponent
        let prefix = fileName.prefix(36)
        return UUID(uuidString: String(prefix))
    }

    private func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let parts = value
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
        let slug = parts.joined(separator: "-").lowercased()
        return slug.isEmpty ? "preset" : slug
    }

    private func normalizedTagKey(_ tag: String) -> String {
        tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
