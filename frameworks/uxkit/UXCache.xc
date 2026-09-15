// UXCache.xc — a bounded LRU cache (NSCache in shape).
//
// Keyed (string) storage with a capacity: when a set would exceed it, the least-recently-used entry is
// evicted.  Every get and set marks its entry most-recently-used via a monotonic clock, so the victim
// is always the entry with the oldest touch.  What an image/thumbnail/parsed-resource cache uses to
// stay bounded.  Pure data structure — testable.
#import "Array.xc"

class UXCacheEntry : Object
    {
    u8* key;
    Object* value;
    i32 touched; // clock value at last access
    void init(void)
        {
        key = (u8*)"";
        value = (Object*)0;
        touched = (i32)0;
        }
    }

    class UXCache
    {
    Array<UXCacheEntry>* entries;
    i32 capacity;
    i32 clock;
    void init(void)
        {
        entries = new Array();
        capacity = (i32)16;
        clock = (i32)0;
        }

    void setCapacity(i32 n)
        {
        capacity = n < (i32)1 ? (i32)1 : n;
        self.evictToFit();
        }
    i32 count(void)
        {
        return (i32)entries.count();
        }
    static bool streq(u8* a, u8* b)
        {
        i32 i = (i32)0;
        while (a[i] != (u8)0 && b[i] != (u8)0)
            {
            if (a[i] != b[i])
                {
                return false;
                }
            i = i + (i32)1;
            }
        return a[i] == b[i];
        }

    UXCacheEntry* find(u8* key)
        {
        for (u16 i = (u16)0; i < entries.count(); i = i + (u16)1)
            {
            UXCacheEntry* e = (UXCacheEntry* ?)entries.get(i);
            if (UXCache.streq(e.key, key))
                {
                return e;
                }
            }
        return (UXCacheEntry*)0;
        }

    void set(u8* key, Object* value)
        {
        clock = clock + (i32)1;
        UXCacheEntry* e = self.find(key);
        // update in place
        if (e != (UXCacheEntry*)0)
            {
            e.value = value;
            e.touched = clock;
            return;
            }
        e = new UXCacheEntry();
        e.key = key;
        e.value = value;
        e.touched = clock;
        entries.add(e);
        self.evictToFit();
        }
    Object* get(u8* key)
        {
        UXCacheEntry* e = self.find(key);
        if (e == (UXCacheEntry*)0)
            {
            return (Object*)0;
            }
        clock = clock + (i32)1;
        e.touched = clock; // mark most-recent
        return e.value;
        }
    bool contains(u8* key)
        {
        return self.find(key) != (UXCacheEntry*)0;
        }
    void remove(u8* key)
        {
        for (u16 i = (u16)0; i < entries.count(); i = i + (u16)1)
            {
            if (UXCache.streq(((UXCacheEntry* ?)entries.get(i)).key, key))
                {
                entries.removeAt(i);
                return;
                }
            }
        }
    void removeAll(void)
        {
        entries.removeAll();
        }

    // Evict least-recently-used entries until within capacity.
    void evictToFit(void)
        {
        while ((i32)entries.count() > capacity)
            {
            u16 victim = (u16)0; i32 oldest = ((UXCacheEntry* ?)entries.get((u16)0)).touched;
            for (u16 i = (u16)1; i < entries.count(); i = i + (u16)1)
                {
                i32 t = ((UXCacheEntry* ?)entries.get(i)).touched;
                if (t < oldest)
                    {
                    oldest = t;
                    victim = i;
                    }
                }
            entries.removeAt(victim);
            }
        }
    }
