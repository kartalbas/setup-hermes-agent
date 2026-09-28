/*
 * The web chat as an app (ADR 0029): one button that installs it.
 *
 * The chat is installable — a manifest with its own name and icon, a service
 * worker — but Chrome and Edge show that only as a small icon in the address
 * bar or an entry deep in a menu, and Safari, on the iPhone, the iPad and the
 * Mac, has no install button at all. This puts one on the page: where the
 * browser offers to install (beforeinstallprompt), it opens the browser's own
 * dialog; in Safari it shows the two steps there are. Opened as the app,
 * installed, or dismissed, it stays away.
 *
 * Plain JavaScript without a build step, served next to LibreChat's files with
 * a script tag of its own. offer() is exported for the tests under Node.
 */
(function () {
  "use strict";

  /** What to offer: "prompt" (the browser installs), "ios", "mac" (the steps), or null. */
  function offer(env) {
    if (env.standalone || env.dismissed) return null;
    if (env.canPrompt) return "prompt";
    var ua = env.userAgent || "";
    // an iPad asks for the desktop site and says Macintosh, but it has a touch screen
    if (/iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && env.touchPoints > 1)) return "ios";
    if (/Macintosh/.test(ua) && /Version\/[\d.]+.*Safari\//.test(ua) && !/Chrome|Chromium|Edg\//.test(ua)) return "mac";
    return null;
  }

  if (typeof module === "object" && module.exports) {
    module.exports = { offer: offer };
  }
  if (typeof window === "undefined" || typeof document === "undefined") return;

  var KEY = "hermes-app-dismissed";
  var SHOW_AFTER_MS = 2000;      // not on a page that is about to go on to the sign-in
  var de = /^de\b/i.test(navigator.language || "");
  var T = de ? {
    app: "{name} als App", install: "Installieren", close: "Schliessen",
    ios: "Tippe auf „Teilen“ {share} und dann auf „Zum Home-Bildschirm“.",
    mac: "Im Menü „Ablage“ auf „Zum Dock hinzufügen“."
  } : {
    app: "{name} as an app", install: "Install", close: "Close",
    ios: "Tap “Share” {share}, then “Add to Home Screen”.",
    mac: "In the File menu, choose “Add to Dock”."
  };
  var SHARE = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ' +
    'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="vertical-align:-3px">' +
    '<path d="M12 3v12"/><path d="M8 7l4-4 4 4"/><path d="M5 11v8a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-8"/></svg>';

  function standalone() {
    var mm = window.matchMedia;
    return !!(mm && (mm("(display-mode: standalone)").matches || mm("(display-mode: window-controls-overlay)").matches)) ||
           navigator.standalone === true;
  }
  function dismissed() { try { return localStorage.getItem(KEY) === "1"; } catch (e) { return false; } }
  function remember() { try { localStorage.setItem(KEY, "1"); } catch (e) { /* private browsing: asked again next time */ } }
  function name() {
    var meta = document.querySelector('meta[name="application-name"]');
    return (meta && meta.getAttribute("content")) || document.title || "LibreChat";
  }
  function el(tag, style, text) {
    var e = document.createElement(tag);
    if (style) e.style.cssText = style;
    if (text) e.textContent = text;
    if (tag === "button") e.type = "button";
    return e;
  }

  var deferred = null, banner = null;
  function env() {
    return { standalone: standalone(), dismissed: dismissed(), canPrompt: !!deferred,
             userAgent: navigator.userAgent, touchPoints: navigator.maxTouchPoints || 0 };
  }
  function hide() { if (banner) { banner.remove(); banner = null; } }
  function show() {
    var what = offer(env());
    if (!what || banner || !document.body) return;
    banner = el("div", "position:fixed;left:50%;top:calc(env(safe-area-inset-top) + 10px);transform:translateX(-50%);" +
                       "z-index:2147483000;display:flex;align-items:center;gap:10px;max-width:calc(100% - 24px);" +
                       "box-sizing:border-box;padding:8px 8px 8px 14px;border-radius:18px;background:rgba(23,23,23,.96);" +
                       "color:#fff;font:14px/1.35 system-ui,sans-serif;box-shadow:0 4px 18px rgba(0,0,0,.35)");
    banner.id = "hermes-app-offer";
    banner.setAttribute("role", "status");
    var text = el("div", "flex:1;min-width:0");
    var title = el("div", "font-weight:600", T.app.replace("{name}", name()));
    text.appendChild(title);
    if (what === "ios" || what === "mac") {
      var steps = el("div", "opacity:.85;font-size:13px");
      steps.innerHTML = (what === "ios" ? T.ios : T.mac).replace("{share}", SHARE);
      text.appendChild(steps);
    }
    banner.appendChild(text);
    if (what === "prompt") {
      var install = el("button", "border:0;border-radius:999px;padding:7px 14px;background:#10a37f;color:#fff;" +
                                 "font:600 14px system-ui,sans-serif;cursor:pointer;flex:none", T.install);
      install.addEventListener("click", function () {
        var e = deferred;
        deferred = null;
        hide();
        if (!e) return;
        e.prompt();
        if (e.userChoice && e.userChoice.then) e.userChoice.then(function () { /* the browser's dialog has the answer */ });
      });
      banner.appendChild(install);
    }
    var close = el("button", "border:0;background:none;color:#fff;opacity:.7;font:18px/1 system-ui,sans-serif;" +
                              "padding:6px 8px;cursor:pointer;flex:none", "✕");
    close.setAttribute("aria-label", T.close);
    close.addEventListener("click", function () { remember(); hide(); });
    banner.appendChild(close);
    document.body.appendChild(banner);
  }

  // Chrome and Edge say when they would install; the event waits for the button.
  window.addEventListener("beforeinstallprompt", function (e) {
    e.preventDefault();
    deferred = e;
    show();
  });
  window.addEventListener("appinstalled", function () { deferred = null; hide(); });
  setTimeout(show, SHOW_AFTER_MS);
})();
