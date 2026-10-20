import AppKit
import Foundation
import Testing
@testable import UsageKit

struct StatusTitleTests {
    private func account(_ id: String = "pho", five: Double? = 15, seven: Double? = 85,
                         state: AccountState = .ok) -> UsageAccount {
        UsageAccount(id: id, label: id, fiveHour: five.map { LimitInfo(percent: $0) },
                     sevenDay: seven.map { LimitInfo(percent: $0) }, state: state)
    }

    @Test func singleAccountAlwaysHasName() {
        let title = StatusTitle(accounts: [account()])
        #expect(title.string == "P 85%")
        #expect(title.segments == [.init(accountID: "pho", shortName: "P", value: "85%")])
        #expect(title.hiddenCount == 0)
        #expect(title.accessibilityLabel == "P, 85 percent used, weekly")
    }

    @Test func customShortNameWins() {
        let title = StatusTitle(accounts: [account()], shortNames: ["pho": "  pho \n"])
        #expect(title.string == "pho 85%")
        #expect(title.accessibilityLabel == "pho, 85 percent used, weekly")
        #expect(StatusTitle(accounts: [account()], shortNames: ["pho": "a% b"]).string == "a% b 85%")
    }

    @Test func effectiveEmptyAndWhitespaceNamesAreAutomatic() {
        let accounts = [account(), account("phil"), UsageAccount(id: "pro", label: "pro", provider: .codex)]
        for custom in [[:], ["pho": "", "phil": " \t\n", "pro": " "]] {
            #expect(AccountShortNames.effective(in: accounts, custom: custom) == accountTags(accounts))
        }
        #expect(StatusTitle(accounts: [account()], shortNames: ["pho": "\n \t"]).string == "P 85%")
    }

    @Test func cutsAtSixCharactersIncludingThaiAndEmoji() {
        let thai = "กิขีคุฆูง่จ้"
        let emoji = "👨‍👩‍👧‍👦👩🏽‍💻🇹🇭👍🏽🦀❤️"
        #expect(thai.count == 6)
        #expect(emoji.count == 6)
        for name in [thai, emoji, "abcdef"] {
            let title = StatusTitle(accounts: [account()], shortNames: ["pho": "  " + name + "xyz \n"])
            #expect(title.segments.first?.shortName == name)
            #expect(title.string == name + " 85%")
            #expect(AccountShortNames.trimmed(name + "xyz") == name)
        }
    }

    @Test func percentDropsOnlyPastTwentyEightCharacters() {
        let accounts = ["a", "b", "c", "d"].map { account($0, five: 100, seven: 100) }
        let title = StatusTitle(accounts: accounts)
        #expect(title.string == "A 100  B 100  C 100  D 100")
        #expect(title.hiddenCount == 0)
        // Exactly 28 is still full format. Percent signs in names are user text.
        let three = Array(accounts.prefix(3))
        let names = ["a": "a%b", "b": "four", "c": "fives"]
        let boundary = StatusTitle(accounts: three, shortNames: names, metric: .five)
        #expect(boundary.string == "a%b 100%  four 100%  fives 100%".replacingOccurrences(of: "100%", with: "100"))
        #expect(boundary.string.contains("a%b"))
        let exact = StatusTitle(accounts: three, shortNames: ["a": "abc", "b": "de", "c": "fghi"])
        #expect(exact.string.count == 28)
        #expect(exact.string == "abc 100%  de 100%  fghi 100%")
    }

    @Test func longBothFallsBackToHighestWindow() {
        let accounts = ["a", "b", "c", "d"].map { account($0) }
        let title = StatusTitle(accounts: accounts, metric: .both)
        #expect(title.string == "A 85  B 85  C 85  D 85")
        #expect(title.segments.count == 4)
        #expect(title.hiddenCount == 0)
        #expect(title.accessibilityLabel.contains("85 percent used, weekly"))
        #expect(!title.accessibilityLabel.contains("session"))
    }

    @Test func longSingleMetricAlsoFallsBackToHighestWindow() {
        let accounts = ["a", "b", "c", "d"].map { account($0, five: 100, seven: 9) }
        let title = StatusTitle(accounts: accounts, shortNames: ["a": "aaaa", "b": "bbbb", "c": "cccc", "d": "dddd"],
                                metric: .seven)
        #expect(title.string == "aaaa 100  +3")
        #expect(title.accessibilityLabel.contains("100 percent used, session"))
    }

    @Test func tooManyAccountsKeepFirstAndHiddenCount() {
        let accounts = ["a", "b", "c", "d", "e"].map { account($0, five: 100, seven: 100) }
        let title = StatusTitle(accounts: accounts, metric: .both)
        #expect(title.string == "A 100  +4")
        #expect(title.segments.count == 1)
        #expect(title.segments.first?.accountID == "a")
        #expect(title.hiddenCount == 4)
        // Hidden accounts remain available to VoiceOver.
        #expect(title.accessibilityLabel.contains("E, 100 percent used, session"))
    }

    @Test func failuresAlwaysUseExclamationMark() {
        for state in [AccountState.error, .tokenRejected] {
            for metric in BarMetric.allCases {
                let title = StatusTitle(accounts: [account(state: state)], metric: metric)
                #expect(title.string == "P !")
                #expect(title.accessibilityLabel == (state == .error ? "P, couldn't load usage" : "P, sign-in expired"))
            }
        }
        #expect(StatusTitle(accounts: [account(state: .stale)]).string == "P 85%")
    }

    @Test func missingWindowsAreDashesAndMaxUsesAvailableWindow() {
        #expect(StatusTitle(accounts: [account(five: nil)], metric: .five).string == "P –")
        #expect(StatusTitle(accounts: [account(seven: nil)], metric: .seven).string == "P –")
        #expect(StatusTitle(accounts: [account(five: nil)], metric: .both).string == "P –·85")
        #expect(StatusTitle(accounts: [account(seven: nil)], metric: .both).string == "P 15·–")
        #expect(StatusTitle(accounts: [account(five: nil, seven: nil)]).string == "P –")
        #expect(StatusTitle(accounts: [account(five: nil)]).string == "P 85%")
        #expect(StatusTitle(accounts: [account(seven: nil)]).string == "P 15%")
    }

    @Test func metricsAndRounding() {
        #expect(StatusTitle(accounts: [account()], metric: .both).string == "P 15·85")
        #expect(StatusTitle(accounts: [account()], metric: .five).string == "P 15%")
        #expect(StatusTitle(accounts: [account()], metric: .seven).string == "P 85%")
        #expect(StatusTitle(accounts: [account(five: 15.5, seven: 14.9)]).string == "P 16%")
        #expect(StatusTitle(accounts: [account(five: 0, seven: 0)]).string == "P 0%")
    }

    @Test func numbersOffHasNoTitleEvenForFailures() {
        for accounts in [[account()], [account(state: .error)], [account(five: nil, seven: nil)], []] {
            let title = StatusTitle(accounts: accounts, numbers: false)
            #expect(title.string.isEmpty)
            #expect(title.segments.isEmpty)
            #expect(title.hiddenCount == 0)
            #expect(!title.accessibilityLabel.isEmpty)
        }
        #expect(StatusTitle(accounts: []).string.isEmpty)
    }

    @Test @MainActor func storedShortNamesPreserveOtherSettingsAndLegacyStyle() throws {
        let suite = "StatusTitleTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults)
        defaults.set("ring", forKey: "barStyle")
        defaults.set("off", forKey: "barMode")
        defaults.set("all", forKey: "barAccounts")
        defaults.set("seven", forKey: "barMetric")
        defaults.set(false, forKey: "menuBarAlways")
        preferences.migrate()
        #expect(defaults.string(forKey: "barStyle") == "ring")
        #expect(!preferences.numbers)
        #expect(preferences.accounts == .all)
        #expect(preferences.metric == .seven)
        #expect(!preferences.always)
        preferences.setShortName("👩🏽‍💻🇹🇭👍🏽🦀❤️กิextra", for: "pho")
        preferences.setShortName("work", for: "other")
        #expect(preferences.shortNames["pho"] == "👩🏽‍💻🇹🇭👍🏽🦀❤️กิ")
        #expect(preferences.effectiveShortNames(in: [account()])["pho"] == "👩🏽‍💻🇹🇭👍🏽🦀❤️กิ")
        preferences.setShortName("", for: "pho")
        #expect(preferences.effectiveShortNames(in: [account()])["pho"] == "P")
        #expect(preferences.shortNames["other"] == "work")
        preferences.setShortName(" \t", for: "pho")
        #expect(preferences.effectiveShortNames(in: [account()])["pho"] == "P")
        #expect(defaults.string(forKey: "barStyle") == "ring")
    }

    @Test @MainActor func nativeAttributesAndUnicodeRanges() throws {
        let title = StatusTitle(accounts: [account()], shortNames: ["pho": "👩🏽‍💻กิ"])
        let text = StatusRenderer.attributedTitle(title)
        #expect(text.string == title.string)
        let nameLength = ("👩🏽‍💻กิ" as NSString).length
        let nameFont = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let valueFont = try #require(text.attribute(.font, at: nameLength + 1, effectiveRange: nil) as? NSFont)
        #expect(nameFont.pointSize == NSFont.menuBarFont(ofSize: 0).pointSize)
        #expect(valueFont.pointSize == nameFont.pointSize)
        #expect(nameFont == NSFont.monospacedDigitSystemFont(ofSize: nameFont.pointSize, weight: .semibold))
        #expect(valueFont == NSFont.monospacedDigitSystemFont(ofSize: nameFont.pointSize, weight: .regular))
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
            #expect(attributes[.foregroundColor] == nil)
        }
    }
}
