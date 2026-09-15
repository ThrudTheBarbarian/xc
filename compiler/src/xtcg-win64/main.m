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

// xtcg-win64 — IR → x86-64 (Win64 ABI) .s code generator for Windows.
// Sibling of xtcg-x86_64: SAME x86-64 ISA and SAME opt profile, but it selects
// the Win64 ABI on XTX86_64Backend (args in rcx/rdx/r8/r9 + 32-byte shadow
// space, PE/COFF object format — no ELF `.type … @function`). The driver
// assembles + links the .s with the mingw-w64 cross-clang into a static PE
// (.exe) — see linkWin64Executable — which runs under Wine or on Windows.
//
// Usage:
//   xtcg-win64 [-O0..-O3] [-o out.s] input.ir

#ifndef XTC_VERSION
#define XTC_VERSION "0.0"
#endif

static void usage(void)
    {
    fprintf(stderr,
            "Usage: xtcg-win64 [options] <input.ir>\n"
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
                printf("xtcg-win64 %s\n", XTC_VERSION);
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
                // with no symbols at all.
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
                fprintf(stderr, "xcc-cg-win64: unknown option '%s'\n", argv[i]);
                usage();
                return 1;
                }
            else
                {
                if (inputPath)
                    {
                    fprintf(stderr, "xcc-cg-win64: multiple inputs not supported\n");
                    return 1;
                    }
                inputPath = arg;
                }
            }
        if (!inputPath)
            {
            fprintf(stderr, "xcc-cg-win64: error: no input file\n");
            usage();
            return 1;
            }

        NSString* irText = [NSString stringWithContentsOfFile:inputPath
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
        if (!irText)
            {
            fprintf(stderr, "xcc-cg-win64: cannot read '%s'\n", inputPath.UTF8String);
            return 1;
            }

        NSError* parseError = nil;
        XTIRModule* mod = [XTIRParser moduleFromString:irText error:&parseError];
        if (!mod)
            {
            fprintf(stderr, "xcc-cg-win64: IR parse failed: %s\n",
                    parseError ? parseError.localizedDescription.UTF8String : "(no detail)");
            return 1;
            }

            {
            // The x86-64 profile applies — same ISA, same opt passes. Only the
            // backend ABI/object-format differs, selected below.
            XTIROptPipeline* pipe =
                [XTIROptPipeline standardPipelineAtLevel:optLevel
                                                 profile:[XTIRX86_64TargetProfile new]];
            pipe.traceToStderr = !quiet;
            NSMutableArray<NSString*>* poErrs = nil;
            if (![pipe runOnModule:mod errors:&poErrs])
                {
                fprintf(stderr, "xcc-cg-win64: IR opt pipeline failed:\n");
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
                    fprintf(stderr, "xcc-cg-win64: cannot write '%s'\n", outputPath.UTF8String);
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

        [XTX86_64Backend setWin64ABI:YES];
        // Thread-safe ARC: the backend decides per module (threading.md §4.1);
        // this only forwards an explicit -f[no-]thread-safe-arc.
        [XTX86_64Backend setThreadSafeARCOverride:threadSafeARC];
        NSString* asmText = [XTX86_64Backend assemblyFromModule:mod];
        if (!asmText)
            {
            fprintf(stderr, "xcc-cg-win64: backend produced no output\n");
            return 1;
            }

        if (outputPath)
            {
            NSError* err = nil;
            [asmText writeToFile:outputPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
            if (err)
                {
                fprintf(stderr, "xcc-cg-win64: cannot write '%s': %s\n",
                        outputPath.UTF8String, err.localizedDescription.UTF8String);
                return 1;
                }
            if (!quiet)
                fprintf(stderr, "xcc-cg-win64: win64 asm -> '%s'\n", outputPath.UTF8String);
            }
        else
            {
            fputs(asmText.UTF8String, stdout);
            }
        return 0;
        }
    }
