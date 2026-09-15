// xtas9.xc — assemble the back end's A32 output, and say what it could not.
// =================================================================
//
//   xtas9 <file.s> [-o out] [--raw | --shared]
//
// Writes an ELF32 relocatable object — or, with `--raw`, just the `.text`
// bytes, which is what the byte-for-byte comparison against
// `arm-none-eabi-as` uses.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "Arm32.xc"
#import "Elf32.xc"

void main(void)
    {
    String* input = (String*)0;
    String* output = (String*)0;
    bool raw = false;
    bool shared = false;
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
        if (a.equals(String.withCString("--raw")))
            {
            raw = true;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("--shared")))
            {
            shared = true;
            i = i + (u32)1;
            continue;
            }
        if (!a.hasPrefix(String.withCString("-")))
            input = a;
        i = i + (u32)1;
        }
    if (input == 0)
        {
        Stdio.printf("usage: xtas9 <file.s> [-o out.bin]\n");
        Process.exit((i32)2);
        return;
        }
    String* text = Files.readText(input);
    if (text == 0)
        {
        Stdio.printf("xtas9: cannot read '%s'\n", input.cString());
        Process.exit((i32)1);
        return;
        }

    Arm32* a = new Arm32();
    Array* bytes = a.assemble(text);
    if (a.failed())
        {
        String* list = String.withCString("");
        for (u32 k = (u32)0; k < a.missing().count(); k = k + (u32)1)
            {
            if (k > (u32)0)
                list.appendCString(" ");
            list.append((String*)a.missing().get(k));
            }
        Stdio.printf("xtas9: %s: unsupported: %s\n", input.cString(), list.cString());
        Process.exit((i32)3);
        return;
        }
    if (output == 0)
        {
        string digits = "0123456789abcdef";
        String* hex = String.withCString("");
        for (u32 k = (u32)0; k < bytes.count(); k = k + (u32)1)
            {
            u32 b = ((Number*)bytes.get(k)).asU32();
            hex.appendByte(digits[(b >> 4) & (u32)$F]);
            hex.appendByte(digits[b & (u32)$F]);
            }
        Stdio.printf("%s\n", hex.cString());
        return;
        }
    Array* payload = bytes;
    if (shared)
        {
        // Link it: the ET_DYN image the loader takes. This used to go through
        // `ElfLink`, a second writer for the same role that no differential
        // compared against the reference — so the two could drift, and the
        // shipped `-A arm9` path (which uses `Elf32.sharedObject`) and this one
        // would have produced different images from the same object.
        Elf32* w = new Elf32();
        payload = w.sharedObject(a.bytes(), a.data(), a.symbols(), a.relocations(),
                                 new Array(), (String*)0, new Array());
        if (w.failed() || payload == (Array*)0)
            {
            Stdio.printf("xtas9: %s: cannot link: %s\n", input.cString(),
                         w.failed() ? w.why().cString() : "?");
            Process.exit((i32)4);
            return;
            }
        }
    else if (!raw)
        {
        Elf32* elf = new Elf32();
        payload = elf.write(a.bytes(), a.data(), a.symbols(), a.relocations());
        }
    Data* d = Data.withCapacity((u32)0);
    for (u32 k = (u32)0; k < payload.count(); k = k + (u32)1)
        d.appendByte((u8)((Number*)payload.get(k)).asU32());
    if (!Files.writeData(output, d))
        {
        Stdio.printf("xtas9: cannot write '%s'\n", output.cString());
        Process.exit((i32)1);
        }
    }
