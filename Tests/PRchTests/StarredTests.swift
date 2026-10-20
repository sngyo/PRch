import Foundation
import Testing
import ReviewCore
@testable import PRch

@Test @MainActor func starsLeaveReviewCountsActivityAndSnapshotsUnchanged() throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let store = AppStore(isDemo: true, preferences: preferences, startsPolling: false, demoActivity: true)
    let incoming = try #require(store.activeIncoming.first { store.activity(for: $0) != nil })
    let outgoing = try #require(store.activeOutgoing.first { $0.outgoingStatus == .changes })
    let image = MenuBarImageState(store: store, scale: 2)
    let summary = store.menuBarSummary
    let snapshot = try #require(store.snapshot)
    let incomingIDs = store.activeIncoming.map(\.id)
    let outgoingIDs = store.activeOutgoing.map(\.id)
    let receipts = store.activityReceipts(incoming: true).union(store.activityReceipts(incoming: false))

    #expect(!store.isStarred(incoming))
    store.setStarred(true, for: incoming)
    store.setStarred(true, for: outgoing)
    store.setStarred(true, for: incoming)
    #expect(store.isStarred(incoming) && store.isStarred(outgoing))
    #expect(store.activeIncoming.map(\.id) == incomingIDs)
    #expect(store.activeOutgoing.map(\.id) == outgoingIDs)
    #expect(MenuBarImageState(store: store, scale: 2) == image)
    #expect(store.menuBarSummary == summary)
    #expect(store.snapshot?.pullRequests == snapshot.pullRequests)
    #expect(store.snapshot?.fetchedAt == snapshot.fetchedAt)
    #expect(store.activityReceipts(incoming: true).union(store.activityReceipts(incoming: false)) == receipts)
    #expect(preferences.dictionary(forKey: "starredPRIDsByAccount") as? [String: [String]] ==
            ["you": [incoming.id, outgoing.id].sorted()])

    store.setStarred(false, for: incoming)
    #expect(!store.isStarred(incoming))
    #expect(store.isStarred(outgoing))
    #expect(MenuBarImageState(store: store, scale: 2) == image)
    #expect(store.activityReceipts(incoming: true).union(store.activityReceipts(incoming: false)) == receipts)
}

@Test @MainActor func starsPersistAcrossRefreshRestartAndScopeChanges() throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let store = AppStore(isDemo: true, preferences: preferences, startsPolling: false)
    let incoming = try #require(store.activeIncoming.first { $0.repository == "sample-web" })
    let outgoing = try #require(store.activeOutgoing.first { $0.repository == "sample-api" })
    store.setStarred(true, for: incoming)
    store.setStarred(true, for: outgoing)
    store.refresh()
    #expect(store.activeIncoming.filter { store.isStarred($0) }.map(\.id) == [incoming.id])
    #expect(store.activeOutgoing.filter { store.isStarred($0) }.map(\.id) == [outgoing.id])

    store.save(RepositoryScope(organization: "example-org", mode: .selected, includedRepositories: ["sample-docs"]))
    #expect(store.activeIncoming.filter { store.isStarred($0) }.isEmpty)
    #expect(store.activeOutgoing.filter { store.isStarred($0) }.isEmpty)
    store.save(RepositoryScope(organization: "example-org"))
    #expect(store.activeIncoming.filter { store.isStarred($0) }.map(\.id) == [incoming.id])
    #expect(store.activeOutgoing.filter { store.isStarred($0) }.map(\.id) == [outgoing.id])

    let restarted = AppStore(isDemo: true, preferences: preferences, startsPolling: false)
    #expect(restarted.isStarred(incoming) && restarted.isStarred(outgoing))
    restarted.setStarred(false, for: outgoing)
    let again = AppStore(isDemo: true, preferences: preferences, startsPolling: false)
    #expect(again.isStarred(incoming))
    #expect(!again.isStarred(outgoing))
}

@Test @MainActor func pendingKeepsStarsWithoutReturningPRsToActiveLists() throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let store = AppStore(isDemo: true, preferences: preferences, startsPolling: false)
    let incoming = try #require(store.activeIncoming.first { $0.incomingStatus?.needsReview == true })
    let outgoing = try #require(store.activeOutgoing.first { $0.outgoingStatus == .changes })
    let image = MenuBarImageState(store: store, scale: 2)
    store.setStarred(true, for: incoming)
    store.setPending(true, for: incoming)
    store.setPending(true, for: outgoing)
    let pendingImage = MenuBarImageState(store: store, scale: 2)
    store.setStarred(true, for: outgoing) // Starring a Pending PR keeps it deferred.
    #expect(MenuBarImageState(store: store, scale: 2) == pendingImage)
    #expect(store.activeIncoming.filter { store.isStarred($0) }.isEmpty)
    #expect(store.activeOutgoing.filter { store.isStarred($0) }.isEmpty)
    #expect(store.pendingIncoming.map(\.id) == [incoming.id])
    #expect(store.pendingOutgoing.map(\.id) == [outgoing.id])

    let restarted = AppStore(isDemo: true, preferences: preferences, startsPolling: false)
    #expect(restarted.isStarred(incoming) && restarted.isStarred(outgoing))
    #expect(restarted.isPending(incoming) && restarted.isPending(outgoing))
    restarted.setPending(false, for: incoming)
    restarted.setPending(false, for: outgoing)
    #expect(restarted.activeIncoming.filter { restarted.isStarred($0) }.map(\.id) == [incoming.id])
    #expect(restarted.activeOutgoing.filter { restarted.isStarred($0) }.map(\.id) == [outgoing.id])
    #expect(MenuBarImageState(store: restarted, scale: 2) == image)
    restarted.setPending(true, for: incoming)
    restarted.setStarred(false, for: incoming)
    #expect(restarted.isPending(incoming))
}

private actor StarredService: ReviewService {
    var snapshot = DemoData.snapshot
    var failure: ReviewError?
    func update(login: String, prs: [PullRequest], failure: ReviewError? = nil) {
        snapshot = ReviewSnapshot(login: login, pullRequests: prs)
        self.failure = failure
    }
    func fetch(scope: RepositoryScope) async throws -> ReviewSnapshot {
        if let failure { throw failure }
        return snapshot
    }
    func repositories(organization: String) async throws -> [Repository] { [] }
}

@Test @MainActor func starsFollowAccountAndPRIdentityAndOnlyShowCurrentPRs() async throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let service = StarredService()
    let store = AppStore(service: service, preferences: preferences, startsPolling: false)
    let pr = try #require(DemoData.snapshot.pullRequests.first)
    store.setStarred(true, for: pr) // No loaded account yet.
    #expect(preferences.dictionary(forKey: "starredPRIDsByAccount") == nil)
    store.save(RepositoryScope(organization: "example-org"))
    for await refreshing in store.$isRefreshing.values { if !refreshing { break } }
    store.setStarred(true, for: pr)
    var other = pr
    other.id = "different-node-id"
    other.repositoryOwner = "another-org"
    #expect(!store.isStarred(other)) // A matching PR number is not enough.
    store.setStarred(true, for: other) // Ignore a stale or unknown PR.
    #expect(!store.isStarred(other))

    await service.update(login: "another-user", prs: [pr])
    store.refresh()
    for await refreshing in store.$isRefreshing.values { if !refreshing { break } }
    #expect(!store.isStarred(pr))
    store.setStarred(true, for: pr)
    store.setStarred(false, for: pr)
    await service.update(login: "YOU", prs: [pr])
    store.refresh()
    for await refreshing in store.$isRefreshing.values { if !refreshing { break } }
    #expect(store.isStarred(pr))

    await service.update(login: "you", prs: [], failure: .network)
    store.refresh()
    for await refreshing in store.$isRefreshing.values { if !refreshing { break } }
    #expect(store.hasStaleData)
    #expect(store.activeIncoming.filter { store.isStarred($0) }.map(\.id) == [pr.id])
    await service.update(login: "you", prs: []) // Closed/merged PRs leave the fetched list.
    store.refresh()
    for await refreshing in store.$isRefreshing.values { if !refreshing { break } }
    #expect(store.activeIncoming.filter { store.isStarred($0) }.isEmpty)
    await service.update(login: "you", prs: [pr]) // Reopening retains the local marker.
    store.refresh()
    for await refreshing in store.$isRefreshing.values { if !refreshing { break } }
    #expect(store.activeIncoming.filter { store.isStarred($0) }.map(\.id) == [pr.id])
    store.save(RepositoryScope(organization: "another-org"))
    #expect(store.snapshot == nil)
    #expect(!store.isStarred(pr))
}
