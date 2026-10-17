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
    @Published private(set) var nextRefreshAt: Date?
    var error: String? { failure.map(l10n.error) }
    var l10n: L10n { L10n(language: language) }
    struct RepositoryListState {
        var repositories: [Repository] = []
        var isLoading = false
        var error: ReviewError?
    }
    @Published private(set) var repositoryLists: [String: RepositoryListState] = [:]
    @Published private(set) var repositoryOrder: [String] = []
    @Published private(set) var collapsedRepositories: Set<String> = []
    @Published private var pendingPRIDsByAccount: [String: [String]] = [:]
    @Published private(set) var activityTracker = ActivityTracker()
    @Published var activityIndicatorStyle = ActivityIndicatorStyle.dot { didSet { defaults.set(activityIndicatorStyle.rawValue, forKey: "activityIndicatorStyle") } }
    @Published var showSettings = false
    @Published var language = AppLanguage.system { didSet { defaults.set(language.rawValue, forKey: "language") } }
    @Published var defaultIncoming = "pending" { didSet { defaults.set(defaultIncoming, forKey: "defaultIncoming") } }
    @Published var showCI = true { didSet { defaults.set(showCI, forKey: "showCI") } }
    @Published var approveWithOneApproval = false { didSet { defaults.set(approveWithOneApproval, forKey: "approveWithOneApproval") } }
    @Published var menuBarStyle = MenuBarStyle.separateCounts { didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") } }
    @Published var refreshInterval = 120 {
        didSet {
            defaults.set(refreshInterval, forKey: "refreshInterval")
            if !isRefreshing { scheduleNextRefresh() }
        }
    }
    let isDemo: Bool
    private let defaults: UserDefaults
    private let service: any ReviewService
    private let pollsAutomatically: Bool
    private let refreshTiming: RefreshTiming
    private var refreshTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var repositoryTasks: [String: Task<Void, Never>] = [:]
    private var refreshID = UUID()
    private var repositoryRequestIDs: [String: UUID] = [:]
    private var failureCount = 0

    init(service: any ReviewService = GitHubService(), isDemo: Bool = false, preferences: UserDefaults? = nil, startsPolling: Bool = true, demoActivity: Bool = false,
         refreshTiming: RefreshTiming = RefreshTiming()) {
        self.service = service
        self.isDemo = isDemo
        self.pollsAutomatically = startsPolling && !isDemo
        self.refreshTiming = refreshTiming
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
        pendingPRIDsByAccount = defaults.dictionary(forKey: "pendingPRIDsByAccount") as? [String: [String]] ?? [:]
        repositoryOrder = defaults.stringArray(forKey: "repositoryOrder") ?? []
        collapsedRepositories = Set(defaults.stringArray(forKey: "collapsedRepositories") ?? [])
        activityTracker = defaults.data(forKey: "activityTracker").flatMap { try? JSONDecoder().decode(ActivityTracker.self, from: $0) } ?? ActivityTracker()
        activityIndicatorStyle = defaults.string(forKey: "activityIndicatorStyle").flatMap(ActivityIndicatorStyle.init(rawValue:)) ?? .dot
        language = defaults.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) ?? .system
        defaultIncoming = defaults.string(forKey: "defaultIncoming") ?? "pending"
        showCI = defaults.object(forKey: "showCI") as? Bool ?? true
        approveWithOneApproval = defaults.bool(forKey: "approveWithOneApproval")
        menuBarStyle = defaults.string(forKey: "menuBarStyle").flatMap(MenuBarStyle.init(rawValue:)) ?? .separateCounts
        refreshInterval = max(60, defaults.integer(forKey: "refreshInterval") == 0 ? 120 : defaults.integer(forKey: "refreshInterval"))
        if isDemo {
            scopes = [RepositoryScope(organization: "example-org")]
            if demoActivity {
                activityTracker = ActivityTracker()
                activityTracker.ingest(DemoData.beforeActivity, scopes: scopes, pendingIDs: [])
            }
            acceptSnapshot(DemoData.snapshot)
        } else {
            showSettings = !scope.isValid
            if pollsAutomatically { refresh() }
        }
    }

    deinit {
        pollingTask?.cancel()
        refreshTask?.cancel()
    }

    var incoming: [PullRequest] { snapshot?.pullRequests.filter { $0.incomingStatus != nil && !$0.isAuthored } ?? [] }
    var outgoing: [PullRequest] { snapshot?.pullRequests.filter { $0.isAuthored } ?? [] }
    var activeIncoming: [PullRequest] { incoming.filter { !isPending($0) } }
    var pendingIncoming: [PullRequest] { incoming.filter { isPending($0) } }
    var activeOutgoing: [PullRequest] { outgoing.filter { !isPending($0) } }
    var pendingOutgoing: [PullRequest] { outgoing.filter { isPending($0) } }

    func outgoingStatus(for pr: PullRequest) -> ReviewStatus {
        pr.outgoingStatus(approveWithOneApproval: approveWithOneApproval)
    }

    // Full, case-insensitive names keep layout stable when scopes or display names change.
    func isRepositoryCollapsed(_ repositoryID: String) -> Bool {
        collapsedRepositories.contains(repositoryID.lowercased())
    }

    func toggleRepository(_ repositoryID: String) {
        let id = repositoryID.lowercased()
        if !collapsedRepositories.insert(id).inserted { collapsedRepositories.remove(id) }
        defaults.set(collapsedRepositories.sorted(), forKey: "collapsedRepositories")
    }

    func orderedRepositoryIDs(_ repositoryIDs: [String]) -> [String] {
        let positions = Dictionary(repositoryOrder.enumerated().map { ($0.element.lowercased(), $0.offset) },
                                   uniquingKeysWith: min)
        return Set(repositoryIDs.map { $0.lowercased() }).sorted {
            let a = positions[$0] ?? Int.max
            let b = positions[$1] ?? Int.max
            return a == b ? $0.localizedStandardCompare($1) == .orderedAscending : a < b
        }
    }

    @discardableResult
    func moveRepository(_ repositoryID: String, to targetID: String) -> Bool {
        let source = repositoryID.lowercased(), target = targetID.lowercased()
        let available = snapshot?.pullRequests.map { $0.repositoryFullName.lowercased() } ?? []
        guard source != target, available.contains(source), available.contains(target) else { return false }
        // Keep absent/filtered repositories in the saved order so they return to their place.
        var order = orderedRepositoryIDs(repositoryOrder + available)
        guard let from = order.firstIndex(of: source), let to = order.firstIndex(of: target) else { return false }
        order.remove(at: from)
        order.insert(source, at: to)
        repositoryOrder = order
        defaults.set(order, forKey: "repositoryOrder")
        return true
    }

    func isPending(_ pr: PullRequest) -> Bool {
        guard let login = snapshot?.login.lowercased() else { return false }
        return pendingPRIDsByAccount[login]?.contains(pr.id) == true
    }

    func setPending(_ pending: Bool, for pr: PullRequest) {
        guard let snapshot,
              snapshot.pullRequests.contains(where: { $0.id == pr.id }) else { return }
        let login = snapshot.login.lowercased()
        var ids = Set(pendingPRIDsByAccount[login] ?? [])
        if pending { ids.insert(pr.id) } else { ids.remove(pr.id) }
        pendingPRIDsByAccount[login] = ids.sorted()
        // Keep IDs when a repository is deselected or absent from a refresh.
        // Only opaque PR IDs and account keys persist, never PR content.
        defaults.set(pendingPRIDsByAccount, forKey: "pendingPRIDsByAccount")
        activityTracker.clear(id: pr.id, account: login)
        persistActivity()
    }

    func activity(for pr: PullRequest) -> PRActivity? {
        guard !isPending(pr), let login = snapshot?.login else { return nil }
        return activityTracker.activity(for: pr.id, account: login)
    }

    func activityReceipt(for pr: PullRequest) -> ActivityReceipt? {
        guard let activity = activity(for: pr), let login = snapshot?.login else { return nil }
        return ActivityReceipt(account: login.lowercased(), prID: pr.id, revision: activity.revision)
    }

    func activityReceipts(incoming: Bool) -> Set<ActivityReceipt> {
        Set((incoming ? activeIncoming : activeOutgoing).compactMap { activityReceipt(for: $0) })
    }

    var unreadActivityCount: Int {
        (incoming + outgoing).filter { activity(for: $0) != nil }.count
    }

    func acknowledgeActivity(_ receipts: Set<ActivityReceipt>) {
        guard !receipts.isEmpty else { return }
        activityTracker.acknowledge(receipts)
        persistActivity()
    }

    private func persistActivity() {
        if let data = try? JSONEncoder().encode(activityTracker) { defaults.set(data, forKey: "activityTracker") }
    }

    private func acceptSnapshot(_ result: ReviewSnapshot) {
        activityTracker.ingest(result, scopes: scopes,
                               pendingIDs: Set(pendingPRIDsByAccount[result.login.lowercased()] ?? []))
        snapshot = result
        persistActivity()
    }

    var pendingCount: Int { activeIncoming.filter { $0.incomingStatus?.needsReview == true }.count }
    var changesRequestedCount: Int { activeOutgoing.filter { $0.outgoingStatus == .changes }.count }
    var menuBarSummary: String {
        if let error { return l10n.text("common.appMessage", error) }
        guard snapshot != nil else { return l10n.text("common.appMessage", l10n.text(isRefreshing ? "connection.loading" : "connection.disconnected")) }
        return l10n.text("menu.summary", pendingCount, changesRequestedCount, scopes.map(\.organization).joined(separator: ", ")) + " · " + l10n.text("activity.unreadCount", unreadActivityCount)
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
            failure = nil
        }
        showSettings = false
        refresh()
    }

    func refresh() {
        guard !isDemo else {
            acceptSnapshot(ReviewSnapshot(login: "you", pullRequests: DemoData.snapshot.pullRequests.filter {
                pr in scopes.contains { $0.contains(owner: pr.repositoryOwner, name: pr.repository) }
            }))
            return
        }
        guard !scopes.isEmpty, scopes.allSatisfy(\.isValid) else { return }
        pollingTask?.cancel()
        nextRefreshAt = nil
        refreshTask?.cancel()
        let id = UUID()
        refreshID = id
        let requestedScopes = scopes
        isRefreshing = true
        refreshTask = Task { [weak self, service] in
            do {
                let result = try await service.fetch(scopes: requestedScopes)
                guard !Task.isCancelled, let self, self.refreshID == id else { return }
                self.acceptSnapshot(result)
                self.failureCount = 0
                self.failure = nil
                self.isRefreshing = false
                self.scheduleNextRefresh()
            } catch {
                guard !Task.isCancelled, let self, self.refreshID == id else { return }
                let failure = (error as? ReviewError) ?? .api
                self.failureCount = self.failure == failure ? min(self.failureCount + 1, 4) : 1
                self.failure = failure
                self.isRefreshing = false
                self.scheduleNextRefresh()
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

    private func scheduleNextRefresh() {
        guard pollsAutomatically, !isRefreshing, !scopes.isEmpty, scopes.allSatisfy(\.isValid) else { return }
        pollingTask?.cancel()
        let delay = RefreshTiming.delay(interval: refreshInterval, failure: failure, failureCount: failureCount)
        nextRefreshAt = refreshTiming.now().addingTimeInterval(delay)
        pollingTask = Task { [weak self, refreshTiming] in
            do { try await refreshTiming.sleep(delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.refresh()
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
