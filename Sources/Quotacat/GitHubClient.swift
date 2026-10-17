import Foundation

enum GitHubError: LocalizedError {
    case unauthorized
    case needsUserScope
    case notAvailable(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "GitHub rejected the token (401). Sign in again with `gh auth login` or update the token."
        case .needsUserScope: return "Needs the `user` token scope. Run: gh auth refresh -h github.com -s user"
        case .notAvailable(let m): return m
        case .http(let code, let m): return "GitHub returned \(code): \(m)"
        }
    }
}

struct RateResource: Decodable {
    let limit: Double
    let used: Double
    let remaining: Double
    let reset: TimeInterval
}

struct BillingItem: Decodable {
    let date: String?
    let product: String?
    let sku: String?
    let quantity: Double?
    let unitType: String?
    let netAmount: Double?
    let repositoryName: String?
}

struct PremiumItem: Decodable {
    let model: String?
    let sku: String?
    let grossQuantity: Double?
    let netAmount: Double?
}

struct GitHubClient {
    let token: String
    var base = URL(string: "https://api.github.com")!

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> (Data, HTTPURLResponse) {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Quotacat/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GitHubError.http(-1, "No HTTP response") }
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 401: throw GitHubError.unauthorized
        default:
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["message"] ?? ""
            throw GitHubError.http(http.statusCode, msg)
        }
    }

    /// Returns the login and the classic-token scopes (nil for fine-grained tokens, which send no header).
    func fetchUser() async throws -> (login: String, scopes: Set<String>?) {
        let (data, http) = try await get("user")
        struct U: Decodable { let login: String }
        let login = try JSONDecoder().decode(U.self, from: data).login
        let scopes = (http.value(forHTTPHeaderField: "X-OAuth-Scopes")).map {
            Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        return (login, scopes)
    }

    /// `/rate_limit` itself does not count against the rate limit.
    func fetchRateLimits() async throws -> [String: RateResource] {
        struct R: Decodable { let resources: [String: RateResource] }
        let (data, _) = try await get("rate_limit")
        return try JSONDecoder().decode(R.self, from: data).resources
    }

    func fetchBillingUsage(user: String, year: Int, month: Int) async throws -> [BillingItem] {
        struct R: Decodable { let usageItems: [BillingItem]? }
        let data = try await billingGet("users/\(user)/settings/billing/usage", year: year, month: month)
        return try JSONDecoder().decode(R.self, from: data).usageItems ?? []
    }

    func fetchPremiumRequests(user: String, year: Int, month: Int) async throws -> [PremiumItem] {
        struct R: Decodable { let usageItems: [PremiumItem]? }
        let data = try await billingGet("users/\(user)/settings/billing/premium_request/usage", year: year, month: month)
        return try JSONDecoder().decode(R.self, from: data).usageItems ?? []
    }

    private func billingGet(_ path: String, year: Int, month: Int) async throws -> Data {
        do {
            return try await get(path, query: [.init(name: "year", value: String(year)),
                                              .init(name: "month", value: String(month))])
                .0
        } catch GitHubError.http(let code, _) where code == 404 || code == 403 {
            // GitHub answers 404 when the token lacks `user` or the account isn't on enhanced billing.
            throw GitHubError.notAvailable("Billing data unavailable (\(code)). The token needs the `user` scope, and the account must be on GitHub's enhanced billing platform.")
        }
    }
}
