// xtirp.xc — the IR text, round-tripped.
// =================================================================
//
// self-hosting M8. Reads an `.ir` file with the ported parser and prints the
// module back out with the ported printer. Because the printer is what wrote
// the file in the first place, the output must equal the input BYTE FOR BYTE —
// so this tool IS the test, and every `.xc` in the tree supplies a case.
//
//   xtirp <file.ir> [-o <out.ir>]
//
// Exit codes: 0 round-tripped, 1 could not read or write, 3 the parser does
// not handle a shape in it (and says which).

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "Ir.xc"
#import "IrParse.xc"

void main(void)
    {
    String* input = (String*)0;
    String* output = (String*)0;
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
        if (!a.hasPrefix(String.withCString("-")))
            input = a;
        i = i + (u32)1;
        }
    if (input == 0)
        {
        Stdio.printf("usage: xtirp <file.ir> [-o out.ir]\n");
        Process.exit((i32)2);
        return;
        }

    String* text = Files.readText(input);
    if (text == 0)
        {
        Stdio.printf("xtirp: cannot read '%s'\n", input.cString());
        Process.exit((i32)1);
        return;
        }

    IrParser* p = new IrParser();
    IRModule* m = p.run(text);
    if (m == 0 || p.failed())
        {
        Stdio.printf("xtirp: %s: unsupported: %s\n", input.cString(),
                     p.why() == 0 ? "?" : p.why().cString());
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
        Stdio.printf("xtirp: cannot write '%s'\n", output.cString());
        Process.exit((i32)1);
        return;
        }
    }
