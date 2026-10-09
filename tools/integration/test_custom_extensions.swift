import Foundation

/// Runs on macOS; no iOS application, device, or simulator is launched.
@main
struct CustomExtensionsTests {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Yima.CustomExtensionsTests.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("nested/custom-extensions.json")
        let store = CustomExtensionsStore(url: url)
        precondition(store.available && store.items.isEmpty)

        for address in ["http://localhost:3000", "http://100.101.102.103:8080/tools?q=hello%20world#top", "https://mac.tail123.ts.net:65535/path", "http://[::1]:1234/"] {
            let parsed = try CustomExtensionItem.validatedURL(" \n" + address + "\t")
            precondition(parsed.absoluteString == address, "Preserve configured host, port, path, query, and fragment")
        }
        for address in ["", "localhost:3000", "//localhost:3000", "file:///tmp/index.html", "javascript:alert(1)", "ftp://localhost", "https:///path", "http://", "http://localhost:0", "http://localhost:65536", "http://localhost:-1", "http://localhost:", "http://localhost:abc", "http://local host:3000", "http://localhost/a b", "http://localhost/\npath"] {
            expectFailure { _ = try CustomExtensionItem.validatedURL(address) }
        }
        let local = try CustomExtensionItem.validatedURL("http://localhost:3000/tools?q=1")
        let logo = Data([0, 1, 2, 3])
        let first = try store.add(name: "  工具一 \n", url: local, logoData: logo)
        let second = try store.add(name: "alpha", url: local)
        let third = try store.add(name: "👩🏽‍💻 Coding", url: local)
        let fourth = try store.add(name: "cafe", url: local)
        precondition(first.name == "工具一" && first.fallbackInitial == "工")
        precondition(second.fallbackInitial == "A" && third.fallbackInitial == "👩🏽‍💻")
        let accented = CustomExtensionItem(name: "  e\u{301}lan", url: local)
        precondition(accented.fallbackInitial == "E\u{301}", "Fallback must preserve the entire first grapheme")
        precondition(CustomExtensionItem(name: " \n", url: local).fallbackInitial == "?")
        expectFailure { _ = try store.add(name: " \n", url: local) }
        precondition(CustomExtensionsStore(url: url).items == [first, second, third, fourth])

        try store.move(fromOffsets: IndexSet([0, 2]), toOffset: 4)
        precondition(store.items == [second, fourth, first, third])
        try store.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        precondition(store.items == [third, second, fourth, first])
        precondition(CustomExtensionsStore(url: url).items == store.items, "Order must survive relaunch")
        let beforeInvalidMove = store.items
        expectFailure { try store.move(fromOffsets: IndexSet(integer: 8), toOffset: 0) }
        expectFailure { try store.move(fromOffsets: IndexSet(integer: 0), toOffset: 8) }
        precondition(store.items == beforeInvalidMove)

        var edited = first
        edited.name = " renamed "
        edited.url = try CustomExtensionItem.validatedURL("https://server.tail123.ts.net:8443/path?key=one")
        edited.logoData = nil
        try store.update(edited)
        edited.name = "renamed"
        precondition(store.items == [third, second, fourth, edited], "Editing must preserve identity, order, and other entries")
        try store.delete(id: second.id)
        precondition(CustomExtensionsStore(url: url).items == [third, fourth, edited], "Deletion must preserve all other entries")

        let brokenURL = root.appendingPathComponent("broken.json")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: brokenURL)
        let broken = CustomExtensionsStore(url: brokenURL)
        precondition(!broken.available && broken.readError != nil)
        expectFailure { _ = try broken.add(name: "New", url: local) }
        let remainingData = try Data(contentsOf: brokenURL)
        precondition(remainingData == corrupt, "Decode failures must never overwrite existing data")

        // A directory at the destination causes atomic writing to fail on macOS.
        let previous = store.items
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        expectFailure { try store.delete(id: third.id) }
        precondition(store.items == previous, "A failed write must leave the published list unchanged")
        print("PASS: custom extension URL validation, grapheme fallback, persistence, editing, ordering, deletion, corrupt-file preservation, and failed-write consistency")
    }

    @MainActor
    private static func expectFailure(_ operation: () throws -> Void) {
        do {
            try operation()
            preconditionFailure("Expected operation to fail")
        } catch {}
    }
}
