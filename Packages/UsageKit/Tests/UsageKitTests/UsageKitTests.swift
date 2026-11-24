import AppKit
import Foundation
import Testing
@testable import UsageKit

struct UsageKitTests {
    @Test func geminiDecodingAndScopedWeeklyMetric() throws {
        let data = Data("""
        {"id":"gemini-pho","label":"pho","provider":"gemini","source":"gemini",
         "machine_login":false,"expires_at":"2026-12-19","state":"ok",
         "five_hour":{"utilization":1,"status":"allowed","resets_at":"2026-11-24T15:15:06Z"},
         "seven_day":{"utilization":1,"status":"allowed","resets_at":"2026-12-01T10:15:06Z"},
         "limits":[{"percent":0,"status":"allowed","kind":"weekly_scoped","group":"Claude and GPT models",
                    "scope":{"model":{"display_name":"Claude and GPT models"}}}],
         "fetched_at":1795515306,"as_of":1795515306,"quota_source":"live"}
        """.utf8)
        let account = try JSONDecoder().decode(UsageAccount.self, from: data)
        #expect(account.provider == .gemini && account.providerName == "Gemini")
        #expect(account.isBridgeAccount && !account.isCodex && !account.machineLogin)
        #expect(account.info.provider == .gemini)
        #expect(account.expiresAt == "2026-12-19")
        #expect(account.fiveHour?.value == 1 && account.sevenDay?.value == 1)
        #expect(account.quotaSource == "live" && account.usage.fetchedAt == account.asOf)
        let metric = try #require(UsageMetric(raw: "weekly:Claude and GPT models"))
        #expect(metric.value(for: account)?.percent == 0)
        #expect(metric.limit(for: account)?.group == "Claude and GPT models")
        #expect(UsageMetric.available(in: [account]).contains(metric))
        let info = try JSONDecoder().decode(AccountInfo.self, from: Data("{\"logged_in\":true,\"provider\":\"gemini\"}".utf8))
        #expect(info.provider == .gemini)
    }

    @Test func geminiTagsKeepCollisionsWithinEachProvider() {
        let accounts = [
            UsageAccount(id: "claude-pho", label: "pho"),
            UsageAccount(id: "codex-pro", label: "pro", provider: .codex),
            UsageAccount(id: "gemini-pho", label: "pho", provider: .gemini),
            UsageAccount(id: "gemini-apple", label: "apple", provider: .gemini),
        ]
        #expect(accountTags(accounts) == ["claude-pho": "P", "codex-pro": "›P", "gemini-pho": "✦P", "gemini-apple": "✦A"])
        let collisions = accounts + [
            UsageAccount(id: "gemini-phil", label: "phil", provider: .gemini),
            UsageAccount(id: "gemini-duplicate", label: "pho", provider: .gemini),
        ]
        let tags = accountTags(collisions)
        #expect(tags["claude-pho"] == "P" && tags["codex-pro"] == "›P")
        #expect(tags["gemini-pho"] == "✦PH")
        #expect(tags["gemini-phil"] == "✦PHI")
        #expect(tags["gemini-duplicate"] == "✦PHO")
        #expect(tags["gemini-apple"] == "✦A")
        // Even a Claude label containing the Gemini marker cannot lengthen a Gemini tag.
        let marked = accounts + [UsageAccount(id: "marked-one", label: "✦P"),
                                 UsageAccount(id: "marked-two", label: "✦Q")]
        #expect(accountTags(marked)["gemini-pho"] == "✦P")
    }

    @Test func providerOrderingPreservesOrderWithinEachProvider() {
        let accounts = [
            UsageAccount(id: "gemini-apple", label: "apple", provider: .gemini),
            UsageAccount(id: "codex-edu", label: "edu", provider: .codex),
            UsageAccount(id: "pho", label: "pho"),
            UsageAccount(id: "gemini-pho", label: "pho", provider: .gemini),
            UsageAccount(id: "kkpk", label: "kkpk"),
            UsageAccount(id: "codex-pro", label: "pro", provider: .codex),
        ]
        #expect(accountsByProvider(accounts).map(\.id) == ["pho", "kkpk", "codex-edu", "codex-pro", "gemini-apple", "gemini-pho"])
        #expect(accountsByProvider([]).isEmpty)
        #expect(!accounts[2].isBridgeAccount)
    }

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
            for metric in BarMetric.allCases {
                for numbers in [false, true] {
                    for unavailable in [false, true] {
                        var sample = accounts
                        if unavailable {
                            sample[0].state = .tokenRejected
                            sample[4].sevenDay = nil
                        }
                        let title = StatusTitle(accounts: sample, metric: metric, numbers: numbers)
                        let text = StatusRenderer.attributedTitle(title)
                        let image = StatusRenderer.previewImage(title, appearance: appearance)
                        #expect(title.string.count <= 28)
                        #expect(text.string == title.string)
                        #expect(image.size.width < 160)
                        #expect(image.size.width >= 24 + ceil(text.size().width))
                        #expect(image.size.height == 24)
                        #expect(numbers ? !title.string.isEmpty : title.string.isEmpty)
                        let glyph = StatusRenderer.glyph()
                        #expect(glyph.isTemplate)
                        #expect(glyph.size == NSSize(width: 24, height: 17))
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
