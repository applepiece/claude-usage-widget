import Foundation

public struct LimitModel: Decodable, Sendable {
    public let displayName: String?

    public init(displayName: String? = nil) {
        self.displayName = displayName
    }

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

public struct LimitScope: Decodable, Sendable {
    public let model: LimitModel?

    public init(model: LimitModel? = nil) {
        self.model = model
    }

    enum CodingKeys: String, CodingKey {
        case model
    }
}

public struct LimitInfo: Decodable, Sendable {
    public let utilization: Double?
    public let status: String?
    public let resetsAt: String?
    public let kind: String?
    public let group: String?
    public let percent: Double?
    public let scope: LimitScope?

    public init(utilization: Double? = nil, resetsAt: String? = nil,
         kind: String? = nil, group: String? = nil, percent: Double? = nil,
         scope: LimitScope? = nil, status: String? = nil) {
        self.utilization = utilization
        self.status = status
        self.resetsAt = resetsAt
        self.kind = kind
        self.group = group
        self.percent = percent
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey {
        case utilization
        case status
        case resetsAt = "resets_at"
        case kind
        case group
        case percent
        case scope
    }
}

public struct Usage: Decodable, Sendable {
    public let fiveHour: LimitInfo?
    public let sevenDay: LimitInfo?
    public let limits: [LimitInfo]?
    public let fetchedAt: Double?
    public let loggedIn: Bool?
    public let accountKey: String?

    public init(fiveHour: LimitInfo? = nil, sevenDay: LimitInfo? = nil,
         limits: [LimitInfo]? = nil, fetchedAt: Double? = nil,
         loggedIn: Bool? = nil, accountKey: String? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.limits = limits
        self.fetchedAt = fetchedAt
        self.loggedIn = loggedIn
        self.accountKey = accountKey
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
        case fetchedAt = "fetched_at"
        case loggedIn = "logged_in"
        case accountKey = "account_key"
    }
}

public struct AccountInfo: Decodable, Sendable {
    public let loggedIn: Bool
    public let email: String?
    public let name: String?
    public let plan: String?
    public let org: String?
    // false when the profile lookup failed, so name/org are local fallbacks and
    // this answer is worth asking again sooner than the normal staleness gate
    public let profileOK: Bool?
    public let provider: Provider

    public init(loggedIn: Bool, email: String? = nil, name: String? = nil,
         plan: String? = nil, org: String? = nil, profileOK: Bool? = nil,
         provider: Provider = .claude) {
        self.loggedIn = loggedIn
        self.email = email
        self.name = name
        self.plan = plan
        self.org = org
        self.profileOK = profileOK
        self.provider = provider
    }

    enum CodingKeys: String, CodingKey {
        case loggedIn = "logged_in"
        case email
        case name
        case plan
        case org
        case profileOK = "profile_ok"
        case provider
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        loggedIn = try values.decode(Bool.self, forKey: .loggedIn)
        email = try values.decodeIfPresent(String.self, forKey: .email)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        plan = try values.decodeIfPresent(String.self, forKey: .plan)
        org = try values.decodeIfPresent(String.self, forKey: .org)
        profileOK = try values.decodeIfPresent(Bool.self, forKey: .profileOK)
        provider = try values.decodeIfPresent(Provider.self, forKey: .provider) ?? .claude
    }
}

extension LimitInfo {
    public var value: Double? {
        guard let value = utilization ?? percent, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
}

public enum Provider: String, Decodable, Sendable {
    case claude, codex
}

public enum AccountState: String, Decodable, Sendable {
    case ok, stale, error
    case tokenRejected = "token_rejected"

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .error
    }
}

public struct AccountsResponse: Decodable, Sendable {
    public let accounts: [UsageAccount]
    public let fetchedAt: Double
    enum CodingKeys: String, CodingKey {
        case accounts
        case fetchedAt = "fetched_at"
    }
}

public struct UsageAccount: Decodable, Sendable {
    public let id: String
    public let label: String
    public var email: String?
    public var plan: String?
    public var source: String
    public var machineLogin: Bool
    public var fiveHour: LimitInfo?
    public var sevenDay: LimitInfo?
    public var limits: [LimitInfo]?
    public private(set) var rawState: String
    public var state: AccountState {
        get { AccountState(rawValue: rawState) ?? .error }
        set { rawState = newValue.rawValue }
    }
    public var fetchedAt: Double?
    public var expiresAt: String?
    public var provider: Provider
    public var asOf: Double?
    public var quotaSource: String?

    public init(id: String, label: String, email: String? = nil, plan: String? = nil,
                source: String = "token", machineLogin: Bool = false,
                fiveHour: LimitInfo? = nil, sevenDay: LimitInfo? = nil,
                limits: [LimitInfo]? = nil, state: AccountState = .ok,
                fetchedAt: Double? = nil, expiresAt: String? = nil,
                provider: Provider = .claude, asOf: Double? = nil, quotaSource: String? = nil) {
        self.id = id
        self.label = label
        self.email = email
        self.plan = plan
        self.source = source
        self.machineLogin = machineLogin
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.limits = limits
        self.rawState = state.rawValue
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
        self.provider = provider
        self.asOf = asOf
        self.quotaSource = quotaSource
    }

    enum CodingKeys: String, CodingKey {
        case id, label, email, plan, source, limits, state, provider
        case machineLogin = "machine_login"
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case fetchedAt = "fetched_at"
        case expiresAt = "expires_at"
        case asOf = "as_of"
        case quotaSource = "quota_source"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decode(String.self, forKey: .label)
        email = try values.decodeIfPresent(String.self, forKey: .email)
        plan = try values.decodeIfPresent(String.self, forKey: .plan)
        source = try values.decodeIfPresent(String.self, forKey: .source) ?? "token"
        machineLogin = try values.decodeIfPresent(Bool.self, forKey: .machineLogin) ?? false
        fiveHour = try values.decodeIfPresent(LimitInfo.self, forKey: .fiveHour)
        sevenDay = try values.decodeIfPresent(LimitInfo.self, forKey: .sevenDay)
        limits = try values.decodeIfPresent([LimitInfo].self, forKey: .limits)
        rawState = try values.decodeIfPresent(String.self, forKey: .state) ?? "ok"
        fetchedAt = try values.decodeIfPresent(Double.self, forKey: .fetchedAt)
        expiresAt = try values.decodeIfPresent(String.self, forKey: .expiresAt)
        provider = try values.decodeIfPresent(Provider.self, forKey: .provider) ?? .claude
        asOf = try values.decodeIfPresent(Double.self, forKey: .asOf)
        quotaSource = try values.decodeIfPresent(String.self, forKey: .quotaSource)
    }

    public var isCodex: Bool { provider == .codex }
    public var providerName: String { isCodex ? "Codex" : "Claude" }
    public var failed: Bool { state == .error || state == .tokenRejected }
    public var usage: Usage {
        Usage(fiveHour: fiveHour, sevenDay: sevenDay, limits: limits,
              fetchedAt: asOf ?? fetchedAt, loggedIn: true)
    }
    public var info: AccountInfo {
        AccountInfo(loggedIn: true, email: email, name: label, plan: plan, provider: provider)
    }
    public var highest: Double? { [fiveHour?.value, sevenDay?.value].compactMap { $0 }.max() }
}
