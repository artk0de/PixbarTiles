import Foundation
import Testing
@testable import AwtrixConnectorsApp

// macOS tells an app THAT a Focus is on and never WHICH. `INFocusStatusCenter`
// answers a boolean, Apple exposes no more than that, and so this app fell
// silent during Work as readily as during Sleep — which is the thing the user
// asked to have taken away.
//
// The mode's identity is in `~/Library/DoNotDisturb/DB/Assertions.json`, behind
// Full Disk Access, and these tests stand in for a machine that has granted it.
// Both fixtures at the bottom are that file, captured off this machine through
// a probe that held the permission: one with Работа on, one with every Focus
// switched off.
//
// One trap in it decides the whole parser, and it is not hypothetical. Beside
// the assertions that are ACTIVE sit two more lists of the same shape holding
// assertions that have ENDED, each wrapping the same
// `assertionDetailsModeIdentifier` key. The idle capture is the trap at its
// sharpest: no Focus is on at all, and the file still names Do Not Disturb and
// Sleep five records deep. A parser that hunts the file for mode identifiers
// instead of reading `storeAssertionRecords` reports Do Not Disturb on an idle
// Mac, for ever, and the app goes permanently mute with nothing on any surface
// to say why.

// MARK: - What the file says

// The trap with a Focus on. Both silencing identifiers this app knows are in
// these bytes, both finished, and the live answer is neither of them.
@Test func theActiveModeIsTheOneStillAssertedRatherThanOneThatHasEnded() {
    let file = Data(CapturedFocusDatabase.workActive.utf8)

    #expect(DoNotDisturbDatabase.activeMode(inAssertions: file) == .mode("com.apple.focus.work"))
}

// The trap with NOTHING on, which is the state the machine is in most of the
// day and the one worth more than the rest of this file. `storeAssertionRecords`
// is absent — not empty, absent — while five ended assertions naming Do Not
// Disturb, Sleep and Work sit beside it in 3,784 bytes of perfectly valid JSON.
@Test func anIdleMacIsNoFocusEvenThoughItsHistoryNamesDoNotDisturbAndSleep() {
    let file = Data(CapturedFocusDatabase.noFocus.utf8)

    #expect(DoNotDisturbDatabase.activeMode(inAssertions: file) == .noFocus)
}

// The guard on the two tests above: they only pose the trap while the fixtures
// still carry the ended records. Trimmed to "just the active bit" by somebody
// tidying up, both would pass against a parser that reads the whole file.
@Test func theCapturedFilesReallyCarryEndedDoNotDisturbAndSleepAssertions() {
    for text in [CapturedFocusDatabase.workActive, CapturedFocusDatabase.noFocus] {
        #expect(text.contains("storeInvalidationRecords"))
        #expect(text.contains("storeInvalidationRequestRecords"))
        #expect(text.contains("com.apple.donotdisturb.mode.default"))
        #expect(text.contains("com.apple.sleep.sleep-mode"))
    }
    // And the difference between them is exactly the key that says what is on
    // NOW: named once in the first, and nowhere at all in the second.
    #expect(CapturedFocusDatabase.workActive.components(separatedBy: "storeAssertionRecords").count == 2)
    #expect(CapturedFocusDatabase.noFocus.contains("storeAssertionRecords") == false)
}

// Absent is what an idle Mac was MEASURED to write, and the fixture above is
// that measurement. Empty was never seen and may never occur — it is defended
// against rather than observed, because the two readings differ by everything:
// taken as an unrecognised shape, an empty list would fall back to the boolean
// and put the old silence-every-Focus behaviour back on the commonest state
// there is.
@Test func anEmptyRecordListWouldAlsoBeNoFocus() {
    let empty = Data(#"{"data":[{"storeAssertionRecords":[]}],"header":{"version":8}}"#.utf8)

    #expect(DoNotDisturbDatabase.activeMode(inAssertions: empty) == .noFocus)
}

// Every way the read can fail, folded onto one answer. `.cannotTell` is not an
// error state here — without Full Disk Access it is what every launch of the
// shipped app gets, and on most machines it is the only answer it will ever
// get.
@Test func aFileThatCannotBeReadOrUnderstoodIsCannotTell() {
    #expect(DoNotDisturbDatabase.activeMode(inAssertions: Data("not json".utf8)) == .cannotTell)
    #expect(DoNotDisturbDatabase.activeMode(inAssertions: Data("{}".utf8)) == .cannotTell)
    // The envelope with no store inside it. Never observed, and a different
    // fact from a missing record list: this is a file whose shape has moved out
    // from under the app.
    #expect(DoNotDisturbDatabase.activeMode(inAssertions: Data(#"{"data":[]}"#.utf8)) == .cannotTell)
}

// Something is asserted and this app cannot name it. Not "no Focus" — that
// would speak through what might be Sleep — and the fallback is the one
// direction that is recoverable.
@Test func anAssertionThatDoesNotNameItsModeIsCannotTell() {
    let unnamed = Data(#"""
        {"data":[{"storeAssertionRecords":[
            {"assertionUUID":"E3AC6351-C7FD-4AF0-82E6-B6B6E5AD89CE",
             "assertionDetails":{"assertionDetailsIdentifier":"com.apple.controlcenter.dnd"}}
        ]}]}
        """#.utf8)

    #expect(DoNotDisturbDatabase.activeMode(inAssertions: unnamed) == .cannotTell)
}

// The path half, which the bytes half cannot prove: a URL that is not there
// reads the same as one TCC refuses, and the shipped app's own path is refused
// on every machine that has not granted the permission — including whichever
// one is running this suite.
@Test func aDatabaseThatIsNotThereIsCannotTell() throws {
    let missing = URL.temporaryDirectory.appending(path: "no-such-\(UUID().uuidString).json")

    #expect(DoNotDisturbDatabase.activeMode(at: missing) == .cannotTell)

    // The control at the other end, so the answer above is a refused read
    // rather than a reader that cannot read anything at all.
    let present = URL.temporaryDirectory.appending(path: "assertions-\(UUID().uuidString).json")
    try Data(CapturedFocusDatabase.workActive.utf8).write(to: present)
    defer { try? FileManager.default.removeItem(at: present) }

    #expect(DoNotDisturbDatabase.activeMode(at: present) == .mode("com.apple.focus.work"))
}

// The one string that decides whether any of this runs on a real machine.
// Nothing else here touches it — the parser is proved on bytes and the gate on
// stubs — so a typo in the path would ship as an app that answers `.cannotTell`
// for ever, which on this machine is indistinguishable from a permission nobody
// granted and would go unnoticed until somebody granted one.
@Test func theDatabaseIsLookedForWhereMacOSKeepsIt() {
    let url = DoNotDisturbDatabase.assertions

    #expect(url.isFileURL)
    #expect(url.path(percentEncoded: false).hasPrefix("/"))
    #expect(url.path(percentEncoded: false).hasSuffix("/Library/DoNotDisturb/DB/Assertions.json"))
}

// MARK: - What the gate does with it

// The two the user asked for, by identifier. The identifiers are Apple's own
// and are what the file carries; the names beside them in
// `ModeConfigurations.json` are localised — "Сон" on this machine — and a user
// can rename a Focus, so matching on those would be a gate that breaks on a
// rename or on somebody else's language.
@Test func doNotDisturbAndSleepSilenceTheSchedule() {
    let doNotDisturb = gate(inMode: "com.apple.donotdisturb.mode.default")
    let sleep = gate(inMode: "com.apple.sleep.sleep-mode")

    #expect(doNotDisturb.silence(quietHours: .default) == FocusGate.duringFocus)
    #expect(sleep.silence(quietHours: .default) == FocusGate.duringFocus)
}

// The whole point of the task. macOS reports a Focus, the app is authorized to
// believe it, and it speaks anyway — because the Focus is Work, and being at
// work is not a reason to be quiet.
@Test func everyOtherFocusIsSpokenThrough() {
    #expect(gate(inMode: "com.apple.focus.work").silence(quietHours: .default) == nil)
    #expect(gate(inMode: "com.apple.focus.personal-time").silence(quietHours: .default) == nil)
    // A Focus the user made themselves, which is an identifier no list can
    // enumerate. Silencing it would be the old behaviour surviving under a new
    // name for everybody who does not use Apple's own four.
    #expect(gate(inMode: "com.apple.focus.reading").silence(quietHours: .default) == nil)
}

// The idle Mac, end to end: the real file that names Do Not Disturb five times
// and has nothing asserted, through the parser, into the gate. It speaks.
@Test func anIdleMacSpeaks() {
    let idle = FocusGate(
        status: StubFocusStatus(
            access: .authorized,
            isFocused: false,
            activeMode: DoNotDisturbDatabase.activeMode(
                inAssertions: Data(CapturedFocusDatabase.noFocus.utf8)
            )
        ),
        now: { atHour(12) }
    )

    #expect(idle.silence(quietHours: .default) == nil)
}

// The fallback, and the direction it leans is deliberate. Told nothing about
// which Focus is on, the gate goes back to the boolean and treats every Focus
// as silencing — being quiet when it could have spoken is a joke the user
// misses, and the other way round is what wakes somebody at three in the
// morning.
@Test func aDatabaseThisAppCannotReadFallsBackToTheBoolean() {
    let focused = FocusGate(
        status: StubFocusStatus(access: .authorized, isFocused: true, activeMode: .cannotTell),
        now: { atHour(12) }
    )
    let idle = FocusGate(
        status: StubFocusStatus(access: .authorized, isFocused: false, activeMode: .cannotTell),
        now: { atHour(12) }
    )

    #expect(focused.silence(quietHours: .default) == FocusGate.duringFocus)
    // Not a mute: the boolean still decides both ways.
    #expect(idle.silence(quietHours: .default) == nil)
}

// The mode is read on ONE of the two branches, exactly as `isFocused` is. A
// centre this app may not believe is a centre whose database it has no business
// acting on either — the user's own window is what stands in, and a Work
// assertion must not reopen the night.
@Test func theModeIsNotConsultedWhileTheCenterIsUnauthorized() {
    let night = QuietWindow(startHour: 23, endHour: 8)
    let atThree = FocusGate(
        status: StubFocusStatus(
            access: .denied, isFocused: false, activeMode: .mode("com.apple.focus.work")
        ),
        now: { atHour(3) }
    )

    #expect(atThree.silence(quietHours: night) == FocusGate.duringQuietHours)
}

// MARK: - What the settings say about it

// Full Disk Access is not something a person grants by accident, and an app
// that silently needs one is worse than an app that asks for it. What the two
// states DO is the part that is certain, so that is what the sentence says.
//
// The words are checked here; that the sentence is DRAWN is on the list only a
// person can check, for the reason `theSettingsSayThatTheOverlayIsSharedWith
// TheWholeDevice` gives — SwiftUI backs a `Text` with no control and builds no
// accessibility tree outside a window, so pixels are the only other instrument
// and a standing sentence cannot differ from itself.
@Test func theSettingsSayWhatFullDiskAccessBuys() {
    let said = FocusRuleLine.whichFocusesSilenceDependsOnFullDiskAccess

    #expect(said.contains("Full Disk Access"))
    // Both halves of the trade, or the reader cannot tell what granting it
    // would change.
    #expect(said.contains("every Focus"))
    #expect(said.contains("Do Not Disturb"))
    #expect(said.contains("Sleep"))
    // Where to go. Not a button: see the constant for why one was not added.
    #expect(said.contains("System Settings"))
}

// MARK: - Helpers

/// A gate told that this mode is on, with everything else that still can saying
/// "be quiet".
///
/// `isFocused` is true throughout, so each expectation below is a statement
/// about the MODE alone: with the boolean already arguing for silence, anything
/// that speaks can only be speaking because of the identifier.
///
/// The clock reads noon, and it read three in the morning until the quiet
/// window started applying whatever the centre says. A hostile hour used to
/// sharpen these tests — one more thing arguing for silence that the mode had
/// to override — and now it simply decides them: every expectation here would
/// pass at three with the identifier ignored entirely. Noon is the hour at
/// which the mode is still the thing being measured.
private func gate(inMode identifier: String) -> FocusGate {
    FocusGate(
        status: StubFocusStatus(
            access: .authorized, isFocused: true, activeMode: .mode(identifier)
        ),
        now: { atHour(12) }
    )
}

/// `~/Library/DoNotDisturb/DB/Assertions.json`, as this machine wrote it, in
/// the two states that matter.
///
/// Captured through a probe holding Full Disk Access, which is the only way to
/// read the file at all, and re-indented for reading: every key, every
/// identifier, every number and every string is the file's own, and parsing
/// either text yields the same object its original bytes do.
///
/// Text in the suite rather than bundled resources, because the app's test
/// target declares no resources and adding some would mean editing
/// `Package.swift` for two fixtures.
private enum CapturedFocusDatabase {
    /// 5,265 bytes, Работа on. The live list holds one record; the history
    /// holds Do Not Disturb, Sleep and Личное from days earlier.
    static let workActive = #"""
        {
          "data": [
            {
              "storeInvalidationRecords": [
                {
                  "invalidationAssertion": {
                    "assertionUUID": "E3AC6351-C7FD-4AF0-82E6-B6B6E5AD89CE",
                    "assertionSource": {
                      "assertionClientIdentifier": "com.apple.controlcenter.dnd"
                    },
                    "assertionStartDateTimestamp": 805532646.93942702,
                    "assertionDetails": {
                      "assertionDetailsIdentifier": "com.apple.controlcenter.dnd",
                      "assertionDetailsModeIdentifier": "com.apple.donotdisturb.mode.default",
                      "assertionDetailsReason": "user-action"
                    }
                  },
                  "invalidationSource": {
                    "assertionClientIdentifier": "com.apple.controlcenter.dnd"
                  },
                  "invalidationDateTimestamp": 808589133.01483405,
                  "invalidationReason": "user-changed-state"
                },
                {
                  "invalidationAssertion": {
                    "assertionUUID": "110E372C-41A1-42AC-B793-4DDACC67157F",
                    "assertionSource": {
                      "assertionClientIdentifier": "com.apple.donotdisturb.private.sleeping-trigger",
                      "assertionSourceDeviceIdentifier": "C1E4A019-FDA0-4A69-99C4-B066A462EA43"
                    },
                    "assertionStartDateTimestamp": 808788602.556705,
                    "assertionDetails": {
                      "assertionDetailsIdentifier": "com.apple.donotdisturb.trigger.sleeping",
                      "assertionDetailsUserVisibleEndDate": 808819200,
                      "assertionDetailsModeIdentifier": "com.apple.sleep.sleep-mode",
                      "assertionDetailsReason": "schedule"
                    }
                  },
                  "invalidationSource": {
                    "assertionClientIdentifier": "com.apple.donotdisturb.private.sleeping-trigger",
                    "assertionSourceDeviceIdentifier": "C1E4A019-FDA0-4A69-99C4-B066A462EA43"
                  },
                  "invalidationDateTimestamp": 808819202.09141195,
                  "invalidationReason": "client-ended"
                },
                {
                  "invalidationAssertion": {
                    "assertionUUID": "FDE9FFD7-DCB7-4177-A557-40A2F3EDEE81",
                    "assertionSource": {
                      "assertionClientIdentifier": "com.apple.donotdisturb.private.smart-trigger",
                      "assertionSourceDeviceIdentifier": "C1E4A019-FDA0-4A69-99C4-B066A462EA43"
                    },
                    "assertionStartDateTimestamp": 808833600.32877898,
                    "assertionDetails": {
                      "assertionDetailsIdentifier": "com.apple.donotdisturb.trigger.smart",
                      "assertionDetailsModeIdentifier": "com.apple.focus.personal-time"
                    }
                  },
                  "invalidationSource": {
                    "assertionClientIdentifier": "com.apple.donotdisturb.private.smart-trigger"
                  },
                  "invalidationDateTimestamp": 808834210.15268803,
                  "invalidationReason": "client-replaced"
                },
                {
                  "invalidationAssertion": {
                    "assertionUUID": "2DC65ECF-CDDD-4953-90C5-205F64A429AE",
                    "assertionSource": {
                      "assertionClientIdentifier": "com.apple.donotdisturb.private.app-launch"
                    },
                    "assertionStartDateTimestamp": 808837482.75790703,
                    "assertionDetails": {
                      "assertionDetailsIdentifier": "com.tinyspeck.slackmacgap.donotdisturb.trigger",
                      "assertionDetailsModeIdentifier": "com.apple.focus.work",
                      "assertionDetailsReason": "system-state"
                    }
                  },
                  "invalidationSource": {
                    "assertionClientIdentifier": "com.apple.donotdisturb.private.app-launch"
                  },
                  "invalidationDateTimestamp": 808837521.35943699,
                  "invalidationReason": "client-ended"
                }
              ],
              "storeInvalidationRequestRecords": [
                {
                  "invalidationRequestPredicate": {
                    "invalidationPredicateType": "any"
                  },
                  "invalidationRequestReason": "user-changed-state",
                  "invalidationRequestUUID": "FD07E599-B191-4D57-B680-917B3A55B852",
                  "invalidationRequestSource": {
                    "assertionClientIdentifier": "com.apple.controlcenter.dnd"
                  },
                  "invalidationRequestDateTimestamp": 808589133.01483405
                },
                {
                  "invalidationRequestPredicate": {
                    "invalidationPredicateType": "client-identifier",
                    "clientIdentifierInvalidationPredicateIdentifiers": [
                      "com.apple.donotdisturb.private.sleeping-trigger"
                    ]
                  },
                  "invalidationRequestReason": "client-ended",
                  "invalidationRequestUUID": "C02AC1F2-930D-40AB-AFDE-BE503668A955",
                  "invalidationRequestSource": {
                    "assertionClientIdentifier": "com.apple.donotdisturb.private.sleeping-trigger",
                    "assertionSourceDeviceIdentifier": "C1E4A019-FDA0-4A69-99C4-B066A462EA43"
                  },
                  "invalidationRequestDateTimestamp": 808819202.09141195
                },
                {
                  "invalidationRequestPredicate": {
                    "invalidationPredicateType": "client-identifier",
                    "clientIdentifierInvalidationPredicateIdentifiers": [
                      "com.apple.donotdisturb.private.smart-trigger"
                    ]
                  },
                  "invalidationRequestReason": "client-replaced",
                  "invalidationRequestUUID": "99E7B979-6975-4959-A6BC-362B8DE796ED",
                  "invalidationRequestSource": {
                    "assertionClientIdentifier": "com.apple.donotdisturb.private.smart-trigger"
                  },
                  "invalidationRequestDateTimestamp": 808834210.15268803
                },
                {
                  "invalidationRequestPredicate": {
                    "invalidationPredicateType": "client-identifier",
                    "clientIdentifierInvalidationPredicateIdentifiers": [
                      "com.apple.donotdisturb.private.app-launch"
                    ]
                  },
                  "invalidationRequestReason": "client-replaced",
                  "invalidationRequestUUID": "3D7E8BE3-A0D3-4211-8F33-44ED01E877AD",
                  "invalidationRequestSource": {
                    "assertionClientIdentifier": "com.apple.donotdisturb.private.app-launch"
                  },
                  "invalidationRequestDateTimestamp": 808837482.75790703
                },
                {
                  "invalidationRequestPredicate": {
                    "invalidationPredicateType": "uuid",
                    "UUIDInvalidationPredicateUUIDs": [
                      "2DC65ECF-CDDD-4953-90C5-205F64A429AE"
                    ]
                  },
                  "invalidationRequestReason": "client-ended",
                  "invalidationRequestUUID": "D8283D97-962F-443B-816D-6D0024C26A2E",
                  "invalidationRequestSource": {
                    "assertionClientIdentifier": "com.apple.donotdisturb.private.app-launch"
                  },
                  "invalidationRequestDateTimestamp": 808837521.35943699
                }
              ],
              "storeAssertionRecords": [
                {
                  "assertionUUID": "97AB67C1-FC62-4B23-A74A-4A3553730A4C",
                  "assertionSource": {
                    "assertionClientIdentifier": "com.apple.donotdisturb.private.smart-trigger"
                  },
                  "assertionStartDateTimestamp": 808834210.15268803,
                  "assertionDetails": {
                    "assertionDetailsIdentifier": "com.apple.donotdisturb.trigger.smart",
                    "assertionDetailsModeIdentifier": "com.apple.focus.work"
                  }
                }
              ]
            }
          ],
          "header": {
            "version": 8,
            "timestamp": 808837521.36035502
          }
        }
        """#

    /// 3,784 bytes, every Focus switched off — and `storeAssertionRecords` is
    /// ABSENT rather than empty, which is the shape the parser is built around.
    /// Five ended assertions remain, naming Do Not Disturb, Sleep and Work.
    static let noFocus = #"""
        {
          "data": [
            {
              "storeInvalidationRequestRecords": [
                {
                  "invalidationRequestPredicate": {
                    "invalidationPredicateType": "any"
                  },
                  "invalidationRequestReason": "user-changed-state",
                  "invalidationRequestUUID": "DAF9DD27-3B48-43CB-8146-D37324BCEE0E",
                  "invalidationRequestSource": {
                    "assertionClientIdentifier": "com.apple.focus.activity-manager"
                  },
                  "invalidationRequestDateTimestamp": 808846217.10864902
                }
              ],
              "storeInvalidationRecords": [
                {
                  "invalidationAssertion": {
                    "assertionUUID": "E3AC6351-C7FD-4AF0-82E6-B6B6E5AD89CE",
                    "assertionSource": {
                      "assertionClientIdentifier": "com.apple.controlcenter.dnd"
                    },
                    "assertionStartDateTimestamp": 805532646.93942702,
                    "assertionDetails": {
                      "assertionDetailsIdentifier": "com.apple.controlcenter.dnd",
                      "assertionDetailsModeIdentifier": "com.apple.donotdisturb.mode.default",
                      "assertionDetailsReason": "user-action"
                    }
                  },
                  "invalidationSource": {
                    "assertionClientIdentifier": "com.apple.controlcenter.dnd"
                  },
                  "invalidationDateTimestamp": 808589133.01483405,
                  "invalidationReason": "user-changed-state"
                },
                {
                  "invalidationAssertion": {
                    "assertionUUID": "110E372C-41A1-42AC-B793-4DDACC67157F",
                    "assertionSource": {
                      "assertionClientIdentifier": "com.apple.donotdisturb.private.sleeping-trigger",
                      "assertionSourceDeviceIdentifier": "C1E4A019-FDA0-4A69-99C4-B066A462EA43"
                    },
                    "assertionStartDateTimestamp": 808788602.556705,
                    "assertionDetails": {
                      "assertionDetailsIdentifier": "com.apple.donotdisturb.trigger.sleeping",
                      "assertionDetailsUserVisibleEndDate": 808819200,
                      "assertionDetailsModeIdentifier": "com.apple.sleep.sleep-mode",
                      "assertionDetailsReason": "schedule"
                    }
                  },
                  "invalidationSource": {
                    "assertionClientIdentifier": "com.apple.donotdisturb.private.sleeping-trigger",
                    "assertionSourceDeviceIdentifier": "C1E4A019-FDA0-4A69-99C4-B066A462EA43"
                  },
                  "invalidationDateTimestamp": 808819202.09141195,
                  "invalidationReason": "client-ended"
                },
                {
                  "invalidationAssertion": {
                    "assertionUUID": "011415D9-1AF1-4429-8458-4F7CF5815AD9",
                    "assertionSource": {
                      "assertionClientIdentifier": "com.apple.donotdisturb.private.smart-trigger"
                    },
                    "assertionStartDateTimestamp": 808843192.20526695,
                    "assertionDetails": {
                      "assertionDetailsIdentifier": "com.apple.donotdisturb.trigger.smart",
                      "assertionDetailsModeIdentifier": "com.apple.focus.work"
                    }
                  },
                  "invalidationSource": {
                    "assertionClientIdentifier": "com.apple.donotdisturb.private.smart-trigger"
                  },
                  "invalidationDateTimestamp": 808843877.84105897,
                  "invalidationReason": "client-ended"
                },
                {
                  "invalidationAssertion": {
                    "assertionUUID": "2A389A36-677F-4EAC-8058-348CA8F4C901",
                    "assertionSource": {
                      "assertionClientIdentifier": "com.apple.donotdisturb.private.app-launch"
                    },
                    "assertionStartDateTimestamp": 808846152.98556006,
                    "assertionDetails": {
                      "assertionDetailsIdentifier": "com.tinyspeck.slackmacgap.donotdisturb.trigger",
                      "assertionDetailsModeIdentifier": "com.apple.focus.work",
                      "assertionDetailsReason": "system-state"
                    }
                  },
                  "invalidationSource": {
                    "assertionClientIdentifier": "com.apple.donotdisturb.private.app-launch"
                  },
                  "invalidationDateTimestamp": 808846175.62445402,
                  "invalidationReason": "client-ended"
                },
                {
                  "invalidationAssertion": {
                    "assertionUUID": "131E8D88-1422-45BC-908C-67ECCAC8CB73",
                    "assertionSource": {
                      "assertionClientIdentifier": "com.apple.focus.activity-manager"
                    },
                    "assertionStartDateTimestamp": 808846216.27966499,
                    "assertionDetails": {
                      "assertionDetailsIdentifier": "com.apple.donotdisturb.kit.lifetime.one-hour",
                      "assertionDetailsModeIdentifier": "com.apple.focus.work",
                      "assertionDetailsLifetime": {
                        "assertionDetailsDateIntervalLifetimeEndDateTimestamp": 808849816.27110696,
                        "assertionDetailsLifetimeType": "date-interval",
                        "assertionDetailsDateIntervalLifetimeStartDateTimestamp": 808846216.27110696
                      },
                      "assertionDetailsReason": "user-action"
                    }
                  },
                  "invalidationSource": {
                    "assertionClientIdentifier": "com.apple.focus.activity-manager"
                  },
                  "invalidationDateTimestamp": 808846217.10864902,
                  "invalidationReason": "user-changed-state"
                }
              ]
            }
          ],
          "header": {
            "version": 8,
            "timestamp": 808846217.11658204
          }
        }
        """#
}
