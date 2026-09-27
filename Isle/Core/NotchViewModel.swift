//
//  NotchViewModel.swift
//  Isle
//
//  The single source of truth for what the island is doing. Services push data in,
//  the window controller pushes hover state in, and the view reads exactly one
//  derived value — `presentation` — to decide its size and contents.
//
//  `presentation` is *never* assigned from the outside. It is recomputed from the
//  inputs by `recomputePresentation()`, which keeps the state machine impossible to
//  desync (the classic bug in this kind of overlay: a peek timer fires while the
//  pointer is inside, and the island collapses out from under the cursor).
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchViewModel: ObservableObject {

    enum Presentation: Equatable {
        /// Exactly the notch. Invisible on notched hardware.
        case collapsed
        /// Slightly wider — content flanks the camera housing.
        case peek
        /// A notification card hanging below the notch.
        case notification
        /// Full widget surface.
        case expanded
    }

    // MARK: Inputs

    @Published var metrics: NotchMetrics = .fallback

    /// Set while a full-screen app owns the display. The view folds the island up
    /// into the housing and fades it; the window is ordered out afterwards.
    @Published var isSuppressed = false
    @Published var isPinned = false

    /// Set by `NotchWindowController` from a global mouse monitor.
    @Published var isHovering = false {
        didSet {
            guard isHovering != oldValue else { return }
            // A click-opened panel closes as soon as the pointer leaves it.
            if !isHovering { isClickOpened = false }
            recomputePresentation()
        }
    }

    /// Opened by a click (rather than pinned). Lives only while the pointer stays
    /// over the island, like Alcove.
    private var isClickOpened = false

    // MARK: Widget data

    @Published var nowPlaying: NowPlayingInfo? {
        didSet {
            // A playing track gives the island a resting "mini player" peek, and a
            // stopped one takes it away, so recompute rather than wait for a timer.
            if (oldValue?.isPlaying ?? false) != (nowPlaying?.isPlaying ?? false) {
                recomputePresentation()
            }
            // Sample the artwork colour once per cover rather than on every render —
            // the visualiser and the glow both read it at 30–120 Hz.
            if nowPlaying?.artwork !== oldValue?.artwork {
                if let color = nowPlaying?.artwork?.dominantColor {
                    artworkTint = Color(nsColor: color)
                } else {
                    artworkTint = nil
                }
            }
        }
    }

    /// Dominant colour of the current cover, or nil when there is no artwork. This is
    /// what Alcove tints the visualiser with, so the bars pick up the record's colour.
    @Published private(set) var artworkTint: Color?
    @Published var battery: BatterySnapshot?
    @Published var audioDevices: [BluetoothDeviceInfo] = []
    @Published var focus: FocusStatus = .off

    /// Next events (today and tomorrow), soonest first. Fed by CalendarService.
    @Published var upcomingEvents: [CalendarEvent] = []
    @Published var calendarAccess: CalendarAccess = .unknown

    // MARK: Derived output

    @Published private(set) var presentation: Presentation = .collapsed

    /// What kind of size change happened last, so the view can pick the right
    /// spring. Opening overshoots a little, closing settles without bounce, and the
    /// hover "lift" is a quick, springy nudge.
    enum Motion: Equatable { case open, close, hoverIn, hoverOut }
    @Published private(set) var motion: Motion = .open

    var isGrowing: Bool { motion == .open || motion == .hoverIn }

    /// Pointer is over a closed island: it swells slightly to say "click me".
    /// Measured off Alcove: 179×32 → 192×37 on a 14" MacBook Pro.
    @Published private(set) var isHoverLifted = false
    private let hoverLift = CGSize(width: 14, height: 5)
    @Published private(set) var hud: HUDEvent?
    @Published private(set) var currentNotification: NotchNotification?

    /// Progress-bar ticker. Only runs while the island is visibly showing progress,
    /// so a paused, collapsed island costs nothing.
    @Published private(set) var tick: Date = .init()

    private var pendingNotifications: [NotchNotification] = []
    private var hudDismissal: DispatchWorkItem?
    private var notificationDismissal: DispatchWorkItem?
    private var hoverWorkItem: DispatchWorkItem?
    private var ticker: Timer?

    private let preferences: Preferences

    /// Installed by `MediaService` once a working backend is found. Nil means the
    /// transport buttons are inert and should render disabled.
    var mediaCommandHandler: ((MediaCommand) -> Void)?

    var canControlMedia: Bool { mediaCommandHandler != nil }

    func send(_ command: MediaCommand) {
        mediaCommandHandler?(command)
    }

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    // MARK: - Layout

    /// Horizontal room given to content on each side of the housing while peeked.
    /// Each flank = outer edge inset + content + a gap before the housing, so the
    /// content is padded on BOTH sides rather than pressed against the curve.
    ///   resting media peek: 10 inset + 24 artwork + 6 gap
    ///   HUD peek:           10 inset + glyph + text/ring + 6 gap
    private let peekFlank: CGFloat = PeekContentView.edgeInset + 50
    private let mediaIdleFlank: CGFloat = PeekContentView.edgeInset + 30

    /// How much taller than the notch the floating capsule sits, so it reads as a
    /// distinct object rather than a widened notch.
    private let floatingLift: CGFloat = 6
    /// The merged style grows a few points below the housing when it peeks
    /// (Alcove: 179×32 → 192×37), so the peek is visibly *something* and not just a
    /// wider notch.
    private let mergedLift: CGFloat = 4

    var style: IslandStyle { preferences.islandStyle }

    /// Gap between the top edge of the screen and the island.
    ///
    /// A display with a real notch can never have one: the camera housing is flush
    /// with the top edge, so any gap would leave the housing's own square silhouette
    /// poking up above the rounded pill. On a display without a notch there is
    /// nothing up there, so the island genuinely floats.
    var topInset: CGFloat {
        guard style == .floating else { return 0 }
        if preferences.detachFromTopEdge { return 8 }
        // No notch means nothing can peek out above the capsule, so float it anyway.
        return metrics.hasPhysicalNotch ? 0 : 6
    }

    /// How far the silhouette spills past its own frame horizontally — non-zero only
    /// for the merged style's concave shoulders.
    var horizontalOverhang: CGFloat {
        style.horizontalOverhang(topRadius: topCornerRadius)
    }

    var expandedSize: CGSize {
        // Fixed height: the player and the idle state are laid out to the same box, so
        // the island never jumps size when a track starts or stops. Matches the
        // Alcove reference (~345×175 on a 14" MacBook Pro).
        // A deeper housing (16" vs 14") pushes the text down, so the panel grows by
        // the same amount instead of squeezing the controls.
        if usesSplitLayout {
            // Two compact columns (~190 pt each) with the housing straddling the
            // middle — only ~95 pt wider than the plain player. The side gutters
            // still leave room for the 56 pt artwork left and the date right.
            // Same height as the plain player.
            return CGSize(
                width: max(440, metrics.notchSize.width + 255),
                height: 176 + max(0, metrics.notchSize.height - 32)
            )
        }
        return CGSize(
            width: max(345, metrics.notchSize.width + 165),
            height: 176
                + max(0, metrics.notchSize.height - 32)
                + (showsCalendarStrip ? UpNextView.reservedHeight : 0)
        )
    }

    var notificationSize: CGSize {
        // Everything in the card sits *below* the housing: notch strip + title +
        // two lines of body + bottom padding. The old fixed 74 pt could not fit two
        // body lines, and the centred content then crept up under the camera.
        CGSize(
            width: max(340, metrics.notchSize.width + 150),
            height: metrics.notchSize.height + 64
        )
    }

    /// The island's target size for the current presentation. The view animates
    /// toward this with a spring; the window itself never changes size.
    var contentSize: CGSize {
        var size = baseContentSize
        if isHoverLifted {
            size.width += hoverLift.width
            size.height += hoverLift.height
        }
        return size
    }

    private var baseContentSize: CGSize {
        switch presentation {
        case .collapsed:
            return metrics.notchSize
        case .peek:
            // The resting mini player is deliberately narrower than a HUD: it is on
            // screen for the whole album, so it has to stay unobtrusive.
            let flank = hud == nil ? mediaIdleFlank : peekFlank
            return CGSize(
                width: metrics.notchSize.width + flank * 2,
                height: metrics.notchSize.height
                    + (style == .floating ? floatingLift : mergedLift)
                    // A HUD drops a caption line *below* the housing, like the
                    // iPhone does when a track changes, instead of cramming text
                    // into the narrow strip beside the camera.
                    + (hud?.hasCaption == true ? Self.hudCaptionHeight : 0)
            )
        case .notification:
            return notificationSize
        case .expanded:
            return expandedSize
        }
    }

    /// Corner radii. The floating style is a true capsule while it is small and
    /// relaxes into a squircle once it is a full panel — a 150 pt tall capsule would
    /// look like a pill, not a window.
    var topCornerRadius: CGFloat {
        switch style {
        case .notchMerged:
            // For the merged style this is the *flare* radius, not a corner radius.
            // It grows with the island: a tiny shoulder on the housing, a generous
            // sweep on the panel. A fixed 8 pt flare on a 345 pt panel looks like a
            // square box glued under the notch — the flare is what makes it look
            // like the bezel itself is stretching down.
            switch presentation {
            case .collapsed: return metrics.topCornerRadius
            case .peek: return 9
            case .notification: return 14
            case .expanded: return 16
            }
        case .floating:
            // Square top whenever the island is flush against the top edge. Rounding
            // corners that touch the bezel makes the shape read as a separate window
            // floating *over* the screen rather than as part of the hardware, which is
            // exactly the "detached" feeling we are avoiding. Only round the top when
            // the island has genuinely been lifted clear of the edge.
            guard topInset > 0 else { return 0 }
            switch presentation {
            case .collapsed, .peek: return contentSize.height / 2
            case .notification: return 22
            case .expanded: return 26
            }
        }
    }

    /// Bottom corners tighten when collapsed and open up when expanded — small
    /// detail, but it is most of why the growth reads as "fluid" rather than "scaled".
    var bottomCornerRadius: CGFloat {
        switch style {
        case .floating:
            // Measured against Alcove on real notched hardware: the radius grows with
            // the island rather than tracking its height. Using height/2 turns the
            // small states into full pills, which is what makes a notch overlay look
            // like a floating widget instead of part of the machine.
            //   collapsed 179×32 → ~10    hover 192×37 → ~11    panel → ~34
            switch presentation {
            case .collapsed: return metrics.bottomCornerRadius
            case .peek: return hud?.hasCaption == true ? 20 : 15
            case .notification: return 26
            case .expanded: return 38
            }
        case .notchMerged:
            switch presentation {
            case .collapsed: return metrics.bottomCornerRadius
            case .peek: return hud?.hasCaption == true ? 20 : 15
            case .notification: return 26
            case .expanded: return 36
            }
        }
    }

    var isOpen: Bool { presentation != .collapsed }

    /// Height of the caption line a HUD adds under the housing.
    static let hudCaptionHeight: CGFloat = 26

    /// Height of the strip level with the camera (art · housing · bars) while
    /// peeking — the island's height minus any HUD caption below it.
    var peekStripHeight: CGFloat {
        contentSize.height - (presentation == .peek && hud?.hasCaption == true ? Self.hudCaptionHeight : 0)
    }

    /// The Up Next row is shown whenever there is an event coming up. When the
    /// calendar is empty, "nothing on your calendar" is only worth the space when
    /// nothing else is going on either — no track loaded — otherwise the panel
    /// stays compact and the row is simply left out.
    /// Music and calendar always sit side by side when both are on. Needs calendar
    /// access — without it the right half would be empty, so the player shows alone.
    var usesSplitLayout: Bool {
        preferences.panelLayout == .sideBySide
            && preferences.nowPlayingEnabled
            && preferences.calendarEnabled
            && calendarAccess == .granted
    }

    /// The single Up Next row is only used when music is switched off entirely;
    /// with music on, the calendar lives in the right half of the split panel.
    var showsCalendarStrip: Bool {
        guard preferences.calendarEnabled, !preferences.nowPlayingEnabled else { return false }
        if upcomingEvents.contains(where: { $0.end > Date() }) { return true }
        let hasTrack = !(nowPlaying?.isEmpty ?? true) && preferences.nowPlayingEnabled
        return !hasTrack && calendarAccess != .unknown
    }

    /// While something is actually playing the island rests one step open, with
    /// artwork on one side of the housing and the visualiser on the other.
    var showsRestingMediaPeek: Bool {
        preferences.nowPlayingEnabled && (nowPlaying?.isPlaying ?? false)
    }

    /// On a real notch the collapsed state must stay *perfectly* black and sized to
    /// the housing; on a faked notch we are free to show a hairline so the user can
    /// find it.
    var drawsVirtualNotch: Bool { !metrics.hasPhysicalNotch }

    // MARK: - Presentation state machine

    private func recomputePresentation() {
        let next: Presentation
        if isPinned || isClickOpened || (isHovering && preferences.expandOnHover) {
            next = .expanded
        } else if currentNotification != nil {
            next = .notification
        } else if hud != nil {
            next = .peek
        } else if showsRestingMediaPeek {
            next = .peek
        } else {
            next = .collapsed
        }

        // Only a closed island lifts; an open panel or a card is already "big".
        let lift = isHovering && (next == .collapsed || next == .peek)

        let presentationChanged = next != presentation
        guard presentationChanged || lift != isHoverLifted else { return }

        // Haptics only fire while a finger is on a Force Touch trackpad, so this is
        // a no-op for mouse users and never needs a permission.
        let haptics = NSHapticFeedbackManager.defaultPerformer

        if presentationChanged {
            motion = Self.rank(next) > Self.rank(presentation) ? .open : .close
            if next == .expanded { haptics.perform(.levelChange, performanceTime: .now) }
            isHoverLifted = lift
            presentation = next
            updateTicker()
        } else {
            motion = lift ? .hoverIn : .hoverOut
            if lift { haptics.perform(.alignment, performanceTime: .now) }
            isHoverLifted = lift
        }
    }

    /// A click on the closed island. Opens it; it closes again when the pointer
    /// leaves. (Use the pin, the menu bar item or isle://expand to keep it open.)
    func openFromClick() {
        guard presentation != .expanded else { return }
        hoverWorkItem?.cancel()
        isClickOpened = true
        // The click itself proves the pointer is here, even if the hover debounce
        // has not caught up yet.
        if !isHovering {
            isHovering = true          // didSet recomputes
        } else {
            recomputePresentation()
        }
    }

    private static func rank(_ presentation: Presentation) -> Int {
        switch presentation {
        case .collapsed: return 0
        case .peek: return 1
        case .notification: return 2
        case .expanded: return 3
        }
    }

    // MARK: - Hover

    /// Debounced so that merely sweeping the pointer across the top of the screen on
    /// the way to a menu bar item does not fling the island open.
    func setHoverTarget(_ hovering: Bool) {
        hoverWorkItem?.cancel()

        if hovering == isHovering { return }

        // Hover-to-open keeps the user's debounce so sweeping past the notch on the
        // way to a menu doesn't fling it open. The lift is harmless, so it reacts
        // almost instantly — that immediacy is what makes it feel alive.
        let enterDelay = preferences.expandOnHover ? preferences.hoverDelay : 0.04
        let delay = hovering ? enterDelay : 0.12
        let work = DispatchWorkItem { [weak self] in
            self?.isHovering = hovering
        }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func togglePin() {
        setPinned(!isPinned)
    }

    func setPinned(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        isPinned = pinned
        recomputePresentation()
    }

    func collapseNow() {
        hoverWorkItem?.cancel()
        isPinned = false
        isClickOpened = false
        isHovering = false
        recomputePresentation()
    }

    // MARK: - HUD events

    /// Show a transient peek. Later events replace earlier ones — an island only has
    /// one slot, and the newest event is always the interesting one.
    func present(hud event: HUDEvent, duration: Double? = nil) {
        hudDismissal?.cancel()
        // The caption makes the island grow even when it was already peeking, so
        // tell the view to use the "open" springs for it.
        motion = .open
        hud = event
        recomputePresentation()

        let window = duration ?? preferences.hudDuration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hud?.id == event.id else { return }
            self.motion = .close
            self.hud = nil
            self.recomputePresentation()
        }
        hudDismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + window, execute: work)
    }

    func dismissHUD() {
        hudDismissal?.cancel()
        motion = .close
        hud = nil
        recomputePresentation()
    }

    // MARK: - Notification cards

    func enqueue(_ notification: NotchNotification, force: Bool = false) {
        guard force || preferences.notificationsEnabled else { return }
        pendingNotifications.append(notification)
        if currentNotification == nil { showNextNotification() }
    }

    private func showNextNotification() {
        notificationDismissal?.cancel()

        guard !pendingNotifications.isEmpty else {
            currentNotification = nil
            recomputePresentation()
            return
        }

        let next = pendingNotifications.removeFirst()
        currentNotification = next
        recomputePresentation()

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.currentNotification?.id == next.id else { return }
            self.showNextNotification()
        }
        notificationDismissal = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + preferences.notificationDuration,
            execute: work
        )
    }

    /// Called by the swipe-to-dismiss gesture and by taps on the card.
    func dismissCurrentNotification() {
        notificationDismissal?.cancel()
        currentNotification = nil
        showNextNotification()
    }

    // MARK: - Playhead ticker

    private func updateTicker() {
        let needsTicker = isOpen && nowPlaying?.isPlaying == true
        if needsTicker, ticker == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick = Date() }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        } else if !needsTicker {
            ticker?.invalidate()
            ticker = nil
        }
    }

    /// Services call this after mutating `nowPlaying` so the ticker can start/stop.
    func nowPlayingDidChange() {
        updateTicker()
    }
}
