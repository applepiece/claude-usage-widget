import Foundation
import Testing
@testable import UsageKit

struct UsageMetricTests {
    @Test func rawValuesRoundTripAndRejectUnknownOrEmptyModels() {
        let metrics: [UsageMetric] = [.session, .weekly, .weeklyModel("Fable"), .weeklyModel("Custom Model"), .extraUsage]
        #expect(metrics.map(\.raw) == ["session", "weekly", "weekly:Fable", "weekly:Custom Model", "extra"])
        for metric in metrics { #expect(UsageMetric(raw: metric.raw) == metric) }
        for raw in ["", "five", "Weekly", "weekly:", "weekly: \t\n", "extra_usage", "monthly:Fable"] {
            #expect(UsageMetric(raw: raw) == nil)
        }
        #expect(UsageMetric(raw: "weekly: Fable ")?.raw == "weekly:Fable")
        #expect(Set([UsageMetric.weeklyModel("Fable"), .weeklyModel("fable")]).count == 1)
    }

    @Test func titlesAndShortTitles() {
        let metrics: [UsageMetric] = [.session, .weekly, .weeklyModel("Fable"), .extraUsage]
        #expect(metrics.map(\.title) == ["Session", "Weekly", "Weekly Fable", "Extra usage"])
        #expect(metrics.map(\.shortTitle) == ["5h", "Week", "Fable", "Extra"])
    }

    @Test func modelColorKeysAreDistinctAndCaseInsensitive() {
        let models: [UsageMetric] = [.weeklyModel("Fable"), .weeklyModel("Opus"),
                                     .weeklyModel("Sonnet"), .weeklyModel("Other")]
        #expect(models.map(\.colorKey) == [.teal, .pink, .blue, .brown])
        #expect(Set(models.map(\.colorKey)).count == 4)
        for model in models {
            #expect(UsageMetric.weeklyModel(model.shortTitle.uppercased()).colorKey == model.colorKey)
        }
        #expect(UsageMetric.session.colorKey == .orange)
        #expect(UsageMetric.weekly.colorKey == .purple)
        #expect(UsageMetric.extraUsage.colorKey == .green)
    }

    @Test func widgetLabelFallsBackFromFullResetToDayThenTitle() {
        let metric = UsageMetric.weeklyModel("Fable")
        let measure: (String) -> Double = { Double($0.count) }
        for (width, expected) in [(15, "FABLE THU 09:53"), (14, "FABLE THU"),
                                  (9, "FABLE THU"), (8, "FABLE"), (5, "FABLE")] {
            #expect(metric.widgetLabel(reset: "THU 09:53", availableWidth: Double(width), measure: measure) == expected)
        }
        #expect(metric.widgetLabel(reset: "09:53", availableWidth: 10, measure: measure) == "FABLE")
        #expect(UsageMetric.extraUsage.widgetLabel(reset: "THU 09:53", availableWidth: 9, measure: measure) == "EXTRA THU")
    }

    @Test func widgetLabelUsesInjectedPointMeasurements() {
        // A wider W prevents a character-count heuristic from choosing an overlapping label.
        let measure: (String) -> Double = { text in
            text.reduce(0) { $0 + ($1 == "W" ? 9 : 5) }
        }
        let metric = UsageMetric.weeklyModel("Fable")
        #expect(metric.widgetLabel(reset: "WED 09:53", availableWidth: 48, measure: measure) == "FABLE")
        #expect(metric.widgetLabel(reset: "WED 09:53", availableWidth: 49, measure: measure) == "FABLE WED")
        #expect(metric.widgetLabel(reset: "WED 09:53", availableWidth: 79, measure: measure) == "FABLE WED 09:53")
    }

    @Test func widgetLabelsPreserveDefaultResetTextTagsAndStatus() {
        let measure: (String) -> Double = { Double($0.count) }
        #expect(UsageMetric.session.widgetLabel(reset: "12:53", availableWidth: 20, measure: measure) == "12:53")
        #expect(UsageMetric.weekly.widgetLabel(reset: "THU 09:53", availableWidth: 20, measure: measure) == "THU 09:53")
        #expect(UsageMetric.weekly.widgetLabel(reset: "THU 09:53", accountTag: "P", availableWidth: 20, measure: measure) == "P THU 09:53")
        #expect(UsageMetric.weeklyModel("Fable").widgetLabel(reset: "THU 09:53", accountTag: "P", availableWidth: 11, measure: measure) == "FABLE P THU")
        #expect(UsageMetric.session.widgetLabel(reset: "SIGN IN", availableWidth: 20, measure: measure) == "SIGN IN")
        #expect(UsageMetric.weeklyModel("Fable").widgetLabel(reset: "SIGN IN", availableWidth: 9, measure: measure) == "FABLE")
    }

    @Test func widgetLabelNeverExceedsSpaceReservedBeforePercentage() {
        let measure: (String) -> Double = { Double($0.count) }
        let metric = UsageMetric.weeklyModel("Unusually Long Model Name")
        for width in 0...40 {
            let label = metric.widgetLabel(reset: "THU 09:53", availableWidth: Double(width), measure: measure)
            #expect(measure(label) <= Double(width))
        }
        #expect(UsageMetric.weeklyModel("Fable").widgetLabel(reset: "THU 09:53", availableWidth: 4, measure: measure) == "FAB…")
        #expect(metric.widgetLabel(reset: "THU 09:53", availableWidth: 0, measure: measure).isEmpty)
    }

    private func account() -> UsageAccount {
        UsageAccount(id: "local", label: "Local", machineLogin: true, limits: [
            LimitInfo(resetsAt: "2026-11-23T03:00:00Z", kind: "session", percent: 15),
            LimitInfo(resetsAt: "2026-11-28T03:00:00.125Z", kind: "weekly_all", percent: 82),
            LimitInfo(kind: "weekly_scoped", percent: 41, scope: LimitScope(model: LimitModel(displayName: "FABLE"))),
            LimitInfo(resetsAt: "bad", kind: "extra_usage", percent: 0),
        ])
    }

    @Test func resolvesEveryMetricAndCaseInsensitiveModelNames() throws {
        let account = account()
        #expect(UsageMetric.session.value(for: account)?.percent == 15)
        #expect(UsageMetric.session.value(for: account)?.resetsAt == ISO8601DateFormatter().date(from: "2026-11-23T03:00:00Z"))
        let weekly = try #require(UsageMetric.weekly.value(for: account))
        #expect(weekly.percent == 82 && weekly.resetsAt != nil)
        #expect(UsageMetric.weeklyModel("fable").value(for: account)?.percent == 41)
        #expect(UsageMetric.weeklyModel("Sonnet").value(for: account) == nil)
        #expect(UsageMetric.extraUsage.value(for: account)?.percent == 0)
        #expect(UsageMetric.extraUsage.value(for: account)?.resetsAt == nil)
    }

    @Test func legacyWindowsTakePrecedenceAndMissingOrInvalidDataStaysMissing() {
        var local = account()
        local.fiveHour = LimitInfo(utilization: 7)
        local.sevenDay = LimitInfo(percent: 12)
        #expect(UsageMetric.session.value(for: local)?.percent == 7)
        #expect(UsageMetric.weekly.value(for: local)?.percent == 12)
        for provider in [Provider.claude, .codex] {
            let bridge = UsageAccount(id: "bridge", label: "Bridge", fiveHour: LimitInfo(percent: 8),
                                      sevenDay: LimitInfo(percent: 9), provider: provider)
            #expect(UsageMetric.session.value(for: bridge)?.percent == 8)
            #expect(UsageMetric.weekly.value(for: bridge)?.percent == 9)
            #expect(UsageMetric.weeklyModel("Fable").value(for: bridge) == nil)
            #expect(UsageMetric.extraUsage.value(for: bridge) == nil)
        }
        var invalid = UsageAccount(id: "missing", label: "Missing")
        for metric in UsageMetric.available(in: []) { #expect(metric.value(for: invalid) == nil) }
        for percent in [-1, 101, Double.nan, Double.infinity] {
            invalid.fiveHour = LimitInfo(percent: percent)
            #expect(UsageMetric.session.value(for: invalid) == nil)
        }
    }

    @Test func availabilityKeepsFixedOrderAndFirstDiscoveredSpelling() {
        let expected: [UsageMetric] = [.session, .weekly, .weeklyModel("Fable"), .weeklyModel("Opus"),
                                       .weeklyModel("Sonnet"), .extraUsage]
        #expect(UsageMetric.available(in: []).map(\.raw) == expected.map(\.raw))
        let names = ["fable", "Haiku", "haiku", "", "  ", "OPUS", "Custom Model"]
        let local = UsageAccount(id: "local", label: "Local", limits: names.map {
            LimitInfo(kind: "weekly_scoped", scope: LimitScope(model: LimitModel(displayName: $0)))
        } + [LimitInfo(kind: "other", scope: LimitScope(model: LimitModel(displayName: "Ignored")))])
        let other = UsageAccount(id: "other", label: "Other", limits: [
            LimitInfo(kind: "weekly_scoped", scope: LimitScope(model: LimitModel(displayName: "HAIKU"))),
            LimitInfo(kind: "weekly_scoped", scope: LimitScope(model: LimitModel(displayName: "Nova"))),
        ])
        #expect(UsageMetric.available(in: [local, other]).map(\.raw) ==
                ["session", "weekly", "weekly:Fable", "weekly:Opus", "weekly:Sonnet",
                 "weekly:Haiku", "weekly:Custom Model", "weekly:Nova", "extra"])
    }

    @Test @MainActor func slotsValidateDefaultsUniqueMetricsAndLimit() throws {
        let suite = "UsageKitTests.BarSlots." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults)
        #expect(preferences.barSlots == [.session, .weekly])
        #expect(defaults.object(forKey: "barSlots") == nil)
        for raw in [[], ["bad", "weekly:", "extra_usage"]] as [[String]] {
            defaults.set(raw, forKey: "barSlots")
            #expect(preferences.barSlots == UsageMetric.defaultSlots)
        }
        defaults.set(["bad", "weekly:Fable", "weekly:fable", "weekly", "extra", "session"], forKey: "barSlots")
        #expect(preferences.barSlots.map(\.raw) == ["weekly:Fable", "weekly", "extra"])
        defaults.set(["session", 42, "extra"] as [Any], forKey: "barSlots")
        #expect(preferences.barSlots == [.session, .extraUsage])
        defaults.set("weekly", forKey: "barSlots")
        #expect(preferences.barSlots == UsageMetric.defaultSlots)
    }

    @Test @MainActor func slotEditingHonorsBoundsOrderAndMinimumCount() throws {
        let suite = "UsageKitTests.EditBarSlots." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults)
        preferences.add(.session)
        preferences.add(.weeklyModel(" "))
        #expect(defaults.object(forKey: "barSlots") == nil)
        preferences.add(.weeklyModel("Fable"))
        preferences.add(.extraUsage)
        #expect(preferences.barSlots == [.session, .weekly, .weeklyModel("Fable")])
        preferences.move(from: 2, to: 0)
        #expect(preferences.barSlots == [.weeklyModel("Fable"), .session, .weekly])
        preferences.move(from: 0, to: 2)
        #expect(preferences.barSlots == [.session, .weekly, .weeklyModel("Fable")])
        for (from, to) in [(-1, 0), (0, 3), (3, 0), (0, -1), (1, 1)] { preferences.move(from: from, to: to) }
        preferences.remove(at: -1)
        preferences.remove(at: 3)
        #expect(preferences.barSlots == [.session, .weekly, .weeklyModel("Fable")])
        preferences.remove(at: 1)
        preferences.add(.weeklyModel("fable"))
        #expect(preferences.barSlots.map(\.raw) == ["session", "weekly:Fable"])
        preferences.remove(at: 0)
        preferences.remove(at: 0)
        #expect(preferences.barSlots == [.weeklyModel("Fable")])
        #expect(defaults.stringArray(forKey: "barSlots") == ["weekly:Fable"])
    }

    @Test func columnAndWidgetGeometrySupportOneToThreeBars() {
        #expect(UsageBarLayout.menuColumnStops(count: 1) == [264])
        #expect(UsageBarLayout.menuColumnStops(count: 2) == [210, 264])
        #expect(UsageBarLayout.menuColumnStops(count: 3) == [156, 210, 264])
        #expect([1, 2, 3].map { UsageBarLayout.widgetHeight(count: $0) } == [64, 74, 106])
        #expect(UsageBarLayout.widgetBarOrigins(count: 1) == [32])
        #expect(UsageBarLayout.widgetBarOrigins(count: 2) == [42, 10])
        #expect(UsageBarLayout.widgetBarOrigins(count: 3) == [74, 42, 10])
        #expect(UsageBarLayout.menuColumnStops(count: 0) == [264])
        #expect(UsageBarLayout.widgetHeight(count: 4) == 106)
    }

    @Test func widgetMoodUsesLegacyWindowsRegardlessOfVisibleMetrics() {
        var account = UsageAccount(id: "a", label: "A", fiveHour: LimitInfo(percent: 15), sevenDay: LimitInfo(percent: 82),
                                   limits: [LimitInfo(kind: "weekly_scoped", percent: 1, scope: LimitScope(model: LimitModel(displayName: "Fable")))])
        #expect(UsageMetric.weeklyModel("Fable").value(for: account)?.percent == 1)
        #expect(UsageBarLayout.moodSeverity(for: account) == 1)
        account.fiveHour = LimitInfo(percent: 95)
        #expect(UsageBarLayout.moodSeverity(for: account) == 2)
        account.fiveHour = LimitInfo(percent: 0)
        account.sevenDay = LimitInfo(percent: 0)
        account.limits = [LimitInfo(kind: "extra_usage", percent: 99)]
        #expect(UsageMetric.extraUsage.value(for: account)?.percent == 99)
        #expect(UsageBarLayout.moodSeverity(for: account) == 0)
        #expect(UsageBarLayout.moodSeverity(for: nil) == 0)
    }

    @Test func finalStartupFrameKeepsSavedOriginAcrossLaunchesAndLiveResizing() {
        for count in 1...3 {
            for widgets in 1...2 {
                var saved = CGPoint(x: 100, y: 400)
                for _ in 0..<10 {
                    let startup = UsageBarLayout.widgetFrame(origin: saved, barCount: count, widgetCount: widgets)
                    let updated = UsageBarLayout.resizedWidgetFrame(startup, barCount: count, widgetCount: widgets)
                    #expect(updated.origin == saved)
                    let expectedHeight = UsageBarLayout.widgetHeight(count: count) * Double(widgets)
                    #expect(Double(updated.height) == expectedHeight)
                    saved = updated.origin
                }
                let startup = UsageBarLayout.widgetFrame(origin: saved, barCount: count, widgetCount: widgets)
                let changed = UsageBarLayout.resizedWidgetFrame(startup, barCount: 3, widgetCount: widgets)
                #expect(changed.maxY == startup.maxY)
                #expect(UsageBarLayout.widgetFrame(origin: changed.origin, barCount: 3, widgetCount: widgets) == changed)
            }
        }
    }

    @Test @MainActor func tooltipFollowsSelectedSlotOrderAndReportsMissingData() {
        let now = Date(timeIntervalSince1970: 0)
        let tooltip = MenuFormatting.accountTooltip(account(), now: now, slots: [.weeklyModel("Fable"), .weekly, .extraUsage])
        #expect(tooltip.contains("Weekly Fable 41%"))
        #expect(tooltip.contains("Weekly 82%"))
        #expect(tooltip.contains("Extra usage 0%"))
        #expect(tooltip.range(of: "Weekly Fable 41%")!.lowerBound < tooltip.range(of: "Weekly 82%")!.lowerBound)
        #expect(!tooltip.contains("Session"))
        let missing = MenuFormatting.accountTooltip(UsageAccount(id: "a", label: "A"), now: now, slots: [.weeklyModel("Fable")])
        #expect(missing.contains("Weekly Fable not reported for this plan"))
    }
}
