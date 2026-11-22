import Cocoa
import UsageKit

struct QAOptions {
    var enabled = false
    var state = "normal"
    var appearance: String?
    var open: String?
    var defaults: [(String, String)] = []
    var quitAfter: TimeInterval = 20

    init(arguments: [String] = []) {
        enabled = arguments.contains("--qa")
        guard enabled else { return }
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard index + 1 < arguments.count else { break }
            let value = arguments[index + 1]
            switch argument {
            case "--qa-state": state = value
            case "--qa-appearance": appearance = value
            case "--qa-open": open = value
            case "--qa-quit-after":
                if let seconds = Double(value), seconds.isFinite, seconds > 0 { quitAfter = seconds }
            case "--qa-defaults":
                if let equal = value.firstIndex(of: "=") {
                    defaults.append((String(value[..<equal]), String(value[value.index(after: equal)...])))
                }
            default: index += 1; continue
            }
            index += 2
        }
    }

    @MainActor func apply(to defaults: UserDefaults) {
        for (key, value) in self.defaults {
            if key == "accountShortNames" {
                if let names = try? JSONDecoder().decode([String: String].self, from: Data(value.utf8)) {
                    defaults.set(names, forKey: key)
                }
            } else if key == "barSlots" {
                defaults.set(value.components(separatedBy: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }, forKey: key)
            } else if key == "creditsWarnDays", let days = Int(value) {
                defaults.set(days, forKey: key)
            } else if ["barNumbers", "menuBarAlways", "minimized", "showAPICredits"].contains(key) {
                defaults.set(["true", "1", "yes"].contains(value.lowercased()), forKey: key)
            } else { defaults.set(value, forKey: key) }
        }
    }

    @MainActor func accounts() -> [UsageAccount] {
        var accounts = sampleAccounts()
        switch state {
        case "signedout": return []
        case "single": return Array(accounts.prefix(1))
        case "stale":
            for index in accounts.indices {
                accounts[index].state = .stale
                accounts[index].fetchedAt = Date().timeIntervalSince1970 - 720
                accounts[index].asOf = accounts[index].fetchedAt
            }
        case "rejected", "error":
            for index in accounts.indices where index == 0 || accounts[index].isCodex {
                accounts[index].state = state == "rejected" ? .tokenRejected : .error
            }
        case "limits":
            if !accounts.isEmpty {
                accounts[0].limits = [
                    LimitInfo(kind: "session", percent: 95, status: "rejected"),
                    LimitInfo(kind: "weekly_all"),
                    LimitInfo(kind: "weekly_scoped", percent: 0,
                              scope: LimitScope(model: LimitModel(displayName: "Sonnet"))),
                ]
                accounts[0].fiveHour = accounts[0].limits?.first
                accounts[0].sevenDay = accounts[0].limits?.dropFirst().first
            }
        default: break
        }
        return accounts
    }
}

@MainActor
extension AppDelegate {
    func scheduleQA() {
        guard qa.enabled else { return }
        let stop = Timer(timeInterval: qa.quitAfter, target: self, selector: #selector(finishQA), userInfo: nil, repeats: false)
        RunLoop.main.add(stop, forMode: .common)
        if qa.open != nil {
            let start = Timer(timeInterval: 1.5, target: self, selector: #selector(openQAUI), userInfo: nil, repeats: false)
            RunLoop.main.add(start, forMode: .common)
        }
    }

    @objc private func openQAUI() {
        guard let kind = qa.open else { return }
        if kind == "menu" {
            if statusItem == nil { minimizeToMenuBar() }
            openStatusMenu()
        } else {
            let tab: SettingsTab
            switch kind {
            case "settings-general": tab = .general
            case "settings-menubar": tab = .menuBar
            case "settings-layout": tab = .layout
            case "settings-accounts": tab = .accounts
            case "settings-about": tab = .about
            default: return
            }
            showSettings(tab: tab)
            let ready = Timer(timeInterval: 0.25, target: self, selector: #selector(announceQAReady), userInfo: nil, repeats: false)
            RunLoop.main.add(ready, forMode: .common)
        }
    }

    @objc func announceQAReady() {
        guard qa.enabled, !qaReadySent, let kind = qa.open else { return }
        guard kind == "menu" ? trackingMenu != nil : settingsController?.window?.isVisible == true else { return }
        qaReadySent = true
        // Write directly to the stdout file descriptor, without a stdio buffer.
        // QA-READY is a machine protocol; operational diagnostics use os.Logger.
        let line = "QA-READY \(ProcessInfo.processInfo.processIdentifier) \(kind)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    @objc private func finishQA() {
        trackingMenu?.cancelTracking()
        statusItem?.menu?.cancelTracking()
        for window in NSApp.windows { window.close() }
        NSApp.terminate(nil)
    }
}
