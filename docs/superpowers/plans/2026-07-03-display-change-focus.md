# Display-Change Focus + Launcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change AutoRaise so focus/raise fires once per display crossing (after a configurable delay) instead of on every hover, and add a menu-bar launcher to control the delay, enable/disable the engine, and start it at login.

**Architecture:** Two pieces. (A) The **engine** — modified `AutoRaise.mm` — adds a pure display-gating function and hooks it into `onTick()` so the raise logic only runs while "armed" by a display crossing. (B) The **launcher** — a Swift menu-bar app built via an xcodegen-generated Xcode project — bundles the engine binary, writes the delay into the engine's config file, and runs the engine argless as a subprocess.

**Tech Stack:** Objective-C++ (engine, built with `make` for dev / an Xcode `tool` target for the bundle), Swift + AppKit + ServiceManagement (launcher), xcodegen + xcodebuild (build), a self-signed code-signing certificate.

> **Part A (Tasks 1–2) is independently shippable** — it produces a working modified CLI engine, testable on its own. Part B (Tasks 3–8) wraps it.

## Global Constraints

- **Behavior:** replace default focus-follows-mouse entirely; only a display crossing arms a focus. One focus per crossing; empty-desktop stays armed until a real window is settled on. (from spec)
- **Config preservation:** the launcher must NOT pass engine settings as CLI args. `AutoRaise.mm:808` reads the config file only when `argc == 1`. The launcher writes `delay=` into `~/.config/AutoRaise/config` and runs the engine **argless**. (from spec, verified)
- **Delay units:** engine `-delay` is in units of `pollMillis` (default 50 ms): `1` = fire on settle, each extra unit adds one `pollMillis`. Minimum passed is `1` (`0` disables raising). (from spec)
- **Deployment target:** macOS 13.0 (for `SMAppService`). (from spec)
- **TCC:** the embedded **engine** binary makes the Accessibility calls and must own the grant. Both binaries are signed with the **same stable self-signed identity** so the grant persists across rebuilds. No notarization/Developer-ID. (from spec)
- **Config file location:** launcher owns `~/.config/AutoRaise/config`; user has no `~/.AutoRaise` (verified absent). (from spec)
- **Engine bundle name:** the embedded engine is `Contents/MacOS/AutoRaiseEngine` (the launcher's own executable is `Contents/MacOS/AutoRaise`, so the engine gets a distinct name).

---

## Task 1: Pure display-gating function + unit tests

Isolates the arm/gate state machine into a pure, AppKit-free function so it can be unit-tested without the event loop.

**Files:**
- Create: `DisplayFocusGate.h`
- Test: `test_display_focus_gate.cpp`
- Modify: `Makefile` (add `test` target)
- Modify: `.gitignore` (ignore the test binary)

**Interfaces:**
- Produces: `struct GateDecision { bool proceed; bool armJustSet; };` and
  `inline GateDecision displayFocusGate(uint32_t currentDisplayID, bool hasScreen, bool cycleInProgress, uint32_t& lastDisplayID, bool& lastDisplayIDValid, bool& armed);`

- [ ] **Step 1: Write the failing test**

Create `test_display_focus_gate.cpp`:

```cpp
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `g++ -std=c++17 -Wall -o test_display_focus_gate test_display_focus_gate.cpp && ./test_display_focus_gate`
Expected: FAIL — compile error, `DisplayFocusGate.h: No such file or directory`.

- [ ] **Step 3: Write the implementation**

Create `DisplayFocusGate.h`:

```cpp
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `g++ -std=c++17 -Wall -o test_display_focus_gate test_display_focus_gate.cpp && ./test_display_focus_gate`
Expected: `ALL PASS` (exit 0).

- [ ] **Step 5: Add a `make test` target and gitignore the binary**

In `Makefile`, add to the `.PHONY` line: `test`, and add this target at the end:

```makefile
test: DisplayFocusGate.h test_display_focus_gate.cpp
	g++ -std=c++17 -Wall -o test_display_focus_gate test_display_focus_gate.cpp && ./test_display_focus_gate
```

In `.gitignore`, add a line:

```
test_display_focus_gate
```

- [ ] **Step 6: Verify the make target**

Run: `make test`
Expected: compiles and prints `ALL PASS`.

- [ ] **Step 7: Commit**

```bash
git add DisplayFocusGate.h test_display_focus_gate.cpp Makefile .gitignore
git commit -m "feat(engine): pure display-gating function with unit tests"
```

---

## Task 2: Integrate the gate into `onTick()`

Wires the gate into the engine, reorders housekeeping so no state goes stale, neutralizes stock space-change auto-raise, and disarms on fire.

**Files:**
- Modify: `AutoRaise.mm` (include, globals ~L158, `onTick` ~L985/L1045/L1220)

**Interfaces:**
- Consumes: `displayFocusGate(...)` and `GateDecision` from Task 1.

- [ ] **Step 1: Include the gate header**

In `AutoRaise.mm`, immediately after the existing top-of-file `#import`/`#include` lines (before the first `static NSString * const` definition), add:

```cpp
#include "DisplayFocusGate.h"
```

- [ ] **Step 2: Add the engine-side gate state globals**

In `AutoRaise.mm`, right after `static int disableKey = 0;` (line 161), add:

```cpp
static CGDirectDisplayID lastDisplayID = 0;
static bool lastDisplayIDValid = false;
static bool displayFocusArmed = false;
```

- [ ] **Step 3: Capture the raw mouse point for display detection**

In `onTick()`, find `oldPoint = mousePoint;` (line 985). Immediately after it, add:

```cpp
    CGPoint gateMousePoint = mousePoint; // raw location, before macOS-12 corrections
```

- [ ] **Step 4: Replace the housekeeping block with the reordered + gated version**

In `onTick()`, replace this exact block (lines 1045–1066):

```cpp
    if (ignoreTimes) {
        ignoreTimes--;
        return;
    } else if (appWasActivated) {
        appWasActivated = false;
        return;
    } else if (spaceHasChanged) {
        // spaceHasChanged has priority
        // over waiting for the delay
        if (mouseMoved) { return; }
        else if (!ignoreSpaceChanged) {
            raiseTimes = 3;
            delayTicks = 0;
        }
        spaceHasChanged = false;
    } else if (requireMouseStop && !mouseStopped && mouseMoved) {
        delayTicks = 0;
        // propagate the mouseMoved event
        // to restart the delay if needed
        propagateMouseMoved = true;
        return;
    }
```

with:

```cpp
    if (ignoreTimes) {
        ignoreTimes--;
        return;
    } else if (appWasActivated) {
        appWasActivated = false;
        return;
    }

    // Display-change focus mode: a Space change alone must never focus.
    // Clear the flag without arming a raise (replaces stock space auto-raise).
    if (spaceHasChanged) { spaceHasChanged = false; }

    // Arm a one-shot focus when the cursor crosses onto a different display.
    // Must run before the requireMouseStop early-return below, because a crossing
    // always happens mid-motion.
    {
        NSScreen * gateScreen = findScreen(gateMousePoint);
        bool hasScreen = gateScreen != nil;
        CGDirectDisplayID currentDisplayID = hasScreen ?
            (CGDirectDisplayID)[gateScreen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] : 0;
        GateDecision gateDecision = displayFocusGate(
            currentDisplayID, hasScreen, (delayTicks != 0 || raiseTimes != 0),
            lastDisplayID, lastDisplayIDValid, displayFocusArmed);
        if (gateDecision.armJustSet) {
            delayTicks = 0; // restart the delay for the new one-shot cycle
            if (verbose) { NSLog(@"Display crossing: armed one-shot focus"); }
        }
        if (!gateDecision.proceed) { return; } // silent within a display
    }

    // Wait for the mouse to stop before starting/continuing the delay.
    if (requireMouseStop && !mouseStopped && mouseMoved) {
        delayTicks = 0;
        // propagate the mouseMoved event to restart the delay if needed
        propagateMouseMoved = true;
        return;
    }
```

- [ ] **Step 5: Disarm on fire**

In `onTick()`, find the fire block that begins (line 1219):

```cpp
                    if (raiseTimes || delayTicks == 1) {
                        delayTicks = 0; // disable delay
```

Insert, immediately after `delayTicks = 0; // disable delay`:

```cpp
                        displayFocusArmed = false; // one focus per crossing
```

- [ ] **Step 6: Build the engine**

Run: `make clean && make`
Expected: compiles to `./AutoRaise` and `AutoRaise.app` with no errors (warnings about deprecated APIs from stock code are acceptable).

- [ ] **Step 7: Re-run the unit test (guards the pure fn still compiles clean)**

Run: `make test`
Expected: `ALL PASS`.

- [ ] **Step 8: Manual multi-monitor verification** (requires 2+ displays)

Run: `./AutoRaise -verbose true`
Verify by watching the log and window behavior:
1. Move the mouse **within one display** over several windows → **no** focus/raise, no "armed" log.
2. Move the cursor **onto another display** → log shows `Display crossing: armed one-shot focus`; settle on a window → after the delay it is raised/focused **once**.
3. Keep moving over other windows on that same display → **no** further raises.
4. Cross onto empty desktop of a third display, then move to a window and settle → it raises once (armed persisted over the empty desktop).
5. Cross back to the first display → re-arms and raises once.
6. Switch Spaces (Mission Control) **without** crossing displays → **no** raise. Then cross displays → raises after the normal delay (not instantly).

- [ ] **Step 9: Single-display sanity**

On a single-display machine (or with `-verbose true`): confirm the engine runs without crashing and performs no spurious focus after startup.

- [ ] **Step 10: Commit**

```bash
git add AutoRaise.mm
git commit -m "feat(engine): fire focus once per display crossing"
```

---

## Task 3: Launcher project scaffold (xcodegen, two targets, signing)

Stands up the buildable app shell: a self-signed identity, an xcodegen project with an engine `tool` target and a launcher `application` target, and a minimal menu-bar `AppDelegate`.

**Files:**
- Create: `project.yml`
- Create: `Launcher/main.swift` (explicit entry point)
- Create: `Launcher/AppDelegate.swift` (minimal)
- Create: `Launcher/Info.plist` (generated by xcodegen; committed)
- Modify: `.gitignore`

**Interfaces:**
- Produces: an `AutoRaise.app` bundle at `build/Build/Products/Release/AutoRaise.app` containing `Contents/MacOS/AutoRaise` (launcher) and `Contents/MacOS/AutoRaiseEngine` (engine).

- [ ] **Step 1: Install tooling (one-time, user machine)**

Run: `xcodegen --version || brew install xcodegen`
Expected: prints a version (installs if missing). Requires Xcode Command Line Tools (`xcode-select -p` should print a path).

- [ ] **Step 2: Create a stable self-signed code-signing certificate (one-time)**

This must be done once in Keychain Access so the Accessibility grant persists across rebuilds:
1. Open **Keychain Access** → menu **Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…**
2. Name: `AutoRaise Self-Signed`; Identity Type: **Self-Signed Root**; Certificate Type: **Code Signing**. Create.

Verify from the terminal:
Run: `security find-identity -v -p codesigning | grep "AutoRaise Self-Signed"`
Expected: one matching identity line. (If you prefer a different name, use it consistently in `project.yml`.)

- [ ] **Step 3: Write `project.yml`**

Create `project.yml`:

```yaml
name: AutoRaise
options:
  bundleIdPrefix: local.autoraise
  deploymentTarget:
    macOS: "13.0"
settings:
  base:
    CODE_SIGN_STYLE: Manual
    CODE_SIGN_IDENTITY: "AutoRaise Self-Signed"
    DEVELOPMENT_TEAM: ""
    ENABLE_HARDENED_RUNTIME: "NO"
    MARKETING_VERSION: "1.0"
    CURRENT_PROJECT_VERSION: "1"
targets:
  AutoRaiseEngine:
    type: tool
    platform: macOS
    sources:
      - path: AutoRaise.mm
      - path: DisplayFocusGate.h
    settings:
      base:
        PRODUCT_NAME: AutoRaiseEngine
        CLANG_ENABLE_OBJC_ARC: "YES"
        OTHER_CPLUSPLUSFLAGS: "-O2 -Wall"
    dependencies:
      - sdk: AppKit.framework
  AutoRaiseLauncher:
    type: application
    platform: macOS
    sources:
      - path: Launcher
        excludes:
          - "Tests/**"
    settings:
      base:
        PRODUCT_NAME: AutoRaise
        PRODUCT_BUNDLE_IDENTIFIER: local.autoraise.displayfocus
    info:
      path: Launcher/Info.plist
      properties:
        LSUIElement: true
        CFBundleName: AutoRaise
        CFBundleDisplayName: AutoRaise
    dependencies:
      - target: AutoRaiseEngine
    postBuildScripts:
      - name: Embed AutoRaise engine
        script: |
          set -e
          SRC="${BUILT_PRODUCTS_DIR}/AutoRaiseEngine"
          DST="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}/AutoRaiseEngine"
          cp "$SRC" "$DST"
          codesign --force --sign "AutoRaise Self-Signed" "$DST"
```

- [ ] **Step 4: Write the entry point and the minimal `AppDelegate.swift`**

Create `Launcher/main.swift` (explicit bootstrap — reliable for a programmatic AppKit menu-bar app; avoids the deprecated `@NSApplicationMain`/`@main` app-delegate path):

```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
app.run()
```

Create `Launcher/AppDelegate.swift`:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cursorarrow.rays",
                                   accessibilityDescription: "AutoRaise")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit AutoRaise",
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
```

- [ ] **Step 5: Generate the project and gitignore build output**

Run: `xcodegen generate`
Expected: `Created project at AutoRaise.xcodeproj`.

In `.gitignore`, add:

```
build/
*.xcodeproj/xcuserdata/
```

- [ ] **Step 6: Build the app**

Run: `xcodebuild -project AutoRaise.xcodeproj -scheme AutoRaiseLauncher -configuration Release -derivedDataPath build build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Verify the bundle contains both binaries**

Run: `ls build/Build/Products/Release/AutoRaise.app/Contents/MacOS`
Expected: two files — `AutoRaise` and `AutoRaiseEngine`.

- [ ] **Step 8: Verify it launches as a menu-bar app**

Run: `open build/Build/Products/Release/AutoRaise.app`
Expected: a menu-bar icon appears (no Dock icon), and its menu shows **Quit AutoRaise**. Use Quit to exit.

- [ ] **Step 9: Commit**

```bash
git add project.yml Launcher/main.swift Launcher/AppDelegate.swift Launcher/Info.plist AutoRaise.xcodeproj .gitignore
git commit -m "feat(launcher): xcodegen scaffold with engine + launcher targets"
```

---

## Task 4: Pure delay + config helpers with tests

The two highest-risk pure pieces: ms→units conversion and the config-file `delay=` read-modify-write that must preserve the user's other settings.

**Files:**
- Create: `Launcher/DelayConversion.swift`
- Create: `Launcher/ConfigFile.swift`
- Create: `Launcher/Tests/main.swift`

**Interfaces:**
- Produces: `enum DelayConversion` with `static let pollMillis: Int`, `static let maxDelayMs: Int`, `static func clampMs(_:) -> Int`, `static func delayUnits(fromMs:) -> Int`.
- Produces: `enum ConfigFile` with `static var url: URL`, `static func settingDelay(_ units: Int, in contents: String) -> String`, `static func writeDelay(_ units: Int) throws`.

- [ ] **Step 1: Write the failing test**

Create `Launcher/Tests/main.swift`:

```swift
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if !cond { print("FAIL: \(msg)"); failures += 1 } else { print("ok:   \(msg)") }
}

// DelayConversion
check(DelayConversion.delayUnits(fromMs: 0) == 1, "0ms -> 1 unit")
check(DelayConversion.delayUnits(fromMs: 50) == 2, "50ms -> 2 units")
check(DelayConversion.delayUnits(fromMs: 200) == 5, "200ms -> 5 units")
check(DelayConversion.delayUnits(fromMs: 5000) == 41, "5000ms clamps to 2000 -> 41 units")
check(DelayConversion.clampMs(70) == 50, "70ms snaps to 50")
check(DelayConversion.clampMs(-10) == 0, "negative clamps to 0")

// ConfigFile.settingDelay preserves other lines
let input = "#AutoRaise config file\nignoreApps=\"WebStorm\"\ndelay=1\npollMillis=50"
let out = ConfigFile.settingDelay(5, in: input)
check(out.contains("ignoreApps=\"WebStorm\""), "preserves ignoreApps")
check(out.contains("pollMillis=50"), "preserves pollMillis")
check(out.contains("delay=5") && !out.contains("delay=1"), "delay replaced 1 -> 5")

// appends when delay absent
let out2 = ConfigFile.settingDelay(3, in: "ignoreApps=\"X\"")
check(out2.contains("ignoreApps=\"X\"") && out2.contains("delay=3"), "appends delay, keeps line")

// empty input gets a header + delay
let out3 = ConfigFile.settingDelay(2, in: "")
check(out3.contains("#AutoRaise config file") && out3.contains("delay=2"), "empty -> header + delay")

if failures > 0 { print("\(failures) FAILURES"); exit(1) }
print("ALL PASS")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swiftc Launcher/DelayConversion.swift Launcher/ConfigFile.swift Launcher/Tests/main.swift -o /tmp/puretests 2>&1 | head`
Expected: FAIL — errors like `cannot find 'DelayConversion' in scope`.

- [ ] **Step 3: Write `DelayConversion.swift`**

Create `Launcher/DelayConversion.swift`:

```swift
import Foundation

/// Pure conversions between a user-facing delay (ms) and the engine's -delay units.
enum DelayConversion {
    static let pollMillis = 50
    static let maxDelayMs = 2000

    /// Clamp to [0, maxDelayMs] and snap to a pollMillis multiple.
    static func clampMs(_ ms: Int) -> Int {
        let clamped = min(max(ms, 0), maxDelayMs)
        return (clamped / pollMillis) * pollMillis
    }

    /// Engine units: 1 = fire on settle; each extra unit adds one pollMillis.
    static func delayUnits(fromMs ms: Int) -> Int {
        let clamped = clampMs(ms)
        return max(1, Int((Double(clamped) / Double(pollMillis)).rounded()) + 1)
    }
}
```

- [ ] **Step 4: Write `ConfigFile.swift`**

Create `Launcher/ConfigFile.swift`:

```swift
import Foundation

/// Owns ~/.config/AutoRaise/config. Only ever rewrites the `delay=` line,
/// leaving every other line (ignoreApps, ignoreTitles, etc.) untouched.
enum ConfigFile {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/AutoRaise/config")
    }

    /// Pure: return `contents` with `delay=` set to `units`, preserving other lines.
    static func settingDelay(_ units: Int, in contents: String) -> String {
        var lines = contents.isEmpty ? [] : contents.components(separatedBy: "\n")
        var replaced = false
        for i in lines.indices {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            let compact = trimmed.replacingOccurrences(of: " ", with: "")
            if compact.hasPrefix("delay=") {
                lines[i] = "delay=\(units)"
                replaced = true
                break
            }
        }
        if !replaced {
            if lines.isEmpty || (lines.count == 1 && lines[0].isEmpty) {
                lines = ["#AutoRaise config file", "delay=\(units)"]
            } else {
                lines.append("delay=\(units)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Read current file (or empty), set delay, write back (creating dirs).
    static func writeDelay(_ units: Int) throws {
        let fm = FileManager.default
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = settingDelay(units, in: existing)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swiftc Launcher/DelayConversion.swift Launcher/ConfigFile.swift Launcher/Tests/main.swift -o /tmp/puretests && /tmp/puretests`
Expected: `ALL PASS`.

- [ ] **Step 6: Regenerate + build (confirm the new files compile into the app target)**

Run: `xcodegen generate && xcodebuild -project AutoRaise.xcodeproj -scheme AutoRaiseLauncher -configuration Release -derivedDataPath build build`
Expected: `** BUILD SUCCEEDED **` (Tests/ is excluded from the app target, so no top-level-code conflict).

- [ ] **Step 7: Commit**

```bash
git add Launcher/DelayConversion.swift Launcher/ConfigFile.swift Launcher/Tests/main.swift
git commit -m "feat(launcher): pure delay + config-file helpers with tests"
```

---

## Task 5: Engine subprocess controller

Manages the engine process: writes the config, launches argless, stops with a bounded off-main-thread wait, and reconciles state on unexpected exit.

**Files:**
- Create: `Launcher/EngineController.swift`

**Interfaces:**
- Consumes: `ConfigFile.writeDelay`, `DelayConversion.delayUnits` (Task 4).
- Produces: `final class EngineController` with `var isRunning: Bool`, `private(set) var lastError: String?`, `func start(delayMs: Int)`, `func stop()`; and `Notification.Name.engineStateChanged`.

- [ ] **Step 1: Write `EngineController.swift`**

Create `Launcher/EngineController.swift`:

```swift
import Foundation
import AppKit

/// Runs the embedded AutoRaiseEngine binary as a subprocess.
final class EngineController {
    private var process: Process?
    private(set) var lastError: String?

    var isRunning: Bool { process?.isRunning ?? false }

    private var engineURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AutoRaiseEngine")
    }

    /// Write the delay into the config file, then launch the engine ARGLESS so it
    /// reads ~/.config/AutoRaise/config in full (preserving the user's settings).
    func start(delayMs: Int) {
        stop()
        lastError = nil
        do {
            try ConfigFile.writeDelay(DelayConversion.delayUnits(fromMs: delayMs))
        } catch {
            lastError = "Could not write config: \(error.localizedDescription)"
            notifyChanged()
            return
        }
        guard FileManager.default.isExecutableFile(atPath: engineURL.path) else {
            lastError = "Engine binary missing or not executable"
            notifyChanged()
            return
        }
        let p = Process()
        p.executableURL = engineURL
        p.arguments = [] // argless => full config file is read
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                if proc.terminationStatus != 0 {
                    self.lastError = "Engine exited unexpectedly (status \(proc.terminationStatus))"
                }
                self.notifyChanged()
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            lastError = "Could not start engine: \(error.localizedDescription)"
            process = nil
        }
        notifyChanged()
    }

    func stop() {
        guard let p = process, p.isRunning else { process = nil; return }
        p.terminationHandler = nil
        p.terminate()
        // Bounded wait OFF the main thread; escalate to SIGKILL if it lingers.
        let pid = p.processIdentifier
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(2.0)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { kill(pid, SIGKILL) }
        }
        process = nil
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .engineStateChanged, object: nil)
    }
}

extension Notification.Name {
    static let engineStateChanged = Notification.Name("engineStateChanged")
}
```

- [ ] **Step 2: Regenerate + build**

Run: `xcodegen generate && xcodebuild -project AutoRaise.xcodeproj -scheme AutoRaiseLauncher -configuration Release -derivedDataPath build build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Launcher/EngineController.swift
git commit -m "feat(launcher): engine subprocess controller"
```

---

## Task 6: Start-at-login helper

Wraps `SMAppService.mainApp` for the login toggle.

**Files:**
- Create: `Launcher/LoginItem.swift`

**Interfaces:**
- Produces: `enum LoginItem` with `static var isEnabled: Bool` and `@discardableResult static func setEnabled(_ on: Bool) -> Bool`.

- [ ] **Step 1: Write `LoginItem.swift`**

Create `Launcher/LoginItem.swift`:

```swift
import Foundation
import ServiceManagement

/// Start-at-login via ServiceManagement (macOS 13+).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns true on success; reflects ACTUAL registration state, not intent.
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            NSLog("AutoRaise: login item toggle failed: \(error)")
            return false
        }
    }
}
```

- [ ] **Step 2: Regenerate + build**

Run: `xcodegen generate && xcodebuild -project AutoRaise.xcodeproj -scheme AutoRaiseLauncher -configuration Release -derivedDataPath build build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Launcher/LoginItem.swift
git commit -m "feat(launcher): start-at-login via SMAppService"
```

---

## Task 7: Preferences window + full menu wiring

Adds the delay Preferences window and rebuilds the menu with Enable/Disable, Delay…, Start at Login, an error line, and Quit — all wired to the controllers and persisted in `UserDefaults`.

**Files:**
- Create: `Launcher/PreferencesWindowController.swift`
- Modify: `Launcher/AppDelegate.swift` (replace entirely)

**Interfaces:**
- Consumes: `EngineController` (T5), `LoginItem` (T6), `DelayConversion` (T4).
- Produces: `final class PreferencesWindowController` with `init(initialMs: Int, onChange: @escaping (Int) -> Void)`.

- [ ] **Step 1: Write `PreferencesWindowController.swift`**

Create `Launcher/PreferencesWindowController.swift`:

```swift
import AppKit

/// A tiny window with a text field + stepper for the focus delay (ms).
final class PreferencesWindowController: NSWindowController {
    private let onChange: (Int) -> Void
    private let field = NSTextField()
    private let stepper = NSStepper()

    init(initialMs: Int, onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AutoRaise Preferences"
        super.init(window: window)
        window.center()
        buildUI(initialMs: DelayConversion.clampMs(initialMs))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI(initialMs: Int) {
        guard let content = window?.contentView else { return }

        let label = NSTextField(labelWithString:
            "Focus delay after crossing a display (ms):")
        label.frame = NSRect(x: 20, y: 72, width: 320, height: 18)
        content.addSubview(label)

        field.frame = NSRect(x: 20, y: 34, width: 90, height: 24)
        field.integerValue = initialMs
        field.target = self
        field.action = #selector(fieldChanged)
        content.addSubview(field)

        stepper.frame = NSRect(x: 114, y: 32, width: 20, height: 28)
        stepper.minValue = 0
        stepper.maxValue = Double(DelayConversion.maxDelayMs)
        stepper.increment = Double(DelayConversion.pollMillis)
        stepper.integerValue = initialMs
        stepper.target = self
        stepper.action = #selector(stepperChanged)
        content.addSubview(stepper)

        let hint = NSTextField(labelWithString:
            "0–\(DelayConversion.maxDelayMs) ms, in \(DelayConversion.pollMillis) ms steps.")
        hint.frame = NSRect(x: 20, y: 8, width: 320, height: 16)
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)
    }

    @objc private func fieldChanged() { apply(field.integerValue) }
    @objc private func stepperChanged() { apply(stepper.integerValue) }

    private func apply(_ raw: Int) {
        let ms = DelayConversion.clampMs(raw)
        field.integerValue = ms   // revert invalid/out-of-range to a valid value
        stepper.integerValue = ms
        onChange(ms)
    }
}
```

- [ ] **Step 2: Replace `AppDelegate.swift` with the full version**

Replace the entire contents of `Launcher/AppDelegate.swift` with (note: `main.swift` remains the entry point; do **not** add `@main` here):

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let engine = EngineController()
    private var prefsWindow: PreferencesWindowController?
    private let defaults = UserDefaults.standard

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    private var delayMs: Int {
        get { defaults.object(forKey: "delayMs") as? Int ?? 200 }
        set { defaults.set(DelayConversion.clampMs(newValue), forKey: "delayMs") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuildMenu),
            name: .engineStateChanged, object: nil)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cursorarrow.rays",
                                   accessibilityDescription: "AutoRaise")
            button.image?.isTemplate = true
        }
        rebuildMenu()
        if enabled { engine.start(delayMs: delayMs) }
    }

    @objc private func rebuildMenu() {
        let menu = NSMenu()

        let toggle = NSMenuItem(title: "Enable AutoRaise",
            action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = (enabled && engine.isRunning) ? .on : .off
        toggle.target = self
        menu.addItem(toggle)

        if let err = engine.lastError {
            let item = NSMenuItem(title: "⚠︎ \(err)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let delayItem = NSMenuItem(title: "Delay: \(delayMs) ms…",
            action: #selector(openPreferences), keyEquivalent: "")
        delayItem.target = self
        menu.addItem(delayItem)

        let login = NSMenuItem(title: "Start at Login",
            action: #selector(toggleLogin), keyEquivalent: "")
        login.state = LoginItem.isEnabled ? .on : .off
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit AutoRaise",
            action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        if enabled { engine.start(delayMs: delayMs) } else { engine.stop() }
        rebuildMenu()
    }

    @objc private func openPreferences() {
        if prefsWindow == nil {
            prefsWindow = PreferencesWindowController(initialMs: delayMs) { [weak self] newMs in
                guard let self else { return }
                self.delayMs = newMs
                if self.enabled { self.engine.start(delayMs: self.delayMs) }
                self.rebuildMenu()
            }
        }
        prefsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        rebuildMenu()
    }

    @objc private func quit() {
        engine.stop()
        NSApp.terminate(nil)
    }
}
```

- [ ] **Step 3: Regenerate + build**

Run: `xcodegen generate && xcodebuild -project AutoRaise.xcodeproj -scheme AutoRaiseLauncher -configuration Release -derivedDataPath build build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Manual verification**

Run: `open build/Build/Products/Release/AutoRaise.app`
1. Menu shows **Enable AutoRaise** (checked), **Delay: 200 ms…**, **Start at Login**, **Quit**.
2. Click **Delay…** → window opens; change value with the stepper → menu title updates to the new ms; try typing `9999` → it snaps back to `2000`.
3. Uncheck **Enable AutoRaise** → checkmark clears (engine stopped). Re-check → engine restarts.
4. Confirm `~/.config/AutoRaise/config` now exists and contains a `delay=` line:
   Run: `cat ~/.config/AutoRaise/config`
   Expected: a `#AutoRaise config file` header and `delay=<units>`.
5. Toggle **Start at Login** on → check it persists:
   Run: `sfltool dumpbtm 2>/dev/null | grep -i autoraise || echo "check System Settings ▸ General ▸ Login Items"`

- [ ] **Step 5: Commit**

```bash
git add Launcher/PreferencesWindowController.swift Launcher/AppDelegate.swift
git commit -m "feat(launcher): preferences window and full menu wiring"
```

---

## Task 8: Accessibility first-run UX + end-to-end verification

Adds the permission affordance (the engine, as a child process, needs its own Accessibility grant) and runs the full regression checklist from the spec.

**Files:**
- Modify: `Launcher/AppDelegate.swift` (add an "Open Accessibility Settings…" item + first-run alert)

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Add the Accessibility menu item and first-run alert**

In `Launcher/AppDelegate.swift`, in `rebuildMenu()`, add this item immediately **before** the final separator (before the `Quit` block):

```swift
        let axItem = NSMenuItem(title: "Open Accessibility Settings…",
            action: #selector(openAccessibility), keyEquivalent: "")
        axItem.target = self
        menu.addItem(axItem)
```

Add these two methods to the class:

```swift
    @objc private func openAccessibility() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func showFirstRunAccessibilityNoticeIfNeeded() {
        guard !defaults.bool(forKey: "didShowAXNotice") else { return }
        defaults.set(true, forKey: "didShowAXNotice")
        let alert = NSAlert()
        alert.messageText = "Grant Accessibility to AutoRaise"
        alert.informativeText = """
            AutoRaise needs Accessibility permission to focus windows. In the \
            settings window that opens, enable the entry named “AutoRaiseEngine”, \
            then toggle AutoRaise off and on from the menu bar.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { openAccessibility() }
    }
```

In `applicationDidFinishLaunching`, add as the last line:

```swift
        showFirstRunAccessibilityNoticeIfNeeded()
```

- [ ] **Step 2: Regenerate + build**

Run: `xcodegen generate && xcodebuild -project AutoRaise.xcodeproj -scheme AutoRaiseLauncher -configuration Release -derivedDataPath build build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Install to /Applications and grant Accessibility**

Run: `rm -rf /Applications/AutoRaise.app && cp -R build/Build/Products/Release/AutoRaise.app /Applications/ && open /Applications/AutoRaise.app`
Then: on first launch, the alert appears → **Open Settings** → enable **AutoRaiseEngine** in Accessibility. Toggle **Enable AutoRaise** off/on from the menu.

- [ ] **Step 4: Full end-to-end verification (from spec)**

Confirm each:
1. **Display-crossing focus:** no focus within a display; exactly one focus after crossing + settling; empty-desktop-then-window still fires once; crossing back re-arms. (Repeat Task 2 Step 8 against the launcher-run engine.)
2. **Delay respected:** change Delay in Preferences → the pause before focus changes accordingly.
3. **Config preservation:** add `ignoreApps="Finder"` to `~/.config/AutoRaise/config`, toggle AutoRaise off/on, and confirm the line survives (`cat ~/.config/AutoRaise/config`) and that hovering/crossing onto a Finder window does not focus it.
4. **Space change while disarmed:** switch Spaces without crossing → no focus; then cross → focus after the normal delay.
5. **Accessibility denied path:** with the engine not yet granted, confirm no crash and the menu still works; the affordance opens Settings.
6. **Child crash reconciliation:** `pkill AutoRaiseEngine` while enabled → the menu’s Enable item unchecks / an error line appears; no runaway restart loop.
7. **Start at Login:** enable it, reboot, confirm the menu-bar app returns and the engine runs.
8. **Bounded stop:** toggling disable returns immediately (no UI hang).

- [ ] **Step 5: Commit**

```bash
git add Launcher/AppDelegate.swift
git commit -m "feat(launcher): accessibility first-run UX and settings shortcut"
```

---

## Notes for the implementer

- The engine and the embedded copy must be signed with the **same** `AutoRaise Self-Signed` identity (the `project.yml` base setting + the post-build `codesign` handle this). If you rename the certificate, update `project.yml` in two places.
- `AutoRaise.icns` exists in the repo; you may optionally wire it as the app icon by adding `CFBundleIconFile` to the launcher `info.properties` and copying the icns into resources — not required for functionality.
- If `xcodebuild` fails to find the signing identity in a headless/CI context, run it from a logged-in GUI session (the self-signed key lives in the login keychain).
- **Provenance/licensing:** the engine (`AutoRaise.mm`) is sbmpost's code (see `LICENSE.md` — keep it). The launcher Swift files here are **original**, written fresh rather than vendored — the menu-bar + subprocess + login-item pattern is inspired by `lhaeger/AutoRaise` but shares no copied source, so no additional license vendoring is needed. Add a credit line to the README when finishing.
