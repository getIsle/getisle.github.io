//
//  IsleApp.swift
//  Isle
//
//  Isle is an LSUIElement (agent) app: no Dock tile, no main menu. The SwiftUI
//  `App` here exists almost entirely to own the `Settings` scene — everything the
//  user actually sees is an AppKit overlay window driven from `AppDelegate`.
//

import SwiftUI

@main
struct IsleApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Standard settings scene: gives us ⌘, handling and the system-styled window.
        // The menu bar extra opens it via `SettingsOpener`, which falls back to a
        // hand-built window on the OS versions where the private action selector for
        // this scene has been renamed.
        Settings {
            SettingsView()
                .environmentObject(Preferences.shared)
        }
    }
}
