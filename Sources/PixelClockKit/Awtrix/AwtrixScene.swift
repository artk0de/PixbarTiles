import Foundation

/// Spelled out rather than `IconRef`: LaunchServices publicly declares
/// `typedef struct OpaqueIconRef* IconRef`, so that name is ambiguous in any
/// file reaching CoreServices — which is every file in the app target and every
/// file in the test target. Module qualification cannot rescue it either,
/// because this module declares an `enum PixelClockKit` that shadows its own
/// name.
public enum IconReference: Sendable, Equatable {
    /// Already present on the device, referenced by basename.
    ///
    /// The one case that promises nothing: it names a file this app never put
    /// there and cannot put back. Right for art a user placed on their own
    /// flash, wrong for anything this app draws by itself — on a clock that has
    /// been reset the picture is simply gone, and a banner with no icon beside
    /// it reads as ordinary.
    case installed(String)
    /// Fetched from the LaMetric catalogue by id, then installed.
    case catalogue(Int)
    /// Art shipped inside this app, uploaded to the flash on demand.
    ///
    /// The case for a picture the catalogue does not have. It installs by
    /// exactly the same route as `catalogue` — list, skip or upload — and
    /// differs only in where the bytes come from, so it keeps the same promise
    /// on a clock that has never seen this app.
    case bundled(String)
}

/// Where an output is drawn on the clock.
///
/// Two surfaces, and they are not settings of one thing. A notification
/// interrupts whatever the loop is showing and then goes away; an app IS the
/// loop, and stays there until it is replaced or removed. An anecdote is an
/// interruption; the weather is ambient and should be there when you glance at
/// the clock. The two coexist without arbitration — a notification draws over
/// the loop, which is exactly what it is for.
public enum DeliverySurface: Sendable, Equatable {
    case notification
    /// An app in the device's own loop, under this name.
    case app(String)
}

/// A bar filled from the left under an app's text.
///
/// Named for what the firmware calls it — `progress`, and not `bar`, which is a
/// different field drawing a little graph of a series. The percentage is what
/// the device draws rather than what is true: a reading past a hundred belongs
/// in the text, where it can be read, and not in a bar that has no room for it.
public struct ProgressBar: Sendable, Equatable {
    /// Nought to a hundred, clamped on the way in — the firmware has nothing to
    /// draw outside that and does not say so.
    public let percent: Int
    public let fill: String
    public let track: String

    public init(percent: Int, fill: String, track: String) {
        self.percent = min(100, max(0, percent))
        self.fill = fill
        self.track = track
    }
}

/// What an AWTRIX clock is asked to show for one delivery.
///
/// Everything the clock itself draws or sounds — the buzzer's jingle included.
/// The Mac's speech is not here; it rides on the `Delivery` beside the scene.
///
/// A struct with a `surface` rather than one case per surface, so a scene can
/// carry a field its surface ignores, and the session is what drops it. The
/// session's tests pin that a lifetime on a notification never reaches the
/// firmware.
public struct AwtrixScene: Sendable, Equatable {
    public var text: String
    public var icon: IconReference?
    /// The bar drawn under the text, or nil for an output that is only words.
    public var progress: ProgressBar?
    public var jingle: String?
    public var duration: Int?
    public var color: String?
    /// Where this is drawn. Defaulted to the notification, which is what every
    /// output was before there was a choice.
    public var surface: DeliverySurface
    /// Seconds without a fresh delivery after which the clock takes this off
    /// itself, or nil to stay until this app removes it.
    ///
    /// Next to `surface` because it belongs to one: an app in the loop is the
    /// only thing that outlives the delivery that made it. Defaulted to none,
    /// so a producer that says nothing about staleness behaves exactly as it
    /// did before there was anything to say.
    public var lifetime: Int?
    /// The device-wide weather layer this output wants, or nil to leave
    /// whatever is on the device alone.
    ///
    /// Carried on the output rather than written by the connector, because a
    /// connector produces and returns and never talks to the device. It is
    /// global state with one borrower and a value to put back afterwards, which
    /// is `DeviceCustody`'s job and not a producer's.
    public var overlay: DeviceOverlay?

    public init(
        text: String,
        icon: IconReference? = nil,
        progress: ProgressBar? = nil,
        jingle: String? = nil,
        duration: Int? = nil,
        color: String? = nil,
        surface: DeliverySurface = .notification,
        lifetime: Int? = nil,
        overlay: DeviceOverlay? = nil
    ) {
        self.text = text
        self.icon = icon
        self.progress = progress
        self.jingle = jingle
        self.duration = duration
        self.color = color
        self.surface = surface
        self.lifetime = lifetime
        self.overlay = overlay
    }
}

/// What an AWTRIX face produces and the AWTRIX session delivers.
public typealias AwtrixDelivery = Delivery<AwtrixScene>

public extension AwtrixScene {
    /// The AWTRIX panel's size — the geometry the preview draws this scene
    /// at, the way the TC002's is `PixelCanvas`'s own default.
    static let panelWidth = 32
    static let panelHeight = 16

    /// The scene as the preview draws it: the words centred on the panel in
    /// the kit's font, in the colour the scene names, with the progress bar
    /// over the panel's bottom band. The device sets its own glyphs and
    /// fetches an icon's pixels from its flash — neither is here, and a word
    /// wider than the double height falls to the single one rather than off
    /// the sides.
    func canvas() -> PixelCanvas {
        var canvas = PixelCanvas(width: Self.panelWidth, height: Self.panelHeight)
        let ink = UlanziColour(hex: color ?? "#FFFFFF")
        let textWidth = { (scale: Int) in text.unicodeScalars.count * 4 * scale - scale }
        let scale = textWidth(2) <= Self.panelWidth ? 2 : 1
        let height = 5 * scale
        // Centred, one band above the bar: the same two-band layout the TC002
        // faces draw, said once here.
        canvas.drawText(
            text,
            at: PixelPoint(
                x: (Self.panelWidth - textWidth(scale)) / 2,
                y: (Self.panelHeight - height - 2) / 2
            ),
            ink: Pixel(colour: ink),
            scale: scale
        )
        if let progress {
            let track = Pixel(colour: UlanziColour(hex: progress.track))
            let fill = Pixel(colour: UlanziColour(hex: progress.fill))
            canvas.drawRect(
                PixelRect(x: 0, y: 14, width: Self.panelWidth, height: 2), color: track
            )
            let filled = Self.panelWidth * progress.percent / 100
            canvas.drawRect(
                PixelRect(x: 0, y: 14, width: filled, height: 2), color: fill
            )
        }
        return canvas
    }
}

extension Delivery where Scene == AwtrixScene {
    /// Everything an AWTRIX delivery can say, in the labels and the order the
    /// connectors have always used.
    public init(
        text: String,
        icon: IconReference? = nil,
        progress: ProgressBar? = nil,
        jingle: String? = nil,
        localAudio: [SpokenClip] = [],
        holdUntilAudioEnds: Bool = false,
        duration: Int? = nil,
        color: String? = nil,
        surface: DeliverySurface = .notification,
        lifetime: Int? = nil,
        overlay: DeviceOverlay? = nil
    ) {
        self.init(
            scene: AwtrixScene(
                text: text,
                icon: icon,
                progress: progress,
                jingle: jingle,
                duration: duration,
                color: color,
                surface: surface,
                lifetime: lifetime,
                overlay: overlay
            ),
            localAudio: localAudio,
            holdUntilAudioEnds: holdUntilAudioEnds
        )
    }
}
