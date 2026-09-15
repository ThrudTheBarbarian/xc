// xtlnwasm.xc — WAT text in, .wasm binary out.
// =================================================================
//
// self-hosting, wasm stage B. The self-hosted counterpart of
// `xcc-ln-wasm32`'s module build: it reads the WAT dialect the back end
// emits and writes the same `.wasm` bytes, and `lnwasm-diff.sh` compares
// the two byte for byte. (The .js/.html loader files the original also
// writes are host scaffolding, not part of the module — only the .wasm
// is compared, so only the .wasm is produced.)
//
//   xtlnwasm <in.wat> -o <out.wasm>

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "Wasm.xc"

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
    if (input == 0 || output == 0)
        {
        Stdio.printf("usage: xtlnwasm <in.wat> -o <out.wasm>\n");
        Process.exit((i32)2);
        return;
        }

    String* src = Files.readText(input);
    if (src == 0)
        {
        Stdio.printf("xtlnwasm: cannot read '%s'\n", input.cString());
        Process.exit((i32)1);
        return;
        }

    WasmWriter* w = new WasmWriter();
    Data* module = w.moduleFromWat(src);
    if (module == (Data*)0)
        {
        Stdio.printf("xtlnwasm: error: %s\n",
                     w.why() == 0 ? "(no detail)" : w.why().cString());
        Process.exit((i32)1);
        return;
        }

    if (!Files.writeData(output, module))
        {
        Stdio.printf("xtlnwasm: cannot write '%s'\n", output.cString());
        Process.exit((i32)1);
        return;
        }
    }
