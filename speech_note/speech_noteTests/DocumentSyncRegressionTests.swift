import Foundation
import Testing
@testable import speech_note

/// #31 regression: conflict / space / network / account / concurrent read.
/// Invariant: sync failures never block local Documents or imply recording blockage.
struct DocumentSyncRegressionTests {
    @Test func attentionClassifierMapsSpaceNetworkAndConflict() {
        let space = DocumentSyncAttention.classify(
            error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        )
        #expect(space.kind == .insufficientSpace)
        #expect(space.state == DocumentSyncAttention.needsAttentionState)
        #expect(space.blocksLocalRecording == false)

        let network = DocumentSyncAttention.classify(
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        )
        #expect(network.kind == .networkInterrupted)
        #expect(network.blocksLocalRecording == false)

        let conflict = DocumentSyncAttention.conflict(paths: ["Transcripts/a.json (conflict 1)"])
        #expect(conflict.kind == .conflict)
        #expect(conflict.needsAttentionStateCompatible)

        #expect(DocumentSyncAttention.fromFallbackReason("documentSyncDisabled") == nil)
        #expect(
            DocumentSyncAttention.fromFallbackReason("icloudAccountUnavailable")?.kind
                == .accountUnavailable
        )
    }

    @Test func stagingNamesAreRejectedForCodexAndAllowlist() {
        let staging = ".transcript.json.ABC.writing"
        #expect(PublicDocumentFileIO.isStagingFileName(staging))
        #expect(!PublicDocumentFileIO.isCompletedDocumentURL(
            URL(fileURLWithPath: "/tmp/\(staging)")
        ))
        #expect(!PublicDocumentContainer.isAllowedPublicRelativePath("Transcripts/\(staging)"))
        #expect(PublicDocumentContainer.isAllowedPublicRelativePath("Transcripts/ok.json"))

        #expect(throws: PublicDocumentFileIO.FileIOError.incompleteStaging(staging)) {
            _ = try PublicDocumentFileIO.readCompletedData(
                at: URL(fileURLWithPath: "/tmp/\(staging)")
            )
        }
    }

    @Test func atomicReplaceNeverExposesHalfWrittenBytesToConcurrentReaders() async throws {
        let root = temporaryDirectory("ConcurrentRead")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("timeline.json")

        let versionA = Data(String(repeating: "A", count: 64_000).utf8)
        let versionB = Data(String(repeating: "B", count: 64_000).utf8)
        try PublicDocumentFileIO.writeAtomically(versionA, to: url)

        let readerErrors = MutexBox<[String]>([])
        let readerSawPartial = MutexBox(false)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<40 {
                    try? PublicDocumentFileIO.writeAtomically(versionB, to: url)
                    try? PublicDocumentFileIO.writeAtomically(versionA, to: url)
                }
            }
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<200 {
                        do {
                            let data = try PublicDocumentFileIO.readCompletedData(at: url)
                            let allA = data.allSatisfy { $0 == UInt8(ascii: "A") }
                            let allB = data.allSatisfy { $0 == UInt8(ascii: "B") }
                            if !(allA || allB) || data.isEmpty {
                                readerSawPartial.value = true
                            }
                        } catch {
                            // Missing between replace is acceptable; mixed bytes are not.
                            readerErrors.value.append(String(describing: error))
                        }
                    }
                }
            }
        }

        #expect(readerSawPartial.value == false)

        // Canonical name must not leave staging siblings visible as completed docs.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(leftovers.allSatisfy { !PublicDocumentFileIO.isStagingFileName($0) || $0.hasPrefix(".") })
        let final = try PublicDocumentFileIO.readCompletedData(at: url)
        #expect(final == versionA || final == versionB)
    }

    @Test func mirrorSpaceFailureKeepsLocalPublishAndSetsNeedsAttention() async throws {
        let root = temporaryDirectory("MirrorSpaceLocal")
        let iCloudRoot = temporaryDirectory("MirrorSpaceCloud")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: iCloudRoot)
        }

        let startedAt = Date(timeIntervalSince1970: 1_786_501_800)
        let recording = Recording(
            id: UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000004")!,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(12),
            title: "空间不足",
            isMeeting: false,
            state: .complete
        )
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/note.m4a",
            startSample: 0,
            endSample: 48_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(12)
        )
        let document = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentTexts: [(chunkID: chunk.id, text: "本地必须保留")],
            timezone: "Asia/Shanghai",
            state: .complete
        )
        let store = try TranscriptDocumentStore(rootURL: root)
        try await store.write(document)

        let failingWriter: PublicDocumentiCloudMirror.AtomicWriter = { _, _ in
            throw PublicDocumentFileIO.FileIOError.insufficientSpace
        }
        let mirror = PublicDocumentiCloudMirror(
            localRootURL: root,
            configuration: .init(
                isDocumentSyncEnabled: { true },
                ubiquityDocumentsURL: { iCloudRoot },
                atomicWriter: failingWriter
            )
        )
        let publisher = PublicDocumentPublisher(rootURL: root, iCloudMirror: mirror)
        let result = try await publisher.publish(document: document, dayDocuments: [document])

        // Local Documents publish succeeded.
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(result.jsonRelativePath).path
            )
        )
        let mirrorResult = try #require(result.iCloudMirror)
        #expect(mirrorResult.needsAttention)
        #expect(mirrorResult.attention?.kind == .insufficientSpace)
        #expect(mirrorResult.attention?.blocksLocalRecording == false)
        #expect(mirrorResult.attention?.state == "needs_attention")
    }

    @Test func mirrorNetworkFailureAndAccountUnavailableAreRecoverable() async throws {
        let root = temporaryDirectory("MirrorNetwork")
        let iCloudRoot = temporaryDirectory("MirrorNetworkCloud")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: iCloudRoot)
        }
        let startedAt = Date(timeIntervalSince1970: 1_786_501_800)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(10),
            title: "网络",
            isMeeting: false,
            state: .complete
        )
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/note.m4a",
            startSample: 0,
            endSample: 40_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(10)
        )
        let document = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentTexts: [(chunkID: chunk.id, text: "网络中断")],
            timezone: "Asia/Shanghai",
            state: .complete
        )
        let store = try TranscriptDocumentStore(rootURL: root)
        try await store.write(document)

        let networkWriter: PublicDocumentiCloudMirror.AtomicWriter = { _, _ in
            throw PublicDocumentFileIO.FileIOError.networkInterrupted
        }
        let networkMirror = PublicDocumentiCloudMirror(
            localRootURL: root,
            configuration: .init(
                isDocumentSyncEnabled: { true },
                ubiquityDocumentsURL: { iCloudRoot },
                atomicWriter: networkWriter
            )
        )
        let networkPublisher = PublicDocumentPublisher(rootURL: root, iCloudMirror: networkMirror)
        let networkResult = try await networkPublisher.publish(
            document: document,
            dayDocuments: [document]
        )
        #expect(networkResult.iCloudMirror?.attention?.kind == .networkInterrupted)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(networkResult.jsonRelativePath).path
            )
        )

        let offlineMirror = PublicDocumentiCloudMirror(
            localRootURL: root,
            configuration: .init(
                isDocumentSyncEnabled: { true },
                ubiquityDocumentsURL: { nil }
            )
        )
        let offlinePublisher = PublicDocumentPublisher(rootURL: root, iCloudMirror: offlineMirror)
        let offlineResult = try await offlinePublisher.publish(
            document: document,
            dayDocuments: [document]
        )
        #expect(offlineResult.iCloudMirror?.destination == .localOnly)
        #expect(
            offlineResult.iCloudMirror?.attention?.kind == .accountUnavailable
                || offlineResult.iCloudMirror?.attention?.kind == .ubiquityUnavailable
        )
        #expect(offlineResult.iCloudMirror?.attention?.blocksLocalRecording == false)
    }

    @Test func conflictKeepsBothCopiesAndMarksNeedsAttention() async throws {
        let root = temporaryDirectory("ConflictBoth")
        let iCloudRoot = temporaryDirectory("ConflictBothCloud")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: iCloudRoot)
        }
        let startedAt = Date(timeIntervalSince1970: 1_786_501_800)
        let recording = Recording(
            id: UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000005")!,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(15),
            title: "冲突双方",
            isMeeting: false,
            state: .complete
        )
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/note.m4a",
            startSample: 0,
            endSample: 80_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(15)
        )
        let localDocument = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentTexts: [(chunkID: chunk.id, text: "本地旧版")],
            timezone: "Asia/Shanghai",
            state: .complete,
            revision: 1
        )
        let store = try TranscriptDocumentStore(rootURL: root)
        try await store.write(localDocument)

        let relativeJSON = "Transcripts/\(recording.id.uuidString).json"
        let cloudJSON = iCloudRoot.appendingPathComponent(relativeJSON)
        try FileManager.default.createDirectory(
            at: cloudJSON.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let cloudFixture = """
        {"schema":"voice-context/transcript@1","recording_id":"\(recording.id.uuidString)","kind":"recording","state":"complete","revision":3,"title":"冲突双方","segments":[{"text":"云端新版"}]}
        """
        try Data(cloudFixture.utf8).write(to: cloudJSON)

        let mirror = PublicDocumentiCloudMirror(
            localRootURL: root,
            configuration: .init(
                isDocumentSyncEnabled: { true },
                ubiquityDocumentsURL: { iCloudRoot }
            )
        )
        let publisher = PublicDocumentPublisher(rootURL: root, iCloudMirror: mirror)
        let result = try await publisher.publish(document: localDocument, dayDocuments: [localDocument])
        let mirrorResult = try #require(result.iCloudMirror)
        #expect(!mirrorResult.conflictRelativePaths.isEmpty)
        #expect(mirrorResult.attention?.kind == .conflict)
        #expect(mirrorResult.attention?.state == "needs_attention")

        let cloudText = try String(contentsOf: cloudJSON, encoding: .utf8)
        #expect(cloudText.contains("云端新版"))
        let conflictFiles = try FileManager.default.contentsOfDirectory(
            at: cloudJSON.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("conflict") }
        #expect(!conflictFiles.isEmpty)
        let conflictText = try String(contentsOf: conflictFiles[0], encoding: .utf8)
        #expect(conflictText.contains("本地旧版") || conflictText.contains("revision"))
    }

    @Test func encryptedVoiceprintSpaceFailureLeavesLocalArchiveAndAttention() throws {
        let fileManager = FileManager.default
        let root = temporaryDirectory("VPSpace")
        defer { try? fileManager.removeItem(at: root) }
        let localURL = root.appendingPathComponent("local").appendingPathComponent(
            VoiceprintArchiveStorage.fileName
        )
        try fileManager.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let cloudRoot = root.appendingPathComponent("cloud", isDirectory: true)
        try fileManager.createDirectory(at: cloudRoot, withIntermediateDirectories: true)

        let archive = VoiceprintArchive(identities: [
            VoiceprintIdentity(displayName: "Space", embeddings: [[1, 0]]),
        ])
        let result = try VoiceprintArchiveStorage.saveAndSync(
            archive,
            to: localURL,
            keyProvider: InMemoryVoiceprintArchiveKeyStore(),
            synchronizableKey: true,
            syncConfiguration: .init(
                isEncryptedVoiceprintSyncEnabled: { true },
                ubiquityContainerURL: { cloudRoot },
                atomicCopier: { _, _ in
                    throw PublicDocumentFileIO.FileIOError.insufficientSpace
                }
            ),
            fileManager: fileManager
        )
        #expect(fileManager.fileExists(atPath: localURL.path))
        #expect(result.destination == .localOnly)
        #expect(result.attention?.kind == .insufficientSpace)
        #expect(result.attention?.blocksLocalRecording == false)
    }

    @Test func encryptedVoiceprintConflictPreservesCloudCopy() throws {
        let fileManager = FileManager.default
        let root = temporaryDirectory("VPConflict")
        defer { try? fileManager.removeItem(at: root) }
        let localURL = root.appendingPathComponent("local").appendingPathComponent(
            VoiceprintArchiveStorage.fileName
        )
        try fileManager.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let cloudRoot = root.appendingPathComponent("cloud", isDirectory: true)
        let cloudURL = cloudRoot.appendingPathComponent(
            EncryptedVoiceprintiCloudMirror.cloudRelativePath
        )
        try fileManager.createDirectory(
            at: cloudURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old-cloud-bytes".utf8).write(to: cloudURL)

        let archive = VoiceprintArchive(identities: [
            VoiceprintIdentity(displayName: "Conflict", embeddings: [[0, 1]]),
        ])
        let result = try VoiceprintArchiveStorage.saveAndSync(
            archive,
            to: localURL,
            keyProvider: InMemoryVoiceprintArchiveKeyStore(),
            synchronizableKey: true,
            syncConfiguration: .init(
                isEncryptedVoiceprintSyncEnabled: { true },
                ubiquityContainerURL: { cloudRoot }
            ),
            fileManager: fileManager
        )
        #expect(result.destination == .iCloud)
        #expect(result.conflictRelativePath != nil)
        #expect(result.attention?.kind == .conflict)
        let siblings = try fileManager.contentsOfDirectory(
            at: cloudURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        #expect(siblings.contains(where: { $0.lastPathComponent.contains("conflict") }))
        #expect(fileManager.fileExists(atPath: localURL.path))
    }

    private func temporaryDirectory(_ prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension DocumentSyncAttention {
    var needsAttentionStateCompatible: Bool { state == DocumentSyncAttention.needsAttentionState }
}

/// Tiny mutex box for concurrent test flags without pulling in OSAllocatedUnfairLock availability issues.
private final class MutexBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}
