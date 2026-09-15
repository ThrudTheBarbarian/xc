/****************************************************************************\
|* XTMachOWriterTests.m
|*
|* Phase 2 of the self-hosted native toolchain (private:docs/Design/native-toolchain.md):
|* verifies XTMachOWriter emits a structurally valid arm64 MH_EXECUTE. This
|* suite is self-contained — it assembles a tiny program with XAArm64Assembler,
|* emits the Mach-O, and parses the bytes back to check the header, segments,
|* LC_MAIN entry, and symbol table. No clang / codesign / otool needed.
|*
|* The end-to-end "sign it and run it on Apple Silicon" proof lives in
|* tests/asm-arm64/macho-run.sh (macOS-gated), which is not part of make test.
\****************************************************************************/

#import <Foundation/Foundation.h>
#import "XAArm64Assembler.h"
#import "XTMachOWriter.h"

static uint32_t rd32(const uint8_t *p){ return p[0]|(p[1]<<8)|(p[2]<<16)|((uint32_t)p[3]<<24); }
static uint64_t rd64(const uint8_t *p){ uint64_t v=0; for(int i=0;i<8;i++) v|=(uint64_t)p[i]<<(8*i); return v; }

int runArm64MachOTests(void);
int runArm64MachOTests(void) {
    int failures = 0;
    #define CHECK(cond, msg) do { if (!(cond)) { fprintf(stderr,"  FAIL: %s\n", msg); failures++; } \
                                  else fprintf(stderr,"  PASS: %s\n", msg); } while(0)

    // _main: movz w0,#7 ; ret   (entry at offset 0)
    XAArm64Assembler *as = [[XAArm64Assembler alloc] init];
    NSError *e = nil;
    NSData *text = [as assemble:@"_main:\nmovz w0, #7\nret\n" error:&e];
    CHECK(text != nil && text.length == 8, "assembled tiny program (8 bytes)");
    if (!text) return failures;

    NSData *macho = [XTMachOWriter executableFromText:text entryOffset:0
                                              symbols:@{@"_main": @0} data:nil dataSymbols:nil fixups:@[]];
    CHECK(macho != nil && macho.length >= 0x4000, "emitted Mach-O (>= one page)");
    const uint8_t *b = macho.bytes;

    // mach_header_64
    CHECK(rd32(b) == 0xFEEDFACF, "magic MH_MAGIC_64");
    CHECK(rd32(b+4) == 0x0100000C, "cputype CPU_TYPE_ARM64");
    CHECK(rd32(b+12) == 2, "filetype MH_EXECUTE");
    uint32_t ncmds = rd32(b+16);
    CHECK(rd32(b+24) == 0x00200085, "flags NOUNDEFS|DYLDLINK|TWOLEVEL|PIE");

    // walk load commands: find LC_MAIN (0x80000028), __TEXT segment, LC_SYMTAB
    uint64_t off = 32; BOOL sawMain=NO, sawText=NO, sawSymtab=NO, sawLibSystem=NO;
    uint64_t mainEntryOff = ~0ull; uint64_t textAddr=0, textSize=0;
    for (uint32_t i = 0; i < ncmds; i++) {
        uint32_t cmd = rd32(b+off), csz = rd32(b+off+4);
        if (cmd == (0x28|0x80000000u)) { sawMain=YES; mainEntryOff = rd64(b+off+8); }
        else if (cmd == 0x19) { // LC_SEGMENT_64
            if (memcmp(b+off+8, "__TEXT", 6)==0 && b[off+8+6]==0) {
                sawText=YES;
                // section_64 __text follows the 72-byte segment command
                const uint8_t *sec = b+off+72;
                textAddr = rd64(sec+32); textSize = rd64(sec+40);
            }
        }
        else if (cmd == 0x2) sawSymtab=YES;
        else if (cmd == 0xc) { // LC_LOAD_DYLIB
            const char *nm = (const char *)(b+off+rd32(b+off+8));
            if (strstr(nm, "libSystem")) sawLibSystem=YES;
        }
        off += csz;
    }
    CHECK(off == 32 + rd32(b+20), "load commands span exactly sizeofcmds");
    CHECK(sawText, "__TEXT segment present");
    CHECK(sawMain, "LC_MAIN present");
    CHECK(sawSymtab, "LC_SYMTAB present");
    CHECK(sawLibSystem, "LC_LOAD_DYLIB libSystem present");
    CHECK(mainEntryOff == 0x4000, "LC_MAIN entryoff = page-aligned __text offset");
    CHECK(textAddr == 0x100000000ull + 0x4000, "__text vmaddr = TEXT base + entry");
    CHECK(textSize == 8, "__text section size = 8 bytes");

    // the entry bytes at mainEntryOff must be our movz+ret
    CHECK(rd32(b+mainEntryOff) == 0x528000E0, "entry[0] = movz w0,#7");
    CHECK(rd32(b+mainEntryOff+4) == 0xD65F03C0, "entry[1] = ret");

    // ── import path: a program that calls an external function ──
    XAArm64Assembler *as2 = [[XAArm64Assembler alloc] init];
    NSData *t2 = [as2 assemble:@"_main:\nmovz w0, #42\nbl _exit\n" error:&e];
    CHECK(t2 != nil, "assembled program with bl _exit");
    NSNumber *entry = as2.symbols[@"_main"];
    NSData *m2 = [XTMachOWriter executableFromText:t2
                    entryOffset:entry.unsignedLongLongValue
                        symbols:as2.symbols data:as2.data dataSymbols:as2.dataSymbols fixups:as2.fixups];
    const uint8_t *b2 = m2.bytes; uint32_t nc2 = rd32(b2+16);
    BOOL sawStubs=NO, sawGot=NO, sawDyldInfo=NO, sawData=NO; uint64_t o2=32;
    for (uint32_t i=0;i<nc2;i++){
        uint32_t cmd=rd32(b2+o2), csz=rd32(b2+o2+4);
        if (cmd==0x19) { // segment: scan its sections
            const char *sn=(const char*)(b2+o2+8);
            if (strcmp(sn,"__DATA")==0) sawData=YES;
            uint32_t nsects=rd32(b2+o2+64);
            for (uint32_t s=0;s<nsects;s++){ const char *sec=(const char*)(b2+o2+72+s*80);
                if (strcmp(sec,"__stubs")==0) sawStubs=YES; if (strcmp(sec,"__got")==0) sawGot=YES; }
        } else if (cmd==(0x22|0x80000000u)) sawDyldInfo=YES;
        o2+=csz;
    }
    CHECK(o2 == 32 + rd32(b2+20), "import binary: load commands span sizeofcmds");
    CHECK(sawData, "import binary: __DATA segment present");
    CHECK(sawStubs, "import binary: __stubs section present");
    CHECK(sawGot, "import binary: __got section present");
    CHECK(sawDyldInfo, "import binary: LC_DYLD_INFO_ONLY present");

    // ── data path: a program referencing a __DATA symbol via adrp/add ──
    XAArm64Assembler *as3 = [[XAArm64Assembler alloc] init];
    NSData *t3 = [as3 assemble:@"_main:\nadrp x1, _m@PAGE\nadd x1, x1, _m@PAGEOFF\nret\n"
                                "\n.section __DATA,__data\n_m:\n.byte 0x41\n.byte 0x42\n" error:&e];
    CHECK(t3 != nil, "assembled program referencing __DATA symbol");
    CHECK(as3.data.length == 2, "assembler captured 2 data bytes");
    CHECK([as3.dataSymbols containsObject:@"_m"], "assembler tagged _m as a data symbol");
    NSData *m3 = [XTMachOWriter executableFromText:t3
                    entryOffset:as3.symbols[@"_main"].unsignedLongLongValue
                        symbols:as3.symbols data:as3.data dataSymbols:as3.dataSymbols fixups:as3.fixups];
    const uint8_t *b3 = m3.bytes; uint32_t nc3 = rd32(b3+16); uint64_t o3=32; BOOL sawDataSect=NO;
    for (uint32_t i=0;i<nc3;i++){ uint32_t cmd=rd32(b3+o3), csz=rd32(b3+o3+4);
        if (cmd==0x19) { uint32_t nsects=rd32(b3+o3+64);
            for (uint32_t s=0;s<nsects;s++) if (strcmp((const char*)(b3+o3+72+s*80),"__data")==0) sawDataSect=YES; }
        o3+=csz; }
    CHECK(sawDataSect, "data binary: __data section present");
    // adrp at the entry (offset 0x4000) must have been patched off zero immediate
    CHECK(rd32(b3+0x4000) != 0x90000001, "adrp _m@PAGE patched (non-zero page immediate)");

    // ── code signature: LC_CODE_SIGNATURE + a well-formed SuperBlob/CodeDirectory ──
    uint64_t o4=32; uint32_t sigOff=0, sigSz=0;
    for (uint32_t i=0;i<ncmds;i++){ uint32_t cmd=rd32(b+o4), csz=rd32(b+o4+4);
        if (cmd==0x1d) { sigOff=rd32(b+o4+8); sigSz=rd32(b+o4+12); } o4+=csz; }
    CHECK(sigOff != 0 && sigSz != 0, "LC_CODE_SIGNATURE present");
    CHECK(macho.length >= sigOff + sigSz, "signature area within file");
    // SuperBlob magic 0xfade0cc0, CodeDirectory magic 0xfade0c02 (big-endian)
    #define RD32BE(p) (((uint32_t)(p)[0]<<24)|((p)[1]<<16)|((p)[2]<<8)|(p)[3])
    CHECK(RD32BE(b+sigOff) == 0xfade0cc0u, "embedded-signature SuperBlob magic");
    CHECK(RD32BE(b+sigOff+20) == 0xfade0c02u, "CodeDirectory magic");
    CHECK(RD32BE(b+sigOff+20+12) == 0x2u, "CodeDirectory flags = adhoc");
    #undef RD32BE

    // ── MH_DYLIB path: a shared library exporting two functions + __XTC iface ──
    XAArm64Assembler *as5 = [[XAArm64Assembler alloc] init];
    NSData *t5 = [as5 assemble:@".globl _lib_answer\n_lib_answer:\nmovz w0,#42\nret\n"
                                "\n.globl _lib_add\n_lib_add:\nadd w0,w0,w1\nret\n" error:&e];
    CHECK(t5 != nil, "dylib: assembled library body");
    NSData *iface5 = [@"{\"module\":\"Demo\"}" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *dy = [XTMachOWriter dylibFromText:t5 installName:@"@rpath/libDemo.dylib"
                    exports:[NSSet setWithArray:@[@"_lib_answer",@"_lib_add"]]
                    iface:iface5 symbols:as5.symbols data:as5.data dataSymbols:as5.dataSymbols
                   fixups:as5.fixups modInitLength:0 objcSections:@[]];
    CHECK(dy != nil && dy.length >= 0x4000, "dylib: emitted (>= one page)");
    const uint8_t *b5 = dy.bytes;
    CHECK(rd32(b5+12) == 6, "dylib: filetype MH_DYLIB");
    uint32_t nc5 = rd32(b5+16); uint64_t o5=32;
    BOOL sawId=NO, sawXtc=NO, sawPagezero=NO; uint32_t exportSize=0;
    for (uint32_t i=0;i<nc5;i++){ uint32_t cmd=rd32(b5+o5), csz=rd32(b5+o5+4);
        if (cmd==0xd) sawId=YES;                                   // LC_ID_DYLIB
        else if (cmd==0x19){ const char *sn=(const char*)(b5+o5+8);
            if (strcmp(sn,"__XTC")==0) sawXtc=YES;
            if (strcmp(sn,"__PAGEZERO")==0) sawPagezero=YES; }
        else if (cmd==(0x22|0x80000000u)) exportSize=rd32(b5+o5+40); // LC_DYLD_INFO export_size
        o5+=csz; }
    CHECK(o5 == 32 + rd32(b5+20), "dylib: load commands span sizeofcmds");
    CHECK(sawId, "dylib: LC_ID_DYLIB present");
    CHECK(sawXtc, "dylib: __XTC segment present");
    CHECK(!sawPagezero, "dylib: no __PAGEZERO (loads at base 0)");
    CHECK(exportSize > 0, "dylib: export trie non-empty");

    // ── multi-dylib client: an exec that binds an import against a named dylib ──
    XAArm64Assembler *as6 = [[XAArm64Assembler alloc] init];
    NSData *t6 = [as6 assemble:@"_main:\nmovz w0,#14\nbl _Mathx$triple\nret\n" error:&e];
    CHECK(t6 != nil, "client: assembled a call to an external dylib symbol");
    NSArray *dylibs = @[@{@"install": @"@rpath/libMathx.dylib",
                         @"symbols": [NSSet setWithObject:@"_Mathx$triple"]}];
    NSData *m6 = [XTMachOWriter executableFromText:t6
                    entryOffset:as6.symbols[@"_main"].unsignedLongLongValue
                        symbols:as6.symbols data:as6.data dataSymbols:as6.dataSymbols
                        fixups:as6.fixups dylibs:dylibs rpaths:@[@"@loader_path"]
                 modInitLength:0 objcSections:@[]];
    const uint8_t *b6 = m6.bytes; uint32_t nc6 = rd32(b6+16); uint64_t o6=32;
    BOOL sawMathxLib=NO, sawRpath=NO; int loadDylibs=0;
    for (uint32_t i=0;i<nc6;i++){ uint32_t cmd=rd32(b6+o6), csz=rd32(b6+o6+4);
        if (cmd==0xc) { loadDylibs++; const char *nm=(const char*)(b6+o6+rd32(b6+o6+8));
            if (strstr(nm,"libMathx")) sawMathxLib=YES; }
        else if (cmd==(0x1c|0x80000000u)) sawRpath=YES;
        o6+=csz; }
    CHECK(o6 == 32 + rd32(b6+20), "client: load commands span sizeofcmds");
    CHECK(sawMathxLib, "client: LC_LOAD_DYLIB for libMathx present");
    CHECK(loadDylibs == 2, "client: two LC_LOAD_DYLIB (libSystem + libMathx)");
    CHECK(sawRpath, "client: LC_RPATH present");
    // the undef _Mathx$triple must carry library ordinal 2 in its n_desc
    uint64_t o6b=32; uint32_t symoff6=0,nsy6=0,stroff6=0;
    for (uint32_t i=0;i<nc6;i++){ uint32_t cmd=rd32(b6+o6b),csz=rd32(b6+o6b+4);
        if (cmd==0x2){symoff6=rd32(b6+o6b+8);nsy6=rd32(b6+o6b+12);stroff6=rd32(b6+o6b+16);} o6b+=csz; }
    BOOL ord2=NO;
    for (uint32_t i=0;i<nsy6;i++){ const uint8_t *ent=b6+symoff6+i*16;
        const char *nm=(const char*)(b6+stroff6+rd32(ent));
        if (strcmp(nm,"_Mathx$triple")==0 && ent[7]==2) ord2=YES; }
    CHECK(ord2, "client: _Mathx$triple undef bound to library ordinal 2");

    // ── .tbd target triples, per platform (private:docs/bugs/028) ─────────────────
    //
    // A `.tbd` carries several platforms in one file and tags each symbols:
    // list with the targets it applies to. Reading the WRONG triples yields an
    // empty export set rather than a wrong one, and an empty set is silent:
    // every import then falls through to dylib ordinal 1 and dyld refuses at
    // launch, naming a library that never had the symbol. That shipped, and it
    // blocked every iOS app that used more than libSystem.
    //
    // Written out here rather than read from an SDK so the check runs anywhere.
    {
        NSString *tbd =
            @"--- !tapi-tbd\n"
            @"tbd-version: 4\n"
            @"targets: [ x86_64-ios-simulator, arm64-ios-simulator ]\n"
            @"install-name: '/usr/lib/libobjc.A.dylib'\n"
            @"exports:\n"
            @"  - targets: [ arm64-ios-simulator ]\n"
            @"    symbols: [ _objc_autoreleasePoolPop, _objc_msgSend ]\n";
        NSString *path = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"xtc-test-028.tbd"];
        [tbd writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];

        [XTMachOWriter setApplePlatform:@"ios-sim"];
        NSDictionary *sim = [XTMachOWriter inspectTbd:path];
        CHECK(sim != nil, "028: a simulator .tbd is read at all");
        CHECK(sim && [sim[@"symbols"] containsObject:@"_objc_autoreleasePoolPop"],
              "028: ios-sim reads arm64-ios-simulator exports");

        // The same file under macOS triples must yield NOTHING — that is the
        // bug's mechanism, and pinning it keeps the mapping honest rather than
        // accidentally permissive.
        [XTMachOWriter setApplePlatform:@"macos"];
        NSDictionary *mac = [XTMachOWriter inspectTbd:path];
        CHECK(mac && [(NSSet *)mac[@"symbols"] count] == 0,
              "028: macos triples collect nothing from a simulator .tbd");

        CHECK([[XTMachOWriter tbdTargets] containsObject:@"arm64-macos"],
              "028: macos maps to arm64-macos");
        [XTMachOWriter setApplePlatform:@"ios"];
        CHECK([[XTMachOWriter tbdTargets] containsObject:@"arm64-ios"],
              "028: ios maps to arm64-ios");
        [XTMachOWriter setApplePlatform:@"ios-sim"];
        CHECK([[XTMachOWriter tbdTargets] containsObject:@"arm64-ios-simulator"],
              "028: ios-sim maps to arm64-ios-simulator");
        [XTMachOWriter setApplePlatform:@"macos"];      // leave the default set
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    }

    fprintf(stderr, "  [Mach-O structural checks done]\n");
    return failures;
}
