import Foundation

/// Short-lived, native-owned snapshots let a visible route identify exactly
/// which search results were requested without turning them into favorites.
@MainActor
final class YimaPlacesPresentation {
    static let shared = YimaPlacesPresentation()

    struct Request: Identifiable {
        let id: UUID
        let places: [YimaPlace]
        let title: String
        let isSearchResult: Bool
    }

    private var requests: [Request] = []

    func create(places: [YimaPlace], title: String, isSearchResult: Bool) -> UUID {
        let request = Request(id: UUID(), places: places, title: title, isSearchResult: isSearchResult)
        requests.append(request)
        if requests.count > 20 { requests.removeFirst(requests.count - 20) }
        return request.id
    }

    func request(id: UUID) -> Request? { requests.first { $0.id == id } }
}
