# 0026 — The transcript is background, and a role's tools follow its text

Date: 2026-09-10 · Status: accepted (refines 0021, the stateless bridge)

## Context

The news bot answered three different questions with the same summary of an
earlier one. Not a repetition bug: the model was answering the loudest thing in
the request, and the question was not it.

What the host showed (2026-09-10, session `…091227…` of the news profile):

- `agent.turn_context: … history=288 msg='<the new question>'` — one Teams DM
  session had grown to ~300 messages in a day, `tool_turns=130`.
- the bridge served that as `stateless … history=290 in=155160 cached=73668` —
  one request, ~155k tokens, of which the question was a single line at the end.
- almost all of it was raw HTML: the bot had researched with `terminal`
  (`curl … | grep`), one page per turn, ninety entries of it.
- inside such a loop the last message is a tool RESULT, not a question, so the
  end of the request does not even name what is being answered.

Two independent decisions produced that. First, ADR 0021 sends the whole chat
in every request and relies on position alone — an identity line before the
last message — to say what is live. Position is a weak signal when what
precedes it is 600k characters on one subject. Second, a bot's Teams toolset
defaulted to the vendor's `hermes-telegram` composite: the full personal set,
terminal and `write_file` included. `bot/roles/news.md` says "Use the web
tools" and "Never write files on this machine" — but a bot reaches for what it
has, and it had a shell.

## Decision

**The transcript is labelled as background and bounded.** It is headed
`BACKGROUND ONLY. None of it is the question`, each entry is capped at
`ENTRY_CAP` characters, and only the newest entries within
`AGY_SHIM_HISTORY_BUDGET` characters (default 120000) are sent; the rest are
replaced by a count. The live message gets its own heading,
`=== THE MESSAGE TO ANSWER NOW ===`. When that message is a tool result, the
user request it serves is restated above it, because it may be a hundred
entries back.

**A role's default toolset follows the role's own text.** `bot_role_toolset`
gives `news` and `search` the tools their role files describe — web, memory,
session search, clarify, cronjob, todo (search also the browser) — and no
terminal and no files. `BOT_<KEY>_TOOLSET`, and `CHANNEL_TEAMS_TOOLSET` set to
anything other than the built-in composite, still decide for the operator.

## Consequences

- A long research turn no longer poisons every later question in the same chat.
  The daily session reset (`AGENT_SESSION_RESET`) is no longer the only thing
  standing between a heavy day and a confused bot.
- Very old detail is lost to the model even though the agent still stores it:
  the bridge sends a count, not the content. `AGY_SHIM_HISTORY_BUDGET=0` sends
  everything, and is the way to get the old behaviour back.
- Fewer prompt tokens per turn on a long chat, and the cached prefix (the
  system block) is untouched — trimming happens in the user message.
- News and Search lose the ability to do anything on the host. That is the
  point; it is also a real reduction in what those two bots can do for an
  operator who was relying on the shell being there.
- The two roles' first run after this writes a new `platform_toolsets.teams`
  into their profiles: the `channels` module applies it.
