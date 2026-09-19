// Sources/PixelClockTilesApp/ClaudeCodeSettings.swift
import Foundation
import PixelClockKit
import SwiftUI

/// Where the Claude figure comes from, on this Mac.
enum ClaudeCodePaths {
    /// This app's own folder. The hook and the document it writes live here,
    /// beside the app's other data.
    static let directory: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("PixelClockTiles")
    }()

    /// Claude Code's user settings, the file its `/statusline` and `/config`
    /// edit.
    static let settingsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    /// What the composition root's reporter reads, and what the hook writes.
    static let document = directory.appendingPathComponent(ClaudeCodeStatusLine.documentName)

    /// The link over the real files, or nil without an app bundle.
    ///
    /// The guard is the point. Under `swift test` there is no bundle, and every
    /// test that lays out the settings surface would otherwise read, and could
    /// rewrite, the Claude Code settings of whoever runs the suite. A bare
    /// `swift run` build pays for that by not being able to connect.
    static var shippedLink: ClaudeCodeStatusLine? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return ClaudeCodeStatusLine(
            settingsFile: settingsFile, directory: directory, defaults: .standard
        )
    }
}

/// Connect / Disconnect Claude Code, and what the section says about it.
///
/// Its own object rather than fields on `AppModel`, for the reason
/// `LoginItemModel` is one: none of this is a setting of the app's. Whether
/// Claude Code is connected is a fact about its settings file, read after every
/// action rather than remembered, because the user or Claude Code's own
/// `/statusline` can change that file while this app is not looking.
@MainActor
final class ClaudeCodeLinkModel: ObservableObject {
    /// Said before connecting, because the cost is invisible until later.
    nonisolated static let costOfConnecting =
        "Claude Code will run this app's script after every reply, and the clock "
            + "gets the usage figure from it. With any custom status line, Claude "
            + "Code stops showing most of its footer hints, esc to interrupt among them."
    nonisolated static let needsTheAppBundle =
        "Connecting Claude Code needs the app bundle — this build is a bare binary."
    nonisolated static let leftChangedStatusLine =
        "Claude Code's status line had been changed since connecting, so it was left as it is."

    @Published private(set) var isConnected: Bool
    /// Between Connect and its confirmation.
    @Published private(set) var isConfirming = false
    @Published private(set) var lastDocumentAt: Date?
    /// Why the last action did not do what was asked, or nil.
    @Published private(set) var note: String?

    private let link: ClaudeCodeStatusLine?

    init(link: ClaudeCodeStatusLine? = ClaudeCodePaths.shippedLink) {
        self.link = link
        self.isConnected = link?.isConnected() ?? false
        self.lastDocumentAt = link?.lastDocumentAt()
        self.note = link == nil ? Self.needsTheAppBundle : nil
    }

    var canAct: Bool { link != nil }

    func askToConnect() {
        isConfirming = canAct
    }

    func cancel() {
        isConfirming = false
    }

    func connect() {
        guard let link else { return }
        isConfirming = false
        do {
            try link.connect()
            note = nil
        } catch {
            note = "Could not connect: " + error.localizedDescription
        }
        readBack(link)
    }

    func disconnect() {
        guard let link else { return }
        do {
            note = try link.disconnect() == .leftAlone ? Self.leftChangedStatusLine : nil
        } catch {
            note = "Could not disconnect: " + error.localizedDescription
        }
        readBack(link)
    }

    /// What the file says now, whatever was asked for.
    private func readBack(_ link: ClaudeCodeStatusLine) {
        isConnected = link.isConnected()
        lastDocumentAt = link.lastDocumentAt()
    }

    nonisolated static func documentLine(_ at: Date?) -> String {
        guard let at else { return "No status-line document yet" }
        return "Last status-line document: \(at.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// Connect / Disconnect Claude Code, with the time of the last status-line
/// document.
///
/// A view of its own, for the reason `LoginItemSettings` is one: the whole
/// settings surface costs 57 ms to lay out, and a test about this section has
/// no business spending it. It lives on the current settings surface until
/// phase 5 moves it; the view moves as it is.
///
/// Confirmation is inline rather than an alert. The menu bar window dismisses
/// when it loses focus, and takes any sheet or alert over it with it.
struct ClaudeCodeSettings: View {
    /// `@StateObject` for the reason `LoginItemSettings` uses one: the note
    /// has to survive the redraws every keystroke elsewhere on the surface
    /// causes.
    @StateObject private var link: ClaudeCodeLinkModel

    init(link: @autoclosure @escaping () -> ClaudeCodeLinkModel = ClaudeCodeLinkModel()) {
        _link = StateObject(wrappedValue: link())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude usage").font(.caption).foregroundStyle(.secondary)
            if link.isConnected {
                Button("Disconnect Claude Code") { link.disconnect() }
                    .controlSize(.small)
            } else if link.isConfirming {
                Text(ClaudeCodeLinkModel.costOfConnecting)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("Connect") { link.connect() }
                    Button("Cancel") { link.cancel() }
                }
                .controlSize(.small)
            } else {
                Button("Connect Claude Code…") { link.askToConnect() }
                    .controlSize(.small)
                    .disabled(link.canAct == false)
            }
            Text(ClaudeCodeLinkModel.documentLine(link.lastDocumentAt))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let note = link.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
