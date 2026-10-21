import Foundation

enum AgentToolPolicy { case standalone, orchestrator }
enum ExpectedFailure: Error { case rejected }

@main struct HostToolCallbackChecks {
    @MainActor static func main() async throws {
        var calls = 0
        AgentRuntimePolicies.hostToolHandlers["native_test"] = { context in
            calls += 1
            precondition(context.toolCallId == "call-1" && context.sessionId == "session-1")
            precondition(context.argumentsJSON == "{\"projectId\":\"p1\"}")
            return .init(content: "{\"ok\":true}", succeeded: true)
        }
        let context = AgentHostToolContext(toolCallId: "call-1", sessionId: "session-1", source: "native", argumentsJSON: "{\"projectId\":\"p1\"}")
        let missing = try await AgentRuntimePolicies.executeHostTool(name: "not_registered", context: context)
        precondition(missing == nil && calls == 0)
        let result = try await AgentRuntimePolicies.executeHostTool(name: "native_test", context: context)
        precondition(result?.succeeded == true && calls == 1)
        AgentRuntimePolicies.hostToolHandlers["throwing"] = { _ in throw ExpectedFailure.rejected }
        do { _ = try await AgentRuntimePolicies.executeHostTool(name: "throwing", context: context); preconditionFailure() }
        catch ExpectedFailure.rejected {}
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await AgentRuntimePolicies.executeHostTool(name: "native_test", context: context); preconditionFailure() }
            catch is CancellationError {}
            catch { preconditionFailure("wrong cancellation error") }
        }
        await cancelled.value
        precondition(calls == 1)
        AgentRuntimePolicies.hostToolHandlers["cancel_during"] = { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return .init(content: "late success", succeeded: true)
        }
        let late = Task { @MainActor in
            do { _ = try await AgentRuntimePolicies.executeHostTool(name: "cancel_during", context: context); preconditionFailure() }
            catch is CancellationError {}
            catch { preconditionFailure("wrong terminal error") }
        }
        await late.value
        print("PASS: native host callbacks retain call/session identity, missing dispatch, errors and cancellation before/after handler; no shell initialization")
    }
}
