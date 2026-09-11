import Foundation

struct AudioInputMetrics: Equatable, Sendable {
    let rmsDecibels: Float
    let peakDecibels: Float

    nonisolated static func from(samples: UnsafeBufferPointer<Float>) -> AudioInputMetrics? {
        guard !samples.isEmpty else { return nil }
        let meanSquare = samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(samples.count)
        let peak = samples.reduce(Float.zero) { max($0, abs($1)) }
        return AudioInputMetrics(
            rmsDecibels: decibels(for: sqrt(meanSquare)),
            peakDecibels: decibels(for: peak)
        )
    }

    nonisolated static func from(samples: [Float]) -> AudioInputMetrics {
        guard let metrics = samples.withUnsafeBufferPointer({ from(samples: $0) }) else {
            return AudioInputMetrics(rmsDecibels: -120, peakDecibels: -120)
        }
        return metrics
    }

    /// Maps the visible meter's documented -60...0 dBFS range to 0...1.
    nonisolated var displayLevel: Float {
        min(1, max(0, (rmsDecibels + 60) / 60))
    }

    private nonisolated static func decibels(for amplitude: Float) -> Float {
        20 * log10(max(amplitude, 0.000_001))
    }
}
