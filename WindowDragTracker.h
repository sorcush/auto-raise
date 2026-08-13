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
