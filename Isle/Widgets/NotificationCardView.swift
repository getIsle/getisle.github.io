//
//  NotificationCardView.swift
//  Isle
//
//  A notification rendered inside the island, with a velocity-aware swipe-to-dismiss
//  gesture. Flick it sideways or up toward the notch and it goes away; a slow, short
//  drag springs back.
//

import SwiftUI

struct NotificationCardView: View {

    let notification: NotchNotification
    let onDismiss: () -> Void

    /// Reserve the strip the camera housing sits in so text never lands under it.
    @Environment(\.notchTopInset) private var topInset

    @State private var dragOffset: CGSize = .zero
    @State private var isDismissing = false

    /// Past this much travel we dismiss regardless of speed.
    private let distanceThreshold: CGFloat = 62
    /// A flick: `predictedEndTranslation` is SwiftUI's built-in velocity projection.
    private let velocityThreshold: CGFloat = 160

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            icon

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(notification.title)
                        .font(.islandHeadline)
                        .lineLimit(1)
                    if let appName = notification.appName {
                        Text(appName)
                            .font(.islandMicro)
                            .foregroundStyle(.white.opacity(IslandInk.quaternary))
                            .lineLimit(1)
                    }
                }
                Text(notification.body)
                    .font(.islandBody)
                    .foregroundStyle(.white.opacity(IslandInk.secondary + 0.05))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        // +6 so the icon and title never touch the housing's bottom edge.
        .padding(.top, topInset + 6)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .offset(x: dragOffset.width, y: min(0, dragOffset.height))
        .opacity(opacity)
        .gesture(dragGesture)
        .onTapGesture { dismiss() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(notification.title). \(notification.body)")
        .accessibilityAddTraits(.isButton)
    }

    private var icon: some View {
        Group {
            if let image = notification.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(notification.accent.opacity(0.22))
                    .overlay(
                        Image(systemName: notification.symbolName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(notification.accent)
                    )
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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
