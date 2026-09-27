//
//  MarqueeText.swift
//  Isle
//
//  Horizontally scrolling text for metadata that will not fit. Only scrolls when it
//  actually overflows — a short artist name stays put rather than drifting, which is
//  the detail that separates this from a ticker.
//
//  When it does scroll, both edges fade out (like Apple Music and the Alcove
//  reference) instead of the text being hard-clipped at the container edge.
//

import SwiftUI

struct MarqueeText: View {
    let text: String
    var font: Font
    var color: Color

    /// Blank space between the end of one pass and the start of the next.
    private let gap: CGFloat = 40
    /// Points per second. Slow enough to read, fast enough not to feel stuck.
    private let speed: CGFloat = 26
    /// Pause before a scroll cycle begins, so the start is readable.
    private let settle: Double = 1.4
    /// Width of the soft fade at each edge while scrolling.
    private let fade: CGFloat = 12

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var animate = false

    private var overflows: Bool { textWidth > containerWidth + 1 }

    var body: some View {
        GeometryReader { proxy in
            let content = Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()

            ZStack(alignment: .leading) {
                if overflows {
                    HStack(spacing: gap) {
                        content
                        content          // second copy makes the wrap seamless
                    }
                    .offset(x: animate ? -(textWidth + gap) : 0)
                    .animation(
                        .linear(duration: Double((textWidth + gap) / speed))
                            .delay(settle)
                            .repeatForever(autoreverses: false),
                        value: animate
                    )
                } else {
                    content
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .clipped()
            .mask(edgeFade(width: proxy.size.width))
            // Measure the real rendered width with the real font, rather than
            // re-deriving it from a hard-coded NSFont that drifts out of sync.
            .background(
                content
                    .hidden()
                    .background(
                        GeometryReader { textProxy in
                            Color.clear
                                .onAppear { textWidth = textProxy.size.width }
                                .onChange(of: textProxy.size.width) { _, new in textWidth = new }
                        }
                    )
            )
            .onAppear {
                containerWidth = proxy.size.width
                // Kick the animation on the next runloop turn; starting it inside the
                // same update as the measurement makes SwiftUI skip the transition.
                DispatchQueue.main.async { animate = true }
            }
            .onChange(of: proxy.size.width) { _, new in containerWidth = new }
            .onChange(of: text) { _, _ in
                animate = false
                DispatchQueue.main.async { animate = true }
            }
        }
    }

    @ViewBuilder
    private func edgeFade(width: CGFloat) -> some View {
        if overflows, width > fade * 2 {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: fade)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: fade)
            }
        } else {
            Color.black
        }
    }
}
