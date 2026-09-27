//
//  FocusMonitor.swift
//  Isle
//
//  ── THERE IS NO GOOD API FOR THIS ────────────────────────────────────────────
//  macOS exposes no supported way for a third-party app to ask "which Focus is the
//  user in?". Isle combines the two partial answers that exist:
//
//  1. `INFocusStatusCenter` (Intents, macOS 12+) — PUBLIC and supported. Requires
//     the user's consent (a one-time system prompt, driven by the
//     NSFocusStatusUsageDescription key in Info.plist). It answers exactly one
//     question: is a Focus on, yes or no. It will not tell you *which* one.
//
//  2. `~/Library/DoNotDisturb/DB/{Assertions,ModeConfigurations}.json` — UNOFFICIAL.
//     These are the files the OS itself uses, and they do name the active mode.
//     Caveats, all of them real:
//       • The directory is TCC-protected. Without Full Disk Access, opening it fails
//         with EPERM — verified on this machine, so this is the normal case, not an
//         edge case. Isle degrades to the boolean from (1) and says so in Settings.
//       • The schema is not contractual and has changed across releases. Every field
//         read below is optional and guarded.
//       • Writes are atomic replacements, so the *directory* is watched, not the file
//         — a vnode watch on the file itself stops firing after the first change.
//
//  Net effect: with Full Disk Access you get "Work" with the right glyph; without it
//  you get "Focus", which is still enough to dim notifications and show a badge.
//  ─────────────────────────────────────────────────────────────────────────────
//

import AppKit
import Combine
import Foundation
import Intents
import os

@MainActor
final class FocusMonitor {

    private let log = Logger(subsystem: "com.isle.Isle", category: "Focus")

    private let viewModel: NotchViewModel
    private let preferences: Preferences

    private let databaseURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/DoNotDisturb/DB")

    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var directoryDescriptor: CInt = -1
    private var pollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private var previous: FocusStatus = .off

    /// Cache of mode identifier -> display name, parsed from ModeConfigurations.json.
    private var modeNames: [String: String] = [:]

    /// Whether the unofficial JSON files are readable at all on this machine.
    private(set) var hasDatabaseAccess = false

    init(viewModel: NotchViewModel, preferences: Preferences) {
        self.viewModel = viewModel
        self.preferences = preferences
    }

    // MARK: Lifecycle

    func start() {
        requestFocusAuthorization()

        hasDatabaseAccess = FileManager.default.isReadableFile(
            atPath: databaseURL.appendingPathComponent("Assertions.json").path
        )
        log.info("Focus database readable: \(self.hasDatabaseAccess, privacy: .public)")

        if hasDatabaseAccess {
            loadModeNames()
            startWatchingDatabase()
        }

        // The Intents API has no change notification, and the Darwin notification the
        // system posts is undocumented, so a slow poll is the honest backstop. Eight
        // seconds is imperceptible for a status badge and costs nothing.
        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // Waking and unlocking are the moments a Focus most often changes unseen.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
            .store(in: &cancellables)

        refresh()
    }

    func stop() {
        directoryWatcher?.cancel()
        directoryWatcher = nil
        if directoryDescriptor >= 0 { close(directoryDescriptor) }
        directoryDescriptor = -1
        pollTimer?.invalidate()
        pollTimer = nil
        cancellables.removeAll()
        viewModel.focus = .off
    }

    private func requestFocusAuthorization() {
        let center = INFocusStatusCenter.default
        guard center.authorizationStatus == .notDetermined else { return }
        center.requestAuthorization { [log] status in
            log.info("Focus authorization: \(status.rawValue, privacy: .public)")
        }
    }

    // MARK: Watching

    private func startWatchingDatabase() {
        // Watch the directory, not the file: the OS replaces these files atomically,
        // which detaches any vnode source bound to the old inode after one event.
        directoryDescriptor = open(databaseURL.path, O_EVTONLY)
        guard directoryDescriptor >= 0 else {
            log.notice("Could not open the Focus database directory for watching")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.directoryDescriptor >= 0 else { return }
            close(self.directoryDescriptor)
            self.directoryDescriptor = -1
        }
        source.resume()
        directoryWatcher = source
    }

    // MARK: Reading

    func refresh() {
        guard preferences.focusEnabled else {
            viewModel.focus = .off
            return
        }

        // Source of truth for "is a Focus on": the public API, when the user allowed it.
        let authorized = INFocusStatusCenter.default.authorizationStatus == .authorized
        let publicIsFocused = INFocusStatusCenter.default.focusStatus.isFocused

        let assertion = hasDatabaseAccess ? activeAssertion() : nil

        let isActive: Bool
        if authorized, let publicIsFocused {
            isActive = publicIsFocused
        } else {
            isActive = assertion != nil
        }

        let identifier = assertion
        let name: String
        if let identifier {
            name = modeNames[identifier] ?? Self.builtInName(for: identifier) ?? "Focus"
        } else {
            name = isActive ? "Focus" : "Off"
        }

        let status = FocusStatus(isActive: isActive, modeIdentifier: identifier, name: name)
        guard status != previous else { return }

        let wasActive = previous.isActive
        previous = status
        viewModel.focus = status

        // Announce a genuine change, but not the initial read at launch.
        if wasActive != status.isActive || (status.isActive && !wasActive) {
            viewModel.present(hud: .focus(status))
        }
    }

    /// Returns the identifier of the currently asserted Focus mode, if any.
    private func activeAssertion() -> String? {
        let url = databaseURL.appendingPathComponent("Assertions.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = root["storeAssertionRecords"] as? [[String: Any]]
        else { return nil }

        for record in records {
            guard let details = record["assertionDetails"] as? [String: Any] else { continue }
            if let identifier = details["assertionDetailsModeIdentifier"] as? String {
                return identifier
            }
        }
        return nil
    }

    private func loadModeNames() {
        let url = databaseURL.appendingPathComponent("ModeConfigurations.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]]
        else { return }

        var names: [String: String] = [:]
        for entry in entries {
            guard let configurations = entry["modeConfigurations"] as? [String: Any] else { continue }
            for (identifier, value) in configurations {
                guard let configuration = value as? [String: Any],
                      let mode = configuration["mode"] as? [String: Any],
                      let name = mode["name"] as? String
                else { continue }
                names[identifier] = name
            }
        }
        modeNames = names
        log.info("Loaded \(names.count, privacy: .public) Focus mode names")
    }

    /// Fallback names for Apple's built-in modes, so a machine without Full Disk
    /// Access still shows something better than "Focus" when we do have an identifier.
    private static func builtInName(for identifier: String) -> String? {
        switch identifier {
        case let id where id.hasSuffix("do-not-disturb"): return "Do Not Disturb"
        case let id where id.hasSuffix("sleep"): return "Sleep"
        case let id where id.hasSuffix("work"): return "Work"
        case let id where id.hasSuffix("personal"): return "Personal"
        case let id where id.hasSuffix("driving"): return "Driving"
        case let id where id.hasSuffix("fitness"): return "Fitness"
        case let id where id.hasSuffix("mindfulness"): return "Mindfulness"
        case let id where id.hasSuffix("gaming"): return "Gaming"
        case let id where id.hasSuffix("reading"): return "Reading"
        default: return nil
        }
    }
}
