import SwiftUI

/// The "Actions" tab: workflows whose latest run on the default branch failed.
struct ActionsView: View {
    let status: ActionsStatus?
    let issue: String?
    let now: Date
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let status {
                if status.watchedRepos.isEmpty {
                    note("No repositories to watch", systemImage: "eye.slash", color: .secondary,
                         detail: "Nothing pushed in the last 30 days, or no repositories selected.")
                } else if status.failing.isEmpty {
                    note("All workflows passing", systemImage: "checkmark.circle.fill", color: .green,
                         detail: "Latest runs on each default branch succeeded.")
                } else {
                    Text("FAILING ON DEFAULT BRANCH (\(status.failing.count))")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(Array(status.failing.enumerated()), id: \.element.id) { index, f in
                            if index > 0 { Divider().padding(.leading, 8) }
                            FailingWorkflowRow(failure: f, now: now)
                        }
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    Text("Watching \(status.watchedRepos.count) \(status.watchedRepos.count == 1 ? "repository" : "repositories")")
                    Spacer()
                    Button("Change…", action: openSettings).buttonStyle(.borderless)
                }
                .font(.caption).foregroundStyle(.secondary)
                .help(status.watchedRepos.joined(separator: "\n"))
            } else if let issue {
                Label {
                    Text(issue).font(.caption).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Checking workflows…").font(.callout) }
            }
        }
    }

    private func note(_ title: String, systemImage: String, color: Color, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).font(.title2).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct FailingWorkflowRow: View {
    let failure: FailingWorkflow
    let now: Date

    private var label: String {
        switch failure.conclusion {
        case "timed_out": return "Timed out"
        case "startup_failure": return "Couldn't start"
        default: return "Failed"
        }
    }

    var body: some View {
        Link(destination: failure.runURL) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.workflowName).font(.callout).foregroundStyle(.primary).lineLimit(1)
                    Text("\(failure.repo) · \(failure.branch)\(failure.runNumber.map { " · #\($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(label).font(.caption2.weight(.medium)).foregroundStyle(.red)
                    if let at = failure.failedAt {
                        Text(UsageMath.age(since: at, now: now) + " ago").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
