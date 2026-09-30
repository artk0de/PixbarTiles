import Testing
@testable import PixbarKit

@Suite struct IntMathTests {
    @Test func divisionFloorsLikePythonAndTruncatesLikeSdiv() {
        #expect(IntMath.floorDiv(-7, 2) == -4)      // python: -7 // 2
        #expect(IntMath.floorDiv(7, -2) == -4)
        #expect(IntMath.floorDiv(7, 2) == 3)
        #expect(IntMath.floorMod(-3, 52) == 49)     // python: -3 % 52
        #expect(IntMath.floorMod(-99, 52) == 5)
        #expect(IntMath.truncDiv(-7, 2) == -3)      // nlengine.sdiv(-7, 2)
        #expect(IntMath.truncDiv(7, -2) == -3)
    }

    @Test func theSineTableIsPythonsRoundedSine() {
        #expect(IntMath.sin.count == 256)
        #expect(IntMath.sin[0] == 0)
        #expect(IntMath.sin[64] == 127)
        #expect(IntMath.sin[128] == 0)
        #expect(IntMath.sin[192] == -127)
        #expect(IntMath.sin[1] == 3)                // round(127·sin(2π/256)) = 3
        #expect(IntMath.sin[32] == 90)              // round(127·sin(π/4)) = 90
        #expect(IntMath.sin.reduce(0, +) == 0)
    }

    @Test func isqrtIsTheFloorOfTheRoot() {
        #expect(IntMath.isqrt(0) == 0)
        #expect(IntMath.isqrt(15) == 3)
        #expect(IntMath.isqrt(16) == 4)
        #expect(IntMath.isqrt(16 * (55 * 55 + 18 * 18)) == 231)   // python: math.isqrt(16*(55**2+18**2))
    }

    @Test func oscillatorsMatchNlengine() {
        #expect(IntMath.phase(10, 200, 3, 7) == 45)                 // (10*3*256//200 + 7) & 255
        #expect(IntMath.swing(10, 200, 3, 7, -1000, 1000) == 889)   // nlengine.swing(10,200,3,7,-1000,1000)
        #expect(IntMath.ramp(50, 240, 2, 0, -800, 1000) == 690)     // nlengine.ramp(50,240,2,0,-800,1000)
    }

    @Test func jitterIsTheScenesSpatialHash() {
        #expect(IntMath.jitter(0, 0, 160) == 110)     // horizon.jitter(0, 0)
        #expect(IntMath.jitter(51, 15, 160) == -15)
        #expect(IntMath.jitter(12, 7, 160) == -127)
        #expect(IntMath.jitter(30, 10, 6) == -2)      // glow.jitter(30, 10)
        #expect(IntMath.jitter(7, 51, 6) == -4)
    }

    @Test func panelLevelsMatchTheMeasuredBands() {
        #expect(PanelLevels.red(7) == 0)
        #expect(PanelLevels.red(8) == 40)
        #expect(PanelLevels.red(64) == 160)
        #expect(PanelLevels.red(255) == 255)
        #expect(PanelLevels.stepUp(8) == 20)
        #expect(PanelLevels.stepUp(200, 3) == 185)
        #expect(PanelLevels.amber(255, 144) == 144)
        #expect(PanelLevels.amber(160, 144) == 100)
        #expect(PanelLevels.amber(144, 100) == 40)
        #expect(PanelLevels.amber(40, 40) == 0)
    }
}
