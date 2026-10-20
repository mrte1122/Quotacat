import AppKit
import ServiceManagement

@main
enum Entry {
    @MainActor
    static func main() {
        SettingsKey.registerDefaults()
        let args = CommandLine.arguments

        if args.contains("--selftest") { exit(SelfTest.run()) }
        if args.contains("--once") { runOnce() }
        if args.contains("--check-update") || args.contains("--update") {
            runUpdate(install: args.contains("--update"))
        }
        if let i = args.firstIndex(of: "--launch-at-login"), i + 1 < args.count {
            let service = SMAppService.mainApp
            do {
                if args[i + 1] == "on" { try service.register() } else { try service.unregister() }
            } catch {
                print("error:", error.localizedDescription)
            }
            print("launch at login:", service.status == .enabled ? "enabled" : "status \(service.status.rawValue)")
            exit(service.status == .enabled ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { Snapshot.run(outDir: args[i + 1]) }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar only, like LSUIElement
        app.run()
    }

    /// Fetch once and print a summary (never the token); handy for checking credentials and scopes.
    @MainActor
    private static func runOnce() -> Never {
        let store = UsageStore()
        Task { @MainActor in
            await store.refresh(notify: false, forcePullRequests: true)
            print("login:", store.login ?? "-", "| credential:", store.tokenSource?.rawValue ?? "none",
                  "| scopes:", store.scopes?.sorted().joined(separator: ",") ?? "n/a")
            if let e = store.lastError { print("error:", e) }
            for k in MetricKind.allCases {
                if let m = store.metrics[k] {
                    let pace = UsageMath.projectedFraction(used: m.used, limit: m.limit, start: m.periodStart,
                                                           end: m.resetAt, now: Date())
                        .map { "\(UsageMath.paceTier(projected: $0).title) (\(Int($0 * 100))%)" } ?? "n/a"
                    let usage = "\(UsageMath.formatQuantity(m.used)) / \(UsageMath.formatQuantity(m.limit))"
                    print(pad(k.title, 26) + pad(usage, 14) + pad("\(Int((m.fraction * 100).rounded()))%", 6)
                          + pad("resets in \(UsageMath.countdown(to: m.resetAt, now: Date()))", 20) + "pace: \(pace)")
                } else if let issue = store.issues[k] {
                    print(pad(k.title, 26) + "unavailable: \(issue)")
                }
            }
            if let q = store.pullRequests {
                print("pull requests waiting on you: \(q.waitingOnYouTotal) | yours open: \(q.yoursTotal)")
                for pr in q.waitingOnYou.prefix(5) + q.yours.prefix(5) {
                    print("  \(pr.repo) #\(pr.number)  \(UsageMath.age(since: pr.createdAt, now: Date()))  \(pr.reviewDecision?.rawValue ?? (pr.isDraft ? "DRAFT" : "-"))")
                }
            } else if let e = store.pullRequestIssue {
                print("pull requests: unavailable: \(e)")
            }
            print("cache:", UsageStore.cacheURL.path)
            exit(store.lastError == nil ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// `--check-update` reports the latest release; `--update` also installs it (no relaunch).
    @MainActor
    private static func runUpdate(install: Bool) -> Never {
        _ = NSApplication.shared
        let updater = Updater()
        Task { @MainActor in
            print("installed:", Updater.currentVersion, "at", Bundle.main.bundleURL.path)
            print("install location:", Updater.installLocationProblem ?? "ok, updates can install here")
            await updater.check(userInitiated: true)
            switch updater.state {
            case .available(let release):
                print("available:", release.version)
                if install {
                    await updater.install(release, relaunch: false)
                    if case .failed(let message) = updater.state { print("error:", message); exit(1) }
                    let plist = NSDictionary(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist"))
                    print("installed now:", plist?["CFBundleShortVersionString"] as? String ?? "?")
                }
                exit(0)
            case .upToDate:
                print("up to date")
                exit(0)
            case .failed(let message):
                print("error:", message)
                exit(1)
            default:
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s + " " : s.padding(toLength: n, withPad: " ", startingAt: 0)
    }
}
