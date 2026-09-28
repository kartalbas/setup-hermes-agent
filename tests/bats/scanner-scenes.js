/*
 * Scenes for the scanner's sheet detection (librechat.bats): letters — text
 * lines, a letterhead, folded in three where asked — or narrow receipts, laid
 * in perspective on a desk, with the light falling off, a shadow, camera noise
 * and a little blur, at the size the phone's live preview is looked at
 * (480 x 853, upright) or, with scale 2, the size a shot is measured at again.
 *
 * scene(cv, spec, scale) -> {data, width, height} in RGBA. SCENES maps a name
 * to its spec; spec.sheets holds each sheet's true corners (TL, TR, BR, BL),
 * largest first, and spec.hard marks a scene no global pass can see: a hard
 * shadow across page and desk. There a page may go unseen, but a wrong one
 * must not be found.
 */
"use strict";

const W = 480, H = 853;

function prng(seed) {
  return () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
}

function sheet(cv, rnd, kind, folds, tint) {     // the flat sheet: a letter 600 x 850, a receipt 300 x 850
  const w = kind === "receipt" ? 300 : 600;
  const page = new cv.Mat(850, w, cv.CV_8UC1, new cv.Scalar(Math.round(242 * tint)));
  for (let y = 120; y < 780; y += 22) {
    const len = (w - 140) * (0.75 + rnd() * 0.25);
    cv.rectangle(page, new cv.Point(70, y), new cv.Point(70 + len, y + 7), new cv.Scalar(60), -1);
  }
  if (kind !== "receipt") cv.rectangle(page, new cv.Point(380, 40), new cv.Point(540, 90), new cv.Scalar(90), -1);
  if (folds) for (const y of [283, 566]) cv.line(page, new cv.Point(0, y), new cv.Point(w - 1, y), new cv.Scalar(200), 3);
  return page;
}

function channel(cv, spec, desk, tint, s) {      // one colour channel of the scene, at scale s
  const rnd = prng(7);                           // the same for every channel: one geometry, one noise
  const w = W * s, h = H * s;
  const img = new cv.Mat(h, w, cv.CV_8UC1, new cv.Scalar(desk));
  if (spec.grain) for (let x = 0; x < w; x += 3 * s) {
    const v = Math.max(0, Math.min(255, desk + (rnd() - 0.5) * spec.grain));
    cv.line(img, new cv.Point(x, 0), new cv.Point(x + 40 * s, h - 1), new cv.Scalar(v), 3 * s);
  }
  for (const quad of spec.sheets) {
    const page = sheet(cv, rnd, spec.kind, spec.folds, tint);
    const white = new cv.Mat(page.rows, page.cols, cv.CV_8UC1, new cv.Scalar(255));
    const from = cv.matFromArray(4, 1, cv.CV_32FC2, [0, 0, page.cols, 0, page.cols, page.rows, 0, page.rows]);
    const to = cv.matFromArray(4, 1, cv.CV_32FC2, quad.flat().map((v) => v * s));
    const m = cv.getPerspectiveTransform(from, to), warped = new cv.Mat(), mask = new cv.Mat();
    cv.warpPerspective(page, warped, m, new cv.Size(w, h));
    cv.warpPerspective(white, mask, m, new cv.Size(w, h));
    warped.copyTo(img, mask);
    [page, white, from, to, m, warped, mask].forEach((x) => x.delete());
  }
  const d = img.data;
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let v = d[y * w + x];
    if (spec.gradient) v *= 1 - (spec.gradient * (x / w + y / h)) / 2;
    if (spec.shadow && x < w * 0.45 && y > h * 0.55) v *= 1 - spec.shadow;
    if (spec.soft) {
      v *= 1 - spec.soft * Math.min(1, Math.max(0, (w * 0.55 - x) / (80 * s))) * Math.min(1, Math.max(0, (y - h * 0.45) / (80 * s)));
    }
    d[y * w + x] = Math.max(0, Math.min(255, v + (rnd() - 0.5) * 2 * (spec.noise || 0)));
  }
  cv.GaussianBlur(img, img, new cv.Size(2 * s + 1, 2 * s + 1), 0);
  const out = new Uint8Array(img.data);
  img.delete();
  return out;
}

function scene(cv, spec, scale) {
  const s = scale || 1, colour = Array.isArray(spec.desk);
  const planes = (colour ? spec.desk : [spec.desk]).map((desk, k) => channel(cv, spec, desk, colour ? [1, 0.99, 0.96][k] : 1, s));
  const n = W * s * H * s, data = new Uint8ClampedArray(n * 4);
  for (let i = 0; i < n; i++) {
    for (let k = 0; k < 3; k++) data[4 * i + k] = planes[colour ? k : 0][i];
    data[4 * i + 3] = 255;
  }
  return { data, width: W * s, height: H * s };
}

const UPRIGHT = [[80, 150], [400, 140], [420, 700], [60, 710]];
const LEANING = [[90, 160], [395, 130], [430, 690], [70, 720]];
const TURNED = [[150, 90], [440, 210], [330, 760], [40, 640]];

const SCENES = {
  "dark desk": { desk: 55, sheets: [UPRIGHT] },
  "light wood": { desk: 175, grain: 40, gradient: 0.25, noise: 6, sheets: [LEANING] },
  "light wood, folded letter": { desk: 175, grain: 40, gradient: 0.25, noise: 6, folds: true, sheets: [LEANING] },
  "grey desk, page turned": { desk: 130, noise: 6, sheets: [TURNED] },
  "light desk, soft shadow": { desk: 200, gradient: 0.2, soft: 0.35, noise: 5, sheets: [UPRIGHT] },
  "beige desk": { desk: [215, 200, 168], gradient: 0.15, noise: 5, sheets: [LEANING] },
  "brown wood, folded, turned": { desk: [150, 100, 60], grain: 30, gradient: 0.2, noise: 6, folds: true, sheets: [TURNED] },
  "white desk": { desk: 222, gradient: 0.15, noise: 5, sheets: [UPRIGHT] },
  "page nearly fills the frame": { desk: 150, noise: 5, sheets: [[[12, 30], [468, 22], [474, 830], [6, 838]]] },
  "three receipts on a dark desk": { desk: 60, noise: 5, kind: "receipt",
    sheets: [[[30, 200], [160, 195], [165, 640], [35, 645]], [[180, 180], [305, 185], [300, 600], [175, 598]],
             [[325, 230], [450, 222], [455, 560], [330, 565]]] },
  "two letters side by side on wood": { desk: 150, grain: 30, gradient: 0.15, noise: 5,
    sheets: [[[20, 250], [230, 245], [235, 540], [25, 545]], [[250, 260], [460, 255], [458, 552], [248, 556]]] },
  "light desk, hard shadow": { desk: 200, gradient: 0.2, shadow: 0.35, noise: 5, sheets: [UPRIGHT], hard: true },
};

module.exports = { W, H, SCENES, scene };
