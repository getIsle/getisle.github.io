//
//  NotchRootView.swift
//  Isle
//
//  The whole island, top to bottom. The window behind this view is a large static
//  transparent canvas; everything you see is this one shape changing size.
//

import SwiftUI

struct NotchRootView: View {

    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var preferences: Preferences

    /// The island's *drawn* size. Width and height are driven separately (see
    /// `animateSize`) instead of animating `viewModel.contentSize` as one value.
    @State private var islandWidth: CGFloat = 0
    @State private var islandHeight: CGFloat = 0
    @State private var hasSized = false

    /// The house spring. Used for every size, corner and content change so the whole
    /// app feels like one physical object. Never use a linear/easeInOut curve here.
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.8)

    /// Opening: a touch of overshoot so the island "pops" out of the housing like the
    /// iPhone's Dynamic Island. Closing: critically damped, so it tucks back in without
    /// wobbling against the bezel. One symmetric spring for both directions is a big
    /// part of why an overlay feels like a web animation instead of hardware.
    static let openSpring = Animation.spring(response: 0.48, dampingFraction: 0.78)
    static let closeSpring = Animation.spring(response: 0.36, dampingFraction: 0.94)

    /// The hover lift: fast and a little bouncy, like a button coming up to meet
    /// the pointer. Settling back is quicker and flat.
    static let hoverInSpring = Animation.spring(response: 0.28, dampingFraction: 0.6)
    static let hoverOutSpring = Animation.spring(response: 0.3, dampingFraction: 0.9)

    /// A touch snappier, for content swapping inside an already-open island.
    static let contentSpring = Animation.spring(response: 0.28, dampingFraction: 0.85)

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The canvas must never eat events on its own; NotchHostingView handles that,
        // but this makes the intent explicit for previews too.
        .background(Color.clear)
    }

    // MARK: - The island

    private var shape: NotchShape {
        NotchShape(
            style: viewModel.style,
            topRadius: viewModel.topCornerRadius,
            bottomRadius: viewModel.bottomCornerRadius
        )
    }

    private var island: some View {
        ZStack(alignment: .top) {
            content
            // Above the content and outside its transitions, so the cover moves
            // continuously with the shape instead of fading between two copies.
            IslandArtworkLayer(viewModel: viewModel, preferences: preferences)
        }
        .frame(
            width: hasSized ? islandWidth : viewModel.contentSize.width,
            height: hasSized ? islandHeight : viewModel.contentSize.height,
            alignment: .top
        )
        // Clip the *content* to the silhouette. `clipShape` clips to the path, not to
        // the frame, so the concave flares that overhang the frame survive.
        .clipShape(shape)
        .background(
            shape
                .fill(Color.black)
                // A hairline edge only once the island has left the bezel; on a real
                // notch a border in the collapsed state would be visible as a seam.
                // Never on the merged style: its path runs along the top edge of the
                // screen, and a stroke there shows up as a grey line on the bezel.
                .overlay(
                    shape
                        .stroke(Color.white.opacity(showsEdgeHighlight ? 0.07 : 0), lineWidth: 0.5)
                )
                // Two layers, like a real lifted object: a tight contact shadow
                // right under the edge, and a wide soft one that sets it off the
                // wallpaper. A single shadow is either invisible or muddy.
                .shadow(
                    color: .black.opacity(shadowStrength * 0.35),
                    radius: 3 * shadowStrength,
                    x: 0,
                    y: 2 * shadowStrength
                )
                .shadow(
                    color: .black.opacity(shadowStrength * 0.55),
                    radius: 26 * shadowStrength,
                    x: 0,
                    y: 12 * shadowStrength
                )
                // A whisper of the accent colour bleeding out from under the island,
                // which is what stops a pure-black pill reading as a dead rectangle.
                .shadow(
                    color: glowColor.opacity(showsEdgeHighlight ? 0.14 : 0),
                    radius: showsEdgeHighlight ? 18 : 0,
                    x: 0,
                    y: 2
                )
        )
        // A plain rectangle, not the silhouette: the path's top edge sits exactly on
        // the screen edge, and a point on a path's boundary can test as outside,
        // which made clicks with the pointer pinned to the top of the screen miss.
        .contentShape(Rectangle())
        // Click opens. A click on an already-open panel does nothing, so tapping
        // empty space between controls never slams it shut.
        .onTapGesture { viewModel.openFromClick() }
        // Full screen: fold up into the housing — squeeze towards the top edge,
        // blur and fade — rather than blinking out. Reversed on the way back.
        .scaleEffect(
            x: viewModel.isSuppressed ? 0.7 : 1,
            y: viewModel.isSuppressed ? 0.3 : 1,
            anchor: .top
        )
        .blur(radius: viewModel.isSuppressed ? 8 : 0)
        .opacity(viewModel.isSuppressed ? 0 : 1)
        .animation(
            viewModel.isSuppressed
                ? .spring(response: 0.34, dampingFraction: 0.95)
                : .spring(response: 0.46, dampingFraction: 0.8),
            value: viewModel.isSuppressed
        )
        // The floating style hangs a few points below the top edge on displays that
        // have no camera housing in the way.
        .padding(.top, viewModel.topInset)
        // Corner radii, shadow and flares follow the presentation; the frame itself
        // is driven by `animateSize`.
        .animation(shapeSpring, value: viewModel.presentation)
        .animation(shapeSpring, value: viewModel.isHoverLifted)
        .animation(Self.spring, value: viewModel.metrics)
        .onAppear {
            islandWidth = viewModel.contentSize.width
            islandHeight = viewModel.contentSize.height
            hasSized = true
        }
        .onChange(of: viewModel.contentSize) { _, newSize in
            animateSize(to: newSize)
        }
        // Widgets below the housing need to know how much room the camera steals.
        .environment(\.notchTopInset, viewModel.metrics.notchSize.height)
    }

    /// Only a full panel gets a hairline edge. On the small capsule any border reads
    /// as a seam and kills the "solid object" illusion.
    /// 0 when collapsed (on real hardware the housing casts no shadow), a hint while
    /// peeking, full strength once the island is a panel.
    private var shadowStrength: CGFloat {
        switch viewModel.presentation {
        case .collapsed: return 0
        case .peek: return 0.35
        case .notification: return 0.85
        case .expanded: return 1
        }
    }

    /// The core of the "native" feel. The iPhone's Dynamic Island does not scale
    /// uniformly: opening, it widens first and then drops down with a little
    /// overshoot, so it reads as the pill *pouring* out of the housing. Closing
    /// runs the other way: it pulls up first, then tucks in sideways. Two
    /// separate springs, in separate transactions, give exactly that.
    private func animateSize(to size: CGSize) {
        switch viewModel.motion {
        case .open:
            withAnimation(.spring(response: 0.4, dampingFraction: 0.84)) {
                islandWidth = size.width
            }
            withAnimation(.spring(response: 0.52, dampingFraction: 0.72).delay(0.035)) {
                islandHeight = size.height
            }

        case .close:
            withAnimation(.spring(response: 0.32, dampingFraction: 0.95)) {
                islandHeight = size.height
            }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.92).delay(0.05)) {
                islandWidth = size.width
            }

        case .hoverIn:
            withAnimation(Self.hoverInSpring) {
                islandWidth = size.width
                islandHeight = size.height
            }

        case .hoverOut:
            withAnimation(Self.hoverOutSpring) {
                islandWidth = size.width
                islandHeight = size.height
            }
        }
    }

    private var shapeSpring: Animation {
        switch viewModel.motion {
        case .open: return Self.openSpring
        case .close: return Self.closeSpring
        case .hoverIn: return Self.hoverInSpring
        case .hoverOut: return Self.hoverOutSpring
        }
    }

    private var showsEdgeHighlight: Bool {
        guard viewModel.style == .floating, viewModel.topInset > 0 else { return false }
        switch viewModel.presentation {
        case .expanded, .notification: return true
        case .collapsed, .peek: return false
        }
    }

    /// Tinted by the artwork when there is some, so the bloom under the island picks
    /// up the album's colour the way the real Dynamic Island does.
    private var glowColor: Color {
        viewModel.artworkTint ?? preferences.accentColor
    }

    // MARK: - Content per state

    @ViewBuilder
    private var content: some View {
        switch viewModel.presentation {
        case .collapsed:
            collapsedContent

        case .peek:
            PeekContentView(viewModel: viewModel, preferences: preferences)
                .transition(.islandContent)

        case .notification:
            notificationContent
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
                    )
                )

        case .expanded:
            ExpandedPanelView(viewModel: viewModel, preferences: preferences)
                .transition(.islandContent)
        }
    }

    /// Nothing at all on real hardware — the collapsed island *is* the camera housing.
    /// On a virtual notch we keep it plain black too so the two behave identically.
    private var collapsedContent: some View {
        Color.clear
    }

    @ViewBuilder
    private var notificationContent: some View {
        if let notification = viewModel.currentNotification {
            NotificationCardView(
                notification: notification,
                onDismiss: { viewModel.dismissCurrentNotification() }
            )
            .id(notification.id)
        }
    }
}

// MARK: - Content transition

/// How content enters and leaves the island.
///
/// The Dynamic Island never cross-fades two layouts on top of each other. The old
/// content blurs away almost immediately, the shape morphs, and the new content
/// resolves out of a blur slightly behind the shape — so the silhouette leads and the
/// content follows. A plain `.opacity` transition leaves both layouts visible at 50%
/// mid-animation, which is the "mushy" look.
private struct IslandContentModifier: ViewModifier {
    var blur: CGFloat
    var opacity: Double
    var scale: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .opacity(opacity)
            .scaleEffect(scale, anchor: .top)
    }
}

extension AnyTransition {
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: IslandContentModifier(blur: 10, opacity: 0, scale: 0.92),
                identity: IslandContentModifier(blur: 0, opacity: 1, scale: 1)
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.85).delay(0.07)),
            removal: .modifier(
                active: IslandContentModifier(blur: 8, opacity: 0, scale: 0.96),
                identity: IslandContentModifier(blur: 0, opacity: 1, scale: 1)
            )
            .animation(.easeOut(duration: 0.14))
        )
    }
}
