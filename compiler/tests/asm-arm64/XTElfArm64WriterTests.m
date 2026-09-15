/****************************************************************************\
|* XTElfArm64WriterTests.m
|*
|* XTElfArm64Writer emits the aarch64 ELF that `-A android` runs. This suite is
|* self-contained: it assembles a tiny program with XAArm64Assembler, writes the
|* ET_DYN image, and parses the BYTES back — no NDK, no emulator, no adb.
|*
|* It checks the things that are silent when wrong. A missing PT_PHDR, a
|* PT_INTERP naming the wrong loader, a writable segment that is also
|* executable, a `.quad <symbol>` that did not become an R_AARCH64_RELATIVE, an
|* import with no GLOB_DAT — none of those fail the LINK. They fail at map time
|* on a device, or worse, run with a null vtable word.
|*
|* The end-to-end "push it and run it on Android" proof lives in
|* examples/android/run.sh, which needs a booted emulator and so is not part of
|* make test.
\****************************************************************************/

#import <Foundation/Foundation.h>
#import "XAArm64Assembler.h"
#import "XTElfArm64Writer.h"

enum { E_ET_DYN = 3, E_EM_AARCH64 = 183,
       E_PT_LOAD = 1, E_PT_DYNAMIC = 2, E_PT_INTERP = 3, E_PT_PHDR = 6,
       E_PF_X = 1, E_PF_W = 2,
       E_DT_NULL = 0, E_DT_NEEDED = 1, E_DT_RELA = 7, E_DT_RELASZ = 8,
       E_R_GLOB_DAT = 1025, E_R_RELATIVE = 1027 };

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1]<<8) | ((uint32_t)p[2]<<16) | ((uint32_t)p[3]<<24);
}
static uint64_t rd64(const uint8_t *p) {
    uint64_t v = 0; for (int i = 7; i >= 0; i--) v = (v << 8) | p[i]; return v;
}

// Two vtable-shaped `.quad <symbol>` words and one bionic import, which is the
// smallest program that exercises every relocation kind the writer emits.
static NSString *kSrc =
    @".text\n"
    @".globl _start\n"
    @"_start:\n"
    @"    stp x29, x30, [sp, #-16]!\n"
    @"    adrp x0, msg@PAGE\n"
    @"    add  x0, x0, msg@PAGEOFF\n"
    @"    bl puts\n"
    @"    mov w0, #0\n"
    @"    ldp x29, x30, [sp], #16\n"
    @"    ret\n"
    @".globl helper\n"
    @"helper:\n"
    @"    ret\n"
    @".data\n"
    @"msg:\n"
    @"    .asciz \"hi\"\n"
    @".p2align 3\n"
    @".globl vtbl\n"
    @"vtbl:\n"
    @"    .quad _start\n"
    @"    .quad helper\n";

int runArm64ElfWriterTests(void);
int runArm64ElfWriterTests(void) {
    int failures = 0;
    #define CHECK(cond, fmt, ...) do { \
        if (cond) fprintf(stderr, "  PASS: " fmt "\n", ##__VA_ARGS__); \
        else { fprintf(stderr, "  FAIL: " fmt "\n", ##__VA_ARGS__); failures++; } \
    } while (0)

    NSError *err = nil;
    XAArm64Assembler *as = [[XAArm64Assembler alloc] init];
    NSData *text = [as assemble:kSrc error:&err];
    if (!text) {
        fprintf(stderr, "  FAIL: test program did not assemble: %s\n",
                err.localizedDescription.UTF8String);
        return 1;
    }
    NSData *img = [XTElfArm64Writer sharedObjectFromText:text data:as.data
                                                 symbols:as.symbols
                                             dataSymbols:as.dataSymbols
                                           globalSymbols:[NSSet setWithObject:@"helper"]
                                                  fixups:as.fixups
                                                  soname:nil
                                                  needed:@[@"libc.so", @"libm.so"]
                                             entrySymbol:@"_start"
                                           modInitLength:0
                                                   error:&err];
    if (!img) {
        fprintf(stderr, "  FAIL: link failed: %s\n", err.localizedDescription.UTF8String);
        return 1;
    }
    const uint8_t *b = img.bytes;
    CHECK(img.length > 64 && b[0]==0x7f && b[1]=='E' && b[2]=='L' && b[3]=='F', "ELF magic");
    CHECK(b[4] == 2 && b[5] == 1, "ELF64, little-endian");
    CHECK(rd16(b+16) == E_ET_DYN, "e_type is ET_DYN (Android runs nothing else)");
    CHECK(rd16(b+18) == E_EM_AARCH64, "e_machine is EM_AARCH64");

    uint64_t entry = rd64(b+24), phoff = rd64(b+32);
    uint16_t phentsize = rd16(b+54), phnum = rd16(b+56);
    CHECK(phentsize == 56, "e_phentsize is 56");

    BOOL sawPhdr = NO, sawInterp = NO, sawDynamic = NO, wxSegment = NO;
    BOOL entryInExec = NO;
    uint64_t interpOff = 0, dynOff = 0, dynSz = 0;
    for (uint16_t i = 0; i < phnum; i++) {
        const uint8_t *ph = b + phoff + (uint64_t)i * phentsize;
        uint32_t type = rd32(ph), flags = rd32(ph+4);
        uint64_t off = rd64(ph+8), filesz = rd64(ph+32), memsz = rd64(ph+40);
        uint64_t align = rd64(ph+48);
        if (type == E_PT_PHDR)    sawPhdr = YES;
        if (type == E_PT_INTERP) { sawInterp = YES; interpOff = off; }
        if (type == E_PT_DYNAMIC){ sawDynamic = YES; dynOff = off; dynSz = filesz; }
        if (type == E_PT_LOAD) {
            if ((flags & E_PF_W) && (flags & E_PF_X)) wxSegment = YES;
            if ((flags & E_PF_X) && entry >= off && entry < off + memsz) entryInExec = YES;
            // 16 KB: Android 15 devices have 16 KB pages and will not map a
            // 4 KB-aligned segment. 16 KB is accepted on 4 KB devices too.
            CHECK(align == 0x4000, "PT_LOAD %u aligns to 16 KB", i);
            CHECK(filesz <= memsz, "PT_LOAD %u filesz <= memsz", i);
        }
    }
    CHECK(sawPhdr, "PT_PHDR present (the loader finds the phdrs through it)");
    CHECK(sawInterp, "PT_INTERP present");
    CHECK(sawInterp && strcmp((const char *)b + interpOff, "/system/bin/linker64") == 0,
          "PT_INTERP names bionic's loader");
    CHECK(sawDynamic, "PT_DYNAMIC present");
    CHECK(!wxSegment, "no segment is both writable and executable");
    CHECK(entryInExec, "e_entry lands inside the executable segment");

    // DT_NEEDED for each library, and the RELA table the loader will walk.
    int needed = 0; uint64_t relaOff = 0, relaSz = 0;
    for (uint64_t o = dynOff; o + 16 <= dynOff + dynSz; o += 16) {
        uint64_t tag = rd64(b+o), val = rd64(b+o+8);
        if (tag == E_DT_NEEDED) needed++;
        if (tag == E_DT_RELA)   relaOff = val;
        if (tag == E_DT_RELASZ) relaSz  = val;
        if (tag == E_DT_NULL) break;
    }
    CHECK(needed == 2, "two DT_NEEDED entries (got %d)", needed);

    int nRelative = 0, nGlobDat = 0;
    for (uint64_t o = relaOff; o + 24 <= relaOff + relaSz; o += 24) {
        uint32_t type = rd32(b+o+8);
        if (type == E_R_RELATIVE) nRelative++;
        if (type == E_R_GLOB_DAT) nGlobDat++;
    }
    // The two vtable words. Without these the loader never biases them and the
    // program calls through a link-time address that is not where it landed.
    CHECK(nRelative == 2, "both .quad <symbol> words became R_AARCH64_RELATIVE (got %d)",
          nRelative);
    // `puts` — the only symbol nothing here defines.
    CHECK(nGlobDat == 1, "the one bionic import got a GLOB_DAT (got %d)", nGlobDat);

    // An undefined symbol reached ABSOLUTELY cannot be imported: it would need
    // the referencing instruction rewritten. Silently emitting a relocation
    // against 0 is the failure this refuses.
    XAArm64Fixup *bad = [XAArm64Fixup new];
    bad.offset = 0; bad.kind = XAArm64FixupPointer64; bad.symbol = @"nowhere";
    NSError *bErr = nil;
    NSData *bimg = [XTElfArm64Writer sharedObjectFromText:text data:as.data
                                                  symbols:as.symbols
                                              dataSymbols:as.dataSymbols
                                            globalSymbols:[NSSet set]
                                                   fixups:[as.fixups arrayByAddingObject:bad]
                                                   soname:nil needed:nil
                                              entrySymbol:@"_start"
                                            modInitLength:0 error:&bErr];
    CHECK(bimg == nil && bErr != nil, "an absolute reference to an undefined symbol is refused");

    #undef CHECK
    return failures;
}
