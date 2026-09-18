// Arm64.xc — the AArch64 assembler, in xtc.
// =================================================================
//
// self-hosting M18, a port of `XAArm64Assembler`. It encodes the subset the
// arm64 back end emits (plus what clang emits in the host runtime the driver
// links alongside) into machine code, and byte-parity with the original — which
// is itself byte-parity with `clang -c` — is the bar.
//
// Two things shape the code more than the instruction set does.
//
// An assembler that quietly drops an instruction produces an object file that
// LINKS and then crashes somewhere unrelated, so an unrecognised mnemonic is an
// error by NAME, never a skip. The same reasoning runs through the branch
// range checks: masking an out-of-range displacement into its field yields a
// valid-looking instruction that jumps somewhere else entirely.
//
// And everything the linker has to finish — a call to another object, an
// `adrp`/`add` symbol pair, a `.quad` pointer — leaves a FIXUP behind rather
// than a guessed value.

#import "Foundation.xc"
#import "U64.xc"

#define FIXUP_BRANCH26      0
#define FIXUP_PAGE21        1
#define FIXUP_PAGEOFF12     2
#define FIXUP_POINTER64     3
#define FIXUP_GOTPAGE21     4
#define FIXUP_GOTPAGEOFF12  5

class Arm64Fixup
{
    u32     _offset;
    u32     _kind;
    String* _symbol;
    u32     _scale;         // PageOff12: log2 of the access size; 0 for `add`
    i32     _addend;        // sym + addend; only the archive reader sets it

    void init(void) { _offset = (u32)0; _kind = (u32)0; _scale = (u32)0; _addend = (i32)0; }

    static Arm64Fixup* make(u32 off, u32 kind, String* sym, u32 scale)
    {
        Arm64Fixup* f = new Arm64Fixup();
        f._offset = off; f._kind = kind; f._symbol = sym; f._scale = scale;
        return f;
    }

    u32     offset(void) { return _offset; }
    u32     kind(void)   { return _kind; }
    String* symbol(void) { return _symbol; }
    u32     scale(void)  { return _scale; }
    i32     addend(void) { return _addend; }
    // The linker rewrites fixups it merged from foreign objects (bug 138): a
    // GOT kind relaxed once its target turned out to be in the image, a data
    // slot moved by the ObjC repartition, an ADDEND carried from the reloc
    // before it.
    void    setOffset(u32 o) { _offset = o; }
    void    setKind(u32 k)   { _kind = k; }
    void    setScale(u32 s)  { _scale = s; }
    void    setAddend(i32 a) { _addend = a; }
}

// A parsed register. `ok` is false when the text was not a register at all,
// which is how the operand shapes are told apart — `mov` with a register second
// operand is a different instruction from `mov` with an immediate.
class RegRef
{
    bool _ok;
    u32  _num;
    bool _is64;
    bool _isSP;
    void init(void) { _ok = false; _num = (u32)0; _is64 = false; _isSP = false; }
    bool ok(void)   { return _ok; }
    u32  num(void)  { return _num; }
    bool is64(void) { return _is64; }
    bool isSP(void) { return _isSP; }
    static RegRef* no(void) { return new RegRef(); }
    static RegRef* yes(u32 n, bool w64, bool sp)
    { RegRef* r = new RegRef(); r._ok = true; r._num = n; r._is64 = w64; r._isSP = sp; return r; }
}

// A scalar FP/SIMD register: size 0=b 1=h 2=s 3=d 4=q.
class FRegRef
{
    bool _ok;
    u32  _num;
    u32  _sz;
    void init(void) { _ok = false; _num = (u32)0; _sz = (u32)0; }
    bool ok(void)  { return _ok; }
    u32  num(void) { return _num; }
    u32  sz(void)  { return _sz; }
    static FRegRef* no(void) { return new FRegRef(); }
    static FRegRef* yes(u32 n, u32 z)
    { FRegRef* r = new FRegRef(); r._ok = true; r._num = n; r._sz = z; return r; }
}

// A NEON register `vN.<arrangement>`, or one lane of one (`vN.s[1]`).
class VRegRef
{
    bool _ok;
    u32  _num;
    u32  _size;     // element size: 0=b 1=h 2=s 3=d
    u32  _q;        // 1 for the 128-bit arrangements
    u32  _idx;      // lane index, for the element form
    void init(void) { _ok = false; }
    bool ok(void)   { return _ok; }
    u32  num(void)  { return _num; }
    u32  size(void) { return _size; }
    u32  q(void)    { return _q; }
    u32  idx(void)  { return _idx; }
    static VRegRef* no(void) { return new VRegRef(); }
    static VRegRef* yes(u32 n, u32 sz, u32 q, u32 idx)
    { VRegRef* r = new VRegRef(); r._ok = true; r._num = n; r._size = sz; r._q = q; r._idx = idx; return r; }
}

class Arm64Asm
{
    Array*  _fixups;        // Arm64Fixup@
    Map*    _symbols;       // name -> offset within its own section
    Array*  _dataBytes;     // Number@, the __data image
    Array*  _dataSyms;      // String@, names that live in __data
    Array*  _globals;       // `.globl` names, in order
    Map*    _commonSyms;    // `.comm` COMMON: name -> [size, log2align] (bug 169)
    Array*  _textBytes;     // Number@, the __text image
    // Bug 066: the __DATA,__mod_init_func pointer array — the load-time
    // constructors — kept SEPARATE from _dataBytes, with its fixups' offsets
    // relative to itself. The linker appends it after every other contribution
    // to __data and shifts these fixups to match, then hands its length to the
    // writer, which gives it a real S_MOD_INIT_FUNC_POINTERS section. Without
    // that section TYPE dyld treats the pointers as inert data and no
    // constructor runs at all.
    //
    // Separate rather than "the tail of __data" because every object and
    // archive appends its own data during the link, so a range recorded here
    // would stop being the tail the moment anything else contributed.
    Array*  _modInitBytes;  // Number@
    Array*  _modInitFixups; // Arm64Fixup@
    bool    _failed;
    String* _why;

    void init(void)
    {
        _fixups = new Array(); _symbols = new Map();
        _dataBytes = new Array(); _dataSyms = new Array(); _globals = new Array(); _textBytes = new Array();
        _commonSyms = new Map();
        _modInitBytes = new Array(); _modInitFixups = new Array();
        _failed = false;
    }

    Array*  fixups(void)     { return _fixups; }
    Array*  modInitBytes(void)  { return _modInitBytes; }
    Array*  modInitFixups(void) { return _modInitFixups; }

    // Bug 066 / bug 124: append the constructor pointer array to the END of
    // `dataBytes`, 8-aligned, shifting its fixups to match, and return its
    // length. Both writers describe that tail — Mach-O with an
    // S_MOD_INIT_FUNC_POINTERS section, ELF with DT_INIT_ARRAY — and a caller
    // that forgets to append it silently drops every load-time constructor,
    // with nothing to diagnose. One copy, because the android link, the APK
    // link and xtlnandroid must all produce the same bytes.
    static u32 appendModInit(Arm64Asm* as, Array* dataBytes, Array* fixups)
    {
        u32 miLen = as.modInitBytes().count();
        if (miLen == (u32)0) return (u32)0;
        while (dataBytes.count() % (u32)8 != (u32)0)
            dataBytes.add((Object*)Number.withU32((u32)0));
        u32 base = dataBytes.count();
        for (u32 i = (u32)0; i < miLen; i = i + (u32)1)
            dataBytes.add(as.modInitBytes().get(i));
        for (u32 i = (u32)0; i < as.modInitFixups().count(); i = i + (u32)1) {
            Arm64Fixup* f = (Arm64Fixup*)as.modInitFixups().get(i);
            fixups.add((Object*)Arm64Fixup.make(base + f.offset(), f.kind(),
                                                f.symbol(), f.scale()));
        }
        return miLen;
    }
    Map*    symbols(void)    { return _symbols; }
    Array*  dataBytes(void)  { return _dataBytes; }
    Array*  textBytes(void)  { return _textBytes; }
    Array*  dataSyms(void)   { return _dataSyms; }
    Array*  globals(void)    { return _globals; }     // names under .globl — the object's exports
    Map*    commonSyms(void) { return _commonSyms; }  // `.comm` commons: name -> [size, log2align]
    bool    failed(void)     { return _failed; }
    String* why(void)        { return _why; }

    // Give every COMMON real storage in __data and define it locally, then clear
    // the common set. For single-unit IMAGE builds (executable/dylib), which
    // have no separate link stage; the object (`-c`) path keeps commons. Sorted
    // order (same insertion sort as MachO.sortNames) so the reference and this
    // assembler lay them out identically (bug 169).
    void demoteCommonsToLocalData(void)
    {
        if (_commonSyms.count() == (u32)0) return;
        Array* names = _commonSyms.allKeys();
        for (u32 i = (u32)1; i < names.count(); i = i + (u32)1) {
            Object* cur = names.get(i); u32 j = i;
            while (j > (u32)0 && ((String*)names.get(j - (u32)1)).compare((String*)cur) > (i32)0) {
                names.set(j, names.get(j - (u32)1)); j = j - (u32)1;
            }
            names.set(j, cur);
        }
        for (u32 k = (u32)0; k < names.count(); k = k + (u32)1) {
            String* nm = (String*)names.get(k);
            Array* info = (Array*)_commonSyms.get((Hashable*)nm);
            u32 sz = ((Number*)info.get((u32)0)).asU32();
            u32 alg = ((Number*)info.get((u32)1)).asU32();
            u32 al = (u32)1 << alg;
            while (_dataBytes.count() % al != (u32)0) _dataBytes.add((Object*)Number.withU32((u32)0));
            _symbols.set((Hashable*)nm, (Object*)Number.withU32(_dataBytes.count()));
            _dataSyms.add((Object*)nm);
            for (u32 i = (u32)0; i < sz; i = i + (u32)1) _dataBytes.add((Object*)Number.withU32((u32)0));
        }
        _commonSyms = new Map();
    }

    void fail(String* msg)
    {
        if (_failed) return;
        _failed = true;
        _why = msg;
    }

    void failFmt(String* what, String* detail)
    {
        String* m = new String();
        m.append(what);
        if (detail != (String*)0) { m.appendCString(" "); m.append(detail); }
        fail(m);
    }

    // ── the GNU/ELF dialect ──────────────────────────────────────────────
    //
    // Rewrite ELF-flavoured AArch64 asm into the Mach-O flavour this assembler
    // parses. The two differ only in how a symbol reference is SPELLED — the
    // instructions are identical — so one normalising pre-pass buys the whole
    // dialect rather than a second spelling at every operand site:
    //
    //     adrp x1, sym          ->  adrp x1, sym@PAGE
    //     :lo12:sym             ->  sym@PAGEOFF
    //     :got:sym              ->  sym@GOTPAGE
    //     :got_lo12:sym         ->  sym@GOTPAGEOFF
    //
    // Needed because the Android runtime (support/arm64/runtime/rt-android.s
    // and glue-android.s) is generated by the NDK clang, which targets ELF: it
    // must be assembled from exactly the text clang produced, or the ABI it was
    // generated for stops being the ABI it is checked against. Idempotent on
    // asm that is already Mach-O flavoured, so it is safe over a mixed input.
    static bool isSymByte(u8 c)
    {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z')
            || (c >= (u8)'0' && c <= (u8)'9')
            || c == (u8)'_' || c == (u8)'$' || c == (u8)'.';
    }

    static bool isSymStart(u8 c)
    {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z')
            || c == (u8)'_' || c == (u8)'$' || c == (u8)'.';
    }

    // `:<op>:sym` → `sym<mod>`, in place, once per line (clang emits at most one).
    static String* elfOperatorToMacho(String* l, String* op, String* mod)
    {
        u32 at = l.byteIndexOf(op);
        if (at == (u32)$FFFF_FFFF) return l;
        u32 sb = at + op.byteLength();
        u32 se = sb;
        while (se < l.byteLength() && isSymByte(l.byteAt(se))) se = se + (u32)1;
        if (se == sb || !isSymStart(l.byteAt(sb))) return l;
        String* o = new String();
        o.append(l.substringBytes((u32)0, at));
        o.append(l.substringBytes(sb, se - sb));
        o.append(mod);
        o.append(l.substringBytes(se, l.byteLength() - se));
        return o;
    }

    static String* machoDialectFromElf(String* elfAsm)
    {
        if (elfAsm == (String*)0) return new String();
        Array* lines = elfAsm.splitOnByte((u8)'\n');
        String* out = new String();
        for (u32 li = (u32)0; li < lines.count(); li = li + (u32)1) {
            String* l = (String*)lines.get(li);
            // `:got_lo12:` first: it is the longest, and stating the order says
            // the intent even though no shorter pattern can match inside it.
            l = elfOperatorToMacho(l, String.withCString(":got_lo12:"),
                                      String.withCString("@GOTPAGEOFF"));
            l = elfOperatorToMacho(l, String.withCString(":got:"),
                                      String.withCString("@GOTPAGE"));
            l = elfOperatorToMacho(l, String.withCString(":lo12:"),
                                      String.withCString("@PAGEOFF"));
            // A BARE symbol operand on adrp. Anything already carrying an `@`
            // is left alone, which is what makes this idempotent. The symbol
            // must run to end of line, so a decorated or commented operand is
            // not touched.
            if (l.trimmed().hasPrefix(String.withCString("adrp"))
             && l.byteIndexOf(String.withCString("@")) == (u32)$FFFF_FFFF) {
                u32 c = l.byteIndexOf(String.withCString(","));
                if (c != (u32)$FFFF_FFFF) {
                    u32 sb = c + (u32)1;
                    while (sb < l.byteLength()
                        && (l.byteAt(sb) == (u8)' ' || l.byteAt(sb) == (u8)'\t'))
                        sb = sb + (u32)1;
                    u32 se = sb;
                    while (se < l.byteLength() && isSymByte(l.byteAt(se))) se = se + (u32)1;
                    bool tail = true;
                    for (u32 k = se; k < l.byteLength(); k = k + (u32)1) {
                        u8 ch = l.byteAt(k);
                        if (ch != (u8)' ' && ch != (u8)'\t' && ch != (u8)'\r') { tail = false; }
                    }
                    if (se > sb && tail && isSymStart(l.byteAt(sb))) {
                        String* o = new String();
                        o.append(l.substringBytes((u32)0, se));
                        o.appendCString("@PAGE");
                        o.append(l.substringBytes(se, l.byteLength() - se));
                        l = o;
                    }
                }
            }
            if (li > (u32)0) out.appendByte((u8)'\n');
            out.append(l);
        }
        return out;
    }

    // ── Operand parsing ──────────────────────────────────────────────────
    //
    // A GP register. `sp`/`wsp` are 31 with the SP flag, which changes the
    // encoding of add/sub (the shifted-register form cannot name SP, so those
    // become the extended-register form).
    static RegRef* parseReg(String* s0)
    {
        if (s0 == (String*)0) return RegRef.no();
        String* s = s0.trimmed();
        if (s.equals(String.withCString("sp")))  return RegRef.yes((u32)31, true, true);
        if (s.equals(String.withCString("wsp"))) return RegRef.yes((u32)31, false, true);
        if (s.equals(String.withCString("xzr"))) return RegRef.yes((u32)31, true, false);
        if (s.equals(String.withCString("wzr"))) return RegRef.yes((u32)31, false, false);
        if (s.equals(String.withCString("fp")))  return RegRef.yes((u32)29, true, false);
        if (s.equals(String.withCString("lr")))  return RegRef.yes((u32)30, true, false);
        if (s.byteLength() < (u32)2) return RegRef.no();
        u8 c = s.byteAt((u32)0);
        if (c != (u8)'w' && c != (u8)'x') return RegRef.no();
        u32 n = (u32)0;
        for (u32 i = (u32)1; i < s.byteLength(); i = i + (u32)1) {
            u8 d = s.byteAt(i);
            if (d < (u8)'0' || d > (u8)'9') return RegRef.no();
            n = n * (u32)10 + (u32)(d - (u8)'0');
        }
        if (n > (u32)30) return RegRef.no();
        return RegRef.yes(n, c == (u8)'x', false);
    }

    static FRegRef* parseFReg(String* s0)
    {
        if (s0 == (String*)0) return FRegRef.no();
        String* s = s0.trimmed();
        if (s.byteLength() < (u32)2) return FRegRef.no();
        u8 c = s.byteAt((u32)0);
        u32 z;
        if (c == (u8)'b') z = (u32)0;
        else if (c == (u8)'h') z = (u32)1;
        else if (c == (u8)'s') z = (u32)2;
        else if (c == (u8)'d') z = (u32)3;
        else if (c == (u8)'q') z = (u32)4;
        else return FRegRef.no();
        u32 n = (u32)0;
        for (u32 i = (u32)1; i < s.byteLength(); i = i + (u32)1) {
            u8 d = s.byteAt(i);
            if (d < (u8)'0' || d > (u8)'9') return FRegRef.no();
            n = n * (u32)10 + (u32)(d - (u8)'0');
        }
        if (n > (u32)31) return FRegRef.no();
        return FRegRef.yes(n, z);
    }

    static VRegRef* parseVReg(String* s0)
    {
        if (s0 == (String*)0) return VRegRef.no();
        String* s = s0.trimmed();
        if (!s.hasPrefix(String.withCString("v"))) return VRegRef.no();
        u32 dot = s.byteIndexOf(String.withCString("."));
        if (dot == (u32)$FFFF_FFFF) return VRegRef.no();
        u32 n = (u32)0;
        for (u32 i = (u32)1; i < dot; i = i + (u32)1) {
            u8 d = s.byteAt(i);
            if (d < (u8)'0' || d > (u8)'9') return VRegRef.no();
            n = n * (u32)10 + (u32)(d - (u8)'0');
        }
        if (n > (u32)31) return VRegRef.no();
        String* arr = s.substringFromByte(dot + (u32)1);
        if (arr.equals(String.withCString("8b")))  return VRegRef.yes(n, (u32)0, (u32)0, (u32)0);
        if (arr.equals(String.withCString("16b"))) return VRegRef.yes(n, (u32)0, (u32)1, (u32)0);
        if (arr.equals(String.withCString("4h")))  return VRegRef.yes(n, (u32)1, (u32)0, (u32)0);
        if (arr.equals(String.withCString("8h")))  return VRegRef.yes(n, (u32)1, (u32)1, (u32)0);
        if (arr.equals(String.withCString("2s")))  return VRegRef.yes(n, (u32)2, (u32)0, (u32)0);
        if (arr.equals(String.withCString("4s")))  return VRegRef.yes(n, (u32)2, (u32)1, (u32)0);
        if (arr.equals(String.withCString("1d")))  return VRegRef.yes(n, (u32)3, (u32)0, (u32)0);
        if (arr.equals(String.withCString("2d")))  return VRegRef.yes(n, (u32)3, (u32)1, (u32)0);
        return VRegRef.no();
    }

    static VRegRef* parseVElem(String* s0)
    {
        if (s0 == (String*)0) return VRegRef.no();
        String* s = s0.trimmed();
        if (!s.hasPrefix(String.withCString("v"))) return VRegRef.no();
        u32 dot = s.byteIndexOf(String.withCString("."));
        u32 lb = s.byteIndexOf(String.withCString("["));
        u32 rb = s.byteIndexOf(String.withCString("]"));
        if (dot == (u32)$FFFF_FFFF || lb == (u32)$FFFF_FFFF || rb == (u32)$FFFF_FFFF) return VRegRef.no();
        if (!(dot < lb && lb < rb)) return VRegRef.no();
        u32 n = (u32)0;
        for (u32 i = (u32)1; i < dot; i = i + (u32)1) {
            u8 d = s.byteAt(i);
            if (d < (u8)'0' || d > (u8)'9') return VRegRef.no();
            n = n * (u32)10 + (u32)(d - (u8)'0');
        }
        if (n > (u32)31) return VRegRef.no();
        String* ty = s.substringBytes(dot + (u32)1, lb - dot - (u32)1);
        u32 sz;
        if (ty.equals(String.withCString("b"))) sz = (u32)0;
        else if (ty.equals(String.withCString("h"))) sz = (u32)1;
        else if (ty.equals(String.withCString("s"))) sz = (u32)2;
        else if (ty.equals(String.withCString("d"))) sz = (u32)3;
        else return VRegRef.no();
        u32 idx = (u32)0;
        for (u32 i = lb + (u32)1; i < rb; i = i + (u32)1) {
            u8 d = s.byteAt(i);
            if (d < (u8)'0' || d > (u8)'9') return VRegRef.no();
            idx = idx * (u32)10 + (u32)(d - (u8)'0');
        }
        return VRegRef.yes(n, sz, (u32)0, idx);
    }

    // An immediate: `#…` or bare, hex or decimal, optionally negative, with
    // `_` digit separators dropped. `ok` distinguishes "not a number" from
    // "the number zero", which decides operand shape all over the encoder.
    bool _immOk;

    U64* parseImm(String* s0)
    {
        _immOk = false;
        if (s0 == (String*)0) return U64.zero();
        String* s = s0.trimmed();
        if (s.hasPrefix(String.withCString("#"))) s = s.substringFromByte((u32)1);
        String* clean = new String();
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            if (s.byteAt(i) != (u8)'_') clean.appendByte(s.byteAt(i));
        s = clean;
        if (s.byteLength() == (u32)0) return U64.zero();
        bool neg = false;
        if (s.hasPrefix(String.withCString("-"))) { neg = true; s = s.substringFromByte((u32)1); }
        u32 base = (u32)10;
        if (s.hasPrefix(String.withCString("0x")) || s.hasPrefix(String.withCString("0X"))) {
            base = (u32)16; s = s.substringFromByte((u32)2);
        }
        if (s.byteLength() == (u32)0) return U64.zero();
        U64* v = U64.zero();
        U64* b = U64.fromU32(base);
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1) {
            u8 c = s.byteAt(i);
            u32 d;
            if (c >= (u8)'0' && c <= (u8)'9') d = (u32)(c - (u8)'0');
            else if (base == (u32)16 && c >= (u8)'a' && c <= (u8)'f') d = (u32)(c - (u8)'a') + (u32)10;
            else if (base == (u32)16 && c >= (u8)'A' && c <= (u8)'F') d = (u32)(c - (u8)'A') + (u32)10;
            else return U64.zero();
            v = mul64small(v, b).plus(U64.fromU32(d));
        }
        _immOk = true;
        return neg ? v.negated() : v;
    }

    // Only ever called with a base of 10 or 16, so a shift-and-add is enough
    // and there is no need for a general 64x64 multiply.
    static U64* mul64small(U64* v, U64* b)
    {
        if (b.lo() == (u32)16 && b.hi() == (u32)0) return v.shl((u32)4);
        // times ten = (v << 3) + (v << 1)
        return v.shl((u32)3).plus(v.shl((u32)1));
    }

    bool immOk(void) { return _immOk; }

    // ── Line handling ────────────────────────────────────────────────────
    //
    // Strip an end-of-line comment — `//` from our back end, `;` from clang's
    // arm64 output — but not one inside a quoted string, or a `.asciz` holding
    // a semicolon loses its tail.
    static String* stripComment(String* l)
    {
        bool inStr = false;
        for (u32 i = (u32)0; i < l.byteLength(); i = i + (u32)1) {
            u8 c = l.byteAt(i);
            if (c == (u8)'"') { inStr = !inStr; continue; }
            if (inStr) continue;
            if (c == (u8)';') return l.substringBytes((u32)0, i);
            if (c == (u8)'/' && i + (u32)1 < l.byteLength() && l.byteAt(i + (u32)1) == (u8)'/')
                return l.substringBytes((u32)0, i);
        }
        return l;
    }

    // xtc's inline-asm capture re-tokenises the body, and because `@` is the
    // language's pointer operator it re-emits `_g@PAGE` as `_g @ PAGE`. clang
    // tolerates the spaces, so this must too: otherwise the symbol keeps a
    // trailing space, never matches the defined name, and the adrp/add pair
    // resolves to zero — a wild store.
    static String* normPageMod(String* op)
    {
        if (op.byteIndexOf(String.withCString("@")) == (u32)$FFFF_FFFF) return op;
        String* out = new String();
        u32 i = (u32)0;
        while (i < op.byteLength()) {
            u8 c = op.byteAt(i);
            if (c == (u8)' ' || c == (u8)'\t') {
                u32 j = i;
                while (j < op.byteLength() && (op.byteAt(j) == (u8)' ' || op.byteAt(j) == (u8)'\t'))
                    j = j + (u32)1;
                if (j < op.byteLength() && op.byteAt(j) == (u8)'@') { i = j; continue; }
                out.appendByte(c); i = i + (u32)1; continue;
            }
            if (c == (u8)'@') {
                out.appendByte(c);
                u32 j = i + (u32)1;
                while (j < op.byteLength() && (op.byteAt(j) == (u8)' ' || op.byteAt(j) == (u8)'\t'))
                    j = j + (u32)1;
                i = j; continue;
            }
            out.appendByte(c); i = i + (u32)1;
        }
        return out;
    }

    // Split on commas at bracket depth zero, so `[x0, #8]` stays one operand.
    static Array* splitOperands(String* s)
    {
        Array* out = new Array();
        i32 depth = (i32)0;
        u32 start = (u32)0;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1) {
            u8 c = s.byteAt(i);
            if (c == (u8)'[') depth = depth + (i32)1;
            else if (c == (u8)']') depth = depth - (i32)1;
            else if (c == (u8)',' && depth == (i32)0) {
                out.add((Object*)normPageMod(s.substringBytes(start, i - start).trimmed()));
                start = i + (u32)1;
            }
        }
        String* last = normPageMod(s.substringFromByte(start).trimmed());
        if (last.byteLength() > (u32)0) out.add((Object*)last);
        return out;
    }

    static i32 condCode(String* cc)
    {
        if (cc.equals(String.withCString("eq"))) return (i32)0;
        if (cc.equals(String.withCString("ne"))) return (i32)1;
        if (cc.equals(String.withCString("cs")) || cc.equals(String.withCString("hs"))) return (i32)2;
        if (cc.equals(String.withCString("cc")) || cc.equals(String.withCString("lo"))) return (i32)3;
        if (cc.equals(String.withCString("mi"))) return (i32)4;
        if (cc.equals(String.withCString("pl"))) return (i32)5;
        if (cc.equals(String.withCString("vs"))) return (i32)6;
        if (cc.equals(String.withCString("vc"))) return (i32)7;
        if (cc.equals(String.withCString("hi"))) return (i32)8;
        if (cc.equals(String.withCString("ls"))) return (i32)9;
        if (cc.equals(String.withCString("ge"))) return (i32)10;
        if (cc.equals(String.withCString("lt"))) return (i32)11;
        if (cc.equals(String.withCString("gt"))) return (i32)12;
        if (cc.equals(String.withCString("le"))) return (i32)13;
        if (cc.equals(String.withCString("al"))) return (i32)14;
        return (i32)-1;
    }

    static u32 firstSpace(String* s)
    {
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1) {
            u8 c = s.byteAt(i);
            if (c == (u8)' ' || c == (u8)'\t') return i;
        }
        return (u32)$FFFF_FFFF;
    }

    static String* opAt(Array* ops, u32 i)
    {
        return i < ops.count() ? (String*)ops.get(i) : String.withCString("");
    }

    // ── The bitmask (logical) immediate ──────────────────────────────────
    //
    // N:immr:imms, thirteen bits describing a repeating run of ones. Ported
    // from LLVM's processLogicalImmediate; the shape is not obvious and is not
    // worth re-deriving. Returns $FFFF_FFFF when the value is not encodable,
    // which is a real answer — `and x0, x0, #5` genuinely has no encoding.
    static bool isMask64(U64* v)
    {
        if (v.isZero()) return false;
        return v.plus(U64.fromU32((u32)1)).anded(v).isZero();
    }

    static bool isShiftedMask64(U64* v)
    {
        if (v.isZero()) return false;
        return isMask64(v.minus(U64.fromU32((u32)1)).ored(v));
    }

    static u32 encodeLogImm(U64* imm0, u32 regSize)
    {
        U64* imm = imm0;
        if (imm.isZero() || imm.isOnes()) return (u32)$FFFF_FFFF;
        if (regSize != (u32)64) {
            if (!imm.shr(regSize).isZero()) return (u32)$FFFF_FFFF;
            if (imm.equals64(U64.ones().shr((u32)64 - regSize))) return (u32)$FFFF_FFFF;
        }
        u32 size = regSize;
        while (true) {
            size = size / (u32)2;
            U64* m = U64.maskLow(size);
            if (!imm.anded(m).equals64(imm.shr(size).anded(m))) { size = size * (u32)2; break; }
            if (size <= (u32)2) break;
        }
        U64* mask = U64.ones().shr((u32)64 - size);
        imm = imm.anded(mask);
        u32 cto;
        u32 i;
        if (isShiftedMask64(imm)) {
            i = imm.ctz();
            cto = imm.shr(i).notted().ctz();
        } else {
            imm = imm.ored(mask.notted());
            if (!isShiftedMask64(imm.notted())) return (u32)$FFFF_FFFF;
            u32 clo = imm.notted().clz();
            i = (u32)64 - clo;
            cto = clo + imm.notted().ctz() - ((u32)64 - size);
        }
        u32 immr = (size - i) & (size - (u32)1);
        // nimms = ~(size-1) << 1, then the low bits carry cto-1.
        U64* nimms = U64.fromU32(size - (u32)1).notted().shl((u32)1);
        nimms = nimms.ored(U64.fromU32(cto - (u32)1));
        u32 N = ((nimms.shr((u32)6).lo() & (u32)1) ^ (u32)1) & (u32)1;
        return (N << (u32)12) | (immr << (u32)6) | (nimms.lo() & (u32)$3F);
    }

    // ── Encoding one line ────────────────────────────────────────────────
    //
    // `resolveLocal` is filled in by the caller's symbol table: a TEXT label
    // gives its address and a relative branch; anything else becomes a fixup.
    Map*  _resolveSyms;
    Array* _resolveDataSyms;
    bool  _lastWasLocal;

    u32 resolveTarget(String* name)
    {
        _lastWasLocal = false;
        if (_resolveSyms == (Map*)0) return (u32)0;
        Object* a = _resolveSyms.get((Hashable*)name);
        if (a == (Object*)0) return (u32)0;
        for (u32 i = (u32)0; i < _resolveDataSyms.count(); i = i + (u32)1)
            if (((String*)_resolveDataSyms.get(i)).equals(name)) return (u32)0;
        _lastWasLocal = true;
        return ((Number*)a).asU32();
    }

    void addFixup(u32 pc, u32 kind, String* sym, u32 scale)
    {
        _fixups.add((Object*)Arm64Fixup.make(pc, kind, sym, scale));
    }

    // Set by every encoder that recognised its line. The dispatch chain reads
    // it instead of a sentinel word, because 0x00000000 is a real encoding.
    bool _hit;

    u32 encodeLine(String* raw, u32 pc)
    {
        _hit = false;
        String* line = stripComment(raw).trimmed();
        if (line.byteLength() == (u32)0) { fail(String.withCString("empty line")); return (u32)0; }
        u32 sp = firstSpace(line);
        String* mn = sp == (u32)$FFFF_FFFF ? line : line.substringBytes((u32)0, sp);
        String* rest = sp == (u32)$FFFF_FFFF ? String.withCString("")
                                             : line.substringFromByte(sp).trimmed();
        Array* ops = splitOperands(rest);

        u32 w = encNeon(mn, ops, pc);      if (_hit) return w;
        w = encAtomics(mn, ops, pc);        if (_hit) return w;
        w = encMoves(mn, ops, pc);          if (_hit) return w;
        w = encFloat(mn, ops, pc);          if (_hit) return w;
        w = encAddSubLogic(mn, ops, pc);    if (_hit) return w;
        w = encBitfieldMul(mn, ops, pc);    if (_hit) return w;
        w = encMemory(mn, ops, pc);         if (_hit) return w;
        w = encBranches(mn, ops, pc);       if (_hit) return w;

        String* m = String.withCString("unhandled mnemonic: ");
        m.append(mn);
        fail(m);
        return (u32)0;
    }


    // ── atomics and barriers (private:docs/Design/threading.md) ──────────────────
    //
    // Threading puts these in the toolchain's path two ways: the runtime's C
    // atomics compile to them, and the back end emits `ldaddh`/`ldaddalh`
    // inline for the ARC refcount under -fthread-safe-arc.
    //
    //   LDAR/STLR   size 001000 1 L 0 11111 1 11111 Rn Rt
    //   LD<op>/SWP  size 111000 A R 1 Rs  o3 opc 00 Rn Rt
    //   CAS         size 0010001 A 1 Rs  R  11111    Rn Rt
    //
    // The suffix carries BOTH the width (b/h) and the ordering (a/l/al), so the
    // mnemonic is taken apart rather than looked up: `ldaddalh` is add,
    // acquire-release, halfword. Width comes off FIRST — `l` (release) and
    // `b`/`h` can both end a mnemonic, and only that order is unambiguous.
    // Everything here is LOCAL: an earlier cut kept the pieces in ivars and the
    // assembler faulted on ordinary code long before it reached an atomic.
    static u32 lseOpcFor(String* b)
    {
        if (b.equals(String.withCString("add")))  return (u32)0;
        if (b.equals(String.withCString("clr")))  return (u32)1;
        if (b.equals(String.withCString("eor")))  return (u32)2;
        if (b.equals(String.withCString("set")))  return (u32)3;
        if (b.equals(String.withCString("smax"))) return (u32)4;
        if (b.equals(String.withCString("smin"))) return (u32)5;
        if (b.equals(String.withCString("umax"))) return (u32)6;
        if (b.equals(String.withCString("umin"))) return (u32)7;
        return (u32)$FFFF_FFFF;
    }

    // `[x16]` → `x16`. The memory operand of every form here is a bare base
    // register in brackets; nothing takes an offset.
    static String* atMemBase(String* op)
    {
        String* t = op.trimmed();
        String* o = new String();
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1) {
            u8 c = t.byteAt(i);
            if (c != (u8)'[' && c != (u8)']' && c != (u8)' ') o.appendByte(c);
        }
        return o;
    }

    u32 encAtomics(String* mn, Array* ops, u32 pc)
    {
        // ── load/store EXCLUSIVE ──────────────────────────────────────────
        //   size 001000 o2 L o1 Rs o0 Rt2 Rn Rt
        // L picks load vs store, o0 the acquire/release ordering. Not an
        // optional corner: Android's armv8-a baseline has no LSE, so an atomic
        // read-modify-write IS an ldaxr/stlxr pair and the `cas*` forms below
        // are never reached there.
        if (mn.hasPrefix(String.withCString("ldxr")) || mn.hasPrefix(String.withCString("ldaxr"))
         || mn.hasPrefix(String.withCString("stxr")) || mn.hasPrefix(String.withCString("stlxr"))) {
            bool isLoad = mn.hasPrefix(String.withCString("ld"));
            bool acqRel = mn.hasPrefix(String.withCString("ldaxr"))
                       || mn.hasPrefix(String.withCString("stlxr"));
            u32 o0 = acqRel ? (u32)1 : (u32)0;
            String* sfx = mn.substringFromByte(acqRel ? (u32)5 : (u32)4);
            i32 sz = (i32)-2;
            if (sfx.byteLength() == (u32)0) sz = (i32)-1;
            else if (sfx.equals(String.withCString("b"))) sz = (i32)0;
            else if (sfx.equals(String.withCString("h"))) sz = (i32)1;
            u32 want = isLoad ? (u32)2 : (u32)3;
            if (sz != (i32)-2 && ops.count() == want) {
                u32 ti = isLoad ? (u32)0 : (u32)1;
                RegRef* t = parseReg(opAt(ops, ti));
                RegRef* n = parseReg(atMemBase(opAt(ops, ops.count() - (u32)1)));
                u32 rs = (u32)31;
                bool rsOk = true;
                if (!isLoad) {
                    RegRef* sr = parseReg(opAt(ops, (u32)0));
                    if (sr.ok()) rs = sr.num(); else rsOk = false;
                }
                if (t.ok() && n.ok() && rsOk) {
                    if (sz < (i32)0) sz = t.is64() ? (i32)3 : (i32)2;
                    _hit = true;
                    return ((u32)sz << (u32)30) | (u32)$08000000
                         | ((isLoad ? (u32)1 : (u32)0) << (u32)22)
                         | (rs << (u32)16) | (o0 << (u32)15) | ((u32)31 << (u32)10)
                         | (n.num() << (u32)5) | t.num();
                }
            }
        }
        // clrex — drop the exclusive monitor on such a loop's failure path.
        if (mn.equals(String.withCString("clrex"))) { _hit = true; return (u32)$D5033F5F; }

        // ldar{b|h} / stlr{b|h}  Rt, [Xn]
        if (ops.count() == (u32)2 && mn.byteLength() >= (u32)4
            && (mn.hasPrefix(String.withCString("ldar"))
             || mn.hasPrefix(String.withCString("stlr")))) {
            bool isLoad = mn.hasPrefix(String.withCString("ldar"));
            String* sfx = mn.substringFromByte((u32)4);
            i32 sz = (i32)-2;
            if (sfx.byteLength() == (u32)0) sz = (i32)-1;
            else if (sfx.equals(String.withCString("b"))) sz = (i32)0;
            else if (sfx.equals(String.withCString("h"))) sz = (i32)1;
            if (sz != (i32)-2) {
                RegRef* t = parseReg(opAt(ops, (u32)0));
                RegRef* n = parseReg(atMemBase(opAt(ops, (u32)1)));
                if (t.ok() && n.ok()) {
                    if (sz < (i32)0) sz = t.is64() ? (i32)3 : (i32)2;
                    _hit = true;
                    return ((u32)sz << (u32)30) | (u32)$08000000 | ((u32)1 << (u32)23)
                         | ((isLoad ? (u32)1 : (u32)0) << (u32)22) | ((u32)31 << (u32)16)
                         | ((u32)1 << (u32)15) | ((u32)31 << (u32)10)
                         | (n.num() << (u32)5) | t.num();
                }
            }
        }

        // ld<op>{a}{l}{b|h} / swp{a}{l}{b|h} / cas{a}{l}{b|h}   Rs, Rt, [Xn]
        if (ops.count() == (u32)3) {
            bool isSwp = mn.hasPrefix(String.withCString("swp"));
            bool isCas = mn.hasPrefix(String.withCString("cas"));
            bool isLd  = mn.hasPrefix(String.withCString("ld"));
            if (isSwp || isCas || isLd) {
                u32 plen = (isSwp || isCas) ? (u32)3 : (u32)2;
                String* t = mn.substringFromByte(plen);
                i32 sz = (i32)-1; u32 A = (u32)0; u32 R = (u32)0;
                if (t.byteLength() > (u32)0 && t.hasSuffix(String.withCString("b"))) {
                    sz = (i32)0; t = t.substringBytes((u32)0, t.byteLength() - (u32)1);
                } else if (t.byteLength() > (u32)0 && t.hasSuffix(String.withCString("h"))) {
                    sz = (i32)1; t = t.substringBytes((u32)0, t.byteLength() - (u32)1);
                }
                if (t.byteLength() >= (u32)2 && t.hasSuffix(String.withCString("al"))) {
                    A = (u32)1; R = (u32)1; t = t.substringBytes((u32)0, t.byteLength() - (u32)2);
                } else if (t.byteLength() >= (u32)1 && t.hasSuffix(String.withCString("a"))) {
                    A = (u32)1; t = t.substringBytes((u32)0, t.byteLength() - (u32)1);
                } else if (t.byteLength() >= (u32)1 && t.hasSuffix(String.withCString("l"))) {
                    R = (u32)1; t = t.substringBytes((u32)0, t.byteLength() - (u32)1);
                }
                u32 opc = (isSwp || isCas) ? (u32)0 : lseOpcFor(t);
                bool shaped = (isSwp || isCas) ? t.byteLength() == (u32)0
                                               : opc != (u32)$FFFF_FFFF;
                if (shaped) {
                    RegRef* rs = parseReg(opAt(ops, (u32)0));
                    RegRef* rt = parseReg(opAt(ops, (u32)1));
                    RegRef* rn = parseReg(atMemBase(opAt(ops, (u32)2)));
                    if (rs.ok() && rt.ok() && rn.ok()) {
                        if (sz < (i32)0) sz = rs.is64() ? (i32)3 : (i32)2;
                        _hit = true;
                        if (isCas)
                            return ((u32)sz << (u32)30) | (u32)$08A00000 | (A << (u32)22)
                                 | (rs.num() << (u32)16) | (R << (u32)15) | ((u32)31 << (u32)10)
                                 | (rn.num() << (u32)5) | rt.num();
                        return ((u32)sz << (u32)30) | (u32)$38000000 | (A << (u32)23)
                             | (R << (u32)22) | ((u32)1 << (u32)21) | (rs.num() << (u32)16)
                             | ((isSwp ? (u32)1 : (u32)0) << (u32)15) | (opc << (u32)12)
                             | (rn.num() << (u32)5) | rt.num();
                    }
                }
            }
        }

        // dmb/dsb <option>, isb
        if ((mn.equals(String.withCString("dmb")) || mn.equals(String.withCString("dsb")))
            && ops.count() == (u32)1) {
            String* o = opAt(ops, (u32)0);
            u32 opt = (u32)$FFFF_FFFF;
            if (o.equals(String.withCString("oshld"))) opt = (u32)1;
            else if (o.equals(String.withCString("oshst"))) opt = (u32)2;
            else if (o.equals(String.withCString("osh")))   opt = (u32)3;
            else if (o.equals(String.withCString("nshld"))) opt = (u32)5;
            else if (o.equals(String.withCString("nshst"))) opt = (u32)6;
            else if (o.equals(String.withCString("nsh")))   opt = (u32)7;
            else if (o.equals(String.withCString("ishld"))) opt = (u32)9;
            else if (o.equals(String.withCString("ishst"))) opt = (u32)10;
            else if (o.equals(String.withCString("ish")))   opt = (u32)11;
            else if (o.equals(String.withCString("ld")))    opt = (u32)13;
            else if (o.equals(String.withCString("st")))    opt = (u32)14;
            else if (o.equals(String.withCString("sy")))    opt = (u32)15;
            if (opt != (u32)$FFFF_FFFF) {
                u32 opc2 = mn.equals(String.withCString("dmb")) ? (u32)5 : (u32)4;
                _hit = true;
                return (u32)$D503309F | (opt << (u32)8) | (opc2 << (u32)5);
            }
        }
        if (mn.equals(String.withCString("isb"))) { _hit = true; return (u32)$D5033FDF; }
        return (u32)0;
    }

    // ── NEON ─────────────────────────────────────────────────────────────
    //
    // Dispatched FIRST, because it shares mnemonics with the scalar handlers
    // (add, mul, the f-ops) and is told apart only by the operands being
    // vector registers. Fields OR'd in: Q<<30, size<<22, Rm<<16, Rn<<5, Rd.
    u32 encNeon(String* mn, Array* ops, u32 pc)
    {
        VRegRef* d = ops.count() >= (u32)1 ? parseVReg(opAt(ops, (u32)0)) : VRegRef.no();

        // dup Vd.T, Rn — splat a GP register across the lanes.
        if (d.ok() && mn.equals(String.withCString("dup")) && ops.count() == (u32)2
            && !opAt(ops, (u32)1).hasPrefix(String.withCString("v"))) {
            RegRef* n = parseReg(opAt(ops, (u32)1));
            if (!n.ok()) { fail(String.withCString("bad dup source")); return (u32)0; }
            _hit = true;
            return (u32)$0E000C00 | (d.q() << (u32)30) | (((u32)1 << d.size()) << (u32)16)
                 | (n.num() << (u32)5) | d.num();
        }

        if (d.ok() && ops.count() == (u32)3) {
            VRegRef* n = parseVReg(opAt(ops, (u32)1));
            VRegRef* m = parseVReg(opAt(ops, (u32)2));
            if (n.ok() && m.ok()) {
                u32 b = neonInt3(mn);
                if (b != (u32)0) {
                    _hit = true;
                    return b | (d.q() << (u32)30) | (d.size() << (u32)22)
                         | (m.num() << (u32)16) | (n.num() << (u32)5) | d.num();
                }
                b = neonLogic3(mn);       // no size field: 8b/16b arrangements only
                if (b != (u32)0) {
                    _hit = true;
                    return b | (d.q() << (u32)30) | (m.num() << (u32)16)
                         | (n.num() << (u32)5) | d.num();
                }
                b = neonFloat3(mn);       // one sz bit at 22: 0 for .2s/.4s, 1 for .2d
                if (b != (u32)0) {
                    _hit = true;
                    return b | (d.q() << (u32)30) | ((d.size() == (u32)3 ? (u32)1 : (u32)0) << (u32)22)
                         | (m.num() << (u32)16) | (n.num() << (u32)5) | d.num();
                }
                b = neonPerm(mn);
                if (b != (u32)0) {
                    _hit = true;
                    return b | (d.q() << (u32)30) | (d.size() << (u32)22)
                         | (m.num() << (u32)16) | (n.num() << (u32)5) | d.num();
                }
                b = neonWiden3(mn);
                if (b != (u32)0) {
                    if (n.size() != m.size() || n.q() != m.q()) {
                        fail(String.withCString("widening multiply sources disagree"));
                        return (u32)0;
                    }
                    // The suffix IS the half-selector; a mismatch would quietly
                    // encode the other half of the register.
                    bool hi = mn.hasSuffix(String.withCString("2"));
                    if ((n.q() == (u32)1) != hi) {
                        fail(String.withCString("widening multiply suffix does not match its sources"));
                        return (u32)0;
                    }
                    if (d.size() != n.size() + (u32)1) {
                        fail(String.withCString("widening multiply destination must be twice the source width"));
                        return (u32)0;
                    }
                    _hit = true;
                    return b | (n.q() << (u32)30) | (n.size() << (u32)22)
                         | (m.num() << (u32)16) | (n.num() << (u32)5) | d.num();
                }
            }
        }
        // ushr/sshr Vd.T, Vn.T, #shift
        if (d.ok() && ops.count() == (u32)3
            && opAt(ops, (u32)2).hasPrefix(String.withCString("#"))) {
            u32 bs = neonShrImm(mn);
            if (bs != (u32)0) {
                VRegRef* n = parseVReg(opAt(ops, (u32)1));
                if (!n.ok() || n.size() != d.size() || n.q() != d.q()) {
                    fail(String.withCString("shift-right arrangements disagree"));
                    return (u32)0;
                }
                U64* sh = parseImm(opAt(ops, (u32)2));
                if (!_immOk) { fail(String.withCString("bad shift amount")); return (u32)0; }
                u32 esize = (u32)8 << d.size();
                u32 amt = sh.lo();
                if (amt < (u32)1 || amt > esize) {
                    fail(String.withCString("shift-right amount out of range"));
                    return (u32)0;
                }
                _hit = true;
                return bs | (d.q() << (u32)30) | (((u32)2 * esize - amt) << (u32)16)
                     | (n.num() << (u32)5) | d.num();
            }
        }
        if (d.ok() && ops.count() == (u32)2) {
            VRegRef* n = parseVReg(opAt(ops, (u32)1));
            if (n.ok()) {
                u32 bp = neonPairLong(mn);
                if (bp != (u32)0) {
                    _hit = true;
                    return bp | (n.q() << (u32)30) | (n.size() << (u32)22)
                         | (n.num() << (u32)5) | d.num();
                }
                u32 b = neonMisc2i(mn);
                if (b != (u32)0) {
                    _hit = true;
                    return b | (d.q() << (u32)30) | (d.size() << (u32)22)
                         | (n.num() << (u32)5) | d.num();
                }
                b = neonMisc2f(mn);
                if (b != (u32)0) {
                    _hit = true;
                    return b | (d.q() << (u32)30) | ((d.size() == (u32)3 ? (u32)1 : (u32)0) << (u32)22)
                         | (n.num() << (u32)5) | d.num();
                }
            }
        }
        // ext Vd.16b, Vn.16b, Vm.16b, #imm4 — a byte extract across two regs.
        if (d.ok() && mn.equals(String.withCString("ext")) && ops.count() == (u32)4) {
            VRegRef* n = parseVReg(opAt(ops, (u32)1));
            VRegRef* m = parseVReg(opAt(ops, (u32)2));
            if (n.ok() && m.ok()) {
                U64* idx = parseImm(opAt(ops, (u32)3));
                _hit = true;
                return (u32)$2E000000 | (d.q() << (u32)30) | (m.num() << (u32)16)
                     | ((idx.lo() & (u32)$F) << (u32)11) | (n.num() << (u32)5) | d.num();
            }
        }
        // Across-lanes reduction: the destination is a SCALAR, the source a vector.
        if (!d.ok() && ops.count() == (u32)2) {
            u32 b = neonReduce(mn);
            VRegRef* n = parseVReg(opAt(ops, (u32)1));
            if (b != (u32)0 && n.ok()) {
                FRegRef* rd = parseFReg(opAt(ops, (u32)0));
                if (!rd.ok()) { fail(String.withCString("bad reduce destination")); return (u32)0; }
                _hit = true;
                return b | (n.q() << (u32)30) | (n.size() << (u32)22)
                     | (n.num() << (u32)5) | rd.num();
            }
        }
        // By-element: Vd.T, Vn.T, Vm.Ts[i]. H:L:M hold the lane — for .s the
        // index is L(21):H(11), for .d just H(11) — and Vm is four bits plus
        // M(20), so only v0-v15 can be the indexed operand.
        if (d.ok() && ops.count() == (u32)3) {
            u32 b = neonElem(mn);
            VRegRef* n = parseVReg(opAt(ops, (u32)1));
            VRegRef* e = parseVElem(opAt(ops, (u32)2));
            if (b != (u32)0 && n.ok() && e.ok()) {
                u32 L; u32 H; u32 sz;
                if (e.size() == (u32)2) { sz = (u32)0; L = e.idx() & (u32)1; H = (e.idx() >> (u32)1) & (u32)1; }
                else                    { sz = (u32)1; L = (u32)0; H = e.idx() & (u32)1; }
                u32 M = (e.num() >> (u32)4) & (u32)1;
                _hit = true;
                return b | (d.q() << (u32)30) | (sz << (u32)22) | (L << (u32)21) | (M << (u32)20)
                     | ((e.num() & (u32)$F) << (u32)16) | (H << (u32)11)
                     | (n.num() << (u32)5) | d.num();
            }
        }
        // dup Vd.T, Vn.Ts[i] — splat one lane across all of them.
        if (d.ok() && mn.equals(String.withCString("dup")) && ops.count() == (u32)2) {
            VRegRef* e = parseVElem(opAt(ops, (u32)1));
            if (e.ok()) {
                u32 imm5 = (e.idx() << (e.size() + (u32)1)) | ((u32)1 << e.size());
                _hit = true;
                return (u32)$0E000400 | (d.q() << (u32)30) | (imm5 << (u32)16)
                     | (e.num() << (u32)5) | d.num();
            }
        }
        // ld1/st1 { Vt.T }, [Xn] — the single-register, no-offset form. The
        // brace list arrives as ONE operand, because splitOperands does not
        // break on the inner comma of a single-register list.
        if ((mn.equals(String.withCString("ld1")) || mn.equals(String.withCString("st1")))
            && ops.count() == (u32)2 && opAt(ops, (u32)0).hasPrefix(String.withCString("{"))) {
            String* inner = stripBraces(opAt(ops, (u32)0));
            VRegRef* t = parseVReg(inner);
            String* mem = opAt(ops, (u32)1);
            if (t.ok() && mem.hasPrefix(String.withCString("["))
                && mem.hasSuffix(String.withCString("]"))) {
                RegRef* bn = parseReg(mem.substringBytes((u32)1, mem.byteLength() - (u32)2).trimmed());
                if (!bn.ok()) { fail(String.withCString("bad ld1/st1 base")); return (u32)0; }
                u32 base = mn.equals(String.withCString("ld1")) ? (u32)$0C407000 : (u32)$0C007000;
                _hit = true;
                return base | (t.q() << (u32)30) | (t.size() << (u32)10)
                     | (bn.num() << (u32)5) | t.num();
            }
        }
        return (u32)0;
    }

    static String* stripBraces(String* s)
    {
        String* out = new String();
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1) {
            u8 c = s.byteAt(i);
            if (c == (u8)'{' || c == (u8)'}') continue;
            out.appendByte(c);
        }
        return out.trimmed();
    }

    // Zero means "not in this table" — none of the real base opcodes is zero.
    static u32 neonInt3(String* m)
    {
        if (m.equals(String.withCString("add")))  return (u32)$0E208400;
        if (m.equals(String.withCString("sub")))  return (u32)$2E208400;
        if (m.equals(String.withCString("mul")))  return (u32)$0E209C00;
        if (m.equals(String.withCString("mla")))  return (u32)$0E209400;
        if (m.equals(String.withCString("mls")))  return (u32)$2E209400;
        if (m.equals(String.withCString("smax"))) return (u32)$0E206400;
        if (m.equals(String.withCString("smin"))) return (u32)$0E206C00;
        if (m.equals(String.withCString("umax"))) return (u32)$2E206400;
        if (m.equals(String.withCString("umin"))) return (u32)$2E206C00;
        if (m.equals(String.withCString("cmeq"))) return (u32)$2E208C00;
        if (m.equals(String.withCString("cmgt"))) return (u32)$0E203400;
        if (m.equals(String.withCString("cmge"))) return (u32)$0E203C00;
        if (m.equals(String.withCString("cmhi"))) return (u32)$2E203400;
        if (m.equals(String.withCString("cmhs"))) return (u32)$2E203C00;
        if (m.equals(String.withCString("sshl"))) return (u32)$0E204400;
        if (m.equals(String.withCString("ushl"))) return (u32)$2E204400;
        if (m.equals(String.withCString("saba"))) return (u32)$0E207C00;
        if (m.equals(String.withCString("uaba"))) return (u32)$2E207C00;
        if (m.equals(String.withCString("sabd"))) return (u32)$0E207400;
        if (m.equals(String.withCString("uabd"))) return (u32)$2E207400;
        return (u32)0;
    }

    static u32 neonLogic3(String* m)
    {
        if (m.equals(String.withCString("and"))) return (u32)$0E201C00;
        if (m.equals(String.withCString("bic"))) return (u32)$0E601C00;
        if (m.equals(String.withCString("orr"))) return (u32)$0EA01C00;
        if (m.equals(String.withCString("orn"))) return (u32)$0EE01C00;
        if (m.equals(String.withCString("eor"))) return (u32)$2E201C00;
        return (u32)0;
    }

    static u32 neonFloat3(String* m)
    {
        if (m.equals(String.withCString("fadd")))  return (u32)$0E20D400;
        if (m.equals(String.withCString("fsub")))  return (u32)$0EA0D400;
        if (m.equals(String.withCString("fmul")))  return (u32)$2E20DC00;
        if (m.equals(String.withCString("fdiv")))  return (u32)$2E20FC00;
        if (m.equals(String.withCString("fmla")))  return (u32)$0E20CC00;
        if (m.equals(String.withCString("fmls")))  return (u32)$0EA0CC00;
        if (m.equals(String.withCString("fmax")))  return (u32)$0E20F400;
        if (m.equals(String.withCString("fmin")))  return (u32)$0EA0F400;
        if (m.equals(String.withCString("fcmeq"))) return (u32)$0E20E400;
        if (m.equals(String.withCString("fcmgt"))) return (u32)$2EA0E400;
        return (u32)0;
    }

    static u32 neonMisc2i(String* m)
    {
        if (m.equals(String.withCString("neg")))   return (u32)$2E20B800;
        if (m.equals(String.withCString("abs")))   return (u32)$0E20B800;
        if (m.equals(String.withCString("not")))   return (u32)$2E205800;
        if (m.equals(String.withCString("mvn")))   return (u32)$2E205800;
        if (m.equals(String.withCString("cnt")))   return (u32)$0E205800;
        if (m.equals(String.withCString("rev64"))) return (u32)$0E200800;
        if (m.equals(String.withCString("rev16"))) return (u32)$0E201800;
        if (m.equals(String.withCString("rev32"))) return (u32)$2E200800;
        return (u32)0;
    }

    static u32 neonMisc2f(String* m)
    {
        if (m.equals(String.withCString("fneg")))   return (u32)$2EA0F800;
        if (m.equals(String.withCString("fabs")))   return (u32)$0EA0F800;
        if (m.equals(String.withCString("scvtf")))  return (u32)$0E21D800;
        if (m.equals(String.withCString("ucvtf")))  return (u32)$2E21D800;
        if (m.equals(String.withCString("fcvtzs"))) return (u32)$0EA1B800;
        if (m.equals(String.withCString("fcvtzu"))) return (u32)$2EA1B800;
        if (m.equals(String.withCString("frintz"))) return (u32)$0EA19800;
        return (u32)0;
    }

    static u32 neonReduce(String* m)
    {
        if (m.equals(String.withCString("addv")))   return (u32)$0E31B800;
        if (m.equals(String.withCString("saddlv"))) return (u32)$0E303800;
        if (m.equals(String.withCString("uaddlv"))) return (u32)$2E303800;
        if (m.equals(String.withCString("smaxv")))  return (u32)$0E30A800;
        if (m.equals(String.withCString("sminv")))  return (u32)$0E31A800;
        if (m.equals(String.withCString("umaxv")))  return (u32)$2E30A800;
        if (m.equals(String.withCString("uminv")))  return (u32)$2E31A800;
        return (u32)0;
    }

    // Pairwise add long: adds ADJACENT lanes of Vn and widens, so the
    // destination arrangement is HALF the lane count at twice the width
    // (`uaddlp v0.4s, v1.8h`). Both Q and size come from the SOURCE, unlike
    // every other 2-register form here — which is why it gets its own case.
    // The vectoriser's widening-sum reduction emits it (bug 028).
    static u32 neonPairLong(String* m)
    {
        if (m.equals(String.withCString("saddlp"))) return (u32)$0E202800;
        if (m.equals(String.withCString("uaddlp"))) return (u32)$2E202800;
        return (u32)0;
    }

    // Widening 3-different: multiplies the lanes of Vn and Vm into a
    // destination of HALF the lane count at twice the width
    // (`umull v0.2d, v1.2s, v2.2s`). The `2` suffix is the same instruction
    // reading the HIGH half of its sources, which is what Q selects — so Q and
    // size both come from the SOURCE, as they do for neonPairLong.
    // The vectoriser's VMulHi emits the pair to build a 32x32 high half.
    static u32 neonWiden3(String* m)
    {
        if (m.equals(String.withCString("smull")))  return (u32)$0E20C000;
        if (m.equals(String.withCString("umull")))  return (u32)$2E20C000;
        if (m.equals(String.withCString("smull2"))) return (u32)$0E20C000;
        if (m.equals(String.withCString("umull2"))) return (u32)$2E20C000;
        return (u32)0;
    }

    // Shift right by immediate. immh:immb holds (2*esize - shift), so the
    // encoded field GROWS as the shift shrinks and a shift of 0 is not
    // encodable at all — callers emit a move instead.
    static u32 neonShrImm(String* m)
    {
        if (m.equals(String.withCString("ushr"))) return (u32)$2F000400;
        if (m.equals(String.withCString("sshr"))) return (u32)$0F000400;
        return (u32)0;
    }

    static u32 neonPerm(String* m)
    {
        if (m.equals(String.withCString("zip1"))) return (u32)$0E003800;
        if (m.equals(String.withCString("zip2"))) return (u32)$0E007800;
        if (m.equals(String.withCString("uzp1"))) return (u32)$0E001800;
        if (m.equals(String.withCString("uzp2"))) return (u32)$0E005800;
        if (m.equals(String.withCString("trn1"))) return (u32)$0E002800;
        if (m.equals(String.withCString("trn2"))) return (u32)$0E006800;
        return (u32)0;
    }

    static u32 neonElem(String* m)
    {
        if (m.equals(String.withCString("fmla"))) return (u32)$0F801000;
        if (m.equals(String.withCString("fmls"))) return (u32)$0F805000;
        if (m.equals(String.withCString("fmul"))) return (u32)$0F809000;
        if (m.equals(String.withCString("mul")))  return (u32)$0F808000;
        if (m.equals(String.withCString("mla")))  return (u32)$2F800000;
        if (m.equals(String.withCString("mls")))  return (u32)$6F804000;
        return (u32)0;
    }

    // ── mov / movz / movk / movn ─────────────────────────────────────────
    u32 encMoves(String* mn, Array* ops, u32 pc)
    {
        if (mn.equals(String.withCString("mov"))) {
            if (ops.count() < (u32)2) { fail(String.withCString("mov needs 2 operands")); return (u32)0; }
            RegRef* d = parseReg(opAt(ops, (u32)0));
            if (!d.ok()) { fail(String.withCString("bad mov destination")); return (u32)0; }
            if (opAt(ops, (u32)1).hasPrefix(String.withCString("#"))) {
                U64* imm = parseImm(opAt(ops, (u32)1));
                if (!_immOk) { fail(String.withCString("bad mov immediate")); return (u32)0; }
                _hit = true;
                return encMovImm(d, imm);
            }
            RegRef* m = parseReg(opAt(ops, (u32)1));
            if (!m.ok()) { fail(String.withCString("bad mov source")); return (u32)0; }
            _hit = true;
            // Anything touching SP becomes `add Rd, Rm, #0`: the orr-with-zero
            // form cannot name the stack pointer.
            if (d.isSP() || m.isSP())
                return (d.is64() ? (u32)$91000000 : (u32)$11000000) | (m.num() << (u32)5) | d.num();
            return (d.is64() ? (u32)$AA0003E0 : (u32)$2A0003E0) | (m.num() << (u32)16) | d.num();
        }
        if (mn.equals(String.withCString("movz")) || mn.equals(String.withCString("movk"))
         || mn.equals(String.withCString("movn"))) {
            if (ops.count() < (u32)2) { fail(String.withCString("movz/movk needs 2 operands")); return (u32)0; }
            RegRef* d = parseReg(opAt(ops, (u32)0));
            if (!d.ok()) { fail(String.withCString("bad movz destination")); return (u32)0; }
            U64* imm = parseImm(opAt(ops, (u32)1));
            if (!_immOk) { fail(String.withCString("bad movz immediate")); return (u32)0; }
            u32 hw = (u32)0;
            if (ops.count() >= (u32)3) {
                String* sh = opAt(ops, (u32)2);
                u32 h = sh.byteIndexOf(String.withCString("#"));
                if (h != (u32)$FFFF_FFFF) {
                    U64* sv = parseImm(sh.substringFromByte(h));
                    if (_immOk) hw = sv.lo() / (u32)16;
                }
            }
            u32 base = mn.equals(String.withCString("movk")) ? (d.is64() ? (u32)$F2800000 : (u32)$72800000)
                     : mn.equals(String.withCString("movn")) ? (d.is64() ? (u32)$92800000 : (u32)$12800000)
                                                             : (d.is64() ? (u32)$D2800000 : (u32)$52800000);
            _hit = true;
            return base | (hw << (u32)21) | ((imm.lo() & (u32)$FFFF) << (u32)5) | d.num();
        }
        return (u32)0;
    }

    // One instruction only — clang spells wider constants as an explicit
    // movz/movk pair, so this never has to invent a second word. MOVZ first,
    // then MOVN of the complement, then ORR of a bitmask.
    u32 encMovImm(RegRef* d, U64* imm)
    {
        u32 nsh = d.is64() ? (u32)4 : (u32)2;
        U64* u = d.is64() ? imm : U64.with((u32)0, imm.lo());
        for (u32 sft = (u32)0; sft < nsh; sft = sft + (u32)1) {
            U64* mask = U64.fromU32((u32)$FFFF).shl((u32)16 * sft);
            if (u.anded(mask.notted()).isZero())
                return (d.is64() ? (u32)$D2800000 : (u32)$52800000) | (sft << (u32)21)
                     | ((u.shr((u32)16 * sft).lo() & (u32)$FFFF) << (u32)5) | d.num();
        }
        U64* nv = u.notted();
        if (!d.is64()) nv = U64.with((u32)0, nv.lo());
        for (u32 sft = (u32)0; sft < nsh; sft = sft + (u32)1) {
            U64* mask = U64.fromU32((u32)$FFFF).shl((u32)16 * sft);
            if (nv.anded(mask.notted()).isZero())
                return (d.is64() ? (u32)$92800000 : (u32)$12800000) | (sft << (u32)21)
                     | ((nv.shr((u32)16 * sft).lo() & (u32)$FFFF) << (u32)5) | d.num();
        }
        u32 bm = encodeLogImm(u, d.is64() ? (u32)64 : (u32)32);
        if (bm != (u32)$FFFF_FFFF)
            return (d.is64() ? (u32)$B2000000 : (u32)$32000000) | (bm << (u32)10)
                 | ((u32)31 << (u32)5) | d.num();
        fail(String.withCString("mov immediate needs more than one instruction"));
        _hit = false;
        return (u32)0;
    }

    // ── Scalar floating point ────────────────────────────────────────────
    //
    // Bit 22 ("ty") selects single from double throughout.
    u32 encFloat(String* mn, Array* ops, u32 pc)
    {
        bool fLike = mn.hasPrefix(String.withCString("f"))
                  || mn.equals(String.withCString("scvtf"))
                  || mn.equals(String.withCString("ucvtf"));
        if (!fLike) return (u32)0;

        FRegRef* d = parseFReg(opAt(ops, (u32)0));

        // The four 3-source FP ops share one encoding group; o1 (bit 21) and
        // o0 (bit 15) select which: fmadd 00, fmsub 01, fnmadd 10, fnmsub 11.
        if ((mn.equals(String.withCString("fmadd")) || mn.equals(String.withCString("fmsub"))
             || mn.equals(String.withCString("fnmadd")) || mn.equals(String.withCString("fnmsub")))
            && ops.count() == (u32)4 && d.ok()) {
            FRegRef* n = parseFReg(opAt(ops, (u32)1));
            FRegRef* m = parseFReg(opAt(ops, (u32)2));
            FRegRef* a = parseFReg(opAt(ops, (u32)3));
            u32 ty = d.sz() == (u32)3 ? (u32)$00400000 : (u32)0;
            u32 base = (u32)$1F000000;
            if (mn.equals(String.withCString("fmsub")))  base = (u32)$1F008000;
            if (mn.equals(String.withCString("fnmadd"))) base = (u32)$1F200000;
            if (mn.equals(String.withCString("fnmsub"))) base = (u32)$1F208000;
            _hit = true;
            return base | ty | (m.num() << (u32)16) | (a.num() << (u32)10)
                 | (n.num() << (u32)5) | d.num();
        }
        u32 f3 = fpArith3(mn);
        if (f3 != (u32)0 && ops.count() == (u32)3 && d.ok()) {
            FRegRef* n = parseFReg(opAt(ops, (u32)1));
            FRegRef* m = parseFReg(opAt(ops, (u32)2));
            u32 ty = d.sz() == (u32)3 ? (u32)$00400000 : (u32)0;
            _hit = true;
            return f3 | ty | (m.num() << (u32)16) | (n.num() << (u32)5) | d.num();
        }
        // fcsel — the FP conditional select. The integer csel cannot take an FP
        // destination, so a float `?:` or an if-converted `if (x < 0) x = -x`
        // needs this one.
        if (mn.equals(String.withCString("fcsel")) && ops.count() == (u32)4 && d.ok()) {
            FRegRef* n = parseFReg(opAt(ops, (u32)1));
            FRegRef* m = parseFReg(opAt(ops, (u32)2));
            i32 cc = condCode(opAt(ops, (u32)3));
            if (cc < (i32)0) { fail(String.withCString("bad fcsel condition")); return (u32)0; }
            u32 ty = d.sz() == (u32)3 ? (u32)$00400000 : (u32)0;
            _hit = true;
            return (u32)$1E200C00 | ty | (m.num() << (u32)16) | ((u32)cc << (u32)12)
                 | (n.num() << (u32)5) | d.num();
        }
        if (mn.equals(String.withCString("fneg")) || mn.equals(String.withCString("fsqrt"))) {
            FRegRef* n = parseFReg(opAt(ops, (u32)1));
            u32 ty = d.sz() == (u32)3 ? (u32)$00400000 : (u32)0;
            u32 base = mn.equals(String.withCString("fneg")) ? (u32)$1E214000 : (u32)$1E21C000;
            _hit = true;
            return base | ty | (n.num() << (u32)5) | d.num();
        }
        if (mn.equals(String.withCString("fcmp"))) {
            FRegRef* n = parseFReg(opAt(ops, (u32)0));
            FRegRef* m = parseFReg(opAt(ops, (u32)1));
            u32 ty = n.sz() == (u32)3 ? (u32)$00400000 : (u32)0;
            _hit = true;
            return (u32)$1E202000 | ty | (m.num() << (u32)16) | (n.num() << (u32)5);
        }
        if (mn.equals(String.withCString("fcvt"))) {
            FRegRef* n = parseFReg(opAt(ops, (u32)1));
            u32 base = (u32)0;
            if (n.sz() == (u32)2 && d.sz() == (u32)3) base = (u32)$1E22C000;
            else if (n.sz() == (u32)3 && d.sz() == (u32)2) base = (u32)$1E624000;
            if (base == (u32)0) { fail(String.withCString("unsupported fcvt")); return (u32)0; }
            _hit = true;
            return base | (n.num() << (u32)5) | d.num();
        }
        if (mn.equals(String.withCString("fmov"))) return encFmov(ops);

        // The SIMD-scalar round-trip forms keep an integer in an FP register:
        // scvtf/ucvtf take one as their SOURCE, fcvtzs/fcvtzu produce one as
        // their DESTINATION, and that operand being d/s rather than a GPR is
        // what selects this encoding over the GPR one below.
        bool toFP = mn.equals(String.withCString("scvtf")) || mn.equals(String.withCString("ucvtf"));
        bool isFcvtz = mn.equals(String.withCString("fcvtzs")) || mn.equals(String.withCString("fcvtzu"));
        if (toFP || isFcvtz) {
            String* discr = toFP ? opAt(ops, (u32)1) : opAt(ops, (u32)0);
            bool discrIsFP = discr.byteLength() > (u32)0
                && (discr.byteAt((u32)0) == (u8)'d' || discr.byteAt((u32)0) == (u8)'s');
            if (discrIsFP) {
                FRegRef* n = parseFReg(opAt(ops, (u32)1));
                u32 dbl = d.sz() == (u32)3 ? (u32)$00400000 : (u32)0;
                u32 base;
                if (mn.equals(String.withCString("scvtf")))       base = (u32)$5E21D800 | dbl;
                else if (mn.equals(String.withCString("ucvtf")))  base = (u32)$7E21D800 | dbl;
                else if (mn.equals(String.withCString("fcvtzs"))) base = (u32)$5EA1B800 | dbl;
                else                                              base = (u32)$7EA1B800 | dbl;
                _hit = true;
                return base | (n.num() << (u32)5) | d.num();
            }
        }
        if (toFP) {
            RegRef* n = parseReg(opAt(ops, (u32)1));
            if (ops.count() >= (u32)3 && opAt(ops, (u32)2).hasPrefix(String.withCString("#"))) {
                U64* fb = parseImm(opAt(ops, (u32)2));
                u32 base = mn.equals(String.withCString("scvtf")) ? (u32)$1E020000 : (u32)$1E030000;
                u32 sf = n.is64() ? (u32)$80000000 : (u32)0;
                u32 ty = d.sz() == (u32)3 ? (u32)$00400000 : (u32)0;
                u32 scale = (u32)64 - fb.lo();
                _hit = true;
                return base | sf | ty | (scale << (u32)10) | (n.num() << (u32)5) | d.num();
            }
            u32 base = mn.equals(String.withCString("scvtf"))
                     ? (d.sz() == (u32)3 ? (u32)$1E620000 : (u32)$1E220000)
                     : (d.sz() == (u32)3 ? (u32)$1E630000 : (u32)$1E230000);
            u32 sf = n.is64() ? (u32)$80000000 : (u32)0;
            _hit = true;
            return base | sf | (n.num() << (u32)5) | d.num();
        }
        if (isFcvtz) {
            RegRef* rd = parseReg(opAt(ops, (u32)0));
            FRegRef* n = parseFReg(opAt(ops, (u32)1));
            u32 base = mn.equals(String.withCString("fcvtzs"))
                     ? (n.sz() == (u32)3 ? (u32)$1E780000 : (u32)$1E380000)
                     : (n.sz() == (u32)3 ? (u32)$1E790000 : (u32)$1E390000);
            u32 sf = rd.is64() ? (u32)$80000000 : (u32)0;
            _hit = true;
            return base | sf | (n.num() << (u32)5) | rd.num();
        }
        return (u32)0;
    }

    static u32 fpArith3(String* m)
    {
        if (m.equals(String.withCString("fadd"))) return (u32)$1E202800;
        if (m.equals(String.withCString("fsub"))) return (u32)$1E203800;
        if (m.equals(String.withCString("fmul"))) return (u32)$1E200800;
        if (m.equals(String.withCString("fdiv"))) return (u32)$1E201800;
        return (u32)0;
    }

    u32 encFmov(Array* ops)
    {
        FRegRef* d = parseFReg(opAt(ops, (u32)0));
        if (ops.count() >= (u32)2 && d.ok()
            && opAt(ops, (u32)1).hasPrefix(String.withCString("#"))) {
            _hit = true;
            return encFmovImm(d, opAt(ops, (u32)1).substringFromByte((u32)1));
        }
        FRegRef* n = parseFReg(opAt(ops, (u32)1));
        if (d.ok() && n.ok()) {
            u32 ty = d.sz() == (u32)3 ? (u32)$00400000 : (u32)0;
            _hit = true;
            return (u32)$1E204000 | ty | (n.num() << (u32)5) | d.num();
        }
        RegRef* gn = parseReg(opAt(ops, (u32)1));
        if (d.ok() && gn.ok()) {                        // GPR -> FP
            u32 base = d.sz() == (u32)3 ? (u32)$9E670000 : (u32)$1E270000;
            _hit = true;
            return base | (gn.num() << (u32)5) | d.num();
        }
        RegRef* gd = parseReg(opAt(ops, (u32)0));
        if (gd.ok() && n.ok()) {                        // FP -> GPR
            u32 base = n.sz() == (u32)3 ? (u32)$9E660000 : (u32)$1E260000;
            _hit = true;
            return base | (n.num() << (u32)5) | gd.num();
        }
        fail(String.withCString("unsupported fmov"));
        return (u32)0;
    }

    // The 8-bit FP immediate is found by BRUTE FORCE — all 256 patterns are
    // expanded and compared. There is a closed form, but the search is 256
    // iterations at assembly time and cannot get the rounding subtly wrong.
    // The comparison is on the decimal SPELLING, because reconstructing a
    // double from text is exactly the problem BigNat exists to solve, and an
    // 8-bit immediate has only 256 possible spellings to match against.
    u32 encFmovImm(FRegRef* d, String* text)
    {
        bool dbl = d.sz() == (u32)3;
        String* want = normaliseFpText(text);
        for (u32 i = (u32)0; i < (u32)256; i = i + (u32)1) {
            if (!normaliseFpText(vfpExpandText(i)).equals(want)) continue;
            return (dbl ? (u32)$1E601000 : (u32)$1E201000) | (i << (u32)13) | d.num();
        }
        fail(String.withCString("fmov immediate is not an 8-bit fp immediate"));
        _hit = false;
        return (u32)0;
    }

    // VFPExpandImm renders exactly: a sign, a 4-bit mantissa over 16, and a
    // power of two — so the value is +/- (16+m)/16 * 2^e, a dyadic rational
    // whose decimal expansion terminates. The single and double forms describe
    // the SAME 256 values, so the width does not enter here.
    //
    //   b6 = 1  ->  biased exponent 124+lowExp, so e = lowExp - 3
    //   b6 = 0  ->  biased exponent 128+lowExp, so e = lowExp + 1
    static String* vfpExpandText(u32 i)
    {
        u32 sign = (i >> (u32)7) & (u32)1;
        u32 b6 = (i >> (u32)6) & (u32)1;
        u32 lowExp = (i >> (u32)4) & (u32)3;
        u32 mant = i & (u32)$F;
        i32 e = b6 != (u32)0 ? ((i32)lowExp - (i32)3) : ((i32)lowExp + (i32)1);
        return fpDecimalText(sign != (u32)0, (u32)16 + mant, e);
    }

    // (num/16) * 2^e as an exact decimal string. e is in [-4, 4] here, so the
    // result never needs more than a handful of fractional digits.
    static String* fpDecimalText(bool neg, u32 num, i32 e)
    {
        // value = num * 2^e / 16 = num * 2^(e-4).
        i32 shift = e - (i32)4;
        u32 intPart;
        u32 fracNum;
        u32 fracDen;
        if (shift >= (i32)0) {
            intPart = num << (u32)shift;
            fracNum = (u32)0; fracDen = (u32)1;
        } else {
            u32 den = (u32)1 << (u32)(-shift);
            intPart = num / den;
            fracNum = num - intPart * den;
            fracDen = den;
        }
        String* o = new String();
        if (neg) o.appendCString("-");
        o.appendFormat("%lu", intPart);
        if (fracNum != (u32)0) {
            o.appendCString(".");
            // Long division, at most as many digits as the denominator has bits.
            for (u32 k = (u32)0; k < (u32)12 && fracNum != (u32)0; k = k + (u32)1) {
                fracNum = fracNum * (u32)10;
                u32 digit = fracNum / fracDen;
                fracNum = fracNum - digit * fracDen;
                o.appendByte((u8)((u32)'0' + digit));
            }
        }
        return o;
    }

    // Drop a leading `+`, a trailing `.0`, and any trailing zeros after a
    // decimal point, so `2.0`, `2.` and `2` all compare equal.
    static String* normaliseFpText(String* t0)
    {
        String* t = t0.trimmed();
        if (t.hasPrefix(String.withCString("+"))) t = t.substringFromByte((u32)1);
        if (t.byteIndexOf(String.withCString(".")) == (u32)$FFFF_FFFF) return t;
        u32 end = t.byteLength();
        while (end > (u32)0 && t.byteAt(end - (u32)1) == (u8)'0') end = end - (u32)1;
        if (end > (u32)0 && t.byteAt(end - (u32)1) == (u8)'.') end = end - (u32)1;
        return t.substringBytes((u32)0, end);
    }

    // ── add / sub / cmp / neg, and the logical group ─────────────────────
    u32 encAddSubLogic(String* mn, Array* ops, u32 pc)
    {
        // add Xd, Xn, sym@PAGEOFF — the second half of an adrp pair. The imm12
        // is left at zero and the linker fills it in.
        if (mn.equals(String.withCString("add")) && ops.count() >= (u32)3
            && opAt(ops, (u32)2).byteIndexOf(String.withCString("@")) != (u32)$FFFF_FFFF) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            String* sym = opAt(ops, (u32)2);
            String* bare = sym.substringBytes((u32)0, sym.byteIndexOf(String.withCString("@")));
            addFixup(pc, (u32)FIXUP_PAGEOFF12, bare, (u32)0);
            _hit = true;
            return (d.is64() ? (u32)$91000000 : (u32)$11000000) | (n.num() << (u32)5) | d.num();
        }
        u32 immBase = addSubImmBase(mn);
        bool isCmp = mn.equals(String.withCString("cmp")) || mn.equals(String.withCString("cmn"));
        bool isNeg = mn.equals(String.withCString("neg"));
        if (immBase != (u32)0 || isCmp || isNeg) {
            String* key = isCmp ? (mn.equals(String.withCString("cmp")) ? String.withCString("subs")
                                                                       : String.withCString("adds"))
                        : isNeg ? String.withCString("sub") : mn;
            // Normalise to an explicit destination: cmp becomes subs to the
            // zero register, neg becomes sub FROM it.
            Array* o = new Array();
            if (isCmp) {
                RegRef* n0 = parseReg(opAt(ops, (u32)0));
                o.add((Object*)(n0.is64() ? String.withCString("xzr") : String.withCString("wzr")));
                for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1) o.add(ops.get(i));
            } else if (isNeg) {
                o.add(ops.get((u32)0));
                o.add((Object*)(opAt(ops, (u32)0).hasPrefix(String.withCString("x"))
                                ? String.withCString("xzr") : String.withCString("wzr")));
                for (u32 i = (u32)1; i < ops.count(); i = i + (u32)1) o.add(ops.get(i));
            } else {
                for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1) o.add(ops.get(i));
            }
            // Immediate vs register is decided by operand 2, NOT the last one.
            // The shifted spelling `add Rd, Rn, #imm, lsl #12` ends in a shift,
            // so testing the last operand sent it down the REGISTER path, which
            // then tried to parse `#1` as a register ("bad rm #1"). That form is
            // valid AArch64 and emitSpAddr emits it for any frame-slot address
            // at a 4096-aligned offset. A register shift (`add x0, x1, x2,
            // lsl #3`) still has a register at operand 2 and is unaffected.
            bool lastImm = o.count() > (u32)2
                && ((String*)o.get((u32)2)).hasPrefix(String.withCString("#"));
            if (lastImm && !isNeg) { _hit = true; return encAddSubImm(addSubImmBase(key), o); }
            _hit = true;
            return encAddSubReg(addSubRegBase(key), o);
        }
        // `tst Rn, op` IS `ands ZR, Rn, op`. Rewriting it into the alias it
        // stands for reuses the bitmask-immediate encoder below; a second copy
        // of that is the kind that drifts. Normalised into LOCALS rather than
        // by reassigning the parameters — same shape as the cmp/neg rewrite
        // above, and reassigning a borrowed parameter here segfaulted.
        String* lmn = mn;
        Array* lops = ops;
        if (mn.equals(String.withCString("tst")) && ops.count() >= (u32)2) {
            bool wide = opAt(ops, (u32)0).hasPrefix(String.withCString("x"))
                     || opAt(ops, (u32)0).hasPrefix(String.withCString("X"));
            Array* a2 = new Array();
            String* zr = String.withCString("wzr");
            if (wide) zr = String.withCString("xzr");
            a2.add((Object*)zr);
            for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1) a2.add(ops.get(i));
            lmn = String.withCString("ands");
            lops = a2;
        }
        u32 logBase = logRegBase(lmn);
        if (logBase != (u32)0) {
            if (lops.count() < (u32)3) { fail(String.withCString("logical op needs 3 operands")); return (u32)0; }
            RegRef* d = parseReg(opAt(lops, (u32)0));
            RegRef* n = parseReg(opAt(lops, (u32)1));
            if (!d.ok() || !n.ok()) { fail(String.withCString("bad logical register")); return (u32)0; }
            u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
            if (opAt(lops, (u32)2).hasPrefix(String.withCString("#"))) {
                U64* v = parseImm(opAt(lops, (u32)2));
                if (!_immOk) { fail(String.withCString("bad logical immediate")); return (u32)0; }
                u32 bm = encodeLogImm(v, d.is64() ? (u32)64 : (u32)32);
                if (bm == (u32)$FFFF_FFFF) { fail(String.withCString("value is not a valid bitmask immediate")); return (u32)0; }
                _hit = true;
                return logImmBase(lmn) | sf | (bm << (u32)10) | (n.num() << (u32)5) | d.num();
            }
            RegRef* m = parseReg(opAt(lops, (u32)2));
            if (!m.ok()) { fail(String.withCString("bad logical register")); return (u32)0; }
            u32 shTy = (u32)0; u32 shAmt = (u32)0;
            if (lops.count() >= (u32)4) {                  // `, <lsl|lsr|asr|ror> #imm`
                String* sw = opAt(lops, (u32)3);
                u32 hash = (u32)$FFFF_FFFF;
                for (u32 i = (u32)0; i < sw.byteLength(); i = i + (u32)1)
                    if (sw.byteAt(i) == (u8)'#') { hash = i; break; }
                if (hash == (u32)$FFFF_FFFF) { fail(String.withCString("bad logical shift")); return (u32)0; }
                String* kind = sw.substringBytes((u32)0, hash).trimmed();
                if (kind.equals(String.withCString("lsl"))) shTy = (u32)0;
                else if (kind.equals(String.withCString("lsr"))) shTy = (u32)1;
                else if (kind.equals(String.withCString("asr"))) shTy = (u32)2;
                else if (kind.equals(String.withCString("ror"))) shTy = (u32)3;
                else { fail(String.withCString("bad logical shift")); return (u32)0; }
                U64* av = parseImm(sw.substringFromByte(hash));
                if (!_immOk) { fail(String.withCString("bad logical shift amount")); return (u32)0; }
                shAmt = av.lo() & (d.is64() ? (u32)63 : (u32)31);
            }
            _hit = true;
            return logBase | sf | (shTy << (u32)22) | (m.num() << (u32)16)
                 | (shAmt << (u32)10) | (n.num() << (u32)5) | d.num();
        }
        if (mn.equals(String.withCString("mvn"))) {          // orn Rd, ZR, Rm
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* m = parseReg(opAt(ops, (u32)1));
            u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
            _hit = true;
            return (u32)$2A200000 | sf | (m.num() << (u32)16) | ((u32)31 << (u32)5) | d.num();
        }
        return (u32)0;
    }

    static u32 addSubImmBase(String* m)
    {
        if (m.equals(String.withCString("add")))  return (u32)$11000000;
        if (m.equals(String.withCString("sub")))  return (u32)$51000000;
        if (m.equals(String.withCString("adds"))) return (u32)$31000000;
        if (m.equals(String.withCString("subs"))) return (u32)$71000000;
        return (u32)0;
    }

    static u32 addSubRegBase(String* m)
    {
        if (m.equals(String.withCString("add")))  return (u32)$0B000000;
        if (m.equals(String.withCString("sub")))  return (u32)$4B000000;
        if (m.equals(String.withCString("adds"))) return (u32)$2B000000;
        if (m.equals(String.withCString("subs"))) return (u32)$6B000000;
        return (u32)0;
    }

    // The N-bit forms — "op with the inverted second operand" — sit at
    // +0x200000 from their plain siblings. clang emits `bic Wd,Wn,Wm,asr #31`
    // for a signed-max idiom, which is how they reach this assembler.
    static u32 logRegBase(String* m)
    {
        if (m.equals(String.withCString("and")))  return (u32)$0A000000;
        if (m.equals(String.withCString("orr")))  return (u32)$2A000000;
        if (m.equals(String.withCString("eor")))  return (u32)$4A000000;
        if (m.equals(String.withCString("ands"))) return (u32)$6A000000;
        if (m.equals(String.withCString("bic")))  return (u32)$0A200000;
        if (m.equals(String.withCString("orn")))  return (u32)$2A200000;
        if (m.equals(String.withCString("eon")))  return (u32)$4A200000;
        if (m.equals(String.withCString("bics"))) return (u32)$6A200000;
        return (u32)0;
    }

    static u32 logImmBase(String* m)
    {
        if (m.equals(String.withCString("and")))  return (u32)$12000000;
        if (m.equals(String.withCString("orr")))  return (u32)$32000000;
        if (m.equals(String.withCString("eor")))  return (u32)$52000000;
        if (m.equals(String.withCString("ands"))) return (u32)$72000000;
        return (u32)0;
    }

    // The immediate form takes 12 bits, optionally shifted left by 12 — so a
    // value that is a multiple of 4096 still fits.
    // The `#N` of a `lsl #N` modifier, as a string parseImm can read.
    String* shiftAmountOf(String* mod)
    {
        for (u32 i = (u32)0; i < mod.byteLength(); i = i + (u32)1)
            if (mod.byteAt(i) == (u8)'#') return mod.substringBytes(i, mod.byteLength() - i);
        return String.withCString("");
    }

    u32 encAddSubImm(u32 base, Array* o)
    {
        RegRef* d = parseReg((String*)o.get((u32)0));
        RegRef* n = parseReg((String*)o.get((u32)1));
        if (!d.ok() || !n.ok()) { fail(String.withCString("bad add/sub register")); _hit = false; return (u32)0; }
        // One width bit (sf), taken from Rd: a mixed `add x10, w16, #1` is
        // invalid AArch64 and would silently read the X view of the source
        // (blewit's #8 followup). Reject, as the reference does.
        if (d.is64() != n.is64()) {
            fail(String.withCString("add/sub width mismatch"));
            _hit = false;
            return (u32)0;
        }
        U64* imm = parseImm((String*)o.get((u32)2));
        if (!_immOk) { fail(String.withCString("bad add/sub immediate")); _hit = false; return (u32)0; }
        u32 sh = (u32)0;
        u32 v = imm.lo();
        bool negative = imm.hi() != (u32)0;
        if (o.count() > (u32)3) {
            // EXPLICIT shift: `add Rd, Rn, #imm, lsl #12`. The immediate is then
            // the UNSHIFTED value -- `#1, lsl #12` is 4096, not 1 -- so it is
            // taken as written and the shift bit set, rather than divided down
            // as the bare spelling is below. Reversing that would encode 1 for
            // 4096: silently wrong code rather than a rejection.
            String* mod = (String*)o.get((u32)3);
            if (!mod.hasPrefix(String.withCString("lsl"))) {
                fail(String.withCString("bad add/sub shift"));
                _hit = false;
                return (u32)0;
            }
            U64* amt = parseImm(shiftAmountOf(mod));
            if (!_immOk || amt.hi() != (u32)0
                || (amt.lo() != (u32)0 && amt.lo() != (u32)12)) {
                fail(String.withCString("add/sub shift must be 0 or 12"));
                _hit = false;
                return (u32)0;
            }
            if (amt.lo() == (u32)12) sh = (u32)1;
            if (negative || v > (u32)$FFF) {
                fail(String.withCString("add/sub immediate out of range"));
                _hit = false;
                return (u32)0;
            }
        } else if (negative || v > (u32)$FFF) {
            if (!negative && (v & (u32)$FFF) == (u32)0 && (v >> (u32)12) <= (u32)$FFF) {
                sh = (u32)1; v = v >> (u32)12;
            } else {
                fail(String.withCString("add/sub immediate out of range"));
                _hit = false;
                return (u32)0;
            }
        }
        u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
        return base | sf | (sh << (u32)22) | ((v & (u32)$FFF) << (u32)10)
             | (n.num() << (u32)5) | d.num();
    }

    u32 encAddSubReg(u32 base, Array* o)
    {
        RegRef* d = parseReg((String*)o.get((u32)0));
        RegRef* n = parseReg((String*)o.get((u32)1));
        if (!d.ok() || !n.ok() || o.count() < (u32)3) { fail(String.withCString("bad add/sub register")); _hit = false; return (u32)0; }
        RegRef* m = parseReg((String*)o.get((u32)2));
        if (!m.ok()) { fail(String.withCString("bad add/sub register")); _hit = false; return (u32)0; }
        u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
        if (o.count() >= (u32)4) {
            String* mod = ((String*)o.get((u32)3)).trimmed();
            u32 ws = firstSpace(mod);
            String* kw = ws == (u32)$FFFF_FFFF ? mod : mod.substringBytes((u32)0, ws);
            i32 shk = shiftKind(kw);
            u32 amt = (u32)0;
            u32 h = mod.byteIndexOf(String.withCString("#"));
            if (h != (u32)$FFFF_FFFF) { U64* a = parseImm(mod.substringFromByte(h)); if (_immOk) amt = a.lo(); }
            if (shk >= (i32)0)
                return base | sf | ((u32)shk << (u32)22) | (m.num() << (u32)16)
                     | ((amt & (u32)$3F) << (u32)10) | (n.num() << (u32)5) | d.num();
            i32 opt = extendKind(kw);
            if (opt < (i32)0) { fail(String.withCString("bad extend modifier")); _hit = false; return (u32)0; }
            // The extend name IMPLIES the index width (uxtb/h/w + sxtb/h/w
            // take Wm; uxtx/sxtx take Xm) and no encoding bit distinguishes
            // them, so a mismatched spelling silently encodes an instruction
            // reading the OTHER view of the register (blewit finding #8).
            // Reject, as the reference assembler does.
            if ((opt == (i32)3 || opt == (i32)7) != m.is64()) {
                fail(String.withCString("extend modifier requires the other index width"));
                _hit = false;
                return (u32)0;
            }
            return base | (u32)$00200000 | sf | (m.num() << (u32)16) | ((u32)opt << (u32)13)
                 | ((amt & (u32)7) << (u32)10) | (n.num() << (u32)5) | d.num();
        }
        // SP cannot appear in the shifted-register form, so anything naming it
        // uses the extended form with a zero shift.
        if (d.isSP() || n.isSP()) {
            u32 opt = d.is64() ? (u32)3 : (u32)2;
            return base | (u32)$00200000 | sf | (m.num() << (u32)16) | (opt << (u32)13)
                 | (n.num() << (u32)5) | d.num();
        }
        return base | sf | (m.num() << (u32)16) | (n.num() << (u32)5) | d.num();
    }

    static i32 shiftKind(String* m)
    {
        if (m.equals(String.withCString("lsl"))) return (i32)0;
        if (m.equals(String.withCString("lsr"))) return (i32)1;
        if (m.equals(String.withCString("asr"))) return (i32)2;
        return (i32)-1;
    }

    static i32 extendKind(String* m)
    {
        if (m.equals(String.withCString("uxtb"))) return (i32)0;
        if (m.equals(String.withCString("uxth"))) return (i32)1;
        if (m.equals(String.withCString("uxtw"))) return (i32)2;
        if (m.equals(String.withCString("uxtx"))) return (i32)3;
        if (m.equals(String.withCString("sxtb"))) return (i32)4;
        if (m.equals(String.withCString("sxth"))) return (i32)5;
        if (m.equals(String.withCString("sxtw"))) return (i32)6;
        if (m.equals(String.withCString("sxtx"))) return (i32)7;
        return (i32)-1;
    }

    // ── bitfield, shifts, multiply, conditional select ───────────────────
    u32 encBitfieldMul(String* mn, Array* ops, u32 pc)
    {
        u32 w = encBitfieldShift(mn, ops, pc);  if (_hit || _failed) return w;
        w = encMulDiv(mn, ops, pc);             if (_hit || _failed) return w;
        return encCondSelect(mn, ops, pc);
    }

    u32 encBitfieldShift(String* mn, Array* ops, u32 pc)
    {
        if (mn.equals(String.withCString("uxtb")) || mn.equals(String.withCString("uxth"))
         || mn.equals(String.withCString("uxtw")) || mn.equals(String.withCString("sxtb"))
         || mn.equals(String.withCString("sxth")) || mn.equals(String.withCString("sxtw"))) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            bool sign = mn.hasPrefix(String.withCString("s"));
            u32 imms = mn.hasSuffix(String.withCString("b")) ? (u32)7
                     : mn.hasSuffix(String.withCString("h")) ? (u32)15 : (u32)31;
            u32 base = sign ? (d.is64() ? (u32)$93400000 : (u32)$13000000)
                            : (d.is64() ? (u32)$D3400000 : (u32)$53000000);
            _hit = true;
            return base | (imms << (u32)10) | (n.num() << (u32)5) | d.num();
        }
        if (mn.equals(String.withCString("lsl")) || mn.equals(String.withCString("lsr"))
         || mn.equals(String.withCString("asr")) || mn.equals(String.withCString("ror"))) {
            if (ops.count() < (u32)3) { fail(String.withCString("shift needs 3 operands")); return (u32)0; }
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
            if (!opAt(ops, (u32)2).hasPrefix(String.withCString("#"))) {
                RegRef* m = parseReg(opAt(ops, (u32)2));
                if (!m.ok()) { fail(String.withCString("bad shift register")); return (u32)0; }
                u32 base = mn.equals(String.withCString("lsl")) ? (u32)$1AC02000
                         : mn.equals(String.withCString("lsr")) ? (u32)$1AC02400
                         : mn.equals(String.withCString("asr")) ? (u32)$1AC02800 : (u32)$1AC02C00;
                _hit = true;
                return base | sf | (m.num() << (u32)16) | (n.num() << (u32)5) | d.num();
            }
            U64* sv = parseImm(opAt(ops, (u32)2));
            if (!_immOk) { fail(String.withCString("bad shift amount")); return (u32)0; }
            u32 sAmt = sv.lo();
            u32 W = d.is64() ? (u32)64 : (u32)32;
            _hit = true;
            if (mn.equals(String.withCString("lsl"))) {
                u32 immr = (W - sAmt) % W;
                u32 imms = W - (u32)1 - sAmt;
                u32 base = d.is64() ? (u32)$D3400000 : (u32)$53000000;
                return base | (immr << (u32)16) | (imms << (u32)10) | (n.num() << (u32)5) | d.num();
            }
            if (mn.equals(String.withCString("lsr"))) {
                u32 base = d.is64() ? (u32)$D3400000 : (u32)$53000000;
                return base | (sAmt << (u32)16) | ((W - (u32)1) << (u32)10) | (n.num() << (u32)5) | d.num();
            }
            u32 base = d.is64() ? (u32)$93400000 : (u32)$13000000;
            return base | (sAmt << (u32)16) | ((W - (u32)1) << (u32)10) | (n.num() << (u32)5) | d.num();
        }
        return (u32)0;
    }

    u32 encMulDiv(String* mn, Array* ops, u32 pc)
    {
        if (mn.equals(String.withCString("mul"))) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            RegRef* m = parseReg(opAt(ops, (u32)2));
            _hit = true;
            return encMul3(d.is64() ? (u32)$9B000000 : (u32)$1B000000, d.num(), n.num(), m.num(), (u32)31);
        }
        if (mn.equals(String.withCString("madd")) || mn.equals(String.withCString("msub"))) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            RegRef* m = parseReg(opAt(ops, (u32)2));
            RegRef* a = parseReg(opAt(ops, (u32)3));
            u32 base = mn.equals(String.withCString("msub"))
                     ? (d.is64() ? (u32)$9B008000 : (u32)$1B008000)
                     : (d.is64() ? (u32)$9B000000 : (u32)$1B000000);
            _hit = true;
            return encMul3(base, d.num(), n.num(), m.num(), a.num());
        }
        if (mn.equals(String.withCString("umull")) || mn.equals(String.withCString("smull"))) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            RegRef* m = parseReg(opAt(ops, (u32)2));
            _hit = true;
            return encMul3(mn.equals(String.withCString("umull")) ? (u32)$9BA00000 : (u32)$9B200000,
                           d.num(), n.num(), m.num(), (u32)31);
        }
        if (mn.equals(String.withCString("umaddl")) || mn.equals(String.withCString("smaddl"))
         || mn.equals(String.withCString("msubl"))) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            RegRef* m = parseReg(opAt(ops, (u32)2));
            RegRef* a = parseReg(opAt(ops, (u32)3));
            _hit = true;
            return encMul3(mn.equals(String.withCString("smaddl")) ? (u32)$9B200000 : (u32)$9BA00000,
                           d.num(), n.num(), m.num(), a.num());
        }
        if (mn.equals(String.withCString("sdiv")) || mn.equals(String.withCString("udiv"))) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            RegRef* m = parseReg(opAt(ops, (u32)2));
            u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
            u32 base = mn.equals(String.withCString("sdiv")) ? (u32)$1AC00C00 : (u32)$1AC00800;
            _hit = true;
            return base | sf | (m.num() << (u32)16) | (n.num() << (u32)5) | d.num();
        }
        return (u32)0;
    }

    u32 encCondSelect(String* mn, Array* ops, u32 pc)
    {
        if (mn.equals(String.withCString("cset"))) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            i32 cc = condCode(opAt(ops, (u32)1));
            if (cc < (i32)0) { fail(String.withCString("bad cset condition")); return (u32)0; }
            u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
            _hit = true;
            return (u32)$1A800400 | sf | ((u32)31 << (u32)16) | (((u32)cc ^ (u32)1) << (u32)12)
                 | ((u32)31 << (u32)5) | d.num();
        }
        if (mn.equals(String.withCString("csetm"))) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            i32 cc = condCode(opAt(ops, (u32)1));
            if (cc < (i32)0) { fail(String.withCString("bad csetm condition")); return (u32)0; }
            u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
            _hit = true;
            return (u32)$5A800000 | sf | ((u32)31 << (u32)16) | (((u32)cc ^ (u32)1) << (u32)12)
                 | ((u32)31 << (u32)5) | d.num();
        }
        // ccmp/ccmn Rn, #imm5|Rm, #nzcv, cond — compare when the condition
        // holds, otherwise just plant #nzcv in the flags. clang emits it for a
        // short-circuit comparison, so the self-hosted runtime met it as soon
        // as a host C file with a compound condition was assembled here.
        if (mn.equals(String.withCString("ccmp")) || mn.equals(String.withCString("ccmn"))) {
            RegRef* n = parseReg(opAt(ops, (u32)0));
            i32 cc = condCode(opAt(ops, (u32)3));
            if (cc < (i32)0) { fail(String.withCString("bad ccmp condition")); return (u32)0; }
            U64* nz = parseImm(opAt(ops, (u32)2));
            if (!_immOk || nz.hi() != (u32)0 || nz.lo() > (u32)15) {
                fail(String.withCString("bad ccmp nzcv")); return (u32)0;
            }
            u32 sf = n.is64() ? (u32)$80000000 : (u32)0;
            u32 opbit = mn.equals(String.withCString("ccmp")) ? (u32)$40000000 : (u32)0;
            u32 base = (u32)$3A400000 | opbit | sf | ((u32)cc << (u32)12)
                     | (n.num() << (u32)5) | nz.lo();
            _hit = true;
            if (opAt(ops, (u32)1).hasPrefix(String.withCString("#"))) {
                U64* imm = parseImm(opAt(ops, (u32)1));
                if (!_immOk || imm.hi() != (u32)0 || imm.lo() > (u32)31) {
                    fail(String.withCString("bad ccmp immediate")); _hit = false; return (u32)0;
                }
                return base | (u32)$800 | (imm.lo() << (u32)16);
            }
            RegRef* m = parseReg(opAt(ops, (u32)1));
            return base | (m.num() << (u32)16);
        }
        // The four conditional selects differ only in bit 30 (invert) and bits
        // 11:10 (increment).
        // cinc/cinv/cneg Rd, Rn, cond == csinc/csinv/csneg Rd, Rn, Rn, invert(cond)
        // — the two-operand aliases clang emits (found by the iOS shim, stage 4).
        if (mn.equals(String.withCString("cinc")) || mn.equals(String.withCString("cinv"))
         || mn.equals(String.withCString("cneg"))) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            i32 cc = condCode(opAt(ops, (u32)2));
            if (cc < (i32)0) { fail(String.withCString("bad cinc condition")); return (u32)0; }
            u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
            u32 inv = (mn.equals(String.withCString("cinv")) || mn.equals(String.withCString("cneg")))
                    ? (u32)$40000000 : (u32)0;
            u32 op2 = (mn.equals(String.withCString("cinc")) || mn.equals(String.withCString("cneg")))
                    ? (u32)$400 : (u32)0;
            _hit = true;
            return (u32)$1A800000 | inv | op2 | sf | (n.num() << (u32)16)
                 | (((u32)cc ^ (u32)1) << (u32)12) | (n.num() << (u32)5) | d.num();
        }
        if (mn.equals(String.withCString("csel")) || mn.equals(String.withCString("csinc"))
         || mn.equals(String.withCString("csinv")) || mn.equals(String.withCString("csneg"))) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            RegRef* n = parseReg(opAt(ops, (u32)1));
            RegRef* m = parseReg(opAt(ops, (u32)2));
            i32 cc = condCode(opAt(ops, (u32)3));
            if (cc < (i32)0) { fail(String.withCString("bad csel condition")); return (u32)0; }
            u32 sf = d.is64() ? (u32)$80000000 : (u32)0;
            u32 inv = (mn.equals(String.withCString("csinv")) || mn.equals(String.withCString("csneg")))
                    ? (u32)$40000000 : (u32)0;
            u32 op2 = (mn.equals(String.withCString("csinc")) || mn.equals(String.withCString("csneg")))
                    ? (u32)$400 : (u32)0;
            _hit = true;
            return (u32)$1A800000 | inv | op2 | sf | (m.num() << (u32)16)
                 | ((u32)cc << (u32)12) | (n.num() << (u32)5) | d.num();
        }
        return (u32)0;
    }

    static u32 encMul3(u32 base, u32 rd, u32 rn, u32 rm, u32 ra)
    {
        return base | (rm << (u32)16) | (ra << (u32)10) | (rn << (u32)5) | rd;
    }

    // ── Memory ───────────────────────────────────────────────────────────
    //
    // The addressing tail: `[Xn]`, `[Xn, #imm]`, `[Xn, #imm]!` (pre-index) or
    // `[Xn], #imm` (post-index). Mode 0 = offset, 1 = pre, 2 = post.
    u32 _memRn;
    i32 _memImm;
    u32 _memMode;

    bool parseMem(Array* ops, u32 memIdx)
    {
        _memImm = (i32)0; _memMode = (u32)0;
        String* m = opAt(ops, memIdx);
        if (!m.hasPrefix(String.withCString("["))) { fail(String.withCString("expected [ in memory operand")); return false; }
        if (m.hasSuffix(String.withCString("]")) && memIdx + (u32)1 < ops.count()) {
            String* inner = m.substringBytes((u32)1, m.byteLength() - (u32)2);
            RegRef* b = parseReg(inner);
            if (!b.ok()) { fail(String.withCString("bad memory base")); return false; }
            U64* v = parseImm(opAt(ops, memIdx + (u32)1));
            if (!_immOk) { fail(String.withCString("bad post-index immediate")); return false; }
            _memRn = b.num(); _memImm = (i32)v.lo(); _memMode = (u32)2;
            return true;
        }
        bool pre = false;
        String* body = m;
        if (body.hasSuffix(String.withCString("]!"))) {
            pre = true;
            body = body.substringBytes((u32)1, body.byteLength() - (u32)3);
        } else if (body.hasSuffix(String.withCString("]"))) {
            body = body.substringBytes((u32)1, body.byteLength() - (u32)2);
        } else {
            fail(String.withCString("unterminated memory operand")); return false;
        }
        Array* parts = splitOperands(body);
        if (parts.count() < (u32)1) { fail(String.withCString("empty memory operand")); return false; }
        RegRef* b = parseReg((String*)parts.get((u32)0));
        if (!b.ok()) { fail(String.withCString("bad memory base")); return false; }
        _memRn = b.num();
        if (parts.count() >= (u32)2) {
            U64* v = parseImm((String*)parts.get((u32)1));
            if (!_immOk) { fail(String.withCString("bad memory offset")); return false; }
            _memImm = (i32)v.lo();
        }
        _memMode = pre ? (u32)1 : (u32)0;
        return true;
    }

    u32 encMemory(String* mn, Array* ops, u32 pc)
    {
        // An FP load/store is told from a GP one by its destination register.
        if ((mn.equals(String.withCString("ldr")) || mn.equals(String.withCString("str")))
            && ops.count() >= (u32)2) {
            FRegRef* t = parseFReg(opAt(ops, (u32)0));
            if (t.ok()) return encFpLoadStore(mn, ops, pc, t);
        }
        u32 uoff = ldstUoff(mn);
        u32 unsc = ldstUnsc(mn);
        i32 scale = ldstScale(mn);
        bool forceUnscaled = isUnscaledOnly(mn);
        if (scale < (i32)0) return encPairOrAddr(mn, ops, pc);

        RegRef* t = parseReg(opAt(ops, (u32)0));
        if (!t.ok()) { fail(String.withCString("bad load/store register")); return (u32)0; }
        bool sizedByReg = mn.equals(String.withCString("ldr")) || mn.equals(String.withCString("str"))
                       || mn.equals(String.withCString("ldur")) || mn.equals(String.withCString("stur"));
        u32 sc = (u32)scale;
        if (sizedByReg) {
            u32 sizeBits = t.is64() ? (u32)$C0000000 : (u32)$80000000;
            sc = t.is64() ? (u32)3 : (u32)2;
            uoff = (uoff & (u32)$3FFFFFFF) | sizeBits;
            unsc = (unsc & (u32)$3FFFFFFF) | sizeBits;
        }
        String* mem = opAt(ops, (u32)1);
        String* inner = (mem.hasPrefix(String.withCString("[")) && mem.hasSuffix(String.withCString("]")))
                      ? mem.substringBytes((u32)1, mem.byteLength() - (u32)2) : mem;
        // [Xn, sym@PAGEOFF] — the load half of an adrp pair; imm12 stays zero.
        bool innerIsGot = inner.byteIndexOf(String.withCString("@GOTPAGEOFF")) != (u32)$FFFF_FFFF;
        if (innerIsGot || inner.byteIndexOf(String.withCString("@PAGEOFF")) != (u32)$FFFF_FFFF) {
            Array* sp2 = splitOperands(inner);
            RegRef* bn = sp2.count() >= (u32)2 ? parseReg((String*)sp2.get((u32)0)) : RegRef.no();
            if (bn.ok()) {
                String* sy = (String*)sp2.get((u32)1);
                String* bare = sy.substringBytes((u32)0, sy.byteIndexOf(String.withCString("@")));
                // A GOT slot is always eight bytes, so the writer scales the
                // displacement itself and the access size does not enter.
                addFixup(pc, innerIsGot ? (u32)FIXUP_GOTPAGEOFF12 : (u32)FIXUP_PAGEOFF12,
                         bare, innerIsGot ? (u32)0 : sc);
                _hit = true;
                return uoff | (bn.num() << (u32)5) | t.num();
            }
        }
        // The register-offset form: [Xn, Wm, uxtw #s] / [Xn, Xm, lsl #s].
        Array* mp = splitOperands(inner);
        if (mp.count() >= (u32)2) {
            RegRef* bn = parseReg((String*)mp.get((u32)0));
            RegRef* bm = parseReg((String*)mp.get((u32)1));
            if (bn.ok() && bm.ok()) {
                u32 regBase = (unsc & (u32)$3FFFFFFF)
                            | (sizedByReg ? (t.is64() ? (u32)$C0000000 : (u32)$80000000)
                                          : (unsc & (u32)$C0000000))
                            | (u32)$00200800;
                u32 option = bm.is64() ? (u32)3 : (u32)2;
                u32 S = (u32)0;
                for (u32 k = (u32)2; k < mp.count(); k = k + (u32)1) {
                    String* e = ((String*)mp.get(k)).trimmed();
                    u32 ws = firstSpace(e);
                    String* kw = ws == (u32)$FFFF_FFFF ? e : e.substringBytes((u32)0, ws);
                    i32 o = memExtendKind(kw);
                    if (o >= (i32)0) option = (u32)o;
                    if (e.byteIndexOf(String.withCString("#")) != (u32)$FFFF_FFFF) S = (u32)1;
                }
                // The option IMPLIES the index width (uxtw/sxtw ↔ Wm,
                // lsl/sxtx ↔ Xm) — no separate bit exists, so a mismatched
                // spelling would encode an instruction reading the OTHER
                // view of the register (blewit finding #8). Reject it, as
                // the reference does.
                if ((option == (u32)3 || option == (u32)7) != bm.is64()) {
                    fail(String.withCString("index extend width mismatch"));
                    _hit = false;
                    return (u32)0;
                }
                _hit = true;
                return regBase | (bm.num() << (u32)16) | (option << (u32)13) | (S << (u32)12)
                     | (bn.num() << (u32)5) | t.num();
            }
        }
        if (!parseMem(ops, (u32)1)) return (u32)0;
        _hit = true;
        if (!forceUnscaled && _memMode == (u32)0 && _memImm >= (i32)0
            && ((u32)_memImm % ((u32)1 << sc)) == (u32)0
            && ((u32)_memImm >> sc) <= (u32)$FFF)
            return uoff | (((u32)_memImm >> sc) << (u32)10) | (_memRn << (u32)5) | t.num();
        u32 imm9 = (u32)_memImm & (u32)$1FF;
        u32 idx = _memMode == (u32)1 ? (u32)$C00 : _memMode == (u32)2 ? (u32)$400 : (u32)0;
        return unsc | (imm9 << (u32)12) | idx | (_memRn << (u32)5) | t.num();
    }

    u32 encFpLoadStore(String* mn, Array* ops, u32 pc, FRegRef* t)
    {
        bool isL = mn.equals(String.withCString("ldr"));
        u32 fscale = t.sz();
        u32 fbase = t.sz() == (u32)4 ? (isL ? (u32)$3DC00000 : (u32)$3D800000)
                  : t.sz() == (u32)3 ? (isL ? (u32)$FD400000 : (u32)$FD000000)
                                     : (isL ? (u32)$BD400000 : (u32)$BD000000);
        String* fmem = opAt(ops, (u32)1);
        String* fin = (fmem.hasPrefix(String.withCString("[")) && fmem.hasSuffix(String.withCString("]")))
                    ? fmem.substringBytes((u32)1, fmem.byteLength() - (u32)2) : fmem;
        if (fin.byteIndexOf(String.withCString("@PAGEOFF")) != (u32)$FFFF_FFFF) {
            Array* fp2 = splitOperands(fin);
            RegRef* bn = fp2.count() >= (u32)2 ? parseReg((String*)fp2.get((u32)0)) : RegRef.no();
            if (bn.ok()) {
                String* sy = (String*)fp2.get((u32)1);
                String* bare = sy.substringBytes((u32)0, sy.byteIndexOf(String.withCString("@")));
                addFixup(pc, (u32)FIXUP_PAGEOFF12, bare, fscale);
                _hit = true;
                return fbase | (bn.num() << (u32)5) | t.num();
            }
        }
        // The register-offset form: `str d9, [x10, x17, lsl #3]` /
        // `[x11, w10, sxtw #3]`. The GP path has it; the FP path used to fall
        // straight to parseMem, which rejects a register second operand as a
        // "bad memory offset" (c2xc 09 — a scaled double store `d[i] = x`). The
        // encoding is the FP unscaled base (uoff with bits 25:24 cleared) plus
        // bit 21 and the "10" in bits 11:10, then Rm/option/S like the GP form.
        Array* fmp = splitOperands(fin);
        if (fmp.count() >= (u32)2) {
            RegRef* fbn = parseReg((String*)fmp.get((u32)0));
            RegRef* fbm = parseReg((String*)fmp.get((u32)1));
            if (fbn.ok() && fbm.ok()) {
                u32 fregBase = (fbase & ~(u32)$03000000) | (u32)$00200800;
                u32 foption = fbm.is64() ? (u32)3 : (u32)2;
                u32 fS = (u32)0;
                for (u32 k = (u32)2; k < fmp.count(); k = k + (u32)1) {
                    String* e = ((String*)fmp.get(k)).trimmed();
                    u32 ws = firstSpace(e);
                    String* kw = ws == (u32)$FFFF_FFFF ? e : e.substringBytes((u32)0, ws);
                    i32 o = memExtendKind(kw);
                    if (o >= (i32)0) foption = (u32)o;
                    if (e.byteIndexOf(String.withCString("#")) != (u32)$FFFF_FFFF) fS = (u32)1;
                }
                if ((foption == (u32)3 || foption == (u32)7) != fbm.is64()) {
                    fail(String.withCString("index extend width mismatch"));
                    _hit = false;
                    return (u32)0;
                }
                _hit = true;
                return fregBase | (fbm.num() << (u32)16) | (foption << (u32)13) | (fS << (u32)12)
                     | (fbn.num() << (u32)5) | t.num();
            }
        }
        if (!parseMem(ops, (u32)1)) return (u32)0;
        _hit = true;
        if (_memMode == (u32)0 && _memImm >= (i32)0
            && ((u32)_memImm % ((u32)1 << fscale)) == (u32)0
            && ((u32)_memImm >> fscale) <= (u32)$FFF)
            return fbase | (((u32)_memImm >> fscale) << (u32)10) | (_memRn << (u32)5) | t.num();
        u32 imm9 = (u32)_memImm & (u32)$1FF;
        u32 unscBase = (fbase & (u32)$3FFFFFFF)
                     | (t.sz() == (u32)3 ? (u32)$C0000000 : (u32)$80000000);
        u32 idx = _memMode == (u32)1 ? (u32)$C00 : _memMode == (u32)2 ? (u32)$400 : (u32)0;
        return (unscBase & ~(u32)$00000C00) | (imm9 << (u32)12) | idx
             | (_memRn << (u32)5) | t.num();
    }

    static i32 memExtendKind(String* m)
    {
        if (m.equals(String.withCString("lsl"))) return (i32)3;
        return extendKind(m);
    }

    static bool isUnscaledOnly(String* m)
    {
        return m.equals(String.withCString("stur")) || m.equals(String.withCString("ldur"))
            || m.equals(String.withCString("sturb")) || m.equals(String.withCString("ldurb"))
            || m.equals(String.withCString("sturh")) || m.equals(String.withCString("ldurh"))
            || m.equals(String.withCString("ldursb")) || m.equals(String.withCString("ldursh"))
            || m.equals(String.withCString("ldursw"));
    }

    static u32 ldstUoff(String* m)
    {
        if (m.equals(String.withCString("str")))   return (u32)$B9000000;
        if (m.equals(String.withCString("ldr")))   return (u32)$B9400000;
        if (m.equals(String.withCString("strb")))  return (u32)$39000000;
        if (m.equals(String.withCString("ldrb")))  return (u32)$39400000;
        if (m.equals(String.withCString("strh")))  return (u32)$79000000;
        if (m.equals(String.withCString("ldrh")))  return (u32)$79400000;
        if (m.equals(String.withCString("ldrsb"))) return (u32)$39C00000;
        if (m.equals(String.withCString("ldrsh"))) return (u32)$79C00000;
        if (m.equals(String.withCString("ldrsw"))) return (u32)$B9800000;
        if (m.equals(String.withCString("stur")))   return (u32)$B8000000;
        if (m.equals(String.withCString("ldur")))   return (u32)$B8400000;
        if (m.equals(String.withCString("sturb")))  return (u32)$38000000;
        if (m.equals(String.withCString("ldurb")))  return (u32)$38400000;
        if (m.equals(String.withCString("sturh")))  return (u32)$78000000;
        if (m.equals(String.withCString("ldurh")))  return (u32)$78400000;
        if (m.equals(String.withCString("ldursb"))) return (u32)$38C00000;
        if (m.equals(String.withCString("ldursh"))) return (u32)$78C00000;
        if (m.equals(String.withCString("ldursw"))) return (u32)$B8800000;
        return (u32)0;
    }

    static u32 ldstUnsc(String* m)
    {
        if (m.equals(String.withCString("str")))   return (u32)$B8000000;
        if (m.equals(String.withCString("ldr")))   return (u32)$B8400000;
        if (m.equals(String.withCString("strb")))  return (u32)$38000000;
        if (m.equals(String.withCString("ldrb")))  return (u32)$38400000;
        if (m.equals(String.withCString("strh")))  return (u32)$78000000;
        if (m.equals(String.withCString("ldrh")))  return (u32)$78400000;
        if (m.equals(String.withCString("ldrsb"))) return (u32)$38C00000;
        if (m.equals(String.withCString("ldrsh"))) return (u32)$78C00000;
        if (m.equals(String.withCString("ldrsw"))) return (u32)$B8800000;
        return ldstUoff(m);
    }

    static i32 ldstScale(String* m)
    {
        if (m.equals(String.withCString("str")) || m.equals(String.withCString("ldr"))
         || m.equals(String.withCString("ldrsw")) || m.equals(String.withCString("stur"))
         || m.equals(String.withCString("ldur")) || m.equals(String.withCString("ldursw"))) return (i32)2;
        if (m.equals(String.withCString("strb")) || m.equals(String.withCString("ldrb"))
         || m.equals(String.withCString("ldrsb")) || m.equals(String.withCString("sturb"))
         || m.equals(String.withCString("ldurb")) || m.equals(String.withCString("ldursb"))) return (i32)0;
        if (m.equals(String.withCString("strh")) || m.equals(String.withCString("ldrh"))
         || m.equals(String.withCString("ldrsh")) || m.equals(String.withCString("sturh"))
         || m.equals(String.withCString("ldurh")) || m.equals(String.withCString("ldursh"))) return (i32)1;
        return (i32)-1;
    }

    // ── Load/store pair, adrp/adr ────────────────────────────────────────
    u32 encPairOrAddr(String* mn, Array* ops, u32 pc)
    {
        if (mn.equals(String.withCString("stp")) || mn.equals(String.withCString("ldp"))) {
            bool L = mn.equals(String.withCString("ldp"));
            FRegRef* ft = parseFReg(opAt(ops, (u32)0));
            FRegRef* ft2 = parseFReg(opAt(ops, (u32)1));
            if (ft.ok() && ft2.ok()) {
                if (!parseMem(ops, (u32)2)) return (u32)0;
                u32 scale = ft.sz();
                u32 imm7 = ((u32)(_memImm >> (i32)scale)) & (u32)$7F;
                u32 fb = ft.sz() == (u32)4
                       ? (_memMode == (u32)1 ? (u32)$AD800000 : _memMode == (u32)2 ? (u32)$AC800000 : (u32)$AD000000)
                       : ft.sz() == (u32)3
                       ? (_memMode == (u32)1 ? (u32)$6D800000 : _memMode == (u32)2 ? (u32)$6C800000 : (u32)$6D000000)
                       : (_memMode == (u32)1 ? (u32)$2D800000 : _memMode == (u32)2 ? (u32)$2C800000 : (u32)$2D000000);
                if (L) fb = fb | (u32)$00400000;
                _hit = true;
                return fb | (imm7 << (u32)15) | (ft2.num() << (u32)10)
                     | (_memRn << (u32)5) | ft.num();
            }
            RegRef* t = parseReg(opAt(ops, (u32)0));
            RegRef* t2 = parseReg(opAt(ops, (u32)1));
            if (!t.ok() || !t2.ok()) { fail(String.withCString("bad pair register")); return (u32)0; }
            if (!parseMem(ops, (u32)2)) return (u32)0;
            u32 scale = t.is64() ? (u32)3 : (u32)2;
            u32 imm7 = ((u32)(_memImm >> (i32)scale)) & (u32)$7F;
            u32 base32 = _memMode == (u32)0 ? (t.is64() ? (u32)$A9000000 : (u32)$29000000)
                       : _memMode == (u32)1 ? (t.is64() ? (u32)$A9800000 : (u32)$29800000)
                                            : (t.is64() ? (u32)$A8800000 : (u32)$28800000);
            if (L) base32 = base32 | (u32)$00400000;
            _hit = true;
            return base32 | (imm7 << (u32)15) | (t2.num() << (u32)10)
                 | (_memRn << (u32)5) | t.num();
        }
        if (mn.equals(String.withCString("adrp")) || mn.equals(String.withCString("adr"))) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            String* sym = opAt(ops, (u32)1);
            String* bare = sym;
            u32 at = sym.byteIndexOf(String.withCString("@"));
            if (at != (u32)$FFFF_FFFF) bare = sym.substringBytes((u32)0, at);
            u8 c0 = bare.byteLength() > (u32)0 ? bare.byteAt((u32)0) : (u8)0;
            bool isName = c0 == (u8)'_' || c0 == (u8)'.'
                       || (c0 >= (u8)'A' && c0 <= (u8)'Z') || (c0 >= (u8)'a' && c0 <= (u8)'z');
            if (!isName) { fail(String.withCString("adr needs a symbol")); return (u32)0; }
            // `sym@GOTPAGE` is the page of the symbol's __got SLOT, not of the
            // symbol: the target is an imported DATA symbol with no in-image
            // address to take.
            bool isGot = at != (u32)$FFFF_FFFF
                      && sym.substringFromByte(at).hasPrefix(String.withCString("@GOTPAGE"));
            u32 kind = mn.equals(String.withCString("adrp"))
                     ? (isGot ? (u32)FIXUP_GOTPAGE21 : (u32)FIXUP_PAGE21)
                     : (isGot ? (u32)FIXUP_GOTPAGEOFF12 : (u32)FIXUP_PAGEOFF12);
            addFixup(pc, kind, bare, (u32)0);
            _hit = true;
            return (mn.equals(String.withCString("adrp")) ? (u32)$90000000 : (u32)$10000000) | d.num();
        }
        return (u32)0;
    }

    // ── Branches and system ──────────────────────────────────────────────
    //
    // A conditional branch carries a SIGNED displacement in a narrow field —
    // 19 bits for b.cond/cbz/cbnz, 14 for tbz/tbnz. Masking an out-of-range
    // one into the field yields a valid-looking instruction that jumps
    // somewhere else entirely, and the program dies far away with the PC in
    // the middle of nothing. So each is CHECKED. The check is not theoretical:
    // it fired on a self-hosted link of a program with Foundation plus the
    // self-hosted preprocessor, whose crash was a truncated branch.
    u32 encBranches(String* mn, Array* ops, u32 pc)
    {
        if (mn.equals(String.withCString("b")) || mn.equals(String.withCString("bl"))) {
            String* tgt = opAt(ops, (u32)0);
            u32 addr = resolveTarget(tgt);
            u32 base = mn.equals(String.withCString("bl")) ? (u32)$94000000 : (u32)$14000000;
            _hit = true;
            if (_lastWasLocal) {
                i32 rel = ((i32)addr - (i32)pc) >> (i32)2;
                return base | ((u32)rel & (u32)$03FFFFFF);
            }
            addFixup(pc, (u32)FIXUP_BRANCH26, tgt, (u32)0);
            return base;
        }
        if (mn.hasPrefix(String.withCString("b."))) {
            i32 cc = condCode(mn.substringFromByte((u32)2));
            if (cc < (i32)0) { fail(String.withCString("bad branch condition")); return (u32)0; }
            u32 addr = resolveTarget(opAt(ops, (u32)0));
            i32 rel = _lastWasLocal ? (((i32)addr - (i32)pc) >> (i32)2) : (i32)0;
            if (rel < (i32)-262144 || rel >= (i32)262144) {
                fail(String.withCString("conditional branch out of range (b.cond reaches +/-1MB)"));
                return (u32)0;
            }
            _hit = true;
            return (u32)$54000000 | (((u32)rel & (u32)$7FFFF) << (u32)5) | (u32)cc;
        }
        if (mn.equals(String.withCString("cbz")) || mn.equals(String.withCString("cbnz"))) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            u32 addr = resolveTarget(opAt(ops, (u32)1));
            i32 rel = _lastWasLocal ? (((i32)addr - (i32)pc) >> (i32)2) : (i32)0;
            if (rel < (i32)-262144 || rel >= (i32)262144) {
                fail(String.withCString("cbz/cbnz out of range (reaches +/-1MB)"));
                return (u32)0;
            }
            u32 base = mn.equals(String.withCString("cbnz")) ? (u32)$35000000 : (u32)$34000000;
            if (d.is64()) base = base | (u32)$80000000;
            _hit = true;
            return base | (((u32)rel & (u32)$7FFFF) << (u32)5) | d.num();
        }
        if (mn.equals(String.withCString("tbz")) || mn.equals(String.withCString("tbnz"))) {
            RegRef* d = parseReg(opAt(ops, (u32)0));
            U64* bit = parseImm(opAt(ops, (u32)1));
            if (!_immOk) { fail(String.withCString("bad test-bit index")); return (u32)0; }
            u32 addr = resolveTarget(opAt(ops, (u32)2));
            i32 rel = _lastWasLocal ? (((i32)addr - (i32)pc) >> (i32)2) : (i32)0;
            if (rel < (i32)-8192 || rel >= (i32)8192) {
                fail(String.withCString("tbz/tbnz out of range (reaches +/-32KB)"));
                return (u32)0;
            }
            u32 op = mn.equals(String.withCString("tbnz")) ? (u32)1 : (u32)0;
            _hit = true;
            return (u32)$36000000 | (((bit.lo() >> (u32)5) & (u32)1) << (u32)31) | (op << (u32)24)
                 | ((bit.lo() & (u32)$1F) << (u32)19) | (((u32)rel & (u32)$3FFF) << (u32)5) | d.num();
        }
        if (mn.equals(String.withCString("ret"))) {
            u32 r = (u32)30;
            if (ops.count() > (u32)0) { RegRef* x = parseReg(opAt(ops, (u32)0)); if (x.ok()) r = x.num(); }
            _hit = true;
            return (u32)$D65F0000 | (r << (u32)5);
        }
        if ((mn.equals(String.withCString("svc")) || mn.equals(String.withCString("brk"))
          || mn.equals(String.withCString("hlt"))) && ops.count() == (u32)1) {
            U64* imm = parseImm(opAt(ops, (u32)0));
            u32 base = mn.equals(String.withCString("svc")) ? (u32)$D4000001
                     : mn.equals(String.withCString("brk")) ? (u32)$D4200000 : (u32)$D4400000;
            _hit = true;
            return base | ((imm.lo() & (u32)$FFFF) << (u32)5);
        }
        if (mn.equals(String.withCString("blr")) || mn.equals(String.withCString("br"))) {
            RegRef* n = parseReg(opAt(ops, (u32)0));
            _hit = true;
            return (mn.equals(String.withCString("blr")) ? (u32)$D63F0000 : (u32)$D61F0000)
                 | (n.num() << (u32)5);
        }
        if (mn.equals(String.withCString("nop"))) { _hit = true; return (u32)$D503201F; }
        return (u32)0;
    }

    // ── Data directives ──────────────────────────────────────────────────
    //
    // Numeric operands only. A symbol-valued `.quad` is handled separately,
    // because it needs a rebased pointer and a fixup rather than eight bytes
    // of a guess.
    bool _wasDirective;

    bool emitDataDirective(String* l, Array* into)
    {
        _wasDirective = false;
        u32 sp = firstSpace(l);
        String* mn = sp == (u32)$FFFF_FFFF ? l : l.substringBytes((u32)0, sp);
        String* rest = sp == (u32)$FFFF_FFFF ? String.withCString("")
                                             : l.substringFromByte(sp).trimmed();
        u32 width = (u32)0;
        if (mn.equals(String.withCString(".byte"))) width = (u32)1;
        else if (mn.equals(String.withCString(".hword")) || mn.equals(String.withCString(".short"))
              || mn.equals(String.withCString(".2byte"))) width = (u32)2;
        else if (mn.equals(String.withCString(".word")) || mn.equals(String.withCString(".long"))
              || mn.equals(String.withCString(".4byte"))) width = (u32)4;
        else if (mn.equals(String.withCString(".quad")) || mn.equals(String.withCString(".8byte"))
              || mn.equals(String.withCString(".xword")))
            width = (u32)8;
        else if (mn.equals(String.withCString(".ascii")) || mn.equals(String.withCString(".asciz"))
              || mn.equals(String.withCString(".string"))) {
            u32 q1 = rest.byteIndexOf(String.withCString("\""));
            u32 q2 = lastIndexOfQuote(rest);
            if (q1 == (u32)$FFFF_FFFF || q2 <= q1) { fail(String.withCString("bad string directive")); return true; }
            String* str = rest.substringBytes(q1 + (u32)1, q2 - q1 - (u32)1);
            u32 i = (u32)0;
            while (i < str.byteLength()) {
                u8 c = str.byteAt(i);
                if (c == (u8)'\\' && i + (u32)1 < str.byteLength()) {
                    i = i + (u32)1;
                    u8 n = str.byteAt(i);
                    if (n == (u8)'n') c = (u8)10;
                    else if (n == (u8)'t') c = (u8)9;
                    else if (n == (u8)'r') c = (u8)13;
                    else if (n == (u8)'0') c = (u8)0;
                    else c = n;
                }
                into.add((Object*)Number.withU32((u32)c));
                i = i + (u32)1;
            }
            if (!mn.equals(String.withCString(".ascii"))) into.add((Object*)Number.withU32((u32)0));
            _wasDirective = true;
            return true;
        }
        else if (mn.equals(String.withCString(".space")) || mn.equals(String.withCString(".zero"))) {
            Array* a = splitOperands(rest);
            U64* n = parseImm((String*)a.get((u32)0));
            u32 fill = (u32)0;
            if (a.count() > (u32)1) { U64* f = parseImm((String*)a.get((u32)1)); if (_immOk) fill = f.lo(); }
            for (u32 i = (u32)0; i < n.lo(); i = i + (u32)1)
                into.add((Object*)Number.withU32(fill & (u32)$FF));
            _wasDirective = true;
            return true;
        }
        else return false;

        Array* toks = splitOperands(rest);
        for (u32 i = (u32)0; i < toks.count(); i = i + (u32)1) {
            U64* v = parseImm((String*)toks.get(i));
            if (!_immOk) { fail(String.withCString("bad data value")); return true; }
            for (u32 b = (u32)0; b < width; b = b + (u32)1)
                into.add((Object*)Number.withU32(v.byteAt(b)));
        }
        _wasDirective = true;
        return true;
    }

    static u32 lastIndexOfQuote(String* s)
    {
        u32 found = (u32)$FFFF_FFFF;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            if (s.byteAt(i) == (u8)'"') found = i;
        return found;
    }

    // `.quad <symbol>` — a symbol-valued pointer (a vtable slot, say), which
    // becomes eight rebased bytes and a fixup rather than a number.
    static String* quadSymbolOperand(String* l)
    {
        u32 sp = firstSpace(l);
        if (sp == (u32)$FFFF_FFFF) return (String*)0;
        String* mn = l.substringBytes((u32)0, sp);
        if (!mn.equals(String.withCString(".quad")) && !mn.equals(String.withCString(".8byte"))
         && !mn.equals(String.withCString(".xword")))
            return (String*)0;
        String* rest = l.substringFromByte(sp).trimmed();
        if (rest.byteIndexOf(String.withCString(",")) != (u32)$FFFF_FFFF) return (String*)0;
        u8 c = rest.byteLength() > (u32)0 ? rest.byteAt((u32)0) : (u8)0;
        if (c >= (u8)'0' && c <= (u8)'9') return (String*)0;
        if (c == (u8)'-' || c == (u8)'#') return (String*)0;
        bool isName = c == (u8)'_' || c == (u8)'.'
                   || (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'a' && c <= (u8)'z');
        return isName ? rest : (String*)0;
    }

    // ── The two passes ───────────────────────────────────────────────────
    //
    // Section 0 is __text and section 1 is __DATA,__data; each has its OWN
    // address space, and the linker assigns the final bases. Pass 1 places the
    // labels and lays down the data; pass 2 encodes the text, by which point
    // every local label's address is known.
    void assemble(String* asmText)
    {
        Array* lines = asmText.splitOnByte((u8)'\n');
        Array* insns = new Array();
        u32 textAddr = (u32)0;
        u32 dataAddr = (u32)0;
        u32 section = (u32)0;
        bool inModInit = false;      // bug 066: inside __DATA,__mod_init_func

        for (u32 li = (u32)0; li < lines.count(); li = li + (u32)1) {
            String* l = stripComment((String*)lines.get(li)).trimmed();
            if (l.byteLength() == (u32)0) continue;
            // A line starting with '.' is a DIRECTIVE unless it ends with ':',
            // in which case it is a local label like `.Lmain_retain_done_0:`
            // and must be recorded, not skipped as something unrecognised.
            if (l.hasPrefix(String.withCString(".")) && !l.hasSuffix(String.withCString(":"))) {
                if (l.hasPrefix(String.withCString(".text"))) { section = (u32)0; inModInit = false; continue; }
                if (l.hasPrefix(String.withCString(".section"))) {
                    section = l.byteIndexOf(String.withCString("__text")) != (u32)$FFFF_FFFF ? (u32)0 : (u32)1;
                    // Bug 066: __mod_init_func's pointers are ordinary __DATA
                    // bytes; what makes dyld CALL them is the section type, and
                    // folding them anonymously into __data is exactly why
                    // load-time constructors never ran.
                    //
                    // Bug 124: match WITHOUT the leading underscores, and accept
                    // the ELF spelling. The android path strips one `_` after a
                    // comma from the whole unit, so this directive arrives as
                    // `.section _DATA,_mod_init_func,...` and a `__mod_init_func`
                    // needle misses — putting android back in exactly the state
                    // bug 066 fixed for Mach-O. The leading dot on `.init_array`
                    // keeps `.preinit_array` from matching.
                    inModInit = section == (u32)1
                        && (l.byteIndexOf(String.withCString("mod_init_func")) != (u32)$FFFF_FFFF
                         || l.byteIndexOf(String.withCString(".init_array")) != (u32)$FFFF_FFFF);
                    continue;
                }
                if (l.hasPrefix(String.withCString(".data"))) { section = (u32)1; inModInit = false; continue; }
                // ELF spelling. Zero bytes laid here are still the LAST thing
                // in the image's data, and the writers drop a trailing zero run
                // from the file, so .bss costs nothing on disk.
                if (l.hasPrefix(String.withCString(".bss"))) { section = (u32)1; continue; }
                if (l.hasPrefix(String.withCString(".align")) || l.hasPrefix(String.withCString(".p2align"))) {
                    u32 skip = l.hasPrefix(String.withCString(".p2align")) ? (u32)8 : (u32)6;
                    // `.p2align 2, 0x0` — clang's ELF output carries a FILL
                    // operand its Mach-O output does not, and the whole
                    // "2, 0x0" does not parse as an immediate: the alignment
                    // was silently dropped, leaving `_xt_threads_active` three
                    // bytes off and its 4-byte `ldr` page offset unencodable.
                    String* aTxt = l.substringFromByte(skip).trimmed();
                    u32 comma = aTxt.byteIndexOf(String.withCString(","));
                    if (comma != (u32)$FFFF_FFFF) aTxt = aTxt.substringBytes((u32)0, comma);
                    U64* a = parseImm(aTxt.trimmed());
                    u32 al = (u32)1 << a.lo();
                    if (section == (u32)0) { while (textAddr % al != (u32)0) textAddr = textAddr + (u32)1; }
                    else {
                        while (dataAddr % al != (u32)0) {
                            _dataBytes.add((Object*)Number.withU32((u32)0));
                            dataAddr = dataAddr + (u32)1;
                        }
                    }
                    continue;
                }
                if (l.hasPrefix(String.withCString(".comm")) || l.hasPrefix(String.withCString(".zerofill"))
                 || l.hasPrefix(String.withCString(".lcomm"))) {
                    // A zero-initialised global, allocated in __data. `.comm`
                    // and `.lcomm` name it first; `.zerofill` puts the segment
                    // and section in front, so the name is operand 2.
                    u32 sp0 = firstSpace(l);
                    if (sp0 == (u32)$FFFF_FFFF) continue;
                    Array* a = splitOperands(l.substringFromByte(sp0).trimmed());
                    u32 ni = l.hasPrefix(String.withCString(".zerofill")) ? (u32)2 : (u32)0;
                    if (a.count() > ni + (u32)1) {
                        String* nm = ((String*)a.get(ni)).trimmed();
                        U64* sz = parseImm((String*)a.get(ni + (u32)1));
                        u32 alg = (u32)0;
                        if (a.count() > ni + (u32)2) { U64* g = parseImm((String*)a.get(ni + (u32)2)); if (_immOk) alg = g.lo(); }
                        // `.comm` is a COMMON (external tentative def): NO storage
                        // in this object, so the linker gives it one shared slot
                        // and every unit binds to it (bug 169). `.lcomm` /
                        // `.zerofill` stay a private LOCAL zero-init in __data.
                        if (l.hasPrefix(String.withCString(".comm"))) {
                            Array* info = new Array();
                            info.add((Object*)Number.withU32(sz.lo()));
                            info.add((Object*)Number.withU32(alg));
                            _commonSyms.set((Hashable*)nm, (Object*)info);
                        } else {
                            u32 al = (u32)1 << alg;
                            while (dataAddr % al != (u32)0) {
                                _dataBytes.add((Object*)Number.withU32((u32)0));
                                dataAddr = dataAddr + (u32)1;
                            }
                            _symbols.set((Hashable*)nm, (Object*)Number.withU32(dataAddr));
                            _dataSyms.add((Object*)nm);
                            for (u32 i = (u32)0; i < sz.lo(); i = i + (u32)1)
                                _dataBytes.add((Object*)Number.withU32((u32)0));
                            dataAddr = dataAddr + sz.lo();
                        }
                    }
                    continue;
                }
                if (l.hasPrefix(String.withCString(".globl"))) {
                    // Visibility: the object writer exports exactly these; every
                    // other defined symbol is local to its object (bug 136).
                    String* nm = l.substringFromByte((u32)6).trimmed();
                    if (nm.byteLength() > (u32)0) _globals.add((Object*)nm);
                    continue;
                }
                if (section == (u32)1) {
                    String* qsym = quadSymbolOperand(l);
                    if (qsym != (String*)0) {
                        // Bug 066: a constructor pointer goes to its own buffer,
                        // its fixup offset relative to that buffer; the linker
                        // places both once it knows where the array lands.
                        Array* dst = inModInit ? _modInitBytes : _dataBytes;
                        u32 at = inModInit ? dst.count() : dataAddr;
                        Arm64Fixup* f = Arm64Fixup.make(at, (u32)FIXUP_POINTER64, qsym, (u32)0);
                        if (inModInit) { _modInitFixups.add((Object*)f); }
                        else           { _fixups.add((Object*)f); }
                        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
                            dst.add((Object*)Number.withU32((u32)0));
                        if (!inModInit) dataAddr = dataAddr + (u32)8;
                        continue;
                    }
                    u32 before = _dataBytes.count();
                    if (emitDataDirective(l, _dataBytes)) {
                        if (_failed) return;
                        dataAddr = dataAddr + (_dataBytes.count() - before);
                        continue;
                    }
                }
                continue;                       // .subsections_via_symbols and friends
            }
            if (l.hasSuffix(String.withCString(":"))) {
                String* lbl = l.substringBytes((u32)0, l.byteLength() - (u32)1);
                // Defined TWICE in one unit is an error, not last-one-wins: the
                // symbol table is flat, so a second definition silently
                // retargets every branch to the first — and two clang-generated
                // files concatenated together both spell their local labels
                // `.LBB0_1`. `Lloh<N>` is exempt: Darwin numbers those
                // linker-optimization-hint markers per FUNCTION, so rt-macos.s
                // legitimately defines Lloh5 twice, and they are only `.loh`
                // operands — never branch targets.
                if (_symbols.get((Hashable*)lbl) != (Object*)0
                 && !lbl.hasPrefix(String.withCString("Lloh"))) {
                    failFmt(String.withCString("duplicate label"), lbl);
                    return;
                }
                if (section == (u32)0) _symbols.set((Hashable*)lbl, (Object*)Number.withU32(textAddr));
                else {
                    _symbols.set((Hashable*)lbl, (Object*)Number.withU32(dataAddr));
                    _dataSyms.add((Object*)lbl);
                }
                continue;
            }
            if (section == (u32)0) { insns.add((Object*)l); textAddr = textAddr + (u32)4; }
            else {
                u32 before = _dataBytes.count();
                if (emitDataDirective(l, _dataBytes)) {
                    if (_failed) return;
                    dataAddr = dataAddr + (_dataBytes.count() - before);
                }
            }
        }

        // Pass 2. Only TEXT symbols resolve as local: a data symbol reaches
        // code through an adrp/add pair, never a relative branch.
        _resolveSyms = _symbols;
        _resolveDataSyms = _dataSyms;
        u32 pc = (u32)0;
        for (u32 i = (u32)0; i < insns.count(); i = i + (u32)1) {
            String* insn = (String*)insns.get(i);
            u32 w = encodeLine(insn, pc);
            if (_failed) {
                String* m = String.withCString("line '");
                m.append(insn);
                m.appendCString("': ");
                m.append(_why);
                _why = m;
                return;
            }
            _textBytes.add((Object*)Number.withU32(w & (u32)$FF));
            _textBytes.add((Object*)Number.withU32((w >> (u32)8) & (u32)$FF));
            _textBytes.add((Object*)Number.withU32((w >> (u32)16) & (u32)$FF));
            _textBytes.add((Object*)Number.withU32((w >> (u32)24) & (u32)$FF));
            pc = pc + (u32)4;
        }
    }
}
