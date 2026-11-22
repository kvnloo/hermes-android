"""Tests for tools/parity_diff.py and tools/parity_report.py on synthetic fixtures.

    python3 -m pytest -q tools/test_parity_diff.py
"""
import json
import sys
from pathlib import Path

import pytest
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))

import parity_diff as pdiff  # noqa: E402
import parity_fixtures as fx  # noqa: E402
import parity_report  # noqa: E402


def run_case(tmp_path, ours, official=fx.Variant(), case="screen", **th):
    fx.write_pair(tmp_path, case, ours, official)
    paths = pdiff.screen_paths(tmp_path, case)
    return pdiff.diff_screen(case, out_dir=tmp_path / "report", th=pdiff.Thresholds(**th), **paths)


def matched_by_label(r, label):
    return [m for m in r["matched"] if m["official"]["label"] == label][0]


def test_identical_pair_passes(tmp_path):
    r = run_case(tmp_path, fx.Variant())
    ev = r["evaluation"]
    assert ev["pass"] and ev["score"] == 100 and ev["issues"] == []
    assert r["counts"]["missing"] == r["counts"]["extra"] == 0
    assert r["counts"]["matched"] == r["counts"]["official"] == 11
    assert r["pixels"]["diff_pct"] == 0.0 and r["pixels"]["compared_px"] > 100_000
    assert all(m["within_tolerance"] for m in r["matched"])
    # CLI exit code 0 on pass, writes the three artifacts
    assert pdiff.main(["screen", "--root", str(tmp_path)]) == 0
    for name in ("screen.md", "screen.json", "screen-heatmap.png"):
        assert (tmp_path / "report" / name).is_file()


def test_moved_button_fails_with_right_delta(tmp_path):
    r = run_case(tmp_path, fx.Variant(send_dx=-40))
    ev = r["evaluation"]
    assert not ev["pass"] and ev["score"] < 90
    send = matched_by_label(r, "Send")
    assert send["delta_px"] == {"dx": -40, "dy": 0, "dw": 0, "dh": 0}
    assert send["delta_pct"]["dx"] == pytest.approx(-40 / 1080 * 100, abs=1e-3)
    assert not send["within_tolerance"]
    assert ev["fails"]["out_of_tolerance"] == 1 and ev["fails"]["missing_interactive"] == 0
    assert ev["issues"][0].startswith("off by dx=-40px(-3.70%) on button:Send")
    assert pdiff.main(["screen", "--root", str(tmp_path)]) == 1
    md = (tmp_path / "report" / "screen.md").read_text()
    assert "**FAIL**" in md and "-40 (-3.70%)" in md and "![heatmap](screen-heatmap.png)" in md


def test_shift_within_tolerance_passes(tmp_path):
    r = run_case(tmp_path, fx.Variant(send_dx=-3))
    assert r["evaluation"]["pass"]
    assert matched_by_label(r, "Send")["delta_px"]["dx"] == -3
    # the same shift fails when the tolerance is tightened via flags
    r = run_case(tmp_path, fx.Variant(send_dx=-3), pos_px=2, pos_pct=0.1)
    assert not r["evaluation"]["pass"]


def test_missing_element_is_reported(tmp_path):
    r = run_case(tmp_path, fx.Variant(drop_send=True))
    ev = r["evaluation"]
    assert not ev["pass"]
    assert [n["label"] for n in r["missing"]] == ["Send"]
    assert r["missing"][0]["interactive"] and r["missing"][0]["bounds"] == [904, 2140, 1048, 2260]
    assert ev["fails"]["missing_interactive"] == 1
    assert "missing in ours: button:Send" in ev["issues"][0]


def test_extra_element_is_reported(tmp_path):
    extra = [{"bounds": (32, 1900, 400, 2000), "text": "Collapse all"}]
    r = run_case(tmp_path, fx.Variant(extra=extra))
    assert not r["evaluation"]["pass"]
    assert [n["label"] for n in r["extra"]] == ["Collapse all"]
    assert r["evaluation"]["fails"]["extra_interactive"] == 1


def test_background_only_change_passes(tmp_path):
    r = run_case(tmp_path, fx.Variant(background="gradient"))
    ev = r["evaluation"]
    assert ev["pass"], ev["issues"]
    assert r["pixels"]["background_official"] != r["pixels"]["background_ours"]
    assert r["pixels"]["diff_pct"] < 0.5


def test_element_recolour_still_fails_pixel_check(tmp_path):
    # background masking must not hide a real change in element colour
    r = run_case(tmp_path, fx.Variant(background="gradient", accent=(255, 120, 60)))
    ev = r["evaluation"]
    assert not ev["pass"] and ev["fails"]["pixel"]
    assert r["pixels"]["diff_pct"] >= 3.0
    heat = Image.open(tmp_path / "report" / "screen-heatmap.png").convert("RGB")
    assert heat.getpixel((925, 2200))[0] == 255  # send button fill shows red


def test_collapsed_vs_expanded_list_fails(tmp_path):
    r = run_case(tmp_path, fx.Variant(collapsed=True))
    ev = r["evaluation"]
    assert not ev["pass"]
    header = matched_by_label(r, "Sessions, expanded")
    assert header["state_diff"] == {"expanded": [True, False]}
    assert header["text_diff"] is None  # state words are not a text change
    assert ev["fails"]["state_mismatch"] == 1
    assert sorted(n["label"] for n in r["missing"]) == sorted(fx.ROWS)
    assert any(i.startswith("state differs on button:Sessions") for i in ev["issues"][:3])


def test_text_change_is_reported_on_positional_match(tmp_path):
    fx.write_pair(tmp_path, "t", fx.Variant())
    xml = tmp_path / "current" / "z0agent-t.xml"
    xml.write_text(xml.read_text().replace('text="Groceries"', 'text="Shopping"'))
    r = pdiff.diff_screen("t", out_dir=tmp_path / "report", **pdiff.screen_paths(tmp_path, "t"))
    m = matched_by_label(r, "Groceries")
    assert m["text_diff"] == ["Groceries", "Shopping"] and m["within_tolerance"]
    assert r["counts"]["missing"] == 0
    assert "text differs: 'Groceries' vs 'Shopping'" in r["evaluation"]["issues"]


def test_screen_size_mismatch_fails(tmp_path):
    fx.write_pair(tmp_path, "s", fx.Variant())
    png = tmp_path / "current" / "z0agent-s.png"
    Image.open(png).resize((720, 1560)).save(png)
    r = pdiff.diff_screen("s", out_dir=tmp_path / "report", **pdiff.screen_paths(tmp_path, "s"))
    assert not r["evaluation"]["pass"] and r["evaluation"]["fails"]["screen_size"]


def test_parse_xml_filters_nodes(tmp_path):
    p = tmp_path / "d.xml"
    p.write_text(
        '<hierarchy rotation="0"><node class="android.widget.FrameLayout" package="a" bounds="[0,0][100,200]">'
        '<node text="Clock" class="android.widget.TextView" package="com.android.systemui" bounds="[0,0][50,10]"/>'
        '<node text="" content-desc="" class="android.view.View" package="a" clickable="false" bounds="[0,0][100,50]"/>'
        '<node text="Zero" class="android.widget.TextView" package="a" bounds="[10,10][10,40]"/>'
        '<node text="Hidden" class="android.widget.TextView" package="a" visible-to-user="false" bounds="[0,0][9,9]"/>'
        '<node text="" content-desc="Menu, collapsed" class="android.view.View" package="a" clickable="true" bounds="[0,60][100,90]"/>'
        '<node text="" class="android.widget.ImageView" package="a" bounds="[0,100][40,140]"/>'
        '<node text="Hi" class="android.widget.EditText" package="a" bounds="[0,150][100,250]"/>'
        "</node></hierarchy>"
    )
    nodes = pdiff.parse_xml(p, 100, 200)
    assert [(n.role, n.raw_label, n.label) for n in nodes] == [
        ("button", "Menu, collapsed", "menu"),
        ("image", "", ""),
        ("input", "Hi", "hi"),
    ]
    assert nodes[0].state == {"expanded": False}
    assert nodes[2].bounds == (0, 150, 100, 200)  # clipped to the screen
    assert len(pdiff.parse_xml(p, 100, 200, keep_system=True)) == 4


def test_report_runs_every_pair(tmp_path):
    fx.write_pair(tmp_path, "identical", fx.Variant())
    fx.write_pair(tmp_path, "moved-button", fx.Variant(send_dx=-40))
    fx.write_pair(tmp_path, "orphan", fx.Variant())
    (tmp_path / "current" / "z0agent-orphan.png").unlink()
    assert parity_report.main(["--root", str(tmp_path)]) == 1
    readme = (tmp_path / "report" / "README.md").read_text()
    assert "1/3 screens pass." in readme
    assert "| [identical](identical.md) | 100 | PASS | 0.00% | none |" in readme
    assert "| [moved-button](moved-button.md) |" in readme and "off by dx=-40px" in readme
    assert "| orphan | 0 | **FAIL** | n/a | no capture: z0agent-orphan.png |" in readme
    summary = json.loads((tmp_path / "report" / "moved-button.json").read_text())
    assert summary["evaluation"]["pass"] is False
    assert parity_report.main(["--root", str(tmp_path), "--screens", "identical"]) == 0


def test_missing_input_exit_code(tmp_path):
    assert pdiff.main(["nope", "--root", str(tmp_path)]) == 2
