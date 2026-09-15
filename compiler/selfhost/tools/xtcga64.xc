// xtcga64.xc — IR text in, AArch64 assembly out.
// =================================================================
//
// self-hosting M14. The self-hosted counterpart of `xtcg-arm64`: it reads the
// same IR text and emits the same `.s`, and `a9-diff.sh` compares the two byte
// for byte at -O0 (where the optimiser is a pass-through, so what is being
// compared is the CODE GENERATOR alone).
//
//   xtcga64 <file.ir> [-o out.s]

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "Ir.xc"
#import "IrParse.xc"
#import "Opt.xc"
#import "Arm64.xc"

void main(void)
    {
    String* input = (String*)0;
    String* output = (String*)0;
    // --dump-homes prints the register-homing decision instead of assembly, so
    // the allocator can be checked against the oracle's register choices
    // before a single emitter exists.
    bool dumpHomes = false;
    // --partial writes whatever WAS emitted alongside the refusal, so a
    // function-by-function diff can measure progress while opcodes are still
    // missing. The exit status stays 3, so no harness mistakes it for success.
    bool partial = false;
    bool aapcs64 = false;
    bool lse = true;
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
        if (a.equals(String.withCString("--dump-homes")))
            {
            dumpHomes = true;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("--partial")))
            {
            partial = true;
            i = i + (u32)1;
            continue;
            }
        // The two Android codegen options, spelled as the reference spells
        // them so one harness can drive both.
        if (a.equals(String.withCString("--aapcs64-abi")))
            {
            aapcs64 = true;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("--no-lse-atomics")))
            {
            lse = false;
            i = i + (u32)1;
            continue;
            }
        if (!a.hasPrefix(String.withCString("-")))
            input = a;
        i = i + (u32)1;
        }
    if (input == 0)
        {
        Stdio.printf("usage: xtcga64 <file.ir> [-o out.s]\n");
        Process.exit((i32)2);
        return;
        }

    String* text = Files.readText(input);
    if (text == 0)
        {
        Stdio.printf("xtcga64: cannot read '%s'\n", input.cString());
        Process.exit((i32)1);
        return;
        }

    IrParser* p = new IrParser();
    IRModule* m = p.run(text);
    if (m == 0 || p.failed())
        {
        Stdio.printf("xtcga64: %s: unsupported: %s\n", input.cString(),
                     p.why() == 0 ? "?" : p.why().cString());
        Process.exit((i32)3);
        return;
        }

    // The back end has no case for the abstract VaStart/VaArg — the pipeline
    // lowers them at EVERY level, so the oracle's -O0 back end never sees one
    // either. Running the ported pipeline at level 0 is therefore not an
    // optimisation step, it is the same mandatory lowering, and it is what
    // makes this a comparison of the code generators alone.
    Opt* opt = Opt.atLevel((u32)0, OptProfile.forTarget(String.withCString("arm64")));
    opt.run(m);
    if (opt.failed())
        {
        Stdio.printf("xtcga64: %s: opt unsupported: %s\n", input.cString(),
                     opt.why() == 0 ? "?" : opt.why().cString());
        Process.exit((i32)3);
        return;
        }

    // The lowering passes just created values with no id. A back end keys
    // frame slots and register homing off value ids, so they need real ones —
    // after every parsed id, in creation order, exactly as the original
    // allocates them.
    for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
        ((IRFunc*)m.funcs().get(f)).numberFreshValues();

    Arm64* be = new Arm64();
    be.setAapcs64Abi(aapcs64);
    be.setLseAtomics(lse);
    if (dumpHomes)
        {
        be.dumpHomes(m);
        return;
        }
    String* asmText = be.assembly(m);
    if (be.failed())
        {
        // Loud, and every distinct opcode named — a back end that quietly
        // skipped an instruction emits code that assembles and is wrong.
        String* list = String.withCString("");
        for (u32 k = (u32)0; k < be.missing().count(); k = k + (u32)1)
            {
            if (k > (u32)0)
                list.appendCString(" ");
            list.append((String*)be.missing().get(k));
            }
        Stdio.printf("xtcga64: %s: unsupported: %s\n", input.cString(), list.cString());
        if (partial && output != 0)
            Files.writeText(output, asmText);
        Process.exit((i32)3);
        return;
        }
    if (output == 0)
        {
        Stdio.printf("%s", asmText.cString());
        return;
        }
    if (!Files.writeText(output, asmText))
        {
        Stdio.printf("xtcga64: cannot write '%s'\n", output.cString());
        Process.exit((i32)1);
        }
    }
