import Foundation

public enum RepositoryMode: String, Codable, CaseIterable, Sendable {
    case all, selected
}

public enum RepositorySelectionState: Sendable {
    case none, some, all
}

public struct RepositoryScope: Codable, Equatable, Sendable {
    public var organization: String
    public var mode: RepositoryMode
    /// Repository names, scoped to `organization`. Exclusions take precedence.
    public var includedRepositories: Set<String>
    public var excludedRepositories: Set<String>
    public var includeUnspecifiedRepositories: Bool

    public init(organization: String = "", mode: RepositoryMode = .all,
                includedRepositories: Set<String> = [], excludedRepositories: Set<String> = [],
                includeUnspecifiedRepositories: Bool = false) {
        self.organization = organization
        self.mode = mode
        self.includedRepositories = includedRepositories
        self.excludedRepositories = excludedRepositories
        self.includeUnspecifiedRepositories = includeUnspecifiedRepositories
    }

    private enum CodingKeys: String, CodingKey {
        case organization, mode, includedRepositories, excludedRepositories, includeUnspecifiedRepositories
    }
    private enum LegacyKeys: String, CodingKey { case repositories }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        organization = try values.decode(String.self, forKey: .organization)
        let savedMode = try values.decode(String.self, forKey: .mode)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let oldRepositories = try legacy.decodeIfPresent(Set<String>.self, forKey: .repositories) ?? []
        includedRepositories = try values.decodeIfPresent(Set<String>.self, forKey: .includedRepositories) ?? []
        excludedRepositories = try values.decodeIfPresent(Set<String>.self, forKey: .excludedRepositories) ?? []
        includeUnspecifiedRepositories = try values.decodeIfPresent(Bool.self, forKey: .includeUnspecifiedRepositories) ?? false
        switch savedMode {
        case "include":
            mode = .selected
            includedRepositories = oldRepositories
        case "exclude":
            mode = .selected
            excludedRepositories = oldRepositories
            includeUnspecifiedRepositories = true
        case "all": mode = .all
        case "selected": mode = .selected
        default:
            throw DecodingError.dataCorruptedError(forKey: .mode, in: values, debugDescription: "Unknown repository mode")
        }
    }

    public var isValid: Bool {
        organization.range(of: #"\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\z"#, options: .regularExpression) != nil
    }
    public var configuredRepositories: Set<String> { includedRepositories.union(excludedRepositories) }
    public var includesAllRepositories: Bool {
        mode == .all || (includeUnspecifiedRepositories && excludedRepositories.isEmpty)
    }
    public func selectionState(repositoryNames: [String]) -> RepositorySelectionState {
        if includesAllRepositories { return .all }
        let count = repositoryNames.filter { contains(owner: organization, name: $0) }.count
        if count == 0 { return .none }
        return count == repositoryNames.count ? .all : .some
    }
    public var isEmptySelection: Bool {
        mode == .selected && !includeUnspecifiedRepositories &&
        !includedRepositories.contains { isIncludedInSelection($0) }
    }

    public func contains(owner: String, name: String) -> Bool {
        guard owner.caseInsensitiveCompare(organization) == .orderedSame else { return false }
        return mode == .all || isIncludedInSelection(name)
    }

    public func isIncludedInSelection(_ name: String) -> Bool {
        if excludedRepositories.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return false }
        return includeUnspecifiedRepositories || includedRepositories.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    public mutating func setIncluded(_ included: Bool, repository name: String) {
        // Editing an all-selected scope starts from the currently monitored set,
        // rather than reviving an older, hidden Selected configuration.
        if mode == .all {
            guard !included else { return }
            setAllIncluded(true)
        }
        includedRepositories = includedRepositories.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
        excludedRepositories = excludedRepositories.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
        if included { includedRepositories.insert(name) }
        else { excludedRepositories.insert(name) }
    }

    public mutating func setAllIncluded(_ included: Bool) {
        mode = .selected
        includedRepositories = []
        excludedRepositories = []
        includeUnspecifiedRepositories = included
    }
}

public struct Repository: Identifiable, Codable, Hashable, Sendable {
    public var name: String
    public var isPrivate: Bool
    public var isArchived: Bool
    public var id: String { name }
    public init(name: String, isPrivate: Bool = false, isArchived: Bool = false) {
        self.name = name; self.isPrivate = isPrivate; self.isArchived = isArchived
    }
}

public enum ReviewStatus: String, Codable, CaseIterable, Sendable {
    case waiting, rereview, approved, changes, commented, dismissed, required, unrequested
    public var needsReview: Bool { self == .waiting || self == .rereview }
    public var priority: Int {
        switch self {
        case .changes: 0
        case .rereview: 1
        case .waiting, .required: 2
        case .unrequested: 3
        case .approved: 4
        case .commented, .dismissed: 5
        }
    }
}

public struct Reviewer: Identifiable, Equatable, Sendable {
    public var name: String
    public var status: ReviewStatus
    public var isTeam: Bool
    public var isBot: Bool
    public var id: String { "\(isTeam ? "team" : "user"):\(name.lowercased())" }
    public init(name: String, status: ReviewStatus, isTeam: Bool = false, isBot: Bool = false) {
        self.name = name; self.status = status; self.isTeam = isTeam; self.isBot = isBot
    }
}

public struct PullRequest: Identifiable, Equatable, Sendable {
    public var id: String
    public var number: Int
    public var title: String
    public var url: URL
    public var repository: String
    public var repositoryOwner: String
    public var repositoryFullName: String { "\(repositoryOwner)/\(repository)" }
    public var author: String
    public var updatedAt: Date
    public var isDraft: Bool
    public var isPrivate: Bool
    public var reviewers: [Reviewer]
    public var incomingStatus: ReviewStatus?
    public var outgoingStatus: ReviewStatus
    public var isAuthored: Bool
    public var checkState: String?
    public var mergeable: String?
    public init(id: String, number: Int, title: String, url: URL, repository: String, author: String,
                updatedAt: Date, isDraft: Bool = false, isPrivate: Bool = false, reviewers: [Reviewer],
                incomingStatus: ReviewStatus?, outgoingStatus: ReviewStatus, isAuthored: Bool,
                checkState: String? = nil, mergeable: String? = nil, repositoryOwner: String? = nil) {
        self.id = id; self.number = number; self.title = title; self.url = url
        self.repository = repository; self.author = author; self.updatedAt = updatedAt
        self.repositoryOwner = repositoryOwner ?? url.pathComponents.dropFirst().first ?? ""
        self.isDraft = isDraft; self.isPrivate = isPrivate; self.reviewers = reviewers
        self.incomingStatus = incomingStatus; self.outgoingStatus = outgoingStatus
        self.isAuthored = isAuthored; self.checkState = checkState; self.mergeable = mergeable
    }

    /// A display preference; keep the fetched status intact for activity tracking.
    public func outgoingStatus(approveWithOneApproval: Bool) -> ReviewStatus {
        guard approveWithOneApproval, outgoingStatus != .changes,
              reviewers.contains(where: { !$0.isBot && !$0.isTeam && $0.status == .approved }) else {
            return outgoingStatus
        }
        return .approved
    }
}

public struct ReviewSnapshot: Sendable {
    public var login: String
    public var avatarURL: URL?
    public var pullRequests: [PullRequest]
    public var fetchedAt: Date
    public var warnings: [ReviewWarning]
    public init(login: String, pullRequests: [PullRequest], fetchedAt: Date = Date(), warnings: [ReviewWarning] = [], avatarURL: URL? = nil) {
        self.login = login; self.pullRequests = pullRequests; self.fetchedAt = fetchedAt; self.warnings = warnings
        self.avatarURL = avatarURL
    }
}

public struct ReviewWarning: Equatable, Sendable {
    public var reason: ReviewError
    public var organization: String?
    public init(reason: ReviewError, organization: String? = nil) {
        self.reason = reason
        self.organization = organization
    }
}

public enum ReviewError: String, CaseIterable, Error, LocalizedError, Equatable, Sendable {
    case invalidOrganization, organizationUnavailable, cliMissing, authentication, network, rateLimited
    case api, invalidResponse, timedOut, tooManyResults

    public var errorDescription: String? {
        switch self {
        case .invalidOrganization: "Enter an organization name using letters, numbers, and hyphens."
        case .organizationUnavailable: "Organization not found or access denied. Check its name, GitHub authentication, and SSO."
        case .cliMissing: "GitHub CLI (gh) was not found. Install it, then reconnect."
        case .authentication: "Check your GitHub authentication. Run gh auth login --hostname github.com in Terminal."
        case .network: "Could not connect to GitHub. Check your network and try again."
        case .rateLimited: "GitHub API rate limit reached. Wait a while, then try again."
        case .api: "Could not fetch data from GitHub. Check authentication, organization SSO, and access permissions."
        case .invalidResponse: "Could not read the GitHub response. Please try again."
        case .timedOut: "The connection to GitHub timed out. Please try again."
        case .tooManyResults: "Search exceeds GitHub’s 1,000-result limit. Only the latest 1,000 results per query are shown."
        }
    }
}
