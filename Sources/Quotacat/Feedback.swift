import AppKit
import Foundation

enum SystemInfo {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// e.g. "macOS 26.1"
    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
                                  : "macOS \(v.majorVersion).\(v.minorVersion)"
    }

    static var chip: String {
        #if arch(arm64)
        return "Apple silicon"
        #else
        // An Intel build running under Rosetta still reports the real hardware.
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
        return rosetta ? "Apple silicon (Rosetta)" : "Intel"
        #endif
    }
}

/// "Report a Bug…", "Suggest a Feature…" and "Copy Diagnostics".
@MainActor
enum Feedback {
    static let ideasURL = URL(string: "https://github.com/mrte1122/Quotacat/discussions/new?category=ideas")!

    /// GitHub's bug-report form with version, macOS, sign-in method and diagnostics filled in.
    /// Nothing is sent until the user reviews it and clicks Submit on GitHub.
    static func bugReportURL(store: UsageStore) -> URL {
        let signIn: String
        switch store.tokenSource {
        case .signIn: signIn = "Sign in with GitHub"
        case .ghCLI: signIn = "GitHub CLI (gh)"
        case .keychain: signIn = "Personal access token"
        case nil: signIn = "Not signed in"
        }
        var comps = URLComponents(string: "https://github.com/mrte1122/Quotacat/issues/new")!
        comps.queryItems = [
            .init(name: "template", value: "bug_report.yml"),
            .init(name: "quotacat-version", value: SystemInfo.appVersion),
            .init(name: "macos-version", value: "\(SystemInfo.macOS), \(SystemInfo.chip)"),
            .init(name: "sign-in", value: signIn),
            .init(name: "once-output", value: store.diagnosticsText()),
        ]
        return comps.url!
    }

    static func reportBug(store: UsageStore) {
        NSWorkspace.shared.open(bugReportURL(store: store))
    }

    static func suggestFeature() {
        NSWorkspace.shared.open(ideasURL)
    }

    static func copyDiagnostics(store: UsageStore) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.diagnosticsText(), forType: .string)
    }
}

extension UsageStore {
    /// A plain-text summary of what Quotacat sees, for bug reports. Never includes a token.
    /// Also what `--once` prints.
    func diagnosticsText(now: Date = Date()) -> String {
        func pad(_ s: String, _ n: Int) -> String {
            s.count >= n ? s + " " : s.padding(toLength: n, withPad: " ", startingAt: 0)
        }
        var out: [String] = []
        out.append("Quotacat \(SystemInfo.appVersion) | \(SystemInfo.macOS) | \(SystemInfo.chip)")
        if let problem = Updater.installLocationProblem { out.append("install location: \(problem)") }
        if Updater.isTranslocated {
            out.append("moved copy in Applications: \(Updater.movedCopyURL?.path ?? "none yet")")
        } else if Updater.installMode == .replaceContents {
            out.append("install location: updates replace the app's contents (folder isn't writable by this account)")
        }
        out.append("login: \(login ?? "-") | credential: \(tokenSource?.rawValue ?? "none") | "
                   + "scopes: \(scopes?.sorted().joined(separator: ",") ?? "n/a") | plan: \(plan ?? "n/a")")
        if let u = lastUpdated { out.append("updated: \(u.formatted(date: .abbreviated, time: .standard))") }
        if needsSignIn { out.append("state: not signed in") }
        if let e = lastError { out.append("error: \(e)") }
        for k in MetricKind.allCases {
            if let m = metrics[k] {
                let pace = UsageMath.projectedFraction(used: m.used, limit: m.limit, start: m.periodStart,
                                                       end: m.resetAt, now: now)
                    .map { "\(UsageMath.paceTier(projected: $0).title) (\(Int($0 * 100))%)" } ?? "n/a"
                let usage = m.amountText + (m.netAmount.map { $0 > 0 ? String(format: " ($%.2f billed)", $0) : "" } ?? "")
                out.append(pad(m.displayTitle, 26) + pad(usage, 30) + pad("\(Int((m.fraction * 100).rounded()))%", 6)
                           + pad("resets in \(UsageMath.countdown(to: m.resetAt, now: now))", 20) + "pace: \(pace)")
            } else if let issue = issues[k] {
                out.append(pad(k.title, 26) + "unavailable: \(issue)")
            }
        }
        if let b = metrics[.actions]?.budget {
            let runway = b.runway.map { "\(Int($0.minutes)) \($0.runner)" }.joined(separator: " / ")
            out.append(String(format: "actions budget: $%.2f of $%.2f%@ | runway: %@ min | projected: %@%@",
                              b.spent, b.amount, b.stopsUsage ? " (stops Actions)" : "", runway,
                              b.projectedSpend.map { String(format: "$%.2f", $0) } ?? "n/a",
                              b.runsOutAt.map { " | runs out ~\($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
        }
        if let q = pullRequests {
            out.append("pull requests waiting on you: \(q.waitingOnYouTotal) | yours open: \(q.yoursTotal)")
            for pr in q.waitingOnYou.prefix(5) + q.yours.prefix(5) {
                out.append("  \(pr.repo) #\(pr.number)  \(UsageMath.age(since: pr.createdAt, now: now))  "
                           + (pr.reviewDecision?.rawValue ?? (pr.isDraft ? "DRAFT" : "-")))
            }
        } else if let e = pullRequestIssue {
            out.append("pull requests: unavailable: \(e)")
        }
        if let a = actions {
            out.append("actions: watching \(a.watchedRepos.count) repos, \(a.failing.count) failing")
            for f in a.failing { out.append("  \(f.repo)  \(f.workflowName)  \(f.conclusion)") }
        } else if let e = actionsIssue {
            out.append("actions: unavailable: \(e)")
        }
        out.append("cache: \(Self.cacheURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
        return out.joined(separator: "\n")
    }
}
