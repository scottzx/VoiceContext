import Foundation

/// Shared by the app and Agent extensions; development containers never fall back to production.
nonisolated enum AgentBuildIdentity {
    #if VOICE_AGENT_DEV
    static let appGroupID = "group.YiJie.speech-note.dev.agent"
    static let iCloudContainerID = "iCloud.YiJie.speech-note.dev.agent"
    static let urlScheme = "minis-dev"
    static let recordingURLScheme = "voicecontext-dev"
    #else
    static let appGroupID = "group.YiJie.speech-note.agent"
    static let iCloudContainerID = "iCloud.YiJie.speech-note.agent"
    static let urlScheme = "minis"
    static let recordingURLScheme = "voicecontext"
    #endif
}
