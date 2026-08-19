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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
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
        .frame(width: 320)
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

    /// Scrolled, and capped rather than left to grow.
    ///
    /// Ten days of a half-hourly connector is a few hundred entries, and a menu
    /// that tall is one macOS draws off the bottom of the screen. Keyed by the
    /// anecdote's id, which is the feed's guid and is unique by the requirement
    /// that nothing is ever played twice.
    private var entries: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.history, id: \.anecdote.id) { entry in
                    row(entry)
                }
            }
        }
        .frame(maxHeight: 280)
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
