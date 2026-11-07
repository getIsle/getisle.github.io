//
//  PeekContentView.swift
//  Isle
//
//  The peeked state: content flanking the camera housing.
//
//  The housing is opaque hardware — nothing can be drawn there — so the layout is
//  always [left accessory][gutter exactly as wide as the notch][right accessory].
//  On a display with no notch we keep the identical layout so behaviour does not
//  diverge between a MacBook Pro and an external monitor.
//

import SwiftUI

struct PeekContentView: View {

    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var preferences: Preferences

    /// Drives the reveal. The accessories start tucked underneath the housing and
    /// slide outwards as the capsule widens, so the content reads as having *come
    /// out of* the notch rather than having faded in on top of it. The island is
    /// clipped to its own silhouette, so mid-animation they are genuinely hidden
    /// behind the black.
    @State private var revealed = false

    private var slide: CGFloat { viewModel.contentSize.height + 10 }

    var body: some View {
        VStack(spacing: 0) {
            strip
                .frame(height: viewModel.peekStripHeight)

        }
        .frame(height: viewModel.contentSize.height, alignment: .top)
        .foregroundStyle(.white)
        .onAppear {
            // A beat behind the capsule's own spring, so the shape leads and the
            // content follows it out. That lag is most of what sells the effect.
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78).delay(0.05)) {
                revealed = true
            }
        }
        .onDisappear { revealed = false }
    }

    /// Level with the camera: [art / glyph] [housing] [bars / ring].
    private var strip: some View {
        HStack(spacing: 0) {
            leading
                .frame(maxWidth: .infinity)
                .padding(.leading, Self.edgeInset)
                .offset(x: revealed ? 0 : slide)
                .opacity(revealed ? 1 : 0)

            // The untouchable middle.
            Color.clear
                .frame(width: viewModel.metrics.notchSize.width)

            trailing
                .frame(maxWidth: .infinity)
                .padding(.trailing, Self.edgeInset + 2)
                .offset(x: revealed ? 0 : -slide)
                .opacity(revealed ? 1 : 0)
        }
    }

    // MARK: Leading — the "what" badge

    @ViewBuilder
    private var leading: some View {
        if viewModel.nowPlaying.map({ !$0.isEmpty }) ?? false {
            // Space held for the cover, which IslandArtworkLayer draws so that it
            // can grow straight into the expanded player's artwork.
            HStack(spacing: 0) {
                Color.clear.frame(width: artworkDiameter, height: artworkDiameter)
                Spacer(minLength: 0)
            }
        } else {
            Color.clear
        }
    }

    // MARK: Trailing — the "detail" side

    @ViewBuilder
    private var trailing: some View {
        if let media = viewModel.nowPlaying, !media.isEmpty {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                // Deliberately tiny — at rest this sits on screen for a whole album,
                // so it has to read as a quiet pulse, not a dashboard.
                AudioBarsView(
                    isAnimating: media.isPlaying,
                    tint: (viewModel.artworkTint ?? preferences.accentColor).opacity(0.9),
                    barCount: 4,
                    barWidth: 2,
                    maxHeight: 11
                )
            }
        } else {
            Color.clear
        }
    }

    // MARK: Pieces

    /// Distance from the island's outer edges to the art / bars. The bottom corners
    /// curve inwards, so anything closer than ~10 pt looks jammed into the curve
    /// instead of sitting inside the shape. NotchViewModel sizes the flanks from
    /// this so there is also a gap on the housing side.
    static let edgeInset: CGFloat = 10

    private var artworkDiameter: CGFloat { Self.artworkDiameter(for: viewModel) }

    /// Fill the capsule's height, leaving an even ring of black around it. The
    /// black margin is what makes the capsule feel like a bezel holding the art.
    static func artworkDiameter(for viewModel: NotchViewModel) -> CGFloat {
        max(16, viewModel.peekStripHeight - 12)
    }

    /// Circular, matching the reference look — a round thumbnail reads as "media"
    /// far faster than a rounded square at this size.
    @ViewBuilder
    private func artworkThumb(_ image: NSImage?) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Circle()
                    .fill(Color.white.opacity(0.12))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                    )
            }
        }
        .frame(width: artworkDiameter, height: artworkDiameter)
        .clipShape(Circle())
        .overlay(
            Circle().stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }
}
