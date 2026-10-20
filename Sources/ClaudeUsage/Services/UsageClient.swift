import Foundation
import UsageKit
import os

// Only compile-time URL literals belong here. Dynamic URLs use URLComponents.
enum AppURLs {
    private static func literal(_ value: StaticString) -> URL {
        URL(string: value.description)!
    }
    static let server = literal("http://127.0.0.1:8737")
    static let claudeSettings = literal("https://claude.ai/settings/usage")
    static let codexSettings = literal("https://chatgpt.com/codex/settings/usage")
}

struct UsageClient: Sendable {
    struct Ping: Decodable, Sendable { let version: String? }
    private static let logger = Logger(subsystem: "com.heng.claude-usage-widget", category: "HTTP")
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func ping(timeout: TimeInterval = 0.25) async -> Ping? {
        var request = URLRequest(url: AppURLs.server.appendingPathComponent("api/ping"))
        request.timeoutInterval = timeout
        guard let (data, _) = try? await session.data(for: request) else { return nil }
        // Any HTTP answer means a process owns the port, even an older/malformed ping.
        return (try? JSONDecoder().decode(Ping.self, from: data)) ?? Ping(version: nil)
    }

    func accounts() async -> [UsageAccount]? {
        var request = URLRequest(url: AppURLs.server.appendingPathComponent("api/accounts"))
        request.timeoutInterval = 100
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(AccountsResponse.self, from: data).accounts
        } catch {
            Self.logger.error("Account refresh failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func post(_ route: String, account: String? = nil, timeout: TimeInterval = 100) async -> Bool {
        guard var components = URLComponents(url: AppURLs.server.appendingPathComponent("api/" + route),
                                             resolvingAgainstBaseURL: false) else { return false }
        if let account { components.queryItems = [URLQueryItem(name: "account", value: account)] }
        guard let url = components.url else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("1", forHTTPHeaderField: "X-Widget")
        guard let (_, response) = try? await session.data(for: request),
              let response = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(response.statusCode)
    }

    func refresh(accounts: [UsageAccount]) async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { _ = await post("refresh", account: account.id) }
            }
        }
    }
}
