import Foundation
import Testing
@testable import speech_note

/// #67 / FR-ADD-FLD-*: local folder CRUD + iCloud conflict injection.
struct FolderCatalogTests {
    @Test func localCRUDMovesDeletedFolderRecordingsToUncategorized() async throws {
        let root = temporaryDirectory("FolderCRUD")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FolderCatalogStore(rootURL: root)
        let work = try await store.createFolder(name: " 工作 ")
        #expect(work.folders.count == 1)
        #expect(work.folders[0].name == "工作")

        let personal = try await store.createFolder(name: "生活")
        #expect(personal.folders.map(\.name) == ["工作", "生活"])

        let recordingA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let recordingB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        var catalog = try await store.moveRecording(recordingA, to: work.folders[0].id)
        catalog = try await store.moveRecording(recordingB, to: personal.folders[1].id)
        #expect(catalog.folderID(for: recordingA) == work.folders[0].id)
        #expect(catalog.folderName(for: recordingB) == "生活")

        catalog = try await store.deleteFolder(id: work.folders[0].id)
        #expect(catalog.folders.map(\.name) == ["生活"])
        #expect(catalog.folderID(for: recordingA) == nil) // uncategorized
        #expect(catalog.folderID(for: recordingB) != nil)

        // Recordings themselves are not stored here — deleting a folder must not
        // invent or remove Recording rows.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Recordings").path) == false)

        catalog = try await store.renameFolder(id: personal.folders[1].id, to: "日常")
        #expect(catalog.folders.map(\.name) == ["日常"])
        #expect(catalog.folderName(for: recordingB) == "日常")

        catalog = try await store.moveRecording(recordingB, to: nil)
        #expect(catalog.folderID(for: recordingB) == nil)
        #expect(FolderListFilter.uncategorized.includes(recordingID: recordingB, catalog: catalog))
        #expect(FolderListFilter.all.includes(recordingID: recordingA, catalog: catalog))
    }

    @Test func folderCatalogIsPublicJSONAndRejectsAudioPaths() {
        #expect(PublicDocumentContainer.isAllowedPublicRelativePath("Folders/catalog.json"))
        #expect(!PublicDocumentContainer.isAllowedPublicRelativePath("Recordings/note.m4a"))
        #expect(!PublicDocumentContainer.isAllowedPublicRelativePath("Folders/secret.m4a"))
        #expect(PublicDocumentLayout.folderCatalogRelativePath == "Folders/catalog.json")
    }

    @Test func syncDisabledOrUbiquityNilStaysLocalIsomorphic() async throws {
        let root = temporaryDirectory("FolderLocalOnly")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FolderCatalogStore(rootURL: root)
        _ = try await store.createFolder(name: "本地")

        let disabled = FolderiCloudMirror(
            localRootURL: root,
            configuration: .init(
                isDocumentSyncEnabled: { false },
                ubiquityDocumentsURL: {
                    URL(fileURLWithPath: "/tmp/should-not-use-\(UUID().uuidString)")
                }
            )
        )
        let disabledResult = await disabled.synchronize(store: store)
        #expect(disabledResult.destination == .localOnly)
        #expect(disabledResult.fallbackReason == "documentSyncDisabled")
        #expect(disabledResult.attention == nil)
        #expect(disabledResult.blocksLocalRecordingCompatible)

        let noUbiquity = FolderiCloudMirror(
            localRootURL: root,
            configuration: .init(
                isDocumentSyncEnabled: { true },
                ubiquityDocumentsURL: { nil }
            )
        )
        let unavailable = await noUbiquity.synchronize(store: store)
        #expect(unavailable.destination == .localOnly)
        #expect(
            unavailable.fallbackReason == "icloudAccountUnavailable"
                || unavailable.fallbackReason == "ubiquityContainerUnavailable"
        )
        #expect(unavailable.attention?.blocksLocalRecording == false)
    }

    @Test func conflictInjectionKeepsCopiesAndNeedsAttention() async throws {
        let root = temporaryDirectory("FolderConflictLocal")
        let iCloudRoot = temporaryDirectory("FolderConflictCloud")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: iCloudRoot)
        }

        let store = FolderCatalogStore(rootURL: root)
        var local = try await store.createFolder(name: "设备A")
        // Force a low revision for conflict math.
        local.revision = 1
        local = try await store.save(local)

        let remoteFolder = RecordingFolder(
            id: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!,
            name: "设备B",
            createdAt: Date(timeIntervalSince1970: 1_786_501_800)
        )
        var remote = FolderCatalogDocument.empty(now: Date(timeIntervalSince1970: 1_786_501_800))
        remote.revision = 4
        remote.folders = [remoteFolder]
        remote.memberships = [
            "DDDDDDDD-0000-0000-0000-000000000004": remoteFolder.id.uuidString
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let remoteData = try encoder.encode(remote)
        let remoteURL = iCloudRoot.appendingPathComponent(PublicDocumentLayout.folderCatalogRelativePath)
        try FileManager.default.createDirectory(
            at: remoteURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try remoteData.write(to: remoteURL)

        let mirror = FolderiCloudMirror(
            localRootURL: root,
            configuration: .init(
                isDocumentSyncEnabled: { true },
                ubiquityDocumentsURL: { iCloudRoot }
            )
        )
        let result = await mirror.synchronize(store: store)
        #expect(result.destination == .iCloud)
        #expect(result.needsAttention)
        #expect(result.attention?.kind == .conflict)
        #expect(result.attention?.state == DocumentSyncAttention.needsAttentionState)
        #expect(result.attention?.blocksLocalRecording == false)
        #expect(result.adoptedRemote)
        #expect(!result.conflictRelativePaths.isEmpty)

        let adopted = try await store.load()
        #expect(adopted.revision == 4)
        #expect(adopted.folders.map(\.name) == ["设备B"])

        let localConflicts = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent(PublicDocumentLayout.foldersRoot),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("conflict") }
        #expect(!localConflicts.isEmpty)

        // Canonical cloud catalog remains JSON metadata only (no audio/voiceprint).
        let cloudBytes = try Data(contentsOf: remoteURL)
        let cloudText = String(decoding: cloudBytes, as: UTF8.self)
        #expect(cloudText.contains("folders"))
        #expect(!cloudText.lowercased().contains(".m4a"))
        #expect(!cloudText.contains("embedding"))
    }

    @Test func spaceFailureDuringFolderSyncSetsNeedsAttentionWithoutThrowingThrough() async throws {
        let root = temporaryDirectory("FolderSpaceLocal")
        let iCloudRoot = temporaryDirectory("FolderSpaceCloud")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: iCloudRoot)
        }
        let store = FolderCatalogStore(rootURL: root)
        _ = try await store.createFolder(name: "空间")

        let failingWriter: FolderiCloudMirror.AtomicWriter = { _, _ in
            throw PublicDocumentFileIO.FileIOError.insufficientSpace
        }
        let mirror = FolderiCloudMirror(
            localRootURL: root,
            configuration: .init(
                isDocumentSyncEnabled: { true },
                ubiquityDocumentsURL: { iCloudRoot },
                atomicWriter: failingWriter
            )
        )
        let result = await mirror.synchronize(store: store)
        #expect(result.needsAttention)
        #expect(result.attention?.kind == .insufficientSpace)
        #expect(result.attention?.blocksLocalRecording == false)

        // Local catalog still readable.
        let local = try await store.load()
        #expect(local.folders.map(\.name) == ["空间"])
    }

    private func temporaryDirectory(_ prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension FolderSyncResult {
    var blocksLocalRecordingCompatible: Bool {
        attention?.blocksLocalRecording != true
    }
}
