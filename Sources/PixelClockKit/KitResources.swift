import Foundation

/// Where the kit's shipped resources are read from.
///
/// Not `Bundle.module` alone, because an installed app cannot rely on it.
/// SwiftPM's lookup tries the directory beside the executable — the root of the
/// `.app`, where codesign refuses anything but `Contents` — and then the
/// absolute build path compiled into the binary, and it calls `fatalError` when
/// both miss. An app built in a worktree meets exactly that once the worktree is
/// removed. `Scripts/bundle.sh` copies the bundle into `Contents/Resources`, and
/// that copy is read first.
enum KitResources {
    /// The resource bundle's name as SwiftPM builds it: package, underscore,
    /// target. `Scripts/bundle.sh` copies the bundle under this name, and a test
    /// holds it to what SwiftPM actually produced.
    static let bundleName = "PixelClockTiles_PixelClockKit.bundle"

    /// The bundle every kit resource is read from. Resolved once, on first use.
    static let bundle = resolve(besideApp: Bundle.main.resourceURL)

    /// The copy under `resources` when there is one, and `fallback` only when
    /// there is not.
    ///
    /// `fallback` is a closure and is left unevaluated whenever the copy exists,
    /// because evaluating `Bundle.module` is itself the crash: its lookup ends
    /// in `fatalError` when the build directory has gone. Under `swift test`
    /// there is no copy and the module is right; under `swift run` the
    /// directory beside the executable is the build directory, and holds the
    /// bundle under this very name.
    static func resolve(besideApp resources: URL?, fallback: () -> Bundle = { Bundle.module }) -> Bundle {
        if let resources, let copy = Bundle(url: resources.appendingPathComponent(bundleName)) {
            return copy
        }
        return fallback()
    }
}
