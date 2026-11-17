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
line starts rather than polled. A ±2 s timing nudge in Settings fixes tracks that run early or late.

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
4. Shelf, calendar, battery/Bluetooth
5. Clipboard, notes, timers, mirror, polish

Uses private SkyLight calls (fullscreen detection, later MediaRemote), so it's distributed outside the Mac App Store.
