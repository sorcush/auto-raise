#ifndef DISPLAY_FOCUS_GATE_H
#define DISPLAY_FOCUS_GATE_H

#include <cstdint>

// Decision returned by displayFocusGate for a single poll tick.
struct GateDecision {
    bool proceed;     // false => onTick should return early (stay silent this tick)
    bool armJustSet;  // true  => a display crossing was detected this tick
};

// Pure decision function for display-change focus gating. No AppKit.
//
//   currentDisplayID   : display id under the cursor (0 when hasScreen is false)
//   hasScreen          : whether a screen was found under the cursor this tick
//   cycleInProgress    : whether a focus cycle is already running (delayTicks || raiseTimes)
//   lastDisplayID      : [in/out] display id seen on the previous qualifying tick
//   lastDisplayIDValid : [in/out] false until the first qualifying tick seeds it
//   armed              : [in/out] whether a one-shot focus is pending
//
// Arming happens here; DISARMING is the caller's job (it clears `armed` when it
// actually fires a raise). `cycleInProgress` keeps an in-flight cycle alive after
// disarm so the stubborn-app multi-raise repeats can finish.
inline GateDecision displayFocusGate(
    uint32_t currentDisplayID,
    bool hasScreen,
    bool cycleInProgress,
    uint32_t & lastDisplayID,
    bool & lastDisplayIDValid,
    bool & armed)
{
    GateDecision decision = { false, false };
    if (hasScreen) {
        if (lastDisplayIDValid && currentDisplayID != lastDisplayID) {
            armed = true;
            decision.armJustSet = true;
        }
        lastDisplayID = currentDisplayID;
        lastDisplayIDValid = true;
    }
    decision.proceed = armed || cycleInProgress;
    return decision;
}

#endif // DISPLAY_FOCUS_GATE_H
