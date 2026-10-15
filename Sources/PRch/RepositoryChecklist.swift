import SwiftUI
import ReviewCore

struct RepositoryChecklist: View {
    @Environment(\.l10n) private var l10n
    @Binding var scope: RepositoryScope
    var repositories: [Repository]
    var isLoading: Bool
    var error: ReviewError?
    @State private var query = ""

    private var known: [Repository] {
        let missing = scope.configuredRepositories.filter { name in
            !repositories.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        return (repositories + missing.map { Repository(name: $0) })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var visible: [Repository] {
        known.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var selectedCount: Int { known.filter { scope.contains(owner: scope.organization, name: $0.name) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "building.2").foregroundStyle(.secondary)
                Text(scope.organization).fontWeight(.medium).lineLimit(1)
                Spacer()
                MixedCheckbox(title: l10n.text("common.all"), state: scope.selectionState(repositoryNames: known.map(\.name))) {
                    scope.setAllIncluded(scope.selectionState(repositoryNames: known.map(\.name)) != .all)
                }.fixedSize().disabled(isLoading || error != nil || known.isEmpty)
                    .help(l10n.text("repositories.allHelp"))
            }.font(.system(size: 11))
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(l10n.text("repositories.search"), text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help(l10n.text("common.clearSearch"))
                }
            }.font(.system(size: 10))
            Group {
                if isLoading {
                    HStack { ProgressView().controlSize(.small); Text(l10n.text("repositories.loading")) }
                } else if let error {
                    Text(l10n.error(error)).foregroundStyle(Palette.amber).padding(8)
                } else if visible.isEmpty {
                    Text(query.isEmpty ? l10n.text("repositories.empty") : l10n.text("repositories.noMatch"))
                        .foregroundStyle(.secondary).padding(8)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visible) { repo in
                                Toggle(isOn: Binding(
                                    get: { scope.contains(owner: scope.organization, name: repo.name) },
                                    set: { scope.setIncluded($0, repository: repo.name) }
                                )) {
                                    HStack(spacing: 5) {
                                        Text(repo.name).lineLimit(1).help(repo.name)
                                        if repo.isPrivate { Image(systemName: "lock").font(.system(size: 8)).foregroundStyle(.tertiary) }
                                    }
                                }.toggleStyle(.checkbox).font(.system(size: 11)).padding(.vertical, 5)
                                    .accessibilityLabel("\(scope.organization)/\(repo.name)")
                            }
                        }.padding(8)
                    }
                }
            }.font(.system(size: 10)).frame(maxWidth: .infinity).frame(height: 168)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            if !isLoading, error == nil {
                Text(l10n.text("repositories.count", selectedCount, known.count))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(scope.mode == .all || scope.includeUnspecifiedRepositories
                     ? l10n.text("repositories.newAutomatic")
                     : l10n.text("repositories.newManual"))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// AppKit supplies the standard macOS mixed-state checkbox for an organization.
private struct MixedCheckbox: NSViewRepresentable {
    var title: String
    var state: RepositorySelectionState
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.toggle))
        button.allowsMixedState = true
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        button.state = state == .all ? .on : state == .some ? .mixed : .off
        button.isEnabled = isEnabled
        context.coordinator.action = action
    }
    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func toggle() { action() }
    }
}
