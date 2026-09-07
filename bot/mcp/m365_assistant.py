#!/usr/bin/env python3
"""Microsoft 365 assistant — an MCP server over Microsoft Graph.

The agent's hands in the operator's Microsoft 365 tenant, acting AS ONE
account (the agent's own mailbox): mail, calendar, Teams meetings with roles,
OneDrive. Delegated permissions only; the account signs in once with a device
code, the refresh token is kept in one file and renewed from then on.

    m365_assistant.py login     sign in (device code), verify the identity, store the token
    m365_assistant.py status    who the token belongs to; exit 1 when there is no usable token
    m365_assistant.py serve     MCP over stdio (what the gateway runs)

Environment (the installer sets it in the MCP server entry):
    M365_TENANT_ID   the Entra tenant
    M365_CLIENT_ID   the public-client app registration ("Hermes Mail")
    M365_ACCOUNT     the account that must own the token — any other identity is refused
    M365_TOKEN_FILE  where the token lives (0600)
    M365_TIMEZONE    default for calendar reads and writes (IANA name)
    M365_SCOPES      space-separated delegated scopes
"""

from __future__ import annotations

import json
import os
import tempfile
import sys
import time
import urllib.parse
from typing import Any, Dict, List, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from assistant_common import (  # noqa: E402
    HttpError, McpServer, TokenStore, b64, env_required, extract_text, form_post, http, log, unb64,
)

VERSION = "0.1.0"
GRAPH = "https://graph.microsoft.com/v1.0"
LOGIN = "https://login.microsoftonline.com"
DEFAULT_SCOPES = ("offline_access openid profile User.Read Mail.ReadWrite Mail.Send "
                  "Calendars.ReadWrite OnlineMeetings.ReadWrite Files.ReadWrite")
UPLOAD_LIMIT = 4 * 1024 * 1024  # simple upload; larger needs an upload session

WELL_KNOWN_FOLDERS = {"inbox", "archive", "deleteditems", "drafts", "sentitems", "junkemail", "outbox"}
FOLDER_ALIASES = {"deleted": "deleteditems", "trash": "deleteditems", "sent": "sentitems", "junk": "junkemail", "spam": "junkemail"}


from assistant_common import (  # noqa: E402,F401  (shared with the Google server)
    parse_worlds, world_check, world_of, plan_world_targets, is_document, companion_path, recognized_text, companion_markdown,
)


def parse_list(value: str) -> List[str]:
    """Comma- or space-separated addresses, lower-cased, empty entries dropped."""
    return [v.strip().lower() for v in value.replace(",", " ").split() if v.strip()]


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

class Auth:
    def __init__(self) -> None:
        self.tenant = env_required("M365_TENANT_ID")
        self.client_id = env_required("M365_CLIENT_ID")
        self.account = env_required("M365_ACCOUNT").lower()
        self.store = TokenStore(env_required("M365_TOKEN_FILE"))
        self.scopes = os.environ.get("M365_SCOPES", "").strip() or DEFAULT_SCOPES
        # Other mailboxes of the tenant the assistant may READ (search, read,
        # attachments, folders) — never send, move or mark there. Each needs
        # Full Access delegation for the assistant's account on the Exchange
        # side and the Mail.Read.Shared scope on the app; the installer checks both.
        self.read_mailboxes = parse_list(os.environ.get("M365_READ_MAILBOXES", ""))
        # The filing root and its worlds (private/business): enforced by the
        # drive tools that write, so a misfiled document is refused with the
        # corrected name rather than filed and forgotten.
        self.root_folder = os.environ.get("M365_ROOT_FOLDER", "").strip().strip("/")
        self.worlds = parse_worlds(os.environ.get("M365_WORLDS", ""))

    def _token_url(self) -> str:
        return f"{LOGIN}/{self.tenant}/oauth2/v2.0/token"

    def device_login(self, timeout: int = 900) -> Dict[str, Any]:
        start = form_post(f"{LOGIN}/{self.tenant}/oauth2/v2.0/devicecode",
                          {"client_id": self.client_id, "scope": self.scopes})
        if "device_code" not in start:
            raise SystemExit(f"device code request failed: {start.get('error_description') or start}")
        # The message names the URL and the code; it goes to stderr and the
        # installer's log, never to stdout (which may be the MCP channel).
        sys.stderr.write("\n" + start["message"] + "\n")
        sys.stderr.write(f"Sign in AS {self.account} — a private browser window avoids picking up another identity.\n\n")
        sys.stderr.flush()
        interval = int(start.get("interval", 5))
        deadline = time.time() + min(timeout, int(start.get("expires_in", timeout)))
        while time.time() < deadline:
            time.sleep(interval)
            tok = form_post(self._token_url(), {
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": self.client_id, "device_code": start["device_code"]})
            err = tok.get("error")
            if not err:
                return self._accept(tok)
            if err == "authorization_pending":
                continue
            if err == "slow_down":
                interval += 5
                continue
            raise SystemExit(f"sign-in failed: {err}: {tok.get('error_description', '')[:300]}")
        raise SystemExit("sign-in timed out; run the installer again and enter the code in time")

    def _accept(self, tok: Dict[str, Any]) -> Dict[str, Any]:
        access = tok["access_token"]
        me = http("GET", f"{GRAPH}/me", headers={"Authorization": f"Bearer {access}"},
                  params={"$select": "userPrincipalName,mail,displayName,id"})
        upn = (me.get("userPrincipalName") or "").lower()
        mail = (me.get("mail") or "").lower()
        if self.account not in (upn, mail):
            raise SystemExit(f"signed in as {upn}, but this token must belong to {self.account}; "
                             "nothing stored — sign in again with the right account")
        self.store.save(access_token=access, refresh_token=tok.get("refresh_token", self.store.refresh_token),
                        expires_at=time.time() + int(tok.get("expires_in", 3600)),
                        account=upn, display_name=me.get("displayName"), scopes=tok.get("scope", self.scopes))
        return me

    def access_token(self) -> str:
        if self.store.access_token_valid():
            return str(self.store.data["access_token"])
        if not self.store.refresh_token:
            raise RuntimeError(f"no token for {self.account}: the installer's sign-in step has not run")
        tok = form_post(self._token_url(), {
            "grant_type": "refresh_token", "client_id": self.client_id,
            "refresh_token": self.store.refresh_token, "scope": self.scopes})
        if "access_token" not in tok:
            raise RuntimeError(f"token refresh failed: {tok.get('error')}: {tok.get('error_description', '')[:300]}")
        self.store.save(access_token=tok["access_token"],
                        refresh_token=tok.get("refresh_token", self.store.refresh_token),
                        expires_at=time.time() + int(tok.get("expires_in", 3600)))
        return str(tok["access_token"])


# ---------------------------------------------------------------------------
# Graph client
# ---------------------------------------------------------------------------

class Graph:
    def __init__(self, auth: Auth, timezone: str):
        self.auth = auth
        self.tz = timezone

    def call(self, method: str, path: str, *, params: Optional[Dict[str, Any]] = None,
             json_body: Any = None, data: Optional[bytes] = None, prefer: Optional[str] = None,
             content_type: Optional[str] = None, raw: bool = False) -> Any:
        url = path if path.startswith("http") else f"{GRAPH}{path}"
        headers = {"Authorization": f"Bearer {self.auth.access_token()}"}
        if prefer:
            headers["Prefer"] = prefer
        if content_type:
            headers["Content-Type"] = content_type
        return http(method, url, headers=headers, params=params, json_body=json_body, data=data, raw=raw)

    def download(self, url: str) -> bytes:
        payload, _ = http("GET", url, raw=True, timeout=120)
        return payload

    # -- helpers ------------------------------------------------------------
    def mailbox_path(self, mailbox: Optional[str] = None) -> str:
        """`/me` for the assistant's own mailbox; `/users/<address>` for one of
        the operator's mailboxes the configuration lets it read. Anything else
        is refused here, before Graph is asked."""
        mb = (mailbox or "").strip().lower()
        if not mb or mb == self.auth.account:
            return "/me"
        allowed = list(self.auth.read_mailboxes or [])
        if mb not in allowed:
            hint = f"readable mailboxes: {', '.join(allowed)}" if allowed else \
                "no other mailbox is configured (ASSISTANT_M365_READ_MAILBOXES)"
            raise RuntimeError(f"mailbox {mb} is not one the assistant may read; {hint}")
        return f"/users/{urllib.parse.quote(mb, safe='@')}"

    def mailbox_probe(self, mailbox: str) -> Dict[str, Any]:
        """The installer's check: can the assistant see the inbox of MAILBOX?"""
        base = self.mailbox_path(mailbox)
        f = self.call("GET", f"{base}/mailFolders/inbox", params={"$select": "id,displayName,totalItemCount,unreadItemCount"})
        return {"mailbox": mailbox.lower(), "readable": True, "inbox_total": f.get("totalItemCount"), "inbox_unread": f.get("unreadItemCount")}

    def folder_id(self, name: str, mailbox: Optional[str] = None) -> str:
        key = name.strip().lower().replace(" ", "")
        key = FOLDER_ALIASES.get(key, key)
        if key in WELL_KNOWN_FOLDERS:
            return key
        found = self.call("GET", f"{self.mailbox_path(mailbox)}/mailFolders", params={
            "$filter": f"displayName eq '{name.replace(chr(39), chr(39) * 2)}'", "$select": "id,displayName"})
        items = found.get("value") or []
        if not items:
            raise RuntimeError(f"no mail folder named '{name}' (use m365_mail_folders to list them)")
        return str(items[0]["id"])

    def drive_path(self, path: str) -> str:
        p = path.strip().strip("/")
        return "/me/drive/root" if not p else f"/me/drive/root:/{urllib.parse.quote(p, safe='/')}:"

    def ensure_folder(self, path: str) -> Dict[str, Any]:
        parts = [s for s in path.strip("/").split("/") if s]
        parent = "/me/drive/root"
        item: Dict[str, Any] = {"id": "root", "name": "root"}
        so_far = ""
        for seg in parts:
            so_far = f"{so_far}/{seg}"
            try:
                item = self.call("GET", self.drive_path(so_far), params={"$select": "id,name,folder"})
                if "folder" not in item:
                    raise RuntimeError(f"'{so_far}' exists and is a file, not a folder")
            except HttpError as e:
                if e.status != 404:
                    raise
                item = self.call("POST", f"{parent}/children", json_body={
                    "name": seg, "folder": {}, "@microsoft.graph.conflictBehavior": "fail"})
            parent = f"/me/drive/items/{item['id']}"
        return item


# ---------------------------------------------------------------------------
# Shapes — what the model gets back. Trimmed on purpose: Graph objects are
# huge and the model pays for every byte.
# ---------------------------------------------------------------------------

def _addr(a: Optional[Dict[str, Any]]) -> Optional[str]:
    if not a:
        return None
    e = a.get("emailAddress") or {}
    name, addr = e.get("name"), e.get("address")
    return f"{name} <{addr}>" if name and addr and name != addr else addr


def _msg_shape(m: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": m.get("id"), "subject": m.get("subject"), "from": _addr(m.get("from")),
        "to": [_addr(r) for r in m.get("toRecipients") or []],
        "cc": [_addr(r) for r in m.get("ccRecipients") or []] or None,
        "received": m.get("receivedDateTime"), "isRead": m.get("isRead"),
        "hasAttachments": m.get("hasAttachments"), "importance": m.get("importance"),
        "preview": m.get("bodyPreview"), "webLink": m.get("webLink"),
        "conversationId": m.get("conversationId"),
    }


def _event_shape(e: Dict[str, Any]) -> Dict[str, Any]:
    om = e.get("onlineMeeting") or {}
    return {
        "id": e.get("id"), "subject": e.get("subject"),
        "start": (e.get("start") or {}).get("dateTime"), "end": (e.get("end") or {}).get("dateTime"),
        "timeZone": (e.get("start") or {}).get("timeZone"), "isAllDay": e.get("isAllDay"),
        "location": (e.get("location") or {}).get("displayName") or None,
        "organizer": _addr(e.get("organizer")), "isOrganizer": e.get("isOrganizer"),
        "attendees": [{"who": _addr(a), "type": a.get("type"),
                       "response": (a.get("status") or {}).get("response")} for a in e.get("attendees") or []],
        "isOnlineMeeting": e.get("isOnlineMeeting"), "joinUrl": om.get("joinUrl"),
        "isCancelled": e.get("isCancelled"), "showAs": e.get("showAs"),
        "categories": e.get("categories") or None, "webLink": e.get("webLink"),
        "preview": e.get("bodyPreview"),
    }


def _item_shape(i: Dict[str, Any]) -> Dict[str, Any]:
    parent = (i.get("parentReference") or {}).get("path") or ""
    folder = parent.split("root:", 1)[1] if "root:" in parent else ""
    return {
        "id": i.get("id"), "name": i.get("name"), "path": f"{folder}/{i.get('name')}",
        "kind": "folder" if "folder" in i else "file", "size": i.get("size"),
        "children": (i.get("folder") or {}).get("childCount"),
        "modified": i.get("lastModifiedDateTime"), "webUrl": i.get("webUrl"),
    }


def _recipients(addrs: Optional[List[str]]) -> List[Dict[str, Any]]:
    return [{"emailAddress": {"address": a.strip()}} for a in addrs or [] if a and a.strip()]


def _when(dt: str, tz: str) -> Dict[str, str]:
    return {"dateTime": dt, "timeZone": tz}


MESSAGE_SELECT = ("id,subject,from,toRecipients,ccRecipients,receivedDateTime,isRead,hasAttachments,"
                  "importance,bodyPreview,webLink,conversationId")
EVENT_SELECT = ("id,subject,start,end,isAllDay,location,organizer,isOrganizer,attendees,isOnlineMeeting,"
                "onlineMeeting,isCancelled,showAs,categories,webLink,bodyPreview")


def upload_session(graph: "Graph", path: str, local: str, size: int, if_exists: str,
                   chunk: int = 10 * 1024 * 1024) -> Dict[str, Any]:
    """Resumable upload for files above the simple-upload limit: one session,
    chunks of a multiple of 320 KiB (Graph's requirement), the last answer is
    the item."""
    session = graph.call("POST", f"{graph.drive_path(path)}/createUploadSession",
                         json_body={"item": {"@microsoft.graph.conflictBehavior": if_exists}})
    url = session["uploadUrl"]
    sent = 0
    item: Dict[str, Any] = {}
    with open(local, "rb") as f:
        while sent < size:
            data = f.read(chunk)
            end = sent + len(data) - 1
            payload, _ = http("PUT", url, data=data, raw=True, timeout=300,
                              headers={"Content-Range": f"bytes {sent}-{end}/{size}", "Content-Length": str(len(data))})
            sent = end + 1
            if payload:
                try:
                    item = json.loads(payload.decode("utf-8"))
                except ValueError:
                    item = {}
    return item


def missing_companions(graph: "Graph", start: str) -> List[str]:
    """Documents below START whose `.md` twin does not exist, as paths."""
    out: List[str] = []

    def walk(path: str) -> None:
        r = graph.call("GET", f"{graph.drive_path(path)}/children", params={"$top": 200, "$select": "id,name,folder,file"})
        names = {(i.get("name") or "") for i in r.get("value") or []}
        for item in r.get("value") or []:
            name = item.get("name") or ""
            child = f"{path}/{name}"
            if "folder" in item:
                walk(child)
            elif is_document(name) and companion_path(name) not in names:
                out.append(child)

    walk(start.strip("/"))
    return out


def companions_apply(graph: "Graph", paths: List[str], root: str, worlds: Dict[str, str]) -> Tuple[List[str], List[str]]:
    """Create the twin for every document whose text the server can extract
    (PDF, Word); return (done, needs_eyes) — the rest waits for the model."""
    done: List[str] = []; eyes: List[str] = []
    for path in paths:
        name = path.rsplit("/", 1)[-1]
        try:
            meta = graph.call("GET", graph.drive_path(path), params={"$select": "id,name,@microsoft.graph.downloadUrl"})
            url = meta.get("@microsoft.graph.downloadUrl")
            data = graph.download(url) if url else graph.call("GET", f"/me/drive/items/{meta['id']}/content", raw=True)[0]
            text = recognized_text(name, data, None)
        except ValueError:
            eyes.append(path)
            continue
        found = world_of(path, root, worlds) if worlds else None
        world = found[0] if found else None
        graph.call("PUT", f"{graph.drive_path(companion_path(path))}/content", data=companion_markdown(name, world, text).encode("utf-8"),
                   content_type="text/markdown", params={"@microsoft.graph.conflictBehavior": "replace"})
        done.append(companion_path(path))
    return done, eyes


def migrate_worlds_plan(graph: "Graph", root: str, worlds: Dict[str, str], default: Optional[str]) -> List[Tuple[str, str]]:
    """Every file below ROOT that is not inside a world folder, with its target."""
    files: List[str] = []

    def walk(rel: str) -> None:
        path = f"{root}/{rel}" if rel else root
        r = graph.call("GET", f"{graph.drive_path(path)}/children", params={"$top": 200, "$select": "id,name,folder,file"})
        for item in r.get("value") or []:
            name = item.get("name") or ""
            child = f"{rel}/{name}" if rel else name
            if "folder" in item:
                if not rel and any(name.lower() == w.lower() for w in worlds):
                    continue                     # already a world
                walk(child)
            else:
                files.append(child)

    walk("")
    return plan_world_targets(files, root, worlds, default)


def migrate_worlds_apply(graph: "Graph", plan: List[Tuple[str, str]]) -> int:
    """Move and rename each planned file; folders are created as needed."""
    moved = 0
    for src, dst in plan:
        folder, _, name = dst.rpartition("/")
        parent = graph.ensure_folder(folder)
        item = graph.call("GET", graph.drive_path(src), params={"$select": "id"})
        graph.call("PATCH", f"/me/drive/items/{item['id']}", json_body={"parentReference": {"id": parent["id"]}, "name": name})
        moved += 1
    return moved


def ensure_mail_rule(graph: "Graph", alias: str, folder: str) -> Dict[str, Any]:
    """Mail addressed to ALIAS is moved into FOLDER by an inbox rule.

    The folder is created under the mailbox root when missing; the rule is
    keyed by its display name and created once. Idempotent."""
    folders = graph.call("GET", "/me/mailFolders", params={"$top": 200, "$select": "id,displayName"}).get("value") or []
    fid = next((f["id"] for f in folders if (f.get("displayName") or "").lower() == folder.lower()), None)
    created_folder = False
    if fid is None:
        fid = graph.call("POST", "/me/mailFolders", json_body={"displayName": folder})["id"]
        created_folder = True
    name = f"Route {alias} -> {folder}"
    rules = graph.call("GET", "/me/mailFolders/inbox/messageRules").get("value") or []
    existing = next((r for r in rules if r.get("displayName") == name), None)
    created_rule = False
    if existing is None:
        graph.call("POST", "/me/mailFolders/inbox/messageRules", json_body={
            "displayName": name, "sequence": 1, "isEnabled": True,
            "conditions": {"sentToAddresses": [{"emailAddress": {"address": alias}}]},
            "actions": {"moveToFolder": fid, "stopProcessingRules": True}})
        created_rule = True
    return {"alias": alias, "folder": folder, "folder_created": created_folder, "rule_created": created_rule}


def share_with(graph: "Graph", path: str, emails: List[str], role: str = "write", message: str = "",
               send_invitation: bool = True) -> Dict[str, Any]:
    """Grant people access to an item — idempotent: existing grants are kept."""
    item = graph.call("GET", graph.drive_path(path), params={"$select": "id,name"})
    perms = graph.call("GET", f"/me/drive/items/{item['id']}/permissions").get("value") or []
    have = {}
    for perm in perms:
        who = ((perm.get("grantedToV2") or {}).get("user") or (perm.get("grantedTo") or {}).get("user") or {})
        addr = (who.get("email") or "").lower()
        if addr:
            have[addr] = perm.get("roles") or []
    missing = [e for e in emails if e.lower() not in have or role not in have[e.lower()]]
    if missing:
        graph.call("POST", f"/me/drive/items/{item['id']}/invite", json_body={
            "recipients": [{"email": e} for e in missing], "roles": [role], "requireSignIn": True,
            "sendInvitation": send_invitation, "message": message or f"Access to {item.get('name')}"})
    return {"path": path, "role": role, "granted_now": missing, "already_had": [e for e in emails if e not in missing]}


# ---------------------------------------------------------------------------
# The server
# ---------------------------------------------------------------------------

def build_server(graph: Graph) -> McpServer:
    tz = graph.tz
    acct = graph.auth.account
    srv = McpServer(
        name="m365-assistant", version=VERSION,
        instructions=(f"Microsoft 365 for the account {acct} — the BUSINESS world and the default: use these tools for "
                      "work mail, work calendar, Teams meetings and OneDrive files. When the user says 'privat', "
                      "'private', 'privater Termin' or names the Gmail account, use the google_* tools instead. "
                      f"Times are interpreted in {tz} unless a timezone is given; "
                      "use ISO 8601 (2026-09-05T18:00:00). Sending mail, creating or cancelling meetings and "
                      "deleting files are visible to other people — confirm with the user when the request is ambiguous."
                      + (f" The operator's own mailboxes {', '.join(graph.auth.read_mailboxes)} can be READ with the "
                         "`mailbox` parameter of the mail search/read/attachment/folders tools (receipts, invoices, "
                         "letters); nothing is sent, moved or marked there." if graph.auth.read_mailboxes else "")
                      + (f" FILING: everything under {graph.auth.root_folder}/ lives in one of its worlds — "
                         + ", ".join(f"{graph.auth.root_folder}/{w}/ (file names end with '{sfx}' before the extension)" for w, sfx in graph.auth.worlds.items())
                         + " — decide the world first (private or business), then the sub-folder; the drive tools refuse a path that breaks this and say the correct name."
                         if graph.auth.worlds and graph.auth.root_folder else "")))
    WORLD_NOTE = (f" Under {graph.auth.root_folder}/ the next segment is the world ({', '.join(graph.auth.worlds)}) and the file name ends with its suffix ("
                  + ", ".join(f"{w}: '{sfx}'" for w, sfx in graph.auth.worlds.items()) + ")." if graph.auth.worlds and graph.auth.root_folder else "")
    ROOT, WORLDS = graph.auth.root_folder, graph.auth.worlds
    TEXT_NOTE = (f" A document (scan, photo, PDF, Word) under {ROOT}/ is filed together with a Markdown twin of the same name holding its "
                 "recognized text: pass it as text_md (read a photo with your vision first; a PDF with a text layer is extracted for you)." if ROOT else "")
    TEXT_MD = {"text_md": {"type": "string", "description": "the document's recognized text, filed as <same name>.md next to it; required for photos and scans"}}

    def file_companion(path: str, world: Optional[str], name: str, data: Optional[bytes], text_md: Optional[str], if_exists: str) -> Optional[str]:
        """The twin for a document below the root — text checked BEFORE the
        document itself is uploaded (see the callers), written right after."""
        if world is None or not is_document(name):
            return None
        twin = companion_path(path)
        graph.call("PUT", f"{graph.drive_path(twin)}/content", data=companion_markdown(name, world, recognized_text(name, data, text_md)).encode("utf-8"),
                   content_type="text/markdown", params={"@microsoft.graph.conflictBehavior": if_exists})
        return "/" + twin.strip("/")

    ATTENDEE = {"type": "object", "additionalProperties": False, "required": ["email"],
                "properties": {"email": {"type": "string"}, "name": {"type": "string"},
                               "type": {"type": "string", "enum": ["required", "optional", "resource"]}}}

    # -- identity -----------------------------------------------------------
    @srv.tool("m365_whoami", "Which Microsoft 365 account the assistant acts as, and whether the token works.", {"properties": {}})
    def whoami() -> Dict[str, Any]:
        me = graph.call("GET", "/me", params={"$select": "displayName,userPrincipalName,mail,jobTitle,officeLocation"})
        return {"account": me.get("userPrincipalName"), "mail": me.get("mail"), "displayName": me.get("displayName"),
                "timezone": tz}

    # -- mail ---------------------------------------------------------------
    # The read tools take `mailbox` only when other mailboxes are configured;
    # the write tools never do — those act on the assistant's own mailbox.
    readable = list(graph.auth.read_mailboxes or [])
    MAILBOX = ({"mailbox": {"type": "string", "description": "READ another mailbox instead of the assistant's own: one of "
                                                              + ", ".join(readable) + " (the operator's own mail — search, read, attachments only)"}}
               if readable else {})

    @srv.tool("m365_mail_search",
              "List or search messages in a mail folder, newest first. `query` searches subject, body and "
              "sender (Graph $search syntax: plain words, or from:name, subject:word, hasAttachments:true)."
              + (f" With `mailbox` it searches one of the operator's mailboxes ({', '.join(readable)})." if readable else ""),
              {"properties": {"query": {"type": "string"}, "folder": {"type": "string", "description": "inbox (default), archive, sent, drafts, deleted, junk or a folder name"},
                              "top": {"type": "integer", "minimum": 1, "maximum": 50},
                              "unread_only": {"type": "boolean"}, **MAILBOX}})
    def mail_search(query: str = "", folder: str = "inbox", top: int = 10, unread_only: bool = False, mailbox: str = "") -> Dict[str, Any]:
        base = graph.mailbox_path(mailbox)
        fid = graph.folder_id(folder, mailbox)
        params: Dict[str, Any] = {"$top": top, "$select": MESSAGE_SELECT}
        if query:
            params["$search"] = f'"{query}"'
            if unread_only:
                params["$filter"] = "isRead eq false"
        else:
            params["$orderby"] = "receivedDateTime desc"
            if unread_only:
                params["$filter"] = "isRead eq false"
        r = graph.call("GET", f"{base}/mailFolders/{fid}/messages", params=params)
        return {"mailbox": mailbox or acct, "folder": folder, "count": len(r.get("value") or []), "more": "@odata.nextLink" in r,
                "messages": [_msg_shape(m) for m in r.get("value") or []]}

    @srv.tool("m365_mail_read", "Read one message: text body and the list of attachments.",
              {"properties": {"message_id": {"type": "string"}, "max_chars": {"type": "integer", "minimum": 200, "maximum": 200000}, **MAILBOX},
               "required": ["message_id"]})
    def mail_read(message_id: str, max_chars: int = 20000, mailbox: str = "") -> Dict[str, Any]:
        base = graph.mailbox_path(mailbox)
        m = graph.call("GET", f"{base}/messages/{message_id}", prefer='outlook.body-content-type="text"',
                       params={"$select": MESSAGE_SELECT + ",body,replyTo"})
        out = _msg_shape(m)
        body = (m.get("body") or {}).get("content") or ""
        out["body"] = body[:max_chars]
        out["bodyTruncated"] = len(body) > max_chars
        if m.get("hasAttachments"):
            a = graph.call("GET", f"{base}/messages/{message_id}/attachments",
                           params={"$select": "id,name,size,contentType,isInline"})
            out["attachments"] = [{"id": x.get("id"), "name": x.get("name"), "size": x.get("size"),
                                   "contentType": x.get("contentType"), "isInline": x.get("isInline")}
                                  for x in a.get("value") or []]
        return out

    @srv.tool("m365_mail_attachment_text", "Text of a mail attachment (pdf, docx, plain text). Use for letters and documents the user sent.",
              {"properties": {"message_id": {"type": "string"}, "attachment_id": {"type": "string"},
                              "max_chars": {"type": "integer", "minimum": 200, "maximum": 200000}, **MAILBOX},
               "required": ["message_id", "attachment_id"]})
    def mail_attachment_text(message_id: str, attachment_id: str, max_chars: int = 20000, mailbox: str = "") -> Dict[str, Any]:
        a = graph.call("GET", f"{graph.mailbox_path(mailbox)}/messages/{message_id}/attachments/{attachment_id}")
        if a.get("@odata.type") != "#microsoft.graph.fileAttachment":
            return {"name": a.get("name"), "supported": False, "note": f"attachment type {a.get('@odata.type')} is not a file"}
        return extract_text(a.get("name") or "attachment", unb64(a.get("contentBytes") or ""), max_chars)

    @srv.tool("m365_mail_send", f"Send a new e-mail from {acct}. Attachments are base64 (small files) — for large files share a OneDrive link instead.",
              {"properties": {"to": {"type": "array", "items": {"type": "string"}, "minItems": 1},
                              "subject": {"type": "string"}, "body": {"type": "string"},
                              "cc": {"type": "array", "items": {"type": "string"}},
                              "bcc": {"type": "array", "items": {"type": "string"}},
                              "body_type": {"type": "string", "enum": ["text", "html"]},
                              "importance": {"type": "string", "enum": ["low", "normal", "high"]},
                              "attachments": {"type": "array", "items": {"type": "object", "additionalProperties": False,
                                                                          "required": ["name", "content_base64"],
                                                                          "properties": {"name": {"type": "string"}, "content_base64": {"type": "string"},
                                                                                         "content_type": {"type": "string"}}}}},
               "required": ["to", "subject", "body"]})
    def mail_send(to: List[str], subject: str, body: str, cc: Optional[List[str]] = None, bcc: Optional[List[str]] = None,
                  body_type: str = "text", importance: str = "normal", attachments: Optional[List[Dict[str, str]]] = None) -> Dict[str, Any]:
        msg: Dict[str, Any] = {"subject": subject, "body": {"contentType": body_type, "content": body},
                               "toRecipients": _recipients(to), "importance": importance}
        if cc:
            msg["ccRecipients"] = _recipients(cc)
        if bcc:
            msg["bccRecipients"] = _recipients(bcc)
        if attachments:
            msg["attachments"] = [{"@odata.type": "#microsoft.graph.fileAttachment", "name": a["name"],
                                   "contentType": a.get("content_type") or "application/octet-stream",
                                   "contentBytes": a["content_base64"]} for a in attachments]
        graph.call("POST", "/me/sendMail", json_body={"message": msg, "saveToSentItems": True})
        return {"sent": True, "from": acct, "to": to, "cc": cc or [], "subject": subject}

    @srv.tool("m365_mail_reply", "Reply to a message (the original is quoted by Exchange).",
              {"properties": {"message_id": {"type": "string"}, "comment": {"type": "string"}, "reply_all": {"type": "boolean"}},
               "required": ["message_id", "comment"]})
    def mail_reply(message_id: str, comment: str, reply_all: bool = False) -> Dict[str, Any]:
        graph.call("POST", f"/me/messages/{message_id}/{'replyAll' if reply_all else 'reply'}", json_body={"comment": comment})
        return {"replied": True, "reply_all": reply_all}

    @srv.tool("m365_mail_move", "Move a message to a folder (archive, deleted, inbox, or a folder name).",
              {"properties": {"message_id": {"type": "string"}, "destination": {"type": "string"}}, "required": ["message_id", "destination"]})
    def mail_move(message_id: str, destination: str) -> Dict[str, Any]:
        m = graph.call("POST", f"/me/messages/{message_id}/move", json_body={"destinationId": graph.folder_id(destination)})
        return {"moved": True, "destination": destination, "new_id": m.get("id")}

    @srv.tool("m365_mail_mark", "Mark a message read or unread.",
              {"properties": {"message_id": {"type": "string"}, "is_read": {"type": "boolean"}}, "required": ["message_id", "is_read"]})
    def mail_mark(message_id: str, is_read: bool) -> Dict[str, Any]:
        graph.call("PATCH", f"/me/messages/{message_id}", json_body={"isRead": is_read})
        return {"id": message_id, "isRead": is_read}

    @srv.tool("m365_mail_folders", "List the mail folders with their unread and total counts.", {"properties": {**MAILBOX}})
    def mail_folders(mailbox: str = "") -> Dict[str, Any]:
        r = graph.call("GET", f"{graph.mailbox_path(mailbox)}/mailFolders", params={"$top": 100, "$select": "id,displayName,unreadItemCount,totalItemCount,childFolderCount"})
        return {"mailbox": mailbox or acct, "folders": [{"name": f.get("displayName"), "unread": f.get("unreadItemCount"), "total": f.get("totalItemCount"),
                             "subfolders": f.get("childFolderCount")} for f in r.get("value") or []]}

    # -- calendar -----------------------------------------------------------
    @srv.tool("m365_calendar_view", f"Events between two instants (ISO 8601, interpreted in {tz} unless they carry an offset), including recurring instances.",
              {"properties": {"start": {"type": "string"}, "end": {"type": "string"},
                              "top": {"type": "integer", "minimum": 1, "maximum": 200}}, "required": ["start", "end"]})
    def calendar_view(start: str, end: str, top: int = 50) -> Dict[str, Any]:
        r = graph.call("GET", "/me/calendarView", prefer=f'outlook.timezone="{tz}"',
                       params={"startDateTime": start, "endDateTime": end, "$top": top, "$orderby": "start/dateTime", "$select": EVENT_SELECT})
        return {"timezone": tz, "count": len(r.get("value") or []), "more": "@odata.nextLink" in r,
                "events": [_event_shape(e) for e in r.get("value") or []]}

    @srv.tool("m365_event_get", "One event with its full details and description.",
              {"properties": {"event_id": {"type": "string"}}, "required": ["event_id"]})
    def event_get(event_id: str) -> Dict[str, Any]:
        e = graph.call("GET", f"/me/events/{event_id}", prefer=f'outlook.timezone="{tz}",outlook.body-content-type="text"',
                       params={"$select": EVENT_SELECT + ",body"})
        out = _event_shape(e)
        out["body"] = ((e.get("body") or {}).get("content") or "")[:20000]
        return out

    def set_roles(join_url: str, coorganizers: List[str], presenters: List[str]) -> Dict[str, Any]:
        found = graph.call("GET", "/me/onlineMeetings", params={"$filter": f"JoinWebUrl eq '{join_url}'"})
        meetings = found.get("value") or []
        if not meetings:
            return {"applied": False, "note": "the Teams meeting was not found by its join URL; roles not set"}
        mid = meetings[0]["id"]
        attendees = [{"upn": u, "role": "coorganizer"} for u in coorganizers] + \
                    [{"upn": u, "role": "presenter"} for u in presenters]
        body = {"participants": {"attendees": attendees}, "allowedPresenters": "roleIsPresenter"}
        graph.call("PATCH", f"/me/onlineMeetings/{mid}", json_body=body)
        return {"applied": True, "coorganizers": coorganizers, "presenters": presenters,
                "note": "co-organizers must be accounts of this tenant; guests can be presenters"}

    @srv.tool("m365_event_create",
              f"Create a calendar event from {acct}; invitations go out by mail automatically. `online_meeting` adds a Teams "
              "meeting link. `coorganizers` (tenant accounts, e.g. the user) and `presenters` (may be external) set the Teams "
              "meeting roles — everyone else joins as attendee. Anyone named in the roles is invited as an attendee too.",
              {"properties": {"subject": {"type": "string"}, "start": {"type": "string"}, "end": {"type": "string"},
                              "timezone": {"type": "string"}, "attendees": {"type": "array", "items": ATTENDEE},
                              "body": {"type": "string"}, "body_type": {"type": "string", "enum": ["text", "html"]},
                              "location": {"type": "string"}, "online_meeting": {"type": "boolean"},
                              "coorganizers": {"type": "array", "items": {"type": "string"}},
                              "presenters": {"type": "array", "items": {"type": "string"}},
                              "reminder_minutes": {"type": "integer", "minimum": 0},
                              "all_day": {"type": "boolean"}, "categories": {"type": "array", "items": {"type": "string"}},
                              "show_as": {"type": "string", "enum": ["free", "tentative", "busy", "oof"]}},
               "required": ["subject", "start", "end"]})
    def event_create(subject: str, start: str, end: str, timezone: Optional[str] = None, attendees: Optional[List[Dict[str, str]]] = None,
                     body: str = "", body_type: str = "text", location: str = "", online_meeting: bool = False,
                     coorganizers: Optional[List[str]] = None, presenters: Optional[List[str]] = None,
                     reminder_minutes: Optional[int] = None, all_day: bool = False, categories: Optional[List[str]] = None,
                     show_as: Optional[str] = None) -> Dict[str, Any]:
        zone = timezone or tz
        coorganizers = [c.strip() for c in coorganizers or [] if c.strip()]
        presenters = [p.strip() for p in presenters or [] if p.strip()]
        att = list(attendees or [])
        known = {a["email"].lower() for a in att}
        for who in coorganizers + presenters:
            if who.lower() not in known:
                att.append({"email": who, "type": "required"})
                known.add(who.lower())
        ev: Dict[str, Any] = {
            "subject": subject, "start": _when(start, zone), "end": _when(end, zone), "isAllDay": all_day,
            "body": {"contentType": body_type, "content": body},
            "attendees": [{"emailAddress": {"address": a["email"], **({"name": a["name"]} if a.get("name") else {})},
                           "type": a.get("type") or "required"} for a in att],
        }
        if location:
            ev["location"] = {"displayName": location}
        if online_meeting or coorganizers or presenters:
            ev["isOnlineMeeting"] = True
            ev["onlineMeetingProvider"] = "teamsForBusiness"
        if reminder_minutes is not None:
            ev["isReminderOn"] = True
            ev["reminderMinutesBeforeStart"] = reminder_minutes
        if categories:
            ev["categories"] = categories
        if show_as:
            ev["showAs"] = show_as
        created = graph.call("POST", "/me/events", json_body=ev, prefer=f'outlook.timezone="{zone}"')
        out = _event_shape(created)
        out["invitations"] = "sent by Exchange to every attendee"
        if coorganizers or presenters:
            join = (created.get("onlineMeeting") or {}).get("joinUrl")
            if join:
                # The onlineMeeting object lags the event by a moment.
                last: Dict[str, Any] = {}
                for attempt in range(6):
                    last = set_roles(join, coorganizers, presenters)
                    if last.get("applied"):
                        break
                    time.sleep(2 + attempt * 2)
                out["roles"] = last
            else:
                out["roles"] = {"applied": False, "note": "no Teams join URL on the created event"}
        return out

    @srv.tool("m365_event_update",
              "Change an event the account organizes. Only the given fields change; `attendees` replaces the list. "
              "Updates are sent to attendees.",
              {"properties": {"event_id": {"type": "string"}, "subject": {"type": "string"}, "start": {"type": "string"},
                              "end": {"type": "string"}, "timezone": {"type": "string"}, "location": {"type": "string"},
                              "body": {"type": "string"}, "body_type": {"type": "string", "enum": ["text", "html"]},
                              "attendees": {"type": "array", "items": ATTENDEE}, "online_meeting": {"type": "boolean"},
                              "coorganizers": {"type": "array", "items": {"type": "string"}},
                              "presenters": {"type": "array", "items": {"type": "string"}},
                              "reminder_minutes": {"type": "integer", "minimum": 0},
                              "categories": {"type": "array", "items": {"type": "string"}},
                              "show_as": {"type": "string", "enum": ["free", "tentative", "busy", "oof"]}},
               "required": ["event_id"]})
    def event_update(event_id: str, **fields: Any) -> Dict[str, Any]:
        zone = fields.pop("timezone", None) or tz
        patch: Dict[str, Any] = {}
        if "subject" in fields:
            patch["subject"] = fields["subject"]
        if "start" in fields:
            patch["start"] = _when(fields["start"], zone)
        if "end" in fields:
            patch["end"] = _when(fields["end"], zone)
        if "location" in fields:
            patch["location"] = {"displayName": fields["location"]}
        if "body" in fields:
            patch["body"] = {"contentType": fields.get("body_type") or "text", "content": fields["body"]}
        if "attendees" in fields:
            patch["attendees"] = [{"emailAddress": {"address": a["email"], **({"name": a["name"]} if a.get("name") else {})},
                                   "type": a.get("type") or "required"} for a in fields["attendees"]]
        if fields.get("online_meeting"):
            patch["isOnlineMeeting"] = True
            patch["onlineMeetingProvider"] = "teamsForBusiness"
        if "reminder_minutes" in fields:
            patch["isReminderOn"] = True
            patch["reminderMinutesBeforeStart"] = fields["reminder_minutes"]
        if "categories" in fields:
            patch["categories"] = fields["categories"]
        if "show_as" in fields:
            patch["showAs"] = fields["show_as"]
        ev = graph.call("PATCH", f"/me/events/{event_id}", json_body=patch, prefer=f'outlook.timezone="{zone}"') if patch \
            else graph.call("GET", f"/me/events/{event_id}", params={"$select": EVENT_SELECT}, prefer=f'outlook.timezone="{zone}"')
        out = _event_shape(ev)
        co, pr = fields.get("coorganizers"), fields.get("presenters")
        if co or pr:
            join = (ev.get("onlineMeeting") or {}).get("joinUrl")
            out["roles"] = set_roles(join, co or [], pr or []) if join else {"applied": False, "note": "event has no Teams meeting"}
        return out

    @srv.tool("m365_event_cancel", "Cancel an event the account organizes (attendees get the cancellation), or decline one it was invited to.",
              {"properties": {"event_id": {"type": "string"}, "comment": {"type": "string"}}, "required": ["event_id"]})
    def event_cancel(event_id: str, comment: str = "") -> Dict[str, Any]:
        e = graph.call("GET", f"/me/events/{event_id}", params={"$select": "id,subject,isOrganizer"})
        if e.get("isOrganizer"):
            graph.call("POST", f"/me/events/{event_id}/cancel", json_body={"comment": comment})
            return {"cancelled": True, "subject": e.get("subject"), "attendees_notified": True}
        graph.call("POST", f"/me/events/{event_id}/decline", json_body={"comment": comment, "sendResponse": True})
        return {"cancelled": False, "declined": True, "subject": e.get("subject"), "note": "not the organizer, so declined instead"}

    @srv.tool("m365_event_respond", "Accept, tentatively accept or decline an invitation.",
              {"properties": {"event_id": {"type": "string"}, "response": {"type": "string", "enum": ["accept", "tentativelyAccept", "decline"]},
                              "comment": {"type": "string"}}, "required": ["event_id", "response"]})
    def event_respond(event_id: str, response: str, comment: str = "") -> Dict[str, Any]:
        graph.call("POST", f"/me/events/{event_id}/{response}", json_body={"comment": comment, "sendResponse": True})
        return {"event_id": event_id, "response": response}

    @srv.tool("m365_find_meeting_times", "Suggest free slots for the account and the given attendees inside a time window.",
              {"properties": {"attendees": {"type": "array", "items": {"type": "string"}}, "duration_minutes": {"type": "integer", "minimum": 5},
                              "window_start": {"type": "string"}, "window_end": {"type": "string"}, "timezone": {"type": "string"},
                              "max_candidates": {"type": "integer", "minimum": 1, "maximum": 20}},
               "required": ["duration_minutes", "window_start", "window_end"]})
    def find_meeting_times(duration_minutes: int, window_start: str, window_end: str, attendees: Optional[List[str]] = None,
                           timezone: Optional[str] = None, max_candidates: int = 5) -> Dict[str, Any]:
        zone = timezone or tz
        h, m = divmod(int(duration_minutes), 60)
        body = {"attendees": [{"emailAddress": {"address": a}, "type": "required"} for a in attendees or []],
                "timeConstraint": {"activityDomain": "work", "timeSlots": [{"start": _when(window_start, zone), "end": _when(window_end, zone)}]},
                "meetingDuration": f"PT{h}H{m}M", "maxCandidates": max_candidates, "isOrganizerOptional": False,
                "returnSuggestionReasons": True}
        r = graph.call("POST", "/me/findMeetingTimes", json_body=body, prefer=f'outlook.timezone="{zone}"')
        return {"timezone": zone, "emptySuggestionsReason": r.get("emptySuggestionsReason") or None,
                "suggestions": [{"start": (s.get("meetingTimeSlot") or {}).get("start", {}).get("dateTime"),
                                 "end": (s.get("meetingTimeSlot") or {}).get("end", {}).get("dateTime"),
                                 "confidence": s.get("confidence"), "reason": s.get("suggestionReason"),
                                 "availability": [{"who": _addr(a.get("attendee")), "availability": a.get("availability")}
                                                  for a in s.get("attendeeAvailability") or []]}
                                for s in r.get("meetingTimeSuggestions") or []]}

    # -- OneDrive -----------------------------------------------------------
    @srv.tool("m365_drive_list", "List a OneDrive folder (path like 'Assistant/Inbox'; empty for the root).",
              {"properties": {"path": {"type": "string"}, "top": {"type": "integer", "minimum": 1, "maximum": 200}}})
    def drive_list(path: str = "", top: int = 100) -> Dict[str, Any]:
        r = graph.call("GET", f"{graph.drive_path(path)}/children", params={"$top": top, "$orderby": "name"})
        return {"path": "/" + path.strip("/"), "count": len(r.get("value") or []), "more": "@odata.nextLink" in r,
                "items": [_item_shape(i) for i in r.get("value") or []]}

    @srv.tool("m365_drive_search", "Search OneDrive by file name and content.",
              {"properties": {"query": {"type": "string"}, "top": {"type": "integer", "minimum": 1, "maximum": 100}}, "required": ["query"]})
    def drive_search(query: str, top: int = 25) -> Dict[str, Any]:
        q = query.replace("'", "''")
        r = graph.call("GET", f"/me/drive/root/search(q='{urllib.parse.quote(q)}')", params={"$top": top})
        return {"count": len(r.get("value") or []), "items": [_item_shape(i) for i in r.get("value") or []]}

    @srv.tool("m365_drive_read", "Text content of a OneDrive file (pdf, docx, plain text) by path.",
              {"properties": {"path": {"type": "string"}, "max_chars": {"type": "integer", "minimum": 200, "maximum": 200000}}, "required": ["path"]})
    def drive_read(path: str, max_chars: int = 20000) -> Dict[str, Any]:
        meta = graph.call("GET", graph.drive_path(path), params={"$select": "id,name,size,file,folder,@microsoft.graph.downloadUrl"})
        if "folder" in meta:
            return {"path": path, "supported": False, "note": "that is a folder; use m365_drive_list"}
        url = meta.get("@microsoft.graph.downloadUrl")
        data = graph.download(url) if url else graph.call("GET", f"/me/drive/items/{meta['id']}/content", raw=True)[0]
        out = extract_text(meta.get("name") or path, data, max_chars)
        out["path"] = path
        return out

    @srv.tool("m365_drive_upload", "Create or replace a file in OneDrive by path (folders are created). Text or base64 content, up to 4 MB." + WORLD_NOTE + TEXT_NOTE,
              {"properties": {"path": {"type": "string"}, "content": {"type": "string"}, "content_base64": {"type": "string"},
                              "if_exists": {"type": "string", "enum": ["replace", "fail", "rename"]}, **TEXT_MD}, "required": ["path"]})
    def drive_upload(path: str, content: Optional[str] = None, content_base64: Optional[str] = None, if_exists: str = "replace",
                     text_md: Optional[str] = None) -> Dict[str, Any]:
        world = world_check(path, ROOT, WORLDS)
        if (content is None) == (content_base64 is None):
            raise ValueError("give exactly one of content or content_base64")
        data = content.encode("utf-8") if content is not None else unb64(content_base64 or "")
        if len(data) > UPLOAD_LIMIT:
            raise ValueError(f"{len(data)} bytes exceeds the 4 MB simple-upload limit")
        folder, _, name = path.strip("/").rpartition("/")
        if not name:
            raise ValueError("path must name a file")
        if world is not None and is_document(name):
            recognized_text(name, data, text_md)          # refuse before anything is written
        if folder:
            graph.ensure_folder(folder)
        item = graph.call("PUT", f"{graph.drive_path(path)}/content", data=data, content_type="application/octet-stream",
                          params={"@microsoft.graph.conflictBehavior": if_exists})
        out = _item_shape(item)
        twin = file_companion(path, world, name, data, text_md, if_exists)
        if twin:
            out["companion"] = twin
        return out

    @srv.tool("m365_drive_upload_file",
              "Upload a file that exists on this machine (e.g. a PDF you generated) to OneDrive by path, then delete the local copy. "
              "Use this for every document you produce: nothing stays on the server. Large files are uploaded in chunks." + WORLD_NOTE + TEXT_NOTE,
              {"properties": {"local_path": {"type": "string"}, "path": {"type": "string", "description": "destination path in OneDrive, e.g. <root>/<World>/Reports/2026/2026-09-06 trip plan<suffix>.pdf"},
                              "if_exists": {"type": "string", "enum": ["replace", "fail", "rename"]}, "keep_local": {"type": "boolean"}, **TEXT_MD},
               "required": ["local_path", "path"]})
    def drive_upload_file(local_path: str, path: str, if_exists: str = "replace", keep_local: bool = False,
                          text_md: Optional[str] = None) -> Dict[str, Any]:
        world = world_check(path, ROOT, WORLDS)
        local = os.path.expanduser(local_path)
        if not os.path.isfile(local):
            raise ValueError(f"no such file on this machine: {local_path}")
        size = os.path.getsize(local)
        folder, _, name = path.strip("/").rpartition("/")
        if not name:
            raise ValueError("path must name a file")
        twin_data: Optional[bytes] = None
        if world is not None and is_document(name):
            with open(local, "rb") as fh:
                twin_data = fh.read() if size <= 50 * 1024 * 1024 else None
            recognized_text(name, twin_data, text_md)     # refuse before anything is written
        if folder:
            graph.ensure_folder(folder)
        if size <= UPLOAD_LIMIT:
            with open(local, "rb") as f:
                data = f.read()
            item = graph.call("PUT", f"{graph.drive_path(path)}/content", data=data, content_type="application/octet-stream",
                              params={"@microsoft.graph.conflictBehavior": if_exists})
        else:
            item = upload_session(graph, path, local, size, if_exists)
        out = _item_shape(item)
        twin = file_companion(path, world, name, twin_data, text_md, if_exists)
        if twin:
            out["companion"] = twin
        if not keep_local:
            os.remove(local)
            out["local_removed"] = True
        return out

    @srv.tool("m365_drive_download", "Download a OneDrive file to this machine (a temporary path is returned) — to read a photo or scan "
              "with your vision before filing its text. Remove the local copy when done.",
              {"properties": {"path": {"type": "string"}}, "required": ["path"]})
    def drive_download(path: str) -> Dict[str, Any]:
        meta = graph.call("GET", graph.drive_path(path), params={"$select": "id,name,size,file,@microsoft.graph.downloadUrl"})
        url = meta.get("@microsoft.graph.downloadUrl")
        data = graph.download(url) if url else graph.call("GET", f"/me/drive/items/{meta['id']}/content", raw=True)[0]
        local_dir = tempfile.mkdtemp(prefix="onedrive-")
        local = os.path.join(local_dir, meta.get("name") or "file")
        with open(local, "wb") as fh:
            fh.write(data)
        return {"path": "/" + path.strip("/"), "local_path": local, "size": len(data)}

    @srv.tool("m365_drive_missing_text", f"Documents below {ROOT or 'the root folder'} that have no Markdown twin yet (scans, photos, PDFs filed without their text).",
              {"properties": {"path": {"type": "string", "description": "start folder; default the root folder"}}})
    def drive_missing_text(path: str = "") -> Dict[str, Any]:
        start = (path or ROOT).strip("/")
        if not start:
            raise ValueError("no root folder configured; give a path")
        return {"path": "/" + start, "missing": missing_companions(graph, start)}

    @srv.tool("m365_drive_mkdir", "Create a folder path in OneDrive (existing parts are kept).",
              {"properties": {"path": {"type": "string"}}, "required": ["path"]})
    def drive_mkdir(path: str) -> Dict[str, Any]:
        world_check(path, ROOT, WORLDS, is_folder=True)
        item = graph.ensure_folder(path)
        return {"path": "/" + path.strip("/"), "id": item.get("id"), "created_or_existing": True}

    @srv.tool("m365_drive_move", "Move and/or rename a file or folder.",
              {"properties": {"path": {"type": "string"}, "new_parent": {"type": "string", "description": "destination folder path; empty keeps the folder"},
                              "new_name": {"type": "string"}}, "required": ["path"]})
    def drive_move(path: str, new_parent: Optional[str] = None, new_name: Optional[str] = None) -> Dict[str, Any]:
        item = graph.call("GET", graph.drive_path(path), params={"$select": "id,name,folder"})
        folder_now, _, name_now = path.strip("/").rpartition("/")
        target = "/".join(x for x in [(new_parent if new_parent is not None else folder_now).strip("/"), new_name or name_now] if x)
        world_check(target, ROOT, WORLDS, is_folder="folder" in item)
        patch: Dict[str, Any] = {}
        if new_parent is not None:
            parent = graph.ensure_folder(new_parent) if new_parent.strip("/") else {"id": graph.call("GET", "/me/drive/root", params={"$select": "id"})["id"]}
            patch["parentReference"] = {"id": parent["id"]}
        if new_name:
            patch["name"] = new_name
        if not patch:
            raise ValueError("nothing to do: give new_parent and/or new_name")
        moved = graph.call("PATCH", f"/me/drive/items/{item['id']}", json_body=patch)
        return _item_shape(moved)

    @srv.tool("m365_drive_delete", "Delete a file or folder (it goes to the OneDrive recycle bin).",
              {"properties": {"path": {"type": "string"}}, "required": ["path"]})
    def drive_delete(path: str) -> Dict[str, Any]:
        item = graph.call("GET", graph.drive_path(path), params={"$select": "id,name"})
        graph.call("DELETE", f"/me/drive/items/{item['id']}")
        return {"deleted": True, "path": path, "note": "recoverable from the recycle bin"}

    @srv.tool("m365_drive_share_with", "Give named people access to a file or folder (they get an invitation mail unless told otherwise).",
              {"properties": {"path": {"type": "string"}, "emails": {"type": "array", "items": {"type": "string"}, "minItems": 1},
                              "role": {"type": "string", "enum": ["read", "write"]}, "message": {"type": "string"},
                              "send_invitation": {"type": "boolean"}}, "required": ["path", "emails"]})
    def drive_share_with(path: str, emails: List[str], role: str = "write", message: str = "", send_invitation: bool = True) -> Dict[str, Any]:
        return share_with(graph, path, emails, role, message, send_invitation)

    @srv.tool("m365_drive_share_link", "Create a sharing link for a file or folder.",
              {"properties": {"path": {"type": "string"}, "type": {"type": "string", "enum": ["view", "edit"]},
                              "scope": {"type": "string", "enum": ["anonymous", "organization"]}}, "required": ["path"]})
    def drive_share_link(path: str, type: str = "view", scope: str = "organization") -> Dict[str, Any]:  # noqa: A002
        item = graph.call("GET", graph.drive_path(path), params={"$select": "id,name"})
        r = graph.call("POST", f"/me/drive/items/{item['id']}/createLink", json_body={"type": type, "scope": scope})
        return {"path": path, "type": type, "scope": scope, "url": (r.get("link") or {}).get("webUrl")}

    return srv


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: List[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "serve"
    auth = Auth()
    tz = os.environ.get("M365_TIMEZONE", "").strip() or "Europe/Zurich"
    if cmd == "login":
        timeout = int(argv[2]) if len(argv) > 2 else 900
        me = auth.device_login(timeout)
        print(json.dumps({"signed_in": True, "account": me.get("userPrincipalName"), "displayName": me.get("displayName")}))
        return 0
    if cmd == "status":
        if not auth.store.refresh_token:
            print(json.dumps({"ok": False, "account": auth.account, "reason": "no token stored; sign-in needed"}))
            return 1
        try:
            graph = Graph(auth, tz)
            me = graph.call("GET", "/me", params={"$select": "userPrincipalName,displayName"})
        except Exception as e:  # noqa: BLE001
            print(json.dumps({"ok": False, "account": auth.account, "reason": str(e)[:400]}))
            return 1
        ok = (me.get("userPrincipalName") or "").lower() == auth.account
        print(json.dumps({"ok": ok, "account": me.get("userPrincipalName"), "displayName": me.get("displayName"),
                          "scopes": auth.store.data.get("scopes"), "token_file": auth.store.path,
                          "read_mailboxes": auth.read_mailboxes}))
        return 0 if ok else 1
    if cmd == "companions":
        # companions [--apply] — documents below the root without a Markdown
        # twin; --apply writes the twin where the text can be extracted (PDF,
        # Word) and lists what needs the Secretary's eyes (photos, scans).
        if not auth.root_folder:
            raise SystemExit("no root folder configured (M365_ROOT_FOLDER)")
        graph = Graph(auth, tz)
        missing = missing_companions(graph, auth.root_folder)
        if not missing:
            print("every document below the root has its text twin")
            return 0
        if "--apply" in argv[2:]:
            done, eyes = companions_apply(graph, missing, auth.root_folder, auth.worlds)
            for d in done:
                print(f"written: {d}")
            for e in eyes:
                print(f"needs the Secretary's eyes (image or no text layer): {e}")
        else:
            for m in missing:
                print(f"missing twin: {m}")
            print(f"{len(missing)} document(s); re-run with --apply to write the twins the server can extract")
        return 0
    if cmd == "move":
        # move SOURCE TARGET — one file or folder, target folders created; the
        # worlds rule applies as it does for the bot.
        if len(argv) < 4:
            raise SystemExit("usage: move SOURCE TARGET")
        graph = Graph(auth, tz)
        src, dst = argv[2].strip("/"), argv[3].strip("/")
        item = graph.call("GET", graph.drive_path(src), params={"$select": "id,name,folder"})
        world_check(dst, auth.root_folder, auth.worlds, is_folder="folder" in item)
        folder, _, name = dst.rpartition("/")
        parent = graph.ensure_folder(folder) if folder else {"id": graph.call("GET", "/me/drive/root", params={"$select": "id"})["id"]}
        moved = graph.call("PATCH", f"/me/drive/items/{item['id']}", json_body={"parentReference": {"id": parent["id"]}, "name": name})
        print(json.dumps(_item_shape(moved)))
        return 0
    if cmd == "migrate-worlds":
        # migrate-worlds [--apply] [--default=World] — existing files below the
        # root folder that are not in a world yet: show where they would go
        # (the default world, with the suffix), move them only with --apply.
        if not auth.worlds or not auth.root_folder:
            raise SystemExit("no worlds configured (M365_WORLDS / M365_ROOT_FOLDER)")
        apply = "--apply" in argv[2:]
        default = next((a.split("=", 1)[1] for a in argv[2:] if a.startswith("--default=")), None)
        graph = Graph(auth, tz)
        plan = migrate_worlds_plan(graph, auth.root_folder, auth.worlds, default)
        for src, dst in plan:
            print(f"{src} -> {dst}")
        if not plan:
            print("nothing to move: everything below the root is already in a world")
            return 0
        if apply:
            print(f"moved {migrate_worlds_apply(graph, plan)} file(s)")
        else:
            print(f"{len(plan)} file(s) would move; re-run with --apply to do it")
        return 0
    if cmd == "check-mailbox":
        # check-mailbox ADDRESS — the installer's "can the assistant read that
        # inbox?" Exit 1 with Graph's reason when it cannot (no delegation yet).
        if len(argv) < 3:
            raise SystemExit("usage: check-mailbox ADDRESS")
        try:
            print(json.dumps(Graph(auth, tz).mailbox_probe(argv[2])))
            return 0
        except Exception as e:  # noqa: BLE001
            print(json.dumps({"mailbox": argv[2].lower(), "readable": False, "reason": str(e)[:400]}))
            return 1
    if cmd == "ensure-folder":
        # ensure-folder PATH [EMAIL,EMAIL [read|write]] — the installer's idempotent
        # "the Secretary's folder exists and the operator can edit it".
        if len(argv) < 3:
            raise SystemExit("usage: ensure-folder PATH [EMAILS [read|write]]")
        graph = Graph(auth, tz)
        item = graph.ensure_folder(argv[2])
        out: Dict[str, Any] = {"path": "/" + argv[2].strip("/"), "id": item.get("id")}
        if len(argv) > 3 and argv[3].strip():
            who = [e.strip() for e in argv[3].split(",") if e.strip()]
            out["share"] = share_with(graph, argv[2], who, argv[4] if len(argv) > 4 else "write", send_invitation=False)
        print(json.dumps(out))
        return 0
    if cmd == "ensure-mail-rule":
        if len(argv) < 4:
            raise SystemExit("usage: ensure-mail-rule ALIAS FOLDER")
        print(json.dumps(ensure_mail_rule(Graph(auth, tz), argv[2], argv[3])))
        return 0
    if cmd == "tools":
        srv = build_server(Graph(auth, tz))
        print(json.dumps([t.spec() for t in srv.tools], indent=1))
        return 0
    if cmd == "serve":
        build_server(Graph(auth, tz)).serve_stdio()
        return 0
    sys.stderr.write(__doc__ or "")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except KeyboardInterrupt:
        sys.exit(130)
