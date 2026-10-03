import Foundation

nonisolated struct PublicSkillPackSeedResult: Equatable, Sendable {
    let skillRelativePath: String
    let templatesRelativePath: String
    let copiedFileCount: Int
    let preservedUserTemplateCount: Int
    let iCloudMirror: PublicDocumentMirrorResult?
}

/// Copies the bundled VoiceContext Skill + Templates into the public local
/// Documents tree (`Documents/VoiceContext`). When document sync is enabled and
/// a ubiquity Documents URL exists, the same relative tree is mirrored.
///
/// Local-first: works without a concrete iCloud container entitlement.
actor PublicSkillPackSeeder {
    struct Configuration: Sendable {
        var packRootURL: URL?
        var isDocumentSyncEnabled: @Sendable () -> Bool
        var ubiquityDocumentsURL: @Sendable () -> URL?

        init(
            packRootURL: URL? = nil,
            isDocumentSyncEnabled: @escaping @Sendable () -> Bool = {
                OnboardingPreferences().documentSyncEnabled
            },
            ubiquityDocumentsURL: (@Sendable () -> URL?)? = nil
        ) {
            self.packRootURL = packRootURL
            self.isDocumentSyncEnabled = isDocumentSyncEnabled
            self.ubiquityDocumentsURL = ubiquityDocumentsURL ?? {
                PublicDocumentContainer.ubiquityDocumentsURL()
            }
        }
    }

    enum SeedError: LocalizedError, Equatable {
        case packMissing
        case skillMissing
        case templatesMissing

        var errorDescription: String? {
            switch self {
            case .packMissing:
                "应用内未找到 VoiceContextPack（Skill/Templates）。"
            case .skillMissing:
                "VoiceContextPack 缺少 Skill/generate-meeting-minutes。"
            case .templatesMissing:
                "VoiceContextPack 缺少 Templates/default-meeting-minutes.md。"
            }
        }
    }

    let rootURL: URL
    private let fileManager: FileManager
    private let configuration: Configuration

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        configuration: Configuration = Configuration()
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.configuration = configuration
    }

    /// Ensures `Skill/generate-meeting-minutes` and `Templates/` exist under the
    /// local public root. Existing Skill/template files are preserved; bundled
    /// files are installed only when absent.
    @discardableResult
    func seed() throws -> PublicSkillPackSeedResult {
        let packRoot = try resolvePackRoot()
        let sourceSkill = packRoot
            .appendingPathComponent(PublicDocumentLayout.skillRoot, isDirectory: true)
            .appendingPathComponent(PublicDocumentLayout.skillPackName, isDirectory: true)
        let sourceTemplates = packRoot.appendingPathComponent(
            PublicDocumentLayout.templatesRoot,
            isDirectory: true
        )
        let sourceDefault = sourceTemplates.appendingPathComponent(
            PublicDocumentLayout.defaultTemplateFileName
        )

        guard fileManager.fileExists(atPath: sourceSkill.path) else {
            throw SeedError.skillMissing
        }
        guard fileManager.fileExists(atPath: sourceDefault.path) else {
            throw SeedError.templatesMissing
        }

        try rejectSymbolicLinks(at: rootURL, within: rootURL)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let destSkill = try PublicDocumentFileIO.resolveURL(
            rootURL: rootURL,
            relativePath: "\(PublicDocumentLayout.skillRoot)/\(PublicDocumentLayout.skillPackName)"
        )
        let destTemplates = try PublicDocumentFileIO.resolveURL(
            rootURL: rootURL,
            relativePath: PublicDocumentLayout.templatesRoot
        )

        var copied = 0
        copied += try copyMissingFiles(from: sourceSkill, to: destSkill, within: rootURL).copied.count
        try rejectSymbolicLinks(at: destTemplates, within: rootURL)
        try fileManager.createDirectory(at: destTemplates, withIntermediateDirectories: true)
        let preservedUserTemplates = try countUserTemplates(in: destTemplates)
        copied += try copyMissingFiles(from: sourceTemplates, to: destTemplates, within: rootURL).copied.count

        // Best-effort iCloud mirror: local Skill/Templates already written.
        let mirror = (try? mirrorSkillAndTemplatesIfPossible()) ?? PublicDocumentMirrorResult(
            destination: .localOnly,
            mirroredRelativePaths: [],
            skippedRelativePaths: [],
            conflictRelativePaths: [],
            fallbackReason: "writeFailed",
            attention: DocumentSyncAttention(kind: .writeFailed, reasonCode: "writeFailed")
        )
        return PublicSkillPackSeedResult(
            skillRelativePath: "\(PublicDocumentLayout.skillRoot)/\(PublicDocumentLayout.skillPackName)",
            templatesRelativePath: PublicDocumentLayout.templatesRoot,
            copiedFileCount: copied,
            preservedUserTemplateCount: preservedUserTemplates,
            iCloudMirror: mirror
        )
    }

    private func resolvePackRoot() throws -> URL {
        if let configured = configuration.packRootURL {
            return configured
        }
        if let url = Bundle.main.resourceURL?
            .appendingPathComponent("VoiceContextPack", isDirectory: true),
           fileManager.fileExists(atPath: url.path) {
            return url
        }
        guard let zipURL = Bundle.main.url(forResource: "VoiceContextPack", withExtension: "zip") else {
            throw SeedError.packMissing
        }
        return try materializePack(fromZip: zipURL)
    }

    private func materializePack(fromZip zipURL: URL) throws -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let values = try? zipURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = "\(Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0))-\(values?.fileSize ?? 0)"
        let unpackRoot = caches
            .appendingPathComponent("VoiceContextPackCache", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        let skillMarker = unpackRoot
            .appendingPathComponent("Skill/generate-meeting-minutes/SKILL.md")
        if fileManager.fileExists(atPath: skillMarker.path) {
            return unpackRoot
        }
        try StoredZipExtractor.extract(zipURL: zipURL, to: unpackRoot, fileManager: fileManager)
        return unpackRoot
    }

    private func copyMissingFiles(
        from source: URL,
        to destination: URL,
        within destinationRoot: URL
    ) throws -> (copied: [String], skipped: [String]) {
        try rejectSymbolicLinks(at: destination, within: destinationRoot)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSFilePathErrorKey: source.path])
        }
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        var copied: [String] = []
        var skipped: [String] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let filePath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard filePath.hasPrefix(sourcePath + "/") else {
                throw PublicDocumentFileIO.FileIOError.escapedRoot(fileURL.path)
            }
            let relative = String(filePath.dropFirst(sourcePath.count + 1))
            let target = try PublicDocumentFileIO.resolveURL(rootURL: destination, relativePath: relative)
            try rejectSymbolicLinks(at: target, within: destinationRoot)
            if fileManager.fileExists(atPath: target.path) {
                skipped.append(relative)
                continue
            }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if try copyMissingFile(from: fileURL, to: target, within: destinationRoot) {
                copied.append(relative)
            } else {
                skipped.append(relative)
            }
        }
        if let enumerationError { throw enumerationError }
        return (copied, skipped)
    }

    private func copyMissingFile(from source: URL, to destination: URL, within root: URL) throws -> Bool {
        var coordinationError: NSError?
        var writeError: Error?
        var copied = false
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: destination,
            options: [],
            error: &coordinationError
        ) { coordinatedDestination in
            do {
                try rejectSymbolicLinks(at: coordinatedDestination, within: root)
                guard !fileManager.fileExists(atPath: coordinatedDestination.path) else { return }
                let staging = coordinatedDestination.deletingLastPathComponent().appendingPathComponent(
                    ".\(coordinatedDestination.lastPathComponent).\(UUID().uuidString).writing"
                )
                defer { try? fileManager.removeItem(at: staging) }
                try fileManager.copyItem(at: source, to: staging)
                try rejectSymbolicLinks(at: coordinatedDestination, within: root)
                // A completed sibling is moved into place without replacement.
                // moveItem also refuses a destination created during the copy.
                try fileManager.moveItem(at: staging, to: coordinatedDestination)
                copied = true
            } catch {
                writeError = error
            }
        }
        if let coordinationError {
            throw PublicDocumentFileIO.FileIOError.coordinationFailed(coordinationError.localizedDescription)
        }
        if let writeError { throw PublicDocumentFileIO.mapWriteError(writeError) }
        return copied
    }

    private func rejectSymbolicLinks(at url: URL, within root: URL) throws {
        let root = root.standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            throw PublicDocumentFileIO.FileIOError.escapedRoot(url.path)
        }
        var componentURL = root
        var componentURLs = [root]
        for component in candidate.pathComponents.dropFirst(root.pathComponents.count) {
            componentURL.appendPathComponent(component)
            componentURLs.append(componentURL)
        }
        for componentURL in componentURLs {
            do {
                if try componentURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    throw PublicDocumentFileIO.FileIOError.escapedRoot(url.path)
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) {
                break // This component and its descendants have not been created.
            }
        }
    }

    private func countUserTemplates(in templatesDirectory: URL) throws -> Int {
        guard fileManager.fileExists(atPath: templatesDirectory.path) else { return 0 }
        let items = try fileManager.contentsOfDirectory(
            at: templatesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return items.filter { url in
            url.pathExtension.lowercased() == "md"
                && url.lastPathComponent != PublicDocumentLayout.defaultTemplateFileName
        }.count
    }

    private func mirrorSkillAndTemplatesIfPossible() throws -> PublicDocumentMirrorResult? {
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

        var mirrored: [String] = []
        var skipped: [String] = []
        let relatives = [
            "\(PublicDocumentLayout.skillRoot)/\(PublicDocumentLayout.skillPackName)",
            PublicDocumentLayout.templatesRoot,
        ]
        for relative in relatives {
            guard PublicDocumentContainer.isAllowedPublicRelativePath(relative) else { continue }
            let source = try PublicDocumentFileIO.resolveURL(rootURL: rootURL, relativePath: relative)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = try PublicDocumentFileIO.resolveURL(
                rootURL: resolution.rootURL,
                relativePath: relative
            )
            let result = try copyMissingFiles(from: source, to: destination, within: resolution.rootURL)
            mirrored += result.copied.map { "\(relative)/\($0)" }
            skipped += result.skipped.map { "\(relative)/\($0)" }
        }
        return PublicDocumentMirrorResult(
            destination: .iCloud,
            mirroredRelativePaths: mirrored.sorted(),
            skippedRelativePaths: skipped.sorted(),
            conflictRelativePaths: [],
            fallbackReason: nil,
            attention: nil
        )
    }
}
