import SwiftUI
import ReviewCore

struct SettingsPanel: View {
    @ObservedObject var store: AppStore
    private var l10n: L10n { store.l10n }
    @State private var drafts: [RepositoryScope]
    @State private var newOrganization = ""
    @State private var selectedTab: SettingsTab

    private enum SettingsTab: String, CaseIterable {
        case general, menuBar, repositories
        var titleKey: String { "settings.tab.\(rawValue)" }
    }

    init(store: AppStore) {
        self.store = store
        _drafts = State(initialValue: store.scopes)
        _selectedTab = State(initialValue: store.scope.isValid ? .general : .repositories)
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
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case .general: generalSettings
                    case .menuBar: menuBarSettings
                    case .repositories: repositorySettings
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            .id(selectedTab)
            if selectedTab == .repositories { repositorySaveBar }
        }
        .font(.system(size: 13))
        .task { for draft in drafts { store.loadRepositories(organization: draft.organization) } }
    }

    private var header: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                if store.scope.isValid {
                    Button { store.showSettings = false } label: {
                        Image(systemName: "chevron.left")
                    }.buttonStyle(.plain).help(l10n.text("common.back"))
                        .accessibilityLabel(l10n.text("common.back"))
                }
                Text(l10n.text("settings.title")).font(.system(size: 15, weight: .semibold))
                Spacer()
                if store.isDemo { Text("DEMO").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Picker(l10n.text("settings.title"), selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(l10n.text(tab.titleKey)).tag(tab)
                }
            }.pickerStyle(.segmented).labelsHidden()
        }.padding(18)
    }

    private var generalSettings: some View {
        Group {
            settingsSection("keyboard.title") {
                KeyboardSettingsView(settings: store.keyboard)
            }
            settingsSection("settings.section.app") {
                LoginItemSettingsView(isDemo: store.isDemo)
                Divider()
                settingRow("language.title") {
                    Picker(l10n.text("language.title"), selection: $store.language) {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            Text(language.title(in: l10n)).tag(language)
                        }
                    }
                }
                Divider()
                settingRow("settings.refresh") {
                    Picker(l10n.text("settings.refreshInterval"), selection: $store.refreshInterval) {
                        Text(l10n.text("settings.oneMinute")).tag(60)
                        Text(l10n.text("settings.twoMinutes")).tag(120)
                        Text(l10n.text("settings.fiveMinutes")).tag(300)
                    }
                }
            }
            settingsSection("settings.section.pullRequests") {
                settingRow("settings.incomingDefault") {
                    Picker(l10n.text("settings.defaultView"), selection: $store.defaultIncoming) {
                        Text(l10n.text("filter.pending")).tag("pending")
                        Text(l10n.text("filter.reviewed")).tag("done")
                        Text(l10n.text("common.all")).tag("all")
                    }
                }
                Divider()
                Toggle(l10n.text("settings.showCI"), isOn: $store.showCI).toggleStyle(.checkbox)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(l10n.text("settings.approveWithOneApproval"), isOn: $store.approveWithOneApproval)
                        .toggleStyle(.checkbox)
                    helpText("settings.approveWithOneApprovalHelp")
                }
            }
            helpText("settings.automaticSave")
        }
    }

    private var menuBarSettings: some View {
        Group {
            settingsSection("settings.section.counts") {
                settingRow("menu.title") {
                    Picker(l10n.text("menu.title"), selection: $store.menuBarStyle) {
                        ForEach(MenuBarStyle.allCases, id: \.self) { style in
                            Text(l10n.text(style.titleKey)).tag(style)
                        }
                    }
                }
                Divider()
                settingRow("menu.outgoingCount") {
                    Picker(l10n.text("menu.outgoingCount"), selection: $store.menuBarIncludesApproved) {
                        Text(l10n.text("menu.changesOnly")).tag(false)
                        Text(l10n.text("menu.changesAndApproved")).tag(true)
                    }
                }
                helpText(store.menuBarStyle.explanationKey(includesApproved: store.menuBarIncludesApproved))
                helpText("menu.countLimits")
            }
            settingsSection("settings.section.activity") {
                settingRow("activity.indicator.title") {
                    Picker(l10n.text("activity.indicator.title"), selection: $store.activityIndicatorStyle) {
                        ForEach(ActivityIndicatorStyle.allCases, id: \.self) { style in
                            Text(l10n.text(style.titleKey)).tag(style)
                        }
                    }
                }
                helpText("activity.help")
            }
            helpText("menu.immediate")
        }
    }

    private var repositorySettings: some View {
        Group {
            helpText("repositories.description")
            ForEach($drafts, id: \.organization) { $draft in
                let list = store.repositoryList(for: draft.organization)
                settingsCard {
                    RepositoryChecklist(scope: $draft, repositories: list.repositories,
                                        isLoading: list.isLoading, error: list.error)
                    Divider()
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
            }
            settingsSection("repositories.addPlaceholder") {
                HStack(spacing: 8) {
                    TextField(l10n.text("repositories.addPlaceholder"), text: $newOrganization)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                        .accessibilityLabel(l10n.text("repositories.addAccessibility"))
                        .onSubmit { addOrganization() }
                    Button(l10n.text("common.add"), action: addOrganization).disabled(!canAddOrganization)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                helpText("settings.access")
                DisclosureGroup(l10n.text("settings.authentication")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("gh auth login --hostname github.com")
                            .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        helpText("settings.authenticationHelp")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.font(.system(size: 12))
            }
        }
    }

    private var repositorySaveBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                helpText("settings.repositoriesSaveHelp")
                Spacer(minLength: 0)
                Button { store.save(drafts) } label: {
                    Text(l10n.text("settings.save"))
                }.buttonStyle(.borderedProminent)
                    .disabled(drafts.isEmpty || !drafts.allSatisfy(\.isValid))
            }.padding(18)
        }
    }

    private func settingsSection<Content: View>(_ titleKey: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.text(titleKey)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            settingsCard(content: content)
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
    }

    private func settingRow<Control: View>(_ titleKey: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(l10n.text(titleKey)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            control().labelsHidden().frame(width: 210)
        }
    }

    private func helpText(_ key: String) -> some View {
        Text(l10n.text(key)).font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
