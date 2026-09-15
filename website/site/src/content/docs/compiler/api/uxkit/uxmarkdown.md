---
title: UXMarkdown
description: "Inline markdown to an attributed string: **bold**, *italic* and `code`, with the markers stripped and the spans they wrapped carrying the attributes."
---

`UXMarkdown` turns inline markdown into a
[`UXAttributedString`](/compiler/api/uxkit/uxattributedstring/).

```c
#use <UXKit>            // or #import "UXMarkdown.xc"
```

## Overview

```c
UXAttributedString* s =
    UXMarkdown.parse((u8*)"plain **bold** and *italic* and `code` here");

s.stringValue();     // "plain bold and italic and code here" — markers gone
s.runCount();        // 7 — the spans, coalesced
```

It covers help text, notes and formatted labels drawn through the
attributed-string path.

## Three markers, and they toggle

| written | attribute |
| --- | --- |
| `**bold**` | `bold` |
| `*italic*` | `italic` |
| `` `code` `` | a distinct colour pen |

Each marker is a **toggle**, not a matched pair. The parser flips a flag and
continues, which has two consequences.

Nesting works with no special handling, because the flags are independent:

```c
UXMarkdown.parse((u8*)"**bold *and italic* **");
// "bold and italic " — three runs: bold, bold+italic, bold
```

An **unclosed** marker is not an error. It applies to the rest of the string,
so `"**oops"` is all bold. This is forgiving for help text, but a stray
asterisk changes everything after it.

`**` is checked before `*`, so a double marker is bold rather than two italics.

## Escaping works

```c
UXMarkdown.parse((u8*)"a \\*literal\\* star");
// "a *literal* star" — one run, no styling
```

A backslash takes the next character literally. Use it to write an asterisk or
a backtick that stands for itself.

## Code is a colour, not a font

The `` ` `` marker sets the [`pen`](/compiler/api/uxkit/uxcharattr/#pen) rather
than a monospace family, because
[`UXCharAttr`](/compiler/api/uxkit/uxcharattr/) has bold, italic, pen and size,
and no family.

Code spans are *distinguished*, not *monospaced*. Adding a family to the
character attributes would change the run-coalescing rule and every backend's
text drawing, for a feature help text rarely needs.

If you need monospace, draw the runs yourself and choose a family per run;
[`drawTextFont`](/compiler/api/uxkit/uxgraphics/) takes one.

## Inline only

No headings, no lists, no links, no block quotes, no paragraphs. The scope is
inline markup only.

Block markdown would sit on top of this. It needs a line model and a notion of
vertical space, and an attributed string has neither. `UXMarkdown` handles the
part that fits in a label.

## Topics

[parse](#parse)

### parse

```c
static UXAttributedString* parse(u8* md)
```

Markdown in, attributed string out. It never fails: no input is malformed,
though some input styles differently from what you meant.

The output text is never longer than the input, because markers are only
removed. Attributes are applied per character, so the
[runs](/compiler/api/uxkit/uxattrrun/) coalesce correctly with no extra work.

:::note[The source string is not retained]
`parse` builds its own text buffer, so the markdown you passed in can be freed
afterwards. The attributed string owns everything it needs.
:::

## Example

```
markdown: 'plain bold and italic and code here'
  7 run(s): [0..5] [6..9 B] [10..14] [15..20 I] [21..25] [26..29 C] [30..34]
escaped: 'a *literal* star' runs=1
nested: 'bold and italic ' runs=3
```

Three styled spans give seven runs, because each one splits the plain text
around it. The escaped line is a single run because nothing is styled.

The program is `website/site/examples/uxkit/toolbox.xc`. The `doc-examples`
gate compiles it, and the listing above is its output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass). It has one
  static method, so there is nothing to instantiate.

## See also

- [`UXAttributedString`](/compiler/api/uxkit/uxattributedstring/): what this
  produces
- [`UXCharAttr`](/compiler/api/uxkit/uxcharattr/): the four attributes
  available, and why there is no family
- [`UXTextLayout`](/compiler/api/uxkit/uxtextlayout/): laying the result out
  for drawing
