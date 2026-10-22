import Foundation

@main
struct YimaPlacesChecks {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yima-places-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Yima/places.json")
        let store = YimaPlacesStore(url: url)
        precondition(store.available && store.items.isEmpty)

        let candidate = YimaPlace(name: " 河畔面馆文一路店 ", address: "杭州市文一路 1 号", latitude: 30.29, longitude: 120.12)
        let first = try store.save(candidate, tags: [" 想去 ", "面食", "想去", " "])
        precondition(first.id == candidate.id && first.name == "河畔面馆文一路店")
        precondition(first.tags == ["想去", "面食"] && first.revision == 1)
        precondition(YimaPlacesStore(url: url).items == store.items, "Saved places must survive reopening")

        let repeated = YimaPlace(name: first.name, address: first.address, latitude: first.latitude + 0.00001, longitude: first.longitude)
        precondition(repeated.id != first.id && store.savedMatch(for: repeated)?.id == first.id,
                     "A new search candidate must resolve to the existing canonical favorite")
        let merged = try store.save(repeated, tags: ["面食", "午饭"])
        precondition(merged.id == first.id && store.items.count == 1 && merged.revision == 2)
        precondition(merged.tags == ["想去", "面食", "午饭"] && merged.createdAt == first.createdAt)
        precondition(store.savedMatch(for: repeated) == merged, "Candidate matching must return the current saved tags and revision")
        let unchanged = try store.save(repeated, tags: ["午饭"])
        precondition(unchanged == merged, "An identical repeated save must not change the revision")

        let branch = try store.save(YimaPlace(name: first.name, address: "杭州市文二路 20 号", latitude: first.latitude, longitude: first.longitude), tags: [])
        let distant = try store.save(YimaPlace(name: first.name, address: first.address, latitude: 31.2, longitude: 121.4), tags: [])
        precondition(store.items.count == 3 && branch.id != first.id && distant.id != first.id, "Names alone cannot merge branches")
        precondition(store.filtered(tag: "午饭").map(\.id) == [first.id])
        precondition(store.filtered(query: "文二路").map(\.id) == [branch.id])
        precondition(store.filtered(query: "午饭").map(\.id) == [first.id])
        precondition(store.allTags.count == 3)

        let beforeEdit = store.items
        let beforeEditData = try Data(contentsOf: url)
        expectRejection { _ = try store.updateTags(id: first.id, tags: ["旧编辑"], expectedRevision: first.revision) }
        expectRejection { try store.delete(id: first.id, expectedRevision: first.revision) }
        let afterEditData = try Data(contentsOf: url)
        precondition(store.items == beforeEdit && afterEditData == beforeEditData, "Stale mutations must not change memory or disk")

        let edited = try store.updateTags(id: first.id, tags: [" Brunch ", "brunch", ""], expectedRevision: merged.revision)
        precondition(edited.tags == ["Brunch"] && edited.revision == 3)
        try store.delete(id: first.id, expectedRevision: edited.revision)
        precondition(store.get(first.id) == nil && YimaPlacesStore(url: url).items == store.items)
        precondition(store.savedMatch(for: repeated) == nil && store.savedMatch(for: first) == nil,
                     "A removed favorite must no longer resolve through either candidate or canonical ID")

        for field in ["name", "address", "latitude", "longitude", "source", "revision", "date"] {
            var invalid = candidate
            switch field {
            case "name": invalid.name = " \n"
            case "address": invalid.address = ""
            case "latitude": invalid.latitude = .nan
            case "longitude": invalid.longitude = 181
            case "source": invalid.coordinateSource = "WGS-84"
            case "revision": invalid.revision = 0
            default: invalid.updatedAt = .distantPast
            }
            let before = store.items
            expectRejection { _ = try store.save(invalid, tags: []) }
            precondition(store.items == before, "Invalid \(field) must not be saved")
        }

        let corruptURL = directory.appendingPathComponent("corrupt.json")
        let corruptBytes = Data("not-json".utf8)
        try corruptBytes.write(to: corruptURL)
        let corrupt = YimaPlacesStore(url: corruptURL)
        precondition(!corrupt.available && corrupt.readError != nil)
        expectRejection { _ = try corrupt.save(candidate, tags: []) }
        let preservedBytes = try Data(contentsOf: corruptURL)
        precondition(preservedBytes == corruptBytes, "Corrupt data must remain untouched")

        let futureURL = directory.appendingPathComponent("future.json")
        try JSONEncoder().encode(FixtureFile(schemaVersion: 99, items: [])).write(to: futureURL)
        let future = YimaPlacesStore(url: futureURL)
        precondition(!future.available)
        expectRejection { _ = try future.save(candidate, tags: []) }

        let duplicateURL = directory.appendingPathComponent("duplicate.json")
        try JSONEncoder().encode(FixtureFile(schemaVersion: 1, items: [candidate, candidate])).write(to: duplicateURL)
        precondition(!YimaPlacesStore(url: duplicateURL).available)

        let invalidURL = directory.appendingPathComponent("invalid.json")
        var legacy = candidate; legacy.coordinateSource = "GCJ-02"
        try JSONEncoder().encode(FixtureFile(schemaVersion: 1, items: [legacy])).write(to: invalidURL)
        precondition(!YimaPlacesStore(url: invalidURL).available, "Legacy coordinate contracts are never silently imported")

        let blockedParent = directory.appendingPathComponent("blocked")
        let failed = YimaPlacesStore(url: blockedParent.appendingPathComponent("places.json"))
        precondition(failed.available)
        try Data("a file cannot contain places.json".utf8).write(to: blockedParent)
        expectRejection { _ = try failed.save(candidate, tags: []) }
        precondition(failed.items.isEmpty, "Failed persistence must not publish a saved place")
    }

    @MainActor
    private static func expectRejection(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected the operation to fail") }
        catch { }
    }
}

nonisolated private struct FixtureFile: Codable {
    let schemaVersion: Int
    let items: [YimaPlace]
}
