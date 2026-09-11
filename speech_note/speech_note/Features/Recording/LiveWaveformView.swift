import SwiftUI

/// A clean, native iOS audio waveform visualizer supporting live recording metering and playback states.
struct LiveWaveformView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Normalized input level between 0.0 and 1.0 (from microphone metering or audio power)
    var inputLevel: Float? = nil
    /// Whether recording is actively capturing
    var isRecording: Bool = true
    /// Color of active waveform bars
    var tintColor: Color = .red
    /// Number of visible vertical bars
    var barCount: Int = 24
    /// Height of the waveform visualizer
    var maxHeight: CGFloat = 36

    // Multipliers to create organic-looking natural speech audio waves
    private let barMultipliers: [CGFloat] = [
        0.3, 0.45, 0.6, 0.8, 1.0, 0.9, 0.75, 0.85,
        1.1, 0.95, 0.7, 0.85, 1.05, 0.9, 0.75, 0.6,
        0.8, 0.95, 0.7, 0.55, 0.4, 0.3, 0.25, 0.2
    ]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                let height = barHeight(at: index)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tintColor.opacity(barOpacity(at: index)))
                    .frame(width: 3, height: height)
                    .animation(
                        reduceMotion ? .none : .spring(response: 0.15, dampingFraction: 0.65),
                        value: height
                    )
            }
        }
        .frame(height: maxHeight)
        .accessibilityLabel(isRecording ? "麦克风声波输入" : "音频波形")
        .accessibilityValue(inputLevel != nil ? "\(Int((inputLevel ?? 0) * 100))%" : "无输入")
    }

    private func barHeight(at index: Int) -> CGFloat {
        let minHeight: CGFloat = 4
        guard isRecording else {
            // Idle or playback static baseline
            let base = barMultipliers[index % barMultipliers.count]
            return minHeight + (maxHeight - minHeight) * 0.2 * base
        }

        guard let level = inputLevel, level > 0 else {
            // Quiet baseline when no active sound
            return minHeight
        }

        let multiplier = barMultipliers[index % barMultipliers.count]
        let scaled = CGFloat(level) * multiplier
        let target = minHeight + (maxHeight - minHeight) * min(max(scaled, 0.05), 1.0)
        return max(minHeight, min(target, maxHeight))
    }

    private func barOpacity(at index: Int) -> Double {
        if !isRecording {
            return 0.4
        }
        guard let level = inputLevel, level > 0.05 else {
            return 0.35
        }
        let mult = barMultipliers[index % barMultipliers.count]
        return min(1.0, 0.5 + Double(level) * 0.5 * mult)
    }
}
