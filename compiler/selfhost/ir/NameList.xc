// NameList.xc — names in the order they were added, each once, with a hash
// set beside them (#335). Lowering kept its per-function name lists (the
// strong and weak locals, the names `&` or inline asm touched, ...) as plain
// arrays and asked "is this name in it" with a scan, at every assignment and
// every scope exit: quadratic in a function's size. The order is kept, as the
// lists' users walk them (a scope's releases follow it).
#import "Foundation.xc"

class NameList
{
    Array* _order;
    Map* _set;

    void init(void)
    {
        _order = new Array();
        _set = new Map();
    }

    // The names of a list, first occurrence first.
    static NameList* of(Array* names)
    {
        NameList* l = new NameList();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            l.add((String*)names.get(i));
        return l;
    }

    u32 count(void)
    {
        return _order.count();
    }

    String* get(u32 i)
    {
        return (String*)_order.get(i);
    }

    bool has(String* name)
    {
        return name != (String*)0 && _set.get((Hashable*)name) != (Object*)0;
    }

    // Adds name at the end unless it is there already.
    void add(String* name)
    {
        if (name == (String*)0 || has(name))
            return;
        _set.set((Hashable*)name, (Object*)name);
        _order.add((Object*)name);
    }

    void remove(String* name)
    {
        if (!has(name))
            return;
        _set.remove((Hashable*)name);
        for (u32 i = (u32)0; i < _order.count(); i = i + (u32)1)
            if (((String*)_order.get(i)).equals(name))
            {
                _order.removeAt(i);
                return;
            }
    }

    NameList* copy(void)
    {
        NameList* c = new NameList();
        c.refill(self);
        return c;
    }

    // This list becomes a copy of from.
    void refill(NameList* from)
    {
        _order = new Array();
        _set = new Map();
        for (u32 i = (u32)0; i < from.count(); i = i + (u32)1)
            add(from.get(i));
    }
}
