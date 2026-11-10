// xtcgx86.xc — IR text in, Motorola x86-64 assembly out.
// =================================================================
//
// self-hosting M15. The self-hosted counterpart of `xtcg-x86_64`: it reads the
// same IR text and emits the same `.s`, and `m68k-diff.sh` compares the two at
// -O0 (where what is being compared is the CODE GENERATOR alone).
//
//   xtcgx86 <file.ir> [-o out.s] [--win64]

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import <OptBase>
#import <Opt>
#import "OptDefs.xc"
#import <X86_64>

// At -O1 and up the input is the reference's post-opt IR, so its gpu-globals
// pass has run already, and dead-function-elim may then have taken
// __xt_gpu_globals and the par runtime's parRegisterGlobals (nothing called
// them) and left both symbols. The level-0 run here would rebuild from those
// symbols what the reference never emits: from the first, an empty
// registration function; from the second, which then looks like the
// libRuntime import, a registration function and its call at the top of main
// (a program whose loops --par-style=auto lifted). Neither symbol is live
// when no function has its name and no operand names it, and a dead one is
// dropped. Pre-opt IR (-O0) is untouched: there the runtime's parGlobals calls
// __xt_gpu_globals, or (libRuntime) there is no declaration of it. As xtcga64.
bool irSymLive(IRModule* m, String* name)
    {
    for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
        {
        IRFunc* fn = (IRFunc*)m.funcs().get(f);
        if (fn.name().equals(name))
            return true;
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 k = (u32)0; k < bb.insns().count(); k = k + (u32)1)
                {
                IRInsn* gi = (IRInsn*)bb.insns().get(k);
                for (u32 q = (u32)0; q < gi.ops().count(); q = q + (u32)1)
                    {
                    IROperand* o = (IROperand*)gi.ops().get(q);
                    if (o.kind() == (u8)OPK_SYM && o.name() != (String*)0 && o.name().equals(name))
                        return true;
                    }
                }
            }
        }
    return false;
    }

bool irDropSym(IRModule* m, String* name)
    {
    for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1)
        if (((IRSymbol*)m.syms().get(i)).name().equals(name))
            {
            m.syms().removeAt(i);
            return true;
            }
    return false;
    }

void dropDeadGpuGlobals(IRModule* m)
    {
    String* gg = String.withCString("__xt_gpu_globals");
    // Only a module whose runtime declared the function: a libRuntime one
    // (pre-opt) has the import with no declaration and no call yet, which
    // the run below must still see.
    if (irSymLive(m, gg) || !irDropSym(m, gg))
        return;
    String* hook = String.withCString("parRegisterGlobals");
    if (!irSymLive(m, hook))
        irDropSym(m, hook);
    }

void main(void)
    {
    String* input = (String*)0;
    String* output = (String*)0;
    bool win64 = false;
    // --partial writes whatever WAS emitted alongside the refusal, so progress
    // can be measured per function while opcodes are still missing. The exit
    // status stays 3, so no harness mistakes it for success.
    bool partial = false;
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
        if (a.equals(String.withCString("--win64")))
            {
            win64 = true;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("--partial")))
            {
            partial = true;
            i = i + (u32)1;
            continue;
            }
        if (!a.hasPrefix(String.withCString("-")))
            input = a;
        i = i + (u32)1;
        }
    if (input == 0)
        {
        Stdio.printf("usage: xtcgx86 <file.ir> [-o out.s]\n");
        Process.exit((i32)2);
        return;
        }

    String* text = Files.readText(input);
    if (text == 0)
        {
        Stdio.printf("xtcgx86: cannot read '%s'\n", input.cString());
        Process.exit((i32)1);
        return;
        }

    IrParser* p = new IrParser();
    IRModule* m = p.run(text);
    if (m == 0 || p.failed())
        {
        Stdio.printf("xtcgx86: %s: unsupported: %s\n", input.cString(),
                     p.why() == 0 ? "?" : p.why().cString());
        Process.exit((i32)3);
        return;
        }

    // The back end has no case for the abstract VaStart/VaArg — the pipeline
    // lowers them at EVERY level, so the oracle's -O0 back end never sees one
    // either. Running the ported pipeline at level 0 is the same mandatory
    // lowering, not an optimisation step. It must not build what the
    // reference's dead-function-elim took away (dropDeadGpuGlobals).
    dropDeadGpuGlobals(m);
    Opt* opt = Opt.atLevel((u32)0, OptProfile.forTarget(String.withCString("x86_64")));
    opt.run(m);
    if (opt.failed())
        {
        Stdio.printf("xtcgx86: %s: opt unsupported: %s\n", input.cString(),
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

    X86_64* be = new X86_64();
    be.setWin64(win64);
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
        Stdio.printf("xtcgx86: %s: unsupported: %s\n", input.cString(), list.cString());
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
        Stdio.printf("xtcgx86: cannot write '%s'\n", output.cString());
        Process.exit((i32)1);
        }
    }
