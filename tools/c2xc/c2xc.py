#!/usr/bin/env python3
"""c2xc — C to xc.

    c2xc.py [-o out.xc] [-I dir]... [-D name[=v]]... [--char signed|unsigned]
            [--init-fn name] [--main] file.c [file2.c ...]

Every input file becomes one xc translation unit (files are concatenated in
order, so C's per-file statics are merged; a name defined static in two
files is suffixed with its file's stem). The pipeline:

  1. preprocess with the system cpp against pycparser's fake libc headers
     (real headers carry GNU extensions pycparser will not read);
  2. parse with pycparser;
  3. a C type pass: every expression gets its C type, so the emitter can
     write C's implicit conversions as the casts xc needs — xc does no
     integer promotion, and a comparison is a bool, not an int;
  4. emit xc, lowering what xc lacks: tagged structs, unions, bit-fields,
     multi-dimensional arrays, pointer ++/--, pointer subtraction, calls
     through a function pointer that is not a bare name, do-while, the
     comma operator, C enums, negative or expression case labels, static,
     const, prototypes beside definitions, string literals carrying bytes
     above 7F, aggregate initialisers holding strings or addresses, dead
     code after a terminating statement, and identifiers that are xc
     reserved words.

goto is reported and left as a marker: the function is emitted with the
label as a comment and the jump as an #error line, so the build points at
every one. See README.md for what each lowering does.
"""
import sys, os, re, subprocess, argparse
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "vendor"))
from pycparser import c_parser, c_ast
import libc as LIBC

# ────────────────────────────────────────────────────────────────────────────
# Types. A small model of C types with what the emitter needs: width,
# signedness, pointer/array shape, struct membership and the xc spelling.
# ────────────────────────────────────────────────────────────────────────────
class T:
    """A C type. kind: 'int','float','void','ptr','array','struct','union','fn','enum','bool'"""
    def __init__(self, kind, **kw):
        self.kind = kind
        self.bits = kw.get("bits", 0)          # int/float width
        self.signed = kw.get("signed", True)
        self.to = kw.get("to")                 # ptr/array element
        self.n = kw.get("n")                   # array length (int or None)
        self.name = kw.get("name")             # struct/union/enum tag or typedef name in xc
        self.ret = kw.get("ret"); self.params = kw.get("params"); self.varargs = kw.get("varargs", False)
        self.fields = kw.get("fields")         # struct: list of (name, T, bitwidth)
        self.volatile = kw.get("volatile", False)
    def __repr__(self): return "T(%s)" % self.xc()
    def is_int(self): return self.kind in ("int", "enum", "bool")
    def is_arith(self): return self.is_int() or self.kind == "float"
    def is_ptr(self): return self.kind == "ptr"
    def is_scalar(self): return self.is_arith() or self.is_ptr()
    def is_fnptr(self): return self.kind == "ptr" and self.to is not None and self.to.kind == "fn"
    def rank(self):  # C integer conversion rank
        return {8: 1, 16: 2, 32: 3, 64: 4}.get(self.bits, 3)
    def xc(self):
        k = self.kind
        if k == "void": return "void"
        if k == "bool": return "bool"
        if k == "int" or k == "enum":
            b = self.bits or 32
            return ("i" if self.signed else "u") + str(b)
        if k == "float": return "float" if self.bits == 32 else "double"
        if k == "ptr":
            if self.to is None or self.to.kind == "void": return "pointer"
            if self.to.kind == "fn": return "callback " + callback_sig(self.to)   # type position: a cast, a pointee
            return self.to.xc() + "*"
        if k in ("struct", "union"): return self.name
        if k == "array": return self.to.xc() + "*"     # only where it decays
        if k == "fn": return "callback " + callback_sig(self)
        return "pointer"
    def elem_size(self):
        return size_of(self.to) if self.to else 1

VOID = T("void"); BOOL = T("bool", bits=8, signed=False)
def INT(bits=32, signed=True): return T("int", bits=bits, signed=signed)
def FLT(bits=64): return T("float", bits=bits)
I32 = INT(32); U32 = INT(32, False); I64 = INT(64); U64 = INT(64, False); U8 = INT(8, False); I8 = INT(8); I16 = INT(16); U16 = INT(16, False)
F64 = FLT(64); F32 = FLT(32)
def PTR(t): return T("ptr", to=t)
# What crosses to C is C's: a function pointer in a native prototype or a
# system-header struct is one word, `pointer`, never xc's two-word bound pair
# (which C would read as the code address plus a stray trampoline word --
# right only by luck when the callback is the last argument). Inside converted
# code, where both sides are xc, `callback` stays right.
def cabi(t):
    if t is None: return t
    if t.kind == "fn" or (t.kind == "ptr" and t.to is not None and t.to.kind == "fn"): return PTR(T("void"))
    return t
def cabi_fn(ft):
    if ft.kind == "fn":
        ft.ret = cabi(ft.ret)
        if ft.params: ft.params = [cabi(p) for p in ft.params]
    return ft
# struct tags that are also C library functions, declared through include/
# rather than the libc table
NATIVE_TAGS = {"sigaction", "stat", "flock", "times", "lstat", "fstat", "statfs", "statvfs"}
FOUNDATION_DECLARES = {"write", "random"}
def is_system(coord):
    f = str(getattr(coord, "file", "") or "")
    return "fake_libc_include" in f or "c2xc_pre.h" in f or (os.sep + "c2xc" + os.sep + "include" + os.sep) in f
VOIDP = PTR(VOID); STR = PTR(U8)

# a callback field takes 32 bytes in xcc 0.5's layout (the 01:26 build of
# 2026-09-07 makes sizeof and stride agree on that); C2XC_CB_BYTES overrides
CB_BYTES = int(os.environ.get("C2XC_CB_BYTES", "32"))
BF_UNIT = {1: "u8", 2: "u16", 4: "u32", 8: "u64"}
_slot_cache = {}
def struct_layout(t):
    """A struct's storage as C lays it out: slots ('field', name, T, off) for
    plain members and ('unit', name, size, off, members) for runs of
    bit-fields, members being (name, shift, width, signed, T). A bit-field
    never crosses a boundary of its declared type's size, the first sits in
    the low bits, and a member's declared type still aligns the struct
    (`signed a:8; unsigned b:12; unsigned c:12` is one 32-bit unit, as C
    tools that read the same data expect).
    Returns (slots, size, align)."""
    key = (id(t), len(t.fields or []))
    c = _slot_cache.get(key)
    if c is not None: return c
    slots = []; bit = 0; al = 1; run = None; has_cb = False
    def close():
        nonlocal run, bit
        if run is None: return
        start_bit, end_bit, S, members = run
        b = start_bit // 8; end = (end_bit + 7) // 8
        while b < end:
            need = end - b
            sz = 8 if need > 4 else 4 if need > 2 else 2 if need > 1 else 1
            # the unit must sit aligned for xc to place it where C does
            while sz > 1 and b % sz: sz //= 2
            chunk = [(n, sh - b * 8, w, sg, ft) for n, sh, w, sg, ft in members if b * 8 <= sh < (b + sz) * 8]
            slots.append(("unit", "_bf%d" % b, sz, b, chunk, S)); b += sz
        run = None; bit = end * 8
    for name, ft, bw in (t.fields or []):
        if bw is not None:
            S = max(1, min(8, size_of(ft))); al = max(al, S); ub = S * 8
            if bw == 0:
                close(); bit = (bit + ub - 1) // ub * ub; continue
            if bit // ub != (bit + bw - 1) // ub: close(); bit = (bit + ub - 1) // ub * ub
            if run is None: run = [bit, bit + bw, S, []]
            run[3].append((name, bit, bw, ft.signed, ft)); run[1] = bit + bw; run[2] = max(run[2], S)
            bit += bw; continue
        close()
        a = align_of(ft); al = max(al, a)
        off = ((bit + 7) // 8 + a - 1) // a * a
        slots.append(("field", name, ft, off)); bit = (off + size_of(ft)) * 8
        if (ft.kind == "ptr" and ft.to is not None and ft.to.kind == "fn") or ft.kind == "fn": has_cb = True
    close()
    # a unit smaller than its members' declared type grows to it when nothing follows in the way
    for i, sl in enumerate(slots):
        if sl[0] != "unit" or sl[2] >= sl[5] or sl[3] % sl[5]: continue
        nxt = slots[i + 1][3] if i + 1 < len(slots) else None
        if nxt is None or nxt >= sl[3] + sl[5]:
            slots[i] = ("unit", sl[1], sl[5], sl[3], sl[4], sl[5]); bit = max(bit, (sl[3] + sl[5]) * 8)
    size = (bit + 7) // 8
    # private:xcc-bugs/26 is fixed in the 01:26 build (2026-09-07): sizeof equals the
    # stride, a callback takes CB_BYTES and the struct is padded as usual
    size = (size + al - 1) // al * al
    res = (slots, size, al); _slot_cache[key] = res
    return res
def has_bitfields(t):
    return t.kind == "struct" and any(bw is not None for _, _, bw in (t.fields or []))
def size_of(t):
    if t.kind in ("int", "enum"): return (t.bits or 32) // 8
    if t.kind == "bool": return 1
    if t.kind == "float": return t.bits // 8
    # a callback: xcc 0.5 INDEXES an array of structs with 32 bytes per
    # callback field and no tail padding, though its sizeof says 16 and pads
    # (private:xcc-bugs/26). C walks tables with base + i * sizeof, so the folded
    # size follows the indexing rule -- what agrees with tab[i] is right
    if t.kind == "ptr": return CB_BYTES if (t.to is not None and t.to.kind == "fn") else 8
    if t.kind == "fn": return CB_BYTES
    if t.kind == "array": return (t.n or 0) * size_of(t.to)
    if t.kind in ("struct", "union"):
        if t.kind == "union": return max((size_of(f[1]) for f in (t.fields or [])), default=1)
        return struct_layout(t)[1]
    return 8
def align_of(t):
    if t.kind == "array": return align_of(t.to)
    if t.kind == "union": return max((align_of(f[1]) for f in (t.fields or [])), default=1)
    if t.kind == "struct": return struct_layout(t)[2]
    return min(size_of(t), 8) or 1

# A function pointer is declared inline as `callback f RET(params);` (xcc 0.5).
# The `^` sigil is transitional and 0.6 refuses it, so it is never written.
# A struct parameter is passed as a pointer to a copy, everywhere: xcc 0.5
# cannot put an aggregate on the stack at a call (private:xcc-bugs/20), and one
# convention for definitions, prototypes, callbacks and calls keeps them agreeing.
def byval(t): return t is not None and t.kind in ("struct", "union")
def xc_float(f, double=True):
    """A floating literal as xc spells it: an unsuffixed literal is a binary32
    by design (docs/double.md), a double takes the `d` suffix; the mantissa
    always carries a decimal point, since `1e-05d` does not parse."""
    if f != f or f in (float("inf"), float("-inf")): s = "1.0e308" if f > 0 else "-1.0e308"
    else:
        s = repr(float(f))
        if "e" in s:
            m, x = s.split("e")
            if "." not in m: m += ".0"
            s = m + "e" + x
        elif "." not in s: s += ".0"
    return s + ("d" if double else "")
def callback_sig(fn):
    """'RET(T a0, T a1)' for the 0.5 declaration form."""
    ps = ", ".join("%s a%d" % ((PTR(p) if byval(p) else p).xc(), i) for i, p in enumerate(fn.params or [])) or "void"
    if fn.varargs: ps += ", ..."
    return "%s(%s)" % (fn.ret.xc(), ps)

XC_RESERVED = set("""asm auto bool break case catch class continue default defer delete double else enum
extern false final float for global i8 i16 i32 i64 if in inline new optional pointer protocol register release
retain return sizeof static string struct switch throw throws true try typedef u8 u16 u32 u64 use void volatile while
callback block self super init dealloc va_start va_arg va_end clobbers Object String Array Map Set Data Number step""".split())

# ────────────────────────────────────────────────────────────────────────────
# The converter
# ────────────────────────────────────────────────────────────────────────────
class Conv:
    def __init__(self, char_signed=False, init_fn="c2xc_init_globals"):
        self.char = I8 if char_signed else U8
        self.typedefs = {}          # name -> T
        self.structs = {}           # tag -> T (struct/union)
        self.enums = {}             # constant -> value
        self.funcs = {}             # name -> T(fn)
        self.defined = set()        # functions with bodies
        self.globals = {}           # name -> T
        self.out = []               # emitted lines
        self.pre = []               # statements hoisted before the current statement
        self.tmp = 0
        self.init_stmts = []        # global initialisers that need a run-time init
        self.init_fn = init_fn
        self.bf_lv = {}                        # bit-field read expression -> (object, sep, info) for stores
        self.array_sizes = {}                  # --sizes: global array name -> outermost extent
        self.system_funcs = set()              # prototypes from system headers (C natives)
        self.va_wrappers = {}                  # cross-unit variadics called here -> their type (private:xcc-bugs/33)
        self.va_wrappers_on = False            # --va-wrappers
        self.hoist_double_varargs = False      # --hoist-double-varargs
        self.warnings = []
        self.strings = []           # (name, bytes) for literals that need a byte array
        self.locals = []            # scope stack: list of dict name->T
        self.cur_fn = None
        self.renames = {}
        self.static_fns = {}        # name -> file stem, for cross-file collisions
        self.natives_used = set()
        self.vars_used = set()
        self.used_fns = {}          # functions referenced by call or address
        self.file = ""
        self.externs_done = set()
        self.defined_globals = set()
        self.addr_alias = {}                # &local hoisted before a ternary: name -> the pointer temp
        self.enum_types = set()
        self.type_names = set()     # struct tags and typedef names, as xc will know them
        self.fake_typedefs = set()
        self.forward_only = False   # the current variadic only forwards its tail
        self.goto_state = None      # label -> state while a function is a state machine
        self.goto_depth = 0
        self.loop_depth = 0         # C loops enclosing the current statement
        self.switch_stack = []      # (run, cont) flags of lowered switches enclosing the statement, innermost last
        self.saved_switch = []
        self.inner_loop_depth = 0   # loops inside the innermost lowered switch
        self.needs_rt = False       # c2xc_rt.xc is imported
    # ── diagnostics ────────────────────────────────────────────────────────
    def warn(self, node, msg):
        c = getattr(node, "coord", None)
        self.warnings.append("%s: %s" % (c, msg))
    def ntmp(self, base="t"):
        self.tmp += 1; return "_%s%d" % (base, self.tmp)
    # ── names ──────────────────────────────────────────────────────────────
    def nm(self, name):
        """A value name (variable, function, field, parameter) as xc spells it."""
        if name in self.renames: return self.renames[name]
        if name in XC_RESERVED: return name + "_"
        # C keeps struct tags in their own namespace; xc does not, so a value
        # sharing a tag's name (`struct nat *nat`) is suffixed
        if name in self.type_names: return name + "_"
        return name
    def tn(self, tag):
        """A struct/union tag as an xc type name. C keeps tags and functions
        apart; xc does not, and a native must keep its symbol, so a tag that is
        also a C library function (struct sigaction and sigaction(), struct
        stat and stat()) is the one renamed."""
        if tag in XC_RESERVED or tag in ("String", "Object", "Array", "Map", "Set", "Data", "Number"): return tag + "_t"
        if tag in LIBC.FUNCS or tag in NATIVE_TAGS: return tag + "_s"
        return tag
    # ── type resolution from pycparser nodes ───────────────────────────────
    def type_of_decl(self, node, name_hint=None):
        """T for a Decl/TypeDecl/PtrDecl/ArrayDecl/FuncDecl chain."""
        if isinstance(node, c_ast.Decl):
            t = self.type_of_decl(node.type, node.name)
            if "volatile" in (node.quals or []): t.volatile = True
            return t
        if isinstance(node, c_ast.Typename):
            return self.type_of_decl(node.type)
        if isinstance(node, c_ast.TypeDecl):
            return self.base_type(node.type, name_hint)
        if isinstance(node, c_ast.PtrDecl):
            return PTR(self.type_of_decl(node.type, name_hint))
        if isinstance(node, c_ast.ArrayDecl):
            n = self.const_int(node.dim) if node.dim is not None else None
            return T("array", to=self.type_of_decl(node.type, name_hint), n=n)
        if isinstance(node, c_ast.FuncDecl):
            ret = self.type_of_decl(node.type, name_hint)
            params = []; va = False
            if node.args:
                for p in node.args.params:
                    if isinstance(p, c_ast.EllipsisParam): va = True; continue
                    pt = self.type_of_decl(p)
                    if pt.kind == "void": continue
                    if pt.kind == "array": pt = PTR(pt.to)        # parameters decay
                    if pt.kind == "fn": pt = PTR(pt)
                    params.append(pt)
            return T("fn", ret=ret, params=params, varargs=va)
        raise NotImplementedError(type(node))
    def base_type(self, node, name_hint=None):
        if isinstance(node, c_ast.IdentifierType):
            names = node.names
            key = " ".join(names)
            if len(names) == 1 and names[0] in self.typedefs: return self.typedefs[names[0]]
            return self.builtin(names, node)
        if isinstance(node, (c_ast.Struct, c_ast.Union)):
            return self.struct_type(node)
        if isinstance(node, c_ast.Enum):
            return self.enum_type(node)
        raise NotImplementedError(type(node))
    def builtin(self, names, node):
        s = set(names)
        if "void" in s: return VOID
        if "_Bool" in s: return BOOL
        if "float" in s: return F32
        if "double" in s: return F64
        unsigned = "unsigned" in s; signed = not unsigned
        if "char" in s: return INT(8, "signed" in s or (signed and self.char.signed)) if not unsigned else U8
        if "short" in s: return INT(16, signed)
        if names.count("long") >= 1: return INT(64, signed)
        if "int" in s or unsigned or "signed" in s: return INT(32, signed)
        if len(names) == 1:
            n = names[0]
            known = LIBC.TYPEDEFS.get(n)
            if known: return known
            self.warn(node, "unknown type '%s', treated as pointer" % n)
            return VOIDP
        self.warn(node, "unknown type %r" % names); return I32
    def struct_type(self, node):
        tag = node.name
        kind = "union" if isinstance(node, c_ast.Union) else "struct"
        if node.decls is None:
            # a reference; forward-declared tags are fine in xc (use before body)
            if tag not in self.structs:
                self.structs[tag] = T(kind, name=self.tn(tag), fields=None); self.type_names.add(self.tn(tag))
            return self.structs[tag]
        if tag is None: tag = "_anon%d" % (len(self.structs) + 1)
        t = self.structs.get(tag)
        if t is None: t = T(kind, name=self.tn(tag)); self.structs[tag] = t; self.type_names.add(self.tn(tag))
        fields = []
        for d in node.decls:
            if isinstance(d, c_ast.Decl):
                ft = self.type_of_decl(d)
                bw = self.const_int(d.bitsize) if d.bitsize is not None else None
                if d.name is None:
                    # an anonymous member struct/union: splice its fields in
                    if ft.kind in ("struct", "union") and ft.fields:
                        fields.extend(ft.fields); continue
                fields.append((d.name, ft, bw))
        if is_system(getattr(node, "coord", None)): fields = [(n, cabi(ft), bw) for n, ft, bw in fields]   # C's layout
        t.fields = fields
        t.emitted = False
        return t
    def enum_type(self, node):
        if node.values is not None:
            v = 0
            for e in node.values.enumerators:
                if e.value is not None:
                    cv = self.const_eval(e.value)
                    if cv is None: self.warn(e, "enumerator %s has a value the converter cannot fold; counting on" % e.name)
                    else: v = int(cv)
                self.enums[e.name] = v; v += 1
        return T("enum", bits=32, signed=True, name=node.name)
    # ── constants ──────────────────────────────────────────────────────────
    def str_lit_bytes(self, v):
        """The bytes of a C string literal as pycparser gives it: adjacent
        literals concatenated, escapes decoded."""
        parts = re.findall(r'"((?:[^"\\]|\\.)*)"', v)
        raw = "".join(parts) if parts else v.strip('"')
        try: return bytes(raw, "utf-8").decode("unicode_escape").encode("latin-1")
        except Exception: return raw.encode("utf-8")
    def const_int(self, e):
        v = self.const_eval(e)
        if v is None:
            self.warn(e, "array size is not a constant the converter can fold; declared as a pointer")
            return None
        return int(v)
    def offset_of(self, t, field):
        """Byte offset of a field in a struct, as C lays it out (a bit-field: its unit's)."""
        for sl in struct_layout(t)[0]:
            if sl[0] == "field" and sl[1] == field: return sl[3]
            if sl[0] == "unit" and any(m[0] == field for m in sl[4]): return sl[3]
        return None
    def bf_info(self, t, field):
        """(unit name, unit size, shift, width, signed, T) for a bit-field member, else None."""
        if t.kind != "struct": return None
        for sl in struct_layout(t)[0]:
            if sl[0] == "unit":
                for n, sh, w, sg, ft in sl[4]:
                    if n == field: return (sl[1], sl[2], sh, w, sg, ft)
        return None
    def bf_read(self, obj, sep, info):
        unit, usz, sh, w, sg, ft = info
        ub = 64 if usz == 8 else 32; ut = "u64" if ub == 64 else "u32"; it = "i64" if ub == 64 else "i32"
        base = "%s%s%s" % (obj, sep, unit)
        if sg: r = "(((%s)(((%s)(%s)) << %d)) >> %d)" % (it, ut, base, ub - sh - w, ub - w); rt = it
        else: r = "((((%s)(%s)) >> %d) & %d)" % (ut, base, sh, (1 << w) - 1); rt = ut
        want = ft.xc()
        return r if want == rt else "(%s)%s" % (want, r)
    def bf_write(self, obj, sep, info, val):
        unit, usz, sh, w, sg, ft = info
        ub = usz * 8; ut = BF_UNIT[usz]; mask = (1 << w) - 1
        base = "%s%s%s" % (obj, sep, unit)
        keep = ((1 << ub) - 1) & ~(mask << sh)
        return "%s = (%s)((%s & %d) | ((((%s)(%s)) & %d) << %d))" % (base, ut, base, keep, ut, val, mask, sh)
    def const_eval(self, e):
        if isinstance(e, c_ast.Constant):
            if e.type in ("int", "long", "long long", "unsigned int", "unsigned long", "unsigned long long"):
                return int(self.int_lit(e.value), 0)
            if e.type == "char": return ord(self.char_lit(e.value))
            if e.type in ("float", "double", "long double"): return float(self.float_lit(e.value))
            return None
        if isinstance(e, c_ast.ID):
            return self.enums.get(e.name)
        if isinstance(e, c_ast.UnaryOp):
            if e.op == "sizeof":                      # before the operand: a type name has no value
                if isinstance(e.expr, c_ast.Typename): return size_of(self.type_of_decl(e.expr))
                if isinstance(e.expr, c_ast.Constant) and e.expr.type == "string":     # sizeof("ab" "c") is 4
                    return len(self.str_lit_bytes(e.expr.value)) + 1
                try: return size_of(self.etype(e.expr))
                except Exception: return None
            v = self.const_eval(e.expr)
            if v is None: return None
            if e.op == "-": return -v
            if e.op == "+": return v
            if e.op == "~": return ~int(v)
            if e.op == "!": return int(not v)
            if e.op == "sizeof":
                if isinstance(e.expr, c_ast.Typename): return size_of(self.type_of_decl(e.expr))
                try: return size_of(self.etype(e.expr))
                except Exception: return None
            return None
        if isinstance(e, c_ast.BinaryOp):
            a = self.const_eval(e.left); b = self.const_eval(e.right)
            if a is None or b is None: return None
            try:
                return {"+": a + b, "-": a - b, "*": a * b, "/": (int(a / b) if isinstance(a, int) and isinstance(b, int) else a / b) if b else None,
                        "%": (a % b) if b else None, "<<": int(a) << int(b), ">>": int(a) >> int(b), "&": int(a) & int(b),
                        "|": int(a) | int(b), "^": int(a) ^ int(b), "<": int(a < b), ">": int(a > b), "<=": int(a <= b), ">=": int(a >= b),
                        "==": int(a == b), "!=": int(a != b), "&&": int(bool(a) and bool(b)), "||": int(bool(a) or bool(b))}[e.op]
            except Exception: return None
        if isinstance(e, c_ast.Cast):
            # offsetof: (unsigned long)&(((T*)0)->f)
            inner = e.expr
            if isinstance(inner, c_ast.UnaryOp) and inner.op == "&" and isinstance(inner.expr, c_ast.StructRef):
                sr = inner.expr
                base = sr.name
                if isinstance(base, c_ast.Cast) and self.const_eval(base.expr) == 0:
                    bt = self.type_of_decl(base.to_type)
                    if bt.kind == "ptr" and bt.to.kind in ("struct", "union"):
                        o = self.offset_of(bt.to, sr.field.name)
                        if o is not None: return o
            v = self.const_eval(e.expr)
            if v is None: return None
            t = self.type_of_decl(e.to_type)
            if t.is_int():
                v = int(v); bits = t.bits or 32; v &= (1 << bits) - 1
                if t.signed and v >= 1 << (bits - 1): v -= 1 << bits
            return v
        if isinstance(e, c_ast.TernaryOp):
            c = self.const_eval(e.cond)
            if c is None: return None
            return self.const_eval(e.iftrue if c else e.iffalse)
        return None
    def int_lit(self, s):
        s = s.rstrip("uUlL")
        if s.startswith("0") and len(s) > 1 and s[1] not in "xXbB": return str(int(s, 8))
        return s
    def float_lit(self, s):
        return s.rstrip("fFlL")
    def char_lit(self, s):
        # 'a', '\n', '\x41', '\101'
        body = s[1:-1]
        return bytes(body, "utf-8").decode("unicode_escape") if body.startswith("\\") else body
    # ── expression types (C semantics) ─────────────────────────────────────
    def lookup(self, name):
        for sc in reversed(self.locals):
            if name in sc: return sc[name]
        if name in self.globals: return self.globals[name]
        if name in self.funcs: return self.funcs[name]
        if name in self.enums: return I32
        if name in LIBC.FUNCS: return LIBC.FUNCS[name]
        if name in LIBC.VARS: return LIBC.VARS[name]
        return None
    def lookup_local(self, name):
        for sc in reversed(self.locals):
            if name in sc: return sc[name]
        return None
    def etype(self, e):
        """C type of expression e, after array decay."""
        t = self.etype_raw(e)
        return t
    def etype_raw(self, e):
        if isinstance(e, c_ast.Constant):
            if e.type == "char": return I32
            if e.type in ("float",): return F32 if e.value[-1] in "fF" else F64
            if e.type in ("double", "long double"): return F64
            if e.type == "string": return T("array", to=U8, n=None)
            s = e.value; suf = s.lstrip("0123456789xXabcdefABCDEF")
            u = "u" in suf.lower(); l = suf.lower().count("l")
            v = int(self.int_lit(s), 0)
            if l or v > 0xFFFFFFFF: return INT(64, not u)
            if u or (v > 0x7FFFFFFF and (s.startswith("0x") or s.startswith("0X") or s.startswith("0"))): return U32 if v <= 0xFFFFFFFF else U64
            return I32
        if isinstance(e, c_ast.ID):
            t = self.lookup(e.name)
            if t is None:
                self.warn(e, "unknown identifier '%s'" % e.name); return I32
            return t
        if isinstance(e, c_ast.UnaryOp):
            if e.op == "sizeof": return U64
            if e.op == "&":
                t = self.etype_raw(e.expr)
                if t.kind == "fn": return PTR(t)
                return PTR(t)
            if e.op == "*":
                t = self.etype(e.expr)
                if t.kind in ("ptr", "array"): return t.to
                if t.kind == "fn": return t
                return I32
            if e.op == "!": return I32
            t = self.etype(e.expr)
            if e.op in ("-", "+", "~"): return self.promote(t)
            return t   # ++ --
        if isinstance(e, c_ast.BinaryOp):
            a = self.etype(e.left); b = self.etype(e.right)
            if e.op in ("<", ">", "<=", ">=", "==", "!=", "&&", "||"): return I32
            if e.op in ("+", "-"):
                if a.kind in ("ptr", "array") and b.is_int(): return PTR(a.to) if a.kind == "array" else a
                if b.kind in ("ptr", "array") and a.is_int() and e.op == "+": return PTR(b.to) if b.kind == "array" else b
                if a.kind in ("ptr", "array") and b.kind in ("ptr", "array"): return I64
            if e.op in ("<<", ">>"): return self.promote(a)
            return self.usual(a, b)
        if isinstance(e, c_ast.Assignment): return self.etype(e.lvalue)
        if isinstance(e, c_ast.TernaryOp):
            a = self.etype(e.iftrue); b = self.etype(e.iffalse)
            if a.is_arith() and b.is_arith(): return self.usual(a, b)
            if a.kind == "ptr": return a
            if b.kind == "ptr": return b
            if a.kind == "array": return PTR(a.to)
            return a
        if isinstance(e, c_ast.Cast): return self.type_of_decl(e.to_type)
        if isinstance(e, c_ast.FuncCall):
            ft = self.etype(e.name)
            if ft.kind == "ptr" and ft.to.kind == "fn": ft = ft.to
            if ft.kind == "fn": return ft.ret
            if isinstance(e.name, c_ast.ID) and e.name.name in LIBC.FUNCS: return LIBC.FUNCS[e.name.name].ret
            self.warn(e, "call of non-function"); return I32
        if isinstance(e, c_ast.ArrayRef):
            t = self.etype(e.name)
            if t.kind in ("ptr", "array"): return t.to
            t2 = self.etype(e.subscript)
            if t2.kind in ("ptr", "array"): return t2.to
            return I32
        if isinstance(e, c_ast.StructRef):
            t = self.etype(e.name)
            if e.type == "->" and t.kind in ("ptr", "array"): t = t.to
            f = self.field(t, e.field.name)
            return f[1] if f else I32
        if isinstance(e, c_ast.ExprList): return self.etype(e.exprs[-1])
        if isinstance(e, c_ast.CompoundLiteral): return self.type_of_decl(e.type)
        return I32
    def field(self, t, name):
        for f in (t.fields or []):
            if f[0] == name: return f
        self.warn(None, "no field '%s' in %s" % (name, t.name)); return None
    def promote(self, t):
        if t.is_int() and (t.bits or 32) < 32: return I32
        if t.kind == "bool": return I32
        return t
    def usual(self, a, b):
        if a.kind == "float" or b.kind == "float":
            return F64 if (a.kind == "float" and a.bits == 64) or (b.kind == "float" and b.bits == 64) else F32
        if not (a.is_int() and b.is_int()): return a if a.is_scalar() else b
        a = self.promote(a); b = self.promote(b)
        if a.bits == b.bits and a.signed == b.signed: return a
        if a.bits != b.bits:
            w = a if a.bits > b.bits else b; n = b if w is a else a
            if not w.signed: return w
            if n.signed: return w
            return w                      # signed wider holds the unsigned narrower
        return INT(a.bits, False)
    # ── emitting types ─────────────────────────────────────────────────────
    def decl_str(self, t, name, field=False):
        """'T name' for a declaration, flattening arrays. A struct field's callback
        is spelled signature-then-name (xcc 0.5 reads only that form there)."""
        if field and (t.kind == "fn" or (t.kind == "ptr" and t.to is not None and t.to.kind == "fn")):
            return "callback %s %s" % (callback_sig(t if t.kind == "fn" else t.to), name)
        if t.kind == "array":
            base, dims = self.flat(t)
            n = 1
            for d in dims:
                if d is None: n = None; break
                n *= d
            fnb = base.to if (base.kind == "ptr" and base.to is not None and base.to.kind == "fn") else (base if base.kind == "fn" else None)
            if n is None:
                # an array of unknown extent (`extern T x[]`): xc takes the
                # unsized form and its linker sizes the common symbol from
                # the defining unit; a pointer here made a per-file
                # link give a nine-entry table 8 bytes
                dims = []; tt = t
                while tt.kind == "array": dims.append(tt.n); tt = tt.to
                if dims[0] is None and all(d is not None for d in dims[1:]):
                    # with --sizes, the extent the defining unit gave it: xcc's
                    # linker keeps the LAST object's common size, so every
                    # unit must agree (private:xcc-bugs/32)
                    known = self.array_sizes.get(name)
                    if known is not None:
                        n = known
                        for d in dims[1:]: n *= d
                        return ("callback %s %s[%d]" % (name, callback_sig(fnb), n)) if fnb is not None else "%s %s[%d]" % (base.xc(), name, n)
                    return ("callback %s %s[]" % (name, callback_sig(fnb))) if fnb is not None else "%s %s[]" % (base.xc(), name)
                return ("callback %s %s*" % (name, callback_sig(fnb))) if fnb is not None else "%s* %s" % (base.xc(), name)
            if fnb is not None: return "callback %s %s[%d]" % (name, callback_sig(fnb), n)
            return "%s %s[%d]" % (base.xc(), name, n)
        if t.kind == "fn": return "callback %s %s" % (name, callback_sig(t))
        if t.kind == "ptr" and t.to is not None and t.to.kind == "fn": return "callback %s %s" % (name, callback_sig(t.to))
        return "%s %s" % (t.xc(), name)
    def flat(self, t):
        dims = []
        while t.kind == "array": dims.append(t.n); t = t.to
        return t, dims
    # ── expressions ────────────────────────────────────────────────────────
    def cast(self, s, frm, to):
        """Wrap s (of C type frm) so it reads as xc type `to`."""
        if to is None: return s
        if frm.kind == "array" and to.kind == "ptr":
            # an array decays as the address of its first element: xcc 0.5
            # crashes on `i32* p = arr;` though it takes `f(arr)`
            return s if s.startswith("&") else "&%s[0]" % self.paren(s)
        if frm.is_int() and to.is_int():
            if frm.kind == "bool" or (frm.bits, frm.signed) != (to.bits, to.signed): return "(%s)(%s)" % (to.xc(), s)
            return s
        if frm.kind == "float" and to.kind == "float":
            return s if frm.bits == to.bits else "(%s)(%s)" % (to.xc(), s)
        if frm.is_arith() and to.is_arith(): return "(%s)(%s)" % (to.xc(), s)
        if to.kind == "ptr" and frm.kind == "ptr":
            # to C: the cast takes the code address out of the pair; from C: a
            # pair cannot yet be made from an address (private:xcc-bugs/14), so the cast
            # is spelled and the value is not callable
            if frm.is_fnptr() and not to.is_fnptr(): return "(pointer)(%s)" % s
            if to.is_fnptr() and not frm.is_fnptr(): self.cb_from_c = getattr(self, "cb_from_c", 0) + 1; return "(%s)(%s)" % (to.xc(), s)
            if to.is_fnptr() or frm.is_fnptr(): return s
            return s if frm.xc() == to.xc() else "(%s)(%s)" % (to.xc(), s)
        if to.kind == "ptr" and frm.is_int(): return "(%s)(%s)" % (to.xc(), s)
        if to.is_int() and frm.kind == "ptr": return "(%s)(%s)" % (to.xc(), s)
        if to.kind == "bool": return s
        return s
    def ex(self, e, want=None, ctx="value"):
        """Emit expression e. want: the C type the context expects (casts inserted).
        ctx: 'value' | 'cond' (a boolean context: no int cast on comparisons) | 'stmt'."""
        s, t = self.ex_raw(e, ctx)
        if ctx == "cond" and t.kind != "bool" and not self.is_cond_expr(e):
            # an int or a pointer as a condition: the comparison written out
            return "%s != 0" % self.paren(s)
        if want is not None: s = self.cast(s, t, want)
        return s
    def is_cond_expr(self, e):
        if isinstance(e, c_ast.BinaryOp): return e.op in ("<", ">", "<=", ">=", "==", "!=", "&&", "||")
        if isinstance(e, c_ast.UnaryOp): return e.op == "!"
        return False
    def ex_t(self, e, ctx="value"):
        return self.ex_raw(e, ctx)
    def paren(self, s):
        return s if re.match(r"^[A-Za-z_][A-Za-z_0-9]*$", s) or re.match(r"^-?[0-9.]+$", s) else "(" + s + ")"
    def ex_raw(self, e, ctx="value"):
        """-> (text, C type)"""
        if isinstance(e, c_ast.Constant):
            t = self.etype(e)
            if e.type == "string": return self.string_lit(e.value), t
            if e.type == "char":
                c = self.char_lit(e.value); return str(ord(c)), I32
            if e.type in ("float", "double", "long double"):
                # xc reads d.d and d.de±d; C also allows 1e4, 1., .5: normalise through Python
                v = self.float_lit(e.value)
                v = xc_float(float(v), double=(e.type != "float"))
                return v, t
            v = int(self.int_lit(e.value), 0)
            return str(v), t
        if isinstance(e, c_ast.ID):
            if e.name in self.enums: return str(self.enums[e.name]), I32
            t = self.etype(e)
            # a function used as a value (not called) is its address: a ^ in xc
            if t.kind == "fn" and ctx != "callee":
                self.used_fns[e.name] = True
                if e.name in LIBC.FUNCS and e.name not in self.defined: self.natives_used.add(e.name)
                return "&" + self.nm(e.name), PTR(t)
            if e.name in LIBC.VARS and self.lookup_local(e.name) is None and e.name not in self.globals:
                if e.name in LIBC.RT_VARS: self.needs_rt = True; return LIBC.RT_VARS[e.name], t
                self.vars_used.add(e.name); return LIBC.VAR_SYMBOL.get(e.name, e.name), t
            return self.nm(e.name), t
        if isinstance(e, c_ast.UnaryOp):
            return self.unary(e, ctx)
        if isinstance(e, c_ast.BinaryOp):
            # all-constant integer arithmetic is folded here: xcc 0.5 folds a
            # literal dividend modulo 256 (private:xcc-bugs/27: 840/56 gives 1)
            cv = self.const_eval(e)
            if cv is not None and isinstance(cv, int) and not isinstance(cv, bool) and e.op in ("/", "%", "*", "+", "-", "<<", ">>", "&", "|", "^"):
                tb0 = self.etype(e)
                if e.op in ("/", "%"):
                    # C truncates toward zero; Python floors
                    a0 = self.const_eval(e.left); b0 = self.const_eval(e.right)
                    if isinstance(a0, int) and isinstance(b0, int) and b0 != 0:
                        q = abs(a0) // abs(b0); q = -q if (a0 < 0) != (b0 < 0) else q
                        cv = q if e.op == "/" else a0 - q * b0
                    else: cv = None
                if cv is not None and tb0.is_int(): return ("(%s)" % cv if cv < 0 else str(cv)), tb0
            return self.binary(e, ctx)
        if isinstance(e, c_ast.Assignment):
            return self.assign(e)
        if isinstance(e, c_ast.TernaryOp):
            t = self.etype(e)
            c = self.ex(e.cond, ctx="cond")
            want = t if (t.is_arith() or t.kind == "ptr") else None    # a pointer result decays an array branch
            # &local inside a branch is refused by xcc 0.5 ("not pinned",
            # private:xcc-bugs/19): its address is taken once, before the ternary
            saved = dict(self.addr_alias)
            for node in self.walk(e.iftrue) + self.walk(e.iffalse):
                if isinstance(node, c_ast.UnaryOp) and node.op == "&" and isinstance(node.expr, c_ast.ID) and node.expr.name not in self.addr_alias and self.is_local(node.expr.name):
                    lt = self.etype(node.expr); tmp = self.ntmp("adr")
                    self.pre.append("%s = &%s;" % (self.decl_str(PTR(lt), tmp), self.nm(node.expr.name)))
                    self.addr_alias[node.expr.name] = tmp
            # a branch that hoists statements (a comma expression, a
            # post-increment: CANT_HAPPEN's (oops(), 1)) must run them only on
            # that branch, so the ternary becomes an if/else on a temporary
            pre0 = len(self.pre)
            a = self.ex(e.iftrue, want); pa = self.pre[pre0:]; del self.pre[pre0:]
            b = self.ex(e.iffalse, want); pb = self.pre[pre0:]; del self.pre[pre0:]
            self.addr_alias = saved
            if pa or pb:
                if t.kind == "void":
                    self.pre.append("if (%s) {" % c); self.pre.extend("    " + x for x in pa); self.pre.append("    %s;" % a)
                    self.pre.append("} else {"); self.pre.extend("    " + x for x in pb); self.pre.append("    %s;" % b); self.pre.append("}")
                    return "0", I32
                tmp = self.ntmp("tern"); self.pre.append(self.decl_str(t, tmp) + ";")
                self.pre.append("if (%s) {" % c); self.pre.extend("    " + x for x in pa); self.pre.append("    %s = %s;" % (tmp, a))
                self.pre.append("} else {"); self.pre.extend("    " + x for x in pb); self.pre.append("    %s = %s;" % (tmp, b)); self.pre.append("}")
                return tmp, t
            return "(%s ? %s : %s)" % (c, a, b), t
        if isinstance(e, c_ast.Cast):
            to = self.type_of_decl(e.to_type)
            cv = self.const_eval(e)
            if cv is not None and isinstance(e.expr, c_ast.UnaryOp) and e.expr.op == "&": return str(int(cv)), to
            s, frm = self.ex_raw(e.expr)
            if to.kind == "void": return s, VOID
            if to.is_fnptr(): return s, to                      # a callback is not cast
            if frm.kind == "array": frm = PTR(frm.to)
            if frm.kind == "bool" or (frm.is_int() and (frm.bits, frm.signed) == (to.bits, to.signed)) and to.is_int() and frm.kind != "bool":
                return s, to
            return "(%s)(%s)" % (to.xc(), s), to
        if isinstance(e, c_ast.FuncCall):
            return self.call(e)
        if isinstance(e, c_ast.ArrayRef):
            return self.index(e)
        if isinstance(e, c_ast.StructRef):
            return self.member(e)
        if isinstance(e, c_ast.ExprList):
            # comma: hoist all but the last
            for x in e.exprs[:-1]: self.pre.append(self.ex(x, ctx="stmt") + ";")
            return self.ex_raw(e.exprs[-1], ctx)
        if isinstance(e, c_ast.CompoundLiteral):
            self.warn(e, "compound literal: hoisted to a temporary")
            t = self.type_of_decl(e.type); n = self.ntmp("cl")
            self.pre.append(self.decl_str(t, n) + ";")
            self.pre.extend(self.init_stmts_for(n, t, e.init))
            return n, t
        self.warn(e, "unsupported expression %s" % type(e).__name__)
        return "/* unsupported */0", I32
    def string_lit(self, raw):
        """A C string literal (with quotes, possibly several adjacent) as an xc literal or a byte array."""
        # pycparser hands adjacent literals joined? it keeps them as one Constant with quotes concatenated
        parts = re.findall(r'"((?:[^"\\]|\\.)*)"', raw)
        body = "".join(parts)
        b = self.unescape(body)
        if all(0x20 <= c < 0x7F or c in (9, 10, 13) for c in b) and b.find(0) < 0:
            out = ""
            for c in b:
                ch = chr(c)
                if ch == '"': out += '\\"'
                elif ch == "\\": out += "\\\\"
                elif ch == "\n": out += "\\n"
                elif ch == "\t": out += "\\t"
                elif ch == "\r": out += "\\r"
                else: out += ch
            return '"' + out + '"'
        # bytes xc's literal cannot spell: a global byte array, decayed
        name = "_str%d" % (len(self.strings) + 1)
        self.strings.append((name, b))
        return "(&%s[0])" % name
    def unescape(self, s):
        out = bytearray(); i = 0
        while i < len(s):
            c = s[i]
            if c != "\\": out += c.encode("utf-8"); i += 1; continue
            i += 1; c = s[i]
            if c in "01234567":
                j = i
                while j < len(s) and j < i + 3 and s[j] in "01234567": j += 1
                out.append(int(s[i:j], 8) & 0xFF); i = j; continue
            if c == "x":
                j = i + 1
                while j < len(s) and s[j] in "0123456789abcdefABCDEF": j += 1
                out.append(int(s[i+1:j], 16) & 0xFF); i = j; continue
            out.append({"n": 10, "t": 9, "r": 13, "0": 0, "a": 7, "b": 8, "f": 12, "v": 11, "\\": 92, '"': 34, "'": 39, "?": 63, "e": 27}.get(c, ord(c)))
            i += 1
        return bytes(out)
    def lvalue_ptr(self, e):
        """The address of an lvalue expression, as (text, C type of the pointee)."""
        s, t = self.ex_raw(e)
        return "&" + self.paren(s), t
    def unary(self, e, ctx):
        op = e.op
        if op == "sizeof":
            if isinstance(e.expr, c_ast.Typename): t = self.type_of_decl(e.expr)
            elif isinstance(e.expr, c_ast.Constant) and e.expr.type == "string":
                return str(len(self.str_lit_bytes(e.expr.value)) + 1), U64          # sizeof("ab" "c") is 4
            else: t = self.etype(e.expr)
            return str(size_of(t)), U64
        if op == "&":
            if isinstance(e.expr, c_ast.ID) and e.expr.name in self.addr_alias: return self.addr_alias[e.expr.name], PTR(self.etype(e.expr))
            s, t = self.ex_raw(e.expr)
            if t.kind == "ptr" and t.to is not None and t.to.kind == "fn" and s.startswith("&"):
                return s, t                                       # &fn: already the address
            if t.kind == "fn":
                return "&" + s, PTR(t)
            if t.kind == "array":
                return "&" + self.paren(s) + "[0]" if not s.startswith("&") else s, PTR(T("array", to=t.to, n=t.n))
            # &(*X) is X: the union-access lowering yields (*(T*)p), and the
            # front end refuses the address of that shape
            m = re.fullmatch(r"\(\*(.*)\)", s)
            if m:
                inner = m.group(1); depth = 0; ok = True
                for ch in inner:
                    if ch == "(": depth += 1
                    elif ch == ")":
                        depth -= 1
                        if depth < 0: ok = False; break
                if ok and depth == 0: return "(" + inner + ")", PTR(t)
            return "&" + self.paren(s), PTR(t)
        if op == "*":
            s, t = self.ex_raw(e.expr)
            if t.kind == "array": return self.paren(s) + "[0]", t.to
            if t.kind == "ptr":
                if t.to.kind == "fn": return s, t
                return "*" + self.paren(s), t.to
            return "*" + self.paren(s), I32
        if op == "!":
            # !x on a float is spelled (x == 0): after a prior compare the
            # backend emits an integer cmp on the float register (private:xcc-bugs/23)
            if self.etype(e.expr).kind == "float":
                fs, ft2 = self.ex_raw(e.expr); return "(%s == 0)" % fs, BOOL
            s, t = self.ex_raw(e.expr, "cond")
            r = "!" + self.paren(s)
            return (r if ctx == "cond" else "(i32)(%s)" % r), I32
        if op in ("-", "+", "~"):
            t = self.etype(e)
            s = self.ex(e.expr, t)
            return "%s%s" % (op, self.paren(s)), t
        if op in ("++", "--", "p++", "p--"):
            s, t = self.ex_raw(e.expr)
            delta = "1"
            if t.kind == "ptr":
                if op in ("++", "--"):
                    self.pre.append("%s = %s %s 1;" % (s, s, op[0]))
                    return s, t
                n = self.ntmp()
                self.pre.append("%s = %s;" % (self.decl_str(t, n), s))
                self.pre.append("%s = %s %s 1;" % (s, s, op[1]))
                return n, t
            # xc's ++/-- takes a name or a subscript; a member or a deref is written out.
            # Outside a statement the step is hoisted (xcc 0.5 hangs on `n-- > 0`
            # in a condition), which the loop emitters turn into a re-tested form.
            simple = isinstance(e.expr, (c_ast.ID, c_ast.ArrayRef))
            step = "%s = %s %s 1" % (s, s, op[-1])
            bf = self.bf_lv.get(s)
            if bf is not None: step = self.bf_write(bf[0], bf[1], bf[2], "%s %s 1" % (s, op[-1]))
            if ctx == "stmt":
                if simple: return "%s%s" % (s, op[1:] if op.startswith("p") else op), t
                return step, t
            if t.kind != "ptr":
                if op.startswith("p"):
                    n = self.ntmp()
                    self.pre.append("%s = %s;" % (self.decl_str(t, n), s)); self.pre.append(step + ";")
                    return n, t
                self.pre.append(step + ";"); return s, t
            if op.startswith("p"):
                n = self.ntmp()
                self.pre.append("%s = %s;" % (self.decl_str(t, n), s))
                self.pre.append(("%s%s;" % (s, op[1:])) if simple else step + ";")
                return n, t
            self.pre.append(("%s%s;" % (s, op)) if simple else step + ";")
            return s, t
        self.warn(e, "unary %s" % op); return "0", I32
    def fold_lits(self, a, op, b):
        """Two integer literals under an arithmetic operator: the value, with
        C's truncating division. xcc 0.5 folds a literal dividend modulo 256
        (private:xcc-bugs/27), so the converter folds first."""
        m1 = re.fullmatch(r"\(?(-?\d+)\)?", a); m2 = re.fullmatch(r"\(?(-?\d+)\)?", b)
        if not (m1 and m2) or op not in ("+", "-", "*", "/", "%", "<<", ">>", "&", "|", "^"): return None
        x, y = int(m1.group(1)), int(m2.group(1))
        if op in ("/", "%"):
            if y == 0: return None
            q = abs(x) // abs(y); q = -q if (x < 0) != (y < 0) else q
            v = q if op == "/" else x - q * y
        elif op == "<<": v = x << y if 0 <= y < 64 else None
        elif op == ">>": v = x >> y if 0 <= y < 64 else None
        else: v = {"+": x + y, "-": x - y, "*": x * y, "&": x & y, "|": x | y, "^": x ^ y}[op]
        if v is None: return None
        return ("(%d)" % v) if v < 0 else str(v)
    def binary(self, e, ctx):
        op = e.op
        if op in ("&&", "||"):
            a = self.ex(e.left, ctx="cond")
            # the right side's hoisted statements run only when it is reached
            pre0 = len(self.pre); b = self.ex(e.right, ctx="cond"); pb = self.pre[pre0:]; del self.pre[pre0:]
            if pb:
                tmp = self.ntmp("sc"); self.pre.append("bool %s = (%s);" % (tmp, a))
                self.pre.append("if (%s%s) {" % ("" if op == "&&" else "!", tmp)); self.pre.extend("    " + x for x in pb)
                self.pre.append("    %s = (%s);" % (tmp, b)); self.pre.append("}")
                r = tmp
            else:
                r = "%s %s %s" % (self.paren(a), op, self.paren(b))
            return (r if ctx == "cond" else "(i32)(%s)" % r), I32
        ta = self.etype(e.left); tb = self.etype(e.right)
        if op in ("<", ">", "<=", ">=", "==", "!="):
            if ta.is_arith() and tb.is_arith():
                u = self.usual(ta, tb)
                a = self.ex(e.left, u); b = self.ex(e.right, u)
            else:
                # pointer comparisons; a 0 against a pointer stays 0
                a = self.ex(e.left); b = self.ex(e.right)
                if ta.kind == "ptr" and tb.is_int() and b != "0": b = "(%s)(%s)" % (ta.xc(), b)
                if tb.kind == "ptr" and ta.is_int() and a != "0": a = "(%s)(%s)" % (tb.xc(), a)
                if ta.kind == "ptr" and tb.kind == "ptr" and ta.xc() != tb.xc() and not ta.is_fnptr(): b = "(%s)(%s)" % (ta.xc(), b)
            r = "%s %s %s" % (self.paren(a), op, self.paren(b))
            return (r if ctx == "cond" else "(i32)(%s)" % r), I32
        if op in ("+", "-") and (ta.kind in ("ptr", "array") or tb.kind in ("ptr", "array")):
            if ta.kind in ("ptr", "array") and tb.kind in ("ptr", "array"):
                a = self.ex(e.left); b = self.ex(e.right)
                el = size_of(ta.to)
                r = "((i64)((u64)(%s) - (u64)(%s)) / %d)" % (a, b, el) if el != 1 else "(i64)((u64)(%s) - (u64)(%s))" % (a, b)
                return r, I64
            if tb.kind in ("ptr", "array"): e.left, e.right = e.right, e.left; ta, tb = tb, ta
            a = self.ex(e.left); b = self.ex(e.right, I64)
            if ta.kind == "array":
                a = "&" + self.paren(a) + "[0]"
            return "%s %s %s" % (self.paren(a), op, self.paren(b)), (PTR(ta.to) if ta.kind == "array" else ta)
        if op in ("<<", ">>"):
            t = self.promote(ta)
            a = self.ex(e.left, t); b = self.ex(e.right, self.promote(tb))
            f = self.fold_lits(a, op, b)
            if f is not None and t.is_int(): return f, t
            return "%s %s %s" % (self.paren(a), op, self.paren(b)), t
        t = self.usual(ta, tb)
        a = self.ex(e.left, t); b = self.ex(e.right, t)
        f = self.fold_lits(a, op, b)
        if f is not None and t.is_int(): return f, t
        return "%s %s %s" % (self.paren(a), op, self.paren(b)), t
    def assign(self, e):
        op = e.op
        ls, lt = self.ex_raw(e.lvalue)
        bf = self.bf_lv.get(ls)
        if bf is not None:
            # a bit-field: read-modify-write of its unit
            if op == "=": v = self.ex(e.rvalue, lt)
            else:
                bop = op[:-1]; rt = self.etype(e.rvalue)
                if bop in ("<<", ">>"): tt = self.promote(lt); r = self.ex(e.rvalue, self.promote(rt))
                else: tt = self.usual(lt, rt); r = self.ex(e.rvalue, tt)
                v = self.cast("%s %s %s" % (self.paren(self.cast(ls, lt, tt)), bop, self.paren(r)), tt, lt)
            return self.bf_write(bf[0], bf[1], bf[2], v), lt
        if op == "=":
            r = self.ex(e.rvalue, lt if lt.is_scalar() else None)
            # a callback stored into a union member: xc's store releases the
            # old value it finds there, and punned bytes are not a callback
            # (the converted server died in the weak registry on a stack
            # valstr), so the member's bytes are cleared first
            if lt.is_fnptr():
                m = re.fullmatch(r"\(\*\((\w+)\*\)&(.+)\.raw\[0\]\)\.(\w+)", ls)
                if m:
                    st = next((t for t in self.structs.values() if t.name == m.group(1)), None)
                    if st is not None and st.fields:
                        self.pre.append("memset((pointer)(&(%s).raw[%d]), 0, 16);" % (m.group(2), self.offset_of(st, m.group(3))))
                        self.natives_used.add("memset")
            return "%s = %s" % (ls, r), lt
        bop = op[:-1]
        if lt.kind == "ptr" and bop in ("+", "-"):
            r = self.ex(e.rvalue, I64)
            return "%s = %s %s %s" % (ls, ls, bop, self.paren(r)), lt
        rt = self.etype(e.rvalue)
        if bop in ("<<", ">>"): t = self.promote(lt); r = self.ex(e.rvalue, self.promote(rt))
        else: t = self.usual(lt, rt); r = self.ex(e.rvalue, t)
        lhs = self.cast(ls, lt, t)
        return "%s = %s" % (ls, self.cast("%s %s %s" % (self.paren(lhs), bop, self.paren(r)), t, lt)), lt
    def call(self, e):
        fn = e.name
        args = e.args.exprs if e.args else []
        # the callee
        if isinstance(fn, c_ast.ID):
            name = fn.name
            ft = self.lookup(name)
            if name in LIBC.REWRITE:
                return LIBC.REWRITE[name](self, e, args)
            if ft is None:
                self.warn(e, "call of undeclared function '%s'" % name)
                ft = T("fn", ret=I32, params=[], varargs=True)
            if ft.kind == "ptr": ft = ft.to
            if ft.kind != "fn":
                self.warn(e, "'%s' is not a function" % name); return "0", I32
            callee = self.nm(name)
            # --va-wrappers: builds before 2026-09-07 13:42 took a bodiless
            # variadic prototype for a C native and passed nothing (private:xcc-bugs/33,
            # fixed by xcc 179); a forwarded pack arrived, so the call went
            # through a local forwarding wrapper. Off by default now.
            if self.va_wrappers_on and ft.varargs and name not in self.defined and name not in LIBC.FUNCS and name not in self.system_funcs and name not in LIBC.REWRITE:
                self.va_wrappers[name] = ft; callee = callee + "__va"
            self.used_fns[name] = True
            if name in LIBC.FUNCS and name not in self.defined: self.natives_used.add(name)
        else:
            s, ft = self.ex_raw(fn)
            if ft.kind == "ptr" and ft.to.kind == "fn": ft = ft.to
            if ft.kind != "fn":
                self.warn(e, "call through non-function"); ft = T("fn", ret=I32, params=[], varargs=True)
            # xc calls a ^ only by a bare name: hoist
            if isinstance(fn, c_ast.UnaryOp) and fn.op == "*" and isinstance(fn.expr, c_ast.ID):
                callee = self.nm(fn.expr.name)
            else:
                callee = self.ntmp("fn")
                self.pre.append("%s = %s;" % (self.decl_str(PTR(ft), callee), s))
        out = []
        # a callback is a two-word pair and cannot go on the stack (private:xcc-bugs/21):
        # count the integer-register slots so a pair past x7 is at least named
        slot = 0
        for i, p in enumerate(ft.params or []):
            w = 2 if (p.kind == "ptr" and p.to is not None and p.to.kind == "fn") or p.kind == "fn" else (0 if p.kind == "float" else 1)
            if w == 2 and slot + 2 > 8: self.warn(e, "a callback argument past the eighth register slot (param %d of %s): private:xcc-bugs/21" % (i, callee))
            slot += w
        for i, a in enumerate(args):
            if i < len(ft.params or []):
                p = ft.params[i]
                at = self.etype(a)
                if byval(p):
                    s = self.ex(a)
                    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\]|\.[A-Za-z_][A-Za-z0-9_]*|->[A-Za-z_][A-Za-z0-9_]*)*", s) or s.startswith("(*"):
                        out.append("&" + self.paren(s))
                    else:
                        tmp = self.ntmp("bv"); self.pre.append("%s = %s;" % (self.decl_str(p, tmp), s)); out.append("&" + tmp)
                elif p.kind == "ptr" and p.to is not None and p.to.kind == "fn":
                    out.append(self.ex(a))                    # a bare function name already comes as &name
                elif p.kind == "ptr" and at.kind == "array":
                    # spelled, never implicit: a member array decaying on its own
                    # compiles to something that segfaults (private:xcc-bugs/22)
                    s = self.ex(a); out.append(s if s.startswith("&") else "&" + self.paren(s) + "[0]")
                else:
                    out.append(self.ex(a, p if p.is_scalar() else None))
            else:
                # variadic tail: C default promotions
                at = self.etype(a)
                if at.kind in ("struct", "union"): self.warn(a, "an aggregate passed through '...' (private:xcc-bugs/20: the stack cannot take it)")
                if at.kind == "array":
                    s = self.ex(a); out.append(s if s.startswith("&") else "&" + self.paren(s) + "[0]"); continue   # spelled decay (private:xcc-bugs/22)
                if at.is_int() and (at.bits or 32) < 32: out.append(self.ex(a, I32))
                elif at.kind == "float":
                    # --hoist-double-varargs: on builds before 2026-09-07 a
                    # double in a pack arrived whole only from a variable
                    # (private:xcc-bugs/29, fixed by xcc 173/179; the literal half was
                    # the missing d suffix, which is always emitted now)
                    s = self.ex(a, F64)
                    if not self.hoist_double_varargs or isinstance(a, c_ast.ID): out.append(s)
                    else:
                        n = self.ntmp("dv"); self.pre.append("double %s = %s;" % (n, s)); out.append(n)
                else: out.append(self.ex(a))
        return "%s(%s)" % (callee, ", ".join(out)), ft.ret
    def index(self, e):
        # a[i][j] on a flattened array: a[i*n2 + j]
        base, subs = e, []
        while isinstance(base, c_ast.ArrayRef): subs.append(base.subscript); base = base.name
        subs.reverse()
        bt = self.etype(base)
        bs, _ = self.ex_raw(base)
        if bt.kind == "array":
            elem, dims = self.flat(bt)
            if len(subs) <= len(dims):
                # full or partial index into a flat array
                idx = None
                for k, sub in enumerate(subs):
                    stride = 1
                    for d in dims[k+1:]: stride *= (d or 1)
                    s = self.ex(sub, I64)
                    term = s if stride == 1 else "%s * %d" % (self.paren(s), stride)
                    idx = term if idx is None else "%s + %s" % (idx, term)
                if len(subs) == len(dims): return "%s[%s]" % (bs if not bs.startswith("(") else bs, idx), elem
                # a row: pointer to the first element of the sub-array
                rem = dims[len(subs):]
                return "&%s[%s]" % (bs, idx), T("array", to=elem, n=rem[0]) if len(rem) == 1 else T("array", to=T("array", to=elem, n=rem[1]), n=rem[0])
        # pointer indexing, possibly of a pointer to a flattened row
        t = bt
        s = bs
        for sub in subs:
            if t.kind == "array":
                elem, dims = self.flat(t)
                stride = 1
                for d in dims[1:]: stride *= (d or 1)
                i = self.ex(sub, I64)
                s = "%s[%s]" % (s, i if stride == 1 else "%s * %d" % (self.paren(i), stride))
                if len(dims) > 1:
                    s = "&" + s; t = T("array", to=elem, n=dims[1]) if len(dims) == 2 else T("array", to=T("array", to=elem, n=dims[2]), n=dims[1])
                    s = s  # a pointer into the flat block
                    t = PTR(elem) if len(dims) == 2 else t
                else: t = elem
            elif t.kind == "ptr":
                i = self.ex(sub, I64)
                # a subscript chain or member chain binds tighter than anything
                # that could precede it; brackets round `name[..]` would read
                # as a cast to an array type in xc
                plain = re.match(r"^[A-Za-z_][A-Za-z0-9_.]*(\[[^\]]*\]|->[A-Za-z_][A-Za-z0-9_]*|\.[A-Za-z_][A-Za-z0-9_]*)*$", s)
                s = "%s[%s]" % (s if plain else self.paren(s), i)
                t = t.to
            else:
                # i[a]
                self.warn(e, "index of non-array"); t = I32
        return s, t
    def member(self, e):
        s, t = self.ex_raw(e.name)
        if e.type == "->":
            if t.kind == "array": t = t.to; s = self.paren(s) + "[0]"
            elif t.kind == "ptr": t = t.to
        if t.kind == "union":
            f = self.field(t, e.field.name)
            ft = f[1] if f else I32
            base = "&" + self.paren(s) + ".raw[0]" if e.type == "." else "&" + self.paren(s) + "->raw[0]"
            if e.type == "->": base = "&%s.raw[0]" % self.paren(s)
            if ft.kind == "array":
                return "((%s*)%s)" % (ft.to.xc(), base), T("array", to=ft.to, n=ft.n)
            return "(*(%s*)%s)" % (ft.xc(), base), ft
        f = self.field(t, e.field.name) if t.kind == "struct" else None
        ft = f[1] if f else I32
        # xc's `.` auto-dereferences a pointer, so `->` is never needed: plain
        # `.` is right on a value and on a pointer alike. Emitting one spelling
        # also removes the trap that produced `*pPivot.Real` from C's
        # `(*pPivot).Real` -- that parses as `*(pPivot.Real)`, a dereference of
        # the FIELD, which the front end accepts today and which segfaults
        # natively and writes an invalid wasm module. So the object is
        # parenthesised whenever it is not a plain name/subscript/member chain,
        # whichever spelling the C used.
        sep = "."
        obj = s if re.match(r"^[A-Za-z_][A-Za-z0-9_\.\[\]]*$", s) else self.paren(s)
        if f and f[2] is not None:
            info = self.bf_info(t, e.field.name)
            if info:
                r = self.bf_read(obj, sep, info)
                self.bf_lv[r] = (obj, sep, info)
                return r, ft
        return "%s%s%s" % (obj, sep, self.nm(e.field.name)), ft
    # ── statements ─────────────────────────────────────────────────────────
    def emit(self, line, ind=0):
        self.out.append("    " * ind + line)
    def flush_pre(self, ind):
        for p in self.pre: self.emit(p, ind)
        self.pre = []
    def stmt(self, s, ind):
        if s is None: return
        if isinstance(s, c_ast.Compound):
            self.emit("{", ind); self.block(s.block_items or [], ind + 1); self.emit("}", ind); return
        if isinstance(s, c_ast.Decl):
            self.local_decl(s, ind); return
        if type(s).__name__ == "Init":
            d = s.decl; t = self.lookup_local(d.name) or self.type_of_decl(d); name = self.nm(d.name)
            if t.is_scalar():
                x = d.init.exprs[0] if isinstance(d.init, c_ast.InitList) else d.init
                v = self.ex(x, t); self.flush_pre(ind); self.emit("%s = %s;" % (name, v), ind); return
            for st in self.init_stmts_for(name, t, d.init): self.emit(st, ind)
            return
        if isinstance(s, c_ast.DeclList):
            for d in s.decls: self.local_decl(d, ind)
            return
        if isinstance(s, c_ast.Return):
            if s.expr is None: self.emit("return;", ind); return
            rt = self.cur_fn.ret
            x = self.ex(s.expr, rt if rt.is_scalar() else None); self.flush_pre(ind)
            self.emit("return %s;" % x, ind); return
        if isinstance(s, c_ast.If):
            c = self.ex(s.cond, ctx="cond"); self.flush_pre(ind)
            self.emit("if (%s) {" % c, ind)
            self.body(s.iftrue, ind + 1)
            if s.iffalse is not None:
                if isinstance(s.iffalse, c_ast.If) and not self.pre_needed(s.iffalse.cond):
                    self.emit("} else", ind); self.stmt_if_chain(s.iffalse, ind); return
                self.emit("} else {", ind); self.body(s.iffalse, ind + 1)
            self.emit("}", ind); return
        if isinstance(s, c_ast.While):
            self.loop_while(s.cond, s.stmt, ind); return
        if isinstance(s, c_ast.DoWhile):
            self.enter_loop()
            try: self.do_while(s, ind)
            finally: self.leave_loop()
            return
        if False:
            f = self.ntmp("first")
            self.emit("bool %s = true;" % f, ind)
            c = self.ex(s.cond, ctx="cond")
            if self.pre:
                # the condition needs statements: evaluate it into a flag at the end of the body
                pre = self.pre; self.pre = []
                self.emit("while (true) {", ind)
                self.body(s.stmt, ind + 1)
                for p in pre: self.emit(p, ind + 1)
                self.emit("if (!(%s)) break;" % c, ind + 1)
                self.emit("}", ind); return
            self.emit("while (%s || (%s)) {" % (f, c), ind)
            self.emit("%s = false;" % f, ind + 1)
            self.body(s.stmt, ind + 1)
            self.emit("}", ind); return
        if isinstance(s, c_ast.For):
            self.loop_for(s, ind); return
        if isinstance(s, c_ast.Switch):
            self.switch(s, ind); return
        if isinstance(s, c_ast.Break):
            if self.switch_stack and self.inner_loop_depth == 0:
                run, cont = self.switch_stack[-1]; self.emit("{ %s = false; break; }" % run, ind); return
            self.emit("break;", ind); return
        if isinstance(s, c_ast.Continue):
            if self.switch_stack and self.inner_loop_depth == 0:
                run, cont = self.switch_stack[-1]; self.emit("{ %s = false; %s = true; break; }" % (run, cont), ind); return
            self.emit("continue;", ind); return
        if isinstance(s, c_ast.EmptyStatement): return
        if isinstance(s, c_ast.Label):
            self.warn(s, "label '%s' (goto is not supported)" % s.name)
            self.emit("// label %s:" % s.name, ind); self.stmt(s.stmt, ind); return
        if isinstance(s, c_ast.Goto):
            self.warn(s, "goto %s" % s.name)
            # not lowerable: say so at build time, trap at run time, and let the rest build
            self.emit("#warning c2xc: goto %s needs a hand-written lowering (this path aborts)" % s.name, 0)
            self.natives_used.add("abort"); self.emit("abort();", ind); return
        if isinstance(s, c_ast.Case) or isinstance(s, c_ast.Default):
            self.warn(s, "case outside switch"); return
        # expression statement
        x, t = self.ex_raw(s, "stmt"); self.flush_pre(ind)
        if isinstance(s, c_ast.FuncCall) and t.kind != "void" and False: pass
        self.emit(x + ";", ind)
    def do_while(self, s, ind):
        f = self.ntmp("first")
        self.emit("bool %s = true;" % f, ind)
        c = self.ex(s.cond, ctx="cond")
        if self.pre:
            # the condition needs statements. They go at the TOP of the
            # loop behind the first-pass flag, not after the body: a
            # `continue` in the body must still reach them (otherwise
            # `do { .. continue; } while (++j < n)` spins for ever)
            pre = self.pre; self.pre = []
            self.emit("while (true) {", ind)
            self.emit("if (!%s) {" % f, ind + 1)
            for p in pre: self.emit(p, ind + 2)
            self.emit("if (!(%s)) break;" % c, ind + 2)
            self.emit("}", ind + 1)
            self.emit("%s = false;" % f, ind + 1)
            self.body(s.stmt, ind + 1)
            self.emit("}", ind); return
        self.emit("while (%s || (%s)) {" % (f, c), ind)
        self.emit("%s = false;" % f, ind + 1)
        self.body(s.stmt, ind + 1)
        self.emit("}", ind)
    def stmt_if_chain(self, s, ind):
        c = self.ex(s.cond, ctx="cond")
        self.emit("if (%s) {" % c, ind)
        self.body(s.iftrue, ind + 1)
        if s.iffalse is not None:
            if isinstance(s.iffalse, c_ast.If) and not self.pre_needed(s.iffalse.cond):
                self.emit("} else", ind); self.stmt_if_chain(s.iffalse, ind); return
            self.emit("} else {", ind); self.body(s.iffalse, ind + 1)
        self.emit("}", ind)
    def pre_needed(self, e):
        """Would emitting e hoist statements? (then an else-if chain cannot be used)"""
        save_out, save_pre, save_tmp = self.out, self.pre, self.tmp
        self.out = []; self.pre = []
        try: self.ex(e, ctx="cond")
        except Exception: pass
        needed = bool(self.pre)
        self.out, self.pre, self.tmp = save_out, save_pre, save_tmp
        return needed
    def body(self, s, ind):
        if isinstance(s, c_ast.Compound): self.block(s.block_items or [], ind)
        else: self.block([s], ind)
    def gotos_in(self, node):
        found = []
        class V(c_ast.NodeVisitor):
            def visit_Goto(self, n): found.append(n.name)
        V().visit(node); return found
    def block(self, items, ind):
        # a block whose own items carry a label, and whose gotos all aim at
        # its own labels, is a region the state machine can take over
        top = [x.name for x in items if isinstance(x, c_ast.Label)]
        if top and not self.goto_state:
            targets = set()
            for it in items: targets.update(self.gotos_in(it))
            if targets <= set(top):
                self.state_machine(c_ast.Compound(list(items)), top, ind); return
            self.warn(items[0], "gotos leave the block holding their labels: %s" % sorted(targets - set(top)))
        self.locals.append({})
        for i, s in enumerate(items):
            if getattr(self, "goto_state", None): self.stmt_g(s, ind)
            else: self.stmt(s, ind)
            if self.terminates(s) and i + 1 < len(items):
                # xc's IR verifier rejects unreachable code: drop it, keeping labels' statements out too
                rest = items[i+1:]
                if any(not isinstance(r, (c_ast.EmptyStatement,)) for r in rest):
                    self.warn(rest[0], "unreachable code dropped")
                break
        self.locals.pop()
    def terminates(self, s):
        if isinstance(s, (c_ast.Return, c_ast.Break, c_ast.Continue, c_ast.Goto)): return True
        if isinstance(s, c_ast.Compound):
            items = s.block_items or []
            return any(self.terminates(x) for x in items)
        if isinstance(s, c_ast.If):
            return s.iffalse is not None and self.terminates(s.iftrue) and self.terminates(s.iffalse)
        if isinstance(s, c_ast.While):
            v = self.const_eval(s.cond)
            return v not in (None, 0) and not self.has_break(s.stmt)
        if isinstance(s, c_ast.For):
            return s.cond is None and not self.has_break(s.stmt)
        if isinstance(s, c_ast.Switch):
            # every case terminates and there is a default, with no break at the switch level
            items = s.stmt.block_items if isinstance(s.stmt, c_ast.Compound) else []
            has_default = any(isinstance(x, c_ast.Default) for x in items)
            if not has_default: return False
            if self.has_break(s.stmt, switch=True): return False
            last = items[-1] if items else None
            return last is not None and self.terminates(self.case_body_last(last))
        if isinstance(s, c_ast.FuncCall) and isinstance(s.name, c_ast.ID) and s.name.name in ("exit", "abort", "_exit", "longjmp", "err", "errx"): return True
        return False
    def case_body_last(self, s):
        while isinstance(s, (c_ast.Case, c_ast.Default)):
            if not s.stmts: return c_ast.EmptyStatement()
            s = s.stmts[-1]
        return s
    def has_break(self, s, switch=False):
        """Does s contain a break that binds to the enclosing loop/switch?"""
        if s is None: return False
        if isinstance(s, c_ast.Break): return True
        if isinstance(s, (c_ast.While, c_ast.DoWhile, c_ast.For)): return False
        if isinstance(s, c_ast.Switch): return False if not switch else any(self.has_break(x) for x in (s.stmt.block_items if isinstance(s.stmt, c_ast.Compound) else []))
        for _, ch in s.children():
            if isinstance(ch, c_ast.Node) and self.has_break(ch, switch=False if isinstance(ch, c_ast.Switch) else switch): return True
        return False
    def enter_loop(self):
        self.loop_depth += 1
        if self.switch_stack: self.inner_loop_depth += 1
        self.saved_switch.append(self.switch_stack); self.switch_stack = []
    def leave_loop(self):
        self.loop_depth -= 1
        self.switch_stack = self.saved_switch.pop()
        if self.switch_stack: self.inner_loop_depth -= 1
    def loop_while(self, cond, body, ind):
        self.enter_loop()
        try: self.loop_while_(cond, body, ind)
        finally: self.leave_loop()
    def loop_while_(self, cond, body, ind):
        c = self.ex(cond, ctx="cond")
        if self.pre:
            pre = self.pre; self.pre = []
            self.emit("while (true) {", ind)
            for p in pre: self.emit(p, ind + 1)
            self.emit("if (!(%s)) break;" % c, ind + 1)
            self.body(body, ind + 1); self.emit("}", ind); return
        self.emit("while (%s) {" % c, ind)
        self.body(body, ind + 1)
        self.emit("}", ind)
    def loop_for(self, s, ind):
        self.enter_loop()
        try: self.loop_for_(s, ind)
        finally: self.leave_loop()
    def loop_for_(self, s, ind):
        self.locals.append({})
        opened = False
        # init: declarations or an expression list
        if s.init is not None:
            self.emit("{", ind); ind += 1; opened = True
            if isinstance(s.init, c_ast.DeclList):
                for d in s.init.decls: self.local_decl(d, ind)
            elif isinstance(s.init, c_ast.Decl): self.local_decl(s.init, ind)
            else:
                for x in (s.init.exprs if isinstance(s.init, c_ast.ExprList) else [s.init]):
                    v = self.ex(x, ctx="stmt"); self.flush_pre(ind); self.emit(v + ";", ind)
        cond = self.ex(s.cond, ctx="cond") if s.cond is not None else "true"
        cond_pre = self.pre; self.pre = []
        steps = []
        if s.next is not None:
            for x in (s.next.exprs if isinstance(s.next, c_ast.ExprList) else [s.next]):
                steps.append(self.ex(x, ctx="stmt") + ";")
        step_pre = self.pre; self.pre = []
        simple = len(steps) <= 1 and not cond_pre and not step_pre
        if simple:
            self.emit("for (; %s; %s) {" % (cond, steps[0][:-1] if steps else ""), ind)
            self.body(s.stmt, ind + 1)
            self.emit("}", ind)
        else:
            f = self.ntmp("first")
            self.emit("bool %s = true;" % f, ind)
            self.emit("while (true) {", ind)
            self.emit("if (!%s) {" % f, ind + 1)
            for p in step_pre: self.emit(p, ind + 2)
            for st in steps: self.emit(st, ind + 2)
            self.emit("}", ind + 1)
            self.emit("%s = false;" % f, ind + 1)
            for p in cond_pre: self.emit(p, ind + 1)
            if cond != "true": self.emit("if (!(%s)) break;" % cond, ind + 1)
            self.body(s.stmt, ind + 1)
            self.emit("}", ind)
        if opened: ind -= 1; self.emit("}", ind)
        self.locals.pop()
    def switch(self, s, ind):
        """A C switch as structured xc. xcc's own switch misreads its operand
        inside a loop and mishandles loops inside cases (private:XCC-BUGS.md 1-3), so
        no xc switch is emitted: the operand is matched to a case number, and
        the cases run in order under a `run` flag that a match turns on, so
        falling through is the next block seeing the flag still up. Each
        case body sits in a one-pass loop: C's `break` leaves it with the flag
        down, a natural end leaves it with the flag up. `continue` inside the
        switch means the enclosing loop's, so it raises its own flag, which
        the code after the switch turns into a real continue."""
        x, t = self.ex_raw(s.cond); self.flush_pre(ind)
        items = s.stmt.block_items if isinstance(s.stmt, c_ast.Compound) else [s.stmt]
        # gather cases in order, flattening nested case labels
        cases = []           # (list of label exprs or None for default, stmts)
        def add(it):
            if isinstance(it, (c_ast.Case, c_ast.Default)):
                labels = [] if isinstance(it, c_ast.Default) else [it.expr]
                stmts = list(it.stmts or [])
                # a label directly followed by another label shares its body
                while stmts and isinstance(stmts[0], (c_ast.Case, c_ast.Default)) and len(stmts) == 1:
                    nxt = stmts[0]
                    if isinstance(nxt, c_ast.Default): labels.append(None)
                    else: labels.append(nxt.expr)
                    stmts = list(nxt.stmts or [])
                cases.append((labels if labels else [None], stmts))
            else:
                if cases: cases[-1][1].append(it)
                else: self.warn(it, "statement before the first case dropped")
        for it in items: add(it)
        m = self.ntmp("sw"); run = self.ntmp("run"); cont = self.ntmp("cont")
        xt = self.promote(t) if t.is_int() else t
        xs = self.cast(x, t, xt) if t.is_int() else x
        self.emit("i32 %s = -1; bool %s = false; bool %s = false;" % (m, run, cont), ind)
        self.emit("{", ind)
        self.emit("%s = %s;" % (self.decl_str(xt, m + "v"), xs), ind + 1)
        first = True; default_k = None
        for k, (labels, stmts) in enumerate(cases):
            for lab in labels:
                if lab is None: default_k = k; continue
                self.emit("%sif (%sv == %s) %s = %d;" % ("" if first else "else ", m, self.ex(lab, xt), m, k), ind + 1)
                first = False
        if default_k is not None:
            self.emit("%s%s = %d;" % ("" if first else "else ", m, default_k) if first else "else %s = %d;" % (m, default_k), ind + 1)
        self.emit("}", ind)
        in_loop = self.loop_depth > 0
        self.loop_depth += 0
        self.switch_stack.append((run, cont))
        for k, (labels, stmts) in enumerate(cases):
            self.emit("if (%s == %d) %s = true;" % (m, k, run), ind)
            self.emit("if (%s) {" % run, ind)
            self.emit("while (true) {", ind + 1)
            self.locals.append({})
            self.switch_body = True
            self.block(stmts, ind + 2)
            self.locals.pop()
            if not (stmts and self.terminates(stmts[-1])): self.emit("break;", ind + 2)
            self.emit("}", ind + 1)
            self.emit("}", ind)
        self.switch_stack.pop()
        if self.mentions_continue(items):
            self.emit("if (%s) %s;" % (cont, "continue" if in_loop else "break"), ind)
    def mentions_continue(self, items):
        found = [False]
        class V(c_ast.NodeVisitor):
            def visit_Continue(self, n): found[0] = True
            def visit_While(self, n): pass
            def visit_DoWhile(self, n): pass
            def visit_For(self, n): pass
        for it in items: V().visit(it)
        return found[0]
    def local_decl(self, d, ind):
        if isinstance(d.type, c_ast.FuncDecl):
            return                                  # a prototype inside a function
        if d.name is None:
            # a struct/enum definition inside a function
            if isinstance(d.type, (c_ast.Struct, c_ast.Union, c_ast.Enum)): self.base_type(d.type)
            return
        if "typedef" in (d.storage or []):
            self.typedefs[d.name] = self.type_of_decl(d.type, d.name); return
        t = self.type_of_decl(d)
        self.locals[-1][d.name] = t
        name = self.nm(d.name)
        static = "static " in ("".join(x + " " for x in (d.storage or [])))
        if "extern" in (d.storage or []): return
        if t.kind == "array":
            base, dims = self.flat(t)
            if d.init is not None and any(x is None for x in dims):
                # size from the initialiser
                n = self.init_len(d.init, t)
                dims[0] = n
                t = self.rebuild_array(base, dims); self.locals[-1][d.name] = t
        decl = self.decl_str(t, name)
        if static: decl = "static " + decl
        if d.init is None:
            self.emit(decl + ";", ind); return
        if t.is_scalar():
            if isinstance(d.init, c_ast.InitList):
                v = self.ex(d.init.exprs[0], t)
            else: v = self.ex(d.init, t)
            self.flush_pre(ind)
            self.emit("%s = %s;" % (decl, v), ind); return
        # aggregates: constant initialisers inline when xc takes them, else statements
        if self.init_is_plain(d.init, t) and not static:
            self.emit("%s = %s;" % (decl, self.init_text(d.init, t)), ind); return
        if static:
            self.emit(decl + ";", ind)
            self.warn(d, "static local aggregate initialised at first use is not modelled; initialised on every entry")
        else: self.emit(decl + ";", ind)
        for st in self.init_stmts_for(name, t, d.init): self.emit(st, ind)
    def rebuild_array(self, base, dims):
        t = base
        for d in reversed(dims): t = T("array", to=t, n=d)
        return t
    def init_len(self, init, t):
        if isinstance(init, c_ast.InitList): return len(init.exprs)
        if isinstance(init, c_ast.Constant) and init.type == "string":
            return len(self.unescape("".join(re.findall(r'"((?:[^"\\]|\\.)*)"', init.value)))) + 1
        return 1
    def init_is_plain(self, init, t):
        """Numbers only (no strings, no addresses): xc accepts the brace form."""
        base = self.flat(t)[0] if t.kind == "array" else t
        if has_bitfields(base) and isinstance(init, c_ast.InitList):
            # bit-field values are folded into their unit: they must be constants
            def leaves(x):
                if isinstance(x, c_ast.NamedInitializer): x = x.expr
                if isinstance(x, c_ast.InitList):
                    for y in x.exprs: yield from leaves(y)
                else: yield x
            if not all(self.const_eval(x) is not None for x in leaves(init)): return False
        if isinstance(init, c_ast.InitList):
            return all(self.init_is_plain(x if not isinstance(x, c_ast.NamedInitializer) else x.expr, t) for x in init.exprs)
        if isinstance(init, c_ast.Constant): return init.type != "string"
        if isinstance(init, c_ast.ID): return init.name in self.enums
        if isinstance(init, c_ast.UnaryOp) and init.op in ("-", "+", "~"): return self.init_is_plain(init.expr, t)
        if isinstance(init, c_ast.Cast): return self.init_is_plain(init.expr, t)
        if isinstance(init, c_ast.BinaryOp): return self.const_eval(init) is not None
        return False
    def init_text(self, init, t):
        """The brace text for a plain initialiser, flattened for multi-dimensional arrays."""
        if t.kind == "array":
            base, dims = self.flat(t)
            vals = []
            self.flatten_init(init, dims, base, vals)
            return "{" + ", ".join(vals) + "}"
        if t.kind == "struct":
            vals = []
            exprs = init.exprs if isinstance(init, c_ast.InitList) else [init]
            fi = 0; given = {}
            for x in exprs:
                if isinstance(x, c_ast.NamedInitializer):
                    fname = x.name[0].name; fi = [f[0] for f in t.fields].index(fname); x = x.expr
                if fi >= len(t.fields): break
                fname, ft, bw = t.fields[fi]
                if has_bitfields(t): given[fname] = x
                else: vals.append(self.init_text(x, ft) if ft.kind in ("array", "struct") else self.const_text(x, ft))
                fi += 1
            if has_bitfields(t):
                for sl in struct_layout(t)[0]:
                    if sl[0] == "field":
                        x = given.get(sl[1]); ft = sl[2]
                        vals.append("0" if x is None else self.init_text(x, ft) if ft.kind in ("array", "struct") else self.const_text(x, ft))
                    else:
                        u = 0
                        for n, sh, w, sg, ft in sl[4]:
                            x = given.get(n); v = 0 if x is None else int(self.const_eval(x) or 0)
                            u |= (v & ((1 << w) - 1)) << sh
                        vals.append(str(u))
            return "{" + ", ".join(vals) + "}"
        return self.const_text(init, t)
    def const_text(self, x, t):
        if isinstance(x, c_ast.InitList): x = x.exprs[0]
        v = self.const_eval(x)
        if v is None: return self.ex(x, t)
        if t.kind == "float": return xc_float(float(v), double=(t.bits == 64))
        return str(int(v))
    def flatten_init(self, init, dims, base, vals):
        if len(dims) == 1 or not isinstance(init, c_ast.InitList):
            exprs = init.exprs if isinstance(init, c_ast.InitList) else [init]
            for x in exprs:
                if isinstance(x, c_ast.NamedInitializer): x = x.expr
                vals.append(self.init_text(x, base) if base.kind in ("struct",) else self.const_text(x, base))
            return
        for x in init.exprs:
            if isinstance(x, c_ast.NamedInitializer): x = x.expr
            n0 = len(vals)
            self.flatten_init(x, dims[1:], base, vals)
            # pad the row
            row = 1
            for d in dims[1:]: row *= (d or 1)
            while len(vals) - n0 < row: vals.append("0")
    def init_stmts_for(self, name, t, init):
        """Assignments that realise an initialiser xc cannot take inline."""
        out = []
        if t.kind == "array":
            base, dims = self.flat(t)
            if isinstance(init, c_ast.Constant) and init.type == "string":
                b = self.unescape("".join(re.findall(r'"((?:[^"\\]|\\.)*)"', init.value)))
                for i, c in enumerate(b): out.append("%s[%d] = %d;" % (name, i, c))
                out.append("%s[%d] = 0;" % (name, len(b))); return out
            if len(dims) == 2 and base.is_int() and base.bits == 8 and isinstance(init, c_ast.InitList) \
               and all(isinstance(x, c_ast.Constant) and x.type == "string" for x in init.exprs):
                row = dims[1] or 1
                for r, x in enumerate(init.exprs):
                    b = self.unescape("".join(re.findall(r'"((?:[^"\\]|\\.)*)"', x.value)))
                    for i, c in enumerate(b[:row]): out.append("%s[%d] = %d;" % (name, r * row + i, c))
                    if len(b) < row: out.append("%s[%d] = 0;" % (name, r * row + len(b)))
                return out
            flat = []
            self.flatten_exprs(init, dims, flat)
            for i, x in enumerate(flat):
                if x is None: continue
                if base.kind in ("struct", "union"):
                    out.extend(self.init_stmts_for("%s[%d]" % (name, i), base, x))
                else:
                    v = self.ex(x, base if base.is_scalar() else None); out.extend(self.pre); self.pre = []
                    out.append("%s[%d] = %s;" % (name, i, v))
            return out
        if t.kind == "struct":
            if not isinstance(init, c_ast.InitList):
                # a whole struct from an expression (a call, another struct)
                v = self.ex(init); out.extend(self.pre); self.pre = []
                out.append("%s = %s;" % (name, v)); return out
            exprs = init.exprs
            fi = 0
            for x in exprs:
                if isinstance(x, c_ast.NamedInitializer):
                    fname = x.name[0].name; fi = [f[0] for f in t.fields].index(fname); x = x.expr
                if fi >= len(t.fields): break
                fname, ft, bw = t.fields[fi]
                if bw is not None and self.bf_info(t, fname):
                    v = self.ex(x, ft); out.extend(self.pre); self.pre = []
                    out.append(self.bf_write(name, ".", self.bf_info(t, fname), v) + ";")
                elif ft.kind in ("array", "struct", "union"): out.extend(self.init_stmts_for("%s.%s" % (name, self.nm(fname)), ft, x))
                else:
                    v = self.ex(x, ft if ft.is_scalar() else None); out.extend(self.pre); self.pre = []
                    out.append("%s.%s = %s;" % (name, self.nm(fname), v))
                fi += 1
            return out
        if t.kind == "union":
            x = init.exprs[0] if isinstance(init, c_ast.InitList) else init
            fname, ft, _ = t.fields[0]
            v = self.ex(x, ft if ft.is_scalar() else None); out.extend(self.pre); self.pre = []
            out.append("*(%s*)&%s.raw[0] = %s;" % (ft.xc(), name, v)); return out
        v = self.ex(init if not isinstance(init, c_ast.InitList) else init.exprs[0], t if t.is_scalar() else None)
        out.extend(self.pre); self.pre = []
        out.append("%s = %s;" % (name, v)); return out
    def flatten_exprs(self, init, dims, flat):
        if len(dims) == 1 or not isinstance(init, c_ast.InitList):
            exprs = init.exprs if isinstance(init, c_ast.InitList) else [init]
            for x in exprs:
                if isinstance(x, c_ast.NamedInitializer): x = x.expr
                flat.append(x)
            return
        for x in init.exprs:
            if isinstance(x, c_ast.NamedInitializer): x = x.expr
            n0 = len(flat)
            self.flatten_exprs(x, dims[1:], flat)
            row = 1
            for d in dims[1:]: row *= (d or 1)
            while len(flat) - n0 < row: flat.append(None)
    # ── top level ──────────────────────────────────────────────────────────
    def collect(self, ast):
        """First pass: every typedef, struct, enum, function signature and global, so
        later references resolve regardless of order and statics can be renamed."""
        for ext in ast.ext:
            if isinstance(ext, c_ast.Typedef):
                # the fake headers make every libc type an int; the table knows better
                c = getattr(ext, "coord", None)
                if c is not None and ("fake_libc_include" in str(c.file) or "c2xc_pre.h" in str(c.file)):
                    self.fake_typedefs.add(ext.name)
                    if ext.name in LIBC.TYPEDEFS: self.typedefs[ext.name] = LIBC.TYPEDEFS[ext.name]; continue
                self.typedefs[ext.name] = self.type_of_decl(ext.type, ext.name)
                self.type_names.add(ext.name)
                if ext.name in XC_RESERVED or ext.name in ("String", "Object"): self.renames[ext.name] = ext.name + "_"
            elif isinstance(ext, c_ast.Decl):
                if isinstance(ext.type, c_ast.FuncDecl):
                    ft = self.type_of_decl(ext)
                    if is_system(getattr(ext, "coord", None)): ft = cabi_fn(ft); self.system_funcs.add(ext.name)    # a native: the C ABI
                    self.funcs[ext.name] = ft
                elif ext.name is None:
                    self.base_type(ext.type)
                else:
                    t = self.type_of_decl(ext)
                    # an array's size from its initialiser, now, so ARRAY_SIZE folds
                    if t.kind == "array" and ext.init is not None:
                        base, dims = self.flat(t)
                        if dims and dims[0] is None: dims[0] = self.init_len(ext.init, t); t = self.rebuild_array(base, dims)
                    old = self.globals.get(ext.name)
                    if "extern" not in (ext.storage or []): self.defined_globals.add(ext.name)
                    # an extern or unsized declaration never hides a sized definition
                    if old is not None and old.kind == "array" and old.n is not None and (t.kind != "array" or t.n is None): continue
                    self.globals[ext.name] = t
            elif isinstance(ext, c_ast.FuncDef):
                d = ext.decl
                self.funcs[d.name] = self.type_of_decl(d)
                self.defined.add(d.name)
        # a typedef that names a struct tag: the struct's xc name is the typedef's
        for name, t in self.typedefs.items():
            if t.kind in ("struct", "union") and t.name and t.name.startswith("_anon"): t.name = self.tn(name); self.type_names.add(t.name)
    # C's file-scope statics are private to their file; one unit holds many
    # files, so a name that is static in more than one, or static here and
    # global elsewhere, is renamed name_<file> throughout that file's tree
    # before anything else looks at it (the AST is rewritten in place, so the
    # type pass, the emitters and the prototypes all agree).
    def rename_statics(self, asts, files):
        stems = [re.sub(r"[^A-Za-z0-9_]", "_", os.path.splitext(os.path.basename(f))[0]) for f in files]
        static_in = {}; global_in = {}
        for ast, stem in zip(asts, stems):
            for ext in ast.ext:
                if isinstance(ext, c_ast.FuncDef): name, st = ext.decl.name, ext.decl.storage
                elif isinstance(ext, c_ast.Decl) and ext.name: name, st = ext.name, ext.storage
                else: continue
                if "static" in (st or []): static_in.setdefault(name, set()).add(stem)
                elif isinstance(ext, c_ast.FuncDef) or (isinstance(ext, c_ast.Decl) and "extern" not in (st or []) and not isinstance(ext.type, c_ast.FuncDecl)): global_in.setdefault(name, set()).add(stem)
        for ast, stem in zip(asts, stems):
            todo = {n: n + "_" + stem for n, fs in static_in.items() if stem in fs and (len(fs) > 1 or n in global_in)}
            if todo:
                for node in self.walk(ast):
                    if isinstance(node, c_ast.ID) and node.name in todo: node.name = todo[node.name]
                    elif isinstance(node, c_ast.Decl) and node.name in todo: node.name = todo[node.name]
                    elif isinstance(node, c_ast.TypeDecl) and node.declname in todo: node.declname = todo[node.declname]
            # a function's static local that shadows a global of the unit:
            # xcc 0.5 binds the name to neither (private:xcc-bugs/20), so it is renamed
            # name_<function> within that function
            taken = set(static_in) | set(global_in)
            for ext in ast.ext:
                if not isinstance(ext, c_ast.FuncDef): continue
                loc = {}
                for node in self.walk(ext.body):
                    if isinstance(node, c_ast.Decl) and node.name and "static" in (node.storage or []) and node.name in taken: loc[node.name] = node.name + "_" + ext.decl.name
                if not loc: continue
                fields = set(id(n.field) for n in self.walk(ext.body) if isinstance(n, c_ast.StructRef))
                for node in self.walk(ext.body):
                    if isinstance(node, c_ast.ID) and node.name in loc and id(node) not in fields: node.name = loc[node.name]
                    elif isinstance(node, c_ast.Decl) and node.name in loc: node.name = loc[node.name]
                    elif isinstance(node, c_ast.TypeDecl) and node.declname in loc: node.declname = loc[node.declname]
    def hoist_static_locals(self, asts):
        """Every static local becomes a file-scope static named fn__name: xcc
        0.5 keeps a static local scalar but not an array (private:xcc-bugs/31), and
        a first-use initialiser then falls to the unit's initialiser."""
        for ast in asts:
            new_ext = []
            for ext in ast.ext:
                if isinstance(ext, c_ast.FuncDef) and ext.body is not None:
                    fn = ext.decl.name; ren = {}; hoisted = []
                    has_static = any(isinstance(n, c_ast.Decl) and n.name and "static" in (n.storage or []) and not isinstance(n.type, c_ast.FuncDecl) for n in self.walk(ext.body))
                    for node in self.walk(ext.body):
                        if has_static and isinstance(node, c_ast.Compound) and node.block_items:
                            keep = []
                            for it in node.block_items:
                                if isinstance(it, c_ast.Decl) and it.name and "static" in (it.storage or []) and not isinstance(it.type, c_ast.FuncDecl):
                                    ren[it.name] = "%s__%s" % (fn, it.name); hoisted.append(it)
                                elif isinstance(it, c_ast.Typedef) or (isinstance(it, c_ast.Decl) and it.name is None and isinstance(it.type, (c_ast.Struct, c_ast.Union, c_ast.Enum))):
                                    hoisted.append(it)        # a type the static may need, defined in the function
                                else: keep.append(it)
                            node.block_items = keep
                    if ren:
                        fields = set(id(n.field) for n in self.walk(ext.body) if isinstance(n, c_ast.StructRef))
                        for node in self.walk(ext.body):
                            if isinstance(node, c_ast.ID) and node.name in ren and id(node) not in fields: node.name = ren[node.name]
                        for it in hoisted:
                            for node in self.walk(it):
                                if isinstance(node, c_ast.ID) and node.name in ren: node.name = ren[node.name]
                                elif isinstance(node, c_ast.TypeDecl) and node.declname in ren: node.declname = ren[node.declname]
                            if isinstance(it, c_ast.Decl) and it.name in ren: it.name = ren[it.name]
                            new_ext.append(it)
                new_ext.append(ext)
            ast.ext = new_ext
    def convert(self, asts, files):
        self.rename_statics(asts, files)
        self.hoist_static_locals(asts)
        for ast in asts: self.collect(ast)
        body = []
        for ast, f in zip(asts, files):
            self.file = os.path.splitext(os.path.basename(f))[0]
            self.out = body
            for ext in ast.ext: self.toplevel(ext)
        head = []
        head.append("// GENERATED by c2xc from %s. Edit the C, not this." % ", ".join(os.path.basename(f) for f in files))
        head.append('#import "Foundation.xc"')
        if self.needs_rt: head.append('#import "c2xc_rt.xc"')
        # enums as constants
        for k, v in self.enums.items(): head.append("#define %s %d" % (self.nm(k), v))
        # structs in dependency order (a struct used by value must come first)
        head.extend(self.struct_decls())
        # natives, and every prototyped function the unit does not define
        rt_declares = {"fputs"} if self.needs_rt else set()
        # Foundation declares a few C symbols itself (write, random) and a C
        # symbol has exactly one signature: the table carries Foundation's and
        # the declaration is left to it
        rt_declares |= FOUNDATION_DECLARES
        for n in sorted(self.natives_used):
            if n in rt_declares: continue                         # declared by c2xc_rt.xc or Foundation; xcc 0.5 refuses a second declaration
            head.append(LIBC.decl(n, self))
        for n, ft in sorted(self.funcs.items()):
            if n in self.defined or n in self.natives_used or n in LIBC.FUNCS or ft.kind != "fn" or not self.used_fns.get(n): continue
            ps = ", ".join(self.decl_str(PTR(p) if (p.kind == "fn" or byval(p)) else p, "a%d" % i) for i, p in enumerate(ft.params)) if ft.params else "void"
            if ft.varargs: ps = (ps + ", ...") if ft.params else "..."
            head.append("%s %s(%s);" % (ft.ret.xc(), self.nm(n), ps))
        for n in sorted(self.vars_used): head.append(LIBC.var_decl(n))
        # byte strings
        for name, b in self.strings:
            head.append("u8 %s[%d] = {%s};" % (name, len(b) + 1, ", ".join(str(c) for c in b) + ", 0"))
        init = []
        # a null callback stored into a zeroed global is a no-op, and each
        # such store makes a stack temporary whose stale bytes xc releases
        # (large static tables can hold hundreds of them), so they are dropped
        null_cb = re.compile(r"^[A-Za-z_][\w\[\]\.\->\(\)\*&]* = \(callback [^;]*\)\(0\);$")
        self.init_stmts = [x for x in self.init_stmts if not null_cb.match(x)]
        if self.init_stmts:
            init.append("void %s(void)" % self.init_fn); init.append("{")
            init.extend("    " + s for s in self.init_stmts); init.append("}")
        wrappers = []
        for name, ft in sorted(self.va_wrappers.items()):
            ps = [self.decl_str(PTR(p) if byval(p) else p, "a%d" % i) for i, p in enumerate(ft.params or [])]
            args = ["a%d" % i for i in range(len(ft.params or []))] + ["..."]
            ret = "" if ft.ret.kind == "void" else "return "
            wrappers.append("%s %s__va(%s, ...) { %s%s(%s); }" % (ft.ret.xc(), self.nm(name), ", ".join(ps) or "void", ret, self.nm(name), ", ".join(args)))
        if wrappers: wrappers = ["// forwarding wrappers for variadics defined in other units (private:xcc-bugs/33)"] + wrappers
        return "\n".join(head + wrappers + [""] + body + [""] + init) + "\n"
    def struct_decls(self):
        out = []; done = set()
        # a tag seen only through pointers (struct iop in a unit that never
        # defines it) is declared opaque, which xcc 0.5 takes since 165a
        for t in self.structs.values():
            if t.fields is None and id(t) not in done: done.add(id(t)); out.append("struct %s;" % t.name)
        def emit(t):
            if id(t) in done or t.fields is None: return
            done.add(id(t))
            for _, ft, _ in t.fields:
                base = ft
                while base.kind == "array": base = base.to
                if base.kind in ("struct", "union"): emit(base)
            if t.kind == "union":
                out.append("struct %s { u8 raw[%d]; };" % (t.name, max(size_of(t), 1)))
                return
            lines = ["struct %s {" % t.name]
            for sl in struct_layout(t)[0]:
                if sl[0] == "field": lines.append("    %s;" % self.decl_str(sl[2], self.nm(sl[1]), field=True))
                else: lines.append("    %s %s;   // bit-fields %s" % (BF_UNIT[sl[2]], sl[1], ", ".join("%s:%d@%d" % (m[0], m[2], m[1]) for m in sl[4])))
            lines.append("};")
            out.extend(lines)
        for tag, t in self.structs.items(): emit(t)
        return out
    def toplevel(self, ext):
        if isinstance(ext, c_ast.Typedef):
            if ext.name in self.fake_typedefs: return                 # libc's names: xc spells them itself
            t = self.typedefs[ext.name]
            if t.kind in ("struct", "union", "fn") or t.is_fnptr(): return   # structs come from the table; callbacks are spelled inline
            if t.kind == "array":
                base, dims = self.flat(t)
                self.emit("typedef %s %s[%d];" % (base.xc(), ext.name if ext.name not in XC_RESERVED else ext.name + "_", max(1, eval("*".join(str(d or 1) for d in dims)))))
                return
            self.emit("typedef %s %s;" % (t.xc(), ext.name if ext.name not in XC_RESERVED else ext.name + "_"))
            return
        if isinstance(ext, c_ast.Decl):
            if isinstance(ext.type, c_ast.FuncDecl): return              # prototypes: dropped (natives come from the table)
            if ext.name is None: return                                  # a bare struct/enum definition
            if "extern" in (ext.storage or []) and ext.init is None:
                # a global of this program defined in another unit, or of libc:
                # declared extern here, once, so the unit binds it at link time
                if ext.name not in self.globals_defined() and ext.name in self.globals and ext.name not in self.externs_done:
                    self.externs_done.add(ext.name)
                    if ext.name in LIBC.VARS: self.emit("extern %s;" % self.decl_str(self.globals[ext.name], self.nm(ext.name)))
                    else: self.emit("extern %s;" % self.decl_str(self.globals[ext.name], self.nm(ext.name)))
                return
            self.global_decl(ext); return
        if isinstance(ext, c_ast.FuncDef):
            self.function(ext); return
        if isinstance(ext, c_ast.Pragma): return
        self.warn(ext, "unsupported top-level %s" % type(ext).__name__)
    def walk(self, node):
        out = []
        if node is None: return out
        stack = [node]
        while stack:
            n = stack.pop(); out.append(n)
            for _, ch in n.children(): stack.append(ch)
        return out
    def is_local(self, name):
        return any(name in sc for sc in self.locals)
    def globals_defined(self):
        return self.defined_globals
    def global_decl(self, d):
        t = self.globals[d.name]
        name = self.nm(d.name)
        if t.kind == "array" and d.init is not None:
            base, dims = self.flat(t)
            if any(x is None for x in dims):
                dims[0] = self.init_len(d.init, t); t = self.rebuild_array(base, dims); self.globals[d.name] = t
        decl = self.decl_str(t, name)
        if d.init is None:
            self.emit(decl + ";"); return
        if t.is_scalar():
            x = d.init.exprs[0] if isinstance(d.init, c_ast.InitList) else d.init
            v = self.const_eval(x)
            if v is not None and t.is_int(): self.emit("%s = %d;" % (decl, int(v))); return
            if v is not None and t.kind == "float": self.emit("%s = %s;" % (decl, xc_float(float(v), double=(t.bits == 64)))); return
            if isinstance(x, c_ast.Constant) and x.type == "string": self.emit("%s = %s;" % (decl, self.ex(x))); self.pre = []; return
            self.emit(decl + ";")
            s = self.ex(x, t); self.init_stmts.extend(self.pre); self.pre = []
            self.init_stmts.append("%s = %s;" % (name, s)); return
        if self.init_is_plain(d.init, t):
            self.emit("%s = %s;" % (decl, self.init_text(d.init, t))); return
        self.emit(decl + ";")
        self.init_stmts.extend(self.init_stmts_for(name, t, d.init))
    def function(self, fd):
        d = fd.decl
        ft = self.funcs.get(d.name)
        if ft is None or ft.kind != "fn" or ft.ret is None:
            sys.exit("c2xc: %s: cannot type function '%s' (%s); K&R-style definitions are not supported" % (fd.coord, d.name, type(d.type).__name__))
        self.cur_fn = ft
        name = self.nm(d.name)
        if d.name == "main": name = "main"
        params = []
        self.locals = [{}]
        copies = []
        if isinstance(d.type, c_ast.FuncDecl) and d.type.args:
            for p in d.type.args.params:
                if isinstance(p, c_ast.EllipsisParam): continue
                pt = self.type_of_decl(p)
                if pt.kind == "void": continue
                if pt.kind == "array": pt = PTR(pt.to)
                if pt.kind == "fn": pt = PTR(pt)
                if byval(pt):
                    nm = self.nm(p.name) if p.name else "_a%d" % len(params)
                    if p.name: self.locals[0][p.name] = pt
                    params.append(self.decl_str(PTR(pt), "_bv_" + nm)); copies.append("%s = *_bv_%s;" % (self.decl_str(pt, nm), nm))
                elif p.name: self.locals[0][p.name] = pt; params.append(self.decl_str(pt, self.nm(p.name)))
                else: params.append(self.decl_str(pt, "_a%d" % len(params)))
        ps = ", ".join(params) if params else "void"
        if ft.varargs: ps += ", ..."
        # a variadic that never reads its arguments and only hands them on can
        # forward them in xc, which forbids reading and forwarding together
        self.forward_only = ft.varargs and not self.mentions(fd.body, "__c2xc_va_arg") and self.mentions(fd.body, ("vsnprintf", "vsprintf", "vprintf", "vfprintf"))
        self.emit("%s %s(%s)" % (ft.ret.xc() if ft.ret.kind != "struct" else ft.ret.name, name, ps))
        self.emit("{")
        for c in copies: self.emit("    " + c)
        if d.name == "main": self.emit("    c2xc_rt_init();")          # stripped at the end if the run-time is not imported
        if d.name == "main" and self.init_stmts_pending(): self.emit("    %s();" % self.init_fn)
        self.body(fd.body, 1)
        self.emit("}")
        self.locals = []
        self.cur_fn = None
    def mentions(self, node, names):
        if isinstance(names, str): names = (names,)
        found = [False]
        class V(c_ast.NodeVisitor):
            def visit_FuncCall(self, n):
                if isinstance(n.name, c_ast.ID) and n.name.name in names: found[0] = True
                self.generic_visit(n)
        V().visit(node); return found[0]
    def labels_in(self, node):
        found = []
        class V(c_ast.NodeVisitor):
            def visit_Label(self, n): found.append(n.name); self.generic_visit(n)
        V().visit(node); return found
    def has_goto(self, node):
        found = [False]
        class V(c_ast.NodeVisitor):
            def visit_Goto(self, n): found[0] = True
        V().visit(node); return found[0]
    def state_machine(self, body, top, ind):
        """goto with every label at the function's top level: the body is cut
        into segments at the labels; a loop runs the segments in order under
        a state number, each guarded by `_st <= k` so falling into the next
        label is the next block running. `goto L` sets the state, raises a
        jump flag and leaves whatever it is inside (break out of loops and
        switches, each re-checking the flag on the way), and the outer loop
        re-dispatches. No xc switch is used (private:XCC-BUGS.md)."""
        items = body.block_items or []
        segs = [[]]; names = [None]
        for it in items:
            if isinstance(it, c_ast.Label):
                segs.append([]); names.append(it.name)
                if it.stmt is not None and not isinstance(it.stmt, c_ast.EmptyStatement): segs[-1].append(it.stmt)
            else: segs[-1].append(it)
        self.goto_state = {n: i for i, n in enumerate(names) if n is not None}
        self.goto_depth = 0
        self.locals.append({})
        for seg in segs:
            for k, s in enumerate(seg):
                if isinstance(s, c_ast.Decl) and s.name is not None and "typedef" not in (s.storage or []):
                    init = s.init; s.init = None
                    self.local_decl(s, ind)
                    if init is not None:
                        s.init = init
                        seg[k] = self.assign_from_init(s)
                    else: seg[k] = c_ast.EmptyStatement()
        self.emit("i32 _st = 0; bool _jump = false;", ind)
        self.emit("while (true) {", ind)
        self.emit("_jump = false;", ind + 1)
        self.loop_depth += 1
        for i, seg in enumerate(segs):
            self.emit("if (_st <= %d) {" % i, ind + 1)
            self.locals.append({})
            for j, s in enumerate(seg):
                self.stmt_g(s, ind + 2)
                if self.terminates(s): break
            self.locals.pop()
            self.emit("}", ind + 1)
            self.emit("if (_jump) continue;", ind + 1)
        self.loop_depth -= 1
        self.emit("break;", ind + 1)
        self.emit("}", ind)
        self.locals.pop()
        self.goto_state = None
        self.goto_depth = 0
    def assign_from_init(self, d):
        """A Decl with an initialiser, as the assignment statements that realise it."""
        class Init(c_ast.Node):
            attr_names = ()
            def __init__(self, decl): self.decl = decl; self.coord = decl.coord
            def children(self): return ()
        return Init(d)
    def stmt_g(self, s, ind):
        """A statement inside a state machine: gotos become jumps, and every
        loop or switch that contains one re-checks the flag after it."""
        if isinstance(s, c_ast.Goto):
            inside = self.goto_depth > 0 or bool(self.switch_stack)
            if self.switch_stack and self.inner_loop_depth == 0:
                run, cont = self.switch_stack[-1]
                self.emit("{ _st = %d; _jump = true; %s = false; break; }" % (self.goto_state[s.name], run), ind); return
            self.emit("{ _st = %d; _jump = true; %s; }" % (self.goto_state[s.name], "break" if inside else "continue"), ind); return
        if isinstance(s, c_ast.Label):
            self.warn(s, "nested label %s" % s.name); self.stmt_g(s.stmt, ind); return
        if isinstance(s, (c_ast.While, c_ast.DoWhile, c_ast.For, c_ast.Switch)) and self.has_goto(s):
            self.goto_depth += 1
            self.stmt(s, ind)
            self.goto_depth -= 1
            inside = self.goto_depth > 0 or bool(self.switch_stack)
            if self.switch_stack and self.inner_loop_depth == 0:
                run, cont = self.switch_stack[-1]; self.emit("if (_jump) { %s = false; break; }" % run, ind)
            else: self.emit("if (_jump) %s;" % ("break" if inside else "continue"), ind)
            return
        if isinstance(s, c_ast.Compound):
            self.emit("{", ind); self.block_g(s.block_items or [], ind + 1); self.emit("}", ind); return
        if isinstance(s, c_ast.If) and self.has_goto(s):
            c = self.ex(s.cond, ctx="cond"); self.flush_pre(ind)
            self.emit("if (%s) {" % c, ind)
            self.body_g(s.iftrue, ind + 1)
            if s.iffalse is not None:
                self.emit("} else {", ind); self.body_g(s.iffalse, ind + 1)
            self.emit("}", ind); return
        self.stmt(s, ind)
    def body_g(self, s, ind):
        if isinstance(s, c_ast.Compound): self.block_g(s.block_items or [], ind)
        else: self.block_g([s], ind)
    def block_g(self, items, ind):
        self.locals.append({})
        for i, s in enumerate(items):
            self.stmt_g(s, ind)
            if self.terminates(s) and i + 1 < len(items): break
        self.locals.pop()
    def init_stmts_pending(self):
        return True   # decided at the end; the call is harmless when the function is empty
    def dump(self, e):
        return type(e).__name__

# ────────────────────────────────────────────────────────────────────────────
def preprocess(path, incs, defs):
    fake = os.path.join(HERE, "vendor", "fake_libc_include")
    cmd = ["clang", "-E", "-nostdinc", "-undef", "-Wno-builtin-macro-redefined", "-Wno-macro-redefined", "-D__attribute__(x)=", "-D__extension__=", "-D__inline__=", "-D__inline=", "-D__restrict=", "-D__asm__(x)=",
           "-D__STDC__=1", "-D__STDC_VERSION__=199901L", "-Dc2xc=1", "-I" + os.path.join(HERE, "include"), "-I" + fake]
    for i in incs: cmd += ["-I" + i]
    for d in defs: cmd += ["-D" + d]
    cmd += ["-include", os.path.join(HERE, "c2xc_pre.h"), path]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0: sys.exit("cpp failed on %s:\n%s" % (path, r.stderr))
    return r.stdout

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+"); ap.add_argument("-o", default=None)
    ap.add_argument("-I", action="append", default=[]); ap.add_argument("-D", action="append", default=[])
    ap.add_argument("--char", default="unsigned"); ap.add_argument("--init-fn", default="c2xc_init_globals")
    ap.add_argument("--sizes-out", default=None, help="write the extents of the global arrays this conversion defines (JSON)")
    ap.add_argument("--sizes", default=None, help="read extents for extern arrays of unknown extent (JSON from --sizes-out); needed only on xcc builds before 2026-09-07 13:42 (private:xcc-bugs/32)")
    ap.add_argument("--va-wrappers", action="store_true", help="route calls to variadics defined in other units through local forwarding wrappers (private:xcc-bugs/33, builds before 2026-09-07 13:42)")
    ap.add_argument("--hoist-double-varargs", action="store_true", help="hoist non-variable double varargs into locals (private:xcc-bugs/29, builds before 2026-09-07)")
    ap.add_argument("-q", action="store_true")
    a = ap.parse_args()
    parser = c_parser.CParser()
    asts = []
    for f in a.files:
        src = preprocess(f, a.I, a.D)
        try: asts.append(parser.parse(src, filename=f))
        except Exception as e: sys.exit("parse failed on %s: %s" % (f, e))
    conv = Conv(char_signed=(a.char == "signed"), init_fn=a.init_fn)
    if a.sizes:
        import json
        conv.array_sizes = json.load(open(a.sizes))
    conv.va_wrappers_on = a.va_wrappers
    conv.hoist_double_varargs = a.hoist_double_varargs
    text = conv.convert(asts, a.files)
    if a.sizes_out:
        import json
        sizes = {conv.nm(n): t.n for n, t in conv.globals.items() if t.kind == "array" and t.n is not None}
        json.dump(sizes, open(a.sizes_out, "w"), indent=0, sort_keys=True)
    # the init call in main only if there is an init function
    if not conv.init_stmts: text = text.replace("    %s();\n" % a.init_fn, "")
    if not conv.needs_rt: text = text.replace("    c2xc_rt_init();\n", "")
    if a.o:
        open(a.o, "w").write(text)
        if conv.needs_rt:
            # the run-time goes beside the output, where xcc's quoted #import looks
            import shutil
            shutil.copy(os.path.join(HERE, "c2xc_rt.xc"), os.path.join(os.path.dirname(os.path.abspath(a.o)), "c2xc_rt.xc"))
    else: sys.stdout.write(text)
    if conv.warnings and not a.q:
        seen = set()
        for w in conv.warnings:
            if w in seen: continue
            seen.add(w); sys.stderr.write("c2xc: %s\n" % w)
    return 0

if __name__ == "__main__": sys.exit(main())
