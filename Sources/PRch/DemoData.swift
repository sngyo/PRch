import Foundation
import ReviewCore

/// Entirely synthetic data for screenshots and development. No network access in --demo mode.
enum DemoData {
    static var repositories: [Repository] {
        Set(snapshot.pullRequests.map(\.repository)).sorted().map { Repository(name: $0) }
    }

    static var beforeActivity: ReviewSnapshot {
        var previous = snapshot
        previous.pullRequests.removeAll { [26, 16].contains($0.number) }
        for index in previous.pullRequests.indices {
            if previous.pullRequests[index].number == 35 { previous.pullRequests[index].incomingStatus = .approved }
            if previous.pullRequests[index].number == 31 { previous.pullRequests[index].outgoingStatus = .waiting }
        }
        return previous
    }

    static var snapshot: ReviewSnapshot {
        let specs: [(Int, String, String, String, ReviewStatus, Bool)] = [
            (42, "sample-web", "一覧の並び順を保存する", "alex", .waiting, false),
            (35, "sample-web", "検索結果が空のときの表示を修正", "sam", .rereview, false),
            (38, "sample-web", "読み込み中の表示を追加", "kai", .waiting, false),
            (16, "sample-docs", "セットアップ手順の説明を追加", "ren", .waiting, false),
            (13, "sample-docs", "サンプルコードの誤字を修正", "sam", .waiting, false),
            (26, "sample-api", "一覧取得にページネーションを追加", "alex", .waiting, false),
            (24, "sample-api", "入力値の検証メッセージを改善", "kai", .approved, false),
            (29, "sample-web", "ボタンのフォーカス表示を改善", "ren", .changes, false),
            (9, "sample-docs", "見出しと目次の構成を整理", "alex", .commented, false),
            (40, "sample-web", "キーボード操作の案内を追加", "you", .waiting, true),
            (31, "sample-web", "フッターの余白を調整", "you", .changes, true),
            (14, "sample-docs", "よくある質問を追加", "you", .waiting, true),
            (19, "sample-api", "レスポンス形式のテストを追加", "you", .approved, true)
        ]
        return ReviewSnapshot(login: "you", pullRequests: specs.enumerated().map { offset, spec in
            let (number, repo, title, author, status, own) = spec
            let reviewers = own ? [Reviewer(name: "alex", status: status == .changes ? .changes : .approved), Reviewer(name: "sam", status: status == .approved ? .approved : .waiting)] : [Reviewer(name: "you", status: status)]
            return PullRequest(id: "demo-\(repo)-\(number)", number: number, title: title,
                               url: URL(string: "https://github.com")!, repository: repo, author: author,
                               updatedAt: Date().addingTimeInterval(-Double((offset + 1) * 1_200)), reviewers: reviewers,
                               incomingStatus: own ? nil : status, outgoingStatus: status, isAuthored: own,
                               checkState: status == .changes ? "FAILURE" : "SUCCESS", repositoryOwner: "example-org")
        })
    }
}
