import Foundation
import CoreGraphics

@main
struct XiaolanFloatingGeometryChecks {
    static func main() {
        let phone = CGRect(x: 8, y: 103, width: 374, height: 651)
        let size = CGSize(width: 144, height: 44)
        let left = XiaolanFloatingGeometry.frame(in: phone, size: size, edge: .left, fraction: 0, keyboard: nil)!
        precondition(left.minX == phone.minX && left.minY == phone.minY)
        let right = XiaolanFloatingGeometry.frame(in: phone, size: size, edge: .right, fraction: 1, keyboard: nil)!
        precondition(right.maxX == phone.maxX && right.maxY == phone.maxY)
        let keyboard = CGRect(x: 0, y: 544, width: 390, height: 300)
        let lifted = XiaolanFloatingGeometry.frame(in: phone, size: size, edge: .right, fraction: 1, keyboard: keyboard)!
        precondition(lifted.maxY == keyboard.minY - 8 && !lifted.intersects(keyboard))
        let composer = CGRect(x: 0, y: 456, width: 390, height: 88)
        let aboveComposer = XiaolanFloatingGeometry.frame(in: phone, size: size, edge: .right, fraction: 1,
                                                          keyboard: keyboard, protected: [composer])!
        precondition(aboveComposer.maxY == composer.minY - 8)
        precondition(!aboveComposer.intersects(composer) && !aboveComposer.intersects(keyboard))
        let draggedAboveComposer = XiaolanFloatingGeometry.clamp(CGRect(x: 238, y: 710, width: 144, height: 44), to: phone,
                                                                 keyboard: keyboard, protected: [composer])!
        precondition(draggedAboveComposer.maxY == composer.minY - 8)
        let tallComposer = CGRect(x: 0, y: 130, width: 390, height: 414)
        precondition(XiaolanFloatingGeometry.frame(in: phone, size: size, edge: .right, fraction: 1,
                                                  keyboard: keyboard, protected: [tallComposer]) == nil)
        precondition(XiaolanFloatingGeometry.clamp(CGRect(x: 238, y: 710, width: 144, height: 44), to: phone,
                                                  keyboard: keyboard, protected: [tallComposer]) == nil)
        let floatingKeyboard = CGRect(x: 200, y: 544, width: 190, height: 240)
        let untouched = XiaolanFloatingGeometry.frame(in: phone, size: size, edge: .left, fraction: 1, keyboard: floatingKeyboard)!
        precondition(untouched.maxY == phone.maxY)
        let fullKeyboard = CGRect(x: 0, y: 120, width: 390, height: 724)
        precondition(XiaolanFloatingGeometry.frame(in: phone, size: size, edge: .right, fraction: 1, keyboard: fullKeyboard) == nil)
        let hidden = XiaolanFloatingGeometry.frame(in: phone, size: .zero, edge: .left, fraction: 0.5, keyboard: nil)!
        precondition(hidden.size == CGSize(width: 44, height: 44) && hidden.minX >= 8)
        let landscape = CGRect(x: 48, y: 60, width: 748, height: 226)
        let rotated = XiaolanFloatingGeometry.frame(in: landscape, size: size, edge: .right, fraction: 0.55, keyboard: nil)!
        precondition(landscape.contains(rotated))
        let small = CGRect(x: 8, y: 60, width: 304, height: 400)
        let largeType = XiaolanFloatingGeometry.frame(in: small, size: CGSize(width: 500, height: 80), edge: .right, fraction: 0.55, keyboard: nil)!
        precondition(small.contains(largeType) && largeType.width == small.width)
        precondition(XiaolanFloatingGeometry.frame(in: CGRect(x: 0, y: 0, width: 40, height: 40), size: size, edge: .left, fraction: 0, keyboard: nil) == nil)
        let dragged = XiaolanFloatingGeometry.clamp(CGRect(x: -90, y: 1000, width: 144, height: 44), to: phone, keyboard: keyboard)!
        precondition(phone.contains(dragged) && !dragged.intersects(keyboard))
        let normalized = XiaolanFloatingGeometry.fraction(centerY: rotated.midY, height: rotated.height, in: landscape)
        precondition(abs(normalized - 0.55) < 0.001)
        precondition(XiaolanFloatingGeometry.shouldTuck(centerX: 20, in: phone))
        precondition(XiaolanFloatingGeometry.shouldTuck(centerX: 380, in: phone))
        precondition(!XiaolanFloatingGeometry.shouldTuck(centerX: phone.midX, in: phone))
        precondition(XiaolanFloatingGeometry.edge(centerX: 20, in: phone) == .left)
        precondition(XiaolanFloatingGeometry.edge(centerX: 300, in: phone) == .right)
        print("xiaolan floating geometry checks passed")
    }
}
