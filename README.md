# `switchr`

Window and tab finder for macOS 🔭

## Features

- Press the global hotkey (default: ⌘⌥⌃⇧+Space, a.k.a hyper+Space) to bring up
  a picker over every running app's windows,
- type to fuzzy-match, Enter to jump straight there,
- for supported apps, the picker goes one level deeper and matches individual
  tabs, not just windows,
- scoped hotkeys jump straight to a single app's tabs — no typing the app name
  first. Hold the hotkey down and tap again to cycle through matches, release to
  commit; a quick tap-and-release just opens the picker so you can type,
- if a scoped app isn't running, the hotkey launches it instead.

## Installation

```sh
brew tap ElliottH/switchr
brew install --cask ElliottH/switchr/switchr
```

`switchr` will appear in your menu bar. You will be prompted to grant
Accessibility permissions, which it needs to see other apps' windows and tabs.

It will add itself to Login Items automatically on first launch, so it starts
with your Mac. You can toggle this from the menu bar icon.

## App support

Every app gets window-level matching for free, just from its windows' titles.
Some apps get deeper, tab-level support:

| App | What you get |
|---|---|
| Chrome | Every tab's title and URL |
| iTerm2 | Every window, tab, and session name |
| Finder, and anything with native macOS window tabs | Every tab's title |
| Firefox | Every tab's title |

Everything else — Slack, Mail, Notes, whatever you have open — falls back to
window titles, which for most apps is the whole story anyway.

## Configuring hotkeys

`switchr` reads `~/.config/switchr/hotkeys.toml`, if it exists, for the global
hotkey and any scoped ones. Without a config file, it falls back to the
default ⌘⌥⌃⇧+Space global hotkey.

```toml
[[hotkey]]
key = "space"
modifiers = ["command", "option", "control", "shift"]
scope = "global"

[[hotkey]]
key = "c"
modifiers = ["command", "option"]
scope = { apps = ["com.google.Chrome"] }
```

`scope = "global"` opens the picker over every running app, same as the
default hotkey. `scope = { apps = [...] }` jumps straight into that app's tabs
— list more than one bundle ID and it uses whichever one is actually running.

## Why?

I switch between a handful of tabs and windows across a handful of apps all
day, and ⌘-Tab and native tab-switching shortcuts only get you so far when
what you're actually looking for is "that one GitHub PR tab" or "the terminal
running the build." A fuzzy-searchable picker that already knows about your
open windows and tabs is faster than alt-tabbing through everything or
hunting with the mouse.

Same posture as [`hypr`](https://github.com/ElliottH/hypr) on scope and
permissions: Accessibility access is powerful, so this stays open-source and
readable end to end. Where it necessarily diverges — a config file, and
per-app integrations that read tab titles — is deliberately kept narrow: it's
data-only, one-directional, and none of it executes anything on your behalf.
