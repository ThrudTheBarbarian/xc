---
title: Operators
description: Full operator precedence table including the rotate and byte-extract operators, and operators defined by classes.
---

xcc operators are mostly a subset of C's, with two additions: a pair of **rotate** operators (`<:` and `:>`) that map to the 6502's `ROL` / `ROR` instructions, and four **byte-extract** prefix operators (`<`, `>`, `>>`, `>>>`) that select individual bytes of wider constants and symbols. The byte-extract operators apply only inside [`asm { ... }`](/compiler/language/inline-asm/) blocks.

## Precedence table

Listed from highest to lowest. Rows at the same level have the same precedence; within a level, **Assoc** records the associativity.

| Operators | Assoc | Notes |
|-----------|-------|-------|
| `a[i]`, `f(...)`, `.`, `->`, postfix `++`, postfix `--` | left | primary |
| prefix `+ -`, `!`, `~`, prefix `++`, prefix `--`, `*` (deref), `&` (addr-of), `(type)` cast, `sizeof()`, `<` `>` `>>` `>>>` (byte extract, asm) | right | unary |
| `*`, `/`, `%` | left | multiplicative |
| `+`, `-` | left | additive |
| `<:`, `:>` | left | rotate (ROL / ROR) |
| `<<`, `>>` | left | shift (ASL / ASR) |
| `<`, `>`, `<=`, `>=` | left | relational |
| `==`, `!=` | left | equality |
| `&` | left | bitwise AND |
| `^` | left | bitwise XOR |
| `\|` | left | bitwise OR |
| `&&` | left | logical AND |
| `\|\|` | left | logical OR |
| `? :` | right | ternary |
| `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `\|=`, `^=`, `<<=`, `>>=`, `<:=`, `:>=` | right | assignment |

## Notes on specific operators

### Rotate vs shift

`<:` and `:>` **rotate** through carry. They map to the 6502 `ROL` / `ROR` instructions, which read and write the carry flag. `<<` and `>>` are **arithmetic shifts** (`ASL`, and `ASR` for the right shift). Use rotate to chain bytes through carry; use shift to multiply or divide by powers of two.

```c
u8 a = $80;
u8 b = a <: 1;    // a is rotated left through carry; one-bit shift left + carry-in
u8 c = a << 1;    // arithmetic left shift; bit 7 lost
```

### Equality against `nil`

`==` and `!=` compare a pointer of any type with [`nil`](/compiler/language/types/#the-null-pointer-nil),
the null pointer: `if (p == nil)`, `while (node != nil)`. `nil` goes into no
other operator (`nil + 1`, `nil < p`) and is not compared with an integer; the
compiler refuses both.

### Pointer dereference and address-of

`*` is the unary dereference operator; `&` takes an address. Each undoes the other:

```c
u8 v   = 42;
u8* p  = &v;
u8 q   = *p;     // q == 42
*p     = 99;     // v becomes 99
```

`->` dereferences and then accesses a member: `p->x` is the same as `(*p).x`. xcc also accepts the dot form `p.x` on a pointer and dereferences automatically. See [Types → Pointers](/compiler/language/types/#pointers) for the rationale.

### Cast extensions

Inside the `(type)` cast, two forms have non-C semantics:

- `(Dog*) animal` — runtime-checked downcast. Traps on mismatch.
- `(Dog* ?) animal` — failable downcast. Yields `(Dog*)0` on mismatch.

These are class-pointer-only; `(u16 ?)x` is a compile-time error. Details on [Inheritance & protocols](/compiler/language/inheritance/).

### `sizeof`

`sizeof(T)` evaluates to a compile-time byte count. Works on any type, including `struct` and `class`.

Its type is the target's size type, like C's `size_t`: `u64` on the 64-bit
targets (arm64, x86-64, Windows, Android, iOS), `u32` on the 32-bit ones (arm9,
m68k, wasm32) and `u16` on the 6502. On the 6502 a size over 65535 bytes does not
fit, so `sizeof` of it is an error that names the size.

### Byte-extract prefixes (asm context)

These operators apply only inside an `asm { ... }` block. They select individual bytes of a constant or symbol that the assembler would otherwise treat as a 16- or 32-bit address:

| Prefix | Meaning |
|--------|---------|
| `<x`   | low 8 bits of `x` |
| `>x`   | bits 8..15 of `x` |
| `>>x`  | bits 16..23 of `x` |
| `>>>x` | bits 24..31 of `x` |

```c
u16 val = $1234;

asm {
    lda #<val;    // LDA #$34
    ldx #>val;    // LDX #$12
}
```

Outside an `asm` block these tokens have their normal meaning: `<` and `>` are relational comparisons and `>>` is the shift operator. Inside a block the byte-extract reading is unambiguous, because the assembler grammar accepts only constants and symbols after the prefix.

### Prefix `+`

Prefix `+` has no meaning of its own. It is accepted only on an instance of a
class that defines it with `:operator(+self)` (next section); on a number it is
an error.

## Operators defined by a class

A method becomes an operator by carrying `:operator(pattern)`. The pattern is
the operator written out with the method's own names as its operands: `self`
for the receiver and the parameter names for the arguments.

```c
class Vec2
    {
    float x;
    float y;

    static Vec2* make(float a, float b) { Vec2* v = new Vec2(); v.x = a; v.y = b; return v; }

    Vec2* plus(Vec2* o)   :operator(self + o) { return Vec2.make(x + o.x, y + o.y); }
    Vec2* minus(Vec2* o)  :operator(self - o) { return Vec2.make(x - o.x, y - o.y); }
    Vec2* negated()       :operator(-self)    { return Vec2.make(-x, -y); }
    Vec2* scaled(float k) :operator(self * k) { return Vec2.make(x * k, y * k); }
    static Vec2* scaledBy(float k, Vec2* v) :operator(k * v) { return v.scaled(k); }
    bool less(Vec2* o)    :operator(self < o) { return x * x + y * y < o.x * o.x + o.y * o.y; }
    }

Vec2* c = a + b * 2.0 - -d;    // a.plus(b.scaled(2.0)).minus(d.negated())
Vec2* e = 2.0 * a;             // Vec2.scaledBy(2.0, a)
```

An operator is an ordinary method call. The method keeps its name, so
`a.plus(b)` still works, and the name is what stack traces and errors show.
Operators work on every target.

### What can be defined

| Group | Operators |
|-------|-----------|
| Arithmetic | `+ - * / %` |
| Prefix | `-x`, `+x`, `~x`, `!x` |
| Bitwise and shift | `& \| ^ << >>` |
| Rotate | `<: :>` |
| Relational | `< <= > >=` |
| Index | `self[i]` (get), `self[i] = v` (set), several indices `self[i, j]`, a range `self[lo..hi]` or `self[lo...hi]` |
| Compound assignment | `+= -= *= /= %= &= \|= ^= <<= >>= <:= :>=` |

A relational operator returns whatever its method returns, so a class can
return a mask or a flag object rather than a `bool`.

These operators keep their fixed meaning and cannot be defined: `&&`, `||`,
`? :`, `=`, `.`, `->`, prefix `&` and `*`, `,`, calls, the byte-extract
prefixes, `++` and `--`. `==` and `!=` compare identity on objects; value
equality is the `equals` method.

Precedence and associativity are the built-in ones. Defining `*` does not
change how `a + b * c` groups.

### Rules for a pattern

- The pattern is one operator applied to names: `self + o`, `-self`, `k * v`.
- Each name is `self` or a parameter of the method, and appears once. Every
  parameter appears.
- An instance method's pattern uses `self`. A static method's pattern does not,
  and one of its parameters is of its own class (or a subclass).
- The method returns one value, except an index set and a compound assignment,
  which are statements and return `void`. It takes no `...`.
- An index or compound-assignment pattern applies its operator to `self`:
  `self[i]`, `self[i] = v`, `self += o`.
- Operators are methods: a free function or a protocol method cannot carry
  `:operator`.

A static method is how a value of another type goes on the left: `:operator(k * v)`
on `scaledBy(float k, Vec2* v)` gives `2.0 * a`.

### How an operator expression is resolved

An operator applies when one of its operands is a class instance (a pointer to
one, or an instance by value) whose class, or an ancestor, defines that operator.
The candidates are the instance methods of the left operand's class whose
pattern is `self OP _`, then the static methods of either operand's class whose
pattern is `_ OP _`. They are ranked as the overloads of a call are, by how well
the operands convert to the parameters. Two candidates that fit equally well
are an error that names both.

Operators are inherited and can be overridden like any method, with or without
repeating the pattern. Through a parent pointer the call dispatches on the
object, as any method call does.

### Classes without operators keep pointer arithmetic

Defining an operator is a choice per class and per operator. A class that
defines no operator keeps C's meaning for every operator on its pointers:
`p + 1` steps one instance and `p < q` compares addresses. A class that defines
`+`, or inherits it, gives up the built-in `+` for its pointers. An unmatched
`+` on it is then an error, never a pointer step:

```
error: 'Vec2' has no '+' taking 'i32'
```

It keeps the built-in meaning of the operators it does not define, so its
pointers still compare with `<` unless it defines `<` too.

### Index operators

`:operator(self[i])` makes `v[i]` a call of the method, and
`:operator(self[i] = x)` makes `v[i] = x` one. A pattern may take several
indices, `self[r, c]`, and is then written `m[r, c]`.

```c
class Matrix
    {
    float cells[9];
    float at(i32 r, i32 c) :operator(self[r, c]) { return cells[r * 3 + c]; }
    void put(i32 r, i32 c, float x) :operator(self[r, c] = x) { cells[r * 3 + c] = x; }
    }

m[0, 2] = 2.5;          // m.put(0, 2, 2.5)
float d = m[1, 1];      // m.at(1, 1)
m[1, 1] += 1.5;         // m.put(1, 1, m.at(1, 1) + 1.5)
```

A range index, `self[lo..hi]` or `self[lo...hi]`, takes the two bounds as two
parameters, so `s[2..5]` is a call with 2 and 5. `..` and `...` are separate
operators: a class decides what each one means. Both bounds are needed. A range
index has a set form too, `self[lo..hi] = x`.

`v[i] op= x` reads with the get, applies `op` (the built-in one at the element's
type, or the element class's operator) and writes with the set. The base and the
indices are evaluated once each, in source order, before the get: in
`f()[g()] += h()`, `f`, `g` and `h` each run once, in that order.

In `g[i][j] = v` the get reads `g[i]`, and the set assigns `[j] = v` on what it
returned. Reading `g[i][j]` is a get and then a get. A get that returns a
built-in pointer is indexed the built-in way, and an element of a built-in array
of objects is indexed with its class's operator.

A class that defines any index operator, or inherits one, gives up the built-in
index for its pointers: `p[i]` on it is an operator, and an index no operator
takes is an error. A class without index operators keeps C's pointer indexing.
Several indices are accepted only by an index operator.

When a get returns a class by value, `g[i][j] = v` would set an element of a
temporary copy, and the write would be lost. That is an error when the class
holds no pointer or reference, directly or in a by-value member; store the
value in a variable first (`Row r = g[i]; r[j] = v;`), or have the get return a
pointer. A class that does hold a pointer is treated as a view into its owner,
so writing through it is allowed. The same applies to compound assignment.

An element read through an index operator is a call's result, so `&v[i]`,
`v[i]++` and `--v[i]` are errors. `for … in` cannot iterate a range index made by
an operator; assign it to a variable first.

### Compound assignment

`:operator(self += o)` defines `+=` in place: `a += b` is a call of the method.
When a class defines `+` and no `+=` that takes `b`, `a += b` is `a = a + b`: the
result of `+` is assigned to `a`, the old value is released, and whatever the
address of `a` is computed from is evaluated once. For a class returned by value,
it is a by-value assignment.

The built-in compound assignment applies when the class defines neither `+=` nor
`+`, so `p += 1` still steps a pointer. A class that defines operators gets no
`p += q` of two pointers: that is an error. A compound operator cannot assign
through a property's setter; write the assignment out.

### Results and memory

The result of an operator is the result of its method call. A class pointer
returned by the method is released at the end of the full expression, unless it
is stored. A method that returns its instance by value
(`Vec2 plus(Vec2 o) :operator(self + o)`) needs no heap allocation: in
`a + b + c` each intermediate gets its own slot in the caller's frame.

## Compound assignment

Every arithmetic, bitwise and shift binary operator has a compound-assignment form: `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `<<=`, `>>=`, plus the rotate forms `<:=` and `:>=`. Each behaves as its expansion:

```c
x += 1;            // x = x + 1
flags &= ~MASK;    // flags = flags & ~MASK
acc <:= 1;         // acc = acc <: 1
```

When the left-hand side goes through a property setter (see [Classes → Properties](/compiler/language/classes/#properties)), the expansion evaluates the base expression twice. This costs nothing for identifiers and `self`, and matters only if the base has a side effect.

## Worked example

The operators that differ from C, and the ones that do not:

```c
// operators.xc — the operators that differ from C, and the ones that don't.
#import "Foundation.xc"
#import "Stdio.xc"

i32 main(void)
{
    // ---- Arithmetic, at the operands' own width -----------------------------
    // Same-width arithmetic stays at that width, so these WRAP rather than
    // promoting to int as C would: 300 & $FF = 44, 600 & $FF = 88.
    u8 a = 200;
    u8 b = 100;
    Stdio.printf("u8   200+100=%d  200*3=%d\n", (u16)(a + b), (u16)(a * 3));
    // Widening the OPERANDS is what gets the true sum.
    Stdio.printf("wide 200+100=%d\n", (u16)a + (u16)b);

    // Division and modulo. Integer division truncates toward zero.
    i16 n = -17;
    Stdio.printf("-17/5=%d  -17%%5=%d\n", n / (i16)5, n % (i16)5);

    // ---- Shift vs rotate ----------------------------------------------------
    // `<<` and `>>` shift; `<:` and `:>` ROTATE through the carry flag, which
    // is what lets you chain bytes together. On the 6502 they are ROL / ROR.
    u8 hi = $81;
    Stdio.printf("$81 << 1 = $%02X   $81 >> 1 = $%02X\n",
                 (u16)(hi << 1), (u16)(hi >> 1));
    Stdio.printf("$81 <: 1 = $%02X   $81 :> 1 = $%02X\n",
                 (u16)(hi <: 1), (u16)(hi :> 1));

    // ---- Bitwise ------------------------------------------------------------
    u8 m = $F0;
    u8 k = $AA;
    Stdio.printf("and=$%02X or=$%02X xor=$%02X not=$%02X\n",
                 (u16)(m & k), (u16)(m | k), (u16)(m ^ k), (u16)(~m));

    // ---- Logical, and short-circuit ----------------------------------------
    // && and || evaluate left to right and stop as soon as the answer is known.
    u16 zero = 0;
    bool safe = (zero != 0) && (100 / zero > 1);   // never divides
    Stdio.printf("short-circuit ok: %d\n", safe ? (u16)1 : (u16)0);

    // ---- Comparison and the ternary ----------------------------------------
    u16 x = 7;
    u16 y = 11;
    Stdio.printf("max=%d  eq=%d  ne=%d\n",
                 x > y ? x : y,
                 (u16)(x == y ? 1 : 0),
                 (u16)(x != y ? 1 : 0));

    // ---- Compound assignment, including the rotates ------------------------
    u8 acc = 1;
    acc += 4;       // 5
    acc *= 3;       // 15
    acc <<= 1;      // 30
    acc |= 1;       // 31
    Stdio.printf("compound=%d\n", (u16)acc);

    // ---- Increment / decrement ---------------------------------------------
    // Prefix updates then yields; postfix yields then updates.
    u16 i = 5;
    u16 pre = ++i;      // i=6, pre=6
    u16 post = i++;     // post=6, i=7
    Stdio.printf("pre=%d post=%d i=%d\n", pre, post, i);

    // ---- sizeof -------------------------------------------------------------
    // A compile-time constant. Pointer width is the only one that varies by
    // target; every scalar is the same everywhere.
    Stdio.printf("sizeof u8=%d u16=%d u32=%d u64=%d float=%d double=%d\n",
                 (u16)sizeof(u8), (u16)sizeof(u16), (u16)sizeof(u32),
                 (u16)sizeof(u64), (u16)sizeof(float), (u16)sizeof(double));

    // ---- Address-of and dereference ----------------------------------------
    u16 v = 42;
    u16* p = &v;
    *p = *p + 1;
    Stdio.printf("through pointer: %d\n", v);
    return 0;
}
```

```
u8   200+100=44  200*3=88
wide 200+100=300
-17/5=-3  -17%5=-2
$81 << 1 = $02   $81 >> 1 = $40
$81 <: 1 = $03   $81 :> 1 = $C0
and=$A0 or=$FA xor=$5A not=$0F
short-circuit ok: 0
max=11  eq=0  ne=1
compound=31
pre=6 post=6 i=7
sizeof u8=1 u16=2 u32=4 u64=8 float=4 double=8
through pointer: 43
```

In the first line, `u8 + u8` and `u8 * u8` stay at 8 bits and wrap (44 and 88). C would promote both to `int` and print 300 and 600. To get the full value, widen the **operands**.
