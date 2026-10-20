import Foundation

enum StatusLevel { case safe, moderate, critical }

/// Six pace tiers, matching the thresholds in Claude Usage's embedded statusline script.
enum PaceTier: Int, CaseIterable {
    case comfortable, onTrack, warming, pressing, critical, runaway

    var title: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .onTrack: return "On track"
        case .warming: return "Warming up"
        case .pressing: return "Pressing"
        case .critical: return "Will hit limit"
        case .runaway: return "Runaway"
        }
    }
}

enum UsageMath {
    /// Pace is not meaningful until 3% of the window has elapsed (540s of 5h in the original).
    static let minElapsedForPace = 0.03

    static func fraction(used: Double, limit: Double) -> Double {
        guard limit > 0 else { return 0 }
        return max(0, used / limit)
    }

    static func elapsedFraction(start: Date, end: Date, now: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(start) / total))
    }

    /// Usage projected to the end of the window at the current rate, as a fraction of the limit.
    static func projectedFraction(used: Double, limit: Double, start: Date, end: Date, now: Date) -> Double? {
        let elapsed = elapsedFraction(start: start, end: end, now: now)
        guard elapsed >= minElapsedForPace, limit > 0 else { return nil }
        return fraction(used: used, limit: limit) / elapsed
    }

    static func paceTier(projected: Double) -> PaceTier {
        switch projected {
        case ..<0.50: return .comfortable
        case ..<0.75: return .onTrack
        case ..<0.90: return .warming
        case ..<1.00: return .pressing
        case ..<1.20: return .critical
        default: return .runaway
        }
    }

    /// Design choice: the original's cut-offs weren't recoverable without decompilation.
    static func statusLevel(fraction: Double) -> StatusLevel {
        switch fraction {
        case ..<0.60: return .safe
        case ..<0.85: return .moderate
        default: return .critical
        }
    }

    static func countdown(to date: Date, now: Date) -> String {
        let s = Int(max(0, date.timeIntervalSince(now)))
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    /// Compact countdown for the menu bar, e.g. "→2H", "→14M".
    static func compactCountdown(to date: Date, now: Date) -> String {
        let s = Int(max(0, date.timeIntervalSince(now)))
        if s >= 86_400 { return "→\(s / 86_400)D" }
        if s >= 3600 { return "→\(s / 3600)H" }
        return "→\(max(1, s / 60))M"
    }

    /// Compact age for list rows: "45m", "20h", "3d".
    static func age(since date: Date, now: Date) -> String {
        let s = Int(max(0, now.timeIntervalSince(date)))
        if s < 3600 { return "\(max(1, s / 60))m" }
        if s < 48 * 3600 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    static func monthBounds(containing date: Date) -> (start: Date, end: Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month], from: date)
        let start = cal.date(from: comps)!
        let end = cal.date(byAdding: .month, value: 1, to: start)!
        return (start, end)
    }

    static func formatQuantity(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.1fk", v / 1000) }
        if v >= 100 || v == v.rounded() { return String(Int(v.rounded())) }
        return String(format: "%.1f", v)
    }
}

/// `Quotacat --selftest` runs these checks without needing XCTest.
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ cond: Bool, _ name: String) {
            print(cond ? "PASS" : "FAIL", name)
            if !cond { failures += 1 }
        }
        let t0 = Date(timeIntervalSince1970: 0)
        let t1 = t0.addingTimeInterval(18_000) // 5h window like the original

        check(UsageMath.fraction(used: 50, limit: 200) == 0.25, "fraction")
        check(UsageMath.fraction(used: 5, limit: 0) == 0, "fraction with zero limit")
        check(UsageMath.elapsedFraction(start: t0, end: t1, now: t0.addingTimeInterval(9000)) == 0.5, "elapsed half")
        check(UsageMath.elapsedFraction(start: t0, end: t1, now: t1.addingTimeInterval(99)) == 1, "elapsed clamps")
        check(UsageMath.projectedFraction(used: 1, limit: 100, start: t0, end: t1, now: t0.addingTimeInterval(539)) == nil,
              "no pace before 540s / 3%")
        check(UsageMath.projectedFraction(used: 1, limit: 100, start: t0, end: t1, now: t0.addingTimeInterval(540)) != nil,
              "pace at 540s")
        // Matches the shell: projected_pct = utilization * 18000 / elapsed_secs
        let p = UsageMath.projectedFraction(used: 30, limit: 100, start: t0, end: t1, now: t0.addingTimeInterval(9000))!
        check(abs(p - 0.60) < 1e-9, "projection 30% at half = 60%")
        check(UsageMath.paceTier(projected: 0.49) == .comfortable, "tier <50")
        check(UsageMath.paceTier(projected: 0.50) == .onTrack, "tier 50")
        check(UsageMath.paceTier(projected: 0.89) == .warming, "tier <90")
        check(UsageMath.paceTier(projected: 0.99) == .pressing, "tier <100")
        check(UsageMath.paceTier(projected: 1.19) == .critical, "tier <120")
        check(UsageMath.paceTier(projected: 1.20) == .runaway, "tier 120")
        check(UsageMath.countdown(to: t0.addingTimeInterval(3 * 3600 + 120), now: t0) == "3h 2m", "countdown h/m")
        check(UsageMath.countdown(to: t0.addingTimeInterval(2 * 86_400 + 3600), now: t0) == "2d 1h", "countdown d/h")
        check(UsageMath.compactCountdown(to: t0.addingTimeInterval(7300), now: t0) == "→2H", "compact countdown")
        let mid = ISO8601DateFormatter().date(from: "2026-10-16T12:00:00Z")!
        let b = UsageMath.monthBounds(containing: mid)
        check(ISO8601DateFormatter().string(from: b.start) == "2026-10-01T00:00:00Z", "month start")
        check(ISO8601DateFormatter().string(from: b.end) == "2026-11-01T00:00:00Z", "month end")
        check(UsageMath.age(since: t0, now: t0.addingTimeInterval(30)) == "1m", "age floor 1m")
        check(UsageMath.age(since: t0, now: t0.addingTimeInterval(5 * 3600)) == "5h", "age hours")
        check(UsageMath.age(since: t0, now: t0.addingTimeInterval(47 * 3600)) == "47h", "age under 2 days")
        check(UsageMath.age(since: t0, now: t0.addingTimeInterval(3 * 86_400)) == "3d", "age days")
        let sample = #"{"data":{"waiting":{"issueCount":2,"nodes":[{"number":7,"title":"Fix it","url":"https://github.com/a/b/pull/7","createdAt":"2026-10-01T12:00:00Z","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","repository":{"nameWithOwner":"a/b"},"author":null},{}]},"yours":{"issueCount":0,"nodes":[]}}}"#
        if let q = try? GitHubClient.decodePullRequests(Data(sample.utf8)) {
            check(q.waitingOnYou.count == 1 && q.waitingOnYouTotal == 2 && q.waitingOnYou[0].author == nil,
                  "PR decode skips empty nodes, keeps ghost authors")
        } else {
            check(false, "PR decode")
        }
        // Latest completed run per workflow decides; older failures and in-progress runs don't count.
        func run(_ id: Int, _ wf: Int, _ status: String, _ conclusion: String?) -> WorkflowRun {
            WorkflowRun(id: id, name: "W\(wf)", workflowID: wf, headBranch: "main", status: status, conclusion: conclusion,
                        htmlURL: URL(string: "https://github.com/a/b/actions/runs/\(id)")!, runNumber: id, event: "push", updatedAt: nil)
        }
        let runs = [run(9, 1, "in_progress", nil), run(8, 1, "completed", "success"), run(7, 1, "completed", "failure"),
                    run(6, 2, "completed", "timed_out"), run(5, 3, "completed", "cancelled"), run(4, 2, "completed", "success")]
        let failing = ActionsStatus.failing(repo: "a/b", branch: "main", runs: runs)
        check(failing.map(\.workflowID) == [2], "Actions: only workflows whose latest completed run failed")
        check(Updater.isVersion("1.1.0", newerThan: "1.0.0"), "version minor bump")
        check(Updater.isVersion("1.10.0", newerThan: "1.9.0"), "version numeric not lexical")
        check(Updater.isVersion("2.0", newerThan: "1.9.9"), "version different lengths")
        check(!Updater.isVersion("1.0.0", newerThan: "1.0.0"), "version equal")
        check(!Updater.isVersion("1.0.0", newerThan: "1.0.1"), "version older")
        print(failures == 0 ? "All self-tests passed" : "\(failures) self-test(s) failed")
        return failures == 0 ? 0 : 1
    }
}
