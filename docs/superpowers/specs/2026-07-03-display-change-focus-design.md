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

### Logic in `onTick()` — explicit ordering

The current `onTick()` maintains non-focus housekeeping state (`ignoreTimes`
decrement, `appWasActivated` reset, and the `spaceHasChanged` branch) *after* the
correction block. A naive early `return` while disarmed would leave that state
stale — most importantly, a `spaceHasChanged` flag set during a Space switch while
disarmed would survive, and the next display crossing would hit the
`spaceHasChanged` branch (sets `raiseTimes = 3; delayTicks = 0`) and fire an
**immediate raise, bypassing the configured delay.** So the ordering is explicit:

1. Mouse-point read and the macOS-12 coordinate correction block run as today
   (keeps `oldCorrectedPoint` fresh).
2. **Always clear non-focus housekeeping first, every tick, armed or not:**
   - `ignoreTimes`: decrement/consume as today.
   - `appWasActivated`: reset as today.
   - `spaceHasChanged`: in this mode, **clear it without raising** — remove the
     `raiseTimes = 3; delayTicks = 0` auto-raise; a space change alone must never
     focus. (Only a display crossing arms a focus.)
3. Determine the current display: `findScreen(mousePoint)`, then read its
   `NSScreenNumber` (`CGDirectDisplayID`). If `findScreen` returns `nil` (cursor
   between/off screens), treat as *no crossing* — skip crossing detection this tick.
4. **Crossing detection:** if `lastDisplayIDValid` and
   `currentDisplayID != lastDisplayID`, set `displayFocusArmed = true` and reset
   `delayTicks = 0` (restart the delay for the new cycle).
5. Update `lastDisplayID = currentDisplayID`; set `lastDisplayIDValid = true`.
6. **Gate:** `if (!displayFocusArmed && !delayTicks && !raiseTimes) return;`
   - When disarmed and no cycle is in progress, do nothing — this is what kills
     continuous focus-follows-mouse (silence within a display). Because step 2
     already ran, no housekeeping state is left stale by this return.
   - `delayTicks`/`raiseTimes` in the condition let an *in-progress* focus cycle
     (delay counting down, or the stubborn-app multi-raise repeats) run to
     completion even after `displayFocusArmed` is cleared.
7. The existing delay + mouse-stop + ignore-list + drag-abort + raise/focus logic
   runs unchanged when the gate passes.
8. **Disarm:** the moment a raise/focus is actually committed (at the
   `raiseAndActivate(...)` call, and the `FOCUS_FIRST` focus path if compiled with
   it), set `displayFocusArmed = false`. `raiseTimes` continues to drain over the
   next few ticks (allowed by the gate), completing the multi-raise, after which
   the gate blocks further activity until the next crossing.

The implementation plan should factor the display-gating decision into a small,
independently testable function (input: current display id, prior display id,
armed flag, in-progress flags → output: arm/return/proceed) so the state machine
can be unit-tested without the full AppKit event loop.

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

- `enabled` (Bool, default `true`) — whether the engine should be running.
- `delayMs` (Int, default `200`) — user-configured delay in milliseconds.
- `startAtLogin` (Bool, default `false`).

On launch: read prefs, apply login registration, and if `enabled` start the engine.

**Delay UI — one concrete choice.** A small **Preferences window** opened from the
menu, containing a labeled `NSStepper` + text field bound to `delayMs`:

- Range **0–2000 ms**, step **50 ms** (aligns with the engine's `pollMillis`
  granularity). Values are clamped to the range; non-numeric text reverts to the
  last valid value (no free-form invalid state).
- `0 ms` is allowed and maps to the engine minimum (`delayUnits = 1`, fire as soon
  as the mouse settles after a crossing).
- Changing the value rewrites the config `delay=` line and restarts the engine if
  `enabled`.

### Running the engine — and preserving user config

**Config-preservation constraint (verified against `AutoRaise.mm:808`).**
`readConfig:` reads the `~/.AutoRaise` / `~/.config/AutoRaise/config` file **only
when `argc == 1`** (no CLI args). If the launcher spawned the engine with
`-delay X`, `argc > 1` and the hidden config file is entirely ignored — silently
discarding any `ignoreApps`, `ignoreTitles`, `stayFocusedBundleIds`, `disableKey`,
etc. the user set there. To avoid that regression:

- The launcher **writes the delay into the config file** (`~/.config/AutoRaise/config`,
  the `delay=` key) rather than passing it as a CLI arg, and **spawns the engine
  with no arguments** so it loads the full config file. This preserves every other
  setting the user has. The launcher only ever rewrites the `delay=` line; other
  lines are left untouched (read-modify-write, preserving comments/order).
- Delay conversion: the engine's `-delay` is in units of `pollMillis` where `1`
  = no delay and each extra unit adds one `pollMillis` (default 50 ms). So
  `delayUnits = max(1, round(delayMs / 50) + 1)`; enforce a minimum of `1`
  (delay `0` disables raising in the engine).

- `startService`: locate the bundled engine binary at
  `…/Contents/MacOS/AutoRaise` (single agreed location — the engine ships next to
  the launcher executable in the bundle), then spawn via `Process` argless.
- `stopService`: `terminate()`, then wait with a **bounded timeout** (e.g. 2 s) on
  a background queue — never block the main/UI thread on `waitUntilExit()`; if the
  process has not exited, escalate to `SIGKILL`.
- Changing the delay while enabled rewrites the config line and restarts the
  subprocess.

### Process lifecycle & error handling

`enabled` is the user's *intent*; the actual subprocess state is tracked
separately and reconciled:

- Set `Process.terminationHandler` to detect crashes / unexpected exits. On an
  unexpected exit while `enabled` is true, update the menu state (uncheck / show an
  error affordance) rather than silently believing it is still running. Do **not**
  auto-restart in a tight loop; offer a manual re-enable.
- Handle spawn failure and missing/unexecutable binary with a user-visible message
  (menu item disabled + explanatory tooltip/alert), not a silent no-op.
- On launcher quit, stop the engine (bounded, as above).

### Start-at-Login

- **Deployment target: macOS 13.0** (Ventura). Use `SMAppService.mainApp`
  (`register()` / `unregister()`, ServiceManagement). The user's macOS is current,
  so this is safe; 13.0 is stated explicitly rather than assumed. The incomplete
  login handling in lhaeger's original is replaced by this.
- If `register()` throws, surface the error and leave the checkbox unchecked
  (reflect actual registration state, not intent).

### Accessibility / TCC ownership

The **engine** child process is what makes the Accessibility API calls
(`AXIsProcessTrusted`, `AXUIElementCopyAttributeValue`, event taps), so it — not
the launcher — must hold the Accessibility grant. macOS attributes TCC by the
running binary's identity, so:

- Both the launcher and the bundled engine binary are signed with the **same
  signing identity / Team ID** (ad-hoc/self-signed is acceptable for personal use,
  but must be stable across rebuilds so the grant persists — a changing signature
  forces re-authorization each build).
- **First-run UX:** on enable, if the engine reports it is not trusted (or focus
  never happens), the launcher shows a menu affordance / alert linking to
  System Settings → Privacy & Security → Accessibility, and the user grants the
  **engine binary** (path inside the bundle). This mirrors how lhaeger's wrapper
  already works in practice.
- The launcher itself needs no Accessibility permission.

### Bundle / build

- New bundle identifier (e.g. `local.autoraise.displayfocus`); own `Info.plist`
  with `LSUIElement` true (menu-bar only, no Dock icon).
- **Build ownership:** the **Xcode project is the single source of truth** for
  producing the shipping app. An Xcode "Run Script" build phase compiles
  `AutoRaise.mm` (via `g++ … -framework AppKit [-framework SkyLight]`, matching the
  existing `Makefile` flags) into the bundle's `Contents/MacOS/AutoRaise`. The
  existing `Makefile` is **retained only** for building/verifying the engine
  standalone from the command line during development; it does not build the
  launcher. (This resolves the earlier "make vs Xcode" ambiguity.)
- **Icon:** reuse the repo's existing `AutoRaise.icns` (present in repo root) for
  the app icon and lhaeger's `Menu.png` for the status-item template image; if a
  template image is unavailable, fall back to a system symbol.

### Upstream source provenance

- Engine: `sbmpost/AutoRaise` **v5.6** (the `AutoRaise.mm` in this repo), modified.
- Launcher: vendored from `lhaeger/AutoRaise` — **pin the exact upstream commit
  hash** in the plan. Files taken/adapted: `Launcher/AppDelegate.swift` (rewritten
  for our trimmed feature set), `Launcher/Info.plist`, and the `Menu.png`/`Prefs.png`
  assets. The MASShortcut/hotkey, warp, and cursor-scaling code is **not** vendored.
- Both projects' licenses (see `LICENSE.md`) are carried forward; note the license
  and attribution in the plan before vendoring.

## Testing / verification

**Unit-testable state machine:** the display-gating decision function (see
onTick step list) gets direct unit tests for the arm/disarm truth table:
within-display move, crossing, empty-desktop-stays-armed, already-focused-window,
startup seeding, `findScreen==nil`.

**Engine, manual on multi-monitor** (`-verbose true`): (a) no focus while moving
within one display, (b) exactly one focus after crossing and settling, (c)
empty-desktop-then-window still fires once, (d) crossing back re-arms, (e)
configured delay is respected before the fire.

**Regression scenarios (from review):**
- **Config preservation:** with an `~/.config/AutoRaise/config` containing
  `ignoreApps`/`ignoreTitles`/etc., confirm those still take effect when the
  launcher runs the engine (i.e. engine launched argless, config file rewritten
  only at the `delay=` line).
- **Space change while disarmed:** switch Spaces without crossing displays →
  **no** focus; then cross displays → fires after the normal delay (not
  immediately). Guards against the stale-`spaceHasChanged` bug.
- **Accessibility denied:** engine not trusted → launcher surfaces the permission
  affordance; no crash.
- **Child crash / manual kill:** kill the engine process → menu state reconciles
  (unchecks / error), no tight restart loop.
- **cmd-tab / app activation:** confirm task-switch activation is not mis-handled
  by the new gate (drag-abort and `appWasActivated` paths still respected).
- **Single-display sanity:** engine stays silent, no crashes, no spurious focus.

**Launcher:** Enable/Disable starts/stops the process (bounded stop, no UI hang);
changing delay rewrites config + restarts and takes effect; Start-at-Login
registers via `SMAppService` and survives a reboot; failed registration leaves the
checkbox unchecked.

## Resolved decisions (formerly open)

- **onTick ordering:** housekeeping cleared before the gate; space-change
  auto-raise removed in this mode. (Resolves stale-state / delay-bypass bug.)
- **Config preservation:** launcher writes the `delay=` line into the config file
  and launches the engine argless, so other user settings survive.
- **Build ownership:** Xcode project builds the shipping app (compiles the engine
  via a build phase); `Makefile` retained for standalone engine dev only.
- **TCC:** the bundled engine binary owns Accessibility; launcher and engine share
  a stable signing identity; first-run permission UX defined.
- **Deployment target:** macOS 13.0 (for `SMAppService`).
- **Delay UI:** Preferences window with a 0–2000 ms stepper (50 ms step).

## Open questions for the user — resolved

- **Signing:** ad-hoc / self-signed, personal use only. No notarization /
  Developer-ID. Signature must stay stable across rebuilds so the Accessibility
  grant persists.
- **Config file location:** the launcher owns `~/.config/AutoRaise/config`. The
  user has **no** `~/.AutoRaise` and no existing config file (verified absent on
  disk 2026-07-03), so there is nothing to shadow or migrate; the launcher creates
  the config file on first run.

No open questions remain.
