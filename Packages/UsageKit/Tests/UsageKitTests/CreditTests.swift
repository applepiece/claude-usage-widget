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
        #expect(response.providers.map(\.providerType) == ["anthropic", "openai"])
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
        let utc = TimeZone(secondsFromGMT: 0)!
        func warning(_ remaining: Double, _ expiry: String? = nil) -> Bool {
            CreditFormatting.warning(remaining: remaining, granted: 100, expiry: expiry, now: now, timeZone: utc)
        }
        #expect(warning(19.99))
        #expect(!warning(20))
        #expect(warning(100, "1970-01-08T23:59:59Z"))
        #expect(!warning(100, "1970-01-09T00:00:00Z"))
        #expect(!warning(100, "1969-12-31T00:00:00Z"))
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

    private func provider(granted: Double = 111, remaining: Double = 90.08, partial: Bool = false,
                          staleDays: Int = 0, expiry: String? = "2026-11-28T00:00:00Z") -> CreditProvider {
        CreditProvider(id: "openai", label: "OpenAI API", remaining: remaining, granted: granted,
                       spendSource: partial ? .ledgerPartial : .ledger, anchorAt: "2026-11-21T00:00:00Z",
                       nextExpiry: expiry.map { CreditExpiry(date: $0, amount: 28.66) },
                       console: "https://example.com", staleDays: staleDays)
    }

    @Test func zeroGrantWithoutExpiryShowsAmountWithoutFillOrWarning() {
        let now = Date(timeIntervalSince1970: 1_795_219_200)
        let row = CreditRowPresentation(provider(granted: 0, expiry: nil), updatedAt: now, now: now)
        #expect(row.amount == "$90.08")
        #expect(row.fraction == 0)
        #expect(row.annotation.isEmpty)
        #expect(!row.showsMeter && !row.warning)
        #expect(!CreditFormatting.warning(remaining: 0, granted: 0, expiry: nil, now: now))
    }

    @Test func partialQualifierIsSharedByTitleTooltipAndAccessibility() {
        let now = Date(timeIntervalSince1970: 1_795_219_200)
        let row = CreditRowPresentation(provider(partial: true), updatedAt: now, now: now)
        #expect(row.amount == "≤$90.08")
        // MenuBuilder uses detail for both its tooltip and accessibility label.
        #expect(row.detail.contains("≤$90.08"))
        #expect(CreditFormatting.amountLeft(199.95, partial: true) == "≤$199.95 left")
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
        #expect(row.amount == "—" && row.annotation == "invalid grant")
        #expect(row.unavailable && row.fraction == 0)
        #expect(!row.showsMeter && !row.warning)
        #expect(!row.detail.contains("$"))
        #expect(response.providers[1].remaining == 90.08)
    }

    @Test func multipleOrganizationsDecodeTypesAndLabelsInResponseOrder() throws {
        let response = try JSONDecoder().decode(CreditsResponse.self, from: Data("""
        {"providers":[
        {"id":"anthropic","type":"anthropic","label":"Claude API · kkpk","remaining":199.95,"granted":200},
        {"id":"anthropic_pho","type":"anthropic","label":"Claude API · pho","remaining":200,"granted":200},
        {"id":"openai","type":"openai","label":"OpenAI API","remaining":90.08,"granted":111}]}
        """.utf8))
        #expect(response.providers.map(\.id) == ["anthropic", "anthropic_pho", "openai"])
        #expect(response.providers.map(\.providerType) == ["anthropic", "anthropic", "openai"])
        #expect(response.providers.map(\.label) == ["Claude API · kkpk", "Claude API · pho", "OpenAI API"])
        #expect(response.providers[1].type == "anthropic")
        let now = Date()
        let rows = response.providers.map { CreditRowPresentation($0, updatedAt: now, now: now) }
        #expect(rows[0].detail.hasPrefix("Claude · kkpk · $199.95"))
        #expect(rows[1].detail.hasPrefix("Claude · pho · $200.00"))
    }

    @Test func explicitTypeOverridesIdentifierAndLegacyResponsesRemainCompatible() throws {
        let explicit = try JSONDecoder().decode(CreditProvider.self, from: Data(
            #"{"id":"anthropic","type":"openai","label":"Custom API"}"#.utf8))
        #expect(explicit.providerType == "openai")
        #expect(explicit.glyphProvider == .codex)
        let legacy = try JSONDecoder().decode(CreditProvider.self, from: Data(
            #"{"id":"anthropic","label":"Claude API"}"#.utf8))
        #expect(legacy.type == nil && legacy.providerType == "anthropic")
        #expect(legacy.glyphProvider == nil)
        let custom = CreditProvider(id: "org A / promo", type: "anthropic", label: "Custom Claude",
                                    remaining: 200, granted: 200, anchorAt: "2026-11-21T00:00:00Z",
                                    console: "https://example.com")
        #expect(custom.providerType == "anthropic")
        #expect(custom.glyphProvider == .claude)
    }

    @Test func qaSamplesIncludeTwoClaudeOrganizationsAndOpenAI() {
        let now = Date(timeIntervalSince1970: 1_795_219_200)
        let providers = CreditSamples.providers(now: now)
        #expect(providers.count == 3)
        #expect(providers.map(\.id) == ["anthropic", "anthropic_pho", "openai"])
        #expect(providers.map(\.providerType) == ["anthropic", "anthropic", "openai"])
        #expect(providers.map(\.glyphProvider) == [.claude, .claude, .codex])
        #expect(providers.map(\.label) == ["Claude API · kkpk", "Claude API · pho", "OpenAI API"])
        let rows = providers.map { CreditRowPresentation($0, updatedAt: now, now: now) }
        #expect(rows.map(\.warning) == [false, true, true])
        #expect(rows.allSatisfy { $0.showsMeter })
        #expect(rows[1].amount == "≤$24.00")
        #expect(rows[1].warningReason == .lowBalance(percent: 12))
        #expect(rows[2].warningReason == .expiry(days: 2, amount: 28.66))
        let section = CreditsMenuPresentation(providers: providers, display: .providers, updatedAt: now, now: now)
        #expect(section.totalAmount == "≤$313.60 left")
        #expect(section.warning == "OpenAI: $28.66 expires in 2 days · +1 more")
    }

    @Test func absentOrUnknownTypeChoosesNeutralGlyphRegardlessOfIdentifier() throws {
        for id in ["anthropic", "openai", "anthropic_pho", "unknown"] {
            for type in [nil, "unsupported"] as [String?] {
                var fields = ["id": id, "label": id, "error": "invalid type"]
                fields["type"] = type
                let provider = try JSONDecoder().decode(CreditProvider.self, from: JSONSerialization.data(withJSONObject: fields))
                #expect(provider.glyphProvider == nil)
                #expect(provider.type == type)
            }
        }
    }

    @Test func shortLabelsRemoveOnlyTheAPIWord() {
        for (label, short) in [
            ("Claude API · kkpk", "Claude · kkpk"),
            ("OpenAI API", "OpenAI"),
            ("My Credits", "My Credits"),
            ("CAPITAL Credits", "CAPITAL Credits"),
            (" My Credits ", " My Credits "),
            ("API", "API"),
            (" API ", "API"),
            ("", "API credits"),
            (" \t\n", "API credits"),
        ] {
            #expect(CreditRowPresentation.shortLabel(label) == short)
        }
    }

    @Test func sectionTotalExcludesErrorsAndQualifiesAnyPartialLedger() throws {
        let providers = try JSONDecoder().decode(CreditsResponse.self, from: Data("""
        {"providers":[
        {"id":"a","label":"Claude API · kkpk","remaining":199.52,"granted":200},
        {"id":"b","label":"Claude API · pho","remaining":200,"granted":200},
        {"id":"c","label":"OpenAI API","remaining":90.07,"granted":111},
        {"id":"error","label":"Broken","remaining":999,"granted":1000,"error":"invalid grant"},
        {"id":"missing","label":"Missing balance"}]}
        """.utf8)).providers
        let now = Date(timeIntervalSince1970: 0)
        let exact = CreditsMenuPresentation(providers: providers, display: .providers, updatedAt: now, now: now)
        #expect(abs(exact.totalRemaining - 489.59) < 0.0001)
        #expect(exact.totalAmount == "$489.59 left · 2 unavailable")
        #expect(exact.rows.suffix(2).allSatisfy { $0.amount == "—" && $0.fraction == 0 && !$0.warning })
        let partial = provider(granted: 0, remaining: 0, partial: true, expiry: nil)
        let estimated = CreditsMenuPresentation(providers: providers + [partial], display: .providers, updatedAt: now, now: now)
        #expect(estimated.totalAmount == "≤$489.59 left · 2 unavailable")
        let failedPartial = try JSONDecoder().decode(CreditProvider.self, from: Data(
            #"{"id":"partial","label":"Partial","spend_source":"ledger_partial","error":"unavailable"}"#.utf8))
        let failed = CreditsMenuPresentation(providers: [failedPartial], display: .providers, updatedAt: now, now: now)
        #expect(failed.totalAmount == "— · 1 unavailable")
    }

    @Test func meterVisibilityRequiresHealthyPositiveGrant() throws {
        let now = Date(timeIntervalSince1970: 0)
        let missing = try JSONDecoder().decode(CreditProvider.self, from: Data(
            #"{"id":"missing","label":"Missing"}"#.utf8))
        let error = CreditProvider(id: "error", label: "Error", remaining: 100, granted: 100,
                                   anchorAt: "1970-01-01T00:00:00Z", console: "https://example.com", error: "unavailable")
        for invalid in [missing, error, provider(granted: 0), provider(granted: -1)] {
            #expect(!CreditRowPresentation(invalid, updatedAt: now, now: now).showsMeter)
        }
        #expect(CreditRowPresentation(provider(remaining: 0), updatedAt: now, now: now).showsMeter)
        #expect(CreditRowPresentation(provider(), updatedAt: now, now: now).showsMeter)
    }

    @Test func totalsDistinguishZeroUnavailableAndContributingUpperBounds() throws {
        let now = Date(timeIntervalSince1970: 0)
        let failed = try JSONDecoder().decode(CreditProvider.self, from: Data(
            #"{"id":"error","label":"Error","spend_source":"ledger_partial","error":"invalid grant"}"#.utf8))
        let healthy = provider(granted: 100, remaining: 10, expiry: nil)
        let some = CreditsMenuPresentation(providers: [healthy, failed], display: .providers, updatedAt: now, now: now)
        #expect(some.totalAmount == "$10.00 left · 1 unavailable")
        let all = CreditsMenuPresentation(providers: [failed, failed], display: .providers, updatedAt: now, now: now)
        #expect(all.totalAmount == "— · 2 unavailable")
        let zero = CreditsMenuPresentation(providers: [provider(remaining: 0, expiry: nil)], display: .total, updatedAt: now, now: now)
        #expect(zero.totalAmount == "$0.00 left")
        let upper = CreditsMenuPresentation(providers: [provider(partial: true), failed], display: .total, updatedAt: now, now: now)
        #expect(upper.totalAmount == "≤$90.08 left · 1 unavailable")
    }

    @Test func partialExpiryWarningUsesUpperBoundQualifier() throws {
        let now = try #require(parseISO("2026-11-21T12:00:00Z"))
        let section = CreditsMenuPresentation(providers: [provider(partial: true, expiry: "2026-11-22T12:00:00Z")],
                                              display: .providers, updatedAt: now, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(section.rows.first?.amount == "≤$90.08")
        #expect(section.totalAmount == "≤$90.08 left")
        #expect(section.warning == "OpenAI: ≤$28.66 expires tomorrow")
    }

    @Test func billingConsoleRequiresHTTPSAndAHost() {
        for value in [nil, "", "http://example.com", "javascript:alert(1)", "https://", "/billing"] as [String?] {
            #expect(CreditFormatting.consoleURL(value) == nil)
        }
        #expect(CreditFormatting.consoleURL("https://example.com/billing")?.absoluteString == "https://example.com/billing")
        #expect(provider().consoleURL?.scheme == "https")
    }

    @Test func expiredGrantsHavePastDetailAndNoExpiryWarning() throws {
        let now = try #require(parseISO("2026-11-21T12:00:00Z"))
        let locale = Locale(identifier: "en_GB")
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        for expiry in ["2026-11-20T12:00:00Z", "2026-11-21T11:59:59Z"] {
            let row = CreditRowPresentation(provider(expiry: expiry), updatedAt: now, now: now, locale: locale, timeZone: utc)
            #expect(!row.warning)
            #expect(row.detailItems.contains(expiry.contains("20T") ? "Expired 20 Nov" : "Expired 21 Nov"))
            #expect(!row.detailItems.contains { $0.hasPrefix("Next expiry") })
        }
        let future = CreditRowPresentation(provider(expiry: "2026-11-21T12:00:01Z"), updatedAt: now, now: now, timeZone: utc)
        #expect(future.warningReason == .expiry(days: 0, amount: 28.66))
        let low = CreditRowPresentation(provider(granted: 100, remaining: 12, expiry: "2026-11-20T12:00:00Z"),
                                       updatedAt: now, now: now, timeZone: utc)
        #expect(low.warningReason == .lowBalance(percent: 12))
    }

    @Test func displayModesPlaceRowsAndHideWarningsWhenOff() {
        let now = Date(timeIntervalSince1970: 0)
        let providers = [provider(granted: 100, remaining: 12, expiry: nil)]
        let expanded = CreditsMenuPresentation(providers: providers, display: .providers, updatedAt: now, now: now)
        #expect(expanded.showsSection && expanded.mainRows.count == 1 && expanded.submenuRows.isEmpty)
        let total = CreditsMenuPresentation(providers: providers, display: .total, updatedAt: now, now: now)
        #expect(total.showsSection && total.mainRows.isEmpty && total.submenuRows.count == 1)
        #expect(total.submenuRows.first?.amount == expanded.mainRows.first?.amount)
        #expect(total.submenuRows.first?.detailItems == expanded.mainRows.first?.detailItems)
        #expect(total.totalAmount == expanded.totalAmount)
        #expect(total.warning == "OpenAI: 12% left")
        #expect(total.warning == expanded.warning)
        let off = CreditsMenuPresentation(providers: providers, display: .off, updatedAt: now, now: now)
        #expect(!off.showsSection && off.mainRows.isEmpty && off.submenuRows.isEmpty && off.warning == nil)
        for mode in CreditsDisplay.allCases {
            let empty = CreditsMenuPresentation(providers: [], display: mode, updatedAt: now, now: now)
            #expect(!empty.showsSection && empty.rows.isEmpty && empty.warning == nil)
        }
    }

    @Test func amountColumnMeasuresWholeStringsInBothMenuModes() throws {
        let providers = try JSONDecoder().decode(CreditsResponse.self, from: Data("""
        {"providers":[
        {"id":"a","label":"Claude API · kkpk","remaining":199.52,"granted":200},
        {"id":"b","label":"Claude API · pho","remaining":24,"granted":200,"spend_source":"ledger_partial"},
        {"id":"c","label":"OpenAI API","remaining":90.08,"granted":111},
        {"id":"error","label":"Broken","error":"unavailable"}]}
        """.utf8)).providers
        let widths: [String: Double] = ["$199.52": 58, "≤$24.00": 67, "$90.08": 49, "—": 14]
        let now = Date(timeIntervalSince1970: 0)
        for mode in [CreditsDisplay.providers, .total] {
            let presentation = CreditsMenuPresentation(providers: providers, display: mode, updatedAt: now, now: now)
            var measured: [String] = []
            let width = presentation.amountColumnWidth {
                measured.append($0)
                return widths[$0] ?? 0
            }
            #expect(measured == ["$199.52", "≤$24.00", "$90.08", "—"])
            #expect(width == 67)
            // An error placeholder still participates if its rendered width is largest.
            #expect(presentation.amountColumnWidth { $0 == "—" ? 80 : widths[$0] ?? 0 } == 80)
        }
        let empty = CreditsMenuPresentation(providers: [], display: .providers, updatedAt: now, now: now)
        #expect(empty.amountColumnWidth { _ in 100 } == 0)
        let off = CreditsMenuPresentation(providers: providers, display: .off, updatedAt: now, now: now)
        #expect(off.amountColumnWidth { _ in 100 } == 0)
    }

    @Test func detailItemsIncludeAvailableDataInOrder() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-21T12:00:00Z"))
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let provider = CreditProvider(id: "a", label: "Claude API · kkpk", remaining: 199.52, granted: 200,
                                      spentSinceAnchor: 0.48, anchorAt: "2026-11-21T00:00:00Z",
                                      nextExpiry: CreditExpiry(date: "2026-12-09T00:00:00Z", amount: 199.52),
                                      console: "https://example.com", extra: 9.07)
        let row = CreditRowPresentation(provider, updatedAt: now.addingTimeInterval(-300), now: now,
                                        locale: Locale(identifier: "en_GB"), timeZone: utc)
        #expect(row.detailItems == [
            "Granted $200.00", "Used since 21 Nov  $0.48", "Next expiry 9 Dec  $199.52",
            "Purchased balance $9.07", "Source: bridge ledger", "Updated 5 min ago",
        ])
        #expect(!row.amount.contains("\n"))
        #expect(row.detail.contains("Granted $200.00"))
    }

    @Test func detailsOmitMissingInvalidAndZeroExtraData() throws {
        let now = Date(timeIntervalSince1970: 0)
        for fields in [
            #"{"id":"a","label":"A","error":"invalid grant"}"#,
            #"{"id":"a","label":"A","spent_since_anchor":2,"anchor_at":"bad","next_expiry":{"date":"bad","amount":1},"extra":0}"#,
            #"{"id":"a","label":"A","spent_since_anchor":2,"extra":-1}"#,
            #"{"id":"a","label":"A","anchor_at":"2026-11-21T00:00:00Z"}"#,
        ] {
            let provider = try JSONDecoder().decode(CreditProvider.self, from: Data(fields.utf8))
            let row = CreditRowPresentation(provider, updatedAt: nil, now: now)
            #expect(row.detailItems.isEmpty)
            #expect(row.amount == "—")
        }
        let costs = try JSONDecoder().decode(CreditProvider.self, from: Data(
            #"{"id":"a","label":"A","spend_source":"costs_api","extra":0}"#.utf8))
        #expect(CreditRowPresentation(costs, updatedAt: nil, now: now).detailItems == ["Source: OpenAI costs API"])
        #expect(CreditRowPresentation(provider(partial: true), updatedAt: nil, now: now)
            .detailItems.contains("Source: bridge ledger"))
    }

    @Test(arguments: [3, 7, 14]) func expiryWindowUsesCalendarDaysAndPreference(days: Int) throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-21T12:00:00Z"))
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let iso = ISO8601DateFormatter()
        // Use the selected window, including the whole last calendar day.
        let inside = CreditRowPresentation(provider(expiry: iso.string(from: now.addingTimeInterval(Double(days) * 86400 + 3600))),
                                           updatedAt: now, now: now, warnDays: days, timeZone: utc)
        #expect(inside.warningReason == .expiry(days: days, amount: 28.66))
        let outside = CreditRowPresentation(provider(expiry: iso.string(from: now.addingTimeInterval(Double(days + 1) * 86400))),
                                            updatedAt: now, now: now, warnDays: days, timeZone: utc)
        #expect(!outside.warning)
    }

    @Test func warningTextUsesRelativeExpiryAndLowBalanceForms() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-21T12:00:00Z"))
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        for (days, text) in [(0, "today"), (1, "tomorrow"), (7, "in 7 days")] {
            let expiry = ISO8601DateFormatter().string(from: now.addingTimeInterval(Double(days) * 86400))
            let section = CreditsMenuPresentation(providers: [provider(expiry: expiry)], display: .providers,
                                                  updatedAt: now, now: now, locale: Locale(identifier: "en_GB"), timeZone: utc)
            #expect(section.warning == "OpenAI: $28.66 expires " + text)
        }
        let low = CreditProvider(id: "pho", label: "Claude API · pho", remaining: 12, granted: 100,
                                 anchorAt: "2026-11-21T00:00:00Z", console: "https://example.com")
        let section = CreditsMenuPresentation(providers: [low], display: .providers, updatedAt: now, now: now)
        #expect(section.warning == "Claude · pho: 12% left")
        let healthy = CreditsMenuPresentation(providers: [provider(expiry: nil)], display: .providers, updatedAt: now, now: now)
        #expect(healthy.warning == nil)
    }

    @Test func warningChoosesSoonestExpiryThenLowestBalanceAndCountsOtherProviders() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-21T12:00:00Z"))
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let low = provider(granted: 100, remaining: 1, expiry: nil)
        let sooner = provider(expiry: "2026-11-22T12:00:00Z")
        let later = provider(expiry: "2026-11-24T12:00:00Z")
        for (providers, suffix) in [([later, sooner], " · +1 more"), ([low, later, sooner], " · +2 more")] {
            let section = CreditsMenuPresentation(providers: providers, display: .providers,
                                                  updatedAt: now, now: now, timeZone: utc)
            #expect(section.warning == "OpenAI: $28.66 expires tomorrow" + suffix)
        }
        let lessUrgent = provider(granted: 100, remaining: 12, expiry: nil)
        let balances = CreditsMenuPresentation(providers: [lessUrgent, low], display: .total, updatedAt: now, now: now)
        #expect(balances.warning == "OpenAI: 1% left · +1 more")
    }

    @Test func expiryWarningUsesLocalDayAcrossMidnightAndDaylightSaving() throws {
        let iso = ISO8601DateFormatter()
        let now = try #require(iso.date(from: "2026-10-31T23:30:00-07:00"))
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let tomorrow = CreditRowPresentation(provider(expiry: "2026-11-01T23:30:00-08:00"),
                                            updatedAt: now, now: now, timeZone: zone)
        #expect(tomorrow.warningReason == .expiry(days: 1, amount: 28.66))
        let lastDay = CreditRowPresentation(provider(expiry: "2026-11-03T23:59:59-08:00"),
                                           updatedAt: now, now: now, warnDays: 3, timeZone: zone)
        #expect(lastDay.warningReason == .expiry(days: 3, amount: 28.66))
        let outside = CreditRowPresentation(provider(expiry: "2026-11-04T00:00:00-08:00"),
                                           updatedAt: now, now: now, warnDays: 3, timeZone: zone)
        #expect(!outside.warning)
    }

    @Test @MainActor func displayPreferencesMigrateIndependentlyOfAccountMigration() throws {
        let suite = "UsageKitTests.CreditPreferences." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults)
        #expect(preferences.creditsDisplay == .providers && preferences.showAPICredits)
        defaults.set(true, forKey: "showAPICredits")
        #expect(preferences.creditsDisplay == .providers)
        defaults.set(false, forKey: "showAPICredits")
        #expect(preferences.creditsDisplay == .off)
        defaults.set(true, forKey: "accountsV2Migrated")
        preferences.migrate()
        #expect(defaults.string(forKey: "creditsDisplay") == "off")
        for mode in CreditsDisplay.allCases {
            defaults.set(mode.rawValue, forKey: "creditsDisplay")
            preferences.migrate()
            #expect(preferences.creditsDisplay == mode)
            #expect(preferences.showAPICredits == (mode != .off))
        }
        defaults.set("invalid", forKey: "creditsDisplay")
        #expect(preferences.creditsDisplay == .providers)
        defaults.set(42, forKey: "creditsDisplay")
        #expect(preferences.creditsDisplay == .providers)
    }

    @Test @MainActor func warningPreferenceDefaultsAndRejectsUnsupportedDays() throws {
        let suite = "UsageKitTests.CreditWarningPreferences." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults)
        #expect(preferences.creditsWarnDays == 7)
        for days in [3, 7, 14] {
            defaults.set(days, forKey: "creditsWarnDays")
            #expect(preferences.creditsWarnDays == days)
        }
        for days in [-1, 0, 1, 4, 8, 15, 100] {
            defaults.set(days, forKey: "creditsWarnDays")
            #expect(preferences.creditsWarnDays == 7)
        }
        for invalid in ["invalid", "3", 3.5] as [Any] {
            defaults.set(invalid, forKey: "creditsWarnDays")
            #expect(preferences.creditsWarnDays == 7)
        }
    }
}
