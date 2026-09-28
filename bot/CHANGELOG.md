# Changelog — the bot

All notable changes to the code under `bot/` (the bridge, the MCP assistants,
the Teams app). The installer stamps the version into what it installs.

## Unreleased

- **The web chat installs as an app** (ADR 0029): under the chat's own name and with its own icon — the title's initial on `LIBRECHAT_APP_COLOR`, drawn by the run with Pillow from the agent's venv — and with a button at the top of the page: in Chrome and Edge it opens the browser's own install dialog, in Safari (iPhone, iPad, Mac), which has no install button, it shows the two steps. Gone in the app itself, once installed, or once dismissed. LibreChat's page is now always derived from the pinned image (title, application and home-screen name, manifest, icons, the app's and the scanner's tags), and a page the image no longer matches stops the run — before, a failed derivation would have written an empty page. The manifest and icons live under `hermes-app/` with a versioned address, because LibreChat's service worker precaches its own manifest. Tests: the page derived and refused, the manifest, the icons drawn once in every size, the version, and the button driven through in a stand-in DOM (Chrome, Edge, iPhone, iPad, Mac, Firefox, dismissed, in the app)

- **A scanned PDF from the web chat reaches the bot as pictures** (ADR 0029, a sixth carried patch on top of the fifth): a PDF page without text is rendered (pypdfium2 and Pillow from the agent's own venv, at most 2000 px, the first 20 pages) and cached like a photo, and the note names the pictures and `vision_analyze`. A scan gets a note of its own instead of the gateway's "extract the text yourself"; a mixed PDF keeps it and gets pictures of its scanned pages; a PDF with text is unchanged. Before, the Secretary filed two scans correctly only after two minutes: `read_file` "needs OCR", no `pdftoppm`, no PyMuPDF, two approvals nobody could give in the web chat. Tests with real rendering in the agent's venv: a scan, a text PDF, a mixed one, a long one, a broken one, the same scan sent twice

- **The web chat's scanner edits pages, cuts several sheets from one shot, and makes several PDFs** (ADR 0029): a tap on a page no longer deletes it but opens it — turn, crop again on the kept shot, filter "Document" (the page divided by its own paper: white wherever it lies, shadow or not, ink dark) or colour, move earlier or later, take again (the next shot replaces it), delete. The cut lay inside the page: a shot is now measured again on itself at twice the preview's resolution — no shift from a hand that moved — and cut with a margin of 2% of the page's shorter side; the detector's sizes and edge thresholds scale with the frame. Several sheets in one shot become several pages in reading order: beside the largest, every sheet inside none of the others that is brighter than the band around it. "New document" starts the next PDF, and "Done" hands one PDF per document to LibreChat's input at once. Tests: every sheet of twelve scenes at both sizes (three receipts, two letters side by side) and never a wrong one, the filter on paper in light and shadow, the margin, the reading order, the documents, and the screen driven through once in a stand-in DOM (a stuck edit or a page appended instead of replaced fails it)

- **The web chat's scanner finds the page on a light desk, and asks for the corners when it does not** (ADR 0029): it saw the edges of a letter only on a dark desk. jscanify's single pass is replaced by the worker's own: after a closing takes text and folds out, edges at three sensitivities and seven brightness levels — the colour saturation when those see nothing — and only a convex quadrilateral with plausible corners, off the frame's border, counts; corners ordered around their centre, so a turned page keeps its top. On ten test scenes (light wood, a folded letter, a turned page, soft shadow, beige and brown desks, a white desk) it finds 9 against jscanify's 4, within 3 px, in about 30 ms a frame. The outline shows once two frames agree and follows the page smoothly. A shot without a page opens a still with four corners to drag and a loupe, instead of an uncropped page. jscanify is no longer downloaded; the installer removes what the scanner no longer uses. Tests: the scenes with the real OpenCV, the corner order, the stale file removed

- **The web chat's scanner works on the phone** (ADR 0029): it opened with the camera running but stayed at "Loading", and not even Cancel answered. OpenCV.js's module is a thenable whose `then()` calls back with itself; the loader resolved a promise with it, which resolves again forever and held the page's thread. The image work now runs in a Web Worker (`scan-worker.js`, served and versioned with the scanner) that polls for OpenCV instead. The scanner opens as a modal `<dialog>`; "Capture" works as soon as the camera runs (uncropped and marked amber until detection is ready); the line at the top says what is loading or what failed; every question to the worker has a timeout, and a worker that failed is started again on the next opening. The worker does jscanify's contour search itself and frees every contour — this OpenCV build never frees a dropped handle, and jscanify's left 1136 of 1137 behind per frame on a busy desk. Tests boot the worker with the real libraries in a worker's own scope (the old loader hangs it) and count the contours left behind

- **A document scanner in the web chat** (ADR 0029, `LIBRECHAT_SCANNER`): a button next to the paperclip opens the camera with the page's edges drawn live; each shot is straightened and cropped, and "Done" hands one PDF to LibreChat's own upload. jscanify and its OpenCV.js build (MIT) are downloaded pinned by checksum and loaded only when the scanner opens; the PDF is written by the scanner itself (one JPEG page each, A4 wide). LibreChat is not rebuilt — its page, derived from the pinned image each run, gets one script tag, and the scanner's files are served next to its own

- **Photos and documents from the web chat arrive as files** (ADR 0029): a fifth carried patch to the agent's API server caches LibreChat's image data URLs and `file` parts with the gateway's own `cache_media_bytes` and tells the bot where the file is, in the gateway's own words — the Secretary reads a PDF or files a photographed receipt from the web as from Teams; photos stay visible to the model; resends are cached once; requests up to 40 MB, files up to 25 MB. LibreChat: images (camera included), PDF, Office and text up to 25 MB, photos shrunk to 3072 px, no resending, and the context gauge shows the bot's real window (it assumed ~32k for an unknown model)

- **LibreChat in front of selected bots** (ADR 0029): a `web` channel per bot — the agent's own API server on loopback, a minted key, the bot's toolset (`platform_toolsets.api_server`) — and a new `librechat` module: LibreChat v0.8.7, MongoDB and Meilisearch in containers on the host network, bound to 127.0.0.1, one unit, the tunnel's `chat.<zone>` in front. Sign-in through Entra only: the azure module creates the app, a security group, the members and the assignment; LibreChat checks the group again from the ID token. Each web bot is one picker entry; each chat is its own agent session (`X-Hermes-Session-Id` = LibreChat's conversation id); LibreChat's own tools and title generation are off. The docker module now installs the engine for LibreChat too. Teams, mail and cron unchanged

- Bridge: **the model searches the web itself** (ADR 0028, bridge version 3). `--builtin-tools` / `AGY_SHIM_BUILTIN_TOOLS` (default `search_web`) names the CLI's own tools the model may use inside its turn; the agent definition lists exactly those (`tools: [search_web]`), `commandExecutionPolicy: off` stays, and any name outside the read-only pair `search_web`, `read_url_content` is refused at startup. The tool contract, the project instructions and both reminders now say what is enabled instead of "the web is disabled" — and no longer point at the TOOL PROTOCOL that ADR 0027 deleted. Each lookup is logged (`built-in search_web done: <query>`); `/stats` shows `builtin_tools`. Over ACP a built-in is allowed when its permission title is exactly `Run <name>?` for a configured name. Probed headless first: a current, sourced answer in 25.6 s; the tools server keeps working beside it, also in the same turn; commands stay unreachable. `tool_contract` lost its dead `native` parameter.
- Installer: on a bot whose every endpoint is the bridge, the agent's own `web_search` is subtracted (`agent.disabled_toolsets: [search]`) — it ran on keyless Firecrawl and a third of the news bot's searches came back 403. `web_extract` stays. `read_url_content`, when enabled, gets the CLI's `read_url(*)` rule
- Installer: a bot's toolset now covers **mail and cron** as well as Teams (`platform_toolsets.email` / `.cron`); unset, both ran on the agent's full default with a terminal, and the news briefing fetched RSS feeds with `curl`, one of them frozen since January 2025. And each bot gets its own list — the per-bot pass had been handing a bot the previous bot's (news ran on search's)
- Installer: the mail poll interval reaches the adapter — it reads `EMAIL_POLL_INTERVAL` from `.env` only, so the YAML key left every bot at 15 s: 20 IMAP logins a minute through the relay until Exchange throttled them. Default now 60 s (`CHANNEL_EMAIL_POLL_INTERVAL`)

- Bridge: **past tool output is capped again, machine output only** — a regression fix from the news bot on 2026-09-14. Move 1 (ADR 0027) stopped cutting anything, but on a research bot that left dozens of full scraped pages in the session, and over ACP the context grew until a turn took one to two minutes and Teams answers stopped being delivered. A PAST `tool result` entry is now capped to its opening (`PAST_TOOL_RESULT_CAP`, 6000 chars) in `split_history`; the LIVE result the model is answering and ALL human content — mails, messages — stay whole. Measured: a turn carrying 320k chars of scraped history went from ~80 s to 5 s. Also: the ACP path never delivers a bare `pending` (the tools server's internal handoff marker) to the user, and a session is retired after 40 turns so it reseeds from bounded history rather than growing without end.

- Bridge: an **ACP backend** (`AGY_SHIM_BACKEND=acp`, ADR 0027 move 3). Instead of driving the `agy` CLI per conversation, it runs one long-lived official `agy_acp_server` and gives each conversation a session over ACP (Agent Client Protocol, JSON-RPC on stdio): one process for every bot, context that survives a restart, and no per-request history resend — the gateway still sends the whole history, so a lost session is simply reseeded from it. The caller's tools reach the model as the `tools` MCP server named in `session/new`; the built-ins are refused by the client's `session/request_permission`, and an allowed `tools_*` call is the turn's decision. Measured live: the full tool loop in 7.0 s + 1.5 s, identity held, streaming intact. Default stays `print`; the agyshim module checks for the server binary and its OAuth token when acp is chosen and says what is missing rather than downloading 2 GB or seeding a credential itself. `tools_mcp.py` gained `AGY_TOOLS_DIR` so one server process serves every bot's own toolset.

- Bridge: **nothing in the transcript is cut any more** (ADR 0027, move 1). The 6,000-character cap that applied to every single entry is gone, and so is the 120,000-character budget across all of them and `AGY_SHIM_HISTORY_BUDGET` with them. The cap was written for scraped pages and hit everything — a long mail, a long message from the operator — replacing the rest with a count. What bounds the prompt now sits where the information is: the agent framework, which owns the conversation and has `session_reset` per bot, and the CLI, which compacts at a token threshold it can measure. The framing stays: it says which part of the text is the question, which is a different job from deciding what the model may read
- Bridge: **the text tool protocol is gone** (ADR 0027, move 2), with `parse_decision` and its hundred lines of rescue — envelopes abandoned mid-object, a stray token between two attempts, arguments encoded as a string with the quotes unescaped, a nested envelope one level too deep. A decision never becomes text now: the CLI reports a completed call to the tools server as a structured event and it travels as an object to the response. `AGY_SHIM_NATIVE_TOOLS` is gone too, because there is no second channel to select — the bridge refuses to start when the tools server is not registered, rather than degrading quietly at the first turn that needs a tool
- Config: `AGENT_SESSION_RESET` defaults to `none`; a bot whose questions stand on their own sets its own (`BOT_<KEY>_SESSION_RESET`). A daily reset cut threads that were still running, and it did nothing for the case that actually fills a window

- Assistants: the token store survives two writers — an exclusive lock over the whole read-modify-write, the file re-read under it, a merge that starts from disk so a stale holder cannot overwrite a newer refresh, a temp file nobody else can name, fsync before the rename (`m365.token` has two holders, and losing a refresh token costs a manual sign-in)
- Bridge: one CLI process kept warm per bot — keyed by model, system prompt and toolset, which is what a spare has to carry — so a request stops paying the 2.3 s a start costs (measured 3.5 s cold against 1.2 s warm); `AGY_SHIM_MAX_SPARES` bounds the shelf and the reaper retires what nobody came back for
- Bridge: an optional bearer token on `/v1` (`AGY_SHIM_AUTH`), minted by the run into a 0600 file the unit names; `/healthz` stays open and reports the bridge's version. The endpoint refuses to start unauthenticated anywhere but loopback, and validation names any declared caller that would not present the token

- Bridge: the transcript is background and bounded — headed `BACKGROUND ONLY`, each entry capped, the newest kept within `AGY_SHIM_HISTORY_BUDGET` characters (120000) and the rest replaced by a count; the live message is headed `=== THE MESSAGE TO ANSWER NOW ===` and a tool-result turn restates the user request it serves. The news bot answered three different questions with the same earlier summary: one turn of `curl` research had left ~90 entries of HTML behind it and the question was one line of a 155k-token request (2026-09-10, ADR 0026)
- Installer: a role's own text decides its default toolset — News and Search run on `web [browser] memory session_search clarify cronjob todo`, no terminal and no files, which is what their role files say and what stops a news desk from researching with `curl | grep` (`BOT_<KEY>_TOOLSET` still decides)
- Teams: carried adapter patch — a question with options arrives as a list, not as one run of prose (the options were visible on the phone but not distinguishable, let alone answerable, 2026-09-09); the numbers stay, so "reply with 2" still works
- Bridge: independent calls the model makes in one turn travel together as parallel tool calls instead of costing a full round trip each (a GitHub report spent twelve turns of 75k tokens on one call apiece, 2026-09-09)
- Bridge: a turn decided through the tools server is allowed to end (grace 45 s) instead of being cut short, so its token counts reach the log and the caller — the first live turn reported none (2026-09-09); a turn decided through the *rejected* native channel still ends at once, there being nothing to wait for

## 0.4.0 — 2026-09-09

- Bridge: the caller's functions reach the model as REAL tools — an MCP server (`bot/agy-shim/tools_mcp.py`) the CLI spawns per conversation, registered with the CLI by the run together with its allow rule; a completed call to it is the decision, the framework still executes. Ends the "improperly formatted function call" retries that cost about half the subscription's turns since 2026-09-07 (ADR 0024, `AGY_SHIM_NATIVE_TOOLS`)
- Bridge: a decision the model abandoned and rewrote (two envelopes glued with a stray token) yields the rewrite; arguments encoded as a string — escaped or with unescaped quotes — are decoded (a Search answer reached the chat as raw JSON, 2026-09-08)

## 0.3.0 — 2026-09-08

- Tasks bot (`bot/roles/tasks.md`, MCP server `bot/mcp/tasks_assistant.py`, module `assistant`): tasks per tenant in Microsoft Planner — one plan in a Microsoft 365 group the run creates (`ASSISTANT_TASKS_*`; owner the operator, member the agent's account, optionally a Team), one bucket per tenant, every card assigned to the operator; `tasks_add` demands start and due date; `tasksctl status|tenants|due|digest`; the Secretary files deadlines as cards in its own bucket; scope `Tasks.ReadWrite` added and consented by the run
- Installer: `AGENT_CRON_DRIFT_GUARD` (default false) — reminders fire after a provider or model change instead of being skipped as "drift"

- Installer: `CHANNELS_COMMAND_ALLOWLIST` / `BOT_<KEY>_COMMAND_ALLOWLIST` record "Always allowed" approval categories in configuration (union with what the chat added)

- Teams: `/help` shows a short page per bot (name, one-line summary, five commands) from `bot/help.md.tpl`; the agent's developer list stays behind `/help all` (carried gateway patch); every role starts with a `> summary` line

- Admin bot: every change carries a read-only host snapshot (`opsctl snapshot`) and Claude Code may run read-only host commands (journals, status, the assistants' listings)

- Google assistant: the same drop folders in Drive (`google_drive_inbox`, `google_drive_file`, `googlectl inbox`); `inboxctl` lists both sides for the cron monitor
- Microsoft 365 assistant: drop folders `<root>/<World>/Inbox` (created by the run), `m365_drive_inbox`, `m365_drive_file` (move, rename, twin in one call), `m365ctl inbox` as a cron monitor; the Secretary files what the operator shares from the phone via OneDrive

- Housekeeping: per-bot `work/` directory as the terminal's cwd and TMPDIR, tmpfiles rules age out scratch and download folders, the bridge sweeps stale working directories at start, the persona forbids writing into home or /tmp

- Balance proxy (`bot/api-proxy/balance_proxy.py`, module `apiproxy`): the remaining API balance appended to every final answer of a bot on DeepSeek or Moonshot (`BOT_<KEY>_LLM_BALANCE`)

- Teams: carried adapter patch — a pasted URL rendered as a named link keeps its URL (`(link: …)`); M365 assistant: `m365_share_read` / `m365_share_download` open SharePoint and OneDrive links through Graph (`Files.Read.All`)
- Assistants: every document filed below the root gets a Markdown twin with its recognized text (`text_md`, refused without it for photos; PDFs extracted); `m365_drive_missing_text`, `m365_drive_download`, `m365ctl companions [--apply]`, `googlectl companions`
- Google assistant: the same worlds in Drive (`ASSISTANT_GOOGLE_ROOT_FOLDER` / `ASSISTANT_GOOGLE_WORLDS`, default the M365 values); `googlectl ensure-folder`, `migrate-worlds`, `move`
- Microsoft 365 assistant: private and business worlds below the root folder (`ASSISTANT_M365_WORLDS`), suffix per world enforced by the drive tools; `m365ctl migrate-worlds [--apply]` moves existing files

- Admin bot: `opsctl apply` writes a request and the root-side `hermes-ops-apply.path` runs the installer (the bots cannot escalate under NoNewPrivileges); `OPS_APPLY` auto/ask/never, `apply-status` shows the log
- Admin bot: `bot/roles/admin.md` and `opsctl` (module `ops`) — host state, update check, installer preview, and change requests that Claude Code turns into tested commits; the installer records its last run for it

- Bridge: a native call to a caller function (the CLI's `unknown tool` step) is taken as the decision; the retry after a malformed-call failure carries a plain-text reminder
- Installer: `AGENT_TOOL_SEARCH` (default off) puts MCP tools inline instead of behind the agent's meta-tools; per bot `BOT_<KEY>_TOOL_SEARCH`
- Installer: `BOT_<KEY>_TOOLSET` / `CHANNEL_TEAMS_TOOLSET` accept a list of the agent's toolsets — a bot without a terminal; the GitHub bot runs on `web memory session_search clarify cronjob todo`
- GitHub role: GitHub only through the `github_*` tools, never `gh`/`git` in the terminal
- Bridge: CLI agent mode (the system prompt in the CLI's own slot, its tools off), transient-failure retry, startup checks
- Roles: every bot translates; Search, News and GitHub directly (they run on the bridge), the Secretary — texts and documents — through `delegate_task` on the bridge
- Secretary role: every read of the operator's own mailboxes goes through `delegate_task`, so a bot on an API model reads them on the bridge (`BOT_<KEY>_DELEGATION_ENDPOINT`)
- Installer: bot units are ordered after the bridge and the mail relay; start timeout `SERVICE_START_TIMEOUT` (300 s) for a cold boot
- Installer: a persona change hands its restart to the channel pass — one restart per bot and run instead of two; what is still owed is restarted at the end
- Installer: `--only` / `--skip` / `--list-modules` to run part of it; per-module timing at the end; agent config keys are read before the agent's CLI is asked to set them (seconds per key per bot saved)
- Installer: the model block sets `base_url` explicitly (empty for a hosted provider) — the vendor's aggregator default in config.yaml otherwise hijacked a bot moved to a hosted provider
- Installer: bots restart when their MCP servers' code or env changed (stamp per bot); server commands via runuser, no nested sudo (the paste-back sign-in hung under sudo-rs use_pty)
- Assistants: read-only access to the operator's own mailboxes — Exchange via Full Access delegation and `Mail.Read.Shared` (`mailbox` parameter), Gmail via a second read-only sign-in per account (`account` parameter)

## 0.2.3 — 2026-09-06

- GitHub bot: fourth Teams app, official GitHub MCP server, mail alias

## 0.2.2 — 2026-09-06

- Teams manifest: `supportsFiles` so the chat offers the attach button (letters, invoices, photos)

## 0.2.1 — 2026-09-06

- Secretary on a fresh bot identity so Teams names the chat after the app

## 0.2.0 — 2026-09-05

- three bots (Secretary, Search, News), each its own Teams app, profile and service
- version bump for all three packages at once

## 0.1.1 — 2026-09-05

- Teams app id derived from the bot's client id (no collision with earlier uploads)
- one package per bot (secretary, search, news) with the bot's name and hostname
- bridge: reminder once when the model reaches for a denied built-in tool
- Microsoft 365 assistant MCP server (mail, calendar, meetings with roles, OneDrive)

## 0.1.0 — 2026-09-05

- agy bridge with tool calling through the tool contract
- Teams app manifest and icons generated from configuration
