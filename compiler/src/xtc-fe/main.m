#import <Foundation/Foundation.h>
#import "XTCommandLineOptions.h"
#import "XTCompilerDriver.h"
#import "XTIRModule.h"
#import "XTIRPrinter.h"
#import "XTInterfaceSerializer.h"
#import "XTLexer.h"
#import "XTToken.h"
#import "XTDiagnosticEngine.h"
#import "XTPreprocessor.h"
#import "XTParser.h"
#import "XTTypeTable.h"
#import "XTASTDumper.h"
#import "XTSemanticAnalyzer.h"
#import "XTSemanticAnalyzer+Analysis.h"
#import "XTPointerType.h"
#import "XTStructType.h"
#import "XTType.h"

// xtc-fe — IR-emitting frontend for the new-IR pipeline.
//
// Runs preprocess → lex → parse → sema → IR-lower → verify on a single
// .xc source file and writes the verified IR module as text (the format
// XTIRPrinter produces, which XTIRParser round-trips). xtcg-<arch>
// consumes that .ir text and produces target asm.
//
// Reuses XTCompilerDriver's command-line parser and the new
// compileFrontendForFile: entry point so the frontend's behaviour stays
// identical to the in-process driver path. Accepts the same -m, -I, -D,
// -O, -q, -V flags so a build system can blindly pass through what it
// gave to xtc.
//
// Usage:
//   xtc-fe [options] <input.xc> -o output.ir

#ifndef XTC_VERSION
#define XTC_VERSION "0.0"
#endif

/****************************************************************************\
|* Escape a token's text so one token is exactly one output line.
|*
|* The self-hosted lexer (selfhost/lexer/Lexer.xc) writes the SAME encoding, and
|* the two dumps are compared byte for byte — so this function's rules are a
|* contract between the two implementations, not a formatting choice. Backslash
|* first, then the three whitespace characters that would otherwise break the
|* one-token-one-line invariant.
\****************************************************************************/
static NSString* XTEscapeTokenText(NSString* s)
    {
    // Escape per UTF-8 BYTE, not per unichar: the xtc lexer sees bytes, and a
    // non-ASCII character would otherwise dump as one \xE9 here and two bytes
    // there for the same input. Via NSData rather than UTF8String because a
    // string literal may contain an embedded NUL (`"\0"`), which would end a C
    // string early — and the xtc side, which carries a length, would not stop.
    NSData* utf8 = [s dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char* bytes = (const unsigned char*)utf8.bytes;
    NSMutableString* out = [NSMutableString stringWithCapacity:s.length + 8];
    for (NSUInteger bi = 0; bi < utf8.length; bi++)
        {
        unsigned c = bytes[bi];
        switch (c)
            {
        case '\\':
            [out appendString:@"\\\\"];
            break;
        case '\n':
            [out appendString:@"\\n"];
            break;
        case '\t':
            [out appendString:@"\\t"];
            break;
        case '\r':
            [out appendString:@"\\r"];
            break;
        default:
            if (c < 32 || c > 126)
                [out appendFormat:@"\\x%02X", c];
            else
                [out appendFormat:@"%c", (char)c];
            break;
            }
        }
    return out;
    }

/****************************************************************************\
|* --dump-tokens: lex ONE raw source file and print its token stream.
|*
|* Deliberately not the compile path: no preprocessing, no include resolution,
|* no sema. It exists to be the ORACLE for the xtc-language lexer (self-hosting
|* M4), which must produce an identical stream for the same input. Anything the
|* driver does around the lexer would be noise in that comparison.
|*
|* One line per token:  <line> <col> <type> <intValue> <escaped text>
|*
|* The type is the NUMERIC XTTokenType, not its name: the numbers are the
|* contract both implementations share, and a name table would be a second
|* thing to keep in sync. `intValue` is 0 for every token that carries no
|* integer payload.
\****************************************************************************/
static int XTDumpTokens(const char* path)
    {
    NSString* file = [NSString stringWithUTF8String:path];
    NSError* err = nil;
    NSString* src = [NSString stringWithContentsOfFile:file
                                              encoding:NSUTF8StringEncoding
                                                 error:&err];
    if (!src)
        {
        fprintf(stderr, "xcc-fe: cannot read '%s'\n", path);
        return 1;
        }

    XTDiagnosticEngine* diag = [[XTDiagnosticEngine alloc] init];
    XTLexer* lexer = [[XTLexer alloc] initWithSource:src
                                            filename:file
                                         diagnostics:diag];
    NSArray<XTToken*>* tokens = [lexer tokenise];

    NSMutableString* out = [NSMutableString string];
    for (XTToken* t in tokens)
        {
        [out appendFormat:@"%lu %lu %ld %lld %@\n",
                          (unsigned long)t.location.line,
                          (unsigned long)t.location.column,
                          (long)t.type,
                          (long long)t.intValue,
                          XTEscapeTokenText(t.value)];
        }
    fputs(out.UTF8String, stdout);
    return 0;
    }

/****************************************************************************\
|* --dump-pp: preprocess ONE file and print the result.
|*
|* The oracle for the xtc-language preprocessor (self-hosting M5), and like
|* --dump-tokens it is deliberately not the compile path: only the -I paths and
|* -D defines given on THIS command line are used, with no implicit platform
|* prelude, no automatic support/ include directories and no library paths. Both
|* implementations then see exactly the same configuration, so a difference in
|* the output is a difference in the preprocessor rather than in the driver
|* around it.
\****************************************************************************/
static int XTDumpPreprocessed(int argc, const char* argv[])
    {
    NSString* input = nil;
    NSMutableArray<NSString*>* includes = [NSMutableArray array];
    NSMutableArray<NSString*>* defines = [NSMutableArray array];

    for (int i = 1; i < argc; i++)
        {
        NSString* a = @(argv[i]);
        if ([a isEqualToString:@"--dump-pp"])
            continue;
        if ([a isEqualToString:@"-I"] && i + 1 < argc)
            {
            [includes addObject:@(argv[++i])];
            continue;
            }
        if ([a hasPrefix:@"-I"] && a.length > 2)
            {
            [includes addObject:[a substringFromIndex:2]];
            continue;
            }
        if ([a isEqualToString:@"-D"] && i + 1 < argc)
            {
            [defines addObject:@(argv[++i])];
            continue;
            }
        if ([a hasPrefix:@"-D"] && a.length > 2)
            {
            [defines addObject:[a substringFromIndex:2]];
            continue;
            }
        if (![a hasPrefix:@"-"])
            input = a;
        }
    if (!input)
        {
        fprintf(stderr, "xcc-fe: --dump-pp needs a file\n");
        return 1;
        }

    XTDiagnosticEngine* diag = [[XTDiagnosticEngine alloc] init];
    XTPreprocessor* pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
    pp.includePaths = includes;
    for (NSString* d in defines)
        {
        NSRange eq = [d rangeOfString:@"="];
        if (eq.location == NSNotFound)
            [pp defineMacro:d value:nil];
        else
            [pp defineMacro:[d substringToIndex:eq.location]
                      value:[d substringFromIndex:eq.location + 1]];
        }

    NSError* err = nil;
    NSString* out = [pp preprocessFile:input error:&err];
    // An unresolvable `#import` leaves a PARTIAL expansion and a diagnostic,
    // not nil. Reporting only the nil case made a missing include a silent
    // success: the oracle printed a short file, said nothing, and exited 0 —
    // and the differential harness read that as "the two agree".
    if (!out || diag.errorCount > 0)
        {
        [diag printAll];
        fprintf(stderr, "xcc-fe: cannot preprocess '%s'\n", input.UTF8String);
        return 1;
        }
    fputs(out.UTF8String, stdout);
    return 0;
    }

/****************************************************************************\
|* --dump-ast: preprocess, lex and parse ONE file, then print the AST.
|*
|* The oracle for the xtc-language parser (self-hosting M5). Sema does NOT run:
|* what is being compared is the tree the parser builds, and everything sema
|* stamps onto it afterwards (resolved methods, mangled names, inferred types)
|* would make the comparison a test of sema instead. See XTASTDumper for the
|* format, which is the contract between the two parsers.
\****************************************************************************/
// The implicit platform prelude, gated exactly as the compile path gates it
// (a Platform.xc anywhere on the -I list, XTCompilerDriver's
// resolvePlatformPrelude). The ast/sema dumps get it because the compile
// path has it — an oracle that parses a DIFFERENT unit than a real compile
// reads ambient-surface files as error files (task #36). --dump-pp and
// --dump-tokens stay bare: the pp/lexer differentials compare the raw file.
static void XTDumpApplyPrelude(XTPreprocessor* pp, NSArray<NSString*>* includes)
    {
    NSFileManager* fm = [NSFileManager defaultManager];
    for (NSString* dir in includes)
        {
        if ([fm fileExistsAtPath:
                    [dir stringByAppendingPathComponent:@"Platform.xc"]])
            {
            pp.platformPrelude = @"Platform.xc";
            return;
            }
        }
    }

static int XTDumpAST(int argc, const char* argv[])
    {
    NSString* input = nil;
    NSMutableArray<NSString*>* includes = [NSMutableArray array];
    NSMutableArray<NSString*>* defines = [NSMutableArray array];
    BOOL raw = NO; // --raw: skip preprocessing, parse the file as-is

    for (int i = 1; i < argc; i++)
        {
        NSString* a = @(argv[i]);
        if ([a isEqualToString:@"--dump-ast"])
            continue;
        if ([a isEqualToString:@"--raw"])
            {
            raw = YES;
            continue;
            }
        if ([a isEqualToString:@"-I"] && i + 1 < argc)
            {
            [includes addObject:@(argv[++i])];
            continue;
            }
        if ([a hasPrefix:@"-I"] && a.length > 2)
            {
            [includes addObject:[a substringFromIndex:2]];
            continue;
            }
        if ([a isEqualToString:@"-D"] && i + 1 < argc)
            {
            [defines addObject:@(argv[++i])];
            continue;
            }
        if ([a hasPrefix:@"-D"] && a.length > 2)
            {
            [defines addObject:[a substringFromIndex:2]];
            continue;
            }
        if (![a hasPrefix:@"-"])
            input = a;
        }
    if (!input)
        {
        fprintf(stderr, "xcc-fe: --dump-ast needs a file\n");
        return 1;
        }

    XTDiagnosticEngine* diag = [[XTDiagnosticEngine alloc] init];
    NSString* source = nil;
    if (raw)
        {
        source = [NSString stringWithContentsOfFile:input
                                           encoding:NSUTF8StringEncoding
                                              error:NULL];
        }
    else
        {
        XTPreprocessor* pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
        pp.includePaths = includes;
        XTDumpApplyPrelude(pp, includes);
        for (NSString* d in defines)
            {
            NSRange eq = [d rangeOfString:@"="];
            if (eq.location == NSNotFound)
                [pp defineMacro:d value:nil];
            else
                [pp defineMacro:[d substringToIndex:eq.location]
                          value:[d substringFromIndex:eq.location + 1]];
            }
        source = [pp preprocessFile:input error:NULL];
        }
    // Same silent-failure trap as --dump-pp: a missing `#import` yields a
    // partial expansion plus a diagnostic. Parsing it produced an EMPTY
    // `Program`, printed it, and exited 0 — which the harness could only read
    // as "the oracle stopped early", when what actually happened is that the
    // file never resolved.
    if (!source || diag.errorCount > 0)
        {
        [diag printAll];
        fprintf(stderr, "xcc-fe: cannot preprocess '%s'\n", input.UTF8String);
        return 1;
        }

    XTLexer* lexer = [[XTLexer alloc] initWithSource:source filename:input diagnostics:diag];
    NSArray<XTToken*>* tokens = [lexer tokenise];
    XTTypeTable* types = [[XTTypeTable alloc] init];
    XTParser* parser = [[XTParser alloc] initWithTokens:tokens
                                              typeTable:types
                                            diagnostics:diag];
    XTProgramNode* program = [parser parse];
    if (!program)
        {
        fprintf(stderr, "xcc-fe: parse failed for '%s'\n", input.UTF8String);
        return 1;
        }
    fputs([XTASTDumper dump:program].UTF8String, stdout);
    return 0;
    }

/****************************************************************************\
|* --dump-sema: preprocess, lex, parse and ANALYSE one file, then print the
|* annotated AST.
|*
|* The oracle for the xtc-language semantic analyser (self-hosting M6). Same
|* tree as --dump-ast, with everything sema stamps onto it: resolved types, the
|* symbol each call resolved to, virtual slots, inferred storage. XTASTDumper
|* renders both from one walk, so the parser oracle and this one cannot drift.
|*
|* The analyser's knobs are PINNED here rather than taken from a target: ARC on,
|* flat heap, 8-byte pointers, 4-byte IEEE float, conformance through the
|* vtable, no itable protocols, not a library build. Sema's output genuinely
|* depends on several of them — vtable slot numbering, for one — so the two
|* implementations have to agree on the configuration before it is meaningful to
|* compare what they make of a program. The port hardcodes the same set.
\****************************************************************************/
static int XTDumpSema(int argc, const char* argv[])
    {
    NSString* input = nil;
    NSMutableArray<NSString*>* includes = [NSMutableArray array];
    NSMutableArray<NSString*>* defines = [NSMutableArray array];

    for (int i = 1; i < argc; i++)
        {
        NSString* a = @(argv[i]);
        if ([a isEqualToString:@"--dump-sema"])
            continue;
        if ([a isEqualToString:@"-I"] && i + 1 < argc)
            {
            [includes addObject:@(argv[++i])];
            continue;
            }
        if ([a hasPrefix:@"-I"] && a.length > 2)
            {
            [includes addObject:[a substringFromIndex:2]];
            continue;
            }
        if ([a isEqualToString:@"-D"] && i + 1 < argc)
            {
            [defines addObject:@(argv[++i])];
            continue;
            }
        if ([a hasPrefix:@"-D"] && a.length > 2)
            {
            [defines addObject:[a substringFromIndex:2]];
            continue;
            }
        if (![a hasPrefix:@"-"])
            input = a;
        }
    if (!input)
        {
        fprintf(stderr, "xcc-fe: --dump-sema needs a file\n");
        return 1;
        }

    [XTPointerType setHeapPointerWidth:8];
    [XTType setFloatWidth:4];
    [XTType setFloatIsIEEE:YES];
    [XTStructType setFieldAlignmentCap:8]; // match the arm64-shaped widths above

    XTDiagnosticEngine* diag = [[XTDiagnosticEngine alloc] init];
    XTPreprocessor* pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
    pp.includePaths = includes;
    XTDumpApplyPrelude(pp, includes);
    for (NSString* d in defines)
        {
        NSRange eq = [d rangeOfString:@"="];
        if (eq.location == NSNotFound)
            [pp defineMacro:d value:nil];
        else
            [pp defineMacro:[d substringToIndex:eq.location]
                      value:[d substringFromIndex:eq.location + 1]];
        }
    NSString* source = [pp preprocessFile:input error:NULL];
    if (!source || diag.errorCount > 0)
        {
        [diag printAll];
        fprintf(stderr, "xcc-fe: cannot preprocess '%s'\n", input.UTF8String);
        return 1;
        }

    XTLexer* lexer = [[XTLexer alloc] initWithSource:source filename:input diagnostics:diag];
    NSArray<XTToken*>* tokens = [lexer tokenise];
    XTTypeTable* types = [[XTTypeTable alloc] init];
    XTParser* parser = [[XTParser alloc] initWithTokens:tokens
                                              typeTable:types
                                            diagnostics:diag];
    XTProgramNode* program = [parser parse];
    if (!program)
        {
        [diag printAll];
        fprintf(stderr, "xcc-fe: parse failed for '%s'\n", input.UTF8String);
        return 1;
        }

    XTSemanticAnalyzer* sema = [[XTSemanticAnalyzer alloc]
        initWithTypeTable:types
              diagnostics:diag];
    sema.allocator = @"heap";
    sema.heapBank = 0;
    sema.libraryBuild = NO;
    sema.itableProtocols = NO;
    sema.vtableConforms = YES;
    [sema analyzeProgram:program];
    // A parse or sema ERROR is reported but still dumps. The distinction that
    // matters for a differential oracle: a PREPROCESSOR failure means neither
    // side ever saw the source, so there is nothing to compare and the run
    // fails (#837); a parse or sema error is part of what the two
    // implementations must AGREE about — error recovery included — so the tree
    // built so far is printed and the exit status stays 0. Getting this
    // backwards would either hide a difference or report a fixture that is
    // MEANT to fail as a broken oracle on every run.
    if (diag.errorCount > 0)
        [diag printAll];

    fputs([XTASTDumper dumpWithSema:program].UTF8String, stdout);
    return 0;
    }

int main(int argc, const char* argv[])
    {
    @autoreleasepool
        {
        // Record argv[0] so the support tree is found relative to THIS binary.
        // An installed tool must not depend on the current directory to find
        // its own libraries.
        [XTCommandLineOptions setExecutablePath:argv[0]];
        for (int i = 1; i < argc; i++)
            {
            if (strcmp(argv[i], "-v") == 0 || strcmp(argv[i], "--version") == 0)
                {
                printf("xtc-fe %s\n", XTC_VERSION);
                return 0;
                }
            }

        for (int i = 1; i < argc; i++)
            {
            if (strcmp(argv[i], "--dump-ast") == 0)
                return XTDumpAST(argc, argv);
            }
        for (int i = 1; i < argc; i++)
            {
            if (strcmp(argv[i], "--dump-sema") == 0)
                return XTDumpSema(argc, argv);
            }

        for (int i = 1; i < argc; i++)
            {
            if (strcmp(argv[i], "--dump-pp") == 0)
                return XTDumpPreprocessed(argc, argv);
            }

        // --dump-tokens <file>: the M4 oracle. Handled before option parsing
        // because it shares none of the compile path's flags.
        for (int i = 1; i < argc; i++)
            {
            if (strcmp(argv[i], "--dump-tokens") != 0)
                continue;
            const char* path = (i + 1 < argc) ? argv[i + 1] : NULL;
            if (!path)
                {
                fprintf(stderr, "xcc-fe: --dump-tokens needs a file\n");
                return 1;
                }
            return XTDumpTokens(path);
            }

        XTCommandLineOptions* opts = [XTCommandLineOptions parseArgc:argc argv:argv];
        if (!opts)
            return 1;
        if (opts.inputFiles.count == 0)
            {
            fprintf(stderr, "xcc-fe: error: no input file\n");
            return 1;
            }
        if (opts.inputFiles.count > 1)
            {
            fprintf(stderr, "xcc-fe: error: multi-file inputs not supported\n");
            return 1;
            }

        // Force the new-IR path so XTCompilerDriver's include-path
        // resolution + macro setup match xtcg-* expectations even if
        // the caller didn't pass -fnew-ir.
        [opts setValue:@(YES) forKey:@"useNewIR"];

        XTCompilerDriver* driver =
            [[XTCompilerDriver alloc] initWithOptions:opts];
        // --dump-c-iface: print the auto-imported libc as xtc declarations and
        // stop. Needs the driver (library search paths, target pointer width),
        // so it is handled here rather than with the other dumps above.
        for (int i = 1; i < argc; i++)
            if (strcmp(argv[i], "--dump-c-iface") == 0)
                return [driver dumpCInterfaceDeclarations];

        XTIRModule* mod =
            [driver compileFrontendForFile:opts.inputFiles.firstObject];
        if (!mod)
            return 1;

        NSString* irText = [XTIRPrinter stringFromModule:mod];
        NSString* outPath = opts.outputPath;
        if (outPath)
            {
            NSError* err = nil;
            [irText writeToFile:outPath
                     atomically:YES
                       encoding:NSUTF8StringEncoding
                          error:&err];
            if (err)
                {
                fprintf(stderr, "xcc-fe: cannot write '%s': %s\n",
                        outPath.UTF8String, err.localizedDescription.UTF8String);
                return 1;
                }
            if (!opts.quiet)
                {
                fprintf(stderr, "xcc-fe: IR -> '%s'\n", outPath.UTF8String);
                }
            // Write the DT_NEEDED sidecar (`<output>.needs`, one .so path per
            // line) so the dispatcher can record the dynamic dependencies it
            // can't see — it doesn't parse #import. Absent ⇒ no library imports.
            NSArray<NSString*>* needed = driver.neededLibraryPaths;
            NSString* needsPath = [outPath stringByAppendingPathExtension:@"needs"];
            if (needed.count > 0)
                {
                NSString* body = [[needed componentsJoinedByString:@"\n"]
                    stringByAppendingString:@"\n"];
                [body writeToFile:needsPath
                       atomically:YES
                         encoding:NSUTF8StringEncoding
                            error:NULL];
                }
            else
                {
                // Stale sidecar from a previous build of the same temp name
                // would mis-link; remove it.
                [[NSFileManager defaultManager] removeItemAtPath:needsPath error:NULL];
                }

            // --emit-lib: serialise the public declarations into `<output>.iface`,
            // which the dispatcher embeds in the library's `.xtc.iface` section so
            // an app can `#import <Lib>` it (B1: binary xtc modules).
            //
            // -c wants the SAME artifact for a different reason: it is the header
            // xtc otherwise lacks. A module that must know a class's layout and
            // vtable slot numbering without seeing its body reads this file — and
            // the numbering has to come from the DEFINING object, because a second
            // compilation cannot re-derive it and agree by luck.
            // private:docs/Design/separate-compilation.md stage 3.
            NSString* ifacePath = [outPath stringByAppendingPathExtension:@"iface"];
            if ((opts.emitLib || opts.compileOnly || opts.emitIface) && driver.analyzedProgram)
                {
                NSString* json = [XTInterfaceSerializer jsonForProgram:driver.analyzedProgram
                                                         protocolSlots:driver.protocolSlots
                                                           methodSlots:driver.virtualMethodSlots
                                                              cImports:driver.cLibraryImports
                                                          excludeFiles:driver.preludeFiles];
                if (json.length)
                    {
                    [json writeToFile:ifacePath
                           atomically:YES
                             encoding:NSUTF8StringEncoding
                                error:NULL];
                    if (!opts.quiet)
                        fprintf(stderr, "xcc-fe: interface -> '%s'\n", ifacePath.UTF8String);
                    }
                }
            else
                {
                [[NSFileManager defaultManager] removeItemAtPath:ifacePath error:NULL];
                }
            }
        else
            {
            fputs(irText.UTF8String, stdout);
            }
        return 0;
        }
    }
