import Foundation

/// Product presets live in the host; the shared runtime only applies policy.
@MainActor
enum VoiceAgentConfiguration {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        AgentRuntimePolicies.hostTools = [YimaItemsAgentTool.definition, AppNavigationTool.definition, AppPresentationTool.definition]
        AgentRuntimePolicies.hiddenAgentIDs.insert(XiaolanAgent.id)
        let shared: Set<String> = ["answer_user", "apple_native", "yima_items", "memory_get", "memory_write"]
        let common = shared.union(SubagentTools.names)
        let reply = AgentReplyDeliveryPolicy(
            definition: MeetingAnswerUserTool.definition,
            canRequest: { MeetingAnswerUserTool.canRequestDelivery(sessionID: $0) },
            reminder: MeetingAnswerUserTool.deliveryReminder
        )
        for (source, meeting) in [("meeting_assistant", true), ("xiaolan_voice", false)] {
            AgentRuntimePolicies.register(source: source, policy: .init(
                toolPolicyOverride: .orchestrator,
                allowedTools: meeting ? common : common.union(["app_navigation", "app_present"]),
                noticeAllowedTools: ["answer_user"], additionalTools: [MeetingAppleTool.definition],
                replyDelivery: reply, allowsLiteMode: false, allowsAutomaticSpeech: false,
                headless: true, requiresIdle: true, requiresNoticeReplyBinding: true,
                requiresNavigationBinding: !meeting, restoresSourceOnLoad: true,
                prompt: { agentID, memoryEnabled, noticeDriven in
                    VoiceAgentPrompt.render(agentId: agentID, memoryEnabled: memoryEnabled,
                                            noticeDriven: noticeDriven, meeting: meeting)
                }
            ))
        }
    }
}
