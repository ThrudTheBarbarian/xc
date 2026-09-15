// UXSortDescriptor.xc — sort records by a key (NSSortDescriptor in shape).
//
// Orders an array of objects that answer UXEvaluable (the same protocol UXPredicate filters on) by one
// key, ascending or descending, comparing the key's value as a string or as a number.  Filter with a
// predicate, then sort with one of these — exactly what a table/list view does to its rows.  Pure
// comparison logic, testable.
#import "Array.xc"
#import "UXPredicate.xc" // for the UXEvaluable protocol

class UXSortDescriptor
    {
    u8* key;
    bool ascending;
    bool numeric;
    void init(void)
        {
        key = (u8*)"";
        ascending = true;
        numeric = false;
        }

    static UXSortDescriptor* make(u8* key, bool ascending)
        {
        UXSortDescriptor* d = new UXSortDescriptor();
        d.key = key;
        d.ascending = ascending;
        return d;
        }
    static UXSortDescriptor* numericKey(u8* key, bool ascending)
        {
        UXSortDescriptor* d = UXSortDescriptor.make(key, ascending);
        d.numeric = true;
        return d;
        }

    static i32 strcmp(u8* a, u8* b)
        {
        if (a == (u8*)0)
            {
            a = (u8*)"";
            }
        if (b == (u8*)0)
            {
            b = (u8*)"";
            }
        i32 i = (i32)0;
        while (a[i] != (u8)0 && b[i] != (u8)0)
            {
            if (a[i] < b[i])
                {
                return (i32)-1;
                }
            if (a[i] > b[i])
                {
                return (i32)1;
                }
            i = i + (i32)1;
            }
        if (a[i] == b[i])
            {
            return (i32)0;
            }
        return a[i] == (u8)0 ? (i32)-1 : (i32)1;
        }

    // -1 if a<b, 0 equal, 1 if a>b, honouring numeric + ascending.
    i32 compare(UXEvaluable* a, UXEvaluable* b)
        {
        u8* va = a.valueForKey(key);
        u8* vb = b.valueForKey(key);
        i32 c;
        if (numeric)
            {
            i32 na = UXPredicate.toInt(va);
            i32 nb = UXPredicate.toInt(vb);
            c = na < nb ? (i32)-1 : (na > nb ? (i32)1 : (i32)0);
            }
        else
            {
            c = UXSortDescriptor.strcmp(va, vb);
            }
        return ascending ? c : -c;
        }

    // Stable-ish selection sort of `items` in place by this descriptor.
    void sort(Array<UXEvaluable>* items)
        {
        i32 n = (i32)items.count();
        for (i32 i = (i32)0; i < n - (i32)1; i = i + (i32)1)
            {
            i32 best = i;
            for (i32 j = i + (i32)1; j < n; j = j + (i32)1)
                {
                if (self.compare((UXEvaluable* ?)items.get((u16)j), (UXEvaluable* ?)items.get((u16)best)) < (i32)0)
                    {
                    best = j;
                    }
                }
            if (best != i)
                {
                UXEvaluable* x = items.get((u16)i);
                UXEvaluable* y = items.get((u16)best);
                items.set((u16)i, y);
                items.set((u16)best, x);
                }
            }
        }
    }
