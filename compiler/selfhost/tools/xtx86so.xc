// xtx86so.xc — assemble x86-64 `.s` and write an ET_DYN SHARED OBJECT.
// =================================================================
//
//   xtx86so [-soname NAME] [-iface FILE] [-l NEEDED]... <in.s>... -o <lib.so>
//
// The self-hosted counterpart of `xcc-ln-x86_64 -shared`, argument for
// argument, so the two can be handed the same inputs and their output files
// compared byte for byte (selfhost/tools/ldx86so-diff.sh).
//
// What the library EXPORTS is what the assembler saw declared `.globl` — the
// same rule the reference uses. Public is a property of the code, not of
// whoever ran the linker.
#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "X86Link.xc"

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
        if (a.equals(String.withCString("-l")) && i + (u32)1 < Process.argumentCount())
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
        Stdio.printf("usage: xtx86so [-soname NAME] [-iface FILE] [-l NEEDED]... "
                     "<in.s>... -o <lib.so>\n");
        Process.exit((i32)2);
        return;
        }
    // `-shared` with no soname names the output, as ld does.
    if (soname == (String*)0)
        soname = out.lastPathComponent();

    Array* srcs = new Array();
    Array* objs = new Array();
    Array* ars = new Array();
    for (u32 k = (u32)0; k < inputs.count(); k = k + (u32)1)
        {
        String* p = (String*)inputs.get(k);
        if (p.hasSuffix(String.withCString(".a")))
            {
            ars.add((Object*)p);
            continue;
            }
        if (p.hasSuffix(String.withCString(".o")))
            {
            objs.add((Object*)p);
            continue;
            }
        String* one = Files.readText(p);
        if (one == 0)
            {
            Stdio.printf("xtx86so: cannot read '%s'\n", p.cString());
            Process.exit((i32)1);
            return;
            }
        srcs.add((Object*)one);
        }

    Array* iface = new Array();
    if (ifacePath != (String*)0 && !ifacePath.equals(String.withCString("-")))
        {
        Data* d = Files.readData(ifacePath);
        if (d == (Data*)0)
            {
            Stdio.printf("xtx86so: cannot read interface '%s'\n", ifacePath.cString());
            Process.exit((i32)1);
            return;
            }
        for (u32 i = (u32)0; i < d.length(); i = i + (u32)1)
            iface.add((Object*)Number.withU32((u32)d.byteAt(i)));
        }

    X86Link* ln = new X86Link();
    Data* img = ln.linkShared(srcs, objs, ars, soname, (Array*)0, needed,
                              (String*)0, iface);
    if (ln.failed())
        {
        Stdio.printf("xtx86so: %s\n", ln.why().cString());
        Process.exit((i32)1);
        return;
        }
    if (!Files.writeData(out, img))
        {
        Stdio.printf("xtx86so: cannot write '%s'\n", out.cString());
        Process.exit((i32)1);
        return;
        }
    }
