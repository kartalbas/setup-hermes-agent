/*
 * The document scanner in the web chat (ADR 0029).
 *
 * A button next to LibreChat's paperclip opens the camera. The page's edges are
 * found live and drawn over the picture; every shot is straightened and cropped
 * (jscanify on OpenCV.js, both loaded only when the scanner opens), and "Done"
 * turns the pages into one PDF and hands it to LibreChat's own upload input —
 * exactly as if it had been picked with the paperclip. From there it goes to the
 * bot like any other attachment.
 *
 * Plain JavaScript without a build step: the installer serves this file and the
 * two libraries next to LibreChat's own and adds one script tag to its page.
 * buildPdf and pageSize are exported for the tests when loaded under Node.
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

  function scanFileName(date) {
    var d = date || new Date();
    function two(n) { return (n < 10 ? "0" : "") + n; }
    return "Scan " + d.getFullYear() + "-" + two(d.getMonth() + 1) + "-" + two(d.getDate()) +
           " " + two(d.getHours()) + "-" + two(d.getMinutes()) + ".pdf";
  }

  if (typeof module === "object" && module.exports) {
    module.exports = { buildPdf: buildPdf, pageSize: pageSize, scanFileName: scanFileName };
  }
  if (typeof window === "undefined" || typeof document === "undefined") return;

  // ---------------------------------------------------------------------------
  // In the browser.
  // ---------------------------------------------------------------------------
  var SRC = (document.currentScript && document.currentScript.src) || "";
  var BASE = SRC.replace(/scan\.js(\?.*)?$/, "");
  // The page's tag carries one version for the scanner and its libraries
  // together; asking for them with it keeps a cached old library from staying.
  var QUERY = (SRC.match(/[?&]v=([0-9a-f]+)/) || [])[1] ? "?v=" + SRC.match(/[?&]v=([0-9a-f]+)/)[1] : "";
  var DETECT_WIDTH = 480;        // the live detection runs on a small copy of the frame
  var PAGE_LONG_SIDE = 2400;     // about 200 dpi on A4: small files, sharp text
  var MIN_PAGE_SHARE = 0.12;     // a "page" smaller than this share of the frame is noise

  var de = /^de\b/i.test(navigator.language || "");
  var T = de ? {
    scan: "Dokument scannen", capture: "Aufnehmen", done: "Fertig", cancel: "Abbrechen",
    find: "Blatt ganz ins Bild halten – ein dunkler Untergrund hilft", found: "Seite erkannt",
    loading: "Scanner wird geladen …", building: "PDF wird erstellt …",
    noCamera: "Keine Kamera verfügbar, oder der Zugriff wurde nicht erlaubt.",
    failed: "Der Scanner konnte nicht geladen werden.", uncut: "Keine Blattkante gefunden – Seite ungeschnitten übernommen",
    remove: "Seite entfernen", fallback: "Das PDF wurde heruntergeladen – bitte über die Büroklammer anhängen."
  } : {
    scan: "Scan a document", capture: "Capture", done: "Done", cancel: "Cancel",
    find: "Fit the whole page in the frame – a dark background helps", found: "Page detected",
    loading: "Loading the scanner …", building: "Building the PDF …",
    noCamera: "No camera available, or access was not allowed.",
    failed: "The scanner could not be loaded.", uncut: "No page edge found – page taken uncropped",
    remove: "Remove page", fallback: "The PDF was downloaded – please attach it with the paperclip."
  };

  var ICON = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ' +
    'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 7V5a2 2 0 0 1 2-2h2"/>' +
    '<path d="M17 3h2a2 2 0 0 1 2 2v2"/><path d="M21 17v2a2 2 0 0 1-2 2h-2"/><path d="M7 21H5a2 2 0 0 1-2-2v-2"/>' +
    '<path d="M8 8h8"/><path d="M8 12h8"/><path d="M8 16h5"/></svg>';

  // --- libraries, loaded once, when first needed --------------------------------
  var libs = null;
  function loadScript(src) {
    return new Promise(function (resolve, reject) {
      var s = document.createElement("script");
      s.src = src; s.async = true;
      s.onload = function () { resolve(); };
      s.onerror = function () { reject(new Error("could not load " + src)); };
      document.head.appendChild(s);
    });
  }
  function cvReady(timeoutMs) {
    // OpenCV.js reports itself ready asynchronously, and some builds hand out a
    // thenable module; waiting for the API itself sidesteps both.
    return new Promise(function (resolve, reject) {
      var started = Date.now();
      (function poll() {
        var cv = window.cv;
        if (cv && typeof cv.Mat === "function" && typeof cv.imread === "function") return resolve(cv);
        if (Date.now() - started > timeoutMs) return reject(new Error("OpenCV did not start"));
        setTimeout(poll, 100);
      })();
    });
  }
  function loadLibs() {
    if (!libs) {
      libs = loadScript(BASE + "opencv.js" + QUERY)
        .then(function () { return cvReady(45000); })
        .then(function () { return loadScript(BASE + "jscanify.js" + QUERY); })
        .then(function () { return new window.jscanify(); })
        .catch(function (e) { libs = null; throw e; });
    }
    return libs;
  }

  // --- the page's corners -------------------------------------------------------
  function corners(scanner, canvas) {
    var cv = window.cv, mat = cv.imread(canvas), contour = null;
    try {
      contour = scanner.findPaperContour(mat);
      if (!contour) return null;
      if (cv.contourArea(contour) < MIN_PAGE_SHARE * canvas.width * canvas.height) return null;
      var c = scanner.getCornerPoints(contour);
      if (!c.topLeftCorner || !c.topRightCorner || !c.bottomLeftCorner || !c.bottomRightCorner) return null;
      return c;
    } catch (e) {
      return null;
    } finally {
      mat.delete();
      if (contour) { try { contour.delete(); } catch (e) { /* already freed */ } }
    }
  }
  function scaled(c, f) {
    function p(q) { return { x: q.x * f, y: q.y * f }; }
    return { topLeftCorner: p(c.topLeftCorner), topRightCorner: p(c.topRightCorner),
             bottomLeftCorner: p(c.bottomLeftCorner), bottomRightCorner: p(c.bottomRightCorner) };
  }
  function dist(a, b) { return Math.hypot(a.x - b.x, a.y - b.y); }

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
  var BTN = "border:0;border-radius:999px;padding:12px 18px;font:600 15px system-ui,sans-serif;" +
            "background:rgba(255,255,255,.14);color:#fff;cursor:pointer;min-width:96px";

  function openScanner() {
    var pages = [], stream = null, timer = null, busy = false, closed = false, scanner = null, last = null;

    var root = el("div", "position:fixed;inset:0;z-index:2147483647;background:#000;display:flex;" +
                         "flex-direction:column;color:#fff;font:15px system-ui,sans-serif;" +
                         "padding:env(safe-area-inset-top) 0 env(safe-area-inset-bottom)");
    root.setAttribute("role", "dialog"); root.setAttribute("aria-label", T.scan);
    var stage = el("div", "position:relative;flex:1;overflow:hidden");
    var video = el("video", "position:absolute;inset:0;width:100%;height:100%;object-fit:contain");
    video.setAttribute("playsinline", ""); video.muted = true; video.autoplay = true;
    var overlay = el("canvas", "position:absolute;inset:0;width:100%;height:100%;pointer-events:none");
    var hint = el("div", "position:absolute;left:0;right:0;top:12px;text-align:center;padding:0 16px;" +
                         "text-shadow:0 1px 3px #000", T.loading);
    stage.appendChild(video); stage.appendChild(overlay); stage.appendChild(hint);
    var thumbs = el("div", "display:flex;gap:8px;overflow-x:auto;padding:8px 12px;min-height:0");
    var bar = el("div", "display:flex;align-items:center;justify-content:space-between;padding:12px 16px 16px");
    var cancel = el("button", BTN, T.cancel);
    var shoot = el("button", "width:72px;height:72px;border-radius:50%;border:4px solid #fff;background:#fff;" +
                             "box-shadow:inset 0 0 0 3px #000;cursor:pointer");
    shoot.setAttribute("aria-label", T.capture); shoot.disabled = true;
    var done = el("button", BTN + ";background:#10a37f", T.done);
    done.disabled = true; done.style.opacity = ".5";
    bar.appendChild(cancel); bar.appendChild(shoot); bar.appendChild(done);
    root.appendChild(stage); root.appendChild(thumbs); root.appendChild(bar);
    document.body.appendChild(root);

    var small = document.createElement("canvas");

    function close() {
      closed = true;
      if (timer) clearTimeout(timer);
      if (stream) stream.getTracks().forEach(function (t) { t.stop(); });
      root.remove();
    }
    function fail(message) { hint.textContent = message; shoot.disabled = true; }

    function refreshDone() {
      done.disabled = pages.length === 0;
      done.style.opacity = pages.length ? "1" : ".5";
      done.textContent = pages.length ? T.done + " (" + pages.length + ")" : T.done;
    }

    function displayBox() {
      var sw = stage.clientWidth, sh = stage.clientHeight, vw = video.videoWidth, vh = video.videoHeight;
      var s = Math.min(sw / vw, sh / vh);
      return { s: s, x: (sw - vw * s) / 2, y: (sh - vh * s) / 2, sw: sw, sh: sh };
    }

    function detect() {
      if (closed) return;
      if (!busy && video.videoWidth) {
        busy = true;
        try {
          var f = DETECT_WIDTH / video.videoWidth;
          small.width = DETECT_WIDTH; small.height = Math.round(video.videoHeight * f);
          small.getContext("2d").drawImage(video, 0, 0, small.width, small.height);
          var c = corners(scanner, small);
          last = c ? scaled(c, 1 / f) : null;          // in the video's own pixels
          var box = displayBox(), dpr = window.devicePixelRatio || 1;
          overlay.width = box.sw * dpr; overlay.height = box.sh * dpr;
          var ctx = overlay.getContext("2d");
          ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
          ctx.clearRect(0, 0, box.sw, box.sh);
          if (last) {
            var q = [last.topLeftCorner, last.topRightCorner, last.bottomRightCorner, last.bottomLeftCorner];
            ctx.beginPath();
            q.forEach(function (p, i) {
              var x = box.x + p.x * box.s, y = box.y + p.y * box.s;
              if (i) ctx.lineTo(x, y); else ctx.moveTo(x, y);
            });
            ctx.closePath();
            ctx.fillStyle = "rgba(16,163,127,.18)"; ctx.fill();
            ctx.lineWidth = 3; ctx.strokeStyle = "#10a37f"; ctx.stroke();
          }
          hint.textContent = last ? T.found : T.find;
        } finally { busy = false; }
      }
      timer = setTimeout(detect, 150);
    }

    function capture() {
      if (!video.videoWidth || busy) return;
      busy = true;
      var full = document.createElement("canvas");
      full.width = video.videoWidth; full.height = video.videoHeight;
      full.getContext("2d").drawImage(video, 0, 0);
      var c = last, page = null, cut = true;
      if (c) {
        try {
          var w = Math.max(dist(c.topLeftCorner, c.topRightCorner), dist(c.bottomLeftCorner, c.bottomRightCorner));
          var h = Math.max(dist(c.topLeftCorner, c.bottomLeftCorner), dist(c.topRightCorner, c.bottomRightCorner));
          var k = Math.min(1, PAGE_LONG_SIDE / Math.max(w, h));
          page = scanner.extractPaper(full, Math.round(w * k), Math.round(h * k), c);
        } catch (e) {
          page = null;                               // an odd quadrilateral: take the frame instead
        }
      }
      if (!page) {                                   // no edge: the whole frame, scaled down
        cut = false;
        var r = Math.min(1, PAGE_LONG_SIDE / Math.max(full.width, full.height));
        page = document.createElement("canvas");
        page.width = Math.round(full.width * r); page.height = Math.round(full.height * r);
        page.getContext("2d").drawImage(full, 0, 0, page.width, page.height);
      }
      page.toBlob(function (blob) {
        busy = false;
        if (!blob) return;
        blob.arrayBuffer().then(function (buf) {
          var entry = { jpeg: new Uint8Array(buf), width: page.width, height: page.height };
          pages.push(entry);
          var t = el("img", "height:64px;border-radius:4px;border:2px solid " + (cut ? "#10a37f" : "#e5a50a") +
                            ";cursor:pointer;flex:none");
          t.src = URL.createObjectURL(blob); t.alt = T.remove; t.title = T.remove;
          t.onclick = function () {
            pages.splice(pages.indexOf(entry), 1); URL.revokeObjectURL(t.src); t.remove(); refreshDone();
          };
          thumbs.appendChild(t);
          refreshDone();
          if (!cut) hint.textContent = T.uncut;
        });
      }, "image/jpeg", 0.85);
      root.animate && root.animate([{ opacity: 0.4 }, { opacity: 1 }], { duration: 180 });
    }

    function finish() {
      if (!pages.length) return;
      hint.textContent = T.building;
      setTimeout(function () {
        var pdf = buildPdf(pages);
        var file = new File([pdf], scanFileName(), { type: "application/pdf", lastModified: Date.now() });
        close();
        deliver(file);
      }, 30);
    }

    cancel.onclick = close;
    shoot.onclick = capture;
    done.onclick = finish;
    document.addEventListener("keydown", function esc(e) {
      if (e.key === "Escape") { document.removeEventListener("keydown", esc); close(); }
    });

    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) { fail(T.noCamera); return; }
    navigator.mediaDevices.getUserMedia({
      audio: false,
      video: { facingMode: { ideal: "environment" }, width: { ideal: 3840 }, height: { ideal: 2160 } }
    }).then(function (s) {
      if (closed) { s.getTracks().forEach(function (t) { t.stop(); }); return; }
      stream = s; video.srcObject = s;
      return video.play().catch(function () { /* autoplay is allowed: muted and inline */ });
    }).then(function () {
      return loadLibs();
    }).then(function (sc) {
      if (closed) return;
      scanner = sc; shoot.disabled = false; hint.textContent = T.find;
      detect();
    }).catch(function (e) {
      fail(stream ? T.failed : T.noCamera);
      if (window.console) console.warn("[scanner]", e);
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
    b.addEventListener("click", function (e) { e.preventDefault(); e.stopPropagation(); openScanner(); });
    attach.insertAdjacentElement("afterend", b);
  }
  new MutationObserver(function () {
    if (!scheduled) { scheduled = true; requestAnimationFrame(ensureButton); }
  }).observe(document.documentElement, { childList: true, subtree: true });
  ensureButton();
})();
