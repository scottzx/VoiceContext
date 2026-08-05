import CTranscribe
import Foundation

enum TranscribeRuntimeProbe {
    /// Touches the linked C ABI during startup so a missing or malformed
    /// framework fails during the technical spike rather than at first decode.
    static func version() -> String {
        String(cString: transcribe_version())
    }
}
