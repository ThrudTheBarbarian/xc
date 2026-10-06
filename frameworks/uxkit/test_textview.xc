// test_textview.xc — UXTextView with no native view (a backend without one, or before it is made):
// the model edits, styles, paragraph alignment, typing style, undo and redo, and the delegate.
#import <Stdio.xc>
#import "UXTextView.xc"

i32 gFails = 0;
void ck(bool ok, u8* what)
    {
    Stdio.printf("  %s %s\n", ok ? (u8*)"ok  " : (u8*)"FAIL", what);
    if (!ok)
        {
        gFails = gFails + 1;
        }
    }
void eqi(i32 got, i32 want, u8* what)
    {
    Stdio.printf("  %s %s = %d (want %d)\n", got == want ? (u8*)"ok  " : (u8*)"FAIL", what, got, want);
    if (got != want)
        {
        gFails = gFails + 1;
        }
    }
bool streq(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        {
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }
bool textIs(UXTextView* tv, u8* want)
    {
    String* t = tv.text();
    return streq(t.cString(), want);
    }
UXTextStyle* styleAt(UXTextView* tv, i32 i)
    {
    return UXTextStyle.at(tv.attributedText(), i);
    }

class Watcher : Object<UXTextViewDelegate>
    {
    i32 changes;
    i32 selections;
    void init(void)
        {
        changes = (i32)0;
        selections = (i32)0;
        }
    void textDidChange(UXTextView* tv)
        {
        changes = changes + (i32)1;
        }
    void selectionDidChange(UXTextView* tv)
        {
        selections = selections + (i32)1;
        }
    }

void main(void)
    {
    UXTextView* tv = new UXTextView();
    Watcher* w = new Watcher();
    tv.delegate = w;
    eqi((i32)tv.kind(), (i32)UXKindView, "no native text view: the view draws itself");
    tv.setText(String.withCString((u8*)"one two\nthree"));
    eqi(tv.length(), (i32)13, "length in bytes");
    ck(!tv.canUndo(), "setting the text is not an undo step");

    tv.setSelectedRange(Range.make((i32)4, (i32)3));
    eqi(w.selections, (i32)1, "the delegate hears the selection move");
    tv.toggleBold();
    ck(styleAt(tv, (i32)4).bold && styleAt(tv, (i32)6).bold && !styleAt(tv, (i32)3).bold && !styleAt(tv, (i32)7).bold,
       "bold covers the selection only");
    tv.setSelectedRange(Range.make((i32)2, (i32)4));
    tv.toggleBold();
    ck(styleAt(tv, (i32)2).bold && styleAt(tv, (i32)5).bold, "a part-bold selection turns all bold");
    tv.toggleBold();
    ck(!styleAt(tv, (i32)2).bold && !styleAt(tv, (i32)5).bold && styleAt(tv, (i32)6).bold,
       "an all-bold selection turns off, and only there");
    tv.toggleItalic();
    tv.toggleUnderline();
    UXTextStyle* st = styleAt(tv, (i32)3);
    ck(st.italic && st.underline && !st.bold, "italic and underline together");
    eqi(tv.selectionStyle().italic ? (i32)1 : (i32)0, (i32)1, "selectionStyle reads the selection");

    tv.setColor((i32)0x336699);
    eqi(styleAt(tv, (i32)3).color, (i32)0x336699, "a colour over the selection");
    tv.setColor((i32)-1);
    eqi(styleAt(tv, (i32)3).color, (i32)-1, "...and back to the ink");
    tv.setFontSize((i32)20);
    eqi((i32)styleAt(tv, (i32)3).size, (i32)20, "a point size");

    tv.setSelectedRange(Range.make((i32)10, (i32)0));
    tv.setAlignment((i32)UX_ALIGN_RIGHT);
    eqi(styleAt(tv, (i32)8).alignment, (i32)UX_ALIGN_RIGHT, "alignment: the caret's paragraph, from its start");
    eqi(styleAt(tv, (i32)12).alignment, (i32)UX_ALIGN_RIGHT, "...to its end");
    eqi(styleAt(tv, (i32)0).alignment, (i32)UX_ALIGN_LEFT, "...and not the paragraph before");

    tv.setSelectedRange(Range.make((i32)13, (i32)0));
    tv.toggleBold();
    tv.insertText(String.withCString((u8*)"!"));
    ck(textIs(tv, (u8*)"one two\nthree!"), "typing at the caret");
    ck(styleAt(tv, (i32)13).bold, "an empty selection's toggle styles what is typed next");
    eqi(tv.selectedRange().loc, (i32)14, "the caret after the typing");
    tv.setSelectedRange(Range.make((i32)0, (i32)3));
    tv.insertText(String.withCString((u8*)"\U0001F44B"));
    ck(textIs(tv, (u8*)"\U0001F44B two\nthree!"), "typing over a selection replaces it");
    eqi(tv.selectedRange().loc, (i32)4, "an emoji is four bytes");

    tv.undo();
    ck(textIs(tv, (u8*)"one two\nthree!"), "undo the replacement");
    tv.undo();
    ck(textIs(tv, (u8*)"one two\nthree"), "undo the typing");
    tv.redo();
    ck(textIs(tv, (u8*)"one two\nthree!"), "redo it");
    ck(tv.canUndo() && tv.canRedo(), "both stacks have steps");
    ck(w.changes >= (i32)10, "the delegate hears each change");

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXTextView without a native view\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", gFails);
        }
    }
