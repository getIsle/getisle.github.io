//
//  LiquidBud.swift
//  Isle
//
//  The "liquid split": when something arrives, a drop pinches off the left of the
//  island carrying the event's icon, and stays out as the notification's only icon
//  until it ends, then flows home. Like a drop separating from water and merging again.
//
//  The notch is hardware, so only the drop travels: the island stays over the camera
//  throughout, and the drop sits beside it in the strip level with the camera.
//
//  The liquid is drawn as a crisp outline rather than a blur: the drop starts thick
//  and flared into the island's side, stretches into an hourglass, thins to a point
//  and snaps, the two tips pull back, and the drop wobbles as it settles. It stays
//  black until it is free, so the neck never shows colour.
//
//  The layer sits *behind* the island, so only the neck and the drop ever show, and
//  when the drop is pulled back in, its icon disappears under the island.
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
    /// Height of the island the drop joins: it may be shorter than the strip it left.
    let joinHeight: CGFloat
    /// How far the island's silhouette spills past its frame (the merged style's
    /// concave shoulders). The bubble has to clear that, not just the frame.
    let overhang: CGFloat

    /// Points of the layer hidden under the island.
    static let overlap: CGFloat = 22
    /// Space between the drop and the island once it has pinched off.
    static let gap: CGFloat = 16
    /// Room around the drop for its wobble and any overshoot.
    static let margin: CGFloat = 20

    /// Springs, so the drop has weight: it leaves with momentum, overshoots a little
    /// and settles by itself. A fixed curve starts and stops dead, and reads as mechanical.
    static let splitSpring = Animation.spring(response: 0.95, dampingFraction: 0.68)
    static let mergeSpring = Animation.spring(response: 0.72, dampingFraction: 0.86)
    /// How long each takes to look finished, for what follows it to start from.
    static let splitDuration = 1.0
    static let mergeDuration = 0.75

    /// Nearly the height of the island it left, and clear of the top of the screen.
    private var dropHeight: CGFloat { max(20, stripHeight - 10) }
    /// A capsule rather than a circle: it reads as liquid, and has room for its icon.
    private var dropWidth: CGFloat { dropHeight * 1.45 }

    private var width: CGFloat {
        Self.overlap + overhang + Self.gap + dropWidth + Self.margin
    }

    var body: some View {
        LiquidBudCanvas(
            separation: detached ? 1 : 0,
            bud: bud,
            dropWidth: dropWidth,
            dropHeight: dropHeight,
            stripHeight: stripHeight,
            joinHeight: joinHeight,
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
/// liquid is redrawn each frame instead of jumping between two end states.
private struct LiquidBudCanvas: View, Animatable {
    var separation: CGFloat
    let bud: LiquidBud
    let dropWidth: CGFloat
    let dropHeight: CGFloat
    let stripHeight: CGFloat
    let joinHeight: CGFloat
    let overhang: CGFloat

    /// The drop is sized and centred to the island it joins, so nothing hangs below it.
    private var currentHeight: CGFloat { min(joinHeight, stripHeight) }

    var animatableData: CGFloat {
        get { separation }
        set { separation = newValue }
    }

    var body: some View {
        GeometryReader { proxy in
            let liquid = liquid(in: proxy.size)

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    context.fill(
                        Path(roundedRect: liquid.drop, cornerRadius: liquid.drop.height / 2),
                        with: .color(.black)
                    )
                    context.fill(liquid.neck, with: .color(.black))
                }
                // Black alone vanishes on a dark menu bar: the glow is what you notice.
                .shadow(color: bud.tint.opacity(0.85), radius: 9)

                // The event's colour inside a black rim, only once the drop is free.
                Capsule()
                    .fill(bud.tint)
                    .frame(
                        width: max(0, liquid.drop.width - 7),
                        height: max(0, liquid.drop.height - 7)
                    )
                    .position(x: liquid.drop.midX, y: liquid.drop.midY)
                    .opacity(liquid.freedom)

                icon(in: liquid.drop.size)
                    .position(x: liquid.drop.midX, y: liquid.drop.midY)
                    .opacity(liquid.freedom)
                    .scaleEffect(0.6 + 0.4 * liquid.freedom)
            }
        }
    }

    private struct Liquid {
        var drop: CGRect
        var neck: Path
        /// 0 while joined to the island, rising to 1 as the drop settles.
        var freedom: Double
    }

    private func clamp(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
    private func smooth(_ x: CGFloat) -> CGFloat { let t = clamp(x); return t * t * (3 - 2 * t) }
    private func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    private func liquid(in size: CGSize) -> Liquid {
        let wall = size.width - LiquidBudLayer.overlap
        let strip = currentHeight
        let centreY = strip / 2

        // At 0 the drop is hidden inside the island; at 1 it hangs a gap away from it.
        // Fully hidden: wider than the drop at its widest, so it never pops in or out.
        let hidden = dropWidth * 1.3
        let farthest = overhang + LiquidBudLayer.gap
        let dropRight = wall + hidden - (hidden + farthest) * separation
        let distance = wall - dropRight
        // How far apart the two are when the neck breaks.
        let snap = farthest * 0.7

        // Thick as it leaves the island, slimming to its own size by the time it breaks.
        let slimming = smooth((distance + hidden * 0.5) / (hidden * 0.5 + snap))
        let height = mix(strip * 0.5, min(dropHeight, strip - 12), slimming)
        let width = mix(dropWidth * 0.8, dropWidth * 0.96, slimming)

        let settled = clamp((distance - snap) / (farthest - snap))

        let drop = CGRect(x: dropRight - width, y: centreY - height / 2, width: width, height: height)
        return Liquid(
            drop: drop,
            neck: neck(wall: wall, dropRight: dropRight, centreY: centreY, radius: height / 2, distance: distance, snap: snap, span: farthest - snap),
            freedom: Double(smooth(settled * 1.25))
        )
    }

    /// The liquid between the drop and the island, top and bottom mirrored. Before it
    /// breaks: curves leaving the drop, a waist, and a flare into the island's side.
    /// After: a tip on each side, pulling back.
    private func neck(wall: CGFloat, dropRight: CGFloat, centreY: CGFloat, radius: CGFloat, distance: CGFloat, snap: CGFloat, span: CGFloat) -> Path {
        var path = Path()

        guard distance < snap else {
            let left = 1 - clamp((distance - snap) / (span * 0.75))
            guard left > 0 else { return path }
            let length = snap * 0.5 * left
            let base = 0.5 + 2 * left
            addTip(to: &path, baseX: wall + 1, tipX: wall - length, centreY: centreY, base: base)
            addTip(to: &path, baseX: dropRight - 1, tipX: dropRight + length, centreY: centreY, base: base)
            return path
        }

        let closeness = 1 - clamp(max(0, distance) / snap)
        let waist = radius * pow(closeness, 1.3) * 0.96
        // Runs on under the island, so the curve meets its edge with no step.
        let strip = currentHeight
        // It stops above the island's rounded bottom corner: lower than that, its edge
        // has nothing to hide behind and shows as a square corner.
        let flare = min(waist + 3, mix(waist + 3, strip / 2 - 13, closeness * closeness))
        // Upward it reaches the top of the screen, so no sliver of menu bar is left
        // between the join and the edge.
        let topFlare = mix(waist + 3, strip / 2 + 1, closeness * closeness)
        let endX = wall + 12
        let startX = dropRight - radius
        guard startX < wall else { return path }
        let middleX = distance > 0 ? dropRight + distance * 0.5 : (startX + wall) / 2

        func y(_ offset: CGFloat, _ side: CGFloat) -> CGFloat { centreY + offset * side }

        path.move(to: CGPoint(x: startX, y: y(radius, -1)))
        path.addCurve(
            to: CGPoint(x: middleX, y: y(waist, -1)),
            control1: CGPoint(x: mix(startX, middleX, 0.55), y: y(radius, -1)),
            control2: CGPoint(x: mix(startX, middleX, 0.6), y: y(waist, -1))
        )
        path.addCurve(
            to: CGPoint(x: endX, y: y(topFlare, -1)),
            control1: CGPoint(x: mix(middleX, endX, 0.5), y: y(waist, -1)),
            control2: CGPoint(x: mix(middleX, endX, 0.6), y: y(topFlare, -1))
        )
        path.addLine(to: CGPoint(x: endX, y: y(flare, 1)))
        path.addCurve(
            to: CGPoint(x: middleX, y: y(waist, 1)),
            control1: CGPoint(x: mix(middleX, endX, 0.6), y: y(flare, 1)),
            control2: CGPoint(x: mix(middleX, endX, 0.5), y: y(waist, 1))
        )
        path.addCurve(
            to: CGPoint(x: startX, y: y(radius, 1)),
            control1: CGPoint(x: mix(startX, middleX, 0.6), y: y(waist, 1)),
            control2: CGPoint(x: mix(startX, middleX, 0.55), y: y(radius, 1))
        )
        path.closeSubpath()
        return path
    }

    private func addTip(to path: inout Path, baseX: CGFloat, tipX: CGFloat, centreY: CGFloat, base: CGFloat) {
        path.move(to: CGPoint(x: baseX, y: centreY - base))
        path.addQuadCurve(
            to: CGPoint(x: tipX, y: centreY),
            control: CGPoint(x: mix(baseX, tipX, 0.55), y: centreY - base * 0.35)
        )
        path.addQuadCurve(
            to: CGPoint(x: baseX, y: centreY + base),
            control: CGPoint(x: mix(baseX, tipX, 0.55), y: centreY + base * 0.35)
        )
        path.closeSubpath()
    }

    @ViewBuilder
    private func icon(in size: CGSize) -> some View {
        if let image = bud.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: max(0, size.width - 7), height: max(0, size.height - 7))
                .clipShape(Capsule())
        } else {
            Image(systemName: bud.symbolName)
                .font(.system(size: size.height * 0.5, weight: .semibold))
                .foregroundStyle(bud.tint == .white ? Color.black : Color.white)
        }
    }
}
