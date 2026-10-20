import SwiftUI

/// The "Pull requests" tab: PRs waiting on your review, then your own open PRs.
struct PullRequestsView: View {
    let queue: PullRequestQueue?
    let issue: String?
    let now: Date
    static let maxRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let issue, queue == nil {
                Label {
                    Text(issue).font(.caption).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } else if let queue {
                list("Waiting on your review", items: queue.waitingOnYou, total: queue.waitingOnYouTotal,
                     empty: "Nothing waiting on you.", seeAll: PullRequestQueue.reviewRequestsPage, yours: false)
                list("Your open pull requests", items: queue.yours, total: queue.yoursTotal,
                     empty: "You have no open pull requests.", seeAll: PullRequestQueue.yoursPage, yours: true)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Loading pull requests…").font(.callout) }
            }
        }
    }

    private func list(_ title: String, items: [PullRequestItem], total: Int, empty: String,
                      seeAll: URL, yours: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(title.uppercased()) (\(total))").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Link("See all", destination: seeAll).font(.caption)
            }
            if items.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.prefix(Self.maxRows).enumerated()), id: \.element.id) { index, pr in
                        if index > 0 { Divider().padding(.leading, 8) }
                        PullRequestRow(pr: pr, now: now, yours: yours)
                    }
                    if total > Self.maxRows {
                        Divider().padding(.leading, 8)
                        Link("+\(total - Self.maxRows) more on GitHub", destination: seeAll)
                            .font(.caption)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct PullRequestRow: View {
    let pr: PullRequestItem
    let now: Date
    /// Your own PRs show their review status; PRs waiting on you show who opened them.
    let yours: Bool

    private var ageDays: Double { now.timeIntervalSince(pr.createdAt) / 86_400 }

    /// Review requests get warmer as they age; your own PRs stay neutral.
    private var ageColor: Color {
        guard !yours else { return .secondary }
        if ageDays >= 7 { return .red }
        if ageDays >= 3 { return .orange }
        return .secondary
    }

    var body: some View {
        Link(destination: pr.url) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pr.title).font(.callout).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 4) {
                        Text("\(pr.repo) #\(pr.number)")
                        if !yours, let author = pr.author { Text("· @\(author)") }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(UsageMath.age(since: pr.createdAt, now: now))
                        .font(.caption.monospacedDigit().weight(ageDays >= 3 && !yours ? .semibold : .regular))
                        .foregroundStyle(ageColor)
                        .help("Opened \(pr.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    if yours { status }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var status: some View {
        if pr.isDraft {
            chip("Draft", .gray)
        } else {
            switch pr.reviewDecision {
            case .approved: chip("Approved", .green)
            case .changesRequested: chip("Changes requested", .orange)
            case .reviewRequired: chip("Awaiting review", .gray)
            case nil: EmptyView()
            }
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}
