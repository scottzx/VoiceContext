import Foundation

/// Decides whether the foreground transcription scheduler may submit work to
/// SenseVoice / Metal. Missing models leave durable jobs pending.
nonisolated struct TranscriptionAdmissionPolicy: Sendable {
    nonisolated enum Decision: Equatable, Sendable {
        case admit
        case deferInference(reason: String)
    }

    var thermalState: @Sendable () -> ProcessInfo.ThermalState
    var isModelReady: @Sendable () -> Bool

    nonisolated init(
        thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = {
            ProcessInfo.processInfo.thermalState
        },
        isModelReady: @escaping @Sendable () -> Bool = { true }
    ) {
        self.thermalState = thermalState
        self.isModelReady = isModelReady
    }

    nonisolated func evaluate() -> Decision {
        if !isModelReady() {
            return .deferInference(reason: "modelsNotReady")
        }
        return .admit
    }
}
