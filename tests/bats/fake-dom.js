/*
 * A stand-in for the few parts of the DOM the web chat's scripts touch, for
 * driving them under Node (scanner-ui.js, app-ui.js): elements with styles,
 * attributes, children and events, a canvas that draws nothing, and blobs
 * that remember their size. Nothing is rendered.
 */
"use strict";

class Ev {
  constructor(type, init) { this.type = type; this.bubbles = !!(init && init.bubbles); this.key = init && init.key; }
  stopPropagation() { this.stopped = true; }
  preventDefault() { this.defaultPrevented = true; }
}
class Ctx {
  constructor(canvas) { this.canvas = canvas; }
  getImageData(x, y, w, h) { return { data: new Uint8ClampedArray(w * h * 4), width: w, height: h }; }
}
for (const m of ["setTransform", "clearRect", "beginPath", "moveTo", "lineTo", "closePath", "fill", "stroke", "rect",
                 "arc", "save", "restore", "clip", "fillRect", "drawImage", "translate", "rotate", "putImageData"]) {
  Ctx.prototype[m] = function () {};
}
class Style {                                    // display, as the last word of cssText says
  set cssText(v) {
    this.css = v;
    const all = [...v.matchAll(/(?:^|;)\s*display\s*:\s*([^;]+)/g)];
    if (all.length) this.display = all[all.length - 1][1].trim();
  }
  get cssText() { return this.css || ""; }
}
class Blob_ { constructor(w, h) { this.w = w; this.h = h; } arrayBuffer() { return Promise.resolve(new ArrayBuffer(16)); } }
class El {
  constructor(tag) {
    this.tagName = tag.toUpperCase(); this.children = []; this.parentElement = null; this.style = new Style();
    this.attrs = {}; this.on = {}; this.text = ""; this.width = 300; this.height = 150; this.disabled = false;
  }
  set textContent(v) { this.text = String(v); this.children.forEach((c) => { c.parentElement = null; }); this.children = []; }
  get textContent() { return this.text + this.children.map((c) => c.textContent).join(""); }
  set innerHTML(v) { this.html = v; }
  appendChild(c) { if (c.parentElement) c.remove(); c.parentElement = this; this.children.push(c); return c; }
  remove() { const p = this.parentElement; if (p) { p.children = p.children.filter((x) => x !== this); this.parentElement = null; } }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  hasAttribute(k) { return k in this.attrs; }
  removeAttribute(k) { delete this.attrs[k]; }
  addEventListener(t, f) { (this.on[t] = this.on[t] || []).push(f); }
  removeEventListener(t, f) { this.on[t] = (this.on[t] || []).filter((x) => x !== f); }
  dispatchEvent(e) {
    e.target = e.target || this;
    for (let n = this; n && !e.stopped; n = e.bubbles ? n.parentElement : null) (n.on[e.type] || []).forEach((f) => f.call(n, e));
    return !e.defaultPrevented;
  }
  click() { if (!this.disabled) this.dispatchEvent(new Ev("click", { bubbles: true })); }
  get previousElementSibling() { const p = this.parentElement; const i = p ? p.children.indexOf(this) : -1; return i > 0 ? p.children[i - 1] : null; }
  insertAdjacentElement(where, e) {
    const p = this.parentElement; if (e.parentElement) e.remove();
    p.children.splice(p.children.indexOf(this) + 1, 0, e); e.parentElement = p; return e;
  }
  all() { return this.children.reduce((a, c) => a.concat([c], c.all()), []); }
  querySelector(sel) {
    return this.all().find((e) => sel === 'input[type="file"]' ? e.tagName === "INPUT" && e.attrs.type === "file" : false) || null;
  }
  get clientWidth() { return 400; }
  get clientHeight() { return 700; }
  getBoundingClientRect() { return { left: 0, top: 0, width: 400, height: 700 }; }
  getContext() { return this.ctx || (this.ctx = new Ctx(this)); }
  toBlob(cb) { setTimeout(() => cb(new Blob_(this.width, this.height)), 0); }
  setPointerCapture() {}
  animate() {}
  showModal() { this.open = true; }
  close() { this.open = false; }
  play() { return Promise.resolve(); }
}

// an element's id is set as a property by the scripts; look it up as an attribute too
Object.defineProperty(El.prototype, "id", { get() { return this.attrs.id || ""; }, set(v) { this.attrs.id = v; } });

module.exports = { Ev, Style, Ctx, Blob_, El };
