# 0029 — LibreChat in front of selected bots, beside Teams

Date: 2026-09-28 · Status: accepted (built as a test with two bots) · Adds a channel to 0024/0026; leaves Teams, mail and cron as they are

## Context

Teams gives each bot one long conversation. For the bots whose work runs in
threads — the Tasks bot per tenant and project, the Secretary per letter or
appointment — that became the limit: one context for everything, reset by
hand or by a timer, and "the last N messages" as the only memory of the
thread in hand. The operator wanted what a chat UI gives: a list of chats,
each its own context, named, found again, continued; in the browser and on
the phone; signed in with the company's Entra accounts, for a group of
people rather than for everyone in the tenant.

Two facts decided the shape:

- **The agent already speaks the protocol a chat UI needs.** Its `api_server`
  platform offers OpenAI chat completions with opt-in session continuity
  (`X-Hermes-Session-Id`, history loaded from the agent's own store) and
  starts as soon as `API_SERVER_KEY` is set. No adapter is needed, and the bot
  stays the bot: its persona, its tools, its memory, its model — one brain
  behind Teams, mail and the web.
- **LibreChat can hand its conversation id to that header.** Custom endpoint
  headers resolve `{{LIBRECHAT_BODY_CONVERSATIONID}}`, and in v0.8.7 the id
  is generated before the model client is built (`ResumableAgentController`
  writes it into `req.body` first), so the first message of a new chat already
  carries the id its later messages will carry. Every LibreChat chat is
  therefore one agent session, with its whole tool history.

The operator narrowed it on 2026-09-28: a test with the Tasks bot and the
Secretary; Teams and all six bots stay as they are; digests stay in Teams;
general questions go to the Gemini app, not to a chat on the bridge.

## Decision

1. **`web` is a channel**, like `teams` and `email`: a bot with it gets its
   agent's API server on loopback (`BOT_WEB_PORT_BASE` + index), a key minted
   into the secrets file (`HERMES_WEB_<KEY>_KEY`), the model name set to the
   bot's key, and `platform_toolsets.api_server` set to the bot's toolset —
   unset, the platform would run with the agent's full default set, terminal
   and files included. Dropping the channel removes the key, and the agent
   stops the listener.
2. **LibreChat runs in containers on loopback**: LibreChat, MongoDB (with a
   password) and Meilisearch, pinned, on the host network, each bound to
   127.0.0.1, nothing published; one systemd unit (`compose up`/`down`). The
   docker module installs the engine for it. The tunnel publishes
   `LIBRECHAT_HOSTNAME` (default `chat.<zone>`) to it, like the bots' webhooks.
3. **Sign-in is Entra only.** The azure module creates the app (redirect,
   `groups` and `email` claims), a security group (`<prefix>-bots`), keeps the
   configured members in it, assigns the group to the app and sets "assignment
   required". LibreChat allows no local accounts and checks the same group
   again from the ID token (`OPENID_REQUIRED_ROLE`).
4. **The bots are the only thing to pick.** One custom endpoint and one model
   spec per web bot, specs enforced; LibreChat's own tools (web search, code,
   file search, agents, memory, presets, parameters) off; no title generation
   (it would be an extra agent run per chat).
5. **Nothing else moves.** Teams, mail, cron and the six bots are unchanged;
   notifications stay in Teams — a page cannot push.

6. **Photos and documents arrive as files** (added 2026-09-28, after the first
   test: uploads failed). LibreChat's "Upload to Provider" sends a photo as an
   `image_url` data URL and a PDF as `{"type": "file", "file": {"filename",
   "file_data"}}`; the agent's API server showed the photo to the model without
   keeping it and refused the PDF. A carried patch (the fifth, like the Teams
   and mail adapter patches) caches both with the gateway's own
   `cache_media_bytes`, tells the agent where the file is in the gateway's own
   words, keeps the photo visible, dedupes resends, and raises the request
   limit to 40 MB (25 MB a file). LibreChat allows images, PDF, Office and text
   up to 25 MB, shrinks photos to 3072 px, does not resend earlier files, and
   shows each bot's real context window (`tokenConfig`, from the bot's
   `LLM_CONTEXT_WINDOW`) instead of its ~32k guess for an unknown model name.

7. **A document scanner in the chat** (added 2026-09-28, the operator's choice
   over a scan step on the bot's side): a button next to the paperclip, the
   camera with the page's edges drawn live (jscanify on OpenCV.js, MIT, pinned
   by checksum, loaded on first use), each shot straightened and cropped, and
   the pages handed to LibreChat's own hidden file input as one PDF — the same
   path as a file picked with the paperclip, so item 6 carries it to the bot.
   LibreChat is not rebuilt: its server reads `client/dist/index.html` once
   and serves `client/dist` statically, so the run mounts the page with one
   script tag more (derived from the pinned image each run) and the scanner's
   directory beside it. No CSP stands in the way (LibreChat sends none), and
   the service worker caches assets, not the page. The DOM hooks it relies on
   — `#attach-file-menu-button` and the file input beside it — are checked
   again on every LibreChat upgrade; without them the PDF is downloaded instead.

## Consequences

- Chats become the unit of context the operator manages: new chat, rename,
  search, continue. The bot's side of each chat is its own session.
- Every signed-in person sees every web bot, and a bot's memory
  (`USER.md`, `MEMORY.md`) and `session_search` are per bot, not per person —
  accepted by the operator for the test ("es ist egal, dass alle Entra-User
  alles sehen"). The personal bots act with the operator's accounts.
- Editing or regenerating a message in LibreChat does not rewrite the agent's
  history of that chat, which is loaded from the agent's store.
- About 1–1.5 GB of RAM for the three containers; images about a gigabyte.
- LibreChat's data (chats, accounts) lives in its Docker volumes, outside the
  agent's backup; `--purge` removes them on uninstall.

## Alternatives considered

- **LibreChat talking to the bridge directly, with its own agents.** Two
  brains, bot definitions twice, and none of the bots' tools (mail, Planner,
  M365) without rebuilding them in LibreChat. Rejected.
- **A direct chat on the bridge for everything else.** Considered and dropped
  by the operator: general questions go to the Gemini app, on the operator's
  own subscription, without sharing it through the bridge.
- **The agent's own session commands in Teams** (`/title`, `/resume`,
  `/sessions`, `/branch`) — available and useful, but a chat list is what was
  asked for.
- **Open WebUI and others.** LibreChat was chosen earlier (2026-09): Entra
  sign-in with a group check, model specs, header placeholders, PWA, active
  maintenance.
