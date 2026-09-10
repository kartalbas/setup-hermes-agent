# The Antigravity CLI (agy) as the model bridge — research, 2026-09-06

Multi-agent research (5 finders, 12 adversarial verifications, 1 synthesis) on how far the CLI can be used as a headless model backend under the hard constraint *subscription only, no API key*. Legend: [V] verified · [L] likely · [U] unverified. Companion to ADR 0017 and ADR 0021.


Legend: **[V]** verified (primary source or command output reproduced during verification) · **[L]** likely (strong secondary evidence or consistent inference) · **[U]** unverified.

## 1. Is agy open source?

**No [V].** `agy` is a closed-source, stripped Go binary built from Google's internal monorepo (`google3/third_party/jetski/...` symbol paths, toolchain `go1.28-20260721-RC01 cl/951519500`), distributed as a prebuilt tarball from GCS via a Cloud Run manifest server (`antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json`; the installed `~/.local/bin/agy` sha256 `93eb2118…` matches the published 1.1.27 tarball). The GitHub repo `google-antigravity/antigravity-cli` has `license: null`, `languages: {}`, no LICENSE and no `.go` files — only README, CHANGELOG, issue templates and statusline/title examples; the winget manifest says `License: Proprietary`; the gemini-cli issue "Antigravity CLI — is it open source?" was closed `not_planned` without a Google reply. The only Apache-2.0 component is the Python SDK wrapper `google-antigravity` (0.1.16, 2026-09-02), which bundles a 129 MB stripped Go `localharness` binary in platform wheels and authenticates **only** via `GEMINI_API_KEY`/Vertex ADC (zero OAuth client IDs, zero subscription-tier strings in the binary) — so it is excluded by the operator constraint [V]. Relationship to gemini-cli: agy is a **rewrite, not a fork** (gemini-cli is TypeScript/Apache-2.0; agy is Go) [V]; consumer Free/Pro/Ultra access via gemini-cli was cut on 2026-06-18 (endpoint returns HTTP 410) [V], so agy is the sole subscription-backed client. agy talks to the same Code Assist backend family (`cloudcode-pa.googleapis.com`, `aicode.googleapis.com`, `businessaicode.googleapis.com`) with its own OAuth client/scopes [V]. Compliance: Antigravity Additional Terms item 6 forbids "third party software, tools, or services to access the Service (e.g. using OpenClaw with Antigravity OAuth)" [V, verbatim 420/420 chars]; whether a wrapper that only spawns the official binary falls under it is **unanswered by Google** (forum topic 178472, 0 replies; two similar questions unanswered; one non-Google forum user says it's fine) [V that it is unanswered; the legal reading is U]. Every OpenAI-compatible Antigravity proxy found reuses the OAuth token directly and has produced bans [V]; Hermes upstream's native `antigravity` provider (PR #50454) does the same and must not be used [V].

## 2. Capabilities not yet used by the bridge

| Capability | Invoked via | Evidence | What it gives the bridge |
|---|---|---|---|
| `--disable-slash-commands` | flag | [V] `agy --help` 1.1.27 | Chat text starting with `/` (Teams `/help`, `/start`) is otherwise expanded as slash command/skill in print mode; unrecognized commands still burn a turn (issue #778). Shim does not pass it. |
| `--print-timeout` | flag (default 5m0s) | [V] `--help`; scope in stream-json [U] | Independent CLI-side ceiling; shim's `--timeout 300` collides exactly with the default. |
| `--log-file <path>` | flag | [V] `--help` | Fixed per-process log path for journald/logrotate instead of `~/.gemini/antigravity-cli/cli.log`. |
| `denied_actions[]` in `result` | automatic (1.1.27) | [V] CHANGELOG 1.1.27; struct tags `tool_name/resource/reason/permission/action` in binary; element shape [L] | Deterministic "model reached for a built-in tool" signal; shim currently ORs it with a `"permission" in stderr` heuristic. |
| `init.permission_mode`, `init.agent`, `init.json_schema` | automatic | [V] headless doc | Fail-fast assertion at spawn (expected `request-review`, expected agent). Shim reads only `model`/`tools`. |
| Custom main agent | `--agent <name>`; `~/.gemini/config/agents/<name>.md` or `<cwd>/.agents/agents/<name>.md`; frontmatter `tools`, `commandExecutionPolicy`, `inheritCustomizations`, `subagent`, `rules`, `model` | [V] docs/blog/CHANGELOG 1.1.1/1.1.6/1.1.14/1.1.25; body "compiles directly into its system prompt" [V, Google wording]; whether it REPLACES the hard-coded "You are Antigravity Agent…" section [U]; honoured in stream-json [U]; local probe found only via `--add-dir`, not cwd [V] | Real system-prompt slot for Hermes identity/tool contract; possibility to strip built-in tools (`tools: []`) and skills from every fresh conversation (~14k tokens). Binary has `SECTION_OVERRIDE_MODE_{OVERRIDE,APPEND,PREPEND}` + `CustomAgentSystemPromptConfig` [V] → replacement is plausible [L]. |
| Hooks: `PreInvocation` → `injectSteps[{ephemeralMessage}]` | `~/.gemini/config/hooks.json` or `<cwd>/.agents/hooks.json`; `sh -c` handler, JSON stdin/stdout, 30 s timeout | [V] built-in `agy-customizations/docs/hooks.md`; fires in stream-json mode [U] | Transient system message before **every** model call — authority independent of transcript position (the ADR 0021 failure mode). |
| Hooks: `PreToolUse` → `{"decision":"deny","reason":…}` / `overwrite` | same | [V] docs; fails closed on any malformed output/`{}` [V, cmux #5358]; env vars don't reach the hook [L] | Explicit denial with a reason the model sees, replacing the shim's re-send-operating-context round trip; arg rewriting (e.g. path redirection for images). |
| `.agents/rules/*.md` with `trigger: always_on` | files in cwd | [V] built-in docs, 12,000-char cap per rule file [V, IDE docs; applies to AGENTS.md? L] | Several deduplicated always-on blocks; deterministic ordering = prompt-cache-stable. Shim already writes a single `AGENTS.md`. |
| `--json-schema '<json>'` | flag | [V] `--help`, headless doc ("only applicable to the final result" in stream-json); per-turn behaviour in a warm process [U] | Provider-enforced `{type: final\|tool_call, …}` envelope → removes prose-unwrap heuristics. Caveat: absent when a tool was denied (#794). |
| Model catalog + effort | `agy --output-format json models`; `--effort low\|medium\|high`; `-low/-medium` slugs | [V] local run | Startup validation of `AGY_SHIM_MODELS`; cheaper aliases for routine turns (Flash ≈ 8× cheaper than Pro in quota terms [V, plans doc]). |
| `AGY_CLI_DISABLE_AUTO_UPDATE=true` | env | [V] troubleshooting doc, binary string | Pins the backend version. **Shim's env filter (HOME/PATH/USER/LOGNAME/LANG/TERM only) drops it even if the unit sets it** [V, agy_shim.py lines 113-115]. |
| Plugin packaging | `~/.gemini/antigravity-cli/plugins/<name>/{plugin.json,rules/AGENTS.md,hooks.json,agents/}`; `agy plugin validate` | [V] docs | One versioned "hermes" unit mirrored by bootstrap.sh/install.sh instead of ad-hoc AGENTS.md. |
| `/usage` `/quota` `/credits` in print mode | `agy -p /usage --output-format json` | non-interactive answers exist [V, CHANGELOG 1.1.11/1.1.12]; JSON shape [U] | Quota probe for the bots' health page. |
| `--sandbox`, `toolPermission: proceed-in-sandbox` | flag / settings.json | [V] docs; never with `--dangerously-skip-permissions` (#36) | Only relevant if a narrow CLI-executed capability is ever opted in; not for current design. |
| MCP (`agy mcp add`, `mcp_config.json`) | CLI/file | [V]; loads in headless [U] | Executes outside Hermes approval; adds tool defs to every conversation — keep empty (it is). |
| Statusline JSON (`quota.remaining_fraction`, `reset_in_seconds`, `plan_tier`, `cost`) | settings `statusLine` command | [V] statusline doc; interactive only [L] | Not usable headless; listed for completeness. |

## 3. Ranked improvement proposals for bot/agy-shim (subscription only, no API key)

1. **Pass `--disable-slash-commands` by default** (spawn cmd, `AgentProcess.__init__`). Effect: user text beginning with `/` reaches the model as text. Risk: none known. Verify: bats test sending `/help` and asserting the response is model text, `num_turns` 1, no `command` field in the envelope. [V flag exists]
2. **Use `denied_actions` as the primary intercept signal; log its full shape once.** Replace `"permission" in detail.lower() or result.get("denied_actions")` with `denied_actions` first, stderr heuristic as fallback. Effect: no false positives from unrelated stderr text. Risk: element field names are inferred from struct tags [L]. Verify: one deliberate turn asking the model to run `ls`; dump `result["denied_actions"]` at INFO.
3. **Treat #902/#944/#947 failure modes as retryable, and bound shutdown.** `SUCCESS` with empty response and no `denied_actions` → retry once on a fresh process; `CANCELED`/`WAITING` without client cancel → retry; stderr "authentication timed out" → one retry after 2–5 s; on `close()` wait ≤10 s then SIGKILL (already partly there — add a hard kill after `terminate` timeout and check for lingering sockets). Effect: ~10% of long tool-using turns stop surfacing as user-facing errors. Risk: doubled quota on genuine failures — cap at one retry. Verify: inject a fake `result` via test harness; observe in production logs the retry count.
4. **Set `AGY_CLI_DISABLE_AUTO_UPDATE=true` in the systemd unit AND whitelist it in the shim's env filter; log `agy --version` at startup.** Effect: backend can no longer change under the bridge (1.1.26 introduced the #947 hang). Risk: operator must run `agy update` deliberately (document in README). Verify: `ls ~/.gemini/antigravity-cli/updater/` mtime stops advancing; startup log shows version. Mirror in bootstrap.sh/install.sh per repo rule.
5. **Custom main agent `hermes` (`--agent hermes`), body = operating context, `tools: []`, `commandExecutionPolicy: off`, `subagent: false`, `inheritCustomizations: false`.** Effect if it works: identity in the real system-prompt slot, no 57-tool/14k-token preamble, no subagent fan-out. Risk: [U] whether body replaces or appends; whether `tools: []` means none; whether `.agents/` in cwd needs `trustedWorkspaces` (probe suggests yes — put the agent under `~/.gemini/config/agents/` instead, or pass `--add-dir`). Verify: experiment E2 below (one turn per variant); assert `init.agent == "hermes"` and `len(init.tools)`.
6. **PreInvocation hook injecting `ephemeralMessage` = system prompt; PreToolUse hook with `matcher: ".*"` returning `deny` with a reason.** Effect: authority on every model call regardless of summarisation; explicit denial reason instead of the REMINDER re-send. Risk: [U] whether hooks fire in stream-json; hooks fail closed — any schema error denies everything; hook cost `sh -c` per call; ~/.gemini/config/hooks.json is global for the Unix user (fine: dedicated user). Verify: experiment E1; keep hook script exit-0 with a valid JSON always.
7. **`--json-schema` union envelope** `{oneOf:[{type:"final",text},{type:"tool_call",name,arguments}]}` per process. Effect: `structured_output` replaces prose-unwrap heuristics. Risk: "final result only" in stream-json [V] — fine for stateless one-turn-per-process, [U] for the pre-warmed pool; absent on denied-tool turns (#794) → keep fallback. Verify: E3.
8. **Cheaper model aliases + startup catalog check.** Validate `AGY_SHIM_MODELS` against `agy --output-format json models` at boot; expose `gemini-3.8-flash-low/medium` as aliases for routine chat. Effect: quota stretch; fail-fast on catalog changes. Risk: low. Verify: unit test with the JSON fixture; `usage.thinking_tokens` drop on `-low`.
9. **Assert `init.permission_mode == "request-review"`** and refuse to serve otherwise (a stray settings.json `toolPermission: always-proceed` would let the CLI execute commands). Risk: none. Verify: unit test on init event.
10. **State-dir retention job**: age-based cleanup of `~/.gemini/antigravity-cli/{conversations,brain,annotations,presence}` (213 brain entries already) + `cli.log` rotation. Risk: deleting a conversation the pool is still using — scope to entries older than idle-timeout×N. Verify: `du -sh` before/after.
11. **Image placement**: ensure image files are inside the CLI workspace (cwd — already `mkdtemp` in workdir) and removed after the turn; never leave a stale path in the prompt (#826). Verify: turn with image → no `denied_actions` for `view_file`.
12. **Document ToS item 6 risk in an ADR** (operator decision): single account, no token reuse, no parallel account pools, rate-limit bursts. [V that it's undecided by Google]

## 4. Ultra quota / cost facts

- One shared Gemini pool per plan, "drawn down as per API pricing": X Pro tokens ≡ 8X Flash tokens, any linear combination [V, plans doc].
- Ultra tiers: $100/mo = 5× Pro's rate limit, $200/mo = 20× (2026-05-19) [V]; window "refreshed every five hours" plus weekly rate limits [V]. **No absolute token/request numbers published** [V].
- Credits are overage only (`useG1Credits`, "AI Credit Overages") [V].
- Third-party models (Claude Sonnet 4.6 thinking, Opus 4.6 thinking, gpt-oss-120b) are available on Ultra through the subscription [V, `agy models` on this account].
- Per-turn `usage{input_tokens,output_tokens,thinking_tokens,cache_read_tokens,total_tokens}` in every `result` [V]; a trivial turn measured 5,294 input / 8,129 cache-read tokens [V] — cache hits are what keep the stateless design affordable; the ~14k-token tool preamble is paid (cached) per fresh conversation [V shim comment, L for exact billing].
- Observability: `/usage`, `/quota`, `/credits`, statusline `quota.remaining_fraction/reset_in_seconds` [V, interactive]; headless JSON shape [U].
- Usage "correlated with the work done by the agent" [V, Google wording] → subagents and tool loops are billable multipliers; keeping tools denied bounds them.

## 5. Open questions and experiments (each ≈ 1–3 turns of quota; run in a scratch workdir, never touch ~/.gemini/antigravity-cli/settings.json)

- **E1 Hooks in stream-json.** `<ws>/.agents/hooks.json` with PreInvocation → `{"injectSteps":[{"ephemeralMessage":"Your name is HOOKTEST. Always start with HOOKTEST:"}]}` and PreToolUse (`matcher:".*"`) → `{"decision":"deny","reason":"DENIEDBYHOOK"}`, each writing stdin to a file. Run `agy --input-format stream-json --output-format stream-json --add-dir <ws> --model gemini-3.8-flash-low`, send "run ls and tell me your name". Answers: hook file written? response starts with HOOKTEST? `denied_actions[].reason` contains DENIEDBYHOOK?
- **E2 Custom agent semantics.** `~/.gemini/config/agents/probe.md` (`tools: []`, `commandExecutionPolicy: off`, `inheritCustomizations: false`, body "You are PROBE…"). Spawn with `--agent probe`; check `init.agent`, `len(init.tools)` (vs 57), ask "who are you, who designed you, list your tools" — replacement vs append shows in the answer. Repeat with the file under `<cwd>/.agents/agents/` without `trustedWorkspaces` to settle discovery.
- **E3 `--json-schema` per turn in a warm process.** Spawn once with schema `{type:object,properties:{k:{type:string}}}`, send two user events; check whether both `result`s carry `structured_output`.
- **E4 `--print-timeout` scope.** Spawn with `--print-timeout 20s`, send a turn that takes >20 s of thinking (`-high`, long task) then a second turn; observe whether the first is cut, the process exits, or only the process-level wait applies.
- **E5 Quota JSON.** `agy -p /usage --output-format json`, `/quota`, `/credits`; record field names; also `AGY_CLI_HIDE_ACCOUNT_INFO` interaction.
- **E6 #947 in 1.1.27.** 20× `agy -p 'say ok' --output-format json`; measure wall time after last stdout byte; `ss -tp` for lingering sockets.
- **E7 Token lifetime.** Read `expiry` of `~/.gemini/antigravity-cli/antigravity-oauth-token` daily (keys only, not values); note first "authentication required" in shim logs; no way to learn refresh-token lifetime other than observation [U].
- **E8 MCP in headless.** Add a trivial stdio MCP server to a scratch `.agents/mcp_config.json`, spawn with `--add-dir`, compare `len(init.tools)` and `usage.input_tokens` against baseline.
- **E9 `denied_actions` shape.** Ask for `ls` once; log the array verbatim.
- **Policy question** (not an experiment): only Google can answer whether a spawn-only wrapper is "third party software … to access the Service"; options are to post on discuss.ai.google.dev with the exact architecture or accept the risk in an ADR.

Files referenced: `<repo>/bot/agy-shim/agy_shim.py` (spawn cmd lines 105-116, env filter 113-115, denied handling 231-253, close 256-270), `<repo>/config/hermes.conf:80` (`AGY_SHIM_MODELS`), `~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/{hooks,rules,json_configs,plugins}.md`, `~/.local/bin/agy` (1.1.27).

## Experiments run 2026-09-07 (results)

- **E2 custom agent** — `.agents/agents/probe.md` (`tools: []`, `commandExecutionPolicy: off`, `inheritCustomizations: false`), spawned with `--agent probe --add-dir <ws>` in stream-json: `init.agent = probe`, the answer was "PROBE: I am PROBE, a private assistant bot … I have no tools." (identity replaced, no vendor mention), a request to run `ls -la` produced no tool step and no `denied_actions` ("I do not have access to a shell execution tool"), input tokens 2,286 vs ≈5,300 with the default agent. `init.tools` still lists 57 entries — the list is global, the agent cannot use them. **Adopted**: the bridge writes the caller's system prompt as the agent definition per request (bot/agy-shim, "agent mode", default on).
- **E1 hooks in stream-json** — `PreInvocation`/`PreToolUse` in `<ws>/.agents/hooks.json` (with `--add-dir`) and in `~/.gemini/config/hooks.json`: neither handler ran (no log written, `denied_actions` unchanged). Not usable headless as far as tested.
- **E3 `--json-schema` in stream-json** — two turns in one process with `--agent probe`: `structured_output` was `None` on both. Not adopted.
- **Startup checks** — `agy --version` prints `1.1.27`; `agy --output-format json models` returns a JSON list (the bridge logs the catalog size; 0 entries means the format changed).
- Observed once in agent mode: `result.status != SUCCESS` with error "Your previous response contained an improperly formatted function call" — the model emitted a native call although the agent has no tools; treated as transient (one retry on a fresh process).
- **Native calls survive `tools: []`** (2026-09-07): `manage_task` stays callable under `tools: []`, `allowedTools: []` and a `permissions` deny (probed, three variants), so the model can always emit native function calls. On a long GitHub transcript it called the caller's `terminal` natively — parseable → CLI step `unknown tool`; unparseable → `Your previous response contained an improperly formatted function call … Retries remaining: 3` → `result.status = ERROR` after three CLI-internal retries. Bridge answer: take the parseable native call as the decision and end the one-shot turn; retry the malformed case once with a plain-text reminder.

## Experiments run 2026-09-09 (E8: MCP tools in headless agent mode) — results

Setup: an isolated HOME (token copied, removed afterwards), `~/.gemini/config/mcp_config.json` with one stdio server ("probe": `web_search`, `tasks_add`, `note_add`, built on `assistant_common.McpServer`), agent `probe` with `tools: []`, model gemini-3.8-flash-high, one turn per variant, 9 turns in total.

- **MCP tools ARE loaded headless, also under `--agent … tools: []`** [V]. The model calls them natively through the CLI's generic `call_mcp_tool` (`step_update.tool_info.parameters = {ServerName, ToolName, Arguments}`); `init.tools` still lists the CLI's 57 built-ins and no MCP tool, so the init event says nothing about MCP. Input per turn 7.5k tokens (agent mode) vs 14.2k (no agent).
- **Without an allow rule the CLI auto-denies the call** (`denied_actions=[{action: mcp}]`, stderr "headless mode cannot prompt for the mcp permission", result SUCCESS with empty response) — the call and its arguments are still visible in the ACTIVE step [V]. `permissions.allow: ["mcp(<server>/*)"]` in settings.json makes the CLI execute it; the wildcard works [V].
- **The model picks the tool on its own** from an indirect question ("Was hat der Bundesrat heute entschieden?") [V], and chains calls within one turn once they execute (two searches, then the answer) [V].
- **First attempt with several arguments often arrives with `Arguments: {}`**; the server's validation error ("missing required 'tenant'") makes the model retry correctly within the same turn (+~1k tokens) [V, 3 of 4 multi-argument calls]. A single-argument tool (`web_search`) arrived complete every time. Consequence: an interceptor must not take an empty ACTIVE call as the decision; let the server validate and answer, take the first call whose arguments satisfy the schema.
- **`tools/list` is asked once at process start**, never per turn [V] — a process's toolset is fixed for its life; pre-warmed spares must be per toolset (hash of the request's tool list), a stateful process per conversation has it naturally.
- **The MCP server inherits the CLI's cwd** — the per-conversation workdir the bridge creates — so one global `mcp_config.json` entry serves every bot: the server reads `tools.json` from its cwd [V]. `agy … models` spawns the MCP servers as well (harmless).
- **`tools: [<mcp tool names>]` in the agent frontmatter kills the agent** ("Agent execution terminated due to error") — keep `tools: []` [V].
- **Zero "improperly formatted function call" in 9 turns with tools** (the live bridge: 140 in the two days before) [V, small sample].

Design that follows (proposed, ADR pending): the bridge exposes the request's tools to the CLI as an MCP server ("tools", one global entry, per-workdir `tools.json`), an allow rule `mcp(tools/*)` written by the installer, the server validates arguments against the schema and the bridge takes the first valid `call_mcp_tool` as the decision — stateless: end the request and close the one-shot process; stateful: the server answers "handed to the caller" and the bridge discards the model's closing words. The text TOOL PROTOCOL becomes the fallback only.

## Stateful against stateless, measured 2026-09-10 (A/B, cold cache)

The assumption this repository has carried since the bridge was written — that a
living CLI process is markedly cheaper per turn than a fresh one — is **false under
today's code**. The same ten-turn conversation, same system prompt, same tools, same
canned tool results, against two private bridge instances that served nothing else:

| | stateless | stateful | |
|---|---|---|---|
| requests | 15 | 14 | |
| input tokens, total | 293,070 | 748,272 | **+155%** |
| marginal (input − cached) | 293,070 | 748,272 | **+155%** |
| average per request | 19,538 | 53,448 | **+174%** |
| output tokens | 43,678 | 44,122 | +1% |
| wall clock | 188 s | 105 s | **−44%** |

- **Stateful grows monotonically and then compacts.** Input per request went 3.8k,
  13.5k, 26k, 40k, 49k, 59k, 66k, 88k, 100k, 113k, 127k — the CLI keeps the whole
  conversation in its own context and re-sends it every turn — then fell to 14k at
  turn 9 when `--compact-at 120000` fired, a 60-second turn that bought the drop.
- **Stateless stays bounded** because the transcript it sends is trimmed to a budget
  (`trim_history`). It oscillates with the size of the last tool result and never
  climbs.
- **The old figures in `agy_shim.py`'s header (5,863 against 14,120 on turn 3)
  predate both the transcript trimming and agent mode.** They are no longer the
  system being described. The header should say so.
- **Identity held in BOTH modes**, at turns 1, 5 and 10, with no vendor name and no
  register slip. That is the failure ADR 0021 abolished the stateful pool for, and
  agent mode has closed it — so the reason to stay stateless is now cost, not drift.
- **Stateful is much faster**: no process spawn per request, 2 to 5 seconds against
  5 to 20. If latency ever matters more than quota, this is the lever.

**The caveat, and it is not small.** `cached` was 0 on every single request in both
modes: two cold instances, prefixes nobody had sent before. Production shows the
stateless path running at `cached ≈ in`. This run therefore compares the two modes
with the cache switched off by accident, and whether a warm prefix changes the
ranking is unmeasured. Repeating the identical A/B immediately afterwards, when both
prefixes are warm, is one more run of about thirty turns and would settle it.

Conclusion for now: **do not adopt the stateful pool for cost.** It is the wrong
direction by a factor of two and a half on the numbers we have. Keep `--stateful`
where it is, behind the flag, as the latency option.
