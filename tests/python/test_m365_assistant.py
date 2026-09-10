"""The M365 assistant against a fake Graph.

What matters is the shape of what goes to Graph — an event with a Teams link
and roles, a mail with recipients — and that the server refuses what it must
(a token for the wrong account, an oversized upload, both content forms).
"""
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "bot", "mcp"))

import assistant_common as common  # noqa: E402
import m365_assistant as m365  # noqa: E402

ENV = {"M365_TENANT_ID": "tenant", "M365_CLIENT_ID": "client", "M365_ACCOUNT": "agent@example.com",
       "M365_TOKEN_FILE": "", "M365_TIMEZONE": "Europe/Zurich"}


class FakeGraph:
    """Records calls; answers from a small script keyed by (method, path prefix)."""

    def __init__(self, answers=None):
        self.calls = []
        self.answers = answers or {}
        self.tz = "Europe/Zurich"
        self.auth = mock.Mock(account="agent@example.com", read_mailboxes=[], root_folder="", worlds={})

    def call(self, method, path, **kw):
        self.calls.append((method, path, kw))
        for (m, prefix), ans in self.answers.items():
            if m == method and path.startswith(prefix):
                return ans(kw) if callable(ans) else ans
        return {}

    def download(self, url):
        return b"file content"

    # the real helpers, bound to the fake
    folder_id = m365.Graph.folder_id
    mailbox_path = m365.Graph.mailbox_path
    mailbox_probe = m365.Graph.mailbox_probe
    drive_path = m365.Graph.drive_path
    ensure_folder = m365.Graph.ensure_folder


def tool(srv, name):
    return next(t for t in srv.tools if t.name == name)


class ToolsList(unittest.TestCase):
    def test_every_tool_has_a_valid_object_schema(self):
        srv = m365.build_server(FakeGraph())
        names = [t.name for t in srv.tools]
        self.assertEqual(len(names), len(set(names)))
        self.assertTrue(all(n.startswith("m365_") for n in names))
        for t in srv.tools:
            spec = t.spec()["inputSchema"]
            self.assertEqual(spec["type"], "object")
            self.assertFalse(spec["additionalProperties"])
            for req in spec.get("required", []):
                self.assertIn(req, spec["properties"], f"{t.name}: required '{req}' undeclared")
        self.assertIn("m365_event_create", names)
        self.assertIn("m365_drive_share_link", names)


class Events(unittest.TestCase):
    def test_create_with_roles_adds_teams_link_invites_the_role_holders_and_patches_roles(self):
        created = {"id": "ev1", "subject": "Sync", "onlineMeeting": {"joinUrl": "https://teams.microsoft.com/l/x"},
                   "start": {"dateTime": "2026-09-05T18:00:00", "timeZone": "Europe/Zurich"}}
        g = FakeGraph({("POST", "/me/events"): created,
                       ("GET", "/me/onlineMeetings"): {"value": [{"id": "om1"}]},
                       ("PATCH", "/me/onlineMeetings/om1"): {}})
        srv = m365.build_server(g)
        out = tool(srv, "m365_event_create").fn(
            subject="Sync", start="2026-09-05T18:00:00", end="2026-09-05T19:00:00",
            attendees=[{"email": "guest@gmail.example"}], coorganizers=["boss@example.com"], presenters=["guest@gmail.example"])
        post = next(kw for m, p, kw in g.calls if m == "POST" and p == "/me/events")["json_body"]
        self.assertTrue(post["isOnlineMeeting"])
        self.assertEqual(post["onlineMeetingProvider"], "teamsForBusiness")
        invited = {a["emailAddress"]["address"] for a in post["attendees"]}
        self.assertEqual(invited, {"guest@gmail.example", "boss@example.com"})
        self.assertEqual(post["start"], {"dateTime": "2026-09-05T18:00:00", "timeZone": "Europe/Zurich"})
        patch = next(kw for m, p, kw in g.calls if m == "PATCH")["json_body"]
        self.assertEqual(patch["participants"]["attendees"],
                         [{"upn": "boss@example.com", "role": "coorganizer"}, {"upn": "guest@gmail.example", "role": "presenter"}])
        self.assertEqual(patch["allowedPresenters"], "roleIsPresenter")
        self.assertTrue(out["roles"]["applied"])
        self.assertEqual(out["joinUrl"], "https://teams.microsoft.com/l/x")

    def test_create_without_online_meeting_is_a_plain_event(self):
        g = FakeGraph({("POST", "/me/events"): {"id": "e", "subject": "Lunch"}})
        srv = m365.build_server(g)
        tool(srv, "m365_event_create").fn(subject="Lunch", start="2026-09-06T12:00:00", end="2026-09-06T13:00:00", timezone="UTC")
        post = g.calls[0][2]["json_body"]
        self.assertNotIn("isOnlineMeeting", post)
        self.assertEqual(post["start"]["timeZone"], "UTC")

    def test_cancel_declines_when_not_the_organizer(self):
        g = FakeGraph({("GET", "/me/events/e1"): {"id": "e1", "subject": "x", "isOrganizer": False}})
        srv = m365.build_server(g)
        out = tool(srv, "m365_event_cancel").fn(event_id="e1")
        self.assertTrue(out["declined"])
        self.assertTrue(any(p.endswith("/decline") for _, p, _ in g.calls))


class Mail(unittest.TestCase):
    def test_send_shapes_recipients_and_saves_to_sent(self):
        g = FakeGraph()
        srv = m365.build_server(g)
        tool(srv, "m365_mail_send").fn(to=["a@x.example", "b@x.example"], cc=["c@x.example"], subject="Hi", body="Text")
        _, path, kw = g.calls[0]
        self.assertEqual(path, "/me/sendMail")
        self.assertTrue(kw["json_body"]["saveToSentItems"])
        msg = kw["json_body"]["message"]
        self.assertEqual([r["emailAddress"]["address"] for r in msg["toRecipients"]], ["a@x.example", "b@x.example"])
        self.assertEqual(msg["body"], {"contentType": "text", "content": "Text"})

    def test_move_resolves_aliases_to_well_known_folders_without_a_lookup(self):
        g = FakeGraph({("POST", "/me/messages/m1/move"): {"id": "m2"}})
        srv = m365.build_server(g)
        tool(srv, "m365_mail_move").fn(message_id="m1", destination="Trash")
        self.assertEqual(g.calls[0][2]["json_body"], {"destinationId": "deleteditems"})
        self.assertEqual(len(g.calls), 1)

    def test_search_uses_search_or_orderby_never_both(self):
        g = FakeGraph({("GET", "/me/mailFolders/inbox/messages"): {"value": []}})
        srv = m365.build_server(g)
        tool(srv, "m365_mail_search").fn(query="invoice")
        self.assertIn("$search", g.calls[0][2]["params"])
        self.assertNotIn("$orderby", g.calls[0][2]["params"])
        tool(srv, "m365_mail_search").fn(unread_only=True)
        self.assertIn("$orderby", g.calls[1][2]["params"])
        self.assertEqual(g.calls[1][2]["params"]["$filter"], "isRead eq false")


class Drive(unittest.TestCase):
    def test_upload_refuses_ambiguous_content_and_oversize(self):
        srv = m365.build_server(FakeGraph())
        up = tool(srv, "m365_drive_upload").fn
        with self.assertRaises(ValueError):
            up(path="a/b.txt")
        with self.assertRaises(ValueError):
            up(path="a/b.txt", content="x", content_base64="eA==")
        with self.assertRaises(ValueError):
            up(path="a/b.txt", content="x" * (m365.UPLOAD_LIMIT + 1))

    def test_upload_creates_the_folder_chain_then_puts_by_path(self):
        def missing(kw):
            raise common.HttpError(404, "GET", "x", "not found")
        g = FakeGraph({("GET", "/me/drive/root:/Assistant:"): missing,
                       ("GET", "/me/drive/root:/Assistant/Inbox:"): missing,
                       ("POST", "/me/drive/root/children"): {"id": "f1", "name": "Assistant"},
                       ("POST", "/me/drive/items/f1/children"): {"id": "f2", "name": "Inbox"},
                       ("PUT", "/me/drive/root:/Assistant/Inbox/letter.txt:/content"): {"id": "i", "name": "letter.txt", "size": 5}})
        srv = m365.build_server(g)
        out = tool(srv, "m365_drive_upload").fn(path="Assistant/Inbox/letter.txt", content="hallo")
        self.assertEqual(out["name"], "letter.txt")
        put = next(kw for m, p, kw in g.calls if m == "PUT")
        self.assertEqual(put["data"], b"hallo")
        self.assertEqual(put["params"]["@microsoft.graph.conflictBehavior"], "replace")

    def test_drive_path_encodes_spaces_and_keeps_slashes(self):
        self.assertEqual(m365.Graph.drive_path(None, "My Docs/a b.pdf"), "/me/drive/root:/My%20Docs/a%20b.pdf:")
        self.assertEqual(m365.Graph.drive_path(None, ""), "/me/drive/root")


class Identity(unittest.TestCase):
    def test_a_token_for_another_account_is_refused_and_not_stored(self):
        with tempfile.TemporaryDirectory() as d:
            env = dict(ENV, M365_TOKEN_FILE=os.path.join(d, "t.json"))
            with mock.patch.dict(os.environ, env), \
                 mock.patch.object(m365, "http", return_value={"userPrincipalName": "someone.else@example.com", "mail": None}):
                auth = m365.Auth()
                with self.assertRaises(SystemExit):
                    auth._accept({"access_token": "a", "refresh_token": "r", "expires_in": 3600})
                self.assertFalse(os.path.exists(env["M365_TOKEN_FILE"]))

    def test_the_right_account_is_stored_with_mode_0600(self):
        with tempfile.TemporaryDirectory() as d:
            env = dict(ENV, M365_TOKEN_FILE=os.path.join(d, "t.json"))
            with mock.patch.dict(os.environ, env), \
                 mock.patch.object(m365, "http", return_value={"userPrincipalName": "Agent@Example.com", "displayName": "Agent"}):
                m365.Auth()._accept({"access_token": "a", "refresh_token": "r", "expires_in": 3600})
                st = os.stat(env["M365_TOKEN_FILE"])
                self.assertEqual(st.st_mode & 0o777, 0o600)
                self.assertEqual(json.load(open(env["M365_TOKEN_FILE"]))["refresh_token"], "r")


class Common(unittest.TestCase):
    def test_validate_reports_missing_unknown_and_wrong_types(self):
        schema = {"type": "object", "additionalProperties": False, "required": ["a"],
                  "properties": {"a": {"type": "string"}, "n": {"type": "integer"}, "e": {"type": "string", "enum": ["x", "y"]}}}
        self.assertEqual(common.validate({"a": "ok"}, schema), [])
        problems = common.validate({"n": "1", "z": 1, "e": "q"}, schema)
        self.assertIn("missing required 'a'", problems)
        self.assertIn("unknown argument 'z'", problems)
        self.assertIn("'n' must be integer", problems)
        self.assertTrue(any("'e' must be one of" in p for p in problems))

    def test_extract_text_plain_and_unsupported(self):
        self.assertEqual(common.extract_text("a.txt", b"hallo")["text"], "hallo")
        self.assertFalse(common.extract_text("a.xlsx", b"")["supported"])
        out = common.extract_text("a.md", b"x" * 50, max_chars=10)
        self.assertTrue(out["truncated"]) and self.assertEqual(len(out["text"]), 10)

    def test_stdio_handshake_lists_tools_and_reports_a_missing_token_as_a_tool_error(self):
        env = dict(os.environ, **dict(ENV, M365_TOKEN_FILE=os.path.join(tempfile.gettempdir(), "no-such-token.json")))
        msgs = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "m365_whoami", "arguments": {}}}]
        proc = subprocess.run([sys.executable, os.path.join(ROOT, "bot", "mcp", "m365_assistant.py"), "serve"],
                              input="".join(json.dumps(m) + "\n" for m in msgs), capture_output=True, text=True, env=env, timeout=30)
        replies = [json.loads(l) for l in proc.stdout.splitlines() if l.strip()]
        self.assertEqual([r["id"] for r in replies], [1, 2, 3])
        self.assertEqual(replies[0]["result"]["serverInfo"]["name"], "m365-assistant")
        self.assertGreater(len(replies[1]["result"]["tools"]), 20)
        self.assertTrue(replies[2]["result"]["isError"])
        self.assertIn("no token", replies[2]["result"]["content"][0]["text"])


if __name__ == "__main__":
    unittest.main()


class Sharing(unittest.TestCase):
    def test_share_with_grants_only_what_is_missing(self):
        g = FakeGraph({("GET", "/me/drive/root:/Secretary:"): {"id": "f1", "name": "Secretary"},
                       ("GET", "/me/drive/items/f1/permissions"): {"value": [
                           {"roles": ["write"], "grantedToV2": {"user": {"email": "Boss@example.com"}}}]},
                       ("POST", "/me/drive/items/f1/invite"): {}})
        out = m365.share_with(g, "Secretary", ["boss@example.com", "new@example.com"], "write", send_invitation=False)
        self.assertEqual(out["granted_now"], ["new@example.com"])
        self.assertEqual(out["already_had"], ["boss@example.com"])
        invite = next(kw for m, p, kw in g.calls if m == "POST")["json_body"]
        self.assertEqual(invite["recipients"], [{"email": "new@example.com"}])
        self.assertEqual(invite["roles"], ["write"])
        self.assertFalse(invite["sendInvitation"])

    def test_share_with_is_a_no_op_when_everyone_has_the_role(self):
        g = FakeGraph({("GET", "/me/drive/root:/Secretary:"): {"id": "f1", "name": "Secretary"},
                       ("GET", "/me/drive/items/f1/permissions"): {"value": [
                           {"roles": ["write"], "grantedToV2": {"user": {"email": "boss@example.com"}}}]}})
        out = m365.share_with(g, "Secretary", ["boss@example.com"])
        self.assertEqual(out["granted_now"], [])
        self.assertFalse(any(m == "POST" for m, _, _ in g.calls))


class LocalFiles(unittest.TestCase):
    def test_upload_file_puts_a_small_local_file_and_removes_it(self):
        import tempfile
        d = tempfile.mkdtemp(); local = os.path.join(d, "plan.pdf")
        open(local, "wb").write(b"%PDF-1.4 fake")
        g = FakeGraph({("GET", "/me/drive/root:/Secretary:"): {"id": "f0", "name": "Secretary", "folder": {}},
                       ("GET", "/me/drive/root:/Secretary/Reports:"): {"id": "f", "name": "Reports", "folder": {}},
                       ("PUT", "/me/drive/root:/Secretary/Reports/plan.pdf:/content"): {"id": "i", "name": "plan.pdf", "size": 13}})
        srv = m365.build_server(g)
        out = tool(srv, "m365_drive_upload_file").fn(local_path=local, path="Secretary/Reports/plan.pdf")
        self.assertEqual(out["name"], "plan.pdf") and self.assertTrue(out["local_removed"])
        self.assertFalse(os.path.exists(local))
        put = next(kw for m, p, kw in g.calls if m == "PUT")
        self.assertEqual(put["data"], b"%PDF-1.4 fake")

    def test_upload_file_refuses_a_missing_local_file(self):
        srv = m365.build_server(FakeGraph())
        with self.assertRaises(ValueError):
            tool(srv, "m365_drive_upload_file").fn(local_path="/nowhere/x.pdf", path="Secretary/x.pdf")


class MailRules(unittest.TestCase):
    def test_rule_and_folder_are_created_once(self):
        g = FakeGraph({("GET", "/me/mailFolders/inbox/messageRules"): {"value": []},
                       ("GET", "/me/mailFolders"): {"value": [{"id": "in", "displayName": "Inbox"}]},
                       ("POST", "/me/mailFolders/inbox/messageRules"): {},
                       ("POST", "/me/mailFolders"): {"id": "f-news"}})
        out = m365.ensure_mail_rule(g, "news@example.com", "News")
        self.assertTrue(out["folder_created"]) and self.assertTrue(out["rule_created"])
        rule = next(kw for m, p, kw in g.calls if m == "POST" and p.endswith("/messageRules"))["json_body"]
        self.assertEqual(rule["conditions"]["sentToAddresses"][0]["emailAddress"]["address"], "news@example.com")
        self.assertEqual(rule["actions"]["moveToFolder"], "f-news")
        g2 = FakeGraph({("GET", "/me/mailFolders/inbox/messageRules"): {"value": [{"displayName": "Route news@example.com -> News"}]},
                        ("GET", "/me/mailFolders"): {"value": [{"id": "f-news", "displayName": "News"}]}})
        out2 = m365.ensure_mail_rule(g2, "news@example.com", "News")
        self.assertFalse(out2["rule_created"]) and self.assertFalse(out2["folder_created"])
        self.assertFalse(any(m == "POST" for m, _, _ in g2.calls))


class ReadMailboxes(unittest.TestCase):
    """The operator's mailboxes: read there, never write there."""

    def graph(self, readable):
        g = FakeGraph({("GET", "/users/you@example.com/mailFolders/inbox"): {"id": "in", "totalItemCount": 7, "unreadItemCount": 2}})
        g.auth = mock.Mock(account="agent@example.com", read_mailboxes=readable, root_folder="", worlds={})
        return g

    def test_without_a_read_list_the_mail_tools_have_no_mailbox_parameter(self):
        srv = m365.build_server(self.graph([]))
        for name in ("m365_mail_search", "m365_mail_read", "m365_mail_folders"):
            self.assertNotIn("mailbox", next(t for t in srv.tools if t.name == name).spec()["inputSchema"]["properties"])
        self.assertNotIn("READ", srv.instructions)

    def test_a_read_mailbox_is_addressed_under_users_and_only_by_the_read_tools(self):
        g = self.graph(["you@example.com"])
        srv = m365.build_server(g)
        tool = {t.name: t for t in srv.tools}
        tool["m365_mail_search"].fn(folder="inbox", mailbox="You@example.com")
        self.assertEqual(g.calls[-1][1], "/users/you@example.com/mailFolders/inbox/messages")
        tool["m365_mail_folders"].fn(mailbox="you@example.com")
        self.assertEqual(g.calls[-1][1], "/users/you@example.com/mailFolders")
        tool["m365_mail_read"].fn(message_id="m1", mailbox="you@example.com")
        self.assertEqual(g.calls[-1][1], "/users/you@example.com/messages/m1")
        for name in ("m365_mail_send", "m365_mail_reply", "m365_mail_move", "m365_mail_mark"):
            self.assertNotIn("mailbox", tool[name].spec()["inputSchema"]["properties"], name)
        self.assertIn("you@example.com", tool["m365_mail_search"].spec()["inputSchema"]["properties"]["mailbox"]["description"])
        self.assertIn("you@example.com", srv.instructions)

    def test_an_unlisted_mailbox_is_refused_before_graph_is_asked(self):
        g = self.graph(["you@example.com"])
        srv = m365.build_server(g)
        with self.assertRaises(RuntimeError) as cm:
            next(t for t in srv.tools if t.name == "m365_mail_search").fn(mailbox="boss@example.com")
        self.assertIn("boss@example.com", str(cm.exception))
        self.assertEqual(g.calls, [])
        # the assistant's own address is the same as no mailbox at all
        self.assertEqual(g.mailbox_path("Agent@example.com"), "/me")

    def test_the_probe_reports_the_inbox_counts(self):
        out = self.graph(["you@example.com"]).mailbox_probe("you@example.com")
        self.assertEqual((out["readable"], out["inbox_total"], out["inbox_unread"]), (True, 7, 2))

    def test_parse_list_accepts_commas_and_spaces(self):
        self.assertEqual(m365.parse_list(" A@x.example,b@x.example  c@x.example "), ["a@x.example", "b@x.example", "c@x.example"])
        self.assertEqual(m365.parse_list(""), [])


class Worlds(unittest.TestCase):
    """Private and business apart: the rule the drive tools enforce, and the migration plan."""
    W = {"Business": "_bus", "Private": "_pri"}

    def test_parse_and_paths_outside_the_root_are_free(self):
        self.assertEqual(m365.parse_worlds("Business=_bus, Private=_pri"), self.W)
        self.assertEqual(m365.parse_worlds(""), {})
        self.assertIsNone(m365.world_check("Other/x.pdf", "Secretary", self.W))
        self.assertIsNone(m365.world_check("Secretary", "Secretary", self.W))
        self.assertIsNone(m365.world_check("Secretary/Business/x.pdf", "Secretary", {}))

    def test_a_world_and_its_suffix_are_required_below_the_root(self):
        self.assertEqual(m365.world_check("Secretary/Business/Letters/2026/2026-09-07 lease_bus.pdf", "Secretary", self.W), "Business")
        self.assertEqual(m365.world_check("secretary/private/Receipts/2026-09_pri.csv", "Secretary", self.W), "Private")
        with self.assertRaises(ValueError) as cm:
            m365.world_check("Secretary/Letters/2026/lease.pdf", "Secretary", self.W)
        self.assertIn("Secretary/Business/Letters/2026/lease.pdf", str(cm.exception))
        with self.assertRaises(ValueError) as cm:
            m365.world_check("Secretary/Business/Letters/2026/lease.pdf", "Secretary", self.W)
        self.assertIn("lease_bus.pdf", str(cm.exception))
        with self.assertRaises(ValueError):
            m365.world_check("Secretary/Private/Reports/plan_bus.pdf", "Secretary", self.W)   # wrong world's suffix
        # folders need the world only
        self.assertEqual(m365.world_check("Secretary/Private/Letters/2026", "Secretary", self.W, is_folder=True), "Private")
        self.assertEqual(m365.world_check("Secretary/Business", "Secretary", self.W), "Business")

    def test_the_drive_tools_refuse_before_calling_graph(self):
        g = FakeGraph()
        g.auth = mock.Mock(account="agent@example.com", read_mailboxes=[], root_folder="Secretary", worlds=self.W)
        srv = m365.build_server(g)
        tool = {t.name: t for t in srv.tools}
        with self.assertRaises(ValueError):
            tool["m365_drive_upload"].fn(path="Secretary/Reports/x.txt", content="hi")
        with self.assertRaises(ValueError):
            tool["m365_drive_mkdir"].fn(path="Secretary/Stuff")
        self.assertEqual(g.calls, [])
        desc = tool["m365_drive_upload_file"].spec()["description"]
        self.assertIn("Under Secretary/", desc); self.assertIn("'_bus'", desc)
        self.assertIn("_pri", srv.instructions)

    def test_existing_files_are_planned_into_the_default_world_with_the_suffix(self):
        plan = m365.plan_world_targets(["Timesheets/Acme/2026-09.csv", "Letters/2026/2026-09-01 notice_bus.pdf",
                                        "Privat/Insurance/policy.pdf", "loose.txt",
                                        "Letters/2026/2026-08-28 tax office papers privat.jpg"], "Secretary", self.W, "Business")
        self.assertEqual(dict(plan), {
            "Secretary/Timesheets/Acme/2026-09.csv": "Secretary/Business/Timesheets/Acme/2026-09_bus.csv",
            "Secretary/Letters/2026/2026-09-01 notice_bus.pdf": "Secretary/Business/Letters/2026/2026-09-01 notice_bus.pdf",
            "Secretary/Privat/Insurance/policy.pdf": "Secretary/Private/Insurance/policy_pri.pdf",
            "Secretary/loose.txt": "Secretary/Business/loose_bus.txt",
            "Secretary/Letters/2026/2026-08-28 tax office papers privat.jpg": "Secretary/Private/Letters/2026/2026-08-28 tax office papers privat_pri.jpg",
        })
        self.assertEqual(m365.plan_world_targets(["x.pdf"], "Secretary", {}, None), [])


class Companions(unittest.TestCase):
    """A filed document comes with its text twin — or not at all."""
    W = {"Business": "_bus", "Private": "_pri"}

    def server(self):
        # every folder lookup finds a folder, so ensure_folder creates nothing
        g = FakeGraph({("GET", "/me/drive/root"): {"id": "dir", "name": "dir", "folder": {}}})
        g.auth = mock.Mock(account="agent@example.com", read_mailboxes=[], root_folder="Secretary", worlds=self.W)
        return g, m365.build_server(g)

    def test_a_photo_without_its_text_is_refused_before_anything_is_written(self):
        g, srv = self.server()
        with self.assertRaises(ValueError) as cm:
            next(t for t in srv.tools if t.name == "m365_drive_upload").fn(path="Secretary/Private/Letters/2026/scan_pri.jpg", content_base64="AAAA")
        self.assertIn("text_md", str(cm.exception))
        self.assertEqual(g.calls, [])

    def test_a_photo_with_its_text_gets_a_markdown_twin_next_to_it(self):
        g, srv = self.server()
        out = next(t for t in srv.tools if t.name == "m365_drive_upload").fn(
            path="Secretary/Private/Letters/2026/2026-09-07 tax_pri.jpg", content_base64="AAAA", text_md="Steuerverwaltung: Veranlagung 2025, Frist 30.09.")
        puts = [c for c in g.calls if c[0] == "PUT"]
        self.assertEqual(len(puts), 2)
        self.assertIn("tax_pri.jpg:/content", puts[0][1])
        self.assertIn("tax_pri.md:/content", puts[1][1])
        body = puts[1][2]["data"].decode()
        self.assertIn("# 2026-09-07 tax_pri.jpg", body); self.assertIn("- world: Private", body); self.assertIn("Frist 30.09.", body)
        self.assertEqual(out["companion"], "/Secretary/Private/Letters/2026/2026-09-07 tax_pri.md")

    def test_text_files_and_files_outside_the_root_need_no_twin(self):
        g, srv = self.server()
        up = next(t for t in srv.tools if t.name == "m365_drive_upload")
        up.fn(path="Secretary/Business/Timesheets/Acme/2026-09_bus.csv", content="date,start")
        up.fn(path="Elsewhere/photo.jpg", content_base64="AAAA")
        self.assertEqual(len([c for c in g.calls if c[0] == "PUT"]), 2)

    def test_companion_helpers(self):
        self.assertEqual(common.companion_path("Secretary/Business/Letters/2026/a_bus.jpg"), "Secretary/Business/Letters/2026/a_bus.md")
        self.assertTrue(common.is_document("x.PDF")); self.assertTrue(common.is_document("x.heic")); self.assertFalse(common.is_document("x.md"))
        self.assertEqual(common.recognized_text("a.jpg", b"", "  hello "), "hello")
        with self.assertRaises(ValueError):
            common.recognized_text("a.png", b"", None)
        md = common.companion_markdown("a_bus.jpg", "Business", "text")
        self.assertTrue(md.startswith("# a_bus.jpg")); self.assertIn("- world: Business", md); self.assertTrue(md.endswith("text\n"))


class SharedLinks(unittest.TestCase):
    def test_share_id_is_the_url_base64url_without_padding(self):
        import base64
        url = "https://tenant.sharepoint.example/sites/x/Doc.pdf"
        self.assertEqual(m365.share_id(url), "u!" + base64.urlsafe_b64encode(url.encode()).decode().rstrip("="))
        self.assertNotIn("=", m365.share_id("https://files.example/c?d=1"))

    def test_share_read_goes_through_the_shares_endpoint_and_extracts_text(self):
        sid = m365.share_id("https://tenant.sharepoint.example/sites/x/notes.txt")
        g = FakeGraph({("GET", f"/shares/{sid}/driveItem"): {"id": "i", "name": "notes.txt", "size": 5, "file": {}, "webUrl": "https://web.example/n",
                                                          "@microsoft.graph.downloadUrl": "https://dl.example/notes.txt"}})
        g.download = lambda url: b"hello"
        srv = m365.build_server(g)
        out = next(t for t in srv.tools if t.name == "m365_share_read").fn(url="https://tenant.sharepoint.example/sites/x/notes.txt")
        self.assertEqual(out.get("text"), "hello"); self.assertEqual(out["name"], "notes.txt")
        self.assertTrue(g.calls[0][1].startswith(f"/shares/{sid}/driveItem"))


class DropFolders(unittest.TestCase):
    W = {"Business": "_bus", "Private": "_pri"}

    def test_the_inbox_listing_is_sorted_and_free_of_timestamps(self):
        def children(kw):
            return {"value": [{"id": "2", "name": "b.pdf", "size": 2, "file": {}}, {"id": "1", "name": "a.jpg", "size": 1, "file": {}},
                              {"id": "3", "name": "sub", "folder": {}}]}
        g = FakeGraph({("GET", "/me/drive/root:/Secretary/Business/Inbox:/children"): children})
        g.auth = mock.Mock(account="agent@example.com", read_mailboxes=[], root_folder="Secretary", worlds=self.W, inbox="Inbox")
        # the Private inbox does not exist yet: a 404 is "nothing there", not an error
        real_call = g.call
        def call(method, path, **kw):
            if path.startswith("/me/drive/root:/Secretary/Private/Inbox"):
                raise common.HttpError(404, "GET", path, "itemNotFound")
            return real_call(method, path, **kw)
        g.call = call
        items = m365.inbox_listing(g, "Secretary", self.W, "Inbox")
        self.assertEqual([i["path"] for i in items], ["Secretary/Business/Inbox/a.jpg", "Secretary/Business/Inbox/b.pdf"])
        self.assertTrue(all("modified" not in i for i in items))

    def test_filing_from_the_inbox_moves_renames_and_writes_the_twin_in_one_call(self):
        g = FakeGraph({("GET", "/me/drive/root:/Secretary/Business/Inbox/scan.jpg:"): {"id": "f1", "name": "scan.jpg", "size": 3, "file": {}},
                       ("GET", "/me/drive/root"): {"id": "dir", "name": "dir", "folder": {}},        # every folder lookup finds a folder
                       ("PATCH", "/me/drive/items/f1"): {"id": "f1", "name": "2026-09-07 tax office_bus.jpg", "parentReference": {"path": "/drive/root:/Secretary/Business/Letters/2026"}}})
        g.auth = mock.Mock(account="agent@example.com", read_mailboxes=[], root_folder="Secretary", worlds=self.W, inbox="Inbox")
        srv = m365.build_server(g)
        tool = next(t for t in srv.tools if t.name == "m365_drive_file")
        with self.assertRaises(ValueError):
            tool.fn(path="Secretary/Business/Inbox/scan.jpg", target="Secretary/Business/Letters/2026/2026-09-07 tax office.jpg", text_md="x")   # suffix missing
        self.assertEqual([c for c in g.calls if c[0] == "PATCH"], [])
        out = tool.fn(path="Secretary/Business/Inbox/scan.jpg", target="Secretary/Business/Letters/2026/2026-09-07 tax office_bus.jpg", text_md="Steueramt, Frist 30.09.")
        patch = next(c for c in g.calls if c[0] == "PATCH")
        self.assertEqual(patch[2]["json_body"]["name"], "2026-09-07 tax office_bus.jpg")
        put = next(c for c in g.calls if c[0] == "PUT")
        self.assertIn("office_bus.md:/content", put[1]); self.assertIn(b"Frist 30.09.", put[2]["data"])
        self.assertEqual(out["companion"], "/Secretary/Business/Letters/2026/2026-09-07 tax office_bus.md")


class TokenFile(unittest.TestCase):
    """One token file, several holders. `m365.token` is refreshed by the
    Secretary's Microsoft 365 server and by the Tasks bot's server, each in its
    own process, so the store has to survive two writers arriving together and
    a writer that has been holding a stale copy."""

    def test_a_stale_holder_cannot_overwrite_a_newer_refresh(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "m365.token")
            common.TokenStore(path).save(access_token="a0", refresh_token="r0", account="agent@example.com")
            stale = common.TokenStore(path)                       # loaded now, written later
            common.TokenStore(path).save(access_token="a1", refresh_token="r1")
            stale.save(expires_at=99)                             # knows only this
            with open(path, encoding="utf-8") as f:
                final = json.load(f)
            self.assertEqual(final["refresh_token"], "r1")        # the newer refresh survived
            self.assertEqual(final["access_token"], "a1")
            self.assertEqual(final["expires_at"], 99)             # and the stale writer's own field landed
            self.assertEqual(final["account"], "agent@example.com")

    def test_concurrent_writers_never_publish_a_torn_file_and_leave_no_temp_behind(self):
        import threading
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "m365.token")
            common.TokenStore(path).save(access_token="seed", refresh_token="r", account="a@b")
            errors = []

            def writer(n):
                try:
                    for i in range(25):
                        common.TokenStore(path).save(access_token=f"{n}-{i}")
                except Exception as exc:  # noqa: BLE001
                    errors.append(exc)

            def reader():
                try:
                    for _ in range(200):
                        with open(path, encoding="utf-8") as f:
                            got = json.load(f)          # never a half-written file
                        self.assertEqual(got["account"], "a@b")
                except Exception as exc:  # noqa: BLE001
                    errors.append(exc)

            threads = [threading.Thread(target=writer, args=(n,)) for n in range(4)] + [threading.Thread(target=reader)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
            self.assertEqual(errors, [])
            self.assertEqual([f for f in os.listdir(d) if f.endswith(".tmp")], [])
            with open(path, encoding="utf-8") as f:
                self.assertEqual(json.load(f)["refresh_token"], "r")

    def test_the_file_stays_private_and_so_does_its_lock(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "m365.token")
            common.TokenStore(path).save(access_token="a")
            self.assertEqual(oct(os.stat(path).st_mode)[-3:], "600")
            self.assertEqual(oct(os.stat(path + ".lock").st_mode)[-3:], "600")
