/*
 * The document scanner in the web chat (ADR 0029).
 *
 * A button next to LibreChat's paperclip opens the camera. The page's edges are
 * found live and drawn over the picture; a shot of a page that was seen is
 * straightened and cropped at once, a shot without one opens a still of it with
 * four corners to drag, and "Done" turns the pages into one PDF and hands it to
 * LibreChat's own upload input — exactly as if it had been picked with the
 * paperclip. From there it goes to the bot like any other attachment. The image
 * work (OpenCV.js) runs in scan-worker.js, off the page's thread; until it is
 * ready — or if it cannot start — the camera still takes pages, uncropped.
 *
 * Plain JavaScript without a build step: the installer serves this file and the
 * two libraries next to LibreChat's own and adds one script tag to its page.
 * buildPdf, pageSize, scanFileName and ordered are exported for the tests when
 * loaded under Node.
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

  function scanFileName(date) {
    var d = date || new Date();
    function two(n) { return (n < 10 ? "0" : "") + n; }
    return "Scan " + d.getFullYear() + "-" + two(d.getMonth() + 1) + "-" + two(d.getDate()) +
           " " + two(d.getHours()) + "-" + two(d.getMinutes()) + ".pdf";
  }

  if (typeof module === "object" && module.exports) {
    module.exports = { buildPdf: buildPdf, pageSize: pageSize, scanFileName: scanFileName, ordered: ordered };
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
  var DETECT_WIDTH = 480;        // the live detection runs on a small copy of the frame
  var FRAME_LONG_SIDE = 3200;    // a captured frame, before it is cut
  var PAGE_LONG_SIDE = 2400;     // about 200 dpi on A4: small files, sharp text

  var de = /^de\b/i.test(navigator.language || "");
  var T = de ? {
    scan: "Dokument scannen", capture: "Aufnehmen", done: "Fertig", cancel: "Abbrechen",
    camera: "Kamera wird gestartet …", loading: "Randerkennung wird geladen (einmalig ca. 9 MB) …",
    find: "Ganzes Blatt ins Bild halten, mit etwas Rand", found: "Seite erkannt",
    adjust: "Ecken auf die Blattecken ziehen", retake: "Neu", use: "Übernehmen",
    building: "PDF wird erstellt …", noCamera: "Keine Kamera verfügbar, oder der Zugriff wurde nicht erlaubt.",
    noDetect: "Randerkennung nicht verfügbar – Aufnahmen werden ungeschnitten übernommen",
    uncut: "Seite ungeschnitten übernommen",
    remove: "Seite entfernen", fallback: "Das PDF wurde heruntergeladen – bitte über die Büroklammer anhängen."
  } : {
    scan: "Scan a document", capture: "Capture", done: "Done", cancel: "Cancel",
    camera: "Starting the camera …", loading: "Loading edge detection (about 9 MB, once) …",
    find: "Fit the whole page in the frame, with a little margin", found: "Page detected",
    adjust: "Drag the corners onto the page's corners", retake: "Retake", use: "Use",
    building: "Building the PDF …", noCamera: "No camera available, or access was not allowed.",
    noDetect: "Edge detection unavailable – pages are taken uncropped",
    uncut: "Page taken uncropped",
    remove: "Remove page", fallback: "The PDF was downloaded – please attach it with the paperclip."
  };

  var ICON = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ' +
    'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 7V5a2 2 0 0 1 2-2h2"/>' +
    '<path d="M17 3h2a2 2 0 0 1 2 2v2"/><path d="M21 17v2a2 2 0 0 1-2 2h-2"/><path d="M7 21H5a2 2 0 0 1-2-2v-2"/>' +
    '<path d="M8 8h8"/><path d="M8 12h8"/><path d="M8 16h5"/></svg>';

  // --- the worker: OpenCV off the page's thread --------------------------------
  // Started when the scanner first opens and kept for the next page; one that
  // failed is dropped, and the next opening starts a new one.
  var WORKER_START_MS = 120000, DETECT_MS = 5000, EXTRACT_MS = 20000;
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

  function scaled(c, f) {
    function p(q) { return { x: q.x * f, y: q.y * f }; }
    return { topLeftCorner: p(c.topLeftCorner), topRightCorner: p(c.topRightCorner),
             bottomLeftCorner: p(c.bottomLeftCorner), bottomRightCorner: p(c.bottomRightCorner) };
  }
  function dist(a, b) { return Math.hypot(a.x - b.x, a.y - b.y); }
  function downscaled(canvas, longSide) {
    var r = Math.min(1, longSide / Math.max(canvas.width, canvas.height));
    if (r === 1) return canvas;
    var out = document.createElement("canvas");
    out.width = Math.round(canvas.width * r); out.height = Math.round(canvas.height * r);
    out.getContext("2d").drawImage(canvas, 0, 0, out.width, out.height);
    return out;
  }

  // --- LibreChat's own upload ---------------------------------------------------
  function attachButton() { return document.getElementById("attach-file-menu-button"); }
  function fileInputNear(el) {
    for (var node = el; node && node !== document.body; node = node.parentElement) {
      var input = node.querySelector('input[type="file"]');
      if (input) return input;
    }
    return null;
  }
  function deliver(file) {
    var attach = attachButton(), input = attach && fileInputNear(attach);
    if (input && typeof DataTransfer === "function") {
      try {
        var dt = new DataTransfer();
        dt.items.add(file);
        input.files = dt.files;
        input.dispatchEvent(new Event("change", { bubbles: true }));
        return true;
      } catch (e) { /* fall through to the download */ }
    }
    var a = document.createElement("a");
    a.href = URL.createObjectURL(file); a.download = file.name;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(function () { URL.revokeObjectURL(a.href); }, 60000);
    alert(T.fallback);
    return false;
  }

  // --- the scanner screen -------------------------------------------------------
  function el(tag, style, text) {
    var e = document.createElement(tag);
    if (style) e.style.cssText = style;
    if (text) e.textContent = text;
    return e;
  }
  var BTN = "border:0;border-radius:999px;padding:12px 18px;font:600 15px system-ui,sans-serif;pointer-events:auto;" +
            "background:rgba(255,255,255,.14);color:#fff;cursor:pointer;min-width:96px;touch-action:manipulation";
  var BAR = "display:flex;align-items:center;justify-content:space-between;padding:12px 16px 16px;" +
            "flex:none;pointer-events:auto";
  var STABLE = 2;                // frames in a row that agree before the outline counts
  var MISSES = 2;                // frames without a page before the outline goes

  function openScanner() {
    if (document.getElementById("hermes-scanner")) return;
    var pages = [], stream = null, timer = null, detecting = false, capturing = false, closed = false;
    var last = null, stable = 0, misses = 0, review = null;

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
    var hint = el("div", "position:absolute;left:0;right:0;top:12px;text-align:center;padding:0 16px;" +
                         "text-shadow:0 1px 3px #000;pointer-events:none", T.camera);
    stage.appendChild(video); stage.appendChild(overlay); stage.appendChild(still); stage.appendChild(hint);
    var thumbs = el("div", "display:flex;gap:8px;overflow-x:auto;padding:8px 12px;flex:none;pointer-events:auto");
    var bar = el("div", BAR);
    var cancel = el("button", BTN, T.cancel);
    var shoot = el("button", "width:72px;height:72px;border-radius:50%;border:4px solid #fff;background:#fff;" +
                             "box-shadow:inset 0 0 0 3px #000;cursor:pointer;pointer-events:auto;touch-action:manipulation");
    shoot.setAttribute("aria-label", T.capture); shoot.disabled = true; shoot.style.opacity = ".4";
    var done = el("button", BTN + ";background:#10a37f", T.done);
    done.disabled = true; done.style.opacity = ".5";
    var reviewBar = el("div", BAR + ";display:none");
    var retake = el("button", BTN, T.retake), use = el("button", BTN + ";background:#10a37f", T.use);
    [cancel, shoot, done, retake, use].forEach(function (b) { b.type = "button"; });
    bar.appendChild(cancel); bar.appendChild(shoot); bar.appendChild(done);
    reviewBar.appendChild(retake); reviewBar.appendChild(use);
    root.appendChild(stage); root.appendChild(thumbs); root.appendChild(bar); root.appendChild(reviewBar);
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
      if (useDialog && root.open) { try { root.close(); } catch (e) { /* removed below */ } }
      root.remove();
    }
    function refreshDone() {
      done.disabled = pages.length === 0;
      done.style.opacity = pages.length ? "1" : ".5";
      done.textContent = pages.length ? T.done + " (" + pages.length + ")" : T.done;
    }
    function status() {
      if (review || !video.videoWidth) return;
      if (workerState === "ready") hint.textContent = last && stable >= STABLE ? T.found : T.find;
      else if (workerState === "failed") hint.textContent = T.noDetect;
      else hint.textContent = T.loading;
    }
    function onWorker() { if (!closed) { status(); startDetect(); } }

    // --- live: the page's outline over the camera ---------------------------------
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
      if (!last || stable < STABLE) return;
      ctx.beginPath();
      CORNERS.forEach(function (k, i) {
        var x = box.x + last[k].x * box.s, y = box.y + last[k].y * box.s;
        if (i) ctx.lineTo(x, y); else ctx.moveTo(x, y);
      });
      ctx.closePath();
      ctx.fillStyle = "rgba(16,163,127,.18)"; ctx.fill();
      ctx.lineWidth = 3; ctx.strokeStyle = "#10a37f"; ctx.stroke();
    }
    // One frame's answer is noise; the outline counts once frames agree, moves
    // halfway to each new answer, and survives a frame or two without one.
    function near(a, b) {
      var reach = 0.04 * Math.hypot(video.videoWidth, video.videoHeight);
      return CORNERS.every(function (k) { return dist(a[k], b[k]) < reach; });
    }
    function detected(c) {       // c: the page's corners in the video's pixels, or null
      if (c && last && near(c, last)) {
        var mid = {};
        CORNERS.forEach(function (k) { mid[k] = { x: (last[k].x + c[k].x) / 2, y: (last[k].y + c[k].y) / 2 }; });
        last = mid; stable++; misses = 0;
      } else if (c) {
        last = c; stable = 1; misses = 0;
      } else if (last && ++misses > MISSES) {
        last = null; stable = 0;
      }
      draw(); status();
    }
    function startDetect() { if (!timer && !closed && workerState === "ready") tick(); }
    function tick() {
      timer = setTimeout(tick, 150);
      if (closed || detecting || capturing || review || workerState !== "ready" || !video.videoWidth) return;
      detecting = true;
      var f = DETECT_WIDTH / video.videoWidth;
      small.width = DETECT_WIDTH; small.height = Math.max(1, Math.round(video.videoHeight * f));
      var ctx = small.getContext("2d", { willReadFrequently: true });
      ctx.drawImage(video, 0, 0, small.width, small.height);
      var img = ctx.getImageData(0, 0, small.width, small.height);
      ask({ type: "detect", image: { data: img.data, width: img.width, height: img.height } }, [img.data.buffer], DETECT_MS)
        .then(function (r) {
          detecting = false;
          if (closed || review) return;
          detected(r && r.corners ? scaled(r.corners, 1 / f) : null);   // in the video's own pixels
        });
    }

    // --- a page: cut out, or kept whole ------------------------------------------
    function addPage(canvas, cut) {
      canvas.toBlob(function (blob) {
        capturing = false;
        if (!blob || closed) return;
        blob.arrayBuffer().then(function (buf) {
          var entry = { jpeg: new Uint8Array(buf), width: canvas.width, height: canvas.height };
          pages.push(entry);
          var t = el("img", "height:64px;border-radius:4px;border:2px solid " + (cut ? "#10a37f" : "#e5a50a") +
                            ";cursor:pointer;flex:none;pointer-events:auto");
          t.src = URL.createObjectURL(blob); t.alt = T.remove; t.title = T.remove;
          t.addEventListener("click", function () {
            pages.splice(pages.indexOf(entry), 1); URL.revokeObjectURL(t.src); t.remove(); refreshDone();
          });
          thumbs.appendChild(t);
          refreshDone();
          if (!cut) hint.textContent = T.uncut;
        });
      }, "image/jpeg", 0.85);
    }
    function cutOut(full, c) {   // c: the page's corners in the shot's pixels
      var w = Math.max(dist(c.topLeftCorner, c.topRightCorner), dist(c.bottomLeftCorner, c.bottomRightCorner));
      var h = Math.max(dist(c.topLeftCorner, c.bottomLeftCorner), dist(c.topRightCorner, c.bottomRightCorner));
      var k = Math.min(1, PAGE_LONG_SIDE / Math.max(w, h, 1));
      var img = full.getContext("2d").getImageData(0, 0, full.width, full.height);
      ask({ type: "extract", image: { data: img.data, width: img.width, height: img.height }, corners: c,
            width: Math.max(1, Math.round(w * k)), height: Math.max(1, Math.round(h * k)) }, [img.data.buffer], EXTRACT_MS)
        .then(function (res) {
          if (closed) { capturing = false; return; }
          if (res && res.image) {
            var page = document.createElement("canvas");
            page.width = res.image.width; page.height = res.image.height;
            page.getContext("2d").putImageData(new ImageData(res.image.data, res.image.width, res.image.height), 0, 0);
            addPage(page, true);
          } else {
            addPage(downscaled(full, PAGE_LONG_SIDE), false);
          }
        });
    }
    function shot() {
      var r = Math.min(1, FRAME_LONG_SIDE / Math.max(video.videoWidth, video.videoHeight));
      var full = document.createElement("canvas");
      full.width = Math.round(video.videoWidth * r); full.height = Math.round(video.videoHeight * r);
      full.getContext("2d").drawImage(video, 0, 0, full.width, full.height);
      return { canvas: full, scale: r };
    }
    function capture() {
      if (!video.videoWidth || capturing || review || closed) return;
      if (root.animate) root.animate([{ opacity: 0.4 }, { opacity: 1 }], { duration: 180 });
      var s = shot();
      if (workerState !== "ready") { capturing = true; addPage(downscaled(s.canvas, PAGE_LONG_SIDE), false); return; }
      if (last && stable >= STABLE) { capturing = true; cutOut(s.canvas, scaled(last, s.scale)); return; }
      startReview(s.canvas, last ? scaled(last, s.scale) : null);
    }

    // --- by hand: no page seen, so the corners are set on a still of the shot ----
    function startReview(full, guess) {
      var ix = full.width * 0.1, iy = full.height * 0.1;
      var c = guess || ordered([{ x: ix, y: iy }, { x: full.width - ix, y: iy },
                                { x: full.width - ix, y: full.height - iy }, { x: ix, y: full.height - iy }]);
      review = { full: full, corners: CORNERS.map(function (k) { return c[k]; }), drag: -1, grab: null };
      video.style.visibility = "hidden"; overlay.style.display = "none"; still.style.display = "block";
      bar.style.display = "none"; reviewBar.style.display = "flex";
      hint.textContent = T.adjust;
      layoutReview(); drawReview();
    }
    function endReview() {
      review = null; last = null; stable = 0; misses = 0;
      still.style.display = "none"; video.style.visibility = ""; overlay.style.display = "";
      reviewBar.style.display = "none"; bar.style.display = "flex";
      draw(); status();
    }
    function useReview() {
      if (!review || capturing) return;
      var full = review.full, c = ordered(review.corners);
      endReview();
      capturing = true;
      cutOut(full, c);
    }
    function layoutReview() {    // the shot fitted to the screen once; every move draws from that
      var sw = stage.clientWidth, sh = stage.clientHeight, dpr = window.devicePixelRatio || 1, f = review.full;
      var s = Math.min(sw / f.width, sh / f.height);
      review.box = { s: s, x: (sw - f.width * s) / 2, y: (sh - f.height * s) / 2, sw: sw, sh: sh, dpr: dpr };
      still.width = Math.round(sw * dpr); still.height = Math.round(sh * dpr);
      var base = document.createElement("canvas");
      base.width = still.width; base.height = still.height;
      var ctx = base.getContext("2d");
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.drawImage(f, review.box.x, review.box.y, f.width * s, f.height * s);
      review.base = base;
    }
    function drawReview() {
      var b = review.box, ctx = still.getContext("2d");
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.drawImage(review.base, 0, 0);
      ctx.setTransform(b.dpr, 0, 0, b.dpr, 0, 0);
      var q = review.corners.map(function (c) { return { x: b.x + c.x * b.s, y: b.y + c.y * b.s }; });
      function outline() { ctx.moveTo(q[0].x, q[0].y); for (var i = 1; i < 4; i++) ctx.lineTo(q[i].x, q[i].y); ctx.closePath(); }
      ctx.beginPath(); ctx.rect(0, 0, b.sw, b.sh); outline();
      ctx.fillStyle = "rgba(0,0,0,.5)"; ctx.fill("evenodd");                 // what is cut away
      ctx.beginPath(); outline(); ctx.lineWidth = 2; ctx.strokeStyle = "#10a37f"; ctx.stroke();
      q.forEach(function (p, i) {
        ctx.beginPath(); ctx.arc(p.x, p.y, i === review.drag ? 18 : 14, 0, 2 * Math.PI);
        ctx.fillStyle = "rgba(16,163,127,.3)"; ctx.fill();
        ctx.lineWidth = 3; ctx.strokeStyle = "#fff"; ctx.stroke();
      });
      if (review.drag >= 0) loupe(ctx, b, review.corners[review.drag], q[review.drag]);
    }
    function loupe(ctx, b, c, at) {   // the corner under the finger, magnified where the finger is not
      var R = 56, x = at.x < b.sw / 2 ? b.sw - R - 12 : R + 12, y = R + 44;
      var r = R / (b.s * 3);              // three times closer: the loupe's radius in the shot's pixels
      ctx.save();
      ctx.beginPath(); ctx.arc(x, y, R, 0, 2 * Math.PI); ctx.clip();
      ctx.fillStyle = "#000"; ctx.fillRect(x - R, y - R, 2 * R, 2 * R);
      ctx.drawImage(review.full, c.x - r, c.y - r, 2 * r, 2 * r, x - R, y - R, 2 * R, 2 * R);
      ctx.restore();
      ctx.beginPath(); ctx.arc(x, y, R, 0, 2 * Math.PI); ctx.lineWidth = 3; ctx.strokeStyle = "#fff"; ctx.stroke();
      ctx.beginPath(); ctx.moveTo(x - 10, y); ctx.lineTo(x + 10, y); ctx.moveTo(x, y - 10); ctx.lineTo(x, y + 10);
      ctx.lineWidth = 2; ctx.strokeStyle = "#10a37f"; ctx.stroke();
    }
    var drawing = false;
    function redrawSoon() {
      if (drawing) return;
      drawing = true;
      requestAnimationFrame(function () { drawing = false; if (review) drawReview(); });
    }
    function pointAt(e) { var r = still.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; }
    still.addEventListener("pointerdown", function (e) {
      if (!review) return;
      var b = review.box, at = pointAt(e), best = -1, reach = 48;   // a fingertip, not a pixel
      review.corners.forEach(function (c, i) {
        var d = Math.hypot(b.x + c.x * b.s - at.x, b.y + c.y * b.s - at.y);
        if (d < reach) { best = i; reach = d; }
      });
      if (best < 0) return;
      e.preventDefault();
      var c = review.corners[best];
      review.drag = best;
      review.grab = { x: c.x - (at.x - b.x) / b.s, y: c.y - (at.y - b.y) / b.s };   // no jump to the finger
      try { still.setPointerCapture(e.pointerId); } catch (err) { /* moves still arrive over the canvas */ }
      redrawSoon();
    });
    still.addEventListener("pointermove", function (e) {
      if (!review || review.drag < 0) return;
      e.preventDefault();
      var b = review.box, at = pointAt(e), f = review.full;
      review.corners[review.drag] = {
        x: Math.max(0, Math.min(f.width - 1, (at.x - b.x) / b.s + review.grab.x)),
        y: Math.max(0, Math.min(f.height - 1, (at.y - b.y) / b.s + review.grab.y))
      };
      redrawSoon();
    });
    function release() { if (review && review.drag >= 0) { review.drag = -1; redrawSoon(); } }
    still.addEventListener("pointerup", release);
    still.addEventListener("pointercancel", release);
    function onResize() { if (review) { layoutReview(); drawReview(); } else { draw(); } }
    window.addEventListener("resize", onResize);

    function finish() {
      if (!pages.length) return;
      hint.textContent = T.building;
      setTimeout(function () {
        var file = new File([buildPdf(pages)], scanFileName(), { type: "application/pdf", lastModified: Date.now() });
        close();
        deliver(file);
      }, 30);
    }

    cancel.addEventListener("click", close);
    shoot.addEventListener("click", capture);
    done.addEventListener("click", finish);
    retake.addEventListener("click", endReview);
    use.addEventListener("click", useReview);
    // Escape, or the phone's back gesture on a <dialog>: out of the corners
    // first, then out of the scanner. A cancelled Escape raises no second one.
    function back() { if (review) endReview(); else close(); }
    root.addEventListener("cancel", function (e) { e.preventDefault(); back(); });
    root.addEventListener("keydown", function (e) { if (e.key === "Escape") { e.preventDefault(); back(); } });

    listeners.push(onWorker);
    startWorker();                                   // in parallel with the camera, not after it
    video.addEventListener("loadedmetadata", function () {
      if (closed) return;
      shoot.disabled = false; shoot.style.opacity = "1";
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
