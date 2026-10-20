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
    /// GitHub plan name ("free", "pro", …), when the token has the `user` scope.
    @Published private(set) var plan: String?
    @Published private(set) var pullRequests: PullRequestQueue?
    @Published private(set) var pullRequestIssue: String?
    private var lastPullRequestFetch = Date.distantPast
    @Published private(set) var actions: ActionsStatus?
    @Published private(set) var actionsIssue: String?
    /// Every non-archived repository the token can see, for the Settings picker.
    @Published private(set) var availableRepos: [String] = []
    private let actionsFetcher = ActionsFetcher()
    private var repoCache: [RepoSummary] = []
    private var lastRepoFetch = Date.distantPast
    private var lastActionsFetch = Date.distantPast
    static let recentRepoLimit = 20
    /// PR lists change slowly; don't spend API calls on them every 10 seconds.
    private static let pullRequestInterval: TimeInterval = 120

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

    func refresh(notify: Bool = true, forceActivity: Bool = false) async {
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
            plan = user.plan
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
                let (billing, billingIssues) = await loadBilling(client: client, login: user.login,
                                                                  token: credential.token, plan: user.plan)
                newMetrics.merge(billing) { $1 }
                newIssues.merge(billingIssues) { $1 }
            }

            if UserDefaults.standard.bool(forKey: SettingsKey.pullRequestsEnabled),
               forceActivity || Date().timeIntervalSince(lastPullRequestFetch) >= Self.pullRequestInterval {
                do {
                    let queue = try await client.fetchPullRequests(login: user.login)
                    pullRequests = queue
                    pullRequestIssue = nil
                    lastPullRequestFetch = Date()
                    if notify { notifier.evaluateReviewRequests(queue.waitingOnYou) }
                } catch {
                    // A PR failure shouldn't hide the quota data that did load.
                    pullRequestIssue = error.localizedDescription
                }
            }

            if UserDefaults.standard.bool(forKey: SettingsKey.actionsEnabled),
               forceActivity || Date().timeIntervalSince(lastActionsFetch) >= Self.pullRequestInterval {
                do {
                    let status = try await loadActions(token: credential.token)
                    actions = status
                    actionsIssue = nil
                    lastActionsFetch = Date()
                    if notify { notifier.evaluateActions(status) }
                } catch {
                    actionsIssue = error.localizedDescription
                }
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

    private func loadBilling(client: GitHubClient, login: String, token: String, plan: String?) async
        -> ([MetricKind: UsageMetric], [MetricKind: String])
    {
        let date = Date()
        let (start, end) = UsageMath.monthBounds(containing: date)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let year = cal.component(.year, from: date), month = cal.component(.month, from: date)
        let defaults = UserDefaults.standard

        async let usageRequest = client.fetchBillingUsage(user: login, year: year, month: month)
        async let creditsRequest = client.fetchAICredits(user: login, year: year, month: month)
        async let premiumRequest = client.fetchPremiumRequests(user: login, year: year, month: month)
        // Public repositories' Actions minutes are free and don't use the plan's allowance.
        let publicRepos = Set((try? await ensureRepos(token: token))?.filter { !$0.isPrivate }
            .map { $0.fullName.split(separator: "/").last.map(String.init)?.lowercased() ?? "" } ?? [])

        var out: [MetricKind: UsageMetric] = [:]
        var issues: [MetricKind: String] = [:]
        var usageRows: [BillingItem] = []

        do {
            usageRows = try await usageRequest
            out[.actions] = Self.actionsMetric(rows: usageRows, publicRepos: publicRepos,
                                               included: Self.includedActionsMinutes(plan: plan), start: start, end: end)
        } catch {
            issues[.actions] = error.localizedDescription
        }

        let credits = try? await creditsRequest
        let premium = try? await premiumRequest
        if credits == nil && premium == nil {
            issues[.copilot] = GitHubError.notAvailable("Copilot billing data unavailable.").localizedDescription
        } else {
            out[.copilot] = Self.copilotMetric(credits: credits ?? [], premium: premium ?? [], usageRows: usageRows,
                                               includedCredits: defaults.double(forKey: SettingsKey.copilotCredits),
                                               includedRequests: defaults.double(forKey: SettingsKey.copilotQuota),
                                               start: start, end: end)
        }
        return (out, issues)
    }

    /// Included Actions minutes per month by GitHub plan (standard Linux runner minutes).
    nonisolated static let planActionsMinutes: [String: Double] = ["free": 2000, "pro": 3000, "team": 3000, "enterprise": 50000]

    static func includedActionsMinutes(plan: String?) -> Double {
        let d = UserDefaults.standard
        if d.bool(forKey: SettingsKey.actionsQuotaFromPlan), let plan, let minutes = planActionsMinutes[plan] {
            return minutes
        }
        return d.double(forKey: SettingsKey.actionsQuota)
    }

    /// Actions minutes as GitHub actually counts them against the allowance.
    ///
    /// The allowance is in standard Linux minutes; other runners cost more per minute (macOS
    /// about 10x, Windows about 2x), and public repositories are free. The billing report applies
    /// the allowance as a dollar discount, so: allowance used = discount on private-repo minutes
    /// / Linux price. Anything beyond it shows up as the net (billed) amount.
    nonisolated static func actionsMetric(rows: [BillingItem], publicRepos: Set<String>, included: Double,
                              start: Date, end: Date) -> UsageMetric {
        let minutes = rows.filter {
            ($0.product ?? "").lowercased() == "actions" && ($0.unitType ?? "").lowercased() == "minutes"
        }
        let linuxRate = minutes.first { ($0.sku ?? "").lowercased() == "actions linux" }?.pricePerUnit ?? 0.006
        let counted = minutes.filter { !publicRepos.contains(($0.repositoryName ?? "").lowercased()) }
        func equivalent(_ r: BillingItem) -> Double { (r.grossAmount ?? 0) / linuxRate }
        let hasWeighted = counted.contains { ($0.pricePerUnit ?? linuxRate) > linuxRate * 1.01 }
        return UsageMetric(
            kind: .actions,
            used: counted.reduce(0) { $0 + ($1.discountAmount ?? 0) } / linuxRate,
            limit: included,
            periodStart: start, resetAt: end,
            netAmount: minutes.reduce(0) { $0 + ($1.netAmount ?? 0) },
            breakdown: group(counted.map { ($0.repositoryName ?? $0.sku ?? "Other", equivalent($0), $0.netAmount ?? 0) }),
            daily: daily(counted.map { ($0.date, equivalent($0)) }),
            note: hasWeighted ? "Counted as Linux minutes: macOS runners use about 10×, Windows 2×. Public repos are free." : nil)
    }

    /// Copilot since June 2026 bills AI Credits in dollars. Annual plans keep premium requests until
    /// renewal, so fall back to those when there's request usage but no credit usage.
    nonisolated static func copilotMetric(credits: [PremiumItem], premium: [PremiumItem], usageRows: [BillingItem],
                              includedCredits: Double, includedRequests: Double,
                              start: Date, end: Date) -> UsageMetric {
        let premiumUsed = premium.reduce(0) { $0 + ($1.grossQuantity ?? 0) }
        if credits.isEmpty && premiumUsed > 0 {
            return UsageMetric(
                kind: .copilot, used: premiumUsed, limit: includedRequests, periodStart: start, resetAt: end,
                netAmount: premium.reduce(0) { $0 + ($1.netAmount ?? 0) },
                breakdown: group(premium.map { ($0.model ?? $0.sku ?? "Other", $0.grossQuantity ?? 0, $0.netAmount ?? 0) }),
                title: "Copilot Premium Requests")
        }
        let copilotRows = usageRows.filter { ($0.product ?? "").lowercased() == "copilot" }
        return UsageMetric(
            kind: .copilot,
            used: credits.reduce(0) { $0 + ($1.grossAmount ?? 0) },
            limit: includedCredits,
            periodStart: start, resetAt: end,
            netAmount: credits.reduce(0) { $0 + ($1.netAmount ?? 0) },
            breakdown: group(credits.map { ($0.model ?? $0.sku ?? "Other", $0.grossAmount ?? 0, $0.netAmount ?? 0) }),
            daily: daily(copilotRows.map { ($0.date, $0.grossAmount ?? 0) }),
            isCurrency: true)
    }

    /// The repository list (shared with the Actions tab), refreshed every 30 minutes.
    private func ensureRepos(token: String) async throws -> [RepoSummary] {
        if repoCache.isEmpty || Date().timeIntervalSince(lastRepoFetch) > 1800 {
            repoCache = try await actionsFetcher.repositories(token: token)
            lastRepoFetch = Date()
            availableRepos = repoCache.filter { !$0.archived }.map(\.fullName).sorted { $0.lowercased() < $1.lowercased() }
        }
        return repoCache
    }

    private nonisolated static func group(_ rows: [(String, Double, Double)]) -> [BreakdownItem] {
        var totals: [String: (Double, Double)] = [:]
        for (label, q, amt) in rows {
            let t = totals[label] ?? (0, 0)
            totals[label] = (t.0 + q, t.1 + amt)
        }
        return totals.map { BreakdownItem(label: $0.key, quantity: $0.value.0, netAmount: $0.value.1) }
            .filter { $0.quantity > 0 }
            .sorted { $0.quantity > $1.quantity }
    }

    private nonisolated static func daily(_ rows: [(String?, Double)]) -> [DailyPoint] {
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

    /// Re-check PRs and Actions now, e.g. after the watched repositories change in Settings.
    func refreshActivity() async {
        lastRepoFetch = .distantPast
        await refresh(notify: false, forceActivity: true)
    }

    private func loadActions(token: String) async throws -> ActionsStatus {
        _ = try await ensureRepos(token: token)
        let watched = Self.watchedRepos(from: repoCache, now: Date())
        let fetcher = actionsFetcher
        let failing = await withTaskGroup(of: [FailingWorkflow].self) { group in
            for repo in watched {
                // One repo failing to load (Actions disabled, no access) shouldn't hide the others.
                group.addTask { (try? await fetcher.failingWorkflows(repo: repo, token: token)) ?? [] }
            }
            var all: [FailingWorkflow] = []
            for await part in group { all += part }
            return all
        }
        return ActionsStatus(failing: failing.sorted { ($0.failedAt ?? .distantPast) > ($1.failedAt ?? .distantPast) },
                             watchedRepos: watched.map(\.fullName), checkedAt: Date())
    }

    /// "Recent": repos pushed in the last 30 days (most recent first, capped). "Selected": the user's picks.
    static func watchedRepos(from repos: [RepoSummary], now: Date) -> [RepoSummary] {
        let d = UserDefaults.standard
        let live = repos.filter { !$0.archived }
        if d.string(forKey: SettingsKey.actionsRepoMode) == "selected" {
            let picked = Set(d.stringArray(forKey: SettingsKey.actionsSelectedRepos) ?? [])
            return live.filter { picked.contains($0.fullName) }
        }
        let iso = ISO8601DateFormatter()
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        return Array(live.filter { ($0.pushedAt.flatMap(iso.date(from:)) ?? .distantPast) >= cutoff }.prefix(recentRepoLimit))
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
            .actions: UsageMetric(kind: .actions, used: 1860, limit: 3000, periodStart: start, resetAt: end, netAmount: 0,
                                  breakdown: [.init(label: "you/web-app", quantity: 820, netAmount: 0),
                                              .init(label: "you/cli-tool", quantity: 420, netAmount: 0)],
                                  daily: days,
                                  note: "Counted as Linux minutes: macOS runners use about 10×, Windows 2×. Public repos are free."),
            .copilot: UsageMetric(kind: .copilot, used: 7.12, limit: 10, periodStart: start, resetAt: end, netAmount: 0,
                                  breakdown: [.init(label: "Claude Sonnet", quantity: 5.04, netAmount: 0),
                                              .init(label: "GPT-5", quantity: 2.08, netAmount: 0)],
                                  isCurrency: true),
        ]
        issues = [:]
        login = "you"
        tokenSource = .ghCLI
        lastUpdated = now
        lastError = nil
        self.now = now
        func pr(_ n: Int, _ title: String, _ repo: String, _ author: String, _ hoursAgo: Double, _ decision: ReviewDecision? = nil, draft: Bool = false) -> PullRequestItem {
            PullRequestItem(number: n, title: title, url: URL(string: "https://github.com/\(repo)/pull/\(n)")!, repo: repo,
                            author: author, createdAt: now.addingTimeInterval(-hoursAgo * 3600), isDraft: draft, reviewDecision: decision)
        }
        pullRequests = PullRequestQueue(
            waitingOnYou: [pr(212, "Migrate settings storage to SwiftData", "acme/web-app", "sam", 24 * 9),
                           pr(48, "Fix flaky checkout test on Intel runners", "acme/cli-tool", "riley", 30),
                           pr(219, "Add dark mode to onboarding", "acme/web-app", "jordan", 3)],
            waitingOnYouTotal: 3,
            yours: [pr(205, "Cache API responses with ETags", "acme/web-app", "you", 24 * 4, .changesRequested),
                    pr(51, "Speed up cold start by 40%", "acme/cli-tool", "you", 26, .approved),
                    pr(220, "Experiment: radial gauges", "you/playground", "you", 2, draft: true)],
            yoursTotal: 3)
        func failure(_ repo: String, _ name: String, _ conclusion: String, _ hoursAgo: Double, run: Int) -> FailingWorkflow {
            FailingWorkflow(repo: repo, workflowID: run, workflowName: name, branch: "main", conclusion: conclusion,
                            runURL: URL(string: "https://github.com/\(repo)/actions/runs/\(run)")!, runNumber: run,
                            failedAt: now.addingTimeInterval(-hoursAgo * 3600))
        }
        actions = ActionsStatus(
            failing: [failure("acme/web-app", "Deploy preview", "failure", 0.6, run: 381),
                      failure("acme/cli-tool", "Nightly integration tests", "timed_out", 9, run: 117)],
            watchedRepos: ["acme/web-app", "acme/cli-tool", "acme/docs", "you/playground", "you/dotfiles", "you/blog"],
            checkedAt: now)
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
            },
            pullRequests: pullRequests.map { .init(waitingOnYou: $0.waitingOnYouTotal, yours: $0.yoursTotal) },
            actionsFailing: actions?.failing.count)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(file) else { return }
        let url = Self.cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
