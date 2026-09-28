/*
 * Scenes for the scanner's page detection (librechat.bats): a letter — text
 * lines, a letterhead, folded in three where asked — laid in perspective on a
 * desk, with the light falling off, a shadow, camera noise and a little blur,
 * at the size the phone's live preview is looked at (480 x 853, upright).
 *
 * scene(cv, spec) -> {data, width, height} in RGBA. SCENES maps a name to its
 * spec; spec.quad holds the page's true corners (TL, TR, BR, BL), and
 * spec.hard marks a scene no global pass can see: a hard shadow across page
 * and desk. There a page may go unseen, but a wrong one must not be found.
 */
"use strict";

const W = 480, H = 853;

function prng(seed) {
  return () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
}

function letter(cv, rnd, folds, tint) {          // the flat page, 600 x 850
  const page = new cv.Mat(850, 600, cv.CV_8UC1, new cv.Scalar(Math.round(242 * tint)));
  for (let y = 120; y < 780; y += 22) {
    cv.rectangle(page, new cv.Point(70, y), new cv.Point(70 + 380 + rnd() * 100, y + 7), new cv.Scalar(60), -1);
  }
  cv.rectangle(page, new cv.Point(380, 40), new cv.Point(540, 90), new cv.Scalar(90), -1);
  if (folds) for (const y of [283, 566]) cv.line(page, new cv.Point(0, y), new cv.Point(599, y), new cv.Scalar(200), 3);
  return page;
}

function channel(cv, spec, desk, tint) {         // one colour channel of the scene
  const rnd = prng(7);                           // the same for every channel: one geometry, one noise
  const img = new cv.Mat(H, W, cv.CV_8UC1, new cv.Scalar(desk));
  if (spec.grain) for (let x = 0; x < W; x += 3) {
    const v = Math.max(0, Math.min(255, desk + (rnd() - 0.5) * spec.grain));
    cv.line(img, new cv.Point(x, 0), new cv.Point(x + 40, H - 1), new cv.Scalar(v), 3);
  }
  const page = letter(cv, rnd, spec.folds, tint);
  const white = new cv.Mat(850, 600, cv.CV_8UC1, new cv.Scalar(255));
  const from = cv.matFromArray(4, 1, cv.CV_32FC2, [0, 0, 600, 0, 600, 850, 0, 850]);
  const to = cv.matFromArray(4, 1, cv.CV_32FC2, spec.quad.flat());
  const m = cv.getPerspectiveTransform(from, to), warped = new cv.Mat(), mask = new cv.Mat();
  cv.warpPerspective(page, warped, m, new cv.Size(W, H));
  cv.warpPerspective(white, mask, m, new cv.Size(W, H));
  warped.copyTo(img, mask);
  const d = img.data;
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    let v = d[y * W + x];
    if (spec.gradient) v *= 1 - (spec.gradient * (x / W + y / H)) / 2;
    if (spec.shadow && x < W * 0.45 && y > H * 0.55) v *= 1 - spec.shadow;
    if (spec.soft) {
      v *= 1 - spec.soft * Math.min(1, Math.max(0, (W * 0.55 - x) / 80)) * Math.min(1, Math.max(0, (y - H * 0.45) / 80));
    }
    d[y * W + x] = Math.max(0, Math.min(255, v + (rnd() - 0.5) * 2 * (spec.noise || 0)));
  }
  cv.GaussianBlur(img, img, new cv.Size(3, 3), 0);
  const out = new Uint8Array(img.data);
  [img, page, white, from, to, m, warped, mask].forEach((x) => x.delete());
  return out;
}

function scene(cv, spec) {
  const colour = Array.isArray(spec.desk);
  const desks = colour ? spec.desk : [spec.desk];
  const planes = desks.map((desk, k) => channel(cv, spec, desk, colour ? [1, 0.99, 0.96][k] : 1));
  const data = new Uint8ClampedArray(W * H * 4);
  for (let i = 0; i < W * H; i++) {
    for (let k = 0; k < 3; k++) data[4 * i + k] = planes[colour ? k : 0][i];
    data[4 * i + 3] = 255;
  }
  return { data, width: W, height: H };
}

const UPRIGHT = [[80, 150], [400, 140], [420, 700], [60, 710]];
const LEANING = [[90, 160], [395, 130], [430, 690], [70, 720]];
const TURNED = [[150, 90], [440, 210], [330, 760], [40, 640]];

const SCENES = {
  "dark desk": { desk: 55, quad: UPRIGHT },
  "light wood": { desk: 175, grain: 40, gradient: 0.25, noise: 6, quad: LEANING },
  "light wood, folded letter": { desk: 175, grain: 40, gradient: 0.25, noise: 6, folds: true, quad: LEANING },
  "grey desk, page turned": { desk: 130, noise: 6, quad: TURNED },
  "light desk, soft shadow": { desk: 200, gradient: 0.2, soft: 0.35, noise: 5, quad: UPRIGHT },
  "beige desk": { desk: [215, 200, 168], gradient: 0.15, noise: 5, quad: LEANING },
  "brown wood, folded, turned": { desk: [150, 100, 60], grain: 30, gradient: 0.2, noise: 6, folds: true, quad: TURNED },
  "white desk": { desk: 222, gradient: 0.15, noise: 5, quad: UPRIGHT },
  "page nearly fills the frame": { desk: 150, noise: 5, quad: [[12, 30], [468, 22], [474, 830], [6, 838]] },
  "light desk, hard shadow": { desk: 200, gradient: 0.2, shadow: 0.35, noise: 5, quad: UPRIGHT, hard: true },
};

module.exports = { W, H, SCENES, scene };
