//
//  InstallGuard.swift
//  Isle
//
//  Keeps exactly one Isle running and makes updating painless:
//
//  • Opening a copy of Isle while another one is already running hands over to
//    whichever is newer, so you never get two islands fighting over the notch
//    and "I installed the update but nothing changed" can't happen.
//  • Opening a downloaded copy (from the disk image or Downloads) when Isle is
//    already set up offers to put it in Applications, replacing the old one.
//    Settings live in UserDefaults under the bundle identifier, so they carry over.
//

import AppKit

/// A bundle's marketing version plus build number, compared numerically
/// ("1.10" is newer than "1.9").
struct AppVersion: Comparable, CustomStringConvertible {
    let short: String
    let build: String

    init(bundle: Bundle?) {
        short = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        build = bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Reads Info.plist straight off disk. `Bundle(url:)` caches per path, which
    /// would hide an update that was copied over the top of a running app.
    init(url: URL?) {
        let plist = url.flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) }
        short = plist?["CFBundleShortVersionString"] as? String ?? "0"
        build = plist?["CFBundleVersion"] as? String ?? "0"
    }

    static var current: AppVersion { AppVersion(bundle: .main) }

    var description: String { short }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let byShort = lhs.short.compare(rhs.short, options: .numeric)
        if byShort != .orderedSame { return byShort == .orderedAscending }
        return lhs.build.compare(rhs.build, options: .numeric) == .orderedAscending
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.short.compare(rhs.short, options: .numeric) == .orderedSame
            && lhs.build.compare(rhs.build, options: .numeric) == .orderedSame
    }
}

@MainActor
enum InstallGuard {

    private static let dontAskKey = "install.dontAskToMove"

    // MARK: One Isle at a time

    /// Call first thing at launch. Returns `false` when a newer copy is already
    /// running: that one is brought forward and this copy should quit.
    /// Otherwise older (or identical) copies are asked to quit and this one carries on.
    static func takeOverFromOtherCopies() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return true }
        let me = NSRunningApplication.current.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return true }

        let mine = AppVersion.current
        if let newer = others.first(where: { AppVersion(url: $0.bundleURL) > mine }) {
            newer.activate()
            return false
        }

        // The copy the user just opened wins: quit the rest, forcefully if they hang.
        others.forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        }
        return true
    }

    /// True when someone dragged a different version over this app while it was
    /// running. Opening it then only reactivates this old process, so the caller
    /// should relaunch to actually start the new version.
    static var wasReplacedOnDisk: Bool {
        let onDisk = AppVersion(url: Bundle.main.bundleURL)
        return onDisk.short != "0" && onDisk != AppVersion.current
    }

    // MARK: Where this copy lives

    static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Builds run from Xcode should never be nagged about moving.
    static var isDevelopmentBuild: Bool {
        let path = Bundle.main.bundleURL.path
        return path.contains("/DerivedData/") || path.contains("/Build/Products/")
    }

    /// Where an installed copy lives (or should live). Prefers an existing copy in
    /// ~/Applications so an update replaces it in place.
    static var installURL: URL {
        let userCopy = URL(fileURLWithPath: NSHomeDirectory() + "/Applications/Isle.app")
        if FileManager.default.fileExists(atPath: userCopy.path) { return userCopy }
        return URL(fileURLWithPath: "/Applications/Isle.app")
    }

    // MARK: Install / update

    /// Copies this build into Applications, sending any older copy to the Trash so
    /// nothing is lost. Returns where it went.
    @discardableResult
    static func copyIntoApplications() throws -> URL {
        let fm = FileManager.default
        let destination = installURL
        if fm.fileExists(atPath: destination.path) {
            try fm.trashItem(at: destination, resultingItemURL: nil)
        }
        try fm.copyItem(at: Bundle.main.bundleURL, to: destination)
        return destination
    }

    /// Opens the copy at `url` and quits this one once it is running.
    static func relaunch(from url: URL, onError: @escaping @MainActor (Error) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error { onError(error) } else { NSApp.terminate(nil) }
            }
        }
    }

    /// For people who already finished the welcome guide and then open a new
    /// download: offer to put this copy in Applications in one click.
    static func offerToInstallIfNeeded() {
        guard !isInApplications, !isDevelopmentBuild,
              !UserDefaults.standard.bool(forKey: dontAskKey) else { return }

        let fm = FileManager.default
        let target = installURL
        let installed = fm.fileExists(atPath: target.path) ? AppVersion(url: target) : nil
        let mine = AppVersion.current

        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"

        if let installed, installed > mine {
            // An older download was opened by mistake: point at the newer one.
            alert.messageText = "You already have a newer Isle"
            alert.informativeText = "This copy is version \(mine). The one in Applications is version \(installed)."
            alert.addButton(withTitle: "Open the Newer One")
            alert.addButton(withTitle: "Keep This One")
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            remember(alert)
            if response == .alertFirstButtonReturn {
                relaunch(from: target) { _ in }
            }
            return
        }

        if let installed {
            alert.messageText = installed == mine
                ? "Replace the Isle in Applications?"
                : "Update Isle to version \(mine)?"
            alert.informativeText = installed == mine
                ? "You opened Isle from outside Applications. Replace the copy there so Isle keeps starting by itself when you log in. Your settings stay as they are."
                : "Your Applications folder has version \(installed). Isle will replace it, keep your settings, and reopen. The old copy goes to the Trash."
            alert.addButton(withTitle: installed == mine ? "Replace and Reopen" : "Update")
        } else {
            alert.messageText = "Move Isle to Applications?"
            alert.informativeText = "Isle needs to live in Applications to start by itself when you log in. Your settings stay as they are."
            alert.addButton(withTitle: "Move and Reopen")
        }
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        remember(alert)
        guard response == .alertFirstButtonReturn else { return }

        do {
            let destination = try copyIntoApplications()
            relaunch(from: destination) { error in showFailure(error) }
        } catch {
            showFailure(error)
        }
    }

    private static func remember(_ alert: NSAlert) {
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: dontAskKey)
        }
    }

    private static func showFailure(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Couldn’t move Isle automatically"
        alert.informativeText = "Drag Isle into your Applications folder yourself, then open it from there.\n\n\(error.localizedDescription)"
        alert.addButton(withTitle: "Show Isle in Finder")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }
}
