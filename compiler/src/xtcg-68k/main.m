#import <Foundation/Foundation.h>
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIRType.h"
#import "XTIRValue.h"
#import "XTIRParser.h"
#import "XTIROptPipeline.h"
#import "XTIROptTargetProfile.h"
#import "XTIRPrinter.h"
#import "XTM68kBackend.h"
#import "XAM68kAssembler.h"
#import "XTCommandLineOptions.h"

// xtcg-68k — IR → Motorola 68000/68030 (.s) code generator for the
// Atari ST/TT target. Sibling of xtcg-6502 / xtcg-arm64.
//
// Reads a text-format IR module (from xtc-fe), runs the XTIROptPipeline
// at the requested -O level with the m68k target profile, emits 68k
// assembly via XTM68kBackend. A future xta68 step (M2.1) will assemble
// the .s into a GEMDOS $601A executable when -o names a binary.
//
// Usage:
//   xtcg-68k [-O0..-O3] [--cpu 68000|68030] [-o out.s] input.ir

#ifndef XTC_VERSION
#define XTC_VERSION "0.0"
#endif

static void usage(void)
    {
    fprintf(stderr,
            "Usage: xtcg-68k [options] <input.ir>\n"
            "\n"
            "Options:\n"
            "  -o <path>             Output .s path (stdout if omitted).\n"
            "  -O0..-O3              IR opt-pass level.\n"
            "  --cpu <n>             68000 (default) or 68030.\n"
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
        NSInteger cpu = 68000;
        BOOL hardFloat = NO;
        BOOL pic = NO;
        BOOL quiet = NO;
        BOOL dumpOptIR = NO;

        for (int i = 1; i < argc; i++)
            {
            NSString* arg = @(argv[i]);
            if ([arg isEqualToString:@"-v"] || [arg isEqualToString:@"--version"])
                {
                printf("xtcg-68k %s\n", XTC_VERSION);
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
            else if ([arg isEqualToString:@"--cpu"] && i + 1 < argc)
                {
                cpu = atoi(argv[++i]);
                }
            else if ([arg isEqualToString:@"--hard-float"])
                {
                hardFloat = YES;
                }
            else if ([arg isEqualToString:@"--pic"])
                {
                pic = YES;
                }
            else if ([arg isEqualToString:@"-m"] && i + 1 < argc)
                {
                (void)argv[++i]; // platform; single ST platform for now
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
            else if ([arg isEqualToString:@"--dump-opt-ir"])
                {
                // The IR AFTER the opt pipeline, as text — the differential
                // oracle for the ported optimiser (selfhost/opt). Nothing is
                // generated: print(opt(parse(text))) is the whole run.
                dumpOptIR = YES;
                }
            else if ([arg hasPrefix:@"-"])
                {
                fprintf(stderr, "xcc-cg-68k: unknown option '%s'\n", argv[i]);
                usage();
                return 1;
                }
            else
                {
                if (inputPath)
                    {
                    fprintf(stderr, "xcc-cg-68k: multiple inputs not supported\n");
                    return 1;
                    }
                inputPath = arg;
                }
            }
        if (!inputPath)
            {
            fprintf(stderr, "xcc-cg-68k: error: no input file\n");
            usage();
            return 1;
            }

        NSString* irText = [NSString stringWithContentsOfFile:inputPath
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
        if (!irText)
            {
            fprintf(stderr, "xcc-cg-68k: cannot read '%s'\n", inputPath.UTF8String);
            return 1;
            }
        NSError* parseError = nil;
        XTIRModule* mod = [XTIRParser moduleFromString:irText error:&parseError];
        if (!mod)
            {
            fprintf(stderr, "xcc-cg-68k: IR parse failed: %s\n",
                    parseError ? parseError.localizedDescription.UTF8String : "(no detail)");
            return 1;
            }

            {
            // Always run (even -O0): VaArgExpand is a MANDATORY lowering pass — the
            // backend can't lower the abstract VaStart/VaArg (bug 014). The per-pass
            // minOptLevel filter keeps the real optimisations off at -O0.
            XTIROptPipeline* pipe =
                [XTIROptPipeline standardPipelineAtLevel:optLevel
                                                 profile:[XTIRM68kTargetProfile new]];
            pipe.traceToStderr = !quiet;
            NSMutableArray<NSString*>* poErrs = nil;
            if (![pipe runOnModule:mod errors:&poErrs])
                {
                fprintf(stderr, "xcc-cg-68k: IR opt pipeline failed:\n");
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
                    fprintf(stderr, "xcc-cg-68k: cannot write '%s'\n", outputPath.UTF8String);
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

        NSString* asmText = nil;
        @try
            {
            asmText = [XTM68kBackend assemblyFromModule:mod
                                                    cpu:cpu
                                              hardFloat:hardFloat
                                                    pic:pic];
            }
        @catch (NSException* e)
            {
            if ([e.name isEqualToString:@"XTFrameBudgetExceeded"])
                {
                fprintf(stderr, "xcc-cg-68k: error: %s\n", e.reason.UTF8String);
                return 1;
                }
            @throw;
            }
        if (!asmText)
            {
            fprintf(stderr, "xcc-cg-68k: backend produced no output\n");
            return 1;
            }

        // Binary output extensions (or no extension) -> assemble in-process to
        // a GEMDOS $601A. A `.s`/`.asm` extension (or stdout) writes asm text.
        NSString* ext = outputPath.pathExtension.lowercaseString;
        NSSet* binExts = [NSSet setWithArray:@[ @"prg", @"tos", @"ttp", @"app", @"acc" ]];
        BOOL wantBinary = outputPath && ([binExts containsObject:ext] || ext.length == 0);

        if (wantBinary)
            {
            XAM68kAssembler* asmer = [XAM68kAssembler new];
            asmer.cpu = cpu; // 68020+ -> 32-bit PC-relative PIC (no ±32KB limit)
            asmer.pic = pic; // 68000 -> GOT/a5 model (no ±32KB limit)
            NSString* asmErr = nil;
            NSData* image = [asmer assemble:asmText error:&asmErr];
            if (!image)
                {
                fprintf(stderr, "xcc-as68: error: %s\n", asmErr.UTF8String ?: "(no detail)");
                return 1;
                }
            if (![image writeToFile:outputPath atomically:YES])
                {
                fprintf(stderr, "xcc-cg-68k: cannot write '%s'\n", outputPath.UTF8String);
                return 1;
                }
            if (!quiet)
                fprintf(stderr, "xcc-cg-68k: $601A -> '%s' (%lu bytes)\n",
                        outputPath.UTF8String, (unsigned long)image.length);
            }
        else if (outputPath)
            {
            NSError* err = nil;
            [asmText writeToFile:outputPath
                      atomically:YES
                        encoding:NSUTF8StringEncoding
                           error:&err];
            if (err)
                {
                fprintf(stderr, "xcc-cg-68k: cannot write '%s': %s\n",
                        outputPath.UTF8String, err.localizedDescription.UTF8String);
                return 1;
                }
            if (!quiet)
                fprintf(stderr, "xcc-cg-68k: 68k asm -> '%s'\n", outputPath.UTF8String);
            }
        else
            {
            fputs(asmText.UTF8String, stdout);
            }
        return 0;
        }
    }
