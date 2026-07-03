# AutoRaise — Display-Change Focus + Launcher

**Date:** 2026-07-03
**Status:** Approved design, pending implementation plan

## Summary

Modify AutoRaise so it no longer focuses/raises windows continuously as the mouse
hovers. Instead, focus/raise fires **once per display crossing**: when the cursor
moves from one display onto a different display, the engine "arms" a single
delayed focus. The user moves to their target window; after the configured delay
elapses, that window is activated. The engine then stays completely silent until
the cursor crosses onto a different display again.

A menu-bar **launcher** app (composed from lhaeger's launcher + sbmpost's engine)
wraps the engine, letting the user control the delay, enable/disable AutoRaise,
and start it at login.

## Goals

- Replace the default focus-follows-mouse behavior with display-change-triggered
  focus. This is the only mode — no runtime toggle between old/new behavior.
- Preserve the existing delay + mouse-stop machinery so the focus fires after a
  short, user-configurable delay once the cursor settles on a window.
- Provide a menu-bar launcher with: a delay setting, an Enable/Disable AutoRaise
  toggle, and a Start-at-Login toggle.

## Non-Goals

- Keeping stock focus-follows-mouse as a selectable option.
- Warp/scale/hotkey features from lhaeger's launcher (dropped — not needed).
- Preserving upstream compatibility / upstreaming these changes.

## Architecture

Two pieces, same split lhaeger already uses:

1. **Engine** — `AutoRaise.mm` (sbmpost v5.6), modified. Builds to a headless CLI
   binary. Runs the polling loop, now gated on display crossings. Configured via
   the existing `-delay` CLI argument (and other stock args).
2. **Launcher** — a menu-bar app (forked from lhaeger's Swift `AppDelegate`).
   Bundles the engine binary, spawns it as a subprocess with the configured
   delay, and manages enable/disable and start-at-login.

The launcher and engine communicate one-way: the launcher passes CLI args when it
spawns the engine, and terminates the process to stop it. No IPC beyond that.

## Engine changes (`AutoRaise.mm`)

### New state (globals near the other `onTick` statics)

- `lastDisplayID` — `CGDirectDisplayID` of the display the cursor was on last poll.
- `lastDisplayIDValid` — seeded `false`, set `true` after the first poll so startup
  doesn't count as a crossing.
- `displayFocusArmed` — `bool`, whether a one-shot focus is pending.

### Logic in `onTick()`

Injected after the existing mouse-point read and the macOS-12 coordinate
correction block (so `oldCorrectedPoint` stays fresh), before the raise-decision
block:

1. Determine the current display: `findScreen(mousePoint)`, then read its
   `NSScreenNumber` (`CGDirectDisplayID`). If `findScreen` returns `nil` (cursor
   between/off screens), treat as *no crossing* — skip crossing detection this tick.
2. **Crossing detection:** if `lastDisplayIDValid` and
   `currentDisplayID != lastDisplayID`, set `displayFocusArmed = true` and reset
   `delayTicks = 0` (restart the delay for the new cycle).
3. Update `lastDisplayID = currentDisplayID`; set `lastDisplayIDValid = true`.
4. **Gate:** `if (!displayFocusArmed && !delayTicks && !raiseTimes) return;`
   - When disarmed and no cycle is in progress, do nothing — this is what kills
     continuous focus-follows-mouse (silence within a display) and also suppresses
     stock space-change auto-raise.
   - `delayTicks`/`raiseTimes` in the condition let an *in-progress* focus cycle
     (delay counting down, or the stubborn-app multi-raise repeats) run to
     completion even after `displayFocusArmed` is cleared.
5. The existing delay + mouse-stop + ignore-list + drag-abort + raise/focus logic
   runs unchanged when the gate passes.
6. **Disarm:** the moment a raise/focus is actually committed (at the
   `raiseAndActivate(...)` call, and the `FOCUS_FIRST` focus path if compiled with
   it), set `displayFocusArmed = false`. `raiseTimes` continues to drain over the
   next few ticks (allowed by the gate), completing the multi-raise, after which
   the gate blocks further activity until the next crossing.

### Behavior guarantees (from approved Section 1)

- **One focus per crossing.** The first window the cursor settles on after a
  crossing (once the delay elapses) is activated; then silent until the next
  crossing.
- **Empty desktop / no raisable window:** stays *armed* (no fire happened), so a
  later settle on a real window activates it.
- **Already-focused window under cursor:** `needs_raise` is false, nothing fires,
  stays armed until the cursor settles on a different window.
- **Startup / single display:** seeded `lastDisplayID` means no spurious focus on
  launch; with one display the engine never re-arms.
- **Cursor between screens (`findScreen` nil):** no crossing recorded; skipped.

### Build

Built with the existing `make` (raise + activate path via `-delay`). No
`FOCUS_FIRST`/`OLD_ACTIVATION_METHOD` flags required for the core behavior; the
disarm hook is added to the `FOCUS_FIRST` path as well so the code stays correct
if those flags are later enabled.

## Launcher app

Forked from lhaeger's `Launcher/AppDelegate.swift` (Swift menu-bar app, Xcode
project), trimmed to what we need and pointed at our modified engine.

### Menu-bar UI

- `NSStatusItem` with an icon (reuse lhaeger's `Menu.png` / sbmpost `.icns`).
- Menu items:
  - **Enable AutoRaise** — checkbox item. Checked = engine subprocess running;
    unchecking terminates it. (New item requested by user.)
  - **Delay…** — opens a small Preferences window (or inline stepper/slider) to
    set the delay in milliseconds.
  - **Start at Login** — checkbox item toggling the login registration.
  - **Quit**.

### Preferences (persisted in `UserDefaults`)

- `enabled` (Bool) — whether the engine should be running.
- `delayMs` (Int) — user-configured delay in milliseconds.
- `startAtLogin` (Bool).

On launch: read prefs, apply login registration, and if `enabled` start the engine.

### Running the engine

- `startService`: locate the bundled engine binary
  (`…/Contents/MacOS/AutoRaise` or `…/Contents/Resources/`), spawn via `Process`
  with arguments. Delay conversion: the engine's `-delay` is in units of
  `pollMillis` where `1` = no delay and each extra unit adds one `pollMillis`
  (default 50 ms). So `delayUnits = max(1, round(delayMs / 50) + 1)`; the launcher
  enforces a minimum of `1` (delay `0` disables raising in the engine).
- `stopService`: `terminate()` + `waitUntilExit()`.
- Changing the delay while enabled restarts the subprocess with new args.

### Start-at-Login

Use `SMAppService.mainApp` (`register()` / `unregister()`, ServiceManagement,
macOS 13+) — the user's macOS is current, so the modern API applies. The
incomplete login handling in lhaeger's original is replaced by this.

### Bundle / build

- New bundle identifier (e.g. `local.autoraise.displayfocus`); own `Info.plist`
  with `LSUIElement` true (menu-bar only, no Dock icon).
- Xcode build phase compiles `AutoRaise.mm` into the app bundle's `MacOS`
  directory (mirroring lhaeger's build-script approach), so one Xcode build
  produces the whole app with the engine embedded.

## Testing / verification

- **Engine, manual on multi-monitor:** run the CLI binary with `-verbose true`;
  confirm (a) no focus while moving within one display, (b) exactly one focus
  after crossing and settling on a window, (c) empty-desktop-then-window still
  fires once, (d) crossing back re-arms.
- **Delay:** verify the configured delay is respected before the fire.
- **Single-display sanity:** confirm the engine stays silent (no crashes, no
  spurious focus).
- **Launcher:** toggle Enable/Disable starts/stops the process; changing delay
  takes effect; Start-at-Login registers and survives a reboot.

## Open questions

None outstanding — behavior rule, replace-default, and launcher scope are all
confirmed.
