import Foundation
import Testing
@testable import PixelClockKit

// An installed app cannot count on SwiftPM's own lookup. `Bundle.module` tries
// the directory beside the executable, then the absolute build path compiled
// into the binary, and stops the process when both miss — which is what an app
// built in a worktree meets once that worktree is removed. The copy
// `Scripts/bundle.sh` puts in `Contents/Resources` is what an installed app
// reads; `Bundle.module` is left to `swift test` and `swift run`.

/// A directory standing in for an app's `Contents/Resources`, removed when
/// `body` returns. `copy` names the files the kit's bundle holds there, or is
/// nil when the app carries no copy at all.
private func withResources(copy: [String: Data]?, _ body: (URL) throws -> Void) throws {
    let resources = FileManager.default.temporaryDirectory
        .appendingPathComponent("kit-resources-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: resources) }
    if let copy {
        let bundle = resources.appendingPathComponent(KitResources.bundleName)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for (name, bytes) in copy {
            try bytes.write(to: bundle.appendingPathComponent(name))
        }
    }
    try body(resources)
}

// The copy wins, and `Bundle.module` is not so much as asked. Asking is the
// defect: its lookup ends in `fatalError` when the build directory is gone, so
// a fallback evaluated "just in case" kills the app the copy was there to save.
@Test func aCopyInTheAppsResourcesIsReadWithoutTouchingTheModule() throws {
    try withResources(copy: [:]) { resources in
        var askedForTheModule = false
        let bundle = KitResources.resolve(besideApp: resources) {
            askedForTheModule = true
            return Bundle.main
        }

        let copy = resources.appendingPathComponent(KitResources.bundleName)
        #expect(bundle.bundleURL.resolvingSymlinksInPath() == copy.resolvingSymlinksInPath())
        #expect(askedForTheModule == false, "the module was asked although the copy was there")
    }
}

// `swift test` and `swift run` have no copy in any Resources directory; the
// build directory is right there, and `Bundle.module` finds it.
@Test func withNoCopyInTheResourcesTheModuleIsRead() throws {
    try withResources(copy: nil) { resources in
        let module = try #require(Bundle(url: resources))

        #expect(KitResources.resolve(besideApp: resources) { module } === module)
    }
}

// A process with no Resources directory at all is the same case.
@Test func withNoResourcesDirectoryTheModuleIsRead() {
    #expect(KitResources.resolve(besideApp: nil) { Bundle.main } === Bundle.main)
}

// The copy is found by name, and the name is SwiftPM's: package, underscore,
// target. Renaming either changes it, and a copy under the old name is a copy
// nobody finds — the app would fall back to the build path and die with it.
@Test func theCopyIsLookedForUnderTheNameSwiftPMGivesTheKit() {
    #expect(KitResources.resolve(besideApp: nil).bundleURL.lastPathComponent == KitResources.bundleName)
}

// The shipped copy is flat — the GIFs at its top level, no `Contents`, no
// Info.plist — because that is how SwiftPM builds it. A lookup that only knew
// the nested layout would find nothing in it and ship a clock with no art.
@Test func anIconIsReadOutOfTheFlatCopy() throws {
    let art = Data("GIF89a-probe".utf8)
    try withResources(copy: ["Probe.gif": art]) { resources in
        let bundle = KitResources.resolve(besideApp: resources) { Bundle.main }

        #expect(BundledIcon.data(named: "Probe", in: bundle) == art)
    }
}
