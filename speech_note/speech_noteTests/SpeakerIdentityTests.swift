import Foundation
import Testing
@testable import speech_note

struct SpeakerIdentityTests {
    @Test func matcherProducesUnknownSuspectedAndConfirmProducesConfirmed() throws {
        var archive = VoiceprintArchive(identities: [
            VoiceprintIdentity(displayName: "Alice", embeddings: [[1, 0]]),
            VoiceprintIdentity(displayName: "Bob", embeddings: [[0, 1]]),
        ])

        // Near Alice, far from Bob → suspected.
        let aliceQuery: [Float] = [0.99, 0.01]
        let suspected = SuspectedIdentityMatcher.match(query: aliceQuery, against: archive)
        #expect(suspected.isSuspected)
        guard case let .suspected(id, name) = suspected.state else {
            Issue.record("expected suspected")
            return
        }
        #expect(name == "Alice")
        #expect(id == archive.identities[0].id)
        #expect((suspected.top1?.score ?? 0) >= SuspectedIdentityMatcher.top1SimilarityThreshold)
        #expect((suspected.margin ?? 0) >= SuspectedIdentityMatcher.top2MarginThreshold)

        // Near-ties between Alice and Bob → unknown despite a moderate top-1 score.
        let ambiguous = SuspectedIdentityMatcher.match(query: [1, 1], against: archive)
        #expect(ambiguous.state == .unknown)
        #expect((ambiguous.margin ?? 1) < SuspectedIdentityMatcher.top2MarginThreshold)

        // No archive → unknown.
        #expect(SuspectedIdentityMatcher.match(query: [1, 0], against: VoiceprintArchive()).state == .unknown)

        var bindings = [
            MeetingSpeakerBinding(
                temporaryLabel: "说话人 1",
                state: .suspected(identityID: id, displayName: name),
                candidateEmbeddings: [aliceQuery, [1, 0]]
            )
        ]
        let beforeCount = archive.identities[0].embeddings.count
        let confirmed = try SpeakerIdentityConfirmation.confirm(
            temporaryLabel: "说话人 1",
            displayName: "Alice",
            bindings: &bindings,
            archive: &archive
        )
        #expect(confirmed.id == id)
        #expect(bindings[0].state == .confirmed(identityID: id, displayName: "Alice"))
        #expect(bindings[0].state.isConfirmed)
        #expect(archive.identities[0].embeddings.count > beforeCount)
        #expect(SpeakerIdentityLabeling.chipText(
            temporaryLabel: "说话人 1",
            state: bindings[0].state
        ) == "Alice")
        #expect(SpeakerIdentityLabeling.chipText(
            temporaryLabel: "说话人 1",
            state: .suspected(identityID: id, displayName: "Alice")
        ) == "疑似：Alice")
        #expect(SpeakerIdentityLabeling.chipText(
            temporaryLabel: "说话人 1",
            state: .unknown
        ) == "说话人 1")
    }

    @Test func denyDoesNotPolluteArchiveAndBlocksSameSuggestion() throws {
        let aliceID = UUID()
        let archiveSnapshot = VoiceprintArchive(identities: [
            VoiceprintIdentity(id: aliceID, displayName: "Alice", embeddings: [[1, 0]]),
            VoiceprintIdentity(displayName: "Bob", embeddings: [[0, 1]]),
        ])
        var archive = archiveSnapshot
        var bindings = [
            MeetingSpeakerBinding(
                temporaryLabel: "说话人 1",
                state: .suspected(identityID: aliceID, displayName: "Alice"),
                candidateEmbeddings: [[0.98, 0.02]]
            )
        ]

        try SpeakerIdentityConfirmation.deny(temporaryLabel: "说话人 1", bindings: &bindings)
        #expect(bindings[0].state == .unknown)
        #expect(bindings[0].deniedIdentityIDs.contains(aliceID))
        #expect(archive == archiveSnapshot)

        SpeakerIdentityConfirmation.applySuspectedMatches(to: &bindings, archive: archive)
        #expect(bindings[0].state == .unknown)
        #expect(archive == archiveSnapshot)
    }

    @Test func unconfirmedSuspectedMatchNeverWritesArchive() {
        let original = VoiceprintArchive(identities: [
            VoiceprintIdentity(displayName: "Alice", embeddings: [[1, 0]]),
            VoiceprintIdentity(displayName: "Bob", embeddings: [[0, 1]]),
        ])
        var archive = original

        let observations = [
            OfflineSpeakerObservation(
                startSample: 0,
                endSample: 32_000,
                embedding: .embedding([0.99, 0.01]),
                exclusionReasons: [],
                onlineTemporaryLabel: "说话人 1"
            ),
            OfflineSpeakerObservation(
                startSample: 32_000,
                endSample: 64_000,
                embedding: .embedding([0.98, 0.02]),
                exclusionReasons: [],
                onlineTemporaryLabel: "说话人 1"
            ),
        ]
        let bindings = SpeakerIdentityConfirmation.makeBindings(
            speakers: ["说话人 1"],
            labels: ["说话人 1", "说话人 1"],
            observations: observations,
            archive: archive
        )
        #expect(bindings.count == 1)
        #expect(bindings[0].state.isSuspected)
        #expect(archive == original)

        var mutable = bindings
        SpeakerIdentityConfirmation.applySuspectedMatches(to: &mutable, archive: archive)
        #expect(archive == original)
        #expect(mutable[0].state.isSuspected)
    }

    @Test func confirmWritesOnlyQualityEmbeddings() throws {
        var archive = VoiceprintArchive()
        var bindings = [
            MeetingSpeakerBinding(
                temporaryLabel: "说话人 1",
                candidateEmbeddings: [
                    [1, 0],
                    [0, 0],          // rejected: zero vector
                    [Float.nan, 1],  // rejected: non-finite
                    [],              // rejected: empty
                    [0.6, 0.8],
                ]
            )
        ]

        let identity = try SpeakerIdentityConfirmation.confirm(
            temporaryLabel: "说话人 1",
            displayName: "Carol",
            bindings: &bindings,
            archive: &archive
        )
        #expect(identity.displayName == "Carol")
        #expect(identity.embeddings.count == 2)
        #expect(identity.embeddings.allSatisfy { vector in
            abs(vector.map { $0 * $0 }.reduce(0, +) - 1) < 0.000_1
        })
        #expect(bindings[0].state.isConfirmed)

        // Confirm with only invalid candidates must fail and leave archive unchanged.
        var dirtyArchive = VoiceprintArchive()
        var dirtyBindings = [
            MeetingSpeakerBinding(
                temporaryLabel: "说话人 2",
                candidateEmbeddings: [[0, 0], [Float.infinity, 1]]
            )
        ]
        #expect(throws: SpeakerIdentityConfirmation.ActionError.noQualityEmbeddings) {
            try SpeakerIdentityConfirmation.confirm(
                temporaryLabel: "说话人 2",
                displayName: "Dave",
                bindings: &dirtyBindings,
                archive: &dirtyArchive
            )
        }
        #expect(dirtyArchive.identities.isEmpty)
        #expect(dirtyBindings[0].state == .unknown)
        #expect(
            SpeakerIdentityConfirmation.ActionError.noQualityEmbeddings.errorDescription?
                .contains("声纹") == true
        )
    }

    @Test func renameDoesNotAppendEmbeddingsAndSuspectedKeepsMarker() throws {
        let id = UUID()
        var archive = VoiceprintArchive(identities: [
            VoiceprintIdentity(id: id, displayName: "Alice", embeddings: [[1, 0]])
        ])
        var bindings = [
            MeetingSpeakerBinding(
                temporaryLabel: "说话人 1",
                state: .suspected(identityID: id, displayName: "Alice"),
                candidateEmbeddings: [[1, 0]]
            )
        ]
        let renamed = try SpeakerIdentityConfirmation.rename(
            temporaryLabel: "说话人 1",
            displayName: "Alice-2",
            bindings: &bindings,
            archive: &archive
        )
        #expect(renamed == "Alice-2")
        #expect(bindings[0].chipText == "疑似：Alice-2")
        #expect(archive.identities[0].embeddings.count == 1)
        #expect(archive.identities[0].displayName == "Alice")

        _ = try SpeakerIdentityConfirmation.confirm(
            temporaryLabel: "说话人 1",
            displayName: "Alice-2",
            bindings: &bindings,
            archive: &archive
        )
        let before = archive.identities[0].embeddings.count
        _ = try SpeakerIdentityConfirmation.rename(
            temporaryLabel: "说话人 1",
            displayName: "Alice Final",
            bindings: &bindings,
            archive: &archive
        )
        #expect(archive.identities[0].displayName == "Alice Final")
        #expect(archive.identities[0].embeddings.count == before)
        #expect(bindings[0].chipText == "Alice Final")
    }

    @Test func archiveStorageRoundTripStaysOutOfPublicDocumentsContract() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceprint-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent(VoiceprintArchiveStorage.fileName)
        let keyStore = InMemoryVoiceprintArchiveKeyStore()
        var archive = VoiceprintArchive()
        archive.upsert(VoiceprintIdentity(displayName: "Eve", embeddings: [[0, 1]]))
        try VoiceprintArchiveStorage.save(archive, to: url, keyProvider: keyStore)
        let loaded = try VoiceprintArchiveStorage.load(from: url, keyProvider: keyStore)
        #expect(loaded.identities.count == 1)
        #expect(loaded.identities[0].displayName == "Eve")
        #expect(url.path.contains("voiceprint-archive.aesgcm"))
        let data = try Data(contentsOf: url)
        #expect(!VoiceprintArchiveCrypto.looksLikeLegacyPlaintextArchive(data))
    }

    @Test func top1WithoutSufficientMarginStaysUnknown() {
        let archive = VoiceprintArchive(identities: [
            VoiceprintIdentity(displayName: "A", embeddings: [[1, 0]]),
            VoiceprintIdentity(displayName: "B", embeddings: [[0.97, 0.243]]),
        ])
        // Query close to both centroids → high top-1 but tiny margin.
        let result = SuspectedIdentityMatcher.match(query: [0.995, 0.1], against: archive)
        #expect(result.state == .unknown)
        #expect((result.top1?.score ?? 0) > 0.5)
        #expect((result.margin ?? 1) < SuspectedIdentityMatcher.top2MarginThreshold)
    }
}
