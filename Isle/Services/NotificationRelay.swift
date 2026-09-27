//
//  NotificationRelay.swift
//  Isle
//
//  ── PLATFORM LIMITATION, STATED PLAINLY ──────────────────────────────────────
//  Isle cannot show *other apps'* notification banners.
//
//  There is no public API for it, and there is no usable private one either:
//    • `UNUserNotificationCenter` only ever reports notifications your own bundle
//      posted. `getDeliveredNotifications` is scoped to the calling app.
//    • The legacy `NSUserNotificationCenter` is deprecated and equally app-scoped.
//    • The banners themselves are composited by `NotificationCenter.app` in another
//      process; the payloads live in a SQLite store under DARWIN_USER_DIR that is
//      protected by TCC, and reading it requires Full Disk Access *and* still gives
//      you no reliable "a banner is on screen right now" signal.
//    • Accessibility (AXUIElement) can scrape the banner window of
//      `NotificationCenter.app`, which is what a couple of shipping apps do. It needs
//      the user to grant Accessibility, it breaks on most macOS point releases, and
//      it is explicitly outside what Isle does.
//
//  Every Dynamic-Island-style Mac app hits this same wall. What we implement instead
//  is everything that genuinely *is* possible:
//
//    1. Isle's own local notifications (UNUserNotificationCenter) are intercepted
//       before the system banner draws and rendered in the notch instead.
//    2. A public, documented ingress other software can post to:
//         • URL scheme:              isle://notify?title=…&body=…
//         • Distributed notification: "com.isle.Isle.notify"
//       Anything that can run `open(1)` or talk to NSDistributedNotificationCenter —
//       a shell script, a Shortcut, a CI hook, another Swift app — can put a card in
//       the notch. It cannot mirror Messages or Mail for you.
//  ─────────────────────────────────────────────────────────────────────────────
//

import AppKit
import SwiftUI
import UserNotifications
import os

@MainActor
final class NotificationRelay: NSObject {

    /// The distributed notification name third parties post to.
    static let distributedNotificationName = Notification.Name("com.isle.Isle.notify")

    private let log = Logger(subsystem: "com.isle.Isle", category: "NotificationRelay")
    private weak var viewModel: NotchViewModel?
    private let preferences: Preferences

    private var didRequestAuthorization = false

    init(viewModel: NotchViewModel, preferences: Preferences) {
        self.viewModel = viewModel
        self.preferences = preferences
        super.init()
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleDistributedNotification(_:)),
            name: Self.distributedNotificationName,
            object: nil,
            // Without this, macOS coalesces/defers notifications for background apps
            // and cards arrive seconds late or not at all.
            suspensionBehavior: .deliverImmediately
        )

        UNUserNotificationCenter.current().delegate = self
        requestAuthorizationIfNeeded()
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                // Unsigned / oddly-signed builds can fail here; it only affects Isle's
                // own notifications, not the URL or distributed-notification ingress.
                Logger(subsystem: "com.isle.Isle", category: "NotificationRelay")
                    .error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Logger(subsystem: "com.isle.Isle", category: "NotificationRelay")
                    .info("Notification authorization granted: \(granted, privacy: .public)")
            }
        }
    }

    // MARK: - Ingress 1: URL scheme

    /// Supported URLs — the scriptable surface of Isle:
    ///
    ///   isle://notify?title=…&body=…&app=…&symbol=…&accent=%23FF8800&image=/path.png
    ///   isle://hud?title=…&subtitle=…&symbol=…&progress=0.6&accent=%23FF8800
    ///   isle://expand        — pin the island open
    ///   isle://collapse      — unpin and close it
    ///   isle://toggle        — flip between the two
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "isle" else { return }

        // `isle://notify?x=1` parses host as "notify"; `isle:notify?x=1` parses it as
        // a path. Accept both so callers do not have to care.
        let action = (url.host?.lowercased())
            ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var values: [String: String] = [:]
        for item in items { values[item.name.lowercased()] = item.value }

        switch action {
        case "notify", "notification":
            present(
                title: values["title"] ?? "Notification",
                body: values["body"] ?? values["message"] ?? "",
                appName: values["app"],
                symbol: values["symbol"] ?? values["icon"],
                accentHex: values["accent"],
                imagePath: values["image"]
            )

        case "hud", "peek":
            presentHUD(values)

        case "expand":
            viewModel?.setPinned(true)

        case "collapse":
            viewModel?.collapseNow()

        case "toggle":
            viewModel?.togglePin()

        case "demo":
            // Populates every widget with sample data so the island can be seen (and
            // screenshotted) without media playing or AirPods paired. Clear it again
            // with isle://demo?clear=1.
            presentDemo(clear: values["clear"] != nil)

        default:
            log.debug("Ignoring unsupported isle:// URL \(url.absoluteString, privacy: .public)")
        }
    }

    private func presentDemo(clear: Bool) {
        guard let viewModel else { return }
        if clear {
            viewModel.nowPlaying = nil
            viewModel.audioDevices = []
            viewModel.nowPlayingDidChange()
            viewModel.collapseNow()
            return
        }

        viewModel.nowPlaying = DemoContent.sampleTrack()
        viewModel.audioDevices = [DemoContent.sampleDevice()]
        if viewModel.battery == nil { viewModel.battery = DemoContent.sampleBattery() }
        viewModel.focus = FocusStatus(
            isActive: true,
            modeIdentifier: "com.apple.donotdisturb.mode.work",
            name: "Work"
        )
        viewModel.nowPlayingDidChange()
    }

    private func presentHUD(_ values: [String: String]) {
        let accent = values["accent"].flatMap { Color(hex: $0) } ?? preferences.accentColor
        var image: NSImage?
        if let path = values["image"], !path.isEmpty {
            image = NSImage(contentsOfFile: (path as NSString).expandingTildeInPath)
        }

        let event = HUDEvent(
            kind: .generic,
            symbolName: values["symbol"] ?? values["icon"] ?? "sparkles",
            title: values["title"] ?? "",
            subtitle: values["subtitle"],
            progress: values["progress"].flatMap(Double.init),
            tint: accent,
            image: image
        )
        viewModel?.present(hud: event, duration: values["duration"].flatMap(Double.init))
    }

    // MARK: - Ingress 2: distributed notification

    @objc private func handleDistributedNotification(_ notification: Notification) {
        // Cross-process userInfo is property-list only, so everything arrives as strings.
        let info = notification.userInfo as? [String: Any] ?? [:]
        func string(_ key: String) -> String? { info[key] as? String }

        present(
            title: string("title") ?? "Notification",
            body: string("body") ?? string("message") ?? "",
            appName: string("app"),
            symbol: string("symbol") ?? string("icon"),
            accentHex: string("accent"),
            imagePath: string("image")
        )
    }

    // MARK: - Ingress 3: our own local notifications

    /// Post a real local notification through the system. `userNotificationCenter(_:willPresent:)`
    /// below catches it on the way out and draws it in the notch instead of a banner.
    func postLocalNotification(title: String, body: String, identifier: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [log] error in
            if let error {
                log.error("Failed to post local notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Rendering

    private func present(
        title: String,
        body: String,
        appName: String?,
        symbol: String?,
        accentHex: String?,
        imagePath: String?
    ) {
        var image: NSImage?
        if let imagePath, !imagePath.isEmpty {
            image = NSImage(contentsOfFile: (imagePath as NSString).expandingTildeInPath)
        }

        let accent = accentHex.flatMap { Color(hex: $0) } ?? preferences.accentColor

        let card = NotchNotification(
            title: title,
            body: body,
            appName: appName,
            symbolName: symbol?.isEmpty == false ? symbol! : "bell.fill",
            image: image,
            accent: accent
        )

        log.info("Presenting notch card: \(title, privacy: .public)")
        viewModel?.enqueue(card)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationRelay: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        let title = content.title
        let body = content.body

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.present(
                title: title.isEmpty ? "Isle" : title,
                body: body,
                appName: "Isle",
                symbol: "bell.fill",
                accentHex: nil,
                imagePath: nil
            )
        }

        // Returning no options suppresses the system banner — the notch *is* the banner.
        completionHandler([])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
