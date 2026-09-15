// xtir.xc — run the ported front end all the way to IR text.
// =================================================================
//
// self-hosting M6. The counterpart of `xtc-fe --dump-sema`;
// selfhost/tools/sema-diff.sh runs both and diffs the annotated trees. The
// parser-only counterpart is xtast.xc, and both print through AstDump so the
// two formats cannot drift.
//
//   xtsema [-I dir]… [-D name=value]… [--raw] <file.xc>
//
// The file is preprocessed with the xtc preprocessor (Task #820) unless --raw
// is given, then lexed with the xtc lexer (Task #818) and parsed with the xtc
// parser. All three modules are the ported ones — this is the first point in
// the self-hosting work where a whole front-end stage runs in xtc end to end.
//
// The dump format is XTASTDumper's, exactly: one node per line, two spaces of
// indent per level, `(Kind field=value …)` fields in a fixed order.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "TokenType.xc"
#import "Token.xc"
#import "Lexer.xc"
#import "FloatEncoding.xc"
#import "MacroDef.xc"
#import "Preprocessor.xc"
#import "Node.xc"
#import "Parser.xc"
#import "AstDump.xc"
#import "Mangle.xc"
#import "Sema.xc"
#import "Vtable.xc"
#import "Ir.xc"
#import "Lower.xc"
#import "Designable.xc"

void main(void)
    {
    Preprocessor* pp = new Preprocessor();
    String* input = (String*)0;
    bool raw = false;
    bool dumpVslots = false;

    // The driver predefines the `bank(...)` selector constants before it ever
    // reaches the front end, so the oracle sees them and this has to as well —
    // otherwise BANK_DATA reads as an unbound identifier in a file the oracle
    // compiles cleanly, and the harness scores a harness gap as a port gap.
    // A -D on the command line still wins: these are defaults, not overrides.
    predefine(pp);

    Array* incs = new Array();
    Array* defs = new Array();
    u32 argc = Process.argumentCount();
    u32 i = (u32)1;
    while (i < argc)
        {
        String* a = Process.argument(i);
        if (a.equals(String.withCString("--raw")))
            {
            raw = true;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("--dump-vslots")))
            {
            dumpVslots = true;
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("-I")) && i + (u32)1 < argc)
            {
            pp.addIncludePath(Process.argument(i + (u32)1));
            incs.add((Object*)Process.argument(i + (u32)1));
            i = i + (u32)2;
            continue;
            }
        if (a.hasPrefix(String.withCString("-I")) && a.byteLength() > (u32)2)
            {
            pp.addIncludePath(a.substringFromByte((u32)2));
            incs.add((Object*)a.substringFromByte((u32)2));
            i = i + (u32)1;
            continue;
            }
        if (a.equals(String.withCString("-D")) && i + (u32)1 < argc)
            {
            defineArg(pp, Process.argument(i + (u32)1));
            defs.add((Object*)Process.argument(i + (u32)1));
            i = i + (u32)2;
            continue;
            }
        if (a.hasPrefix(String.withCString("-D")) && a.byteLength() > (u32)2)
            {
            defineArg(pp, a.substringFromByte((u32)2));
            defs.add((Object*)a.substringFromByte((u32)2));
            i = i + (u32)1;
            continue;
            }
        if (!a.hasPrefix(String.withCString("-")))
            input = a;
        i = i + (u32)1;
        }

    if (input == 0)
        {
        Stdio.printf("usage: xtir [-I dir] [-D name=value] [--raw] <file.xc>\n");
        Process.exit((i32)2);
        return;
        }

    // The `%@` gate. Stdio pulls in the Object root (and String) for
    // `%@` → description() dispatch ONLY when the program actually uses one,
    // and the spec can live in an imported library — so it is found by a
    // THROWAWAY expansion of the whole source, then declared on the real
    // preprocessor before it evaluates the guard. Without it the port compiles
    // a different program than the driver does.
    if (!raw)
        {
        Preprocessor* scan = new Preprocessor();
        predefine(scan);
        for (u32 pi = (u32)0; pi < incs.count(); pi = pi + (u32)1)
            scan.addIncludePath((String*)incs.get(pi));
        for (u32 di = (u32)0; di < defs.count(); di = di + (u32)1)
            defineArg(scan, (String*)defs.get(di));
        scan.define(String.withCString("HAS_ATFMT"), String.withCString("0"));
        String* probe = scan.preprocessFile(input);
        bool hasAt = probe != 0 && probe.byteIndexOf(String.withCString("%@")) != String.notFound();
        pp.define(String.withCString("HAS_ATFMT"),
                  String.withCString(hasAt ? "1" : "0"));
        }

    // The implicit platform prelude, gated exactly as the oracle's driver
    // gates it — a Platform.xc anywhere on the search path (task #36). The
    // %@ scan above stays preludeless, mirroring setupObjectFmtGateOnto:.
    if (!raw)
        {
        for (u32 pi = (u32)0; pi < incs.count(); pi = pi + (u32)1)
            {
            String* pth = String.withCString(((String*)incs.get(pi)).cString());
            pth.appendCString("/Platform.xc");
            if (Files.exists(pth))
                {
                pp.setPrelude(String.withCString("Platform.xc"));
                pi = incs.count();
                }
            }
        }

    String* source = raw ? Files.readText(input) : pp.preprocessFile(input);
    if (source == 0)
        {
        Stdio.printf("xtir: cannot read '%s'\n", input.cString());
        Process.exit((i32)1);
        return;
        }

    Lexer* lex = Lexer.with(source, input);
    Array* tokens = lex.tokenise();
    Parser* parser = Parser.with(tokens);
    Node* program = parser.parse();
    // uxkit/026: the oracle for this harness is `xcc-fe`, and xcc-fe
    // synthesises the designable bodies before sema. Without the same call
    // here the two sides lower DIFFERENT programs and the differential is
    // comparing the wrong thing rather than finding a real divergence.
    synthesizeDesignable(program);

    Sema* sema = Sema.make();
    // This tool is compared against `xcc-fe -m xt`, whose pointer width is 3.
    // Stated rather than defaulted, and stated for BOTH halves below, because
    // sema picks the ptrdiff type while lowering builds the value: if they
    // disagree the cast is selected from one width and applied to the other.
    sema.setPointerWidth((u32)3);
    sema.analyse(program);

    // --dump-vslots mirrors XTC_DUMP_VSLOTS on xtc-fe, so the two slot
    // assignments can be diffed line for line rather than inferred from what
    // they produce.
    if (dumpVslots)
        {
        String* vs = String.withCString("");
        sema.vtable().dumpTo(vs);
        Stdio.printf("%s", vs.cString());
        }
    Lower* lower = Lower.make();
    lower.setPointerWidth((u32)3);
    lower.setVtable(sema.vtable());
    IRModule* mod = lower.run(program, moduleNameOf(input));
    if (mod == 0 || lower.failed())
        {
        Stdio.printf("xtir: %s: unsupported: %s\n", input.cString(),
                     lower.why() == 0 ? "?" : lower.why().cString());
        Process.exit((i32)3);
        return;
        }
    Stdio.printf("%s", mod.text().cString());
    }

// The module name is the file's basename with its extension removed — the
// same name the original gives the module.
String* moduleNameOf(String* path)
    {
    u32 slash = String.notFound();
    for (u32 i = (u32)0; i < path.byteLength(); i = i + (u32)1)
        if (path.byteAt(i) == (u8)'/')
            slash = i;
    String* base = (slash == String.notFound()) ? path : path.substringFromByte(slash + (u32)1);
    u32 dot = String.notFound();
    for (u32 i = (u32)0; i < base.byteLength(); i = i + (u32)1)
        if (base.byteAt(i) == (u8)'.')
            dot = i;
    if (dot == String.notFound())
        return base;
    return base.substringBytes((u32)0, dot);
    }

void predefine(Preprocessor* pp)
    {
    // …and the MEMORY MODEL's own constants, which the driver computes from
    // the layout before the front end ever runs. The default target is xt6502:
    // a 4 KB hidden hardware stack (so the runtime libs push their recursion
    // frames on it and XTC_SP does not exist at all), banked, no PORTB shadow
    // and no cloaking.
    // The printf scratch buffers, whose addresses come from the layout's
    // `buffers` map — absent on xt, so all three are zero.
    pp.define(String.withCString("XT_STDIO_FMT_BUF"), String.withCString("$0000"));
    pp.define(String.withCString("XT_PRINTF_BUF"), String.withCString("$0000"));
    pp.define(String.withCString("XT_PRINTF_DATA_BUF"), String.withCString("$0002"));
    pp.define(String.withCString("XTC_POINTER_WIDTH"), String.withCString("4"));
    pp.define(String.withCString("XTC_LIB_HWSTACK"), String.withCString("1"));
    pp.define(String.withCString("XTC_TARGET_BANKED"), String.withCString("1"));
    pp.define(String.withCString("XTC_TARGET_SHADOW"), String.withCString("0"));
    pp.define(String.withCString("XTC_HAS_CLOAKED"), String.withCString("0"));
    pp.define(String.withCString("XTC_HP_LO"), String.withCString("$8E"));
    pp.define(String.withCString("XTC_HP_HI"), String.withCString("$8F"));

    pp.define(String.withCString("BANK_DATA"), String.withCString("0"));
    pp.define(String.withCString("BANK_CODE"), String.withCString("1"));
    pp.define(String.withCString("BANK_C"), String.withCString("2"));
    }

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
