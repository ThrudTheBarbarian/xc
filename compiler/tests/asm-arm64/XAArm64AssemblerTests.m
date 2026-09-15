/****************************************************************************\
|* XAArm64AssemblerTests.m
|*
|* Phase 1 of the self-hosted native toolchain (private:docs/Design/native-toolchain.md):
|* verifies XAArm64Assembler encodes the AArch64 integer/scalar subset emitted
|* by XTArm64Backend byte-for-byte identically to clang.
|*
|* These golden encodings were produced by `clang -c -target arm64-apple-macos11`
|* and cover every encoding family the assembler implements: mov/movz/movk,
|* add/sub (imm, shifted-reg, extended-reg, LSL#12), cmp/neg, logical reg + the
|* bitmask-immediate encoder, bitfield (uxt/sxt/lsl/lsr/asr imm + variable),
|* mul/madd/msub/umull/smull, div, cset/csel, loads/stores (unsigned-offset,
|* unscaled, pre/post-index, register-offset with extend), load/store pair,
|* ret and brk.
|*
|* The exhaustive check — every instruction our backend emits across the whole
|* fixture corpus (20,156 integer instructions, 0 mismatches) — lives in the
|* `make oracle-arm64` tool, which needs clang+otool at runtime and so is kept
|* out of `make test`.  This suite is the self-contained regression guard.
\****************************************************************************/

#import <Foundation/Foundation.h>
#import "XAArm64Assembler.h"

static const struct
    {
    const char* insn;
    uint32_t word;
    } kGolden[] = {
        {"mov x29, sp", 0x910003fdu},
        {"mov w19, w0", 0x2a0003f3u},
        {"mov x16, x20", 0xaa1403f0u},
        {"mov w10, #1", 0x5280002au},
        {"mov w17, #10", 0x52800151u},
        {"movz w17, #52429", 0x529999b1u},
        {"movk w17, #52428, lsl #16", 0x72b99991u},
        {"add w19, w10, #48", 0x1100c153u},
        {"add x16, sp, #16", 0x910043f0u},
        {"add sp, sp, #352", 0x910583ffu},
        {"sub sp, sp, #352", 0xd10583ffu},
        {"subs w17, w17, #1", 0x71000631u},
        {"cmp w19, #10", 0x71002a7fu},
        {"cmp x0, #0x10000", 0xf140401fu},
        {"add w2, w3, w4", 0x0b040062u},
        {"sub x5, x6, x7", 0xcb0700c5u},
        {"sub sp, sp, x9", 0xcb2963ffu},
        {"add x11, x25, w11, uxtw", 0x8b2b432bu},
        {"add w10, w15, w15, lsr #31", 0x0b4f7deau},
        {"and w0, w1, w2", 0x0a020020u},
        {"orr x3, x4, x5", 0xaa050083u},
        {"eor w6, w7, w8", 0x4a0800e6u},
        {"and w16, w27, #0xFFFF", 0x12003f70u},
        {"mvn w9, w10", 0x2a2a03e9u},
        {"neg w25, w10", 0x4b0a03f9u},
        {"uxtb w10, w10", 0x53001d4au},
        {"uxth w11, w10", 0x53003d4bu},
        {"sxtb x17, w16", 0x93401e11u},
        {"sxth x17, w16", 0x93403e11u},
        {"sxtw x3, w4", 0x93407c83u},
        {"lsl w5, w6, #3", 0x531d70c5u},
        {"lsr x7, x8, #32", 0xd360fd07u},
        {"asr w9, w10, #5", 0x13057d49u},
        {"lsr w11, w12, w13", 0x1acd258bu},
        {"mul w0, w1, w2", 0x1b027c20u},
        {"umull x15, w19, w17", 0x9bb17e6fu},
        {"smull x3, w4, w5", 0x9b257c83u},
        {"msub w10, w15, w17, w19", 0x1b11cdeau},
        {"madd x1, x2, x3, x4", 0x9b031041u},
        {"sdiv w0, w1, w2", 0x1ac20c20u},
        {"udiv x3, x4, x5", 0x9ac50883u},
        {"cset w0, eq", 0x1a9f17e0u},
        {"csel w1, w2, w3, ne", 0x1a831041u},
        {"str w17, [sp, #72]", 0xb9004bf1u},
        {"ldr x16, [sp, #320]", 0xf940a3f0u},
        {"ldrb w10, [x16]", 0x3940020au},
        {"strb wzr, [x16]", 0x3900021fu},
        {"sturh w17, [x0, #-2]", 0x781fe011u},
        // The 32-bit forms the ARC sequence uses since the refcount was widened
        // (task #46): the count lives at obj-4 now, and retain/release load, store
        // and atomically update it as a WORD. Pinned here because a back end that
        // emits an instruction the assembler cannot encode fails at the assembler,
        // a long way from the change that caused it.
        {"ldur w17, [x16, #-4]", 0xb85fc211u},
        {"stur w17, [x0, #-4]", 0xb81fc011u},
        {"ldaddl w17, wzr, [x16]", 0xb871021fu},
        {"ldaxr w17, [x16]", 0x885ffe11u},
        {"stlxr w15, w17, [x16]", 0x880ffe11u},
        {"ldurh w17, [x16, #-2]", 0x785fe211u},
        {"strb w13, [x21, w11, uxtw #0]", 0x382b5aadu},
        {"strh w11, [x19, w12, uxtw #1]", 0x782c5a6bu},
        {"ldrsh w3, [x4, #6]", 0x79c00c83u},
        {"stp x29, x30, [sp, #-352]!", 0xa9aa7bfdu},
        {"ldp x29, x30, [sp], #352", 0xa8d67bfdu},
        {"stp x19, x20, [sp, #320]", 0xa91453f3u},
        {"ldp x29, x30, [sp]", 0xa9407bfdu},
        {"ret", 0xd65f03c0u},
        {"brk #1", 0xd4200020u},
        // ── scalar floating-point ──
        {"ldr s0, [sp, #72]", 0xbd404be0u},
        {"str s0, [sp, #72]", 0xbd004be0u},
        {"ldr d0, [sp, #320]", 0xfd40a3e0u},
        {"str d0, [sp, #320]", 0xfd00a3e0u},
        {"str s8, [x16]", 0xbd000208u},
        {"str d13, [x16]", 0xfd00020du},
        {"fmov s0, s13", 0x1e2041a0u},
        {"fmov d0, d8", 0x1e604100u},
        {"fmov s10, w16", 0x1e27020au},
        {"fmov d13, x16", 0x9e67020du},
        {"fmov w0, s5", 0x1e2600a0u},
        {"fmov x3, d7", 0x9e6600e3u},
        {"fadd s0, s0, s1", 0x1e212800u},
        {"fadd d0, d0, d1", 0x1e612800u},
        {"fsub s0, s0, s1", 0x1e213800u},
        {"fsub d8, d8, d9", 0x1e693908u},
        {"fmul s0, s0, s1", 0x1e210800u},
        {"fdiv d0, d0, d1", 0x1e611800u},
        {"fneg s0, s0", 0x1e214000u},
        {"fneg d0, d0", 0x1e614000u},
        {"fsqrt s8, s8", 0x1e21c108u},
        {"fsqrt d0, d0", 0x1e61c000u},
        {"fcmp s0, s1", 0x1e212000u},
        {"fcmp d0, d1", 0x1e612000u},
        {"fcvt d1, s0", 0x1e22c001u},
        {"fcvt s1, d0", 0x1e624001u},
        {"scvtf s0, w10", 0x1e220140u},
        {"scvtf d0, w16", 0x1e620200u},
        {"ucvtf s8, w24", 0x1e230308u},
        {"ucvtf d0, w11", 0x1e630160u},
        {"fcvtzs x16, d0", 0x9e780010u},
        {"fcvtzs x16, s0", 0x9e380010u},
        {"fcvtzu x16, s0", 0x9e390010u},
        {"fmadd s0, s0, s1, s2", 0x1f010800u},
        {"fmadd d0, d0, d1, d2", 0x1f410800u},
        {"fnmsub s0, s0, s1, s2", 0x1f218800u},
        // ── atomics and barriers (private:docs/Design/threading.md) ──
        // The refcount pair the backend emits under -fthread-safe-arc, plus the
        // acquire/release and CAS forms the C runtime's atomics compile to. The
        // suffix carries width AND ordering, so the split is tested both ways
        // round: ldaddlh (release, halfword) vs ldaddalh (acquire-release).
        {"ldaddlh w17, wzr, [x16]", 0x7871021fu},
        {"ldaddalh w17, w17, [x16]", 0x78f10211u},
        {"ldadd w1, w8, [x0]", 0xb8210008u},
        {"ldaddal w1, w8, [x0]", 0xb8e10008u},
        {"ldaddb w1, w8, [x0]", 0x38210008u},
        {"ldclral w1, w8, [x0]", 0xb8e11008u},
        {"ldsetal w1, w8, [x0]", 0xb8e13008u},
        {"swpal w1, w0, [x0]", 0xb8e18000u},
        {"cas w8, w2, [x0]", 0x88a87c02u},
        {"casal w8, w2, [x0]", 0x88e8fc02u},
        {"casal x8, x2, [x0]", 0xc8e8fc02u},
        {"casalh w8, w2, [x0]", 0x48e8fc02u},
        {"ldar w0, [x0]", 0x88dffc00u},
        {"ldar x0, [x1]", 0xc8dffc20u},
        {"ldarb w2, [x3]", 0x08dffc62u},
        {"stlr w1, [x0]", 0x889ffc01u},
        {"stlrh w5, [x6]", 0x489ffcc5u},
        {"dmb ish", 0xd5033bbfu},
        {"dmb ishst", 0xd5033abfu},
        {"isb", 0xd5033fdfu},
        // N-bit logical forms, with and without a shifted second operand — the
        // runtime's signed-max idiom emits the shifted one.
        {"bic w8, w19, w19, asr #31", 0x0ab37e68u},
        {"bic x8, x19, x20", 0x8a340268u},
        {"orn w1, w2, w3", 0x2a230041u},
        {"eon w1, w2, w3, lsr #7", 0x4a631c41u},
        // Load/store EXCLUSIVE + tst + clrex. Android's armv8-a baseline has no
        // LSE, so an atomic read-modify-write in the runtime IS an ldaxr/stlxr
        // pair — the `cas*` forms above are never reached there. Goldens from the
        // NDK's aarch64-linux-android clang; the ISA is the same one, so a Darwin
        // clang produces these bytes too.
        {"tst w0, #0xff", 0x72001c1fu},
        {"tst x1, #0xffffffff", 0xf2407c3fu},
        {"tst w2, w3", 0x6a03005fu},
        {"tst x4, x5", 0xea05009fu},
        {"ldxr w8, [x9]", 0x885f7d28u},
        {"ldaxr w8, [x9]", 0x885ffd28u},
        {"ldaxr x10, [x11]", 0xc85ffd6au},
        {"ldaxrb w12, [x13]", 0x085ffdacu},
        {"ldaxrh w14, [x15]", 0x485ffdeeu},
        {"stxr w10, w11, [x9]", 0x880a7d2bu},
        {"stlxr w10, w11, [x9]", 0x880afd2bu},
        {"stlxr w1, x2, [x3]", 0xc801fc62u},
        {"stlxrb w4, w5, [x6]", 0x0804fcc5u},
        {"stlxrh w7, w8, [x9]", 0x4807fd28u},
        {"clrex", 0xd5033f5fu},
    };

// The GNU/ELF dialect the NDK-generated Android runtime arrives in, and the
// Mach-O spelling the assembler parses. Two properties matter and only one is
// obvious: the rewrite must be right, and it must be IDEMPOTENT — the same
// pass runs over a file that also contains the compiler's own Mach-O-flavoured
// asm, and a second rewrite of `sym@PAGE` would corrupt it.
static const struct
    {
    const char* elf;
    const char* macho;
    } kDialect[] = {
        {"\tadrp\tx1, .L.str", "\tadrp\tx1, .L.str@PAGE"},
        {"\tadd\tx1, x1, :lo12:.L.str", "\tadd\tx1, x1, .L.str@PAGEOFF"},
        {"\tadrp\tx8, :got:stderr", "\tadrp\tx8, stderr@GOTPAGE"},
        {"\tldr\tx8, [x8, :got_lo12:stderr]", "\tldr\tx8, [x8, stderr@GOTPAGEOFF]"},
        {"\tldr\tx0, [x1, :lo12:_xtc_v]", "\tldr\tx0, [x1, _xtc_v@PAGEOFF]"},
        // already Mach-O — must pass through untouched
        {"\tadrp\tx1, _foo@PAGE", "\tadrp\tx1, _foo@PAGE"},
        {"\tadd\tx1, x1, _foo@PAGEOFF", "\tadd\tx1, x1, _foo@PAGEOFF"},
        {"\tbl\t_bar", "\tbl\t_bar"},
    };

int runArm64AssemblerTests(void);
int runArm64AssemblerTests(void)
    {
    int failures = 0;
    XAArm64Assembler* as = [[XAArm64Assembler alloc] init];
    NSUInteger n = sizeof(kGolden) / sizeof(kGolden[0]);
    for (NSUInteger i = 0; i < n; i++)
        {
        NSString* insn = @(kGolden[i].insn);
        NSError* err = nil;
        uint32_t got = [as encodeLine:insn pc:0 resolve:nil error:&err];
        if (err)
            {
            fprintf(stderr, "  FAIL: %-38s error: %s\n", kGolden[i].insn,
                    err.localizedDescription.UTF8String);
            failures++;
            }
        else if (got != kGolden[i].word)
            {
            fprintf(stderr, "  FAIL: %-38s ours=%08x clang=%08x\n",
                    kGolden[i].insn, got, kGolden[i].word);
            failures++;
            }
        else
            {
            fprintf(stderr, "  PASS: %-38s %08x\n", kGolden[i].insn, got);
            }
        }
    fprintf(stderr, "  [%lu/%lu golden encodings matched]\n",
            (unsigned long)(n - failures), (unsigned long)n);

    NSUInteger dn = sizeof(kDialect) / sizeof(kDialect[0]);
    for (NSUInteger i = 0; i < dn; i++)
        {
        NSString* want = @(kDialect[i].macho);
        NSString* got = [XAArm64Assembler machoDialectFromElf:@(kDialect[i].elf)];
        // Run it TWICE: the pass must be a fixed point, or a mixed-dialect file
        // gets a second, wrong rewrite of the parts already converted.
        NSString* twice = [XAArm64Assembler machoDialectFromElf:got];
        if (![got isEqualToString:want])
            {
            fprintf(stderr, "  FAIL: dialect %-34s got '%s' want '%s'\n",
                    kDialect[i].elf, got.UTF8String, want.UTF8String);
            failures++;
            }
        else if (![twice isEqualToString:want])
            {
            fprintf(stderr, "  FAIL: dialect %-34s not idempotent: '%s'\n",
                    kDialect[i].elf, twice.UTF8String);
            failures++;
            }
        else
            {
            fprintf(stderr, "  PASS: dialect %-34s -> %s\n",
                    kDialect[i].elf, got.UTF8String);
            }
        }
    return failures;
    }
