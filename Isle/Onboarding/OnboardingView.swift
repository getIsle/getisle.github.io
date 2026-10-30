//
//  OnboardingView.swift
//  Isle
//
//  Welcome → Move to Applications → Permissions → Quick setup → Ready.
//  Dark, calm, one idea per screen, with a live miniature of the island so the
//  user sees what they are setting up before they touch the real notch.
//

import SwiftUI

struct OnboardingView: View {

    @ObservedObject var model: OnboardingModel
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        ZStack {
            OnboardingBackground()

            VStack(spacing: 0) {
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 48)
                    .padding(.top, 44)

                footer
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }
        }
        .frame(width: 620, height: 500)
    }

    // MARK: Pages

    @ViewBuilder
    private var page: some View {
        ZStack {
            switch model.step {
            case .welcome: WelcomePage().transition(slide)
            case .install: InstallPage(model: model).transition(slide)
            case .permissions: PermissionsPage(model: model).transition(slide)
            case .setup: SetupPage().transition(slide)
            case .done: DonePage().transition(slide)
            }
        }
    }

    private var slide: AnyTransition {
        let forward = model.direction >= 0
        return .asymmetric(
            insertion: .offset(x: forward ? 60 : -60).combined(with: .opacity),
            removal: .offset(x: forward ? -60 : 60).combined(with: .opacity)
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 7) {
                ForEach(Array(model.steps.enumerated()), id: \.offset) { index, _ in
                    Capsule()
                        .fill(Color.white.opacity(index == model.stepIndex ? 0.9 : 0.2))
                        .frame(width: index == model.stepIndex ? 18 : 6, height: 6)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.stepIndex)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .liquidGlass(in: Capsule())

            Spacer()

            // Grouped so the two buttons' glass blends as one material and
            // morphs smoothly when "Back" appears or disappears.
            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    if model.canGoBack {
                        Button("Back") { model.back() }
                            .glassSecondaryButton()
                            .transition(.opacity)
                    }

                    Button(primaryTitle) { model.next() }
                        .glassPrimaryButton()
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.install == .installing)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.canGoBack)
    }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: return "Get Started"
        case .install: return model.install == .installed ? "Continue" : "Skip for Now"
        case .permissions, .setup: return "Continue"
        case .done: return "Start Using Isle"
        }
    }
}

// MARK: - Welcome

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 92, height: 92)
                .shadow(color: .black.opacity(0.5), radius: 16, y: 8)

            VStack(spacing: 8) {
                Text("Welcome to Isle")
                    .font(.system(size: 30, weight: .bold))
                Text("Your notch, brought to life. Music, calendar, battery and alerts —\nright where your camera already is.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            IslandDemo()
                .padding(.top, 8)
        }
    }
}

// MARK: - Install

private struct InstallPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 20) {
            PageHeader(
                symbol: "arrow.down.app.fill",
                tint: .blue,
                title: "Move Isle to Applications",
                subtitle: "Isle needs to live in your Applications folder to start by itself when you log in."
            )

            Group {
                switch model.install {
                case .notInstalled:
                    Button {
                        model.moveToApplications()
                    } label: {
                        Label("Move to Applications", systemImage: "folder.fill")
                    }
                    .glassPrimaryButton(large: true)

                    Text("Isle will reopen from Applications and carry on from here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))

                case .installing:
                    ProgressView().controlSize(.small)
                    Text("Moving…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))

                case .installed:
                    Label("Isle is in Applications", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.green)

                case .failed(let message):
                    VStack(spacing: 10) {
                        Label("Couldn't move it automatically", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                            .multilineTextAlignment(.center)
                        Button("Show Isle in Finder") { model.revealInFinder() }
                            .glassSecondaryButton()
                        Text("Drag it into the Applications folder, then open it from there.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: model.install)
        }
    }
}

// MARK: - Permissions

private struct PermissionsPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 14) {
            PageHeader(
                symbol: "hand.raised.fill",
                tint: .purple,
                title: "A few permissions",
                subtitle: "Each one switches on a part of the island. Skip any you don't want — the rest keeps working. Nothing ever leaves your Mac."
            )

            VStack(spacing: 0) {
                PermissionRow(
                    symbol: "calendar", tint: .red,
                    title: "Calendar",
                    detail: "Up Next and meeting reminders",
                    state: model.calendar,
                    request: model.requestCalendar,
                    openSettings: { model.openPrivacySettings("Privacy_Calendars") }
                )
                Divider().overlay(Color.white.opacity(0.06))
                PermissionRow(
                    symbol: "bell.badge.fill", tint: .orange,
                    title: "Notifications",
                    detail: "Isle's own alerts in the notch",
                    state: model.notifications,
                    request: model.requestNotifications,
                    openSettings: { model.openPrivacySettings("Privacy_Notifications") }
                )
                Divider().overlay(Color.white.opacity(0.06))
                PermissionRow(
                    symbol: "moon.fill", tint: .indigo,
                    title: "Focus",
                    detail: "Show when a Focus is on",
                    state: model.focus,
                    request: model.requestFocus,
                    openSettings: { model.openPrivacySettings("Privacy_Focus") }
                )
                Divider().overlay(Color.white.opacity(0.06))
                PermissionRow(
                    symbol: "music.note", tint: .pink,
                    title: "Now Playing in every app",
                    detail: model.nowPlaying == .granted
                        ? "Ready — Spotify, Music, browsers, and more"
                        : model.installingTools
                            ? "Installing… a few minutes. This ticks itself when done."
                            : "Optional. Needs Apple's free Command Line Tools",
                    state: model.nowPlaying,
                    request: model.installDeveloperTools,
                    openSettings: {},
                    requestTitle: model.installingTools ? "Retry" : "Install"
                )
            }
            .padding(.horizontal, 16)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            allowAll
                .animation(.easeInOut(duration: 0.2), value: model.pendingCount)
                .animation(.easeInOut(duration: 0.2), value: model.isAllowingAll)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Coming back from System Settings: pick up whatever changed there.
            model.refreshPermissions()
        }
    }

    /// The easy path: one button, with a heads-up about what macOS will show.
    @ViewBuilder
    private var allowAll: some View {
        if model.isAllowingAll {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Click “Allow” in each macOS pop-up.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .transition(.opacity)
        } else if model.pendingCount > 1 {
            HStack(spacing: 12) {
                Button {
                    model.allowAll()
                } label: {
                    Label("Allow All", systemImage: "checkmark.shield.fill")
                }
                .glassPrimaryButton(compact: true)

                Text("macOS will ask \(model.pendingCount) times — just click Allow.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .transition(.opacity)
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let state: OnboardingModel.PermissionState
    let request: () -> Void
    let openSettings: () -> Void
    var requestTitle = "Allow"

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .liquidGlass(in: RoundedRectangle(cornerRadius: 9, style: .continuous), tint: tint.opacity(0.8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(state == .denied ? "Turned off. Open Settings and switch on Isle." : detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(state == .denied ? Color.orange.opacity(0.85) : Color.white.opacity(0.5))
            }

            Spacer()

            trailing
                .animation(.easeInOut(duration: 0.2), value: state)
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .denied:
            Button("Open Settings", action: openSettings)
                .glassSecondaryButton(compact: true)
        case .notAsked, .unavailable:
            Button(requestTitle, action: request)
                .glassPrimaryButton(compact: true)
        case .unknown:
            ProgressView().controlSize(.small)
        }
    }
}

// MARK: - Setup

private struct SetupPage: View {
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        VStack(spacing: 18) {
            PageHeader(
                symbol: "slider.horizontal.3",
                tint: .teal,
                title: "Make it yours",
                subtitle: "Sensible defaults are already on. Change anything later in Settings."
            )

            VStack(spacing: 0) {
                SetupToggle(
                    title: "Open Isle at login",
                    detail: "Start automatically with your Mac",
                    isOn: Binding(
                        get: { preferences.launchAtLogin },
                        set: { preferences.setLaunchAtLogin($0) }
                    )
                )
                Divider().overlay(Color.white.opacity(0.06))
                SetupToggle(
                    title: "Open on hover",
                    detail: "Otherwise hover lifts the island and a click opens it",
                    isOn: $preferences.expandOnHover
                )
                Divider().overlay(Color.white.opacity(0.06))
                SetupToggle(
                    title: "Hide in full screen",
                    detail: "Stay out of the way of full-screen apps and videos",
                    isOn: $preferences.hideInFullScreen
                )
                Divider().overlay(Color.white.opacity(0.06))
                SetupToggle(
                    title: "Calendar in the island",
                    detail: "Up Next row and reminders before meetings",
                    isOn: $preferences.calendarEnabled
                )
            }
            .padding(.horizontal, 16)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

private struct SetupToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .toggleStyle(.switch)
        .tint(.blue)
        .padding(.vertical, 11)
    }
}

// MARK: - Done

private struct DonePage: View {
    var body: some View {
        VStack(spacing: 22) {
            IslandDemo(startExpanded: true)

            VStack(spacing: 8) {
                Text("You're all set")
                    .font(.system(size: 30, weight: .bold))
                Text("Move your pointer up to the notch to try it.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
            }

            HStack(spacing: 18) {
                Tip(symbol: "cursorarrow.motionlines", text: "Hover to lift")
                Tip(symbol: "cursorarrow.click", text: "Click to open")
                Tip(symbol: "menubar.rectangle", text: "Settings in the menu bar")
            }
            .padding(.top, 4)
        }
    }
}

private struct Tip: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 44, height: 44)
                .liquidGlass(in: Circle(), interactive: true)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(width: 130)
    }
}

// MARK: - Shared pieces

private struct PageHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .liquidGlass(
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous),
                    tint: tint.opacity(0.75),
                    interactive: true
                )
                .shadow(color: tint.opacity(0.4), radius: 16, y: 6)

            Text(title)
                .font(.system(size: 24, weight: .bold))

            Text(subtitle)
                .font(.system(size: 13.5))
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
    }
}

private struct OnboardingBackground: View {
    var body: some View {
        ZStack {
            WindowGlassBackground()
            // A light night-blue wash keeps text readable over any wallpaper
            // while letting the desktop colour come through the glass.
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.11, blue: 0.20).opacity(0.35),
                         Color(red: 0.02, green: 0.03, blue: 0.07).opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Color(red: 0.36, green: 0.40, blue: 1.0).opacity(0.28), .clear],
                center: UnitPoint(x: 0.35, y: 0.0),
                startRadius: 0,
                endRadius: 360
            )
            RadialGradient(
                colors: [Color(red: 1.0, green: 0.36, blue: 0.62).opacity(0.16), .clear],
                center: UnitPoint(x: 0.8, y: 0.1),
                startRadius: 0,
                endRadius: 300
            )
        }
        .ignoresSafeArea()
    }
}

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    var compact = false
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : (large ? 14 : 13), weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 14 : (large ? 22 : 18))
            .padding(.vertical, compact ? 5 : (large ? 10 : 8))
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.35, green: 0.55, blue: 1.0), Color(red: 0.55, green: 0.38, blue: 1.0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .shadow(color: Color(red: 0.45, green: 0.45, blue: 1.0).opacity(compact ? 0 : 0.4), radius: 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct OnboardingSecondaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 5 : 8)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.09)))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Live miniature of the island

/// A small, self-running demo: collapsed → peek with art and bars → open panel,
/// on the same kinds of springs as the real island.
struct IslandDemo: View {
    var startExpanded = false

    private enum Phase: CaseIterable { case collapsed, peek, expanded }
    @State private var phase: Phase = .collapsed
    @State private var timer: Timer?

    private var size: CGSize {
        switch phase {
        case .collapsed: return CGSize(width: 110, height: 24)
        case .peek: return CGSize(width: 170, height: 28)
        case .expanded: return CGSize(width: 250, height: 86)
        }
    }

    private var bottomRadius: CGFloat {
        switch phase {
        case .collapsed: return 9
        case .peek: return 12
        case .expanded: return 24
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // "Screen" strip the island hangs from.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .frame(width: 300, height: 110)

            ZStack(alignment: .topLeading) {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: bottomRadius,
                    bottomTrailingRadius: bottomRadius,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .fill(Color.black)
                .shadow(color: .black.opacity(phase == .expanded ? 0.6 : 0), radius: 12, y: 6)

                // The cover: one shape that grows from the peek circle to the panel square.
                RoundedRectangle(cornerRadius: phase == .expanded ? 8 : 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 1, green: 0.75, blue: 0.35), Color(red: 1, green: 0.37, blue: 0.51), Color(red: 0.55, green: 0.31, blue: 1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: artSide, height: artSide)
                    .offset(x: phase == .expanded ? 14 : 8, y: phase == .expanded ? 12 : 4)
                    .opacity(phase == .collapsed ? 0 : 1)

                if phase == .expanded {
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().fill(Color.white.opacity(0.9)).frame(width: 90, height: 7)
                        Capsule().fill(Color.white.opacity(0.35)).frame(width: 64, height: 6)
                        Capsule().fill(Color.white.opacity(0.18)).frame(width: 160, height: 4).padding(.top, 10)
                    }
                    .offset(x: 62, y: 28)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topLeading)))
                }

                if phase != .collapsed {
                    DemoBars()
                        .frame(width: 16, height: 12)
                        .offset(x: size.width - (phase == .expanded ? 30 : 24), y: phase == .expanded ? 14 : 8)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: bottomRadius,
                    bottomTrailingRadius: bottomRadius,
                    topTrailingRadius: 0,
                    style: .continuous
                )
            )
        }
        .frame(height: 110, alignment: .top)
        .onAppear(perform: start)
        .onDisappear { timer?.invalidate() }
    }

    private var artSide: CGFloat {
        switch phase {
        case .collapsed: return 10
        case .peek: return 20
        case .expanded: return 38
        }
    }

    private func start() {
        if startExpanded {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.75).delay(0.25)) { phase = .expanded }
            return
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { _ in
            Task { @MainActor in
                let next: Phase
                switch phase {
                case .collapsed: next = .peek
                case .peek: next = .expanded
                case .expanded: next = .collapsed
                }
                let grow = next != .collapsed
                withAnimation(grow
                    ? .spring(response: 0.5, dampingFraction: 0.74)
                    : .spring(response: 0.36, dampingFraction: 0.94)) {
                    phase = next
                }
            }
        }
    }
}

private struct DemoBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let speeds = [3.1, 4.3, 2.7, 3.7]
                    let wave = (sin(t * speeds[i] + Double(i)) + 1) / 2
                    Capsule()
                        .fill(Color(red: 0.7, green: 0.6, blue: 1.0))
                        .frame(width: 2, height: 2 + CGFloat(wave) * 10)
                }
            }
        }
    }
}
