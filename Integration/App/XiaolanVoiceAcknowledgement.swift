import AVFoundation
import Foundation

/// Immediate local wake feedback. The controller owns audio-session admission,
/// mute preferences and whether the current voice request may speak.
@MainActor
final class XiaolanVoiceAcknowledgement: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = XiaolanVoiceAcknowledgement()
    private(set) var isSpeaking = false
    var onSpeakingChanged: (@MainActor (Bool) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    private var token: UUID?
    private var completion: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func say(_ text: String) async -> Bool {
        guard ["我在", "收到，开始处理"].contains(text) else { return false }
        guard !Task.isCancelled,
              let voice = AVSpeechSynthesisVoice(language: "zh-CN") else { return false }
        stop()
        let speech = AVSpeechUtterance(string: text)
        speech.voice = voice
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                token = id
                utterance = speech
                completion = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard self?.token == id else { return }
                    self?.stop()
                }
                synthesizer.speak(speech)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.token == id else { return }
                self?.stop()
            }
        }
    }

    func stop() {
        finish(completed: false)
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func finish(completed: Bool) {
        let waiting = completion
        completion = nil
        token = nil
        utterance = nil
        timeout?.cancel()
        timeout = nil
        setSpeaking(false)
        waiting?.resume(returning: completed)
    }

    private func setSpeaking(_ value: Bool) {
        guard isSpeaking != value else { return }
        isSpeaking = value
        onSpeakingChanged?(value)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart speech: AVSpeechUtterance) {
        Task { @MainActor [weak self, speech] in
            guard self?.utterance === speech else { return }
            self?.setSpeaking(true)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish speech: AVSpeechUtterance) {
        Task { @MainActor [weak self, speech] in
            guard self?.utterance === speech else { return }
            self?.finish(completed: true)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel speech: AVSpeechUtterance) {
        Task { @MainActor [weak self, speech] in
            guard self?.utterance === speech else { return }
            self?.finish(completed: false)
        }
    }
}
