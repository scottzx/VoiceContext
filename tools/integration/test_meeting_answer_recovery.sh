#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
MEETING_RECOVERY_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/meeting-answer-recovery.XXXXXX")
trap 'rm -rf "$MEETING_RECOVERY_CHECK_DIR"' EXIT
sed -n '1,/\/\/ MARK: - Agent Messages/p' \
    Vendor/Phone/src/ios/Providers/AgentProvider.swift > "$MEETING_RECOVERY_CHECK_DIR/AgentToolTypes.swift"
python3 - "$MEETING_RECOVERY_CHECK_DIR" <<'PY'
from pathlib import Path
import re
import sys

def block(source, declaration):
    start = source.index(declaration)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    return source[start:end]

vm = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel.swift').read_text()
definitions = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift').read_text()
dispatch = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift').read_text()
fallback = Path('Vendor/Phone/src/ios/Agent/Chat/AIChatViewModel+Fallback.swift').read_text()
store = Path('Vendor/Phone/src/ios/Agent/Chat/ChatStore.swift').read_text()
helper = block(vm, '        func requestMeetingAnswerDelivery(')
no_start = vm.index('                // [T-meeting-answer-user-recovery-no-tool]')
no_end = vm.index('                // [T-ios-queued-message-continues-prev-turn]', no_start)
no_tool = vm[no_start:no_end]
tool_start = vm.index('            // [T-meeting-answer-user-recovery-tool-close]')
tool_end = vm.index('            // [T-ios-queued-message-interrupt-on-toolclose]', tool_start)
tool_close = vm[tool_start:tool_end]
pass_start = vm.index('                if isNoticeDriven && GroupMentionRouter.isPass(')
pass_branch = block(vm[pass_start:], '                if isNoticeDriven && GroupMentionRouter.isPass(')
empty_classifier = block(vm, '            func isEmptyResponse(')
no_tool_guard = vm.index('            guard !toolEntries.isEmpty else {')
classify_start = vm.index('                canResume = false', no_tool_guard)
classify_end = vm.index('                // Flush any remaining unspoken text', classify_start)
stop_classification = vm[classify_start:classify_end]
fallback_function = fallback.index('    func streamWithGroupFallbackUntilContent(')
fallback_empty_start = fallback.index('            let hasReasoning =', fallback_function)
fallback_empty_end = fallback.index('            // Empty response — record this entry', fallback_empty_start)
fallback_empty_decision = fallback[fallback_empty_start:fallback_empty_end]
assert '[T-meeting-empty-fallback-delivery]' in fallback_empty_decision
assert fallback_empty_decision.count('return result') == 2
assert 'guard isEmpty else { return result }' in fallback_empty_decision
assert '&& !hasReasoning && !result.isStreamInterrupted' in fallback_empty_decision
assert '&& result.stopReason != .maxTokens' in fallback_empty_decision
assert 'if isMeetingCoordinator, result.stopReason == .endTurn,' in fallback_empty_decision
assert 'MeetingAnswerUserTool.canRequestDelivery(sessionID: sessionId)' in fallback_empty_decision
assert fallback_empty_end < fallback.index('            let entryKey = activeEntryId ?? "unknown"', fallback_empty_end)
round_tools = re.search(r'^\s*let roundTools = hooks\.tools\(tools\)$', vm, re.M).group().strip()
required_tool = re.search(r'^\s*let requiredToolName = .+$', vm, re.M).group().strip()

# Verify real-loop insertion points and that shrinking the captured `tools`
# actually changes the next provider request and both execution adapters.
assert 'var tools = makeAgentTools()' in vm
assert 'var meetingAnswerDeliveryRound = false' in vm
final_persist = vm.index('if let persistedId = await persistAgentMessage(assistantMessage, tokenUsage:')
assert pass_start < final_persist < no_start < no_end
batch_persist = vm.index('await ChatStore.shared.appendMessages(batch)', no_end)
cancel = vm.index('if cancelledDuringToolExecution || self.userDidCancel {', batch_persist)
assert batch_persist < cancel < tool_start < tool_end
assert 'let roundTools = hooks.tools(tools)' in vm
assert required_tool == 'let requiredToolName = meetingAnswerDeliveryRound ? "answer_user" : nil'
# Check every initial/retry/fallback request in the production loop. A fake
# provider recording the desired value alone would miss a dropped call argument.
requests = []
loop_requests = vm[vm.index('            let roundTools = hooks.tools(tools)'):no_start]
for match in re.finditer(r'\b(streamWithGroupFallback(?:UntilContent)?|streamWithAutoRetry)\(', loop_requests):
    opening = loop_requests.index('(', match.start())
    depth, end = 1, opening + 1
    while depth:
        if loop_requests[end] == '(': depth += 1
        if loop_requests[end] == ')': depth -= 1
        end += 1
    request = loop_requests[match.start():end]
    assert 'tools: roundTools,' in request, match.group(1)
    assert 'requiredToolName: requiredToolName,' in request, match.group(1)
    requests.append(match.group(1))
assert requests == ['streamWithGroupFallback', 'streamWithAutoRetry',
                    'streamWithGroupFallbackUntilContent', 'streamWithAutoRetry',
                    'streamWithGroupFallbackUntilContent'], requests
assert 'tools: tools,' in vm[vm.index('if shouldUseSharedAgentRunEngine(for: toolEntries)'):]
assert 'let toolsSnapshot = tools' in vm[no_end:]
assert 'tu: tu, msgIdx: msgIdx, tools: toolsSnapshot' in vm[no_end:]
assert 'displayStr = Self.stripSystemReminders(displayStr)' in store

wiring = 'import Foundation\nextension AIChatViewModel {\n'
for source, declaration in [
    (definitions, '    var isMeetingCoordinator:'),
    (definitions, '    static var meetingCoordinatorToolNames:'),
    (definitions, '    func meetingToolRefusal('),
    (dispatch, '    func executeSingleToolUse('),
    (vm, '    private var canSpeakNow: Bool {')
]:
    wiring += block(source, declaration) + '\n'
wiring += '    var testCanSpeakNow: Bool { canSpeakNow }\n'
wiring += empty_classifier.replace('            func isEmptyResponse(', '    func testIsEmptyResponse(') + '\n'
# Adapt only the two return values to expose whether the real code proceeds
# into generic fallback. The classification and authorization are unchanged.
wiring += '    func testUsesGenericEmptyFallback(_ result: StreamResult) -> Bool {\n'
wiring += fallback_empty_decision.replace('return result', 'return false')
wiring += '        return true\n    }\n'
wiring += '''
    func runRecoveryScript(_ provider: ScriptProvider) async {
        let hooks = self.hooks ?? HostHooks()
        var tools = makeAgentTools()
        var meetingAnswerDeliveryRound = false
''' + helper + '''
        let msgIdx = 0
        let entry = HostModelEntry()
        var hitTurnLimit = true
        while provider.requests.count < 10 {
''' + '            ' + round_tools + '\n            ' + required_tool + '''
            let turn: ScriptTurn
            do { turn = try provider.next(tools: roundTools, requiredToolName: requiredToolName, history: agentHistory) } catch { return }
            let stopReason = turn.stopReason
            let assistantText = turn.text
            let streamResult = StreamResult(assistantText: turn.text, toolEntries: turn.calls,
                                            stopReason: stopReason, reasoningContent: turn.reasoning,
                                            isStreamInterrupted: turn.interrupted)
            provider.emptyRetryClassifications.append(testIsEmptyResponse(streamResult))
            canResume = turn.interrupted
            ordinarySpeech(turn.text)
            // Even if private reasoning reached the generic speech path, the
            // actual meeting gate must keep it out of the output boundary.
            ordinarySpeech(turn.reasoning)
            let assistantMessage = AgentMessage(role: .assistant, parts: [.text(turn.text)] + turn.calls.map {
                .toolUse(id: $0.id, name: $0.name, input: $0.args)
            })
            let assistantAgentIdx = agentHistory.count
            agentHistory.append(assistantMessage)
            if turn.calls.isEmpty {
''' + stop_classification + pass_branch + '''
                if let persistedID = await persistAgentMessage(assistantMessage) {
                    agentHistory[assistantAgentIdx].dbMessageId = persistedID
                    await ChatStore.shared.updateMessageErrorInfo(messageId: persistedID, errorInfo: messages[msgIdx].error)
                }
''' + no_tool + '''
                break
            }
            _ = await persistAgentMessage(assistantMessage)
            var parts: [AgentContentPart] = []
            for call in turn.calls {
                let outcome = await executeSingleToolUse(tu: call, msgIdx: msgIdx, tools: tools, batchBudget: .init())
                parts.append(outcome.resultPart)
            }
            let result = AgentMessage(role: .user, parts: parts)
            agentHistory.append(result)
            _ = await persistAgentMessage(result)
            if userDidCancel { break }
''' + tool_close + '''
            if stopReason == .endTurn { break }
        }
        _ = hitTurnLimit
    }
}
enum ContextDisplayCheck {
''' + block(store, '    static func stripSystemReminders(') + '\n}\n'
Path(sys.argv[1], 'RecoveryWiring.swift').write_text(wiring)
PY
xcrun swiftc -default-isolation MainActor -D VOICE_AGENT_FUSION \
    "$MEETING_RECOVERY_CHECK_DIR/AgentToolTypes.swift" \
    Integration/App/MeetingAnswerUserTool.swift \
    "$MEETING_RECOVERY_CHECK_DIR/RecoveryWiring.swift" \
    tools/integration/test_meeting_answer_recovery.swift \
    -o "$MEETING_RECOVERY_CHECK_DIR/check"
"$MEETING_RECOVERY_CHECK_DIR/check"
