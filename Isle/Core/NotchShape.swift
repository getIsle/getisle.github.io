//
//  NotchShape.swift
//  Isle
//
//  The silhouette of the island. Two styles, because the two look right in
//  different places:
//
//  • .floating     A fully rounded capsule/squircle that reads as a discrete object
//                  sitting at the top of the screen. This is the Dynamic Island look.
//
//  • .notchMerged  Square top, *concave* top shoulders, rounded bottom — the shape
//                  grows out of the bezel instead of floating below it. Closer to the
//                  hardware, but it only makes sense on a display that has a notch.
//
//  NOTE on .notchMerged: its concave flares are drawn `topRadius` points OUTSIDE the
//  horizontal bounds of the rect on each side. Never clip that style to its own frame
//  or the flares disappear and the illusion breaks.
//

import SwiftUI

enum IslandStyle: String, CaseIterable, Identifiable, Codable {
    case floating
    case notchMerged

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .floating: return "Floating capsule"
        case .notchMerged: return "Merged with the bezel"
        }
    }

    var summary: String {
        switch self {
        case .floating:
            return "A rounded pill that detaches from the top edge. Works on any display."
        case .notchMerged:
            return "Square-topped with concave shoulders, so it looks carved out of the bezel."
        }
    }

    /// How far the shape spills past its frame horizontally. Only the merged style
    /// does this; the hit-testing code needs the number.
    func horizontalOverhang(topRadius: CGFloat) -> CGFloat {
        switch self {
        case .floating: return 0
        case .notchMerged: return topRadius
        }
    }
}

struct NotchShape: Shape {
    var style: IslandStyle
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// Width of the drop hanging from the strip; 0 for no drop. Everything in the rect
    /// below `stripHeight` is the drop, so it stretches as the frame grows downward.
    var hangWidth: CGFloat = 0
    var stripHeight: CGFloat = 0
    /// The island's own width when the frame is wider, to hold the drop; 0 for the frame.
    var stripWidth: CGFloat = 0

    /// Lets SwiftUI interpolate the corner radii during the expand/collapse spring,
    /// so the corners ease open as the island grows rather than snapping.
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(topRadius, bottomRadius), hangWidth) }
        set {
            topRadius = newValue.first.first
            bottomRadius = newValue.first.second
            hangWidth = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var strip = rect
        if stripWidth > 0, stripWidth < rect.width {
            strip.origin.x = rect.midX - stripWidth / 2
            strip.size.width = stripWidth
        }
        guard hangWidth > 0.5, stripHeight > 0, rect.height > stripHeight + 0.5 else {
            return basePath(in: strip)
        }
        strip.size.height = stripHeight
        return basePath(in: strip).union(hangingDrop(in: rect))
    }

    private func basePath(in rect: CGRect) -> Path {
        switch style {
        case .floating: return floatingPath(in: rect)
        case .notchMerged: return mergedPath(in: rect)
        }
    }

    // MARK: Hanging drop

    /// Height of the drop itself; anything the rect has beyond that is the gap between
    /// it and the strip.
    static let dropHeight: CGFloat = 26
    /// How far the drop has fallen when the neck breaks.
    private static let snapGap: CGFloat = 7

    /// A drop falling from the strip. As the rect grows it comes out as a bead on a
    /// neck; the neck thins and snaps, the tips pull back, and the drop hangs free.
    private func hangingDrop(in rect: CGRect) -> Path {
        let stripBottom = rect.minY + stripHeight
        let fallen = rect.maxY - stripBottom
        let height = min(fallen, Self.dropHeight)
        let gap = max(0, fallen - Self.dropHeight)
        let width = min(hangWidth, rect.width)
        let drop = CGRect(x: rect.midX - width / 2, y: rect.maxY - height, width: width, height: height)

        var path = Path(roundedRect: drop, cornerRadius: min(height, width) / 2, style: .continuous)
        let half = min(width / 2, 10)
        let centre = rect.midX

        guard gap < Self.snapGap else {
            let left = 1 - min(1, (gap - Self.snapGap) / 3)
            guard left > 0 else { return path }
            addTip(to: &path, centre: centre, baseY: stripBottom - 1, tipY: stripBottom + 2.5 * left, base: 1 + 2 * left)
            addTip(to: &path, centre: centre, baseY: drop.minY + 1, tipY: drop.minY - 2.5 * left, base: 1 + 2 * left)
            return path
        }

        let closeness = 1 - gap / Self.snapGap
        let waist = half * pow(closeness, 1.3) * 0.9
        let flare = 3 + 6 * closeness
        let middleY = stripBottom + gap / 2
        let dropJoin = drop.minY + min(height / 2, half)

        var neck = Path()
        neck.move(to: CGPoint(x: centre - waist - flare, y: stripBottom - 1))
        neck.addCurve(
            to: CGPoint(x: centre - waist, y: middleY),
            control1: CGPoint(x: centre - waist - flare * 0.2, y: stripBottom - 1),
            control2: CGPoint(x: centre - waist, y: stripBottom + gap * 0.2)
        )
        neck.addCurve(
            to: CGPoint(x: centre - half, y: dropJoin),
            control1: CGPoint(x: centre - waist, y: middleY + gap * 0.3),
            control2: CGPoint(x: centre - half, y: drop.minY)
        )
        neck.addLine(to: CGPoint(x: centre + half, y: dropJoin))
        neck.addCurve(
            to: CGPoint(x: centre + waist, y: middleY),
            control1: CGPoint(x: centre + half, y: drop.minY),
            control2: CGPoint(x: centre + waist, y: middleY + gap * 0.3)
        )
        neck.addCurve(
            to: CGPoint(x: centre + waist + flare, y: stripBottom - 1),
            control1: CGPoint(x: centre + waist, y: stripBottom + gap * 0.2),
            control2: CGPoint(x: centre + waist + flare * 0.2, y: stripBottom - 1)
        )
        neck.closeSubpath()
        return path.union(neck)
    }

    private func addTip(to path: inout Path, centre: CGFloat, baseY: CGFloat, tipY: CGFloat, base: CGFloat) {
        path.move(to: CGPoint(x: centre - base, y: baseY))
        path.addQuadCurve(to: CGPoint(x: centre, y: tipY), control: CGPoint(x: centre - base * 0.3, y: (baseY + tipY) / 2))
        path.addQuadCurve(to: CGPoint(x: centre + base, y: baseY), control: CGPoint(x: centre + base * 0.3, y: (baseY + tipY) / 2))
        path.closeSubpath()
    }

    // MARK: Floating capsule

    private func floatingPath(in rect: CGRect) -> Path {
        let top = clampedTop(in: rect)
        let bottom = clampedBottom(in: rect)

        // Built by hand rather than with RoundedRectangle because the top and bottom
        // radii differ once the island expands into a panel.
        var path = Path()

        path.move(to: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + top),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        addBottomRightCorner(to: &path, rect: rect, radius: bottom)
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        addBottomLeftCorner(to: &path, rect: rect, radius: bottom)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }

    // MARK: Merged-with-bezel

    private func mergedPath(in rect: CGRect) -> Path {
        var path = Path()

        let top = clampedTop(in: rect)
        let bottom = clampedBottom(in: rect)

        // Start out on the bezel, to the left of the island.
        path.move(to: CGPoint(x: rect.minX - top, y: rect.minY))

        // Concave shoulder curving down into the left edge.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + top),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )

        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        path.addCurve(
            to: CGPoint(x: rect.minX + bottom, y: rect.maxY),
            control1: CGPoint(x: rect.minX, y: rect.maxY - bottom * Self.arcInset),
            control2: CGPoint(x: rect.minX + bottom * Self.arcInset, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - bottom),
            control1: CGPoint(x: rect.maxX - bottom * Self.arcInset, y: rect.maxY),
            control2: CGPoint(x: rect.maxX, y: rect.maxY - bottom * Self.arcInset)
        )

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + top))

        // Concave shoulder curving back out onto the bezel.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX + top, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }

    // MARK: Helpers

    /// Cubic control-point inset that makes a Bézier corner a true quarter circle
    /// (1 − 0.5523). The old quadratic corners hugged the corner point, so a "28 pt"
    /// corner looked more like 18 pt — this is why the bottom read as boxy.
    private static let arcInset: CGFloat = 0.4477

    private func addBottomRightCorner(to path: inout Path, rect: CGRect, radius r: CGFloat) {
        path.addCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.maxY - r * Self.arcInset),
            control2: CGPoint(x: rect.maxX - r * Self.arcInset, y: rect.maxY)
        )
    }

    private func addBottomLeftCorner(to path: inout Path, rect: CGRect, radius r: CGFloat) {
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control1: CGPoint(x: rect.minX + r * Self.arcInset, y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.maxY - r * Self.arcInset)
        )
    }

    private func clampedTop(in rect: CGRect) -> CGFloat {
        max(0, min(topRadius, min(rect.height / 2, rect.width / 2)))
    }

    private func clampedBottom(in rect: CGRect) -> CGFloat {
        max(0, min(bottomRadius, min(rect.height / 2, rect.width / 2)))
    }
}
