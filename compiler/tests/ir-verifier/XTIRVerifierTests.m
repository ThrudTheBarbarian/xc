// XTIRVerifierTests.m — Layer-2 fixture runner.
//
// Walks tests/ir-verifier/positive/*.ir and tests/ir-verifier/negative/*.ir.
// For each positive fixture: assert parse + verify succeed AND that
// parse → print → parse → print is a fixed point (round-trip).
// For each negative fixture: assert parse succeeds but verify rejects
// with at least one diagnostic citing an invariant.
#import <Foundation/Foundation.h>
#import "XTIR.h"

static NSArray<NSString*>* fixtureFilesIn(NSString* dir)
    {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSError* err = nil;
    NSArray<NSString*>* all = [fm contentsOfDirectoryAtPath:dir error:&err];
    if (!all)
        return @[];
    NSMutableArray<NSString*>* out = [NSMutableArray array];
    for (NSString* n in all)
        {
        if ([n hasSuffix:@".ir"])
            {
            [out addObject:[dir stringByAppendingPathComponent:n]];
            }
        }
    return [out sortedArrayUsingSelector:@selector(compare:)];
    }

static NSString* readFile(NSString* path)
    {
    NSError* err = nil;
    NSString* s = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:&err];
    return s;
    }

int runIRVerifierTests(void)
    {
    fprintf(stderr, "  XTIRVerifierTests\n");
    int failures = 0;
    int positiveTotal = 0, positivePass = 0;
    int negativeTotal = 0, negativePass = 0;
    int roundtripTotal = 0, roundtripPass = 0;

    NSString* posDir = @"tests/ir-verifier/positive";
    NSString* negDir = @"tests/ir-verifier/negative";

    NSArray* posFiles = fixtureFilesIn(posDir);
    NSArray* negFiles = fixtureFilesIn(negDir);

    // Positive fixtures — must parse, must verify cleanly, and must
    // round-trip (parse → print → parse → print = fixed point).
    for (NSString* path in posFiles)
        {
        positiveTotal++;
        roundtripTotal++;
        NSString* raw = readFile(path);
        if (!raw)
            {
            fprintf(stderr, "  FAIL [pos %s]: could not read file\n",
                    path.lastPathComponent.UTF8String);
            failures++;
            continue;
            }
        NSError* parseErr = nil;
        XTIRModule* m1 = [XTIRParser moduleFromString:raw error:&parseErr];
        if (!m1)
            {
            fprintf(stderr, "  FAIL [pos %s]: parse failed: %s\n",
                    path.lastPathComponent.UTF8String,
                    parseErr.localizedDescription.UTF8String);
            failures++;
            continue;
            }
        NSArray<NSString*>* vErrs = nil;
        BOOL ok = [XTIRVerifier verifyModule:m1 errors:&vErrs];
        if (!ok)
            {
            fprintf(stderr, "  FAIL [pos %s]: verifier rejected:\n",
                    path.lastPathComponent.UTF8String);
            for (NSString* e in vErrs)
                {
                fprintf(stderr, "    %s\n", e.UTF8String);
                }
            if (getenv("XTIR_VERBOSE"))
                {
                fprintf(stderr, "  --- parsed IR ---\n%s---\n",
                        [XTIRPrinter stringFromModule:m1].UTF8String);
                }
            failures++;
            continue;
            }
        positivePass++;

        // Round-trip check.
        NSString* t1 = [XTIRPrinter stringFromModule:m1];
        NSError* parseErr2 = nil;
        XTIRModule* m2 = [XTIRParser moduleFromString:t1 error:&parseErr2];
        if (!m2)
            {
            fprintf(stderr, "  FAIL [pos %s]: re-parse failed: %s\n",
                    path.lastPathComponent.UTF8String,
                    parseErr2.localizedDescription.UTF8String);
            failures++;
            continue;
            }
        NSString* t2 = [XTIRPrinter stringFromModule:m2];
        if (![t1 isEqualToString:t2])
            {
            fprintf(stderr, "  FAIL [pos %s]: round-trip differs (printer not deterministic or parser drops info)\n",
                    path.lastPathComponent.UTF8String);
            failures++;
            continue;
            }
        roundtripPass++;
        }

    // Negative fixtures — must parse, must verify reject with at
    // least one diagnostic citing a §12.N invariant.
    for (NSString* path in negFiles)
        {
        negativeTotal++;
        NSString* raw = readFile(path);
        if (!raw)
            {
            fprintf(stderr, "  FAIL [neg %s]: could not read file\n",
                    path.lastPathComponent.UTF8String);
            failures++;
            continue;
            }
        NSError* parseErr = nil;
        XTIRModule* m = [XTIRParser moduleFromString:raw error:&parseErr];
        if (!m)
            {
            fprintf(stderr, "  FAIL [neg %s]: parse failed (negative fixtures must still parse): %s\n",
                    path.lastPathComponent.UTF8String,
                    parseErr.localizedDescription.UTF8String);
            failures++;
            continue;
            }
        NSArray<NSString*>* vErrs = nil;
        BOOL ok = [XTIRVerifier verifyModule:m errors:&vErrs];
        if (ok)
            {
            fprintf(stderr, "  FAIL [neg %s]: verifier accepted, but fixture is a known violation\n",
                    path.lastPathComponent.UTF8String);
            failures++;
            continue;
            }
        // Diagnostic must cite a §12.N invariant.
        BOOL found = NO;
        for (NSString* e in vErrs)
            {
            if ([e containsString:@"§12."])
                {
                found = YES;
                break;
                }
            }
        if (!found)
            {
            fprintf(stderr, "  FAIL [neg %s]: verifier rejected but no diagnostic cited §12.N\n",
                    path.lastPathComponent.UTF8String);
            failures++;
            continue;
            }
        negativePass++;
        }

    int total = positiveTotal + negativeTotal;
    int passed = positivePass + negativePass;
    if (failures == 0)
        {
        fprintf(stderr, "  PASS (%d/%d fixtures, %d/%d round-trip)\n",
                passed, total, roundtripPass, roundtripTotal);
        }
    else
        {
        fprintf(stderr, "  FAIL summary: %d/%d fixtures pass, %d/%d round-trip\n",
                passed, total, roundtripPass, roundtripTotal);
        }
    return failures;
    }
