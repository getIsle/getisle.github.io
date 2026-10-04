//
//  MediaService.swift
//  Isle
//
//  Chooses a Now Playing backend, keeps the view model fed, and decides when a
//  change is interesting enough to deserve a peek animation.
//

import AppKit
import Combine
import os

@MainActor
final class MediaService {

    private let log = Logger(subsystem: "com.isle.Isle", category: "MediaService")

    private let viewModel: NotchViewModel
    private let preferences: Preferences

    private let mediaRemote = MediaRemoteBridge()
    private let helper = MediaRemoteHelperSource()
    private let appleScript = AppleScriptMediaSource()

    private var activeSource: NowPlayingSource?
    /// A system-wide source kept running in the background while Apple Events is
    /// active. It could not prove itself at startup — most often simply because
    /// nothing was playing yet — so the moment it reports a track it takes over.
    private var standbySource: NowPlayingSource?
    private var fallbackProbe: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    /// Last track we announced, so we peek once per track rather than once per update.
    private var lastAnnouncedTrack: String?
    /// Whether the previous (non-empty) sample was playing, and which app it came from.
    private var lastSeenPlaying = false
    private var lastSeenSource = ""
    /// When playback last went from playing to paused. A pause only counts as a real
    /// pause once it has lasted a few seconds — switching windows can make a player
    /// report a momentary pause, and that must not look like "playback started".
    private var pausedSince: Date?
    /// An announcement waiting out its settle delay, and the track it is for.
    private var pendingAnnounce: DispatchWorkItem?
    private var pendingIdentity: String?

    init(viewModel: NotchViewModel, preferences: Preferences) {
        self.viewModel = viewModel
        self.preferences = preferences
    }

    // MARK: Lifecycle

    func start() {
        preferences.$nowPlayingEnabled
            .combineLatest(preferences.$useMediaRemote, preferences.$useAppleScriptFallback)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.reconfigure() }
            .store(in: &cancellables)

        reconfigure()
    }

    func stop() {
        cancelPendingAnnouncement()
        fallbackProbe?.cancel()
        activeSource?.stop()
        activeSource = nil
        standbySource?.stop()
        standbySource = nil
        viewModel.mediaCommandHandler = nil
        viewModel.nowPlaying = nil
        cancellables.removeAll()
    }

    // MARK: Source selection

    private func reconfigure() {
        fallbackProbe?.cancel()
        activeSource?.stop()
        activeSource = nil
        standbySource?.stop()
        standbySource = nil

        guard preferences.nowPlayingEnabled else {
            viewModel.mediaCommandHandler = nil
            viewModel.nowPlaying = nil
            viewModel.nowPlayingDidChange()
            return
        }

        // Preference order, most capable first:
        //   1. MediaRemote in-process — works on older macOS, dead on 15.4+.
        //   2. MediaRemote via the Swift-interpreter helper — every app, event-driven.
        //   3. Apple Events — Music, Spotify, Safari, Chrome only; polled.
        // Each stage gets a grace period to produce a track before the next one runs.
        if preferences.useMediaRemote {
            startInProcessStage()
        } else {
            fallBackToAppleScript(keeping: nil)
        }
    }

    private func startInProcessStage() {
        guard mediaRemote.isAvailable else {
            startHelperStage()
            return
        }
        adopt(mediaRemote)
        probe(mediaRemote, grace: 2.5) { [weak self] in
            guard let self else { return }
            self.log.notice("In-process MediaRemote returned nothing (normal on macOS 15.4+) — trying the helper")
            MediaDiagnostics.shared.record(.mediaRemoteRestricted)
            self.mediaRemote.stop()
            self.startHelperStage()
        }
    }

    private func startHelperStage() {
        guard helper.isAvailable else {
            fallBackToAppleScript(keeping: nil)
            return
        }
        adopt(helper)
        // Generous: the helper's first run includes a JIT compile of its script.
        probe(helper, grace: 12) { [weak self] in
            guard let self else { return }
            self.log.notice("Helper has reported no track yet — Apple Events active, helper on standby")
            self.fallBackToAppleScript(keeping: self.helper)
        }
    }

    private func fallBackToAppleScript(keeping standby: NowPlayingSource?) {
        guard preferences.useAppleScriptFallback, appleScript.isAvailable else {
            // Nothing better to fall back to — keep whatever is running.
            if activeSource == nil {
                log.notice("No Now Playing source available")
                viewModel.mediaCommandHandler = nil
            }
            return
        }

        if let standby {
            standbySource = standby
            standby.onUpdate = { [weak self, weak standby] media in
                Task { @MainActor in self?.standbyReported(media, from: standby) }
            }
            // Deliberately not stopped: it keeps listening in the background.
        }
        adopt(appleScript)
    }

    private func standbyReported(_ media: NowPlayingInfo?, from source: NowPlayingSource?) {
        guard let source, source === standbySource, let media, !media.isEmpty else { return }
        log.info("\(source.name, privacy: .public) produced a track — promoting it over Apple Events")
        standbySource = nil
        appleScript.stop()
        adopt(source)          // already running; this just rewires the callbacks
        apply(media)
    }

    private func probe(_ source: NowPlayingSource, grace: Double, otherwise: @escaping () -> Void) {
        fallbackProbe?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.activeSource === source, !source.hasProducedData else { return }
            otherwise()
        }
        fallbackProbe = work
        DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: work)
    }

    private func adopt(_ source: NowPlayingSource) {
        log.info("Now Playing source: \(source.name, privacy: .public)")

        MediaDiagnostics.shared.activeSourceName = source.name

        source.onUpdate = { [weak self] media in
            Task { @MainActor in self?.apply(media) }
        }
        source.start()
        activeSource = source

        viewModel.mediaCommandHandler = { [weak source] command in
            source?.send(command)
        }
    }

    // MARK: Applying updates

    private func apply(_ media: NowPlayingInfo?) {
        viewModel.nowPlaying = media
        viewModel.nowPlayingDidChange()

        // A missed poll is not "playback stopped". Switching windows makes the sources
        // blink, so an empty sample must not make the same song look new when it returns.
        guard let media, !media.isEmpty else { return }

        let identity = Self.identity(of: media)
        let source = media.sourceBundleIdentifier ?? media.sourceName ?? ""

        defer {
            lastSeenPlaying = media.isPlaying
            lastSeenSource = source
            if media.isPlaying {
                pausedSince = nil
            } else if pausedSince == nil {
                pausedSince = Date()
            }
        }

        // Peek only for a track that is actually playing. Peeking on every pause or
        // resume would make the island twitch constantly.
        guard media.isPlaying else {
            cancelPendingAnnouncement()
            return
        }

        // The track that was already playing when Isle launched is the baseline, not news.
        guard let announced = lastAnnouncedTrack else {
            if pausedSince != nil {
                scheduleAnnouncement(identity: identity)
            } else {
                lastAnnouncedTrack = identity
            }
            return
        }

        // macOS hands "now playing" to whichever app you focus. If something was already
        // playing and the reporting app changed, that is the system switching clients as
        // you move between windows, not a new song, so adopt it silently.
        let isNewTrack = identity != announced
        let clientHandover = isNewTrack && lastSeenPlaying
            && !source.isEmpty && !lastSeenSource.isEmpty && source != lastSeenSource
        if clientHandover {
            cancelPendingAnnouncement()
            lastAnnouncedTrack = identity
            return
        }

        // Back to the track we already announced: whatever was pending was a blip.
        if let pending = pendingIdentity, pending != identity { cancelPendingAnnouncement() }
        if pendingIdentity == identity { return }   // already counting down

        let resumedAfterRealPause = pausedSince.map { Date().timeIntervalSince($0) > 4 } ?? false
        guard isNewTrack || resumedAfterRealPause else { return }

        scheduleAnnouncement(identity: identity)
    }

    /// Waits a moment before peeking so a blip that corrects itself never reaches the screen.
    private func scheduleAnnouncement(identity: String) {
        pendingAnnounce?.cancel()
        pendingIdentity = identity
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingIdentity = nil
            self.pendingAnnounce = nil
            guard let current = self.viewModel.nowPlaying, current.isPlaying,
                  Self.identity(of: current) == identity else { return }
            self.lastAnnouncedTrack = identity

            // Don't interrupt an island the user is interacting with.
            guard !self.viewModel.isPinned, !self.viewModel.isHovering else { return }
            self.viewModel.present(hud: .nowPlaying(current))
        }
        pendingAnnounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func cancelPendingAnnouncement() {
        pendingAnnounce?.cancel()
        pendingAnnounce = nil
        pendingIdentity = nil
    }

    /// Title and artist only, ignoring case and spacing. Album and other metadata often
    /// arrive late or half-filled, which would otherwise make one song look like two.
    private static func identity(of media: NowPlayingInfo) -> String {
        func normalise(_ text: String) -> String {
            text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        return normalise(media.title) + "|" + normalise(media.artist)
    }
}
