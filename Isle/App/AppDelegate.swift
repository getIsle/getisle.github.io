//
//  AppDelegate.swift
//  Isle
//
//  Wires the object graph together and owns app-level lifecycle.
//

import AppKit
import Combine
import SwiftUI
import UserNotifications
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let log = Logger(subsystem: "com.isle.Isle", category: "App")

    let preferences = Preferences.shared
    lazy var viewModel = NotchViewModel(preferences: preferences)
    lazy var windowController = NotchWindowController(
        viewModel: viewModel,
        preferences: preferences
    )
    lazy var services = ServiceCoordinator(
        viewModel: viewModel,
        preferences: preferences
    )

    private var menuBarController: MenuBarController?
    private var onboarding: OnboardingController?
    private var servicesStarted = false
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces: LSUIElement already does this, but setting it explicitly
        // means a debug build launched straight from the binary behaves the same.
        NSApp.setActivationPolicy(.accessory)

        windowController.start()

        menuBarController = MenuBarController(
            preferences: preferences,
            viewModel: viewModel,
            onShowSettings: { SettingsOpener.open() },
            onShowWelcome: { [weak self] in self?.showOnboarding() }
        )

        // First launch: walk through the welcome flow before anything asks for a
        // permission, so the prompts arrive one at a time with an explanation
        // instead of all at once on a blank screen. The services start when it ends.
        if preferences.onboardingCompleted {
            startServices()
        } else {
            showOnboarding()
        }

        // Rebuild the overlay if the user turns the virtual notch on or off.
        preferences.$showVirtualNotchOnExternalDisplays
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.windowController.stop()
                self?.windowController.start()
            }
            .store(in: &cancellables)

        // "Welcome Guide…" in Settings ▸ About.
        NotificationCenter.default.publisher(for: .isleShowWelcomeGuide)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.showOnboarding() }
            .store(in: &cancellables)

        log.info("Isle launched")
    }

    private func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true
        services.start()
        // Start with the Mac from now on (first run from /Applications only).
        preferences.enableLaunchAtLoginOnFirstInstall()
    }

    private func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingController(preferences: preferences) { [weak self] in
                guard let self else { return }
                let firstRun = !self.servicesStarted
                self.startServices()
                self.onboarding = nil
                if firstRun {
                    // Say hello from the notch itself, so the user sees where to look.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        self.viewModel.present(
                            hud: HUDEvent(
                                kind: .generic,
                                symbolName: "sparkles",
                                title: "Isle is ready",
                                subtitle: "Hover the notch",
                                progress: nil,
                                tint: .white,
                                image: nil
                            ),
                            duration: 4
                        )
                    }
                }
            }
        }
        onboarding?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        services.stop()
        windowController.stop()
    }

    /// Opening the app again (double-clicking it in Finder) should surface Settings,
    /// since there is no window to bring forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let onboarding, onboarding.isVisible {
            onboarding.show()
            return true
        }
        SettingsOpener.open()
        return true
    }

    // MARK: - URL scheme

    /// `isle://notify?title=…&body=…` — see `NotificationRelay` for the full grammar.
    /// This is one of the two public entry points other software can use to put a
    /// card in the notch (the other is a distributed notification).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            services.notificationRelay.handle(url: url)
        }
    }
}

// MARK: - Settings window

/// Isle's own settings window. Always hand-built: the SwiftUI `Settings` scene
/// can only be opened through a private action selector that menu-bar-only apps
/// can't rely on (it silently does nothing on recent macOS), which is exactly the
/// "Settings does nothing" bug this replaces.
@MainActor
enum SettingsOpener {

    private static var window: NSWindow?

    static func open() {
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView().environmentObject(Preferences.shared)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Isle Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 760, height: 540))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
