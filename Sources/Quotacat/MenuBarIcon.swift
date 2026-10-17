import AppKit

/// Draws the status-item image. Mirrors Claude Usage's `MenuBarIconRenderer` styles:
/// progress bar, battery, percentage, text only; monochrome renders as a template image.
@MainActor
enum MenuBarIconRenderer {
    struct Segment {
        let label: String
        let fraction: Double      // value to display (used, or remaining)
        let elapsed: Double?      // time marker position
        let color: NSColor
        let countdown: String?
    }

    static let height: CGFloat = 18
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let labelFont = NSFont.systemFont(ofSize: 9, weight: .semibold)

    static func render(store: UsageStore) -> NSImage {
        let d = UserDefaults.standard
        let style = IconStyle(rawValue: d.string(forKey: SettingsKey.iconStyle) ?? "") ?? .progressBar
        let mono = d.bool(forKey: SettingsKey.monochrome)
        let remaining = d.bool(forKey: SettingsKey.showRemaining)
        let labels = d.bool(forKey: SettingsKey.showLabels)
        let countdown = d.bool(forKey: SettingsKey.showCountdown)
        let pace = d.bool(forKey: SettingsKey.paceColoring)
        let marker = d.bool(forKey: SettingsKey.showTimeMarker)
        let now = store.now

        let segments: [Segment] = MetricKind.allCases.compactMap { kind in
            guard d.bool(forKey: SettingsKey.menuBar(kind)), let m = store.metrics[kind] else { return nil }
            let used = min(1, m.fraction)
            return Segment(
                label: labels ? kind.shortLabel : "",
                fraction: remaining ? 1 - used : used,
                elapsed: marker ? UsageMath.elapsedFraction(start: m.periodStart, end: m.resetAt, now: now) : nil,
                color: mono ? .black : Theme.barColor(for: m, now: now, paceAware: pace),
                countdown: countdown ? UsageMath.compactCountdown(to: m.resetAt, now: now) : nil)
        }

        // "App logo mode" when nothing is selected or nothing has loaded yet.
        guard !segments.isEmpty else {
            let name = store.lastError != nil && !store.hasData ? "exclamationmark.triangle" : "chart.bar.xaxis"
            let img = NSImage(systemSymbolName: name, accessibilityDescription: "Quotacat")!
            img.isTemplate = true
            return img
        }

        let widths = segments.map { width(of: $0, style: style) }
        let gap: CGFloat = 8
        let total = widths.reduce(0, +) + gap * CGFloat(segments.count - 1)
        let image = NSImage(size: NSSize(width: ceil(total), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (seg, w) in zip(segments, widths) {
                draw(seg, style: style, mono: mono, at: x)
                x += w + gap
            }
            return true
        }
        image.isTemplate = mono
        return image
    }

    private static func textSize(_ s: String, _ f: NSFont) -> CGSize {
        (s as NSString).size(withAttributes: [.font: f])
    }

    private static func pct(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }

    private static func width(of s: Segment, style: IconStyle) -> CGFloat {
        var w: CGFloat = 0
        if !s.label.isEmpty { w += textSize(s.label, labelFont).width + 3 }
        switch style {
        case .progressBar: w += 30
        case .battery: w += 25
        case .percentage, .textOnly: w += textSize(pct(s.fraction), font).width
        }
        if let c = s.countdown { w += 3 + textSize(c, labelFont).width }
        return ceil(w)
    }

    private static func draw(_ s: Segment, style: IconStyle, mono: Bool, at x0: CGFloat) {
        var x = x0
        let text: NSColor = mono ? .black : .labelColor
        let mid = height / 2

        func drawText(_ str: String, _ f: NSFont, _ color: NSColor) {
            let size = textSize(str, f)
            (str as NSString).draw(at: NSPoint(x: x, y: mid - size.height / 2),
                                   withAttributes: [.font: f, .foregroundColor: color])
            x += size.width
        }

        if !s.label.isEmpty { drawText(s.label, labelFont, text); x += 3 }

        switch style {
        case .progressBar:
            let track = NSRect(x: x, y: mid - 3.5, width: 30, height: 7)
            text.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: track, xRadius: 3.5, yRadius: 3.5).fill()
            var fill = track
            fill.size.width = max(s.fraction > 0 ? 3 : 0, track.width * s.fraction)
            s.color.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 3.5, yRadius: 3.5).fill()
            if let e = s.elapsed {
                text.setFill()
                NSRect(x: track.minX + track.width * e - 0.75, y: track.minY - 2, width: 1.5, height: track.height + 4).fill()
            }
            x += 30
        case .battery:
            let body = NSRect(x: x + 0.5, y: mid - 5, width: 21, height: 10)
            text.withAlphaComponent(0.6).setStroke()
            let outline = NSBezierPath(roundedRect: body, xRadius: 2.5, yRadius: 2.5)
            outline.lineWidth = 1
            outline.stroke()
            text.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: NSRect(x: body.maxX + 1, y: mid - 2, width: 2, height: 4), xRadius: 1, yRadius: 1).fill()
            s.color.setFill()
            let inner = body.insetBy(dx: 2, dy: 2)
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: inner.width * s.fraction, height: inner.height),
                         xRadius: 1, yRadius: 1).fill()
            x += 25
        case .percentage:
            drawText(pct(s.fraction), font, s.color)
        case .textOnly:
            drawText(pct(s.fraction), font, text)
        }

        if let c = s.countdown { x += 3; drawText(c, labelFont, text.withAlphaComponent(0.8)) }
    }
}
