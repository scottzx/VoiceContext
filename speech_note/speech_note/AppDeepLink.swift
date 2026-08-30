import Foundation

/// App URL routes used by the home-screen Record Widget and future launchers.
/// Scheme is registered in Info.plist (`CFBundleURLTypes`).
enum AppDeepLink: Equatable, Sendable {
    case startRecording
    case stopRecording
    case openRecording

    static let urlScheme = "voicecontext"
    static let startRecordingHost = "start-recording"
    static let stopRecordingHost = "stop-recording"
    static let openRecordingHost = "recording"

    static var startRecordingURL: URL {
        URL(string: "\(urlScheme)://\(startRecordingHost)")!
    }

    static var stopRecordingURL: URL {
        URL(string: "\(urlScheme)://\(stopRecordingHost)")!
    }

    static var openRecordingURL: URL {
        URL(string: "\(urlScheme)://\(openRecordingHost)")!
    }

    static func parse(_ url: URL) -> AppDeepLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == urlScheme else {
            return nil
        }

        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if host == startRecordingHost || path == startRecordingHost || host == "record" || path == "record" {
            return .startRecording
        }
        if host == stopRecordingHost || path == stopRecordingHost || host == "stop" || path == "stop" {
            return .stopRecording
        }
        if host == openRecordingHost || path == openRecordingHost {
            return .openRecording
        }
        return nil
    }
}
