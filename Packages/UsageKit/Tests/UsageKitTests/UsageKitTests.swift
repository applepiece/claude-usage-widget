import AppKit
import Foundation
import Testing
@testable import UsageKit

struct UsageKitTests {
    @Test func providerTagsAndCollisions() {
        let accounts = [
            UsageAccount(id: "pho", label: "pho"),
            UsageAccount(id: "pro", label: "pro", provider: .codex),
        ]
        #expect(accountTags(accounts) == ["pho": "P", "pro": "›P"])
        #expect(accountTags([UsageAccount(id: "john", label: "John"),
                             UsageAccount(id: "jill", label: "Jill")]) == ["john": "JO", "jill": "JI"])
        let collisions = accounts + [UsageAccount(id: "phil", label: "phil"),
                                     UsageAccount(id: "duplicate", label: "pho"),
                                     UsageAccount(id: "empty", label: ""),
                                     UsageAccount(id: "empty2", label: "")]
        let tags = accountTags(collisions)
        #expect(tags["pho"] == "PH")
        #expect(tags["phil"] == "PHI")
        #expect(tags["pro"] == "›P")
        #expect(Set(tags.values).count == collisions.count)
    }

    @Test @MainActor func preferencesFallbacksAndShownAccounts() throws {
        let suite = "UsageKitTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults)
        let accounts = [UsageAccount(id: "first", label: "First"),
                        UsageAccount(id: "machine", label: "Machine", machineLogin: true),
                        UsageAccount(id: "saved", label: "Saved")]
        defaults.set("saved", forKey: "primaryAccount")
        #expect(preferences.primary(in: accounts)?.id == "saved")
        defaults.set("missing", forKey: "primaryAccount")
        #expect(preferences.primary(in: accounts)?.id == "machine")
        #expect(preferences.primary(in: [accounts[0], accounts[2]])?.id == "first")
        #expect(preferences.primary(in: []) == nil)
        defaults.set("machine", forKey: "secondaryAccount")
        #expect(preferences.secondary(in: accounts) == nil)
        defaults.set("first", forKey: "secondaryAccount")
        #expect(preferences.secondary(in: accounts)?.id == "first")
        for mode in BarAccounts.allCases {
            defaults.set(mode.rawValue, forKey: "barAccounts")
            let expected: [String]
            switch mode {
            case .primary: expected = ["machine"]
            case .primarySecondary: expected = ["machine", "first"]
            case .all: expected = ["first", "machine", "saved"]
            }
            #expect(preferences.shown(in: accounts).map(\.id) == expected)
        }
        defaults.set("both", forKey: "barMode")
        preferences.migrate()
        #expect(preferences.metric == .both)
        #expect(defaults.bool(forKey: "accountsV2Migrated"))
        defaults.set("five", forKey: "barMode")
        preferences.migrate()
        #expect(preferences.metric == .both)
    }

    @Test func validatedLimits() {
        for invalid in [Double.nan, .infinity, -.infinity, -0.1, 100.1] {
            #expect(LimitInfo(utilization: invalid, percent: 10).value == nil)
            #expect(LimitInfo(percent: invalid).value == nil)
        }
        #expect(LimitInfo(utilization: 0, percent: 100).value == 0)
        #expect(LimitInfo(utilization: 100, percent: 0).value == 100)
        #expect(LimitInfo(percent: 42).value == 42)
        #expect(LimitInfo().value == nil)
    }

    @Test func decodesCurrentAccountsAndUnknownState() throws {
        let url = try #require(Bundle.module.url(forResource: "accounts", withExtension: "json"))
        let response = try JSONDecoder().decode(AccountsResponse.self, from: Data(contentsOf: url))
        #expect(response.accounts.count == 3)
        #expect(response.fetchedAt == 1792480001)
        let machine = response.accounts[0], bridge = response.accounts[1], codex = response.accounts[2]
        #expect(machine.machineLogin && machine.provider == .claude)
        #expect(machine.limits?.first?.scope?.model?.displayName == "All models")
        #expect(machine.fiveHour?.value == 15)
        #expect(bridge.provider == .claude)
        #expect(bridge.sevenDay == nil)
        #expect(bridge.state == .error && bridge.failed)
        #expect(bridge.rawState == "future_state")
        #expect(codex.provider == .codex && codex.state == .stale)
        #expect(codex.quotaSource == "live")
        #expect(codex.usage.fetchedAt == codex.asOf)
        #expect(codex.info.provider == .codex)
        let info = try JSONDecoder().decode(AccountInfo.self, from: Data("{\"logged_in\":false}".utf8))
        #expect(info.provider == .claude)
        let unknown = try JSONDecoder().decode(AccountState.self, from: Data("\"future\"".utf8))
        #expect(unknown == .error)
    }

    @Test @MainActor func statusWidths() throws {
        let accounts = (0..<5).map { index in
            UsageAccount(id: String(index), label: ["pho", "kkpk", "mahidol", "pro", "edu"][index],
                         fiveHour: LimitInfo(utilization: 100), sevenDay: LimitInfo(utilization: 100),
                         provider: index < 3 ? .claude : .codex)
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for style in BarStyle.allCases {
                for metric in BarMetric.allCases {
                    for numbers in [false, true] {
                        for unavailable in [false, true] {
                            var sample = accounts
                            if unavailable {
                                sample[0].state = .tokenRejected
                                sample[4].sevenDay = nil
                            }
                            let image = StatusRenderer.image(accounts: sample, tags: accountTags(sample),
                                                             style: style, metric: metric, numbers: numbers,
                                                             appearance: appearance)
                            #expect(image.size.width < 160)
                            #expect(image.size.height == 22)
                        }
                    }
                }
            }
        }
    }

    @Test @MainActor func isoFractionsAndCalendarFormatting() throws {
        let whole = try #require(parseISO("2026-10-20T10:30:00Z"))
        let milli = try #require(parseISO("2026-10-20T10:30:00.123Z"))
        let micro = try #require(parseISO("2026-10-20T10:30:00.123456Z"))
        #expect(abs(milli.timeIntervalSince(whole) - 0.123) < 0.001)
        #expect(abs(micro.timeIntervalSince(whole) - 0.123456) < 0.001)
        #expect(parseISO("invalid") == nil)
        let calendar = Calendar(identifier: .gregorian)
        let zone = try #require(TimeZone(secondsFromGMT: 7 * 3600))
        #expect(fmtWhen(whole, now: whole, calendar: calendar, timeZone: zone) == "17:30")
        #expect(fmtWhen(whole.addingTimeInterval(86400), now: whole, calendar: calendar, timeZone: zone) == "TMRW 17:30")
        #expect(fmtWhen(whole.addingTimeInterval(172800), now: whole, calendar: calendar, timeZone: zone) == "THU 17:30")
        // UTC's next day is still today in the injected time zone.
        let nearMidnight = try #require(parseISO("2026-10-20T23:30:00Z"))
        #expect(fmtWhen(nearMidnight.addingTimeInterval(3600), now: nearMidnight,
                        calendar: calendar, timeZone: zone) == "07:30")
    }
}
