#if VOICE_AGENT_FUSION
import TranscribeNative
#else
import CTranscribe
#endif
import Foundation

enum TranscribeRuntimeProbe {
    /// Touches the linked C ABI during startup so a missing or malformed
    /// framework fails during the technical spike rather than at first decode.
    static func version() -> String {
        #if VOICE_AGENT_FUSION
        Transcribe.version()
        #else
        String(cString: transcribe_version())
        #endif
    }
}
