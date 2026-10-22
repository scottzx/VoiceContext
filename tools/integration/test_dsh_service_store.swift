import Foundation

@main
struct DSHServiceStoreChecks {
    @MainActor
    static func main() throws {
        let suite = "DSHServiceStoreChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = TestCredentials()
        let store = makeStore(defaults, credentials)
        precondition(store.available && store.services.isEmpty && store.selectedServiceID == nil)

        let origin = try DSHService.validatedURL(" HTTPS://SCOTT-MAC.example.ts.net:443/ ")
        precondition(origin.absoluteString == "https://scott-mac.example.ts.net")
        precondition(tryURL("http://100.88.227.56:3080/")?.absoluteString == "http://100.88.227.56:3080")
        precondition(tryURL("http://[fd7a:115c:a1e0::1]:3080") != nil)
        for text in [
            "", "example.ts.net", "ftp://example.ts.net", "http://example.ts.net/chat",
            "http://example.ts.net?token=test-secret", "https://example.ts.net#test-secret",
            "http://user:test-secret@example.ts.net", "http://@example.ts.net",
            "http://example.ts.net:", "http://example.ts.net:0", "http://example.ts.net:65536",
            "http://example .ts.net", "http://example.ts.net\\@localhost",
            "http://localhost:3080", "http://LOCALHOST./", "http://app.localhost",
            "http://127.0.0.1:3080", "http://127.5.4.3", "http://127.1", "http://2130706433",
            "http://0x7f000001", "http://0.0.0.0", "http://[::1]", "http://[::]",
            "http://[::ffff:127.0.0.1]", "http://[::7f00:1]", "http://[::1%25lo0]"
        ] {
            precondition(tryURL(text) == nil, "Unsafe service URL was accepted")
        }

        var service = DSHService(name: " 办公室电脑 ", url: origin)
        expectRejection { try store.save(service: service, token: nil) }
        expectRejection { try store.save(service: service, token: "\n ") }
        expectRejection { try store.save(service: DSHService(name: " ", url: origin), token: "test-token") }
        precondition(store.services.isEmpty && credentials.tokens.isEmpty)

        try store.save(service: service, token: " test-token ")
        service.name = "办公室电脑"
        precondition(store.services == [service] && store.token(for: service.id) == "test-token")
        let metadata = defaults.data(forKey: "Yima.dsh.services")!
        let rows = try JSONSerialization.jsonObject(with: metadata) as! [[String: Any]]
        precondition(Set(rows[0].keys) == ["id", "name", "url"])
        precondition(!String(decoding: metadata, as: UTF8.self).contains("test-token"), "Secrets must stay out of metadata")

        store.selectedServiceID = service.id
        let reopened = makeStore(defaults, credentials)
        precondition(reopened.services == [service] && reopened.selectedServiceID == service.id)
        reopened.selectedServiceID = UUID()
        precondition(reopened.selectedServiceID == nil && makeStore(defaults, credentials).selectedServiceID == nil)

        service.name = "家里电脑"
        try store.save(service: service, token: nil)
        precondition(store.services == [service] && store.token(for: service.id) == "test-token")
        let before = defaults.data(forKey: "Yima.dsh.services")
        credentials.failWrites = true
        expectRejection { try store.save(service: service, token: "replacement") }
        precondition(defaults.data(forKey: "Yima.dsh.services") == before && credentials.tokens[service.id] == "test-token")
        credentials.failWrites = false

        var changedOrigin = service
        changedOrigin.url = URL(string: "https://other.example.ts.net")!
        expectRejection { try store.save(service: changedOrigin, token: nil) }
        precondition(store.services == [service], "Changing origins must never reuse another host's token")
        credentials.failCookieDeletes = true
        expectRejection { try store.save(service: changedOrigin, token: "replacement") }
        precondition(store.services == [service] && credentials.tokens[service.id] == "test-token")
        expectRejection { try store.remove(id: service.id) }
        precondition(store.services == [service] && credentials.tokens[service.id] == "test-token")
        credentials.failCookieDeletes = false

        try store.save(service: changedOrigin, token: "replacement")
        precondition(store.services == [changedOrigin] && store.token(for: service.id) == "replacement")
        precondition(store.token(for: service.id, matching: origin) == nil,
                     "A stale view model must not send the replacement token to the previous origin")
        precondition(store.token(for: service.id, matching: changedOrigin.url) == "replacement")
        store.selectedServiceID = service.id
        try store.remove(id: service.id)
        precondition(store.services.isEmpty && store.selectedServiceID == nil && credentials.tokens.isEmpty)
        precondition(makeStore(defaults, credentials).services.isEmpty)
        precondition(store.token(for: service.id) == nil)

        let corruptBytes = Data("not-json".utf8)
        defaults.set(corruptBytes, forKey: "Yima.dsh.services")
        let corrupt = makeStore(defaults, credentials)
        precondition(!corrupt.available && corrupt.readError != nil)
        expectRejection { try corrupt.save(service: service, token: "test-token") }
        precondition(defaults.data(forKey: "Yima.dsh.services") == corruptBytes)

        defaults.set(try JSONEncoder().encode([service, service]), forKey: "Yima.dsh.services")
        precondition(!makeStore(defaults, credentials).available)
        var invalid = service
        invalid.url = URL(string: "http://localhost:3080")!
        defaults.set(try JSONEncoder().encode([invalid]), forKey: "Yima.dsh.services")
        precondition(!makeStore(defaults, credentials).available, "Persisted service URLs must also be validated")
        defaults.set("invalid-storage-type", forKey: "Yima.dsh.services")
        precondition(!makeStore(defaults, credentials).available, "Invalid metadata must not be treated as a new installation")
    }

    private static func tryURL(_ text: String) -> URL? { try? DSHService.validatedURL(text) }

    @MainActor
    private static func makeStore(_ defaults: UserDefaults, _ credentials: TestCredentials) -> DSHServiceStore {
        DSHServiceStore(defaults: defaults, readToken: { credentials.tokens[$0] }, writeToken: { id, value in
            if credentials.failWrites { throw DSHServiceError.keychain }
            credentials.tokens[id] = value
        }, deleteCookie: { url in
            if credentials.failCookieDeletes { throw DSHServiceError.keychain }
            credentials.deletedCookieOrigins.append(url)
        })
    }

    private static func expectRejection(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected the operation to fail") }
        catch { }
    }
}

@MainActor
private final class TestCredentials {
    var tokens: [UUID: String] = [:]
    var failWrites = false
    var failCookieDeletes = false
    var deletedCookieOrigins: [URL] = []
}
