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
        Section("Night and morning") {
            // The one tile that brings itself to the front: when its hours or
            // Sleep begin, and back to the morning tile when they end.
            Toggle("Turn on by itself", isOn: binding(\.autoShow))
            Picker("In the morning show", selection: binding(\.morningTileId)) {
                ForEach(morning, id: \.self) { Text($0.title).tag($0.tileId) }
            }
            .disabled(!config.autoShow)
        }
    }

    private func edit(_ change: (inout NightLightTileConfig) -> Void) {
        var edited = config
        change(&edited)
        onChange(edited)
    }

    private func binding<Value>(_ path: WritableKeyPath<NightLightTileConfig, Value>) -> Binding<Value> {
        Binding(get: { config[keyPath: path] }, set: { value in edit { $0[keyPath: path] = value } })
    }

    /// The motion switches a scene declares, in its layers' order, once each.
    static func motionKeys(of scene: NightLightScene) -> [String] {
        var seen: Set<String> = []
        return scene.animatedScene.layers.compactMap(\.key).filter { seen.insert($0).inserted }
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

    /// "First in order", then every other tile on the night light's clock in
    /// stored order.
    static func morningChoices(
        of key: TileKey, among records: [TileRecord], name: (TileRecord) -> String
    ) -> [MorningChoice] {
        [MorningChoice(title: "First in order", tileId: nil)]
            + records
            .filter { $0.key.clockId == key.clockId && $0.key != key }
            .map { MorningChoice(title: name($0), tileId: $0.key.tileId) }
    }
}
