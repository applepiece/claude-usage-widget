import Foundation
import Testing
@testable import UsageKit

struct CreditTests {
    @Test func responseDecodesPublicFieldsAndMissingConfig() throws {
        let data = Data("""
        {"providers":[{"id":"anthropic","label":"Claude API","remaining":199.95,"granted":200,
        "spent_since_anchor":0.05,"spend_source":"ledger","anchor_at":"2026-11-21T04:50:00Z",
        "next_expiry":{"date":"2026-12-09T00:00:00Z","amount":200},"console":"https://example.com",
        "stale_days":0,"note":"","extra":9.07},
        {"id":"openai","label":"OpenAI API","remaining":5,"granted":100,"spent_since_anchor":85,
        "spend_source":"costs_api","anchor_at":"2026-11-21T04:45:00Z","next_expiry":null,
        "console":"https://example.com","stale_days":1,"note":null}],"updated_at":1795236600}
        """.utf8)
        let response = try JSONDecoder().decode(CreditsResponse.self, from: data)
        #expect(response.providers.count == 2)
        #expect(response.providers[0].extra == 9.07)
        #expect(response.providers[0].nextExpiry?.amount == 200)
        #expect(response.providers[1].spendSource == .costsAPI)
        #expect(response.providers[1].nextExpiry == nil)
        #expect(response.providers[1].extra == nil)
        #expect(response.updatedAt == 1795236600)
        let missing = try JSONDecoder().decode(CreditsResponse.self, from: Data(#"{"providers":[]}"#.utf8))
        #expect(missing.providers.isEmpty && missing.updatedAt == nil)
    }

    @Test func amountsHaveExactlyTwoDecimals() {
        let locale = Locale(identifier: "en_GB")
        #expect(CreditFormatting.amountLeft(199.95, locale: locale) == "$199.95 left")
        #expect(CreditFormatting.amountLeft(200, locale: locale) == "$200.00 left")
        #expect(CreditFormatting.amountLeft(0.0051, locale: locale) == "$0.01 left")
        #expect(CreditFormatting.amountLeft(-1, locale: locale) == "$0.00 left")
    }

    @Test func subtitlesUseLocalShortDatesAndTimeZone() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let expiry = CreditExpiry(date: "2026-12-09T00:00:00.000Z", amount: 200)
        #expect(CreditFormatting.subtitle(granted: 200, expiry: expiry, locale: Locale(identifier: "en_GB"),
                                           timeZone: utc) == "of $200 · $200 expires 9 Dec")
        #expect(CreditFormatting.subtitle(granted: 200, expiry: expiry, locale: Locale(identifier: "en_US"),
                                           timeZone: utc) == "of $200 · $200 expires Dec 9")
        let thai = CreditFormatting.subtitle(granted: 200, expiry: expiry, locale: Locale(identifier: "th_TH"), timeZone: utc)
        #expect(thai.contains("ธ.ค."))
        let west = try #require(TimeZone(secondsFromGMT: -8 * 3600))
        #expect(CreditFormatting.subtitle(granted: 199.95, expiry: expiry, locale: Locale(identifier: "en_GB"),
                                           timeZone: west) == "of $199.95 · $200 expires 8 Dec")
        #expect(CreditFormatting.subtitle(granted: 200, expiry: nil) == "of $200")
        #expect(CreditFormatting.subtitle(granted: 200, expiry: CreditExpiry(date: "bad", amount: 100)) == "of $200")
    }

    @Test func fractionsClampAndWarningsRespectBoundaries() {
        #expect(CreditFormatting.fraction(remaining: 250, granted: 200) == 1)
        #expect(CreditFormatting.fraction(remaining: -1, granted: 200) == 0)
        #expect(CreditFormatting.fraction(remaining: 1, granted: 0) == 0)
        #expect(CreditFormatting.fraction(remaining: .nan, granted: 200) == 0)
        #expect(CreditFormatting.fraction(remaining: 50, granted: 200) == 0.25)
        let now = Date(timeIntervalSince1970: 0)
        func warning(_ remaining: Double, _ expiry: String? = nil) -> Bool {
            CreditFormatting.warning(remaining: remaining, granted: 100, expiry: expiry, now: now)
        }
        #expect(warning(9.99))
        #expect(!warning(10))
        #expect(warning(100, "1970-01-04T00:00:00Z"))
        #expect(!warning(100, "1970-01-04T00:00:01Z"))
        #expect(warning(100, "1969-12-31T00:00:00Z"))
        #expect(!warning(100, "bad"))
    }

    @Test @MainActor func visibilityDefaultsOnAndPersists() throws {
        let suite = "UsageKitTests.Credits." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(Preferences(defaults).showAPICredits)
        defaults.set(false, forKey: "showAPICredits")
        #expect(!Preferences(defaults).showAPICredits)
    }

    @Test func expiringPartIsSeparateFromTotalGrant() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let expiry = CreditExpiry(date: "2026-11-28T00:00:00Z", amount: 28.67)
        #expect(CreditFormatting.subtitle(granted: 111, expiry: expiry, locale: Locale(identifier: "en_GB"),
                                           timeZone: utc) == "of $111 · $28.67 expires 28 Nov")
        let dateOnly = CreditExpiry(date: "2026-11-28", amount: 28.67)
        #expect(CreditFormatting.subtitle(granted: 111, expiry: dateOnly, locale: Locale(identifier: "en_GB"),
                                           timeZone: utc) == "of $111 · $28.67 expires 27 Nov")
    }

    private func provider(granted: Double = 111, partial: Bool = false, staleDays: Int = 0) -> CreditProvider {
        CreditProvider(id: "openai", label: "OpenAI API", remaining: 90.08, granted: granted,
                       spendSource: partial ? .ledgerPartial : .ledger, anchorAt: "2026-11-21T00:00:00Z",
                       nextExpiry: CreditExpiry(date: "2026-11-28T00:00:00Z", amount: 28.67),
                       console: "https://example.com", staleDays: staleDays)
    }

    @Test func zeroGrantShowsOnlyAmountWithoutMeterOrWarning() {
        let now = Date(timeIntervalSince1970: 1_795_219_200)
        let row = CreditRowPresentation(provider(granted: 0), updatedAt: now, now: now)
        #expect(row.amount == "$90.08 left")
        #expect(row.subtitle.isEmpty)
        #expect(row.annotation.isEmpty)
        #expect(!row.showsMeter && !row.warning)
        #expect(!CreditFormatting.warning(remaining: 0, granted: 0, expiry: "1970-01-01T00:00:00Z", now: now))
    }

    @Test func partialQualifierIsSharedByTitleTooltipAndAccessibility() {
        let now = Date(timeIntervalSince1970: 1_795_219_200)
        let row = CreditRowPresentation(provider(partial: true), updatedAt: now, now: now)
        #expect(row.amount == "≤ $90.08 left")
        // MenuBuilder uses detail for both its tooltip and accessibility label.
        #expect(row.detail.contains("≤ $90.08 left"))
        #expect(CreditFormatting.amountLeft(199.95, partial: true) == "≤ $199.95 left")
    }

    @Test func weekOldAnchorAddsBalanceDateAndThirtyMinuteFailuresAreStale() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-27T00:00:00Z"))
        let locale = Locale(identifier: "en_GB")
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let fresh = CreditRowPresentation(provider(staleDays: 6), updatedAt: now, now: now, locale: locale, timeZone: utc)
        #expect(fresh.annotation.isEmpty)
        let old = CreditRowPresentation(provider(staleDays: 7), updatedAt: now, now: now, locale: locale, timeZone: utc)
        #expect(old.annotation == "balance from 21 Nov")
        #expect(old.detail.contains("balance from 21 Nov"))
        let elapsed = CreditRowPresentation(provider(staleDays: 6), updatedAt: now, now: now.addingTimeInterval(86400),
                                            locale: locale, timeZone: utc)
        #expect(elapsed.annotation.contains("balance from 21 Nov"))
        #expect(!CreditFormatting.isStale(updatedAt: now, now: now.addingTimeInterval(1799)))
        let stale = CreditRowPresentation(provider(), updatedAt: now, now: now.addingTimeInterval(1800))
        #expect(stale.stale)
        #expect(stale.annotation == "Balance update overdue")
        #expect(stale.detail.contains("Balance update overdue"))
    }

    @Test func failedFetchAndUnreadableConfigRetainSnapshotUntilSuccess() throws {
        let now = Date(timeIntervalSince1970: 100)
        var snapshot = CreditSnapshot(providers: [provider()], updatedAt: now)
        snapshot.receive(nil, now: now.addingTimeInterval(1800))
        #expect(snapshot.updatedAt == now)
        #expect(snapshot.providers.first?.remaining == 90.08)
        #expect(CreditFormatting.isStale(updatedAt: snapshot.updatedAt, now: now.addingTimeInterval(1800)))
        let unreadable = try JSONDecoder().decode(CreditsResponse.self, from: Data(
            #"{"providers":[],"error":"config unreadable"}"#.utf8))
        snapshot.receive(unreadable, now: now.addingTimeInterval(3600))
        #expect(snapshot.providers.count == 1 && snapshot.updatedAt == now)
        let empty = try JSONDecoder().decode(CreditsResponse.self, from: Data(#"{"providers":[]}"#.utf8))
        snapshot.receive(empty, now: now.addingTimeInterval(3601))
        #expect(snapshot.providers.isEmpty)
        #expect(snapshot.updatedAt == now.addingTimeInterval(3601))
        #expect(!CreditFormatting.isStale(updatedAt: snapshot.updatedAt, now: now.addingTimeInterval(3601)))
    }

    @Test func providerErrorDecodesWithoutNumbersAndPreservesHealthyRows() throws {
        let response = try JSONDecoder().decode(CreditsResponse.self, from: Data("""
        {"providers":[{"id":"anthropic","label":"Claude API","error":"invalid grant"},
        {"id":"openai","label":"OpenAI API","remaining":90.08,"granted":111,
        "spent_since_anchor":0,"spend_source":"ledger_partial","anchor_at":"2026-11-21T00:00:00Z",
        "console":"https://example.com","stale_days":0}]}
        """.utf8))
        #expect(response.providers.count == 2)
        let broken = response.providers[0]
        #expect(broken.error == "invalid grant")
        #expect(broken.remaining == nil && broken.granted == nil && broken.extra == nil)
        let row = CreditRowPresentation(broken, updatedAt: Date(), now: Date())
        #expect(row.amount == "Unavailable" && row.annotation == "invalid grant")
        #expect(!row.showsMeter && !row.warning)
        #expect(!row.detail.contains("$"))
        #expect(response.providers[1].remaining == 90.08)
    }
}
