// XTWasmCodegenTests.m — Layer-4 cross-backend equivalence on wasm32.
//
// For each fixture <name>:
//   tests/ir-codegen-wasm32/<name>.xc            — self-contained xtc source
//   tests/ir-codegen-wasm32/<name>.expected.out  — stdout oracle
//
// Pipeline:
//   1. lex+parse+sema      (frontend, wasm32 widths: ptr 4, IEEE f32, cap 8)
//   2. XTIRLowering        (AST → IR)
//   3. XTWasmBackend       (IR → WAT text)
//   4. XTWasmWriter        (WAT → .wasm binary — the in-house encoder)
//   5. node runner.js <name>.wasm, capture stdout
//   6. diff stdout against .expected.out
//
// The fixtures avoid the standard library on purpose: output goes through a
// single bodyless `extern void putw(i32)` — which doubles as coverage for
// the env-import path. Skips cleanly (with a note) when node is absent.
#import <Foundation/Foundation.h>
#import "XTLexer.h"
#import "XTParser.h"
#import "XTSemanticAnalyzer.h"
#import "XTDiagnosticEngine.h"
#import "XTTypeTable.h"
#import "XTDeclNodes.h"
#import "XTIR.h"
#import "XTWasmBackend.h"
#import "XTWasmWriter.h"
#import "XTPointerType.h"
#import "XTStructType.h"

static NSString* const kBuildDir = @"build/wasm32-fixtures";
static NSString* const kFixtureDir = @"tests/ir-codegen-wasm32";

static NSArray<NSString*>* fixtureNames(void)
    {
    NSArray* all = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:kFixtureDir
                            error:NULL];
    if (!all)
        return @[];
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    for (NSString* n in all)
        if ([n hasSuffix:@".xc"])
            [names addObject:n.stringByDeletingPathExtension];
    return [names sortedArrayUsingSelector:@selector(compare:)];
    }

static NSString* readFile(NSString* path)
    {
    return [NSString stringWithContentsOfFile:path
                                     encoding:NSUTF8StringEncoding
                                        error:NULL];
    }

static BOOL runProcess(NSString* exe, NSArray<NSString*>* args,
                       NSString* stdoutPath, int* exitCodeOut)
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

static NSString* nodePath(void)
    {
    for (NSString* p in @[ @"/opt/homebrew/bin/node", @"/usr/local/bin/node",
                           @"/usr/bin/node" ])
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:p])
            return p;
    return nil;
    }

static int runFixture(NSString* name, NSString* node)
    {
    NSString* src = [NSString stringWithFormat:@"%@/%@.xc", kFixtureDir, name];
    NSString* expected = [NSString stringWithFormat:@"%@/%@.expected.out",
                                                    kFixtureDir, name];
    NSString* source = readFile(src);
    if (!source)
        {
        fprintf(stderr, "  FAIL [%s]: cannot read %s\n",
                name.UTF8String, src.UTF8String);
        return 1;
        }
    // Configure the front end EXACTLY as the driver does for wasm32:
    // 4-byte pointers, IEEE f32, field-alignment cap 8. The backend reads
    // struct offsets verbatim from the IR layout (type-width invariant).
    [XTPointerType setHeapPointerWidth:4];
    [XTType setFloatWidth:4];
    [XTType setFloatIsIEEE:YES];
    [XTStructType setFieldAlignmentCap:8];
    XTDiagnosticEngine* diag = [[XTDiagnosticEngine alloc] init];
    XTLexer* lexer = [[XTLexer alloc] initWithSource:source
                                            filename:src.lastPathComponent
                                         diagnostics:diag];
    NSArray<XTToken*>* tokens = [lexer tokenise];
    XTTypeTable* tt = [[XTTypeTable alloc] init];
    XTParser* parser = [[XTParser alloc] initWithTokens:tokens
                                              typeTable:tt
                                            diagnostics:diag];
    XTProgramNode* ast = [parser parse];
    if (!ast || diag.hasFatalError)
        {
        fprintf(stderr, "  FAIL [%s]: frontend error\n", name.UTF8String);
        return 1;
        }
    XTSemanticAnalyzer* sema =
        [[XTSemanticAnalyzer alloc] initWithTypeTable:tt
                                          diagnostics:diag];
    sema.allocator = @"heap"; // wasm32's default (free-list; `delete` legal)
    [sema analyzeProgram:ast];
    if (diag.hasFatalError)
        {
        fprintf(stderr, "  FAIL [%s]: sema error\n", name.UTF8String);
        for (XTDiagnostic* d in diag.diagnostics)
            fprintf(stderr, "    %s\n", d.message.UTF8String);
        return 1;
        }
    XTIRModule* mod = [XTIRLowering lowerProgram:ast
                                      moduleName:name
                                     diagnostics:diag];
    if (!mod || diag.hasFatalError)
        {
        fprintf(stderr, "  FAIL [%s]: lowering error\n", name.UTF8String);
        return 1;
        }
    NSArray<NSString*>* vErrs = nil;
    if (![XTIRVerifier verifyModule:mod errors:&vErrs])
        {
        fprintf(stderr, "  FAIL [%s]: lowered IR fails verifier\n",
                name.UTF8String);
        for (NSString* e in vErrs)
            fprintf(stderr, "    %s\n", e.UTF8String);
        return 1;
        }
    NSString* wat = [XTWasmBackend assemblyFromModule:mod];
    NSError* werr = nil;
    NSData* bytes = [XTWasmWriter wasmModuleFromWat:wat error:&werr];
    if (!bytes)
        {
        fprintf(stderr, "  FAIL [%s]: writer: %s\n", name.UTF8String,
                werr.localizedDescription.UTF8String ?: "(no detail)");
        return 1;
        }

    NSFileManager* fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:kBuildDir
        withIntermediateDirectories:YES
                         attributes:nil
                              error:NULL];
    NSString* watPath = [NSString stringWithFormat:@"%@/%@.wat", kBuildDir, name];
    NSString* wasmPath = [NSString stringWithFormat:@"%@/%@.wasm", kBuildDir, name];
    NSString* outPath = [NSString stringWithFormat:@"%@/%@.out", kBuildDir, name];
    [wat writeToFile:watPath
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:NULL];
    if (![bytes writeToFile:wasmPath atomically:YES])
        {
        fprintf(stderr, "  FAIL [%s]: cannot write %s\n",
                name.UTF8String, wasmPath.UTF8String);
        return 1;
        }

    int rc = 0;
    [fm removeItemAtPath:outPath error:NULL];
    if (!runProcess(node, @[ [kFixtureDir stringByAppendingString:@"/runner.js"],
                             wasmPath ],
                    outPath, &rc) ||
        rc != 0)
        {
        fprintf(stderr, "  FAIL [%s]: node exited rc=%d (see %s)\n",
                name.UTF8String, rc, watPath.UTF8String);
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
        fprintf(stderr, "    actual:   %s", actual.UTF8String ?: "(none)\n");
        return 1;
        }
    return 0;
    }

int runWasmCodegenTests(void)
    {
    fprintf(stderr, "  XTWasmCodegenTests\n");
    NSString* node = nodePath();
    if (!node)
        {
        fprintf(stderr, "  SKIP: node not found (fixtures need a JS host)\n");
        return 0;
        }
    NSArray<NSString*>* fixtures = fixtureNames();
    int total = (int)fixtures.count;
    int failures = 0;
    for (NSString* n in fixtures)
        failures += runFixture(n, node);
    if (failures == 0)
        fprintf(stderr, "  PASS (%d/%d fixtures)\n", total - failures, total);
    else
        fprintf(stderr, "  FAIL summary: %d/%d fixtures pass\n",
                total - failures, total);
    return failures;
    }
