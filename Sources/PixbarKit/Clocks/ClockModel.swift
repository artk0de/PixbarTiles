/// Which firmware a clock runs, and so which adapter drives it.
///
/// Detected when a clock is added, never chosen. Stored by its raw value, so
/// the case names are persisted vocabulary: renaming one strands every record
/// that holds it.
public enum ClockModel: String, Codable, Sendable {
    /// A Ulanzi TC001 on AWTRIX 3.
    case awtrix3
    /// A Ulanzi TC002 on its stock firmware.
    case ulanziTC002
}
