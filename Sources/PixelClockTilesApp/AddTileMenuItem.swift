/// One entry in the panel's Add tile menu: what it is called, whether it can
/// join the current clock, and what adding it does.
///
/// A plain value. The menu renders reasons and does not compute them (D9) —
/// `Availability` is carried whole from whoever built the item, so 5b maps
/// `TileCatalogue.availability` onto it without this type knowing the
/// catalogue exists.
struct AddTileMenuItem: Equatable {
    enum Availability: Equatable {
        case available
        case unavailable(reason: String)
    }

    let title: String
    let availability: Availability
    let onAdd: () -> Void

    init(title: String, availability: Availability, onAdd: @escaping () -> Void) {
        self.title = title
        self.availability = availability
        self.onAdd = onAdd
    }

    static func == (lhs: AddTileMenuItem, rhs: AddTileMenuItem) -> Bool {
        lhs.title == rhs.title && lhs.availability == rhs.availability
    }
}
