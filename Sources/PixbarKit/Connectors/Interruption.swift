import Foundation

/// A scene that takes over the clock for a while and then gives it back — a
/// celebration riding on an ordinary delivery.
///
/// Carried on `Delivery` rather than sent on its own, because the thing that
/// knows a celebration is due is the read that produced the reading: one read
/// that brings new stars AND a fork carries both, in the order they play.
///
/// What "takes over" means is the clock model's business. The TC002 has no
/// notification surface, so its session overwrites pages and restores them
/// from its board afterwards; an AWTRIX clock queues a notification, which
/// goes away by itself.
public struct Interruption<Scene: Sendable & Equatable>: Sendable, Equatable {
    /// Which pages the TC002 overwrites. An AWTRIX clock ignores it: its
    /// notification covers whatever is on screen, whichever app that is.
    public enum Scope: Sendable, Equatable {
        /// Every page on the clock, so the knob lands on it wherever it is.
        case everyPage
        /// Only the delivering tile's own page.
        case ownPage
    }

    public var scene: Scene
    public var scope: Scope
    /// Seconds the scene holds its pages before the next entry, or the
    /// restore, takes over.
    public var duration: TimeInterval

    public init(scene: Scene, scope: Scope, duration: TimeInterval) {
        self.scene = scene
        self.scope = scope
        self.duration = duration
    }
}
