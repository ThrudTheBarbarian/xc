// xtcgwasm.xc — IR text in, WebAssembly text (WAT) out.
// =================================================================
//
// self-hosting, wasm stage A. The self-hosted counterpart of `xcc-cg-wasm32`:
// it reads the same IR text and emits the same `.wat`, and `wasm-diff.sh`
// compares the two byte for byte at -O0 (where the optimiser is a
// pass-through, so what is being compared is the CODE GENERATOR alone).
//
//   xtcgwasm <file.ir> [-O<n>] [-o out.wat]
//
// -O<n> mirrors what `xcc-cg-wasm32 -O<n>` does: the ported Opt pipeline
// runs at the SAME level (the pipeline lives in the cg process on both
// sides), and the ported backend learns the level — at -O1+ it emits real
// structured control flow instead of the dispatch loop. Default -O0.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "Ir.xc"
#import "IrParse.xc"
#import "Opt.xc"
#import "Wasm32.xc"

void main(void)
    {
    String* input = (String*)0;
    String* output = (String*)0;
    u32 level = (u32)0;
    bool tailCalls = false;
    bool emitLib = false;
    bool linkLibs = false;
    u32 argc = Process.argumentCount();
    u32 i = (u32)1;
    while (i < argc)
        {
        String* a = Process.argument(i);
        if (a.equals(String.withCString("-o")) && i + (u32)1 < argc)
            {
            output = Process.argument(i + (u32)1);
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-O0")))
            {
            level = (u32)0;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("-O")) || a.equals(String.withCString("-O1")))
            {
            level = (u32)1;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("-O2")))
            {
            level = (u32)2;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("-O3")))
            {
            level = (u32)3;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("-x-wasm32,return-call")))
            {
            tailCalls = true;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("--emit-lib")))
            {
            emitLib = true;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("--link-libs")))
            {
            linkLibs = true;
            i = i + (u32)1;
            continue;
            }
        if (!a.hasPrefix(String.withCString("-")))
            input = a;
        i = i + (u32)1;
        }
    if (input == 0)
        {
        Stdio.printf("usage: xtcgwasm <file.ir> [-O<n>] [-o out.wat]\n");
        Process.exit((i32)2);
        return;
        }

    String* text = Files.readText(input);
    if (text == 0)
        {
        Stdio.printf("xtcgwasm: cannot read '%s'\n", input.cString());
        Process.exit((i32)1);
        return;
        }

    IrParser* p = new IrParser();
    IRModule* m = p.run(text);
    if (m == 0 || p.failed())
        {
        Stdio.printf("xtcgwasm: %s: unsupported: %s\n", input.cString(),
                     p.why() == 0 ? "?" : p.why().cString());
        Process.exit((i32)3);
        return;
        }

    // The back end has no case for the abstract VaStart/VaArg — the pipeline
    // lowers them at EVERY level, so the oracle's -O0 back end never sees one
    // either. At -O0 the ported pipeline is the same mandatory lowering (a
    // comparison of the code generators alone); at -O1+ it is the same full
    // pipeline the oracle's cg runs, so the IR entering both back ends is
    // identical (opt-diff's property) and what -O2 compares is the two
    // STRUCTURIZERS.
    Opt* opt = Opt.atLevel(level, OptProfile.forTarget(String.withCString("wasm32")));
    if (emitLib)
        opt.setKeepAllFunctions(true);
    opt.run(m);
    if (opt.failed())
        {
        Stdio.printf("xtcgwasm: %s: opt unsupported: %s\n", input.cString(),
                     opt.why() == 0 ? "?" : opt.why().cString());
        Process.exit((i32)3);
        return;
        }

    // The lowering passes just created values with no id. The back end keys
    // frame slots and local names off value ids, so they need real ones —
    // after every parsed id, in creation order, exactly as the original
    // allocates them.
    for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
        ((IRFunc*)m.funcs().get(f)).numberFreshValues();

    Wasm32* be = new Wasm32();
    be.setOptLevel(level);
    be.setTailCalls(tailCalls);
    be.setEmitLib(emitLib);
    be.setLinkLibs(linkLibs);
    String* wat = be.assembly(m);
    if (be.fatalImport())
        Process.exit((i32)1); // task #34
    if (output == 0)
        {
        Stdio.printf("%s", wat.cString());
        return;
        }
    if (!Files.writeText(output, wat))
        {
        Stdio.printf("xtcgwasm: cannot write '%s'\n", output.cString());
        Process.exit((i32)1);
        }
    }
