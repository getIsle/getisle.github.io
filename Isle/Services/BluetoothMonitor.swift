//
//  BluetoothMonitor.swift
//  Isle
//
//  Connect/disconnect events for Bluetooth devices, plus battery levels for the
//  Apple audio devices that publish them.
//
//  Two different mechanisms, because no single one gives both:
//
//  1. IOBluetooth — classic Bluetooth connection notifications. Old API (it predates
//     CoreBluetooth by a decade) but it is the only one that reports *classic* device
//     connections, which is what AirPods, Magic Mouse and every BT headset use.
//     CoreBluetooth only sees BLE peripherals you explicitly scan for, and scanning
//     triggers a Bluetooth permission prompt without ever telling you that the user's
//     AirPods just connected.
//
//  2. The IORegistry — Apple's H1/H2 audio devices publish `BatteryPercent*` keys on
//     their `AppleDeviceManagementHIDEventService` node. This is undocumented but
//     stable, read-only, and needs no entitlement. If the keys are missing (any
//     third-party headset) we simply show no percentage.
//

import AppKit
import Combine
import Foundation
import IOBluetooth
import IOKit
import os

@MainActor
final class BluetoothMonitor: NSObject {

    private let log = Logger(subsystem: "com.isle.Isle", category: "Bluetooth")

    private let viewModel: NotchViewModel
    private let preferences: Preferences

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var batteryRefreshTimer: Timer?

    /// Bluetooth's major device class for audio/video peripherals.
    private static let audioMajorClass: UInt32 = 0x04

    init(viewModel: NotchViewModel, preferences: Preferences) {
        self.viewModel = viewModel
        self.preferences = preferences
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        guard connectNotification == nil else { return }

        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )

        // Seed from devices that were already connected when Isle launched, and wire
        // up their disconnect notifications (which are registered per device).
        for device in pairedDevices() where device.isConnected() {
            registerDisconnect(for: device)
        }
        rebuildDeviceList(announce: nil)

        // Battery levels are polled: the IORegistry nodes update silently, and the
        // numbers only move a percent every few minutes, so a slow timer is plenty.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rebuildDeviceList(announce: nil) }
        }
        RunLoop.main.add(timer, forMode: .common)
        batteryRefreshTimer = timer
    }

    func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
        batteryRefreshTimer?.invalidate()
        batteryRefreshTimer = nil
        viewModel.audioDevices = []
    }

    // MARK: IOBluetooth callbacks

    @objc private func deviceConnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        registerDisconnect(for: device)

        // The battery nodes do not appear in the IORegistry the instant the link comes
        // up, so give the OS a moment before reading them or the HUD shows no level.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            Task { @MainActor in
                self?.rebuildDeviceList(announce: (device.addressString ?? "", true))
            }
        }
    }

    @objc private func deviceDisconnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        let address = device.addressString ?? ""
        disconnectNotifications[address]?.unregister()
        disconnectNotifications[address] = nil
        rebuildDeviceList(announce: (address, false))
    }

    private func registerDisconnect(for device: IOBluetoothDevice) {
        let address = device.addressString ?? ""
        guard disconnectNotifications[address] == nil else { return }
        disconnectNotifications[address] = device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDisconnected(_:device:))
        )
    }

    private func pairedDevices() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    }

    // MARK: Building the list

    /// - Parameter announce: `(address, connected)` when this rebuild was caused by a
    ///   connection event that deserves a HUD card.
    private func rebuildDeviceList(announce: (address: String, connected: Bool)?) {
        let batteries = Self.batteryLevels()

        var devices: [BluetoothDeviceInfo] = []
        for device in pairedDevices() {
            let address = device.addressString ?? ""
            let name = device.name ?? device.nameOrAddress ?? "Bluetooth Device"
            let isAudio = device.deviceClassMajor == Self.audioMajorClass

            var info = BluetoothDeviceInfo(
                id: address,
                name: name,
                isConnected: device.isConnected(),
                isAudioDevice: isAudio
            )

            if let levels = Self.match(batteries, address: address, name: name) {
                info.batteryCombined = levels.combined
                info.batteryLeft = levels.left
                info.batteryRight = levels.right
                info.batteryCase = levels.caseLevel
            }
            devices.append(info)
        }

        // Connected first, audio before everything else, then alphabetical.
        devices.sort { lhs, rhs in
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
            if lhs.isAudioDevice != rhs.isAudioDevice { return lhs.isAudioDevice }
            return lhs.name < rhs.name
        }

        viewModel.audioDevices = devices

        guard preferences.bluetoothEnabled,
              let announce,
              let changed = devices.first(where: { $0.id == announce.address })
        else { return }

        log.info("""
        Bluetooth \(announce.connected ? "connect" : "disconnect", privacy: .public): \
        \(changed.name, privacy: .public)
        """)
        viewModel.present(hud: .bluetooth(changed, connected: announce.connected))
    }

    // MARK: IORegistry battery levels

    struct BatteryLevels {
        var address: String?
        var product: String?
        var combined: Int?
        var left: Int?
        var right: Int?
        var caseLevel: Int?
    }

    /// Walks `AppleDeviceManagementHIDEventService` nodes and pulls out any battery
    /// keys they expose. Entirely read-only and permission-free.
    static func batteryLevels() -> [BatteryLevels] {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("AppleDeviceManagementHIDEventService"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var results: [BatteryLevels] = []

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }

            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any]
            else { continue }

            func level(_ key: String) -> Int? {
                if let number = properties[key] as? NSNumber, number.intValue > 0 {
                    return number.intValue
                }
                // Some firmware reports these as strings such as "84".
                if let string = properties[key] as? String, let value = Int(string), value > 0 {
                    return value
                }
                return nil
            }

            let levels = BatteryLevels(
                address: (properties["DeviceAddress"] as? String)
                    ?? (properties["BD_ADDR"] as? String),
                product: properties["Product"] as? String,
                combined: level("BatteryPercentCombined"),
                left: level("BatteryPercentLeft"),
                right: level("BatteryPercentRight"),
                caseLevel: level("BatteryPercentCase")
            )

            if levels.combined != nil || levels.left != nil
                || levels.right != nil || levels.caseLevel != nil {
                results.append(levels)
            }
        }
        return results
    }

    /// The IORegistry node and the IOBluetooth device do not share an identifier
    /// scheme, so match on address (normalised) and fall back to the product name.
    private static func match(
        _ levels: [BatteryLevels],
        address: String,
        name: String
    ) -> BatteryLevels? {
        let normalisedAddress = address
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .lowercased()

        if !normalisedAddress.isEmpty {
            let byAddress = levels.first { candidate in
                guard let candidateAddress = candidate.address else { return false }
                let normalisedCandidate = candidateAddress
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: ":", with: "")
                    .lowercased()
                return normalisedCandidate == normalisedAddress
            }
            if let byAddress { return byAddress }
        }

        return levels.first { $0.product?.caseInsensitiveCompare(name) == .orderedSame }
    }
}
