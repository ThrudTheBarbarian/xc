// xtld64.xc — assemble an arm64 `.s` and write a Mach-O executable.
// =================================================================
//
//   xtld64 <input.s> <output>
//
// The self-hosted counterpart of `xtcln-arm64`: no clang, no system `as`, no
// `codesign`. The input already has the runtime crt prepended by the driver, so
// the entry is `_xtc_start`, falling back to `_main` for a program built
// without it.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "U64.xc"
#import "Arm64Asm.xc"
#import "MachO.xc"

void main(void)
    {
    if (Process.argumentCount() < (u32)3)
        {
        Stdio.printf("usage: xtld64 <input.s> <output>\n");
        Process.exit((i32)2);
        return;
        }
    String* inPath = Process.argument((u32)1);
    String* outPath = Process.argument((u32)2);
    // `-platform macos|ios|ios-sim` after the two paths — same stamp flag the
    // reference linker takes (iOS.md Stage 0).
    String* platform = 0;
    for (u32 ai = (u32)3; ai + (u32)1 < Process.argumentCount(); ai = ai + (u32)1)
        {
        if (Process.argument(ai).equals(String.withCString("-platform")))
            platform = Process.argument(ai + (u32)1);
        }

    String* src = Files.readText(inPath);
    if (src == 0)
        {
        Stdio.printf("xtld64: cannot read '%s'\n", inPath.cString());
        Process.exit((i32)1);
        return;
        }

    Arm64Asm* a = new Arm64Asm();
    a.assemble(src);
    a.demoteCommonsToLocalData(); // single-unit image: give commons storage (bug 169)
    if (a.failed())
        {
        Stdio.printf("xtld64: assembly failed: %s\n", a.why().cString());
        Process.exit((i32)1);
        return;
        }

    Object* entry = a.symbols().get((Hashable*)String.withCString("_xtc_start"));
    if (entry == (Object*)0)
        entry = a.symbols().get((Hashable*)String.withCString("_main"));
    if (entry == (Object*)0)
        {
        Stdio.printf("xtld64: no entry symbol (_xtc_start / _main)\n");
        Process.exit((i32)1);
        return;
        }

    // Bug 066: place the __mod_init_func pointer array at the END of __data and
    // shift its fixups to match, so the writer can describe that tail with an
    // S_MOD_INIT_FUNC_POINTERS section. It goes last because the reference
    // linker also appends every object's and archive's data before it, and the
    // two have to agree byte for byte.
    Array* dataBytes = a.dataBytes();
    Array* fixups = a.fixups();
    u32 miLen = a.modInitBytes().count();
    if (miLen > (u32)0)
        {
        while (dataBytes.count() % (u32)8 != (u32)0)
            dataBytes.add((Object*)Number.withU32((u32)0));
        u32 base = dataBytes.count();
        for (u32 i = (u32)0; i < a.modInitBytes().count(); i = i + (u32)1)
            dataBytes.add(a.modInitBytes().get(i));
        for (u32 i = (u32)0; i < a.modInitFixups().count(); i = i + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)a.modInitFixups().get(i);
            fixups.add((Object*)Arm64Fixup.make(base + f.offset(), f.kind(),
                                                f.symbol(), f.scale()));
            }
        }

    MachO* m = new MachO();
    if (platform != 0)
        m.setApplePlatform(platform);
    m.executable(a.textBytes(), ((Number*)entry).asU32(), a.symbols(),
                 dataBytes, a.dataSyms(), fixups, miLen);

    Array* image = m.bytes();
    Data* d = Data.withCapacity((u32)0);
    for (u32 i = (u32)0; i < image.count(); i = i + (u32)1)
        d.appendByte((u8)((Number*)image.get(i)).asU32());
    if (!Files.writeData(outPath, d))
        {
        Stdio.printf("xtld64: cannot write '%s'\n", outPath.cString());
        Process.exit((i32)1);
        return;
        }
    Files.setExecutable(outPath);
    }
