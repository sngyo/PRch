import SwiftUI
import ReviewCore

struct ReviewPanel: View {
    @ObservedObject var store: AppStore
    private var l10n: L10n { store.l10n }
    var openWindow: () -> Void = {}
    @State private var tab = "incoming"
    @State private var filter = "pending"
    @State private var query = ""
    @State private var selectedRepository = "all"
    @State private var detail: PullRequest?

    private var source: [PullRequest] { tab == "incoming" ? store.incoming : store.outgoing }
    private func repositoryName(_ pr: PullRequest) -> String {
        store.scopes.count > 1 ? pr.repositoryFullName : pr.repository
    }
    private var searched: [PullRequest] {
        source.filter { pr in
            (selectedRepository == "all" || repositoryName(pr) == selectedRepository) &&
            (query.isEmpty || "\(pr.title) \(pr.number) \(pr.repositoryFullName) \(pr.author)".localizedCaseInsensitiveContains(query))
        }
    }
    private func matches(_ pr: PullRequest, filter: String) -> Bool {
        let status = tab == "incoming" ? pr.incomingStatus : pr.outgoingStatus
        switch filter {
        case "all": return true
        case "pending": return status?.needsReview == true
        case "done": return status?.needsReview == false
        case "waiting": return status == .waiting || status == .required
        default: return status?.rawValue == filter
        }
    }
    private var filtered: [PullRequest] { searched.filter { matches($0, filter: filter) } }
    private var repositoryNames: [String] { Set(source.map(repositoryName)).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    private var groups: [(name: String, prs: [PullRequest])] {
        Dictionary(grouping: filtered, by: repositoryName).map { name, prs in
            (name, prs.sorted {
                let a = (tab == "incoming" ? $0.incomingStatus : $0.outgoingStatus)?.priority ?? 9
                let b = (tab == "incoming" ? $1.incomingStatus : $1.outgoingStatus)?.priority ?? 9
                return a == b ? $0.updatedAt > $1.updatedAt : a < b
            })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
        .onAppear { filter = tab == "incoming" ? store.defaultIncoming : "all" }
        .onChange(of: store.scopes) { _, _ in selectedRepository = "all"; detail = nil }
        .onChange(of: repositoryNames) { _, names in
            if selectedRepository != "all", !names.contains(selectedRepository) { selectedRepository = "all" }
        }
    }

    private var mainPanel: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 22) {
                tabButton("incoming", l10n.text("tab.incoming"), "tray", store.incoming.count)
                tabButton("outgoing", l10n.text("tab.outgoing"), "paperplane", store.outgoing.count)
                Spacer()
            }.padding(.horizontal, 17)
            Divider().padding(.horizontal, 16)
            filters
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
            tab = id; filter = id == "incoming" ? store.defaultIncoming : "all"; selectedRepository = "all"
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
                Text("\(count)").font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 2)
                    .background((tab == id ? Palette.green : Color.secondary).opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
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
                Picker(l10n.text("repositories.picker"), selection: $selectedRepository) {
                    Text(l10n.text("repositories.all")).tag("all")
                    ForEach(repositoryNames, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().pickerStyle(.menu).fixedSize().frame(maxWidth: 190)
            }.font(.system(size: 10))
        }.padding(.horizontal, 16).padding(.top, 11).padding(.bottom, 9)
    }

    private func chip(_ id: String, _ title: String) -> some View {
        Button { filter = id } label: {
            HStack(spacing: 4) {
                Text(title)
                Text("\(searched.filter { matches($0, filter: id) }.count)").font(.system(size: 9)).opacity(0.75)
            }.font(.system(size: 10, weight: filter == id ? .medium : .regular))
                .foregroundStyle(filter == id ? Palette.green : Color.secondary)
                .padding(.horizontal, 7).padding(.vertical, 6)
                .background(filter == id ? Palette.green.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).accessibilityAddTraits(filter == id ? .isSelected : [])
    }

    private var list: some View {
        ScrollView {
            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: store.isRefreshing ? "arrow.clockwise" : "tray").font(.system(size: 25)).foregroundStyle(Palette.green)
                    Text(store.snapshot == nil && store.isRefreshing ? l10n.text("connection.loading") : store.snapshot == nil && store.error != nil ? l10n.text("connection.empty") : l10n.text("list.noMatch")).font(.system(size: 12, weight: .medium))
                    Text(store.scopes.allSatisfy(\.isEmptySelection) ? l10n.text("list.selectRepositories") : l10n.text("list.checkFilters"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                LazyVStack(spacing: 7, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups, id: \.name) { group in
                        Section {
                            VStack(spacing: 0) {
                                ForEach(group.prs) { pr in
                                    PRRow(pr: pr, incoming: tab == "incoming", showCI: store.showCI,
                                          open: { store.open(pr.url) }, details: { detail = pr })
                                }
                            }
                        } header: {
                            HStack(spacing: 5) {
                                Image(systemName: "folder")
                                Text(group.name).fontWeight(.medium)
                                Spacer()
                                Text(l10n.text("list.count", group.prs.count)).foregroundStyle(.tertiary)
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }
        }.frame(maxHeight: .infinity)
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
            Menu {
                Button(l10n.text("common.openWindow"), action: openWindow)
                Button(l10n.text("settings.openMenu")) { store.showSettings = true }
                Divider()
                Button(l10n.text("common.quit")) { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help(l10n.text("common.more"))
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
                        Text(pr.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 2)
                        Text(l10n.age(pr.updatedAt)).font(.system(size: 9)).foregroundStyle(.tertiary).fixedSize()
                    }
                    HStack(spacing: 6) {
                        Text(verbatim: "#\(pr.number)").foregroundStyle(.tertiary)
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
            Button(action: details) { Image(systemName: "chevron.right").font(.system(size: 9)).frame(width: 14, height: 36) }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help(l10n.text("detail.title")).accessibilityLabel(l10n.text("row.detailsAccessibility", pr.title))
        }.padding(.horizontal, 8).frame(height: 50)
            .background(hovered ? Color.primary.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovered = $0 }
            .contextMenu { Button(l10n.text("common.openGitHub"), action: open); Button(l10n.text("common.details"), action: details) }
    }
}
