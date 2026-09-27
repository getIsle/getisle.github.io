//
//  Visualizer.swift
//  Isle
//
//  The little dancing bars that sit on the right-hand side of the housing while
//  music is playing. There is no public API for real audio taps without a driver or
//  a screen/audio-capture permission prompt, so these are decorative: a set of bars
//  on out-of-phase springs. Alcove's are the same.
//

import SwiftUI

struct AudioBarsView: View {
    var isAnimating: Bool
    var tint: Color
    var barCount: Int = 4
    var barWidth: CGFloat = 2.5
    var maxHeight: CGFloat = 14

    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: barWidth) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: barWidth, height: height(for: index, at: t))
                }
            }
            .frame(height: maxHeight, alignment: .center)
        }
    }

    private func height(for index: Int, at time: TimeInterval) -> CGFloat {
        guard isAnimating else { return barWidth }
        // Prime-ish frequency offsets keep the bars from ever syncing up, which is
        // what makes the motion read as "audio" instead of "loading spinner".
        let speeds: [Double] = [3.1, 4.3, 2.7, 3.7, 4.9, 2.3]
        let offsets: [Double] = [0.0, 1.2, 2.4, 0.7, 1.9, 3.1]
        let speed = speeds[index % speeds.count]
        let offset = offsets[index % offsets.count]
        let wave = (sin(time * speed + offset) + 1) / 2          // 0...1
        return barWidth + CGFloat(wave) * (maxHeight - barWidth)
    }
}

/// Thin capsule meter used for playback progress and battery level.
struct MeterBar: View {
    var value: Double        // 0...1
    var tint: Color
    var height: CGFloat = 3
    var trackOpacity: Double = 0.18

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(trackOpacity))
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: max(0, min(1, value)) * proxy.size.width)
            }
        }
        .frame(height: height)
    }
}

/// Circular progress used in the peeked capsule, where a horizontal bar would fight
/// the capsule's own geometry.
struct ProgressRing: View {
    var value: Double        // 0...1
    var tint: Color
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(NotchRootView.contentSpring, value: value)
    }
}
