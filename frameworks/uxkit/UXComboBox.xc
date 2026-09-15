// UXComboBox.xc — an editable field with a drop-down suggestion list (NSComboBox in shape).
//
// Like a popup button but the text is editable; typing narrows a suggestion list by prefix, and a
// completion fills in the first match.  The text + suggestions + prefix-completion is the pure testable
// model; drawing the field + running the drop-down ride the backend.
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"

class UXComboItem : Object
    {
    u8* s;
    void init(void)
        {
        s = (u8*)"";
        }
    }

    class UXComboBox : UXControl
    {
    Array<UXComboItem>* items;
    u8* textVal;
    void init(void)
        {
        super.init();
        items = new Array();
        textVal = (u8*)"";
        }
    UXKind kind(void)
        {
        return UXKindView;
        }

    void addItem(u8* s)
        {
        UXComboItem* it = new UXComboItem();
        it.s = s;
        items.add(it);
        }
    void removeAllItems(void)
        {
        items.removeAll();
        }
    i32 count(void)
        {
        return (i32)items.count();
        }
    u8* itemAt(i32 i)
        { return ((UXComboItem* ?)items.get((u16)i)).s;
        }
    void setText(u8* s)
        {
        textVal = s;
        }
    u8* text(void)
        {
        return textVal;
        }

    static u8 lower(u8 c)
        {
        return (c >= (u8)'A' && c <= (u8)'Z') ? (u8)(c + (u8)32) : c;
        }
    // does `s` start with `prefix` (case-insensitive)?
    static bool hasPrefixCI(u8* s, u8* prefix)
        {
        i32 i = (i32)0;
        while (prefix[i] != (u8)0)
            {
            if (s[i] == (u8)0 || UXComboBox.lower(s[i]) != UXComboBox.lower(prefix[i]))
                {
                return false;
                }
            i = i + (i32)1;
            }
        return true;
        }

    // index of the first suggestion that has the current text as a prefix, or -1.
    i32 completionIndex(void)
        {
        if (textVal == (u8*)0 || textVal[0] == (u8)0)
            {
            return (i32)-1;
            }
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            if (UXComboBox.hasPrefixCI(self.itemAt(i), textVal))
                {
                return i;
                }
            }
        return (i32)-1;
        }
    // the completed text (the matching suggestion) or the current text if none.
    u8* completion(void)
        {
        i32 i = self.completionIndex();
        return i >= (i32)0 ? self.itemAt(i) : textVal;
        }
    // count of suggestions still matching the current prefix.
    i32 matchCount(void)
        {
        if (textVal == (u8*)0 || textVal[0] == (u8)0)
            {
            return self.count();
            }
        i32 n = (i32)0;
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            if (UXComboBox.hasPrefixCI(self.itemAt(i), textVal))
                {
                n = n + (i32)1;
                }
            }
        return n;
        }
    // commit a suggestion into the text (as a drop-down pick or Tab-complete would).
    void selectItem(i32 i)
        {
        if (i >= (i32)0 && i < self.count())
            {
            textVal = self.itemAt(i);
            }
        }
    void acceptCompletion(void)
        {
        i32 i = self.completionIndex();
        if (i >= (i32)0)
            {
            textVal = self.itemAt(i);
            }
        }

    void mouseDown(UXEvent* e)
        {
        if (self.isEnabled())
            {
            self.setNeedsDisplay();
            self.fire();
            }
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        // a bordered field face; the drop-down affordance is a chevron in a
        // face-grey box at the right end (the popup's look, with an editable field)
        g.fillRect(UXGeom.make((i16)0, (i16)0, b.w, b.h), (i32)0);
        g.fillRect(UXGeom.make((i16)0, (i16)0, b.w, (i16)1), (i32)9);
        g.fillRect(UXGeom.make((i16)0, (i16)(b.h - (i16)1), b.w, (i16)1), (i32)9);
        g.fillRect(UXGeom.make((i16)0, (i16)0, (i16)1, b.h), (i32)9);
        g.fillRect(UXGeom.make((i16)(b.w - (i16)1), (i16)0, (i16)1, b.h), (i32)9);
        g.drawText(textVal, (i16)4, (i16)((b.h - (i16)12) / (i16)2), (i32)1, (i32)0);
        i16 axx = (i16)(b.w - (i16)16);
        g.fillRect(UXGeom.make(axx, (i16)1, (i16)15, (i16)(b.h - (i16)2)), (i32)8);
        g.fillTriangle((i16)(axx + (i16)7), (i16)(b.h / (i16)2 + (i16)3),
                       (i16)(axx + (i16)3), (i16)(b.h / (i16)2 - (i16)2),
                       (i16)(axx + (i16)11), (i16)(b.h / (i16)2 - (i16)2), (i32)1);
        }
    }
