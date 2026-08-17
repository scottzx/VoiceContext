import Foundation
import UniformTypeIdentifiers

nonisolated enum RecordingOrigin: String, Codable, CaseIterable, Sendable {
    case microphone
    case importedAudio
}

/// One complete private copy of a Files- or Photos-imported audio file. Playback, retry,
/// and media export all read this asset; ProcessingRange never owns media.
/// When the original encoding cannot stably random-access decode, the private
/// copy may be replaced by a single standardized AAC asset (`isStandardized`).
nonisolated struct ImportedAudioAsset: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordingID: UUID
    let relativePath: String
    let sourceFilename: String
    let sourceUTType: String
    let durationSeconds: TimeInterval
    let sampleRate: Double?
    let channelCount: Int?
    let byteCount: Int64?
    let totalSamples: Int64
    let importedAt: Date
    var audioRemovedAt: Date?
    /// True when `relativePath` points at the unique standardized private asset.
    var isStandardized: Bool

    init(
        id: UUID = UUID(),
        recordingID: UUID,
        relativePath: String,
        sourceFilename: String,
        sourceUTType: String,
        durationSeconds: TimeInterval,
        sampleRate: Double? = nil,
        channelCount: Int? = nil,
        byteCount: Int64? = nil,
        totalSamples: Int64,
        importedAt: Date,
        audioRemovedAt: Date? = nil,
        isStandardized: Bool = false
    ) {
        self.id = id
        self.recordingID = recordingID
        self.relativePath = relativePath
        self.sourceFilename = sourceFilename
        self.sourceUTType = sourceUTType
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.byteCount = byteCount
        self.totalSamples = totalSamples
        self.importedAt = importedAt
        self.audioRemovedAt = audioRemovedAt
        self.isStandardized = isStandardized
    }

    private enum CodingKeys: String, CodingKey {
        case id, recordingID, relativePath, sourceFilename, sourceUTType
        case durationSeconds, sampleRate, channelCount, byteCount, totalSamples
        case importedAt, audioRemovedAt, isStandardized
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        recordingID = try container.decode(UUID.self, forKey: .recordingID)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        sourceFilename = try container.decode(String.self, forKey: .sourceFilename)
        sourceUTType = try container.decode(String.self, forKey: .sourceUTType)
        durationSeconds = try container.decode(TimeInterval.self, forKey: .durationSeconds)
        sampleRate = try container.decodeIfPresent(Double.self, forKey: .sampleRate)
        channelCount = try container.decodeIfPresent(Int.self, forKey: .channelCount)
        byteCount = try container.decodeIfPresent(Int64.self, forKey: .byteCount)
        totalSamples = try container.decode(Int64.self, forKey: .totalSamples)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        audioRemovedAt = try container.decodeIfPresent(Date.self, forKey: .audioRemovedAt)
        isStandardized = try container.decodeIfPresent(Bool.self, forKey: .isStandardized) ?? false
    }
}

nonisolated enum ImportAudioSupportedTypes: Sendable {
    /// First-wave types the Files picker offers. Final device matrix remains
    /// open in the requirement doc; these are the formats AVFoundation can
    /// commonly decode on iPhone.
    static var contentTypes: [UTType] {
        var types: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        if let m4a = UTType("com.apple.m4a-audio") {
            types.append(m4a)
        }
        if let caf = UTType("com.apple.coreaudio-format") {
            types.append(caf)
        }
        return types
    }
}
