#!/usr/bin/env python3
"""Regenerate the GENERATED runtime .s files from their C sources, or check
that the checked-in files are what the sources and the recipes give.

    python3 tools/regen-runtimes.py              # regenerate all six
    python3 tools/regen-runtimes.py macos win64  # some of them
    python3 tools/regen-runtimes.py --check      # regenerate to a temp dir and diff

Each file keeps its own header (everything before the first assembler line)
and gets one maintained line at the end of it naming the clang that produced
the body. A different clang renames registers through the whole file, so the
recorded version is what tells a reviewer whether a thousand-line diff is a
change of substance or of compiler. --check compares only when the installed
clang matches the recorded one; otherwise it says so and passes.

The recipes are the ones the sources document (rt.c, rt-checked.c,
rt-freestanding.c); this file is where they are run. The android one needs the
NDK ($ANDROID_NDK_HOME, else the newest under the SDK): its clang, not the
host's, because Darwin and AAPCS64 pass variadic arguments differently.
"""
import os, re, subprocess, sys, tempfile

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CLANG = os.environ.get("XTC_RTGEN_CLANG", "clang")
RT = "src/xtc/support-src/rt.c"
RTC = "src/xtc/support-src/rt-checked.c"
RTF = "src/xtc/support-src/rt-freestanding.c"
COMMON = ["-fno-stack-protector", "-fomit-frame-pointer"]
INTEL = ["-S", "-O1", "-masm=intel", "-fno-asynchronous-unwind-tables", "-fno-jump-tables"] + COMMON

def ndk_clang():
    home = os.environ.get("ANDROID_NDK_HOME")
    if not home:
        sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") \
              or os.path.expanduser("~/Library/Android/sdk")
        ndks = sorted(os.listdir(os.path.join(sdk, "ndk"))) if os.path.isdir(os.path.join(sdk, "ndk")) else []
        if not ndks:
            return None
        home = os.path.join(sdk, "ndk", ndks[-1])
    for host in ("darwin-x86_64", "linux-x86_64"):
        cc = os.path.join(home, "toolchains/llvm/prebuilt", host, "bin/aarch64-linux-android24-clang")
        if os.path.exists(cc):
            return cc
    return None

# name -> (output path, source, clang argv (without -o), post-processing)
TARGETS = {
    "macos":   ("support/arm64/runtime/rt-macos.s", RT,
                [CLANG, "-S", "-O1", "-arch", "arm64"] + COMMON, None),
    "checked": ("support/arm64/runtime/rt-checked-macos.s", RTC,
                [CLANG, "-S", "-O0", "-fno-omit-frame-pointer", "-fno-stack-protector", "-arch", "arm64"],
                lambda s: s.replace("LBB", "Lchk_BB").replace("l_.str", "l_chk.str")),
    "android": ("support/arm64/runtime/rt-android.s", RT,
                [ndk_clang() or "aarch64-linux-android24-clang", "-S", "-O1",
                 "-fno-asynchronous-unwind-tables", "-fno-addrsig", "-mno-outline-atomics",
                 "-mbranch-protection=none"] + COMMON,
                lambda s: s.replace(".L", ".Lrt_")),
    "linux":   ("support/x86_64/runtime/rtgen-linux.s", RTF,
                [CLANG] + INTEL + ["-target", "x86_64-unknown-linux-gnu",
                 "-DXT_SINIT_C_INCLUDED=1", "-DXT_NO_WEAK_SEAM=1"], "linux-pieces"),
    "glibc":   ("support/x86_64/runtime/rtgen-glibc.s", RTF,
                [CLANG] + INTEL + ["-target", "x86_64-unknown-linux-gnu", "-DXT_GLIBC=1",
                 "-DXT_NO_WEAK_SEAM=1", "-fPIC", "-Wno-incompatible-library-redeclaration"], None),
    "win64":   ("support/win64/runtime/rtgen-win64.s", RTF,
                [CLANG] + INTEL + ["-target", "x86_64-windows-gnu", "-DXT_WIN64", "-DXT_NO_WEAK_SEAM=1"], None),
}

def clang_version(cc):
    out = subprocess.run([cc, "--version"], capture_output=True, text=True)
    return out.stdout.splitlines()[0].strip() if out.returncode == 0 and out.stdout else "?"

def split_header(text):
    """The header is every line before the first assembler line (a tab)."""
    lines = text.split("\n")
    for i, ln in enumerate(lines):
        if ln.startswith("\t"):
            return lines[:i], lines[i:]
    return lines, []

VERSION_RE = re.compile(r"^(//|#) regenerated with: ")

def with_version(header, comment, version):
    header = [h for h in header if not VERSION_RE.match(h)]
    while header and header[-1] == "":
        header.pop()
    return header + [f"{comment} regenerated with: {version}"]

def recorded_version(header):
    for h in header:
        m = VERSION_RE.match(h)
        if m:
            return h[m.end():].strip()
    return None

def linux_pieces(body):
    pieces = os.path.join(REPO, "tools", "rtgen-pieces")
    tlspad = open(os.path.join(pieces, "piece_tlspad.txt")).read()
    sinit = open(os.path.join(pieces, "piece_sinit.txt")).read()
    old = ('\t.type\t_xt_main_tcb,@object            # @_xt_main_tcb\n'
           '\t.bss\n\t.globl\t_xt_main_tcb\n\t.p2align\t3, 0x0\n')
    if old not in body:
        sys.exit("linux: could not find the _xt_main_tcb .bss preamble to replace")
    return body.replace(old, tlspad, 1).rstrip("\n") + "\n\n" + sinit

def generate(name):
    out, src, argv, post = TARGETS[name]
    cc = argv[0]
    if name == "android" and not os.path.exists(cc):
        return None, "no NDK clang"
    run = subprocess.run(argv + ["-o", "-", os.path.join(REPO, src)], capture_output=True, text=True, cwd=REPO)
    if run.returncode != 0:
        sys.exit(f"{name}: clang failed:\n" + run.stderr[-2000:])
    body = run.stdout
    if post == "linux-pieces":
        body = linux_pieces(body)
    elif post:
        body = post(body)
    current = open(os.path.join(REPO, out)).read()
    header, _ = split_header(current)
    comment = "#" if header and header[0].startswith("#") else "//"
    header = with_version(header, comment, clang_version(cc))
    return "\n".join(header) + "\n" + body.rstrip("\n") + "\n", None

def main():
    args = sys.argv[1:]
    check = "--check" in args
    names = [a for a in args if not a.startswith("--")] or list(TARGETS)
    bad = 0
    for name in names:
        if name not in TARGETS:
            sys.exit(f"unknown runtime '{name}'; one of {', '.join(TARGETS)}")
        out = os.path.join(REPO, TARGETS[name][0])
        text, why = generate(name)
        if text is None:
            print(f"{name}: skipped ({why})")
            continue
        if not check:
            tmp = out + ".tmp"
            open(tmp, "w").write(text)
            os.replace(tmp, out)      # never a truncated runtime checked in
            print(f"{name}: wrote {TARGETS[name][0]} ({text.count(chr(10))} lines)")
            continue
        current = open(out).read()
        rec = recorded_version(split_header(current)[0])
        have = clang_version(TARGETS[name][2][0])
        if rec is not None and rec != have:
            print(f"{name}: not checked (made with '{rec}', this is '{have}')")
            continue
        cb, nb = split_header(current)[1], split_header(text)[1]
        if cb == nb:
            note = "" if rec is not None else " (no clang version recorded; regenerate once to add it)"
            print(f"{name}: up to date{note}")
        else:
            diff = sum(1 for a, b in zip(cb, nb) if a != b) + abs(len(cb) - len(nb))
            print(f"{name}: DIFFERS from {TARGETS[name][1]} ({diff} body lines); regenerate with tools/regen-runtimes.py {name}")
            bad += 1
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
