import Foundation

/// Resolves the public VoiceContext document root.
///
/// Local-first: `Documents/VoiceContext` always works without an iCloud
/// container entitlement. When the user later enables iCloud Documents in
/// Xcode / the Developer portal and a ubiquity container URL becomes
/// available, completed MD/JSON revisions can mirror there. Until then,
/// `url(forUbiquityContainerIdentifier:)` returns nil and callers fall back.
///
/// Do not hard-require a concrete `iCloud.*` identifier in entitlements until
/// the team provisioning profile includes that container.
nonisolated enum PublicDocumentContainer {
    /// Preferred identifier once Cloud Documents is provisioned for the app.
    /// Lookup still tries the default ubiquity container (`nil`) first so builds
    /// with an empty `icloud-container-identifiers` array remain green.
    static let preferredContainerIdentifier = "iCloud.YiJie.speech-note"
    static let displayName = "VoiceContext"
    static let documentsFolderName = "Documents"

    /// Relative roots that may appear in the public document tree.
    static let allowedPublicRoots: Set<String> = [
        PublicDocumentLayout.meetingsRoot,
        PublicDocumentLayout.dailyRoot,
        PublicDocumentLayout.transcriptsRoot,
        "Templates",
        "Skill",
        PublicDocumentLayout.foldersRoot,
    ]

    /// Never publish these into any public/mirrored container (FR-ICL-007).
    static let forbiddenPublicRoots: Set<String> = [
        "Recordings",
        "Imports",
    ]

    static let forbiddenPathExtensions: Set<String> = [
        "m4a", "aac", "caf", "wav", "mp3", "sqlite", "sqlite-wal", "sqlite-shm", "jsonl",
    ]

    enum DestinationKind: String, Equatable, Sendable {
        case local
        case iCloud
    }

    struct Resolution: Equatable, Sendable {
        let kind: DestinationKind
        let rootURL: URL
        let fallbackReason: String?

        var usesUbiquity: Bool { kind == .iCloud }
    }

    /// Always-available Files-visible local tree (`Documents/VoiceContext`).
    static func localRootURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(displayName, isDirectory: true)
    }

    /// Ubiquity container `Documents/` when the capability + account are ready.
    /// Returns nil when entitlements/profile omit iCloud Documents, the user is
    /// signed out, or the container cannot be configured — callers must fall back.
    static func ubiquityDocumentsURL(
        fileManager: FileManager = .default,
        preferredContainerIdentifier: String? = preferredContainerIdentifier
    ) -> URL? {
        guard fileManager.ubiquityIdentityToken != nil else { return nil }

        // Prefer the default container from the entitlements array (may be empty
        // today). A concrete id is only attempted as a secondary lookup.
        let candidates: [String?] = [nil, preferredContainerIdentifier]
        var seen = Set<String>()
        for candidate in candidates {
            let key = candidate ?? "::default::"
            guard seen.insert(key).inserted else { continue }
            if let container = fileManager.url(forUbiquityContainerIdentifier: candidate) {
                return container.appendingPathComponent(documentsFolderName, isDirectory: true)
            }
        }
        return nil
    }

    /// Prefers iCloud only when sync is enabled and a ubiquity Documents URL
    /// exists; otherwise returns the local Documents isomorphic tree (FR-ICL-003).
    static func resolvePublicRoot(
        documentSyncEnabled: Bool,
        fileManager: FileManager = .default,
        ubiquityDocumentsURLProvider: () -> URL? = {
            PublicDocumentContainer.ubiquityDocumentsURL()
        }
    ) -> Resolution {
        let local = localRootURL(fileManager: fileManager)
        guard documentSyncEnabled else {
            return Resolution(kind: .local, rootURL: local, fallbackReason: "documentSyncDisabled")
        }
        guard let ubiquitous = ubiquityDocumentsURLProvider() else {
            let reason: String
            if fileManager.ubiquityIdentityToken == nil {
                reason = "icloudAccountUnavailable"
            } else {
                reason = "ubiquityContainerUnavailable"
            }
            return Resolution(kind: .local, rootURL: local, fallbackReason: reason)
        }
        return Resolution(kind: .iCloud, rootURL: ubiquitous, fallbackReason: nil)
    }

    /// Rejects absolute paths, escapes, audio, journals, and private recording trees.
    static func isAllowedPublicRelativePath(_ relativePath: String) -> Bool {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.hasPrefix("/") else { return false }
        guard !trimmed.contains("://") else { return false }
        let parts = trimmed.split(separator: "/").map(String.init)
        guard let root = parts.first, allowedPublicRoots.contains(root) else { return false }
        if parts.contains(where: { $0 == ".." || $0 == "." }) { return false }
        // Codex must never be pointed at half-written atomic staging siblings.
        if parts.contains(where: { PublicDocumentFileIO.isStagingFileName($0) }) { return false }
        if forbiddenPublicRoots.contains(root) { return false }
        let ext = URL(fileURLWithPath: trimmed).pathExtension.lowercased()
        if forbiddenPathExtensions.contains(ext) { return false }
        if !ext.isEmpty {
            let allowedExt: Set<String> = ["json", "md", "markdown", "txt", "yaml", "yml"]
            if !allowedExt.contains(ext) { return false }
        }
        return true
    }
}
