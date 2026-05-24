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

These must be verified before this RDR moves to Accepted. Each is gated to a Phase 0 probe.

- [ ] **A1.** `.mcpb` extension tools are reachable from the Code surface model context. — **Status**: Unverified — **Method**: Spike (P0.1) — install a probe extension with one distinctive tool, start a Code session, ask the model to list its available tools and call the probe.
- [ ] **A2.** `.mcpb` extension tools are reachable from the CoWork surface model context (proxied through vsock into the VM). — **Status**: Documented-Unreliable (round 2 — `001-research-14`) — `anthropics/claude-code#20377` and `#26259` confirm intent + race-condition bug in `remoteMcpServersConfig` initialization. Bug closed inactive without confirmed fix. — **Method**: Spike (P0.2) MUST repeat multiple times to catch intermittent failures. Pessimistic-case fallback for CoWork is CONFIRMED necessary, not precautionary.
- [ ] **A3.** File-drop install (writing files to `Claude Extensions/` + editing `extensions-installations.json`) is honored on next Desktop launch, bypassing the Settings-UI install flow. — **Status**: Unverified — **Method**: Spike (P0.3). Not load-bearing for the chosen design (§4.1 hybrid uses Settings-UI install via `open path/to/.mcpb`); informs the recovery path if that flow breaks in a future Desktop release.
- [x] **A4.** Playwright's `_electron.launch` works against Claude.app's Electron 41.6.1. — **Status**: **FAILED (P0.5, 2026-05-24) — architecture-invalidating.** Claude.app v1.8555.2 ships a targeted anti-automation guard that calls `app.quit()` immediately when launched with **either** Chromium remote-debugging transport (`--remote-debugging-port` in any form, OR `--remote-debugging-pipe`). Playwright's `_electron.launch` drives Electron *exclusively* via the Chromium DevTools Protocol, bootstrapped by one of exactly those two flags — there is no third transport — so Playwright cannot attach at all, independent of version (the 1.58.1 `--remote-debugging-port=0` fix is moot; the app rejects the flag regardless of value). Confirmed by controlled flag-probe matrix: benign unknown flags, `--user-data-dir`, `--remote-debugging-address` (no port), and the Node `--inspect` family all leave the app running; both remote-debugging transports kill it. Exit is a graceful `app.quit()` (`CoreAnalytics: Entering exit handler` in the unified log ~64 ms after AppKit init), not a crash → deliberate guard. **Cascades to A5, A6, A8, A10** (all presuppose a Playwright page handle). **The RDR's Playwright-Electron driver+recording mechanism is non-viable as designed; RDR revision required** (recommended pivot: native macOS automation — AXUIElement/CGEvent drive + ScreenCaptureKit record — which sidesteps CDP and is ethically clean). What survives: the `.mcpb` sentinel bridge (A1 PASS) and `--user-data-dir` profile isolation. — Evidence: T2 `recording-rig/RDR-001-phase0-probes` (P0.5 section) and cross-cutting T2 `recording-rig/claude-app-blocks-remote-debugging-flags-2026-05-24`. — **Method**: Spike (P0.5), Playwright 1.60.0.
- [ ] **A5.** Claude.app uses a single BrowserWindow for the CoWork surface (no `BrowserView`/separate WebContents that Playwright `page.screencast` would miss). — **Status**: Unverified — **Method**: Spike (P0.4) — launch Claude.app with `--remote-debugging-port=9222`, inspect `chrome://inspect` during a CoWork session.
- [ ] **A6.** DOM selectors for sidebar navigation, surface inputs, and send buttons can be discovered and pinned to a Desktop version. — **Status**: Unverified — **Method**: Spike (P0.6) — DevTools inspection on each surface, captured to `bin/desktop-selectors.json`.
- [ ] **A7.** A long-idle Claude-Rig profile refreshes OAuth tokens on next launch without requiring a fresh interactive login. — **Status**: Unverified — **Method**: Spike (P0.7) — leave profile idle 48h, observe `main.log` for successful refresh on relaunch.
- [ ] **A8.** `open path/to/.mcpb` triggers Claude Desktop's install dialog reliably AND dismissal can be sentinel-driven from the driver. — **Status**: Documented (round 2 — `001-research-11`, `001-research-19`) — `.mcpb` is registered with Claude.app as `CFBundleTypeRole: Viewer`; dialog renders as an in-app BrowserWindow element (per Anthropic engineering blog). Whether it opens as a new `BrowserWindow` or content within an existing one remains unknown. — **Method**: Spike (P0.8) MUST use `electronApp.windows()` (plural), not just `firstWindow()`; subscribe to `electronApp.on('window', ...)` to catch new windows post-launch. Playwright DOM locators are viable for auto-dismiss (no AppleScript / AXUIElement required). Second remaining TUI-scrape exception, analogous to the CLI rig's `consent_sweep` in `record.sh`.
- [ ] **A9.** No two simultaneous Desktop-backend recordings collide; mutual exclusion is the only available cross-instance disambiguation. — **Status**: Verified by inference (round 2 — `001-research-10`, `001-research-16`, `001-research-17`). `claude://` LaunchServices is bundle-identity-scoped (no per-user-data-dir routing); OAuth callbacks go to most-recently-active instance; vsock CIDs are per-VM-namespaced (no collision at that layer), but the single-active-session guard makes the question moot. — **Method**: Implemented as a refuse-launch check (mirror of CLI rig's `record.sh:208-212` `tmux has-session`).
- [ ] **A10.** `page.screencast.start/stop` works on Electron pages obtained via `electronApp.firstWindow()` for Electron 41 specifically. — **Status**: Unverified (round 2 — gap surfaced by `001-research-9` and `001-research-13`). API exists in Playwright v1.59+ for all backends, but Electron-specific verification not done. — **Method**: Spike (Phase 2 Step 1 — minimal "launch Claude.app, start screencast, click, stop, verify .webm playable" probe before the full driver lands).

**Method definitions** (template-standard):

- **Source Search**: API verified against dependency source code or official documentation
- **Spike**: Behavior verified by running code against a live service (required for the eight above — Claude Desktop is opaque to source search)
- **Docs Only**: Insufficient for load-bearing assumptions

## Proposed Solution

### Approach

A second driver backend, additive to the CLI backend. Selection via a new top-level `backend: "cli" | "desktop"` field in the spec (default `"cli"`). The CLI backend stays byte-identical; existing CLI specs continue to record without modification.

The Desktop backend uses Playwright Electron (`_electron.launch`) to drive an isolated long-lived Claude.app profile (`~/Library/Application Support/Claude-Rig/`) with a permanently installed `.mcpb` bridge (`recording-rig-bridge.mcpb`) that acts as the sentinel emitter. The bridge exposes four tools the model is instructed to call at named beats: `rig.turn_end()`, `rig.checkpoint(name)`, `rig.ask(options) → answer_index`, `rig.emit(name, payload)`. Each call atomically writes a sentinel file under `/tmp/${SESSION}.*` using the SAME contract as the CLI rig (`.partial` + rename, no trailing newline, identifier regex `[A-Za-z0-9._-]+` from `lib/sentinels.sh:12` `rig_check_identifier`). Sentinel files inherit the invoker's umask (typically owner-readable/writable, group/world-readable); the bridge runs in Claude.app's process tree under the same user as the rig, matching CLI rig behavior. The `prompt-submitted` sentinel (analogue of the CLI's `UserPromptSubmit` hook) is **not** a bridge tool; it is written by the driver itself immediately after `locator.fill()` + send-button click, because the driver knows when it submitted and no model action is needed. This preserves the existing sentinel-name semantics consumed by `commands/diagnose.md:12` and by companion-pane start signals.

Surface coordination is provider-polymorphic. A `CoordinationProvider` interface with three implementations — `mcp-bridge` (strongest), `file-mtime-watch` (Code fallback), `coworkd-log-tail` (CoWork fallback) — selected per-surface by doctor's cached probe results (`coordination: "auto"` in the spec). The optimistic case (A1 and A2 both pass): all three surfaces use `mcp-bridge`. The pessimistic case: Chat uses `mcp-bridge`; Code falls back to file-mtime; CoWork falls back to log-tail. Spec authors write the same spec either way; the provider is chosen at preflight.

### Technical Design

Architecture overview (mirrors the CLI rig's ASCII diagram in `../design.md`):

```
┌──────────────────────────────────────────────────────────────────────┐
│                                record.sh                             │
│                       (backend dispatcher; CLI is default)           │
└────────────┬──────────────────────────────────┬──────────────────────┘
             │ backend=cli                      │ backend=desktop
             ▼                                  ▼
   ┌───────────────────┐              ┌──────────────────────────────┐
   │ existing CLI path │              │ bin/desktop-driver.mjs       │
   │ (unchanged):      │              │  (Node + Playwright)         │
   │  render-hooks.sh  │              │   │                          │
   │  tmux-session.sh  │              │   ├─ launch Claude.app via   │
   │  driver.sh        │              │   │   _electron.launch       │
   │  asciinema rec    │              │   │   --user-data-dir=<prof> │
   │  validate.mjs     │              │   ├─ write active-session    │
   │  agg              │              │   │   pointer + rig-config   │
   └───────────────────┘              │   ├─ navigate to surface     │
                                      │   ├─ paste agent.command(s)  │
                                      │   ├─ touch prompt-submitted  │
                                      │   ├─ watch sentinels         │
                                      │   ├─ page.screencast → .webm │
                                      │   └─ on agent-done: stop +   │
                                      │      teardown                │
                                      └───────┬──────────────────────┘
                                              │
                              spawns / drives  ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │              Claude.app (Electron, headed, isolated profile)     │
   │  ┌──────────┐  ┌──────────┐  ┌──────────────────────────────┐    │
   │  │  Chat    │  │  Code    │  │  CoWork (Linux VM via vsock) │    │
   │  └────┬─────┘  └────┬─────┘  └────┬─────────────────────────┘    │
   │       │             │             │                              │
   │       └─────────────┼─────────────┘                              │
   │                     │ model invokes MCP tools                    │
   │                     ▼                                            │
   │     ┌─────────────────────────────────────────────┐              │
   │     │   recording-rig-bridge.mcpb (permanent)     │              │
   │     │     reads /tmp/<sess>.rig-config.json       │              │
   │     │     writes /tmp/<sess>.* sentinels          │              │
   │     │     logs /tmp/<sess>.bridge-transcript.jsonl│              │
   │     │     tools: rig.turn_end                     │              │
   │     │            rig.checkpoint(name)             │              │
   │     │            rig.ask(options) → answer_index  │              │
   │     │            rig.emit(name, payload)          │              │
   │     └──────────────────┬──────────────────────────┘              │
   └────────────────────────┼─────────────────────────────────────────┘
                            │ sentinel files
                            ▼
        ┌──────────────────────────────────────┐
        │ /tmp/${SESSION}.* sentinel namespace │
        │   (identical contract to CLI rig)    │
        └────────┬─────────────────────────────┘
                 │ consumed by
                 ▼
        ┌──────────────────────────────────────┐
        │ desktop-driver waits on:             │
        │   turn-end (rig.turn_end)            │
        │   agent-done (driver-set on idle)    │
        │   gate-pending (rig.ask call)        │
        │   <capture-tool sentinels>           │
        │   prompt-submitted (driver-written)  │
        └──────────────────────────────────────┘

  Pessimistic-case fallback (when A1/A2 fail) replaces bridge → sentinels
  for Code and CoWork with:
    file-mtime-watch: local-agent-mode-sessions/ mtime → turn-end sentinel
    coworkd-log-tail: coworkd.log structured events → turn-end sentinel
  Driver code is provider-polymorphic; downstream consumers unchanged.

  Post-recording (both cases):
    .webm → ffmpeg → .mp4 + .gif (new bin/render-webm.sh)
    bridge-transcript.jsonl + .webm + spec → validate.mjs
```

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

Driver launch (sketch — actual `_electron.launch` invocation in `bin/desktop-driver.mjs`). API signatures verified against Playwright `/microsoft/playwright` docs (round-2 finding `001-research-9`): `_electron.launch()` accepts ONLY `{executablePath, args, cwd, env, timeout}`. Recording is per-page via `page.screencast.start/stop` (Playwright v1.59+; pin per `001-research-13`). HAR/trace capture for Electron is contingent on a Phase 2 sub-spike (see A10 / Failure Modes notes below).

```text
const electronApp = await electron.launch({
  executablePath: "/Applications/Claude.app/Contents/MacOS/Claude",
  args: ["--user-data-dir=${HOME}/Library/Application Support/Claude-Rig",
         "--no-default-browser-check"],
  env: { ...process.env, /* spec.desktop.env */ },
  timeout: 30000,
})

// Recording page: firstWindow() returns the initial BrowserWindow.
const page = await electronApp.firstWindow()

// Install-dialog detection (P0.8 flow): subscribe to windows() because
// the dialog may open as a new BrowserWindow post-launch — firstWindow()
// would miss it (per round-2 finding 001-research-19 / A8 refinement).
electronApp.on('window', async (dialogPage) => { /* dismiss if install-dialog */ })

// Screencast (Playwright v1.59+): per-page, not a launch option.
await page.screencast.start({ path: webmPath, fps: spec.render?.fps ?? 24 })
// ... drive the session ...
await page.screencast.stop()

// HAR + tracing for Electron: contingent on Phase 2 sub-spike validating
// context.tracing.startHar() and .start() on a context derived from the
// Electron app (001-research-9). Not safe to assume available.
```

Surface navigation uses cached DOM selectors in a new `bin/desktop-selectors.json` (populated by Phase 0 P0.6 spike). Driver calls `page.click(selectors["sidebar." + spec.desktop.surface])` then waits on a `surface-ready` sentinel the bridge writes when it observes the first tool-listing call from the new surface (analogue of CLI's `session-start` wait).

Typing input: Playwright's `locator(input).fill(text)` for the agent.command, then `locator(send).click()` (or `keyboard.press("Enter")` per surface). After send, the driver atomically writes `/tmp/${SESSION}.prompt-submitted` (same `.partial`+rename pattern). No paste-buffer trick needed — Playwright's `fill` is reliable on long inputs, unlike `tmux send-keys -l`.

Sentinel watch reuses CLI semantics, ported to JS: poll `turn-end` mtime, idle when stable for `idle_seconds`. Same `turn_timeout_sec` and `session_max_sec` ceilings. Per-command flow mirrors `bin/driver.sh`: `rm turn-end` before paste, paste, consume gates targeted at this command, wait idle. Concrete primitives: `sentinel_clear_all()` (`lib/sentinels.sh:41`) called before pre-paste; `sentinel_wait_idle()` (`lib/sentinels.sh:78`) ported to JS for the idle wait. The original bash primitives continue to gate the outer `record.sh` orchestrator.

Screencast control: `page.screencast.start({ path: webmPath, fps: spec.render?.fps ?? 24 })` before first paste; `page.screencast.stop()` after `agent-done` + `exit_hold_sec`. Final-frame screenshot via `page.screenshot({ path: finalFramePath })` for thumbnails.

Teardown: on `agent-done` sentinel + hold, `electronApp.close()` (clean Electron exit flushes video). Unlink `/tmp/recording-rig.active-session`. Optionally save Playwright trace zip for `diagnose`.

#### Existing Infrastructure Audit

| Proposed Component | Existing Module | Decision |
| --- | --- | --- |
| Backend dispatch in `record.sh` | `bin/record.sh` (CLI-only today) | **Extend**: insert `case "$BACKEND" in cli) … ;; desktop) exec node bin/desktop-driver.mjs "$SPEC" ;;` after shared preflight + sentinel_clear_all, before tmux/asciinema. Shared steps (SESSION resolution, sentinel_clear_all, preflight identifier regex) run before fork. |
| `bin/desktop-driver.mjs` | none — new file | **Create**: Node ES module, Playwright dependency. |
| `bin/render-webm.sh` | `bin/render-hooks.sh` (different role) | **Create**: invokes ffmpeg + gifski for `.webm → .mp4 + .gif`. |
| `bin/desktop-selectors.json` | none — new file | **Create**: per-Desktop-version DOM selector cache, populated by P0.6. |
| `recording-rig-bridge.mcpb` | none — new artifact | **Create**: standalone MCPB bundle, built in this repo and published to releases. |
| Sentinel write contract | `bin/render-hooks.sh:31-44` (atomic .partial+rename) | **Reuse**: bridge implements the same pattern in Node. |
| Identifier regex | `lib/sentinels.sh:12` `rig_check_identifier` `[A-Za-z0-9._-]+` | **Reuse**: bridge inlines the same regex; preflight in `record.sh:104-107` continues to gate. |
| `sentinel_clear_all` | `lib/sentinels.sh:41` | **Reuse via shell**: orchestrator calls before driver dispatch; driver does not re-clear. |
| `sentinel_wait_idle` | `lib/sentinels.sh:78` | **Port**: equivalent JS implementation inside `bin/desktop-driver.mjs` for mtime-based idle wait. |
| `bin/validate.mjs` | `bin/validate.mjs` (asciinema-cast parser) | **Extend**: branch on `spec.backend`; for `desktop`, read `bridge-transcript.jsonl` as primary input + `.webm` metadata as sanity. |
| Plugin commands | `commands/{record,author-spec,doctor,diagnose}.md` | **Extend** all four to be backend-aware (`record` dispatches on `backend`; `doctor` adds Desktop checks; `author` adds Desktop fields; `diagnose` learns webm/transcript/trace forensics). |
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

**Description**: Use Playwright `page.route()` on the Chat BrowserWindow to intercept SSE responses and detect `message_stop` events as turn-end.

**Pros**:

- Works for Chat without any model instruction
- Catches the cleanest possible signal (actual stream-end event)

**Cons**:

- Works only in Chat — Code routes through a separate local-agent-mode process; CoWork routes through a vsock-mediated VM. Not uniform across surfaces.
- Adds a Playwright-specific code path that doesn't help the other surfaces

**Reason for rejection**: Not uniform. Kept as a supplementary diagnostic (HAR capture) but not as a primary coordination mechanism.

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

### Alternative 7: ScreenCaptureKit primary capture

**Description**: Use macOS ScreenCaptureKit (AVFoundation) as the primary capture mechanism, with Playwright as a control plane only.

**Pros**:

- Captures everything visible on the window, including any BrowserView sub-panels Playwright misses
- Higher fidelity for canvas/GPU content

**Cons**:

- macOS-only (the backend is macOS-first in phase 1 anyway, but adds a Mac-specific dependency)
- `.mov` output diverges from the existing ffmpeg-based post-processing pipeline
- Doubles disk + CPU for the common case where Playwright is sufficient (Chat, Code)

**Reason for rejection**: Chose Playwright `recordVideo` primary; ScreenCaptureKit as a secondary parallel stream gated behind P0.4 (only added if CoWork rendering has BrowserView sub-panels Playwright would miss). Pays the SCK cost only when it's necessary.

### Alternative 8: Separate `/recording-rig:desktop` command surface

**Description**: New top-level commands for the Desktop backend (`/recording-rig:desktop-record`, etc.) instead of routing the existing commands through the spec's `backend` field.

**Pros**:

- No backend-aware logic in commands

**Cons**:

- Forces users to know which backend they're using before selecting a command
- Duplicates the command tree

**Reason for rejection**: Chose backend-aware unified commands. Spec selects backend; commands route. User picks "record this spec" without thinking about backend taxonomy.

### Briefly Rejected

- **Headless Desktop recording**: Playwright Electron is headed-only; the recording IS the headed render. No headless mode to ship.
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
- **Negative**: Phase 0 probe results may force the pessimistic case (Code uses file-mtime-watch, CoWork uses coworkd-log-tail) in which `gates[]` are not supported on those surfaces and checkpoint assertions degrade to substring matches. Documented in the spec preflight.
- **Negative**: CoWork in the pessimistic case is bounded by an unresolved race-condition bug in Claude's own `remoteMcpServersConfig` initialization (`anthropics/claude-code#26259`, closed inactive without confirmed fix — round-2 finding `001-research-14`). Bridge tool calls from CoWork are intermittently dropped silently; the fallback `coworkd-log-tail` provider gives a coarser signal that is NOT improvable by prologue discipline. Re-take rate on CoWork may therefore be non-zero and non-improvable from the rig's side until Anthropic fixes the forwarding bug. Distinct from Chat/Code "weaker-but-improvable-via-prologue" — this is a structurally bounded ceiling. Spec preflight should surface a CoWork-specific advisory.
- **Negative**: Bridge installation is permanent in the Claude-Rig profile (no ephemeral install). One bridge per profile.
- **Negative**: New post-processing pipeline (`bin/render-webm.sh` for ffmpeg + gifski) — not as battle-tested as the CLI rig's `agg` pipeline.

### Risks and Mitigations

- **Risk**: A1 AND A2 both fail (`.mcpb` blocked in Code AND CoWork). Bridge useful only for Chat.
  **Mitigation**: Architecture already designs the pessimistic-case fallback (provider-polymorphic coordination, §Technical Design). Code and CoWork degrade to weaker coordination but remain usable. RDR documents the asymmetry; spec preflight rejects gated specs targeting fallback-provider surfaces.

- **Risk**: Model skips `rig.turn_end` due to instruction drift. Soft miss accumulates.
  **Mitigation**: System-prompt prologue is part of every Desktop spec template (`examples/desktop-*.json`). Fallback timer synthesizes turn-end with a soft-miss log entry if `pacing.turn_timeout_sec` elapses without the call. Soft-miss rate over last N recordings tracked in `~/Library/Application Support/recording-rig/quality.jsonl`; >20% triggers a doctor warning.

- **Risk**: Claude Desktop UI churn breaks DOM selectors. Surface navigation fails after a Desktop update.
  **Mitigation**: Selectors centralized in `bin/desktop-selectors.json`, version-pinned to the Desktop version observed at probe time. Doctor warns when running against a Desktop version newer than the cached probe. `--probe-surfaces` re-runs selector discovery.

- **Risk**: OAuth token expiry on idle Claude-Rig profile. First recording after long idle fails to launch authenticated.
  **Mitigation**: Doctor pre-record check warns "profile auth refreshed N days ago — consider launching Claude-Rig manually before recording." Recovery: user launches profile, lets refresh run, retries.

- **Risk**: Playwright < 1.59.0 fails against Claude.app's Electron 41.6.1 via the `--remote-debugging-port=0` CLI-arg rejection bug (`microsoft/playwright#39008`, fixed in v1.58.1 by PR #39012). Failure mode is opaque (`bad option: --remote-debugging-port=0`) and would be misread as a signing/entitlement issue (round-2 finding `001-research-13`).
  **Mitigation**: Plugin install instructions pin `playwright >= 1.59.0` (v1.59 also introduces `page.screencast.start/stop`). Doctor enforces the version floor with a clear error citing the issue number. `_electron.launch` should succeed once the floor is met; spike P0.5 reduced to launch-verification only.

- **Risk**: MCPB transport changes in a future Claude Desktop release silently break the bridge. MCPB v0.4 MANIFEST.md does NOT mandate stdio — Claude Desktop chooses stdio as an implementation detail (round-2 finding `001-research-18`), and could theoretically change without a manifest version bump.
  **Mitigation**: Bridge README + §Cross-Cutting Concerns / Versioning document the stdio assumption explicitly. `doctor --verify-bridge` includes a connectivity probe (call a bridge tool, assert response shape) that catches transport-format changes as a fast doctor failure rather than a silent recording miss.

- **Risk**: CoWork sub-panel capture gap. Playwright misses BrowserView frames if CoWork uses one.
  **Mitigation**: Phase 2 (post-probe) gates the addition of ScreenCaptureKit as a parallel stream if P0.4 shows separate WebContents. Validator can source from either capture.

- **Risk**: Bridge config file race. Two simultaneous recordings clobber `/tmp/recording-rig.active-session`.
  **Mitigation**: Driver refuses to launch if `active-session` exists; mirrors the CLI rig's `tmux has-session` check at `bin/record.sh:208-212`.

- **Risk**: Auth deep-link collision when seeding from primary. With two Claude.app instances running, macOS LaunchServices delivers the `claude://` `GetURL` Apple Event via `NSAppleEventManager` deterministically to the **most-recently-active** instance — not probabilistically (round-2 finding `001-research-16`). The OAuth callback WILL go to whichever instance was most recently active, not "may go to the wrong one".
  **Mitigation**: `doctor --install-profile` and `doctor --seed-from-primary` refuse to run if a non-Rig Claude.app is already running (`pgrep -f "Claude.app/Contents/MacOS/Claude"` returns a non-Rig PID). The PID check is sufficient because it enforces mutual exclusion at the OS level — no race, no luck, no need to control window focus during the OAuth flow. User-driven quit-then-resume on conflict.

- **Risk**: `extensions-installations.json` schema change invalidates the bridge install path.
  **Mitigation**: Bridge install uses the supported `open path/to/.mcpb` → Settings-UI install path (one of two surviving TUI-scrape exceptions, justified analogously to the CLI rig's `consent_sweep`). Direct manifest editing is the recovery path, not the primary.

### Failure Modes

- **Visible failure**: A required checkpoint missing in the bridge transcript → validator FAILS → no GIF rendered. Validator names the missing checkpoint.
- **Silent failure (mitigated)**: Model skips `rig.turn_end` but produces text output. Fallback timer synthesizes turn-end; recording completes; soft-miss logged for trend analysis.
- **Recovery**: Soft-miss aggregation surfaces drift in `diagnose`. Operator action: strengthen prologue, re-record. If soft-miss persists across prologue revisions, the Desktop backend's determinism floor for that surface/Desktop-version combo is established as the practical limit.
- **Diagnose path**: `/recording-rig:diagnose <session>` reads the transcript, webm, sentinel timeline, and (contingent on the Phase 2 HAR/trace sub-spike landing per round-2 finding `001-research-9`) HAR + Playwright trace; surfaces (a) which expected checkpoints were called and which were missed, (b) soft-miss rate trend, (c) webm-duration vs session-wall-time delta (capture-coverage check), (d) HAR cross-check (`turn_end` call vs SSE stream close) — *only if HAR capture validated on Electron*, (e) Playwright trace path for manual inspection — *only if `context.tracing.start()` validated on Electron*. Sentinel/transcript-based diagnostics are unconditional; HAR/trace are contingent.

## Implementation Plan

### Prerequisites

- [ ] All Critical Assumptions A1–A10 resolved before implementation. A1, A3, A5, A6, A7, A8 verified via Phase 0 spikes. A2 partly resolved by round-2 finding `001-research-14` (Documented-Unreliable; spike P0.2 still required to characterize intermittent-failure rate). A4 partly resolved by round-2 finding `001-research-13` (Documented; spike P0.5 reduced to launch verification). A9 verified-by-inference (round-2 findings `001-research-10/16/17` — no spike needed; the mutual-exclusion guard at the rig level is the enforcement). A10 gated to Phase 2 Step 1 verification (requires driver to exist).
- [ ] Probe results archived to T2 memory (project `recording-rig`, title `RDR-001-phase0-probes`)
- [ ] Decisions §Technical Design §11 (per-surface coordination) and §Alternative 7 (capture pipeline) locked based on probe outcomes
- [ ] `docs/design.md` updated with a new Desktop section that mirrors the determinism-gap acknowledgment in this RDR

### Minimum Viable Validation

End-to-end recording of a Chat-surface session with a minimal `desktop` spec produces all expected artifacts: `.webm` (Playwright video), `.gif` + `.mp4` (ffmpeg + gifski post-process), `bridge-transcript.jsonl` (with at least one `rig.turn_end` call), and `validate.mjs` PASS verdict. Required-checkpoint omission on a re-run reproduces a deliberate FAIL with no GIF rendered. This is the single proof that the bridge → sentinels → validator → render pipeline composes end-to-end. **In scope for Phase 2 — not deferred.**

### Phase 0: Probes (no code shipped)

Eight spikes; results to scratch tag `recording-rig-desktop-phase0-results` and to T2 memory.

#### Step 1: P0.1 — `.mcpb` reachable in Code

Install a probe `.mcpb` (`recording-rig-probe`, single tool `probe.distinctive_marker_42`) in the Claude-Rig profile. Start a Code session in a trusted folder. Ask the model: "Please call the probe.distinctive_marker_42 tool and report what it returns." Observe whether the tool is listed, callable, and returns successfully. Result: PASS / FAIL / DISABLED-WITH-ERROR.

#### Step 2: P0.2 — `.mcpb` reachable in CoWork

Same as P0.1 but in a CoWork session. Tests whether the vsock RPC layer proxies host extension tool calls into the VM model context.

#### Step 3: P0.3 — File-drop install viability

Without using Settings UI: write probe `.mcpb` files directly to `Claude Extensions/`, edit `extensions-installations.json` to register, restart Desktop, verify extension loads. Informs the recovery path for §Risk "extensions-installations.json schema change".

#### Step 4: P0.4 — WebContents count during CoWork

Launch Claude-Rig with `--remote-debugging-port=9222`. Open `chrome://inspect` in another browser. Start a CoWork session. Count WebContents/BrowserView targets. Determines whether ScreenCaptureKit is needed in addition to Playwright's screencast.

#### Step 5: P0.5 — Electron version compatibility

Already partially done (Claude.app Electron is 41.6.1). Pin a Playwright version, run `_electron.launch` against Claude.app, confirm launch succeeds. Report Playwright version + Electron support matrix.

#### Step 6: P0.6 — DOM selector discovery

With `--remote-debugging-port=9222`, navigate each surface (Chat / Code / CoWork). Use DevTools to identify stable selectors for sidebar nav, surface input, send button. Capture to `bin/desktop-selectors.json` with `claude_desktop_version: "1.8555.2"` keyed entry.

#### Step 7: P0.7 — Long-lived profile auth refresh

Launch Claude-Rig, log in interactively (or seed from primary). Leave idle 48h. Relaunch and observe `main.log` for successful OAuth refresh without re-auth. Sets the doctor's auth-staleness warning threshold.

#### Step 8: P0.8 — Bridge install via `open path/to/.mcpb`

Manually verify: `open recording-rig-bridge.mcpb` triggers Claude Desktop's install dialog reliably. Identify DOM locators for the install-confirmation button. Confirm dismiss can be sentinel-driven from a Playwright script.

**Phase 0 gate**: probe report → T2 memory. Decisions §Technical Design §11 and §Alternative 7 are locked based on results. If A1 or A2 fail, the pessimistic-case fallback providers (file-mtime-watch / coworkd-log-tail) move from "designed for but unimplemented" to "must implement in phase 4".

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

#### Step 1: `bin/desktop-driver.mjs`

Node ES module. Pins `playwright >= 1.59.0` (round-2 finding `001-research-13` — required for both Electron 30+ launch fix and `page.screencast` API). `_electron.launch({ executablePath, args, env, timeout })` — NOT `recordVideo`/`recordHar`/`tracesDir` (those are `browser.newContext()` options, not Electron-launch options — round-2 finding `001-research-9`). Pre-launch: write `/tmp/recording-rig.active-session`, write `/tmp/${SESSION}.rig-config.json`. Obtain recording page via `electronApp.firstWindow()` for normal surface navigation. **Install-dialog flow (P0.8)** is separate: subscribe to `electronApp.on('window', ...)` and inspect `electronApp.windows()` because the install dialog may open as a new `BrowserWindow` post-launch (`001-research-19` / A8 refinement) — `firstWindow()` alone will miss it. Navigate to Chat surface via `bin/desktop-selectors.json["sidebar.chat"]`. Type prompt via `locator(input).fill()` + `locator(send).click()`. Atomically write `/tmp/${SESSION}.prompt-submitted` immediately after send. Screencast: `await page.screencast.start({ path: webmPath, fps })` before paste; `await page.screencast.stop()` before teardown. **A10 spike happens here** — a minimal "launch + screencast.start + click + screencast.stop + verify .webm playable" probe MUST land before the full driver, to catch any Electron-41-specific screencast issue early. HAR + tracing for Electron are gated to a separate sub-spike (validate `context.tracing.startHar()` / `.start()` on a context derived from the Electron app — `001-research-9`); if not validated, ship without HAR/trace and document the diagnose-feature gap. Watch sentinels via ported `sentinel_wait_idle()`. Teardown: `electronApp.close()`, unlink active-session.

#### Step 2: `bin/render-webm.sh`

ffmpeg + gifski pipeline: `.webm → .mp4 + .gif`. Gated behind validation pass (mirrors CLI rig's gate against `agg`).

#### Step 3: Backend dispatch in `record.sh`

Insert `case "$BACKEND" in cli) ... ;; desktop) exec node bin/desktop-driver.mjs "$SPEC" ;; esac` after shared preflight (identifier regex validation, sentinel_clear_all, SESSION resolution) and before tmux/asciinema setup. Shared steps run for both backends.

#### Step 4: Chat-surface examples

`examples/desktop-chat.json` — minimal Chat-only spec with one command, one checkpoint, basic validation.

**Phase 2 gate**: end-to-end record of `examples/desktop-chat.json` produces `.webm`, `.gif`, `.mp4`, bridge transcript, validator PASS. A deliberately broken spec (missing required checkpoint) produces validator FAIL and no GIF.

### Phase 3: Validation extensions + diagnose integration

#### Step 1: Validator backend awareness

`bin/validate.mjs` branches on `spec.backend`. For `desktop`: read `bridge-transcript.jsonl` as primary input. `must_contain` / `must_contain_in_order` / `must_not_contain` apply against transcript text. Assert all `required: true` checkpoints appeared in spec-declared order. Assert last call is `rig.turn_end`.

#### Step 2: Soft-miss aggregation

`~/Library/Application Support/recording-rig/quality.jsonl` append on each run. Doctor warns if >20% over last N runs.

#### Step 3: Diagnose webm/transcript/trace forensics

Extend `commands/diagnose.md` skill: read transcript, webm metadata, sentinel timeline (always). Surface missing-checkpoint reports, soft-miss trends, capture-coverage check. **HAR cross-check and Playwright trace path are contingent on the Phase 2 HAR/trace sub-spike landing** (per round-2 finding `001-research-9` — `_electron.launch` doesn't accept these directly; Electron-context HAR/tracing feasibility is unvalidated). If the sub-spike fails or is deferred, diagnose ships without HAR/trace and the feature gap is documented in `commands/diagnose.md`.

**Phase 3 gate**: required-checkpoint failure produces no GIF; soft-miss only produces GIF + warning; diagnose surfaces both with usable forensic output.

### Phase 4: Code + CoWork surfaces (with chosen coordination providers)

#### Step 1: Surface support

Add `bin/desktop-selectors.json` entries for Code and CoWork surface inputs, sidebar nav, send. Driver navigates per `desktop.surface`.

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

Add subcommands: `--install-bridge` (build + install bridge MCPB), `--install-profile` (create Claude-Rig dir, interactive login wait), `--seed-from-primary` (auth-state copy), `--probe-surfaces` (per-surface MCP probe). Standard checks add Desktop-mode validations: Playwright installed, Electron-version compat, Claude.app present, profile exists, bridge installed, probe cache fresh (<30d).

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
| `playwright` (Node) | Apache 2.0 | Standard OSS |
| `ffmpeg` (system binary) | LGPL / GPL (depending on build) | Standard OSS |
| `gifski` (system binary) | AGPL-3.0 | Compatible with this project's AGPL-3.0-or-later license |
| Bridge MCPB Node runtime | Bundled with Claude Desktop (no separate install) | N/A |

## Test Plan

Test scenarios cover each phase's gate plus cross-cutting failure modes.

- **Scenario**: P0.1 probe outcome PASS → all three coordination providers degrade to `mcp-bridge` — **Verify**: spec with `coordination: "auto"` on Code resolves to `mcp-bridge` per doctor's cached probe.
- **Scenario**: P0.1 probe outcome FAIL → Code coordination resolves to `file-mtime-watch` — **Verify**: same spec resolves differently; preflight rejects gated specs targeting Code.
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
   **Expected**: A1–A8 each marked Verified or Unverified-with-reason; decisions §Technical Design §11 and §Alternative 7 locked.

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
| `_electron.launch({ executablePath, args, cwd, env, timeout })` — five-option signature only | playwright (v1.59+) | Source Search (Context7 `/microsoft/playwright` `docs/src/electron-api/class-electron.md`); round-2 finding `001-research-9` corrects earlier sketch that included `recordVideo`/`recordHar`/`tracesDir` (those belong to `browser.newContext()`) |
| `page.screencast.start({ path, fps })` / `.stop()` (per-page, not launch option) | playwright (v1.59+) | Source Search (Context7); `001-research-13` confirms v1.59.0 release date |
| `electronApp.firstWindow()`, `windows()`, `.on('window', ...)`, `.evaluate()` | playwright | Source Search (Context7); `001-research-19` requires `windows()` + `'window'` event for install-dialog detection |
| `context.tracing.startHar()` / `.start()` on a context derived from the Electron app | playwright | **Sub-spike required** (Phase 2) — feasibility for Electron contexts unvalidated per `001-research-9`; defer or drop HAR/trace if spike fails |
| `_electron.launch` against Claude.app v1.8555.2 (Electron 41.6.1) with `playwright >= 1.59.0` | playwright + electron | Documented (`001-research-13`: blocker `microsoft/playwright#39008` fixed in v1.58.1 by PR #39012); Spike P0.5 reduced to launch verification |
| `.mcpb` manifest v0.4 schema | mcpb | Source Search (`github.com/modelcontextprotocol/mcpb/blob/main/MANIFEST.md`, `001-research-18` notes transport is implementation-defined, not spec-mandated) |
| Bridge tool callability per surface | claude-desktop | Spike (P0.1 for Code; `001-research-14` already Documents the P0.2/CoWork race) |

### Scope Verification

Minimum Viable Validation is defined under [Implementation Plan / Minimum Viable Validation](#minimum-viable-validation). In scope for Phase 2 — end-to-end Chat recording with required-checkpoint enforcement and deliberate-fail reproduction. Not deferred.

### Cross-Cutting Concerns

- **Versioning**: Bridge MCPB version + Desktop bundle version pinned in `bin/desktop-selectors.json` and `probe-cache.json`. Doctor warns on Desktop version drift. New Desktop backend triggers `recording-rig` major-version bump (v0.2.0).
- **Build tool compatibility**: Bridge ships as Node MCPB (Node bundled with Claude Desktop). Driver is Node ES module. No new build toolchain.
- **Licensing**: All new dependencies (Playwright, ffmpeg, gifski) compatible with `AGPL-3.0-or-later`. gifski is AGPL-3.0 — same family.
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
- [Playwright Electron API](https://playwright.dev/docs/api/class-electron) — `_electron.launch` (five-option signature), `page.screencast.start/stop`, `electronApp.firstWindow()` / `windows()` / `.on('window', ...)`.
- [Playwright issue #10369](https://github.com/microsoft/playwright/issues/10369) — closed "not planned": cannot attach to running Electron process.
- [Playwright issue #39008 + PR #39012](https://github.com/microsoft/playwright/issues/39008) — Electron 30+ `--remote-debugging-port=0` blocker; fixed in v1.58.1 (2026-01-30); informs A4 Playwright >= 1.59.0 pin.
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
