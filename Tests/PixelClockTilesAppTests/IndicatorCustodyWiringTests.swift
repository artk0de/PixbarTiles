import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The display and the custody are each proven on their own. This is the one
// line between them in `live()` — the kind of seam this project has already
// once found green on both banks with nothing crossing it.
@Test @MainActor func theCornersAreLitThroughTheClockTheAppTalksTo() async throws {
    let suite = "lamps-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let transport = StubTransport(body: onlineStats)
    let subject = AppModel.live(
        defaults: defaults,
        transport: transport,
        anecdoteStore: FileManager.default.temporaryDirectory
            .appendingPathComponent("lamps-\(UUID().uuidString).json")
    )

    subject.refreshLamps()

    // Both corners on the first showing, whatever this machine's tunnels and
    // Focus say: nothing is known yet about what the lamps show.
    #expect(await waitUntil {
        Set(transport.requests.compactMap(\.url?.path).filter { $0.hasPrefix("/api/indicator") })
            == ["/api/indicator1", "/api/indicator3"]
    })
}
