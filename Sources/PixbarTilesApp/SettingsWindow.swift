import PixbarKit
import SwiftUI

/// The Settings window: three tabs, each one kind of answer. Clocks is where
/// a clock is added, renamed, removed and put in order; Defaults is what a
/// tile added later starts from; General is what is set once in the life of
/// an installation.
///
/// A real `Settings` scene rather than a surface swapped into the panel —
/// ⌘, works, the window is restorable, and a menu bar popover's habit of
/// dismissing on a lost focus takes nothing away from what the user is
/// reading.
struct SettingsRoot: View {
    @Bindable var settings: SettingsModel
    @ObservedObject var model: AppModel
    @ObservedObject var discovery: ClockDiscovery
    private let loginItem: () -> LoginItemModel

    init(
        model: AppModel,
        settings: SettingsModel,
        discovery: ClockDiscovery,
        loginItem: @autoclosure @escaping () -> LoginItemModel = LoginItemModel()
    ) {
        self.model = model
        self.settings = settings
        self.discovery = discovery
        self.loginItem = loginItem
    }

    var body: some View {
        // The app's own pixel switcher over the tab, not a `TabView`: the
        // system's tabs drew the accent blue above a window whose every
        // other control is in the clock's hand. Same state, same tabs.
        VStack(spacing: 0) {
            PixelSegmentedControl("Tab", selection: $settings.tab, title: \.title)
                .padding(12)
            Divider()
            switch settings.tab {
            case .clocks:
                ClocksTab(settings: settings, model: model, discovery: discovery)
            case .defaults:
                DefaultsTab(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .general:
                GeneralTab(model: model, loginItem: loginItem())
            }
        }
        // The titlebar is transparent under `glassWindow()`: the band clears
        // it the way the clock settings window's does.
        .padding(.top, 16)
        // A floor, not a box: the Clocks tab's content grows with every clock
        // a person adds, and a fixed frame CLIPS what a window exists to
        // show. The tabs scroll; the window resizes.
        .frame(minWidth: 460, minHeight: 380)
        .glassWindow()
    }
}

// MARK: - Clocks

/// The Clocks tab: the configured clocks in stored order, the two ways in,
/// and drag to reorder — the panel's sections follow this order.
///
/// The content of the Clocks section, moved here from the sheet (the spec's
/// own verdict: the right view in the wrong container).
private struct ClocksTab: View {
    let settings: SettingsModel
    @ObservedObject var model: AppModel
    @ObservedObject var discovery: ClockDiscovery
    /// What the last Add answered, cleared the moment the next attempt
    /// starts — the line never outlives the attempt that earned it.
    @State private var addOutcome: String?

    var body: some View {
        ClocksSettings(
            entries: settings.clockEntries,
            // A clock already configured is not a find: its address is in
            // the store, and offering it again is offering a duplicate.
            discovered: discovery.found.filter { found in
                !settings.clocks.contains { $0.address == found.address }
            },
            outcome: addOutcome,
            onMove: { settings.moveClock($0, to: $1) },
            onRename: { settings.renameClock($0, to: $1) },
            onRemove: { settings.removeClock($0) },
            onAddDiscovered: { discovered in
                let outcome = settings.addClock(from: discovered)
                addOutcome = ClockAddOutcomeLine.title(for: outcome, added: discovered.name)
            },
            onAddByAddress: { address in
                addOutcome = nil
                Task {
                    let outcome = await settings.addClock(address: address)
                    addOutcome = ClockAddOutcomeLine.title(for: outcome, added: address)
                }
            }
        )
        // No ScrollView and no padding around it: a grouped Form IS a scroll
        // view with its own insets, and nesting one inside another gave the
        // tab two sets of margins and a list that could not reach the window's
        // edges — the dead band the Clocks tab was read as.
        .onAppear { settings.clocksSectionVisibilityChanged(true) }
        .onDisappear { settings.clocksSectionVisibilityChanged(false) }
    }
}

// MARK: - Defaults

/// The Defaults tab: what a tile ADDED LATER starts from. Tiles already on a
/// clock keep their own settings — this tab answers nothing about them.
private struct DefaultsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            // Grouped, like the Clocks tab beside it: a plain `Form` and a
            // grouped one in one window are two different-looking settings
            // pages under one tab strip.
            Picker("New tile refresh", selection: Binding(
                get: { model.newTileIntervalSeconds ?? -1 },
                set: { model.setNewTileInterval(seconds: $0 < 0 ? nil : $0) }
            )) {
                Text("Each connector's own").tag(-1)
                Text("1 minute").tag(60)
                Text("5 minutes").tag(300)
                Text("10 minutes").tag(600)
                Text("15 minutes").tag(900)
                Text("30 minutes").tag(1800)
                Text("1 hour").tag(3600)
            }
            Text("The pace a tile added later starts at. A tile already on a clock keeps its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - General

/// The General tab: what is set once in the life of an installation, and the
/// machine-wide facts the schedule waits on. Internal rather than private
/// because its pins render it directly — the tab is a surface in its own
/// right, not an arrangement inside this file.
struct GeneralTab: View {
    @ObservedObject var model: AppModel
    private let loginItem: () -> LoginItemModel

    init(model: AppModel, loginItem: @autoclosure @escaping () -> LoginItemModel = LoginItemModel()) {
        self.model = model
        self.loginItem = loginItem
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Full Disk Access is not a permission anybody grants by accident,
            // and an app that quietly needs one is worse than an app that says
            // so.
            Text(FocusRuleLine.whichFocusesSilenceDependsOnFullDiskAccess)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Full Disk Access Settings…") { FullDiskAccess.openSettings() }
                .controlSize(.small)
            microphonesSection
            iconSection
            Divider()
            LoginItemSettings(item: loginItem())
        }
        .padding(20)
    }

    /// Which microphones the schedule waits for: every input the system
    /// reports, watched ones ticked — a gate the user cannot inspect is a
    /// gate they will eventually fight.
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

    /// The only thing this app writes to the device's flash, and the only
    /// way to take it back off. Its result line lives beside the button: an
    /// answer thrown to another surface is an answer nobody reads.
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
