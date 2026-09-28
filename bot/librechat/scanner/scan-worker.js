/*
 * The scanner's image work, off the page's thread (ADR 0029).
 *
 * OpenCV.js is nine megabytes of WebAssembly. Started on the page it holds the
 * thread while it compiles, and it takes over a global `Module` the page may
 * already have (LibreChat's HEIC converter is such a build). In a worker
 * neither matters: the page stays responsive and the worker has a global scope
 * of its own.
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

  var MIN_PAGE_SHARE = 0.12;   // a "page" smaller than this share of the frame is noise

  /**
   * The largest contour, found the way jscanify's findPaperContour finds it —
   * edges, a little blur, Otsu, contours — but with every Mat freed: jscanify's
   * own keeps one per contour it looks at, which a live preview asking several
   * times a second turns into megabytes a minute.
   */
  function paperContour(cv, mat) {
    var edges = new cv.Mat(), blurred = new cv.Mat(), binary = new cv.Mat();
    var contours = new cv.MatVector(), hierarchy = new cv.Mat(), best = null, bestArea = 0;
    try {
      cv.Canny(mat, edges, 50, 200);
      cv.GaussianBlur(edges, blurred, new cv.Size(3, 3), 0, 0, cv.BORDER_DEFAULT);
      cv.threshold(blurred, binary, 0, 255, cv.THRESH_OTSU);
      cv.findContours(binary, contours, hierarchy, cv.RETR_CCOMP, cv.CHAIN_APPROX_SIMPLE);
      for (var i = 0; i < contours.size(); i++) {
        var contour = contours.get(i), area = cv.contourArea(contour);
        if (area > bestArea) {
          if (best) best.delete();
          best = contour; bestArea = area;
        } else {
          contour.delete();
        }
      }
      return best && { contour: best, area: bestArea };
    } finally {
      [edges, blurred, binary, contours, hierarchy].forEach(function (m) { m.delete(); });
    }
  }

  /** The page's four corners in the image's pixels, or null. */
  function findCorners(cv, scanner, image) {
    var mat = cv.matFromImageData(image), found = null;
    try {
      found = paperContour(cv, mat);
      if (!found || found.area < MIN_PAGE_SHARE * image.width * image.height) return null;
      var c = scanner.getCornerPoints(found.contour);
      if (!c.topLeftCorner || !c.topRightCorner || !c.bottomLeftCorner || !c.bottomRightCorner) return null;
      return c;
    } finally {
      mat.delete();
      if (found) found.contour.delete();
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
    module.exports = { findCorners: findCorners, warp: warp };
    return;
  }

  // --- in the worker ----------------------------------------------------------
  var query = self.location.search || "";
  var cv = null, scanner = null;

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
    try {
      self.importScripts("jscanify.js" + query);
      if (typeof self.jscanify !== "function") throw new Error("jscanify did not register");
      cv = c;
      scanner = new self.jscanify();
      self.postMessage({ type: "ready" });
    } catch (e) {
      fail(e);
    }
  });

  self.onmessage = function (e) {
    var msg = e.data || {};
    if (!scanner) { self.postMessage({ id: msg.id, error: "not ready" }); return; }
    try {
      if (msg.type === "detect") {
        self.postMessage({ id: msg.id, corners: findCorners(cv, scanner, msg.image) });
      } else if (msg.type === "extract") {
        var out = warp(cv, msg.image, msg.corners, msg.width, msg.height);
        self.postMessage({ id: msg.id, image: out }, [out.data.buffer]);
      }
    } catch (err) {
      self.postMessage({ id: msg.id, error: String((err && err.message) || err) });
    }
  };
})();
