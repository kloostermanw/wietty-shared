import Testing
@testable import ItermplexShared

@Suite struct RemoteChecksTests {
    private func checks(passing: Int = 0, failing: Int = 0, cancelled: Int = 0,
                        skipped: Int = 0, pending: Int = 0) -> RemoteChecks {
        RemoteChecks(passing: passing, failing: failing, cancelled: cancelled,
                     skipped: skipped, pending: pending, summary: "")
    }

    @Test func allPassingIsPassed() {
        #expect(checks(passing: 3).status == .passed)
    }

    @Test func noChecksAtAllIsPassed() {
        #expect(checks().status == .passed)
    }

    @Test func pendingIsRunning() {
        #expect(checks(passing: 1, pending: 2).status == .running)
    }

    @Test func failingBeatsPending() {
        #expect(checks(failing: 1, pending: 2).status == .failed)
    }

    @Test func cancelledCountsAsAFailure() {
        #expect(checks(cancelled: 1).status == .failed)
        #expect(checks(cancelled: 1).hasFailures)
    }

    @Test func skippedAloneIsNotAFailure() {
        #expect(checks(skipped: 4).status == .passed)
        #expect(!checks(skipped: 4).hasFailures)
    }
}
