# Brim

A native macOS menu-bar utility (SwiftUI + AppKit, Swift Package Manager, macOS 14+). Its identity is the
Dynamic Island around the camera notch; the window switcher, lid fold, trackpad scale and Lock Mac are
extras. The goal is an Apple-like feel: quiet by default, opaque black island, system colors and SF Symbols.

## Build and test

- `./test.sh` runs the tests. Plain `swift test` fails with this toolchain (the Testing framework needs extra
  flags that the script adds). Never report tests as failing because `swift test` failed.
- `scripts/package.sh` builds the download, `dist/Brim-<version>.dmg`, signed locally and not notarized. With a paid Developer ID,
  `scripts/release.sh` builds the same image signed for it, notarizes it and staples the ticket.
- `./build.sh debug` builds and signs `dist/Brim.app`. Release: `./build.sh` (or `swift build -c release` to
  just compile). Check both: test harness code lives behind `#if DEBUG`.
- Signing uses one stable local identity (`scripts/sign-local.sh`, keys in `.sense-signing/`, never committed),
  so macOS privacy grants survive rebuilds. Don't rotate it.
- Permission checks only mean something when the app is launched with `open`: run from a terminal, macOS can
  judge the terminal's permissions instead of Brim's.
- Use the `verify-brim` skill (`.claude/skills/verify-brim`) to check the app on real hardware: lid
  diagnostics, the smoke test's screenshots, and crash reports. Unit tests don't prove hardware or UI behavior.

## Toolchain quirks

- SwiftUI's `@State` (and other SwiftUI macros) don't compile here: the SwiftUIMacros plugin is missing from
  the Command Line Tools. Keep view state in `@Observable` models or plain properties instead.
- `#require` nested inside another `#require` fails to expand ("recursive expansion"). Bind to a local first.
- Swift 6 language mode with strict concurrency: most types are `@MainActor`; Core Audio, IOKit and Carbon
  callbacks hop back with `MainActor.assumeIsolated` or a main-queue dispatch.

## Rules of the codebase

- The app used to be called Sense. These keep the old name on purpose, because changing them would lose privacy
  grants or saved data: the bundle ID `dk.jonasgandrup.Sense`, the signing identity and `.sense-signing/`, the
  `Sense/Clipboard Pins` folder, the `SenseStatusItem` and `SenseSettings` autosave names, and the `sense://` link scheme
  (kept next to `brim://`).
- No third-party dependencies.
- Private or undocumented macOS interfaces (MediaRemote, MultitouchSupport,
  `_AXUIElementGetWindow`, `SACLockScreenImmediate`) are loaded at runtime with `dlopen`/`dlsym`, isolated in one place, and must fail
  gracefully into an "unavailable" state. Never show invented values: no fake weights, angles or percentages.
- Anything that reads personal data or needs a permission is opt-in (Downloads, calendar,
  Focus status, screenshots). Now Playing is on by default because its system feed asks for nothing; its Music and
  Spotify access (Apple Events, `playerAccess`) stays opt-in, so a new install never sees an Automation prompt unasked. Titles and file names are never logged
  (`Log.*` with `privacy: .private`).
- Launch-time flags come from `AppEnvironment` (`isSmokeTest`, `isBundledApp`, `allowsAlerts`); feature code
  doesn't parse `CommandLine.arguments` itself.
- `NSWindow.windowNumber` is negative before a window is shown; use `window.windowID` (nil until valid),
  never `CGWindowID(window.windowNumber)`, which traps.
- Settings: every preference is a stored property on `Preferences` saved under its own name; a change in
  `SettingsView` calls `model.apply()`.
- A new install is Essentials, what iPhone does and nothing more. `IslandLevel` isn't saved; it's read back from the
  switches in `levelSwitches`. Add a new extra there unless it reads personal data or needs a permission: those stay
  their own switch, so choosing a level never sets off a run of prompts.
- "Dynamic Island" is Apple's name: in the app it's the island ("Island" as a title, "øen" in Danish, where "Island" means Iceland).
  The README may mention Apple's feature only as a comparison.
- Match the surrounding code: dense, few comments that explain why, Apple-style user-facing copy.
- Every user-facing string is translatable: SwiftUI literals, `LocalizedStringKey` parameters on our own
  components (`SettingsLabel`, `Footnote`, `IslandEmptyState`, `TimerActionButton`…), or `String(localized:)` in
  model code. Write whole sentences per count ("Copied 1 file" / "Copied \(n) files"), never glue English pieces.
  Text made elsewhere is shown with `.verbatim(_:)`. Diagnostics, identifiers and saved raw values stay English.
- Danish lives in `Resources/da.lproj/Localizable.strings` (keys are the English text). After changing UI text,
  run `scripts/check-localization.sh`; it lists missing translations and placeholder mismatches.

## Layout

- `App/`: lifecycle, `BrimAppModel`, preferences, `brim://` commands (`BrimCommand`), menu bar.
- `Features/Notch/`: `NotchController` (panel, presentation, feedback/HUD) and the island views and tabs.
- `Features/WindowSwitcher`, `Features/LidEffect`, `Features/TrackpadScale`, `Features/LockScreen`, `Features/Timer`.
- `Services/`: system readers (battery, audio, media bridge, transfers, calendar, trackpad).
- `Settings/`: the System Settings–style window and the setup checklist.
