import Foundation

public enum BarAccounts: String, CaseIterable, Sendable { case primary, primarySecondary, all }
public enum BarMetric: String, CaseIterable, Sendable { case five, seven, both, max }

@MainActor
public struct Preferences {
    public let defaults: UserDefaults
    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func migrate() {
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
    public var twoWidgets: Bool { defaults.string(forKey: "widgetAccounts") == "primarySecondary" }
    public var shortNames: [String: String] { defaults.dictionary(forKey: "accountShortNames") as? [String: String] ?? [:] }

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
