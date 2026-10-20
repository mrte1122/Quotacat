import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updater: Updater

    var body: some View {
        TabView {
            GeneralSettings(store: store, updater: updater).tabItem { Label("General", systemImage: "gearshape") }
            ActivitySettings(store: store).tabItem { Label("Activity", systemImage: "bell.badge") }
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
    @ObservedObject var updater: Updater
    @AppStorage(SettingsKey.autoUpdateCheck) private var autoUpdate = true
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

    private var updateStatus: String {
        switch updater.state {
        case .checking: return "Checking…"
        case .upToDate: return "Quotacat is up to date."
        case .available(let r): return "Version \(r.version) is available."
        case .installing(let step): return step
        case .failed(let message): return message
        case .idle:
            return updater.lastChecked.map { "Last checked \($0.formatted(.relative(presentation: .named)))." } ?? "Not checked yet."
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
            Section("About") {
                LabeledContent("Version", value: Updater.currentVersion)
                HStack {
                    Text(updateStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let release = updater.availableRelease {
                        Button("Install \(release.version)") { Task { await updater.install(release) } }
                    } else {
                        Button("Check for Updates") { Task { await updater.check(userInitiated: true) } }
                            .disabled(updater.state == .checking)
                    }
                }
                Toggle("Check for updates automatically (daily)", isOn: $autoUpdate)
                HStack {
                    Link("Source on GitHub", destination: Links.repo)
                    Spacer()
                    Link(destination: Links.tip) {
                        Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                    }
                }
                Text("Quotacat is free and open source. If it saves you a surprise bill, a tip is appreciated.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Pull requests and GitHub Actions: what to show, badge and notify about, and which repos to watch.
private struct ActivitySettings: View {
    @ObservedObject var store: UsageStore
    @AppStorage(SettingsKey.pullRequestsEnabled) private var pullRequests = true
    @AppStorage(SettingsKey.menuBarPullRequests) private var menuBarPullRequests = true
    @AppStorage(SettingsKey.notifyReviewRequests) private var notifyReviewRequests = true
    @AppStorage(SettingsKey.actionsEnabled) private var actions = true
    @AppStorage(SettingsKey.menuBarActions) private var menuBarActions = true
    @AppStorage(SettingsKey.notifyActions) private var notifyActions = true
    @AppStorage(SettingsKey.actionsRepoMode) private var repoMode = "recent"
    @State private var selected = Set(UserDefaults.standard.stringArray(forKey: SettingsKey.actionsSelectedRepos) ?? [])
    @State private var filter = ""

    private func refreshSoon() { Task { await store.refreshActivity() } }

    var body: some View {
        Form {
            Section("Pull requests") {
                Toggle("Show pull requests", isOn: $pullRequests)
                    .onChange(of: pullRequests) { _, on in if on { refreshSoon() } }
                Group {
                    Toggle("Show reviews waiting on me in the menu bar", isOn: $menuBarPullRequests)
                    Toggle("Notify me about new review requests", isOn: $notifyReviewRequests)
                        .onChange(of: notifyReviewRequests) { _, on in if on { store.notifier.requestAuthorization() } }
                }
                .disabled(!pullRequests)
            }
            Section("GitHub Actions") {
                Toggle("Show failing workflows", isOn: $actions)
                    .onChange(of: actions) { _, on in if on { refreshSoon() } }
                Group {
                    Toggle("Show the failure count in the menu bar", isOn: $menuBarActions)
                    Toggle("Notify me when a workflow fails or recovers", isOn: $notifyActions)
                        .onChange(of: notifyActions) { _, on in if on { store.notifier.requestAuthorization() } }
                    Picker("Watch", selection: $repoMode) {
                        Text("Repositories pushed in the last 30 days").tag("recent")
                        Text("Repositories I choose").tag("selected")
                    }
                    .onChange(of: repoMode) { _, _ in refreshSoon() }
                    if repoMode == "selected" { repoPicker }
                }
                .disabled(!actions)
                Text("A workflow counts as failing when its latest completed run on the repository's default branch failed. Checked every 2 minutes; unchanged repositories don't use your API limit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var repoPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Filter repositories", text: $filter)
            if store.availableRepos.isEmpty {
                Text("Loading repositories…").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.availableRepos.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }, id: \.self) { repo in
                            Toggle(repo, isOn: Binding(
                                get: { selected.contains(repo) },
                                set: { on in
                                    if on { selected.insert(repo) } else { selected.remove(repo) }
                                    UserDefaults.standard.set(Array(selected).sorted(), forKey: SettingsKey.actionsSelectedRepos)
                                    refreshSoon()
                                }))
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
                Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AppearanceSettings: View {
    @AppStorage(SettingsKey.iconStyle) private var iconStyle = IconStyle.progressBar.rawValue
    @AppStorage(SettingsKey.theme) private var theme = ThemeChoice.system.rawValue
    @AppStorage(SettingsKey.monochrome) private var monochrome = false
    @AppStorage(SettingsKey.showRemaining) private var showRemaining = false
    @AppStorage(SettingsKey.showLabels) private var showLabels = true
    @AppStorage(SettingsKey.showCountdown) private var showCountdown = false
    @AppStorage(SettingsKey.paceColoring) private var paceColoring = true
    @AppStorage(SettingsKey.showTimeMarker) private var showTimeMarker = true
    @AppStorage(SettingsKey.radialMeters) private var radialMeters = false

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Popover and Settings", selection: $theme) {
                    ForEach(ThemeChoice.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Text("System follows your Mac's Light or Dark setting. The menu-bar icon always matches the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
            Section("Popover") {
                Toggle("Radial meters instead of bars", isOn: $radialMeters)
                Text("Draws each quota as a ring with the percentage inside. The time marker becomes a tick on the ring.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Pace") {
                Toggle("Pace-aware meter colors", isOn: $paceColoring)
                Toggle("Show time marker on bars and rings", isOn: $showTimeMarker)
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
    @AppStorage(SettingsKey.actionsQuotaFromPlan) private var fromPlan = true
    @AppStorage(SettingsKey.actionsQuota) private var actions = 2000.0
    @AppStorage(SettingsKey.copilotCredits) private var credits = 10.0
    @AppStorage(SettingsKey.copilotQuota) private var requests = 300.0

    private var planMinutes: Double? { store.plan.flatMap { UsageStore.planActionsMinutes[$0] } }

    private func apply() { Task { await store.refresh(notify: false) } }

    var body: some View {
        Form {
            Section("Actions minutes") {
                Toggle(planMinutes.map { "Use my plan's allowance (\(store.plan!.capitalized): \(Int($0).formatted()) minutes)" }
                       ?? "Use my plan's allowance (needs the `user` scope)", isOn: $fromPlan)
                    .disabled(planMinutes == nil)
                    .onChange(of: fromPlan) { _, _ in apply() }
                TextField("Included minutes / month", value: $actions, format: .number)
                    .disabled(fromPlan && planMinutes != nil)
                    .onSubmit(apply)
                Text("Counted the way GitHub does: in standard Linux minutes, where macOS runners use about 10× and Windows 2×, and public repositories are free.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Copilot") {
                Picker("Plan", selection: Binding(
                    get: { credits == 10 ? "pro" : credits == 39 ? "pro+" : "custom" },
                    set: { v in if v == "pro" { credits = 10 } else if v == "pro+" { credits = 39 }; apply() })) {
                    Text("Pro ($10 of AI Credits)").tag("pro")
                    Text("Pro+ ($39 of AI Credits)").tag("pro+")
                    Text("Custom").tag("custom")
                }
                TextField("Included AI Credits ($ / month)", value: $credits, format: .number.precision(.fractionLength(2)))
                    .onSubmit(apply)
                TextField("Premium requests / month (annual plans)", value: $requests, format: .number)
                    .onSubmit(apply)
                Text("Since June 2026 Copilot bills AI Credits in dollars. Annual plans keep premium requests until they renew; Quotacat shows whichever your account uses.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
