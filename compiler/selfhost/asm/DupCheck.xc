// DupCheck.xc — two objects defining one name from different sources (#663).
//
// Every in-house linker keeps the FIRST definition of a name two inputs
// define. That is right for the copies every `-c` object and split build
// carries (the standard library compiled into each module): they come from
// the same source. It is wrong when two modules each wrote a definition of
// their own: the program would silently run the first wherever the second
// was meant. The bytes cannot tell the two apart — each module compiles a
// library function with its own context — so each object records where its
// definitions came from (`<object>.xtc.origins`, sema/Origins.xc), and a link
// refuses a name two named objects define from different origins, naming the
// symbol, both objects and both origins. An object without the table (a C or
// foreign object) and an archive member keep first-wins.

#import "Foundation.xc"
#import "Files.xc"

class DupCheck
    {
    // The origins table beside an object, or null when it has none.
    static Map* originsFor(String* objPath)
        {
        if (objPath == (String*)0)
            return (Map*)0;
        String* base = objPath;
        u32 dot = String.notFound();
        for (u32 i = (u32)0; i < objPath.byteLength(); i = i + (u32)1)
            {
            u8 c = objPath.byteAt(i);
            if (c == (u8)'.')
                dot = i;
            else if (c == (u8)'/')
                dot = String.notFound();
            }
        if (dot != String.notFound())
            base = objPath.substringBytes((u32)0, dot);
        String* p = String.withString(base);
        p.appendCString(".xtc.origins");
        if (!Files.exists(p))
            return (Map*)0;
        String* t = Files.readText(p);
        if (t == (String*)0)
            return (Map*)0;
        Map* m = new Map();
        Array* lines = t.splitOnByte((u8)'\n');
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
            {
            String* l = (String*)lines.get(i);
            u32 tab = l.byteIndexOf(String.withCString("\t"));
            if (tab == String.notFound())
                continue;
            m.set((Hashable*)l.substringBytes((u32)0, tab), (Object*)l.substringFromByte(tab + (u32)1));
            }
        return m;
        }

    // A symbol's origin; Mach-O names carry one leading underscore the table
    // does not.
    static String* originOf(Map* origins, String* sym, bool machO)
        {
        if (origins == (Map*)0 || sym == (String*)0)
            return (String*)0;
        String* k = sym;
        if (machO && k.hasPrefix(String.withCString("_")))
            k = k.substringFromByte((u32)1);
        return (String*)origins.get((Hashable*)k);
        }

    // The refusal, worded the same by every linker (each adds its own prefix).
    static String* message(String* name, String* first, String* firstOrigin,
                           String* second, String* secondOrigin)
        {
        String* e = String.withCString("'");
        e.append(name);
        e.appendCString("' is defined in both '");
        e.append(first);
        e.appendCString("' (");
        e.append(firstOrigin);
        e.appendCString(") and '");
        e.append(second);
        e.appendCString("' (");
        e.append(secondOrigin);
        e.appendCString("), from different sources. A name may be defined in several "
                        "objects only when every copy comes from the same source; rename one, "
                        "or keep one definition and declare it in the other module");
        return e;
        }
    }
