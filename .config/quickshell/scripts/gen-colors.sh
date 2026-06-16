#!/usr/bin/env bash
# Pull a small colour palette out of the current wallpaper and write it to
# ~/.cache/quickshell/colors.json, which Theme.qml reads and applies live.
#
# No imagemagick/matugen — just ffmpeg (already a dep, see lock.sh) to shrink the
# image to a tiny raw buffer, and stdlib python to k-means it. Cheap enough to run
# on every wallpaper change.
#
# Usage: gen-colors.sh [wallpaper-path]
#   no arg -> uses whatever awww is currently showing.
exec python3 - "$@" <<'PY'
import subprocess, sys, os, json, colorsys, tempfile

wall = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None
if not wall:
    try:
        q = subprocess.run(["awww", "query"], capture_output=True, text=True, timeout=5).stdout
        for line in q.splitlines():
            i = line.find("image: ")
            if i != -1:
                wall = line[i + 7:].strip()
                break
    except Exception:
        pass

if not wall or not os.path.isfile(wall):
    sys.exit(0)

def ff(vf):
    p = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", wall, "-vf", vf,
         "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        capture_output=True, timeout=20)
    return p.stdout

full = ff("scale=48:48:flags=area")
if not full:
    sys.exit(0)

# Sample the wallpaper band that actually sits behind the bar. awww covers the
# screen (scale-to-fill, centred), so the image's literal top row is usually
# cropped off — we have to replay that crop to read the right pixels. Fall back to
# the image's top sliver if we can't learn the geometry.
BAR_H = 44

def screen_dims():
    try:
        mons = json.loads(subprocess.run(["hyprctl", "monitors", "-j"],
                                          capture_output=True, text=True, timeout=5).stdout)
        for m in mons:
            if m.get("focused"):
                return m["width"], m["height"]
        if mons:
            return mons[0]["width"], mons[0]["height"]
    except Exception:
        pass
    return None

def img_dims():
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x", wall],
            capture_output=True, text=True, timeout=10).stdout.strip()
        w, h = out.split("x")
        return int(w), int(h)
    except Exception:
        return None

strip = None
sd, idm = screen_dims(), img_dims()
if sd and idm:
    sw, sh = sd
    W, H = idm
    scale = max(sw / W, sh / H)              # cover: fill both axes
    cropw = max(1, int(sw / scale))          # only the columns actually on screen
    croph = max(1, int(BAR_H / scale))       # bar height back in image pixels
    x0 = int(max(0, (W - sw / scale) / 2))   # centred crop offsets
    y0 = int(max(0, (H - sh / scale) / 2))
    strip = ff("crop=%d:%d:%d:%d,scale=32:4:flags=area" % (cropw, croph, x0, y0))
if not strip:
    strip = ff("crop=iw:ih*0.06:0:0,scale=32:4:flags=area")

px = [(full[i], full[i + 1], full[i + 2]) for i in range(0, len(full) - 2, 3)]

def hsv(r, g, b):
    return colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)

def kmeans(px, k=5, iters=12):
    n = len(px)
    cents = [px[(i * n) // k] for i in range(k)]   # deterministic spread init
    assign = [0] * n
    for _ in range(iters):
        for idx, (r, g, b) in enumerate(px):
            best, bd = 0, 1e18
            for ci, (cr, cg, cb) in enumerate(cents):
                d = (r - cr) ** 2 + (g - cg) ** 2 + (b - cb) ** 2
                if d < bd:
                    bd, best = d, ci
            assign[idx] = best
        sums = [[0, 0, 0, 0] for _ in range(k)]
        for idx, (r, g, b) in enumerate(px):
            s = sums[assign[idx]]
            s[0] += r; s[1] += g; s[2] += b; s[3] += 1
        cents = [(s[0] / s[3], s[1] / s[3], s[2] / s[3]) if s[3] else cents[ci]
                 for ci, s in enumerate(sums)]
    pops = [0] * k
    for a in assign:
        pops[a] += 1
    return cents, pops

cents, pops = kmeans(px)
clusters = [(cents[i], pops[i]) for i in range(len(cents)) if pops[i] > 0]
total = sum(p for _, p in clusters) or 1

# Accent = the most vivid colour that's still actually present and not too dark.
best, best_score = None, -1
for c, p in clusters:
    h, s, v = hsv(*c)
    frac = p / total
    score = s * (0.4 + 0.6 * frac) * (0.3 + 0.7 * v)
    if score > best_score:
        best_score, best = score, (h, s, v)
acc_h, acc_s, acc_v0 = best
acc_s = min(max(acc_s, 0.45), 0.90)
acc_v = min(max(acc_v0, 0.75), 0.95)

# Dominant (largest) cluster's hue tints the dark bar/glass surfaces.
dom = max(clusters, key=lambda cp: cp[1])[0]
dh = hsv(*dom)[0]

# How bright is the wallpaper right behind the bar? That decides whether the bar's
# text/dots/glyph go dark or light so they stay visible.
def lum(r, g, b):
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255

if strip:
    sp = [(strip[i], strip[i + 1], strip[i + 2]) for i in range(0, len(strip) - 2, 3)]
    band = sum(lum(*p) for p in sp) / len(sp)
else:
    band = sum(lum(*p) for p in px) / len(px)

def hexc(h, s, v, a=1.0):
    r, g, b = colorsys.hsv_to_rgb(h, s, v)
    return "#%02X%02X%02X%02X" % (round(a * 255), round(r * 255), round(g * 255), round(b * 255))

# Bright behind the bar -> dark foreground; dark behind -> light. The whole
# palette (bar + popups) flips together so it stays coherent, with the accent
# pulled from the wallpaper either way.
if band >= 0.50:
    out = {
        "accent":        hexc(acc_h, min(acc_s + 0.10, 0.95), min(max(acc_v0, 0.35), 0.55)),
        "volGradStart":  hexc((acc_h - 0.04) % 1, min(acc_s + 0.10, 0.95), 0.55),
        "volGradEnd":    hexc((acc_h + 0.07) % 1, acc_s, 0.62),
        "textBright":    hexc(dh, 0.55, 0.08),
        "textPrimary":   hexc(dh, 0.45, 0.15),
        "textSecondary": hexc(dh, 0.35, 0.26),
        "textTertiary":  hexc(dh, 0.40, 0.20),
        "textMuted":     hexc(dh, 0.30, 0.38),
        "textDim":       hexc(dh, 0.30, 0.34),
        "glassBg":       hexc(dh, 0.10, 0.96, 0.55),
        "glassBorder":   hexc(dh, 0.40, 0.25, 0.30),
        "textShadow":    "#B3FFFFFF",   # dark text -> light halo lifts it off dark gaps
    }
else:
    out = {
        "accent":        hexc(acc_h, acc_s, acc_v),
        "volGradStart":  hexc((acc_h - 0.04) % 1, min(acc_s + 0.05, 0.95), acc_v),
        "volGradEnd":    hexc((acc_h + 0.07) % 1, acc_s, min(acc_v + 0.05, 0.98)),
        "textBright":    hexc(acc_h, 0.04, 1.00),
        "textPrimary":   hexc(acc_h, 0.08, 0.93),
        "textSecondary": hexc(acc_h, 0.10, 0.80),
        "textTertiary":  hexc(acc_h, 0.08, 0.86),
        "textMuted":     hexc(acc_h, 0.10, 0.68),
        "textDim":       hexc(acc_h, 0.08, 0.70),
        "glassBg":       hexc(dh, 0.32, 0.12, 0.55),
        "glassBorder":   hexc(acc_h, 0.30, 1.00, 0.22),
        "textShadow":    "#B3000000",   # light text -> dark halo lifts it off bright patches
    }

dst = os.path.expanduser("~/.cache/quickshell/colors.json")
os.makedirs(os.path.dirname(dst), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dst))
with os.fdopen(fd, "w") as f:
    json.dump(out, f, indent=2)
os.replace(tmp, dst)
print(json.dumps(out, indent=2))
PY
