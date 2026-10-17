import AppKit
import Foundation
import Network

/// Refresh coordinator + model. Mirrors Claude Usage's `UsageRefreshCoordinator` / `MenuBarManager`:
/// interval timer, wake-from-sleep refresh with debounce, refresh when the network comes back.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var metrics: [MetricKind: UsageMetric] = [:]
    @Published private(set) var issues: [MetricKind: String] = [:]
    @Published private(set) var login: String?
    @Published private(set) var tokenSource: TokenSource?
    @Published private(set) var scopes: Set<String>?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var consecutiveFailures = 0
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var now = Date()

    let notifier = Notifier()
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    private var scheduledInterval: TimeInterval = 0
    private var lastRefreshStart = Date.distantPast
    private let pathMonitor = NWPathMonitor()
    private var networkWasDown = false
    private static let triggerDebounce: TimeInterval = 30

    var hasData: Bool { !metrics.isEmpty }

    func start() {
        rescheduleIfNeeded()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Give Wi-Fi a moment to reassociate before hitting the network.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                Task { @MainActor in self?.triggeredRefresh() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rescheduleIfNeeded() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                if path.status == .satisfied {
                    if self.networkWasDown { self.networkWasDown = false; self.triggeredRefresh() }
                } else {
                    self.networkWasDown = true
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Quotacat.network"))
        Task { await refresh() }
    }

    private func rescheduleIfNeeded() {
        let raw = UserDefaults.standard.double(forKey: SettingsKey.refreshInterval)
        let interval = min(300, max(10, raw))
        guard interval != scheduledInterval else { return }
        scheduledInterval = interval
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        refreshTimer?.tolerance = interval * 0.1
    }

    /// Wake / network refreshes are debounced so a flapping connection doesn't hammer the API.
    private func triggeredRefresh() {
        guard Date().timeIntervalSince(lastRefreshStart) > Self.triggerDebounce else { return }
        Task { await refresh() }
    }

    func refresh(notify: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefreshStart = Date()
        defer { isRefreshing = false; now = Date() }

        let preferPAT = UserDefaults.standard.bool(forKey: SettingsKey.preferPAT)
        let credential = await Task.detached { CredentialProvider.resolve(preferPAT: preferPAT) }.value
        guard let credential else {
            tokenSource = nil
            consecutiveFailures += 1
            lastError = "No GitHub credentials. Run `gh auth login`, or add a token in Settings → Account."
            return
        }
        tokenSource = credential.source
        let client = GitHubClient(token: credential.token)

        do {
            let user = try await client.fetchUser()
            login = user.login
            scopes = user.scopes
            let limits = try await client.fetchRateLimits()

            var newMetrics: [MetricKind: UsageMetric] = [:]
            var newIssues: [MetricKind: String] = [:]
            let windows: [(MetricKind, String, TimeInterval)] = [
                (.core, "core", 3600), (.graphql, "graphql", 3600), (.search, "search", 60),
            ]
            for (kind, key, length) in windows {
                guard let r = limits[key] else { continue }
                let reset = Date(timeIntervalSince1970: r.reset)
                newMetrics[kind] = UsageMetric(kind: kind, used: r.used, limit: r.limit,
                                               periodStart: reset.addingTimeInterval(-length), resetAt: reset)
            }

            if let s = user.scopes, !s.contains("user") {
                for k in MetricKind.billing { newIssues[k] = GitHubError.needsUserScope.localizedDescription }
            } else {
                let (billing, billingIssues) = await loadBilling(client: client, login: user.login)
                newMetrics.merge(billing) { $1 }
                newIssues.merge(billingIssues) { $1 }
            }

            metrics = newMetrics
            issues = newIssues
            lastUpdated = Date()
            consecutiveFailures = 0
            lastError = nil
            if notify { notifier.evaluate(Array(newMetrics.values)) }
            writeCache()
        } catch {
            consecutiveFailures += 1
            lastError = error.localizedDescription
        }
    }

    private func loadBilling(client: GitHubClient, login: String) async
        -> ([MetricKind: UsageMetric], [MetricKind: String])
    {
        let date = Date()
        let (start, end) = UsageMath.monthBounds(containing: date)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let year = cal.component(.year, from: date), month = cal.component(.month, from: date)
        let defaults = UserDefaults.standard

        async let usageRequest = client.fetchBillingUsage(user: login, year: year, month: month)
        async let premiumRequest = client.fetchPremiumRequests(user: login, year: year, month: month)

        var out: [MetricKind: UsageMetric] = [:]
        var issues: [MetricKind: String] = [:]
        var copilotDaily: [DailyPoint] = []

        do {
            let usage = try await usageRequest
            let actions = usage.filter {
                ($0.product ?? "").lowercased() == "actions" && ($0.unitType ?? "").lowercased() == "minutes"
            }
            out[.actions] = UsageMetric(
                kind: .actions,
                used: actions.reduce(0) { $0 + ($1.quantity ?? 0) },
                limit: defaults.double(forKey: SettingsKey.actionsQuota),
                periodStart: start, resetAt: end,
                netAmount: actions.reduce(0) { $0 + ($1.netAmount ?? 0) },
                breakdown: Self.group(actions.map { ($0.repositoryName ?? $0.sku ?? "Other", $0.quantity ?? 0, $0.netAmount ?? 0) }),
                daily: Self.daily(actions.map { ($0.date, $0.quantity ?? 0) })
            )
            copilotDaily = Self.daily(usage
                .filter { ($0.sku ?? "").lowercased().contains("premium request") }
                .map { ($0.date, $0.quantity ?? 0) })
        } catch {
            issues[.actions] = error.localizedDescription
        }

        do {
            let items = try await premiumRequest
            out[.copilot] = UsageMetric(
                kind: .copilot,
                used: items.reduce(0) { $0 + ($1.grossQuantity ?? 0) },
                limit: defaults.double(forKey: SettingsKey.copilotQuota),
                periodStart: start, resetAt: end,
                netAmount: items.reduce(0) { $0 + ($1.netAmount ?? 0) },
                breakdown: Self.group(items.map { ($0.model ?? $0.sku ?? "Other", $0.grossQuantity ?? 0, $0.netAmount ?? 0) }),
                daily: copilotDaily
            )
        } catch {
            issues[.copilot] = error.localizedDescription
        }
        return (out, issues)
    }

    private static func group(_ rows: [(String, Double, Double)]) -> [BreakdownItem] {
        var totals: [String: (Double, Double)] = [:]
        for (label, q, amt) in rows {
            let t = totals[label] ?? (0, 0)
            totals[label] = (t.0 + q, t.1 + amt)
        }
        return totals.map { BreakdownItem(label: $0.key, quantity: $0.value.0, netAmount: $0.value.1) }
            .filter { $0.quantity > 0 }
            .sorted { $0.quantity > $1.quantity }
    }

    private static func daily(_ rows: [(String?, Double)]) -> [DailyPoint] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let iso = ISO8601DateFormatter()
        let dayOnly = DateFormatter()
        dayOnly.calendar = cal
        dayOnly.timeZone = cal.timeZone
        dayOnly.dateFormat = "yyyy-MM-dd"
        var totals: [Date: Double] = [:]
        for (raw, q) in rows {
            guard let raw, let d = iso.date(from: raw) ?? dayOnly.date(from: String(raw.prefix(10))) else { continue }
            totals[cal.startOfDay(for: d), default: 0] += q
        }
        return totals.map { DailyPoint(date: $0.key, quantity: $0.value) }.sorted { $0.date < $1.date }
    }

    /// Sample data for README screenshots (`--snapshot DIR --demo`), so no real account data is published.
    func loadDemo() {
        let now = Date()
        let (start, end) = UsageMath.monthBounds(containing: now)
        let cal = Calendar(identifier: .gregorian)
        let days = (0..<max(1, cal.dateComponents([.day], from: start, to: now).day ?? 1)).map {
            DailyPoint(date: cal.date(byAdding: .day, value: $0, to: start)!, quantity: Double([40, 85, 20, 130, 60, 95, 10][$0 % 7]))
        }
        func window(_ kind: MetricKind, _ used: Double, _ limit: Double, _ resetIn: TimeInterval, _ length: TimeInterval) -> UsageMetric {
            let reset = now.addingTimeInterval(resetIn)
            return UsageMetric(kind: kind, used: used, limit: limit, periodStart: reset.addingTimeInterval(-length), resetAt: reset)
        }
        metrics = [
            .core: window(.core, 3120, 5000, 22 * 60, 3600),
            .graphql: window(.graphql, 410, 5000, 41 * 60, 3600),
            .search: window(.search, 4, 30, 40, 60),
            .actions: UsageMetric(kind: .actions, used: 1240, limit: 2000, periodStart: start, resetAt: end, netAmount: 0,
                                  breakdown: [.init(label: "you/web-app", quantity: 820, netAmount: 0),
                                              .init(label: "you/cli-tool", quantity: 420, netAmount: 0)],
                                  daily: days),
            .copilot: UsageMetric(kind: .copilot, used: 212, limit: 300, periodStart: start, resetAt: end, netAmount: 0,
                                  breakdown: [.init(label: "Claude Sonnet", quantity: 150, netAmount: 0),
                                              .init(label: "GPT-5", quantity: 62, netAmount: 0)]),
        ]
        issues = [:]
        login = "you"
        tokenSource = .ghCLI
        lastUpdated = now
        lastError = nil
        self.now = now
    }

    static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quotacat/usage.json")
    }

    /// Like Claude Usage's statusline cache: lets a shell prompt show usage without calling the API.
    private func writeCache() {
        let file = UsageCacheFile(
            login: login, updatedAt: Date(),
            metrics: MetricKind.allCases.compactMap { k in
                metrics[k].map { .init(kind: k.rawValue, used: $0.used, limit: $0.limit,
                                       percent: Int(($0.fraction * 100).rounded()), resetAt: $0.resetAt) }
            })
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(file) else { return }
        let url = Self.cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
