#!/usr/bin/env python3
"""Write the website's performance page from benchmark results.

  page.py                       current run v0.66, history v0.62..v0.66
  page.py --current v0.66 --history v0.62,v0.63,v0.64,v0.65,v0.66

The current run supplies the four-language comparison; the history runs supply
how xc's own times moved from release to release (their xc sources are the
same, so their xc times compare directly). The charts are inline SVG drawn in
the page's text colour, so they follow the site's light and dark themes.
"""

import argparse
import json
import math
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
PAGE = os.path.join(REPO, "website", "site", "src", "content", "docs", "compiler", "performance.md")
SOURCES_PAGE = os.path.join(REPO, "website", "site", "src", "content", "docs", "compiler", "benchmark-sources.mdx")
SOURCES_URL = "/compiler/benchmark-sources/"
SRC_FILES = (("xc", "xc", "c"), ("m", "Objective-C", "objc"), ("cpp", "C++", "cpp"), ("swift", "Swift", "swift"))

LANGS = (("objc", "Objective-C", "#d4a017"), ("cpp", "C++", "#3b82f6"), ("swift", "Swift", "#e5534b"))
PLATFORMS = (("arm64", ""), ("x86-64", "_x86_64"))
# Benchmarks whose sources changed in a way that makes their earlier times
# incomparable, and the release from which their times are comparable again.
CHANGED_IN = {"arc_alloc": "v0.64-langs", "method_call": "v0.64-langs"}
# Benchmarks quoted on their own, outside the geometric means: one kernel the
# compiler recognises and replaces would otherwise swing a mean that stands
# for general code.
SEPARATE = ("matrix_mul_f32",)


def general(cur):
    return {b: d for b, d in cur.items() if b not in SEPARATE}


def load(v):
    with open(os.path.join(ROOT, v, "results.json")) as fh:
        return json.load(fh)["net"]


def gmean(xs):
    xs = [x for x in xs if x and x > 0]
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else None


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def secs(t):
    """A time for prose: milliseconds below a second, else seconds."""
    return "%d ms" % round(t * 1000) if t < 1 else "%.1f s" % t


def ratio_rows(cur, suffix):
    """(worst ratio, benchmark, {language: xc's time over its}) per benchmark."""
    rows = []
    for b, d in cur.items():
        d = d["O3"]
        x = d.get("xc" + suffix)
        rs = {l: x / d[l + suffix] for l, _, _ in LANGS if x and d.get(l + suffix)}
        best = max(rs.values()) if rs else 0
        rows.append((best, b, rs))
    return rows


def ratio_chart(cur, suffix, title, order=None):
    """One row per benchmark: xc's time over each language's, on a log scale.
    `order` fixes the rows (the latest release's), so a release's chart has
    its dots, not its rows, in different places."""
    rows = ratio_rows(cur, suffix)
    if order:
        byname = {r[1]: r for r in rows}
        rows = [byname.get(b, (0, b, {})) for b in order]
    else:
        rows.sort(key=lambda r: -r[0])
    w, left, right, top, rowh = 720, 132, 704, 44, 19
    lo, hi = -3.0, 3.0                       # log2 range: 1/8 .. 8
    h = top + rowh * len(rows) + 30
    def px(r):
        v = max(lo, min(hi, math.log2(r)))
        return left + (v - lo) / (hi - lo) * (right - left)
    o = ['<figure class="xc-chart"><svg viewBox="0 0 %d %d" width="100%%" role="img" '
         'aria-label="%s" style="max-width:%dpx;height:auto;font:12px system-ui,sans-serif">' % (w, h, esc(title), w)]
    o.append('<title>%s</title>' % esc(title))
    # legend
    lx = left
    for l, name, col in LANGS:
        o.append('<circle cx="%d" cy="14" r="5" fill="%s"/>' % (lx, col))
        o.append('<text x="%d" y="18" fill="currentColor">xc ÷ %s</text>' % (lx + 9, esc(name)))
        lx += 130
    # grid and axis
    for k in range(int(lo), int(hi) + 1):
        x = px(2.0 ** k)
        o.append('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" stroke="currentColor" stroke-opacity="%s"/>'
                 % (x, top - 8, x, top + rowh * len(rows), "0.55" if k == 0 else "0.15"))
        lab = "1×" if k == 0 else ("%d×" % (2 ** k) if k > 0 else "1/%d" % (2 ** -k))
        o.append('<text x="%.1f" y="%d" text-anchor="middle" fill="currentColor" fill-opacity="0.75">%s</text>'
                 % (x, top + rowh * len(rows) + 16, lab))
    o.append('<text x="%d" y="%d" fill="currentColor" fill-opacity="0.75">← xc faster</text>'
             % (left, top + rowh * len(rows) + 28))
    o.append('<text x="%d" y="%d" text-anchor="end" fill="currentColor" fill-opacity="0.75">xc slower →</text>'
             % (right, top + rowh * len(rows) + 28))
    for i, (_, b, rs) in enumerate(rows):
        y = top + i * rowh + rowh / 2
        o.append('<a href="%s#%s"><text x="%d" y="%.1f" text-anchor="end" fill="currentColor" '
                 'style="font-family:ui-monospace,monospace;text-decoration:underline;text-decoration-thickness:1px">%s'
                 '<title>%s: the four programs</title></text></a>' % (SOURCES_URL, b, left - 8, y + 4, esc(b), esc(b)))
        if rs:
            xs = [px(r) for r in rs.values()]
            o.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="currentColor" stroke-opacity="0.3"/>'
                     % (min(xs), y, max(xs), y))
        for l, name, col in LANGS:
            if l in rs:
                o.append('<circle cx="%.1f" cy="%.1f" r="4.5" fill="%s"><title>%s: xc ÷ %s = %.2f</title></circle>'
                         % (px(rs[l]), y, col, esc(b), esc(name), rs[l]))
    o.append('</svg><figcaption>%s</figcaption></figure>' % esc(title))
    return "".join(o)


def version_switch(hist, suffix, title, versions, key):
    """The per-benchmark chart for each release, one shown at a time, chosen
    by a row of release labels (the latest at first). CSS only: each label is
    a radio button's, and the checked one's chart is displayed."""
    latest = versions[-1]
    order = [r[1] for r in sorted(ratio_rows(hist[latest], suffix), key=lambda r: -r[0])]
    tag = lambda v: "%s-%s" % (key, v.lstrip("v").replace(".", "-"))
    o = ['<div class="xc-versions">']
    for v in versions:
        o.append('<input type="radio" name="%s" id="%s"%s>' % (key, tag(v), " checked" if v == latest else ""))
    o.append('<div class="xc-version-labels" role="group" aria-label="Release">Release:')
    for v in versions:
        o.append('<label for="%s">%s</label>' % (tag(v), v.lstrip("v")))
    o.append('</div>')
    for v in versions:
        o.append('<div class="xc-version %s">%s</div>'
                 % (tag(v), ratio_chart(hist[v], suffix, "%s (%s)" % (title, v.lstrip("v")), order)))
    o.append('</div>')
    css = [".xc-versions>input{position:absolute;opacity:0;width:1px;height:1px}",
           ".xc-versions .xc-version{display:none}",
           ".xc-version-labels{display:flex;flex-wrap:wrap;gap:.35rem;align-items:center;margin:.25rem 0 .5rem;font-size:.9em}",
           ".xc-version-labels label{margin:0;cursor:pointer;padding:.1rem .55rem;border:1px solid currentColor;border-radius:999px;opacity:.6}"]
    for v in versions:
        t = tag(v)
        css.append("#%s:checked~.%s{display:block}" % (t, t))
        css.append("#%s:checked~.xc-version-labels label[for=%s]{opacity:1;font-weight:600}" % (t, t))
        css.append("#%s:focus-visible~.xc-version-labels label[for=%s]{outline:2px solid currentColor;outline-offset:2px}" % (t, t))
    o.append('<style>%s</style>' % "".join(css))
    return "".join(o)


def history_chart(hist, suffix, title, versions):
    """xc's own time per benchmark, relative to the first release shown."""
    first = versions[0]
    series = {}
    for b in hist[first]:
        vals = []
        for v in versions:
            d = hist[v].get(b, {}).get("O3", {})
            vals.append(d.get("xc" + suffix))
        if vals[0]:
            series[b] = [None if x is None else x / vals[0] for x in vals]
    geo = [gmean([s[i] for b, s in series.items() if s[i] and b not in SEPARATE]) for i in range(len(versions))]
    w, h, left, right, top, bottom = 720, 300, 60, 560, 24, 262
    # The y range fits the data, kept at least 0.8..1.25 so a quiet history
    # still reads as quiet rather than being stretched into drama.
    allr = [r for s in series.values() for r in s if r]
    lo = min(math.log2(0.8), math.log2(min(allr)) - 0.05)
    hi = max(math.log2(1.25), math.log2(max(allr)) + 0.05)
    def py(r):
        v = max(lo, min(hi, math.log2(r)))
        return bottom - (v - lo) / (hi - lo) * (bottom - top)
    def px(i):
        return left + i * (right - left) / max(1, len(versions) - 1)
    o = ['<figure class="xc-chart"><svg viewBox="0 0 %d %d" width="100%%" role="img" aria-label="%s" '
         'style="max-width:%dpx;height:auto;font:12px system-ui,sans-serif">' % (w, h, esc(title), w)]
    o.append('<title>%s</title>' % esc(title))
    ticks = [t for t in (0.25, 0.33, 0.5, 0.67, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0, 3.0)
             if lo <= math.log2(t) <= hi]
    for r in ticks:
        y = py(r)
        o.append('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="currentColor" stroke-opacity="%s"/>'
                 % (left, y, right, y, "0.55" if r == 1.0 else "0.15"))
        o.append('<text x="%d" y="%.1f" text-anchor="end" fill="currentColor" fill-opacity="0.75">%.2f×</text>'
                 % (left - 6, y + 4, r))
    for i, v in enumerate(versions):
        o.append('<text x="%.1f" y="%d" text-anchor="middle" fill="currentColor">%s</text>'
                 % (px(i), bottom + 20, esc(v.lstrip("v"))))
    labels = []
    for b, s in sorted(series.items()):
        pts = [(px(i), py(r)) for i, r in enumerate(s) if r]
        o.append('<polyline points="%s" fill="none" stroke="currentColor" stroke-opacity="0.28" '
                 'stroke-width="1.2"><title>%s: %s</title></polyline>'
                 % (" ".join("%.1f,%.1f" % p for p in pts), esc(b),
                    ", ".join("%.2f" % r for r in s if r)))
        if s[-1] and abs(math.log2(s[-1])) > math.log2(1.12):
            labels.append((py(s[-1]), b, s[-1]))
    gpts = [(px(i), py(r)) for i, r in enumerate(geo) if r]
    o.append('<polyline points="%s" fill="none" stroke="#3b82f6" stroke-width="3"/>'
             % " ".join("%.1f,%.1f" % p for p in gpts))
    for (x, y), r in zip(gpts, [g for g in geo if g]):
        o.append('<circle cx="%.1f" cy="%.1f" r="4" fill="#3b82f6"/>' % (x, y))
        o.append('<text x="%.1f" y="%.1f" text-anchor="middle" fill="#3b82f6" '
                 'style="font-weight:600">%.2f</text>' % (x, y - 9, r))
    labels.sort()
    last = -99
    for y, b, r in labels:
        y = max(y, last + 13)
        last = y
        o.append('<text x="%d" y="%.1f" fill="currentColor" fill-opacity="0.8" '
                 'style="font-family:ui-monospace,monospace">%s %.2f×</text>' % (right + 8, y + 4, esc(b), r))
    o.append('<text x="%d" y="%d" fill="#3b82f6">geometric mean</text>' % (left + 4, top + 12))
    o.append('</svg><figcaption>%s</figcaption></figure>' % esc(title))
    return "".join(o)


def table(cur, suffix):
    rows = []
    for b, d in cur.items():
        d = d["O3"]
        x = d.get("xc" + suffix)
        others = [d[l + suffix] for l, _, _ in LANGS if d.get(l + suffix)]
        rows.append((x / min(others) if x and others else 0, b, d))
    rows.sort(key=lambda r: -r[0])
    out = ["| benchmark | xc | Objective-C | C++ | Swift | xc ÷ fastest |", "|---|---|---|---|---|---|"]
    for r, b, d in rows:
        cells = ["%.2f" % d[k + suffix] if d.get(k + suffix) else "–" for k in ("xc", "objc", "cpp", "swift")]
        out.append("| [`%s`](%s#%s) | %s | **%.2f** |" % (b, SOURCES_URL, b, " | ".join(cells), r))
    return "\n".join(out)


def summary(cur):
    out = ["| xc's time ÷ | arm64 | x86-64 |", "|---|---|---|"]
    for l, name, _ in LANGS:
        vals = []
        for _, suf in PLATFORMS:
            vals.append(gmean([d["O3"]["xc" + suf] / d["O3"][l + suf] for d in general(cur).values()
                               if d["O3"].get("xc" + suf) and d["O3"].get(l + suf)]))
        out.append("| %s | **%.2f** | **%.2f** |" % (name, vals[0], vals[1]))
    return "\n".join(out)


def separate(cur):
    """The benchmarks kept out of the means, each with its own ratios."""
    out = []
    for b in SEPARATE:
        d = cur.get(b, {}).get("O3", {})
        parts = []
        for pname, suf in PLATFORMS:
            rs = []
            for l, name, _ in LANGS:
                if d.get("xc" + suf) and d.get(l + suf):
                    r = d["xc" + suf] / d[l + suf]
                    rs.append("%s %s" % (name, ("1/%d" % round(1 / r)) if r < 0.5 else ("%.2f" % r)))
            if rs:
                parts.append("on %s, %s" % (pname, ", ".join(rs)))
        if parts:
            out.append("There xc's time divided by each language's is, %s." % "; ".join(parts))
    return " ".join(out)


def standing(cur):
    """One sentence per target: which languages xc is ahead of and behind, from
    the same geometric means as the summary table, so it cannot go stale."""
    def join(names):
        return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]
    parts = []
    for pname, suf in PLATFORMS:
        ahead, behind = [], []
        for l, name, _ in LANGS:
            g = gmean([d["O3"]["xc" + suf] / d["O3"][l + suf] for d in general(cur).values()
                       if d["O3"].get("xc" + suf) and d["O3"].get(l + suf)])
            (ahead if g < 1.0 else behind).append(name)
        if not behind:
            parts.append("On %s xc is ahead of all three." % pname)
        elif not ahead:
            parts.append("On %s xc is behind all three." % pname)
        else:
            parts.append("On %s xc is ahead of %s and behind %s." % (pname, join(ahead), join(behind)))
    return " ".join(parts)


PAR_MACHINES = (("mac", "Apple silicon, Metal"), ("linux", "Zen 5 Linux, CPU only"),
                ("windows", "Windows, NVIDIA RTX 3090"))


def ms(us):
    return "%.1f" % (us / 1000.0) if us < 100000 else "%.0f" % (us / 1000.0)


def par_tables(version):
    """The par benchmarks (benchmark/par/run.py): milliseconds for the best of
    eight runs of each block, per machine and device, and the first run's."""
    path = os.path.join(ROOT, "par", version, "results.json")
    if not os.path.exists(path):
        return "*(not measured for this release)*"
    with open(path) as fh:
        res = json.load(fh)
    out = []
    for m, name in PAR_MACHINES:
        rows = [(b, r[m]) for b, r in sorted(res.items()) if m in r]
        if not rows:
            continue
        gpu = any("gpu" in r for _, r in rows)
        out.append("**%s** (ms; best of eight runs)\n" % name)
        if gpu:
            out.append("| benchmark | one thread | all threads | GPU | `auto` | GPU's first run |")
            out.append("|---|---|---|---|---|---|")
        else:
            out.append("| benchmark | one thread | all threads | `auto` |")
            out.append("|---|---|---|---|")
        for b, r in rows:
            cells = ["[`%s`](%s#%s)" % (b, SOURCES_URL, b), ms(r["serial"]["best_us"]), ms(r["cpu"]["best_us"])]
            if gpu:
                cells.append(ms(r["gpu"]["best_us"]) if "gpu" in r else "–")
            cells.append(ms(r["auto"]["best_us"]))
            if gpu:
                cells.append(ms(r["gpu"]["first_us"]) if "gpu" in r else "–")
            out.append("| " + " | ".join(cells) + " |")
        out.append("")
    return "\n".join(out)


def sources_page(names):
    """Every benchmark's four programs, one section each, the languages in
    tabs that stay in step (choosing xc once shows xc everywhere)."""
    o = [SOURCES_HEAD]
    for b in sorted(names):
        texts = {}
        for ext, name, lang in SRC_FILES:
            path = os.path.join(ROOT, "src", "%s.%s" % (b, ext))
            if os.path.exists(path):
                with open(path) as fh:
                    texts[ext] = fh.read().rstrip("\n")
        if "xc" not in texts:
            continue
        first = texts["xc"].split("\n", 1)[0]
        what = first.split(" — ", 1)[1] if " — " in first else ""
        o.append("## %s\n" % b)
        if what:
            o.append(what[0].upper() + what[1:] + "\n")
        counts = ", ".join("%s %d" % (name, texts[ext].count("\n") + 1) for ext, name, _ in SRC_FILES if ext in texts)
        o.append("Lines: %s.\n" % counts)
        o.append('<Tabs syncKey="bench-lang">')
        for ext, name, lang in SRC_FILES:
            if ext in texts:
                o.append('<TabItem label="%s">\n\n```%s\n%s\n```\n\n</TabItem>' % (name, lang, texts[ext]))
        o.append("</Tabs>\n")
    # The par benchmarks: xc only (each is one program, its blocks run on the
    # CPU's threads or the GPU as the runtime chooses).
    o.append(PAR_SOURCES_HEAD)
    for path in sorted(f for f in os.listdir(os.path.join(ROOT, "par")) if f.endswith(".xc")):
        b = path[:-3]
        with open(os.path.join(ROOT, "par", path)) as fh:
            text = fh.read().rstrip("\n")
        first = text.split("\n", 1)[0]
        what = first.split(" — ", 1)[1] if " — " in first else ""
        o.append("### %s\n" % b)
        if what:
            o.append(what[0].upper() + what[1:] + "\n")
        o.append("Lines: %d.\n" % (text.count("\n") + 1))
        o.append("```c\n%s\n```\n" % text)
    with open(SOURCES_PAGE, "w") as fh:
        fh.write("\n".join(o) + "\n")
    print("wrote", os.path.relpath(SOURCES_PAGE, REPO))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--current", default="v0.71")
    ap.add_argument("--history", default="v0.62,v0.63,v0.64,v0.65,v0.66,v0.7,v0.71")
    ap.add_argument("--release", default="0.71")
    a = ap.parse_args()
    cur = load(a.current)
    versions = a.history.split(",")
    hist = {v: load(v) for v in versions}
    for b, since in CHANGED_IN.items():
        if since not in versions:
            for v in versions:
                hist[v].pop(b, None)

    page = PAGE_TEMPLATE.format(
        release=a.release,
        summary=summary(cur),
        standing=standing(cur),
        separate=separate(cur),
        mm_arm=secs(cur["matrix_mul_f32"]["O3"]["xc"]),
        mm_arm_cpp=secs(cur["matrix_mul_f32"]["O3"]["cpp"]),
        mm_x86=secs(cur["matrix_mul_f32"]["O3"]["xc_x86_64"]),
        mm_x86_cpp=secs(cur["matrix_mul_f32"]["O3"]["cpp_x86_64"]),
        chart_arm=version_switch(hist, "", "arm64: xc's time divided by each language's, per benchmark", versions, "vs-arm"),
        chart_x86=version_switch(hist, "_x86_64", "x86-64: xc's time divided by each language's, per benchmark", versions, "vs-x86"),
        table_arm=table(cur, ""),
        table_x86=table(cur, "_x86_64"),
        hist_arm=history_chart(hist, "", "arm64: xc's time relative to %s" % versions[0].lstrip("v"), versions),
        hist_x86=history_chart(hist, "_x86_64", "x86-64: xc's time relative to %s" % versions[0].lstrip("v"), versions),
        first=versions[0].lstrip("v"),
        hist_list=", ".join(v.lstrip("v") for v in versions),
        changed=", ".join("`%s`" % b for b in sorted(CHANGED_IN)),
        par=par_tables(a.current),
    )
    with open(PAGE, "w") as fh:
        fh.write(page)
    print("wrote", os.path.relpath(PAGE, REPO))
    sources_page(cur.keys())


SOURCES_HEAD = """---
title: Benchmark sources
description: Every program the performance page measures, in xc, Objective-C, C++ and Swift, side by side.
---

import { Tabs, TabItem } from '@astrojs/starlight/components';

These are the programs behind the [performance](/compiler/performance/) figures,
each written four times with the same algorithm and the same data. Choose a
language on any of them and every one switches to it.

The xc versions are plain loops over arrays and objects. None of them asks for
vector instructions, threads, a matrix unit or anything else by name: where
`matrix_mul_f32` runs on Apple's SME matrix unit, or `array_map` on AVX-512,
it is because xcc saw the loop and chose to.

Each program times its own work with `bench_now_us()` (the monotonic clock) and
prints a checksum, which must agree across the four languages for a run to
count.
"""


PAR_SOURCES_HEAD = """## Parallel blocks and the GPU

The programs behind the performance page's GPU tables. Each is one xc program:
its work is a `par` block, a loop whose iterations are independent, and the
runtime runs it on the CPU's threads or on the GPU (Metal on a Mac, CUDA on
Windows), whichever it finds faster. Nothing in the source
names a device, a kernel language or a thread.
"""


PAGE_TEMPLATE = """---
title: Performance
description: How xcc-compiled code compares with clang's Objective-C and C++ and with Swift on the same programs, measured on twenty benchmarks across arm64 and x86-64.
---

The compiler is measured on twenty programs, each written four times: in the
xc language, in Objective-C with ARC, in C++ and in Swift, doing the same work
with the same algorithm and the same data. All are built with optimisation
(`-O3` for xc, Objective-C and C++, `-O` for Swift), every version prints a
checksum, and a run only counts if all four checksums agree. Every program, in
all four languages, is on the [benchmark sources](/compiler/benchmark-sources/)
page; each benchmark's name below links to its own.

Each figure is measured with the released {release} `xcc`, on an Apple-silicon
Mac (arm64) and a Zen 5 Linux machine (x86-64). Times are seconds for the timed
region, the best of five runs, each run waiting until the machine is otherwise
idle.

## Summary

Geometric mean, over nineteen of the twenty benchmarks, of xc's time divided by
the other language's. **Below 1 is xc faster.**

{summary}

The twentieth, `matrix_mul_f32`, is quoted on its own. xcc recognises its loop
nest and replaces it with a matrix kernel (SME on Apple silicon, SSE or AVX on
x86-64), which makes xc so much faster at that one operation that putting it
in with the others would skew the means in xc's favour, and most programs do
not multiply 2D matrices. {separate} From 0.72 its outer
loop is marked [`:goal(speed)`](/compiler/language/statements/#speed-or-accuracy-goal),
which lets the SME kernel leave out a NaN check whose only effect is on the
bits of a NaN (the inputs have none); earlier releases were measured without
it.

{standing} The arithmetic mean of ratios
is not given: a benchmark at 2.00× and one at 0.50× are exactly compensating,
and only the geometric mean says so.

## Per benchmark

Each row is a benchmark, each dot one language: how many times as long xc takes
as that language. Dots left of the centre line are benchmarks xc wins. Choose a
release above a chart to see how it stood then; the rows stay in {release}'s
order. Releases before 0.65 were measured against Objective-C alone, apart
from `matrix_mul_f32`, which was added later and measured against all three.

{chart_arm}

{chart_x86}

### arm64

{table_arm}

### x86-64

{table_x86}

The fastest results are where the runtime does the work: `string_scan`,
`method_call` and `struct_copy` are byte scanning, dynamic dispatch and
aggregate copies. The slowest show where xcc's code generation has most to
gain:

- **Vectorisation.** On arm64, `matrix_mul` is vectorised across its outer loop
  but clang also unrolls the inner one completely and keeps every broadcast in
  a register; `int_muldiv` and `float_math` are vectorised by both, and clang's
  loops are tighter.
- **Reference counting and allocation on x86-64.** `arc_alloc` and `arc_array`,
  where C++ makes one allocation per object through a faster allocator and
  reads elements without retaining them.
- **x86-64 loops.** `sieve` and `sort_small`, where the other compilers' loops
  are faster.
- **Dispatch.** `poly_dispatch` on arm64, where clang's call sequence around the
  virtual call is shorter.

## Matrix multiplies

From 0.71 a dense matrix multiply written as three loops — `C[i][j]` the sum
over `k` of `A[i][k] · B[k][j]`, in `float` or `double` — runs as a kernel the
compiler writes itself: on Apple silicon with SME (M4 and later) on the matrix
unit, and on x86-64 with the widest vector unit the processor has (SSE2, AVX2
or AVX-512), chosen when the program starts. The results are the loops', to
the last bit. `matrix_mul_f32` measures it: a 128×128 `float` multiply, 10,000
times. (`matrix_mul` multiplies `u32` values, which the matrix unit's outer
products do not take, so it stays a vectorised loop.) On an Apple M4 Max
it takes {mm_arm} against {mm_arm_cpp} for clang's C++ of the same loops; on an AMD Zen 5
processor, where the program picks AVX-512, {mm_x86} against {mm_x86_cpp}. With
`-fno-matmul` the loops run as written.

## Parallel blocks and the GPU

From 0.7 a [`par` block](/compiler/language/par/) runs a loop's iterations at
once, across every CPU thread or on the GPU. Four programs in `benchmark/par`
measure it: `mandelbrot` (a 2048×2048 escape-time image, at most 256 iterations
a pixel), `perlin` (2048×2048 improved noise, four octaves), `nbody` (the force
on each of 8192 bodies from all the others) and `saxpy` (`y = a·x + y` over 16
million integers, with a sum). Each runs its block
eight times and reports the best run; *one thread* is `XC_PAR=cpu
XC_PAR_THREADS=1`, *all threads* `XC_PAR=cpu`, *GPU* `XC_PAR=gpu`, and `auto` the
default, which times the CPU and the GPU and keeps the faster. Every mode's
checksum must agree.

{par}

The GPU's first run carries one-off costs — building the kernel, and on NVIDIA
creating the driver context and compiling the PTX — so it is shown apart: a few
tens of milliseconds on Metal, a few hundred on NVIDIA. `auto` pays it once,
while it measures. `saxpy` does one multiply-add for every eight bytes it moves, so the
copy to and from the GPU outweighs the arithmetic and `auto` keeps it on the CPU;
the other three do enough work per element that the GPU wins by a wide margin.

## Release to release

xc's own time for each benchmark, relative to {first}. The thin lines are
single benchmarks (labelled where they moved by more than twelve percent), the
thick line the geometric mean (without `matrix_mul_f32`). Releases shown: {hist_list}. {changed} changed in
0.64's benchmark set and are left out of this history.

{hist_arm}

{hist_x86}

## What is being compared, and what is not

**The compiler that ships.** The xc numbers come from the `xcc` in the download.

**The same work in every language.** Every version keeps its data where the xc
version keeps it (local arrays, not `static` ones, which clang optimises
differently) and leaves nothing a compiler can remove: an object that could be
put on the stack outlives its iteration, a call whose target could be resolved
at compile time takes its class at run time, and results are folded in so no
loop has a closed form. Where the original's point is reference-counted
objects, the C++ version uses `std::shared_ptr` and the Swift version a class,
so they pay for reference counting too.

**Different runtimes on the two targets.** The Objective-C column is Apple's
Foundation on arm64 and GNUstep with libobjc2 on x86-64, and Swift is 6.2 on the
Mac and 6.1 on Linux. These are different implementations, so a language's
times compare within a target and not across one. Swift on Linux is markedly
slower on `poly_dispatch` and `array_map` than on the Mac; the runs were
repeated on an idle machine and reproduce.

**Timed regions of about one second.** Each benchmark times its own inner loop
rather than the process, so start-up and data set-up are excluded.

**Alignment noise on x86-64.** xcc aligns every loop head on x86-64 to a 32-byte
boundary and the start of `.text` to 64 bytes, so an unrelated change elsewhere
cannot move a loop across a fetch boundary; see
[Optimisation](/compiler/usage/optimization/#per-target-settings).

## Reproducing

The sources are in `benchmark/src`, one `.xc`, `.m`, `.cpp` and `.swift` per
program, and the runner builds and times them all:

```
python3 benchmark/run.py --opt O3 --repeats 5
python3 benchmark/page.py
```

The x86-64 legs cross-build xc here and build the other languages on the
configured Linux host; without one the runner measures this machine only.
`--langs` measures some of the languages and adds them to the results already
there. Results land in `benchmark/<version>/results.json`, and `page.py` turns
them into this page.
"""

if __name__ == "__main__":
    main()
