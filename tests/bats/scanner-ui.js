/*
 * The scanner's screen, driven through once without a browser (librechat.bats):
 * a small stand-in for the DOM, a camera that is 1920 x 1080, and a worker that
 * answers as told — so every path through the screen runs: a shot with one
 * sheet and with two, a new document, a shot without a sheet through the
 * corners, a page opened, turned, filtered, cropped, moved, taken again and
 * deleted, and "Done" handing two PDFs to LibreChat's file input. Pictures are
 * not looked at here; the worker's own tests do that with the real OpenCV.
 *
 * node scanner-ui.js <scan.js>   — exits non-zero with the step that failed
 */
"use strict";
const fs = require("fs"), vm = require("vm");

const { Ev, El } = require("./fake-dom.js");

// --- the worker, answering as told ---------------------------------------------------
let sheets = 1;                                  // how many sheets the next frames hold
function quads(w, h) {
  const one = (x0, x1) => ({ topLeftCorner: { x: x0 * w, y: 0.2 * h }, topRightCorner: { x: x1 * w, y: 0.2 * h },
                             bottomRightCorner: { x: x1 * w, y: 0.8 * h }, bottomLeftCorner: { x: x0 * w, y: 0.8 * h } });
  return sheets === 2 ? [one(0.55, 0.9), one(0.1, 0.45)] : sheets === 1 ? [one(0.2, 0.8)] : [];
}
const asked = [];
class FakeWorker {
  constructor(url) { this.url = url; setTimeout(() => this.onmessage({ data: { type: "ready" } }), 5); }
  postMessage(m) {
    asked.push(m.type === "extract" ? m.type + ":" + m.filter + ":" + m.cuts.length : m.type + ":" + m.image.width);
    setTimeout(() => this.onmessage({ data: m.type === "detect"
      ? { id: m.id, pages: quads(m.image.width, m.image.height) }
      : { id: m.id, images: m.cuts.map((c) => ({ data: new Uint8ClampedArray(c.width * c.height * 4), width: c.width, height: c.height })) } }), 2);
  }
  terminate() {}
}

// --- the page LibreChat would be ------------------------------------------------------
const html = new El("html"), body = html.appendChild(new El("body"));
const composer = body.appendChild(new El("div"));
const attach = composer.appendChild(new El("button")); attach.attrs.id = "attach-file-menu-button"; attach.className = "btn";
const input = composer.appendChild(new El("input")); input.attrs.type = "file";
const changes = [];
input.addEventListener("change", () => changes.push(input.files.map((f) => f.name)));
let urls = 0, alerted = 0;
const window_ = {
  document: {
    currentScript: { src: "https://chat.example.com/hermes-scan/scan.js?v=abc123" }, body, documentElement: html,
    createElement: (t) => new El(t),
    getElementById: (id) => [html].concat(html.all()).find((e) => e.attrs.id === id || e.id === id) || null,
  },
  navigator: { language: "de-CH", mediaDevices: { getUserMedia: () => Promise.resolve({ getTracks: () => [{ stop() {} }] }) } },
  devicePixelRatio: 2, console, setTimeout, clearTimeout,
  HTMLDialogElement: function () {}, Worker: FakeWorker, Event: Ev,
  MutationObserver: class { observe() {} },
  requestAnimationFrame: (f) => setTimeout(f, 0),
  ImageData: class { constructor(data, w, h) { this.data = data; this.width = w; this.height = h; } },
  DataTransfer: class { constructor() { this.files = []; this.items = { add: (f) => this.files.push(f) }; } },
  File: class { constructor(parts, name, o) { this.name = name; this.type = o.type; this.size = parts[0].length; } },
  URL: { createObjectURL: () => "blob:" + ++urls, revokeObjectURL: () => {} },
  createImageBitmap: (b) => Promise.resolve({ width: b.w, height: b.h, close() {} }),
  Image: class {},
  alert: () => { alerted++; },
  addEventListener() {}, removeEventListener() {},
};
window_.window = window_;

// --- driving it -------------------------------------------------------------------------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let step = "loading the script";
function fail(msg) { console.error("FAIL at " + step + ": " + msg); process.exit(1); }
process.on("uncaughtException", (e) => fail("uncaught " + (e && e.stack || e)));
process.on("unhandledRejection", (e) => fail("unhandled rejection " + (e && e.stack || e)));
function expect(cond, msg) { if (!cond) fail(msg); }
async function until(cond, what, ms) {           // the screen's own pace: detection runs every 150 ms
  for (const end = Date.now() + (ms || 3000); Date.now() < end; await sleep(20)) if (cond()) return;
  fail("waited in vain for " + what);
}
const $ = (id) => window_.document.getElementById(id);
const byText = (root, text) => root.all().find((e) => e.tagName === "BUTTON" && e.textContent.includes(text));
const shown = (e) => e.style.display !== "none";

vm.createContext(window_);
vm.runInContext(fs.readFileSync(process.argv[2], "utf8"), window_, { filename: "scan.js" });

(async () => {
  step = "the button next to the paperclip";
  const scanButton = $("hermes-scan-button");
  expect(scanButton && scanButton.previousElementSibling === attach, "no scan button after the paperclip");
  scanButton.click();
  const root = $("hermes-scanner");
  expect(root && root.open, "the scanner did not open as a modal dialog");
  const video = root.all().find((e) => e.tagName === "VIDEO");
  const hint = root.all().find((e) => e.tagName === "DIV" && /Kamera/.test(e.text));
  const shoot = root.all().find((e) => e.attrs["aria-label"] === "Aufnehmen");
  const done = byText(root, "Fertig");
  expect(video && hint && shoot && done, "the camera screen is incomplete");
  expect(shoot.disabled, "capture must wait for the camera");

  step = "the camera starts";
  await sleep(20);
  video.videoWidth = 1920; video.videoHeight = 1080;
  video.dispatchEvent(new Ev("loadedmetadata"));
  expect(!shoot.disabled, "capture not enabled once the camera runs");
  await until(() => hint.text === "Seite erkannt", "a page detected, hint: " + hint.text);

  const pages = () => root.all().filter((e) => e.tagName === "BUTTON" && (e.attrs["aria-label"] || "").startsWith("Seite "));
  step = "a shot with one sheet";
  shoot.click();
  await until(() => pages().length === 1, "one page");
  expect(asked.includes("detect:960"), "the shot was not measured again at 960: " + asked.join(" "));
  expect(asked.includes("extract:colour:1"), "no single cut: " + asked.join(" "));
  expect(done.textContent === "Fertig (1)" && !done.disabled, "done: " + done.textContent);

  step = "a shot with two sheets";
  sheets = 2;
  await until(() => hint.text === "2 Blätter erkannt", "two sheets detected");
  shoot.click();
  await until(() => pages().length === 3, "three pages");
  expect(asked.includes("extract:colour:2"), "the two sheets were not cut from one shot: " + asked.join(" "));

  step = "a new document";
  byText(root, "Neues Dokument").click();
  expect(root.all().some((e) => e.text === "PDF 2"), "no second document in the strip");
  sheets = 0;
  await until(() => hint.text === "Nächste Aufnahme: neues PDF", "the sheets forgotten, hint: " + hint.text);
  step = "a shot without a sheet, by the corners";
  shoot.click();
  const use = byText(root, "Übernehmen");
  await until(() => shown(use.parentElement) && !shown(shoot.parentElement), "the corners");
  use.click();
  await until(() => pages().length === 4, "a fourth page");
  expect(done.textContent === "Fertig · 2 PDFs", "done: " + done.textContent);

  step = "a page opened";
  pages()[0].click();
  expect(hint.text === "PDF 1 · Seite 1 von 3", "hint: " + hint.text);
  const tool = (word) => root.all().find((e) => e.tagName === "BUTTON" && e.children.some((c) => c.text === word));
  step = "turned";
  tool("Drehen").click();
  await until(() => hint.text === "PDF 1 · Seite 1 von 3", "the page turned");
  step = "filtered";
  tool("Farbe").click();
  await until(() => tool("Dokument"), "the Document filter");
  expect(asked.includes("extract:document:1"), "the filter did not cut again as a document");
  step = "cropped";
  tool("Zuschneiden").click();
  await until(() => shown(use.parentElement), "the corners of the page");
  use.click();
  await until(() => hint.text === "PDF 1 · Seite 1 von 3", "the page cut again");
  step = "moved later";
  tool("Nach hinten").click();
  expect(hint.text === "PDF 1 · Seite 2 von 3", "after moving: " + hint.text);
  step = "taken again";
  byText(root, "Neu aufnehmen").click();
  const chip = root.all().find((e) => e.tagName === "BUTTON" && /Ersetzt Seite 2/.test(e.text));
  expect(chip && shown(chip), "no chip for the page taken again");
  sheets = 1;
  await until(() => hint.text === "Seite erkannt", "the page in view again");
  const was = pages()[1].children[0].src;
  shoot.click();
  await until(() => pages()[1].children[0].src !== was && !shown(chip), "the second page replaced");
  expect(pages().length === 4, "after taking it again: " + pages().length);
  step = "deleted";
  pages()[3].click();
  byText(root, "Löschen").click();
  expect(pages().length === 3, "after deleting: " + pages().length);
  expect(done.textContent === "Fertig (3)", "one document is left: " + done.textContent);

  step = "Escape steps back";
  pages()[0].click();
  root.dispatchEvent(new Ev("keydown", { key: "Escape", bubbles: true }));
  expect(shown(shoot.parentElement) && $("hermes-scanner"), "Escape did not go back to the camera");

  step = "done: the PDFs into LibreChat's input";
  byText(root, "Neues Dokument").click();
  shoot.click();
  await until(() => done.textContent === "Fertig · 2 PDFs", "a second document, done: " + done.textContent);
  done.click();
  await until(() => !$("hermes-scanner"), "the scanner closed");
  expect(!$("hermes-scanner"), "the scanner did not close");
  expect(changes.length === 1 && changes[0].length === 2, "files handed over: " + JSON.stringify(changes));
  expect(/^Scan \d{4}-\d\d-\d\d \d\d-\d\d \(1\)\.pdf$/.test(changes[0][0]) && / \(2\)\.pdf$/.test(changes[0][1]), "names: " + changes[0]);
  expect(!alerted, "it fell back to a download");
  process.exit(0);
})();
