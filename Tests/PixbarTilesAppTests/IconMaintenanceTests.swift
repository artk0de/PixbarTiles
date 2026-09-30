import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// Taking this app's icons back off the flash: said before the work, reported
/// after it, never two passes at once.
@MainActor
@Suite struct IconMaintenanceTests {
    private func maintenance(uploads: InMemoryUploadedIconStore = InMemoryUploadedIconStore()) -> IconMaintenance {
        let transport = StubTransport()
        let device = AwtrixDevice(host: "10.0.0.5", transport: transport)
        return IconMaintenance(
            installer: CatalogueIconInstaller(device: device, transport: transport, uploads: uploads),
            taskBag: TaskBag()
        )
    }

    @Test func aRemovalSaysSoAtOnceAndReportsWhatItFound() async {
        let subject = maintenance()
        #expect(subject.iconStatus == nil)
        subject.removeInstalledIcons()
        #expect(subject.iconStatus == "removing…")
        #expect(await waitUntil { subject.iconStatus == "nothing this app uploaded" })
    }
}
