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
    private var lastPlayingState: Bool?

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
        let previous = viewModel.nowPlaying
        viewModel.nowPlaying = media
        viewModel.nowPlayingDidChange()

        guard let media, !media.isEmpty else {
            lastAnnouncedTrack = nil
            lastPlayingState = nil
            return
        }

        let identity = "\(media.title)|\(media.artist)|\(media.album)"
        let isNewTrack = identity != lastAnnouncedTrack
        let startedPlaying = media.isPlaying && (lastPlayingState == false)

        lastAnnouncedTrack = identity
        lastPlayingState = media.isPlaying

        // Peek only for a genuinely new track that is actually playing. Peeking on
        // every pause/resume would make the island twitch constantly.
        guard media.isPlaying, isNewTrack || startedPlaying else { return }

        // Don't interrupt an already-open island the user is interacting with.
        guard !viewModel.isPinned, !viewModel.isHovering else { return }

        // Nor announce the very first sample after launch as if it were new — the
        // track was already playing before Isle started.
        guard previous != nil || startedPlaying else { return }

        viewModel.present(hud: .nowPlaying(media))
    }
}
