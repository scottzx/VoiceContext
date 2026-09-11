import Foundation

nonisolated final class RecordingJournal: @unchecked Sendable {
    nonisolated enum JournalError: LocalizedError {
        case corruptEvent(line: Int, underlying: Error)

        var errorDescription: String? {
            switch self {
            case let .corruptEvent(line, underlying):
                "录音 journal 第 \(line) 行损坏：\(underlying.localizedDescription)"
            }
        }
    }

    let url: URL

    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(url: URL) throws {
        self.url = url
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    func append(_ event: RecordingJournalEvent) throws {
        lock.lock()
        defer { lock.unlock() }

        var data = try encoder.encode(event)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    func events() throws -> [RecordingJournalEvent] {
        lock.lock()
        defer { lock.unlock() }

        let data = try Data(contentsOf: url)
        let hasTerminatingNewline = data.last == 0x0A
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var result: [RecordingJournalEvent] = []
        result.reserveCapacity(lines.count)

        for (offset, line) in lines.enumerated() {
            do {
                result.append(try decoder.decode(RecordingJournalEvent.self, from: Data(line)))
            } catch {
                let isCrashTruncatedTail = offset == lines.count - 1 && !hasTerminatingNewline
                if isCrashTruncatedTail {
                    break
                }
                throw JournalError.corruptEvent(line: offset + 1, underlying: error)
            }
        }
        return result
    }
}
