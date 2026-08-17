import Foundation

/// Minimal ZIP reader for archives written with ZIP_STORED (no compression).
/// Used to unpack VoiceContextPack.zip while preserving nested Skill/Templates paths.
enum StoredZipExtractor {
    enum ExtractError: LocalizedError, Equatable {
        case unreadableArchive
        case unsupportedCompression(UInt16)
        case truncatedArchive
        case unsafeEntry(String)

        var errorDescription: String? {
            switch self {
            case .unreadableArchive:
                "无法读取 VoiceContextPack.zip。"
            case .unsupportedCompression(let method):
                "VoiceContextPack.zip 含不支持的压缩方式：\(method)"
            case .truncatedArchive:
                "VoiceContextPack.zip 已损坏或截断。"
            case .unsafeEntry(let name):
                "VoiceContextPack.zip 含非法路径：\(name)"
            }
        }
    }

    static func extract(zipURL: URL, to destination: URL, fileManager: FileManager = .default) throws {
        let data = try Data(contentsOf: zipURL)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        var offset = 0
        while offset + 30 <= data.count {
            let sig = readUInt32(data, offset)
            if sig == 0x02014b50 || sig == 0x06054b50 {
                break // central directory / end
            }
            guard sig == 0x04034b50 else {
                throw ExtractError.unreadableArchive
            }
            guard offset + 30 <= data.count else { throw ExtractError.truncatedArchive }
            let compression = readUInt16(data, offset + 8)
            let compSize = Int(readUInt32(data, offset + 18))
            let nameLen = Int(readUInt16(data, offset + 26))
            let extraLen = Int(readUInt16(data, offset + 28))
            let nameStart = offset + 30
            let nameEnd = nameStart + nameLen
            guard nameEnd + extraLen + compSize <= data.count else {
                throw ExtractError.truncatedArchive
            }
            guard let name = String(data: data.subdata(in: nameStart..<nameEnd), encoding: .utf8),
                  !name.isEmpty else {
                throw ExtractError.unreadableArchive
            }
            if name.contains("..") || name.hasPrefix("/") {
                throw ExtractError.unsafeEntry(name)
            }
            let dataStart = nameEnd + extraLen
            let dataEnd = dataStart + compSize
            let entryURL = destination.appendingPathComponent(name)
            if name.hasSuffix("/") {
                try fileManager.createDirectory(at: entryURL, withIntermediateDirectories: true)
            } else {
                guard compression == 0 else {
                    throw ExtractError.unsupportedCompression(compression)
                }
                try fileManager.createDirectory(
                    at: entryURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.subdata(in: dataStart..<dataEnd).write(to: entryURL, options: .atomic)
            }
            offset = dataEnd
        }
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
