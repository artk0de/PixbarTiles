/// Everything the TC002 path can fail with. `limit` is thrown by the scene
/// encoder against the measured device ceilings (D7); the rest come back from
/// the device adapter.
public enum UlanziError: Error, Equatable, Sendable {
    case limit(String)
    case deviceRejected(code: Int, message: String)
    case unexpectedStatus(Int)
    case malformed(String)
}
