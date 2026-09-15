// xtasx86.xc — assemble the x86_64 back end's output, and print what it made.
// =================================================================
//
//   xtasx86 <file.s>
//
// Prints the same canonical listing `xtcln-x86_64 --dump` does — section bytes,
// symbol offsets and section, every fixup — so the two assemblers can be
// compared byte for byte. A failure goes to stderr and exits non-zero rather
// than printing a partial listing that would silently pass a diff of its own
// prefix.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"

#import "X86Asm.xc"

// printf has no zero-padded hex, and the listing's whole value is that it is
// byte-for-byte comparable, so the padding is done here.
String* hexPad(u32 v, u32 digits)
    {
    String* o = new String();
    u32 i = digits;
    while (i > (u32)0)
        {
        i = i - (u32)1;
        u32 nib = (v >> ((u32)4 * i)) & (u32)$F;
        o.appendByte(nib < (u32)10 ? (u8)((u32)'0' + nib) : (u8)((u32)'a' + nib - (u32)10));
        }
    return o;
    }

void dumpBytes(String* tag, Array* bytes)
    {
    Stdio.printf("%s %ld\n", tag.cString(), (i32)bytes.count());
    u32 i = (u32)0;
    while (i < bytes.count())
        {
        String* line = hexPad(i, (u32)8);
        line.appendCString(" ");
        u32 j = i;
        while (j < bytes.count() && j < i + (u32)16)
            {
            line.append(hexPad(((Number*)bytes.get(j)).asU32(), (u32)2));
            j = j + (u32)1;
            }
        Stdio.printf("%s\n", line.cString());
        i = i + (u32)16;
        }
    }

// The listing is in sorted symbol order, so it does not depend on how either
// implementation happens to hash its table.
Array* sortedKeys(Map* m)
    {
    Array* keys = m.allKeys();
    for (u32 i = (u32)1; i < keys.count(); i = i + (u32)1)
        {
        Object* k = keys.get(i);
        u32 j = i;
        while (j > (u32)0 && ((String*)keys.get(j - (u32)1)).compare((String*)k) > (i32)0)
            {
            keys.set(j, keys.get(j - (u32)1));
            j = j - (u32)1;
            }
        keys.set(j, k);
        }
    return keys;
    }

bool isDataSym(Array* dataSyms, String* name)
    {
    for (u32 i = (u32)0; i < dataSyms.count(); i = i + (u32)1)
        if (((String*)dataSyms.get(i)).equals(name))
            return true;
    return false;
    }

void main(void)
    {
    String* input = (String*)0;
    u32 argc = Process.argumentCount();
    for (u32 i = (u32)1; i < argc; i = i + (u32)1)
        {
        String* a = Process.argument(i);
        if (!a.hasPrefix(String.withCString("-")))
            input = a;
        }
    if (input == 0)
        {
        Stdio.printf("usage: xtasx86 <file.s>\n");
        Process.exit((i32)2);
        return;
        }
    String* text = Files.readText(input);
    if (text == 0)
        {
        Stdio.printf("xtasx86: cannot read '%s'\n", input.cString());
        Process.exit((i32)1);
        return;
        }

    X86Asm* a = new X86Asm();
    a.assemble(text);
    if (a.failed())
        {
        Stdio.printf("xtasx86: assembly failed: %s\n", a.why().cString());
        Process.exit((i32)1);
        return;
        }
    // Mirror `xcc-ln-x86_64 --dump`: a single-unit image materialises its
    // COMMON (`.comm`) tentative globals into local storage (bug 36 x-obj).
    a.demoteCommonsToLocalData();

    dumpBytes(String.withCString("text"), a.text());
    dumpBytes(String.withCString("data"), a.data());

    Array* keys = sortedKeys(a.symbols());
    Stdio.printf("symbols %ld\n", (i32)keys.count());
    for (u32 i = (u32)0; i < keys.count(); i = i + (u32)1)
        {
        String* k = (String*)keys.get(i);
        u32 off = ((Number*)a.symbols().get((Hashable*)k)).asU32();
        Stdio.printf("  %s %lu %s%s\n", k.cString(), off,
                     isDataSym(a.dataSyms(), k) ? "data" : "text",
                     isDataSym(a.globalSyms(), k) ? " globl" : "");
        }

    Array* fx = a.fixups();
    Stdio.printf("fixups %ld\n", (i32)fx.count());
    for (u32 i = (u32)0; i < fx.count(); i = i + (u32)1)
        {
        X86Fixup* f = (X86Fixup*)fx.get(i);
        Stdio.printf("  %lu %ld %s %ld\n", f.offset(), (i32)f.kind(),
                     f.symbol().cString(), f.addend());
        }
    }
