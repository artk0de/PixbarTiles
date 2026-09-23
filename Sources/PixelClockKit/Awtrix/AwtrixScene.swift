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
    /// The AWTRIX panel's size.
    ///
    /// 32×8, which is the hardware: `prototype/awtrix/client.py` reads the
    /// device's own buffer as "256 packed 0xRRGGBB values" and 32 × 8 is what
    /// 256 is. This was written as 32×16 for one iteration and every preview
    /// drawn in that time put its progress bar on rows the panel does not
    /// have and half its text below the glass.
    static let panelWidth = 32
    static let panelHeight = 8

    /// The columns an icon costs the text: the device draws 8×8 art from its
    /// own flash, plus a column of air after it.
    ///
    /// The preview cannot draw the art — those pixels live on the clock, and
    /// a catalogue icon has never been in this process. It keeps the columns
    /// instead, because where the WORDS sit is the thing a preview is read
    /// for, and a line centred over the icon's ground is a line that will not
    /// be there on the clock.
    static let iconColumns = 9

    /// How far the scroll moves between frames, in columns. Two rather than
    /// one: the frames are a preview of motion rather than a recording of it,
    /// and halving them halves the GIF.
    private static let scrollStep = 2

    /// The most frames a scrolling line is drawn as — a bound on the GIF
    /// rather than on the sentence.
    private static let scrollFrameCap = 96

    /// The scene as the preview draws it: one still frame.
    ///
    /// The first frame of `canvasFrames()`, which for a line that fits is the
    /// whole of it, and for a line that scrolls is the line at its start —
    /// where a reader looks first.
    func canvas() -> PixelCanvas {
        canvasFrames()[0]
    }

    /// The scene as the clock plays it: one frame for a line that fits, and
    /// the frames of the scroll for one that does not.
    ///
    /// The firmware scrolls anything wider than the panel, so a single still
    /// of the first 32 columns is not what the clock shows — it is the first
    /// third of a sentence presented as the whole of it. The words are drawn
    /// in the kit's X11 face; the device has glyphs of its own, and that is
    /// the one thing this preview approximates rather than reproduces.
    func canvasFrames() -> [PixelCanvas] {
        let font = PixelFont.standard
        let ink = Pixel(colour: UlanziColour(hex: color ?? "#FFFFFF"))
        // An icon takes the leading columns; a bar takes the last row.
        let left = icon == nil ? 0 : Self.iconColumns
        let available = Self.panelWidth - left
        let textRows = progress == nil ? Self.panelHeight : Self.panelHeight - 1
        let top = max(0, (textRows - font.height) / 2)
        let line = font.width(of: text, scale: 1)

        guard line > available else {
            var canvas = blankPanel()
            var strip = PixelCanvas(width: available, height: Self.panelHeight)
            strip.drawText(
                text, at: PixelPoint(x: (available - line) / 2, y: top), ink: ink, scale: 1,
                font: font
            )
            canvas.draw(strip, at: PixelPoint(x: left, y: 0))
            paintProgress(onto: &canvas)
            return [canvas]
        }

        // The line starts against the left of its own area and walks off it,
        // which is where a reader's eye starts. The travel ends when the last
        // glyph has left: one panel's worth past the line's own width.
        let travel = line + available
        var frames: [PixelCanvas] = []
        var offset = 0
        while offset <= travel, frames.count < Self.scrollFrameCap {
            var canvas = blankPanel()
            var strip = PixelCanvas(width: available, height: Self.panelHeight)
            strip.drawText(
                text, at: PixelPoint(x: -offset, y: top), ink: ink, scale: 1, font: font
            )
            canvas.draw(strip, at: PixelPoint(x: left, y: 0))
            paintProgress(onto: &canvas)
            frames.append(canvas)
            offset += Self.scrollStep
        }
        return frames
    }

    private func blankPanel() -> PixelCanvas {
        PixelCanvas(width: Self.panelWidth, height: Self.panelHeight)
    }

    /// The bar the firmware fills under an app's text: the panel's LAST row,
    /// the track across the whole width and the fill over its left part.
    private func paintProgress(onto canvas: inout PixelCanvas) {
        guard let progress else { return }
        let row = Self.panelHeight - 1
        canvas.drawRect(
            PixelRect(x: 0, y: row, width: Self.panelWidth, height: 1),
            color: Pixel(colour: UlanziColour(hex: progress.track))
        )
        canvas.drawRect(
            PixelRect(
                x: 0, y: row, width: Self.panelWidth * progress.percent / 100, height: 1
            ),
            color: Pixel(colour: UlanziColour(hex: progress.fill))
        )
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
        overlay: DeviceOverlay? = nil,
        interruptions: [Interruption<AwtrixScene>] = []
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
            holdUntilAudioEnds: holdUntilAudioEnds,
            interruptions: interruptions
        )
    }
}
