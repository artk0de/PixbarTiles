// Sources/PixbarKit/Secrets/HardwareIdentity.swift
import Foundation
import IOKit

/// The machine's own identity, as the secret file's key is derived from it.
public enum HardwareIdentity {
    /// The platform UUID the firmware reports — the same string System
    /// Information shows as "Hardware UUID". It does not change across
    /// reinstalls or user accounts, which is what makes a copied secrets file
    /// useless on another Mac. Nil when the registry does not answer.
    public static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        )
        return property?.takeRetainedValue() as? String
    }
}
