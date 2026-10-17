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
            // Only the highest crossed threshold fires, so a jump from 10% to 96% sends one alert.
            if let t = Self.thresholds.last(where: { m.fraction >= $0 }) {
                let key = "\(m.kind.rawValue)-\(window)-\(Int(t * 100))"
                if !sent.contains(key) {
                    for lower in Self.thresholds where lower <= t {
                        sent.insert("\(m.kind.rawValue)-\(window)-\(Int(lower * 100))")
                    }
                    post(title: "\(m.kind.title) at \(Int((m.fraction * 100).rounded()))%",
                         body: "\(UsageMath.formatQuantity(m.used)) of \(UsageMath.formatQuantity(m.limit)) \(m.kind.unit) used. Resets in \(UsageMath.countdown(to: m.resetAt, now: Date())).")
                }
            }
            if let prev = lastReset[m.kind], m.resetAt.timeIntervalSince(prev) > 60,
               (lastFraction[m.kind] ?? 0) >= Self.thresholds[0] {
                post(title: "\(m.kind.title) reset", body: "Your \(m.kind.title.lowercased()) allowance is available again.")
            }
            lastReset[m.kind] = m.resetAt
            lastFraction[m.kind] = m.fraction
        }
        UserDefaults.standard.set(Array(sent.sorted().suffix(300)), forKey: SettingsKey.sentNotifications)
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
