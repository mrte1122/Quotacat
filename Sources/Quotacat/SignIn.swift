import AppKit
import Foundation

/// "Sign in with GitHub" using the OAuth device flow: GitHub shows a page where you enter a short
/// code, and the app polls until you approve. No client secret is involved (the Client ID is
/// public), and the resulting token is stored in the Keychain.
@MainActor
final class GitHubSignIn: ObservableObject {
    enum State: Equatable {
        case idle
        case requesting
        case waiting(code: String, url: URL, expires: Date)
        case failed(String)
    }

    static let clientID = "Ov23liLGpWaXO0bDBU3S"
    /// repo: private repos' PRs and Actions runs. user: billing usage and plan. read:org: org repos.
    static let scopes = "repo user read:org"

    @Published private(set) var state: State = .idle
    @Published private(set) var isSignedIn = Keychain.load(.signIn) != nil
    var onSignedIn: (() -> Void)?
    private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch state {
        case .requesting, .waiting: return true
        default: return false
        }
    }

    func start() {
        task?.cancel()
        state = .requesting
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    /// Forgets the token on this Mac. GitHub keeps the authorization until it's revoked at
    /// github.com/settings/applications (revoking needs the client secret, which the app never has).
    func signOut() {
        cancel()
        Keychain.delete(.signIn)
        isSignedIn = false
    }

    func copyCodeAndOpenGitHub() {
        guard case .waiting(let code, let url, _) = state else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        NSWorkspace.shared.open(url)
    }

    private func run() async {
        do {
            let device = try await Self.post("https://github.com/login/device/code",
                                             ["client_id": Self.clientID, "scope": Self.scopes])
            guard let deviceCode = device["device_code"] as? String,
                  let userCode = device["user_code"] as? String,
                  let uri = (device["verification_uri"] as? String).flatMap(URL.init(string:)) else {
                throw SignInError(message: (device["error_description"] as? String) ?? "GitHub didn't return a sign-in code.")
            }
            let expires = Date().addingTimeInterval(TimeInterval((device["expires_in"] as? Int) ?? 900))
            var interval = UInt64(max(5, (device["interval"] as? Int) ?? 5))
            state = .waiting(code: userCode, url: uri, expires: expires)

            while Date() < expires {
                try await Task.sleep(nanoseconds: interval * 1_000_000_000)
                let r = try await Self.post("https://github.com/login/oauth/access_token", [
                    "client_id": Self.clientID, "device_code": deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ])
                if ProcessInfo.processInfo.environment["QUOTACAT_DEBUG"] != nil {
                    print("poll:", r["error"] as? String ?? (r["access_token"] != nil ? "token received" : "\(r.keys.sorted())"))
                }
                if let token = r["access_token"] as? String {
                    Keychain.save(token, .signIn)
                    isSignedIn = true
                    state = .idle
                    onSignedIn?()
                    return
                }
                switch r["error"] as? String {
                case "authorization_pending":
                    continue
                case "slow_down":
                    interval = UInt64((r["interval"] as? Int) ?? Int(interval) + 5)
                case "access_denied":
                    state = .failed("Sign-in was cancelled on GitHub.")
                    return
                case "expired_token":
                    break
                default:
                    throw SignInError(message: (r["error_description"] as? String) ?? "GitHub sign-in failed.")
                }
            }
            state = .failed("The code expired before it was approved. Try again.")
        } catch is CancellationError {
            // cancelled by the user; state already reset
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    struct SignInError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func post(_ url: String, _ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("Quotacat", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+:/ ")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SignInError(message: "Unexpected response from GitHub.")
        }
        return json
    }
}
