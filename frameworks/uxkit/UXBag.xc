// UXBag.xc — a counted set / multiset (CFBag in shape).
//
// Like a set, but each member carries a COUNT: adding the same object again bumps its count instead of
// being ignored, removing decrements, and the member drops out at zero.  Membership is by object
// identity (CFBag's default), so it counts occurrences of the same reference — a histogram of tokens,
// a reference tally, "how many of these are selected".  totalCount is the sum of counts; uniqueCount
// is the number of distinct members.
#import "Array.xc"

class UXBagEntry : Object
    {
    Object* obj;
    i32 count;
    void init(void)
        {
        obj = (Object*)0;
        count = (i32)0;
        }
    }

    class UXBag
    {
    Array<UXBagEntry>* entries; // distinct members with counts
    i32 total;                  // sum of all counts
    void init(void)
        {
        entries = new Array();
        total = (i32)0;
        }

    UXBagEntry* entryFor(Object* o)
        {
        for (u16 i = (u16)0; i < entries.count(); i = i + (u16)1)
            {
            UXBagEntry* e = (UXBagEntry* ?)entries.get(i);
            // identity
            if (e.obj == o)
                {
                return e;
                }
            }
        return (UXBagEntry*)0;
        }

    void add(Object* o)
        {
        self.addTimes(o, (i32)1);
        }
    void addTimes(Object* o, i32 n)
        {
        if (n <= (i32)0)
            {
            return;
            }
        UXBagEntry* e = self.entryFor(o);
        if (e == (UXBagEntry*)0)
            {
            e = new UXBagEntry();
            e.obj = o;
            entries.add(e);
            }
        e.count = e.count + n;
        total = total + n;
        }
    // Remove one occurrence; the member drops out when its count hits zero.
    void remove(Object* o)
        {
        for (u16 i = (u16)0; i < entries.count(); i = i + (u16)1)
            {
            UXBagEntry* e = (UXBagEntry* ?)entries.get(i);
            if (e.obj == o)
                {
                e.count = e.count - (i32)1;
                total = total - (i32)1;
                if (e.count <= (i32)0)
                    {
                    entries.removeAt(i);
                    }
                return;
                }
            }
        }
    void removeAllOf(Object* o)
        {
        for (u16 i = (u16)0; i < entries.count(); i = i + (u16)1)
            {
            UXBagEntry* e = (UXBagEntry* ?)entries.get(i);
            if (e.obj == o)
                {
                total = total - e.count;
                entries.removeAt(i);
                return;
                }
            }
        }
    void removeAll(void)
        {
        entries.removeAll();
        total = (i32)0;
        }

    i32 countFor(Object* o)
        {
        UXBagEntry* e = self.entryFor(o);
        return e == (UXBagEntry*)0 ? (i32)0 : e.count;
        }
    bool contains(Object* o)
        {
        return self.entryFor(o) != (UXBagEntry*)0;
        }
    i32 totalCount(void)
        {
        return total;
        }
    i32 uniqueCount(void)
        {
        return (i32)entries.count();
        }
    // introspection: the i-th distinct member and its count
    Object* memberAt(i32 i)
        { return ((UXBagEntry* ?)entries.get((u16)i)).obj;
        }
    i32 countAt(i32 i)
        { return ((UXBagEntry* ?)entries.get((u16)i)).count;
        }
    }
