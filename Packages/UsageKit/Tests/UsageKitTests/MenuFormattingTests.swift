import Foundation
import Testing
@testable import UsageKit

struct MenuFormattingTests {
    @Test @MainActor func accountSelectionPreservesSwapAndNone() throws {
        let suite = "UsageKitTests.MenuSelection." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults)
        let accounts = [UsageAccount(id: "a", label: "A", machineLogin: true),
                        UsageAccount(id: "b", label: "B", provider: .codex),
                        UsageAccount(id: "c", label: "C")]
        preferences.setSecondary("b", in: accounts)
        preferences.makePrimary("b", in: accounts)
        #expect(preferences.primary(in: accounts)?.id == "b")
        #expect(preferences.secondary(in: accounts)?.id == "a")
        preferences.setSecondary("b", in: accounts)
        #expect(preferences.secondaryID == "a")
        preferences.makePrimary("c", in: accounts)
        #expect(preferences.secondaryID == "a")
        preferences.makePrimary("missing", in: accounts)
        preferences.setSecondary("missing", in: accounts)
        #expect(preferences.primaryID == "c")
        #expect(preferences.secondaryID == "a")
        preferences.setSecondary("none", in: accounts)
        #expect(preferences.secondary(in: accounts) == nil)
        preferences.makePrimary("a", in: accounts)
        #expect(preferences.secondaryID == "none")
    }

    @Test func planTitles() {
        for (raw, expected) in [("MAX", "Max"), (" pro ", "Pro"), ("team", "Team"),
                                ("EDU", "Edu"), ("pro_lite", "Pro Lite"), ("pro-lite", "Pro Lite"),
                                ("pro lite", "Pro Lite"), ("plus", "Plus")] {
            #expect(MenuFormatting.planTitle(raw) == expected)
        }
        for unknown in [nil, "", "unknown", "future_plan"] {
            #expect(MenuFormatting.planTitle(unknown) == nil)
        }
    }

    @Test func relativeResetBoundaries() throws {
        let now = Date(timeIntervalSince1970: 1_792_490_400)
        let calendar = Calendar(identifier: .gregorian)
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        func caption(_ seconds: Double?, value: Double? = 12) -> String {
            MenuFormatting.resetCaption(value: value, reset: seconds.map { now.addingTimeInterval($0) },
                                        now: now, calendar: calendar,
                                        locale: Locale(identifier: "en_GB"), timeZone: zone)
        }
        #expect(caption(3 * 3600 + 41 * 60) == "Resets in 3h 41m")
        #expect(caption(60) == "Resets in 1m")
        #expect(caption(59) == "Resets in under a minute")
        #expect(caption(-1) == "Resets in under a minute")
        #expect(caption(86399) == "Resets in 23h 59m")
        #expect(caption(nil, value: 0) == "Not started")
        #expect(caption(nil) == "Reset time unavailable")
        #expect(caption(3600, value: nil) == "Not reported for this plan")
        #expect(!caption(86400).contains("Resets in"))
    }

    @Test @MainActor func absoluteResetEnglishClockAndTimeZone() throws {
        let now = try #require(parseISO("2026-10-20T00:00:00Z"))
        let reset = try #require(parseISO("2026-10-23T02:59:00Z"))
        let zone = try #require(TimeZone(secondsFromGMT: 7 * 3600))
        let buddhist = Calendar(identifier: .buddhist)
        let thai = MenuFormatting.resetCaption(value: 8, reset: reset, now: now, calendar: buddhist,
                                               locale: Locale(identifier: "th_TH"), timeZone: zone)
        #expect(thai == "Resets Fri 09:59")
        let us = MenuFormatting.resetCaption(value: 8, reset: reset, now: now, calendar: buddhist,
                                             locale: Locale(identifier: "en_US"), timeZone: zone)
        #expect(us.contains("Fri") && us.contains("9:59") && us.contains("AM"))
        #expect(!us.contains("2569"))
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        #expect(MenuFormatting.resetCaption(value: 8, reset: reset, now: now,
                                            locale: Locale(identifier: "en_GB"), timeZone: utc) == "Resets Fri 02:59")
    }

    @Test func accountSubtitlesAndFreshness() {
        let now = Date(timeIntervalSince1970: 100_000)
        var account = UsageAccount(id: "test", label: "Test", plan: "max",
                                   fiveHour: LimitInfo(percent: 8), sevenDay: LimitInfo(percent: 86),
                                   fetchedAt: now.timeIntervalSince1970 - 720)
        #expect(MenuFormatting.accountSubtitle(account, now: now) == "Max · Session 8% · Weekly 86%")
        account.state = .stale
        #expect(MenuFormatting.accountSubtitle(account, now: now) == "Max · Session 8% · Weekly 86% · 12 min old")
        account.fiveHour = LimitInfo()
        account.sevenDay = nil
        #expect(MenuFormatting.accountSubtitle(account, now: now) == "Max · 12 min old")
        account.state = .tokenRejected
        #expect(MenuFormatting.accountSubtitle(account, now: now) == "Sign-in expired")
        account.state = .error
        #expect(MenuFormatting.accountSubtitle(account, now: now) == "Couldn't load usage")
        account.asOf = now.timeIntervalSince1970 - 30
        #expect(MenuFormatting.updated(since: MenuFormatting.timestamp(account), now: now) == "Updated just now")
        #expect(MenuFormatting.updated(since: now.addingTimeInterval(-60), now: now) == "Updated 1 min ago")
        #expect(MenuFormatting.updated(since: now.addingTimeInterval(-86400), now: now) == "Updated 1 day ago")
        #expect(MenuFormatting.updated(since: nil, now: now) == "Not updated yet")
    }

    @Test func limitNames() {
        #expect(MenuFormatting.limitName(LimitInfo(kind: "session")) == "Current session")
        #expect(MenuFormatting.limitName(LimitInfo(kind: "weekly_all")) == "Weekly · All models")
        #expect(MenuFormatting.limitName(LimitInfo(kind: "weekly_scoped")) == "Weekly · Scoped")
        #expect(MenuFormatting.limitName(LimitInfo(kind: "weekly_scoped",
                                                  scope: LimitScope(model: LimitModel(displayName: "Sonnet")))) == "Weekly · Sonnet")
        #expect(MenuFormatting.limitName(LimitInfo(kind: "extra_usage")) == "Extra Usage")
    }
}
