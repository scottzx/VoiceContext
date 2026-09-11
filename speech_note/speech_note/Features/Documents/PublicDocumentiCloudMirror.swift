import Foundation

nonisolated struct PublicDocumentMirrorResult: Equatable, Sendable {
    enum Destination: String, Sendable {
        case localOnly
        case iCloud
        case skipped
    }

    let destination: Destination
    let mirroredRelativePaths: [String]
    let skippedRelativePaths: [String]
    let conflictRelativePaths: [String]
    let fallbackReason: String?
    /// Present when the user should see `needs_attention` (conflict / space / network / account).
    let attention: DocumentSyncAttention?

    var needsAttention: Bool { attention != nil }
}

/// Mirrors completed Meetings/Daily/Transcripts MD+JSON into the public
/// iCloud Drive container. Never copies Recordings or other private assets.
/// Failures degrade to local-only attention and never undo local publishes.
actor PublicDocumentiCloudMirror {
    typealias AtomicWriter = @Sendable (Data, URL) throws -> Void

    struct Configuration: Sendable {
        var preferredContainerIdentifier: String?
        var isDocumentSyncEnabled: @Sendable () -> Bool
        var ubiquityDocumentsURL: @Sendable () -> URL?
        /// Injectable writer for regression tests (space / network failures).
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

    @discardableResult
    func mirror(
        publishResult: PublicDocumentPublishResult,
        documentState: String
    ) -> PublicDocumentMirrorResult {
        guard documentState == "complete" else {
            return PublicDocumentMirrorResult(
                destination: .skipped,
                mirroredRelativePaths: [],
                skippedRelativePaths: [],
                conflictRelativePaths: [],
                fallbackReason: "incompleteDocument",
                attention: nil
            )
        }

        let resolution = PublicDocumentContainer.resolvePublicRoot(
            documentSyncEnabled: configuration.isDocumentSyncEnabled(),
            fileManager: fileManager,
            ubiquityDocumentsURLProvider: configuration.ubiquityDocumentsURL
        )
        guard resolution.usesUbiquity else {
            return PublicDocumentMirrorResult(
                destination: .localOnly,
                mirroredRelativePaths: [],
                skippedRelativePaths: [],
                conflictRelativePaths: [],
                fallbackReason: resolution.fallbackReason,
                attention: DocumentSyncAttention.fromFallbackReason(resolution.fallbackReason)
            )
        }

        do {
            try fileManager.createDirectory(at: resolution.rootURL, withIntermediateDirectories: true)
        } catch {
            let attention = DocumentSyncAttention.classify(error: error)
            return PublicDocumentMirrorResult(
                destination: .localOnly,
                mirroredRelativePaths: [],
                skippedRelativePaths: [],
                conflictRelativePaths: [],
                fallbackReason: attention.reasonCode,
                attention: attention
            )
        }

        var mirrored: [String] = []
        var skipped: [String] = []
        var conflicts: [String] = []
        var attentions: [DocumentSyncAttention] = []

        for relativePath in candidatePaths(from: publishResult) {
            guard PublicDocumentContainer.isAllowedPublicRelativePath(relativePath) else {
                skipped.append(relativePath)
                continue
            }
            let source: URL
            do {
                source = try PublicDocumentFileIO.resolveURL(
                    rootURL: localRootURL,
                    relativePath: relativePath
                )
            } catch {
                skipped.append(relativePath)
                continue
            }
            guard fileManager.fileExists(atPath: source.path) else {
                skipped.append(relativePath)
                continue
            }

            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                do {
                    let destinationDir = try PublicDocumentFileIO.resolveURL(
                        rootURL: resolution.rootURL,
                        relativePath: relativePath
                    )
                    try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
                    mirrored.append(relativePath)
                } catch {
                    skipped.append(relativePath)
                    attentions.append(DocumentSyncAttention.classify(error: error))
                }
                continue
            }

            do {
                let destination = try PublicDocumentFileIO.resolveURL(
                    rootURL: resolution.rootURL,
                    relativePath: relativePath
                )
                if let conflictName = try replacePreservingConflicts(from: source, to: destination) {
                    let parent = (relativePath as NSString).deletingLastPathComponent
                    let conflictPath = parent.isEmpty ? conflictName : parent + "/" + conflictName
                    conflicts.append(conflictPath)
                }
                mirrored.append(relativePath)
            } catch {
                skipped.append(relativePath)
                attentions.append(DocumentSyncAttention.classify(error: error))
            }
        }

        let attention: DocumentSyncAttention?
        if !conflicts.isEmpty {
            attention = .conflict(paths: conflicts)
        } else {
            attention = attentions.first
        }

        let destination: PublicDocumentMirrorResult.Destination
        let fallback: String?
        if mirrored.isEmpty, attention != nil {
            destination = .localOnly
            fallback = attention?.reasonCode
        } else {
            destination = .iCloud
            fallback = nil
        }

        return PublicDocumentMirrorResult(
            destination: destination,
            mirroredRelativePaths: mirrored.sorted(),
            skippedRelativePaths: skipped.sorted(),
            conflictRelativePaths: conflicts.sorted(),
            fallbackReason: fallback,
            attention: attention
        )
    }

    private func candidatePaths(from result: PublicDocumentPublishResult) -> [String] {
        var paths: [String] = [
            result.jsonRelativePath,
            result.markdownRelativePath,
            result.dailyDirectoryRelativePath + "/" + PublicDocumentLayout.timelineJSONName,
            result.dailyDirectoryRelativePath + "/" + PublicDocumentLayout.timelineMarkdownName,
        ]
        if let meeting = result.meetingDirectoryRelativePath {
            paths.append(meeting + "/" + PublicDocumentLayout.transcriptJSONName)
            paths.append(meeting + "/" + PublicDocumentLayout.transcriptMarkdownName)
            paths.append(meeting + "/" + PublicDocumentLayout.generatedDirectoryName)
        }
        for entry in result.timeline.entries {
            paths.append(entry.relativePath)
            if entry.relativePath.hasSuffix(".json") {
                paths.append(String(entry.relativePath.dropLast(4)) + "md")
            }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// Returns the conflict file's last path component when a divergent copy is kept.
    private func replacePreservingConflicts(from source: URL, to destination: URL) throws -> String? {
        let sourceData = try Data(contentsOf: source)
        guard fileManager.fileExists(atPath: destination.path) else {
            try write(sourceData, to: destination)
            return nil
        }

        let destinationData = try Data(contentsOf: destination)
        if sourceData == destinationData {
            return nil
        }

        let sourceRevision = PublicDocumentFileIO.revision(inJSONAt: source)
        let destinationRevision = PublicDocumentFileIO.revision(inJSONAt: destination)

        // Newer cloud revision wins the canonical name; park the local publish beside it.
        if let sourceRevision, let destinationRevision, destinationRevision > sourceRevision {
            let conflictURL = PublicDocumentFileIO.conflictSiblingURL(for: destination)
            try write(sourceData, to: conflictURL)
            return conflictURL.lastPathComponent
        }

        // Local publish advances the canonical document; keep the previous cloud bytes.
        let preserved = try PublicDocumentFileIO.preserveConflictCopyIfNeeded(
            of: destination,
            fileManager: fileManager
        )
        try write(sourceData, to: destination)
        return preserved?.lastPathComponent
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
