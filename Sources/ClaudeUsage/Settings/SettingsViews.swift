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
    @AppStorage("barStyle") private var style = "battery"
    @AppStorage("barAccounts") private var accounts = "primary"
    @AppStorage("barMetric") private var metric = "max"
    @AppStorage("barNumbers") private var numbers = true
    @AppStorage("menuBarAlways") private var always = true

    private var showsBoth: Bool { style == "dual" || style == "ring" }
    private var appearance: NSAppearance { NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance }
    private var shownAccounts: [UsageAccount] {
        if accounts == "all" { return model.accounts }
        return [model.primary, accounts == "primarySecondary" ? model.secondary : nil].compactMap { $0 }
    }
    private func image(_ sampleStyle: BarStyle, preview: Bool) -> NSImage {
        StatusRenderer.image(accounts: preview ? shownAccounts : [model.primary].compactMap { $0 },
                             tags: accountTags(model.accounts), style: sampleStyle,
                             metric: BarMetric(rawValue: metric) ?? .max, numbers: numbers, appearance: appearance)
    }
    private func title(_ style: BarStyle) -> String {
        switch style {
        case .percent: String(localized: "Percent")
        case .battery: String(localized: "Battery")
        case .hp: String(localized: "HP Bar")
        case .dual: String(localized: "Dual Bars")
        case .ring: String(localized: "Ring")
        }
    }

    var body: some View {
        Form {
            Section {
                Image(nsImage: image(BarStyle(rawValue: style) ?? .battery, preview: true))
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .background(Color(nsColor: .windowBackgroundColor), in: ButtonBorderShape.roundedRectangle)
                    .accessibilityLabel(Text("Menu bar preview"))
                    .accessibilityValue(Text(verbatim: shownAccounts.map { MenuFormatting.accountSubtitle($0, now: Date()) }.joined(separator: ", ")))
            }.measureSettingsSection()
            Section {
                HStack(spacing: 8) {
                    ForEach(BarStyle.allCases, id: \.rawValue) { candidate in
                        Button { style = candidate.rawValue } label: {
                            VStack(spacing: 4) {
                                Image(nsImage: image(candidate, preview: false)).accessibilityHidden(true)
                                Text(title(candidate)).font(.caption)
                                    .foregroundStyle(style == candidate.rawValue ? Color.accentColor : .primary)
                            }
                            .frame(width: 80, height: 56)
                            .contentShape(ButtonBorderShape.roundedRectangle)
                            .overlay(ButtonBorderShape.roundedRectangle
                                .strokeBorder(style == candidate.rawValue ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .focusable()
                        .accessibilityLabel(Text(title(candidate)))
                        .accessibilityAddTraits(style == candidate.rawValue ? .isSelected : [])
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            } header: { Text("Style").measureSettingsSection() }.measureSettingsSection()
            Section {
                Picker("Accounts", selection: $accounts) {
                    Text("Primary only").tag("primary")
                    Text("Primary and secondary").tag("primarySecondary")
                    Text("All accounts").tag("all")
                }.pickerStyle(.menu)
                Picker("Value", selection: $metric) {
                    Text("Most used").tag("max")
                    Text("Session").tag("five")
                    Text("Weekly").tag("seven")
                    Text("Both").tag("both")
                }.pickerStyle(.menu).disabled(showsBoth)
                if showsBoth {
                    Text("Dual Bars and Ring always show both windows.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Show numbers", isOn: $numbers)
                Toggle("Keep icon in the menu bar", isOn: $always)
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
        [account.label, account.providerName, account.email].compactMap { $0 }.joined(separator: " · ")
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
                    ForEach(model.accounts, id: \.id) { AccountSettingsRow(account: $0) }
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
