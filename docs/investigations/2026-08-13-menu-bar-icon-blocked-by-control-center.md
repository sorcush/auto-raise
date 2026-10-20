# AutoRaise — menu bar icon never appears: Control Center adopted the app into Cursor's allow-list entry

**Date:** 2026-08-13
**Status:** **Root cause found and confirmed.** Icon restored by allowing Cursor in
the menu bar. A proper cleanup is still pending — see
[Pending cleanup](#pending-cleanup-so-cursor-can-go-back-to-off).

---

## Resolution in one paragraph

macOS 26 keeps a per-app menu bar allow-list. AutoRaise's own entry says *allowed*,
but Cursor's entry — which is set to *not allowed* — **also claims AutoRaise's menu
bar item**. Control Center honours the claiming entry, so on every launch it accepted
the status item, then immediately moved the app to its internal "blocked hosts" list
and hid it. Nothing about AutoRaise's code, build, signature, install path or
permissions was involved. Switching Cursor on in
**System Settings → Menu Bar → Allow in the Menu Bar** made the icon appear
immediately.

The app was adopted into Cursor's entry because it had been **launched as a child of
Cursor** (running the binary from Cursor's integrated terminal). Control Center
attributes a status item to the responsible parent application, and the mapping is
permanent once written — the icon stayed blocked afterwards even when launched
normally from `/Applications`.

This is the same defect reported against another app in
[CodexBar #1440](https://github.com/steipete/CodexBar/issues/1440) ("orphaned
`trackedApplications` mapping"), and part of a wider class of Tahoe menu bar
regressions: [BetterDisplay #5314](https://github.com/waydabber/BetterDisplay/issues/5314),
[Stats #3120](https://github.com/exelban/stats/issues/3120),
[Maccy #1224](https://github.com/p0deje/Maccy/issues/1224),
[CodexBar #1169](https://github.com/steipete/CodexBar/issues/1169),
[Daring Fireball on the Tahoe menu bar](https://daringfireball.net/2026/03/what_to_do_about_those_menu_item_icons_in_macos_26_tahoe).

---

## Correct deployment procedure

**The rule: deploy and launch through LaunchServices. Never run the binary from an
IDE terminal.** Doing so is what caused this bug.

```sh
# 1. Quit the running instance from its own menu item (Quit AutoRaise).
./make-app.sh                          # build + sign with the stable self-signed identity
make install                           # copy the bundle to /Applications
open -a /Applications/AutoRaise.app    # launch via LaunchServices
```

Debugging with console output, without re-creating the bug — `open` can redirect the
app's stdout/stderr, so `-verbose` still works:

```sh
open -a /Applications/AutoRaise.app \
     --stdout /tmp/autoraise.log --stderr /tmp/autoraise.log \
     --args -verbose 1
tail -f /tmp/autoraise.log
```

**Never do this from Cursor's (or any IDE's) terminal** — each of these makes the app
a child of the IDE and gets it adopted into the IDE's allow-list entry:

```sh
./AutoRaise                              # bare binary
AutoRaise.app/Contents/MacOS/AutoRaise   # bundle binary directly
make run                                 # execs ./AutoRaise -focusDelay 1
make debug                               # execs ./AutoRaise -focusDelay 1 -verbose 1
```

### Two traps in the current Makefile

- **`make update` is the wrong target.** It builds with
  `-DOLD_ACTIVATION_METHOD -DEXPERIMENTAL_FOCUS_FIRST` — different behaviour from
  what is installed today (verified: the installed binary contains neither) — and it
  bypasses `make-app.sh`, so the bundle gets no stable signature and the
  Accessibility grant resets on every install.
- **`make run` / `make debug` exec the binary directly**, which is the exact pattern
  that caused this bug. If they are to be kept, they should go through `open` with
  `--stdout`/`--stderr` as above.

---

## Root cause, with evidence

### The allow-list

Store (TCC-protected — needs Full Disk Access, or a Finder copy; see
[Reading the allow-list](#reading-the-allow-list)):

```
~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist
```

Key `trackedApplications` holds a **nested binary plist**: a flat list alternating
a bundle marker and an entry dictionary of
`{ location, menuItemLocations, isAllowed }`. `menuItemLocations` is the list of
apps whose menu bar items Control Center associates with that entry.

Decoded on 2026-08-13 (`<<<` marks entries claiming AutoRaise):

```
ALLOWED  ENTRY (location)                           MENU ITEMS MAPPED TO IT
NO       com.microsoft.OneDrive                     self
YES      com.openai.codex                           self
YES      com.grammarly.ProjectLlama                 self
YES      com.paloaltonetworks.GlobalProtect.client   self
YES      com.linguee.DeepLCopyTranslator            self
YES      dev.kdrag0n.MacVirt                        self
YES      nl.postware.autoraise                      self  <<<
NO       com.docker.docker                          self + com.electron.dockerdesktop
YES      us.zoom.xos                                self
NO       com.anthropic.claudefordesktop             self
YES      com.jamf.connect                           self
YES      com.openai.sky.CUAService                  self
NO       com.pilotmoon.scroll-reverser              self
NO       com.todesktop.230313mzl4w4u92  (Cursor)    self + nl.postware.autoraise,
                                                    test.artest, test.artest2,
                                                    test.artest3, test.x.SL,
                                                    test.x.NOSL                  <<<
YES      com.okta.mobile                            self
NO       com.microsoft.teams2                       self
YES      eu.exelban.Stats                           self
YES      com.displaylink.DisplayLinkUserAgent       self
```

AutoRaise's own entry is `isAllowed: true`; Cursor's is `isAllowed: false` and claims
AutoRaise. The `false` wins.

### Control Center's log

```sh
/usr/bin/log stream --style compact --predicate 'subsystem == "com.apple.controlcenter"' \
  | grep -E "blocked|ephemaral|hiding"
```

Blocked app, in order (note: the item is accepted and placed *first*, then blocked
~5 ms later):

```
appStatusItems] Host properties initialized; (bid:nl.postware.autoraise-Item-0-<pid>).
                State(applicationItem: true, clientRequestsVisibility: true, neverClip: false)
appStatusItems] Starting to track host; ...
displayables]   Created instance DisplayableId(...) in .menuBar for ...
appStatusItems] Created ephemaral instance DisplayableId(...) with positioning .ephemeral
menu]           Persisting displayables state
appStatusItems] Moving host to blocked list; (bid:nl.postware.autoraise-Item-0-<pid>)
appStatusItems] Starting to track blocked host; ...
menu]           Responding to displayables availability update; hiding status items for [...]
```

An unaffected app produces the identical sequence up to and including
`Created ephemaral instance ... .ephemeral`, then stays visible. `Moving host to
blocked list` is the single reliable signal. The `blockedHosts` machinery is visible
in the Control Center binary's strings (`Moving host to blocked list`,
`Updated stored blocked host for %s to %s`,
`Requesting visibility for unblocked host`, `Ignoring host with no bundle id or path`).

`WindowServer`'s `Incomplete status bar capture surface detected. Requested bounds:
(…) [0.000 x 0]` errors are a **consequence** (timestamped after the block), not a
cause.

### What the blocked item looks like from inside the process

Same probe program (appendix), one launch per identifier:

| | blocked identifier | unaffected identifier |
|---|---|---|
| `isVisible` / button hidden / alpha | 1 / no / 1.00 | 1 / no / 1.00 |
| image | SF Symbol resolved, 16×16 | same |
| **status bar window frame** | **`{{2527, 1418}, {33, 22}}`** | **`{{1719, 1410}, {33, 30}}`** |

The blocked item's window is flush into the top-right corner of the main display
(x 2527–2560 on a 2560-wide screen, overlapping the clock window at `(2420,0 140x30)`)
and is **22pt** tall — the legacy `NSStatusBar.thickness` — instead of the real 30pt
menu bar height. That is the fallback frame for an item that never got a slot. Same
signature as CodexBar's `(0, -22, …x22)`.

### How the adoption correlates with launch method

Every app launched during this investigation, split perfectly:

| Launch method | Landed in Cursor's `menuItemLocations` | Icon visible |
|---|---|---|
| binary exec'd from Cursor's terminal (5 apps: `test.artest`, `test.artest2`, `test.artest3`, `test.x.SL`, `test.x.NOSL`) | yes | no |
| `open` / LaunchServices (9 apps: `test.bolt`, `test.v2`, `test.v3`, `test.sb.BEFORE`, `test.sb.AFTER`, `test.probe.fresh`, `test.probe.dup`, `nl.postware.autoraise3`, `local.autoraise.displayfocus`) | no — each got its own entry | yes |

14 for 14. Note the mapping is keyed by bundle identifier and is sticky: once an
identifier is in Cursor's list, later launches via `open` are still blocked. That is
exactly AutoRaise's situation.

---

## Pending cleanup (so Cursor can go back to "off")

Currently Cursor is allowed in the menu bar purely to unblock AutoRaise. To restore
that setting, remove the stale claims from Cursor's entry first.

1. Copy the plist out via Finder (see below) to `/tmp`.
2. Produce a corrected copy:

```python
python3 - <<'PY'
import plistlib, shutil
SRC = '/tmp/group.com.apple.controlcenter.plist'
DST = '/tmp/group.com.apple.controlcenter.fixed.plist'
CURSOR = 'com.todesktop.230313mzl4w4u92'
DROP = {'nl.postware.autoraise', 'test.artest', 'test.artest2',
        'test.artest3', 'test.x.SL', 'test.x.NOSL'}
d  = plistlib.load(open(SRC, 'rb'))
ta = plistlib.loads(d['trackedApplications'])
for e in ta:
    if isinstance(e, dict) and e.get('location', {}).get('bundle', {}).get('_0') == CURSOR:
        before = len(e['menuItemLocations'])
        e['menuItemLocations'] = [m for m in e['menuItemLocations']
                                  if m.get('bundle', {}).get('_0') not in DROP]
        print('cursor entry: %d -> %d mapped items' % (before, len(e['menuItemLocations'])))
d['trackedApplications'] = plistlib.dumps(ta, fmt=plistlib.FMT_BINARY)
plistlib.dump(d, open(DST, 'wb'), fmt=plistlib.FMT_BINARY)
print('wrote', DST)
PY
```

3. Copy `group.com.apple.controlcenter.fixed.plist` back over the original with
   Finder (rename it to `group.com.apple.controlcenter.plist` first; Finder will ask
   to replace). **Keep the untouched copy as a backup.**
4. `killall cfprefsd; killall ControlCenter`
5. Relaunch AutoRaise, confirm the icon, then set Cursor back to *off* in
   System Settings → Menu Bar → Allow in the Menu Bar.

Risk to be aware of: the nested plist is written by Swift's `PropertyListEncoder`;
re-encoding it with Python's `plistlib` should be structurally equivalent but has not
been verified end-to-end. Hence the backup. If it goes wrong, delete the file —
Control Center recreates it, and every app's allow flag returns to default.

### Reading the allow-list

The folder is TCC-protected. **Important gotcha:** `grep -r` over `~/Library`
silently skips it (`Operation not permitted`), which is why a full-Library content
search for the bundle identifier came back empty and sent this investigation down a
long dead end. Either grant the terminal Full Disk Access, or copy the file out with
Finder, which needs no permission grant:

1. Finder → **⌘⇧G** → `~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences`
2. Select `group.com.apple.controlcenter.plist`, **⌘C**
3. **⌘⇧G** → `/tmp` → **⌘V**

---

## Other leftover state worth tidying

- **Accessibility grant for AutoRaise was reset** during the investigation
  (`tccutil reset Accessibility nl.postware.autoraise` and `... ListenEvent ...`,
  with approval). Re-approve AutoRaise in
  System Settings → Privacy & Security → Accessibility if not already done.
- **Stale login item under the old identity.** `sfltool dumpbtm` entry #5 lists
  `/Applications/AutoRaise.app` with `Bundle Identifier: local.autoraise.displayfocus`
  — the pre-merge launcher's identifier — `Disposition: [enabled, allowed, notified]`.
  Toggling "Start at Login" off and on from the app's menu should re-register it
  under `nl.postware.autoraise`.
- **Orphan preferences domain** `~/Library/Preferences/local.autoraise.displayfocus.plist`
  (`delayMs = 50`, `didShowAXNotice = true`, `enabled = true`) is dead weight from the
  pre-merge launcher; the live domain is `nl.postware.autoraise` (`delayMs = 20`).

---

## Investigation trail: why the app itself was exonerated

Kept so none of this gets re-tested. Each row was a built-and-launched variant,
judged by the Control Center log or by direct observation of the menu bar.

| # | Hypothesis | Test | Result |
|---|---|---|---|
| 1 | Status item created before `NSApplication` exists (it is, in `main()`) | minimal apps built both ways; then the real source with `[NSApplication sharedApplication]` forced before setup | no difference |
| 2 | SF Symbol name invalid → nil image | probe logged a resolved `NSImage` | not it |
| 3 | Installed binary built with different flags | `strings` for `focusDelay`/`EXPERIMENTAL_FOCUS_FIRST`/`OLD_ACTIVATION_METHOD`: absent. `size -m` sections identical, `nm -j` 404 symbols each, only `__GLOBAL__sub_I_*` differs | code identical |
| 4 | Engine activity (5 ms poll chain, `CGEventTapCreate`) | poll timer and event tap compiled out, real identity | still blocked |
| 5 | Main thread starved by the 5 ms poll | `sample`: main thread parked in `__CFRunLoopRun`; `top`: 0.4–0.7 % CPU | idle |
| 6 | Signing identity (`AutoRaise Self-Signed`, untrusted CA) | fresh id + same cert → visible; real id + ad-hoc → blocked | not it |
| 7 | `Info.plist` extras (`CFBundleIconFile`, icns, versions) | fresh id with full plist + icns → visible | not it |
| 8 | Something about `/Applications` | verbatim `cp -R` of the installed bundle run from `/tmp` | still blocked |
| 9 | Duplicate LaunchServices registrations | new id registered at two paths → visible; real app with only `/Applications` registered → still blocked | not it |
| 10 | Stale BTM login item under the old identifier | `/tmp` copies have no BTM record and were still blocked | not it |
| 11 | Accessibility / Input Monitoring grant | `tccutil reset` both, relaunch | still blocked |
| 12 | Saved status item position | wrote `NSStatusItem Preferred Position Item-0 = 600` (reverted) | no change |
| 13 | Saved per-app hidden flag | app domain holds only `delayMs`; apps genuinely hidden this way do carry a key (`com.microsoft.OneDrive`, `com.openai.sky.CUAService`: `NSStatusItem VisibleCC Item-0 = false`) | absent for AutoRaise |
| 14 | Autosave name collision | explicit `autosaveName = "AutoRaiseMain"` | `Moving host to blocked list; (bid:nl.postware.autoraise-AutoRaiseMain-…)` |
| 15 | macOS 26 "bento box" grouping swallowed it | decoded `ByHost/com.apple.controlcenter.bentoboxes.*.plist` → `boxes[0].displayablesData` | no reference to the app |
| 16 | Stale Control Center state | `killall ControlCenter` | still blocked |
| 17 | Menu bar out of room | an unaffected app got a slot at the same moment | not it |
| 18 | Churn from many rebuild/kill cycles earning a block | `local.autoraise.displayfocus` (used heavily pre-merge) → not blocked; brand-new `nl.postware.autoraise3` → not blocked | not it |
| 19 | MDM / configuration profile | `grep` of `/Library/Preferences`, `/Library/Managed Preferences`, `/var/db/ConfigurationProfiles`; `profiles show` | no hit |
| 20 | Hardcoded blocklist in Control Center | `strings` of the binary for the identifier | no hit |
| 21 | Block written to disk when it happens | marker file + `find ~/Library -newer` | nothing written — the block is *read* from the allow-list each launch |

---

## Methodology notes for next time

- **Go straight to the Control Center log.** One command tells you whether the OS is
  blocking the item, which would have collapsed this whole investigation into minutes:
  ```sh
  /usr/bin/log stream --style compact --predicate 'subsystem == "com.apple.controlcenter"' \
    | grep -E "blocked|ephemaral"
  ```
- **`log` is a zsh builtin** — call `/usr/bin/log` explicitly or it fails with
  "too many arguments".
- **A `grep -r` that skips protected files looks exactly like a negative result.**
  This cost the most time here. When searching for state, check for
  `Operation not permitted` rather than discarding stderr.
- **Accessibility API positions were actually reliable**, contrary to what the first
  draft of this document said. Items reporting a sane menu bar row (`y ≈ 3–4`) were
  visible; items reporting junk (`(-1, 1439)`, `(2526, -1)`) were genuinely blocked.
  The apparent inconsistency was the bug itself: the "junk" apps were all ones in
  Cursor's mapping. `System Events` is a usable signal, but the in-process probe and
  the log are better.
- **`CGWindowListCopyWindowInfo` does not show third-party status item windows** on
  this OS — all layer-25 windows belong to Control Center, which hosts the scenes.
  Absence there means nothing.
- **`screencapture` needs Screen Recording permission.** Without it, every visual
  check needs a human. Granting it to the terminal up front removes many round trips.
- Give each test variant a **different SF Symbol** so several can be told apart in
  one look, and never run two variants with the same icon at once.

---

## Environment at time of investigation

- macOS 26.x (Darwin 25.4.0), arm64. `NSStatusItem` is an **`NSSceneStatusItem`**:
  the item's view is a remote scene hosted by Control Center over
  `com.apple.controlcenter.statusitems`. The app does not draw its own icon — which
  is why the OS can hide it unilaterally.
- App: this fork's merged menu-bar build; bundle id `nl.postware.autoraise`; signed
  `AutoRaise Self-Signed` (see `make-app.sh`). Two byte-identical registered copies:
  `/Applications/AutoRaise.app` and the repo build.
- Displays: `G257HU` `{{0,0},{2560,1440}}` @1x (main, menu bar 31pt);
  `Built-in Retina` `{{-1728,135},{1728,1117}}` @2x (32pt);
  `DELL U2417H` `{{2560,360},{1920,1080}}` @1x.
  `screensHaveSeparateSpaces == 0`; `NSStatusBar.thickness == 22`.

---

## Appendix — the probe program

Reports what the app sees about its own status item. Build into a bundle with
`LSUIElement`, one per identifier under test, launch with `open`, read
`/tmp/probe/out-<bundleid>.txt`.

```objc
#import <Cocoa/Cocoa.h>
static NSStatusItem *item;
static void report(void) {
  NSMutableString *s = [NSMutableString string];
  [s appendFormat:@"bundleID=%@\n", [[NSBundle mainBundle] bundleIdentifier]];
  [s appendFormat:@"item=%@\n", item];
  [s appendFormat:@"autosaveName=%@\n", item.autosaveName];
  [s appendFormat:@"isVisible=%d\n", (int)item.visible];
  [s appendFormat:@"image=%@\n", item.button.image];
  NSWindow *w = item.button.window;
  [s appendFormat:@"winFrame=%@ visible=%d alpha=%.2f level=%ld screen=%@\n",
     NSStringFromRect(w.frame), (int)w.isVisible, w.alphaValue, (long)w.level,
     w.screen.localizedName];
  [s appendFormat:@"buttonFrame=%@ hidden=%d alpha=%.2f\n",
     NSStringFromRect(item.button.frame), (int)item.button.isHidden,
     item.button.alphaValue];
  NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
  for (NSString *k in d)
    if ([k containsString:@"NSStatusItem"]) [s appendFormat:@"pref[%@]=%@\n", k, d[k]];
  [s appendFormat:@"statusBarThickness=%.1f\n", [NSStatusBar systemStatusBar].thickness];
  [s writeToFile:[NSString stringWithFormat:@"/tmp/probe/out-%@.txt",
      [[NSBundle mainBundle] bundleIdentifier]]
      atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
int main() { @autoreleasepool {
  [NSApplication sharedApplication];
  item = [[NSStatusBar systemStatusBar] statusItemWithLength: NSVariableStatusItemLength];
  NSImage *img = [NSImage imageWithSystemSymbolName:@"cursorarrow.rays"
                                accessibilityDescription:@"probe"];
  [img setTemplate:YES];
  item.button.image = img;
  item.menu = [[NSMenu alloc] init];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{ report(); [NSApp terminate:nil]; });
  [NSApp run];
}}
```
