//
//  OnboardingModel.swift
//  Isle
//
//  State and actions behind the onboarding screens: which step is showing,
//  installing into /Applications, and asking for each permission at the moment
//  the user taps its button (instead of a pile of prompts at launch).
//

import AppKit
import EventKit
import Intents
import SwiftUI
import UserNotifications

@MainActor
final class OnboardingModel: ObservableObject {

    enum Step: Int, CaseIterable {
        case welcome, install, permissions, setup, done
    }

    enum PermissionState: Equatable {
        case unknown, notAsked, granted, denied, unavailable
    }

    enum InstallState: Equatable {
        case notInstalled, installing, installed, failed(String)
    }

    @Published private(set) var step: Step
    /// +1 moving forward, -1 moving back — picks the slide direction.
    @Published private(set) var direction: Int = 1

    @Published var install: InstallState
    @Published var calendar: PermissionState = .unknown
    @Published var notifications: PermissionState = .unknown
    @Published var focus: PermissionState = .unknown
    @Published var nowPlaying: PermissionState = .unknown

    var onFinish: (() -> Void)?

    /// Set just before this copy quits to hand over to the one in /Applications,
    /// so closing this window is not mistaken for "onboarding finished".
    static private(set) var isHandingOver = false

    private let preferences: Preferences

    init(preferences: Preferences) {
        self.preferences = preferences
        let installed = Self.isInstalled
        install = installed ? .installed : .notInstalled

        // Resume after the relaunch that "Move to Applications" performs.
        var resume = Step(rawValue: preferences.onboardingResumeStep) ?? .welcome
        if resume == .install, installed { resume = .permissions }
        step = resume

        refreshPermissions()
    }

    // MARK: Navigation

    /// The install step is skipped entirely when Isle already lives in Applications.
    var steps: [Step] {
        Step.allCases.filter { $0 != .install || install != .installed || step == .install }
    }

    var stepIndex: Int { steps.firstIndex(of: step) ?? 0 }

    var canGoBack: Bool { step != .welcome && step != .done }

    func next() {
        guard let index = steps.firstIndex(of: step) else { return }
        if index + 1 < steps.count {
            go(to: steps[index + 1], direction: 1)
        } else {
            onFinish?()
        }
    }

    func back() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        go(to: steps[index - 1], direction: -1)
    }

    private func go(to newStep: Step, direction: Int) {
        self.direction = direction
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            step = newStep
        }
        preferences.onboardingResumeStep = newStep.rawValue
        if newStep == .permissions { refreshPermissions() }
    }

    // MARK: Install

    static var isInstalled: Bool { InstallGuard.isInApplications }

    /// Copies this build into Applications (replacing an older copy, which goes to
    /// the Trash so nothing is lost), launches the new copy and quits this one.
    /// The new copy picks the flow up at the next step.
    func moveToApplications() {
        install = .installing

        let destination: URL
        do {
            destination = try InstallGuard.copyIntoApplications()
        } catch {
            install = .failed(error.localizedDescription)
            return
        }

        preferences.onboardingResumeStep = Step.permissions.rawValue
        Self.isHandingOver = true

        InstallGuard.relaunch(from: destination) { [weak self] error in
            Self.isHandingOver = false
            self?.install = .failed(error.localizedDescription)
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    // MARK: Permissions

    func refreshPermissions() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: calendar = .granted
        case .notDetermined: calendar = .notAsked
        default: calendar = .denied
        }

        switch INFocusStatusCenter.default.authorizationStatus {
        case .authorized: focus = .granted
        case .notDetermined: focus = .notAsked
        default: focus = .denied
        }

        nowPlaying = MediaRemoteHelperSource.locateSwift() != nil ? .granted : .unavailable

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state: PermissionState
            switch settings.authorizationStatus {
            case .authorized, .provisional: state = .granted
            case .notDetermined: state = .notAsked
            default: state = .denied
            }
            Task { @MainActor in self.notifications = state }
        }
    }

    /// How many macOS permission pop-ups "Allow All" would bring up.
    var pendingCount: Int {
        [calendar, notifications, focus].filter { $0 == .notAsked }.count
    }

    @Published private(set) var isAllowingAll = false

    /// One button for people who just want it to work: asks for every permission
    /// that hasn't been asked yet, strictly one after another so the macOS dialogs
    /// never pile up on top of each other.
    func allowAll() {
        guard !isAllowingAll else { return }
        isAllowingAll = true
        Task {
            if calendar == .notAsked {
                let granted = (try? await eventStore.requestFullAccessToEvents()) ?? false
                calendar = granted ? .granted : .denied
            }
            if notifications == .notAsked {
                let granted = (try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])) ?? false
                notifications = granted ? .granted : .denied
            }
            if focus == .notAsked {
                let status = await withCheckedContinuation { continuation in
                    INFocusStatusCenter.default.requestAuthorization { continuation.resume(returning: $0) }
                }
                focus = status == .authorized ? .granted : .denied
            }
            isAllowingAll = false
        }
    }

    private let eventStore = EKEventStore()

    func requestCalendar() {
        Task {
            let granted = (try? await eventStore.requestFullAccessToEvents()) ?? false
            calendar = granted ? .granted : .denied
        }
    }

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.notifications = granted ? .granted : .denied }
        }
    }

    func requestFocus() {
        INFocusStatusCenter.default.requestAuthorization { status in
            Task { @MainActor in self.focus = status == .authorized ? .granted : .denied }
        }
    }

    /// Opens Apple's own "Install Command Line Tools" dialog. That is what gives
    /// Isle the `swift` it needs to read Now Playing from every app.
    func installDeveloperTools() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        try? process.run()

        // Apple's installer takes a few minutes and never tells us it finished,
        // so look for the tools every few seconds and tick the row when they land.
        installingTools = true
        toolsPoll?.invalidate()
        toolsPoll = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkDeveloperTools() }
        }
    }

    @Published private(set) var installingTools = false
    private var toolsPoll: Timer?

    private func checkDeveloperTools() {
        guard MediaRemoteHelperSource.locateSwift() != nil else { return }
        nowPlaying = .granted
        installingTools = false
        toolsPoll?.invalidate()
        toolsPoll = nil
    }

    func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
