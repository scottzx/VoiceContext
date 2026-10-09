import Foundation
import Combine

nonisolated struct CustomExtensionItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var url: URL
    var logoData: Data?

    init(id: UUID = UUID(), name: String, url: URL, logoData: Data? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.logoData = logoData
    }

    var fallbackInitial: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "?"
    }

    static func validatedURL(_ raw: String) throws -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              let url = components.url else { throw CustomExtensionsError.invalidURL }
        if let port = components.port, !(1...65535).contains(port) { throw CustomExtensionsError.invalidURL }
        // URLComponents accepts an empty port ("host:"), which is not a configured port.
        let authority = text.dropFirst(scheme.count + 3).prefix { !"/?#".contains($0) }
        guard !authority.hasSuffix(":") else { throw CustomExtensionsError.invalidURL }
        return url
    }
}

nonisolated enum CustomExtensionsError: LocalizedError {
    case invalidName, invalidURL, missingItem, invalidMove, changedItem
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidName: return NSLocalizedString("请输入功能名称。", comment: "Custom function validation")
        case .invalidURL: return NSLocalizedString("请输入完整的 http:// 或 https:// 地址，端口范围为 1–65535。", comment: "Custom function validation")
        case .missingItem: return NSLocalizedString("此功能已被删除，请重新打开。", comment: "Custom function validation")
        case .invalidMove: return NSLocalizedString("功能顺序已改变，请重新调整。", comment: "Custom function validation")
        case .changedItem: return NSLocalizedString("此功能已在其他位置更新，请关闭后重新打开再编辑。", comment: "Custom function edit conflict")
        case .unavailable(let message): return message
        }
    }
}

@MainActor
final class CustomExtensionsStore: ObservableObject {
    static let shared = CustomExtensionsStore()
    @Published private(set) var items: [CustomExtensionItem] = []
    @Published private(set) var readError: String?
    private let url: URL

    init(url: URL? = nil) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.url = url ?? root.appendingPathComponent("Yima/custom-extensions.json")
        do {
            items = try JSONDecoder().decode([CustomExtensionItem].self, from: Data(contentsOf: self.url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A new installation starts with an empty list.
        } catch {
            readError = error.localizedDescription
        }
    }

    var available: Bool { readError == nil }

    @discardableResult
    func add(name: String, url: URL, logoData: Data? = nil) throws -> CustomExtensionItem {
        let item = try normalized(CustomExtensionItem(name: name, url: url, logoData: logoData))
        try save(items + [item])
        return item
    }

    func update(_ item: CustomExtensionItem, expected: CustomExtensionItem? = nil) throws {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { throw CustomExtensionsError.missingItem }
        if let expected, items[index] != expected { throw CustomExtensionsError.changedItem }
        var updated = items
        updated[index] = try normalized(item)
        try save(updated)
    }

    func delete(id: UUID) throws {
        guard items.contains(where: { $0.id == id }) else { throw CustomExtensionsError.missingItem }
        try save(items.filter { $0.id != id })
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) throws {
        guard offsets.allSatisfy(items.indices.contains), (0...items.count).contains(destination) else {
            throw CustomExtensionsError.invalidMove
        }
        var updated = items
        let moving = offsets.map { items[$0] }
        for index in offsets.reversed() { updated.remove(at: index) }
        updated.insert(contentsOf: moving, at: destination - offsets.filter { $0 < destination }.count)
        try save(updated)
    }

    private func normalized(_ item: CustomExtensionItem) throws -> CustomExtensionItem {
        var item = item
        item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.name.isEmpty else { throw CustomExtensionsError.invalidName }
        item.url = try CustomExtensionItem.validatedURL(item.url.absoluteString)
        return item
    }

    private func save(_ updated: [CustomExtensionItem]) throws {
        guard available else { throw CustomExtensionsError.unavailable(readError ?? "自定义功能暂不可用。") }
        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        items = updated
    }
}
