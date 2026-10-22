import Foundation
import Combine

nonisolated struct YimaPlace: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var tags: [String]
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
    // Opaque MapKit coordinates: retain the original values for MapKit display and handoff.
    var coordinateSource: String

    init(id: UUID = UUID(), name: String, address: String, latitude: Double, longitude: Double,
         tags: [String] = [], revision: Int = 1, createdAt: Date = Date(), updatedAt: Date = Date(),
         coordinateSource: String = "mapkit") {
        self.id = id; self.name = name; self.address = address
        self.latitude = latitude; self.longitude = longitude; self.tags = tags
        self.revision = revision; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.coordinateSource = coordinateSource
    }
}

nonisolated enum YimaPlacesError: LocalizedError {
    case invalid(String), missingItem, changedItem, unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .unavailable(let message): return message
        case .missingItem: return "此地点已被删除，请重新打开。"
        case .changedItem: return "此地点已在其他位置更新，请关闭后重新打开再编辑。"
        }
    }
}

nonisolated private struct YimaPlacesFile: Codable {
    var schemaVersion = 1
    var items: [YimaPlace]
}

@MainActor
final class YimaPlacesStore: ObservableObject {
    static let shared = YimaPlacesStore()
    @Published private(set) var items: [YimaPlace] = []
    @Published private(set) var readError: String?
    private let url: URL

    init(url: URL? = nil) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.url = url ?? root.appendingPathComponent("Yima/places.json")
        do {
            let file = try JSONDecoder().decode(YimaPlacesFile.self, from: Data(contentsOf: self.url))
            guard file.schemaVersion == 1 else { throw YimaPlacesError.invalid("地点收藏版本不受支持，请升级应用。") }
            guard Set(file.items.map(\.id)).count == file.items.count else {
                throw YimaPlacesError.invalid("地点收藏标识重复，原始资料已保留。")
            }
            items = try file.items.map(normalized)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A new installation starts with an empty list.
        } catch {
            readError = "地点收藏无法读取，原始资料已保留：" + error.localizedDescription
        }
    }

    var available: Bool { readError == nil }

    var allTags: [String] {
        normalizedTags(items.flatMap(\.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func get(_ id: UUID) -> YimaPlace? { items.first { $0.id == id } }

    func savedMatch(for candidate: YimaPlace) -> YimaPlace? {
        items.first { $0.id == candidate.id || samePlace($0, candidate) }
    }

    func filtered(query: String = "", tag: String? = nil) -> [YimaPlace] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { place in
            (tag == nil || place.tags.contains { textKey($0) == textKey(tag!) }) &&
            (query.isEmpty || ([place.name, place.address] + place.tags).contains { $0.localizedStandardContains(query) })
        }
    }

    @discardableResult
    func save(_ candidate: YimaPlace, tags: [String]) throws -> YimaPlace {
        try requireAvailable()
        var place = try normalized(candidate)
        if let index = items.firstIndex(where: { $0.id == place.id || samePlace($0, place) }) {
            guard samePlace(items[index], place) else { throw YimaPlacesError.changedItem }
            let merged = normalizedTags(items[index].tags + place.tags + tags)
            if merged == items[index].tags { return items[index] }
            return try updateTags(id: items[index].id, tags: merged, expectedRevision: items[index].revision)
        }
        place.tags = normalizedTags(place.tags + tags)
        place.revision = 1
        place.createdAt = Date(); place.updatedAt = place.createdAt
        try persist(items + [place])
        return place
    }

    @discardableResult
    func updateTags(id: UUID, tags: [String], expectedRevision: Int) throws -> YimaPlace {
        try requireAvailable()
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw YimaPlacesError.missingItem }
        guard items[index].revision == expectedRevision, expectedRevision < Int.max else { throw YimaPlacesError.changedItem }
        var updated = items
        updated[index].tags = normalizedTags(tags)
        updated[index].revision += 1
        updated[index].updatedAt = max(Date(), updated[index].createdAt)
        try persist(updated)
        return updated[index]
    }

    func delete(id: UUID, expectedRevision: Int) throws {
        try requireAvailable()
        guard let place = get(id) else { throw YimaPlacesError.missingItem }
        guard place.revision == expectedRevision else { throw YimaPlacesError.changedItem }
        try persist(items.filter { $0.id != id })
    }

    private func normalized(_ input: YimaPlace) throws -> YimaPlace {
        var place = input
        place.name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
        place.address = place.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !place.name.isEmpty, !place.address.isEmpty else { throw YimaPlacesError.invalid("地点名称和地址不能为空。") }
        guard place.latitude.isFinite, place.longitude.isFinite,
              (-90...90).contains(place.latitude), (-180...180).contains(place.longitude),
              place.coordinateSource == "mapkit" else {
            throw YimaPlacesError.invalid("地点坐标或来源无效，请重新使用地图查找。")
        }
        guard place.revision > 0, place.createdAt.timeIntervalSince1970.isFinite,
              place.updatedAt.timeIntervalSince1970.isFinite, place.updatedAt >= place.createdAt else {
            throw YimaPlacesError.invalid("地点版本或保存时间无效，原始资料已保留。")
        }
        place.tags = normalizedTags(place.tags)
        return place
    }

    private func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { raw in
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return !tag.isEmpty && seen.insert(textKey(tag)).inserted ? tag : nil
        }
    }

    private func textKey(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func samePlace(_ first: YimaPlace, _ second: YimaPlace) -> Bool {
        guard textKey(first.name) == textKey(second.name), textKey(first.address) == textKey(second.address) else { return false }
        // A conservative 30 m proximity check, only between coordinates from the same MapKit source.
        let latitude = (first.latitude - second.latitude) * .pi / 180
        let longitude = (first.longitude - second.longitude) * .pi / 180
        let a = pow(sin(latitude / 2), 2) + cos(first.latitude * .pi / 180) * cos(second.latitude * .pi / 180) * pow(sin(longitude / 2), 2)
        return 6_371_000 * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a))) <= 30
    }

    private func requireAvailable() throws {
        guard available else { throw YimaPlacesError.unavailable(readError ?? "地点收藏暂不可用。") }
    }

    private func persist(_ updated: [YimaPlace]) throws {
        try requireAvailable()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(YimaPlacesFile(items: updated))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        items = updated
    }
}
