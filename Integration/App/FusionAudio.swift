import Foundation
import AVFoundation
import VoiceRecording
import WebKit

/// The recording module calls this bridge from both capture workers and the UI.
/// All ownership changes are serialized on the host coordinator's main actor;
/// actual AVAudioSession IPC remains on its existing audio queue.
enum FusionAudio {
    @MainActor private static let webViews = NSHashTable<WKWebView>.weakObjects()

    @MainActor static func registerWebView(_ webView: WKWebView) {
        webViews.add(webView)
        if AudioSessionCoordinator.shared.isRecording {
            webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
            webView.setMicrophoneCaptureState(.muted, completionHandler: nil)
        }
    }

    @MainActor static func suspendWebAudio(_ suspended: Bool) {
        for webView in webViews.allObjects {
            webView.setAllMediaPlaybackSuspended(suspended, completionHandler: nil)
            if suspended { webView.setMicrophoneCaptureState(.muted, completionHandler: nil) }
        }
    }

    @MainActor static func install() {
        RecordingAudioBridge.install(.init(
            capture: { owner in try onMain { try AudioSessionCoordinator.shared.beginRecording(owner: owner) } },
            release: { owner in onMain { AudioSessionCoordinator.shared.endRecording(owner: owner) } },
            playback: { onMain { AudioSessionCoordinator.shared.beginAndWait(.mediaAttachment) } },
            releasePlayback: { onMain { AudioSessionCoordinator.shared.end(.mediaAttachment) } }
        ))
    }

    static func onMain<T>(_ body: @MainActor () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try MainActor.assumeIsolated { try body() } }
        return try DispatchQueue.main.sync { try MainActor.assumeIsolated { try body() } }
    }
}

// C entry points let the imported shell tools share exactly the same policy.
@_cdecl("vc_audio_begin")
func vcAudioBegin(_ kind: Int32) -> Bool {
    FusionAudio.onMain {
        guard kind == 1 || kind == 2 else { return false }
        return AudioSessionCoordinator.shared.beginTool(kind == 1 ? .toolCapture : .toolTTS)
    }
}

@_cdecl("vc_audio_end")
func vcAudioEnd(_ kind: Int32) {
    FusionAudio.onMain {
        guard kind == 1 || kind == 2 else { return }
        AudioSessionCoordinator.shared.end(kind == 1 ? .toolCapture : .toolTTS)
    }
}
