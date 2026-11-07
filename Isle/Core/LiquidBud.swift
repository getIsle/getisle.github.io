//
//  LiquidBud.swift
//  Isle
//
//  The "liquid split": when something arrives, a small bubble pinches off the left
//  of the island carrying the event's icon, hangs there for a beat, and is then
//  pulled back in as the island grows to show it. The island reads as one liquid
//  object that budded and reabsorbed a drop, not as two views sliding about.
//
//  The goo is a metaball: the bubble and a stand-in for the island's left end are
//  drawn into one layer, blurred, and cut back to a hard edge with an alpha
//  threshold. While the two are close the blur fields add up between them and the
//  threshold leaves a neck; as they part the neck thins and snaps.
//
//  The layer sits *behind* the island. Its stand-in for the island is covered by
//  the real shape, so only the neck and the bubble ever show, and when the bubble
//  is pulled back in, its icon disappears under the island.
//

import AppKit
import SwiftUI

/// What the bubble carries. Equal by id, so swapping the icon of a bubble that is
/// already out does not restart its animation.
struct LiquidBud: Identifiable, Equatable {
    let id = UUID()
    var symbolName: String
    var tint: Color
    var image: NSImage?

    static func == (lhs: LiquidBud, rhs: LiquidBud) -> Bool { lhs.id == rhs.id }
}

extension LiquidBud {
    init(hud: HUDEvent) {
        self.init(symbolName: hud.symbolName, tint: hud.tint, image: hud.image)
    }

    init(notification: NotchNotification) {
        self.init(symbolName: notification.symbolName, tint: notification.accent, image: notification.image)
    }
}

/// Drawn as a background of the island's frame, anchored to its top-leading corner.
struct LiquidBudLayer: View {
    let bud: LiquidBud
    let detached: Bool
    /// Height of the strip level with the camera; the bubble is centred in it.
    let stripHeight: CGFloat
    /// How far the island's silhouette spills past its frame (the merged style's
    /// concave shoulders). The bubble has to clear that, not just the frame.
    let overhang: CGFloat

    /// Points of the layer hidden under the island. Must be well over the blur
    /// radius, or the blur thins the stand-in where the island's edge is.
    static let overlap: CGFloat = 22
    /// Space between the bubble and the island once it has pinched off.
    static let gap: CGFloat = 9
    static let goo: CGFloat = 5

    /// Out: quick with a visible overshoot, so the drop is flung free. In: no
    /// bounce, so it is swallowed rather than bouncing off the island.
    static let splitSpring = Animation.spring(response: 0.42, dampingFraction: 0.62)
    static let mergeSpring = Animation.spring(response: 0.3, dampingFraction: 0.9)

    private var diameter: CGFloat { max(18, stripHeight - 6) }

    private var width: CGFloat {
        Self.overlap + overhang + Self.gap + diameter + Self.goo * 4
    }

    var body: some View {
        LiquidBudCanvas(
            separation: detached ? 1 : 0,
            bud: bud,
            diameter: diameter,
            stripHeight: stripHeight,
            overhang: overhang
        )
        .frame(width: width, height: stripHeight)
        .offset(x: -(width - Self.overlap))
        .animation(detached ? Self.splitSpring : Self.mergeSpring, value: detached)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Animatable, so SwiftUI hands it every in-between value of `separation` and the
/// metaball is redrawn each frame instead of jumping between two end states.
private struct LiquidBudCanvas: View, Animatable {
    var separation: CGFloat
    let bud: LiquidBud
    let diameter: CGFloat
    let stripHeight: CGFloat
    let overhang: CGFloat

    var animatableData: CGFloat {
        get { separation }
        set { separation = newValue }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let circle = circleRect(in: size)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    context.addFilter(.alphaThreshold(min: 0.5, color: .black))
                    context.addFilter(.blur(radius: LiquidBudLayer.goo))
                    context.drawLayer { layer in
                        // Stand-in for the island's left end: a pill through the
                        // middle of the strip, so it stays inside the island
                        // whatever its corners are (square, flared, or a full
                        // capsule) and only the neck can show. Runs past the
                        // right edge so the blur does not eat into it there.
                        let islandEdge = size.width - LiquidBudLayer.overlap
                        let standHeight = stripHeight * 0.6
                        let stand = CGRect(
                            x: islandEdge,
                            y: (stripHeight - standHeight) / 2,
                            width: LiquidBudLayer.overlap + LiquidBudLayer.goo * 4,
                            height: standHeight
                        )
                        layer.fill(
                            Path(roundedRect: stand, cornerRadius: standHeight / 2),
                            with: .color(.black)
                        )
                        layer.fill(Path(ellipseIn: circle), with: .color(.black))
                    }
                }

                // A wash of the event's colour, like the coloured bubble in iOS's
                // split island. Fades in only once the drop is mostly free, so the
                // neck stays black.
                Circle()
                    .fill(bud.tint.opacity(0.22))
                    .frame(width: circle.width, height: circle.height)
                    .position(x: circle.midX, y: circle.midY)
                    .opacity(iconOpacity)

                icon(size: circle.width)
                    .position(x: circle.midX, y: circle.midY)
                    .opacity(iconOpacity)
                    .scaleEffect(0.6 + 0.4 * min(1, max(0, separation)))
            }
        }
    }

    private var iconOpacity: Double {
        Double(min(1, max(0, (separation - 0.55) / 0.35)))
    }

    /// At 0 the bubble sits wholly inside the island; at 1 it is free, a gap away
    /// from the silhouette. It also swells from a seed to full size as it goes.
    private func circleRect(in size: CGSize) -> CGRect {
        let s = separation
        let d = diameter * (0.55 + 0.45 * min(1.1, max(0, s)))
        let r = d / 2
        let islandEdge = size.width - LiquidBudLayer.overlap
        let travel = diameter + LiquidBudLayer.gap + overhang
        let centreX = islandEdge + diameter / 2 - travel * s
        let centreY = stripHeight / 2
        return CGRect(x: centreX - r, y: centreY - r, width: d, height: d)
    }

    @ViewBuilder
    private func icon(size: CGFloat) -> some View {
        if let image = bud.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size - 6, height: size - 6)
                .clipShape(Circle())
        } else {
            Image(systemName: bud.symbolName)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(bud.tint)
                .symbolRenderingMode(.hierarchical)
        }
    }
}
