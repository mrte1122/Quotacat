import AppKit
import ServiceManagement

@main
enum Entry {
    @MainActor
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered, so CLI modes print immediately even when piped
        SettingsKey.registerDefaults()
        let args = CommandLine.arguments

        if args.contains("--selftest") { exit(SelfTest.run()) }
        if args.contains("--once") { runOnce() }
        if args.contains("--sign-in") { runSignIn() }
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
            await store.refresh(notify: false, forceActivity: true)
            print(store.diagnosticsText())
            exit(store.lastError == nil ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// `--sign-in` runs the device flow in the terminal (same code path as the button).
    @MainActor
    private static func runSignIn() -> Never {
        _ = NSApplication.shared
        let signIn = GitHubSignIn()
        signIn.start()
        Task { @MainActor in
            var shown = false
            while true {
                switch signIn.state {
                case .waiting(let code, let url, _) where !shown:
                    print("Open \(url.absoluteString) and enter: \(code)")
                    shown = true
                case .failed(let message):
                    print("error:", message); exit(1)
                case .idle where signIn.isSignedIn:
                    if let token = Keychain.load(.signIn), let user = try? await GitHubClient(token: token).fetchUser() {
                        print("signed in as @\(user.login) | scopes: \(user.scopes?.sorted().joined(separator: ",") ?? "n/a") | plan: \(user.plan ?? "n/a")")
                    }
                    exit(0)
                default: break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
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
}
