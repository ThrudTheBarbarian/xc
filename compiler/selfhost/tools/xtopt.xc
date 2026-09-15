// xtopt.xc — run the ported IR optimiser over IR text.
// =================================================================
//
//   xtopt <in.ir> -m <target> -O<n> [--stop-after <pass>] [-o out.ir]
//
// The mirror of `xtcg-<arch> -O<n> --dump-opt-ir`, and compared against it by
// `selfhost/tools/opt-diff.sh`. A pass the port does not have yet exits 3 and
// names it, so an unported pass never masquerades as a clean diff.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "Ir.xc"
#import "IrParse.xc"
#import "Opt.xc"

void main(void)
    {
    String* input = (String*)0;
    String* output = (String*)0;
    String* target = String.withCString("arm64");
    String* stopAfter = (String*)0;
    u32 level = (u32)0;
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
        if (a.equals(String.withCString("-m")) && i + (u32)1 < argc)
            {
            target = Process.argument(i + (u32)1);
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("--stop-after")) && i + (u32)1 < argc)
            {
            stopAfter = Process.argument(i + (u32)1);
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-O0")))
            {
            level = (u32)0;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("-O1")) || a.equals(String.withCString("-O")))
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
        if (!a.hasPrefix(String.withCString("-")))
            input = a;
        i = i + (u32)1;
        }
    if (input == 0)
        {
        Stdio.printf("usage: xtopt <in.ir> -m <target> -O<n> [-o out.ir]\n");
        Process.exit((i32)2);
        return;
        }
    String* text = Files.readText(input);
    if (text == 0)
        {
        Stdio.printf("xtopt: cannot read '%s'\n", input.cString());
        Process.exit((i32)1);
        return;
        }

    IrParser* p = new IrParser();
    IRModule* m = p.run(text);
    if (m == 0 || p.failed())
        {
        Stdio.printf("xtopt: %s: unsupported: %s\n", input.cString(),
                     p.why() == 0 ? "?" : p.why().cString());
        Process.exit((i32)3);
        return;
        }

    Opt* o = Opt.atLevel(level, OptProfile.forTarget(target));
    if (stopAfter != 0)
        o.setStopAfter(stopAfter);
    o.run(m);
    if (o.failed())
        {
        Stdio.printf("xtopt: %s: unsupported: %s\n", input.cString(),
                     o.why() == 0 ? "?" : o.why().cString());
        Process.exit((i32)3);
        return;
        }

    String* out = m.text();
    if (output == 0)
        {
        Stdio.printf("%s", out.cString());
        return;
        }
    if (!Files.writeText(output, out))
        {
        Stdio.printf("xtopt: cannot write '%s'\n", output.cString());
        Process.exit((i32)1);
        }
    }
