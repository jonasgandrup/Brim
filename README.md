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
| Dynamic Island | Actual transparent AppKit panel around the notched display, activity-only compact artwork/playback wings, native Liquid Glass expansion on hover/click, outside-click and fast pointer-leave collapse, temporary file shelf, power feedback, system Now Playing metadata and transport controls, Music/Spotify artwork fallbacks | Broader media support uses an undocumented MediaRemote compatibility bridge and can change with macOS. Apps must publish a Now Playing session; artwork and commands vary. Downloads, file transfers, and arbitrary system notifications have no general public feed and are omitted. |
| Window Switcher | Individual Accessibility windows, app icons/titles, live ScreenCaptureKit snapshots, Command-Tab or Option-Tab, Shift/reverse, arrows, Escape, release-to-activate, minimized-window restore | Opt-in and off initially. Accessibility is required; Screen Recording is optional for previews. Protected/minimized/ambiguous windows show a clearly labeled fallback. Space switching follows macOS settings. |
| Trackpad Scale | Native built-in Force Touch sensor, tare, live/held grams and optional known-mass calibration | Experimental private macOS interface. Keep one fingertip in contact while placing an object beside it. Objects alone may not register. No fabricated weight is shown. |
| Lock Screen | Brief lock animation, standard macOS Lock Screen shortcut, welcome-back island feedback after unlock | Cannot replace or render on the secure login screen. No camera recognition, password handling, automatic credential entry, or authentication bypass. |

Every feature can be disabled independently. Settings and calibration use UserDefaults. Light, dark and system appearances are supported. The active compact island stays black to blend with the hardware camera cutout. On a notched display the entire island body remains opaque black throughout expansion and collapse, so the physical cutout never shows through glass. Native Liquid Glass is reserved for controls. The surface is pure opaque sRGB black on every display, with no material tint or gray rim. The hidden hardware state contracts exactly to the camera footprint rather than fading a translucent rectangle over it.

### Dynamic Island

The app prefers a notched display and calculates the camera cutout using `safeAreaInsets` and the auxiliary menu-bar regions. The island uses status-bar window level so its activity indicators remain visible against the menu bar. Its compact width reserves the physical camera area plus narrow activity wings. A fixed-size transparent compositor window hosts one persistent SwiftUI surface. A single spring animates that surface; the NSPanel itself never resizes. Pointer tracking lets input pass through outside the visible surface. The idle island adds no visible interface beyond the physical camera footprint and passes all mouse input through; it appears for actual playback or temporary feedback, or when explicitly opened from the menu bar. No idle battery badge, placeholder track, or disabled playback controls are shown. On a display without a notch, opt into **Show on displays without a notch** in Dynamic Island settings. The island follows display-layout changes and joins Spaces, including full-screen Spaces where macOS permits auxiliary windows.

Battery/output volume are refreshed every 15 seconds with timer tolerance. Opening the island does not synchronously query hardware during its animation. Unsupported output-device volume controls show **Unavailable**. There is no idle screenshot loop.

**Now Playing** is opt-in and uses the active macOS media session, so compatible browser audio/video, podcasts and other players can appear alongside Music and Spotify. It does not enumerate browser tabs, inspect page contents, inject JavaScript into websites or request browser Automation access. It shows one system-selected session at a time, with an explicit “Playing/Paused in [app]” label. That status describes the shown session, not every app. It reads only the session an app publishes to macOS. Apps that do not publish a session are unavailable.

Apple’s public Now Playing APIs publish an app’s own media; they do not expose this global feed to third-party utilities. Sense therefore isolates an **undocumented MediaRemote compatibility bridge** in a short-lived JavaScript for Automation process with a four-second timeout. It uses the runtime’s local Now Playing request and controller, without linking or shipping a private framework, impersonating another app, adding entitlements, or changing system files. Compatibility is not guaranteed after macOS updates. If the bridge is unavailable or no session is published, the existing public Music/Spotify AppleScript adapters remain available. This local build is not an App Store compatibility claim.

The bridge polls once per second during playback and every three seconds otherwise. A real playback rate, position and duration drive the playback scrubber, including nonstandard playback speeds; missing or invalid timeline values leave that strip empty. Click or drag the bar to seek when the player advertises an enabled absolute-seek command. Dragging previews locally; release sends one bounded seek. A source or track change during a drag cancels it, and live streams without a usable duration have no scrubber. Unsupported players show a disabled bar. Playback is not assumed to change after a command; the thumb returns to the player’s published position. Commands capture the displayed app, track identity and full macOS player path (including the client process and player session). They recheck that identity, then use a controller bound to that captured player rather than the global media route. Play and Pause are explicit actions, and further transport clicks are disabled during dispatch. A failed or stale system command is never retried through a different adapter; native Music/Spotify automation is used only when its own snapshot supplied the card. Reads begun before a click are discarded. The user can open the source app from the media header. Some players may ignore transport commands; use their own controls in that case.

Artwork uses session-provided image data when present. Music and Spotify can supply artwork through the existing Automation integration, queried once per source/track change. Those players may request Automation permission. Artwork results are applied only while the source and track still match; otherwise the source app’s actual icon is used. Spotify’s supplied HTTPS artwork URL remains the app’s only network request. No playback metadata is stored or transmitted by Sense. Disabling Now Playing stops polling, cancels updates and clears media state.

Reference for compatibility behavior only: [MRNowPlayingRequest / controller research](https://gist.github.com/SKaplanOfficial/f9f5bdd6455436203d0d318c078358de). No third-party runtime library or helper binary is bundled. Apple’s own supported publishing APIs are documented in [Now Playing](https://developer.apple.com/documentation/nowplaying).


### Window Switcher and permissions

1. Open **Permissions** and allow Accessibility.
2. Allow Screen Recording if you want window thumbnails. macOS may require a restart.
3. Enable Window Switcher. Choose Command-Tab or Option-Tab.
4. Hold the modifier and press Tab; use Shift-Tab or arrows to move. Release the modifier to focus the window. Escape cancels.

Sense uses an event tap only while the switcher is enabled and Accessibility is granted. It intercepts the configured Tab chord and navigation while the switcher is visible, rather than consuming every system shortcut. Stopping/disabling the feature removes the tap. If the tap cannot be created, Settings reports the failure; some configurations also require Input Monitoring. Secure Input, protected sessions, and system-reserved contexts may prevent interception. The panel appears on the display containing the pointer, and enumerates windows from running regular applications across displays.

ScreenCaptureKit and Accessibility do not share a public window identifier. Thumbnails are matched by owning process, title, and geometry; uncertain matches are omitted. A live snapshot is not guaranteed for a minimized or protected window. AX failures (closed windows, apps refusing focus) are left to macOS; the system has final authority over activation and Spaces.

### Native trackpad weighing

Open Scale from the menu bar. Rest one fingertip lightly on a built-in Force Touch trackpad, press **T** or **Set Zero**, then place a small object beside your finger without lifting or pressing harder. The display shows the sensor’s native gram estimate relative to that zero. Lift your finger to hold the last real reading. A new or changed contact invalidates zero; tare again. Optional known-mass calibration corrects the conversion and can be reset.

This follows the sensor approach demonstrated by [TrackWeight](https://github.com/KrishKrosh/TrackWeight) and its [OpenMultitouchSupport fork](https://github.com/KrishKrosh/OpenMultitouchSupport). Sense dynamically binds the optional private MultitouchSupport interface without adding a package dependency. The shared device session also handles Space-gesture suppression; closing Scale removes only the weighing subscriber. Force fields are decoded only while Scale is open and only for a built-in device advertising force support. Touch coordinates are never read or retained. See [third-party acknowledgments](THIRD_PARTY_NOTICES.md).

Objects alone may not produce capacitive contact. This is experimental: macOS can change the private interface, and fingertip pressure affects accuracy. Hardware availability and frame delivery do not prove calibration or accuracy. Validate with a known mass. Use only small, cool, dry, smooth objects; this is not a precision or safety-critical scale. The older public normalized-pressure model remains internal for compatibility and tests; it is not used as the native gram sensor.

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

Trackpad Scale opens directly in grams. Before a valid native sensor contact and zero it shows a dash; a held reading is labelled explicitly.

The island body is pure black through expansion and collapse, with no outline; native glass is reserved for controls. The hardware camera area stays opaque black. In addition to native transient behavior, Sense checks public window owner/layer/bounds metadata for Dock/Mission Control and AltTab overlays, samples only Tab/modifier shortcut state when macOS makes it available, and receives visibility callbacks directly from its own window switcher. It stays hidden for the entire observed switcher session, then restores after settling. Metadata detection is a heuristic because macOS has no public Mission Control active-state API; gesture behavior requires physical testing on each OS version. No additional keyboard permissions are requested.

After the opaque retraction finishes, an idle island is ordered out entirely; there is no software camera cover left for desktop animations to carry around. Active playback, retained files or an explicit open bring it back. To verify the real system overlay after rendering checks, append `--check-mission-control` to `--smoke-test`; it briefly opens/closes Mission Control with an active shelf and reports both hiding and restoration.

Idle hover uses a separate invisible hit region around the hardware camera, including a small strip below it. The idle window remains absent, but hovering opens it without needing media playback or a retained file. Dock full-display surface IDs are tracked independently from Mission Control/switcher panels to suppress the island during sideways Space animations, including held and cancelled swipes. The detector still uses public window metadata; physical three-finger gestures remain a manual acceptance check because macOS reserves them from normal global event monitors.

Use **Sense’s menu-bar icon → Set Up Lid Fold…** to open the app’s **Lid Fold & Lock** section. This is separate from macOS’s Lock Screen pane. **Enable Screen Recording…** requests the required permission; enable **Sense** in macOS **Privacy & Security → Screen & System Audio Recording**, then return to Sense (or reopen it if macOS asks). The setup status distinguishes a disabled feature, missing permission, Reduce Motion, an unavailable sensor and a ready fold. Screen Recording access is always granted by the user through macOS.

Space-slide suppression now waits for completion (an active-Space change or return to the original surfaces on cancellation) and 600 ms of stable metadata. A single stationary animation surface no longer causes early reappearance. Mission Control has a separate exit path, and temporary metadata-query failure preserves the current hidden state. A 12-second recovery limit prevents stale OS surfaces from leaving the island permanently unavailable.

## Island tools

The expanded island has **Media**, **Files**, **Clipboard** and **Timer** tabs. These tools are also available from Sense’s menu-bar icon.

- **Timer:** choose a duration or preset, then start, pause, resume or cancel. The compact island shows the remaining time. Completion produces a brief island message and a sound. The countdown uses an end date, so sleep does not extend it; a timer that expires during sleep finishes when Sense runs again. Timers stop when Sense quits.
- **Clipboard:** choose **Pin Clipboard** to save copied text, a web link or an image. Copied Finder files go to Files. You can also drop text, links and images onto the island. Copy a pin again, drag it into another app, or remove it from its context menu. Up to 20 pins remain in memory for the current session; Sense does not monitor clipboard history or persist pins to disk.
- **Files:** Command-click to select multiple files, then drag them together. Press **Space** or the eye button for native Quick Look, with arrows or Previous/Next for the selected files and Space/Escape to close. The share button opens the macOS sharing picker; you choose the destination and complete the share. Clear and Remove only forget references. Originals stay untouched.
- **Charging feedback:** connecting power briefly displays the real battery percentage. Reaching the chosen target while connected displays a one-time reminder. Configure the toggle and target (50–100%) in **Dynamic Island** settings. This is a reminder, not a charging limit. Starting Sense, changing the target or polling an unavailable battery does not generate a charging event. Feedback does not interrupt an already expanded tool.

For additional native verification, append `--check-file-actions` to `--smoke-test`. It selects two files from Sense’s own bundle, exercises the collection’s Space key handler, opens/closes Quick Look, and opens/cancels the sharing picker without selecting a service. Smoke output also includes empty/populated clipboard views, timer states and an explicitly labelled charging-feedback preview. The test uses isolated temporary pasteboards; it does not inspect your clipboard. Physical multi-file dragging into another app and actual power connection still require manual checks.

Append `--check-media` to `--smoke-test` for a read-only compatibility check against the current real media session. It reports bridge/session availability and timeline support and captures `now-playing-live.png` when media is present. A command with an intentionally mismatched source verifies rejection before dispatch; it does not alter current playback. Seeking checks validate the current player, item identity, capability, time bounds and options without dispatching a seek. Manual acceptance should include browser media, app-to-app source changes, play/pause/skip, missing artwork, stream durations and idle clearing on the specific apps you use.

### Space gesture visibility

Sense also observes **three or more trackpad contacts** through an optional, dynamically loaded MultitouchSupport compatibility interface. This is necessary because macOS reserves the live three/four-finger Space swipe before ordinary app event monitors receive it. During normal island use Sense reads only contact counts per device. While Scale is explicitly open, it additionally decodes force and contact identity from the selected built-in Force Touch device to measure grams and invalidate changed-contact baselines. It never reads touch positions or intercepts, synthesizes or changes gestures. The island disappears at contact onset, stays latched even as the count falls from three to two or one, and waits 900 ms after every finger on that gesture’s device lifts before restoring. Other devices cannot release the hold. This intentionally also hides it during other three-finger interactions. Ordinary two-finger scrolling does not start this path. Contact changes reach the main run loop in common modes, including event tracking. The panel has no AppKit hide/show animation and becomes fully transparent before being ordered out, preventing a lingering software edge. There is no added keyboard or Accessibility permission request.

The interface is undocumented and optional. A missing framework, symbol or device leaves the existing Space/window metadata detection working. Registrations are removed and devices stopped when the island is disabled or Sense quits. The native smoke report includes registered trackpad-device and observed contact-gesture counts; registration alone does not prove a physical swipe. Public desktop surface tracking additionally compares geometry, so moving surfaces with unchanged IDs extend hiding. A monotonic restore gate prevents overlapping shorter app-activation notifications from bringing the island back early.

Contact callback ABI reference only: [MultitouchSupport contact callback research](https://gist.github.com/rmhsilva/61cc45587ed34707da34818a76476e11). No third-party gesture implementation or touch-buffer structure is copied or bundled.

### Clock and camera alignment

The Clock tab contains Timer, Stopwatch (pause/resume, reset, latest lap) and a one-time Alarm with a native time picker and five-minute snooze. Stopwatch timing uses system uptime; alarm scheduling uses the next local calendar occurrence, including daylight-saving transitions. Alarms persist their future date and request macOS notification permission only when explicitly set. Granted notifications provide a system alert if Sense is closed; keep Sense running for its repeating sound. Alarms do not wake a sleeping Mac; the running app rings on wake. Stopwatch and timer stop when Sense quits.

On a notched display the compact island adds width only: its height equals the physical menu-bar/camera region. Ordinary application changes no longer hide and recreate the island. Space/switcher transitions still suppress the native panel; the compact shape is prepared with animations disabled while hidden before the panel returns at its fixed camera position. Hardware three-finger swipe timing still needs physical verification; automated full-screen transitions are complementary evidence.

Tab changes use an ordered fade: outgoing content fades before the selected pane is replaced. Shared artwork no longer travels between tab layouts. Desktop-transition restoration prepares compact geometry while hidden, then fades the stationary island in; Reduce Motion skips the fades. Rapid tab changes cancel pending transitions so stale panes cannot reappear.

Media routing regression checks cover two simultaneously playing model players, a handoff during Pause, repeated clicks, failed-command isolation, same-app browser-session changes, and stale-command refresh. Native `--check-media` validates construction of a player-bound Pause controller and rejects another session in the same app without sending playback commands. Actual simultaneous playback in specific third-party apps still needs a hands-on check; some apps expose grouped tabs as one system session.
