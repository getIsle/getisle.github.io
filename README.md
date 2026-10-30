# Isle

A Dynamic Island for the Mac notch — a borderless, always-on-top overlay pinned to
the top-centre of your display that collapses into the notch, peeks when something
happens, and expands into a widget panel on hover.

Built entirely in Swift/SwiftUI + AppKit. Menu bar agent app (`LSUIElement`), no Dock
icon. Targets **macOS 15 Sequoia or later**, Apple Silicon.

---

## Build and run

```bash
open Isle.xcodeproj
```

Then ⌘R. That is the whole setup — no package resolution, no signing configuration.

The project is configured to **ad-hoc sign** (`CODE_SIGN_IDENTITY = "-"`, manual
signing, empty team) so it builds and runs on any machine without a developer
account. See [Signing and distribution](#signing-and-distribution) before you try to
share the build with anyone else.

From the command line:

```bash
xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Debug build
```

The Xcode project uses a **file-system-synchronized group** (Xcode 16+), so any `.swift`
file you drop into `Isle/` is picked up automatically — you never have to add files to
the target by hand.

---

## First launch

A welcome window walks through five short steps (`Isle/Onboarding/`):

1. **Welcome** — with a live miniature of the island.
2. **Move to Applications** — one click copies Isle into /Applications, reopens it
   from there and resumes the flow. Needed for launch at login. Skipped if Isle is
   already installed.
3. **Permissions** — Calendar, Notifications, Focus, and the Command Line Tools for
   system-wide Now Playing. Each is requested only when its button is pressed, or
   all at once with **Allow All**, which asks one after another and says up front
   how many macOS pop-ups to expect. The Command Line Tools row ticks itself when
   Apple's installer finishes.
4. **Make it yours** — launch at login, open on hover, hide in full screen, calendar.
5. **Ready** — then the island itself says hello.

No monitors start (so no permission prompts appear) until the flow is finished or
closed. Reopen it any time from the menu bar: **Welcome Guide…**

## Updating and reinstalling

Open the new version however you like: Isle sorts it out.

- **Only one Isle runs at a time** (`App/InstallGuard.swift`). The copy you just
  opened quits any older copy that is still running; if a *newer* copy is already
  running, the one you opened steps aside instead.
- **Opened from the disk image or Downloads?** If you've already been through the
  welcome guide, Isle asks once: *Update Isle to version X?* One click replaces the
  copy in Applications (the old one goes to the Trash), keeps your settings and
  reopens. Tick *Don't ask again* to keep running it from elsewhere.
- **Dragged the new version over the old one while it was running?** Opening it
  again restarts into the new version, instead of just waking the old process.
- **Settings are kept** — they live in `UserDefaults` under the bundle identifier,
  not inside the app.
- **Permissions may be asked again.** An ad-hoc signed build gets a new code
  signature every time, so macOS may treat an update as a new app and ask for
  Calendar (or Automation) once more. Signing with a Developer ID keeps the same
  identity across updates, so the grants carry over. See
  [Signing and distribution](#signing-and-distribution).

## What it does

| State | Looks like | Trigger |
|---|---|---|
| **Collapsed** | Exactly the notch. Invisible on notched hardware. | Default |
| **Peek** | A short capsule flanking the camera housing — round album art on one side, audio bars on the other | Something is playing, or a HUD event fired |
| **Notification** | A card hanging below the notch, swipe-to-dismiss | An incoming notification card |
| **Expanded** | Full widget panel: Now Playing with transport controls, battery, Bluetooth, Focus | Hover, or click to pin |

Everything animates on one spring (`response: 0.35, dampingFraction: 0.8`). The peek
accessories slide out from *behind* the housing rather than fading in on top of it,
which is what makes the motion read as native.

### Shape

Two styles, in **Settings ▸ Appearance**:

- **Floating capsule** (default) — square top corners where the island meets the top
  edge, fully rounded bottom. Square-topped deliberately: rounding a corner that
  touches the bezel makes the island read as a separate window hovering over the
  screen instead of part of the hardware.
- **Merged with the bezel** — adds *concave* shoulders so the shape appears carved
  out of the bezel. Only makes sense on a display that actually has a notch.

There is also a **Detach from the top edge** toggle. It floats the capsule clear of
the bezel, which looks great on a display with no notch. On notched hardware leave it
off: the camera housing is a physical black cutout running to the very top of the
panel, so a gap leaves the housing visible as a dark tab above the capsule.

### No notch? Still works

`NSScreen.safeAreaInsets.top > 0` detects a real notch, and
`auxiliaryTopLeftArea`/`auxiliaryTopRightArea` give its exact width. On any other
display Isle draws a **virtual notch** of the same proportions, and every state and
animation behaves identically.

---

## Permissions to grant

Isle asks for as little as it can, and every widget degrades gracefully if you say no.

| Permission | Asked when | What breaks without it |
|---|---|---|
| **Notifications** | First launch | Isle's own local notifications. The URL / distributed-notification ingress still works. |
| **Focus** (`INFocusStatusCenter`) | First launch, if the Focus widget is on | The Focus badge. Prompt text lives in `NSFocusStatusUsageDescription`. |
| **Calendars** | First launch, if the Calendar widget is on | The Up Next row and meeting reminders. Fix in Privacy & Security ▸ Calendars. |
| **Automation** (Apple Events) | First time Isle queries each media app | Now Playing. macOS prompts once per app. |
| **“Allow JavaScript from Apple Events”** | Never prompted — you must turn it on | Now Playing **from browsers only**. See below. |
| **Full Disk Access** | Never asked — grant manually if you want it | The *name* of the active Focus ("Work" vs. just "Focus"). See below. |

### Browsers need one manual toggle

Safari and Chrome refuse `do JavaScript` from Apple Events until you opt in. Isle
detects this precisely and tells you in **Settings ▸ Integration**; the raw error is:

> Safari got an error: You must enable 'Allow JavaScript from Apple Events' in the
> Developer section of Safari Settings to use 'do JavaScript'. (8)

- **Safari** — Settings ▸ Advanced ▸ tick *Show features for web developers*, then
  Develop ▸ **Allow JavaScript from Apple Events**.
- **Chrome** — View ▸ Developer ▸ **Allow JavaScript from Apple Events**.

Music and Spotify need only the Automation prompt, not this.

**Accessibility is not required.** Isle tracks hover with `NSEvent` global mouse-moved
monitors, which need no permission — only keyboard event monitoring does. If anything
ever asks you for Accessibility on Isle's behalf, something is wrong.

**Bluetooth** does not prompt either: Isle uses classic `IOBluetooth` connection
notifications and read-only IORegistry lookups, not CoreBluetooth scanning. The
`NSBluetoothAlwaysUsageDescription` key is present for completeness.

---

## MediaRemote is a private framework

`Services/MediaRemoteBridge.swift` talks to
`/System/Library/PrivateFrameworks/MediaRemote.framework`. This is not a public API.
Consequences, in order of how much they will bite you:

- **Mac App Store: impossible.** Instantly rejected. Do not submit this as-is.
- **Developer ID + notarisation: fine.** Notarisation does not scan for private
  framework use. Sign with a Developer ID certificate and run it locally or
  distribute it directly.
- **Hardened Runtime** requires `com.apple.security.cs.disable-library-validation`
  (already in `Config/Isle.entitlements`), or `dlopen()` is refused at runtime.
- **The App Sandbox is impossible**, and is switched off in the entitlements. The
  sandbox blocks the mach lookups MediaRemote performs, IORegistry reads, and the
  `~/Library/DoNotDisturb` watch.
- **It can break on any macOS update.** macOS 15.4 restricted these APIs to
  Apple-signed callers on some configurations.

Everything is resolved with `dlopen`/`dlsym` rather than by linking, so a missing or
changed framework degrades to "no media source" instead of crashing on launch.

### It does NOT work on current macOS — verify this yourself before trusting it

Measured on macOS 27 (Tahoe): `MRMediaRemoteGetNowPlayingInfo` invokes its callback
with a **nil dictionary** for a compiled app, whether ad-hoc signed, signed without
entitlements, or signed with them.

There is a trap here that costs an afternoon. Testing with

```bash
swift probe.swift      # ← appears to work perfectly, full metadata + artwork
```

succeeds, because the process is Apple's *signed* `swift` interpreter hosting your
code. Compile the identical source and it returns nil:

```bash
swiftc probe.swift -o probe && ./probe    # ← nil
```

So MediaRemote is kept as an opportunistic first choice (it still works on older
systems, and costs one call to find out), but Isle treats a nil dictionary as normal
and hands over to Apple Events after a 2.5 s grace period.

### Why not `MPRemoteCommandCenter`?

`MPRemoteCommandCenter` / `MPNowPlayingInfoCenter` are public and sandbox-safe, but
they are built for an app that *is* the now-playing app: they let you publish your own
metadata and receive commands for your own playback. They give you no way to read what
Spotify or Safari is playing, which is the entire feature. **There is no public,
system-wide "what is playing" API on macOS.**

### The helper — system-wide Now Playing on current macOS

`Services/MediaRemoteHelperSource.swift` turns the `swift probe.swift` "trap" above
into a feature. Isle writes a small script to
`~/Library/Caches/com.isle.Isle/NowPlayingHelper.swift` and runs it with the
toolchain's `swift` (found via `xcode-select -p`, never the `/usr/bin/swift` shim,
which would pop an install dialog). Because the interpreter is Apple-signed,
MediaRemote answers it. The script streams one JSON line per change on stdout and
takes transport commands on stdin; it exits when Isle does.

That covers **every** app that publishes Now Playing — Music, Spotify, Podcasts,
Safari, Chrome, Arc, Firefox, VLC, IINA… — event-driven, with artwork and no
Automation prompts. It needs Xcode or the Command Line Tools installed. Source order:
in-process MediaRemote → helper → Apple Events. If the helper has not reported a
track within 12 s (usually just because nothing is playing), Apple Events takes over
and the helper stays on standby, taking back over the moment it sees a track.

### Apple Events — the fallback

`AppleScriptMediaSource` covers **Music, Spotify, Safari and Chrome**.

This is not a guess about what shipping apps do. Alcove's own code signature asks for
exactly these exceptions, and no MediaRemote entitlement at all:

```
$ codesign -d --entitlements - /Applications/Alcove.app
  com.apple.security.automation.apple-events            true
  com.apple.security.temporary-exception.apple-events
      com.spotify.client
      com.apple.Music
      com.apple.Safari
      com.google.Chrome
      company.thebrowser.dia
```

- **Music and Spotify** expose real AppleScript dictionaries (`current track`,
  `player position`, `player state`).
- **Safari and Chrome** expose nothing useful, so Isle runs a small JavaScript snippet
  in each tab and reads `navigator.mediaSession.metadata` plus the underlying
  `<video>`/`<audio>` element. That is how YouTube, Spotify Web and SoundCloud get
  picked up, including artwork.

Trade-offs versus MediaRemote: polled at 2 s rather than event-driven, four apps
rather than all of them, and it needs the permissions below. Both backends are
toggleable in **Settings ▸ Integration**, which also shows a live diagnostic of which
source is active and what is blocking it.

---

## Notifications: the real platform limitation

**Isle cannot show other apps' notification banners. Neither can any other
Dynamic-Island-style Mac app.** This is worth being blunt about, because it is the
feature people assume is there.

There is no public API for it, and no usable private one:

- `UNUserNotificationCenter` only ever reports notifications *your own bundle* posted.
  `getDeliveredNotifications` is scoped to the calling app.
- The legacy `NSUserNotificationCenter` is deprecated and equally app-scoped.
- The banners are composited by `NotificationCenter.app` in another process. The
  payloads live in a SQLite store under `DARWIN_USER_DIR` that is TCC-protected;
  reading it needs Full Disk Access and *still* gives you no reliable "a banner is on
  screen right now" signal.
- Accessibility (`AXUIElement`) can scrape the banner window of
  `NotificationCenter.app`. A couple of shipping apps do this. It requires the user to
  grant Accessibility, it breaks on most macOS point releases, and Isle does not do it.

### What Isle implements instead

Everything that genuinely is possible:

**1. Isle's own local notifications** are intercepted in
`userNotificationCenter(_:willPresent:)`, rendered in the notch, and the system banner
is suppressed by returning no presentation options.

**2. A public ingress any script or app can post to.** Two equivalent entry points:

```bash
# URL scheme
open "isle://notify?title=Build%20finished&body=42%20tests%20passed&app=Xcode&symbol=hammer.fill&accent=%2333B86B"
```

```bash
# Distributed notification
osascript -l JavaScript -e '
  $.NSDistributedNotificationCenter.defaultCenter
    .postNotificationNameObjectUserInfoDeliverImmediately(
      "com.isle.Isle.notify", null,
      { title: "Deploy finished", body: "web-prod · 2m 14s", app: "CI", symbol: "checkmark.seal.fill" },
      true)'
```

From Swift:

```swift
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.isle.Isle.notify"),
    object: nil,
    userInfo: ["title": "Hello", "body": "From another app", "symbol": "sparkles"],
    deliverImmediately: true
)
```

**What that covers:** anything you control or can hook — CI, build scripts, Shortcuts,
`launchd` jobs, your own apps, a `git` hook, a long-running command finishing.

**What it does not cover:** Messages, Mail, Slack, Calendar, or any other app you did
not write. Those would have to opt in, and they will not.

### Full scriptable API

| URL | Effect |
|---|---|
| `isle://notify?title=…&body=…&app=…&symbol=…&accent=%23RRGGBB&image=/path.png` | Notification card |
| `isle://hud?title=…&subtitle=…&symbol=…&progress=0.6&duration=3&accent=%23RRGGBB` | Transient peek HUD |
| `isle://expand` / `isle://collapse` / `isle://toggle` | Pin, unpin, flip |
| `isle://demo` / `isle://demo?clear=1` | Fill every widget with sample data, then clear it |

`symbol` is any SF Symbol name. `image` is a file path and overrides `symbol`.

---

## Calendar

`Services/CalendarService.swift` uses EventKit (public API, one prompt). With
music and calendar both on, the expanded island splits in two around the camera:
a compact player on the left, today's agenda on the right (`Widgets/AgendaView.swift`)
— date in the right gutter, up to three events below the housing, each with its
calendar colour, time, and a green **Join** button in the last 10 minutes before a
Zoom/Meet/Teams/Webex/FaceTime call. Clicking an event opens it in Calendar.

The island also peeks with a reminder before an event starts (default 5 minutes,
**Settings ▸ Calendar**) and again when it starts. All-day, cancelled and
declined events are ignored.

## Focus: unofficial, and usually degraded

`Services/FocusMonitor.swift` combines the two partial answers that exist:

1. **`INFocusStatusCenter`** (Intents, macOS 12+) — public, supported, needs user
   consent. Answers exactly one question: is a Focus on, yes or no. It will not tell
   you which one.
2. **`~/Library/DoNotDisturb/DB/{Assertions,ModeConfigurations}.json`** — unofficial.
   These are the files the OS itself uses and they do name the active mode. But:
   - The directory is **TCC-protected**. Without Full Disk Access, opening it fails
     with `EPERM` — confirmed on macOS 27, so this is the normal case, not an edge
     case. Isle detects this and degrades to the boolean from (1).
   - The schema is not contractual and has changed across releases. Every field read
     is optional and guarded.
   - Writes are atomic replacements, so the **directory** is watched with a
     `DispatchSourceFileSystemObject`, not the file — a vnode watch bound to the file
     stops firing after the first change.

Net effect: with Full Disk Access you get "Work" and the right glyph. Without it you
get "Focus". Either way the badge works.

---

## Architecture

```
Isle/
├── App/
│   ├── IsleApp.swift            @main. Owns only the Settings scene.
│   └── AppDelegate.swift        Object graph, URL handling, SettingsOpener.
├── Core/
│   ├── NotchGeometry.swift      Screen/notch detection, virtual notch fallback.
│   ├── NotchShape.swift         Both silhouettes (floating capsule / merged).
│   ├── NotchWindow.swift        NSPanel subclass + click-through hosting view.
│   ├── NotchWindowController.swift  Placement, hover tracking, hit region.
│   ├── NotchViewModel.swift     The state machine. Single source of truth.
│   ├── NotchRootView.swift      The island, top to bottom.
│   ├── NotchModels.swift        Plain value types the services publish.
│   └── ImageColor.swift         Artwork → dominant colour for the glow.
├── Widgets/
│   ├── PeekContentView.swift    Content flanking the housing.
│   ├── ExpandedPanelView.swift  The full widget surface.
│   ├── NowPlayingWidget.swift   Artwork, metadata, transport.
│   ├── BatteryWidget.swift      Chip + HUD factory.
│   ├── BluetoothWidget.swift    Chip, device row, HUD factories.
│   ├── NotificationCardView.swift  Card + velocity-aware swipe dismiss.
│   ├── MarqueeText.swift        Scrolls metadata that overflows.
│   └── Visualizer.swift         Audio bars, meter bar, progress ring.
├── Services/
│   ├── ServiceCoordinator.swift Starts/stops monitors with their toggles.
│   ├── NowPlayingSource.swift   Backend abstraction.
│   ├── MediaRemoteBridge.swift  Private framework, dlopen'd.
│   ├── AppleScriptMediaSource.swift  Public fallback.
│   ├── MediaService.swift       Backend selection + peek decisions.
│   ├── PowerMonitor.swift       IOKit power sources.
│   ├── BluetoothMonitor.swift   IOBluetooth + IORegistry battery.
│   ├── FocusMonitor.swift       INFocusStatusCenter + DND JSON.
│   ├── NotificationRelay.swift  URL + distributed + own notifications.
│   ├── MediaDiagnostics.swift   Explains *why* Now Playing is empty.
│   └── DemoContent.swift        Sample data for isle://demo.
├── Settings/
│   ├── Preferences.swift        UserDefaults store + SMAppService.
│   └── SettingsView.swift       General / Widgets / Appearance / Integration.
└── MenuBar/
    └── MenuBarController.swift  NSStatusItem menu.
```

### Design notes worth knowing before you edit

**The window never resizes.** It is a fixed, oversized, transparent canvas pinned to
the top of the screen; the island grows *inside* it. Animating `NSWindow.setFrame` at
120 Hz is jerky and fights SwiftUI's own animation. The cost is that the window covers
a chunk of the menu bar, which `NotchHostingView.hitTest` undoes by returning `nil`
everywhere except the island's actual rect.

**Hover uses global mouse monitors, not an `NSTrackingArea`.** A tracking area only
fires for a view that can be hit-tested, and the hosting view deliberately refuses
hit-testing outside the island — which would make `mouseEntered` unreachable for the
collapsed pill. Monitors sidestep the circularity and need no permission.

**`presentation` is never assigned from outside.** It is recomputed from the inputs by
`recomputePresentation()`. That kills the classic overlay bug where a peek timer fires
while the pointer is inside and the island collapses out from under the cursor.

**The concave flares of the merged style are drawn outside the frame.** Never clip
that style to its own bounds.

**The corner radius grows with the island, not with its height.** Measured off Alcove
running on notched hardware:

| State | Size | Top radius | Bottom radius |
|---|---|---|---|
| Collapsed | 179×32 (exactly the notch) | 0 | ~10 |
| Hover | 192×37 | 0 | ~11 |
| Panel | ~335×170 | 0 | ~34 |

The top corners are **square in every state**. Using `height / 2` for the small states
turns them into pills, and a pill reads as a floating widget rather than part of the
machine — it is the single biggest thing that makes a notch overlay look wrong.

**Use the gutters either side of the housing.** The notch only occludes the *centre* of
the top strip, so artwork can sit in the left gutter from y≈13 and status chips in the
right one, with only the title and artist pushed below the housing. Pushing every
element below it instead wastes a 32 pt band across the full width and makes the panel
look half empty.

---

## Making a DMG

```bash
./Packaging/make-dmg.sh
```

Builds Release, signs, and writes `dist/Isle-<version>.dmg` — a drag-to-install
window (Isle → arrow → Applications) on Isle's own background, with the app icon
as the volume icon. The first run may ask to let Terminal control Finder; that is
only for arranging the window.

Without a Developer ID the app is ad-hoc signed: it runs on your Mac, but on other
Macs Gatekeeper blocks the first launch — right-click Isle ▸ **Open** once, or
System Settings ▸ Privacy & Security ▸ **Open Anyway**. To sign and notarize:

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./Packaging/make-dmg.sh
```

## Signing and distribution

The project ad-hoc signs so it builds anywhere. For anything beyond your own machine:

1. Set `DEVELOPMENT_TEAM` and switch `CODE_SIGN_STYLE` to `Automatic`.
2. Turn `ENABLE_HARDENED_RUNTIME` on (required for notarisation). The
   `disable-library-validation` entitlement is already there for MediaRemote.
3. Notarise as usual. **Keep the App Sandbox off** — the entitlements set it to
   `false` and the app cannot work with it on.
4. Do not submit to the Mac App Store. See above.

`SMAppService.mainApp.register()` (the launch-at-login toggle) can fail if the app is
still quarantined in `~/Downloads`. Move it to `/Applications` first; the toggle
reverts itself and logs rather than silently lying if registration fails.

---

## Known issues and caveats

- **Run only one notch app at a time.** If you also run BoringNotch, Alcove or similar,
  two overlays will fight for the same real estate at the same window level.
- **Focus mode names** need Full Disk Access (see above).
- **Third-party Bluetooth headsets** rarely publish `BatteryPercent*` keys, so no
  percentage is shown. Apple's H1/H2 devices do.
- **The audio bars are decorative.** Reading real system audio requires an audio driver
  or a capture permission prompt; every app of this kind fakes them.
- **IOBluetooth is an old API** and throws deprecation notices in some SDKs, but it is
  the only one that reports classic (non-BLE) device connections, which is what AirPods
  and every BT headset actually use.
- **MediaRemote is already dead on macOS 15.4+** for third-party apps, so Apple Events
  is the real path. If a future macOS restores it, Isle picks it up automatically —
  the selection is made at runtime from whether data actually arrives.
- **Browser playback needs the JavaScript toggle above.** Without it Isle shows
  "Nothing playing" while you are very obviously playing something, which is why
  Settings ▸ Integration explains the exact cause rather than failing silently.

---

## Licence

Personal project. MediaRemote usage makes it unsuitable for App Store distribution;
build and run it locally.
