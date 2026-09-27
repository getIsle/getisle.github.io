//
//  NowPlayingWidget.swift
//  Isle
//
//  The expanded player.
//
//  The layout trick that makes this read as compact rather than tall: the camera
//  housing only occludes the *centre* of the top strip. The gutters either side of it
//  are perfectly usable from y = 0. So the artwork sits in the left gutter starting
//  near the very top, the status chip sits in the right gutter, and only the title and
//  artist — which do cross the housing's horizontal span — are pushed below it.
//
//  Pushing every element below the notch instead (the obvious implementation) costs a
//  whole 32 pt band across the full width and makes the panel look half empty.
//
//      ┌────────┬──────────────┬────────┐
//      │ [art]  │   housing    │  35%   │  ← gutters used from the top
//      │        ├──────────────┤        │
//      │        │ Title        │  ||||  │  ← text starts below the housing
//      │        │ Artist — Alb │        │
//      ├────────┴──────────────┴────────┤
//      │ 1:18 ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬  -2:45 │
//      │        ◀◀    ❚❚    ▶▶      💻  │
//      └────────────────────────────────┘
//

import SwiftUI

struct NowPlayingWidget: View {

    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var preferences: Preferences

    let media: NowPlayingInfo

    /// Left half of the side-by-side panel: the column's right edge sits under the
    /// camera housing, so the right-gutter status/bars and the output button are
    /// left out (the agenda owns the right gutter).
    var compact: Bool = false

    @State private var hoveredControl: MediaCommand?

    /// Nothing is loaded in any player. The panel keeps exactly the same layout —
    /// placeholder art, "Not Playing", dimmed transport — so hovering the notch never
    /// changes shape depending on whether music happens to be on.
    private var isIdle: Bool { media.isEmpty }

    /// Transport only works when there is a track to act on (playing *or* paused —
    /// a paused track still needs a working play button) and a backend to send to.
    private var controlsEnabled: Bool { !isIdle && viewModel.canControlMedia }

    private let preferredArtworkSize: CGFloat = 56
    /// Where the artwork's top edge sits. Shared with IslandArtworkLayer, which
    /// actually draws the cover so it can morph between peek and panel.
    static let artworkTop: CGFloat = 14
    private var topPadding: CGFloat { Self.artworkTop }

    /// Side of the expanded artwork: 56 pt, or less if the gutter beside the camera
    /// is narrower than that.
    static func artworkSide(for viewModel: NotchViewModel) -> CGFloat {
        let panel = viewModel.expandedSize.width
        let housing = viewModel.metrics.notchSize.width
        let gutter = max(0, (panel - housing) / 2 - horizontalPadding - 6)
        return min(56, gutter)
    }
    /// Must match the horizontal padding ExpandedPanelView gives this widget.
    static let horizontalPadding: CGFloat = 19
    /// Breathing room kept between anything in a gutter and the housing's edge.
    private let housingClearance: CGFloat = 6

    /// Width of each strip beside the camera housing that is actually drawable
    /// from the very top of the panel. Derived from the *real* notch width, so a
    /// wider housing (or a virtual one) automatically shrinks what sits beside it.
    private var gutterWidth: CGFloat {
        let panel = viewModel.expandedSize.width
        let housing = viewModel.metrics.notchSize.width
        return max(0, (panel - housing) / 2 - Self.horizontalPadding - housingClearance)
    }

    /// Artwork lives in the left gutter from the top, so it can never be wider than
    /// that gutter.
    private var artworkSize: CGFloat { min(preferredArtworkSize, gutterWidth) }

    /// Title + subtitle stack under the housing; the row has to be tall enough for
    /// both on a taller notch too (the 16" housing is deeper than the 14").
    private var topRowHeight: CGFloat {
        max(artworkSize, textTopOffset + 2 + 19 + 2 + 17)
    }

    /// How far the title has to drop to clear the camera housing.
    private var textTopOffset: CGFloat {
        // +3 pt of clearance below the housing's bottom edge, so the title never
        // looks like it is touching the camera.
        max(0, viewModel.metrics.notchSize.height - topPadding) + 3
    }

    var body: some View {
        VStack(spacing: 0) {
            topRow
            Spacer(minLength: 8)
            progressRow
            Spacer(minLength: 11)
            transportRow
        }
        .padding(.top, topPadding)
        .foregroundStyle(.white)
    }

    // MARK: Top row — gutters and metadata

    private var topRow: some View {
        HStack(alignment: .top, spacing: 13) {
            // With a track loaded the cover is drawn by IslandArtworkLayer (so it
            // can fly in from the peek); this just holds its place. The idle
            // placeholder tile is drawn here as usual.
            if isIdle {
                artwork
            } else {
                Color.clear.frame(width: artworkSize, height: artworkSize)
            }

            VStack(alignment: .leading, spacing: 2) {
                // Clears the housing. Everything to the left and right of this column
                // is free to start higher.
                Color.clear.frame(height: textTopOffset)

                Text(media.title.isEmpty ? "Not Playing" : media.title)
                    .font(.islandTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                MarqueeText(
                    text: subtitleText,
                    font: .islandSubtitle,
                    color: .white.opacity(IslandInk.secondary)
                )
                .frame(height: 17)
            }

            Spacer(minLength: 4)

            if !compact {
                rightGutter
                    .opacity(isIdle ? 0 : 1)
            }
        }
        .frame(height: topRowHeight, alignment: .top)
    }

    private var rightGutter: some View {
        VStack(alignment: .trailing, spacing: 0) {
            // This row sits level with the camera, so it is hard-limited to the
            // gutter. ViewThatFits drops detail (the % text, then the Focus glyph)
            // rather than ever letting a chip slide under the housing.
            ViewThatFits(in: .horizontal) {
                statusRow(showFocus: true, showPercentage: true)
                statusRow(showFocus: true, showPercentage: false)
                statusRow(showFocus: false, showPercentage: false)
            }
            .frame(width: gutterWidth, height: 12, alignment: .trailing)
            .clipped()

            // Alcove parks the visualiser in the top-right gutter, level with the
            // title, tinted with the cover's colour rather than a fixed accent.
            AudioBarsView(
                isAnimating: media.isPlaying,
                tint: visualizerTint,
                barCount: 5,
                barWidth: 2,
                maxHeight: 14
            )
            .padding(.top, max(0, textTopOffset - 12))
            Spacer(minLength: 0)
        }
        .frame(width: gutterWidth, alignment: .trailing)
        .frame(height: topRowHeight, alignment: .top)
    }

    private func statusRow(showFocus: Bool, showPercentage: Bool) -> some View {
        HStack(spacing: 5) {
            if showFocus, preferences.focusEnabled, viewModel.focus.isActive {
                Image(systemName: viewModel.focus.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.purple.opacity(0.95))
                    .help(viewModel.focus.name)
            }
            if preferences.batteryEnabled, let battery = viewModel.battery, battery.isNoteworthy {
                BatteryChip(battery: battery, showsPercentage: showPercentage)
            }
        }
        .fixedSize()
    }

    private var artwork: some View {
        ZStack {
            if isIdle {
                // Quiet placeholder: a soft graphite tile with the note glyph, in the
                // spirit of the system's empty Now Playing tile.
                LinearGradient(
                    colors: [Color.white.opacity(0.14), Color.white.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white.opacity(0.75), .white.opacity(0.45)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
            } else if let image = media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [preferences.accentColor.opacity(0.55), .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                )
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        // iOS artwork radius is ~22% of the side. No bloom, no border: on pure black
        // a glow around the art is what makes it look like a web widget.
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var visualizerTint: Color {
        (viewModel.artworkTint ?? preferences.accentColor).opacity(0.9)
    }

    private var subtitleText: String {
        let parts = [media.artist, media.album].filter { !$0.isEmpty }
        return parts.isEmpty ? (media.sourceName ?? "") : parts.joined(separator: " — ")
    }

    // MARK: Scrubber

    private var progressRow: some View {
        // Reading `tick` is what keeps the bar moving: the view model publishes it
        // twice a second while something is playing and the island is open.
        let _ = viewModel.tick
        let elapsed = media.currentElapsed
        let remaining = max(0, media.duration - elapsed)

        return HStack(spacing: 10) {
            // Compact (side by side): just the bar — the half-width column has no
            // room for two time labels without squeezing the bar to a stub.
            if !compact {
                Text(Self.timeString(elapsed))
                    .frame(width: 36, alignment: .leading)
            }

            // Neutral greys, like the system player: a coloured fill competes with
            // the artwork, which is supposed to be the only colour in the panel.
            MeterBar(
                value: media.progress,
                tint: .white.opacity(0.55),
                height: compact ? 4 : 5,
                trackOpacity: 0.16
            )
            .animation(.linear(duration: 0.5), value: media.progress)

            if !compact {
                Text(media.duration > 0 ? "-\(Self.timeString(remaining))" : "--:--")
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .font(.islandTime)
        .foregroundStyle(.white.opacity(IslandInk.tertiary))
        .opacity(isIdle ? 0.3 : (media.duration > 0 ? 1 : 0.35))
    }

    // MARK: Transport

    private var transportRow: some View {
        ZStack {
            HStack(spacing: compact ? 16 : 30) {
                transportButton(.previousTrack, symbol: "backward.fill", size: compact ? 17 : 20)
                transportButton(
                    .togglePlayPause,
                    symbol: media.isPlaying ? "pause.fill" : "play.fill",
                    size: compact ? 21 : 25
                )
                transportButton(.nextTrack, symbol: "forward.fill", size: compact ? 17 : 20)
            }

            HStack {
                Spacer()
                if !compact { outputButton }
            }
        }
        .frame(height: 30)
    }

    private func transportButton(
        _ command: MediaCommand,
        symbol: String,
        size: CGFloat
    ) -> some View {
        Button {
            viewModel.send(command)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(controlsEnabled ? 1 : 0.25))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 30)
                // A soft circular highlight on hover, like macOS Control Centre,
                // instead of scaling the glyph (which reads as a web button).
                .background(
                    Circle()
                        .fill(Color.white.opacity(controlsEnabled && hoveredControl == command ? 0.12 : 0))
                        .frame(width: 36, height: 36)
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!controlsEnabled)
        .animation(NotchRootView.contentSpring, value: controlsEnabled)
        .onHover { inside in
            withAnimation(NotchRootView.contentSpring) {
                hoveredControl = inside ? command : nil
            }
        }
    }

    /// Mirrors the system's output-device affordance. Shows the connected Bluetooth
    /// device's glyph when there is one, and opens Sound settings on click — there is
    /// no public API to actually switch the output device.
    private var outputButton: some View {
        Button {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Image(systemName: outputSymbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(outputName)
    }

    private var connectedAudioDevice: BluetoothDeviceInfo? {
        viewModel.audioDevices.first { $0.isConnected && $0.isAudioDevice }
    }

    private var outputSymbol: String { connectedAudioDevice?.symbolName ?? "laptopcomputer" }
    private var outputName: String {
        connectedAudioDevice?.name ?? "Built-in output — open Sound settings"
    }

    // MARK: Helpers

    static func timeString(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "--:--" }
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension NowPlayingInfo {
    /// Stand-in used to draw the player when nothing is loaded anywhere.
    static let empty = NowPlayingInfo(
        title: "",
        artist: "",
        album: "",
        isPlaying: false,
        duration: 0,
        elapsed: 0,
        playbackRate: 0,
        timestamp: .distantPast,
        artwork: nil,
        sourceBundleIdentifier: nil,
        sourceName: nil
    )
}

/// Shrinks a little while pressed — the tactile "give" every iOS control has.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Shown in the expanded island when nothing is playing, so the island never looks
/// broken or empty.
struct NowPlayingIdleView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "music.note.list")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Nothing playing")
                    .font(.islandHeadline)
                    .foregroundStyle(.white.opacity(0.9))
                Text(hint)
                    .font(.islandBody)
                    .foregroundStyle(.white.opacity(IslandInk.tertiary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var hint: String {
        if !preferences.nowPlayingEnabled {
            return "The Now Playing widget is turned off in Settings."
        }
        return "Play something in Music, Spotify, Safari or Chrome."
    }
}
