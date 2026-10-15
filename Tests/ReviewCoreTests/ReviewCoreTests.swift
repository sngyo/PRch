import Foundation
import Testing
@testable import ReviewCore

private var end: [String: Any] { ["hasNextPage": false, "endCursor": NSNull()] }

private func actor(_ login: String, bot: Bool = false) -> [String: Any] {
    ["__typename": bot ? "Bot" : "User", "login": login]
}
private func review(_ login: String, _ state: String, day: Int = 1, bot: Bool = false) -> [String: Any] {
    ["id": "\(login)-\(day)", "state": state, "submittedAt": String(format: "2026-01-%02dT00:00:00Z", day), "author": actor(login, bot: bot)]
}
private func fixture(id: String = "PR_1", owner: String = "example-org", repo: String = "app", author: String = "alex",
                     state: String = "OPEN", decision: String? = nil, reviews: [[String: Any]] = [],
                     requested: [String] = [], moreReviews: Bool = false) -> [String: Any] {
    ["id": id, "number": 42, "title": "A synthetic pull request", "url": "https://github.com/\(owner)/\(repo)/pull/42",
     "state": state, "updatedAt": "2026-01-02T00:00:00Z", "isDraft": false,
     "author": actor(author), "repository": ["name": repo, "owner": ["login": owner], "isPrivate": true],
     "reviewDecision": decision as Any? ?? NSNull(), "mergeable": "MERGEABLE",
     "reviews": ["nodes": reviews, "pageInfo": moreReviews ? ["hasNextPage": true, "endCursor": "review-cursor"] : end],
     "reviewRequests": ["nodes": requested.map { ["requestedReviewer": actor($0)] }, "pageInfo": end],
     "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": "SUCCESS"]]]]]]
}
private func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
private func raw(_ object: [String: Any]) throws -> RawPullRequest {
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(RawPullRequest.self, from: data(object))
}
private func searchData(_ nodes: [[String: Any]], more: Bool = false, total: Int? = nil) throws -> Data {
    try data(["data": ["search": ["issueCount": total ?? nodes.count, "nodes": nodes,
                                         "pageInfo": more ? ["hasNextPage": true, "endCursor": "next-page"] : end]]])
}
private let identity = Data(#"{"data":{"viewer":{"login":"you"},"organization":{"login":"example-org"}}}"#.utf8)

private actor MockTransport: GitHubTransport {
    let handler: @Sendable (String, [String: String]) throws -> Data
    var variables: [[String: String]] = []
    init(_ handler: @escaping @Sendable (String, [String: String]) throws -> Data) { self.handler = handler }
    func request(query: String, variables: [String: String]) async throws -> Data {
        self.variables.append(variables)
        return try handler(query, variables)
    }
}

@Test func organizationIsAnUnconditionalBoundary() {
    for mode in RepositoryMode.allCases {
        let scope = RepositoryScope(organization: "example-org", mode: mode, includedRepositories: ["app"])
        #expect(!scope.contains(owner: "personal-user", name: "app"))
    }
    #expect(RepositoryScope(organization: "Example-Org").contains(owner: "example-org", name: "anything"))
}

@Test func selectedRepositoriesHaveExplicitEmptyAndExclusionSemantics() {
    let empty = RepositoryScope(organization: "example-org", mode: .selected)
    #expect(empty.isEmptySelection)
    #expect(!empty.contains(owner: "example-org", name: "app"))
    let selection = RepositoryScope(organization: "example-org", mode: .selected,
                                    includedRepositories: ["App", "api"], excludedRepositories: ["API"])
    #expect(selection.contains(owner: "example-org", name: "app"))
    #expect(!selection.contains(owner: "example-org", name: "api"))
    #expect(!selection.contains(owner: "example-org", name: "other"))
    #expect(!selection.isEmptySelection)
}

@Test func individualEditsAndAllModePreserveCustomSelection() throws {
    var selection = RepositoryScope(organization: "example-org", mode: .selected)
    selection.setIncluded(true, repository: "App")
    selection.setIncluded(true, repository: "api")
    selection.setIncluded(false, repository: "APP")
    #expect(!selection.contains(owner: "example-org", name: "app"))
    #expect(selection.contains(owner: "example-org", name: "api"))
    selection.mode = .all
    #expect(selection.contains(owner: "example-org", name: "app"))
    #expect(!selection.contains(owner: "personal-user", name: "api"))
    // All mode must also persist the saved selection for a later switch back.
    selection = try JSONDecoder().decode(RepositoryScope.self, from: JSONEncoder().encode(selection))
    selection.mode = .selected
    #expect(!selection.contains(owner: "example-org", name: "app"))
    #expect(selection.contains(owner: "example-org", name: "api"))
    selection.setIncluded(true, repository: "app")
    #expect(selection.excludedRepositories.isEmpty)
    #expect(selection.contains(owner: "example-org", name: "APP"))
}

@Test func selectingAllAllowsIndividualExceptionsAndNewRepositories() {
    var selection = RepositoryScope(organization: "example-org", mode: .selected)
    selection.setAllIncluded(true)
    selection.setIncluded(false, repository: "legacy")
    #expect(selection.mode == .selected)
    #expect(!selection.contains(owner: "example-org", name: "legacy"))
    #expect(selection.contains(owner: "example-org", name: "new-repo"))
    selection.setAllIncluded(false)
    #expect(selection.isEmptySelection)
    #expect(!selection.contains(owner: "example-org", name: "new-repo"))
}

@Test func checkboxStatesAndLegacyAllEditsFollowVisibleSelection() {
    var scope = RepositoryScope(organization: "example-org", mode: .all, excludedRepositories: ["api"])
    let names = ["app", "api"]
    #expect(scope.selectionState(repositoryNames: names) == .all)
    scope.setIncluded(false, repository: "app")
    #expect(scope.selectionState(repositoryNames: names) == .some)
    #expect(scope.contains(owner: "example-org", name: "api"))
    scope.setIncluded(true, repository: "app")
    #expect(scope.selectionState(repositoryNames: names) == .all)
    scope.setAllIncluded(false)
    #expect(scope.selectionState(repositoryNames: names) == .none)
    #expect(scope.isEmptySelection)
    scope.setIncluded(true, repository: "api")
    #expect(scope.selectionState(repositoryNames: names) == .some)
    #expect(!scope.contains(owner: "example-org", name: "future"))
    scope.setAllIncluded(true)
    #expect(scope.contains(owner: "example-org", name: "future"))
}

@Test func multipleOrganizationsKeepSameNamedRepositoriesAndSeparateSelections() async throws {
    let first = try searchData([fixture(id: "FIRST", requested: ["you"]),
                                fixture(id: "EXCLUDED", repo: "legacy", requested: ["you"])])
    let second = try searchData([fixture(id: "SECOND", owner: "another-org", author: "you"),
                                 fixture(id: "OUTSIDE", owner: "personal-user", author: "you")])
    let empty = try searchData([])
    let transport = MockTransport { query, variables in
        if query.contains("query Identity") { return identity }
        let search = variables["search"] ?? ""
        if search.contains("org:example-org"), search.contains("user-review-requested:") { return first }
        if search.contains("org:another-org"), search.contains("author:") { return second }
        return empty
    }
    let result = try await GitHubService(transport: transport).fetch(scopes: [
        RepositoryScope(organization: "example-org", mode: .selected,
                        excludedRepositories: ["legacy"], includeUnspecifiedRepositories: true),
        RepositoryScope(organization: "another-org", mode: .selected, includedRepositories: ["app"])
    ])
    #expect(Set(result.pullRequests.map(\.id)) == ["FIRST", "SECOND"])
    #expect(Set(result.pullRequests.map(\.repositoryFullName)) == ["example-org/app", "another-org/app"])
    #expect(result.pullRequests.filter { $0.incomingStatus?.needsReview == true }.count == 1)
    #expect(result.pullRequests.filter(\.isAuthored).count == 1)
}

@Test func failedOrganizationDoesNotPublishPartialCounts() async throws {
    let empty = try searchData([])
    let service = GitHubService(transport: MockTransport { query, variables in
        if variables["organization"] == "unavailable-org" { throw ReviewError.organizationUnavailable }
        if query.contains("query Identity") { return identity }
        return empty
    })
    await #expect(throws: ReviewError.organizationUnavailable) {
        try await service.fetch(scopes: [RepositoryScope(organization: "example-org"), RepositoryScope(organization: "unavailable-org")])
    }
    await #expect(throws: ReviewError.invalidOrganization) {
        try await service.fetch(scopes: [RepositoryScope(organization: "example-org"), RepositoryScope(organization: "EXAMPLE-ORG")])
    }
}

@Test func oldMonitoringModesMigrateWithoutChangingTheirScope() throws {
    for (oldMode, appIncluded, otherIncluded) in [("all", true, true), ("include", true, false), ("exclude", false, true)] {
        let saved = try data(["organization": "example-org", "mode": oldMode, "repositories": ["app"]])
        let migrated = try JSONDecoder().decode(RepositoryScope.self, from: saved)
        #expect(migrated.mode == (oldMode == "all" ? .all : .selected))
        #expect(migrated.contains(owner: "example-org", name: "app") == appIncluded)
        #expect(migrated.contains(owner: "example-org", name: "other") == otherIncluded)
        #expect(!migrated.contains(owner: "personal-user", name: "other"))
        #expect(try JSONDecoder().decode(RepositoryScope.self, from: JSONEncoder().encode(migrated)) == migrated)
    }
}

@Test(arguments: ["", "org another:qualifier", "../personal", "org/repo", "-org", "org-", "org\n"])
func organizationRejectsSearchInjection(value: String) {
    #expect(!RepositoryScope(organization: value).isValid)
}

@Test func requestedAgainOverridesOldApproval() throws {
    let pr = try raw(fixture(reviews: [review("you", "APPROVED")], requested: ["you"]))
    let mapped = ReviewClassifier.map(pr, viewer: "you", directlyRequested: true)
    #expect(mapped.incomingStatus == .rereview)
    #expect(mapped.reviewers.first?.status == .rereview)
}

@Test func aCommentDoesNotOverrideAnOpinion() throws {
    for (state, expected) in [("APPROVED", ReviewStatus.approved), ("CHANGES_REQUESTED", .changes)] {
        let pr = try raw(fixture(reviews: [review("you", state), review("you", "COMMENTED", day: 2)]))
        #expect(ReviewClassifier.map(pr, viewer: "you", directlyRequested: false).incomingStatus == expected)
    }
}

@Test func dismissedReviewIsNotAnApproval() throws {
    let pr = try raw(fixture(reviews: [review("you", "APPROVED"), review("you", "DISMISSED", day: 2)]))
    let result = ReviewClassifier.map(pr, viewer: "you", directlyRequested: false)
    #expect(result.incomingStatus == .dismissed)
    #expect(result.outgoingStatus != .approved)
}

@Test func pendingDraftReviewIsNotSubmitted() throws {
    let pr = try raw(fixture(reviews: [review("you", "PENDING")], requested: ["you"]))
    #expect(ReviewClassifier.map(pr, viewer: "you", directlyRequested: true).incomingStatus == .waiting)
}

@Test func oneApprovalDoesNotHideAnotherPendingReviewer() throws {
    let pr = try raw(fixture(author: "you", decision: "APPROVED", reviews: [review("alex", "APPROVED")], requested: ["sam"]))
    let result = ReviewClassifier.map(pr, viewer: "you", directlyRequested: false)
    #expect(result.outgoingStatus == .waiting)
    #expect(result.reviewers.count == 2)
    #expect(result.isAuthored)
}

@Test func changesRequestedTakesPriorityOverWaiting() throws {
    let pr = try raw(fixture(author: "you", reviews: [review("alex", "CHANGES_REQUESTED")], requested: ["sam"]))
    #expect(ReviewClassifier.map(pr, viewer: "you", directlyRequested: false).outgoingStatus == .changes)
}

@Test func githubRequiredDecisionIsNotMistakenForApproval() throws {
    let pr = try raw(fixture(author: "you", decision: "REVIEW_REQUIRED", reviews: [review("alex", "APPROVED")]))
    #expect(ReviewClassifier.map(pr, viewer: "you", directlyRequested: false).outgoingStatus == .required)
}

@Test func botApprovalAloneDoesNotApproveThePullRequest() throws {
    let pr = try raw(fixture(author: "you", reviews: [review("robot", "APPROVED", bot: true)]))
    #expect(ReviewClassifier.map(pr, viewer: "you", directlyRequested: false).outgoingStatus != .approved)
}

@Test func unrequestedAndBotOnlyPRsAreClassifiedAsUnrequested() throws {
    for input in [fixture(author: "you"), fixture(author: "you", reviews: [review("robot", "COMMENTED", bot: true)])] {
        #expect(ReviewClassifier.map(try raw(input), viewer: "you", directlyRequested: false).outgoingStatus == .unrequested)
    }
}

@Test func teamRequestsRemainVisible() throws {
    var object = fixture(author: "you")
    object["reviewRequests"] = ["nodes": [["requestedReviewer": ["__typename": "Team", "slug": "engineers", "name": "Engineers", "organization": ["login": "example-org"]]]], "pageInfo": end]
    let result = ReviewClassifier.map(try raw(object), viewer: "you", directlyRequested: false)
    #expect(result.reviewers.first?.name == "example-org/engineers")
    #expect(result.reviewers.first?.isTeam == true)
    #expect(result.outgoingStatus == .waiting)
}

@Test func servicePaginatesDeduplicatesAndRejectsOutsideOrganization() async throws {
    let first = try searchData([fixture(requested: ["you"])], more: true)
    let second = try searchData([fixture(id: "PR_2", repo: "api", requested: ["you"])])
    let reviewed = try searchData([fixture(requested: ["you"])])
    let own = try searchData([fixture(id: "PRIVATE_PERSONAL", owner: "personal-user", author: "you"), fixture(id: "CLOSED", author: "you", state: "MERGED")])
    let transport = MockTransport { query, variables in
        if query.contains("query Identity") { return identity }
        if variables["search"]?.contains("user-review-requested:") == true { return variables["cursor"] == nil ? first : second }
        if variables["search"]?.contains("reviewed-by:") == true { return reviewed }
        return own
    }
    let result = try await GitHubService(transport: transport).fetch(scope: RepositoryScope(organization: "example-org"))
    #expect(Set(result.pullRequests.map(\.id)) == ["PR_1", "PR_2"])
    #expect(result.pullRequests.allSatisfy { $0.incomingStatus == .waiting })
    let calls = await transport.variables
    #expect(calls.compactMap { $0["search"] }.allSatisfy { $0.contains("org:example-org") && $0.contains("is:open") })
}

@Test func serviceAppliesIncludeAndExclude() async throws {
    let page = try searchData([fixture(repo: "app", requested: ["you"]), fixture(id: "PR_2", repo: "api", requested: ["you"])])
    let empty = try searchData([])
    let transport = MockTransport { query, variables in
        if query.contains("query Identity") { return identity }
        return variables["search"]?.contains("user-review-requested:") == true ? page : empty
    }
    let scopes = [
        RepositoryScope(organization: "example-org", mode: .selected, includedRepositories: ["app"]),
        RepositoryScope(organization: "example-org", mode: .selected, excludedRepositories: ["app"], includeUnspecifiedRepositories: true)
    ]
    for (scope, expected) in zip(scopes, ["app", "api"]) {
        let snapshot = try await GitHubService(transport: transport).fetch(scope: scope)
        #expect(snapshot.pullRequests.map(\.repository) == [expected])
    }
}

@Test func nestedReviewPaginationPreservesLatestReview() async throws {
    let page = try searchData([fixture(reviews: [review("you", "APPROVED")], moreReviews: true)])
    let next = try data(["data": ["node": ["reviews": ["nodes": [review("you", "CHANGES_REQUESTED", day: 2)], "pageInfo": end]]]])
    let empty = try searchData([])
    let transport = MockTransport { query, variables in
        if query.contains("query Identity") { return identity }
        if query.contains("query MoreReviews") { return next }
        return variables["search"]?.contains("reviewed-by:") == true ? page : empty
    }
    let result = try await GitHubService(transport: transport).fetch(scope: RepositoryScope(organization: "example-org"))
    #expect(result.pullRequests.first?.incomingStatus == .changes)
}

@Test func repositoryListingPaginatesAndOmitsArchivedRepositories() async throws {
    let first = try data(["data": ["organization": ["repositories": ["nodes": [["name": "private-app", "isPrivate": true, "isArchived": false]], "pageInfo": ["hasNextPage": true, "endCursor": "repo-next"]]]]])
    let second = try data(["data": ["organization": ["repositories": ["nodes": [["name": "old-app", "isPrivate": true, "isArchived": true], ["name": "api", "isPrivate": false, "isArchived": false]], "pageInfo": end]]]])
    let service = GitHubService(transport: MockTransport { _, variables in variables["cursor"] == nil ? first : second })
    let repos = try await service.repositories(organization: "example-org")
    #expect(repos.map(\.name) == ["api", "private-app"])
    #expect(repos.last?.isPrivate == true)
}

@Test func partialGraphQLErrorsDoNotLookLikeSuccessfulEmptyResults() async {
    let service = GitHubService(transport: MockTransport { _, _ in Data(#"{"data":null,"errors":[{"type":"RATE_LIMITED"}]}"#.utf8) })
    await #expect(throws: ReviewError.rateLimited) { try await service.fetch(scope: RepositoryScope(organization: "example-org")) }
}

@Test func emptySelectionDoesNotFetchPullRequests() async throws {
    let transport = MockTransport { _, _ in identity }
    let result = try await GitHubService(transport: transport).fetch(scope: RepositoryScope(organization: "example-org", mode: .selected))
    #expect(result.pullRequests.isEmpty)
    #expect(await transport.variables.count == 1)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PRCH_LIVE_ORG"] != nil))
func liveGitHubSmokeTest() async throws {
    let organization = try #require(ProcessInfo.processInfo.environment["PRCH_LIVE_ORG"])
    let service = GitHubService()
    let repos = try await service.repositories(organization: organization)
    let result = try await service.fetch(scopes: [RepositoryScope(organization: organization)])
    #expect(!result.login.isEmpty)
    #expect(result.avatarURL?.host == "avatars.githubusercontent.com")
    #expect(result.pullRequests.allSatisfy { $0.url.host == "github.com" })
    print("Live check: \(repos.count) accessible repositories, \(result.pullRequests.filter { $0.incomingStatus != nil && !$0.isAuthored }.count) incoming, \(result.pullRequests.filter(\.isAuthored).count) authored. No PR data saved.")
}
