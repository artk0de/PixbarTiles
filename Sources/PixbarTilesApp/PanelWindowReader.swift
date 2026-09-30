import AppKit
import SwiftUI

/// Reports the window the panel was put on.
///
/// A view, because a view is the only thing that can answer: `MenuBarExtra` in
/// `.window` style builds the panel's window itself, on the first open, and
/// returns it to nobody — there is nothing for the delegate to hold at launch,
/// which is where its observer is set up. `NSView.viewDidMoveToWindow` fires
/// when the panel is put on screen, and `window` is then the panel's own.
///
/// Internal rather than private so a test can put one in a window of its own:
/// the mechanism is what the whole filter rests on, and a menu bar extra cannot
/// be opened from a test.
struct PanelWindowReader: NSViewRepresentable {
    /// Called with the window on every move, `nil` included. What a nil means is
    /// the reader's caller's business, not the reader's.
    let report: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { WindowReportingView(report: report) }

    /// Nothing to update: the view draws nothing and reads nothing from SwiftUI.
    /// What it reports comes from AppKit moving it, not from the state changing.
    func updateNSView(_ view: NSView, context: Context) {}
}

/// The AppKit half of `PanelWindowReader`.
private final class WindowReportingView: NSView {
    private let report: (NSWindow?) -> Void

    init(report: @escaping (NSWindow?) -> Void) {
        self.report = report
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("never unarchived: this view exists only where SwiftUI builds it")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        report(window)
    }
}
