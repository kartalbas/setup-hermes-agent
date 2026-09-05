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
        self.auth = mock.Mock(account="agent@example.com")

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
