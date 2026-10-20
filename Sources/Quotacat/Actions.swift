import Foundation

struct WorkflowRun: Decodable, Hashable {
    let id: Int
    let name: String?
    let workflowID: Int
    let headBranch: String?
    let status: String?
    let conclusion: String?
    let htmlURL: URL
    let runNumber: Int?
    let event: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, event
        case workflowID = "workflow_id"
        case headBranch = "head_branch"
        case htmlURL = "html_url"
        case runNumber = "run_number"
        case updatedAt = "updated_at"
    }
}

/// A workflow whose most recent completed run on the default branch failed.
struct FailingWorkflow: Identifiable, Hashable {
    /// Stable per workflow (not per run), so a re-run that still fails isn't a "new" failure.
    var id: String { "\(repo)#\(workflowID)" }
    let repo: String
    let workflowID: Int
    let workflowName: String
    let branch: String
    let conclusion: String
    let runURL: URL
    let runNumber: Int?
    let failedAt: Date?
}

struct ActionsStatus {
    var failing: [FailingWorkflow]
    var watchedRepos: [String]
    var checkedAt: Date

    static let failureConclusions: Set<String> = ["failure", "timed_out", "startup_failure"]

    /// Latest completed run per workflow (runs arrive newest first); keep the ones that failed.
    static func failing(repo: String, branch: String, runs: [WorkflowRun]) -> [FailingWorkflow] {
        var seen = Set<Int>()
        var result: [FailingWorkflow] = []
        let iso = ISO8601DateFormatter()
        for run in runs where run.status == "completed" {
            guard seen.insert(run.workflowID).inserted else { continue }
            guard let conclusion = run.conclusion, failureConclusions.contains(conclusion) else { continue }
            result.append(FailingWorkflow(repo: repo, workflowID: run.workflowID, workflowName: run.name ?? "Workflow",
                                          branch: branch, conclusion: conclusion, runURL: run.htmlURL,
                                          runNumber: run.runNumber, failedAt: run.updatedAt.flatMap(iso.date(from:))))
        }
        return result
    }
}

struct RepoSummary: Decodable, Hashable {
    let fullName: String
    let defaultBranch: String
    let pushedAt: String?
    let archived: Bool
    let isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case archived
        case isPrivate = "private"
        case fullName = "full_name"
        case defaultBranch = "default_branch"
        case pushedAt = "pushed_at"
    }
}

/// Fetches repositories and workflow runs with ETags. GitHub doesn't count a 304 Not Modified
/// response against the rate limit, so polling unchanged repos is effectively free.
actor ActionsFetcher {
    private var cache: [URL: (etag: String, data: Data)] = [:]

    func repositories(token: String) async throws -> [RepoSummary] {
        let url = URL(string: "https://api.github.com/user/repos?affiliation=owner,collaborator,organization_member&sort=pushed&per_page=100")!
        return try JSONDecoder().decode([RepoSummary].self, from: try await get(url, token: token))
    }

    func failingWorkflows(repo: RepoSummary, token: String) async throws -> [FailingWorkflow] {
        struct Page: Decodable {
            let runs: [WorkflowRun]
            enum CodingKeys: String, CodingKey { case runs = "workflow_runs" }
        }
        var comps = URLComponents(string: "https://api.github.com/repos/\(repo.fullName)/actions/runs")!
        comps.queryItems = [.init(name: "branch", value: repo.defaultBranch),
                            .init(name: "status", value: "completed"),
                            .init(name: "per_page", value: "30")]
        let page = try JSONDecoder().decode(Page.self, from: try await get(comps.url!, token: token))
        return ActionsStatus.failing(repo: repo.fullName, branch: repo.defaultBranch, runs: page.runs)
    }

    private func get(_ url: URL, token: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Quotacat/1.0", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData   // we manage ETags ourselves
        req.timeoutInterval = 20
        if let cached = cache[url] { req.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }

        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        switch http?.statusCode ?? -1 {
        case 304:
            if let cached = cache[url] { return cached.data }
            throw GitHubError.http(304, "unexpected Not Modified")
        case 200:
            if let etag = http?.value(forHTTPHeaderField: "ETag") { cache[url] = (etag, data) }
            return data
        case 401:
            throw GitHubError.unauthorized
        case let code:
            throw GitHubError.http(code, url.path)
        }
    }
}
