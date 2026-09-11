import Foundation

/// Coordinated atomic replace helpers for local Documents and iCloud Drive roots.
/// Staging siblings use a leading-dot `.….writing` name so Finder/Codex walks that
/// skip hidden files never surface half-written bytes under the canonical path.
nonisolated enum PublicDocumentFileIO {
    enum FileIOError: LocalizedError, Equatable {
        case coordinationFailed(String)
        case escapedRoot(String)
        case insufficientSpace
        case networkInterrupted
        case incompleteStaging(String)

        var errorDescription: String? {
            switch self {
            case .coordinationFailed(let message):
                "公开文档写入协调失败：\(message)"
            case .escapedRoot(let path):
                "公开文档路径越界：\(path)"
            case .insufficientSpace:
                "存储空间不足，无法完成公开文档写入。"
            case .networkInterrupted:
                "同步网络中断，公开文档写入未完成。"
            case .incompleteStaging(let path):
                "拒绝读取未完成的暂存文件：\(path)"
            }
        }
    }

    static func resolveURL(rootURL: URL, relativePath: String) throws -> URL {
        let url = rootURL.appendingPathComponent(relativePath)
        let root = rootURL.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate == root || candidate.hasPrefix(root + "/") else {
            throw FileIOError.escapedRoot(relativePath)
        }
        return url
    }

    /// True for in-progress atomic staging names (`.\(name).<uuid>.writing`).
    static func isStagingFileName(_ name: String) -> Bool {
        let base = (name as NSString).lastPathComponent
        if base.hasPrefix("."), base.contains(".writing") { return true }
        if base.hasSuffix(".writing") { return true }
        return false
    }

    /// Codex / Finder consumers should only open completed canonical documents.
    static func isCompletedDocumentURL(_ url: URL) -> Bool {
        !isStagingFileName(url.lastPathComponent)
    }

    /// Reads bytes only from a completed (non-staging) document URL.
    static func readCompletedData(at url: URL) throws -> Data {
        guard isCompletedDocumentURL(url) else {
            throw FileIOError.incompleteStaging(url.lastPathComponent)
        }
        return try Data(contentsOf: url)
    }

    /// Writes via a temporary sibling then `replaceItem`, inside `NSFileCoordinator`.
    static func writeAtomically(
        _ data: Data,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var coordinationError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: destination,
            options: [.forReplacing],
            error: &coordinationError
        ) { coordinatedDestination in
            do {
                let staging = coordinatedDestination
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        ".\(coordinatedDestination.lastPathComponent).\(UUID().uuidString).writing"
                    )
                if fileManager.fileExists(atPath: staging.path) {
                    try fileManager.removeItem(at: staging)
                }
                do {
                    try data.write(to: staging, options: .atomic)
                } catch {
                    try? fileManager.removeItem(at: staging)
                    throw mapWriteError(error)
                }

                do {
                    if fileManager.fileExists(atPath: coordinatedDestination.path) {
                        _ = try fileManager.replaceItemAt(
                            coordinatedDestination,
                            withItemAt: staging,
                            backupItemName: nil,
                            options: [.usingNewMetadataOnly]
                        )
                    } else {
                        try fileManager.moveItem(at: staging, to: coordinatedDestination)
                    }
                } catch {
                    try? fileManager.removeItem(at: staging)
                    throw mapWriteError(error)
                }
            } catch {
                writeError = error
            }
        }
        if let coordinationError {
            throw FileIOError.coordinationFailed(coordinationError.localizedDescription)
        }
        if let writeError {
            throw mapWriteError(writeError)
        }
    }

    /// Copies an existing local file into the destination root with coordination.
    static func copyAtomically(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        let data = try Data(contentsOf: source)
        try writeAtomically(data, to: destination, fileManager: fileManager)
    }

    /// Preserves a divergent destination as a conflict sibling before replace.
    @discardableResult
    static func preserveConflictCopyIfNeeded(
        of destination: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> URL? {
        guard fileManager.fileExists(atPath: destination.path) else { return nil }
        let conflictURL = conflictSiblingURL(for: destination, now: now)
        if fileManager.fileExists(atPath: conflictURL.path) {
            try fileManager.removeItem(at: conflictURL)
        }
        try fileManager.copyItem(at: destination, to: conflictURL)
        return conflictURL
    }

    static func conflictSiblingURL(for destination: URL, now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: now)
        let base = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        let conflictName: String
        if ext.isEmpty {
            conflictName = "\(base) (conflict \(stamp))"
        } else {
            conflictName = "\(base) (conflict \(stamp)).\(ext)"
        }
        return destination.deletingLastPathComponent().appendingPathComponent(conflictName)
    }

    /// Reads an integer `revision` field from a JSON object when present.
    static func revision(inJSONAt url: URL) -> Int? {
        guard isCompletedDocumentURL(url),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let value = object["revision"] as? Int { return value }
        if let number = object["revision"] as? NSNumber { return number.intValue }
        return nil
    }

    static func mapWriteError(_ error: Error) -> Error {
        if error is FileIOError { return error }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
            return FileIOError.insufficientSpace
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) {
            return FileIOError.insufficientSpace
        }
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorTimedOut:
                return FileIOError.networkInterrupted
            default:
                break
            }
        }
        return error
    }
}
