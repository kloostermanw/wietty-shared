/// Whether this viewer's claim is the grid in force, as far as it can know.
///
/// Not a comparison of grids: with two claims in flight the answer to the first names
/// a grid that is no longer this viewer's, and a viewer that concluded from that it had
/// lost the grid would stop following its own window halfway through a drag.
public struct GridOwnership: Equatable, Sendable {
    private var unanswered = 0
    private var lastWasOwn = false

    public init() {}

    public var isOwner: Bool { unanswered > 0 || lastWasOwn }

    /// A claim went out.
    public mutating func claimSent() { unanswered += 1 }

    /// The server announced a grid.
    public mutating func resizeReceived(own: Bool) {
        if own { unanswered = max(0, unanswered - 1) }
        lastWasOwn = own
    }
}
