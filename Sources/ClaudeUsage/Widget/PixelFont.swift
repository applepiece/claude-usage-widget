import Cocoa
import os

@MainActor
func registerPixelFont() {
    guard let url = Bundle.main.url(forResource: "PressStart2P-Regular", withExtension: "ttf", subdirectory: "Fonts") else {
        Logger(subsystem: "com.heng.claude-usage-widget", category: "Font").error("Bundled pixel font is missing")
        return
    }
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
}

@MainActor
func pixelFont(_ size: CGFloat) -> NSFont {
    NSFont(name: "PressStart2P-Regular", size: size)
        ?? NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
}

