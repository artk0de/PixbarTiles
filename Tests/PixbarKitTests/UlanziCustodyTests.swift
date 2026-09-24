// Tests/PixbarKitTests/UlanziCustodyTests.swift
import Foundation
import Testing
@testable import PixbarKit

/// In-memory stand-in for the UserDefaults record.
final class MemoryAppRecord: UlanziAppRecord, @unchecked Sendable {
    private var storage: [String: [String]] = [:]

    func names(forClock clockId: String) -> [String] { storage[clockId] ?? [] }
    func save(_ names: [String], forClock clockId: String) { storage[clockId] = names }
}

@Suite struct UlanziCustodyTests {
    let recorder = RecordingTransport()

    func makeCustody() -> UlanziCustody {
        UlanziCustody(
            device: UlanziDevice(host: "192.168.1.72", transport: recorder),
            record: MemoryAppRecord(),
            clockId: "clock-1"
        )
    }

    func custodyHolding(_ names: [String], listed: [String]) async -> UlanziCustody {
        recorder.body = Self.listAnswer(listed)
        let custody = makeCustody()
        for name in names {
            // Claim by tile id: "pct-weather" is tile "weather"'s name.
            _ = try? await custody.appName(forTile: String(name.dropFirst("pct-".count)))
        }
        return custody
    }

    static func listAnswer(_ names: [String]) -> Data {
        let joined = names.map { "\"\($0)\"" }.joined(separator: ",")
        return Data((#"{"code":200,"message":"ok","data":["# + joined + #"]}"#).utf8)
    }

    @Test func appNameIsPrefixedTileId() async throws {
        #expect(try await makeCustody().appName(forTile: "weather") == "pct-weather")
    }

    @Test func theSameTileClaimsTheSameNameTwice() async throws {
        let custody = makeCustody()
        #expect(try await custody.appName(forTile: "weather") == "pct-weather")
        #expect(try await custody.appName(forTile: "weather") == "pct-weather")
        let owned = await custody.ownedNames
        #expect(owned.count == 1)
    }

    @Test func twentyFirstAppPassesTwentySecondThrows() async throws {
        let custody = makeCustody()
        for i in 0..<21 { _ = try await custody.appName(forTile: "tile\(i)") }   // budget full
        await #expect(throws: UlanziError.self) {
            try await custody.appName(forTile: "one-more")
        }
        // the failed claim must not consume budget
        let owned = await custody.ownedNames
        #expect(owned.count == 21)
    }

    @Test func sweepRemovesStaleNamesTheDeviceStillLists() async throws {
        recorder.body = Self.listAnswer(["pct-a", "pct-b", "pct-z"])
        let custody = await custodyHolding(["pct-a", "pct-b", "pct-z"], listed: ["pct-a", "pct-b", "pct-z"])

        try await custody.sweep(liveTiles: ["a", "b"])

        let requests = recorder.requests
        #expect(requests.count == 2)   // one customList read, one delete
        #expect(requests.last?.url?.query == "name=pct-z")
        let owned = await custody.ownedNames
        #expect(owned == ["pct-a", "pct-b"])
    }

    @Test func sweepDropsLostNamesWithoutDelete() async throws {
        // a reboot wiped every app but pct-a (E9): there is nothing left to
        // delete, so the sweep deletes nothing
        recorder.body = Self.listAnswer(["pct-a"])
        let custody = await custodyHolding(["pct-a", "pct-b", "pct-z"], listed: ["pct-a"])

        try await custody.sweep(liveTiles: ["a", "b", "z"])

        #expect(recorder.requests.count == 1)   // the customList read alone
        let owned = await custody.ownedNames
        #expect(owned == ["pct-a"])
    }

    @Test func releaseAllEmptiesEveryPage() async throws {
        let custody = await custodyHolding(["pct-a", "pct-b"], listed: ["pct-a", "pct-b"])

        try await custody.releaseAll()

        let queries = recorder.requests.compactMap(\.url?.query)
        #expect(queries == ["name=pct-a", "name=pct-b"])
        let owned = await custody.ownedNames
        #expect(owned == [])
    }
}
