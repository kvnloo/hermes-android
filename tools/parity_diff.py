#!/usr/bin/env python3
"""Layout + pixel parity diff for one screen: official Hermes app vs ours.

Inputs (same device, same density):
  docs/parity/reference/official-<screen>.png + .xml   (uiautomator dump)
  docs/parity/current/z0agent-<screen>.png + .xml

Outputs:
  docs/parity/report/<screen>.md, <screen>.json, <screen>-heatmap.png
Exit code: 0 pass, 1 fail, 2 bad input.

Deps: pillow, numpy. No network. See docs/parity/README.md.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

OFFICIAL_PREFIX = "official-"
OURS_PREFIX = "z0agent-"

_BOUNDS_RE = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")
# State words that screen readers / semantics append to labels. They are
# stripped from the match key and compared separately as visual state.
_STATE_RE = re.compile(
    r"(?:double[- ]tap to (?:expand|collapse|activate|toggle)|"
    r"not selected|not checked|unchecked|selected|checked|expanded|collapsed)",
    re.IGNORECASE,
)


@dataclass
class Thresholds:
    pos_px: float = 4.0  # max position/size delta in px ...
    pos_pct: float = 1.0  # ... or in % of the screen dimension (either passes)
    pixel_pct: float = 3.0  # max % of element pixels that differ
    pixel_delta: int = 24  # per-channel delta (0-255) for a pixel to count as different
    bg_tol: int = 12  # per-channel tolerance for "is background"
    match_radius_pct: float = 8.0  # max centre distance (% of screen diagonal) for positional matching
    fail_on_missing_any: bool = False  # also fail on missing/extra non-interactive nodes


@dataclass
class Node:
    label: str  # normalized match key (state words removed)
    raw_label: str
    text: str
    desc: str
    cls: str
    rid: str
    role: str  # button | input | image | text
    interactive: bool
    state: dict
    bounds: tuple  # x1, y1, x2, y2

    @property
    def x(self):
        return self.bounds[0]

    @property
    def y(self):
        return self.bounds[1]

    @property
    def w(self):
        return self.bounds[2] - self.bounds[0]

    @property
    def h(self):
        return self.bounds[3] - self.bounds[1]

    @property
    def cx(self):
        return (self.bounds[0] + self.bounds[2]) / 2

    @property
    def cy(self):
        return (self.bounds[1] + self.bounds[3]) / 2

    def short(self):
        name = self.raw_label or self.rid or self.cls.rsplit(".", 1)[-1]
        return f"{self.role}:{name}"[:80]


# ---------------------------------------------------------------- XML


def parse_bounds(s: str):
    m = _BOUNDS_RE.search(s or "")
    if not m:
        return None
    return tuple(int(v) for v in m.groups())


def _norm(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "").strip())


def _strip_state(s: str) -> str:
    return _norm(_STATE_RE.sub(" ", s or "")).strip(" ,.;:-")


def _state_of(attrs: dict, label: str) -> dict:
    st = {}
    low = label.lower()
    if "collapsed" in low or re.search(r"double[- ]tap to expand", low):
        st["expanded"] = False
    elif "expanded" in low or re.search(r"double[- ]tap to collapse", low):
        st["expanded"] = True
    if attrs.get("expanded") in ("true", "false"):
        st["expanded"] = attrs["expanded"] == "true"
    if attrs.get("checkable") == "true":
        st["checked"] = attrs.get("checked") == "true"
    if attrs.get("selected") == "true":
        st["selected"] = True
    return st


def _role(attrs: dict) -> str:
    cls = attrs.get("class", "")
    if "EditText" in cls:
        return "input"
    if any(attrs.get(k) == "true" for k in ("clickable", "long-clickable", "checkable")):
        return "button"
    if "Image" in cls:
        return "image"
    return "text"


def parse_xml(path, screen_w: int, screen_h: int, keep_system: bool = False):
    """Return visible leaf-ish nodes: text, content-desc, clickable, images."""
    root = ET.parse(path).getroot()
    out = []
    for el in root.iter("node"):
        a = el.attrib
        if not keep_system and a.get("package", "").startswith("com.android.systemui"):
            continue
        if a.get("visible-to-user") == "false":
            continue
        b = parse_bounds(a.get("bounds", ""))
        if not b:
            continue
        x1, y1 = max(0, b[0]), max(0, b[1])
        x2, y2 = min(screen_w, b[2]), min(screen_h, b[3])
        if x2 - x1 <= 0 or y2 - y1 <= 0:
            continue
        text, desc = _norm(a.get("text", "")), _norm(a.get("content-desc", ""))
        cls = a.get("class", "")
        clickable = any(a.get(k) == "true" for k in ("clickable", "long-clickable", "checkable"))
        if not (text or desc or clickable or "Image" in cls):
            continue
        raw = text or desc
        out.append(
            Node(
                label=_strip_state(raw).casefold(),
                raw_label=raw,
                text=text,
                desc=desc,
                cls=cls,
                rid=a.get("resource-id", ""),
                role=_role(a),
                interactive=clickable or "EditText" in cls,
                state=_state_of(a, raw),
                bounds=(x1, y1, x2, y2),
            )
        )
    return out


# ---------------------------------------------------------------- matching


def match_nodes(off, ours, screen_w, screen_h, th: Thresholds):
    """Pass 1: equal label (nearest first). Pass 2: same role, nearest centre
    within the match radius, same-row candidates preferred (reading order)."""
    diag = math.hypot(screen_w, screen_h)
    pairs, used_o, used_u = [], set(), set()

    def greedy(cands):
        for _, i, j in sorted(cands):
            if i in used_o or j in used_u:
                continue
            used_o.add(i)
            used_u.add(j)
            pairs.append((i, j))

    def dist(a, b):
        return math.hypot(a.cx - b.cx, a.cy - b.cy) / diag

    cands = []
    for i, a in enumerate(off):
        if not a.label:
            continue
        for j, b in enumerate(ours):
            if b.label == a.label:
                # a role change is allowed, but costs more than any distance
                cands.append((dist(a, b) + (0 if a.role == b.role else 1.0), i, j))
    greedy(cands)

    radius = th.match_radius_pct / 100.0
    cands = []
    for i, a in enumerate(off):
        if i in used_o:
            continue
        for j, b in enumerate(ours):
            if j in used_u or a.role != b.role:
                continue
            d = dist(a, b)
            if d <= radius:
                cands.append((d + abs(a.cy - b.cy) / diag, i, j))
    greedy(cands)
    pairs.sort(key=lambda p: (off[p[0]].y, off[p[0]].x))
    missing = [i for i in range(len(off)) if i not in used_o]
    extra = [j for j in range(len(ours)) if j not in used_u]
    return pairs, missing, extra


def _within(delta_px, dim, th: Thresholds):
    return abs(delta_px) <= th.pos_px or abs(delta_px) / dim * 100.0 <= th.pos_pct


def _node_json(n: Node):
    return {
        "label": n.raw_label,
        "role": n.role,
        "interactive": n.interactive,
        "class": n.cls,
        "resource_id": n.rid,
        "state": n.state,
        "bounds": list(n.bounds),
        "short": n.short(),
    }


def compare_layout(off, ours, screen_w, screen_h, th: Thresholds):
    pairs, missing, extra = match_nodes(off, ours, screen_w, screen_h, th)
    matched = []
    for i, j in pairs:
        a, b = off[i], ours[j]
        d = {"dx": b.x - a.x, "dy": b.y - a.y, "dw": b.w - a.w, "dh": b.h - a.h}
        dims = {"dx": screen_w, "dy": screen_h, "dw": screen_w, "dh": screen_h}
        pct = {k: round(v / dims[k] * 100, 3) for k, v in d.items()}
        ok = all(_within(d[k], dims[k], th) for k in d)
        state_diff = {
            k: [a.state.get(k), b.state.get(k)]
            for k in sorted(set(a.state) | set(b.state))
            if a.state.get(k) != b.state.get(k)
        }
        text_diff = None
        if _strip_state(a.raw_label) != _strip_state(b.raw_label):
            text_diff = [a.raw_label, b.raw_label]
        font = None
        if a.text or b.text:  # text node height ~ line box ~ font size
            font = {"official_px": a.h, "ours_px": b.h, "delta_px": b.h - a.h}
        matched.append(
            {
                "official": _node_json(a),
                "ours": _node_json(b),
                "delta_px": d,
                "delta_pct": pct,
                "within_tolerance": ok,
                "state_diff": state_diff,
                "text_diff": text_diff,
                "font": font,
                "role_diff": None if a.role == b.role else [a.role, b.role],
            }
        )
    return matched, [_node_json(off[i]) for i in missing], [_node_json(ours[j]) for j in extra]


# ---------------------------------------------------------------- pixels


def load_rgb(path):
    with Image.open(path) as im:
        return np.asarray(im.convert("RGB"), dtype=np.int16)


def rect_mask(shape, rects):
    m = np.zeros(shape[:2], dtype=bool)
    for x1, y1, x2, y2 in rects:
        m[max(0, y1) : max(0, y2), max(0, x1) : max(0, x2)] = True
    return m


def dominant_colour(img, mask=None):
    px = img[mask] if mask is not None and mask.sum() >= 64 else img.reshape(-1, 3)
    if len(px) > 200_000:
        px = px[:: len(px) // 200_000 + 1]
    q = (px >> 3).astype(np.int32)
    keys = (q[:, 0] << 10) | (q[:, 1] << 5) | q[:, 2]
    vals, counts = np.unique(keys, return_counts=True)
    return px[keys == vals[counts.argmax()]].mean(axis=0)


def estimate_background(img, elem_mask):
    """Per-row background colour: median of the non-element pixels of each row,
    interpolated across rows fully covered by elements, falling back to the
    dominant colour. Models flat backgrounds and vertical gradients."""
    h, w, _ = img.shape
    non = ~elem_mask
    dom = dominant_colour(img, non)
    rows = np.full((h, 3), np.nan)
    counts = non.sum(axis=1)
    for y in np.nonzero(counts >= max(8, int(0.02 * w)))[0]:
        rows[y] = np.median(img[y][non[y]], axis=0)
    valid = ~np.isnan(rows[:, 0])
    if not valid.any():
        rows[:] = dom
    elif not valid.all():
        ys = np.arange(h)
        for c in range(3):
            rows[:, c] = np.interp(ys, ys[valid], rows[valid, c])
    return rows, dom


def background_mask(img, rows, dom, tol):
    near_row = (np.abs(img - rows[:, None, :]) <= tol).all(axis=2)
    near_dom = (np.abs(img - dom[None, None, :]) <= tol).all(axis=2)
    return near_row | near_dom


def _ok_at(A, B, bgA, bgB, ys, xs, delta):
    """For pixels (ys, xs): True where A matches some B pixel in its 3x3
    neighbourhood (tolerates 1 px rasterisation shifts), either directly
    (max channel delta <= delta) or as the same translucent / anti-aliased
    content composited over a different background:
        A - B == t * (bgA - bgB), t in [0, 1]   (residual <= delta)."""
    a = A[ys, xs].astype(np.float32)  # (n, 3)
    g = (bgA[ys] - bgB[ys]).astype(np.float32)  # (n, 3)
    gg = (g * g).sum(axis=1)
    Bp = np.pad(B, ((1, 1), (1, 1), (0, 0)), mode="edge")
    ok = np.zeros(len(ys), dtype=bool)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            d = a - Bp[ys + 1 + dy, xs + 1 + dx].astype(np.float32)
            ok |= np.abs(d).max(axis=1) <= delta
            t = np.where(gg > 1.0, (d * g).sum(axis=1) / np.maximum(gg, 1.0), 0.0)
            t = np.clip(t, 0.0, 1.0)[:, None]
            ok |= np.abs(d - t * g).max(axis=1) <= delta
    return ok


def compare_pixels(off_img, our_img, off_nodes, our_nodes, matched, th: Thresholds):
    region = rect_mask(off_img.shape, [m["official"]["bounds"] for m in matched]) | rect_mask(
        off_img.shape, [m["ours"]["bounds"] for m in matched]
    )
    rows_a, dom_a = estimate_background(off_img, rect_mask(off_img.shape, [n.bounds for n in off_nodes]))
    rows_b, dom_b = estimate_background(our_img, rect_mask(our_img.shape, [n.bounds for n in our_nodes]))
    bg_a = background_mask(off_img, rows_a, dom_a, th.bg_tol)
    bg_b = background_mask(our_img, rows_b, dom_b, th.bg_tol)
    # element pixels where at least one side shows something other than background
    considered = region & ~(bg_a & bg_b)
    ys, xs = np.nonzero(considered)
    ok = _ok_at(off_img, our_img, rows_a, rows_b, ys, xs, th.pixel_delta) & _ok_at(
        our_img, off_img, rows_b, rows_a, ys, xs, th.pixel_delta
    )
    differ = np.zeros(region.shape, dtype=bool)
    differ[ys[~ok], xs[~ok]] = True
    n_cons, n_diff = len(ys), int((~ok).sum())
    return {
        "region_px": int(region.sum()),
        "compared_px": n_cons,
        "differing_px": n_diff,
        "diff_pct": round(100.0 * n_diff / n_cons, 3) if n_cons else 0.0,
        "background_official": [int(round(v)) for v in dom_a],
        "background_ours": [int(round(v)) for v in dom_b],
    }, differ


def write_heatmap(path, off_img, differ, missing, extra, moved):
    grey = off_img.astype(np.float32).mean(axis=2) * 0.35
    rgb = np.stack([grey, grey, grey], axis=2)
    rgb[differ] = (255, 40, 40)
    im = Image.fromarray(rgb.clip(0, 255).astype(np.uint8))
    dr = ImageDraw.Draw(im)
    for n in missing:
        dr.rectangle(n["bounds"], outline=(255, 220, 0), width=4)
    for n in extra:
        dr.rectangle(n["bounds"], outline=(255, 0, 255), width=4)
    for m in moved:
        dr.rectangle(m["official"]["bounds"], outline=(0, 200, 255), width=3)
        dr.rectangle(m["ours"]["bounds"], outline=(0, 120, 255), width=2)
    im.save(path)


# ---------------------------------------------------------------- scoring


def _fmt_delta(m):
    d, p = m["delta_px"], m["delta_pct"]
    return " ".join(f"{k}={d[k]:+d}px({p[k]:+.2f}%)" for k in ("dx", "dy", "dw", "dh") if d[k])


def evaluate(layout, pixels, th: Thresholds, size_issue=None):
    matched, missing, extra = layout
    issues = []  # (severity, text); higher first
    if size_issue:
        issues.append((100, size_issue))
    for n in missing:
        issues.append((30 if n["interactive"] else 8, f"missing in ours: {n['short']} at {n['bounds']}"))
    for n in extra:
        issues.append((25 if n["interactive"] else 6, f"extra in ours: {n['short']} at {n['bounds']}"))
    for m in matched:
        if m["state_diff"]:
            s = ", ".join(f"{k} official={v[0]} ours={v[1]}" for k, v in m["state_diff"].items())
            issues.append((35, f"state differs on {m['official']['short']}: {s}"))
        if not m["within_tolerance"]:
            worst = max(abs(v) for v in m["delta_px"].values())
            issues.append((10 + min(worst, 200) / 10, f"off by {_fmt_delta(m)} on {m['official']['short']}"))
        if m["text_diff"]:
            issues.append((4, f"text differs: {m['text_diff'][0]!r} vs {m['text_diff'][1]!r}"))
        if m["role_diff"]:
            issues.append((5, f"role differs on {m['official']['short']}: {m['role_diff'][0]} vs {m['role_diff'][1]}"))
    if pixels["diff_pct"] >= th.pixel_pct:
        issues.append(
            (20 + pixels["diff_pct"], f"pixel diff {pixels['diff_pct']:.2f}% of element pixels (limit {th.pixel_pct}%)")
        )
    issues.sort(key=lambda t: -t[0])

    miss_i = sum(1 for n in missing if n["interactive"])
    extra_i = sum(1 for n in extra if n["interactive"])
    fails = {
        "screen_size": bool(size_issue),
        "missing_interactive": miss_i,
        "extra_interactive": extra_i,
        "missing_any": len(missing) if th.fail_on_missing_any else 0,
        "extra_any": len(extra) if th.fail_on_missing_any else 0,
        "out_of_tolerance": sum(1 for m in matched if not m["within_tolerance"]),
        "state_mismatch": sum(1 for m in matched if m["state_diff"]),
        "pixel": pixels["diff_pct"] >= th.pixel_pct,
    }
    passed = not any(fails.values())

    score = 100.0 - (50 if size_issue else 0)
    score -= 15 * miss_i + 4 * (len(missing) - miss_i)
    score -= 10 * extra_i + 3 * (len(extra) - extra_i)
    score -= 4 * fails["out_of_tolerance"] + 15 * fails["state_mismatch"]
    score -= sum(1 for m in matched if m["text_diff"])
    score -= min(40.0, 4.0 * pixels["diff_pct"])
    score = max(0, round(score))
    # keep score bands consistent with the verdict: pass >= 90 > fail
    score = max(score, 90) if passed else min(score, 89)
    return {"pass": passed, "score": score, "fails": fails, "issues": [t for _, t in issues]}


# ---------------------------------------------------------------- report


def _md(s):
    return str(s).replace("|", "\\|").replace("\n", " ")


def render_markdown(screen, r, heatmap_name):
    ev, th, px, c = r["evaluation"], r["thresholds"], r["pixels"], r["counts"]
    L = [
        f"# Parity: `{screen}`",
        "",
        f"**{'PASS' if ev['pass'] else 'FAIL'}**, score **{ev['score']}/100**",
        "",
        f"Screen {r['screen_size'][0]}x{r['screen_size'][1]} px. Nodes: official {c['official']}, ours {c['ours']}, "
        f"matched {c['matched']}, missing {c['missing']}, extra {c['extra']}.",
        "",
        f"Pixel diff (background ignored): **{px['diff_pct']:.2f}%** of {px['compared_px']} compared element pixels "
        f"(limit {th['pixel_pct']}%). Dominant background: official rgb{tuple(px['background_official'])}, "
        f"ours rgb{tuple(px['background_ours'])}.",
        "",
        f"Thresholds: position/size within {th['pos_px']:g} px or {th['pos_pct']:g}%, pixel delta {th['pixel_delta']}, "
        f"bg tolerance {th['bg_tol']}, match radius {th['match_radius_pct']:g}% of diagonal.",
        "",
        f"![heatmap]({heatmap_name})",
        "",
        "Heatmap: red = differing element pixels, yellow box = missing in ours, magenta box = extra in ours, "
        "cyan/blue boxes = official/ours bounds of out-of-tolerance elements.",
        "",
        "## Issues",
        "",
    ]
    L += [f"- {_md(t)}" for t in ev["issues"]] or ["- none"]
    for title, key, col in (("Missing in ours", "missing", "official bounds"), ("Extra in ours", "extra", "ours bounds")):
        L += ["", f"## {title}", ""]
        if r[key]:
            L += [f"| element | interactive | {col} |", "|---|---|---|"]
            L += [f"| {_md(n['short'])} | {n['interactive']} | {n['bounds']} |" for n in r[key]]
        else:
            L.append("none")
    L += [
        "",
        "## Matched elements",
        "",
        "| element | dx | dy | dw | dh | font px (official/ours) | state | text | ok |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for m in r["matched"]:
        d, p = m["delta_px"], m["delta_pct"]
        cells = " | ".join(f"{d[k]:+d} ({p[k]:+.2f}%)" for k in ("dx", "dy", "dw", "dh"))
        font = f"{m['font']['official_px']}/{m['font']['ours_px']}" if m["font"] else ""
        state = "; ".join(f"{k}: {v[0]} -> {v[1]}" for k, v in m["state_diff"].items())
        text = f"{m['text_diff'][0]!r} -> {m['text_diff'][1]!r}" if m["text_diff"] else ""
        ok = "yes" if m["within_tolerance"] and not m["state_diff"] else "**no**"
        L.append(f"| {_md(m['official']['short'])} | {cells} | {font} | {_md(state)} | {_md(text)} | {ok} |")
    L.append("")
    return "\n".join(L)


# ---------------------------------------------------------------- entry points


def screen_paths(root, screen):
    root = Path(root)
    return {
        "official_png": root / "reference" / f"{OFFICIAL_PREFIX}{screen}.png",
        "official_xml": root / "reference" / f"{OFFICIAL_PREFIX}{screen}.xml",
        "ours_png": root / "current" / f"{OURS_PREFIX}{screen}.png",
        "ours_xml": root / "current" / f"{OURS_PREFIX}{screen}.xml",
    }


def diff_screen(screen, official_png, official_xml, ours_png, ours_xml, out_dir, th=None, keep_system=False):
    th = th or Thresholds()
    off_img, our_img = load_rgb(official_png), load_rgb(ours_png)
    h, w = off_img.shape[:2]
    size_issue = None
    if our_img.shape != off_img.shape:
        size_issue = (
            f"screenshot size differs: official {w}x{h}, ours {our_img.shape[1]}x{our_img.shape[0]} "
            "(capture on the same display and density)"
        )
        our_img = np.asarray(Image.fromarray(our_img.astype(np.uint8)).resize((w, h)), dtype=np.int16)
    off_nodes = parse_xml(official_xml, w, h, keep_system)
    our_nodes = parse_xml(ours_xml, w, h, keep_system)
    layout = compare_layout(off_nodes, our_nodes, w, h, th)
    matched, missing, extra = layout
    pixels, differ = compare_pixels(off_img, our_img, off_nodes, our_nodes, matched, th)
    result = {
        "screen": screen,
        "screen_size": [w, h],
        "inputs": {
            "official_png": Path(official_png).name,
            "official_xml": Path(official_xml).name,
            "ours_png": Path(ours_png).name,
            "ours_xml": Path(ours_xml).name,
        },
        "thresholds": asdict(th),
        "counts": {
            "official": len(off_nodes),
            "ours": len(our_nodes),
            "matched": len(matched),
            "missing": len(missing),
            "extra": len(extra),
        },
        "evaluation": evaluate(layout, pixels, th, size_issue),
        "pixels": pixels,
        "missing": missing,
        "extra": extra,
        "matched": matched,
        "heatmap": f"{screen}-heatmap.png",
    }
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    moved = [m for m in matched if not m["within_tolerance"]]
    write_heatmap(out / result["heatmap"], off_img, differ, missing, extra, moved)
    (out / f"{screen}.json").write_text(json.dumps(result, indent=2) + "\n")
    (out / f"{screen}.md").write_text(render_markdown(screen, result, result["heatmap"]))
    return result


def add_threshold_args(p):
    d = Thresholds()
    p.add_argument("--pos-px", type=float, default=d.pos_px, help="position/size tolerance in px (default %(default)s)")
    p.add_argument("--pos-pct", type=float, default=d.pos_pct, help="or in %% of the screen dimension (default %(default)s)")
    p.add_argument("--pixel-pct", type=float, default=d.pixel_pct, help="max %% differing element pixels (default %(default)s)")
    p.add_argument("--pixel-delta", type=int, default=d.pixel_delta, help="per-channel delta of a differing pixel (default %(default)s)")
    p.add_argument("--bg-tol", type=int, default=d.bg_tol, help="per-channel background tolerance (default %(default)s)")
    p.add_argument("--match-radius-pct", type=float, default=d.match_radius_pct,
                   help="positional match radius, %% of screen diagonal (default %(default)s)")
    p.add_argument("--fail-on-missing-any", action="store_true", help="also fail on missing/extra non-interactive nodes")
    p.add_argument("--keep-system", action="store_true", help="keep com.android.systemui nodes")


def thresholds_from(args):
    return Thresholds(
        pos_px=args.pos_px,
        pos_pct=args.pos_pct,
        pixel_pct=args.pixel_pct,
        pixel_delta=args.pixel_delta,
        bg_tol=args.bg_tol,
        match_radius_pct=args.match_radius_pct,
        fail_on_missing_any=args.fail_on_missing_any,
    )


def summary_line(r):
    ev = r["evaluation"]
    return (
        f"{r['screen']}: {'PASS' if ev['pass'] else 'FAIL'} score={ev['score']} "
        f"pixel_diff={r['pixels']['diff_pct']:.2f}% matched={r['counts']['matched']} "
        f"missing={r['counts']['missing']} extra={r['counts']['extra']}"
    )


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("screen", help="screen name: files official-<screen>.png/.xml and z0agent-<screen>.png/.xml")
    p.add_argument("--root", default="docs/parity", help="parity root holding reference/ and current/")
    p.add_argument("--out", default=None, help="report dir (default <root>/report)")
    p.add_argument("--official-png")
    p.add_argument("--official-xml")
    p.add_argument("--ours-png")
    p.add_argument("--ours-xml")
    add_threshold_args(p)
    args = p.parse_args(argv)
    paths = screen_paths(args.root, args.screen)
    for k in list(paths):
        if getattr(args, k):
            paths[k] = Path(getattr(args, k))
    absent = [str(v) for v in paths.values() if not Path(v).is_file()]
    if absent:
        print("parity_diff: missing input(s): " + ", ".join(absent), file=sys.stderr)
        return 2
    out = args.out or str(Path(args.root) / "report")
    r = diff_screen(args.screen, out_dir=out, th=thresholds_from(args), keep_system=args.keep_system, **paths)
    print(summary_line(r))
    for t in r["evaluation"]["issues"][:10]:
        print(f"  - {t}")
    print(f"  report: {Path(out) / (args.screen + '.md')}")
    return 0 if r["evaluation"]["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
