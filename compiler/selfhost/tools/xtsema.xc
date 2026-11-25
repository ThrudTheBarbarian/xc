// xtsema.xc — parse and ANALYSE a file with the ported front end, then dump
// the annotated AST.
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

void main(void)
    {
    Preprocessor* pp = new Preprocessor();
    String* input = (String*)0;
    bool raw = false;
    bool dumpVslots = false;
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
        Stdio.printf("usage: xtsema [-I dir] [-D name=value] [--raw] <file.xc>\n");
        Process.exit((i32)2);
        return;
        }

    // A program with a small float is read again with its routines imported
    // at the end (Sema.packRoutines), as the oracle reads it.
    Array* incs0 = pp.includePaths();
    u32 packR = (u32)0;
    Sema* sema = (Sema*)0;
    Node* program = (Node*)0;
    for (u32 pass = (u32)0; pass < (u32)2; pass = pass + (u32)1)
        {
        if (pass > (u32)0)
            {
            Preprocessor* pp2 = new Preprocessor();
            for (u32 pi = (u32)0; pi < incs0.count(); pi = pi + (u32)1)
                pp2.addIncludePath((String*)incs0.get(pi));
            for (u32 di = (u32)0; di < defs.count(); di = di + (u32)1)
                defineArg(pp2, (String*)defs.get(di));
            pp2.setTailImport(Preprocessor.packTailImport(packR));
            pp = pp2;
            }
        // The implicit platform prelude, gated exactly as the oracle gates it —
        // a Platform.xc anywhere on the -I list (task #36). The compile path has
        // it, so the dump oracles have it; an oracle parsing a DIFFERENT unit
        // than a real compile reads ambient-surface files as error files.
        if (!raw)
            {
            Array* incs = pp.includePaths();
            for (u32 ppi = (u32)0; ppi < incs.count(); ppi = ppi + (u32)1)
                {
                String* ppp = String.withCString(((String*)incs.get(ppi)).cString());
                ppp.appendCString("/Platform.xc");
                if (Files.exists(ppp))
                    {
                    pp.setPrelude(String.withCString("Platform.xc"));
                    ppi = incs.count();
                    }
                }
            }

        String* source = raw ? Files.readText(input) : pp.preprocessFile(input);
        if (source == 0)
            {
            Stdio.printf("xtsema: cannot read '%s'\n", input.cString());
            Process.exit((i32)1);
            return;
            }

        Lexer* lex = Lexer.with(source, input);
        Array* tokens = lex.tokenise();
        // A lexical error stops the reference's parse before its first
        // declaration, so its tree is an empty Program; the same here.
        if (lex.diagnostics().count() > (u32)0)
            {
            Stdio.printf("Program\n");
            return;
            }
        Parser* parser = Parser.with(tokens);
        parser.setGoalDefault(pp.goal());   // a #goal in the file, as the front end honours it
        parser.setLibraryFiles(pp.libraryFiles());
        program = parser.parse();

        sema = Sema.make();
        // This tool dumps the tree for COMPARISON against xcc-fe --dump-sema, and
        // that mode lays everything out with an 8-byte pointer regardless of
        // target (XTDumpSema parses only -I/-D and the filename). Say so, rather
        // than leaning on the default: the two sides must agree on the ptrdiff
        // type or every `p - q` in the corpus reads as a divergence.
        sema.setPointerWidth((u32)8);
        sema.analyse(program);
        if (raw || (sema.packRoutines() & ~packR) == (u32)0)
            break;
        packR = packR | sema.packRoutines();
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
    AstDump.setSemaMode(true);
    String* out = String.withCString("");
    AstDump.emit(program, out, (u32)0);
    Stdio.printf("%s", out.cString());
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
