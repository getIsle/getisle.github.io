//
//  FullScreenDetector.swift
//  Isle
//
//  "Is the display the island lives on currently showing a full-screen app?"
//
//  There is no public API for this. Two answers, best first:
//
//  1. Ask the window server which Space is current on that display and whether it
//     is a full-screen Space (type 4). This is exact — it catches full-screen apps,
//     full-screen browser video and Split View, and never mistakes a merely
//     *maximised* window for full screen. It uses SkyLight's CGS calls, resolved
//     with dlsym like MediaRemote, so if a macOS release removes them we simply
//     fall through to (2) instead of crashing.
//
//  2. Fallback heuristic: the frontmost app owns a normal-level window covering the
//     entire display. On a notched Mac a full-screen window stops below the camera
//     strip, which is exactly where a zoomed window stops too, so this is only used
//     when (1) is unavailable.
//

import AppKit
import CoreGraphics

enum FullScreenDetector {

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let skyLight: (MainConnectionFn, CopyManagedDisplaySpacesFn)? = {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY),
              let main = dlsym(handle, "CGSMainConnectionID"),
              let copy = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return nil }
        return (
            unsafeBitCast(main, to: MainConnectionFn.self),
            unsafeBitCast(copy, to: CopyManagedDisplaySpacesFn.self)
        )
    }()

    /// Space type the window server uses for a full-screen (or Split View) Space.
    private static let fullScreenSpaceType = 4

    static func isFullScreen(on screen: NSScreen) -> Bool {
        if let answer = spaceTypeAnswer(for: screen) { return answer }
        return windowBoundsHeuristic(for: screen)
    }

    // MARK: 1. Space type

    private static func spaceTypeAnswer(for screen: NSScreen) -> Bool? {
        guard let skyLight,
              let displays = skyLight.1(skyLight.0())?.takeRetainedValue() as? [[String: Any]],
              !displays.isEmpty else { return nil }

        let uuid = displayUUID(for: screen)

        // With "Displays have separate Spaces" off there is a single entry named
        // "Main"; otherwise one entry per display, keyed by the display's UUID.
        let entry = displays.first { ($0["Display Identifier"] as? String) == uuid }
            ?? (displays.count == 1 ? displays.first : nil)
            ?? displays.first { ($0["Display Identifier"] as? String) == "Main" }

        guard let current = entry?["Current Space"] as? [String: Any],
              let type = current["type"] as? Int else { return nil }
        return type == fullScreenSpaceType
    }

    private static func displayUUID(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else {
            return nil
        }
        guard let string = CFUUIDCreateString(nil, uuid) else { return nil }
        return string as String
    }

    // MARK: 2. Window-bounds heuristic

    private static func windowBoundsHeuristic(for screen: NSScreen) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier,
              let windows = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else { return false }

        // CG window bounds are top-left-origin, relative to the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let frame = screen.frame
        let screenInCG = CGRect(
            x: frame.minX,
            y: primaryHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )

        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? Int) == Int(front.processIdentifier),
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return false }
            return abs(bounds.minX - screenInCG.minX) < 1
                && abs(bounds.width - screenInCG.width) < 1
                && abs(bounds.minY - screenInCG.minY) < 1
                && abs(bounds.height - screenInCG.height) < 1
        }
    }
}
