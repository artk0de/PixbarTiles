import Foundation

/// A connector whose place in the clock's loop depends on which Focus is on.
///
/// A pair rather than a protocol conformance, and the pairing is the point:
/// `PixelClockKit` does not know what a Focus is and must not learn. The
/// connector carries a closure it cannot interpret, and this is where the
/// closure and the connector's name are held together so that a change of Focus
/// can act on both — deliver the one that now belongs, retract the one that no
/// longer does.
struct FocusGatedConnector: Sendable {
    let id: String
    /// Whether it belongs on the clock under the Focus that is on right now.
    let shows: @Sendable () -> Bool
}
