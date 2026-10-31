# Sense

A native macOS menu-bar utility (SwiftUI + AppKit, Swift Package Manager, macOS 14+). Its identity is the
Dynamic Island around the camera notch; the window switcher, lid fold, trackpad scale and lock animation are
extras. The goal is an Apple-like feel: quiet by default, opaque black island, system colors and SF Symbols.

## Build and test

- `./test.sh` runs the tests. Plain `swift test` fails with this toolchain (the Testing framework needs extra
  flags that the script adds). Never report tests as failing because `swift test` failed.
- `./build.sh debug` builds and signs `dist/Sense.app`. Release: `./build.sh` (or `swift build -c release` to
  just compile). Check both: test harness code lives behind `#if DEBUG`.
- Signing uses one stable local identity (`scripts/sign-local.sh`, keys in `.sense-signing/`, never committed),
  so macOS privacy grants survive rebuilds. Don't rotate it.
- Use the `verify-sense` skill (`.claude/skills/verify-sense`) to check the app on real hardware: lid
  diagnostics, the smoke test's screenshots, and crash reports. Unit tests don't prove hardware or UI behavior.

## Toolchain quirks

- SwiftUI's `@State` (and other SwiftUI macros) don't compile here: the SwiftUIMacros plugin is missing from
  the Command Line Tools. Keep view state in `@Observable` models or plain properties instead.
- `#require` nested inside another `#require` fails to expand ("recursive expansion"). Bind to a local first.
- Swift 6 language mode with strict concurrency: most types are `@MainActor`; Core Audio, IOKit and Carbon
  callbacks hop back with `MainActor.assumeIsolated` or a main-queue dispatch.

## Rules of the codebase

- No third-party dependencies.
- Private or undocumented macOS interfaces (MediaRemote, MultitouchSupport, DisplayServices,
  `_AXUIElementGetWindow`) are loaded at runtime with `dlopen`/`dlsym`, isolated in one place, and must fail
  gracefully into an "unavailable" state. Never show invented values: no fake weights, angles or percentages.
- Anything that reads personal data or needs a permission is opt-in (Downloads, calendar, clipboard history,
  Focus status, screenshots). Clipboard history is memory-only. Titles and file names are never logged
  (`Log.*` with `privacy: .private`).
- Launch-time flags come from `AppEnvironment` (`isSmokeTest`, `isBundledApp`, `allowsAlerts`); feature code
  doesn't parse `CommandLine.arguments` itself.
- `NSWindow.windowNumber` is negative before a window is shown; use `window.windowID` (nil until valid),
  never `CGWindowID(window.windowNumber)`, which traps.
- Settings: every preference is a stored property on `Preferences` saved under its own name; a change in
  `SettingsView` calls `model.apply()`.
- Match the surrounding code: dense, few comments that explain why, Apple-style user-facing copy.
- Every user-facing string is translatable: SwiftUI literals, `LocalizedStringKey` parameters on our own
  components (`SettingsLabel`, `Footnote`, `IslandEmptyState`, `TimerActionButton`…), or `String(localized:)` in
  model code. Write whole sentences per count ("Copied 1 file" / "Copied \(n) files"), never glue English pieces.
  Text made elsewhere is shown with `.verbatim(_:)`. Diagnostics, identifiers and saved raw values stay English.
- Danish lives in `Resources/da.lproj/Localizable.strings` (keys are the English text). After changing UI text,
  run `scripts/check-localization.sh`; it lists missing translations and placeholder mismatches.

## Layout

- `App/`: lifecycle, `SenseAppModel`, preferences, `sense://` commands (`SenseCommand`), menu bar.
- `Features/Notch/`: `NotchController` (panel, presentation, feedback/HUD) and the island views and tabs.
- `Features/WindowSwitcher`, `Features/LidEffect`, `Features/TrackpadScale`, `Features/LockScreen`, `Features/Timer`.
- `Services/`: system readers (battery, audio, brightness, media bridge, transfers, calendar, sensors).
- `Settings/`: the System Settings–style window and the setup checklist.
