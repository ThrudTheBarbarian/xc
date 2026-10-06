---
title: AttributedString
description: "Text with named attributes over ranges of it, kept as merged runs; editing the text keeps the attributes in place."
---

`AttributedString` is text with named attributes over ranges of it
(`NSAttributedString` in shape): the model behind styled text and a rich-text
field. **From 0.72.**

```c
#import "AttributedString.xc"   // not in the Foundation umbrella: import it by name
```

## Overview

```c
AttributedString* s = AttributedString.withString(String.withCString("Hello, world"));
s.setAttribute(String.withCString("bold"), Number.withBool(true), Range.make((i32)0, (i32)5));
s.runCount();                                  // 2: "Hello" bold, ", world" plain
s.attribute(String.withCString("bold"), (i32)1);   // true
```

**Attributes** are named by `String`s and hold any object: a font, a colour, a
link, a flag. Which names mean what is up to the code that draws the text;
Foundation only keeps them. Positions and [`Range`](/compiler/api/range/)s are
byte offsets into the UTF-8 text.

**Runs.** The text is covered by runs: ranges whose bytes share one set of
attributes, with neighbours that have equal sets merged, so drawing can walk the
runs and style one span at a time. Two sets are equal when they have the same
names and their values are equal by `equals`.

**Editing** keeps the attributes where they belong. Replacing text gives the new
text the attributes of the first byte replaced; inserted text takes those of the
byte before it (of the first byte, at the start); text after the edit moves with
it.

:::note[Availability]
Every heap-capable target except xt6502.
:::

## Topics

**Creating** · [withString](#withstring) · [withAttributes](#withattributes) · [copy](#copy)

**The text** · [text](#text) · [length](#length)

**Reading attributes** · [attribute](#attribute) · [attributesAt](#attributesat) · [runRangeAt](#runrangeat) · [runCount / runRange / runAttributes](#runcount--runrange--runattributes)

**Changing attributes** · [setAttribute](#setattribute) · [removeAttribute](#removeattribute) · [addAttributes](#addattributes) · [setAttributes](#setattributes)

**Editing the text** · [replace](#replace) · [replaceWithAttributed](#replacewithattributed) · [appendString](#appendstring) · [append](#append)

**Pieces** · [substring](#substring) · [equals](#equals)

---

## Creating

### withString
```c
static AttributedString* withString(String* text)
```
`text` with no attributes. `new AttributedString()` is empty.

### withAttributes
```c
static AttributedString* withAttributes(String* text, Map* attrs)
```
`text` with `attrs` over all of it.

### copy
```c
AttributedString* copy(void)
```

[↑ Topics](#topics)

## The text

### text
```c
String* text(void)
```
A copy of the text. It is also the `description`.

### length
```c
i32 length(void)
```
In bytes.

[↑ Topics](#topics)

## Reading attributes

### attribute
```c
Object* attribute(String* name, i32 at)
```
The value of `name` at byte `at`, or null.

### attributesAt
```c
Map* attributesAt(i32 at)
```
A copy of every attribute at byte `at`; empty out of range.

### runRangeAt
```c
Range* runRangeAt(i32 at)
```
The run holding byte `at`: the longest range around it with the same
attributes.

### runCount / runRange / runAttributes
```c
u32 runCount(void)
Range* runRange(u32 k)
Map* runAttributes(u32 k)
```
The runs in order, for drawing: the k-th run's range and a copy of its
attributes.

[↑ Topics](#topics)

## Changing attributes

Each takes a range, clipped to the text.

### setAttribute
```c
void setAttribute(String* name, Object* value, Range* r)
```
Sets `name` to `value` over `r`; a null value removes it.

### removeAttribute
```c
void removeAttribute(String* name, Range* r)
```

### addAttributes
```c
void addAttributes(Map* attrs, Range* r)
```
Sets every attribute of `attrs` over `r`, leaving the others.

### setAttributes
```c
void setAttributes(Map* attrs, Range* r)
```
Replaces every attribute over `r` with `attrs` (null: none).

[↑ Topics](#topics)

## Editing the text

### replace
```c
void replace(Range* r, String* text)
```
Replaces the bytes of `r` with `text`, which takes the attributes described in
the [overview](#overview). An empty `r` inserts.

### replaceWithAttributed
```c
void replaceWithAttributed(Range* r, AttributedString* other)
```
The same, keeping `other`'s own attributes.

### appendString
```c
void appendString(String* text)
```
Adds `text` at the end with the attributes of the last byte.

### append
```c
void append(AttributedString* other)
```

[↑ Topics](#topics)

## Pieces

### substring
```c
AttributedString* substring(Range* r)
```
The text and attributes of `r`, clipped to the text.

### equals
```c
bool equals(Object* other)
```
Equal text, and equal attributes over the same runs.

[↑ Topics](#topics)
