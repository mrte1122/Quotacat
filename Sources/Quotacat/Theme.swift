import AppKit
import SwiftUI

enum Theme {
    static func status(_ level: StatusLevel) -> NSColor {
        switch level {
        case .safe: return .systemGreen
        case .moderate: return .systemOrange
        case .critical: return .systemRed
        }
    }

    /// Six-tier ramp, green → purple, like the original's pace marker.
    static func pace(_ tier: PaceTier) -> NSColor {
        switch tier {
        case .comfortable: return .systemGreen
        case .onTrack: return .systemTeal
        case .warming: return .systemYellow
        case .pressing: return .systemOrange
        case .critical: return .systemRed
        case .runaway: return .systemPurple
        }
    }

    /// Bar color: pace-aware when enabled and enough of the window has elapsed, else usage level.
    static func barColor(for m: UsageMetric, now: Date, paceAware: Bool) -> NSColor {
        // Past the included allowance, color by the budget: projected spend vs. the budget amount.
        if m.inBudgetStage, let b = m.budget {
            if paceAware, let p = b.projectedSpend, b.amount > 0 { return pace(UsageMath.paceTier(projected: p / b.amount)) }
            return status(UsageMath.statusLevel(fraction: b.fraction))
        }
        if paceAware, let p = UsageMath.projectedFraction(used: m.used, limit: m.limit,
                                                         start: m.periodStart, end: m.resetAt, now: now) {
            return pace(UsageMath.paceTier(projected: p))
        }
        return status(UsageMath.statusLevel(fraction: m.fraction))
    }
}

extension Color {
    init(ns: NSColor) { self.init(nsColor: ns) }
}
