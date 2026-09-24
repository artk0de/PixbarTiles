import PixbarKit

/// A test connector whose reading already is what the clock is to show draws
/// it unchanged. A second copy of the kit target's own, because test targets
/// do not import each other.
extension Connector where Reading == AwtrixDelivery {
    var awtrixFace: AwtrixFace<AwtrixDelivery> { AwtrixFace { $0 } }
}
