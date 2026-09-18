@testable import PixelClockKit

/// A test connector whose reading already is what the clock is to show draws
/// it unchanged.
///
/// Test-only on purpose. Every shipped connector reads a value and draws it,
/// and a default in the kit would let a new connector skip its face and still
/// compile.
extension Connector where Reading == AwtrixDelivery {
    var awtrixFace: AwtrixFace<AwtrixDelivery> { AwtrixFace { $0 } }
}
