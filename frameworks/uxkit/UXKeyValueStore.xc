// UXKeyValueStore.xc — a typed key/value settings store (NSUserDefaults in shape), PERSISTENT.
//
// String / integer / boolean values keyed by name, with a REGISTRATION domain of fallbacks consulted
// when a key was never explicitly set — exactly NSUserDefaults' registerDefaults behaviour, so an app
// reads a sensible value on first launch.
//
// Values SURVIVE THE PROCESS, through UXViewDriver's setting seam: on XTOS they go into the system
// SQLite registry the desktop already keeps its own preferences in (a `settings` table, created on
// demand — see gem/registry.c), on macOS into NSUserDefaults, on Win32 into an .ini under %APPDATA%.
// A store made before a driver is booted, or on a backend with nowhere to write, still works — it is
// simply in-memory, which is what this class used to be everywhere.
//
// DOMAINS namespace a key to one application: standard() is the SHARED domain, seen by every program
// on the machine, and forDomain("ks") is that app's own.  A read in a named domain falls back to the
// shared value when the domain has none, so a machine-wide default can be set once and overridden per
// app.  That fallback is applied HERE rather than in each backend, so the rule is one rule.
//
// The in-memory entries are a CACHE of the persistent store, not a copy of it: a key is fetched once
// and then answered from memory.  Another process writing the same key mid-run is therefore not seen
// — the same bargain NSUserDefaults makes, and the alternative is a database round trip per read.
#import "Array.xc"
#import "UXString.xc"
#import "UXViewDriver.xc" // gDriver — the persistence seam

#define UXKV_STRING 0
#define UXKV_INT 1
#define UXKV_BOOL 2

class UXKVEntry : Object
    {
    u8* key;
    i32 type;
    u8* str;
    i32 num;
    void init(void)
        {
        key = (u8*)"";
        type = (i32)UXKV_STRING;
        str = (u8*)"";
        num = (i32)0;
        }
    }

    UXKeyValueStore* gUXStandardDefaults;
Array<UXKeyValueStore>* gUXDomainStores; // the per-domain stores, so forDomain("ks") is always the same one
u8 gUXKVBuf[1024];                       // one scratch buffer for a settingGet — copied out immediately

class UXKeyValueStore
    {
    Array<UXKVEntry>* entries; // explicitly-set values (and values read back from the persistent store)
    Array* registered;         // fallback domain (registerDefaults)
    u8* domain;                // 0 = the shared domain
    void init(void)
        {
        entries = new Array();
        registered = new Array();
        domain = (u8*)0;
        }

    static UXKeyValueStore* standard(void)
        {
        if (gUXStandardDefaults == (UXKeyValueStore*)0)
            {
            gUXStandardDefaults = new UXKeyValueStore();
            }
        return gUXStandardDefaults;
        }
    // The store for ONE application's settings.  Same domain -> same store, because two stores over
    // one domain would each cache half of it and disagree.
    static UXKeyValueStore* forDomain(u8* d)
        {
        if (d == (u8*)0 || d[(i32)0] == (u8)0)
            {
            return UXKeyValueStore.standard();
            }
        if (gUXDomainStores == (Array*)0)
            {
            gUXDomainStores = new Array();
            }
        for (u16 i = (u16)0; i < gUXDomainStores.count(); i = i + (u16)1)
            {
            UXKeyValueStore* s = (UXKeyValueStore* ?)gUXDomainStores.get(i);
            if (UXKeyValueStore.streq(s.domain, d))
                {
                return s;
                }
            }
        UXKeyValueStore* s = new UXKeyValueStore();
        s.domain = d;
        gUXDomainStores.add(s);
        return s;
        }
    u8* domainName(void)
        {
        return domain == (u8*)0 ? (u8*)"" : domain;
        }

    static bool streq(u8* a, u8* b)
        {
        if (a == (u8*)0 || b == (u8*)0)
            {
            return a == b;
            }
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

    static UXKVEntry* find(Array<UXKVEntry>* where, u8* key)
        {
        for (u16 i = (u16)0; i < where.count(); i = i + (u16)1)
            {
            UXKVEntry* e = (UXKVEntry* ?)where.get(i);
            if (UXKeyValueStore.streq(e.key, key))
                {
                return e;
                }
            }
        return (UXKVEntry*)0;
        }
    UXKVEntry* upsert(u8* key)
        {
        UXKVEntry* e = UXKeyValueStore.find(entries, key);
        if (e == (UXKVEntry*)0)
            {
            e = new UXKVEntry();
            e.key = key;
            entries.add(e);
            }
        return e;
        }

    // ---- the persistent store ------------------------------------------------
    // Ask the backend for THIS domain's `key` and cache what comes back, so a key costs one lookup
    // per process.  Exact: the shared-domain fallback is a separate step in resolve(), because a
    // value inherited from the shared domain must be cached THERE and not here — otherwise hasKey
    // would report that this domain owns a value it merely inherited.
    UXKVEntry* cacheFetched(u8* key)
        {
        if (gDriver == (UXViewDriver*)0)
            {
            return (UXKVEntry*)0;
            }
        if (!gDriver.settingGet(self.domainName(), key, &gUXKVBuf[(i32)0], (i32)1024))
            {
            return (UXKVEntry*)0;
            }
        u8* v = UXStr.dup(&gUXKVBuf[(i32)0]);
        UXKVEntry* e = new UXKVEntry();
        e.key = key;
        e.type = (i32)UXKV_STRING;
        e.str = v;
        e.num = UXStr.toInt(v);
        entries.add(e);
        return e;
        }
    void store(u8* key, u8* value)
        {
        if (gDriver != (UXViewDriver*)0)
            {
            gDriver.settingSet(self.domainName(), key, value);
            }
        }

    // resolve a key: this domain's own value (in memory, else persisted), else the SHARED domain's,
    // else this domain's registered fallback, else null.  The shared step goes through the standard
    // STORE — so a shared value is fetched and cached once, wherever it is first asked for, and a
    // value set on standard() this run is seen even where nothing persists.
    UXKVEntry* resolve(u8* key)
        {
        UXKVEntry* e = UXKeyValueStore.find(entries, key);
        if (e != (UXKVEntry*)0)
            {
            return e;
            }
        e = self.cacheFetched(key);
        if (e != (UXKVEntry*)0)
            {
            return e;
            }
        if (domain != (u8*)0)
            {
            UXKeyValueStore* sh = UXKeyValueStore.standard();
            UXKVEntry* se = UXKeyValueStore.find(sh.entries, key);
            if (se == (UXKVEntry*)0)
                {
                se = sh.cacheFetched(key);
                }
            if (se != (UXKVEntry*)0)
                {
                return se;
                }
            }
        return UXKeyValueStore.find(registered, key);
        }

    // ---- writes --------------------------------------------------------------
    // Each write goes through to the backing store immediately.  There is no synchronize(): a
    // preference the user just changed must not be lost to a crash before some flush timer ran.
    void setString(u8* key, u8* v)
        {
        UXKVEntry* e = self.upsert(key);
        e.type = (i32)UXKV_STRING;
        e.str = v;
        e.num = UXStr.toInt(v);
        self.store(key, v);
        }
    void setInt(u8* key, i32 v)
        {
        u8* s = UXStr.fromInt(v);
        UXKVEntry* e = self.upsert(key);
        e.type = (i32)UXKV_INT;
        e.num = v;
        e.str = s;
        self.store(key, s);
        }
    void setBool(u8* key, bool v)
        {
        UXKVEntry* e = self.upsert(key);
        e.type = (i32)UXKV_BOOL;
        e.num = v ? (i32)1 : (i32)0;
        e.str = v ? (u8*)"1" : (u8*)"0";
        self.store(key, e.str);
        }
    void removeKey(u8* key)
        {
        if (gDriver != (UXViewDriver*)0)
            {
            gDriver.settingRemove(self.domainName(), key);
            }
        for (u16 i = (u16)0; i < entries.count(); i = i + (u16)1)
            {
            if (UXKeyValueStore.streq(((UXKVEntry* ?)entries.get(i)).key, key))
                {
                entries.removeAt(i);
                return;
                }
            }
        }

    // ---- reads (explicit value, else the store, else the registered fallback) --
    u8* stringFor(u8* key)
        {
        UXKVEntry* e = self.resolve(key);
        return e == (UXKVEntry*)0 ? (u8*)0 : e.str;
        }
    i32 intFor(u8* key)
        {
        UXKVEntry* e = self.resolve(key);
        return e == (UXKVEntry*)0 ? (i32)0 : e.num;
        }
    bool boolFor(u8* key)
        {
        UXKVEntry* e = self.resolve(key);
        if (e == (UXKVEntry*)0)
            {
            return false;
            }
        if (e.type != (i32)UXKV_STRING)
            {
            return e.num != (i32)0;
            }
        // A string that came back from the store: "1"/"true"/"yes" are all true, "0"/""/"false" not.
        u8 c = e.str[(i32)0];
        return c == (u8)'1' || c == (u8)'t' || c == (u8)'T' || c == (u8)'y' || c == (u8)'Y';
        }
    // hasKey is about an EXPLICIT value, not a fallback (NSUserDefaults objectForKey semantics) —
    // and a value sitting in the persistent store from an earlier run IS explicit.
    bool hasKey(u8* key)
        {
        self.resolve(key); // may pull a persisted value into the cache
        return UXKeyValueStore.find(entries, key) != (UXKVEntry*)0;
        }

    // Drop the in-memory cache, so the next read goes back to the persistent store.  For a test, and
    // for an app that knows another process has just written its settings.
    void invalidate(void)
        {
        entries = new Array();
        }

    // ---- registration domain (fallbacks) ------------------------------------
    UXKVEntry* upsertRegistered(u8* key)
        {
        UXKVEntry* e = UXKeyValueStore.find(registered, key);
        if (e == (UXKVEntry*)0)
            {
            e = new UXKVEntry();
            e.key = key;
            registered.add(e);
            }
        return e;
        }
    void registerString(u8* key, u8* v)
        {
        UXKVEntry* e = self.upsertRegistered(key);
        e.type = (i32)UXKV_STRING;
        e.str = v;
        }
    void registerInt(u8* key, i32 v)
        {
        UXKVEntry* e = self.upsertRegistered(key);
        e.type = (i32)UXKV_INT;
        e.num = v;
        }
    void registerBool(u8* key, bool v)
        {
        UXKVEntry* e = self.upsertRegistered(key);
        e.type = (i32)UXKV_BOOL;
        e.num = v ? (i32)1 : (i32)0;
        }
    }
