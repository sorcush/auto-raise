# AutoRaise (display-change focus fork)

A fork of [sbmpost/AutoRaise](https://github.com/sbmpost/AutoRaise) that changes
**when** focus follows the mouse.

Upstream AutoRaise raises/focuses a window every time you hover it. This fork
does **not** do that. Instead it fires focus **once per display crossing**: when
the mouse moves from one display onto a different display, AutoRaise arms a single
focus. You move to the window you want, and after a short (configurable) delay it
is raised and focused — once. It then stays completely silent, no matter how the
mouse moves within that display, until the cursor crosses onto another display
again.

This is meant for multi-monitor setups where continuous focus-follows-mouse is
too aggressive, but you still want the mouse to hand focus to whatever you point
at right after switching screens.

It ships as a single menu-bar app (no Dock icon) that controls the delay,
enables/disables the behavior, and can start at login.

## Behavior in detail

- **Within a single display:** nothing happens — moving the mouse over other
  windows never changes focus.
- **On a display crossing:** the next window you settle on (after the delay)
  is raised and focused, exactly once.
- **Empty desktop after a crossing:** the one-shot stays armed, so if you cross
  onto an empty area and then move to a real window, that window is focused.
- **A Mission Control Space change alone** never focuses anything — only a
  display crossing arms a focus.

## Requirements

- macOS 13 or newer (uses `SMAppService` for start-at-login).
- Xcode **Command Line Tools** (`xcode-select --install`). Full Xcode is not
  required — everything builds with `make`.

## Build & install

```bash
# Build the app bundle and sign it:
./make-app.sh

# Install and launch:
cp -R AutoRaise.app /Applications/
open /Applications/AutoRaise.app
```

`make-app.sh` runs `make` (which compiles `AutoRaise.mm` and assembles
`AutoRaise.app`) and then code-signs the bundle.

## Using the app

AutoRaise runs as a menu-bar icon (no Dock icon). Its menu offers:

- **Enable AutoRaise** — turn the behavior on/off. Checked = active.
- **Delay: N ms…** — opens a small window with a stepper + **Set** button to set
  the focus delay (20–2000 ms, in 20 ms steps): how long after a display crossing,
  once the cursor settles on a window, before that window is focused.
- **Start at Login** — register/unregister the app as a login item.
- **Open Accessibility Settings…** — jump to the Accessibility pane (see below).
- **Quit AutoRaise**.

Settings (delay, enabled, start-at-login) are stored in `UserDefaults` and applied
live — no restart needed when you change the delay.

## Accessibility permission

AutoRaise focuses windows through the macOS Accessibility API, so the app must be
granted Accessibility permission. Grant **AutoRaise.app** in
*System Settings → Privacy & Security → Accessibility*, then toggle
**Enable AutoRaise** off and on. Because it's a single process, granting the app
is all that's needed (no separate helper).

### Signing (so the grant persists)

`make-app.sh` prefers a code-signing identity named `AutoRaise Self-Signed` and
falls back to ad-hoc signing. With ad-hoc signing, macOS asks you to re-grant
Accessibility after every rebuild, because the code signature changes. To keep
the grant stable across rebuilds, create a self-signed certificate once:

1. Open **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `AutoRaise Self-Signed`, Identity Type: **Self-Signed Root**,
   Certificate Type: **Code Signing**.

Then re-run `./make-app.sh` — it signs with that identity automatically. (The
first signing may prompt for keychain access; click **Always Allow**.)

## Configuration

The delay is controlled from the menu and stored in `UserDefaults`; the app polls
the mouse every 20 ms so the 20 ms delay steps are exact.

The engine still reads the upstream config file at `~/.AutoRaise` or
`~/.config/AutoRaise/config` for its **other** options (e.g. `ignoreApps`,
`ignoreTitles`, `stayFocusedBundleIds`, `disableKey`). Any `delay`/`pollMillis`
lines there are overridden by the app. Example:

```
#AutoRaise config file
ignoreApps="IntelliJ IDEA,WebStorm"
ignoreTitles="^window$"
stayFocusedBundleIds="com.apple.SecurityAgent"
```

For the full list of engine options, see the upstream
[AutoRaise](https://github.com/sbmpost/AutoRaise) documentation — this fork keeps
the same engine flags.

## Tests

```bash
make test
```

Runs the display-gating unit tests (C++) that cover the arm/disarm state machine.

## Project layout

```
AutoRaise.mm         # the whole app: engine + menu-bar UI (Objective-C++)
DisplayFocusGate.h   # pure display-gating decision function (unit-tested)
Info.plist           # bundle metadata (LSUIElement menu-bar app)
create-app-bundle.sh # assembles AutoRaise.app from the built binary
make-app.sh          # make + code-sign AutoRaise.app
Makefile             # build (`make`) and tests (`make test`)
test/engine/test_display_focus_gate.cpp
docs/superpowers/    # design spec + implementation plan (historical)
```

## Credits

- Engine and the original focus-follows-mouse implementation:
  [sbmpost/AutoRaise](https://github.com/sbmpost/AutoRaise) (see `LICENSE.md`).
- The menu-bar app pattern was inspired by
  [lhaeger/AutoRaise](https://github.com/lhaeger/AutoRaise); the UI here is an
  original reimplementation folded into the engine.
