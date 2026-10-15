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
