/// The reds and ambers the TC002 tells apart, measured on the panel
/// 2026-09-29 — `nlengine.PANEL_REDS` and `AMBER_FLOOR`.
public enum PanelLevels {
    /// (lowest design red, panel red): 4…64 light as one dimmest dot,
    /// 72…128 as one, 144…255 step apart.
    static let reds: [(low: Int, out: Int)] = [(8, 40), (20, 100), (36, 144), (64, 160), (90, 176),
                                               (120, 192), (150, 224), (185, 255)]
    /// (green, lowest panel red that carries it), greenest first.
    static let amberFloor: [(green: Int, floor: Int)] = [(144, 192), (100, 160), (72, 160), (40, 100)]

    /// The panel red a design red shows as; 0 below the first band.
    public static func red(_ r: Int) -> Int {
        var level = 0
        for band in reds where r >= band.low { level = band.out }
        return level
    }

    /// The lowest design red `steps` panel levels above `r`'s own.
    public static func stepUp(_ r: Int, _ steps: Int = 1) -> Int {
        let band = reds.filter { r >= $0.low }.count - 1
        return reds[min(reds.count - 1, band + steps)].low
    }

    /// The greenest approved green at or below `g` that panel red `r` carries.
    public static func amber(_ r: Int, _ g: Int) -> Int {
        amberFloor.first { g >= $0.green && r >= $0.floor }?.green ?? 0
    }
}
