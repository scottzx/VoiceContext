import Foundation
import CoreGraphics

nonisolated enum XiaolanFloatingEdge: String { case left, right }

/// Coordinates belong to the current app scene, with navigation/safe-area space removed.
nonisolated enum XiaolanFloatingGeometry {
    static let hitSize: CGFloat = 44
    static let margin: CGFloat = 8

    static func frame(in bounds: CGRect, size: CGSize, edge: XiaolanFloatingEdge,
                      fraction: CGFloat, keyboard: CGRect?, protected: [CGRect] = []) -> CGRect? {
        guard bounds.width >= hitSize, bounds.height >= hitSize else { return nil }
        let size = CGSize(width: min(bounds.width, max(hitSize, size.width)),
                          height: min(bounds.height, max(hitSize, size.height)))
        let x = edge == .left ? bounds.minX : bounds.maxX - size.width
        let y = bounds.minY + (bounds.height - size.height) * min(1, max(0, fraction))
        return clamp(CGRect(origin: CGPoint(x: x, y: y), size: size), to: bounds, keyboard: keyboard, protected: protected)
    }

    static func clamp(_ frame: CGRect, to bounds: CGRect, keyboard: CGRect?, protected: [CGRect] = []) -> CGRect? {
        guard frame.width <= bounds.width, frame.height <= bounds.height else { return nil }
        var result = frame
        result.origin.x = min(max(result.minX, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.minY, bounds.minY), bounds.maxY - result.height)
        let obstacles = (keyboard.map { [$0] } ?? []) + protected.filter { !$0.isEmpty }
        // Clearing the keyboard can land inside the composer immediately above it.
        // Recheck each lifted position against every actual protected region.
        for _ in obstacles {
            guard let first = obstacles.filter({ result.intersects($0) }).map(\.minY).min() else { return result }
            let top = first - margin - result.height
            guard top >= bounds.minY else { return nil }
            result.origin.y = min(result.minY, top)
        }
        return obstacles.contains(where: { result.intersects($0) }) ? nil : result
    }

    static func fraction(centerY: CGFloat, height: CGFloat, in bounds: CGRect) -> CGFloat {
        let travel = bounds.height - height
        guard travel > 0 else { return 0.5 }
        return min(1, max(0, (centerY - height / 2 - bounds.minY) / travel))
    }

    static func edge(centerX: CGFloat, in bounds: CGRect) -> XiaolanFloatingEdge {
        centerX < bounds.midX ? .left : .right
    }

    static func shouldTuck(centerX: CGFloat, in bounds: CGRect) -> Bool {
        centerX <= bounds.minX + hitSize / 2 || centerX >= bounds.maxX - hitSize / 2
    }
}
