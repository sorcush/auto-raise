# Window-Drag Focus Suppression Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop AutoRaise from arming a one-shot focus when the cursor crosses onto another display while the user is dragging or resizing a window, so the dragged window keeps focus after the drop.

**Architecture:** A pure, header-only press/drag/release state machine (`WindowDragTracker.h`) is driven once per poll tick from `onTick()`. It classifies a button hold as a window drag by watching the grabbed window's bounds change, using the side-effect-free window list rather than the accessibility API. Its `dragging` output feeds a new input on the existing `displayFocusGate()`, which then records the display without arming. Classification also cancels any focus already pending or counting down.

**Tech Stack:** Objective-C++ (`.mm`) compiled by `g++` with `-fobjc-arc`, AppKit / ApplicationServices / CoreGraphics. Header-only pure functions unit-tested with plain C++17 binaries under `test/engine/`, run by `make test`.

**Spec:** `docs/superpowers/specs/2026-08-12-window-drag-focus-design.md`

## Global Constraints

- The whole app is one file, `AutoRaise.mm`. Pure decision logic goes in header-only files at the repo root and is unit-tested; everything touching AppKit, the accessibility API or the window server stays in `AutoRaise.mm`. Follow the existing `DisplayFocusGate.h` pattern exactly.
- **Drag tracking must never call `get_mousewindow()`.** It is not side-effect-free: `fallback()` calls `activate(pid)` (`AutoRaise.mm:378-380`) and the `kAXApplicationRole` branch activates XQuartz (`AutoRaise.mm:419-429`). Use `topwindow()` and `CGWindowListCopyWindowInfo` only.
- Poll interval is 20 ms (`kStepMs`, `AutoRaise.mm:1338`). Everything in this plan runs once per tick.
- Button state is the OR of left and right, matching the existing `abort` condition at `AutoRaise.mm:1096-1097`. The existing `abort` calls stay exactly where they are — this plan adds a second read earlier in the tick, it does not move the old one.
- Bounds comparison uses a **1.0 point threshold** on each of the four components, never exact float equality.
- The file is compiled with ARC (`-fobjc-arc` in `Makefile:2`). CoreFoundation types (`CFArrayRef`, `CFDictionaryRef`) are *not* ARC-managed — release them explicitly. Do not copy the `(NSString *) CFBridgingRelease(kCGWindowBounds)` idiom at `AutoRaise.mm:330`; use `(__bridge id)` casts for CoreGraphics string constants.
- Build with `make`; run unit tests with `make test`. Both must pass before every commit.

---

### Task 1: Pure window-drag state machine

**Files:**
- Create: `WindowDragTracker.h`
- Test: `test/engine/test_window_drag_tracker.cpp`
- Modify: `Makefile:37-38` (the `test` target)
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct DragTickDecision { bool captureNow; bool releaseCapture; bool cancelArm; bool dragging; };` and `inline DragTickDecision windowDragTick(bool buttonDown, bool boundsChanged, bool & wasButtonDown, bool & dragClassified);` — used by Task 3.

- [ ] **Step 1: Write the failing test**

Create `test/engine/test_window_drag_tracker.cpp`. It mirrors the style of the existing `test/engine/test_display_focus_gate.cpp` — no test framework, a `check()` helper, a non-zero exit on failure.

```cpp
#include "WindowDragTracker.h"
#include <cstdio>

static int failures = 0;
static void check(bool cond, const char * msg) {
    if (!cond) { printf("FAIL: %s\n", msg); failures++; }
    else       { printf("ok:   %s\n", msg); }
}

int main() {
    // Fresh state: no button held, nothing classified.
    bool wasDown = false; bool classified = false;

    // 1) Idle tick: nothing happens at all.
    DragTickDecision d = windowDragTick(false, false, wasDown, classified);
    check(!d.captureNow && !d.releaseCapture && !d.cancelArm && !d.dragging,
          "idle: no capture, no release, no cancel, not dragging");

    // 2) Press tick: capture the window, but nothing has moved yet.
    d = windowDragTick(true, false, wasDown, classified);
    check(d.captureNow && !d.cancelArm, "press: captureNow, no cancel");
    check(!d.dragging && !classified, "press: not yet a drag");

    // 3) Held, window has not moved: still not a drag, no repeat capture.
    d = windowDragTick(true, false, wasDown, classified);
    check(!d.captureNow && !d.dragging && !classified, "held still: not dragging");

    // 4) Held and the bounds changed: classified, cancel fires.
    d = windowDragTick(true, true, wasDown, classified);
    check(classified && d.dragging, "bounds changed: classified and dragging");
    check(d.cancelArm, "bounds changed: cancelArm fires");

    // 5) Bounds change again: no second cancel.
    d = windowDragTick(true, true, wasDown, classified);
    check(!d.cancelArm && d.dragging, "second change: cancelArm fires only once");

    // 6) Held with no further change: stays a drag for the rest of the hold.
    d = windowDragTick(true, false, wasDown, classified);
    check(d.dragging && !d.cancelArm, "held after classify: still dragging");

    // 7) Release: capture dropped, classification cleared.
    d = windowDragTick(false, false, wasDown, classified);
    check(d.releaseCapture && !classified && !d.dragging, "release: capture dropped");

    // 8) Idle after release: no repeat release.
    d = windowDragTick(false, false, wasDown, classified);
    check(!d.releaseCapture && !d.captureNow && !d.dragging, "idle after release: quiet");

    // 9) A second hold starts unclassified, and a hold whose caller never reports
    //    a bounds change (no capture, or an unreadable window) never classifies.
    d = windowDragTick(true, false, wasDown, classified);
    check(d.captureNow && !classified, "second press: fresh hold, captures again");
    d = windowDragTick(true, false, wasDown, classified);
    check(!d.dragging && !classified && !d.cancelArm, "no bounds change: never classifies");
    d = windowDragTick(true, false, wasDown, classified);
    check(!d.dragging && !classified, "no bounds change: still not a drag");
    d = windowDragTick(false, false, wasDown, classified);
    check(d.releaseCapture && !d.dragging, "no bounds change: clean release");

    if (failures) { printf("%d FAILURES\n", failures); return 1; }
    printf("ALL PASS\n");
    return 0;
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `g++ -std=c++17 -Wall -I. -o test/engine/test_window_drag_tracker test/engine/test_window_drag_tracker.cpp`

Expected: FAIL to compile — `fatal error: 'WindowDragTracker.h' file not found`.

- [ ] **Step 3: Write the header**

Create `WindowDragTracker.h`:

```c
#ifndef WINDOW_DRAG_TRACKER_H
#define WINDOW_DRAG_TRACKER_H

// Decision returned by windowDragTick for a single poll tick.
struct DragTickDecision {
    bool captureNow;      // capture the window under the pointer and its bounds
    bool releaseCapture;  // forget the captured window
    bool cancelArm;       // clear a pending one-shot focus (fires once, on classification)
    bool dragging;        // a window drag is in progress this tick
};

// Pure press/drag/release state machine for window-drag detection. No AppKit.
//
//   buttonDown     : left or right mouse button held this tick
//   boundsChanged  : the captured window's bounds differ from the recorded ones.
//                    MUST be false whenever there is no valid capture or the
//                    bounds read failed.
//   wasButtonDown  : [in/out] button state on the previous tick
//   dragClassified : [in/out] this hold has been recognised as a window drag
//
// The caller decides whether a bounds read is needed this tick: only when a
// button is held, a valid capture exists, and dragClassified is still false.
// Once classified, no further reads happen for that hold.
//
// dragging is false on the press tick — no movement has been observed yet.
inline DragTickDecision windowDragTick(
    bool buttonDown,
    bool boundsChanged,
    bool & wasButtonDown,
    bool & dragClassified)
{
    DragTickDecision decision = { false, false, false, false };

    if (buttonDown && !wasButtonDown) {
        decision.captureNow = true;
        dragClassified = false;
    } else if (buttonDown) {
        if (!dragClassified && boundsChanged) {
            dragClassified = true;
            decision.cancelArm = true;
        }
    } else if (wasButtonDown) {
        decision.releaseCapture = true;
        dragClassified = false;
    }

    decision.dragging = buttonDown && dragClassified;
    wasButtonDown = buttonDown;
    return decision;
}

#endif // WINDOW_DRAG_TRACKER_H
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `g++ -std=c++17 -Wall -I. -o test/engine/test_window_drag_tracker test/engine/test_window_drag_tracker.cpp && ./test/engine/test_window_drag_tracker`

Expected: every line prefixed `ok:`, then `ALL PASS`, exit 0.

- [ ] **Step 5: Wire both test binaries into `make test`**

The current target at `Makefile:37-38` builds and runs only the gate test. Replace those two lines with:

```makefile
test: DisplayFocusGate.h WindowDragTracker.h test/engine/test_display_focus_gate.cpp test/engine/test_window_drag_tracker.cpp
	g++ -std=c++17 -Wall -I. -o test/engine/test_display_focus_gate test/engine/test_display_focus_gate.cpp
	g++ -std=c++17 -Wall -I. -o test/engine/test_window_drag_tracker test/engine/test_window_drag_tracker.cpp
	./test/engine/test_display_focus_gate
	./test/engine/test_window_drag_tracker
```

Recipe lines are separate shell invocations and `make` stops at the first non-zero exit, so either test failing fails the target.

**Note:** recipe lines must be indented with a real tab, not spaces.

Add the new binary to `.gitignore`, on the line after `test/engine/test_display_focus_gate`:

```
test/engine/test_window_drag_tracker
```

- [ ] **Step 6: Run the full test target**

Run: `make test`

Expected: both binaries compile, both print `ALL PASS`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add WindowDragTracker.h test/engine/test_window_drag_tracker.cpp Makefile .gitignore
git commit -m "feat(engine): pure window-drag state machine with unit tests"
```

---

### Task 2: Teach the display gate about drags

**Files:**
- Modify: `DisplayFocusGate.h:24-43`
- Test: `test/engine/test_display_focus_gate.cpp`
- Modify: `AutoRaise.mm:1073-1075` (call site, so the app still compiles)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `displayFocusGate(uint32_t currentDisplayID, bool hasScreen, bool cycleInProgress, bool windowDragInProgress, uint32_t & lastDisplayID, bool & lastDisplayIDValid, bool & armed)` — the new fourth parameter is positional and cannot have a default, because the parameters after it are references. Task 3 passes `dragDecision.dragging` here.

- [ ] **Step 1: Write the failing tests**

In `test/engine/test_display_focus_gate.cpp`, update every existing `displayFocusGate(...)` call to pass `false` as the new fourth argument, then append the new cases before the final `if (failures)` block. The existing calls become, in order:

```cpp
    GateDecision d = displayFocusGate(1, true, false, false, last, valid, armed);
    // ...
    d = displayFocusGate(1, true, false, false, last, valid, armed);
    // ...
    d = displayFocusGate(2, true, false, false, last, valid, armed);
    // ...
    d = displayFocusGate(2, true, false, false, last, valid, armed);
    // ...
    d = displayFocusGate(0, false, false, false, last, valid, armed);
    // ...
    d = displayFocusGate(2, true, true, false, last, valid, armed);
    // ...
    d = displayFocusGate(2, true, false, false, last, valid, armed);
```

Their assertions are unchanged. Then append:

```cpp
    // 8) Crossing while a window drag is in progress: no arm, but the display
    //    baseline still moves to the new display.
    {
        uint32_t dlast = 1; bool dvalid = true; bool darmed = false;
        GateDecision g = displayFocusGate(2, true, false, true, dlast, dvalid, darmed);
        check(!g.armJustSet && !darmed, "drag crossing: does not arm");
        check(dlast == 2, "drag crossing: baseline follows the new display");

        // 9) The release is not a crossing: same display, dragging false.
        g = displayFocusGate(2, true, false, false, dlast, dvalid, darmed);
        check(!g.armJustSet && !darmed && !g.proceed, "after release: no crossing, silent");
    }

    // 10) Crossing while dragging with a one-shot already pending: the gate
    //     leaves `armed` alone. Cancelling is the caller's job via cancelArm.
    {
        uint32_t dlast = 1; bool dvalid = true; bool darmed = true;
        GateDecision g = displayFocusGate(2, true, false, true, dlast, dvalid, darmed);
        check(!g.armJustSet, "drag crossing with pending arm: no new arm");
        check(darmed && g.proceed, "drag crossing with pending arm: gate does not clear it");
        check(dlast == 2, "drag crossing with pending arm: baseline still follows");
    }

    // 11) Crossing with no drag in progress arms exactly as before.
    {
        uint32_t dlast = 1; bool dvalid = true; bool darmed = false;
        GateDecision g = displayFocusGate(2, true, false, false, dlast, dvalid, darmed);
        check(g.armJustSet && darmed && g.proceed, "normal crossing: still arms");
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`

Expected: FAIL to compile the gate test — `too many arguments to function call, expected 6, have 7`.

- [ ] **Step 3: Add the parameter to the gate**

In `DisplayFocusGate.h`, add `windowDragInProgress` to the signature and the arming condition, and extend the comment block. The function becomes:

```c
// Pure decision function for display-change focus gating. No AppKit.
//
//   currentDisplayID     : display id under the cursor (0 when hasScreen is false)
//   hasScreen            : whether a screen was found under the cursor this tick
//   cycleInProgress      : whether a focus cycle is already running (delayTicks || raiseTimes)
//   windowDragInProgress : whether the user is dragging/resizing a window this tick
//   lastDisplayID        : [in/out] display id seen on the previous qualifying tick
//   lastDisplayIDValid   : [in/out] false until the first qualifying tick seeds it
//   armed                : [in/out] whether a one-shot focus is pending
//
// Arming happens here; DISARMING is the caller's job (it clears `armed` when it
// actually fires a raise). `cycleInProgress` keeps an in-flight cycle alive after
// disarm so the stubborn-app multi-raise repeats can finish.
//
// While a window drag is in progress the baseline still follows the cursor, so
// releasing the button is never mistaken for a display crossing. Cancelling an
// already-pending `armed` is the caller's job too (see WindowDragTracker.h).
inline GateDecision displayFocusGate(
    uint32_t currentDisplayID,
    bool hasScreen,
    bool cycleInProgress,
    bool windowDragInProgress,
    uint32_t & lastDisplayID,
    bool & lastDisplayIDValid,
    bool & armed)
{
    GateDecision decision = { false, false };
    if (hasScreen) {
        if (lastDisplayIDValid && currentDisplayID != lastDisplayID && !windowDragInProgress) {
            armed = true;
            decision.armJustSet = true;
        }
        lastDisplayID = currentDisplayID;
        lastDisplayIDValid = true;
    }
    decision.proceed = armed || cycleInProgress;
    return decision;
}
```

- [ ] **Step 4: Update the call site so the app still builds**

In `AutoRaise.mm:1073-1075`, pass `false` for now — Task 3 replaces it with the real value:

```objc
        GateDecision gateDecision = displayFocusGate(
            currentDisplayID, hasScreen, (delayTicks != 0 || raiseTimes != 0), false,
            lastDisplayID, lastDisplayIDValid, displayFocusArmed);
```

- [ ] **Step 5: Run the tests and the build**

Run: `make test && make AutoRaise`

Expected: both test binaries print `ALL PASS`; `AutoRaise` compiles with no warnings.

- [ ] **Step 6: Commit**

```bash
git add DisplayFocusGate.h test/engine/test_display_focus_gate.cpp AutoRaise.mm
git commit -m "feat(engine): displayFocusGate takes a window-drag input"
```

---

### Task 3: Drive the tracker from onTick

**Files:**
- Modify: `AutoRaise.mm` — include (`:31`), globals (`:164-167`), helpers (after `findScreen`, `:592`), `onTick()` drag block (before `:1053`), gate block (`:1068-1081`), `toggleEnabled:` (`:1418-1422`)
- Modify: `README.md` (the "Behavior in detail" list)

**Interfaces:**
- Consumes: `windowDragTick(bool, bool, bool &, bool &) -> DragTickDecision` from Task 1; `displayFocusGate(uint32_t, bool, bool, bool, uint32_t &, bool &, bool &)` from Task 2.
- Produces: nothing consumed by later tasks.

There is no test seam in `onTick()` — it reads the live window server and screen list — so this task has no unit test. Its behavior is verified by hand in Task 4. Keep the changes minimal and exactly as written below.

- [ ] **Step 1: Add the include**

After `AutoRaise.mm:31` (`#include "DisplayFocusGate.h"`):

```objc
#include "WindowDragTracker.h"
```

- [ ] **Step 2: Add the drag-tracking globals**

After `AutoRaise.mm:166` (`static bool displayFocusArmed = false;`), before `static bool autoRaiseEnabled = true;`:

```objc
static bool dragWasButtonDown = false;
static bool dragClassified = false;
static CGWindowID dragWindowID = kCGNullWindowID;
static CGRect dragWindowBounds = CGRectZero;
static bool dragBoundsValid = false;
```

- [ ] **Step 3: Add the three helpers**

Insert after `findScreen()` ends at `AutoRaise.mm:592`. `windowBoundsForID` and `captureDragWindow` are deliberately CoreFoundation-only and never touch the accessibility API — see the Global Constraints. `topwindow()` is already declared above this point (`AutoRaise.mm:323`).

```objc
// Display id under a point, without the caller repeating the deviceDescription
// lookup. Returns false when the point is not on any screen.
inline bool displayIDAt(CGPoint point, CGDirectDisplayID & outID) {
    NSScreen * screen = findScreen(point);
    if (!screen) { return false; }
    outID = (CGDirectDisplayID) [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    return true;
}

// Current bounds of one window, by id. Side-effect free: reads the window
// server only. Returns false when the window is gone or off-screen.
inline bool windowBoundsForID(CGWindowID windowID, CGRect & outBounds) {
    if (windowID == kCGNullWindowID) { return false; }
    CFArrayRef _info = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, windowID);
    if (!_info) { return false; }
    bool found = false;
    if (CFArrayGetCount(_info) > 0) {
        CFDictionaryRef _window = (CFDictionaryRef) CFArrayGetValueAtIndex(_info, 0);
        CFDictionaryRef _bounds = (CFDictionaryRef) CFDictionaryGetValue(_window, kCGWindowBounds);
        if (_bounds) { found = CGRectMakeWithDictionaryRepresentation(_bounds, &outBounds); }
    }
    CFRelease(_info);
    return found;
}

// Capture the window the user just pressed on: the frontmost normal (layer 0)
// window whose bounds contain the point. All-or-nothing — on any failure the
// caller records no capture and the hold can never be classified a drag.
// Must NOT use get_mousewindow(): that can activate an application.
inline bool captureDragWindow(CGPoint point, CGWindowID & outID, CGRect & outBounds) {
    NSDictionary * top_window = topwindow(point);
    if (!top_window) { return false; }
    CGWindowID windowID = (CGWindowID) [top_window[(__bridge id) kCGWindowNumber] unsignedIntValue];
    if (windowID == kCGNullWindowID) { return false; }
    if (!windowBoundsForID(windowID, outBounds)) { return false; }
    outID = windowID;
    return true;
}
```

Bounds are re-read through `windowBoundsForID` rather than parsed from the dictionary `topwindow()` already returned, so the captured value and every later comparison come from one code path.

- [ ] **Step 4: Insert the drag block in `onTick()`**

Insert immediately after the macOS-12 correction block closes at `AutoRaise.mm:1051`, and immediately *before* `if (ignoreTimes) {` at `AutoRaise.mm:1053`. The placement is load-bearing: `ignoreTimes` is set to 3 by the event tap after a task switch (`AutoRaise.mm:1308`, `AutoRaise.mm:1315`) and that branch returns early, so a press landing inside those three ticks would otherwise be missed.

```objc
    // Window-drag tracking. A display crossing that happens while the user is
    // dragging or resizing a window must not arm a focus, and recognising a drag
    // cancels one that is already pending. Runs before the housekeeping returns
    // below so a press is never missed.
    bool dragInProgress = false;
    {
        bool buttonDown =
            CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft) ||
            CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight);

        bool boundsChanged = false;
        if (buttonDown && dragBoundsValid && !dragClassified) {
            CGRect currentBounds;
            if (windowBoundsForID(dragWindowID, currentBounds)) {
                boundsChanged =
                    fabs(currentBounds.origin.x - dragWindowBounds.origin.x) >= 1 ||
                    fabs(currentBounds.origin.y - dragWindowBounds.origin.y) >= 1 ||
                    fabs(currentBounds.size.width - dragWindowBounds.size.width) >= 1 ||
                    fabs(currentBounds.size.height - dragWindowBounds.size.height) >= 1;
            }
        }

        DragTickDecision dragDecision = windowDragTick(
            buttonDown, boundsChanged, dragWasButtonDown, dragClassified);

        if (dragDecision.captureNow) {
            dragWindowID = kCGNullWindowID;
            dragBoundsValid = false;
            CGWindowID capturedID = kCGNullWindowID;
            CGRect capturedBounds = CGRectZero;
            if (captureDragWindow(mousePoint, capturedID, capturedBounds)) {
                dragWindowID = capturedID;
                dragWindowBounds = capturedBounds;
                dragBoundsValid = true;
            }
        }

        if (dragDecision.cancelArm) {
            if (verbose) { NSLog(@"Window drag: cancelled pending focus"); }
            displayFocusArmed = false;
            delayTicks = 0;
            raiseTimes = 0;
        }

        if (dragDecision.releaseCapture) {
            dragWindowID = kCGNullWindowID;
            dragBoundsValid = false;
        }

        dragInProgress = dragDecision.dragging;

        // Keep the display baseline current during a drag. The gate below sits
        // after the ignoreTimes/appWasActivated early returns, so on a tick that
        // returns there it records nothing — and a release right after such a
        // tick would then look like a crossing. Recording here closes that.
        if (dragInProgress) {
            CGDirectDisplayID draggingDisplayID = 0;
            if (displayIDAt(gateMousePoint, draggingDisplayID)) {
                lastDisplayID = draggingDisplayID;
                lastDisplayIDValid = true;
            }
        }
    }
```

Do **not** move the gate block above the housekeeping instead. Its `if (!gateDecision.proceed) { return; }` would then preempt the `ignoreTimes` decrement at `AutoRaise.mm:1053-1055`, leaving `ignoreTimes` stuck until the next display crossing.

- [ ] **Step 5: Feed the gate and reuse the helper**

Replace the body of the gate block at `AutoRaise.mm:1068-1081` — the `findScreen`/`NSScreenNumber` pair becomes a `displayIDAt` call, and `false` from Task 2 becomes `dragInProgress`:

```objc
    {
        CGDirectDisplayID currentDisplayID = 0;
        bool hasScreen = displayIDAt(gateMousePoint, currentDisplayID);
        GateDecision gateDecision = displayFocusGate(
            currentDisplayID, hasScreen, (delayTicks != 0 || raiseTimes != 0), dragInProgress,
            lastDisplayID, lastDisplayIDValid, displayFocusArmed);
        if (gateDecision.armJustSet) {
            delayTicks = 0; // restart the delay for the new one-shot cycle
            if (verbose) { NSLog(@"Display crossing: armed one-shot focus"); }
        }
        if (!gateDecision.proceed) { return; } // silent within a display
    }
```

- [ ] **Step 6: Reset the drag state on re-enable**

In `toggleEnabled:` at `AutoRaise.mm:1418-1422`, extend the re-enable branch so a hold in progress when AutoRaise was switched off cannot leak into the next session. No CoreFoundation objects are held, so this is plain assignment:

```objc
    if (autoRaiseEnabled) {
        // Re-seed display tracking so simply re-enabling doesn't arm a focus.
        lastDisplayIDValid = false;
        displayFocusArmed = false;
        // Drop any hold that was in progress while disabled.
        dragWasButtonDown = false;
        dragClassified = false;
        dragWindowID = kCGNullWindowID;
        dragBoundsValid = false;
    }
```

- [ ] **Step 7: Build and run the unit tests**

Run: `make test && make AutoRaise`

Expected: both test binaries print `ALL PASS`; `AutoRaise` compiles with no warnings. `-Wall` is on (`Makefile:2`); an unused-variable or sign-compare warning here means a step above was mistyped.

- [ ] **Step 8: Document the behavior in the README**

In `README.md`, in the "Behavior in detail" list, insert a bullet after the "Empty desktop after a crossing" bullet (`README.md:27-28`):

```markdown
- **Dragging or resizing a window onto another display:** the crossing is
  ignored, so the window you just moved keeps focus when you let go and move the
  mouse away. Recognizing a window drag also cancels a focus that was already
  pending. Dragging something that is *not* a window — a text selection, a
  rubber-band on the desktop — still counts as a crossing and still arms a focus.
```

- [ ] **Step 9: Commit**

```bash
git add AutoRaise.mm README.md
git commit -m "feat(engine): don't arm a focus while dragging a window across displays"
```

---

### Task 4: Manual verification on hardware

**Files:**
- Modify: none unless a check fails.

**Interfaces:**
- Consumes: the built app from Task 3.
- Produces: nothing.

`onTick()` reads the live window server, so the ordering and side-effect decisions in Task 3 can only be confirmed by hand. Run every check. If one fails, fix it and re-run the whole list — the checks interact.

- [ ] **Step 1: Build, sign, install and launch**

```bash
./make-app.sh
cp -R AutoRaise.app /Applications/
open /Applications/AutoRaise.app
```

If macOS asks for Accessibility permission again, grant **AutoRaise.app** in System Settings → Privacy & Security → Accessibility, then toggle **Enable AutoRaise** off and on from the menu-bar icon.

- [ ] **Step 2: Run the engine from a terminal with logging**

Quit the menu-bar app first so two copies do not fight, then:

```bash
./AutoRaise -verbose 1
```

Leave this running for the checks below and watch the log. `Ctrl-C` when done.

- [ ] **Step 3: Core drag checks**

Run each on a two-display setup and confirm the stated result:

1. Drag a window from display A to display B, release, move the pointer off it → the dragged window keeps focus. The log shows `Window drag: cancelled pending focus` and **no** `Display crossing: armed one-shot focus` for that drag.
2. Walk the pointer from A to B without dragging, settle on a window → it is focused after the delay, exactly as before. Log shows `Display crossing: armed one-shot focus`.
3. Step onto empty desktop on B so a one-shot stays armed, then grab a window on B and drag it, release, move the pointer away → focus stays on the dragged window.
4. Cross onto B so a focus is counting down, and within the delay grab and drag a window → the counting-down focus is cancelled and nothing else is focused.
5. Drag a window to B and release it while the pointer is over a *different* window on B → focus stays on the dragged window.

- [ ] **Step 4: Resize checks**

6. Resize a window by its **top-left** corner across the display boundary → focus stays on it.
7. Resize by its **bottom-right** corner across the boundary → focus stays on it. This is the case that comparing only the origin would miss.

- [ ] **Step 5: Ordering and side-effect checks**

8. **cmd-tab mid-drag:** start dragging a window on A, press cmd-tab during the drag, continue onto B, release, move the pointer away → focus stays on the dragged window. This is the `ignoreTimes` gap that the baseline recording in Task 3 Step 4 exists for.
9. **No activation on press:** press and hold on a window of an app with weak accessibility support (a Chrome/Edge PWA, or an XQuartz window if one is available) → the log shows no `Activate` and no `Fallback` line attributable to the press. This is why capture avoids `get_mousewindow()`.
10. Disable AutoRaise from the menu mid-drag, release the button, re-enable, then cross displays → normal arming, no stale hold, no focus fired on the re-enable.

- [ ] **Step 6: Regression checks — unchanged behavior**

11. Move around within one display, over several windows → still silent, nothing focused.
12. Press on empty desktop, rubber-band across the display boundary, release, settle on a window → that window **is** focused. No capture was taken, so nothing is suppressed.
13. Drag a text selection from a window on A to display B and release → a one-shot **still** fires. Expected per the spec's "Accepted limitations", not a regression.
14. Cross A → B → A repeatedly without dragging → one focus per crossing, as before.

- [ ] **Step 7: Record the result**

If every check passed, commit nothing — the code is already committed. Report which checks passed to the user. If any failed, fix it, re-run `make test`, and re-run this whole task.

---

## Notes for the implementer

- **Why `topwindow()` and not `get_mousewindow()`** is the single most important constraint here. `get_mousewindow()` can activate an application, and drag capture runs *before* the `abort` check that normally stops AutoRaise doing anything while a button is held. Using it would let a press activate an app.
- **Why the baseline is recorded in two places.** The gate normally records `lastDisplayID` itself, but it sits after early returns that can skip a tick. Recording it again in the drag block — only while dragging — is three lines and closes the case where the pointer changes display during a skipped tick and the button comes up before the next gate tick.
- **Known limitation, do not try to fix it here.** Capture is poll-aligned, so the press is observed up to 20 ms late. A crossing survives only if press, display crossing and release all fall inside roughly one to two 20 ms ticks. A crossing seen before classification self-heals, because `cancelArm` clears it. Closing the rest would mean adding mouse-down events to the event tap, which the spec rules out.
- **Out of scope.** The Microsoft Teams live-video focus problem is recorded as a follow-up at the end of the spec and needs its own diagnostic run. Nothing in this plan changes it.
