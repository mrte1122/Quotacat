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
        case .copilot: return "Copilot AI Credits"
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

/// Spending allowed after the plan's included Actions minutes run out.
struct ActionsBudget: Hashable {
    let amount: Double
    let spent: Double
    /// GitHub blocks Actions once the budget is reached.
    let stopsUsage: Bool
    /// End-of-period spend at the recent (7-day) daily rate; nil without recent overage.
    let projectedSpend: Double?
    /// When the budget runs out at that rate, if before the reset.
    let runsOutAt: Date?
    /// Minutes the remaining budget buys on each runner type used this period, e.g. ("macOS", 270).
    let runway: [Runway]

    struct Runway: Hashable { let runner: String; let minutes: Double }

    var remaining: Double { max(0, amount - spent) }
    var fraction: Double { UsageMath.fraction(used: spent, limit: amount) }
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
    /// Overrides `kind.title`, e.g. "Copilot Premium Requests" for annual plans still on requests.
    var title: String? = nil
    /// Amounts are dollars (Copilot AI Credits) rather than counts.
    var isCurrency = false
    /// One-line explanation under the card, e.g. how Actions minutes are weighted.
    var note: String? = nil
    /// Actions only: the overage budget, when one is configured.
    var budget: ActionsBudget? = nil

    var fraction: Double { UsageMath.fraction(used: used, limit: limit) }

    /// Included allowance used up and now spending from the budget.
    var inBudgetStage: Bool { budget != nil && limit > 0 && used >= limit * 0.999 }

    /// What the headline percentage, menu bar and alerts track: the budget once it's in play.
    var displayFraction: Double { inBudgetStage ? budget!.fraction : fraction }
    var displayTitle: String { title ?? kind.title }

    func format(_ value: Double) -> String {
        isCurrency ? String(format: "$%.2f", value) : UsageMath.formatQuantity(value)
    }

    /// "330 / 3000 min" or "$4.20 / $10.00".
    var amountText: String {
        isCurrency ? "\(format(used)) / \(format(limit))" : "\(format(used)) / \(format(limit)) \(kind.unit)"
    }
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
    /// Workflows currently failing on watched repos' default branches.
    var actionsFailing: Int? = nil
    /// Actions overage budget, when configured.
    struct Budget: Codable { let amount: Double; let spent: Double; let stopsUsage: Bool }
    var actionsBudget: Budget? = nil
}
