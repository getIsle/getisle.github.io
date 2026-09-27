//
//  DemoContent.swift
//  Isle
//
//  Sample data for `isle://demo`. Exists so the island's media states can be
//  exercised (and screenshotted) on a machine where nothing is playing, and so a
//  first-run user can see what the app does before wiring up permissions.
//

import AppKit
import SwiftUI

enum DemoContent {

    static func sampleTrack() -> NowPlayingInfo {
        NowPlayingInfo(
            title: "Midnight City",
            artist: "M83",
            album: "Hurry Up, We're Dreaming",
            isPlaying: true,
            duration: 243,
            elapsed: 78,
            playbackRate: 1,
            timestamp: Date(),
            artwork: gradientArtwork(),
            sourceBundleIdentifier: nil,
            sourceName: "Demo"
        )
    }

    static func sampleDevice() -> BluetoothDeviceInfo {
        BluetoothDeviceInfo(
            id: "00:00:00:00:00:00",
            name: "AirPods Pro",
            isConnected: true,
            isAudioDevice: true,
            batteryCombined: 84,
            batteryLeft: 86,
            batteryRight: 82,
            batteryCase: 61
        )
    }

    static func sampleBattery() -> BatterySnapshot {
        BatterySnapshot(
            percentage: 68,
            isCharging: true,
            isCharged: false,
            powerSource: .acPower,
            timeRemaining: 52 * 60,
            isLowPower: false
        )
    }

    /// A stand-in cover: a diagonal gradient, so the artwork-derived glow has
    /// something real to sample.
    static func gradientArtwork(size: CGFloat = 256) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        let gradient = NSGradient(
            colors: [
                NSColor(srgbRed: 0.42, green: 0.22, blue: 0.85, alpha: 1),
                NSColor(srgbRed: 0.93, green: 0.33, blue: 0.48, alpha: 1),
                NSColor(srgbRed: 0.99, green: 0.69, blue: 0.29, alpha: 1),
            ]
        )
        gradient?.draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            angle: 135
        )
        return image
    }
}
