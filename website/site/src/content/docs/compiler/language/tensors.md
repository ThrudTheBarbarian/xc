---
title: Tensors
description: The tensor<T, R> value type — creating, indexing, views (slices, transpose, broadcast, view and reshape), element-wise expressions with broadcasting, value semantics, bounds checks, par and C.
---

A `tensor<T, R>` is an R-dimensional array of elements of type T, held as a
value. The value is a view of a buffer: a reference to the buffer's storage,
an element offset, R shapes and R strides. Copying the value copies the view;
the elements stay where they are, and every copy reads and writes the same
ones.

```c
tensor<f32, 2> m = new tensor<f32, 2>(3, 4);    // 3 rows of 4, zero-filled
m[1, 2] = 2.5;
m[1, 2] += 1.0;
f32 x = m[1, 2];                                // 3.5
```

Tensors work on every target except xt6502, whose functions return at most 16
bytes by value: a tensor value is wider, so using one there is an error.

## The type

`tensor<T, R>` names the element type T and the rank R:

- T is a scalar: `i8`, `u8`, `i16`, `u16`, `i32`, `u32`, `i64`, `u64`,
  `bool`, `f64`, `f32`, `f16`, `bf16`, `f8`, `f4`, or a pack of one of the
  small floats, as in `tensor<f8:pack(e5m2), 2>`. A class, a struct, a
  pointer or a typedef is refused.
- R is an integer literal from 1 to 8.

Each pair of T and R is a type of its own. A `tensor<f32, 2>` does not convert
to a `tensor<f32, 3>` or a `tensor<f16, 2>`.

## Creating a tensor

`new tensor<T, R>(d0, …)` takes one dimension for each index, R in all. Each is
an integer expression. The result is a contiguous row-major tensor whose
elements are all zero: its last stride is 1 and each stride before it is the
next stride times the next dimension.

```c
tensor<u8, 3> volume = new tensor<u8, 3>(depth, rows, cols);
```

The buffer is page-aligned, as a [`simd:` array](/compiler/language/par/#arrays-the-gpu-shares-simd-pointers)
is. Its size is the element count times the element's size; `f4` elements
take half a byte each, two to a byte, the first in the low nibble.

A tensor variable declared without a value has no storage. Index it only
after assigning a tensor to it.

## Elements

`t[i, j, …]` reads or writes one element and takes exactly R indices. An
index is an integer of any width. The element's address is the buffer plus
`offset + i0 × stride0 + i1 × stride1 + …` elements.

Reading and writing follow the usual conversions to and from the element
type: a literal takes the element's type (`h[0, 0] = 0.5` on a
`tensor<f16, 2>`), and a conversion that loses information needs a cast
(`h[0, 0] = (f16)x` for an `f32` x). Compound assignment works
(`t[i, j] += v`), and evaluates `t` and the indices once. Each element access
is a call of the tensor's accessor, which `-O2` inlines; at `-O0` it stays a
call. `t[i, j]++` and
`&t[i, j]` are not available.

Writing an `f4` element reads its byte, replaces one nibble and writes the
byte back. Two threads writing the two elements of one byte can lose a write,
as with C bitfields.

## Members

| Member | Gives |
|---|---|
| `t.rank` | R, a `u64` |
| `t.shape(k)` | the size of dimension k |
| `t.stride(k)` | the stride of dimension k, in elements |
| `t.offset()` | the element offset of `t[0, 0, …]` in the storage |
| `t.count` | the number of elements, the product of the shapes |
| `t.isContiguous` | `true` when the elements are packed row major with no gaps |
| `t.data()` | a `T*` to the first element, for C |
| `t.bytes()` | for `f4` only: a `u8*` to the byte holding the first element |

k may be a run-time value. An `f4` element has no byte address, so a
`tensor<f4, R>` has no `data()`; `bytes()` gives its bytes, two elements to
each.

## Views

A slice, a transpose, a permutation, a broadcast and a `view` are views: each
is a new tensor value over the same storage, with its own offset, shapes and
strides. No element is copied, and a write through a view is a write to the
storage, seen through every other value of it.

Each view is made from the header of the tensor it is taken from, so a view
of a view is one header like any other: the offsets add and the strides are
carried over. Strides count elements, not bytes, so a view of an `f4` tensor
may start at an odd element.

### Slicing

`t[…]` with a range among its positions is a slice. It takes R positions, one
for each dimension, and each is one of:

| Position | Keeps |
|---|---|
| `a..b` | elements a to b − 1 of the dimension |
| `a...b` | elements a to b |
| `a..` | elements a to the end |
| `..b`, `...b` | elements 0 to b − 1, or to b |
| `..` | the whole dimension |
| `i` | element i only, and drops the dimension |

Ranges and indices mix freely. The result is a `tensor<T, R'>`, where R' is R
less the number of indices; a subscript with no range at all is an element.

```c
tensor<f32, 3> c = new tensor<f32, 3>(2, 3, 4);
tensor<f32, 2> p = c[1, .., 1..3];       // shape 3 × 2, strides 4, 1
tensor<f32, 1> row = c[0, 2, ..];        // shape 4
tensor<f32, 2> q = p[1.., ..1];          // shape 2 × 1, offset 17
p[0, 0] = 5.0;                           // c[1, 0, 1] is 5.0 too
```

A slice starting at `start` in dimension k adds `start × stride_k` to the
offset, and a kept dimension's shape is its range's length, with the stride
unchanged. Bounds are integers of any width. Assigning to a slice writes
into the elements it views (see
[A new tensor, or a write in place](#a-new-tensor-or-a-write-in-place)).

A class's own [range index operator](/compiler/language/operators/#index-operators)
still takes a range alone in its brackets, with both bounds. Mixing ranges
with indices, and leaving a bound out, are for tensors.

### Transpose and permute

`t.transpose()`, on a rank-2 tensor, swaps the two dimensions: their shapes
and their strides. `t.permute(p0, …)` takes R integer literals, a permutation
of 0 to R − 1, and gives dimension k of the result the shape and stride of
dimension p_k of `t`. The permutation is checked as the program compiles.

```c
tensor<f32, 2> mt = m.transpose();       // mt[j, i] is m[i, j]
tensor<f32, 3> cp = c.permute(2, 0, 1);  // cp[k, i, j] is c[i, j, k]
```

### Broadcast

`t.broadcast(d0, …)` gives a view of rank R' ≥ R with the shapes `d0, …`. The
shapes line up from the last dimension. Each dimension of `t` either has the
target size, or has size 1 and repeats; each new leading dimension repeats
too. A repeated dimension has stride 0. Any other shape stops the program
with a report.

```c
tensor<f32, 1> bias = new tensor<f32, 1>(4);
tensor<f32, 2> b = bias.broadcast(3, 4); // b[i, j] is bias[j]
```

A broadcast view repeats elements, so a write through it would change every
element it repeats. Such a write is an error where the compiler sees it: on a
`broadcast(…)` result directly, or through a local set once from one. A write
through a broadcast view passed elsewhere writes the one storage element
behind all the positions it repeats.

### view and reshape

`t.view(d0, …)` gives a view of any rank over the same elements, in row-major
order, with the shapes `d0, …`. Their product must be `t.count`. The strides
must be able to give the new shape: a contiguous tensor can always be viewed,
and so can one whose dimensions are contiguous where the new shape merges or
splits them. A tensor that cannot be viewed stops the program with a report;
`m.transpose().view(12)` is one.

`t.reshape(d0, …)` gives the same result as `view` when the strides allow,
and otherwise copies the elements, in row-major order, into a new contiguous
storage. The element count must match.

Where the compiler knows every shape, it checks both as the program
compiles: a local made by `new tensor<…>(…)` with literal dimensions and
never assigned again, viewed or reshaped with literal shapes, perhaps after a
`transpose()` or a `permute(…)`. Otherwise the checks run with the program.

### copy

`t.copy()` gives a tensor with the same shapes and elements in a new
contiguous storage of its own. `t.isContiguous` says whether a tensor is
contiguous already.

## Expressions

Arithmetic, comparisons, unary minus, casts and some `Math` functions work on
whole tensors, element by element. The value of an expression is a new tensor:
each element is computed from the operands' elements at its position.

```c
tensor<f32, 2> a = new tensor<f32, 2>(3, 4);
tensor<f32, 1> b = new tensor<f32, 1>(4);
tensor<f32, 2> c = a * b + 1.0;          // c[i, j] is a[i, j] * b[j] + 1.0
tensor<f32, 2> d = Math.sqrt(a * a + c) - c;
tensor<bool, 2> big = d > 0.5;
```

### Operators and functions

| Form | Elements |
|---|---|
| `a + b`, `a - b`, `a * b`, `a / b` | any number type |
| `a % b` | integers |
| `-a` | any number type |
| `a < b`, `a <= b`, `a > b`, `a >= b` | any number type; the result is a `tensor<bool, R>` |
| `a == b`, `a != b` | any type, `bool` included; the result is a `tensor<bool, R>` |
| `(tensor<E, R>)a` | any type; a tensor of the same rank with elements of type E |
| `Math.sqrt`, `Math.exp`, `Math.ln`, `Math.sin`, `Math.cos`, `Math.tan`, `Math.atan` | `f64`, `f32`, `f16`, `bf16`, `f8`, `f4` and their packs |
| `Math.abs` | the floats above, and `i8`, `i16`, `i32` |
| `Math.pow(a, b)` | the floats above |

Either operand of a binary operator, and the second of `Math.pow`, may be a
scalar: `t * 2.0`, `1 - t`. Other operators (`&`, `<<`, `&&`, `~`, `!`) and
other `Math` functions take no tensors.

Each element is computed as the same expression on scalars would compute it.
An operation works in its operands' type and rounds its result to that type,
so an `f16` expression rounds after every operation, and `Math` functions on
`f16`, `bf16`, `f8` and `f4` work in `f32` and round the result. Integer
arithmetic wraps at the operands' width: two `u8` tensors add to a `u8`
tensor. A cast converts each element as a scalar cast does.

### Element types

Two operands of different element types mix only when one type holds every
value of the other, as for scalars: a wider integer of the same signedness, or
a wider signed integer for an unsigned one, and among floats `f16` and `bf16`
into `f32`, `f32` into `f64`, `f8` into `f16`, and `f4` into any float. The
result has the wider type. Integers and floats do not mix, and `bool` mixes
with nothing but `bool`. Anything else is an error that names the cast to
write:

```
error: 'tensor<f16, 1>' and 'tensor<bf16, 1>' have no common element type: neither holds every value of the other; cast one, as in (tensor<f32, 1>)x
```

A literal takes the element type of the tensor beside it: in `h * 0.5` on a
`tensor<f16, 1>`, the `0.5` is an `f16`. An integer literal must fit an
integer element type. A scalar variable mixes as its type does.

### Broadcasting

The operands' shapes line up from the last dimension. In each dimension the
sizes are equal, or one of them is 1 and repeats; a dimension an operand of
lower rank lacks counts as 1. The result has the larger rank and, in each
dimension, the larger size.

```c
tensor<f32, 2> m = new tensor<f32, 2>(3, 4);
tensor<f32, 2> col = new tensor<f32, 2>(3, 1);
tensor<f32, 1> row = new tensor<f32, 1>(4);
tensor<f32, 2> p = m * col + row;        // 3 × 4
tensor<f32, 2> q = col + row;            // 3 × 4
tensor<f32, 3> r = new tensor<f32, 3>(2, 3, 4) - m;  // 2 × 3 × 4
```

Where the compiler knows the shapes (locals made by `new tensor<…>(…)` with
literal dimensions and never assigned again), shapes that do not broadcast
are an error. Otherwise the program checks them as it runs, and stops with a
report and status 134:

```
=== xcc: tensor shapes that do not broadcast ===
  dimension 1 of the result: sizes 4 and 5; each must be the same, or 1
```

### A new tensor, or a write in place

`c = a + b` makes a new tensor with contiguous storage of its own, of the
broadcast shape; `c` refers to it from then on. Assigning a tensor variable
from another (`c = a`) copies the view, as before.

A slice on the left writes into the elements it views:

```c
m[.., ..] = m * 2.0 + row;               // every element of m
m[0, ..] = row;                          // row 0
m[1.., 2] = 0.0;                         // a scalar fills
```

The value broadcasts to the slice's shape; the slice does not broadcast.
`m[.., ..]` names all of `m`, so `m[.., ..] = expr` overwrites `m`'s elements
in place, where `m = expr` makes `m` refer to a new tensor. Each element
converts to the destination's element type when the type holds every value of
the value's type; otherwise a cast is needed (a `tensor<bool, R>` written into
float elements needs `(tensor<f32, R>)`).

A compound assignment, `t += u` (and `-=`, `*=`, `/=`, `%=`), writes in place
too, on a tensor variable or a slice: every value that refers to the storage
sees the change.

### Writes into a storage the value reads

A write in place may read the storage it writes, through the same tensor or
through a view of it. An operand at the destination's own offset and strides
(`a += a`, `a[.., ..] = a * 2.0`) reads each element before the element is
written, so the write needs nothing more. An operand that views the same
storage at another offset or with other strides (`a[1..] = a[..9] + 1`,
`m[.., ..] = m.transpose() - m`, `m += m[0, ..]`) would read elements the
write has already changed, so its value is computed into a temporary first
and then copied into the destination. Which of the two happens is decided as
the program runs, from the storages, offsets and strides, so it holds for
parameters and fields too. A result in a new tensor shares no storage with its
operands.

### One pass for each expression

An expression is computed by one loop over the result's elements, however
many operators it has: `Math.sqrt(a * b + c) - e` reads each element of `a`,
`b`, `c` and `e` once and makes no tensor for `a * b` or for the square root.
Each statement is one loop; two statements are two.

The loop runs on the CPU's threads, as a [CPU par block](/compiler/language/par/)
does, when the result has 32768 elements or more; a smaller one, one
started inside a running par block, and every one on a target without
threads (wasm32, m68k) runs on the calling thread.
`XC_PAR_THREADS` sets the number of threads. When the result and every operand
are contiguous with the same shape, the loop is one flat loop the vectoriser
can take; otherwise it walks the result's rows, reading each operand through
its offset and strides (a broadcast dimension has stride 0). An `f4` result is
split where a byte starts, so no two threads write one byte. A write through a
view that repeats elements (a broadcast) runs on one thread.

A fused expression written in place runs as fast as the same computation
written as a par loop over the elements; see [Performance](#performance) below.

### Performance

`a * b + c` on `f32` tensors, timed against the same loop written as a CPU
par block over plain arrays, and against C built with clang `-O2`, serially
and with OpenMP. The first case has 10<sup>7</sup> contiguous elements; the
second is 4096 × 4096 with `a` and `b` transposed, so they are read with a
stride of 4096 elements. The machines are the arm64 macOS and x86-64 Linux
machines of the [performance page](/compiler/performance/), with all their
threads. Times are in milliseconds, each the median of three runs of a
program that reports the median of five.

| `a * b + c` | arm64 | x86-64 |
|---|---|---|
| 10<sup>7</sup>, new tensor (`e = a * b + c`) | 1.32 | 3.28 |
| 10<sup>7</sup>, in place (`d[..] = a * b + c`) | 1.11 | 2.78 |
| 10<sup>7</sup>, par block | 1.06 | 2.74 |
| 10<sup>7</sup>, clang `-O2` | 1.71 | 3.74 |
| 10<sup>7</sup>, clang `-O2 -fopenmp` | 1.03 | 2.70 |
| 4096 × 4096 strided, new tensor | 37.1 | 33.7 |
| 4096 × 4096 strided, in place | 36.7 | 33.9 |
| 4096 × 4096 strided, par block | 36.7 | 40.6 |
| 4096 × 4096 strided, clang `-O2` | 101.3 | 166.4 |
| 4096 × 4096 strided, clang `-O2 -fopenmp` | 36.8 | 32.9 |

Both cases are limited by memory bandwidth. A write in place runs at the
speed of the par block and of OpenMP; a new tensor takes longer by the time
it takes to allocate the 40 MB result and touch it for the first time.

## Value semantics

A tensor value behaves like a [stack instance](/compiler/language/classes/#stack-instance)
of a class that refers to the storage:

- `tensor<f32, 2> b = a;`, passing `a` to a function, returning it and storing
  it in a field of a class each copy the view and add a reference to the
  storage.
- A struct cannot hold a tensor, since copying a struct copies its bytes and
  counts no references. Hold the tensor in a class.
- When a value goes out of scope, or is overwritten, its reference is dropped.
  The storage and its buffer are freed when the last value referring to them
  goes.
- `&t` follows the rules for a stack instance: the variable moves to the heap
  and its address is a strong reference.
- `==` and `!=` compare elements, as the other comparisons do (see
  [Expressions](#expressions)): `a == b` is a `tensor<bool, R>`, not a
  condition. To ask whether two values are views of one storage, compare
  their shapes, strides and `data()` pointers.

```c
tensor<i32, 1> a = new tensor<i32, 1>(4);
tensor<i32, 1> b = a;     // the same storage
b[0] = 7;                 // a[0] is 7 too
```

`TensorStorage.live()` gives the number of storages alive, for tests.

## Checked builds

With [`-fbounds-check`](/compiler/usage/cli/#checked-builds), each index is
checked against its dimension's shape before the element is reached. A
failure reports the subscript's site with the dimension, the index and the
shape, and stops the program with status 134:

```
=== xcc: out-of-bounds access ===
  at grid.xc:8:13, dimension 1
  array: index 3, but it holds 3 elements
```

A slice is checked before it is taken: each range must keep
`0 ≤ start ≤ end ≤ shape`, and each index in it must be below its
dimension's shape. A failure reports the slice's site, the dimension and the
bounds:

```
=== xcc: out-of-bounds slice ===
  at grid.xc:12:25, dimension 1
  slice 1..5, but the dimension holds 3 elements
```

`t.shape(k)` and `t.stride(k)` check k. Without the flag there are no checks.
The checks of `view`, `reshape` and `broadcast` run in every build.

## In a par block

A [`par` block](/compiler/language/par/) may read and write tensor elements.
Such a block runs on the CPU's threads; it has no GPU form yet, and the
compiler warns that it runs on the CPU only, with the reason. `XC_PAR_REPORT=1`
reports the run as for any CPU block.

Two tensor values may share one storage, so the block's work items must be
independent in a form the compiler can check:

- The block writes through one tensor value only. Writes through two values
  are refused, even if they are different storages. The exception is two
  slices of one tensor that split its first dimension at the same place,
  `a = t[lo..h, …]` and `b = t[h.., …]`, with a, b and t each assigned only
  where they are declared (or parameters never assigned) and h the same
  expression in both, made of literals and such names. They share no element,
  so the block may write both.
- Every write to a tensor has one first index, `k × i + c` with k not 0, in
  the block's index i. Each work item then writes its own rows.
- A read of a written tensor has its first index too, and so does a read of
  any other tensor of the same element type, since it may share the written
  tensor's storage (a copy, a view, a parameter, a field). The exception is two
  tensors known to be different storages: locals that are each made by their
  own `new tensor<…>(…)` and never assigned again or have their address
  taken, or views of two such locals taken by slicing, `transpose()`,
  `permute(…)` or `view(…)`. The other one may be read anywhere. Tensors of
  another element type may be read anywhere.

A view's first index is not the storage's: a slice that starts at row 1, read
at the written row, reaches the next row of the storage. So when a block
writes a tensor that may share a storage with another tensor of its element
type that it reads, it checks as it starts whether the two are views of one
storage with different offsets or strides, and whether the written one
repeats elements (a broadcast). If either holds, the block runs on the
calling thread, one work item after another, as its source reads. A view
never counts as made by `new` for these rules.

A block that breaks a rule is refused, and the message says what to do:
"writes the tensor 't' and reads the tensor 'u' at a different row; they may
share storage: read 'u' at the same row, or copy it first". A loop that
`--par-style=auto` would make into a block runs serially instead.

```c
par scale
{
    for (u64 i in 0..rows)
        for (u64 j in 0..cols)
            out[i, j] = in[i, j] * 2.0 + in[rows - 1 - i, j];
}
```

## C

C has no tensor type. A function C calls or defines, written `extern`, cannot
take or return a tensor. Pass `t.data()` and the shape instead:

```c
extern void scale(f32* p, u64 n, f32 by);
scale(m.data(), m.count, 2.0);
```

## Across modules

Tensor types appear in a library's interface like any other type: a library
function `tensor<f32, 2> make(u64 r, u64 c)` can be called from a client that
has only the interface. So can one that returns a view, such as
`tensor<f32, 1> column(tensor<f32, 2> t, u64 j)` returning `t[.., j]`.

## Worked example

```c
#import "Stdio.xc"

tensor<f32, 2> identity(u64 n)
{
    tensor<f32, 2> m = new tensor<f32, 2>(n, n);
    for (u64 i = 0; i < n; i++)
        m[i, i] = 1.0;
    return m;
}

f32 trace(tensor<f32, 2> m)
{
    f32 s = 0.0;
    for (u64 i = 0; i < m.shape(0); i++)
        s += m[i, i];
    return s;
}

i32 main(void)
{
    tensor<f32, 2> m = identity(3);
    m[0, 2] = 2.5;
    m[1, 1] += 4.0;
    Stdio.printf("rank %d, %d x %d, %d elements\n", (i32)m.rank, (i32)m.shape(0), (i32)m.shape(1), (i32)m.count);
    Stdio.printf("strides %d %d, contiguous %d\n", (i32)m.stride(0), (i32)m.stride(1), m.isContiguous ? 1 : 0);
    Stdio.printf("trace %.1f\n", trace(m));

    tensor<f32, 2> view = m;          // the same storage
    view[2, 0] = 7.0;
    Stdio.printf("m[2, 0] %.1f\n", m[2, 0]);

    f32* p = m.data();                // row major: element [0, 2] is p[2]
    Stdio.printf("p[2] %.1f\n", p[2]);
    Stdio.printf("storages alive %d\n", (i32)TensorStorage.live());
    return 0;
}
```

```
rank 2, 3 x 3, 9 elements
strides 3 1, contiguous 1
trace 7.0
m[2, 0] 7.0
p[2] 2.5
storages alive 1
```
