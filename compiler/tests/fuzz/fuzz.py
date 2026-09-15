#!/usr/bin/env python3
"""
Differential fuzzer for the xtc compiler.

Generates random *valid, UB-free, deterministic, integer-only* xtc programs,
compiles + runs each on all live backends (arm64, xt6502, m68k, wasm32, and
opt-in arm9 / x86-64 / win64), and flags any disagreement, crash, hang, or
compile-divergence. No reference oracle is needed: the backends must agree with
each other.

Integer-only FOR NOW — xt6502's software float legitimately differs from IEEE,
so a float divergence wouldn't be a real bug. i64/u64 ARE in the set: every live
target implements them (private:docs/Design/int64.md), so they must agree.

A construct only belongs in the generator once every backend is known to agree
on it — `tests/fuzz/probe.py <file.xc>` runs a hand-written program across the
same backend set and is how that gets established.

A backend is named `<backend>` or `<backend>@<opt>` — the SAME backend at two
optimisation levels is a legitimate differential pair, and a sharp one: nearly
every recent change is in the shared IR optimiser (vectoriser, slot colouring,
reduction recognisers), so `arm64@0` vs `arm64@3` isolates an optimiser bug from
a backend bug with no second target involved.

Usage:
  python3 tests/fuzz/fuzz.py [-n COUNT] [--start SEED]
                             [--only arm64,xt6502,m68k] [--opt 0,3] [-v]
Findings (a generated program + each backend's output) are saved under
tests/fuzz/findings/<seed>/.
"""
import argparse, os, random, re, subprocess, sys, tempfile, shutil


def _load_build_env():
    """Export build.env values (repository root) that the environment does not set."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "build.env")
    if not os.path.isfile(path):
        return
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, value = line.split("=", 1)
            if value and not os.environ.get(name):
                os.environ[name] = value


_load_build_env()

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BIN  = os.path.join(ROOT, "bin", "osx")
XCC  = os.path.join(BIN, "xcc")
FIND = os.path.join(os.path.dirname(os.path.abspath(__file__)), "findings")

# ── backend definitions ────────────────────────────────────────────────────
# builder(src, out, opt) -> (compile argv, run argv, artifact to check for)
def _arm64(src, out, o):
    return ([XCC, "-A", "arm64", f"-O{o}", src, "-o", out], [out], out)
def _xt6502(src, out, o):
    return ([XCC, "-m", "xt", f"-O{o}", src, "-o", out],
            [f"{BIN}/xcc-sim-6502", "-m", "xt", "-d", out], out)
def _m68k(src, out, o):
    return ([XCC, "-A", "68030", "-mhard-float", f"-O{o}", src, "-o", out],
            # --cpu 68030 REQUIRED: the code is built for -A 68030 and uses
            # 68020+ scaled-index addressing (An,Xn*2); the simulator defaults to
            # a 68000 core, which silently drops the scale and mis-reads every
            # array-in-a-loop. (XTCorpusSweep passes it too.)
            [f"{BIN}/xcc-sim-68k", "--cpu", "68030", "-d", out], out)

# wasm32: the in-house pipeline emits <out>.wasm plus an <out>.js loader that
# Node runs. Local and cheap, so it belongs in the default set.
NODE = os.environ.get("XTC_NODE", "node")
def _wasm32(src, out, o):
    return ([XCC, "-q", "-A", "wasm32", f"-O{o}", src, "-o", out],
            [NODE, out + ".js"], out + ".js")

# arm9/XTOS: compiled to a .so and run under qemu via the loader's hosttest
# kernel. EXPENSIVE (a full kernel boot per program) — opt-in only.
ARM9_SYS = os.environ.get("XTC_ARM9_SYSROOT", "")
def _arm9(src, out, o):
    kernel = os.path.join(ARM9_SYS, "freertos-hosttest.elf")
    run = (f"printf 'runhost {out}\\nexit\\n' | "
           f"qemu-system-arm -M xilinx-zynq-a9 -display none -no-reboot -m 1024 "
           f"-chardev stdio,id=sh0 -semihosting-config enable=on,target=native,chardev=sh0 "
           f"-kernel {kernel} 2>/dev/null | sed -e '1,/XTOS shell/d' | sed 's/^xtos\\$ //' "
           f"| sed -e '/^bye$/,$d' | grep -v '^\\[net\\]' | sed 's/\\r$//' | sed -e '/^$/d'")
    return ([XCC, "-q", "-A", "arm9", f"-O{o}", "-L", ARM9_SYS, src, "-o", out],
            ["/bin/sh", "-c", run], out)
# x86-64 Linux, built two ways and run on a Linux host. Pairing these two is the
# sharpest check the fuzzer can make of the self-hosted toolchain: the compiler
# is byte-identical up to the .s, so ANY divergence is in XAX86_64Assembler or
# XTElfWriter and nowhere else. (Pairing self-host against arm64 instead would
# also catch backend bugs, which is useful but does not isolate.)
X86_HOST = os.environ.get("XTC_LINUX_HOST", "")

def _x86_remote_run(out):
    remote = f"/tmp/xtc-fuzz-{os.getpid()}-{os.path.basename(out)}"
    return ["/bin/sh", "-c",
            f"scp -q -o BatchMode=yes {out} {X86_HOST}:{remote} && "
            f"ssh -o BatchMode=yes {X86_HOST} 'chmod +x {remote}; {remote}; "
            f"__rc=$?; rm -f {remote}; exit $__rc'"]

def _x86cc(src, out, o): return ([XCC, "-A", "x86_64", f"-O{o}", src, "-o", out],
                                 _x86_remote_run(out), out)
def _x86sh(src, out, o): return ([XCC, "-A", "x86_64", "--self-host", f"-O{o}", src, "-o", out],
                                 _x86_remote_run(out), out)

# Windows, built self-hosted (XTPEWriter) and run under Wine — LOCAL, no ssh, so
# far cheaper per program than the x86 legs. `win64sh` against `arm64` hunts
# backend bugs; against `x86sh` it isolates the PE container from the ELF one
# (same encoder, same generated .s, only the writer differs).
WINE = os.environ.get("XTC_WINE", "/opt/homebrew/bin/wine")
if not os.path.exists(WINE):
    _w = shutil.which("wine")
    if _w: WINE = _w
def _win64_run(out):    return [WINE, out]
def _win64sh(src, out, o): return ([XCC, "-A", "win64", "--self-host", f"-O{o}", src, "-o", out],
                                   _win64_run(out), out)
def _win64cc(src, out, o): return ([XCC, "-A", "win64", f"-O{o}", src, "-o", out],
                                   _win64_run(out), out)

BACKENDS = {"arm64": (_arm64, ".out"), "xt6502": (_xt6502, ".xex"), "m68k": (_m68k, ".prg"),
            "wasm32": (_wasm32, ".wasm32"), "arm9": (_arm9, ".so"),
            "x86cc": (_x86cc, ".x86cc"), "x86sh": (_x86sh, ".x86sh"),
            "win64sh": (_win64sh, ".w64sh.exe"), "win64cc": (_win64cc, ".w64cc.exe")}
# Backends whose per-program cost is a network round trip or a kernel boot —
# excluded from the default set and given a longer run timeout.
SLOW = {"x86cc", "x86sh", "arm9"}

def parse_spec(spec, default_opt):
    """'arm64' / 'arm64@0' -> (backend, opt) or None if the backend is unknown."""
    name, _, o = spec.partition("@")
    if name not in BACKENDS: return None
    return (name, o if o else default_opt)

# ── the integer type model ─────────────────────────────────────────────────
# (name, bit-width, signed). The print path casts every value to u32/%lu so a
# single uniform format covers all widths (and also exercises the widening cast);
# a 64-bit value prints as its two u32 halves, since %lu is 32-bit by contract.
NARROW = [("u8",8,False),("i8",8,True),("u16",16,False),("i16",16,True),
          ("u32",32,False),("i32",32,True)]
WIDE   = [("i64",64,True),("u64",64,False)]
# Element types for a LOCAL array and for the vector-shaped loops. Narrow on
# purpose in both cases: a 64-bit local array blows the xt6502 frame budget on
# its own, and the vector loops exist to feed the auto-vectoriser, which works
# on the narrow lane widths.
VEC_TYPES = NARROW

class Gen:
    def __init__(self, rng):
        self.rng = rng
        # ── per-seed feature dice ──────────────────────────────────────────
        # Every construct behind a die is generated by only SOME seeds. Two
        # reasons: a program that used every feature at once would blow the
        # xt6502 frame budget (119 bytes) on nearly every seed and be skipped
        # entirely, and a smaller program delta-debugs to a smaller repro.
        self.p64      = rng.choice([0.0, 0.0, 0.0, 0.15, 0.3])  # 64-bit types
        self.useVec   = rng.random() < 0.55   # vectoriser-shaped global loops
        self.useForIn = rng.random() < 0.55   # for-in (array / range / slice)
        self.useProto = rng.random() < 0.35   # protocols + optional methods
        self.useBound = rng.random() < 0.35   # bound methods (^)
        self.useWeak  = rng.random() < 0.35   # weak ivars / globals
        self.useDeep  = rng.random() < 0.35   # 3+ level inheritance chains
        self.useObjFn = rng.random() < 0.35   # object args / object returns
        self.useGArr  = rng.random() < 0.40   # global class-pointer arrays
        self.n = 0
        self.funcs = []        # (name, ty, nparams) — all params + return share `ty`
        self.struct_types = [] # (typename, [(fieldname, ty), ...])
        self.arrays = []       # (name, elemTy, size)
        self.struct_vars = []  # (name, typename, [(fieldname, ty), ...])
        self.ptrs = []         # (name, pointeeTy)
        self.struct_makers = {}    # typename -> maker function name (builds + returns it)
        self.struct_consumers = [] # (funcname, typename, retTy) — takes a struct by value
        self.multiret = []         # (name, ty, nparams) — returns TWO values of ty
        self.struct_arrays = []    # (name, typename, size, [(fieldname, ty), ...])
        self.globals = []          # (name, ty) — module-level globals (absolute addressing)
        self.array_ptrs = []       # (name, arrayName, baseIdx, elemTy, size) — &arr[i]
        self.classes = []          # (name, [(ivar, ty), ...], mixRetTy) — class defs
        self.objects = []          # (name, className, ivars, mixRetTy) — live heap objects
        self.hierarchies = []      # (base, baseIvars, vgetRetTy, [derivedNames]) — inheritance
        self.base_refs = []        # (name, base, baseIvars, vgetRetTy) — base@ = new Derived()
        self.tracked = []          # (className, strongChildOrNone) — dealloc-counting classes
        self.dcounters = []        # global counter names (dc0, dc1, ...) — one per tracked class
        self.garrays = []          # (name, elemTy, size) — module-level scalar arrays
        self.protos = []           # (name, [(method, retTy, optional)]) — protocol defs
        self.proto_impls = []      # (className, protoName, methods) — conforming classes
        self.proto_refs = []       # (varName, protoName, methods) — protocol-typed pointers
        self.chains = []           # ([classNames...], ivars, whoRetTy) — deep inheritance
        self.chain_refs = []       # (varName, rootClass, ivars, whoRetTy)
        self.bmethods = []         # (varName, typedefName, retTy, nparams)
        self.objfns = []           # (fnName, className, retTy) — takes an object, returns a scalar
        self.objmakers = []        # (fnName, className, ivars, mixRetTy) — returns an object
        self.weakers = []          # (obsClass, targetClass) — weak-ivar observer classes
        self.typedefs = []         # `typedef` lines a body needed (hoisted to module scope)

    def ty(self):
        """A random scalar type. 64-bit types appear only on the seeds whose
        dice enabled them (they are the widest, slowest and frame-hungriest)."""
        r = self.rng
        if self.p64 and r.random() < self.p64: return r.choice(WIDE)
        return r.choice(NARROW)

    def fresh(self, scope, ty):
        nm = f"v{self.n}"; self.n += 1; scope.append((nm, ty)); return nm

    def ptr_off(self, base, size):
        # a signed element offset k s.t. base+k stays in [0, size) — UB-free
        k = self.rng.randint(-base, size - 1 - base)
        return f"+ (i16){k}" if k >= 0 else f"- (i16){-k}"

    def lit(self, ty):
        w, signed = ty[1], ty[2]
        lo, hi = (-(1 << (w-1)), (1 << (w-1)) - 1) if signed else (0, (1 << w) - 1)
        return str(self.rng.randint(lo, hi))

    # an expression of result type `ty` over the variables in `scope`
    def expr(self, scope, ty, depth):
        r = self.rng
        if depth <= 0 or r.random() < 0.30:
            # leaf: scalar var, array element, struct field, ptr deref, or literal
            same = [v for v in scope if v[1] == ty]
            arrs = [a for a in self.arrays if a[1] == ty]
            sfields = [p for s in self.struct_vars
                       for p, fty in self.struct_leaves(s[0], s[2]) if fty == ty]
            sfields += [p for a in self.struct_arrays for i in range(a[2])
                        for p, fty in self.struct_leaves(f"{a[0]}[{i}]", a[3]) if fty == ty]
            ptrs = [p for p in self.ptrs if p[1] == ty]
            aptrs = [ap for ap in self.array_ptrs if ap[3] == ty]
            # object ivar reads (o.iv) and mix() dispatch of matching type
            oivs = [(o[0], iv[0]) for o in self.objects for iv in o[2] if iv[1] == ty]
            omix = [o[0] for o in self.objects if o[3] == ty]
            # base-ref inherited-ivar reads (br.b) and virtual vget() dispatch
            brivs = [(b[0], iv[0]) for b in self.base_refs for iv in b[2] if iv[1] == ty]
            brvget = [b[0] for b in self.base_refs if b[3] == ty]
            glbs = [g[0] for g in self.globals if g[1] == ty]
            garrs = [a for a in self.garrays if a[1] == ty]
            # deep-chain virtual dispatch, protocol dispatch, bound-method calls
            chrefs = [c for c in self.chain_refs if c[3] == ty]
            chivs  = [(c[0], iv[0]) for c in self.chain_refs for iv in c[2] if iv[1] == ty]
            prefs  = [(p[0], m) for p in self.proto_refs for m in p[2]
                      if m[1] == ty and not m[2]]         # required methods only
            bms    = [b for b in self.bmethods if b[2] == ty and b[3] == 0]
            objfns = [f for f in self.objfns if f[2] == ty
                      and any(o[1] == f[1] for o in self.objects)]
            # consumers callable here: a struct var of the consumer's type exists
            svtypes = {s[1] for s in self.struct_vars}
            cons = [c for c in self.struct_consumers if c[2] == ty and c[1] in svtypes]
            choices = []
            if same:    choices += [("var",) ] * 4
            if glbs:    choices += [("glb",) ] * 2
            if arrs:    choices += [("arr",) ] * 2
            if garrs:   choices += [("garr",)] * 2
            if sfields: choices += [("fld",) ] * 2
            if cons:    choices += [("con",) ] * 2
            if ptrs:    choices += [("ptr",) ] * 1
            if aptrs:   choices += [("aptr",)] * 2
            if oivs:    choices += [("oiv",) ] * 2
            if omix:    choices += [("omix",)] * 1
            if brivs:   choices += [("briv",)] * 2
            if brvget:  choices += [("brvget",)]* 1
            if chivs:   choices += [("chiv",)] * 2
            if chrefs:  choices += [("chwho",)]* 1
            if prefs:   choices += [("pcall",)]* 2
            if bms:     choices += [("bcall",)]* 2
            if objfns:  choices += [("objfn",)]* 1
            choices += [("lit",)]
            kind = r.choice(choices)[0]
            if kind == "var": return r.choice(same)[0]
            if kind == "glb": return r.choice(glbs)
            if kind == "garr":
                a = r.choice(garrs); i = r.randint(0, a[2]-1); return f"{a[0]}[{i}]"
            if kind == "chiv":
                on, ivn = r.choice(chivs); return f"{on}.{ivn}"
            if kind == "chwho":
                return f"({r.choice(chrefs)[0]}.who())"
            if kind == "pcall":
                pv, m = r.choice(prefs); return f"({pv}.{m[0]}())"
            if kind == "bcall":
                # a `^` is falsy when its receiver died — the guard is the point
                b = r.choice(bms); return f"(({b[0]}) ? {b[0]}() : ({ty[0]})0)"
            if kind == "objfn":
                f = r.choice(objfns)
                o = r.choice([o for o in self.objects if o[1] == f[1]])
                return f"{f[0]}({o[0]})"
            if kind == "oiv":
                on, ivn = r.choice(oivs); return f"{on}.{ivn}"
            if kind == "omix":
                return f"({r.choice(omix)}.mix())"
            if kind == "briv":
                on, ivn = r.choice(brivs); return f"{on}.{ivn}"
            if kind == "brvget":
                return f"({r.choice(brvget)}.vget())"
            if kind == "aptr":
                nm, arr, base, ety, size = r.choice(aptrs)
                return f"(@({nm} {self.ptr_off(base, size)}))"
            if kind == "arr":
                a = r.choice(arrs); i = r.randint(0, a[2]-1); return f"{a[0]}[{i}]"
            if kind == "fld":
                return r.choice(sfields)
            if kind == "con":
                cn, tn, _ = r.choice(cons)
                sv = r.choice([s for s in self.struct_vars if s[1] == tn])
                return f"{cn}({sv[0]})"
            if kind == "ptr": return f"(@{r.choice(ptrs)[0]})"
            if scope and r.random() < 0.3:  return f"({ty[0]}){r.choice(scope)[0]}"
            return f"({ty[0]}){self.lit(ty)}"
        callable_ = [f for f in self.funcs if f[1] == ty]
        if callable_ and r.random() < 0.25:
            nm, fty, npar = r.choice(callable_)
            args = ", ".join(self.expr(scope, fty, depth-1) for _ in range(npar))
            return f"{nm}({args})"
        # Mixed-width arithmetic (spec §3.1: mixed-width operands widen, same-
        # width wraps). Restricted to +,-,*,&,|,^ so it stays UB-free whatever
        # widths the operands take; result cast back to `ty`.
        if r.random() < 0.18:
            mop = r.choice(["+", "-", "*", "&", "|", "^"])
            t1 = self.ty(); t2 = self.ty()
            a = self.expr(scope, t1, depth-1); b = self.expr(scope, t2, depth-1)
            return f"({ty[0]})({a} {mop} {b})"
        if r.random() < 0.10:                    # ternary (spec §4.1 level 14)
            return (f"(({self.cond(scope)}) ? ({self.expr(scope, ty, depth-1)}) "
                    f": ({self.expr(scope, ty, depth-1)}))")
        if r.random() < 0.06:                    # unary
            u = r.choice(["-", "~"])
            return f"({ty[0]})({u}({self.expr(scope, ty, depth-1)}))"
        if r.random() < 0.06:                    # a bool folded back into the width
            return f"({ty[0]})({self.cond(scope)})"
        op = r.choice(["+","-","*","/","%","&","|","^","<<",">>","<:",":>"])
        a = self.expr(scope, ty, depth-1)        # both operands `ty` ⇒ result `ty`
        b = self.expr(scope, ty, depth-1)        # (same-width, no promotion)
        if op in ("/","%"):  return f"({a} {op} ({b} | ({ty[0]})1))"     # divisor != 0
        # shift/rotate distance in range
        if op in ("<<",">>","<:",":>"): return f"({a} {op} ({b} & ({ty[0]}){ty[1]-1}))"
        return f"({a} {op} {b})"

    def cond(self, scope):
        """A boolean expression. `&&` / `||` are short-circuit (spec §4.4), so a
        call in the right-hand operand may or may not run — deterministic, and
        every backend must agree on which."""
        r = self.rng
        def one():
            ty = self.ty()
            return (f"({self.expr(scope, ty, 2)} {r.choice(['<','>','<=','>=','==','!='])} "
                    f"{self.expr(scope, ty, 2)})")
        k = r.random()
        if k < 0.14:  return f"({one()} {r.choice(['&&','||'])} {one()})"
        if k < 0.18:  return f"(!{one()})"
        return one()

    def gen_func(self):
        r = self.rng; ty = self.ty(); nm = f"fn{len(self.funcs)}"; npar = r.randint(1, 3)
        params = [(f"p{i}", ty) for i in range(npar)]
        body = ""
        if self.globals and r.random() < 0.5:     # side effect: write a global
            g, gty = r.choice(self.globals)
            body = f"{g} = ({gty[0]})({self.expr(params[:], gty, 2)}); "
        e = self.expr(params[:], ty, 3)           # body may also READ globals
        self.funcs.append((nm, ty, npar))
        sig = ", ".join(f"{ty[0]} {p}" for p, _ in params)
        return f"{ty[0]} {nm}({sig}) {{ {body}return ({ty[0]})({e}); }}"

    def gen_multiret(self):
        r = self.rng; ty = self.ty(); nm = f"mr{len(self.multiret)}"; npar = r.randint(1, 3)
        params = [(f"p{i}", ty) for i in range(npar)]
        e1 = self.expr(params[:], ty, 3); e2 = self.expr(params[:], ty, 3)
        self.multiret.append((nm, ty, npar))
        sig = ", ".join(f"{ty[0]} {p}" for p, _ in params)
        return (f"{ty[0]}, {ty[0]} {nm}({sig}) "
                f"{{ return ({ty[0]})({e1}), ({ty[0]})({e2}); }}")

    def gen_classes(self, n):
        # Each class: scalar ivars, an init() ctor, a setvals() setter (one param
        # per ivar), and a mix() getter returning an expr over the ivars. Method
        # bodies reference ONLY ivars/params (+ globals + literals) — safe because
        # classes are emitted before main's locals exist, so self.expr's local
        # state (arrays/structs/ptrs/objects) is still empty here.
        r = self.rng; out = []
        for _ in range(n):
            nm = f"K{len(self.classes)}"
            ivars = [(f"iv{i}", self.ty()) for i in range(r.randint(1, 3))]
            mixTy = self.ty()
            lines = [f"class {nm} {{"]
            for iv, ty in ivars:
                lines.append(f"    {ty[0]} {iv};")
            inits = " ".join(f"{iv} = {self.lit(ty)};" for iv, ty in ivars)
            lines.append(f"    void init(void) {{ {inits} }}")
            sig = ", ".join(f"{ty[0]} a{i}" for i, (iv, ty) in enumerate(ivars))
            sets = " ".join(f"{iv} = a{i};" for i, (iv, ty) in enumerate(ivars))
            lines.append(f"    void setvals({sig}) {{ {sets} }}")
            mixe = self.expr([(iv, ty) for iv, ty in ivars], mixTy, 2)
            lines.append(f"    {mixTy[0]} mix(void) {{ return ({mixTy[0]})({mixe}); }}")
            lines.append("}")
            self.classes.append((nm, ivars, mixTy))
            out += lines
        return out

    def gen_hierarchies(self, n):
        # A base class with ivars + a virtual vget(), and 1-2 derived classes
        # that OVERRIDE vget() (different expr) — so calling vget() through a
        # base@ reference must dynamically dispatch to the concrete override.
        # setb() (base-only, not overridden) sets the inherited ivars to runtime
        # values, so vget()'s result depends on them (not just init literals).
        r = self.rng; out = []
        for _ in range(n):
            base = f"B{len(self.hierarchies)}"
            bivars = [(f"b{i}", self.ty()) for i in range(r.randint(1, 2))]
            vgetTy = self.ty()
            ivscope = [(iv, ty) for iv, ty in bivars]
            def vget(retTy):
                return (f"    {retTy[0]} vget(void) {{ return ({retTy[0]})"
                        f"({self.expr(ivscope, retTy, 2)}); }}")
            lines = [f"class {base} {{"]
            for iv, ty in bivars:
                lines.append(f"    {ty[0]} {iv};")
            inits = " ".join(f"{iv} = {self.lit(ty)};" for iv, ty in bivars)
            lines.append(f"    void init(void) {{ {inits} }}")
            sig = ", ".join(f"{ty[0]} a{i}" for i, (iv, ty) in enumerate(bivars))
            sets = " ".join(f"{iv} = a{i};" for i, (iv, ty) in enumerate(bivars))
            lines.append(f"    void setb({sig}) {{ {sets} }}")
            lines.append(vget(vgetTy))
            lines.append("}")
            derived = []
            for di in range(r.randint(1, 2)):
                D = f"D{len(self.hierarchies)}_{di}"
                lines.append(f"class {D} : {base} {{")
                lines.append(f"    void init(void) {{ {inits} }}")
                lines.append(vget(vgetTy))         # OVERRIDE — independent expr
                lines.append("}")
                derived.append(D)
            self.hierarchies.append((base, bivars, vgetTy, derived))
            out += lines
        return out

    def gen_tracked_classes(self, n):
        # Classes whose dealloc() bumps a dedicated global counter. Some hold a
        # STRONG ivar of a lower-indexed tracked class, so releasing the parent
        # cascades into the child (another dealloc). churn() exercises ARC; the
        # counters are the oracle — a backend that over-/under-releases diverges.
        r = self.rng; out = []
        for _ in range(n):
            i = len(self.tracked); nm = f"TC{i}"; ctr = f"dc{i}"
            child = r.choice(self.tracked)[0] if self.tracked and r.random() < 0.6 else None
            out.append(f"u16 {ctr};")
            lines = [f"class {nm} {{", "    u16 v;"]
            if child: lines.append(f"    {child}@ kid;")
            lines.append("    void init(void) { v = (u16)0; }")
            lines.append(f"    void dealloc(void) {{ {ctr} = {ctr} + (u16)1; }}")
            lines.append("}")
            self.tracked.append((nm, child)); self.dcounters.append(ctr)
            out += lines
        return out

    def gen_protocols(self, n):
        # A protocol + 2-3 conforming classes with INDEPENDENT method bodies, so
        # a call through a protocol-typed pointer must land in the right class's
        # vtable slot. One method per protocol is `optional` and implemented by
        # only some conformers — the `^`-is-null test (spec 8.5) is the oracle
        # for a slot that should be empty.
        r = self.rng; out = []
        for _ in range(n):
            pn = f"PR{len(self.protos)}"
            methods = [(f"pm{i}", self.ty(), False) for i in range(r.randint(1, 2))]
            methods.append((f"pmx{len(self.protos)}", r.choice(NARROW), True))  # optional
            out.append(f"protocol {pn} {{")
            for m, rty, opt in methods:
                out.append(f"    {'optional ' if opt else ''}{rty[0]} {m}(void);")
            out.append("}")
            for m, rty, opt in methods:
                if opt: out.append(f"typedef {rty[0]} {pn}_{m}_t(void);")
            self.protos.append((pn, methods))
            for ci in range(r.randint(2, 3)):
                cn = f"{pn}C{ci}"
                ivars = [(f"pv{i}", self.ty()) for i in range(r.randint(1, 2))]
                out.append(f"class {cn} <{pn}> {{")
                for iv, ty in ivars: out.append(f"    {ty[0]} {iv};")
                out.append("    void init(void) { " +
                           " ".join(f"{iv} = {self.lit(ty)};" for iv, ty in ivars) + " }")
                sig = ", ".join(f"{ty[0]} a{i}" for i, (iv, ty) in enumerate(ivars))
                sets = " ".join(f"{iv} = a{i};" for i, (iv, ty) in enumerate(ivars))
                out.append(f"    void setp({sig}) {{ {sets} }}")
                for m, rty, opt in methods:
                    if opt and ci % 2 == 1: continue          # left unimplemented
                    body = self.expr(list(ivars), rty, 2)
                    out.append(f"    {rty[0]} {m}(void) {{ return ({rty[0]})({body}); }}")
                out.append("}")
                self.proto_impls.append((cn, pn, methods, ivars))
        return out

    def gen_chains(self, n):
        # A 3-4 deep single-inheritance chain. Every level overrides who() and
        # each override reads the ivars introduced ABOVE it, so a wrong vtable
        # slot or a wrong object layout both show up in the printed value.
        r = self.rng; out = []
        for _ in range(n):
            depth = r.randint(3, 4); names = []; ivars = []
            whoTy = r.choice(NARROW)
            for lv in range(depth):
                cn = f"H{len(self.chains)}_{lv}"
                mine = [(f"h{len(self.chains)}_{lv}", self.ty())]
                visible = ivars + mine
                out.append(f"class {cn}{'' if lv == 0 else ' : ' + names[-1]} {{")
                for iv, ty in mine: out.append(f"    {ty[0]} {iv};")
                sup = "" if lv == 0 else "super.init(); "
                out.append(f"    void init(void) {{ {sup}" +
                           " ".join(f"{iv} = {self.lit(ty)};" for iv, ty in mine) + " }")
                if lv == 0:
                    sig = ", ".join(f"{ty[0]} a{i}" for i, (iv, ty) in enumerate(mine))
                    sets = " ".join(f"{iv} = a{i};" for i, (iv, ty) in enumerate(mine))
                    out.append(f"    void seth({sig}) {{ {sets} }}")
                out.append(f"    {whoTy[0]} who(void) {{ return ({whoTy[0]})"
                           f"({self.expr(list(visible), whoTy, 2)}); }}")
                out.append("}")
                names.append(cn); ivars = visible
            self.chains.append((names, [ivars[0]], whoTy))
        return out

    def gen_weak_classes(self, n):
        # An observer holding a weak: back-pointer at a tracked class. When the
        # target is released the slot must read back as null — the counted
        # before/after pair is the oracle (and the reason weak needs a helper
        # function: main's own objects outlive main's printf).
        r = self.rng; out = []
        for _ in range(n):
            if not self.tracked: break
            tgt = r.choice(self.tracked)[0]
            on = f"W{len(self.weakers)}"
            out += [f"class {on} {{",
                    f"    weak:{tgt}@ tw;",
                    "    u16 k;",
                    "    void init(void) { k = (u16)0; }",
                    "}"]
            out.append(f"weak:{tgt}@ gw{len(self.weakers)};")
            self.weakers.append((on, tgt))
        return out

    def gen_weak_probe(self):
        # Observe the weak slots from inside a helper: the target dies at the
        # helper's scope exit, so main can print "was it non-null, is it null
        # now" — two facts every backend must agree on.
        lines = ["u16 weakprobe(void) {", "    u16 seen = (u16)0;"]
        for i, (on, tgt) in enumerate(self.weakers):
            lines += [f"    {tgt}@ wt{i} = new {tgt}();",
                      f"    {on}@ wo{i} = new {on}();",
                      f"    wo{i}.tw = wt{i};",
                      f"    gw{i} = wt{i};",
                      f"    if (wo{i}.tw != 0) {{ seen = seen + (u16)1; }}",
                      f"    if (gw{i} != 0) {{ seen = seen + (u16)2; }}"]
        lines += ["    return seen;", "}"]
        return lines

    def gen_objfns(self, n):
        # Functions that take an object by reference and functions that RETURN a
        # freshly-made one (returns-retained: the caller adopts it, and ARC must
        # not double-release).
        r = self.rng; out = []
        for _ in range(n):
            if not self.classes: break
            cn, ivars, mixTy = r.choice(self.classes)
            fn = f"of{len(self.objfns)}"
            rty = r.choice([t for _, t in ivars] + [mixTy])
            body = self.expr([(f"o.{iv}", ty) for iv, ty in ivars], rty, 2)
            out.append(f"{rty[0]} {fn}({cn}@ o) {{ return ({rty[0]})({body}); }}")
            self.objfns.append((fn, cn, rty))
            mk = f"om{len(self.objmakers)}"
            args = ", ".join(f"{ty[0]} a{i}" for i, (iv, ty) in enumerate(ivars))
            sets = ", ".join(f"a{i}" for i in range(len(ivars)))
            out.append(f"{cn}@ {mk}({args}) {{ {cn}@ o = new {cn}(); "
                       f"o.setvals({sets}); return o; }}")
            self.objmakers.append((mk, cn, ivars, mixTy))
        return out

    def gen_global_arrays(self, n):
        # Module-level arrays: absolutely addressed (not frame-relative), which
        # is what the vectoriser-shaped loops need — a 32-element local array
        # would exceed the xt6502 frame budget on its own.
        r = self.rng; out = []
        for _ in range(n):
            ty = r.choice(VEC_TYPES); K = r.choice([8, 12, 16, 24, 32])
            nm = f"ga{len(self.garrays)}"
            out.append(f"{ty[0]} {nm}[{K}];")
            self.garrays.append((nm, ty, K))
        return out

    def gen_class_global_array(self):
        # A GLOBAL array of class pointers: ARC has to manage the elements, and
        # reassigning one must release the old occupant exactly once (#1150).
        if not self.tracked: return []
        tc = self.rng.choice(self.tracked)[0]
        return [f"{tc}@ gca[3];",
                "u16 gcafill(void) {",
                "    for (i16 i = (i16)0; i < (i16)3; i = i + (i16)1) {",
                f"        gca[i] = new {tc}();",
                "        gca[i].v = (u16)(i + (i16)1);",
                "    }",
                f"    gca[1] = new {tc}();",     # reassign: releases the old element
                "    u16 s = gca[0].v + gca[1].v + gca[2].v;",
                "    for (i16 i = (i16)0; i < (i16)3; i = i + (i16)1) { gca[i] = 0; }",
                "    return s;",
                "}"]

    def gen_churn(self):
        # Create K tracked objects, optionally set/reassign their strong ivar,
        # return — ARC releases everything at function exit (cascading through
        # strong ivars), bumping the counters a deterministic number of times.
        r = self.rng; lines = ["u16 churn(void) {"]; k = 0
        for _ in range(r.randint(1, 3)):
            tc, child = r.choice(self.tracked); nm = f"tk{k}"; k += 1
            lines.append(f"    {tc}@ {nm} = new {tc}();")
            if child:
                lines.append(f"    {nm}.kid = new {child}();")        # strong ivar → cascade
                if r.random() < 0.5:
                    lines.append(f"    {nm}.kid = new {child}();")    # reassign → release old
        lines.append("    return (u16)0;")
        lines.append("}")
        return lines

    # ── statement kinds added after the v12 generator ──────────────────────
    # Kept in one dispatcher rather than extended onto block()'s threshold
    # chain, so a new construct does not silently re-weight every old one.
    def new_stmt(self, scope, ind, depth):
        r = self.rng
        kinds = []
        if scope:                       kinds += ["compound", "incdec", "compound"]
        if self.useVec and self.garrays: kinds += ["vec"] * 4
        if self.useForIn and (self.arrays or self.garrays): kinds += ["forin_arr", "forin_slice"]
        if self.useForIn and scope:     kinds += ["forin_range"]
        if scope:                       kinds += ["loopctl", "unrollfor"]
        if self.useProto and self.proto_impls: kinds += ["protoref"] * 2
        if self.useDeep and self.chains:       kinds += ["chainref"] * 2
        if self.useBound and self.objects:     kinds += ["bound"] * 2
        if self.useObjFn and self.objmakers:   kinds += ["objmake"] * 2
        if not kinds: return []
        return getattr(self, "st_" + r.choice(kinds))(scope, ind, depth)

    def st_compound(self, scope, ind, depth):
        r = self.rng; v, ty = r.choice(scope)
        op = r.choice(["+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="])
        e = self.expr(scope, ty, 2)
        if op in ("/=", "%="):   e = f"({e} | ({ty[0]})1)"          # divisor != 0
        if op in ("<<=", ">>="): e = f"({e} & ({ty[0]}){ty[1]-1})"  # distance in range
        return [f"{ind}{v} {op} ({ty[0]})({e});"]

    def st_incdec(self, scope, ind, depth):
        r = self.rng; v, ty = r.choice(scope)
        return [f"{ind}" + r.choice([f"{v}++;", f"{v}--;", f"++{v};", f"--{v};"])]

    def st_loopctl(self, scope, ind, depth):
        # break / continue out of a counted loop — the trip count becomes a
        # property of the body, not of the header, which is what an optimiser
        # that rewrites the header has to preserve.
        r = self.rng; v, vty = r.choice(scope); K = r.randint(3, 8)
        i = f"lc{self.n}"; self.n += 1
        inner = scope + [(i, ("i16", 16, True))]
        out = [f"{ind}for (i16 {i} = (i16)0; {i} < (i16){K}; {i} = {i} + (i16)1) {{"]
        if r.random() < 0.5:
            out.append(f"{ind}    if ({i} == (i16){r.randint(1, K-1)}) {{ continue; }}")
        out.append(f"{ind}    if ({self.cond(inner)}) {{ break; }}")
        out.append(f"{ind}    {v} = ({vty[0]})({self.expr(inner, vty, 2)});")
        out.append(f"{ind}}}")
        return out

    def st_unrollfor(self, scope, ind, depth):
        r = self.rng; v, vty = r.choice(scope); K = r.randint(2, 6)
        i = f"lc{self.n}"; self.n += 1
        inner = scope + [(i, ("i16", 16, True))]
        return [f"{ind}for (i16 {i} = (i16)0; {i} < (i16){K}; {i} = {i} + (i16)1) :unroll "
                f"{{ {v} = ({vty[0]})({self.expr(inner, vty, 2)}); }}"]

    def st_forin_arr(self, scope, ind, depth):
        r = self.rng
        pool = [a for a in self.arrays] + [g for g in self.garrays]
        nm, ety, size = r.choice(pool)
        acc = self.fresh(scope, ety)
        v = f"fv{self.n}"; self.n += 1
        inner = scope + [(v, ety)]
        return [f"{ind}{ety[0]} {acc} = ({ety[0]})0;",
                f"{ind}for ({ety[0]} {v} in {nm}) {{ {acc} = ({ety[0]})"
                f"({self.expr(inner, ety, 1)}); }}"]

    def st_forin_slice(self, scope, ind, depth):
        r = self.rng
        pool = [a for a in self.arrays] + [g for g in self.garrays]
        nm, ety, size = r.choice(pool)
        lo = r.randint(0, size - 2); hi = r.randint(lo + 1, size)
        sl = r.choice([f"{lo}..{hi}", f"{lo}...{min(hi, size-1)}", f"..{hi}", f"{lo}.."])
        acc = self.fresh(scope, ety)
        v = f"fv{self.n}"; self.n += 1
        inner = scope + [(v, ety)]
        return [f"{ind}{ety[0]} {acc} = ({ety[0]})0;",
                f"{ind}for ({ety[0]} {v} in {nm}[{sl}]) {{ {acc} = ({ety[0]})"
                f"({self.expr(inner, ety, 1)}); }}"]

    def st_forin_range(self, scope, ind, depth):
        r = self.rng; v, vty = r.choice(scope)
        lo = r.randint(0, 5); hi = lo + r.randint(1, 12)
        step = r.choice(["", "", f" step {r.randint(2, 3)}"])
        dots = r.choice(["..", "..."])
        i = f"lc{self.n}"; self.n += 1
        inner = scope + [(i, ("i16", 16, True))]
        return [f"{ind}for (i16 {i} in {lo}{dots}{hi}{step}) {{ {v} = ({vty[0]})"
                f"({self.expr(inner, vty, 2)}); }}"]

    def st_vec(self, scope, ind, depth):
        """A loop shaped like the ones the auto-vectoriser recognises: map,
        reduction, widening sum, dot product, count and max. Deliberately
        parameterised on the two things that broke recognisers recently — a
        NON-ZERO start (#1125/#1126) and a RUNTIME trip count (#1133/#1138)."""
        r = self.rng
        src, ety, size = r.choice(self.garrays)
        i = f"lc{self.n}"; self.n += 1
        start = r.choice([0, 0, 0, 1, 2, 3])
        step  = r.choice([1, 1, 1, 2])
        out = []
        if r.random() < 0.5:                       # runtime trip count
            n = f"nt{self.n}"; self.n += 1
            e = self.expr(scope, ("u16", 16, False), 1)
            out.append(f"{ind}i16 {n} = (i16)((({e}) % (u16){size}) + (u16)1);")
            scope.append((n, ("i16", 16, True)))
        else:
            n = f"(i16){r.randint(max(start+1, 2), size)}"
        inner = scope + [(i, ("i16", 16, True))]
        head = (f"{ind}for (i16 {i} = (i16){start}; {i} < {n}; "
                f"{i} = {i} + (i16){step})")
        shape = r.choice(["map", "reduce", "widen", "dot", "count", "max"])
        same = [a for a in self.garrays if a[1] == ety and a[2] == size]
        if shape == "map":
            dst = r.choice(same)[0]
            k = self.lit(ety); c = self.lit(ety)
            out.append(f"{head} {{ {dst}[{i}] = ({ety[0]})({src}[{i}] * ({ety[0]}){k} "
                       f"+ ({ety[0]}){c}); }}")
        elif shape == "reduce":
            acc = self.fresh(scope, ety)
            out.append(f"{ind}{ety[0]} {acc} = ({ety[0]}){self.lit(ety)};")
            out.append(f"{head} {{ {acc} = ({ety[0]})({acc} + {src}[{i}]); }}")
        elif shape == "widen":
            wt = r.choice([("u32",32,False), ("i32",32,True)])
            acc = self.fresh(scope, wt)
            out.append(f"{ind}{wt[0]} {acc} = ({wt[0]})0;")
            out.append(f"{head} {{ {acc} = ({wt[0]})({acc} + ({wt[0]}){src}[{i}]); }}")
        elif shape == "dot" and len(same) > 1:
            b = r.choice([a for a in same if a[0] != src])[0]
            acc = self.fresh(scope, ety)
            out.append(f"{ind}{ety[0]} {acc} = ({ety[0]})0;")
            out.append(f"{head} {{ {acc} = ({ety[0]})({acc} + ({ety[0]})"
                       f"({src}[{i}] * {b}[{i}])); }}")
        elif shape == "count":
            cnt = self.fresh(scope, ("u16", 16, False))
            out.append(f"{ind}u16 {cnt} = (u16)0;")
            out.append(f"{head} {{ if ({src}[{i}] > ({ety[0]}){self.lit(ety)}) "
                       f"{{ {cnt} = {cnt} + (u16)1; }} }}")
        else:                                                       # running max
            best = self.fresh(scope, ety)
            out.append(f"{ind}{ety[0]} {best} = {src}[{start}];")
            out.append(f"{head} {{ if ({src}[{i}] > {best}) {{ {best} = {src}[{i}]; }} }}")
        return out

    def st_protoref(self, scope, ind, depth):
        # A protocol-typed pointer to a conforming instance: the call must land
        # in the class's own slot, and the OPTIONAL method's `^` must be null on
        # exactly the classes that left it out.
        r = self.rng
        cn, pn, methods, ivars = r.choice(self.proto_impls)
        obj = f"pi{self.n}"; self.n += 1
        pv  = f"pp{self.n}"; self.n += 1
        out = [f"{ind}{cn}@ {obj} = new {cn}();"]
        args = ", ".join(f"({ty[0]})({self.expr(scope, ty, 2)})" for iv, ty in ivars)
        out.append(f"{ind}{obj}.setp({args});")
        out.append(f"{ind}{pn}@ {pv} = {obj};")
        self.proto_refs.append((pv, pn, methods))
        opt = [m for m in methods if m[2]]
        if opt:
            m, rty, _ = opt[0]
            h = f"ph{self.n}"; self.n += 1
            acc = self.fresh(scope, rty)
            out.append(f"{ind}{pn}_{m}_t^ {h} = &{pv}.{m};")
            out.append(f"{ind}{rty[0]} {acc} = ({rty[0]})0;")
            out.append(f"{ind}if ({h}) {{ {acc} = {h}(); }}")
        return out

    def st_chainref(self, scope, ind, depth):
        r = self.rng
        names, ivars, whoTy = r.choice(self.chains)
        root = names[0]; conc = r.choice(names)
        nm = f"ch{self.n}"; self.n += 1
        out = [f"{ind}{root}@ {nm} = new {conc}();"]
        args = ", ".join(f"({ty[0]})({self.expr(scope, ty, 2)})" for iv, ty in ivars)
        out.append(f"{ind}{nm}.seth({args});")
        self.chain_refs.append((nm, root, ivars, whoTy))
        return out

    def st_bound(self, scope, ind, depth):
        # `&obj.method` — a two-word value that auto-zeroes when its receiver
        # dies. Taken over a live object here, so it must stay callable.
        r = self.rng
        o = r.choice(self.objects)
        nm = f"bm{self.n}"; self.n += 1
        td = f"bmt{self.n}"; self.n += 1
        self.typedefs.append(f"typedef {o[3][0]} {td}(void);")
        acc = self.fresh(scope, o[3])
        self.bmethods.append((nm, td, o[3], 0))
        return [f"{ind}{td}^ {nm} = &{o[0]}.mix;",
                f"{ind}{o[3][0]} {acc} = ({o[3][0]})0;",
                f"{ind}if ({nm}) {{ {acc} = {nm}(); }}"]

    def st_objmake(self, scope, ind, depth):
        # A function that RETURNS a new object: the caller adopts it (returns-
        # retained), so ARC must release it exactly once at scope exit.
        r = self.rng
        mk, cn, ivars, mixTy = r.choice(self.objmakers)
        nm = f"oi{self.n}"; self.n += 1     # not om{n}: the makers are named om0..
        args = ", ".join(f"({ty[0]})({self.expr(scope, ty, 2)})" for iv, ty in ivars)
        self.objects.append((nm, cn, ivars, mixTy))
        return [f"{ind}{cn}@ {nm} = {mk}({args});"]

    def block(self, scope, indent, depth, nstmts):
        r = self.rng; ind = "    " * indent; lines = []
        for _ in range(nstmts):
            if r.random() < 0.35:
                fresh = self.new_stmt(scope, ind, depth)
                if fresh:
                    lines += fresh; continue
            k = r.random()
            if k < 0.45 or len(scope) < 2 or depth <= 0:                # scalar declaration
                ty = self.ty(); e = self.expr(scope, ty, r.randint(0, 4))
                nm = self.fresh(scope, ty)
                lines.append(f"{ind}{ty[0]} {nm} = ({ty[0]})({e});")
            elif k < 0.50 and self.globals:                             # write a global
                g, gty = r.choice(self.globals)
                lines.append(f"{ind}{g} = ({gty[0]})({self.expr(scope, gty, 3)});")
            elif k < 0.58:                                              # local array (+ init all)
                ty = r.choice(VEC_TYPES); K = r.randint(2, 5); nm = f"ar{self.n}"; self.n += 1
                lines.append(f"{ind}{ty[0]} {nm}[{K}];")
                for j in range(K):
                    lines.append(f"{ind}{nm}[{j}] = ({ty[0]})({self.expr(scope, ty, 2)});")
                self.arrays.append((nm, ty, K))
            elif k < 0.68 and self.struct_types and r.random() < 0.3:   # array of structs
                tn, fields = r.choice(self.struct_types); K = r.randint(2, 3)
                nm = f"sa{self.n}"; self.n += 1
                lines.append(f"{ind}{tn} {nm}[{K}];")
                for j in range(K):
                    for path, fty in self.struct_leaves(f"{nm}[{j}]", fields):
                        lines.append(f"{ind}{path} = ({fty[0]})({self.expr(scope, fty, 2)});")
                self.struct_arrays.append((nm, tn, K, fields))
            elif k < 0.68 and self.struct_types:                       # struct var
                tn, fields = r.choice(self.struct_types); nm = f"st{self.n}"; self.n += 1
                if tn in self.struct_makers and r.random() < 0.5:   # via maker (sret)
                    args = ", ".join(self.expr(scope, fty, 2) for fn, fty in fields)
                    lines.append(f"{ind}{tn} {nm} = {self.struct_makers[tn]}({args});")
                else:                       # field-by-field (handles nested)
                    lines.append(f"{ind}{tn} {nm};")
                    for path, fty in self.struct_leaves(nm, fields):
                        lines.append(f"{ind}{path} = ({fty[0]})({self.expr(scope, fty, 2)});")
                self.struct_vars.append((nm, tn, fields))
            elif k < 0.76 and self.arrays and r.random() < 0.6:        # pointer INTO an array
                arr, ety, size = r.choice(self.arrays); base = r.randint(0, size - 1)
                nm = f"ap{self.n}"; self.n += 1
                lines.append(f"{ind}{ety[0]}@ {nm} = &{arr}[{base}];")
                # write through an in-bounds pointer offset: modifies arr[base+k]
                lines.append(f"{ind}@({nm} {self.ptr_off(base, size)}) = "
                             f"({ety[0]})({self.expr(scope, ety, 2)});")
                self.array_ptrs.append((nm, arr, base, ety, size))
            elif k < 0.76 and scope:                                   # pointer to a scalar local
                v, vty = r.choice(scope); nm = f"pt{self.n}"; self.n += 1
                lines.append(f"{ind}{vty[0]}@ {nm} = &{v};")
                lines.append(f"{ind}@{nm} = ({vty[0]})({self.expr(scope, vty, 2)});")
                self.ptrs.append((nm, vty))
            elif k < 0.78 and self.classes:                            # new class object + populate
                C, ivars, mixTy = r.choice(self.classes)
                nm = f"o{self.n}"; self.n += 1
                lines.append(f"{ind}{C}@ {nm} = new {C}();")
                args = ", ".join(f"({ty[0]})({self.expr(scope, ty, 2)})" for iv, ty in ivars)
                lines.append(f"{ind}{nm}.setvals({args});")   # ivar_i := arg_i (deterministic)
                self.objects.append((nm, C, ivars, mixTy))
            elif k < 0.81 and self.hierarchies:                        # base@ = new Derived() (vtable)
                base, bivars, vgetTy, derived = r.choice(self.hierarchies)
                D = r.choice(derived); nm = f"br{self.n}"; self.n += 1
                lines.append(f"{ind}{base}@ {nm} = new {D}();")   # base ref, derived instance
                args = ", ".join(f"({ty[0]})({self.expr(scope, ty, 2)})" for iv, ty in bivars)
                lines.append(f"{ind}{nm}.setb({args});")         # set inherited ivars (runtime)
                self.base_refs.append((nm, base, bivars, vgetTy))
            elif k < 0.82 and self.multiret and any(
                    sum(1 for v in scope if v[1] == m[1]) >= 2 for m in self.multiret):
                # multi-return unpack: (a, b) = fn(...) into two existing vars
                ms = [m for m in self.multiret if sum(1 for v in scope if v[1] == m[1]) >= 2]
                nm, ty, npar = r.choice(ms)
                dests = r.sample([v[0] for v in scope if v[1] == ty], 2)
                args = ", ".join(self.expr(scope, ty, 2) for _ in range(npar))
                lines.append(f"{ind}({dests[0]}, {dests[1]}) = {nm}({args});")
            elif k < 0.84:                                             # if / else
                v, vty = r.choice(scope)
                lines.append(f"{ind}if ({self.cond(scope)}) {{ {v} = ({vty[0]})"
                             f"({self.expr(scope, vty, 2)}); }}")
                lines.append(f"{ind}else {{ {v} = ({vty[0]})({self.expr(scope, vty, 2)}); }}")
            elif k < 0.89:                                             # bounded while loop
                v, vty = r.choice(scope); K = r.randint(2, 6)
                i = f"wc{self.n}"; self.n += 1
                inner = scope + [(i, ("i16", 16, True))]
                lines.append(f"{ind}i16 {i} = (i16)0;")
                lines.append(f"{ind}while ({i} < (i16){K}) {{ {v} = ({vty[0]})"
                             f"({self.expr(inner, vty, 2)}); {i} = {i} + (i16)1; }}")
            elif k < 0.93:                                             # switch (u8 selector 0-3)
                v, vty = r.choice(scope)
                sel = self.expr(scope, ("u8", 8, False), 2)
                lines.append(f"{ind}switch (({sel}) & (u8)3) {{")
                for c in range(4):
                    lines.append(f"{ind}    case {c}: {v} = ({vty[0]})"
                                 f"({self.expr(scope, vty, 2)}); break;")
                lines.append(f"{ind}    default: break;")
                lines.append(f"{ind}}}")
            else:                                                       # bounded for-loop
                v, vty = r.choice(scope); K = r.randint(2, 6)
                i = f"lc{self.n}"; self.n += 1     # not i{n}: i8/i16/i32 are type names
                inner = scope + [(i, ("i16", 16, True))]
                head = (f"{ind}for (i16 {i} = (i16)0; {i} < (i16){K}; "
                        f"{i} = {i} + (i16)1) ")
                if depth > 0 and r.random() < 0.4:    # NESTED loop body
                    j = f"lc{self.n}"; self.n += 1; K2 = r.randint(2, 4)
                    inner2 = inner + [(j, ("i16", 16, True))]
                    lines.append(head + "{")
                    lines.append(f"{ind}    for (i16 {j} = (i16)0; {j} < (i16){K2}; "
                                 f"{j} = {j} + (i16)1) {{ {v} = ({vty[0]})"
                                 f"({self.expr(inner2, vty, 2)}); }}")
                    lines.append(f"{ind}}}")
                else:
                    lines.append(head + f"{{ {v} = ({vty[0]})({self.expr(inner, vty, 2)}); }}")
        return lines

    # Every scalar leaf of a struct value as (access_path, scalar_ty), recursing
    # into struct-typed fields (a field's ty is a typename string when nested).
    def struct_leaves(self, prefix, fields):
        types = dict(self.struct_types); out = []
        for fn, fty in fields:
            path = f"{prefix}.{fn}"
            if isinstance(fty, str): out += self.struct_leaves(path, types[fty])
            else:                    out.append((path, fty))
        return out

    def gen_struct_types(self, k):
        r = self.rng; out = []
        for _ in range(k):
            tn = f"S{len(self.struct_types)}"
            # a field may be an earlier ALL-SCALAR struct (one level of nesting)
            simple = [t[0] for t in self.struct_types
                      if all(not isinstance(ft, str) for _, ft in t[1])]
            fields = []
            for i in range(r.randint(2, 4)):
                if simple and r.random() < 0.25: fields.append((f"f{i}", r.choice(simple)))
                else:                            fields.append((f"f{i}", self.ty()))
            self.struct_types.append((tn, fields))
            out.append("struct " + tn + " { " +
                       " ".join((f"{ft} {fn};" if isinstance(ft, str) else f"{ft[0]} {fn};")
                                for fn, ft in fields) + " }")
            nested = any(isinstance(ft, str) for _, ft in fields)
            if not nested:        # maker only for all-scalar structs (sret return)
                mk = f"mk{tn}"
                params = ", ".join(f"{ft[0]} a{i}" for i, (fn, ft) in enumerate(fields))
                asg = " ".join(f"rr.{fn} = a{i};" for i, (fn, ft) in enumerate(fields))
                out.append(f"{tn} {mk}({params}) {{ {tn} rr; {asg} return rr; }}")
                self.struct_makers[tn] = mk
            # consumer: combine EVERY scalar leaf (exercises the struct-arg ABI)
            rty = self.ty(); cn = f"use{tn}"
            combine = " + ".join(f"({rty[0]})({p})" for p, _ in self.struct_leaves("s", fields))
            out.append(f"{rty[0]} {cn}({tn} s) {{ return ({rty[0]})({combine}); }}")
            self.struct_consumers.append((cn, tn, rty))
        return out

    def program(self, nstmts):
        r = self.rng
        lines = ['#import "Stdio.xc"', ""]
        lines += self.gen_struct_types(r.randint(1, 2))
        for _ in range(r.randint(0, 3)):     # globals FIRST so functions can use them
            ty = self.ty(); g = f"g{len(self.globals)}"
            lines.append(f"{ty[0]} {g};"); self.globals.append((g, ty))
        if self.useVec:                      # global arrays for the vector loops
            lines += self.gen_global_arrays(r.randint(2, 3))
        lines += self.gen_classes(r.randint(1, 3))   # classes (before functions/main)
        lines += self.gen_hierarchies(r.randint(1, 2))   # inheritance + virtual dispatch
        if self.useDeep:  lines += self.gen_chains(1)        # 3-4 level chain + overrides
        if self.useProto: lines += self.gen_protocols(1)     # protocol + conformers
        lines += self.gen_tracked_classes(r.randint(1, 2))   # ARC dealloc-count classes
        if self.useWeak:  lines += self.gen_weak_classes(1)  # weak back-pointers
        lines += self.gen_churn()                     # the ARC churn function
        if self.weakers:  lines += self.gen_weak_probe()
        gca = self.gen_class_global_array() if self.useGArr else []
        lines += gca
        for _ in range(r.randint(0, 3)):     # a few leaf helper functions
            lines.append(self.gen_func())
        for _ in range(r.randint(0, 2)):     # a few multi-return functions
            lines.append(self.gen_multiret())
        if self.useObjFn: lines += self.gen_objfns(1)   # object args + object returns
        tdAt = len(lines)                    # body-hoisted typedefs land here
        lines += ["", "void main(void)", "{"]
        scope = []
        # seed every global first (read-before-write, deterministic)
        for g, gty in self.globals:
            lines.append(f"    {g} = ({gty[0]})({self.lit(gty)});")
        for nm, ety, size in self.garrays:   # and every global array element
            lines.append(f"    for (i16 gi{self.n} = (i16)0; gi{self.n} < (i16){size}; "
                         f"gi{self.n} = gi{self.n} + (i16)1) "
                         f"{{ {nm}[gi{self.n}] = ({ety[0]})(gi{self.n} * (i16){r.randint(1,7)} "
                         f"+ (i16){r.randint(0,9)}); }}")
            self.n += 1
        for ctr in self.dcounters:                     # zero the ARC dealloc counters
            lines.append(f"    {ctr} = (u16)0;")
        if self.weakers:
            wv = self.fresh(scope, ("u16", 16, False))
            lines.append(f"    u16 {wv} = weakprobe();")
            for i in range(len(self.weakers)):         # each target died with the probe
                nv = self.fresh(scope, ("u16", 16, False))
                lines.append(f"    u16 {nv} = (u16)0;")
                lines.append(f"    if (gw{i} == 0) {{ {nv} = (u16)1; }}")
        if gca:
            gv = self.fresh(scope, ("u16", 16, False))
            lines.append(f"    u16 {gv} = gcafill();")
        lines += self.block(scope, 1, 2, nstmts)
        for _ in range(r.randint(1, 3)):               # churn: create+release tracked objects
            lines.append("    churn();")
        # Print every observable as u32 (%lu is 32-bit by contract), so one
        # format covers every width; a 64-bit value prints as its two halves.
        U16 = ("u16", 16, False)
        printables = list(scope)
        printables += list(self.globals)
        printables += [(f"{a[0]}[{j}]", a[1]) for a in self.arrays for j in range(a[2])]
        printables += [(f"{a[0]}[{j}]", a[1]) for a in self.garrays for j in range(a[2])]
        printables += [(p, t) for s in self.struct_vars
                       for p, t in self.struct_leaves(s[0], s[2])]
        printables += [(p, t) for a in self.struct_arrays for j in range(a[2])
                       for p, t in self.struct_leaves(f"{a[0]}[{j}]", a[3])]
        printables += [(f"{o[0]}.{iv}", t) for o in self.objects for iv, t in o[2]]
        printables += [(f"{b[0]}.{iv}", t) for b in self.base_refs for iv, t in b[2]]
        printables += [(f"{b[0]}.vget()", b[3]) for b in self.base_refs]  # virtual dispatch
        printables += [(f"{c[0]}.who()", c[3]) for c in self.chain_refs]  # deep-chain dispatch
        printables += [(f"{p[0]}.{m[0]}()", m[1]) for p in self.proto_refs
                       for m in p[2] if not m[2]]                         # protocol dispatch
        printables += [(d, U16) for d in self.dcounters]   # ARC dealloc counts (oracle)
        cols = []
        for e, t in printables:
            if t[1] == 64:      # two u32 halves — %lu cannot carry a 64-bit value
                cols.append(f"(u32)(({e}) >> ({t[0]})32)")
                cols.append(f"(u32)({e})")
            else:
                cols.append(f"(u32)({e})")
        for i in range(0, len(cols), 6):
            ch = cols[i:i+6]
            fmt = " ".join("%lu" for _ in ch)
            lines.append(f'    Stdio.printf("{fmt}\\n", {", ".join(ch)});')
        lines += ["    return;", "}", ""]
        if self.typedefs:            # hoist body-created typedefs to module scope
            lines[tdAt:tdAt] = self.typedefs
        return "\n".join(lines)

# ── running one backend ─────────────────────────────────────────────────────
def run_backend(spec, src, workdir, timeout=20):
    """spec is (backend, opt). Returns (status, output).
    status: 'ok' | 'compile' | 'run' | 'timeout'."""
    name, opt = spec
    builder, ext = BACKENDS[name]
    out = os.path.join(workdir, f"{name}-O{opt}{ext}")
    cargv, rargv, artifact = builder(src, out, opt)
    # Run from the repo ROOT: the xt6502 subprocess pipeline (xcc-cg-6502) reads its
    # runtime harness (tests/corpus/xt6502-corpus-harness.asm — where _u32LShr etc.
    # live) and the support/ asm tree via CWD-relative paths. Invoked from anywhere
    # else the harness reads empty, xt6502 emits `JSR $0000` for those routines, and
    # every program that uses one prints nothing → a flood of bogus xt6502-empty
    # "divergences". src/out are absolute (tempdir), so cwd only steers resolution.
    try:
        c = subprocess.run(cargv, capture_output=True, timeout=120, text=True, cwd=ROOT)
    except subprocess.TimeoutExpired:
        return ("compile", "compile-timeout")
    if c.returncode != 0 or not os.path.exists(artifact):
        # Keep the TAIL — the actual error line trails any warnings (and the
        # capacity-limit skip detection keys off it).
        return ("compile", (c.stderr or c.stdout or "").strip()[-1500:])
    # Wine spins up wineserver on a cold prefix and can exceed a tight timeout
    # under parallel load — a startup cost, not a hang; a qemu run pays a whole
    # kernel boot. Give both headroom.
    runTimeout = timeout * 6 if (name in SLOW or "win64" in name) else timeout
    try:
        rr = subprocess.run(rargv, capture_output=True, timeout=runTimeout, text=True, cwd=ROOT)
    except subprocess.TimeoutExpired:
        return ("timeout", "run-timeout (likely infinite loop)")
    # xt6502's exit code is the ACCUMULATOR at the final BRK — sim6502.c calls it
    # "the program's DOS return value". A generated program is `void main(void)`,
    # so A holds whatever the last instruction left there and the rc is noise: two
    # perfectly good programs reported rc=234 and rc=77 and were chased as wild
    # stores. (The `SDATA_WRITE` lines they print are a leftover PROBE in the
    # simulator too — it traces every write to $D8A0-$D8B4, which is
    # __sdata_Stdio's own field range, i.e. entirely normal traffic.) Judge this
    # backend on its OUTPUT: a real crash truncates it, which the differential
    # sees, and a real hang still trips the timeout.
    if rr.returncode != 0 and name != "xt6502":
        return ("run", f"rc={rr.returncode} {rr.stderr.strip()[:200]}")
    return ("ok", rr.stdout)

# Compile errors that mean "this program is too big for THIS backend" — an
# expected per-target capacity difference, not a miscompile. Skip such programs.
CAPACITY_LIMITS = (
    "frame budget",                  # arm64 16K / m68k 32K / xt6502 119 (#408)
    "exceeds the declared .code",    # xt6502 banked code-region overflow
    "SP-relative offset",            # xt6502 +N,SP past +127 (#409)
    "past the xt's signed-8-bit",    # xt6502 (#409)
    "119-byte budget",               # xt6502 frame ("exceeds 119-byte budget", ±"the")
    "struct return wider than",      # xt6502: sret >16 bytes is unimplemented, not wrong
)
def is_capacity_limit(out):
    return any(p in out for p in CAPACITY_LIMITS)

def test_one(seed, backends, verbose=False):
    rng = random.Random(seed)
    prog = Gen(rng).program(rng.randint(4, 14))
    wd = tempfile.mkdtemp(prefix="xtfuzz_")
    try:
        src = os.path.join(wd, "p.xc")
        open(src, "w").write(prog)
        results = {b: run_backend(b, src, wd) for b in backends}
        # A capacity-limit compile error means "too big for THIS variant" — an
        # expected per-target (and per -O level) capacity difference, not a
        # miscompile. Drop just that variant; the rest still form a differential.
        capped = {b for b, (st, out) in results.items()
                  if st == "compile" and is_capacity_limit(out)}
        usable = {b: r for b, r in results.items() if b not in capped}
        if len(usable) < 2:
            return ("SKIP", seed, prog, results)
        oks = {b: out for b, (st, out) in usable.items() if st == "ok"}
        bad = {b: (st, out) for b, (st, out) in usable.items() if st != "ok"}
        # a finding: any non-ok backend, or any disagreement among the ok ones
        outs = set(oks.values())
        diverge = len(outs) > 1
        if bad or diverge:
            return ("FINDING", seed, prog, results)
        return ("OK", seed, prog, results)
    finally:
        shutil.rmtree(wd, ignore_errors=True)

_DECL_RE = re.compile(r"^\s{4}(\w+)\s+(\w+)(\[\d+\])?;\s*$")
_ASSIGN_RE = re.compile(r"^\s*([A-Za-z_]\w*(?:\[\d+\])?(?:\.\w+)*)\s*=[^=]")

def _reads_uninitialised(prog):
    """True if main reads storage nothing ever wrote.

    The GENERATOR never emits that — it initialises every array element and
    struct field right after the declaration — but the REDUCER can create it by
    deleting the initialising lines, and a program that reads uninitialised
    stack is entitled to differ between two -O levels or two back ends. Without
    this guard a real miscompile reduces to `S0 sa[2];` plus a printf of it,
    which proves nothing.

    The check is PER PATH, not per variable: one surviving `sa[0].f0 = …` does
    not make `sa[1].f0` initialised. An assignment to any PREFIX counts, so a
    whole-struct `st = mk(…)` covers `st.f0`. Module scope is exempt — globals
    and ivars are zero-init."""
    lines = prog.split("\n")
    try:      start = next(i for i, l in enumerate(lines) if l.startswith("void main("))
    except StopIteration: return False
    body = lines[start:]
    decls, declLines = [], set()
    for i, l in enumerate(body):
        m = _DECL_RE.match(l)
        if m: decls.append(m.group(2)); declLines.add(i)
    if not decls: return False
    targets = {m.group(1) for m in (_ASSIGN_RE.match(l) for l in body) if m}
    scan = "\n".join(l for i, l in enumerate(body) if i not in declLines)
    for name in decls:
        for m in re.finditer(r"\b" + re.escape(name) + r"(?:\[\d+\])?(?:\.\w+)*", scan):
            path = m.group(0)
            if not any(path == t or path.startswith(t + ".") or path.startswith(t + "[")
                       for t in targets):
                return True
    return False

def _interesting(prog, backends, want):
    """True iff the program still shows the SAME kind of finding it started with.
    `want` is 'diverge' (all backends run, outputs disagree) or '<status>:<name>'
    — that backend still fails the same way while some other still builds+runs.
    A build failure or a crash is a finding too, and the old minimiser could
    only ever shrink a divergence."""
    if _reads_uninitialised(prog): return False
    wd = tempfile.mkdtemp(prefix="xtfuzzmin_")
    try:
        src = os.path.join(wd, "p.xc"); open(src, "w").write(prog)
        res = {b: run_backend(b, src, wd) for b in backends}
        if want == "diverge":
            if any(st != "ok" for st, _ in res.values()): return False
            return len({out for _, out in res.values()}) > 1
        status, target = want.split(":", 1)
        hit = next((r for b, r in res.items() if label(b) == target), None)
        if not hit or hit[0] != status: return False
        if status == "compile" and is_capacity_limit(hit[1]): return False
        return any(st == "ok" for b, (st, _) in res.items() if label(b) != target)
    finally:
        shutil.rmtree(wd, ignore_errors=True)

def minimize(seed, backends):
    """Delta-debug the WHOLE program — declarations, classes and print statements
    included. Removing a line that something later needs simply fails to compile,
    which is not the finding, so the line stays: no dependency tracking needed."""
    rng = random.Random(seed); prog = Gen(rng).program(rng.randint(4, 14))
    wd = tempfile.mkdtemp(prefix="xtfuzzmin_")
    try:
        src = os.path.join(wd, "p.xc"); open(src, "w").write(prog)
        res = {b: run_backend(b, src, wd) for b in backends}
    finally:
        shutil.rmtree(wd, ignore_errors=True)
    want = None
    if all(st == "ok" for st, _ in res.values()):
        if len({out for _, out in res.values()}) > 1: want = "diverge"
    else:
        bad = [b for b, (st, out) in res.items()
               if st != "ok" and not (st == "compile" and is_capacity_limit(out))]
        if bad and any(st == "ok" for st, _ in res.values()):
            want = res[bad[0]][0] + ":" + label(bad[0])
    if not want: return None            # nothing reproducible to shrink
    lines = prog.split("\n")
    if not _interesting("\n".join(lines), backends, want): return None
    # Coarse to fine: drop contiguous chunks, halving the chunk size each round,
    # so a 150-line program does not need 150 compiles per removed line.
    n = max(1, len(lines) // 4)
    while n >= 1:
        i = len(lines) - n
        while i >= 0:
            cand = lines[:i] + lines[i+n:]
            if cand and _interesting("\n".join(cand), backends, want):
                lines = cand; i = min(i, len(lines) - n)
            else:
                i -= 1
        n //= 2
    return "\n".join(lines)

def label(spec): return f"{spec[0]}@O{spec[1]}"

def save_finding(seed, prog, results):
    d = os.path.join(FIND, str(seed)); os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "prog.xc"), "w").write(prog)
    with open(os.path.join(d, "results.txt"), "w") as f:
        for b, (st, out) in results.items():
            f.write(f"=== {label(b)}: {st} ===\n{out}\n\n")
    return d

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=200)
    ap.add_argument("--start", type=int, default=1)
    ap.add_argument("--only", default="arm64,xt6502,m68k,wasm32",
                    help="backends; each may carry an explicit level, e.g. arm64@0")
    ap.add_argument("--opt", default="3",
                    help="optimisation level(s) for backends given without one. "
                         "'0,3' compares every backend at BOTH levels — the "
                         "sharpest check of the shared IR optimiser.")
    ap.add_argument("-j", type=int, default=4, help="programs tested in parallel")
    ap.add_argument("--reduce", type=int, default=0, help="minimize the finding at this seed and print it")
    ap.add_argument("-v", action="store_true")
    a = ap.parse_args()
    levels = [o for o in a.opt.split(",") if o]
    backends = []
    for spec in a.only.split(","):
        if not spec: continue
        if "@" in spec:
            s = parse_spec(spec, levels[0])
            if s and s not in backends: backends.append(s)
        else:
            for o in levels:
                s = parse_spec(spec, o)
                if s and s not in backends: backends.append(s)
    if not backends:
        print(f"no known backends in --only (known: {', '.join(BACKENDS)})"); return 2
    if any("win64" in b for b, _ in backends) and os.path.exists(WINE):
        # Initialise the Wine prefix once so the first real run is not charged its
        # (multi-second) cold-start cost.
        try: subprocess.run([WINE, "--version"], capture_output=True, timeout=120)
        except Exception: pass
    if a.reduce:
        m = minimize(a.reduce, backends)
        print(m if m else "// could not isolate to a single value (multi-value interaction)")
        return 0
    print(f"backends: {' '.join(label(b) for b in backends)}", file=sys.stderr)
    findings = 0; skipped = 0; done = 0
    seeds = [a.start + i for i in range(a.n)]
    def report(verdict, s, prog, results):
        nonlocal findings, skipped, done
        done += 1
        if verdict == "FINDING":
            findings += 1
            d = save_finding(s, prog, results)
            summ = " ".join(f"{label(b)}={results[b][0]}" for b in backends)
            print(f"[seed {s}] FINDING  {summ}  -> {d}", flush=True)
        elif verdict == "SKIP":
            skipped += 1
            if a.v: print(f"[seed {s}] skip (capacity limit)")
        elif a.v:
            print(f"[seed {s}] ok")
        if done % 25 == 0:
            print(f"  ... {done}/{a.n} done, {findings} findings, {skipped} skipped",
                  file=sys.stderr, flush=True)
    if a.j > 1:
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=a.j) as ex:
            for r in ex.map(lambda s: test_one(s, backends, a.v), seeds):
                report(*r)
    else:
        for s in seeds:
            report(*test_one(s, backends, a.v))
    print(f"\nDone: {a.n} programs, {findings} findings, {skipped} skipped (capacity).")
    return 1 if findings else 0

if __name__ == "__main__":
    sys.exit(main())
