#!/usr/bin/env bash
#
# Render the Teams app icons from the one SVG under bot/assets/.
#
#   color.png   192x192, the full tile
#   outline.png  32x32, the mark alone as a white silhouette on transparency
#               (what Teams shows in the dark sidebar)
#
# Run after changing the SVG and commit the PNGs: the installer needs no
# renderer, only the committed PNGs. Needs rsvg-convert (librsvg2-bin).
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
src="${here}/simetrix-appicon.svg"
out="${here}/../teams-app"
command -v rsvg-convert >/dev/null || { echo "rsvg-convert missing: apt-get install librsvg2-bin" >&2; exit 1; }
[[ -f $src ]] || { echo "missing $src" >&2; exit 1; }

rsvg-convert -w 192 -h 192 -o "${out}/color.png" "$src"

# The outline: keep only the mark's <g>, drop filters and gradients, paint it white.
tmp=$(mktemp --suffix=.svg)
trap 'rm -f "$tmp"' EXIT
python3 - "$src" >"$tmp" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
head = re.match(r"<svg[^>]*>", s).group(0)
g = re.search(r"<g[^>]*>.*?</g>", s, re.S).group(0)
g = re.sub(r'\s*filter="[^"]*"', "", g)
g = re.sub(r'fill="url\(#mark\)"', 'fill="#FFFFFF"', g)
sys.stdout.write(f"{head}\n{g}\n</svg>\n")
PY
rsvg-convert -w 32 -h 32 -o "${out}/outline.png" "$tmp"

python3 - "${out}/color.png" "${out}/outline.png" <<'PY'
import struct, sys
for n, want in zip(sys.argv[1:], (192, 32)):
    d = open(n, "rb").read(); w, h = struct.unpack(">II", d[16:24])
    assert (w, h) == (want, want), (n, w, h)
    print(f"{n}: {w}x{h}, {len(d)} bytes")
PY
