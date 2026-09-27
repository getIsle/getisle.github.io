//
//  OnboardingController.swift
//  Isle
//
//  First-launch flow. Owns the window, remembers which step the user reached
//  (so "Move to Applications", which relaunches the app, resumes where it left
//  off) and tells AppDelegate when the user is done.
//

import AppKit
import SwiftUI

@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {

    private let preferences: Preferences
    private let onFinish: () -> Void
    private var window: NSWindow?

    init(preferences: Preferences, onFinish: @escaping () -> Void) {
        self.preferences = preferences
        self.onFinish = onFinish
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = OnboardingModel(preferences: preferences)
        model.onFinish = { [weak self] in self?.finish() }

        let root = OnboardingView(model: model)
            .environmentObject(preferences)
            .preferredColorScheme(.dark)

        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        // Transparent window so the glass backdrop can show the desktop through it.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Closing the window with the red button counts as "done" — the user
    /// clearly wants to get on with it, and every choice has a sane default.
    func windowWillClose(_ notification: Notification) {
        completeIfNeeded()
        window = nil
    }

    private func finish() {
        completeIfNeeded()
        window?.close()
    }

    private var didComplete = false

    private func completeIfNeeded() {
        guard !didComplete, !OnboardingModel.isHandingOver else { return }
        didComplete = true
        preferences.onboardingCompleted = true
        preferences.onboardingResumeStep = 0
        onFinish()
    }
}
