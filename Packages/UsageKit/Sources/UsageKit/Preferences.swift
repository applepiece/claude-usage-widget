import Foundation

public enum BarAccounts: String, CaseIterable, Sendable { case primary, primarySecondary, all }
public enum BarStyle: String, CaseIterable, Sendable { case percent, battery, hp, dual, ring }
public enum BarMetric: String, CaseIterable, Sendable { case five, seven, both, max }

@MainActor
public struct Preferences {
    public let defaults: UserDefaults
    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func migrate() {
        guard !defaults.bool(forKey: "accountsV2Migrated") else { return }
        if let old = defaults.string(forKey: "barMode") {
            if old == "off" {
                defaults.set("percent", forKey: "barStyle")
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
    public var style: BarStyle { BarStyle(rawValue: defaults.string(forKey: "barStyle") ?? "") ?? .battery }
    public var metric: BarMetric { BarMetric(rawValue: defaults.string(forKey: "barMetric") ?? "") ?? .max }
    public var numbers: Bool { defaults.object(forKey: "barNumbers") as? Bool ?? true }
    public var always: Bool { defaults.object(forKey: "menuBarAlways") as? Bool ?? true }
    public var twoWidgets: Bool { defaults.string(forKey: "widgetAccounts") == "primarySecondary" }

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
