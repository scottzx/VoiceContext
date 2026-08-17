import Foundation
import Testing
@testable import speech_note

struct PublicDocumentTests {
    @Test func meetingAndDailyPathsSortByAbsoluteLocalTimeAndStayRelative() throws {
        let earlierID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let laterID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        // 2026-08-12 10:30:00 and 11:00:00 in Asia/Shanghai (+08:00)
        let earlier = Date(timeIntervalSince1970: 1_786_501_800)
        let later = Date(timeIntervalSince1970: 1_786_503_600)

        let earlierPath = PublicDocumentLayout.meetingDirectoryRelativePath(
            recordingID: earlierID,
            startedAt: earlier,
            timezoneIdentifier: "Asia/Shanghai"
        )
        let laterPath = PublicDocumentLayout.meetingDirectoryRelativePath(
            recordingID: laterID,
            startedAt: later,
            timezoneIdentifier: "Asia/Shanghai"
        )

        #expect(earlierPath == "Meetings/2026/08/2026-08-12_10-30-00_AAAAAAAA")
        #expect(laterPath == "Meetings/2026/08/2026-08-12_11-00-00_BBBBBBBB")
        #expect(earlierPath < laterPath)
        #expect(!earlierPath.hasPrefix("/"))
        #expect(!laterPath.contains("Users/"))

        let daily = PublicDocumentLayout.dailyDirectoryRelativePath(
            date: earlier,
            timezoneIdentifier: "Asia/Shanghai"
        )
        #expect(daily == "Daily/2026/08/12")
    }

    @Test func publisherWritesMeetingDirectoryDailyTimelineAndValidRelativePaths() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let startedAt = Date(timeIntervalSince1970: 1_786_501_800.125)
        let meeting = Recording(
            id: UUID(uuidString: "BA485C93-6D6E-42E9-ADDA-B8DA50B2CA7C")!,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(120),
            title: "产品评审",
            isMeeting: true,
            state: .complete
        )
        let personal = Recording(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            startedAt: startedAt.addingTimeInterval(3_600),
            endedAt: startedAt.addingTimeInterval(3_660),
            title: "个人备忘",
            isMeeting: false,
            state: .complete
        )
        let meetingChunk = AudioChunk(
            recordingID: meeting.id,
            relativePath: "Recordings/meeting.m4a",
            startSample: 0,
            endSample: 960_000,
            startedAt: meeting.startedAt,
            endedAt: meeting.endedAt!
        )
        let personalChunk = AudioChunk(
            recordingID: personal.id,
            relativePath: "Recordings/personal.m4a",
            startSample: 0,
            endSample: 160_000,
            startedAt: personal.startedAt,
            endedAt: personal.endedAt!
        )

        let meetingDocument = TranscriptDocumentV1(
            recording: meeting,
            chunks: [meetingChunk],
            segmentTexts: [(chunkID: meetingChunk.id, text: "会议正文")],
            timezone: "Asia/Shanghai",
            language: "zh",
            state: .complete
        )
        let personalDocument = TranscriptDocumentV1(
            recording: personal,
            chunks: [personalChunk],
            segmentTexts: [(chunkID: personalChunk.id, text: "日常正文")],
            timezone: "Asia/Shanghai",
            language: "zh",
            state: .complete
        )

        let store = try TranscriptDocumentStore(rootURL: root)
        try await store.write(meetingDocument)
        try await store.write(personalDocument)

        let publisher = PublicDocumentPublisher(rootURL: root)
        let result = try await publisher.publish(
            document: meetingDocument,
            dayDocuments: [meetingDocument, personalDocument]
        )

        #expect(result.meetingDirectoryRelativePath == "Meetings/2026/08/2026-08-12_10-30-00_BA485C93")
        #expect(result.dailyDirectoryRelativePath == "Daily/2026/08/12")
        #expect(result.jsonRelativePath.hasSuffix("/transcript.json"))
        #expect(!result.jsonRelativePath.hasPrefix("/"))
        #expect(result.iCloudMirror == nil)

        let meetingJSON = root.appendingPathComponent(result.jsonRelativePath)
        let meetingMD = root.appendingPathComponent(result.markdownRelativePath)
        #expect(FileManager.default.fileExists(atPath: meetingJSON.path))
        #expect(FileManager.default.fileExists(atPath: meetingMD.path))
        #expect(
            FileManager.default.fileExists(
                atPath: root
                    .appendingPathComponent(result.meetingDirectoryRelativePath!)
                    .appendingPathComponent("generated").path
            )
        )

        let timelineJSON = root
            .appendingPathComponent(result.dailyDirectoryRelativePath)
            .appendingPathComponent("timeline.json")
        let timelineMD = root
            .appendingPathComponent(result.dailyDirectoryRelativePath)
            .appendingPathComponent("timeline.md")
        #expect(FileManager.default.fileExists(atPath: timelineJSON.path))
        #expect(FileManager.default.fileExists(atPath: timelineMD.path))

        let timeline = result.timeline
        #expect(timeline.schema == DailyTimelineDocument.schema)
        #expect(timeline.date == "2026-08-12")
        #expect(timeline.entries.map(\.recordingID) == [meeting.id, personal.id])
        #expect(timeline.entries.map(\.relativePath) == [
            "Meetings/2026/08/2026-08-12_10-30-00_BA485C93/transcript.json",
            "Transcripts/\(personal.id.uuidString).json",
        ])
        for entry in timeline.entries {
            let url = try await publisher.resolveURL(relativePath: entry.relativePath)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(!entry.relativePath.contains(":"))
            #expect(!entry.relativePath.hasPrefix("/"))
        }

        let markdown = try String(contentsOf: timelineMD, encoding: .utf8)
        #expect(markdown.contains("schema: voice-context/timeline@1"))
        #expect(markdown.contains("产品评审"))
        #expect(markdown.contains("个人备忘"))
        #expect(markdown.contains("Meetings/2026/08/2026-08-12_10-30-00_BA485C93/transcript.json"))
    }

    @Test func personalRecordingPublishesOnlyDailyIndexAgainstCanonicalTranscript() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let startedAt = Date(timeIntervalSince1970: 1_786_501_800)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(30),
            title: "想法",
            isMeeting: false,
            state: .complete
        )
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/note.m4a",
            startSample: 0,
            endSample: 160_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(30)
        )
        let document = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentTexts: [(chunkID: chunk.id, text: "一个念头")],
            timezone: "Asia/Shanghai",
            state: .complete
        )
        let store = try TranscriptDocumentStore(rootURL: root)
        try await store.write(document)
        let publisher = PublicDocumentPublisher(rootURL: root)
        let result = try await publisher.publish(document: document, dayDocuments: [document])

        #expect(result.meetingDirectoryRelativePath == nil)
        #expect(result.jsonRelativePath == "Transcripts/\(recording.id.uuidString).json")
        #expect(result.timeline.entries.count == 1)
        #expect(result.timeline.entries[0].relativePath == result.jsonRelativePath)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Meetings").path))
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Daily/2026/08/12/timeline.json").path
            )
        )
    }

    @Test func publicContainerAllowlistRejectsAudioAndPrivateRoots() {
        #expect(PublicDocumentContainer.isAllowedPublicRelativePath("Meetings/a/transcript.json"))
        #expect(PublicDocumentContainer.isAllowedPublicRelativePath("Daily/2026/08/12/timeline.md"))
        #expect(PublicDocumentContainer.isAllowedPublicRelativePath("Transcripts/id.json"))
        #expect(PublicDocumentContainer.isAllowedPublicRelativePath("Templates/default-meeting-minutes.md"))
        #expect(PublicDocumentContainer.isAllowedPublicRelativePath("Skill/generate-meeting-minutes/SKILL.md"))
        #expect(!PublicDocumentContainer.isAllowedPublicRelativePath("Recordings/meeting.m4a"))
        #expect(!PublicDocumentContainer.isAllowedPublicRelativePath("Imports/raw.wav"))
        #expect(!PublicDocumentContainer.isAllowedPublicRelativePath("Transcripts/id.m4a"))
        #expect(!PublicDocumentContainer.isAllowedPublicRelativePath("../Escape/secret.json"))
        #expect(!PublicDocumentContainer.isAllowedPublicRelativePath("/absolute/path.json"))
        #expect(!PublicDocumentContainer.isAllowedPublicRelativePath("recording-journal.jsonl"))
    }

    @Test func resolvePublicRootFallsBackWhenSyncDisabledOrUbiquityMissing() {
        let disabled = PublicDocumentContainer.resolvePublicRoot(
            documentSyncEnabled: false,
            ubiquityDocumentsURLProvider: {
                URL(fileURLWithPath: "/tmp/fake-icloud-documents")
            }
        )
        #expect(disabled.kind == .local)
        #expect(disabled.fallbackReason == "documentSyncDisabled")
        #expect(disabled.rootURL.path.hasSuffix("VoiceContext"))

        let unavailable = PublicDocumentContainer.resolvePublicRoot(
            documentSyncEnabled: true,
            ubiquityDocumentsURLProvider: { nil }
        )
        #expect(unavailable.kind == .local)
        #expect(
            unavailable.fallbackReason == "icloudAccountUnavailable"
                || unavailable.fallbackReason == "ubiquityContainerUnavailable"
        )
    }

    @Test func iCloudMirrorCopiesMarkdownJSONButNeverAudio() async throws {
        let root = temporaryDirectory()
        let iCloudRoot = temporaryDirectory("PublicDocumentiCloud")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: iCloudRoot)
        }

        let startedAt = Date(timeIntervalSince1970: 1_786_501_800)
        let meeting = Recording(
            id: UUID(uuidString: "BA485C93-6D6E-42E9-ADDA-B8DA50B2CA7C")!,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            title: "同步会议",
            isMeeting: true,
            state: .complete
        )
        let chunk = AudioChunk(
            recordingID: meeting.id,
            relativePath: "Recordings/meeting.m4a",
            startSample: 0,
            endSample: 160_000,
            startedAt: meeting.startedAt,
            endedAt: meeting.endedAt!
        )
        let document = TranscriptDocumentV1(
            recording: meeting,
            chunks: [chunk],
            segmentTexts: [(chunkID: chunk.id, text: "同步正文")],
            timezone: "Asia/Shanghai",
            language: "zh",
            state: .complete
        )
        let store = try TranscriptDocumentStore(rootURL: root)
        try await store.write(document)

        // Local private audio must exist beside public docs and must not be mirrored.
        let recordingsDir = root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        try Data("fake-audio".utf8).write(to: recordingsDir.appendingPathComponent("meeting.m4a"))

        let mirror = PublicDocumentiCloudMirror(
            localRootURL: root,
            configuration: .init(
                isDocumentSyncEnabled: { true },
                ubiquityDocumentsURL: { iCloudRoot }
            )
        )
        let publisher = PublicDocumentPublisher(rootURL: root, iCloudMirror: mirror)
        let result = try await publisher.publish(document: document, dayDocuments: [document])

        let mirrorResult = try #require(result.iCloudMirror)
        #expect(mirrorResult.destination == .iCloud)
        #expect(mirrorResult.mirroredRelativePaths.contains(result.jsonRelativePath))
        #expect(mirrorResult.mirroredRelativePaths.contains(result.markdownRelativePath))
        #expect(
            FileManager.default.fileExists(
                atPath: iCloudRoot.appendingPathComponent(result.jsonRelativePath).path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: iCloudRoot.appendingPathComponent(result.markdownRelativePath).path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: iCloudRoot.appendingPathComponent("Daily/2026/08/12/timeline.json").path
            )
        )
        #expect(!FileManager.default.fileExists(atPath: iCloudRoot.appendingPathComponent("Recordings").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: iCloudRoot.appendingPathComponent("Recordings/meeting.m4a").path
            )
        )
    }

    @Test func iCloudMirrorFallsBackLocallyWhenSyncOffAndSkipsIncomplete() async throws {
        let root = temporaryDirectory()
        let iCloudRoot = temporaryDirectory("PublicDocumentiCloudOff")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: iCloudRoot)
        }
        let startedAt = Date(timeIntervalSince1970: 1_786_501_800)
        let recording = Recording(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(20),
            title: "未完成",
            isMeeting: false,
            state: .processing
        )
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/note.m4a",
            startSample: 0,
            endSample: 80_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(20)
        )
        let processing = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentTexts: [(chunkID: chunk.id, text: "处理中")],
            timezone: "Asia/Shanghai",
            state: .processing
        )
        let store = try TranscriptDocumentStore(rootURL: root)
        try await store.write(processing)

        let mirror = PublicDocumentiCloudMirror(
            localRootURL: root,
            configuration: .init(
                isDocumentSyncEnabled: { false },
                ubiquityDocumentsURL: { iCloudRoot }
            )
        )
        let publisher = PublicDocumentPublisher(rootURL: root, iCloudMirror: mirror)
        let processingResult = try await publisher.publish(
            document: processing,
            dayDocuments: [processing]
        )
        #expect(processingResult.iCloudMirror?.destination == .skipped)
        #expect(processingResult.iCloudMirror?.fallbackReason == "incompleteDocument")
        #expect(!FileManager.default.fileExists(atPath: iCloudRoot.appendingPathComponent("Daily").path))

        let completeRecording = Recording(
            id: recording.id,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(20),
            title: "完成",
            isMeeting: false,
            state: .complete
        )
        let complete = TranscriptDocumentV1(
            recording: completeRecording,
            chunks: [chunk],
            segmentTexts: [(chunkID: chunk.id, text: "完成正文")],
            timezone: "Asia/Shanghai",
            state: .complete
        )
        try await store.write(complete)
        let completeResult = try await publisher.publish(
            document: complete,
            dayDocuments: [complete]
        )
        #expect(completeResult.iCloudMirror?.destination == .localOnly)
        #expect(completeResult.iCloudMirror?.fallbackReason == "documentSyncDisabled")
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Daily/2026/08/12/timeline.json").path
            )
        )
        #expect(!FileManager.default.fileExists(atPath: iCloudRoot.appendingPathComponent("Daily").path))
    }

    @Test func iCloudMirrorKeepsConflictCopyWhenCloudRevisionIsNewer() async throws {
        let root = temporaryDirectory()
        let iCloudRoot = temporaryDirectory("PublicDocumentConflict")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: iCloudRoot)
        }
        let startedAt = Date(timeIntervalSince1970: 1_786_501_800)
        let recording = Recording(
            id: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(15),
            title: "冲突",
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
        {"schema":"voice-context/transcript@1","recording_id":"\(recording.id.uuidString)","kind":"recording","state":"complete","revision":3,"title":"冲突","segments":[{"text":"云端新版"}]}
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

        let cloudText = try String(contentsOf: cloudJSON, encoding: .utf8)
        #expect(cloudText.contains("云端新版"))
        #expect(PublicDocumentFileIO.revision(inJSONAt: cloudJSON) == 3)

        let conflictFiles = try FileManager.default.contentsOfDirectory(
            at: cloudJSON.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("conflict") }
        #expect(!conflictFiles.isEmpty)
    }

    private func temporaryDirectory(_ prefix: String = "PublicDocumentTests") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
