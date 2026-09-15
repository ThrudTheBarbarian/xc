#!/bin/bash
# native-arm64.sh — cross-module checks that need nothing but the host.
#
# tests/crossmod/run.sh covers a `^` crossing a module boundary, but it needs
# the XTOS loader tree and qemu. This one builds a .dylib and a client with the
# host toolchain and runs them directly, so it can be part of an ordinary
# working loop.
#
# What it covers, and why each was worth a test:
#
#   1. ARRAY IVAR EXPORT. A class with `u8 bits[32]` serialised into the
#      interface as the type `u8[32]`, which the importer could not resolve —
#      so the class could not be exported AT ALL. Invisible until CharacterSet
#      (a 256-bit bitmap) joined Foundation and took every Foundation-importing
#      library down with it.
#
#   2. ARC ACROSS THE BOUNDARY. The +1/+0 return convention is derived from
#      each function's BODY, per compilation unit, and is not carried in the
#      interface. A factory that returns `new T` is +1 inside its own library
#      and +0 to an importer that has never seen the body — so the caller
#      retains a value it was handed ownership of, and every returned object
#      leaks. Identical source in one module leaks nothing.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
XTC=bin/osx/xcc
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ -x "$XTC" ] || { echo "native-arm64: build first (make)" >&2; exit 1; }
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) ;;
    *) echo "SKIP: needs an arm64 macOS host"; exit 0 ;;
esac

fail=0
note() { echo "  $*"; }

# ── 1. a class with an array ivar crosses the interface ──────────────────────
cat > "$TMP/Bits.xc" <<'EOF'
class Holder
{
    u8 bits[32];
    void init(void) { bits[0] = (u8)1; }
    static u16 answer(void) { return (u16)42; }
}
EOF
cat > "$TMP/bitsuser.xc" <<'EOF'
#import <Bits>
#import "Stdio.xc"
void main(void) { Stdio.printf("%u\n", Holder.answer()); }
EOF
( cd "$TMP" && "$ROOT/$XTC" -H "$ROOT" -q -A arm64 --emit-lib Bits.xc -o libBits.dylib ) 2>"$TMP/e1"
( cd "$TMP" && "$ROOT/$XTC" -H "$ROOT" -q -A arm64 -L "$TMP" bitsuser.xc -o bitsuser ) 2>>"$TMP/e1"
got=$("$TMP/bitsuser" 2>&1 | tail -1)
if [ "$got" = "42" ]; then
    echo "PASS  array-ivar export"
else
    echo "FAIL  array-ivar export (got '$got')"
    note "$(tail -2 "$TMP/e1")"
    fail=$((fail+1))
fi

# ── 2. the ARC return convention across the boundary ─────────────────────────
# The factory returns `new T`, so its own unit classifies it +1. The client has
# no body for it. Both sides must still agree, or the objects leak.
cat > "$TMP/Fact.xc" <<'EOF'
u16 gLive;

class Thing
{
    u16 tag;
    void init(void) { tag = (u16)0; gLive = gLive + (u16)1; }
    void dealloc(void) { gLive = gLive - (u16)1; }
    u16 value(void) { return tag; }
}

class Fact
{
    u8 _u;
    void init(void) { _u = (u8)0; }
    static Thing@ make(u16 t) { Thing@ p = new Thing(); p.tag = t; return p; }
    static u16 live(void) { return gLive; }
}
EOF
cat > "$TMP/factuser.xc" <<'EOF'
#import <Fact>
#import "Stdio.xc"
void main(void)
{
    for (u16 i = (u16)0; i < (u16)10; i = i + (u16)1) {
        Thing@ t = Fact.make(i);
        if (t.value() == (u16)999) Stdio.printf("never\n");
    }
    Stdio.printf("%u\n", Fact.live());
}
EOF
( cd "$TMP" && "$ROOT/$XTC" -H "$ROOT" -q -A arm64 --emit-lib Fact.xc -o libFact.dylib ) 2>"$TMP/e2"
( cd "$TMP" && "$ROOT/$XTC" -H "$ROOT" -q -A arm64 -L "$TMP" factuser.xc -o factuser ) 2>>"$TMP/e2"
live=$("$TMP/factuser" 2>&1 | tail -1)
if [ "$live" = "0" ]; then
    echo "PASS  ARC across the module boundary (0 live after 10 make/drop)"
else
    echo "FAIL  ARC across the module boundary: $live objects still live after 10 make/drop"
    note "the +1/+0 return convention is body-derived per unit and absent from"
    note "the interface, so the two sides disagree — see private:docs/Design/HANDOFF.md"
    fail=$((fail+1))
fi

#   3. THE EXPORT TRIE PAST 255 SYMBOLS. The Mach-O export trie is what dyld
#      consults for a two-level import, and it used to be built DEGENERATE —
#      one root node whose children were the whole symbol names. `childCount`
#      is one byte, so an image capped at 255 exports and the writer truncated
#      past it with a warning. The library still linked and type-checked; it
#      failed in the dynamic loader, at the library USER's run time, naming a
#      symbol the compiler had dropped. Any Foundation-importing library
#      exceeded it (private:docs/bugs/042).
python3 - "$TMP" <<'PYEOF'
import sys
tmp = sys.argv[1]
lines = ['#import "Foundation.xc"']
lines += [f"u32 trie_fn_{i:04d}(u32 v) {{ return v + (u32){i}; }}" for i in range(400)]
open(f"{tmp}/Trie.xc", "w").write("\n".join(lines) + "\n")
PYEOF
cat > "$TMP/trieuser.xc" <<'EOF'
#import <Trie>
#import "Stdio.xc"
void main(void)
{
    // Either side of the old 255-child cap, so a truncated trie cannot pass.
    Stdio.printf("%lu %lu %lu\n", trie_fn_0003((u32)0),
                 trie_fn_0254((u32)0), trie_fn_0399((u32)0));
}
EOF
trieerr=$("$ROOT/$XTC" -H "$ROOT" -q -A arm64 --emit-lib "$TMP/Trie.xc" -o "$TMP/libTrie.dylib" 2>&1 | grep -ci 'trunc' || true)
( cd "$TMP" && "$ROOT/$XTC" -H "$ROOT" -q -A arm64 -L "$TMP" trieuser.xc -o trieuser ) 2>>"$TMP/e2"
got=$("$TMP/trieuser" 2>&1 | tail -1)
if [ "$got" = "3 254 399" ] && [ "$trieerr" = "0" ]; then
    echo "PASS  export trie resolves past 255 symbols"
else
    echo "FAIL  export trie past 255 symbols: got '$got' (want '3 254 399'), truncation warnings=$trieerr"
    note "the trie is a PREFIX tree — the 255 limit is per NODE, not per image"
    fail=$((fail+1))
fi

# ── library metadata merges with a source import of the same functions ───────
# (XG bug 024.) A library compiles its imports IN, so its interface describes
# functions the client may ALSO import by source. The metadata proto meeting
# the source definition used to be "Redefinition of '_putc' with same
# parameter types" on the first out-of-tree library client; it must merge the
# way a C prototype meets its definition — the local declaration wins, and the
# .so satisfies the proto at load. The helper lives in its own include dir and
# the library SOURCE is kept out of the client's -I paths, because a reachable
# source file masks the metadata path entirely (the bare-name probe prefers
# source) — which is exactly why no in-tree client ever hit this.
mkdir -p "$TMP/inc024" "$TMP/lib024" "$TMP/cl024"
cat > "$TMP/inc024/Helper024.xc" <<'EOF'
u16 helperTwice(u16 v) { return v * (u16)2; }
EOF
cat > "$TMP/lib024/Shim.xc" <<'EOF'
#import "Helper024.xc"

class Shim
{
    u16 _u;
    static u16 four(void) { return helperTwice((u16)2); }
}
EOF
cat > "$TMP/cl024/shimuser.xc" <<'EOF'
#import "Stdio.xc"
#import "Helper024.xc"
#import <Shim>

void main(void)
{
    Stdio.printf("%u %u\n", Shim.four(), helperTwice((u16)3));
}
EOF
( cd "$TMP/lib024" && "$ROOT/$XTC" -H "$ROOT" -q -A arm64 -I "$TMP/inc024" --emit-lib Shim.xc -o libShim.dylib ) 2>"$TMP/e024"
( cd "$TMP/cl024" && "$ROOT/$XTC" -H "$ROOT" -q -A arm64 -I "$TMP/inc024" -L "$TMP/lib024" shimuser.xc -o shimuser ) 2>>"$TMP/e024"
got=$("$TMP/cl024/shimuser" 2>&1 | tail -1)
if [ "$got" = "4 6" ]; then
    echo "PASS  metadata + source import of the same functions merge"
else
    echo "FAIL  metadata/source import merge (got '$got', want '4 6')"
    note "$(grep -m2 'error' "$TMP/e024")"
    fail=$((fail+1))
fi

# ── the third-party tree: /opt/xcc/3p (private:docs/Design/third-party-libraries.md) ──
# One vendor = one subtree: <3p>/<vendor>/<arch>/lib<X>.so (a SYMLINK to the
# versioned artifact) + arch-neutral contract sources once at <vendor>/xc/.
# The client compiles with NO -L and NO -I: the bare `#import <Gadget3p>`
# probes the 3p tier, and the metadata hit adds acme's xc/ to the QUOTED
# import path for the whole TU — which must cover the TRANSITIVE case, a
# contract file importing its sibling. A bare name two vendors both provide
# is a hard error; the <vendor/lib> form resolves it.
mkdir -p "$TMP/3p/acme/arm64" "$TMP/3p/acme/xc" "$TMP/3p/rival/arm64" "$TMP/cl3p"
cat > "$TMP/Gadget3p.xc" <<'EOF'
u16 gadget3p_abi_1_0(void) { return (u16)7; }

class Gadget3p
{
    u16 _u;
    static u16 nine(void) { return (u16)9; }
}
EOF
cat > "$TMP/3p/acme/xc/G3pVersion.xc" <<'EOF'
u16 G3P_ABI_SYM(void) { return gadget3p_abi_1_0(); }
EOF
cat > "$TMP/3p/acme/xc/G3pAbi.xc" <<'EOF'
#import "G3pVersion.xc"

i32 gG3pPatch;

bool g3p_require(i32 minPatch)
{
    gG3pPatch = (i32)G3P_ABI_SYM();
    return gG3pPatch >= minPatch;
}
EOF
( cd "$TMP" && "$ROOT/$XTC" -H "$ROOT" -q -A arm64 --emit-lib Gadget3p.xc -o libGadget3p.dylib ) 2>"$TMP/e3p"
mv "$TMP/libGadget3p.dylib" "$TMP/3p/acme/arm64/libGadget3p-1-0.dylib"
ln -sf libGadget3p-1-0.dylib "$TMP/3p/acme/arm64/libGadget3p.dylib"
cat > "$TMP/cl3p/g3puser.xc" <<'EOF'
#import "Stdio.xc"
#import <Gadget3p>
#import "G3pAbi.xc"

void main(void)
{
    if (!g3p_require((i32)2)) { Stdio.printf("ABI too old\n"); return; }
    Stdio.printf("%u %ld\n", Gadget3p.nine(), gG3pPatch);
}
EOF
( cd "$TMP/cl3p" && XCC_3P="$TMP/3p" "$ROOT/$XTC" -H "$ROOT" -q -A arm64 g3puser.xc -o g3puser ) 2>>"$TMP/e3p"
got=$("$TMP/cl3p/g3puser" 2>&1 | tail -1)
if [ "$got" = "9 7" ]; then
    echo "PASS  3p tree: flag-free client, symlinked lib, transitive contract imports"
else
    echo "FAIL  3p tree (got '$got', want '9 7')"
    note "$(grep -m2 'error' "$TMP/e3p")"
    fail=$((fail+1))
fi
# Ambiguity: a second vendor providing the same bare name must be a hard
# error that names both vendors; the qualified form must still resolve.
cp "$TMP/3p/acme/arm64/libGadget3p-1-0.dylib" "$TMP/3p/rival/arm64/libGadget3p.dylib"
amberr=$( (cd "$TMP/cl3p" && XCC_3P="$TMP/3p" "$ROOT/$XTC" -H "$ROOT" -q -A arm64 g3puser.xc -o g3pamb) 2>&1 | grep -c "more than one third-party vendor" )
sed 's|<Gadget3p>|<acme/Gadget3p>|' "$TMP/cl3p/g3puser.xc" > "$TMP/cl3p/g3pqual.xc"
( cd "$TMP/cl3p" && XCC_3P="$TMP/3p" "$ROOT/$XTC" -H "$ROOT" -q -A arm64 g3pqual.xc -o g3pqual ) 2>"$TMP/e3q"
gotq=$("$TMP/cl3p/g3pqual" 2>&1 | tail -1)
if [ "$amberr" = "1" ] && [ "$gotq" = "9 7" ]; then
    echo "PASS  3p tree: bare-name ambiguity is a hard error; <vendor/lib> resolves it"
else
    echo "FAIL  3p ambiguity/qualified (amberr=$amberr, qualified got '$gotq')"
    note "$(grep -m2 'error' "$TMP/e3q")"
    fail=$((fail+1))
fi

# ── §4.2: a category on a class inside a PREBUILT library ────────────────────
# The NSString case. `class Base (Rep)` in the client adds a method to a class
# whose vtable was emitted when libCat42 was built — so the method cannot have a
# vtable slot, and taking one is not a subtle error: `b.rep()` read a word past
# the end of the library's table and jumped through it (SIGSEGV, exit 139).
# It dispatches through the CATEGORY CHAIN instead: vtable header word 2, whose
# null on any class this client never compiled falls back to the extended
# class's own table — which is right, because nothing built before the category
# existed can override it.
#
# The three answers are the three cases, and only the last one needs the chain:
#   b.rep()  Base made by the LIBRARY      → chain word null → Base$cat.rep
#   d.rep()  Derived made by the LIBRARY   → same table, and the who() inside it
#                                            still dispatches to Derived's own
#   s.rep()  Sub defined HERE, overriding  → Sub's chain word → Sub$cat.rep
cat > "$TMP/Cat42.xc" <<'EOF'
class Base { u16 v; void init(void){ v = (u16)10; } u16 who(void){ return v + (u16)1; } }
class Derived : Base { void init(void){ super.init(); } u16 who(void){ return v + (u16)2; } }
Base@ makeBase(void)    { return new Base(); }
Base@ makeDerived(void) { return new Derived(); }
EOF
cat > "$TMP/cat42user.xc" <<'EOF'
#import "Stdio.xc"
#import <Cat42>
class Base (Rep) { u16 rep(void) { return who() + (u16)1000; } }
class Sub : Base { void init(void){ super.init(); } u16 rep(void) { return who() + (u16)2000; } }
void main(void)
{
    Base@ b = makeBase();
    Base@ d = makeDerived();
    Base@ s = new Sub();
    Stdio.printf("%u %u %u\n", b.rep(), d.rep(), s.rep());
}
EOF
( cd "$TMP" && "$ROOT/$XTC" -H "$ROOT" -q -A arm64 --emit-lib Cat42.xc -o libCat42.dylib ) 2>"$TMP/e42"
( cd "$TMP" && "$ROOT/$XTC" -H "$ROOT" -q -A arm64 -L "$TMP" cat42user.xc -o cat42user ) 2>>"$TMP/e42"
got=$("$TMP/cat42user" 2>&1 | tail -1)
if [ "$got" = "1011 1012 2011" ]; then
    echo "PASS  category on a prebuilt .so class, overridden here (chain dispatch)"
else
    echo "FAIL  §4.2 category chain (got '$got', want '1011 1012 2011')"
    note "$(grep -m2 'error' "$TMP/e42")"
    fail=$((fail+1))
fi

# The refusals. Each is a layout the client cannot rewrite, so each has to be a
# diagnostic rather than a silent half-effect — and the first is the user's
# ruling that only the FINAL LINK may extend an imported class, which is what
# keeps chain depth unambiguous while there is no registry to arbitrate.
# Chain-slot numbering must not depend on how the class names SORT. A subclass
# whose name sorts before the class it extends (Alpha < Zoo) is its own override
# root, and keying "is this a chain method?" off the label alone left that root
# in the vtable slot space — so the same program worked or crashed according to
# a name. The rule is an ancestry walk, not a name comparison.
cat > "$TMP/Zoo.xc" <<'EOF'
class Zoo { u16 v; void init(void){ v = (u16)10; } u16 who(void){ return v + (u16)1; } }
Zoo@ makeZoo(void) { return new Zoo(); }
EOF
cat > "$TMP/zoouser.xc" <<'EOF'
#import "Stdio.xc"
#import <Zoo>
class Zoo (Rep) { u16 rep(void) { return who() + (u16)1000; } }
class Alpha : Zoo { void init(void){ super.init(); } u16 rep(void) { return who() + (u16)2000; } }
void main(void) { Stdio.printf("%u %u\n", makeZoo().rep(), ((Zoo@)new Alpha()).rep()); }
EOF
( cd "$TMP" && "$ROOT/$XTC" -H "$ROOT" -q -A arm64 --emit-lib Zoo.xc -o libZoo.dylib ) 2>"$TMP/ez"
( cd "$TMP" && "$ROOT/$XTC" -H "$ROOT" -q -A arm64 -L "$TMP" zoouser.xc -o zoouser ) 2>>"$TMP/ez"
got=$("$TMP/zoouser" 2>&1 | tail -1)
if [ "$got" = "1011 2011" ]; then
    echo "PASS  chain slots survive a subclass that sorts before its base"
else
    echo "FAIL  chain slot ordering (got '$got', want '1011 2011')"
    note "$(grep -m2 'error' "$TMP/ez")"
    fail=$((fail+1))
fi

cat > "$TMP/cat42dup.xc" <<'EOF'
#import "Stdio.xc"
#import <Cat42>
class Base (Clash) { u16 who(void) { return (u16)99; } }
void main(void) { Stdio.printf("%u\n", makeBase().who()); }
EOF
r2=$( (cd "$TMP" && "$ROOT/$XTC" -H "$ROOT" -q -A arm64 -L "$TMP" cat42dup.xc -o nope) 2>&1 \
      | grep -c "cannot replace 'Base.who'" )
if [ "$r2" = "1" ]; then
    echo "PASS  §4.2 refusal: a category may not replace an existing method"
else
    echo "FAIL  §4.2 replace refusal (got $r2, want 1)"
    fail=$((fail+1))
fi

# ── §4.3b: MULTIPLE independent extenders of one class ──────────────────────
# The former "only the final link may extend" ruling is lifted: each extender's
# tables carry an OWNER ANCHOR ($cat[0], the extender's own fallback table), and
# a dispatch site that meets another module's table falls back to its own base
# implementation — which is correct, because a class that never compiled against
# this category cannot override it. Here: a LIBRARY extends Zoo (RepL, with an
# overriding subclass), the APP extends Zoo too (RepM, ditto), and each of the
# six dispatches must pick the right body — including the two cross-extender
# receivers, which take the fallback.
cat > "$TMP/zooext.xc" <<'EOF'
#import <Zoo>
class Zoo (RepL) { u16 repL(void) { return who() + (u16)500; } }
class ZooLibSub : Zoo { void init(void){ super.init(); } u16 repL(void) { return who() + (u16)600; } }
Zoo@ makeZooLibSub(void) { return new ZooLibSub(); }
u16 callRepL(Zoo@ s) { return s.repL(); }
EOF
cat > "$TMP/zoomain.xc" <<'EOF'
#import "Stdio.xc"
#import <Zoo>
#import <ZooExt>
class Zoo (RepM) { u16 repM(void) { return who() + (u16)700; } }
class ZooAppSub : Zoo { void init(void){ super.init(); } u16 repM(void) { return who() + (u16)800; } }
u16 callRepM(Zoo@ s) { return s.repM(); }
void main(void)
{
    Zoo@ s = makeZoo();
    Zoo@ l = makeZooLibSub();
    Zoo@ m = (Zoo@)new ZooAppSub();
    Stdio.printf("%u %u %u %u %u %u\n",
        callRepL(s), callRepL(l), callRepL(m),
        callRepM(s), callRepM(l), callRepM(m));
    return;
}
EOF
( cd "$TMP" && "$ROOT/$XTC" -H "$ROOT" -q -A arm64 --emit-lib -L "$TMP" zooext.xc -o libZooExt.dylib ) 2>"$TMP/eze"
( cd "$TMP" && "$ROOT/$XTC" -H "$ROOT" -q -A arm64 -L "$TMP" zoomain.xc -o zoomain ) 2>>"$TMP/eze"
got=$("$TMP/zoomain" 2>&1 | tail -1)
if [ "$got" = "511 611 511 711 711 811" ]; then
    echo "PASS  two extenders of one class (library + app, ownership anchors)"
else
    echo "FAIL  §4.3b two extenders (got '$got', want '511 611 511 711 711 811')"
    note "$(grep -m2 'error' "$TMP/eze")"
    fail=$((fail+1))
fi

# A client OVERRIDING a chain method through the iface is refused: the iface
# carries `chain` but not the chain's shape, so the override could only be
# mis-slotted — and the extender's dispatch would silently never reach it.
cat > "$TMP/zoorogue.xc" <<'EOF'
#import <Zoo>
#import <ZooExt>
class Rogue : ZooLibSub { void init(void){ super.init(); } u16 repL(void) { return (u16)1; } }
void main(void) { return; }
EOF
r3=$( (cd "$TMP" && "$ROOT/$XTC" -H "$ROOT" -q -A arm64 -L "$TMP" zoorogue.xc -o rogue) 2>&1 \
      | grep -c "dispatched through another module's category chain" )
if [ "$r3" = "1" ]; then
    echo "PASS  §4.3b refusal: no overriding a chain method across an iface"
else
    echo "FAIL  §4.3b iface-override refusal (got $r3, want 1)"
    fail=$((fail+1))
fi

# ── a library that WRAPS external C is self-contained ───────────────────────
# The shape libtls has: an xtc library over a C shim plus a static archive. Both
# must land IN the .dylib, or the library exports the right symbols, loads, and
# fails on the first wrapped call. Two separate bugs made it fail that way:
# --emit-lib dropped -Wl objects and archives entirely (the driver resolved them
# for the executable path only), and dylibFromText: had no Branch26 case for a
# symbol DEFINED in the image — it only patched imports, because a dylib used to
# be one assembled unit whose branches the assembler had already resolved. The
# fixup stayed zero, which encodes `bl .`, so the call HUNG rather than crashing.
if command -v clang >/dev/null 2>&1 && command -v ar >/dev/null 2>&1; then
    cat > "$TMP/wshim.c" <<'EOF'
int _xt_w_read(int v);
int _xt_w_shim(int v) { return _xt_w_read(v) + 1; }
EOF
    cat > "$TMP/wcore.c" <<'EOF'
int _xt_w_read(int v) { return v * 2; }
EOF
    ( cd "$TMP" && clang -c wshim.c -o wshim.o && clang -c wcore.c -o wcore.o \
        && ar rcs libwcore.a wcore.o ) 2>/dev/null
    cat > "$TMP/Wrap.xc" <<'EOF'
i32 _xt_w_shim(i32 v);
class Wrap { static i32 go(i32 v) { return _xt_w_shim(v); } }
EOF
    cat > "$TMP/wcli.xc" <<'EOF'
#import "Stdio.xc"
#import <wrap>
i32 main(void) { Stdio.printf("%d\n", Wrap.go((i32)20)); return 0; }
EOF
    ( cd "$TMP" && "$ROOT/$XTC" -q -A arm64 --emit-lib Wrap.xc -o libwrap.dylib \
        -Wl,wshim.o -Wl,libwcore.a ) 2>"$TMP/w1.err"
    und=$(nm -u "$TMP/libwrap.dylib" 2>/dev/null | grep -c "_xt_w_" || true)
    if [ "$und" = 0 ]; then
        echo "PASS  --emit-lib bundles the -Wl shim object and archive member"
    else
        echo "FAIL  --emit-lib left $und wrapped C symbol(s) undefined"; fail=$((fail+1))
    fi
    ( cd "$TMP" && "$ROOT/$XTC" -q -A arm64 -L . wcli.xc -o wcli ) 2>"$TMP/w2.err"
    # A TIMEOUT is the point: the pre-fix failure was `bl .`, an infinite loop,
    # not a crash — so a plain run would hang the suite rather than fail it.
    out=$( cd "$TMP" && DYLD_LIBRARY_PATH=. perl -e 'alarm 30; exec "./wcli"' 2>/dev/null )
    if [ "$out" = "41" ]; then
        echo "PASS  a call through the wrapped C runs (got 41)"
    else
        echo "FAIL  wrapped-C call (got '$out', want 41)"; fail=$((fail+1))
    fi
fi

echo "--- native-arm64: $fail failing ---"
[ "$fail" = 0 ]
