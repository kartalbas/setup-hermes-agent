"""The Google assistant against a fake API: the shapes that go out."""
import base64
import json
import os
import sys
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "bot", "mcp"))
import google_assistant as ga  # noqa: E402


class FakeGoogle:
    def __init__(self, answers=None):
        self.calls, self.answers, self.tz = [], answers or {}, "Europe/Zurich"
        self.auth = mock.Mock(account="agent@gmail.example", root_folder="", worlds={})

    def call(self, method, url, **kw):
        self.calls.append((method, url, kw))
        for (m, prefix), ans in self.answers.items():
            if m == method and url.startswith(prefix):
                return ans(kw) if callable(ans) else ans
        return {}

    folder_id = ga.Google.folder_id
    item_by_path = ga.Google.item_by_path


def tool(srv, name):
    return next(t for t in srv.tools if t.name == name)


class Tools(unittest.TestCase):
    def test_every_tool_is_prefixed_and_declares_its_required_fields(self):
        srv = ga.build_server(FakeGoogle())
        for t in srv.tools:
            self.assertTrue(t.name.startswith("google_"))
            spec = t.spec()["inputSchema"]
            for req in spec.get("required", []):
                self.assertIn(req, spec["properties"], t.name)
        self.assertIn("PRIVATE", srv.instructions)

    def test_send_builds_a_mime_message_with_recipients_and_attachment(self):
        g = FakeGoogle({("POST", ga.GMAIL + "/messages/send"): {"id": "m1"}})
        srv = ga.build_server(g)
        tool(srv, "google_gmail_send").fn(to=["a@x.example"], cc=["c@x.example"], subject="Hi", body="Text",
                                           attachments=[{"name": "n.txt", "content_base64": base64.b64encode(b"hallo").decode()}])
        raw = g.calls[0][2]["json_body"]["raw"]
        mime = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)).decode()
        self.assertIn("To: a@x.example", mime) and self.assertIn("Cc: c@x.example", mime)
        self.assertIn("Subject: Hi", mime)
        self.assertIn('filename="n.txt"', mime)

    def test_event_with_meet_asks_for_conference_data_and_notifies(self):
        g = FakeGoogle({("POST", ga.CAL + "/calendars/primary/events"): {"id": "e1", "summary": "x"}})
        srv = ga.build_server(g)
        tool(srv, "google_calendar_event_create").fn(summary="x", start="2026-09-07T10:00:00", end="2026-09-07T11:00:00",
                                                     attendees=["p@x.example"], meet=True, reminder_minutes=[10080, 1440])
        _, _, kw = g.calls[0]
        self.assertEqual(kw["params"]["conferenceDataVersion"], 1)
        self.assertEqual(kw["params"]["sendUpdates"], "all")
        self.assertEqual(kw["json_body"]["start"], {"dateTime": "2026-09-07T10:00:00", "timeZone": "Europe/Zurich"})
        self.assertEqual(kw["json_body"]["reminders"]["overrides"][0]["minutes"], 10080)
        self.assertIn("createRequest", kw["json_body"]["conferenceData"])

    def test_drive_upload_resolves_the_folder_chain_and_creates_missing_parts(self):
        def files(kw):
            q = kw["params"]["q"]
            if "name = 'Secretary'" in q:
                return {"files": [{"id": "f1", "name": "Secretary"}]}
            return {"files": []}          # 'Inbox' missing; file not existing
        g = FakeGoogle({("GET", ga.DRIVE + "/files"): files,
                        ("POST", ga.DRIVE + "/files"): {"id": "f2"},
                        ("POST", ga.DRIVE_UPLOAD): {"id": "x", "name": "n.txt", "mimeType": "text/plain"}})
        srv = ga.build_server(g)
        out = tool(srv, "google_drive_upload").fn(path="Secretary/Inbox/n.txt", content="hallo")
        self.assertEqual(out["name"], "n.txt") and self.assertFalse(out["replaced"])
        mk = next(kw for m, u, kw in g.calls if m == "POST" and u == ga.DRIVE + "/files")
        self.assertEqual(mk["json_body"], {"name": "Inbox", "mimeType": ga.FOLDER_MIME, "parents": ["f1"]})
        up = next(kw for m, u, kw in g.calls if u == ga.DRIVE_UPLOAD)
        self.assertIn(b"hallo", up["data"]) and self.assertEqual(up["params"]["uploadType"], "multipart")

    def test_archive_removes_inbox_and_creates_unknown_labels(self):
        g = FakeGoogle({("GET", ga.GMAIL + "/labels"): {"labels": [{"id": "L1", "name": "Privat"}]},
                        ("POST", ga.GMAIL + "/labels"): {"id": "L2"}})
        srv = ga.build_server(g)
        tool(srv, "google_gmail_modify").fn(message_id="m", archive=True, add_labels=["Privat", "Neu"], mark_read=True)
        mod = next(kw for m, u, kw in g.calls if u.endswith("/modify"))["json_body"]
        self.assertEqual(mod["addLabelIds"], ["L1", "L2"])
        self.assertIn("INBOX", mod["removeLabelIds"]) and self.assertIn("UNREAD", mod["removeLabelIds"])

    def test_wrong_account_is_refused_before_anything_is_stored(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            env = {"GOOGLE_CLIENT_ID": "c", "GOOGLE_CLIENT_SECRET": "s", "GOOGLE_ACCOUNT": "agent@gmail.example",
                   "GOOGLE_TOKEN_FILE": os.path.join(d, "t.json")}
            with mock.patch.dict(os.environ, env), mock.patch.object(ga, "http", return_value={"email": "other@gmail.example"}):
                with self.assertRaises(SystemExit):
                    ga.Auth()._accept({"access_token": "a", "refresh_token": "r"})
                self.assertFalse(os.path.exists(env["GOOGLE_TOKEN_FILE"]))

    def test_iso_adds_the_offset_for_bare_local_times(self):
        self.assertTrue(ga._iso("2026-09-07T10:00:00", "Europe/Zurich").endswith("+02:00"))
        self.assertEqual(ga._iso("2026-09-07T10:00:00Z", "Europe/Zurich"), "2026-09-07T10:00:00Z")


if __name__ == "__main__":
    unittest.main()


class ReadAccounts(unittest.TestCase):
    """The operator's own Gmail: read with its own token, never written."""

    def test_without_read_accounts_the_gmail_tools_have_no_account_parameter(self):
        srv = ga.build_server(FakeGoogle())
        for name in ("google_gmail_search", "google_gmail_read", "google_gmail_labels"):
            self.assertNotIn("account", tool(srv, name).spec()["inputSchema"]["properties"])

    def test_a_read_account_routes_to_its_own_client_and_only_for_reading(self):
        primary, reader = FakeGoogle(), FakeGoogle({("GET", ga.GMAIL + "/messages"): {"messages": []}})
        srv = ga.build_server(primary, {"you@gmail.example": reader})
        out = tool(srv, "google_gmail_search").fn(query="has:attachment", account="You@gmail.example")
        self.assertEqual(out["account"], "You@gmail.example")
        self.assertEqual(len(reader.calls), 1) and self.assertEqual(primary.calls, [])
        tool(srv, "google_gmail_labels").fn(account="you@gmail.example")
        self.assertTrue(reader.calls[-1][1].endswith("/labels"))
        for name in ("google_gmail_send", "google_gmail_reply", "google_gmail_modify"):
            self.assertNotIn("account", tool(srv, name).spec()["inputSchema"]["properties"], name)
        self.assertIn("you@gmail.example", srv.instructions)

    def test_an_unlisted_account_is_refused_before_google_is_asked(self):
        primary = FakeGoogle()
        srv = ga.build_server(primary, {"you@gmail.example": FakeGoogle()})
        with self.assertRaises(RuntimeError):
            tool(srv, "google_gmail_read").fn(message_id="m", account="stranger@gmail.example")
        self.assertEqual(primary.calls, [])

    def test_a_read_account_gets_its_own_token_file_and_the_read_only_scopes(self):
        env = {"GOOGLE_CLIENT_ID": "c", "GOOGLE_CLIENT_SECRET": "s", "GOOGLE_ACCOUNT": "agent@gmail.example",
               "GOOGLE_TOKEN_FILE": "/var/lib/x/google.token", "GOOGLE_READ_ACCOUNTS": "you@gmail.example, other@gmail.example"}
        with mock.patch.dict(os.environ, env, clear=False):
            a = ga.Auth("You@gmail.example")
            self.assertEqual((a.account, a.read_only, a.store.path), ("you@gmail.example", True, "/var/lib/x/google-" + "you@gmail.example" + ".token"))
            self.assertEqual(a.scopes, ga.READ_SCOPES)
            self.assertNotIn("gmail.modify", a.scopes)
            p = ga.Auth()
            self.assertEqual((p.account, p.read_only, p.store.path), ("agent@gmail.example", False, "/var/lib/x/google.token"))
            self.assertEqual(ga.read_accounts(), ["you@gmail.example", "other@gmail.example"])
            with self.assertRaises(SystemExit):
                ga.Auth("stranger@gmail.example")


class Worlds(unittest.TestCase):
    """The private/business rule, mirrored in Drive."""

    def test_the_drive_tools_refuse_a_misfiled_path_before_google_is_asked(self):
        g = FakeGoogle()
        g.auth = mock.Mock(account="agent@gmail.example", root_folder="Secretary", worlds={"Business": "_bus", "Private": "_pri"})
        srv = ga.build_server(g)
        with self.assertRaises(ValueError):
            tool(srv, "google_drive_upload").fn(path="Secretary/Reports/x.txt", content="hi")
        with self.assertRaises(ValueError):
            tool(srv, "google_drive_mkdir").fn(path="Secretary/Stuff")
        self.assertEqual(g.calls, [])
        self.assertIn("Under Secretary/", tool(srv, "google_drive_upload").spec()["description"])
        self.assertIn("FILING in Drive", srv.instructions)

    def test_without_worlds_nothing_changes(self):
        srv = ga.build_server(FakeGoogle())
        self.assertNotIn("FILING", srv.instructions)
        self.assertNotIn("world", tool(srv, "google_drive_upload").spec()["description"])


class Companions(unittest.TestCase):
    def test_a_photo_needs_its_text_and_gets_a_twin_in_drive(self):
        g = FakeGoogle({("GET", ga.DRIVE + "/files"): {"files": [{"id": "f1", "name": "x"}]}, ("POST", ga.DRIVE_UPLOAD): {"id": "n"}, ("PATCH", ga.DRIVE_UPLOAD): {"id": "n"}})
        g.auth = mock.Mock(account="agent@gmail.example", root_folder="Secretary", worlds={"Business": "_bus", "Private": "_pri"})
        srv = ga.build_server(g)
        with self.assertRaises(ValueError):
            tool(srv, "google_drive_upload").fn(path="Secretary/Private/Letters/2026/scan_pri.jpg", content_base64="AAAA")
        self.assertEqual(g.calls, [])
        out = tool(srv, "google_drive_upload").fn(path="Secretary/Private/Letters/2026/scan_pri.jpg", content_base64="AAAA", text_md="the text")
        uploads = [c for c in g.calls if c[1].startswith(ga.DRIVE_UPLOAD)]
        self.assertEqual(len(uploads), 2)
        self.assertIn(b"scan_pri.md", uploads[1][2]["data"]); self.assertIn(b"the text", uploads[1][2]["data"])
        self.assertEqual(out["companion"], "/Secretary/Private/Letters/2026/scan_pri.md")
