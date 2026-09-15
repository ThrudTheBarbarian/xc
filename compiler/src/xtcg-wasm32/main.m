#import <Foundation/Foundation.h>
#import "XTDiagnosticEngine.h"
#import "XTIRModule.h"
#import "XTIRParser.h"
#import "XTIROptPipeline.h"
#import "XTIROptTargetProfile.h"
#import "XTIROptDeadFunctionElim.h"
#import "XTIRPrinter.h"
#import "XTWasmBackend.h"
#import "XTCommandLineOptions.h"

// xtcg-wasm32 — IR → WebAssembly text (.wat) code generator.
//
// Reads a text-format IR module (produced by xcc-fe), runs the
// XTIROptPipeline at the requested -O level with the wasm32 profile,
// emits WAT via XTWasmBackend, and writes it out. xcc-ln-wasm32 then
// assembles the WAT to .wasm (in-house, no wat2wasm) and writes the JS
// loader beside it. Same pattern as its xtcg-* siblings.
//
// Usage:
//   xcc-cg-wasm32 [-O0..-O3] [-o output.wat] input.ir

#ifndef XTC_VERSION
#define XTC_VERSION "0.0"
#endif

static void usage(void)
    {
    fprintf(stderr,
            "Usage: xcc-cg-wasm32 [options] <input.ir>\n"
            "\n"
            "Options:\n"
            "  -o <path>             Output .wat path.\n"
            "  -O0..-O3              IR opt-pass level.\n"
            "  --emit-lib            Library build (W2): relocatable dylink-shaped module.\n"
            "  --link-libs           App build that #imports .wasm libraries.\n"
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
        [XTCommandLineOptions setExecutablePath:argv[0]];
        NSString* inputPath = nil;
        NSString* outputPath = nil;
        NSInteger optLevel = 0;
        BOOL quiet = NO;
        BOOL dumpOptIR = NO;
        // -1 = decide from the module (the default), 0 = off, 1 = on.
        int threadSafeARC = -1;

        for (int i = 1; i < argc; i++)
            {
            NSString* arg = @(argv[i]);
            if ([arg isEqualToString:@"-v"] || [arg isEqualToString:@"--version"])
                {
                printf("xcc-cg-wasm32 %s\n", XTC_VERSION);
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
            else if ([arg isEqualToString:@"--emit-lib"])
                {
                // Library build: keep every function (the export set is the
                // public API), and switch the backend to the relocatable
                // dylink-shaped library mode (W2).
                [XTIROptDeadFunctionElim setKeepAllFunctions:YES];
                [XTWasmBackend setEmitLib:YES];
                }
            else if ([arg isEqualToString:@"--link-libs"])
                {
                // App that #imports .wasm libraries: export the runtime /
                // memory / table surface the loader wires each library to.
                [XTWasmBackend setLinkLibs:YES];
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
                // The IR AFTER the opt pipeline — the differential oracle for
                // the ported optimiser (selfhost/opt).
                dumpOptIR = YES;
                }
            else if ([arg hasPrefix:@"-x-wasm32,"])
                {
                for (NSString* o in [[arg substringFromIndex:10]
                         componentsSeparatedByString:@","])
                    {
                    if ([o isEqualToString:@"return-call"])
                        {
                        [XTWasmBackend setTailCalls:YES];
                        }
                    else
                        {
                        fprintf(stderr, "xcc-cg-wasm32: unknown wasm32 option '%s'\n",
                                o.UTF8String);
                        return 1;
                        }
                    }
                }
            else if ([arg hasPrefix:@"-"])
                {
                fprintf(stderr, "xcc-cg-wasm32: unknown option '%s'\n", argv[i]);
                usage();
                return 1;
                }
            else
                {
                if (inputPath)
                    {
                    fprintf(stderr, "xcc-cg-wasm32: multiple inputs not supported\n");
                    return 1;
                    }
                inputPath = arg;
                }
            }
        if (!inputPath)
            {
            fprintf(stderr, "xcc-cg-wasm32: error: no input file\n");
            usage();
            return 1;
            }

        NSString* irText = [NSString stringWithContentsOfFile:inputPath
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
        if (!irText)
            {
            fprintf(stderr, "xcc-cg-wasm32: cannot read '%s'\n", inputPath.UTF8String);
            return 1;
            }
        NSError* parseError = nil;
        XTIRModule* mod = [XTIRParser moduleFromString:irText
                                                 error:&parseError];
        if (!mod)
            {
            fprintf(stderr, "xcc-cg-wasm32: IR parse failed: %s\n",
                    parseError ? parseError.localizedDescription.UTF8String : "(no detail)");
            return 1;
            }

            {
            // Always run the pipeline (even -O0): VaArgExpand lowers the
            // abstract VaStart/VaArg and is MANDATORY (bug 014); the per-pass
            // minOptLevel filter keeps real optimisations off at -O0.
            XTIROptPipeline* pipe =
                [XTIROptPipeline standardPipelineAtLevel:optLevel
                                                 profile:[XTIRWasm32TargetProfile new]];
            pipe.traceToStderr = !quiet;
            NSMutableArray<NSString*>* poErrs = nil;
            if (![pipe runOnModule:mod errors:&poErrs])
                {
                fprintf(stderr, "xcc-cg-wasm32: IR opt pipeline failed:\n");
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
                    fprintf(stderr, "xcc-cg-wasm32: cannot write '%s'\n", outputPath.UTF8String);
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

        // Thread-safe ARC: the backend decides per module; this only forwards
        // an explicit -fthread-safe-arc / -fno-thread-safe-arc.
        [XTWasmBackend setThreadSafeARCOverride:threadSafeARC];
        // -O1+ emits real structured control flow; -O0 keeps the br_table
        // dispatch loop (the wasm-diff oracle form).
        [XTWasmBackend setOptLevel:optLevel];

        NSString* asmText = [XTWasmBackend assemblyFromModule:mod];
        if (!quiet && [XTWasmBackend threadSafeARC] && threadSafeARC < 0)
            fprintf(stderr, "xcc-cg-wasm32: thread-safe (atomic) ARC enabled — the module spawns threads\n");
        if (!asmText)
            {
            fprintf(stderr, "xcc-cg-wasm32: backend produced no output\n");
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
                fprintf(stderr, "xcc-cg-wasm32: cannot write '%s': %s\n",
                        outputPath.UTF8String, err.localizedDescription.UTF8String);
                return 1;
                }
            if (!quiet)
                {
                fprintf(stderr, "xcc-cg-wasm32: wasm32 WAT -> '%s'\n", outputPath.UTF8String);
                }
            }
        else
            {
            fputs(asmText.UTF8String, stdout);
            }
        return 0;
        }
    }
