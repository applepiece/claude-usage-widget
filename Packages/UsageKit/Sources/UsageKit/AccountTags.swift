import Foundation

public func accountTags(_ accounts: [UsageAccount]) -> [String: String] {
    var tags: [String: String] = [:]
    for account in accounts {
        let first = String(account.label.prefix(1)).uppercased()
        let collide = accounts.filter {
            $0.isCodex == account.isCodex && String($0.label.prefix(1)).uppercased() == first
        }.count > 1
        tags[account.id] = (account.isCodex ? "›" : "") + String(account.label.prefix(collide ? 2 : 1)).uppercased()
    }
    var used = Set<String>()
    for account in accounts {
        let prefix = account.isCodex ? "›" : ""
        let label = account.label.uppercased()
        var tag = tags[account.id] ?? prefix
        var length = tag.count - prefix.count
        var suffix = 2
        while used.contains(tag) {
            if length < label.count {
                length += 1
                tag = prefix + String(label.prefix(length))
            } else {
                tag = prefix + label + String(suffix)
                suffix += 1
            }
        }
        used.insert(tag)
        tags[account.id] = tag
    }
    return tags
}

public enum AccountShortNames {
    /// Limit by extended grapheme clusters, preserving Thai marks and emoji.
    public static func trimmed(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(6))
    }

    public static func effective(in accounts: [UsageAccount], custom: [String: String]) -> [String: String] {
        let automatic = accountTags(accounts)
        return Dictionary(uniqueKeysWithValues: accounts.map { account in
            let name = trimmed(custom[account.id] ?? "")
            return (account.id, name.isEmpty ? (automatic[account.id] ?? "?") : name)
        })
    }
}
