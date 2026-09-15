#import <Foundation/Foundation.h>
#import "XTRegexCompat.h"
#import "XTCommandLineOptions.h"
#import "XTDiagnosticEngine.h"
#import "XTMemoryModel.h"
#import "XTLinkerScriptParser.h"
#import "XTIRModule.h"
#import "XTIRParser.h"
#import "XTIROptPipeline.h"
#import "XTIROptTargetProfile.h"
#import "XTIRPrinter.h"
#import "XT6502Backend.h"
#import "XTType.h"
#import "XT6502AsmPeephole.h"
#import "XTIRRuntimeEmitter.h"
#import "XAAssembler.h" // declares XASegment too

// xtcg-6502 — IR → xt6502 asm/xex code generator.
//
// Reads a text-format IR module (produced by xtc-fe or the new-IR driver
// with --emit-ir), runs the XTIROptPipeline at the requested -O level,
// emits xt6502 assembly via XT6502Backend, wraps it with the runtime
// harness via XTIRRuntimeEmitter, and writes either raw .asm or an
// assembled .xex via XAAssembler.
//
// This is the first half of the front-end / back-end split: this binary
// is the only one in the toolchain that knows about XT6502Backend and
// xta. Adding a future xtcg-m68k is a sibling binary that doesn't
// affect this one. xtc shells out to the appropriate xtcg-<arch>
// chosen from -m.
//
// Usage:
//   xtcg-6502 [-O0..-O3] [-m xl|xt|xe|...] [-o output] input.ir
//
// Output extension drives the mode:
//   .xex/.exe/.bin/.com → assemble in-process and write the binary
//   anything else / no -o → write the wrapped assembly text

#ifndef XTC_VERSION
#define XTC_VERSION "0.0"
#endif

static void usage(void)
    {
    fprintf(stderr,
            "Usage: xtcg-6502 [options] <input.ir>\n"
            "\n"
            "Options:\n"
            "  -m <model>            Memory layout (xl, xt, xe, ...). Default xl.\n"
            "  -o <path>             Output path. Extension drives format:\n"
            "                          .xex/.exe/.bin/.com → assemble to binary\n"
            "                          else → write wrapped 6502 asm.\n"
            "  -O0..-O3              IR opt-pass level.\n"
            "  -q, --quiet           Suppress informational stderr.\n"
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
        // xt6502 float is IEEE f32 (via the MECH coprocessor), matching the
        // front end. This process reads XTType.floatIsIEEE in byteWidthForType
        // and the float op lowering, so it must be configured the same as the
        // driver set it in xtc-fe, or the type-width invariant breaks.
        [XTType setFloatIsIEEE:YES];
        [XTType setFloatWidth:4];
        NSString* inputPath = nil;
        NSString* outputPath = nil;
        NSString* target = @"xt";
        NSString* xtcHomeArg = nil;
        NSInteger optLevel = 0;
        BOOL quiet = NO;
        BOOL dumpOptIR = NO;

        for (int i = 1; i < argc; i++)
            {
            NSString* arg = @(argv[i]);
            if ([arg isEqualToString:@"-v"] || [arg isEqualToString:@"--version"])
                {
                printf("xtcg-6502 %s\n", XTC_VERSION);
                return 0;
                }
            else if ([arg isEqualToString:@"-h"] || [arg isEqualToString:@"--help"])
                {
                usage();
                return 0;
                }
            else if ([arg isEqualToString:@"-m"] && i + 1 < argc)
                {
                target = @(argv[++i]);
                }
            else if (([arg isEqualToString:@"-H"] || [arg isEqualToString:@"--xtc-home"]) && i + 1 < argc)
                {
                xtcHomeArg = @(argv[++i]);
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
            else if ([arg isEqualToString:@"--dump-opt-ir"])
                {
                // The IR AFTER the opt pipeline, as text — the differential
                // oracle for the ported optimiser (selfhost/opt). Nothing is
                // generated: print(opt(parse(text))) is the whole run.
                dumpOptIR = YES;
                }
            else if ([arg hasPrefix:@"-"])
                {
                fprintf(stderr, "xcc-cg-6502: unknown option '%s'\n", argv[i]);
                usage();
                return 1;
                }
            else
                {
                if (inputPath)
                    {
                    fprintf(stderr, "xcc-cg-6502: multiple inputs not supported\n");
                    return 1;
                    }
                inputPath = arg;
                }
            }
        if (!inputPath)
            {
            fprintf(stderr, "xcc-cg-6502: error: no input file\n");
            usage();
            return 1;
            }

        // Resolve memory model from the .lnk file — xt.lnk is the single
        // source of truth for the layout (entry, banking, ZP, main
        // region). Resolve the xtc home the same way the driver does
        // (explicit -H, then $XTC_HOME, then ".", then install dirs) so
        // the backend uses the SAME model the frontend did; otherwise the
        // generated code's placement won't match the runtime harness that
        // wraps it. The .lnk is the single source of truth — if it can't be
        // found, that is a HARD ERROR, not a fall-back to a hardcoded model.
        // The sole exception is the parametric `xe:<size>:<mask>` triplet,
        // which has no .lnk by design and is built from the spec itself.
        NSString* xtcHome = [XTCommandLineOptions resolveXtcHome:xtcHomeArg];
        XTMemoryModel* mm =
            [XTCommandLineOptions tryLoadLinkerScript:target
                                              xtcHome:xtcHome];
        if (!mm && [target hasPrefix:@"xe:"])
            {
            mm = [XTMemoryModel modelFromSpec:target];
            }
        if (!mm)
            {
            fprintf(stderr, "xcc-cg-6502: error: no layout file for -m '%s' "
                            "(looked for support/<platform>/layouts/%s.lnk under the xtc "
                            "home%s). The layout is the single source of truth; there is "
                            "no built-in fallback.\n",
                    target.UTF8String,
                    target.UTF8String, xtcHome ? "" : " — none found");
            return 1;
            }

        // Read + parse IR.
        NSString* irText = [NSString stringWithContentsOfFile:inputPath
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
        if (!irText)
            {
            fprintf(stderr, "xcc-cg-6502: cannot read '%s'\n", inputPath.UTF8String);
            return 1;
            }
        NSError* parseError = nil;
        XTIRModule* mod = [XTIRParser moduleFromString:irText
                                                 error:&parseError];
        if (!mod)
            {
            fprintf(stderr, "xcc-cg-6502: IR parse failed: %s\n",
                    parseError ? parseError.localizedDescription.UTF8String : "(no detail)");
            return 1;
            }
        // The parser populates `error` with a joined error list even
        // when it returns a (partially-built) module. Surface those
        // errors to stderr — silently consuming them produced bogus
        // codegen (e.g. AddrOf-resolution failures became Bitcasts
        // with sentinel operands).
        if (parseError && !quiet)
            {
            fprintf(stderr, "xcc-cg-6502: IR parser warnings:\n%s\n",
                    parseError.localizedDescription.UTF8String);
            }

            // IR opt pipeline. Always run (even -O0): VaArgExpand is a MANDATORY
            // lowering pass — the backend can't lower the abstract VaStart/VaArg
            // (bug 014). The per-pass minOptLevel filter keeps the real optimisations
            // off at -O0 (the asm-text peephole below stays -O>=1 gated).
            {
            XTIROptPipeline* pipe =
                [XTIROptPipeline standardPipelineAtLevel:optLevel
                                                 profile:[XTIRXt6502TargetProfile new]];
            pipe.traceToStderr = !quiet;
            NSMutableArray<NSString*>* poErrs = nil;
            if (![pipe runOnModule:mod errors:&poErrs])
                {
                fprintf(stderr, "xcc-cg-6502: IR opt pipeline failed:\n");
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
                    fprintf(stderr, "xcc-cg-6502: cannot write '%s'\n", outputPath.UTF8String);
                    return 1;
                    }
                }
            else
                {
                fputs(t.UTF8String, stdout);
                }
            return 0;
            }

        // Backend.
        XTDiagnosticEngine* diag = [[XTDiagnosticEngine alloc] init];
        NSString* asmText = [XT6502Backend assemblyFromModule:mod
                                                  memoryModel:mm
                                                  diagnostics:diag];
        if (!asmText || diag.hasFatalError)
            {
            [diag printAll];
            fprintf(stderr, "xcc-cg-6502: backend produced no output\n");
            return 1;
            }

        // Asm-text peephole — runs over the raw backend output to close
        // patterns the SSA→stack lowering opens up (redundant reload,
        // dead store, ...). Adds noise to -O0 builds where the
        // straight-line shape is easier to read, so gated by -O>=1.
        if (optLevel > 0)
            {
            NSUInteger before = [[asmText componentsSeparatedByString:@"\n"] count];
            asmText = [XT6502AsmPeephole optimise:asmText level:optLevel];
            NSUInteger after = [[asmText componentsSeparatedByString:@"\n"] count];
            if (!quiet && before != after)
                {
                fprintf(stderr,
                        "xcc-cg-6502: peephole: %lu → %lu lines (%ld removed)\n",
                        (unsigned long)before, (unsigned long)after,
                        (long)before - (long)after);
                }
            }

        // Rename `_main` → `_xt_main` so the harness's startup JSR resolves.
        NSRegularExpression* re = [NSRegularExpression
            regularExpressionWithPattern:@"\\b_main\\b"
                                 options:0
                                   error:NULL];
        if (re)
            {
            asmText = XTRegexReplace(re, asmText, @"_xt_main");
            }

        // Runtime wrap. Resolve the harness + asm templates under the xtc home
        // (from -H / $XTC_HOME) so the build works from ANY cwd — not just the
        // repo root. Without this the harness (which defines _u32LShr and the
        // other integer runtime routines) read cwd-relative and, run elsewhere,
        // came back empty → xt6502 emitted `JSR $0000` for those routines.
        [XTIRRuntimeEmitter setSupportRoot:
                                [XTCommandLineOptions supportRootForHome:xtcHome]];
        asmText = [XTIRRuntimeEmitter
            wrapXt6502Asm:asmText
                forModule:mod
              memoryModel:mm
              harnessPath:@"xt6502/runtime/xt6502-harness.asm"];

        // Output: binary or asm?
        NSSet<NSString*>* binExts = [NSSet setWithArray:@[ @"xex", @"exe", @"bin", @"com" ]];
        NSString* ext = outputPath.pathExtension.lowercaseString;
        BOOL wantBinary = outputPath && [binExts containsObject:ext];

        if (wantBinary)
            {
            XAAssembler* asmer = [[XAAssembler alloc] init];
            asmer.verbose = NO;
            asmer.bankedMode = mm.isBanked;
            asmer.xeBankMask = (mm.kind == XTMemoryModelKindXE) ? mm.portBMask : 0;
            asmer.bankWindowStart = mm.bankWindowStart;
            asmer.bankWindowEnd = mm.bankWindowEnd;
            asmer.hasSplitBanking = mm.hasSplitBanking;
            // The code/data bank-select registers must reach xta whenever
            // the model defines them — xt.lnk sets them via `registers =
            // $D5C0, $D5C1` WITHOUT flagging split banking, so gating this
            // on hasSplitBanking left xta defaulting to the old $82/$83
            // ZP pair. The backend's bank switches and xta's preload stubs
            // then wrote $82/$83 while xts -m xt reads the selector at
            // $D5C0/$D5C1 → the bank never switched and nothing printed.
            if (mm.codeBankReg)
                asmer.codeBankReg = mm.codeBankReg;
            if (mm.dataBankReg)
                asmer.dataBankReg = mm.dataBankReg;
            if (mm.hasSplitBanking)
                {
                asmer.dataWindowStart = mm.dataWindowStart;
                asmer.dataWindowEnd = mm.dataWindowEnd;
                }
            if (mm.hasRegionCBanking)
                {
                asmer.regCWindowStart = mm.regCWindowStart;
                asmer.regCWindowEnd = mm.regCWindowEnd;
                asmer.regCBankRegLo = mm.regCBankRegLo;
                asmer.regCBankRegHi = mm.regCBankRegHi;
                }
            if (mm.mainRegionRanges.count > 0)
                {
                asmer.mainRegionStart = [mm.mainRegionRanges[0][0] unsignedShortValue];
                asmer.mainRegionEnd = [mm.mainRegionRanges[0][1] unsignedShortValue];
                }
            // Resolve `.include "xt6502/asm/…"` under the SUPPORT ROOT — the
            // emitted paths are relative to it, because the tree is called
            // lib/xc in an install and support/ in the source tree. Pointing
            // this at the home instead worked only where the two happened to
            // coincide: installed, every runtime routine assembled to a JSR
            // $0000, which the assembler warns about and nothing failed on.
            NSString* supRoot = [XTCommandLineOptions supportRootForHome:xtcHome];
            NSMutableArray<NSString*>* incs = [NSMutableArray array];
            if (supRoot.length)
                [incs addObject:supRoot];
            if (xtcHome.length)
                [incs addObject:xtcHome]; // legacy "support/…" spellings
            [incs addObject:@"."];
            asmer.includePaths = incs;
            NSArray<XASegment*>* segs = [asmer assembleSource:asmText filename:outputPath];
            for (NSString* w in asmer.warnings)
                fprintf(stderr, "xcc-as: warning: %s\n", w.UTF8String);
            if (!segs)
                {
                for (NSString* e in asmer.errors)
                    fprintf(stderr, "xcc-as: error: %s\n", e.UTF8String);
                return 1;
                }
            uint16_t entry = segs.count > 0 ? segs[0].origin : 0x2000;
            BOOL ok = asmer.bankedMode
                          ? [asmer writeBankedXEX:segs entryPoint:entry toFile:outputPath]
                          : [asmer writeXEX:segs entryPoint:entry toFile:outputPath];
            if (!ok)
                {
                fprintf(stderr, "xcc-as: error: cannot write '%s'\n", outputPath.UTF8String);
                return 1;
                }
            if (!quiet)
                {
                NSUInteger total = 0;
                for (XASegment* s in segs)
                    total += s.data.length;
                fprintf(stderr, "xcc-cg-6502: %s -> '%s' (%lu bytes, %lu segments)\n",
                        ext.UTF8String, outputPath.UTF8String,
                        (unsigned long)total, (unsigned long)segs.count);
                }
            return 0;
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
                fprintf(stderr, "xcc-cg-6502: cannot write '%s': %s\n",
                        outputPath.UTF8String, err.localizedDescription.UTF8String);
                return 1;
                }
            if (!quiet)
                {
                fprintf(stderr, "xcc-cg-6502: 6502 asm -> '%s'\n", outputPath.UTF8String);
                }
            }
        else
            {
            fputs(asmText.UTF8String, stdout);
            }
        return 0;
        }
    }
