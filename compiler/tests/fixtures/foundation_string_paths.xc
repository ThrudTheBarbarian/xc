//xtc-na: xt6502 — the 6502 String has no path methods
// foundation_string_paths.xc — String's path components, joining, absolute
// test and lexical normalisation, beside the existing last-component and
// extension methods.
#import "Foundation.xc"

void show(u8* path)
    {
    String* p = String.withCString(path);
    Array* parts = p.pathComponents();
    Stdio.printf("%-22s abs=%d n=%d [", path, (i32)(p.isAbsolutePath() ? 1 : 0), (i32)parts.count());
    for (u32 i = (u32)0; i < parts.count(); i++)
        Stdio.printf(i > (u32)0 ? "|%@" : "%@", parts.get(i));
    Stdio.printf("] norm=\"%@\" rejoin=\"%@\" last=\"%@\" ext=\"%@\"\n",
                 p.normalizedPath(), String.pathWithComponents(parts),
                 p.lastPathComponent(), p.pathExtension());
    }

i32 main(void)
    {
    show("/usr/lib/libc.a");
    show("/usr//lib/");
    show("a/b/../c/./d.txt");
    show("../../x");
    show("a/..");
    show("a/../..");
    show("/..");
    show("/a/../../b");
    show("./");
    show("/");
    show("");
    show(".bashrc");
    return (i32)0;
    }
