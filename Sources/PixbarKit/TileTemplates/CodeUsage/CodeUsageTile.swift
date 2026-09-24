import Foundation

public extension CodeUsage {
    /// The page a coding-subscription tile draws, on both surfaces.
    ///
    /// One page for both vendors. It used to be two: Claude's AWTRIX face drew
    /// a figure, its mark and a band-coloured bar, while z.ai's joined its
    /// windows into `"84% 52%"` with no mark and no bar — two answers to one
    /// question, differing in everything except the question. A reader who has
    /// both tiles on one clock was being asked to learn two pictures.
    enum Tile {
        /// The unfilled part of a bar. Dark enough to read as empty at
        /// brightness two, light enough that the bar's full width is still
        /// visible — an unlit track makes a half-full bar look like a short one.
        public static let trackColour = "#303030"

        /// How long a page outlives the Mac that pushed it.
        ///
        /// A quarter of an hour, doing two jobs. The usual one is insurance: a
        /// crashed Mac stops refreshing and the clock clears a figure nothing
        /// stands behind any more. The second is how the app LEAVES when a
        /// Focus changes — nothing retracts it, the gate simply stops feeding
        /// it and the lifetime finishes the job. Read against the connectors'
        /// one-minute interval, which is chosen for it: fifteen polls inside
        /// one lifetime survives a few misses.
        ///
        /// One number for both, where z.ai's used to be half an hour. Nothing
        /// about a z.ai figure is staler at twenty minutes than a Claude one.
        public static let lifetime = 900

        /// The AWTRIX page: the headline figure, the vendor's mark, the band's
        /// own bar under it — and nil when the reading names no window at all.
        ///
        /// Nil rather than a page saying "—": the app carries a `lifetime`, so
        /// a run that delivers nothing lets the clock drop the app by itself.
        /// That says the true thing — nothing here knows a figure any more —
        /// without inventing one.
        ///
        /// The figure is the TRUE one, including past a hundred: an overage
        /// channel keeps serving after the bar is full, and a hundred and forty
        /// is a true thing to say about a week. The bar clamps because the
        /// firmware has nowhere to draw the rest; the text has no such excuse.
        public static func awtrix(_ reading: Reading, vendor: Vendor) -> AwtrixDelivery? {
            guard let window = reading.headline else { return nil }
            return AwtrixDelivery(
                text: "\(window.percent)%",
                icon: vendor.icon,
                progress: ProgressBar(
                    percent: window.percent,
                    fill: Band(utilization: window.percent).fillColour(brand: vendor.brand),
                    track: trackColour
                ),
                color: vendor.brand,
                surface: .app(vendor.id),
                lifetime: lifetime
            )
        }

        /// The TC002 page: the face the tile is set to, drawn for this reading.
        ///
        /// A window the source did not report is drawn with no reading, never
        /// as a zero — the page's shape is the tile's settings, not what a
        /// route felt like saying today. That holds in both layouts: Compact
        /// leaves the row blank, Circle still gives the window its turn.
        public static func ulanzi(
            _ reading: Reading, vendor: Vendor,
            parameters: Parameters, timeZone: TimeZone
        ) -> UlanziDelivery {
            switch parameters.layout {
            case .compact:
                return Compact.delivery(
                    vendor: vendor,
                    session: reading.fiveHour,
                    weekly: reading.weekly,
                    config: parameters,
                    timeZone: timeZone
                )
            case .circle:
                return page(Circle.timeline(
                    vendor: vendor,
                    windows: parameters.windows.map { (kind: $0, reading: reading.window($0)) },
                    parameters: parameters,
                    timeZone: timeZone
                ))
            }
        }

        /// A timeline as the one page the TC002 plays by itself: a full-frame
        /// GIF, each frame's own delay, at the panel's origin (the `image[]`
        /// envelope measured in §6f).
        ///
        /// The template's, not a face's, because every face the substrate
        /// carries reaches the panel the same way — what differs between
        /// Compact and Circle is the pictures, never how they are delivered.
        ///
        /// Should the GIF fail to encode — it cannot for these frames: a
        /// handful of colours, one panel size — the page falls back to the
        /// first frame as a plain bitmap, which says the percentages rather
        /// than nothing.
        static func page(_ frames: [Frame]) -> UlanziDelivery {
            guard let first = frames.first else {
                return UlanziDelivery(scene: UlanziScene(frames: []))
            }
            guard
                let gif = try? FullFrameGif.encode(
                    frames: frames.map(\.canvas),
                    delays: frames.map { TimeInterval($0.milliseconds) / 1000 }
                )
            else {
                return UlanziDelivery(scene: UlanziScene(frames: [
                    UlanziFrame(duration: 5, draw: [first.canvas.drawCommands()]),
                ]))
            }
            let image = UlanziImage(
                base64: gif.base64EncodedString(),
                isAnimated: frames.count > 1,
                frameCount: frames.count,
                pixelSize: (width: PixelCanvas.width, height: PixelCanvas.height),
                position: (x: 0, y: 0)
            )
            return UlanziDelivery(scene: UlanziScene(frames: [
                UlanziFrame(duration: 5, image: [image]),
            ]))
        }
    }
}
