#include "DisplayFocusGate.h"
#include <cstdio>

static int failures = 0;
static void check(bool cond, const char * msg) {
    if (!cond) { printf("FAIL: %s\n", msg); failures++; }
    else       { printf("ok:   %s\n", msg); }
}

int main() {
    // Fresh state
    uint32_t last = 0; bool valid = false; bool armed = false;

    // 1) First tick seeds, does not arm, does not proceed (no cycle).
    GateDecision d = displayFocusGate(1, true, false, false, last, valid, armed);
    check(!d.armJustSet && !d.proceed, "first tick: seed, no arm, no proceed");
    check(valid && last == 1 && !armed, "first tick: state seeded to display 1");

    // 2) Same display, no cycle: stay silent.
    d = displayFocusGate(1, true, false, false, last, valid, armed);
    check(!d.armJustSet && !d.proceed && !armed, "same display: silent");

    // 3) Crossing 1 -> 2: arm + proceed, remember display 2.
    d = displayFocusGate(2, true, false, false, last, valid, armed);
    check(d.armJustSet && d.proceed && armed && last == 2, "crossing: armed and proceed");

    // 4) Armed, same display: still proceeds, no new arm.
    d = displayFocusGate(2, true, false, false, last, valid, armed);
    check(!d.armJustSet && d.proceed && armed, "armed persists within display");

    // 5) No screen under cursor: no arm, last unchanged, proceed follows armed.
    d = displayFocusGate(0, false, false, false, last, valid, armed);
    check(!d.armJustSet && last == 2 && d.proceed, "no screen: last unchanged, proceed=armed");

    // 6) Disarm (simulate fire) then a cycle in progress still proceeds.
    armed = false;
    d = displayFocusGate(2, true, true, false, last, valid, armed);
    check(!d.armJustSet && d.proceed && !armed, "disarmed but cycle in progress proceeds");

    // 7) Disarmed, no cycle, same display: silent again.
    d = displayFocusGate(2, true, false, false, last, valid, armed);
    check(!d.proceed, "disarmed + no cycle: silent");

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

    if (failures) { printf("%d FAILURES\n", failures); return 1; }
    printf("ALL PASS\n");
    return 0;
}
