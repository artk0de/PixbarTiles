// Tests/PixbarKitTests/ZaiUsageDecoderTests.swift
import Foundation
import Testing
@testable import PixbarKit

// The z.ai dashboard answers are nobody's documented contract: the routes are
// the community trackers' discovery of what the web console calls, and z.ai
// documents none of it. So the decoder pins ONLY the fields a live response
// has been seen to carry (tokn-provider-zai's quota.rs and zai-usage-tracker's
// zaiService.ts are the two observations this suite stands on), tolerates
// missing and extra fields everywhere, and drops what it cannot place instead
// of failing the whole answer. The one deliberate widening: per-model usage
// (`modelData`) is decoded keyed by the id AS THE WIRE SPELLS IT — the guide's
// model names live in `ZaiUsage`'s vocabulary, which recognises but never
// gates a key.

/// The quota answer as the community trackers saw it: an envelope, a plan
/// level, and one limit object per window — tokens in 5-hour and weekly
/// buckets, MCP spend in a time bucket — with fields this decoder never needs.
private let quotaAnswer = Data("""
{"data":{"level":"PRO","limits":[
  {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":12.4,
   "currentValue":99400000,"usage":800000000,"nextResetTime":1726000000000,"x":true},
  {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":34.5,
   "currentValue":310500000,"usage":900000000,"nextResetTime":1726500000000},
  {"type":"TIME_LIMIT","percentage":7,"currentValue":7,"usage":100,
   "nextResetTime":1727000000000,"extra":{"deep":[1,2]}}
]}}
""".utf8)

/// The model-usage answer, same envelope, the two totals the trackers read
/// and the per-model breakdown the guide's model names give meaning to. The
/// entry shape is the one a live key has shown (`tokens`); everything else a
/// model entry may one day carry is extra.
private let modelUsageAnswer = Data("""
{"data":{"totalUsage":{"totalModelCallCount":42,"totalTokensUsage":1234567},
  "modelData":{"glm-4.6":{"tokens":999}},"span":"7d"}}
""".utf8)

@Suite struct ZaiUsageDecoderTests {
    // MARK: - The quota answer

    @Test func theQuotaAnswerDecodesIntoTheThreeWindowsAndTheLevel() {
        let limits = ZaiUsageDecoder.limits(from: quotaAnswer)

        #expect(limits.level == "PRO")
        #expect(limits.fiveHour?.percentUsed == 12)
        #expect(limits.fiveHour?.usedTokens == 99_400_000)
        #expect(limits.fiveHour?.capTokens == 800_000_000)
        #expect(limits.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_726_000_000))
        #expect(limits.weekly?.percentUsed == 35)
        #expect(limits.weekly?.capTokens == 900_000_000)
        #expect(limits.mcpMonthly?.percentUsed == 7)
        #expect(limits.mcpMonthly?.usedTokens == 7)
        #expect(limits.mcpMonthly?.capTokens == 100)
    }

    /// Some deployments unwrap; both readings answer the same.
    @Test func aBareAnswerWithoutTheEnvelopeDecodesTheSame() {
        let bare = Data("""
        {"level":"MAX","limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":1}]}
        """.utf8)

        let limits = ZaiUsageDecoder.limits(from: bare)

        #expect(limits.level == "MAX")
        #expect(limits.fiveHour?.percentUsed == 1)
        #expect(limits.weekly == nil)
    }

    /// A window nobody can place — an unknown bucket pair, a foreign type — is
    /// dropped by itself; the answer's other windows survive it.
    @Test func unknownLimitShapesAreDroppedWithoutFailingTheRest() {
        let mixed = Data("""
        {"data":{"limits":[
          {"type":"TOKENS_LIMIT","unit":9,"number":2,"percentage":50},
          {"type":"REQUESTS_LIMIT","unit":3,"number":5,"percentage":10},
          {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":20}
        ]}}
        """.utf8)

        let limits = ZaiUsageDecoder.limits(from: mixed)

        #expect(limits.fiveHour == nil)
        #expect(limits.weekly?.percentUsed == 20)
        #expect(limits.mcpMonthly == nil)
    }

    /// Fields the answer has not shown yet leave their value out; the windows
    /// that do decode still stand.
    @Test func missingFieldsLeaveTheirValueNil() {
        let sparse = Data("""
        {"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5}]}}
        """.utf8)

        let limits = ZaiUsageDecoder.limits(from: sparse)

        #expect(limits.fiveHour?.percentUsed == nil)
        #expect(limits.fiveHour?.usedTokens == nil)
        #expect(limits.fiveHour?.capTokens == nil)
        #expect(limits.fiveHour?.resetsAt == nil)
    }

    /// No percentage on the wire is not the end: what was spent against what
    /// says the same thing. The bucket that gives neither has no figure.
    @Test func aMissingPercentageIsDerivedFromSpentAgainstCap() {
        let derived = Data("""
        {"data":{"limits":[
          {"type":"TOKENS_LIMIT","unit":6,"number":1,"currentValue":250,"usage":1000}
        ]}}
        """.utf8)

        #expect(ZaiUsageDecoder.limits(from: derived).weekly?.percentUsed == 25)
    }

    /// The live answer, verbatim as the pro plan returned it on 2026-09-23:
    /// the buckets are `CREDIT_LIMIT`, not the `TOKENS_LIMIT` the community
    /// trackers recorded, and a window with nothing spent carries no reset.
    /// Reading only the old spelling dropped both windows and the TC002 face
    /// drew dashes.
    @Test func theLiveCreditLimitAnswerPlacesBothWindows() {
        let live = Data("""
        {"code":200,"msg":"Operation successful","data":{"limits":[
          {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":12000,"currentValue":0,
           "remaining":12000,"percentage":0},
          {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":60000,"currentValue":60032,
           "remaining":0,"percentage":100,"nextResetTime":1790443012983}
        ],"level":"pro"},"success":true}
        """.utf8)

        let limits = ZaiUsageDecoder.limits(from: live)

        #expect(limits.level == "pro")
        #expect(limits.fiveHour?.percentUsed == 0)
        #expect(limits.fiveHour?.resetsAt == nil)
        #expect(limits.weekly?.percentUsed == 100)
        #expect(limits.weekly?.usedTokens == 60032)
        #expect(limits.weekly?.capTokens == 60000)
        #expect(limits.weekly?.resetsAt == Date(timeIntervalSince1970: 1_790_443_012.983))
    }

    /// A quota answer that is not JSON, or carries nothing placeable, is an
    /// answer with nothing in it — never a thrown failure. The limits are the
    /// informational half of the reading; a dead route says so by being empty.
    @Test func garbageAndEmptyAnswersReadAsEmpty() {
        #expect(ZaiUsageDecoder.limits(from: Data("not json".utf8)) == ZaiUsageLimits())
        #expect(ZaiUsageDecoder.limits(from: Data("{}".utf8)) == ZaiUsageLimits())
    }

    // MARK: - The model-usage answer

    @Test func theModelUsageAnswerGivesUpItsTotals() {
        let totals = ZaiUsageDecoder.totals(from: modelUsageAnswer)

        #expect(totals.modelCalls == 42)
        #expect(totals.tokens == 1_234_567)
    }

    /// The per-model breakdown rides the same answer: one entry per model the
    /// period used, its id as the wire spells it and the tokens it spent.
    @Test func theModelUsageAnswerCarriesItsPerModelTokens() {
        let totals = ZaiUsageDecoder.totals(from: modelUsageAnswer)

        #expect(totals.models == [ZaiUsageModelUsage(id: "glm-4.6", tokens: 999)])
    }

    /// Every entry is carried, keyed or not by the vocabulary — the guide's
    /// model names recognise, they do not gate — and an entry whose tokens are
    /// missing still stands. A value that is not an object has no shape to
    /// carry and is dropped by itself.
    @Test func everyModelEntryIsCarriedRegardlessOfItsName() {
        let mixed = Data("""
        {"data":{"modelData":{
          "glm-5.3-flash[1m]":{"tokens":7},
          "some-future-model":{},
          "glm-4.6":5,
          "glm-4.7":{"tokens":12}}}}
        """.utf8)

        let totals = ZaiUsageDecoder.totals(from: mixed)

        // A keyed answer has no order to promise — the entries compare as a set.
        #expect(Set(totals.models) == [
            ZaiUsageModelUsage(id: "glm-5.3-flash[1m]", tokens: 7),
            ZaiUsageModelUsage(id: "some-future-model", tokens: nil),
            ZaiUsageModelUsage(id: "glm-4.7", tokens: 12),
        ])
    }

    /// A model-usage answer with no breakdown — or none that is an object —
    /// reads as a reading with no models, the same empty answer as ever.
    @Test func aModelUsageAnswerWithoutAModelBreakdownReadsAsModelless() {
        let modelless = Data("""
        {"data":{"totalUsage":{"totalModelCallCount":9,"totalTokensUsage":100}}}
        """.utf8)

        #expect(ZaiUsageDecoder.totals(from: modelless).models.isEmpty)
        #expect(ZaiUsageDecoder.totals(from: Data("{}".utf8)) == ZaiUsageTotals())
        #expect(ZaiUsageDecoder.totals(from: Data("[1,2]".utf8)) == ZaiUsageTotals())
    }

    /// The totals and the breakdown are two halves of one answer: a response
    /// that carries only the breakdown still gives it up.
    @Test func aBreakdownSurvivesTotalsGoingMissing() {
        let onlyModels = Data("""
        {"data":{"modelData":{"glm-4.6":{"tokens":999}}}}
        """.utf8)

        let totals = ZaiUsageDecoder.totals(from: onlyModels)

        #expect(totals.modelCalls == nil)
        #expect(totals.models == [ZaiUsageModelUsage(id: "glm-4.6", tokens: 999)])
    }

    // MARK: - The reading

    /// The connector's reading is the two answers merged; either half can be
    /// empty because its route died or said nothing placeable.
    @Test func theReadingCarriesBothAnswers() {
        let reading = ZaiUsageReading(
            limits: ZaiUsageDecoder.limits(from: quotaAnswer),
            totals: ZaiUsageDecoder.totals(from: modelUsageAnswer),
            observedAt: Date(timeIntervalSince1970: 1_726_000_100)
        )

        #expect(reading.level == "PRO")
        #expect(reading.fiveHour?.percentUsed == 12)
        #expect(reading.weekly?.percentUsed == 35)
        #expect(reading.mcpMonthly?.percentUsed == 7)
        #expect(reading.totalModelCalls == 42)
        #expect(reading.totalTokens == 1_234_567)
        #expect(reading.models == [ZaiUsageModelUsage(id: "glm-4.6", tokens: 999)])
        #expect(reading.observedAt == Date(timeIntervalSince1970: 1_726_000_100))
    }
}
