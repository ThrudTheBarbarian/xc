// xtfe — the self-hosted front end: source in, IR text out.
// =================================================================
//
//   xtfe [-m target] [-I dir] [-D k=v] <file.xc> -o <out.ir>
//
// The pipeline itself lives in selfhost/driver/Frontend.xc, shared with `xcc`.
// What stays here is this tool's own command line and the one thing it does
// with the result: print the IR.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "Frontend.xc"

void main(void)
    {
    FeOptions* o = parseArgs();
    if (o == 0)
        {
        Process.exit((i32)2);
        return;
        }
    if (o.input() == 0)
        {
        Stdio.printf("usage: xtfe [-m target] [-I dir] [-D k=v] <file.xc> -o <out.ir>\n");
        Process.exit((i32)2);
        return;
        }

    IRModule* mod = Frontend.lower(o);
    if (mod == 0)
        {
        Process.exit((i32)3);
        return;
        }

    String* text = mod.text();
    if (o.output() == 0)
        {
        Stdio.printf("%s", text.cString());
        return;
        }
    if (!Files.writeText(o.output(), text))
        {
        Stdio.printf("xtfe: error: cannot write '%s'\n", o.output().cString());
        Process.exit((i32)1);
        return;
        }
    }

FeOptions* parseArgs(void)
    {
    FeOptions* o = new FeOptions();
    u32 argc = Process.argumentCount();
    u32 i = (u32)1;
    while (i < argc)
        {
        String* a = Process.argument(i);
        if (a.equals(String.withCString("-o")) && i + (u32)1 < argc)
            {
            o.setOutput(Process.argument(i + (u32)1));
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-m")) && i + (u32)1 < argc)
            {
            o.setTarget(Process.argument(i + (u32)1));
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-H")) && i + (u32)1 < argc)
            {
            o.setHome(Process.argument(i + (u32)1));
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-I")) && i + (u32)1 < argc)
            {
            o.incs().add((Object*)Process.argument(i + (u32)1));
            i = i + (u32)2;
            continue;
            }
        if (a.hasPrefix(String.withCString("-I")) && a.byteLength() > (u32)2)
            {
            o.incs().add((Object*)a.substringFromByte((u32)2));
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("-D")) && i + (u32)1 < argc)
            {
            o.defs().add((Object*)Process.argument(i + (u32)1));
            i = i + (u32)2;
            continue;
            }
        if (a.hasPrefix(String.withCString("-D")) && a.byteLength() > (u32)2)
            {
            o.defs().add((Object*)a.substringFromByte((u32)2));
            i = i + (u32)1;
            continue;
            }
        // -L names a directory `#import <lib>` resolves against. A bare
        // `.xtc.iface` side file (as `xcc -c` leaves) is READ — stage 3 of
        // separate-compilation, ported; a binary `.dylib`/`.so` still refuses
        // loudly below (the port has no Mach-O/ELF section readers).
        if (a.equals(String.withCString("-L")) && i + (u32)1 < argc)
            {
            o.libs().add((Object*)Process.argument(i + (u32)1));
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-V")))
            {
            o.setVerbose(true);
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("-q")))
            {
            i = i + (u32)1;
            continue;
            }
        if (a.hasPrefix(String.withCString("-farc")))
            {
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("--emit-lib")))
            {
            Stdio.printf("xtfe: error: --emit-lib is not supported yet\n");
            return (FeOptions*)0;
            }
        if (!a.hasPrefix(String.withCString("-")))
            o.setInput(a);
        i = i + (u32)1;
        }
    return o;
    }

// The library tree a target reads from. `-m` names the TARGET; several of them
// share one platform directory, and a 6502 memory model names its own.