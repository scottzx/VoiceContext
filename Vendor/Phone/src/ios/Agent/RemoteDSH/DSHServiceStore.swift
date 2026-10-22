import Foundation
import Combine
import Security
import Darwin

nonisolated struct DSHService: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var url: URL

    init(id: UUID = UUID(), name: String, url: URL) {
        self.id = id
        self.name = name
        self.url = url
    }

    static func validatedURL(_ raw: String) throws -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !text.contains("\\"),
              var parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { throw DSHServiceError.invalidURL }
        if let port = parts.port, !(1...65535).contains(port) { throw DSHServiceError.invalidURL }
        let authority = text.dropFirst(scheme.count + 3).prefix { !"/?#".contains($0) }
        guard !authority.hasSuffix(":"), parts.url != nil else { throw DSHServiceError.invalidURL }
        guard !isLoopback(host) else { throw DSHServiceError.loopbackURL }
        parts.scheme = scheme
        parts.host = host.lowercased()
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        parts.path = ""
        guard let url = parts.url else { throw DSHServiceError.invalidURL }
        return url
    }

    private static func isLoopback(_ raw: String) -> Bool {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
            .split(separator: "%", maxSplits: 1).first.map(String.init) ?? ""
        if host == "localhost" || host.hasSuffix(".localhost") || host == "ip6-localhost" { return true }
        var ipv4 = in_addr()
        if inet_aton(host, &ipv4) == 1 {
            let address = UInt32(bigEndian: ipv4.s_addr)
            return address == 0 || address >> 24 == 127
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, host, &ipv6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        let zeroPrefix = bytes.prefix(15).allSatisfy { $0 == 0 }
        if zeroPrefix && bytes[15] <= 1 { return true }
        let mapped = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255
        let compatible = bytes.prefix(12).allSatisfy { $0 == 0 }
        return (mapped || compatible) && (bytes[12] == 127 || bytes.suffix(4).allSatisfy { $0 == 0 })
    }
}

nonisolated enum DSHServiceError: LocalizedError {
    case invalidName, invalidURL, loopbackURL, missingToken, missingService, unavailable, keychain

    var errorDescription: String? {
        switch self {
        case .invalidName: return NSLocalizedString("请输入服务名称。", comment: "DSH service validation")
        case .invalidURL: return NSLocalizedString("请输入服务的 http:// 或 https:// 地址和端口，不要包含路径、登录信息、参数或片段。", comment: "DSH service validation")
        case .loopbackURL: return NSLocalizedString("localhost 和回环地址指向 iPhone 本机，请填写远程电脑的 Tailscale IP 或域名。", comment: "DSH service validation")
        case .missingToken: return NSLocalizedString("添加服务或更换地址时，请填写该服务的连接令牌。", comment: "DSH service validation")
        case .missingService: return NSLocalizedString("此服务已被移除，请重新打开。", comment: "DSH service validation")
        case .unavailable: return NSLocalizedString("远程服务设置无法读取，原始资料已保留。", comment: "DSH service storage")
        case .keychain: return NSLocalizedString("无法访问安全凭据，请解锁 iPhone 后重试。", comment: "DSH service storage")
        }
    }
}

@MainActor
final class DSHServiceStore: ObservableObject {
    static let shared = DSHServiceStore()
    @Published private(set) var services: [DSHService] = []
    @Published private(set) var readError: String?
    @Published var selectedServiceID: UUID? {
        didSet {
            if let selectedServiceID, !services.contains(where: { $0.id == selectedServiceID }) {
                self.selectedServiceID = nil
            }
            defaults.set(selectedServiceID?.uuidString, forKey: Self.selectionKey)
        }
    }

    private static let servicesKey = "Yima.dsh.services"
    private static let selectionKey = "Yima.dsh.selectedServiceID"
    private let defaults: UserDefaults
    private let readToken: (UUID) -> String?
    private let writeToken: (UUID, String?) throws -> Void
    private let deleteCookie: (URL) throws -> Void

    init(defaults: UserDefaults = .standard,
         readToken: ((UUID) -> String?)? = nil,
         writeToken: ((UUID, String?) throws -> Void)? = nil,
         deleteCookie: ((URL) throws -> Void)? = nil) {
        self.defaults = defaults
        self.readToken = readToken ?? { DSHCredentialKeychain.read(account: "token.\($0.uuidString)") }
        self.writeToken = writeToken ?? { try DSHCredentialKeychain.write($1, account: "token.\($0.uuidString)") }
        self.deleteCookie = deleteCookie ?? { try DSHCookieCredentialStore.delete(for: $0) }
        if let stored = defaults.object(forKey: Self.servicesKey) {
            do {
                guard let data = stored as? Data else { throw DSHServiceError.unavailable }
                let decoded = try JSONDecoder().decode([DSHService].self, from: data)
                guard Set(decoded.map(\.id)).count == decoded.count else { throw DSHServiceError.unavailable }
                services = try decoded.map(Self.normalized)
            } catch { readError = DSHServiceError.unavailable.localizedDescription }
        }
        let selected = defaults.string(forKey: Self.selectionKey).flatMap(UUID.init(uuidString:))
        selectedServiceID = services.contains(where: { $0.id == selected }) ? selected : nil
        defaults.set(selectedServiceID?.uuidString, forKey: Self.selectionKey)
    }

    var available: Bool { readError == nil }

    func token(for id: UUID) -> String? {
        guard services.contains(where: { $0.id == id }) else { return nil }
        return readToken(id)
    }

    func token(for id: UUID, matching url: URL) -> String? {
        guard let origin = try? DSHService.validatedURL(url.absoluteString),
              services.contains(where: { $0.id == id && $0.url == origin }) else { return nil }
        return readToken(id)
    }

    // nil retains an existing token. A new origin always needs its own credential.
    func save(service: DSHService, token: String?) throws {
        guard available else { throw DSHServiceError.unavailable }
        let service = try Self.normalized(service)
        let existing = services.first { $0.id == service.id }
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing?.url != service.url || token != nil {
            guard let token, !token.isEmpty,
                  !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw DSHServiceError.missingToken
            }
        }
        var updated = services
        if let index = updated.firstIndex(where: { $0.id == service.id }) { updated[index] = service }
        else { updated.append(service) }
        let data = try JSONEncoder().encode(updated)
        let previousToken = token == nil ? nil : readToken(service.id)
        if let token { try writeToken(service.id, token) }
        do {
            if token != nil { try deleteCookie(service.url) }
            if let existing, existing.url != service.url, !updated.contains(where: { $0.url == existing.url }) {
                try deleteCookie(existing.url)
            }
        } catch {
            if token != nil { try writeToken(service.id, previousToken) }
            throw error
        }
        defaults.set(data, forKey: Self.servicesKey)
        services = updated
        if token != nil {
            NotificationCenter.default.post(name: Notification.Name("Yima.dshServiceCredentialsDidChange"),
                                            object: service.id.uuidString)
        }
    }

    func remove(id: UUID) throws {
        guard available else { throw DSHServiceError.unavailable }
        guard let service = services.first(where: { $0.id == id }) else { throw DSHServiceError.missingService }
        let updated = services.filter { $0.id != id }
        let data = try JSONEncoder().encode(updated)
        let previousToken = readToken(id)
        try writeToken(id, nil)
        do {
            if !updated.contains(where: { $0.url == service.url }) { try deleteCookie(service.url) }
        } catch {
            try writeToken(id, previousToken)
            throw error
        }
        defaults.set(data, forKey: Self.servicesKey)
        services = updated
        if selectedServiceID == id { selectedServiceID = nil }
    }

    private static func normalized(_ input: DSHService) throws -> DSHService {
        var service = input
        service.name = service.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !service.name.isEmpty else { throw DSHServiceError.invalidName }
        service.url = try DSHService.validatedURL(service.url.absoluteString)
        return service
    }
}

nonisolated enum DSHCookieCredentialStore {
    static func cookie(for baseURL: URL) -> String? {
        DSHCredentialKeychain.read(account: account(for: baseURL))
    }

    static func save(cookie: String, for baseURL: URL) throws {
        guard !cookie.isEmpty, !cookie.contains("\r"), !cookie.contains("\n") else { throw DSHServiceError.keychain }
        try DSHCredentialKeychain.write(cookie, account: account(for: baseURL))
    }

    static func delete(for baseURL: URL) throws {
        try DSHCredentialKeychain.write(nil, account: account(for: baseURL))
    }

    private static func account(for url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        return "cookie.\(scheme)://\(url.host?.lowercased() ?? ""):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
}

nonisolated private enum DSHCredentialKeychain {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "com.yima.agent") + ".dsh" }

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    static func read(account: String) -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?, account: String) throws {
        let query = query(account: account)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw DSHServiceError.keychain }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw DSHServiceError.keychain
            }
        } else if status != errSecSuccess { throw DSHServiceError.keychain }
    }
}
