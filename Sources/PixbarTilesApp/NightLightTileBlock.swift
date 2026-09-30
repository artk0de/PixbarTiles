import PixbarKit
import SwiftUI

// The night light's own block: which scene, how bright, how fast, which of
// its motions play, and whether it takes the clock by itself at night and to
// which tile it hands it back. The model does the storing — the block renders
// and reports every change as the whole edited config.

struct NightLightTileBlock: View {
    /// One entry of "In the morning show": a tile on this clock, or the
    /// first in order.
    struct MorningChoice: Hashable {
        let title: String
        let tileId: String?
    }

    let config: NightLightTileConfig
    let morning: [MorningChoice]
    let onChange: (NightLightTileConfig) -> Void

    var body: some View {
        Section("Scene") {
            Picker("Scene", selection: binding(\.scene)) {
                ForEach(NightLightScene.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            SteppedSlider(
                label: "Brightness",
                ladder: StepLadder(NightLightTileConfig.brightnessLevels.map(Double.init)),
                value: Double(config.brightness),
                caption: { "\(Int($0) * 20) %" },
                onCommit: { level in edit { $0.brightness = Int(level) } }
            )
            Picker("Speed", selection: binding(\.speed)) {
                ForEach(NightLightSpeed.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            // A switched-off motion is drawn still, not hidden.
            ForEach(Self.motionKeys(of: config.scene), id: \.self) { key in
                Toggle(Self.motionTitle(key), isOn: Binding(
                    get: { !config.stilled.contains(key) },
                    set: { moving in
                        edit {
                            if moving { $0.stilled.remove(key) } else { $0.stilled.insert(key) }
                        }
                    }
                ))
            }
        }
        Section {
            // The one tile that brings itself to the front: when its Focus or
            // hours begin, and back to the chosen tile when they end.
            Toggle("Switch the clock to it when it starts", isOn: binding(\.autoShow))
            Picker("When it stops, switch the clock to", selection: binding(\.morningTileId)) {
                ForEach(morning, id: \.self) { Text($0.title).tag($0.tileId) }
            }
            .disabled(!config.autoShow)
        } header: {
            Text("Turning on and off")
        } footer: {
            Text(Self.switchingNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What starts and stops the night light, said where the switches are:
    /// the words alone left the user asking what "by itself" meant.
    static let switchingNote =
        "It starts and stops with the Focus modes and hours set on the Common tab. "
        + "With the switch on, the clock shows it as it starts and moves to the tile picked above as it stops; "
        + "with it off, it runs only when you turn the clock to it yourself."

    private func edit(_ change: (inout NightLightTileConfig) -> Void) {
        var edited = config
        change(&edited)
        onChange(edited)
    }

    private func binding<Value>(_ path: WritableKeyPath<NightLightTileConfig, Value>) -> Binding<Value> {
        Binding(get: { config[keyPath: path] }, set: { value in edit { $0[keyPath: path] = value } })
    }

    /// The motion switches a scene offers.
    static func motionKeys(of scene: NightLightScene) -> [String] {
        scene.motionSwitches
    }

    /// A motion key as a switch's words: `cloudMotion` → "Cloud motion".
    static func motionTitle(_ key: String) -> String {
        var words: [String] = []
        for character in key {
            if character.isUppercase || words.isEmpty {
                words.append(String(character).lowercased())
            } else {
                words[words.count - 1].append(character)
            }
        }
        let sentence = words.joined(separator: " ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    /// "First tile in the list", then every other tile on the night light's clock in
    /// stored order.
    static func morningChoices(
        of key: TileKey, among records: [TileRecord], name: (TileRecord) -> String
    ) -> [MorningChoice] {
        [MorningChoice(title: "First tile in the list", tileId: nil)]
            + records
            .filter { $0.key.clockId == key.clockId && $0.key != key }
            .map { MorningChoice(title: name($0), tileId: $0.key.tileId) }
    }
}
