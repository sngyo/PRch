import CryptoKit
import Foundation
import ReviewCore

enum PRActivityKind: String, Codable, Sendable {
    case new, updated
    var labelKey: String { self == .new ? "activity.new" : "activity.updated" }
}

struct PRActivity: Codable, Equatable, Sendable {
    var kind: PRActivityKind
    var revision = UUID()
}

struct ActivityReceipt: Hashable, Sendable {
    var account: String
    var prID: String
    var revision: UUID
}

/// Persist only opaque IDs, state digests and activity markers, never PR content.
struct ActivityTracker: Codable {
    struct Record: Codable {
        var fingerprint: String
        var activity: PRActivity?
    }
    struct Account: Codable {
        var scopeDigest: String
        var records: [String: Record] = [:]
    }
    private(set) var accounts: [String: Account] = [:]

    static func digest(_ parts: [String]) -> String {
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint(_ pr: PullRequest) -> String {
        if !pr.isAuthored { return digest(["incoming", pr.incomingStatus?.rawValue ?? "none"]) }
        // A human approval matters even if another reviewer keeps the overall status waiting.
        return digest(["outgoing", pr.outgoingStatus.rawValue] + pr.reviewers.filter { !$0.isBot }
            .map { "\($0.id):\($0.status.rawValue)" }.sorted())
    }

    static func scopeDigest(_ scopes: [RepositoryScope]) -> String {
        digest(scopes.map { scope in
            digest([scope.organization.lowercased(), scope.mode.rawValue, String(scope.includeUnspecifiedRepositories)] +
                   scope.includedRepositories.map { "include:\($0.lowercased())" }.sorted() +
                   scope.excludedRepositories.map { "exclude:\($0.lowercased())" }.sorted())
        }.sorted())
    }

    mutating func ingest(_ snapshot: ReviewSnapshot, scopes: [RepositoryScope], pendingIDs: Set<String>) {
        let login = snapshot.login.lowercased(), scope = Self.scopeDigest(scopes)
        let baselineNewIDs = accounts[login]?.scopeDigest != scope
        var account = accounts[login] ?? Account(scopeDigest: scope)
        for pr in snapshot.pullRequests {
            let fingerprint = Self.fingerprint(pr)
            var activity = account.records[pr.id]?.activity
            // Clear own-PR NEW markers persisted by earlier versions before detecting review changes.
            if pr.isAuthored && activity?.kind == .new { activity = nil }
            if let previous = account.records[pr.id] {
                if previous.fingerprint != fingerprint {
                    activity = PRActivity(kind: activity?.kind == .new ? .new : .updated)
                }
            } else if !baselineNewIDs && !pr.isAuthored && pr.incomingStatus?.needsReview == true {
                activity = PRActivity(kind: .new)
            }
            if pendingIDs.contains(pr.id) { activity = nil }
            account.records[pr.id] = Record(fingerprint: fingerprint, activity: activity)
        }
        account.scopeDigest = scope
        accounts[login] = account
    }

    func activity(for id: String, account: String) -> PRActivity? {
        accounts[account.lowercased()]?.records[id]?.activity
    }

    mutating func acknowledge(_ receipts: Set<ActivityReceipt>) {
        for receipt in receipts {
            let login = receipt.account.lowercased()
            guard accounts[login]?.records[receipt.prID]?.activity?.revision == receipt.revision else { continue }
            accounts[login]?.records[receipt.prID]?.activity = nil
        }
    }

    mutating func clear(id: String, account: String) {
        accounts[account.lowercased()]?.records[id]?.activity = nil
    }
}
