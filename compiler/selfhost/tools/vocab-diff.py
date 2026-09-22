#!/usr/bin/env python3
"""Differential instruction-vocabulary check: our x86-64 assembler against the
vendor's, one instruction at a time.

asx86-diff compares the PORT's assembler against the REFERENCE's — both ours —
so an encoding both get wrong passes it. This compares each instruction form we
actually emit against clang's integrated assembler and diffs the BYTES, which
catches all three failure modes at once:

  * a mnemonic the tables lack        -> ours refuses, clang encodes
  * a mnemonic that is not real       -> ours encodes, clang refuses
  * a mnemonic encoded WRONGLY        -> both encode, bytes differ

The third is the one no set-difference finds and no existing harness covers.

The vocabulary is DATA-DRIVEN: harvested from `.s` the compiler actually
produced, so it is exactly what we emit, not what a grep of the sources guesses.

  vocab-diff.py <file.s> [file.s ...]
"""
import re, subprocess, sys, os, shutil, collections

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
LN   = os.path.join(ROOT, "bin", "osx", "xcc-ln-x86_64")
CC   = shutil.which("clang") or "/usr/bin/clang"
TMP  = os.environ.get("TMPDIR", "/tmp").rstrip("/")

# Forms that carry a relocation rather than an encoding: the bytes legitimately
# differ because the fixup is applied by the linker, not the assembler.
RELOC = re.compile(r'\brip\b|@|\bL[_.]|\b_[A-Za-z]')

def harvest(paths):
    """Distinct instruction forms, skipping any function that contains inline
    assembly.

    Inline asm is emitted VERBATIM, so a 6502 fixture compiled for x86 puts
    `LDA #$5A` in the output and a harvester that does not know this reports it
    as a vocabulary miss. There is a `# inline asm` START marker but no END
    marker, so the region cannot be bracketed — the whole function is dropped
    instead, which is sound if blunt. (An end marker would let this be precise,
    and would also let anything else that consumes the .s tell compiler output
    from user text.)
    """
    forms = collections.OrderedDict()
    for p in paths:
        text = open(p).read()
        funcs = re.split(r'(?m)^(?=[A-Za-z_][A-Za-z0-9_$.]*:$)', text)
        for fn in funcs:
            if "# inline asm" in fn: continue
            for ln in fn.splitlines(True):
                if not ln.startswith("\t"): continue
                s = ln.strip()
                if not s or s.startswith("."): continue
                if RELOC.search(s): continue
                if s.startswith("#"): continue
                if s.split()[0] in ("call", "jmp", "ret", "leave"): continue
                if re.match(r'^(j\w+|loop\w*)\b', s): continue  # branch displacements
                forms.setdefault(re.sub(r'\s+', ' ', s.replace("\t", " ")), p)
    return forms

def ours(form):
    f = f"{TMP}/vd_one.s"
    open(f, "w").write(".intel_syntax noprefix\n.text\n" + form + "\n")
    r = subprocess.run([LN, "--dump", f], capture_output=True, text=True)
    if r.returncode != 0: return None
    # `text <n>` then one line per chunk: "<8-hex address> <bytes…>". The
    # address is not part of the encoding.
    out = []
    grab = False
    for l in r.stdout.splitlines():
        if l.startswith("text "): grab = True; continue
        if grab:
            if not re.match(r'^[0-9a-f]{8} ', l): break
            out.append(l.split(None, 1)[1].replace(" ", ""))
    return "".join(out).strip() or None

def vendor(form):
    src = ".intel_syntax noprefix\n.text\n" + form + "\n"
    o = f"{TMP}/vd_one.o"
    r = subprocess.run([CC, "-x", "assembler", "-c", "-o", o, "-",
                        "-target", "x86_64-unknown-linux-gnu"],
                       input=src, capture_output=True, text=True)
    if r.returncode != 0: return None
    OD = shutil.which("llvm-objdump") or "/opt/homebrew/opt/llvm/bin/llvm-objdump"
    if not os.path.exists(OD): OD = shutil.which("objdump")
    d = subprocess.run([OD, "--section=.text", "--full-contents", o],
                       capture_output=True, text=True)
    if d.returncode != 0:
        d = subprocess.run([OD, "-s", "-j", ".text", o], capture_output=True, text=True)
        if d.returncode != 0: return None
    by = ""
    for l in d.stdout.splitlines():
        m = re.match(r'^\s*[0-9a-f]+\s((?:[0-9a-f]{2,8}\s){1,4})', l)
        if m: by += m.group(1).replace(" ", "")
    return by.strip() or None

forms = harvest(sys.argv[1:])
onlyv = []; onlyo = []; diff = []; neither = []; same = 0
for form, src in forms.items():
    a, b = ours(form), vendor(form)
    if a is None and b is None: neither.append((form, src)); continue
    if a is None: onlyv.append((form, b, src)); continue
    if b is None: onlyo.append((form, a, src)); continue
    if a == b: same += 1
    else: diff.append((form, a, b, src))

print(f"instruction forms harvested: {len(forms)}   agreeing: {same}   "
      f"neither assembler accepted: {len(neither)}")
def show(title, rows, fmt):
    if not rows: return
    print(f"\n{title} ({len(rows)}):")
    for r in rows[:25]: print("   " + fmt(r))
show("OUR ASSEMBLER REFUSES what clang encodes", onlyv,
     lambda r: f"{r[0]:<34} clang={r[1]}")
show("OUR ASSEMBLER ENCODES what clang refuses", onlyo,
     lambda r: f"{r[0]:<34} ours={r[1]}")
show("NEITHER assembler accepted (not silently skipped)", neither,
     lambda r: f"{r[0]:<50} from {os.path.basename(r[1])}")
show("BYTES DIFFER", diff,
     lambda r: f"{r[0]:<34} ours={r[1]:<16} clang={r[2]}")

# EVERY input lands in exactly one category, and the categories SUM to the
# input count. This is not decoration: the first version of this tool silently
# dropped the "neither assembler accepted it" case, and 374 inline-asm lines
# vanished into it. A differential that only counts DISAGREEMENTS cannot tell
# a silent skip from an agreement — the arithmetic is the only thing that can,
# and nothing in a green exit code performs it for you.
accounted = same + len(onlyv) + len(onlyo) + len(diff) + len(neither)
print(f"\naccounting: {same} agree + {len(onlyv)} ours-refuses + {len(onlyo)} "
      f"clang-refuses + {len(diff)} differ + {len(neither)} neither = {accounted}")
if accounted != len(forms):
    print(f"  *** UNACCOUNTED: {len(forms) - accounted} forms fell through every "
          f"category. The tool is lying; fix it before believing the result.")
    sys.exit(2)
sys.exit(1 if (onlyv or onlyo or diff) else 0)
