// UXCharacterSet.xc — a set of characters (NSCharacterSet in shape), over the byte range 0..255.
//
// Built on UXIndexSet (a byte is just an index), plus an inverted flag so "everything except these"
// costs nothing.  The standard sets — whitespace, letters, digits, alphanumerics, punctuation — plus
// membership; the base for trimming, tokenizing, and input validation.
#import "Array.xc"
#import "UXIndexSet.xc"

class UXCharacterSet
    {
    UXIndexSet* set;
    bool invertedFlag;
    void init(void)
        {
        set = new UXIndexSet();
        invertedFlag = false;
        }

    void addChar(i32 c)
        {
        set.addIndex(c);
        }
    void addRange(i32 lo, i32 hi)
        {
        if (hi >= lo)
            {
            set.addRange(lo, hi - lo + (i32)1);
            }
        }
    void addString(u8* s)
        {
        i32 i = (i32)0;
        while (s[i] != (u8)0)
            {
            set.addIndex((i32)s[i]);
            i = i + (i32)1;
            }
        }
    bool contains(i32 c)
        {
        bool m = set.containsIndex(c);
        return invertedFlag ? !m : m;
        }

    UXCharacterSet* inverted(void)
        {
        UXCharacterSet* n = new UXCharacterSet();
        n.set = set;
        n.invertedFlag = !invertedFlag;
        return n;
        }
    // Union of two sets (both assumed non-inverted, the common case).
    UXCharacterSet* unionWith(UXCharacterSet* o)
        {
        UXCharacterSet* n = new UXCharacterSet();
        n.set.addIndexes(set);
        n.set.addIndexes(o.set);
        return n;
        }

    // ---- standard sets -------------------------------------------------------
    static UXCharacterSet* whitespace(void)
        {
        UXCharacterSet* c = new UXCharacterSet();
        c.addChar((i32)' ');
        c.addChar((i32)9);
        return c; // space + tab
        }
    static UXCharacterSet* whitespaceAndNewlines(void)
        {
        UXCharacterSet* c = UXCharacterSet.whitespace();
        c.addChar((i32)10);
        c.addChar((i32)13);
        return c;
        }
    static UXCharacterSet* decimalDigits(void)
        {
        UXCharacterSet* c = new UXCharacterSet();
        c.addRange((i32)'0', (i32)'9');
        return c;
        }
    static UXCharacterSet* letters(void)
        {
        UXCharacterSet* c = new UXCharacterSet();
        c.addRange((i32)'a', (i32)'z');
        c.addRange((i32)'A', (i32)'Z');
        return c;
        }
    static UXCharacterSet* alphanumerics(void)
        {
        UXCharacterSet* c = UXCharacterSet.letters();
        c.addRange((i32)'0', (i32)'9');
        return c;
        }
    static UXCharacterSet* punctuation(void)
        {
        UXCharacterSet* c = new UXCharacterSet();
        c.addString((u8*)"!\"#%&'()*,-./:;?@[\\]_{}");
        return c;
        }
    }
