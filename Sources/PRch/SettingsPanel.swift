import SwiftUI
import ReviewCore

struct SettingsPanel: View {
    @ObservedObject var store: AppStore
    private var l10n: L10n { store.l10n }
    @State private var drafts: [RepositoryScope]
    @State private var newOrganization = ""

    init(store: AppStore) {
        self.store = store
        _drafts = State(initialValue: store.scopes)
    }
    private var organizationToAdd: String { newOrganization.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAddOrganization: Bool {
        RepositoryScope(organization: organizationToAdd).isValid &&
        !drafts.contains { $0.organization.caseInsensitiveCompare(organizationToAdd) == .orderedSame }
    }
    private func addOrganization() {
        guard canAddOrganization else { return }
        let organization = organizationToAdd
        drafts.append(RepositoryScope(organization: organization))
        newOrganization = ""
        store.loadRepositories(organization: organization)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if store.scope.isValid {
                    Button { store.showSettings = false } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).help(l10n.text("common.back"))
                }
                Text(l10n.text("settings.title")).font(.system(size: 15, weight: .semibold))
                Spacer()
                if store.isDemo { Text("DEMO").font(.system(size: 11)).foregroundStyle(.secondary) }
            }.padding(17)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(l10n.text("language.title")).fontWeight(.medium)
                            Spacer()
                            Picker(l10n.text("language.title"), selection: $store.language) {
                                ForEach(AppLanguage.allCases, id: \.self) { language in
                                    Text(language.title(in: l10n)).tag(language)
                                }
                            }.labelsHidden().frame(width: 210)
                        }
                        Text(l10n.text("language.help")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }.font(.system(size: 13))
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text(l10n.text("repositories.title")).font(.system(size: 14, weight: .medium))
                        Text(l10n.text("repositories.description"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        ForEach($drafts, id: \.organization) { $draft in
                            let list = store.repositoryList(for: draft.organization)
                            VStack(alignment: .leading, spacing: 8) {
                                RepositoryChecklist(scope: $draft, repositories: list.repositories,
                                                    isLoading: list.isLoading, error: list.error)
                                HStack {
                                    Button(l10n.text("common.reload")) { store.loadRepositories(organization: draft.organization) }
                                        .disabled(list.isLoading)
                                    Spacer()
                                    Button(l10n.text("repositories.remove")) {
                                        let organization = draft.organization
                                        drafts.removeAll { $0.organization == organization }
                                    }
                                }.font(.system(size: 12)).buttonStyle(.borderless)
                            }
                            Divider()
                        }
                        HStack {
                            TextField(l10n.text("repositories.addPlaceholder"), text: $newOrganization).textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled().accessibilityLabel(l10n.text("repositories.addAccessibility"))
                                .onSubmit { addOrganization() }
                            Button(l10n.text("common.add"), action: addOrganization).disabled(!canAddOrganization)
                        }.font(.system(size: 13))
                        Text(l10n.text("settings.access"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(l10n.text("menu.title")).fontWeight(.medium)
                            Spacer()
                            Picker(l10n.text("menu.title"), selection: $store.menuBarStyle) {
                                ForEach(MenuBarStyle.allCases, id: \.self) { style in
                                    Text(l10n.text(style.titleKey)).tag(style)
                                }
                            }.labelsHidden().frame(width: 210)
                        }
                        HStack(spacing: 12) {
                            Text(l10n.text("menu.preview")).foregroundStyle(.secondary)
                            MenuBarIndicator(style: store.menuBarStyle, reviews: 12, changes: 1, unread: 3, activityStyle: store.activityIndicatorStyle)
                                .font(.system(size: 13)).padding(.horizontal, 9).padding(.vertical, 5)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityLabel(l10n.text("menu.sample"))
                        }
                        Text(l10n.text(store.menuBarStyle.explanationKey)).foregroundStyle(.secondary)
                        HStack {
                            Text(l10n.text("activity.indicator.title"))
                            Spacer()
                            Picker(l10n.text("activity.indicator.title"), selection: $store.activityIndicatorStyle) {
                                ForEach(ActivityIndicatorStyle.allCases, id: \.self) { style in
                                    Text(l10n.text(style.titleKey)).tag(style)
                                }
                            }.labelsHidden().frame(width: 150)
                        }
                        Text(l10n.text("activity.help")).font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(l10n.text("menu.immediate"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }.font(.system(size: 13))
                    Divider()
                    VStack(spacing: 12) {
                        HStack {
                            Text(l10n.text("settings.incomingDefault"))
                            Spacer()
                            Picker(l10n.text("settings.defaultView"), selection: $store.defaultIncoming) {
                                Text(l10n.text("filter.pending")).tag("pending"); Text(l10n.text("filter.reviewed")).tag("done"); Text(l10n.text("common.all")).tag("all")
                            }.labelsHidden().frame(width: 150)
                        }
                        HStack {
                            Text(l10n.text("settings.refresh"))
                            Spacer()
                            Picker(l10n.text("settings.refreshInterval"), selection: $store.refreshInterval) {
                                Text(l10n.text("settings.oneMinute")).tag(60); Text(l10n.text("settings.twoMinutes")).tag(120); Text(l10n.text("settings.fiveMinutes")).tag(300)
                            }.labelsHidden().frame(width: 150)
                        }
                        Toggle(l10n.text("settings.showCI"), isOn: $store.showCI).toggleStyle(.checkbox)
                    }.font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(l10n.text("settings.authentication")).font(.system(size: 12, weight: .medium))
                        Text("gh auth login --hostname github.com").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        Text(l10n.text("settings.authenticationHelp"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.padding(18)
            }
            Divider()
            Button { store.save(drafts) } label: {
                Text(l10n.text("settings.save")).font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).disabled(drafts.isEmpty || !drafts.allSatisfy(\.isValid)).padding(16)
        }
        .task { for draft in drafts { store.loadRepositories(organization: draft.organization) } }
    }

}
