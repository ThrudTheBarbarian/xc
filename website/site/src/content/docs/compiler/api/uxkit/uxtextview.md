---
title: UXTextView
description: "An editable, multi-line rich-text view: the content is a Foundation AttributedString, edited in the platform's own text view."
---

`UXTextView` is an editable, multi-line view of styled text. Its content is a
Foundation [`AttributedString`](/compiler/api/attributedstring/), styled with
the attributes [`UXTextStyle`](/compiler/api/uxkit/uxtextstyle/) names: bold,
italic, underline, monospace, colour, size and paragraph alignment. From 0.72.

```c
#import "UXTextView.xc"
```

The view is the platform's own text view where there is one, so typing, the
caret, selection by mouse and keyboard, the clipboard, undo, scrolling, input
methods and emoji behave as they do in the platform's other applications.
Cut, copy, paste, select all, undo and redo work from the keyboard while the
view has the focus, whatever menus the application has. Where the view keeps
the undo itself, a run of typing is one step. The content is read back after each edit,
so [`attributedText`](#attributedtext) is always current.

| Backend | View |
|---|---|
| macOS | `NSTextView` |
| Web | A `contenteditable` element over the view. Pasted text comes in unstyled, and undo is kept by the view. |
| GTK | `GtkTextView`. Undo is kept by the view, because GTK's own does not record styles. |
| Windows | A RichEdit control. Undo is kept by the view. |
| iOS | `UITextView`. Undo is kept by the view; the system's undo keys and gestures reach it. |
| Android | An `EditText` whose styles are spans. Undo is kept by the view. |
| GEM | Drawn by the view, which also does the editing: typing, Return, Backspace and Delete, the arrow keys, Home and End (with Shift to select), a click and a drag, the wheel, the clipboard and undo. Typed characters are ASCII. |

Offsets and lengths are UTF-8 bytes, as in Foundation's strings. An emoji is
four bytes.

## Overview

```c
UXTextView* tv = new UXTextView();
content.addSubview(tv, UXGeom.make(10, 40, 440, 250));
tv.setText(String.withCString("Dispatch from the front"));

// A Bold button: bold over the selection, or off if all of it is bold already.
void boldPressed(UXControl* c)
    {
    tv.toggleBold();
    }

// The content as runs, for the application's own format.
AttributedString* as = tv.attributedText();
for (u32 k = 0; k < as.runCount(); k = k + 1)
    {
    Range* r = as.runRange(k);
    UXTextStyle* st = UXTextStyle.of(as.runAttributes(k));
    // r.loc, r.len, st.bold, st.italic, ...
    }
```

## Topics

[setAttributedText](#setattributedtext) · [setText](#settext) · [attributedText](#attributedtext) · [text](#text) · [length](#length) · [selectedRange](#selectedrange) · [setSelectedRange](#setselectedrange) · [focus](#focus) · [insertText](#inserttext) · [toggleBold](#togglebold--toggleitalic--toggleunderline) · [toggleItalic](#togglebold--toggleitalic--toggleunderline) · [toggleUnderline](#togglebold--toggleitalic--toggleunderline) · [setColor](#setcolor) · [setFontSize](#setfontsize) · [setAlignment](#setalignment) · [selectionStyle](#selectionstyle) · [setBackgroundColor](#setbackgroundcolor--setink--setcaretcolor--setselectioncolor) · [setInk](#setbackgroundcolor--setink--setcaretcolor--setselectioncolor) · [setCaretColor](#setbackgroundcolor--setink--setcaretcolor--setselectioncolor) · [setSelectionColor](#setbackgroundcolor--setink--setcaretcolor--setselectioncolor) · [setDefaultFontSize](#setdefaultfontsize) · [setMonospace](#setmonospace) · [undo](#undo--redo) · [redo](#undo--redo) · [canUndo](#canundo--canredo) · [canRedo](#canundo--canredo) · [delegate](#delegate)

### setAttributedText

```c
void setAttributedText(AttributedString* as)
```

Replaces the whole content with a copy of `as` and puts the caret at the start.
This is not an edit, so it cannot be undone.

### setText

```c
void setText(String* text)
```

Replaces the whole content with unstyled text.

### attributedText

```c
AttributedString* attributedText(void)
```

A copy of the content as it is now.

### text

```c
String* text(void)
```

The content's text, without its styles.

### length

```c
i32 length(void)
```

The content's length in bytes.

### selectedRange

```c
Range* selectedRange(void)
```

The selection. An empty one is the caret.

### setSelectedRange

```c
void setSelectedRange(Range* r)
```

Selects `r`, clipped to the content, and scrolls it into view.

### focus

```c
void focus(void)
```

Puts the keyboard focus in the view.

### insertText

```c
void insertText(String* text)
```

Replaces the selection with `text`, in the style typing has there, and puts the
caret after it. This is an edit, so it can be undone.

### toggleBold / toggleItalic / toggleUnderline

```c
void toggleBold(void)
void toggleItalic(void)
void toggleUnderline(void)
```

Turns the style on over the selection, or off if all of the selection has it.
With an empty selection, changes the style of what is typed next.

### setColor

```c
void setColor(i32 rgb)
```

Colours the selection `0xRRGGBB`. `-1` returns it to the view's ink.

### setFontSize

```c
void setFontSize(i32 size)
```

Sets the selection's point size. `0` returns it to the default.

### setAlignment

```c
void setAlignment(i32 align)
```

Aligns every paragraph the selection touches: `UX_ALIGN_LEFT`,
`UX_ALIGN_CENTER`, `UX_ALIGN_RIGHT` or `UX_ALIGN_JUSTIFY`.

### selectionStyle

```c
UXTextStyle* selectionStyle(void)
```

The style of the selection's first byte, or of what is typed next when the
selection is empty. A toolbar reads it to show which styles are on.

### setBackgroundColor / setInk / setCaretColor / setSelectionColor

```c
void setBackgroundColor(i32 rgb)
void setInk(i32 rgb)
void setCaretColor(i32 rgb)
void setSelectionColor(i32 rgb)
```

The view's colours, each `0xRRGGBB`; `-1` returns one to the platform's. The
ink is the colour of text with no colour of its own: a run's `color`
attribute overrides it, and text drawn in the ink reads back with no colour.
The caret takes the ink when it has no colour of its own.

On Windows the caret and the selection keep the system's colours. On iOS
the caret and the selection are drawn in one colour, the caret's (or else
the selection's). On Android a caret colour needs Android 10 or later.

### setDefaultFontSize

```c
void setDefaultFontSize(i32 size)
```

The size of text with no size of its own, in the view's pixels. `0` returns
it to the platform's. Text in the default size reads back with no size.

### setMonospace

```c
void setMonospace(bool on)
```

Whether text with no face of its own is monospace. Such text does not read
back as having the `monospace` attribute.

### undo / redo

```c
void undo(void)
void redo(void)
```

Undoes or redoes the last edit, typed or made through these methods.

### canUndo / canRedo

```c
bool canUndo(void)
bool canRedo(void)
```

Whether there is an edit to undo or redo.

### delegate

```c
weak : UXTextViewDelegate* delegate;

protocol UXTextViewDelegate
    {
    optional void textDidChange(UXTextView* tv);
    optional void selectionDidChange(UXTextView* tv);
    }
```

Told when the content changes, by the user or through the view's methods, and
when the selection moves.
