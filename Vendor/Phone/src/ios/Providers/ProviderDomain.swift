import Foundation

/// Foundation-only provider identity shared by the iOS configuration store and
/// the macOS Runtime. UI labels, built-in catalogs and authentication clients
/// deliberately live in platform-specific extensions.
public enum ProviderType: String, Codable, CaseIterable, Hashable, Sendable {
    case openAI
    case anthropic
    case gemini
    case antigravity
    case openRouter
    case openAIResponses
    case xAI
    case kimiCode
    /// [T-copilot-provider] GitHub Copilot via an UNOFFICIAL reverse-engineered
    /// integration: RFC 8628 device-code sign-in to GitHub, then a short-lived
    /// Copilot session token. The chat surface is OpenAI-compatible, so it
    /// flows through OpenAIProvider like xAI/Kimi. Opt-in, warned about in the
    /// sign-in UI, and hideable via CopilotConstants.isEnabled.
    case githubCopilot
    /// A newer peer may persist a provider this build cannot execute yet.
    case unsupported

    /// Decodes unknown persisted values without losing the surrounding record.
    public static func decoded(_ raw: String) -> ProviderType {
        ProviderType(rawValue: raw) ?? .unsupported
    }

    /// Whether an OAuth instance of this provider can discover its model list
    /// from the network, rather than only reporting a compiled-in catalog.
    ///
    /// [T-provider-oauth-model-discovery] This drives the one-shot refresh
    /// `ProviderConfigStore.addInstance` fires after a provider is added, so a
    /// freshly-authenticated account shows the vendor's CURRENT models instead
    /// of whatever this build happened to ship with (GH#265: xAI OAuth seeded a
    /// static catalog with no grok-4.6, and only a manual Settings → Models →
    /// Refresh fixed it).
    ///
    /// Deliberately a property of the TYPE rather than a check at the call
    /// site: the same question is asked of every provider, and the answer is a
    /// fact about how that provider's OAuth branch in
    /// `fetchModelsForInstance` is implemented. Keeping it here means adding a
    /// provider means answering it, instead of silently inheriting "no".
    ///
    /// `false` for the two whose OAuth branch returns a static list without a
    /// request — refreshing them would spend a network round-trip to arrive
    /// back at the catalog already seeded.
    public var oauthSupportsModelDiscovery: Bool {
        switch self {
        case .anthropic, .gemini, .antigravity, .openRouter, .xAI, .kimiCode, .githubCopilot:
            // These OAuth branches all reach a real /models endpoint.
            return true
        case .openAI:
            // OpenAIModelsAPI.fetchModelsOAuth() is a compiled-in list.
            return false
        case .openAIResponses:
            // Responses-API instances are API-key only; the OAuth branch
            // returns builtInModels.
            return false
        case .unsupported:
            // Synced from a newer build — nothing to fetch with.
            return false
        }
    }
}

/// How a provider instance obtains its credential. The secret itself is never
/// part of this value domain.
public enum ProviderCredential: String, Codable, Hashable, Sendable {
    case apiKey
    case oauth
}

/// Stable model identity usable without a provider implementation or catalog.
/// Extra catalog metadata remains owned by iOS `LLMModel` / `ModelEntry`.
public struct ProviderModel: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String?
    public var provider: String?

    public init(id: String, displayName: String? = nil, provider: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
    }

    /// The first desktop prototype persisted `model` as a JSON string. Accept
    /// that representation so existing desktop databases migrate in place.
    public init(from decoder: Decoder) throws {
        if let legacyID = try? decoder.singleValueContainer().decode(String.self) {
            id = legacyID
            displayName = nil
            provider = nil
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            provider = try container.decodeIfPresent(String.self, forKey: .provider)
        }
    }
}

/// Portable provider binding used by the Runtime protocol. It contains no
/// keychain data and intentionally describes only the endpoint + model needed
/// by an OpenAI-compatible request runner.
public struct ProviderConfiguration: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var endpoint: URL
    public var model: ProviderModel
    public var additionalHeaders: [String: String]
    public var providerType: ProviderType
    /// Authentication mechanism for this binding. Older records omitted this
    /// field and therefore decode as API-key configurations.
    public var credentialType: ProviderCredential
    /// Original unknown provider type for forward-compatible round trips.
    public var unknownProviderTypeRaw: String?

    public init(
        id: String = "default",
        displayName: String = "OpenAI Compatible",
        endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
        model: ProviderModel = ProviderModel(id: "gpt-5.1"),
        additionalHeaders: [String: String] = [:],
        providerType: ProviderType = .openAI,
        credentialType: ProviderCredential = .apiKey,
        unknownProviderTypeRaw: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.model = model
        self.additionalHeaders = additionalHeaders
        self.providerType = providerType
        self.credentialType = credentialType
        self.unknownProviderTypeRaw = providerType == .unsupported ? unknownProviderTypeRaw : nil
    }

    /// Source-compatible bridge for the original macOS Runtime configuration.
    public init(
        id: String = "default",
        displayName: String = "OpenAI Compatible",
        endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
        model: String,
        additionalHeaders: [String: String] = [:],
        providerType: ProviderType = .openAI,
        credentialType: ProviderCredential = .apiKey,
        unknownProviderTypeRaw: String? = nil
    ) {
        self.init(
            id: id,
            displayName: displayName,
            endpoint: endpoint,
            model: ProviderModel(id: model),
            additionalHeaders: additionalHeaders,
            providerType: providerType,
            credentialType: credentialType,
            unknownProviderTypeRaw: unknownProviderTypeRaw
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, endpoint, model, additionalHeaders, providerType, credentialType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? "default"
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? "OpenAI Compatible"
        endpoint = try container.decodeIfPresent(URL.self, forKey: .endpoint) ?? URL(string: "https://api.openai.com/v1/chat/completions")!
        model = try container.decodeIfPresent(ProviderModel.self, forKey: .model) ?? ProviderModel(id: "gpt-5.1")
        additionalHeaders = try container.decodeIfPresent([String: String].self, forKey: .additionalHeaders) ?? [:]
        let raw = try container.decodeIfPresent(String.self, forKey: .providerType) ?? ProviderType.openAI.rawValue
        providerType = ProviderType.decoded(raw)
        credentialType = try container.decodeIfPresent(ProviderCredential.self, forKey: .credentialType) ?? .apiKey
        unknownProviderTypeRaw = providerType == .unsupported ? raw : nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(model, forKey: .model)
        try container.encode(additionalHeaders, forKey: .additionalHeaders)
        try container.encode(unknownProviderTypeRaw ?? providerType.rawValue, forKey: .providerType)
        try container.encode(credentialType, forKey: .credentialType)
    }
}
