// xtas68.xc — assemble the m68k back end's output into a GEMDOS $601A image.
// =================================================================
//
//   xtas68 <file.s> <out.prg> [-A 68030] [-mpic]

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "M68kAsm.xc"

void main(void)
    {
    String* inPath = (String*)0;
    String* outPath = (String*)0;
    u32 cpu = (u32)68000;
    bool pic = false;
    u32 argc = Process.argumentCount();
    u32 i = (u32)1;
    while (i < argc)
        {
        String* a = Process.argument(i);
        if (a.equals(String.withCString("-A")) && i + (u32)1 < argc)
            {
            String* v = Process.argument(i + (u32)1);
            if (v.byteIndexOf(String.withCString("68030")) != (u32)$FFFF_FFFF)
                cpu = (u32)68030;
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-mpic")))
            {
            pic = true;
            i = i + (u32)1;
            continue;
            }
        if (!a.hasPrefix(String.withCString("-")))
            {
            if (inPath == (String*)0)
                inPath = a;
            else if (outPath == (String*)0)
                outPath = a;
            }
        i = i + (u32)1;
        }
    if (inPath == 0 || outPath == 0)
        {
        Stdio.printf("usage: xtas68 <file.s> <out.prg> [-A 68030] [-mpic]\n");
        Process.exit((i32)2);
        return;
        }
    String* src = Files.readText(inPath);
    if (src == 0)
        {
        Stdio.printf("xtas68: cannot read '%s'\n", inPath.cString());
        Process.exit((i32)1);
        return;
        }
    M68kAsm* a = new M68kAsm();
    a.setCpu(cpu);
    a.setPic(pic);
    a.assemble(src);
    if (a.failed())
        {
        Stdio.printf("xtas68: %s\n", a.why().cString());
        Process.exit((i32)1);
        return;
        }
    Array* image = a.image();
    Data* d = Data.withCapacity((u32)0);
    for (u32 k = (u32)0; k < image.count(); k = k + (u32)1)
        d.appendByte((u8)((Number*)image.get(k)).asU32());
    if (!Files.writeData(outPath, d))
        {
        Stdio.printf("xtas68: cannot write '%s'\n", outPath.cString());
        Process.exit((i32)1);
        return;
        }
    }
