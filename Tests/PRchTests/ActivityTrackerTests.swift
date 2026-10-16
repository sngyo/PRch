import Foundation
import Testing
import ReviewCore
@testable import PRch

private let activityScopes = [RepositoryScope(organization: "example-org")]
private func activityPR(_ id: String, own: Bool = false, status: ReviewStatus = .waiting) -> PullRequest {
    PullRequest(id: id, number: 1, title: "Example change", url: URL(string: "https://github.com/example-org/sample/pull/1")!,
                repository: "sample", author: own ? "you" : "alex", updatedAt: Date(),
                reviewers: [Reviewer(name: "alex", status: status)], incomingStatus: own ? nil : status,
                outgoingStatus: status, isAuthored: own)
}
private func ingest(_ prs: [PullRequest], into tracker: inout ActivityTracker, login: String = "you", pending: Set<String> = []) {
    tracker.ingest(ReviewSnapshot(login: login, pullRequests: prs), scopes: activityScopes, pendingIDs: pending)
}

@Test func activityBaselinesFirstFetchThenFindsNewPRDespiteUnchangedTotal() throws {
    var tracker = ActivityTracker()
    ingest([activityPR("old")], into: &tracker)
    #expect(tracker.activity(for: "old", account: "you") == nil)
    ingest([activityPR("replacement")], into: &tracker)
    #expect(tracker.activity(for: "replacement", account: "you")?.kind == .new)
    let before = try #require(tracker.activity(for: "replacement", account: "you"))
    ingest([activityPR("replacement")], into: &tracker)
    #expect(tracker.activity(for: "replacement", account: "you") == before)
    // Newly discovered reviewed-only incoming PRs do not look like new requests.
    ingest([activityPR("reviewed", status: .approved)], into: &tracker)
    #expect(tracker.activity(for: "reviewed", account: "you") == nil)
}

@Test func activityIgnoresMetadataAndBotsButDetectsHumanReviewChanges() throws {
    var tracker = ActivityTracker()
    ingest([], into: &tracker)
    var pr = activityPR("own", own: true)
    pr.reviewers.append(Reviewer(name: "sam", status: .waiting))
    ingest([pr], into: &tracker)
    #expect(tracker.activity(for: pr.id, account: "you") == nil)
    pr.title = "Edited title"
    pr.updatedAt = .now.addingTimeInterval(60)
    pr.checkState = "FAILURE"
    pr.isDraft = true
    pr.reviewers.reverse()
    pr.reviewers.append(Reviewer(name: "example-bot", status: .approved, isBot: true))
    ingest([pr], into: &tracker)
    #expect(tracker.activity(for: pr.id, account: "you") == nil)
    pr.reviewers[0].status = .approved
    ingest([pr], into: &tracker)
    #expect(pr.outgoingStatus == .waiting)
    #expect(tracker.activity(for: pr.id, account: "you")?.kind == .updated)
}

@Test(arguments: [false, true])
func activityClearsLegacyOwnNewMarkersWhilePreservingReviewActivity(reviewChanged: Bool) throws {
    var own = activityPR("own", own: true)
    let incoming = activityPR("incoming"), updated = activityPR("updated", own: true)
    let newActivity = PRActivity(kind: .new), updatedActivity = PRActivity(kind: .updated)
    let account = ActivityTracker.Account(scopeDigest: ActivityTracker.scopeDigest(activityScopes), records: [
        own.id: .init(fingerprint: ActivityTracker.fingerprint(own), activity: newActivity),
        incoming.id: .init(fingerprint: ActivityTracker.fingerprint(incoming), activity: newActivity),
        updated.id: .init(fingerprint: ActivityTracker.fingerprint(updated), activity: updatedActivity)
    ])
    let saved = try JSONEncoder().encode(["accounts": ["you": account]])
    var tracker = try JSONDecoder().decode(ActivityTracker.self, from: saved)
    if reviewChanged { own.reviewers[0].status = .approved }
    ingest([own, incoming, updated], into: &tracker)
    #expect(tracker.activity(for: own.id, account: "you")?.kind == (reviewChanged ? .updated : nil))
    #expect(tracker.activity(for: incoming.id, account: "you") == newActivity)
    #expect(tracker.activity(for: updated.id, account: "you") == updatedActivity)
    let restored = try JSONDecoder().decode(ActivityTracker.self, from: JSONEncoder().encode(tracker))
    #expect(restored.activity(for: own.id, account: "you") == tracker.activity(for: own.id, account: "you"))
}

@Test func activityAcknowledgesOnlySeenRevisionAndAccount() throws {
    var tracker = ActivityTracker()
    var pr = activityPR("request", status: .approved)
    ingest([pr], into: &tracker)
    pr.incomingStatus = .rereview
    ingest([pr], into: &tracker)
    let first = try #require(tracker.activity(for: pr.id, account: "you"))
    #expect(first.kind == .updated)
    let receipt = ActivityReceipt(account: "YOU", prID: pr.id, revision: first.revision)
    pr.incomingStatus = .changes
    ingest([pr], into: &tracker)
    tracker.acknowledge([receipt])
    let second = try #require(tracker.activity(for: pr.id, account: "you"))
    #expect(second.revision != first.revision)
    tracker.acknowledge([ActivityReceipt(account: "someone-else", prID: pr.id, revision: second.revision)])
    #expect(tracker.activity(for: pr.id, account: "you") != nil)
    tracker.acknowledge([ActivityReceipt(account: "you", prID: pr.id, revision: second.revision)])
    #expect(tracker.activity(for: pr.id, account: "you") == nil)
}

@Test func activityScopeChangesAndPendingDoNotFloodNotifications() throws {
    var tracker = ActivityTracker()
    ingest([], into: &tracker)
    let pr = activityPR("new")
    ingest([pr], into: &tracker)
    let original = try #require(tracker.activity(for: pr.id, account: "you"))
    let expanded = activityScopes + [RepositoryScope(organization: "another-org")]
    tracker.ingest(ReviewSnapshot(login: "you", pullRequests: [pr, activityPR("existing-in-new-scope")]), scopes: expanded, pendingIDs: [])
    #expect(tracker.activity(for: "existing-in-new-scope", account: "you") == nil)
    #expect(tracker.activity(for: pr.id, account: "you") == original)
    tracker.ingest(ReviewSnapshot(login: "you", pullRequests: [pr]), scopes: expanded, pendingIDs: [pr.id])
    #expect(tracker.activity(for: pr.id, account: "you") == nil)
    var changed = pr
    changed.incomingStatus = .rereview
    tracker.ingest(ReviewSnapshot(login: "you", pullRequests: [changed]), scopes: expanded, pendingIDs: [pr.id])
    tracker.ingest(ReviewSnapshot(login: "you", pullRequests: [changed]), scopes: expanded, pendingIDs: [])
    #expect(tracker.activity(for: pr.id, account: "you") == nil)
    ingest([pr], into: &tracker, login: "another-user")
    #expect(tracker.activity(for: pr.id, account: "another-user") == nil)
}

@Test func activitySurvivesSerializationWithoutStoringPRContent() throws {
    var tracker = ActivityTracker()
    ingest([], into: &tracker)
    let pr = activityPR("opaque-id")
    ingest([pr], into: &tracker)
    #expect(tracker.activity(for: pr.id, account: "you")?.kind == .new)
    let data = try JSONEncoder().encode(tracker)
    let text = try #require(String(data: data, encoding: .utf8))
    for content in [pr.title, pr.url.absoluteString, pr.repository, "alex"] { #expect(!text.contains(content)) }
    let restored = try JSONDecoder().decode(ActivityTracker.self, from: data)
    #expect(restored.activity(for: pr.id, account: "you") == tracker.activity(for: pr.id, account: "you"))
}

private actor ActivityService: ReviewService {
    var prs: [PullRequest] = []
    var failure = false
    func update(_ prs: [PullRequest], failure: Bool = false) { self.prs = prs; self.failure = failure }
    func fetch(scope: RepositoryScope) async throws -> ReviewSnapshot {
        if failure { throw ReviewError.network }
        return ReviewSnapshot(login: "you", pullRequests: prs)
    }
    func repositories(organization: String) async throws -> [Repository] { [] }
}

@Test @MainActor func storePersistsUnseenActivityAndKeepsPendingAndFailedRefreshQuiet() async throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let service = ActivityService()
    let store = AppStore(service: service, preferences: preferences, startsPolling: false)
    store.save(activityScopes)
    for await refreshing in store.$isRefreshing.values { if !refreshing { break } }
    let incoming = activityPR("incoming")
    var own = activityPR("own", own: true)
    await service.update([incoming, own])
    store.refresh()
    for await refreshing in store.$isRefreshing.values { if !refreshing { break } }
    #expect(store.unreadActivityCount == 1)
    #expect(store.activity(for: own) == nil)
    #expect(store.activityReceipt(for: own) == nil)
    own.outgoingStatus = .changes
    own.reviewers[0].status = .changes
    await service.update([incoming, own])
    store.refresh()
    for await refreshing in store.$isRefreshing.values { if !refreshing { break } }
    #expect(store.unreadActivityCount == 2)
    let receipt = try #require(store.activityReceipt(for: incoming))
    store.activityIndicatorStyle = .count
    let restarted = AppStore(service: service, preferences: preferences, startsPolling: false)
    restarted.refresh()
    for await refreshing in restarted.$isRefreshing.values { if !refreshing { break } }
    #expect(restarted.unreadActivityCount == 2)
    #expect(restarted.activityIndicatorStyle == .count)
    restarted.acknowledgeActivity([receipt])
    #expect(restarted.unreadActivityCount == 1)
    #expect(restarted.activity(for: own)?.kind == .updated)
    await service.update([], failure: true)
    restarted.refresh()
    for await refreshing in restarted.$isRefreshing.values { if !refreshing { break } }
    #expect(restarted.unreadActivityCount == 1)
    restarted.setPending(true, for: own)
    #expect(restarted.unreadActivityCount == 0)
    #expect(restarted.changesRequestedCount == 0)
    restarted.setPending(false, for: own)
    #expect(restarted.unreadActivityCount == 0)
    #expect(restarted.changesRequestedCount == 1)
    await service.update([])
    restarted.refresh()
    for await refreshing in restarted.$isRefreshing.values { if !refreshing { break } }
    #expect(restarted.unreadActivityCount == 0)
}
