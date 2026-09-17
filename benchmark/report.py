#!/usr/bin/env python3
"""Render a benchmark run as a self-contained HTML page.

  report.py                  read <version>/results.json, write <version>/index.html
  report.py --version v0.6   which run to render

The page has no external assets: the CSS is inline and the charts are inline
SVG, so it can be opened from a checkout or folded into the site unchanged.

The optimisation table is read from the compiler source at render time rather
than copied here, so it cannot drift away from what the compiler does.
"""

import argparse
import html
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
PROFILE = os.path.join(REPO, "compiler", "src", "xtc", "ir", "XTIROptTargetProfile.m")
OPTS = ["O0", "O1", "O2", "O3"]
SERIES = (("xc", "#2563eb"), ("objc", "#f59e0b"),
          ("xc_x86_64", "#7c3aed"), ("objc_x86_64", "#059669"))
SERIES_LABEL = {"xc": "xc arm64", "objc": "ObjC arm64",
                "xc_x86_64": "xc x86-64", "objc_x86_64": "ObjC x86-64"}

CSS = """
:root{--ink:#16181d;--dim:#6b7280;--line:#e4e7ec;--bg:#fff;--panel:#f7f8fa;
--xc:#2563eb;--objc:#f59e0b;--good:#15803d;--bad:#b91c1c}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:1040px;margin:0 auto;padding:40px 20px 80px}
h1{font-size:28px;margin:0 0 4px;letter-spacing:-.02em}
h2{font-size:19px;margin:44px 0 12px;letter-spacing:-.01em}
.sub{color:var(--dim);margin:0 0 28px}
.meta{display:flex;gap:28px;flex-wrap:wrap;background:var(--panel);
border:1px solid var(--line);border-radius:10px;padding:14px 18px;margin:0 0 8px}
.meta div{font-size:13px}.meta b{display:block;color:var(--dim);font-weight:500}
table{border-collapse:collapse;width:100%;font-size:14px;margin:8px 0 4px}
th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line)}
th{font-weight:600;font-size:12px;letter-spacing:.04em;text-transform:uppercase;
color:var(--dim)}
td.n{text-align:right;font-variant-numeric:tabular-nums}
tr:hover td{background:var(--panel)}
.y{color:var(--good);font-weight:600}.n0{color:var(--dim)}
.win{color:var(--good);font-weight:600}.lose{color:var(--bad);font-weight:600}
.legend{display:flex;gap:18px;align-items:center;font-size:13px;color:var(--dim);
margin:6px 0 16px}
.sw{display:inline-block;width:11px;height:11px;border-radius:2px;margin-right:6px;
vertical-align:-1px}
.note{font-size:13px;color:var(--dim);margin:10px 0 0}
.chart{border:1px solid var(--line);border-radius:10px;padding:10px 6px;margin:0 0 10px}
"""


def profile_table():
    """Per-target optimisation knobs, parsed from the compiler source."""
    if not os.path.isfile(PROFILE):
        return [], {}
    text = open(PROFILE, encoding="utf-8", errors="ignore").read()
    knobs, order, table, cls = {}, [], {}, None
    pending = None
    for line in text.splitlines():
        m = re.match(r"^@implementation\s+XTIR(\w+?)TargetProfile", line)
        if m:
            cls = m.group(1)
            if cls == "Opt":
                cls = "base"
            table.setdefault(cls, {})
            continue
        m = re.match(r"^\s*-\s*\(BOOL\)(\w+)", line)
        if m:
            pending = m.group(1)
            continue
        m = re.search(r"\breturn\s+(YES|NO)\s*;", line)
        if m and pending and cls:
            if pending not in knobs:
                knobs[pending] = True
                order.append(pending)
            table[cls][pending] = (m.group(1) == "YES")
            pending = None
    return order, table


def svg_chart(name, per_opt):
    """Grouped bars, xc against objc, one group per optimisation level."""
    W, H, PAD_L, PAD_B, PAD_T = 660, 210, 54, 30, 14
    plot_w, plot_h = W - PAD_L - 12, H - PAD_B - PAD_T
    vals = [v for o in OPTS for v in per_opt.get(o, {}).values()]
    vmax = max(vals) if vals else 1.0
    vmax = vmax if vmax > 0 else 1.0
    out = ['<svg class="chart" viewBox="0 0 %d %d" width="100%%" '
           'xmlns="http://www.w3.org/2000/svg" role="img" '
           'aria-label="%s timings">' % (W, H, html.escape(name))]
    for f in (0, .25, .5, .75, 1):
        y = PAD_T + plot_h - f * plot_h
        out.append('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="#e4e7ec"/>'
                   % (PAD_L, y, W - 12, y))
        out.append('<text x="%d" y="%.1f" font-size="10" fill="#6b7280" '
                   'text-anchor="end">%.3fs</text>' % (PAD_L - 6, y + 3, vmax * f))
    gw = plot_w / max(len(OPTS), 1)
    for gi, opt in enumerate(OPTS):
        langs = per_opt.get(opt, {})
        gx = PAD_L + gi * gw
        out.append('<text x="%.1f" y="%d" font-size="11" fill="#6b7280" '
                   'text-anchor="middle">%s</text>'
                   % (gx + gw / 2, H - 10, opt))
        for bi, (lang, colour) in enumerate(SERIES):
            v = langs.get(lang)
            if v is None:
                continue
            bh = (v / vmax) * plot_h
            bw = gw * 0.17
            bx = gx + gw / 2 - 2 * bw - 3 + bi * (bw + 2)
            out.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="2" '
                       'fill="%s"><title>%s %s %.4fs</title></rect>'
                       % (bx, PAD_T + plot_h - bh, bw, bh, colour, lang, opt, v))
    out.append("</svg>")
    return "".join(out)


def main():
    ap = argparse.ArgumentParser(description="render a benchmark run as HTML")
    ap.add_argument("--version", default="v0.6")
    args = ap.parse_args()

    src = os.path.join(ROOT, args.version, "results.json")
    if not os.path.isfile(src):
        sys.exit("no results at %s: run run.py first" % os.path.relpath(src, REPO))
    data = json.load(open(src))
    net = data.get("net", {})

    p = []
    p.append("<!doctype html><meta charset='utf-8'>")
    p.append("<title>xc against Objective-C &middot; %s</title>" % html.escape(args.version))
    p.append("<style>%s</style><div class='wrap'>" % CSS)
    p.append("<h1>xc against Objective-C</h1>")
    p.append("<p class='sub'>The same programs in both languages, both with "
             "automatic reference counting, built at four optimisation levels.</p>")
    p.append("<div class='meta'><div><b>version</b>%s</div><div><b>platform</b>%s</div>"
             "<div><b>runs per point</b>%s</div><div><b>benchmarks</b>%d</div></div>"
             % (html.escape(data.get("version", "")), html.escape(data.get("platform", "")),
                html.escape(str(data.get("repeats", ""))), len(net)))
    p.append("<p class='note'>Each figure is the fastest of the runs. Every program "
             "times its own measured region with clock_gettime(CLOCK_MONOTONIC), so "
             "process startup and data setup are outside the number. Both programs "
             "print a checksum and a run is rejected if they disagree.</p>")
    p.append("<p class='note'>The arm64 Objective-C column is Apple's runtime and "
             "Foundation; the x86-64 column is libobjc2 and gnustep-base. Comparing "
             "a ratio across the two platforms therefore also compares two different "
             "Objective-C implementations, which matters most for the benchmarks "
             "dominated by allocation and dispatch.</p>")

    mism = data.get("mismatches", [])
    if mism:
        p.append("<p class='note lose'>%d checksum mismatch(es): the two programs do "
                 "not compute the same thing, so those timings are not comparable.</p>"
                 % len(mism))

    # ---- summary table -------------------------------------------------
    p.append("<h2>Time by benchmark and optimisation level</h2>")
    p.append("<div class='legend'>" + "".join(
        "<span><i class='sw' style='background:%s'></i>%s</span>" % (c, SERIES_LABEL[k])
        for k, c in SERIES) + "<span>ratio below 1 means xc is faster</span></div>")
    p.append("<table><tr><th>benchmark</th>" +
             "".join("<th colspan='2'>%s</th>" % o for o in OPTS) + "</tr>")
    p.append("<tr><th></th>" + "".join("<th>arm64</th><th>x86-64</th>"
                                       for _ in OPTS) + "</tr>")
    for name in sorted(net):
        row = ["<tr><td>%s</td>" % html.escape(name)]
        for o in OPTS:
            l = net[name].get(o, {})
            for a, b in (("xc", "objc"), ("xc_x86_64", "objc_x86_64")):
                x, oc = l.get(a), l.get(b)
                if x is None or oc is None:
                    row.append("<td class='n'>-</td>")
                    continue
                ratio = (x / oc) if oc else 0.0
                klass = "win" if ratio < 1.0 else ("lose" if ratio > 1.5 else "")
                row.append("<td class='n %s'>%.2f&times;</td>" % (klass, ratio))
        row.append("</tr>")
        p.append("".join(row))
    p.append("</table>")

    # ---- per-benchmark charts -----------------------------------------
    p.append("<h2>Per benchmark</h2>")
    for name in sorted(net):
        p.append("<h3 style='font-size:15px;margin:22px 0 4px'>%s</h3>"
                 % html.escape(name))
        p.append(svg_chart(name, net[name]))

    # ---- optimisation feature matrix ----------------------------------
    order, table = profile_table()
    if order:
        cols = [c for c in ("base", "Arm64", "X86_64", "Arm9", "Wasm32", "M68k", "Xt6502")
                if c in table]
        p.append("<h2>Optimisations by target</h2>")
        p.append("<p class='note'>Read from the compiler's target profiles when this "
                 "page was rendered. A target that does not override a setting takes "
                 "the base value.</p>")
        p.append("<table><tr><th>optimisation</th>" +
                 "".join("<th>%s</th>" % html.escape(c) for c in cols) + "</tr>")
        for knob in order:
            cells = []
            for c in cols:
                v = table[c].get(knob, table.get("base", {}).get(knob))
                cells.append("<td class='%s'>%s</td>"
                             % ("y" if v else "n0", "yes" if v else "no"))
            label = re.sub(r"(?<!^)(?=[A-Z])", " ", knob).lower()
            p.append("<tr><td>%s</td>%s</tr>" % (html.escape(label), "".join(cells)))
        p.append("</table>")

    p.append("</div>")
    out = os.path.join(ROOT, args.version, "index.html")
    with open(out, "w") as fh:
        fh.write("\n".join(p))
    print("report -> %s" % os.path.relpath(out, REPO))
    return 0


if __name__ == "__main__":
    sys.exit(main())
