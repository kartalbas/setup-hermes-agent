/*
 * The web chat's install button, driven through without a browser
 * (librechat.bats): what it offers on which browser, and the button itself in
 * Chrome (the browser's own dialog) and on the iPhone (the two steps), gone
 * once dismissed, and never shown in the app itself.
 *
 * node app-ui.js <app.js>   — exits non-zero with the case that failed
 */
"use strict";
const fs = require("fs"), vm = require("vm");
const { Ev, El } = require("./fake-dom.js");

const file = process.argv[2];
const { offer } = require(file);
let step = "offer()";
function fail(msg) { console.error("FAIL at " + step + ": " + msg); process.exit(1); }
process.on("uncaughtException", (e) => fail("uncaught " + (e && e.stack || e)));
process.on("unhandledRejection", (e) => fail("unhandled rejection " + (e && e.stack || e)));
function expect(cond, msg) { if (!cond) fail(msg); }

const CHROME_WIN = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36";
const EDGE_WIN = CHROME_WIN + " Edg/140.0";
const IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1";
const IPHONE_CHROME = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/140.0 Mobile/15E148 Safari/604.1";
const MAC_SAFARI = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15";
const MAC_CHROME = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36";
const FIREFOX = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:143.0) Gecko/20100101 Firefox/143.0";
const env = (o) => Object.assign({ standalone: false, dismissed: false, canPrompt: false, userAgent: CHROME_WIN, touchPoints: 0 }, o);
for (const [what, want, got] of [
  ["Chrome, once it offers", "prompt", offer(env({ canPrompt: true }))],
  ["Edge, once it offers", "prompt", offer(env({ canPrompt: true, userAgent: EDGE_WIN }))],
  ["Chrome, before it offers", null, offer(env())],
  ["Safari on the iPhone", "ios", offer(env({ userAgent: IPHONE }))],
  ["Chrome on the iPhone", "ios", offer(env({ userAgent: IPHONE_CHROME }))],
  ["an iPad that asks for the desktop site", "ios", offer(env({ userAgent: MAC_SAFARI, touchPoints: 5 }))],
  ["Safari on the Mac", "mac", offer(env({ userAgent: MAC_SAFARI }))],
  ["Chrome on the Mac, before it offers", null, offer(env({ userAgent: MAC_CHROME }))],
  ["Firefox", null, offer(env({ userAgent: FIREFOX }))],
  ["in the app itself", null, offer(env({ standalone: true, canPrompt: true, userAgent: IPHONE }))],
  ["once dismissed", null, offer(env({ dismissed: true, userAgent: IPHONE }))],
]) expect(got === want, `${what}: ${got} instead of ${want}`);

/** The script on a page of its own; returns what the test needs to drive it. */
function load(userAgent, { standalone = false, storage = {} } = {}) {
  const html = new El("html"), body = html.appendChild(new El("body"));
  const handlers = {}, timers = [];
  const meta = new El("meta"); meta.attrs.content = "Acme Chat";
  const win = {
    document: {
      body, documentElement: html, title: "LibreChat", createElement: (t) => new El(t),
      querySelector: (sel) => (sel === 'meta[name="application-name"]' ? meta : null),
    },
    navigator: { userAgent, language: "de-CH", maxTouchPoints: 0, standalone: standalone || undefined },
    matchMedia: (q) => ({ matches: standalone && /standalone/.test(q) }),
    localStorage: { getItem: (k) => (k in storage ? storage[k] : null), setItem: (k, v) => { storage[k] = String(v); } },
    addEventListener: (t, f) => { (handlers[t] = handlers[t] || []).push(f); },
    setTimeout: (f) => { timers.push(f); }, console,
  };
  win.window = win;
  vm.createContext(win);
  vm.runInContext(fs.readFileSync(file, "utf8"), win, { filename: "app.js" });
  const banner = () => html.all().find((e) => e.attrs.id === "hermes-app-offer") || null;
  return {
    banner, storage,
    later: () => timers.splice(0).forEach((f) => f()),                  // the delay has passed
    fire: (type, e) => (handlers[type] || []).forEach((f) => f(e)),
    button: (text) => (banner() ? banner().all().find((e) => e.tagName === "BUTTON" && e.textContent === text) : null),
  };
}

(async () => {
  step = "Chrome: the browser's own dialog";
  const chrome = load(CHROME_WIN);
  chrome.later();
  expect(!chrome.banner(), "a button before Chrome offers to install");
  let prompted = 0, prevented = 0;
  chrome.fire("beforeinstallprompt", { preventDefault: () => prevented++, prompt: () => prompted++,
                                        userChoice: Promise.resolve({ outcome: "accepted" }) });
  expect(prevented === 1 && chrome.banner(), "no button once Chrome offers");
  expect(chrome.banner().textContent.includes("Acme Chat als App"), "not the chat's name: " + chrome.banner().textContent);
  chrome.button("Installieren").click();
  expect(prompted === 1 && !chrome.banner(), "the button did not open the browser's dialog");

  step = "Chrome: installed from the address bar instead";
  const other = load(CHROME_WIN);
  other.fire("beforeinstallprompt", { preventDefault() {}, prompt() {} });
  other.fire("appinstalled", {});
  expect(!other.banner(), "the button stayed after the app was installed");

  step = "iPhone: the two steps, then gone for good";
  const storage = {};
  const phone = load(IPHONE, { storage });
  expect(!phone.banner(), "shown before the delay");
  phone.later();
  const text = phone.banner() && phone.banner().textContent;
  expect(text && text.includes("Acme Chat als App"), "no button on the iPhone");
  const steps = phone.banner().all().find((e) => e.html && e.html.includes("Zum Home-Bildschirm"));
  expect(steps && steps.html.includes("<svg"), "the steps or the share icon are missing");
  expect(!phone.button("Installieren"), "an install button Safari cannot honour");
  phone.banner().all().find((e) => e.attrs["aria-label"] === "Schliessen").click();
  expect(!phone.banner() && storage["hermes-app-dismissed"] === "1", "not dismissed for good");
  const again = load(IPHONE, { storage });
  again.later();
  expect(!again.banner(), "back after it was dismissed");

  step = "in the app itself";
  const app = load(IPHONE, { standalone: true });
  app.later();
  app.fire("beforeinstallprompt", { preventDefault() {}, prompt() {} });
  expect(!app.banner(), "a button inside the installed app");

  step = "Firefox";
  const firefox = load(FIREFOX);
  firefox.later();
  expect(!firefox.banner(), "a button Firefox cannot honour");
  process.exit(0);
})();
