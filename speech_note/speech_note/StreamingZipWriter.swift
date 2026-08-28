import Foundation

nonisolated enum ExportPackagePreferences {
    static let includesOriginalAudioKey = "exportPackageIncludesOriginalAudio"

    static var includesOriginalAudio: Bool {
        UserDefaults.standard.bool(forKey: includesOriginalAudioKey)
    }
}

nonisolated enum StreamingZipWriter {
    struct Entry: Sendable {
        let sourceURL: URL
        let archivePath: String
    }

    enum ZipError: LocalizedError {
        case fileTooLarge(String)
        case archiveTooLarge

        var errorDescription: String? {
            switch self {
            case let .fileTooLarge(name): "文件过大，当前资料包不支持：\(name)"
            case .archiveTooLarge: "资料包过大，无法生成标准 ZIP"
            }
        }
    }

    private struct CentralEntry {
        let pathData: Data
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
    }

    static func write(entries: [Entry], to outputURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: outputURL)
        fileManager.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        var offset: UInt64 = 0
        var centralEntries: [CentralEntry] = []
        for entry in entries {
            try Task.checkCancellation()
            let attributes = try fileManager.attributesOfItem(atPath: entry.sourceURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard fileSize <= UInt64(UInt32.max) else {
                throw ZipError.fileTooLarge(entry.archivePath)
            }
            guard offset <= UInt64(UInt32.max) else { throw ZipError.archiveTooLarge }
            let pathData = Data(safeArchivePath(entry.archivePath).utf8)
            let checksum = try checksum(of: entry.sourceURL)
            let (dosTime, dosDate) = dosTimestamp(
                attributes[.modificationDate] as? Date ?? Date()
            )
            var localHeader = Data()
            localHeader.appendLE(UInt32(0x04034b50))
            localHeader.appendLE(UInt16(20))
            localHeader.appendLE(UInt16(0))
            localHeader.appendLE(UInt16(0))
            localHeader.appendLE(dosTime)
            localHeader.appendLE(dosDate)
            localHeader.appendLE(checksum.crc32)
            localHeader.appendLE(checksum.size)
            localHeader.appendLE(checksum.size)
            localHeader.appendLE(UInt16(pathData.count))
            localHeader.appendLE(UInt16(0))
            localHeader.append(pathData)
            try output.write(contentsOf: localHeader)
            let localOffset = UInt32(offset)
            offset += UInt64(localHeader.count)

            let input = try FileHandle(forReadingFrom: entry.sourceURL)
            defer { try? input.close() }
            var written: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: 256 * 1024) ?? Data()
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
                written += UInt64(chunk.count)
                offset += UInt64(chunk.count)
            }
            guard written <= UInt64(UInt32.max) else {
                throw ZipError.fileTooLarge(entry.archivePath)
            }
            guard UInt32(written) == checksum.size else {
                throw CocoaError(.fileReadUnknown)
            }
            centralEntries.append(CentralEntry(
                pathData: pathData,
                crc32: checksum.crc32,
                size: checksum.size,
                localHeaderOffset: localOffset,
                dosTime: dosTime,
                dosDate: dosDate
            ))
        }

        guard offset <= UInt64(UInt32.max), centralEntries.count <= Int(UInt16.max) else {
            throw ZipError.archiveTooLarge
        }
        let centralOffset = UInt32(offset)
        for entry in centralEntries {
            var header = Data()
            header.appendLE(UInt32(0x02014b50))
            header.appendLE(UInt16(20))
            header.appendLE(UInt16(20))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(entry.dosTime)
            header.appendLE(entry.dosDate)
            header.appendLE(entry.crc32)
            header.appendLE(entry.size)
            header.appendLE(entry.size)
            header.appendLE(UInt16(entry.pathData.count))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt32(0))
            header.appendLE(entry.localHeaderOffset)
            header.append(entry.pathData)
            try output.write(contentsOf: header)
            offset += UInt64(header.count)
        }
        guard offset <= UInt64(UInt32.max) else { throw ZipError.archiveTooLarge }
        let centralSize = UInt32(offset) - centralOffset
        var end = Data()
        end.appendLE(UInt32(0x06054b50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(centralEntries.count))
        end.appendLE(UInt16(centralEntries.count))
        end.appendLE(centralSize)
        end.appendLE(centralOffset)
        end.appendLE(UInt16(0))
        try output.write(contentsOf: end)
        try output.synchronize()
    }

    static func safeArchivePath(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .filter { $0 != "." && $0 != ".." }
            .map { $0.replacingOccurrences(of: ":", with: "-") }
            .joined(separator: "/")
    }

    private static func checksum(of url: URL) throws -> (crc32: UInt32, size: UInt32) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var crc = UInt32.max
        var size: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            crc = CRC32.update(crc, with: chunk)
            size += UInt64(chunk.count)
        }
        guard size <= UInt64(UInt32.max) else {
            throw ZipError.fileTooLarge(url.lastPathComponent)
        }
        return (crc ^ UInt32.max, UInt32(size))
    }

    private static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: .current,
            from: date
        )
        let year = min(max((components.year ?? 1980) - 1980, 0), 127)
        let month = min(max(components.month ?? 1, 1), 12)
        let day = min(max(components.day ?? 1, 1), 31)
        let hour = min(max(components.hour ?? 0, 0), 23)
        let minute = min(max(components.minute ?? 0, 0), 59)
        let second = min(max(components.second ?? 0, 0), 59) / 2
        return (
            UInt16((hour << 11) | (minute << 5) | second),
            UInt16((year << 9) | (month << 5) | day)
        )
    }
}

private nonisolated enum CRC32 {
    static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1
        }
        return crc
    }

    static func update(_ initial: UInt32, with data: Data) -> UInt32 {
        var crc = initial
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ table[index]
        }
        return crc
    }
}

private nonisolated extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
