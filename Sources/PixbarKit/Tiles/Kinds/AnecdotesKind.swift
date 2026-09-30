// Sources/PixbarKit/Tiles/Kinds/AnecdotesKind.swift
import Foundation

/// The day's anecdotes, spoken through the Mac — AWTRIX only, and the one
/// kind that makes a sound.
public enum AnecdotesKind: TileKind {
    public typealias Parameters = NoParameters
    public static let id = "anecdotes"
    public static let presentation = TilePresentation(
        category: .system, icon: "text.bubble", blurb: "The day's anecdotes, spoken"
    )
    public static let models: Set<ClockModel> = [.awtrix3]
    public static let isAudible = true
}
