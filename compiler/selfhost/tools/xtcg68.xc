// xtcg68.xc — IR text in, Motorola 68000/68030 assembly out.
// =================================================================
//
// self-hosting M15. The self-hosted counterpart of `xtcg-68k`: it reads the
// same IR text and emits the same `.s`, and `m68k-diff.sh` compares the two at
// -O0 (where what is being compared is the CODE GENERATOR alone).
//
//   xtcg68 <file.ir> [-o out.s] [--cpu 68000|68030] [--hard-float] [--pic]

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "Ir.xc"
#import "IrParse.xc"
#import "Opt.xc"
#import "M68k.xc"

void main(void)
    {
    String* input = (String*)0;
    String* output = (String*)0;
    u32 cpu = (u32)68000;
    bool hardFloat = false;
    bool pic = false;
    // --partial writes whatever WAS emitted alongside the refusal, so progress
    // can be measured per function while opcodes are still missing. The exit
    // status stays 3, so no harness mistakes it for success.
    bool partial = false;
    bool dumpHomes = false;
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
        if (a.equals(String.withCString("--cpu")) && i + (u32)1 < argc)
            {
            String* v = Process.argument(i + (u32)1);
            cpu = (u32)0;
            for (u32 k = (u32)0; k < v.byteLength(); k = k + (u32)1)
                cpu = cpu * (u32)10 + (u32)(v.byteAt(k) - (u8)'0');
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("--hard-float")))
            {
            hardFloat = true;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("--pic")))
            {
            pic = true;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("--partial")))
            {
            partial = true;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("--dump-homes")))
            {
            dumpHomes = true;
            i = i + (u32)1;
            continue;
            }
        if (!a.hasPrefix(String.withCString("-")))
            input = a;
        i = i + (u32)1;
        }
    if (input == 0)
        {
        Stdio.printf("usage: xtcg68 <file.ir> [-o out.s]\n");
        Process.exit((i32)2);
        return;
        }

    String* text = Files.readText(input);
    if (text == 0)
        {
        Stdio.printf("xtcg68: cannot read '%s'\n", input.cString());
        Process.exit((i32)1);
        return;
        }

    IrParser* p = new IrParser();
    IRModule* m = p.run(text);
    if (m == 0 || p.failed())
        {
        Stdio.printf("xtcg68: %s: unsupported: %s\n", input.cString(),
                     p.why() == 0 ? "?" : p.why().cString());
        Process.exit((i32)3);
        return;
        }

    // The back end has no case for the abstract VaStart/VaArg — the pipeline
    // lowers them at EVERY level, so the oracle's -O0 back end never sees one
    // either. Running the ported pipeline at level 0 is the same mandatory
    // lowering, not an optimisation step.
    Opt* opt = Opt.atLevel((u32)0, OptProfile.forTarget(String.withCString("atarist")));
    opt.run(m);
    if (opt.failed())
        {
        Stdio.printf("xtcg68: %s: opt unsupported: %s\n", input.cString(),
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

    M68k* be = new M68k();
    be.setCpu(cpu);
    be.setHardFloat(hardFloat);
    be.setPic(pic);
    be.setDumpHomes(dumpHomes);
    String* asmText = be.assembly(m);
    if (be.failed())
        {
        String* list = String.withCString("");
        for (u32 k = (u32)0; k < be.missing().count(); k = k + (u32)1)
            {
            if (k > (u32)0)
                list.appendCString(" ");
            list.append((String*)be.missing().get(k));
            }
        Stdio.printf("xtcg68: %s: unsupported: %s\n", input.cString(), list.cString());
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
        Stdio.printf("xtcg68: cannot write '%s'\n", output.cString());
        Process.exit((i32)1);
        }
    }
