# Rocks `.rsc` format notes

This document describes the GEM resource (`.rsc`) files that **Rocks** writes, so
other software can consume them correctly and get the most out of them. It covers
what is standard, what is extended, and the current limitations. The reader/writer is a **portable C library**, `src/rsc.c` + `src/rsc.h` (no
dependencies beyond the C standard library), shared verbatim with the GEM
desktop (written in C) so both read and write byte-identical files. The Objective-C editor
uses it through a thin bridge (`src/GRsc.m`). This document is kept in sync with
`src/rsc.c`.

Rocks also has a native project format (`.gemproj`, JSON) that preserves
everything losslessly (including tree names); `.rsc` is the interchange format and
carries a subset plus a few documented extensions.

---

## 1. Overall structure (standard)

A Rocks `.rsc` is a classic Digital Research / Atari GEM resource:

```
RSHDR            18 × 16-bit words (36 bytes)
OBJECT[]         nobs × 24 bytes
TEDINFO[]        nted × 28 bytes
ICONBLK[]        nib  × 34 bytes
(BITBLK[])       0 (not emitted — see Limitations)
(free-string / free-image pointer arrays)   0
tree index       ntree × 32-bit offsets
string data      NUL-terminated strings
image data       icon bitplanes + embedded colour icons (see §4)
```

**Byte order: big-endian** by default (Atari-ST/68000 convention). The reader
also accepts little-endian files, but Rocks *writes* big-endian.

**`RSHDR` (18 words):** `vrsn(0), object, tedinfo, iconblk, bitblk, frstr, string,
imdata, frimg, trindex, nobs, ntree, nted, nib, nbb, nstring, nimages, rssize`.
All offsets are byte offsets from the start of the file. `rssize` = total size.
`vrsn = 0` (the extended/large `vrsn & 4` variant is **not** produced).

---

## 2. OBJECT records (mostly standard, one extension)

Each `OBJECT` is 24 bytes: `ob_next, ob_head, ob_tail (16-bit)`, `ob_type
(16-bit)`, `ob_flags (16-bit)`, `ob_state (16-bit)`, `ob_spec (32-bit)`, `ob_x,
ob_y, ob_width, ob_height (16-bit)`.

- **`ob_head`/`ob_tail`/`ob_next` are indices relative to each tree's root**
  (the standard GEM convention — `objc_*` treat the tree pointer as object 0).
  For tree 0 the root is object 0, so relative == absolute; for later trees they
  are offset by the tree's base. Consumers must add the tree base, as
  `rsrc_gaddr` + the AES do.

- **Coordinates are char/pixel packed** (`(chars) | (extra_pixels << 8)`), so a
  standard `rsrc_obfix` reconstructs pixels as `low_byte × cell + high_byte`
  (high byte signed). Rocks uses **cell width 8, cell height 16**. Apply
  `rsrc_obfix` with an 8×16 cell (or your system font) before use.

- **`ob_type` — low byte is the type; high byte is an "extended" byte.** The AES
  only looks at the low byte, so a standard loader is unaffected. Rocks uses the
  high byte for two of its own purposes (see §5); it is safe to ignore.

### `ob_spec` by type

| `ob_type` (low) | `ob_spec` holds |
|---|---|
| `G_BOX (20)`, `G_IBOX (25)`, `G_BOXCHAR (27)` | inline: `(char<<24) \| (thickness<<16) \| colour_word` |
| `G_STRING (28)`, `G_BUTTON (26)`, `G_TITLE (32)` | byte offset to a NUL-terminated string |
| `G_TEXT (21)`, `G_BOXTEXT (22)`, `G_FTEXT (29)`, `G_FBOXTEXT (30)` | byte offset to a `TEDINFO` |
| `G_ICON (31)` | byte offset to an `ICONBLK` (monochrome) |
| `G_IMAGE (23)` | byte offset to an embedded **P7 PAM** (Rocks extension, see §4) |
| extended types 40–44 | see §3 |

The 16-bit GEM colour word is standard:
`border(15-12) text(11-8) textMode(7) fillPattern(6-4) inside(3-0)`.

`TEDINFO` (28 bytes) and `ICONBLK` (34 bytes) are the standard layouts; string
pointers inside them are byte offsets into the string area.

---

## 3. Extended widget types (non-standard)

Rocks supports the GEM desktop's themed widgets, which use **type numbers the
stock AES does not define**:

| Type | Value | `ob_spec` | Notes |
|---|---|---|---|
| `G_CHECKBOX` | 40 | string offset (label) | ticked state = `OS_SELECTED` |
| `G_RADIO`    | 41 | string offset (label) | `OF_RBUTTON`; group = same parent |
| `G_POPUP`    | 42 | string offset (current value) | linked menu tree in high byte, §5 |
| `G_FIELD`    | 43 | `TEDINFO` offset | editable field; rounded flag in high byte, §5 |
| `G_CICON`    | 44 | embedded P7 PAM offset (§4) | RGBA colour icon |

A consumer that only understands classic GEM will not know these types. If you
target only classic AES, restrict a design to types 20–32. Rocks reads and
writes both.

---

## 4. Colour images: embedded P7 PAM (non-standard)

Classic GEM has no RGBA image type. For **`G_CICON (44)`** and **`G_IMAGE (23)`**,
Rocks stores the picture as a **binary Netpbm P7 (PAM)** blob in the image-data
section, and `ob_spec` is the byte offset of that blob. The PAM is
self-delimiting (`P7 … ENDHDR` then `WIDTH×HEIGHT×DEPTH` bytes, `DEPTH 4` =
`RGB_ALPHA`), so you can read it directly from `ob_spec` without a length field.

This matches the format the GEM desktop runtime loads (`img.c`,
`GRAY[_ALPHA]` / `RGB[_ALPHA]`). **A standard GEM loader will not understand
these** — it expects `ICONBLK`/`BITBLK`. Monochrome `G_ICON (31)` **is** written
as a standard `ICONBLK` and is portable.

> Note: PAM pixels are written straight (non-premultiplied) RGBA.

---

## 5. The `ob_type` high byte (Rocks conventions)

The AES ignores this byte; Rocks uses it as follows. Both survive a `.rsc`
round-trip.

- **`G_POPUP (42)`: the high byte is the linked menu tree's index.** The popup's
  choices live in a *separate* tree; the byte says which one. A runtime would do
  `rsrc_gaddr(R_TREE, high_byte)` to open it, then copy the chosen item's text
  into the popup. `0` means "no linked tree." (Tree names are not stored in
  `.rsc`; the link is by index. Rocks renumbers these automatically when trees
  are deleted.)

- **Editable fields (`G_FTEXT/G_FBOXTEXT/G_FIELD`): bit 0 = "rounded bezel"** — a
  purely cosmetic hint (square vs rounded text-field art). It has no semantic
  effect; ignore it if you draw your own borders.

- **`G_BOXTEXT (22)`: bit 0 = "group box"** — render as a labelled frame (a
  fieldset: the `TEDINFO` text breaks the top border, no fill) and treat it as a
  container. A plain loader that draws a normal boxed-text is still correct.

- **Box corner rounding, all box types (`G_BOX/G_IBOX/G_BOXCHAR/G_BOXTEXT`):
  bits 4–7 round individual corners** — `0x10` top-left, `0x20` top-right,
  `0x40` bottom-right, `0x80` bottom-left (`0xF0` = all). Cosmetic; a plain
  loader draws square corners.

### Provenance: whose byte is it?

The AES masks `ob_type & 0xFF` and ignores the high byte, so **other editors have
long used it as a free "extended type" field**. A scan of 112 real resources finds
it non-zero on `G_BOX`, `G_IBOX`, `G_BUTTON`, `G_BOXTEXT` and `G_STRING`, with
values `0x02`–`0x13`. Read as Rocks flags, **75 of those objects become spuriously
rounded boxes or "rounded" fields** — a legacy `G_BUTTON` carrying `0x12` has bit 4
set, which is `BOX_ROUND_TL`.

So the byte only carries the meanings above when the file says it does. Rocks
recognises its own work by any of three independent witnesses:

- **`rsh_vrsn` bit 3** (`RSC_VRSN_ROCKS = 0x0008`) — survives a rewrite of the
  string table.
- **a signature as the LAST free string**, `RoCkS;v=<editor>;f=<file format>` —
  survives a rewrite of the header, and carries versions for future migrations.
  Last, not first, because free strings are indexed (`rsrc_gaddr(R_STRING, i)`):
  prepending one would shift every index an app already relies on. Rocks strips it
  on read, so it never appears in the string table or the generated header.
- **an extended widget type** (`G_CHECKBOX`…`G_PAMICON`, 40–44) anywhere in the
  file. These cannot occur in anyone else's resource, so they identify the GEM
  desktop's resources written before the marker existed.

With **none** of them the file is someone else's: the high byte is kept
verbatim and written back unchanged, but is not allowed to mean anything here.

---

## 5a. `ob_flags` / `ob_state` bit reuse

`ob_flags` and `ob_state` are round-tripped as **raw 16-bit fields**, so files are
lossless regardless of labelling. The GEM desktop runtime doesn't implement GEM's
3D-style flags (3D shading is baked into the themes), so it reuses those freed bit
positions. Rocks labels and edits them the same way (authoritative source:
`aes/OBJECT-FLAGS.md` in the GEM desktop sources, `GEM_DIR` in `build.env`):

- **`ob_flags`** — standard `0x01`–`0x80`, plus:
  - **`OF_CANCEL 0x200`** (reuses `FL3DIND`): Esc fires this object (the Cancel
    affordance).
  - **`OF_MOVEABLE 0x400`** (reuses `FL3DBAK`): on the tree **root** only — the
    dialog is movable. `0x100`/`0x600`/`0x800` are unused by the runtime.
- **`ob_state`** — standard `0x01`–`0x20`, plus:
  - **`OS_WHITEBAK 0x40`**: mnemonic present. Bits **8–14** hold the 0-based index
    of the underlined shortcut character in the object's label
    (`index = (state >> 8) & 0x7F`). `DRAW3D 0x80` is unused.

## 6. Strings and character set

- Strings are **NUL-terminated, ISO-8859-1 (Latin-1)**.
- **Caveat:** characters outside Latin-1 (e.g. a real `…` U+2026) are written as
  `?`. If you need the Atari-ST character set, transcode on your side, or ask for
  a mapping to be added to the exporter.
- `TEDINFO` templates use `_` for each editable slot; `te_pvalid` has one
  validation code per slot (`9` digit, `f` filename, `a` alphanumeric, `A` upper,
  `X` any). A leading `@` in `te_ptext` is the standard GEM "empty field" marker.

---

## 7. Menus

Menu trees follow the standard shape: a root `G_IBOX` containing a bar `G_BOX` of
`G_TITLE`s and, in a second `G_IBOX`, one dropdown `G_BOX` of `G_STRING` items per
title. Rocks pairs a title with its dropdown **by X position** (the box under the
title). Item ticks use `OS_CHECKED` (drawn as the menu tick); the on-state of a
checkbox/radio uses `OS_SELECTED`.

---

## 8. Current limitations of the writer

- **No extended/large (`vrsn & 4`) header** — files are the classic ≤64 KB form.
- **No tree names in `.rsc`** — trees are identified by index only (names live in
  the `.gemproj`). Popup links and any C/header export use the index.
- **Latin-1 strings only** (§6).
- Coordinates assume an **8×16 cell**; if your target uses 8×8, rescale on import.

## 9. What Rocks reads

For completeness, the reader accepts: standard big-endian `.rsc` (and
little-endian as a fallback), char/pixel-packed coordinates, tree-relative object
indices, `TEDINFO`, monochrome `ICONBLK` (bitplanes preserved), free strings, the
standard tree index, and the Rocks extensions above. It masks `ob_type` to the
low byte for the type and keeps the high byte per §5. Files with **no object
trees** (e.g. cursor/`BITBLK`-only resources) are reported as such rather than
loaded.

---

## 10. Using the C library (`rsc.c` / `rsc.h`)

The full API is documented in `rsc.h` (worked read/write examples in the top
comment). In brief:

**Integration.** Add `rsc.c` + `rsc.h` to the build. If the project already has
an AES header defining `OF_`/`OS_`/`BOX_ROUND_` and the `G_` object types
(the desktop does), `#define RSC_NO_STATE_FLAGS` and provide a `G_BOX` macro
before including `rsc.h` to skip the duplicate definitions. `RSC_OBJECT` has the
same layout as the AES `OBJECT` (`ob_w`/`ob_h`, `void *ob_spec`), so you can
`typedef` or use it directly.

**Reading.**
```c
const char *err = NULL;
RSC *r = rsc_read(bytes, len, &err);          /* NULL + err on failure     */
RSC_OBJECT *tree = rsc_tree(r, 0);            /* root of tree 0            */
/* ob_head/ob_tail/ob_next are indices relative to the tree root, so walk
   with tree[c] exactly like the AES.  ob_spec is a resolved pointer. */
rsc_free(r);                                  /* releases all memory        */
```

**Writing.**
```c
RSC *r = rsc_new();
int base = rsc_alloc_objects(r, n);           /* n objects for this tree    */
rsc_add_tree(r, base);
RSC_OBJECT *o = rsc_objects(r, NULL);         /* re-fetch after any alloc   */
/* fill o[base..base+n-1]; links are tree-relative; strings via
   rsc_intern_str(); TEDINFO/ICONBLK/CICON via rsc_new_*(). */
uint8_t *out; size_t olen;
rsc_write(r, &out, &olen, &err);              /* 0 = ok; caller free()s out */
rsc_free(r);
```

**Gotchas** (also in `rsc.h`):
- `rsc_alloc_objects` may `realloc` the object array — fetch the pointer with
  `rsc_objects()` *after* the last allocation, and don't hold `RSC_OBJECT*`
  across allocations.
- All strings / sub-structures handed to objects must be arena-owned
  (`rsc_intern_str/bytes`, `rsc_new_tedinfo/iconblk/cicon`) so they live with the
  resource; `rsc_free` releases the lot.
- For box types, `ob_spec` is the inline box word — build it with
  `RSC_BOXWORD(char, thickness, colour)` and read it with `RSC_BOX_*`.
- Coordinates are pixels; the pack/unpack cell defaults to 8×16 (`rsc_set_cell`).

The library only moves bytes between disk and `OBJECT` trees — it does not draw
or decode/encode PAM pixels. The Rocks editor wraps it in `src/GRsc.m`
(`GObject ↔ RSC_OBJECT`); the desktop uses it directly.

---

*Maintained alongside `src/rsc.c` (the shared C library). If the reader/writer
changes, update this file.*
