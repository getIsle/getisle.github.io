//
//  NotificationCardView.swift
//  Isle
//
//  A notification rendered inside the island, with a velocity-aware swipe-to-dismiss
//  gesture. Flick it sideways or up toward the notch and it goes away; a slow, short
//  drag springs back.
//

import AppKit
import SwiftUI

struct NotificationCardView: View {

    let notification: NotchNotification
    /// Whether the drop below the strip has opened far enough to hold the text.
    let textVisible: Bool
    let onDismiss: () -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var isDismissing = false

    /// The text surfaces once the drop below has opened.
    @State private var textProgress: Double = 0

    /// Past this much travel we dismiss regardless of speed.
    private let distanceThreshold: CGFloat = 62
    /// A flick: `predictedEndTranslation` is SwiftUI's built-in velocity projection.
    private let velocityThreshold: CGFloat = 160

    var body: some View {
        // One line, in the drop hanging below the island. The icon is the drop beside it.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text(notification.title)
                        .font(.islandHeadline)
                        .layoutPriority(1)
                        .textRenderer(SurfacingText(progress: textProgress))
                    Text(notification.body)
                        .font(.islandBody)
                        .foregroundStyle(.white.opacity(IslandInk.secondary + 0.05))
                        .textRenderer(SurfacingText(progress: textProgress))
                }
                .lineLimit(1)
                .padding(.horizontal, 15)
                .frame(height: NotchShape.dropHeight)
            }
            .opacity(textVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.22), value: textVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .offset(x: dragOffset.width, y: min(0, dragOffset.height))
        .opacity(opacity)
        .gesture(dragGesture)
        .onTapGesture { dismiss() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(notification.title). \(notification.body)")
        .accessibilityAddTraits(.isButton)
        .onChange(of: textVisible) { _, visible in
            guard visible else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                textProgress = 1
            } else {
                textProgress = 0
                withAnimation(.easeOut(duration: 0.65)) { textProgress = 1 }
            }
        }
    }

    /// Fades as it is pushed away, which is the visual stand-in for the haptic you
    /// would get on iOS — there is no public haptic API for a Mac trackpad from a
    /// regular app (NSHapticFeedbackManager only drives Force Touch alignment feedback).
    private var opacity: Double {
        let travel = max(abs(dragOffset.width), abs(min(0, dragOffset.height)))
        return isDismissing ? 0 : Double(max(0.15, 1 - travel / 180))
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                // Rubber-band downward drags: the card lives at the top of the screen,
                // pulling it further down should feel resisted, not free.
                var translation = value.translation
                if translation.height > 0 { translation.height *= 0.25 }
                dragOffset = translation
            }
            .onEnded { value in
                let horizontalFlick = abs(value.predictedEndTranslation.width) > velocityThreshold
                let upwardFlick = value.predictedEndTranslation.height < -velocityThreshold
                let dragged = abs(value.translation.width) > distanceThreshold
                    || value.translation.height < -distanceThreshold

                if horizontalFlick || upwardFlick || dragged {
                    dismiss(direction: value.predictedEndTranslation)
                } else {
                    withAnimation(NotchRootView.spring) { dragOffset = .zero }
                }
            }
    }

    private func dismiss(direction: CGSize? = nil) {
        guard !isDismissing else { return }
        isDismissing = true

        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            if let direction, abs(direction.width) >= abs(direction.height) {
                dragOffset = CGSize(width: direction.width > 0 ? 420 : -420, height: 0)
            } else {
                dragOffset = CGSize(width: 0, height: -160)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: onDismiss)
    }
}

// MARK: - Surfacing text

/// Text that rises into place from below like liquid surfacing: letters come up out
/// of a blur one after another, left to right, line by line, overshoot a touch and settle.
/// Works on the laid-out glyphs, so wrapping and truncation are unaffected.
private struct SurfacingText: TextRenderer, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    private let rise: CGFloat = 10

    var displayPadding: EdgeInsets {
        EdgeInsets(top: 4, leading: 4, bottom: rise + 4, trailing: 4)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for (index, line) in layout.enumerated() {
            let width = max(1, line.typographicBounds.rect.width)
            for run in line {
                for glyph in run {
                    let across = (glyph.typographicBounds.rect.minX - line.typographicBounds.rect.minX) / width
                    let start = Double(across) * 0.62 + Double(index) * 0.1
                    let local = min(1, max(0, (progress - start) / 0.38))
                    guard local > 0 else { continue }

                    // Rises slightly past its resting place, then drops back.
                    let back = 1.70158
                    let t = local - 1
                    let eased = t * t * ((back + 1) * t + back) + 1

                    var copy = context
                    copy.opacity = min(1, local * 1.6)
                    copy.translateBy(x: 0, y: rise * CGFloat(1 - eased))
                    if local < 1 {
                        copy.addFilter(.blur(radius: 3.5 * CGFloat(1 - local)))
                    }
                    copy.draw(glyph)
                }
            }
        }
    }
}

// MARK: - Notch inset environment

/// Height of the strip occupied by the camera housing. Views that render text below
/// the notch read this instead of hard-coding 32 pt, so a virtual notch and a real
/// one lay out identically.
private struct NotchTopInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 32
}

extension EnvironmentValues {
    var notchTopInset: CGFloat {
        get { self[NotchTopInsetKey.self] }
        set { self[NotchTopInsetKey.self] = newValue }
    }
}
