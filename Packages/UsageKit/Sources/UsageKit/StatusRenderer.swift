import AppKit

/// AppKit presentation of the pure title model. The real button owns text color.
@MainActor
public enum StatusRenderer {
    public static func glyph() -> NSImage {
        let image = glyphImage(color: .black)
        image.isTemplate = true
        return image
    }

    private static func glyphImage(color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 24, height: 17), flipped: false) { rect in
            drawClawdGlyph(in: rect, color: color)
            return true
        }
    }

    public static func attributedTitle(_ title: StatusTitle) -> NSAttributedString {
        let pointSize = NSFont.menuBarFont(ofSize: 0).pointSize
        let regular = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .regular)
        let semibold = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .semibold)
        let text = NSMutableAttributedString(string: "")
        for (index, segment) in title.segments.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "  ", attributes: [.font: regular])) }
            text.append(NSAttributedString(string: segment.shortName, attributes: [.font: semibold]))
            text.append(NSAttributedString(string: " " + segment.value, attributes: [.font: regular]))
        }
        if title.hiddenCount > 0 {
            text.append(NSAttributedString(string: "  +\(title.hiddenCount)", attributes: [.font: regular]))
        }
        return text
    }

    public static func previewSize(_ title: StatusTitle) -> NSSize {
        let text = attributedTitle(title)
        return NSSize(width: 24 + (text.length == 0 ? 0 : 4 + ceil(text.size().width)), height: 24)
    }

    /// NSStatusBarButton has no offscreen initializer. Use its actual glyph
    /// geometry and attributed text, adding labelColor only on this canvas.
    public static func drawPreview(_ title: StatusTitle, in rect: NSRect) {
        // Composite the glyph separately so its transparent eyes cannot clear
        // the preview strip underneath it.
        glyphImage(color: .labelColor).draw(in: NSRect(x: rect.minX, y: rect.midY - 8.5, width: 24, height: 17))
        let text = NSMutableAttributedString(attributedString: attributedTitle(title))
        text.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: text.length))
        text.draw(at: NSPoint(x: rect.minX + 28, y: rect.midY - text.size().height / 2))
    }

    public static func previewImage(_ title: StatusTitle, appearance: NSAppearance) -> NSImage {
        NSImage(size: previewSize(title), flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance { drawPreview(title, in: rect) }
            return true
        }
    }
}
