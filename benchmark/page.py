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
import shutil
import re

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
PAGE = os.path.join(REPO, "website", "site", "src", "content", "docs", "compiler", "performance.md")
GPU_PAGE = os.path.join(REPO, "website", "site", "src", "content", "docs", "compiler", "benchmarks", "gpu.md")
NET_PAGE = os.path.join(REPO, "website", "site", "src", "content", "docs", "compiler", "benchmarks", "network.md")
SOURCES_PAGE = os.path.join(REPO, "website", "site", "src", "content", "docs", "compiler", "benchmark-sources.mdx")
SOURCES_URL = "/compiler/benchmark-sources/"
SRC_FILES = (("xc", "xc", "c"), ("m", "Objective-C", "objc"), ("cpp", "C++", "cpp"), ("swift", "Swift", "swift"))

# "gcc" is the C++ source built with GCC: on the Linux host (g++), and from 0.8
# on the Mac too (Homebrew g++-NN). Releases before 0.74 measured no GCC at all,
# and a run may still lack it on a machine without a real GCC, so each use
# guards for a missing entry.
LANGS = (("objc", "Objective-C", "#d4a017"), ("cpp", "C++ (clang)", "#3b82f6"),
         ("gcc", "C++ (GCC)", "#16a34a"), ("swift", "Swift", "#e5534b"))
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


# --mac m3max: the arm64 figures come from benchmark/m3max-<v>/ (measured on
# an M3 Max, so the M4 Max stays free for compiling, 0.87), the x86-64 ones
# from benchmark/<v>/ as before. One machine's figures per target: an arm64
# entry from <v>/ is dropped, never mixed with the M3 Max's, and a release the
# M3 Max has not timed has no arm64 figures.
MAC_TREE = None
MACHINES = {
    None: ("Apple M4 Max", "an Apple MacBook Pro with an M4 Max (12 performance and 4\n  efficiency cores)", True),
    "m3max": ("Apple M3 Max", "an Apple MacBook Pro with an M3 Max (12 performance and 4\n  efficiency cores, a 40-core GPU, no SME matrix unit)", False),
}


def mac_name():
    return MACHINES[MAC_TREE][0]


def merged(v):
    """A release's results.json, its arm64 entries taken from MAC_TREE's when set."""
    with open(os.path.join(ROOT, v, "results.json")) as fh:
        d = json.load(fh)
    if MAC_TREE is None:
        return d
    ap = os.path.join(ROOT, "%s-%s" % (MAC_TREE, v), "results.json")
    arm = None
    if os.path.exists(ap):
        with open(ap) as fh:
            arm = json.load(fh)
    for key in ("net", "raw"):
        tbl = d.get(key, {})
        for b in tbl:
            for o in tbl[b]:
                tbl[b][o] = {l: t for l, t in tbl[b][o].items() if l.endswith("_x86_64")}
        if arm:
            for b, opts in arm.get(key, {}).items():
                for o, langs in opts.items():
                    for l, t in langs.items():
                        if not l.endswith("_x86_64"):
                            tbl.setdefault(b, {}).setdefault(o, {})[l] = t
    tc = d.setdefault("toolchains", {})
    tc.pop("arm64", None)
    if arm and arm.get("toolchains", {}).get("arm64"):
        tc["arm64"] = arm["toolchains"]["arm64"]
    return d


def has_mac(v):
    return MAC_TREE is None or os.path.exists(os.path.join(ROOT, "%s-%s" % (MAC_TREE, v), "results.json"))


def load(v):
    return merged(v)["net"]


def toolchain_notes(v):
    """One clause per machine naming the compilers the results were measured
    against, from the versions run.py recorded; empty for results without them."""
    tc = merged(v).get("toolchains", {})
    def short(s):
        # "Apple clang version 17.0.0 (clang-1700...)" -> "Apple clang 17.0.0";
        # "gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0" -> "GCC 15.2.0"; Swift's
        # "swift-driver version: ... Apple Swift version 6.2 (...)" -> "Swift 6.2".
        if not s:
            return None
        m = re.search(r"Swift version (\d[\d.]*)", s)
        if m:
            return "Swift " + m.group(1)
        m = re.search(r"^g\+\+(?:-\d+)? .*?(\d+\.\d+\.\d+)\s*$", s)
        if m:
            return "GCC " + m.group(1)
        m = re.search(r"^(Apple|Ubuntu)? ?clang version (\d[\d.]*)", s)
        if m:
            return ("Apple clang " if m.group(1) == "Apple" else "clang ") + m.group(2)
        return s
    out = {}
    for plat, order in (("arm64", ("clang", "gcc", "swiftc")), ("x86_64", ("gcc", "clang", "swiftc"))):
        names = [short(tc.get(plat, {}).get(k)) for k in order]
        names = [n for n in names if n]
        out[plat] = ("; " + ", ".join(names[:-1]) + " and " + names[-1]) if len(names) > 1 else ("; " + names[0] if names else "")
    return out


def gmean(xs):
    xs = [x for x in xs if x and x > 0]
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else None


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def secs(t):
    """A time for prose: milliseconds below a second, else seconds."""
    return "%d ms" % round(t * 1000) if t < 1 else "%.1f s" % t


def speed(r):
    """xc's time over another's as a multiple a reader takes in at once:
    "1.33× faster" (r = 0.75), "1.20× slower" (r = 1.2), "327× faster"."""
    if r is None or r <= 0:
        return "–"
    if abs(r - 1) < 0.005:
        return "the same"
    m = 1 / r if r < 1 else r
    txt = ("%.0f×" % m) if m >= 20 else ("%.1f×" % m) if m >= 2 else ("%.2f×" % m)
    return txt + (" faster" if r < 1 else " slower")


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
        o.append('<text x="%d" y="18" fill="currentColor">xc vs %s</text>' % (lx + 9, esc(name)))
        lx += 130
    # grid and axis
    for k in range(int(lo), int(hi) + 1):
        x = px(2.0 ** k)
        o.append('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" stroke="currentColor" stroke-opacity="%s"/>'
                 % (x, top - 8, x, top + rowh * len(rows), "0.55" if k == 0 else "0.15"))
        lab = "same" if k == 0 else ("%d× slower" % (2 ** k) if k > 0 else "%d× faster" % (2 ** -k))
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
                o.append('<circle cx="%.1f" cy="%.1f" r="4.5" fill="%s"><title>%s: xc is %s than %s</title></circle>'
                         % (px(rs[l]), y, col, esc(b), speed(rs[l]), esc(name)))
    o.append('</svg><figcaption>%s</figcaption></figure>' % esc(title))
    return "".join(o)


def version_switch(hist, suffix, title, versions, key):
    """The per-benchmark chart for each release, one shown at a time, chosen
    by a row of release labels (the latest at first). CSS only: each label is
    a radio button's, and the checked one's chart is displayed."""
    # A release with nothing to compare against here (the M3 Max history
    # has only xc before 0.87) gets no label: its chart would be empty.
    versions = [v for v in versions if any(r[2] for r in ratio_rows(hist[v], suffix))]
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
            # Speed relative to the first release: above 1 is faster.
            series[b] = [None if not x else vals[0] / x for x in vals]
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
    out = ["| benchmark | xc | Objective-C | C++ (clang) | C++ (GCC) | Swift | xc vs the fastest of the others |",
           "|---|---|---|---|---|---|---|"]
    for r, b, d in rows:
        cells = ["%.2f" % d[k + suffix] if d.get(k + suffix) else "–" for k in ("xc", "objc", "cpp", "gcc", "swift")]
        out.append("| [`%s`](%s#%s) | %s | **%s** |" % (b, SOURCES_URL, b, " | ".join(cells), speed(r)))
    return "\n".join(out)


def summary(cur):
    out = ["| xc compared with | arm64 (%s) | x86-64 (AMD Ryzen 9 9955HX) |" % mac_name(), "|---|---|---|"]
    for l, name, _ in LANGS:
        vals = []
        for _, suf in PLATFORMS:
            vals.append(gmean([d["O3"]["xc" + suf] / d["O3"][l + suf] for d in general(cur).values()
                               if d["O3"].get("xc" + suf) and d["O3"].get(l + suf)]))
        out.append("| %s | **%s** | **%s** |" % (name, speed(vals[0]), speed(vals[1])))
    return "\n".join(out)


def separate(cur):
    """The benchmarks kept out of the means, each as a table: the times on
    each target, and how much faster xc is than each language there."""
    out = []
    for b in SEPARATE:
        d = cur.get(b, {}).get("O3", {})
        rows = ["| `%s` | xc | Objective-C | C++ (clang) | C++ (GCC) | Swift |" % b, "|---|---|---|---|---|---|"]
        for (pname, suf), mach in zip(PLATFORMS, (mac_name(), "AMD Ryzen 9 9955HX")):
            x = d.get("xc" + suf)
            if not x:
                continue
            rows.append("| %s, %s | %s | %s |" % (pname, mach, secs(x),
                        " | ".join(secs(d[l + suf]) if d.get(l + suf) else "–" for l, _, _ in LANGS)))
            rows.append("| xc is | | %s |" % " | ".join(("**%s**" % speed(x / d[l + suf])) if d.get(l + suf) else "–"
                                                    for l, _, _ in LANGS))
        out.append("\n".join(rows))
    return "\n\n".join(out)


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
            if g is None:
                continue # not measured on this target (GCC on arm64)
            (ahead if g < 1.0 else behind).append(name)
        if not behind:
            parts.append("On %s xc is ahead of all of them." % pname)
        elif not ahead:
            parts.append("On %s xc is behind all of them." % pname)
        else:
            parts.append("On %s xc is ahead of %s and behind %s." % (pname, join(ahead), join(behind)))
    if len(parts) == 2 and parts[0].replace("arm64", "") == parts[1].replace("x86-64", ""):
        return parts[0].replace("On arm64", "On both targets")
    return " ".join(parts)


# (key, description, multi_gpu): multi_gpu is True only where the machine has
# two or more GPUs, so the "all GPUs" column (combining them) means something.
# On a one-GPU machine it would just repeat the "GPU" column, so it is dropped.
PAR_MACHINES = (("mac", "Apple MacBook Pro, %s (12 performance and 4 efficiency cores), its GPU through Metal", False),
                ("linux", "AMD Ryzen 9 9955HX (16 cores, 32 threads), Linux, its integrated Radeon 610M "
                          "(2 compute units, 128 shader lanes) through Vulkan", False),
                # CUDA's default device is the faster card (an RTX 5080 since 2026-10-12), Vulkan's the
                # first it enumerates (the RTX 3090): the two columns are two cards.
                ("windows", "AMD Ryzen 9 5950X (16 cores, 32 threads), Windows, an NVIDIA RTX 5080 through CUDA "
                            "and an RTX 3090 through Vulkan", True),
                ("browser", "Chrome on the Apple M4 Max: wasm32 (one thread) and WebGPU (from 0.73); "
                            "measured with 0.86, as the M3 Max has no Chrome", False))


def par_mac():
    """The Mac the par figures' "mac" column was measured on."""
    return "M3 Max, a 40-core GPU" if MAC_TREE == "m3max" else "M4 Max"


def ms(us):
    # Under a millisecond the tenths hide too much (0.1 ms was 143 us against
    # 445 ms, read as 4,500 times): the cell says so in microseconds.
    if us < 1000:
        return "%d µs" % us
    return "%.1f" % (us / 1000.0) if us < 100000 else "%.0f" % (us / 1000.0)


def autopar_tables(version):
    """--par-auto (benchmark/par/run.py --autopar): each plain-loop program as
    written and with --par-auto, beside the hand-written par version's auto."""
    path = os.path.join(ROOT, "par", version, "autopar.json")
    if not os.path.exists(path):
        return "*(not measured for this release)*"
    with open(path) as fh:
        res = json.load(fh)
    hand = {}
    hp = os.path.join(ROOT, "par", version, "results.json")
    if os.path.exists(hp):
        with open(hp) as fh:
            hand = json.load(fh)
    names = {"mac": "Apple %s, Metal" % par_mac().split(",")[0], "linux": "AMD Ryzen 9 9955HX, its integrated Radeon through Vulkan",
             "windows": "Windows, RTX 5080 through CUDA"}
    out = []
    for m in ("mac", "linux", "windows"):
        rows = [(b, r[m]) for b, r in res.items() if m in r]
        if not rows:
            continue
        out.append("**%s** (ms; best of eight runs)\n" % names[m])
        out.append("| benchmark | as written | `--par-auto`, all threads | `--par-auto`, GPU | `--par-auto`, `auto` "
                   "| hand-written `par`, `auto` |")
        out.append("|---|---|---|---|---|---|")
        for b, r in rows:
            h = hand.get(b, {}).get(m, {}).get("auto")
            out.append("| [`%s`](%s#%s) | %s | %s | %s | %s | %s |" % (
                b, SOURCES_URL, b, ms(r["written"]["best_us"]), ms(r["cpu"]["best_us"]),
                ms(r["gpu"]["best_us"]) if "gpu" in r else "–", ms(r["auto"]["best_us"]),
                ms(h["best_us"]) if h else "–"))
        out.append("")
    return "\n".join(out)


def remote_tables(version):
    """A remote GPU through xcd (benchmark/par/remote.py)."""
    path = os.path.join(ROOT, "par", version, "remote.json")
    if not os.path.exists(path):
        return "*(not measured for this release)*"
    with open(path) as fh:
        res = json.load(fh)
    names = {"mac": "Apple M4 Max (Metal), using the remote RTX 5080",
             "linux": "AMD Ryzen 9 9955HX with its integrated Radeon (Vulkan), using the remote RTX 5080"}
    out = []
    for m in ("mac", "linux"):
        rows = [(b, r[m]) for b, r in res.items() if m in r]
        if not rows:
            continue
        older = sorted({r.get("measured_with") for _, r in rows} - {None})
        note = "; measured with %s" % ", ".join(older) if older else ""
        out.append("**%s** (ms; best of eight runs%s)\n" % (names[m], note))
        out.append("| benchmark | this machine | the remote GPU | every GPU | `auto` |")
        out.append("|---|---|---|---|---|")
        for b, r in rows:
            out.append("| [`%s`](%s#%s) | %s | %s | %s | %s |" % (
                b, SOURCES_URL, b, ms(r["local"]["best_us"]), ms(r["remote"]["best_us"]),
                ms(r["all"]["best_us"]), ms(r["auto"]["best_us"])))
        out.append("")
    return "\n".join(out)


def par_tables(version):
    """The par benchmarks (benchmark/par/run.py): milliseconds for the best of
    eight runs of each block, per machine and device, and the first run's."""
    path = os.path.join(ROOT, "par", version, "results.json")
    if not os.path.exists(path):
        return "*(not measured for this release)*"
    with open(path) as fh:
        res = json.load(fh)
    out = []
    for m, name, multi_gpu in PAR_MACHINES:
        name = name % par_mac() if "%s" in name else name
        # GPU-saturation benchmarks (no CPU figures) have their own section.
        rows = [(b, r[m]) for b, r in sorted(res.items()) if m in r and "serial" in r[m]]
        if not rows:
            continue
        gpu = any("gpu" in r for _, r in rows)
        vk = any("vulkan" in r for _, r in rows)   # Windows from 0.72: CUDA and Vulkan
        out.append("**%s** (ms; best of eight runs)\n" % name)
        # "all GPUs" only where there are two or more to combine (0.8).
        gpus_m = multi_gpu and any("gpus" in r for _, r in rows)
        alldev = any("all" in r for _, r in rows)     # all devices (from 0.8)
        if gpu:
            heads = ["benchmark", "one thread", "all threads", "GPU"] + (["all GPUs"] if gpus_m else []) + \
                    (["Vulkan"] if vk else []) + (["all devices"] if alldev else []) + \
                    ["`auto`", "GPU vs %s" % ("one thread" if not any("cpu" in r for _, r in rows) else "all threads"),
                     "GPU's first run"] + (["Vulkan's first run"] if vk else [])
            out.append("| " + " | ".join(heads) + " |")
            out.append("|" + "---|" * len(heads))
        else:
            out.append("| benchmark | one thread | all threads | `auto` |")
            out.append("|---|---|---|---|")
        for b, r in rows:
            # A browser has no threads for wasm: no all-threads figure.
            cells = ["[`%s`](%s#%s)" % (b, SOURCES_URL, b), ms(r["serial"]["best_us"]),
                     ms(r["cpu"]["best_us"]) if "cpu" in r else "–"]
            if gpu:
                cells.append(ms(r["gpu"]["best_us"]) if "gpu" in r else "–")
            if gpus_m:
                cells.append(ms(r["gpus"]["best_us"]) if "gpus" in r else "–")
            if vk:
                cells.append(ms(r["vulkan"]["best_us"]) if "vulkan" in r else "–")
            if alldev:
                cells.append(ms(r["all"]["best_us"]) if "all" in r else "–")
            cells.append(ms(r["auto"]["best_us"]))
            if gpu:
                # The GPU against the best the CPU does (all threads; one in a browser).
                cpu = r.get("cpu", r["serial"])["best_us"]
                cells.append(speed(r["gpu"]["best_us"] / cpu) if "gpu" in r else "–")
                cells.append(ms(r["gpu"]["first_us"]) if "gpu" in r else "–")
            if vk:
                cells.append(ms(r["vulkan"]["first_us"]) if "vulkan" in r else "–")
            out.append("| " + " | ".join(cells) + " |")
        out.append("")
    return "\n".join(out)


GPU_SAT_INTRO = """### GPU-saturation benchmarks

These blocks are sized so that a single GPU stays busy for tens of milliseconds
— long enough that the tile queue's fixed per-tile cost is amortised and
spreading the block across a **second GPU** cuts the wall-clock time. The
benchmarks above each finish on one modern card in around a millisecond, too
little for a second card to help; these are the opposite case. There are no
*one thread*, *all threads* or *all devices* columns: at this size a single CPU
thread takes minutes per run, and `auto` would never put a saturating GPU block
on the CPU, so only the GPU paths are measured. On a one-GPU machine *all GPUs*
is the same device as *GPU* and is dropped; the point is the machine with two.

These figures are from the **development compiler for 0.8.1**, not released 0.8:
they need two fixes landing in that release — a narrow integer now converts to
float in a CUDA (PTX) kernel instead of dropping the kernel to a Vulkan
fallback, and the tile queue keeps a card's second back end in reach so a block
can spread across both NVIDIA cards. On released 0.8 this block stays on one
card. The two cards are not a matched pair — an RTX 5080 and an older RTX 3090
— so the gain is not 2×; read it from the slower card, which is the fairer
baseline: the 3090 alone against the two together. `auto` still keeps this
block on the single faster card for now — the per-tile cost during its short
probe hides the second card's gain — so the two-card figure is the `all GPUs`
column (`XC_PAR=gpus`); teaching `auto` to choose it is the next step.
"""


def gpu_saturation(version):
    """The GPU-saturation benchmarks (run.py GPU_BENCHES, from 0.8x): a block
    big enough to keep a GPU busy, so a second GPU pays off. They record only the
    GPU paths (no serial/all-threads/all-devices), which is how they are told
    apart here — a benchmark with no "serial" figure belongs in this section."""
    path = os.path.join(ROOT, "par", version, "results.json")
    if not os.path.exists(path):
        return ""
    with open(path) as fh:
        res = json.load(fh)
    gpu_benches = [b for b in res if not any("serial" in mv for mv in res[b].values())]
    if not gpu_benches:
        return ""
    out = [GPU_SAT_INTRO]
    for m, name, multi_gpu in PAR_MACHINES:
        name = name % par_mac() if "%s" in name else name
        rows = [(b, res[b][m]) for b in sorted(gpu_benches) if m in res[b]]
        if not rows:
            continue
        vk = any("vulkan" in r for _, r in rows)
        gpus_m = multi_gpu and any("gpus" in r for _, r in rows)
        out.append("**%s** (ms; best of eight runs)\n" % name)
        heads = ["benchmark", "GPU"] + (["all GPUs"] if gpus_m else []) + \
                (["Vulkan"] if vk else []) + ["`auto`", "GPU's first run"]
        out.append("| " + " | ".join(heads) + " |")
        out.append("|" + "---|" * len(heads))
        for b, r in rows:
            cells = ["[`%s`](%s#%s)" % (b, SOURCES_URL, b),
                     ms(r["gpu"]["best_us"]) if "gpu" in r else "–"]
            if gpus_m:
                cells.append(ms(r["gpus"]["best_us"]) if "gpus" in r else "–")
            if vk:
                cells.append(ms(r["vulkan"]["best_us"]) if "vulkan" in r else "–")
            cells.append(ms(r["auto"]["best_us"]))
            cells.append(ms(r["gpu"]["first_us"]) if "gpu" in r else "–")
            out.append("| " + " | ".join(cells) + " |")
        out.append("")
    return "\n".join(out)


def multigpu(version):
    """The multi-device table (a block across several GPUs and the CPU, from
    0.8). The device sets are not among run.py's standard modes and a machine
    with two cards is the only place they differ, so for now the figures are a
    hand-measured markdown fragment at benchmark/par/<version>/multigpu.md,
    included verbatim when present. (0.8x: have par/run.py record the sets and
    render this the way par_tables does the single-device modes.)"""
    path = os.path.join(ROOT, "par", version, "multigpu.md")
    if not os.path.exists(path):
        return ""
    with open(path) as fh:
        return fh.read().rstrip() + "\n"


def vulkan_notes(version):
    """The notes on CUDA against Vulkan on the Windows machine, from the same
    results as its table, so they follow each release's figures."""
    path = os.path.join(ROOT, "par", version, "results.json")
    if not os.path.exists(path):
        return ""
    with open(path) as fh:
        res = json.load(fh)
    rows = [(b, r["windows"]) for b, r in sorted(res.items())
            if "gpu" in r.get("windows", {}) and "vulkan" in r.get("windows", {})]
    if not rows:
        return ""
    faster, level, slower = [], [], []
    for b, r in rows:
        c, v = r["gpu"]["best_us"], r["vulkan"]["best_us"]
        pair = "`%s` (%s ms against %s)" % (b, ms(v), ms(c))
        if v < c * 0.95:
            faster.append(pair)
        elif v > c * 1.05:
            slower.append(pair)
        else:
            level.append("`%s`" % b)
    parts = []
    if faster:
        parts.append("faster on " + " and ".join(faster))
    if level:
        parts.append("level on " + " and ".join(level))
    if slower:
        parts.append("slower on " + " and ".join(slower))
    said = parts[0] if len(parts) == 1 else ", ".join(parts[:-1]) + " and " + parts[-1]
    note = ("- **Vulkan against CUDA:** the RTX 3090 through Vulkan against the RTX 5080 through CUDA, two cards,"
            " so this compares the APIs only roughly: Vulkan is " + said + ".")
    if faster:
        note += (" Up to 0.74 `auto` used CUDA on an NVIDIA GPU; from 0.75 it measures"
                 " both and keeps the faster for each block.")
    firsts = lambda k: [r[k]["first_us"] for _, r in rows]
    span = lambda us: "%s to %s ms" % (ms(min(us)).split(".")[0], ms(max(us)).split(".")[0])
    note += ("\n- **The first run** carries one-off costs (building the kernel, and on NVIDIA\n"
             "  creating the driver context and compiling the PTX or SPIR-V), so it is shown\n"
             "  apart: a few tens of milliseconds on Metal and the integrated GPU, and on the\n"
             "  3090 %s through CUDA and %s through Vulkan. `auto` pays it\n"
             "  once, while it measures." % (span(firsts("gpu")), span(firsts("vulkan"))))
    return note


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
    # Beside par/run.py, and md5 and md5_mask from apps/hashcat, where run.py
    # builds them (SRC_DIRS there): the GPU page links both here.
    srcs = {f[:-3]: os.path.join(ROOT, "par", f) for f in os.listdir(os.path.join(ROOT, "par")) if f.endswith(".xc")}
    for b in ("md5", "md5_mask"):
        hp = os.path.join(REPO, "apps", "hashcat", b + ".xc")
        if os.path.exists(hp):
            srcs[b] = hp
    for b in sorted(srcs):
        with open(srcs[b]) as fh:
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
    ap.add_argument("--current", default="v0.8")
    ap.add_argument("--history", default="v0.62,v0.63,v0.64,v0.65,v0.66,v0.7,v0.71,v0.72,v0.73,v0.74,v0.75,v0.8")
    ap.add_argument("--release", default="0.8")
    ap.add_argument("--mac", default=None, choices=["m3max"],
                    help="the arm64 figures from benchmark/<mac>-<version>/ (the Mac they were measured on)")
    a = ap.parse_args()
    global MAC_TREE
    MAC_TREE = a.mac
    cur = load(a.current)
    versions = a.history.split(",")
    hist = {v: load(v) for v in versions}
    for b, since in CHANGED_IN.items():
        if since not in versions:
            for v in versions:
                hist[v].pop(b, None)

    tc = toolchain_notes(a.current)
    page = PAGE_TEMPLATE.format(
        release=a.release,
        mac_long=MACHINES[MAC_TREE][1],
        tc_arm=tc.get("arm64", ""),
        tc_x86=tc.get("x86_64", ""),
        summary=summary(cur),
        standing=standing(cur),
        separate=separate(cur),
        chart_arm=version_switch(hist, "", "arm64: xc against each language, per benchmark",
                                 [v for v in versions if has_mac(v)], "vs-arm"),
        chart_x86=version_switch(hist, "_x86_64", "x86-64: xc against each language, per benchmark", versions, "vs-x86"),
        table_arm=table(cur, ""),
        table_x86=table(cur, "_x86_64"),
        hist_arm=history_chart(hist, "", "arm64: xc's speed relative to %s" % versions[0].lstrip("v"),
                               [v for v in versions if has_mac(v)]),
        hist_x86=history_chart(hist, "_x86_64", "x86-64: xc's speed relative to %s" % versions[0].lstrip("v"), versions),
        first=versions[0].lstrip("v"),
        hist_list=", ".join(v.lstrip("v") for v in versions),
        changed=", ".join("`%s`" % b for b in sorted(CHANGED_IN)),
    )
    with open(PAGE, "w") as fh:
        fh.write(page)
    print("wrote", os.path.relpath(PAGE, REPO))
    gpu_page = GPU_PAGE_TEMPLATE.format(
        release=a.release,
        par_mac=par_mac().split(",")[0],
        par=par_tables(a.current),
        multigpu=multigpu(a.current),
        gpu_saturation=gpu_saturation(a.current),
        vulkan=vulkan_notes(a.current),
        autopar=autopar_tables(a.current),
    )
    with open(GPU_PAGE, "w") as fh:
        fh.write(gpu_page)
    print("wrote", os.path.relpath(GPU_PAGE, REPO))
    with open(NET_PAGE, "w") as fh:
        fh.write(NET_PAGE_TEMPLATE.format(release=a.release, remote=remote_tables(a.current)))
    print("wrote", os.path.relpath(NET_PAGE, REPO))
    sources_page(cur.keys())
    published(a.current)


# The results behind the page, served by the site's corpus.php beside the
# submitted contributions, so the visualiser's Download shows the project's
# own figures even before anyone has submitted a run.
PUBLISHED = os.path.join(REPO, "website", "site", "public", "benchmarks", "published")


def published(current):
    os.makedirs(PUBLISHED, exist_ok=True)
    with open(os.path.join(PUBLISHED, "langs.json"), "w") as fh:
        json.dump(merged(current), fh, indent=1, sort_keys=True)
    print("wrote", os.path.relpath(os.path.join(PUBLISHED, "langs.json"), REPO))
    src = os.path.join(ROOT, "par", current, "results.json")
    if os.path.exists(src):
        shutil.copyfile(src, os.path.join(PUBLISHED, "par.json"))
        print("wrote", os.path.relpath(os.path.join(PUBLISHED, "par.json"), REPO))


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
runtime runs it on the CPU's threads or on the GPU (Metal on a Mac, CUDA or
Vulkan on Windows, Vulkan on Linux and Android, WebGPU in the browser),
whichever it finds faster. Nothing in the source
names a device, a kernel language or a thread.
"""


GPU_PAGE_TEMPLATE = """---
title: "Performance: GPU"
description: How xc's par blocks run on every CPU thread and on GPUs through Metal, CUDA, Vulkan and WebGPU, and what --par-auto makes of plain loops, measured with the released xcc.
---

Each figure is measured with the released {release} `xcc`, on an Apple
MacBook Pro with an {par_mac} (Metal), a Linux machine with an AMD Ryzen 9
9955HX and its integrated Radeon (Vulkan), and a Windows machine with an RTX
5080 and an RTX 3090 (CUDA and Vulkan). How the CPU code compares with other
compilers is on [Performance: CPU](/compiler/performance/); GPUs on other
machines are on [Performance: networked](/compiler/benchmarks/network/).

## Parallel blocks

A [`par` block](/compiler/language/par/) runs a loop's iterations at once,
across every CPU thread, on the GPU, or across several devices at once: the
block is cut into tiles handed to every GPU the machine
has, and to the CPU, together. The GPU is reached through:

- **Metal** on Apple silicon;
- **CUDA** on an NVIDIA GPU under Windows;
- **Vulkan** on Linux, Windows and Android;
- **WebGPU** in a browser.

Six programs in `benchmark/par` measure it:

- `mandelbrot`: a 2048×2048 escape-time image, at most 256 iterations a pixel;
- `perlin`: 2048×2048 improved noise, four octaves;
- `nbody`: the force on each of 8192 bodies from all the others;
- `saxpy`: `y = a·x + y` over 16 million integers, with a sum;
- `md5`, `md5_mask`: the hashcat MD5 workload, hashing 64 million candidates
  through the full 64-round compression and summing the digests.

Each runs its block eight times and reports the best run. The single-device
modes are *one thread* (`XC_PAR=cpu XC_PAR_THREADS=1`), *all threads*
(`XC_PAR=cpu`) and *GPU* (`XC_PAR=gpu`). A block can also run on *every
GPU* (`XC_PAR=gpus`) or on *every device* (`XC_PAR=all`), and `XC_PAR_WORKERS=…`
names an exact set (`cuda`, `vulkan`, `metal`, `cpu`). `auto`, the default,
times the sets the machine can form and keeps the fastest; it
remembers the choice, per program and per machine, so later runs do not measure
again. Every mode's checksum must agree. On Windows *GPU* is CUDA and *Vulkan*
the same work through Vulkan (`XC_PAR_GPU=vulkan`).

{par}
{multigpu}
{gpu_saturation}

What the tables show:

- **A discrete GPU wins by a wide margin** on the programs that do real work per
  element — `md5` hashes 64 million candidates in about a millisecond on one
  discrete card against hundreds on the CPU — and `auto` finds that and uses it.
- **`saxpy` stays on the CPU.** It does one multiply-add for every eight bytes
  it moves, so copying to and from the GPU outweighs the arithmetic, and `auto`
  keeps it on the CPU everywhere.
- **The tile queue scales a block across GPUs, where that pays.**
  `saxpy` spreads across both cards as the sum of their PCIe links — one GPU
  16 ms, both 7.9 — though it is memory-bound, so the CPU still wins and `auto`
  keeps it there. `md5` at 64 million candidates takes 0.9 ms on one card and
  0.7 on both: a block this short gains little from a second card, since the
  queue's cost per tile is paid twice, and `auto` chooses between them by
  measuring. A second GPU pays most on a block big enough to need its compute
  and not bound by the transfer to it.
- **Mixed graphics APIs.** The scheduler does not require one API: a block
  can run one card through CUDA beside another through Vulkan, so an NVIDIA
  and an AMD card could share a block the same way.
- **The Ryzen's integrated Radeon** has 128 shader lanes against the CPU's 32
  threads. It just beats them on `mandelbrot`, `perlin` and `md5` and loses on
  `nbody` and `saxpy`, where `auto` keeps the CPU.
{vulkan}

## Plain loops: `--par-auto`

`--par-auto` turns a loop whose iterations are independent into a `par`
block. Four of the programs above, written again as plain loops with no `par`
in them, are built as written and with `--par-auto`, and each mode's checksum
must agree. The last column is the hand-written `par` version's `auto`.

{autopar}

## Reproducing

```
python3 benchmark/par/run.py              # the par tables
python3 benchmark/par/run.py --autopar    # the --par-auto tables
python3 benchmark/page.py
```
"""


NET_PAGE_TEMPLATE = """---
title: "Performance: networked"
description: A par block's tiles on a GPU in another machine, served by xcd, beside the program's own devices, measured with the released xcc.
---

`xcd`, the par daemon, serves a machine's GPUs to programs on others (see
[par](/compiler/language/par/)). Here it runs on a Windows machine with an
RTX 5080, on the local network, and two machines use it: an Apple MacBook Pro
with an M4 Max, whose own GPU is fast, and a Linux machine with an AMD Ryzen 9
9955HX, whose only GPU is integrated. Each figure is measured with the
released {release} `xcc`.

Each program runs four ways: on the machine alone (`XC_PAR_REMOTE=none`), on
the remote GPU alone (`XC_PAR_WORKERS=remote`), on every GPU, the machine's
own and the remote one (`XC_PAR=gpus`), and as `auto` chooses with the remote
GPU among its choices. Each run starts from empty settings, so `auto`
measures afresh, and a remote-only figure counts only if every block ran on
the remote GPU. Every mode's checksum must agree.

{remote}

What the tables show:

- **A remote GPU pays where a block computes much from little data.** The
  hashcat MD5 workload sends almost nothing and hashes 64 million candidates:
  from the Linux machine it runs on the remote RTX 5080 many times faster than
  on its own devices, and `auto` picks the remote card.
- **It does not pay where the machine's own GPU is already fast**, as on the
  M4 Max, or where a block moves more than it computes (`saxpy`): `auto` keeps
  those local.
- **Every GPU together is not always faster.** Beside a remote card many times
  faster, a slow integrated GPU's share holds the fast one back; `auto`
  measures the remote card alone too and keeps whichever is fastest.

## Reproducing

```
python3 benchmark/par/remote.py
python3 benchmark/page.py
```

`remote.py` starts `xcd` on the configured GPU machine and measures from this
machine and the configured Linux host.
"""


PAGE_TEMPLATE = """---
title: "Performance: CPU"
description: How xcc-compiled code compares with clang's Objective-C and C++, with GCC's C++ and with Swift on the same programs, measured on twenty benchmarks across arm64 and x86-64.
---

The compiler is measured on twenty programs, each written four times: in the
xc language, in Objective-C with ARC, in C++ and in Swift, doing the same work
with the same algorithm and the same data. All are built with optimisation
(`-O3` for xc, Objective-C and C++, `-O` for Swift), every version prints a
checksum, and a run only counts if all four checksums agree. Every program, in
all four languages, is on the [benchmark sources](/compiler/benchmark-sources/)
page; each benchmark's name below links to its own. On x86-64 the C++ source
is built twice, with clang and with GCC (`g++ -O3`), on both targets, so each
carries a column for each C++ compiler.

Each figure is measured with the released {release} `xcc` on two machines:

- **arm64:** {mac_long}, macOS{tc_arm};
- **x86-64:** an AMD Ryzen 9 9955HX (16 cores, 32 threads), Linux{tc_x86}; its
  CPU frequency governor is `performance` (amd-pstate-epp) for the run.

Every compiler is given the machine's full instruction set: `-march=native`
(x86-64) or `-mcpu=native` (arm64) for clang and GCC, `-target-cpu native` for
Swift. xc needs no flag for that: with its default `-msimd=auto`, xcc builds
each vectorised function for SSE2, AVX2 and AVX-512 and the program picks one
when it starts. Nothing else is set: no link-time optimisation, no
profile-guided build, no `-ffast-math`, on any side.

Times are seconds for the timed region, the best of five runs, each run waiting
until the machine is otherwise idle.

## Summary

How much faster xc's code runs than each language's, as the geometric mean
over nineteen of the twenty benchmarks:

{summary}

{standing}

The twentieth benchmark, `matrix_mul_f32`, is kept out of those means. xcc
recognises its loop nest and replaces it with a matrix kernel of its own, which
makes xc tens to hundreds of times faster at that one operation; counted in, it would
dominate means that stand for ordinary code, and most programs do not multiply
matrices. Its figures are under [Matrix multiplies](#matrix-multiplies).

## Per benchmark

Each row is a benchmark, each dot one language: how much faster or slower xc
is than that language. Dots left of the centre line are benchmarks xc wins. Choose a
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

- **Vectorisation.** On arm64, `int_muldiv` and `float_math` are vectorised
  by both compilers, and clang's loops are tighter; `matrix_mul` has matched
  clang there since 0.73. On x86-64 `matrix_mul` is still behind, because
  clang keeps the second matrix's rows in registers across the outer loop.
- **Reference counting on x86-64.** `arc_array`, where C++ reads elements
  without retaining them.
- **x86-64 loops and calls.** `sieve` and `sort_small`, where clang's loops
  are still tighter (in 0.74 `sort_small` was 2.6× behind; 0.75 rotates its
  inner loop), `call_depth`, where clang's call sequence is shorter, and
  `int_muldiv`, where GCC hoists the arithmetic that does not depend on the
  repetition out of it.

## Matrix multiplies

A dense matrix multiply written as three plain loops, `C[i][j]` the sum over
`k` of `A[i][k] · B[k][j]` in `float` or `double`, runs as a kernel the
compiler writes itself (from 0.71). The results are the loops', to the last
bit, and `-fno-matmul` turns it off. The kernel depends on the machine:

- **Apple M4 and later (SME):** the multiply runs on the matrix unit. From
  0.72 it works on a 2×2 block of the unit's tiles at once, and under
  [`:goal(speed)`](/compiler/language/statements/#speed-or-accuracy-goal),
  which `matrix_mul_f32` uses, it leaves out a NaN check that only affects the
  bits of a NaN (the inputs have none).
- **Apple M1 to M3 (no SME):** the program finds no matrix unit when it
  starts and runs the loops, vectorised. The arm64 figures on this page, for
  every release, come from an M3 Max, so there `matrix_mul_f32` is the loop.
- **x86-64:** the widest vector unit the processor has (SSE2, AVX2 or
  AVX-512), chosen when the program starts; the Ryzen 9 9955HX picks AVX-512.

`matrix_mul_f32` measures it: a 128×128 `float` multiply, 10,000 times.
(`matrix_mul` multiplies `u32` values, which the matrix unit does not take, so
it stays a vectorised loop.)

{separate}

## The GPU and the network

`par` blocks, which run on every CPU thread, on GPUs and across machines, have
pages of their own: [Performance: GPU](/compiler/benchmarks/gpu/) (including
plain loops made parallel by `--par-auto`) and
[Performance: networked](/compiler/benchmarks/network/).

## Release to release

How fast xc's code is in each release, relative to {first}: above 1× is faster.
The thin lines are single benchmarks (labelled where they moved by more than
twelve percent), the thick line the geometric mean (without `matrix_mul_f32`). Releases shown: {hist_list}. {changed} changed in
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
