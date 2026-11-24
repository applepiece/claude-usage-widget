import Cocoa
import Observation
import UsageKit

@MainActor @Observable
final class AppModel {
    var accounts: [UsageAccount] = []
    var creditSnapshot = CreditSnapshot()
    var credits: [CreditProvider] { creditSnapshot.providers }
    var creditsUpdatedAt: Date? { creditSnapshot.updatedAt }
    var refreshing = false
    var lastUpdate: Date?
    var widgetVisible = false
    var preferencesRevision = 0
    @ObservationIgnored let preferences: Preferences
    @ObservationIgnored let isQA: Bool
    @ObservationIgnored var widgetAction: (Bool) -> Void = { _ in }
    @ObservationIgnored var refreshAction: () -> Void = {}
    @ObservationIgnored var signInAction: () -> Void = {}
    @ObservationIgnored var signOutAction: () -> Void = {}

    init(preferences: Preferences, isQA: Bool) {
        self.preferences = preferences
        self.isQA = isQA
    }

    var primary: UsageAccount? {
        _ = preferencesRevision
        return preferences.primary(in: accounts)
    }
    var secondary: UsageAccount? {
        _ = preferencesRevision
        return preferences.secondary(in: accounts)
    }
    var machineLogin: UsageAccount? { accounts.first { $0.machineLogin && !$0.isBridgeAccount } }

    var shortNames: [String: String] {
        _ = preferencesRevision
        return preferences.effectiveShortNames(in: accounts)
    }

    var barSlots: [UsageMetric] {
        _ = preferencesRevision
        return preferences.barSlots
    }

    func addBar(_ metric: UsageMetric) {
        preferences.add(metric)
        preferencesRevision += 1
    }

    func removeBar(at index: Int) {
        preferences.remove(at: index)
        preferencesRevision += 1
    }

    func moveBar(from source: Int, to destination: Int) {
        preferences.move(from: source, to: destination)
        preferencesRevision += 1
    }

    func customShortName(for id: String) -> String {
        _ = preferencesRevision
        return preferences.shortNames[id] ?? ""
    }

    func setShortName(_ value: String, for id: String) {
        preferences.setShortName(value, for: id)
        preferencesRevision += 1
    }

    func makePrimary(_ id: String) {
        preferences.makePrimary(id, in: accounts)
        preferencesRevision += 1
    }

    func setSecondary(_ id: String) {
        preferences.setSecondary(id, in: accounts)
        preferencesRevision += 1
    }

    func setWidgetVisible(_ visible: Bool) { widgetAction(visible) }
    func refreshNow() { refreshAction() }
    func signIn() { signInAction() }
    func signOut() { signOutAction() }
}
