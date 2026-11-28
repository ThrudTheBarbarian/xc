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
#import <TokenType>
#import "TokenTypeDefs.xc"
#import <Token>
#import <Lexer>
#import <FloatEncoding>
#import <MacroDef>
#import <Preprocessor>
#import <Node>
#import "NodeDefs.xc"
#import <Parser>
#import <AstDump>
#import <Mangle>
#import <Sema>
#import <Vtable>
#import <Ir>
#import "IrDefs.xc"
#import <LowerBase>
#import <Lower>
#import <Designable>

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
    // `%@` → description() dispatch only when the program passes a format
    // that holds one, in its own code or an imported file's. Sema finds that
    // (Sema.usesAtFormat): the first pass is built with HAS_ATFMT 0, and a
    // program that uses `%@` is built again with 1, as the driver does.
    // Without it the port compiles a different program than the driver does.
    // A small float's routines likewise (Sema.packRoutines): imported at the
    // end of the entry file in a pass after the first, as the driver does.
    bool hasAt = false;
    u32 packR = (u32)0;
    String* source = (String*)0;
    Node* program = (Node*)0;
    Sema* sema = (Sema*)0;
    // A tensor type: TensorStorage.xc imported and read again, as the driver does.
    bool withTensor = false;
    // The kernels of its tensor expressions, written by the parse, as the
    // driver does.
    Array* kernels = (Array*)0;
    for (u32 pass = 0; pass < 6; pass = pass + (u32)1)
        {
        if (pass > (u32)0)
            {
            pp = new Preprocessor();
            predefine(pp);
            for (u32 pi = (u32)0; pi < incs.count(); pi = pi + (u32)1)
                pp.addIncludePath((String*)incs.get(pi));
            for (u32 di = (u32)0; di < defs.count(); di = di + (u32)1)
                defineArg(pp, (String*)defs.get(di));
            }
        if (!raw)
            pp.define(String.withCString("HAS_ATFMT"),
                      String.withCString(hasAt ? "1" : "0"));
        if (!raw && packR != (u32)0)
            pp.setTailImport(Preprocessor.packTailImport(packR));
        if (!raw && withTensor)
            pp.setAutoImport(String.withCString("TensorStorage.xc"));
        if (!raw && withTensor && kernels != (Array*)0)
            pp.addAutoImport(String.withCString("TensorPar.xc"));

        // The implicit platform prelude, gated exactly as the oracle's driver
        // gates it — a Platform.xc anywhere on the search path (task #36).
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

        source = raw ? Files.readText(input) : pp.preprocessFile(input);
        if (source == 0)
            {
            Stdio.printf("xtir: cannot read '%s'\n", input.cString());
            Process.exit((i32)1);
            return;
            }

        Lexer* lex = Lexer.with(source, input);
        Array* tokens = lex.tokenise();
        Parser* parser = Parser.with(tokens);
        parser.setGoalDefault(pp.goal());   // a #goal in the file, as the front end honours it
        parser.setLibraryFiles(pp.libraryFiles());
        parser.setTensorReady(withTensor);
        parser.setTensorKernels(kernels);
        program = parser.parse();
        if (!raw && !withTensor && parser.tensorNames().count() > (u32)0)
            {
            withTensor = true;
            continue;
            }
        // uxkit/026: the oracle for this harness is `xcc-fe`, and xcc-fe
        // synthesises the designable bodies before sema. Without the same call
        // here the two sides lower DIFFERENT programs and the differential is
        // comparing the wrong thing rather than finding a real divergence.
        Array* designErrors = synthesizeDesignable(program);
        if (designErrors.count() > (u32)0)
            {
            for (u32 e = (u32)0; e < designErrors.count(); e = e + (u32)1)
                Stdio.printf("%s", ((String*)designErrors.get(e)).cString());
            Process.exit((i32)1);
            return;
            }

        sema = Sema.make();
        // This tool is compared against `xcc-fe -m xt`, whose pointer width is 3.
        // Stated rather than defaulted, and stated for BOTH halves below, because
        // sema picks the ptrdiff type while lowering builds the value: if they
        // disagree the cast is selected from one width and applied to the other.
        sema.setPointerWidth((u32)3);
        sema.setTensorKernelsGiven(kernels);
        sema.analyse(program);
        if (raw)
            break;
        bool wantAt = !hasAt && sema.usesAtFormat();
        u32 wantPack = sema.packRoutines() & ~packR;
        Array* wantKernels = Sema.tensorKernelsJoin(kernels, sema.tensorKernelRequests());
        if (!wantAt && wantPack == 0 && wantKernels == (Array*)0)
            break;
        hasAt = hasAt || wantAt;
        packR = packR | wantPack;
        if (wantKernels != (Array*)0)
            kernels = wantKernels;
        }

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
