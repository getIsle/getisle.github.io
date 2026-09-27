//
//  ServiceCoordinator.swift
//  Isle
//
//  Starts and stops the background monitors and keeps their lifetimes tied to the
//  matching preference toggles, so a disabled widget costs zero CPU rather than
//  being merely hidden.
//

import AppKit
import Combine
import os

@MainActor
final class ServiceCoordinator {

    private let log = Logger(subsystem: "com.isle.Isle", category: "Services")

    private let viewModel: NotchViewModel
    private let preferences: Preferences

    let notificationRelay: NotificationRelay
    let media: MediaService
    let power: PowerMonitor
    let bluetooth: BluetoothMonitor
    let focus: FocusMonitor
    let calendar: CalendarService

    private var cancellables = Set<AnyCancellable>()

    init(viewModel: NotchViewModel, preferences: Preferences) {
        self.viewModel = viewModel
        self.preferences = preferences
        self.notificationRelay = NotificationRelay(viewModel: viewModel, preferences: preferences)
        self.media = MediaService(viewModel: viewModel, preferences: preferences)
        self.power = PowerMonitor(viewModel: viewModel, preferences: preferences)
        self.bluetooth = BluetoothMonitor(viewModel: viewModel, preferences: preferences)
        self.focus = FocusMonitor(viewModel: viewModel, preferences: preferences)
        self.calendar = CalendarService(viewModel: viewModel, preferences: preferences)
    }

    func start() {
        notificationRelay.start()
        media.start()

        // Each monitor's lifetime follows its preference toggle, so a widget the user
        // switched off costs nothing rather than merely being hidden.
        bind(preferences.$batteryEnabled) { [weak self] on in
            on ? self?.power.start() : self?.power.stop()
        }
        bind(preferences.$bluetoothEnabled) { [weak self] on in
            on ? self?.bluetooth.start() : self?.bluetooth.stop()
        }
        bind(preferences.$focusEnabled) { [weak self] on in
            on ? self?.focus.start() : self?.focus.stop()
        }
        bind(preferences.$calendarEnabled) { [weak self] on in
            on ? self?.calendar.start() : self?.calendar.stop()
        }

        log.info("Services started")
    }

    private func bind(
        _ publisher: Published<Bool>.Publisher,
        _ apply: @escaping (Bool) -> Void
    ) {
        publisher
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { apply($0) }
            .store(in: &cancellables)
    }

    func stop() {
        notificationRelay.stop()
        media.stop()
        power.stop()
        bluetooth.stop()
        focus.stop()
        calendar.stop()
        cancellables.removeAll()
    }
}
