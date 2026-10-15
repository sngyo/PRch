import Foundation
import Testing
import ReviewCore
@testable import PRch

private struct StubService: ReviewService {
    func fetch(scope: RepositoryScope) async throws -> ReviewSnapshot { ReviewSnapshot(login: "you", pullRequests: []) }
    func repositories(organization: String) async throws -> [Repository] { [] }
}

@Test @MainActor func initializationUsesValidPreferencesDomain() {
    // Exercise the production (standard UserDefaults) initializer, without network/polling.
    let store = AppStore(service: StubService(), startsPolling: false)
    #expect(!store.isRefreshing)
}

@Test @MainActor func repositorySelectionSurvivesRestart() throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let first = AppStore(service: StubService(), preferences: preferences, startsPolling: false)
    let selection = RepositoryScope(organization: "example-org", mode: .selected, excludedRepositories: ["legacy"], includeUnspecifiedRepositories: true)
    first.save(selection)
    let restarted = AppStore(service: StubService(), preferences: preferences, startsPolling: false)
    #expect(restarted.scope == selection)
    #expect(!restarted.showSettings)
}

@Test @MainActor func demoDoesNotOverwriteRealScope() throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let real = RepositoryScope(organization: "real-example", mode: .selected, includedRepositories: ["selected"])
    preferences.set(try JSONEncoder().encode(real), forKey: "scope")
    let demo = AppStore(service: StubService(), isDemo: true, preferences: preferences)
    demo.save(RepositoryScope(organization: "example-org", mode: .selected, includedRepositories: ["sample-web"]))
    let restarted = AppStore(service: StubService(), preferences: preferences, startsPolling: false)
    #expect(restarted.scope == real)
    #expect(demo.snapshot?.pullRequests.isEmpty == false)
    #expect(demo.snapshot?.pullRequests.allSatisfy { $0.repository == "sample-web" } == true)
}

@Test @MainActor func menuBarPreferenceDefaultsAndSurvivesRestart() throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let store = AppStore(service: StubService(), preferences: preferences, startsPolling: false)
    #expect(store.menuBarStyle == .separateCounts)
    store.menuBarStyle = .dot
    let restarted = AppStore(service: StubService(), preferences: preferences, startsPolling: false)
    #expect(restarted.menuBarStyle == .dot)
    preferences.set("unknown-style", forKey: "menuBarStyle")
    let recovered = AppStore(service: StubService(), preferences: preferences, startsPolling: false)
    #expect(recovered.menuBarStyle == .separateCounts)
}

@Test @MainActor func legacyScopeMigratesToIndependentOrganizations() throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let legacy = RepositoryScope(organization: "example-org", mode: .selected,
                                 excludedRepositories: ["app"], includeUnspecifiedRepositories: true)
    preferences.set(try JSONEncoder().encode(legacy), forKey: "scope")
    let store = AppStore(service: StubService(), preferences: preferences, startsPolling: false)
    #expect(store.scopes == [legacy])
    let other = RepositoryScope(organization: "another-org", mode: .selected, includedRepositories: ["app"])
    store.save([legacy, other])
    let restarted = AppStore(service: StubService(), preferences: preferences, startsPolling: false)
    #expect(restarted.scopes == [legacy, other])
    #expect(!restarted.scopes[0].contains(owner: "example-org", name: "app"))
    #expect(restarted.scopes[1].contains(owner: "another-org", name: "app"))
    restarted.save([other])
    #expect(AppStore(service: StubService(), preferences: preferences, startsPolling: false).scopes == [other])
}

@Test @MainActor func pendingExcludesBothTabsFromCountsAndCanBeRestored() throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let store = AppStore(isDemo: true, preferences: preferences, startsPolling: false)
    let pr = try #require(store.outgoing.first { $0.outgoingStatus == .changes })
    let incomingCount = store.pendingCount
    let outgoingCount = store.outgoing.count
    #expect(store.changesRequestedCount == 1)
    store.setPending(true, for: pr)
    store.setPending(true, for: pr)
    #expect(store.pendingOutgoing.map(\.id) == [pr.id])
    #expect(store.activeOutgoing.count == outgoingCount - 1)
    #expect(store.changesRequestedCount == 0)
    #expect(store.pendingCount == incomingCount)
    #expect(store.outgoing.first { $0.id == pr.id }?.outgoingStatus == .changes)
    let incoming = try #require(store.incoming.first)
    store.setPending(true, for: incoming)
    #expect(store.isPending(incoming))
    #expect(store.pendingIncoming.map(\.id) == [incoming.id])
    #expect(store.activeIncoming.count == store.incoming.count - 1)
    #expect(store.pendingCount == incomingCount - 1)
    #expect(store.pendingOutgoing.count == 1)
    store.setPending(false, for: incoming)
    #expect(store.pendingCount == incomingCount)
    #expect(store.pendingIncoming.isEmpty)
    store.setPending(false, for: pr)
    #expect(store.pendingOutgoing.isEmpty)
    #expect(store.activeOutgoing.count == outgoingCount)
    #expect(store.changesRequestedCount == 1)
}

@Test @MainActor func pendingPersistsAcrossRefreshRestartAndRepositorySelection() throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let store = AppStore(isDemo: true, preferences: preferences, startsPolling: false)
    let pr = try #require(store.outgoing.first)
    store.setPending(true, for: pr)
    let incoming = try #require(store.incoming.first)
    store.setPending(true, for: incoming)
    store.refresh()
    #expect(store.isPending(pr))
    store.save(RepositoryScope(organization: "example-org", mode: .selected, includedRepositories: ["sample-api"]))
    #expect(store.pendingOutgoing.isEmpty)
    store.save(RepositoryScope(organization: "example-org"))
    #expect(store.pendingOutgoing.map(\.id) == [pr.id])
    let restarted = AppStore(isDemo: true, preferences: preferences, startsPolling: false)
    #expect(restarted.pendingOutgoing.map(\.id) == [pr.id])
    #expect(restarted.pendingIncoming.map(\.id) == [incoming.id])
    restarted.setPending(false, for: pr)
    #expect(AppStore(isDemo: true, preferences: preferences, startsPolling: false).pendingOutgoing.isEmpty)
}

private actor PendingService: ReviewService {
    var snapshot = DemoData.snapshot
    func update(login: String, prs: [PullRequest]) { snapshot = ReviewSnapshot(login: login, pullRequests: prs) }
    func fetch(scope: RepositoryScope) async throws -> ReviewSnapshot { snapshot }
    func repositories(organization: String) async throws -> [Repository] { [] }
}

@Test @MainActor func pendingIsAccountScopedAndUsesPRIdentity() async throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let service = PendingService()
    let store = AppStore(service: service, preferences: preferences, startsPolling: false)
    store.save(RepositoryScope(organization: "example-org"))
    for await refreshing in store.$isRefreshing.values { if !refreshing { break } }
    let pr = try #require(store.outgoing.first)
    store.setPending(true, for: pr)
    var other = pr
    other.id = "another-pr-id"
    other.repositoryOwner = "another-org"
    #expect(!store.isPending(other)) // Same PR number, different node ID.
    await service.update(login: "another-user", prs: [pr])
    store.refresh()
    for await refreshing in store.$isRefreshing.values { if !refreshing { break } }
    #expect(!store.isPending(pr))
    await service.update(login: "YOU", prs: [pr])
    store.refresh()
    for await refreshing in store.$isRefreshing.values { if !refreshing { break } }
    #expect(store.isPending(pr))
    // A newer review state does not silently restore the user's deferred PR.
    var updated = pr
    updated.outgoingStatus = .changes
    await service.update(login: "you", prs: [updated])
    store.refresh()
    for await refreshing in store.$isRefreshing.values { if !refreshing { break } }
    #expect(store.pendingOutgoing.map(\.id) == [pr.id])
    #expect(store.changesRequestedCount == 0)
    await service.update(login: "you", prs: []) // Closed/merged PR is absent.
    store.refresh()
    for await refreshing in store.$isRefreshing.values { if !refreshing { break } }
    #expect(store.pendingOutgoing.isEmpty)
    #expect(store.activeOutgoing.isEmpty)
}
