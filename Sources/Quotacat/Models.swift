import Foundation

enum MetricKind: String, CaseIterable, Identifiable, Codable {
    case core, graphql, search, actions, copilot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .core: return "REST API"
        case .graphql: return "GraphQL API"
        case .search: return "Search API"
        case .actions: return "Actions Minutes"
        case .copilot: return "Copilot Premium Requests"
        }
    }

    /// Prefix shown in the menu bar when labels are on (mirrors Claude Usage's `S:` / `W:`).
    var shortLabel: String {
        switch self {
        case .core: return "R"
        case .graphql: return "G"
        case .search: return "S"
        case .actions: return "A"
        case .copilot: return "C"
        }
    }

    var symbol: String {
        switch self {
        case .core: return "arrow.left.arrow.right"
        case .graphql: return "point.3.connected.trianglepath.dotted"
        case .search: return "magnifyingglass"
        case .actions: return "gearshape.2"
        case .copilot: return "sparkles"
        }
    }

    var unit: String {
        switch self {
        case .core, .search: return "requests"
        case .graphql: return "points"
        case .actions: return "min"
        case .copilot: return "requests"
        }
    }

    /// Monthly billing metrics vs. short rate-limit windows.
    var isBilling: Bool { self == .actions || self == .copilot }

    static let rateLimits: [MetricKind] = [.core, .graphql, .search]
    static let billing: [MetricKind] = [.actions, .copilot]
}

struct BreakdownItem: Identifiable, Hashable {
    var id: String { label }
    let label: String
    let quantity: Double
    let netAmount: Double
}

struct DailyPoint: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let quantity: Double
}

struct UsageMetric: Identifiable {
    let kind: MetricKind
    var id: MetricKind { kind }
    let used: Double
    let limit: Double
    let periodStart: Date
    let resetAt: Date
    var netAmount: Double? = nil
    var breakdown: [BreakdownItem] = []
    var daily: [DailyPoint] = []

    var fraction: Double { UsageMath.fraction(used: used, limit: limit) }
}

/// Snapshot written to disk on each refresh for shell prompts / statuslines.
struct UsageCacheFile: Codable {
    struct Entry: Codable {
        let kind: String
        let used: Double
        let limit: Double
        let percent: Int
        let resetAt: Date
    }
    let login: String?
    let updatedAt: Date
    let metrics: [Entry]
    /// Open PR counts, when the pull request feature is on.
    struct PullRequestCounts: Codable { let waitingOnYou: Int; let yours: Int }
    var pullRequests: PullRequestCounts? = nil
}
