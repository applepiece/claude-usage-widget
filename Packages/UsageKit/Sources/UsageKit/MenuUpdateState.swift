import Foundation

/// Balance and warning changes can refresh native items without replacing their identities.
public struct CreditMenuStructure: Equatable, Sendable {
    public let display: CreditsDisplay
    private let providerIDs: Set<String>

    public init(display: CreditsDisplay, providerIDs: [String]) {
        self.display = display
        self.providerIDs = Set(providerIDs)
    }
}

/// Only preferences that affect account rows should rebuild a tracked account menu.
public struct AccountMenuState: Equatable, Sendable {
    let slots: [UsageMetric]
    let primaryID: String?
    let secondaryID: String
    let shortNames: [String: String]
}
