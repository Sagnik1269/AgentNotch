# AgentNotch

A notch app for macOS: media, HUDs, file shelf, calendar, and a developer layer
(AI agent sessions, finished commands, ports, CI).

## Build & run

```bash
make run      # release build → build/AgentNotch.app, then launches it
make debug    # debug build
make clean
```

Requires macOS 14+ and the Xcode Command Line Tools. The build script calls `swiftc`/`clang`
directly and picks an SDK matching the compiler (some CLT installs ship a newer default SDK
than their compiler supports). Override with `SDK=/path/to/MacOSX.sdk ./scripts/build.sh`.

The bundle is written to `~/Library/Developer/AgentNotch/AgentNotch.app` (`build/AgentNotch.app`
is a symlink), because iCloud-synced folders add metadata that breaks codesigning.

**Signing:** builds are ad-hoc signed by default and never touch your keychain. The catch: macOS
ties privacy grants (Accessibility, System Audio Recording) to the signature, which changes on every
ad-hoc build, so you may need to re-grant after rebuilding. To sign with a real identity instead
(macOS will ask for keychain access to that key), opt in explicitly:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make run
```

If signing with the chosen identity fails, the build fails rather than silently falling back.

## Dev layer

AgentNotch listens on a Unix socket, `~/Library/Application Support/AgentNotch/agentnotch.sock`
(mode 0600 in a 0700 folder: only your user can connect, no TCP port is opened).

| Route | Body | Used by |
|---|---|---|
| `POST /v1/claude` | Claude Code hook JSON | `agentnotch-claude-hook` |
| `POST /v1/command` | `{"command","exit","duration","cwd"}` | `agentnotch.zsh` |
| `POST /v1/notify` | `{"title","subtitle"?,"icon"?,"tint"?}` | your scripts |
| `GET /v1/status` | n/a | snapshot of sessions, commands, CI, current alert |

```bash
curl --unix-socket "$HOME/Library/Application Support/AgentNotch/agentnotch.sock" \
     -d '{"title":"Deploy done","tint":"green"}' http://localhost/v1/notify
```

Integrations are installed from **Settings → Developer** (each makes a `.agentnotch-backup` first):
- **Claude Code** adds one hook entry per event to `~/.claude/settings.json`, alongside existing hooks.
  The hook script has a 1s timeout, prints nothing and always exits 0, so it can't block or break Claude.
- **zsh** adds a marked `source` line to `~/.zshrc`; commands ≥ 2s are reported in the background.

Ports come from `lsof` (only while the Ports list is visible). CI uses `gh run list` for the
repos/branches seen in Claude sessions and shell commands.

## How media works

MediaRemote only serves now-playing info to Apple-signed processes on macOS 15.4+. AgentNotch's
`Helpers/NowPlayingBridge` is a small dylib loaded into `/usr/bin/perl` (which qualifies); it streams
JSON lines on stdout and takes `play/pause/toggle/next/previous/seek <s>` commands on stdin.

### Live lyrics

Off by default. Turn it on in **Settings → Media** or with the quote button in the Media tab.
Lyrics come from [LRCLIB](https://lrclib.net) (free, open, no account). Only the playing song's
title, artist, album and length are sent, once per song; hits and misses are cached in
`~/Library/Application Support/AgentNotch/Lyrics`. Video-site titles ("Artist – Song (Official Video)")
are cleaned before lookup. The current line shows under the closed notch and in a scrolling view in
the Media tab (click a line to seek). Line changes are scheduled for the exact moment the next
line starts rather than polled.

- **Sync:** uploads whose timings can't fit the track are rejected, and malformed LRC timestamps
  (`[00:3045]`, `[01:02:50]`) are repaired. If a song is still off, ⌥-click (or right-click) the line
  you're hearing: that sets a per-song offset of any size, remembered for that song. The ± buttons
  nudge it by 0.5 s. The all-songs timing in Settings is for constant delays (e.g. Bluetooth).
  Lyrics from a different-length version (a music video, a radio edit) are still shown, with a note.
- **English letters:** on by default. Romanized uploads are preferred; otherwise Hindi/Devanagari and
  Punjabi/Gurmukhi are converted Hinglish-style with silent-"a" rules ("तुम ही हो" → "Tum hi ho"),
  and other scripts use the system transliterator. This is transliteration, not translation.

## Shelf, calendar, battery

- **Shelf:** drag files (or images, text, links) onto the notch; it opens straight to the Shelf. Files are
  referenced by bookmark, not copied, and survive restarts; dropped images/text are saved under
  `~/Library/Application Support/AgentNotch/Shelf`. Drag items back out, double-click to open,
  right-click for Show in Finder / AirDrop / Copy / Remove.
- **Calendar:** EventKit, only after you click *Show your calendar* (macOS asks). Today's and tomorrow's
  events appear on Home; an alert drops from the notch before each one (1–15 min, configurable).
  Meet/Zoom/Teams/Webex/FaceTime links get a Join button.
- **Battery:** IOKit power-source notifications (no polling): a pop on plug/unplug, alerts at 20% and 10%.
- **Bluetooth:** off by default (macOS asks for Bluetooth permission). Connect/disconnect alerts with
  battery levels when the device reports them (AirPods per bud + case, Apple keyboards/mice).

## Notes, timer, mirror

- **Notes:** several quick notes, saved as you type to `~/Library/Application Support/AgentNotch/notes.json`.
  The notch stays open while you're typing; click outside to close it, and the keyboard goes back to
  the app you were using.
- **Timer:** presets from 1 min to 1 h, ±1 min, pause/resume. While it runs, the closed notch shows the
  countdown; when it ends you get an alert and a chime.
- **Mirror:** the camera button in the header shows a mirrored camera preview. macOS asks for camera
  access the first time; the camera only runs while the mirror is showing.
- Any tab except Home can be hidden in **Settings → Tabs & tools**.

## Layout

```
Sources/AgentNotch/
  App/        main.swift, AppDelegate (screens, mouse monitors, menu bar icon)
  Notch/      NotchPanel (window), NotchWindowController (per-screen hover/open logic), NotchViewModel
  Views/      NotchShape, NotchView, ExpandedNotchView, tab views
  Settings/   AppSettings (UserDefaults + launch at login), SettingsView
  Support/    NSScreen notch geometry, SpaceInspector (fullscreen detection)
```

## Roadmap

1. ✅ Shell: overlay, hover/click expand, tabs, multi-display + virtual notch, fullscreen hiding, settings, launch at login
2. ✅ Media (now playing, controls, scrubber, live activity, track peek) + volume/brightness HUD replacement
3. ✅ Dev layer: Claude Code sessions, command-finished alerts, local event API, ports, CI
   - ✅ Live lyrics (LRCLIB, time-synced, opt-in)
4. ✅ Shelf (drag files onto the notch, drag out, AirDrop/copy), calendar (agenda on Home, alerts before
   events, Join for video calls), battery (charging pop, low-battery alerts), Bluetooth connect alerts
5. ✅ Notes, timer, mirror, tab visibility (clipboard history is out of scope: handled by another app)

Uses private SkyLight calls (fullscreen detection, later MediaRemote), so it's distributed outside the Mac App Store.
