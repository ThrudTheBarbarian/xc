---
title: Tensors
description: The tensor<T, R> value type — creating, indexing, members, value semantics, bounds checks, par and C.
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
(`t[i, j] += v`), and evaluates `t` and the indices once. `t[i, j]++` and
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
| `t.count` | the number of elements, the product of the shapes |
| `t.isContiguous` | `true` when the elements are packed row major with no gaps |
| `t.data()` | a `T*` to the first element, for C |
| `t.bytes()` | for `f4` only: a `u8*` to the byte holding the first element |

k may be a run-time value. An `f4` element has no byte address, so a
`tensor<f4, R>` has no `data()`; `bytes()` gives its bytes, two elements to
each.

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
- `==` and `!=` are not defined for tensors. Compare elements, or compare the
  shapes and the `data()` pointers.

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

`t.shape(k)` and `t.stride(k)` check k. Without the flag there are no checks.

## In a par block

A [`par` block](/compiler/language/par/) may read and write tensor elements.
Such a block runs on the CPU's threads; it has no GPU form yet, and the
compiler warns that it runs on the CPU only, with the reason. `XC_PAR_REPORT=1`
reports the run as for any CPU block.

Two tensor values may share one storage, so the block's work items must be
independent in a form the compiler can check:

- The block writes through one tensor value only. Writes through two values
  are refused, even if they are different storages.
- Every write to that tensor has the same first index, `k × i + c` with k not
  0, in the block's index i. Each work item then writes its own rows.
- A read of the written tensor has that first index too. Other tensors may be
  read anywhere.

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
has only the interface.

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
