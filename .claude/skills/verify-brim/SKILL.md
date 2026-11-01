---
name: verify-sense
description: Check that Sense actually works on this Mac, beyond unit tests. Use after changing the island, lid fold, switcher, scale or permissions, before saying a feature works, or when the user reports something broken. Covers the lid/hinge diagnostics, the smoke test's screenshots (for design review), crash reports, and the trackpad force check.
---

# Verify Sense on real hardware

Unit tests (`./test.sh`) cover logic only. These checks cover what they can't. Report what each check
actually showed; if a check couldn't run, say so.

## 1. Build

```sh
./test.sh                 # never plain `swift test`; it fails with this toolchain
./build.sh debug          # signs dist/Sense.app with the stable local identity
```

## 2. Lid fold and Screen Recording

```sh
perl -e 'alarm 25; exec @ARGV' dist/Sense.app/Contents/MacOS/Sense --lid-diagnostics
```

Prints JSON and exits (`timeout` isn't installed; the `perl alarm` stands in). Read:
- `hingeStatus` / `angle`: a live angle means the hinge sensor works.
- `screenRecording` and `captureCheck`: `true` and `Ready` mean the fold can capture the desktop.
- `readiness`: the one-line next step if anything is missing.

Exit code 133 is a Swift trap (a crash), not a diagnostic result. Go to step 4.

## 3. Screenshots for design review

```sh
SENSE_SMOKE_OUTPUT="$PWD/dist/smoke" dist/Sense.app/Contents/MacOS/Sense --smoke-test --check-file-actions --check-media
```

Renders every settings page (light and dark), the island in its states, file shelf, clipboard, timer,
battery and fold poses to PNGs in `dist/smoke`, plus `report.json`. It uses a separate preferences suite
and never touches the user's settings. Open the PNGs with the Read tool to see them; pair them with the
`design:design-critique`, `design:accessibility-review` and `design:ux-copy` skills.

## 4. Crashes

A run that dies prints `Fatal error: …` on stderr. The backtrace is in the newest
`~/Library/Logs/DiagnosticReports/Sense-*.ips`. Extract the crashing thread:

```sh
python3 - <<'EOF'
import json, glob, os
path = max(glob.glob(os.path.expanduser('~/Library/Logs/DiagnosticReports/Sense-*.ips')), key=os.path.getmtime)
raw = open(path).read(); body = json.loads(raw[raw.index('\n') + 1:])
for thread in body['threads']:
    if thread.get('triggered'):
        for frame in thread['frames'][:15]:
            print(body['usedImages'][frame['imageIndex']].get('name'), frame.get('symbol'), frame.get('sourceFile', ''), frame.get('sourceLine', ''))
EOF
```

Crashes can depend on timing and may not reproduce under `lldb`, so prefer the crash report.

## 5. Trackpad force (Scale)

The scale needs a built-in Force Touch trackpad that MultitouchSupport reports with force. Compile a tiny
check in the scratchpad (not the repo) that calls `MTDeviceCreateList`, `MTDeviceSupportsForce` and
`MTDeviceIsBuiltIn` through `dlopen`/`dlsym`, and print the result. A trackpad only senses pressure
while a finger touches it, so an object alone never registers.

## Things only the user can check

Hover and click feel, actually closing the lid, dragging files in and out, switching windows with ⌘Tab,
Now Playing with a real player, AirDrop, and haptics. Ask the user to try these rather than claiming them.
