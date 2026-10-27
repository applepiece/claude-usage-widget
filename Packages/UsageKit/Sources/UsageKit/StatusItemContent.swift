import Foundation

/// Everything the status button shows, as a plain value. The app assigns the
/// button's title and tool tip only when this value changes.
///
/// Why: re-assigning the button's image or title makes NSStatusItem redraw its
/// replicant snapshot, and that redraw sets the button's appearance, which fires
/// `effectiveAppearance` KVO. Redrawing on every such notification kept the main
/// thread at 100% for 41 hours on mac-mini (27 Oct 2026).
public struct StatusItemContent: Equatable, Sendable {
    public let title: StatusTitle
    public let toolTip: String

    /// - Parameters:
    ///   - shown: the accounts the status button shows (already filtered by preferences).
    ///   - anyAccounts: whether any account exists at all; `false` reads "No accounts".
    public init(shown: [UsageAccount], anyAccounts: Bool, shortNames: [String: String] = [:],
                metric: BarMetric = .max, numbers: Bool = true) {
        title = StatusTitle(accounts: shown, shortNames: shortNames, metric: metric, numbers: numbers)
        toolTip = Self.toolTip(shown: shown, anyAccounts: anyAccounts)
    }

    public static func toolTip(shown: [UsageAccount], anyAccounts: Bool) -> String {
        guard anyAccounts else { return "Claude Usage · No accounts" }
        return shown.map {
            "\($0.label) · \($0.providerName): 5H \(percentage($0.fiveHour)), WK \(percentage($0.sevenDay)) · \($0.rawState)"
        }.joined(separator: "\n")
    }

    public static func percentage(_ limit: LimitInfo?) -> String {
        limit?.value.map { "\(Int($0.rounded()))%" } ?? "–"
    }
}
