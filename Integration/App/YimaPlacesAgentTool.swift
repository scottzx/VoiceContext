import Foundation
import CoreFoundation
import UIKit

/// Search candidates are native MapKit results, scoped to one conversation.
@MainActor
enum YimaPlacesAgentTool {
    static let definition = AgentToolDefinition(
        name: "yima_places",
        description: "Search real places, manage Yima's local food-map favorites and user tags, display places in the app, or hand an explicit destination to Apple Maps. Search never saves. Search first, disambiguate names/branches/area with the user, and use the exact returned search_id and candidate_id to request a save. save opens a native confirmation sheet containing the real name, full address and resulting tags, and waits for the user's Confirm Save button; it never writes before that button. The foreground unlocked app is required for confirmation. Cancellation, stale candidates, timeout, unavailable presentation and write errors are not successful saves. Do not pass invented confirmation flags or tell the user to confirm on the map page. Raw names, addresses or coordinates cannot create favorites. Only use tags explicitly supplied by the user; no invented ratings. A new search invalidates prior candidates and pending confirmations in this conversation. Search source is separate from saved state; each result reports its actual saved state. list/get return real place_id and revision; update_tags/delete require that revision. Deleting requires the user's explicit deletion confirmation. A successful save or tag update does not authorize a page change: keep the current page unchanged after confirmation dismisses and give a brief factual receipt. Use show/navigate or app_navigation to change pages only when the user's current request explicitly asks to open the map, display places or navigate. If explicitly asked to save and display, wait for confirmed save, read fresh app_navigation.get_state, then show the returned place_id. show/navigate require expected_revision from app_navigation.get_state and the foreground unlocked app. Only visible confirms map display; only handoff_accepted confirms Apple Maps accepted the destination, not that navigation started. Executors and completion-notice turns cannot use this tool.",
        parameters: [
            "action": .init(type: .string, description: "Place action", enumValues: ["search", "list", "get", "save", "update_tags", "delete", "show", "navigate"]),
            "query": .init(type: .string, description: "For search: specific shop name or address; supply area when needed. For list/show without IDs: favorite name/address filter."),
            "area": .init(type: .string, description: "For search only: city or neighborhood explicitly supplied by the user; do not assume current location."),
            "search_id": .init(type: .string, description: "Exact current search_id returned in this conversation. Required with candidate_id; show can display all candidates from this search without saving."),
            "candidate_id": .init(type: .string, description: "Exact candidate_id returned by the current search; required for save, optional for show/navigate with search_id."),
            "place_id": .init(type: .string, description: "Exact saved place_id from list/get/save; required for get/update_tags/delete, optional for show/navigate."),
            "tag": .init(type: .string, description: "For list/show without IDs: exact user tag filter."),
            "tags": .init(type: .string, description: "JSON array of user-specified tag strings, e.g. [\"面食\",\"想去\"]. save merges these tags with an existing favorite; update_tags replaces all tags, and [] clears them."),
            "revision": .init(type: .integer, description: "Saved place revision from list/get, required for update_tags/delete."),
            "expected_revision": .init(type: .integer, description: "Current app_navigation.get_state revision, required for show/navigate.")
        ], required: ["action"]
    )

    private struct SearchBatch {
        let id: UUID
        let query: String
        let createdAt: Date
        var places: [YimaPlace]
    }
    private static var searches: [String: SearchBatch] = [:]
    private static let searchLifetime: TimeInterval = 30 * 60
    private static let maxSearchSessions = 24

    static func execute(_ args: [String: Any], sessionID: String?, sessionSource: String?,
                        isExecutor: Bool, noticeDriven: Bool, executionGeneration: UInt64?,
                        voiceNavigationGeneration: UInt64?) async -> (output: String, success: Bool) {
        let policy = AgentRuntimePolicies.policy(for: sessionSource)
        guard !isExecutor, !noticeDriven, sessionSource != "meeting_assistant",
              policy.allowedToolNames(noticeDriven: false)?.contains(definition.name) != false else {
            return result(["status": "forbidden", "message": "只有当前主会话的明确指令可以操作美食地图；子任务和完成通知回合不能操作。"], success: false)
        }
        guard let sessionID, !sessionID.isEmpty else {
            return result(["status": "unavailable", "message": "当前会话不可用。"], success: false)
        }
        func isCurrent() -> Bool {
            guard !Task.isCancelled else { return false }
            guard sessionSource == "xiaolan_voice" else { return true }
            guard let executionGeneration else { return false }
            return XiaolanVoiceController.shared.executionGeneration(sessionID: sessionID) == executionGeneration
        }
        guard isCurrent() else { return stale() }
        do {
            let action = try string(args, "action")
            let allowed: Set<String>
            switch action {
            case "search": allowed = ["action", "query", "area"]
            case "list": allowed = ["action", "query", "tag"]
            case "get": allowed = ["action", "place_id"]
            case "save": allowed = ["action", "search_id", "candidate_id", "tags"]
            case "update_tags": allowed = ["action", "place_id", "tags", "revision"]
            case "delete": allowed = ["action", "place_id", "revision"]
            case "show": allowed = ["action", "place_id", "search_id", "candidate_id", "query", "tag", "expected_revision"]
            case "navigate": allowed = ["action", "place_id", "search_id", "candidate_id", "expected_revision"]
            default: throw invalid("不支持此地点操作。")
            }
            guard Set(args.keys).isSubset(of: allowed) else { throw invalid("包含此操作不支持的参数。") }
            expireSearches()
            if action == "search" {
                let query = try string(args, "query")
                let area = try optionalString(args, "area")
                let searchID = UUID()
                // Reserve before awaiting so failed, cancelled and superseded searches
                // can never expose an earlier batch as the new search's candidates.
                searches[sessionID] = .init(id: searchID, query: query, createdAt: Date(), places: [])
                expireSearches()
                do {
                    let places = Array(try await YimaPlaceSearch.search(query: query, area: area).prefix(20))
                    guard isCurrent() else { invalidateSearch(sessionID: sessionID, id: searchID); return stale() }
                    guard searches[sessionID]?.id == searchID else { return stale() }
                    searches[sessionID]?.places = places
                    var body: [String: Any] = ["status": "available", "search_id": searchID.uuidString,
                                              "query": query, "source": "search", "candidates": places.map { summary($0, candidate: true) },
                                              "message": places.isEmpty ? "没有查到地点，请补充城市、分店或地址；本次没有保存收藏。" : "已查到真实地点，每项 saved 表示其实际收藏状态；同名或多个分店时请先让用户选择。收藏请求会弹窗核对名称、地址与标签，点击确认后才写入。"]
                    body.merge(savedState(places)) { _, new in new }
                    return result(body, success: true)
                } catch {
                    invalidateSearch(sessionID: sessionID, id: searchID)
                    guard isCurrent() else { return stale() }
                    throw error
                }
            }
            let store = YimaPlacesStore.shared
            guard store.available else { throw invalid(store.readError ?? "本地地点暂不可用。") }
            if action == "list" {
                let places = store.filtered(query: try optionalString(args, "query") ?? "", tag: try optionalString(args, "tag"))
                return result(["status": "available", "places": places.prefix(100).map { summary($0) },
                               "total_count": places.count, "all_tags": store.allTags], success: true)
            }
            if action == "get" {
                let place = try savedPlace(args, store: store)
                return result(["status": "available", "place": summary(place)], success: true)
            }
            if action == "save" {
                let candidate = try searchedPlaces(args, sessionID: sessionID, requiresCandidate: true).places[0]
                let tags = try tags(args, required: false)
                guard isCurrent() else { return stale() }
                let outcome = await YimaPlacesSaveConfirmation.shared.requestSave(place: candidate, tags: tags) {
                    guard isCurrent(),
                          let current = try? searchedPlaces(args, sessionID: sessionID, requiresCandidate: true).places.first else { return false }
                    return current.id == candidate.id
                }
                switch outcome {
                case .saved(let place):
                    return result(["status": "saved", "place": summary(place), "confirmed_by": "native_button",
                                   "message": "用户已在弹窗核对并点击确认，地点和标签已保存在 Yima；重复地点合并标签。"], success: true)
                case .cancelled:
                    return result(["status": "cancelled", "changed": false, "message": "用户取消了收藏确认，本次没有写入地点或标签。"], success: false)
                case .stale:
                    return stale()
                case .unavailable:
                    return result(["status": "unavailable", "changed": false,
                                   "message": "本次没有保存。请回到前台并解锁 Yima，先关闭其他设置或编辑弹窗，再发起收藏并点击“确认收藏”。"], success: false)
                case .busy:
                    return result(["status": "busy", "changed": false,
                                   "message": "已有收藏核对弹窗等待处理，本次没有保存。请先确认或取消当前弹窗。"], success: false)
                case .timedOut:
                    return result(["status": "timed_out", "changed": false, "message": "收藏核对等待超时，本次没有写入地点或标签。"], success: false)
                }
            }
            if action == "update_tags" || action == "delete" {
                let place = try savedPlace(args, store: store)
                let revision = try integer(args, "revision")
                guard isCurrent() else { return stale() }
                if action == "delete" {
                    try store.delete(id: place.id, expectedRevision: revision)
                    return result(["status": "deleted", "place_id": place.id.uuidString, "message": "已删除该地点收藏。"], success: true)
                }
                let updated = try store.updateTags(id: place.id, tags: tags(args, required: true), expectedRevision: revision)
                return result(["status": "saved", "place": summary(updated)], success: true)
            }
            let revision = try integer(args, "expected_revision")
            let center = AppNavigationCenter.shared
            let voice = policy.requiresNavigationBinding
            guard isCurrent() else { return stale() }
            guard center.available, UIApplication.shared.applicationState == .active else {
                return result(["status": "unavailable", "message": "请回到前台并解锁 Yima 后查看地图或交给苹果地图导航。"], success: false)
            }
            guard !voice || center.isVoiceBindingCurrent(sessionID: sessionID, generation: voiceNavigationGeneration),
                  center.state.revision == revision else {
                return result(["status": "stale", "message": "当前页面或语音请求已变化，请先读取当前页面状态；未强制打开旧地点。"], success: false)
            }
            guard !(args["place_id"] != nil && (args["search_id"] != nil || args["candidate_id"] != nil)) else {
                throw invalid("请只选择一个收藏地点或一批真实搜索结果。")
            }
            let places: [YimaPlace]
            let title: String
            let isSearchResult: Bool
            if args["place_id"] != nil {
                guard args["query"] == nil, args["tag"] == nil else { throw invalid("指定地点时不能同时筛选收藏。") }
                let place = try savedPlace(args, store: store)
                places = [place]; title = place.name; isSearchResult = false
            } else if args["search_id"] != nil || args["candidate_id"] != nil {
                guard args["query"] == nil, args["tag"] == nil else { throw invalid("搜索结果不能同时筛选收藏。") }
                let batch = try searchedPlaces(args, sessionID: sessionID, requiresCandidate: action == "navigate")
                places = batch.places; title = batch.query; isSearchResult = true
            } else {
                guard action == "show" else { throw invalid("请先从真实搜索结果或收藏中选择唯一导航地点。") }
                let tag = try optionalString(args, "tag")
                places = store.filtered(query: try optionalString(args, "query") ?? "", tag: tag)
                title = tag.map { "美食地图 · " + $0 } ?? "美食地图"; isSearchResult = false
            }
            if action == "show" {
                let presentationID = YimaPlacesPresentation.shared.create(places: places, title: title, isSearchResult: isSearchResult)
                let receipt = await center.navigate(routeID: "extension.places.show", params: ["presentation_id": presentationID.uuidString],
                                                    expectedRevision: revision, sessionID: voice ? sessionID : nil,
                                                    voiceGeneration: voice ? voiceNavigationGeneration : nil)
                guard isCurrent() else { return stale() }
                var body = receipt.dictionary
                body["presentation_id"] = presentationID.uuidString
                let displayed = livePlaces(places, isSearchResult: isSearchResult)
                body["count"] = displayed.count
                body["source"] = isSearchResult ? "search" : "favorites"
                body.merge(savedState(displayed)) { _, new in new }
                return result(body, success: receipt.success)
            }
            guard let place = places.first, places.count == 1 else { throw invalid("请先选择唯一的导航地点。") }
            let accepted = await YimaPlaceSearch.openInMaps(place)
            guard isCurrent() else { return stale() }
            return result(["status": accepted ? "handoff_accepted" : "failed", "place": summary(place, candidate: isSearchResult),
                           "message": accepted ? "苹果地图已接受目的地交接；是否开始导航由苹果地图和用户决定。" : "苹果地图未接受目的地交接。"], success: accepted)
        } catch {
            guard isCurrent() else { return stale() }
            return result(["status": "failed", "message": error.localizedDescription], success: false)
        }
    }

    private static func searchedPlaces(_ args: [String: Any], sessionID: String, requiresCandidate: Bool) throws -> (places: [YimaPlace], query: String) {
        let searchID = try uuid(args, "search_id")
        guard let batch = searches[sessionID], batch.id == searchID,
              Date().timeIntervalSince(batch.createdAt) < searchLifetime else { throw invalid("搜索结果已失效或不属于当前会话，请重新查找真实地点。") }
        if requiresCandidate || args["candidate_id"] != nil {
            let id = try uuid(args, "candidate_id")
            guard let place = batch.places.first(where: { $0.id == id }) else { throw invalid("候选地点不在本次真实搜索中，请重新查找。") }
            return ([place], batch.query)
        }
        guard !batch.places.isEmpty else { throw invalid("本次搜索没有可显示的地点。") }
        return (batch.places, batch.query)
    }

    private static func savedPlace(_ args: [String: Any], store: YimaPlacesStore) throws -> YimaPlace {
        guard let place = store.get(try uuid(args, "place_id")) else { throw invalid("收藏地点不存在，请重新读取收藏。") }
        return place
    }

    private static func summary(_ place: YimaPlace, candidate: Bool = false) -> [String: Any] {
        let store = YimaPlacesStore.shared
        let saved = candidate ? store.savedMatch(for: place) : store.get(place.id)
        let current = saved ?? place
        var body: [String: Any] = [candidate ? "candidate_id" : "place_id": place.id.uuidString, "name": current.name,
                                  "address": current.address, "tags": current.tags, "revision": current.revision,
                                  "coordinate_source": "mapkit"]
        if store.available {
            body["saved"] = saved != nil
            if let saved { body["place_id"] = saved.id.uuidString }
        } else {
            body["saved_state"] = "unavailable"
        }
        return body
    }

    private static func savedState(_ places: [YimaPlace]) -> [String: Any] {
        let store = YimaPlacesStore.shared
        guard store.available else { return ["saved_state": "unavailable"] }
        let savedCount = places.filter { store.savedMatch(for: $0) != nil }.count
        return ["saved": !places.isEmpty && savedCount == places.count,
                "saved_count": savedCount, "unsaved_count": places.count - savedCount]
    }

    private static func livePlaces(_ places: [YimaPlace], isSearchResult: Bool) -> [YimaPlace] {
        let store = YimaPlacesStore.shared
        var seen = Set<UUID>()
        return places.compactMap { place in
            let current = isSearchResult ? (store.savedMatch(for: place) ?? place) : store.get(place.id)
            guard let current, seen.insert(current.id).inserted else { return nil }
            return current
        }
    }

    private static func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = try optionalString(args, key) else { throw invalid("缺少参数：" + key) }
        return value
    }

    private static func optionalString(_ args: [String: Any], _ key: String) throws -> String? {
        guard let raw = args[key] else { return nil }
        guard let text = raw as? String else { throw invalid(key + " 必须是文字。") }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 300,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw invalid(key + " 为空、过长或含无效字符。") }
        return value
    }

    private static func uuid(_ args: [String: Any], _ key: String) throws -> UUID {
        guard let id = UUID(uuidString: try string(args, key)) else { throw invalid(key + " 必须来自真实工具回执。") }
        return id
    }

    private static func integer(_ args: [String: Any], _ key: String) throws -> Int {
        guard let number = args[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue < Double(Int.max) else { throw invalid(key + " 必须是从查询结果读取的非负整数。") }
        return number.intValue
    }

    private static func tags(_ args: [String: Any], required: Bool) throws -> [String] {
        guard let raw = args["tags"] else {
            if required { throw invalid("请提供 tags JSON 数组；空数组表示清除标签。") }
            return []
        }
        guard let text = raw as? String, text.utf8.count <= 8_192,
              let tags = try? JSONDecoder().decode([String].self, from: Data(text.utf8)),
              tags.count <= 20 else { throw invalid("tags 必须是最多 20 项的文字 JSON 数组。") }
        return try tags.map {
            guard let value = try optionalString(["tag": $0], "tag"), value.count <= 12 else { throw invalid("每个标签须为 1 至 12 个字符。") }
            return value
        }
    }

    private static func expireSearches() {
        let now = Date()
        searches = searches.filter { now.timeIntervalSince($0.value.createdAt) < searchLifetime }
        if searches.count > maxSearchSessions {
            for key in searches.sorted(by: { $0.value.createdAt < $1.value.createdAt }).prefix(searches.count - maxSearchSessions).map(\.key) {
                searches.removeValue(forKey: key)
            }
        }
    }

    private static func invalidateSearch(sessionID: String, id: UUID) {
        if searches[sessionID]?.id == id { searches.removeValue(forKey: sessionID) }
    }

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "Yima.Places", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func stale() -> (output: String, success: Bool) {
        result(["status": "stale", "message": "本次请求已取消、失效或被新的查询取代，未确认完成。"], success: false)
    }

    private static func result(_ body: [String: Any], success: Bool) -> (output: String, success: Bool) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return (String(decoding: data, as: UTF8.self), success)
    }
}
