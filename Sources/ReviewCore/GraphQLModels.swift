import Foundation

struct PageInfo: Decodable, Sendable {
    var hasNextPage: Bool
    var endCursor: String?
}

struct Connection<Node: Decodable & Sendable>: Decodable, Sendable {
    var nodes: [Node?]
    var pageInfo: PageInfo
    var values: [Node] { nodes.compactMap { $0 } }
}

struct Actor: Decodable, Sendable {
    var __typename: String?
    var login: String?
    var slug: String?
    var name: String?
    var organization: Owner?
    var isTeam: Bool { __typename == "Team" || __typename == "EnterpriseTeam" }
    var isBot: Bool { __typename == "Bot" }
    var identifier: String? {
        if let login { return login }
        if let slug, let organization { return "\(organization.login)/\(slug)" }
        return slug ?? name
    }
}

struct Owner: Decodable, Sendable { var login: String }
struct RepositoryInfo: Decodable, Sendable {
    var name: String
    var owner: Owner
    var isPrivate: Bool
}
struct ReviewRecord: Decodable, Sendable {
    var id: String
    var state: String
    var author: Actor?
    var submittedAt: Date?
}
struct ReviewRequestRecord: Decodable, Sendable { var requestedReviewer: Actor? }
struct CommitNodes: Decodable, Sendable {
    var nodes: [CommitNode]
    struct CommitNode: Decodable, Sendable {
        var commit: Commit
        struct Commit: Decodable, Sendable {
            var statusCheckRollup: Rollup?
            struct Rollup: Decodable, Sendable { var state: String }
        }
    }
}

struct RawPullRequest: Decodable, Sendable {
    var id: String
    var number: Int
    var title: String
    var url: URL
    var state: String
    var updatedAt: Date
    var isDraft: Bool
    var author: Actor?
    var repository: RepositoryInfo
    var reviewDecision: String?
    var mergeable: String?
    var reviews: Connection<ReviewRecord>
    var reviewRequests: Connection<ReviewRequestRecord>
    var commits: CommitNodes
}

enum ReviewClassifier {
    static func map(_ raw: RawPullRequest, viewer: String, directlyRequested: Bool) -> PullRequest {
        // A later comment does not undo an approval or a changes-requested review.
        // A dismissed review does undo that opinion. Pending drafts are not submitted reviews.
        var byUser: [String: Reviewer] = [:]
        var hasReviewed = Set<String>()
        for review in raw.reviews.values.sorted(by: { ($0.submittedAt ?? .distantPast) < ($1.submittedAt ?? .distantPast) }) {
            guard let actor = review.author, let name = actor.identifier, review.state != "PENDING" else { continue }
            let key = "user:\(name.lowercased())"
            let status: ReviewStatus
            switch review.state {
            case "APPROVED": status = .approved
            case "CHANGES_REQUESTED": status = .changes
            case "DISMISSED": status = .dismissed
            case "COMMENTED":
                if let existing = byUser[key], [.approved, .changes, .dismissed].contains(existing.status) {
                    hasReviewed.insert(name.lowercased())
                    continue
                }
                status = .commented
            default: continue
            }
            hasReviewed.insert(name.lowercased())
            byUser[key] = Reviewer(name: name, status: status, isBot: actor.isBot)
        }
        for request in raw.reviewRequests.values {
            guard let actor = request.requestedReviewer, let name = actor.identifier else { continue }
            let reviewer = Reviewer(name: name, status: hasReviewed.contains(name.lowercased()) ? .rereview : .waiting, isTeam: actor.isTeam, isBot: actor.isBot)
            byUser[reviewer.id] = reviewer
        }
        let viewerKey = "user:\(viewer.lowercased())"
        // The search qualifier also covers a short-lived search/API consistency gap.
        if directlyRequested, byUser[viewerKey]?.status.needsReview != true {
            byUser[viewerKey] = Reviewer(name: viewer, status: hasReviewed.contains(viewer.lowercased()) ? .rereview : .waiting)
        }
        let reviewers = byUser.values.sorted {
            if $0.status.priority != $1.status.priority { return $0.status.priority < $1.status.priority }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let humanReviewers = reviewers.filter { !$0.isBot }
        let outgoing: ReviewStatus
        if raw.reviewDecision == "CHANGES_REQUESTED" || humanReviewers.contains(where: { $0.status == .changes }) {
            outgoing = .changes
        } else if reviewers.contains(where: { $0.status.needsReview }) {
            outgoing = .waiting
        } else if raw.reviewDecision == "REVIEW_REQUIRED" {
            outgoing = .required
        } else if raw.reviewDecision == "APPROVED" {
            outgoing = .approved
        } else if !humanReviewers.isEmpty && humanReviewers.allSatisfy({ $0.status == .approved }) {
            outgoing = .approved
        } else if !humanReviewers.isEmpty {
            outgoing = .required
        } else {
            outgoing = .unrequested
        }
        return PullRequest(id: raw.id, number: raw.number, title: raw.title, url: raw.url,
                           repository: raw.repository.name, author: raw.author?.login ?? "deleted-user",
                           updatedAt: raw.updatedAt, isDraft: raw.isDraft, isPrivate: raw.repository.isPrivate,
                           reviewers: reviewers, incomingStatus: byUser[viewerKey]?.status,
                           outgoingStatus: outgoing, isAuthored: raw.author?.login?.lowercased() == viewer.lowercased(),
                           checkState: raw.commits.nodes.last?.commit.statusCheckRollup?.state, mergeable: raw.mergeable,
                           repositoryOwner: raw.repository.owner.login)
    }
}
