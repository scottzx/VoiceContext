# DEBUG REPORT — Long recording detail and launch crash

- **Symptom:** Opening the two-hour recording exited the app after several seconds. After historical jobs began recovering, subsequent cold launches exited immediately.
- **Root cause:** Two independent unbounded resource paths were present. The detail timeline eagerly created and prepared one `AVAudioPlayer` per physical chunk (114 players for the two-hour recording). Historical recordings also contained legacy five-minute chunks; launch recovery sent the complete five-minute PCM buffer through speech analysis and then ASR, causing repeated iOS `SIGKILL (9)` termination. The affected job reached 16 attempts.
- **Fix:** The timeline now stores lightweight URL/duration items and lazily owns at most one player. Speech analysis is bounded to one-minute windows, VAD utterances are preserved as separate ASR inputs, and continuous inputs are hard-capped at 25 seconds before Metal inference.
- **Evidence:** The old timeline regression reported 114 resident players. On-device console reproduction showed `SIGKILL (9)` before the bounded pipeline. After bounding the pipeline, the same historical job completed and the app stayed alive through cold launch, detail navigation, and the final 15-second process check.
- **Regression tests:** `RecordingCoreTests.longTimelineDoesNotKeepOneAudioPlayerPerChunkResident`, `speech_noteTests.senseVoicePreservesBoundedVADUtterancesAsSeparateMetalInputs`, `speech_noteTests.senseVoiceBoundsLegacyFiveMinuteChunksBeforeSpeechAnalysis`, and `speech_noteTests.senseVoiceHardCapsContinuousSpeechBelowTheModelLimit`.
- **Full suite:** 66 passed, 0 failed, 0 skipped.
- **Related:** Historical backfill must not assume physical chunks were recorded with the current one-minute segment duration.
- **Status:** DONE
