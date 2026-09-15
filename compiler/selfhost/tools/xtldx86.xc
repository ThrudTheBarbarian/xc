// xtldx86.xc — assemble x86-64 `.s` and write a static Linux ELF.
// =================================================================
//
//   xtldx86 <input.s>... [obj.o] [lib.a] -o <output> [-e entry]
//
// The self-hosted counterpart of `xtcln-x86_64`: no clang, no ld, no Linux
// tooling anywhere in the chain.
//
// Inputs are classified by EXTENSION, as the reference does: `.a` is an
// archive (a POOL — a member joins only if it defines something still
// wanted), `.o` a relocatable object, anything else assembly.
//
// The link itself is X86Link, shared with the driver's `-A x86_64` path so
// the two cannot drift. See private:docs/Design/foreign-object-linking.md.
#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "X86Link.xc"

void main(void)
    {
    Array* inputs = new Array();
    String* outPath = (String*)0;
    String* entry = String.withCString("_start");
    u32 argc = Process.argumentCount();
    u32 i = (u32)1;
    while (i < argc)
        {
        String* a = Process.argument(i);
        if (a.equals(String.withCString("-e")) && i + (u32)1 < argc)
            {
            entry = Process.argument(i + (u32)1);
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-o")) && i + (u32)1 < argc)
            {
            outPath = Process.argument(i + (u32)1);
            i = i + (u32)2;
            continue;
            }
        if (!a.hasPrefix(String.withCString("-")))
            inputs.add((Object*)a);
        i = i + (u32)1;
        }
    if (inputs.count() == (u32)0 || outPath == 0)
        {
        Stdio.printf("usage: xtldx86 <input.s>... [obj.o] [lib.a] -o <output> [-e entry]\n");
        Process.exit((i32)2);
        return;
        }

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
            Stdio.printf("xtldx86: cannot read '%s'\n", p.cString());
            Process.exit((i32)1);
            return;
            }
        srcs.add((Object*)one);
        }
    if (srcs.count() == (u32)0)
        {
        Stdio.printf("xtldx86: no assembly input — there is nothing to link into\n");
        Process.exit((i32)2);
        return;
        }

    X86Link* ln = new X86Link();
    Data* img = ln.link(srcs, objs, ars, entry);
    if (ln.failed())
        {
        Stdio.printf("xtldx86: %s\n", ln.why().cString());
        Process.exit((i32)1);
        return;
        }
    if (!Files.writeData(outPath, img))
        {
        Stdio.printf("xtldx86: cannot write '%s'\n", outPath.cString());
        Process.exit((i32)1);
        return;
        }
    Files.setExecutable(outPath);
    }
