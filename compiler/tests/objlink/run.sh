#!/usr/bin/env bash
# objlink/run.sh — separate compilation end to end: compile each module to its
# own object, then link the objects into a program.
#
# This is the property stages 1 and 2 of private:docs/Design/separate-compilation.md
# exist to provide, and it is not something the corpus can express: every corpus
# fixture is one translation unit, so nothing there would notice if `-c` started
# emitting an executable again, or if cross-function DCE deleted a helper that
# only another object calls (it did, before the codegen learned `--object`).
#
# Checks, in order:
#   1. `-c` produces a real Mach-O OBJECT — not an executable with a .o name,
#      which is the failure mode this whole stage exists to end.
#   2. A helper nothing in its own module calls still EXPORTS. Per-object DCE
#      would remove it; an object's surface is not its own call graph.
#   3. The caller's reference to it stays UNDEFINED — the binding is the
#      linker's job, which is what makes the file relocatable.
#   4. Our linker turns the two objects into a program that runs and prints 9.
#   5. Apple's ld reads our object too — an independent check that the file is
#      a real object rather than merely one we can read back.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
XCC="bin/osx/xcc"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail=0
ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1"; fail=1; }

cat > "$W/modA.xc" <<'EOF'
u16 helperA(u16 x) { return x + (u16)5; }
EOF
cat > "$W/modMain.xc" <<'EOF'
#import "Stdio.xc"
u16 helperA(u16 x);
void main(void) { Stdio.printf("%lu\n", (u32)helperA((u16)4)); return; }
EOF

"$XCC" -q -A arm64 -c "$W/modA.xc"    -o "$W/modA.o"    2>"$W/a.err" || { bad "compile modA"; cat "$W/a.err"; exit 1; }
"$XCC" -q -A arm64 -c "$W/modMain.xc" -o "$W/modMain.o" 2>"$W/m.err" || { bad "compile modMain"; cat "$W/m.err"; exit 1; }

file "$W/modA.o" | grep -q "Mach-O 64-bit object arm64" \
  && ok "-c emits an object (not an executable)" || bad "-c emits an object (not an executable)"

nm "$W/modA.o" | grep -q "T _helperA" \
  && ok "an uncalled helper still exports" || bad "an uncalled helper still exports"

nm "$W/modMain.o" | grep -q "U _helperA" \
  && ok "the caller's reference stays undefined" || bad "the caller's reference stays undefined"

if "$XCC" -q -A arm64 "$W/modMain.o" "$W/modA.o" -o "$W/prog" 2>"$W/l.err"; then
    out="$("$W/prog" 2>/dev/null)"
    [ "$out" = "9" ] && ok "linked program runs (got 9)" || bad "linked program runs (got '$out', want 9)"
else
    bad "link two objects"; cat "$W/l.err"
fi

# ── cross-object tentative GLOBAL: two units each declare `u32 gShared;` (a C
# tentative definition). They must merge to ONE slot across separately-compiled
# objects — the setter's write is the reader's read (c2xc bug 36, cross-object).
# Uninitialised file-scope globals are emitted as COMMON symbols for this.
cat > "$W/gSet.xc" <<'EOF'
u32 gShared;
void gset(u32 v) { gShared = v; }
EOF
cat > "$W/gGet.xc" <<'EOF'
u32 gShared;
u32 gget(void) { return gShared; }
EOF
cat > "$W/gMain.xc" <<'EOF'
#import "Stdio.xc"
void gset(u32 v);
u32 gget(void);
void main(void) { gset((u32)42); Stdio.printf("%lu\n", gget()); return; }
EOF
"$XCC" -q -A arm64 -c "$W/gSet.xc"  -o "$W/gSet.o"  2>"$W/gs.err" || { bad "compile gSet"; cat "$W/gs.err"; }
"$XCC" -q -A arm64 -c "$W/gGet.xc"  -o "$W/gGet.o"  2>"$W/gg.err" || { bad "compile gGet"; cat "$W/gg.err"; }
"$XCC" -q -A arm64 -c "$W/gMain.xc" -o "$W/gMain.o" 2>"$W/gm.err" || { bad "compile gMain"; cat "$W/gm.err"; }
nm "$W/gSet.o" | grep -q "C _gShared"   && ok "a tentative global is a COMMON symbol" || bad "a tentative global is a COMMON symbol"
if "$XCC" -q -A arm64 "$W/gMain.o" "$W/gSet.o" "$W/gGet.o" -o "$W/gprog" 2>"$W/gl.err"; then
    out="$("$W/gprog" 2>/dev/null)"
    [ "$out" = "42" ] && ok "cross-object global shares one slot (got 42)"                       || bad "cross-object global shares one slot (got '$out', want 42)"
else
    bad "link three objects sharing a global"; cat "$W/gl.err"
fi

# ── stage 3: compiling against the INTERFACE, with no source and no .so ──
# `xcc -c` leaves <out>.xtc.iface beside the object; it is the header xtc
# otherwise lacks. The client below never sees Shape's body.
cat > "$W/ShapeMod.xc" <<'EOF'
class Shape {
    u16 w;
    u16 h;
    void init(void) { w = (u16)3; h = (u16)4; }
    u16 area(void) { return w * h; }
}
class Base {
    u16 v;
    void init(void) { v = (u16)10; }
    u16 who(void) { return v + (u16)1; }
}
class Derived : Base {
    void init(void) { super.init(); }
    u16 who(void) { return v + (u16)2; }
}
Base@ makeDerived(void) { return new Derived(); }
EOF
cat > "$W/useShape.xc" <<'EOF'
#import "Stdio.xc"
#import <ShapeMod>
void main(void)
{
    Shape@ s = new Shape();
    Base@ b = new Base();
    Base@ d = makeDerived();
    Stdio.printf("%lu %lu %lu\n", (u32)s.area(), (u32)b.who(), (u32)d.who());
    return;
}
EOF
"$XCC" -q -A arm64 -c "$W/ShapeMod.xc" -o "$W/ShapeMod.o" 2>"$W/s.err" || { bad "compile ShapeMod"; cat "$W/s.err"; }
[ -f "$W/ShapeMod.xtc.iface" ] && ok "-c writes the .xtc.iface sidecar" \
                               || bad "-c writes the .xtc.iface sidecar"

# The client resolves `#import <ShapeMod>` to the bare interface on the -L path.
if "$XCC" -q -A arm64 -c -L "$W" "$W/useShape.xc" -o "$W/useShape.o" 2>"$W/u.err"; then
    ok "a client compiles against the interface alone"
else
    bad "a client compiles against the interface alone"; cat "$W/u.err"
fi

# 12 = 3*4 (plain call), 11 = Base.who, 12 = Derived.who — the last is the one
# that matters: virtual dispatch across an object boundary only lands correctly
# if the client ADOPTED the defining module's slot numbering instead of
# re-deriving its own.
if "$XCC" -q -A arm64 "$W/useShape.o" "$W/ShapeMod.o" -o "$W/shapeprog" 2>"$W/sl.err"; then
    out="$("$W/shapeprog" 2>/dev/null)"
    [ "$out" = "12 11 12" ] && ok "virtual dispatch across objects (got '$out')" \
                            || bad "virtual dispatch across objects (got '$out', want '12 11 12')"
else
    bad "link client + module"; cat "$W/sl.err"
fi

# ── stage 4: categories and extensions ───────────────────────────────────
# `class S (Name)` adds methods; `class S ()` may also add ivars, but only where
# the class itself is being compiled. Both merge into the class, so the parts
# must NOT survive as separate declarations — four passes walk that list, and
# the one that forgets to skip a spent part lowers the same method twice and
# dies on "append after terminator".
cat > "$W/cat.xc" <<'EOF'
#import "Stdio.xc"
class Sh {
    u16 w;
    void init(void) { w = (u16)6; }
    u16 area(void) { return w * w; }
}
class Sh (Drawing) { u16 drawn(void) { return area() + (u16)100; } }
class Sh () { u16 extra; u16 withExtra(void) { return w + extra; } }
void main(void)
{
    Sh@ s = new Sh();
    s.extra = (u16)7;
    Stdio.printf("%lu %lu %lu\n", (u32)s.area(), (u32)s.drawn(), (u32)s.withExtra());
    return;
}
EOF
if "$XCC" -q -A arm64 "$W/cat.xc" -o "$W/cat" 2>"$W/cat.err"; then
    out="$("$W/cat" 2>/dev/null)"
    [ "$out" = "36 136 13" ] && ok "category + extension merge (got '$out')" \
                             || bad "category + extension merge (got '$out', want '36 136 13')"
else
    bad "compile category + extension"; cat "$W/cat.err"
fi

# A category on a class that lives in ANOTHER object: methods only, and the
# call has to reach the imported class's own method too.
cat > "$W/useCat.xc" <<'EOF'
#import "Stdio.xc"
#import <ShapeMod>
class Shape (Report) { u16 report(void) { return area() + (u16)1000; } }
void main(void)
{
    Shape@ s = new Shape();
    Stdio.printf("%lu %lu\n", (u32)s.area(), (u32)s.report());
    return;
}
EOF
if "$XCC" -q -A arm64 -c -L "$W" "$W/useCat.xc" -o "$W/useCat.o" 2>"$W/uc.err" \
   && "$XCC" -q -A arm64 "$W/useCat.o" "$W/ShapeMod.o" -o "$W/catprog" 2>>"$W/uc.err"; then
    out="$("$W/catprog" 2>/dev/null)"
    [ "$out" = "12 1012" ] && ok "category on a class from another object (got '$out')" \
                           || bad "category on another object's class (got '$out', want '12 1012')"
else
    bad "category across objects"; cat "$W/uc.err"
fi

# ── §4.3b: TWO objects each extend the same imported class ────────────────
# Formerly a linker error ("only one may"). Ownership anchors lift it: each
# extender's tables carry $cat[0] = its own fallback's address, and a dispatch
# that meets the OTHER module's table falls back to its own base impl — the
# right answer, since a class that never compiled against this category cannot
# override it. Six dispatches; the two cross-extender receivers take the
# fallback (111 and 311).
cat > "$W/ShapeMod2.xc" <<'EOF'
class Shape2 { u16 v; void init(void) { v = (u16)10; } u16 who(void) { return v + (u16)1; } }
Shape2@ makeShape2(void) { return new Shape2(); }
EOF
cat > "$W/extA2.xc" <<'EOF'
#import <ShapeMod2>
class Shape2 (RepA) { u16 repA(void) { return who() + (u16)100; } }
class SubA : Shape2 { void init(void) { super.init(); } u16 repA(void) { return who() + (u16)200; } }
Shape2@ makeSubA(void) { return new SubA(); }
u16 callRepA(Shape2@ s) { return s.repA(); }
EOF
cat > "$W/extB2.xc" <<'EOF'
#import <ShapeMod2>
class Shape2 (RepB) { u16 repB(void) { return who() + (u16)300; } }
class SubB : Shape2 { void init(void) { super.init(); } u16 repB(void) { return who() + (u16)400; } }
Shape2@ makeSubB(void) { return new SubB(); }
u16 callRepB(Shape2@ s) { return s.repB(); }
EOF
cat > "$W/mainAB2.xc" <<'EOF'
#import "Stdio.xc"
#import <ShapeMod2>
Shape2@ makeSubA(void); u16 callRepA(Shape2@ s);
Shape2@ makeSubB(void); u16 callRepB(Shape2@ s);
void main(void)
{
    Shape2@ s = makeShape2();
    Shape2@ a = makeSubA();
    Shape2@ b = makeSubB();
    Stdio.printf("%u %u %u %u %u %u\n",
        callRepA(s), callRepA(a), callRepA(b),
        callRepB(s), callRepB(a), callRepB(b));
    return;
}
EOF
if "$XCC" -q -A arm64 -c "$W/ShapeMod2.xc" -o "$W/ShapeMod2.o" 2>"$W/ab.err" \
   && "$XCC" -q -A arm64 -c -L "$W" "$W/extA2.xc" -o "$W/extA2.o" 2>>"$W/ab.err" \
   && "$XCC" -q -A arm64 -c -L "$W" "$W/extB2.xc" -o "$W/extB2.o" 2>>"$W/ab.err" \
   && "$XCC" -q -A arm64 -c -L "$W" "$W/mainAB2.xc" -o "$W/mainAB2.o" 2>>"$W/ab.err" \
   && "$XCC" -q -A arm64 "$W/mainAB2.o" "$W/extA2.o" "$W/extB2.o" "$W/ShapeMod2.o" -o "$W/progAB2" 2>>"$W/ab.err"; then
    out="$("$W/progAB2" 2>/dev/null)"
    [ "$out" = "111 211 111 311 311 411" ] && ok "two objects extend one class (ownership anchors, got '$out')" \
        || bad "§4.3b two-object extenders (got '$out', want '111 211 111 311 311 411')"
else
    bad "§4.3b two-object extenders: build failed"; cat "$W/ab.err"
fi

# The SAME category name in two modules is the one collision left, and it is
# a diagnostic, not a first-wins mis-dispatch.
cat > "$W/dupA2.xc" <<'EOF'
#import <ShapeMod2>
class Shape2 (Rep) { u16 rx(void) { return who() + (u16)1; } }
class DupSubA : Shape2 { void init(void) { super.init(); } u16 rx(void) { return (u16)0; } }
u16 useDA(void) { Shape2@ s = new DupSubA(); return s.rx(); }
EOF
cat > "$W/dupB2.xc" <<'EOF'
#import <ShapeMod2>
class Shape2 (Rep) { u16 ry(void) { return who() + (u16)2; } }
class DupSubB : Shape2 { void init(void) { super.init(); } u16 ry(void) { return (u16)0; } }
u16 useDB(void) { Shape2@ s = new DupSubB(); return s.ry(); }
EOF
cat > "$W/dmain2.xc" <<'EOF'
u16 useDA(void); u16 useDB(void);
void main(void) { useDA(); useDB(); return; }
EOF
"$XCC" -q -A arm64 -c -L "$W" "$W/dupA2.xc" -o "$W/dupA2.o" 2>/dev/null
"$XCC" -q -A arm64 -c -L "$W" "$W/dupB2.xc" -o "$W/dupB2.o" 2>/dev/null
"$XCC" -q -A arm64 -c "$W/dmain2.xc" -o "$W/dmain2.o" 2>/dev/null
if "$XCC" -q -A arm64 "$W/dmain2.o" "$W/dupA2.o" "$W/dupB2.o" "$W/ShapeMod2.o" -o "$W/dprog2" 2>"$W/dup.err"; then
    bad "same-named category in two modules LINKED (must be refused)"
else
    grep -q "two modules define category 'Rep'" "$W/dup.err" \
        && ok "same-named category in two modules is diagnosed" \
        || { bad "same-name category: wrong diagnostic"; cat "$W/dup.err"; }
fi

# ── plain subclassing across objects ─────────────────────────────────────
# Not categories at all, and it failed for longer: `-c` did not set
# libraryBuild, so Mod.xc — compiled as a whole program in which nothing
# overrides who() — devirtualised it and emitted NO vtable. The client then
# overrides it, decides Base3 dispatches, and references a `Base3$vtbl` that
# exists nowhere. That is a LOAD failure ("Symbol not found"), not a link one,
# so every build looked fine. Fixed by treating a `-c` object as not-whole,
# exactly as `--emit-lib` already did.
cat > "$W/subBase.xc" <<'EOF'
class Base3
{
    u16 who(void) { return (u16)11; }
    u16 ask(void) { return self.who(); }
}
EOF
cat > "$W/subCli.xc" <<'EOF'
#import "Stdio.xc"
#import <subBase>
class Sub3 : Base3 { u16 who(void) { return (u16)22; } }
i32 main(void)
{
    Base3* b = new Sub3();
    Stdio.printf("%d\n", b.ask());       // 22 — through the override, not 11
    return 0;
}
EOF
if "$XCC" -q -A arm64 -c "$W/subBase.xc" -o "$W/subBase.o" 2>"$W/sb.err" \
   && "$XCC" -q -A arm64 -c -L "$W" "$W/subCli.xc" -o "$W/subCli.o" 2>>"$W/sb.err" \
   && "$XCC" -q -A arm64 "$W/subCli.o" "$W/subBase.o" -o "$W/subprog" 2>>"$W/sb.err"; then
    out="$("$W/subprog" 2>&1 | head -1)"
    [ "$out" = "22" ] && ok "a subclass overriding a method from another object (got 22)" \
        || bad "cross-object subclass (got '$out', want 22)"
else
    bad "cross-object subclass: build failed"; head -3 "$W/sb.err"
fi

# ── an object that `#import <Lib>`s carries the dependency ───────────────
# `#import <Lib>` is a FRONT-END fact, and an object link has no front end, so
# the link could not know the program needed the library at all. It did not fail
# at link — the undefined symbols resolve against the .so quite happily — it
# failed at LOAD with "Symbol not found", because no LC_LOAD_DYLIB was recorded.
# The list now rides beside the object as `<out>.xtc.needs`, like the interface
# and the IR.
cat > "$W/nBits.xc" <<'EOF'
class NBits { static u16 twice(u16 v) { return v * (u16)2; } }
EOF
cat > "$W/nMod.xc" <<'EOF'
#import <nBits>
u16 nDouble(u16 v) { return NBits.twice(v); }
EOF
cat > "$W/nMain.xc" <<'EOF'
#import "Stdio.xc"
u16 nDouble(u16 v);
i32 main(void) { Stdio.printf("%d\n", nDouble((u16)21)); return 0; }
EOF
if "$XCC" -q -A arm64 --emit-lib "$W/nBits.xc" -o "$W/libnBits.dylib" 2>"$W/nb.err" \
   && "$XCC" -q -A arm64 -L "$W" -c "$W/nMod.xc" -o "$W/nMod.o" 2>>"$W/nb.err" \
   && "$XCC" -q -A arm64 -c "$W/nMain.xc" -o "$W/nMain.o" 2>>"$W/nb.err"; then
    grep -q "libnBits" "$W/nMod.xtc.needs" 2>/dev/null \
        && ok "-c records its #import <Lib> list beside the object" \
        || bad "no .xtc.needs sidecar (got '$(cat "$W/nMod.xtc.needs" 2>/dev/null)')"
    if "$XCC" -q -A arm64 "$W/nMain.o" "$W/nMod.o" -o "$W/nprog" 2>>"$W/nb.err"; then
        otool -L "$W/nprog" 2>/dev/null | grep -q nBits \
            && ok "an object link records LC_LOAD_DYLIB for the imported library" \
            || bad "object link recorded no dependency on libnBits"
        out="$("$W/nprog" 2>&1 | head -1)"
        [ "$out" = "42" ] && ok "a program linked from objects loads its library (got 42)" \
            || bad "cross-object library load (got '$out', want 42)"
    else
        bad "link objects that import a library"; head -3 "$W/nb.err"
    fi
else
    bad "build objects that import a library"; head -3 "$W/nb.err"
fi

# ── §4.2: a category method that is OVERRIDDEN here ──────────────────────
# The case above works because nothing overrides `report`, so it keeps a direct
# call. Add a subclass that overrides it and the method needs runtime dispatch —
# and it cannot have a vtable slot, because ShapeMod.o's vtables were laid out
# before this file existed. It took one anyway, and `b.rep()` read a word past
# the end of Base$vtbl and jumped through it (SIGSEGV). It goes through the
# CATEGORY CHAIN now: vtable header word 2, null on every class this unit did
# not compile, falling back to the extended class's own table.
#   1011 = Base.who + 1000 (library object, null chain → Base$cat)
#   1012 = Derived.who + 1000 (ditto, and who() still finds Derived's override)
#   2011 = Sub.rep, reached through Sub's own chain word
cat > "$W/catBase.xc" <<'EOF'
class Base2 { u16 v; void init(void){ v = (u16)10; } u16 who(void){ return v + (u16)1; } }
class Derived2 : Base2 { void init(void){ super.init(); } u16 who(void){ return v + (u16)2; } }
Base2@ makeBase2(void)    { return new Base2(); }
Base2@ makeDerived2(void) { return new Derived2(); }
EOF
cat > "$W/catOver.xc" <<'EOF'
#import "Stdio.xc"
#import <catBase>
class Base2 (Rep) { u16 rep(void) { return who() + (u16)1000; } }
class Sub2 : Base2 { void init(void){ super.init(); } u16 rep(void) { return who() + (u16)2000; } }
void main(void)
{
    Base2@ b = makeBase2();
    Base2@ d = makeDerived2();
    Base2@ s = new Sub2();
    Stdio.printf("%lu %lu %lu\n", (u32)b.rep(), (u32)d.rep(), (u32)s.rep());
    return;
}
EOF
if "$XCC" -q -A arm64 -c "$W/catBase.xc" -o "$W/catBase.o" 2>"$W/cb.err" \
   && "$XCC" -q -A arm64 -c -L "$W" "$W/catOver.xc" -o "$W/catOver.o" 2>>"$W/cb.err" \
   && "$XCC" -q -A arm64 "$W/catOver.o" "$W/catBase.o" -o "$W/catover" 2>>"$W/cb.err"; then
    out="$("$W/catover" 2>/dev/null)"
    [ "$out" = "1011 1012 2011" ] && ok "an overridden category method dispatches through the chain" \
        || bad "category chain dispatch (got '$out', want '1011 1012 2011')"
else
    bad "category chain dispatch: build failed"; cat "$W/cb.err"
fi

# TWO objects extending one class — formerly a linker refusal (before the
# refusal existed, the second `B$cat` silently overwrote the first and
# `b.two()` ran `one`'s body). §4.3b's ownership anchors make it WORK: each
# extender's fallback table is named by its category (`Base2$cat$One` /
# `Base2$cat$Two`), so nothing collides, and each dispatch compares the
# receiver's chain-table owner word against its own anchor.
cat > "$W/twoA.xc" <<'EOF'
#import <catBase>
class Base2 (One) { u16 one(void) { return who() + (u16)100; } }
class T1 : Base2 { void init(void){ super.init(); } u16 one(void) { return who() + (u16)200; } }
u16 useOne(Base2@ b) { return b.one(); }
EOF
cat > "$W/twoB.xc" <<'EOF'
#import "Stdio.xc"
#import <catBase>
class Base2 (Two) { u16 two(void) { return who() + (u16)300; } }
class T2 : Base2 { void init(void){ super.init(); } u16 two(void) { return who() + (u16)400; } }
u16 useOne(Base2@ b);
void main(void) { Base2@ b = makeBase2(); Stdio.printf("%lu %lu\n", (u32)useOne(b), (u32)b.two()); return; }
EOF
"$XCC" -q -A arm64 -c -L "$W" "$W/twoA.xc" -o "$W/twoA.o" 2>/dev/null
"$XCC" -q -A arm64 -c -L "$W" "$W/twoB.xc" -o "$W/twoB.o" 2>/dev/null
if "$XCC" -q -A arm64 "$W/twoB.o" "$W/twoA.o" "$W/catBase.o" -o "$W/two" 2>"$W/two.err"; then
    out="$("$W/two" 2>/dev/null)"
    [ "$out" = "111 311" ] && ok "two modules extend one class (differently-named categories, got '$out')" \
        || bad "two-extender link ran wrong (got '$out', want '111 311')"
else
    bad "two modules with differently-named categories must LINK now (§4.3b)"; cat "$W/two.err"
fi

# The refusals matter as much as the acceptances: each is a rule that keeps a
# layout honest, and a silent acceptance would corrupt an instance.
refuses() {  # <file> <expected substring> <label>
    if "$XCC" -q -A arm64 -L "$W" "$1" -o "$W/none" 2>&1 | grep -q "$2"; then ok "$3"; else bad "$3"; fi
}
printf 'class S { u16 w; void init(void){w=(u16)1;} }\nclass S (Bad) { u16 extra; }\nvoid main(void){return;}\n' > "$W/e1.xc"
refuses "$W/e1.xc" "cannot add instance variables" "a category may not add ivars"
printf 'class Nope (Cat) { u16 f(void){return (u16)1;} }\nvoid main(void){return;}\n' > "$W/e2.xc"
refuses "$W/e2.xc" "extends unknown class" "extending a class not in scope is refused"
printf '#import "Stdio.xc"\n#import <ShapeMod>\nclass Shape () { u16 more; }\nvoid main(void){return;}\n' > "$W/e3.xc"
refuses "$W/e3.xc" "instance size is already fixed" "an extension may not add ivars across a module"

# ── stage 5: -flto, recompiling from the IR each object carries ──────────
# `-c` leaves <out>.xtc.ir beside the object; `-flto` merges those and compiles
# them as ONE module, so the inliner sees across object boundaries again. The
# assertion is behavioural — same answer as the plain link — because that is
# what must not regress; the inlining itself is visible as `bl _helperA`
# disappearing from the merged assembly.
[ -f "$W/modA.xtc.ir" ] && ok "-c carries the module IR" || bad "-c carries the module IR"
if "$XCC" -q -A arm64 -flto "$W/modMain.o" "$W/modA.o" -o "$W/lto" 2>"$W/lto.err"; then
    out="$("$W/lto" 2>/dev/null)"
    [ "$out" = "9" ] && ok "-flto links and runs (got 9)" \
                     || bad "-flto links and runs (got '$out', want 9)"
else
    bad "-flto link"; cat "$W/lto.err"
fi
# Without a sidecar it must say so rather than silently dropping to a plain link:
# a quiet fallback is how an optimisation feature becomes a no-op nobody notices.
rm -f "$W/modA.xtc.ir"
"$XCC" -q -A arm64 -flto "$W/modMain.o" "$W/modA.o" -o "$W/lto2" 2>&1 \
  | grep -q "needs" && ok "-flto without carried IR is refused loudly" \
                    || bad "-flto without carried IR is refused loudly"

# ── x86_64: the same two stages, in ELF ──────────────────────────────────
# `-c` writes an ET_REL through XTElfWriter and the linker merges `.o` inputs
# the way the arm64 one does. The structural checks are done by parsing the
# file here rather than with nm/readelf, which a macOS host does not have for
# ELF — and which would make the check silently vanish on the machine that
# actually builds these.
elfchk() {   # <file> <symbol> -> prints "type=<e_type> <symbol>=<T|U|absent>"
    python3 - "$1" "$2" <<'PYEOF'
import struct, sys
b = open(sys.argv[1],'rb').read(); want = sys.argv[2]
if b[:4] != b'\x7fELF': print("type=notelf"); raise SystemExit
etype, = struct.unpack_from('<H', b, 16)
shoff, = struct.unpack_from('<Q', b, 40)
shent, shnum, shstr = struct.unpack_from('<HHH', b, 58)
secs = [struct.unpack_from('<IIQQQQIIQQ', b, shoff+i*shent) for i in range(shnum)]
state = 'absent'
for s in secs:
    if s[1] != 2: continue                      # SHT_SYMTAB
    stroff = secs[s[6]][4]
    for o in range(s[4], s[4]+s[5], 24):
        nm, info, other, shndx, val, sz = struct.unpack_from('<IBBHQQ', b, o)
        end = b.index(b'\0', stroff+nm)
        if b[stroff+nm:end].decode() == want:
            state = 'U' if shndx == 0 else ('T' if (info & 0xf) == 2 else 'D')
print(f"type={etype} {want}={state}")
PYEOF
}
"$XCC" -q -A x86_64 -c "$W/modA.xc"    -o "$W/modA-x86.o"    2>"$W/xa.err"
"$XCC" -q -A x86_64 -c "$W/modMain.xc" -o "$W/modMain-x86.o" 2>>"$W/xa.err"
if [ -f "$W/modA-x86.o" ] && [ -f "$W/modMain-x86.o" ]; then
    [ "$(elfchk "$W/modA-x86.o" helperA)" = "type=1 helperA=T" ] \
        && ok "x86_64 -c emits an ET_REL that defines its helper" \
        || bad "x86_64 -c object: $(elfchk "$W/modA-x86.o" helperA)"
    [ "$(elfchk "$W/modMain-x86.o" helperA)" = "type=1 helperA=U" ] \
        && ok "x86_64 caller's reference stays undefined" \
        || bad "x86_64 undefined ref: $(elfchk "$W/modMain-x86.o" helperA)"
else
    bad "x86_64 -c produced no object"; cat "$W/xa.err"
fi
if "$XCC" -q -A x86_64 "$W/modMain-x86.o" "$W/modA-x86.o" -o "$W/xprog" 2>"$W/xl.err"; then
    # Built here, run over there: this host builds x86-64 ELF but cannot execute
    # it. An unreachable Linux box means the RUN is not covered — say so, rather
    # than let a skipped run read as a pass.
    XH="${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}"
    if ssh -o ConnectTimeout=8 -o BatchMode=yes "$XH" true 2>/dev/null; then
        scp -q "$W/xprog" "$XH:/tmp/xtc-objlink-$$" 2>/dev/null
        out="$(ssh -o BatchMode=yes "$XH" "chmod +x /tmp/xtc-objlink-$$ && /tmp/xtc-objlink-$$; rm -f /tmp/xtc-objlink-$$" 2>/dev/null)"
        [ "$out" = "9" ] && ok "x86_64 linked program runs on $XH (got 9)" \
                         || bad "x86_64 linked program (got '$out', want 9)"
    else
        echo "SKIP  x86_64 run — no Linux host at '$XH' (build was checked, EXECUTION WAS NOT)"
    fi
else
    bad "x86_64 link two objects"; cat "$W/xl.err"
fi

# Stages 3 and 4 on x86_64 too — the same sources the arm64 half uses. Worth
# repeating rather than trusting shared machinery: the interface, the adopted
# slot numbering and the §4.2 chain are all arch-neutral IR, so if they were
# going to differ per target it would be through the backend, which is exactly
# what a second target checks.
"$XCC" -q -A x86_64 -c "$W/catBase.xc" -o "$W/catBase-x86.o" 2>"$W/xc.err"
"$XCC" -q -A x86_64 -c -L "$W" "$W/catOver.xc" -o "$W/catOver-x86.o" 2>>"$W/xc.err"
if "$XCC" -q -A x86_64 "$W/catOver-x86.o" "$W/catBase-x86.o" -o "$W/xcat" 2>>"$W/xc.err"; then
    XH="${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}"
    if ssh -o ConnectTimeout=8 -o BatchMode=yes "$XH" true 2>/dev/null; then
        scp -q "$W/xcat" "$XH:/tmp/xtc-objcat-$$" 2>/dev/null
        out="$(ssh -o BatchMode=yes "$XH" "chmod +x /tmp/xtc-objcat-$$ && /tmp/xtc-objcat-$$; rm -f /tmp/xtc-objcat-$$" 2>/dev/null)"
        [ "$out" = "1011 1012 2011" ] \
            && ok "x86_64 interface + category chain across objects (got '$out')" \
            || bad "x86_64 category chain (got '$out', want '1011 1012 2011')"
    else
        echo "SKIP  x86_64 category-chain run — no Linux host at '$XH' (EXECUTION WAS NOT CHECKED)"
    fi
else
    bad "x86_64 category-chain link"; cat "$W/xc.err"
fi

# -flto on x86_64: same carried IR, same merge, same "refuse loudly when a
# sidecar is missing" — an optimisation that quietly degrades to a plain link
# is one nobody notices has stopped working.
if "$XCC" -q -A x86_64 -flto "$W/modMain-x86.o" "$W/modA-x86.o" -o "$W/xlto" 2>"$W/xlto.err"; then
    XH="${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}"
    if ssh -o ConnectTimeout=8 -o BatchMode=yes "$XH" true 2>/dev/null; then
        scp -q "$W/xlto" "$XH:/tmp/xtc-xlto-$$" 2>/dev/null
        out="$(ssh -o BatchMode=yes "$XH" "chmod +x /tmp/xtc-xlto-$$ && /tmp/xtc-xlto-$$; rm -f /tmp/xtc-xlto-$$" 2>/dev/null)"
        [ "$out" = "9" ] && ok "x86_64 -flto links and runs (got 9)" \
                         || bad "x86_64 -flto (got '$out', want 9)"
    else
        echo "SKIP  x86_64 -flto run — no Linux host at '$XH' (EXECUTION WAS NOT CHECKED)"
    fi
else
    bad "x86_64 -flto link"; cat "$W/xlto.err"
fi

# ── win64: the same two stages, in COFF/PE ───────────────────────────────
# The third container. COFF has no explicit addend field — the addend lives
# INLINE in the patched bytes and REL32 implies a +4 — so this is the one
# target where the writer had to transform what the assembler produced rather
# than copy it, which is exactly why it earns its own run rather than being
# assumed from x86_64's (same assembler, same backend, different container).
coffchk() {  # <file> -> prints "coff <nsections>" or "notcoff"
    python3 - "$1" <<'PYEOF'
import struct, sys
b = open(sys.argv[1],'rb').read()
if len(b) < 20 or struct.unpack_from('<H',b,0)[0] != 0x8664: print("notcoff"); raise SystemExit
nsect, = struct.unpack_from('<H', b, 2)
opt,   = struct.unpack_from('<H', b, 16)          # SizeOfOptionalHeader: 0 => object
print(f"{'coff' if opt == 0 else 'image'} {nsect}")
PYEOF
}
"$XCC" -q -A win64 -c "$W/modA.xc"    -o "$W/modA-win.o"    2>"$W/wa.err"
"$XCC" -q -A win64 -c "$W/modMain.xc" -o "$W/modMain-win.o" 2>>"$W/wa.err"
if [ -f "$W/modA-win.o" ]; then
    [ "$(coffchk "$W/modA-win.o")" = "coff 2" ] \
        && ok "win64 -c emits a bare COFF object (.text + .data)" \
        || bad "win64 -c object: $(coffchk "$W/modA-win.o")"
else
    bad "win64 -c produced no object"; cat "$W/wa.err"
fi
"$XCC" -q -A win64 -c "$W/catBase.xc" -o "$W/catBase-win.o" 2>>"$W/wa.err"
"$XCC" -q -A win64 -c -L "$W" "$W/catOver.xc" -o "$W/catOver-win.o" 2>>"$W/wa.err"
if "$XCC" -q -A win64 "$W/modMain-win.o" "$W/modA-win.o" -o "$W/wprog.exe" 2>"$W/wl.err" \
   && "$XCC" -q -A win64 "$W/catOver-win.o" "$W/catBase-win.o" -o "$W/wcat.exe" 2>>"$W/wl.err"; then
    if command -v wine >/dev/null 2>&1; then
        out="$(WINEDEBUG=-all timeout 120 wine "$W/wprog.exe" 2>/dev/null | tr -d '\r')"
        [ "$out" = "9" ] && ok "win64 linked program runs under wine (got 9)" \
                         || bad "win64 linked program (got '$out', want 9)"
        out="$(WINEDEBUG=-all timeout 120 wine "$W/wcat.exe" 2>/dev/null | tr -d '\r')"
        [ "$out" = "1011 1012 2011" ] \
            && ok "win64 interface + category chain across objects (got '$out')" \
            || bad "win64 category chain (got '$out', want '1011 1012 2011')"
        if "$XCC" -q -A win64 -flto "$W/modMain-win.o" "$W/modA-win.o" \
             -o "$W/wlto.exe" 2>"$W/wt.err"; then
            out="$(WINEDEBUG=-all timeout 120 wine "$W/wlto.exe" 2>/dev/null | tr -d '\r')"
            [ "$out" = "9" ] && ok "win64 -flto links and runs (got 9)" \
                             || bad "win64 -flto (got '$out', want 9)"
        else
            bad "win64 -flto link"; head -3 "$W/wt.err"
        fi
    else
        echo "SKIP  win64 runs — no wine on this host (LINKING was checked, EXECUTION WAS NOT)"
    fi
else
    bad "win64 link objects"; cat "$W/wl.err"
fi

# The same object reached through a STATIC ARCHIVE rather than named directly.
# An archive is a POOL: the member joins only because something is undefined
# without it, which is what makes this different from listing the .o. Built with
# the host `ar` — the container is orthogonal to the COFF inside it, and reading
# BSD-format `ar` is exactly what the shared XTArArchive is for.
if command -v ar >/dev/null 2>&1; then
    rm -f "$W/wlib.a"
    ar rcs "$W/wlib.a" "$W/modA-win.o" 2>/dev/null
    # Without the archive it must FAIL, or the check proves nothing.
    if "$XCC" -q -A win64 "$W/modMain-win.o" -o "$W/wnoar.exe" 2>/dev/null; then
        bad "win64 links with modA missing (the archive check is vacuous)"
    else
        ok "win64 refuses the link when the archive is absent"
    fi
    if "$XCC" -q -A win64 "$W/modMain-win.o" "$W/wlib.a" -o "$W/war.exe" 2>"$W/war.err"; then
        if command -v wine >/dev/null 2>&1; then
            out="$(WINEDEBUG=-all timeout 120 wine "$W/war.exe" 2>/dev/null | tr -d '\r')"
            [ "$out" = "9" ] && ok "win64 COFF archive member pulled on demand (got 9)" \
                             || bad "win64 archive pull (got '$out', want 9)"
        else
            echo "SKIP  win64 archive run — no wine (LINKING was checked, EXECUTION WAS NOT)"
        fi
    else
        bad "win64 link against a .a"; head -3 "$W/war.err"
    fi
else
    echo "SKIP  win64 archive pull — no ar on this host (NOT CHECKED)"
fi

# A THIRD-PARTY archive, which is a different test from one we built ourselves.
# Our own objects have a single .text and no unwind or debug sections, so they
# never exercise the parts of a COFF object a real toolchain emits: mingw's
# members carry one .text per COMDAT function plus .pdata (SEH unwind) and
# discardable .debug_* — and every SECREL relocation in libmingwex.a lives in
# the latter, every ADDR32NB in .idata/.pdata. Reading those sections is what
# made the reader need relocation types it now never sees.
MGWLIB="${XTC_WIN64_TOOLCHAIN:-/opt/clang/win64}/x86_64-w64-mingw32/lib"
if [ -f "$MGWLIB/libmingwex.a" ] && command -v wine >/dev/null 2>&1; then
    cat > "$W/mgw.xc" <<'EOF'
#import "Stdio.xc"
u8* strtok_r(u8* s, u8* delim, u8** save);
i32 main(void)
{
    u8 buf[32]; u8* sv;
    buf[0]=(u8)$61; buf[1]=(u8)$2C; buf[2]=(u8)$62; buf[3]=(u8)0;   // "a,b"
    u8 d[2]; d[0]=(u8)$2C; d[1]=(u8)0;                               // ","
    u8* p = strtok_r(&buf[0], &d[0], &sv);
    Stdio.printf("%s", p);
    p = strtok_r((u8*)0, &d[0], &sv);
    Stdio.printf("%s\n", p);
    return 0;
}
EOF
    "$XCC" -q -A win64 -S -o "$W/mgw.s" "$W/mgw.xc" 2>/dev/null
    SUPW=support/win64/runtime
    if bin/osx/xcc-ln-win64 "$SUPW/crt-win64.s" "$SUPW/rtgen-win64.s" "$SUPW/rtfiles-win64.s" "$SUPW/libmgen-win64.s" \
         "$W/mgw.s" "$MGWLIB/libmingwex.a" \
         -importmap support/win64/win32-imports.map \
         -import "kernel32.dll:ExitProcess,GetStdHandle,WriteFile,VirtualAlloc,GetSystemTimeAsFileTime,Sleep" \
         -o "$W/mgw.exe" 2>"$W/mgw.err"; then
        out="$(WINEDEBUG=-all timeout 120 wine "$W/mgw.exe" 2>/dev/null | tr -d '\r')"
        [ "$out" = "ab" ] && ok "win64 pulls from a REAL mingw archive (got 'ab')" \
                          || bad "win64 third-party archive (got '$out', want 'ab')"
    else
        bad "win64 link against libmingwex.a"; head -3 "$W/mgw.err"
    fi
else
    echo "SKIP  win64 third-party archive — no mingw sysroot or no wine (NOT CHECKED)"
fi

# The REAL Windows C runtime, through the DEFAULT driver path (no flags).
# snprintf is the case that proves it: it is not an msvcrt.dll export at all —
# mingw ships its own C99 one because msvcrt's is not conformant, and that
# reaches the real formatter through `__imp___stdio_common_vsprintf` in
# ucrtbase.dll. So this exercises the archive pull AND the `__imp_` IAT-slot
# reference at once. Our own fixed-form _xt_fmt_f formatter IGNORES its format
# string, so if it were still answering to the name `snprintf` this would print
# "n=1 s=0" rather than failing outright.
if [ -f "$MGWLIB/libmingwex.a" ] && command -v wine >/dev/null 2>&1; then
    cat > "$W/ucrt.xc" <<'EOF'
#import "Stdio.xc"
i32 snprintf(u8* buf, u32 size, string fmt, i32 prec, double v);
i32 main(void)
{
    u8 buf[64];
    i32 n = snprintf(&buf[0], (u32)64, "hello", (i32)0, 0.0);
    Stdio.printf("n=%d s=%s\n", n, &buf[0]);
    return 0;
}
EOF
    if "$XCC" -q -A win64 "$W/ucrt.xc" -o "$W/ucrt.exe" 2>"$W/ucrt.err"; then
        out="$(WINEDEBUG=-all timeout 120 wine "$W/ucrt.exe" 2>/dev/null | tr -d '\r')"
        [ "$out" = "n=5 s=hello" ] \
            && ok "win64 snprintf is the REAL libc via ucrtbase (got '$out')" \
            || bad "win64 real-libc snprintf (got '$out', want 'n=5 s=hello')"
    else
        bad "win64 link against the real C runtime"; head -3 "$W/ucrt.err"
    fi
fi

# ── arm9: the fourth target, and the one that is a different SHAPE ───────
# arm9 has no in-house assembler in this tree and no xcc-ln-arm9 — it shells out
# to arm-none-eabi-gcc — so `-c` is that toolchain's `-c` and the object is
# written by it, not by us. Two consequences the other three do not have:
#   · the objects carry NO runtime stub. Our own linkers take first-wins on a
#     duplicate; GNU ld does not, so the ARC/heap helpers are generated once at
#     the final link, from the objects' own symbol table via `nm`.
#   · ld runs with --allow-multiple-definition to match our linkers' semantics,
#     which costs its duplicate diagnostic — so the one duplicate that is never
#     benign, `<Class>$cat`, is checked in the driver against that same nm read.
# It needs the XTOS loader tree and qemu, so it SKIPS where they are absent —
# and says so, because a skipped run that reads as a pass is the failure mode
# this whole file exists to prevent.
A9SYS="${XTC_ARM9_SYSROOT:-}"
if [ -f "$A9SYS/freertos-hosttest.elf" ] && command -v qemu-system-arm >/dev/null 2>&1; then
    a9run() {  # <so> -> the program's stdout
        printf 'runhost %s\nexit\n' "$1" \
          | timeout 90 qemu-system-arm -M xilinx-zynq-a9 -display none -no-reboot -m 1024 \
              -chardev stdio,id=sh0 -semihosting-config enable=on,target=native,chardev=sh0 \
              -kernel "$A9SYS/freertos-hosttest.elf" 2>/dev/null \
          | sed -e '1,/XTOS shell/d' | sed 's/^xtos\$ //' | sed -e '/^bye$/,$d' \
          | grep -v '^\[net\]' | sed 's/\r$//' | sed -e '/^$/d'
    }
    "$XCC" -q -A arm9 -L "$A9SYS" -c "$W/modA.xc"    -o "$W/modA-a9.o"    2>"$W/9a.err"
    "$XCC" -q -A arm9 -L "$A9SYS" -c "$W/modMain.xc" -o "$W/modMain-a9.o" 2>>"$W/9a.err"
    if file "$W/modA-a9.o" 2>/dev/null | grep -q "ELF 32-bit LSB relocatable, ARM"; then
        ok "arm9 -c emits an ARM relocatable"
    else
        bad "arm9 -c object: $(file "$W/modA-a9.o" 2>&1 | head -1)"; head -3 "$W/9a.err"
    fi
    "$XCC" -q -A arm9 -L "$A9SYS" -c "$W/catBase.xc" -o "$W/catBase-a9.o" 2>>"$W/9a.err"
    "$XCC" -q -A arm9 -L "$A9SYS" -L "$W" -c "$W/catOver.xc" -o "$W/catOver-a9.o" 2>>"$W/9a.err"
    if "$XCC" -q -A arm9 -L "$A9SYS" "$W/modMain-a9.o" "$W/modA-a9.o" -o "$W/a9prog.so" 2>"$W/9l.err" \
       && "$XCC" -q -A arm9 -L "$A9SYS" "$W/catOver-a9.o" "$W/catBase-a9.o" -o "$W/a9cat.so" 2>>"$W/9l.err"; then
        out="$(a9run "$W/a9prog.so")"
        [ "$out" = "9" ] && ok "arm9 linked program runs on the loader (got 9)" \
                         || bad "arm9 linked program (got '$out', want 9)"
        out="$(a9run "$W/a9cat.so")"
        [ "$out" = "1011 1012 2011" ] \
            && ok "arm9 interface + category chain across objects (got '$out')" \
            || bad "arm9 category chain (got '$out', want '1011 1012 2011')"
        # The same object through a STATIC ARCHIVE. arm9 was the last hosted
        # target that could not resolve a symbol out of a `.a`, and the pull has
        # to be on DEMAND: a member joins only because something is undefined
        # without it. The paired no-archive link must fail, or this proves
        # nothing.
        if command -v ar >/dev/null 2>&1; then
            rm -f "$W/a9lib.a"
            ar rcs "$W/a9lib.a" "$W/modA-a9.o" 2>/dev/null
            # NOT "the link must fail": a shared object may legitimately carry
            # undefined symbols, which the loader resolves — that is how every
            # libc call works here. So the check is that it does not RUN without
            # the archive, which is what proves the archive supplied helperA.
            "$XCC" -q -A arm9 -L "$A9SYS" "$W/modMain-a9.o" -o "$W/a9noar.so" 2>/dev/null
            [ "$(a9run "$W/a9noar.so" 2>/dev/null)" = "9" ] \
                && bad "arm9 prints 9 without modA at all (the archive check is vacuous)" \
                || ok "arm9 cannot run without the archive that defines helperA"
            if "$XCC" -q -A arm9 -L "$A9SYS" "$W/modMain-a9.o" "$W/a9lib.a" \
                 -o "$W/a9ar.so" 2>"$W/9r.err"; then
                out="$(a9run "$W/a9ar.so")"
                [ "$out" = "9" ] && ok "arm9 archive member pulled on demand (got 9)" \
                                 || bad "arm9 archive pull (got '$out', want 9)"
            else
                bad "arm9 link against a .a"; grep -v "ABI flags" "$W/9r.err" | head -3
            fi
        fi

        # -flto: merge the IR each object carries, recompile as one module, and
        # hand the result to the ordinary arm9 link. The codegen MUST be given
        # --pic here, as the ordinary path does — without it the image links,
        # is 5.2 KB smaller, and DATA-ABORTs, because the loader maps it as a
        # PIC ET_DYN. Running it is the only check that catches that.
        if "$XCC" -q -A arm9 -L "$A9SYS" -flto "$W/modMain-a9.o" "$W/modA-a9.o" \
             -o "$W/a9lto.so" 2>"$W/9t.err"; then
            out="$(a9run "$W/a9lto.so")"
            [ "$out" = "9" ] && ok "arm9 -flto links and runs (got 9)" \
                             || bad "arm9 -flto (got '$out', want 9)"
        else
            bad "arm9 -flto link"; grep -v "ABI flags" "$W/9t.err" | head -3
        fi
    else
        bad "arm9 link objects"; grep -v "ABI flags" "$W/9l.err" | head -4
    fi
else
    echo "SKIP  arm9 — no loader build at '$A9SYS' or no qemu-system-arm (NOT CHECKED AT ALL)"
fi

# ── a library that WRAPS external C, per target ──────────────────────────
# The shape libtls has. Three separate bugs made this impossible: --emit-lib
# dropped -Wl objects/archives (arm64 silently, arm9 silently, x86_64 by
# falling back to clang, which bundles the C but not the xtc runtime); the
# Mach-O dylib writer had no Branch26 case for a symbol defined in the image;
# and the arm9 ET_DYN writer emitted no section headers, so `#import <lib>`
# could not read the library's own .xtc.iface.
#
# arm64 is covered by tests/crossmod/native-arm64.sh, which can RUN it.
# Here: arm9 and x86_64, checked for zero undefined wrapped symbols and a
# readable interface — the two properties that were broken.
# The wrapped-C sources are shared by the arm9, x86_64 and win64 halves below,
# so they are written HERE, not inside the arm9 branch: when that branch was
# skipped (no loader build in this checkout) the x86_64 `-l` case had no
# libdashl.a to link, the driver reported "-l names no static archive" and
# fell back — a harness gap that read as finding #15 regressing (bug 135).
cat > "$W/wshim.c" <<'EOF'
int _xt_w_read(int v);
int _xt_w_shim(int v) { return _xt_w_read(v) + 1; }
EOF
cat > "$W/wcore.c" <<'EOF'
int _xt_w_read(int v) { return v * 2; }
EOF
A9AR="${XTC_ARM9_AR:-arm-none-eabi-ar}"
if [ -d "$A9SYS" ] && command -v arm-none-eabi-gcc >/dev/null 2>&1 \
   && command -v "$A9AR" >/dev/null 2>&1; then
    cat > "$W/Wrap.xc" <<'EOF'
i32 _xt_w_shim(i32 v);
class Wrap { static i32 go(i32 v) { return _xt_w_shim(v); } }
EOF
    cat > "$W/wrapcli.xc" <<'EOF'
#import "Stdio.xc"
#import <wrap>
i32 main(void) { Stdio.printf("%d\n", Wrap.go((i32)20)); return 0; }
EOF
    A9CC=arm-none-eabi-gcc
    $A9CC -c -mcpu=cortex-a9 -mfloat-abi=softfp -mword-relocations \
        "$W/wshim.c" -o "$W/wshim9.o" 2>/dev/null
    $A9CC -c -mcpu=cortex-a9 -mfloat-abi=softfp -mword-relocations \
        "$W/wcore.c" -o "$W/wcore9.o" 2>/dev/null
    "$A9AR" rcs "$W/libwcore9.a" "$W/wcore9.o" 2>/dev/null
    "$XCC" -q -A arm9 -L "$A9SYS" --emit-lib "$W/Wrap.xc" -o "$W/libwrap.so" \
        -Wl,"$W/wshim9.o" -Wl,"$W/libwcore9.a" 2>"$W/wr9.err"
    if [ -f "$W/libwrap.so" ]; then
        # The C must be IN the library...
        und=$(arm-none-eabi-nm -D "$W/libwrap.so" 2>/dev/null | grep -c "U _xt_w_" || true)
        def=$(arm-none-eabi-nm -D "$W/libwrap.so" 2>/dev/null | grep -c "T _xt_w_" || true)
        [ "$und" = 0 ] && [ "$def" = 2 ] \
            && ok "arm9 --emit-lib bundles the wrapped C (2 defined, 0 undefined)" \
            || bad "arm9 wrapped C (defined=$def undefined=$und, want 2 and 0)"
        # ...and the library must be IMPORTABLE, which needs section headers.
        shn=$(arm-none-eabi-readelf -h "$W/libwrap.so" 2>/dev/null \
              | awk -F: '/Number of section headers/{print $2}' | xargs)
        [ "${shn:-0}" -gt 0 ] \
            && ok "arm9 --emit-lib writes a section header table ($shn sections)" \
            || bad "arm9 --emit-lib has no section headers — #import cannot read .xtc.iface"
        if "$XCC" -q -A arm9 -L "$A9SYS" -L "$W" "$W/wrapcli.xc" -o "$W/wrapcli.so" 2>"$W/wc9.err"; then
            ok "arm9 client imports the in-house library"
        else
            bad "arm9 client import"; grep -v "ABI flags" "$W/wc9.err" | head -2
        fi
    else
        bad "arm9 --emit-lib with wrapped C"; grep -v "ABI flags" "$W/wr9.err" | head -3
    fi
fi

XTC_X86_TC="${XTC_X86_64_TOOLCHAIN:-/opt/clang/linux}"
X86AR="$XTC_X86_TC/bin/x86_64-linux-musl-ar"
[ -x "$X86AR" ] || X86AR="$XTC_X86_TC/bin/llvm-ar"
if [ -x "$XTC_X86_TC/bin/x86_64-linux-musl-clang" ] && [ -x "$X86AR" ]; then
    "$XTC_X86_TC/bin/x86_64-linux-musl-clang" -c -fPIC "$W/wshim.c" -o "$W/wshimx.o" 2>/dev/null
    "$XTC_X86_TC/bin/x86_64-linux-musl-clang" -c -fPIC "$W/wcore.c" -o "$W/wcorex.o" 2>/dev/null
    "$X86AR" rcs "$W/libwcorex.a" "$W/wcorex.o" 2>/dev/null
    out=$("$XCC" -A x86_64 --emit-lib "$W/Wrap.xc" -o "$W/libwrapx.so" \
            -Wl,"$W/wshimx.o" -Wl,"$W/libwcorex.a" 2>&1)
    if echo "$out" | grep -q "SYSTEM toolchain"; then
        bad "x86_64 --emit-lib fell back to clang for -Wl file inputs"
    else
        ok "x86_64 --emit-lib takes -Wl objects in-house (no clang fallback)"
    fi
    und=$(nm -u "$W/libwrapx.so" 2>/dev/null | grep -c "_xt_w_" || true)
    [ "$und" = 0 ] && ok "x86_64 --emit-lib bundles the wrapped C (0 undefined)" \
                   || bad "x86_64 wrapped C left $und undefined"

    # ── finding #15: `-l` + Stdio.printf in ONE in-house executable ──────
    # `-l<name>` used to force the clang fallback, which links the C library
    # but not the in-house runtime — so a program reaching printf's
    # `_xt_fmt_f` could use Stdio.printf OR a C archive, never both. The
    # driver now resolves `-l` to `lib<name>.a` on the -L paths and stays
    # in-house.
    # wcore128.c adds a 128-bit division so the pool must also reach the
    # compiler builtins (`__udivti3` — finding #16): C archives use what the
    # ISA has no instruction for, and neither our runtime nor musl defines it.
    cat > "$W/wcore128.c" <<'EOF'
unsigned long long xt_w_div128(unsigned long long a) {
    unsigned __int128 w = ((unsigned __int128)a << 64) | 2u;
    return (unsigned long long)(w / 7u);
}
EOF
    "$XTC_X86_TC/bin/x86_64-linux-musl-clang" -c "$W/wcore128.c" -o "$W/wcore128.o" 2>/dev/null
    "$X86AR" rcs "$W/libdashl.a" "$W/wcorex.o" "$W/wcore128.o" 2>/dev/null
    cat > "$W/dashl.xc" <<'EOF'
#use Stdio
i32 _xt_w_read(i32 a, ...);
u64 xt_w_div128(u64 a, ...);
u8* getenv(u8* name, ...);
i32 main(void) {
    // getenv pins TWO findings: #17's GOTPCRELX relaxation (musl's getenv.lo
    // reads &__environ through a GOT load) and the crt actually publishing
    // envp — it linked and quietly answered NULL before.
    printf("core=%ld f=%f d=%llu env=%d\n", _xt_w_read((i32)5), (float)1.5,
           xt_w_div128((u64)1), getenv((u8*)"PATH") != (u8*)0 ? (i16)1 : (i16)0);
    return 0;
}
EOF
    out=$("$XCC" -A x86_64 -L "$W" "$W/dashl.xc" -ldashl -o "$W/dashl" 2>&1)
    if echo "$out" | grep -q "SYSTEM toolchain"; then
        bad "x86_64 -l archive forced the clang fallback (finding #15)"
    elif [ -f "$W/dashl" ]; then
        ok "x86_64 -l archive + Stdio.printf link in-house (finding #15)"
    else
        bad "x86_64 -l archive link failed"; echo "$out" | tail -3
    fi

    # -- plain GOTPCREL (type 9), COMMON, and weak/strong resolution --------
    # libpq exposed all three at once: a `cmpq` against a GOT slot cannot be
    # relaxed mov->lea and needs a real link-time GOT; OpenSSL's cpuid module
    # defines OPENSSL_ia32cap_P as a COMMON the reader used to drop; and
    # musl's lite_malloc defines `malloc` WEAK, which first-definition-wins
    # kept over mallocng's strong impl -- malloc without a matching free.
    # The .s is hand-written so the non-relaxable shape is GUARANTEED (a
    # compiler is free to pick the mov form); -mrelax-relocations=no keeps
    # even the mov as type 9 rather than GOTPCRELX.
    cat > "$W/got9.s" <<'GOT9EOF'
	.text
	.globl	xt_g9_probe
xt_g9_probe:
	cmpq	$0, xt_g9_var@GOTPCREL(%rip)
	je	1f
	movq	xt_g9_var@GOTPCREL(%rip), %rax
	movl	(%rax), %eax
	addl	xt_g9_common(%rip), %eax
	ret
1:	xorl	%eax, %eax
	ret
	.weak	xt_g9_absent
	.globl	xt_g9_absent_p
xt_g9_absent_p:
	movl	$1, %eax
	cmpq	$0, xt_g9_absent@GOTPCREL(%rip)
	jne	2f
	xorl	%eax, %eax
2:	ret
	.data
	.globl	xt_g9_var
xt_g9_var:
	.long	42
GOT9EOF
    cat > "$W/got9c.c" <<'GOT9EOF'
int xt_g9_common;                      /* tentative: a COMMON symbol */
int xt_g9_common_seed(void) { xt_g9_common = 7; return xt_g9_common; }
GOT9EOF
    cat > "$W/weakpair.c" <<'GOT9EOF'
static int weak_impl(void) { return 1; }
int xt_g9_pick(void) __attribute__((weak, alias("weak_impl")));
GOT9EOF
    cat > "$W/strongpair.c" <<'GOT9EOF'
int xt_g9_pick(void) { return 2; }
GOT9EOF
    "$XTC_X86_TC/bin/x86_64-linux-musl-clang" -c -Wa,-mrelax-relocations=no \
        "$W/got9.s" -o "$W/got9.o" 2>/dev/null
    "$XTC_X86_TC/bin/x86_64-linux-musl-clang" -c -fcommon "$W/got9c.c" -o "$W/got9c.o" 2>/dev/null
    "$XTC_X86_TC/bin/x86_64-linux-musl-clang" -c "$W/weakpair.c" -o "$W/weakpair.o" 2>/dev/null
    "$XTC_X86_TC/bin/x86_64-linux-musl-clang" -c "$W/strongpair.c" -o "$W/strongpair.o" 2>/dev/null
    # weak BEFORE strong in the archive: the order that used to pick wrong.
    "$X86AR" rcs "$W/libgot9.a" "$W/got9.o" "$W/got9c.o" "$W/weakpair.o" "$W/strongpair.o" 2>/dev/null
    cat > "$W/got9m.xc" <<'GOT9EOF'
#use Stdio
i32 xt_g9_probe(void);
i32 xt_g9_absent_p(void);
i32 xt_g9_pick(void);
i32 xt_g9_common_seed(void);
i32 main(void) {
    i32 seeded = xt_g9_common_seed();
    printf("%ld %ld %ld %ld\n", xt_g9_probe(), xt_g9_absent_p(),
           xt_g9_pick(), seeded);
    return 0;
}
GOT9EOF
    out=$("$XCC" -A x86_64 -L "$W" "$W/got9m.xc" -lgot9 -o "$W/got9m" 2>&1)
    if [ -f "$W/got9m" ]; then
        ok "type-9 GOTPCREL + COMMON + weak/strong archive links in-house"
        # Runs only when the x86 host answers; a silent host is NOT a pass.
        X86HOST="${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}"
        if ssh -o ConnectTimeout=3 "$X86HOST" true 2>/dev/null; then
            scp -q "$W/got9m" "$X86HOST:/tmp/xt-got9m" 2>/dev/null
            run9=$(ssh "$X86HOST" "/tmp/xt-got9m; rm -f /tmp/xt-got9m" 2>/dev/null)
            [ "$run9" = "49 0 2 7" ] \
                && ok "type-9 slot reads, weak-undef 0, strong-over-weak run right (got '$run9')" \
                || bad "got9 program ran wrong (got '$run9', want '49 0 2 7')"
        else
            echo "  (x86 host unreachable -- got9 RUN not attempted, link-only)"
        fi
    else
        bad "type-9/COMMON/weak archive link failed"; echo "$out" | tail -3
    fi

    # -- static local-exec TLS (__thread) --------------------------------
    # mimalloc's per-thread heap pointer is a __thread variable: TPOFF32
    # relocations, a .tdata image, and a per-thread block below %fs that the
    # crt and _xt_tcb_alloc must initialise. The C is compiled -fno-pic so
    # the model is LOCAL-EXEC (type 23), the only static-TLS model the
    # linker implements.
    cat > "$W/tlsv.c" <<'TLSEOF'
__thread long xt_tls_v = 41;
__thread long xt_tls_z;
long xt_tls_get(void)  { return xt_tls_v + xt_tls_z; }
void xt_tls_bump(void) { xt_tls_v++; xt_tls_z += 2; }
TLSEOF
    "$XTC_X86_TC/bin/x86_64-linux-musl-clang" -c -O1 -fno-pic "$W/tlsv.c" -o "$W/tlsv.o" 2>/dev/null
    cat > "$W/tlsm.xc" <<'TLSEOF'
#use Stdio
i64 xt_tls_get(void);
void xt_tls_bump(void);
i32 main(void) {
    xt_tls_bump();
    printf("%llu\n", (u64)xt_tls_get());
    return 0;
}
TLSEOF
    out=$("$XCC" -A x86_64 -L "$W" "$W/tlsm.xc" -Wl,"$W/tlsv.o" -o "$W/tlsm" 2>&1)
    if [ -f "$W/tlsm" ]; then
        ok "__thread (local-exec TLS) object links in-house"
        X86HOST="${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}"
        if ssh -o ConnectTimeout=3 "$X86HOST" true 2>/dev/null; then
            scp -q "$W/tlsm" "$X86HOST:/tmp/xt-tlsm" 2>/dev/null
            runt=$(ssh "$X86HOST" "/tmp/xt-tlsm; rm -f /tmp/xt-tlsm" 2>/dev/null)
            [ "$runt" = "44" ]                 && ok "__thread image initialised and writable (got '$runt')"                 || bad "__thread program ran wrong (got '$runt', want '44')"
        else
            echo "  (x86 host unreachable -- TLS RUN not attempted, link-only)"
        fi
    else
        bad "__thread object link failed"; echo "$out" | tail -3
    fi
fi

# `-o foo.o` WITHOUT -c, on EVERY target. This is the lie the whole programme
# exists to end: it ran a full link and wrote an executable to the `.o` path,
# reporting success on arm64 and failing deep inside someone else's crt1.o on
# x86_64. Checked across all six architectures, including the two that will
# never have objects — a target that quietly kept the old behaviour is exactly
# the one nobody would think to look at.
liefail=0
for arch in arm64 x86_64 win64 arm9 6502 m68k; do
    "$XCC" -q -A "$arch" "$W/modA.xc" -o "$W/lie-$arch.o" >/dev/null 2>&1
    if [ -f "$W/lie-$arch.o" ]; then
        echo "  $arch still wrote $(file "$W/lie-$arch.o" | cut -d: -f2-)"
        liefail=1
    fi
done
[ "$liefail" = 0 ] && ok "'-o foo.o' without -c writes nothing, on every target" \
                   || bad "'-o foo.o' without -c still produces a file"

# ── the in-house linker reads a real static ARCHIVE ─────────────────────
# A `.a` is not linked, it is a POOL: a member joins only if it defines
# something still undefined, and pulling one can make new names undefined in
# turn. `atoi` exists in musl's libc.a and NOWHERE in our runtime, so a program
# that calls it links only if the archive machinery genuinely works.
X86LIBC="${XTC_X86_LIBC:-/opt/clang/linux/x86_64-linux-musl/lib/libc.a}"
if [ -f "$X86LIBC" ]; then
    cat > "$W/ar.xc" <<'EOF'
#import "Stdio.xc"
i32 atoi(string s);
void main(void) { Stdio.printf("%ld\n", (u32)atoi("4711")); return; }
EOF
    "$XCC" -q -A x86_64 -S -o "$W/ar.s" "$W/ar.xc" 2>/dev/null
    SUP=support/x86_64/runtime
    RT="$SUP/crt-linux.s $SUP/sys-linux.s $SUP/rtgen-linux.s $SUP/rtfiles-linux.s $SUP/libmgen-linux.s"
    # Without the archive it must FAIL: otherwise the check proves nothing.
    if bin/osx/xcc-ln-x86_64 $RT "$W/ar.s" -o "$W/ar_no" 2>/dev/null; then
        bad "a call into libc links even WITHOUT the archive (the check is vacuous)"
    else
        ok "an unresolved libc call is refused without the archive"
    fi
    if bin/osx/xcc-ln-x86_64 $RT "$W/ar.s" "$X86LIBC" -o "$W/ar_yes" 2>"$W/ar.err"; then
        XH="${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}"
        if ssh -o ConnectTimeout=8 -o BatchMode=yes "$XH" true 2>/dev/null; then
            scp -q "$W/ar_yes" "$XH:/tmp/xtc-ar-$$" 2>/dev/null
            out="$(ssh -o BatchMode=yes "$XH" "chmod +x /tmp/xtc-ar-$$ && /tmp/xtc-ar-$$; rm -f /tmp/xtc-ar-$$" 2>/dev/null)"
            [ "$out" = "4711" ] && ok "libc.a member pulled in by our own linker (got 4711)" \
                                || bad "archive pull (got '$out', want 4711)"
        else
            echo "SKIP  archive-pull run — no Linux host at '$XH' (LINKING was checked, EXECUTION WAS NOT)"
        fi
    else
        bad "link against libc.a"; head -2 "$W/ar.err"
    fi
else
    echo "SKIP  archive pull — no musl libc.a at '$X86LIBC' (NOT CHECKED)"
fi

# Independent reader. Missing runtime symbols are EXPECTED here: -c deliberately
# leaves crt/rt out, so this checks ld can parse and resolve, not that it links.
if command -v clang >/dev/null 2>&1; then
    clang -arch arm64 "$W/modA.o" -o "$W/x" 2>"$W/c.err"
    grep -q "Undefined symbols\|_main" "$W/c.err" && ok "Apple's ld reads our object" \
        || { grep -qi "truncated\|malformed\|not an object" "$W/c.err" \
             && bad "Apple's ld reads our object" || ok "Apple's ld reads our object"; }
fi

# bug 177: two tentative definitions of one array at different sizes are both
# COMMON symbols; the linker must keep the LARGEST whatever the link order (a C
# linker merges commons that way). def.o-then-use.o used to shrink the table to
# the smaller common. `_tbl` size is measured as the gap to the next symbol.
cat > "$W/cbig.xc" <<'EOF'
struct rec { i64 a; i64 b; }
rec tbl[83];
i64 zbig;
void useBig(void) { tbl[82].a = (i64)1; zbig = (i64)9; }
EOF
cat > "$W/csml.xc" <<'EOF'
struct rec { i64 a; i64 b; }
rec tbl[9];
i64 zsml;
i64 useSml(void) { return tbl[0].a + zsml; }
EOF
"$XCC" -q -O0 -c -o "$W/cbig.o" "$W/cbig.xc" 2>/dev/null
"$XCC" -q -O0 -c -o "$W/csml.o" "$W/csml.xc" 2>/dev/null
tblroom() {  # $1 = binary → prints the byte gap from _tbl to the next symbol
    local lines a b
    lines="$(nm -n "$1" 2>/dev/null | grep -A1 ' _tbl$')"
    a="$(printf '%s\n' "$lines" | sed -n '1p' | awk '{print $1}')"
    b="$(printf '%s\n' "$lines" | sed -n '2p' | awk '{print $1}')"
    [ -n "$a" ] && [ -n "$b" ] && echo $(( 0x$b - 0x$a ))
}
for order in "cbig.o csml.o" "csml.o cbig.o"; do
    if "$XCC" -q -o "$W/cw" $(echo "$order" | sed "s#[a-z0-9]*\.o#$W/&#g") 2>/dev/null; then
        r="$(tblroom "$W/cw")"
        [ "$r" = "1328" ] && ok "common largest-wins ($order → tbl 1328)" \
                          || bad "common largest-wins ($order → tbl '$r', want 1328)"
    else
        bad "link commons ($order)"
    fi
done

echo "--- objlink: $([ $fail -eq 0 ] && echo ALL PASS || echo FAILURES) ---"
exit $fail
