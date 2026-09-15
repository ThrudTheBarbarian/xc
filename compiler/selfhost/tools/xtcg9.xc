// xtcg9.xc — IR text in, ARMv7-A assembly out.
// =================================================================
//
// self-hosting M8. The self-hosted counterpart of `xtcg-arm9`: it reads the
// same IR text and emits the same `.s`, and `a9-diff.sh` compares the two byte
// for byte at -O0 (where the optimiser is a pass-through, so what is being
// compared is the CODE GENERATOR alone).
//
//   xtcg9 <file.ir> [-o out.s]

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "Ir.xc"
#import "IrParse.xc"
#import "Arm9.xc"

void main(void)
    {
    String* input = (String*)0;
    String* output = (String*)0;
    // --emit-lib / --object: every function this module defines is part of its
    // surface, so it keeps DEFAULT visibility. Same two spellings the reference
    // `xcc-cg-arm9` takes, and the same meaning.
    bool emitLib = false;
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
        if (a.equals(String.withCString("--emit-lib")) || a.equals(String.withCString("--object")))
            {
            emitLib = true;
            i = i + (u32)1;
            continue;
            }
        if (!a.hasPrefix(String.withCString("-")))
            input = a;
        i = i + (u32)1;
        }
    if (input == 0)
        {
        Stdio.printf("usage: xtcg9 <file.ir> [-o out.s]\n");
        Process.exit((i32)2);
        return;
        }

    String* text = Files.readText(input);
    if (text == 0)
        {
        Stdio.printf("xtcg9: cannot read '%s'\n", input.cString());
        Process.exit((i32)1);
        return;
        }

    IrParser* p = new IrParser();
    IRModule* m = p.run(text);
    if (m == 0 || p.failed())
        {
        Stdio.printf("xtcg9: %s: unsupported: %s\n", input.cString(),
                     p.why() == 0 ? "?" : p.why().cString());
        Process.exit((i32)3);
        return;
        }

    Arm9* be = new Arm9();
    be.setEmitLib(emitLib);
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
        Stdio.printf("xtcg9: %s: unsupported: %s\n", input.cString(), list.cString());
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
        Stdio.printf("xtcg9: cannot write '%s'\n", output.cString());
        Process.exit((i32)1);
        }
    }
