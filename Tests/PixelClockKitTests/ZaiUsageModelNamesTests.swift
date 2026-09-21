// Tests/PixelClockKitTests/ZaiUsageModelNamesTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The model vocabulary is the one place a name is written down without a live
// response having shown it: z.ai's Claude Code guide (docs.z.ai/devpack) is
// the source — `glm-5.3` and `glm-5.3-flash` in the settings example, the
// `[1m]` context suffix beside them, GLM-4.7 through GLM-5.2 on the devpack
// overview as the older generations the plan served — plus the one id a live
// `modelData` key has shown (`glm-4.6`). Recognition only: nothing anywhere
// drops a model for being outside the vocabulary.

@Suite struct ZaiUsageModelNamesTests {
    /// Every name the vocabulary carries resolves to itself — the guide's
    /// spellings, lowercase the way the settings example writes them.
    @Test func everyDocumentedModelResolvesToItself() {
        for id in ["glm-4.6", "glm-4.7", "glm-5.1", "glm-5.2", "glm-5.3", "glm-5.3-flash"] {
            #expect(ZaiUsage.canonicalModel(id) == id)
        }
    }

    /// The guide writes the names in prose uppercased ("GLM-5.3-Flash") and
    /// settings lowercase; both are the one model.
    @Test func theGuideProseSpellingResolvesToTheSettingsSpelling() {
        #expect(ZaiUsage.canonicalModel("GLM-5.3") == "glm-5.3")
        #expect(ZaiUsage.canonicalModel("GLM-5.3-Flash") == "glm-5.3-flash")
    }

    /// The `[1m]` suffix is Claude Code's context-window marker, not a
    /// different model — the guide's own manual configuration uses it.
    @Test func theContextSuffixNamesTheSameModel() {
        #expect(ZaiUsage.canonicalModel("glm-5.3[1m]") == "glm-5.3")
        #expect(ZaiUsage.canonicalModel("GLM-5.3-Flash[1m]") == "glm-5.3-flash")
    }

    /// A model outside the vocabulary has no canonical name — and nothing
    /// treats that as an error.
    @Test func aModelTheVocabularyDoesNotCarryResolvesToNothing() {
        #expect(ZaiUsage.canonicalModel("some-future-model") == nil)
    }
}
