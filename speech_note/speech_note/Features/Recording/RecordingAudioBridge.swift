import Foundation

/// Optional host routing. The standalone recorder retains its original audio
/// behavior; the fused app supplies one owner for all AVAudioSession mutations.
nonisolated public enum RecordingAudioBridge {
    public struct Handlers: Sendable {
        public let capture: @Sendable (UUID) throws -> Void
        public let release: @Sendable (UUID) -> Void
        public let playback: @Sendable () -> Bool
        public let releasePlayback: @Sendable () -> Void

        public init(capture: @escaping @Sendable (UUID) throws -> Void,
                    release: @escaping @Sendable (UUID) -> Void,
                    playback: @escaping @Sendable () -> Bool,
                    releasePlayback: @escaping @Sendable () -> Void) {
            self.capture = capture
            self.release = release
            self.playback = playback
            self.releasePlayback = releasePlayback
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: Handlers?

    public static func install(_ handlers: Handlers) {
        lock.withLock { installed = handlers }
    }

    static var handlers: Handlers? { lock.withLock { installed } }
}
