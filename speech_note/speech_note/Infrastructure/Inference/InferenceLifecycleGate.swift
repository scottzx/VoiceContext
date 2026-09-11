import Foundation

/// The only entry point for GPU-backed work. Recording is intentionally not
/// behind this gate, so an app lifecycle transition can never stop audio.
///
/// Global in-flight Metal work is capped at 1. Callers must pair every
/// successful `beginMetalWork()` with `endMetalWork()`.
actor InferenceLifecycleGate {
    static let maxInFlightMetalWork = 1

    enum Rejection: Error, Equatable {
        case appIsBackgrounded
        case metalBusy
    }

    private var acceptsMetalWork = true
    private var inFlightMetalWork = 0
    private var submittedMetalWork = 0
    private var peakInFlightMetalWork = 0

    func enteredBackground() {
        acceptsMetalWork = false
    }

    func enteredForeground() {
        acceptsMetalWork = true
    }

    func beginMetalWork() throws {
        guard acceptsMetalWork else { throw Rejection.appIsBackgrounded }
        guard inFlightMetalWork < Self.maxInFlightMetalWork else { throw Rejection.metalBusy }
        inFlightMetalWork += 1
        submittedMetalWork += 1
        peakInFlightMetalWork = max(peakInFlightMetalWork, inFlightMetalWork)
    }

    func endMetalWork() {
        guard inFlightMetalWork > 0 else { return }
        inFlightMetalWork -= 1
    }

    func metrics() -> Metrics {
        Metrics(
            acceptsMetalWork: acceptsMetalWork,
            submittedMetalWork: submittedMetalWork,
            inFlightMetalWork: inFlightMetalWork,
            peakInFlightMetalWork: peakInFlightMetalWork
        )
    }

    struct Metrics: Equatable, Sendable {
        let acceptsMetalWork: Bool
        let submittedMetalWork: Int
        let inFlightMetalWork: Int
        let peakInFlightMetalWork: Int
    }
}
