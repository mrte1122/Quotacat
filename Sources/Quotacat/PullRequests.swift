import Foundation

enum ReviewDecision: String, Decodable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

struct PullRequestItem: Identifiable, Hashable {
    var id: String { url.absoluteString }
    let number: Int
    let title: String
    let url: URL
    let repo: String
    let author: String?
    let createdAt: Date
    let isDraft: Bool
    let reviewDecision: ReviewDecision?
}

struct PullRequestQueue {
    /// Open PRs where you (or a team you're on) are a requested reviewer, oldest first.
    var waitingOnYou: [PullRequestItem]
    var waitingOnYouTotal: Int
    /// Your own open PRs, oldest first.
    var yours: [PullRequestItem]
    var yoursTotal: Int

    static let reviewRequestsPage = URL(string: "https://github.com/pulls/review-requested")!
    static let yoursPage = URL(string: "https://github.com/pulls")!
}

extension GitHubClient {
    /// Both lists in a single GraphQL request (about 1 point of the 5,000/hour GraphQL budget),
    /// rather than two calls against the 30/minute search limit.
    func fetchPullRequests(login: String) async throws -> PullRequestQueue {
        let query = """
        query($waiting: String!, $yours: String!) {
          waiting: search(query: $waiting, type: ISSUE, first: 30) { issueCount nodes { ...pr } }
          yours: search(query: $yours, type: ISSUE, first: 30) { issueCount nodes { ...pr } }
        }
        fragment pr on PullRequest {
          number title url createdAt isDraft reviewDecision
          repository { nameWithOwner }
          author { login }
        }
        """
        let base = "is:pr is:open archived:false sort:created-asc"
        let variables = ["waiting": "\(base) review-requested:\(login)", "yours": "\(base) author:\(login)"]

        var req = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Quotacat/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if code == 401 { throw GitHubError.unauthorized }
        guard code == 200 else { throw GitHubError.http(code, "pull request search failed") }
        return try Self.decodePullRequests(data)
    }

    static func decodePullRequests(_ data: Data) throws -> PullRequestQueue {
        struct Node: Decodable {
            struct Repo: Decodable { let nameWithOwner: String }
            struct Author: Decodable { let login: String }
            let number: Int?
            let title: String?
            let url: URL?
            let createdAt: String?
            let isDraft: Bool?
            let reviewDecision: ReviewDecision?
            let repository: Repo?
            let author: Author?
        }
        struct Search: Decodable { let issueCount: Int; let nodes: [Node] }
        struct Payload: Decodable {
            struct DataBlock: Decodable { let waiting: Search; let yours: Search }
            struct GQLError: Decodable { let message: String }
            let data: DataBlock?
            let errors: [GQLError]?
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let block = payload.data else {
            throw GitHubError.notAvailable(payload.errors?.first?.message ?? "Pull request search returned no data.")
        }
        let iso = ISO8601DateFormatter()
        func items(_ s: Search) -> [PullRequestItem] {
            s.nodes.compactMap { n in
                guard let number = n.number, let title = n.title, let url = n.url,
                      let created = n.createdAt.flatMap(iso.date(from:)), let repo = n.repository else { return nil }
                return PullRequestItem(number: number, title: title, url: url, repo: repo.nameWithOwner,
                                       author: n.author?.login, createdAt: created, isDraft: n.isDraft ?? false,
                                       reviewDecision: n.reviewDecision)
            }
        }
        return PullRequestQueue(waitingOnYou: items(block.waiting), waitingOnYouTotal: block.waiting.issueCount,
                                yours: items(block.yours), yoursTotal: block.yours.issueCount)
    }
}
