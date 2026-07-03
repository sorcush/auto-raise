
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
