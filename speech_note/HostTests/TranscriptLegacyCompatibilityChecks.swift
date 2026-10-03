import CryptoKit
import Foundation

/// Reads controlled temporary files with the production TranscriptDocumentStore
/// decoder. No model or date-decoding implementation is copied into this test.
enum TranscriptLegacyCompatibilityChecks {
    static func run() async throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("speech_noteTests/Fixtures", isDirectory: true)
        let legacyBytes = try Data(contentsOf: fixtures.appendingPathComponent("transcript_v1_legacy_source_chunk_fixture.json"))
        let rangeBytes = try Data(contentsOf: fixtures.appendingPathComponent("transcript_v1_schema_fixture.json"))
        let legacy = try JSONSerialization.jsonObject(with: legacyBytes) as! [String: Any]
        let current = try JSONSerialization.jsonObject(with: rangeBytes) as! [String: Any]
        let recordingID = UUID(uuidString: legacy["recording_id"] as! String)!
        let segmentID = UUID(uuidString: "BA485C93-6D6E-42E9-ADDA-B8DA00000001")!
        let sourceID = UUID(uuidString: "D1765381-81EC-4761-BDDF-8978200D4197")!
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("yima-transcript-legacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }

        func read(_ name: String, _ bytes: Data) async throws -> (TranscriptDocumentStore, TranscriptDocumentV1, URL) {
            let store = try TranscriptDocumentStore(rootURL: temporary.appendingPathComponent(name))
            let url = await store.jsonURL(for: recordingID)
            try bytes.write(to: url, options: .atomic)
            guard let document = try await store.document(recordingID: recordingID) else {
                preconditionFailure("Temporary legacy fixture was not read: \(name)")
            }
            return (store, document, url)
        }
        func bytes(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        func replacingSegment(_ object: [String: Any], _ transform: (inout [String: Any]) -> Void) -> [String: Any] {
            var result = object
            var segments = result["segments"] as! [[String: Any]]
            transform(&segments[0])
            result["segments"] = segments
            return result
        }
        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        let (_, old, _) = try await read("bare-source-chunk", legacyBytes)
        precondition(old.recordingID == recordingID && old.segments[0].id == segmentID)
        precondition(old.endedAt?.timeIntervalSince(old.startedAt) == 60)
        precondition(old.segments[0].text == "旧版单一 source_chunk_id。")
        precondition(old.segments[0].sourceRanges == [.init(sourceID: sourceID, startSample: 0, endSample: 0)])
        precondition(old.segments[0].startSample == 0 && old.segments[0].endSample == 0)
        let shifted = replacingSegment(legacy) { $0["offset_milliseconds"] = 60_000 }
        let (_, shiftedDocument, _) = try await read("bare-source-offset", bytes(shifted))
        precondition(shiftedDocument.segments[0].sourceRanges == [.init(sourceID: sourceID, startSample: 960_000, endSample: 960_000)])
        print("PASS legacy source_chunk_id: missing end remains a zero-length anchor at offset * 16")

        let (_, ranged, _) = try await read("source-ranges", rangeBytes)
        precondition(ranged.segments.map(\.id) == [segmentID, UUID(uuidString: "BA485C93-6D6E-42E9-ADDA-B8DA00000002")!])
        precondition(ranged.segments.map(\.sourceRanges) == [
            [.init(sourceID: sourceID, startSample: 0, endSample: 960_000)],
            [.init(sourceID: UUID(uuidString: "E2765381-81EC-4761-BDDF-8978200D4198")!, startSample: 960_000, endSample: 1_920_000)],
        ])
        let speechSpanID = UUID(uuidString: "D1765381-81EC-4761-BDDF-897820000001")!
        let aliased = replacingSegment(current) { segment in
            segment.removeValue(forKey: "speech_span_ids")
            segment["speech_span_i_ds"] = [speechSpanID.uuidString]
            segment["source_chunk_id"] = "D1765381-81EC-4761-BDDF-897820000002"
            var ranges = segment["source_ranges"] as! [[String: Any]]
            ranges[0]["chunk_id"] = ranges[0].removeValue(forKey: "source_id")
            ranges[0].removeValue(forKey: "source_kind")
            segment["source_ranges"] = ranges
        }
        let (aliasStore, aliases, _) = try await read("legacy-aliases", bytes(aliased))
        precondition(aliases.segments[0].sourceRanges == ranged.segments[0].sourceRanges)
        precondition(aliases.segments[0].speechSpanIDs == [speechSpanID])
        try await aliasStore.write(aliases)
        let aliasRoundTrip = try await aliasStore.document(recordingID: recordingID)
        precondition(aliasRoundTrip == aliases, "Old spelling must re-encode and remain readable")
        print("PASS source_ranges precedence, legacy chunk_id/default kind, and speech_span_i_ds alias")

        var minimal = legacy
        for key in ["title", "tags", "participants", "language", "language_mode", "speaker_turns", "speech_spans", "speakers", "gaps"] {
            minimal.removeValue(forKey: key)
        }
        let minimalSegment = replacingSegment(minimal) { $0.removeValue(forKey: "speech_span_ids") }
        let (_, defaults, _) = try await read("missing-optional-fields", bytes(minimalSegment))
        precondition(defaults.title == nil && defaults.tags.isEmpty && defaults.participants.isEmpty)
        precondition(defaults.language == "" && defaults.languageMode == .zhEnBilingual)
        precondition(defaults.speakerTurns.isEmpty && defaults.speakers.isEmpty && defaults.speechSpans.isEmpty && defaults.gaps.isEmpty)
        precondition(defaults.segments[0].speechSpanIDs.isEmpty && !defaults.segments[0].isManuallyEdited && defaults.segments[0].editedAt == nil)
        print("PASS optional-field defaults preserve legacy bilingual mode and absent edit metadata")

        var seconds = replacingSegment(legacy) { $0["started_at"] = "2026-08-05T07:00:00Z" }
        seconds["started_at"] = "2026-08-05T07:00:00Z"
        seconds["ended_at"] = "2026-08-05T07:01:00Z"
        let (secondsStore, wholeSeconds, secondsURL) = try await read("rfc3339-seconds", bytes(seconds))
        precondition(abs(old.startedAt.timeIntervalSince(wholeSeconds.startedAt) - 0.125) < 0.000_01)
        precondition(wholeSeconds.endedAt?.timeIntervalSince(wholeSeconds.startedAt) == 60)
        precondition(wholeSeconds.segments[0].startedAt == wholeSeconds.startedAt)
        try await secondsStore.write(wholeSeconds)
        let encodedSeconds = try JSONSerialization.jsonObject(with: Data(contentsOf: secondsURL)) as! [String: Any]
        precondition(encodedSeconds["started_at"] as? String == "2026-08-05T07:00:00.000Z")
        var offset = replacingSegment(legacy) { $0["started_at"] = "2026-08-05T15:00:00.125+08:00" }
        offset["started_at"] = "2026-08-05T15:00:00.125+08:00"
        offset["ended_at"] = "2026-08-05T15:01:00.125+08:00"
        let (_, offsetDocument, _) = try await read("rfc3339-offset-milliseconds", bytes(offset))
        precondition(offsetDocument.startedAt == old.startedAt && offsetDocument.endedAt == old.endedAt)
        precondition(offsetDocument.endedAt?.timeIntervalSince(offsetDocument.startedAt) == 60)
        precondition(offsetDocument.segments[0].startedAt == old.segments[0].startedAt)
        print("PASS RFC3339 without fractions, milliseconds, explicit offset, and UTC millisecond re-encoding")

        let manual = replacingSegment(legacy) { segment in
            segment["id"] = segmentID.uuidString.lowercased()
            segment["text"] = "人工校对，保持旧 ID 和来源点"
            segment["is_manually_edited"] = true
            segment["edited_at"] = "2026-08-05T07:03:00.875Z"
        }
        let (manualStore, edited, _) = try await read("manually-edited", bytes(manual))
        precondition(edited.segments[0].id == segmentID && edited.segments[0].isManuallyEdited)
        precondition(edited.segments[0].text == "人工校对，保持旧 ID 和来源点")
        precondition(edited.segments[0].sourceRanges == old.segments[0].sourceRanges)
        precondition(edited.segments[0].editedAt!.timeIntervalSince(old.startedAt) == 180.75)
        try await manualStore.write(edited)
        let manualRoundTrip = try await manualStore.document(recordingID: recordingID)
        precondition(manualRoundTrip == edited, "Re-encoding must preserve edit provenance and stable UUID identity")
        print("PASS manually edited text, timestamp, UUID identity, and source anchor survive store round trip")

        let (hashStore, hashDocument, hashURL) = try await read("original-bytes-hash", legacyBytes)
        let originalHash = digest(legacyBytes)
        try await hashStore.write(hashDocument)
        let reencodedBytes = try Data(contentsOf: hashURL)
        let reencodedHash = digest(reencodedBytes)
        let hashRoundTrip = try await hashStore.document(recordingID: recordingID)
        precondition(hashRoundTrip == hashDocument)
        precondition(reencodedBytes != legacyBytes && reencodedHash != originalHash,
                     "An equivalent re-encoded document must not impersonate the original bytes hash")
        print("PASS original bytes SHA256=\(originalHash); re-encoded SHA256=\(reencodedHash) (distinct, semantically equal)")

        let reencoded = try JSONSerialization.jsonObject(with: reencodedBytes) as! [String: Any]
        precondition(old.state == "complete" && old.gaps.isEmpty && ranged.state == "complete" && ranged.gaps.isEmpty)
        for object in [legacy, current, reencoded] {
            for key in ["completeness", "evidence", "expectedRanges", "observedRanges"] {
                precondition(object[key] == nil, "Legacy complete is not new completeness evidence")
            }
        }
        precondition((reencoded["segments"] as! [[String: Any]])[0]["end_sample"] as? Int == 0)
        print("PASS legacy state=complete/gaps=[] and re-encoding add no coverage or completeness proof")
        print("Transcript legacy compatibility host checks passed (7 cases; fixtures are temporary).")
    }
}
