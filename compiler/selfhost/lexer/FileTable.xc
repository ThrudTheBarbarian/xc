// FileTable.xc — interned source-file names.
// =================================================================
//
// Tokens and AST nodes have to know WHICH FILE they came from, and there are
// millions of them. They cannot hold a `String*`: the runtime's refcount is a
// **u16 that wraps** (private:docs/Design/self-hosting.md, private:docs/bugs/025), so one name
// retained once per token passes 65,536 on any large file, wraps to zero, and
// the next release frees a string that is still in use. selfhost/opt/Opt.xc is
// 117k tokens and aborted the lexer the moment tokens held the pointer.
//
// So they hold a u32 INDEX into this table, which owns exactly one reference
// per distinct name. Interning also makes the common case — every token in a
// file sharing one name — cost 4 bytes each instead of a pointer.
//
// Index 0 is "unknown", so a node nothing stamped degrades to no position
// rather than to the first file that happened to be interned.
#import "Foundation.xc"

class FileTable
    {
    i32 unused;
    void init(void)
        {
        unused = (i32)0;
        }

    // The id for `name`, interning it on first sight. Linear search: a
    // compilation sees tens of files, not thousands, and this runs once per
    // `#line`, not once per token.
    static u32 idFor(String* name)
        {
        if (name == 0)
            return (u32)0;
        Array* t = FileTable.table();
        for (u32 i = (u32)0; i < t.count(); i = i + (u32)1)
            if (((String*)t.get(i)).equals(name))
                return i + (u32)1;
        t.add((Object*)name);
        return t.count();
        }

    // The name for `id`, or 0 for "unknown".
    static String* name(u32 id)
        {
        if (id == (u32)0)
            return (String*)0;
        Array* t = FileTable.table();
        if (id > t.count())
            return (String*)0;
        return (String*)t.get(id - (u32)1);
        }

    static Array* table(void)
        {
        static Array* files;
        if (files == 0)
            files = new Array();
        return files;
        }
    }
