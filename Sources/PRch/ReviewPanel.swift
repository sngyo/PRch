import AppKit
import SwiftUI
import ReviewCore

struct ReviewPanel: View {
    @ObservedObject var store: AppStore
    private var l10n: L10n { store.l10n }
    @State private var tab = "incoming"
    @State private var selectedFilters: [String: String] = [:]
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var selectedRepository = "all"
    @State private var repositoryFilterHovered = false
    @State private var detail: PullRequest?
    @State private var incomingPendingExpanded = false
    @State private var outgoingPendingExpanded = false
    @State private var activityOnly = false
    @State private var activityReceipts: Set<ActivityReceipt> = []
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
    private func status(for pr: PullRequest, tab: String) -> ReviewStatus? {
        tab == "incoming" ? pr.incomingStatus : store.outgoingStatus(for: pr)
    }
    private func matches(_ pr: PullRequest, filter: String, tab: String) -> Bool {
        let status = status(for: pr, tab: tab)
        switch filter {
        case "all": return true
        case "pending": return status?.needsReview == true
        case "done": return status?.needsReview == false
        case "waiting": return status == .waiting || status == .required
        default: return status?.rawValue == filter
        }
    }
    private func filterCounts(for prs: [PullRequest]) -> [String: Int] {
        var counts = ["all": prs.count]
        for pr in prs {
            guard let status = status(for: pr, tab: tab) else { continue }
            let key = tab == "incoming" ? (status.needsReview ? "pending" : "done")
                : (status == .required ? "waiting" : status.rawValue)
            counts[key, default: 0] += 1
        }
        return counts
    }
    private func tabCount(_ id: String) -> Int {
        let prs = id == "incoming" ? store.activeIncoming : store.activeOutgoing
        // Switching tabs resets the repository picker, but keeps the search query.
        return search(prs, repository: id == tab ? selectedRepository : "all")
            .filter { matches($0, filter: selectedFilter(for: id), tab: id) }.count
    }
    private var repositoryNames: [String] { Set(source.map(repositoryName)).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    private enum ListSection: String { case starred, regular, pending }

    private func groups(for prs: [PullRequest], section: ListSection) -> [(id: String, repositoryID: String, name: String, prs: [PullRequest])] {
        let grouped = Dictionary(grouping: prs) { $0.repositoryFullName.lowercased() }
        return store.orderedRepositoryIDs(Array(grouped.keys)).compactMap { id in
            guard let prs = grouped[id], let first = prs.first else { return nil }
            // Starred, regular, and Pending can contain the same repository in one lazy stack.
            // Give their sections distinct identities, including across tab switches.
            return ("\(tab):\(section.rawValue):\(id)", id, repositoryName(first), prs.sorted {
                let a = status(for: $0, tab: tab)?.priority ?? 9
                let b = status(for: $1, tab: tab)?.priority ?? 9
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
        .frame(width: PanelLayout.size.width, height: PanelLayout.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Palette.green)
        .environment(\.l10n, l10n)
        .environment(\.locale, l10n.locale)
        .background(PanelActivityObserver { active, closed in
            panelActive = active
            if closed { finishActivitySession() }
            else if active { recordTabActivity() }
        }.frame(width: 0, height: 0))
        .onDisappear { finishActivitySession() }
        .onChange(of: tab) { _, _ in recordTabActivity() }
        .onChange(of: store.snapshot?.fetchedAt) { _, _ in recordTabActivity() }
        .onChange(of: store.showSettings) { _, showing in if !showing { recordTabActivity() } }
        .onChange(of: detail) { _, detail in if detail == nil { recordTabActivity() } }
        .onChange(of: store.scopes) { _, _ in selectedRepository = "all"; detail = nil }
        .onChange(of: repositoryNames) { _, names in
            if selectedRepository != "all", !names.contains(selectedRepository) { selectedRepository = "all" }
        }
    }

    private var mainPanel: some View {
        let searched = search(tab == "incoming" ? store.activeIncoming : store.activeOutgoing)
        let counts = filterCounts(for: searched)
        let filtered = searched.filter { matches($0, filter: filter, tab: tab) && (!activityOnly || store.activity(for: $0) != nil) }
        let pending = search(tab == "incoming" ? store.pendingIncoming : store.pendingOutgoing)
        return VStack(spacing: 0) {
            header
            HStack(spacing: 22) {
                tabButton("incoming", l10n.text("tab.incoming"), "tray", tab == "incoming" ? counts[filter, default: 0] : tabCount("incoming"))
                tabButton("outgoing", l10n.text("tab.outgoing"), "paperplane", tab == "outgoing" ? counts[filter, default: 0] : tabCount("outgoing"))
                Spacer()
            }.padding(.horizontal, 17)
            Divider().padding(.horizontal, 16)
            filters(counts: counts)
            activitySummary
            if let error = store.error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(error + (store.hasStaleData ? l10n.text("connection.stale") : ""))
                        if store.isRefreshing {
                            Text(l10n.text("connection.retrying"))
                        } else if let nextRefreshAt = store.nextRefreshAt {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(l10n.text("connection.retryIn", max(1, Int(ceil(nextRefreshAt.timeIntervalSince(context.date))))))
                                    .monospacedDigit()
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }.font(.system(size: 12)).foregroundStyle(Palette.amber).padding(10)
                    .background(Palette.amber.opacity(0.08))
            }
            if let warning = store.snapshot?.warnings.first {
                Text(l10n.warning(warning)).font(.system(size: 12)).foregroundStyle(Palette.amber).padding(8)
            }
            list(filtered: filtered, pending: pending)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            BrandMark()
                .foregroundStyle(Palette.green).frame(width: 28, height: 28)
                .background(Palette.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text("PRch").font(.system(size: 16, weight: .semibold))
                HStack(spacing: 4) {
                    Image(systemName: "building.2").font(.system(size: 10))
                    Text(store.scopes.count > 1 ? l10n.text("organizations.count", store.scopes.count) : store.scope.organization)
                        .help(store.scopes.map(\.organization).joined(separator: ", "))
                }.font(.system(size: 12)).foregroundStyle(.secondary)
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
                Text("\(count)").font(.system(size: 11)).padding(.horizontal, 4).padding(.vertical, 2)
                    .background((tab == id ? Palette.green : Color.secondary).opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                let unread = (id == "incoming" ? store.activeIncoming : store.activeOutgoing).filter { store.activity(for: $0) != nil }.count
                if unread > 0 {
                    Text("+\(unread)").font(.system(size: 11)).foregroundStyle(Palette.green)
                        .help(l10n.text("activity.unreadCount", unread))
                }
            }.font(.system(size: 13, weight: tab == id ? .semibold : .regular))
                .foregroundStyle(tab == id ? Color.primary : Color.secondary)
                .padding(.bottom, 10)
                .overlay(alignment: .bottom) { Rectangle().fill(tab == id ? Palette.green : .clear).frame(height: 2) }
        }.buttonStyle(.plain).accessibilityAddTraits(tab == id ? .isSelected : [])
    }

    private func filters(counts: [String: Int]) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                if tab == "incoming" {
                    chip("pending", l10n.text("filter.pending"), counts); chip("done", l10n.text("filter.reviewed"), counts); chip("all", l10n.text("common.all"), counts)
                } else {
                    chip("all", l10n.text("common.all"), counts); chip("waiting", l10n.text("filter.waiting"), counts); chip("changes", l10n.text("filter.changes"), counts); chip("approved", l10n.text("filter.approved"), counts); chip("unrequested", l10n.text("filter.unrequested"), counts)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Button { searchFocused = true } label: {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain).keyboardShortcut("f", modifiers: .command)
                .help(l10n.text("search.accessibility") + " (⌘F)")
                .accessibilityLabel(l10n.text("search.accessibility"))
                TextField(l10n.text("search.placeholder"), text: $query).textFieldStyle(.plain).accessibilityLabel(l10n.text("search.accessibility"))
                    .focused($searchFocused)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary).help(l10n.text("common.clearSearch")) }
                repositoryFilter
            }.font(.system(size: 12))
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
        }.font(.system(size: 11)).padding(.horizontal, 16).padding(.bottom, 8)
            .help(l10n.text("activity.help"))
    }

    private func recordTabActivity() {
        guard panelActive, !store.showSettings, detail == nil else { return }
        // Visiting a tab acknowledges its whole scope on close, including hidden rows.
        // Receipts retain the revision so later changes in an unvisited tab stay unread.
        activityReceipts.formUnion(store.activityReceipts(incoming: tab == "incoming"))
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
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
            }
            .font(.system(size: 12, weight: isFiltered ? .medium : .regular))
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

    private func chip(_ id: String, _ title: String, _ counts: [String: Int]) -> some View {
        Button { selectedFilters[tab] = id } label: {
            HStack(spacing: 4) {
                Text(title)
                Text("\(counts[id, default: 0])").font(.system(size: 11)).opacity(0.75)
            }.font(.system(size: 12, weight: filter == id ? .medium : .regular))
                .foregroundStyle(filter == id ? Palette.green : Color.secondary)
                .padding(.horizontal, 7).padding(.vertical, 6)
                .background(filter == id ? Palette.green.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).accessibilityAddTraits(filter == id ? .isSelected : [])
    }

    private func list(filtered: [PullRequest], pending: [PullRequest]) -> some View {
        let starred = filtered.filter { store.isStarred($0) }
        let regular = filtered.filter { !store.isStarred($0) }
        return ScrollView {
            if filtered.isEmpty && pending.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: store.isRefreshing ? "arrow.clockwise" : "tray").font(.system(size: 25)).foregroundStyle(Palette.green)
                    Text(store.snapshot == nil && store.isRefreshing ? l10n.text("connection.loading") : store.snapshot == nil && store.error != nil ? l10n.text("connection.empty") : l10n.text("list.noMatch")).font(.system(size: 14, weight: .medium))
                    Text(store.scopes.allSatisfy(\.isEmptySelection) ? l10n.text("list.selectRepositories") : l10n.text("list.checkFilters"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if !starred.isEmpty {
                        HStack(spacing: 6) {
                            Label(l10n.text("starred.title"), systemImage: "star.fill")
                            Text("\(starred.count)").monospacedDigit()
                            Spacer()
                        }.font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.amber)
                            .padding(.horizontal, 9).padding(.vertical, 8)
                            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                            .help(l10n.text("starred.help"))
                        repositoryGroups(starred, section: .starred)
                        if !regular.isEmpty { Divider().padding(.vertical, 8).padding(.horizontal, 9) }
                    }
                    repositoryGroups(regular)
                    if !pending.isEmpty {
                        let isExpanded = tab == "incoming" ? $incomingPendingExpanded : $outgoingPendingExpanded
                        Button {
                            isExpanded.wrappedValue.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold)).frame(width: 8)
                                Label(l10n.text("localPending.title"), systemImage: "pause.circle")
                                Text("\(pending.count)").monospacedDigit()
                                Spacer()
                            }.font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.top, 7)
                        .help(l10n.text("localPending.help"))
                        .accessibilityValue(l10n.text(isExpanded.wrappedValue ? "repositories.expanded" : "repositories.collapsed"))
                        // Keep expanded Pending rows in the same lazy stack as active rows.
                        if isExpanded.wrappedValue { repositoryGroups(pending, section: .pending) }
                    }
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func repositoryGroups(_ prs: [PullRequest], section: ListSection = .regular) -> some View {
        ForEach(groups(for: prs, section: section), id: \.id) { group in
            Section {
                if !store.isRepositoryCollapsed(group.repositoryID) {
                    // Direct children let LazyVStack create and lay out individual visible rows.
                    ForEach(group.prs) { pr in
                        PRRow(store: store, pr: pr, incoming: tab == "incoming",
                              open: { store.open(pr.url) }, details: { detail = pr })
                    }
                }
            } header: {
                RepositoryHeader(repositoryID: group.repositoryID, name: group.name, count: group.prs.count,
                                 activity: activityCounts(group.prs), isCollapsed: store.isRepositoryCollapsed(group.repositoryID),
                                 toggle: { store.toggleRepository(group.repositoryID) },
                                 move: { store.moveRepository($0, to: group.repositoryID) })
                    .padding(.vertical, 7)
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
            if store.isDemo { Text("DEMO").font(.system(size: 10)) }
            Button { store.openOrganization() } label: { Label("GitHub", systemImage: "arrow.up.right") }
        }.font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .top) { Divider() }
    }
}

struct PRRow: View {
    @Environment(\.l10n) private var l10n
    // Local state must stay live when a lazy row moves between sections with the same PR ID.
    @ObservedObject var store: AppStore
    let pr: PullRequest
    let incoming: Bool
    let open: () -> Void
    let details: () -> Void
    @State private var hovered = false
    @State private var copyFeedbackID: UUID?
    private var reference: String { "\(pr.repository)#\(pr.number)" }
    private var status: ReviewStatus { incoming ? pr.incomingStatus ?? .waiting : store.outgoingStatus(for: pr) }
    private var isPending: Bool { store.isPending(pr) }
    private var activity: PRActivityKind? { store.activity(for: pr)?.kind }
    private func togglePending() { store.setPending(!isPending, for: pr) }

    private func copyReference() {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(reference, forType: .string) else { return }
        withAnimation(.easeOut(duration: 0.15)) { copyFeedbackID = UUID() }
    }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: copyReference) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: pr.isDraft ? "pencil.circle" : "arrow.triangle.branch").foregroundStyle(pr.isDraft ? Color.secondary : Palette.green).font(.system(size: 13))
                        Text(verbatim: "#\(pr.number)・\(pr.title)").font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 2)
                        if let activity { ActivityBadge(kind: activity) }
                        Text(l10n.age(pr.updatedAt)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
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
                        if !incoming && store.showCI, let check = pr.checkState {
                            Image(systemName: check == "SUCCESS" ? "checkmark" : ["FAILURE", "ERROR"].contains(check) ? "xmark" : "clock")
                                .foregroundStyle(check == "SUCCESS" ? Palette.green : Palette.amber).help(l10n.text("detail.ci", check))
                        }
                    }.font(.system(size: 11)).padding(.leading, 17)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .highPriorityGesture(TapGesture(count: 2).onEnded { open() })
                .help(l10n.text("row.clickHelp", pr.title, reference))
                .accessibilityHint(Text(l10n.text("row.copyReference", reference)))
                .accessibilityValue(Text(copyFeedbackID == nil ? "" : l10n.text("row.copied")))
                .accessibilityAction(named: Text(l10n.text("common.openGitHub")), open)
                .overlay(alignment: .trailing) {
                    if copyFeedbackID != nil {
                        Label(l10n.text("row.copied"), systemImage: "checkmark")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.green)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                            .overlay { Capsule().strokeBorder(Palette.green.opacity(0.2), lineWidth: 1) }
                            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                            .allowsHitTesting(false).accessibilityHidden(true)
                            .transition(.opacity)
                    }
                }
            PRStarButton(store: store, pr: pr)
            Menu {
                Button(l10n.text(isPending ? "localPending.restore" : "localPending.set"), action: togglePending)
            } label: { Image(systemName: isPending ? "pause.circle" : "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(.secondary)
                .help(l10n.text(isPending ? "localPending.restore" : "localPending.set"))
                .accessibilityLabel(l10n.text("localPending.actions", pr.title))
            Button(action: details) { Image(systemName: "chevron.right").font(.system(size: 11)).frame(width: 14, height: 36) }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help(l10n.text("detail.title")).accessibilityLabel(l10n.text("row.detailsAccessibility", pr.title))
        }.padding(.horizontal, 8).frame(height: 60)
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
            .task(id: copyFeedbackID) {
                guard copyFeedbackID != nil else { return }
                do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                withAnimation(.easeOut(duration: 0.15)) { copyFeedbackID = nil }
            }
            .onDisappear { copyFeedbackID = nil }
            .contextMenu {
                Button(l10n.text("row.copyReference", reference), action: copyReference)
                Button(l10n.text("common.openGitHub"), action: open)
                Button(l10n.text("common.details"), action: details)
                Divider()
                PRStarButton(store: store, pr: pr, showsTitle: true)
                Button(l10n.text(isPending ? "localPending.restore" : "localPending.set"), action: togglePending)
            }
    }
}
