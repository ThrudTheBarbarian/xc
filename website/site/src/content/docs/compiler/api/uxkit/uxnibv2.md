---
title: UXNibV2
description: "The UXNB nib chunk (v2 and v3), parsed in xc rather than in the host, so variant selection and logical-id resolution work on every backend."
---

`UXNibV2` reads the **UXNB** chunk (v2, and from 0.67 v3) out of a `.rsc` file,
entirely in portable code. It reads the bytes in place; to load a form, use
[`UXNib`](/compiler/api/uxkit/uxnib/).

```c
#use <UXKit>            // or #import "UXNibV2.xc"
```

## Why v2 is parsed here and v1 is not

v1's chunk is read by `libGEM`'s C `rscload`, whose surface
[`UXNibGem`](/compiler/api/uxkit/uxnibgem/) declares. That makes
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
| `UXNB` | v2 and v3 — invisible to the C v1 reader |
| `XGNB` | v1 — this parser reports it as version 1 |

A v2 file cannot confuse the old reader. A v1 file handed to this parser is
presented per the spec's compatibility rule: **every tree its own single-variant
form of class `any`**.

There is no migration step. Old resources keep working, new ones gain
variants, and the same code path consumes both.

## v3: scoped connections

From 0.67 the chunk can be version 3. Three things change:

- A connection carries a **scope**, the layout themes it binds in.
  [`connScope`](#connscope) reads it, and every v2 connection reads as 0, all
  themes.
- A top-level object carries a **label**, the name the designer shows.
- The chunk can carry **extension sections**, `{tag, size, body}`, which a
  reader skips by size when it does not know the tag.

The classic body is unchanged, so a v3 file is still a plain `.rsc` to a GEM
AES.

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

## Orientation is a second axis

A phone or tablet layout can also come in **portrait** and **landscape**
trees. A rotation can re-nest a layout, not just stretch it, so each
orientation gets a whole tree of its own, exactly as each form factor
does.

```c
i32 tree = nib.selectTreeOriented(formId, gDriver.formFactorClass(),
                                  gDriver.orientation(), &cls, &orient);
```

Within each class of the fallback chain the order is:

1. a tree for the current orientation;
2. a tree with no orientation, drawn to work both ways;
3. the other orientation's tree.

Only then does selection move on to the next class. A tablet held upright
with only a landscape tablet layout therefore gets that layout, not the
desktop's.

The orientation rides in the top two bits of a variant's class word (`0`
none, `1` portrait, `2` landscape). Files written before it existed have
`0` there and read unchanged. [`selectTree`](#selecttree) masks those bits
off, so code that ignores orientation keeps working.

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

[open](#open) · [parse](#parse) · [version](#version) · [formCount](#formcount) · [formAt](#format) · [formOffById](#formoffbyid) · [formName](#formname) · [selectTree](#selecttree) · [selectTreeOriented](#selecttreeoriented) · [chainAt / chain](#chainat--chain) · [classOf](#classof) · [orientOf](#orientof) · [objForLogical](#objforlogical) · [resolveView](#resolveview) · [connScope](#connscope) · [connInScope](#conninscope) · [themeBit](#themebit) · [topObjectLabel](#topobjectlabel) · [extCount](#extcount) · [extTag / extSize / extBody](#exttag--extsize--extbody) · [str](#str)

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

`1` for a v1 file presented through the compatibility rule, otherwise the
chunk's own version, `2` or `3`.

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

The best variant for a form-factor class, ignoring orientation. See
[above](#variant-selection-walks-a-chain).

### selectTreeOriented

```c
i32 selectTreeOriented(i32 formId, i32 klass, i32 orient, i32* chosenClass, i32* chosenOrient)
```

The best variant for a class held at an orientation (`UX_ORIENT_*`). See
[Orientation is a second axis](#orientation-is-a-second-axis).
`chosenOrient` reports the orientation of the tree that won.

### chainAt / chain

```c
i32 chainAt(i32 klass, i32 step)
static i32 chain(i32 klass, i32 step)
```

The form-factor class at `step` (0 to 3) of `klass`'s fallback chain.

### classOf

```c
static i32 classOf(u32 word)
```

The form-factor class in a variant's class word: its low 14 bits.

### orientOf

```c
static i32 orientOf(u32 word)
```

The orientation in a variant's class word: its top two bits.

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

### connScope

```c
u32 connScope(i32 i)
```

Connection `i`'s scope: bit `class * 3 + orientation` per theme, 0 for all.

### connInScope

```c
bool connInScope(i32 i, i32 klass, i32 orient)
```

Whether connection `i` binds in a theme.

### themeBit

```c
static u32 themeBit(i32 klass, i32 orient)
```

### topObjectLabel

```c
u8* topObjectLabel(i32 i)
```

The designer's name for top-level object `i`; "" before v3.

### extCount

```c
i32 extCount(void)
```

### extTag / extSize / extBody

```c
u32 extTag(i32 i)
u32 extSize(i32 i)
u32 extBody(i32 i)
```

Extension section `i`: its tag, its size, and the offset of its body in the
buffer.

### str

```c
u8* str(u32 off)
```

A string from the chunk's table, borrowed.

## See also

- [`UXNib`](/compiler/api/uxkit/uxnib/): loading a form on every backend
- [`UXNibGem`](/compiler/api/uxkit/uxnibgem/): v1, and the host surface that
  makes it GEM-only
- [`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/): `formFactorClass`, which
  supplies the class `selectTree` is asked for
- [`UXViewTree`](/compiler/api/uxkit/uxviewtree/): what a loaded nib becomes
