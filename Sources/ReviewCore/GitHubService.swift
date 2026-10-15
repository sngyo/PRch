import Foundation

public protocol ReviewService: Sendable {
    func fetch(scope: RepositoryScope) async throws -> ReviewSnapshot
    func repositories(organization: String) async throws -> [Repository]
}

public extension ReviewService {
    /// Publish only a complete refresh. A failing organization must not silently
    /// disappear from aggregate counts or make stale data appear current.
    func fetch(scopes: [RepositoryScope]) async throws -> ReviewSnapshot {
        guard !scopes.isEmpty, scopes.allSatisfy(\.isValid),
              Set(scopes.map { $0.organization.lowercased() }).count == scopes.count else {
            throw ReviewError.invalidOrganization
        }
        var merged: ReviewSnapshot?
        var seen = Set<String>()
        for scope in scopes {
            try Task.checkCancellation()
            // Empty groups contribute no PRs; one identity request is still useful
            // when every group is unchecked.
            if scope.isEmptySelection, merged != nil { continue }
            let result = try await fetch(scope: scope)
            if merged == nil {
                merged = ReviewSnapshot(login: result.login, pullRequests: [], avatarURL: result.avatarURL)
            }
            guard merged?.login.caseInsensitiveCompare(result.login) == .orderedSame else {
                throw ReviewError.authentication
            }
            merged?.pullRequests += result.pullRequests.filter {
                scope.contains(owner: $0.repositoryOwner, name: $0.repository) && seen.insert($0.id).inserted
            }
            merged?.warnings += result.warnings.map { ReviewWarning(reason: $0.reason, organization: scope.organization) }
        }
        guard var snapshot = merged else { throw ReviewError.invalidResponse }
        snapshot.fetchedAt = Date()
        return snapshot
    }
}

public struct GitHubService: ReviewService {
    private let transport: any GitHubTransport
    public init(transport: any GitHubTransport = GitHubCLITransport()) { self.transport = transport }

    public func fetch(scope: RepositoryScope) async throws -> ReviewSnapshot {
        guard scope.isValid else { throw ReviewError.invalidOrganization }
        let identity: IdentityResponse = try await execute(Self.identityQuery, ["organization": scope.organization])
        guard identity.organization != nil else { throw ReviewError.organizationUnavailable }
        let login = identity.viewer.login
        let avatarURL = identity.viewer.avatarUrl.flatMap { url in
            url.scheme == "https" && url.host == "avatars.githubusercontent.com" ? url : nil
        }
        if scope.isEmptySelection {
            return ReviewSnapshot(login: login, pullRequests: [], avatarURL: avatarURL)
        }
        let base = "is:pr is:open archived:false org:\(scope.organization) sort:updated-desc"
        async let requested = search("\(base) user-review-requested:\(login)")
        async let reviewed = search("\(base) reviewed-by:\(login)")
        async let authored = search("\(base) author:\(login)")
        let (requests, reviews, own) = try await (requested, reviewed, authored)
        let requestedIDs = Set(requests.nodes.map(\.id))
        var unique: [String: RawPullRequest] = [:]
        for pr in own.nodes + reviews.nodes + requests.nodes {
            guard pr.state == "OPEN", scope.contains(owner: pr.repository.owner.login, name: pr.repository.name) else { continue }
            unique[pr.id] = pr
        }
        var result: [PullRequest] = []
        for var pr in unique.values.sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation()
            try await hydrate(&pr)
            // Only follow trusted GitHub PR URLs when a user clicks a row.
            guard pr.url.scheme == "https", pr.url.host == "github.com" else { throw ReviewError.invalidResponse }
            result.append(ReviewClassifier.map(pr, viewer: login, directlyRequested: requestedIDs.contains(pr.id)))
        }
        let truncated = requests.truncated || reviews.truncated || own.truncated
        return ReviewSnapshot(login: login, pullRequests: result,
                              warnings: truncated ? [ReviewWarning(reason: .tooManyResults)] : [], avatarURL: avatarURL)
    }

    public func repositories(organization: String) async throws -> [Repository] {
        guard RepositoryScope(organization: organization).isValid else { throw ReviewError.invalidOrganization }
        var variables = ["organization": organization]
        var result: [Repository] = []
        var cursors = Set<String>()
        while true {
            try Task.checkCancellation()
            let response: RepositoriesResponse = try await execute(Self.repositoriesQuery, variables)
            guard let organization = response.organization else { throw ReviewError.organizationUnavailable }
            result += organization.repositories.values.filter { !$0.isArchived }
            guard organization.repositories.pageInfo.hasNextPage else { break }
            guard let cursor = organization.repositories.pageInfo.endCursor, cursors.insert(cursor).inserted else {
                throw ReviewError.invalidResponse
            }
            variables["cursor"] = cursor
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private struct SearchResult: Sendable { var nodes: [RawPullRequest]; var truncated: Bool }
    private func search(_ query: String) async throws -> SearchResult {
        var variables = ["search": query]
        var result: [RawPullRequest] = []
        var cursors = Set<String>()
        var truncated = false
        while true {
            try Task.checkCancellation()
            let response: SearchResponse = try await execute(Self.searchQuery, variables)
            result += response.search.nodes.compactMap { $0 }
            truncated = response.search.issueCount > 1_000
            guard response.search.pageInfo.hasNextPage, result.count < 1_000 else { break }
            guard let cursor = response.search.pageInfo.endCursor, cursors.insert(cursor).inserted else {
                throw ReviewError.invalidResponse
            }
            variables["cursor"] = cursor
        }
        return SearchResult(nodes: result, truncated: truncated)
    }

    private func hydrate(_ pr: inout RawPullRequest) async throws {
        var cursors = Set<String>()
        while pr.reviews.pageInfo.hasNextPage {
            guard let cursor = pr.reviews.pageInfo.endCursor, cursors.insert(cursor).inserted else { throw ReviewError.invalidResponse }
            let response: MoreReviews = try await execute(Self.reviewsQuery, ["id": pr.id, "cursor": cursor])
            guard let node = response.node else { throw ReviewError.invalidResponse }
            pr.reviews.nodes += node.reviews.nodes
            pr.reviews.pageInfo = node.reviews.pageInfo
        }
        cursors.removeAll()
        while pr.reviewRequests.pageInfo.hasNextPage {
            guard let cursor = pr.reviewRequests.pageInfo.endCursor, cursors.insert(cursor).inserted else { throw ReviewError.invalidResponse }
            let response: MoreRequests = try await execute(Self.requestsQuery, ["id": pr.id, "cursor": cursor])
            guard let node = response.node else { throw ReviewError.invalidResponse }
            pr.reviewRequests.nodes += node.reviewRequests.nodes
            pr.reviewRequests.pageInfo = node.reviewRequests.pageInfo
        }
    }

    private func execute<T: Decodable & Sendable>(_ query: String, _ variables: [String: String]) async throws -> T {
        let bytes = try await transport.request(query: query, variables: variables)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: Envelope<T>
        do { envelope = try decoder.decode(Envelope<T>.self, from: bytes) }
        catch { throw ReviewError.invalidResponse }
        if let errors = envelope.errors, !errors.isEmpty {
            if errors.contains(where: { $0.type == "RATE_LIMITED" }) { throw ReviewError.rateLimited }
            if errors.contains(where: { $0.type == "NOT_FOUND" }) { throw ReviewError.organizationUnavailable }
            throw ReviewError.api
        }
        guard let data = envelope.data else { throw ReviewError.invalidResponse }
        return data
    }

    private struct Envelope<T: Decodable & Sendable>: Decodable, Sendable {
        var data: T?
        var errors: [APIError]?
        struct APIError: Decodable, Sendable { var type: String? }
    }
    private struct IdentityResponse: Decodable, Sendable {
        var viewer: Viewer
        var organization: Owner?
        struct Viewer: Decodable, Sendable { var login: String; var avatarUrl: URL? }
    }
    private struct SearchResponse: Decodable, Sendable {
        var search: Results
        struct Results: Decodable, Sendable { var issueCount: Int; var nodes: [RawPullRequest?]; var pageInfo: PageInfo }
    }
    private struct RepositoriesResponse: Decodable, Sendable {
        var organization: Organization?
        struct Organization: Decodable, Sendable { var repositories: Connection<Repository> }
    }
    private struct MoreReviews: Decodable, Sendable {
        var node: Node?
        struct Node: Decodable, Sendable { var reviews: Connection<ReviewRecord> }
    }
    private struct MoreRequests: Decodable, Sendable {
        var node: Node?
        struct Node: Decodable, Sendable { var reviewRequests: Connection<ReviewRequestRecord> }
    }

    private static let identityQuery = """
    query Identity($organization: String!) {
      viewer { login avatarUrl(size: 64) }
      organization(login: $organization) { login }
    }
    """
    private static let repositoriesQuery = """
    query Repositories($organization: String!, $cursor: String) {
      organization(login: $organization) {
        repositories(first: 100, after: $cursor, orderBy: {field: NAME, direction: ASC}) {
          nodes { name isPrivate isArchived }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
    """
    private static let reviewFields = """
    nodes { id state submittedAt author { __typename login } }
    pageInfo { hasNextPage endCursor }
    """
    private static let requestFields = """
    nodes { requestedReviewer {
      __typename
      ... on User { login }
      ... on Bot { login }
      ... on Team { name slug organization { login } }
    } }
    pageInfo { hasNextPage endCursor }
    """
    private static let searchQuery = """
    query ReviewSearch($search: String!, $cursor: String) {
      search(query: $search, type: ISSUE, first: 25, after: $cursor) {
        issueCount pageInfo { hasNextPage endCursor }
        nodes { ... on PullRequest {
          id number title url state updatedAt isDraft reviewDecision mergeable
          author { __typename login }
          repository { name isPrivate owner { login } }
          reviews(first: 100) { \(reviewFields) }
          reviewRequests(first: 100) { \(requestFields) }
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        } }
      }
    }
    """
    private static let reviewsQuery = """
    query MoreReviews($id: ID!, $cursor: String!) {
      node(id: $id) { ... on PullRequest { reviews(first: 100, after: $cursor) { \(reviewFields) } } }
    }
    """
    private static let requestsQuery = """
    query MoreRequests($id: ID!, $cursor: String!) {
      node(id: $id) { ... on PullRequest { reviewRequests(first: 100, after: $cursor) { \(requestFields) } } }
    }
    """
}
