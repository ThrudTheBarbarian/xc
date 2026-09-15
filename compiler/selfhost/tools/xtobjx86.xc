// xtobjx86.xc — assemble x86-64 `.s` and write an ET_REL OBJECT.
// =================================================================
//
//   xtobjx86 <in.s>... -o <out.o>
//
// The self-hosted counterpart of `xcc-ln-x86_64 --object`, argument for
// argument, so the two can be handed the same inputs and their output files
// compared byte for byte (selfhost/tools/objx86-diff.sh).
//
// Separate compilation is the capability this unlocks: `-c` in the shipped
// driver had nothing to write an object with, so a developer using the
// compiler that ships could not compile a module at a time.
#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "X86Asm.xc"
#import "X86Link.xc"
#import "Elf64.xc"

void main(void)
    {
    String* out = (String*)0;
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
        if (a.equals(String.withCString("--object")) || a.equals(String.withCString("-c")))
            continue;
        inputs.add((Object*)a);
        }
    if (out == (String*)0 || inputs.count() == (u32)0)
        {
        Stdio.printf("usage: xtobjx86 <in.s>... -o <out.o>\n");
        Process.exit((i32)2);
        return;
        }

    String* all = new String();
    for (u32 k = (u32)0; k < inputs.count(); k = k + (u32)1)
        {
        String* p = (String*)inputs.get(k);
        String* one = Files.readText(p);
        if (one == 0)
            {
            Stdio.printf("xtobjx86: cannot read '%s'\n", p.cString());
            Process.exit((i32)1);
            return;
            }
        if (inputs.count() > (u32)1)
            one = X86Link.namespaceLocals(one, k);
        all.append(one);
        all.appendCString("\n");
        }

    X86Asm* as = new X86Asm();
    as.assemble(all);
    if (as.failed())
        {
        Stdio.printf("xtobjx86: %s\n", as.why().cString());
        Process.exit((i32)1);
        return;
        }

    Elf64* w = new Elf64();
    Data* img = w.objectFromText(as.text(), as.data(), as.symbols(),
                                 as.dataSyms(), as.globalSyms(), as.commonSyms(), as.fixups());
    if (w.failed() || img == (Data*)0)
        {
        Stdio.printf("xtobjx86: %s\n", w.failed() ? w.why().cString() : "object write failed");
        Process.exit((i32)1);
        return;
        }
    if (!Files.writeData(out, img))
        {
        Stdio.printf("xtobjx86: cannot write '%s'\n", out.cString());
        Process.exit((i32)1);
        return;
        }
    }
