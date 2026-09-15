/****************************************************************************\
|* XTElfWriterTests.m
|*
|* The Linux leg of the self-hosted toolchain (private:docs/Design/native-toolchain.md
|* §12): verifies XTElfWriter emits structurally valid x86-64 ELF. Self-contained
|* — it assembles with XAX86_64Assembler, emits the ELF, and parses the bytes
|* back. No clang, no readelf, and crucially no Linux host.
|*
|* That last point is why this suite exists. Every other check on the ELF work
|* (tests/asm-x86_64/elf-run.sh, selfhost-lib.sh, the corpus) needs a reachable
|* x86-64 Linux box and skips without one — so on a machine that has none, a
|* broken writer would have gone completely unnoticed.
|*
|* The "it actually runs under ld.so" proof stays in those scripts; this checks
|* the shapes the loader depends on.
\****************************************************************************/

#import <Foundation/Foundation.h>
#import "XAX86_64Assembler.h"
#import "XTElfWriter.h"

static uint16_t erd16(const uint8_t *p){ return (uint16_t)(p[0]|(p[1]<<8)); }
static uint32_t erd32(const uint8_t *p){ return p[0]|(p[1]<<8)|(p[2]<<16)|((uint32_t)p[3]<<24); }
static uint64_t erd64(const uint8_t *p){ uint64_t v=0; for(int i=0;i<8;i++) v|=(uint64_t)p[i]<<(8*i); return v; }

// Find the first program header of `type`; returns its record or NULL.
static const uint8_t *phdrOfType(const uint8_t *b, uint32_t type) {
    uint64_t phoff = erd64(b + 0x20);
    uint16_t phentsize = erd16(b + 0x36), phnum = erd16(b + 0x38);
    for (uint16_t i = 0; i < phnum; i++) {
        const uint8_t *p = b + phoff + (uint64_t)i * phentsize;
        if (erd32(p) == type) return p;
    }
    return NULL;
}

// Find a section header by name; returns its record or NULL.
static const uint8_t *shdrNamed(const uint8_t *b, const char *want) {
    uint64_t shoff = erd64(b + 0x28);
    uint16_t shentsize = erd16(b + 0x3A), shnum = erd16(b + 0x3C), shstrndx = erd16(b + 0x3E);
    if (!shoff || !shnum || shstrndx >= shnum) return NULL;
    const uint8_t *strRec = b + shoff + (uint64_t)shstrndx * shentsize;
    const char *str = (const char *)(b + erd64(strRec + 0x18));
    for (uint16_t i = 0; i < shnum; i++) {
        const uint8_t *r = b + shoff + (uint64_t)i * shentsize;
        if (strcmp(str + erd32(r), want) == 0) return r;
    }
    return NULL;
}

int runX86_64ElfWriterTests(void);
int runX86_64ElfWriterTests(void) {
    int failures = 0;
    #define CHECK(cond, msg) do { if (!(cond)) { fprintf(stderr,"  FAIL: %s\n", msg); failures++; } \
                                  else fprintf(stderr,"  PASS: %s\n", msg); } while(0)

    enum { PT_LOAD = 1, PT_DYNAMIC = 2, PT_INTERP = 3, PT_PHDR = 6,
           PT_GNU_STACK = 0x6474e551 };

    // ── a static executable ──
    XAX86_64Assembler *as = [[XAX86_64Assembler alloc] init];
    NSError *e = nil;
    NSData *text = [as assemble:@"\t.intel_syntax noprefix\n\t.text\n\t.globl _start\n"
                                 @"_start:\n\tmov eax, 60\n\tmov edi, 7\n\tsyscall\n" error:&e];
    CHECK(text != nil && text.length == 12, "assembled a 3-instruction program");
    if (!text) return failures;

    NSData *elf = [XTElfWriter staticExecutableFromText:text data:[NSData data]
                                                symbols:as.symbols dataSymbols:as.dataSymbols
                                             absSymbols:nil
                                                 fixups:as.fixups entrySymbol:@"_start"
                                                    bss:[NSData data] bssSymbols:@[] bssAlign:1 error:&e];
    CHECK(elf != nil, "emitted a static executable");
    if (!elf) return failures;
    const uint8_t *b = elf.bytes;

    CHECK(b[0]==0x7f && b[1]=='E' && b[2]=='L' && b[3]=='F', "ELF magic");
    CHECK(b[4] == 2, "ELFCLASS64");
    CHECK(b[5] == 1, "ELFDATA2LSB");
    CHECK(erd16(b + 0x10) == 2, "e_type ET_EXEC");
    CHECK(erd16(b + 0x12) == 62, "e_machine EM_X86_64");
    CHECK(erd64(b + 0x18) == [XTElfWriter textAddressWithDataSegment:NO],
          "e_entry is _start at the text base");
    // A PT_LOAD's p_offset and p_vaddr must be congruent modulo the page size or
    // the kernel refuses the mapping outright.
    const uint8_t *ld = phdrOfType(b, PT_LOAD);
    CHECK(ld != NULL, "has a PT_LOAD");
    if (ld) CHECK((erd64(ld + 0x08) & 0xFFF) == (erd64(ld + 0x10) & 0xFFF),
                  "PT_LOAD p_offset ≡ p_vaddr (mod page)");
    // Present with no PF_X: the stack must not be executable.
    const uint8_t *gs = phdrOfType(b, PT_GNU_STACK);
    CHECK(gs != NULL, "has PT_GNU_STACK");
    if (gs) CHECK((erd32(gs + 0x04) & 1) == 0, "PT_GNU_STACK is not executable");
    CHECK(shdrNamed(b, ".symtab") != NULL, "static exec carries .symtab");
    CHECK(shdrNamed(b, ".text") != NULL,   "static exec carries .text");

    // An undefined symbol must be an ERROR here, not a zero-filled call.
    XAX86_64Assembler *as2 = [[XAX86_64Assembler alloc] init];
    NSData *t2 = [as2 assemble:@"\t.intel_syntax noprefix\n\t.text\n\t.globl _start\n"
                                @"_start:\n\tcall nosuchthing\n\tret\n" error:&e];
    NSError *e2 = nil;
    NSData *bad = t2 ? [XTElfWriter staticExecutableFromText:t2 data:[NSData data]
                                                    symbols:as2.symbols dataSymbols:as2.dataSymbols
                                                 absSymbols:nil
                                                     fixups:as2.fixups entrySymbol:@"_start"
                                                        bss:[NSData data] bssSymbols:@[] bssAlign:1
                                                      error:&e2] : nil;
    CHECK(bad == nil && e2 != nil, "static link rejects an undefined symbol");

    // The assembler must reject a duplicate definition rather than let the last
    // one win — two clang-generated files sharing a .LBB name silently corrupted
    // every branch in the first one.
    XAX86_64Assembler *as3 = [[XAX86_64Assembler alloc] init];
    NSError *e3 = nil;
    NSData *dup = [as3 assemble:@"\t.text\nfoo:\n\tret\nfoo:\n\tret\n" error:&e3];
    CHECK(dup == nil && e3 != nil, "assembler rejects a duplicate label");

    // ── a shared object ──
    XAX86_64Assembler *as4 = [[XAX86_64Assembler alloc] init];
    NSData *t4 = [as4 assemble:@"\t.intel_syntax noprefix\n\t.text\n\t.globl xt_id\n"
                                @"xt_id:\n\tmov eax, edi\n\tjmp helper\n" error:&e];
    CHECK(t4 != nil, "assembled a library with one export and one import");
    NSData *so = t4 ? [XTElfWriter sharedObjectFromText:t4 data:[NSData data]
                                                symbols:as4.symbols dataSymbols:as4.dataSymbols
                                          globalSymbols:as4.globalSymbols fixups:as4.fixups
                                                 soname:@"libtest.so" needed:@[@"libc.so.6"]
                                            entrySymbol:nil runpath:nil
                                                  iface:[@"{}" dataUsingEncoding:NSUTF8StringEncoding]
                                                    bss:[NSData data] bssSymbols:@[] bssAlign:1
                                                  error:&e] : nil;
    CHECK(so != nil, "emitted a shared object");
    if (so) {
        const uint8_t *s = so.bytes;
        CHECK(erd16(s + 0x10) == 3, "e_type ET_DYN");
        CHECK(erd64(s + 0x18) == 0, "a library has no entry point");
        CHECK(phdrOfType(s, PT_DYNAMIC) != NULL, "has PT_DYNAMIC");
        CHECK(phdrOfType(s, PT_GNU_STACK) != NULL,
              "has PT_GNU_STACK (without it the loader refuses to map it)");
        CHECK(phdrOfType(s, PT_INTERP) == NULL, "a library has no PT_INTERP");
        CHECK(shdrNamed(s, ".dynsym") != NULL,  "has .dynsym");
        CHECK(shdrNamed(s, ".hash") != NULL,    "has .hash");
        CHECK(shdrNamed(s, ".dynamic") != NULL, "has .dynamic");
        CHECK(shdrNamed(s, ".symtab") != NULL,  "has .symtab (internals, not just exports)");
        const uint8_t *ifc = shdrNamed(s, ".xtc.iface");
        CHECK(ifc != NULL, "carries .xtc.iface — #import <Lib> reads it by name");
        if (ifc) CHECK(erd64(ifc + 0x20) == 2, ".xtc.iface holds the bytes given");
        // e_shstrndx must name a real section, or every tool reads garbage names.
        CHECK(erd16(s + 0x3E) < erd16(s + 0x3C), "e_shstrndx is in range");
    }

    // ── a dynamically-linked executable (PIE) ──
    XAX86_64Assembler *as5 = [[XAX86_64Assembler alloc] init];
    NSData *t5 = [as5 assemble:@"\t.intel_syntax noprefix\n\t.text\n\t.globl _start\n"
                                @"_start:\n\tcall xt_id\n\tret\n" error:&e];
    NSData *pie = t5 ? [XTElfWriter sharedObjectFromText:t5 data:[NSData data]
                                                 symbols:as5.symbols dataSymbols:as5.dataSymbols
                                           globalSymbols:as5.globalSymbols fixups:as5.fixups
                                                  soname:@"prog" needed:@[@"libtest.so"]
                                             entrySymbol:@"_start" runpath:@"$ORIGIN"
                                                   iface:nil
                                                     bss:[NSData data] bssSymbols:@[] bssAlign:1
                                                   error:&e] : nil;
    CHECK(pie != nil, "emitted a dynamically-linked executable");
    if (pie) {
        const uint8_t *s = pie.bytes;
        // Both were learned the hard way: without PT_PHDR ld.so dies before it
        // can print anything at all, and DT_SONAME on an executable muddles the
        // lookup scope.
        CHECK(phdrOfType(s, PT_PHDR) != NULL, "has PT_PHDR (ld.so needs it to find the phdrs)");
        CHECK(phdrOfType(s, PT_INTERP) != NULL, "has PT_INTERP");
        CHECK(erd64(s + 0x18) != 0, "has an entry point");
        const uint8_t *dyn = shdrNamed(s, ".dynamic");
        CHECK(dyn != NULL, "has .dynamic");
        if (dyn) {
            BOOL sawSoname = NO, sawNeeded = NO, sawRunpath = NO;
            uint64_t off = erd64(dyn + 0x18), sz = erd64(dyn + 0x20);
            for (uint64_t i = 0; i + 16 <= sz; i += 16) {
                uint64_t tag = erd64(s + off + i);
                if (tag == 14) sawSoname = YES;
                if (tag == 1)  sawNeeded = YES;
                if (tag == 29) sawRunpath = YES;
            }
            CHECK(!sawSoname, "an executable emits no DT_SONAME");
            CHECK(sawNeeded,  "DT_NEEDED names the library");
            CHECK(sawRunpath, "DT_RUNPATH carries $ORIGIN");
        }
    }
    #undef CHECK
    return failures;
}
