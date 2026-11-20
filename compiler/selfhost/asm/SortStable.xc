// SortStable.xc — the assemblers' and object writers' stable sort.
//
// A bottom-up merge sort: n log n where the insertion sorts it replaces were
// quadratic in the number of symbols, relocations or offsets (#335). It is
// STABLE in exactly the insertion sort's sense: an element moves only past a
// strictly greater one, so equal keys (two labels at one offset, a name given
// twice) keep the order they were given in, and the object bytes do not move.

#import "Foundation.xc"

class SortStable : Object
    {
    // Sort `items` by the u32 Numbers in `keys` (parallel to it), ascending;
    // both arrays end up in the sorted order. `keys` may be `items` itself.
    static void byU32(Array* items, Array* keys)
        {
        u32 n = keys.count();
        if (n < (u32)2)
            return;
        bool same = items == keys;
        Array* srcI = SortStable.copy(items);
        Array* srcK = same ? srcI : SortStable.copy(keys);
        Array* dstI = SortStable.copy(items);
        Array* dstK = same ? dstI : SortStable.copy(keys);
        u32 width = (u32)1;
        while (width < n)
            {
            u32 lo = (u32)0;
            while (lo < n)
                {
                u32 mid = lo + width < n ? lo + width : n;
                u32 hi = lo + width + width < n ? lo + width + width : n;
                u32 a = lo;
                u32 b = mid;
                u32 k = lo;
                while (k < hi)
                    {
                    // Take from the left run unless the right one is strictly
                    // smaller: a tie keeps its order.
                    bool takeA = a < mid
                        && (b >= hi || ((Number*)srcK.get(a)).asU32() <= ((Number*)srcK.get(b)).asU32());
                    u32 from = takeA ? a : b;
                    dstI.set(k, srcI.get(from));
                    if (!same)
                        dstK.set(k, srcK.get(from));
                    if (takeA)
                        a = a + (u32)1;
                    else
                        b = b + (u32)1;
                    k = k + (u32)1;
                    }
                lo = hi;
                }
            Array* t = srcI; srcI = dstI; dstI = t;
            if (!same)
                {
                Array* tk = srcK; srcK = dstK; dstK = tk;
                }
            else
                srcK = srcI;
            width = width + width;
            }
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            items.set(i, srcI.get(i));
            if (!same)
                keys.set(i, srcK.get(i));
            }
        }

    // Sort an array of Strings ascending by String.compare, stably.
    static void byString(Array* a)
        {
        u32 n = a.count();
        if (n < (u32)2)
            return;
        Array* src = SortStable.copy(a);
        Array* dst = SortStable.copy(a);
        u32 width = (u32)1;
        while (width < n)
            {
            u32 lo = (u32)0;
            while (lo < n)
                {
                u32 mid = lo + width < n ? lo + width : n;
                u32 hi = lo + width + width < n ? lo + width + width : n;
                u32 x = lo;
                u32 y = mid;
                u32 k = lo;
                while (k < hi)
                    {
                    bool takeX = x < mid
                        && (y >= hi || ((String*)src.get(x)).compare((String*)src.get(y)) <= 0);
                    if (takeX)
                        {
                        dst.set(k, src.get(x));
                        x = x + (u32)1;
                        }
                    else
                        {
                        dst.set(k, src.get(y));
                        y = y + (u32)1;
                        }
                    k = k + (u32)1;
                    }
                lo = hi;
                }
            Array* t = src; src = dst; dst = t;
            width = width + width;
            }
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            a.set(i, src.get(i));
        }

    static Array* copy(Array* a)
        {
        Array* c = new Array();
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            c.add(a.get(i));
        return c;
        }
    }
