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

A small menu-bar **launcher** app is included to control the delay, enable/disable
the engine, and start it at login.

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

- macOS 13 or newer (the launcher uses `SMAppService` for start-at-login).
- Xcode **Command Line Tools** (`xcode-select --install`). Full Xcode is *not*
  required — the launcher builds with SwiftPM.

## Build & install

```bash
# Build the whole app bundle (engine + launcher) and sign it:
./make-app.sh

# Install and launch:
cp -R AutoRaise.app /Applications/
open /Applications/AutoRaise.app
```

`make-app.sh` builds the engine (`make AutoRaise`), builds the launcher
(`swift build -c release`), assembles `AutoRaise.app`, and code-signs it.

The engine can also be built and run on its own, without the launcher:

```bash
make            # builds ./AutoRaise (the engine CLI)
./AutoRaise -verbose true
```

## Using the launcher

AutoRaise runs as a menu-bar icon (no Dock icon). Its menu offers:

- **Enable AutoRaise** — start/stop the engine. Checked = running.
- **Delay: N ms…** — opens a small window with a stepper to set the focus delay
  (0–2000 ms, in 50 ms steps). This is the delay after a display crossing before
  the hovered window is focused.
- **Start at Login** — register/unregister the app as a login item.
- **Open Accessibility Settings…** — jump to the Accessibility pane (see below).
- **Quit AutoRaise**.

## Accessibility permission

AutoRaise focuses windows through the macOS Accessibility API, so the **engine**
binary must be granted Accessibility permission. On first launch the app shows a
notice; grant the entry named **AutoRaiseEngine** in
*System Settings → Privacy & Security → Accessibility*, then toggle
**Enable AutoRaise** off and on.

### Signing (so the grant persists)

`make-app.sh` prefers a code-signing identity named `AutoRaise Self-Signed` and
falls back to ad-hoc signing. With ad-hoc signing, macOS asks you to re-grant
Accessibility after every rebuild, because the code signature changes. To keep
the grant stable across rebuilds, create a self-signed certificate once:

1. Open **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `AutoRaise Self-Signed`, Identity Type: **Self-Signed Root**,
   Certificate Type: **Code Signing**.

Then re-run `./make-app.sh` — it will sign with that identity automatically.

## Configuration

The launcher writes the delay into `~/.config/AutoRaise/config` and runs the
engine with no command-line arguments, so it reads the full config file. This
means you can add any of the engine's other options to that file and they are
preserved — the launcher only ever rewrites the `delay=` line. Example:

```
#AutoRaise config file
delay=5
ignoreApps="IntelliJ IDEA,WebStorm"
ignoreTitles="^window$"
stayFocusedBundleIds="com.apple.SecurityAgent"
```

`delay` is in units of `pollMillis` (default 50 ms): `1` = fire as soon as the
mouse settles, each extra unit adds one `pollMillis`. The launcher converts its
millisecond setting to these units for you. For the full list of engine options,
see the upstream [AutoRaise](https://github.com/sbmpost/AutoRaise) documentation —
this fork keeps the same engine flags.

## Tests

```bash
make test
```

Runs the engine's display-gating unit tests (C++) and the launcher's pure-logic
tests (delay conversion + config-file rewrite).

## Project layout

```
AutoRaise.mm                     # engine (Objective-C++), modified for display-change focus
DisplayFocusGate.h               # pure display-gating decision function
Package.swift                    # SwiftPM manifest for the launcher
make-app.sh                      # builds engine + launcher, assembles & signs AutoRaise.app
Launcher/                        # menu-bar launcher (Swift)
  main.swift                     #   entry point
  AppDelegate.swift              #   menu-bar UI + wiring
  EngineController.swift         #   runs the engine subprocess
  DelayConversion.swift          #   ms <-> engine delay units
  ConfigFile.swift               #   read-modify-write of ~/.config/AutoRaise/config
  LoginItem.swift                #   start-at-login (SMAppService)
  PreferencesWindowController.swift  # delay preferences window
  Info.plist
test/
  engine/test_display_focus_gate.cpp
  launcher/main.swift
docs/superpowers/                # design spec + implementation plan
```

## Credits

- Engine and the original focus-follows-mouse implementation:
  [sbmpost/AutoRaise](https://github.com/sbmpost/AutoRaise) (see `LICENSE.md`).
- The menu-bar launcher pattern is inspired by
  [lhaeger/AutoRaise](https://github.com/lhaeger/AutoRaise); the Swift launcher
  here is an original, trimmed reimplementation.
