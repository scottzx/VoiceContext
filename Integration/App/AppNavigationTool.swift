import Foundation
import CoreFoundation

@MainActor
enum AppNavigationTool {
    static let definition = AgentToolDefinition(
        name: "app_navigation",
        description: "Inspect the installed in-app route tree or current visible page, and navigate to an existing first or second level app page or return with its native back action. Use tree to discover actual route IDs and exact parameter names; use get_state to obtain revision before navigate/back. Navigate/back require expected_revision and never create, delete or complete business items. Only a visible receipt confirms the destination appeared. Stale, failed, busy or unavailable receipts must not be described as successful navigation. Background executors cannot control app UI. This tool does not capture screenshots or read page contents.",
        parameters: [
            "action": AgentToolParam(type: .string, description: "Requested app navigation action", enumValues: ["tree", "get_state", "navigate", "back"]),
            "route": AgentToolParam(type: .string, description: "An exact installed route ID from tree; required for navigate"),
            "params": AgentToolParam(type: .string, description: "A JSON object containing only the declared route parameters, each a string. Example: {\"date\":\"2026-10-17\"}. Omit for routes with no parameters."),
            "expected_revision": AgentToolParam(type: .integer, description: "The current get_state revision. Required for navigate and back; stale requests do not change the page.")
        ],
        required: ["action"]
    )

    struct Invocation {
        let action: String
        let routeID: String?
        let params: [String: String]
        let expectedRevision: Int?
    }

    static func routeTree(center: AppNavigationCenter, customItems: [CustomExtensionItem]) -> [[String: Any]] {
        AppRouteCatalog.descriptors.filter { center.supportedRoutes.contains($0.id) }.map { descriptor in
            var route = descriptor.dictionary
            if descriptor.id == "extension.custom" {
                route["destinations"] = customItems.map { ["id": $0.id.uuidString, "title": $0.name] }
            }
            return route
        }
    }

    static func invocation(_ args: [String: Any]) throws -> Invocation {
        func invalid(_ message: String) -> NSError {
            NSError(domain: "Yima.AppNavigation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let action = args["action"] as? String, ["tree", "get_state", "navigate", "back"].contains(action) else { throw invalid("Unsupported navigation action.") }
        let allowed: Set<String> = action == "navigate" ? ["action", "route", "params", "expected_revision"] : action == "back" ? ["action", "expected_revision"] : ["action"]
        guard Set(args.keys).isSubset(of: allowed) else { throw invalid("Unexpected navigation argument.") }
        var revision: Int?
        if action == "navigate" || action == "back" {
            guard let number = args["expected_revision"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= 0, number.doubleValue < Double(Int.max) else { throw invalid("expected_revision must be a non-negative integer from get_state.") }
            revision = number.intValue
        }
        var params: [String: String] = [:]
        if let raw = args["params"] {
            guard let json = raw as? String, json.utf8.count <= 4_096,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let values = object as? [String: String] else { throw invalid("params must be a bounded JSON object of strings.") }
            params = values
        }
        var routeID: String?
        if action == "navigate" {
            guard let route = args["route"] as? String else { throw invalid("navigate requires route.") }
            if let error = AppRouteCatalog.validate(routeID: route, params: params) { throw invalid(error) }
            routeID = route
        }
        return .init(action: action, routeID: routeID, params: params, expectedRevision: revision)
    }

    static func execute(_ args: [String: Any], sessionID: String?, sessionSource: String?,
                        isExecutor: Bool, voiceGeneration: UInt64?, blocksAppUI: Bool = false) async -> (output: String, success: Bool) {
        let center = AppNavigationCenter.shared
        func output(_ value: [String: Any], success: Bool) -> (output: String, success: Bool) {
            let json = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            return (String(decoding: json, as: UTF8.self), success)
        }
        guard !isExecutor && !blocksAppUI else { return output(["status": "forbidden", "message": "Background execution reports to the main assistant and cannot control app UI."], success: false) }
        let request: Invocation
        do { request = try invocation(args) }
        catch { return output(["status": "invalid_arguments", "message": error.localizedDescription], success: false) }
        guard center.available else { return output(["status": "unavailable", "message": "App navigation requires the foreground, unlocked app."], success: false) }
        let voice = AgentRuntimePolicies.policy(for: sessionSource).requiresNavigationBinding
        if voice && !center.isVoiceBindingCurrent(sessionID: sessionID, generation: voiceGeneration) {
            return output(["status": "stale", "message": "This voice request is no longer active."], success: false)
        }
        switch request.action {
        case "tree":
            return output(["status": "available", "routes": routeTree(center: center, customItems: CustomExtensionsStore.shared.items)], success: true)
        case "get_state":
            return output(["status": "available", "state": center.state.dictionary], success: true)
        case "navigate":
            if request.routeID == "artifact.preview", let id = request.params["artifact_id"],
               id.split(separator: ":").first.map(String.init) != sessionID {
                return output(["status": "forbidden", "message": "Only artifacts owned by this conversation can be opened by its assistant."], success: false)
            }
            let result = await center.navigate(routeID: request.routeID!, params: request.params,
                                               expectedRevision: request.expectedRevision!,
                                               sessionID: voice ? sessionID : nil, voiceGeneration: voice ? voiceGeneration : nil)
            return output(result.dictionary, success: result.success)
        default:
            let result = await center.back(expectedRevision: request.expectedRevision!,
                                           sessionID: voice ? sessionID : nil, voiceGeneration: voice ? voiceGeneration : nil)
            return output(result.dictionary, success: result.success)
        }
    }
}
