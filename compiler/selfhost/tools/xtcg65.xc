// xtcg65.xc — IR text in, banked 6502 assembly out.
// =================================================================
//
// self-hosting M17. The self-hosted counterpart of `xtcg-6502`: it reads the
// same IR text and the same `.lnk` layout, and emits the same assembly.
// `selfhost/tools/x65-diff.sh` compares the two at -O0, where what is being
// compared is the CODE GENERATOR alone.
//
//   xtcg65 <file.ir> -L <layout.lnk> [-o out.s]
//          [-Q rts|loop] [--xtc-stack] [-Fmb <n>] [-dp]
//
// The last four are xcc-cg-6502's, so a differential can compare the two with
// any of them set: the quit style, the --xtc-stack default, the -Fmb
// threshold, and the -dp placement report (on stderr).

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "Ir.xc"
#import "IrParse.xc"
#import "Opt.xc"
#import "Layout.xc"
#import "Xt6502.xc"
#import "Runtime6502.xc"

void main(void)
    {
    String* input = (String*)0;
    String* output = (String*)0;
    String* layoutPath = (String*)0;
    bool partial = false;
    String* wrapRoot = (String*)0;
    bool quitLoop = false;
    bool xtcStack = false;
    u32 fnMinBanked = (u32)0;
    bool dumpPlacement = false;
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
        if (a.equals(String.withCString("-L")) && i + (u32)1 < argc)
            {
            layoutPath = Process.argument(i + (u32)1);
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("--partial")))
            {
            partial = true;
            i = i + (u32)1;
            continue;
            }
        // --wrap <support-root>: also run the runtime wrap (lazy link) over the
        // generated text, so the output is the WHOLE thing the reference's
        // xcc-cg-6502 writes rather than just the back end's share of it.
        // x65-diff strips the wrap off the oracle to compare the halves it can;
        // this is what lets the other half be compared too.
        if (a.equals(String.withCString("--wrap")) && i + (u32)1 < argc)
            {
            wrapRoot = Process.argument(i + (u32)1);
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-Q")) && i + (u32)1 < argc)
            {
            quitLoop = Process.argument(i + (u32)1).equals(String.withCString("loop"));
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("--xtc-stack")))
            {
            xtcStack = true;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("-Fmb")) && i + (u32)1 < argc)
            {
            String* v = Process.argument(i + (u32)1);
            u32 n = (u32)0;
            for (u32 k = (u32)0; k < v.byteLength(); k = k + (u32)1)
                n = n * (u32)10 + (u32)(v.byteAt(k) - (u8)'0');
            fnMinBanked = n;
            i = i + (u32)2;
            continue;
            }
        if (a.equals(String.withCString("-dp")))
            {
            dumpPlacement = true;
            i = i + (u32)1;
            continue;
            }
        if (!a.hasPrefix(String.withCString("-")))
            input = a;
        i = i + (u32)1;
        }
    if (input == 0 || layoutPath == 0)
        {
        Stdio.printf("usage: xtcg65 <file.ir> -L <layout.lnk> [-o out.s]\n");
        Process.exit((i32)2);
        return;
        }

    Layout* layout = Layout.read(layoutPath);
    if (layout.failed())
        {
        Stdio.printf("xtcg65: %s: %s\n", layoutPath.cString(), layout.why().cString());
        Process.exit((i32)1);
        return;
        }
    // The model's NAME is its layout file's stem, which the emitted header
    // comment carries.
    layout.setName(stemOf(layoutPath));

    String* text = Files.readText(input);
    if (text == 0)
        {
        Stdio.printf("xtcg65: cannot read '%s'\n", input.cString());
        Process.exit((i32)1);
        return;
        }

    IrParser* p = new IrParser();
    IRModule* m = p.run(text);
    if (m == 0 || p.failed())
        {
        Stdio.printf("xtcg65: %s: unsupported: %s\n", input.cString(),
                     p.why() == 0 ? "?" : p.why().cString());
        Process.exit((i32)3);
        return;
        }

    Opt* opt = Opt.atLevel((u32)0, OptProfile.forTarget(String.withCString("xt6502")));
    opt.run(m);
    if (opt.failed())
        {
        Stdio.printf("xtcg65: %s: opt unsupported: %s\n", input.cString(),
                     opt.why() == 0 ? "?" : opt.why().cString());
        Process.exit((i32)3);
        return;
        }
    // The lowering passes just made values with no id; a back end keys slots
    // off value ids, so they need real ones.
    for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
        ((IRFunc*)m.funcs().get(f)).numberFreshValues();

    Xt6502* be = new Xt6502();
    be.setLayout(layout);
    be.setXtcStackDefault(xtcStack);
    be.setFnMinBanked(fnMinBanked);
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
        Stdio.printf("xtcg65: %s: unsupported: %s\n", input.cString(), list.cString());
        if (partial && output != 0)
            Files.writeText(output, asmText);
        Process.exit((i32)3);
        return;
        }
    // `_main` becomes `_xt_main` so the harness's startup JSR resolves. The
    // DRIVER does this, not the back end — it is a rename over the finished
    // text, on whole-word boundaries so `_main_loop` is left alone.
    if (dumpPlacement)
        Stdio.error(be.placementReport());
    asmText = renameMain(asmText);
    if (wrapRoot != (String*)0)
        {
        asmText = Runtime6502.wrapQuit(asmText, m, layout, wrapRoot,
                                       String.withCString("xt6502/runtime/xt6502-harness.asm"),
                                       quitLoop);
        }
    if (output == 0)
        {
        Stdio.printf("%s", asmText.cString());
        return;
        }
    if (!Files.writeText(output, asmText))
        {
        Stdio.printf("xtcg65: cannot write '%s'\n", output.cString());
        Process.exit((i32)1);
        }
    }

String* renameMain(String* text)
    {
    String* from = String.withCString("_main");
    String* out = String.withCString("");
    u32 i = (u32)0;
    while (i < text.byteLength())
        {
        u32 at = text.byteIndexOf(from, i);
        if (at == (u32)$FFFF_FFFF)
            {
            out.append(text.substringFromByte(i));
            break;
            }
        u32 e = at + from.byteLength();
        // A whole word on BOTH sides: `_main` is a match, `_main__bb_entry`
        // and `_xt_main` are not.
        u8 before = at > (u32)0 ? text.byteAt(at - (u32)1) : (u8)' ';
        u8 after = e < text.byteLength() ? text.byteAt(e) : (u8)' ';
        out.append(text.substringBytes(i, at - i));
        if (!isWordByte(before) && !isWordByte(after))
            out.appendCString("_xt_main");
        else
            out.append(from);
        i = e;
        }
    return out;
    }

bool isWordByte(u8 c)
    {
    return (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'0' && c <= (u8)'9') || c == (u8)'_';
    }

// The file's stem: everything after the last `/` and before the last `.`.
String* stemOf(String* path)
    {
    u32 start = (u32)0;
    for (u32 i = (u32)0; i < path.byteLength(); i = i + (u32)1)
        if (path.byteAt(i) == (u8)'/')
            start = i + (u32)1;
    u32 end = path.byteLength();
    for (u32 i = start; i < path.byteLength(); i = i + (u32)1)
        if (path.byteAt(i) == (u8)'.')
            end = i;
    return path.substringBytes(start, end - start);
    }
