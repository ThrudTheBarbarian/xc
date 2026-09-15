// xta9so.xc — assemble ARM32 `.s` and write an ET_DYN SHARED OBJECT.
// =================================================================
//
//   xta9so [-soname NAME] [-iface FILE] [-needed L]... <in.s>... -o <lib.so>
//
// The self-hosted counterpart of `xcc-ln-arm9 --shared`, argument for argument,
// so the two can be handed the same inputs and their output files compared byte
// for byte (selfhost/tools/ldarm9-diff.sh).
//
// This is what takes the arm9 link in-house: before it, `-A arm9` in the
// shipped compiler had nothing to hand the assembled code to, and the port
// refused the target. There is no arm-none-eabi-ld in this path and no C
// compiler behind it — the assembler encodes, `Elf32.sharedObject` lays the
// image out, and the XTOS loader takes it from there.
//
// `.o` and `.a` inputs are REFUSED rather than quietly dropped: the reference
// merges them and this does not yet, and a linker that silently ignores an
// input produces an image that links and crashes.
#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "Arm32.xc"
#import "Elf32.xc"

// `.L<rest>` becomes `.L<index>Z<rest>`, so two separately compiled files
// cannot collide on `.L0` — a compiler restarts its numbering per file.
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
    String* out = (String*)0;
    String* soname = (String*)0;
    String* ifacePath = (String*)0;
    Array* needed = new Array();
    Array* inputs = new Array();
    for (u32 i = (u32)1; i < Process.argumentCount(); i = i + (u32)1)
        {
        String* a = Process.argument(i);
        if (a.equals(String.withCString("-o")) && i + (u32)1 < Process.argumentCount())
            {
            i = i + (u32)1;
            out = Process.argument(i);
            continue;
            }
        if (a.equals(String.withCString("-soname")) && i + (u32)1 < Process.argumentCount())
            {
            i = i + (u32)1;
            soname = Process.argument(i);
            continue;
            }
        if (a.equals(String.withCString("-iface")) && i + (u32)1 < Process.argumentCount())
            {
            i = i + (u32)1;
            ifacePath = Process.argument(i);
            continue;
            }
        if (a.equals(String.withCString("-needed")) && i + (u32)1 < Process.argumentCount())
            {
            i = i + (u32)1;
            needed.add((Object*)Process.argument(i));
            continue;
            }
        if (a.equals(String.withCString("-shared")) || a.equals(String.withCString("--shared")))
            continue;
        inputs.add((Object*)a);
        }
    if (out == (String*)0 || inputs.count() == (u32)0)
        {
        Stdio.printf("usage: xta9so [-soname NAME] [-iface FILE] [-needed L]... "
                     "<in.s>... -o <lib.so>\n");
        Process.exit((i32)2);
        return;
        }

    String* all = new String();
    for (u32 k = (u32)0; k < inputs.count(); k = k + (u32)1)
        {
        String* p = (String*)inputs.get(k);
        if (p.hasSuffix(String.withCString(".o")) || p.hasSuffix(String.withCString(".a")))
            {
            Stdio.printf("xta9so: '%s': merging objects and archives is not "
                         "implemented here yet — pass the assembly\n",
                         p.cString());
            Process.exit((i32)1);
            return;
            }
        String* one = Files.readText(p);
        if (one == 0)
            {
            Stdio.printf("xta9so: cannot read '%s'\n", p.cString());
            Process.exit((i32)1);
            return;
            }
        if (inputs.count() > (u32)1)
            one = namespaceLocals(one, k);
        all.append(one);
        all.appendCString("\n");
        }

    Arm32* as = new Arm32();
    Array* text = as.assemble(all);
    if (as.failed())
        {
        // An unsupported mnemonic is NAMED, not counted: the point of the
        // message is to say what to implement.
        Stdio.printf("xta9so: %s\n", as.why().cString());
        Process.exit((i32)1);
        return;
        }

    Array* iface = new Array();
    if (ifacePath != (String*)0 && !ifacePath.equals(String.withCString("-")))
        {
        Data* d = Files.readData(ifacePath);
        if (d == (Data*)0)
            {
            Stdio.printf("xta9so: cannot read interface '%s'\n", ifacePath.cString());
            Process.exit((i32)1);
            return;
            }
        for (u32 i = (u32)0; i < d.length(); i = i + (u32)1)
            iface.add((Object*)Number.withU32((u32)d.byteAt(i)));
        }

    Elf32* w = new Elf32();
    Array* img = w.sharedObject(text, as.data(), as.symbols(), as.relocations(),
                                needed, soname, iface);
    if (w.failed() || img == (Array*)0)
        {
        Stdio.printf("xta9so: %s\n", w.failed() ? w.why().cString() : "link failed");
        Process.exit((i32)1);
        return;
        }
    Data* d = Data.withCapacity(img.count());
    for (u32 i = (u32)0; i < img.count(); i = i + (u32)1)
        d.appendByte((u8)((Number*)img.get(i)).asU32());
    if (!Files.writeData(out, d))
        {
        Stdio.printf("xta9so: cannot write '%s'\n", out.cString());
        Process.exit((i32)1);
        return;
        }
    }
