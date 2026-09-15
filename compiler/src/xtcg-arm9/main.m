#import <Foundation/Foundation.h>
#import "XTDiagnosticEngine.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIRType.h"
#import "XTIRValue.h"
#import "XTIRParser.h"
#import "XTIROptPipeline.h"
#import "XTIROptDeadFunctionElim.h"
#import "XTIROptTargetProfile.h"
#import "XTIRPrinter.h"
#import "XTArm9Backend.h"
#import "XTCommandLineOptions.h"

// xtcg-arm9 — IR → ARMv7-A (A32) .s code generator for the Zynq-7020
// Cortex-A9 (xtos) target. Sibling of xtcg-arm64 / xtcg-6502 / xtcg-68k.
//
// Reads a text-format IR module (from xtc-fe), runs the XTIROptPipeline at
// the requested -O level (base/conservative profile during bring-up), emits
// A32 assembly via XTArm9Backend, and writes .s. The driver assembles + links
// it with arm-none-eabi-gcc (AAPCS32, the Vitis BSP flags).
//
// Usage:
//   xtcg-arm9 [-O0..-O3] [-o out.s] input.ir

#ifndef XTC_VERSION
#define XTC_VERSION "0.0"
#endif

static void usage(void)
    {
    fprintf(stderr,
            "Usage: xtcg-arm9 [options] <input.ir>\n"
            "\n"
            "Options:\n"
            "  -o <path>             Output .s path (stdout if omitted).\n"
            "  -O0..-O3              IR opt-pass level.\n"
            "  -q, --quiet           Suppress informational stderr.\n"
            "  --dump-opt-ir         Print the IR after the opt pipeline and stop.\n"
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
                printf("xtcg-arm9 %s\n", XTC_VERSION);
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
            else if ([arg isEqualToString:@"--pic"])
                {
                [XTArm9Backend setPIC:YES]; // Tier-2 position-independent ET_DYN
                }
            else if ([arg isEqualToString:@"--object"])
                {
                // -c: this module is an OBJECT, so every function it defines is
                // part of its surface — something in another object may call it.
                // Without this, cross-function DCE deletes anything the module
                // does not itself call, and a helper compiled alone yields a .o
                // with no symbols at all. `.globl` too (setEmitLib), or the
                // functions are kept but not exported, which is the same
                // undefined symbol one step later.
                [XTArm9Backend setEmitLib:YES];
                [XTIROptDeadFunctionElim setKeepAllFunctions:YES];
                }
            else if ([arg isEqualToString:@"--emit-lib"])
                {
                [XTArm9Backend setEmitLib:YES];                    // export the public class API
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
                fprintf(stderr, "xcc-cg-arm9: unknown option '%s'\n", argv[i]);
                usage();
                return 1;
                }
            else
                {
                if (inputPath)
                    {
                    fprintf(stderr, "xcc-cg-arm9: multiple inputs not supported\n");
                    return 1;
                    }
                inputPath = arg;
                }
            }
        if (!inputPath)
            {
            fprintf(stderr, "xcc-cg-arm9: error: no input file\n");
            usage();
            return 1;
            }

        NSString* irText = [NSString stringWithContentsOfFile:inputPath
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
        if (!irText)
            {
            fprintf(stderr, "xcc-cg-arm9: cannot read '%s'\n", inputPath.UTF8String);
            return 1;
            }

        NSError* parseError = nil;
        XTIRModule* mod = [XTIRParser moduleFromString:irText error:&parseError];
        if (!mod)
            {
            fprintf(stderr, "xcc-cg-arm9: IR parse failed: %s\n",
                    parseError ? parseError.localizedDescription.UTF8String : "(no detail)");
            return 1;
            }

            {
            // Always run (even -O0): VaArgExpand is a MANDATORY lowering pass — the
            // backend can't lower the abstract VaStart/VaArg (bug 014). The per-pass
            // minOptLevel filter keeps the real optimisations off at -O0.
            // Conservative base profile during bring-up; an XTIRArm9TargetProfile
            // (relaxing it like arm64) lands once the backend is correctness-solid.
            XTIROptPipeline* pipe =
                [XTIROptPipeline standardPipelineAtLevel:optLevel
                                                 profile:[XTIRArm9TargetProfile new]];
            pipe.traceToStderr = !quiet;
            NSMutableArray<NSString*>* poErrs = nil;
            if (![pipe runOnModule:mod errors:&poErrs])
                {
                fprintf(stderr, "xcc-cg-arm9: IR opt pipeline failed:\n");
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
                    fprintf(stderr, "xcc-cg-arm9: cannot write '%s'\n", outputPath.UTF8String);
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

        // Thread-safe ARC: decided per module by the backend (threading.md
        // §4.1); this only forwards an explicit -f[no-]thread-safe-arc.
        [XTArm9Backend setThreadSafeARCOverride:threadSafeARC];
        NSString* asmText = [XTArm9Backend assemblyFromModule:mod];
        if (!asmText)
            {
            fprintf(stderr, "xcc-cg-arm9: backend produced no output\n");
            return 1;
            }

        if (outputPath)
            {
            NSError* err = nil;
            [asmText writeToFile:outputPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
            if (err)
                {
                fprintf(stderr, "xcc-cg-arm9: cannot write '%s': %s\n",
                        outputPath.UTF8String, err.localizedDescription.UTF8String);
                return 1;
                }
            if (!quiet)
                fprintf(stderr, "xcc-cg-arm9: A32 asm -> '%s'\n", outputPath.UTF8String);
            }
        else
            {
            fputs(asmText.UTF8String, stdout);
            }
        return 0;
        }
    }
