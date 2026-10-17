import Foundation
import ReviewCore

/// Injectable time keeps retry and cancellation tests independent of real waits.
@MainActor
struct RefreshTiming {
    var now: () -> Date = { Date() }
    var sleep: (TimeInterval) async throws -> Void = { delay in
        try await Task.sleep(for: .seconds(delay))
    }

    static func delay(interval: Int, failure: ReviewError?, failureCount: Int) -> TimeInterval {
        let interval = TimeInterval(max(60, interval))
        guard let failure else { return interval }
        let failures = min(4, max(1, failureCount))
        if failure == .network || failure == .timedOut {
            return min(60, 10 * Double(1 << (failures - 1)))
        }
        // Authentication, rate limits and API errors retain a slower backoff.
        return min(1_800, interval * Double(1 << failures))
    }
}
