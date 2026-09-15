// xtldwin.xc — assemble x86-64 `.s` and write a Windows PE/COFF .exe.
// =================================================================
//
//   xtldwin <input.s>... -o <out.exe> [-e entry] [-import <dll>:<sym>,...]
//                                     [-importmap <file>]
//
// The self-hosted counterpart of `xtcln-win64`: no mingw, no lld-link, no
// Windows SDK. Windows has no stable syscall ABI, so unlike the Linux target
// imports are unavoidable — kernel32.dll is the floor.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "X86Asm.xc"
#import "Pe.xc"

Array* gDlls; // String@
Array* gSyms; // Array@ of String@, parallel to gDlls

u32 dllSlot(String* dll)
    {
    for (u32 i = (u32)0; i < gDlls.count(); i = i + (u32)1)
        if (((String*)gDlls.get(i)).equals(dll))
            return i;
    gDlls.add((Object*)dll);
    gSyms.add((Object*)new Array());
    return gDlls.count() - (u32)1;
    }

bool alreadyListed(String* sym)
    {
    for (u32 i = (u32)0; i < gSyms.count(); i = i + (u32)1)
        {
        Array* a = (Array*)gSyms.get(i);
        for (u32 k = (u32)0; k < a.count(); k = k + (u32)1)
            if (((String*)a.get(k)).equals(sym))
                return true;
        }
    return false;
    }

// `.L<rest>` becomes `.L<index>Z<rest>` — clang restarts its `.LBB` numbering
// per translation unit, so a plain concatenation of two generated files makes
// the first one's branches land inside the second.
String* namespaceLocals(String* s, u32 idx)
    {
    String* out = new String();
    u32 i = (u32)0;
    while (i < s.byteLength())
        {
        if (i + (u32)1 < s.byteLength() && s.byteAt(i) == (u8)'.' && s.byteAt(i + (u32)1) == (u8)'L')
            {
            out.appendCString(".L");
            out.appendFormat("%luZ", idx);
            i = i + (u32)2;
            continue;
            }
        out.appendByte(s.byteAt(i));
        i = i + (u32)1;
        }
    return out;
    }

void main(void)
    {
    gDlls = new Array();
    gSyms = new Array();
    Array* inputs = new Array();
    String* outPath = (String*)0;
    String* entry = String.withCString("_start");
    String* mapPath = (String*)0;
    u32 argc = Process.argumentCount();
    u32 i = (u32)1;
    while (i < argc)
        {
        String* a = Process.argument(i);
        if (a.equals(String.withCString("-o")) && i + (u32)1 < argc)
            {
            outPath = Process.argument(i + (u32)1);
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-e")) && i + (u32)1 < argc)
            {
            entry = Process.argument(i + (u32)1);
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-importmap")) && i + (u32)1 < argc)
            {
            mapPath = Process.argument(i + (u32)1);
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-import")) && i + (u32)1 < argc)
            {
            String* spec = Process.argument(i + (u32)1);
            u32 colon = spec.byteIndexOf(String.withCString(":"));
            if (colon != (u32)$FFFF_FFFF)
                {
                u32 slot = dllSlot(spec.substringBytes((u32)0, colon));
                Array* parts = spec.substringFromByte(colon + (u32)1).splitOnByte((u8)',');
                for (u32 k = (u32)0; k < parts.count(); k = k + (u32)1)
                    {
                    String* sym = (String*)parts.get(k);
                    if (sym.byteLength() > (u32)0)
                        ((Array*)gSyms.get(slot)).add((Object*)sym);
                    }
                }
            i = i + (u32)2;
            continue;
            }
        if (!a.hasPrefix(String.withCString("-")))
            inputs.add((Object*)a);
        i = i + (u32)1;
        }
    if (inputs.count() == (u32)0 || outPath == 0)
        {
        Stdio.printf("usage: xtldwin <input.s>... -o <out.exe> [-e entry] [-import <dll>:<sym>,...] [-importmap <file>]\n");
        Process.exit((i32)2);
        return;
        }

    // Fold the map in. Listing a symbol here does NOT put it in the output: the
    // writer emits a descriptor only for names the program actually references,
    // so the whole table costs nothing in the binary. An explicit -import wins.
    if (mapPath != (String*)0)
        {
        String* body = Files.readText(mapPath);
        if (body == 0)
            {
            Stdio.printf("xtldwin: cannot read import map '%s'\n", mapPath.cString());
            Process.exit((i32)2);
            return;
            }
        Array* lines = body.splitOnByte((u8)'\n');
        for (u32 k = (u32)0; k < lines.count(); k = k + (u32)1)
            {
            String* ln = (String*)lines.get(k);
            if (ln.byteLength() == (u32)0 || ln.hasPrefix(String.withCString("#")))
                continue;
            u32 tab = ln.byteIndexOf(String.withCString("\t"));
            if (tab == (u32)$FFFF_FFFF)
                continue;
            String* sym = ln.substringBytes((u32)0, tab);
            String* dll = ln.substringFromByte(tab + (u32)1).trimmed();
            if (sym.byteLength() == (u32)0 || dll.byteLength() == (u32)0)
                continue;
            if (alreadyListed(sym))
                continue;
            ((Array*)gSyms.get(dllSlot(dll))).add((Object*)sym);
            }
        }

    String* src = new String();
    for (u32 k = (u32)0; k < inputs.count(); k = k + (u32)1)
        {
        String* one = Files.readText((String*)inputs.get(k));
        if (one == 0)
            {
            Stdio.printf("xtldwin: cannot read '%s'\n", ((String*)inputs.get(k)).cString());
            Process.exit((i32)1);
            return;
            }
        if (inputs.count() > (u32)1)
            one = namespaceLocals(one, k);
        src.append(one);
        src.appendCString("\n");
        }

    X86Asm* a = new X86Asm();
    a.assemble(src);
    if (a.failed())
        {
        Stdio.printf("xtldwin: assembly failed: %s\n", a.why().cString());
        Process.exit((i32)1);
        return;
        }
    Pe* pe = new Pe();
    pe.executable(a.text(), a.data(), a.symbols(), a.dataSyms(), a.fixups(),
                  entry, gDlls, gSyms);
    if (pe.failed())
        {
        Stdio.printf("xtldwin: %s\n", pe.why().cString());
        Process.exit((i32)1);
        return;
        }
    Array* image = pe.bytes();
    Data* d = Data.withCapacity((u32)0);
    for (u32 k = (u32)0; k < image.count(); k = k + (u32)1)
        d.appendByte((u8)((Number*)image.get(k)).asU32());
    if (!Files.writeData(outPath, d))
        {
        Stdio.printf("xtldwin: cannot write '%s'\n", outPath.cString());
        Process.exit((i32)1);
        return;
        }
    }
