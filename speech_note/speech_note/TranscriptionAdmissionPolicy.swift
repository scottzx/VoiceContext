import Foundation

/// Decides whether the foreground transcription scheduler may submit work to
/// SenseVoice / Metal. Thermal pauses and purchase locks must never reach the
/// GPU admission gate.
nonisolated struct TranscriptionAdmissionPolicy: Sendable {
    nonisolated enum Decision: Equatable, Sendable {
        case admit
        case deferInference(reason: String)
        case lockedPendingPurchase
    }

    var thermalState: @Sendable () -> ProcessInfo.ThermalState
    var isPurchaseLocked: @Sendable () -> Bool

    nonisolated init(
        thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = {
            ProcessInfo.processInfo.thermalState
        },
        isPurchaseLocked: @escaping @Sendable () -> Bool = { false }
    ) {
        self.thermalState = thermalState
        self.isPurchaseLocked = isPurchaseLocked
    }

    nonisolated func evaluate() -> Decision {
        if isPurchaseLocked() {
            return .lockedPendingPurchase
        }
        switch thermalState() {
        case .serious, .critical:
            return .deferInference(reason: "deferredUntilThermalImproves")
        case .nominal, .fair:
            return .admit
        @unknown default:
            return .admit
        }
    }
}
