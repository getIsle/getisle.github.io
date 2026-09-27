//
//  MenuBarController.swift
//  Isle
//
//  The only chrome an LSUIElement app gets. Without it there is literally no way to
//  quit Isle short of Activity Monitor.
//

import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let preferences: Preferences
    private let viewModel: NotchViewModel

    private let onShowSettings: () -> Void
    private let onShowWelcome: () -> Void

    init(
        preferences: Preferences,
        viewModel: NotchViewModel,
        onShowSettings: @escaping () -> Void,
        onShowWelcome: @escaping () -> Void
    ) {
        self.preferences = preferences
        self.viewModel = viewModel
        self.onShowSettings = onShowSettings
        self.onShowWelcome = onShowWelcome
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        if let button = statusItem.button {
            button.image = Self.islandGlyph()
            button.toolTip = "Isle"
        }

        // The menu is rebuilt every time it opens (menuNeedsUpdate), so the track,
        // the next event and every checkmark are always current.
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    /// A tiny version of the app icon: a soft pill with a round "album art" dot on the
    /// left and three bouncy sound bars on the right, both punched out of the pill.
    /// Drawn in code rather than shipped as a PNG so it stays crisp at every scale, and
    /// marked as a template so macOS tints it for light, dark and highlighted menu bars.
    static func islandGlyph() -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { _ in
            let pill = NSRect(x: 1.5, y: 3.5, width: 21, height: 11)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 5.5, yRadius: 5.5).fill()

            // Everything below is cut out of the pill.
            NSGraphicsContext.current?.compositingOperation = .destinationOut

            NSBezierPath(ovalIn: NSRect(x: 4, y: 6, width: 6, height: 6)).fill()

            let bars: [CGFloat] = [3.5, 6, 4]
            for (i, height) in bars.enumerated() {
                let x = 13.5 + CGFloat(i) * 2.6
                let bar = NSRect(x: x, y: pill.midY - height / 2, width: 1.6, height: height)
                NSBezierPath(roundedRect: bar, xRadius: 0.8, yRadius: 0.8).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Isle"
        return image
    }

    deinit {
        // `statusItem` is captured, so hop to the main actor to tear it down.
        let item = statusItem
        Task { @MainActor in NSStatusBar.system.removeStatusItem(item) }
    }

    // MARK: - Building the menu

    /// Deliberately tiny — music, calendar and the rest already live in the notch,
    /// and every option lives in Settings:
    ///
    ///     Keep Island Open
    ///     ─────────────
    ///     Settings…            ⌘,     (hold ⌥ → Welcome Guide…)
    ///     Quit Isle            ⌘Q
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.add(title: "Keep Island Open", action: #selector(togglePinned), target: self)
            .state = viewModel.isPinned ? .on : .off

        menu.addItem(.separator())

        menu.add(title: "Settings…", action: #selector(showSettings), target: self, key: ",")
        // Hold Option while the menu is open to swap Settings for the Welcome Guide.
        let welcome = menu.add(title: "Welcome Guide…", action: #selector(showWelcome), target: self, key: ",")
        welcome.keyEquivalentModifierMask = [.command, .option]
        welcome.isAlternate = true

        menu.addItem(.separator())

        menu.add(title: "Quit Isle", action: #selector(quit), target: self, key: "q")
    }

    // MARK: - Actions

    @objc private func togglePinned() { viewModel.setPinned(!viewModel.isPinned) }
    @objc private func showSettings() { onShowSettings() }
    @objc private func showWelcome() { onShowWelcome() }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

}

private extension NSMenuItem {
    convenience init(title: String, action: Selector?, target: AnyObject) {
        self.init(title: title, action: action, keyEquivalent: "")
        self.target = target
    }
}

private extension NSMenu {
    /// Small convenience so each menu line is one readable statement. Deliberately
    /// not named `addItem(withTitle:…)` — that would overload AppKit's own method and
    /// make every call site ambiguous.
    @discardableResult
    func add(
        title: String,
        action: Selector,
        target: AnyObject,
        key: String = "",
        symbol: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        addItem(item)
        return item
    }
}
