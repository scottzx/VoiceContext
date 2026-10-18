import Foundation
import AVFoundation
import Combine

nonisolated struct StoryAudio: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let fileName: String
    let duration: TimeInterval
}

nonisolated enum StoryLibraryError: LocalizedError {
    case invalidAudio, invalidLibrary, missingStory
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidAudio: return "无法读取此音频，请选择可播放的音频文件。"
        case .invalidLibrary: return "故事库资料已损坏，原有文件已保留，暂时无法修改。"
        case .missingStory: return "故事已删除或音频文件不存在，请重新导入。"
        case .unavailable(let message): return message
        }
    }
}

@MainActor
final class StoryLibraryStore: ObservableObject {
    static let shared = StoryLibraryStore()
    @Published private(set) var stories: [StoryAudio] = []
    @Published private(set) var loadError: String?
    private let directory: URL
    private let fileManager = FileManager.default
    private var libraryURL: URL { directory.appendingPathComponent("library.json") }

    init(directory: URL? = nil) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? root.appendingPathComponent("Yima/story-player", isDirectory: true)
        do {
            guard try fileManager.attributesOfItem(atPath: libraryURL.path)[.type] as? FileAttributeType == .typeRegular else {
                throw StoryLibraryError.invalidLibrary
            }
            let loaded = try JSONDecoder().decode([StoryAudio].self, from: Data(contentsOf: libraryURL))
            guard Set(loaded.map(\.id)).count == loaded.count,
                  loaded.allSatisfy(Self.isValid) else { throw StoryLibraryError.invalidLibrary }
            stories = loaded
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A new installation starts with an empty library.
        } catch {
            loadError = StoryLibraryError.invalidLibrary.localizedDescription
        }
    }

    /// Called while unlocked, before enabling background voice playback.
    /// Validate every owned path before changing any file's protection.
    func prepareForBackgroundPlayback() throws {
        try requireAvailable()
        try prepareDirectory()
        var urls = [directory]
        do {
            guard try fileManager.attributesOfItem(atPath: libraryURL.path)[.type] as? FileAttributeType == .typeRegular else {
                throw StoryLibraryError.invalidLibrary
            }
            urls.append(libraryURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            guard stories.isEmpty else { throw StoryLibraryError.invalidLibrary }
        }
        for story in stories { urls.append(try audioURL(for: story)) }
        for url in urls { try setBackgroundProtection(for: url) }
    }

    @discardableResult
    func importAudio(from url: URL) throws -> StoryAudio {
        try requireAvailable()
        guard url.isFileURL else { throw StoryLibraryError.invalidAudio }
        guard try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
            throw StoryLibraryError.invalidAudio
        }
        let id = UUID()
        let suffix = url.pathExtension.lowercased()
        let fileExtension = Self.isSafeExtension(suffix) ? suffix : "audio"
        let destination = directory.appendingPathComponent(id.uuidString + "." + fileExtension)
        try prepareDirectory()
        try setBackgroundProtection(for: directory)
        do {
            try fileManager.copyItem(at: url, to: destination)
            try validateAudioFile(destination)
            try setBackgroundProtection(for: destination)
            let audio = try AVAudioPlayer(contentsOf: destination)
            guard audio.duration.isFinite, audio.duration > 0 else { throw StoryLibraryError.invalidAudio }
            let title = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            let story = StoryAudio(id: id, title: title.isEmpty ? "未命名故事" : title,
                                   fileName: destination.lastPathComponent, duration: audio.duration)
            let updated = stories + [story]
            try persist(updated)
            stories = updated
            return story
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    func remove(_ id: UUID) throws {
        try requireAvailable()
        guard let story = stories.first(where: { $0.id == id }) else { throw StoryLibraryError.missingStory }
        let source = directory.appendingPathComponent(story.fileName)
        // Stage the file beside its original so a failed manifest write can restore it.
        let staged = directory.appendingPathComponent(".deleting-" + id.uuidString)
        let exists = fileManager.fileExists(atPath: source.path)
        if exists {
            try validateAudioFile(source)
            try fileManager.moveItem(at: source, to: staged)
        }
        let updated = stories.filter { $0.id != id }
        do {
            try persist(updated)
        } catch {
            if exists {
                do { try fileManager.moveItem(at: staged, to: source) }
                catch { loadError = "音频删除未完成，原有音频已保留，请重新打开故事机。" }
            }
            throw error
        }
        stories = updated
        if exists { try? fileManager.removeItem(at: staged) }
    }

    func audioURL(for story: StoryAudio) throws -> URL {
        try requireAvailable()
        guard stories.contains(story), Self.isValid(story) else { throw StoryLibraryError.missingStory }
        let url = directory.appendingPathComponent(story.fileName)
        try validateAudioFile(url)
        return url
    }

    private func requireAvailable() throws {
        if let loadError { throw StoryLibraryError.unavailable(loadError) }
    }

    private func prepareDirectory() throws {
        do {
            guard try fileManager.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw StoryLibraryError.invalidLibrary
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func setBackgroundProtection(for url: URL) throws {
        #if os(iOS)
        do {
            try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                          ofItemAtPath: url.path)
        } catch {
            throw StoryLibraryError.unavailable("故事音频暂时无法准备锁屏播放，请解锁后重试：\(error.localizedDescription)")
        }
        #endif
    }

    private func validateAudioFile(_ url: URL) throws {
        guard try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular,
              url.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.resolvingSymlinksInPath().path else {
            throw StoryLibraryError.invalidAudio
        }
    }

    private func persist(_ updated: [StoryAudio]) throws {
        do {
            guard try fileManager.attributesOfItem(atPath: libraryURL.path)[.type] as? FileAttributeType == .typeRegular else {
                throw StoryLibraryError.invalidLibrary
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // The first import creates the manifest.
        }
        var options: Data.WritingOptions = .atomic
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(updated).write(to: libraryURL, options: options)
    }

    private static func isValid(_ story: StoryAudio) -> Bool {
        let file = URL(fileURLWithPath: story.fileName)
        return !story.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            story.duration.isFinite && story.duration > 0 &&
            !story.fileName.contains("/") && !story.fileName.contains("\\") &&
            file.deletingPathExtension().lastPathComponent == story.id.uuidString &&
            isSafeExtension(file.pathExtension)
    }

    private static func isSafeExtension(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 16 && value.unicodeScalars.allSatisfy {
            (97...122).contains($0.value) || (48...57).contains($0.value)
        }
    }
}
