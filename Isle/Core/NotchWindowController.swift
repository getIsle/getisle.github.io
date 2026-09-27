//
//  NotchWindowController.swift
//  Isle
//
//  Owns the overlay window: places it on the right screen, keeps it there when the
//  display configuration changes, translates raw pointer movement into hover state,
//  and keeps the window's hit region in sync with what is actually drawn.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchWindowController {

    let viewModel: NotchViewModel

    private let preferences: Preferences
    private var window: NotchWindow?
    private var hostingView: NotchHostingView<NotchRootView>?

    /// True while the island's display is showing a full-screen app (or Split View).
    private var isHiddenForFullScreen = false
    private var fullScreenPoll: Timer?

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    /// Extra slop around the island so the hover target is forgiving — without it,
    /// a 32 pt tall strip is genuinely hard to keep the pointer inside.
    ///
    /// `top` matters more than it looks: with the pointer shoved against the top
    /// of the screen, `NSEvent.mouseLocation.y` is *exactly* the screen's maxY, and
    /// `CGRect.contains` excludes its max edge — so without extending the region
    /// past the top, the most natural gesture (flick the pointer up to the notch)
    /// was never detected.
    private let hoverPadding = NSEdgeInsets(top: 8, left: 14, bottom: 10, right: 14)

    /// Same idea for clicks: the hit region reaches a little past the window top.
    private let hitTopOverreach: CGFloat = 4

    init(viewModel: NotchViewModel, preferences: Preferences) {
        self.viewModel = viewModel
        self.preferences = preferences
    }

    // MARK: - Lifecycle

    func start() {
        rebuildWindow()
        installMouseMonitors()

        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
        .sink { [weak self] _ in self?.rebuildWindow() }
        .store(in: &cancellables)

        // Waking from sleep can leave the panel behind a full-screen app's shield.
        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didWakeNotification
        )
        .sink { [weak self] _ in
            guard let self, !self.isHiddenForFullScreen else { return }
            self.window?.orderFrontRegardless()
        }
        .store(in: &cancellables)

        installFullScreenWatch()

        // Any change in what we draw changes where clicks should land.
        viewModel.objectWillChange
            .merge(with: preferences.objectWillChange)   // style / widget changes resize it
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateHitRegion() }
            .store(in: &cancellables)
    }

    // MARK: - Full screen

    /// Entering or leaving full screen switches Space, so the Space notification is
    /// the main trigger. It fires as the transition *starts*, so re-check once the
    /// animation has settled; a slow poll catches anything that slips through.
    private func installFullScreenWatch() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            workspace.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    // The Space notification arrives as the slide *starts*; check
                    // now, then twice more as the transition settles.
                    self?.updateFullScreenState()
                    for delay in [0.25, 0.7] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            self?.updateFullScreenState()
                        }
                    }
                }
                .store(in: &cancellables)
        }

        preferences.$hideInFullScreen
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateFullScreenState() }
            .store(in: &cancellables)

        let poll = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateFullScreenState() }
        }
        RunLoop.main.add(poll, forMode: .common)
        fullScreenPoll = poll

        updateFullScreenState()
    }

    private func updateFullScreenState() {
        guard let window, let screen = NotchGeometry.preferredScreen() else { return }
        let shouldHide = preferences.hideInFullScreen && FullScreenDetector.isFullScreen(on: screen)
        guard shouldHide != isHiddenForFullScreen else { return }
        isHiddenForFullScreen = shouldHide

        if shouldHide {
            // Close anything open so it doesn't reappear mid-state on the way out,
            // then let SwiftUI fold the island into the notch. The window is only
            // ordered out once that animation has finished, so nothing pops.
            viewModel.collapseNow()
            viewModel.setHoverTarget(false)
            viewModel.isSuppressed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self, weak window] in
                guard let self, self.isHiddenForFullScreen else { return }
                window?.orderOut(nil)
            }
        } else {
            window.alphaValue = 1
            window.orderFrontRegardless()
            // Start the unfold on the next frame, once the window is on screen,
            // so the whole spring is visible rather than its tail end.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self, !self.isHiddenForFullScreen else { return }
                self.viewModel.isSuppressed = false
            }
        }
    }

    func stop() {
        fullScreenPoll?.invalidate()
        fullScreenPoll = nil
        isHiddenForFullScreen = false
        viewModel.isSuppressed = false
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        window?.orderOut(nil)
        window = nil
    }

    // MARK: - Window construction

    /// The window is a fixed canvas; only the island inside it animates. Size it once
    /// for the widest thing we will ever draw, plus room for the concave flares.
    private func canvasSize(for metrics: NotchMetrics) -> CGSize {
        let width = max(760, metrics.notchSize.width + 420)
        return CGSize(width: width, height: 340)
    }

    private func rebuildWindow() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let metrics = NotchGeometry.metrics(for: screen)

        // On a screen with no notch the user may not want a fake one at all.
        if !metrics.hasPhysicalNotch && !preferences.showVirtualNotchOnExternalDisplays {
            window?.orderOut(nil)
            window = nil
            hostingView = nil
            return
        }

        viewModel.metrics = metrics

        let canvas = canvasSize(for: metrics)
        let frame = NSRect(
            x: metrics.screenFrame.midX - canvas.width / 2,
            y: metrics.screenFrame.maxY - canvas.height,
            width: canvas.width,
            height: canvas.height
        )

        if let window, let hostingView {
            window.setFrame(frame, display: true)
            hostingView.frame = NSRect(origin: .zero, size: canvas)
            updateHitRegion()
            if !isHiddenForFullScreen { window.orderFrontRegardless() }
            return
        }

        let window = NotchWindow(contentRect: frame)
        let root = NotchRootView(viewModel: viewModel, preferences: preferences)
        let hosting = NotchHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: canvas)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting

        self.window = window
        self.hostingView = hosting

        updateHitRegion()
        window.orderFrontRegardless()
    }

    // MARK: - Hit region

    /// The island's rect inside the window, in window (bottom-left origin) coordinates.
    private func islandWindowRect(padded: Bool) -> CGRect {
        guard let window else { return .zero }
        let size = viewModel.contentSize
        let flare = viewModel.horizontalOverhang
        let inset = viewModel.topInset

        var rect = CGRect(
            x: window.frame.width / 2 - size.width / 2 - flare,
            y: window.frame.height - size.height - inset,
            width: size.width + flare * 2,
            height: size.height + inset
        )

        if padded {
            rect.origin.x -= hoverPadding.left
            rect.size.width += hoverPadding.left + hoverPadding.right
            rect.origin.y -= hoverPadding.bottom
            rect.size.height += hoverPadding.bottom + hoverPadding.top
        }
        return rect
    }

    private func updateHitRegion() {
        var rect = islandWindowRect(padded: false)
        rect.size.height += hitTopOverreach      // include the very top pixel row
        hostingView?.hitRegion.windowRect = rect
    }

    // MARK: - Hover tracking

    /// Hover is driven by raw mouse-moved events rather than an `NSTrackingArea`.
    ///
    /// A tracking area only fires for a view that can be hit-tested, and this view
    /// deliberately refuses hit-testing outside the island — which would make
    /// `mouseEntered` unreachable for the collapsed pill. Global + local monitors
    /// sidestep the circularity. (Mouse-moved monitoring needs no Accessibility
    /// permission; only keyboard event monitoring does.)
    private func installMouseMonitors() {
        let matching: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .mouseExited]

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: matching) { [weak self] _ in
            Task { @MainActor in self?.evaluateHover() }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: matching) { [weak self] event in
            Task { @MainActor in self?.evaluateHover() }
            return event
        }
    }

    private func evaluateHover() {
        guard let window, !isHiddenForFullScreen else { return }
        let mouse = NSEvent.mouseLocation                     // global screen coordinates
        let regionInWindow = islandWindowRect(padded: true)
        let regionOnScreen = regionInWindow.offsetBy(
            dx: window.frame.origin.x,
            dy: window.frame.origin.y
        )
        viewModel.setHoverTarget(regionOnScreen.contains(mouse))
    }
}
