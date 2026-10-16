import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let repositoryOrder = UTType(exportedAs: "dev.prch.repository-order", conformingTo: .data)
}

struct RepositoryDragItem: Codable, Transferable {
    let repositoryID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .repositoryOrder)
    }

    var itemProvider: NSItemProvider {
        let data = try? JSONEncoder().encode(self)
        return NSItemProvider(item: data as NSData?, typeIdentifier: UTType.repositoryOrder.identifier)
    }
}

struct RepositoryHeader: View {
    @Environment(\.l10n) private var l10n
    let repositoryID: String
    let name: String
    let count: Int
    let activity: String
    let isCollapsed: Bool
    let toggle: () -> Void
    let move: @MainActor @Sendable (String) -> Bool
    @State private var isDropTarget = false
    @FocusState private var isFocused: Bool

    var body: some View {
        content
            .onTapGesture(perform: toggle)
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(.space) { toggle(); return .handled }
            .onKeyPress(.return) { toggle(); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
            .help(l10n.text(isCollapsed ? "repositories.expandHelp" : "repositories.collapseHelp"))
            .accessibilityLabel(Text(l10n.text("repositories.groupAccessibility", name, count)))
            .accessibilityValue(Text(l10n.text(isCollapsed ? "repositories.collapsed" : "repositories.expanded")))
            .accessibilityHint(Text(l10n.text(isCollapsed ? "repositories.expandHelp" : "repositories.collapseHelp")))
            .onDrop(of: [.repositoryOrder], delegate: RepositoryDropDelegate(isTargeted: $isDropTarget, move: move))
    }

    private var content: some View {
        HStack(spacing: 5) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .semibold)).frame(width: 8)
            Image(systemName: "folder")
            Text(name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if !activity.isEmpty {
                Text(activity).foregroundStyle(Palette.green).font(.system(size: 9)).fixedSize()
            }
            Text(l10n.text("list.count", count)).foregroundStyle(.tertiary).fixedSize()
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
        }.font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isDropTarget ? Palette.green : isFocused ? Color.secondary.opacity(0.45) : .clear,
                                  lineWidth: isDropTarget ? 1.5 : 1)
            }
            .contentShape(Rectangle())
            .onDrag {
                RepositoryDragItem(repositoryID: repositoryID).itemProvider
            } preview: {
                Label(name, systemImage: "folder").font(.system(size: 11, weight: .medium))
                    .padding(8).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            }
    }
}

private struct RepositoryDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let move: @MainActor @Sendable (String) -> Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.repositoryOrder]) }
    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [.repositoryOrder])
        guard providers.count == 1, let provider = providers.first else { return false }
        _ = provider.loadTransferable(type: RepositoryDragItem.self) { [move] result in
            guard case .success(let item) = result else { return }
            Task { @MainActor in _ = move(item.repositoryID) }
        }
        return true
    }
}
