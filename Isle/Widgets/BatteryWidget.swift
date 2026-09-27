//
//  BatteryWidget.swift
//  Isle
//
//  Battery chip for the expanded header, plus the HUD event factory used when the
//  charging state flips.
//

import SwiftUI

struct BatteryChip: View {
    let battery: BatterySnapshot
    var compact: Bool = true
    /// Drop the "84%" text when the chip has to fit beside the camera housing and
    /// there is not enough gutter left for it.
    var showsPercentage: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: battery.symbolName)
                .font(.system(size: compact ? 10 : 13, weight: .semibold))
                .foregroundStyle(battery.tint)
                .contentTransition(.symbolEffect(.replace))

            if showsPercentage {
                Text("\(battery.percentage)%")
                    .font(compact ? .islandChip : .islandHeadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }

            if !compact, let remaining = battery.timeRemaining, remaining > 0 {
                Text(Self.remainingString(remaining))
                    .font(.islandMicro)
                    .foregroundStyle(.white.opacity(IslandInk.tertiary))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .help(helpText)
    }

    private var helpText: String {
        if battery.isCharged { return "Fully charged" }
        if battery.isCharging { return "Charging" }
        if battery.powerSource == .acPower { return "On power adapter" }
        return "On battery"
    }

    static func remainingString(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        let hours = minutes / 60
        let rest = minutes % 60
        return hours > 0 ? "\(hours)h \(rest)m" : "\(rest)m"
    }
}

extension HUDEvent {

    /// Built when the charging state changes, the machine crosses a low-battery
    /// threshold, or it finishes charging.
    static func battery(_ snapshot: BatterySnapshot, reason: BatteryHUDReason) -> HUDEvent {
        let title: String
        switch reason {
        case .pluggedIn: title = "Charging"
        case .unplugged: title = "On Battery"
        case .charged: title = "Charged"
        case .low: title = "Low Battery"
        }

        return HUDEvent(
            kind: .battery,
            symbolName: snapshot.symbolName,
            title: title,
            subtitle: "\(snapshot.percentage)%",
            progress: Double(snapshot.percentage) / 100.0,
            tint: snapshot.tint,
            image: nil,
            layout: .side
        )
    }
}

enum BatteryHUDReason {
    case pluggedIn
    case unplugged
    case charged
    case low
}
