import Charts
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updater: Updater
    var openSettings: () -> Void

    @AppStorage(SettingsKey.paceColoring) private var paceColoring = true
    @AppStorage(SettingsKey.showTimeMarker) private var showTimeMarker = true
    @AppStorage(SettingsKey.radialMeters) private var radialMeters = false
    @AppStorage(SettingsKey.pullRequestsEnabled) private var pullRequestsEnabled = true
    @AppStorage(SettingsKey.popoverTab) private var tab = "quotas"

    @AppStorage(SettingsKey.actionsEnabled) private var actionsEnabled = true

    /// Tabs for the features that are switched on; Quotas is always there.
    private var tabs: [(tag: String, title: String)] {
        var t: [(String, String)] = [("quotas", "Quotas")]
        if pullRequestsEnabled {
            let n = store.pullRequests?.waitingOnYouTotal ?? 0
            t.append(("pulls", n > 0 ? "Pull requests (\(n))" : "Pull requests"))
        }
        if actionsEnabled {
            let n = store.actions?.failing.count ?? 0
            t.append(("actions", n > 0 ? "Actions (\(n))" : "Actions"))
        }
        return t
    }

    /// Falls back to Quotas if the remembered tab's feature was switched off.
    private var currentTab: String { tabs.contains { $0.tag == tab } ? tab : "quotas" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            locationBanner
            updateBanner
            banner
            if tabs.count > 1 {
                Picker("View", selection: $tab) {
                    ForEach(tabs, id: \.tag) { Text($0.title).tag($0.tag) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            switch currentTab {
            case "pulls":
                PullRequestsView(queue: store.pullRequests, issue: store.pullRequestIssue, now: store.now)
            case "actions":
                ActionsView(status: store.actions, issue: store.actionsIssue, now: store.now, openSettings: openSettings)
            default:
                section("API rate limits", kinds: MetricKind.rateLimits)
                section("This month", kinds: MetricKind.billing)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Quotacat").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await store.refresh(forceActivity: true) }
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .disabled(store.isRefreshing)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let l = store.login { parts.append("@\(l)") }
        if let s = store.tokenSource { parts.append("via \(s.rawValue)") }
        if let u = store.lastUpdated { parts.append("updated \(relative(u))") }
        return parts.isEmpty ? "Not connected" : parts.joined(separator: " · ")
    }

    private func relative(_ d: Date) -> String {
        let s = Int(store.now.timeIntervalSince(d))
        return s < 60 ? "just now" : "\(s / 60)m ago"
    }

    // Mirrors Claude Usage's StatusBannerView: "Refresh failed %d times", credentials problems.
    // Shown only when there's something to act on; "up to date" stays in Settings.
    /// Updates can't install from a translocated or read-only copy, so say how to fix it up front.
    @ViewBuilder private var locationBanner: some View {
        if Updater.installLocationProblem != nil {
            VStack(alignment: .leading, spacing: 6) {
                Label("Move Quotacat to Applications", systemImage: "folder.badge.plus")
                    .font(.callout.weight(.medium))
                Text("It's running from a temporary copy, so updates can't install. Quit Quotacat, drag it from Downloads into Applications, and open it from there.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Applications Folder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                    }
                    Button("Quit Quotacat") { NSApp.terminate(nil) }
                }
                .controlSize(.small)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder private var updateBanner: some View {
        switch updater.state {
        case .available(let release):
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").font(.title3).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Quotacat \(release.version) is available").font(.callout.weight(.medium))
                    Link("What's new", destination: release.pageURL).font(.caption)
                }
                Spacer()
                if Updater.installLocationProblem == nil {
                    Button("Update") { Task { await updater.install(release) } }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                } else {
                    // Can't update in place from here; offer the manual download instead.
                    Link("Download", destination: release.pageURL)
                        .controlSize(.small)
                }
            }
            .padding(8)
            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .installing(let step):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(step).font(.callout)
                Spacer()
            }
            .padding(8)
            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text("Update failed").font(.caption.bold())
                Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                Link("Open the releases page", destination: Updater.releasesPage).font(.caption)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var banner: some View {
        if let err = store.lastError {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    if store.consecutiveFailures > 1 {
                        Text("Refresh failed \(store.consecutiveFailures) times").font(.caption.bold())
                    }
                    Text(err).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func section(_ title: String, kinds: [MetricKind]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(kinds) { kind in
                if let m = store.metrics[kind] {
                    MetricCard(metric: m, now: store.now, paceColoring: paceColoring,
                               showTimeMarker: showTimeMarker, radial: radialMeters)
                } else if let issue = store.issues[kind] {
                    IssueRow(kind: kind, message: issue)
                } else if store.isRefreshing || store.lastUpdated == nil {
                    HStack { Image(systemName: kind.symbol); Text(kind.title); Spacer(); Text("—") }
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…", action: openSettings)
            Spacer()
            Link("Billing", destination: Links.billing)
            Spacer()
            Link(destination: Links.tip) {
                Image(systemName: "heart.fill").foregroundStyle(.pink)
            }
            .help("Enjoying Quotacat? Buy me a coffee on Ko-fi")
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

struct MetricCard: View {
    let metric: UsageMetric
    let now: Date
    let paceColoring: Bool
    let showTimeMarker: Bool
    var radial = false
    @State private var expanded = false

    private var projected: Double? {
        UsageMath.projectedFraction(used: metric.used, limit: metric.limit,
                                    start: metric.periodStart, end: metric.resetAt, now: now)
    }

    private var elapsed: Double? {
        showTimeMarker ? UsageMath.elapsedFraction(start: metric.periodStart, end: metric.resetAt, now: now) : nil
    }

    private var meterColor: Color { Color(ns: Theme.barColor(for: metric, now: now, paceAware: paceColoring)) }
    private var percentColor: Color { Color(ns: Theme.status(UsageMath.statusLevel(fraction: metric.fraction))) }
    private var percentText: String { "\(Int((metric.fraction * 100).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if radial { radialLayout } else { barLayout }
            if !metric.breakdown.isEmpty || metric.daily.count > 1 {
                DisclosureGroup(isExpanded: $expanded) {
                    details.padding(.top, 4)
                } label: {
                    Text("Details").font(.caption)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Default layout: title and percentage on one line, a horizontal bar, then the caption.
    @ViewBuilder private var barLayout: some View {
        HStack(alignment: .firstTextBaseline) {
            title
            Spacer()
            Text(percentText)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(percentColor)
        }
        UsageBar(fraction: metric.fraction, elapsed: elapsed, color: meterColor,
                 markerColor: .primary)  // the bar and caption already carry the pace color
        HStack {
            quantity
            Spacer()
            resets
        }
        .font(.caption).foregroundStyle(.secondary)
        pace
    }

    /// Radial layout: a ring gauge with the percentage inside, and the text stacked beside it.
    private var radialLayout: some View {
        HStack(alignment: .center, spacing: 12) {
            RadialMeter(fraction: metric.fraction, elapsed: elapsed, color: meterColor, markerColor: .primary) {
                Text(percentText)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(percentColor)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                title
                quantity.font(.caption).foregroundStyle(.secondary)
                resets.font(.caption).foregroundStyle(.secondary)
                pace
            }
            Spacer(minLength: 0)
        }
    }

    private var title: some View {
        Label(metric.kind.title, systemImage: metric.kind.symbol).font(.callout.weight(.medium))
    }

    private var quantity: some View {
        HStack(spacing: 4) {
            Text("\(UsageMath.formatQuantity(metric.used)) / \(UsageMath.formatQuantity(metric.limit)) \(metric.kind.unit)")
            if let amt = metric.netAmount, amt > 0 {
                Text(String(format: "· $%.2f billed", amt))
            }
        }
    }

    private var resets: some View {
        Text("Resets in \(UsageMath.countdown(to: metric.resetAt, now: now))")
            .help(metric.resetAt.formatted(date: .abbreviated, time: .shortened))
    }

    @ViewBuilder private var pace: some View {
        if let p = projected {
            let tier = UsageMath.paceTier(projected: p)
            Text("\(tier.title) · projected \(Int((p * 100).rounded()))% by reset")
                .font(.caption2)
                .foregroundStyle(Color(ns: Theme.pace(tier)))
        }
    }

    @ViewBuilder private var details: some View {
        if metric.daily.count > 1 {
            Chart(metric.daily) { p in
                BarMark(x: .value("Day", p.date, unit: .day), y: .value(metric.kind.unit, p.quantity))
                    .foregroundStyle(Color.accentColor.gradient)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .frame(height: 70)
        }
        ForEach(metric.breakdown.prefix(6)) { item in
            HStack {
                Text(item.label).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(UsageMath.formatQuantity(item.quantity)).monospacedDigit()
                if item.netAmount > 0 { Text(String(format: "$%.2f", item.netAmount)).foregroundStyle(.secondary) }
            }
            .font(.caption)
        }
    }
}

struct UsageBar: View {
    let fraction: Double
    let elapsed: Double?
    let color: Color
    let markerColor: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: max(fraction > 0 ? 6 : 0, geo.size.width * min(1, fraction)))
                if let e = elapsed {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(markerColor)
                        .frame(width: 2, height: geo.size.height + 4)
                        .offset(x: geo.size.width * e - 1)
                        .help("\(Int(e * 100))% of the window elapsed")
                }
            }
        }
        .frame(height: 7)
    }
}

/// Ring gauge: a faint track, the value as an arc clockwise from 12 o'clock, the time marker as
/// a tick across the ring, and arbitrary content (usually the percentage) in the middle.
struct RadialMeter<Center: View>: View {
    let fraction: Double
    let elapsed: Double?
    let color: Color
    let markerColor: Color
    var lineWidth: CGFloat = 6
    @ViewBuilder let center: () -> Center

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = (side - lineWidth) / 2   // stroke centerline
            ZStack {
                Circle().stroke(.quaternary, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: min(1, max(fraction > 0 ? 0.02 : 0, fraction)))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let e = elapsed {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(markerColor)
                        .frame(width: 2, height: lineWidth + 4)
                        .offset(y: -radius)
                        .rotationEffect(.degrees(360 * e))
                        .help("\(Int(e * 100))% of the window elapsed")
                }
                center()
            }
            .frame(width: side - lineWidth, height: side - lineWidth)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

struct IssueRow: View {
    let kind: MetricKind
    let message: String

    private var needsScope: Bool { message.contains("`user`") }
    static let scopeCommand = "gh auth refresh -h github.com -s user"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(kind.title, systemImage: kind.symbol).font(.callout.weight(.medium))
            Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if needsScope {
                Button("Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.scopeCommand, forType: .string)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
