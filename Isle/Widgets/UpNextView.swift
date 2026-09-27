//
//  UpNextView.swift
//  Isle
//
//  The calendar strip at the bottom of the expanded island:
//
//      ─────────────────────────────────────────────
//      ▌ Design review                       [ Join ]
//      ▌ 10:30 – 11:00 · in 12 min
//
//  A coloured bar in the calendar's colour, the title, when it is, and a Join
//  button whenever the event carries a Zoom / Meet / Teams / … link. Tapping the
//  row opens the event in Calendar.
//

import AppKit
import SwiftUI

struct UpNextView: View {

    @ObservedObject var viewModel: NotchViewModel

    /// Height of the row itself.
    static let rowHeight: CGFloat = 36
    /// What the panel grows by to make room: row + divider + spacing.
    static let reservedHeight: CGFloat = 50

    @State private var isHovering = false

    var body: some View {
        // The relative time ("in 12 min") has to count down on its own, even while
        // the playhead ticker is stopped.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .frame(height: Self.rowHeight)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch viewModel.calendarAccess {
        case .unknown:
            placeholder(symbol: "calendar", text: "Loading calendar…")

        case .denied:
            Button(action: Self.openCalendarPrivacySettings) {
                placeholder(
                    symbol: "calendar.badge.exclamationmark",
                    text: "Allow Isle to see your calendar",
                    trailing: "Open Settings"
                )
            }
            .buttonStyle(.plain)

        case .granted:
            if let event = viewModel.upcomingEvents.first(where: { $0.end > now }) {
                eventRow(event, now: now)
            } else {
                placeholder(symbol: "calendar", text: "No upcoming events")
            }
        }
    }

    // MARK: Event row

    private func eventRow(_ event: CalendarEvent, now: Date) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(event.calendarColor)
                .frame(width: 3, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.islandHeadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(Self.detail(for: event, now: now))
                    .font(.islandMicro)
                    .foregroundStyle(.white.opacity(IslandInk.secondary))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let url = event.joinURL {
                joinButton(url: url, isImminent: event.start.timeIntervalSince(now) < 10 * 60)
            } else if let badge = Self.shortRelative(for: event, now: now) {
                Text(badge)
                    .font(.islandChip)
                    .foregroundStyle(.white.opacity(IslandInk.tertiary))
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(NotchRootView.contentSpring) { isHovering = inside }
        }
        .onTapGesture { Self.open(event) }
        .help(event.calendarTitle)
    }

    private func joinButton(url: URL, isImminent: Bool) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "video.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Join")
                    .font(.islandChip)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    // Green once the meeting is close, like the system's call buttons.
                    .fill(isImminent ? Color(red: 0.19, green: 0.78, blue: 0.35) : Color.white.opacity(0.14))
            )
        }
        .buttonStyle(PressableButtonStyle())
        .help(url.host ?? "Join")
    }

    private func placeholder(symbol: String, text: String, trailing: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
            Text(text)
                .font(.islandBody)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.islandChip)
                    .foregroundStyle(.white.opacity(IslandInk.secondary))
            }
        }
        .foregroundStyle(.white.opacity(IslandInk.tertiary))
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: Formatting

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// "10:30 – 11:00 · in 12 min", "Now · until 11:00", "Tomorrow · 09:00 – 09:30".
    static func detail(for event: CalendarEvent, now: Date) -> String {
        let start = timeFormatter.string(from: event.start)
        let end = timeFormatter.string(from: event.end)

        if event.isOngoing(at: now) {
            return "Now · until \(end)"
        }
        if !Calendar.current.isDate(event.start, inSameDayAs: now) {
            return "Tomorrow · \(start) – \(end)"
        }
        if let relative = shortRelative(for: event, now: now) {
            return "\(start) – \(end) · \(relative)"
        }
        return "\(start) – \(end)"
    }

    /// "in 12 min" / "in 1 h 20 min" for today's events; nil otherwise.
    static func shortRelative(for event: CalendarEvent, now: Date) -> String? {
        let seconds = event.start.timeIntervalSince(now)
        guard seconds > 0, Calendar.current.isDate(event.start, inSameDayAs: now) else {
            return nil
        }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "in \(hours) h" : "in \(hours) h \(rest) min"
    }

    // MARK: Actions

    static func open(_ event: CalendarEvent) {
        if let identifier = event.eventIdentifier,
           let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more"),
           NSWorkspace.shared.open(url) {
            return
        }
        if let calendarApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: calendarApp, configuration: .init())
        }
    }

    static func openCalendarPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        if let url { NSWorkspace.shared.open(url) }
    }
}

// MARK: - HUD

extension HUDEvent {
    /// The peek shown before and at the start of an event.
    static func calendar(_ event: CalendarEvent, startsIn seconds: TimeInterval) -> HUDEvent {
        let subtitle: String
        if seconds <= 0 {
            subtitle = "Now"
        } else {
            subtitle = "in \(Int((seconds / 60).rounded(.up))) min"
        }
        return HUDEvent(
            kind: .calendar,
            symbolName: event.joinURL != nil ? "video.fill" : "calendar",
            title: event.title,
            subtitle: subtitle,
            progress: nil,
            tint: event.calendarColor,
            image: nil
        )
    }
}
