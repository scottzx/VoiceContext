import Foundation
import Combine

/// Host-only checks. No iOS application, device, or simulator is launched.
@main
struct CustomExtensionsCLITests {
    private static let logo = Data("PRIVATE-LOGO-FIXTURE-\u{1}-\u{2}-\u{3}".utf8)

    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Yima.CustomExtensionsCLITests.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("custom-extensions.json")
        let store = CustomExtensionsStore(url: url)
        var publications: [[UUID]] = []
        let observation = store.$items.dropFirst().sink { publications.append($0.map(\.id)) }
        defer { observation.cancel() }

        let empty = checked(["list"], store: store, action: "list")
        precondition(empty["count"] as? Int == 0 && (empty["items"] as? [[String: Any]])?.isEmpty == true)
        let address = "http://100.101.102.103:8787/workbench?folder=alpha%20beta&view=1#details"
        let added = checked(["--compact", "add", "--name", "  中文工具 👩🏽‍💻  ", "--quiet", "--url", address, "-q"], store: store, action: "add")
        let first = store.items[0]
        precondition(first.name == "中文工具 👩🏽‍💻" && first.url.absoluteString == address)
        checkItem(added["item"] as! [String: Any], expected: first, position: 0)
        precondition(publications == [[first.id]], "CLI mutations must publish to the same store observed by the UI")

        // A UI-created logo is visible immediately through the injected shared store.
        let uiItem = try store.add(name: "e\u{301}lan", url: URL(string: "http://localhost:3000/")!, logoData: logo)
        let got = checked(["--quiet", "get", "--id", uiItem.id.uuidString], store: store, action: "get")
        checkItem(got["item"] as! [String: Any], expected: uiItem, position: 1)
        precondition((got["item"] as! [String: Any])["initial"] as? String == "E\u{301}")
        let emojiResult = checked(["add", "--name", "👩🏽‍💻 Lab", "--url", "http://[::1]:8080/path?q=one#two"], store: store, action: "add")
        let emojiItem = store.items[2]
        checkItem(emojiResult["item"] as! [String: Any], expected: emojiItem, position: 2)
        precondition(emojiItem.fallbackInitial == "👩🏽‍💻")
        for flags in [["--compact", "list"], ["list", "-q"], ["list", "--quiet"], ["--compact", "list", "--quiet", "-q"]] {
            checkList(checked(flags, store: store, action: "list"), expected: store.items)
        }

        let originalOrder = store.items.map(\.id)
        checked(["update", "--id", uiItem.id.uuidString, "--name", "  改名工具  "], store: store, action: "update")
        precondition(store.items.map(\.id) == originalOrder && store.items[1].name == "改名工具")
        precondition(store.items[1].url == uiItem.url && store.items[1].logoData == logo, "Name-only updates must preserve URL and logo")
        let changedURL = "https://host.tail123.ts.net:8443/tools?mode=wide%20view#tab"
        let edited = checked(["update", "--id", uiItem.id.uuidString, "--url", changedURL], store: store, action: "update")
        precondition(store.items[1].name == "改名工具" && store.items[1].url.absoluteString == changedURL)
        precondition(store.items[1].logoData == logo && store.items.map(\.id) == originalOrder, "URL-only updates must preserve name, logo, identity, and order")
        checkItem(edited["item"] as! [String: Any], expected: store.items[1], position: 1)
        checked(["update", "--id", uiItem.id.uuidString, "--clear-logo"], store: store, action: "update")
        precondition(store.items[1].logoData == nil && store.items[1].name == "改名工具" && store.items[1].url.absoluteString == changedURL)
        precondition(store.items.map(\.id) == originalOrder)

        let moved = checked(["move", "--id", first.id.uuidString, "--position", "2"], store: store, action: "move")
        precondition(store.items.map(\.id) == [uiItem.id, emojiItem.id, first.id])
        checkItem(moved["item"] as! [String: Any], expected: first, position: 2)
        checked(["move", "--id", first.id.uuidString, "--position", "0"], store: store, action: "move")
        precondition(store.items.map(\.id) == originalOrder, "Moving backward must also use a zero-based final position")
        checked(["move", "--id", emojiItem.id.uuidString, "--position", "2"], store: store, action: "move")
        checkList(checked(["list"], store: store, action: "list"), expected: store.items)
        precondition(CustomExtensionsStore(url: url).items == store.items, "CLI updates and ordering must survive reload")

        let id = first.id.uuidString
        let invalidArguments: [[String]] = [
            [], ["unknown"], ["-q"], ["list", "get"], ["list", "--unknown"], ["list", "--id", id],
            ["get"], ["get", "--id"], ["get", "--id", "--compact"], ["get", "--id", id, "--id", id],
            ["add", "--name", "Thing"], ["add", "--url", address], ["add", "--name", "Thing", "--url"],
            ["add", "--name", "Thing", "--url", address, "--name", "Again"],
            ["add", "--name", "--clear-logo", "--url", address], ["add", "--name", "--url", "--url", address],
            ["add", "--name", "-q", "--url", address], ["add", "--name", "Thing", "--url", address, "--clear-logo"],
            ["update", "--id", id], ["update", "--id", id, "--name", "--clear-logo"],
            ["update", "--id", id, "--clear-logo", "false"], ["update", "--id", id, "--clear-logo", "--clear-logo"],
            ["move", "--id", id], ["move", "--id", id, "--position", "--compact"],
            ["delete"], ["delete", "--id", id, "--name", "Unexpected"]
        ]
        let beforeInvalid = publications.count
        for arguments in invalidArguments {
            try rejectedWithoutMutation(arguments, store: store, url: url, code: "invalid_args", exitCode: 2)
        }
        for invalidURL in ["localhost:3000", "javascript:alert(1)", "file:///tmp/index.html", "http://localhost:0", "http://localhost:65536", "http://localhost:", "http://local host:3000", "http://localhost/a b"] {
            try rejectedWithoutMutation(["add", "--name", "Invalid", "--url", invalidURL], store: store, url: url, code: "invalid_args", exitCode: 2)
            try rejectedWithoutMutation(["update", "--id", id, "--url", invalidURL], store: store, url: url, code: "invalid_args", exitCode: 2)
        }
        for position in ["-1", "3", "1.5", "one"] {
            try rejectedWithoutMutation(["move", "--id", id, "--position", position], store: store, url: url, code: "invalid_args", exitCode: 2)
        }
        try rejectedWithoutMutation(["add", "--name", " \n", "--url", address], store: store, url: url, code: "invalid_args", exitCode: 2)
        try rejectedWithoutMutation(["update", "--id", id, "--name", ""], store: store, url: url, code: "invalid_args", exitCode: 2)
        for action in ["get", "update", "move", "delete"] {
            let extra = action == "update" ? ["--name", "New"] : action == "move" ? ["--position", "0"] : []
            try rejectedWithoutMutation([action, "--id", "invalid-uuid"] + extra, store: store, url: url, code: "invalid_args", exitCode: 2)
            try rejectedWithoutMutation([action, "--id", UUID().uuidString] + extra, store: store, url: url, code: "no_data", exitCode: 1)
        }
        precondition(publications.count == beforeInvalid, "Rejected operations must not publish a changed list")

        let beforeDelete = store.items.filter { $0.id != emojiItem.id }
        let deleted = checked(["delete", "--id", emojiItem.id.uuidString], store: store, action: "delete")
        precondition(deleted["id"] as? String == emojiItem.id.uuidString && deleted["deleted"] as? Bool == true)
        precondition(store.items == beforeDelete && CustomExtensionsStore(url: url).items == beforeDelete)
        try rejectedWithoutMutation(["get", "--id", emojiItem.id.uuidString], store: store, url: url, code: "no_data", exitCode: 1)
        try rejectedWithoutMutation(["delete", "--id", emojiItem.id.uuidString], store: store, url: url, code: "no_data", exitCode: 1)

        let corruptURL = root.appendingPathComponent("corrupt.json")
        let corruptData = Data("{not-json".utf8)
        try corruptData.write(to: corruptURL)
        let corruptStore = CustomExtensionsStore(url: corruptURL)
        checked(["list"], store: corruptStore, action: "list", code: "not_available", exitCode: 4)
        try rejectedWithoutMutation(["add", "--name", "New", "--url", address], store: corruptStore, url: corruptURL, code: "not_available", exitCode: 4)
        let preservedCorruptData = try Data(contentsOf: corruptURL)
        precondition(preservedCorruptData == corruptData, "Unavailable storage must never return an empty successful list or overwrite existing data")

        try checkUIEditConflicts(root: root)

        let beforeFailedWrites = store.items
        let beforeFailedPublications = publications.count
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let sentinel = url.appendingPathComponent("preserve-me")
        try logo.write(to: sentinel)
        for arguments in [["add", "--name", "New", "--url", address], ["update", "--id", id, "--name", "New"], ["move", "--id", id, "--position", "1"], ["delete", "--id", id]] {
            checked(arguments, store: store, code: "internal_error", exitCode: 1)
            precondition(store.items == beforeFailedWrites, "Failed persistence must preserve the shared UI store")
            let preservedSentinel = try Data(contentsOf: sentinel)
            precondition(preservedSentinel == logo)
        }
        precondition(publications.count == beforeFailedPublications)
        print("PASS: custom extension CLI CRUD, shared-store publication, Unicode/URL fidelity, final-position moves, strict parsing, result envelopes, logo privacy, stale UI edit protection, corruption protection, and failed-write consistency")
    }

    @MainActor
    private static func checkUIEditConflicts(root: URL) throws {
        let url = root.appendingPathComponent("edit-conflicts.json")
        let store = CustomExtensionsStore(url: url)
        let opening = try store.add(name: "Original", url: URL(string: "http://localhost:3000/original")!, logoData: logo)
        let companion = try store.add(name: "Companion", url: URL(string: "http://localhost:4000/")!)
        var publicationCount = 0
        let observation = store.$items.dropFirst().sink { _ in publicationCount += 1 }
        defer { observation.cancel() }

        let changedURL = "http://100.101.102.103:8181/new?source=cli#updated"
        checked(["update", "--id", opening.id.uuidString, "--url", changedURL, "--clear-logo"], store: store, action: "update")
        let before = store.items
        let bytes = try Data(contentsOf: url)
        let beforePublications = publicationCount
        var staleDraft = opening
        staleDraft.name = "Name from the open UI editor"
        do {
            try store.update(staleDraft, expected: opening)
            preconditionFailure("A stale UI editor must not restore an older CLI URL or logo")
        } catch CustomExtensionsError.changedItem {}
        let after = try Data(contentsOf: url)
        precondition(store.items == before && after == bytes && publicationCount == beforePublications)
        precondition(store.items[0].url.absoluteString == changedURL && store.items[0].logoData == nil)

        let currentOpening = store.items[0]
        var currentDraft = currentOpening
        currentDraft.name = "Name from a fresh UI editor"
        try store.update(currentDraft, expected: currentOpening)
        precondition(store.items == [currentDraft, companion], "A current snapshot must still allow editing")
        precondition(CustomExtensionsStore(url: url).items == store.items && publicationCount == beforePublications + 1)

        let beforeReorderOpening = store.items[0]
        checked(["move", "--id", opening.id.uuidString, "--position", "1"], store: store, action: "move")
        var reorderedDraft = beforeReorderOpening
        reorderedDraft.name = "Edited after reordering"
        try store.update(reorderedDraft, expected: beforeReorderOpening)
        precondition(store.items == [companion, reorderedDraft], "Reordering alone must not invalidate the edited item snapshot")
        precondition(reorderedDraft.url.absoluteString == changedURL && reorderedDraft.logoData == nil)
        precondition(CustomExtensionsStore(url: url).items == store.items && publicationCount == beforePublications + 3)
    }

    @MainActor
    @discardableResult
    private static func checked(_ arguments: [String], store: CustomExtensionsStore, action: String? = nil,
                                code: String? = nil, exitCode: Int = 0) -> [String: Any] {
        let result = CustomExtensionsCLI.execute(arguments, store: store)
        precondition(result.exitCode == exitCode, "Unexpected exit code for \(arguments): \(result.envelope)")
        let envelope = result.envelope
        precondition(envelope["ok"] as? Bool == (code == nil) && envelope["tool"] as? String == "yima-extensions")
        precondition(envelope["action"] is String)
        if let action { precondition(envelope["action"] as? String == action) }
        precondition(ISO8601DateFormatter().date(from: envelope["timestamp"] as! String) != nil)
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        precondition(!json.contains(logo.base64EncodedString()) && !json.contains("logoData") && !json.contains("logo_data"), "CLI output must not expose logo bytes")
        if let code {
            precondition(envelope["data"] == nil)
            let error = envelope["error"] as! [String: Any]
            precondition(error["code"] as? String == code && !(error["message"] as! String).isEmpty)
            return [:]
        }
        precondition(envelope["error"] == nil)
        return envelope["data"] as! [String: Any]
    }

    @MainActor
    private static func rejectedWithoutMutation(_ arguments: [String], store: CustomExtensionsStore, url: URL,
                                                code: String, exitCode: Int) throws {
        let before = store.items
        let bytes = try Data(contentsOf: url)
        checked(arguments, store: store, code: code, exitCode: exitCode)
        let after = try Data(contentsOf: url)
        precondition(store.items == before && after == bytes, "Rejected arguments mutated storage: \(arguments)")
    }

    @MainActor
    private static func checkItem(_ summary: [String: Any], expected: CustomExtensionItem, position: Int) {
        precondition(Set(summary.keys) == Set(["id", "name", "url", "position", "has_logo", "initial"]))
        precondition(summary["id"] as? String == expected.id.uuidString && summary["name"] as? String == expected.name)
        precondition(summary["url"] as? String == expected.url.absoluteString && summary["position"] as? Int == position)
        precondition(summary["has_logo"] as? Bool == (expected.logoData != nil) && summary["initial"] as? String == expected.fallbackInitial)
    }

    @MainActor
    private static func checkList(_ data: [String: Any], expected: [CustomExtensionItem]) {
        precondition(data["count"] as? Int == expected.count)
        let summaries = data["items"] as! [[String: Any]]
        precondition(summaries.count == expected.count)
        for index in expected.indices { checkItem(summaries[index], expected: expected[index], position: index) }
    }
}
