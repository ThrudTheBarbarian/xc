#!/usr/bin/env python3
# docgen.py — extract per-class doc SKELETONS from the UXKit sources into the
# website's Foundation-docs shape (private:PLAN-UXKIT.md phase 4: scaffold, then curate).
#
# The house comment style is prose-quality, so the skeletons are born useful:
# a file's leading comment block seeds its first class's Overview, each
# method's preceding comment becomes its section body, and the Topics grid is
# generated from the method list.  Pages land as draft: true; curation removes
# the flag page by page.  A page that already exists WITHOUT the draft flag is
# NEVER overwritten — curated prose outranks regeneration.
#
# usage: python3 tools/docgen.py            (from frameworks/uxkit)
import os, re, sys, glob

OUT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "..",
                                    "website", "site", "src", "content", "docs",
                                    "compiler", "api", "uxkit"))
SRC = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))

GROUPS = {
    "Views & controls": ["UXView", "UXControl", "UXButton", "UXCheckbox", "UXRadioButton",
        "UXRadioGroup", "UXTextField", "UXSlider", "UXStepper", "UXPopUpButton",
        "UXSegmentedControl", "UXProgressBar", "UXProgress", "UXTableView", "UXOutlineView",
        "UXCollectionView", "UXScrollView", "UXSplitView", "UXTabView", "UXToolbar",
        "UXComboBox", "UXDatePicker", "UXColorPanel", "UXColorList", "UXBreadcrumb",
        "UXSearchIndex", "UXViewTree", "UXResponder"],
    "Application & windows": ["UXApplication", "UXWindow", "UXMenu", "UXMenuBar", "UXAlert",
        "UXEvent", "UXNotificationCenter", "UXEventRecorder", "UXTimer", "UXOperationQueue",
        "UXStateMachine", "UXDragSession", "UXPasteboard", "UXOpenPanel", "UXFilePanel",
        "UXFileChooser", "UXKeyValueStore", "UXUndoManager"],
    "Text & content": ["UXString", "UXText", "UXTextLayout", "UXAttributedString",
        "UXCharacterSet", "UXFont", "UXMarkdown", "UXNumberFormatter", "UXValidator",
        "UXRegex", "UXExpression", "UXPredicate", "UXSortDescriptor", "UXDate", "UXURL",
        "UXJSON", "UXCSV", "UXLog"],
    "Geometry & drawing": ["UXGeom", "UXRect", "UXPoint", "UXSize", "UXGraphics",
        "UXPainter", "UXShapePath", "UXColor", "UXGradient", "UXImage", "UXAnimation",
        "UXViewport", "UXRange", "UXIndexSet", "UXBag", "UXBinaryHeap", "UXCache",
        "UXData", "UXPath", "UXNull"],
    "Nibs & the designer": ["UXNib", "UXNibV2", "UXDesignable"],
    "Drivers & backends": ["UXViewDriver", "UXGemDriver", "UXWin32Driver", "UXAppKitDriver",
        "UXWebDriver", "UXIosDriver", "UXGemGraphics", "UXGdiGraphics", "UXCocoaGraphics",
        "UXCanvasGraphics", "UXIosGraphics"],
}
SKIP_FILES = re.compile(r"(test_|demo_|^demo|^ks_|^lib|^nibdemo|^dateshow|\.h\.xc$)")

# Not every type a UXKit class touches BELONGS to UXKit. Object is Foundation's,
# and linking it into the UXKit namespace produces a page that does not exist —
# 44 pages carried that broken link before this was noticed, because it is
# generated and so wrong everywhere at once rather than obviously wrong anywhere.
FOUNDATION = {"Object", "String", "Number", "Array", "Dictionary", "Data", "Date"}
def typelink(name):
    ns = "" if name in FOUNDATION else "uxkit/"
    return f"/compiler/api/{ns}{name.lower()}/"


def group_of(cls):
    for g, names in GROUPS.items():
        if cls in names: return g
    return "Utilities"

def strip_comment(lines):
    out = []
    for l in lines:
        l = re.sub(r"^\s*//\s?", "", l.rstrip())
        out.append(l)
    while out and not out[0]: out.pop(0)
    while out and not out[-1]: out.pop()
    return "\n".join(out)

def first_sentence(text):
    t = " ".join(text.split("\n"))
    t = re.sub(r"^\S+\.xc\s+[—-]+\s*", "", t)          # drop the "UXFoo.xc — " prefix
    m = re.search(r"(.+?\.)\s", t + " ")
    s = (m.group(1) if m else t)[:180].strip()
    return s.replace('"', "'")

def parse(path):
    """-> list of (class, parent, protos, class_comment, [(sig, name, comment)])"""
    src = open(path).read().split("\n")
    filehead = []
    for l in src:
        if l.startswith("//"): filehead.append(l)
        else: break
    classes, cur, pending = [], None, []
    for i, l in enumerate(src):
        # PROTOCOLS are API too, and this scanner used to miss all ten of them:
        # UXApplicationDelegate, UXGraphics, UXViewDriver, UXTableDataSource and
        # the rest had no page at all, because only `class` was matched. They
        # are declared `protocol X { ... }` with bare signatures inside, so they
        # parse as a class with no parent and methods ending in `;`.
        mp = re.match(r"protocol\s+(UX\w+)", l)
        if mp:
            cur = {"cls": mp.group(1), "parent": "", "protos": [], "isproto": True,
                   "comment": strip_comment(pending) if classes else strip_comment(filehead),
                   "methods": []}
            classes.append(cur); pending = []
            continue
        m = re.match(r"class\s+(UX\w+)\s*(?::\s*(\w+))?\s*(?:<([\w,\s]+)>)?", l)
        if m:
            cur = {"cls": m.group(1), "parent": m.group(2) or "", "isproto": False,
                   "protos": [p.strip() for p in (m.group(3) or "").split(",") if p.strip()],
                   "comment": strip_comment(pending) if classes else strip_comment(filehead),
                   "methods": []}
            classes.append(cur); pending = []
            continue
        if cur is None:
            continue
        mm = re.match(r"    (?:optional\s+)?(?:static\s+)?[\w\*\^]+\s+(\w+)\s*\(([^)]*)\)\s*[{;]", l)
        if mm and not l.strip().startswith("//"):
            sig = l.strip().rstrip("{").strip()
            cur["methods"].append((sig, mm.group(1), strip_comment(pending)))
            pending = []
        elif l.strip().startswith("//"):
            pending.append(l)
        elif l.strip() == "":
            pending = []
    return classes

def page(cls, info, srcfile):
    md = []
    desc = first_sentence(info["comment"]) or f"The {cls} class."
    md.append("---")
    md.append(f"title: {cls}")
    md.append(f'description: "{desc}"')
    md.append("sidebar:")
    md.append("  badge:")
    md.append("    text: draft")
    md.append("    variant: caution")
    md.append("---")
    md.append("")
    md.append(f"<!-- GENERATED SKELETON (tools/docgen.py) from {srcfile} — curate, then drop draft: true.")
    md.append("     Curated pages are never regenerated over. -->")
    md.append("")
    if info["comment"]:
        md.append(info["comment"]); md.append("")
    md.append("```c")
    md.append(f'#use <UXKit>            // or #import "{srcfile}"')
    md.append("```")
    md.append("")
    md.append("## Overview")
    md.append("")
    md.append("_Curate: what this class is FOR, ownership rules, complexity notes._")
    md.append("")
    if info["parent"] or info["protos"]:
        md.append("## Conforms to"); md.append("")
        if info["parent"]:
            md.append(f"- Inherits [`{info['parent']}`]({typelink(info['parent'])})")
        for p in info["protos"]:
            md.append(f"- [`{p}`]({typelink(p)})")
        md.append("")
    if info["methods"]:
        names = " · ".join(f"[{n}](#{n.lower()})" for _, n, _ in info["methods"])
        md.append("## Topics"); md.append(""); md.append(names); md.append("")
        for sig, name, comment in info["methods"]:
            md.append(f"### {name}"); md.append("")
            md.append("```c"); md.append(sig); md.append("```"); md.append("")
            md.append(comment if comment else "_Curate._"); md.append("")
    md.append("## Platform appearance")
    md.append("")
    md.append("_Curate: the appearance tabs land here, in the fixed realm order —")
    md.append("Web | iOS Android | macOS Windows Linux GEM — wrapped in")
    md.append('the ux-platforms wrapper div for the realm separators (see uxbutton.mdx)._')
    md.append("")
    md.append("## Example")
    md.append("")
    md.append("_Curate: a worked example, per the docs mandate._")
    md.append("")
    return "\n".join(md)

def main():
    os.makedirs(OUT, exist_ok=True)
    made, kept, catalog = 0, 0, {}
    for path in sorted(glob.glob(os.path.join(SRC, "UX*.xc"))):
        base = os.path.basename(path)
        if SKIP_FILES.search(base): continue
        for info in parse(path):
            cls = info["cls"]
            catalog.setdefault(group_of(cls), []).append(cls)
            out = os.path.join(OUT, cls.lower() + ".md")
            curated = os.path.join(OUT, cls.lower() + ".mdx")   # curated pages go .mdx (components)
            if os.path.exists(curated) or (os.path.exists(out) and "GENERATED SKELETON" not in open(out).read()):
                kept += 1; continue                     # curated: never regenerate
            open(out, "w").write(page(cls, info, base))
            made += 1
    # the index
    idx = ["---", "title: UXKit", 'description: "The UI framework for the xc language — one neutral API, native realization on GEM, Win32, macOS, the web and iOS."', "---", "",
           "UXKit is the toolkit the compiler ships: one neutral widget/view/window",
           "API, realized NATIVELY per platform by interchangeable drivers.  An app",
           "says `#use <UXKit>` and `app.setDriver(...)` — nothing else in it names",
           "a platform.  The platforms, by realm: **the web** (canvas, the Aristo",
           "theme); **devices** — iOS and Android; **desktops** — macOS, Windows,",
           "Linux (GTK) and GEM.", ""]
    for g in list(GROUPS.keys()) + (["Utilities"] if "Utilities" in catalog else []):
        if g not in catalog: continue
        idx.append(f"## {g}"); idx.append("")
        for cls in sorted(set(catalog[g])):
            idx.append(f"- [`{cls}`](/compiler/api/uxkit/{cls.lower()}/)")
        idx.append("")
    open(os.path.join(OUT, "index.md"), "w").write("\n".join(idx))
    # the sidebar group (imported by astro.config.mjs) — regenerated with the pages
    sb = ["// GENERATED by frameworks/uxkit/tools/docgen.py — do not hand-edit.",
          "export default {",
          "\tlabel: 'UX framework (UXKit)',",
          "\tcollapsed: true,",
          "\titems: [",
          "\t\t{ label: 'Overview', slug: 'compiler/api/uxkit' },"]
    # Hand-written guides come FIRST: someone arriving at a 160-page reference
    # needs a path through it, not an alphabetical list.  They are discovered
    # from disk (guide-*.mdx) rather than listed here, so adding a guide is one
    # file and no edit to this generator.  Their titles are read from the
    # frontmatter so the sidebar cannot drift from the page.
    # Guides are a READING ORDER, not an alphabet: someone arriving needs the
    # first window before the view tree, and the view tree before controls.
    # Sorting by filename put "Your first window" second, which is the one
    # ordering that is definitely wrong. Unlisted guides fall in afterwards,
    # alphabetically, so adding one still needs no edit here to appear.
    GUIDE_ORDER = ["guide-first-window", "guide-view-tree", "guide-controls",
                   "guide-tables", "guide-drivers", "guide-nibs"]
    found = glob.glob(os.path.join(OUT, "guide-*.md")) + \
            glob.glob(os.path.join(OUT, "guide-*.mdx"))
    def guide_key(path):
        slug = os.path.basename(path).rsplit(".", 1)[0]
        return (GUIDE_ORDER.index(slug) if slug in GUIDE_ORDER else len(GUIDE_ORDER),
                slug)
    guides = sorted(found, key=guide_key)
    if guides:
        sb.append("\t\t{")
        sb.append("\t\t\tlabel: 'Guides',")
        sb.append("\t\t\titems: [")
        for g in guides:
            slug = os.path.basename(g).rsplit(".", 1)[0]
            head = open(g, errors="ignore").read(600)
            m = re.search(r'^title:\s*"?(.+?)"?\s*$', head, re.M)
            label = m.group(1) if m else slug
            label = label.replace("Guide: ", "").strip()
            label = label[:1].upper() + label[1:]
            sb.append("\t\t\t\t{ label: '%s', slug: 'compiler/api/uxkit/%s' }," %
                      (label.replace("'", "\\'"), slug))
        sb.append("\t\t\t],")
        sb.append("\t\t},")
    for g in list(GROUPS.keys()) + (["Utilities"] if "Utilities" in catalog else []):
        if g not in catalog: continue
        sb.append(f"\t\t{{")
        sb.append(f"\t\t\tlabel: '{g.replace(chr(39), chr(92)+chr(39))}',")
        sb.append("\t\t\tcollapsed: true,")
        sb.append("\t\t\titems: [")
        for cls in sorted(set(catalog[g])):
            sb.append(f"\t\t\t\t{{ label: '{cls}', slug: 'compiler/api/uxkit/{cls.lower()}' }},")
        sb.append("\t\t\t],")
        sb.append("\t\t},")
    sb += ["\t],", "};", ""]
    sbpath = os.path.normpath(os.path.join(OUT, "..", "..", "..", "..", "..", "..", "uxkit-sidebar.mjs"))
    open(sbpath, "w").write("\n".join(sb))
    print(f"docgen: {made} skeleton(s) written, {kept} curated page(s) kept -> {OUT}")
    print(f"docgen: sidebar -> {sbpath}")

if __name__ == "__main__":
    main()
