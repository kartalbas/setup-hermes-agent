"""The Tasks assistant against a fake Graph: what goes to Planner, and the
rules the server keeps on its own (a tenant is a bucket, a card is assigned,
dates are Planner's, listings are stable)."""
import json
import os
import subprocess
import sys
import unittest
from datetime import date
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "bot", "mcp"))

import tasks_assistant as ta  # noqa: E402

GROUP = "11111111-2222-3333-4444-555555555555"
ME = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
PLAN = {"id": "plan1", "title": "Tasks", "@odata.etag": 'W/"p"'}
BUCKETS = [{"id": "b-acme", "name": "Acme", "orderHint": "8586", "@odata.etag": 'W/"b1"'},
           {"id": "b-sec", "name": "Secretary", "orderHint": "8585", "@odata.etag": 'W/"b2"'}]


class FakeGraph:
    def __init__(self, answers=None):
        self.calls = []
        self.answers = answers or {}
        self.tz = "Europe/Zurich"
        self.auth = mock.Mock(account="agent@example.com")

    def call(self, method, path, **kw):
        self.calls.append((method, path, kw))
        for (m, prefix), ans in self.answers.items():
            if m == method and path.startswith(prefix):
                return ans(kw) if callable(ans) else ans
        return {}


def planner(answers=None):
    g = FakeGraph(answers)
    return ta.Planner(g, GROUP, "Tasks", "you@example.com", ME, "Europe/Zurich"), g


def with_plan(extra=None):
    answers = {("GET", f"/groups/{GROUP}/planner/plans"): {"value": [PLAN, {"id": "other", "title": "Other"}]},
               ("GET", "/planner/plans/plan1/buckets"): {"value": list(BUCKETS)}}
    answers.update(extra or {})
    return answers


def tool(srv, name):
    return next(t for t in srv.tools if t.name == name)


class Dates(unittest.TestCase):
    def test_a_date_becomes_planners_date_marker_and_back(self):
        self.assertEqual(ta.to_utc("2026-09-30", "Europe/Zurich"), "2026-09-30T10:00:00Z")
        self.assertEqual(ta.local_when("2026-09-30T10:00:00Z", "Europe/Zurich"), "2026-09-30")
        self.assertEqual(ta.local_when("2026-09-30T10:00:00.0000000Z", "Europe/Zurich"), "2026-09-30")

    def test_a_local_time_is_stored_as_the_instant_and_shown_local(self):
        self.assertEqual(ta.to_utc("2026-09-30T14:00", "Europe/Zurich"), "2026-09-30T12:00:00Z")   # CEST
        self.assertEqual(ta.to_utc("2026-12-01T14:00", "Europe/Zurich"), "2026-12-01T13:00:00Z")   # CET
        self.assertEqual(ta.local_when("2026-09-30T12:00:00Z", "Europe/Zurich"), "2026-09-30 14:00")
        self.assertEqual(ta.to_utc("2026-09-30T14:00:00+02:00", "UTC"), "2026-09-30T12:00:00Z")

    def test_bad_or_empty_dates_are_refused(self):
        with self.assertRaises(ValueError):
            ta.to_utc("", "UTC")
        with self.assertRaises(ValueError):
            ta.to_utc("2026-13-01", "UTC")
        self.assertIsNone(ta.local_when(None, "UTC"))

    def test_priority_labels_follow_planners_bands(self):
        self.assertEqual([ta.priority_label(v) for v in (0, 1, 3, 5, 9, None)],
                         ["urgent", "urgent", "important", "medium", "low", "medium"])


class Plan(unittest.TestCase):
    def test_the_plan_is_found_by_title_case_insensitively_and_cached(self):
        p, g = planner(with_plan())
        p.plan_title = "tasks"
        self.assertEqual(p.plan()["id"], "plan1")
        p.plan()
        self.assertEqual(sum(1 for m, path, _ in g.calls if path.endswith("/planner/plans")), 1)

    def test_a_missing_plan_names_the_installer_command(self):
        p, _ = planner({("GET", f"/groups/{GROUP}/planner/plans"): {"value": []}})
        with self.assertRaises(RuntimeError) as cm:
            p.plan()
        self.assertIn("ensure-plan", str(cm.exception))

    def test_ensure_plan_creates_once_in_the_group_container(self):
        p, g = planner({("GET", f"/groups/{GROUP}/planner/plans"): {"value": []},
                        ("POST", "/planner/plans"): {"id": "new", "title": "Tasks"}})
        self.assertTrue(p.ensure_plan())
        body = next(kw for m, path, kw in g.calls if m == "POST")["json_body"]
        self.assertEqual(body["container"]["url"], f"https://graph.microsoft.com/v1.0/groups/{GROUP}")
        self.assertEqual(body["title"], "Tasks")
        self.assertFalse(p.ensure_plan())                       # cached: no second POST
        self.assertEqual(sum(1 for m, _, _ in g.calls if m == "POST"), 1)

    def test_a_403_on_creation_explains_the_membership(self):
        def refuse(kw):
            raise ta.HttpError(403, "POST", "x", "Forbidden")
        p, _ = planner({("GET", f"/groups/{GROUP}/planner/plans"): {"value": []}, ("POST", "/planner/plans"): refuse})
        with self.assertRaises(RuntimeError) as cm:
            p.ensure_plan()
        self.assertIn("member of the group", str(cm.exception))


class Tenants(unittest.TestCase):
    def test_buckets_are_matched_case_insensitively_and_unknown_ones_list_the_rest(self):
        p, _ = planner(with_plan())
        self.assertEqual(p.bucket("acme")["id"], "b-acme")
        with self.assertRaises(RuntimeError) as cm:
            p.bucket("Globex")
        self.assertIn("Acme", str(cm.exception))
        self.assertIn("tasks_tenant_add", str(cm.exception))

    def test_ensure_creates_a_bucket_only_when_missing(self):
        p, g = planner(with_plan({("POST", "/planner/buckets"): {"id": "b-new", "name": "Globex"}}))
        self.assertFalse(p.bucket_ensure("ACME")["created"])
        self.assertTrue(p.bucket_ensure("Globex")["created"])
        body = next(kw for m, path, kw in g.calls if m == "POST")["json_body"]
        self.assertEqual(body, {"name": "Globex", "planId": "plan1", "orderHint": " !"})

    def test_rename_carries_the_etag(self):
        p, g = planner(with_plan({("PATCH", "/planner/buckets/b-sec"): {"name": "Office"}}))
        p.bucket_rename("secretary", "Office")
        _, _, kw = next(c for c in g.calls if c[0] == "PATCH")
        self.assertEqual(kw["headers"], {"If-Match": 'W/"b2"'})
        self.assertEqual(kw["json_body"], {"name": "Office"})


class Cards(unittest.TestCase):
    def test_add_posts_the_card_assigned_to_the_operator_with_planner_dates_and_writes_the_description(self):
        p, g = planner(with_plan({("POST", "/planner/tasks"): {"id": "t1", "title": "RP anpassen (CASE-2323)", "bucketId": "b-acme",
                                                                 "startDateTime": "2026-09-08T10:00:00Z", "dueDateTime": "2026-09-30T10:00:00Z"},
                                  ("GET", "/planner/tasks/t1/details"): {"@odata.etag": 'W/"d"', "description": ""}}))
        out = p.task_add("acme", "RP anpassen (CASE-2323)", "2026-09-08", "2026-09-30", notes="Kunde liefert Details", reference="CASE-2323", priority="important")
        post = next(kw for m, path, kw in g.calls if m == "POST")["json_body"]
        self.assertEqual(post["planId"], "plan1")
        self.assertEqual(post["bucketId"], "b-acme")
        self.assertEqual(post["startDateTime"], "2026-09-08T10:00:00Z")
        self.assertEqual(post["dueDateTime"], "2026-09-30T10:00:00Z")
        self.assertEqual(post["priority"], 3)
        self.assertEqual(post["assignments"], {ME: {"@odata.type": "#microsoft.graph.plannerAssignment", "orderHint": " !"}})
        details = next(kw for m, path, kw in g.calls if m == "PATCH" and path.endswith("/details"))
        self.assertEqual(details["json_body"]["description"], "Reference: CASE-2323\n\nKunde liefert Details")
        self.assertEqual(details["headers"], {"If-Match": 'W/"d"'})
        self.assertEqual(out["tenant"], "Acme")
        self.assertEqual(out["due"], "2026-09-30")
        self.assertEqual(out["assigned_to"], "you@example.com")

    def test_add_without_dates_is_refused_by_the_tool_schema(self):
        p, _ = planner(with_plan())
        srv = ta.build_server(p)
        spec = tool(srv, "tasks_add").spec()["inputSchema"]
        self.assertEqual(sorted(spec["required"]), ["due", "start", "tenant", "title"])

    def test_done_patches_percent_complete_with_the_etag(self):
        p, g = planner(with_plan({("GET", "/planner/tasks/t1"): {"id": "t1", "title": "x", "bucketId": "b-acme", "@odata.etag": 'W/"t"',
                                                                  "assignments": {ME: {}}},
                                  ("PATCH", "/planner/tasks/t1"): {"id": "t1", "title": "x", "bucketId": "b-acme", "percentComplete": 100,
                                                                    "completedDateTime": "2026-09-08T09:00:00Z"}}))
        out = p.task_done("t1")
        _, _, kw = next(c for c in g.calls if c[0] == "PATCH")
        self.assertEqual(kw["json_body"], {"percentComplete": 100})
        self.assertEqual(kw["headers"], {"If-Match": 'W/"t"'})
        self.assertEqual(kw["prefer"], "return=representation")
        self.assertEqual(out["status"], "done")
        self.assertEqual(out["completed"], "2026-09-08")

    def test_update_moves_between_tenants_and_re_assigns_a_card_nobody_holds(self):
        p, g = planner(with_plan({("GET", "/planner/tasks/t1"): {"id": "t1", "title": "x", "bucketId": "b-acme", "@odata.etag": 'W/"t"'},
                                  ("PATCH", "/planner/tasks/t1"): {"id": "t1", "title": "x", "bucketId": "b-sec"}}))
        out = p.task_update("t1", tenant="Secretary", due="2026-10-01T09:30")
        _, _, kw = next(c for c in g.calls if c[0] == "PATCH")
        self.assertEqual(kw["json_body"]["bucketId"], "b-sec")
        self.assertEqual(kw["json_body"]["dueDateTime"], "2026-10-01T07:30:00Z")
        self.assertIn(ME, kw["json_body"]["assignments"])
        self.assertEqual(out["tenant"], "Secretary")

    def test_delete_needs_the_etag(self):
        p, g = planner(with_plan({("GET", "/planner/tasks/t1"): {"id": "t1", "title": "x", "@odata.etag": 'W/"t"'}}))
        self.assertEqual(p.task_delete("t1")["deleted"], True)
        _, _, kw = next(c for c in g.calls if c[0] == "DELETE")
        self.assertEqual(kw["headers"], {"If-Match": 'W/"t"'})


TASKS = [
    {"id": "1", "title": "Late", "bucketId": "b-acme", "dueDateTime": "2026-09-01T10:00:00Z", "percentComplete": 0},
    {"id": "2", "title": "Today", "bucketId": "b-sec", "dueDateTime": "2026-09-08T10:00:00Z", "startDateTime": "2026-09-08T10:00:00Z", "percentComplete": 50},
    {"id": "3", "title": "Soon", "bucketId": "b-acme", "dueDateTime": "2026-09-12T10:00:00Z", "percentComplete": 0},
    {"id": "4", "title": "Far", "bucketId": "b-acme", "dueDateTime": "2026-10-30T10:00:00Z", "percentComplete": 0},
    {"id": "5", "title": "Done", "bucketId": "b-acme", "dueDateTime": "2026-09-01T10:00:00Z", "percentComplete": 100},
]


class Listings(unittest.TestCase):
    def test_open_cards_are_sorted_by_due_and_the_done_ones_filtered(self):
        p, _ = planner(with_plan({("GET", "/planner/plans/plan1/tasks"): {"value": list(TASKS)}}))
        titles = [t["title"] for t in p.tasks()]
        self.assertEqual(titles, ["Late", "Today", "Soon", "Far"])
        self.assertEqual([t["title"] for t in p.tasks(tenant="secretary")], ["Today"])
        self.assertEqual([t["title"] for t in p.tasks(status="done")], ["Done"])
        self.assertEqual(len(p.tasks(status="all")), 5)

    def test_classify_and_the_due_lines_are_stable_and_free_of_timestamps(self):
        p, _ = planner(with_plan({("GET", "/planner/plans/plan1/tasks"): {"value": list(TASKS)}}))
        groups = ta.classify(p.tasks(), date(2026, 9, 8))
        self.assertEqual([t["title"] for t in groups["overdue"]], ["Late"])
        self.assertEqual([t["title"] for t in groups["today"]], ["Today"])
        self.assertEqual([t["title"] for t in groups["starting"]], ["Today"])
        self.assertEqual([t["title"] for t in groups["week"]], ["Soon"])
        lines = ta.due_lines(groups)
        self.assertEqual(lines, ["overdue  2026-09-01       Acme | Late",
                                 "today    2026-09-08       Secretary | Today",
                                 "starts   2026-09-08       Secretary | Today"])
        self.assertEqual(lines, ta.due_lines(ta.classify(p.tasks(), date(2026, 9, 8))))

    def test_tenants_count_open_and_overdue_cards(self):
        p, _ = planner(with_plan({("GET", "/planner/plans/plan1/tasks"): {"value": list(TASKS)}}))
        p.today = lambda: date(2026, 9, 8)
        self.assertEqual(p.tenants(), [{"tenant": "Secretary", "open": 1, "overdue": 0}, {"tenant": "Acme", "open": 3, "overdue": 1}])

    def test_paging_follows_next_links(self):
        p, _ = planner(with_plan({("GET", "/planner/plans/plan1/tasks"): {"value": [TASKS[0]], "@odata.nextLink": "https://graph.example/next"},
                                  ("GET", "https://graph.example/next"): {"value": [TASKS[2]]}}))
        self.assertEqual([t["title"] for t in p.tasks()], ["Late", "Soon"])


class Tools(unittest.TestCase):
    def test_every_tool_is_prefixed_with_a_valid_schema_and_the_instructions_name_the_rules(self):
        p, _ = planner(with_plan())
        srv = ta.build_server(p)
        names = [t.name for t in srv.tools]
        self.assertEqual(len(names), len(set(names)))
        self.assertTrue(all(n.startswith("tasks_") for n in names))
        for t in srv.tools:
            spec = t.spec()["inputSchema"]
            self.assertEqual(spec["type"], "object")
            for req in spec.get("required", []):
                self.assertIn(req, spec["properties"], f"{t.name}: required '{req}' undeclared")
        for n in ("tasks_add", "tasks_tenants", "tasks_tenant_add", "tasks_done", "tasks_digest", "tasks_update", "tasks_list"):
            self.assertIn(n, names)
        self.assertIn("you@example.com", srv.instructions)
        self.assertIn("start and a due date", srv.instructions)

    def test_the_server_starts_and_reports_a_missing_group_id_at_start(self):
        env = dict(os.environ, M365_TENANT_ID="t", M365_CLIENT_ID="c", M365_ACCOUNT="agent@example.com",
                   M365_TOKEN_FILE="/nonexistent/token", M365_TASKS_PLAN="Tasks", M365_TASKS_ASSIGNEE_ID=ME)
        env.pop("M365_TASKS_GROUP_ID", None)
        proc = subprocess.run([sys.executable, os.path.join(ROOT, "bot", "mcp", "tasks_assistant.py"), "status"],
                              env=env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("M365_TASKS_GROUP_ID", proc.stderr)

    def test_the_stdio_handshake_lists_the_tools(self):
        env = dict(os.environ, M365_TENANT_ID="t", M365_CLIENT_ID="c", M365_ACCOUNT="agent@example.com",
                   M365_TOKEN_FILE="/nonexistent/token", M365_TASKS_PLAN="Tasks", M365_TASKS_ASSIGNEE_ID=ME, M365_TASKS_GROUP_ID=GROUP)
        msgs = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}]
        proc = subprocess.run([sys.executable, os.path.join(ROOT, "bot", "mcp", "tasks_assistant.py"), "serve"],
                              input="".join(json.dumps(m) + "\n" for m in msgs), env=env, capture_output=True, text=True, timeout=30)
        replies = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
        self.assertEqual(replies[0]["result"]["serverInfo"]["name"], "tasks-assistant")
        self.assertIn("tasks_add", [t["name"] for t in replies[1]["result"]["tools"]])


if __name__ == "__main__":
    unittest.main()
