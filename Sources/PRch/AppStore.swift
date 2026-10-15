import AppKit
import Combine
import Foundation
import ReviewCore

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var scopes: [RepositoryScope]
    var scope: RepositoryScope { scopes.first ?? RepositoryScope() }
    @Published private(set) var snapshot: ReviewSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var failure: ReviewError?
    var error: String? { failure.map(l10n.error) }
    var l10n: L10n { L10n(language: language) }
    struct RepositoryListState {
        var repositories: [Repository] = []
        var isLoading = false
        var error: ReviewError?
    }
    @Published private(set) var repositoryLists: [String: RepositoryListState] = [:]
    @Published var showSettings = false
    @Published var language = AppLanguage.system { didSet { defaults.set(language.rawValue, forKey: "language") } }
    @Published var defaultIncoming = "pending" { didSet { defaults.set(defaultIncoming, forKey: "defaultIncoming") } }
    @Published var showCI = true { didSet { defaults.set(showCI, forKey: "showCI") } }
    @Published var menuBarStyle = MenuBarStyle.separateCounts { didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") } }
    @Published var refreshInterval = 120 { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    let isDemo: Bool
    private let defaults: UserDefaults
    private let service: any ReviewService
    private var refreshTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var repositoryTasks: [String: Task<Void, Never>] = [:]
    private var refreshID = UUID()
    private var repositoryRequestIDs: [String: UUID] = [:]
    private var failureCount = 0

    init(service: any ReviewService = GitHubService(), isDemo: Bool = false, preferences: UserDefaults? = nil, startsPolling: Bool = true) {
        self.service = service
        self.isDemo = isDemo
        // A suite named after the running bundle can return nil. Use the application's
        // standard domain; a separate suite is only needed for synthetic demo data.
        defaults = preferences ?? (isDemo ? UserDefaults(suiteName: "dev.prch.demo") ?? .standard : .standard)
        if let saved = defaults.data(forKey: "scopes").flatMap({ try? JSONDecoder().decode([RepositoryScope].self, from: $0) }) {
            scopes = saved
        } else if let legacy = defaults.data(forKey: "scope").flatMap({ try? JSONDecoder().decode(RepositoryScope.self, from: $0) }), legacy.isValid {
            scopes = [legacy]
        } else {
            scopes = []
        }
        language = defaults.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) ?? .system
        defaultIncoming = defaults.string(forKey: "defaultIncoming") ?? "pending"
        showCI = defaults.object(forKey: "showCI") as? Bool ?? true
        menuBarStyle = defaults.string(forKey: "menuBarStyle").flatMap(MenuBarStyle.init(rawValue:)) ?? .separateCounts
        refreshInterval = max(60, defaults.integer(forKey: "refreshInterval") == 0 ? 120 : defaults.integer(forKey: "refreshInterval"))
        if isDemo {
            scopes = [RepositoryScope(organization: "example-org")]
            snapshot = DemoData.snapshot
        } else {
            showSettings = !scope.isValid
            if startsPolling { startPolling() }
        }
    }

    var incoming: [PullRequest] { snapshot?.pullRequests.filter { $0.incomingStatus != nil && !$0.isAuthored } ?? [] }
    var outgoing: [PullRequest] { snapshot?.pullRequests.filter { $0.isAuthored } ?? [] }
    var pendingCount: Int { incoming.filter { $0.incomingStatus?.needsReview == true }.count }
    var changesRequestedCount: Int { outgoing.filter { $0.outgoingStatus == .changes }.count }
    var menuBarSummary: String {
        if let error { return l10n.text("common.appMessage", error) }
        guard snapshot != nil else { return l10n.text("common.appMessage", l10n.text(isRefreshing ? "connection.loading" : "connection.disconnected")) }
        return l10n.text("menu.summary", pendingCount, changesRequestedCount, scopes.map(\.organization).joined(separator: ", "))
    }
    var hasStaleData: Bool { error != nil && snapshot != nil }

    func save(_ newScope: RepositoryScope) { save([newScope]) }

    func save(_ newScopes: [RepositoryScope]) {
        guard !newScopes.isEmpty, newScopes.allSatisfy(\.isValid),
              Set(newScopes.map { $0.organization.lowercased() }).count == newScopes.count else { return }
        let changed = newScopes != scopes
        scopes = newScopes
        if !isDemo, let data = try? JSONEncoder().encode(newScopes) { defaults.set(data, forKey: "scopes") }
        if changed {
            snapshot = nil
            failureCount = 0
        }
        showSettings = false
        refresh()
    }

    func refresh() {
        guard !isDemo else {
            snapshot = ReviewSnapshot(login: "you", pullRequests: DemoData.snapshot.pullRequests.filter {
                pr in scopes.contains { $0.contains(owner: pr.repositoryOwner, name: pr.repository) }
            })
            return
        }
        guard !scopes.isEmpty, scopes.allSatisfy(\.isValid) else { return }
        refreshTask?.cancel()
        let id = UUID()
        refreshID = id
        let requestedScopes = scopes
        isRefreshing = true
        failure = nil
        refreshTask = Task { [weak self, service] in
            do {
                let result = try await service.fetch(scopes: requestedScopes)
                guard !Task.isCancelled, let self, self.refreshID == id else { return }
                self.snapshot = result
                self.failureCount = 0
                self.isRefreshing = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.refreshID == id else { return }
                self.failure = (error as? ReviewError) ?? .api
                self.failureCount = min(self.failureCount + 1, 4)
                self.isRefreshing = false
            }
        }
    }

    func repositoryList(for organization: String) -> RepositoryListState {
        repositoryLists[organization.lowercased()] ?? RepositoryListState()
    }

    func loadRepositories(organization: String) {
        let key = organization.lowercased()
        repositoryTasks[key]?.cancel()
        let id = UUID()
        repositoryRequestIDs[key] = id
        guard RepositoryScope(organization: organization).isValid else { return }
        if isDemo {
            repositoryLists[key] = RepositoryListState(repositories: DemoData.repositories)
            return
        }
        repositoryLists[key] = RepositoryListState(isLoading: true)
        repositoryTasks[key] = Task { [weak self, service] in
            do {
                let result = try await service.repositories(organization: organization)
                guard !Task.isCancelled, let self, self.repositoryRequestIDs[key] == id else { return }
                self.repositoryLists[key] = RepositoryListState(repositories: result)
            } catch {
                guard !Task.isCancelled, let self, self.repositoryRequestIDs[key] == id else { return }
                self.repositoryLists[key] = RepositoryListState(error: (error as? ReviewError) ?? .api)
            }
        }
    }

    private func startPolling() {
        refresh()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.refreshInterval, let failures = self?.failureCount else { return }
                let delay = min(1_800, interval * (1 << failures))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self else { return }
                if !self.isRefreshing { self.refresh() }
            }
        }
    }

    func open(_ url: URL) {
        guard url.scheme == "https", url.host == "github.com" else { return }
        NSWorkspace.shared.open(url)
    }

    func openOrganization() {
        guard !scopes.isEmpty, scopes.allSatisfy(\.isValid) else { return }
        var components = URLComponents(string: "https://github.com/pulls")!
        components.queryItems = [URLQueryItem(name: "q", value: "is:pr is:open " + scopes.map { "org:\($0.organization)" }.joined(separator: " "))]
        if let url = components.url { open(url) }
    }
}
