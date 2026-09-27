//
//  IslandTypography.swift
//  Isle
//
//  One type scale for the whole island, modelled on the system Now Playing / Live
//  Activity styles that Alcove copies. Every text style in the widgets comes from
//  here, so sizes and weights can't drift apart file by file.
//
//  Rules of thumb that make it read as native rather than "web":
//  • Plain SF Pro (the default design) — never .rounded for body text.
//  • Hierarchy comes from weight + opacity, not from many different sizes: white for
//    the primary line, ~55% white for secondary, ~45% for tertiary/numbers.
//  • Anything that ticks (times, percentages) uses monospaced digits so it doesn't
//    jitter sideways every second.
//

import SwiftUI

extension Font {
    /// Track title in the player. "Tum Se" in the reference.
    static let islandTitle = Font.system(size: 15, weight: .semibold)
    /// Artist — album line under the title.
    static let islandSubtitle = Font.system(size: 13, weight: .regular)
    /// Elapsed / remaining time either side of the scrubber.
    static let islandTime = Font.system(size: 12, weight: .medium).monospacedDigit()

    /// Primary line in a notification card or empty state.
    static let islandHeadline = Font.system(size: 13, weight: .semibold)
    /// Body text in a notification card or empty state.
    static let islandBody = Font.system(size: 12, weight: .regular)

    /// Small status text in chips (battery %, Focus name).
    static let islandChip = Font.system(size: 11, weight: .semibold).monospacedDigit()
    /// The smallest text we ever draw — app names, secondary chip text.
    static let islandMicro = Font.system(size: 10, weight: .medium).monospacedDigit()

    /// HUD text in the peeked capsule beside the housing.
    static let islandHUDTitle = Font.system(size: 12, weight: .semibold)
    static let islandHUDSubtitle = Font.system(size: 10, weight: .medium).monospacedDigit()
}

/// Opacity ladder for white-on-black text. Use these instead of ad-hoc numbers.
enum IslandInk {
    static let primary: Double = 1.0
    static let secondary: Double = 0.55
    static let tertiary: Double = 0.45
    static let quaternary: Double = 0.3
}
