//
//  NotchModels.swift
//  Isle
//
//  Plain value types the services publish and the widgets render. Keeping these
//  free of any framework-specific detail means a widget never has to know whether
//  its data came from MediaRemote, AppleScript, IOKit or a unit test.
//

import AppKit
import SwiftUI

// MARK: - Now Playing

struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool

    /// Track length in seconds, when the source reports one.
    var duration: TimeInterval
    /// Playback position at the moment `timestamp` was captured.
    var elapsed: TimeInterval
    /// Playback rate (1.0 while playing, 0.0 while paused). Used to extrapolate
    /// `elapsed` between updates so the progress bar moves smoothly without us
    /// hammering the media source once a second.
    var playbackRate: Double
    var timestamp: Date

    var artwork: NSImage?
    var sourceBundleIdentifier: String?
    var sourceName: String?

    /// Where playback actually is *right now*, extrapolated from the last sample.
    var currentElapsed: TimeInterval {
        guard playbackRate != 0 else { return elapsed }
        let drift = Date().timeIntervalSince(timestamp) * playbackRate
        guard duration > 0 else { return max(0, elapsed + drift) }
        return min(duration, max(0, elapsed + drift))
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentElapsed / duration))
    }

    var isEmpty: Bool { title.isEmpty && artist.isEmpty }

    static func == (lhs: NowPlayingInfo, rhs: NowPlayingInfo) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.isPlaying == rhs.isPlaying
            && lhs.duration == rhs.duration
            && lhs.sourceBundleIdentifier == rhs.sourceBundleIdentifier
            && lhs.artwork === rhs.artwork
    }

    /// True when only the playhead moved — lets the view model refresh the progress
    /// bar without re-running the "new track" peek animation.
    func isSameTrack(as other: NowPlayingInfo?) -> Bool {
        guard let other else { return false }
        return title == other.title && artist == other.artist && album == other.album
    }
}

// MARK: - Battery

struct BatterySnapshot: Equatable {
    enum PowerSource: Equatable { case battery, acPower, unknown }

    var percentage: Int
    var isCharging: Bool
    var isCharged: Bool
    var powerSource: PowerSource
    var timeRemaining: TimeInterval?
    var isLowPower: Bool

    var symbolName: String {
        if isCharging || powerSource == .acPower { return "battery.100percent.bolt" }
        switch percentage {
        case ..<10: return "battery.0percent"
        case ..<35: return "battery.25percent"
        case ..<60: return "battery.50percent"
        case ..<85: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// Worth a chip in the island? The menu bar already shows the battery, so the
    /// island only mentions it when it matters: charging, low, or Low Power Mode.
    /// Plug/unplug/low/charged moments are announced separately as HUDs.
    ///
    /// Only *charging* earns a resting chip now. Low battery is announced as a
    /// notification card below the notch instead (see PowerMonitor.warnLow) — a
    /// red chip parked next to the camera read as part of the hardware, not as a
    /// warning.
    var isNoteworthy: Bool {
        isCharging && !isCharged
    }

    var tint: Color {
        if isCharging || isCharged { return .green }
        if percentage <= 10 { return .red }
        if percentage <= 20 { return .orange }
        return .white
    }
}

// MARK: - Bluetooth

struct BluetoothDeviceInfo: Equatable, Identifiable {
    var id: String            // device address
    var name: String
    var isConnected: Bool
    var isAudioDevice: Bool

    /// 0...100, when the device publishes battery levels into the IORegistry.
    var batteryCombined: Int?
    var batteryLeft: Int?
    var batteryRight: Int?
    var batteryCase: Int?

    /// Best-effort SF Symbol for the product family.
    var symbolName: String {
        let lowered = name.lowercased()
        if lowered.contains("airpods max") { return "airpods.max" }
        if lowered.contains("airpods pro") { return "airpods.pro" }
        if lowered.contains("airpods") { return "airpods" }
        if lowered.contains("beats") || lowered.contains("solo") || lowered.contains("studio") {
            return "beats.headphones"
        }
        if lowered.contains("magic keyboard") { return "keyboard" }
        if lowered.contains("magic mouse") { return "magicmouse" }
        if lowered.contains("magic trackpad") { return "trackpad" }
        if isAudioDevice { return "headphones" }
        return "dot.radiowaves.left.and.right"
    }
}

// MARK: - Focus

struct FocusStatus: Equatable {
    var isActive: Bool
    var modeIdentifier: String?
    var name: String

    static let off = FocusStatus(isActive: false, modeIdentifier: nil, name: "Off")

    /// Apple ships a fixed set of built-in mode identifiers; user-created Focus
    /// modes get a UUID, which we render with the generic moon badge.
    var symbolName: String {
        guard let identifier = modeIdentifier else { return "moon" }
        switch identifier {
        case let id where id.contains("do-not-disturb"): return "moon.fill"
        case let id where id.contains("sleep"): return "bed.double.fill"
        case let id where id.contains("work"): return "briefcase.fill"
        case let id where id.contains("personal"): return "person.fill"
        case let id where id.contains("driving"): return "car.fill"
        case let id where id.contains("fitness"): return "figure.run"
        case let id where id.contains("mindfulness"): return "brain.head.profile"
        case let id where id.contains("gaming"): return "gamecontroller.fill"
        case let id where id.contains("reading"): return "book.fill"
        default: return "moon.fill"
        }
    }
}

// MARK: - Calendar

/// One upcoming calendar event, flattened out of EventKit so widgets never import it.
struct CalendarEvent: Identifiable, Equatable {
    let id: String
    var title: String
    var start: Date
    var end: Date
    var calendarColor: Color
    var calendarTitle: String
    var location: String?
    /// Zoom / Meet / Teams / Webex / FaceTime link found in the URL, location or notes.
    var joinURL: URL?
    /// EventKit identifier, for opening the event in Calendar.
    var eventIdentifier: String?

    func isOngoing(at date: Date = Date()) -> Bool { start <= date && date < end }
}

enum CalendarAccess: Equatable {
    case unknown
    case granted
    case denied
}

// MARK: - HUD

/// A transient "something just happened" card shown in the peeked state — the
/// volume-HUD-style moments: charger plugged in, AirPods connected, Focus changed.
struct HUDEvent: Identifiable, Equatable {
    enum Kind: Equatable { case battery, bluetooth, focus, nowPlaying, calendar, generic }

    let id = UUID()
    var kind: Kind
    var symbolName: String
    var title: String
    var subtitle: String?
    /// When set, draws a thin meter under the title (battery %, volume, …).
    var progress: Double?
    var tint: Color
    /// Overrides the symbol with real artwork (album art, app icon).
    var image: NSImage?

    /// Where the text goes.
    ///  • caption — one line *below* the camera (track changes, calendar, AirPods).
    ///  • side    — glyph left of the camera, short value right of it, no caption.
    ///              For glanceable values like "15%", exactly like the iPhone's
    ///              low-battery and silent-mode alerts.
    enum Layout: Equatable { case caption, side }
    var layout: Layout = .caption

    var hasCaption: Bool { layout == .caption }

    static func == (lhs: HUDEvent, rhs: HUDEvent) -> Bool { lhs.id == rhs.id }
}

// MARK: - Notifications

struct NotchNotification: Identifiable, Equatable {
    let id: UUID
    var title: String
    var body: String
    var appName: String?
    var symbolName: String
    var image: NSImage?
    var accent: Color
    var date: Date

    init(
        id: UUID = UUID(),
        title: String,
        body: String,
        appName: String? = nil,
        symbolName: String = "bell.fill",
        image: NSImage? = nil,
        accent: Color = .white,
        date: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.appName = appName
        self.symbolName = symbolName
        self.image = image
        self.accent = accent
        self.date = date
    }

    static func == (lhs: NotchNotification, rhs: NotchNotification) -> Bool { lhs.id == rhs.id }
}

// MARK: - Media commands

/// Transport commands the expanded Now Playing widget can issue. The view never
/// knows which backend fulfils them (MediaRemote, AppleScript, or nothing at all).
enum MediaCommand: Equatable {
    case togglePlayPause
    case play
    case pause
    case nextTrack
    case previousTrack
}
