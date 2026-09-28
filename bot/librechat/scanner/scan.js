/*
 * The document scanner in the web chat (ADR 0029).
 *
 * A button next to LibreChat's paperclip opens the camera. The sheets' edges
 * are found live and drawn over the picture — one sheet, or several side by
 * side. A shot is measured again on itself at twice the preview's resolution,
 * so a hand that moved cannot shift the cut, and every sheet in it is
 * straightened and cut with a little margin; a shot without a sheet opens a
 * still of it with four corners to drag. A tap on a page opens it: turn it,
 * crop it again, "Document" (white paper, dark ink) or colour, move it earlier
 * or later, take it again, delete it. "New document" starts the next PDF, and
 * "Done" hands one PDF per document to LibreChat's own upload input — exactly
 * as if picked with the paperclip; from there each goes to the bot like any
 * other attachment. The image work (OpenCV.js) runs in scan-worker.js, off the
 * page's thread; until it is ready — or if it cannot start — the camera still
 * takes pages, uncropped.
 *
 * Plain JavaScript without a build step: the installer serves this file, the
 * worker and OpenCV next to LibreChat's own and adds one script tag to its
 * page. What has no screen — the PDF, the corners, the margin, the reading
 * order, the documents — is exported for the tests when loaded under Node.
 */
(function () {
  "use strict";

  // ---------------------------------------------------------------------------
  // PDF: one page per JPEG, the page as wide as A4, as tall as the picture is.
  // ---------------------------------------------------------------------------
  var A4_WIDTH_PT = 595.28;

  function bytes(text) {
    var out = new Uint8Array(text.length);
    for (var i = 0; i < text.length; i++) out[i] = text.charCodeAt(i) & 0xff;
    return out;
  }

  function pageSize(width, height) {
    return { w: A4_WIDTH_PT, h: Math.round((A4_WIDTH_PT * height / width) * 100) / 100 };
  }

  /** pages: [{jpeg: Uint8Array, width, height}] -> Uint8Array holding a PDF */
  function buildPdf(pages) {
    if (!pages || !pages.length) throw new Error("no pages");
    var chunks = [], offsets = [], size = 0;
    function push(b) { chunks.push(b); size += b.length; }
    function obj(n, dict, stream) {
      offsets[n] = size;
      push(bytes(n + " 0 obj\n" + dict));
      if (stream) { push(bytes("\nstream\n")); push(stream); push(bytes("\nendstream")); }
      push(bytes("\nendobj\n"));
    }
    push(bytes("%PDF-1.4\n%âãÏÓ\n"));
    var kids = pages.map(function (_, i) { return (3 + i * 3) + " 0 R"; });
    obj(1, "<< /Type /Catalog /Pages 2 0 R >>");
    obj(2, "<< /Type /Pages /Kids [" + kids.join(" ") + "] /Count " + pages.length + " >>");
    pages.forEach(function (p, i) {
      var pageNo = 3 + i * 3, contentNo = pageNo + 1, imageNo = pageNo + 2;
      var s = pageSize(p.width, p.height);
      var content = bytes("q " + s.w + " 0 0 " + s.h + " 0 0 cm /Im0 Do Q");
      obj(pageNo, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " + s.w + " " + s.h + "] " +
                  "/Resources << /XObject << /Im0 " + imageNo + " 0 R >> >> /Contents " + contentNo + " 0 R >>");
      obj(contentNo, "<< /Length " + content.length + " >>", content);
      obj(imageNo, "<< /Type /XObject /Subtype /Image /Width " + p.width + " /Height " + p.height +
                   " /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length " + p.jpeg.length + " >>",
          p.jpeg);
    });
    var count = 3 + pages.length * 3;   // objects 1..count-1, plus the free entry 0
    var xref = size;
    var table = "xref\n0 " + count + "\n0000000000 65535 f \n";
    for (var k = 1; k < count; k++) table += String(offsets[k]).padStart(10, "0") + " 00000 n \n";
    push(bytes(table + "trailer\n<< /Size " + count + " /Root 1 0 R >>\nstartxref\n" + xref + "\n%%EOF\n"));
    var out = new Uint8Array(size), pos = 0;
    chunks.forEach(function (c) { out.set(c, pos); pos += c.length; });
    return out;
  }

  // ---------------------------------------------------------------------------
  // Corners: four points as TL, TR, BR, BL — around their centre, starting top
  // left, so corners dragged across each other still make a page.
  // ---------------------------------------------------------------------------
  var CORNERS = ["topLeftCorner", "topRightCorner", "bottomRightCorner", "bottomLeftCorner"];

  function dist(a, b) { return Math.hypot(a.x - b.x, a.y - b.y); }

  function ordered(points) {
    var cx = 0, cy = 0;
    points.forEach(function (p) { cx += p.x / points.length; cy += p.y / points.length; });
    var p = points.slice().sort(function (a, b) { return Math.atan2(a.y - cy, a.x - cx) - Math.atan2(b.y - cy, b.x - cx); });
    var first = 0;
    p.forEach(function (q, i) { if (q.x + q.y < p[first].x + p[first].y) first = i; });
    p = p.slice(first).concat(p.slice(0, first));
    var c = {};
    CORNERS.forEach(function (k, i) { c[k] = p[i]; });
    return c;
  }

  /** The quadrilateral with every edge moved outward by m pixels, kept inside w x h. */
  function expanded(c, m, w, h) {
    var p = CORNERS.map(function (k) { return c[k]; });
    var edges = p.map(function (a, i) {           // clockwise on screen: the outward normal is (dy, -dx)
      var b = p[(i + 1) % 4], dx = b.x - a.x, dy = b.y - a.y, len = Math.hypot(dx, dy) || 1;
      return { x: a.x + (dy / len) * m, y: a.y - (dx / len) * m, dx: dx, dy: dy };
    });
    var out = {};
    CORNERS.forEach(function (k, i) {
      var e1 = edges[(i + 3) % 4], e2 = edges[i], den = e1.dx * e2.dy - e1.dy * e2.dx, q = p[i];
      if (Math.abs(den) > 1e-9) {                 // where the two moved edges meet
        var t = ((e2.x - e1.x) * e2.dy - (e2.y - e1.y) * e2.dx) / den;
        q = { x: e1.x + t * e1.dx, y: e1.y + t * e1.dy };
      }
      out[k] = { x: Math.max(0, Math.min(w - 1, q.x)), y: Math.max(0, Math.min(h - 1, q.y)) };
    });
    return out;
  }

  /** A cut with a margin on every edge: a share of the page's shorter side. */
  function withMargin(c, share, w, h) {
    var width = (dist(c.topLeftCorner, c.topRightCorner) + dist(c.bottomLeftCorner, c.bottomRightCorner)) / 2;
    var height = (dist(c.topLeftCorner, c.bottomLeftCorner) + dist(c.topRightCorner, c.bottomRightCorner)) / 2;
    return expanded(c, share * Math.min(width, height), w, h);
  }

  /** Sheets in the order they are read: rows from the top, left to right within a row. */
  function readingOrder(sheets) {
    return sheets.map(function (c) {
      var xs = CORNERS.map(function (k) { return c[k].x; }), ys = CORNERS.map(function (k) { return c[k].y; });
      var top = Math.min.apply(null, ys), bottom = Math.max.apply(null, ys);
      return { c: c, x: (Math.min.apply(null, xs) + Math.max.apply(null, xs)) / 2, y: (top + bottom) / 2, h: bottom - top };
    }).sort(function (a, b) {
      return Math.abs(a.y - b.y) < Math.min(a.h, b.h) / 2 ? a.x - b.x : a.y - b.y;
    }).map(function (s) { return s.c; });
  }

  // ---------------------------------------------------------------------------
  // Documents: one strip of pages, a break where the next document begins.
  // ---------------------------------------------------------------------------
  var BREAK = "break";

  /** The strip as documents, none of them empty. */
  function documents(strip) {
    var docs = [[]];
    strip.forEach(function (item) { if (item === BREAK) docs.push([]); else docs[docs.length - 1].push(item); });
    return docs.filter(function (d) { return d.length; });
  }

  /** The strip without breaks that separate nothing: none first, none last, never two. */
  function tidy(strip) {
    var out = [];
    strip.forEach(function (item) {
      if (item === BREAK && (!out.length || out[out.length - 1] === BREAK)) return;
      out.push(item);
    });
    if (out[out.length - 1] === BREAK) out.pop();
    return out;
  }

  /** The strip with the page one place earlier (-1) or later (+1); across a break it changes document. */
  function moved(strip, page, step) {
    var s = strip.slice(), i = s.indexOf(page), j = i + step;
    if (i < 0 || j < 0 || j >= s.length) return s;
    s[i] = s[j]; s[j] = page;
    return tidy(s);
  }

  function scanFileName(date, n) {
    var d = date || new Date();
    function two(v) { return (v < 10 ? "0" : "") + v; }
    return "Scan " + d.getFullYear() + "-" + two(d.getMonth() + 1) + "-" + two(d.getDate()) +
           " " + two(d.getHours()) + "-" + two(d.getMinutes()) + (n ? " (" + n + ")" : "") + ".pdf";
  }

  if (typeof module === "object" && module.exports) {
    module.exports = { buildPdf: buildPdf, pageSize: pageSize, scanFileName: scanFileName, ordered: ordered,
                       expanded: expanded, withMargin: withMargin, readingOrder: readingOrder,
                       documents: documents, tidy: tidy, moved: moved, BREAK: BREAK };
  }
  if (typeof window === "undefined" || typeof document === "undefined") return;

  // ---------------------------------------------------------------------------
  // In the browser.
  // ---------------------------------------------------------------------------
  var SRC = (document.currentScript && document.currentScript.src) || "";
  var BASE = SRC.replace(/scan\.js(\?.*)?$/, "");
  // The page's tag carries one version for the scanner, its worker and OpenCV
  // together; asking for them with it keeps a cached old file from staying.
  var VERSION = (SRC.match(/[?&]v=([0-9a-f]+)/) || [])[1];
  var QUERY = VERSION ? "?v=" + VERSION : "";
  var DETECT_WIDTH = 480;        // the live preview is looked at this wide
  var MEASURE_WIDTH = 960;       // and a shot measured again at twice that
  var FRAME_LONG_SIDE = 3200;    // a shot, before it is cut
  var PAGE_LONG_SIDE = 2400;     // about 200 dpi on A4: small files, sharp text
  var MARGIN = 0.02;             // of the page's shorter side, on every edge: rather desk than text
  var STABLE = 2;                // frames in a row that agree before a sheet counts
  var MISSES = 2;                // frames without it before it goes

  var de = /^de\b/i.test(navigator.language || "");
  var T = de ? {
    scan: "Dokument scannen", capture: "Aufnehmen", done: "Fertig", cancel: "Abbrechen",
    camera: "Kamera wird gestartet …", loading: "Randerkennung wird geladen (einmalig ca. 9 MB) …",
    find: "Blatt ganz ins Bild halten, mit etwas Rand", found: "Seite erkannt", foundMany: "{1} Blätter erkannt",
    measuring: "Wird zugeschnitten …", working: "Wird bearbeitet …", building: "PDF wird erstellt …",
    noCamera: "Keine Kamera verfügbar, oder der Zugriff wurde nicht erlaubt.",
    noDetect: "Randerkennung nicht verfügbar – Aufnahmen werden ungeschnitten übernommen",
    uncut: "Seite ungeschnitten übernommen",
    adjust: "Ecken auf die Blattecken ziehen", again: "Neu", use: "Übernehmen", back: "Zurück",
    newDoc: "Neues Dokument", nextDoc: "Nächste Aufnahme: neues PDF", pdfs: "{1} PDFs",
    pageOf: "Seite {1} von {2}", docPage: "PDF {1} · Seite {2} von {3}", replaces: "Ersetzt Seite {1}",
    earlier: "Nach vorn", later: "Nach hinten", rotate: "Drehen", crop: "Zuschneiden",
    colour: "Farbe", document: "Dokument", retake: "Neu aufnehmen", remove: "Löschen",
    fallback: "Heruntergeladen – bitte über die Büroklammer anhängen."
  } : {
    scan: "Scan a document", capture: "Capture", done: "Done", cancel: "Cancel",
    camera: "Starting the camera …", loading: "Loading edge detection (about 9 MB, once) …",
    find: "Fit the whole page in the frame, with a little margin", found: "Page detected", foundMany: "{1} sheets detected",
    measuring: "Cutting …", working: "Working …", building: "Building the PDF …",
    noCamera: "No camera available, or access was not allowed.",
    noDetect: "Edge detection unavailable – pages are taken uncropped",
    uncut: "Page taken uncropped",
    adjust: "Drag the corners onto the page's corners", again: "Retake", use: "Use", back: "Back",
    newDoc: "New document", nextDoc: "Next shot: a new PDF", pdfs: "{1} PDFs",
    pageOf: "Page {1} of {2}", docPage: "PDF {1} · page {2} of {3}", replaces: "Replaces page {1}",
    earlier: "Earlier", later: "Later", rotate: "Rotate", crop: "Crop",
    colour: "Colour", document: "Document", retake: "Retake", remove: "Delete",
    fallback: "Downloaded – please attach it with the paperclip."
  };
  function fmt(text) {
    var args = arguments;
    return text.replace(/\{(\d)\}/g, function (_, i) { return args[+i]; });
  }

  var ICON = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ' +
    'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 7V5a2 2 0 0 1 2-2h2"/>' +
    '<path d="M17 3h2a2 2 0 0 1 2 2v2"/><path d="M21 17v2a2 2 0 0 1-2 2h-2"/><path d="M7 21H5a2 2 0 0 1-2-2v-2"/>' +
    '<path d="M8 8h8"/><path d="M8 12h8"/><path d="M8 16h5"/></svg>';

  // --- the worker: OpenCV off the page's thread --------------------------------
  // Started when the scanner first opens and kept for the next page; one that
  // failed is dropped, and the next opening starts a new one.
  var WORKER_START_MS = 120000, DETECT_MS = 5000, MEASURE_MS = 15000, EXTRACT_MS = 30000;
  var worker = null, workerState = "idle", listeners = [], pending = {}, nextId = 1;
  function workerChanged(state) {
    workerState = state;
    listeners.slice().forEach(function (f) { f(state); });
  }
  function workerFailed(message) {
    if (window.console) console.warn("[scanner] edge detection:", message);
    if (worker) { try { worker.terminate(); } catch (e) { /* gone already */ } }
    worker = null;
    Object.keys(pending).forEach(function (id) { var answer = pending[id]; delete pending[id]; answer({ error: message }); });
    workerChanged("failed");
  }
  function startWorker() {
    if (worker) return;
    workerChanged("loading");
    var w;
    try {
      w = new Worker(BASE + "scan-worker.js" + QUERY);
    } catch (e) {
      workerFailed(String((e && e.message) || e));
      return;
    }
    worker = w;
    var started = setTimeout(function () {
      if (worker === w && workerState === "loading") workerFailed("did not start within " + WORKER_START_MS / 1000 + " s");
    }, WORKER_START_MS);
    w.onmessage = function (e) {
      if (worker !== w) return;
      var m = e.data || {};
      if (m.type === "ready") { clearTimeout(started); workerChanged("ready"); return; }
      if (m.type === "error") { clearTimeout(started); workerFailed(m.message); return; }
      var answer = pending[m.id];
      delete pending[m.id];
      if (answer) answer(m);
    };
    w.onerror = function (e) {
      if (worker !== w) return;
      clearTimeout(started);
      workerFailed((e && e.message) || "the worker failed");
    };
  }
  /** One question to the worker; the answer, or {error} when there is none in time. */
  function ask(message, transfer, ms) {
    return new Promise(function (resolve) {
      var id = message.id = nextId++;
      var timer = setTimeout(function () { delete pending[id]; resolve({ error: "no answer in time" }); }, ms);
      pending[id] = function (m) { clearTimeout(timer); resolve(m); };
      try {
        worker.postMessage(message, transfer || []);
      } catch (e) {
        delete pending[id]; clearTimeout(timer);
        resolve({ error: String((e && e.message) || e) });
      }
    });
  }

  // --- pictures -----------------------------------------------------------------
  function scaled(c, f) {
    var out = {};
    CORNERS.forEach(function (k) { out[k] = { x: c[k].x * f, y: c[k].y * f }; });
    return out;
  }
  function whole(w, h) {
    return { topLeftCorner: { x: 0, y: 0 }, topRightCorner: { x: w, y: 0 },
             bottomRightCorner: { x: w, y: h }, bottomLeftCorner: { x: 0, y: h } };
  }
  function sized(c) {            // a cut's picture: as large as its longer edges, at most PAGE_LONG_SIDE
    var w = Math.max(dist(c.topLeftCorner, c.topRightCorner), dist(c.bottomLeftCorner, c.bottomRightCorner));
    var h = Math.max(dist(c.topLeftCorner, c.bottomLeftCorner), dist(c.topRightCorner, c.bottomRightCorner));
    var k = Math.min(1, PAGE_LONG_SIDE / Math.max(w, h, 1));
    return { width: Math.max(1, Math.round(w * k)), height: Math.max(1, Math.round(h * k)) };
  }
  function canvasOf(w, h) { var c = document.createElement("canvas"); c.width = w; c.height = h; return c; }
  function resized(src, factor) {
    if (factor >= 1) return src;
    var c = canvasOf(Math.max(1, Math.round(src.width * factor)), Math.max(1, Math.round(src.height * factor)));
    c.getContext("2d").drawImage(src, 0, 0, c.width, c.height);
    return c;
  }
  function downscaled(src, longSide) { return resized(src, longSide / Math.max(src.width, src.height)); }
  function pixels(canvas) {
    var d = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height);
    return { data: d.data, width: d.width, height: d.height };
  }
  function jpeg(canvas, quality) {
    return new Promise(function (resolve, reject) {
      canvas.toBlob(function (b) { if (b) resolve(b); else reject(new Error("no JPEG")); }, "image/jpeg", quality);
    });
  }
  function decoded(blob) {       // a JPEG back into a canvas
    if (typeof createImageBitmap === "function") {
      return createImageBitmap(blob).then(function (bitmap) {
        var c = canvasOf(bitmap.width, bitmap.height);
        c.getContext("2d").drawImage(bitmap, 0, 0);
        if (bitmap.close) bitmap.close();
        return c;
      });
    }
    return new Promise(function (resolve, reject) {
      var img = new Image(), url = URL.createObjectURL(blob);
      img.onload = function () {
        var c = canvasOf(img.naturalWidth, img.naturalHeight);
        c.getContext("2d").drawImage(img, 0, 0);
        URL.revokeObjectURL(url);
        resolve(c);
      };
      img.onerror = function () { URL.revokeObjectURL(url); reject(new Error("could not read the picture")); };
      img.src = url;
    });
  }
  function turned(src, degrees) {
    if (!degrees) return src;
    var side = degrees % 180 !== 0, c = canvasOf(side ? src.height : src.width, side ? src.width : src.height);
    var ctx = c.getContext("2d");
    ctx.translate(c.width / 2, c.height / 2);
    ctx.rotate((degrees * Math.PI) / 180);
    ctx.drawImage(src, -src.width / 2, -src.height / 2);
    return c;
  }

  // --- a page -------------------------------------------------------------------
  // {shot, corners, rotation, filter, flat, jpeg, width, height, url}: the whole
  // frame it came from (JPEG), so it can be cut again; where it is cut, in the
  // shot's pixels (null: the whole shot); the cut before turning (JPEG); and the
  // picture that goes into the PDF and the strip.

  /** The shot's cuts as canvases, not yet turned; the whole shot where there is no worker to cut. */
  function cutOut(shot, cuts, filter) {
    function uncut() { return cuts.map(function () { return downscaled(shot, PAGE_LONG_SIDE); }); }
    if (workerState !== "ready") return Promise.resolve(uncut());
    var img = pixels(shot);
    var list = cuts.map(function (c) { var s = sized(c); return { corners: c, width: s.width, height: s.height }; });
    return ask({ type: "extract", image: img, cuts: list, filter: filter }, [img.data.buffer], EXTRACT_MS).then(function (r) {
      if (!r || !r.images) return uncut();
      return r.images.map(function (im) {
        var c = canvasOf(im.width, im.height);
        c.getContext("2d").putImageData(new ImageData(im.data, im.width, im.height), 0, 0);
        return c;
      });
    });
  }
  /** The page's pictures from its cut: kept flat for turning, turned for the PDF and the strip. */
  function settle(page, flat) {
    return jpeg(flat, 0.9).then(function (blob) { page.flat = blob; return publish(page, flat); });
  }
  function publish(page, flat) {
    var picture = turned(flat, page.rotation);
    return jpeg(picture, 0.85).then(function (blob) {
      return blob.arrayBuffer().then(function (buf) {
        page.jpeg = new Uint8Array(buf); page.width = picture.width; page.height = picture.height;
        if (page.url) URL.revokeObjectURL(page.url);
        page.url = URL.createObjectURL(blob);
      });
    });
  }
  /** Cut the page again from its shot: after new corners or another filter. */
  function recut(page) {
    return decoded(page.shot).then(function (shot) {
      return cutOut(shot, [page.corners || whole(shot.width, shot.height)], page.filter);
    }).then(function (flats) { return settle(page, flats[0]); });
  }
  function drop(pages) { pages.forEach(function (p) { if (p.url) URL.revokeObjectURL(p.url); p.url = null; }); }

  // --- LibreChat's own upload ---------------------------------------------------
  function attachButton() { return document.getElementById("attach-file-menu-button"); }
  function fileInputNear(el) {
    for (var node = el; node && node !== document.body; node = node.parentElement) {
      var input = node.querySelector('input[type="file"]');
      if (input) return input;
    }
    return null;
  }
  function deliver(files) {
    var attach = attachButton(), input = attach && fileInputNear(attach);
    if (input && typeof DataTransfer === "function") {
      try {
        var dt = new DataTransfer();
        files.forEach(function (f) { dt.items.add(f); });
        input.files = dt.files;
        input.dispatchEvent(new Event("change", { bubbles: true }));
        return true;
      } catch (e) { /* fall through to the download */ }
    }
    files.forEach(function (file) {
      var a = document.createElement("a");
      a.href = URL.createObjectURL(file); a.download = file.name;
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(function () { URL.revokeObjectURL(a.href); }, 60000);
    });
    alert(T.fallback);
    return false;
  }

  // --- the scanner screen -------------------------------------------------------
  function el(tag, style, text) {
    var e = document.createElement(tag);
    if (style) e.style.cssText = style;
    if (text) e.textContent = text;
    if (tag === "button") e.type = "button";
    return e;
  }
  var BTN = "border:0;border-radius:999px;padding:12px 18px;font:600 15px system-ui,sans-serif;pointer-events:auto;" +
            "background:rgba(255,255,255,.14);color:#fff;cursor:pointer;min-width:96px;touch-action:manipulation";
  var BAR = "display:flex;align-items:center;justify-content:space-between;padding:12px 16px 16px;" +
            "flex:none;pointer-events:auto";
  function tool(glyph, word) {   // an icon over a word, for the page's tools
    var b = el("button", "border:0;background:none;color:#fff;display:flex;flex-direction:column;align-items:center;" +
                         "gap:3px;min-width:60px;padding:6px 2px;font:12px system-ui,sans-serif;cursor:pointer;" +
                         "pointer-events:auto;touch-action:manipulation");
    var w = el("span", "", word);
    b.appendChild(el("span", "font-size:22px;line-height:1", glyph));
    b.appendChild(w);
    return { button: b, word: function (text) { w.textContent = text; } };
  }
  function enable(b, on) { b.disabled = !on; b.style.opacity = on ? "1" : ".35"; }

  function openScanner() {
    if (document.getElementById("hermes-scanner")) return;
    var stream = null, timer = null, detecting = false, busy = false, closed = false, heldUntil = 0;
    var mode = "camera", tracked = [], strip = [], startNew = false, retake = null, viewing = null, crop = null;
    var filter = "colour";       // what a new page gets: the last one chosen

    // A modal <dialog> sits in the browser's top layer, above anything the page
    // stacks, and is outside whatever the page marks inert; pointer events are
    // switched on explicitly in case the page switched them off on <body>.
    var useDialog = typeof HTMLDialogElement === "function";
    var root = el(useDialog ? "dialog" : "div",
      "position:fixed;inset:0;width:100%;height:100%;max-width:none;max-height:none;margin:0;border:0;" +
      "padding:env(safe-area-inset-top) 0 env(safe-area-inset-bottom);box-sizing:border-box;z-index:2147483647;" +
      "background:#000;color:#fff;display:flex;flex-direction:column;pointer-events:auto;font:15px system-ui,sans-serif");
    root.id = "hermes-scanner";
    root.setAttribute("aria-label", T.scan);
    if (!useDialog) root.setAttribute("role", "dialog");
    var stage = el("div", "position:relative;flex:1;overflow:hidden;min-height:0");
    var video = el("video", "position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:#000");
    video.setAttribute("playsinline", ""); video.setAttribute("muted", ""); video.muted = true; video.autoplay = true;
    var overlay = el("canvas", "position:absolute;inset:0;width:100%;height:100%;pointer-events:none");
    // the corners set by hand, over a still of the shot
    var still = el("canvas", "position:absolute;inset:0;width:100%;height:100%;display:none;touch-action:none;" +
                             "pointer-events:auto");
    var picture = el("img", "position:absolute;inset:0;width:100%;height:100%;object-fit:contain;display:none;" +
                            "pointer-events:none");
    picture.alt = "";
    var hint = el("div", "position:absolute;left:0;right:0;top:12px;text-align:center;padding:0 16px;" +
                         "text-shadow:0 1px 3px #000;pointer-events:none", T.camera);
    var chip = el("button", "position:absolute;left:50%;top:44px;transform:translateX(-50%);display:none;border:0;" +
                            "border-radius:999px;padding:6px 14px;background:#e5a50a;color:#000;" +
                            "font:600 13px system-ui,sans-serif;cursor:pointer;pointer-events:auto;white-space:nowrap");
    [video, overlay, still, picture, hint, chip].forEach(function (e) { stage.appendChild(e); });
    var thumbs = el("div", "display:flex;align-items:center;gap:8px;overflow-x:auto;padding:8px 12px;flex:none;" +
                           "pointer-events:auto");

    var camBar = el("div", BAR);
    var cancel = el("button", BTN, T.cancel);
    var shoot = el("button", "width:72px;height:72px;border-radius:50%;border:4px solid #fff;background:#fff;" +
                             "box-shadow:inset 0 0 0 3px #000;cursor:pointer;pointer-events:auto;touch-action:manipulation");
    shoot.setAttribute("aria-label", T.capture);
    var done = el("button", BTN + ";background:#10a37f", T.done);
    [cancel, shoot, done].forEach(function (b) { camBar.appendChild(b); });
    enable(shoot, false); enable(done, false);

    var cornerBar = el("div", BAR + ";display:none");
    var cornerBack = el("button", BTN, T.again), cornerUse = el("button", BTN + ";background:#10a37f", T.use);
    cornerBar.appendChild(cornerBack); cornerBar.appendChild(cornerUse);

    var pageBar = el("div", "display:none;flex-direction:column;gap:8px;padding:8px 12px 16px;flex:none;pointer-events:auto");
    var tools = el("div", "display:flex;justify-content:space-between");
    var earlier = tool("←", T.earlier), rotate = tool("↻", T.rotate), cropTool = tool("✂", T.crop);
    var filterTool = tool("◐", T.colour), later = tool("→", T.later);
    [earlier, rotate, cropTool, filterTool, later].forEach(function (t) { tools.appendChild(t.button); });
    var actions = el("div", "display:flex;justify-content:space-between;gap:8px");
    var remove = el("button", BTN + ";min-width:0;background:rgba(220,60,60,.4)", T.remove);
    var again = el("button", BTN + ";min-width:0", T.retake);
    var back = el("button", BTN + ";min-width:0;background:#10a37f", T.back);
    [remove, again, back].forEach(function (b) { actions.appendChild(b); });
    pageBar.appendChild(tools); pageBar.appendChild(actions);

    [stage, thumbs, camBar, cornerBar, pageBar].forEach(function (e) { root.appendChild(e); });
    // the page must not see our taps as taps outside something of its own
    ["pointerdown", "mousedown", "touchstart", "click", "keydown"].forEach(function (type) {
      root.addEventListener(type, function (e) { e.stopPropagation(); });
    });
    document.body.appendChild(root);
    if (useDialog) { try { root.showModal(); } catch (e) { root.setAttribute("open", ""); } }
    // should anything mark the scanner inert after all, take it back
    new MutationObserver(function () {
      if (root.hasAttribute("inert")) root.removeAttribute("inert");
      if (root.getAttribute("aria-hidden") === "true") root.removeAttribute("aria-hidden");
    }).observe(root, { attributes: true, attributeFilter: ["inert", "aria-hidden"] });

    var small = document.createElement("canvas");

    function close() {
      if (closed) return;
      closed = true;
      if (timer) clearTimeout(timer);
      if (stream) stream.getTracks().forEach(function (t) { t.stop(); });
      listeners = listeners.filter(function (f) { return f !== onWorker; });
      window.removeEventListener("resize", onResize);
      drop(strip.filter(function (x) { return x !== BREAK; }));
      if (useDialog && root.open) { try { root.close(); } catch (e) { /* removed below */ } }
      root.remove();
    }
    function tell(text, ms) { hint.textContent = text; heldUntil = ms ? Date.now() + ms : 0; }
    function status() {
      if (mode !== "camera" || busy || !video.videoWidth || Date.now() < heldUntil) return;
      if (workerState === "ready") {
        var n = seen().length;
        hint.textContent = n > 1 ? fmt(T.foundMany, n) : n ? T.found : startNew && strip.length ? T.nextDoc : T.find;
      } else if (workerState === "failed") {
        hint.textContent = T.noDetect;
      } else {
        hint.textContent = T.loading;
      }
    }
    function onWorker() { if (!closed) { status(); startDetect(); } }
    function show(m) {
      mode = m;
      video.style.visibility = m === "camera" ? "" : "hidden";
      overlay.style.display = m === "camera" ? "" : "none";
      still.style.display = m === "corners" ? "block" : "none";
      picture.style.display = m === "page" ? "block" : "none";
      camBar.style.display = m === "camera" ? "flex" : "none";
      cornerBar.style.display = m === "corners" ? "flex" : "none";
      pageBar.style.display = m === "page" ? "flex" : "none";
      thumbs.style.display = m === "corners" ? "none" : "flex";
      if (m === "camera") { tracked = []; draw(); status(); }
      updateChip();
    }

    // --- live: the sheets' outlines over the camera --------------------------------
    function displayBox() {
      var sw = stage.clientWidth, sh = stage.clientHeight, vw = video.videoWidth, vh = video.videoHeight;
      var s = Math.min(sw / vw, sh / vh);
      return { s: s, x: (sw - vw * s) / 2, y: (sh - vh * s) / 2, sw: sw, sh: sh };
    }
    function draw() {
      if (!video.videoWidth) return;
      var box = displayBox(), dpr = window.devicePixelRatio || 1;
      var w = Math.round(box.sw * dpr), h = Math.round(box.sh * dpr);
      if (overlay.width !== w || overlay.height !== h) { overlay.width = w; overlay.height = h; }
      var ctx = overlay.getContext("2d");
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, box.sw, box.sh);
      seen().forEach(function (c) {
        ctx.beginPath();
        CORNERS.forEach(function (k, i) {
          var x = box.x + c[k].x * box.s, y = box.y + c[k].y * box.s;
          if (i) ctx.lineTo(x, y); else ctx.moveTo(x, y);
        });
        ctx.closePath();
        ctx.fillStyle = "rgba(16,163,127,.18)"; ctx.fill();
        ctx.lineWidth = 3; ctx.strokeStyle = "#10a37f"; ctx.stroke();
      });
    }
    // One frame's answer is noise: a sheet counts once frames agree on it, moves
    // halfway to each new answer, and survives a frame or two without one.
    function near(a, b) {
      var reach = 0.04 * Math.hypot(video.videoWidth, video.videoHeight);
      return CORNERS.every(function (k) { return dist(a[k], b[k]) < reach; });
    }
    function seen() {
      return tracked.filter(function (t) { return t.stable >= STABLE; }).map(function (t) { return t.c; });
    }
    function detected(list) {    // list: the sheets' corners in the video's pixels
      var used = list.map(function () { return false; });
      tracked.forEach(function (t) {
        var j = -1;
        list.forEach(function (c, i) { if (j < 0 && !used[i] && near(c, t.c)) j = i; });
        if (j < 0) { t.misses++; return; }
        used[j] = true;
        var mid = {};
        CORNERS.forEach(function (k) { mid[k] = { x: (t.c[k].x + list[j][k].x) / 2, y: (t.c[k].y + list[j][k].y) / 2 }; });
        t.c = mid; t.stable++; t.misses = 0;
      });
      tracked = tracked.filter(function (t) { return t.misses <= MISSES; });
      list.forEach(function (c, i) { if (!used[i]) tracked.push({ c: c, stable: 1, misses: 0 }); });
      draw(); status();
    }
    function startDetect() { if (!timer && !closed && workerState === "ready") tick(); }
    function tick() {
      timer = setTimeout(tick, 150);
      if (closed || detecting || busy || mode !== "camera" || workerState !== "ready" || !video.videoWidth) return;
      detecting = true;
      var f = DETECT_WIDTH / video.videoWidth;
      small.width = DETECT_WIDTH; small.height = Math.max(1, Math.round(video.videoHeight * f));
      var ctx = small.getContext("2d", { willReadFrequently: true });
      ctx.drawImage(video, 0, 0, small.width, small.height);
      var img = ctx.getImageData(0, 0, small.width, small.height);
      ask({ type: "detect", image: { data: img.data, width: img.width, height: img.height } }, [img.data.buffer], DETECT_MS)
        .then(function (r) {
          detecting = false;
          if (closed || busy || mode !== "camera") return;
          detected(((r && r.pages) || []).map(function (c) { return scaled(c, 1 / f); }));
        });
    }

    // --- a shot: measured again, every sheet in it cut with a margin ---------------
    function shot() {
      var r = Math.min(1, FRAME_LONG_SIDE / Math.max(video.videoWidth, video.videoHeight));
      var full = canvasOf(Math.round(video.videoWidth * r), Math.round(video.videoHeight * r));
      full.getContext("2d").drawImage(video, 0, 0, full.width, full.height);
      return { canvas: full, scale: r };
    }
    function capture() {
      if (!video.videoWidth || busy || mode !== "camera" || closed) return;
      busy = true;
      if (root.animate) root.animate([{ opacity: 0.4 }, { opacity: 1 }], { duration: 180 });
      tell(T.measuring);
      var s = shot(), full = s.canvas;
      var live = seen().map(function (c) { return scaled(c, s.scale); });   // in the shot's pixels
      var kept = jpeg(full, 0.9);                                           // the shot, to cut again later
      var target = retake;
      retake = null; updateChip();
      if (workerState !== "ready") { add(full, kept, [null], target); return; }
      measure(full).then(function (found) {
        if (closed) return;
        var sheets = found.length ? found : live;
        if (!sheets.length) { busy = false; cornersForShot(full, kept, target); return; }
        add(full, kept, readingOrder(sheets).map(function (c) { return withMargin(c, MARGIN, full.width, full.height); }), target);
      });
    }
    // The sheets in this very shot, at twice the preview's resolution: the
    // preview's answer is a moment older, and the hand may have moved since.
    function measure(full) {
      var f = Math.min(1, MEASURE_WIDTH / full.width), img = pixels(resized(full, f));
      return ask({ type: "detect", image: img }, [img.data.buffer], MEASURE_MS).then(function (r) {
        return ((r && r.pages) || []).map(function (c) { return scaled(c, 1 / f); });
      });
    }
    /** Pages from a shot: every cut (corners in the shot's pixels, null: the whole shot) becomes one. */
    function add(full, kept, cuts, target) {
      var f = workerState === "ready" ? filter : "colour";
      cutOut(full, cuts.map(function (c) { return c || whole(full.width, full.height); }), f).then(function (flats) {
        return kept.then(function (blob) {
          var pages = flats.map(function (_, i) { return { shot: blob, corners: cuts[i], rotation: 0, filter: f }; });
          return Promise.all(pages.map(function (p, i) { return settle(p, flats[i]); })).then(function () { return pages; });
        });
      }).then(function (pages) {
        busy = false;
        if (closed) { drop(pages); return; }
        insert(pages, target);
        renderStrip();
        thumbs.scrollLeft = thumbs.scrollWidth;
        tell("", 0);
        if (cuts.some(function (c) { return !c; })) tell(T.uncut, 2500);
        status();
      }, function (e) {
        busy = false;
        if (window.console) console.warn("[scanner] page:", e);
        tell("", 0); status();
      });
    }
    function insert(pages, target) {
      var i = target ? strip.indexOf(target) : -1;
      if (i >= 0) {                                    // the page being taken again
        strip.splice.apply(strip, [i, 1].concat(pages));
        drop([target]);
      } else {
        if (startNew && strip.length) strip.push(BREAK);
        strip.push.apply(strip, pages);
      }
      startNew = false;
      strip = tidy(strip);
    }
    function cornersForShot(full, kept, target) {
      var ix = full.width * 0.1, iy = full.height * 0.1;
      editCorners(full, ordered([{ x: ix, y: iy }, { x: full.width - ix, y: iy },
                                 { x: full.width - ix, y: full.height - iy }, { x: ix, y: full.height - iy }]), T.again,
        function (c) { busy = true; show("camera"); tell(T.measuring); add(full, kept, [c], target); },   // as set: no margin
        function () { retake = target; show("camera"); });
    }

    // --- corners by hand, on a still of the shot -----------------------------------
    function editCorners(full, guess, backWord, onUse, onBack) {
      crop = { full: full, points: CORNERS.map(function (k) { return guess[k]; }), drag: -1, grab: null,
               onUse: onUse, onBack: onBack };
      cornerBack.textContent = backWord;
      show("corners");
      tell(T.adjust);
      layoutCrop(); drawCrop();
    }
    function cropDone(use) {
      if (!crop) return;
      var c = crop, corners = ordered(c.points);
      crop = null;
      if (use) c.onUse(corners); else c.onBack();
    }
    function layoutCrop() {      // the shot fitted to the screen once; every move draws from that
      var sw = stage.clientWidth, sh = stage.clientHeight, dpr = window.devicePixelRatio || 1, f = crop.full;
      var s = Math.min(sw / f.width, sh / f.height);
      crop.box = { s: s, x: (sw - f.width * s) / 2, y: (sh - f.height * s) / 2, sw: sw, sh: sh, dpr: dpr };
      still.width = Math.round(sw * dpr); still.height = Math.round(sh * dpr);
      var base = canvasOf(still.width, still.height), ctx = base.getContext("2d");
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.drawImage(f, crop.box.x, crop.box.y, f.width * s, f.height * s);
      crop.base = base;
    }
    function drawCrop() {
      var b = crop.box, ctx = still.getContext("2d");
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.drawImage(crop.base, 0, 0);
      ctx.setTransform(b.dpr, 0, 0, b.dpr, 0, 0);
      var q = crop.points.map(function (c) { return { x: b.x + c.x * b.s, y: b.y + c.y * b.s }; });
      function outline() { ctx.moveTo(q[0].x, q[0].y); for (var i = 1; i < 4; i++) ctx.lineTo(q[i].x, q[i].y); ctx.closePath(); }
      ctx.beginPath(); ctx.rect(0, 0, b.sw, b.sh); outline();
      ctx.fillStyle = "rgba(0,0,0,.5)"; ctx.fill("evenodd");                 // what is cut away
      ctx.beginPath(); outline(); ctx.lineWidth = 2; ctx.strokeStyle = "#10a37f"; ctx.stroke();
      q.forEach(function (p, i) {
        ctx.beginPath(); ctx.arc(p.x, p.y, i === crop.drag ? 18 : 14, 0, 2 * Math.PI);
        ctx.fillStyle = "rgba(16,163,127,.3)"; ctx.fill();
        ctx.lineWidth = 3; ctx.strokeStyle = "#fff"; ctx.stroke();
      });
      if (crop.drag >= 0) loupe(ctx, b, crop.points[crop.drag], q[crop.drag]);
    }
    function loupe(ctx, b, c, at) {   // the corner under the finger, magnified where the finger is not
      var R = 56, x = at.x < b.sw / 2 ? b.sw - R - 12 : R + 12, y = R + 44;
      var r = R / (b.s * 3);              // three times closer: the loupe's radius in the shot's pixels
      ctx.save();
      ctx.beginPath(); ctx.arc(x, y, R, 0, 2 * Math.PI); ctx.clip();
      ctx.fillStyle = "#000"; ctx.fillRect(x - R, y - R, 2 * R, 2 * R);
      ctx.drawImage(crop.full, c.x - r, c.y - r, 2 * r, 2 * r, x - R, y - R, 2 * R, 2 * R);
      ctx.restore();
      ctx.beginPath(); ctx.arc(x, y, R, 0, 2 * Math.PI); ctx.lineWidth = 3; ctx.strokeStyle = "#fff"; ctx.stroke();
      ctx.beginPath(); ctx.moveTo(x - 10, y); ctx.lineTo(x + 10, y); ctx.moveTo(x, y - 10); ctx.lineTo(x, y + 10);
      ctx.lineWidth = 2; ctx.strokeStyle = "#10a37f"; ctx.stroke();
    }
    var drawing = false;
    function redrawSoon() {
      if (drawing) return;
      drawing = true;
      requestAnimationFrame(function () { drawing = false; if (crop) drawCrop(); });
    }
    function pointAt(e) { var r = still.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; }
    still.addEventListener("pointerdown", function (e) {
      if (!crop) return;
      var b = crop.box, at = pointAt(e), best = -1, reach = 48;     // a fingertip, not a pixel
      crop.points.forEach(function (c, i) {
        var d = Math.hypot(b.x + c.x * b.s - at.x, b.y + c.y * b.s - at.y);
        if (d < reach) { best = i; reach = d; }
      });
      if (best < 0) return;
      e.preventDefault();
      var c = crop.points[best];
      crop.drag = best;
      crop.grab = { x: c.x - (at.x - b.x) / b.s, y: c.y - (at.y - b.y) / b.s };   // no jump to the finger
      try { still.setPointerCapture(e.pointerId); } catch (err) { /* moves still arrive over the canvas */ }
      redrawSoon();
    });
    still.addEventListener("pointermove", function (e) {
      if (!crop || crop.drag < 0) return;
      e.preventDefault();
      var b = crop.box, at = pointAt(e), f = crop.full;
      crop.points[crop.drag] = {
        x: Math.max(0, Math.min(f.width - 1, (at.x - b.x) / b.s + crop.grab.x)),
        y: Math.max(0, Math.min(f.height - 1, (at.y - b.y) / b.s + crop.grab.y))
      };
      redrawSoon();
    });
    function release() { if (crop && crop.drag >= 0) { crop.drag = -1; redrawSoon(); } }
    still.addEventListener("pointerup", release);
    still.addEventListener("pointercancel", release);
    function onResize() { if (crop) { layoutCrop(); drawCrop(); } else { draw(); } }
    window.addEventListener("resize", onResize);

    // --- a page, opened from the strip ---------------------------------------------
    function place(page) {       // which document, which page of it, of how many
      var docs = documents(strip);
      for (var d = 0; d < docs.length; d++) {
        var i = docs[d].indexOf(page);
        if (i >= 0) return { doc: d + 1, docs: docs.length, page: i + 1, pages: docs[d].length };
      }
      return null;
    }
    function openPage(page) {
      if (busy || mode === "corners") return;
      viewing = page;
      show("page");
      showPage();
    }
    function showPage() {
      var p = viewing, at = p && place(p);
      if (!at) { viewing = null; show("camera"); renderStrip(); return; }
      picture.src = p.url;
      tell(at.docs > 1 ? fmt(T.docPage, at.doc, at.page, at.pages) : fmt(T.pageOf, at.page, at.pages));
      filterTool.word(p.filter === "document" ? T.document : T.colour);
      var i = strip.indexOf(p), ready = workerState === "ready";
      enable(earlier.button, i > 0);
      enable(later.button, i < strip.length - 1);
      enable(cropTool.button, ready);
      enable(filterTool.button, ready);
      renderStrip();
    }
    function leavePage() { viewing = null; show("camera"); renderStrip(); }
    function change(work) {      // one change to the open page, made while the screen waits
      var page = viewing;
      if (busy || !page) return;
      busy = true;
      tell(T.working);
      work(page).then(null, function (e) { if (window.console) console.warn("[scanner] edit:", e); }).then(function () {
        busy = false;
        if (viewing === page && mode === "page") showPage(); else renderStrip();
      });
    }
    rotate.button.addEventListener("click", function () {
      change(function (p) {
        p.rotation = (p.rotation + 90) % 360;
        return decoded(p.flat).then(function (flat) { return publish(p, flat); });
      });
    });
    filterTool.button.addEventListener("click", function () {
      change(function (p) { p.filter = filter = p.filter === "document" ? "colour" : "document"; return recut(p); });
    });
    cropTool.button.addEventListener("click", function () {
      var p = viewing;
      if (busy || !p) return;
      busy = true;
      tell(T.working);
      decoded(p.shot).then(function (full) {
        busy = false;
        if (closed || viewing !== p) return;
        editCorners(full, p.corners || whole(full.width, full.height), T.back,
          function (c) { p.corners = c; show("page"); change(recut); },
          function () { show("page"); showPage(); });
      }, function (e) {
        busy = false;
        if (window.console) console.warn("[scanner] crop:", e);
        showPage();
      });
    });
    earlier.button.addEventListener("click", function () { if (!busy && viewing) { strip = moved(strip, viewing, -1); showPage(); } });
    later.button.addEventListener("click", function () { if (!busy && viewing) { strip = moved(strip, viewing, 1); showPage(); } });
    remove.addEventListener("click", function () {
      var p = viewing;
      if (busy || !p) return;
      strip = tidy(strip.filter(function (x) { return x !== p; }));
      if (retake === p) retake = null;
      drop([p]);
      leavePage();
    });
    again.addEventListener("click", function () {
      if (busy || !viewing) return;
      retake = viewing;
      leavePage();
    });
    back.addEventListener("click", function () { if (!busy) leavePage(); });

    // --- the strip: every page, a break before each next document -------------------
    function label(n) { return el("span", "flex:none;font:600 11px system-ui,sans-serif;color:#aaa;padding:0 2px", "PDF " + n); }
    function renderStrip() {
      thumbs.textContent = "";
      var docs = documents(strip), many = docs.length > 1 || (startNew && strip.length > 0), d = 0, n = 0;
      if (many) thumbs.appendChild(label(1));
      strip.forEach(function (item) {
        if (item === BREAK) { d++; n = 0; thumbs.appendChild(label(d + 1)); return; }
        n++;
        var b = el("button", "position:relative;flex:none;padding:0;border-radius:4px;background:none;cursor:pointer;" +
                             "pointer-events:auto;touch-action:manipulation;border:2px solid " +
                             (item === viewing ? "#fff" : item.corners ? "#10a37f" : "#e5a50a"));
        b.setAttribute("aria-label", fmt(T.pageOf, n, docs[d].length));
        var img = el("img", "display:block;height:56px;border-radius:2px");
        img.src = item.url; img.alt = "";
        b.appendChild(img);
        b.appendChild(el("span", "position:absolute;right:2px;bottom:2px;padding:0 4px;border-radius:3px;" +
                                 "background:rgba(0,0,0,.65);font:600 11px system-ui,sans-serif", String(n)));
        b.addEventListener("click", function () { openPage(item); });
        thumbs.appendChild(b);
      });
      if (strip.length && mode === "camera") {
        if (startNew) thumbs.appendChild(label(docs.length + 1));
        var next = el("button", "flex:none;border:1px dashed rgba(255,255,255,.5);border-radius:6px;color:#fff;" +
                                "padding:8px 10px;font:600 12px system-ui,sans-serif;cursor:pointer;pointer-events:auto;" +
                                "touch-action:manipulation;background:" + (startNew ? "#10a37f" : "none"),
                      (startNew ? "✓ " : "+ ") + T.newDoc);
        next.addEventListener("click", function () { startNew = !startNew; renderStrip(); status(); });
        thumbs.appendChild(next);
      }
      var count = strip.filter(function (x) { return x !== BREAK; }).length;
      enable(done, count > 0);
      done.textContent = !count ? T.done : docs.length > 1 ? T.done + " · " + fmt(T.pdfs, docs.length) : T.done + " (" + count + ")";
      updateChip();
    }
    function updateChip() {
      var at = retake && place(retake);
      chip.style.display = at && mode === "camera" ? "block" : "none";
      if (at) chip.textContent = fmt(T.replaces, at.page) + (at.docs > 1 ? " · PDF " + at.doc : "") + "   ✕";
    }
    chip.addEventListener("click", function () { retake = null; updateChip(); });

    function finish() {
      var docs = documents(strip);
      if (!docs.length || busy) return;
      busy = true;
      tell(T.building);
      setTimeout(function () {
        var now = new Date();
        var files = docs.map(function (pages, i) {
          return new File([buildPdf(pages)], scanFileName(now, docs.length > 1 ? i + 1 : 0),
                          { type: "application/pdf", lastModified: Date.now() });
        });
        close();
        deliver(files);
      }, 30);
    }

    cancel.addEventListener("click", close);
    shoot.addEventListener("click", capture);
    done.addEventListener("click", finish);
    cornerBack.addEventListener("click", function () { cropDone(false); });
    cornerUse.addEventListener("click", function () { cropDone(true); });
    // Escape, or the phone's back gesture on a <dialog>: one step back at a time —
    // out of the corners, out of the page, out of taking a page again, then out.
    // A cancelled Escape raises no second one.
    function goBack() {
      if (mode === "corners") { cropDone(false); return; }
      if (mode === "page") { if (!busy) leavePage(); return; }
      if (retake) { retake = null; updateChip(); return; }
      close();
    }
    root.addEventListener("cancel", function (e) { e.preventDefault(); goBack(); });
    root.addEventListener("keydown", function (e) { if (e.key === "Escape") { e.preventDefault(); goBack(); } });

    listeners.push(onWorker);
    startWorker();                                   // in parallel with the camera, not after it
    video.addEventListener("loadedmetadata", function () {
      if (closed) return;
      enable(shoot, true);
      status(); startDetect();
    });
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) { hint.textContent = T.noCamera; return; }
    navigator.mediaDevices.getUserMedia({
      audio: false,
      video: { facingMode: { ideal: "environment" }, width: { ideal: 3840 }, height: { ideal: 2160 } }
    }).then(function (s) {
      if (closed) { s.getTracks().forEach(function (t) { t.stop(); }); return; }
      stream = s; video.srcObject = s;
      var p = video.play();                          // not waited for: some browsers never settle it
      if (p && p.catch) p.catch(function () { /* autoplay is allowed: muted and inline */ });
    }).catch(function (e) {
      hint.textContent = T.noCamera;
      if (window.console) console.warn("[scanner] camera:", e);
    });
  }

  // --- the button next to the paperclip -----------------------------------------
  var scheduled = false;
  function ensureButton() {
    scheduled = false;
    var attach = attachButton();
    var mine = document.getElementById("hermes-scan-button");
    if (!attach) return;
    if (mine && mine.previousElementSibling === attach) { mine.disabled = attach.disabled; return; }
    if (mine) mine.remove();
    var b = document.createElement("button");
    b.type = "button"; b.id = "hermes-scan-button";
    b.className = attach.className;
    b.setAttribute("aria-label", T.scan); b.title = T.scan;
    b.innerHTML = ICON;
    b.disabled = attach.disabled;
    ["pointerdown", "mousedown", "touchstart"].forEach(function (type) {
      b.addEventListener(type, function (e) { e.stopPropagation(); });
    });
    b.addEventListener("click", function (e) { e.preventDefault(); e.stopPropagation(); openScanner(); });
    attach.insertAdjacentElement("afterend", b);
  }
  new MutationObserver(function () {
    if (!scheduled) { scheduled = true; requestAnimationFrame(ensureButton); }
  }).observe(document.documentElement, { childList: true, subtree: true });
  ensureButton();
})();
