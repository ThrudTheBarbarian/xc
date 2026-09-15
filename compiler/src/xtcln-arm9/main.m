// xtcln-arm9 — the in-house last stage for ARM32, sibling of xtcln-arm64,
// xtcln-x86_64 and xtcln-win64. Assembles the `.s` the arm9 back end emits with
// XAArm32Assembler and writes an ELF32 relocatable with XTElf32Writer.
//
//   xcc-ln-arm9 --object <in.s> <out.o>
//   xcc-ln-arm9 --dump <in.s>            (the differential's canonical listing)
//
// It exists because `arm-none-eabi-gcc` is not available everywhere the
// compiler is: not on the Cortex-A9 itself, and not on a Windows host. `-c` for
// arm9 goes through here on every host.
//
//   xcc-ln-arm9 --shared -o <out.so> [-soname N] [-needed L] <in.s>...
//
// The link mode assembles every input as ONE unit (they are concatenated, with
// each file's local labels tagged so two runtime files cannot collide on
// `.L0`) and writes the loader-hosted ET_DYN. No gcc, no ld, no libgcc.
#import <Foundation/Foundation.h>
#import "XTRegexCompat.h"
#import "XAArm32Assembler.h"
#import "XTElf32Writer.h"
#import "XTArArchive.h"

int main(int argc, const char* argv[])
    {
    @autoreleasepool
        {
        BOOL dump = NO, shared = NO;
        NSString *inPath = nil, *outPath = nil, *soname = nil, *ifacePath = nil;
        NSMutableArray<NSString*>* inputs = [NSMutableArray array];
        NSMutableArray<NSString*>* needed = [NSMutableArray array];
        for (int i = 1; i < argc; i++)
            {
            NSString* a = @(argv[i]);
            if ([a isEqualToString:@"--object"])
                continue;
            else if ([a isEqualToString:@"--dump"])
                dump = YES;
            // Read one .o back and print what the reader found. Verifying the
            // reader ALONE, against `nm`, before anything merges its output.
            else if ([a isEqualToString:@"--dump-obj"] && i + 1 < argc)
                {
                NSString* op = @(argv[++i]);
                NSDictionary* o = [XTElf32Writer objectFromData:
                                                     [NSData dataWithContentsOfFile:op] ?: [NSData data]];
                if (!o)
                    {
                    fprintf(stderr, "not a readable ARM ELF32 object\n");
                    return 1;
                    }
                printf("text %lu data %lu symbols %lu relocs %lu\n",
                       (unsigned long)[o[@"text"] length], (unsigned long)[o[@"data"] length],
                       (unsigned long)[o[@"symbols"] count], (unsigned long)[o[@"relocs"] count]);
                NSUInteger nsec[4] = {0, 0, 0, 0};
                NSUInteger glob = 0;
                for (XAArm32Symbol* sy in o[@"symbols"])
                    {
                    if (sy.section < 4)
                        nsec[sy.section]++;
                    if (sy.isGlobal && sy.section)
                        glob++;
                    }
                printf("  undef=%lu text=%lu data=%lu common=%lu  global-defined=%lu\n",
                       (unsigned long)nsec[0], (unsigned long)nsec[1],
                       (unsigned long)nsec[2], (unsigned long)nsec[3], (unsigned long)glob);
                return 0;
                }
            else if ([a isEqualToString:@"--shared"])
                shared = YES;
            else if ([a isEqualToString:@"-o"] && i + 1 < argc)
                outPath = @(argv[++i]);
            else if ([a isEqualToString:@"-soname"] && i + 1 < argc)
                soname = @(argv[++i]);
            else if ([a isEqualToString:@"-needed"] && i + 1 < argc)
                [needed addObject:@(argv[++i])];
            else if ([a isEqualToString:@"-iface"] && i + 1 < argc)
                ifacePath = @(argv[++i]);
            else if ([a hasPrefix:@"-"])
                {
                fprintf(stderr, "xcc-ln-arm9: unknown option '%s'\n", argv[i]);
                return 2;
                }
            else
                [inputs addObject:a];
            }
        if (!shared)
            {
            inPath = inputs.count > 0 ? inputs[0] : nil;
            if (!outPath)
                outPath = inputs.count > 1 ? inputs[1] : nil;
            }
        if (!inputs.count || (!outPath && !dump))
            {
            fprintf(stderr, "usage: %s --object <in.s> <out.o>\n"
                            "       %s --shared -o <out.so> [-soname N] [-needed L] "
                            "[-iface F] <in.s|obj.o|lib.a>...\n"
                            "       %s --dump <in.s>\n",
                    argv[0], argv[0], argv[0]);
            return 2;
            }

        NSError* err = nil;
        NSString* src = nil;
        NSArray<NSString*>* objInputs = @[];
        NSArray<NSString*>* arInputs = @[];
        if (shared)
            {
            // Concatenate, tagging each file's local labels so two of them cannot
            // collide on `.L0` — the same thing the arm64 and x86_64 linkers do,
            // and for the same reason: a compiler restarts its numbering per file.
            // `.o` inputs are MERGED after assembly (below), `.a` inputs are POOLS
            // pulled from on demand; the rest is source.
            NSMutableArray<NSString*>* objs = [NSMutableArray array];
            NSMutableArray<NSString*>* ars = [NSMutableArray array];
            for (NSString* p in [inputs copy])
                {
                if ([p.pathExtension isEqualToString:@"o"])
                    [objs addObject:p];
                else if ([p.pathExtension isEqualToString:@"a"])
                    [ars addObject:p];
                }
            [inputs removeObjectsInArray:objs];
            [inputs removeObjectsInArray:ars];
            objInputs = objs;
            arInputs = ars;
            NSMutableString* all = [NSMutableString string];
            NSRegularExpression* localLbl =
                [NSRegularExpression regularExpressionWithPattern:@"\\.L([A-Za-z0-9_$.]*)"
                                                          options:0
                                                            error:NULL];
            for (NSUInteger i = 0; i < inputs.count; i++)
                {
                NSString* one = [NSString stringWithContentsOfFile:inputs[i]
                                                          encoding:NSUTF8StringEncoding
                                                             error:&err];
                if (!one)
                    {
                    fprintf(stderr, "xcc-ln-arm9: cannot read '%s': %s\n",
                            inputs[i].UTF8String, err.localizedDescription.UTF8String);
                    return 1;
                    }
                if (inputs.count > 1)
                    one = XTRegexReplace(localLbl, one,
                                         [NSString stringWithFormat:@".L%luZ$1", (unsigned long)i]);
                [all appendString:one];
                [all appendString:@"\n"];
                }
            src = all;
            }
        else
            {
            src = [NSString stringWithContentsOfFile:inPath
                                            encoding:NSUTF8StringEncoding
                                               error:&err];
            }
        if (!src)
            {
            fprintf(stderr, "xcc-ln-arm9: cannot read '%s': %s\n",
                    inPath.UTF8String, err.localizedDescription.UTF8String);
            return 1;
            }
        XAArm32Assembler* as = [[XAArm32Assembler alloc] init];
        NSData* text = [as assemble:src error:&err];
        if (!text)
            {
            // An unsupported mnemonic is named, not counted: the point of the
            // message is to say what to implement.
            fprintf(stderr, "xcc-ln-arm9: %s\n", err.localizedDescription.UTF8String);
            return 1;
            }

        if (dump)
            {
            // A canonical listing of everything the assembler produced, so a second
            // implementation can be compared against this one byte for byte. It
            // prints the whole state and nothing derived from it — a dump that
            // summarises is a dump that hides a divergence.
            NSMutableString* o = [NSMutableString string];
            void (^hex)(NSString*, NSData*) = ^(NSString* tag, NSData* d) {
              [o appendFormat:@"%@ %lu\n", tag, (unsigned long)d.length];
              const uint8_t* p = d.bytes;
              for (NSUInteger i = 0; i < d.length; i += 16)
                  {
                  [o appendFormat:@"%08lx ", (unsigned long)i];
                  for (NSUInteger j = i; j < d.length && j < i + 16; j++)
                      [o appendFormat:@"%02x", p[j]];
                  [o appendString:@"\n"];
                  }
            };
            hex(@"text", text);
            hex(@"data", as.data);
            [o appendFormat:@"symbols %lu\n", (unsigned long)as.symbols.count];
            for (XAArm32Symbol* s in as.symbols)
                [o appendFormat:@"  %@ sec=%u val=%u size=%u%@%@%@\n", s.name,
                                s.section, s.value, s.size, s.isGlobal ? @" globl" : @"",
                                s.isFunction ? @" func" : @"", s.hidden ? @" hidden" : @""];
            [o appendFormat:@"relocs %lu\n", (unsigned long)as.relocations.count];
            for (XAArm32Reloc* r in as.relocations)
                [o appendFormat:@"  sec=%u off=%u type=%u %@\n",
                                r.section, r.offset, (unsigned)r.kind, r.symbol];
            fputs(o.UTF8String, stdout);
            if (!outPath)
                return 0;
            }

        // ── merge the `.o` inputs ─────────────────────────────────────────────
        // The assembled text goes FIRST, so its own offsets stay valid and only the
        // objects are rebased. The merged whole then goes through the SAME
        // sharedObjectFromText: call an all-source link makes, so a linked-from-
        // objects image has the same shape rather than a second code path.
        NSMutableData* mtext = [text mutableCopy];
        NSMutableData* mdata = [(as.data ?: [NSData data]) mutableCopy];
        NSMutableArray<XAArm32Symbol*>* msyms = [(as.symbols ?: @[]) mutableCopy];
        NSMutableArray<XAArm32Reloc*>* mrels = [(as.relocations ?: @[]) mutableCopy];
        if (objInputs.count || arInputs.count)
            {
            NSMutableSet<NSString*>* defined = [NSMutableSet set];
            for (XAArm32Symbol* sy in msyms)
                if (sy.section)
                    [defined addObject:sy.name];
            __block BOOL mergeFailed = NO;
            BOOL (^mergeObj)(NSDictionary*) = ^BOOL(NSDictionary* o) {
              while (mtext.length & 3)
                  {
                  uint8_t z = 0;
                  [mtext appendBytes:&z length:1];
                  }
              uint32_t tbase = (uint32_t)mtext.length;
              [mtext appendData:o[@"text"]];
              while (mdata.length & 3)
                  {
                  uint8_t z = 0;
                  [mdata appendBytes:&z length:1];
                  }
              uint32_t dbase = (uint32_t)mdata.length;
              if ([o[@"data"] length])
                  [mdata appendData:o[@"data"]];
              for (XAArm32Symbol* sy in o[@"symbols"])
                  {
                  if (!sy.section)
                      continue; // undefined: the link resolves it
                  // FIRST DEFINITION WINS, as the other three linkers do: `-c`
                  // compiles each module's imports INTO it, so a duplicate is the
                  // same body twice rather than a conflict.
                  if ([defined containsObject:sy.name])
                      {
                      // ...with the category-chain exceptions (§4.3b), where
                      // first-wins would run one module's category method as the
                      // other's body — a wrong call rather than a missing symbol.
                      // `C$cat$Names` (owner anchor) duplicated = the same-NAMED
                      // category on one class in two modules; bare `X$cat`
                      // duplicated = the class itself in two modules.
                      NSRange catr = [sy.name rangeOfString:@"$cat$"];
                      if (catr.location != NSNotFound)
                          {
                          fprintf(stderr, "xcc-ln-arm9: error: two modules define category "
                                          "'%s' on class '%s' ('%s' defined twice). The category "
                                          "name is the extender's identity (separate-compilation "
                                          "§4.3b) — rename one, or compile both from one module\n",
                                  [sy.name substringFromIndex:catr.location + 5].UTF8String,
                                  [sy.name substringToIndex:catr.location].UTF8String,
                                  sy.name.UTF8String);
                          mergeFailed = YES;
                          return NO;
                          }
                      if ([sy.name hasSuffix:@"$cat"])
                          {
                          fprintf(stderr, "xcc-ln-arm9: error: class '%s' is compiled into "
                                          "two modules ('%s', its category-chain table, defined "
                                          "twice)\n",
                                  [sy.name substringToIndex:sy.name.length - 4].UTF8String,
                                  sy.name.UTF8String);
                          mergeFailed = YES;
                          return NO;
                          }
                      continue;
                      }
                  [defined addObject:sy.name];
                  // Drop the assembler's UNDEFINED entry for this name. The
                  // program referenced the symbol before the object supplying it
                  // was merged, so both records exist; leaving the stale one in
                  // puts the SAME name in .dynsym twice, once defined and once
                  // UND, and a loader resolving by name can pick either.
                  for (NSUInteger k = 0; k < msyms.count; k++)
                      if (!msyms[k].section && [msyms[k].name isEqualToString:sy.name])
                          {
                          [msyms removeObjectAtIndex:k];
                          break;
                          }
                  // A COMMON symbol's `value` is its ALIGNMENT, not an offset —
                  // the writer assigns its storage later. Rebasing it would turn
                  // an alignment into a bogus address.
                  if (sy.section == 1)
                      sy.value += tbase;
                  else if (sy.section == 2)
                      sy.value += dbase;
                  [msyms addObject:sy];
                  }
              for (XAArm32Reloc* r in o[@"relocs"])
                  {
                  r.offset += (r.section == 1) ? tbase : dbase;
                  [mrels addObject:r];
                  }
              return YES;
            };
            for (NSString* op in objInputs)
                {
                NSDictionary* o = [XTElf32Writer objectFromData:
                                                     [NSData dataWithContentsOfFile:op] ?: [NSData data]];
                if (!o)
                    {
                    fprintf(stderr, "xcc-ln-arm9: error: '%s' is not a readable ARM ELF32 "
                                    "object (or carries a relocation this linker does not emit)\n",
                            op.UTF8String);
                    return 1;
                    }
                if (!mergeObj(o) || mergeFailed)
                    return 1;
                }
            // ── pull from static archives, on demand ──────────────────────────
            // A `.a` is not linked, it is a POOL: a member joins only if it defines
            // something still undefined, and pulling one can make new names
            // undefined in turn, so this iterates to a fixpoint. Same shape as the
            // other three linkers; only the container reader differs.
            if (arInputs.count)
                {
                NSMutableArray<NSDictionary*>* pool = [NSMutableArray array];
                for (NSString* ap in arInputs)
                    {
                    NSArray<NSDictionary*>* ms = [XTArArchive membersOfArchive:ap];
                    if (!ms)
                        {
                        fprintf(stderr, "xcc-ln-arm9: error: '%s' is not a static archive\n",
                                ap.UTF8String);
                        return 1;
                        }
                    for (NSDictionary* m in ms)
                        {
                        NSDictionary* o = [XTElf32Writer objectFromData:m[@"data"]];
                        if (o)
                            [pool addObject:o]; // non-object members: skipped
                        }
                    }
                NSMutableSet<NSNumber*>* taken = [NSMutableSet set];
                BOOL progress = YES;
                while (progress)
                    {
                    progress = NO;
                    NSMutableSet<NSString*>* needed = [NSMutableSet set];
                    for (XAArm32Reloc* r in mrels)
                        if (r.symbol.length && ![defined containsObject:r.symbol])
                            [needed addObject:r.symbol];
                    if (!needed.count)
                        break;
                    for (NSUInteger mi = 0; mi < pool.count; mi++)
                        {
                        if ([taken containsObject:@(mi)])
                            continue;
                        BOOL defines = NO;
                        for (XAArm32Symbol* sy in pool[mi][@"symbols"])
                            if (sy.section && sy.isGlobal && [needed containsObject:sy.name])
                                {
                                defines = YES;
                                break;
                                }
                        if (!defines)
                            continue;
                        [taken addObject:@(mi)];
                        progress = YES;
                        if (!mergeObj(pool[mi]) || mergeFailed)
                            return 1;
                        }
                    }
                }
            text = mtext;
            }

        NSData* obj;
        if (shared)
            {
            obj = [XTElf32Writer sharedObjectFromText:text
                                                 data:mdata
                                              symbols:msyms
                                          relocations:mrels
                                               needed:needed
                                               soname:soname
                                                iface:(ifacePath ? [NSData dataWithContentsOfFile:ifacePath] : nil)
                                                error:&err];
            if (!obj)
                {
                fprintf(stderr, "xcc-ln-arm9: %s\n", err.localizedDescription.UTF8String);
                return 1;
                }
            }
        else
            {
            obj = [XTElf32Writer objectFromText:text
                                           data:as.data
                                        symbols:as.symbols
                                    relocations:as.relocations];
            }
        if (![obj writeToFile:outPath atomically:YES])
            {
            fprintf(stderr, "xcc-ln-arm9: cannot write '%s'\n", outPath.UTF8String);
            return 1;
            }
        return 0;
        }
    }
