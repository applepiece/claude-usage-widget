import AppKit

// Shared geometry keeps the status glyph and account avatar in sync.
@MainActor public func drawClawdGlyph(in rect: NSRect, color: NSColor,
                    eyeColor: NSColor? = nil) {
    let scale = min(rect.width / 20, rect.height / 14)
    let x0 = rect.midX - 10 * scale
    let y0 = rect.midY - 7 * scale
    func fill(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
        NSRect(x: x0 + x * scale, y: y0 + y * scale,
               width: width * scale, height: height * scale).fill()
    }

    color.setFill()
    fill(4, 4, 12, 10)
    fill(1, 8, 3, 3); fill(16, 8, 3, 3)
    fill(4, 0, 2, 4); fill(7, 0, 2, 4)
    fill(11, 0, 2, 4); fill(14, 0, 2, 4)
    if let eyeColor {
        eyeColor.setFill()
    } else {
        NSGraphicsContext.current?.compositingOperation = .clear
    }
    fill(6, 10, 2, 2); fill(11, 10, 2, 2)
    NSGraphicsContext.current?.compositingOperation = .sourceOver
}

