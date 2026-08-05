import Foundation

/// The only entry point for GPU-backed work. Recording is intentionally not
/// behind this gate, so an app lifecycle transition can never stop audio.
actor InferenceLifecycleGate {
    enum Rejection: Error, Equatable {
        case appIsBackgrounded
    }

    private var acceptsMetalWork = true
    private var submittedMetalWork = 0

    func enteredBackground() {
        acceptsMetalWork = false
    }

    func enteredForeground() {
        acceptsMetalWork = true
    }

    func beginMetalWork() throws {
        guard acceptsMetalWork else { throw Rejection.appIsBackgrounded }
        submittedMetalWork += 1
    }

    func metrics() -> Metrics {
        Metrics(acceptsMetalWork: acceptsMetalWork, submittedMetalWork: submittedMetalWork)
    }

    struct Metrics: Equatable, Sendable {
        let acceptsMetalWork: Bool
        let submittedMetalWork: Int
    }
}
