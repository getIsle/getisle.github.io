//
//  SettingsView.swift
//  Isle
//
//  Isle's settings window: a System Settings–style sidebar with one pane per
//  area. Every control writes straight to `Preferences`, which the island, the
//  services and the window controller all observe — so changes apply live.
//

import AppKit
import EventKit
import ServiceManagement
import SwiftUI

extension Notification.Name {
    /// Posted by the About pane; AppDelegate reopens the onboarding flow.
    static let isleShowWelcomeGuide = Notification.Name("com.isle.Isle.showWelcomeGuide")
}

struct SettingsView: View {

    enum Pane: String, CaseIterable, Identifiable {
        case general, island, widgets, nowPlaying, calendar, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .island: return "Appearance"
            case .widgets: return "Widgets"
            case .nowPlaying: return "Now Playing"
            case .calendar: return "Calendar"
            case .about: return "About Isle"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .island: return "paintbrush.fill"
            case .widgets: return "square.grid.2x2.fill"
            case .nowPlaying: return "music.note"
            case .calendar: return "calendar"
            case .about: return "info"
            }
        }

        var tint: Color {
            switch self {
            case .general: return .gray
            case .island: return .indigo
            case .widgets: return .blue
            case .nowPlaying: return .pink
            case .calendar: return .red
            case .about: return .teal
            }
        }
    }

    @EnvironmentObject private var preferences: Preferences
    @State private var selection: Pane? = .general

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $selection) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    SettingsIcon(symbol: pane.symbol, tint: pane.tint)
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            Group {
                switch selection ?? .general {
                case .general: GeneralPane()
                case .island: AppearancePane()
                case .widgets: WidgetsPane()
                case .nowPlaying: NowPlayingPane()
                case .calendar: CalendarPane()
                case .about: AboutPane()
                }
            }
            .navigationTitle((selection ?? .general).title)
        }
        .frame(minWidth: 720, minHeight: 520)
        .environmentObject(preferences)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Open Isle at login",
                    isOn: Binding(
                        get: { preferences.launchAtLogin },
                        set: { preferences.setLaunchAtLogin($0) }
                    )
                )
                if SMAppService.mainApp.status == .requiresApproval {
                    Label(
                        "Approve Isle in System Settings ▸ General ▸ Login Items.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("Opening the island") {
                Picker("Open with", selection: $preferences.expandOnHover) {
                    Text("Click").tag(false)
                    Text("Hover").tag(true)
                }
                .pickerStyle(.segmented)

                if preferences.expandOnHover {
                    LabeledContent("Hover delay") {
                        HStack {
                            Slider(value: $preferences.hoverDelay, in: 0...0.6, step: 0.02)
                                .frame(width: 180)
                            Text(String(format: "%.2f s", preferences.hoverDelay))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                } else {
                    Text("Hovering lifts the island a little; clicking opens it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Hide in full-screen apps and videos", isOn: $preferences.hideInFullScreen)
            }

            Section("Displays") {
                Toggle(
                    "Show a virtual notch on displays without one",
                    isOn: $preferences.showVirtualNotchOnExternalDisplays
                )
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        Form {
            Section("Shape") {
                Picker("Island style", selection: $preferences.islandStyle) {
                    ForEach(IslandStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(preferences.islandStyle.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if preferences.islandStyle == .floating {
                    Toggle("Detach from the top edge", isOn: $preferences.detachFromTopEdge)
                    Text("Best on displays without a notch — on a notched Mac a gap leaves the camera housing visible above the island.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Accent colour") {
                ColorPicker(
                    "Colour",
                    selection: Binding(
                        get: { preferences.accentColor },
                        set: { preferences.accentHex = $0.hexString }
                    ),
                    supportsOpacity: false
                )

                HStack(spacing: 10) {
                    ForEach(Self.presets, id: \.self) { hex in
                        Button {
                            preferences.accentHex = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex) ?? .blue)
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle().stroke(
                                        Color.primary.opacity(isSelected(hex) ? 0.85 : 0.12),
                                        lineWidth: isSelected(hex) ? 2.5 : 1
                                    )
                                    .padding(-3)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)

                Text("Used when a song has no artwork, and for the island's glow. Album art tints the music bars automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Timing") {
                LabeledContent("Alerts stay for") {
                    SliderWithValue(value: $preferences.hudDuration, range: 0.8...8, step: 0.1)
                }
                LabeledContent("Notification cards stay for") {
                    SliderWithValue(value: $preferences.notificationDuration, range: 1.5...15, step: 0.5)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func isSelected(_ hex: String) -> Bool {
        preferences.accentHex.caseInsensitiveCompare(hex) == .orderedSame
    }

    private static let presets = [
        "#388AD9", "#8E5CF7", "#E0557B", "#F2A33C", "#33B86B", "#E5E5EA",
    ]
}

// MARK: - Widgets

private struct WidgetsPane: View {
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        Form {
            Section {
                WidgetToggle(symbol: "music.note", tint: .pink, title: "Now Playing",
                             detail: "Album art and music bars beside the camera; the full player when opened.",
                             isOn: $preferences.nowPlayingEnabled)
                WidgetToggle(symbol: "calendar", tint: .red, title: "Calendar",
                             detail: "Up Next under the player, and a reminder before each event.",
                             isOn: $preferences.calendarEnabled)
                WidgetToggle(symbol: "battery.75percent", tint: .green, title: "Battery",
                             detail: "Alerts when you plug in, unplug, finish charging or run low.",
                             isOn: $preferences.batteryEnabled)
                WidgetToggle(symbol: "airpods", tint: .blue, title: "Bluetooth devices",
                             detail: "AirPods and headphones connecting, with their battery.",
                             isOn: $preferences.bluetoothEnabled)
                WidgetToggle(symbol: "moon.fill", tint: .indigo, title: "Focus",
                             detail: "Shows when a Focus mode turns on or off.",
                             isOn: $preferences.focusEnabled)
                WidgetToggle(symbol: "bell.badge.fill", tint: .orange, title: "Notification cards",
                             detail: "Alerts that apps and Shortcuts send to Isle.",
                             isOn: $preferences.notificationsEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

private struct WidgetToggle: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                SettingsIcon(symbol: symbol, tint: tint, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
    }
}

// MARK: - Now Playing

private struct NowPlayingPane: View {
    @ObservedObject private var diagnostics = MediaDiagnostics.shared
    @State private var toolsInstalled: Bool?

    var body: some View {
        Form {
            Section {
                if diagnostics.issues.isEmpty {
                    Label(
                        diagnostics.hasData ? "Isle can see what's playing." : "Play something and it will appear in the notch.",
                        systemImage: diagnostics.hasData ? "checkmark.circle.fill" : "music.note"
                    )
                    .foregroundStyle(diagnostics.hasData ? .green : .secondary)
                } else {
                    ForEach(Array(diagnostics.issues.filter(\.isBlocking).enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            if let fix = issue.fix {
                                Text(fix).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Button("Open Automation Settings") { MediaDiagnostics.openAutomationSettings() }
                }
            }

            if toolsInstalled == false {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("See music from every app")
                            Text("Needs Apple's free Command Line Tools. Without them, Isle works with Music, Spotify, Safari and Chrome.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Install…") {
                            let process = Process()
                            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
                            process.arguments = ["--install"]
                            try? process.run()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            toolsInstalled = MediaRemoteHelperSource.locateSwift() != nil
        }
    }
}

// MARK: - Calendar

private struct CalendarPane: View {
    @EnvironmentObject private var preferences: Preferences
    @State private var status = EKEventStore.authorizationStatus(for: .event)

    var body: some View {
        Form {
            Section {
                if !preferences.calendarEnabled {
                    Text("Calendar is turned off in Widgets.")
                        .foregroundStyle(.secondary)
                }

                Picker("When music is on", selection: $preferences.panelLayout) {
                    ForEach(PanelLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!preferences.calendarEnabled || !preferences.nowPlayingEnabled)

                Text(preferences.panelLayout == .sideBySide
                     ? "The island splits in two around the camera: music on the left, today's agenda on the right."
                     : "The island shows just the player. Calendar reminders still pop up before each event.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Access") {
                    switch status {
                    case .fullAccess:
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .notDetermined:
                        Button("Allow Access…") {
                            Task {
                                _ = try? await EKEventStore().requestFullAccessToEvents()
                                status = EKEventStore.authorizationStatus(for: .event)
                            }
                        }
                    default:
                        Button("Open Privacy Settings") {
                            IsleURL.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
                        }
                    }
                }
            }

            Section("Reminders") {
                Picker("Remind me", selection: $preferences.calendarAlertMinutes) {
                    Text("When the event starts").tag(0)
                    Text("1 minute before").tag(1)
                    Text("5 minutes before").tag(5)
                    Text("10 minutes before").tag(10)
                    Text("15 minutes before").tag(15)
                }
                Text("All-day, cancelled and declined events are skipped. Events with a Zoom, Meet, Teams or Webex link get a Join button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!preferences.calendarEnabled)
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = EKEventStore.authorizationStatus(for: .event)
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            Text("Isle").font(.system(size: 28, weight: .bold))
            Text(version).foregroundStyle(.secondary)
            Text("A Dynamic Island for your Mac's notch.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Welcome Guide…") {
                    NotificationCenter.default.post(name: .isleShowWelcomeGuide, object: nil)
                }
                Button("Quit Isle") { NSApp.terminate(nil) }
            }
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

// MARK: - Shared pieces

/// Coloured rounded-square icon, like System Settings' sidebar.
private struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(tint.gradient)
            )
    }
}

private struct SliderWithValue: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        HStack {
            Slider(value: $value, in: range, step: step).frame(width: 180)
            Text(String(format: "%.1f s", value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

/// Opens a system URL (e.g. a Privacy & Security pane).
enum IsleURL {
    static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
