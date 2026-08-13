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
