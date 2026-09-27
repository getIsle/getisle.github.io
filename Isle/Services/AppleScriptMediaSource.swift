//
//  AppleScriptMediaSource.swift
//  Isle
//
//  Now Playing over Apple Events. On macOS 15.4 and later this is the PRIMARY path,
//  not a fallback: MediaRemote's now-playing data is gated to Apple-signed callers,
//  so a normal third-party app gets a nil dictionary no matter how it is signed.
//
//  (If you test MediaRemote with `swift somefile.swift` it appears to work. It is not
//  your app that is allowed — it is Apple's signed `swift` interpreter hosting your
//  code. Compile the same code into any binary and it returns nil. That mistake is
//  easy to make and costs an afternoon.)
//
//  This is the same approach Alcove itself uses; its code signature requests
//  apple-events exceptions for exactly these bundle IDs.
//
//  Two kinds of player:
//
//  • Native scriptable apps (Music, Spotify) expose a real AppleScript dictionary —
//    `current track`, `player position`, `player state`.
//
//  • Browsers (Safari, Chrome) expose no such thing, so we run a small JavaScript
//    snippet in each tab and read `navigator.mediaSession.metadata` plus the
//    underlying <video>/<audio> element. That is how YouTube, Spotify Web, SoundCloud
//    and friends are picked up.
//
//  PERMISSIONS THIS NEEDS (all user-granted, all recoverable):
//   1. Automation, per target app — macOS prompts the first time we talk to each one.
//   2. For browsers only, "Allow JavaScript from Apple Events":
//        Safari ▸ Develop ▸ Allow JavaScript from Apple Events
//        Chrome ▸ View ▸ Developer ▸ Allow JavaScript from Apple Events
//      Both are off by default. Without them the browser queries fail harmlessly and
//      Isle just falls through to the next player.
//

import AppKit
import Foundation
import os

final class AppleScriptMediaSource: NowPlayingSource {

    private enum Kind { case native, browser }

    private enum Player: CaseIterable {
        case spotify
        case music
        case safari
        case chrome

        var bundleIdentifier: String {
            switch self {
            case .spotify: return "com.spotify.client"
            case .music: return "com.apple.Music"
            case .safari: return "com.apple.Safari"
            case .chrome: return "com.google.Chrome"
            }
        }

        var applicationName: String {
            switch self {
            case .spotify: return "Spotify"
            case .music: return "Music"
            case .safari: return "Safari"
            case .chrome: return "Google Chrome"
            }
        }

        var kind: Kind {
            switch self {
            case .spotify, .music: return .native
            case .safari, .chrome: return .browser
            }
        }

        /// Spotify reports track length in milliseconds, everything else in seconds.
        var durationScale: Double {
            self == .spotify ? 1.0 / 1000.0 : 1.0
        }
    }

    private let log = Logger(subsystem: "com.isle.Isle", category: "AppleScriptMedia")

    /// NSAppleScript is a synchronous Apple Event round trip that can take tens of
    /// milliseconds — and iterating browser tabs can take longer. Never on the main
    /// thread.
    private let queue = DispatchQueue(label: "com.isle.Isle.applescript", qos: .utility)

    private var pollTimer: Timer?
    private var isRunning = false
    private var artworkCache: (url: String, image: NSImage)?

    /// Remembers which player answered last, so the next poll asks it first instead of
    /// walking every browser tab again.
    private var preferredPlayer: Player?

    var onUpdate: ((NowPlayingInfo?) -> Void)?
    private(set) var hasProducedData = false

    let name = "Apple Events (Music, Spotify, Safari, Chrome)"

    /// Available if any supported player is installed. We never *launch* anything —
    /// only already-running apps are queried — so this cannot cause a surprise launch.
    var isAvailable: Bool {
        Player.allCases.contains { player in
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: player.bundleIdentifier
            ) != nil
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        refresh()
    }

    func stop() {
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() {
        guard isRunning else { return }

        queue.async { [weak self] in
            guard let self else { return }

            // Ask whoever answered last first; a running player is usually still the
            // running player, and this keeps the common case to a single Apple Event.
            var order = Player.allCases
            if let preferred = self.preferredPlayer,
               let index = order.firstIndex(of: preferred) {
                order.remove(at: index)
                order.insert(preferred, at: 0)
            }

            for player in order where self.isLaunched(player) {
                if let media = self.query(player) {
                    self.hasProducedData = true
                    self.preferredPlayer = player
                    DispatchQueue.main.async {
                        MediaDiagnostics.shared.clearIssues()
                        MediaDiagnostics.shared.hasData = true
                        self.onUpdate?(media)
                    }
                    return
                }
            }

            self.preferredPlayer = nil
            DispatchQueue.main.async { self.onUpdate?(nil) }
        }
    }

    /// Checking the running-app list first is what stops a query from launching the
    /// app: `tell application "Music"` on a quit app would start it.
    private func isLaunched(_ player: Player) -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: player.bundleIdentifier
        ).isEmpty
    }

    private func query(_ player: Player) -> NowPlayingInfo? {
        switch player.kind {
        case .native: return queryNative(player)
        case .browser: return queryBrowser(player)
        }
    }

    // MARK: - Native scriptable players

    private func queryNative(_ player: Player) -> NowPlayingInfo? {
        let artworkLine = player == .spotify ? "& linefeed & (artwork url of tr as text)" : ""
        let source = """
        tell application "\(player.applicationName)"
            if player state is stopped then return "STOPPED"
            set tr to current track
            return (name of tr as text) & linefeed & \
                   (artist of tr as text) & linefeed & \
                   (album of tr as text) & linefeed & \
                   (duration of tr as text) & linefeed & \
                   (player position as text) & linefeed & \
                   (player state as text) \(artworkLine)
        end tell
        """

        guard let raw = run(source, player: player), raw != "STOPPED" else { return nil }
        return parse(raw, player: player)
    }

    // MARK: - Browsers

    /// Reads the Media Session metadata the page published, falling back to the
    /// document title and the first media element. Returns an empty string when the
    /// tab has nothing playing, which keeps the AppleScript side simple.
    private static let mediaProbeJavaScript = """
    (function(){
      try {
        var v = document.querySelector('video, audio');
        var md = (navigator.mediaSession && navigator.mediaSession.metadata) || null;
        if (!v && !md) { return ''; }
        if (v && v.paused && !md) { return ''; }
        var title  = md && md.title  ? md.title  : (document.title || '');
        var artist = md && md.artist ? md.artist : '';
        var album  = md && md.album  ? md.album  : '';
        var art = '';
        if (md && md.artwork && md.artwork.length) { art = md.artwork[md.artwork.length - 1].src; }
        var dur = v && isFinite(v.duration) ? v.duration : 0;
        var pos = v ? v.currentTime : 0;
        var state = (v && !v.paused) ? 'playing' : 'paused';
        if (!title) { return ''; }
        return [title, artist, album, dur, pos, state, art].join('\\n');
      } catch (e) { return ''; }
    })()
    """

    private func queryBrowser(_ player: Player) -> NowPlayingInfo? {
        // Escape the snippet for embedding in an AppleScript string literal.
        let escaped = Self.mediaProbeJavaScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")

        let source: String
        switch player {
        case .safari:
            source = """
            tell application "Safari"
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set r to (do JavaScript "\(escaped)" in t)
                            if r is not missing value and r is not "" then return r
                        end try
                    end repeat
                end repeat
            end tell
            return ""
            """
        case .chrome:
            source = """
            tell application "Google Chrome"
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set r to (execute t javascript "\(escaped)")
                            if r is not missing value and r is not "" then return r
                        end try
                    end repeat
                end repeat
            end tell
            return ""
            """
        default:
            return nil
        }

        guard let raw = run(source, player: player), !raw.isEmpty else { return nil }
        return parse(raw, player: player)
    }

    // MARK: - Shared plumbing

    private func run(_ source: String, player: Player) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)

        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown"

            log.notice("""
            Apple Event to \(player.applicationName, privacy: .public) failed \
            (\(code, privacy: .public)): \(message, privacy: .public)
            """)

            // Translate the two failures a user can actually do something about.
            // -1743 is "not authorised to send Apple events"; Safari reports 8 when
            // `do JavaScript` is blocked, and Chrome phrases it in the message.
            let appName = player.applicationName
            let javaScriptBlocked = code == 8
                || message.localizedCaseInsensitiveContains("Allow JavaScript from Apple Events")
            let notAuthorized = code == -1743
                || message.localizedCaseInsensitiveContains("Not authorized")

            Task { @MainActor in
                if javaScriptBlocked {
                    MediaDiagnostics.shared.record(.browserJavaScriptDisabled(app: appName))
                } else if notAuthorized {
                    MediaDiagnostics.shared.record(.automationDenied(app: appName))
                }
            }
            return nil
        }
        return result.stringValue
    }

    private func parse(_ raw: String, player: Player) -> NowPlayingInfo? {
        let fields = raw.components(separatedBy: "\n")
        guard fields.count >= 6 else { return nil }

        let title = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let duration = (Double(fields[3]) ?? 0) * player.durationScale
        let position = (Double(fields[4]) ?? 0) * (player.kind == .browser ? 1 : 1)
        let isPlaying = fields[5].lowercased().contains("playing")

        var artwork: NSImage?
        if fields.count >= 7 { artwork = self.artwork(forURL: fields[6]) }

        return NowPlayingInfo(
            title: title,
            artist: fields[1],
            album: fields[2],
            isPlaying: isPlaying,
            duration: duration,
            elapsed: position,
            playbackRate: isPlaying ? 1 : 0,
            timestamp: Date(),
            artwork: artwork,
            sourceBundleIdentifier: player.bundleIdentifier,
            sourceName: player.applicationName
        )
    }

    private func artwork(forURL string: String) -> NSImage? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }

        if let cached = artworkCache, cached.url == trimmed { return cached.image }

        // Synchronous, but we are already on a background queue and these are a few
        // KB from a CDN. A failure just means no art this cycle.
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else {
            return nil
        }
        artworkCache = (trimmed, image)
        return image
    }

    // MARK: - Commands

    @discardableResult
    func send(_ command: MediaCommand) -> Bool {
        guard let player = preferredPlayer ?? Player.allCases.first(where: { isLaunched($0) })
        else { return false }

        let source: String
        switch player.kind {
        case .native:
            let verb: String
            switch command {
            case .togglePlayPause: verb = "playpause"
            case .play: verb = "play"
            case .pause: verb = "pause"
            case .nextTrack: verb = "next track"
            case .previousTrack: verb = "previous track"
            }
            source = "tell application \"\(player.applicationName)\" to \(verb)"

        case .browser:
            // Drive the page's own media element. Track skipping maps to the Media
            // Session action handlers the site registered, which is what YouTube and
            // Spotify Web use for their own next/previous buttons.
            let javascript: String
            switch command {
            case .togglePlayPause:
                javascript = "var v=document.querySelector('video, audio'); if(v){v.paused?v.play():v.pause();}"
            case .play:
                javascript = "var v=document.querySelector('video, audio'); if(v){v.play();}"
            case .pause:
                javascript = "var v=document.querySelector('video, audio'); if(v){v.pause();}"
            case .nextTrack:
                javascript = "document.querySelector('.ytp-next-button, [data-testid=control-button-skip-forward], [aria-label*=Next]')?.click();"
            case .previousTrack:
                javascript = "document.querySelector('.ytp-prev-button, [data-testid=control-button-skip-back], [aria-label*=Previous]')?.click();"
            }
            let escaped = javascript
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")

            switch player {
            case .safari:
                source = """
                tell application "Safari"
                    repeat with w in windows
                        repeat with t in tabs of w
                            try
                                if (do JavaScript "!!document.querySelector('video, audio')" in t) is true then
                                    do JavaScript "\(escaped)" in t
                                    return
                                end if
                            end try
                        end repeat
                    end repeat
                end tell
                """
            case .chrome:
                source = """
                tell application "Google Chrome"
                    repeat with w in windows
                        repeat with t in tabs of w
                            try
                                if (execute t javascript "!!document.querySelector('video, audio')") is true then
                                    execute t javascript "\(escaped)"
                                    return
                                end if
                            end try
                        end repeat
                    end repeat
                end tell
                """
            default:
                return false
            }
        }

        queue.async { [weak self] in
            guard let self else { return }
            _ = self.run(source, player: player)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refresh() }
        }
        return true
    }
}
