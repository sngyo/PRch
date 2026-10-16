import SwiftUI
import ReviewCore

struct ReviewPanel: View {
    @ObservedObject var store: AppStore
    private var l10n: L10n { store.l10n }
    @State private var tab = "incoming"
    @State private var selectedFilters: [String: String] = [:]
    @State private var query = ""
    @State private var selectedRepository = "all"
    @State private var repositoryFilterHovered = false
    @State private var detail: PullRequest?
    @State private var incomingPendingExpanded = false
    @State private var outgoingPendingExpanded = false
    @State private var activityOnly = false
    @State private var activityReceipts: Set<ActivityReceipt> = []
    @State private var rowFrames: [ActivityReceipt: CGRect] = [:]
    @State private var viewportHeight: CGFloat = 0
    @State private var panelActive = false

    private var source: [PullRequest] { tab == "incoming" ? store.incoming : store.outgoing }
    private func selectedFilter(for tab: String) -> String {
        selectedFilters[tab] ?? (tab == "incoming" ? store.defaultIncoming : "all")
    }
    private var filter: String { selectedFilter(for: tab) }
    private func repositoryName(_ pr: PullRequest) -> String {
        store.scopes.count > 1 ? pr.repositoryFullName : pr.repository
    }
    private func search(_ prs: [PullRequest], repository: String? = nil) -> [PullRequest] {
        let repository = repository ?? selectedRepository
        return prs.filter { pr in
            (repository == "all" || repositoryName(pr) == repository) &&
            (query.isEmpty || "\(pr.title) \(pr.number) \(pr.repositoryFullName) \(pr.author)".localizedCaseInsensitiveContains(query))
        }
    }
    private var searched: [PullRequest] { search(tab == "incoming" ? store.activeIncoming : store.activeOutgoing) }
    private var pending: [PullRequest] { search(tab == "incoming" ? store.pendingIncoming : store.pendingOutgoing) }
    private func matches(_ pr: PullRequest, filter: String, tab: String) -> Bool {
        let status = tab == "incoming" ? pr.incomingStatus : pr.outgoingStatus
        switch filter {
        case "all": return true
        case "pending": return status?.needsReview == true
        case "done": return status?.needsReview == false
        case "waiting": return status == .waiting || status == .required
        default: return status?.rawValue == filter
        }
    }
    private var filtered: [PullRequest] { searched.filter { matches($0, filter: filter, tab: tab) && (!activityOnly || store.activity(for: $0) != nil) } }
    private func tabCount(_ id: String) -> Int {
        let prs = id == "incoming" ? store.activeIncoming : store.activeOutgoing
        // Switching tabs resets the repository picker, but keeps the search query.
        return search(prs, repository: id == tab ? selectedRepository : "all")
            .filter { matches($0, filter: selectedFilter(for: id), tab: id) }.count
    }
    private var repositoryNames: [String] { Set(source.map(repositoryName)).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    private func groups(for prs: [PullRequest]) -> [(id: String, name: String, prs: [PullRequest])] {
        let grouped = Dictionary(grouping: prs) { $0.repositoryFullName.lowercased() }
        return store.orderedRepositoryIDs(Array(grouped.keys)).compactMap { id in
            guard let prs = grouped[id], let first = prs.first else { return nil }
            return (id, repositoryName(first), prs.sorted {
                let a = (tab == "incoming" ? $0.incomingStatus : $0.outgoingStatus)?.priority ?? 9
                let b = (tab == "incoming" ? $1.incomingStatus : $1.outgoingStatus)?.priority ?? 9
                return a == b ? $0.updatedAt > $1.updatedAt : a < b
            })
        }
    }

    var body: some View {
        Group {
            if store.showSettings { SettingsPanel(store: store) }
            else if let detail { DetailPanel(pr: detail, store: store) { self.detail = nil } }
            else { mainPanel }
        }
        .frame(width: 440, height: 624)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Palette.green)
        .environment(\.l10n, l10n)
        .environment(\.locale, l10n.locale)
        .background(PanelActivityObserver { active, closed in
            panelActive = active
            if closed { finishActivitySession() }
            else if active { recordVisibleActivity() }
        }.frame(width: 0, height: 0))
        .onDisappear { finishActivitySession() }
        .onChange(of: store.showSettings) { _, showing in if !showing { recordVisibleActivity() } }
        .onChange(of: store.scopes) { _, _ in selectedRepository = "all"; detail = nil }
        .onChange(of: repositoryNames) { _, names in
            if selectedRepository != "all", !names.contains(selectedRepository) { selectedRepository = "all" }
        }
    }

    private var mainPanel: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 22) {
                tabButton("incoming", l10n.text("tab.incoming"), "tray", tabCount("incoming"))
                tabButton("outgoing", l10n.text("tab.outgoing"), "paperplane", tabCount("outgoing"))
                Spacer()
            }.padding(.horizontal, 17)
            Divider().padding(.horizontal, 16)
            filters
            activitySummary
            if let error = store.error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error + (store.hasStaleData ? l10n.text("connection.stale") : ""))
                    Spacer(minLength: 0)
                }.font(.system(size: 10)).foregroundStyle(Palette.amber).padding(10)
                    .background(Palette.amber.opacity(0.08))
            }
            if let warning = store.snapshot?.warnings.first {
                Text(l10n.warning(warning)).font(.system(size: 10)).foregroundStyle(Palette.amber).padding(8)
            }
            list
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            BrandMark()
                .foregroundStyle(Palette.green).frame(width: 28, height: 28)
                .background(Palette.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text("PRch").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 4) {
                    Image(systemName: "building.2").font(.system(size: 8))
                    Text(store.scopes.count > 1 ? l10n.text("organizations.count", store.scopes.count) : store.scope.organization)
                        .help(store.scopes.map(\.organization).joined(separator: ", "))
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isRefreshing { ProgressView().controlSize(.mini).frame(width: 22) }
            else { Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.help(l10n.text("common.refreshNow")).keyboardShortcut("r") }
            Button { store.showSettings = true } label: { Image(systemName: "gearshape") }.help(l10n.text("settings.open"))
            if let snapshot = store.snapshot { Avatar(name: snapshot.login, url: snapshot.avatarURL, size: 20).help(snapshot.login) }
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 17).padding(.vertical, 13)
    }

    private func tabButton(_ id: String, _ title: String, _ symbol: String, _ count: Int) -> some View {
        Button {
            guard tab != id else { return }
            tab = id; selectedRepository = "all"; activityOnly = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
                Text("\(count)").font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 2)
                    .background((tab == id ? Palette.green : Color.secondary).opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                let unread = (id == "incoming" ? store.activeIncoming : store.activeOutgoing).filter { store.activity(for: $0) != nil }.count
                if unread > 0 {
                    Text("+\(unread)").font(.system(size: 9)).foregroundStyle(Palette.green)
                        .help(l10n.text("activity.unreadCount", unread))
                }
            }.font(.system(size: 11, weight: tab == id ? .semibold : .regular))
                .foregroundStyle(tab == id ? Color.primary : Color.secondary)
                .padding(.bottom, 10)
                .overlay(alignment: .bottom) { Rectangle().fill(tab == id ? Palette.green : .clear).frame(height: 2) }
        }.buttonStyle(.plain).accessibilityAddTraits(tab == id ? .isSelected : [])
    }

    private var filters: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                if tab == "incoming" {
                    chip("pending", l10n.text("filter.pending")); chip("done", l10n.text("filter.reviewed")); chip("all", l10n.text("common.all"))
                } else {
                    chip("all", l10n.text("common.all")); chip("waiting", l10n.text("filter.waiting")); chip("changes", l10n.text("filter.changes")); chip("approved", l10n.text("filter.approved")); chip("unrequested", l10n.text("filter.unrequested"))
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField(l10n.text("search.placeholder"), text: $query).textFieldStyle(.plain).accessibilityLabel(l10n.text("search.accessibility"))
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary).help(l10n.text("common.clearSearch")) }
                repositoryFilter
            }.font(.system(size: 10))
        }.padding(.horizontal, 16).padding(.top, 11).padding(.bottom, 9)
    }

    private func activityCounts(_ prs: [PullRequest]) -> String {
        let activities = prs.compactMap { store.activity(for: $0) }
        let newCount = activities.filter { $0.kind == .new }.count
        let updatedCount = activities.filter { $0.kind == .updated }.count
        return [newCount > 0 ? l10n.text("activity.newCount", newCount) : nil,
                updatedCount > 0 ? l10n.text("activity.updatedCount", updatedCount) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var activitySummary: some View {
        let summary = activityCounts(tab == "incoming" ? store.activeIncoming : store.activeOutgoing)
        return HStack(spacing: 5) {
            if !summary.isEmpty {
                Circle().fill(Palette.green).frame(width: 4, height: 4)
                Text(l10n.text("activity.sinceLast", summary)).foregroundStyle(Palette.green)
            } else {
                Text(l10n.text("activity.none")).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            Button { activityOnly.toggle() } label: {
                Text(l10n.text("activity.only"))
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(activityOnly ? Palette.green.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
            }.buttonStyle(.plain).foregroundStyle(activityOnly ? Palette.green : .secondary)
                .accessibilityAddTraits(activityOnly ? .isSelected : [])
        }.font(.system(size: 9)).padding(.horizontal, 16).padding(.bottom, 8)
            .help(l10n.text("activity.help"))
    }

    private func recordVisibleActivity() {
        guard panelActive, !store.showSettings, detail == nil, viewportHeight > 0 else { return }
        let visibleIDs = Set(filtered.filter { !store.isRepositoryCollapsed($0.repositoryFullName) }.map(\.id))
        // Leave room for the pinned repository header; partially clipped rows stay unread.
        for (receipt, frame) in rowFrames where visibleIDs.contains(receipt.prID) && frame.minY >= 26 && frame.maxY <= viewportHeight && frame.height > 0 {
            activityReceipts.insert(receipt)
        }
    }

    private func finishActivitySession() {
        store.acknowledgeActivity(activityReceipts)
        activityReceipts.removeAll()
        panelActive = false
    }

    private var repositoryFilter: some View {
        let isFiltered = selectedRepository != "all"
        let title = isFiltered ? selectedRepository : l10n.text("repositories.all")
        return Menu {
            Picker(l10n.text("repositories.picker"), selection: $selectedRepository) {
                Text(l10n.text("repositories.all")).tag("all")
                ForEach(repositoryNames, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                Text(title).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
            }
            .font(.system(size: 10, weight: isFiltered ? .medium : .regular))
            .foregroundStyle(isFiltered ? Palette.green : Color.secondary)
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(isFiltered ? Palette.green.opacity(0.10) : Color.primary.opacity(repositoryFilterHovered ? 0.05 : 0),
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .frame(maxWidth: 190).fixedSize(horizontal: true, vertical: false)
        .onHover { repositoryFilterHovered = $0 }
        .accessibilityLabel(l10n.text("repositories.picker"))
        .accessibilityValue(title)
        .help(title)
    }

    private func chip(_ id: String, _ title: String) -> some View {
        Button { selectedFilters[tab] = id } label: {
            HStack(spacing: 4) {
                Text(title)
                Text("\(searched.filter { matches($0, filter: id, tab: tab) }.count)").font(.system(size: 9)).opacity(0.75)
            }.font(.system(size: 10, weight: filter == id ? .medium : .regular))
                .foregroundStyle(filter == id ? Palette.green : Color.secondary)
                .padding(.horizontal, 7).padding(.vertical, 6)
                .background(filter == id ? Palette.green.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).accessibilityAddTraits(filter == id ? .isSelected : [])
    }

    private var list: some View {
        ScrollView {
            if filtered.isEmpty && pending.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: store.isRefreshing ? "arrow.clockwise" : "tray").font(.system(size: 25)).foregroundStyle(Palette.green)
                    Text(store.snapshot == nil && store.isRefreshing ? l10n.text("connection.loading") : store.snapshot == nil && store.error != nil ? l10n.text("connection.empty") : l10n.text("list.noMatch")).font(.system(size: 12, weight: .medium))
                    Text(store.scopes.allSatisfy(\.isEmptySelection) ? l10n.text("list.selectRepositories") : l10n.text("list.checkFilters"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                LazyVStack(spacing: 7, pinnedViews: [.sectionHeaders]) {
                    repositoryGroups(filtered)
                    if !pending.isEmpty {
                        let isExpanded = tab == "incoming" ? $incomingPendingExpanded : $outgoingPendingExpanded
                        DisclosureGroup(isExpanded: isExpanded) {
                            repositoryGroups(pending)
                        } label: {
                            HStack(spacing: 6) {
                                Label(l10n.text("localPending.title"), systemImage: "pause.circle")
                                Text("\(pending.count)").monospacedDigit()
                                Spacer()
                            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation { isExpanded.wrappedValue.toggle() }
                                }
                                .help(l10n.text("localPending.help"))
                        }
                        .padding(.horizontal, 4)
                    }
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        .coordinateSpace(name: "activityList")
        .background(GeometryReader { geometry in
            Color.clear.onAppear { viewportHeight = geometry.size.height; recordVisibleActivity() }
                .onChange(of: geometry.size.height) { _, height in viewportHeight = height; recordVisibleActivity() }
        })
        .onPreferenceChange(ActivityRowFrames.self) { frames in
            rowFrames = frames
            recordVisibleActivity()
        }
        .frame(maxHeight: .infinity)
    }

    private func repositoryGroups(_ prs: [PullRequest]) -> some View {
        ForEach(groups(for: prs), id: \.id) { group in
            Section {
                if !store.isRepositoryCollapsed(group.id) {
                    VStack(spacing: 0) {
                        ForEach(group.prs) { pr in
                            PRRow(pr: pr, incoming: tab == "incoming", showCI: store.showCI,
                                  isPending: store.isPending(pr), activity: store.activity(for: pr)?.kind,
                                  togglePending: { store.setPending(!store.isPending(pr), for: pr) },
                                  open: { store.open(pr.url) }, details: { detail = pr })
                                .background(GeometryReader { geometry in
                                    if let receipt = store.activityReceipt(for: pr) {
                                        Color.clear.preference(key: ActivityRowFrames.self,
                                                               value: [receipt: geometry.frame(in: .named("activityList"))])
                                    }
                                })
                        }
                    }
                }
            } header: {
                RepositoryHeader(repositoryID: group.id, name: group.name, count: group.prs.count,
                                 activity: activityCounts(group.prs), isCollapsed: store.isRepositoryCollapsed(group.id),
                                 toggle: { store.toggleRepository(group.id) },
                                 move: { store.moveRepository($0, to: group.id) })
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Circle().fill(store.error == nil ? Palette.green : Palette.amber).frame(width: 4, height: 4)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(store.snapshot.map { l10n.text("time.updated", l10n.age($0.fetchedAt, now: context.date)) } ?? l10n.text("connection.disconnected"))
            }
            Spacer()
            if store.isDemo { Text("DEMO").font(.system(size: 8)) }
            Button { store.openOrganization() } label: { Label("GitHub", systemImage: "arrow.up.right") }
        }.font(.system(size: 9)).foregroundStyle(.secondary).buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .top) { Divider() }
    }
}

struct PRRow: View {
    @Environment(\.l10n) private var l10n
    let pr: PullRequest
    let incoming: Bool
    let showCI: Bool
    let isPending: Bool
    let activity: PRActivityKind?
    let togglePending: () -> Void
    let open: () -> Void
    let details: () -> Void
    @State private var hovered = false
    private var status: ReviewStatus { incoming ? pr.incomingStatus ?? .waiting : pr.outgoingStatus }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: pr.isDraft ? "pencil.circle" : "arrow.triangle.branch").foregroundStyle(pr.isDraft ? Color.secondary : Palette.green).font(.system(size: 11))
                        Text(verbatim: "#\(pr.number)・\(pr.title)").font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 2)
                        if let activity { ActivityBadge(kind: activity) }
                        Text(l10n.age(pr.updatedAt)).font(.system(size: 9)).foregroundStyle(.tertiary).fixedSize()
                    }
                    HStack(spacing: 6) {
                        if incoming {
                            Avatar(name: pr.author)
                            Text(pr.author).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            ForEach(Array(pr.reviewers.prefix(2))) { reviewer in
                                HStack(spacing: 2) {
                                    Text(reviewer.name).lineLimit(1)
                                    Image(systemName: reviewer.status.symbol).foregroundStyle(reviewer.status.color)
                                }.foregroundStyle(.secondary).help(l10n.text("row.reviewer", reviewer.name, l10n.text(reviewer.status.labelKey)))
                            }
                            if pr.reviewers.count > 2 { Text("+\(pr.reviewers.count - 2)").foregroundStyle(.tertiary) }
                        }
                        Spacer(minLength: 0)
                        if pr.isDraft { Text(l10n.text("common.draft")).foregroundStyle(.secondary) }
                        StatusBadge(status: status, label: status == .waiting && incoming ? l10n.text("status.unreviewed") : status == .changes && !incoming ? l10n.text("filter.changes") : nil)
                        if !incoming && showCI, let check = pr.checkState {
                            Image(systemName: check == "SUCCESS" ? "checkmark" : ["FAILURE", "ERROR"].contains(check) ? "xmark" : "clock")
                                .foregroundStyle(check == "SUCCESS" ? Palette.green : Palette.amber).help(l10n.text("detail.ci", check))
                        }
                    }.font(.system(size: 9)).padding(.leading, 17)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(l10n.text("row.openHelp", pr.title))
            Menu {
                Button(l10n.text(isPending ? "localPending.restore" : "localPending.set"), action: togglePending)
            } label: { Image(systemName: isPending ? "pause.circle" : "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(.secondary)
                .help(l10n.text(isPending ? "localPending.restore" : "localPending.set"))
                .accessibilityLabel(l10n.text("localPending.actions", pr.title))
            Button(action: details) { Image(systemName: "chevron.right").font(.system(size: 9)).frame(width: 14, height: 36) }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help(l10n.text("detail.title")).accessibilityLabel(l10n.text("row.detailsAccessibility", pr.title))
        }.padding(.horizontal, 8).frame(height: 50)
            .background(hovered ? Color.primary.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .background(activity.map { ($0 == .new ? Palette.green : Palette.blue).opacity(0.07) } ?? .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .leading) {
                if let activity {
                    RoundedRectangle(cornerRadius: 1).fill(activity == .new ? Palette.green : Palette.blue)
                        .frame(width: 2).padding(.vertical, 4)
                }
            }
            .onHover { hovered = $0 }
            .contextMenu {
                Button(l10n.text("common.openGitHub"), action: open)
                Button(l10n.text("common.details"), action: details)
                Divider()
                Button(l10n.text(isPending ? "localPending.restore" : "localPending.set"), action: togglePending)
            }
    }
}
