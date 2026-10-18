import Foundation

@main
struct StoryLibraryChecks {
    @MainActor
    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("yima-story-library-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let source = root.appendingPathComponent("小兔子的故事.wav")
        try wave().write(to: source)
        let directory = root.appendingPathComponent("library", isDirectory: true)
        let store = StoryLibraryStore(directory: directory)
        check(store.stories.isEmpty && store.loadError == nil, "new library")
        try store.prepareForBackgroundPlayback()
        check(files.fileExists(atPath: directory.path) && !files.fileExists(atPath: directory.appendingPathComponent("library.json").path),
              "empty background preparation does not invent a manifest")
        let first = try store.importAudio(from: source)
        let copied = try store.audioURL(for: first)
        check(first.title == "小兔子的故事" && abs(first.duration - 0.25) < 0.001, "decoded title and duration")
        let originalData = try Data(contentsOf: source)
        let copiedData = try Data(contentsOf: copied)
        check(copied != source && copiedData == originalData, "owns an audio copy")
        check(StoryLibraryStore(directory: directory).stories == [first], "stable IDs after reload")
        let second = try store.importAudio(from: source)
        check(second.id != first.id && store.stories.count == 2, "same title keeps distinct IDs")
        let manifestBeforePreparation = try Data(contentsOf: directory.appendingPathComponent("library.json"))
        try store.prepareForBackgroundPlayback()
        check(try Data(contentsOf: directory.appendingPathComponent("library.json")) == manifestBeforePreparation,
              "background preparation preserves manifest content")
        check(try Data(contentsOf: copied) == copiedData && Data(contentsOf: source) == originalData,
              "background preparation preserves imported and external audio bytes")
        let directoryAlias = root.appendingPathComponent("library-alias", isDirectory: true)
        try files.createSymbolicLink(at: directoryAlias, withDestinationURL: directory)
        let aliased = StoryLibraryStore(directory: directoryAlias)
        rejects("background preparation through directory symlink") { try aliased.prepareForBackgroundPlayback() }
        rejects("import through directory symlink") { _ = try aliased.importAudio(from: source) }

        let invalid = root.appendingPathComponent("broken.mp3")
        try Data("not an audio file".utf8).write(to: invalid)
        let before = try contents(directory)
        rejects("invalid audio") { _ = try store.importAudio(from: invalid) }
        check(try contents(directory) == before, "invalid audio leaves no orphan")
        rejects("directory import") { _ = try store.importAudio(from: root) }
        check(try contents(directory) == before, "directory import leaves no orphan")
        rejects("remote URL") { _ = try store.importAudio(from: URL(string: "https://example.com/a.mp3")!) }

        let forged = StoryAudio(id: first.id, title: first.title, fileName: "../outside.wav", duration: first.duration)
        rejects("forged audio path") { _ = try store.audioURL(for: forged) }
        try files.removeItem(at: copied)
        try files.createSymbolicLink(at: copied, withDestinationURL: source)
        rejects("symlink audio path") { _ = try store.audioURL(for: first) }
        rejects("background preparation with symlink audio") { try store.prepareForBackgroundPlayback() }
        try files.removeItem(at: copied)
        try files.copyItem(at: source, to: copied)

        let manifest = directory.appendingPathComponent("library.json")
        let saved = try Data(contentsOf: manifest)
        try files.removeItem(at: manifest)
        try files.createDirectory(at: manifest, withIntermediateDirectories: false)
        let blockedContents = try contents(directory)
        rejects("import manifest write failure") { _ = try store.importAudio(from: source) }
        let failedImportContents = try contents(directory)
        check(store.stories == [first, second] && failedImportContents == blockedContents, "failed import preserves memory and files")
        rejects("delete manifest write failure") { try store.remove(first.id) }
        rejects("background preparation with invalid manifest") { try store.prepareForBackgroundPlayback() }
        check(store.stories == [first, second] && files.fileExists(atPath: copied.path), "failed deletion restores audio and memory")
        check(try contents(directory) == blockedContents, "failed deletion leaves no staging file")
        try files.removeItem(at: manifest)
        try saved.write(to: manifest)
        try store.remove(first.id)
        check(!files.fileExists(atPath: copied.path) && files.fileExists(atPath: source.path), "deletion removes only owned audio")
        check(StoryLibraryStore(directory: directory).stories == [second], "deletion survives reload")
        try files.removeItem(at: store.audioURL(for: second))
        rejects("background preparation with missing audio") { try store.prepareForBackgroundPlayback() }
        try store.remove(second.id)
        check(store.stories.isEmpty && StoryLibraryStore(directory: directory).stories.isEmpty, "missing audio can be removed")

        let malformed = Data("{ broken library".utf8)
        try malformed.write(to: manifest)
        let damaged = StoryLibraryStore(directory: directory)
        check(damaged.loadError != nil && damaged.stories.isEmpty, "malformed library reports error")
        rejects("malformed library import") { _ = try damaged.importAudio(from: source) }
        rejects("malformed library background preparation") { try damaged.prepareForBackgroundPlayback() }
        check(try Data(contentsOf: manifest) == malformed, "malformed library stays intact")

        try JSONEncoder().encode([forged]).write(to: manifest)
        check(StoryLibraryStore(directory: directory).loadError != nil, "persisted traversal is rejected")
        try JSONEncoder().encode([first, first]).write(to: manifest)
        check(StoryLibraryStore(directory: directory).loadError != nil, "duplicate IDs are rejected")
        try files.removeItem(at: manifest)
        try files.createSymbolicLink(at: manifest, withDestinationURL: root.appendingPathComponent("absent.json"))
        check(StoryLibraryStore(directory: directory).loadError != nil, "dangling manifest symlink is rejected")
        rejects("manifest symlink write") { _ = try store.importAudio(from: source) }
        rejects("manifest symlink background preparation") { try store.prepareForBackgroundPlayback() }
        check(try files.attributesOfItem(atPath: manifest.path)[.type] as? FileAttributeType == .typeSymbolicLink, "manifest symlink stays intact")
        print("Story library: import, decode, persistence, deletion, corruption, path safety and write rollback checks passed")
        print("Story library: background preparation preserves content and rejects missing, corrupt or symlink paths; iOS protection attributes require device verification")
    }

    static func check(_ condition: Bool, _ label: String) {
        precondition(condition, label)
    }

    static func rejects(_ label: String, action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected rejection: " + label) }
        catch {}
    }

    static func contents(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    static func wave() -> Data {
        let count: UInt32 = 2_000
        var result = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
        append(UInt32(36) + count * 2)
        result.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(8_000))
        append(UInt32(16_000)); append(UInt16(2)); append(UInt16(16))
        result.append(contentsOf: "data".utf8)
        append(count * 2)
        result.append(Data(repeating: 0, count: Int(count * 2)))
        return result
    }
}
