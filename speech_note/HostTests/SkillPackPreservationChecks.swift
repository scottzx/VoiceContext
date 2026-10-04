import Foundation

@main
struct SkillPackPreservationChecks {
    static let manager = FileManager.default
    static let skill = "Skill/generate-meeting-minutes"

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "SkillPreservation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func write(_ text: String, _ relative: String, under root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func read(_ relative: String, under root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    static func pack(under root: URL) throws -> URL {
        let pack = root.appendingPathComponent("pack")
        try write("bundled skill", "\(skill)/SKILL.md", under: pack)
        try write("bundled script", "\(skill)/scripts/generate_minutes.py", under: pack)
        try write("new helper", "\(skill)/scripts/new-helper.txt", under: pack)
        try write("bundled default", "Templates/default-meeting-minutes.md", under: pack)
        try write("bundled extra", "Templates/bundled-extra.md", under: pack)
        return pack
    }

    static func seed(_ local: URL, pack: URL, cloud: URL? = nil) async throws -> PublicSkillPackSeedResult {
        try await PublicSkillPackSeeder(
            rootURL: local,
            configuration: .init(packRootURL: pack, isDocumentSyncEnabled: { cloud != nil }, ubiquityDocumentsURL: { cloud })
        ).seed()
    }

    static func localPreservation(_ root: URL) async throws {
        let pack = try pack(under: root)
        let local = root.appendingPathComponent("local")
        try write("edited skill", "\(skill)/SKILL.md", under: local)
        try write("edited script", "\(skill)/scripts/generate_minutes.py", under: local)
        try write("user tool", "\(skill)/scripts/user.py", under: local)
        try write("edited default", "Templates/default-meeting-minutes.md", under: local)
        try write("edited extra", "Templates/bundled-extra.md", under: local)
        try write("custom", "Templates/custom.md", under: local)
        let first = try await seed(local, pack: pack)
        try require(try read("\(skill)/SKILL.md", under: local) == "edited skill", "Existing Skill was overwritten")
        try require(try read("\(skill)/scripts/generate_minutes.py", under: local) == "edited script", "Existing script was overwritten")
        try require(try read("\(skill)/scripts/user.py", under: local) == "user tool", "User tool was deleted")
        try require(try read("Templates/default-meeting-minutes.md", under: local) == "edited default", "Default template was overwritten")
        try require(try read("Templates/bundled-extra.md", under: local) == "edited extra", "Extra template was overwritten")
        try require(try read("Templates/custom.md", under: local) == "custom", "Custom template was deleted")
        try require(try read("\(skill)/scripts/new-helper.txt", under: local) == "new helper", "Missing bundle file was not added")
        try require(first.copiedFileCount == 1, "Expected only one missing file copied")
        let second = try await seed(local, pack: pack)
        try require(second.copiedFileCount == 0, "Repeated installation copied existing files")
        try write("updated bundle", "\(skill)/SKILL.md", under: pack)
        let third = try await seed(local, pack: pack)
        try require(third.copiedFileCount == 0, "Bundle upgrade overwrote an existing Skill")
        try require(try read("\(skill)/SKILL.md", under: local) == "edited skill", "Bundle upgrade lost edits")
        print("PASS local preservation / repeat install / changed bundle")
    }

    static func cloudPreservation(_ root: URL) async throws {
        let pack = try pack(under: root)
        let local = root.appendingPathComponent("local")
        let cloud = root.appendingPathComponent("cloud")
        try write("cloud edited skill", "\(skill)/SKILL.md", under: cloud)
        try write("cloud tool", "\(skill)/scripts/cloud.py", under: cloud)
        try write("cloud default", "Templates/default-meeting-minutes.md", under: cloud)
        try write("cloud custom", "Templates/cloud-custom.md", under: cloud)
        let first = try await seed(local, pack: pack, cloud: cloud)
        try require(try read("\(skill)/SKILL.md", under: cloud) == "cloud edited skill", "Cloud Skill was overwritten")
        try require(try read("\(skill)/scripts/cloud.py", under: cloud) == "cloud tool", "Cloud-only tool was removed")
        try require(try read("Templates/default-meeting-minutes.md", under: cloud) == "cloud default", "Cloud template was overwritten")
        try require(try read("Templates/cloud-custom.md", under: cloud) == "cloud custom", "Cloud-only template was removed")
        try require(try read("\(skill)/scripts/new-helper.txt", under: cloud) == "new helper", "Missing cloud file was not added")
        try require(try read("Templates/bundled-extra.md", under: cloud) == "bundled extra", "Missing cloud template was not added")
        try require(first.iCloudMirror?.destination == .iCloud, "Injected mirror was not used")
        let second = try await seed(local, pack: pack, cloud: cloud)
        try require(second.copiedFileCount == 0, "Repeat mirror recopied local files")
        print("PASS cloud preservation / missing-file merge / repeat mirror")
    }

    static func destinationSymlink(_ root: URL, relative: String) async throws {
        let pack = try pack(under: root)
        let local = root.appendingPathComponent("local")
        let outside = root.appendingPathComponent("outside")
        try write("outside marker", "marker.txt", under: outside)
        let link = local.appendingPathComponent(relative)
        try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)
        do {
            _ = try await seed(local, pack: pack)
            throw NSError(domain: "SkillPreservation", code: 2, userInfo: [NSLocalizedDescriptionKey: "Symbolic link accepted: \(relative)"])
        } catch PublicDocumentFileIO.FileIOError.escapedRoot { }
        try require(try read("marker.txt", under: outside) == "outside marker", "Outside file changed")
        try require(try manager.contentsOfDirectory(atPath: outside.path) == ["marker.txt"], "Seeder followed destination symbolic link")
        try require(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true, "Seeder removed destination symbolic link")
        print("PASS rejects destination symlink \(relative)")
    }

    static func cloudSymlink(_ root: URL, linksRoot: Bool = false) async throws {
        let pack = try pack(under: root)
        let local = root.appendingPathComponent("local")
        let cloud = root.appendingPathComponent("cloud")
        let outside = root.appendingPathComponent("outside")
        try write("outside marker", "marker.txt", under: outside)
        let link = linksRoot ? cloud : cloud.appendingPathComponent("Templates")
        try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)
        let result = try await seed(local, pack: pack, cloud: cloud)
        try require(result.iCloudMirror?.attention != nil, "Unsafe cloud destination did not report mirror failure")
        try require(try read("\(skill)/SKILL.md", under: local) == "bundled skill", "Mirror failure undid local installation")
        try require(try manager.contentsOfDirectory(atPath: outside.path) == ["marker.txt"], "Mirror followed cloud symbolic link")
        print("PASS mirror \(linksRoot ? "root" : "Templates") symlink failure leaves local installation usable")
    }

    static func sourceReadFailure(_ root: URL) async throws {
        let pack = try pack(under: root)
        let local = root.appendingPathComponent("local")
        let scripts = pack.appendingPathComponent("\(skill)/scripts")
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: scripts.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scripts.path) }
        var failed = false
        do {
            _ = try await seed(local, pack: pack)
        } catch {
            failed = true
        }
        try require(failed, "Unreadable source directory was reported as successful installation")
        try require(!manager.fileExists(atPath: local.appendingPathComponent("\(skill)/scripts/generate_minutes.py").path), "Unreadable source fixture was ineffective")
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scripts.path)
        _ = try await seed(local, pack: pack)
        try require(try read("\(skill)/scripts/generate_minutes.py", under: local) == "bundled script", "Retry after source recovery did not install missing script")
        print("PASS source enumeration failure is explicit and retry installs missing files")
    }

    static func main() async throws {
        let root = manager.temporaryDirectory.appendingPathComponent("skill-checks-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        try await localPreservation(root.appendingPathComponent("case1"))
        try await cloudPreservation(root.appendingPathComponent("case2"))
        try await destinationSymlink(root.appendingPathComponent("case3"), relative: skill)
        try await destinationSymlink(root.appendingPathComponent("case4"), relative: "Templates")
        try await cloudSymlink(root.appendingPathComponent("case5"))
        try await destinationSymlink(root.appendingPathComponent("case6"), relative: "")
        try await cloudSymlink(root.appendingPathComponent("case7"), linksRoot: true)
        try await sourceReadFailure(root.appendingPathComponent("case8"))
        print("PASS production Skill seeder: 8 temporary-directory regression groups")
    }
}
