#!/usr/bin/env python3
"""Tasks assistant — an MCP server over Microsoft Planner.

One plan in a Microsoft 365 group; one bucket per tenant (a customer, a
project, or a bot's own); one card per task, assigned to the operator so it
shows up in their Planner and To Do apps. The server acts as the agent's own
account — the same token as the Microsoft 365 assistant, with the
Tasks.ReadWrite scope the installer adds — and never as the operator.

    tasks_assistant.py status                  the plan, its buckets and their open cards; exit 1 when the plan is missing
    tasks_assistant.py ensure-plan [BUCKETS]   create the plan in the group and the comma-separated buckets (the installer)
    tasks_assistant.py tenants                 the buckets, one per line
    tasks_assistant.py due                     what is overdue, due today or starting today — one line each, sorted
    tasks_assistant.py digest                  the same as JSON, with the week ahead
    tasks_assistant.py tools | serve           the tool list; MCP over stdio (what the gateway runs)

Environment: the M365_* variables of the Microsoft 365 assistant, plus
    M365_TASKS_GROUP_ID     the Microsoft 365 group that owns the plan
    M365_TASKS_PLAN         the plan's title
    M365_TASKS_ASSIGNEE     the operator (sign-in address, named in the tools' text)
    M365_TASKS_ASSIGNEE_ID  the operator's directory object id (Planner assigns by id)

Dates: a card's start and due dates are stored the way Planner's own UI
stores a date picked without a time — 10:00 UTC of that day — so they show
as that calendar day everywhere. A time given by the operator is interpreted
in M365_TIMEZONE and stored as that instant.
"""

from __future__ import annotations

import json
import os
import sys
from datetime import date, datetime, timedelta, timezone
from typing import Any, Dict, List, Optional
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from assistant_common import HttpError, McpServer, env_required, log  # noqa: E402
from m365_assistant import GRAPH, Auth, Graph  # noqa: E402

VERSION = "0.1.0"
ASSIGNMENT = {"@odata.type": "#microsoft.graph.plannerAssignment", "orderHint": " !"}
PRIORITY = {"urgent": 1, "important": 3, "medium": 5, "low": 9}
DATE_MARK = "T10:00:00Z"   # a date without a time, as Planner's UI writes it


# ---------------------------------------------------------------------------
# Dates — pure, tested on their own
# ---------------------------------------------------------------------------

def to_utc(value: str, tz: str) -> str:
    """'2026-09-30' -> that day at Planner's date marker; '2026-09-30T14:00'
    (local time in TZ) or an offset-carrying timestamp -> the instant in UTC."""
    v = (value or "").strip()
    if not v:
        raise ValueError("a date is needed (YYYY-MM-DD, or YYYY-MM-DDTHH:MM for a time of day)")
    if len(v) == 10:
        date.fromisoformat(v)
        return v + DATE_MARK
    s = v.replace("Z", "+00:00")
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=ZoneInfo(tz))
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def local_when(iso_utc: Optional[str], tz: str) -> Optional[str]:
    """What Planner holds, for the operator: 'YYYY-MM-DD' for a date-only
    card, 'YYYY-MM-DD HH:MM' (local time) when the card carries a time."""
    if not iso_utc:
        return None
    base = iso_utc.strip().split(".")[0].rstrip("Z")
    dt = datetime.fromisoformat(base).replace(tzinfo=timezone.utc)
    if (dt.hour, dt.minute, dt.second) == (10, 0, 0):
        return dt.strftime("%Y-%m-%d")
    return dt.astimezone(ZoneInfo(tz)).strftime("%Y-%m-%d %H:%M")


def _day(when: Optional[str]) -> Optional[date]:
    return date.fromisoformat(when[:10]) if when else None


def priority_label(value: Any) -> str:
    try:
        p = int(value)
    except (TypeError, ValueError):
        return "medium"
    if p <= 1:
        return "urgent"
    if p <= 4:
        return "important"
    if p <= 7:
        return "medium"
    return "low"


def task_shape(t: Dict[str, Any], bucket_names: Dict[str, str], tz: str, description: Optional[str] = None) -> Dict[str, Any]:
    pc = int(t.get("percentComplete") or 0)
    out: Dict[str, Any] = {
        "id": t.get("id"), "title": t.get("title"), "tenant": bucket_names.get(str(t.get("bucketId")), "?"),
        "start": local_when(t.get("startDateTime"), tz), "due": local_when(t.get("dueDateTime"), tz),
        "status": "done" if pc >= 100 else ("in progress" if pc > 0 else "open"),
        "priority": priority_label(t.get("priority")),
        "created": (t.get("createdDateTime") or "")[:10] or None,
    }
    if pc >= 100:
        out["completed"] = (t.get("completedDateTime") or "")[:10] or None
    if description is not None:
        out["description"] = description
    return out


def classify(tasks: List[Dict[str, Any]], today: date) -> Dict[str, List[Dict[str, Any]]]:
    """Open cards by what they mean today: overdue, due today, starting today,
    due within the week. Sorted by due date, tenant, title — stable, so two
    listings of the same state compare equal."""
    groups: Dict[str, List[Dict[str, Any]]] = {"overdue": [], "today": [], "starting": [], "week": []}
    for t in tasks:
        if t.get("status") == "done":
            continue
        d, s = _day(t.get("due")), _day(t.get("start"))
        if d and d < today:
            groups["overdue"].append(t)
        elif d and d == today:
            groups["today"].append(t)
        elif d and d <= today + timedelta(days=7):
            groups["week"].append(t)
        if s and s == today:
            groups["starting"].append(t)

    def key(t: Dict[str, Any]):
        return (t.get("due") or "9999-99-99", t.get("tenant") or "", t.get("title") or "")
    return {k: sorted(v, key=key) for k, v in groups.items()}


def due_lines(groups: Dict[str, List[Dict[str, Any]]]) -> List[str]:
    """One line per card that needs the operator's attention today — no
    timestamps, so the lines change only when the state does."""
    lines: List[str] = []
    for label, key in (("overdue", "overdue"), ("today", "today"), ("starts", "starting")):
        for t in groups.get(key) or []:
            when = t.get("start") if key == "starting" else t.get("due")
            lines.append(f"{label:<8} {when or '':<16} {t.get('tenant')} | {t.get('title')}")
    return lines


def compose_description(reference: Optional[str], notes: Optional[str]) -> str:
    parts = []
    if reference and reference.strip():
        parts.append(f"Reference: {reference.strip()}")
    if notes and notes.strip():
        parts.append(notes.strip())
    return "\n\n".join(parts)


# ---------------------------------------------------------------------------
# Planner
# ---------------------------------------------------------------------------

class Planner:
    def __init__(self, graph: Graph, group_id: str, plan_title: str, assignee: str, assignee_id: str, tz: str):
        self.graph, self.group_id, self.plan_title = graph, group_id, plan_title
        self.assignee, self.assignee_id, self.tz = assignee, assignee_id, tz
        self._plan: Optional[Dict[str, Any]] = None

    # -- the plan -----------------------------------------------------------
    def _paged(self, path: str, params: Optional[Dict[str, Any]] = None) -> List[Dict[str, Any]]:
        out: List[Dict[str, Any]] = []
        r = self.graph.call("GET", path, params=params)
        while True:
            out.extend(r.get("value") or [])
            nxt = r.get("@odata.nextLink")
            if not nxt:
                return out
            r = self.graph.call("GET", nxt)

    def find_plan(self) -> Optional[Dict[str, Any]]:
        if self._plan is None:
            for p in self._paged(f"/groups/{self.group_id}/planner/plans"):
                if (p.get("title") or "").casefold() == self.plan_title.casefold():
                    self._plan = p
                    break
        return self._plan

    def plan(self) -> Dict[str, Any]:
        p = self.find_plan()
        if p is None:
            raise RuntimeError(f"no plan named '{self.plan_title}' in the group; the installer creates it (tasksctl ensure-plan)")
        return p

    def ensure_plan(self) -> bool:
        """The plan exists afterwards; True when it was created now."""
        if self.find_plan() is not None:
            return False
        try:
            self._plan = self.graph.call("POST", "/planner/plans", json_body={
                "container": {"url": f"{GRAPH}/groups/{self.group_id}"}, "title": self.plan_title})
        except HttpError as e:
            if e.status == 403:
                raise RuntimeError(f"Planner refuses to create the plan (HTTP 403): {self.graph.auth.account} must be a member of the group, "
                                   "and a membership added minutes ago has not reached Planner yet — run the installer again later") from None
            raise
        return True

    # -- buckets = tenants --------------------------------------------------
    def buckets(self) -> List[Dict[str, Any]]:
        items = self._paged(f"/planner/plans/{self.plan()['id']}/buckets")
        return sorted(items, key=lambda b: (str(b.get("orderHint") or ""), str(b.get("name") or "")))

    def bucket_names(self) -> Dict[str, str]:
        return {str(b["id"]): str(b.get("name") or "") for b in self.buckets()}

    def bucket(self, name: str) -> Dict[str, Any]:
        wanted = (name or "").strip().casefold()
        found = [b for b in self.buckets() if (b.get("name") or "").casefold() == wanted]
        if not found:
            have = ", ".join(b.get("name") or "" for b in self.buckets()) or "none yet"
            raise RuntimeError(f"no tenant named '{name}'; tenants: {have}. Add one with tasks_tenant_add when the operator confirms it is new")
        return found[0]

    def bucket_ensure(self, name: str) -> Dict[str, Any]:
        try:
            return dict(self.bucket(name), created=False)
        except RuntimeError:
            b = self.graph.call("POST", "/planner/buckets", json_body={"name": name.strip(), "planId": self.plan()["id"], "orderHint": " !"})
            return dict(b, created=True)

    def bucket_rename(self, name: str, new_name: str) -> Dict[str, Any]:
        b = self.bucket(name)
        return self.graph.call("PATCH", f"/planner/buckets/{b['id']}", json_body={"name": new_name.strip()},
                               headers={"If-Match": b.get("@odata.etag") or "*"}, prefer="return=representation")

    # -- cards ---------------------------------------------------------------
    def tasks(self, tenant: Optional[str] = None, status: str = "open") -> List[Dict[str, Any]]:
        names = self.bucket_names()
        wanted_bucket = self.bucket(tenant)["id"] if tenant else None
        out = []
        for t in self._paged(f"/planner/plans/{self.plan()['id']}/tasks"):
            if wanted_bucket and t.get("bucketId") != wanted_bucket:
                continue
            shaped = task_shape(t, names, self.tz)
            if status == "open" and shaped["status"] == "done":
                continue
            if status == "done" and shaped["status"] != "done":
                continue
            out.append(shaped)
        return sorted(out, key=lambda t: (t.get("due") or "9999-99-99", t.get("tenant") or "", t.get("title") or ""))

    def task(self, task_id: str) -> Dict[str, Any]:
        t = self.graph.call("GET", f"/planner/tasks/{task_id}")
        d = self.graph.call("GET", f"/planner/tasks/{task_id}/details")
        return task_shape(t, self.bucket_names(), self.tz, description=d.get("description") or "")

    def _details_set(self, task_id: str, description: str) -> None:
        d = self.graph.call("GET", f"/planner/tasks/{task_id}/details")
        self.graph.call("PATCH", f"/planner/tasks/{task_id}/details", json_body={"description": description},
                        headers={"If-Match": d.get("@odata.etag") or "*"})

    def task_add(self, tenant: str, title: str, start: str, due: str, notes: Optional[str] = None,
                 reference: Optional[str] = None, priority: Optional[str] = None) -> Dict[str, Any]:
        bucket = self.bucket(tenant)
        body: Dict[str, Any] = {
            "planId": self.plan()["id"], "bucketId": bucket["id"], "title": title.strip(),
            "startDateTime": to_utc(start, self.tz), "dueDateTime": to_utc(due, self.tz),
            "assignments": {self.assignee_id: dict(ASSIGNMENT)},
        }
        if priority:
            body["priority"] = PRIORITY[priority]
        created = self.graph.call("POST", "/planner/tasks", json_body=body)
        description = compose_description(reference, notes)
        if description:
            self._details_set(created["id"], description)
        out = task_shape(created, {bucket["id"]: bucket.get("name") or tenant}, self.tz, description=description or None)
        out["assigned_to"] = self.assignee
        return out

    def task_update(self, task_id: str, title: Optional[str] = None, tenant: Optional[str] = None,
                    start: Optional[str] = None, due: Optional[str] = None, priority: Optional[str] = None,
                    status: Optional[str] = None, notes: Optional[str] = None, reference: Optional[str] = None) -> Dict[str, Any]:
        current = self.graph.call("GET", f"/planner/tasks/{task_id}")
        patch: Dict[str, Any] = {}
        if title and title.strip():
            patch["title"] = title.strip()
        if tenant:
            patch["bucketId"] = self.bucket(tenant)["id"]
        if start:
            patch["startDateTime"] = to_utc(start, self.tz)
        if due:
            patch["dueDateTime"] = to_utc(due, self.tz)
        if priority:
            patch["priority"] = PRIORITY[priority]
        if status == "done":
            patch["percentComplete"] = 100
        elif status == "open":
            patch["percentComplete"] = 0
        if self.assignee_id not in (current.get("assignments") or {}):
            patch["assignments"] = {self.assignee_id: dict(ASSIGNMENT)}
        updated = current
        if patch:
            updated = self.graph.call("PATCH", f"/planner/tasks/{task_id}", json_body=patch,
                                      headers={"If-Match": current.get("@odata.etag") or "*"}, prefer="return=representation") or current
        description = None
        if notes is not None or reference is not None:
            old = self.graph.call("GET", f"/planner/tasks/{task_id}/details").get("description") or ""
            description = compose_description(reference, notes if notes is not None else old)
            self._details_set(task_id, description)
        return task_shape(updated, self.bucket_names(), self.tz, description=description)

    def task_done(self, task_id: str) -> Dict[str, Any]:
        return self.task_update(task_id, status="done")

    def task_delete(self, task_id: str) -> Dict[str, Any]:
        current = self.graph.call("GET", f"/planner/tasks/{task_id}")
        self.graph.call("DELETE", f"/planner/tasks/{task_id}", headers={"If-Match": current.get("@odata.etag") or "*"})
        return {"deleted": True, "id": task_id, "title": current.get("title")}

    # -- the day -------------------------------------------------------------
    def today(self) -> date:
        return datetime.now(ZoneInfo(self.tz)).date()

    def digest(self) -> Dict[str, Any]:
        groups = classify(self.tasks(status="open"), self.today())
        return {"date": self.today().isoformat(), **groups}

    def tenants(self) -> List[Dict[str, Any]]:
        open_tasks = self.tasks(status="open")
        today = self.today()
        out = []
        for b in self.buckets():
            mine = [t for t in open_tasks if t.get("tenant") == (b.get("name") or "")]
            out.append({"tenant": b.get("name"), "open": len(mine),
                        "overdue": sum(1 for t in mine if _day(t.get("due")) and _day(t.get("due")) < today)})
        return out


# ---------------------------------------------------------------------------
# The tools
# ---------------------------------------------------------------------------

def build_server(planner: Planner) -> McpServer:
    who = planner.assignee or "the operator"
    srv = McpServer(
        name="tasks-assistant", version=VERSION,
        instructions=(f"The operator's tasks in Microsoft Planner: one plan ('{planner.plan_title}'), one bucket per TENANT "
                      f"(a customer, a project, or a bot's own bucket), one card per task, every card assigned to {who} so it "
                      "shows in their Planner and To Do apps. A task always belongs to a tenant and always carries a start and a "
                      "due date — ask for what is missing (today is a valid start). Dates: YYYY-MM-DD, or YYYY-MM-DDTHH:MM "
                      f"for a time of day in {planner.tz}. What these tools return is what Planner holds; the operator sees the "
                      "same cards in the Planner app."))

    DATE = {"type": "string", "description": "YYYY-MM-DD, or YYYY-MM-DDTHH:MM for a time of day"}
    PRIO = {"type": "string", "enum": sorted(PRIORITY), "description": "urgent, important, medium (default) or low"}

    @srv.tool("tasks_tenants", "The tenants (buckets) of the plan with their open and overdue cards.", {"properties": {}})
    def tasks_tenants() -> Any:
        return planner.tenants()

    @srv.tool("tasks_tenant_add", "Add a tenant (a bucket) — only when the operator confirms it is new; existing names are matched case-insensitively.",
              {"properties": {"name": {"type": "string"}}, "required": ["name"]})
    def tasks_tenant_add(name: str) -> Any:
        b = planner.bucket_ensure(name)
        return {"tenant": b.get("name"), "created": b.get("created")}

    @srv.tool("tasks_tenant_rename", "Rename a tenant; its cards stay where they are.",
              {"properties": {"name": {"type": "string"}, "new_name": {"type": "string"}}, "required": ["name", "new_name"]})
    def tasks_tenant_rename(name: str, new_name: str) -> Any:
        b = planner.bucket_rename(name, new_name)
        return {"tenant": b.get("name") or new_name, "renamed_from": name}

    @srv.tool("tasks_add", f"Create a card for a tenant, assigned to {who}: title in the operator's words, start and due date (both required — ask "
              "when missing), optional notes and a reference (ticket or case number, also good at the end of the title).",
              {"properties": {"tenant": {"type": "string"}, "title": {"type": "string"}, "start": DATE, "due": DATE,
                              "notes": {"type": "string"}, "reference": {"type": "string", "description": "a ticket, case or document number"},
                              "priority": PRIO},
               "required": ["tenant", "title", "start", "due"]})
    def tasks_add(tenant: str, title: str, start: str, due: str, notes: Optional[str] = None,
                  reference: Optional[str] = None, priority: Optional[str] = None) -> Any:
        return planner.task_add(tenant, title, start, due, notes=notes, reference=reference, priority=priority)

    @srv.tool("tasks_list", "Cards of one tenant or of all, open by default; sorted by due date.",
              {"properties": {"tenant": {"type": "string"}, "status": {"type": "string", "enum": ["open", "done", "all"]}}})
    def tasks_list(tenant: Optional[str] = None, status: str = "open") -> Any:
        return planner.tasks(tenant=tenant, status=status)

    @srv.tool("tasks_get", "One card with its description.", {"properties": {"task_id": {"type": "string"}}, "required": ["task_id"]})
    def tasks_get(task_id: str) -> Any:
        return planner.task(task_id)

    @srv.tool("tasks_update", "Change a card: title, tenant, dates, priority, status (open/done), notes or reference. Only what is given changes.",
              {"properties": {"task_id": {"type": "string"}, "title": {"type": "string"}, "tenant": {"type": "string"},
                              "start": DATE, "due": DATE, "priority": PRIO, "status": {"type": "string", "enum": ["open", "done"]},
                              "notes": {"type": "string"}, "reference": {"type": "string"}},
               "required": ["task_id"]})
    def tasks_update(task_id: str, **changes: Any) -> Any:
        return planner.task_update(task_id, **changes)

    @srv.tool("tasks_done", "Mark a card done.", {"properties": {"task_id": {"type": "string"}}, "required": ["task_id"]})
    def tasks_done(task_id: str) -> Any:
        return planner.task_done(task_id)

    @srv.tool("tasks_delete", "Delete a card for good — on the operator's explicit word; 'done' is usually what is meant.",
              {"properties": {"task_id": {"type": "string"}}, "required": ["task_id"]})
    def tasks_delete(task_id: str) -> Any:
        return planner.task_delete(task_id)

    @srv.tool("tasks_digest", "Today's picture: overdue cards, due today, starting today, due within the week — grouped, sorted.", {"properties": {}})
    def tasks_digest() -> Any:
        return planner.digest()

    return srv


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def planner_from_env(graph: Graph, tz: str) -> Planner:
    return Planner(graph, env_required("M365_TASKS_GROUP_ID"), env_required("M365_TASKS_PLAN"),
                   os.environ.get("M365_TASKS_ASSIGNEE", "").strip(), env_required("M365_TASKS_ASSIGNEE_ID"), tz)


def main(argv: List[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "serve"
    auth = Auth()
    tz = os.environ.get("M365_TIMEZONE", "").strip() or "Europe/Zurich"
    planner = planner_from_env(Graph(auth, tz), tz)
    if cmd == "status":
        try:
            plan = planner.plan()
            print(json.dumps({"ok": True, "plan": plan.get("title"), "plan_id": plan.get("id"), "group_id": planner.group_id,
                              "assignee": planner.assignee, "tenants": planner.tenants()}))
            return 0
        except Exception as e:  # noqa: BLE001
            print(json.dumps({"ok": False, "plan": planner.plan_title, "group_id": planner.group_id, "reason": str(e)[:400]}))
            return 1
    if cmd == "ensure-plan":
        # ensure-plan [BUCKET,BUCKET…] — the installer's idempotent "the plan
        # and these tenants exist".
        created = planner.ensure_plan()
        names = [n.strip() for n in (argv[2] if len(argv) > 2 else "").split(",") if n.strip()]
        made = [n for n in names if planner.bucket_ensure(n).get("created")]
        print(json.dumps({"plan": planner.plan().get("title"), "plan_id": planner.plan().get("id"), "created": created,
                          "buckets_created": made, "tenants": [b.get("name") for b in planner.buckets()]}))
        return 0
    if cmd == "tenants":
        for b in planner.buckets():
            print(b.get("name"))
        return 0
    if cmd == "due":
        for line in due_lines(classify(planner.tasks(status="open"), planner.today())):
            print(line)
        return 0
    if cmd == "digest":
        print(json.dumps(planner.digest(), ensure_ascii=False, indent=1))
        return 0
    if cmd == "tools":
        print(json.dumps([t.spec() for t in build_server(planner).tools], indent=1))
        return 0
    if cmd == "serve":
        log(f"tasks assistant: plan '{planner.plan_title}' in group {planner.group_id[:8]}…, cards assigned to {planner.assignee or planner.assignee_id}")
        build_server(planner).serve_stdio()
        return 0
    sys.stderr.write(__doc__ or "")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except KeyboardInterrupt:
        sys.exit(130)
