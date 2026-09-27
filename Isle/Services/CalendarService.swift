//
//  CalendarService.swift
//  Isle
//
//  Reads upcoming events with EventKit (public API, one permission prompt) and:
//   • publishes today's and tomorrow's remaining events for the Up Next row, and
//   • peeks the island with a reminder N minutes before an event and again when it
//     starts, the way the iPhone surfaces a Live Activity.
//
//  Needs `NSCalendarsFullAccessUsageDescription` in Info.plist (macOS 14+ refuses
//  to prompt without it). If the user says no, the Up Next row explains how to fix
//  it instead of silently showing nothing.
//

import AppKit
import EventKit
import SwiftUI
import os

@MainActor
final class CalendarService {

    private let log = Logger(subsystem: "com.isle.Isle", category: "Calendar")

    private let viewModel: NotchViewModel
    private let preferences: Preferences
    private let store = EKEventStore()

    private var storeObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var timer: Timer?
    private var isRunning = false

    /// "eventID|soon" / "eventID|now" — each reminder fires once per event.
    private var announced = Set<String>()

    /// How far ahead the Up Next row looks.
    private let lookaheadDays = 2

    init(viewModel: NotchViewModel, preferences: Preferences) {
        self.viewModel = viewModel
        self.preferences = preferences
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await self.requestAccess()
            guard self.isRunning else { return }

            self.viewModel.calendarAccess = granted ? .granted : .denied
            guard granted else {
                self.log.notice("Calendar access not granted")
                return
            }
            self.beginObserving()
            self.reload()
        }
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        storeObserver = nil
        wakeObserver = nil
        viewModel.upcomingEvents = []
    }

    private func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            do {
                return try await store.requestFullAccessToEvents()
            } catch {
                log.error("Calendar access request failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        default:
            // .denied, .restricted, .writeOnly — none of them let us read events.
            return false
        }
    }

    private func beginObserving() {
        // Fires for edits made anywhere: Calendar.app, iCloud/Google sync, invites.
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }

        // Timers do not run during sleep; catch up straight away on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }

        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Loading

    func reload() {
        guard isRunning, viewModel.calendarAccess == .granted else { return }

        let now = Date()
        let calendar = Calendar.current
        let end = calendar.date(
            byAdding: .day,
            value: lookaheadDays,
            to: calendar.startOfDay(for: now)
        ) ?? now.addingTimeInterval(86_400)

        // Start the window in the past so events already in progress are included.
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-12 * 3600),
            end: end,
            calendars: nil
        )

        let events = store.events(matching: predicate)
            .filter { event in
                !event.isAllDay
                    && event.endDate > now
                    && event.status != .canceled
                    && !Self.isDeclined(event)
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(10)
            .map(Self.makeEvent)

        viewModel.upcomingEvents = Array(events)
        tick()
    }

    // MARK: Reminders

    private func tick() {
        guard isRunning else { return }
        let now = Date()

        // Drop finished events without waiting for the next reload.
        if viewModel.upcomingEvents.contains(where: { $0.end <= now }) {
            viewModel.upcomingEvents.removeAll { $0.end <= now }
        }

        if announced.count > 500 { announced.removeAll() }
        let lead = TimeInterval(preferences.calendarAlertMinutes * 60)

        for event in viewModel.upcomingEvents {
            let untilStart = event.start.timeIntervalSince(now)

            if lead > 0, untilStart > 0, untilStart <= lead,
               announced.insert(event.id + "|soon").inserted {
                viewModel.present(hud: .calendar(event, startsIn: untilStart), duration: 6)
                return
            }

            // "Starting now" — within the first 90 s, so a sleeping Mac that wakes
            // half an hour into a meeting doesn't announce it as new.
            if untilStart <= 0, untilStart > -90,
               announced.insert(event.id + "|now").inserted {
                viewModel.present(hud: .calendar(event, startsIn: 0), duration: 6)
                return
            }
        }
    }

    // MARK: Mapping

    private static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: { $0.isCurrentUser })?.participantStatus == .declined
    }

    private static func makeEvent(_ event: EKEvent) -> CalendarEvent {
        let color = event.calendar.map { Color(nsColor: $0.color) } ?? .blue
        return CalendarEvent(
            id: (event.eventIdentifier ?? UUID().uuidString)
                + "@\(event.startDate.timeIntervalSince1970)",   // recurring instances differ
            title: event.title?.isEmpty == false ? event.title! : "Untitled event",
            start: event.startDate,
            end: event.endDate,
            calendarColor: color,
            calendarTitle: event.calendar?.title ?? "",
            location: event.location,
            joinURL: joinURL(for: event),
            eventIdentifier: event.eventIdentifier
        )
    }

    private static let meetingHosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "facetime.apple.com", "whereby.com", "chime.aws",
    ]

    /// First video-call link in the event's URL, location or notes.
    private static func joinURL(for event: EKEvent) -> URL? {
        var candidates: [URL] = []
        if let url = event.url { candidates.append(url) }

        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        if !text.isEmpty,
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                if let url = match.url { candidates.append(url) }
            }
        }

        return candidates.first { url in
            guard let host = url.host?.lowercased() else { return false }
            return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }
}
