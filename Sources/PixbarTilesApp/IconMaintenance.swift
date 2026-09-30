import Foundation
import PixbarKit

/// Takes the icons this app uploaded back off the clock's flash, and says how
/// that went.
@MainActor
final class IconMaintenance: ObservableObject {
    /// The removal of the icons the app uploaded — never two at once.
    static let iconRemoval = "iconRemoval"

    /// How the last removal went, and nil until one has been asked for.
    @Published private(set) var iconStatus: String?
    private let installer: CatalogueIconInstaller
    /// The model's task bag: teardown waits on the removal through it.
    private let taskBag: TaskBag

    init(installer: CatalogueIconInstaller, taskBag: TaskBag) {
        self.installer = installer
        self.taskBag = taskBag
    }

    /// Takes this app's icons back off the flash, because the user asked.
    ///
    /// Owned here rather than by the button's action closure, for the same
    /// reason the model's `runNow` is: teardown can only wait for a task it holds. One at a
    /// time — a second press while one is running would race two passes over
    /// the same record.
    func removeInstalledIcons() {
        guard !taskBag.isRunning(Self.iconRemoval) else { return }
        // Said before the work, not after it. `removeUploaded` sends one DELETE
        // per recorded icon, and against a device that has stopped answering
        // each one costs the transport's full 15 seconds — the same silence the
        // run button had, on a button one divider away.
        iconStatus = "removing…"
        taskBag.startIfIdle(Self.iconRemoval) { [weak self] in
            await self?.reportIconRemoval()
        }
    }

    private func reportIconRemoval() async {
        do {
            let removed = try await installer.removeUploaded()
            iconStatus = removed.isEmpty
                ? "nothing this app uploaded"
                : "removed \(removed.joined(separator: ", "))"
        } catch let CatalogueIconInstaller.Failure.notRemoved(names) {
            iconStatus = "could not remove \(names.joined(separator: ", "))"
        } catch {
            iconStatus = "failed: \(String(describing: error).prefix(60))"
        }
    }
}
