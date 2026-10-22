import Foundation

/// A server session never shares a navigation/cache key with a local session.
struct DSHSessionRoute: Equatable {
    let serviceID: UUID
    let sessionID: String

    var isDraft: Bool { sessionID.hasPrefix("__new__") }
    var rawValue: String { "dsh:\(serviceID.uuidString):\(sessionID)" }

    init(serviceID: UUID, sessionID: String) {
        self.serviceID = serviceID
        self.sessionID = sessionID
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "dsh", let id = UUID(uuidString: String(parts[1])),
              !parts[2].isEmpty else { return nil }
        serviceID = id
        sessionID = String(parts[2])
    }

    static func draft(serviceID: UUID) -> Self {
        Self(serviceID: serviceID, sessionID: "__new__\(UUID().uuidString)")
    }
}
