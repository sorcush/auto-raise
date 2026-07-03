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
    GateDecision d = displayFocusGate(1, true, false, last, valid, armed);
    check(!d.armJustSet && !d.proceed, "first tick: seed, no arm, no proceed");
    check(valid && last == 1 && !armed, "first tick: state seeded to display 1");

    // 2) Same display, no cycle: stay silent.
    d = displayFocusGate(1, true, false, last, valid, armed);
    check(!d.armJustSet && !d.proceed && !armed, "same display: silent");

    // 3) Crossing 1 -> 2: arm + proceed, remember display 2.
    d = displayFocusGate(2, true, false, last, valid, armed);
    check(d.armJustSet && d.proceed && armed && last == 2, "crossing: armed and proceed");

    // 4) Armed, same display: still proceeds, no new arm.
    d = displayFocusGate(2, true, false, last, valid, armed);
    check(!d.armJustSet && d.proceed && armed, "armed persists within display");

    // 5) No screen under cursor: no arm, last unchanged, proceed follows armed.
    d = displayFocusGate(0, false, false, last, valid, armed);
    check(!d.armJustSet && last == 2 && d.proceed, "no screen: last unchanged, proceed=armed");

    // 6) Disarm (simulate fire) then a cycle in progress still proceeds.
    armed = false;
    d = displayFocusGate(2, true, true, last, valid, armed);
    check(!d.armJustSet && d.proceed && !armed, "disarmed but cycle in progress proceeds");

    // 7) Disarmed, no cycle, same display: silent again.
    d = displayFocusGate(2, true, false, last, valid, armed);
    check(!d.proceed, "disarmed + no cycle: silent");

    if (failures) { printf("%d FAILURES\n", failures); return 1; }
    printf("ALL PASS\n");
    return 0;
}
