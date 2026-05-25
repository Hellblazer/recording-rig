---
title: "Electron Claude Desktop driver backend"
id: RDR-001
type: Architecture
status: accepted
priority: medium
author: Hal Hildebrand
reviewed-by: self
created: 2026-05-23
accepted_date: 2026-05-23
related_issues: []
---

# RDR-001: Electron Claude Desktop driver backend

> Revise during planning; lock at implementation.
> If wrong, abandon code and iterate RDR.

## Problem Statement

The rig records `claude-code` CLI sessions deterministically via tmux + asciinema + hook-driven sentinels (see [`../design.md`](../design.md)). The Claude product surface has grown well past the CLI: the Electron-based Claude Desktop app now hosts three internal modes — Chat, Code, CoWork — none of which the rig can record today. Recordings of these surfaces are needed for tutorials, demos, regression fixtures, and forensic captures, with the same determinism guarantees the CLI rig provides (no TUI scraping, validated outputs, single-spec re-record). The challenge is reproducing the rig's hook-driven coordination model on a surface that has no exposed hook system, where the model's lifecycle events are not directly observable from the host process.

### Enumerated gaps to close

#### Gap 1: No Desktop coverage

Today the rig binds to the CLI's `--settings` hook surface. Claude Desktop has no equivalent: the model executes inside Claude.app's renderer/main processes (Chat), in a local agent mode subprocess (Code), or inside a Linux VM via vsock (CoWork). The driver has no signal to bind to. The fix is a new backend that obtains an analogous signal source without scraping the rendered UI.

#### Gap 2: Surface heterogeneity

Chat is an embedded `claude.ai` web app inside Electron. Code is local-agent-mode with per-folder trust gates. CoWork runs a sandboxed Linux VM (Ubuntu 22.04, Apple Virtualization framework on macOS, Hyper-V on Windows) executing tool calls inside the VM and surfacing results via vsock. A single coordination strategy will not work uniformly across all three — the design must accommodate per-surface variance without proliferating the spec dialect.

#### Gap 3: MCP-as-sentinel viability is unconfirmed for Code and CoWork

The proposed unifying mechanism is a custom MCP server (delivered as a `.mcpb` Claude Extension) exposing `rig.turn_end`, `rig.checkpoint`, `rig.ask`, and `rig.emit` tools — the model is instructed to call these at named beats, and the bridge writes filesystem sentinels exactly like CLI hooks do. GitHub issue `anthropics/claude-code#42453` confirms that legacy `claude_desktop_config.json mcpServers`-path tools are **disabled** in Code and CoWork. Whether the modern `.mcpb` path is also restricted is unconfirmed. The architecture must work in both the optimistic (`.mcpb` works everywhere) and pessimistic (`.mcpb` Chat-only) case, with documented behavior differences.

#### Gap 4: Cross-platform fragmentation

Claude Desktop ships on macOS and Windows (Feb 2026 onwards). Linux does not ship. macOS uses Apple Virtualization for CoWork; Windows uses Hyper-V — different host-side parser surface area. Phase-1 scope must commit to one OS without precluding the other; a follow-up RDR can cover the second host.

## Context

### Background

The existing CLI rig (v0.1.2 as of 2026-05-23) is documented in [`../design.md`](../design.md). Its load-bearing insight is that TUI scraping is structurally broken — the Claude Code spinner glyph rotates through `✶ ✢ ✻ ✳ ✽`, the "esc to interrupt" banner appears and disappears mid-redraw, and the busy-text participle is drawn from a runtime-reconfigurable 90-word Statsig-flagged dictionary. The rig sidesteps this by using `claude --settings` to install lifecycle hooks (`UserPromptSubmit`, `Stop`, `PostToolUse`, `PreToolUse`, `SessionStart`) that drop sentinel files under `/tmp/${SESSION}.*`. The driver watches sentinels, never pane text.

Claude Desktop has no analogous hook surface for the driver to bind to. The earlier sketch (in conversation, 2026-05-23) proposed substituting MCP tool calls for hook events: install a `.mcpb` extension that exposes `rig.*` tools, instruct the model via prompt prologue to call those tools at named checkpoints, have the extension write the same sentinel files the CLI hooks do. This RDR works out the consequences of that proposal.

### Technical Environment

Confirmed by local probe (Claude Desktop installed at `/Applications/Claude.app`, this session):

- **Claude Desktop** version `CFBundleShortVersionString = 1.8555.2`. Electron Framework version `CFBundleVersion = 41.6.1` (built with macOS SDK 15.5).
- **Multi-process Electron**: helpers at `Contents/Helpers/`: `Claude Helper.app`, `Claude Helper (GPU).app`, `Claude Helper (Plugin).app`, `Claude Helper (Renderer).app`.
- **App bundle integrity**: `ElectronAsarIntegrity` SHA256 over `Contents/Resources/app.asar` (25 MB) verified at launch. The Extensions directory is outside the asar.
- **MCP integration**: two paths. Legacy `~/Library/Application Support/Claude/claude_desktop_config.json mcpServers: {}` (empty on this machine). Modern `~/Library/Application Support/Claude/Claude Extensions/<id>/` (this machine has `ant.dir.ant.anthropic.filesystem`, `ant.dir.gh.k6l3.osascript`, `ant.dir.gh.silverstein.pdf-filler-simple`, `local.mcpb.hal-hildebrand.palinex`, plus settings for `local.mcpb.hal-hildebrand.nexus`).
- **CoWork architecture**: separate `coworkd` daemon (log: `coworkd.log`), Linux VM via Apple Virtualization (log: `cowork_vm_swift.log`), Node-side VM management (log: `cowork_vm_node.log`). VM: Ubuntu 22.04 ARM64, 4 CPUs, 4 GB RAM, rootfs from `vm_bundles/claudevm.bundle/rootfs.img`, gvisor user-mode networking, host↔VM RPC via vsock (CID=2, port=51234). Claude Code SDK installs inside the VM on each startup.
- **Chat architecture**: `claude.ai-web.log` confirms Chat is the `claude.ai` web app loaded inside a BrowserWindow. React + Next.js + Radix UI components (`DialogContent` warnings observed). Canvas elements present.
- **Auth**: OAuth tokens cached locally; refresh loop polls every 60s (observed in `main.log`). Keychain entry "Claude Safe Storage" bound to app identity `Q6L2SF6YDW.com.anthropic.claudefordesktop`.

Existing rig components (composed with, not replaced):

- `bin/record.sh` — orchestrator + preflight
- `bin/driver.sh` — paste commands, navigate gates via tmux send-keys
- `bin/render-hooks.sh` — spec → `claude --settings` JSON
- `bin/tmux-session.sh` — spawn detached tmux + optional companion pane
- `bin/validate.mjs` — cast → pass/fail before render
- `lib/sentinels.sh` — sentinel primitives: `rig_check_identifier()` (line 12), `sentinel_clear_all()` (line 41), `sentinel_wait_idle()` (line 78)
- `hooks/hooks.json.tmpl` — five-hook template (UserPromptSubmit, Stop, PreToolUse[AskUserQuestion], PostToolUse, SessionStart)
- Plugin: `commands/{record,author-spec,doctor,diagnose}.md`, `skills/{record,author-spec,doctor,diagnose}/`

## Research Findings

### Investigation

Research executed by a `nx:deep-research-synthesizer` agent (this session, scratch tag `recording-rig-desktop-rdr-findings`, entry `45000495-41ae-43d4-8fd5-3dfe760fe916`) plus local filesystem probes of the installed Claude Desktop and the recording-rig codebase. Cross-references the live Playwright Electron docs via Context7 (`/microsoft/playwright`), the MCPB manifest specification (`github.com/modelcontextprotocol/mcpb/blob/main/MANIFEST.md`), the Anthropic engineering blog on Desktop Extensions (`anthropic.com/engineering/desktop-extensions`), and GitHub issue `anthropics/claude-code#42453`.

#### Dependency Source Verification

| Dependency | Source Searched? | Key Findings |
| --- | --- | --- |
| Playwright Electron API | Yes (Context7 `/microsoft/playwright`) | `_electron.launch({ executablePath, args, env, recordVideo, recordHar, tracesDir })`, `.firstWindow()`, `.window` event, `.evaluate()` runs in main process, `page.screencast.start/stop` (v1.59+) |
| MCPB manifest spec | Yes (docs + local manifest files) | v0.4 confirmed; `server.type: node|python|binary|uv`; variable substitution `${__dirname}`, `${HOME}`, `${user_config.KEY}`; `compatibility.platforms: ["darwin","win32","linux"]`; `_meta` extension point |
| Claude Desktop config layout | Yes (filesystem probe) | `~/Library/Application Support/Claude/{Claude Extensions/,Claude Extensions Settings/,claude_desktop_config.json,Local State,Cookies,Local Storage,IndexedDB,blob_storage,Cache,Logs/}` |
| Electron multi-instance via `--user-data-dir` | Yes (web + Playwright issue tracker) | Works on Claude.app: `open -n -a Claude --args --user-data-dir=<path>` creates fully isolated instance (independent config, extensions, prefs, CoWork VM). Playwright issue #10369 confirms no attach-to-running support. |
| recording-rig codebase | Yes (direct read) | Verified line ranges: `render-hooks.sh:31-44` (atomic sentinel write via `.partial`+rename), `record.sh:104-107` (`rig_check_identifier` on `capture_tools[].name`), `record.sh:208-212` (refuse-launch via `tmux has-session`), `lib/sentinels.sh:12,41,78` (primitives), `commands/diagnose.md:12` (`prompt-submitted` reference in diagnose taxonomy) |

### Key Discoveries

- **`.mcpb` is the modern MCP registration path.** — **Documented** (Anthropic engineering blog, MCPB MANIFEST spec). Legacy `claude_desktop_config.json mcpServers` is deprecated. Bridge MUST ship as `.mcpb`.
- **Legacy `mcpServers` tools disabled in Code and CoWork.** — **Documented** (GitHub anthropics/claude-code#42453). Error: "This tool has been disabled in your connector settings." Closed stale without Anthropic comment.
- **`.mcpb`-path availability in Code and CoWork is unconfirmed.** — **Assumed** (no source found either way). Needs Phase 0 spike.
- **CoWork runs a full Linux VM.** — **Verified** (local `coworkd.log`, `cowork_vm_swift.log` probe). Apple Virtualization on macOS, Hyper-V on Windows (`@ant/claude-swift` is macOS-specific per `cowork_vm_node.log`). Tool execution happens inside the VM; UI surfaces results via vsock.
- **Playwright cannot attach to a running Claude.app.** — **Documented** (Playwright issue #10369, closed "not planned"). Must launch its own instance.
- **`--user-data-dir` provides full isolation** (independent config, extensions, prefs, CoWork VM state). — **Verified** (multi-instance guides; local app entitlements probe).
- **Keychain "Claude Safe Storage" is shared by app identity, not user-data-dir.** — **Documented** (Electron safe-storage docs + app entitlements probe `codesign --entitlements`). Both instances on one machine can decrypt each other's encrypted blobs.
- **OAuth token refresh polls every 60s** while Claude is running. — **Verified** (`main.log` observation). Long-lived recording profile + periodic launch keeps tokens warm.
- **`localAgentModeTrustedFolders` is per-user-data-dir.** — **Verified** (`claude_desktop_config.json` probe). Recording profile starts with empty allowlist.
- **Determinism ranking** (most to least): lifecycle hooks > MCP-tool-call sentinels > file-mtime watch > log-tail > network interception > DOM polling. — **Documented** (analysis in research findings). MCP-tool-call is the strongest mechanism available to Desktop; structurally weaker than CLI hooks.
- **Playwright `recordVideo` captures BrowserWindow content including canvas** at GPU-accelerated headed mode. — **Documented** (Playwright API). CoWork sub-panel coverage depends on WebContents layout (open question).
- **No documented ephemeral install for `.mcpb`.** — **Documented** (MCPB spec, install flow). Install writes permanently to `extensions-installations.json` + Extensions dir; uninstall via Settings UI only.

#### Round 2 additions (2026-05-23)

Recorded as T2 entries `001-research-1` through `001-research-20`. Local probes of Claude Desktop 1.8555.2 on macOS Sequoia plus external source research (deep-research-synthesizer agent).

- **MCPB transport is stdio; protocol negotiation 2025-11-25 ↔ 2025-06-18.** — **Verified** (source search). Live observation of `~/Library/Logs/Claude/mcp-server-filesystem.log`: `Secure MCP Filesystem Server running on stdio`, `Server transport closed (intentional shutdown)`. Client `claude-ai 0.1.0` claims `protocolVersion: "2025-11-25"`, server (filesystem) returns `"2025-06-18"`. Both legacy v0.2 (`type: "node"`) and modern v0.4 (`type: "uv"`, palinex) extensions use the same stdio transport. Bridge must implement at least the older `2025-06-18` server spec for back-compat downgrade. *T2: 001-research-1.*
- **MCPB processes are short-lived per-feature-invocation, NOT one-per-Desktop-launch.** — **Verified** (source search). Filesystem MCPB log on this machine: 144 `Server started` events + 446 `Server transport closed` events. Observed sub-second spawn→close cycles (15:02:20.348 → 15:02:20.571 → 15:02:20.592 → 15:02:22.005) plus 15–30 min idle reaping. **RDR design impact**: confirms the `/tmp/recording-rig.active-session` pointer-file pattern is *mandatory*, not optional — the bridge process may be a fresh PID on every tool call, so state must be entirely filesystem-mediated. The pointer-file race window is bounded to "before the first bridge spawn after a Claude-Rig profile launch". *T2: 001-research-2.*
- **`Claude Helper (Plugin).app` runs MCPB child processes with permissive entitlements; no TCC prompts for `/tmp` writes.** — **Verified** (source search). `codesign --display --entitlements` on the helper bundle: `cs.allow-jit`, `cs.allow-unsigned-executable-memory`, `cs.disable-library-validation`. Main Claude.app bundle has NO `app-sandbox` entitlement (only `cs.allow-jit`, `cs.virtualization`, plus device entitlements). Bridge child processes inherit no sandbox restrictions; can write `/tmp/*` without Full Disk Access or Files-and-Folders prompts on macOS Sequoia. *T2: 001-research-3.*
- **Per-MCPB structured log feed at `~/Library/Logs/Claude/mcp-server-<display_name>.log`.** — **Verified** (source search). Format `ISO8601Z [name] [level] message { metadata: ... }`, auto-rotated `<name>1.log`. Bridge stdout/stderr (`console.log` / `print`) appears in this log automatically — free debug instrumentation. Log naming uses the manifest's `display_name` (palinex log is `mcp-server-Palinex.log`); recording-rig bridge should set `display_name: "Recording Rig Bridge"`. Suited for **liveness diagnostics** in `/recording-rig:diagnose`, NOT primary coordination — transport open/close is too coarse to detect turn-end (see also *T2: 001-research-20*). *T2: 001-research-4.*
- **macOS `/tmp` → `/private/tmp` is APFS on the same volume as `/Users` and `~/Library/Logs/Claude`.** — **Verified** (source search). `df /private/tmp /Users ~/Library/Logs/Claude` → all `/dev/disk3s5` APFS (device id `16777231`). `/private/tmp` is persistent APFS (not tmpfs). `rename(2)` between `/tmp/<sess>.<name>.partial` and `/tmp/<sess>.<name>` is atomic, will never EXDEV. The bridge's `.partial`+rename pattern (port of `render-hooks.sh:31-44`) is safe as designed. *T2: 001-research-5.*
- **All cited recording-rig code references verified against current main branch.** — **Verified** (source search). `render-hooks.sh:31-44` (atomic `.partial`+rename via jq), `record.sh:104-107` (preflight `rig_check_identifier "hooks.capture_tools[].name"` loop), `record.sh:208-212` (`tmux has-session` refuse-launch — lines 208–211), `lib/sentinels.sh:12-22` (`rig_check_identifier()` default regex `^[A-Za-z0-9._-]+$`), `lib/sentinels.sh:41-44` (`sentinel_clear_all`), `lib/sentinels.sh:78-107` (`sentinel_wait_idle` with three timeouts), `commands/diagnose.md:12` (`prompt-submitted` in failure taxonomy). RDR's "Existing Infrastructure Audit" table is accurate; no drift. *T2: 001-research-6.*
- **CoWork vsock CID=2 + port 51234 confirmed at runtime; CoWork session lifecycle observable from host.** — **Verified** (source search). Live `coworkd.log`: `[rpc] connecting to host CID=2 port=51234` → `connected successfully`. Session names auto-generated by coworkd (e.g., `adoring-nice-wright`). ext4-formatted 10 GB virtual disk at `/dev/nvme1n1` mounted at `/sessions`. Host paths virtio-fs-mounted into VM: `outputs/` rw, `uploads/` ro, `.claude/projects` ro. `[process:oneshot-<uuid>]` events give per-tool-call visibility. **Two independent CoWork signal sources**: host-side file-mtime-watch on `outputs/` AND host-side log-tail of `coworkd.log` — both stronger than the RDR's current `coworkd-log-tail` alone. *T2: 001-research-7.*
- **`extensions-installations.json` schema documented from live file.** — **Verified** (source search). `{extensions: {<id>: {id, version, hash, installedAt, manifest{...full embedded manifest...}, signatureInfo: {status: "unsigned"|"signed"}, source: "registry"|"local"}}}`. SHA256 hash over the bundle. `signatureInfo.status: "unsigned"` works for v0.2 (filesystem), v0.3 (pdf-toolkit), AND v0.4 (palinex) — unsigned extensions install and run fine. Phase 0 Spike A3 (file-drop install) has a structurally-plausible schema target. *T2: 001-research-8.*
- **RDR §Technical Design API gap: `_electron.launch()` does NOT accept `recordVideo` / `recordHar` / `tracesDir`.** — **Verified** (source search via Context7 `/microsoft/playwright`). Per `docs/src/electron-api/class-electron.md`, `_electron.launch()` accepts exactly five options: `executablePath`, `args`, `cwd`, `env`, `timeout`. The RDR's Phase 2 Step 1 sketch uses options that exist for `browser.newContext()` only. **Correct Electron recording path**: `page.screencast.start({ path })` / `.stop()` on each Electron `page` obtained via `electronApp.firstWindow()` (Playwright v1.59+). HAR + tracing for Electron require `context.tracing.startHar()` / `context.tracing.start()` on a context derived from the Electron app — feasibility requires further validation. **Phase 2 driver sketch MUST be revised**, and HAR/trace capture may need to be reworked or deferred. *T2: 001-research-9.*
- **`claude://` URL handler is bundle-identity-scoped, NOT user-data-dir-scoped.** — **Verified** (source search). `defaults read /Applications/Claude.app/Contents/Info.plist CFBundleURLTypes` shows `CFBundleURLSchemes: ["claude"]` at the bundle level. `defaults read com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers` shows `LSHandlerURLScheme = claude; LSHandlerRoleAll = "com.anthropic.claudefordesktop"`. Both Claude.app instances (primary + Claude-Rig) share the bundle identifier — there is no way to disambiguate two instances of the same bundle in LaunchServices. The RDR Risk "Auth deep-link collision when seeding from primary" is REAL and structurally unavoidable except by mutual exclusion. *T2: 001-research-10.*
- **`.mcpb` and `.dxt` file extensions are registered with Claude.app as `CFBundleTypeRole: Viewer`.** — **Verified** (source search). `defaults read /Applications/Claude.app/Contents/Info.plist CFBundleDocumentTypes`: `{CFBundleTypeExtensions: ["dxt","mcpb"], CFBundleTypeIconFile: "dxt.icns", CFBundleTypeName: "Desktop Extension", CFBundleTypeRole: "Viewer"}`. **Implication for Spike P0.8**: `open path/to/recording-rig-bridge.mcpb` WILL trigger Claude.app's install flow because Claude.app is the registered handler for the `.mcpb` UTI. Note `.skill` is also registered (`CFBundleTypeName: "Skill File"`) — useful if the rig later wants to record skill-installation flows. *T2: 001-research-11.*
- **CoWork VM bundle persists `machineIdentifier` per user-data-dir; gvisor networking artifacts (`vmIP`, `gvisorMacAddress`) are per-VM-start.** — **Verified** (source search). `ls ~/Library/Application Support/Claude/vm_bundles/claudevm.bundle/` shows: `efivars.fd, gvisorMacAddress, machineIdentifier, rootfs.img, rootfs.img.zst, sessiondata.img, vmIP`. Each `--user-data-dir` instance gets its own `vm_bundles/` so `machineIdentifier` (Apple's `VZGenericMachineIdentifier`) does NOT collide across instances. Whether the host's gvisor router supports parallel CoWork VMs remains open, but vsock CID collision is REFUTED by *001-research-17*. *T2: 001-research-12.*
- **Playwright >= 1.59.0 is a hard prerequisite (BLOCKER FOUND + FIXED).** — **Documented** (source search). Playwright 1.57.0 and 1.58.0 fail against Electron 30+ (including Claude.app's Electron 41.6.1) because Playwright passes `--remote-debugging-port=0` as a CLI argument; Electron 30+ rejects this BEFORE any JavaScript executes (`bad option: --remote-debugging-port=0`). Reported as `microsoft/playwright#39008` (2026-01-28). Fixed by `microsoft/playwright PR#39012` (merged same day): "fix(electron): pass port via switches not args". Fix ships in **v1.58.1** (2026-01-30). v1.59.0 (2026-04-01) introduces `page.screencast.start/stop`. Current stable v1.60.0 (2026-05-11). The failure mode is opaque and would be misread as a signing/entitlement failure. **Plugin install instructions MUST pin `playwright >= 1.59.0`; doctor MUST check the version floor.** Strengthens A4 from Unverified to Documented; spike P0.5 reduced to "launch verification only". *T2: 001-research-13.*
- **CoWork `.mcpb` tool delivery has a documented race-condition bug — intended-but-unreliable in production.** — **Documented** (source search). `anthropics/claude-code#20377` (2026-01-23): local and `.mcpb` desktop tools not exposed to CoWork. Partially fixed for Python servers in Claude ~1.1.2156 (2026-02-05). Follow-up `#26259`: Desktop Extension MCP servers not forwarded to CoWork VM. Root cause: `remoteMcpServersConfig` is populated BEFORE all local servers finish initializing — servers that miss the window are silently dropped with no error. `enabledMcpTools` correctly records all connectors as enabled, but `remoteMcpServersConfig` (what reaches the VM) contains only a subset. **Failure is silent from the model's perspective.** **A2 weakens from Unverified to Documented-Unreliable.** Pessimistic-case fallback (`coworkd-log-tail` + file-mtime-watch on `outputs/`) is CONFIRMED necessary, not precautionary. Spike P0.2 must repeat multiple times to catch intermittent failures. *T2: 001-research-14.*
- **No MCP-level session or conversation identifier exists.** — **Verified** (source search). MCP spec 2025-06-18: `_meta` is a generic extension point with NO session-scoping semantics. `clientInfo` on initialize is always `{"name":"claude-ai","version":"0.1.0"}` — zero per-instance differentiation. For stdio transport, no session identifier is defined. `anthropics/claude-code#41836` (2026-04, unresolved) confirms Claude does not echo `Mcp-Session-Id` back. **The `/tmp/recording-rig.active-session` pointer file is the only viable session scoping mechanism.** Bridge MUST defensively read the pointer file on every single tool call (not cache at startup). *T2: 001-research-15.*
- **OAuth `claude://` deep-link routing is deterministically frontmost, not random.** — **Documented** (docs only). macOS LaunchServices routes custom-scheme callbacks to the registered bundle, then delivers the GetURL Apple Event via `NSAppleEventManager` to the **most-recently-active** running instance. **Deterministic, not random.** Mitigation correctly designed; the check MUST test for a running PID (`pgrep -f "Claude.app/Contents/MacOS/Claude"`), not focus state. The Risk section should be strengthened from "may go to wrong instance" to "WILL go to the most-recently-active instance". *T2: 001-research-16.*
- **vsock CID is per-VM-namespaced — no dual-VM collision.** — **Verified** (source search). Apple Virtualization framework `VZVirtioSocketDeviceConfiguration`: every guest gets CID=3, host always has CID=2, each guest-host vsock pair is INDEPENDENT (per-VM namespace). Two host processes both creating CoWork VMs do NOT collide on CID=2. **REFUTES the CID collision risk surfaced in *001-research-7* and *001-research-12*.** Single-active-session guard (mirroring CLI rig's `tmux has-session`) makes this moot anyway. *T2: 001-research-17.*
- **MCPB MANIFEST.md is SILENT on transport.** — **Documented** (source search). Per the canonical v0.4 schema at `github.com/modelcontextprotocol/mcpb/blob/main/MANIFEST.md`, the spec does NOT say "stdio only" — transport is implementation-defined by Claude Desktop. Stdio is empirically confirmed (*001-research-1*) but not spec-mandated. **The silence is load-bearing**: a future Claude Desktop version could change transport for local extensions WITHOUT a manifest version bump. Bridge README and the RDR's "Cross-Cutting Concerns / Versioning" should document this assumption. *T2: 001-research-18.*
- **`open path/to/.mcpb` install dialog is an in-app BrowserWindow element.** — **Documented** (Anthropic engineering blog). Whether the dialog opens as a NEW Electron `BrowserWindow` or as content within an existing one is unknown from docs. Spike P0.8 MUST use `electronApp.windows()` (plural) NOT just `firstWindow()`; subscribe to `electronApp.on('window', ...)` to catch new windows post-launch. Once located, Playwright DOM locators are viable for auto-dismiss (no AppleScript / AXUIElement required). *T2: 001-research-19.*
- **Per-MCPB log feed is suited for liveness diagnostics, NOT primary coordination.** — **Documented** (inference). Updates *001-research-4*: per-MCPB log only carries transport lifecycle events (too coarse for turn-end detection); `coworkd.log` carries semantic events (`[process:oneshot-<uuid>]` per-tool-call) and is the better-grounded log-based provider. The `log-tail-mcp` candidate from *001-research-4* should be DEMOTED from "third coordination provider" to "diagnostic signal" — if the bridge's log stops showing activity during an active session, the bridge may have crashed. Wire into `diagnose`. Code's pessimistic fallback should rely on file-mtime-watch of `local-agent-mode-sessions/.../outputs/`. *T2: 001-research-20.*
- **Third-party host processes CANNOT register vsock listeners against Claude's Cowork VM.** — **Verified** (source search). Refines *001-research-7* and *001-research-17*. On Apple Virtualization framework, host-side vsock listeners are NOT plain BSD sockets — they are registered via `VZVirtioSocketDevice.setSocketListener(_:forPort:)`, an Apple framework API scoped to a specific `VZVirtualMachine` instance owned by the caller process. `coworkd` inside the Cowork VM reaches `CID=2:port=51234` only because Claude.app (the VM-creator) registered that listener on its own VM. A separate user-space process (nexus daemon, recording-rig bridge, any third party) CANNOT install a vsock listener on Claude's VM. Two independent walls block third-party VM→host: (1) Cowork's strict network allowlist (`api.anthropic.com`, `pypi.org`, `registry.npmjs.org` only — per nexus `docs/container-integration.md:184-189`), and (2) the per-VM Apple-framework listener registration. **RDR impact**: reinforces the bridge-as-MCPB choice — Claude.app dispatches the MCPB child process so the bridge naturally shares Claude.app's process tree and uses its own filesystem sentinels; a third-party vsock path was never structurally viable. Cross-references nexus T2 `cowork-vsock-third-party-host-listener-impossible-2026-05-23`, which validates nexus RDR-126's prior decision to use `--mcp-config "type": "sdk"` (Anthropic SDK bridge) rather than vsock. *T2: 001-research-21.*
- **MCP servers always run on the macOS host as stdio child processes of `Claude Helper (Plugin).app`, INVARIANT across all three surfaces.** — **Verified** (source search). The model's location varies (Anthropic cloud for Chat, macOS host for Code local-agent-mode, Cowork Linux VM for Cowork), but MCP server location is fixed: host process tree. `~/Library/Logs/Claude/mcp.log` shows host-side spawns like `Using MCP server command: /usr/local/bin/npx with args [-y, @modelcontextprotocol/server-filesystem, ...]` and `Using MCP server command: /Users/.../uv with args [run, --directory, Claude Extensions/local.mcpb.hal-hildebrand.palinex, src/server.py]` — plain host PATH binaries, no in-VM execution. Tool-call routing per surface: **Chat** = cloud model → SSE down → Claude.app → stdio to MCPB → result back up SSE. **Code** = host model → in-process dispatch on host → stdio to MCPB. **Cowork** = VM agent → Anthropic SDK channel → Claude.app on host → stdio to MCPB → result back through SDK (the `--mcp-config "type": "sdk"` model from nexus `docs/container-integration.md:201-209`). **RDR impact**: the bridge MCPB writes `/tmp/${SESSION}.*` on the host every time, regardless of surface. The surface-dependent question is NOT "where does the bridge run" but ONLY "does the model on this surface reach the bridge's tool list" — deterministic for Chat, A1-pending for Code, documented-unreliable for Cowork due to the `remoteMcpServersConfig` race (*001-research-14*). *T2: 001-research-22.*

### Critical Assumptions

Phase 0 spikes (2026-05-24) resolved these against the live app. **A4/A5/A10 are SUPERSEDED**: the original design's Playwright/CDP driver + `page.screencast` recording are non-viable (Claude.app blocks the Chromium remote-debugging transports Playwright requires), and are replaced by the validated **AXUIElement drive + ScreenCaptureKit record** stack (A11, A12). See §Revision History (2026-05-24 pivot).

- [x] **A1.** `.mcpb` extension tools are reachable from the Code surface model context. — **Status**: **Verified (P0.1, 2026-05-24).** Probe `.mcpb` (`recording-rig-probe`, tool `probe_distinctive_marker_42`) installed; a Code session invoked the tool and returned the marker verbatim. No DISABLED-WITH-ERROR. Code-surface coordination → `mcp-bridge`. T2 `recording-rig/RDR-001-phase0-probes` (P0.1).
- [ ] **A2.** `.mcpb` extension tools are reachable from the CoWork surface model context (proxied through vsock into the VM). — **Status**: Documented-Unreliable (round 2 — `001-research-14`); **P0.2 not yet run.** `anthropics/claude-code#20377` and `#26259` confirm intent + a race-condition bug in `remoteMcpServersConfig` initialization (closed inactive, no confirmed fix). — **Method**: Spike (P0.2) MUST repeat multiple times to characterize the intermittent-failure rate. CoWork pessimistic-case fallback (`coworkd-log-tail`) is CONFIRMED necessary regardless of pass rate.
- [x] **A3.** File-drop install (writing files to `Claude Extensions/` + editing `extensions-installations.json`) is honored on next Desktop launch, bypassing the Settings-UI install flow. — **Status**: **Verified (P0.3, 2026-05-24).** Pure file-drop (unpacked `.mcpb` into `Claude Extensions/<id>/` + `extensions-installations.json` per the `001-research-8` schema, hash = sha256 of bundle) loaded in a logged-in profile: Settings → Extensions showed the probe + its tool. Confirms the doctor recovery path (no Settings-UI dialog required). Methodology note: load-check requires a *logged-in* profile — a fresh `--user-data-dir` gates Settings behind the "Get started" onboarding screen. T2 `recording-rig/RDR-001-phase0-probes` (P0.3).
- [x] **A4. [SUPERSEDED → A11]** Playwright's `_electron.launch` works against Claude.app's Electron 41.6.1. — **Status**: **FAILED (P0.5, 2026-05-24).** Claude.app v1.8555.2 has a targeted anti-automation guard that calls `app.quit()` immediately on **either** Chromium remote-debugging transport (`--remote-debugging-port` any form OR `--remote-debugging-pipe`). Playwright drives Electron *exclusively* via the Chromium DevTools Protocol bootstrapped by one of those two flags — no third transport — so it cannot attach, version-independently. Controlled flag matrix: benign flags / `--user-data-dir` / `--remote-debugging-address` (no port) / Node `--inspect*` all leave the app running; both CDP transports kill it (graceful `app.quit()` ~64 ms post-AppKit, not a crash → deliberate). **Driver/record pivots to AXUIElement + ScreenCaptureKit (A11/A12).** T2 `recording-rig/claude-app-blocks-remote-debugging-flags-2026-05-24`, `recording-rig/RDR-001-phase0-probes` (P0.5).
- [x] **A5. [SUPERSEDED → A12]** ~~Claude.app uses a single BrowserWindow for the CoWork surface (no `BrowserView`/separate WebContents that Playwright `page.screencast` would miss).~~ — **Status**: **Moot.** ScreenCaptureKit captures the window's compositor output (all layers, incl. any `BrowserView`/GPU content) by `windowID`, so the "page.screencast misses sub-panels" concern no longer applies. P0.4 (WebContents count) is unnecessary under the SCK pivot.
- [x] **A6.** Surface-navigation, input, and send controls can be discovered and pinned to a Desktop version. — **Status**: **Verified (2026-05-24), reframed DOM → AX.** With a11y activated (`AXManualAccessibility`), Claude.app exposes named AX elements: `AXButton` desc="Chat"/"Code"/"Cowork", title="New session"; `AXTextArea` desc="Write your prompt to Claude" (composer). Selectors are AX role+description/title descriptors pinned in `bin/desktop-ax-selectors.json` (replacing the planned DOM `desktop-selectors.json`). T2 `recording-rig/claude-app-ax-driving-viable-2026-05-24`.
- [ ] **A7.** A long-idle Claude-Rig profile refreshes OAuth tokens on next launch without requiring a fresh interactive login. — **Status**: **In progress (P0.7 clock running, near-certain PASS).** Baseline: the primary session credential `sessionKey` has a ~28-day TTL (expires 2026-06-21), so a 48h idle is well within range. Methodology correction: there is **no `main.log`** (Claude logs are global under `~/Library/Logs/Claude/`, no `main.log`); the observable is whether a 48h-idle relaunch lands logged-in vs back at "Get started". Doctor staleness threshold should track the 28-day `sessionKey` TTL, not 48h. T2 `recording-rig/RDR-001-phase0-probes` (P0.7).
- [ ] **A8.** `open path/to/.mcpb` triggers Claude Desktop's install dialog reliably AND dismissal can be driven from the driver. — **Status**: Documented (round 2 — `001-research-11`); **P0.8 not yet run; dismissal mechanism reframed to AX.** `.mcpb` is registered `CFBundleTypeRole: Viewer`; `open ...mcpb` opens the install dialog (used successfully in P0.1/P0.3). — **Method**: Spike (P0.8) locates the dialog's install control via the AX tree (re-arm + wait-for-stable) and triggers it with `AXPress`, not Playwright DOM. Second remaining UI-driving exception, analogous to the CLI rig's `consent_sweep`.
- [x] **A9.** Cross-instance disambiguation for simultaneous Desktop instances. — **Status**: **Refined (2026-05-24).** Multi-instance *launch* COEXISTS — `open -n --user-data-dir=<other>` runs a second instance alongside the primary (single-instance lock is per-user-data-dir), so the prior "mutual exclusion is the only option" premise is REFUTED at the launch layer. BUT an OAuth *login* on a second instance collides: the `claude://` device-verification step routes onto the other instance's window (bundle-scoped deep-link handler) — observed live (a login hijacked the primary's window). **Implication**: steady-state recording (no OAuth, `sessionKey` valid) can run concurrently with the user's primary; the one-time Claude-Rig *login/seed* requires the primary quit. T2 `recording-rig/claude-app-multi-instance-per-userdatadir-2026-05-24`.
- [x] **A10. [SUPERSEDED → A12]** ~~`page.screencast.start/stop` works on Electron pages via `electronApp.firstWindow()`.~~ — **Status**: **Moot** (Playwright path dead). Recording is via ScreenCaptureKit (A12).
- [x] **A11. (new)** Claude.app's UI is drivable via the macOS Accessibility API. — **Status**: **Verified (2026-05-24).** Activate with `AXUIElementSetAttributeValue(app, "AXManualAccessibility", true)` from a long-lived process holding the connection → full web UI exposed (≈265–371 named nodes). Navigation: `AXPress` on named buttons (validated: Chat/Code/Cowork switching). Input + submit: set composer `AXValue` (element-scoped, safe) then post a **process-targeted** Return (`CGEvent…postToPid(rigPid)`, virtualKey 0x24) — validated end-to-end (test prompt sent, Claude's response read back via the AX tree). Window geometry via `kAXSizeAttribute` (validated). **Two driver invariants**: (1) a11y is non-persistent across UI re-renders — re-arm + poll-until-stable before each action from ONE long-lived process; (2) **NEVER global CGEvent** (`.post(tap:)` leaks to the focused app — observed) — use `postToPid` only. T2 `recording-rig/claude-app-ax-driving-viable-2026-05-24`, `recording-rig/claude-app-ax-input-submit-mechanism-2026-05-24`.
- [x] **A12. (new)** ScreenCaptureKit records the Claude-Rig window to a video file. — **Status**: **Verified (2026-05-24).** `SCShareableContent` → filter by `owningApplication.processID` → `SCContentFilter(desktopIndependentWindow:)` → `SCStream` → `AVAssetWriter` produced a valid h264 `.mov` (3 s → 94 frames @ 30 fps, ffprobe-confirmed). One-shot via `SCScreenshotManager` also works. Gotcha: a CLI tool must init `NSApplication.shared` (`.accessory`) or it crashes `CGS_REQUIRE_INIT`. Requires Screen Recording permission (doctor must check). T2 `recording-rig/claude-app-screencapturekit-recording-viable-2026-05-24`.

**Method definitions** (template-standard):

- **Source Search**: API verified against dependency source code or official documentation
- **Spike**: Behavior verified by running code against a live service (required for the eight above — Claude Desktop is opaque to source search)
- **Docs Only**: Insufficient for load-bearing assumptions

## Proposed Solution

### Approach

A second driver backend, additive to the CLI backend. Selection via a new top-level `backend: "cli" | "desktop"` field in the spec (default `"cli"`). The CLI backend stays byte-identical; existing CLI specs continue to record without modification.

The Desktop backend launches an isolated long-lived Claude.app profile (`~/Library/Application Support/Claude-Rig/`) via LaunchServices and drives it with a **Swift helper (`bin/desktop-driver`) over the macOS Accessibility API** (`AXUIElement`), recording via **ScreenCaptureKit** — the validated replacement for the original Playwright/CDP design, which is non-viable because Claude.app blocks the Chromium remote-debugging transports Playwright requires (A4, P0.5). A permanently installed `.mcpb` bridge (`recording-rig-bridge.mcpb`) acts as the sentinel emitter. The bridge exposes four tools the model is instructed to call at named beats: `rig.turn_end()`, `rig.checkpoint(name)`, `rig.ask(options) → answer_index`, `rig.emit(name, payload)`. Each call atomically writes a sentinel file under `/tmp/${SESSION}.*` using the SAME contract as the CLI rig (`.partial` + rename, no trailing newline, identifier regex `[A-Za-z0-9._-]+` from `lib/sentinels.sh:12` `rig_check_identifier`). Sentinel files inherit the invoker's umask; the bridge runs in Claude.app's process tree under the same user as the rig, matching CLI rig behavior. The `prompt-submitted` sentinel (analogue of the CLI's `UserPromptSubmit` hook) is **not** a bridge tool; the Swift driver writes it immediately after the `AXValue`-set + process-targeted-Return submit, because the driver knows when it submitted and no model action is needed. This preserves the existing sentinel-name semantics consumed by `commands/diagnose.md:12` and by companion-pane start signals.

Surface coordination is provider-polymorphic. A `CoordinationProvider` interface with implementations — `mcp-bridge` (strongest), `coworkd-log-tail` (CoWork fallback), `file-mtime-watch` (retained as a recovery option) — selected per-surface by doctor's cached probe results (`coordination: "auto"` in the spec). Post-P0.1 (A1 ✅): **Chat AND Code use `mcp-bridge`** — the `.mcpb` bridge is reachable from both. CoWork (A2 documented-unreliable, P0.2 pending) uses `coworkd-log-tail` as its fallback. Spec authors write the same spec either way; the provider is chosen at preflight.

### Technical Design

Architecture overview:

![RDR-001 Desktop backend architecture](RDR-001-architecture.svg)

The Desktop backend is additive to the CLI backend (`record.sh` dispatches on `backend`). `record.sh` (shell/Node) orchestrates — owning SESSION, spec, the `/tmp/${SESSION}.*` sentinel watch, and the `active-session` pointer — and launches Claude.app via LaunchServices (`open -n -a Claude --user-data-dir=<Claude-Rig>`), then invokes the Swift helper `bin/desktop-driver` for AX-drive + ScreenCaptureKit capture. The model invokes the permanent `recording-rig-bridge.mcpb`, which writes `/tmp/${SESSION}.*` sentinels (byte-identical contract to the CLI rig's hooks); the orchestrator waits on those plus the driver-written `prompt-submitted`. Coordination is provider-polymorphic: Chat + Code use `mcp-bridge` (A1 ✅), CoWork uses the `coworkd-log-tail` fallback (A2 pending). Post-recording, the ScreenCaptureKit `.mov` → ffmpeg → `.mp4`/`.gif` (new `bin/render-webm.sh`), and `bridge-transcript.jsonl` + `.mov` + spec → `validate.mjs`.

**Interfaces** (signatures; implementations deferred to phase plan):

```text
// CoordinationProvider (TypeScript-ish; implementation language TBD)
interface CoordinationProvider {
  ready(spec): Promise<void>            // pre-paste setup; throw on unmet prereqs
  waitTurnEnd(sessionId, opts): Promise<void>
  waitGate(sessionId, gateIdx, opts): Promise<void>
  teardown(sessionId): Promise<void>
}

// Bridge MCP tool surface
rig.turn_end()                          → { ok: true }
rig.checkpoint(name: string)            → { ok: true }
rig.ask(options: string[], prompt?: string) → { answer_index: int, answer_value: string }
rig.emit(name: string, payload?: object) → { ok: true }
```

Bridge tools are idempotent. Each writes `/tmp/${SESSION}.<suffix>` via the same atomic `.partial`+rename pattern used by `render-hooks.sh:31-44` (the CLI hook generator). Identifier `<name>` and `<suffix>` are validated against the SAME regex `[A-Za-z0-9._-]+` sourced from `lib/sentinels.sh:12` `rig_check_identifier`; the bridge inlines a port of this function as defense in depth, but preflight in `record.sh:104-107` continues to gate ahead of dispatch. Transcript log at `/tmp/${SESSION}.bridge-transcript.jsonl` (append-only, one JSON object per call: `{ ts, tool, args, result, session }`) is the validator's primary input.

Bridge session resolution: bridge reads `/tmp/recording-rig.active-session` (a single-line file containing the active SESSION id) on every tool call. The driver writes this file immediately before launching Claude.app and unlinks it at teardown. If absent, the bridge logs the call to `/tmp/recording-rig.orphan-calls.jsonl` and returns `{ ok: false, reason: "no active session" }` to the model — fails loud, lets the model retry on the next turn.

Driver: a compiled Swift helper `bin/desktop-driver` (Swift chosen because AXUIElement and ScreenCaptureKit are Cocoa APIs and pyobjc is not available; `swiftc` is present). `record.sh` (shell/Node) remains the orchestrator — it owns SESSION resolution, spec parsing, the `/tmp/${SESSION}.*` sentinel watch, and the `active-session` pointer — and invokes the Swift helper for the AX-drive + capture work. All mechanisms below are validated against the live app (Phase 0, 2026-05-24; T2 `claude-app-ax-driving-viable`, `-ax-input-submit-mechanism`, `-screencapturekit-recording-viable`).

**Launch** (LaunchServices, NOT direct exec — direct exec of the binary exits immediately; `open` works):

```text
open -n -a Claude --args \
  --user-data-dir="$HOME/Library/Application Support/Claude-Rig" \
  --force-renderer-accessibility        # survives the guard; harmless. NEVER pass --remote-debugging-* (guard quits the app)
```

**Attach AX + drive** (Swift `bin/desktop-driver`, holding one long-lived AX connection):

```text
let app = AXUIElementCreateApplication(rigPid)            // rigPid: main Claude-Rig process
AXUIElementSetAttributeValue(app, "AXManualAccessibility", true)   // flips Chromium's NSAccessibility bridge

// INVARIANT 1: a11y is non-persistent across UI re-renders. Re-arm + poll
// until the target element re-appears before EVERY action (wait-for-stable).
func armWait(role, desc) -> AXUIElement   // re-set AXManualAccessibility; walk; retry

// Navigation: AXPress on named buttons (validated: Chat/Code/Cowork)
AXUIElementPerformAction(armWait("AXButton", surfaceDesc), kAXPressAction)

// Window geometry (deterministic recording size): set + re-assert
AXUIElementSetAttributeValue(win, kAXSizeAttribute, 1280x800)   // verify; re-assert if reverted

// Input + submit (the validated recipe):
let composer = armWait("AXTextArea", "Write your prompt to Claude")  // surface-specific desc
AXUIElementSetAttributeValue(composer, kAXValueAttribute, agentCommand)  // element-scoped, safe
//   INVARIANT 2: NEVER global CGEvent (.post(tap:) leaks to the focused app — observed).
CGEvent(virtualKey: 0x24 /*Return*/, keyDown: true).postToPid(rigPid)   // process-targeted
CGEvent(virtualKey: 0x24, keyDown: false).postToPid(rigPid)
// driver then atomically writes /tmp/${SESSION}.prompt-submitted (.partial+rename)
```

Notes: `AXValue`-set alone is inert for submit (doesn't fire the framework input event, so the Send button never enables) — the process-targeted Return is what submits. `kAXConfirmAction` on the composer is a no-op. Target the composer by surface-specific `AXDescription` (Chat="Write your prompt to Claude"; the home/launcher composer "Describe a task or ask a question" is a different element whose `AXValue`-set is inert).

**Install-dialog dismissal** (A8): `open path/to/.mcpb` opens the install dialog; the driver locates its install control in the AX tree (`armWait` + `AXPress`). No Playwright DOM, no AppleScript.

**Recording** (ScreenCaptureKit → h264 `.mov`): `SCShareableContent` → filter windows by `owningApplication.processID == rigPid` → `SCContentFilter(desktopIndependentWindow:)` → `SCStream` + `AVAssetWriter` (start the writer session on the first frame's PTS) before first paste; stop + `finishWriting()` after `agent-done` + `exit_hold_sec`. One-shot final-frame thumbnail via `SCScreenshotManager`. The Swift helper must init `NSApplication.shared` (`.accessory`) at startup or CG/SCK calls crash `CGS_REQUIRE_INIT`. Captures the window's compositor output by `windowID` (all layers, incl. any `BrowserView`/GPU content) — supersedes the page.screencast/BrowserView concern (former A5).

**Sentinel watch** is unchanged from the CLI design and stays in `record.sh`/shell: poll `turn-end` mtime, idle when stable for `idle_seconds`; same `turn_timeout_sec` / `session_max_sec` ceilings; `sentinel_clear_all()` (`lib/sentinels.sh:41`) before pre-paste, `sentinel_wait_idle()` (`lib/sentinels.sh:78`) for the idle wait. Per-command flow mirrors `bin/driver.sh`. The bridge writes `turn-end`/`checkpoint`/`gate-pending`; the Swift helper writes `prompt-submitted`.

**Teardown**: stop the SCStream + `AVAssetWriter.finishWriting()` (flushes the `.mov`), quit the Claude-Rig instance (graceful), unlink `/tmp/recording-rig.active-session`.

#### Existing Infrastructure Audit

| Proposed Component | Existing Module | Decision |
| --- | --- | --- |
| Backend dispatch in `record.sh` | `bin/record.sh` (CLI-only today) | **Extend**: insert `case "$BACKEND" in cli) … ;; desktop) launch Claude-Rig + exec bin/desktop-driver "$SPEC" ;;` after shared preflight + sentinel_clear_all, before tmux/asciinema. Shared steps (SESSION resolution, sentinel_clear_all, preflight identifier regex) run before fork. |
| `bin/desktop-driver` | none — new file | **Create**: compiled **Swift** helper (AXUIElement drive + ScreenCaptureKit capture). `swiftc` present; pyobjc absent. |
| `bin/render-webm.sh` | `bin/render-hooks.sh` (different role) | **Create**: invokes ffmpeg + gifski for `.mov → .mp4 + .gif`. |
| `bin/desktop-ax-selectors.json` | none — new file | **Create**: per-Desktop-version **AX selector** cache (role + AXDescription/AXTitle), populated when AX selectors are pinned. |
| `recording-rig-bridge.mcpb` | none — new artifact | **Create**: standalone MCPB bundle, built in this repo and published to releases. |
| Sentinel write contract | `bin/render-hooks.sh:31-44` (atomic .partial+rename) | **Reuse**: bridge implements the same pattern in Node. |
| Identifier regex | `lib/sentinels.sh:12` `rig_check_identifier` `[A-Za-z0-9._-]+` | **Reuse**: bridge inlines the same regex; preflight in `record.sh:104-107` continues to gate. |
| `sentinel_clear_all` | `lib/sentinels.sh:41` | **Reuse via shell**: orchestrator calls before driver dispatch; driver does not re-clear. |
| `sentinel_wait_idle` | `lib/sentinels.sh:78` | **Reuse via shell**: the idle wait stays in `record.sh`/shell (orchestrator), not the Swift helper. |
| `bin/validate.mjs` | `bin/validate.mjs` (asciinema-cast parser) | **Extend**: branch on `spec.backend`; for `desktop`, read `bridge-transcript.jsonl` as primary input + `.mov` metadata as sanity. |
| Plugin commands | `commands/{record,author-spec,doctor,diagnose}.md` | **Extend** all four to be backend-aware (`record` dispatches on `backend`; `doctor` adds Desktop checks; `author` adds Desktop fields; `diagnose` learns `.mov`/transcript forensics). |
| `lib/sentinels.sh` | as-is | **No change**: primitives are bash-shell only; JS port lives in driver. |

### Decision Rationale

The architecture is shaped by three load-bearing decisions, each chosen to preserve the CLI rig's invariants:

1. **MCP-tool-call as sentinel** is the strongest mechanism available to Desktop without TUI scraping. It is structurally weaker than CLI lifecycle hooks (model must choose to call), but provides a deterministic-once-called contract that DOM polling and network interception do not.
2. **Single unified spec dialect** keeps users in one mental model. The `backend` discriminator routes to the right driver without spec-format proliferation. Existing CLI specs stay byte-identical.
3. **Provider-polymorphic coordination** handles the unresolved `.mcpb`-in-Code/CoWork uncertainty without forcing a premature commitment. The optimistic case is simpler; the pessimistic case degrades gracefully with documented behavior differences (no `rig.ask` on Code/CoWork in the pessimistic case; checkpoint assertions weaken to substring matches).

Eight further decisions (bridge install lifecycle, user-data-dir strategy, recording capture, validation strategy, spec dialect specifics, plugin integration, cross-platform scope, determinism gap acknowledgment) are documented under [Alternatives Considered](#alternatives-considered) below.

## Alternatives Considered

### Alternative 1: Per-recording `.mcpb` install/uninstall

**Description**: Install `recording-rig-bridge.mcpb` per recording session, uninstall after. Each spec brings its own bridge configuration baked into the install.

**Pros**:

- Per-recording config isolation
- No persistent state in user's Desktop profile

**Cons**:

- No documented ephemeral install path — would require writing `extensions-installations.json` + dropping files directly
- Risk of integrity-hash check breaking on a future Desktop update
- 5-15s Desktop restart per recording

**Reason for rejection**: Chose hybrid approach (§Technical Design): permanent dispatcher + per-session `rig-config.json` side-channel the bridge reads on every tool call. Settles configuration concerns without the per-recording restart cost.

### Alternative 2: Optimistic-only — assume `.mcpb` reaches all three surfaces

**Description**: Design only for the case where `.mcpb` bridge tools are available in Chat, Code, AND CoWork. Defer the fallback design until probes A1/A2 prove otherwise.

**Pros**:

- Simpler initial architecture
- Lower phase-1 surface area

**Cons**:

- If A1 or A2 fail, the architecture wedges — significant rework to add fallback providers retroactively
- The probe results are not available until Phase 0 begins; designing the data flow before knowing the answer freezes a specific dataflow shape that may not survive the probe outcome

**Reason for rejection**: Provider-polymorphic from the start. The `CoordinationProvider` interface is one extra abstraction; the fallback implementations are gated behind probe results but the interface lands in phase 2. Pays one-time abstraction cost; avoids wedge risk.

### Alternative 3: DOM polling as the fallback for Code/CoWork

**Description**: When `.mcpb` is unavailable on a surface, fall back to polling the rendered DOM for turn-end indicators (text patterns, ARIA state, animation classes).

**Pros**:

- Works in any surface that renders content visibly
- No host-side log/file dependencies

**Cons**:

- Same failure class as TUI scraping (animation frames, React re-renders, canvas content invisible to queries, runtime-reconfigurable participle dictionary)
- CLI rig's `../design.md` ruled this out for the CLI; the same logic applies here

**Reason for rejection**: File-mtime-watch and log-tail are structurally stronger than DOM polling (host-side, no rendering-layer dependency). Chose those; DOM polling is not on the menu.

### Alternative 4: Network interception of `api.anthropic.com` SSE streams

**Description**: Intercept `api.anthropic.com` SSE responses on the Chat surface and detect `message_stop` events as turn-end.

**Pros**:

- Works for Chat without any model instruction
- Catches the cleanest possible signal (actual stream-end event)

**Cons**:

- Works only in Chat — Code routes through a separate local-agent-mode process; CoWork routes through a vsock-mediated VM. Not uniform across surfaces.
- Requires an in-app network-interception transport (CDP `page.route` etc.) — **structurally unavailable** now that Claude.app blocks the Chromium remote-debugging transports (A4/P0.5). No supported network-interception hook remains.

**Reason for rejection**: Not uniform, and the only viable interception transport (CDP) is blocked by the app guard. The `.mcpb` bridge's `rig.turn_end` is the uniform, transport-independent turn-end signal instead.

### Alternative 5: Fresh user-data-dir + auth seeding per recording

**Description**: Each recording creates a fresh `--user-data-dir`, copies auth state (Cookies, Local Storage, IndexedDB) from the user's primary, runs the recording, discards the dir.

**Pros**:

- Pristine state per recording
- No profile rot

**Cons**:

- First-run seeding per recording forces a quit-primary step every time (OAuth deep-link collision risk on simultaneous instances)
- Copy is non-trivial (multiple paths, Keychain shared by app identity anyway)
- Slow setup per recording

**Reason for rejection**: Chose long-lived dedicated `Claude-Rig` profile (set up once via `doctor --install-profile`, refreshed by Desktop's own 60s OAuth loop). Pays setup cost once; recordings reuse the warm profile.

### Alternative 6: Parallel spec dialects (`cli-spec.json` vs `desktop-spec.json`)

**Description**: Two separate spec formats, one per backend. Loader chooses by file extension or schema-detection.

**Pros**:

- Each format optimized for its backend
- No shared-field-with-different-semantics surprise

**Cons**:

- File proliferation
- Two loader code paths
- Authoring skill (`author-spec`) needs two branches

**Reason for rejection**: Chose single unified spec with `backend` discriminator. Repurposed semantics for `agent.command(s)`, `hooks.capture_tools[]`, `gates[]` are documented in §Technical Design. Trades a small mental-model load (same field, different backend behavior) for spec-format unity.

### Alternative 7: ScreenCaptureKit primary capture — **ADOPTED (2026-05-24 revision)**

**Description**: Use macOS ScreenCaptureKit as the primary capture mechanism. (Originally framed as an alternative to Playwright's `page.screencast`.)

**Pros**:

- Captures the window's compositor output by `windowID` — everything visible, including any `BrowserView`/GPU sub-panels
- Higher fidelity for canvas/GPU content
- Independent of any in-app automation transport — unaffected by Claude.app's CDP guard

**Cons**:

- macOS-only (the backend is macOS-first anyway; AX drive is also macOS-only, so no new platform constraint)
- `.mov` output → one ffmpeg transcode step (`bin/render-webm.sh`)

**Status**: **Adopted as the primary (and only) capture path.** When P0.5 killed the Playwright/CDP driver, `page.screencast` died with it, and the BrowserView-coverage concern (former A5) became moot — SCK captures the whole window regardless. Validated in Phase 0 (A12): h264 `.mov`, 94 frames / 3 s. No "only when necessary" gating remains — SCK is the recording mechanism.

### Alternative 8: Separate `/recording-rig:desktop` command surface

**Description**: New top-level commands for the Desktop backend (`/recording-rig:desktop-record`, etc.) instead of routing the existing commands through the spec's `backend` field.

**Pros**:

- No backend-aware logic in commands

**Cons**:

- Forces users to know which backend they're using before selecting a command
- Duplicates the command tree

**Reason for rejection**: Chose backend-aware unified commands. Spec selects backend; commands route. User picks "record this spec" without thinking about backend taxonomy.

### Briefly Rejected

- **Headless Desktop recording**: the recording IS the headed render, and AX-driving + ScreenCaptureKit both require an on-screen window. No headless mode to ship.
- **Cross-machine profile portability**: Electron safe-storage is hardware-bound; copying a profile to another machine fails to decrypt encrypted blobs.
- **Linux Claude Desktop support**: Claude Desktop does not ship on Linux.
- **Video frame OCR as primary validation**: Tesseract per keyframe is expensive, adds a Python dependency, unreliable on small/anti-aliased text. Worst signal-to-noise.
- **DOM-only validation**: Code/CoWork have unstable selectors and CoWork output is rendered via vsock-bridge; DOM assertions don't generalize across surfaces.

## Trade-offs

### Consequences

- **Positive**: Single unified spec dialect across CLI and Desktop. Existing CLI specs continue to record without modification. Plugin commands work uniformly.
- **Positive**: Provider-polymorphic coordination decouples the architecture from the unresolved `.mcpb`-in-Code/CoWork question. Architecture survives either probe outcome.
- **Positive**: Long-lived `Claude-Rig` profile pays setup cost once; OAuth refresh is automatic.
- **Positive**: Bridge sentinel contract is byte-identical to CLI hooks; `diagnose` taxonomy carries over.
- **Negative**: This backend is structurally less deterministic than the CLI backend. Model must choose to call `rig.turn_end` and `rig.checkpoint`; instruction drift is a real failure mode mitigated by, but not eliminated by, the system-prompt prologue.
- **Negative**: CoWork remains a fallback surface (A2 documented-unreliable, P0.2 pending) using `coworkd-log-tail`, where `gates[]` are not supported and checkpoint assertions degrade to substring matches. Chat and Code both use `mcp-bridge` (A1 ✅), so the original "Code might fall back" worry is resolved. Documented in the spec preflight.
- **Negative**: The Desktop driver depends on macOS Accessibility behavior that is fragile by nature: a11y must be re-armed across UI re-renders, and synthetic input must be process-targeted. Both are validated (A11) but are version-sensitive to Claude.app/Electron updates.
- **Negative**: CoWork in the pessimistic case is bounded by an unresolved race-condition bug in Claude's own `remoteMcpServersConfig` initialization (`anthropics/claude-code#26259`, closed inactive without confirmed fix — round-2 finding `001-research-14`). Bridge tool calls from CoWork are intermittently dropped silently; the fallback `coworkd-log-tail` provider gives a coarser signal that is NOT improvable by prologue discipline. Re-take rate on CoWork may therefore be non-zero and non-improvable from the rig's side until Anthropic fixes the forwarding bug. Distinct from Chat/Code "weaker-but-improvable-via-prologue" — this is a structurally bounded ceiling. Spec preflight should surface a CoWork-specific advisory.
- **Negative**: Bridge installation is permanent in the Claude-Rig profile (no ephemeral install). One bridge per profile.
- **Negative**: New post-processing pipeline (`bin/render-webm.sh` for ffmpeg + gifski) — not as battle-tested as the CLI rig's `agg` pipeline.

### Risks and Mitigations

- **Risk**: A1 AND A2 both fail (`.mcpb` blocked in Code AND CoWork). Bridge useful only for Chat.
  **Mitigation**: Architecture already designs the pessimistic-case fallback (provider-polymorphic coordination, §Technical Design). Code and CoWork degrade to weaker coordination but remain usable. RDR documents the asymmetry; spec preflight rejects gated specs targeting fallback-provider surfaces.

- **Risk**: Model skips `rig.turn_end` due to instruction drift. Soft miss accumulates.
  **Mitigation**: System-prompt prologue is part of every Desktop spec template (`examples/desktop-*.json`). Fallback timer synthesizes turn-end with a soft-miss log entry if `pacing.turn_timeout_sec` elapses without the call. Soft-miss rate over last N recordings tracked in `~/Library/Application Support/recording-rig/quality.jsonl`; >20% triggers a doctor warning.

- **Risk**: Claude Desktop UI churn breaks AX selectors. Surface navigation / composer targeting fails after a Desktop update (the AX role+description of a button or the composer changes).
  **Mitigation**: AX selectors centralized in `bin/desktop-ax-selectors.json`, version-pinned to the Desktop version observed at probe time. Doctor warns when running against a Desktop version newer than the cached probe. `--probe-surfaces` re-runs AX selector discovery. The `armWait` (re-arm + wait-for-stable) helper fails loud with the missing role/description when an element can't be found.

- **Risk**: OAuth token expiry on idle Claude-Rig profile. First recording after long idle fails to launch authenticated.
  **Mitigation**: Doctor pre-record check warns "profile auth refreshed N days ago — consider launching Claude-Rig manually before recording." Recovery: user launches profile, lets refresh run, retries.

- **Risk**: a11y tree collapse mid-recording. Chromium drops the NSAccessibility bridge across UI re-renders / when the activating client goes idle, so a stale AX element reference fails after a navigation.
  **Mitigation** (validated, A11): the Swift driver is ONE long-lived process holding the AX connection; it re-arms `AXManualAccessibility` and polls-until-stable (`armWait`) before every action rather than caching element handles. Fail loud on timeout.

- **Risk**: synthetic input leaks to the wrong window. Global `CGEvent.post(tap:)` delivers to whatever app is system-frontmost — during validation it leaked a test prompt into the operator's terminal.
  **Mitigation** (validated, A11): the driver NEVER uses global CGEvent. Input is element-scoped `AXValue`-set for text plus a **process-targeted** `CGEvent…postToPid(rigPid)` for the submit Return. Doctor documents this invariant; code review enforces it.

- **Risk**: missing macOS permissions. AX driving needs Accessibility permission; ScreenCaptureKit needs Screen Recording permission — without them the driver silently gets an empty tree / black frames.
  **Mitigation**: `doctor` checks `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()` for the controlling process and prints the exact System Settings → Privacy panes to grant before recording.

- **Risk**: window geometry drift. The Claude-Rig window can revert to an unexpected size, producing inconsistent recording dimensions.
  **Mitigation**: the driver sets `kAXSizeAttribute` to a deterministic size, reads it back, and re-asserts if it reverted, before starting capture.

- **Risk**: MCPB transport changes in a future Claude Desktop release silently break the bridge. MCPB v0.4 MANIFEST.md does NOT mandate stdio — Claude Desktop chooses stdio as an implementation detail (round-2 finding `001-research-18`), and could theoretically change without a manifest version bump.
  **Mitigation**: Bridge README + §Cross-Cutting Concerns / Versioning document the stdio assumption explicitly. `doctor --verify-bridge` includes a connectivity probe (call a bridge tool, assert response shape) that catches transport-format changes as a fast doctor failure rather than a silent recording miss.

- **Risk**: Bridge config file race. Two simultaneous recordings clobber `/tmp/recording-rig.active-session`.
  **Mitigation**: Driver refuses to launch if `active-session` exists; mirrors the CLI rig's `tmux has-session` check at `bin/record.sh:208-212`.

- **Risk**: Auth deep-link collision during the one-time Claude-Rig login/seed. Confirmed live (A9, 2026-05-24): with two instances running, an OAuth login on the second instance routes its `claude://` device-verification step onto the *other* instance's window (bundle-scoped deep-link handler) — observed hijacking the primary's window. Note the nuance: multi-instance *launch* coexists fine (per-`--user-data-dir` single-instance lock); only the OAuth-login flow collides.
  **Mitigation**: `doctor --install-profile` / `--seed-from-primary` (the steps that perform an OAuth login) refuse to run if any non-Rig Claude.app is running (`pgrep -f "Claude.app/Contents/MacOS/Claude"`); user quits the primary, logs in once, resumes. **Steady-state recording does NOT require exclusion** — once the Claude-Rig `sessionKey` is valid (~28-day TTL, A7), recording triggers no OAuth, so it can run concurrently with the user's primary.

- **Risk**: `extensions-installations.json` schema change invalidates the bridge install path.
  **Mitigation**: Bridge install uses the supported `open path/to/.mcpb` → Settings-UI install path (one of two surviving TUI-scrape exceptions, justified analogously to the CLI rig's `consent_sweep`). Direct manifest editing is the recovery path, not the primary.

### Failure Modes

- **Visible failure**: A required checkpoint missing in the bridge transcript → validator FAILS → no GIF rendered. Validator names the missing checkpoint.
- **Silent failure (mitigated)**: Model skips `rig.turn_end` but produces text output. Fallback timer synthesizes turn-end; recording completes; soft-miss logged for trend analysis.
- **Recovery**: Soft-miss aggregation surfaces drift in `diagnose`. Operator action: strengthen prologue, re-record. If soft-miss persists across prologue revisions, the Desktop backend's determinism floor for that surface/Desktop-version combo is established as the practical limit.
- **Diagnose path**: `/recording-rig:diagnose <session>` reads the bridge transcript, the `.mov` metadata, and the sentinel timeline; surfaces (a) which expected checkpoints were called and which were missed, (b) soft-miss rate trend, (c) `.mov`-duration vs session-wall-time delta (capture-coverage check), (d) the bridge per-server log (`~/Library/Logs/Claude/mcp-server-<display_name>.log`) as a liveness signal — if the bridge log goes quiet during an active session the bridge may have crashed. HAR/Playwright-trace forensics are dropped (no CDP transport under the AX pivot).

## Implementation Plan

### Prerequisites

- [ ] All Critical Assumptions A1–A10 resolved before implementation. A1, A3, A5, A6, A7, A8 verified via Phase 0 spikes. A2 partly resolved by round-2 finding `001-research-14` (Documented-Unreliable; spike P0.2 still required to characterize intermittent-failure rate). A4 partly resolved by round-2 finding `001-research-13` (Documented; spike P0.5 reduced to launch verification). A9 verified-by-inference (round-2 findings `001-research-10/16/17` — no spike needed; the mutual-exclusion guard at the rig level is the enforcement). A10 gated to Phase 2 Step 1 verification (requires driver to exist).
- [ ] Probe results archived to T2 memory (project `recording-rig`, title `RDR-001-phase0-probes`)
- [ ] Decisions §Technical Design §11 (per-surface coordination) and §Alternative 7 (capture pipeline) locked based on probe outcomes
- [ ] `docs/design.md` updated with a new Desktop section that mirrors the determinism-gap acknowledgment in this RDR

### Minimum Viable Validation

End-to-end recording of a Chat-surface session with a minimal `desktop` spec produces all expected artifacts: `.mov` (ScreenCaptureKit/h264 capture), `.gif` + `.mp4` (ffmpeg + gifski post-process), `bridge-transcript.jsonl` (with at least one `rig.turn_end` call), and `validate.mjs` PASS verdict. Required-checkpoint omission on a re-run reproduces a deliberate FAIL with no GIF rendered. This is the single proof that the AX-drive → bridge → sentinels → validator → render pipeline composes end-to-end. **In scope for Phase 2 — not deferred.**

### Phase 0: Probes (no code shipped)

**Largely executed 2026-05-24** (results in T2 `recording-rig/RDR-001-phase0-probes` + the per-topic findings; scratch tag `recording-rig-desktop-phase0-results`). The probes resolved the architecture pivot — see §Revision History. Status:

- **P0.1 — `.mcpb` reachable in Code (A1): PASS.** Probe `.mcpb` `recording-rig-probe` (tool `probe_distinctive_marker_42`) invoked from a Code session, returned the marker. → Code uses `mcp-bridge`.
- **P0.2 — `.mcpb` reachable in CoWork (A2): PENDING.** Documented-unreliable (`001-research-14` race); when run, MUST repeat ≥10× to characterize the intermittent-failure rate. CoWork fallback (`coworkd-log-tail`) is needed regardless.
- **P0.3 — File-drop install (A3): PASS.** Unpacked `.mcpb` + `extensions-installations.json` (per `001-research-8` schema) loaded in a logged-in profile. Doctor recovery path confirmed.
- **P0.4 — WebContents count: MOOT.** Was about whether `page.screencast` misses sub-panels; ScreenCaptureKit captures the whole window's compositor output by `windowID`, so the question no longer matters.
- **P0.5 — driver launch (A4): FAIL → pivot.** Claude.app blocks the Chromium remote-debugging transports Playwright requires (anti-automation guard). Replaced by AX drive (A11) + ScreenCaptureKit (A12), both validated this phase.
- **P0.6 — selector discovery: DONE, reframed DOM→AX (A6).** AX tree exposes named elements (composer, Chat/Code/Cowork buttons); pin to `bin/desktop-ax-selectors.json`.
- **P0.7 — long-idle OAuth refresh (A7): IN PROGRESS.** Clock running; near-certain PASS (28-day `sessionKey` TTL ≫ 48h). No `main.log` exists — observable is logged-in-vs-onboarding on relaunch.
- **P0.8 — install-dialog dismissal (A8): PENDING, reframed to AX.** `open ...mcpb` opens the dialog (used in P0.1/P0.3); dismissal via AX (`armWait` + `AXPress`), not Playwright DOM.

**Phase 0 gate**: probe report → T2 (done). The pivot is locked: §Technical Design and §Alternative 7 (ScreenCaptureKit adopted) reflect the AX + SCK stack. Remaining open probes (P0.2, P0.7) are non-blocking for the Phase 1/2 bridge + driver work.

### Phase 1: Bridge MCPB

#### Step 1: Bridge skeleton

`recording-rig-bridge.mcpb` source tree under `bridge/` in this repo. Manifest v0.4 with `server.type: "node"`. Tools per §Technical Design: `rig.turn_end`, `rig.checkpoint`, `rig.ask`, `rig.emit`. ID `local.mcpb.hellblazer.recording-rig-bridge`.

#### Step 2: Sentinel write + transcript log

Implement the atomic `.partial`+rename pattern (port of `render-hooks.sh:31-44`). Identifier validation against `[A-Za-z0-9._-]+` (port of `lib/sentinels.sh:12` `rig_check_identifier`). Append-only JSONL transcript at `/tmp/${SESSION}.bridge-transcript.jsonl`.

#### Step 3: Session resolution

Read `/tmp/recording-rig.active-session` on every tool call. Fail loud on missing pointer (log to orphan file, return `{ ok: false, reason: "no active session" }`).

#### Step 4: Build + install

Package as `.mcpb`. Install into the Claude-Rig profile manually for phase 1; install automation lands in phase 5.

**Phase 1 gate**: All four bridge tools callable from Chat in the Claude-Rig profile. Sentinels appear at expected paths with expected payloads. Transcript file written. `rig.ask` returns spec-dictated answer for a single-gate spec.

### Phase 2: Driver + capture pipeline (Chat-only)

#### Step 1: `bin/desktop-driver` (Swift)

Compiled Swift helper (AXUIElement + ScreenCaptureKit are Cocoa APIs; `swiftc` present, pyobjc absent). All primitives validated in Phase 0 (A11/A12). At startup: `NSApplication.shared.setActivationPolicy(.accessory)` (else CG/SCK calls crash `CGS_REQUIRE_INIT`). `record.sh` launches the app via LaunchServices (`open -n -a Claude --user-data-dir=<Claude-Rig> --force-renderer-accessibility`) and passes the resolved Claude-Rig PID to the helper. The helper:
- **Attaches AX**: `AXUIElementSetAttributeValue(app, "AXManualAccessibility", true)` from this long-lived process (holds the connection). **Invariant 1**: re-arm + poll-until-element-present (`armWait`) before EVERY action — a11y collapses across UI re-renders.
- **Window geometry**: set `kAXSizeAttribute` to a deterministic size (e.g. 1280×800); verify + re-assert (it can revert).
- **Navigate**: `AXPress` the named surface button (`AXButton` desc="Chat") — selectors in `bin/desktop-ax-selectors.json`.
- **Input + submit**: set composer `AXValue` (target by surface-specific `AXDescription`, e.g. "Write your prompt to Claude"); then **Invariant 2** — post a *process-targeted* Return (`CGEvent(virtualKey: 0x24).postToPid(rigPid)`), NEVER a global `CGEvent.post(tap:)` (it leaks to the focused app). Then atomically write `/tmp/${SESSION}.prompt-submitted`.
- **Record**: ScreenCaptureKit — `SCShareableContent` filtered by `owningApplication.processID` → `SCContentFilter(desktopIndependentWindow:)` → `SCStream` + `AVAssetWriter` (h264 `.mov`); start the writer session on the first frame's PTS, before first paste; stop + `finishWriting()` before teardown. One-shot final-frame thumbnail via `SCScreenshotManager`.
- **Install-dialog flow (P0.8)**: `open path/to/.mcpb` → locate the dialog's install control in the AX tree (`armWait` + `AXPress`). No Playwright DOM.

Sentinel watch stays in `record.sh`/shell (ported `sentinel_wait_idle()`); the bridge writes `turn-end`/`checkpoint`/`gate-pending`, the helper writes `prompt-submitted`. Teardown: stop SCStream + `finishWriting()` (flushes `.mov`), quit the Claude-Rig instance, unlink `active-session`. Requires Accessibility + Screen Recording permission for the controlling process (doctor checks both).

#### Step 2: `bin/render-webm.sh`

ffmpeg + gifski pipeline: `.mov (h264) → .mp4 + .gif`. Gated behind validation pass (mirrors CLI rig's gate against `agg`).

#### Step 3: Backend dispatch in `record.sh`

Insert `case "$BACKEND" in cli) ... ;; desktop) launch Claude-Rig + exec bin/desktop-driver "$SPEC" ;; esac` after shared preflight (identifier regex validation, sentinel_clear_all, SESSION resolution) and before tmux/asciinema setup. Shared steps run for both backends. `record.sh` owns the launch (`open -n`), the `active-session`/`rig-config` writes, and the sentinel watch; the Swift helper owns AX-drive + capture.

#### Step 4: Chat-surface examples

`examples/desktop-chat.json` — minimal Chat-only spec with one command, one checkpoint, basic validation.

**Phase 2 gate**: end-to-end record of `examples/desktop-chat.json` produces `.mov`, `.gif`, `.mp4`, bridge transcript, validator PASS. A deliberately broken spec (missing required checkpoint) produces validator FAIL and no GIF.

### Phase 3: Validation extensions + diagnose integration

#### Step 1: Validator backend awareness

`bin/validate.mjs` branches on `spec.backend`. For `desktop`: read `bridge-transcript.jsonl` as primary input. `must_contain` / `must_contain_in_order` / `must_not_contain` apply against transcript text. Assert all `required: true` checkpoints appeared in spec-declared order. Assert last call is `rig.turn_end`.

#### Step 2: Soft-miss aggregation

`~/Library/Application Support/recording-rig/quality.jsonl` append on each run. Doctor warns if >20% over last N runs.

#### Step 3: Diagnose webm/transcript/trace forensics

Extend `commands/diagnose.md` skill: read bridge transcript, `.mov` metadata, sentinel timeline (always). Surface missing-checkpoint reports, soft-miss trends, capture-coverage check (`.mov` duration vs session wall-time), and the bridge per-server log (`~/Library/Logs/Claude/mcp-server-<display_name>.log`) as a liveness signal. No HAR/Playwright-trace forensics (no CDP transport under the AX pivot).

**Phase 3 gate**: required-checkpoint failure produces no GIF; soft-miss only produces GIF + warning; diagnose surfaces both with usable forensic output.

### Phase 4: Code + CoWork surfaces (with chosen coordination providers)

#### Step 1: Surface support

Add `bin/desktop-ax-selectors.json` entries (AX role + AXDescription/AXTitle) for Code and CoWork surface composers, sidebar nav, send. Driver navigates per `desktop.surface` via `AXPress` + `armWait`.

#### Step 2: Coordination provider implementations

Implement the provider(s) locked by Phase 0 gate:

- Optimistic case: nothing new — `mcp-bridge` provider already exists from Phase 2.
- Pessimistic case: implement `file-mtime-watch` (Code: watch `local-agent-mode-sessions/<acct>/<org>/local_<sess>/` mtime) and/or `coworkd-log-tail` (CoWork: structured parse of `coworkd.log` for session events) behind the same `CoordinationProvider` interface.

#### Step 3: Code-surface trusted folder pre-seeding

`doctor` and driver pre-configure `localAgentModeTrustedFolders` from `desktop.trusted_folders` before launch.

#### Step 4: Pessimistic-case spec preflight

Reject specs that use `gates[]` or `desktop.checkpoints[].required: true` on surfaces whose coordination provider is a fallback (no `rig.ask`, no transcript-asserted checkpoints in fallback mode).

#### Step 5: Code + CoWork examples

`examples/desktop-code.json`, `examples/desktop-cowork.json`.

**Phase 4 gate**: all three surfaces record end-to-end with their declared coordination providers. Fallback-provider specs gracefully reject incompatible features.

### Phase 5: Plugin integration + docs

#### Step 1: `/recording-rig:doctor` extensions

Add subcommands: `--install-bridge` (build + install bridge MCPB), `--install-profile` (create Claude-Rig dir, interactive login wait — refuses if a non-Rig Claude.app is running, per the A9 OAuth-collision risk), `--seed-from-primary` (auth-state copy), `--probe-surfaces` (per-surface MCP probe + AX selector discovery). Standard checks add Desktop-mode validations: `swiftc` present (build the driver), Claude.app present, **Accessibility permission** (`AXIsProcessTrusted()`) and **Screen Recording permission** (`CGPreflightScreenCaptureAccess()`) granted, profile exists, bridge installed, AX-selector + probe cache fresh (<30d).

#### Step 2: `/recording-rig:author` extensions

Backend-first question; for Desktop, surface choice, coordination default `auto`, starter `system_prompt_prologue` template. Reads probe cache to warn about restrictions.

#### Step 3: `/recording-rig:diagnose` extensions

Already partially in Phase 3 step 3; finalize the forensic-report formatting.

#### Step 4: `docs/design.md` Desktop section

Add a Desktop subsection mirroring the determinism-gap acknowledgment in this RDR. Honest documentation: this backend is structurally weaker than the CLI backend; the gap is bridged by model-instruction discipline, not by mechanism.

#### Step 5: `README.md` updates

Show `backend` selector usage and the three new examples.

#### Step 6: Cut v0.2.0

Bump `plugin.json`, update `CHANGELOG.md`, tag `v0.2.0` per `docs/RELEASE.md`. The CLI rig regression test: existing CLI specs in `examples/` and `test-runs/` continue to record successfully with byte-identical output (modulo timestamps).

**Phase 5 gate**: v0.2.0 cut. Plugin commands work uniformly across CLI and Desktop backends; doctor passes on a fresh install; all three example specs record successfully.

### Day 2 Operations

| Resource | List | Info | Delete | Verify | Backup |
| --- | --- | --- | --- | --- | --- |
| Claude-Rig user-data-dir | `ls "$HOME/Library/Application Support/Claude-Rig"` | `doctor --info-profile` | `doctor --remove-profile` | `doctor --verify-profile` (auth fresh, bridge present, probe cache OK) | Out of scope (recreatable from primary via `--seed-from-primary`) |
| Bridge `.mcpb` install | `cat "$HOME/.../Claude-Rig/Claude Extensions Settings/local.mcpb.hellblazer.recording-rig-bridge.json"` | `doctor --info-bridge` | Settings UI (no automation) | `doctor --verify-bridge` (bridge tool list call returns expected schema) | Bridge source lives in `bridge/`; rebuilds are reproducible. |
| Probe cache | `cat "$HOME/Library/Application Support/recording-rig/probe-cache.json"` | Inspected by `doctor` | Delete the file; `doctor --probe-surfaces` regenerates | Doctor warns if missing/stale | Recreatable via re-probe. |
| Quality log | `cat "$HOME/Library/Application Support/recording-rig/quality.jsonl"` | Inspected by `doctor` | Truncate to start fresh after a major prologue change | Last N lines surfaced in doctor | Append-only; rotate manually if needed. |

### New Dependencies

| Dependency | License | Legal Review |
| --- | --- | --- |
| Swift toolchain (`swiftc`) — builds `bin/desktop-driver` | Apache 2.0 (Swift) | Ships with Xcode / Command Line Tools; system-provided on macOS |
| AXUIElement + ScreenCaptureKit + AVFoundation | Apple system frameworks | First-party macOS frameworks; no third-party dependency (replaces the Playwright dependency from the original design) |
| `ffmpeg` (system binary) | LGPL / GPL (depending on build) | Standard OSS |
| `gifski` (system binary) | AGPL-3.0 | Compatible with this project's AGPL-3.0-or-later license |
| Bridge MCPB Node runtime | Bundled with Claude Desktop (no separate install) | N/A |

## Test Plan

Test scenarios cover each phase's gate plus cross-cutting failure modes.

- **Scenario**: Code coordination (A1 PASS) — **Verify**: a spec with `coordination: "auto"` on Code resolves to `mcp-bridge` per doctor's cached probe.
- **Scenario**: CoWork coordination (A2 fallback) — **Verify**: a spec with `coordination: "auto"` on CoWork resolves to `coworkd-log-tail`; preflight rejects gated specs (`gates[]` / required checkpoints) targeting CoWork.
- **Scenario**: AX submit recipe — **Verify**: `AXValue`-set + process-targeted Return submits a prompt and the response is readable in the AX tree; a global `CGEvent.post(tap:)` is never used (code review / lint).
- **Scenario**: End-to-end Chat recording with all required checkpoints called — **Verify**: validator PASSES; `.gif` + `.mp4` rendered; bridge transcript contains expected calls in order.
- **Scenario**: End-to-end Chat recording with one required checkpoint omitted — **Verify**: validator FAILS; no GIF rendered; error message names the missing checkpoint.
- **Scenario**: Model skips `rig.turn_end` for entire recording — **Verify**: fallback timer fires; recording completes with soft-miss logged; quality.jsonl entry added.
- **Scenario**: Two simultaneous recordings attempt to start with the same SESSION — **Verify**: second invocation refuses with the same error class as CLI rig's `tmux has-session` check.
- **Scenario**: Existing CLI spec from `examples/single-pane.json` re-recorded after Desktop backend lands — **Verify**: byte-identical artifact output (modulo timestamps).
- **Scenario**: `doctor` run against a Desktop newer than the probe-cache version — **Verify**: warning surfaced; option to re-probe offered.
- **Scenario**: Claude-Rig profile idle 48h, then recording attempted — **Verify**: doctor pre-record check surfaces auth-staleness warning; recovery instruction provided.

## Validation

### Testing Strategy

1. **Scenario**: Phase-0 probe report archived to T2 with PASS/FAIL per assumption.
   **Expected**: A1–A12 each marked Verified / Superseded / Pending-with-reason (done 2026-05-24); §Technical Design and §Alternative 7 (ScreenCaptureKit adopted) reflect the AX + SCK pivot.

2. **Scenario**: Phase-1 bridge integration test — record a single-turn Chat spec end-to-end manually.
   **Expected**: All four bridge tools observable in transcript; sentinels appear at expected paths.

3. **Scenario**: Phase-2 minimum viable validation reproduced 10 times in a row.
   **Expected**: 10/10 PASS, zero re-takes, identical structural output (modulo timestamps).

4. **Scenario**: Phase-4 per-surface recording across all three surfaces, 10 runs each.
   **Expected**: 30/30 PASS in optimistic case; in pessimistic case, 30/30 PASS with the documented gate restrictions enforced at preflight.

5. **Scenario**: CLI rig regression — re-record every spec in `examples/` and `test-runs/` after each phase.
   **Expected**: byte-identical output to pre-Desktop-backend recordings.

### Performance Expectations

Comparison metric is "re-take rate," not throughput. Existing CLI rig achieves zero re-takes on the tutorial specs in `test-runs/`. Desktop backend success criterion: same (see §Success criteria in [Implementation Plan / Minimum Viable Validation](#minimum-viable-validation)). Wall-clock recording duration is dominated by model response time, not rig overhead; not estimated.

## Finalization Gate

> Complete each item with a written response before marking this RDR as **Accepted**.

### Contradiction Check

[To be filled at gate time. Expected: "No contradictions found between research findings, design principles, and proposed solution." If `.mcpb`-in-Code/CoWork probes resolve negatively, the pessimistic-case design path activates without contradicting the architecture.]

### Assumption Verification

[Confirm A1–A10 resolved. After round-2: A2 Documented-Unreliable (`001-research-14`, pessimistic fallback mandatory), A4 Documented (`001-research-13`, pin `playwright >= 1.59.0`), A8 refined (`001-research-19`, use `windows()` not `firstWindow()` for install dialog), A9 verified-by-inference (`001-research-10/16/17`), A10 gated to Phase 2 Step 1 spike. A1/A3/A5/A6/A7/A8 still gated to Phase 0 spikes.]

#### API Verification

| API Call | Library | Verification |
| --- | --- | --- |
| `AXUIElementSetAttributeValue(app, "AXManualAccessibility", true)` activates the renderer a11y tree | ApplicationServices (AX) | **Spike-verified (A11)** — full UI tree exposed (≈265–371 named nodes) only with this set, held by a long-lived process; `--force-renderer-accessibility` flag alone is insufficient |
| `AXUIElementPerformAction(elem, kAXPressAction)` ; `AXUIElementSetAttributeValue(composer, kAXValueAttribute, text)` ; `kAXSizeAttribute` | ApplicationServices (AX) | **Spike-verified (A11)** — navigation, composer text-set, and window geometry all confirmed against the live app |
| `CGEvent(virtualKey: 0x24).postToPid(rigPid)` for the submit Return (process-targeted) | CoreGraphics | **Spike-verified (A11)** — submit confirmed end-to-end (response read back via AX). `AXValue`-set alone is inert; global `CGEvent.post(tap:)` leaks (forbidden) |
| `SCShareableContent` → `SCContentFilter(desktopIndependentWindow:)` → `SCStream` + `AVAssetWriter` ; `SCScreenshotManager` | ScreenCaptureKit + AVFoundation | **Spike-verified (A12)** — h264 `.mov`, 94 frames / 3 s, ffprobe-confirmed. CLI tool must init `NSApplication.shared` (`.accessory`) to avoid `CGS_REQUIRE_INIT` |
| `.mcpb` manifest v0.4 schema + `extensions-installations.json` file-drop | mcpb / claude-desktop | Source Search (`mcpb/MANIFEST.md`) + **Spike-verified (A3, file-drop install loads)** |
| Bridge tool callability per surface | claude-desktop | **Spike-verified (A1, P0.1 PASS for Code)**; `001-research-14` documents the P0.2/CoWork race (pending) |

### Scope Verification

Minimum Viable Validation is defined under [Implementation Plan / Minimum Viable Validation](#minimum-viable-validation). In scope for Phase 2 — end-to-end Chat recording with required-checkpoint enforcement and deliberate-fail reproduction. Not deferred.

### Cross-Cutting Concerns

- **Versioning**: Bridge MCPB version + Desktop bundle version pinned in `bin/desktop-ax-selectors.json` and `probe-cache.json`. Doctor warns on Desktop version drift. New Desktop backend triggers `recording-rig` major-version bump (v0.2.0).
- **Build tool compatibility**: Bridge ships as Node MCPB (Node bundled with Claude Desktop). The Desktop driver is a compiled Swift binary (`swiftc`, system-provided) using Apple frameworks only — built by `doctor`/CI, no third-party runtime.
- **Licensing**: New dependencies (Swift toolchain Apache-2.0; Apple system frameworks; ffmpeg; gifski AGPL-3.0) all compatible with `AGPL-3.0-or-later`. The Playwright (Node) dependency from the original design is dropped.
- **Deployment model**: Plugin install via marketplace (see `docs/RELEASE.md`). Bridge install via `doctor --install-bridge` (Settings-UI-mediated). Claude-Rig profile install via `doctor --install-profile`.
- **IDE compatibility**: N/A.
- **Incremental adoption**: Users opt in by writing `backend: "desktop"` in a spec. Default `cli` is unchanged. Existing specs continue to work.
- **Secret/credential lifecycle**: OAuth tokens live in Keychain (shared by app identity) and `Local State` (machine-bound). Bridge handles no secrets directly. Rotation: standard Claude Desktop refresh loop.
- **Memory management**: Bridge tool calls are stateless beyond the per-call sentinel write + transcript append. Transcript JSONL grows linearly with recording length; rotated per recording. Webm files are tens-to-hundreds of MB depending on duration; cleaned up by `record.sh` teardown unless `--keep` flag set.

### Proportionality

The architecture is sized for a real cross-surface recording backend, not a quick experiment. Phase 0 gates substantive code work behind probe results, so the document's prescriptive sections (§Technical Design phases 1–5) only execute on validated assumptions. The provider-polymorphic abstraction is the only "designed for an uncertain future" element; it is justified by the explicit A1/A2 uncertainty and the cost of refactoring after that uncertainty resolves.

## References

- [`../design.md`](../design.md) — CLI rig design rationale; required reading for the Core Insight (TUI scraping structurally broken) and Sentinel-file contract sections.
- [`../RELEASE.md`](../RELEASE.md) — release procedure; v0.2.0 cut at Phase 5.
- [`../../CHANGELOG.md`](../../CHANGELOG.md) — version history.
- [Anthropic engineering blog — Desktop Extensions](https://www.anthropic.com/engineering/desktop-extensions) — `.mcpb` rationale, install flow.
- [MCPB MANIFEST.md](https://github.com/modelcontextprotocol/mcpb/blob/main/MANIFEST.md) — manifest schema v0.4.
- [Apple — Accessibility (AXUIElement)](https://developer.apple.com/documentation/applicationservices/axuielement_h) and [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) — the validated drive + record stack (A11/A12).
- Playwright/CDP (original design, now rejected — A4/P0.5): Claude.app blocks `--remote-debugging-port`/`--remote-debugging-pipe`, so `_electron.launch` cannot attach. Retained only as historical context in §Key Discoveries / §Alternatives.
- T2 `recording-rig/claude-app-blocks-remote-debugging-flags-2026-05-24` — the CDP guard (A4 FAIL).
- T2 `recording-rig/claude-app-ax-driving-viable-2026-05-24` and `…-ax-input-submit-mechanism-2026-05-24` — AX drive recipe + the global-CGEvent safety rule (A11).
- T2 `recording-rig/claude-app-screencapturekit-recording-viable-2026-05-24` — SCK recording (A12).
- T2 `recording-rig/claude-app-multi-instance-per-userdatadir-2026-05-24` — multi-instance + OAuth-collision (A9).
- T2 `recording-rig/RDR-001-phase0-probes` — per-probe results (P0.1/P0.3/P0.5 …).
- [`anthropics/claude-code` issue #20377](https://github.com/anthropics/claude-code/issues/20377) and [#26259](https://github.com/anthropics/claude-code/issues/26259) — `.mcpb` desktop extensions not reliably forwarded to CoWork VM (race in `remoteMcpServersConfig`); informs A2 Documented-Unreliable.
- [`anthropics/claude-code` issue #41836](https://github.com/anthropics/claude-code/issues/41836) — no MCP session/conversation identifier echoed; informs `001-research-15`.
- [`anthropics/claude-code` issue #42453](https://github.com/anthropics/claude-code/issues/42453) — confirms legacy `mcpServers`-path tools disabled in Code/CoWork; `.mcpb`-path unconfirmed.
- T1 scratch `45000495-41ae-43d4-8fd5-3dfe760fe916` (tag `recording-rig-desktop-rdr-findings`) — full research report.
- T1 scratch `08daa01d-59de-4c2b-b901-be734c7e0497` (tag `recording-rig-desktop-rdr-architecture`) — pre-RDR architecture draft.
- T1 scratch `a3aea278-ee04-4b00-8114-e563344dedfc` (tag `recording-rig-desktop-rdr,audit-revisions,verified`) — `nx_plan_audit` revisions applied to this RDR.

## Revision History

- 2026-05-23 — Initial draft (RDR-001 v1.0). Research, architecture, and audit phases complete; document populated from prepped design with the six `nx_plan_audit` revisions applied inline.
- 2026-05-23 — Round 2 research findings appended to Key Discoveries (20 entries, `001-research-1` through `001-research-20`). Critical Assumptions table updated: A2 weakened (Unverified → Documented-Unreliable, race-condition bug in CoWork `.mcpb` delivery), A4 strengthened (Unverified → Documented, Playwright >= 1.59.0 hard prerequisite), A8 refined (use `windows()` not `firstWindow()` for install dialog), A9 added (mutual exclusion across instances verified by inference), A10 added (page.screencast on Electron unverified). Notable refutation: vsock CID=2 collision risk surfaced in round 1 is REFUTED by per-VM namespacing (Apple Virtualization framework). Notable gap (resolved in next revision): Phase 2 Step 1 driver sketch passed `recordVideo`/`recordHar`/`tracesDir` to `_electron.launch` — those belong to `browser.newContext`.
- 2026-05-23 — Round 2 follow-up: two additional findings recorded (`001-research-21` vsock third-party host listener impossibility on Apple Virtualization; `001-research-22` MCP servers always run on host as `Claude Helper (Plugin)` stdio children, invariant across surfaces) — total 22 round-2 entries. Cross-project T2 entry written to `nexus/cowork-vsock-third-party-host-listener-impossible-2026-05-23` validating nexus RDR-126's SDK-transport decision.
- 2026-05-23 — Gate v1 → BLOCKED (3 Critical, 4 Significant text issues; substantive-critic report). Fixes applied in-place: (1) Phase 2 Step 1 + driver-launch sketch + API Verification table corrected to the five-option `_electron.launch` signature with separate `page.screencast.start/stop` and contingent HAR/trace notes; (2) `electronApp.windows()` + `'window'` event subscription added for install-dialog flow (A8 refinement); (3) OAuth deep-link risk re-worded from "may go to wrong instance" to "WILL go to most-recently-active instance (deterministic per macOS LaunchServices)"; (4) MCPB transport-silence risk added to §Risks; (5) CoWork pessimistic-case race-condition ceiling added to §Consequences; (6) Phase 0 Prerequisites updated A1–A8 → A1–A10 with per-assumption status; (7) HAR/trace forensics in Failure Modes and Phase 3 Step 3 marked contingent on Phase 2 sub-spike. Ready for re-gate.
- 2026-05-23 — Gate v2 → PASSED. RDR accepted; status draft → accepted. 39-bead execution plan created (epic `rr-enu`, Phase 0–5 coordinators + 32 leaves), `nx_plan_audit` PASS, `nx_enrich_beads` applied.
- 2026-05-24 — **Architecture pivot: Playwright/CDP → AXUIElement + ScreenCaptureKit.** Phase 0 spikes run against the live app (Claude.app v1.8555.2, Electron 41.6.1). **P0.1 PASS** (A1: `.mcpb` reachable in Code → Code uses `mcp-bridge`). **P0.3 PASS** (A3: file-drop install honored → doctor recovery path). **P0.5 FAIL, architecture-invalidating** (A4): Claude.app ships an anti-automation guard that `app.quit()`s on either Chromium remote-debugging transport (`--remote-debugging-port`/`--remote-debugging-pipe`) — Playwright `_electron.launch` uses exactly those, so it cannot attach, version-independently. Pivot validated end-to-end: **A11** (AX drive — `AXManualAccessibility` activation, `AXPress` nav, `AXValue`+`postToPid` Return submit, `kAXSizeAttribute` geometry) and **A12** (ScreenCaptureKit → h264 `.mov`, 94 frames/3s verified). A5/A10 SUPERSEDED (page.screencast/BrowserView concern moot under SCK's compositor capture); A6 reframed DOM→AX selectors (verified — named elements exposed); A8 dismissal reframed to AX; A9 refined (multi-instance launch coexists; OAuth-login collision confirmed). Driver implementation: a Swift helper (`bin/desktop-driver`) does AX + SCK; `record.sh` (shell/Node) orchestrates. Two driver invariants: (i) re-arm a11y + wait-for-stable before each action from one long-lived process; (ii) process-targeted input only (`postToPid`), never global CGEvent (it leaks to the focused app — observed). ASCII architecture diagram replaced with `RDR-001-architecture.svg`. Findings in T2: `recording-rig/{RDR-001-phase0-probes, claude-app-blocks-remote-debugging-flags, claude-app-multi-instance-per-userdatadir, claude-app-ax-driving-viable, claude-app-ax-input-submit-mechanism, claude-app-screencapturekit-recording-viable}-2026-05-24`. P0.2 (CoWork) and P0.7 (OAuth 48h) still pending; P0.4/P0.6/P0.8 reshaped/absorbed by the AX pivot. Ready for re-gate.
