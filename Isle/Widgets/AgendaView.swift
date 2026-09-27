//
//  AgendaView.swift
//  Isle
//
//  Right half of the split ("Side by side") panel: today's agenda.
//
//      ┌───────── music ─────────┬──[housing]──┬──── agenda ─────┐
//      │ [art]                   │             │          Fri 25 │ ← right gutter
//      │       Tum Se            │             │ ▌ Design review │ ← below housing
//      │       Samuel & Akanksha │             │ ▌ 10:30 · 12 min│
//      │ 1:28 ▬▬▬▬▬▬▬▬▬▬ -2:47  │             │ ▌ Standup       │
//      │    ◀◀    ❚❚    ▶▶     │             │ ▌ 14:00 – 14:15 │
//      └─────────────────────────┴─────────────┴─────────────────┘
//
//  Same rules as the player: only the date sits level with the camera (in the
//  right gutter, like the player's status row); everything else starts below the
//  housing. Same type scale, same ink levels, same Join button as Up Next.
//

import AppKit
import SwiftUI

struct AgendaView: View {

    @ObservedObject var viewModel: NotchViewModel

    /// How many events fit under the date in the fixed-height panel.
    private let maxRows = 3

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .padding(.top, NowPlayingWidget.artworkTop)
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            dateHeader(now: now)
                .frame(height: 16)
                .frame(maxWidth: .infinity, alignment: .trailing)

            // Drop the list below the camera housing, whatever its depth.
            Color.clear.frame(height: max(4, viewModel.metrics.notchSize.height + 6 - NowPlayingWidget.artworkTop - 16))

            let events = Array(viewModel.upcomingEvents.filter { $0.end > now }.prefix(maxRows))
            if events.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(events) { event in
                        AgendaRow(event: event, now: now)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// "Fri 25", weekday in the calendar-red Apple uses for today.
    private func dateHeader(now: Date) -> some View {
        HStack(spacing: 4) {
            Text(now.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.islandChip)
                .foregroundStyle(Color(red: 1, green: 0.27, blue: 0.23))
            Text(now.formatted(.dateTime.day()))
                .font(.islandChip)
                .foregroundStyle(.white)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 18, weight: .medium))
            Text("No more events today")
                .font(.islandBody)
        }
        .foregroundStyle(.white.opacity(IslandInk.tertiary))
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }
}

private struct AgendaRow: View {
    let event: CalendarEvent
    let now: Date

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(event.calendarColor)
                .frame(width: 3, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.islandHeadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(timeLine)
                    .font(.islandMicro)
                    .foregroundStyle(.white.opacity(IslandInk.secondary))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let url = event.joinURL, event.start.timeIntervalSince(now) < 10 * 60 {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 20)
                        .background(Capsule(style: .continuous).fill(Color(red: 0.19, green: 0.78, blue: 0.35)))
                }
                .buttonStyle(PressableButtonStyle())
                .help("Join")
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(NotchRootView.contentSpring) { isHovering = inside }
        }
        .onTapGesture { UpNextView.open(event) }
        .help(event.calendarTitle)
    }

    /// Compact version of Up Next's line: "Now · until 11:00", "10:30 · in 12 min",
    /// "Tomorrow · 09:00".
    private var timeLine: String {
        let start = event.start.formatted(date: .omitted, time: .shortened)
        if event.isOngoing(at: now) {
            return "Now · until \(event.end.formatted(date: .omitted, time: .shortened))"
        }
        if !Calendar.current.isDate(event.start, inSameDayAs: now) {
            return "Tomorrow · \(start)"
        }
        if let relative = UpNextView.shortRelative(for: event, now: now) {
            return "\(start) · \(relative)"
        }
        return start
    }
}
