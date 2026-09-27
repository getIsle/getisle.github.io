//
//  IslandArtworkLayer.swift
//  Isle
//
//  The album cover, drawn ONCE, above whatever content the island is showing.
//
//  The peek and the expanded player used to each draw their own copy of the art,
//  so opening the island cross-faded a small circle out and a big square in, out of
//  step with the shape. Here there is a single image whose frame, corner radius and
//  position are derived from the presentation and animated on the same spring as
//  the island's height — so the round thumbnail beside the camera visibly grows
//  into the 56 pt cover as the island opens, and shrinks back into the circle as it
//  closes. That continuity is what the iPhone's Dynamic Island does.
//
//  The peek and player views keep an empty frame where the art goes, so their
//  layout is unchanged.
//

import SwiftUI

struct IslandArtworkLayer: View {

    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var preferences: Preferences

    private struct Placement: Equatable {
        var origin: CGPoint
        var side: CGFloat
        var cornerRadius: CGFloat
        var isVisible: Bool
    }

    var body: some View {
        let placement = self.placement

        artwork
            .frame(width: placement.side, height: placement.side)
            .clipShape(RoundedRectangle(cornerRadius: placement.cornerRadius, style: .continuous))
            .scaleEffect(placement.isVisible ? 1 : 0.5, anchor: .center)
            .opacity(placement.isVisible ? 1 : 0)
            .blur(radius: placement.isVisible ? 0 : 4)
            .offset(x: placement.origin.x, y: placement.origin.y)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .animation(spring, value: placement)
            // New cover: dissolve between the two images instead of snapping.
            .animation(.easeInOut(duration: 0.3), value: coverIdentity)
    }

    // MARK: Where the cover goes

    private var media: NowPlayingInfo? {
        guard preferences.nowPlayingEnabled,
              let media = viewModel.nowPlaying, !media.isEmpty else { return nil }
        return media
    }

    private var placement: Placement {
        let size = viewModel.contentSize

        switch viewModel.presentation {
        case .expanded where media != nil:
            let side = NowPlayingWidget.artworkSide(for: viewModel)
            return Placement(
                origin: CGPoint(x: NowPlayingWidget.horizontalPadding, y: NowPlayingWidget.artworkTop),
                side: side,
                cornerRadius: 12,
                isVisible: true
            )

        case .peek where media != nil && (viewModel.hud == nil || viewModel.hud?.kind == .nowPlaying):
            let diameter = PeekContentView.artworkDiameter(for: viewModel)
            return Placement(
                origin: CGPoint(
                    x: PeekContentView.edgeInset,
                    y: (viewModel.peekStripHeight - diameter) / 2
                ),
                side: diameter,
                cornerRadius: diameter / 2,
                isVisible: true
            )

        default:
            // Tucked under the camera housing: shrinks towards the notch's left
            // edge while fading, as if it went back inside.
            let side: CGFloat = 14
            let housingLeft = (size.width - viewModel.metrics.notchSize.width) / 2
            return Placement(
                origin: CGPoint(x: max(0, housingLeft), y: (min(size.height, 32) - side) / 2),
                side: side,
                cornerRadius: side / 2,
                isVisible: false
            )
        }
    }

    /// Matches the island's own motion: the art grows on the *height* spring when
    /// opening (it is the vertical drop that carries it) and settles flat on close.
    private var spring: Animation {
        switch viewModel.motion {
        case .open: return .spring(response: 0.52, dampingFraction: 0.74).delay(0.035)
        case .close: return .spring(response: 0.34, dampingFraction: 0.95)
        case .hoverIn: return NotchRootView.hoverInSpring
        case .hoverOut: return NotchRootView.hoverOutSpring
        }
    }

    // MARK: The image

    private var coverIdentity: ObjectIdentifier? {
        media?.artwork.map(ObjectIdentifier.init)
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = media?.artwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .id(coverIdentity)
                .transition(.opacity)
        } else {
            // Track with no cover (many browser tabs): tinted tile with a note.
            LinearGradient(
                colors: [preferences.accentColor.opacity(0.55), Color(white: 0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            )
        }
    }
}
