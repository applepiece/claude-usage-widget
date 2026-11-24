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
        #expect(MenuFormatting.limitName(LimitInfo(kind: "session")) == "Session")
        #expect(MenuFormatting.limitName(LimitInfo(kind: "weekly_all")) == "Weekly")
        #expect(MenuFormatting.limitName(LimitInfo(kind: "weekly_scoped")) == "Weekly scoped")
        #expect(MenuFormatting.limitName(LimitInfo(kind: "weekly_scoped",
                                                  scope: LimitScope(model: LimitModel(displayName: "Sonnet")))) == "Weekly Sonnet")
        #expect(MenuFormatting.limitName(LimitInfo(kind: "weekly_scoped",
                                                  scope: LimitScope(model: LimitModel(displayName: "Fable")))) == "Weekly Fable")
        #expect(MenuFormatting.limitName(LimitInfo(kind: "weekly_scoped",
                                                  scope: LimitScope(model: LimitModel(displayName: "")))) == "Weekly scoped")
        #expect(MenuFormatting.limitName(LimitInfo(kind: "extra_usage")) == "Extra Usage")
        #expect(MenuFormatting.limitName(LimitInfo()) == "Usage limit")
    }

    @Test @MainActor func shortResetBoundariesAndLocale() throws {
        let now = try #require(parseISO("2026-10-23T16:20:00Z"))
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        func short(_ seconds: Double?, value: Double? = 15, locale: String = "en_GB") -> String {
            MenuFormatting.shortResetText(value: value, reset: seconds.map { now.addingTimeInterval($0) }, now: now,
                                          calendar: Calendar(identifier: .gregorian),
                                          locale: Locale(identifier: locale), timeZone: zone)
        }
        #expect(short(2 * 3600 + 59 * 60) == "2h 59m")
        #expect(short(60) == "1m")
        #expect(short(59) == "<1m")
        #expect(short(0) == "<1m")
        #expect(short(-60) == "<1m")
        #expect(short(3600) == "1h")
        #expect(short(86399) == "23h 59m")
        #expect(short(86400) == "Sat 16:20")
        #expect(short(nil, value: 0).isEmpty)
        #expect(short(nil).isEmpty)
        #expect(short(3600, value: nil).isEmpty)
        let us = short(86400, locale: "en_US")
        #expect(us.contains("Sat") && us.contains("4:20") && us.contains("PM"))
        #expect(short(86400, locale: "th_TH") == "Sat 16:20")
        let bangkok = try #require(TimeZone(secondsFromGMT: 7 * 3600))
        #expect(MenuFormatting.shortResetText(value: 15, reset: now.addingTimeInterval(86400), now: now,
                                              calendar: Calendar(identifier: .buddhist),
                                              locale: Locale(identifier: "th_TH"), timeZone: bangkok) == "Sat 23:20")
    }

    @Test func spokenResetHelp() {
        let now = Date(timeIntervalSince1970: 100_000)
        func help(_ seconds: Double?, value: Double? = 15) -> String {
            MenuFormatting.resetHelp(value: value, reset: seconds.map { now.addingTimeInterval($0) }, now: now)
        }
        #expect(help(2 * 3600 + 59 * 60) == "Resets in 2 hours 59 minutes")
        #expect(help(3660) == "Resets in 1 hour 1 minute")
        #expect(help(3600) == "Resets in 1 hour")
        #expect(help(60) == "Resets in 1 minute")
        #expect(help(59) == "Resets in under a minute")
        #expect(help(nil, value: 0) == "Not started")
        #expect(help(nil) == "Reset time unavailable")
        #expect(help(3600, value: nil) == "Not reported for this plan")
    }

    @Test @MainActor func fullAccountTooltip() throws {
        let now = try #require(parseISO("2026-10-23T12:00:00Z"))
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        var account = UsageAccount(id: "pho", label: "pho", plan: "max",
                                   fiveHour: LimitInfo(resetsAt: "2026-10-23T14:59:00Z", percent: 15),
                                   sevenDay: LimitInfo(resetsAt: "2026-10-24T16:20:00Z", percent: 82))
        func tooltip(_ account: UsageAccount) -> String {
            MenuFormatting.accountTooltip(account, now: now, calendar: Calendar(identifier: .gregorian),
                                          locale: Locale(identifier: "en_GB"), timeZone: zone)
        }
        let normal = "pho · Claude Max · Session 15%, resets in 2h 59m · Weekly 82%, resets Sat 16:20"
        #expect(tooltip(account) == normal)
        account.state = .stale
        account.fetchedAt = now.timeIntervalSince1970 - 720
        #expect(tooltip(account) == normal + " · Stale · Updated 12 min ago")
        account.fetchedAt = nil
        #expect(tooltip(account) == normal + " · Stale · Not updated yet")
        account.state = .ok
        account.provider = .codex
        account.plan = "pro_lite"
        account.fiveHour = LimitInfo(percent: 0)
        account.sevenDay = nil
        #expect(tooltip(account) == "pho · Codex Pro Lite · Session 0%, not started · Weekly not reported for this plan")
        account.fiveHour = LimitInfo(percent: 94.6, status: "rejected")
        #expect(tooltip(account) == "pho · Codex Pro Lite · Session 95%, reset time unavailable, limit reached · Weekly not reported for this plan")
        account.fiveHour = LimitInfo(resetsAt: "2026-10-23T12:00:30Z", percent: 15)
        #expect(tooltip(account) == "pho · Codex Pro Lite · Session 15%, resets in <1m · Weekly not reported for this plan")
    }

    @Test @MainActor func failedRowsAndRenewalTooltips() {
        let now = Date(timeIntervalSince1970: 100_000)
        var account = UsageAccount(id: "pho", label: "pho", plan: "max",
                                   fiveHour: LimitInfo(percent: 15), sevenDay: LimitInfo(percent: 82))
        #expect(MenuFormatting.failedRowText(.ok) == nil)
        #expect(MenuFormatting.failedRowText(.stale) == nil)
        account.state = .tokenRejected
        #expect(MenuFormatting.failedRowText(account.state) == "⚠︎ expired")
        #expect(MenuFormatting.accountTooltip(account, now: now) == "pho · Claude Max · Sign-in expired · Renew in Settings")
        account.state = .error
        #expect(MenuFormatting.failedRowText(account.state) == "⚠︎ error")
        #expect(MenuFormatting.accountTooltip(account, now: now) == "pho · Claude Max · Couldn't load usage · Renew in Settings")
    }

    @Test @MainActor func rejectedAccountWordingIsSignedOutOnlyForGemini() {
        let now = Date(timeIntervalSince1970: 100_000)
        for provider in Provider.allCases {
            let account = UsageAccount(id: "pho", label: "pho", state: .tokenRejected, provider: provider)
            let status = provider == .gemini ? "Signed out" : "Sign-in expired"
            #expect(MenuFormatting.rejectedAccountText(provider) == status)
            #expect(MenuFormatting.failedRowText(account.state, provider: provider) == (provider == .gemini ? "⚠︎ signed out" : "⚠︎ expired"))
            #expect(MenuFormatting.accountSubtitle(account, now: now) == status)
            #expect(MenuFormatting.accountTooltip(account, now: now) == "pho · \(account.providerName) · \(status) · Renew in Settings")
            #expect(MenuFormatting.failedRowText(.error, provider: provider) == "⚠︎ error")
            #expect(MenuFormatting.failedRowText(.ok, provider: provider) == nil)
            #expect(MenuFormatting.failedRowText(.stale, provider: provider) == nil)
        }
    }
}
