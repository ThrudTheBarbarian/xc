// XTArm64CodegenTests.m — Layer-4 cross-backend equivalence on arm64.
//
// For each fixture <name>:
//   tests/ir-lowering/<name>.xc    — xtc source (shared with lowering tests)
//   tests/ir-codegen-arm64/<name>.stub.c   — C harness with main()
//   tests/ir-codegen-arm64/<name>.expected.out  — stdout oracle
//
// Pipeline:
//   1. lex+parse+sema   (frontend)
//   2. XTIRLowering     (AST → IR)
//   3. XTArm64Backend   (IR → .s text)
//   4. assemble+link stub.c + gen.s -> build/arm64-fixtures/<name>
//        macOS: clang -arch arm64          Linux: the NDK's cross clang,
//        after rewriting the Mach-O asm dialect to ELF
//   5. run the binary, capture stdout
//        macOS: exec it                    Linux: qemu-aarch64 -L <sysroot>
//   6. diff stdout against .expected.out
#import <Foundation/Foundation.h>
#import "XTLexer.h"
#import "XTParser.h"
#import "XTSemanticAnalyzer.h"
#import "XTDiagnosticEngine.h"
#import "XTTypeTable.h"
#import "XTDeclNodes.h"
#import "XTIR.h"
#import "XTArm64Backend.h"
#import "XTPointerType.h"
#import "XTStructType.h"
#import "XTMachOToElfArm64.h"
#import "XTArm64HostTools.h"

static NSString* const kBuildDir = @"build/arm64-fixtures";
static NSString* const kSourceDir = @"tests/ir-lowering";
static NSString* const kFixtureDir = @"tests/ir-codegen-arm64";

static NSArray<NSString*>* fixtureNames(void)
    {
    // Mirror the four lowering fixtures; the stubs live alongside.
    NSError* err = nil;
    NSArray* all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kFixtureDir error:&err];
    if (!all)
        return @[];
    NSMutableSet<NSString*>* names = [NSMutableSet set];
    for (NSString* n in all)
        {
        if ([n hasSuffix:@".stub.c"])
            {
            [names addObject:[n stringByReplacingOccurrencesOfString:@".stub.c" withString:@""]];
            }
        }
    return [names.allObjects sortedArrayUsingSelector:@selector(compare:)];
    }

static NSString* readFile(NSString* path)
    {
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    }

static BOOL runProcess(NSString* exe, NSArray<NSString*>* args,
                       NSString* stdoutPath, int* exitCodeOut)
    {
    NSTask* task = [[NSTask alloc] init];
    task.launchPath = exe;
    task.arguments = args;
    if (stdoutPath)
        {
        NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:stdoutPath];
        if (!fh)
            {
            [[NSFileManager defaultManager] createFileAtPath:stdoutPath contents:[NSData data] attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:stdoutPath];
            }
        task.standardOutput = fh;
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
        return NO;
        }
    }

static int runFixture(NSString* name)
    {
    NSString* src = [NSString stringWithFormat:@"%@/%@.xc", kSourceDir, name];
    NSString* stub = [NSString stringWithFormat:@"%@/%@.stub.c", kFixtureDir, name];
    NSString* expected = [NSString stringWithFormat:@"%@/%@.expected.out", kFixtureDir, name];

    NSString* source = readFile(src);
    if (!source)
        {
        fprintf(stderr, "  FAIL [%s]: cannot read %s\n",
                name.UTF8String, src.UTF8String);
        return 1;
        }
    // Configure the front end EXACTLY as the driver does for arm64 (8-byte
    // pointers, IEEE f32, field-alignment cap 8). The backend reads struct
    // offsets verbatim from the IR layout, so lowering with the default
    // (2-byte-pointer, packed) widths would record offsets the 8-byte
    // stores then overrun — the harness used to get away with it only
    // because the backend re-derived offsets from its own widths.
    [XTPointerType setHeapPointerWidth:8];
    [XTType setFloatWidth:4];
    [XTType setFloatIsIEEE:YES];
    [XTStructType setFieldAlignmentCap:8];
    XTDiagnosticEngine* diag = [[XTDiagnosticEngine alloc] init];
    XTLexer* lexer = [[XTLexer alloc] initWithSource:source
                                            filename:src.lastPathComponent
                                         diagnostics:diag];
    NSArray<XTToken*>* tokens = [lexer tokenise];
    XTTypeTable* tt = [[XTTypeTable alloc] init];
    XTParser* parser = [[XTParser alloc] initWithTokens:tokens typeTable:tt diagnostics:diag];
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
        fprintf(stderr, "  FAIL [%s]: lowered IR fails verifier\n", name.UTF8String);
        for (NSString* e in vErrs)
            fprintf(stderr, "    %s\n", e.UTF8String);
        return 1;
        }
    NSString* asmText = [XTArm64Backend assemblyFromModule:mod];

    NSFileManager* fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:kBuildDir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString* asmPath = [NSString stringWithFormat:@"%@/%@.s", kBuildDir, name];
    NSString* binPath = [NSString stringWithFormat:@"%@/%@", kBuildDir, name];
    NSString* outPath = [NSString stringWithFormat:@"%@/%@.out", kBuildDir, name];

    // The backend emits MACH-O flavoured asm: `_sa`, @PAGE/@PAGEOFF. An ELF
    // toolchain reads that as a symbol named `_sa` and then cannot find `sa`,
    // so every fixture died at link with `undefined symbol`. Same rewrite the
    // compiler applies for -A android, from the same source — see
    // link/XTMachOToElfArm64.h.
    if (XTArm64NeedsElfDialect())
        asmText = XTMachOToElfArm64(asmText);

    NSError* werr = nil;
    if (![asmText writeToFile:asmPath atomically:YES encoding:NSUTF8StringEncoding error:&werr])
        {
        fprintf(stderr, "  FAIL [%s]: cannot write %s: %s\n",
                name.UTF8String, asmPath.UTF8String, werr.localizedDescription.UTF8String);
        return 1;
        }

    // Assemble + link the fixture for arm64, then run it.
    //
    // On macOS this is `clang -arch arm64` and a direct exec, because the host
    // IS arm64. On Linux neither half works as written: `-arch` is a Darwin
    // driver flag, the host clang targets x86-64 (it rejects the asm outright —
    // "invalid instruction mnemonic 'uxtb'"), and nothing here executes arm64
    // anyway.
    //
    // But the arm64 ISA is not actually Mac-bound. The NDK's cross clang emits
    // aarch64 ELF against bionic and qemu-aarch64 runs it, which exercises the
    // SAME backend output this test exists to check — what stays Mac-only is
    // the macOS platform surface (Mach-O, dyld, dSYM), not instruction
    // selection. See ci/README.md.
    //
    // Both halves are overridable so the harness hardcodes no toolchain path:
    //   XC_ARM64_CC   compiler to assemble+link with
    //   XC_ARM64_RUN  launcher prefix for the result ("" = exec directly)
    int rc = 0;
    NSArray<NSString*>* base = XTArm64ClangArgv();
    NSArray<NSString*>* ccArgv = base ? [base arrayByAddingObjectsFromArray:
                                                  @[ stub, asmPath, @"-o", binPath ]]
                                      : nil;
    if (!ccArgv)
        {
        fprintf(stderr, "  FAIL [%s]: no arm64 compiler. Set $XC_ARM64_CC, or "
                        "$ANDROID_NDK_HOME for the NDK's cross clang.\n",
                name.UTF8String);
        return 1;
        }
    if (!runProcess(@"/usr/bin/env", ccArgv, nil, &rc) || rc != 0)
        {
        fprintf(stderr, "  FAIL [%s]: %s failed (rc=%d). See %s\n",
                name.UTF8String, ccArgv.firstObject.UTF8String, rc, asmPath.UTF8String);
        return 1;
        }

    // Run the binary, capturing stdout.
    [fm removeItemAtPath:outPath error:NULL];
    NSArray<NSString*>* pre = XTArm64RunPrefix();
    BOOL ok = pre
                  ? runProcess(@"/usr/bin/env",
                               [pre arrayByAddingObject:[@"./" stringByAppendingString:binPath]],
                               outPath, &rc)
                  : runProcess([@"./" stringByAppendingString:binPath], @[], outPath, &rc);
    if (!ok || rc != 0)
        {
        fprintf(stderr, "  FAIL [%s]: binary exited with rc=%d\n",
                name.UTF8String, rc);
        return 1;
        }
    NSString* actual = readFile(outPath);
    NSString* want = readFile(expected);
    if (!want)
        {
        fprintf(stderr, "  FAIL [%s]: missing %s\n",
                name.UTF8String, expected.UTF8String);
        return 1;
        }
    if (![actual isEqualToString:want])
        {
        fprintf(stderr, "  FAIL [%s]: stdout differs\n", name.UTF8String);
        fprintf(stderr, "    expected: %s", want.UTF8String);
        fprintf(stderr, "    actual:   %s", actual.UTF8String);
        return 1;
        }
    return 0;
    }

int runArm64CodegenTests(void)
    {
    fprintf(stderr, "  XTArm64CodegenTests\n");
    NSArray<NSString*>* fixtures = fixtureNames();
    int total = (int)fixtures.count;
    int failures = 0;
    for (NSString* n in fixtures)
        {
        failures += runFixture(n);
        }
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
