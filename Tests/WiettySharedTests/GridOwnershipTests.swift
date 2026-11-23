import Testing
@testable import WiettyShared

struct GridOwnershipTests {
    @Test func aNewViewerOwnsNothing() {
        #expect(GridOwnership().isOwner == false)
    }

    @Test func aViewerWithAClaimInFlightIsTheOwner() {
        var ownership = GridOwnership()
        ownership.claimSent()
        #expect(ownership.isOwner)
    }

    /// The window drag the first design lost: two claims out, the first answered.
    @Test func twoClaimsInFlightAndOneAnsweredStillOwns() {
        var ownership = GridOwnership()
        ownership.claimSent(); ownership.claimSent()
        ownership.resizeReceived(own: true)
        #expect(ownership.isOwner)
        ownership.resizeReceived(own: true)
        #expect(ownership.isOwner)
    }

    @Test func anotherViewersClaimAfterMineTakesOwnershipAway() {
        var ownership = GridOwnership()
        ownership.claimSent()
        ownership.resizeReceived(own: true)
        ownership.resizeReceived(own: false)
        #expect(ownership.isOwner == false)
    }

    /// The server handled theirs first and mine second, so mine is in force.
    @Test func anotherViewersClaimBeforeMineLeavesMeTheOwner() {
        var ownership = GridOwnership()
        ownership.claimSent()
        ownership.resizeReceived(own: false)
        #expect(ownership.isOwner)
        ownership.resizeReceived(own: true)
        #expect(ownership.isOwner)
    }

    @Test func anAnswerNobodyAskedForDoesNotGoBelowZero() {
        var ownership = GridOwnership()
        ownership.resizeReceived(own: true)
        ownership.resizeReceived(own: false)
        ownership.claimSent()
        #expect(ownership.isOwner)
    }

    /// The server answers every claim with one own resize, and a value is one connection's.
    @Test func anotherViewersClaimBetweenMyAnswersDoesNotCostOwnershipEarly() {
        var ownership = GridOwnership()
        ownership.claimSent(); ownership.claimSent()
        ownership.resizeReceived(own: true)
        ownership.resizeReceived(own: false)
        #expect(ownership.isOwner)
        ownership.resizeReceived(own: true)
        #expect(ownership.isOwner)
        ownership.resizeReceived(own: false)
        #expect(ownership.isOwner == false)
    }
}
