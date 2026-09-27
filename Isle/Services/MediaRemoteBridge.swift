//
//  MediaRemoteBridge.swift
//  Isle
//
//  ── PRIVATE API WARNING ──────────────────────────────────────────────────────
//  This file talks to /System/Library/PrivateFrameworks/MediaRemote.framework.
//  It is not a public API. Consequences, in order of how much they will bite you:
//
//   • App Store: instantly rejected. Isle can never ship there with this file in it.
//   • Notarization / Developer ID: fine. Notarization does not scan for private
//     framework use, so a locally signed or Developer-ID-signed build runs normally.
//   • Hardened Runtime: you must add `com.apple.security.cs.disable-library-validation`
//     (already in Config/Isle.entitlements) or dlopen() is refused at runtime.
//   • Sandbox: impossible. The sandbox blocks the mach lookups MediaRemote performs.
//   • OS upgrades: this can break at any time. macOS 15.4 restricted the now-playing
//     APIs to Apple-signed callers on some configurations; that is exactly why
//     `MediaService` treats this class as *optional* and has an AppleScript fallback.
//
//  THE ALTERNATIVE, AND WHY IT ISN'T USED AS THE PRIMARY PATH
//  `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter` are public and sandbox-safe,
//  but they are designed for an app that *is* the now-playing app: they let you
//  publish your own metadata and receive commands for your own playback. They give
//  you no way to read what Spotify or Safari is playing, which is the entire feature.
//  There is no public, system-wide "what is playing" API on macOS.
//
//  Everything is resolved with dlopen/dlsym rather than by linking the framework, so
//  a missing or changed framework degrades to "no media source" instead of a crash
//  on launch.
//  ─────────────────────────────────────────────────────────────────────────────
//

import AppKit
import Foundation
import os

// MARK: - C function shapes

private typealias MRGetNowPlayingInfo =
    @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
private typealias MRGetNowPlayingApplicationPID =
    @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
private typealias MRGetNowPlayingApplicationIsPlaying =
    @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
private typealias MRRegisterForNotifications = @convention(c) (DispatchQueue) -> Void
private typealias MRUnregisterForNotifications = @convention(c) () -> Void
private typealias MRSendCommand = @convention(c) (Int32, CFDictionary?) -> Bool

final class MediaRemoteBridge: NowPlayingSource {

    // MediaRemote's command numbers. Stable since the framework's introduction.
    private enum Command: Int32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    // Dictionary keys are plain strings — the framework's exported CFString symbols
    // simply hold these literals, so there is nothing gained by dlsym'ing them.
    private enum InfoKey {
        static let title = "kMRMediaRemoteNowPlayingInfoTitle"
        static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
        static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
        static let artworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
        static let artworkIdentifier = "kMRMediaRemoteNowPlayingInfoArtworkIdentifier"
        static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
        static let elapsed = "kMRMediaRemoteNowPlayingInfoElapsedTime"
        static let playbackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
        static let timestamp = "kMRMediaRemoteNowPlayingInfoTimestamp"
    }

    private static let notificationNames = [
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
    ]

    private let log = Logger(subsystem: "com.isle.Isle", category: "MediaRemote")

    private var handle: UnsafeMutableRawPointer?
    private var getNowPlayingInfo: MRGetNowPlayingInfo?
    private var getPID: MRGetNowPlayingApplicationPID?
    private var getIsPlaying: MRGetNowPlayingApplicationIsPlaying?
    private var registerForNotifications: MRRegisterForNotifications?
    private var unregisterForNotifications: MRUnregisterForNotifications?
    private var sendCommand: MRSendCommand?

    private var observers: [NSObjectProtocol] = []
    private var resyncTimer: Timer?
    private var isRunning = false

    /// Decoding a JPEG on every info change is wasteful — MediaRemote hands us a
    /// stable identifier per artwork, so decode once per identifier.
    private var artworkCache: (identifier: String, image: NSImage)?

    // MARK: NowPlayingSource

    var onUpdate: ((NowPlayingInfo?) -> Void)?

    private(set) var isAvailable = false

    /// `true` once the framework has actually handed us a non-empty payload.
    /// `MediaService` uses this to decide whether the AppleScript fallback is needed.
    private(set) var hasProducedData = false

    let name = "MediaRemote"

    init() {
        loadFramework()
    }

    deinit {
        // Intentionally not dlclose()'d: MediaRemote installs process-wide notification
        // machinery, and unloading it out from under that has historically crashed.
        resyncTimer?.invalidate()
    }

    private func loadFramework() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW) else {
            log.notice("MediaRemote could not be opened: \(String(cString: dlerror()), privacy: .public)")
            return
        }
        self.handle = handle

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else {
                log.notice("MediaRemote symbol missing: \(name, privacy: .public)")
                return nil
            }
            return unsafeBitCast(pointer, to: type)
        }

        getNowPlayingInfo = symbol("MRMediaRemoteGetNowPlayingInfo", as: MRGetNowPlayingInfo.self)
        getPID = symbol("MRMediaRemoteGetNowPlayingApplicationPID", as: MRGetNowPlayingApplicationPID.self)
        getIsPlaying = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: MRGetNowPlayingApplicationIsPlaying.self)
        registerForNotifications = symbol("MRMediaRemoteRegisterForNowPlayingNotifications", as: MRRegisterForNotifications.self)
        unregisterForNotifications = symbol("MRMediaRemoteUnregisterForNowPlayingNotifications", as: MRUnregisterForNotifications.self)
        sendCommand = symbol("MRMediaRemoteSendCommand", as: MRSendCommand.self)

        // Reading info is the minimum viable feature; commands are a bonus.
        isAvailable = (getNowPlayingInfo != nil && registerForNotifications != nil)
        log.info("MediaRemote available: \(self.isAvailable, privacy: .public)")
    }

    // MARK: Lifecycle

    func start() {
        guard isAvailable, !isRunning else { return }
        isRunning = true

        registerForNotifications?(DispatchQueue.main)

        for name in Self.notificationNames {
            let observer = NotificationCenter.default.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
            observers.append(observer)
        }

        // Safety net: some clients (notably browsers) update elapsed time without
        // posting a change notification, so resync the playhead periodically. This is
        // cheap — one XPC round trip every few seconds — and keeps the bar honest.
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        resyncTimer = timer

        refresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        resyncTimer?.invalidate()
        resyncTimer = nil
        unregisterForNotifications?()
    }

    // MARK: Reading

    func refresh() {
        guard isRunning, let getNowPlayingInfo else { return }

        getNowPlayingInfo(DispatchQueue.main) { [weak self] dictionary in
            guard let self else { return }

            guard let info = dictionary as? [String: Any], !info.isEmpty else {
                self.onUpdate?(nil)
                return
            }

            // MediaRemote reports the playing flag separately from the info dict, and
            // the dict's playbackRate is the more reliable of the two for browsers.
            let rate = (info[InfoKey.playbackRate] as? NSNumber)?.doubleValue ?? 0

            var media = NowPlayingInfo(
                title: (info[InfoKey.title] as? String) ?? "",
                artist: (info[InfoKey.artist] as? String) ?? "",
                album: (info[InfoKey.album] as? String) ?? "",
                isPlaying: rate > 0,
                duration: (info[InfoKey.duration] as? NSNumber)?.doubleValue ?? 0,
                elapsed: (info[InfoKey.elapsed] as? NSNumber)?.doubleValue ?? 0,
                playbackRate: rate,
                timestamp: (info[InfoKey.timestamp] as? Date) ?? Date(),
                artwork: self.artwork(from: info),
                sourceBundleIdentifier: nil,
                sourceName: nil
            )

            if media.isEmpty {
                self.onUpdate?(nil)
                return
            }

            self.hasProducedData = true

            // Resolve which app owns playback so we can show its icon.
            if let getPID = self.getPID {
                getPID(DispatchQueue.main) { pid in
                    if pid > 0,
                       let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                        media.sourceBundleIdentifier = app.bundleIdentifier
                        media.sourceName = app.localizedName
                    }
                    self.onUpdate?(media)
                }
            } else {
                self.onUpdate?(media)
            }
        }
    }

    private func artwork(from info: [String: Any]) -> NSImage? {
        guard let data = info[InfoKey.artworkData] as? Data, !data.isEmpty else { return nil }

        let identifier = (info[InfoKey.artworkIdentifier] as? String)
            ?? String(data.count)

        if let cached = artworkCache, cached.identifier == identifier {
            return cached.image
        }

        guard let image = NSImage(data: data) else { return nil }
        artworkCache = (identifier, image)
        return image
    }

    // MARK: Commands

    @discardableResult
    func send(_ command: MediaCommand) -> Bool {
        guard let sendCommand else { return false }

        let raw: Command
        switch command {
        case .togglePlayPause: raw = .togglePlayPause
        case .play: raw = .play
        case .pause: raw = .pause
        case .nextTrack: raw = .nextTrack
        case .previousTrack: raw = .previousTrack
        }

        let result = sendCommand(raw.rawValue, nil)
        log.debug("MediaRemote command \(raw.rawValue, privacy: .public) -> \(result, privacy: .public)")

        // The info dict lags the command by a beat; nudge it so the UI feels instant.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refresh() }
        return result
    }
}
