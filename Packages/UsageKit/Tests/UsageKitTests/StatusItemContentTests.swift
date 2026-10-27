import Foundation
import Testing
@testable import UsageKit

struct StatusItemContentTests {
    private func account(_ id: String = "pho", five: Double? = 15, seven: Double? = 85,
                         state: AccountState = .ok) -> UsageAccount {
        UsageAccount(id: id, label: id, fiveHour: five.map { LimitInfo(percent: $0) },
                     sevenDay: seven.map { LimitInfo(percent: $0) }, state: state)
    }

    @Test func unchangedInputsProduceEqualContentSoTheButtonIsLeftAlone() {
        let first = StatusItemContent(shown: [account()], anyAccounts: true)
        let second = StatusItemContent(shown: [account()], anyAccounts: true)
        #expect(first == second)
    }

    @Test func changedNumbersOrNamesProduceDifferentContent() {
        let base = StatusItemContent(shown: [account()], anyAccounts: true)
        #expect(base != StatusItemContent(shown: [account(seven: 86)], anyAccounts: true))
        #expect(base != StatusItemContent(shown: [account()], anyAccounts: true, shortNames: ["pho": "me"]))
        #expect(base != StatusItemContent(shown: [account()], anyAccounts: true, numbers: false))
        #expect(base != StatusItemContent(shown: [account(state: .stale)], anyAccounts: true))
    }

    @Test func toolTipListsEachShownAccount() {
        let content = StatusItemContent(shown: [account(), account("pro", five: nil, seven: 40.4)], anyAccounts: true)
        #expect(content.toolTip == "pho · Claude: 5H 15%, WK 85% · ok\npro · Claude: 5H –, WK 40% · ok")
        #expect(content.title.string == "PH 85%  PR 40%")
    }

    @Test func toolTipWithoutAnyAccount() {
        #expect(StatusItemContent(shown: [], anyAccounts: false).toolTip == "Claude Usage · No accounts")
        #expect(StatusItemContent(shown: [], anyAccounts: true).toolTip == "")
    }
}
