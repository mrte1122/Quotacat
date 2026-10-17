import Charts
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updater: Updater
    var openSettings: () -> Void

    @AppStorage(SettingsKey.paceColoring) private var paceColoring = true
    @AppStorage(SettingsKey.showTimeMarker) private var showTimeMarker = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            updateBanner
            banner
            section("API rate limits", kinds: MetricKind.rateLimits)
            section("This month", kinds: MetricKind.billing)
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
                Task { await store.refresh() }
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
                Button("Update") { Task { await updater.install(release) } }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
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
                    MetricCard(metric: m, now: store.now, paceColoring: paceColoring, showTimeMarker: showTimeMarker)
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
    @State private var expanded = false

    private var projected: Double? {
        UsageMath.projectedFraction(used: metric.used, limit: metric.limit,
                                    start: metric.periodStart, end: metric.resetAt, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Label(metric.kind.title, systemImage: metric.kind.symbol).font(.callout.weight(.medium))
                Spacer()
                Text("\(Int((metric.fraction * 100).rounded()))%")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color(ns: Theme.status(UsageMath.statusLevel(fraction: metric.fraction))))
            }
            UsageBar(fraction: metric.fraction,
                     elapsed: showTimeMarker ? UsageMath.elapsedFraction(start: metric.periodStart, end: metric.resetAt, now: now) : nil,
                     color: Color(ns: Theme.barColor(for: metric, now: now, paceAware: paceColoring)),
                     markerColor: .primary)  // the bar and caption already carry the pace color
            HStack {
                Text("\(UsageMath.formatQuantity(metric.used)) / \(UsageMath.formatQuantity(metric.limit)) \(metric.kind.unit)")
                if let amt = metric.netAmount, amt > 0 {
                    Text(String(format: "· $%.2f billed", amt))
                }
                Spacer()
                Text("Resets in \(UsageMath.countdown(to: metric.resetAt, now: now))")
                    .help(metric.resetAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.caption).foregroundStyle(.secondary)
            if let p = projected {
                let tier = UsageMath.paceTier(projected: p)
                Text("\(tier.title) · projected \(Int((p * 100).rounded()))% by reset")
                    .font(.caption2)
                    .foregroundStyle(Color(ns: Theme.pace(tier)))
            }
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
