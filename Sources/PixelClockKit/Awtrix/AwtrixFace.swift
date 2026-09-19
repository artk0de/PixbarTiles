import Foundation

/// How one connector's reading looks on an AWTRIX clock.
///
/// A value rather than a method, so a connector's faces are things it HAS: the
/// TC002's face joins beside this one as a second property, and the models a
/// connector supports are the faces it carries. A pure function — it reaches no
/// network and no device, which is what lets every drawing be tested against a
/// value.
public struct AwtrixFace<Reading: Sendable>: Sendable {
    private let render: @Sendable (Reading) -> AwtrixDelivery

    public init(_ render: @escaping @Sendable (Reading) -> AwtrixDelivery) {
        self.render = render
    }

    public func draw(_ reading: Reading) -> AwtrixDelivery {
        render(reading)
    }
}
