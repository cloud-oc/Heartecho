#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PYTHON="${PYTHON:-/Users/cloud/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3}"
OUTPUT_DIR="$ROOT_DIR/build/icons"
APP_ICONSET="$OUTPUT_DIR/Heartecho.iconset"
DRIVER_ICONSET="$OUTPUT_DIR/HeartechoDriver.iconset"
APP_ICNS="$OUTPUT_DIR/Heartecho.icns"
DRIVER_ICNS="$OUTPUT_DIR/HeartechoDriver.icns"

[ -x "$PYTHON" ] || PYTHON="$(command -v python3)"
[ -n "$PYTHON" ] || { printf 'python3 is required to build icons.\n' >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
rm -rf "$APP_ICONSET" "$DRIVER_ICONSET"
mkdir -p "$APP_ICONSET" "$DRIVER_ICONSET"

"$PYTHON" - "$OUTPUT_DIR" <<'PY'
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

output = Path(sys.argv[1])

sizes = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}

def lerp(a, b, t):
    return int(a + (b - a) * t)

def gradient(size, start, end):
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pixels = image.load()
    for y in range(size):
        for x in range(size):
            t = (x * 0.45 + y * 0.55) / max(1, size - 1)
            pixels[x, y] = (
                lerp(start[0], end[0], t),
                lerp(start[1], end[1], t),
                lerp(start[2], end[2], t),
                255,
            )
    return image

def rounded_mask(size, radius):
    scale = 4
    mask = Image.new("L", (size * scale, size * scale), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        (0, 0, size * scale - 1, size * scale - 1),
        radius=radius * scale,
        fill=255,
    )
    return mask.resize((size, size), Image.Resampling.LANCZOS)

def draw_polyline(draw, points, fill, width):
    if len(points) < 2:
        return
    draw.line(points, fill=fill, width=width, joint="curve")

def make_icon(size, variant):
    if variant == "app":
        start = (43, 124, 238)
        end = (17, 24, 39)
        line = (242, 201, 76, 255)
        line2 = (39, 174, 96, 255)
        node = (255, 255, 255, 255)
    else:
        start = (155, 81, 224)
        end = (17, 24, 39)
        line = (86, 204, 242, 255)
        line2 = (45, 156, 219, 255)
        node = (245, 247, 250, 255)

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_mask = rounded_mask(size, int(size * 0.19))
    shadow.putalpha(shadow_mask.filter(ImageFilter.GaussianBlur(max(1, size // 36))))
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 72))
    canvas.alpha_composite(shadow, (0, max(1, size // 38)))

    body = gradient(size, start, end)
    body.putalpha(rounded_mask(size, int(size * 0.19)))
    canvas.alpha_composite(body)

    draw = ImageDraw.Draw(canvas)
    inset = size * 0.095
    arc_box = (inset * 1.65, inset * 1.65, size - inset * 1.65, size - inset * 1.65)
    draw.arc(arc_box, start=205, end=335, fill=(255, 255, 255, 72), width=max(2, size // 22))
    draw.arc(arc_box, start=25, end=155, fill=(255, 255, 255, 72), width=max(2, size // 22))

    width = max(4, size // 16)
    y_mid = size * 0.50
    p1 = [
        (size * 0.24, y_mid),
        (size * 0.42, y_mid),
        (size * 0.51, size * 0.39),
        (size * 0.62, size * 0.62),
        (size * 0.75, size * 0.62),
    ]
    p2 = [
        (size * 0.24, size * 0.38),
        (size * 0.39, size * 0.38),
        (size * 0.55, size * 0.57),
        (size * 0.75, size * 0.38),
    ]
    draw_polyline(draw, p2, line2, max(2, width // 2))
    draw_polyline(draw, p1, line, width)

    for x, y, r, fill in [
        (size * 0.24, y_mid, size * 0.074, node),
        (size * 0.51, size * 0.39, size * 0.064, line),
        (size * 0.75, size * 0.62, size * 0.074, node),
    ]:
        draw.ellipse((x - r, y - r, x + r, y + r), fill=fill)

    if size >= 128:
        draw.text((size * 0.39, size * 0.72), "HE", fill=(255, 255, 255, 180))

    background = Image.new("RGB", (size, size), (18, 24, 38))
    background.paste(canvas, mask=canvas.getchannel("A"))
    return background

for variant, iconset_name in [
    ("app", "Heartecho.iconset"),
    ("driver", "HeartechoDriver.iconset"),
]:
    iconset = output / iconset_name
    iconset.mkdir(parents=True, exist_ok=True)
    for name, size in sizes.items():
        make_icon(size, variant).save(iconset / name)
PY

APP_ICNS_STATUS="missing"
DRIVER_ICNS_STATUS="missing"

if iconutil -c icns "$APP_ICONSET" -o "$APP_ICNS" >/tmp/heartecho-app-iconutil.log 2>&1; then
    APP_ICNS_STATUS="built"
else
    rm -f "$APP_ICNS"
    printf 'Warning: iconutil could not build app .icns; keeping iconset PNG assets.\n' >&2
    sed 's/^/  /' /tmp/heartecho-app-iconutil.log >&2
fi

if iconutil -c icns "$DRIVER_ICONSET" -o "$DRIVER_ICNS" >/tmp/heartecho-driver-iconutil.log 2>&1; then
    DRIVER_ICNS_STATUS="built"
else
    rm -f "$DRIVER_ICNS"
    printf 'Warning: iconutil could not build HAL driver .icns; keeping iconset PNG assets.\n' >&2
    sed 's/^/  /' /tmp/heartecho-driver-iconutil.log >&2
fi

printf 'Built icons\n'
printf '%s\n' "- app iconset: $APP_ICONSET"
printf '%s\n' "- app icns: $APP_ICNS_STATUS"
printf '%s\n' "- HAL driver iconset: $DRIVER_ICONSET"
printf '%s\n' "- HAL driver icns: $DRIVER_ICNS_STATUS"
