import CryptoKit
import Foundation

/// AES-GCM envelope for the long-term voiceprint archive (FR-ICL-006).
nonisolated struct EncryptedVoiceprintEnvelope: Equatable, Sendable, Codable {
    static let currentFormat = "voiceprint-archive-aesgcm-v1"

    var format: String
    /// AES.GCM.SealedBox.combined = nonce || ciphertext || tag
    var sealedBox: Data

    init(format: String = currentFormat, sealedBox: Data) {
        self.format = format
        self.sealedBox = sealedBox
    }
}

nonisolated enum VoiceprintArchiveCryptoError: LocalizedError, Equatable {
    case missingKey
    case unsupportedFormat(String)
    case authenticationFailed
    case encodingFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .missingKey:
            "声纹档案密钥缺失，无法解密。"
        case .unsupportedFormat(let format):
            "不支持的声纹档案加密格式：\(format)"
        case .authenticationFailed:
            "声纹档案密文校验失败（密钥错误或内容被篡改）。"
        case .encodingFailed:
            "声纹档案编码失败。"
        case .decodingFailed:
            "声纹档案解码失败。"
        }
    }
}

nonisolated enum VoiceprintArchiveCrypto {
    /// Encrypts archive JSON with AES-GCM. Wrong keys / tampering fail on decrypt.
    static func seal(
        _ archive: VoiceprintArchive,
        using key: SymmetricKey
    ) throws -> EncryptedVoiceprintEnvelope {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext: Data
        do {
            plaintext = try encoder.encode(archive)
        } catch {
            throw VoiceprintArchiveCryptoError.encodingFailed
        }
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else {
                throw VoiceprintArchiveCryptoError.encodingFailed
            }
            return EncryptedVoiceprintEnvelope(sealedBox: combined)
        } catch let error as VoiceprintArchiveCryptoError {
            throw error
        } catch {
            throw VoiceprintArchiveCryptoError.encodingFailed
        }
    }

    static func open(
        _ envelope: EncryptedVoiceprintEnvelope,
        using key: SymmetricKey
    ) throws -> VoiceprintArchive {
        guard envelope.format == EncryptedVoiceprintEnvelope.currentFormat else {
            throw VoiceprintArchiveCryptoError.unsupportedFormat(envelope.format)
        }
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealedBox)
            plaintext = try AES.GCM.open(box, using: key)
        } catch {
            throw VoiceprintArchiveCryptoError.authenticationFailed
        }
        do {
            return try JSONDecoder().decode(VoiceprintArchive.self, from: plaintext)
        } catch {
            throw VoiceprintArchiveCryptoError.decodingFailed
        }
    }

    static func encodeEnvelope(_ envelope: EncryptedVoiceprintEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(envelope)
        } catch {
            throw VoiceprintArchiveCryptoError.encodingFailed
        }
    }

    static func decodeEnvelope(from data: Data) throws -> EncryptedVoiceprintEnvelope {
        do {
            return try JSONDecoder().decode(EncryptedVoiceprintEnvelope.self, from: data)
        } catch {
            throw VoiceprintArchiveCryptoError.decodingFailed
        }
    }

    /// True when `data` looks like a legacy plaintext archive JSON object.
    static func looksLikeLegacyPlaintextArchive(_ data: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object.keys.contains("identities")
        else {
            return false
        }
        return true
    }
}
