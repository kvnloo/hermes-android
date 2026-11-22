#!/usr/bin/env python3
"""Synthetic parity fixtures: a fake 1080x2340 chat-list screen plus variants.

Used by tools/test_parity_diff.py and to demo the tool without a phone:
    python3 tools/parity_fixtures.py /tmp/parity-demo
    python3 tools/parity_report.py --root /tmp/parity-demo

Writes <root>/reference/official-<case>.{png,xml} (always the base screen)
and <root>/current/z0agent-<case>.{png,xml} (the variant) for every case in
CASES. The drawings are plain rectangles and text; nothing is taken from
either app.
"""
from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path
from xml.sax.saxutils import quoteattr

import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H = 1080, 2340
BG = (16, 17, 20)
CARD = (34, 36, 44)
FG = (232, 232, 240)
ACCENT = (120, 170, 255)
ROWS = ("Planning trip", "Fix the build", "Groceries")


@dataclass
class Variant:
    send_dx: int = 0
    drop_send: bool = False
    background: str = "flat"  # flat | gradient
    collapsed: bool = False
    accent: tuple = ACCENT
    extra: list = field(default_factory=list)


CASES = {
    "identical": Variant(),
    "moved-button": Variant(send_dx=-40),
    "missing-element": Variant(drop_send=True),
    "background-only": Variant(background="gradient"),
    "collapsed-list": Variant(collapsed=True),
}


def _font(size):
    try:
        return ImageFont.load_default(size=size)
    except (TypeError, OSError):  # old Pillow / no FreeType
        return ImageFont.load_default()


def _node(cls, bounds, text="", desc="", clickable=False, extra_attrs=""):
    x1, y1, x2, y2 = bounds
    return (
        f'<node index="0" text={quoteattr(text)} resource-id="" class="{cls}" package="demo.app" '
        f'content-desc={quoteattr(desc)} checkable="false" checked="false" clickable="{str(clickable).lower()}" '
        f'enabled="true" focusable="{str(clickable).lower()}" focused="false" scrollable="false" '
        f'long-clickable="false" password="false" selected="false" {extra_attrs}'
        f'bounds="[{x1},{y1}][{x2},{y2}]" />'
    )


def render(v: Variant = Variant()):
    """Return (PIL.Image RGB, uiautomator-style XML string) for a variant."""
    if v.background == "gradient":
        top, bot = (52, 24, 80), (8, 46, 64)
        t = np.linspace(0.0, 1.0, H)[:, None, None]
        grad = np.array(top) + (np.array(bot) - np.array(top)) * t  # (H, 1, 3)
        arr = np.broadcast_to(grad, (H, W, 3)).round().astype(np.uint8)
        base = Image.fromarray(arr).convert("RGBA")
    else:
        base = Image.new("RGBA", (W, H), BG + (255,))
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    nodes = []

    def text(bounds, s, size=48, fill=FG):
        f = _font(size)
        d.text((bounds[0] + 8, bounds[1] + (bounds[3] - bounds[1] - size) // 2), s, font=f, fill=fill)

    # top bar
    b = (32, 140, 152, 260)
    d.rounded_rectangle(b, 24, fill=CARD)
    for i in range(3):
        d.rectangle((62, 172 + i * 24, 122, 180 + i * 24), fill=FG)
    nodes.append(_node("android.widget.ImageButton", b, desc="Open navigation", clickable=True))
    b = (184, 160, 520, 240)
    text(b, "Hermes", 64)
    nodes.append(_node("android.widget.TextView", b, text="Hermes"))
    b = (560, 168, 624, 232)
    d.ellipse(b, fill=v.accent)
    nodes.append(_node("android.widget.ImageView", b))
    b = (760, 140, 1048, 260)
    d.rounded_rectangle(b, 60, fill=v.accent)
    text((790, 140, 1048, 260), "New chat", 48, fill=(10, 10, 20))
    nodes.append(_node("android.widget.Button", b, text="New chat", clickable=True))

    # collapsible sessions list
    b = (32, 320, 1048, 420)
    d.rectangle(b, fill=CARD)
    text(b, "Sessions", 52)
    chev = [(980, 350), (1020, 350), (1000, 390)] if not v.collapsed else [(985, 345), (985, 395), (1020, 370)]
    d.polygon(chev, fill=FG)
    nodes.append(
        _node("android.view.View", b, desc=f"Sessions, {'collapsed' if v.collapsed else 'expanded'}", clickable=True)
    )
    y = 440
    if not v.collapsed:
        for name in ROWS:
            b = (32, y, 1048, y + 130)
            d.rounded_rectangle(b, 20, fill=CARD)
            text((64, y, 1048, y + 130), name, 44)
            nodes.append(_node("android.view.View", b, text=name, clickable=True))
            y += 150

    # translucent tip card (exercises the background-compositing model)
    b = (32, y + 20, 1048, y + 160)
    d.rounded_rectangle(b, 20, fill=(255, 255, 255, 40))
    text((64, y + 20, 1048, y + 160), "Tip: long-press to pin", 40)
    nodes.append(_node("android.widget.TextView", b, text="Tip: long-press to pin"))

    for e in v.extra:
        d.rectangle(e["bounds"], fill=ACCENT)
        nodes.append(_node(e.get("cls", "android.widget.Button"), e["bounds"], text=e.get("text", ""), clickable=True))

    # composer
    b = (32, 2140, 880, 2260)
    d.rounded_rectangle(b, 60, fill=CARD)
    text((72, 2140, 880, 2260), "Message", 44, fill=(150, 150, 160))
    nodes.append(_node("android.widget.EditText", b, text="Message", clickable=True))
    if not v.drop_send:
        b = (904 + v.send_dx, 2140, 1048 + v.send_dx, 2260)
        d.ellipse(b, fill=v.accent)
        cx, cy = (b[0] + b[2]) // 2, 2200
        d.polygon([(cx - 22, cy - 26), (cx + 28, cy), (cx - 22, cy + 26)], fill=(10, 10, 20))
        nodes.append(_node("android.widget.ImageButton", b, desc="Send", clickable=True))

    img = Image.alpha_composite(base, layer).convert("RGB")
    xml = (
        "<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>"
        '<hierarchy rotation="0">'
        f'<node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="demo.app" '
        f'content-desc="" clickable="false" bounds="[0,0][{W},{H}]">'
        + "".join(nodes)
        + "</node></hierarchy>"
    )
    return img, xml


def write_pair(root, case, ours: Variant, official: Variant = Variant()):
    root = Path(root)
    (root / "reference").mkdir(parents=True, exist_ok=True)
    (root / "current").mkdir(parents=True, exist_ok=True)
    for prefix, sub, v in (("official", "reference", official), ("z0agent", "current", ours)):
        img, xml = render(v)
        img.save(root / sub / f"{prefix}-{case}.png")
        (root / sub / f"{prefix}-{case}.xml").write_text(xml)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        print("usage: parity_fixtures.py OUT_ROOT", file=sys.stderr)
        return 2
    for case, v in CASES.items():
        write_pair(argv[0], case, v)
        print(f"wrote {case}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
