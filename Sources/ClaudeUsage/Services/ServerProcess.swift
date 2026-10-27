import Foundation
import os

@MainActor
final class ServerProcess {
    static let version = "3.0.1"
    private let logger = Logger(subsystem: "com.heng.claude-usage-widget", category: "Server")
    private var process: Process?

    func ensureServer(client: UsageClient) async {
        if let ping = await client.ping(timeout: 2) {
            guard ping.version != Self.version else { return }
            guard await client.post("quit", timeout: 3) else {
                logger.notice("Existing server did not accept quit; continuing to use it")
                return
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(3))
            while clock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                let remaining = clock.now.duration(to: deadline)
                let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
                guard seconds > 0 else { break }
                if await client.ping(timeout: min(0.25, seconds)) == nil {
                    await launch()
                    return
                }
            }
            logger.notice("Existing server still answers after quit; continuing to use it")
            return
        }
        await launch()
    }

    private func launch() async {
        guard let script = Bundle.main.url(forResource: "server", withExtension: "py") else {
            logger.error("Bundled server.py is missing")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            self.process = process
            try await Task.sleep(for: .seconds(2))
        } catch {
            logger.error("Server launch failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
