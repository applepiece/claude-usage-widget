import Foundation
import Testing
@testable import UsageKit

struct MenuUpdateTests {
    @Test func creditItemsKeepIdentityWhenOnlyBalancesDetailsOrOrderChange() throws {
        let now = Date(timeIntervalSince1970: 0)
        let before = try JSONDecoder().decode(CreditsResponse.self, from: Data(
            #"{"providers":[{"id":"a","label":"A","remaining":50,"granted":100},{"id":"b","label":"B","remaining":10,"granted":100}]}"#.utf8))
        let after = try JSONDecoder().decode(CreditsResponse.self, from: Data(
            #"{"providers":[{"id":"b","label":"Changed label","error":"unavailable"},{"id":"a","label":"A","remaining":5,"granted":100,"spend_source":"ledger_partial"}]}"#.utf8))
        for mode in [CreditsDisplay.providers, .total] {
            let first = CreditsMenuPresentation(providers: before.providers, display: mode, updatedAt: nil, now: now)
            let refreshed = CreditsMenuPresentation(providers: after.providers, display: mode, updatedAt: now, now: now)
            #expect(first.structure == refreshed.structure)
            #expect(first.totalAmount != refreshed.totalAmount)
            #expect(first.structure != CreditMenuStructure(display: mode, providerIDs: ["a"]))
            #expect(first.structure != CreditMenuStructure(display: mode, providerIDs: ["a", "b", "c"]))
        }
    }

    @Test @MainActor func unrelatedDefaultsDoNotInvalidateTrackedAccountRows() throws {
        let suite = "UsageKitTests.MenuUpdates." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults)
        var state = preferences.accountMenuState
        let unrelated: [String: Any] = [
            "pos": "{100, 200}", "minimized": true, "creditsDisplay": "off", "creditsWarnDays": 14,
            "barNumbers": false, "menuBarAlways": false, "barMetric": "five",
            "barAccounts": "all", "widgetAccounts": "primarySecondary",
        ]
        for (key, value) in unrelated {
            defaults.set(value, forKey: key)
            #expect(preferences.accountMenuState == state)
        }
        let relevant: [(String, Any)] = [
            ("barSlots", ["weekly", "weekly:Fable"]), ("primaryAccount", "a"),
            ("secondaryAccount", "b"), ("accountShortNames", ["a": "AAA"]),
        ]
        for (key, value) in relevant {
            defaults.set(value, forKey: key)
            #expect(preferences.accountMenuState != state)
            state = preferences.accountMenuState
        }
    }
}
