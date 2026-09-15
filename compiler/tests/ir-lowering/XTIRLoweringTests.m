// XTIRLoweringTests.m — Layer-3-style fixture runner for the AST → IR
// lowering.
//
// For each `*.xc` source under tests/ir-lowering/, run the existing
// frontend (lexer → parser → sema), lower via XTIRLowering, print
// the resulting IR, and diff against the matching `*.expected.ir`.
// Every lowered module must additionally pass `XTIRVerifier`.
//
// Set XTIR_GENERATE=1 to overwrite each .expected.ir from the
// current printer output — useful for bootstrap and intentional
// printer changes. The CI / default run treats a divergence as
// failure.
#import <Foundation/Foundation.h>
#import "XTLexer.h"
#import "XTParser.h"
#import "XTSemanticAnalyzer.h"
#import "XTDiagnosticEngine.h"
#import "XTTypeTable.h"
#import "XTDeclNodes.h"
#import "XTIR.h"

static NSArray<NSString*>* fixturesIn(NSString* dir)
    {
    NSError* err = nil;
    NSArray* all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:&err];
    if (!all)
        return @[];
    NSMutableArray<NSString*>* out = [NSMutableArray array];
    for (NSString* n in all)
        {
        if ([n hasSuffix:@".xc"])
            [out addObject:[dir stringByAppendingPathComponent:n]];
        }
    return [out sortedArrayUsingSelector:@selector(compare:)];
    }

static int runFixture(NSString* path)
    {
    NSString* base = path.lastPathComponent;
    NSString* source = [NSString stringWithContentsOfFile:path
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
    if (!source)
        {
        fprintf(stderr, "  FAIL [%s]: cannot read source\n", base.UTF8String);
        return 1;
        }
    XTDiagnosticEngine* diag = [[XTDiagnosticEngine alloc] init];
    XTLexer* lexer = [[XTLexer alloc] initWithSource:source filename:base diagnostics:diag];
    NSArray<XTToken*>* tokens = [lexer tokenise];
    XTTypeTable* tt = [[XTTypeTable alloc] init];
    XTParser* parser = [[XTParser alloc] initWithTokens:tokens typeTable:tt diagnostics:diag];
    XTProgramNode* ast = [parser parse];
    if (!ast || diag.hasFatalError)
        {
        fprintf(stderr, "  FAIL [%s]: frontend (lex/parse) error\n", base.UTF8String);
        return 1;
        }
    XTSemanticAnalyzer* sema = [[XTSemanticAnalyzer alloc] initWithTypeTable:tt diagnostics:diag];
    [sema analyzeProgram:ast];
    if (diag.hasFatalError)
        {
        fprintf(stderr, "  FAIL [%s]: sema error\n", base.UTF8String);
        return 1;
        }

    NSString* moduleName = [base stringByDeletingPathExtension];
    XTIRModule* mod = [XTIRLowering lowerProgram:ast moduleName:moduleName diagnostics:diag];
    if (!mod || diag.hasFatalError)
        {
        fprintf(stderr, "  FAIL [%s]: lowering error\n", base.UTF8String);
        for (XTDiagnostic* d in diag.diagnostics)
            {
            if (d.level >= 2)
                {
                fprintf(stderr, "    %s\n", d.message.UTF8String);
                }
            }
        return 1;
        }

    NSArray<NSString*>* vErrs = nil;
    if (![XTIRVerifier verifyModule:mod errors:&vErrs])
        {
        fprintf(stderr, "  FAIL [%s]: verifier rejected lowered module:\n", base.UTF8String);
        for (NSString* e in vErrs)
            fprintf(stderr, "    %s\n", e.UTF8String);
        return 1;
        }

    NSString* actual = [XTIRPrinter stringFromModule:mod];
    NSString* expectedPath = [[path stringByDeletingPathExtension]
        stringByAppendingPathExtension:@"expected.ir"];

    if (getenv("XTIR_GENERATE"))
        {
        [actual writeToFile:expectedPath
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:NULL];
        fprintf(stderr, "  GEN  [%s]: wrote %s\n", base.UTF8String,
                expectedPath.lastPathComponent.UTF8String);
        return 0;
        }

    NSString* expected = [NSString stringWithContentsOfFile:expectedPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    if (!expected)
        {
        fprintf(stderr, "  FAIL [%s]: missing %s (run with XTIR_GENERATE=1 to bootstrap)\n",
                base.UTF8String, expectedPath.lastPathComponent.UTF8String);
        fprintf(stderr, "  --- actual ---\n%s---\n", actual.UTF8String);
        return 1;
        }
    if (![actual isEqualToString:expected])
        {
        fprintf(stderr, "  FAIL [%s]: lowered IR differs from %s\n",
                base.UTF8String, expectedPath.lastPathComponent.UTF8String);
        fprintf(stderr, "  --- expected ---\n%s", expected.UTF8String);
        fprintf(stderr, "  --- actual   ---\n%s---\n", actual.UTF8String);
        return 1;
        }
    return 0;
    }

int runIRLoweringTests(void)
    {
    fprintf(stderr, "  XTIRLoweringTests\n");
    NSArray<NSString*>* fixtures = fixturesIn(@"tests/ir-lowering");
    int total = (int)fixtures.count;
    int failures = 0;
    for (NSString* p in fixtures)
        {
        failures += runFixture(p);
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
