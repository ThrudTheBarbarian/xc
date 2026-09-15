#import <Foundation/Foundation.h>
#import "XTDiagnosticEngine.h"
#import "XTIRModule.h"
#import "XTIRParser.h"
#import "XTIROptPipeline.h"
#import "XTIROptDeadFunctionElim.h"
#import "XTIROptTargetProfile.h"
#import "XTIRPrinter.h"
#import "XTX86_64Backend.h"
#import "XTCommandLineOptions.h"

// xtcg-x86_64 — IR → x86-64 (System V AMD64) .s code generator for Linux.
// Sibling of xtcg-arm64 / xtcg-arm9 / xtcg-6502 / xtcg-68k.
//
// Reads a text-format IR module (from xtc-fe), runs the XTIROptPipeline at the
// requested -O level (base/conservative profile during bring-up), emits x86-64
// assembly via XTX86_64Backend, and writes .s. The driver assembles + links it
// with the musl cross-clang + ld.lld (static x86-64 ELF) — see linkX86_64.
//
// Usage:
//   xtcg-x86_64 [-O0..-O3] [-o out.s] input.ir

#ifndef XTC_VERSION
#define XTC_VERSION "0.0"
#endif

static void usage(void)
    {
    fprintf(stderr,
            "Usage: xtcg-x86_64 [options] <input.ir>\n"
            "\n"
            "Options:\n"
            "  -o <path>             Output .s path (stdout if omitted).\n"
            "  -O0..-O3              IR opt-pass level.\n"
            "  -q, --quiet           Suppress informational stderr.\n"
            "  --dump-opt-ir         Print the IR after the opt pipeline and stop.\n"
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
        // -1 = decide from the module (the default), 0 = off, 1 = on.
        int threadSafeARC = -1;
        BOOL dumpOptIR = NO;

        for (int i = 1; i < argc; i++)
            {
            NSString* arg = @(argv[i]);
            if ([arg isEqualToString:@"-v"] || [arg isEqualToString:@"--version"])
                {
                printf("xtcg-x86_64 %s\n", XTC_VERSION);
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
            else if ([arg isEqualToString:@"-q"] || [arg isEqualToString:@"--quiet"])
                {
                quiet = YES;
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
                [XTIROptDeadFunctionElim setKeepAllFunctions:YES]; // keep it all
                }
            else if ([arg isEqualToString:@"--thread-safe-arc"])
                {
                threadSafeARC = 1;
                }
            else if ([arg isEqualToString:@"--no-thread-safe-arc"])
                {
                threadSafeARC = 0;
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
                fprintf(stderr, "xcc-cg-x86_64: unknown option '%s'\n", argv[i]);
                usage();
                return 1;
                }
            else
                {
                if (inputPath)
                    {
                    fprintf(stderr, "xcc-cg-x86_64: multiple inputs not supported\n");
                    return 1;
                    }
                inputPath = arg;
                }
            }
        if (!inputPath)
            {
            fprintf(stderr, "xcc-cg-x86_64: error: no input file\n");
            usage();
            return 1;
            }

        NSString* irText = [NSString stringWithContentsOfFile:inputPath
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
        if (!irText)
            {
            fprintf(stderr, "xcc-cg-x86_64: cannot read '%s'\n", inputPath.UTF8String);
            return 1;
            }

        NSError* parseError = nil;
        XTIRModule* mod = [XTIRParser moduleFromString:irText error:&parseError];
        if (!mod)
            {
            fprintf(stderr, "xcc-cg-x86_64: IR parse failed: %s\n",
                    parseError ? parseError.localizedDescription.UTF8String : "(no detail)");
            return 1;
            }

            {
            // Always run the pipeline (even -O0): the VaArgExpand pass lowers the
            // abstract VaStart/VaArg → __xtc_va_buf and runs unconditionally; the
            // backend has no case for the abstract ops. The level gates the rest.
            XTIROptPipeline* pipe =
                [XTIROptPipeline standardPipelineAtLevel:optLevel
                                                 profile:[XTIRX86_64TargetProfile new]];
            pipe.traceToStderr = !quiet;
            NSMutableArray<NSString*>* poErrs = nil;
            if (![pipe runOnModule:mod errors:&poErrs])
                {
                fprintf(stderr, "xcc-cg-x86_64: IR opt pipeline failed:\n");
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
                    fprintf(stderr, "xcc-cg-x86_64: cannot write '%s'\n", outputPath.UTF8String);
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
            fputs([XTIRPrinter stringFromModule:mod].UTF8String, stderr);

        // Thread-safe ARC: the backend decides per module (threading.md §4.1);
        // this only forwards an explicit -f[no-]thread-safe-arc.
        [XTX86_64Backend setThreadSafeARCOverride:threadSafeARC];
        NSString* asmText = [XTX86_64Backend assemblyFromModule:mod];
        if (!asmText)
            {
            fprintf(stderr, "xcc-cg-x86_64: backend produced no output\n");
            return 1;
            }

        if (outputPath)
            {
            NSError* err = nil;
            [asmText writeToFile:outputPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
            if (err)
                {
                fprintf(stderr, "xcc-cg-x86_64: cannot write '%s': %s\n",
                        outputPath.UTF8String, err.localizedDescription.UTF8String);
                return 1;
                }
            if (!quiet)
                fprintf(stderr, "xcc-cg-x86_64: x86-64 asm -> '%s'\n", outputPath.UTF8String);
            }
        else
            {
            fputs(asmText.UTF8String, stdout);
            }
        return 0;
        }
    }
