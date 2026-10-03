"""Renders a viewers-over-time PNG without a headless browser.

Drawn at 2x and downsampled for antialiasing.
"""

import io
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

FONTS = Path(__file__).resolve().parent / "fonts"
SANS = FONTS / "ibm-plex-sans-variable.ttf"
MONO = FONTS / "ibm-plex-mono-500.ttf"

WIDE, HIGH = 1200, 520
SCALE = 2
PAD = {"l": 92, "r": 40, "t": 118, "b": 74}

PAPER = (251, 250, 248)
INK = (42, 41, 38)
INK_2 = (105, 103, 98)
INK_4 = (160, 157, 150)
GRID = (230, 227, 221)
LINE = (194, 94, 27)
WASH = (194, 94, 27)

SPANS = {
    "1h": ("minutes after posting", 60, 10, lambda m: f"{m}m"),
    "1d": ("hours after posting", 3600, 4, lambda h: f"{h}h"),
    "1w": ("days after posting", 86400, 1, lambda d: f"day {d}"),
    "30d": ("days after posting", 86400, 5, lambda d: f"day {d}"),
}

TITLES = {
    "1h": "the first hour",
    "1d": "the first day",
    "1w": "the first week",
    "30d": "the first month",
}


def font(path, size, weight=400):
    try:
        face = ImageFont.truetype(str(path), size * SCALE)
        try:
            face.set_variation_by_axes([weight])
        except (OSError, AttributeError):
            pass
        return face
    except OSError:
        return ImageFont.load_default(size * SCALE)


def axis_ticks(top, wanted=4):
    if top <= 0:
        return [0, 1]
    raw = top / wanted
    magnitude = 10 ** math.floor(math.log10(raw))
    for step in (1, 2, 2.5, 5, 10):
        if raw <= step * magnitude:
            step *= magnitude
            break
    ticks = []
    at = 0
    while at <= top + step * 0.001:
        ticks.append(at)
        at += step
    if ticks[-1] < top:
        ticks.append(ticks[-1] + step)
    return ticks


def smoothed(points, per_span=12):
    """Monotone cubic interpolation; does not overshoot on flat segments."""
    n = len(points)
    if n < 3:
        return points
    xs = [x for x, _ in points]
    ys = [y for _, y in points]
    dx = [xs[i + 1] - xs[i] or 1e-9 for i in range(n - 1)]
    slope = [(ys[i + 1] - ys[i]) / dx[i] for i in range(n - 1)]
    m = [0.0] * n
    m[0], m[-1] = slope[0], slope[-1]
    for i in range(1, n - 1):
        if slope[i - 1] * slope[i] <= 0:
            m[i] = 0.0
        else:
            m[i] = (slope[i - 1] + slope[i]) / 2
    for i in range(n - 1):
        if slope[i] == 0:
            m[i] = m[i + 1] = 0.0
            continue
        a, b = m[i] / slope[i], m[i + 1] / slope[i]
        tight = a * a + b * b
        if tight > 9:
            tau = 3 / math.sqrt(tight)
            m[i], m[i + 1] = tau * a * slope[i], tau * b * slope[i]
    out = []
    for i in range(n - 1):
        h = dx[i]
        for k in range(per_span):
            t = k / per_span
            t2, t3 = t * t, t * t * t
            h00 = 2 * t3 - 3 * t2 + 1
            h10 = t3 - 2 * t2 + t
            h01 = -2 * t3 + 3 * t2
            h11 = t3 - t2
            out.append((xs[i] + t * h,
                        h00 * ys[i] + h10 * h * m[i] + h01 * ys[i + 1] + h11 * h * m[i + 1]))
    out.append(points[-1])
    return out


def gradient_fill(size, polygon, floor, top):
    """Vertical gradient fill between the curve and the baseline."""
    layer = Image.new("RGBA", size, WASH + (0,))
    shape = Image.new("L", size, 0)
    ImageDraw.Draw(shape).polygon(polygon, fill=255)
    fade = Image.linear_gradient("L").resize((size[0], max(1, floor - top)))
    ramp = Image.new("L", size, 0)
    ramp.paste(fade.point(lambda v: int(58 * (255 - v) / 255)), (0, top))
    mask = Image.composite(ramp, Image.new("L", size, 0), shape)
    layer.putalpha(mask)
    return layer


def bucket_label(curve):
    """Human-readable bucket width; Slack selects it per span."""
    seconds = int((curve[1][0] - curve[0][0]).total_seconds()) if len(curve) > 1 else 0
    if seconds <= 0:
        return "bucket"
    if seconds < 3600:
        minutes = seconds // 60
        return "minute" if minutes == 1 else f"{minutes} minutes"
    hours = seconds // 3600
    if hours < 24:
        return "hour" if hours == 1 else f"{hours} hours"
    days = hours // 24
    return "day" if days == 1 else f"{days} days"


def trim_to_present(curve, age_seconds):
    """Drop the zero-padding Slack appends past the current time."""
    if age_seconds is None or not curve:
        return curve
    start = curve[0][0]
    return [(at, count) for at, count in curve if (at - start).total_seconds() <= age_seconds]


WINDOWS = ((86400, "day"), (3600, "hour"), (60, "minute"))


def format_span(seconds):
    for size, word in WINDOWS:
        if seconds >= size:
            count = round(seconds / size)
            return f"the first {word}" if count == 1 else f"the first {count} {word}s"
    return "the first minute"


def render(curve, span, viewers=None, age_seconds=None):
    """PNG bytes for one span's curve of (posted_at + offset, new viewers),
    drawn up to the present only."""
    spec = SPANS.get(span)
    if not spec or len(curve) < 2:
        return None
    whole_span = (curve[-1][0] - curve[0][0]).total_seconds()
    curve = trim_to_present(curve, age_seconds)
    if len(curve) < 2:
        return None

    unit_label, unit, step, say = spec
    s = SCALE
    size = (WIDE * s, HIGH * s)
    image = Image.new("RGB", size, PAPER)
    draw = ImageDraw.Draw(image, "RGBA")

    left, right = PAD["l"] * s, (WIDE - PAD["r"]) * s
    top, floor = PAD["t"] * s, (HIGH - PAD["b"]) * s

    start = curve[0][0]
    span_seconds = whole_span or 1
    counts = [count for _, count in curve]
    peak = max(counts)
    ticks = axis_ticks(peak * 1.12)
    ceiling = ticks[-1]

    def x_of(at):
        return left + (right - left) * ((at - start).total_seconds() / span_seconds)

    def y_of(v):
        return floor - (floor - top) * (v / ceiling if ceiling else 0)

    small = font(MONO, 15)
    for tick in ticks:
        y = y_of(tick)
        draw.line([(left, y), (right, y)], fill=GRID, width=s)
        label = f"{int(tick):,}" if float(tick).is_integer() else f"{tick:g}"
        draw.text((left - 18 * s, y), label, font=small, fill=INK_4, anchor="rm")

    whole = int(span_seconds // unit)
    for k in range(0, whole + 1, step):
        at = left + (right - left) * (k * unit / span_seconds)
        draw.line([(at, floor), (at, floor + 6 * s)], fill=GRID, width=s)
        draw.text((at, floor + 14 * s), say(k), font=small, fill=INK_4, anchor="ma")
    draw.text((right, floor + 40 * s), unit_label, font=small, fill=INK_4, anchor="ra")

    points = [(x_of(at), y_of(count)) for at, count in curve]
    bend = smoothed(points)
    bend = [(x, min(max(y, top), floor)) for x, y in bend]

    under = gradient_fill(size, [(left, floor), *bend, (bend[-1][0], floor)], floor, top)
    image.paste(under, (0, 0), under)
    draw = ImageDraw.Draw(image, "RGBA")
    draw.line([(left, floor), (right, floor)], fill=GRID, width=s)
    draw.line(bend, fill=LINE, width=int(3.2 * s), joint="curve")

    if age_seconds is not None and age_seconds < whole_span:
        now_x = x_of(curve[-1][0])
        for y in range(int(top), int(floor), 8 * s):
            draw.line([(now_x, y), (now_x, min(y + 4 * s, floor))], fill=INK_4, width=s)
        draw.text((now_x + 8 * s, top + 2 * s), "now", font=small, fill=INK_4, anchor="la")

    i = counts.index(peak)
    px, py = points[i]
    draw.ellipse([px - 7 * s, py - 7 * s, px + 7 * s, py + 7 * s], fill=PAPER, outline=LINE,
                 width=int(3 * s))
    peak_font = font(MONO, 16, 500)
    anchor = "ls" if px < (left + right) / 2 else "rs"
    post_expiry_notice = 14 * s if anchor == "ls" else -14 * s
    draw.text((px + post_expiry_notice, py - 12 * s), f"{peak:,}", font=peak_font, fill=LINE, anchor=anchor)

    title = font(SANS, 30, 620)
    sub = font(MONO, 16)
    draw.text((left, 34 * s), f"Viewers over {format_span(whole_span)}", font=title, fill=INK,
              anchor="la")
    seen = f"{sum(counts):,} of {viewers:,}" if viewers is not None else f"{sum(counts):,}"
    draw.text((left, 74 * s), f"{seen} viewers · new viewers per {bucket_label(curve)}",
              font=sub, fill=INK_2, anchor="la")

    shrunk = image.resize((WIDE, HIGH), Image.LANCZOS).filter(ImageFilter.SHARPEN)
    out = io.BytesIO()
    shrunk.save(out, format="PNG", optimize=True)
    return out.getvalue()


def span_for(age_seconds):
    """Select the reporting span appropriate to the post's age."""
    if age_seconds < 2 * 3600:
        return "1h"
    if age_seconds < 2 * 86400:
        return "1d"
    if age_seconds < 8 * 86400:
        return "1w"
    return "30d"
