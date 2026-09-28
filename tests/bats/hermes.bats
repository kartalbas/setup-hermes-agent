#!/usr/bin/env bats
#
# The agent module's carried patches.

setup() {
    load helper
    load_libs
    silence_logs
    DRY_RUN=true
    SCRIPT_DIR=$REPO_ROOT
    config_defaults
}

@test "the Teams link patch adds the hrefs of named links to the text, once" {
    tmp=$(mktemp -d)
    cat >"${tmp}/adapter.py" <<'PY'
def handle(activity, text, att):
    for att in getattr(activity, "attachments", None) or []:
        content_url = getattr(att, "content_url", None)
        content_type = (getattr(att, "content_type", None) or "").lower()
        if True:
            if content_type in ("text/html", "text/plain") and not content_url:
                continue
    return text
PY
    hermes_patch_teams_links_file "${tmp}/adapter.py"
    grep -q 'setup-hermes-agent: named links' "${tmp}/adapter.py"
    grep -q '(link: ' "${tmp}/adapter.py"
    bats_run hermes_patch_teams_links_file "${tmp}/adapter.py"; [ "$status" -eq 3 ]
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "${tmp}/adapter.py"
    # the patched loop hands the URL over: exercise the generated code with a fake attachment
    python3 - "${tmp}/adapter.py" <<'PY'
import sys, types
ns = {}; exec(open(sys.argv[1]).read(), ns)
att = types.SimpleNamespace(content_url=None, content_type="text/html", content='<p>Bericht: <a href="https://tenant.sharepoint.example/sites/x/Doc.pdf?web=1&amp;e=1">Doc.pdf</a></p>')
activity = types.SimpleNamespace(attachments=[att])
out = ns["handle"](activity, "Bericht: Doc.pdf", None)
assert out == "Bericht: Doc.pdf\n(link: https://tenant.sharepoint.example/sites/x/Doc.pdf?web=1&e=1)", out
PY
    rm -rf "$tmp"
}

@test "the help patch answers a bare /help from HELP.md and leaves /help all alone" {
    tmp=$(mktemp -d)
    cat >"${tmp}/slash_commands.py" <<'PY'
import os
class MessageEvent: pass
class H:
    async def _handle_help_command(self, event: MessageEvent) -> str:
        """Handle /help command - list available commands."""
        return "DEVELOPER LIST"
PY
    hermes_patch_help_file "${tmp}/slash_commands.py"
    grep -q 'setup-hermes-agent: curated help' "${tmp}/slash_commands.py"
    bats_run hermes_patch_help_file "${tmp}/slash_commands.py"; [ "$status" -eq 3 ]
    python3 - "${tmp}" <<'PY'
import asyncio, os, sys, types
tmp = sys.argv[1]
os.makedirs(os.path.join(tmp, "home"), exist_ok=True)
open(os.path.join(tmp, "home", "HELP.md"), "w").write("**Bot**\nshort help\n")
run = types.ModuleType("gateway.run"); run._hermes_home = os.path.join(tmp, "home")
gw = types.ModuleType("gateway"); gw.run = run
sys.modules["gateway"] = gw; sys.modules["gateway.run"] = run
ns = {}; exec(open(os.path.join(tmp, "slash_commands.py")).read(), ns)
class Ev:
    def __init__(self, a): self.a = a
    def get_command_args(self): return self.a
h = ns["H"]()
assert asyncio.run(h._handle_help_command(Ev(""))) == "**Bot**\nshort help"
assert asyncio.run(h._handle_help_command(Ev("all"))) == "DEVELOPER LIST"
assert asyncio.run(h._handle_help_command(Ev("skills"))) == "DEVELOPER LIST"
PY
    rm -rf "$tmp"
}

@test "the choice patch turns the numbered fallback into a list, once, and keeps the numbers" {
    local f; f=$(mktemp --suffix=.py)
    cat >"$f" <<'PY'
class Adapter:
    async def send_clarify(self, chat_id, question, choices, clarify_id, session_key, metadata=None):
        if choices:
            _is_multi = False
            lines = [f"❓ {question}", ""]
            for i, choice in enumerate(choices, start=1):
                lines.append(f"  {i}. {choice}")
            lines.append("")
            lines.append("Reply with the number, the option text, or your own answer.")
            text = "\n".join(lines)
        else:
            text = f"❓ {question}"
        return text
PY
    hermes_patch_clarify_choices_file "$f"
    grep -q 'lines.append(f"- \*\*{i}\.\*\* {choice}")' "$f"
    ! grep -q 'lines.append(f"  {i}. {choice}")' "$f"
    python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$f"
    # every option on its own line, the number still answerable
    out=$(python3 - "$f" <<'PY'
import asyncio, importlib.util, sys
spec = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(asyncio.run(m.Adapter().send_clarify("c", "Welcher Tenant?", ["Acme", "Globex"], "id", "s")))
PY
)
    [[ "$out" == *'- **1.** Acme'* && "$out" == *'- **2.** Globex'* ]]
    [[ "$out" == *'Reply with the number'* ]]
    bats_run hermes_patch_clarify_choices_file "$f"
    [ "$status" -eq 3 ]
    [ "$(hermes_adapter_base_path)" = "$(hermes_install_dir)/gateway/platforms/base.py" ]
    rm -f "$f"
}

@test "the web-files patch caches a document and a photo like a Teams attachment, once, and names the file" {
    tmp=$(mktemp -d)
    cat >"${tmp}/api_server.py" <<'PY'
import os
from typing import Any, Dict, List

MAX_REQUEST_BYTES = 10_000_000  # 10 MB — accommodates long agent conversations with tool calls
_TEXT_PART_TYPES = frozenset({"text", "input_text"})
_IMAGE_PART_TYPES = frozenset({"image_url", "input_image"})
_FILE_PART_TYPES = frozenset({"file", "input_file"})


def _normalize_multimodal_content(content: Any) -> Any:
    normalized_parts: List[Dict[str, Any]] = []
    for part in content:
        part_type = part.get("type")
        if part_type in _TEXT_PART_TYPES:
            normalized_parts.append({"type": "text", "text": part["text"]})
            continue
        if part_type in _IMAGE_PART_TYPES:
            url_value = part["image_url"]["url"]
            lowered = url_value.lower()
            image_part: Dict[str, Any] = {"type": "image_url", "image_url": {"url": url_value}}
            normalized_parts.append(image_part)
            continue

        if part_type in _FILE_PART_TYPES:
            raise ValueError(
                "unsupported_content_type:Inline image inputs are supported, "
                "but uploaded files and document inputs are not supported on this endpoint."
            )
    return normalized_parts
PY
    hermes_patch_web_files_file "${tmp}/api_server.py"
    grep -q 'setup-hermes-agent: files through the web channel' "${tmp}/api_server.py"
    grep -q '^MAX_REQUEST_BYTES = 40_000_000' "${tmp}/api_server.py"
    bats_run hermes_patch_web_files_file "${tmp}/api_server.py"; [ "$status" -eq 3 ]
    python3 - "${tmp}/api_server.py" "$tmp" <<'PY'
import base64, os, sys, types
src, tmp = sys.argv[1], sys.argv[2]
calls = []
class Cached:
    def __init__(self, path, media_type, kind, display_name):
        self.path, self.media_type, self.kind, self.display_name = path, media_type, kind, display_name
def cache_media_bytes(data, *, filename="", mime_type=""):
    calls.append(filename)
    path = os.path.join(tmp, "cache-%d-%s" % (len(calls), filename))
    open(path, "wb").write(data)
    kind = "image" if mime_type.startswith("image/") else "document"
    return Cached(path, mime_type, kind, filename)
def _build_document_context_note(name, path, mime, content_inlined=True):
    return "[DOC %s at %s (%s) inlined=%s]" % (name, path, mime, content_inlined)
gateway = types.ModuleType("gateway"); platforms = types.ModuleType("gateway.platforms")
base = types.ModuleType("gateway.platforms.base"); base.cache_media_bytes = cache_media_bytes
run = types.ModuleType("gateway.run"); run._build_document_context_note = _build_document_context_note
sys.modules.update({"gateway": gateway, "gateway.platforms": platforms, "gateway.platforms.base": base, "gateway.run": run})
ns = {}; exec(compile(open(src).read(), src, "exec"), ns)
norm = ns["_normalize_multimodal_content"]

pdf = "data:application/pdf;base64," + base64.b64encode(b"%PDF-1.4 fake").decode()
out = norm([{"type": "text", "text": "Bitte ablegen"},
            {"type": "file", "file": {"filename": "Rechnung.pdf", "file_data": pdf}}])
assert out[0] == {"type": "text", "text": "Bitte ablegen"}, out
assert out[1]["type"] == "text" and "[DOC Rechnung.pdf at " in out[1]["text"] and "inlined=False" in out[1]["text"], out
assert open(out[1]["text"].split(" at ")[1].split(" (")[0], "rb").read() == b"%PDF-1.4 fake"

# a client that sends the same file again gets the same file, not a copy
again = norm([{"type": "file", "file": {"filename": "Rechnung.pdf", "file_data": pdf}}])
assert again[0]["text"] == out[1]["text"] and calls == ["Rechnung.pdf"], (again, calls)

# the Responses API shape: filename and file_data at the top
top = norm([{"type": "input_file", "filename": "Brief.pdf",
             "file_data": "data:application/pdf;base64," + base64.b64encode(b"other").decode()}])
assert "[DOC Brief.pdf at " in top[0]["text"], top

# a photo stays a picture for the model AND becomes a file with a note
png = "data:image/png;base64," + base64.b64encode(b"\x89PNG fake").decode()
pic = norm([{"type": "image_url", "image_url": {"url": png}}])
assert pic[0] == {"type": "image_url", "image_url": {"url": png}}, pic
assert pic[1]["type"] == "text" and "The user sent an image: 'image-1.png'. It is saved at: " in pic[1]["text"], pic

# a file id cannot be fetched, and an oversized file is refused, both in the API's own codes
for bad in ({"type": "file", "file": {"file_id": "file-123"}},):
    try:
        norm([bad]); raise SystemExit("a file id was accepted")
    except ValueError as exc:
        assert str(exc).startswith("unsupported_content_type:"), exc
ns["_WEB_ATTACHMENT_MAX_BYTES"] = 4
try:
    norm([{"type": "file", "file": {"filename": "big.pdf", "file_data": "data:application/pdf;base64," + base64.b64encode(b"12345").decode()}}])
    raise SystemExit("an oversized file was accepted")
except ValueError as exc:
    assert "larger than 25 MB" in str(exc), exc
print("ok")
PY
    rm -rf "$tmp"
}

@test "the web-files patch is applied on every run, after an update too" {
    [ "$(grep -cE '^ +_hermes_patch_web_files$' "$REPO_ROOT/libs/60-hermes.sh")" -eq 2 ]
}

# A scanned PDF from the web chat: its pages without text go to the model as
# pictures (patch 6, on top of patch 5). Run with the agent's own interpreter,
# which has pypdfium2 and Pillow.

@test "the scan-pictures patch hands a scan's pages to the model as pictures, keeps a text PDF's note, and marks a mixed one's scanned pages" {
    agent_python pypdfium2,PIL
    tmp=$(mktemp -d)
    cat >"${tmp}/api_server.py" <<'PY'
import os
from typing import Any, Dict, List

MAX_REQUEST_BYTES = 10_000_000  # 10 MB — accommodates long agent conversations with tool calls
_TEXT_PART_TYPES = frozenset({"text", "input_text"})
_IMAGE_PART_TYPES = frozenset({"image_url", "input_image"})
_FILE_PART_TYPES = frozenset({"file", "input_file"})


def _normalize_multimodal_content(content: Any) -> Any:
    normalized_parts: List[Dict[str, Any]] = []
    for part in content:
        part_type = part.get("type")
        if part_type in _TEXT_PART_TYPES:
            normalized_parts.append({"type": "text", "text": part["text"]})
            continue
        if part_type in _IMAGE_PART_TYPES:
            url_value = part["image_url"]["url"]
            lowered = url_value.lower()
            image_part: Dict[str, Any] = {"type": "image_url", "image_url": {"url": url_value}}
            normalized_parts.append(image_part)
            continue

        if part_type in _FILE_PART_TYPES:
            raise ValueError(
                "unsupported_content_type:Inline image inputs are supported, "
                "but uploaded files and document inputs are not supported on this endpoint."
            )
    return normalized_parts
PY
    hermes_patch_web_files_file "${tmp}/api_server.py"
    hermes_patch_scan_pictures_file "${tmp}/api_server.py"
    grep -q "setup-hermes-agent: a scan's pages as pictures" "${tmp}/api_server.py"
    bats_run hermes_patch_scan_pictures_file "${tmp}/api_server.py"; [ "$status" -eq 3 ]
    "$HPY" - "${tmp}/api_server.py" "$tmp" <<'PY'
import base64, io, os, sys, types
from PIL import Image, ImageDraw
src, tmp = sys.argv[1], sys.argv[2]
calls = []
class Cached:
    def __init__(self, path, media_type, kind, display_name):
        self.path, self.media_type, self.kind, self.display_name = path, media_type, kind, display_name
def cache_media_bytes(data, *, filename="", mime_type=""):
    calls.append(filename)
    path = os.path.join(tmp, "cache-%d-%s" % (len(calls), filename))
    open(path, "wb").write(data)
    return Cached(path, mime_type, "image" if mime_type.startswith("image/") else "document", filename)
def _build_document_context_note(name, path, mime, content_inlined=True):
    return "[DOC %s at %s (%s) inlined=%s]" % (name, path, mime, content_inlined)
gateway = types.ModuleType("gateway"); platforms = types.ModuleType("gateway.platforms")
base = types.ModuleType("gateway.platforms.base"); base.cache_media_bytes = cache_media_bytes
run = types.ModuleType("gateway.run"); run._build_document_context_note = _build_document_context_note
sys.modules.update({"gateway": gateway, "gateway.platforms": platforms, "gateway.platforms.base": base, "gateway.run": run})
ns = {}; exec(compile(open(src).read(), src, "exec"), ns)
norm = ns["_normalize_multimodal_content"]

def jpeg():                       # a photographed page: white, a dark block of "text"
    im = Image.new("RGB", (400, 560), "white"); ImageDraw.Draw(im).rectangle((40, 60, 360, 90), fill="black")
    b = io.BytesIO(); im.save(b, "JPEG"); return b.getvalue()
def pdf(pages):                   # ("text", words) or ("image",) per page
    objs, kids, font = [b"", b""], [], None
    for page in pages:
        if page[0] == "text":
            if font is None:
                objs.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"); font = len(objs)
            stream, res = b"BT /F1 18 Tf 72 700 Td (" + page[1].encode() + b") Tj ET", b"<< /Font << /F1 %d 0 R >> >>" % font
        else:
            data = jpeg()
            objs.append(b"<< /Type /XObject /Subtype /Image /Width 400 /Height 560 /ColorSpace /DeviceRGB "
                        b"/BitsPerComponent 8 /Filter /DCTDecode /Length %d >>\nstream\n" % len(data) + data + b"\nendstream")
            stream, res = b"q 595 0 0 842 0 0 cm /Im0 Do Q", b"<< /XObject << /Im0 %d 0 R >> >>" % len(objs)
        objs.append(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
        objs.append(b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources " + res + b" /Contents %d 0 R >>" % len(objs))
        kids.append(len(objs))
    objs[0] = b"<< /Type /Catalog /Pages 2 0 R >>"
    objs[1] = b"<< /Type /Pages /Kids [" + b" ".join(b"%d 0 R" % k for k in kids) + b"] /Count %d >>" % len(kids)
    out, offsets = bytearray(b"%PDF-1.4\n"), []
    for i, o in enumerate(objs, 1):
        offsets.append(len(out)); out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1) + b"".join(b"%010d 00000 n \n" % o for o in offsets)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    return bytes(out)
def send(name, data):
    url = "data:application/pdf;base64," + base64.b64encode(data).decode()
    return norm([{"type": "file", "file": {"filename": name, "file_data": url}}])[0]["text"]
def pictures(note):
    return [p.strip().rstrip(".") for p in note.split("saved as pictures: ")[1].split(". Read")[0].split(",")]

# a scan: a note of its own, the pictures real JPEGs, no "extract the text yourself"
scan = pdf([("image",), ("image",)])
note = send("Scan.pdf", scan)
assert note.startswith("[The user sent a scanned document: 'Scan.pdf'. It is saved at: ") and "[DOC " not in note, note
assert "no text layer" in note and "vision_analyze" in note, note
shots = pictures(note)
assert len(shots) == 2 and all(open(p, "rb").read(2) == b"\xff\xd8" for p in shots), shots
w, h = Image.open(shots[0]).size
assert max(w, h) <= 2000 and h > w, (w, h)
made = len(calls)
assert send("Scan.pdf", scan) == note and len(calls) == made, "the same scan sent again was rendered again"

# a PDF with text: the gateway's own note, nothing more
text = send("Brief.pdf", pdf([("text", "Rechnung Nummer 51 ueber CHF 1558.20")]))
assert text.startswith("[DOC Brief.pdf at ") and text.endswith("inlined=False]"), text

# a mixed one: the gateway's note, and the scanned page as a picture
mixed = send("Mixed.pdf", pdf([("text", "Seite eins mit richtigem Text darauf"), ("image",)]))
assert mixed.startswith("[DOC Mixed.pdf at ") and "Page 2 of it has no text layer; it is saved as a picture: " in mixed, mixed

# a long scan: the first pages only, and the note says so
ns["_WEB_SCAN_MAX_PAGES"] = 2
long = send("Long.pdf", pdf([("image",)] * 3))
assert "Only its first 2 of 3 pages were looked at." in long and len(pictures(long)) == 2, long

# not readable as a PDF: the gateway's note alone
broken = send("Kaputt.pdf", b"%PDF-1.4 not really")
assert broken.startswith("[DOC Kaputt.pdf at ") and "picture" not in broken, broken
print("ok")
PY
    rm -rf "$tmp"
}

@test "the scan-pictures patch is applied on every run, right after the web-files patch it extends" {
    [ "$(grep -cE '^ +_hermes_patch_scan_pictures$' "$REPO_ROOT/libs/60-hermes.sh")" -eq 2 ]
    [ "$(grep -A1 -E '^ +_hermes_patch_web_files$' "$REPO_ROOT/libs/60-hermes.sh" | grep -cE '^ +_hermes_patch_scan_pictures$')" -eq 2 ]
}

@test "the scan-pictures patch needs the web-files patch and refuses to guess when it changed" {
    tmp=$(mktemp -d)
    printf 'def _web_attachment_note(data: bytes, filename: str, mime: str) -> str:\n    pass\n' >"${tmp}/api_server.py"
    bats_run hermes_patch_scan_pictures_file "${tmp}/api_server.py"
    [ "$status" -ne 0 ] && [ "$status" -ne 3 ] && [[ "$output" == *"web-files patch is not applied"* ]]
    printf '# setup-hermes-agent: files through the web channel\n' >"${tmp}/api_server.py"
    bats_run hermes_patch_scan_pictures_file "${tmp}/api_server.py"
    [ "$status" -ne 0 ] && [ "$status" -ne 3 ] && [[ "$output" == *"review the patch"* ]]
    rm -rf "$tmp"
}

@test "the web-files patch refuses to guess when the API server changed" {
    tmp=$(mktemp -d)
    printf 'MAX_REQUEST_BYTES = 5\n' >"${tmp}/api_server.py"
    bats_run hermes_patch_web_files_file "${tmp}/api_server.py"
    [ "$status" -ne 0 ] && [ "$status" -ne 3 ]
    [[ "$output" == *"review the patch"* ]]
    rm -rf "$tmp"
}
