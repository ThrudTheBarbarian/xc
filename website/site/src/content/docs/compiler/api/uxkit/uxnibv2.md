---
title: UXNibV2
description: "The UXNB v2 nib chunk, parsed in xtc rather than in the host, so variant selection and logical-id resolution work on every backend."
---

`UXNibV2` reads the **UXNB v2** chunk out of a `.rsc` file, entirely in portable
code.

```c
#use <UXKit>            // or #import "UXNibV2.xc"
```

## Why v2 is parsed here and v1 is not

v1's chunk is read by `libGEM`'s C `rscload`, whose surface
[`UXNib`](/compiler/api/uxkit/uxnib/) declares. That makes
**v1 nib loading GEM-only**.

v2 is parsed here, from the raw bytes, with no host dependency. Variant
selection, logical-id resolution and validation therefore run, and are
gated, on every backend, wasm32 included.

A resource format read by one platform's C library cannot be used by the
other six backends, which is why v2 exists.

## The two formats coexist cleanly

The **magics differ**:

| magic | |
| --- | --- |
| `UXNB` | v2 — invisible to the C v1 reader |
| `XGNB` | v1 — this parser reports it as version 1 |

A v2 file cannot confuse the old reader. A v1 file handed to this parser is
presented per the spec's compatibility rule: **every tree its own single-variant
form of class `any`**.

There is no migration step. Old resources keep working, new ones gain
variants, and the same code path consumes both.

## Variant selection walks a chain

```c
i32 tree = nib.selectTree(formId, klass, &chosenClass);
```

A form can carry several **variants** (a phone layout, a tablet layout, a
desktop one). `selectTree` picks the best available for a requested class by
walking a fallback chain of up to four steps.

A nib that only ships a `desktop` variant still loads on a phone by falling
back. A nib that ships both gets the right one with no `if` in the
application.

`chosenClass` reports which variant was used. This matters when the
answer was a fallback rather than the exact match: it separates
*"there is a phone layout"* from *"the desktop layout is in use on a
phone"*.

A form with no usable variant returns `-1` rather than guessing.

## Logical ids, and why absent is legal

```c
i32 obj = nib.objForLogical(tree, logicalId);
// -1 means the variant genuinely does not have that control
```

A control is referred to by a **logical id** instead of its index in a tree,
so the same code binds to it in every variant even though the layouts differ.

`-1` is a normal answer, not an error:

:::note[A missing control is a design decision, not a failure]
A phone variant may drop a control the desktop one has, such as a
secondary toolbar or an advanced option. `objForLogical` returns `-1` and the
caller **skips it silently**.

If every variant had to carry every control, variants would differ only in
geometry, and a layout system already handles geometry.
:::

## The parser borrows the caller's buffer

:::caution[Every `u8*` it returns points into the bytes you passed in]
Class names, member names and form names are not copied. They are valid only
while the caller keeps the buffer alive and unmodified.

Copy anything you intend to keep with
[`UXStr.dup`](/compiler/api/uxkit/uxstr/#dup). Freeing the `.rsc` bytes while
holding a name from them leaves a dangling pointer that reads as garbage
instead of crashing.
:::

Borrowing keeps loading a nib cheap: a resource file with hundreds of names
costs no allocations to parse.

All multi-byte fields are **big-endian**, matching the `.rsc` body. The
parser is byte-order-independent, and a resource built on one machine loads on
another.

## Topics

[open](#open) · [parse](#parse) · [version](#version) · [formCount](#formcount) · [formAt](#format) · [formOffById](#formoffbyid) · [formName](#formname) · [selectTree](#selecttree) · [objForLogical](#objforlogical) · [resolveView](#resolveview) · [str](#str)

### open

```c
static UXNibV2* open(u8* rsc, u32 rscLen)
```

Finds the chunk in a resource file. The buffer is **borrowed**; see the
[caution](#the-parser-borrows-the-callers-buffer).

### parse

```c
bool parse(void)
```

Reads the header and the section offsets. Returns `false` on a malformed chunk.
Check this before trusting anything else.

### version

```c
i32 version(void)
```

`1` for a v1 file presented through the compatibility rule, `2` for a real v2
chunk.

### formCount

```c
i32 formCount(void)
```

### formAt

```c
u32 formAt(i32 f)
```

The byte offset of the i-th form record.

### formOffById

```c
u32 formOffById(i32 formId)
```

By id rather than by index. `0` when absent.

### formName

```c
u8* formName(i32 formId)
```

Borrowed, like every string here.

### selectTree

```c
i32 selectTree(i32 formId, i32 klass, i32* chosenClass)
```

The best variant for a form-factor class. See
[above](#variant-selection-walks-a-chain).

### objForLogical

```c
i32 objForLogical(i32 tree, i32 logicalId)
```

An object index within a tree, or `-1`.

### resolveView

```c
i32 resolveView(u32 refAt, i32 tree)
```

Resolves a reference record to an object. References carry a **space** saying
what they point at: a view by coordinate, a top-level object, the owner, or a
view by logical id. This lets a connection survive a variant that moved
things around.

### str

```c
u8* str(u32 off)
```

A string from the chunk's table, borrowed.

## See also

- [`UXNib`](/compiler/api/uxkit/uxnib/): v1, and the host surface that makes it
  GEM-only
- [`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/): `formFactorClass`, which
  supplies the class `selectTree` is asked for
- [`UXViewTree`](/compiler/api/uxkit/uxviewtree/): what a loaded nib becomes
