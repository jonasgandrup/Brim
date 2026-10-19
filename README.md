# Sense

Small touches. A better everyday.

A native SwiftUI + AppKit menu-bar utility, built with Swift Package Manager. No web view, backend, account, database, or third-party dependencies. Local development uses the free Command Line Tools and ad-hoc signing; Xcode’s GUI and a paid developer account are unnecessary.

## Run

```sh
./dev.sh          # Build debug .app and open Settings
./build.sh        # Build and locally sign release .app
./build.sh debug  # Build debug .app without launching
./test.sh         # Run Swift Testing tests
open dist/Sense.app
```

Requires Swift 6.4 and macOS 14 or later (developed for Apple Silicon and macOS 26+). Install the tools with `xcode-select --install` if Swift is unavailable. The installed SDK must be compatible with the installed Swift compiler. Caches are placed under `.build` so restricted workspaces do not need writes to the global module cache. Scripts use SwiftPM’s native build system and disable the nested package sandbox; this does not change macOS privacy permissions.

The app lives at `dist/Sense.app`. A persistent native waveform icon in the top-right menu bar opens the island, Settings, feature toggles, the scale, Lock Mac, and Quit. This AppKit status item stays present independently of Settings windows. Hold Command and drag the icon to reposition it like other macOS menu-bar apps. Closing Settings leaves Sense running. Reopening the app opens Settings. VS Code build/test tasks are included.

For login items, first copy the release app to a stable location such as `/Applications`, launch that copy, then enable **Launch at login**. macOS may ask you to approve it under General → Login Items. Do not register a disposable build and then move it. Running the raw Swift executable is useful for debugging but is not the supported launch-at-login workflow.

## What is implemented

| Feature | Implementation | Limits |
| --- | --- | --- |
| Dynamic Island | Actual transparent AppKit panel around the notched display, activity-only compact artwork/playback wings, native Liquid Glass expansion on hover/click, outside-click and fast pointer-leave collapse, temporary file shelf, real battery/output volume, Music/Spotify metadata and artwork, playback controls | No global browser-media/private MediaRemote integration. Downloads, file transfers, and arbitrary system notifications have no general public feed and are omitted. |
| Window Switcher | Individual Accessibility windows, app icons/titles, live ScreenCaptureKit snapshots, Command-Tab or Option-Tab, Shift/reverse, arrows, Escape, release-to-activate, minimized-window restore | Opt-in and off initially. Accessibility is required; Screen Recording is optional for previews. Protected/minimized/ambiguous windows show a clearly labeled fallback. Space switching follows macOS settings. |
| Trackpad Scale | Real `NSEvent.pressureChange` capture over a dedicated AppKit pressure pad, raw relative pressure, tare, known-mass calibration, approximate grams | An experiment in relative pressure, **not passive trackpad weighing**. Requires finger contact and pressure events. No events means unavailable; no fabricated weight is shown. Public pressure changes with click stage, contact and position. |
| Lock Screen | Brief lock animation, standard macOS Lock Screen shortcut, welcome-back island feedback after unlock | Cannot replace or render on the secure login screen. No camera recognition, password handling, automatic credential entry, or authentication bypass. |

Every feature can be disabled independently. Settings and calibration use UserDefaults. Light, dark and system appearances are supported. The active compact island stays black to blend with the hardware camera cutout. On a notched display the entire island body remains opaque black throughout expansion and collapse, so the physical cutout never shows through glass. Native Liquid Glass is reserved for controls. On an unnotched display the expanded body uses Apple’s `glassEffect`, with a system-material fallback before macOS 26. The hidden hardware state contracts exactly to the camera footprint rather than fading a translucent rectangle over it.

### Dynamic Island

The app prefers a notched display and calculates the camera cutout using `safeAreaInsets` and the auxiliary menu-bar regions. The island uses status-bar window level so its activity indicators remain visible against the menu bar. Its compact width reserves the physical camera area plus narrow activity wings. A fixed-size transparent compositor window hosts one persistent SwiftUI surface. A single spring animates that surface; the NSPanel itself never resizes. Pointer tracking lets input pass through outside the visible surface. The idle island adds no visible interface beyond the physical camera footprint and passes all mouse input through; it appears for actual playback or temporary feedback, or when explicitly opened from the menu bar. No idle battery badge, placeholder track, or disabled playback controls are shown. On a display without a notch, opt into **Show on displays without a notch** in Dynamic Island settings. The island follows display-layout changes and joins Spaces, including full-screen Spaces where macOS permits auxiliary windows.

Battery/output volume are refreshed every 15 seconds with timer tolerance. Opening the island does not synchronously query hardware during its animation. Unsupported output-device volume controls show **Unavailable**. There is no idle screenshot loop.

**Music & Spotify** is opt-in. On enable, Sense queries running players through public AppleScript automation, then refreshes on distributed player-change notifications. The players may ask for Automation permission. Playing Spotify takes priority; otherwise Music or paused Spotify is used. The app does not start a stopped player. Artwork comes from Music’s local track data or the HTTPS artwork URL supplied by Spotify. That artwork fetch is the only network request; there is no analytics or telemetry. Player automation runs outside the UI process’s main thread with a timeout. Some player/OS versions may not publish change notifications; toggle the integration off/on to refresh.

### Window Switcher and permissions

1. Open **Permissions** and allow Accessibility.
2. Allow Screen Recording if you want window thumbnails. macOS may require a restart.
3. Enable Window Switcher. Choose Command-Tab or Option-Tab.
4. Hold the modifier and press Tab; use Shift-Tab or arrows to move. Release the modifier to focus the window. Escape cancels.

Sense uses an event tap only while the switcher is enabled and Accessibility is granted. It intercepts the configured Tab chord and navigation while the switcher is visible, rather than consuming every system shortcut. Stopping/disabling the feature removes the tap. If the tap cannot be created, Settings reports the failure; some configurations also require Input Monitoring. Secure Input, protected sessions, and system-reserved contexts may prevent interception. The panel appears on the display containing the pointer, and enumerates windows from running regular applications across displays.

ScreenCaptureKit and Accessibility do not share a public window identifier. Thumbnails are matched by owning process, title, and geometry; uncertain matches are omitted. A live snapshot is not guaranteed for a minimized or protected window. AX failures (closed windows, apps refusing focus) are left to macOS; the system has final authority over activation and Spaces.

### Trackpad experiment and TrackWeight research

[TrackWeight](https://github.com/KrishKrosh/TrackWeight) uses a custom OpenMultitouchSupport fork to read private global trackpad data and requires continuous capacitive finger contact. Its [license](https://github.com/KrishKrosh/TrackWeight/blob/main/LICENSE) was checked: MIT, copyright 2025 Krish Shah. **No TrackWeight or OpenMultitouchSupport source was copied, linked, or vendored into Sense.** Sense intentionally uses Apple’s public AppKit pressure API; low-level private sensor support remains unimplemented.

Open Scale, put the pointer over the dashed pad, and gently press with a finger. Compatible pressure events update the raw-pressure readout. Enter the known mass first. Press **T** while keeping light finger contact to tare, then maintain that contact while applying the small known mass and press **C** to calibrate. These keyboard controls let you keep the pointer over the pad. Losing contact invalidates the baseline; tare again before taking another reading. Before calibration the weight display is a dash with numbered setup instructions. After calibration it displays approximate grams. Lifting the finger retains the last real estimate, clearly marked Held; tare before taking a new reading. Reset clears the calibration and held value. No sample grams are generated. A saved conversion is a convenience, not hardware detection or proof of accuracy. Recalibrate each session; switching click stages or losing contact invalidates the physical assumptions. Do not put heavy, sharp, wet, or hot objects on the trackpad. This is not suitable for medical, commercial, or other precise weighing.

### Lock Screen

**Lock Now** needs Accessibility to send Control–Command–Q. The visible transition is only a short handoff; macOS performs the actual lock and authentication. Use the system shortcut directly at any time. Automatic unlock observation uses macOS distributed screen-lock notifications as best-effort cosmetic feedback; it is not used as a security signal. No service can grant Sense the ability to replace loginwindow securely. Webcam recognition has therefore not been added.

## Local signing

`build.sh` signs with `codesign --sign -` by default. No entitlement, sandbox exception, or developer membership is needed for this local unsandboxed app. This is not a notarized distribution build. A new ad-hoc binary can invalidate a previous macOS privacy approval. Keep the bundle ID and path stable; if necessary remove/re-add Sense in Privacy & Security and restart it.

For an existing local signing identity, use:

```sh
SENSE_SIGN_IDENTITY='your existing identity' ./build.sh
```

The script does not create certificates, change the keychain, enable login items, or grant permissions automatically.

## Structure

```text
Sources/Sense/
  App/                      App lifecycle, menu, persisted preferences
  DesignSystem/             Native reusable settings components
  Features/Notch/           Panel geometry and island UI
  Features/WindowSwitcher/  Event tap, AX windows, ScreenCaptureKit previews
  Features/TrackpadScale/   Actual pressure input and calibration
  Features/LockScreen/      System lock handoff and visual feedback
  Services/                 Permissions, media, battery and volume
  Settings/                 Six-section settings window
Resources/                  Bundle metadata and app icon
Tests/SenseTests/           Calibration, selection, persistence and input-state tests
scripts/                    Reproducible native icon renderer
```

## Verify locally

```sh
./test.sh
./build.sh debug
SENSE_SMOKE_OUTPUT="$PWD/dist/smoke" dist/Sense.app/Contents/MacOS/Sense --smoke-test
```

The smoke test opens and renders all six settings sections in both appearances and the scale, captures the idle/active and expanded island plus empty/populated file shelves, checks prompt pointer-exit closure, and exercises rapid direction changes without resizing the panel, writes PNG previews (using the same content without the scrolling wrapper, since AppKit omits scroll layers from bitmap capture) and a JSON capability report, then exits. Native island screenshots use ScreenCaptureKit’s current-process content API, which only exposes capturable windows without requesting Screen Recording permission; other previews use AppKit rendering. It uses a separate preferences suite and does not ask for permissions or intentionally lock the computer. It does not prove private-permission flows, hardware readings, media control, secure lock behavior, or window activation on your Mac. Those require the manual checks below.

Manual acceptance: expand/collapse on the physical notch; move between displays and Spaces; drag files from Finder to the island, switch apps or Spaces, then drag them out into a destination; grant permissions and switch two windows of one app; cancel the switcher and disable it to confirm normal Command-Tab; restore a minimized window; play Music/Spotify and check artwork/controls; press the scale pad and calibrate against a known mass; explicitly lock and unlock using macOS; test login after installing in a stable location. Do not infer these results from passing unit tests.

Public API references: [AppKit pressure](https://developer.apple.com/documentation/appkit/nsevent/pressure), [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager), [CGEvent taps](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)), [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).

Liquid Glass reference: [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views).

## Duo lid closing

Enable **Lock Screen → Duo lid closing**. Sense opens only the dedicated Apple hinge HID device (vendor `0x05AC`, product `0x8104`, usage page `0x20`, usage `0x8A`). It reads feature report 1 through public IOKit calls; the report format is community-documented, not an Apple-supported lid-angle API. A missing/denied sensor produces an unavailable state, never a simulated angle. The sensor was found and a real 99° reading was verified on the development Mac.

The current angle at startup is the neutral position; **Set Open Position** recalibrates it. Six degrees of movement are ignored before the effect begins. With Screen Recording granted, the actual desktop folds into two connected top/bottom perspective panels as you physically close the lid. Their shared horizontal hinge recedes while the top and bottom edges move vertically inward. Each panel has its own depth shading, with a softer upper panel and a sharper lower panel; fading is reserved for the final ten percent of closure. Capture prewarms after two degrees of movement; the visible motion begins after six degrees. Without Screen Recording, the desktop effect stays off; use **Lock Screen → Desktop fold → Allow** to enable it. The snapshot stays in memory, is never saved or transmitted, and is discarded when the lid returns to its neutral angle. External displays are untouched. Sleep, wake, display-layout changes and screen lock clear the overlay. There are no private WindowServer APIs or secure-lock-screen overlays; macOS still owns sleep and authentication. Reduce Motion disables the effect.

The sensor polls at 8 Hz at rest and 60 Hz briefly during movement. HID reads run on a separate actor. Nothing is captured in an idle loop. Smoke tests read the sensor but suppress the full-screen effect; actual physical closing and the permitted desktop depth effect require manual testing on the Mac.

Research references (protocol/behavior only; no source copied): [LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor), [hinge-report notes](https://gist.github.com/alessaba/098f83c587e1372d30dea36a7c18b7cc), [Duo-style reference](https://github.com/lqSky7/iphone-duo-macos-animation).

## Temporary file shelf

Drag files or folders toward the island to reveal the Files shelf, or choose **Open File Shelf** from Sense’s menu-bar icon. Drop them there, switch windows, tabs or Spaces, and drag an item into its destination. The shelf retains references for the current app session. Clear and Remove from Shelf only remove references; they never delete or move the original files. A source moved or deleted elsewhere can leave a stale reference.

Hover opens after 60 ms with a 220 ms motion; pointer-leave closes after 60 ms with a 140 ms motion. The playback indicator keeps the same five bars through pause/play, animating between quiet dots and moving bars over 300 ms. Transparent rounded corners count as outside the island. The panel keeps a fixed size through every transition, and the camera region remains opaque black throughout.

The island uses AppKit’s [transient window behavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/transient), so macOS excludes it from Mission Control. Observed horizontal swipes, Space changes and app activation temporarily hide the panel; it returns at the physical camera after the transition settles. Shelf references remain intact. Public event monitors do not expose every system-reserved trackpad gesture, so physical swipe/Mission Control checks remain part of manual acceptance.

Smoke previews named `duo-fold-*.png` render Sense’s own settings image at fixed fold poses to inspect geometry. They are rendering checks, not captured desktop motion or synthetic hardware readings.

Trackpad Scale opens in **Trackpad units**: the exact normalized AppKit pressure value (0–1), with the last observed reading held after release. This needs no gram calibration and is not labelled as mass or force. **Grams** remains available as a separately calibrated estimate; successful calibration selects it.

Island collapse uses a native glass capsule with a subtle lower rim below the camera. The hardware camera area stays opaque black. In addition to native transient behavior, Sense checks public window owner/layer/bounds metadata for Dock/Mission Control and AltTab overlays, samples only Tab/modifier shortcut state when macOS makes it available, and receives visibility callbacks directly from its own window switcher. It stays hidden for the entire observed switcher session, then restores after settling. Metadata detection is a heuristic because macOS has no public Mission Control active-state API; gesture behavior requires physical testing on each OS version. No additional keyboard permissions are requested.

After the opaque retraction finishes, an idle island is ordered out entirely; there is no software camera cover left for desktop animations to carry around. Active playback, retained files or an explicit open bring it back. To verify the real system overlay after rendering checks, append `--check-mission-control` to `--smoke-test`; it briefly opens/closes Mission Control with an active shelf and reports both hiding and restoration.

Idle hover uses a separate invisible hit region around the hardware camera, including a small strip below it. The idle window remains absent, but hovering opens it without needing media playback or a retained file. Dock full-display surface IDs are tracked independently from Mission Control/switcher panels to suppress the island during sideways Space animations, including held and cancelled swipes. The detector still uses public window metadata; physical three-finger gestures remain a manual acceptance check because macOS reserves them from normal global event monitors.

Use **Sense’s menu-bar icon → Set Up Lid Fold…** to open the app’s **Lid Fold & Lock** section. This is separate from macOS’s Lock Screen pane. **Enable Screen Recording…** requests the required permission; enable **Sense** in macOS **Privacy & Security → Screen & System Audio Recording**, then return to Sense (or reopen it if macOS asks). The setup status distinguishes a disabled feature, missing permission, Reduce Motion, an unavailable sensor and a ready fold. Screen Recording access is always granted by the user through macOS.

Space-slide suppression now waits for completion (an active-Space change or return to the original surfaces on cancellation) and 600 ms of stable metadata. A single stationary animation surface no longer causes early reappearance. Mission Control has a separate exit path, and temporary metadata-query failure preserves the current hidden state. A 12-second recovery limit prevents stale OS surfaces from leaving the island permanently unavailable.
