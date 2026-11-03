<h1 align="center">Brim</h1>

<p align="center"><strong>Small touches. A better everyday.</strong></p>

<p align="center">The iPhone's Dynamic Island, made for the notch on your Mac.<br>Quiet until there's something to show.</p>

<p align="center"><img src="docs/images/hero.png" alt="The island open below the notch, playing Poker Face by Lady Gaga with artwork, a progress bar and playback controls" width="100%"></p>

Brim is a small native Mac app that lives around your camera. Music, timers, charging and AirPods appear beside the notch, the way they do on iPhone, and hovering opens them up. When nothing is happening, you won't know it's there.

It has no accounts and no cloud, and it asks for a permission only when a feature you turned on needs it.

## Around the notch

What's happening sits on either side of the camera, and it stays out of your way:

<p align="center"><img src="docs/images/compact-music.png" alt="Album artwork to the left of the notch and playback bars to the right" width="100%"></p>

- **It stays out of the way.** Inside the app that's playing, the music steps aside, because you can already see it. Switch away and it comes back in the notch.
- **Colors from your music.** The playback bars take their color from the album art.
- **Swipe to hide.** Swipe an activity away with two fingers, and it stays hidden until something new happens.
- **Click to go there.** Click the music to jump to the app that's playing it. Hover to open the island instead.
- **It makes room for menus.** If a menu or status icon is under the activity, reaching for it makes the activity step aside.

Two things at once? The second one parts from the island into its own bubble, just like on iPhone:

<p align="center"><img src="docs/images/dual-activities.png" alt="Music beside the notch, with a timer in a small round bubble next to it" width="100%"></p>

## Open the island

Hover over the activity and it opens, only as tall as what's inside.

<table>
  <tr>
    <td width="50%"><img src="docs/images/player.png" alt="Now Playing with artwork, seek bar and controls"></td>
    <td width="50%"><img src="docs/images/files.png" alt="Four files waiting in the island's file shelf"></td>
  </tr>
  <tr>
    <td><strong>Now Playing</strong><br>Control Spotify, Music, or a video in your browser. Seek, choose where the sound plays, and set a sleep timer.</td>
    <td><strong>Files</strong><br>Drop files on the notch and drag them out anywhere later. They wait while you switch windows or Spaces.</td>
  </tr>
  <tr>
    <td><img src="docs/images/clipboard.png" alt="A note, a link and an image pinned in the clipboard section"></td>
    <td><img src="docs/images/timer.png" alt="A five-minute timer running with Pause and Cancel"></td>
  </tr>
  <tr>
    <td><strong>Clipboard</strong><br>Pin text, links and images, and click one to copy it again. Clipboard history is optional and stays in memory only.</td>
    <td><strong>Clock</strong><br>Timers, focus sessions, a stopwatch and alarms, one click from wherever you are.</td>
  </tr>
  <tr>
    <td><img src="docs/images/battery.png" alt="Battery percentage, time remaining, volume and brightness sliders, battery health and cycle count"></td>
    <td><img src="docs/images/airpods.png" alt="An AirPods Pro card showing left, right and case battery levels"></td>
  </tr>
  <tr>
    <td><strong>Battery &amp; Controls</strong><br>Battery, time remaining, health, volume and brightness, all in one place.</td>
    <td><strong>Accessories</strong><br>Connect your AirPods and see every battery level at a glance.</td>
  </tr>
  <tr>
    <td><img src="docs/images/drop-zones.png" alt="Dragging a file over the island, with Files and AirDrop drop zones"></td>
    <td><img src="docs/images/activity.png" alt="A video export at 40 percent shown as a progress bar"></td>
  </tr>
  <tr>
    <td><strong>Drag to AirDrop</strong><br>Drag a file to the notch and choose where it goes: the shelf or AirDrop.</td>
    <td><strong>Your own activities</strong><br>Shortcuts and scripts can show their progress in the notch with a simple <code>brim://</code> link.</td>
  </tr>
</table>

## Choose how much it shows

A new install starts with **Essentials**, which does what the iPhone does and nothing more. Move up to **More** or **Everything** when you want the shelf, clipboard, clock and controls.

Anything that reads your calendar, downloads, screenshots or clipboard history, or needs a macOS permission, stays its own switch. Choosing a level never sets off a run of prompts.

<p align="center"><img src="docs/images/settings.png" alt="Brim's settings window, in the style of System Settings, showing the three levels" width="80%"></p>

## Window Switcher

Every window on ⌘Tab, not just every app. Hold, tab through, and let go. Search with `/`, and quit, close or hide right from the switcher. It's optional and off until you turn it on.

<p align="center"><img src="docs/images/switcher.png" alt="A row of window previews with app icons, the selected window softly highlighted and named below" width="100%"></p>

## Labs

Two experiments that lean on your Mac's sensors. Fun, and a little unpredictable.

<table>
  <tr>
    <td width="62%"><img src="docs/images/lid-fold.png" alt="The desktop tipping back in perspective as the lid closes"></td>
    <td width="38%"><img src="docs/images/scale.png" alt="The Trackpad Scale window with steps for weighing an object"></td>
  </tr>
  <tr>
    <td><strong>Lid Fold</strong><br>Your desktop follows the lid as you close your MacBook.</td>
    <td><strong>Trackpad Scale</strong><br>Weigh small objects on a Force Touch trackpad. An estimate, not a precision scale.</td>
  </tr>
</table>

## Get Brim

There's no download yet, so for now you build it yourself. It takes one command and needs only Apple's free Command Line Tools.

You need macOS 14 or later, and a Mac with a notch gets the most from it. Displays without a notch can show a floating island if you turn that on.

```sh
xcode-select --install
git clone https://github.com/jonasgandrup/Brim.git
cd Brim
./build.sh
open dist/Brim.app
```

Brim is available in English and Danish.

## More

- [How it works, and what its limits are](docs/TECHNICAL.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

Now Playing and a few other features use private macOS interfaces, so they can stop working after a macOS update. When that happens they show as unavailable, and Brim never makes up a value.

<sub>Brim is an independent project, not affiliated with or endorsed by Apple or Spotify. Dynamic Island is Apple's name for its iPhone feature. Album art belongs to its owners and is shown only to illustrate the player. Screenshots are real captures of the app on a plain drawn backdrop. The files, clipboard pins, AirPods levels, export progress and window previews in them are samples.</sub>
