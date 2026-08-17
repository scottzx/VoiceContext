import Foundation
import Testing
@testable import speech_note

struct PublicSkillPackTests {
    @Test func seederCopiesSkillAndDefaultTemplateWithoutOverwritingCustom() async throws {
        let root = temporaryDirectory()
        let pack = temporaryDirectory("VoiceContextPackSource")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: pack)
        }

        let skillSrc = pack
            .appendingPathComponent("Skill/generate-meeting-minutes", isDirectory: true)
        try FileManager.default.createDirectory(at: skillSrc, withIntermediateDirectories: true)
        try Data("# skill\n".utf8).write(to: skillSrc.appendingPathComponent("SKILL.md"))
        try FileManager.default.createDirectory(
            at: skillSrc.appendingPathComponent("scripts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("print('ok')\n".utf8).write(
            to: skillSrc.appendingPathComponent("scripts/generate_minutes.py")
        )

        let templatesSrc = pack.appendingPathComponent("Templates", isDirectory: true)
        try FileManager.default.createDirectory(at: templatesSrc, withIntermediateDirectories: true)
        try Data("# default\n".utf8).write(
            to: templatesSrc.appendingPathComponent("default-meeting-minutes.md")
        )
        try Data("# bundled-extra\n".utf8).write(
            to: templatesSrc.appendingPathComponent("bundled-extra.md")
        )

        // Pre-existing user custom template must survive.
        let templatesDest = root.appendingPathComponent("Templates", isDirectory: true)
        try FileManager.default.createDirectory(at: templatesDest, withIntermediateDirectories: true)
        try Data("# mine\n".utf8).write(to: templatesDest.appendingPathComponent("my-custom.md"))
        try Data("# user-edited-default\n".utf8).write(
            to: templatesDest.appendingPathComponent("default-meeting-minutes.md")
        )

        let seeder = PublicSkillPackSeeder(
            rootURL: root,
            configuration: .init(
                packRootURL: pack,
                isDocumentSyncEnabled: { false },
                ubiquityDocumentsURL: { nil }
            )
        )
        let result = try await seeder.seed()

        #expect(result.skillRelativePath == "Skill/generate-meeting-minutes")
        #expect(result.templatesRelativePath == "Templates")
        #expect(result.preservedUserTemplateCount == 1)
        #expect(result.iCloudMirror?.destination == .localOnly)

        let skillMD = root.appendingPathComponent("Skill/generate-meeting-minutes/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: skillMD.path))
        #expect(try String(contentsOf: skillMD, encoding: .utf8).contains("# skill"))

        let defaultTemplate = try String(
            contentsOf: templatesDest.appendingPathComponent("default-meeting-minutes.md"),
            encoding: .utf8
        )
        #expect(defaultTemplate.contains("user-edited-default"))

        let custom = try String(
            contentsOf: templatesDest.appendingPathComponent("my-custom.md"),
            encoding: .utf8
        )
        #expect(custom.contains("# mine"))

        let bundledExtra = templatesDest.appendingPathComponent("bundled-extra.md")
        #expect(FileManager.default.fileExists(atPath: bundledExtra.path))
    }

    @Test func seederMirrorsSkillTemplatesWhenUbiquityAvailable() async throws {
        let root = temporaryDirectory()
        let pack = temporaryDirectory("VoiceContextPackMirror")
        let iCloud = temporaryDirectory("VoiceContextiCloud")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: pack)
            try? FileManager.default.removeItem(at: iCloud)
        }

        let skillSrc = pack.appendingPathComponent("Skill/generate-meeting-minutes", isDirectory: true)
        try FileManager.default.createDirectory(at: skillSrc, withIntermediateDirectories: true)
        try Data("name: generate-meeting-minutes\n".utf8).write(
            to: skillSrc.appendingPathComponent("SKILL.md")
        )
        let templatesSrc = pack.appendingPathComponent("Templates", isDirectory: true)
        try FileManager.default.createDirectory(at: templatesSrc, withIntermediateDirectories: true)
        try Data("default\n".utf8).write(
            to: templatesSrc.appendingPathComponent("default-meeting-minutes.md")
        )

        let seeder = PublicSkillPackSeeder(
            rootURL: root,
            configuration: .init(
                packRootURL: pack,
                isDocumentSyncEnabled: { true },
                ubiquityDocumentsURL: { iCloud }
            )
        )
        let result = try await seeder.seed()
        #expect(result.iCloudMirror?.destination == .iCloud)
        #expect(
            FileManager.default.fileExists(
                atPath: iCloud.appendingPathComponent("Skill/generate-meeting-minutes/SKILL.md").path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: iCloud.appendingPathComponent("Templates/default-meeting-minutes.md").path
            )
        )
        #expect(PublicDocumentContainer.isAllowedPublicRelativePath("Skill/generate-meeting-minutes"))
        #expect(PublicDocumentContainer.isAllowedPublicRelativePath("Templates/default-meeting-minutes.md"))
    }

    @Test func allowlistAcceptsSkillAndTemplatesRoots() {
        #expect(PublicDocumentContainer.isAllowedPublicRelativePath("Skill/generate-meeting-minutes/SKILL.md"))
        #expect(PublicDocumentContainer.isAllowedPublicRelativePath("Templates/default-meeting-minutes.md"))
        #expect(PublicDocumentLayout.skillRoot == "Skill")
        #expect(PublicDocumentLayout.templatesRoot == "Templates")
    }

    private func temporaryDirectory(_ prefix: String = "PublicSkillPackTests") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
