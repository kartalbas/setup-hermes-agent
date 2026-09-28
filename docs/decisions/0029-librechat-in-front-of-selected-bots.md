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
   A scan has no text layer (added the same day, after the first scans were
   filed): `read_file` answers "needs OCR", and `pdftotext`, which the agent's
   own page check uses, is not on the host. The Secretary filed both scans
   correctly, but only after two minutes of missing tools and two approvals
   nobody could give in the web chat. A sixth patch, on top of the fifth,
   renders every page without text (pypdfium2 and Pillow, already in the
   agent's venv; at most 20 pages, 2000 px) into a cached picture and names the
   pictures and `vision_analyze` in the note — the step the Secretary found
   last comes first. The operator chose this over OCR on the host: no new
   package, and the model sees the layout of a payment slip, not lines of text.

7. **A document scanner in the chat** (added 2026-09-28, the operator's choice
   over a scan step on the bot's side): a button next to the paperclip, the
   camera with the page's edges drawn live (OpenCV.js 4.7.0, Apache 2.0, pinned
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
   The image work runs in a Web Worker (`scan-worker.js`), never on the page:
   OpenCV.js's module is a thenable whose `then()` calls back with itself, so a
   promise resolved with it resolves again forever — the first version did that
   on the page, which froze on the phone with the camera running and not even
   "Cancel" answering. The worker polls for OpenCV instead, and its WASM start
   and its global `Module` stay out of the page. The scanner opens as a modal
   `<dialog>`; "Capture" works as soon as the camera runs, uncropped until the
   worker is ready.
   Finding the page (revised the same day, the operator's choice): jscanify's
   single pass — Canny at fixed high thresholds, the largest contour — saw the
   page on a dark desk only; on test scenes of a letter on light wood, folded,
   turned, on a white or coloured desk it found 4 of 10, some of them wrong.
   The worker now looks at each frame in several passes after a closing has
   taken text and folds out — edges at three sensitivities with their gaps
   closed, seven brightness levels, and the colour saturation when those see
   nothing — and counts only a convex quadrilateral with plausible corners
   that does not touch the frame's border: 9 of 10, within 3 px. jscanify is
   gone; its repository still supplies the pinned OpenCV build. The outline
   counts once two frames agree, and a shot without one opens a still with four
   corners to drag instead of being taken uncropped — a hard shadow across
   page and desk, which no global pass sees through, ends there. Every contour
   is freed: this OpenCV build never frees a handle that is dropped, and
   jscanify's search left about a thousand per frame on a busy desk.
   Editing and several documents (the operator's choices, the same day): the
   cut lay inside the page — the preview's corners come from a smaller copy of
   an older frame, and the inner edge of an outline can win — so a shot is
   measured again on itself at twice the preview's resolution (the detector's
   sizes and edge thresholds scale with the frame) and cut with a margin of 2%
   of the page's shorter side. Several sheets in one shot are several pages:
   beside the largest, every sheet that lies inside none of the others and is
   brighter than a band around it, as paper is on a desk. A tap on a page opens
   it instead of deleting it: turn, crop again on the kept shot, a "Document"
   filter (the page divided by its own paper, so a shadow goes), move, take
   again, delete. "New document" puts a break in the strip, and "Done" hands
   one PDF per document to the file input at once.

## Consequences

- Chats become the unit of context the operator manages: new chat, rename,
  search, continue. The bot's side of each chat is its own session.
- Every signed-in person sees every web bot, and a bot's memory
  (`USER.md`, `MEMORY.md`) and `session_search` are per bot, not per person —
  accepted by the operator for the test ("es ist egal, dass alle Entra-User
  alles sehen"). The personal bots act with the operator's accounts.
- Editing or regenerating a message in LibreChat does not rewrite the agent's
  history of that chat, which is loaded from the agent's store.
- A file is only as readable as the bot's tools make it: the Secretary reads
  documents, photos and scans and files them — creating the tasks they call
  for itself — while the Tasks bot stays lean, without file or vision tools in
  the web chat. Documents go to the Secretary (the operator's choice,
  2026-09-28).
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
