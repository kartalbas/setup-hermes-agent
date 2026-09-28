/*
 * The scanner's image work, off the page's thread (ADR 0029).
 *
 * OpenCV.js is nine megabytes of WebAssembly. Started on the page it holds the
 * thread while it compiles, and it takes over a global `Module` the page may
 * already have (LibreChat's HEIC converter is such a build). In a worker
 * neither matters: the page stays responsive and the worker has a global scope
 * of its own.
 *
 * Finding sheets: one pass cannot see a white letter on a light desk, through
 * a wood grain, over its folds and under a soft shadow all at once, so several
 * look at the same frame — edges at three sensitivities with their gaps closed,
 * seven brightness levels, and, when none of them sees a sheet, the colour
 * saturation (paper has none; a desk often has). Text and folds are taken out
 * first: a closing removes dark detail narrower than its kernel and keeps the
 * sheet's outline. Every outline found is simplified, and only a convex
 * quadrilateral counts — corners between 60° and 120°, not touching the
 * frame's border (a sheet cut by the border has no corner there). The largest
 * is the page; beside it, every further sheet that lies inside none of the
 * others and is brighter than its surroundings, as paper is on a desk — three
 * receipts side by side are three sheets, the letterhead inside a letter is
 * none. A small sheet has to look like paper even alone.
 *
 * Sizes are for a frame 480 pixels wide, the live preview's; a larger one — the
 * shot measured again at twice that — scales them.
 *
 * Messages in:  {id, type: "detect",  image: {data, width, height}}
 *               {id, type: "extract", image, cuts: [{corners, width, height}], filter}
 * Messages out: {type: "ready"} | {type: "error", message}
 *               {id, pages: [corners]} | {id, images: [{data, width, height}]} | {id, error}
 *
 * The finding, cutting and whitening are exported for the tests under Node.
 */
(function () {
  "use strict";

  var PAGE_SHARE = 0.12;       // a sheet this large is a page by its shape alone
  var SHEET_SHARE = 0.04;      // down to this, a sheet must also look like paper
  var MAX_SHARE = 0.95;        // larger is the frame itself
  var MAX_COSINE = 0.5;        // corners between 60° and 120°: a sheet seen at an angle
  var PAPER_CONTRAST = 10;     // grey levels a sheet is brighter than the band around it
  var CANNY = [[10, 30], [25, 75], [50, 150]];
  var LEVELS = 8;              // brightness thresholds at 1/8 … 7/8
  var BORDER = 2;              // a corner this close to the frame's edge is cut off
  var CLOSING = 9;             // dark detail narrower than this goes (text, folds)
  var BLUR = 5;
  var GROW = 2;                // dilations that close an outline's gaps

  function odd(n) { n = Math.max(1, Math.round(n)); return n % 2 ? n : n + 1; }

  /** TL, TR, BR, BL: around their centre, starting top left (as scan.js orders them). */
  function orderCorners(points) {
    var c = centroid(points);
    var p = points.slice().sort(function (a, b) { return Math.atan2(a.y - c.y, a.x - c.x) - Math.atan2(b.y - c.y, b.x - c.x); });
    var first = 0;
    p.forEach(function (q, i) { if (q.x + q.y < p[first].x + p[first].y) first = i; });
    p = p.slice(first).concat(p.slice(0, first));
    return { topLeftCorner: p[0], topRightCorner: p[1], bottomRightCorner: p[2], bottomLeftCorner: p[3] };
  }

  function centroid(p) {
    var x = 0, y = 0;
    p.forEach(function (q) { x += q.x / p.length; y += q.y / p.length; });
    return { x: x, y: y };
  }

  /** Is the point inside the convex quadrilateral (either winding)? */
  function inside(q, p) {
    var sign = 0;
    for (var k = 0; k < 4; k++) {
      var a = p[k], b = p[(k + 1) % 4], cross = (b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x);
      if (cross === 0) continue;
      if (sign && (cross > 0) !== (sign > 0)) return false;
      sign = cross;
    }
    return true;
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

  /** Every outline in a binary image that simplifies to a plausible sheet, into `found`. */
  function collectQuads(cv, binary, width, height, border, found) {
    var contours = new cv.MatVector(), hierarchy = new cv.Mat();
    try {
      cv.findContours(binary, contours, hierarchy, cv.RETR_LIST, cv.CHAIN_APPROX_SIMPLE);
      for (var i = 0; i < contours.size(); i++) {
        var contour = contours.get(i), approx = null;
        try {
          if (Math.abs(cv.contourArea(contour)) < SHEET_SHARE * width * height) continue;
          approx = new cv.Mat();
          cv.approxPolyDP(contour, approx, 0.02 * cv.arcLength(contour, true), true);
          if (approx.rows !== 4 || !cv.isContourConvex(approx)) continue;
          var p = [];
          for (var k = 0; k < 4; k++) p.push({ x: approx.data32S[2 * k], y: approx.data32S[2 * k + 1] });
          var cut = p.some(function (q) {
            return q.x < border || q.y < border || q.x > width - 1 - border || q.y > height - 1 - border;
          });
          var area = Math.abs(cv.contourArea(approx));
          if (!cut && area <= MAX_SHARE * width * height && maxCosine(p) < MAX_COSINE) found.push({ area: area, corners: p });
        } finally {
          contour.delete();
          if (approx) approx.delete();
        }
      }
    } finally {
      contours.delete(); hierarchy.delete();
    }
  }

  // An edge in a frame s times larger is s times wider, its gradient s times
  // flatter: the thresholds come down with it.
  function edgePasses(cv, smooth, binary, grow, iterations, s, width, height, border, found) {
    CANNY.forEach(function (t) {
      cv.Canny(smooth, binary, t[0] / s, t[1] / s);
      cv.dilate(binary, binary, grow, new cv.Point(-1, -1), iterations);   // close the outline's gaps
      collectQuads(cv, binary, width, height, border, found);
    });
  }

  function fill(cv, mask, p) {
    var pts = cv.matFromArray(4, 1, cv.CV_32SC2, [].concat.apply([], p.map(function (q) { return [Math.round(q.x), Math.round(q.y)]; })));
    var polys = new cv.MatVector();
    try {
      polys.push_back(pts);
      cv.fillPoly(mask, polys, new cv.Scalar(255));
    } finally {
      pts.delete(); polys.delete();
    }
  }

  /** How much brighter the quadrilateral is than a band around it. */
  function contrast(cv, grey, p) {
    var c = centroid(p);
    var around = p.map(function (q) { return { x: c.x + (q.x - c.x) * 1.25, y: c.y + (q.y - c.y) * 1.25 }; });
    var inner = cv.Mat.zeros(grey.rows, grey.cols, cv.CV_8UC1), band = cv.Mat.zeros(grey.rows, grey.cols, cv.CV_8UC1);
    try {
      fill(cv, inner, p);
      fill(cv, band, around);
      cv.subtract(band, inner, band);
      if (!cv.countNonZero(band)) return Infinity;           // nothing around it: the frame is the surroundings
      return cv.mean(grey, inner)[0] - cv.mean(grey, band)[0];
    } finally {
      inner.delete(); band.delete();
    }
  }

  /** The page, and every further sheet beside it — largest first. */
  function choose(cv, grey, found, width, height) {
    found.sort(function (a, b) { return b.area - a.area; });
    var sheets = [];
    found.forEach(function (f) {
      var c = centroid(f.corners);
      if (sheets.some(function (s) { return inside(c, s.corners) || inside(centroid(s.corners), f.corners); })) return;
      var page = !sheets.length && f.area >= PAGE_SHARE * width * height;
      if (!page && contrast(cv, grey, f.corners) < PAPER_CONTRAST) return;
      sheets.push(f);
    });
    return sheets.map(function (s) { return orderCorners(s.corners); });
  }

  /** The sheets' corners in the image's pixels, largest first; none is an empty list. */
  function findPages(cv, image) {
    var width = image.width, height = image.height, s = Math.max(1, width / 480), found = [];
    var border = BORDER * s, iterations = Math.round(GROW * s), blur = new cv.Size(odd(BLUR * s), odd(BLUR * s));
    var rgba = cv.matFromImageData(image), grey = new cv.Mat(), smooth = new cv.Mat(), binary = new cv.Mat();
    var closing = cv.getStructuringElement(cv.MORPH_RECT, new cv.Size(odd(CLOSING * s), odd(CLOSING * s)));
    var grow = cv.getStructuringElement(cv.MORPH_RECT, new cv.Size(3, 3));
    try {
      cv.cvtColor(rgba, grey, cv.COLOR_RGBA2GRAY);
      cv.morphologyEx(grey, grey, cv.MORPH_CLOSE, closing);
      cv.GaussianBlur(grey, smooth, blur, 0);
      edgePasses(cv, smooth, binary, grow, iterations, s, width, height, border, found);
      for (var l = 1; l < LEVELS; l++) {
        cv.threshold(smooth, binary, (l * 255) / LEVELS, 255, cv.THRESH_BINARY);
        collectQuads(cv, binary, width, height, border, found);
      }
      if (!found.length) {
        var rgb = new cv.Mat(), hsv = new cv.Mat(), planes = new cv.MatVector(), saturation = null, sat = new cv.Mat();
        try {
          cv.cvtColor(rgba, rgb, cv.COLOR_RGBA2RGB);
          cv.cvtColor(rgb, hsv, cv.COLOR_RGB2HSV);
          cv.split(hsv, planes);
          saturation = planes.get(1);
          cv.GaussianBlur(saturation, sat, blur, 0);
          cv.threshold(sat, binary, 0, 255, cv.THRESH_BINARY_INV + cv.THRESH_OTSU);   // colourless = paper
          collectQuads(cv, binary, width, height, border, found);
          edgePasses(cv, sat, binary, grow, iterations, s, width, height, border, found);
        } finally {
          [rgb, hsv, planes, sat].forEach(function (m) { m.delete(); });
          if (saturation) saturation.delete();
        }
      }
      return choose(cv, smooth, found, width, height);
    } finally {
      [rgba, grey, smooth, binary, closing, grow].forEach(function (m) { m.delete(); });
    }
  }

  /** The page's corners, or null. */
  function findCorners(cv, image) {
    var pages = findPages(cv, image);
    return pages.length ? pages[0] : null;
  }

  /** The quadrilateral straightened into a width x height Mat of the shot's kind. */
  function warpMat(cv, shot, c, width, height) {
    var dst = new cv.Mat();
    var from = cv.matFromArray(4, 1, cv.CV_32FC2, [
      c.topLeftCorner.x, c.topLeftCorner.y, c.topRightCorner.x, c.topRightCorner.y,
      c.bottomLeftCorner.x, c.bottomLeftCorner.y, c.bottomRightCorner.x, c.bottomRightCorner.y]);
    var to = cv.matFromArray(4, 1, cv.CV_32FC2, [0, 0, width, 0, 0, height, width, height]);
    var m = cv.getPerspectiveTransform(from, to);
    try {
      cv.warpPerspective(shot, dst, m, new cv.Size(width, height), cv.INTER_LINEAR, cv.BORDER_REPLICATE, new cv.Scalar());
      return dst;
    } finally {
      [from, to, m].forEach(function (x) { x.delete(); });
    }
  }

  /**
   * "Document": the page divided by its own paper — the page without its ink
   * (dilated, then a wide median) — so the paper is white wherever it lies, in
   * shadow or not, and the ink a little darker than it was. Grey, RGBA Mat.
   */
  function whiten(cv, page) {
    var grey = new cv.Mat(), small = new cv.Mat(), paper = new cv.Mat(), out = new cv.Mat();
    var ink = cv.getStructuringElement(cv.MORPH_RECT, new cv.Size(7, 7));
    try {
      cv.cvtColor(page, grey, cv.COLOR_RGBA2GRAY);
      cv.resize(grey, small, new cv.Size(0, 0), 0.5, 0.5, cv.INTER_AREA);      // the paper changes slowly
      cv.dilate(small, small, ink);
      cv.medianBlur(small, small, 21);
      cv.resize(small, paper, new cv.Size(grey.cols, grey.rows), 0, 0, cv.INTER_LINEAR);
      cv.divide(grey, paper, grey, 255);
      grey.convertTo(grey, -1, 1.4, -0.4 * 255);                                // 255 stays, the ink falls faster
      cv.cvtColor(grey, out, cv.COLOR_GRAY2RGBA);
      return out;
    } finally {
      [grey, small, paper, ink].forEach(function (m) { m.delete(); });
    }
  }

  function imageOf(mat) {
    return { data: new Uint8ClampedArray(mat.data), width: mat.cols, height: mat.rows };
  }

  /** Cut every sheet out of one shot, whitened where asked. */
  function extract(cv, image, cuts, filter) {
    var shot = cv.matFromImageData(image), images = [];
    try {
      cuts.forEach(function (cut) {
        var page = warpMat(cv, shot, cut.corners, cut.width, cut.height);
        try {
          if (filter === "document") { var white = whiten(cv, page); page.delete(); page = white; }
          images.push(imageOf(page));
        } finally {
          page.delete();
        }
      });
      return images;
    } finally {
      shot.delete();
    }
  }

  /** One quadrilateral straightened into a width x height RGBA image (for the tests). */
  function warp(cv, image, c, width, height) {
    return extract(cv, image, [{ corners: c, width: width, height: height }], "colour")[0];
  }

  if (typeof module === "object" && module.exports) {
    module.exports = { findPages: findPages, findCorners: findCorners, warp: warp, extract: extract,
                       orderCorners: orderCorners, inside: inside };
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
        self.postMessage({ id: msg.id, pages: findPages(cv, msg.image) });
      } else if (msg.type === "extract") {
        var images = extract(cv, msg.image, msg.cuts, msg.filter);
        self.postMessage({ id: msg.id, images: images }, images.map(function (i) { return i.data.buffer; }));
      }
    } catch (err) {
      self.postMessage({ id: msg.id, error: String((err && err.message) || err) });
    }
  };
})();
