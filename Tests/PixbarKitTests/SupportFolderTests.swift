import Foundation
import Testing
@testable import PixbarKit

// The app's folder in Application Support was named after the app, and the app
// was renamed: `PixelClockTiles` holds `secrets.enc` — every token the user
// pasted — and the Claude Code hook with the document it writes. The first
// launch as PixbarTiles moves it, before anything opens the secret store. Every
// test here works in a temporary directory of its own.

private func withSupportRoot(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("support-folder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: url)
}

// Everything in the old folder arrives byte for byte, and the old folder is
// gone: a copy would leave two sets of secrets to drift apart.
@Test func theOldFolderMovesWithEverythingInIt() throws {
    try withSupportRoot { root in
        let old = root.appendingPathComponent("PixelClockTiles", isDirectory: true)
        let new = root.appendingPathComponent("PixbarTiles", isDirectory: true)
        try write("sealed", to: old.appendingPathComponent("secrets.enc"))
        try write("#!/bin/sh", to: old.appendingPathComponent("claude-statusline.sh"))

        let outcome = try SupportFolder.carryOver(from: old, to: new)

        #expect(outcome == .moved)
        #expect(try Data(contentsOf: new.appendingPathComponent("secrets.enc")) == Data("sealed".utf8))
        #expect(try Data(contentsOf: new.appendingPathComponent("claude-statusline.sh"))
            == Data("#!/bin/sh".utf8))
        #expect(FileManager.default.fileExists(atPath: old.path) == false)
    }
}

// A new folder that already exists is newer than the old one: nothing is
// merged into it and nothing is taken from the old one, which stays for the
// user to look at.
@Test func aNewFolderThatExistsLeavesBothAlone() throws {
    try withSupportRoot { root in
        let old = root.appendingPathComponent("PixelClockTiles", isDirectory: true)
        let new = root.appendingPathComponent("PixbarTiles", isDirectory: true)
        try write("old", to: old.appendingPathComponent("secrets.enc"))
        try write("new", to: new.appendingPathComponent("secrets.enc"))

        let outcome = try SupportFolder.carryOver(from: old, to: new)

        #expect(outcome == .keptBoth)
        #expect(try Data(contentsOf: new.appendingPathComponent("secrets.enc")) == Data("new".utf8))
        #expect(try Data(contentsOf: old.appendingPathComponent("secrets.enc")) == Data("old".utf8))
    }
}

// A fresh install has no old folder, and the move creates nothing: the store
// and the hook create the new folder when they first write.
@Test func withNoOldFolderNothingIsCreated() throws {
    try withSupportRoot { root in
        let old = root.appendingPathComponent("PixelClockTiles", isDirectory: true)
        let new = root.appendingPathComponent("PixbarTiles", isDirectory: true)

        let outcome = try SupportFolder.carryOver(from: old, to: new)

        #expect(outcome == .nothingToMove)
        #expect(FileManager.default.fileExists(atPath: new.path) == false)
    }
}

// The literals the move depends on. The old one names where the data IS.
@Test func theFoldersAreNamedAfterTheAppBeforeAndAfter() {
    #expect(SupportFolder.name == "PixbarTiles")
    #expect(SupportFolder.previousName == "PixelClockTiles")
    #expect(SupportFolder.current.lastPathComponent == "PixbarTiles")
    #expect(SupportFolder.previous.lastPathComponent == "PixelClockTiles")
    #expect(SupportFolder.current.deletingLastPathComponent().path
        == SupportFolder.previous.deletingLastPathComponent().path)
    #expect(SupportFolder.current.path.contains("/Application Support/"))
}

// The folder the move fills is the one the secret store opens. Were they to
// differ, the move would succeed and every token would still be lost.
@Test func theLiveSecretStoreLivesInTheCurrentFolder() {
    #expect(EncryptedFileSecretStore.liveFile.deletingLastPathComponent().path
        == SupportFolder.current.path)
    #expect(EncryptedFileSecretStore.liveFile.lastPathComponent == "secrets.enc")
}
