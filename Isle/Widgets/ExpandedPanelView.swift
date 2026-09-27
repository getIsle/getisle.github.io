//
//  ExpandedPanelView.swift
//  Isle
//
//  The full widget surface. Laid out as:
//
//      ┌──────────────┬────────────┬──────────────┐  ← header row, exactly as tall as
//      │  focus/state │  [housing] │  battery, BT │    the notch, so nothing is drawn
//      ├──────────────┴────────────┴──────────────┤    under the camera
//      │            Now Playing                   │
//      │            (optional) audio device row    │
//      └──────────────────────────────────────────┘
//

import SwiftUI

struct ExpandedPanelView: View {

    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        Group {
            if viewModel.usesSplitLayout {
                splitPanel
            } else if preferences.nowPlayingEnabled {
                // The player owns the whole panel: it puts artwork in the left gutter
                // beside the housing and status in the right one, so a separate header
                // row would both duplicate the status and shove the artwork down.
                NowPlayingWidget(
                    viewModel: viewModel,
                    preferences: preferences,
                    // Nothing loaded → the same player, in its "Not Playing" state.
                    media: isShowingPlayer ? (viewModel.nowPlaying ?? .empty) : .empty
                )
                .padding(.horizontal, NowPlayingWidget.horizontalPadding)
                .padding(.bottom, 16)
            } else {
                VStack(spacing: 8) {
                    header
                    idleBody
                    calendarStrip
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 13)
            }
        }
        .foregroundStyle(.white)
    }

    /// Music | agenda, divided down the middle under the housing.
    private var splitPanel: some View {
        let padding = NowPlayingWidget.horizontalPadding
        let divider: CGFloat = 20
        let column = (viewModel.expandedSize.width - padding * 2 - divider) / 2

        return HStack(alignment: .top, spacing: 0) {
            NowPlayingWidget(
                viewModel: viewModel,
                preferences: preferences,
                media: isShowingPlayer ? (viewModel.nowPlaying ?? .empty) : .empty,
                compact: true
            )
            .frame(width: column)

            // Hairline divider that starts below the housing, never under it.
            VStack(spacing: 0) {
                Color.clear.frame(height: viewModel.metrics.notchSize.height + 10)
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 0.5)
            }
            .frame(width: divider)

            AgendaView(viewModel: viewModel)
                .frame(width: column)
        }
        .padding(.horizontal, padding)
        .padding(.bottom, 16)
    }

    /// Up Next row, below a hairline, when the Calendar widget is on.
    @ViewBuilder
    private var calendarStrip: some View {
        if viewModel.showsCalendarStrip {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 0.5)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                UpNextView(viewModel: viewModel)
            }
            .padding(.horizontal, -6)   // let the hover highlight reach the text edge
        }
    }

    // MARK: Header (flanks the housing)

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                focusChip
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            // Reserve the housing plus a little clearance either side. (This used to
            // be 24 pt *narrower* than the notch, which let chips slide under it.)
            Color.clear
                .frame(width: viewModel.metrics.notchSize.width + 12)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                // Hidden while the player is up: the output button in the transport
                // row already names the device, and the header strip either side of
                // the housing is far too narrow to carry both.
                if preferences.bluetoothEnabled, !isShowingPlayer, let device = primaryAudioDevice {
                    BluetoothChip(device: device)
                        .transition(.opacity)
                }
                if preferences.batteryEnabled, let battery = viewModel.battery, battery.isNoteworthy {
                    BatteryChip(battery: battery)
                        .transition(.opacity)
                }
                pinIndicator
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: viewModel.metrics.notchSize.height)
        .animation(NotchRootView.contentSpring, value: viewModel.battery)
        .animation(NotchRootView.contentSpring, value: viewModel.audioDevices)
    }

    @ViewBuilder
    private var focusChip: some View {
        if preferences.focusEnabled, viewModel.focus.isActive {
            HStack(spacing: 4) {
                Image(systemName: viewModel.focus.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                Text(viewModel.focus.name)
                    .font(.islandChip)
                    .lineLimit(1)
            }
            .foregroundStyle(.purple.opacity(0.95))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                Capsule(style: .continuous).fill(Color.white.opacity(0.08))
            )
        } else {
            Text("Isle")
                .font(.islandChip)
                .foregroundStyle(.white.opacity(IslandInk.quaternary))
        }
    }

    private var pinIndicator: some View {
        Button {
            viewModel.togglePin()
        } label: {
            Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(viewModel.isPinned ? 0.9 : 0.3))
                .rotationEffect(.degrees(viewModel.isPinned ? 0 : 30))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(viewModel.isPinned ? "Unpin the island" : "Keep the island open")
    }

    // MARK: Main body

    /// Nothing playing: reuse the space for the device detail that would otherwise
    /// never have room to appear.
    @ViewBuilder
    private var idleBody: some View {
        VStack(spacing: 10) {
            NowPlayingIdleView(viewModel: viewModel, preferences: preferences)

            if preferences.bluetoothEnabled,
               let device = primaryAudioDevice,
               device.batteryCombined != nil || device.batteryLeft != nil {
                Divider().overlay(Color.white.opacity(0.08))
                BluetoothDeviceRow(device: device)
            }
            Spacer(minLength: 0)
        }
    }

    private var isShowingPlayer: Bool {
        preferences.nowPlayingEnabled && !(viewModel.nowPlaying?.isEmpty ?? true)
    }

    private var primaryAudioDevice: BluetoothDeviceInfo? {
        viewModel.audioDevices.first { $0.isConnected && $0.isAudioDevice }
            ?? viewModel.audioDevices.first { $0.isConnected }
    }
}
