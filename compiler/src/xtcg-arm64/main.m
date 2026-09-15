#import <Foundation/Foundation.h>
#import "XTDiagnosticEngine.h"
#import "XTIRModule.h"
#import "XTIRParser.h"
#import "XTIROptPipeline.h"
#import "XTIROptTargetProfile.h"
#import "XTIROptDeadFunctionElim.h"
#import "XTIRPrinter.h"
#import "XTArm64Backend.h"
#import "XTCommandLineOptions.h"

// xtcg-arm64 — IR → arm64 (.s) code generator.
//
// Reads a text-format IR module (produced by xtc-fe or the new-IR
// driver with --emit-ir), runs the XTIROptPipeline at the requested
// -O level, emits arm64 assembly via XTArm64Backend, and writes .s.
//
// Sibling of xtcg-6502; adding a future xtcg-m68k is the same pattern.
// arm64 has no runtime-wrapping step here — the user supplies main()
// in source and the host C runtime (libc, libxt.a, …) is linked at
// the clang step by the caller (xtc when -o is a binary).
//
// Usage:
//   xtcg-arm64 [-O0..-O3] [-o output.s] input.ir

#ifndef XTC_VERSION
#define XTC_VERSION "0.0"
#endif

static void usage(void)
    {
    fprintf(stderr,
            "Usage: xtcg-arm64 [options] <input.ir>\n"
            "\n"
            "Options:\n"
            "  -o <path>             Output .s path.\n"
            "  -O0..-O3              IR opt-pass level.\n"
            "  -q, --quiet           Suppress informational stderr.\n"
            "  --dump-opt-ir         Print the IR after the opt pipeline and stop.\n"
            "  --no-lse-atomics      The target has no ARMv8.1 LSE: emit atomic ARC\n"
            "                        as an ldaxrh/stlxrh loop (Android).\n"
            "  --aapcs64-abi         Use plain AAPCS64 argument placement (Android)\n"
            "                        rather than Darwin's variadic-tail and packed\n"
            "                        stack-slot deviations.\n"
            "  --thread-safe-arc     Force atomic ARC retain/release.\n"
            "  --no-thread-safe-arc  Force plain (non-atomic) ARC retain/release.\n"
            "                        Default: atomic iff the module spawns a thread.\n"
            "  -v, --version         Print version and exit.\n");
    }

int main(int argc, const char* argv[])
    {
    @autoreleasepool
        {
        // Record argv[0] so the support tree is found relative to THIS binary.
        // An installed tool must not depend on the current directory to find
        // its own libraries.
        [XTCommandLineOptions setExecutablePath:argv[0]];
        NSString* inputPath = nil;
        NSString* outputPath = nil;
        NSInteger optLevel = 0;
        BOOL quiet = NO;
        BOOL dumpOptIR = NO;
        // -1 = decide from the module (the default), 0 = off, 1 = on.
        int threadSafeARC = -1;
        BOOL aapcs64Abi = NO;
        BOOL lseAtomics = YES;

        for (int i = 1; i < argc; i++)
            {
            NSString* arg = @(argv[i]);
            if ([arg isEqualToString:@"-v"] || [arg isEqualToString:@"--version"])
                {
                printf("xtcg-arm64 %s\n", XTC_VERSION);
                return 0;
                }
            else if ([arg isEqualToString:@"-h"] || [arg isEqualToString:@"--help"])
                {
                usage();
                return 0;
                }
            else if ([arg isEqualToString:@"-o"] && i + 1 < argc)
                {
                outputPath = @(argv[++i]);
                }
            else if ([arg isEqualToString:@"-O0"])
                {
                optLevel = 0;
                }
            else if ([arg isEqualToString:@"-O"] || [arg isEqualToString:@"-O1"])
                {
                optLevel = 1;
                }
            else if ([arg isEqualToString:@"-O2"])
                {
                optLevel = 2;
                }
            else if ([arg isEqualToString:@"-O3"])
                {
                optLevel = 3;
                }
            else if ([arg isEqualToString:@"--object"])
                {
                // -c: this module is an OBJECT, so every function it defines is
                // part of its surface — something in another object may call it.
                // Without this, cross-function DCE deletes anything the module
                // does not itself call, and a helper compiled alone yields a .o
                // with no symbols at all. Same switch as library mode, same
                // reason: the module boundary is not the program boundary.
                [XTIROptDeadFunctionElim setKeepAllFunctions:YES];
                }
            else if ([arg isEqualToString:@"--emit-lib"])
                {
                // Library build: this module IS a shared library, so its public
                // API is reachable from outside even though nothing here calls
                // it. Keep every function (the backend already emits `.globl`
                // for each, so they export). Same arch-neutral switch the arm9
                // codegen uses.
                [XTIROptDeadFunctionElim setKeepAllFunctions:YES];
                }
            else if ([arg isEqualToString:@"--no-lse-atomics"])
                {
                // The target does not guarantee ARMv8.1 LSE (Android's floor is
                // armv8-a): emit exclusive-load/store loops instead.
                lseAtomics = NO;
                }
            else if ([arg isEqualToString:@"--aapcs64-abi"])
                {
                // Non-Darwin AArch64 (Android): plain AAPCS64 argument
                // placement, without Darwin's variadic-tail and packed-stack-
                // slot deviations.
                aapcs64Abi = YES;
                }
            else if ([arg isEqualToString:@"--thread-safe-arc"])
                {
                threadSafeARC = 1;
                }
            else if ([arg isEqualToString:@"--no-thread-safe-arc"])
                {
                threadSafeARC = 0;
                }
            else if ([arg isEqualToString:@"-q"] || [arg isEqualToString:@"--quiet"])
                {
                quiet = YES;
                }
            else if ([arg isEqualToString:@"--dump-opt-ir"])
                {
                // The IR AFTER the opt pipeline, as text — the differential
                // oracle for the ported optimiser (selfhost/opt). Nothing is
                // generated: print(opt(parse(text))) is the whole run.
                dumpOptIR = YES;
                }
            else if ([arg hasPrefix:@"-"])
                {
                fprintf(stderr, "xcc-cg-arm64: unknown option '%s'\n", argv[i]);
                usage();
                return 1;
                }
            else
                {
                if (inputPath)
                    {
                    fprintf(stderr, "xcc-cg-arm64: multiple inputs not supported\n");
                    return 1;
                    }
                inputPath = arg;
                }
            }
        if (!inputPath)
            {
            fprintf(stderr, "xcc-cg-arm64: error: no input file\n");
            usage();
            return 1;
            }

        NSString* irText = [NSString stringWithContentsOfFile:inputPath
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
        if (!irText)
            {
            fprintf(stderr, "xcc-cg-arm64: cannot read '%s'\n", inputPath.UTF8String);
            return 1;
            }
        NSError* parseError = nil;
        XTIRModule* mod = [XTIRParser moduleFromString:irText
                                                 error:&parseError];
        if (!mod)
            {
            fprintf(stderr, "xcc-cg-arm64: IR parse failed: %s\n",
                    parseError ? parseError.localizedDescription.UTF8String : "(no detail)");
            return 1;
            }

            {
            // Always run the pipeline (even -O0): the VaArgExpand pass lowers the
            // abstract VaStart/VaArg → __xtc_va_buf and is MANDATORY (the backend
            // has no case for the abstract ops). Skipping the pipeline at -O0 left
            // every variadic callee reading unlowered ops → args arrived as 0
            // (bug 014). The per-pass minOptLevel filter keeps the real
            // optimisations off at -O0.
            XTIROptPipeline* pipe =
                [XTIROptPipeline standardPipelineAtLevel:optLevel
                                                 profile:[XTIRArm64TargetProfile new]];
            pipe.traceToStderr = !quiet;
            NSMutableArray<NSString*>* poErrs = nil;
            if (![pipe runOnModule:mod errors:&poErrs])
                {
                fprintf(stderr, "xcc-cg-arm64: IR opt pipeline failed:\n");
                for (NSString* e in poErrs)
                    fprintf(stderr, "  %s\n", e.UTF8String);
                return 1;
                }
            }

        if (dumpOptIR)
            {

            NSString* t = [XTIRPrinter stringFromModule:mod];

            if (outputPath)
                {

                NSError* err = nil;

                [t writeToFile:outputPath atomically:YES encoding:NSUTF8StringEncoding error:&err];

                if (err)
                    {
                    fprintf(stderr, "xcc-cg-arm64: cannot write '%s'\n", outputPath.UTF8String);
                    return 1;
                    }
                }
            else
                {

                fputs(t.UTF8String, stdout);
                }

            return 0;
            }

        if (getenv("XTIR_DUMP_OPT"))
            {
            fputs([XTIRPrinter stringFromModule:mod].UTF8String, stderr);
            }

        // Thread-safe ARC: the backend decides per module (atomic exactly when
        // the program spawns a thread — threading.md §4.1); this only forwards
        // an explicit -fthread-safe-arc / -fno-thread-safe-arc.
        [XTArm64Backend setThreadSafeARCOverride:threadSafeARC];
        [XTArm64Backend setAapcs64Abi:aapcs64Abi];
        [XTArm64Backend setLseAtomics:lseAtomics];

        NSString* asmText = nil;
        @try
            {
            asmText = [XTArm64Backend assemblyFromModule:mod];
            if (!quiet && [XTArm64Backend threadSafeARC] && threadSafeARC < 0)
                fprintf(stderr, "xcc-cg-arm64: thread-safe (atomic) ARC enabled — the module spawns threads\n");
            }
        @catch (NSException* e)
            {
            if ([e.name isEqualToString:@"XTFrameBudgetExceeded"])
                {
                fprintf(stderr, "xcc-cg-arm64: error: %s\n", e.reason.UTF8String);
                return 1;
                }
            @throw;
            }
        if (!asmText)
            {
            fprintf(stderr, "xcc-cg-arm64: backend produced no output\n");
            return 1;
            }

        if (outputPath)
            {
            NSError* err = nil;
            [asmText writeToFile:outputPath
                      atomically:YES
                        encoding:NSUTF8StringEncoding
                           error:&err];
            if (err)
                {
                fprintf(stderr, "xcc-cg-arm64: cannot write '%s': %s\n",
                        outputPath.UTF8String, err.localizedDescription.UTF8String);
                return 1;
                }
            if (!quiet)
                {
                fprintf(stderr, "xcc-cg-arm64: arm64 asm -> '%s'\n", outputPath.UTF8String);
                }
            }
        else
            {
            fputs(asmText.UTF8String, stdout);
            }
        return 0;
        }
    }
