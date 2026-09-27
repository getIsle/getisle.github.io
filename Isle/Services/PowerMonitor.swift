//
//  PowerMonitor.swift
//  Isle
//
//  Battery state via IOKit's power-source API. Fully public, needs no permissions,
//  and is event-driven: `IOPSNotificationCreateRunLoopSource` fires whenever the OS's
//  own battery state changes, so there is no polling loop.
//

import Combine
import Foundation
import IOKit.ps
import os

@MainActor
final class PowerMonitor {

    private let log = Logger(subsystem: "com.isle.Isle", category: "Power")

    private let viewModel: NotchViewModel
    private let preferences: Preferences

    private var runLoopSource: CFRunLoopSource?
    private var cancellables = Set<AnyCancellable>()

    /// Previous snapshot, used to decide whether a change is HUD-worthy.
    private var previous: BatterySnapshot?

    /// Low-battery thresholds already announced this discharge cycle.
    private var announcedLowThresholds: Set<Int> = []

    init(viewModel: NotchViewModel, preferences: Preferences) {
        self.viewModel = viewModel
        self.preferences = preferences
    }

    func start() {
        guard runLoopSource == nil else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
                // Fires on the run loop we registered with (main), but hop explicitly
                // so the actor isolation is provable rather than assumed.
                Task { @MainActor in monitor.refresh(announce: true) }
            },
            context
        )?.takeRetainedValue() else {
            log.error("Could not create a power-source run loop source")
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source

        // Low Power Mode is reported separately from the power source itself.
        NotificationCenter.default
            .publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh(announce: false) }
            .store(in: &cancellables)

        refresh(announce: false)
        warnIfAlreadyLow()
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
        cancellables.removeAll()
        viewModel.battery = nil
    }

    // MARK: - Reading

    func refresh(announce: Bool) {
        guard let snapshot = Self.currentSnapshot() else { return }

        let old = previous
        previous = snapshot
        viewModel.battery = snapshot

        guard announce, preferences.batteryEnabled, let old else { return }
        announceIfInteresting(old: old, new: snapshot)
    }

    static func currentSnapshot() -> BatterySnapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }

            // Skip attached UPS/peripheral batteries — we only want the Mac's own.
            guard (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }

            let current = (description[kIOPSCurrentCapacityKey] as? Int) ?? 0
            let maximum = (description[kIOPSMaxCapacityKey] as? Int) ?? 100
            let percentage = maximum > 0
                ? Int((Double(current) / Double(maximum)) * 100.0)
                : current

            let state = (description[kIOPSPowerSourceStateKey] as? String) ?? ""
            let powerSource: BatterySnapshot.PowerSource
            switch state {
            case kIOPSACPowerValue: powerSource = .acPower
            case kIOPSBatteryPowerValue: powerSource = .battery
            default: powerSource = .unknown
            }

            let isCharging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            let isCharged = (description[kIOPSIsChargedKey] as? Bool) ?? false

            // IOKit reports -1 for "still calculating".
            let rawMinutes = isCharging
                ? (description[kIOPSTimeToFullChargeKey] as? Int)
                : (description[kIOPSTimeToEmptyKey] as? Int)
            let timeRemaining = (rawMinutes ?? -1) > 0
                ? TimeInterval((rawMinutes ?? 0) * 60)
                : nil

            return BatterySnapshot(
                percentage: max(0, min(100, percentage)),
                isCharging: isCharging,
                isCharged: isCharged,
                powerSource: powerSource,
                timeRemaining: timeRemaining,
                isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
        }

        // Desktop Macs have no internal battery. Not an error — just nothing to show.
        return nil
    }

    // MARK: - HUD decisions

    private func announceIfInteresting(old: BatterySnapshot, new: BatterySnapshot) {
        // Plugged in / unplugged is the headline event.
        if old.powerSource != new.powerSource {
            let reason: BatteryHUDReason = (new.powerSource == .acPower) ? .pluggedIn : .unplugged
            if reason == .unplugged { announcedLowThresholds.removeAll() }
            viewModel.present(hud: .battery(new, reason: reason))
            return
        }

        if !old.isCharged, new.isCharged {
            viewModel.present(hud: .battery(new, reason: .charged))
            return
        }

        guard new.powerSource == .battery else {
            announcedLowThresholds.removeAll()
            return
        }

        // Low-battery warnings, at most once per threshold per discharge cycle.
        for threshold in Self.lowThresholds
        where new.percentage <= threshold
            && old.percentage > threshold
            && !announcedLowThresholds.contains(threshold) {
            announcedLowThresholds.insert(threshold)
            warnLow(new)
            return
        }
    }

    private static let lowThresholds = [20, 10, 5]

    /// Launched (or the widget switched on) while already low and unplugged: the
    /// crossing-based check above would never fire, so warn once now.
    private func warnIfAlreadyLow() {
        guard preferences.batteryEnabled,
              let snapshot = previous,
              snapshot.powerSource == .battery,
              let threshold = Self.lowThresholds.last(where: { snapshot.percentage <= $0 })
        else { return }
        // Mark this and every higher threshold as done for this discharge cycle.
        announcedLowThresholds.formUnion(Self.lowThresholds.filter { $0 >= threshold })
        warnLow(snapshot)
    }

    /// iPhone-style low-battery alert: the island widens, a red/orange battery on
    /// the left of the camera and the percentage on the right. Held for 5 s —
    /// longer than a routine HUD, because the user has to act on it.
    private func warnLow(_ snapshot: BatterySnapshot) {
        viewModel.present(hud: .battery(snapshot, reason: .low), duration: 5)
    }
}
