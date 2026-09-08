# 0023 — Tasks live in Microsoft Planner, not in To Do and not in a store of the bot's own

Date: 2026-09-08 · Status: accepted

## Context

The operator wants a bot that turns one sentence — "<tenant> neuer Task: …
<reference>" — into a task under a tenant (a customer, a project), asks for a
start and a due date, reminds, and reports what is open per tenant. The
operator already lives in Microsoft Planner and To Do on the phone; whatever
the bot keeps must be visible there, and the tenants must be created by the
bot on the operator's word, not by hand.

Three places could hold the tasks:

- **A store of the bot's own** (SQLite plus a Markdown mirror per tenant in
  OneDrive). Fully under the bot's control, no new permission — and invisible
  to Planner and To Do unless mirrored, which means two truths.
- **Microsoft To Do.** Lists as tenants, tasks with native reminders that push
  on the phone. But To Do lists live in a *mailbox*: the agent's account
  writes into its own lists, not the operator's. Reaching the operator's lists
  needs either the application permission `Tasks.ReadWrite.All` — read and
  write over every mailbox in the tenant, with an app secret on the host — or
  one list per tenant shared by hand from the agent's account, which ends
  "tenants on the bot's word". The Graph API has no call to share a list.
- **Microsoft Planner.** A plan lives in a Microsoft 365 group; buckets are
  free-form; a card can be assigned to a person, and an assigned card appears
  in that person's To Do under "Assigned to me" and in the Planner app. The
  delegated scope `Tasks.ReadWrite` on the agent's account suffices once the
  account is a member of the group. Planner sends no reminders of its own.

## Decision

1. **Planner is the store.** One plan in one Microsoft 365 group; one bucket
   per tenant; one card per task, assigned to the operator. The bot reads and
   writes only through Planner; nothing is kept in memory or files as a second
   truth.
2. **The run makes the group and the plan.** The azure module creates the
   Microsoft 365 group (the operator as owner and member, the agent's account
   as member; a Team on it when asked), records the group's id and the
   operator's object id in the secrets file — the run's write-back store,
   because the assistant's scopes cannot look up groups or users and must
   not —, and the assistant module creates the plan and the initial buckets
   as the agent's account.
3. **Start and due date are mandatory at the tool level.** `tasks_add`
   refuses a card without both; the role asks for what is missing. A tenant
   that does not exist is a question, not a bucket the bot invents.
4. **Alarms are the bot's.** A daily digest (`tasks_digest`) at 07:00 and
   one-shot reminders at a time of day — both `cronjob`s delivered into the
   Teams chat, which pushes on the phone. Planner's due dates are the data;
   the bot is the alarm.
5. **The Secretary uses the same plan.** Deadlines it reads off letters and
   invoices become cards in the bucket that carries its own name, so one
   digest covers everything.

## Consequences

- The operator sees and edits the same cards in Planner and To Do; the bot's
  next call reflects the edit. Nothing to synchronise.
- One more delegated scope on the mail app (`Tasks.ReadWrite`), one more
  admin consent, and the agent's account becomes a member of one group.
- Two ids in the secrets file that are not secrets; the file is the run's
  single write-back store, and the pattern already holds the bots' client ids.
- A card cannot be moved between plans by API. Cards created elsewhere are
  recreated through the bot or moved in the app.
- Planner's date model is day-granular in its UI; a time of day is kept on
  the card (the instant in UTC) and shown by the bot, not by Planner.

## Alternatives considered

- **To Do through the application permission.** Rejected: tenant-wide reach
  for one person's lists, and an app secret on the host that the bots do not
  otherwise hold.
- **To Do through shared lists.** Rejected: no API to share, so every new
  tenant is a manual step.
- **A store of the bot's own with a Markdown mirror.** Rejected once Planner
  proved to need one scope and one group: the mirror would have been a second
  truth the operator cannot edit.
