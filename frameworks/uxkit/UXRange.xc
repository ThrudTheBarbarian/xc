// UXRange.xc — a half-open range [loc, loc+len), as an object.  Foundation's NSRange in shape.
//
// A CLASS, not a packed struct, because the whole point of it is to live in an Array — a wrapped
// line, a selected block of rows, a run of styled characters are all "a list of ranges", and xt
// autoboxes primitives but not structs.
//
// It exists as one type because it kept being written as several.  UXIndexSet had an UXIndexRange
// (loc/len, half-open, with end()); UXTextLayout had an UXTextLine (start/length, same shape, same
// meaning, no end()); UXAttributedString's runs and UXTextLayout's runs each spelled the pair out
// again next to their payload.  Four vocabularies for one idea, and a reader had to open the file to
// learn that a "text line" was a range.  Now: one name, one field pair, one half-open contract, and
// a range WITH a payload says so by extending this.
//
// Half-open is the contract: `loc` is included, `end()` is not, an empty range has len 0, and
// adjacent ranges satisfy a.end() == b.loc with no gap and no overlap.
#import "Array.xc"

class UXRange : Object
    {
    i32 loc;
    i32 len;
    void init(void)
        {
        loc = (i32)0;
        len = (i32)0;
        }
    static UXRange* make(i32 l, i32 n)
        {
        UXRange* r = new UXRange();
        r.loc = l;
        r.len = n;
        return r;
        }

    // one past the last index
    i32 end(void)
        {
        return loc + len;
        }
    bool isEmpty(void)
        {
        return len <= (i32)0;
        }
    bool contains(i32 i)
        {
        return i >= loc && i < loc + len;
        }
    // Do these two cover any index in common?  Touching end-to-end ([0,3) and [3,2)) is NOT
    // overlapping — that is the half-open contract doing its job.
    bool overlaps(UXRange* o)
        {
        if (o == (UXRange*)0)
            {
            return false;
            }
        // An EMPTY range covers no index, so it overlaps nothing — including a range it sits inside.
        // The comparison below would say otherwise: [5,5) against [0,10) satisfies both halves of it.
        if (self.isEmpty() || o.isEmpty())
            {
            return false;
            }
        return loc < o.end() && o.loc < self.end();
        }
    }
