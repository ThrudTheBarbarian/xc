// xtdylib.xc — assemble an arm64 `.s` and write a Mach-O SHARED LIBRARY.
// =================================================================
//
//   xtdylib <install-name> <iface|-> <exports|-> <input.s> <output>
//
// The self-hosted counterpart of `xcc-ln-arm64 --dylib`, argument for argument
// so the two can be handed the same inputs and their OUTPUT FILES compared
// byte for byte (selfhost/tools/lddylib-diff.sh). No clang, no system `ld`, no
// `codesign`.
//
// `exports` is one symbol name per line — the library's public surface, which
// decides both the N_EXT bit in the symbol table and the dyld export trie.
// A name that is not DEFINED here is dropped rather than exported: a trie
// entry pointing at nothing is a load-time failure in the client, a long way
// from the library that promised it.
#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "U64.xc"
#import "Arm64Asm.xc"
#import "MachO.xc"

void main(void)
    {
    if (Process.argumentCount() < (u32)6)
        {
        Stdio.printf("usage: xtdylib <install-name> <iface|-> <exports|-> "
                     "<input.s> <output>\n");
        Process.exit((i32)2);
        return;
        }
    String* installName = Process.argument((u32)1);
    String* ifacePath = Process.argument((u32)2);
    String* exportsPath = Process.argument((u32)3);
    String* inPath = Process.argument((u32)4);
    String* outPath = Process.argument((u32)5);
    String* platform = 0;
    for (u32 ai = (u32)6; ai + (u32)1 < Process.argumentCount(); ai = ai + (u32)1)
        {
        if (Process.argument(ai).equals(String.withCString("-platform")))
            platform = Process.argument(ai + (u32)1);
        }

    String* src = Files.readText(inPath);
    if (src == 0)
        {
        Stdio.printf("xtdylib: cannot read '%s'\n", inPath.cString());
        Process.exit((i32)1);
        return;
        }

    Arm64Asm* a = new Arm64Asm();
    a.assemble(src);
    a.demoteCommonsToLocalData(); // single-unit image: give commons storage (bug 169)
    if (a.failed())
        {
        Stdio.printf("xtdylib: assembly failed: %s\n", a.why().cString());
        Process.exit((i32)1);
        return;
        }

    Array* iface = new Array();
    if (!ifacePath.equals(String.withCString("-")))
        {
        Data* d = Files.readData(ifacePath);
        if (d == (Data*)0)
            {
            Stdio.printf("xtdylib: cannot read interface '%s'\n", ifacePath.cString());
            Process.exit((i32)1);
            return;
            }
        for (u32 i = (u32)0; i < d.length(); i = i + (u32)1)
            iface.add((Object*)Number.withU32((u32)d.byteAt(i)));
        }

    Array* exports = new Array();
    if (!exportsPath.equals(String.withCString("-")))
        {
        String* el = Files.readText(exportsPath);
        if (el == 0)
            {
            Stdio.printf("xtdylib: cannot read exports '%s'\n", exportsPath.cString());
            Process.exit((i32)1);
            return;
            }
        Array* lines = el.splitOnByte((u8)'\n');
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
            {
            String* s = ((String*)lines.get(i)).trimmed();
            if (s.byteLength() == (u32)0)
                continue;
            // Defined HERE, or not exported at all — see the header note.
            if (a.symbols().get((Hashable*)s) == (Object*)0)
                continue;
            exports.add((Object*)s);
            }
        }

    // Bug 066: the __mod_init_func pointer array goes at the END of __data,
    // with its fixups shifted to match, so the writer can describe that tail
    // with an S_MOD_INIT_FUNC_POINTERS section. For a LIBRARY this is the only
    // way its load-time constructors run at all — nothing can call its copy of
    // the runner.
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
    m.dylib(a.textBytes(), installName, exports, iface, a.symbols(),
            dataBytes, a.dataSyms(), fixups, miLen);

    Array* image = m.bytes();
    Data* d = Data.withCapacity((u32)0);
    for (u32 i = (u32)0; i < image.count(); i = i + (u32)1)
        d.appendByte((u8)((Number*)image.get(i)).asU32());
    if (!Files.writeData(outPath, d))
        {
        Stdio.printf("xtdylib: cannot write '%s'\n", outPath.cString());
        Process.exit((i32)1);
        return;
        }
    }
