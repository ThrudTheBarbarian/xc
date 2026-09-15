// UXIndexSet.xc — a set of non-negative integer indices, Foundation's NSIndexSet in shape.
//
// Stored the way NSIndexSet is: a sorted list of non-overlapping, non-adjacent RANGES (location +
// length).  A selection of rows 3,4,5,9,10 is two ranges [3,3] and [9,2], not five integers — so a
// contiguous block of a million indices costs one range, and add/remove coalesce and split ranges to
// keep that invariant.  This is exactly what a table's multi-selection wants.
#import "Array.xc"
#import "UXRange.xc" // the ranges are UXRange — the toolkit's one half-open range type

class UXIndexSet
    {
    Array<UXRange>* ranges; // sorted by loc, non-overlapping, non-adjacent (coalesced)
    void init(void)
        {
        ranges = new Array();
        }

    UXRange* rangeAt(u16 i)
        { return (UXRange* ?)ranges.get(i);
        }

    // ---- adding (coalescing) -------------------------------------------------
    void addIndex(i32 i)
        {
        self.addRange(i, (i32)1);
        }
    void addRange(i32 loc, i32 len)
        {
        if (len <= (i32)0 || loc < (i32)0)
            {
            return;
            }
        i32 nloc = loc;
        i32 nend = loc + len;
        u16 i = (u16)0;
        // absorb every range that touches/overlaps [nloc,nend]
        while (i < ranges.count())
            {
            UXRange* r = self.rangeAt(i);
            // before, with a gap -> keep
            if (r.end() < nloc)
                {
                i = i + (u16)1;
                continue;
                }
            // after, with a gap -> done (sorted)
            if (r.loc > nend)
                {
                break;
                }
            if (r.loc < nloc)
                {
                nloc = r.loc;
                }
            if (r.end() > nend)
                {
                nend = r.end();
                }
            ranges.removeAt(i); // absorbed; do not advance
            }
        UXRange* nr = new UXRange();
        nr.loc = nloc;
        nr.len = nend - nloc;
        u16 pos = (u16)0;
        while (pos < ranges.count())
            {
            UXRange* r = self.rangeAt(pos);
            if (r.loc >= nloc)
                {
                break;
                }
            pos = pos + (u16)1;
            }
        ranges.insert(pos, nr);
        }
    void addIndexes(UXIndexSet* other)
        {
        if (other == (UXIndexSet*)0)
            {
            return;
            }
        for (u16 i = (u16)0; i < other.ranges.count(); i = i + (u16)1)
            {
            UXRange* r = other.rangeAt(i);
            self.addRange(r.loc, r.len);
            }
        }

    // ---- removing (splitting) ------------------------------------------------
    void removeIndex(i32 i)
        {
        self.removeRange(i, (i32)1);
        }
    void removeRange(i32 loc, i32 len)
        {
        if (len <= (i32)0)
            {
            return;
            }
        i32 rloc = loc;
        i32 rend = loc + len;
        u16 i = (u16)0;
        while (i < ranges.count())
            {
            UXRange* r = self.rangeAt(i);
            // wholly before
            if (r.end() <= rloc)
                {
                i = i + (u16)1;
                continue;
                }
            // wholly after
            if (r.loc >= rend)
                {
                break;
                }
            i32 rl = r.loc;
            i32 re = r.end();
            ranges.removeAt(i);
            // left survivor [rl, rloc)
            if (rl < rloc)
                {
                UXRange* left = new UXRange();
                left.loc = rl;
                left.len = rloc - rl;
                ranges.insert(i, left);
                i = i + (u16)1;
                }
            // right survivor [rend, re)
            if (re > rend)
                {
                UXRange* right = new UXRange();
                right.loc = rend;
                right.len = re - rend;
                ranges.insert(i, right);
                i = i + (u16)1;
                }
            }
        }
    void removeAllIndexes(void)
        {
        ranges.removeAll();
        }

    // ---- queries -------------------------------------------------------------
    bool containsIndex(i32 idx)
        {
        for (u16 i = (u16)0; i < ranges.count(); i = i + (u16)1)
            {
            UXRange* r = self.rangeAt(i);
            // ranges are sorted
            if (idx < r.loc)
                {
                return false;
                }
            if (idx < r.end())
                {
                return true;
                }
            }
        return false;
        }
    bool containsRange(i32 loc, i32 len)
        {
        if (len <= (i32)0)
            {
            return true;
            }
        for (u16 i = (u16)0; i < ranges.count(); i = i + (u16)1)
            {
            UXRange* r = self.rangeAt(i);
            if (r.loc <= loc && r.end() >= loc + len)
                {
                return true;
                }
            }
        return false;
        }
    i32 count(void)
        {
        i32 n = (i32)0;
        for (u16 i = (u16)0; i < ranges.count(); i = i + (u16)1)
            {
            n = n + self.rangeAt(i).len;
            }
        return n;
        }
    bool isEmpty(void)
        {
        return ranges.count() == (u16)0;
        }
    i32 firstIndex(void)
        {
        return ranges.count() == (u16)0 ? (i32)-1 : self.rangeAt((u16)0).loc;
        }
    i32 lastIndex(void)
        {
        if (ranges.count() == (u16)0)
            {
            return (i32)-1;
            }
        return self.rangeAt((u16)(ranges.count() - (u16)1)).end() - (i32)1;
        }
    // Smallest index in the set strictly greater than `idx` (-1 if none) — the iteration primitive.
    i32 indexGreaterThan(i32 idx)
        {
        for (u16 i = (u16)0; i < ranges.count(); i = i + (u16)1)
            {
            UXRange* r = self.rangeAt(i);
            // whole range is <= idx
            if (r.end() - (i32)1 <= idx)
                {
                continue;
                }
            // gap: first of this range
            if (r.loc > idx)
                {
                return r.loc;
                }
            return idx + (i32)1; // idx is inside r; next one is still in r
            }
        return (i32)-1;
        }
    i32 indexLessThan(i32 idx)
        {
        i32 best = (i32)-1;
        for (u16 i = (u16)0; i < ranges.count(); i = i + (u16)1)
            {
            UXRange* r = self.rangeAt(i);
            // this and later ranges are all >= idx
            if (r.loc >= idx)
                {
                break;
                }
            i32 top = r.end() - (i32)1;
            best = top < idx ? top : idx - (i32)1;
            }
        return best;
        }
    bool intersectsRange(i32 loc, i32 len)
        {
        if (len <= (i32)0)
            {
            return false;
            }
        i32 e = loc + len;
        for (u16 i = (u16)0; i < ranges.count(); i = i + (u16)1)
            {
            UXRange* r = self.rangeAt(i);
            if (r.loc < e && loc < r.end())
                {
                return true;
                }
            }
        return false;
        }
    // not `equals`: that is Object's pointer-equality method
    bool isEqualTo(UXIndexSet* other)
        {
        if (other == (UXIndexSet*)0)
            {
            return false;
            }
        if (ranges.count() != other.ranges.count())
            {
            return false;
            }
        for (u16 i = (u16)0; i < ranges.count(); i = i + (u16)1)
            {
            UXRange* a = self.rangeAt(i);
            UXRange* b = other.rangeAt(i);
            if (a.loc != b.loc || a.len != b.len)
                {
                return false;
                }
            }
        return true;
        }
    // exposed for tests/introspection
    i32 rangeCount(void)
        {
        return (i32)ranges.count();
        }
    }
