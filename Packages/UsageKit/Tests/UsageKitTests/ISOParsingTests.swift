import Foundation
import Testing
@testable import UsageKit

struct ISOParsingTests {
    @Test(arguments: [
        "2026-10-20T14:00:00.123456Z",
        "2026-10-20T14:00:00.125Z",
        "2026-10-20T14:00:00+00:00",
        "2026-10-20T14:00:00Z",
    ])
    func sharedParserPreservesResetAcrossTimestampForms(raw: String) throws {
        let expected = try #require(parseISO("2026-10-20T14:00:00Z"))
        let parsed = try #require(parseISO(raw))
        #expect(parsed.timeIntervalSince(expected) >= 0 && parsed.timeIntervalSince(expected) < 1)
        let account = UsageAccount(id: "a", label: "A", fiveHour: LimitInfo(utilization: 15, resetsAt: raw))
        #expect(UsageMetric.session.value(for: account)?.resetsAt == parsed)
    }

    @Test func cachedParserSupportsConcurrentMetricLookups() async {
        let allParsed = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for _ in 0..<64 {
                group.addTask { parseISO("2026-10-20T14:00:00.123456Z") != nil && parseISO("bad") == nil }
            }
            var success = true
            for await parsed in group { success = success && parsed }
            return success
        }
        #expect(allParsed)
    }
}
