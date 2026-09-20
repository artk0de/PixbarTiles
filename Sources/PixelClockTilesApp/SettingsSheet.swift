import PixelClockKit
import SwiftUI

/// Everything set once and forgotten, behind the gear.
///
/// Shown in place of the panel rather than as a `.sheet`. A menu bar extra's
/// window dismisses when it loses focus and takes any sheet over it with it, so
/// a sheet here is a surface that vanishes while it is being read. Swapping the
/// content also makes the rule literal: the settings are a view, and nothing
/// about the schedule, the poll or a run in flight knows they are open.
struct SettingsSheet: View {
    @ObservedObject var model: AppModel

    /// Handed down rather than built in `LoginItemSettings`'s own default, so a
    /// test can prove the section is on THIS surface without touching the real
    /// login-item database.
    private let loginItem: () -> LoginItemModel

    /// Where the width the three surfaces share is read.
    ///
    /// Handed in rather than reached for, for the reason `MenuPanel` takes one:
    /// a test can put a width in and see the sheet drawn at it, instead of the
    /// only proof being a write into the preferences of whoever runs the suite.
    private let defaults: UserDefaults

    init(
        model: AppModel,
        loginItem: @autoclosure @escaping () -> LoginItemModel = LoginItemModel(),
        defaults: UserDefaults = .standard
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.loginItem = loginItem
        self.defaults = defaults
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ClocksSettings(
                entries: model.clocks.map { clock in
                    ClockListEntry(
                        id: clock.id,
                        name: clock.name,
                        model: modelName(clock.model),
                        address: clock.address,
                        status: DeviceStatusLine.title(for: model.deviceState(of: clock.id))
                    )
                },
                discovered: [],
                onRename: { model.renameClock($0, to: $1) },
                onRemove: { model.removeClock($0) },
                onAddDiscovered: { _ = model.addClock(from: $0) },
                onAddByAddress: { address in
                    Task { _ = await model.addClock(address: address) }
                }
            )
            Divider()
            focusSection
            Divider()
            microphonesSection
            Divider()
            iconSection
            Divider()
            // Last, beside the icon removal, because the two are the same kind
            // of thing: settings above this line are changed while the app is
            // being used, and these two are set once in the life of an
            // installation.
            LoginItemSettings(item: loginItem())
        }
        .padding(14)
        // The width the three surfaces share, on this sheet rather than wrapped
        // round it from `MenuPanel`. The outer frame was tried and measured: a
        // 500-wide host round a sheet whose own frame said 320 gave 320 of
        // content CENTRED, fields at x=104 with 90 points of nothing each side.
        // A child's fixed frame is not something its parent can overrule, so the
        // literal had to go rather than be wrapped.
        //
        // No second axis: the form is exactly as tall as its sections.
        .panelWidth(from: defaults)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { model.closeSettings() } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Back")
            Text("Settings").font(.headline)
        }
    }

    /// The clock a list entry names, as the models are called when a person
    /// says them.
    private func modelName(_ model: ClockModel) -> String {
        switch model {
        case .awtrix3: "AWTRIX 3"
        case .ulanziTC002: "TC002"
        }
    }

    /// Where Focus reaches the tiles, and how much the system's answer is
    /// worth. The hours each tile keeps are the tile's own (B16); what the app
    /// still owes the user here is how to let it tell Work from Sleep.
    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Full Disk Access is not a permission anybody grants by accident,
            // and an app that quietly needs one is worse than an app that says
            // so.
            Text(FocusRuleLine.whichFocusesSilenceDependsOnFullDiskAccess)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Which microphones the schedule waits for.
    ///
    /// Every input the system reports, watched ones ticked — not only the
    /// watched ones. A gate the user cannot inspect is a gate they will
    /// eventually fight, and the always-on interface that reports itself busy
    /// for ever is only understandable next to the inputs that do not.
    ///
    /// Read live on every draw, at one CoreAudio enumeration — 1.36 ms measured
    /// on this machine — because the list changes underneath the app: the phone
    /// appears and vanishes, headphones are plugged in. Nothing on this surface
    /// redraws at frame rate, which is what makes that affordable here and
    /// worth stating before anybody moves it to the panel.
    private var microphonesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Wait for these microphones").font(.caption).foregroundStyle(.secondary)
            ForEach(model.microphoneListing) { choice in
                Toggle(choice.input.name, isOn: Binding(
                    get: { choice.isWatched },
                    set: { model.setWatched($0, for: choice.input) }
                ))
                .controlSize(.small)
            }
        }
    }

    /// The only thing this app writes to the device's flash, and the only way to
    /// take it back off.
    ///
    /// Its result line lives here beside it rather than on the panel: the user
    /// pressed this button on this surface, and an answer thrown back to a panel
    /// they have already left is an answer nobody reads. An action taken once in
    /// the life of an installation also has no business sitting next to one
    /// taken daily.
    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Remove icons this app uploaded") { model.removeInstalledIcons() }
                .controlSize(.small)
            if let status = model.iconStatus {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Whether macOS starts this app when the user logs in.
///
/// The tick is drawn from what the system reports, not from anything this app
/// stored — see `LoginItemModel` for why that is the whole design rather than a
/// refinement. What the section adds on top of the model is the one thing a
/// model cannot do: putting the failure on screen. A registration that is
/// refused has to be visible, or a box that would not stay ticked is
/// indistinguishable from a click that never landed.
struct LoginItemSettings: View {
    /// `@StateObject` rather than `@ObservedObject`, because what it holds must
    /// survive the redraws every keystroke in the address and location boxes
    /// causes: observed, the words explaining a refused registration would be
    /// thrown away by the next character typed two sections up.
    @StateObject private var item: LoginItemModel

    /// An autoclosure so the shipped model — which reads the login-item
    /// database on construction — is not built on every redraw of the surface
    /// this sits on. A plain default argument is evaluated at each call, and
    /// `StateObject` would discard all but the first.
    init(item: @autoclosure @escaping () -> LoginItemModel = LoginItemModel()) {
        _item = StateObject(wrappedValue: item())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(
                "Open at login",
                isOn: Binding(
                    get: { item.opensAtLogin },
                    set: { item.setOpensAtLogin($0) }
                )
            )
            .controlSize(.small)
            if let note = item.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
