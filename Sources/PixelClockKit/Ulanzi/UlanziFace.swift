import Foundation

/// TC002 counterpart of `AwtrixDelivery` (AwtrixScene.swift, phase 2).
public typealias UlanziDelivery = Delivery<UlanziScene>

/// TC002 counterpart of `AwtrixFace`: how one connector's reading looks on a
/// Ulanzi TC002. A value rather than a method, for the same reason its AWTRIX
/// twin is — the faces a connector HAS are the clock models it supports, and a
/// pure function reaches no network, which is what lets every drawing be
/// tested against a value.
public struct UlanziFace<Reading: Sendable>: Sendable {
    private let render: @Sendable (Reading) -> UlanziDelivery

    public init(_ render: @escaping @Sendable (Reading) -> UlanziDelivery) {
        self.render = render
    }

    public func draw(_ reading: Reading) -> UlanziDelivery {
        render(reading)
    }
}
