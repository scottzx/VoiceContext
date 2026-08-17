import Foundation

nonisolated struct EncryptedVoiceprintSyncResult: Equatable, Sendable {
    enum Destination: String, Sendable {
        case localOnly
        case iCloud
        case removed
        case skipped
    }

    let destination: Destination
    let cloudRelativePath: String?
    let fallbackReason: String?
    let conflictRelativePath: String?
    let attention: DocumentSyncAttention?

    var needsAttention: Bool { attention != nil }
}

/// Optional private iCloud mirror for the AES-GCM voiceprint archive.
/// LOCAL-FIRST: when sync is off or ubiquity is unavailable, keep the encrypted
/// archive on-device only. Does not write into the public VoiceContext MD/JSON tree.
/// Cloud write failures return `localOnly` + attention instead of throwing, so
/// callers never lose the already-saved local envelope.
nonisolated enum EncryptedVoiceprintiCloudMirror {
    /// Outside public Documents roots (Meetings/Daily/Transcripts/…).
    static let cloudRelativePath = "Private/Voiceprint/voiceprint-archive.aesgcm"

    typealias AtomicCopier = @Sendable (URL, URL) throws -> Void

    struct Configuration: Sendable {
        var isEncryptedVoiceprintSyncEnabled: @Sendable () -> Bool
        var ubiquityContainerURL: @Sendable () -> URL?
        var atomicCopier: AtomicCopier?

        init(
            isEncryptedVoiceprintSyncEnabled: @escaping @Sendable () -> Bool = {
                UserDefaults.standard.bool(forKey: OnboardingPreferences.encryptedVoiceprintSyncKey)
            },
            ubiquityContainerURL: (@Sendable () -> URL?)? = nil,
            atomicCopier: AtomicCopier? = nil
        ) {
            self.isEncryptedVoiceprintSyncEnabled = isEncryptedVoiceprintSyncEnabled
            self.ubiquityContainerURL = ubiquityContainerURL ?? {
                EncryptedVoiceprintiCloudMirror.ubiquityContainerURL()
            }
            self.atomicCopier = atomicCopier
        }
    }

    /// Ubiquity container root (not Documents/). Nil when entitlement/account
    /// is unavailable — callers must stay local-only.
    static func ubiquityContainerURL(
        fileManager: FileManager = .default,
        preferredContainerIdentifier: String? = PublicDocumentContainer.preferredContainerIdentifier
    ) -> URL? {
        guard fileManager.ubiquityIdentityToken != nil else { return nil }
        let candidates: [String?] = [nil, preferredContainerIdentifier]
        var seen = Set<String>()
        for candidate in candidates {
            let key = candidate ?? "::default::"
            guard seen.insert(key).inserted else { continue }
            if let container = fileManager.url(forUbiquityContainerIdentifier: candidate) {
                return container
            }
        }
        return nil
    }

    /// Publishes the already-encrypted local blob to private iCloud when enabled.
    /// When sync is disabled, removes any prior cloud copy ("关闭同步无云档案").
    @discardableResult
    static func publish(
        localEncryptedURL: URL,
        fileManager: FileManager = .default,
        configuration: Configuration = Configuration()
    ) -> EncryptedVoiceprintSyncResult {
        let syncEnabled = configuration.isEncryptedVoiceprintSyncEnabled()
        let cloudRoot = configuration.ubiquityContainerURL()

        guard syncEnabled else {
            if let cloudRoot {
                do {
                    let cloudURL = try PublicDocumentFileIO.resolveURL(
                        rootURL: cloudRoot,
                        relativePath: cloudRelativePath
                    )
                    if fileManager.fileExists(atPath: cloudURL.path) {
                        try fileManager.removeItem(at: cloudURL)
                        return EncryptedVoiceprintSyncResult(
                            destination: .removed,
                            cloudRelativePath: cloudRelativePath,
                            fallbackReason: "encryptedVoiceprintSyncDisabled",
                            conflictRelativePath: nil,
                            attention: nil
                        )
                    }
                } catch {
                    // Removal failure still leaves sync "off" locally; surface attention.
                    let attention = DocumentSyncAttention.classify(error: error)
                    return EncryptedVoiceprintSyncResult(
                        destination: .localOnly,
                        cloudRelativePath: cloudRelativePath,
                        fallbackReason: "encryptedVoiceprintSyncDisabled",
                        conflictRelativePath: nil,
                        attention: attention
                    )
                }
            }
            return EncryptedVoiceprintSyncResult(
                destination: .localOnly,
                cloudRelativePath: nil,
                fallbackReason: "encryptedVoiceprintSyncDisabled",
                conflictRelativePath: nil,
                attention: nil
            )
        }

        guard let cloudRoot else {
            let reason: String
            if fileManager.ubiquityIdentityToken == nil {
                reason = "icloudAccountUnavailable"
            } else {
                reason = "ubiquityContainerUnavailable"
            }
            return EncryptedVoiceprintSyncResult(
                destination: .localOnly,
                cloudRelativePath: nil,
                fallbackReason: reason,
                conflictRelativePath: nil,
                attention: DocumentSyncAttention.fromFallbackReason(reason)
            )
        }

        guard fileManager.fileExists(atPath: localEncryptedURL.path) else {
            return EncryptedVoiceprintSyncResult(
                destination: .skipped,
                cloudRelativePath: nil,
                fallbackReason: "localEncryptedArchiveMissing",
                conflictRelativePath: nil,
                attention: nil
            )
        }

        do {
            let destination = try PublicDocumentFileIO.resolveURL(
                rootURL: cloudRoot,
                relativePath: cloudRelativePath
            )
            var conflictPath: String?
            if fileManager.fileExists(atPath: destination.path) {
                let localData = try Data(contentsOf: localEncryptedURL)
                let cloudData = try Data(contentsOf: destination)
                if localData != cloudData {
                    let preserved = try PublicDocumentFileIO.preserveConflictCopyIfNeeded(
                        of: destination,
                        fileManager: fileManager
                    )
                    conflictPath = preserved.map { cloudRelativePathParent + "/" + $0.lastPathComponent }
                        ?? (cloudRelativePathParent + "/voiceprint-archive (conflict)")
                }
            }

            if let atomicCopier = configuration.atomicCopier {
                try atomicCopier(localEncryptedURL, destination)
            } else {
                try PublicDocumentFileIO.copyAtomically(
                    from: localEncryptedURL,
                    to: destination,
                    fileManager: fileManager
                )
            }

            let attention = conflictPath.map {
                DocumentSyncAttention.conflict(paths: [$0])
            }
            return EncryptedVoiceprintSyncResult(
                destination: .iCloud,
                cloudRelativePath: cloudRelativePath,
                fallbackReason: nil,
                conflictRelativePath: conflictPath,
                attention: attention
            )
        } catch {
            let attention = DocumentSyncAttention.classify(error: error)
            return EncryptedVoiceprintSyncResult(
                destination: .localOnly,
                cloudRelativePath: nil,
                fallbackReason: attention.reasonCode,
                conflictRelativePath: nil,
                attention: attention
            )
        }
    }

    private static var cloudRelativePathParent: String {
        (cloudRelativePath as NSString).deletingLastPathComponent
    }

    static func cloudArchiveExists(
        fileManager: FileManager = .default,
        configuration: Configuration = Configuration()
    ) -> Bool {
        guard let cloudRoot = configuration.ubiquityContainerURL() else { return false }
        guard let url = try? PublicDocumentFileIO.resolveURL(
            rootURL: cloudRoot,
            relativePath: cloudRelativePath
        ) else {
            return false
        }
        return fileManager.fileExists(atPath: url.path)
    }
}
