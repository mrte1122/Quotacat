import AppKit

/// Draws the status-item image. Mirrors Claude Usage's `MenuBarIconRenderer` styles:
/// progress bar, battery, percentage, text only, plus a radial ring gauge; monochrome renders
/// as a template image.
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

    // Radial style: ring centerline radius and stroke width. The ring plus its time-marker tick
    // (ringRadius + ringWidth / 2 + tickOverhang = 8.75pt) fits inside the 18pt image height.
    private static let ringRadius: CGFloat = 6
    private static let ringWidth: CGFloat = 2.5
    private static let ringSlot: CGFloat = 15

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
            let used = min(1, m.displayFraction)
            return Segment(
                label: labels ? kind.shortLabel : "",
                fraction: remaining ? 1 - used : used,
                elapsed: marker ? UsageMath.elapsedFraction(start: m.periodStart, end: m.resetAt, now: now) : nil,
                color: mono ? .black : Theme.barColor(for: m, now: now, paceAware: pace),
                countdown: countdown ? UsageMath.compactCountdown(to: m.resetAt, now: now) : nil)
        }

        // Activity badges after the meters: reviews waiting on you, then failing workflows.
        struct Badge { let symbol: String; let palette: [NSColor]; let text: String; let color: NSColor; let width: CGFloat }
        let badgeSymbolWidth: CGFloat = 13
        var badges: [Badge] = []
        /// `palette` colors multi-layer symbols (e.g. a white ✕ on a red circle); defaults to the text color.
        func addBadge(_ symbol: String, _ count: Int, _ color: NSColor, palette: [NSColor]? = nil) {
            let text = "\(count)"
            let tint = mono ? NSColor.black : color
            badges.append(Badge(symbol: symbol, palette: mono ? [tint] : (palette ?? [tint]), text: text, color: tint,
                                width: ceil(badgeSymbolWidth + 2 + textSize(text, font).width)))
        }
        if d.bool(forKey: SettingsKey.pullRequestsEnabled), d.bool(forKey: SettingsKey.menuBarPullRequests),
           let q = store.pullRequests, q.waitingOnYouTotal > 0 {
            let stale = q.waitingOnYou.contains { now.timeIntervalSince($0.createdAt) >= 3 * 86_400 }
            addBadge("arrow.triangle.pull", q.waitingOnYouTotal, stale ? .systemOrange : .labelColor)
        }
        if d.bool(forKey: SettingsKey.actionsEnabled), d.bool(forKey: SettingsKey.menuBarActions),
           let a = store.actions, !a.failing.isEmpty {
            if mono {
                addBadge("xmark.circle", a.failing.count, .systemRed)
            } else {
                addBadge("xmark.circle.fill", a.failing.count, .systemRed, palette: [.white, .systemRed])
            }
        }

        // "App logo mode" when nothing is selected or nothing has loaded yet.
        guard !segments.isEmpty || !badges.isEmpty else {
            let name = store.lastError != nil && !store.hasData ? "exclamationmark.triangle" : "chart.bar.xaxis"
            let img = NSImage(systemSymbolName: name, accessibilityDescription: "Quotacat")!
            img.isTemplate = true
            return img
        }

        let widths = segments.map { width(of: $0, style: style) }
        let gap: CGFloat = 8
        let items = widths + badges.map(\.width)
        let total = items.reduce(0, +) + gap * CGFloat(max(0, items.count - 1))
        let image = NSImage(size: NSSize(width: ceil(total), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (seg, w) in zip(segments, widths) {
                draw(seg, style: style, mono: mono, at: x)
                x += w + gap
            }
            for badge in badges {
                let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                    .applying(.init(paletteColors: badge.palette))
                if let symbol = NSImage(systemSymbolName: badge.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config) {
                    let s = symbol.size
                    symbol.draw(in: NSRect(x: x + (badgeSymbolWidth - s.width) / 2, y: (height - s.height) / 2,
                                           width: s.width, height: s.height))
                }
                let size = textSize(badge.text, font)
                (badge.text as NSString).draw(at: NSPoint(x: x + badgeSymbolWidth + 2, y: height / 2 - size.height / 2),
                                              withAttributes: [.font: font, .foregroundColor: badge.color])
                x += badge.width + gap
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
        case .radial: w += ringSlot
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
        case .radial:
            drawRing(s, text: text, center: NSPoint(x: x + ringSlot / 2, y: mid))
            x += ringSlot
        case .percentage:
            drawText(pct(s.fraction), font, s.color)
        case .textOnly:
            drawText(pct(s.fraction), font, text)
        }

        if let c = s.countdown { x += 3; drawText(c, labelFont, text.withAlphaComponent(0.8)) }
    }

    /// Ring gauge: a faint full-circle track, the value as an arc clockwise from 12 o'clock, and
    /// the time marker as a short radial tick across the ring. Angles are in AppKit's
    /// unflipped space, where 90° is 12 o'clock and positive angles run counterclockwise.
    private static func drawRing(_ s: Segment, text: NSColor, center c: NSPoint) {
        let r = ringRadius, lw = ringWidth
        let track = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        track.lineWidth = lw
        text.withAlphaComponent(0.25).setStroke()
        track.stroke()

        let f = CGFloat(min(1, max(0, s.fraction)))
        if f >= 0.999 {
            s.color.setStroke()
            track.stroke()
        } else if f > 0 {
            let arc = NSBezierPath()
            // Keep a visible dot for tiny values, like the 3pt minimum on the progress bar.
            arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * max(f, 0.02), clockwise: true)
            arc.lineWidth = lw
            arc.lineCapStyle = .round
            s.color.setStroke()
            arc.stroke()
        }

        if let e = s.elapsed {
            let a = CGFloat(90 - 360 * e) * .pi / 180
            let inner = r - lw / 2 - 1.5, outer = r + lw / 2 + 1.5
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
            tick.line(to: NSPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
            tick.lineWidth = 1.5
            text.setStroke()
            tick.stroke()
        }
    }
}
