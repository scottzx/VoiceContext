import Foundation

@MainActor
enum CustomExtensionsCLI {
    struct Result {
        let exitCode: Int
        let envelope: [String: Any]
    }

    static func execute(_ arguments: [String], store: CustomExtensionsStore? = nil) -> Result {
        var action = arguments.first { !["--compact", "-q", "--quiet"].contains($0) } ?? "unknown"
        do {
            let input = try parse(arguments)
            action = input.action
            let store = store ?? CustomExtensionsStore.shared
            guard store.available else { throw CustomExtensionsError.unavailable(store.readError ?? "Custom functions are unavailable.") }
            func required(_ key: String) throws -> String {
                guard let value = input.options[key], !value.isEmpty else { throw invalid("Missing \(key).") }
                return value
            }
            func selected() throws -> (index: Int, item: CustomExtensionItem) {
                guard let id = UUID(uuidString: try required("--id")) else { throw invalid("--id must be a UUID from list/get.") }
                guard let index = store.items.firstIndex(where: { $0.id == id }) else { throw CustomExtensionsError.missingItem }
                return (index, store.items[index])
            }
            func summary(_ item: CustomExtensionItem) -> [String: Any] {
                ["id": item.id.uuidString, "name": item.name, "url": item.url.absoluteString,
                 "position": store.items.firstIndex(where: { $0.id == item.id })!,
                 "has_logo": item.logoData != nil, "initial": item.fallbackInitial]
            }

            let data: [String: Any]
            switch action {
            case "list":
                data = ["items": store.items.map(summary), "count": store.items.count]
            case "get":
                data = ["item": summary(try selected().item)]
            case "add":
                let item = try store.add(name: required("--name"), url: CustomExtensionItem.validatedURL(required("--url")))
                data = ["item": summary(item)]
            case "update":
                var item = try selected().item
                guard input.options.count > 1 else { throw invalid("Provide --name, --url, or --clear-logo to update.") }
                if let name = input.options["--name"] { item.name = name }
                if let url = input.options["--url"] { item.url = try CustomExtensionItem.validatedURL(url) }
                if input.options["--clear-logo"] != nil { item.logoData = nil }
                try store.update(item)
                data = ["item": summary(store.items.first { $0.id == item.id }!)]
            case "move":
                let current = try selected()
                guard let position = Int(try required("--position")), store.items.indices.contains(position) else {
                    throw invalid("--position must be a zero-based final position within the list.")
                }
                try store.move(fromOffsets: IndexSet(integer: current.index), toOffset: position > current.index ? position + 1 : position)
                data = ["item": summary(current.item)]
            case "delete":
                let item = try selected().item
                try store.delete(id: item.id)
                data = ["id": item.id.uuidString, "deleted": true]
            default:
                throw invalid("Unknown command. Use yima-extensions --help.")
            }
            return result(action: action, data: data)
        } catch let error as ArgumentsError {
            return result(action: action, code: "invalid_args", message: error.message, exitCode: 2)
        } catch let error as CustomExtensionsError {
            switch error {
            case .invalidName, .invalidURL, .invalidMove, .changedItem:
                return result(action: action, code: "invalid_args", message: error.localizedDescription, exitCode: 2)
            case .missingItem:
                return result(action: action, code: "no_data", message: error.localizedDescription, exitCode: 1)
            case .unavailable:
                return result(action: action, code: "not_available", message: error.localizedDescription, exitCode: 4)
            }
        } catch {
            return result(action: action, code: "internal_error", message: error.localizedDescription, exitCode: 1)
        }
    }

    private struct ArgumentsError: Error { let message: String }
    private static func invalid(_ message: String) -> ArgumentsError { ArgumentsError(message: message) }

    private static func parse(_ arguments: [String]) throws -> (action: String, options: [String: String]) {
        let allowed: [String: Set<String>] = [
            "list": [], "get": ["--id"], "add": ["--name", "--url"],
            "update": ["--id", "--name", "--url", "--clear-logo"],
            "move": ["--id", "--position"], "delete": ["--id"]
        ]
        var action: String?
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            index += 1
            if ["--compact", "-q", "--quiet"].contains(token) { continue }
            guard let command = action else {
                guard allowed[token] != nil else { throw invalid("Missing or unknown command. Use yima-extensions --help.") }
                action = token
                continue
            }
            guard allowed[command]!.contains(token), options[token] == nil else {
                throw invalid("Unknown, repeated, or unsupported argument: \(token).")
            }
            if token == "--clear-logo" { options[token] = "true"; continue }
            guard index < arguments.count, !arguments[index].hasPrefix("--"),
                  !["-q", "-h"].contains(arguments[index]) else { throw invalid("Missing value for \(token).") }
            options[token] = arguments[index]
            index += 1
        }
        guard let action else { throw invalid("No command specified. Use yima-extensions --help.") }
        return (action, options)
    }

    private static func result(action: String, data: [String: Any]) -> Result {
        Result(exitCode: 0, envelope: ["ok": true, "tool": "yima-extensions", "action": action,
                                     "data": data, "timestamp": ISO8601DateFormatter().string(from: Date())])
    }

    private static func result(action: String, code: String, message: String, exitCode: Int) -> Result {
        Result(exitCode: exitCode, envelope: ["ok": false, "tool": "yima-extensions", "action": action,
                                            "error": ["code": code, "message": message],
                                            "timestamp": ISO8601DateFormatter().string(from: Date())])
    }
}
