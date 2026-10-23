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

extension Theme {
    /// Accent colors as text: the bright system colors are hard to read on a light background,
    /// so in light appearances they're darkened; dark appearances keep them as-is.
    static func readable(_ color: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? color
                : (color.blended(withFraction: 0.32, of: .black) ?? color)
        }
    }
}

/// Card surface: white with a hairline border in light mode (the translucent grey of dark mode
/// looked muddy on the light popover), the existing translucent fill in dark mode.
struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return content
            .background(shape.fill(scheme == .dark ? AnyShapeStyle(.quaternary.opacity(0.5))
                                                   : AnyShapeStyle(Color.white.opacity(0.9))))
            .overlay(shape.strokeBorder(Color.black.opacity(scheme == .dark ? 0 : 0.07), lineWidth: 1))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}
