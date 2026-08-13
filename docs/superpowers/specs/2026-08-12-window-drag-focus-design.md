# AutoRaise — Don't arm a focus while dragging a window across displays

**Date:** 2026-08-12
**Status:** Approved design, revised after independent review, pending implementation plan

## Summary

Dragging a window from one display onto another currently leaves a pending
one-shot focus behind. The cursor crossing that happens *while the window is in
hand* looks, to the display-focus gate, exactly like the user walking the pointer
onto another display: the gate arms. The drag-abort check in `onTick()` suppresses
the raise for as long as a mouse button is held, but it only clears `delayTicks`
and `raiseTimes` — `displayFocusArmed` survives the drop. So the moment the user
releases and moves the pointer off the window they just moved, the surviving
one-shot fires on whatever the pointer settles on, and the dragged window loses
focus.

This design suppresses arming for crossings that occur during a window drag, and
cancels any one-shot that was already pending when the drag was recognized. The
dragged window itself needs no explicit focus — macOS focuses a window when its
title bar is grabbed; the only bug is AutoRaise taking that focus away afterwards.

## Problem, verified against the code

- `AutoRaise.mm:1068-1081` runs `displayFocusGate()` every tick. It arms on any
  change of the display under the cursor. It has no notion of a drag.
- `AutoRaise.mm:1096-1098` computes `abort` from
  `CGEventSourceButtonState(...)`; `AutoRaise.mm:1111-1116` then clears
  `raiseTimes` and `delayTicks` and returns. `displayFocusArmed` is untouched.
- `AutoRaise.mm:1244` is the only place `displayFocusArmed` is cleared during
  normal operation — when a raise/focus is actually committed.
- Consequence: a crossing during a drag arms a one-shot that cannot fire until
  the button is released, and then fires on the first window the pointer settles
  on after the release.

## Goals

- A crossing that happens while a window is being dragged never arms a one-shot
  focus.
- Recognizing a window drag cancels a one-shot that was already pending, so a
  drag never costs the user the focus of the window they dragged.
- Releasing the button is not itself seen as a display crossing.
- Drag tracking introduces no focus or activation side effects of its own.
- Everything else about the display-focus behavior is unchanged.

## Non-Goals

- Explicitly focusing the dragged window. macOS already does this on grab.
- Suppressing arming for *any* held mouse button. Only window drags are
  suppressed (decided by the user). A text selection dragged across displays
  still arms a one-shot; see "Accepted limitations".
- Observing the true mouse-down instant via the event tap. Capture is
  poll-aligned; see "Accepted limitations" for the residual race and why it is
  not worth new event-tap surface.
- Fixing the Microsoft Teams live-video focus problem. Separate work; see
  "Known follow-up".

## Behavior

1. On the first tick where a mouse button is observed down, AutoRaise captures
   the frontmost normal window whose bounds contain the pointer, recording its
   window number and its bounds.
2. While the button stays down and the hold has not yet been classified,
   AutoRaise re-reads that window's bounds each tick. The first time the bounds
   differ from the recorded ones, the hold is classified a **window drag**.
3. On classification, and for the rest of the hold:
   - display crossings do not arm a one-shot focus;
   - any one-shot already pending is cancelled, including a focus already
     counting down.
4. Which display the cursor is on keeps being recorded throughout the drag, so
   releasing the button never registers as a crossing.
5. After the release nothing is pending. The next genuine crossing arms a
   one-shot exactly as it does today.
6. Movement within a single display is unchanged — still silent.

### Bounds, not just position

Classification compares the window's full bounds: origin *and* size. Origin alone
is not enough to be coherent. Resizing a window by its top or left edge moves the
origin, while resizing by the right or bottom edge does not — comparing only the
origin would suppress the one-shot for the first case and not the second. Treating
any bounds change as a drag makes resizing behave consistently: while the user is
manipulating one window, that window does not lose focus. This is the approved
intent ("keep the resize behavior too") applied to all edges.

### Accepted limitations

Each of these is a deliberate consequence of a decision above, not an oversight.

- **Non-window drags still arm.** Dragging a text selection, or holding a button
  while moving the pointer without changing any window's bounds, still arms a
  one-shot on a display crossing. This follows directly from narrowing
  suppression to window drags.
- **Desktop drags are not window drags.** Pressing on the desktop (rubber-band
  selection) captures no window, so the hold can never be classified, and a
  crossing during it arms normally.
- **Poll-aligned capture.** The capture happens on the first tick where the
  button is *observed* down, up to one poll interval (20 ms) after the physical
  press. If the window has already begun moving by then, the recorded bounds are
  a partly-moved snapshot — harmless, because classification only needs a
  *subsequent* change, and any real drag produces many.
  The residual hole is narrow: the crossing is only left armed if the pointer
  crosses onto another display and the button is released without a single
  further bounds change being observed — i.e. press, cross a display boundary,
  and release all within roughly one to two poll intervals. Note also that a
  crossing seen *before* classification self-heals: the cancellation in rule 3
  clears the one-shot that the crossing armed. Closing the remainder would mean
  adding mouse-down events to the event tap, which is not justified for a window
  worth 20-40 ms. This is a stated limitation of poll-based detection.
- **Multi-button holds are one hold.** Button state is the OR of left and right,
  matching the existing `abort` condition. If a second button is pressed and the
  first released, the hold is treated as continuous and the classification simply
  persists longer.

## Architecture

Two pure, header-only decision functions plus a thin caller in `onTick()`. This
follows the pattern already established by `DisplayFocusGate.h` and its C++ unit
test: the state machine is testable without AppKit, and only the window and screen
lookups live in `onTick()`.

### Capture uses the window list, not the accessibility API

Drag capture must not call `get_mousewindow()`. That function is not a
side-effect-free lookup in this codebase: `fallback()` calls `activate(pid)` when
the owning application exposes no accessibility windows
(`AutoRaise.mm:378-380`), and the `kAXApplicationRole` branch activates XQuartz
(`AutoRaise.mm:419-429`). Calling it on the press tick — before the existing
`abort` check, which is precisely the guard that keeps AutoRaise from doing focus
work while a button is held — could activate an application mid-press.

Drag tracking therefore uses the existing `topwindow(point)`
(`AutoRaise.mm:323-347`), which only reads `CGWindowListCopyWindowInfo` and has no
side effects. It returns the frontmost window with `kCGWindowLayer == 0` whose
bounds contain the point; the capture reads `kCGWindowNumber` and
`kCGWindowBounds` from that dictionary. Bounds-based hit testing is correct for
this purpose even when the grabbed window is behind another one — a front window
whose rectangle does not contain the point is skipped, which is exactly the case
where the user can see and grab the window behind it.

Per-tick re-reads fetch only the captured window:
`CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, capturedID)`,
then read `kCGWindowBounds` from the single returned entry. An empty result means
the window is gone or off-screen.

Two further benefits: no `AXUIElementRef` is retained for drag tracking, so there
is no ownership or leak surface; and position and size arrive together in one
read.

### New: `WindowDragTracker.h`

A pure state-transition function owning the press/drag/release lifecycle. It takes
booleans only — no CoreGraphics or AppKit types — so the caller does the bounds
comparison and passes the result.

```c
struct DragTickDecision {
    bool captureNow;      // caller: capture the window under the pointer + its bounds
    bool releaseCapture;  // caller: forget the captured window
    bool cancelArm;       // caller: clear displayFocusArmed (true once, on classification)
    bool dragging;        // a window drag is in progress this tick
};

// buttonDown     : left or right button held this tick
// boundsChanged  : captured window's bounds differ from the recorded ones.
//                  false whenever there is no valid capture or the read failed.
// wasButtonDown  : [in/out] button state on the previous tick
// dragClassified : [in/out] this hold has been recognized as a window drag
inline DragTickDecision windowDragTick(
    bool buttonDown,
    bool boundsChanged,
    bool & wasButtonDown,
    bool & dragClassified);
```

Transitions:

| Condition | Effect |
|---|---|
| `buttonDown && !wasButtonDown` | `captureNow`; `dragClassified = false` |
| `buttonDown && wasButtonDown && !dragClassified && boundsChanged` | `dragClassified = true`; `cancelArm` |
| `buttonDown && wasButtonDown` (otherwise) | no transition |
| `!buttonDown && wasButtonDown` | `releaseCapture`; `dragClassified = false` |
| `!buttonDown && !wasButtonDown` | no transition |

`dragging` is `buttonDown && dragClassified`. It is false on the press tick (no
movement has been observed yet). `wasButtonDown` is updated to `buttonDown` before
returning.

The caller decides on its own whether a bounds read is needed this tick — namely
when a button is held, a valid capture exists, and `dragClassified` is still
false. Once classified, no further reads happen for that hold.

### Changed: `DisplayFocusGate.h`

`displayFocusGate()` gains one input, `windowDragInProgress`, inserted before the
in/out parameters:

```c
if (hasScreen) {
    if (lastDisplayIDValid && currentDisplayID != lastDisplayID && !windowDragInProgress) {
        armed = true;
        decision.armJustSet = true;
    }
    lastDisplayID = currentDisplayID;   // updated even while dragging
    lastDisplayIDValid = true;
}
decision.proceed = armed || cycleInProgress;
```

`lastDisplayID` is deliberately still updated during a drag — that is what keeps
the release from looking like a crossing. `proceed` is left alone: the existing
`abort` check already keeps the focus path silent while a button is held, and
`cancelArm` means `armed` is false by the time the button comes up.

### New: display-baseline helper

Extract the two lines that turn a point into a display id — `findScreen(point)`
then its `NSScreenNumber` — into a small helper used by both the gate block and
the drag block:

```c
// Returns true and sets outID when a screen was found under point.
static bool displayIDAt(CGPoint point, CGDirectDisplayID & outID);
```

This exists because of the stale-baseline case below; it also removes the
duplication that would otherwise appear.

### New state in `AutoRaise.mm`

Next to `lastDisplayID` / `lastDisplayIDValid` / `displayFocusArmed`
(`AutoRaise.mm:164-166`):

- `dragWasButtonDown` — `bool`, previous tick's button state.
- `dragClassified` — `bool`, this hold is a window drag.
- `dragWindowID` — `CGWindowID`, the captured window (`kCGNullWindowID` when
  there is no capture).
- `dragWindowBounds` — `CGRect`, the captured window's recorded bounds.
- `dragBoundsValid` — `bool`, whether `dragWindowBounds` holds a real reading.
  Separate from `dragWindowID` because a window number can be captured while the
  bounds reading fails.

All five are reset alongside `lastDisplayIDValid` and `displayFocusArmed` in
`toggleEnabled:` on the re-enable branch (`AutoRaise.mm:1418-1422`), so
re-enabling AutoRaise never starts with a stale hold. No CoreFoundation objects
are held, so the reset is plain assignment.

### Placement in `onTick()`

The drag-tracker block runs **after** the macOS-12 coordinate-correction block
(so `gateMousePoint` and the corrected `mousePoint` are both available) and
**before** the `if (ignoreTimes) { … return; }` / `appWasActivated` housekeeping
at `AutoRaise.mm:1053-1059`.

Placing it before those early returns matters: `ignoreTimes` is set to 3 by the
event tap after a task switch (`AutoRaise.mm:1308`, `AutoRaise.mm:1315`), and a
press landing inside that window would otherwise be missed, leaving
`dragWasButtonDown` stale and that whole drag unclassified.

Per tick, in order:

1. `buttonDown` = left or right button state (same calls as the existing `abort`
   check; the existing calls stay where they are).
2. `boundsChanged` = `false`. If `buttonDown && dragWindowID != kCGNullWindowID
   && dragBoundsValid && !dragClassified`, read the captured window's current
   bounds and compare. A failed read (empty result) leaves `boundsChanged` false
   and leaves the capture in place; the hold simply may never classify.
3. Call `windowDragTick(...)`.
4. Act on the decision:
   - `captureNow` → `topwindow(gateMousePoint)`; on a hit, store `kCGWindowNumber`
     into `dragWindowID` and `kCGWindowBounds` into `dragWindowBounds`, and set
     `dragBoundsValid` to whether the bounds dictionary parsed. On a miss, set
     `dragWindowID = kCGNullWindowID` and `dragBoundsValid = false`.
   - `cancelArm` → `displayFocusArmed = false`, and also clear `delayTicks` and
     `raiseTimes` so no in-flight focus cycle survives the drag; log under
     `verbose`.
   - `releaseCapture` → `dragWindowID = kCGNullWindowID`,
     `dragBoundsValid = false`.
5. If `decision.dragging` and `displayIDAt(gateMousePoint, id)` succeeds, record
   the baseline here: `lastDisplayID = id; lastDisplayIDValid = true;`. See below.
6. Pass `decision.dragging` into `displayFocusGate(...)` in the existing gate
   block, which runs unmoved.

#### Why the baseline is recorded twice, and why the gate is not moved

The gate normally records `lastDisplayID` itself, but it sits *after* the
`ignoreTimes` / `appWasActivated` early returns. On a tick that returns there, no
baseline is recorded. If the pointer changes display during such a tick and the
button comes up before the next gate tick, the first gate tick after the gap sees
a different display with `windowDragInProgress` already false, and arms a
one-shot for a crossing that was part of the drag.

Reachability is narrow: `appWasActivated` is only set for task-switcher
activations (`appActivated()` returns early at `AutoRaise.mm:899` unless
`activated_by_task_switcher`, with `altTaskSwitcher` off by default), so clicking
a window to drag it does not trigger this. The reachable trigger is a cmd-tab or
cmd-grave during a drag, which sets `ignoreTimes = 3`.

Step 5 closes it by recording the baseline during drags, before any early return
can skip it. The alternative — relocating the whole gate block above the
housekeeping — is **rejected**: the gate's `if (!proceed) return;` would then
preempt the `ignoreTimes` decrement, so `ignoreTimes` would stay stuck until the
next display crossing. That is the same class of stale-housekeeping bug the
2026-07-03 spec was written to prevent.

### Bounds comparison

Bounds from `CGWindowListCopyWindowInfo` are integral, but the comparison uses a
1.0 point threshold on any of the four components rather than exact float
equality, so rounding noise cannot classify a stationary window as dragged.

### Cost

One window-list hit test (`topwindow`) on the tick a button goes down, and one
single-window bounds read per tick while a button is held, stopping as soon as the
hold is classified. The idle path — no button held — adds only two
`CGEventSourceButtonState` calls per tick, the same calls the existing `abort`
check already makes later in the same tick. Those existing calls stay in place;
they cover cases the tracker does not (Dock, Mission Control, disable key).

## Testing

### Unit tests (C++)

New `test/engine/test_window_drag_tracker.cpp`, matching the style of the existing
gate test:

- Idle ticks with no button: no capture, no cancel, not dragging.
- Press tick: `captureNow` set, `dragging` false, `dragClassified` false.
- Held with no bounds change: never classified, no cancel, not dragging.
- Held, bounds change: classified, `cancelArm` set exactly once, `dragging` true
  on that tick and on subsequent held ticks.
- Held, bounds change again after classification: no second `cancelArm`.
- Release: `releaseCapture` set, `dragClassified` cleared, not dragging.
- Press → drag → release → press again: the second hold starts unclassified.
- Press with no capture (caller passes `boundsChanged` permanently false): never
  classified, `dragging` stays false for the whole hold.

Extend `test/engine/test_display_focus_gate.cpp` for the new input:

- Crossing with `windowDragInProgress` true: no arm, `armed` stays false, but
  `lastDisplayID` is updated to the new display.
- Immediately after, same display with dragging false: no arm — proves the
  release is not a crossing.
- Crossing with `windowDragInProgress` true while `armed` was already true: the
  gate leaves `armed` alone (cancellation is the caller's job via `cancelArm`)
  and does not set `armJustSet`.
- Crossing with `windowDragInProgress` false: arms, as today.
- Every existing assertion still holds; those call sites are updated to pass
  `windowDragInProgress = false` explicitly (the parameter sits before the in/out
  references, so it cannot carry a default argument).

### Makefile

The `test` target currently compiles and runs only
`test/engine/test_display_focus_gate.cpp` (`Makefile:37-38`). It must build and
run both test binaries, and fail if either fails.

### Manual verification, multi-monitor, `-verbose true`

`onTick()` has no seam for automated integration tests, so the ordering and
side-effect decisions above are verified by hand:

- Drag a window from display A to display B, release, move the pointer off it →
  the dragged window keeps focus; the log shows no "Display crossing: armed" for
  the drag.
- Walk the pointer from A to B without dragging → the window settled on is
  focused after the delay, exactly as before.
- Step onto empty desktop on B (one-shot stays armed), then grab and drag a
  window on B, release, move the pointer away → focus stays on the dragged
  window (the pending one-shot was cancelled).
- Cross onto B so a focus is counting down, and within the delay grab and drag a
  window → the counting-down focus is cancelled, nothing else is focused.
- Resize a window by its top-left corner across the display boundary → focus
  stays on it.
- Resize by its bottom-right corner across the boundary → focus stays on it
  (covered by comparing bounds, not origin alone).
- **cmd-tab mid-drag:** start dragging a window on A, press cmd-tab during the
  drag, continue onto B, release, move the pointer away → focus stays on the
  dragged window. Covers the `ignoreTimes` gap that step 5 exists for.
- **No activation on press:** press and hold on a window of an app with poor
  accessibility support (a PWA, or an XQuartz window if available) → the log
  shows no "Activate" and no "Fallback" attributable to the press tick. Covers
  the reason capture avoids `get_mousewindow()`.
- Drag a window and release it while the pointer is over another display's
  window → focus stays on the dragged window.
- Move around within one display → still silent.
- Press on empty desktop, rubber-band across the boundary, release, settle on a
  window → the window is focused (no capture, so no suppression).
- Drag a text selection across displays and release → a one-shot still fires.
  Expected, per "Accepted limitations".
- Disable AutoRaise mid-drag, release the button, re-enable, then cross displays
  → normal arming; no stale hold.

## Known follow-up (not in this spec)

**Microsoft Teams live video does not take focus.** With a Teams meeting window
on another display, moving the pointer onto the large live-video tile does not
focus the Teams window; the one-shot stays armed and only fires once the pointer
reaches the window's chrome. The same spot showing a static avatar image works
correctly, which points at Teams rendering live video through a layer or helper
process that `get_mousewindow()` cannot trace back to the Teams window — it
returns either no raisable window or a window owned by a helper PID that exposes
no accessibility windows, in which case `fallback()`'s layer-0 hit test also
fails.

Which of those paths is actually taken is unverified. The next step is a
diagnostic run with `-verbose true` during a live share to capture what
`get_mousewindow()` reports at that point, then a separate design. Nothing in
this spec changes that behavior.

## Review history

Independently reviewed 2026-08-12 (GPT-5.5 via cursor-agent, read-only). Verdict:
needs revision. Resolution:

- **Accepted, fixed more broadly than proposed:** `get_mousewindow()` has
  activation side effects and must not be used for capture. Capture now uses the
  side-effect-free window list, which also eliminates the `AXUIElementRef`
  ownership surface the reviewer flagged separately.
- **Accepted, fixed differently:** the stale `lastDisplayID` baseline during
  `ignoreTimes` / `appWasActivated` early returns. The reviewer's proposal to
  move the gate above the housekeeping would preempt the `ignoreTimes`
  decrement; step 5 records the baseline during drags instead.
- **Accepted:** bounds/capture validity lifecycle underspecified
  (`dragBoundsValid` added); `make test` builds only one test binary; the
  sub-20 ms claim was too absolute.
- **Accepted in substance:** integration behavior was untested. `onTick()` has no
  test seam, so the cmd-tab-mid-drag and no-activation-on-press cases were added
  to the manual checklist.
- **Amended after the final whole-branch review (2026-08-13):** capture originally
  used the corrected `mousePoint` for consistency with the rest of the focus
  path. That reasoning was backwards — `WINDOW_CORRECTION` biases the hit test
  toward the window the pointer is moving *into*, and the menu-bar correction can
  snap the y coordinate to the screen top, so a press near a window's edge could
  hit-test outside it and silently skip drag detection for that hold. Capture now
  uses the raw `gateMousePoint`. The baseline recording always used
  `gateMousePoint` and is unchanged.
- **Not accepted as critical:** the poll-latency race. A crossing survives only
  if press, display crossing and release all fall inside roughly one to two
  20 ms poll intervals, and a crossing seen before classification is self-healed
  by the cancellation in behavior rule 3. Documented as a stated limitation
  rather than justifying mouse-down events on the event tap.
