import Cocoa
import UsageKit
import os

if CommandLine.arguments.count >= 2, CommandLine.arguments[1].hasPrefix("--preview-") {
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    exit(renderPreview(kind: CommandLine.arguments[1], path: CommandLine.arguments[2],
                       dark: CommandLine.arguments.contains("--dark"),
                       signedOut: CommandLine.arguments.contains("--signed-out"),
                       two: CommandLine.arguments.contains("--two")))
}
let app = NSApplication.shared
let qa = QAOptions(arguments: CommandLine.arguments)
let preferences: Preferences
if qa.enabled {
    guard let defaults = UserDefaults(suiteName: "ClaudeUsage.qa") else {
        Logger(subsystem: "com.heng.claude-usage-widget", category: "QA").error("Cannot create QA defaults suite")
        exit(1)
    }
    defaults.removePersistentDomain(forName: "ClaudeUsage.qa")
    qa.apply(to: defaults)
    preferences = Preferences(defaults)
} else { preferences = Preferences() }
let delegate = AppDelegate(preferences: preferences, qa: qa)
app.delegate = delegate
app.run()
