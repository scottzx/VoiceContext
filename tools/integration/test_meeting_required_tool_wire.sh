#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
MEETING_REQUIRED_WIRE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/meeting-required-wire.XXXXXX")
trap 'rm -rf "$MEETING_REQUIRED_WIRE_DIR"' EXIT
python3 - "$MEETING_REQUIRED_WIRE_DIR" <<'PY'
from pathlib import Path
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

out = Path(sys.argv[1])
base = Path('Vendor/Phone/src/ios/Providers')
protocol = (base / 'AgentProvider.swift').read_text()
thinking = block((base / 'LLMTypes.swift').read_text(), 'enum ThinkingLevel:')
(out / 'Protocol.swift').write_text(protocol + '\n' + thinking)

openai = (base / 'OpenAI/OpenAIAgentProvider.swift').read_text()
transport_source = (base / 'OpenAI/OpenAIProvider.swift').read_text()
raw = block(transport_source, '    func streamRaw(')
session = block(transport_source, 'private func makeStreamingSession()')
assert 'URLSessionConfiguration.default' in session and 'protocolClasses' not in session
assert 'let session = makeStreamingSession()' in raw
# The Agent path sends the prepared body unchanged; per-call chatExtraBody is
# merged only by the separate non-Agent builders. Pin that boundary as well as
# compiling the real JSON serialization statement in the capture transport.
serialization = 'request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])'
assert serialization in raw
assert 'chatExtraBody' not in raw
assert 'var body' not in raw[:raw.index(serialization)]
(out / 'Serialization.swift').write_text('''import Foundation
extension OpenAIProvider {
    func streamRaw(body: [String: Any], isResponsesAPI: Bool) async throws -> (AsyncThrowingStream<String, Error>, Int) {
        attempts += 1
        if let failure { throw failure }
        var request = URLRequest(url: URL(string: "https://example.invalid")!)
        ''' + serialization + '''
        sentBodies.append(try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])
        responsesFlags.append(isResponsesAPI)
        return (AsyncThrowingStream { $0.finish() }, 0)
    }
}
''')

def request_prefix(source, declaration, transport):
    start = source.index(declaration)
    end = source.index(transport, start) + len(transport)
    return source[start:end] + '\n        _ = lineStream\n        return AsyncThrowingStream { $0.finish() }\n    }\n'

open_header = openai[openai.index('final class OpenAIAgentProvider:'):openai.index('    func streamAgentMessageClamped(')]
open_parts = [open_header, block(openai, '    func streamAgentMessageClamped(')]
for method, response in [('streamChatCompletions', 'false'), ('streamResponsesAPI', 'true')]:
    transport = f'let (lineStream, _) = try await provider.streamRaw(body: body, isResponsesAPI: {response})'
    prefix = request_prefix(openai, f'    private func {method}(', transport)
    # No subsequent body mutation can weaken the forced named selection.
    assert 'requiredToolName: String?' in prefix
    assert prefix.rindex('body["tool_choice"]') < prefix.index(transport)
    open_parts.append(prefix)
for name in ['convertToolsChatCompletions', 'convertToolsResponsesAPI']:
    open_parts.append(block(openai, f'    private func {name}('))
open_parts.append('}\n')
(out / 'OpenAI.swift').write_text('import Foundation\n' + '\n'.join(open_parts))

anthropic = (base / 'Anthropic/AnthropicAgentProvider.swift').read_text()
anthropic_provider = (base / 'Anthropic/AnthropicProvider.swift').read_text()
anth_header = anthropic[anthropic.index('final class AnthropicAgentProvider:'):anthropic.index('    func streamAgentMessageClamped(')]
start = anthropic.index('    func streamAgentMessageClamped(')
end = anthropic.index('\n        #if DEBUG\n        // Note: request body is captured', start)
anth_prefix = anthropic[start:end]
assert 'requiredToolName: String?' in anth_prefix
assert 'provider.service.streamMessage(parameter)' in anthropic[end:]
anth_parts = [anth_header, anth_prefix + '\n        provider.parameters.append(parameter)\n        return AsyncThrowingStream { $0.finish() }\n    }']
for name in ['thinkingBudget', 'thinkingEffort']:
    anth_parts.append(block(anthropic, f'    static func {name}('))
anth_parts.append('}\n')
anth_parts.append('extension AnthropicProvider {')
for name in ['parseClaudeVersion', 'modelUsesAdaptiveThinking', 'modelAcceptsExplicitThinkingDisabled']:
    anth_parts.append(block(anthropic_provider, f'    static func {name}('))
anth_parts.append('}\nenum ThinkingRuleResolver {')
resolver = (base / 'Thinking/ThinkingRuleResolver.swift').read_text()
anth_parts.append(block(resolver, '    static func anthropicThinkingShape('))
anth_parts.append('}\n')
sdk = Path('build/PhonePackages/checkouts/SwiftAnthropic/Sources/Anthropic/Public/Parameters/Message/MessageParameter.swift').read_text()
endpoint = Path('build/PhonePackages/checkouts/SwiftAnthropic/Sources/Anthropic/Private/Network/Endpoint.swift').read_text()
assert 'encoder.keyEncodingStrategy = .convertToSnakeCase' in endpoint
anth_parts += ['extension MessageParameter {', block(sdk, '   public struct ToolChoice:'), '}']
(out / 'Anthropic.swift').write_text('import Foundation\n' + '\n'.join(anth_parts))
PY
swiftc -parse-as-library \
    "$MEETING_REQUIRED_WIRE_DIR/Protocol.swift" \
    "$MEETING_REQUIRED_WIRE_DIR/OpenAI.swift" \
    "$MEETING_REQUIRED_WIRE_DIR/Anthropic.swift" \
    "$MEETING_REQUIRED_WIRE_DIR/Serialization.swift" \
    tools/integration/test_meeting_required_tool_wire.swift \
    -o "$MEETING_REQUIRED_WIRE_DIR/test_meeting_required_tool_wire"
"$MEETING_REQUIRED_WIRE_DIR/test_meeting_required_tool_wire"
