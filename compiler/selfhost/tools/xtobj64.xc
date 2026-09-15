// xtobj64.xc — assemble arm64 `.s` and write an MH_OBJECT.
// =================================================================
//
//   xtobj64 --object <in.s> <out.o>
//
// The self-hosted counterpart of `xcc-ln-arm64 --object`, argument for
// argument, so the two can be handed the same input and their output files
// compared byte for byte (selfhost/tools/obj64-diff.sh).
#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "Arm64Asm.xc"
#import "MachO.xc"

void main(void)
    {
    String* inPath = (String*)0;
    String* out = (String*)0;
    for (u32 i = (u32)1; i < Process.argumentCount(); i = i + (u32)1)
        {
        String* a = Process.argument(i);
        if (a.equals(String.withCString("--object")) || a.equals(String.withCString("-c")))
            continue;
        if (a.equals(String.withCString("-o")) && i + (u32)1 < Process.argumentCount())
            {
            i = i + (u32)1;
            out = Process.argument(i);
            continue;
            }
        if (inPath == (String*)0)
            inPath = a;
        else if (out == (String*)0)
            out = a;
        }
    if (inPath == (String*)0 || out == (String*)0)
        {
        Stdio.printf("usage: xtobj64 --object <in.s> <out.o>\n");
        Process.exit((i32)2);
        return;
        }
    String* src = Files.readText(inPath);
    if (src == 0)
        {
        Stdio.printf("xtobj64: cannot read '%s'\n", inPath.cString());
        Process.exit((i32)1);
        return;
        }
    Arm64Asm* as = new Arm64Asm();
    as.assemble(src);
    if (as.failed())
        {
        Stdio.printf("xtobj64: %s\n", as.why().cString());
        Process.exit((i32)1);
        return;
        }
    MachO* m = new MachO();
    Array* img = m.objectFromText(as.textBytes(), as.dataBytes(), as.symbols(),
                                  as.dataSyms(), as.fixups(), as.globals(), as.commonSyms());
    if (img == (Array*)0)
        {
        Stdio.printf("xtobj64: object write failed\n");
        Process.exit((i32)1);
        return;
        }
    Data* d = Data.withCapacity(img.count());
    for (u32 i = (u32)0; i < img.count(); i = i + (u32)1)
        d.appendByte((u8)((Number*)img.get(i)).asU32());
    if (!Files.writeData(out, d))
        {
        Stdio.printf("xtobj64: cannot write '%s'\n", out.cString());
        Process.exit((i32)1);
        return;
        }
    }
