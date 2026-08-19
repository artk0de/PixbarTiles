import AppKit
import AwtrixKit
import SwiftUI

/// When an anecdote played, as the History says it.
///
/// Its own type rather than a format string in the view, for the reason
/// `NextRunLine` is one: what a surface says is behaviour, and a `Text` built
/// inline is not somewhere behaviour can be read back from.
///
/// The date as well as the hour, because the window is ten days: "14:32" alone
/// answers "what was that one this morning" and nothing else, and the question
/// asked of a week-old entry is which day it was.
enum PlayedAtLine {
    static func text(for moment: Date) -> String {
        moment.formatted(date: .abbreviated, time: .shortened)
    }
}

/// What has played, with a way to hear it again.
///
/// Shown in place of the panel rather than as a `.sheet`, exactly as the
/// settings are: a menu bar extra's window dismisses when it loses focus and
/// takes any sheet over it with it, so a sheet here is a surface that vanishes
/// while it is being read.
///
/// Nothing here bounds the list. What it draws is what the queue still holds,
/// and the retention window is what removed the rest — a limit of its own would
/// be a second answer to a question Task 17 already answers, and the two would
/// disagree the first time either moved.
struct HistoryMenu: View {
    @ObservedObject var model: AppModel

    /// Where the width the three surfaces share is read.
    ///
    /// Handed in rather than reached for, for the reason `MenuPanel` takes one:
    /// a test can put a width in and see the History drawn at it, instead of the
    /// only proof being a write into the preferences of whoever runs the suite.
    private let defaults: UserDefaults

    /// How much display there is to hang this surface in.
    ///
    /// Handed in for the reason `defaults` is: a test has no screen worth
    /// speaking of, and the claim worth proving — that a History taller than the
    /// display is cut down to it — cannot be posed against whatever monitor the
    /// suite happens to be running on.
    private let screenHeight: CGFloat

    /// What is left of the display once the menu bar and the Dock have had
    /// theirs, which is what `visibleFrame` answers.
    ///
    /// `NSScreen.main` is the screen with the keyboard focus, which is not
    /// necessarily the one the menu bar item was clicked on. It is the closest
    /// public answer — a menu bar extra does not tell anybody which screen its
    /// window went to — and being wrong means clamping against the wrong display
    /// of a multi-monitor setup, not against nothing.
    static var availableScreenHeight: CGFloat {
        NSScreen.main?.visibleFrame.height ?? HistoryHeight.shortestDisplay
    }

    /// What a drag in flight has reached, and nil the rest of the time — for the
    /// reason `SharedPanelWidth` keeps the width the same way: a `UserDefaults`
    /// write publishes nothing to SwiftUI, so a surface reading the defaults on
    /// every frame of a drag would draw the old height the whole way down.
    @State private var draggedHeight: CGFloat?

    init(
        model: AppModel,
        defaults: UserDefaults = .standard,
        screenHeight: CGFloat = HistoryMenu.availableScreenHeight
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.defaults = defaults
        self.screenHeight = screenHeight
    }

    private var height: CGFloat {
        draggedHeight ?? HistoryHeight.stored(in: defaults, fittingInto: screenHeight).points
    }

    /// The height, as somewhere the border can write. The setter is where the
    /// clamp is, so a drag meets the floor and the screen as it happens rather
    /// than when the button comes up.
    private var heightBinding: Binding<CGFloat> {
        Binding(
            get: { height },
            set: { draggedHeight = HistoryHeight($0, fittingInto: screenHeight).points }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // How the last replay went, under the header rather than beside it:
            // the reason one failed is a sentence, and a row shared with the
            // title has room for a word. Nothing at all until one has been
            // asked for — the surface is a list of what has played, and an
            // empty slot above it would be a question nobody asked.
            if let outcome = model.replayResult {
                Text(outcome)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            if model.history.isEmpty {
                Text("Nothing has played yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                entries
            }
        }
        .padding(14)
        // The width the three surfaces share, on this surface rather than
        // wrapped round it from `MenuPanel` for the reason `SettingsSheet`
        // carries its own: a child's fixed frame is not something its parent can
        // overrule, and the outer frame leaves the content centred in it.
        //
        // And the second axis, which only this surface has — but only while
        // there is a list to resize. With nothing played yet the surface is one
        // line of text, and a top or bottom edge would show a resize cursor and
        // then move nothing, which is the same lie as a border that resizes
        // silently told from the other side.
        .panelWidth(
            from: defaults,
            alsoResizing: model.history.isEmpty ? nil : heightBinding
        ) {
            // The width's own save is `SharedPanelWidth`'s; this is the half it
            // cannot know about. Saved before the state is let go of, for the
            // same reason and in the same order: the moment `draggedHeight` is
            // nil the list is reading the defaults again.
            HistoryHeight(height, fittingInto: screenHeight).save(to: defaults)
            draggedHeight = nil
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { model.closeHistory() } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Back")
            Text("History").font(.headline)
        }
    }

    /// Scrolled, and as tall as it was last left rather than as tall as its
    /// contents.
    ///
    /// Ten days of a half-hourly connector is a few hundred entries, and a menu
    /// that tall is one macOS draws off the bottom of the screen. The height is
    /// stored, and the scroll view is what makes storing one honest: it is a
    /// viewport over the list rather than a cut through it, so the entries below
    /// the fold are a scroll away instead of gone.
    ///
    /// An exact height and not `maxHeight:`, which is what the literal 280 was.
    /// Capped at a maximum, a short list takes only what it needs — and then
    /// dragging the bottom edge of a History with three jokes in it moves
    /// nothing at all, which is precisely the border that cannot be told from
    /// one that does not work. A stored height is a size somebody chose, and it
    /// is honoured whether the list fills it or not.
    ///
    /// Keyed by the anecdote's id, which is the feed's guid and is unique by the
    /// requirement that nothing is ever played twice.
    private var entries: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.history, id: \.anecdote.id) { entry in
                    row(entry)
                }
            }
        }
        .frame(height: height)
    }

    /// The joke, when it played, and the two things that can be done with it.
    private func row(_ entry: PlayedAnecdote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.anecdote.text)
                .font(.caption)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(PlayedAtLine.text(for: entry.playedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Disabled on the one answer that exists. `isPlayable` is what
                // the model's own guard reads, and what the connector reads when
                // it pops one: a second rule here would be a second answer, and
                // the two would disagree the moment either moved.
                Button("Play again") { model.replay(entry.anecdote) }
                    .controlSize(.small)
                    .disabled(entry.anecdote.isPlayable == false)
                Button("Copy") { model.copyText(entry.anecdote) }
                    .controlSize(.small)
            }
        }
    }
}
