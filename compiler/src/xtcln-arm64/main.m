/****************************************************************************\
|* xtcln-arm64 — the self-hosted arm64/macOS linker.
|*
|* The last stage of the `--self-host` pipeline (private:docs/Design/native-toolchain.md):
|* assembles an arm64 `.s`, lays it out into a signed Mach-O MH_EXECUTE, and
|* writes it — with NO external toolchain (no clang, no system as, no codesign).
|* The `xtc` dispatcher spawns this in place of clang, exactly as it spawns `xta`
|* for the 6502 target.
|*
|* Usage:  xtcln-arm64 <input.s> <output>
|*
|* The input `.s` already has the hand-written runtime (crt-macos.s) prepended by
|* the driver, so its entry symbol is `_xtc_start` (falling back to `_main`).
\****************************************************************************/

#import <Foundation/Foundation.h>
#import "XAArm64Assembler.h"
#import "XTMachOWriter.h"
#import "XTElfArm64Writer.h"

// A symbol reference in a pulled object resolves to: its real name if external or
// undefined (cross-object / import), or a per-object-unique name if it's a LOCAL
// definition (e.g. `l_.str` — Mach-O emits its relocs as r_extern with a symtab
// index, but the symbol itself is non-external and would clash across members).
static NSString *taggedSym(NSDictionary *symdef, NSString *realName, NSUInteger oi) {
    BOOL localDef = ![symdef[@"ext"] boolValue] && [symdef[@"where"] intValue] != 0;
    return localDef ? [NSString stringWithFormat:@"__L%lu$%@", (unsigned long)oi, realName] : realName;
}

// Translate one __text relocation of a pulled static-archive object (index `oi`)
// into an XAArm64Fixup against the merged image. `base` is where the object's
// __text was appended. Returns nil for a reloc kind we don't handle yet (→ the
// caller fails the link so the driver retries with clang).
static XAArm64Fixup *objectRelocFixup(NSDictionary *r, uint64_t base, NSDictionary *obj, NSUInteger oi) {
    int type = [r[@"type"] intValue], ext = [r[@"extern"] intValue];
    NSArray<NSString *> *names = obj[@"symnames"];
    NSArray<NSDictionary *> *defs = obj[@"symdefs"];
    uint32_t symnum = (uint32_t)[r[@"symnum"] unsignedIntValue];
    // Only symbol-indexed (r_extern) BRANCH26/PAGE21/PAGEOFF12 are handled — they
    // map straight onto the assembler's own fixup kinds. Section-relative relocs
    // (r_extern=0) and GOT/UNSIGNED are not, and force the clang fallback.
    if (!ext || symnum >= names.count) return nil;
    XAArm64FixupKind kind;
    switch (type) {
        case 2: kind = XAArm64FixupBranch26;   break;   // ARM64_RELOC_BRANCH26
        case 3: kind = XAArm64FixupPage21;     break;   // ARM64_RELOC_PAGE21
        case 4: kind = XAArm64FixupPageOff12;  break;   // ARM64_RELOC_PAGEOFF12
        default: return nil;                            // GOT/UNSIGNED/ADDEND/… → later
    }
    XAArm64Fixup *f = [XAArm64Fixup new];
    f.offset = base + (uint64_t)[r[@"off"] longLongValue];
    f.kind = kind; f.symbol = taggedSym(defs[symnum], names[symnum], oi); f.scale = 0;
    // PAGEOFF12 patches an instruction's imm12: an unsigned-offset load/store
    // scales it by the access size (so `ldr x,[b,#off]` needs off>>3), while an
    // `add` is unscaled. Read the target instruction to pick the scale.
    if (kind == XAArm64FixupPageOff12) {
        NSData *t = obj[@"text"]; uint64_t off = (uint64_t)[r[@"off"] longLongValue];
        if (off + 4 <= t.length) {
            const uint8_t *p = (const uint8_t *)t.bytes + off;
            uint32_t insn = p[0]|(p[1]<<8)|(p[2]<<16)|((uint32_t)p[3]<<24);
            if ((insn & 0x3B000000u) == 0x39000000u) {          // LDR/STR unsigned offset
                f.scale = insn >> 30;                           // size field (0..3)
                if (f.scale==0 && ((insn>>26)&1) && ((insn>>23)&1)) f.scale = 4;  // 128-bit SIMD
            }
        }
    }
    return f;
}

// Merge explicit objects and pull archive members, into the assembler's own
// model. Shared by the EXECUTABLE and the DYLIB paths — a second copy of
// relocation merging is the kind that drifts, and the dylib path having no
// copy at all is what made `--emit-lib` silently ignore -Wl objects.
//   0 = merged, 1 = error already reported, 2 = something the in-house link
//   cannot express (the driver falls back to clang).

// Bug 066: place the assembler's __mod_init_func pointer array at the END of
// the merged __data and shift its fixups to match. It goes last because every
// object and archive appends its own data during the merge — a range recorded
// at assembly time would stop being the tail as soon as anything else
// contributed. Returns its byte length, which the writer needs to know how much
// of the tail gets the S_MOD_INIT_FUNC_POINTERS section.

// Bug 069: give the ObjC metadata its section identity back.
//
// The object reader concatenates every __DATA/__TEXT-literal section of an
// input object into one anonymous blob — which is why the runtime never uniqued
// a selector: it locates __objc_selrefs BY SECTION, and a selref arriving as
// plain __data keeps its build-time pointer, so every message send misses.
//
// A Mach-O section is a contiguous range, and the blob interleaves ObjC runs
// with ordinary data, so identity cannot simply be asserted over the existing
// layout: the bytes have to be REGROUPED — all ordinary data first, then each
// __objc_* section gathered from every object it came from. Everything that
// names a byte position then has to move with it, which is every data symbol
// and every Pointer64 fixup (the only kind that addresses data; the rest patch
// instructions in __text).
//
// Returns the section table for the writer: name → {seg, flags, off, size} in
// FINAL blob coordinates. Empty when the link has no ObjC content, in which
// case nothing moves and the image is byte-identical to before.
static NSArray<NSDictionary *> *repartitionObjcSections(
        NSMutableData *mdata, NSArray<NSDictionary *> *ranges,
        NSMutableDictionary<NSString *, NSNumber *> *msyms,
        NSSet<NSString *> *mdataSyms,
        NSMutableArray<XAArm64Fixup *> *mfix) {
    if (ranges.count == 0) return @[];

    // 1. Sort the ObjC runs by position and mark the bytes they own.
    NSArray<NSDictionary *> *sorted = [ranges sortedArrayUsingComparator:
        ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"off"] compare:b[@"off"]];
        }];
    NSUInteger total = mdata.length;
    NSMutableIndexSet *owned = [NSMutableIndexSet indexSet];
    for (NSDictionary *r in sorted) {
        NSUInteger off = [r[@"off"] unsignedIntegerValue], sz = [r[@"size"] unsignedIntegerValue];
        if (off + sz > total) return @[];                 // malformed; leave it alone
        if (sz) [owned addIndexesInRange:NSMakeRange(off, sz)];
    }

    // 2. Lay the new blob out: ordinary data in its original order, then each
    //    named section with all of its runs adjacent.
    const uint8_t *src = mdata.bytes;
    NSMutableData *out = [NSMutableData data];
    // old offset -> new offset, as (oldStart, len, newStart) moves.
    NSMutableArray<NSArray<NSNumber *> *> *moves = [NSMutableArray array];
    NSUInteger i = 0;
    while (i < total) {
        if ([owned containsIndex:i]) { i++; continue; }
        NSUInteger run = i;
        while (i < total && ![owned containsIndex:i]) i++;
        // Bug 140: keep every byte's alignment class. Pulling an odd-sized
        // ObjC run (__objc_methname is a string pool) out from between two
        // ordinary runs slid everything after it by that odd amount, so a
        // __cfstring constant landed on an odd address and UIApplicationMain
        // died in CFStringGetLength2 with EXC_ARM_DA_ALIGN — in BOTH linkers,
        // identically. A run is re-laid at the same offset modulo 16 it had.
        while ((out.length & 15) != (run & 15)) { uint8_t z = 0; [out appendBytes:&z length:1]; }
        [moves addObject:@[@(run), @(i - run), @(out.length)]];
        [out appendBytes:src + run length:i - run];
    }

    NSMutableArray<NSString *> *order = [NSMutableArray array];   // first-seen order
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *byName =
        [NSMutableDictionary dictionary];
    for (NSDictionary *r in sorted) {
        NSString *nm = r[@"name"];
        if (!byName[nm]) { byName[nm] = [NSMutableArray array]; [order addObject:nm]; }
        [byName[nm] addObject:r];
    }

    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
    for (NSString *nm in order) {
        while (out.length & 7) { uint8_t z = 0; [out appendBytes:&z length:1]; }
        NSUInteger start = out.length;
        NSDictionary *first = byName[nm].firstObject;
        for (NSDictionary *r in byName[nm]) {
            NSUInteger off = [r[@"off"] unsignedIntegerValue], sz = [r[@"size"] unsignedIntegerValue];
            if (!sz) continue;
            [moves addObject:@[@(off), @(sz), @(out.length)]];
            [out appendBytes:src + off length:sz];
        }
        [sections addObject:@{@"name":nm, @"seg":first[@"seg"], @"flags":first[@"flags"],
                              @"off":@(start), @"size":@(out.length - start)}];
    }

    // 3. Move everything that names a byte position.
    NSNumber *(^remap)(NSUInteger) = ^NSNumber *(NSUInteger old) {
        for (NSArray<NSNumber *> *m in moves) {
            NSUInteger st = m[0].unsignedIntegerValue, len = m[1].unsignedIntegerValue;
            if (old >= st && old < st + len)
                return @(m[2].unsignedIntegerValue + (old - st));
        }
        return nil;                                       // not in the blob
    };
    for (NSString *nm in msyms.allKeys) {
        if (![mdataSyms containsObject:nm]) continue;
        NSNumber *n = remap(msyms[nm].unsignedIntegerValue);
        if (n) msyms[nm] = n;
    }
    for (XAArm64Fixup *f in mfix) {
        if (f.kind != XAArm64FixupPointer64) continue;    // the only data-addressing kind
        NSNumber *n = remap((NSUInteger)f.offset);
        if (n) f.offset = n.unsignedLongLongValue;
    }

    [mdata setData:out];
    return sections;
}

static NSUInteger appendModInit(XAArm64Assembler *as, NSMutableData *mdata,
                                NSMutableArray<XAArm64Fixup *> *mfix) {
    NSData *mi = as.modInitData;
    if (mi.length == 0) return 0;
    while (mdata.length & 7) { uint8_t z = 0; [mdata appendBytes:&z length:1]; }
    uint64_t base = mdata.length;
    [mdata appendData:mi];
    for (XAArm64Fixup *f in as.modInitFixups) {
        XAArm64Fixup *g = [XAArm64Fixup new];
        g.offset = base + f.offset; g.symbol = f.symbol;
        g.kind = f.kind; g.scale = f.scale; g.addend = f.addend;
        [mfix addObject:g];
    }
    return mi.length;
}

static int mergeMachOInputs(NSArray<NSString *> *objectFiles,
                            NSArray<NSString *> *archives,
                            NSMutableData *mtext, NSMutableData *mdata,
                            NSMutableDictionary<NSString *, NSNumber *> *msyms,
                            NSMutableSet<NSString *> *mdataSyms,
                            NSMutableArray<XAArm64Fixup *> *mfix,
                            NSMutableArray<NSDictionary *> *mObjc,
                            NSMutableArray<XAArm64Fixup *> *gotFixups) {
    if (!archives.count && !objectFiles.count) return 0;
        NSMutableArray<NSDictionary *> *allObjs = [NSMutableArray array];
        // Explicit objects go in FIRST and are marked forced, so they merge
        // whether or not anything references them: a .o on the command line
        // is a statement that it belongs in the image.
        NSMutableSet<NSNumber *> *forced = [NSMutableSet set];
        for (NSString *op in objectFiles) {
            NSDictionary *o = [XTMachOWriter objectAtPath:op];
            if (!o) {
                fprintf(stderr, "xcc-ln-arm64: error: '%s' is not a readable arm64 object\n",
                        op.UTF8String);
                return 1;
            }
            [forced addObject:@(allObjs.count)];
            [allObjs addObject:o];
        }
        for (NSString *ap in archives) {
            NSArray<NSDictionary *> *o = [XTMachOWriter objectsInArchive:ap];
            if (o) [allObjs addObjectsFromArray:o];
            else fprintf(stderr, "xcc-ln-arm64: note: '%s' is not a parseable archive\n", ap.UTF8String);
        }
        NSMutableSet<NSString *> *needed = [NSMutableSet set];
        void (^refresh)(void) = ^{
            [needed removeAllObjects];
            for (XAArm64Fixup *f in mfix) if (f.symbol && !msyms[f.symbol]) [needed addObject:f.symbol];
        };
        refresh();
        NSMutableSet<NSNumber *> *pulled = [NSMutableSet set];
        // Common-symbol resolution across objects (bug 177): the size of the
        // common currently registered for a name, and the names a STRONG data
        // def has claimed (a strong def wins over any common).
        NSMutableDictionary<NSString *, NSNumber *> *commonSizes = [NSMutableDictionary dictionary];
        NSMutableSet<NSString *> *strongDataDefs = [NSMutableSet set];
        BOOL progress = YES;
        // `forced.count` keeps the loop entered even when nothing is undefined
        // yet — an explicit object still has to be merged.
        while (progress && (needed.count || forced.count)) {
            progress = NO;
            for (NSUInteger oi = 0; oi < allObjs.count; oi++) {
                if ([pulled containsObject:@(oi)]) continue;
                NSDictionary *obj = allObjs[oi];
                NSDictionary<NSString *, NSNumber *> *osyms = obj[@"symbols"];
                NSDictionary<NSString *, NSNumber *> *odsyms = obj[@"datasyms"];
                BOOL defines = [forced containsObject:@(oi)];
                if (!defines) for (NSString *s in osyms)  if ([needed containsObject:s]) { defines = YES; break; }
                if (!defines) for (NSString *s in odsyms) if ([needed containsObject:s]) { defines = YES; break; }
                if (!defines) continue;
                [forced removeObject:@(oi)];
                [pulled addObject:@(oi)];
                (void)osyms; (void)odsyms;
                // Append __text (4-aligned) and the __data blob (16-aligned).
                // 16, not 8: the blob concatenates each section at its own
                // alignment RELATIVE to the blob start, and a 16-byte literal
                // (S_16BYTE_LITERALS — clang parks SIMD constant vectors there,
                // e.g. mbedtls's constant-time base64 range bounds) is only
                // truly 16-aligned if the blob itself starts 16-aligned. An
                // `ldr q,[x,#off]` encodes off>>4, so a blob landing 8-but-not-
                // 16-aligned makes the vector load read 16 bytes off — garbage
                // constants, and layout-dependent (it aligned by luck before).
                while (mtext.length & 3) { uint8_t z=0; [mtext appendBytes:&z length:1]; }
                uint64_t base = mtext.length;
                [mtext appendData:obj[@"text"]];
                NSData *odata = obj[@"data"]; uint64_t dbase = mdata.length;
                if (odata.length) {
                    while (mdata.length & 15) { uint8_t z=0; [mdata appendBytes:&z length:1]; }
                    dbase = mdata.length; [mdata appendData:odata];
                }
                // Bug 069: remember where this object's __objc_* sections landed,
                // in MERGED coordinates — recorded after the append, so `dbase`
                // is the padded base actually used. The repartition below puts
                // their section identity back; the runtime finds its metadata by
                // that identity and does nothing without it.
                for (NSDictionary *r in obj[@"objcranges"])
                    [mObjc addObject:@{@"name":r[@"name"], @"seg":r[@"seg"], @"flags":r[@"flags"],
                                       @"off":@(dbase + [r[@"off"] unsignedLongLongValue]),
                                       @"size":r[@"size"]}];
                // Register EVERY defined symbol at its merged address: external
                // names as-is (cross-object / for the program), local names under
                // a per-object tag (unique). Data symbols also join mdataSyms so
                // symAddr uses the __DATA base.
                NSArray<NSString *> *snames = obj[@"symnames"];
                NSArray<NSDictionary *> *sdefs = obj[@"symdefs"];
                for (NSUInteger si=0; si<snames.count; si++) {
                    NSDictionary *sd = sdefs[si]; int where=[sd[@"where"] intValue];
                    NSString *rn = snames[si];
                    if (where==0 || !rn.length) continue;      // undef
                    NSString *nm = taggedSym(sd, rn, oi);
                    // Category-chain tables (§4.3b). Two shapes, two errors:
                    // `C$cat$Names` is an OWNER ANCHOR — a duplicate means two
                    // modules defined the same-NAMED category on one class
                    // (the name is the extender's identity; independent
                    // extenders with different names no longer collide).
                    // Bare `X$cat` is a family table — a duplicate means the
                    // CLASS itself is compiled into two modules. Either way a
                    // silent first-wins is a wrong CALL, not a missing symbol.
                    NSRange catr = [nm rangeOfString:@"$cat$"];
                    if (catr.location != NSNotFound && msyms[nm] != nil) {
                        NSString *cn = [nm substringToIndex:catr.location];
                        if ([cn hasPrefix:@"_"]) cn = [cn substringFromIndex:1];
                        fprintf(stderr, "xcc-ln-arm64: error: two modules define "
                                "category '%s' on class '%s' ('%s' defined twice). "
                                "The category name is the extender's identity "
                                "(separate-compilation §4.3b) — rename one, or "
                                "compile both from one module\n",
                                [nm substringFromIndex:catr.location + 5].UTF8String,
                                cn.UTF8String, nm.UTF8String);
                        return 1;
                    }
                    if ([nm hasSuffix:@"$cat"] && msyms[nm] != nil) {
                        // Report the SOURCE name: these are Mach-O symbols, so
                        // `_B$cat` is class B, and naming it `_B` sends the
                        // reader looking for a class that does not exist.
                        NSString *cn = [nm substringToIndex:nm.length - 4];
                        if ([cn hasPrefix:@"_"]) cn = [cn substringFromIndex:1];
                        fprintf(stderr, "xcc-ln-arm64: error: class '%s' is "
                                "compiled into two modules ('%s', its "
                                "category-chain table, defined twice)\n",
                                cn.UTF8String, nm.UTF8String);
                        return 1;
                    }
                    uint64_t off = [sd[@"off"] unsignedLongLongValue];
                    if (where==1) msyms[nm] = @(base + off);
                    else {
                        // Common (tentative) vs strong resolution (bug 177). A
                        // STRONG data def beats any common; among commons the
                        // LARGEST size wins whatever the link ORDER (a C linker
                        // merges commons that way — def.o then use.o must not
                        // shrink a table to the smaller common). obj[commons][rn]
                        // gives this def's size when it is itself a common.
                        NSNumber *csz = ((NSDictionary *)obj[@"commons"])[rn];
                        if (csz) {
                            if ([strongDataDefs containsObject:nm]) {
                                // a strong def already claimed it — commons yield
                            } else if (commonSizes[nm] &&
                                       [commonSizes[nm] unsignedLongLongValue]
                                           >= csz.unsignedLongLongValue) {
                                // a same-or-larger common already registered
                            } else {
                                msyms[nm] = @(dbase + off); [mdataSyms addObject:nm];
                                commonSizes[nm] = csz;
                            }
                        } else {
                            msyms[nm] = @(dbase + off); [mdataSyms addObject:nm];
                            [strongDataDefs addObject:nm];
                            [commonSizes removeObjectForKey:nm];
                        }
                    }
                }
                // __text relocations → fixups against the merged image. An
                // unhandled reloc kind (section-relative / UNSIGNED / GOT) must
                // FAIL the in-house link — not silently leave the instruction at
                // its placeholder — so the driver cleanly retries with clang.
                int64_t pendAddend = 0;      // ARM64_RELOC_ADDEND applies to the NEXT reloc
                for (NSDictionary *r in obj[@"relocs"]) {
                    int rt = [r[@"type"] intValue];
                    if (rt == 10) {          // ARM64_RELOC_ADDEND — `sym + N` for the next one
                        pendAddend = (int64_t)[r[@"symnum"] unsignedIntValue];
                        continue;
                    }
                    // GOT_LOAD_PAGE21/PAGEOFF12: `adrp x,sym@GOTPAGE; ldr x,[x,
                    // sym@GOTPAGEOFF]` loads sym's ADDRESS out of a GOT slot. When
                    // sym ends up defined in our image we can RELAX that to
                    // `adrp x,sym@PAGE; add x,x,sym@PAGEOFF` — same result, no GOT
                    // entry. (Verified after the merge: a still-undefined target
                    // would need a real data GOT entry, so we defer to clang.)
                    if ((rt==5 || rt==6) && [r[@"extern"] intValue]) {
                        uint32_t sn=(uint32_t)[r[@"symnum"] unsignedIntValue];
                        if (sn >= snames.count) { fprintf(stderr,"xcc-ln-arm64: bad GOT symnum\n"); return 2; }
                        XAArm64Fixup *gf = [XAArm64Fixup new];
                        gf.offset = base + (uint64_t)[r[@"off"] longLongValue];
                        gf.symbol = taggedSym(sdefs[sn], snames[sn], oi); gf.scale = 0;
                        gf.kind = (rt==5) ? XAArm64FixupGotPage21 : XAArm64FixupGotPageOff12;
                        gf.addend = pendAddend; pendAddend = 0;
                        [mfix addObject:gf]; [gotFixups addObject:gf];
                        continue;
                    }
                    XAArm64Fixup *f = objectRelocFixup(r, base, obj, oi);
                    if (f) { f.addend = pendAddend; pendAddend = 0; [mfix addObject:f]; continue; }
                    fprintf(stderr, "xcc-ln-arm64: unhandled static-archive relocation "
                            "(type %ld, extern %ld) — deferring to clang\n",
                            (long)[r[@"type"] integerValue], (long)[r[@"extern"] integerValue]);
                    return 2;   // in-house link can't handle it → driver falls back to clang
                }
                // DATA relocations: an ARM64_RELOC_UNSIGNED slot is a `.quad
                // <symbol>` pointer (a function-pointer table, a static pointer),
                // which is exactly the assembler's Pointer64 fixup — the writer
                // patches the slot and emits a rebase for it.
                for (NSDictionary *r in obj[@"datarelocs"]) {
                    int rt=[r[@"type"] intValue], rext=[r[@"extern"] intValue];
                    uint32_t sn=(uint32_t)[r[@"symnum"] unsignedIntValue];
                    if (rt==0 && rext && sn<snames.count) {         // UNSIGNED → Pointer64
                        XAArm64Fixup *pf = [XAArm64Fixup new];
                        pf.offset = dbase + (uint64_t)[r[@"off"] unsignedLongLongValue];
                        pf.kind = XAArm64FixupPointer64;
                        pf.symbol = taggedSym(sdefs[sn], snames[sn], oi);
                        pf.scale = 0;
                        [mfix addObject:pf];
                        continue;
                    }
                    fprintf(stderr, "xcc-ln-arm64: unhandled static-archive DATA relocation "
                            "(type %d, extern %d) — deferring to clang\n", rt, rext);
                    return 2;
                }
                progress = YES;
            }
            refresh();
        }
        // GOT references: now that the fixpoint has settled we know what ended up
        // in the image. A target DEFINED here needs no GOT indirection — relax
        // `adrp x,s@GOTPAGE; ldr x,[x,s@GOTPAGEOFF]` to `adrp x,s@PAGE;
        // add x,x,s@PAGEOFF` (rewriting the ldr into an add). A target that
        // stayed external keeps its GOT kind, so the writer gives it a real
        // __got slot + bind like any other import.
        for (XAArm64Fixup *gf in gotFixups) {
            if (!msyms[gf.symbol]) continue;                 // stays a data import
            if (gf.kind == XAArm64FixupGotPage21) { gf.kind = XAArm64FixupPage21; continue; }
            gf.kind = XAArm64FixupPageOff12; gf.scale = 0;   // and turn the ldr into an add
            uint8_t *tb = (uint8_t *)mtext.mutableBytes + gf.offset;
            uint32_t insn = tb[0]|(tb[1]<<8)|(tb[2]<<16)|((uint32_t)tb[3]<<24);
            uint32_t add = 0x91000000u | (((insn>>5)&0x1F)<<5) | (insn&0x1F);
            tb[0]=(uint8_t)add; tb[1]=(uint8_t)(add>>8); tb[2]=(uint8_t)(add>>16); tb[3]=(uint8_t)(add>>24);
        }
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // `-platform macos|ios|ios-sim` may appear anywhere on the line and
        // applies to every image this invocation writes (the LC_BUILD_VERSION
        // stamp). Stripped here so the mode parsers below never see it.
        {
            NSMutableArray<NSString *> *kept = [NSMutableArray array];
            for (int i = 0; i < argc; i++) {
                if (strcmp(argv[i], "-platform") == 0 && i + 1 < argc) {
                    [XTMachOWriter setApplePlatform:@(argv[++i])];
                    continue;
                }
                [kept addObject:@(argv[i])];
            }
            if ((int)kept.count != argc) {
                static const char *newArgv[256];
                argc = (int)MIN(kept.count, (NSUInteger)256);
                for (int i = 0; i < argc; i++) newArgv[i] = [kept[i] UTF8String];
                argv = newArgv;
            }
        }
        // Shared-library mode:
        //   xtcln-arm64 --dylib <install-name> <iface|-> <exports|-> <in.s> <out>
        // <exports> is a newline-separated list of the public symbols to export
        // (the library's .globl API, gathered by the driver); <iface> is the
        // module-interface JSON to embed in __XTC,__iface (or - for none).
        // Object mode (`xcc -c`):
        //   xcc-ln-arm64 --object <in.s> <out.o>
        // Assemble and STOP. Nothing is bound: every unresolved fixup becomes a
        // relocation and every symbol it names becomes an undefined entry, which
        // is precisely the difference between an object and an executable.
        // Stage 1 of private:docs/Design/separate-compilation.md.
        if (argc >= 2 && strcmp(argv[1], "--object") == 0) {
            if (argc < 4) {
                fprintf(stderr, "usage: %s --object <in.s> <out.o>\n", argv[0]);
                return 2;
            }
            NSString *inPath = @(argv[2]), *outPath = @(argv[3]);
            NSError *err = nil;
            NSString *src = [NSString stringWithContentsOfFile:inPath
                                                      encoding:NSUTF8StringEncoding error:&err];
            if (!src) {
                fprintf(stderr, "xcc-ln-arm64: cannot read '%s': %s\n",
                        argv[2], err.localizedDescription.UTF8String);
                return 1;
            }
            XAArm64Assembler *as = [[XAArm64Assembler alloc] init];
            NSData *text = [as assemble:src error:&err];
            if (!text) {
                fprintf(stderr, "xcc-ln-arm64: assembly failed: %s\n",
                        err.localizedDescription.UTF8String);
                return 1;
            }
            NSData *obj = [XTMachOWriter objectFromText:text symbols:as.symbols
                                                   data:as.data dataSymbols:as.dataSymbols
                                                 fixups:as.fixups
                                                exports:as.globalSymbols
                                                commons:as.commonSymbols];
            if (![obj writeToFile:outPath atomically:YES]) {
                fprintf(stderr, "xcc-ln-arm64: cannot write '%s'\n", argv[3]);
                return 1;
            }
            return 0;
        }

        // Android mode:
        //   xcc-ln-arm64 --android exe <entry> <exports|-> <needed-csv> <in.s> <out>
        //   xcc-ln-arm64 --android so  <soname> <exports|-> <needed-csv> <in.s> <out>
        // Same assembler, different last stage: XTElfArm64Writer instead of
        // XTMachOWriter. Android runs ET_DYN only — an app is a PIE, a
        // NativeActivity payload is a .so — so both shapes come out of one call,
        // separated by whether an entry symbol was given.
        //
        // The input is normalised from the GNU/ELF dialect first, because the
        // Android runtime is generated by the NDK clang and arrives spelled
        // `:lo12:` rather than `@PAGEOFF`. The pass is idempotent, so the
        // compiler's own Mach-O-flavoured asm in the same file is untouched.
        if (argc >= 2 && strcmp(argv[1], "--android") == 0) {
            if (argc < 8) {
                fprintf(stderr, "usage: %s --android <exe|so> <entry|soname> <exports|-> "
                                "<needed-csv> <in.s> <out>\n", argv[0]);
                return 2;
            }
            BOOL isExe = (strcmp(argv[2], "exe") == 0);
            NSString *entryOrSoname = @(argv[3]);
            NSString *exportsPath = @(argv[4]);
            NSString *neededCsv = @(argv[5]);
            NSString *inPath = @(argv[6]), *outPath = @(argv[7]);
            NSError *err = nil;
            NSString *src = [NSString stringWithContentsOfFile:inPath
                                                      encoding:NSUTF8StringEncoding error:&err];
            if (!src) {
                fprintf(stderr, "xcc-ln-arm64: cannot read '%s': %s\n",
                        argv[6], err.localizedDescription.UTF8String);
                return 1;
            }
            XAArm64Assembler *as = [[XAArm64Assembler alloc] init];
            NSData *text = [as assemble:[XAArm64Assembler machoDialectFromElf:src] error:&err];
            [as demoteCommonsToLocalData];
            if (!text) {
                fprintf(stderr, "xcc-ln-arm64: assembly failed: %s\n",
                        err.localizedDescription.UTF8String);
                return 1;
            }
            NSMutableSet<NSString *> *exports = [NSMutableSet set];
            if (![exportsPath isEqualToString:@"-"]) {
                NSString *e = [NSString stringWithContentsOfFile:exportsPath
                                                        encoding:NSUTF8StringEncoding error:NULL];
                for (NSString *n in [(e ?: @"") componentsSeparatedByString:@"\n"])
                    if (n.length) [exports addObject:n];
            }
            NSMutableArray<NSString *> *needed = [NSMutableArray array];
            for (NSString *n in [neededCsv componentsSeparatedByString:@","])
                if (n.length && ![n isEqualToString:@"-"]) [needed addObject:n];
            if (isExe && !as.symbols[entryOrSoname]) {
                fprintf(stderr, "xcc-ln-arm64: entry symbol '%s' is not defined\n", argv[3]);
                return 1;
            }
            // Bug 124: the constructor pointer array is kept OUT of `_data` by
            // the assembler (bug 066), so a caller that passes `as.data` alone
            // drops it on the floor — which is what this branch did, and why no
            // load-time constructor had ever run on android. Append it and hand
            // the writer its length, exactly as the Mach-O links below do.
            NSMutableData *dataM = [as.data mutableCopy];
            NSMutableArray<XAArm64Fixup *> *fixM = [as.fixups mutableCopy];
            NSUInteger miLen = appendModInit(as, dataM, fixM);
            NSData *img = [XTElfArm64Writer sharedObjectFromText:text
                                                            data:dataM
                                                         symbols:as.symbols
                                                     dataSymbols:as.dataSymbols
                                                   globalSymbols:exports
                                                          fixups:fixM
                                                          soname:isExe ? nil : entryOrSoname
                                                          needed:needed
                                                     entrySymbol:isExe ? entryOrSoname : nil
                                                   modInitLength:miLen
                                                           error:&err];
            if (!img) {
                fprintf(stderr, "xcc-ln-arm64: android link failed: %s\n",
                        err.localizedDescription.UTF8String);
                return 1;
            }
            if (![img writeToFile:outPath atomically:YES]) {
                fprintf(stderr, "xcc-ln-arm64: cannot write '%s'\n", argv[7]);
                return 1;
            }
            // The loader will not map a file it cannot execute, and a .so that
            // ends up non-executable is a confusing "not found" at dlopen.
            [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0755}
                                             ofItemAtPath:outPath error:NULL];
            return 0;
        }

        if (argc >= 2 && strcmp(argv[1], "--dylib") == 0) {
            if (argc < 7) {
                fprintf(stderr, "usage: %s --dylib <install-name> <iface|-> <exports|-> "
                        "<in.s> <out> [obj.o|lib.a|dep.dylib]...\n", argv[0]);
                return 2;
            }
            NSString *installName = @(argv[2]);
            NSString *ifacePath = @(argv[3]), *exportsPath = @(argv[4]);
            NSString *inPath = @(argv[5]), *outPath = @(argv[6]);
            NSError *err = nil;
            NSString *src = [NSString stringWithContentsOfFile:inPath encoding:NSUTF8StringEncoding error:&err];
            if (!src) { fprintf(stderr, "xcc-ln-arm64: cannot read '%s': %s\n", argv[5], err.localizedDescription.UTF8String); return 1; }
            XAArm64Assembler *as = [[XAArm64Assembler alloc] init];
            NSData *text = [as assemble:src error:&err];
            [as demoteCommonsToLocalData];
            if (!text) { fprintf(stderr, "xcc-ln-arm64: assembly failed: %s\n", err.localizedDescription.UTF8String); return 1; }
            NSData *iface = nil;
            if (![ifacePath isEqualToString:@"-"]) iface = [NSData dataWithContentsOfFile:ifacePath];
            NSMutableSet<NSString *> *exports = [NSMutableSet set];
            if (![exportsPath isEqualToString:@"-"]) {
                NSString *el = [NSString stringWithContentsOfFile:exportsPath encoding:NSUTF8StringEncoding error:NULL];
                for (NSString *ln in [el componentsSeparatedByString:@"\n"]) {
                    NSString *s = [ln stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (s.length && as.symbols[s]) [exports addObject:s];
                }
            }
            // Extra inputs after <out> — the SAME kinds the executable link
            // takes. A library that wraps external C (a shim plus a static
            // archive) is only self-contained if those actually land in the
            // .dylib; before this they were accepted by the driver and silently
            // dropped here, so the library built, was the same size whatever
            // was passed, and aborted at load on the first wrapped symbol.
            NSMutableArray<NSString *> *dObjs = [NSMutableArray array];
            NSMutableArray<NSString *> *dArchives = [NSMutableArray array];
            for (int i = 7; i < argc; i++) {
                NSString *p = @(argv[i]);
                if ([p hasPrefix:@"-"]) continue;          // ld directives: not ours to honour here
                NSString *e = p.pathExtension;
                if      ([e isEqualToString:@"o"]) [dObjs addObject:p];
                else if ([e isEqualToString:@"a"]) [dArchives addObject:p];
                // .dylib/.tbd dependencies are recorded by the driver as
                // LC_LOAD_DYLIB on the client, not bundled into this image.
            }
            NSMutableData *mtext = [text mutableCopy];
            NSMutableDictionary<NSString *, NSNumber *> *msyms = [as.symbols mutableCopy];
            NSMutableArray<XAArm64Fixup *> *mfix = [as.fixups mutableCopy];
            NSMutableData *mdata = [as.data mutableCopy] ?: [NSMutableData data];
            NSMutableSet<NSString *> *mdataSyms = [as.dataSymbols mutableCopy] ?: [NSMutableSet set];
            NSMutableArray<XAArm64Fixup *> *gotFixups = [NSMutableArray array];
            NSMutableArray<NSDictionary *> *mObjc = [NSMutableArray array];   // 069
            if (dObjs.count || dArchives.count) {
                int mrc = mergeMachOInputs(dObjs, dArchives, mtext, mdata,
                                           msyms, mdataSyms, mfix, mObjc, gotFixups);
                if (mrc) return mrc;
                text = mtext;
            }
            // 069 first: it MOVES data bytes, and the mod-init array must be
            // placed at the final tail, after everything else has settled.
            NSArray<NSDictionary *> *objcSects =
                repartitionObjcSections(mdata, mObjc, msyms, mdataSyms, mfix);
            NSUInteger miLen = appendModInit(as, mdata, mfix);
            NSData *dylib = [XTMachOWriter dylibFromText:text installName:installName
                                exports:exports iface:iface symbols:msyms
                                data:mdata dataSymbols:mdataSyms fixups:mfix
                          modInitLength:miLen
                            objcSections:objcSects];
            if (![dylib writeToFile:outPath atomically:YES]) {
                fprintf(stderr, "xcc-ln-arm64: cannot write '%s'\n", argv[6]); return 1;
            }
            [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0755}
                                             ofItemAtPath:outPath error:NULL];
            return 0;
        }

        // Assembler-only dump mode:
        //   xtcln-arm64 --dump <input.s>
        // Prints a canonical listing of everything the assembler produced —
        // section bytes, symbol offsets, fixups — so a second implementation
        // can be compared against this one byte for byte. The same idiom as
        // `xtc-fe --dump-ast`; it exists to be an ORACLE, so it prints the
        // whole state and nothing derived from it.
        if (argc >= 3 && strcmp(argv[1], "--dump") == 0) {
            NSError *derr = nil;
            NSString *dsrc = [NSString stringWithContentsOfFile:@(argv[2])
                                     encoding:NSUTF8StringEncoding error:&derr];
            if (!dsrc) { fprintf(stderr, "xcc-ln-arm64: cannot read '%s'\n", argv[2]); return 1; }
            XAArm64Assembler *das = [[XAArm64Assembler alloc] init];
            // Normalised first, so --dump can be pointed at ELF-dialect asm (the
            // Android runtime) as well as Mach-O. The pass is a no-op on Mach-O
            // input — nothing there matches `:lo12:` or a bare adrp operand — so
            // the self-host as64-diff oracle is unchanged.
            NSData *dtext = [das assemble:[XAArm64Assembler machoDialectFromElf:dsrc]
                                    error:&derr];
            if (!dtext) {
                fprintf(stderr, "xcc-ln-arm64: assembly failed: %s\n",
                        derr.localizedDescription.UTF8String);
                return 1;
            }
            NSMutableString *o = [NSMutableString string];
            void (^hex)(NSString *, NSData *) = ^(NSString *tag, NSData *d) {
                [o appendFormat:@"%@ %lu\n", tag, (unsigned long)d.length];
                const uint8_t *p = d.bytes;
                for (NSUInteger i = 0; i < d.length; i += 16) {
                    [o appendFormat:@"%08lx ", (unsigned long)i];
                    for (NSUInteger j = i; j < d.length && j < i + 16; j++)
                        [o appendFormat:@"%02x", p[j]];
                    [o appendString:@"\n"];
                }
            };
            hex(@"text", dtext);
            hex(@"data", das.data);
            NSArray *keys = [das.symbols.allKeys sortedArrayUsingSelector:@selector(compare:)];
            [o appendFormat:@"symbols %lu\n", (unsigned long)keys.count];
            for (NSString *k in keys)
                [o appendFormat:@"  %@ %llu %@\n", k,
                 (unsigned long long)das.symbols[k].unsignedLongLongValue,
                 [das.dataSymbols containsObject:k] ? @"data" : @"text"];
            [o appendFormat:@"fixups %lu\n", (unsigned long)das.fixups.count];
            for (XAArm64Fixup *f in das.fixups)
                [o appendFormat:@"  %llu %d %@ %u %lld\n",
                 (unsigned long long)f.offset, (int)f.kind, f.symbol,
                 (unsigned)f.scale, (long long)f.addend];
            fputs(o.UTF8String, stdout);
            return 0;
        }

        if (argc < 3) {
            fprintf(stderr, "usage: %s <input.s> <output>\n", argv[0]);
            return 2;
        }
        NSString *asmPath = @(argv[1]);
        NSString *outPath = @(argv[2]);
        NSError *err = nil;
        NSString *src = [NSString stringWithContentsOfFile:asmPath
                                                  encoding:NSUTF8StringEncoding error:&err];
        if (!src) {
            fprintf(stderr, "xcc-ln-arm64: cannot read '%s': %s\n",
                    argv[1], err.localizedDescription.UTF8String);
            return 1;
        }

        XAArm64Assembler *as = [[XAArm64Assembler alloc] init];
        NSData *text = [as assemble:src error:&err];
        [as demoteCommonsToLocalData];
        if (!text) {
            fprintf(stderr, "xcc-ln-arm64: assembly failed: %s\n",
                    err.localizedDescription.UTF8String);
            return 1;
        }

        // Entry is the runtime crt (`_xtc_start`); a program without the runtime
        // falls back to `_main`.
        NSNumber *entry = as.symbols[@"_xtc_start"] ?: as.symbols[@"_main"];
        if (!entry) {
            fprintf(stderr, "xcc-ln-arm64: no entry symbol (_xtc_start / _main)\n");
            return 1;
        }

        // Extra args are dylib/.tbd paths to link against and forwarded ld
        // directives (the driver unwraps -Xlinker/-Wl, into raw args). We honour
        // `-rpath <path>`; other `-flags` we don't (yet) implement are ignored with
        // a warning — a dropped flag that mattered is then a fixable linker bug, not
        // a silent clang divergence. A non-flag arg is a dylib/.tbd to inspect.
        NSMutableArray<NSDictionary *> *dylibs = [NSMutableArray array];
        NSMutableArray<NSString *> *archives = [NSMutableArray array];   // static .a paths
        NSMutableArray<NSString *> *objectFiles = [NSMutableArray array]; // explicit .o paths
        NSMutableArray<NSString *> *rpaths = [NSMutableArray array];
        NSMutableSet<NSString *> *rpSeen = [NSMutableSet set];
        void (^addRpath)(NSString *) = ^(NSString *dir) {
            if (dir.length && ![rpSeen containsObject:dir]) { [rpaths addObject:dir]; [rpSeen addObject:dir]; }
        };
        addRpath(@"@loader_path");
        for (int i=3;i<argc;i++) {
            NSString *dp = @(argv[i]);
            if ([dp isEqualToString:@"-rpath"] && i+1 < argc) { addRpath(@(argv[++i])); continue; }
            if ([dp hasPrefix:@"-"]) {          // an ld directive we don't implement
                fprintf(stderr, "xcc-ln-arm64: note: ignoring unrecognised linker flag '%s'\n", argv[i]);
                continue;
            }
            if ([dp.pathExtension isEqualToString:@"a"]) { [archives addObject:dp]; continue; }  // static archive
            // An explicitly-listed .o links UNCONDITIONALLY — that is the whole
            // difference between naming an object and naming an archive, which
            // is searched only for what is still undefined.
            if ([dp.pathExtension isEqualToString:@"o"]) { [objectFiles addObject:dp]; continue; }
            BOOL isTbd = [dp.pathExtension isEqualToString:@"tbd"];
            NSDictionary *info = isTbd ? [XTMachOWriter inspectTbd:dp]
                                       : [XTMachOWriter inspectDylib:dp];
            if (!info) {                        // stray/unreadable → warn + skip (tolerant)
                fprintf(stderr, "xcc-ln-arm64: note: skipping unreadable %s '%s'\n",
                        isTbd ? "tbd stub" : "arg", argv[i]);
                continue;
            }
            [dylibs addObject:info];
            // A .tbd names a shared-cache library by an absolute install-name (e.g.
            // /usr/lib/libz.1.dylib) that dyld finds without help — no rpath. An
            // on-disk .dylib is @rpath-relative, so add its directory.
            if (!isTbd) addRpath([dp stringByDeletingLastPathComponent]);
        }

        // Static-archive linking: pull each `.a` member that DEFINES a symbol the
        // program references but doesn't define locally, append its __text after the
        // program text (4-aligned), register its symbols as local, and translate its
        // __text relocations into fixups. Iterates to a fixpoint so an object that
        // references a symbol defined in another member pulls it in too. Whatever
        // stays undefined is a real dylib/libSystem import.
        NSMutableData *mtext = [text mutableCopy];
        NSMutableDictionary<NSString *, NSNumber *> *msyms = [as.symbols mutableCopy];
        NSMutableArray<XAArm64Fixup *> *mfix = [as.fixups mutableCopy];
        NSMutableData *mdata = [as.data mutableCopy] ?: [NSMutableData data];
        NSMutableSet<NSString *> *mdataSyms = [as.dataSymbols mutableCopy] ?: [NSMutableSet set];
        NSMutableArray<XAArm64Fixup *> *gotFixups = [NSMutableArray array];  // GOT refs, resolved after the merge
        NSMutableArray<NSDictionary *> *mObjc = [NSMutableArray array];      // 069: ObjC section ranges
        {
            int mrc = mergeMachOInputs(objectFiles, archives, mtext, mdata,
                                       msyms, mdataSyms, mfix, mObjc, gotFixups);
            if (mrc) return mrc;
        }

        // Diagnose DIRECT-addressing references (adrp/add PAGE21/PAGEOFF12)
        // to symbols that are neither defined nor GOT-indirected — the
        // incomplete-archive case used to link SILENTLY and crash at the
        // first use (blewit finding #7). Calls stub-bind and pointer slots
        // data-bind, so those resolve at load; a direct page reference to a
        // missing symbol has nothing to bind and must fail HERE, by name.
        {
            NSMutableSet<NSString *> *missing = [NSMutableSet set];
            for (XAArm64Fixup *f in mfix) {
                if ((f.kind == XAArm64FixupPage21 || f.kind == XAArm64FixupPageOff12)
                    && !msyms[f.symbol])
                    [missing addObject:f.symbol];
            }
            if (missing.count) {
                for (NSString *s in [missing.allObjects sortedArrayUsingSelector:@selector(compare:)])
                    fprintf(stderr, "xcc-ln-arm64: error: undefined symbol '%s' "
                                    "(directly addressed; not resolvable at load)\n",
                            s.UTF8String);
                return 1;
            }
        }
        NSArray<NSDictionary *> *objcSects =
            repartitionObjcSections(mdata, mObjc, msyms, mdataSyms, mfix);
        NSUInteger miLen = appendModInit(as, mdata, mfix);
        NSData *macho = [XTMachOWriter executableFromText:mtext
                                              entryOffset:entry.unsignedLongLongValue
                                                  symbols:msyms
                                                     data:mdata
                                              dataSymbols:mdataSyms
                                                   fixups:mfix
                                                   dylibs:dylibs
                                                   rpaths:rpaths
                                            modInitLength:miLen
                                             objcSections:objcSects];
        if (![macho writeToFile:outPath atomically:YES]) {
            fprintf(stderr, "xcc-ln-arm64: cannot write '%s'\n", argv[2]);
            return 1;
        }
        // Make it executable (the writer signs it in-house; no chmod-from-shell).
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0755}
                                         ofItemAtPath:outPath error:NULL];
        return 0;
    }
}
