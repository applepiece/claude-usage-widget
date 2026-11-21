import Cocoa
import ServiceManagement
import SwiftUI
import UsageKit
import os

@MainActor
struct SettingsContent: View {
    let tab: SettingsTab
    let model: AppModel
    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettings(model: model)
            case .menuBar: MenuBarSettings(model: model)
            case .accounts: AccountsSettings(model: model)
            case .about: AboutSettings()
            }
        }
        .monospacedDigit()
        .coordinateSpace(name: "settingsForm")
    }
}

@MainActor
private struct GeneralSettings: View {
    let model: AppModel
    @AppStorage("widgetAccounts") private var widgetAccounts = "primary"
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    private let logger = Logger(subsystem: "com.heng.claude-usage-widget", category: "LoginItems")

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: {
                    loginStatus == .enabled || loginStatus == .requiresApproval
                }, set: setLaunchAtLogin))
                .disabled(model.isQA)
                if loginStatus == .requiresApproval && !model.isQA {
                    Text("Allow Claude Usage in Login Items to launch it at login.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }.measureSettingsSection()
            Section {
                Toggle("Show Claw'd on the desktop", isOn: Binding(get: { model.widgetVisible }, set: model.setWidgetVisible))
                Picker("Show", selection: $widgetAccounts) {
                    Text("Primary account").tag("primary")
                    Text("Primary and secondary").tag("primarySecondary")
                }.pickerStyle(.menu)
            } header: {
                Text("Desktop widget").measureSettingsSection()
            } footer: {
                Text("Tip: click Claw'd's legs to tuck the widget into the menu bar.").measureSettingsSection()
            }.measureSettingsSection()
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard !model.isQA else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            logger.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
            loginError = String(localized: "Couldn't change the login item: \(error.localizedDescription)")
        }
        loginStatus = SMAppService.mainApp.status
    }
}

@MainActor
private struct MenuBarSettings: View {
    let model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("barAccounts") private var accounts = "primary"
    @AppStorage("barMetric") private var metric = "max"
    @AppStorage("barNumbers") private var numbers = true
    @AppStorage("menuBarAlways") private var always = true
    @AppStorage("showAPICredits") private var showAPICredits = true

    private var appearance: NSAppearance { NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance }
    private var shownAccounts: [UsageAccount] {
        if accounts == "all" { return model.accounts }
        return [model.primary, accounts == "primarySecondary" ? model.secondary : nil].compactMap { $0 }
    }
    private var title: StatusTitle {
        StatusTitle(accounts: shownAccounts, shortNames: model.shortNames,
                    metric: BarMetric(rawValue: metric) ?? .max, numbers: numbers)
    }

    var body: some View {
        Form {
            Section {
                Image(nsImage: StatusRenderer.previewImage(title, appearance: appearance))
                    .frame(maxWidth: .infinity).frame(height: 24)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .accessibilityLabel(Text("Menu bar preview"))
                    .accessibilityValue(Text(verbatim: title.accessibilityLabel))
            }.measureSettingsSection()
            Section {
                Picker("Show", selection: $accounts) {
                    Text("Primary account").tag("primary")
                    Text("Primary and secondary").tag("primarySecondary")
                    Text("All accounts").tag("all")
                }.pickerStyle(.menu)
                Picker("Value", selection: $metric) {
                    Text("Most used").tag("max")
                    Text("Session").tag("five")
                    Text("Weekly").tag("seven")
                    Text("Session and weekly").tag("both")
                }.pickerStyle(.menu)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show percentage", isOn: $numbers)
                    Text("Off shows Claw'd alone.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Keep icon in the menu bar", isOn: $always)
                Toggle("Show API credits", isOn: $showAPICredits)
            } footer: {
                Text("When off, the icon appears only while the widget is tucked away.").measureSettingsSection()
            }.measureSettingsSection()
        }
        .formStyle(.grouped)
    }
}

@MainActor
private struct AccountsSettings: View {
    let model: AppModel
    @AppStorage("primaryAccount") private var primary = ""
    @AppStorage("secondaryAccount") private var secondary = "none"

    private func identity(_ account: UsageAccount) -> String {
        [model.shortNames[account.id], account.label, account.providerName, account.email]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        Form {
            Section {
                Picker("Primary account", selection: Binding(get: {
                    model.accounts.contains { $0.id == primary } ? primary : model.primary?.id ?? ""
                }, set: model.makePrimary)) {
                    if model.accounts.isEmpty { Text("No accounts").tag("") }
                    ForEach(model.accounts, id: \.id) { Text(verbatim: identity($0)).tag($0.id) }
                }.pickerStyle(.menu).disabled(model.accounts.isEmpty)
                Picker("Secondary account", selection: Binding(get: {
                    model.accounts.contains { $0.id == secondary && $0.id != model.primary?.id } ? secondary : "none"
                }, set: model.setSecondary)) {
                    Text("None").tag("none")
                    ForEach(model.accounts.filter { $0.id != model.primary?.id }, id: \.id) {
                        Text(verbatim: identity($0)).tag($0.id)
                    }
                }.pickerStyle(.menu).disabled(model.accounts.isEmpty)
            }.measureSettingsSection()
            if !model.accounts.isEmpty {
                Section {
                    ForEach(model.accounts, id: \.id) { AccountSettingsRow(account: $0, model: model) }
                }.measureSettingsSection()
            }
            Section {
                Text(verbatim: model.machineLogin?.email ?? String(localized: "Not signed in"))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    if model.machineLogin == nil {
                        Button("Sign In…", action: model.signIn)
                    } else {
                        Button("Switch Account…", action: model.signIn)
                        Button("Sign Out…", role: .destructive, action: model.signOut)
                    }
                }
            } header: { Text("This Mac's Claude Code login").measureSettingsSection() }.measureSettingsSection()
            Section {
                Link("Open Claude usage page", destination: AppURLs.claudeSettings)
                if model.accounts.contains(where: \.isCodex) {
                    Link("Open Codex usage page", destination: AppURLs.codexSettings)
                }
            }.measureSettingsSection()
        }.formStyle(.grouped)
    }
}

@MainActor
private struct AccountSettingsRow: View {
    let account: UsageAccount
    let model: AppModel
    private var automaticName: String { accountTags(model.accounts)[account.id] ?? "?" }
    private var duplicate: UsageAccount? {
        model.accounts.first { $0.id != account.id && model.shortNames[$0.id] == model.shortNames[account.id] }
    }
    private var suggestions: [String] {
        var values = [account.label, account.label.uppercased(), String(account.label.prefix(2)).uppercased()]
        if account.isCodex { values.append("›" + account.label.uppercased()) }
        return values
    }
    private var status: String {
        switch account.state {
        case .ok: String(localized: "Up to date")
        case .stale: String(localized: "Stale")
        case .tokenRejected: String(localized: "Sign-in expired")
        case .error: String(localized: "Error")
        }
    }
    private var statusColor: Color {
        switch account.state {
        case .ok: .green
        case .stale, .error: .orange
        case .tokenRejected: .red
        }
    }
    private var renewal: String {
        if account.isCodex { return "bridge-accounts/login-all.sh codex" }
        // Quote labels with shell metacharacters so the copyable command is safe.
        let label = account.label
        let safe = !label.isEmpty && label.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }
        let argument = safe ? label : "'" + label.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "scripts/add-account.sh " + argument
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: accountAvatar(account, size: 32)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: account.label).fontWeight(.semibold).lineLimit(1)
                    Text(verbatim: account.email ?? "").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Circle().fill(statusColor).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(status).font(.caption)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Text("Short name").padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        // An explicit prompt plus hidden label keeps the automatic tag inside
                        // the field as placeholder text; a grouped Form otherwise shows the title as a row label.
                        TextField(text: Binding(get: {
                            model.customShortName(for: account.id)
                        }, set: { model.setShortName($0, for: account.id) }), prompt: Text(verbatim: automaticName)) {
                            Text("Short name for \(account.label)")
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .accessibilityLabel(Text("Short name for \(account.label)"))
                        Menu {
                            Button("Automatic (\(automaticName))") { model.setShortName("", for: account.id) }
                            ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                                Button { model.setShortName(suggestion, for: account.id) } label: {
                                    Text(verbatim: suggestion)
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel(Text("Short name suggestions for \(account.label)"))
                    }
                    if let duplicate {
                        Text("Same as \(duplicate.label)").font(.caption)
                            .foregroundStyle(Color(nsColor: .systemOrange))
                    }
                }
            }
            if account.state == .tokenRejected {
                HStack(alignment: .top, spacing: 8) {
                    Text(verbatim: renewal).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(renewal, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .accessibilityLabel(Text("Copy renewal command"))
                    .help("Copy renewal command")
                }
            }
        }.accessibilityElement(children: .contain)
    }
}

@MainActor
private struct AboutSettings: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.0" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "300" }
    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                    Text("Claude Usage").font(.title2).fontWeight(.semibold)
                    Text("Version \(version) (\(build))").foregroundStyle(.secondary)
                    Text("Claude Usage reads your limits directly from Anthropic and OpenAI. It collects nothing and sends nothing anywhere else.")
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Link("Source code", destination: AppURLs.sourceCode)
                }.frame(maxWidth: .infinity)
            }.measureSettingsSection()
        }.formStyle(.grouped)
    }
}
