# AutoRaise — Don't arm a focus while dragging a window across displays

**Date:** 2026-08-12
**Status:** Approved design, pending implementation plan

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
- Everything else about the display-focus behavior is unchanged.

## Non-Goals

- Explicitly focusing the dragged window. macOS already does this on grab.
- Suppressing arming for *any* held mouse button. Only window drags are
  suppressed (decided by the user). A text selection dragged across displays
  still arms a one-shot; see "Accepted consequences".
- Fixing the Microsoft Teams live-video focus problem. Separate work; see
  "Known follow-up".

## Behavior

1. On the tick where a mouse button goes down, AutoRaise captures the window
   under the pointer and records that window's frame (position and size).
2. While the button stays down and the hold has not yet been classified,
   AutoRaise re-reads that window's frame each tick. The first time the frame
   differs from the recorded one, the hold is classified a **window drag**.
3. On classification, and for the rest of the hold:
   - display crossings do not arm a one-shot focus;
   - any one-shot already pending is cancelled.
4. The gate keeps recording which display the cursor is on throughout the drag,
   so releasing the button never registers as a crossing.
5. After the release nothing is pending. The next genuine crossing arms a
   one-shot exactly as it does today.
6. Movement within a single display is unchanged — still silent.

### Frame change, not just position

The classification compares the window's **frame**: position or size. Position
alone is not enough to be coherent. Resizing a window by its top or left edge
moves the origin, while resizing by the right or bottom edge does not — comparing
only position would suppress the one-shot for the first case and not the second.
Treating any frame change as a drag makes resizing behave consistently: while the
user is manipulating one window, that window does not lose focus. This is the
approved intent ("keep the resize behavior too") applied to all edges.

### Accepted consequences

- Dragging a text selection, or holding a button while moving the pointer without
  touching a window's frame, still arms a one-shot on a display crossing. This
  follows directly from narrowing suppression to window drags. It is expected
  behavior, not a regression.
- Pressing on the desktop (rubber-band selection) captures no window, so the hold
  can never be classified a drag, and a crossing during it arms normally.
- A press-and-release completed inside a single 20 ms poll interval is not
  observed at all. Such a hold cannot have dragged a window across a display
  boundary, so this is harmless.
- If a second button is pressed and the first released during one hold, the hold
  is treated as continuous (the button state is the OR of left and right, matching
  the existing `abort` condition). The classification simply persists longer.

## Architecture

Two pure, header-only decision functions plus a thin caller in `onTick()`. This
follows the pattern already established by `DisplayFocusGate.h` and its C++ unit
test: the state machine is testable without AppKit, and only the accessibility
and screen lookups live in `onTick()`.

### New: `WindowDragTracker.h`

A pure state-transition function owning the press/drag/release lifecycle. It takes
booleans only — no CoreGraphics or AppKit types — so the caller does the frame
comparison and passes the result.

```c
struct DragTickDecision {
    bool captureNow;      // caller: capture window under pointer + its frame
    bool releaseCapture;  // caller: release the captured window reference
    bool cancelArm;       // caller: clear displayFocusArmed (true once, on classification)
    bool dragging;        // a window drag is in progress this tick
};

// buttonDown        : left or right button held this tick
// frameChanged      : captured window's frame differs from the recorded one
//                     (false when there is no capture, or the read failed)
// wasButtonDown     : [in/out] button state on the previous tick
// dragClassified    : [in/out] this hold has been recognized as a window drag
inline DragTickDecision windowDragTick(
    bool buttonDown,
    bool frameChanged,
    bool & wasButtonDown,
    bool & dragClassified);
```

Transitions:

| Condition | Effect |
|---|---|
| `buttonDown && !wasButtonDown` | `captureNow`; `dragClassified = false` |
| `buttonDown && wasButtonDown && !dragClassified && frameChanged` | `dragClassified = true`; `cancelArm` |
| `buttonDown && wasButtonDown` (otherwise) | no transition |
| `!buttonDown && wasButtonDown` | `releaseCapture`; `dragClassified = false` |
| `!buttonDown && !wasButtonDown` | no transition |

`dragging` is `buttonDown && dragClassified`. It is false on the press tick (no
movement has been observed yet). `wasButtonDown` is updated to `buttonDown` before
returning.

The caller decides on its own whether a frame read is needed this tick — namely
when a button is held, a capture exists, and `dragClassified` is still false. Once
classified, no further reads happen for that hold.

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

### New state in `AutoRaise.mm`

Next to `lastDisplayID` / `lastDisplayIDValid` / `displayFocusArmed`
(`AutoRaise.mm:164-166`):

- `dragWasButtonDown` — `bool`, previous tick's button state.
- `dragClassified` — `bool`, this hold is a window drag.
- `_dragWindow` — `AXUIElementRef`, the captured window (retained; `NULL` when
  there is no capture).
- `dragWindowFrame` — `CGRect`, the captured window's recorded frame.

All four are reset alongside `lastDisplayIDValid` and `displayFocusArmed` in
`toggleEnabled:` on the re-enable branch (`AutoRaise.mm:1418-1422`), releasing
`_dragWindow` if held, so re-enabling AutoRaise never starts with a stale hold.

### Placement in `onTick()`

The drag-tracker block runs **after** the macOS-12 coordinate-correction block
(so it uses the same corrected `mousePoint` as the rest of the focus path) and
**before** the `if (ignoreTimes) { … return; }` / `appWasActivated` housekeeping
at `AutoRaise.mm:1053-1059`.

Placing it before those early returns matters: `ignoreTimes` is set to 3 after a
task switch, and a press landing inside that window would otherwise be missed,
leaving `dragWasButtonDown` stale and that whole drag unclassified.

Per tick, in order:

1. `buttonDown` = left or right button state (same calls as the existing `abort`
   check).
2. `frameChanged` = `false`; if `buttonDown && _dragWindow && !dragClassified`,
   read the captured window's position and size and compare with
   `dragWindowFrame`. A read failure (window gone) leaves `frameChanged` false.
3. Call `windowDragTick(...)`.
4. Act on the decision:
   - `captureNow` → release any stale `_dragWindow`, then
     `_dragWindow = get_mousewindow(mousePoint)`; if non-`NULL`, record its frame
     into `dragWindowFrame`.
   - `cancelArm` → `displayFocusArmed = false`; also clear `delayTicks` and
     `raiseTimes` so no in-flight cycle survives the drag; log under `verbose`.
   - `releaseCapture` → release `_dragWindow`, set it to `NULL`.
5. Pass `decision.dragging` into `displayFocusGate(...)` in the existing gate
   block.

### Frame comparison

Positions and sizes from the accessibility API are integral in practice, but the
comparison uses a 1.0 point threshold on any of the four components rather than
exact float equality, so sub-pixel noise cannot classify a stationary window as
dragged.

### Cost

One accessibility hit-test (`get_mousewindow`) on the tick a button goes down,
and one position+size read per tick while a button is held, stopping as soon as
the hold is classified. The idle path — no button held — adds only two
`CGEventSourceButtonState` calls per tick, the same calls the `abort` check
already makes later in the same tick. The existing `abort` calls are left in
place; they cover cases the tracker does not (Dock, Mission Control, disable key).

## Testing

### Unit tests (C++, wired into `make test`)

New `test/engine/test_window_drag_tracker.cpp`, matching the style of the existing
gate test:

- Idle ticks with no button: no capture, no cancel, not dragging.
- Press tick: `captureNow` set, `dragging` false, `dragClassified` false.
- Held with no frame change: never classified, no cancel, not dragging.
- Held, frame changes: classified, `cancelArm` set exactly once, `dragging` true
  on that tick and on subsequent held ticks.
- Held, frame changes a second time after classification: no second `cancelArm`.
- Release: `releaseCapture` set, `dragClassified` cleared, not dragging.
- Press → drag → release → press again: the second hold starts unclassified.

Extend `test/engine/test_display_focus_gate.cpp` for the new input:

- Crossing with `windowDragInProgress` true: no arm, `armed` stays false, but
  `lastDisplayID` is updated to the new display.
- Immediately after, same display with dragging false: no arm (no crossing
  remains to detect) — proves the release is not a crossing.
- Crossing with `windowDragInProgress` true while `armed` was already true: the
  gate leaves `armed` alone (cancellation is the caller's job via `cancelArm`),
  and still does not set `armJustSet`.
- Crossing with `windowDragInProgress` false: arms, as today.
- Every existing assertion still holds; those call sites are updated to pass
  `windowDragInProgress = false` explicitly (the parameter sits before the in/out
  references, so it cannot carry a default argument).

### Manual verification, multi-monitor, `-verbose true`

- Drag a window from display A to display B, release, move the pointer off it →
  the dragged window keeps focus; log shows no "Display crossing: armed" for the
  drag.
- Walk the pointer from A to B without dragging → the window settled on is
  focused after the delay, exactly as before.
- Step onto empty desktop on B (one-shot stays armed), then grab and drag a
  window on B, release, move the pointer away → focus stays on the dragged
  window (the pending one-shot was cancelled).
- Resize a window by its top-left corner across the display boundary → focus
  stays on it.
- Resize by its bottom-right corner across the boundary → focus stays on it
  (covered by the frame comparison, not position alone).
- Move around within one display → still silent.
- Press on empty desktop, rubber-band across the boundary, release, settle on a
  window → the window is focused (no capture, so no suppression).
- Drag a text selection across displays and release → a one-shot still fires.
  Expected, per "Accepted consequences".
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
