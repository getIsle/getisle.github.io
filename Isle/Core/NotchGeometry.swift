//
//  NotchGeometry.swift
//  Isle
//
//  Everything Isle needs to know about the physical shape of the display it is
//  drawing on. On a notched MacBook we read the real dimensions out of AppKit;
//  on everything else we synthesise a "virtual notch" of the same proportions so
//  the app behaves identically on an external monitor or a MacBook Air M1.
//

import AppKit

/// Resolved description of the black pill Isle anchors to the top of a screen.
struct NotchMetrics: Equatable {

    /// `true` when the screen actually has a hardware notch (HUD renders *around*
    /// the camera housing); `false` when we are faking one.
    var hasPhysicalNotch: Bool

    /// Size of the collapsed pill, in points.
    var notchSize: CGSize

    /// Full frame of the screen we are anchored to, in global (bottom-left origin)
    /// coordinates.
    var screenFrame: CGRect

    /// Radius of the *concave* flare where the pill meets the top bezel. This is
    /// what sells the "it is part of the hardware" illusion — a plain rounded rect
    /// reads as a floating widget, an inverted corner reads as a notch.
    var topCornerRadius: CGFloat

    /// Radius of the convex bottom corners of the pill.
    var bottomCornerRadius: CGFloat

    /// Screens change (clamshell, display hot-plug, resolution switch), so we keep
    /// the identity of the screen we measured around for change detection.
    var screenIdentifier: String

    static let fallback = NotchMetrics(
        hasPhysicalNotch: false,
        notchSize: CGSize(width: 200, height: 32),
        screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        topCornerRadius: 8,
        bottomCornerRadius: 12,
        screenIdentifier: "fallback"
    )
}

enum NotchGeometry {

    /// Dimensions used when we have to draw a notch that isn't there. Chosen to
    /// match the 14"/16" MacBook Pro housing closely enough that the animations
    /// feel the same on an external display.
    static let virtualNotchSize = CGSize(width: 200, height: 32)

    /// The screen Isle should live on: the one with the menu bar if it has a notch,
    /// otherwise whichever screen currently owns the menu bar.
    static func preferredScreen() -> NSScreen? {
        // A notched built-in display always wins — that is the whole point of the app.
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    static func metrics(for screen: NSScreen) -> NotchMetrics {
        let identifier = screenIdentifier(for: screen)

        // `safeAreaInsets.top > 0` is the documented signal for "content would be
        // occluded by the camera housing", i.e. this display has a notch.
        let topInset = screen.safeAreaInsets.top

        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // The two auxiliary areas are the usable menu-bar strips either side of
            // the housing. Whatever is left in the middle *is* the notch.
            let width = screen.frame.width - left.width - right.width
            if width > 20 {
                return NotchMetrics(
                    hasPhysicalNotch: true,
                    notchSize: CGSize(width: width, height: topInset),
                    screenFrame: screen.frame,
                    topCornerRadius: 8,
                    bottomCornerRadius: 12,
                    screenIdentifier: identifier
                )
            }
        }

        // No notch (external display, Air, clamshell): draw a virtual one that is
        // never taller than the menu bar so it reads as part of the chrome.
        let menuBarHeight = max(24, NSStatusBar.system.thickness)
        return NotchMetrics(
            hasPhysicalNotch: false,
            notchSize: CGSize(width: virtualNotchSize.width, height: menuBarHeight),
            screenFrame: screen.frame,
            topCornerRadius: 8,
            bottomCornerRadius: 12,
            screenIdentifier: identifier
        )
    }

    private static func screenIdentifier(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber
        return "\(number?.intValue ?? 0)-\(Int(screen.frame.width))x\(Int(screen.frame.height))"
    }
}
