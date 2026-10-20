import Cocoa

if CommandLine.arguments.count >= 2, CommandLine.arguments[1].hasPrefix("--preview-") {
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    exit(renderPreview(kind: CommandLine.arguments[1], path: CommandLine.arguments[2],
                       dark: CommandLine.arguments.contains("--dark"),
                       signedOut: CommandLine.arguments.contains("--signed-out"),
                       two: CommandLine.arguments.contains("--two")))
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
