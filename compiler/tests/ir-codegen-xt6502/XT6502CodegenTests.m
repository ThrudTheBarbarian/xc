// XT6502CodegenTests.m — Layer-4 cross-backend equivalence on the
// 6502 xt simulator.
//
// For each fixture <name>:
//   tests/ir-lowering/<name>.xc                — shared xtc source
//   tests/ir-codegen-xt6502/<name>.harness.asm — 6502 harness
//   tests/ir-codegen-xt6502/<name>.expected.out — stdout oracle
//                                                  (shared with
//                                                   ir-codegen-arm64)
//
// Pipeline:
//   1. frontend (lex/parse/sema) + XTIRLowering
//   2. XT6502Backend → generated asm
//   3. concatenate harness + generated + print.asm into one file
//   4. invoke <bin>/xcc-as to produce .xex          (<bin> = XC_BIN_DIR)
//   5. invoke <bin>/xcc-sim-6502 -d to simulate, capture stdout
//   6. diff against .expected.out (trailing whitespace trimmed)
#import <Foundation/Foundation.h>

// The built-binary directory is the HOST's, not always the Mac's: bin/osx on
// macOS, bin/linux on Linux. The Makefile already computes it (BIN_DIR) and
// passes it in as XC_BIN_DIR; the fallback keeps a standalone compile working.
// Hardcoding ./bin/osx here is what made every fixture fail rc=-1 on the Linux
// CI box — the process simply could not be spawned.
#ifndef XC_BIN_DIR
#define XC_BIN_DIR "bin/osx"
#endif
#define XCBIN(tool) (@"./" XC_BIN_DIR "/" tool)
#import "XTLexer.h"
#import "XTParser.h"
#import "XTSemanticAnalyzer.h"
#import "XTDiagnosticEngine.h"
#import "XTTypeTable.h"
#import "XTDeclNodes.h"
#import "XTIR.h"
#import "XT6502Backend.h"
#import "XTPointerType.h"
#import "XTStructType.h"
#import "XTMemoryModel.h"
#import "XTLinkerScriptParser.h"

static NSString* const kBuildDir = @"build/xt6502-fixtures";
static NSString* const kSourceDir = @"tests/ir-lowering";
static NSString* const kFixtureDir = @"tests/ir-codegen-xt6502";

// Flat memory model matching the dual-backend harness reality (NOT
// the production xt.lnk map — see task #55's recorded decision).
// Entry $2000, code+data in $2000-$9BFF, screen RAM at $9C00 (the
// SAVMSC the harnesses set + xts dumps from). Vars stay $A0-$FF so
// ZP allocation is byte-identical to the pre-#55 backend and never
// clashes with the harness's $58/$59/$90-$95 scratch. The model
// makes the backend emit `.code_regions $2000-$9BFF`, which guards
// against any code+data overrun into screen RAM.
static XTMemoryModel* xt6502HarnessModel(void)
    {
    XTMemoryModel* m = [XTMemoryModel new];
    m.name = @"xt6502-harness";
    m.entryAddress = 0x2000;
    m.systemStart = 0x2000;
    m.systemEnd = 0x9BFF;
    m.screenStart = 0x9C00;
    m.screenEnd = 0x9FFF;
    m.mainRegionRanges = @[ @[ @0x2000, @0x9BFF ] ];
    m.zpVarsRanges = @[ @[ @0xA0, @0xFF ] ];
    // Software-stack region (STACK-ABI §11.3) for non-leaf spill frames.
    // $C000-$CFFF: above the xts -d screen-write log window ($9C00..$BB3F)
    // so frame writes aren't decoded as screen output, and below the
    // $D000 I/O page. (Production xt.lnk uses the full $A000-$CFFF —
    // real HW has no such log window.)
    m.stackRangeStart = 0xC000;
    m.stackRangeEnd = 0xCFFF;
    m.stackRangeSet = YES;
    m.stackGrowsUp = YES;
    return m;
    }

static NSArray<NSString*>* fixtureNames(void)
    {
    NSError* err = nil;
    NSArray* all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kFixtureDir error:&err];
    if (!all)
        return @[];
    NSMutableArray<NSString*>* out = [NSMutableArray array];
    for (NSString* n in all)
        {
        if ([n hasSuffix:@".harness.asm"])
            {
            NSString* base = [n stringByReplacingOccurrencesOfString:@".harness.asm"
                                                          withString:@""];
            // banked-xcall has its own runner (banked model + -m xt);
            // the generic flat-model path would mis-run it.
            if ([base isEqualToString:@"banked-xcall"])
                continue;
            [out addObject:base];
            }
        }
    return [out sortedArrayUsingSelector:@selector(compare:)];
    }

static NSString* readFile(NSString* path)
    {
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    }

static NSString* trimTrailing(NSString* s)
    {
    if (!s)
        return @"";
    NSCharacterSet* ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSUInteger i = s.length;
    while (i > 0 && [ws characterIsMember:[s characterAtIndex:i - 1]])
        i--;
    return [s substringToIndex:i];
    }

static BOOL runProcessErr(NSString* exe, NSArray<NSString*>* args,
                          NSString* stdoutPath, NSString* stderrPath,
                          int* exitCodeOut)
    {
    NSTask* task = [[NSTask alloc] init];
    task.launchPath = exe;
    task.arguments = args;
    if (stdoutPath)
        {
        [[NSFileManager defaultManager] createFileAtPath:stdoutPath
                                                contents:[NSData data]
                                              attributes:nil];
        task.standardOutput = [NSFileHandle fileHandleForWritingAtPath:stdoutPath];
        }
    else
        {
        task.standardOutput = [NSFileHandle fileHandleWithStandardError];
        }
    // Suppress xta/xts chatter on success — the runner reports its
    // own per-fixture diagnostics, and the .combined.asm path is
    // printed on failure so re-invocation by hand is easy. A caller that
    // needs to inspect the halt reason (crash vs a clean non-zero exit)
    // passes a stderrPath to capture it instead.
    if (stderrPath)
        {
        [[NSFileManager defaultManager] createFileAtPath:stderrPath
                                                contents:[NSData data]
                                              attributes:nil];
        task.standardError = [NSFileHandle fileHandleForWritingAtPath:stderrPath];
        }
    else
        {
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
        }
    @try
        {
        [task launch];
        [task waitUntilExit];
        if (exitCodeOut)
            *exitCodeOut = task.terminationStatus;
        return YES;
        }
    @catch (NSException* e)
        {
        if (exitCodeOut)
            *exitCodeOut = -1;
        return NO;
        }
    }

static BOOL runProcess(NSString* exe, NSArray<NSString*>* args,
                       NSString* stdoutPath, int* exitCodeOut)
    {
    return runProcessErr(exe, args, stdoutPath, nil, exitCodeOut);
    }

// xts now surfaces the 6502 program's own exit code (main's return value)
// as its process status, so a clean run may legitimately exit non-zero.
// A genuine crash — illegal opcode or an instruction-limit blow-out — is
// reported on stderr with a fixed marker, which is what actually signals
// failure. Returns YES if the captured stderr shows the run was aborted.
static BOOL xtsAborted(NSString* stderrPath)
    {
    NSString* err = readFile(stderrPath);
    if (!err)
        return NO;
    return [err containsString:@"illegal opcode"] ||
           [err containsString:@"instruction limit"];
    }

static int runFixture(NSString* name)
    {
    NSString* xtSrc = [NSString stringWithFormat:@"%@/%@.xc", kSourceDir, name];
    NSString* harnessAsm = [NSString stringWithFormat:@"%@/%@.harness.asm", kFixtureDir, name];
    NSString* expectedPath = [NSString stringWithFormat:@"%@/%@.expected.out", kFixtureDir, name];
    NSString* printAsm = [NSString stringWithFormat:@"%@/print.asm", kFixtureDir];

    NSString* source = readFile(xtSrc);
    if (!source)
        {
        fprintf(stderr, "  FAIL [%s]: cannot read %s\n",
                name.UTF8String, xtSrc.UTF8String);
        return 1;
        }
    // Pin the widths this suite's fixtures were written against — the
    // PROCESS DEFAULTS it always ran under (ptr 2, the bespoke 5-byte
    // float): it used to inherit them by accident, and the arm64 suite
    // now configures its own widths explicitly, so this one must too.
    // (This is the task-#55 harness reality, not the production xt6502
    // pipeline — the corpus sweeps that with ptr 3 / IEEE f32.)
    [XTPointerType setHeapPointerWidth:2];
    [XTType setFloatWidth:5];
    [XTType setFloatIsIEEE:NO];
    [XTStructType setFieldAlignmentCap:1];
    XTDiagnosticEngine* diag = [[XTDiagnosticEngine alloc] init];
    XTLexer* lexer = [[XTLexer alloc] initWithSource:source
                                            filename:xtSrc.lastPathComponent
                                         diagnostics:diag];
    XTTypeTable* tt = [[XTTypeTable alloc] init];
    XTParser* parser = [[XTParser alloc] initWithTokens:[lexer tokenise]
                                              typeTable:tt
                                            diagnostics:diag];
    XTProgramNode* ast = [parser parse];
    if (!ast || diag.hasFatalError)
        {
        fprintf(stderr, "  FAIL [%s]: frontend error\n", name.UTF8String);
        return 1;
        }
    XTSemanticAnalyzer* sema = [[XTSemanticAnalyzer alloc] initWithTypeTable:tt diagnostics:diag];
    [sema analyzeProgram:ast];
    if (diag.hasFatalError)
        {
        fprintf(stderr, "  FAIL [%s]: sema error\n", name.UTF8String);
        return 1;
        }
    XTIRModule* mod = [XTIRLowering lowerProgram:ast moduleName:name diagnostics:diag];
    if (!mod || diag.hasFatalError)
        {
        fprintf(stderr, "  FAIL [%s]: lowering error\n", name.UTF8String);
        return 1;
        }
    NSArray<NSString*>* vErrs = nil;
    if (![XTIRVerifier verifyModule:mod errors:&vErrs])
        {
        fprintf(stderr, "  FAIL [%s]: verifier rejected lowered IR\n", name.UTF8String);
        return 1;
        }
    NSString* generated = [XT6502Backend assemblyFromModule:mod
                                                memoryModel:xt6502HarnessModel()
                                                diagnostics:diag];
    if (!generated)
        {
        fprintf(stderr, "  FAIL [%s]: xt6502 backend rejected the module\n",
                name.UTF8String);
        for (XTDiagnostic* d in diag.diagnostics)
            {
            if (d.level >= 2)
                fprintf(stderr, "    %s\n", d.message.UTF8String);
            }
        return 1;
        }
    // The model must drive a `.code_regions` screen-overrun guard into
    // the output (task #55). Cheap structural check alongside the
    // behavioural oracle below.
    if (![generated containsString:@".code_regions $2000-$9BFF"])
        {
        fprintf(stderr, "  FAIL [%s]: backend did not emit model-driven "
                        ".code_regions\n",
                name.UTF8String);
        return 1;
        }
    // recurse-spill drives the non-leaf software-stack frame (task #57):
    // the backend must warn that the function uses a software stack.
    if ([name isEqualToString:@"recurse-spill"])
        {
        BOOL sawWarn = NO;
        for (XTDiagnostic* d in diag.diagnostics)
            {
            if ([d.message containsString:@"uses a software stack"])
                {
                sawWarn = YES;
                break;
                }
            }
        if (!sawWarn)
            {
            fprintf(stderr, "  FAIL [%s]: expected a 'uses a software stack' "
                            "warning (STACK-ABI §11.3)\n",
                    name.UTF8String);
            return 1;
            }
        }

    NSString* harnessSrc = readFile(harnessAsm);
    NSString* printSrc = readFile(printAsm);
    if (!harnessSrc || !printSrc)
        {
        fprintf(stderr, "  FAIL [%s]: missing harness or print routine\n", name.UTF8String);
        return 1;
        }
    NSString* combined = [NSString stringWithFormat:@"%@\n%@\n%@\n",
                                                    harnessSrc, generated, printSrc];

    NSFileManager* fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:kBuildDir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString* combinedPath = [NSString stringWithFormat:@"%@/%@.combined.asm", kBuildDir, name];
    NSString* xexPath = [NSString stringWithFormat:@"%@/%@.xex", kBuildDir, name];
    NSString* outPath = [NSString stringWithFormat:@"%@/%@.out", kBuildDir, name];
    NSError* werr = nil;
    if (![combined writeToFile:combinedPath
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:&werr])
        {
        fprintf(stderr, "  FAIL [%s]: cannot write %s\n",
                name.UTF8String, combinedPath.UTF8String);
        return 1;
        }

    // Assemble.
    int rc = 0;
    if (!runProcess(XCBIN("xcc-as"),
                    @[ @"-o", xexPath, combinedPath ],
                    nil, &rc) ||
        rc != 0)
        {
        fprintf(stderr, "  FAIL [%s]: xta failed (rc=%d). See %s\n",
                name.UTF8String, rc, combinedPath.UTF8String);
        return 1;
        }

    // Simulate. A clean run may exit non-zero (that's the program's own
    // return value now); only an aborted run — flagged on stderr — is a
    // failure.
    NSString* errPath = [NSString stringWithFormat:@"%@/%@.err", kBuildDir, name];
    if (!runProcessErr(XCBIN("xcc-sim-6502"),
                       @[ @"-d", xexPath ],
                       outPath, errPath, &rc) ||
        xtsAborted(errPath))
        {
        fprintf(stderr, "  FAIL [%s]: xts aborted (rc=%d). See %s\n",
                name.UTF8String, rc, xexPath.UTF8String);
        return 1;
        }

    NSString* actual = trimTrailing(readFile(outPath));
    NSString* expected = trimTrailing(readFile(expectedPath));
    if (!expected)
        {
        fprintf(stderr, "  FAIL [%s]: missing %s\n",
                name.UTF8String, expectedPath.UTF8String);
        return 1;
        }
    if (![actual isEqualToString:expected])
        {
        fprintf(stderr, "  FAIL [%s]: stdout differs\n", name.UTF8String);
        fprintf(stderr, "    expected: '%s'\n", expected.UTF8String);
        fprintf(stderr, "    actual:   '%s'\n", actual.UTF8String);
        return 1;
        }
    return 0;
    }

// xt banked memory model (task #60): the real xt map, loaded
// from the canonical layout file so the bank windows live in ONE place.
// Two test-harness overrides: the ZP var pool dodges the harness's
// $90-$95 print scratch (real HW has none), and `bankEachUserFunction`
// forces every non-entry function into its own bank so the focused
// golden exercises cross-bank calls with a two-function program.
static XTMemoryModel* xt6502XtModel(void)
    {
    NSError* err = nil;
    XTMemoryModel* m = [XTLinkerScriptParser
        parseFile:@"support/xt6502/layouts/xt.lnk"
            error:&err];
    if (!m)
        {
        fprintf(stderr, "  (cannot load xt.lnk: %s)\n",
                err.localizedDescription.UTF8String);
        return nil;
        }
    m.zpVarsRanges = @[ @[ @0xA0, @0xFF ] ];
    m.bankEachUserFunction = YES;
    return m;
    }

// Cross-bank-call golden: lower banked-xcall.xc, place each function in
// its own bank, assemble with the layout's banking config (-L), and run
// on the xt sim model (-m xt). Proves the $82 swap + _xcall
// trampoline + the sim's $6000-$9FFF code-bank windows end to end.
static int runBankedGolden(void)
    {
    NSString* name = @"banked-xcall";
    NSString* xtSrc = [NSString stringWithFormat:@"%@/%@.xc", kSourceDir, name];
    NSString* harnessAsm = [NSString stringWithFormat:@"%@/%@.harness.asm", kFixtureDir, name];
    NSString* expectedPath = [NSString stringWithFormat:@"%@/%@.expected.out", kFixtureDir, name];

    NSString* source = readFile(xtSrc);
    XTMemoryModel* model = xt6502XtModel();
    if (!source || !model)
        {
        fprintf(stderr, "  FAIL [%s]: missing source or model\n", name.UTF8String);
        return 1;
        }
    XTDiagnosticEngine* diag = [[XTDiagnosticEngine alloc] init];
    XTLexer* lexer = [[XTLexer alloc] initWithSource:source
                                            filename:xtSrc.lastPathComponent
                                         diagnostics:diag];
    XTTypeTable* tt = [[XTTypeTable alloc] init];
    XTParser* parser = [[XTParser alloc] initWithTokens:[lexer tokenise]
                                              typeTable:tt
                                            diagnostics:diag];
    XTProgramNode* ast = [parser parse];
    XTSemanticAnalyzer* sema = [[XTSemanticAnalyzer alloc] initWithTypeTable:tt diagnostics:diag];
    [sema analyzeProgram:ast];
    XTIRModule* mod = [XTIRLowering lowerProgram:ast moduleName:name diagnostics:diag];
    if (!mod || diag.hasFatalError)
        {
        fprintf(stderr, "  FAIL [%s]: frontend/lowering error\n", name.UTF8String);
        return 1;
        }
    NSString* generated = [XT6502Backend assemblyFromModule:mod
                                                memoryModel:model
                                                diagnostics:diag];
    if (!generated)
        {
        fprintf(stderr, "  FAIL [%s]: xt6502 backend rejected the module\n", name.UTF8String);
        return 1;
        }
    // Structural checks: the banked placement must have produced two
    // code banks (`.org $6000` ×2) and the cross-bank call staging.
    NSUInteger orgs = [[generated componentsSeparatedByString:@".org $6000"] count] - 1;
    if (orgs < 2)
        {
        fprintf(stderr, "  FAIL [%s]: expected ≥2 code banks (.org $6000), saw %lu\n",
                name.UTF8String, (unsigned long)orgs);
        return 1;
        }
    if (![generated containsString:@"JSR _xcall"])
        {
        fprintf(stderr, "  FAIL [%s]: no cross-bank _xcall emitted\n", name.UTF8String);
        return 1;
        }

    NSString* harnessSrc = readFile(harnessAsm);
    NSString* combined = [NSString stringWithFormat:@"%@\n%@\n", harnessSrc, generated];
    NSFileManager* fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:kBuildDir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString* combinedPath = [NSString stringWithFormat:@"%@/%@.combined.asm", kBuildDir, name];
    NSString* xexPath = [NSString stringWithFormat:@"%@/%@.xex", kBuildDir, name];
    NSString* outPath = [NSString stringWithFormat:@"%@/%@.out", kBuildDir, name];
    [combined writeToFile:combinedPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    int rc = 0;
    if (!runProcess(XCBIN("xcc-as"),
                    @[ @"-L", @"support/xt6502/layouts/xt.lnk",
                       @"-o", xexPath, combinedPath ],
                    nil, &rc) ||
        rc != 0)
        {
        fprintf(stderr, "  FAIL [%s]: xta failed (rc=%d). See %s\n",
                name.UTF8String, rc, combinedPath.UTF8String);
        return 1;
        }
    NSString* errPath = [NSString stringWithFormat:@"%@/%@.err", kBuildDir, name];
    if (!runProcessErr(XCBIN("xcc-sim-6502"),
                       @[ @"-m", @"xt", @"-d", xexPath ], outPath, errPath, &rc) ||
        xtsAborted(errPath))
        {
        fprintf(stderr, "  FAIL [%s]: xts aborted (rc=%d). See %s\n",
                name.UTF8String, rc, xexPath.UTF8String);
        return 1;
        }
    NSString* actual = trimTrailing(readFile(outPath));
    NSString* expected = trimTrailing(readFile(expectedPath));
    if (![actual isEqualToString:expected])
        {
        fprintf(stderr, "  FAIL [%s]: stdout differs\n    expected: '%s'\n    actual:   '%s'\n",
                name.UTF8String, expected.UTF8String, actual.UTF8String);
        return 1;
        }
    return 0;
    }

int runXT6502CodegenTests(void)
    {
    fprintf(stderr, "  XT6502CodegenTests\n");
    NSArray<NSString*>* fixtures = fixtureNames();
    int total = (int)fixtures.count + 1; // + the banked-xcall golden
    int failures = 0;
    for (NSString* n in fixtures)
        failures += runFixture(n);
    failures += runBankedGolden();
    if (failures == 0)
        {
        fprintf(stderr, "  PASS (%d/%d fixtures)\n", total - failures, total);
        }
    else
        {
        fprintf(stderr, "  FAIL summary: %d/%d fixtures pass\n", total - failures, total);
        }
    return failures;
    }
