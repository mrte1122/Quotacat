import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        TabView {
            GeneralSettings(store: store).tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "menubar.rectangle") }
            AccountSettings(store: store).tabItem { Label("Account", systemImage: "person.crop.circle") }
            QuotaSettings(store: store).tabItem { Label("Quotas", systemImage: "gauge.with.dots.needle.50percent") }
        }
        .padding(16)
        .frame(width: 500, height: 420)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var store: UsageStore
    @AppStorage(SettingsKey.refreshInterval) private var interval = 60.0
    @AppStorage(SettingsKey.notificationsEnabled) private var notifications = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    // Same slider range and named presets as Claude Usage (10s Real-time … 300s Battery saver).
    private var preset: String {
        switch interval {
        case ...15: return "Real-time"
        case ...30: return "Frequent"
        case ...90: return "Balanced"
        case ...180: return "Power efficient"
        default: return "Battery saver"
        }
    }

    var body: some View {
        Form {
            Section("Refresh interval") {
                Slider(value: $interval, in: 10...300, step: 5) {
                    Text("\(Int(interval)) seconds")
                } minimumValueLabel: { Text("10s") } maximumValueLabel: { Text("300s") }
                Text("\(preset). Rate-limit checks are free; billing data updates a few times a day on GitHub's side.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Alert at 75%, 90%, and 95%, and when a limit resets", isOn: $notifications)
                    .onChange(of: notifications) { _, on in if on { store.notifier.requestAuthorization() } }
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettings: View {
    @AppStorage(SettingsKey.iconStyle) private var iconStyle = IconStyle.progressBar.rawValue
    @AppStorage(SettingsKey.monochrome) private var monochrome = false
    @AppStorage(SettingsKey.showRemaining) private var showRemaining = false
    @AppStorage(SettingsKey.showLabels) private var showLabels = true
    @AppStorage(SettingsKey.showCountdown) private var showCountdown = false
    @AppStorage(SettingsKey.paceColoring) private var paceColoring = true
    @AppStorage(SettingsKey.showTimeMarker) private var showTimeMarker = true

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Icon style", selection: $iconStyle) {
                    ForEach(IconStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                ForEach(MetricKind.allCases) { kind in
                    MenuBarToggle(kind: kind)
                }
                Toggle("Show labels (R, G, S, A, C)", isOn: $showLabels)
                Toggle("Show time until reset (→2H)", isOn: $showCountdown)
                Toggle("Show remaining instead of used", isOn: $showRemaining)
                Toggle("Monochrome (adapts to light and dark menu bars)", isOn: $monochrome)
            }
            Section("Pace") {
                Toggle("Pace-aware bar colors", isOn: $paceColoring)
                Toggle("Show time marker on bars", isOn: $showTimeMarker)
                Text("Pace projects usage to the end of the window: green under 50%, then teal, yellow, orange, red at 100%+, and purple at 120%+.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MenuBarToggle: View {
    let kind: MetricKind
    @AppStorage private var on: Bool

    init(kind: MetricKind) {
        self.kind = kind
        _on = AppStorage(wrappedValue: false, SettingsKey.menuBar(kind))
    }

    var body: some View {
        Toggle("Show \(kind.title)", isOn: $on)
    }
}

private struct AccountSettings: View {
    @ObservedObject var store: UsageStore
    @AppStorage(SettingsKey.preferPAT) private var preferPAT = false
    @State private var token = ""
    @State private var hasStoredToken = Keychain.loadToken() != nil
    @State private var copied = false

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Account", value: store.login.map { "@\($0)" } ?? "Not connected")
                LabeledContent("Credential", value: store.tokenSource?.rawValue ?? "None")
                LabeledContent("Token scopes", value: store.scopes.map { $0.sorted().joined(separator: ", ") } ?? "Not reported (fine-grained token)")
                LabeledContent("GitHub CLI", value: CredentialProvider.ghPath ?? "Not found")
            }
            Section("Billing access") {
                Text("Actions minutes and Copilot premium requests need the `user` scope. To add it to your GitHub CLI login, run:")
                    .font(.caption)
                HStack {
                    Text(IssueRow.scopeCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(IssueRow.scopeCommand, forType: .string)
                        copied = true
                    }
                }
            }
            Section("Personal access token (optional)") {
                SecureField(hasStoredToken ? "Token saved in Keychain" : "ghp_… or github_pat_…", text: $token)
                HStack {
                    Button("Save to Keychain") {
                        Keychain.saveToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
                        token = ""
                        hasStoredToken = true
                        Task { await store.refresh(notify: false) }
                    }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Remove") {
                        Keychain.deleteToken()
                        hasStoredToken = false
                        Task { await store.refresh(notify: false) }
                    }
                    .disabled(!hasStoredToken)
                    Spacer()
                    Link("Create token", destination: URL(string: "https://github.com/settings/tokens/new?scopes=user&description=GitHub%20Usage%20Monitor")!)
                }
                Toggle("Prefer this token over the GitHub CLI login", isOn: $preferPAT)
                    .onChange(of: preferPAT) { _, _ in Task { await store.refresh(notify: false) } }
            }
        }
        .formStyle(.grouped)
    }
}

private struct QuotaSettings: View {
    @ObservedObject var store: UsageStore
    @AppStorage(SettingsKey.actionsQuota) private var actions = 2000.0
    @AppStorage(SettingsKey.copilotQuota) private var copilot = 300.0

    var body: some View {
        Form {
            Section {
                TextField("Included Actions minutes / month", value: $actions, format: .number)
                Text("Free: 2,000 · Pro: 3,000 · Team: 3,000 · Enterprise: 50,000").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("Copilot premium requests / month", value: $copilot, format: .number)
                Text("Copilot Free: 50 · Pro: 300 · Pro+: 1,500").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("GitHub only reports your plan to tokens with the `user` scope, so set your included amounts here.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Apply") { Task { await store.refresh(notify: false) } }
            }
        }
        .formStyle(.grouped)
    }
}
