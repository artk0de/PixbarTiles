import Foundation
import Testing
@testable import PixbarKit

// What a face hands the AWTRIX session. The clock draws the scene; the Mac
// plays the audio. The buzzer is the clock's own sound, so a jingle is part of
// what the clock is asked to show.

@Test func theSoundTravelsBesideTheSceneRatherThanInsideIt() {
    let clip = SpokenClip(url: URL(fileURLWithPath: "/tmp/a.wav"))

    let delivery = AwtrixDelivery(
        text: "hi", jingle: "nokia:d=4,o=5,b=225:8e6",
        localAudio: [clip], holdUntilAudioEnds: true
    )

    #expect(delivery.localAudio == [clip])
    #expect(delivery.holdUntilAudioEnds)
    #expect(delivery.scene.text == "hi")
    #expect(delivery.scene.jingle == "nokia:d=4,o=5,b=225:8e6")
}

// Every field a producer can name reaches the scene. This is the crossing the
// progress bar once failed to make — green on both banks, nothing crossing.
@Test func aDeliveryReadsAsTheSceneItCarries() {
    let delivery = AwtrixDelivery(
        text: "83%",
        icon: .bundled("ClaudeStar"),
        progress: ProgressBar(percent: 83, fill: "#FFD24A", track: "#303030"),
        duration: 10,
        color: "#D97757",
        surface: .app("claude"),
        lifetime: 900,
        overlay: .rain
    )

    #expect(delivery.text == "83%")
    #expect(delivery.icon == .bundled("ClaudeStar"))
    #expect(delivery.progress == ProgressBar(percent: 83, fill: "#FFD24A", track: "#303030"))
    #expect(delivery.duration == 10)
    #expect(delivery.color == "#D97757")
    #expect(delivery.surface == .app("claude"))
    #expect(delivery.lifetime == 900)
    #expect(delivery.overlay == .rain)
    #expect(delivery.text == delivery.scene.text)
}

// A producer that names only its text gets a banner and nothing else — the
// defaults every output had before there was a scene.
@Test func aDeliveryThatNamesOnlyItsTextIsAPlainBanner() {
    let delivery = AwtrixDelivery(text: "plain")

    #expect(delivery.surface == .notification)
    #expect(delivery.icon == nil)
    #expect(delivery.progress == nil)
    #expect(delivery.jingle == nil)
    #expect(delivery.duration == nil)
    #expect(delivery.color == nil)
    #expect(delivery.lifetime == nil)
    #expect(delivery.overlay == nil)
    #expect(delivery.localAudio.isEmpty)
    #expect(delivery.holdUntilAudioEnds == false)
}
