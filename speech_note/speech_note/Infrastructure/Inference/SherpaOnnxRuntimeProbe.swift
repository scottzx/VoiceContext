import Foundation
import SherpaOnnxC

enum SherpaOnnxRuntimeProbe {
    /// Touches the static C ABI during startup so a malformed XCFramework
    /// fails in the technical spike instead of at the first VAD or CAM++ call.
    static func version() -> String {
        String(cString: SherpaOnnxGetVersionStr())
    }
}
