// xta6502.xc — assemble 6502 source into an Atari XEX.
// =================================================================
//
//   xta6502 <file.asm> -o <out.xex> [-e entry] [-b]
//               [-code-window LO,HI] [-data-window LO,HI]
//               [-code-reg R] [-data-reg R] [-I dir]
//
// `-b` selects the banked output path. The windows and bank registers come
// from the caller — the layout is the single source of truth for them, and
// there is deliberately no default.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "Xta.xc"

// `$6000-$9FFF` — a hex range.
void parseRange(String* s, u32* lo, u32* hi)
    {
    u32 dash = s.byteIndexOf(String.withCString("-"));
    if (dash == (u32)$FFFF_FFFF)
        return;
    *lo = parseHex(s.substringBytes((u32)0, dash));
    *hi = parseHex(s.substringFromByte(dash + (u32)1));
    }

u32 parseHex(String* s0)
    {
    String* s = s0.trimmed();
    if (s.hasPrefix(String.withCString("$")))
        s = s.substringFromByte((u32)1);
    u32 v = (u32)0;
    for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
        {
        u8 c = s.byteAt(i);
        u32 d;
        if (c >= (u8)'0' && c <= (u8)'9')
            d = (u32)(c - (u8)'0');
        else if (c >= (u8)'a' && c <= (u8)'f')
            d = (u32)(c - (u8)'a') + (u32)10;
        else if (c >= (u8)'A' && c <= (u8)'F')
            d = (u32)(c - (u8)'A') + (u32)10;
        else
            break;
        v = v * (u32)16 + d;
        }
    return v;
    }

void main(void)
    {
    String* inPath = (String*)0;
    String* outPath = (String*)0;
    String* entrySym = (String*)0;
    bool banked = false;
    bool split = false;
    u32 codeLo = (u32)0;
    u32 codeHi = (u32)0;
    u32 dataLo = (u32)0;
    u32 dataHi = (u32)0;
    u32 codeReg = (u32)0;
    u32 dataReg = (u32)0;
    Array* incPaths = new Array();
    u32 argc = Process.argumentCount();
    u32 i = (u32)1;
    while (i < argc)
        {
        String* a = Process.argument(i);
        if (a.equals(String.withCString("-o")) && i + (u32)1 < argc)
            {
            outPath = Process.argument(i + (u32)1);
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-e")) && i + (u32)1 < argc)
            {
            entrySym = Process.argument(i + (u32)1);
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-b")))
            {
            banked = true;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("-split-bank")))
            {
            split = true;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("-I")) && i + (u32)1 < argc)
            {
            incPaths.add((Object*)Process.argument(i + (u32)1));
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-code-window")) && i + (u32)1 < argc)
            {
            parseRange(Process.argument(i + (u32)1), &codeLo, &codeHi);
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-data-window")) && i + (u32)1 < argc)
            {
            parseRange(Process.argument(i + (u32)1), &dataLo, &dataHi);
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-code-reg")) && i + (u32)1 < argc)
            {
            codeReg = parseHex(Process.argument(i + (u32)1));
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-data-reg")) && i + (u32)1 < argc)
            {
            dataReg = parseHex(Process.argument(i + (u32)1));
            i = i + (u32)2;
            continue;
            }
        if (!a.hasPrefix(String.withCString("-")))
            inPath = a;
        i = i + (u32)1;
        }
    if (inPath == 0 || outPath == 0)
        {
        Stdio.printf("usage: xta6502 <file.asm> -o <out.xex> [-e entry]\n");
        Process.exit((i32)2);
        return;
        }
    String* src = Files.readText(inPath);
    if (src == 0)
        {
        Stdio.printf("xta6502: cannot read '%s'\n", inPath.cString());
        Process.exit((i32)1);
        return;
        }
    Xta* a = new Xta();
    incPaths.add((Object*)String.withCString("."));
    a.setIncludePaths(incPaths);
    a.setBankRegs(codeReg, dataReg);
    if (codeHi != (u32)0)
        a.setBankWindow(codeLo, codeHi);
    if (dataHi != (u32)0)
        a.setDataWindow(dataLo, dataHi);
    a.setSplitBanking(split);
    Array* lines = a.preprocess(src, inPath);
    a.assemble(lines);
    if (a.errors().count() > (u32)0)
        {
        for (u32 k = (u32)0; k < a.errors().count(); k = k + (u32)1)
            Stdio.printf("xta6502: %s\n", ((String*)a.errors().get(k)).cString());
        Process.exit((i32)1);
        return;
        }
    u32 entry = (u32)0;
    if (entrySym != (String*)0)
        {
        Object* e = a.symbols().get((Hashable*)entrySym);
        if (e != (Object*)0)
            entry = ((Number*)e).asU32();
        }
    else if (a.segments().count() > (u32)0)
        {
        entry = ((XaSegment*)a.segments().get((u32)0)).origin();
        }
    Array* img = banked ? a.writeBankedXex(entry) : a.writeXex(entry);
    Data* d = Data.withCapacity((u32)0);
    for (u32 k = (u32)0; k < img.count(); k = k + (u32)1)
        d.appendByte((u8)((Number*)img.get(k)).asU32());
    if (!Files.writeData(outPath, d))
        {
        Stdio.printf("xta6502: cannot write '%s'\n", outPath.cString());
        Process.exit((i32)1);
        return;
        }
    }
