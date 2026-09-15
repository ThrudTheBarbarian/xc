#import <Foundation/Foundation.h>
#import "XAAssembler.h"
#import "XTMemoryModel.h"
#import "XTLinkerScriptParser.h"
#import "XTCommandLineOptions.h"

#ifndef XTC_VERSION
#define XTC_VERSION "0.0"
#endif

/****************************************************************************\
|* Print the assembler usage/help text to stderr.
\****************************************************************************/
static void printUsage(void)
    {
    fprintf(stderr,
            "xta — 6502 assembler\n"
            "Usage: xta [options] <input.asm ...>\n"
            "Options:\n"
            "  -D name[=value]  Define a symbol\n"
            "  -f <which>       Output format: xex (default), prg\n"
            "  -I path          Add include search path\n"
            "  -o path          Output file (default: input stem + .xex)\n"
            "  -l path          Output listing file\n"
            "  -b               Enable banked output mode (for xtc bank-switched targets)\n"
            "  --split-bank     xt Option B: segments at $6000-$7FFF get $83-only preloads,\n"
            "                   segments at $4000-$5FFF get $82-only preloads. Requires -b.\n"
            "  --data-window START:END  Data-window bounds for --split-bank (hex, e.g. $6000:$7FFF).\n"
            "  -L <layout.lnk>  Read banking windows + bank registers from a layout file\n"
            "                   (the same .lnk the xtc driver uses). Enables banked output\n"
            "                   when the layout declares a [banking] section.\n"
            "  -s path          Load platform symbol file (.sym)\n"
            "  -v, --version    Print version\n"
            "  -V               Verbose (show all warnings)\n"
            "  -h               Show this help\n"
            "\n"
            "The output format is auto-detected from the -o extension (.prg = PRG,\n"
            "anything else = XEX), or set explicitly with -f.\n");
    }

/****************************************************************************\
|* xta entry point. Parses command-line arguments, reads and concatenates
|* input files, assembles them, and writes the output XEX binary.
|* @param argc  Argument count.
|* @param argv  Argument vector.
|* @return  0 on success, 1 on error.
\****************************************************************************/
int main(int argc, const char* argv[])
    {
    @autoreleasepool
        {
        // Record argv[0] so the support tree is found relative to THIS binary.
        // An installed tool must not depend on the current directory to find
        // its own libraries.
        [XTCommandLineOptions setExecutablePath:argv[0]];
        NSMutableArray<NSString*>* inputFiles = [NSMutableArray array];
        NSMutableArray<NSString*>* includePaths = [NSMutableArray array];
        NSMutableDictionary<NSString*, NSString*>* defines = [NSMutableDictionary dictionary];
        NSString* outputPath = nil;
        NSString* listingPath = nil;
        NSString* formatStr = nil;
        NSString* symbolsFile = nil;
        BOOL banked = NO;
        BOOL verbose = NO;
        BOOL splitBanking = NO;
        uint16_t dataWindowStart = 0;
        uint16_t dataWindowEnd = 0;
        NSString* layoutPath = nil;

        for (int i = 1; i < argc; i++)
            {
            NSString* arg = [NSString stringWithUTF8String:argv[i]];

            if ([arg isEqualToString:@"-h"])
                {
                printUsage();
                return 0;
                }
            if ([arg isEqualToString:@"-v"] || [arg isEqualToString:@"--version"])
                {
                printf("xta %s\n", XTC_VERSION);
                return 0;
                }
            if ([arg isEqualToString:@"-V"])
                {
                verbose = YES;
                continue;
                }
            if ([arg isEqualToString:@"-b"])
                {
                banked = YES;
                continue;
                }
            // xt Option B split-bank output. `--split-bank` marks
            // banked output as origin-classified (segments at
            // $6000-$7FFF get $83-only preloads, segments at
            // $4000-$5FFF get $82-only preloads). `--data-window
            // START:END` gives the data-half bounds; both are hex
            // with or without leading $ / 0x. When xta is driven
            // by xtc the driver plumbs these from the memory model
            // and these flags are unused.
            if ([arg isEqualToString:@"--split-bank"])
                {
                splitBanking = YES;
                continue;
                }
            if ([arg isEqualToString:@"--data-window"] && i + 1 < argc)
                {
                NSString* v = [NSString stringWithUTF8String:argv[++i]];
                NSArray<NSString*>* parts = [v componentsSeparatedByString:@":"];
                if (parts.count != 2)
                    {
                    fprintf(stderr, "xcc-as: --data-window expects START:END\n");
                    return 1;
                    }
                for (int k = 0; k < 2; k++)
                    {
                    NSString* s = parts[k];
                    if ([s hasPrefix:@"$"])
                        s = [s substringFromIndex:1];
                    else if ([s hasPrefix:@"0x"] || [s hasPrefix:@"0X"])
                        s = [s substringFromIndex:2];
                    unsigned int u = 0;
                    NSScanner* sc = [NSScanner scannerWithString:s];
                    if (![sc scanHexInt:&u] || !sc.isAtEnd)
                        {
                        fprintf(stderr, "xcc-as: --data-window bad hex '%s'\n", s.UTF8String);
                        return 1;
                        }
                    if (k == 0)
                        dataWindowStart = (uint16_t)u;
                    else
                        dataWindowEnd = (uint16_t)u;
                    }
                continue;
                }
            // xt banking (task #60): read the bank windows + bank
            // registers from a layout file — the same `.lnk` the xtc
            // driver parses, so the window addresses live in ONE place
            // rather than being duplicated as CLI flags. Standalone xta
            // (the test harnesses, manual use) configures itself from
            // the layout; the in-process driver path already does the
            // equivalent from its parsed XTMemoryModel.
            if ([arg isEqualToString:@"-L"] && i + 1 < argc)
                {
                layoutPath = [NSString stringWithUTF8String:argv[++i]];
                continue;
                }
            if ([arg isEqualToString:@"-f"] && i + 1 < argc)
                {
                formatStr = [[NSString stringWithUTF8String:argv[++i]] lowercaseString];
                continue;
                }
            if ([arg isEqualToString:@"-s"] && i + 1 < argc)
                {
                symbolsFile = [NSString stringWithUTF8String:argv[++i]];
                continue;
                }

            if ([arg isEqualToString:@"-o"] && i + 1 < argc)
                {
                outputPath = [NSString stringWithUTF8String:argv[++i]];
                continue;
                }
            if ([arg isEqualToString:@"-l"] && i + 1 < argc)
                {
                listingPath = [NSString stringWithUTF8String:argv[++i]];
                continue;
                }
            if ([arg isEqualToString:@"-I"] && i + 1 < argc)
                {
                [includePaths addObject:[NSString stringWithUTF8String:argv[++i]]];
                continue;
                }
            if ([arg hasPrefix:@"-D"])
                {
                NSString* def = arg.length > 2 ? [arg substringFromIndex:2] : (i + 1 < argc ? [NSString stringWithUTF8String:argv[++i]] : @"");
                NSRange eq = [def rangeOfString:@"="];
                if (eq.location != NSNotFound)
                    {
                    defines[[def substringToIndex:eq.location]] = [def substringFromIndex:eq.location + 1];
                    }
                else
                    {
                    defines[def] = @"1";
                    }
                continue;
                }
            if ([arg hasPrefix:@"-"])
                {
                fprintf(stderr, "xcc-as: unknown option '%s'\n", argv[i]);
                return 1;
                }

            [inputFiles addObject:arg];
            }

        if (inputFiles.count == 0)
            {
            fprintf(stderr, "xcc-as: no input files\n");
            printUsage();
            return 1;
            }

        // Default output path
        if (!outputPath)
            {
            NSString* ext = [formatStr isEqualToString:@"prg"] ? @"prg" : @"xex";
            outputPath = [[inputFiles[0] stringByDeletingPathExtension] stringByAppendingPathExtension:ext];
            }

        // Read and concatenate all input files
        NSMutableString* source = [NSMutableString string];
        for (NSString* inputFile in inputFiles)
            {
            NSError* err;
            NSString* content = [NSString stringWithContentsOfFile:inputFile
                                                          encoding:NSUTF8StringEncoding
                                                             error:&err];
            if (!content)
                {
                fprintf(stderr, "xcc-as: cannot read '%s': %s\n",
                        inputFile.UTF8String, err.localizedDescription.UTF8String);
                return 1;
                }
            [source appendString:content];
            [source appendString:@"\n"];
            }

        // Assemble
        XAAssembler* assembler = [[XAAssembler alloc] init];
        assembler.verbose = verbose;
        assembler.bankedMode = banked;
        assembler.includePaths = includePaths;
        if (symbolsFile)
            assembler.symbolsFile = symbolsFile;

        // Auto-load platform symbol tables when no explicit -s was given.
        // Mirrors what the xtc driver does for assembler invocations.
        // Without this, standalone xta invocations (e.g. from the IR-path
        // test harness) leave Atari OS vector symbols (CIOV, SYSVBV,
        // XITVBV, etc.) undefined and they resolve to $0000 at link time.
        // Search order matches the driver: support/<platform>/symbols/*.sym
        // followed by support/generic/symbols/*.sym, under any of the
        // standard xtc support roots.
        if (!symbolsFile)
            {
            // One resolver, shared with the compiler: -H/$XCC_HOME, then
            // relative to this binary, then cwd and the install roots. Rolling
            // its own list here is how the assembler ended up able to find a
            // support tree the compiler could not, and vice versa.
            NSFileManager* fm = [NSFileManager defaultManager];
            NSString* supportRoot = [XTCommandLineOptions resolveSupportRoot:nil];
            if (supportRoot)
                {
                NSMutableArray<NSString*>* symFiles = [NSMutableArray array];
                // Heuristic: pick "atari" as the default platform, since
                // that's the only one xtc currently targets.  Per-target
                // .sym discovery is the driver's job — standalone xta
                // can't see the -m flag.
                NSArray<NSString*>* symDirs = @[
                    [[supportRoot stringByAppendingPathComponent:@"atari"]
                        stringByAppendingPathComponent:@"symbols"],
                    [[supportRoot stringByAppendingPathComponent:@"generic"]
                        stringByAppendingPathComponent:@"symbols"],
                ];
                for (NSString* dir in symDirs)
                    {
                    NSArray<NSString*>* entries = [fm contentsOfDirectoryAtPath:dir error:NULL];
                    NSArray<NSString*>* sorted = [entries sortedArrayUsingSelector:@selector(compare:)];
                    for (NSString* name in sorted)
                        {
                        if (![name.pathExtension isEqualToString:@"sym"])
                            continue;
                        [symFiles addObject:[dir stringByAppendingPathComponent:name]];
                        }
                    }
                if (symFiles.count > 0)
                    assembler.symbolsFiles = symFiles;
                }
            }
        if (splitBanking)
            {
            assembler.hasSplitBanking = YES;
            assembler.dataWindowStart = dataWindowStart;
            assembler.dataWindowEnd = dataWindowEnd;
            // codeBankReg/dataBankReg default to $82/$83 inside
            // XAAssembler when not explicitly set by the driver.
            }
        // Layout-driven banking (task #60). When -L names a layout with
        // a [banking] section, configure the assembler from it exactly
        // as the in-process driver does from its XTMemoryModel — the
        // layout is the single source of truth for the bank windows and
        // registers. A [banking] section implies banked output.
        if (layoutPath)
            {
            NSError* lerr = nil;
            XTMemoryModel* m = [XTLinkerScriptParser parseFile:layoutPath error:&lerr];
            if (!m)
                {
                fprintf(stderr, "xcc-as: cannot read layout '%s': %s\n",
                        layoutPath.UTF8String,
                        lerr.localizedDescription.UTF8String);
                return 1;
                }
            if (m.hasBanking)
                {
                banked = YES;
                assembler.bankedMode = YES;
                assembler.bankWindowStart = m.bankWindowStart;
                assembler.bankWindowEnd = m.bankWindowEnd;
                // Non-banked code lands in the layout's `main` region.
                // writeBankedXEX bounds each main segment by
                // mainRegionStart..mainRegionEnd, so span them across the
                // declared main ranges (first start … last end) — the
                // backend `.org`s its unbanked block there and xta's
                // .code_regions auto-spill bridges any internal gap.
                if (m.mainRegionRanges.count > 0)
                    {
                    assembler.mainRegionStart =
                        (uint16_t)m.mainRegionRanges.firstObject[0].unsignedIntegerValue;
                    assembler.mainRegionEnd =
                        (uint16_t)m.mainRegionRanges.lastObject[1].unsignedIntegerValue;
                    }
                // Bank-register addresses apply to every banked layout, not
                // just split ones: a single-window layout can relocate the
                // selectors (xt: $D5C0/$D5C1) via `registers`. These feed
                // the preload-stub stores and the `__bank_code_reg` /
                // `__bank_data_reg` predefined symbols.
                if (m.codeBankReg)
                    assembler.codeBankReg = m.codeBankReg;
                if (m.dataBankReg)
                    assembler.dataBankReg = m.dataBankReg;
                if (m.hasSplitBanking)
                    {
                    assembler.hasSplitBanking = YES;
                    assembler.dataWindowStart = m.dataWindowStart;
                    assembler.dataWindowEnd = m.dataWindowEnd;
                    }
                if (m.hasRegionCBanking)
                    {
                    assembler.regCWindowStart = m.regCWindowStart;
                    assembler.regCWindowEnd = m.regCWindowEnd;
                    assembler.regCBankRegLo = m.regCBankRegLo;
                    assembler.regCBankRegHi = m.regCBankRegHi;
                    }
                }
            }

        for (NSString* name in defines)
            {
            [assembler defineSymbol:name value:defines[name]];
            }

        NSArray<XASegment*>* segments = [assembler assembleSource:source
                                                         filename:inputFiles[0]];
        // Print warnings
        for (NSString* w in assembler.warnings)
            {
            fprintf(stderr, "xcc-as: warning: %s\n", w.UTF8String);
            }

        if (!segments)
            {
            for (NSString* e in assembler.errors)
                {
                fprintf(stderr, "xcc-as: error: %s\n", e.UTF8String);
                }
            return 1;
            }

        // Determine entry point (first segment's origin, or $3400 default)
        uint16_t entry = segments.count > 0 ? segments[0].origin : 0x3400;

        // Determine output format: explicit -f, or auto-detect from extension
        BOOL usePRG = [formatStr isEqualToString:@"prg"] ||
                      (!formatStr && [outputPath.pathExtension.lowercaseString isEqualToString:@"prg"]);

        // Write output
        BOOL ok;
        if (usePRG)
            {
            ok = [assembler writePRG:segments entryPoint:entry toFile:outputPath];
            }
        else if (banked)
            {
            ok = [assembler writeBankedXEX:segments entryPoint:entry toFile:outputPath];
            }
        else
            {
            ok = [assembler writeXEX:segments entryPoint:entry toFile:outputPath];
            }

        if (!ok)
            {
            fprintf(stderr, "xcc-as: error: cannot write '%s'\n", outputPath.UTF8String);
            return 1;
            }

        // Listing
        if (listingPath)
            {
            NSString* listing = [assembler generateListing];
            if (listing)
                {
                [listing writeToFile:listingPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                }
            }

        NSUInteger totalBytes = 0;
        for (XASegment* s in segments)
            totalBytes += s.data.length;
        fprintf(stderr, "xcc-as: assembled '%s' -> '%s' (%lu bytes, %lu segment%s)\n",
                inputFiles[0].UTF8String, outputPath.UTF8String,
                (unsigned long)totalBytes, (unsigned long)segments.count,
                segments.count == 1 ? "" : "s");

        return 0;
        }
    }
