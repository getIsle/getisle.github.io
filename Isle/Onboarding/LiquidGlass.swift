//
//  LiquidGlass.swift
//  Isle
//
//  Liquid Glass (macOS 26) with graceful fallbacks, so the same views build for
//  the macOS 15 deployment target:
//
//   • macOS 26+  → SwiftUI `.glassEffect`, `.buttonStyle(.glass/.glassProminent)`
//                  and AppKit `NSGlassEffectView` behind the whole window.
//   • macOS 15   → `.ultraThinMaterial` and `NSVisualEffectView`, which is the
//                  closest older look.
//
//  Building needs the macOS 26 SDK (Xcode 26 or later).
//

import AppKit
import SwiftUI

extension View {

    /// A piece of Liquid Glass in `shape`. `tint` colours the glass (for icon
    /// tiles); `interactive` makes it react to the pointer like a control.
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Self.makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background(shape.fill((tint ?? .clear).opacity(0.55)))
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 0.5))
        }
    }

    @available(macOS 26.0, *)
    private static func makeGlass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }

    /// Main call-to-action: prominent (tinted) glass on macOS 26.
    @ViewBuilder
    func glassPrimaryButton(compact: Bool = false, large: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self
                .buttonStyle(.glassProminent)
                .tint(Color(red: 0.40, green: 0.45, blue: 1.0))
                .controlSize(compact ? .small : (large ? .large : .regular))
        } else {
            self.buttonStyle(OnboardingPrimaryButtonStyle(compact: compact, large: large))
        }
    }

    /// Secondary action: clear glass on macOS 26.
    @ViewBuilder
    func glassSecondaryButton(compact: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .controlSize(compact ? .small : .regular)
        } else {
            self.buttonStyle(OnboardingSecondaryButtonStyle(compact: compact))
        }
    }
}

/// Groups nearby glass shapes so they blend and morph into each other like
/// one material (macOS 26); a plain container before that.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// The window's own backdrop: real Liquid Glass over the desktop on macOS 26,
/// a behind-window blur before that.
struct WindowGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.tintColor = NSColor(red: 0.06, green: 0.07, blue: 0.14, alpha: 0.55)
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        return blur
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
