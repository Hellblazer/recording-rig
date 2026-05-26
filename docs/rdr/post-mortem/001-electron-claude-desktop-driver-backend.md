# Post-Mortem: RDR-001 Electron Claude Desktop driver backend

## RDR Summary

RDR-001 proposed a **Desktop backend** for recording-rig — recording the real
Claude.app (Chat, Code, CoWork surfaces), not just a headless CLI session — additive
to and not disturbing the existing CLI backend. After a Phase 0 architecture pivot it
recommended **native macOS automation**: a Swift driver that drives Claude.app over
Accessibility (AXUIElement) and captures via ScreenCaptureKit, coordinated by a
permanent `.mcpb` bridge that writes the CLI rig's sentinel contract.

## Implementation Status

**Implemented.** Shipped as **v0.2.0** (annotated tag + GitHub Release, 2026-05-26)
through a self-hosted pinned-source marketplace. Chat/Code/CoWork certified 30/30 in
the Phase 4 release cert; the CLI backend is byte-unchanged.

---

## Implementation vs. Plan

### What Was Implemented as Planned

- AX-drive (AXManualAccessibility arm + AXPress nav + AXValue/`postToPid` submit + geometry re-assert) + ScreenCaptureKit `.mov` capture, exactly as the post-pivot Technical Design specified.
- Provider-polymorphic coordination behind one interface: Chat/Code → `mcp-bridge`, CoWork → `agent-transcript-tail`.
- `record.sh` orchestrates (SESSION, sentinel watch, active-session pointer, launch); the Swift `bin/desktop-driver` owns AX-drive + capture — the division of labor the RDR drew.
- Additive backend dispatch (`backend: "desktop"`); the CLI flow stayed byte-identical (verified by `examples/cli-smoke.json`).
- `doctor` / `diagnose` / `author-spec` gained desktop modes, as the Phase 5 plan called for.

### What Diverged from the Plan

The two largest course-corrections happened **before acceptance** and were folded into
the accepted RDR by the gate process (so they are not implementation drift — see "What
the RDR Got Right"): the **Playwright/CDP → AXUIElement+ScreenCaptureKit** pivot (A4 FAIL
in P0.5) and the **`coworkd-log-tail` → `agent-transcript-tail`** CoWork fallback
(2026-05-25 live-probe amendment). True **post-acceptance** divergences:

- **v1.8555.2 lazy-loads MCP extension tools** (rr-yfj): Claude.app loads extension tools on demand rather than pre-injecting them. The original prologue produced **zero** `rig_*` calls (empty bridge transcript → hard miss). The implementation now leads the chat/code `system_prompt_prologue` with "load the Recording Rig Bridge tools first." Caught only by the strict 30× release cert, not a 1× smoke.
- **A9 single-instance mutual-exclusion refuted**: the RDR assumed a single-instance lock forced one-at-a-time; `open -n --user-data-dir` actually launches concurrent instances. The A9 guard narrowed to an OAuth-login collision guard on the mutating `doctor` subcommands only.
- **Bridge install is file-drop, not a UI dialog** (A3): `doctor --install-bridge` unzips the `.mcpb` into the profile + writes `isEnabled:true` — the planned AX install-dialog dismissal (A8/P0.8) was never needed.

### Existing Infrastructure Reused Instead of New Code

- The CLI rig's `/tmp/${SESSION}.*` **sentinel contract** — the bridge writes byte-identical sentinels, so the validator and the turn-end watch were reused unchanged.
- `lib/quality.sh` soft-miss aggregation — reused by `doctor` and `diagnose` for the instruction-drift advisory.

### What Was Added Beyond the Plan

- `doctor` desktop **subcommands** (`--install-bridge` / `--install-profile` / `--seed-from-primary` / `--probe-surfaces` / `--verify-bridge`) and a synthesized `diagnose` summary verdict.
- A **self-hosted pinned-source marketplace** (`.claude-plugin/marketplace.json`), `CONTRIBUTING.md`, and a repo `release` skill — release-engineering infrastructure the RDR did not anticipate.

### What Was Planned but Not Implemented

- **Windows host** — Gap 4 was explicitly scoped to one OS (macOS) with a follow-up RDR for the second; deferred as designed.
- **Phase 0 residual probes** P0.2 / P0.7 / P0.8 — closed as **superseded/validated** by the shipped design (agent-transcript-tail; 30d staleness threshold; file-drop install) rather than run. See T2 `recording-rig/RDR-001-phase0-residuals-disposition`.

---

## Drift Classification

| Category | Count | Examples | Preventable? |
| --- | --- | --- | --- |
| **Unvalidated assumption** | 3 | Playwright/CDP attach works (A4); `coworkd.log` carries a turn signal; A9 single-instance lock | Yes — spike (P0.5 and the 2026-05-25 probe DID catch two, pre/post-acceptance) |
| **Framework API detail** | 2 | Claude.app quits on any CDP transport; v1.8555.2 lazy-loads extension tools | Partly — the CDP guard by spike; the lazy-load only by the strict 30× cert |
| **Missing failure mode** | 2 | empty bridge transcript on lazy-load; `coworkd.log` has no turn signal | Yes — strict-gate / live-probe |
| **Missing Day 2 operation** | 1 | self-hosted marketplace + release protocol/skill not planned | Yes — Day 2 checklist |
| **Scope underestimation** | 0 | (Desktop determinism shortfall was honestly documented up front, not drift) | — |

### Pattern References

- **Unvalidated assumption (3)** and **Framework API detail (2)** — both ≥2. The recurring pattern: *Electron-app internals (transport guards, lazy tool-loading, instance locks) are not knowable from docs and must be spiked against the exact app build.* The project already internalized this (the P0 probe phase, the strict 30× cert).

---

## RDR Quality Assessment

### What the RDR Got Right

- **The Phase 0 probe gate paid for itself.** P0.5 found the CDP-transport guard *before* acceptance and triggered a clean architecture pivot (Playwright → AX/SCK); the RDR was revised and re-gated (Gate v1 BLOCKED → v2 PASSED) so the accepted document already reflected reality. This is the model working as intended.
- **Provider-polymorphic coordination** absorbed the `coworkd-log-tail → agent-transcript-tail` correction as a fallback-implementation swap behind a stable interface — no architecture change, no re-gate.
- **Honest determinism framing.** The RDR documented up front that the Desktop backend is structurally less deterministic than the CLI (the model must choose to call the rig tools) and shipped mitigations (fallback timer, soft-miss trend) rather than over-promising.

### What the RDR Missed

- The **v1.8555.2 lazy-load** failure mode — only a strict, repeated (30×) cert surfaced it; a confidence-sample would have shipped a broken desktop backend.
- The **release/distribution model** (self-hosted pinned-source marketplace) — a Day 2 concern that landed entirely post-implementation.

### What the RDR Over-specified

- Minimal. The pre-acceptance pivot removed the Playwright/CDP machinery before any of it was built, so the over-specification was caught at gate time rather than in code. Two pre-pivot research entries (Playwright pin; Playwright DOM dismissal) survive only as annotated `[SUPERSEDED]` history.

---

## Key Takeaways for RDR Process Improvement

1. **Spike Electron-app internals against the exact build, every phase.** Transport guards, lazy tool-loading, and instance locks are version-specific and undocumented; assume nothing survives an app upgrade (re-verify on each Claude.app bump).
2. **A strict, repeated cert is a different instrument than a smoke.** The 30× release cert caught the lazy-load regression a 1× smoke would have missed — budget the strict gate before any release, not just a confidence sample.
3. **Name the distribution/Day-2 model in the RDR.** The marketplace + release protocol were invented after the fact; a "how does this ship and update" section belongs in the original plan.
4. **Provider-polymorphic seams localize live-probe corrections.** Putting coordination behind one interface meant a disproven fallback was a one-file swap, not a re-architecture — a reusable hedge against unverifiable runtime assumptions.

---

## Close

RDR-001 closed **2026-05-26**, reason **Implemented**. Substantive-critic verdict
`justified` (0 critical / 0 significant) after one remediation (the §Contradiction Check
fallback-name inconsistency). All beads closed (epic `rr-2pp` + Phases 0–5); shipped as
v0.2.0.
