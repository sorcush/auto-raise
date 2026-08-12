
## 2026-08-12 — spec review
- **Run:** spec · `docs/superpowers/specs/2026-08-12-window-drag-focus-design.md` · read-only, no lenses specified
- **Findings:** 2 Critical, 3 Important, 2 Minor · verdict: Needs revision
- **Triage:** Accepted 6/7. The best finding was real and non-obvious: `get_mousewindow()`
  is not side-effect-free — `fallback()` calls `activate(pid)` (AutoRaise.mm:378-380) and
  the `kAXApplicationRole` branch activates XQuartz (AutoRaise.mm:419-429) — so capturing
  on the press tick could activate an app inside the very window the `abort` check
  protects. Fixed more broadly than proposed by dropping AX from drag capture in favour of
  `topwindow()` + `kCGWindowListOptionIncludingWindow`, which also removed the
  AXUIElementRef ownership surface the reviewer had raised as a separate item.
  Also accepted: stale `lastDisplayID` during `ignoreTimes`/`appWasActivated` early
  returns; missing capture-validity lifecycle; `make test` builds only one binary
  (Makefile:37-38); over-absolute sub-20 ms claim.
- **Pushed back on 1 Critical** (poll-latency race): overstated. A crossing survives only
  if press, display crossing and release all land inside ~1-2 poll intervals, and a
  crossing seen before classification is self-healed by the cancel-pending-arm rule.
  Documented as a stated limitation instead of adding mouse-down events to the event tap.
- **Reviewer quality:** Strong again, and codebase-grounded — it traced `get_mousewindow()`
  into `fallback()` rather than trusting the name. Two of its own proposed *fixes* were
  wrong, though: moving the gate above the housekeeping would have preempted the
  `ignoreTimes` decrement (the exact bug class the 2026-07-03 spec fixed), and it treated
  `appWasActivated` as firing on any app activation when `appActivated()` returns early at
  AutoRaise.mm:899 unless activated by the task switcher. Findings worth trusting;
  remedies worth re-deriving.
- **Environment friction:** None. Returned REVIEWED with session_id
  9ef114da-019d-430e-9800-cff235395e67.
- **Recommendations:** Telling it which decisions were user-approved and not to relitigate
  them worked — no wasted findings on the "only window drags" narrowing. Worth repeating.
  Next time also ask it to verify the reachability of each finding, since its two bad
  remedies both came from assuming a trigger was more common than the code allows.

## 2026-07-03 — spec review
- **Run:** spec · `docs/superpowers/specs/2026-07-03-display-change-focus-design.md` · lenses: backend, frontend, ui
- **Findings:** 3 Critical, 8 Important, 3 Minor · verdict: Needs revision
- **Triage:** Accepted 13/14. All 3 Critical verified against code and accepted
  (config-file-only-when-argc==1 at AutoRaise.mm:808; stale spaceHasChanged → delay
  bypass; child-process TCC ownership). Pushed back on 1 Minor (claimed AutoRaise.icns
  absent — it is present in repo root).
- **Reviewer quality:** Strong and codebase-grounded — it actually read onTick() and
  readConfig() and cited exact line-anchored behavior. The two hardest bugs (config
  regression, space-change delay bypass) were real and non-obvious. One false positive
  (icns). No notable misses caught by me beyond that.
- **Environment friction:** None. Probe returned READY; reviewer returned REVIEWED with
  session_id 1ff705a6-f46e-42ea-85f5-8aac541f929c.
- **Recommendations:** Lens selection was fine but "frontend/ui" are web-oriented; for
  native macOS specs a "platform/permissions (TCC/signing)" lens would be more on-target
  — the best findings came from that angle under the generic backend lens anyway.
