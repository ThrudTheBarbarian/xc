// Vtable.xc — virtual slot numbering.
// =================================================================
//
// self-hosting M6. The port of `computeOverriddenMethods` +
// `computeVirtualMethodTables` from src/xtc/sema/XTSemanticAnalyzer+Analysis.m.
//
// Slots are PROGRAM-WIDE, not per class: every class implementing the method
// behind slot N puts its implementation at index N, so a call through a
// `Proto@` or a base-class pointer reaches the right body without knowing the
// leaf class. A slot number is therefore an ABI fact, and the numbering has to
// match the original down to the order it walks things in.
//
// Two sources, in this order:
//
//   1. OVERRIDE ROOTS. A method gets a slot when some subclass overrides it,
//      and the slot belongs to the ANCESTOR's method — the root of the override
//      chain — not to the override. Roots are numbered in sorted LABEL order,
//      which is what makes the assignment reproducible; a dictionary's own
//      order would not be.
//   2. PROTOCOL METHODS. Every protocol method takes a slot whether or not
//      anything overrides anything, because dispatch through a protocol-typed
//      receiver needs one. Protocols in sorted name order, methods in
//      DECLARATION order.
//
// Three things have to be right before any number is, and each cost a wrong
// answer to find (`XTC_DUMP_VSLOTS=1 xtc-fe --dump-sema …` prints the
// original's assignment, which is how they were found):
//
//   * A class with no explicit parent still HAS one: Object.
//   * Sema SYNTHESISES `description()` on every class that lacks one (except
//     Object and String), so every such class overrides Object's — which is
//     what makes `_cls_Object_description` a root and gives it slot 0. It is
//     modelled here without adding a node to the tree, because adding one would
//     change the DUMP the harness compares.
//   * Signatures match on resolved TYPES, not spellings: `string` and `u8@` are
//     one parameter type, not two. Comparing spellings misses overrides, and a
//     missed override is a missing root, and a missing root shifts every slot
//     after it.

#import "Foundation.xc"
#import "Node.xc"

class Vtable
    {
    Map* _slotByLabel; // `_cls_<Class>_<mangled>` -> slot
    Map* _protoSlots;  // protocol name -> Map(method name -> slot)
    Array* _roots;     // slot -> the override-root label that owns it
    u32 _total;
    Map* _adopted;      // imported label -> slot: theirs, not renumbered
    u32 _adoptedBase;   // our own numbering starts above their highest
    Map* _chainLabels;  // §4.2: root labels living in the CHAIN slot
    Map* _cyclic;       // severed classes (findCycles) — their parent is GONE
    bool _libraryBuild; // --emit-lib / -c: the program is NOT whole
    Map* _adoptedProto; // proto -> Map(method -> slot): an imported
                        //   library's protocol numbering, which is
                        //   authoritative for the same reason its method
                        //   numbering is — its vtables are already emitted
                        // space — excluded from vtable numbering

    void init(void)
        {
        _slotByLabel = new Map();
        _protoSlots = new Map();
        _total = (u32)0;
        _adopted = new Map();
        _adoptedBase = (u32)0;
        _libraryBuild = false;
        _adoptedProto = new Map();
        }

    // Adopt a slot an imported module already committed to: its vtables are
    // emitted, we cannot renumber them, so its numbering is authoritative and
    // ours starts above the highest slot it used. Mirrors the reference's
    // importedMethodSlots adoption exactly. Called before assign().
    void adopt(String* label, u32 slot)
        {
        _adopted.set((Hashable*)label, (Object*)Number.withU32(slot));
        if (slot + (u32)1 > _adoptedBase)
            _adoptedBase = slot + (u32)1;
        }
    Map* adopted(void)
        {
        return _adopted;
        }
    void setLibraryBuild(bool b)
        {
        _libraryBuild = b;
        }

    // Adopt one imported protocol method's slot. Ours continue above the
    // highest, exactly as for methods: a client that renumbered would dispatch
    // a `Proto*` receiver into a slot the library never filled — which is a
    // null table entry at run time, not a link error. Skipped on arm9, where
    // dispatch goes through the itable and adopting is what would create an
    // unsatisfiable collision between two independent libraries.
    void adoptProtoSlot(String* proto, String* method, u32 slot)
        {
        Map* m = (Map*)_adoptedProto.get((Hashable*)proto);
        if (m == 0)
            {
            m = new Map();
            _adoptedProto.set((Hashable*)proto, (Object*)m);
            }
        m.set((Hashable*)method, (Object*)Number.withU32(slot));
        if (slot + (u32)1 > _adoptedBase)
            _adoptedBase = slot + (u32)1;
        }
    void setChainLabels(Map* m)
        {
        _chainLabels = m;
        }
    void setCyclic(Map* m)
        {
        _cyclic = m;
        }

    // The parent walk, respecting the severing: the original clears the
    // NODE's parent link on cycle detection, so every consumer sees the
    // break; the port's severing is a side map, so the walkers that matter
    // must consult it (task #36).
    Node* parentRespectingCycles(Map* classes, Node* c)
        {
        if (_cyclic != 0 && c.name() != 0 && _cyclic.get((Hashable*)c.name()) != 0)
            return (Node*)0;
        return Vtable.walkParent(classes, c);
        }
    Array* rootLabels(void)
        {
        return _roots == 0 ? new Array() : _roots;
        }
    bool isChainLabel(String* l)
        {
        return _chainLabels != 0 && _chainLabels.get((Hashable*)l) != 0;
        }

    u32 total(void)
        {
        return _total;
        }
    Map* protoSlotsFor(String* proto)
        {
        return (Map*)_protoSlots.get((Hashable*)proto);
        }
    Object* slotForLabel(String* label)
        {
        return _slotByLabel.get((Hashable*)label);
        }
    // The whole table, for the INTERFACE writer: a client links against our
    // slot numbers, so they travel in the `.xtc.iface` rather than being
    // recomputed on the other side (where a different set of classes would
    // number them differently).
    Map* slotByLabel(void)
        {
        return _slotByLabel;
        }
    Map* protoSlots(void)
        {
        return _protoSlots;
        }

    // The parent of `cls` for WALKING purposes: nil at the root, and nil for a
    // class that is its own parent. `class A : A` is a sema error, but the
    // analyser still has to walk the tree without hanging — and every walk in
    // this file follows parents, so the guard belongs here rather than at each
    // call site.
    static Node* walkParent(Map* classes, Node* cls)
        {
        String* pn = Vtable.parentName(cls);
        if (pn == 0)
            return (Node*)0;
        if (cls.name() != 0 && pn.equals(cls.name()))
            return (Node*)0;
        return (Node*)classes.get((Hashable*)pn);
        }

    // The explicit `: Super`, or Object for everything except Object itself.
    //
    // "No superclass" is spelled `-` on the node, not nil — the parser writes
    // the dash the dump prints. Reading it as a NAME is what made every class
    // look parentless, so no class overrode anything, so there were no override
    // roots at all and every slot in the program was three too low.
    static String* parentName(Node* cls)
        {
        if (cls.op() != 0 && !cls.op().equals(String.withCString("-")))
            return cls.op();
        if (cls.name() != 0 && cls.name().equals(String.withCString("Object")))
            return (String*)0;
        return String.withCString("Object");
        }

    static String* label(String* cls, Node* m)
        {
        String* s = String.withCString("_cls_");
        s.append(cls);
        s.appendByte((u8)'_');
        s.append(m.sym() != 0 ? m.sym() : m.name());
        return s;
        }

    // One spelling for what is one type. The analyser carries spellings (see
    // Sema.xc), and everywhere else that is exactly right — but a SIGNATURE
    // comparison is about type identity, so the aliases have to collapse first.
    static String* canonical(String* t)
        {
        if (t == 0)
            return t;
        String* s = Node.stripElem(t);
        // Placement and weak qualifiers are not part of a parameter's identity.
        while (true)
            {
            u32 c = (u32)$FFFFFFFF;
            for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
                if (s.byteAt(i) == (u8)':')
                    {
                    c = i;
                    }
            if (c == (u32)$FFFFFFFF)
                break;
            s = s.substringBytes(c + (u32)1, s.byteLength() - c - (u32)1);
            }
        if (s.equals(String.withCString("string")))
            return String.withCString("u8*");
        return s;
        }

    static bool sameType(String* a, String* b)
        {
        String* x = Vtable.canonical(a);
        String* y = Vtable.canonical(b);
        if (x == 0 || y == 0)
            return false;
        return x.equals(y);
        }

    // Does `cls` declare a method matching `want`'s name and parameter types?
    static Node* matching(Node* cls, Node* want)
        {
        for (u32 i = (u32)0; i < cls.kidCount(); i = i + (u32)1)
            {
            Node* m = cls.kid(i);
            if (m.kind() != (u16)nkMethodDecl)
                continue;
            if (m.name() == 0 || want.name() == 0)
                continue;
            if (!m.name().equals(want.name()))
                continue;
            if (Vtable.sameParams(m, want))
                return m;
            }
        return (Node*)0;
        }

    // The first method of `cls` with this name, whatever its signature.
    static Node* namedMethod(Node* cls, String* name)
        {
        for (u32 i = (u32)0; i < cls.kidCount(); i = i + (u32)1)
            {
            Node* m = cls.kid(i);
            if (m.kind() != (u16)nkMethodDecl)
                continue;
            if (m.name() != 0 && m.name().equals(name))
                return m;
            }
        return (Node*)0;
        }

    // The same by NAME and arity only, for the synthesised `description()`,
    // which has no node to compare against.
    static Node* zeroArgNamed(Node* cls, string name)
        {
        for (u32 i = (u32)0; i < cls.kidCount(); i = i + (u32)1)
            {
            Node* m = cls.kid(i);
            if (m.kind() != (u16)nkMethodDecl)
                continue;
            if (m.name() == 0 || !m.name().equals(String.withCString(name)))
                continue;
            if (Vtable.paramTypes(m).count() == (u32)0)
                return m;
            }
        return (Node*)0;
        }

    static bool sameParams(Node* a, Node* b)
        {
        Array* pa = Vtable.paramTypes(a);
        Array* pb = Vtable.paramTypes(b);
        if (pa.count() != pb.count())
            return false;
        for (u32 i = (u32)0; i < pa.count(); i = i + (u32)1)
            {
            if (!Vtable.sameType((String*)pa.get(i), (String*)pb.get(i)))
                return false;
            }
        return true;
        }

    static Array* paramTypes(Node* m)
        {
        Array* out = new Array();
        for (u32 i = (u32)0; i < m.kidCount(); i = i + (u32)1)
            {
            Node* p = m.kid(i);
            if (p.kind() == (u16)nkParam)
                out.add((Object*)p.op());
            }
        return out;
        }

    // Pass 1 — the override roots, as a sorted array of labels.
    void collectRoots(Map* classes, Array* outLabels)
        {
        Array* names = classes.allKeys();
        // LIBRARY build: the program is not whole. The overrides live in a
        // client that does not exist yet, so "nothing overrides this method"
        // is not a fact we are entitled to — devirtualising on it would make
        // an app's override permanently unreachable. Every instance method of
        // every class is an override root, so it earns a slot.
        //
        // Static methods are excluded: no `self`, nothing to dispatch on.
        // `init` too — it runs on a known concrete class at `new` time, never
        // through a base pointer. `final` is the author asserting no client
        // overrides it, and overriding a final method is already an error.
        if (_libraryBuild)
            {
            for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
                {
                Node* cls = (Node*)classes.get((Hashable*)names.get(i));
                for (u32 j = (u32)0; j < cls.kidCount(); j = j + (u32)1)
                    {
                    Node* m = cls.kid(j);
                    if (m.kind() != (u16)nkMethodDecl)
                        continue;
                    if (m.hasFlag((u32)NF_STATIC))
                        continue;
                    if (m.name() != 0 && m.name().equals(String.withCString("init")))
                        continue;
                    if (m.hasFlag((u32)NF_FINAL))
                        continue;
                    Vtable.addUnique(outLabels, Vtable.label(cls.name(), m));
                    }
                }
            }
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            Node* cls = (Node*)classes.get((Hashable*)names.get(i));
            String* pn0 = Vtable.parentName(cls);
            if (pn0 == 0)
                continue; // Object itself overrides nothing

            // A synthesised description() used to be modelled HERE, walking up
            // to the nearest ancestor that has one and rooting there. That
            // double-counted: sema already materialises a description NODE on
            // the classes that need one, so the general walk below roots it
            // correctly — and this block additionally rooted at an ancestor
            // whose own description was synthesised too. In `Dog : Animal`
            // where neither writes one, it produced `_cls_Animal_description`,
            // an override that does not exist, and every later slot shifted by
            // one against the ObjC compiler. Slot numbers are an ABI. Bug 035.

            for (u32 j = (u32)0; j < cls.kidCount(); j = j + (u32)1)
                {
                Node* child = cls.kid(j);
                if (child.kind() != (u16)nkMethodDecl)
                    continue;
                // Walk up: the FIRST ancestor with a matching signature owns the
                // slot, and the walk stops there — a chain of three overrides is
                // one slot, not two.
                Node* a = parentRespectingCycles(classes, cls);
                u32 guard = (u32)0;
                while (a != 0 && guard < (u32)64)
                    {
                    Node* match = Vtable.matching(a, child);
                    if (match != 0)
                        {
                        Vtable.addUnique(outLabels, Vtable.label(a.name(), match));
                        a = (Node*)0;
                        }
                    else
                        {
                        a = parentRespectingCycles(classes, a);
                        }
                    guard = guard + (u32)1;
                    }
                }
            }
        Vtable.sortStrings(outLabels);
        }

    // Per-class deterministic vtable numbering (bug 201). A root method's slot
    // is its owning class's PARENT vtable size + its index among the class's own
    // true roots (sorted) — a pure function of the class's ancestor chain, which
    // every compilation unit sees identically, so two objects that number their
    // vtables from source AGREE. Overrides are not roots (they collapse to the
    // ancestor root's slot in the vtable fill), so String.description lands at
    // Object.description's slot in every unit. Used for a `-c`/library build,
    // where the program is split across independently compiled objects and a
    // program-global counter would number the same class differently per object.
    u32 _vsizeFor(Map* classes, Node* cls, Map* vsize, Array* allRoots)
        {
        String* cn = cls.name();
        if (cn == 0)
            return (u32)0;
        Object* have = vsize.get((Hashable*)cn);
        if (have != 0)
            return ((Number*)have).asU32();
        vsize.set((Hashable*)cn, (Object*)Number.withU32((u32)0)); // cycle guard
        Node* p = parentRespectingCycles(classes, cls);
        u32 base = (p != 0) ? _vsizeFor(classes, p, vsize, allRoots) : (u32)0;
        Array* own = new Array();
        for (u32 j = (u32)0; j < cls.kidCount(); j = j + (u32)1)
            {
            Node* m = cls.kid(j);
            if (m.kind() != (u16)nkMethodDecl)
                continue;
            if (m.hasFlag((u32)NF_STATIC))
                continue;
            if (m.name() != 0 && m.name().equals(String.withCString("init")))
                continue;
            if (m.hasFlag((u32)NF_FINAL))
                continue;
            bool ovr = false;
            Node* a = p;
            u32 g = (u32)0;
            while (a != 0 && g < (u32)64)
                {
                if (Vtable.matching(a, m) != 0)
                    {
                    ovr = true;
                    a = (Node*)0;
                    }
                else
                    {
                    a = parentRespectingCycles(classes, a);
                    }
                g = g + (u32)1;
                }
            if (ovr)
                continue; // an override shares its root's slot
            own.add((Object*)Vtable.label(cn, m));
            }
        Vtable.sortStrings(own);
        u32 n = base;
        for (u32 j = (u32)0; j < own.count(); j = j + (u32)1)
            {
            String* l = (String*)own.get(j);
            if (_chainLabels != 0 && _chainLabels.get((Hashable*)l) != 0)
                continue; // §4.2 chain, not vtable
            allRoots.add((Object*)l);
            if (_slotByLabel.get((Hashable*)l) != 0)
                continue; // adopted: keep the library's number
            _slotByLabel.set((Hashable*)l, (Object*)Number.withU32(n));
            n = n + (u32)1;
            }
        vsize.set((Hashable*)cn, (Object*)Number.withU32(n));
        return n;
        }

    void assignPerClass(Map* classes, Map* protocols)
        {
        Array* alab = _adopted.allKeys();
        for (u32 i = (u32)0; i < alab.count(); i = i + (u32)1)
            {
            String* l = (String*)alab.get(i);
            _slotByLabel.set((Hashable*)l, _adopted.get((Hashable*)l));
            }
        Map* vsize = new Map();
        Array* allRoots = new Array();
        Array* names = classes.allKeys();
        Vtable.sortStrings(names);
        u32 mx = _adoptedBase;
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            Node* cls = (Node*)classes.get((Hashable*)names.get(i));
            u32 vs = _vsizeFor(classes, cls, vsize, allRoots);
            if (vs > mx)
                mx = vs;
            }
        _roots = allRoots;
        // Protocol methods still get a vtable slot NUMBER, appended after the
        // roots — dispatch goes through the itable (which ignores the value),
        // but the number being >= 0 is the marker that tells lowering "this is a
        // protocol receiver" (Lower.lowerMethodCall guards on vslot >= 0). The
        // value need not agree across objects; only proto id + method index
        // (the itable key) must, and those already do.
        u32 next = mx;
        Array* pnames = protocols.allKeys();
        Vtable.sortStrings(pnames);
        for (u32 i = (u32)0; i < pnames.count(); i = i + (u32)1)
            {
            String* pn = (String*)pnames.get(i);
            Node* proto = (Node*)protocols.get((Hashable*)pn);
            Map* slots = new Map();
            Map* pre = (Map*)_adoptedProto.get((Hashable*)pn);
            if (pre != 0)
                {
                Array* pk = pre.allKeys();
                for (u32 j = (u32)0; j < pk.count(); j = j + (u32)1)
                    slots.set((Hashable*)pk.get(j), pre.get((Hashable*)pk.get(j)));
                }
            for (u32 j = (u32)0; j < proto.kidCount(); j = j + (u32)1)
                {
                Node* m = proto.kid(j);
                if (m.kind() != (u16)nkMethodDecl)
                    continue;
                if (slots.get((Hashable*)m.name()) != 0)
                    continue;
                slots.set((Hashable*)m.name(), (Object*)Number.withU32(next));
                next = next + (u32)1;
                }
            _protoSlots.set((Hashable*)pn, (Object*)slots);
            }
        _total = next;
        }

    // Roots first, then every protocol method. Both in a fixed order, because
    // the numbers are an ABI.
    void assign(Map* classes, Map* protocols)
        {
        if (_libraryBuild)
            {
            assignPerClass(classes, protocols);
            return;
            }
        // Adopted (imported) numbering first — verbatim, and ours continues
        // above it. An adopted label that also shows up as a local root keeps
        // the imported number ("imported: already fixed").
        Array* alab = _adopted.allKeys();
        for (u32 i = (u32)0; i < alab.count(); i = i + (u32)1)
            {
            String* l = (String*)alab.get(i);
            _slotByLabel.set((Hashable*)l, _adopted.get((Hashable*)l));
            }
        Array* roots = new Array();
        collectRoots(classes, roots);
        // An ADOPTED label has a slot but is not a local root, and the vtable is
        // materialised by walking rootLabels() — so without this the number is
        // known and the table entry is never emitted. That is bug 091 seen from
        // the other end: the client agreed the library's slot for
        // String.byteLength and still left it empty, which is the same null
        // function at run time.
        //
        // Appended AFTER collectRoots so local numbering is untouched: `next`
        // starts at _adoptedBase and the loop below skips anything already in
        // _slotByLabel, so these carry the library's number and cost no new one.
        Map* haveRoot = new Map();
        for (u32 i = (u32)0; i < roots.count(); i = i + (u32)1)
            haveRoot.set((Hashable*)(String*)roots.get(i), (Object*)Number.withU32((u32)1));
        Array* alab2 = _adopted.allKeys();
        for (u32 i = (u32)0; i < alab2.count(); i = i + (u32)1)
            {
            String* l = (String*)alab2.get(i);
            if (haveRoot.get((Hashable*)l) != (Object*)0)
                continue;
            roots.add((Object*)l);
            }
        _roots = roots;
        u32 next = _adoptedBase;
        for (u32 i = (u32)0; i < roots.count(); i = i + (u32)1)
            {
            String* l = (String*)roots.get(i);
            if (_slotByLabel.get((Hashable*)l) != 0)
                continue; // imported: already fixed
            if (_chainLabels != 0 && _chainLabels.get((Hashable*)l) != 0)
                continue; // §4.2: chain, not vtable
            _slotByLabel.set((Hashable*)l, (Object*)Number.withU32(next));
            next = next + (u32)1;
            }
        Array* pnames = protocols.allKeys();
        Vtable.sortStrings(pnames);
        for (u32 i = (u32)0; i < pnames.count(); i = i + (u32)1)
            {
            String* pn = (String*)pnames.get(i);
            Node* proto = (Node*)protocols.get((Hashable*)pn);
            // Start from what the LIBRARY already numbered, if anything.
            Map* slots = new Map();
            Map* pre = (Map*)_adoptedProto.get((Hashable*)pn);
            if (pre != 0)
                {
                Array* pk = pre.allKeys();
                for (u32 j = (u32)0; j < pk.count(); j = j + (u32)1)
                    slots.set((Hashable*)pk.get(j), pre.get((Hashable*)pk.get(j)));
                }
            for (u32 j = (u32)0; j < proto.kidCount(); j = j + (u32)1)
                {
                Node* m = proto.kid(j);
                if (m.kind() != (u16)nkMethodDecl)
                    continue;
                if (slots.get((Hashable*)m.name()) != 0)
                    continue; // imported: fixed
                slots.set((Hashable*)m.name(), (Object*)Number.withU32(next));
                next = next + (u32)1;
                }
            _protoSlots.set((Hashable*)pn, (Object*)slots);
            }
        _total = next;
        }

    // The mirror of XTC_DUMP_VSLOTS on the original, so the two assignments can
    // be diffed line for line rather than inferred from what they produce.
    void dumpTo(String* out)
        {
        Array* labels = _slotByLabel.allKeys();
        Vtable.sortStrings(labels);
        for (u32 i = (u32)0; i < labels.count(); i = i + (u32)1)
            {
            String* l = (String*)labels.get(i);
            out.appendFormat("vslot root  %2lu  %s\n",
                             ((Number*)_slotByLabel.get((Hashable*)l)).asU32(), l.cString());
            }
        Array* pn = _protoSlots.allKeys();
        Vtable.sortStrings(pn);
        for (u32 i = (u32)0; i < pn.count(); i = i + (u32)1)
            {
            String* p = (String*)pn.get(i);
            Map* ms = (Map*)_protoSlots.get((Hashable*)p);
            Array* mn = ms.allKeys();
            Vtable.sortStrings(mn);
            for (u32 j = (u32)0; j < mn.count(); j = j + (u32)1)
                {
                String* m = (String*)mn.get(j);
                out.appendFormat("vslot proto %2lu  %s.%s\n",
                                 ((Number*)ms.get((Hashable*)m)).asU32(),
                                 p.cString(), m.cString());
                }
            }
        out.appendFormat("vslot total %lu\n", _total);
        }

    static void addUnique(Array* a, String* s)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).equals(s))
                return;
        a.add((Object*)s);
        }

    static bool _is(String* s, string lit)
        {
        if (s == 0)
            return false;
        return s.equals(String.withCString(lit));
        }

    // Insertion sort: a few dozen entries at most, and the ORDER is the
    // contract — not the speed of getting there.
    static void sortStrings(Array* a)
        {
        for (u32 i = (u32)1; i < a.count(); i = i + (u32)1)
            {
            String* key = (String*)a.get(i);
            u32 j = i;
            while (j > (u32)0 && ((String*)a.get(j - (u32)1)).compare(key) > (i8)0)
                {
                a.set(j, a.get(j - (u32)1));
                j = j - (u32)1;
                }
            a.set(j, (Object*)key);
            }
        }
    }
