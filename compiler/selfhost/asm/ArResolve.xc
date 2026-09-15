// ArResolve.xc — choosing which archive members a link actually needs.
// =================================================================
//
// A static archive is not a library you link; it is a BAG of objects you may
// take from. The rule (task #47) is the traditional one: walk the archive
// repeatedly, and pull in a member exactly when it defines a symbol something
// already pulled in still needs. Pulling it in adds ITS undefined symbols to
// the want-list, which is why one pass is not enough — `printf` drags in the
// float formatter, which drags in the long-division helper.
//
// Two rules that are easy to get wrong and expensive to debug:
//
//   * A LOCAL definition cannot satisfy anybody. Only global and weak symbols
//     are visible across objects, and musl has plenty of static helpers whose
//     names collide with public ones.
//   * A WEAK undefined symbol is NOT a reason to pull a member in. `_DYNAMIC`
//     and `__init_array_start` are weak-undefined in musl and are supposed to
//     resolve to zero in a static link; treating them as wants would drag in
//     the dynamic loader, or fail the link outright for a symbol nothing
//     needs.
#import "Foundation.xc"
#import "ArArchive.xc"
#import "ElfObject.xc"

class ArPick
    {
    String* _archive;
    ArMember* _member;
    ElfObject* _object;
    u32 _id; // unique across every archive on the command line
    void init(void)
        {
        }
    String* archive(void)
        {
        return _archive;
        }
    ArMember* member(void)
        {
        return _member;
        }
    ElfObject* object(void)
        {
        return _object;
        }
    u32 id(void)
        {
        return _id;
        }
    void set(String* a, ArMember* m, ElfObject* o, u32 i)
        {
        _archive = a;
        _member = m;
        _object = o;
        _id = i;
        }
    }

    class ArResolve
    {
    Map* _defines;      // symbol name -> ArPick (first definer wins)
    Array* _order;      // ArPick@, in archive order — for stable output
    Array* _picked;     // ArPick@, the members actually taken
    Map* _taken;        // member ID -> Number(1)
    u32 _nextId;        // see the note on identity in addArchive
    Map* _satisfied;    // symbol name -> Number(1)
    Array* _unresolved; // String@
    Array* _pending;    // String@, the want-list not yet chased

    void init(void)
        {
        _defines = new Map();
        _order = new Array();
        _picked = new Array();
        _taken = new Map();
        _satisfied = new Map();
        _unresolved = new Array();
        _pending = new Array();
        _nextId = (u32)0;
        }

    Array* picked(void)
        {
        return _picked;
        }
    // The whole pool in archive order, id == index: what X86Link's
    // reference-shaped fixpoint walks (bug 133).
    Array* members(void)
        {
        return _order;
        }
    Array* unresolved(void)
        {
        return _unresolved;
        }

    // Index one archive. Call once per -l, in command-line order: the FIRST
    // archive to define a symbol wins, which is what the traditional linker
    // does and what lets a program override a libc symbol.
    void addArchive(String* path)
        {
        Array* ms = ArArchive.membersOfFile(path);
        if (ms == (Array*)0)
            return;
        for (u32 i = (u32)0; i < ms.count(); i = i + (u32)1)
            {
            ArMember* m = (ArMember*)ms.get(i);
            ElfObject* o = ElfObject.parse(m.data());
            if (!o.ok())
                continue; // not an object — skip, don't fail
            // A member is identified by its POSITION, never by its name.
            // musl's libc.a contains TWO distinct members called `free.lo`
            // (src/malloc/free.c and src/malloc/mallocng/free.c): the first
            // defines only `free` and REFERENCES __libc_free, the second
            // defines __libc_free. Keying "already taken" on the name made
            // pulling the first permanently mask the second, so __libc_free
            // could never be resolved however often it was wanted — a link
            // that failed on a symbol the archive plainly contains.
            ArPick* p = new ArPick();
            p.set(path, m, o, _nextId);
            _nextId = _nextId + (u32)1;
            _order.add((Object*)p);
            Array* def = o.definedNames();
            for (u32 k = (u32)0; k < def.count(); k = k + (u32)1)
                {
                String* n = (String*)def.get(k);
                if (_defines.get((Hashable*)n) != (Object*)0)
                    continue; // first wins
                _defines.set((Hashable*)n, (Object*)p);
                }
            }
        }

    // Seed the want-list from the objects WE produced, then close over it.
    void need(Array* names)
        {
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            _want((String*)names.get(i));
        _close();
        }

    void _want(String* n)
        {
        if (_satisfied.get((Hashable*)n) != (Object*)0)
            return;
        _satisfied.set((Hashable*)n, (Object*)Number.with((u32)1));
        _pending.add((Object*)n);
        }

    // The fixpoint: keep taking members until nothing new is wanted.
    void _close(void)
        {
        while (_pending.count() > (u32)0)
            {
            Array* round = _pending;
            _pending = new Array();
            for (u32 i = (u32)0; i < round.count(); i = i + (u32)1)
                {
                String* n = (String*)round.get(i);
                ArPick* p = (ArPick*)_defines.get((Hashable*)n);
                if (p == (ArPick*)0)
                    {
                    _unresolved.add((Object*)n);
                    continue;
                    }
                Number* key = Number.withU32(p.id());
                if (_taken.get((Hashable*)key) != (Object*)0)
                    continue;
                _taken.set((Hashable*)key, (Object*)Number.with((u32)1));
                _picked.add((Object*)p);
                // Everything this member defines is now satisfied...
                Array* def = p.object().definedNames();
                for (u32 k = (u32)0; k < def.count(); k = k + (u32)1)
                    _satisfied.set((Hashable*)def.get(k), (Object*)Number.with((u32)1));
                // ...and everything it needs joins the want-list, EXCEPT weak
                // undefineds, which resolve to zero rather than drag a member in.
                Array* syms = p.object().symdefs();
                for (u32 k = (u32)0; k < syms.count(); k = k + (u32)1)
                    {
                    ElfSymDef* s = (ElfSymDef*)syms.get(k);
                    if (s.where() != (u32)0 || !s.ext())
                        continue; // defined here
                    if (s.weak())
                        continue; // weak: resolves to 0
                    if (s.name() == 0 || s.name().byteLength() == (u32)0)
                        continue;
                    _want(s.name());
                    }
                }
            }
        }
    }
