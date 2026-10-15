import SwiftUI
import ReviewCore

enum MenuBarStyle: String, CaseIterable {
    case separateCounts, reviewCount, total, dot

    var titleKey: String {
        switch self {
        case .separateCounts: "menu.separateTitle"
        case .reviewCount: "menu.reviewTitle"
        case .total: "menu.totalTitle"
        case .dot: "menu.dotTitle"
        }
    }

    var explanationKey: String {
        switch self {
        case .separateCounts: "menu.separateHelp"
        case .reviewCount: "menu.reviewHelp"
        case .total: "menu.totalHelp"
        case .dot: "menu.dotHelp"
        }
    }
}

struct MenuBarIndicator: View {
    let style: MenuBarStyle
    let reviews: Int
    let changes: Int

    private func count(_ value: Int) -> String { value > 99 ? "99+" : String(value) }
    private var separateLabel: String {
        [reviews > 0 ? "↓\(count(reviews))" : nil, changes > 0 ? "↑\(count(changes))" : nil]
            .compactMap { $0 }.joined(separator: " │ ")
    }

    var body: some View {
        HStack(spacing: 4) {
            BrandMark()
            switch style {
            case .separateCounts:
                if !separateLabel.isEmpty { Text(verbatim: separateLabel).monospacedDigit() }
            case .reviewCount:
                if reviews > 0 { Text(verbatim: count(reviews)).monospacedDigit() }
                if changes > 0 { dot }
            case .total:
                if reviews + changes > 0 { Text(verbatim: count(reviews + changes)).monospacedDigit() }
            case .dot:
                if reviews + changes > 0 { dot }
            }
        }
    }

    private var dot: some View {
        Image(systemName: "circle.fill").font(.system(size: 5))
    }
}

enum Palette {
    static let green = Color(red: 0.29, green: 0.54, blue: 0.36)
    static let amber = Color(red: 0.66, green: 0.47, blue: 0.20)
    static let blue = Color(red: 0.34, green: 0.50, blue: 0.68)
}

extension ReviewStatus {
    var labelKey: String {
        switch self {
        case .waiting: "filter.waiting"
        case .rereview: "status.rereview"
        case .approved: "filter.approved"
        case .changes: "status.changes"
        case .commented: "status.commented"
        case .dismissed: "status.dismissed"
        case .required: "status.required"
        case .unrequested: "filter.unrequested"
        }
    }
    var symbol: String {
        switch self {
        case .waiting, .required: "clock"
        case .rereview: "arrow.triangle.2.circlepath"
        case .approved: "checkmark"
        case .changes, .commented: "text.bubble"
        case .dismissed: "minus.circle"
        case .unrequested: "person.badge.plus"
        }
    }
    var color: Color {
        switch self {
        case .approved: Palette.green
        case .rereview, .commented: Palette.blue
        case .unrequested, .dismissed: .secondary
        default: Palette.amber
        }
    }
}

struct StatusBadge: View {
    @Environment(\.l10n) private var l10n
    let status: ReviewStatus
    var label: String? = nil
    var body: some View {
        Label(label ?? l10n.text(status.labelKey), systemImage: status.symbol)
            .font(.system(size: 9)).foregroundStyle(status.color)
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(status.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

struct Avatar: View {
    let name: String
    var url: URL? = nil
    var size: CGFloat = 15
    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else { initials }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .accessibilityHidden(true)
    }
    private var initials: some View {
        Text(String(name.prefix(2)).uppercased())
            .font(.system(size: size * 0.46, weight: .medium)).foregroundStyle(Palette.green)
            .frame(width: size, height: size)
            .background(Palette.green.opacity(0.12), in: Circle())
    }
}
