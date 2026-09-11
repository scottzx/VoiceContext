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
    /// local public root. Skill files are refreshed from the bundle; user-added
    /// templates are preserved; the default template is created when absent.
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
        copied += try replaceDirectory(from: sourceSkill, to: destSkill)
        try fileManager.createDirectory(at: destTemplates, withIntermediateDirectories: true)

        let defaultDest = destTemplates.appendingPathComponent(
            PublicDocumentLayout.defaultTemplateFileName
        )
        let preservedUserTemplates = try countUserTemplates(in: destTemplates)
        if !fileManager.fileExists(atPath: defaultDest.path) {
            try PublicDocumentFileIO.copyAtomically(
                from: sourceDefault,
                to: defaultDest,
                fileManager: fileManager
            )
            copied += 1
        }

        // Also copy any other bundled templates that are missing (never overwrite).
        if let enumerator = fileManager.enumerator(
            at: sourceTemplates,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue
                else { continue }
                let relative = fileURL.path.replacingOccurrences(
                    of: sourceTemplates.path + "/",
                    with: ""
                )
                let destination = destTemplates.appendingPathComponent(relative)
                if !fileManager.fileExists(atPath: destination.path) {
                    try PublicDocumentFileIO.copyAtomically(
                        from: fileURL,
                        to: destination,
                        fileManager: fileManager
                    )
                    copied += 1
                }
            }
        }

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

    private func replaceDirectory(from source: URL, to destination: URL) throws -> Int {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: source, to: destination)
        return try countRegularFiles(under: destination)
    }

    private func countRegularFiles(under root: URL) throws -> Int {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let fileURL as URL in enumerator {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                count += 1
            }
        }
        return count
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
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: destination)
            mirrored.append(relative)
        }
        return PublicDocumentMirrorResult(
            destination: .iCloud,
            mirroredRelativePaths: mirrored.sorted(),
            skippedRelativePaths: [],
            conflictRelativePaths: [],
            fallbackReason: nil,
            attention: nil
        )
    }
}
