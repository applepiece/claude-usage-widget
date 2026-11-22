import Foundation

public enum BarAccounts: String, CaseIterable, Sendable { case primary, primarySecondary, all }
public enum BarMetric: String, CaseIterable, Sendable { case five, seven, both, max }
public enum CreditsDisplay: String, CaseIterable, Sendable { case providers, total, off }

@MainActor
public struct Preferences {
    public let defaults: UserDefaults
    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func migrate() {
        if defaults.object(forKey: "creditsDisplay") == nil {
            defaults.set(creditsDisplay.rawValue, forKey: "creditsDisplay")
        }
        guard !defaults.bool(forKey: "accountsV2Migrated") else { return }
        if let old = defaults.string(forKey: "barMode") {
            if old == "off" {
                defaults.set(false, forKey: "barNumbers")
            } else if ["five", "seven", "both"].contains(old) {
                defaults.set(old, forKey: "barMetric")
            }
        }
        defaults.set(true, forKey: "accountsV2Migrated")
    }
    public var primaryID: String? { defaults.string(forKey: "primaryAccount") }
    public var secondaryID: String { defaults.string(forKey: "secondaryAccount") ?? "none" }
    public var accounts: BarAccounts { BarAccounts(rawValue: defaults.string(forKey: "barAccounts") ?? "") ?? .primary }
    public var metric: BarMetric { BarMetric(rawValue: defaults.string(forKey: "barMetric") ?? "") ?? .max }
    public var numbers: Bool { defaults.object(forKey: "barNumbers") as? Bool ?? true }
    public var always: Bool { defaults.object(forKey: "menuBarAlways") as? Bool ?? true }
    public var creditsDisplay: CreditsDisplay {
        if defaults.object(forKey: "creditsDisplay") == nil {
            return defaults.object(forKey: "showAPICredits") as? Bool == false ? .off : .providers
        }
        return CreditsDisplay(rawValue: defaults.string(forKey: "creditsDisplay") ?? "") ?? .providers
    }
    public var creditsWarnDays: Int {
        let days = defaults.object(forKey: "creditsWarnDays") as? Int ?? 7
        return [3, 7, 14].contains(days) ? days : 7
    }
    public var showAPICredits: Bool { creditsDisplay != .off }
    public var barSlots: [UsageMetric] {
        var seen: Set<UsageMetric> = []
        let slots = (defaults.array(forKey: "barSlots") ?? []).compactMap { value in
            (value as? String).flatMap(UsageMetric.init(raw:))
        }.filter { seen.insert($0).inserted }
        return slots.isEmpty ? UsageMetric.defaultSlots : Array(slots.prefix(3))
    }

    public func add(_ metric: UsageMetric) {
        var slots = barSlots
        guard let metric = UsageMetric(raw: metric.raw), slots.count < 3, !slots.contains(metric) else { return }
        slots.append(metric)
        defaults.set(slots.map(\.raw), forKey: "barSlots")
    }

    public func remove(at index: Int) {
        var slots = barSlots
        guard slots.count > 1, slots.indices.contains(index) else { return }
        slots.remove(at: index)
        defaults.set(slots.map(\.raw), forKey: "barSlots")
    }

    public func move(from source: Int, to destination: Int) {
        var slots = barSlots
        guard source != destination, slots.indices.contains(source), slots.indices.contains(destination) else { return }
        let metric = slots.remove(at: source)
        slots.insert(metric, at: destination)
        defaults.set(slots.map(\.raw), forKey: "barSlots")
    }

    public var twoWidgets: Bool { defaults.string(forKey: "widgetAccounts") == "primarySecondary" }
    public var shortNames: [String: String] { defaults.dictionary(forKey: "accountShortNames") as? [String: String] ?? [:] }
    public var accountMenuState: AccountMenuState {
        AccountMenuState(slots: barSlots, primaryID: primaryID, secondaryID: secondaryID, shortNames: shortNames)
    }

    public func effectiveShortNames(in accounts: [UsageAccount]) -> [String: String] {
        AccountShortNames.effective(in: accounts, custom: shortNames)
    }

    public func setShortName(_ value: String, for id: String) {
        var names = shortNames
        // Keep spaces during editing so a name can contain spaces. Only the
        // effective display name is trimmed; Character limits apply on each edit.
        names[id] = String(value.prefix(6))
        defaults.set(names, forKey: "accountShortNames")
    }

    public func primary(in accounts: [UsageAccount]) -> UsageAccount? {
        accounts.first { $0.id == primaryID } ?? accounts.first { $0.machineLogin } ?? accounts.first
    }
    public func secondary(in accounts: [UsageAccount]) -> UsageAccount? {
        accounts.first { $0.id == secondaryID && $0.id != primary(in: accounts)?.id }
    }
    public func shown(in accounts: [UsageAccount]) -> [UsageAccount] {
        if self.accounts == .all { return accounts }
        return [primary(in: accounts), self.accounts == .primarySecondary ? secondary(in: accounts) : nil].compactMap { $0 }
    }

    public func makePrimary(_ id: String, in accounts: [UsageAccount]) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        let old = primary(in: accounts)?.id
        if secondaryID == id { defaults.set(old ?? "none", forKey: "secondaryAccount") }
        defaults.set(id, forKey: "primaryAccount")
    }

    public func setSecondary(_ id: String, in accounts: [UsageAccount]) {
        guard id != primary(in: accounts)?.id,
              id == "none" || accounts.contains(where: { $0.id == id }) else { return }
        defaults.set(id, forKey: "secondaryAccount")
    }
}
