import Foundation

nonisolated struct FolderSyncResult: Equatable, Sendable {
    enum Destination: String, Sendable {
        case localOnly
        case iCloud
        case skipped
    }

    let destination: Destination
    let mirroredRelativePaths: [String]
    let conflictRelativePaths: [String]
    let adoptedRemote: Bool
    let fallbackReason: String?
    let attention: DocumentSyncAttention?

    var needsAttention: Bool { attention != nil }
}

/// Mirrors `Folders/catalog.json` into the public iCloud Documents tree when
/// document sync is enabled. Never writes Recordings audio or voiceprint bytes.
/// Failures degrade to local-only `needs_attention` and never block capture.
actor FolderiCloudMirror {
    typealias AtomicWriter = @Sendable (Data, URL) throws -> Void

    struct Configuration: Sendable {
        var preferredContainerIdentifier: String?
        var isDocumentSyncEnabled: @Sendable () -> Bool
        var ubiquityDocumentsURL: @Sendable () -> URL?
        var atomicWriter: AtomicWriter?

        init(
            preferredContainerIdentifier: String? = PublicDocumentContainer.preferredContainerIdentifier,
            isDocumentSyncEnabled: @escaping @Sendable () -> Bool = {
                OnboardingPreferences().documentSyncEnabled
            },
            ubiquityDocumentsURL: (@Sendable () -> URL?)? = nil,
            atomicWriter: AtomicWriter? = nil
        ) {
            self.preferredContainerIdentifier = preferredContainerIdentifier
            self.isDocumentSyncEnabled = isDocumentSyncEnabled
            let preferred = preferredContainerIdentifier
            self.ubiquityDocumentsURL = ubiquityDocumentsURL ?? {
                PublicDocumentContainer.ubiquityDocumentsURL(
                    preferredContainerIdentifier: preferred
                )
            }
            self.atomicWriter = atomicWriter
        }
    }

    private let localRootURL: URL
    private let fileManager: FileManager
    private let configuration: Configuration

    init(
        localRootURL: URL,
        fileManager: FileManager = .default,
        configuration: Configuration = Configuration()
    ) {
        self.localRootURL = localRootURL
        self.fileManager = fileManager
        self.configuration = configuration
    }

    /// Pull remote catalog (if any), adopt when remote revision wins, then push
    /// the active local catalog. Conflict siblings preserve the losing bytes.
    func synchronize(store: FolderCatalogStore) async -> FolderSyncResult {
        let relativePath = PublicDocumentLayout.folderCatalogRelativePath
        guard PublicDocumentContainer.isAllowedPublicRelativePath(relativePath) else {
            return FolderSyncResult(
                destination: .skipped,
                mirroredRelativePaths: [],
                conflictRelativePaths: [],
                adoptedRemote: false,
                fallbackReason: "folderPathNotAllowed",
                attention: DocumentSyncAttention(
                    kind: .writeFailed,
                    reasonCode: "folderPathNotAllowed"
                )
            )
        }

        let resolution = PublicDocumentContainer.resolvePublicRoot(
            documentSyncEnabled: configuration.isDocumentSyncEnabled(),
            fileManager: fileManager,
            ubiquityDocumentsURLProvider: configuration.ubiquityDocumentsURL
        )
        guard resolution.usesUbiquity else {
            return FolderSyncResult(
                destination: .localOnly,
                mirroredRelativePaths: [],
                conflictRelativePaths: [],
                adoptedRemote: false,
                fallbackReason: resolution.fallbackReason,
                attention: DocumentSyncAttention.fromFallbackReason(resolution.fallbackReason)
            )
        }

        do {
            try fileManager.createDirectory(at: resolution.rootURL, withIntermediateDirectories: true)
        } catch {
            let attention = DocumentSyncAttention.classify(error: error)
            return FolderSyncResult(
                destination: .localOnly,
                mirroredRelativePaths: [],
                conflictRelativePaths: [],
                adoptedRemote: false,
                fallbackReason: attention.reasonCode,
                attention: attention
            )
        }

        var conflicts: [String] = []
        var adoptedRemote = false

        do {
            // Ensure local catalog exists before sync.
            _ = try await store.load()
            let localURL = try PublicDocumentFileIO.resolveURL(
                rootURL: localRootURL,
                relativePath: relativePath
            )
            let remoteURL = try PublicDocumentFileIO.resolveURL(
                rootURL: resolution.rootURL,
                relativePath: relativePath
            )

            if fileManager.fileExists(atPath: remoteURL.path) {
                let remoteData = try PublicDocumentFileIO.readCompletedData(at: remoteURL)
                let localData = fileManager.fileExists(atPath: localURL.path)
                    ? try PublicDocumentFileIO.readCompletedData(at: localURL)
                    : Data()

                if !localData.isEmpty, localData != remoteData {
                    let localRevision = PublicDocumentFileIO.revision(inJSONAt: localURL) ?? 0
                    let remoteRevision = PublicDocumentFileIO.revision(inJSONAt: remoteURL) ?? 0

                    if remoteRevision > localRevision {
                        // Remote wins canonical local catalog; park previous local bytes.
                        if let conflictURL = try PublicDocumentFileIO.preserveConflictCopyIfNeeded(
                            of: localURL,
                            fileManager: fileManager
                        ) {
                            let parent = (relativePath as NSString).deletingLastPathComponent
                            let name = conflictURL.lastPathComponent
                            conflicts.append(parent.isEmpty ? name : parent + "/" + name)
                        }
                        try write(remoteData, to: localURL)
                        await store.invalidateCache()
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        let remoteDocument = try decoder.decode(FolderCatalogDocument.self, from: remoteData)
                        _ = try await store.replace(remoteDocument)
                        adoptedRemote = true
                    } else {
                        // Local wins (or equal revision with divergent bytes): park remote.
                        if let conflictName = try replacePreservingConflicts(
                            from: localURL,
                            to: remoteURL
                        ) {
                            let parent = (relativePath as NSString).deletingLastPathComponent
                            conflicts.append(parent.isEmpty ? conflictName : parent + "/" + conflictName)
                        }
                    }
                } else if localData.isEmpty {
                    try write(remoteData, to: localURL)
                    await store.invalidateCache()
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let remoteDocument = try decoder.decode(FolderCatalogDocument.self, from: remoteData)
                    _ = try await store.replace(remoteDocument)
                    adoptedRemote = true
                }
            }

            // Push active local catalog.
            let activeLocal = try await store.load()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let payload = try encoder.encode(activeLocal)
            if fileManager.fileExists(atPath: remoteURL.path) {
                if let conflictName = try replacePreservingConflictsData(
                    sourceData: payload,
                    destination: remoteURL
                ) {
                    let parent = (relativePath as NSString).deletingLastPathComponent
                    let path = parent.isEmpty ? conflictName : parent + "/" + conflictName
                    if !conflicts.contains(path) {
                        conflicts.append(path)
                    }
                }
            } else {
                try write(payload, to: remoteURL)
            }

            let attention: DocumentSyncAttention? = conflicts.isEmpty
                ? nil
                : .conflict(paths: conflicts)
            return FolderSyncResult(
                destination: .iCloud,
                mirroredRelativePaths: [relativePath],
                conflictRelativePaths: conflicts.sorted(),
                adoptedRemote: adoptedRemote,
                fallbackReason: nil,
                attention: attention
            )
        } catch {
            let attention = DocumentSyncAttention.classify(error: error, conflictPaths: conflicts)
            return FolderSyncResult(
                destination: .localOnly,
                mirroredRelativePaths: [],
                conflictRelativePaths: conflicts.sorted(),
                adoptedRemote: adoptedRemote,
                fallbackReason: attention.reasonCode,
                attention: attention
            )
        }
    }

    private func replacePreservingConflicts(from source: URL, to destination: URL) throws -> String? {
        let sourceData = try Data(contentsOf: source)
        return try replacePreservingConflictsData(sourceData: sourceData, destination: destination)
    }

    private func replacePreservingConflictsData(sourceData: Data, destination: URL) throws -> String? {
        guard fileManager.fileExists(atPath: destination.path) else {
            try write(sourceData, to: destination)
            return nil
        }
        let destinationData = try Data(contentsOf: destination)
        if sourceData == destinationData {
            return nil
        }

        let sourceRevision = revision(in: sourceData)
        let destinationRevision = PublicDocumentFileIO.revision(inJSONAt: destination)

        if let sourceRevision, let destinationRevision, destinationRevision > sourceRevision {
            let conflictURL = PublicDocumentFileIO.conflictSiblingURL(for: destination)
            try write(sourceData, to: conflictURL)
            return conflictURL.lastPathComponent
        }

        let preserved = try PublicDocumentFileIO.preserveConflictCopyIfNeeded(
            of: destination,
            fileManager: fileManager
        )
        try write(sourceData, to: destination)
        return preserved?.lastPathComponent
    }

    private func revision(in data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let value = object["revision"] as? Int { return value }
        if let number = object["revision"] as? NSNumber { return number.intValue }
        return nil
    }

    private func write(_ data: Data, to destination: URL) throws {
        if let atomicWriter = configuration.atomicWriter {
            try atomicWriter(data, destination)
        } else {
            try PublicDocumentFileIO.writeAtomically(
                data,
                to: destination,
                fileManager: fileManager
            )
        }
    }
}
