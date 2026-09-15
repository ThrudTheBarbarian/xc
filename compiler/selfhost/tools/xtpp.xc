// xtpp.xc — preprocess a file with the xtc preprocessor.
// =================================================================
//
// self-hosting M5. The counterpart of `xtc-fe --dump-pp`; selfhost/tools/
// pp-diff.sh runs both over the corpus and diffs the results byte for byte.
//
//   xtpp [-I dir]… [-D name[=value]]… <file.xc>
//
// Only what is on the command line is used — no implicit platform prelude, no
// automatic support/ directories — so both implementations see the same
// configuration and a difference in the output is a difference in the
// preprocessor rather than in the driver around it.
//
// Diagnostics go to stderr and set the exit status; the preprocessed text goes
// to stdout, which is what gets compared.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "MacroDef.xc"
#import "Preprocessor.xc"

void main(void)
    {
    Preprocessor* pp = new Preprocessor();
    String* input = (String*)0;

    u32 argc = Process.argumentCount();
    u32 i = (u32)1;
    while (i < argc)
        {
        String* a = Process.argument(i);
        if (a.equals(String.withCString("-I")) && i + (u32)1 < argc)
            {
            pp.addIncludePath(Process.argument(i + (u32)1));
            i = i + (u32)2;
            continue;
            }
        if (a.hasPrefix(String.withCString("-I")) && a.byteLength() > (u32)2)
            {
            pp.addIncludePath(a.substringFromByte((u32)2));
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("-D")) && i + (u32)1 < argc)
            {
            defineArg(pp, Process.argument(i + (u32)1));
            i = i + (u32)2;
            continue;
            }
        if (a.hasPrefix(String.withCString("-D")) && a.byteLength() > (u32)2)
            {
            defineArg(pp, a.substringFromByte((u32)2));
            i = i + (u32)1;
            continue;
            }
        if (!a.hasPrefix(String.withCString("-")))
            input = a;
        i = i + (u32)1;
        }

    if (input == 0)
        {
        Stdio.printf("usage: xtpp [-I dir] [-D name=value] <file.xc>\n");
        Process.exit((i32)2);
        return;
        }

    String* out = pp.preprocessFile(input);
    if (out == 0)
        {
        Stdio.printf("xtpp: cannot preprocess '%s'\n", input.cString());
        Process.exit((i32)1);
        return;
        }
    Stdio.printf("%s", out.cString());
    if (pp.errors().count() > (u32)0)
        Process.exit((i32)1);
    }

// -D name  →  name=1;  -D name=value  →  that value.
void defineArg(Preprocessor* pp, String* arg)
    {
    u32 eq = arg.indexOfByte((u8)'=');
    if (eq == String.notFound())
        {
        pp.define(arg, String.withCString("1"));
        return;
        }
    pp.define(arg.substringBytes((u32)0, eq), arg.substringFromByte(eq + (u32)1));
    }
