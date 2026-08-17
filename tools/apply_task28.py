#!/usr/bin/env python3
"""Apply #28 changes onto the voice_type tree on the user Mac."""
from __future__ import annotations

import re
import shutil
from pathlib import Path

ROOT = Path("/Users/scott/Documents/01-开发项目/AI应用/voice_type")
APP = ROOT / "speech_note" / "speech_note"
TESTS = ROOT / "speech_note" / "speech_noteTests"
DRAFT = Path("/Users/scott/Documents/01-开发项目/AI应用/voice_type/tools/task28_drafts")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing pattern for {label}")
    return text.replace(old, new, 1)


def patch_transcript_document() -> None:
    path = APP / "TranscriptDocumentV1.swift"
    text = path.read_text()
    text = replace_once(
        text,
        "    let title: String?\n    let tags: [String]\n",
        "    var title: String?\n    var tags: [String]\n",
        "title/tags var",
    )
    text = replace_once(
        text,
        "    let segments: [Segment]\n",
        "    var segments: [Segment]\n",
        "segments var",
    )
    path.write_text(text)
    print("patched TranscriptDocumentV1.swift")


def patch_speaker_identity() -> None:
    path = APP / "SpeakerIdentity.swift"
    text = path.read_text()
    text = replace_once(
        text,
        "nonisolated struct MeetingSpeakerBinding: Equatable, Sendable {",
        "nonisolated struct MeetingSpeakerBinding: Equatable, Sendable, Codable {",
        "MeetingSpeakerBinding Codable",
    )
    path.write_text(text)
    print("patched SpeakerIdentity.swift")


def patch_offline_pass() -> None:
    path = APP / "OfflineSpeakerReclustering.swift"
    text = path.read_text()
    old = '''enum OfflineSpeakerReclusterPass {
    enum PassError: LocalizedError {
        case missingResource(String)
        case missingManifest

        var errorDescription: String? {
            switch self {
            case let .missingResource(name):
                "离线重聚类缺少模型：\\(name)。"
            case .missingManifest:
                "离线重聚类找不到 ModelManifest.json。"
            }
        }
    }

    static func bundledResourceRoot(bundle: Bundle = .main) throws -> URL {
        guard let manifestURL = bundle.url(forResource: "ModelManifest", withExtension: "json") else {
            throw PassError.missingManifest
        }
        return manifestURL.deletingLastPathComponent()
    }

    static func run(
        chunkURLs: [(url: URL, startSample: Int64)],
        resourceRoot: URL
    ) async throws -> OfflineSpeakerReclustering.Result {
        try await Task.detached(priority: .userInitiated) {
            try runSync(chunkURLs: chunkURLs, resourceRoot: resourceRoot)
        }.value
    }

    nonisolated private static func runSync(
        chunkURLs: [(url: URL, startSample: Int64)],
        resourceRoot: URL
    ) throws -> OfflineSpeakerReclustering.Result {
'''
    new = '''enum OfflineSpeakerReclusterPass {
    struct PassResult: Equatable, Sendable {
        let recluster: OfflineSpeakerReclustering.Result
        let observations: [OfflineSpeakerObservation]
    }

    enum PassError: LocalizedError {
        case missingResource(String)
        case missingManifest

        var errorDescription: String? {
            switch self {
            case let .missingResource(name):
                "离线重聚类缺少模型：\\(name)。"
            case .missingManifest:
                "离线重聚类找不到 ModelManifest.json。"
            }
        }
    }

    static func bundledResourceRoot(bundle: Bundle = .main) throws -> URL {
        guard let manifestURL = bundle.url(forResource: "ModelManifest", withExtension: "json") else {
            throw PassError.missingManifest
        }
        return manifestURL.deletingLastPathComponent()
    }

    static func run(
        chunkURLs: [(url: URL, startSample: Int64)],
        resourceRoot: URL
    ) async throws -> PassResult {
        try await Task.detached(priority: .userInitiated) {
            try runSync(chunkURLs: chunkURLs, resourceRoot: resourceRoot)
        }.value
    }

    nonisolated private static func runSync(
        chunkURLs: [(url: URL, startSample: Int64)],
        resourceRoot: URL
    ) throws -> PassResult {
'''
    text = replace_once(text, old, new, "OfflineSpeakerReclusterPass signature")
    text = replace_once(
        text,
        "        return OfflineSpeakerReclustering.recluster(observations)\n    }\n}\n",
        "        let recluster = OfflineSpeakerReclustering.recluster(observations)\n"
        "        return PassResult(recluster: recluster, observations: observations)\n"
        "    }\n}\n",
        "OfflineSpeakerReclusterPass return",
    )
    path.write_text(text)
    print("patched OfflineSpeakerReclustering.swift")


def patch_journal_title() -> None:
    domain = APP / "RecordingDomain.swift"
    text = domain.read_text()
    text = replace_once(
        text,
        "    case chunkAudioRemoved(chunkID: UUID, removedAt: Date)\n}",
        "    case chunkAudioRemoved(chunkID: UUID, removedAt: Date)\n"
        "    case recordingTitleChanged(recordingID: UUID, title: String?)\n}",
        "journal payload title",
    )
    domain.write_text(text)

    index = APP / "RecordingIndex.swift"
    text = index.read_text()
    text = replace_once(
        text,
        '''        case let .chunkAudioRemoved(chunkID, removedAt):
            try execute(
                "UPDATE audio_chunks SET state = ?, audio_removed_at = ? WHERE id = ?",
                [.text(AudioChunkState.audioRemoved.rawValue), .double(removedAt.timeIntervalSince1970), .text(chunkID.uuidString)]
            )
        }
    }
''',
        '''        case let .chunkAudioRemoved(chunkID, removedAt):
            try execute(
                "UPDATE audio_chunks SET state = ?, audio_removed_at = ? WHERE id = ?",
                [.text(AudioChunkState.audioRemoved.rawValue), .double(removedAt.timeIntervalSince1970), .text(chunkID.uuidString)]
            )
        case let .recordingTitleChanged(recordingID, title):
            try execute(
                "UPDATE recordings SET title = ?, updated_at = ? WHERE id = ?",
                [title.sqliteValue, .double(occurredAt.timeIntervalSince1970), .text(recordingID.uuidString)]
            )
        }
    }
''',
        "index apply title",
    )
    index.write_text(text)

    repo = APP / "RecordingRepository.swift"
    text = repo.read_text()
    # Insert after setRecordingRetention
    needle = '''    func setRecordingRetention(
        recordingID: UUID,
        retention: AudioRetention,
        at date: Date
    ) throws {
        try persist(.init(
            occurredAt: date,
            payload: .retentionChanged(recordingID: recordingID, retention: retention)
        ))
    }
'''
    addition = needle + '''
    func setRecordingTitle(
        recordingID: UUID,
        title: String?,
        at date: Date
    ) throws {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        try persist(.init(
            occurredAt: date,
            payload: .recordingTitleChanged(
                recordingID: recordingID,
                title: (trimmed?.isEmpty == false) ? trimmed : nil
            )
        ))
    }
'''
    text = replace_once(text, needle, addition, "repository setRecordingTitle")
    repo.write_text(text)
    print("patched journal/title path")


def patch_recording_core_model() -> None:
    path = APP / "RecordingCoreModel.swift"
    text = path.read_text()

    old_offline = '''    /// CPU-only CAM++ pass over closed chunks. Does not submit SenseVoice/Metal.
    private static func offlineSpeakerRecluster(
        recordingID: UUID,
        repository: RecordingRepository
    ) async throws -> OfflineSpeakerReclustering.Result {
        let chunks = try await repository.chunks(recordingID: recordingID)
            .filter { $0.state == .closed && $0.audioRemovedAt == nil }
            .sorted { $0.startSample < $1.startSample }
        let chunkURLs = chunks.map {
            (
                url: repository.rootURL.appendingPathComponent($0.relativePath),
                startSample: $0.startSample
            )
        }
        let resourceRoot = try OfflineSpeakerReclusterPass.bundledResourceRoot()
        return try await OfflineSpeakerReclusterPass.run(
            chunkURLs: chunkURLs,
            resourceRoot: resourceRoot
        )
    }
'''
    new_offline = '''    /// CPU-only CAM++ pass over closed chunks. Does not submit SenseVoice/Metal.
    private static func offlineSpeakerRecluster(
        recordingID: UUID,
        repository: RecordingRepository
    ) async throws -> OfflineSpeakerReclusterPass.PassResult {
        let chunks = try await repository.chunks(recordingID: recordingID)
            .filter { $0.state == .closed && $0.audioRemovedAt == nil }
            .sorted { $0.startSample < $1.startSample }
        let chunkURLs = chunks.map {
            (
                url: repository.rootURL.appendingPathComponent($0.relativePath),
                startSample: $0.startSample
            )
        }
        let resourceRoot = try OfflineSpeakerReclusterPass.bundledResourceRoot()
        return try await OfflineSpeakerReclusterPass.run(
            chunkURLs: chunkURLs,
            resourceRoot: resourceRoot
        )
    }
'''
    text = replace_once(text, old_offline, new_offline, "offlineSpeakerRecluster return")

    old_apply = '''                    if let document = try await transcriptStore.document(recordingID: outcome.recordingID) {
                        var completed = document.updatingState(.complete)
                        // FR-SPK-004: replace per-chunk temporary IDs with stable
                        // offline turns. Failure keeps the online roster and
                        // must not block Recording completion.
                        if let reclustered = try? await Self.offlineSpeakerRecluster(
                            recordingID: outcome.recordingID,
                            repository: repository
                        ) {
                            completed = completed.applyingOfflineRecluster(
                                speakers: reclustered.speakers,
                                speakerTurns: reclustered.turns
                            )
                        }
                        try await transcriptStore.write(completed)
                        do {
                            try await publishPublicDocuments(for: completed)
                        } catch {
                            notice = "本地文稿已保存，公开目录同步稍后可重试：" + error.localizedDescription
                        }
                    }
'''
    new_apply = '''                    if let document = try await transcriptStore.document(recordingID: outcome.recordingID) {
                        var completed = document.updatingState(.complete)
                        // FR-SPK-004: replace per-chunk temporary IDs with stable
                        // offline turns. Failure keeps the online roster and
                        // must not block Recording completion.
                        if let pass = try? await Self.offlineSpeakerRecluster(
                            recordingID: outcome.recordingID,
                            repository: repository
                        ) {
                            completed = completed.applyingOfflineRecluster(
                                speakers: pass.recluster.speakers,
                                speakerTurns: pass.recluster.turns
                            )
                            // #27 leftover / #28: suspected matches after offline
                            // recluster. Matching never mutates the archive.
                            if let archiveURL = try? VoiceprintArchiveStorage.defaultURL(),
                               let archive = try? VoiceprintArchiveStorage.load(from: archiveURL) {
                                let bindings = SpeakerIdentityConfirmation.makeBindings(
                                    speakers: pass.recluster.speakers,
                                    labels: pass.recluster.labels,
                                    observations: pass.observations,
                                    archive: archive
                                )
                                try? MeetingSpeakerBindingStore.save(
                                    bindings,
                                    rootURL: repository.rootURL,
                                    recordingID: outcome.recordingID
                                )
                            }
                        }
                        try await transcriptStore.write(completed)
                        do {
                            try await publishPublicDocuments(for: completed)
                        } catch {
                            notice = "本地文稿已保存，公开目录同步稍后可重试：" + error.localizedDescription
                        }
                    }
'''
    text = replace_once(text, old_apply, new_apply, "applyTranscriptionOutcome recluster hook")

    # Insert edit / identity APIs before publishPublicDocuments(for:)
    api = '''
    /// Persist user edits to the canonical transcript, rebuild Markdown, bump
    /// revision once, sync Recording title, and best-effort republish public docs.
    /// Never advances an incomplete job to `complete`.
    @discardableResult
    func saveTranscriptEdits(
        recordingID: UUID,
        title: String?,
        tags: [String],
        segmentTexts: [UUID: String]
    ) async throws -> TranscriptDocumentV1 {
        guard let document = try await transcriptStore.document(recordingID: recordingID) else {
            throw PublicDocumentPublisher.PublishError.unresolvedRelativePath("Transcripts/" + recordingID.uuidString)
        }
        let edited = document.applyingUserEdits(
            title: title,
            tags: tags,
            segmentTexts: segmentTexts
        )
        try await transcriptStore.write(edited)
        try? await repository.setRecordingTitle(
            recordingID: recordingID,
            title: edited.title,
            at: Date()
        )
        do {
            try await publishPublicDocuments(for: edited)
        } catch {
            notice = "文稿已保存，公开目录同步稍后可重试：" + error.localizedDescription
        }
        await refresh()
        return edited
    }

    func speakerBindings(recordingID: UUID) async throws -> [MeetingSpeakerBinding] {
        try MeetingSpeakerBindingStore.load(
            rootURL: repository.rootURL,
            recordingID: recordingID
        )
    }

    @discardableResult
    func confirmSpeakerIdentity(
        recordingID: UUID,
        temporaryLabel: String,
        displayName: String
    ) async throws -> (TranscriptDocumentV1?, [MeetingSpeakerBinding]) {
        try await mutateSpeakerIdentity(recordingID: recordingID) { bindings, archive in
            try SpeakerIdentityConfirmation.confirm(
                temporaryLabel: temporaryLabel,
                displayName: displayName,
                bindings: &bindings,
                archive: &archive
            )
        }
    }

    @discardableResult
    func denySpeakerIdentity(
        recordingID: UUID,
        temporaryLabel: String
    ) async throws -> (TranscriptDocumentV1?, [MeetingSpeakerBinding]) {
        try await mutateSpeakerIdentity(recordingID: recordingID) { bindings, archive in
            try SpeakerIdentityConfirmation.deny(
                temporaryLabel: temporaryLabel,
                bindings: &bindings
            )
        }
    }

    @discardableResult
    func renameSpeakerIdentity(
        recordingID: UUID,
        temporaryLabel: String,
        displayName: String
    ) async throws -> (TranscriptDocumentV1?, [MeetingSpeakerBinding]) {
        try await mutateSpeakerIdentity(recordingID: recordingID) { bindings, archive in
            _ = try SpeakerIdentityConfirmation.rename(
                temporaryLabel: temporaryLabel,
                displayName: displayName,
                bindings: &bindings,
                archive: &archive
            )
        }
    }

    private func mutateSpeakerIdentity(
        recordingID: UUID,
        _ body: (inout [MeetingSpeakerBinding], inout VoiceprintArchive) throws -> Void
    ) async throws -> (TranscriptDocumentV1?, [MeetingSpeakerBinding]) {
        var bindings = try MeetingSpeakerBindingStore.load(
            rootURL: repository.rootURL,
            recordingID: recordingID
        )
        if bindings.isEmpty, let document = try await transcriptStore.document(recordingID: recordingID) {
            bindings = document.speakers.map {
                MeetingSpeakerBinding(temporaryLabel: $0, state: .unknown)
            }
        }
        let archiveURL = try VoiceprintArchiveStorage.defaultURL()
        var archive = try VoiceprintArchiveStorage.load(from: archiveURL)
        try body(&bindings, &archive)
        try VoiceprintArchiveStorage.save(archive, to: archiveURL)
        try MeetingSpeakerBindingStore.save(
            bindings,
            rootURL: repository.rootURL,
            recordingID: recordingID
        )

        var updatedDocument: TranscriptDocumentV1?
        if let document = try await transcriptStore.document(recordingID: recordingID) {
            let mapping = TranscriptDocumentV1.speakerDisplayMapping(from: bindings)
            if !mapping.isEmpty {
                let edited = document.applyingSpeakerLabelMapping(mapping)
                try await transcriptStore.write(edited)
                do {
                    try await publishPublicDocuments(for: edited)
                } catch {
                    notice = "说话人已更新，公开目录同步稍后可重试：" + error.localizedDescription
                }
                updatedDocument = edited
            } else {
                updatedDocument = document
            }
        }
        await refresh()
        return (updatedDocument, bindings)
    }

'''
    text = replace_once(
        text,
        "    @discardableResult\n    func publishPublicDocuments(for document: TranscriptDocumentV1) async throws -> PublicDocumentPublishResult {\n",
        api + "    @discardableResult\n    func publishPublicDocuments(for document: TranscriptDocumentV1) async throws -> PublicDocumentPublishResult {\n",
        "insert edit APIs",
    )
    path.write_text(text)
    print("patched RecordingCoreModel.swift")


def patch_content_view() -> None:
    path = APP / "ContentView.swift"
    text = path.read_text()

    # Make RecordingBar internal so detail file can reuse session chrome.
    text = text.replace("private struct RecordingBar: View {", "struct RecordingBar: View {", 1)

    # Remove RecordingDetailScreen block.
    start = text.find("/// A deliberately small, truthful detail surface")
    end = text.find("private struct CalendarStrip: View {")
    if start < 0 or end < 0 or end <= start:
        raise SystemExit("could not locate RecordingDetailScreen block")
    text = text[:start] + text[end:]
    path.write_text(text)
    print("patched ContentView.swift (removed detail, exposed RecordingBar)")


def copy_new_files() -> None:
    mapping = {
        "TranscriptDocumentEdits.swift": APP / "TranscriptDocumentEdits.swift",
        "MeetingSpeakerBindingStore.swift": APP / "MeetingSpeakerBindingStore.swift",
        "RecordingDetailView.swift": APP / "RecordingDetailView.swift",
        "TranscriptEditTests.swift": TESTS / "TranscriptEditTests.swift",
    }
    for src_name, dest in mapping.items():
        shutil.copy2(DRAFT / src_name, dest)
        print(f"copied {src_name} -> {dest}")


def fix_edit_tests_api() -> None:
    path = TESTS / "TranscriptEditTests.swift"
    text = path.read_text()
    text = text.replace(
        """        let edited = initial.applyingUserEdits(
            title: "修订标题",
            tags: ["产品", "周会", "产品"],
            segmentTexts: [segmentID: "纠正后的句子"],
            speakers: ["说话人 1", "说话人 2"]
        )""",
        """        let edited = initial.applyingUserEdits(
            title: "修订标题",
            tags: ["产品", "周会", "产品"],
            segmentTexts: [segmentID: "纠正后的句子"],
            speakers: ["说话人 1", "说话人 2"]
        )""",
    )
    text = text.replace(
        "let again = edited.applyingUserEdits(title: \"再次修订\", tags: edited.tags)",
        "let again = edited.applyingUserEdits(title: \"再次修订\", tags: edited.tags, segmentTexts: [:])",
    )
    path.write_text(text)


def main() -> None:
    copy_new_files()
    fix_edit_tests_api()
    patch_transcript_document()
    patch_speaker_identity()
    patch_offline_pass()
    patch_journal_title()
    patch_recording_core_model()
    patch_content_view()
    print("ALL PATCHES APPLIED")


if __name__ == "__main__":
    main()
