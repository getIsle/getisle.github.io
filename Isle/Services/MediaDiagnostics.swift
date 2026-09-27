//
//  MediaDiagnostics.swift
//  Isle
//
//  Surfaces *why* Now Playing is empty. Without this the app just silently shows
//  "Nothing playing" while the user is very obviously playing something, and there is
//  no way to tell a missing permission from an unsupported player.
//

import AppKit
import Combine
import Foundation

@MainActor
final class MediaDiagnostics: ObservableObject {

    static let shared = MediaDiagnostics()

    enum Issue: Equatable {
        /// The user has not granted Isle permission to control this app.
        case automationDenied(app: String)
        /// Safari/Chrome will not run `do JavaScript` until the user opts in.
        case browserJavaScriptDisabled(app: String)
        /// MediaRemote loaded but returned nothing — normal on macOS 15.4+.
        case mediaRemoteRestricted

        var message: String {
            switch self {
            case .automationDenied(let app):
                return "Isle needs permission to control \(app)."
            case .browserJavaScriptDisabled(let app):
                return "\(app) will not answer until “Allow JavaScript from Apple Events” is on."
            case .mediaRemoteRestricted:
                return "MediaRemote returned no data, so Isle is using Apple Events instead."
            }
        }

        var fix: String? {
            switch self {
            case .automationDenied:
                return "Open System Settings ▸ Privacy & Security ▸ Automation and enable the app under Isle."
            case .browserJavaScriptDisabled(let app):
                if app.contains("Chrome") {
                    return "In Chrome: View ▸ Developer ▸ Allow JavaScript from Apple Events."
                }
                return "In Safari: Settings ▸ Advanced ▸ tick “Show features for web developers”, then Develop ▸ Allow JavaScript from Apple Events."
            case .mediaRemoteRestricted:
                return nil
            }
        }

        var isBlocking: Bool {
            switch self {
            case .mediaRemoteRestricted: return false
            case .automationDenied, .browserJavaScriptDisabled: return true
            }
        }
    }

    /// Name of the backend currently supplying data.
    @Published var activeSourceName: String = "—"

    /// Issues seen since the last successful read, newest first, de-duplicated.
    @Published private(set) var issues: [Issue] = []

    /// True once any backend has handed us a real track.
    @Published var hasData = false

    func record(_ issue: Issue) {
        guard !issues.contains(issue) else { return }
        issues.insert(issue, at: 0)
        if issues.count > 4 { issues.removeLast() }
    }

    func clearIssues() {
        guard !issues.isEmpty else { return }
        issues.removeAll()
    }

    /// Opens the Automation pane, which is where every Apple Events problem is fixed.
    static func openAutomationSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        )
        if let url { NSWorkspace.shared.open(url) }
    }
}
