import Foundation

/// Collects one command from the same absolute 16 kHz PCM timeline as the recorder.
nonisolated struct MeetingWakeCommandCapture: Sendable {
    nonisolated struct Command: Sendable {
        let samples: [Float]
        let startSample: Int64
        let endSample: Int64
    }

    nonisolated enum Event: Sendable {
        case command(Command)
        case timedOut
        case tooLong
        case discontinuity
    }

    private struct Frame: Sendable {
        let samples: [Float]
        let start: Int64
        let isSpeech: Bool
        var end: Int64 { start + Int64(samples.count) }
    }

    private struct Capture: Sendable {
        let wakeEnd: Int64
        var start: Int64
        var samples: [Float] = []
        var speechStart: Int64?
        var speechSamples: Int64 = 0
        var lastSpeechEnd: Int64?
        var hasCommand = false
        let finishOnSilence: Bool
        let acousticWake: Bool
        var lastUtteranceSpeechEnd: Int64?
    }

    private static let sampleRate: Int64 = 16_000
    private static let recentLimit = 3 * sampleRate
    private static let waitLimit = 8 * sampleRate
    private static let commandLimit = 20 * sampleRate
    private static let quietLimit: Int64 = 11_200 // 0.7 seconds, after VAD stops detecting speech.
    private static let minimumSpeech: Int64 = 3_840 // 0.24 seconds.
    private static let wakeTail: Int64 = 1_920 // Count speech after a 0.12-second keyword tail.
    private static let speechPreRoll: Int64 = 3_200
    private var recent: [Frame] = []
    private var expectedSample: Int64?
    private var capture: Capture?
    private var pendingEvent: Event?

    var isActive: Bool { capture != nil || pendingEvent != nil }
    var bufferedSampleCount: Int {
        let pendingSamples: Int
        if case .command(let command) = pendingEvent { pendingSamples = command.samples.count }
        else { pendingSamples = 0 }
        return recent.reduce(0) { $0 + $1.samples.count } + (capture?.samples.count ?? 0) + pendingSamples
    }

    mutating func reset() {
        recent.removeAll()
        expectedSample = nil
        capture = nil
        pendingEvent = nil
    }

    /// A deliberate tap authorizes one command without an acoustic keyword.
    /// Use the same bounded VAD collection, retaining audio from the tap onward.
    mutating func beginCommand(at sample: Int64, finishOnSilence: Bool = false) {
        reset()
        capture = Capture(wakeEnd: sample - Self.wakeTail, start: sample,
                          finishOnSilence: finishOnSilence, acousticWake: false)
    }

    mutating func append(samples: [Float], startingAt startSample: Int64, isSpeech: Bool) -> Event? {
        guard !samples.isEmpty else { return nil }
        let interrupted = expectedSample.map { $0 != startSample } ?? false
        let wasActive = isActive
        if interrupted { reset() }
        let frame = Frame(samples: samples, start: startSample, isSpeech: isSpeech)
        remember(frame)
        expectedSample = frame.end
        if interrupted && wasActive { return .discontinuity }
        if let pendingEvent {
            self.pendingEvent = nil
            return pendingEvent
        }
        return consume(frame)
    }

    /// Replays the recent audio so decoder latency cannot discard a same-sentence command.
    @discardableResult
    mutating func wake(startSample: Int64, endSample: Int64, finishOnSilence: Bool = false) -> Bool {
        guard !isActive, let first = recent.first, let latest = expectedSample,
              startSample >= first.start, endSample > startSample, endSample <= latest else { return false }
        let audioStart = max(first.start, startSample - 1_280)
        capture = Capture(wakeEnd: endSample, start: audioStart,
                          finishOnSilence: finishOnSilence, acousticWake: true)
        for frame in recent where frame.end > audioStart {
            let start = max(audioStart, frame.start)
            let replay = Frame(samples: Array(frame.samples[Int(start - frame.start)...]),
                               start: start, isSpeech: frame.isSpeech)
            if let event = consume(replay) {
                pendingEvent = event
                break
            }
        }
        return true
    }

    private mutating func remember(_ frame: Frame) {
        recent.append(frame)
        let keepFrom = frame.end - Self.recentLimit
        while let first = recent.first, first.end <= keepFrom { recent.removeFirst() }
        if let first = recent.first, first.start < keepFrom {
            recent[0] = Frame(samples: Array(first.samples[Int(keepFrom - first.start)...]),
                              start: keepFrom, isSpeech: first.isSpeech)
        }
    }

    private func precedingAudio(from start: Int64, to end: Int64) -> [Float] {
        recent.flatMap { frame in
            let lower = max(start, frame.start)
            let upper = min(end, frame.end)
            return upper > lower ? Array(frame.samples[Int(lower - frame.start)..<Int(upper - frame.start)]) : []
        }
    }

    private mutating func consume(_ frame: Frame) -> Event? {
        guard var current = capture else { return nil }
        capture = nil // Transfer ownership before appending; do not copy the growing PCM buffer each window.
        if frame.isSpeech { current.lastUtteranceSpeechEnd = frame.end }
        let eligibleStart = max(frame.start, current.wakeEnd + Self.wakeTail)
        let hasSpeech = frame.isSpeech && frame.end > eligibleStart
        if hasSpeech {
            if current.speechStart == nil {
                guard eligibleStart <= current.wakeEnd + Self.waitLimit else {
                    capture = nil
                    return .timedOut
                }
                current.speechStart = eligibleStart
            }
            current.speechSamples += frame.end - eligibleStart
            current.lastSpeechEnd = frame.end
            current.hasCommand = current.speechSamples >= Self.minimumSpeech
        }

        let quietEnd = current.finishOnSilence
            ? max(current.lastUtteranceSpeechEnd ?? current.wakeEnd, current.wakeEnd) + Self.quietLimit
            : (current.lastSpeechEnd ?? current.wakeEnd) + Self.quietLimit
        // Independent voice transcribes the entire wake utterance, including
        // the keyword alone and commands shorter than the post-keyword tail.
        // A silent direct tap has no acoustic authorization and still times out.
        let canFinishUtterance = current.finishOnSilence
            && (current.acousticWake || current.lastUtteranceSpeechEnd != nil)
        let finished = (canFinishUtterance ? !frame.isSpeech : current.hasCommand && !hasSpeech)
            && frame.end >= quietEnd
        if let speechStart = current.speechStart,
           frame.end >= speechStart + Self.commandLimit,
           !finished || quietEnd > speechStart + Self.commandLimit {
            capture = nil
            return .tooLong
        }

        if current.samples.isEmpty {
            if hasSpeech && frame.start > current.start {
                current.start = max(recent.first?.start ?? frame.start, frame.start - Self.speechPreRoll)
                current.samples = precedingAudio(from: current.start, to: frame.start)
            } else if frame.start > current.start {
                if frame.end > current.wakeEnd + Self.waitLimit {
                    capture = nil
                    return .timedOut
                }
                capture = current
                return nil
            }
        }
        let audioEnd = finished ? quietEnd : frame.end
        current.samples.append(contentsOf: frame.samples.prefix(Int(audioEnd - frame.start)))

        if finished {
            capture = nil
            return .command(Command(samples: current.samples, startSample: current.start, endSample: audioEnd))
        }
        if !hasSpeech && frame.end >= quietEnd && !current.hasCommand {
            // An isolated keyword or a short noise burst does not consume the eight-second wait.
            current.samples.removeAll()
            current.speechStart = nil
            current.speechSamples = 0
            current.lastSpeechEnd = nil
        }
        if !current.hasCommand && current.speechStart == nil,
           frame.end > current.wakeEnd + Self.waitLimit {
            capture = nil
            return .timedOut
        }
        capture = current
        return nil
    }
}
