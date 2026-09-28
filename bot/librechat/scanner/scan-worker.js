/*
 * The scanner's image work, off the page's thread (ADR 0029).
 *
 * OpenCV.js is nine megabytes of WebAssembly. Started on the page it holds the
 * thread while it compiles, and it takes over a global `Module` the page may
 * already have (LibreChat's HEIC converter is such a build). In a worker
 * neither matters: the page stays responsive and the worker has a global scope
 * of its own.
 *
 * Finding the page: one pass cannot see a white letter on a light desk, through
 * a wood grain, over its folds and under a soft shadow all at once, so several
 * look at the same frame — edges at three sensitivities with their gaps closed,
 * seven brightness levels, and, when none of them sees a page, the colour
 * saturation (paper has none; a desk often has). Text and folds are taken out
 * first: a closing removes dark detail narrower than its kernel and keeps the
 * page's outline. Every outline found is simplified, and only a convex
 * quadrilateral counts — corners between 60° and 120°, at least 12% of the
 * frame, not touching its border (a page cut by the border has no corner
 * there). The largest wins.
 *
 * Messages in:  {id, type: "detect",  image: {data, width, height}}
 *               {id, type: "extract", image, corners, width, height}
 * Messages out: {type: "ready"} | {type: "error", message}
 *               {id, corners | null} | {id, image} | {id, error}
 *
 * findCorners and warp are exported for the tests when loaded under Node.
 */
(function () {
  "use strict";

  var MIN_PAGE_SHARE = 0.12;   // smaller than this share of the frame is not the page
  var MAX_PAGE_SHARE = 0.95;   // larger is the frame itself
  var MAX_COSINE = 0.5;        // corners between 60° and 120°: a page seen at an angle
  var BORDER = 2;              // pixels; a corner this close to the frame's edge is cut off
  var CLOSING = 9;             // pixels; dark detail narrower than this goes (text, folds)
  var CANNY = [[10, 30], [25, 75], [50, 150]];
  var LEVELS = 8;              // brightness thresholds at 1/8 … 7/8

  /** TL, TR, BR, BL: around their centre, starting top left (as scan.js orders them). */
  function orderCorners(points) {
    var cx = 0, cy = 0;
    points.forEach(function (p) { cx += p.x / 4; cy += p.y / 4; });
    var p = points.slice().sort(function (a, b) { return Math.atan2(a.y - cy, a.x - cx) - Math.atan2(b.y - cy, b.x - cx); });
    var first = 0;
    p.forEach(function (q, i) { if (q.x + q.y < p[first].x + p[first].y) first = i; });
    p = p.slice(first).concat(p.slice(0, first));
    return { topLeftCorner: p[0], topRightCorner: p[1], bottomRightCorner: p[2], bottomLeftCorner: p[3] };
  }

  function maxCosine(p) {
    var worst = 0;
    for (var k = 0; k < 4; k++) {
      var a = p[(k + 3) % 4], b = p[k], c = p[(k + 1) % 4];
      var x1 = a.x - b.x, y1 = a.y - b.y, x2 = c.x - b.x, y2 = c.y - b.y;
      var cos = Math.abs((x1 * x2 + y1 * y2) / Math.sqrt((x1 * x1 + y1 * y1) * (x2 * x2 + y2 * y2) + 1e-10));
      if (cos > worst) worst = cos;
    }
    return worst;
  }

  /** Every outline in a binary image that simplifies to a plausible page, into `found`. */
  function collectQuads(cv, binary, width, height, found) {
    var contours = new cv.MatVector(), hierarchy = new cv.Mat();
    try {
      cv.findContours(binary, contours, hierarchy, cv.RETR_LIST, cv.CHAIN_APPROX_SIMPLE);
      for (var i = 0; i < contours.size(); i++) {
        var contour = contours.get(i), approx = null;
        try {
          if (Math.abs(cv.contourArea(contour)) < MIN_PAGE_SHARE * width * height) continue;
          approx = new cv.Mat();
          cv.approxPolyDP(contour, approx, 0.02 * cv.arcLength(contour, true), true);
          if (approx.rows !== 4 || !cv.isContourConvex(approx)) continue;
          var p = [];
          for (var k = 0; k < 4; k++) p.push({ x: approx.data32S[2 * k], y: approx.data32S[2 * k + 1] });
          var cut = p.some(function (q) {
            return q.x < BORDER || q.y < BORDER || q.x > width - 1 - BORDER || q.y > height - 1 - BORDER;
          });
          var area = Math.abs(cv.contourArea(approx));
          if (!cut && area <= MAX_PAGE_SHARE * width * height && maxCosine(p) < MAX_COSINE) found.push({ area: area, corners: p });
        } finally {
          contour.delete();
          if (approx) approx.delete();
        }
      }
    } finally {
      contours.delete(); hierarchy.delete();
    }
  }

  function edgePasses(cv, smooth, binary, grow, width, height, found) {
    CANNY.forEach(function (t) {
      cv.Canny(smooth, binary, t[0], t[1]);
      cv.dilate(binary, binary, grow, new cv.Point(-1, -1), 2);      // close the outline's gaps
      collectQuads(cv, binary, width, height, found);
    });
  }

  /** The page's four corners in the image's pixels, or null. */
  function findCorners(cv, image) {
    var width = image.width, height = image.height, found = [];
    var rgba = cv.matFromImageData(image), gray = new cv.Mat(), smooth = new cv.Mat(), binary = new cv.Mat();
    var closing = cv.getStructuringElement(cv.MORPH_RECT, new cv.Size(CLOSING, CLOSING));
    var grow = cv.getStructuringElement(cv.MORPH_RECT, new cv.Size(3, 3));
    try {
      cv.cvtColor(rgba, gray, cv.COLOR_RGBA2GRAY);
      cv.morphologyEx(gray, gray, cv.MORPH_CLOSE, closing);
      cv.GaussianBlur(gray, smooth, new cv.Size(5, 5), 0);
      edgePasses(cv, smooth, binary, grow, width, height, found);
      for (var l = 1; l < LEVELS; l++) {
        cv.threshold(smooth, binary, (l * 255) / LEVELS, 255, cv.THRESH_BINARY);
        collectQuads(cv, binary, width, height, found);
      }
      if (!found.length) {
        var rgb = new cv.Mat(), hsv = new cv.Mat(), planes = new cv.MatVector(), saturation = null;
        try {
          cv.cvtColor(rgba, rgb, cv.COLOR_RGBA2RGB);
          cv.cvtColor(rgb, hsv, cv.COLOR_RGB2HSV);
          cv.split(hsv, planes);
          saturation = planes.get(1);
          cv.GaussianBlur(saturation, smooth, new cv.Size(5, 5), 0);
          cv.threshold(smooth, binary, 0, 255, cv.THRESH_BINARY_INV + cv.THRESH_OTSU);   // colourless = paper
          collectQuads(cv, binary, width, height, found);
          edgePasses(cv, smooth, binary, grow, width, height, found);
        } finally {
          [rgb, hsv, planes].forEach(function (m) { m.delete(); });
          if (saturation) saturation.delete();
        }
      }
      if (!found.length) return null;
      found.sort(function (a, b) { return b.area - a.area; });
      return orderCorners(found[0].corners);
    } finally {
      [rgba, gray, smooth, binary, closing, grow].forEach(function (m) { m.delete(); });
    }
  }

  /** The quadrilateral straightened into a width x height RGBA image. */
  function warp(cv, image, c, width, height) {
    var src = cv.matFromImageData(image), dst = new cv.Mat();
    var from = cv.matFromArray(4, 1, cv.CV_32FC2, [
      c.topLeftCorner.x, c.topLeftCorner.y, c.topRightCorner.x, c.topRightCorner.y,
      c.bottomLeftCorner.x, c.bottomLeftCorner.y, c.bottomRightCorner.x, c.bottomRightCorner.y]);
    var to = cv.matFromArray(4, 1, cv.CV_32FC2, [0, 0, width, 0, 0, height, width, height]);
    var m = cv.getPerspectiveTransform(from, to);
    try {
      cv.warpPerspective(src, dst, m, new cv.Size(width, height), cv.INTER_LINEAR, cv.BORDER_REPLICATE, new cv.Scalar());
      return { data: new Uint8ClampedArray(dst.data), width: width, height: height };
    } finally {
      [src, dst, from, to, m].forEach(function (x) { x.delete(); });
    }
  }

  if (typeof module === "object" && module.exports) {
    module.exports = { findCorners: findCorners, warp: warp, orderCorners: orderCorners };
    return;
  }

  // --- in the worker ----------------------------------------------------------
  var query = self.location.search || "";
  var cv = null;

  function fail(e) {
    self.postMessage({ type: "error", message: String((e && e.message) || e) });
  }

  // OpenCV's module is a thenable whose then() calls back with the module
  // itself: a promise resolved with it resolves again and again, and the thread
  // never gets back to its events. So it is polled here and never handed to a
  // promise — the page's first scanner froze on exactly that.
  function whenStarted(done) {
    var started = Date.now();
    (function poll() {
      var c = self.cv;
      if (c && typeof c.Mat === "function" && typeof c.matFromImageData === "function") return done(c);
      if (Date.now() - started > 90000) return fail("OpenCV did not start within 90 s");
      setTimeout(poll, 50);
    })();
  }

  try {
    self.importScripts("opencv.js" + query);
  } catch (e) {
    fail("could not load OpenCV: " + ((e && e.message) || e));
    return;
  }
  whenStarted(function (c) {
    cv = c;
    self.postMessage({ type: "ready" });
  });

  self.onmessage = function (e) {
    var msg = e.data || {};
    if (!cv) { self.postMessage({ id: msg.id, error: "not ready" }); return; }
    try {
      if (msg.type === "detect") {
        self.postMessage({ id: msg.id, corners: findCorners(cv, msg.image) });
      } else if (msg.type === "extract") {
        var out = warp(cv, msg.image, msg.corners, msg.width, msg.height);
        self.postMessage({ id: msg.id, image: out }, [out.data.buffer]);
      }
    } catch (err) {
      self.postMessage({ id: msg.id, error: String((err && err.message) || err) });
    }
  };
})();
