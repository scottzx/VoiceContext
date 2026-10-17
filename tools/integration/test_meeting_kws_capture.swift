import Foundation

@main
struct MeetingKWSCaptureChecks {
    static let rate: Int64 = 16_000

    struct Fixture: Decodable {
        struct Frame: Decodable {
            struct Hit: Decodable {
                let hitEndSample: Int64
                let timestamps: [Double]
            }
            let startSample: Int64
            let endSample: Int64
            let isSpeech: Bool
            let hits: [Hit]
        }
        let name: String
        let sampleRate: Int
        let expected: String?
        let frames: [Frame]
    }

    struct Fixtures: Decodable { let cases: [Fixture] }

    static func pcm(start: Int64, count: Int) -> [Float] {
        (0..<count).map { Float(start + Int64($0)) }
    }

    @discardableResult
    static func feed(_ capture: inout MeetingWakeCommandCapture, _ cursor: inout Int64,
                     samples: Int64, speech: Bool, packetSize: Int = 512) -> [MeetingWakeCommandCapture.Event] {
        let end = cursor + samples
        var events: [MeetingWakeCommandCapture.Event] = []
        while cursor < end {
            let count = Int(min(Int64(packetSize), end - cursor))
            if let event = capture.append(samples: pcm(start: cursor, count: count),
                                          startingAt: cursor, isSpeech: speech) { events.append(event) }
            cursor += Int64(count)
            precondition(capture.bufferedSampleCount <= 27 * Int(rate), "PCM storage must remain bounded")
        }
        return events
    }

    static func command(_ events: [MeetingWakeCommandCapture.Event]) -> MeetingWakeCommandCapture.Command {
        precondition(events.count == 1, "Expected exactly one completed command")
        guard case .command(let command) = events[0] else { preconditionFailure("Expected a command") }
        precondition(command.samples.count == Int(command.endSample - command.startSample))
        precondition(command.samples == pcm(start: command.startSample, count: command.samples.count),
                     "Capture must preserve every sample in order, including the command's first sound")
        return command
    }

    static func main() {
        var capture = MeetingWakeCommandCapture()
        var cursor: Int64 = 0

        // An explicit tap captures a full bounded command without fabricating
        // an acoustic keyword or dropping the first sound.
        capture.beginCommand(at: 0)
        feed(&capture, &cursor, samples: rate / 2, speech: true)
        let tapped = command(feed(&capture, &cursor, samples: rate, speech: false))
        precondition(tapped.startSample == 0 && tapped.endSample == rate / 2 + 11_200)
        capture.beginCommand(at: cursor)
        let directTimeout = feed(&capture, &cursor, samples: 9 * rate, speech: false)
        guard case .timedOut = directTimeout.first else { preconditionFailure("A silent tap must time out") }
        capture.reset(); cursor = 0

        // Independent voice opts into an utterance endpoint. A keyword alone
        // finishes after VAD quiet, preserving its PCM so ASR can say wake-only.
        feed(&capture, &cursor, samples: rate, speech: true)
        precondition(capture.wake(startSample: 0, endSample: 12_800, finishOnSilence: true))
        let keywordOnly = command(feed(&capture, &cursor, samples: rate, speech: false))
        precondition(keywordOnly.startSample == 0 && keywordOnly.endSample == rate + 11_200)

        // A very short command may fit entirely in the KWS estimate's tail.
        // Independent capture must preserve it rather than wait eight seconds.
        capture.reset(); cursor = 0
        feed(&capture, &cursor, samples: rate + 1_600, speech: true)
        precondition(capture.wake(startSample: 0, endSample: rate, finishOnSilence: true))
        let shortWakeCommand = command(feed(&capture, &cursor, samples: rate, speech: false))
        precondition(shortWakeCommand.startSample == 0 && shortWakeCommand.endSample == rate + 1_600 + 11_200)

        // Decoder latency can report the wake after its VAD endpoint. Replay
        // still delivers exactly one intact utterance on the next PCM frame.
        capture.reset(); cursor = 0
        feed(&capture, &cursor, samples: rate, speech: true)
        feed(&capture, &cursor, samples: rate, speech: false)
        precondition(capture.wake(startSample: 0, endSample: 12_800, finishOnSilence: true))
        let replayedWake = command(feed(&capture, &cursor, samples: 512, speech: false))
        precondition(replayedWake.startSample == 0 && replayedWake.endSample == rate + 11_200)

        // A deliberate tap has no acoustic wake authorization. Silence must
        // time out, while even a short recognized command reaches ASR intact.
        capture.reset(); cursor = 0
        capture.beginCommand(at: 0, finishOnSilence: true)
        let silentIndependentTap = feed(&capture, &cursor, samples: 9 * rate, speech: false)
        guard case .timedOut = silentIndependentTap.first else { preconditionFailure("Silence cannot become a wake-only reply") }
        capture.beginCommand(at: cursor, finishOnSilence: true)
        let tapStart = cursor
        feed(&capture, &cursor, samples: 1_600, speech: true)
        let shortTap = command(feed(&capture, &cursor, samples: rate, speech: false))
        precondition(shortTap.startSample == tapStart && shortTap.endSample == tapStart + 1_600 + 11_200)

        // A gap invalidates independent wake authorization too, and reset
        // discards a completed replay before it can become a local reply.
        capture.reset(); cursor = 0
        feed(&capture, &cursor, samples: rate, speech: true)
        precondition(capture.wake(startSample: 0, endSample: rate, finishOnSilence: true))
        let lostWake = capture.append(samples: [0], startingAt: cursor + 1, isSpeech: false)
        guard case .discontinuity = lostWake else { preconditionFailure("Wake-only capture must reject audio gaps") }
        capture.reset(); cursor = 0

        // Decoder reports a hit after the user has already begun the same-sentence command.
        feed(&capture, &cursor, samples: 20_800, speech: true, packetSize: 317)
        precondition(capture.wake(startSample: 0, endSample: 12_800))
        precondition(!capture.wake(startSample: 0, endSample: 12_800), "Repeated model hits cannot rearm an active command")
        let sameSentence = command(feed(&capture, &cursor, samples: 12_800, speech: false, packetSize: 701))
        precondition(sameSentence.startSample == 0 && sameSentence.endSample == 32_000)
        precondition(!capture.isActive)

        // A delayed hit may arrive after both the command and the endpoint were already buffered.
        capture.reset(); cursor = 0
        feed(&capture, &cursor, samples: 20_800, speech: true)
        feed(&capture, &cursor, samples: 12_800, speech: false)
        precondition(capture.wake(startSample: 0, endSample: 12_800))
        let replayed = command(feed(&capture, &cursor, samples: 512, speech: false))
        precondition(replayed.startSample == 0 && replayed.endSample == 32_000)

        // A standalone keyword with a VAD tail stays armed; its tail must not execute a task.
        capture.reset(); cursor = 0
        feed(&capture, &cursor, samples: 16_000, speech: true)
        precondition(capture.wake(startSample: 0, endSample: 12_800))
        precondition(feed(&capture, &cursor, samples: 96_000, speech: false).isEmpty)
        precondition(capture.isActive)
        let laterStart = cursor
        feed(&capture, &cursor, samples: 12_800, speech: true)
        let later = command(feed(&capture, &cursor, samples: 12_800, speech: false))
        precondition(later.startSample == laterStart - 3_200)

        // Eight seconds is inclusive for a command whose first packet begins at the deadline.
        capture.reset(); cursor = 0
        feed(&capture, &cursor, samples: rate, speech: true)
        precondition(capture.wake(startSample: 0, endSample: rate))
        precondition(feed(&capture, &cursor, samples: 8 * rate, speech: false).isEmpty)
        feed(&capture, &cursor, samples: rate / 2, speech: true)
        _ = command(feed(&capture, &cursor, samples: rate, speech: false))

        // No command and short noise bursts time out; ordinary speech afterwards cannot execute.
        capture.reset(); cursor = 0
        feed(&capture, &cursor, samples: rate, speech: true)
        precondition(capture.wake(startSample: 0, endSample: rate))
        feed(&capture, &cursor, samples: rate, speech: false)
        precondition(feed(&capture, &cursor, samples: rate / 10, speech: true).isEmpty)
        let timeout = feed(&capture, &cursor, samples: 8 * rate, speech: false)
        precondition(timeout.count == 1)
        guard case .timedOut = timeout[0] else { preconditionFailure("Expected wait timeout") }
        precondition(feed(&capture, &cursor, samples: rate, speech: true).isEmpty)
        precondition(!capture.isActive)

        // A weak burst is discarded before the actual command; its sound is not sent as the task.
        capture.reset(); cursor = 0
        feed(&capture, &cursor, samples: rate, speech: true)
        precondition(capture.wake(startSample: 0, endSample: rate))
        feed(&capture, &cursor, samples: rate, speech: false)
        feed(&capture, &cursor, samples: rate / 10, speech: true)
        let noiseEnd = cursor
        feed(&capture, &cursor, samples: rate, speech: false)
        feed(&capture, &cursor, samples: rate, speech: true)
        let afterNoise = command(feed(&capture, &cursor, samples: rate, speech: false))
        precondition(afterNoise.startSample > noiseEnd)

        // Gaps, overlaps and an explicit reset invalidate the wake authorization.
        for delta: Int64 in [1_000, -1_000] {
            capture.reset(); cursor = 0
            feed(&capture, &cursor, samples: rate, speech: true)
            precondition(capture.wake(startSample: 0, endSample: rate))
            let event = capture.append(samples: pcm(start: cursor + delta, count: 512),
                                       startingAt: cursor + delta, isSpeech: true)
            guard case .discontinuity = event else { preconditionFailure("Expected discontinuity") }
            precondition(!capture.isActive)
            precondition(!capture.wake(startSample: 0, endSample: rate))
        }
        capture.reset(); cursor = 0
        feed(&capture, &cursor, samples: rate, speech: true)
        precondition(capture.wake(startSample: 0, endSample: rate))
        capture.reset()
        precondition(feed(&capture, &cursor, samples: rate, speech: true).isEmpty)

        // Reject an overlong request rather than executing a truncated sentence.
        capture.reset(); cursor = 0
        feed(&capture, &cursor, samples: rate, speech: true)
        precondition(capture.wake(startSample: 0, endSample: rate))
        let overlong = feed(&capture, &cursor, samples: 22 * rate, speech: true)
        precondition(overlong.count == 1)
        guard case .tooLong = overlong[0] else { preconditionFailure("Expected too-long rejection") }
        precondition(feed(&capture, &cursor, samples: rate, speech: false).isEmpty)

        // A discontinuity also discards a completed-but-not-yet-delivered replay command.
        capture.reset(); cursor = 0
        feed(&capture, &cursor, samples: 20_800, speech: true)
        feed(&capture, &cursor, samples: 12_800, speech: false)
        precondition(capture.wake(startSample: 0, endSample: 12_800))
        let interruptedReplay = capture.append(samples: [0], startingAt: cursor + 1, isSpeech: false)
        guard case .discontinuity = interruptedReplay else { preconditionFailure("Expected pending replay invalidation") }

        // Idle meetings and even large incoming packets cannot grow the three-second history.
        capture.reset(); cursor = 0
        feed(&capture, &cursor, samples: 300 * rate, speech: false, packetSize: 32_000)
        precondition(capture.bufferedSampleCount == 3 * Int(rate))
        precondition(!capture.wake(startSample: 0, endSample: rate), "Reject a wake outside retained audio")
        precondition(!capture.wake(startSample: cursor - 512, endSample: cursor + 512), "Reject future timestamps")
        precondition(!capture.wake(startSample: cursor, endSample: cursor), "Reject empty keyword ranges")
        print("Meeting KWS command capture, replay, endpoints, deadlines, discontinuity and buffer bounds passed")
        if let path = CommandLine.arguments.dropFirst().first { checkFixtures(path: path) }
    }

    static func checkFixtures(path: String) {
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        let fixtures = (try? JSONDecoder().decode([Fixture].self, from: data))
            ?? (try! JSONDecoder().decode(Fixtures.self, from: data)).cases
        for fixture in fixtures {
            if fixture.expected == "repeated" { continue } // Worker/bridge owns rearming between complete requests.
            precondition(fixture.sampleRate == Int(rate))
            var capture = MeetingWakeCommandCapture()
            var result = "none"
            var acceptedWake = false
            for frame in fixture.frames {
                let event = capture.append(samples: pcm(start: frame.startSample,
                                                        count: Int(frame.endSample - frame.startSample)),
                                           startingAt: frame.startSample, isSpeech: frame.isSpeech)
                if let event {
                    switch event {
                    case .command(let value):
                        _ = command([.command(value)])
                        result = "command"
                    case .timedOut: result = "timedOut"
                    case .tooLong: result = "tooLong"
                    case .discontinuity: result = "discontinuity"
                    }
                    break
                }
                if !acceptedWake, let hit = frame.hits.first {
                    let duration = max(0.2, min(3, (hit.timestamps.last ?? 1) - (hit.timestamps.first ?? 0)))
                    let wakeEnd = max(0, hit.hitEndSample - 2_560)
                    let wakeStart = max(fixture.frames.first!.startSample,
                                        max(hit.hitEndSample - 48_000, wakeEnd - Int64(duration * 16_000) - 3_200))
                    acceptedWake = capture.wake(startSample: wakeStart, endSample: wakeEnd)
                    print("Fixture \(fixture.name): KWS hit=\(hit.hitEndSample), wake=\(wakeStart)..<\(wakeEnd)")
                }
            }
            print("Fixture \(fixture.name): accepted=\(acceptedWake), event=\(result)")
            if fixture.expected == "noWake" {
                precondition(!acceptedWake && result == "none", fixture.name)
            } else if let expected = fixture.expected {
                precondition(result == expected, fixture.name)
            }
        }
    }
}
