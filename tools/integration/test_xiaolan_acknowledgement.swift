import Foundation

// No audio engine is instantiated. Only the SDK boundary is replaced so the
// product continuation, cancellation and callback identity logic run unchanged.
nonisolated protocol AVSpeechSynthesizerDelegate: AnyObject {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart: AVSpeechUtterance)
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish: AVSpeechUtterance)
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel: AVSpeechUtterance)
}
@MainActor final class AVSpeechSynthesisVoice {
    static var available = true
    let language: String
    init?(language: String) { guard Self.available else { return nil }; self.language = language }
}
nonisolated final class AVSpeechUtterance: @unchecked Sendable {
    let string: String
    var voice: AVSpeechSynthesisVoice?
    init(string: String) { self.string = string }
}
@MainActor final class AVSpeechSynthesizer {
    enum Boundary { case immediate }
    static var latest: AVSpeechSynthesizer?
    weak var delegate: AVSpeechSynthesizerDelegate?
    var spoken: [AVSpeechUtterance] = []
    init() { Self.latest = self }
    func speak(_ utterance: AVSpeechUtterance) { spoken.append(utterance) }
    func stopSpeaking(at boundary: Boundary) {}
}

@main struct XiaolanAcknowledgementChecks {
    @MainActor static func main() async {
        let helper = XiaolanVoiceAcknowledgement.shared
        let synth = AVSpeechSynthesizer.latest!
        var changes: [Bool] = []
        helper.onSpeakingChanged = { changes.append($0) }
        func waitForSpeech(_ count: Int) async {
            for _ in 0..<1_000 {
                if synth.spoken.count >= count { return }
                await Task.yield()
            }
            preconditionFailure("Expected immediate local speech")
        }
        func flushCallbacks() async { for _ in 0..<10 { await Task.yield() } }
        func check(_ value: Bool) { precondition(value) }

        let wake = Task { await helper.say("我在") }
        await waitForSpeech(1)
        let first = synth.spoken[0]
        precondition(first.string == "我在" && first.voice?.language == "zh-CN" && !helper.isSpeaking)
        synth.delegate?.speechSynthesizer(synth, didStart: first)
        await flushCallbacks()
        precondition(helper.isSpeaking && changes == [true])
        synth.delegate?.speechSynthesizer(synth, didFinish: first)
        check(await wake.value)
        precondition(!helper.isSpeaking && changes == [true, false])

        let stopped = Task { await helper.say("我在") }
        await waitForSpeech(2)
        let old = synth.spoken[1]
        helper.stop()
        check(await stopped.value == false)
        let command = Task { await helper.say("收到，开始处理") }
        await waitForSpeech(3)
        let current = synth.spoken[2]
        precondition(current.string == "收到，开始处理")
        // These callbacks belong to prior utterances and must not complete or
        // change the speaking state of the new continuation.
        synth.delegate?.speechSynthesizer(synth, didStart: old)
        synth.delegate?.speechSynthesizer(synth, didFinish: old)
        synth.delegate?.speechSynthesizer(synth, didCancel: first)
        await flushCallbacks()
        precondition(!helper.isSpeaking && changes == [true, false])
        synth.delegate?.speechSynthesizer(synth, didStart: current)
        await flushCallbacks()
        precondition(helper.isSpeaking)
        let cancelledCaller = Task { await helper.say("我在") }
        cancelledCaller.cancel()
        check(await cancelledCaller.value == false)
        precondition(helper.isSpeaking && synth.spoken.count == 3,
                     "An already-cancelled caller must not stop the current acknowledgement")
        command.cancel()
        check(await command.value == false)
        precondition(!helper.isSpeaking && changes == [true, false, true, false])
        synth.delegate?.speechSynthesizer(synth, didCancel: current)
        synth.delegate?.speechSynthesizer(synth, didFinish: current)
        await flushCallbacks()
        precondition(changes == [true, false, true, false])

        AVSpeechSynthesisVoice.available = false
        check(await helper.say("我在") == false)
        AVSpeechSynthesisVoice.available = true
        check(await helper.say("改写后的回执") == false)
        precondition(synth.spoken.count == 3)
        helper.stop()
        print("PASS: exact local zh-CN acknowledgements, actual speaking callbacks, once-only continuation and late/stop/task cancellation isolation; no audio runtime used")
    }
}
