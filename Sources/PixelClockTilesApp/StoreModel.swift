import Combine
import Foundation
import Observation
import PixelClockKit

/// The tile store's facade: the shelves, the cards, and the one action a
/// card carries — aimed at the clock whose gear opened the store.
///
/// The availability mapping is the store's own reading of the catalogue's
/// answer, and it exists because a menu can drop a row but a grid cannot:
/// a grid with holes in it reads as a bug. So `.notListed` — a single tile
/// of that connector already on this clock — draws as an "Added" card,
/// disabled and with no reason, exactly as the spec's table maps it. The kit
/// rule does not change; the case is renamed at the presentation boundary.
@MainActor
@Observable
final class StoreModel {
    private let model: AppModel
    /// The subscription that hears every change the model publishes — a
    /// tile added anywhere moves what this clock's cards may offer.
    private var pulse: AnyCancellable?
    private var scheduled: Task<Void, Never>?

    /// The clock the store is aimed at: the gear that opened it. Re-aimed,
    /// not re-opened — one store window, whatever clock asks.
    var clockId: UUID?
    /// The shelf showing, or nil for All. Every assignment refiles the
    /// cards, so the sidebar's tap and a re-aim's reset both land at once.
    var category: TileCategory? {
        didSet { rebuildNow() }
    }
    /// The tile the last successful add put on the clock — the first half
    /// of the two-step commit. The window sees it change and opens the tile
    /// settings on it; a tile added with defaults and never configured is
    /// the mistake this second step exists to prevent.
    private(set) var lastAdded: TileKey?
    private(set) var cards: [StoreCard] = []

    init(model: AppModel) {
        self.model = model
        rebuildNow()
        pulse = model.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildAfterTheChangeLands() }
        }
    }

    /// One card on the grid: what the tile is, and what pressing it does.
    struct StoreCard: Equatable {
        enum Action: Equatable {
            /// No tile of this connector is on the clock: pressing adds it.
            case add
            /// One already is — the catalogue's `.notListed`, drawn as
            /// Added rather than dropped, because a grid with holes reads
            /// as a bug.
            case added
            /// The catalogue refused, and the card says why.
            case refused(reason: String)
        }

        let candidate: TileCandidate
        let title: String
        let action: Action
    }

    /// Aims the store at a clock and puts it on All — the state a gear's
    /// "Add tile…" means, whatever the store showed last time.
    func show(_ clockId: UUID) {
        self.clockId = clockId
        // The assignment itself refiles the cards through `didSet` — even
        // when nil was already showing, so a re-aim never keeps the cards
        // of the clock the store has just left.
        category = nil
    }

    /// Pressing an add card: the tile goes on the clock with its defaults,
    /// and its settings window opens on it — the two-step commit, so a tile
    /// is never added and forgotten.
    func add(_ card: StoreCard) {
        guard case .add = card.action, let clockId else { return }
        if case .saved = model.addTile(card.candidate.connectorId, to: clockId) {
            let key = TileKey(clockId: clockId, connectorId: card.candidate.connectorId)
            model.openDetail(for: key)
            lastAdded = key
        }
    }

    // MARK: - The projection

    private func rebuildNow() {
        guard let clockId else {
            cards = []
            return
        }
        cards = model.tileCandidates().compactMap { offer in
            guard let candidate = model.candidate(for: offer.connectorId),
                category == nil || candidate.category == category
            else { return nil }
            let action: StoreCard.Action
            switch model.availability(of: offer.connectorId, on: clockId) {
            case .available:
                action = .add
            case .notListed:
                action = .added
            case let .unavailable(reason):
                action = .refused(reason: reason)
            }
            return StoreCard(candidate: candidate, title: offer.name, action: action)
        }
    }

    private func rebuildAfterTheChangeLands() {
        scheduled?.cancel()
        scheduled = Task { [weak self] in self?.rebuildNow() }
    }
}
