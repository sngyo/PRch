import Foundation
import Testing
import ReviewCore
@testable import PRch

@MainActor
private final class RefreshTestClock {
    struct Sleep {
        var id: UUID
        var deadline: Date
        var continuation: CheckedContinuation<Void, any Error>?
    }
    var now = Date(timeIntervalSince1970: 1_000)
    var sleeps: [Sleep] = []
    private var observers: [CheckedContinuation<Void, Never>] = []

    var timing: RefreshTiming {
        RefreshTiming(now: { self.now }, sleep: { delay in
            let id = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    self.sleeps.append(Sleep(id: id, deadline: self.now.addingTimeInterval(delay), continuation: continuation))
                    let observers = self.observers
                    self.observers.removeAll()
                    for observer in observers { observer.resume() }
                }
            } onCancel: {
                Task { @MainActor in self.finish(id, error: CancellationError()) }
            }
        })
    }

    func waitForSleep(_ count: Int) async {
        while sleeps.count < count {
            await withCheckedContinuation { observers.append($0) }
        }
    }

    func advance(by seconds: TimeInterval) {
        now.addTimeInterval(seconds)
        for sleep in sleeps where sleep.deadline <= now { finish(sleep.id) }
    }

    private func finish(_ id: UUID, error: (any Error)? = nil) {
        guard let index = sleeps.firstIndex(where: { $0.id == id }),
              let continuation = sleeps[index].continuation else { return }
        sleeps[index].continuation = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
}

private actor ControlledRefreshService: ReviewService {
    private var requests: [CheckedContinuation<ReviewSnapshot, any Error>?] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    var fetchCount: Int { requests.count }

    func fetch(scope: RepositoryScope) async throws -> ReviewSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(continuation)
            let observers = self.observers
            self.observers.removeAll()
            for observer in observers { observer.resume() }
        }
    }

    func waitForFetch(_ count: Int) async {
        while requests.count < count {
            await withCheckedContinuation { observers.append($0) }
        }
    }

    func complete(_ number: Int, error: (any Error)? = nil) {
        let continuation = requests[number - 1]
        requests[number - 1] = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: ReviewSnapshot(login: "you", pullRequests: [])) }
    }

    func repositories(organization: String) async throws -> [Repository] { [] }
}

private func refreshPreferences(_ suite: String) throws -> UserDefaults {
    let preferences = try #require(UserDefaults(suiteName: suite))
    preferences.set(try JSONEncoder().encode([RepositoryScope(organization: "example-org")]), forKey: "scopes")
    return preferences
}

@Test(.timeLimit(.minutes(1))) @MainActor
func pollingRecoversAutomaticallyAndKeepsStaleDataUntilSuccess() async throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let preferences = try refreshPreferences(suite)
    defer { preferences.removePersistentDomain(forName: suite) }
    let service = ControlledRefreshService(), clock = RefreshTestClock()
    let store = AppStore(service: service, preferences: preferences, refreshTiming: clock.timing)
    await service.waitForFetch(1)
    #expect(store.nextRefreshAt == nil)
    await service.complete(1)
    await clock.waitForSleep(1)
    let snapshotDate = try #require(store.snapshot?.fetchedAt)
    #expect(store.nextRefreshAt == clock.now.addingTimeInterval(120))

    clock.advance(by: 120)
    await service.waitForFetch(2)
    await service.complete(2, error: ReviewError.network)
    await clock.waitForSleep(2)
    #expect(store.failure == .network)
    #expect(store.hasStaleData)
    #expect(store.snapshot?.fetchedAt == snapshotDate)
    #expect(store.nextRefreshAt == clock.now.addingTimeInterval(10))

    clock.advance(by: 10)
    await service.waitForFetch(3)
    #expect(store.isRefreshing)
    #expect(store.hasStaleData)
    #expect(store.nextRefreshAt == nil)
    await service.complete(3)
    await clock.waitForSleep(3)
    #expect(store.failure == nil)
    #expect(!store.hasStaleData)
    #expect(!store.isRefreshing)
    #expect(store.nextRefreshAt == clock.now.addingTimeInterval(120))
}

@Test(.timeLimit(.minutes(1)), arguments: [ReviewError.network, .timedOut]) @MainActor
func transientFailuresRetryWithinOneMinute(failure: ReviewError) async throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let preferences = try refreshPreferences(suite)
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set(300, forKey: "refreshInterval")
    let service = ControlledRefreshService(), clock = RefreshTestClock()
    let store = AppStore(service: service, preferences: preferences, refreshTiming: clock.timing)
    for (index, delay) in [10.0, 20, 40, 60, 60].enumerated() {
        await service.waitForFetch(index + 1)
        await service.complete(index + 1, error: failure)
        await clock.waitForSleep(index + 1)
        #expect(store.nextRefreshAt == clock.now.addingTimeInterval(delay))
        clock.advance(by: delay)
    }
    await service.waitForFetch(6)
    await service.complete(6)
    await clock.waitForSleep(6)
    #expect(store.nextRefreshAt == clock.now.addingTimeInterval(300))
    clock.advance(by: 300)
    await service.waitForFetch(7)
    await service.complete(7, error: failure)
    await clock.waitForSleep(7)
    #expect(store.nextRefreshAt == clock.now.addingTimeInterval(10))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func manualRefreshReplacesLongBackoffWithNormalPolling() async throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let preferences = try refreshPreferences(suite)
    defer { preferences.removePersistentDomain(forName: suite) }
    let service = ControlledRefreshService(), clock = RefreshTestClock()
    let store = AppStore(service: service, preferences: preferences, refreshTiming: clock.timing)
    for (index, delay) in [240.0, 480, 960, 1_800].enumerated() {
        await service.waitForFetch(index + 1)
        await service.complete(index + 1, error: ReviewError.rateLimited)
        await clock.waitForSleep(index + 1)
        #expect(store.nextRefreshAt == clock.now.addingTimeInterval(delay))
        if index < 3 { clock.advance(by: delay) }
    }
    store.refresh()
    #expect(store.nextRefreshAt == nil)
    await service.waitForFetch(5)
    await service.complete(5)
    await clock.waitForSleep(5)
    #expect(store.nextRefreshAt == clock.now.addingTimeInterval(120))
    clock.advance(by: 120)
    await service.waitForFetch(6)
    clock.advance(by: 1_680) // The old backoff expires while a request is running.
    #expect(await service.fetchCount == 6)
    await service.complete(6)
    await clock.waitForSleep(6)
    #expect(store.failure == nil)
    #expect(store.nextRefreshAt == clock.now.addingTimeInterval(120))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func pollingWaitsForCompletionAndReschedulesIntervalChanges() async throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let preferences = try refreshPreferences(suite)
    defer { preferences.removePersistentDomain(forName: suite) }
    let service = ControlledRefreshService(), clock = RefreshTestClock()
    let store = AppStore(service: service, preferences: preferences, refreshTiming: clock.timing)
    await service.waitForFetch(1)
    store.refreshInterval = 300
    clock.advance(by: 600)
    #expect(store.nextRefreshAt == nil)
    #expect(clock.sleeps.isEmpty)
    #expect(await service.fetchCount == 1)
    await service.complete(1)
    await clock.waitForSleep(1)
    #expect(store.nextRefreshAt == clock.now.addingTimeInterval(300))
    store.refreshInterval = 60
    await clock.waitForSleep(2)
    #expect(store.nextRefreshAt == clock.now.addingTimeInterval(60))
    clock.advance(by: 60)
    await service.waitForFetch(2)
    await service.complete(2)
    await clock.waitForSleep(3)
    #expect(store.nextRefreshAt == clock.now.addingTimeInterval(60))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func supersededAndUnexpectedCancellationDoNotStopPolling() async throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let preferences = try refreshPreferences(suite)
    defer { preferences.removePersistentDomain(forName: suite) }
    let service = ControlledRefreshService(), clock = RefreshTestClock()
    let store = AppStore(service: service, preferences: preferences, refreshTiming: clock.timing)
    await service.waitForFetch(1)
    store.refresh()
    await service.waitForFetch(2)
    await service.complete(1, error: ReviewError.authentication)
    await service.complete(2, error: CancellationError())
    await clock.waitForSleep(1)
    #expect(!store.isRefreshing)
    #expect(store.failure == .api)
    #expect(store.nextRefreshAt == clock.now.addingTimeInterval(240))
    clock.advance(by: 240)
    await service.waitForFetch(3)
    await service.complete(3)
    await clock.waitForSleep(2)
    #expect(store.failure == nil)
    #expect(store.nextRefreshAt == clock.now.addingTimeInterval(120))
}
