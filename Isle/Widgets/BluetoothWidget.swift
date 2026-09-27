//
//  BluetoothWidget.swift
//  Isle
//
//  Chip + HUD for Bluetooth audio devices (AirPods and friends).
//

import SwiftUI

struct BluetoothChip: View {
    let device: BluetoothDeviceInfo

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: device.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))

            if let level = device.batteryCombined ?? device.batteryLeft {
                Text("\(level)%")
                    .font(.islandChip)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .help(device.name)
    }
}

/// The wide layout used inside the expanded island when a device is connected and
/// reporting per-bud levels.
struct BluetoothDeviceRow: View {
    let device: BluetoothDeviceInfo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbolName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.islandHeadline)
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.9))

                if let summary = batterySummary {
                    Text(summary)
                        .font(.islandMicro)
                        .foregroundStyle(.white.opacity(IslandInk.secondary))
                } else {
                    Text("Connected")
                        .font(.islandMicro)
                        .foregroundStyle(.white.opacity(IslandInk.tertiary))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var batterySummary: String? {
        var parts: [String] = []
        if let left = device.batteryLeft { parts.append("L \(left)%") }
        if let right = device.batteryRight { parts.append("R \(right)%") }
        if let box = device.batteryCase { parts.append("Case \(box)%") }
        if parts.isEmpty, let combined = device.batteryCombined { parts.append("\(combined)%") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}

extension HUDEvent {
    static func bluetooth(_ device: BluetoothDeviceInfo, connected: Bool) -> HUDEvent {
        let level = device.batteryCombined
            ?? [device.batteryLeft, device.batteryRight].compactMap { $0 }.min()

        return HUDEvent(
            kind: .bluetooth,
            symbolName: connected ? device.symbolName : "bolt.horizontal.circle",
            title: device.name,
            subtitle: connected ? (level.map { "\($0)%" } ?? "Connected") : "Disconnected",
            progress: connected ? level.map { Double($0) / 100.0 } : nil,
            tint: connected ? .white : .white.opacity(0.6),
            image: nil
        )
    }

    static func focus(_ status: FocusStatus) -> HUDEvent {
        HUDEvent(
            kind: .focus,
            symbolName: status.isActive ? status.symbolName : "moon.slash",
            title: status.isActive ? status.name : "Focus Off",
            subtitle: status.isActive ? "Focus On" : nil,
            progress: nil,
            tint: .purple,
            image: nil
        )
    }

    static func nowPlaying(_ media: NowPlayingInfo) -> HUDEvent {
        HUDEvent(
            kind: .nowPlaying,
            symbolName: "music.note",
            title: media.title,
            subtitle: media.artist.isEmpty ? media.album : media.artist,
            progress: nil,
            tint: .white,
            image: media.artwork
        )
    }
}
