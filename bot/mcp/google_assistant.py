#!/usr/bin/env python3
"""Google assistant — an MCP server over Gmail, Google Calendar and Drive.

The agent's hands in the operator's PRIVATE world, acting as the agent's own
Google account. Used only when the operator says so ("privat", "private",
"privater Termin", or names the Gmail account); the business default is the
Microsoft 365 server.

    google_assistant.py login      sign in once (paste-back), verify the identity, store the token
    google_assistant.py status     who the token belongs to; exit 1 when there is no usable token
    google_assistant.py serve      MCP over stdio (what the gateway runs)

Environment (the installer sets it in the MCP server entry):
    GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET   the OAuth "Desktop app" client
    GOOGLE_ACCOUNT    the account that must own the token — any other identity is refused
    GOOGLE_TOKEN_FILE where the token lives (0600)
    GOOGLE_TIMEZONE   default for calendar reads and writes (IANA name)
    GOOGLE_SCOPES     space-separated OAuth scopes
"""

from __future__ import annotations

import base64
import hashlib
import json
import mimetypes
import os
import secrets
import sys
import time
import urllib.parse
from email.message import EmailMessage
from typing import Any, Dict, List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from assistant_common import (  # noqa: E402
    HttpError, McpServer, TokenStore, env_required, extract_text, form_post, http, log, unb64,
)

VERSION = "0.1.0"
AUTH = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN = "https://oauth2.googleapis.com/token"
USERINFO = "https://openidconnect.googleapis.com/v1/userinfo"
GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me"
CAL = "https://www.googleapis.com/calendar/v3"
DRIVE = "https://www.googleapis.com/drive/v3"
DRIVE_UPLOAD = "https://www.googleapis.com/upload/drive/v3/files"
DEFAULT_SCOPES = ("openid email https://www.googleapis.com/auth/gmail.modify "
                  "https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/drive")
# The loopback redirect Google allows for Desktop clients. Nothing listens
# there on purpose: the browser shows an error page whose ADDRESS carries the
# code, and the operator pastes that address back. That is what makes the
# sign-in work from a headless host.
REDIRECT = "http://127.0.0.1:17999/"
UPLOAD_LIMIT = 5 * 1024 * 1024
FOLDER_MIME = "application/vnd.google-apps.folder"


# ---------------------------------------------------------------------------
# Auth — authorization code with PKCE, paste-back
# ---------------------------------------------------------------------------

class Auth:
    def __init__(self) -> None:
        self.client_id = env_required("GOOGLE_CLIENT_ID")
        self.client_secret = env_required("GOOGLE_CLIENT_SECRET")
        self.account = env_required("GOOGLE_ACCOUNT").lower()
        self.store = TokenStore(env_required("GOOGLE_TOKEN_FILE"))
        self.scopes = os.environ.get("GOOGLE_SCOPES", "").strip() or DEFAULT_SCOPES

    def login(self) -> Dict[str, Any]:
        verifier = base64.urlsafe_b64encode(secrets.token_bytes(48)).rstrip(b"=").decode()
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        state = secrets.token_urlsafe(16)
        url = AUTH + "?" + urllib.parse.urlencode({
            "client_id": self.client_id, "redirect_uri": REDIRECT, "response_type": "code",
            "scope": self.scopes, "access_type": "offline", "prompt": "consent",
            "login_hint": self.account, "code_challenge": challenge, "code_challenge_method": "S256",
            "state": state})
        sys.stderr.write("\nSign in AS " + self.account + " — in a PRIVATE browser window:\n\n  " + url + "\n\n"
                         "After consenting, the browser lands on an unreachable 127.0.0.1 page. Copy the FULL "
                         "address from the address bar and paste it here.\n\nPasted address: ")
        sys.stderr.flush()
        pasted = sys.stdin.readline().strip()
        if not pasted:
            raise SystemExit("nothing pasted")
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(pasted).query) if "://" in pasted else {"code": [pasted]}
        if qs.get("state", [state])[0] != state:
            raise SystemExit("the pasted address belongs to another sign-in attempt (state mismatch)")
        code = (qs.get("code") or [""])[0]
        if not code:
            raise SystemExit("no authorization code in the pasted address")
        tok = form_post(TOKEN, {"code": code, "client_id": self.client_id, "client_secret": self.client_secret,
                                "redirect_uri": REDIRECT, "grant_type": "authorization_code",
                                "code_verifier": verifier})
        if "access_token" not in tok:
            raise SystemExit(f"token exchange failed: {tok.get('error')}: {tok.get('error_description', '')[:300]}")
        if not tok.get("refresh_token"):
            raise SystemExit("Google issued no refresh token; the client must be a Desktop app and the app "
                             "published (not in Testing), then sign in again")
        return self._accept(tok)

    def _accept(self, tok: Dict[str, Any]) -> Dict[str, Any]:
        me = http("GET", USERINFO, headers={"Authorization": f"Bearer {tok['access_token']}"})
        email = (me.get("email") or "").lower()
        if email != self.account:
            raise SystemExit(f"signed in as {email}, but this token must belong to {self.account}; "
                             "nothing stored — sign in again with the right account")
        self.store.save(access_token=tok["access_token"], refresh_token=tok["refresh_token"],
                        expires_at=time.time() + int(tok.get("expires_in", 3600)),
                        account=email, scopes=tok.get("scope", self.scopes))
        return me

    def access_token(self) -> str:
        if self.store.access_token_valid():
            return str(self.store.data["access_token"])
        if not self.store.refresh_token:
            raise RuntimeError(f"no token for {self.account}: run `googlectl login` once as the service account")
        tok = form_post(TOKEN, {"client_id": self.client_id, "client_secret": self.client_secret,
                                "refresh_token": self.store.refresh_token, "grant_type": "refresh_token"})
        if "access_token" not in tok:
            raise RuntimeError(f"token refresh failed: {tok.get('error')}: {tok.get('error_description', '')[:300]} "
                               "— if the app is in Testing status the token expired after 7 days; publish it and sign in again")
        self.store.save(access_token=tok["access_token"], expires_at=time.time() + int(tok.get("expires_in", 3600)))
        return str(tok["access_token"])


class Google:
    def __init__(self, auth: Auth, timezone: str):
        self.auth = auth
        self.tz = timezone

    def call(self, method: str, url: str, *, params: Optional[Dict[str, Any]] = None, json_body: Any = None,
             data: Optional[bytes] = None, content_type: Optional[str] = None, raw: bool = False) -> Any:
        headers = {"Authorization": f"Bearer {self.auth.access_token()}"}
        if content_type:
            headers["Content-Type"] = content_type
        return http(method, url, headers=headers, params=params, json_body=json_body, data=data, raw=raw, timeout=120)

    # -- Drive paths: Drive is id-based; names are resolved folder by folder --
    def folder_id(self, path: str, create: bool = False) -> str:
        parent = "root"
        for seg in [s for s in path.strip("/").split("/") if s]:
            q = f"'{parent}' in parents and name = '{_q(seg)}' and mimeType = '{FOLDER_MIME}' and trashed = false"
            r = self.call("GET", f"{DRIVE}/files", params={"q": q, "fields": "files(id,name)", "pageSize": 1})
            files = r.get("files") or []
            if files:
                parent = files[0]["id"]
            elif create:
                made = self.call("POST", f"{DRIVE}/files", json_body={"name": seg, "mimeType": FOLDER_MIME, "parents": [parent]},
                                 params={"fields": "id"})
                parent = made["id"]
            else:
                raise RuntimeError(f"no folder '{seg}' under '/{path}'")
        return parent

    def item_by_path(self, path: str) -> Dict[str, Any]:
        folder, _, name = path.strip("/").rpartition("/")
        parent = self.folder_id(folder) if folder else "root"
        q = f"'{parent}' in parents and name = '{_q(name)}' and trashed = false"
        r = self.call("GET", f"{DRIVE}/files", params={"q": q, "fields": "files(id,name,mimeType,size,modifiedTime,webViewLink)", "pageSize": 1})
        files = r.get("files") or []
        if not files:
            raise RuntimeError(f"no file or folder at '/{path.strip('/')}'")
        return files[0]


def _q(s: str) -> str:
    return s.replace("\\", "\\\\").replace("'", "\\'")


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def _unb64url(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def _header(msg: Dict[str, Any], name: str) -> Optional[str]:
    for h in (msg.get("payload") or {}).get("headers") or []:
        if h.get("name", "").lower() == name.lower():
            return h.get("value")
    return None


def _body_text(payload: Dict[str, Any]) -> str:
    """Prefer text/plain, fall back to text/html stripped of tags."""
    plain, html = [], []

    def walk(p):
        mime = p.get("mimeType", "")
        data = (p.get("body") or {}).get("data")
        if data and mime == "text/plain":
            plain.append(_unb64url(data).decode("utf-8", "replace"))
        elif data and mime == "text/html":
            html.append(_unb64url(data).decode("utf-8", "replace"))
        for part in p.get("parts") or []:
            walk(part)
    walk(payload)
    if plain:
        return "\n".join(plain)
    if html:
        import re
        return re.sub(r"<[^>]+>", " ", " ".join(html))
    return ""


def _attachments(payload: Dict[str, Any]) -> List[Dict[str, Any]]:
    out = []

    def walk(p):
        body = p.get("body") or {}
        if p.get("filename") and body.get("attachmentId"):
            out.append({"id": body["attachmentId"], "name": p["filename"], "size": body.get("size"), "contentType": p.get("mimeType")})
        for part in p.get("parts") or []:
            walk(part)
    walk(payload)
    return out


def _msg_shape(m: Dict[str, Any]) -> Dict[str, Any]:
    return {"id": m.get("id"), "threadId": m.get("threadId"), "subject": _header(m, "Subject"),
            "from": _header(m, "From"), "to": _header(m, "To"), "date": _header(m, "Date"),
            "labels": m.get("labelIds"), "snippet": m.get("snippet")}


def _event_shape(e: Dict[str, Any]) -> Dict[str, Any]:
    return {"id": e.get("id"), "summary": e.get("summary"),
            "start": (e.get("start") or {}).get("dateTime") or (e.get("start") or {}).get("date"),
            "end": (e.get("end") or {}).get("dateTime") or (e.get("end") or {}).get("date"),
            "location": e.get("location"), "attendees": [{"email": a.get("email"), "response": a.get("responseStatus")} for a in e.get("attendees") or []],
            "meetLink": e.get("hangoutLink"), "htmlLink": e.get("htmlLink"), "status": e.get("status"),
            "description": (e.get("description") or "")[:500]}


def _file_shape(f: Dict[str, Any]) -> Dict[str, Any]:
    return {"id": f.get("id"), "name": f.get("name"), "kind": "folder" if f.get("mimeType") == FOLDER_MIME else "file",
            "mimeType": f.get("mimeType"), "size": f.get("size"), "modified": f.get("modifiedTime"), "webViewLink": f.get("webViewLink")}


# ---------------------------------------------------------------------------
# The server
# ---------------------------------------------------------------------------

def build_server(g: Google) -> McpServer:
    tz, acct = g.tz, g.auth.account
    srv = McpServer(
        name="google-assistant", version=VERSION,
        instructions=(f"Google for the PRIVATE account {acct}: Gmail, Google Calendar, Drive. Use these tools ONLY "
                      "when the user says 'privat', 'private', 'privater Termin' or names the Gmail account; business "
                      f"goes to the m365_* tools. Times are interpreted in {tz} unless a timezone is given (ISO 8601). "
                      "Sending mail, creating or deleting events and deleting files are visible to others — confirm when ambiguous."))

    @srv.tool("google_whoami", "Which Google account the assistant acts as, and whether the token works.", {"properties": {}})
    def whoami() -> Dict[str, Any]:
        me = g.call("GET", USERINFO)
        return {"account": me.get("email"), "name": me.get("name"), "timezone": tz}

    # -- Gmail -------------------------------------------------------------
    @srv.tool("google_gmail_search", "Search or list Gmail messages (Gmail search syntax: from:, subject:, newer_than:7d, has:attachment, is:unread). Default: inbox, newest first.",
              {"properties": {"query": {"type": "string"}, "max_results": {"type": "integer", "minimum": 1, "maximum": 50}}})
    def gmail_search(query: str = "in:inbox", max_results: int = 10) -> Dict[str, Any]:
        r = g.call("GET", f"{GMAIL}/messages", params={"q": query or "in:inbox", "maxResults": max_results})
        out = []
        for ref in r.get("messages") or []:
            m = g.call("GET", f"{GMAIL}/messages/{ref['id']}", params={"format": "metadata", "metadataHeaders": ["Subject", "From", "To", "Date"]})
            out.append(_msg_shape(m))
        return {"query": query, "count": len(out), "more": bool(r.get("nextPageToken")), "messages": out}

    @srv.tool("google_gmail_read", "Read one message: text body and attachment list.",
              {"properties": {"message_id": {"type": "string"}, "max_chars": {"type": "integer", "minimum": 200, "maximum": 200000}}, "required": ["message_id"]})
    def gmail_read(message_id: str, max_chars: int = 20000) -> Dict[str, Any]:
        m = g.call("GET", f"{GMAIL}/messages/{message_id}", params={"format": "full"})
        out = _msg_shape(m)
        body = _body_text(m.get("payload") or {})
        out["body"] = body[:max_chars]
        out["bodyTruncated"] = len(body) > max_chars
        out["attachments"] = _attachments(m.get("payload") or {})
        return out

    @srv.tool("google_gmail_attachment_text", "Text of a Gmail attachment (pdf, docx, plain text).",
              {"properties": {"message_id": {"type": "string"}, "attachment_id": {"type": "string"}, "name": {"type": "string", "description": "file name (decides the parser)"},
                              "max_chars": {"type": "integer", "minimum": 200, "maximum": 200000}}, "required": ["message_id", "attachment_id", "name"]})
    def gmail_attachment_text(message_id: str, attachment_id: str, name: str, max_chars: int = 20000) -> Dict[str, Any]:
        a = g.call("GET", f"{GMAIL}/messages/{message_id}/attachments/{attachment_id}")
        return extract_text(name, _unb64url(a.get("data") or ""), max_chars)

    def build_mime(to: List[str], subject: str, body: str, cc: Optional[List[str]], bcc: Optional[List[str]],
                   html: bool, attachments: Optional[List[Dict[str, str]]], in_reply_to: Optional[str] = None) -> bytes:
        msg = EmailMessage()
        msg["To"] = ", ".join(to)
        if cc:
            msg["Cc"] = ", ".join(cc)
        if bcc:
            msg["Bcc"] = ", ".join(bcc)
        msg["Subject"] = subject
        if in_reply_to:
            msg["In-Reply-To"] = in_reply_to
            msg["References"] = in_reply_to
        msg.set_content(body, subtype="html" if html else "plain")
        for a in attachments or []:
            data = unb64(a["content_base64"])
            ctype = a.get("content_type") or mimetypes.guess_type(a["name"])[0] or "application/octet-stream"
            maintype, subtype = ctype.split("/", 1)
            msg.add_attachment(data, maintype=maintype, subtype=subtype, filename=a["name"])
        return msg.as_bytes()

    ATTACH = {"type": "array", "items": {"type": "object", "additionalProperties": False, "required": ["name", "content_base64"],
                                         "properties": {"name": {"type": "string"}, "content_base64": {"type": "string"}, "content_type": {"type": "string"}}}}

    @srv.tool("google_gmail_send", f"Send a new e-mail from {acct}.",
              {"properties": {"to": {"type": "array", "items": {"type": "string"}, "minItems": 1}, "subject": {"type": "string"}, "body": {"type": "string"},
                              "cc": {"type": "array", "items": {"type": "string"}}, "bcc": {"type": "array", "items": {"type": "string"}},
                              "html": {"type": "boolean"}, "attachments": ATTACH}, "required": ["to", "subject", "body"]})
    def gmail_send(to: List[str], subject: str, body: str, cc: Optional[List[str]] = None, bcc: Optional[List[str]] = None,
                   html: bool = False, attachments: Optional[List[Dict[str, str]]] = None) -> Dict[str, Any]:
        raw = build_mime(to, subject, body, cc, bcc, html, attachments)
        r = g.call("POST", f"{GMAIL}/messages/send", json_body={"raw": _b64url(raw)})
        return {"sent": True, "id": r.get("id"), "to": to, "subject": subject}

    @srv.tool("google_gmail_reply", "Reply to a message in its thread (reply-all optional).",
              {"properties": {"message_id": {"type": "string"}, "body": {"type": "string"}, "reply_all": {"type": "boolean"}}, "required": ["message_id", "body"]})
    def gmail_reply(message_id: str, body: str, reply_all: bool = False) -> Dict[str, Any]:
        m = g.call("GET", f"{GMAIL}/messages/{message_id}", params={"format": "metadata", "metadataHeaders": ["Subject", "From", "To", "Cc", "Message-ID", "Reply-To"]})
        to = [_header(m, "Reply-To") or _header(m, "From") or ""]
        cc = None
        if reply_all:
            cc = [x.strip() for x in ((_header(m, "To") or "") + "," + (_header(m, "Cc") or "")).split(",") if x.strip() and acct not in x.lower()]
        subject = _header(m, "Subject") or ""
        if not subject.lower().startswith("re:"):
            subject = "Re: " + subject
        raw = build_mime(to, subject, body, cc, None, False, None, in_reply_to=_header(m, "Message-ID"))
        r = g.call("POST", f"{GMAIL}/messages/send", json_body={"raw": _b64url(raw), "threadId": m.get("threadId")})
        return {"replied": True, "id": r.get("id"), "to": to, "cc": cc or []}

    @srv.tool("google_gmail_modify", "Archive (remove INBOX), mark read/unread, star, or apply/remove labels by name.",
              {"properties": {"message_id": {"type": "string"}, "archive": {"type": "boolean"}, "mark_read": {"type": "boolean"},
                              "add_labels": {"type": "array", "items": {"type": "string"}}, "remove_labels": {"type": "array", "items": {"type": "string"}}},
               "required": ["message_id"]})
    def gmail_modify(message_id: str, archive: Optional[bool] = None, mark_read: Optional[bool] = None,
                     add_labels: Optional[List[str]] = None, remove_labels: Optional[List[str]] = None) -> Dict[str, Any]:
        labels = {l["name"]: l["id"] for l in g.call("GET", f"{GMAIL}/labels").get("labels") or []}
        add, rem = [], []
        for n in add_labels or []:
            if n not in labels:
                made = g.call("POST", f"{GMAIL}/labels", json_body={"name": n, "labelListVisibility": "labelShow", "messageListVisibility": "show"})
                labels[n] = made["id"]
            add.append(labels[n])
        for n in remove_labels or []:
            if n in labels:
                rem.append(labels[n])
        if archive:
            rem.append("INBOX")
        if mark_read is True:
            rem.append("UNREAD")
        elif mark_read is False:
            add.append("UNREAD")
        g.call("POST", f"{GMAIL}/messages/{message_id}/modify", json_body={"addLabelIds": add, "removeLabelIds": rem})
        return {"id": message_id, "added": add_labels or [], "removed": (remove_labels or []) + (["INBOX"] if archive else [])}

    @srv.tool("google_gmail_labels", "List Gmail labels (folders) with unread counts.", {"properties": {}})
    def gmail_labels() -> Dict[str, Any]:
        out = []
        for l in g.call("GET", f"{GMAIL}/labels").get("labels") or []:
            if l.get("type") == "user" or l.get("id") in ("INBOX", "STARRED", "SENT", "DRAFTS", "SPAM", "TRASH"):
                d = g.call("GET", f"{GMAIL}/labels/{l['id']}")
                out.append({"name": d.get("name"), "unread": d.get("messagesUnread"), "total": d.get("messagesTotal")})
        return {"labels": out}

    # -- Calendar ----------------------------------------------------------
    @srv.tool("google_calendar_view", f"Events between two instants (ISO 8601, {tz} unless an offset is given), recurring instances expanded.",
              {"properties": {"start": {"type": "string"}, "end": {"type": "string"}, "max_results": {"type": "integer", "minimum": 1, "maximum": 250}}, "required": ["start", "end"]})
    def calendar_view(start: str, end: str, max_results: int = 50) -> Dict[str, Any]:
        r = g.call("GET", f"{CAL}/calendars/primary/events", params={"timeMin": _iso(start, tz), "timeMax": _iso(end, tz), "singleEvents": "true",
                                                                    "orderBy": "startTime", "maxResults": max_results, "timeZone": tz})
        return {"timezone": tz, "count": len(r.get("items") or []), "events": [_event_shape(e) for e in r.get("items") or []]}

    @srv.tool("google_calendar_event_create", "Create a private calendar event; `meet` adds a Google Meet link; attendees get invitations.",
              {"properties": {"summary": {"type": "string"}, "start": {"type": "string"}, "end": {"type": "string"}, "timezone": {"type": "string"},
                              "attendees": {"type": "array", "items": {"type": "string"}}, "description": {"type": "string"}, "location": {"type": "string"},
                              "meet": {"type": "boolean"}, "all_day": {"type": "boolean"}, "reminder_minutes": {"type": "array", "items": {"type": "integer"}}},
               "required": ["summary", "start", "end"]})
    def event_create(summary: str, start: str, end: str, timezone: Optional[str] = None, attendees: Optional[List[str]] = None,
                     description: str = "", location: str = "", meet: bool = False, all_day: bool = False,
                     reminder_minutes: Optional[List[int]] = None) -> Dict[str, Any]:
        zone = timezone or tz
        ev: Dict[str, Any] = {"summary": summary, "description": description, "location": location,
                              "start": {"date": start[:10]} if all_day else {"dateTime": start, "timeZone": zone},
                              "end": {"date": end[:10]} if all_day else {"dateTime": end, "timeZone": zone}}
        if attendees:
            ev["attendees"] = [{"email": a} for a in attendees]
        if reminder_minutes:
            ev["reminders"] = {"useDefault": False, "overrides": [{"method": "popup", "minutes": m} for m in reminder_minutes]}
        params = {"sendUpdates": "all"}
        if meet:
            ev["conferenceData"] = {"createRequest": {"requestId": secrets.token_hex(8), "conferenceSolutionKey": {"type": "hangoutsMeet"}}}
            params["conferenceDataVersion"] = 1
        e = g.call("POST", f"{CAL}/calendars/primary/events", json_body=ev, params=params)
        return _event_shape(e)

    @srv.tool("google_calendar_event_update", "Change fields of an event; attendees are notified.",
              {"properties": {"event_id": {"type": "string"}, "summary": {"type": "string"}, "start": {"type": "string"}, "end": {"type": "string"},
                              "timezone": {"type": "string"}, "description": {"type": "string"}, "location": {"type": "string"},
                              "attendees": {"type": "array", "items": {"type": "string"}}}, "required": ["event_id"]})
    def event_update(event_id: str, **fields: Any) -> Dict[str, Any]:
        zone = fields.pop("timezone", None) or tz
        patch: Dict[str, Any] = {}
        for k in ("summary", "description", "location"):
            if k in fields:
                patch[k] = fields[k]
        if "start" in fields:
            patch["start"] = {"dateTime": fields["start"], "timeZone": zone}
        if "end" in fields:
            patch["end"] = {"dateTime": fields["end"], "timeZone": zone}
        if "attendees" in fields:
            patch["attendees"] = [{"email": a} for a in fields["attendees"]]
        e = g.call("PATCH", f"{CAL}/calendars/primary/events/{event_id}", json_body=patch, params={"sendUpdates": "all"})
        return _event_shape(e)

    @srv.tool("google_calendar_event_delete", "Delete an event (attendees are notified).",
              {"properties": {"event_id": {"type": "string"}}, "required": ["event_id"]})
    def event_delete(event_id: str) -> Dict[str, Any]:
        g.call("DELETE", f"{CAL}/calendars/primary/events/{event_id}", params={"sendUpdates": "all"})
        return {"deleted": True, "event_id": event_id}

    # -- Drive -------------------------------------------------------------
    @srv.tool("google_drive_list", "List a Drive folder by path ('' for the root).",
              {"properties": {"path": {"type": "string"}, "max_results": {"type": "integer", "minimum": 1, "maximum": 200}}})
    def drive_list(path: str = "", max_results: int = 100) -> Dict[str, Any]:
        parent = g.folder_id(path) if path.strip("/") else "root"
        r = g.call("GET", f"{DRIVE}/files", params={"q": f"'{parent}' in parents and trashed = false", "orderBy": "folder,name",
                                                     "pageSize": max_results, "fields": "files(id,name,mimeType,size,modifiedTime,webViewLink),nextPageToken"})
        return {"path": "/" + path.strip("/"), "count": len(r.get("files") or []), "more": bool(r.get("nextPageToken")),
                "items": [_file_shape(f) for f in r.get("files") or []]}

    @srv.tool("google_drive_search", "Search Drive by name and full text.",
              {"properties": {"query": {"type": "string"}, "max_results": {"type": "integer", "minimum": 1, "maximum": 100}}, "required": ["query"]})
    def drive_search(query: str, max_results: int = 25) -> Dict[str, Any]:
        q = f"(name contains '{_q(query)}' or fullText contains '{_q(query)}') and trashed = false"
        r = g.call("GET", f"{DRIVE}/files", params={"q": q, "pageSize": max_results, "fields": "files(id,name,mimeType,size,modifiedTime,webViewLink)"})
        return {"count": len(r.get("files") or []), "items": [_file_shape(f) for f in r.get("files") or []]}

    @srv.tool("google_drive_read", "Text of a Drive file by path (pdf, docx, plain text; Google Docs/Sheets are exported as text/csv).",
              {"properties": {"path": {"type": "string"}, "max_chars": {"type": "integer", "minimum": 200, "maximum": 200000}}, "required": ["path"]})
    def drive_read(path: str, max_chars: int = 20000) -> Dict[str, Any]:
        f = g.item_by_path(path)
        mime = f.get("mimeType", "")
        if mime == FOLDER_MIME:
            return {"path": path, "supported": False, "note": "that is a folder; use google_drive_list"}
        if mime.startswith("application/vnd.google-apps."):
            export = "text/csv" if "spreadsheet" in mime else "text/plain"
            data, _ = g.call("GET", f"{DRIVE}/files/{f['id']}/export", params={"mimeType": export}, raw=True)
            out = extract_text(f["name"] + (".csv" if export == "text/csv" else ".txt"), data, max_chars)
        else:
            data, _ = g.call("GET", f"{DRIVE}/files/{f['id']}", params={"alt": "media"}, raw=True)
            out = extract_text(f["name"], data, max_chars)
        out["path"] = path
        return out

    @srv.tool("google_drive_upload", "Create or replace a file in Drive by path (folders are created). Text or base64, up to 5 MB.",
              {"properties": {"path": {"type": "string"}, "content": {"type": "string"}, "content_base64": {"type": "string"},
                              "content_type": {"type": "string"}}, "required": ["path"]})
    def drive_upload(path: str, content: Optional[str] = None, content_base64: Optional[str] = None, content_type: Optional[str] = None) -> Dict[str, Any]:
        if (content is None) == (content_base64 is None):
            raise ValueError("give exactly one of content or content_base64")
        data = content.encode("utf-8") if content is not None else unb64(content_base64 or "")
        if len(data) > UPLOAD_LIMIT:
            raise ValueError(f"{len(data)} bytes exceeds the 5 MB simple-upload limit")
        folder, _, name = path.strip("/").rpartition("/")
        if not name:
            raise ValueError("path must name a file")
        parent = g.folder_id(folder, create=True) if folder else "root"
        ctype = content_type or mimetypes.guess_type(name)[0] or ("text/plain" if content is not None else "application/octet-stream")
        existing = g.call("GET", f"{DRIVE}/files", params={"q": f"'{parent}' in parents and name = '{_q(name)}' and trashed = false", "fields": "files(id)", "pageSize": 1}).get("files") or []
        boundary = "hermes" + secrets.token_hex(8)
        meta = {"name": name} if existing else {"name": name, "parents": [parent]}
        body = (f"--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{json.dumps(meta)}\r\n"
                f"--{boundary}\r\nContent-Type: {ctype}\r\n\r\n").encode() + data + f"\r\n--{boundary}--".encode()
        url = f"{DRIVE_UPLOAD}/{existing[0]['id']}" if existing else DRIVE_UPLOAD
        f = g.call("PATCH" if existing else "POST", url, params={"uploadType": "multipart", "fields": "id,name,mimeType,size,modifiedTime,webViewLink"},
                   data=body, content_type=f"multipart/related; boundary={boundary}")
        out = _file_shape(f)
        out["path"] = "/" + path.strip("/")
        out["replaced"] = bool(existing)
        return out

    @srv.tool("google_drive_mkdir", "Create a folder path in Drive (existing parts are kept).", {"properties": {"path": {"type": "string"}}, "required": ["path"]})
    def drive_mkdir(path: str) -> Dict[str, Any]:
        return {"path": "/" + path.strip("/"), "id": g.folder_id(path, create=True)}

    @srv.tool("google_drive_move", "Move and/or rename a file or folder.",
              {"properties": {"path": {"type": "string"}, "new_parent": {"type": "string"}, "new_name": {"type": "string"}}, "required": ["path"]})
    def drive_move(path: str, new_parent: Optional[str] = None, new_name: Optional[str] = None) -> Dict[str, Any]:
        f = g.item_by_path(path)
        params: Dict[str, Any] = {"fields": "id,name,mimeType,size,modifiedTime,webViewLink"}
        body: Dict[str, Any] = {}
        if new_parent is not None:
            cur = g.call("GET", f"{DRIVE}/files/{f['id']}", params={"fields": "parents"}).get("parents") or []
            params["addParents"] = g.folder_id(new_parent, create=True) if new_parent.strip("/") else "root"
            params["removeParents"] = ",".join(cur)
        if new_name:
            body["name"] = new_name
        if not body and "addParents" not in params:
            raise ValueError("nothing to do: give new_parent and/or new_name")
        moved = g.call("PATCH", f"{DRIVE}/files/{f['id']}", json_body=body or None, params=params)
        return _file_shape(moved)

    @srv.tool("google_drive_delete", "Move a file or folder to the Drive trash.", {"properties": {"path": {"type": "string"}}, "required": ["path"]})
    def drive_delete(path: str) -> Dict[str, Any]:
        f = g.item_by_path(path)
        g.call("PATCH", f"{DRIVE}/files/{f['id']}", json_body={"trashed": True})
        return {"trashed": True, "path": path}

    @srv.tool("google_drive_share", "Share a file or folder: with named people (role reader|writer) or by link (anyone with the link, reader).",
              {"properties": {"path": {"type": "string"}, "emails": {"type": "array", "items": {"type": "string"}}, "role": {"type": "string", "enum": ["reader", "writer"]},
                              "anyone_with_link": {"type": "boolean"}, "notify": {"type": "boolean"}}, "required": ["path"]})
    def drive_share(path: str, emails: Optional[List[str]] = None, role: str = "reader", anyone_with_link: bool = False, notify: bool = True) -> Dict[str, Any]:
        f = g.item_by_path(path)
        granted = []
        for e in emails or []:
            g.call("POST", f"{DRIVE}/files/{f['id']}/permissions", json_body={"type": "user", "role": role, "emailAddress": e},
                   params={"sendNotificationEmail": "true" if notify else "false"})
            granted.append(e)
        if anyone_with_link:
            g.call("POST", f"{DRIVE}/files/{f['id']}/permissions", json_body={"type": "anyone", "role": "reader"})
        link = g.call("GET", f"{DRIVE}/files/{f['id']}", params={"fields": "webViewLink"}).get("webViewLink")
        return {"path": path, "granted": granted, "role": role, "anyone_with_link": anyone_with_link, "link": link}

    return srv


def _iso(dt: str, tz: str) -> str:
    """Calendar's timeMin/timeMax need an offset; a bare local time gets one from tz."""
    if len(dt) > 19 and dt[19] in "+-Z" or dt.endswith("Z"):
        return dt
    try:
        from zoneinfo import ZoneInfo
        from datetime import datetime
        return datetime.fromisoformat(dt).replace(tzinfo=ZoneInfo(tz)).isoformat()
    except Exception:  # noqa: BLE001
        return dt


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: List[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "serve"
    auth = Auth()
    tz = os.environ.get("GOOGLE_TIMEZONE", "").strip() or "Europe/Zurich"
    if cmd == "login":
        me = auth.login()
        print(json.dumps({"signed_in": True, "account": me.get("email")}))
        return 0
    if cmd == "status":
        if not auth.store.refresh_token:
            print(json.dumps({"ok": False, "account": auth.account, "reason": "no token stored; run `googlectl login` as the service account"}))
            return 1
        try:
            me = Google(auth, tz).call("GET", USERINFO)
        except Exception as e:  # noqa: BLE001
            print(json.dumps({"ok": False, "account": auth.account, "reason": str(e)[:400]}))
            return 1
        ok = (me.get("email") or "").lower() == auth.account
        print(json.dumps({"ok": ok, "account": me.get("email"), "scopes": auth.store.data.get("scopes"), "token_file": auth.store.path}))
        return 0 if ok else 1
    if cmd == "tools":
        print(json.dumps([t.spec() for t in build_server(Google(auth, tz)).tools], indent=1))
        return 0
    if cmd == "serve":
        build_server(Google(auth, tz)).serve_stdio()
        return 0
    sys.stderr.write(__doc__ or "")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except KeyboardInterrupt:
        sys.exit(130)
