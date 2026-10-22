#!/usr/bin/env python3
"""Exercise production ViewModelCache DSH methods on the macOS host, without iOS."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "Vendor/Phone/src/ios/Agent/Chat/ChatLifecycleSupport.swift").read_text()
lookup = source[source.index("    func get(for sessionId:"):source.index("    static func dshKey(")]
remote = source[source.index("    static func dshKey("):source.index("    /// Create a fresh (uncached)")]
fixture = '''import Foundation
struct DSHService { var id: UUID; var name: String; var url: URL }
struct Logger { func info(_ value: String) {} }
let logger = Logger()
@MainActor final class AIChatViewModel {
    var dshService: DSHService?
    var sessionId: String?
    var draftId: String?
    var detachCount = 0
    var cancelCount = 0
    let vmInstanceId = UUID().uuidString
    var isDSH: Bool { dshService != nil }
    init(dshService: DSHService? = nil) { self.dshService = dshService }
    func detachDSHSession() { detachCount += 1 }
    func cancel() { cancelCount += 1 }
}
@MainActor final class ViewModelCache {
    private var cache: [String: AIChatViewModel] = [:]
    private var dshDraftAliases: [String: String] = [:]
    private var lruOrder: [String] = []
    func touch(_ id: String) { lruOrder.removeAll { $0 == id }; lruOrder.append(id) }
    func evictIfOverCap() {}
    func seed(_ id: String, _ vm: AIChatViewModel) { cache[id] = vm }
    var count: Int { cache.count }
'''
checks = '''
}
@main struct CachePolicyTests {
    @MainActor static func main() {
        let id = UUID()
        var service = DSHService(id: id, name: "Old", url: URL(string: "http://100.100.100.1:9000")!)
        let cache = ViewModelCache()
        let local = AIChatViewModel()
        cache.seed("local", local)
        let first = cache.getOrCreateDSH(service: service, sessionID: "same", draftID: "unused")
        service.name = "Renamed"
        let renamed = cache.getOrCreateDSH(service: service, sessionID: "same", draftID: "unused")
        precondition(first.vm === renamed.vm && !renamed.isNew && renamed.vm.dshService?.name == "Renamed")
        service.url = URL(string: "http://100.100.100.2:9000")!
        let replaced = cache.getOrCreateDSH(service: service, sessionID: "same", draftID: "unused")
        precondition(replaced.isNew && replaced.vm !== first.vm && first.vm.detachCount == 1 && first.vm.cancelCount == 0,
                     "same id with another origin must discard old transport")
        let draftRoute = "dsh:\\(id.uuidString):__new__draft"
        let draft = cache.getOrCreateDSH(service: service, sessionID: nil, draftID: draftRoute).vm
        precondition(cache.get(for: draftRoute) === draft, "draft must be namespaced exactly once")
        draft.sessionId = "created"
        cache.cacheDSHSession(draft, serviceID: id, sessionID: "created")
        let realRoute = ViewModelCache.dshKey(serviceID: id, sessionID: "created")
        precondition(cache.get(for: draftRoute) === draft && cache.get(for: realRoute) === draft)
        precondition(cache.getOrCreateDSH(service: service, sessionID: nil, draftID: draftRoute).vm === draft,
                     "remounting promoted draft must reuse its server session")
        let other = DSHService(id: UUID(), name: "Other", url: service.url)
        let isolated = cache.getOrCreateDSH(service: other, sessionID: "same", draftID: "unused").vm
        precondition(isolated !== replaced.vm, "server-local session ids must not collide")
        cache.invalidateDSH(serviceID: id)
        precondition(cache.get(for: draftRoute) == nil && cache.get(for: realRoute) == nil)
        precondition(cache.get(for: "local") === local && cache.get(for: ViewModelCache.dshKey(serviceID: other.id, sessionID: "same")) === isolated)
        precondition(draft.detachCount == 1 && draft.cancelCount == 0 && replaced.vm.cancelCount == 0,
                     "cache invalidation must never cancel remote work")
        cache.remove(sessionId: ViewModelCache.dshKey(serviceID: other.id, sessionID: "same"))
        precondition(isolated.detachCount == 1 && isolated.cancelCount == 0)
        print("DSH cache identity and origin tests passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="dsh-cache-policy-") as directory:
    work = Path(directory)
    test = work / "main.swift"
    test.write_text(fixture + lookup + remote + checks)
    executable = work / "check"
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5", str(test), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
