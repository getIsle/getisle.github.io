//
//  NotchWindow.swift
//  Isle
//
//  The overlay surface itself.
//
//  Two non-obvious decisions live here:
//
//  1. It is an `NSPanel` with `.nonactivatingPanel`, not a plain `NSWindow`.
//     Clicking the island must not steal focus from whatever the user is typing in.
//
//  2. The window never resizes. It is a fixed, oversized, fully transparent canvas
//     pinned to the top of the screen, and the island grows *inside* it. Animating an
//     `NSWindow.setFrame` at 120 Hz is jerky and fights SwiftUI's own animation; a
//     static window with a springy SwiftUI subview is glassy smooth. The cost is that
//     the window covers a chunk of the menu bar, which is what `NotchHostingView`'s
//     hit-testing below exists to undo.
//

import AppKit
import SwiftUI

final class NotchWindow: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        // Above the menu bar, so an expanded island is not clipped by it, but below
        // the shielding level used by screen savers / security dialogs.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)

        // Visible on every Space and over full-screen apps, and never captured by
        // Mission Control or window cycling.
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]

        // Keep the island out of screenshots/screen recordings? Deliberately NOT set:
        // people screen-record this app to show it off. Flip to `.none` to hide it.
        sharingType = .readOnly
    }

    /// Needed so buttons and text fields inside the island work, but paired with
    /// `.nonactivatingPanel` it takes key *without* activating Isle as the front app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Hit region

/// Shared mutable box describing the only part of the window that should swallow
/// mouse events, in window coordinates. Updated by `NotchWindowController` whenever
/// the presentation changes.
final class NotchHitRegion {
    var windowRect: CGRect = .zero
}

/// Hosting view that is transparent to the mouse everywhere except the island.
///
/// Without this, a 720×320 always-on-top window would eat clicks across the middle
/// of the menu bar and the top of whatever app is frontmost.
final class NotchHostingView<Content: View>: NSHostingView<Content> {

    let hitRegion = NotchHitRegion()

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("NotchHostingView is not archivable")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the *superview's* coordinate space; window coordinates
        // are the one space both we and the controller can agree on unambiguously
        // (NSHostingView is flipped, the window's frame view is not).
        let windowPoint = superview?.convert(point, to: nil) ?? point
        guard hitRegion.windowRect.contains(windowPoint) else { return nil }
        return super.hitTest(point)
    }

    /// Lets the first click on the island press a button, rather than being consumed
    /// just to bring the panel forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
