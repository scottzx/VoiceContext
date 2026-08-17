import Foundation

/// App URL routes used by the home-screen Record Widget and future launchers.
/// Scheme is registered in Info.plist (`CFBundleURLTypes`).
enum AppDeepLink: Equatable, Sendable {
    case startRecording

    static let urlScheme = "voicecontext"
    static let startRecordingHost = "start-recording"

    static var startRecordingURL: URL {
        URL(string: "\(urlScheme)://\(startRecordingHost)")!
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
        return nil
    }
}
