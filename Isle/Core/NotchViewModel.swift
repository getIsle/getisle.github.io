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
    enum Motion: Equatable { case open, close, hoverIn, hoverOut, drip }
    @Published private(set) var motion: Motion = .open

    var isGrowing: Bool { motion == .open || motion == .hoverIn }

    /// Pointer is over a closed island: it swells slightly to say "click me".
    /// Measured off Alcove: 179×32 → 192×37 on a 14" MacBook Pro.
    @Published private(set) var isHoverLifted = false
    private let hoverLift = CGSize(width: 14, height: 5)
    @Published private(set) var currentNotification: NotchNotification? {
        didSet {
            guard currentNotification == nil else { return }
            dripIsDown = false
            dripWidth = 0
            dripTextVisible = false
            dripIsClosing = false
        }
    }

    /// The notification's text hangs from the island as a drop: `dripIsDown` stretches
    /// it down as a bead, `dripWidth` opens it, then `dripTextVisible` shows the line.
    @Published private(set) var dripIsDown = false
    @Published private(set) var dripWidth: CGFloat = 0
    @Published private(set) var dripTextVisible = false
    private var dripIsClosing = false
    private static let dripHeight: CGFloat = NotchShape.dropHeight + 10
    private static let dripBead: CGFloat = 20
    private static let dripMaxWidth: CGFloat = 340

    /// The liquid split's bubble, while one is out (see LiquidBud.swift).
    /// `budDetached` false means it is inside the island: just budding, or pulled
    /// back in.
    @Published private(set) var bud: LiquidBud?
    @Published private(set) var budDetached = false
    /// The camera strip's height when the drop set out. Fixed for its whole trip:
    /// the island may grow into a card meanwhile, and the drop must not grow with it.
    @Published private(set) var budStripHeight: CGFloat = 0
    /// How much the closed island swells around the camera for a drop to leave it.
    /// A notch-sized island has too little mass to give up: the drop would be small,
    /// and easy to miss.
    @Published private(set) var budSwell: CGSize = .zero
    private static let swellToSplit = CGSize(width: 44, height: 8)
    static let swellWhileApart = CGSize(width: 12, height: 6)

    /// Progress-bar ticker. Only runs while the island is visibly showing progress,
    /// so a paused, collapsed island costs nothing.
    @Published private(set) var tick: Date = .init()

    private var pendingNotifications: [NotchNotification] = []
    private var hudDismissal: DispatchWorkItem?
    private var notificationDismissal: DispatchWorkItem?
    private var hoverWorkItem: DispatchWorkItem?

    /// What the island shows once the bubble is reabsorbed. Held back so the drop
    /// visibly carries the event in, instead of the island growing alongside it.
    private var pendingArrival: (() -> Void)?
    private var budWork: [DispatchWorkItem] = []
    private var isNotificationArriving = false
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

    /// The island itself stays slim, just around the camera. The frame is only wider to
    /// hold the text drop hanging below it.
    var notificationSize: CGSize {
        CGSize(
            width: max(notificationStripWidth, dripTargetWidth),
            height: notificationStripHeight + (dripIsDown ? Self.dripHeight : 0)
        )
    }

    var notificationStripWidth: CGFloat { metrics.notchSize.width + Self.swellWhileApart.width }

    var notificationStripHeight: CGFloat {
        metrics.notchSize.height + (style == .floating ? floatingLift : mergedLift)
    }

    /// The one line of text, measured, so the drop opens to fit it.
    private var dripTargetWidth: CGFloat {
        guard let notification = currentNotification else { return 0 }
        let title = (notification.title as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
        ).width
        let body = (notification.body as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 12)]
        ).width
        return min(Self.dripMaxWidth, ceil(title + body) + 6 + 30)
    }

    /// The island's target size for the current presentation. The view animates
    /// toward this with a spring; the window itself never changes size.
    var contentSize: CGSize {
        var size = baseContentSize
        if isHoverLifted {
            size.width += hoverLift.width
            size.height += hoverLift.height
        }
        if presentation == .collapsed || presentation == .peek {
            size.width += budSwell.width
            size.height += budSwell.height
        }
        return size
    }

    private var baseContentSize: CGSize {
        switch presentation {
        case .collapsed:
            return metrics.notchSize
        case .peek:
            // On screen for the whole album, so it has to stay unobtrusive.
            return CGSize(
                width: metrics.notchSize.width + mediaIdleFlank * 2,
                height: metrics.notchSize.height
                    + (style == .floating ? floatingLift : mergedLift)
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
            case .notification: return 9
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
            case .peek: return 15
            case .notification: return 15
            case .expanded: return 38
            }
        case .notchMerged:
            switch presentation {
            case .collapsed: return metrics.bottomCornerRadius
            case .peek: return 15
            case .notification: return 15
            case .expanded: return 36
            }
        }
    }

    var isOpen: Bool { presentation != .collapsed }

    /// Height of the strip level with the camera (art · housing · bars) while peeking.
    var peekStripHeight: CGFloat { contentSize.height }

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

    // MARK: - Events

    /// Something happened: shown the same way as every other notification.
    func present(hud event: HUDEvent, duration: Double? = nil) {
        enqueue(
            NotchNotification(
                title: event.title,
                body: event.subtitle ?? "",
                symbolName: event.symbolName,
                image: event.image,
                accent: event.tint,
                duration: duration ?? preferences.hudDuration,
                isTrackChange: event.kind == .nowPlaying
            ),
            force: true
        )
    }

    // MARK: - Notification cards

    func enqueue(_ notification: NotchNotification, force: Bool = false) {
        guard force || preferences.notificationsEnabled else { return }
        if notification.isTrackChange {
            pendingNotifications.removeAll { $0.isTrackChange }
        }
        pendingNotifications.append(notification)
        // One already on its way in will pick the queue up when it is done.
        guard currentNotification == nil, !isNotificationArriving else { return }
        bringNextNotification()
    }

    /// The next in the queue arrives on a drop from the island's side.
    private func bringNextNotification() {
        guard let upcoming = pendingNotifications.first else { return }
        isNotificationArriving = true
        arrive(carrying: LiquidBud(notification: upcoming)) { [weak self] in
            self?.isNotificationArriving = false
            self?.showNextNotification()
        }
    }

    // MARK: - Liquid split

    /// Whether the island is in a state where budding makes sense: closed or
    /// resting, on screen, and nobody asked for less motion.
    private var canBud: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && !isSuppressed
            && (presentation == .collapsed || presentation == .peek)
    }

    /// The island swells, and a drop leaves its side carrying the icon. The drop stays
    /// out as the notification's only icon; `apply` runs once it has settled.
    private func arrive(carrying newBud: LiquidBud, apply: @escaping () -> Void) {
        guard canBud else {
            apply()
            return
        }

        budWork.forEach { $0.cancel() }
        budWork.removeAll()

        budDetached = false
        budStripHeight = peekStripHeight + Self.swellToSplit.height
        pendingArrival = apply

        // First the island swells, so there is mass to give up. Then the drop leaves,
        // and the island shrinks back as it does, because the drop took that mass.
        setSwell(Self.swellToSplit, motion: .open)
        let swellTime = 0.38
        // Only now: the hidden drop is taller than the unswollen island, and would
        // show beneath it.
        schedule(after: swellTime - 0.06) { [weak self] in self?.bud = newBud }
        schedule(after: swellTime) { [weak self] in self?.budDetached = true }
        schedule(after: swellTime + 0.15) { [weak self] in
            self?.setSwell(Self.swellWhileApart, motion: .close)
        }
        schedule(after: swellTime + LiquidBudLayer.splitDuration + 0.1) { [weak self] in
            guard let self else { return }
            let apply = self.pendingArrival
            self.pendingArrival = nil
            apply?()
            self.budSwell = .zero
        }
    }

    /// Height of the island while the drop is apart from it, for the drop to fit.
    var budJoinHeight: CGFloat { budStripHeight - Self.swellToSplit.height + Self.swellWhileApart.height }

    private func setSwell(_ swell: CGSize, motion newMotion: Motion) {
        motion = newMotion
        budSwell = swell
    }

    private func mergeBud() {
        guard bud != nil else { return }
        budDetached = false
        schedule(after: LiquidBudLayer.mergeDuration + 0.05) { [weak self] in
            guard let self, !self.budDetached else { return }
            self.bud = nil
        }
    }

    private func schedule(after delay: Double, _ block: @escaping () -> Void) {
        let work = DispatchWorkItem(block: block)
        budWork.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func showNextNotification() {
        notificationDismissal?.cancel()

        guard !pendingNotifications.isEmpty else {
            currentNotification = nil
            recomputePresentation()
            return
        }

        // Another is waiting: this one has closed, and the next arrives like the first.
        if currentNotification != nil {
            currentNotification = nil
            recomputePresentation()
            bringNextNotification()
            return
        }

        let next = pendingNotifications.removeFirst()
        currentNotification = next
        dripWidth = Self.dripBead
        recomputePresentation()
        openDrip(for: next.id)

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.currentNotification?.id == next.id else { return }
            self.closeDrip(for: next.id) { [weak self] in self?.showNextNotification() }
        }
        notificationDismissal = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (next.duration ?? preferences.notificationDuration) + 1.3,
            execute: work
        )
    }

    /// A bead falls and breaks free, then opens sideways, then the text surfaces in it.
    private func openDrip(for id: NotchNotification.ID) {
        afterDelay(0.3, for: id) { [weak self] in
            guard let self, !self.dripIsClosing else { return }
            self.motion = .drip
            self.dripIsDown = true
        }
        afterDelay(1.13, for: id) { [weak self] in
            guard let self, !self.dripIsClosing else { return }
            self.dripWidth = self.dripTargetWidth
        }
        afterDelay(1.28, for: id) { [weak self] in
            guard let self, !self.dripIsClosing else { return }
            self.dripTextVisible = true
        }
    }

    /// One thing at a time: the icon flows home, then the text fades, and its drop
    /// narrows to a bead and rises back. Only then may the island shrink.
    private func closeDrip(for id: NotchNotification.ID, then finish: @escaping () -> Void) {
        guard !dripIsClosing else { return }
        dripIsClosing = true
        let iconTime = bud == nil ? 0 : LiquidBudLayer.mergeDuration * 0.75
        mergeBud()
        afterDelay(iconTime, for: id) { [weak self] in self?.dripTextVisible = false }
        afterDelay(iconTime + 0.2, for: id) { [weak self] in self?.dripWidth = Self.dripBead }
        afterDelay(iconTime + 0.5, for: id) { [weak self] in
            self?.motion = .drip
            self?.dripIsDown = false
        }
        afterDelay(iconTime + 1.3, for: id) { [weak self] in
            // At once, not animated: the bead is already inside the strip, and a
            // shrinking one would show as a nub if the island changes height.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { self?.dripWidth = 0 }
        }
        afterDelay(iconTime + 1.45, for: id, finish)
    }

    /// Runs only if the same notification is still showing: a swipe can end it early.
    private func afterDelay(_ delay: Double, for id: NotchNotification.ID, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard self?.currentNotification?.id == id else { return }
            block()
        }
    }

    /// Called by the swipe-to-dismiss gesture and by taps on the card.
    func dismissCurrentNotification() {
        notificationDismissal?.cancel()
        guard let current = currentNotification else {
            showNextNotification()
            return
        }
        // The same careful order as when it times out, so the icon has gone before the
        // island shrinks. No side drop afterwards: it was dismissed by hand.
        closeDrip(for: current.id) { [weak self] in
            guard let self else { return }
            if self.pendingNotifications.isEmpty {
                self.currentNotification = nil
                self.recomputePresentation()
            } else {
                self.showNextNotification()
            }
        }
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
