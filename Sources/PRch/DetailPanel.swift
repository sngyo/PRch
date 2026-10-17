import SwiftUI
import ReviewCore

struct DetailPanel: View {
    let pr: PullRequest
    @ObservedObject var store: AppStore
    private var l10n: L10n { store.l10n }
    let back: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button(action: back) { Image(systemName: "chevron.left") }.buttonStyle(.plain).help(l10n.text("common.back"))
                Text(l10n.text("detail.title")).font(.system(size: 14, weight: .semibold))
                Spacer()
                if pr.isPrivate { Image(systemName: "lock").foregroundStyle(.secondary) }
            }.padding(17)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: "\(pr.repositoryFullName) #\(pr.number)").font(.system(size: 13)).foregroundStyle(.secondary)
                        Text(pr.title).font(.system(size: 19, weight: .semibold)).textSelection(.enabled)
                        HStack {
                            StatusBadge(status: pr.isAuthored ? store.outgoingStatus(for: pr) : pr.incomingStatus ?? .waiting)
                            if pr.isDraft { Text(l10n.text("common.draft")).font(.system(size: 12)).foregroundStyle(.secondary) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            store.setPending(!store.isPending(pr), for: pr)
                        } label: {
                            Label(l10n.text(store.isPending(pr) ? "localPending.restore" : "localPending.set"),
                                  systemImage: store.isPending(pr) ? "play.circle" : "pause.circle")
                        }.buttonStyle(.bordered)
                        Text(l10n.text("localPending.help")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(l10n.text("detail.reviews")).font(.system(size: 12)).foregroundStyle(.secondary)
                        if pr.reviewers.isEmpty { Text(l10n.text("detail.noReviewers")).font(.system(size: 13)).foregroundStyle(.secondary) }
                        ForEach(pr.reviewers) { reviewer in
                            HStack {
                                Image(systemName: reviewer.isTeam ? "person.2" : reviewer.isBot ? "gearshape" : "person.crop.circle").foregroundStyle(.secondary)
                                Text(reviewer.name).font(.system(size: 14)).textSelection(.enabled)
                                Spacer()
                                StatusBadge(status: reviewer.status)
                            }.padding(.vertical, 5)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(l10n.text("detail.author")).font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack(spacing: 7) { Avatar(name: pr.author); Text(pr.author).font(.system(size: 14)) }
                    }
                    if store.showCI {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(l10n.text("detail.checks")).font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(l10n.text("detail.ci", pr.checkState ?? l10n.text("detail.noChecks"))).font(.system(size: 13))
                            if pr.mergeable == "CONFLICTING" { Text(l10n.text("detail.conflicts")).font(.system(size: 13)).foregroundStyle(Palette.amber) }
                        }
                    }
                    Text(l10n.text("time.updated", l10n.age(pr.updatedAt))).font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            Divider()
            Button { store.open(pr.url) } label: {
                Label(l10n.text("common.openGitHub"), systemImage: "arrow.up.right").frame(maxWidth: .infinity).padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).padding(16)
        }
    }
}
