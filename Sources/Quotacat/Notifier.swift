import Foundation
import UserNotifications

/// Threshold alerts at 75/90/95% plus a reset notice, deduplicated per metric per window
/// (Claude Usage tracks the same thing in its `sentNotifications` default).
@MainActor
final class Notifier {
    static let thresholds: [Double] = [0.75, 0.90, 0.95]
    /// The 60-second search window would be pure noise.
    static let watched: Set<MetricKind> = [.core, .graphql, .actions, .copilot]

    private var lastReset: [MetricKind: Date] = [:]
    private var lastFraction: [MetricKind: Double] = [:]

    /// UNUserNotificationCenter traps outside a real .app bundle (e.g. `swift run`).
    private var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private var enabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.notificationsEnabled) }

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(_ metrics: [UsageMetric]) {
        guard available, enabled else { return }
        var sent = Set(UserDefaults.standard.stringArray(forKey: SettingsKey.sentNotifications) ?? [])

        for m in metrics where Self.watched.contains(m.kind) && m.limit > 0 {
            let window = Int(m.resetAt.timeIntervalSince1970 / 60)
            if m.inBudgetStage, let b = m.budget {
                // Once, when the included minutes run out and the budget starts paying.
                let exhausted = "actions-\(window)-included-exhausted"
                if !sent.contains(exhausted) {
                    sent.insert(exhausted)
                    post(title: "Included Actions minutes used up",
                         body: String(format: "Now spending from your $%.2f budget.", b.amount)
                             + (b.stopsUsage ? " GitHub stops Actions when it runs out." : ""))
                }
                if let t = Self.thresholds.last(where: { b.fraction >= $0 }) {
                    let key = "actions-budget-\(window)-\(Int(t * 100))"
                    if !sent.contains(key) {
                        for lower in Self.thresholds where lower <= t { sent.insert("actions-budget-\(window)-\(Int(lower * 100))") }
                        let spent = String(format: "$%.2f of $%.2f spent.", b.spent, b.amount)
                        post(title: "Actions budget at \(Int((b.fraction * 100).rounded()))%",
                             body: spent + (b.stopsUsage ? " Actions stops at the limit." : ""))
                    }
                }
                lastReset[m.kind] = m.resetAt
                lastFraction[m.kind] = m.fraction
                continue
            }
            // Only the highest crossed threshold fires, so a jump from 10% to 96% sends one alert.
            if let t = Self.thresholds.last(where: { m.fraction >= $0 }) {
                let key = "\(m.kind.rawValue)-\(window)-\(Int(t * 100))"
                if !sent.contains(key) {
                    for lower in Self.thresholds where lower <= t {
                        sent.insert("\(m.kind.rawValue)-\(window)-\(Int(lower * 100))")
                    }
                    post(title: "\(m.displayTitle) at \(Int((m.fraction * 100).rounded()))%",
                         body: "\(m.amountText) used. Resets in \(UsageMath.countdown(to: m.resetAt, now: Date())).")
                }
            }
            if let prev = lastReset[m.kind], m.resetAt.timeIntervalSince(prev) > 60,
               (lastFraction[m.kind] ?? 0) >= Self.thresholds[0] {
                post(title: "\(m.displayTitle) reset", body: "Your \(m.displayTitle.lowercased()) allowance is available again.")
            }
            lastReset[m.kind] = m.resetAt
            lastFraction[m.kind] = m.fraction
        }
        UserDefaults.standard.set(Array(sent.sorted().suffix(300)), forKey: SettingsKey.sentNotifications)
    }

    /// nil until the first fetch, so PRs that were already waiting don't all notify at launch.
    private var knownReviewRequests: Set<String>?

    func evaluateReviewRequests(_ items: [PullRequestItem]) {
        let ids = Set(items.map(\.id))
        defer { knownReviewRequests = ids }
        guard let known = knownReviewRequests,
              UserDefaults.standard.bool(forKey: SettingsKey.notifyReviewRequests) else { return }
        for pr in items.filter({ !known.contains($0.id) }).prefix(3) {
            post(title: "Review requested: \(pr.repo) #\(pr.number)",
                 body: pr.author.map { "\(pr.title) (from @\($0))" } ?? pr.title)
        }
    }

    /// Failing workflows from the previous check; nil until the first check (seeded silently).
    private var knownFailing: [String: FailingWorkflow]?

    func evaluateActions(_ status: ActionsStatus) {
        let current = Dictionary(status.failing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        defer { knownFailing = current }
        guard let known = knownFailing,
              UserDefaults.standard.bool(forKey: SettingsKey.notifyActions) else { return }
        let watched = Set(status.watchedRepos)
        for f in status.failing where known[f.id] == nil {
            post(title: "CI failing: \(f.repo)", body: "\(f.workflowName) failed on \(f.branch).")
        }
        // Only call it a recovery if the repo is still watched (not just removed from the list).
        for (id, f) in known where current[id] == nil && watched.contains(f.repo) {
            post(title: "CI passing again: \(f.repo)", body: "\(f.workflowName) is green on \(f.branch).")
        }
    }

    func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
