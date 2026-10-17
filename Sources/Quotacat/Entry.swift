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
            await store.refresh(notify: false)
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
            print("cache:", UsageStore.cacheURL.path)
            exit(store.lastError == nil ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s + " " : s.padding(toLength: n, withPad: " ", startingAt: 0)
    }
}
