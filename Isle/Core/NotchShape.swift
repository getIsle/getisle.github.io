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

    /// Lets SwiftUI interpolate the corner radii during the expand/collapse spring,
    /// so the corners ease open as the island grows rather than snapping.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        switch style {
        case .floating: return floatingPath(in: rect)
        case .notchMerged: return mergedPath(in: rect)
        }
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
