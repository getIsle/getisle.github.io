//
//  Preferences.swift
//  Isle
//
//  UserDefaults-backed settings store. Deliberately a hand-rolled ObservableObject
//  rather than a pile of @AppStorage properties, because AppKit code (the window
//  controller, the monitors) needs to read these too — not just SwiftUI views.
//

import AppKit
import Combine
import ServiceManagement
import SwiftUI
import os

@MainActor
final class Preferences: ObservableObject {

    static let shared = Preferences()

    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: "com.isle.Isle", category: "Preferences")

    // MARK: Keys

    private enum Key {
        static let nowPlayingEnabled = "widget.nowPlaying.enabled"
        static let batteryEnabled = "widget.battery.enabled"
        static let bluetoothEnabled = "widget.bluetooth.enabled"
        static let focusEnabled = "widget.focus.enabled"
        static let calendarEnabled = "widget.calendar.enabled"
        static let calendarAlertMinutes = "calendar.alertMinutes"
        static let panelLayout = "appearance.panelLayout"
        static let notificationsEnabled = "widget.notifications.enabled"
        static let accentHex = "appearance.accentHex"
        static let islandStyle = "appearance.islandStyle"
        static let adoptedFlaredDefault = "appearance.adoptedFlaredDefault"
        static let detachFromTopEdge = "appearance.detachFromTopEdge"
        static let hudDuration = "behaviour.hudDuration"
        static let notificationDuration = "behaviour.notificationDuration"
        static let expandOnHover = "behaviour.expandOnHover"
        static let hoverDelay = "behaviour.hoverDelay"
        static let showOnAllDisplays = "behaviour.virtualNotchOnExternal"
        static let hideInFullScreen = "behaviour.hideInFullScreen"
        static let didAutoEnableLaunchAtLogin = "general.didAutoEnableLaunchAtLogin"
        static let onboardingCompleted = "onboarding.completed"
        static let onboardingResumeStep = "onboarding.resumeStep"
        static let mediaRemoteEnabled = "media.useMediaRemote"
        static let appleScriptFallback = "media.useAppleScriptFallback"
    }

    // MARK: Widgets

    @Published var nowPlayingEnabled: Bool { didSet { defaults.set(nowPlayingEnabled, forKey: Key.nowPlayingEnabled) } }
    @Published var batteryEnabled: Bool { didSet { defaults.set(batteryEnabled, forKey: Key.batteryEnabled) } }
    @Published var bluetoothEnabled: Bool { didSet { defaults.set(bluetoothEnabled, forKey: Key.bluetoothEnabled) } }
    @Published var focusEnabled: Bool { didSet { defaults.set(focusEnabled, forKey: Key.focusEnabled) } }
    @Published var calendarEnabled: Bool { didSet { defaults.set(calendarEnabled, forKey: Key.calendarEnabled) } }
    /// How long before an event starts the island peeks with a reminder. 0 = only at start.
    /// Open island: music and agenda side by side, or the player on its own.
    @Published var panelLayout: PanelLayout { didSet { defaults.set(panelLayout.rawValue, forKey: Key.panelLayout) } }
    @Published var calendarAlertMinutes: Int { didSet { defaults.set(calendarAlertMinutes, forKey: Key.calendarAlertMinutes) } }
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) } }

    // MARK: Appearance & behaviour

    @Published var accentHex: String { didSet { defaults.set(accentHex, forKey: Key.accentHex) } }
    @Published var islandStyle: IslandStyle { didSet { defaults.set(islandStyle.rawValue, forKey: Key.islandStyle) } }

    /// Float the capsule clear of the top edge instead of sitting flush against it.
    ///
    /// Looks best on a display with no notch. On notched hardware the camera housing
    /// is a physical black cutout running to the very top of the panel, so a gap
    /// leaves that housing visible as a black tab above the capsule — hence the
    /// default below is "only when there is no notch to worry about".
    @Published var detachFromTopEdge: Bool { didSet { defaults.set(detachFromTopEdge, forKey: Key.detachFromTopEdge) } }
    @Published var hudDuration: Double { didSet { defaults.set(hudDuration, forKey: Key.hudDuration) } }
    @Published var notificationDuration: Double { didSet { defaults.set(notificationDuration, forKey: Key.notificationDuration) } }
    @Published var expandOnHover: Bool { didSet { defaults.set(expandOnHover, forKey: Key.expandOnHover) } }
    @Published var hoverDelay: Double { didSet { defaults.set(hoverDelay, forKey: Key.hoverDelay) } }
    /// Get out of the way of full-screen apps, video and Split View.
    @Published var hideInFullScreen: Bool { didSet { defaults.set(hideInFullScreen, forKey: Key.hideInFullScreen) } }
    @Published var showVirtualNotchOnExternalDisplays: Bool {
        didSet { defaults.set(showVirtualNotchOnExternalDisplays, forKey: Key.showOnAllDisplays) }
    }

    // MARK: Media source strategy

    @Published var useMediaRemote: Bool { didSet { defaults.set(useMediaRemote, forKey: Key.mediaRemoteEnabled) } }
    @Published var useAppleScriptFallback: Bool { didSet { defaults.set(useAppleScriptFallback, forKey: Key.appleScriptFallback) } }

    // MARK: Launch at login

    /// Not persisted by us — `SMAppService` is the source of truth, we just mirror it.
    @Published var launchAtLogin: Bool = false

    var accentColor: Color { Color(hex: accentHex) ?? Color(red: 0.22, green: 0.54, blue: 0.85) }

    private init() {
        defaults.register(defaults: [
            Key.nowPlayingEnabled: true,
            Key.batteryEnabled: true,
            Key.bluetoothEnabled: true,
            Key.focusEnabled: true,
            Key.calendarEnabled: true,
            Key.calendarAlertMinutes: 5,
            Key.panelLayout: PanelLayout.sideBySide.rawValue,
            Key.notificationsEnabled: true,
            Key.accentHex: "#388AD9",
            Key.islandStyle: IslandStyle.notchMerged.rawValue,
            Key.detachFromTopEdge: false,
            Key.hudDuration: 2.4,
            Key.notificationDuration: 4.0,
            Key.expandOnHover: false,
            Key.hoverDelay: 0.18,
            Key.showOnAllDisplays: true,
            Key.hideInFullScreen: true,
            Key.mediaRemoteEnabled: true,
            Key.appleScriptFallback: true,
        ])

        nowPlayingEnabled = defaults.bool(forKey: Key.nowPlayingEnabled)
        batteryEnabled = defaults.bool(forKey: Key.batteryEnabled)
        bluetoothEnabled = defaults.bool(forKey: Key.bluetoothEnabled)
        focusEnabled = defaults.bool(forKey: Key.focusEnabled)
        calendarEnabled = defaults.bool(forKey: Key.calendarEnabled)
        calendarAlertMinutes = defaults.integer(forKey: Key.calendarAlertMinutes)
        panelLayout = PanelLayout(rawValue: defaults.string(forKey: Key.panelLayout) ?? "") ?? .sideBySide
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        accentHex = defaults.string(forKey: Key.accentHex) ?? "#388AD9"
        // One-time move to the flared shape, which is what Alcove (and the real
        // hardware) looks like. After this the user's own choice always wins.
        if !defaults.bool(forKey: Key.adoptedFlaredDefault) {
            defaults.set(IslandStyle.notchMerged.rawValue, forKey: Key.islandStyle)
            defaults.set(true, forKey: Key.adoptedFlaredDefault)
        }
        islandStyle = IslandStyle(rawValue: defaults.string(forKey: Key.islandStyle) ?? "")
            ?? .notchMerged
        detachFromTopEdge = defaults.bool(forKey: Key.detachFromTopEdge)
        hudDuration = defaults.double(forKey: Key.hudDuration)
        notificationDuration = defaults.double(forKey: Key.notificationDuration)
        expandOnHover = defaults.bool(forKey: Key.expandOnHover)
        hoverDelay = defaults.double(forKey: Key.hoverDelay)
        showVirtualNotchOnExternalDisplays = defaults.bool(forKey: Key.showOnAllDisplays)
        hideInFullScreen = defaults.bool(forKey: Key.hideInFullScreen)
        useMediaRemote = defaults.bool(forKey: Key.mediaRemoteEnabled)
        useAppleScriptFallback = defaults.bool(forKey: Key.appleScriptFallback)

        launchAtLogin = Self.isLaunchAtLoginActive
    }

    // MARK: - Onboarding

    /// Not @Published: only AppDelegate and the onboarding flow read these.
    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Key.onboardingCompleted) }
        set { defaults.set(newValue, forKey: Key.onboardingCompleted) }
    }

    /// Step to reopen on — survives the relaunch "Move to Applications" does.
    var onboardingResumeStep: Int {
        get { defaults.integer(forKey: Key.onboardingResumeStep) }
        set { defaults.set(newValue, forKey: Key.onboardingResumeStep) }
    }

    // MARK: - Login item

    /// Turn launch-at-login on by itself the first time Isle runs from
    /// /Applications. Only once: if the user later switches it off in Settings,
    /// that choice sticks.
    ///
    /// Skipped for builds run straight out of Xcode's DerivedData — registering
    /// that path would point the login item at a build folder that Xcode keeps
    /// replacing and cleaning.
    func enableLaunchAtLoginOnFirstInstall() {
        guard !defaults.bool(forKey: Key.didAutoEnableLaunchAtLogin) else { return }
        let path = Bundle.main.bundleURL.path
        let isInstalled = path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard isInstalled else {
            log.notice("Not auto-enabling launch at login: running from \(path, privacy: .public), not /Applications")
            return
        }

        setLaunchAtLogin(true)
        // Only remember "done" if it actually worked, so a refusal is retried on
        // the next launch instead of silently giving up forever.
        if launchAtLogin {
            defaults.set(true, forKey: Key.didAutoEnableLaunchAtLogin)
        }
    }

    /// `SMAppService` replaced the old `SMLoginItemSetEnabled` helper-bundle dance in
    /// macOS 13. Registering can throw if the app lives somewhere macOS refuses to
    /// launch from (e.g. still inside a Downloads quarantine), so we surface failure
    /// by reverting the toggle rather than lying to the user.
    /// Two mechanisms, best first:
    ///  1. `SMAppService.mainApp` — the modern API, shows up in Login Items.
    ///     macOS often refuses it for ad-hoc-signed builds (no developer ID), and
    ///     it can sit in "requires approval".
    ///  2. A LaunchAgent in ~/Library/LaunchAgents that runs `open <Isle.app>` at
    ///     login. Works for any build, signed or not; launchd reads the folder at
    ///     every login, so nothing has to be loaded now.
    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp

        if enabled {
            var registered = false
            do {
                if service.status != .enabled { try service.register() }
                registered = (service.status == .enabled)
            } catch {
                log.error("SMAppService register failed: \(error.localizedDescription, privacy: .public) — using a LaunchAgent instead")
            }

            if registered {
                removeLaunchAgent()        // don't launch twice
            } else if !installLaunchAgent() {
                log.error("Could not install the launch-at-login LaunchAgent either")
            }
        } else {
            if service.status == .enabled || service.status == .requiresApproval {
                try? service.unregister()
            }
            removeLaunchAgent()
        }

        launchAtLogin = Self.isLaunchAtLoginActive
    }

    static var isLaunchAtLoginActive: Bool {
        SMAppService.mainApp.status == .enabled
            || FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    private static let launchAgentLabel = "com.isle.Isle.autostart"

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(launchAgentLabel + ".plist")
    }

    private func installLaunchAgent() -> Bool {
        let url = Self.launchAgentURL
        let plist: [String: Any] = [
            "Label": Self.launchAgentLabel,
            // `open` (not the raw executable) so it launches like a normal app,
            // and points at wherever this copy of Isle actually lives.
            "ProgramArguments": ["/usr/bin/open", Bundle.main.bundleURL.path],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: url, options: .atomic)
            log.info("Installed launch-at-login agent at \(url.path, privacy: .public)")
            return true
        } catch {
            log.error("LaunchAgent write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func removeLaunchAgent() {
        try? FileManager.default.removeItem(at: Self.launchAgentURL)
    }
}

// MARK: - Panel layout

enum PanelLayout: String, CaseIterable, Identifiable {
    /// Compact player on the left, today's agenda on the right.
    case sideBySide
    /// The player alone, full width. (Calendar reminders still peek.)
    case single

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sideBySide: return "Side by side"
        case .single: return "Single"
        }
    }
}

// MARK: - Color <-> hex

extension Color {
    init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }

    var hexString: String {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = Int((nsColor.redComponent * 255).rounded())
        let g = Int((nsColor.greenComponent * 255).rounded())
        let b = Int((nsColor.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
