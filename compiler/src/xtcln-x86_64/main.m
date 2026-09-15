// xtcln-x86_64 — the self-hosted last stage for x86-64 Linux, the sibling of
// xtcln-arm64. Takes the `.s` the x86_64 backend emits, assembles it with
// XAX86_64Assembler, and writes a runnable ELF with XTElfWriter. No clang, no
// ld.lld, no musl — nothing from a Linux toolchain is involved.
//
//   xtcln-x86_64 <input.s> -o <output> [-e <entry>] [--dump]
//
// The link is static and whole-program: every symbol must be defined by the
// input plus whatever runtime is concatenated into it, so an undefined symbol is
// a hard error rather than something left to a loader.
#import <Foundation/Foundation.h>
#import "XTRegexCompat.h"
#import "XAX86_64Assembler.h"
#import "XTElfWriter.h"
#import "XTElfGC.h"

// Merge ONE ET_REL — an explicit `.o` or an archive member — into the image.
//
// The assembled text goes first, so its symbol offsets stay valid and only the
// objects need rebasing. A LOCAL symbol is tagged per object: two objects may
// each define a same-named static, and registering both under the bare name
// would silently bind every reference to whichever came last.
//
// FIRST DEFINITION WINS on a duplicate. `-c` compiles each module's imports
// INTO it, so two objects that both `#import "Stdio.xc"` each define every
// `Stdio$*`, and the injected `_xtc_obj_conforms` is in every object by
// construction: a duplicate is the same body twice, which is COMDAT semantics
// rather than an error. `<Class>$cat` is the exception, where two definitions
// mean two different category tables (separate-compilation §4.2).
static BOOL mergeElfObject(NSDictionary* obj, NSString* label, NSUInteger tag,
                           NSMutableData* mtext, NSMutableData* mdata,
                           NSMutableDictionary<NSString*, NSNumber*>* msyms,
                           NSMutableSet<NSString*>* mdataSyms,
                           NSMutableSet<NSString*>* mglobals,
                           NSMutableArray<XAX86_64Fixup*>* mfix,
                           NSMutableSet<NSString*>* mweak,
                           NSMutableSet<NSString*>* mweakdef,
                           NSMutableData* mtls,
                           NSMutableDictionary<NSString*, NSNumber*>* mtlsSyms,
                           NSMutableArray<NSDictionary*>* mtlsAbs,
                           NSMutableData* mbss,
                           NSMutableArray<NSString*>* mbssSyms,
                           uint64_t* mbssAlign,
                           XTElfGC* gc)
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
    // The object's OWN strictest data alignment, not a guess. An 8-byte
    // guess put musl's 16-byte `.rodata.cst16` constants on an 8-boundary
    // and `movaps` faulted — which showed up as printf working for one
    // conversion and dying on the next.
    uint64_t da = [obj[@"dataalign"] unsignedLongLongValue];
    if (da < 8)
        da = 8;
    if (odata.length)
        {
        while (mdata.length % da)
            {
            uint8_t z = 0;
            [mdata appendBytes:&z length:1];
            }
        dbase = mdata.length;
        [mdata appendData:odata];
        }
    // GC unit boundaries (bug 196): every section start and object start, and
    // every defined symbol — recorded BEFORE the duplicate check below, so a
    // dropped second definition still bounds its own bytes.
    [gc noteObjectText:tbase
               textEnd:tbase + [obj[@"text"] length]
                  data:dbase
               dataEnd:dbase + odata.length
             dataAlign:da
                 label:label];
    for (NSNumber* o in obj[@"textsecs"])
        [gc noteTextBound:tbase + o.unsignedLongLongValue];
    for (NSNumber* o in obj[@"datasecs"])
        [gc noteDataBound:dbase + o.unsignedLongLongValue];
    for (NSDictionary* sd in obj[@"symdefs"])
        {
        int w = [sd[@"where"] intValue];
        if (w == 1)
            [gc noteTextBound:tbase + [sd[@"off"] unsignedLongLongValue]];
        else if (w == 2 && [sd[@"size"] unsignedLongLongValue] > 0)
            [gc noteDataBound:dbase + [sd[@"off"] unsignedLongLongValue]];
        }
    // Thread-local image: concatenated like data, but its symbols are OFFSETS
    // within the per-thread block and its bytes are the initialisation image.
    uint64_t lbase = 0;
    NSData* otls = obj[@"tls"];
    if (otls.length)
        {
        uint64_t la = [obj[@"tlsalign"] unsignedLongLongValue] ?: 1;
        while (mtls.length % la)
            {
            uint8_t z = 0;
            [mtls appendBytes:&z length:1];
            }
        lbase = mtls.length;
        [mtls appendData:otls];
        }
    NSArray<NSString*>* snames = obj[@"symnames"];
    NSArray<NSDictionary*>* sdefs = obj[@"symdefs"];
    NSString* (^tagged)(NSUInteger) = ^NSString*(NSUInteger si) {
      NSString* n = snames[si];
      // A SECTION symbol has no name — a relocation against one says "this
      // section, plus the addend", which is how a compiler refers to its own
      // .rodata. Tagging an empty name produced `$o1967`, a symbol nothing
      // defines, and the link failed on a name that never existed. Give it one
      // that is unique to (object, index) and register the definition under
      // the same name.
      if (!n.length)
          return [NSString stringWithFormat:@".Lsec%lu$o%lu",
                                            (unsigned long)si, (unsigned long)tag];
      if ([sdefs[si][@"ext"] boolValue] || ![sdefs[si][@"where"] intValue])
          return n;
      return [NSString stringWithFormat:@"%@$o%lu", n, (unsigned long)tag];
    };
    for (NSUInteger si = 0; si < snames.count; si++)
        {
        int where = [sdefs[si][@"where"] intValue];
        BOOL weakDef = [sdefs[si][@"weak"] boolValue];
        if (!where)
            {
            // A WEAK undefined reference resolves to absolute 0 if nothing in
            // the link defines it (musl's `_DYNAMIC` static/dynamic probe).
            // Remember the name; leftovers get the 0 after the archive
            // fixpoint, when "nothing defines it" is finally a fact.
            if ([sdefs[si][@"weak"] boolValue] && snames[si].length)
                [mweak addObject:snames[si]];
            continue; // undefined: nothing to register
            }
        NSString* nm = tagged(si);
        uint64_t off = [sdefs[si][@"off"] unsignedLongLongValue];
        if (msyms[nm])
            {
            // §4.3b: `C$cat$Names` (owner anchor) duplicated = the same-NAMED
            // category on one class in two modules; bare `X$cat` duplicated =
            // the class itself compiled into two modules.
            NSRange catr = [nm rangeOfString:@"$cat$"];
            if (catr.location != NSNotFound)
                {
                fprintf(stderr, "xcc-ln-x86_64: error: two modules define category "
                                "'%s' on class '%s' ('%s' defined twice). The category name "
                                "is the extender's identity (separate-compilation §4.3b) — "
                                "rename one, or compile both from one module\n",
                        [nm substringFromIndex:catr.location + 5].UTF8String,
                        [nm substringToIndex:catr.location].UTF8String, nm.UTF8String);
                return NO;
                }
            if ([nm hasSuffix:@"$cat"])
                {
                fprintf(stderr, "xcc-ln-x86_64: error: class '%s' is compiled into "
                                "two modules ('%s', its category-chain table, defined "
                                "twice)\n",
                        [nm substringToIndex:nm.length - 4].UTF8String, nm.UTF8String);
                return NO;
                }
            // Strong beats weak, whatever the merge order (ELF rule). A weak
            // definition that arrived first steps aside for this strong one;
            // a weak arriving second is simply not registered.
            if (!weakDef && [mweakdef containsObject:nm])
                {
                [mweakdef removeObject:nm];
                [mdataSyms removeObject:nm];
                }
            else
                {
                continue;
                }
            }
        // COMMON -> NOBITS bss
        if (where == 5)
            {
            uint64_t cal = [sdefs[si][@"align"] unsignedLongLongValue];
            if (cal < 1)
                cal = 1;
            while (mbss.length % cal)
                {
                uint8_t z = 0;
                [mbss appendBytes:&z length:1];
                }
            msyms[nm] = @(mbss.length);
            [mbssSyms addObject:nm];
            [mdataSyms addObject:nm]; // resolves as a data address
            uint64_t csize = [sdefs[si][@"size"] unsignedLongLongValue];
            if (!csize)
                csize = 8;
            [mbss appendData:[NSMutableData dataWithLength:(NSUInteger)csize]];
            if (cal > *mbssAlign)
                *mbssAlign = cal;
            if ([sdefs[si][@"ext"] boolValue])
                [mglobals addObject:nm];
            if (weakDef)
                [mweakdef addObject:nm];
            continue;
            }
        // TLS: an offset, not an address
        if (where == 3)
            {
            if (!mtlsSyms[nm])
                mtlsSyms[nm] = @(lbase + off);
            continue;
            }
        if (where == 1)
            msyms[nm] = @(tbase + off);
        else
            {
            msyms[nm] = @(dbase + off);
            [mdataSyms addObject:nm];
            }
        if ([sdefs[si][@"ext"] boolValue])
            [mglobals addObject:nm];
        if (weakDef)
            [mweakdef addObject:nm];
        }
    // Relocations become fixups against the merged image. The assembler's fixup
    // semantics ARE the ELF ones (`S + A - P` for the PC-relative kinds, `S + A`
    // for the absolute one), so only the offsets move.
    for (NSDictionary* r in obj[@"relocs"])
        {
        uint32_t rt = [r[@"type"] unsignedIntValue];
        NSUInteger sn = [r[@"sym"] unsignedIntegerValue];
        if (sn >= snames.count)
            {
            fprintf(stderr, "xcc-ln-x86_64: bad relocation symbol index in '%s'\n",
                    label.UTF8String);
            return NO;
            }
        // 41/42 are [REX_]GOTPCRELX — a relaxable GOT load (finding #17: musl's
        // getenv.lo reads &__environ through one). The writer relaxes mov→lea.
        // 9 is plain GOTPCREL — NOT relaxable (libpq compares and SSE-loads the
        // slot as data), so the writer gives it a real link-time GOT slot.
        if (rt != 2 /*R_X86_64_PC32*/ && rt != 4 /*R_X86_64_PLT32*/ &&
            rt != 9 /*GOTPCREL*/ && rt != 23 /*TPOFF32 (local-exec TLS)*/ &&
            rt != 41 /*GOTPCRELX*/ && rt != 42 /*REX_GOTPCRELX*/)
            {
            fprintf(stderr, "xcc-ln-x86_64: error: unhandled text relocation type %u "
                            "in '%s'%s\n",
                    rt, label.UTF8String,
                    (rt == 19 || rt == 20 || rt == 22)
                        ? " (general/initial-exec TLS: build the library with "
                          "-ftls-model=local-exec, or file the relaxation)"
                        : "");
            return NO;
            }
        XAX86_64Fixup* f = [XAX86_64Fixup new];
        f.offset = tbase + [r[@"off"] unsignedLongLongValue];
        f.kind = (rt == 4)                ? XAX86FixupRel32
                 : (rt == 41 || rt == 42) ? XAX86FixupGotLoad
                 : (rt == 9)              ? XAX86FixupGotRef
                 : (rt == 23)             ? XAX86FixupTpoff32
                                          : XAX86FixupPC32;
        f.symbol = tagged(sn);
        f.addend = [r[@"addend"] longLongValue];
        [mfix addObject:f];
        }
    for (NSDictionary* r in obj[@"tlsrelocs"])
        {
        uint32_t rt = [r[@"type"] unsignedIntValue];
        NSUInteger sn = [r[@"sym"] unsignedIntegerValue];
        if (rt != 1 /*R_X86_64_64*/ || sn >= snames.count)
            {
            fprintf(stderr, "xcc-ln-x86_64: error: unhandled TLS-image relocation "
                            "type %u in '%s'\n",
                    rt, label.UTF8String);
            return NO;
            }
        // Applied into the MASTER image (every thread's copy inherits it):
        // rebased onto __xt_tls_hdr's data area after the merge completes.
        [mtlsAbs addObject:@{@"off" : @(lbase + [r[@"off"] unsignedLongLongValue]),
                             @"sym" : tagged(sn),
                             @"addend" : r[@"addend"]}];
        }
    for (NSDictionary* r in obj[@"datarelocs"])
        {
        uint32_t rt = [r[@"type"] unsignedIntValue];
        NSUInteger sn = [r[@"sym"] unsignedIntegerValue];
        // R_X86_64_64 is an absolute slot; PC32 in DATA is a position-independent
        // jump table, which musl's vfprintf uses and our back end never emits.
        if ((rt != 1 && rt != 2) || sn >= snames.count)
            {
            fprintf(stderr, "xcc-ln-x86_64: error: unhandled data relocation type %u "
                            "in '%s'\n",
                    rt, label.UTF8String);
            return NO;
            }
        XAX86_64Fixup* f = [XAX86_64Fixup new];
        f.offset = dbase + [r[@"off"] unsignedLongLongValue];
        f.kind = (rt == 2) ? XAX86FixupPC32Data : XAX86FixupAbs64;
        f.symbol = tagged(sn);
        f.addend = [r[@"addend"] longLongValue];
        [mfix addObject:f];
        }
    return YES;
    }

int main(int argc, const char* argv[])
    {
    @autoreleasepool
        {
        // Object mode (`xcc -c`):
        //   xcc-ln-x86_64 --object <in.s> <out.o>
        // Assemble and STOP. Nothing is bound: every unresolved fixup becomes a
        // relocation and every symbol it names becomes an undefined entry, which is
        // precisely the difference between an object and an executable.
        // Stage 1 of private:docs/Design/separate-compilation.md.
        if (argc >= 2 && strcmp(argv[1], "--object") == 0)
            {
            if (argc < 4)
                {
                fprintf(stderr, "usage: %s --object <in.s> <out.o>\n", argv[0]);
                return 2;
                }
            NSError* oerr = nil;
            NSString* src = [NSString stringWithContentsOfFile:@(argv[2])
                                                      encoding:NSUTF8StringEncoding
                                                         error:&oerr];
            if (!src)
                {
                fprintf(stderr, "xcc-ln-x86_64: cannot read '%s': %s\n",
                        argv[2], oerr.localizedDescription.UTF8String);
                return 1;
                }
            XAX86_64Assembler* oas = [[XAX86_64Assembler alloc] init];
            NSData* otext = [oas assemble:src error:&oerr];
            if (!otext)
                {
                fprintf(stderr, "xcc-ln-x86_64: assembly failed: %s\n",
                        oerr.localizedDescription.UTF8String);
                return 1;
                }
            NSData* obj = [XTElfWriter objectFromText:otext
                                                 data:oas.data
                                              symbols:oas.symbols
                                          dataSymbols:oas.dataSymbols
                                        globalSymbols:oas.globalSymbols
                                              commons:oas.commonSymbols
                                               fixups:oas.fixups
                                                error:&oerr];
            if (!obj)
                {
                fprintf(stderr, "xcc-ln-x86_64: %s\n", oerr.localizedDescription.UTF8String);
                return 1;
                }
            if (![obj writeToFile:@(argv[3]) atomically:YES])
                {
                fprintf(stderr, "xcc-ln-x86_64: cannot write '%s'\n", argv[3]);
                return 1;
                }
            return 0;
            }

        NSMutableArray<NSString*>* inputs = [NSMutableArray array];
        NSString *output = nil, *entry = @"_start", *soname = nil;
        NSMutableArray<NSString*>* needed = [NSMutableArray array];
        NSMutableArray<NSString*>* rpaths = [NSMutableArray array];
        NSString* ifacePath = nil;
        BOOL dump = NO, shared = NO, pie = NO;
        for (int i = 1; i < argc; i++)
            {
            NSString* a = @(argv[i]);
            if ([a isEqualToString:@"-o"] && i + 1 < argc)
                output = @(argv[++i]);
            else if ([a isEqualToString:@"-e"] && i + 1 < argc)
                entry = @(argv[++i]);
            else if ([a isEqualToString:@"--dump"])
                dump = YES;
            else if ([a isEqualToString:@"-shared"] || [a isEqualToString:@"--shared"])
                shared = YES;
            else if ([a isEqualToString:@"-pie"] || [a isEqualToString:@"--pie"])
                pie = YES;
            else if ([a isEqualToString:@"-soname"] && i + 1 < argc)
                soname = @(argv[++i]);
            else if ([a isEqualToString:@"-rpath"] && i + 1 < argc)
                [rpaths addObject:@(argv[++i])];
            else if ([a isEqualToString:@"-iface"] && i + 1 < argc)
                ifacePath = @(argv[++i]);
            else if ([a isEqualToString:@"-l"] && i + 1 < argc)
                [needed addObject:@(argv[++i])];
            else if ([a hasPrefix:@"-l"])
                [needed addObject:[a substringFromIndex:2]];
            else if ([a hasPrefix:@"-"])
                {
                fprintf(stderr, "xcc-ln-x86_64: unknown option '%s'\n", argv[i]);
                return 2;
                }
            else
                [inputs addObject:a];
            }
        if (!inputs.count || (!output && !dump))
            {
            fprintf(stderr, "usage: xtcln-x86_64 <input.s>... -o <output> [-e entry] [--dump]\n"
                            "       xtcln-x86_64 <input.s>... -shared -o <lib.so> "
                            "[-soname NAME] [-l<needed>]\n"
                            "       xtcln-x86_64 <input.s>... -pie -o <prog> [-l<needed>]  "
                            "(dynamically linked)\n");
            return 2;
            }
        if (shared && !soname)
            soname = output.lastPathComponent;

        // Concatenate the inputs, renaming each file's local labels so they cannot
        // collide. clang restarts its numbering per translation unit, so two
        // separately compiled runtime files both contain `.LBB0_1` — concatenated
        // verbatim, every branch in the first lands in the second. Local labels are
        // file-scoped by definition, so a per-file tag is always safe.
        NSError* err = nil;
        NSMutableString* src = [NSMutableString string];
        NSRegularExpression* localLbl =
            [NSRegularExpression regularExpressionWithPattern:@"\\.L([A-Za-z0-9_$.]*)"
                                                      options:0
                                                        error:NULL];
        // `.o` inputs are merged AFTER the assembled text (below); everything else
        // is source and is concatenated here. Stage 2 of separate-compilation.
        NSMutableArray<NSString*>* objInputs = [NSMutableArray array];
        NSMutableArray<NSString*>* archives = [NSMutableArray array];
        NSMutableArray<NSString*>* sharedDeps = [NSMutableArray array];
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
            if ([inputs[i].pathExtension isEqualToString:@"so"])
                {
                [sharedDeps addObject:inputs[i]];
                continue;
                }
            NSString* one = [NSString stringWithContentsOfFile:inputs[i]
                                                      encoding:NSUTF8StringEncoding
                                                         error:&err];
            if (!one)
                {
                fprintf(stderr, "xcc-ln-x86_64: cannot read '%s': %s\n", inputs[i].UTF8String,
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
            fprintf(stderr, "xcc-ln-x86_64: %s\n", err.localizedDescription.UTF8String);
            return 1;
            }
        // The main unit's own COMMON (`.comm`) tentative globals get real storage
        // here — an executable has no separate link stage to allocate them. `.o`
        // inputs merged below keep theirs as commons (the merge resolves them).
        [as demoteCommonsToLocalData];

        // ── merge the `.o` inputs ─────────────────────────────────────────────
        // The assembled text goes first, so its symbol offsets stay valid and only
        // the objects need rebasing. A LOCAL symbol is tagged per object: two
        // objects may each define a same-named static, and registering both under
        // the bare name would silently bind every reference to whichever came last.
        NSMutableData* mtext = [text mutableCopy];
        NSMutableData* mdata = [as.data mutableCopy] ?: [NSMutableData data];
        NSMutableDictionary<NSString*, NSNumber*>* msyms = [as.symbols mutableCopy];
        NSMutableSet<NSString*>* mweak = [NSMutableSet set];
        NSMutableSet<NSString*>* mweakdef = [NSMutableSet set];
        NSMutableSet<NSString*>* mabs = [NSMutableSet set];
        NSMutableData* mtls = [NSMutableData data];
        NSMutableDictionary<NSString*, NSNumber*>* mtlsSyms = [NSMutableDictionary dictionary];
        NSMutableArray<NSDictionary*>* mtlsAbs = [NSMutableArray array];
        NSMutableSet<NSString*>* mdataSyms = [as.dataSymbols mutableCopy] ?: [NSMutableSet set];
        NSMutableSet<NSString*>* mglobals = [as.globalSymbols mutableCopy] ?: [NSMutableSet set];
        NSMutableArray<XAX86_64Fixup*>* mfix = [as.fixups mutableCopy] ?: [NSMutableArray array];
        NSMutableData* mbss = [NSMutableData data]; // COMMON (NOBITS) pool
        NSMutableArray<NSString*>* mbssSyms = [NSMutableArray array];
        uint64_t mbssAlign = 1;
        // Dead code/data elimination (bug 196): the assembled seed is kept whole;
        // what the objects and archives bring is GC'd after the merge.
        XTElfGC* gc = [XTElfGC new];
        uint64_t seedTextEnd = mtext.length, seedDataEnd = mdata.length;
        for (NSUInteger oi = 0; oi < objInputs.count; oi++)
            {
            NSDictionary* obj = [XTElfWriter objectAtPath:objInputs[oi]];
            if (!obj)
                {
                fprintf(stderr, "xcc-ln-x86_64: error: '%s' is not a readable x86-64 object\n",
                        objInputs[oi].UTF8String);
                return 1;
                }
            if (!mergeElfObject(obj, objInputs[oi], oi, mtext, mdata, msyms,
                                mdataSyms, mglobals, mfix, mweak, mweakdef,
                                mtls, mtlsSyms, mtlsAbs, mbss, mbssSyms, &mbssAlign, gc))
                return 1;
            }
        // ── shared-object dependencies: satisfy + export what they import ──────
        // A `.so` we link against (e.g. libtls.so) is not merged — it stays a
        // DT_NEEDED. But musl is a STATIC libc: the .so has no libc of its own and
        // there is no libc.so in the process, so its libc/crt imports must be
        // resolved against THIS executable's one crt-initialised musl. So we treat
        // the .so's UND dynsyms as symbols this link must also define (pull them
        // from libc.a below) AND export (added to mglobals after the pull), so the
        // loader binds the .so's imports to the exe. Without this the .so loads a
        // second, uninitialised libc and faults on the first call (__vdsosym).
        NSMutableSet<NSString*>* soNeeds = [NSMutableSet set];
        for (NSString* dep in sharedDeps)
            {
            NSDictionary* info = [XTElfWriter sharedInfoAtPath:dep];
            if (!info)
                {
                fprintf(stderr, "xcc-ln-x86_64: error: '%s' is not a readable x86-64 shared object\n",
                        dep.UTF8String);
                return 1;
                }
            NSString* sn = info[@"soname"];
            if (sn.length && ![needed containsObject:sn])
                [needed addObject:sn];
            for (NSString* u in info[@"undefined"])
                [soNeeds addObject:u];
            }
        // ── pull from static archives, on demand ──────────────────────────────
        // A `.a` is not linked; it is a POOL. A member joins the image only if it
        // defines something still undefined, and pulling one can make new names
        // undefined in turn — so this iterates to a fixpoint rather than making one
        // pass. That is the whole difference between an archive and a list of
        // objects, and getting it wrong shows up as a link that succeeds while
        // leaving half of libc out.
        if (archives.count)
            {
            NSMutableArray<NSDictionary*>* pool = [NSMutableArray array];
            NSMutableArray<NSString*>* poolFrom = [NSMutableArray array];
            for (NSString* a in archives)
                {
                NSArray<NSDictionary*>* ms = [XTElfWriter objectsInArchive:a];
                if (!ms)
                    {
                    fprintf(stderr, "xcc-ln-x86_64: error: '%s' is not a static archive\n",
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
                // What is still missing? A fixup whose symbol nothing defines.
                NSMutableSet<NSString*>* needed = [NSMutableSet set];
                for (XAX86_64Fixup* f in mfix)
                    if (f.symbol.length && !msyms[f.symbol])
                        [needed addObject:f.symbol];
                // The shared deps' imports must also be satisfied from libc.a, even
                // when nothing in THIS image references them — they are pulled to be
                // exported for the .so, not for our own code.
                for (NSString* u in soNeeds)
                    if (!msyms[u])
                        [needed addObject:u];
                if (!needed.count)
                    break;
                for (NSUInteger mi = 0; mi < pool.count; mi++)
                    {
                    if ([taken containsObject:@(mi)])
                        continue;
                    NSDictionary* obj = pool[mi];
                    // A WEAK definition attracts a member exactly as a strong one
                    // does — GNU ld behaviour, and musl requires it: `malloc` has
                    // NO strong definition anywhere in libc.a (lite_malloc.lo's
                    // weak alias is the only one), so a strong-only rule leaves it
                    // undefined. Correctness comes from resolution, not
                    // extraction: when mallocng's malloc.lo arrives (pulled via
                    // free.lo's internals) its STRONG __libc_malloc_impl replaces
                    // lite_malloc's weak one in the merge, whatever the order.
                    BOOL defines = NO;
                    for (NSString* n in [obj[@"symbols"] allKeys])
                        if ([needed containsObject:n])
                            {
                            defines = YES;
                            break;
                            }
                    if (!defines)
                        for (NSString* n in [obj[@"datasyms"] allKeys])
                            if ([needed containsObject:n])
                                {
                                defines = YES;
                                break;
                                }
                    if (!defines)
                        continue;
                    [taken addObject:@(mi)];
                    progress = YES;
                    if (!mergeElfObject(obj, [NSString stringWithFormat:@"%@(%@)", poolFrom[mi].lastPathComponent, obj[@"member"]],
                                        1000 + mi, mtext, mdata, msyms, mdataSyms,
                                        mglobals, mfix, mweak, mweakdef,
                                        mtls, mtlsSyms, mtlsAbs, mbss, mbssSyms, &mbssAlign, gc))
                        return 1;
                    }
                }
            }
        if (objInputs.count || archives.count)
            {
            // A fixup naming a symbol this image now defines is resolved by the
            // writer; one that names nothing is a link error there, which is where
            // an undefined symbol belongs in a static link.
            text = mtext;
            // Linker-synthesised array bounds. An ld script provides these on the
            // GNU path; here they exist so that musl's start/exit code — which
            // walks [start, end) unconditionally — sees EMPTY arrays. No object in
            // any archive we link carries .init_array/.fini_array sections (the
            // reader would have to collect them before non-equal bounds could be
            // honest), so start == end is the truthful answer, not a stub.
            // libpq's exit path is what first asked (via musl __libc_exit_fini).
            NSArray<NSString*>* bounds = @[
                @"__preinit_array_start", @"__preinit_array_end",
                @"__init_array_start", @"__init_array_end",
                @"__fini_array_start", @"__fini_array_end"
            ];
            BOOL wanted = NO;
            for (XAX86_64Fixup* f in mfix)
                if (!msyms[f.symbol] && [bounds containsObject:f.symbol])
                    {
                    wanted = YES;
                    break;
                    }
            if (wanted)
                for (NSString* b in bounds)
                    if (!msyms[b])
                        msyms[b] = @(0); // text offset 0: all equal
            // Weak-undefined leftovers: everything the fixpoint could define is
            // defined, so a weak name still missing resolves to ABSOLUTE zero —
            // the answer `if (&_DYNAMIC)`-style probes are written against.
            for (XAX86_64Fixup* f in mfix)
                if (f.symbol.length && !msyms[f.symbol] && [mweak containsObject:f.symbol])
                    {
                    msyms[f.symbol] = @(0);
                    [mabs addObject:f.symbol];
                    }
            // ── static local-exec TLS ──
            // The per-thread block sits at [%fs - R, %fs): variant II, R = the
            // image size rounded to 16. The image itself is stored in the crt's
            // __xt_tls_hdr data area ([0]=R, [8..8+R) = bytes) — the startup and
            // _xt_tcb_alloc copy it below every tcb, whose 248 reserved bytes cap
            // R at 240 (a hard error here, not a silent overrun). Each TPOFF32
            // becomes the CONSTANT tlsOff - R, carried in the fixup's addend; the
            // writer stores it with no symbol lookup.
            if (mtls.length)
                {
                uint64_t R = (mtls.length + 15) & ~15ULL;
                if (R > 240)
                    {
                    fprintf(stderr, "xcc-ln-x86_64: error: static TLS needs %llu bytes; "
                                    "the runtime reserves 240 below each thread block\n",
                            (unsigned long long)R);
                    return 1;
                    }
                NSNumber* hdr = msyms[@"__xt_tls_hdr"];
                if (!hdr || ![mdataSyms containsObject:@"__xt_tls_hdr"])
                    {
                    fprintf(stderr, "xcc-ln-x86_64: error: TLS inputs need the crt's "
                                    "__xt_tls_hdr (is the runtime missing?)\n");
                    return 1;
                    }
                uint64_t ho = hdr.unsignedLongLongValue;
                uint8_t* dp = mdata.mutableBytes;
                if (ho + 8 + 240 > mdata.length)
                    {
                    fprintf(stderr, "xcc-ln-x86_64: error: __xt_tls_hdr area truncated\n");
                    return 1;
                    }
                for (int i = 0; i < 8; i++)
                    dp[ho + i] = (uint8_t)(R >> (8 * i));
                memcpy(dp + ho + 8, mtls.bytes, mtls.length);
                for (XAX86_64Fixup* f in mfix)
                    {
                    if (f.kind != XAX86FixupTpoff32)
                        continue;
                    NSNumber* lo = mtlsSyms[f.symbol];
                    if (!lo)
                        {
                        fprintf(stderr, "xcc-ln-x86_64: error: undefined TLS symbol "
                                        "'%s'\n",
                                f.symbol.UTF8String);
                        return 1;
                        }
                    f.addend = (int64_t)lo.unsignedLongLongValue - (int64_t)R + f.addend;
                    f.symbol = @"";
                    }
                // Initialisers inside the image (mimalloc's `&_mi_heap_empty`)
                // become ordinary data Abs64 fixups at the image's home.
                for (NSDictionary* r in mtlsAbs)
                    {
                    XAX86_64Fixup* f = [XAX86_64Fixup new];
                    f.kind = XAX86FixupAbs64;
                    f.offset = ho + 8 + [r[@"off"] unsignedLongLongValue];
                    f.symbol = r[@"sym"];
                    f.addend = [r[@"addend"] longLongValue];
                    [mfix addObject:f];
                    }
                }
            else
                {
                for (XAX86_64Fixup* f in mfix)
                    if (f.kind == XAX86FixupTpoff32)
                        {
                        fprintf(stderr, "xcc-ln-x86_64: error: TPOFF32 for '%s' with no "
                                        "TLS sections in the link\n",
                                f.symbol.UTF8String);
                        return 1;
                        }
                }
            }
        if ((objInputs.count || archives.count) && !shared && !pie)
            {
            [gc runWithText:mtext
                       data:mdata
                    symbols:msyms
                dataSymbols:mdataSyms
                 bssSymbols:mbssSyms
                     fixups:mfix
                seedTextEnd:seedTextEnd
                seedDataEnd:seedDataEnd
                      entry:entry];
            text = mtext;
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
            NSArray* keys = [as.symbols.allKeys sortedArrayUsingComparator:^(NSString* x, NSString* y) {
              return (NSComparisonResult)strcmp(x.UTF8String, y.UTF8String) < 0 ? NSOrderedAscending
                                                                                : (strcmp(x.UTF8String, y.UTF8String) > 0 ? NSOrderedDescending : NSOrderedSame);
            }];
            [o appendFormat:@"symbols %lu\n", (unsigned long)keys.count];
            for (NSString* k in keys)
                [o appendFormat:@"  %@ %llu %@%@\n", k,
                                (unsigned long long)as.symbols[k].unsignedLongLongValue,
                                [as.dataSymbols containsObject:k] ? @"data" : @"text",
                                [as.globalSymbols containsObject:k] ? @" globl" : @""];
            [o appendFormat:@"fixups %lu\n", (unsigned long)as.fixups.count];
            for (XAX86_64Fixup* f in as.fixups)
                [o appendFormat:@"  %llu %d %@ %lld\n",
                                (unsigned long long)f.offset, (int)f.kind, f.symbol, (long long)f.addend];
            fputs(o.UTF8String, stdout);
            if (!output)
                return 0;
            }

        // Export every shared-dep import this image defines, so the loader binds the
        // .so's libc/crt references back to this executable's one initialised musl.
        // (A symbol the .so needs that we could NOT define is left undefined — it
        // becomes this image's own import, which is the honest outcome.)
        for (NSString* u in soNeeds)
            if (msyms[u])
                [mglobals addObject:u];

        // -pie: the dynamically-linked executable form. Same ET_DYN machinery as a
        // library, plus an entry point and a PT_INTERP — that is what lets a
        // self-hosted program link against a self-hosted .so.
        NSData* elf = (shared || pie)
                          ? [XTElfWriter sharedObjectFromText:text
                                                         data:mdata
                                                      symbols:msyms
                                                  dataSymbols:mdataSyms
                                                globalSymbols:mglobals
                                                       fixups:mfix
                                                       soname:soname ?: output.lastPathComponent
                                                       needed:needed
                                                  entrySymbol:(pie ? entry : nil)
                                                  runpath:(rpaths.count ? [rpaths componentsJoinedByString:@":"] : nil)
                                                  iface:(ifacePath && ![ifacePath isEqualToString:@"-"]
                                                             ? [NSData dataWithContentsOfFile:ifacePath]
                                                             : nil)
                                                          bss:mbss
                                                   bssSymbols:mbssSyms
                                                     bssAlign:mbssAlign
                                                        error:&err]
                          : [XTElfWriter staticExecutableFromText:text
                                                             data:mdata
                                                          symbols:msyms
                                                      dataSymbols:mdataSyms
                                                       absSymbols:mabs
                                                           fixups:mfix
                                                      entrySymbol:entry
                                                              bss:mbss
                                                       bssSymbols:mbssSyms
                                                         bssAlign:mbssAlign
                                                            error:&err];
        if (!elf)
            {
            fprintf(stderr, "xcc-ln-x86_64: %s\n", err.localizedDescription.UTF8String);
            return 1;
            }
        if (![elf writeToFile:output atomically:YES])
            {
            fprintf(stderr, "xcc-ln-x86_64: cannot write '%s'\n", output.UTF8String);
            return 1;
            }
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0755}
                                         ofItemAtPath:output
                                                error:NULL];
        return 0;
        }
    }
