---
title: Statements & control flow
description: Variable declarations, if, switch, for, for-in (array and range), while, break, continue, :unroll.
---

## Variable declarations

```c
u8  myVal;
u8  myVal = 5;
u8  a, b = 1, 2;            // a = 1, b = 2

u8  bytes[32];              // array
u8  rgb[]   = {255, 0, 0};  // size inferred from initialiser
RGB white   = {255, 255, 255};
```

You may also initialise the **raw bytes** of any value, regardless of its type, using the brace form. Trailing missing bytes are zero-filled.

### Storage modifiers

| Modifier | Storage | Persistence | Visibility |
|----------|---------|-------------|-------------|
| *(default)* | fast storage | local scope | current block |
| `register` | fast storage (priority) | local scope | current block |
| `volatile` | fast storage | local scope | current block |
| `static` | data section | permanent | the enclosing block (persists across calls) |
| `global static` | data section | permanent | as `static`, plus external linkage (other files) |

`static` and `global static` are local modifiers. They apply to a variable
declared inside a function and give it storage that outlives the call. For
file-scope persistent state, write a plain top-level declaration (a bare
`u16 total = 0;`). `static` and `global static` at file scope do not parse.

A file-scope name may be declared more than once, as a header imported down two
paths does, but only with the same type each time. Two declarations at different
types are an error, because they would name one object:

```c
u32 gX;
u32 gX[64];   // error: global 'gX' is declared twice in this unit with different types
```

Examples:

```c
u16 total = 0;                      // file-scope state: a plain top-level global

void tick(void) {
    volatile u16* dosvec = (u16*)10;  // both stores happen, even at -O3
    register u16  hot = (u16)0;       // priority on the fast storage class
    static  u16  hits = 0;            // a local that persists across calls
    global static u16 shared = 0;     // persists, and linked to other files
    hits = hits + (u16)1;
}
```

What "fast storage" means depends on the target, which is why it is not named
after one machine's hardware:

| Target | Fast storage means |
|---|---|
| `xt6502` | **zero page**: one byte of address instead of two, and the only place indirect addressing works. It is scarce (a couple of hundred bytes for the whole program), so the allocator rations it. |
| `arm64`, `x86_64`, `win64`, `arm9`, `m68k` | **machine registers**, assigned by the backend's register allocator, spilling to the stack frame when they run out. Plentiful by comparison. |

`register` is a hint. It asks the allocator to consider this variable before
ordinary locals, so on a target where the resource is scarce it gets first pick.
On the register machines the allocator's own analysis is usually better, and the
hint rarely changes anything.

`volatile` is target-neutral. It disables the optimiser's store-elimination, so
every read and write becomes a real memory access, as a hardware register needs.

`typedef <type> alias;` introduces a type alias; see [Types → Type aliases](/compiler/language/types/#type-aliases-typedef).

## If / else

```c
if (x > 10) {
    Stdio.print("big\n");
} else if (x > 5) {
    Stdio.print("medium\n");
} else {
    Stdio.print("small\n");
}
```

The condition is in round brackets; the body is a block (`{ }`). `else` is optional.

## Switch

```c
switch (c) {
    case ..12:
        // any value <= 12
        break;

    case 13..18:
        // 13, 14, 15, 16, 17, 18
        break;

    case 22:        // fall through
    case 23:
        myFunction(c);
        break;

    case 40..:
        // any value >= 40
        break;

    default:
        Stdio.printf("nope\n");
        break;
}
```

`switch` extends C's form with **range cases**: `..N`, `M..N` and `N..` cover "less than or equal", inclusive ranges, and "greater than or equal". Range cases are only available on `u8` arguments; non-range cases (single values, fall-through) work on any integer.

At `-O2` and above the compiler may emit a jump-table for dense switches.

## C-style `for`

```c
for (u8 i = 0; i < 40; i++) {
    Stdio.printInt(i);
}
```

The setup may declare a new loop variable; if so, that variable goes out of scope when the loop terminates. All three clauses (setup / condition / step) are optional.

## For-in (iterate over array)

```c
u8 chars[] = {'h', 'e', 'l', 'l', 'o'};
for (u8 ch in chars) {
    Stdio.printByte(ch);
}
```

The collection may be either:

- A fixed-size array (length is known at compile time), or
- A heap-allocated pointer from `new T[N]` (length is read from the allocator's block header at loop entry, so deep recursion or re-allocation inside the body doesn't perturb the iteration count).

The loop variable's type may be given explicitly (`u8 ch in …`) or **omitted**, in which case it is taken from the collection's element type:

```c
u16 squares[5];
for (u16 v in squares) { … }      // explicit
for (v in squares)     { … }      // same loop, element type inferred
```

Both spellings produce identical code. If the element type cannot be inferred, the compiler emits a diagnostic that names the fix, instead of generating a loop that silently does not run.

:::note[Primitive elements in a typed collection]
`for ... in` over an `Array<i32>` works too: the element is a boxed `Number`, and binding it to a primitive loop variable unboxes it. See [Collections](/compiler/language/collections/#primitive-element-types).
:::

## For-in (range)

The for-in collection slot also accepts an integer range, in two forms:

```c
for (u8 i in 0..10)  { ... }   // exclusive: 0, 1, …, 9   (10 iters)
for (u8 i in 0...10) { ... }   // inclusive: 0, 1, …, 10  (11 iters)
```

`..` (two dots) is **exclusive**: the end value is not visited. `...` (three dots) is **inclusive**: the end value is visited. This is the same convention as Rust.

### Stride and direction: `step`

An optional `step <signed-int-literal>` clause sets the increment:

```c
for (u8 i in 0..10 step 2)    { ... }   // 0, 2, 4, 6, 8
for (u8 i in 0...10 step 2)   { ... }   // 0, 2, 4, 6, 8, 10
for (u8 i in 10..0 step -1)   { ... }   // 10, 9, …, 1
for (u16 i in 100..0 step -5) { ... }   // 100, 95, …, 5
```

The step must be a compile-time integer literal (a bare integer or its negation; expressions are not folded here). A negative step makes the loop descend.

When both bounds are integer literals, `start > end`, and no explicit step is given, the loop auto-flips to descending with `step -1`:

```c
for (u8 i in 10..0)   { ... }   // 10, 9, …, 1   (auto-flip, step -1)
for (u8 i in 10...0)  { ... }   // 10, 9, …, 0   (auto-flip, step -1, inclusive)
```

For non-literal bounds, the loop is ascending unless you write `step -N` explicitly:

```c
u8 from = 8;
u8 to   = 3;
for (u8 i in from..to step -1) { ... }   // runtime descending
```

Inconsistent combinations (e.g. `0..10 step -1`, where the body would never run) are rejected at parse time.

### Type inference

When no loop type is given, the compiler defaults to `u8` if both bounds and the step magnitude are `u8`-fitting integer literals:

```c
for (i in 1..4) { ... }           // i: u8 (auto)
for (i in 0..1000) { ... }        // ERROR: needs explicit type — bound > 255
```

Anything else (a non-literal bound, a literal beyond 255, a large step) requires an explicit type. The parser does not run sema's full constant-folding, so this is a surface-level check, not full type inference.

### Caveat: unsigned descending and underflow

Descending **unsigned** loops with a step that doesn't divide evenly into the start wrap past 0 and keep going. `for (u8 i in 20..0 step -3)` walks 20, 17, 14, 11, 8, 5, 2, then `2 - 3` wraps to 255 and the loop continues from there.

There are two fixes:

- **Align the bounds with the step**, so the walk lands on the end: `for (u8 i in 9..0 step -3)` gives 9, 6, 3 and stops.
- **Make the loop variable signed**: `for (i16 i in 10..0 step -3)` gives 10, 7, 4, 1 and stops, because stepping below the bound produces a negative value instead of a large positive one.

Widening from `u8` to `u16` does not help. It moves the wrap to 65535, so the loop runs 20 000 iterations instead of 80. The cause is the unsigned type, not its width.

### Lowering

The range form is rewritten to an equivalent C-style `for` at parse time, so all existing optimisation paths (`:unroll`, the loop unroller, pointer induction) apply:

| Source                                     | Equivalent C-style                            |
|--------------------------------------------|-----------------------------------------------|
| `for (T i in 0..N)`                        | `for (T i = 0; i < N; i += 1)`                |
| `for (T i in 0...N)`                       | `for (T i = 0; i <= N; i += 1)`               |
| `for (T i in 0..N step 2)`                 | `for (T i = 0; i < N; i += 2)`                |
| `for (T i in N..0)`     *(literal bounds)* | `for (T i = N; i > 0; i -= 1)`                |
| `for (T i in N..0 step -3)`                | `for (T i = N; i > 0; i -= 3)`                |

## For-in (array slice)

The for-in array form also accepts a range expression inside the subscript. This produces a slice, a sub-range view that the loop walks element by element:

```c
u8 arr[10] = { 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };

for (u8 v in arr[2..5])  { ... }   // 30, 40, 50         (m..n exclusive)
for (u8 v in arr[2...4]) { ... }   // 30, 40, 50         (m...n inclusive)
for (u8 v in arr[..3])   { ... }   // 10, 20, 30         (open start = 0)
for (u8 v in arr[7..])   { ... }   // 80, 90, 100        (open end = arr.length)
```

The base may be either a fixed-size array or a heap-allocated pointer from `new T[N]`; for heap pointers the open-end form (`buf[m..]`) reads `.length` from the heap-block header at loop entry, same as the plain `for (u8 v in buf)` form.

Bounds can be any integer expression. They do not have to constant-fold:

```c
u8 from = 2;
u8 to   = 7;
for (u8 v in arr[from..to]) { ... }  // 30, 40, 50, 60, 70
```

The codegen lowers the slice to a counted iteration with the counter starting at `m` (or 0) and exiting when it would reach `n` (or the base's `.length`). The inclusive form adds 1 to the cap at loop setup, so the inner compare stays a plain `idx < cap` and `..` and `...` have the same per-iteration branch.

Slice expressions are only valid as the iterable of a `for-in` loop. Passing a slice to a function or storing it in a variable needs a first-class slice value type (a fat pointer with length), which the language does not have.

## While

```c
while (running) {
    tick();
}
```

The body runs while the condition evaluates to non-zero.

## Loop control: break and continue

`break` exits the enclosing loop. `continue` skips the rest of the current iteration and jumps to the loop's increment / re-test.

```c
for (u8 i = 0; i < n; i++) {
    if (skip[i]) continue;
    if (i == limit) break;
    process(i);
}
```

## `defer`

`defer { ... }` registers a block to run when the **enclosing scope** exits by any path: fall-through, `return`, `break`, `continue`, or a propagating [`throw`](/compiler/language/errors/). You write the release next to the acquisition instead of at the bottom of the function, and every exit path runs it.

```c
void render(Scene* s) {
    s.lock();
    defer { s.unlock(); }             // released however we leave

    if (!s.visible) return;           // …here
    if (s.clipped)  return;           // …or here
    s.drawEverything();               // …or by falling off the end
}
```

The body must be a block. It runs at several exit points, so the braces keep what is deferred unambiguous.

### LIFO, and per-scope

Multiple defers in one scope run **last-registered-first**, and each defer belongs to the block that registered it. An inner `{ }` runs its own defers at its closing brace, not at function exit.

```c
{
    defer { Stdio.printf("A\n"); }
    defer { Stdio.printf("B\n"); }
    Stdio.printf("body\n");
}
// body
// B
// A
```

Inside a loop body, the defer runs at the end of **each iteration**, including the iteration that `break`s or `continue`s out.

```c
for (u32 i = (u32)0; i < (u32)3; i = i + (u32)1) {
    defer { Stdio.printf("d%d\n", i); }
    if (i == (u32)1) break;
}
// d0
// d1
```

### It runs before the scope's ARC releases

A scope exits by running **its defers first**, then its [ARC teardown](/compiler/language/memory/#automatic-reference-counting-arc), then moving outward to the next scope. The defer body can therefore still use the local it cleans up.

```c
{
    Res* r = new Res((u32)7);
    defer { Stdio.printf("defer sees id=%d\n", r.id); }
}
// defer sees id=7
// dealloc 7
```

### No closures involved

`defer` is a statement, not a value. Its body is lowered inline at each exit point of the scope that registered it. Nothing is captured or allocated, and there is no object to keep alive. It reads the enclosing scope's locals directly because it is emitted in that scope. This gives `defer` zero cost on every backend, including the 6502, without closures.

The compiler enforces two consequences:

- **`return` inside a defer body is rejected.** The body runs at every exit of its scope, so there is no single return for it to perform.
- **A `break` or `continue` that would leave the body is rejected.** A `break` inside a loop or `switch` written within the body is fine, because it targets that construct.

```c
defer { return; }                       // error
defer { break; }                        // error (inside a loop's scope)
defer { for (…) { … break; } }          // fine — the break is the inner loop's
```

## Manual unrolling: `:unroll`

The auto-unroller runs at `-O2` and above. It fully unrolls a counted loop whose constant trip count is within the target's cap (4 on xt6502, 32 on arm64 and x86-64; see [Optimisation](/compiler/usage/optimization/#-flu--loop-unroll-cap)), tunable with `-Flu`. To unroll a longer loop, annotate it with `:unroll`, which raises the cap for that loop to 64 iterations, or to the target's cap if that is higher:

```c
for (u8 i = 0; i < 40; i++) :unroll {
    poke(scrn + i, ' ');
}
```

The annotation goes after the closing `)` of the `for` clause and before the body. It has no effect at `-O0` or `-O1`, where the unroller does not run. Use it sparingly: every unroll trades binary size for cycle count.

## Program entry: `main`

Execution begins at `main`. Two signatures are accepted:

```c
void main(void) {
    // …
}

i16 main(u8 numArgs, string args[]) {
    // …
}
```

When `main` returns, the program issues an `RTS` to the caller. If you pass `-Q loop` on the command line (`xcc-bootstrap` only), the runtime spins in an infinite loop instead.

## Worked example

Every loop form in one runnable program:

```c
// loops.xc — every loop form the language has.
#import "Foundation.xc"
#import "Stdio.xc"

i32 main(void)
{
    // 1. C-style for: init; condition; step.
    Stdio.print("for       ");
    for (u16 i = (u16)0; i < (u16)5; i = i + (u16)1)
        Stdio.printf("%d ", i);
    Stdio.print("\n");

    // 2. while — the test runs first, so the body may not run at all.
    Stdio.print("while     ");
    u16 n = (u16)5;
    while (n > (u16)0) { Stdio.printf("%d ", n); n = n - (u16)1; }
    Stdio.print("\n");

    // 3. for ... in over an array, with and without the element type.
    u16 squares[5];
    for (u16 i = (u16)0; i < (u16)5; i = i + (u16)1)
        squares[i] = i * i;
    Stdio.print("for-in    ");
    for (u16 v in squares)
        Stdio.printf("%d ", v);
    Stdio.print("\n");

    Stdio.print("inferred  ");
    for (v in squares)
        Stdio.printf("%d ", v);
    Stdio.print("\n");

    // 4. break and continue, as in C.
    Stdio.print("evens<=6  ");
    for (u16 i = (u16)0; i < (u16)10; i = i + (u16)1) {
        if ((i & (u16)1) != (u16)0) continue;
        if (i > (u16)6) break;
        Stdio.printf("%d ", i);
    }
    Stdio.print("\n");

    // 5. Nested: break leaves only the INNERMOST loop.
    Stdio.print("nested    ");
    for (u16 r = (u16)0; r < (u16)3; r = r + (u16)1)
        for (u16 c = (u16)0; c < (u16)3; c = c + (u16)1) {
            if (c == (u16)2) break;
            Stdio.printf("%d%d ", r, c);
        }
    Stdio.print("\n");

    // 6. `: unroll` asks the optimiser to unroll a counted loop fully.
    //    Purely a performance annotation — the result is identical.
    Stdio.print("unrolled  ");
    for (u16 i = (u16)0; i < (u16)4; i = i + (u16)1) : unroll
        Stdio.printf("%d ", i);
    Stdio.print("\n");
    return 0;
}
```

```
for       0 1 2 3 4
while     5 4 3 2 1
for-in    0 1 4 9 16
inferred  0 1 4 9 16
evens<=6  0 2 4 6
nested    00 01 10 11 20 21
unrolled  0 1 2 3
```

There is **no** `do/while`: the loop forms are `while`, C-style `for`, and
`for ... in` over an array, a range or a slice.
