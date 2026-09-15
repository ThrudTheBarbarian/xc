// xtcln-win64 — the self-hosted last stage for x86-64 Windows, sibling of
// xtcln-arm64 and xtcln-x86_64. Assembles the `.s` the win64 backend emits with
// XAX86_64Assembler (shared verbatim with the Linux target — same backend, same
// directive set) and writes a PE/COFF .exe with XTPEWriter. No mingw, no
// lld-link, no Windows SDK.
//
//   xtcln-win64 <input.s>... -o <output.exe> [-e <entry>] [--dump]
//                            [-import <dll>:<sym>[,<sym>...]]
//
// Unlike the Linux target, imports are unavoidable: Windows has no stable
// syscall ABI, so even a freestanding program reaches the OS through
// kernel32.dll. `-import` declares what may be resolved that way; anything else
// undefined is an error, not a zero-filled call.
#import <Foundation/Foundation.h>
#import "XTRegexCompat.h"
#import "XAX86_64Assembler.h"
#import "XTPEWriter.h"

// Merge one COFF object into the growing image (defined below main).
static BOOL mergeCoffObject(NSDictionary* obj, NSString* whence, NSUInteger oi,
                            NSMutableData* mtext, NSMutableData* mdata,
                            NSMutableDictionary<NSString*, NSNumber*>* msyms,
                            NSMutableSet<NSString*>* mdataSyms,
                            NSMutableArray<XAX86_64Fixup*>* mfix);

int main(int argc, const char* argv[])
    {
    @autoreleasepool
        {
        // Object mode (`xcc -c`):
        //   xcc-ln-win64 --object <in.s> <out.o>
        // Assemble and STOP. Nothing is bound: every unresolved fixup becomes a
        // relocation and every symbol it names becomes an undefined entry — which
        // includes the kernel32 imports, since an OBJECT declares no import table.
        // Stage 1 of private:docs/Design/separate-compilation.md.
        if (argc >= 2 && strcmp(argv[1], "--object") == 0)
            {
            if (argc < 4)
                {
                fprintf(stderr, "usage: %s --object <in.s> <out.o>\n", argv[0]);
                return 2;
                }
            NSError* oerr = nil;
            NSString* osrc = [NSString stringWithContentsOfFile:@(argv[2])
                                                       encoding:NSUTF8StringEncoding
                                                          error:&oerr];
            if (!osrc)
                {
                fprintf(stderr, "xcc-ln-win64: cannot read '%s': %s\n",
                        argv[2], oerr.localizedDescription.UTF8String);
                return 1;
                }
            XAX86_64Assembler* oas = [[XAX86_64Assembler alloc] init];
            NSData* otext = [oas assemble:osrc error:&oerr];
            if (!otext)
                {
                fprintf(stderr, "xcc-ln-win64: assembly failed: %s\n",
                        oerr.localizedDescription.UTF8String);
                return 1;
                }
            NSData* obj = [XTPEWriter objectFromText:otext
                                                data:oas.data
                                             symbols:oas.symbols
                                         dataSymbols:oas.dataSymbols
                                       globalSymbols:oas.globalSymbols
                                              fixups:oas.fixups
                                               error:&oerr];
            if (!obj)
                {
                fprintf(stderr, "xcc-ln-win64: %s\n", oerr.localizedDescription.UTF8String);
                return 1;
                }
            if (![obj writeToFile:@(argv[3]) atomically:YES])
                {
                fprintf(stderr, "xcc-ln-win64: cannot write '%s'\n", argv[3]);
                return 1;
                }
            return 0;
            }
        NSMutableArray<NSString*>* inputs = [NSMutableArray array];
        NSString *output = nil, *entry = @"_start";
        NSMutableDictionary<NSString*, NSMutableArray<NSString*>*>* imports =
            [NSMutableDictionary dictionary];
        // symbol → owning DLL, from -importmap. Folded into `imports` after parsing,
        // so explicit -import entries take precedence.
        NSMutableDictionary<NSString*, NSString*>* mapOwner = [NSMutableDictionary dictionary];
        BOOL dump = NO;
        for (int i = 1; i < argc; i++)
            {
            NSString* a = @(argv[i]);
            if ([a isEqualToString:@"-o"] && i + 1 < argc)
                output = @(argv[++i]);
            else if ([a isEqualToString:@"-e"] && i + 1 < argc)
                entry = @(argv[++i]);
            else if ([a isEqualToString:@"--dump"])
                dump = YES;
            else if ([a isEqualToString:@"-import"] && i + 1 < argc)
                {
                NSString* spec = @(argv[++i]);
                NSRange colon = [spec rangeOfString:@":"];
                if (colon.location == NSNotFound)
                    {
                    fprintf(stderr, "xcc-ln-win64: -import wants <dll>:<sym>[,<sym>...]\n");
                    return 2;
                    }
                NSString* dll = [spec substringToIndex:colon.location];
                if (!imports[dll])
                    imports[dll] = [NSMutableArray array];
                for (NSString* s in [[spec substringFromIndex:colon.location + 1]
                         componentsSeparatedByString:@","])
                    if (s.length)
                        [imports[dll] addObject:s];
                }
            else if ([a isEqualToString:@"-importmap"] && i + 1 < argc)
                {
                // A generated symbol<TAB>DLL table (support/win64/win32-imports.map).
                // Without it the only importable names are those spelled out in
                // -import, so a real Win32 call (GetStockObject, CreateWindowExA, …)
                // cannot link at all on the self-hosted path. Explicit -import wins:
                // the map only supplies owners we do not already have.
                NSString* mapPath = @(argv[++i]);
                NSString* body = [NSString stringWithContentsOfFile:mapPath
                                                           encoding:NSUTF8StringEncoding
                                                              error:NULL];
                if (!body)
                    {
                    fprintf(stderr, "xcc-ln-win64: cannot read import map '%s'\n", argv[i]);
                    return 2;
                    }
                for (NSString* ln in [body componentsSeparatedByString:@"\n"])
                    {
                    if (ln.length == 0 || [ln hasPrefix:@"#"])
                        continue;
                    NSRange tab = [ln rangeOfString:@"\t"];
                    if (tab.location == NSNotFound)
                        continue;
                    NSString* sym = [ln substringToIndex:tab.location];
                    NSString* dll = [[ln substringFromIndex:tab.location + 1]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (!sym.length || !dll.length)
                        continue;
                    if (!mapOwner[sym])
                        mapOwner[sym] = dll;
                    }
                }
            else if ([a hasPrefix:@"-"])
                {
                fprintf(stderr, "xcc-ln-win64: unknown option '%s'\n", argv[i]);
                return 2;
                }
            else
                [inputs addObject:a];
            }
        if (!inputs.count || (!output && !dump))
            {
            fprintf(stderr, "usage: xtcln-win64 <input.s>... -o <output.exe> [-e entry] "
                            "[-import <dll>:<sym>,...] [-importmap <file>] [--dump]\n");
            return 2;
            }
            // Fold the map in. Listing a symbol here does NOT put it in the output: the
            // PE writer emits a descriptor only for names the program actually
            // references, so the whole table costs nothing in the binary.
            {
            NSMutableSet<NSString*>* explicit = [NSMutableSet set];
            for (NSString* dll in imports)
                [explicit addObjectsFromArray:imports[dll]];
            [mapOwner enumerateKeysAndObjectsUsingBlock:^(NSString* sym, NSString* dll, BOOL* stop) {
              if ([explicit containsObject:sym])
                  return;
              if (!imports[dll])
                  imports[dll] = [NSMutableArray array];
              [imports[dll] addObject:sym];
            }];
            }

        // Concatenate the inputs, renaming each file's local labels so they cannot
        // collide — clang restarts its `.LBB` numbering per translation unit, so a
        // plain `cat` of two generated runtime files makes the first one's branches
        // land inside the second.
        NSError* err = nil;
        NSMutableString* src = [NSMutableString string];
        NSRegularExpression* localLbl =
            [NSRegularExpression regularExpressionWithPattern:@"\\.L([A-Za-z0-9_$.]*)"
                                                      options:0
                                                        error:NULL];
        // `.o` inputs are merged AFTER the assembled text (below); everything else
        // is source and is concatenated here. Stage 2 of separate-compilation.
        // `.a` inputs are POOLS, pulled from on demand further down.
        NSMutableArray<NSString*>* objInputs = [NSMutableArray array];
        NSMutableArray<NSString*>* archives = [NSMutableArray array];
        for (NSUInteger i = 0; i < inputs.count; i++)
            {
            if ([inputs[i].pathExtension isEqualToString:@"a"])
                {
                [archives addObject:inputs[i]];
                continue;
                }
            if ([inputs[i].pathExtension isEqualToString:@"o"])
                {
                [objInputs addObject:inputs[i]];
                continue;
                }
            NSString* one = [NSString stringWithContentsOfFile:inputs[i]
                                                      encoding:NSUTF8StringEncoding
                                                         error:&err];
            if (!one)
                {
                fprintf(stderr, "xcc-ln-win64: cannot read '%s': %s\n", inputs[i].UTF8String,
                        err.localizedDescription.UTF8String);
                return 1;
                }
            if (inputs.count > 1)
                one = XTRegexReplace(localLbl, one,
                                     [NSString stringWithFormat:@".L%luZ$1", (unsigned long)i]);
            [src appendString:one];
            [src appendString:@"\n"];
            }

        XAX86_64Assembler* as = [[XAX86_64Assembler alloc] init];
        NSData* text = [as assemble:src error:&err];
        if (!text)
            {
            fprintf(stderr, "xcc-ln-win64: %s\n", err.localizedDescription.UTF8String);
            return 1;
            }
        if (dump)
            {
            printf("text %lu bytes, data %lu bytes, %lu symbols, %lu unresolved fixups\n",
                   (unsigned long)text.length, (unsigned long)as.data.length,
                   (unsigned long)as.symbols.count, (unsigned long)as.fixups.count);
            if (!output)
                return 0;
            }

        // ── merge the `.o` inputs ─────────────────────────────────────────────
        // The assembled text goes first, so its symbol offsets stay valid and only
        // the objects need rebasing. A STATIC symbol is tagged per object: two
        // objects may each define a same-named helper, and registering both under
        // the bare name would silently bind every reference to whichever came last.
        NSMutableData* mtext = [text mutableCopy];
        NSMutableData* mdata = [as.data mutableCopy] ?: [NSMutableData data];
        NSMutableDictionary<NSString*, NSNumber*>* msyms = [as.symbols mutableCopy];
        NSMutableSet<NSString*>* mdataSyms = [as.dataSymbols mutableCopy] ?: [NSMutableSet set];
        NSMutableArray<XAX86_64Fixup*>* mfix = [as.fixups mutableCopy] ?: [NSMutableArray array];
        for (NSUInteger oi = 0; oi < objInputs.count; oi++)
            {
            NSDictionary* obj = [XTPEWriter objectAtPath:objInputs[oi]];
            if (!obj)
                {
                fprintf(stderr, "xcc-ln-win64: error: '%s' is not a readable x86-64 COFF object\n",
                        objInputs[oi].UTF8String);
                return 1;
                }
            if (!mergeCoffObject(obj, objInputs[oi], oi, mtext, mdata, msyms, mdataSyms, mfix))
                return 1;
            }
        // ── pull from static archives, on demand ──────────────────────────────
        // A `.a` is not linked; it is a POOL. A member joins the image only if it
        // defines something still undefined, and pulling one can make new names
        // undefined in turn — so this iterates to a fixpoint. Same shape as the
        // x86-64 linker's musl pull; the only difference is the container.
        if (archives.count)
            {
            NSMutableArray<NSDictionary*>* pool = [NSMutableArray array];
            NSMutableArray<NSString*>* poolFrom = [NSMutableArray array];
            for (NSString* a in archives)
                {
                NSArray<NSDictionary*>* ms = [XTPEWriter objectsInArchive:a];
                if (!ms)
                    {
                    fprintf(stderr, "xcc-ln-win64: error: '%s' is not a static archive\n",
                            a.UTF8String);
                    return 1;
                    }
                for (NSDictionary* m in ms)
                    {
                    [pool addObject:m];
                    [poolFrom addObject:a];
                    }
                }
            NSMutableSet<NSNumber*>* taken = [NSMutableSet set];
            BOOL progress = YES;
            while (progress)
                {
                progress = NO;
                NSMutableSet<NSString*>* needed = [NSMutableSet set];
                for (XAX86_64Fixup* f in mfix)
                    if (f.symbol.length && !msyms[f.symbol])
                        [needed addObject:f.symbol];
                if (!needed.count)
                    break;
                for (NSUInteger mi = 0; mi < pool.count; mi++)
                    {
                    if ([taken containsObject:@(mi)])
                        continue;
                    NSDictionary* obj = pool[mi];
                    NSArray<NSString*>* snames = obj[@"symnames"];
                    NSArray<NSDictionary*>* sdefs = obj[@"symdefs"];
                    BOOL defines = NO;
                    for (NSUInteger si = 0; si < snames.count && !defines; si++)
                        if ([sdefs[si][@"where"] intValue] && [sdefs[si][@"ext"] boolValue] && [needed containsObject:snames[si]])
                            defines = YES;
                    if (!defines)
                        continue;
                    [taken addObject:@(mi)];
                    progress = YES;
                    if (!mergeCoffObject(obj, [NSString stringWithFormat:@"%@(%@)", poolFrom[mi].lastPathComponent, obj[@"member"]],
                                         1000 + mi, mtext, mdata, msyms, mdataSyms, mfix))
                        return 1;
                    }
                }
            }
        if (objInputs.count || archives.count)
            text = mtext;

        NSData* pe = [XTPEWriter executableFromText:text
                                               data:mdata
                                            symbols:msyms
                                        dataSymbols:mdataSyms
                                             fixups:mfix
                                        entrySymbol:entry
                                            imports:imports
                                              error:&err];
        if (!pe)
            {
            fprintf(stderr, "xcc-ln-win64: %s\n", err.localizedDescription.UTF8String);
            return 1;
            }
        if (![pe writeToFile:output atomically:YES])
            {
            fprintf(stderr, "xcc-ln-win64: cannot write '%s'\n", output.UTF8String);
            return 1;
            }
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0755}
                                         ofItemAtPath:output
                                                error:NULL];
        return 0;
        }
    }

// Merge one COFF object into the growing image. `oi` tags this object's STATIC
// symbols so two objects may each define a same-named helper without the second
// silently capturing the first's references.
static BOOL mergeCoffObject(NSDictionary* obj, NSString* whence, NSUInteger oi,
                            NSMutableData* mtext, NSMutableData* mdata,
                            NSMutableDictionary<NSString*, NSNumber*>* msyms,
                            NSMutableSet<NSString*>* mdataSyms,
                            NSMutableArray<XAX86_64Fixup*>* mfix)
    {
        {
        while (mtext.length & 15)
            {
            uint8_t z = 0;
            [mtext appendBytes:&z length:1];
            }
        uint64_t tbase = mtext.length;
        [mtext appendData:obj[@"text"]];
        NSData* odata = obj[@"data"];
        uint64_t dbase = mdata.length;
        if (odata.length)
            {
            while (mdata.length & 7)
                {
                uint8_t z = 0;
                [mdata appendBytes:&z length:1];
                }
            dbase = mdata.length;
            [mdata appendData:odata];
            }
        NSArray<NSString*>* snames = obj[@"symnames"];
        NSArray<NSDictionary*>* sdefs = obj[@"symdefs"];
        NSString* (^tagged)(NSUInteger) = ^NSString*(NSUInteger si) {
          NSString* n = snames[si];
          if ([sdefs[si][@"ext"] boolValue] || ![sdefs[si][@"where"] intValue])
              return n;
          return [NSString stringWithFormat:@"%@$o%lu", n, (unsigned long)oi];
        };
        for (NSUInteger si = 0; si < snames.count; si++)
            {
            int where = [sdefs[si][@"where"] intValue];
            if (!where || !snames[si].length)
                continue;
            NSString* nm = tagged(si);
            uint64_t off = [sdefs[si][@"off"] unsignedLongLongValue];
            // FIRST DEFINITION WINS — see the x86_64 linker for why: `-c`
            // compiles each module's imports INTO it, so a duplicate is the
            // same body twice (COMDAT semantics), not an error. `<Class>$cat`
            // is the exception, where two definitions mean two different
            // category tables (separate-compilation §4.2).
            if (msyms[nm])
                {
                // §4.3b: `C$cat$Names` (owner anchor) duplicated = the
                // same-NAMED category on one class in two modules; bare
                // `X$cat` duplicated = the class itself in two modules.
                NSRange catr = [nm rangeOfString:@"$cat$"];
                if (catr.location != NSNotFound)
                    {
                    fprintf(stderr, "xcc-ln-win64: error: two modules define category "
                                    "'%s' on class '%s' ('%s' defined twice). The category "
                                    "name is the extender's identity (separate-compilation "
                                    "§4.3b) — rename one, or compile both from one module\n",
                            [nm substringFromIndex:catr.location + 5].UTF8String,
                            [nm substringToIndex:catr.location].UTF8String, nm.UTF8String);
                    return NO;
                    }
                if ([nm hasSuffix:@"$cat"])
                    {
                    fprintf(stderr, "xcc-ln-win64: error: class '%s' is compiled "
                                    "into two modules ('%s', its category-chain table, "
                                    "defined twice)\n",
                            [nm substringToIndex:nm.length - 4].UTF8String, nm.UTF8String);
                    return NO;
                    }
                continue;
                }
            if (where == 1)
                msyms[nm] = @(tbase + off);
            else
                {
                msyms[nm] = @(dbase + off);
                [mdataSyms addObject:nm];
                }
            }
        for (NSDictionary* r in obj[@"relocs"])
            {
            uint32_t rt = [r[@"type"] unsignedIntValue];
            NSUInteger sn = [r[@"sym"] unsignedIntegerValue];
            if (rt != 0x04 /*IMAGE_REL_AMD64_REL32*/ || sn >= snames.count)
                {
                fprintf(stderr, "xcc-ln-win64: error: unhandled text relocation type %u "
                                "in '%s'\n",
                        rt, whence.UTF8String);
                return NO;
                }
            XAX86_64Fixup* f = [XAX86_64Fixup new];
            f.offset = tbase + [r[@"off"] unsignedLongLongValue];
            // Rel32 vs PC32 is not recorded in COFF and does not need to be:
            // the writer treats them identically, both being `S + A - P`.
            f.kind = XAX86FixupRel32;
            f.symbol = tagged(sn);
            f.addend = [r[@"addend"] longLongValue];
            [mfix addObject:f];
            }
        for (NSDictionary* r in obj[@"datarelocs"])
            {
            uint32_t rt = [r[@"type"] unsignedIntValue];
            NSUInteger sn = [r[@"sym"] unsignedIntegerValue];
            if (rt != 0x01 /*IMAGE_REL_AMD64_ADDR64*/ || sn >= snames.count)
                {
                fprintf(stderr, "xcc-ln-win64: error: unhandled data relocation type %u "
                                "in '%s'\n",
                        rt, whence.UTF8String);
                return NO;
                }
            XAX86_64Fixup* f = [XAX86_64Fixup new];
            f.offset = dbase + [r[@"off"] unsignedLongLongValue];
            f.kind = XAX86FixupAbs64;
            f.symbol = tagged(sn);
            f.addend = [r[@"addend"] longLongValue];
            [mfix addObject:f];
            }
        }
    return YES;
    }
