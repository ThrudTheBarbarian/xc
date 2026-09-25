/*
 * sim6502 — 6502 simulator for xtc compiler output
 *
 * Usage: sim6502 [options] <file.xex> [mapfile.map]
 *   -tty   Plain text output (default)
 *   -g0    Dump 40x24 screen memory after execution
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <signal.h>
#include <ctype.h>
#include <math.h>

#ifndef XTC_VERSION
#define XTC_VERSION "0.0"
#endif

/* Forward declarations for CPU registers used by mem_read/mem_write. */
static uint8_t reg_a, reg_x, reg_y;
static uint16_t reg_sp;
static uint16_t reg_pc;

/* ── Memory ────────────────────────────────────────────────────────── */

#define MEM_SIZE 0x10000
/* Bank id is 8-bit ($82 for code, $83 for data). With 3-byte uniform
   pointers, $84 is not used (bank-hi eliminated). The simulator only
   ever needs 256 pages for testing. */
#define BANK_PAGES 256
#define BANK_SIZE 0x4000 /* 16KB per bank page, mapped at $4000-$7FFF */

/* xt's split-bank routing has two independent 8 KB windows:
   $4000-$5FFF routed through $82 as a code-bank selector, and
   $6000-$7FFF routed through $83 as a data-bank selector. Pages
   are 8 KB each. Arrays kept separate from the legacy 16 KB
   `bank[]` so the xt-collapsed / xe routing stays bit-identical
   for the negative-control harness and for xe. */
#define SPLIT_BANK_SIZE 0x2000

/* xt-extended (PR3 of doc/xt-extended-ram.md): a third 4 KB window
   at $7000-$7FFF (carved off the data half) selected by a 16-bit
   page index in the $84/$85 ZP pair. Region C of xt-extended.
   1024 pages × 4 KB = 4 MB — enough to validate the > 256-page
   boundary path that PR6's xt_extended_16bit_select fixture
   exercises. PR4b's stress fixtures may bump further if needed
   (the 16-bit selector tops out at 65536 pages = 256 MB). */
#define EXT_PAGES 1024
#define EXT_BANK_SIZE 0x1000
#define EXT_DATA_SIZE 0x1000 /* shrunken data half ($6000-$6FFF) */

static uint8_t mem[MEM_SIZE];
static uint8_t bank[BANK_PAGES][BANK_SIZE];
static uint8_t code_bank[BANK_PAGES][SPLIT_BANK_SIZE];
static uint8_t data_bank[BANK_PAGES][SPLIT_BANK_SIZE];
static uint8_t ext_bank[EXT_PAGES][EXT_BANK_SIZE];

/* xt data-bank window: the
   $83 8-bit ZP byte selects a 12 KB page at $A000-$CFFF. Selector 0
   keeps the window as plain main RAM (where the generated unbanked
   code+data lives, and where .xex segments load at boot, $83 = 0);
   selector >= 1 is an on-demand heap data page. 256 pages × 12 KB = 3 MB,
   ample for the corpus. With 3-byte uniform pointers, $84 is not used
   for the data-bank selector (bank-hi eliminated). */
#define XT_DATA_PAGES 256
#define XT_DATA_SIZE 0x3000
static uint8_t xt_data_bank[XT_DATA_PAGES][XT_DATA_SIZE];
static int banked_mode = 0;

/* Hardware ZP banking (xt models only). Writes to $82 atomically
   swap three 16-byte ZP regions ($A0-$AF, $C0-$CF, $D0-$DF) along
   with the code window — each 8 KB code bank gets 48 bytes of
   private ZP that travel with it. The simulator models this by
   shadowing each bank's last-seen ZP contents in zp_shadow[][]
   and rotating the live ZP bytes on every $82 write.

   Layout of zp_shadow[bank]:
     [ 0..15]  shadow of $A0-$AF
     [16..31]  shadow of $C0-$CF
     [32..47]  shadow of $D0-$DF

   GATED behind the `-z` CLI flag (zp_banking_enabled) until the
   codegen migrates globals out of $C0-$DF. Today's xt codegen
   places cross-bank-shared globals in the $C0-$FF range (block-2
   vars); enabling hardware ZP banking unconditionally would
   partition those globals per-bank and break programs that
   expect them to be shared. The path-A4 commit will flip the
   default once A2/A3 have moved globals to $8F-$9F / $E0-$FF. */
#define ZP_BANKED_SLICE_BYTES 48
static uint8_t zp_shadow[BANK_PAGES][ZP_BANKED_SLICE_BYTES];
static int zp_banking_enabled = 0; /* set by -z CLI flag */

/* Whether ZP banking applies under the current bank_mode AND has
   been enabled by the user. xt / xt-split / xt-extended are the
   only modes that support it; xe / none always say no. */
static int zp_banking_active(void);

/* Save the currently-live ZP regions to zp_shadow[bank], and load
   zp_shadow[new_bank] back into the live ZP regions. Called from
   mem_write when $82 changes. No-op when old == new. */
static void zp_bank_swap(uint8_t old_bank, uint8_t new_bank);

/* Bank-swap strategy.
     `xt` (BANK_XT): one 16 KB code-bank window at $6000-$9FFF selected
       by the 8-bit code selector ($D5C0, 4 MB code space), routed
       through bank[] (16 KB pages). Screen RAM at $4000-$5FFF; the
       $A000-$CFFF data window is the banked heap via the data selector
       ($D5C1). The earlier three-window split-bank xt has been retired.
     `xe` reads PORTB ($D301) — if bit 4 is set, the bank window
       maps to main RAM (no banking); otherwise the `xe_mask` bits
       are compressed to form the bank index. */
typedef enum
{
    BANK_NONE = 0,
    BANK_XT,
    BANK_XE
} bank_mode_t;
static bank_mode_t bank_mode = BANK_NONE;
/* Set when -m specifies a memory model (including `xl`). When non-zero
   the load_xex auto-detect step skips its $4000-$7FFF banking flip —
   xl-shadow stages shadow-region payload through the heap range
   ($5000-$9FFF) and the auto-flip would mistake the staging segment
   for legacy banked data and route reads through bank[]. */
static int bank_mode_explicit = 0;
static uint8_t xe_mask = 0;

/* Bank-register addresses. Default to the standard Atari XL/XE
   layout ($82 = code, $83 = data, $84/$85 = region C 16-bit pair,
   $D301 = xe PORTB). Layouts can move them anywhere reachable by
   `STA <addr>` (zero-page or absolute) — see [banking] codeReg,
   dataReg, regCReg in support/xt6502/layouts. The simulator
   reads these addresses to compute the live bank id and watches
   writes to them so it can swap the bank window in step with the
   running program. Override via `--code-reg` / `--data-reg` /
   `--regc-reg` (CLI) or via the auto-detect pass that scans the
   XEX preload stubs at load time (see scan_xex_for_bank_regs). */
static uint16_t code_reg_addr = 0x82;
static uint16_t data_reg_addr = 0x83;
static uint16_t regc_reg_lo_addr = 0x84;
static uint16_t regc_reg_hi_addr = 0x85;
static int bank_reg_addrs_explicit = 0; /* set by CLI override */

#define PORTB_ADDR 0xD301
#define PORTB_BANK_OFF 0x10 /* bit 4 set → main RAM mapped */

/* Shadow ROM support. When rom_loaded is true, reads from the ROM
   range ($D800-$FFFF) return rom[] bytes when the shadow-mask bit
   in PORTB is SET (OS ROM enabled). Clearing the bit banks out ROM
   and exposes shadow RAM underneath. Writes always go to mem[]. */
#define ROM_BASE 0xD800
#define ROM_SIZE 0x2800 /* 10KB: $D800-$FFFF */
static uint8_t rom[ROM_SIZE];
static int rom_loaded = 0;
static uint8_t shadow_mask = 0; /* which PORTB bit(s) control ROM */

/* NMI support for shadow-mode testing. When nmi_interval > 0,
   the simulator fires an NMI every N instructions by pushing
   PC and P onto the stack and vectoring through $FFFA/$FFFB. */
static uint64_t nmi_interval = 0;
static uint64_t nmi_counter = 0;

/* Compress the PORTB value through `xe_mask`, returning the bank
   index. Only the bits named by the mask participate; they are
   packed low-to-high in the result. */
static uint16_t xe_bank_from_portb(uint8_t portb)
    {
    uint16_t idx = 0;
    uint16_t outBit = 1;
    for (int i = 0; i < 8; i++)
        {
        if (xe_mask & (1u << i))
            {
            if (portb & (1u << i))
                idx |= outBit;
            outBit <<= 1;
            }
        }
    return idx;
    }

/* Current bank id. Returns -1 (cast through uint16_t = 0xFFFF) if
   the bank window is mapped to main RAM instead (xe, bit 4 set).
   Used by the xe ($4000-$7FFF) routing; xt routes its $6000-$9FFF /
   $A000-$CFFF windows through code_reg_addr / data_reg_addr directly
   in mem_read / mem_write. */
#define BANK_MAIN_RAM 0xFFFFu
static uint16_t current_bank(void)
    {
    if (bank_mode == BANK_XE)
        {
        uint8_t pb = mem[PORTB_ADDR];
        if (pb & PORTB_BANK_OFF)
            return BANK_MAIN_RAM;
        return xe_bank_from_portb(pb);
        }
    return (uint16_t)(mem[code_reg_addr] | ((uint16_t)mem[data_reg_addr] << 8));
    }

static int zp_banking_active(void)
    {
    if (!banked_mode || !zp_banking_enabled)
        return 0;
    return bank_mode == BANK_XT;
    }

static void zp_bank_swap(uint8_t old_bank, uint8_t new_bank)
    {
    if (old_bank == new_bank)
        return;
    /* Snapshot outgoing bank's ZP into shadow. */
    memcpy(&zp_shadow[old_bank][0], &mem[0xA0], 16);
    memcpy(&zp_shadow[old_bank][16], &mem[0xC0], 16);
    memcpy(&zp_shadow[old_bank][32], &mem[0xD0], 16);
    /* Restore incoming bank's ZP from shadow. */
    memcpy(&mem[0xA0], &zp_shadow[new_bank][0], 16);
    memcpy(&mem[0xC0], &zp_shadow[new_bank][16], 16);
    memcpy(&mem[0xD0], &zp_shadow[new_bank][32], 16);
    }

/* Is OS ROM currently enabled? True when the shadow-mask bit(s)
   in PORTB are all SET. */
static int rom_enabled(void)
    {
    if (!rom_loaded || !shadow_mask)
        return 0;
    return (mem[PORTB_ADDR] & shadow_mask) == shadow_mask;
    }

/* True while a .xex image is being loaded (segments streamed + INITAD
   preload stubs executed). Declared here so the bank-unlock gate below
   can see it. */
static int loading = 0;

/* XT register-unlock master switch, modelling the hardware's register-unlock
   design. The $D5C0/$D5C1 bank selectors
   are gated by the BANK group (bit 3) of the unlock register at $D1DF,
   which resets to 0 (locked = bone-stock Atari). A native 6502 program
   must write $D1DF to unlock banking before $D5C0/$D5C1 take effect (the
   xtc xt6502 startup does this first thing). The register lives in
   mem[$D1DF] — a plain native read/write port. */
#define XT_UNLOCK_ADDR 0xD1DF
#define XT_UNLK_BANK 0x08 /* bit 3 — $D5C0/$D5C1 code/data bank select */

/* The $D5C0/$D5C1 bank windows are live when the image loader is streaming
   (the A9/bridge load path is always live on real hardware, independent of
   the lock) or once the 6502 has unlocked the BANK group via $D1DF. When
   locked at runtime the windows decode as plain main RAM, exactly as a
   stock Atari would, so a program that forgets to unlock misbehaves the
   same way it would on hardware. */
static inline int xt_bank_on(void)
    {
    return loading || (mem[XT_UNLOCK_ADDR] & XT_UNLK_BANK);
    }

/* ==========================================================================
 * MECH math-coprocessor mailbox model
 *
 * Faithful port of the A9 worker in the XTOS loader's
 *   test/freertos/mathcop.{c,h}
 * plus the $D5C6-$D5C8 register / page-overlay semantics of the hardware's
 *   math_cop.sv
 * so a MECH program runs identically here and on the board. The 6502 maps an
 * 8 KB "math page" over $4000-$5FFF ($D5C6.0=1), fills the slot file + an op
 * program, and strobes $D5C7 (EXEC). Real hardware round-trips to the A9; here
 * EXEC runs the op stream synchronously on the host FPU/libm (the A9 VFP's
 * stand-in) and latches $D5C7.0 (done). The DDR chunk / cache-maintenance /
 * demand-load machinery on the real worker is pure transport — the observable
 * slot results are identical, so this model works the page in place. Quiescence
 * between EXEC and the done poll is trivially satisfied by running synchronously.
 * ====================================================================== */
#define MC_PAGE_SIZE 8192
#define MC_OFF_OPCOUNT 0x0000 /* u16 */
#define MC_OFF_ABIVER 0x0002  /* u8  */
#define MC_OFF_STATUS 0x0003  /* u8  */
#define MC_OFF_SLOTS 0x0040   /* 256 x 8 B */
#define MC_NSLOTS 256
#define MC_OFF_OPS 0x0840 /* up to 1024 x 4 B */
#define MC_MAX_OPS 1024
#define MC_ABI_VERSION 2

/* status byte (A9 -> 6502) */
#define MC_ST_OK 0x01
#define MC_ST_DIV0 0x02
#define MC_ST_INVALID 0x04
#define MC_ST_BADOP 0x08
#define MC_ST_RANGE 0x10
#define MC_ST_NOPROG 0x20
#define MC_ST_PROGFULL 0x40

/* element types (op word byte0 [7:6]) */
#define MC_T_F32 0
#define MC_T_F64 1
#define MC_T_I32 2
#define MC_T_I64 3

/* scalar ops (op word byte0 [5:0]) */
#define MC_OP_NOP 0x00
#define MC_OP_ADD 0x01
#define MC_OP_SUB 0x02
#define MC_OP_MUL 0x03
#define MC_OP_DIV 0x04
#define MC_OP_NEG 0x05
#define MC_OP_ABS 0x06
#define MC_OP_SQRT 0x07
#define MC_OP_MIN 0x08
#define MC_OP_MAX 0x09
#define MC_OP_CMP 0x0A
#define MC_OP_REM 0x0B
#define MC_OP_SIN 0x10
#define MC_OP_COS 0x11
#define MC_OP_TAN 0x12
#define MC_OP_ASIN 0x13
#define MC_OP_ACOS 0x14
#define MC_OP_ATAN 0x15
#define MC_OP_ATAN2 0x16
#define MC_OP_EXP 0x17
#define MC_OP_LOG 0x18
#define MC_OP_LOG10 0x19
#define MC_OP_POW 0x1A
#define MC_OP_FLOOR 0x1B
#define MC_OP_CEIL 0x1C
#define MC_OP_ROUND 0x1D
#define MC_OP_TRUNC 0x1E
#define MC_OP_CVT 0x20
/* control ops (single word; id in bytes1-2, byte3 = CALL arg base) */
#define MC_OP_CTLBASE 0x21
#define MC_OP_CALL 0x21
#define MC_OP_DEF 0x22
#define MC_OP_END 0x23
#define MC_OP_UNDEF 0x24
#define MC_OP_CTLTOP 0x24
/* integer-only ops */
#define MC_OP_AND 0x28
#define MC_OP_OR 0x29
#define MC_OP_XOR 0x2A
#define MC_OP_NOT 0x2B
#define MC_OP_SHL 0x2C
#define MC_OP_SHR 0x2D
#define MC_OP_SAR 0x2E
/* vector ops (two-word) */
#define MC_OP_VECBASE 0x30
#define MC_OP_VADD 0x30
#define MC_OP_VSUB 0x31
#define MC_OP_VMUL 0x32
#define MC_OP_VDIV 0x33
#define MC_OP_VMIN 0x34
#define MC_OP_VMAX 0x35
#define MC_OP_VABS 0x36
#define MC_OP_VNEG 0x37
#define MC_OP_VSQRT 0x38
#define MC_OP_VMLA 0x39
#define MC_OP_VCOPY 0x3A
#define MC_OP_VDOT 0x3B
#define MC_OP_VSUM 0x3C
#define MC_OP_VCVT 0x3D
#define MC_OP_VECTOP 0x3D
#define MC_CALL_DEPTH_MAX 8

/* 6502-side registers */
#define MC_REG_CTL 0xD5C6   /* bit0 = map the math page over $4000 */
#define MC_REG_EXEC 0xD5C7  /* W: doorbell; R: {ready<<2, busy<<1, done} */
#define MC_REG_CHUNK 0xD5C8 /* backing chunk index */

static uint8_t mc_page[MC_PAGE_SIZE];
static int mc_mapped = 0;    /* $D5C6.0 — page overlaid on $4000-$5FFF */
static int mc_done = 0;      /* $D5C7.0 — last program finished        */
static int mc_ready = 0;     /* $D5C7.2 — a chunk is selected          */
static uint8_t mc_chunk = 0; /* $D5C8                                   */

    typedef union {
    float f;
    double d;
    int32_t i;
    int64_t l;
    uint64_t u;
    } mc_val;

static int mc_esize(uint8_t t)
    {
    return (t == MC_T_F32 || t == MC_T_I32) ? 4 : 8;
    }

/* slot access: `off` is a byte offset into the slot region (0..MC_NSLOTS*8) */
static mc_val mc_load(int off, int esize)
    {
    mc_val v;
    v.u = 0;
    memcpy(&v, mc_page + MC_OFF_SLOTS + off, (size_t)esize);
    return v;
    }
static void mc_store(int off, int esize, mc_val v)
    {
    memcpy(mc_page + MC_OFF_SLOTS + off, &v, (size_t)esize);
    }
static int mc_elem_off(int base_slot, int i, int stride, int esize, uint8_t* st)
    {
    int off = base_slot * 8 + i * stride * esize;
    if (off < 0 || off + esize > MC_NSLOTS * 8)
        {
        *st |= MC_ST_RANGE;
        return -1;
        }
    return off;
    }

static double mc_as_double(mc_val v, uint8_t t)
    {
    return t == MC_T_F32 ? (double)v.f : t == MC_T_F64 ? v.d
                                     : t == MC_T_I32   ? (double)v.i
                                                       : (double)v.l;
    }
static int64_t mc_as_int64(mc_val v, uint8_t t)
    {
    return t == MC_T_F32 ? (int64_t)v.f : t == MC_T_F64 ? (int64_t)v.d
                                      : t == MC_T_I32   ? (int64_t)v.i
                                                        : v.l;
    }

static mc_val mc_convert(uint8_t dst_t, uint8_t src_t, mc_val v)
    {
    mc_val r;
    r.u = 0;
    switch (dst_t)
        {
    case MC_T_F32:
        r.f = (float)mc_as_double(v, src_t);
        break;
    case MC_T_F64:
        r.d = mc_as_double(v, src_t);
        break;
    case MC_T_I32:
        r.i = (int32_t)mc_as_int64(v, src_t);
        break;
    default:
        r.l = mc_as_int64(v, src_t);
        break;
        }
    return r;
    }

/* dst = op(a,b) in the given element type; flags accumulate into *st */
static mc_val mc_scalar(uint8_t op, uint8_t type, mc_val a, mc_val b, uint8_t* st)
    {
    mc_val r;
    r.u = 0;
    int isf = (type == MC_T_F32 || type == MC_T_F64);
    if (isf)
        {
        double x = (type == MC_T_F32) ? (double)a.f : a.d;
        double y = (type == MC_T_F32) ? (double)b.f : b.d;
        double z;
        switch (op)
            {
        case MC_OP_NOP:
            z = x;
            break;
        case MC_OP_ADD:
            z = x + y;
            break;
        case MC_OP_SUB:
            z = x - y;
            break;
        case MC_OP_MUL:
            z = x * y;
            break;
        case MC_OP_DIV:
            if (y == 0.0)
                *st |= MC_ST_DIV0;
            z = x / y;
            break;
        case MC_OP_NEG:
            z = -x;
            break;
        case MC_OP_ABS:
            z = fabs(x);
            break;
        case MC_OP_SQRT:
            z = sqrt(x);
            break;
        case MC_OP_MIN:
            z = (x < y) ? x : y;
            break;
        case MC_OP_MAX:
            z = (x > y) ? x : y;
            break;
        case MC_OP_CMP:
            r.i = (x < y) ? -1 : (x > y) ? 1
                                         : 0;
            return r;
        case MC_OP_REM:
            if (y == 0.0)
                *st |= MC_ST_DIV0;
            z = fmod(x, y);
            break;
        case MC_OP_SIN:
            z = sin(x);
            break;
        case MC_OP_COS:
            z = cos(x);
            break;
        case MC_OP_TAN:
            z = tan(x);
            break;
        case MC_OP_ASIN:
            z = asin(x);
            break;
        case MC_OP_ACOS:
            z = acos(x);
            break;
        case MC_OP_ATAN:
            z = atan(x);
            break;
        case MC_OP_ATAN2:
            z = atan2(x, y);
            break;
        case MC_OP_EXP:
            z = exp(x);
            break;
        case MC_OP_LOG:
            z = log(x);
            break;
        case MC_OP_LOG10:
            z = log10(x);
            break;
        case MC_OP_POW:
            z = pow(x, y);
            break;
        case MC_OP_FLOOR:
            z = floor(x);
            break;
        case MC_OP_CEIL:
            z = ceil(x);
            break;
        case MC_OP_ROUND:
            z = round(x);
            break;
        case MC_OP_TRUNC:
            z = trunc(x);
            break;
        default:
            *st |= MC_ST_BADOP;
            z = 0.0;
            break;
            }
        if (isnan(z) || isinf(z))
            *st |= MC_ST_INVALID;
        if (type == MC_T_F32)
            r.f = (float)z;
        else
            r.d = z;
        return r;
        }
        {
        int64_t x = (type == MC_T_I32) ? (int64_t)a.i : a.l;
        int64_t y = (type == MC_T_I32) ? (int64_t)b.i : b.l;
        int64_t z;
        switch (op)
            {
        case MC_OP_NOP:
            z = x;
            break;
        case MC_OP_ADD:
            z = x + y;
            break;
        case MC_OP_SUB:
            z = x - y;
            break;
        case MC_OP_MUL:
            z = x * y;
            break;
        case MC_OP_DIV:
            if (y == 0)
                {
                *st |= MC_ST_DIV0;
                z = 0;
                }
            else
                z = x / y;
            break;
        case MC_OP_NEG:
            z = -x;
            break;
        case MC_OP_ABS:
            z = (x < 0) ? -x : x;
            break;
        case MC_OP_MIN:
            z = (x < y) ? x : y;
            break;
        case MC_OP_MAX:
            z = (x > y) ? x : y;
            break;
        case MC_OP_CMP:
            r.i = (x < y) ? -1 : (x > y) ? 1
                                         : 0;
            return r;
        case MC_OP_REM:
            if (y == 0)
                {
                *st |= MC_ST_DIV0;
                z = 0;
                }
            else
                z = x % y;
            break;
        case MC_OP_AND:
            z = x & y;
            break;
        case MC_OP_OR:
            z = x | y;
            break;
        case MC_OP_XOR:
            z = x ^ y;
            break;
        case MC_OP_NOT:
            z = ~x;
            break;
        case MC_OP_SHL:
            z = x << (y & 63);
            break;
        case MC_OP_SHR:
            z = (int64_t)((type == MC_T_I32 ? (uint64_t)(uint32_t)x
                                            : (uint64_t)x) >>
                          (y & 63));
            break;
        case MC_OP_SAR:
            z = x >> (y & 63);
            break;
        default:
            *st |= MC_ST_BADOP;
            z = 0;
            break;
            }
        if (type == MC_T_I32)
            r.i = (int32_t)z;
        else
            r.l = z;
        return r;
        }
    }

static uint8_t mc_vec_to_scalar(uint8_t vop)
    {
    switch (vop)
        {
    case MC_OP_VADD:
        return MC_OP_ADD;
    case MC_OP_VSUB:
        return MC_OP_SUB;
    case MC_OP_VMUL:
        return MC_OP_MUL;
    case MC_OP_VDIV:
        return MC_OP_DIV;
    case MC_OP_VMIN:
        return MC_OP_MIN;
    case MC_OP_VMAX:
        return MC_OP_MAX;
    case MC_OP_VABS:
        return MC_OP_ABS;
    case MC_OP_VNEG:
        return MC_OP_NEG;
    case MC_OP_VSQRT:
        return MC_OP_SQRT;
    default:
        return MC_OP_NOP;
        }
    }

/* v2 stored-program table (DEF/CALL/UNDEF). Fixed-capacity — no malloc in xts. */
static struct
    {
    int active;
    int16_t id;
    unsigned nops;
    uint32_t ops[MC_MAX_OPS];
    } mc_ptab[16];
static int mc_prog_find(int16_t id)
    {
    for (int i = 0; i < 16; i++)
        if (mc_ptab[i].active && mc_ptab[i].id == id)
            return i;
    return -1;
    }
static uint8_t mc_prog_store(int16_t id, const uint32_t* ops, unsigned nops)
    {
    int idx = mc_prog_find(id);
    if (idx < 0)
        {
        for (int i = 0; i < 16; i++)
            if (!mc_ptab[i].active)
                {
                idx = i;
                break;
                }
        }
    if (idx < 0 || nops > MC_MAX_OPS)
        return MC_ST_PROGFULL;
    mc_ptab[idx].active = 1;
    mc_ptab[idx].id = id;
    mc_ptab[idx].nops = nops;
    for (unsigned i = 0; i < nops; i++)
        mc_ptab[idx].ops[i] = ops[i];
    return 0;
    }

static void mc_run_ops(const uint32_t* ops, unsigned nops, uint8_t* st, int depth);

/* one control op at ops[*pc]; may advance *pc past a DEF body or recurse (CALL) */
static void mc_ctl_op(const uint32_t* ops, unsigned nops, unsigned* pc, uint8_t* st, int depth)
    {
    uint32_t w = ops[*pc];
    uint8_t op = w & 0x3F;
    int16_t id = (int16_t)((w >> 8) & 0xFFFFu);
    switch (op)
        {
    case MC_OP_DEF:
        {
        if (id <= 0)
            {
            *st |= MC_ST_BADOP;
            return;
            }
        unsigned body = *pc + 1, e = body;
        while (e < nops && (ops[e] & 0x3F) != MC_OP_END)
            {
            if ((ops[e] & 0x3F) == MC_OP_DEF)
                {
                *st |= MC_ST_BADOP;
                return;
                }
            e++;
            }
        if (e >= nops)
            {
            *st |= MC_ST_BADOP;
            return;
            }
        *st |= mc_prog_store(id, &ops[body], e - body);
        *pc = e;
        return;
        }
    case MC_OP_END:
        *st |= MC_ST_BADOP;
        return;
    case MC_OP_UNDEF:
        {
        int idx = mc_prog_find(id);
        if (idx >= 0)
            mc_ptab[idx].active = 0;
        return;
        }
    case MC_OP_CALL:
        {
        /* native builtins: not modelled (match v2 firmware) */
        if (id < 0)
            {
            *st |= MC_ST_NOPROG;
            return;
            }
        if (id == 0)
            {
            *st |= MC_ST_NOPROG;
            return;
            }
        int idx = mc_prog_find(id);
        if (idx < 0)
            *st |= MC_ST_NOPROG;
        else if (depth >= MC_CALL_DEPTH_MAX)
            *st |= MC_ST_BADOP;
        else
            mc_run_ops(mc_ptab[idx].ops, mc_ptab[idx].nops, st, depth + 1);
        return;
        }
    default:
        *st |= MC_ST_BADOP;
        return;
        }
    }

/* interpret `nops` op words against the math page's slot file */
static void mc_run_ops(const uint32_t* ops, unsigned nops, uint8_t* st, int depth)
    {
    for (unsigned pc = 0; pc < nops && !(*st & (MC_ST_BADOP | MC_ST_RANGE)); pc++)
        {
        uint32_t w = ops[pc];
        uint8_t op = w & 0x3F;
        uint8_t type = (w >> 6) & 3;
        uint8_t s1 = (w >> 8) & 0xFF;
        uint8_t s2 = (w >> 16) & 0xFF;
        uint8_t dst = (w >> 24) & 0xFF;

        if (op >= MC_OP_CTLBASE && op <= MC_OP_CTLTOP)
            {
            mc_ctl_op(ops, nops, &pc, st, depth);
            continue;
            }
        if (op < MC_OP_VECBASE)
            {
            mc_val a, b, r;
            if (op == MC_OP_CVT)
                {
                uint8_t src_t = s2 & 3;
                a = mc_load(s1 * 8, mc_esize(src_t));
                r = mc_convert(type, src_t, a);
                }
            else
                {
                a = mc_load(s1 * 8, mc_esize(type));
                b = mc_load(s2 * 8, mc_esize(type));
                r = mc_scalar(op, type, a, b, st);
                }
            mc_store(dst * 8, (op == MC_OP_CMP) ? 4 : mc_esize(type), r);
            }
        else
            {
            if (op > MC_OP_VECTOP || pc + 1 >= nops)
                {
                *st |= MC_ST_BADOP;
                break;
                }
            uint32_t w1 = ops[++pc];
            unsigned n = w1 & 0xFF;
            if (n == 0)
                n = 256;
            int st1 = (int8_t)(w1 >> 8);
            int st2 = (int8_t)(w1 >> 16);
            int stD = (int8_t)(w1 >> 24);
            int es = mc_esize(type);
            uint8_t sop = mc_vec_to_scalar(op);
            double facc = 0.0;
            int64_t iacc = 0;
            int isf = (type == MC_T_F32 || type == MC_T_F64);
            for (unsigned i = 0; i < n; i++)
                {
                int o1 = mc_elem_off(s1, (int)i, st1, es, st);
                if (o1 < 0)
                    break;
                mc_val a = mc_load(o1, es), b, r;
                b.u = 0;
                if (op == MC_OP_VCOPY)
                    {
                    r = a;
                    }
                else if (op == MC_OP_VCVT)
                    {
                    uint8_t src_t = s2 & 3;
                    int ses = mc_esize(src_t);
                    int o1s = mc_elem_off(s1, (int)i, st1, ses, st);
                    if (o1s < 0)
                        break;
                    r = mc_convert(type, src_t, mc_load(o1s, ses));
                    }
                else if (op == MC_OP_VSUM)
                    {
                    if (isf)
                        facc += mc_as_double(a, type);
                    else
                        iacc += mc_as_int64(a, type);
                    continue;
                    }
                else if (op == MC_OP_VDOT || op == MC_OP_VMLA ||
                         (op != MC_OP_VABS && op != MC_OP_VNEG && op != MC_OP_VSQRT))
                    {
                    int o2 = mc_elem_off(s2, (int)i, st2, es, st);
                    if (o2 < 0)
                        break;
                    b = mc_load(o2, es);
                    if (op == MC_OP_VDOT)
                        {
                        if (isf)
                            facc += mc_as_double(a, type) * mc_as_double(b, type);
                        else
                            iacc += mc_as_int64(a, type) * mc_as_int64(b, type);
                        continue;
                        }
                    if (op == MC_OP_VMLA)
                        {
                        int oD = mc_elem_off(dst, (int)i, stD, es, st);
                        if (oD < 0)
                            break;
                        mc_val c = mc_load(oD, es);
                        mc_val p = mc_scalar(MC_OP_MUL, type, a, b, st);
                        mc_store(oD, es, mc_scalar(MC_OP_ADD, type, c, p, st));
                        continue;
                        }
                    r = mc_scalar(sop, type, a, b, st);
                    }
                else
                    {
                    r = mc_scalar(sop, type, a, b, st);
                    }
                int oD = mc_elem_off(dst, (int)i, stD, es, st);
                if (oD < 0)
                    break;
                mc_store(oD, es, r);
                }
            if (op == MC_OP_VDOT || op == MC_OP_VSUM)
                {
                mc_val r;
                r.u = 0;
                switch (type)
                    {
                case MC_T_F32:
                    r.f = (float)facc;
                    break;
                case MC_T_F64:
                    r.d = facc;
                    break;
                case MC_T_I32:
                    r.i = (int32_t)iacc;
                    break;
                default:
                    r.l = iacc;
                    break;
                    }
                if (isf && (isnan(facc) || isinf(facc)))
                    *st |= MC_ST_INVALID;
                mc_store(dst * 8, es, r);
                }
            }
        }
    }

/* EXEC doorbell ($D5C7 write): run the page's program synchronously. */
static void mc_exec(void)
    {
    uint8_t st = 0;
    unsigned op_count = mc_page[MC_OFF_OPCOUNT] | ((unsigned)mc_page[MC_OFF_OPCOUNT + 1] << 8);
    if (op_count > MC_MAX_OPS)
        {
        op_count = MC_MAX_OPS;
        st |= MC_ST_RANGE;
        }
    uint32_t ops[MC_MAX_OPS];
    for (unsigned i = 0; i < op_count; i++)
        {
        unsigned b = MC_OFF_OPS + i * 4;
        ops[i] = (uint32_t)mc_page[b] | ((uint32_t)mc_page[b + 1] << 8) | ((uint32_t)mc_page[b + 2] << 16) | ((uint32_t)mc_page[b + 3] << 24);
        }
    mc_run_ops(ops, op_count, &st, 0);
    if (!(st & (MC_ST_BADOP | MC_ST_RANGE)))
        st |= MC_ST_OK;
    mc_page[MC_OFF_STATUS] = st;
    mc_page[MC_OFF_ABIVER] = MC_ABI_VERSION;
    mc_done = 1;
    }

/* MECH register/overlay hooks, called from mem_read/mem_write. Return 1 if the
 * access was handled (a mapped $4000-$5FFF byte or a $D5C6-$D5C8 register). */
static int mc_read_hook(uint16_t addr, uint8_t* out)
    {
    if (mc_mapped && addr >= 0x4000 && addr <= 0x5FFF)
        {
        *out = mc_page[addr - 0x4000];
        return 1;
        }
    if (addr == MC_REG_EXEC)
        {
        *out = (uint8_t)((mc_done ? 0x01 : 0) | (mc_ready ? 0x04 : 0)); /* busy always 0: synchronous */
        return 1;
        }
    return 0;
    }
static int mc_write_hook(uint16_t addr, uint8_t val)
    {
    if (mc_mapped && addr >= 0x4000 && addr <= 0x5FFF)
        {
        mc_page[addr - 0x4000] = val;
        return 1;
        }
    if (addr == MC_REG_CTL)
        {
        mc_mapped = val & 1;
        if (mc_mapped)
            mc_ready = 1;
        return 1;
        }
    if (addr == MC_REG_CHUNK)
        {
        mc_chunk = val;
        mc_ready = 1;
        return 1;
        }
    if (addr == MC_REG_EXEC)
        {
        mc_done = 0;
        mc_exec();
        return 1;
        }
    return 0;
    }

static uint8_t mem_read(uint16_t addr)
    {
        {
        uint8_t mv;
        if (mc_read_hook(addr, &mv))
            return mv;
        }
    /* xt: one 16 KB code-bank window at $6000-$9FFF via the 8-bit code
       selector ($D5C0), routed through bank[] (16 KB pages). The
       $4000-$5FFF screen and the $A000-$CFFF data window stay plain
       main RAM in this first cut — data banking is a follow-up. */
    if (banked_mode && bank_mode == BANK_XT && xt_bank_on() && addr >= 0x6000 && addr <= 0x9FFF)
        {
        return bank[mem[code_reg_addr]][addr - 0x6000];
        }
    /* xt data-bank window: $A000-$CFFF via the data-bank selector
       (data_reg_addr, $D5C1 on the shipping hardware). With 3-byte
       uniform pointers there is no bank-hi byte. */
    if (banked_mode && bank_mode == BANK_XT && xt_bank_on() && addr >= 0xA000 && addr <= 0xCFFF)
        {
        uint8_t sel = mem[data_reg_addr];
        if (sel != 0)
            {
            // uint8_t sel can never exceed XT_DATA_PAGES (256).
            return xt_data_bank[sel][addr - 0xA000];
            }
        /* sel == 0 → plain main RAM (fall through). */
        }
    if (banked_mode && bank_mode != BANK_XT && addr >= 0x4000 && addr < 0x8000)
        {
        uint16_t bid = current_bank();
        if (bid == BANK_MAIN_RAM)
            return mem[addr];
        if (bid < BANK_PAGES)
            return bank[bid][addr - 0x4000];
        return 0;
        }
    // Shadow ROM: when ROM is enabled, reads from $D800-$FFFF
    // return ROM bytes instead of RAM.
    if (rom_loaded && addr >= ROM_BASE && rom_enabled())
        {
        return rom[addr - ROM_BASE];
        }
    if (addr == 0xD20A)
        return (uint8_t)(rand() & 0xFF);
    if (addr == 0xD014)
        return 0x0F;

    /* PROBE: track reads from ___sdata_Assert count */
    if (addr == 0xDF17 || addr == 0xDF18)
        {
        static int cnt_r_cnt = 0;
        if (cnt_r_cnt++ < 40)
            fprintf(stderr, "ASSERT_READ count[%s] addr=$%04X val=$%02X PC=$%04X\n",
                    (addr & 1) ? "hi" : "lo", addr, mem[addr], reg_pc);
        }
    /* PROBE: track reads from canPrint field */
    if (addr == 0xD8A9)
        {
        static int d8a9_r_cnt = 0;
        if (d8a9_r_cnt++ < 50)
            fprintf(stderr, "CANPRINT_READ addr=$D8A9 val=$%02X PC=$%04X A=$%02X X=$%02X Y=$%02X $82=$%02X $83=$%02X\n",
                    mem[addr], reg_pc, reg_a, reg_x, reg_y, mem[0x82], mem[0x83]);
        }
    return mem[addr];
    }

static int opt_dump = 0;
static int opt_cycles = 0;

/* ── Targeted instruction trace (task #122) ──────────────────────────
 * A gated per-instruction trace to stderr, independent of the -d screen
 * dump on stdout. Controlled by environment variables so it can be
 * dropped onto a single fixture without touching the corpus harness:
 *
 *   XTS_ITRACE=1            trace from the first executed instruction
 *   XTS_ITRACE_TRIGGER=hex  start tracing once PC first reaches this addr
 *   XTS_ITRACE_STOP=hex     stop tracing once PC reaches this addr
 *   XTS_ITRACE_MAX=dec      cap on traced instructions (default 200000)
 *
 * Each traced line is:
 *   <insns> PC=$xxxx $82=bb $83=dd SP=sss A=aa X=xx Y=yy <flags> <mnem> <ops>
 * Addresses inside the $6000-$9FFF code-bank window are bank-relative;
 * pair with the xta `-l` listing ($82 tells you which bank) to resolve
 * a symbol. This is the instruction-level visibility the dealloc /
 * _xcall re-entrancy debugging needs (xts -d only logs bank events). */
static int itrace_enabled = 0; /* trace from start          */
static int itrace_active = 0;  /* currently emitting        */
static int itrace_has_trig = 0;
static uint16_t itrace_trigger = 0;
static int itrace_has_stop = 0;
static uint16_t itrace_stop = 0;
static uint64_t itrace_max = 200000;
static uint64_t itrace_emitted = 0;
static uint64_t itrace_after = 0; /* trigger ignored before this insn */
/* Stack-slot write watch (task #124): XTS_WATCH_SP=hex logs every write to
 * hidden_stack[addr] with PC + the value — used to pin which call corrupts
 * a frame's saved-status / saved-register slot (a stack misalignment). */
static int watch_sp_on = 0;
static uint16_t watch_sp_addr = 0;
/* `loading` (declared above, near the bank-unlock gate) is set while
   load_xex is shovelling segment bytes into mem[]. The -d dump path
   ignores writes during load — they aren't the running program's output,
   they're the code/data image, and if the binary extends past $9C00 those
   bytes would otherwise show up as initial "garbage" in the dump stream. */
static void dump_emit_char(uint16_t addr, uint8_t sc);
static void mem_write(uint16_t addr, uint8_t val)
    {
    /* MECH math page overlay + $D5C6-$D5C8 registers take precedence over
       normal RAM / the screen-dump path when the page is mapped. */
    if (mc_write_hook(addr, val))
        return;
        /* Debug: XTS_WATCH_MEM=hex logs every write to that absolute address. */
        {
        static int wm_init = 0;
        static long wm_addr = -1;
        if (!wm_init)
            {
            const char* e = getenv("XTS_WATCH_MEM");
            wm_addr = e ? (long)strtoul(e, NULL, 16) : -1;
            wm_init = 1;
            }
        if (wm_addr >= 0 && addr == (uint16_t)wm_addr && !loading)
            {
            fprintf(stderr, "[wm $%04X] <= $%02X  PC=$%04X A=%02X X=%02X Y=%02X SP=%03X\n",
                    addr, val, reg_pc, reg_a, reg_x, reg_y, reg_sp);
            }
        }
    /* Watch $58/$59 (SAVMSC) for changes — with safe bank-offset guard */
    if (addr == 0x58 || addr == 0x59)
        {
        int bi = mem[0x82];
        uint8_t b0 = 0, b1 = 0;
        if (bi >= 0 && bi < 256 && reg_pc >= 0x6000 && reg_pc < 0xA000)
            {
            uint16_t off = reg_pc - 0x6000;
            if (off < 16384)
                b0 = bank[bi][off];
            if (off + 1 < 16384)
                b1 = bank[bi][off + 1];
            }
        fprintf(stderr, "SAVMSC_WRITE addr=$%04X val=$%02X PC=$%04X \$82=$%02X \$83=$%02X A=$%02X X=$%02X Y=$%02X [opcodes=%02X %02X]\n",
                addr, val, reg_pc, mem[0x82], mem[0x83], reg_a, reg_x, reg_y, b0, b1);
        }
    /* Watch $19-$1C (the 4-byte pointer that ends up pointing to $58) */
    if (addr >= 0x19 && addr <= 0x1C)
        {
        fprintf(stderr, "ZP19_WRITE addr=$%04X val=$%02X PC=$%04X \$82=$%02X A=$%02X X=$%02X Y=$%02X\n",
                addr, val, reg_pc, mem[0x82], reg_a, reg_x, reg_y);
        }
    /* Watch $83 bank-register writes for debugging. With 3-byte uniform
       pointers, $84 is not used for the data-bank selector. */
    if (addr == 0x83)
        {
        static int wp_cnt = 0;
        if (wp_cnt++ < 2000)
            fprintf(stderr, "[bank_write $83] ← $%02X at PC=$%04X (A=$%02X X=$%02X Y=$%02X $82=$%02X $84=$%02X)\n",
                    val, reg_pc, reg_a, reg_x, reg_y, mem[0x82], mem[0x84]);
        /* Also log every transition of $83 from non-zero to zero — that's
           the bug we're hunting (heap walker with $83=0). No rate limit. */
        if (val == 0 && mem[0x83] != 0)
            fprintf(stderr, "[bank_write $83→0] ← $00 at PC=$%04X (A=$%02X X=$%02X Y=$%02X) [PREV $83=$%02X]\n",
                    reg_pc, reg_a, reg_x, reg_y, mem[0x83]);
        }
    /* Watch writes to $89 — only used for u32 returns now (3-byte
       pointers don't use $89 for bank-hi). */
    if (addr == 0x89)
        {
        static int wp89_cnt = 0;
        if (wp89_cnt++ < 200)
            fprintf(stderr, "[bank_write $89] ← $%02X at PC=$%04X $82=$%02X (A=$%02X X=$%02X Y=$%02X)\n",
                    val, reg_pc, mem[code_reg_addr], reg_a, reg_x, reg_y);
        }
    /* Hardware ZP banking: a write to $82 swaps the three 16-byte
       ZP slices ($A0-$AF / $C0-$CF / $D0-$DF) along with the code
       window. Has to fire BEFORE the underlying mem[0x82] update
       so zp_bank_swap can read the outgoing bank id. The xt-extended
       path that follows then sees mem[0x82] already pointing at
       the new bank, so subsequent reads from $4000-$5FFF hit the
       freshly-paged code bank. */
    if (addr == code_reg_addr && zp_banking_active())
        {
        zp_bank_swap(mem[code_reg_addr], val);
        }
    /* xt: $6000-$9FFF code-bank window via the code selector ($D5C0). The
       INITAD preload stub sets it to the target page before each banked
       payload streams in, so loading routes correctly here. */
    if (banked_mode && bank_mode == BANK_XT && xt_bank_on() && addr >= 0x6000 && addr <= 0x9FFF)
        {
        bank[mem[code_reg_addr]][addr - 0x6000] = val;
        return;
        }
    /* xt data-bank window: $A000-$CFFF via the data-bank selector
       (data_reg_addr, $D5C1). At boot / load time it reads 0 so .xex
       segments stream into main RAM; a running program selects page >= 1
       to read/write a heap data page. With 3-byte uniform pointers there
       is no bank-hi byte. */
    if (banked_mode && bank_mode == BANK_XT && xt_bank_on() && addr >= 0xA000 && addr <= 0xCFFF)
        {
        uint8_t sel = mem[data_reg_addr];
        if (sel != 0)
            {
            // uint8_t sel can never exceed XT_DATA_PAGES (256), but
            // the unchecked index keeps xt_data_bank bounds safe.
            xt_data_bank[sel][addr - 0xA000] = val;
            return;
            }
        /* sel == 0 → plain main RAM (fall through). */
        }
    if (banked_mode && bank_mode != BANK_XT && addr >= 0x4000 && addr < 0x8000)
        {
        uint16_t bid = current_bank();
        if (bid == BANK_MAIN_RAM)
            {
            mem[addr] = val;
            return;
            }
        if (bid < BANK_PAGES)
            {
            bank[bid][addr - 0x4000] = val;
            }
        return;
        }
    /* PROBE: track writes to canPrint field */
    /* PROBE: track writes to ___sdata_Assert count/fails */
    if (addr >= 0xDF17 && addr <= 0xDF1A)
        {
        static int cnt_w_cnt = 0;
        if (cnt_w_cnt++ < 50)
            {
            const char* field = "???";
            if (addr == 0xDF17 || addr == 0xDF18)
                field = "count";
            if (addr == 0xDF19 || addr == 0xDF1A)
                field = "fails";
            fprintf(stderr, "ASSERT_WRITE %s[%s] addr=$%04X val=$%02X PC=$%04X A=$%02X\n",
                    field, (addr & 1) ? "hi" : "lo", addr, val, reg_pc, reg_a);
            }
        }
    if (addr == 0xD8A9)
        {
        static int d8a9_w_cnt = 0;
        if (d8a9_w_cnt++ < 20)
            fprintf(stderr, "CANPRINT_WRITE addr=$D8A9 val=$%02X PC=$%04X A=$%02X X=$%02X Y=$%02X $82=$%02X $83=$%02X\n",
                    val, reg_pc, reg_a, reg_x, reg_y, mem[0x82], mem[0x83]);
        }
    /* PROBE: track writes to any __sdata_Stdio field */
    if (addr >= 0xD8A0 && addr <= 0xD8B4)
        {
        static int sd_w_cnt = 0;
        if (sd_w_cnt++ < 40)
            fprintf(stderr, "SDATA_WRITE addr=$%04X val=$%02X PC=$%04X A=$%02X X=$%02X Y=$%02X $82=$%02X $83=$%02X\n",
                    addr, val, reg_pc, reg_a, reg_x, reg_y, mem[0x82], mem[0x83]);
        }
    mem[addr] = val;
    if (opt_dump && !loading)
        {
        dump_emit_char(addr, val);
        }
    }

/* ── CPU ───────────────────────────────────────────────────────────── */

/* Forward-declared above for use by mem_read/mem_write. */
// static uint8_t reg_a, reg_x, reg_y;
/* SP is widened to 12 bits on xt (docs/6502/6502-embellishments.md §1).
 * Stored in 16 bits and masked to 12 on every update; the high 4 bits
 * are always zero. TSX returns SP[7:0] only (high bits lost); TXS writes
 * SP[7:0] only (high bits unchanged). Reset value $FFF. */
// static uint16_t reg_sp;
// static uint16_t reg_pc;

/* 4 KB hidden hardware stack RAM (docs/6502/6502-embellishments.md §1).
 * Indexed by reg_sp[11:0]. The top 256 bytes alias to main memory at
 * $0100..$01FF — a write to hidden_stack[$F00..$FFF] mirrors into
 * mem[$0100..$01FF] and vice-versa so stock-6502 patterns like
 * `TSX + LDA $0100,X` still work for stack depth ≤ 256. Deeper than
 * that, the alias goes stale (stack writes still update hidden_stack
 * but no longer touch mem[$0100..$01FF]). */
static uint8_t hidden_stack[4096];

/* Push 8-bit value, decrement SP. SP wraps within the 12-bit range;
 * the hardware actually clamps at $000 (a runtime stack-overflow
 * condition the simulator does not trap on today — see STACK-ABI.md
 * §8). */
static inline void hidden_stack_write(uint16_t sp_addr, uint8_t v)
    {
    sp_addr &= 0xFFF;
    if (watch_sp_on && sp_addr == watch_sp_addr && !loading)
        {
        fprintf(stderr, "[watch-sp $%03X] <= $%02X  PC=$%04X SP=%03X "
                        "A=%02X X=%02X Y=%02X\n",
                sp_addr, v, reg_pc, reg_sp, reg_a, reg_x, reg_y);
        }
    hidden_stack[sp_addr] = v;
    if (sp_addr >= 0xF00)
        {
        /* Aliased compatibility window. */
        mem[0x0100 | (sp_addr & 0xFF)] = v;
        }
    /* PROBE: track hidden stack writes that overwrite our pointer */
    if (!loading && (sp_addr == 0xFEA || sp_addr == 0xFEB ||
                     sp_addr == 0xFE5 || sp_addr == 0xFE6 ||
                     sp_addr == 0xFE8 || sp_addr == 0xFE9))
        {
        static int hw_cnt = 0;
        if (hw_cnt++ < 20)
            fprintf(stderr, "HSTACK_WRITE sp_addr=$%03X val=$%02X PC=$%04X A=$%02X\n",
                    sp_addr, v, reg_pc, reg_a);
        }
    }

static inline uint8_t hidden_stack_read(uint16_t sp_addr)
    {
    return hidden_stack[sp_addr & 0xFFF];
    }

#define FLAG_C 0x01
#define FLAG_Z 0x02
#define FLAG_I 0x04
#define FLAG_D 0x08
#define FLAG_B 0x10
#define FLAG_V 0x40
#define FLAG_N 0x80
static uint8_t reg_p = 0x24;

static void set_nz(uint8_t v)
    {
    reg_p &= ~(FLAG_N | FLAG_Z);
    if (!v)
        reg_p |= FLAG_Z;
    if (v & 0x80)
        reg_p |= FLAG_N;
    }

static int running = 1;
static int opt_g0 = 0;
static uint64_t insn_count = 0;
/* Optional per-run instruction cap (-M <N>). Defaults to "no cap";
   useful for test harnesses that need an infinite-loop abort without
   relying on shell `timeout`. Exits with a short error on the first
   instruction past the cap. */
static uint64_t insn_limit = 0;

/* Process exit code surfaced by main().  A clean program end (an RTS back to
   the loader, a BRK, or a self-targeted JMP after main returns) leaves the 6502's return value in A;
   we hand that low byte back as our own exit status so a 6502 program can be
   probed with `$?` exactly like a native one.  An abnormal stop (illegal
   opcode, instruction-limit blow-out) instead sets a reserved code AND writes
   a distinctive line to stderr, so a wrapper can tell a crash apart from a
   program that merely chose to exit non-zero. */
static int g_exit_code = 0;
#define XTS_EXIT_ILLEGAL_OPCODE 70 /* EX_SOFTWARE — sim aborted the run */
#define XTS_EXIT_INSN_LIMIT 124    /* timeout convention */

/* RTCLOK jiffy-counter simulation.
 *
 * The Atari OS increments RTCLOK ($12 MSB, $13, $14 LSB — a 24-bit
 * little-endian-byte big-endian-word counter) during VBI at 60 Hz NTSC /
 * 50 Hz PAL. xts doesn't run the OS or ANTIC, so without this the
 * counter never advances and any Atari Time-class code that polls it
 * (Time.delayJiffies, Time.ticksSince) loops forever.
 *
 * Tick every N executed instructions; +1 to $14 with carry to $13 and
 * $12. N is configurable via XTS_RTCLOK_INSNS and defaults to a rate
 * slow enough that short tests (sieve, hello-world) don't observe a
 * tick — preserving oracles written assuming "Time: 0.0 secs" — but
 * fast enough that delayJiffies(small N) terminates inside the harness
 * timeout. Set XTS_RTCLOK_INSNS=0 to disable ticking entirely. */
static uint64_t rtclok_insns_per_tick = 20000000;
static uint64_t rtclok_step_counter = 0;

/* Accumulated screen output for -d mode. Each write to screen memory
   is decoded and appended; row/column transitions emit \n and spaces so
   that the stream mirrors what the program intended to draw. */
static int dump_last_row = -1;
static int dump_last_col = -1;
static char screen_code_to_ascii(uint8_t sc);
/* -d mode treats screen writes as a log stream, not a bounded 40x24
   visible frame. A fixture that outputs more than 24 rows would
   otherwise lose its tail to the early-return below, so we extend
   the virtual capture region to 200 rows (8000 bytes). 200 rows × 40
   cols is plenty for any regression fixture; anything past the end
   just wraps back into row 0 as a discontinuity (Stdio.printf's
   screenPtr keeps climbing linearly). */
#define XTS_DUMP_ROWS 200
static void dump_emit_char(uint16_t addr, uint8_t sc)
    {
    uint16_t base = mem[0x58] | ((uint16_t)mem[0x59] << 8);
    /* Cap the virtual dump window so it can't bleed into the
       $C000+ I/O / OS ROM space. Without this, programs that
       write to PIA ($D301 PORTB — xe bank switches, for
       example) have their selector bytes decoded as screen
       codes and streamed into the output. */
    uint32_t cap = (uint32_t)base + 40 * XTS_DUMP_ROWS;
    if (cap > 0xC000)
        cap = 0xC000;
        /* LOG ALL calls that guard-pass — limit to first 1000 */
        {
        static uint64_t pass_cnt = 0;
        if (addr >= base && (uint32_t)addr < cap)
            {
            if (pass_cnt < 1000)
                {
                fprintf(stderr, "GUARD_PASS cnt=%llu base=$%04X cap=$%04X addr=$%04X val=$%02X\n",
                        (unsigned long long)pass_cnt, base, (uint16_t)cap, addr, sc);
                }
            pass_cnt++;
            }
        }
    if (addr < base || (uint32_t)addr >= cap)
        return;
    uint16_t off = addr - base;
    int row = off / 40, col = off % 40;
    /* Treat the write stream as a log: a continuation of the current row
       prints inline, a next-row write emits a single newline, and any
       other jump (forward skip, cursor move via printfAt) also emits a
       single newline. We never pad with blank rows or leading spaces —
       the -d stream mirrors what the program *printed*, not where on
       the screen it landed. */
    if (dump_last_row >= 0)
        {
        int same_row = (row == dump_last_row && col == dump_last_col + 1);
        /* Hardware wrap from the last column of one row to the first
           column of the next is a continuation of the same printed
           line, not a row transition — without this, a printf that
           spilled past column 40 (e.g. `%lu` of 3000000000 at the end
           of a long format string) was reported as two output lines
           and broke naive line-based verification. */
        int wrap = (dump_last_col == 39 && row == dump_last_row + 1 && col == 0);
        if (!same_row && !wrap)
            putchar('\n');
        }
    putchar(screen_code_to_ascii(sc));
    dump_last_row = row;
    dump_last_col = col;
    }

/* ── Stack ─────────────────────────────────────────────────────────── */

/* Writes to hidden_stack[SP]; mirrors into mem[$0100..$01FF] if SP is in
 * the top-256 alias window. Decrements SP (12-bit, wraps to $FFF).
 * The xt hardware actually clamps at $000 — the simulator wraps,
 * which is also a runtime-overflow indicator (the program will produce
 * wrong results either way, and the alias mirroring stops once SP
 * leaves the top window). */
static void push8(uint8_t v)
    {
    hidden_stack_write(reg_sp, v);
    reg_sp = (reg_sp - 1) & 0xFFF;
    }
static uint8_t pop8(void)
    {
    reg_sp = (reg_sp + 1) & 0xFFF;
    return hidden_stack_read(reg_sp);
    }
static void push16(uint16_t v)
    {
    push8((v >> 8) & 0xFF);
    push8(v & 0xFF);
    }
static uint16_t pop16(void)
    {
    uint16_t lo = pop8();
    return lo | ((uint16_t)pop8() << 8);
    }

/* ── Addressing ────────────────────────────────────────────────────── */

typedef enum
{
    AM_IMP,
    AM_ACC,
    AM_IMM,
    AM_ZP,
    AM_ZPX,
    AM_ZPY,
    AM_ABS,
    AM_ABX,
    AM_ABY,
    AM_IND,
    AM_IZX,
    AM_IZY,
    AM_REL
} AddrMode;

static uint16_t ea;
static uint8_t opbytes;

static uint16_t resolve_ea(AddrMode am)
    {
    uint8_t lo, hi;
    switch (am)
        {
    case AM_IMP:
    case AM_ACC:
        opbytes = 1;
        return 0;
    case AM_IMM:
        opbytes = 2;
        return reg_pc + 1;
    case AM_ZP:
        opbytes = 2;
        return mem_read(reg_pc + 1);
    case AM_ZPX:
        opbytes = 2;
        return (mem_read(reg_pc + 1) + reg_x) & 0xFF;
    case AM_ZPY:
        opbytes = 2;
        return (mem_read(reg_pc + 1) + reg_y) & 0xFF;
    case AM_ABS:
        opbytes = 3;
        lo = mem_read(reg_pc + 1);
        hi = mem_read(reg_pc + 2);
        return lo | ((uint16_t)hi << 8);
    case AM_ABX:
        opbytes = 3;
        lo = mem_read(reg_pc + 1);
        hi = mem_read(reg_pc + 2);
        return (lo | ((uint16_t)hi << 8)) + reg_x;
    case AM_ABY:
        opbytes = 3;
        lo = mem_read(reg_pc + 1);
        hi = mem_read(reg_pc + 2);
        return (lo | ((uint16_t)hi << 8)) + reg_y;
    case AM_IND:
        opbytes = 3;
        lo = mem_read(reg_pc + 1);
        hi = mem_read(reg_pc + 2);
            {
            uint16_t p = lo | ((uint16_t)hi << 8);
            return mem_read(p) | ((uint16_t)mem_read((p & 0xFF00) | ((p + 1) & 0xFF)) << 8);
            }
    case AM_IZX:
        opbytes = 2;
            {
            uint8_t z = (mem_read(reg_pc + 1) + reg_x) & 0xFF;
            return mem_read(z) | ((uint16_t)mem_read((z + 1) & 0xFF) << 8);
            }
    case AM_IZY:
        opbytes = 2;
            {
            uint8_t z = mem_read(reg_pc + 1);
            return (mem_read(z) | ((uint16_t)mem_read((z + 1) & 0xFF) << 8)) + reg_y;
            }
    case AM_REL:
        opbytes = 2;
        return reg_pc + 2 + (int8_t)mem_read(reg_pc + 1);
        }
    return 0;
    }

/* ── Opcode tables ─────────────────────────────────────────────────── */

/* mn_names is patched in install_xt_opcode_modes() for the xt
 * additions; vanilla 6502 slots are unchanged. */
static const char* mn_names[256] = {
    "BRK",
    "ORA",
    "???",
    "???",
    "???",
    "ORA",
    "ASL",
    "???",
    "PHP",
    "ORA",
    "ASL",
    "???",
    "???",
    "ORA",
    "ASL",
    "???",
    "BPL",
    "ORA",
    "???",
    "???",
    "???",
    "ORA",
    "ASL",
    "???",
    "CLC",
    "ORA",
    "???",
    "???",
    "???",
    "ORA",
    "ASL",
    "???",
    "JSR",
    "AND",
    "???",
    "???",
    "BIT",
    "AND",
    "ROL",
    "???",
    "PLP",
    "AND",
    "ROL",
    "???",
    "BIT",
    "AND",
    "ROL",
    "???",
    "BMI",
    "AND",
    "???",
    "???",
    "???",
    "AND",
    "ROL",
    "???",
    "SEC",
    "AND",
    "???",
    "???",
    "???",
    "AND",
    "ROL",
    "???",
    "RTI",
    "EOR",
    "???",
    "???",
    "???",
    "EOR",
    "LSR",
    "???",
    "PHA",
    "EOR",
    "LSR",
    "???",
    "JMP",
    "EOR",
    "LSR",
    "???",
    "BVC",
    "EOR",
    "???",
    "???",
    "???",
    "EOR",
    "LSR",
    "???",
    "CLI",
    "EOR",
    "???",
    "???",
    "???",
    "EOR",
    "LSR",
    "???",
    "RTS",
    "ADC",
    "???",
    "???",
    "???",
    "ADC",
    "ROR",
    "???",
    "PLA",
    "ADC",
    "ROR",
    "???",
    "JMP",
    "ADC",
    "ROR",
    "???",
    "BVS",
    "ADC",
    "???",
    "???",
    "???",
    "ADC",
    "ROR",
    "???",
    "SEI",
    "ADC",
    "???",
    "???",
    "???",
    "ADC",
    "ROR",
    "???",
    "???",
    "STA",
    "???",
    "???",
    "STY",
    "STA",
    "STX",
    "???",
    "DEY",
    "???",
    "TXA",
    "???",
    "STY",
    "STA",
    "STX",
    "???",
    "BCC",
    "STA",
    "???",
    "???",
    "STY",
    "STA",
    "STX",
    "???",
    "TYA",
    "STA",
    "TXS",
    "???",
    "???",
    "STA",
    "???",
    "???",
    "LDY",
    "LDA",
    "LDX",
    "???",
    "LDY",
    "LDA",
    "LDX",
    "???",
    "TAY",
    "LDA",
    "TAX",
    "???",
    "LDY",
    "LDA",
    "LDX",
    "???",
    "BCS",
    "LDA",
    "???",
    "???",
    "LDY",
    "LDA",
    "LDX",
    "???",
    "CLV",
    "LDA",
    "TSX",
    "???",
    "LDY",
    "LDA",
    "LDX",
    "???",
    "CPY",
    "CMP",
    "???",
    "???",
    "CPY",
    "CMP",
    "DEC",
    "???",
    "INY",
    "CMP",
    "DEX",
    "???",
    "CPY",
    "CMP",
    "DEC",
    "???",
    "BNE",
    "CMP",
    "???",
    "???",
    "???",
    "CMP",
    "DEC",
    "???",
    "CLD",
    "CMP",
    "???",
    "???",
    "???",
    "CMP",
    "DEC",
    "???",
    "CPX",
    "SBC",
    "???",
    "???",
    "CPX",
    "SBC",
    "INC",
    "???",
    "INX",
    "SBC",
    "NOP",
    "???",
    "CPX",
    "SBC",
    "INC",
    "???",
    "BEQ",
    "SBC",
    "???",
    "???",
    "???",
    "SBC",
    "INC",
    "???",
    "SED",
    "SBC",
    "???",
    "???",
    "???",
    "SBC",
    "INC",
    "???",
};

/* mn_modes is patched at runtime in main() to register the xt
 * additions ($02/$12/$22/$32/$42/$52/$62/$72/$92/$B2/$D2/$F2 as
 * AM_IMM; $80 as AM_REL). Vanilla 6502 dispatch is unchanged. */
static AddrMode mn_modes[256] = {
    AM_IMP,
    AM_IZX,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_ZP,
    AM_ZP,
    AM_IMP,
    AM_IMP,
    AM_IMM,
    AM_ACC,
    AM_IMP,
    AM_IMP,
    AM_ABS,
    AM_ABS,
    AM_IMP,
    AM_REL,
    AM_IZY,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_ZPX,
    AM_ZPX,
    AM_IMP,
    AM_IMP,
    AM_ABY,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_ABX,
    AM_ABX,
    AM_IMP,
    AM_ABS,
    AM_IZX,
    AM_IMP,
    AM_IMP,
    AM_ZP,
    AM_ZP,
    AM_ZP,
    AM_IMP,
    AM_IMP,
    AM_IMM,
    AM_ACC,
    AM_IMP,
    AM_ABS,
    AM_ABS,
    AM_ABS,
    AM_IMP,
    AM_REL,
    AM_IZY,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_ZPX,
    AM_ZPX,
    AM_IMP,
    AM_IMP,
    AM_ABY,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_ABX,
    AM_ABX,
    AM_IMP,
    AM_IMP,
    AM_IZX,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_ZP,
    AM_ZP,
    AM_IMP,
    AM_IMP,
    AM_IMM,
    AM_ACC,
    AM_IMP,
    AM_ABS,
    AM_ABS,
    AM_ABS,
    AM_IMP,
    AM_REL,
    AM_IZY,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_ZPX,
    AM_ZPX,
    AM_IMP,
    AM_IMP,
    AM_ABY,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_ABX,
    AM_ABX,
    AM_IMP,
    AM_IMP,
    AM_IZX,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_ZP,
    AM_ZP,
    AM_IMP,
    AM_IMP,
    AM_IMM,
    AM_ACC,
    AM_IMP,
    AM_IND,
    AM_ABS,
    AM_ABS,
    AM_IMP,
    AM_REL,
    AM_IZY,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_ZPX,
    AM_ZPX,
    AM_IMP,
    AM_IMP,
    AM_ABY,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_ABX,
    AM_ABX,
    AM_IMP,
    AM_IMP,
    AM_IZX,
    AM_IMP,
    AM_IMP,
    AM_ZP,
    AM_ZP,
    AM_ZP,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_ABS,
    AM_ABS,
    AM_ABS,
    AM_IMP,
    AM_REL,
    AM_IZY,
    AM_IMP,
    AM_IMP,
    AM_ZPX,
    AM_ZPX,
    AM_ZPY,
    AM_IMP,
    AM_IMP,
    AM_ABY,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_ABX,
    AM_IMP,
    AM_IMP,
    AM_IMM,
    AM_IZX,
    AM_IMM,
    AM_IMP,
    AM_ZP,
    AM_ZP,
    AM_ZP,
    AM_IMP,
    AM_IMP,
    AM_IMM,
    AM_IMP,
    AM_IMP,
    AM_ABS,
    AM_ABS,
    AM_ABS,
    AM_IMP,
    AM_REL,
    AM_IZY,
    AM_IMP,
    AM_IMP,
    AM_ZPX,
    AM_ZPX,
    AM_ZPY,
    AM_IMP,
    AM_IMP,
    AM_ABY,
    AM_IMP,
    AM_IMP,
    AM_ABX,
    AM_ABX,
    AM_ABY,
    AM_IMP,
    AM_IMM,
    AM_IZX,
    AM_IMP,
    AM_IMP,
    AM_ZP,
    AM_ZP,
    AM_ZP,
    AM_IMP,
    AM_IMP,
    AM_IMM,
    AM_IMP,
    AM_IMP,
    AM_ABS,
    AM_ABS,
    AM_ABS,
    AM_IMP,
    AM_REL,
    AM_IZY,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_ZPX,
    AM_ZPX,
    AM_IMP,
    AM_IMP,
    AM_ABY,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_ABX,
    AM_ABX,
    AM_IMP,
    AM_IMM,
    AM_IZX,
    AM_IMP,
    AM_IMP,
    AM_ZP,
    AM_ZP,
    AM_ZP,
    AM_IMP,
    AM_IMP,
    AM_IMM,
    AM_IMP,
    AM_IMP,
    AM_ABS,
    AM_ABS,
    AM_ABS,
    AM_IMP,
    AM_REL,
    AM_IZY,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_ZPX,
    AM_ZPX,
    AM_IMP,
    AM_IMP,
    AM_ABY,
    AM_IMP,
    AM_IMP,
    AM_IMP,
    AM_ABX,
    AM_ABX,
    AM_IMP,
};

static void format_operand(char* buf, AddrMode am)
    {
    uint8_t lo, hi;
    switch (am)
        {
    case AM_IMP:
        buf[0] = 0;
        break;
    case AM_ACC:
        strcpy(buf, "A");
        break;
    case AM_IMM:
        sprintf(buf, "#$%02X", mem_read(reg_pc + 1));
        break;
    case AM_ZP:
        sprintf(buf, "$%02X", mem_read(reg_pc + 1));
        break;
    case AM_ZPX:
        sprintf(buf, "$%02X,X", mem_read(reg_pc + 1));
        break;
    case AM_ZPY:
        sprintf(buf, "$%02X,Y", mem_read(reg_pc + 1));
        break;
    case AM_ABS:
        lo = mem_read(reg_pc + 1);
        hi = mem_read(reg_pc + 2);
        sprintf(buf, "$%04X", lo | ((uint16_t)hi << 8));
        break;
    case AM_ABX:
        lo = mem_read(reg_pc + 1);
        hi = mem_read(reg_pc + 2);
        sprintf(buf, "$%04X,X", lo | ((uint16_t)hi << 8));
        break;
    case AM_ABY:
        lo = mem_read(reg_pc + 1);
        hi = mem_read(reg_pc + 2);
        sprintf(buf, "$%04X,Y", lo | ((uint16_t)hi << 8));
        break;
    case AM_IND:
        lo = mem_read(reg_pc + 1);
        hi = mem_read(reg_pc + 2);
        sprintf(buf, "($%04X)", lo | ((uint16_t)hi << 8));
        break;
    case AM_IZX:
        sprintf(buf, "($%02X,X)", mem_read(reg_pc + 1));
        break;
    case AM_IZY:
        sprintf(buf, "($%02X),Y", mem_read(reg_pc + 1));
        break;
    case AM_REL:
        sprintf(buf, "$%04X", (reg_pc + 2 + (int8_t)mem_read(reg_pc + 1)) & 0xFFFF);
        break;
        }
    }

static void format_flags(char* buf, uint8_t p)
    {
    buf[0] = (p & FLAG_N) ? 'N' : '-';
    buf[1] = (p & FLAG_V) ? 'V' : '-';
    buf[2] = (p & FLAG_D) ? 'D' : '-';
    buf[3] = (p & FLAG_I) ? 'I' : '-';
    buf[4] = (p & FLAG_Z) ? 'Z' : '-';
    buf[5] = (p & FLAG_C) ? 'C' : '-';
    buf[6] = 0;
    }

/* ── ALU ───────────────────────────────────────────────────────────── */

static void do_adc(uint8_t v)
    {
    uint16_t s = reg_a + v + (reg_p & FLAG_C ? 1 : 0);
    reg_p &= ~(FLAG_C | FLAG_V);
    if (s > 0xFF)
        reg_p |= FLAG_C;
    if (~(reg_a ^ v) & (reg_a ^ s) & 0x80)
        reg_p |= FLAG_V;
    reg_a = s & 0xFF;
    set_nz(reg_a);
    }
static void do_sbc(uint8_t v)
    {
    do_adc(~v);
    }
static void do_cmp(uint8_t r, uint8_t v)
    {
    uint16_t d = r - v;
    reg_p &= ~(FLAG_C | FLAG_Z | FLAG_N);
    if (r >= v)
        reg_p |= FLAG_C;
    if (r == v)
        reg_p |= FLAG_Z;
    if (d & 0x80)
        reg_p |= FLAG_N;
    }

/* ── Execute ───────────────────────────────────────────────────────── */

static int step(void)
    {
    /* PROBE: log first 5 instructions AFTER loading=0 */
    if (!loading)
        {
        static int probe_cnt = 0;
        if (probe_cnt++ < 5)
            fprintf(stderr, "MAIN_PROBE PC=$%04X insns=%llu\n", reg_pc, (unsigned long long)insn_count);
        }
    /* PROBE: watch for store-zero code in bank 2 at $7411-$7460 */
    if (!loading && banked_mode && bank_mode == BANK_XT &&
        mem[0x82] == 2 && reg_pc >= 0x7411 && reg_pc <= 0x7460)
        {
        static int probe_b2 = 0;
        if (probe_b2++ < 20)
            {
            fprintf(stderr, "B2_PROBE PC=$%04X A=$%02X X=$%02X Y=$%02X SP=%03X\n",
                    reg_pc, reg_a, reg_x, reg_y, reg_sp);
            }
        }
    /* PROBE: dump argument area when init function starts */
    if (!loading && reg_pc == 0xBA6E)
        {
        static int probe_al = 0;
        if (probe_al++ < 10)
            {
            fprintf(stderr, "ALLOC_PROBE PC=$%04X A=$%02X X=$%02X Y=$%02X (size+4 raw) SP=%03X\n",
                    reg_pc, reg_a, reg_x, reg_y, reg_sp);
            }
        }
    /* PROBE: log heap allocator failure at $BB6B (RTS with A=X=Y=0) */
    if (!loading && reg_pc == 0xBB6B)
        {
        static int probe_af = 0;
        if (probe_af++ < 5)
            {
            fprintf(stderr, "ALLOC_FAIL PC=$%04X A=$%02X X=$%02X Y=$%02X (OOM return) mem[3713]=%02X%02X\n",
                    reg_pc, reg_a, reg_x, reg_y,
                    mem[0x3714], mem[0x3713]);
            }
        }
    /* PROBE: investigate invalid $83 writes at PC=$8F49 (first bad bank val) */
    if (!loading && reg_pc == 0x8F49)
        {
        static int probe_8f = 0;
        if (probe_8f++ < 10)
            {
            uint8_t* bk = bank[mem[0x82]];
            fprintf(stderr, "PC8F49_PROBE PC=$%04X A=$%02X X=$%02X Y=$%02X "
                            "SP=%03X $82=%02X $83=%02X insn_count=%llu\n",
                    reg_pc, reg_a, reg_x, reg_y, reg_sp,
                    mem[0x82], mem[0x83],
                    (unsigned long long)insn_count);
            /* Dump 32 bytes of code leading up to (and including) PC */
            int offset = reg_pc - 0x6000;
            fprintf(stderr, "  CODE[%d:]:", offset);
            for (int i = -32; i < 16; i++)
                {
                int o = offset + i;
                if (o >= 0 && o < 0x4000)
                    fprintf(stderr, " %02X", bk[o]);
                else
                    fprintf(stderr, " ??");
                if (i == -1)
                    fprintf(stderr, " <<<");
                }
            fprintf(stderr, "\n");
            /* Dump SP-relative frame around the current stack top */
            for (int d = 0; d < 32; d += 4)
                {
                fprintf(stderr, "  SP+%02X=%02X SP+%02X=%02X SP+%02X=%02X SP+%02X=%02X\n",
                        d, hidden_stack_read((reg_sp + d) & 0xFFF),
                        d + 1, hidden_stack_read((reg_sp + d + 1) & 0xFFF),
                        d + 2, hidden_stack_read((reg_sp + d + 2) & 0xFFF),
                        d + 3, hidden_stack_read((reg_sp + d + 3) & 0xFFF));
                }
            }
        }
    uint8_t opc = mem_read(reg_pc);
    AddrMode am = mn_modes[opc];
    ea = resolve_ea(am);

    char ops[32], fb[8], fa[8];
    format_operand(ops, am);
    format_flags(fb, reg_p);
    if (!opt_dump)
        printf("A=%02X X=%02X Y=%02X SP=%03X %s | %04X: %-3s %-10s | ",
               reg_a, reg_x, reg_y, reg_sp, fb, reg_pc, mn_names[opc], ops);

    /* Targeted instruction trace (task #122) — to stderr, gated. */
    if (itrace_has_trig && reg_pc == itrace_trigger && insn_count >= itrace_after)
        itrace_active = 1;
    if (itrace_active && itrace_emitted < itrace_max)
        {
        if (itrace_has_stop && reg_pc == itrace_stop)
            itrace_active = 0;
        else
            {
            fprintf(stderr,
                    "%8llu PC=$%04X $82=%02X $83=%02X SP=%03X A=%02X X=%02X Y=%02X %s %-3s %s\n",
                    (unsigned long long)insn_count, reg_pc, mem[0x82], mem[0x83],
                    reg_sp, reg_a, reg_x, reg_y, fb, mn_names[opc], ops);
            itrace_emitted++;
            }
        }

    int br = 0;
    uint8_t v, r;
    switch (opc)
        {
    case 0xA9:
    case 0xA5:
    case 0xB5:
    case 0xAD:
    case 0xBD:
    case 0xB9:
    case 0xA1:
    case 0xB1:
        reg_a = mem_read(ea);
        set_nz(reg_a);
        break;
    case 0xA2:
    case 0xA6:
    case 0xB6:
    case 0xAE:
    case 0xBE:
        reg_x = mem_read(ea);
        set_nz(reg_x);
        break;
    case 0xA0:
    case 0xA4:
    case 0xB4:
    case 0xAC:
    case 0xBC:
        reg_y = mem_read(ea);
        set_nz(reg_y);
        break;
    case 0x85:
    case 0x95:
    case 0x8D:
    case 0x9D:
    case 0x99:
    case 0x81:
    case 0x91:
        mem_write(ea, reg_a);
        break;
    case 0x86:
    case 0x96:
    case 0x8E:
        mem_write(ea, reg_x);
        break;
    case 0x84:
    case 0x94:
    case 0x8C:
        mem_write(ea, reg_y);
        break;
    case 0x69:
    case 0x65:
    case 0x75:
    case 0x6D:
    case 0x7D:
    case 0x79:
    case 0x61:
    case 0x71:
        do_adc(mem_read(ea));
        break;
    case 0xE9:
    case 0xE5:
    case 0xF5:
    case 0xED:
    case 0xFD:
    case 0xF9:
    case 0xE1:
    case 0xF1:
        do_sbc(mem_read(ea));
        break;
    case 0x29:
    case 0x25:
    case 0x35:
    case 0x2D:
    case 0x3D:
    case 0x39:
    case 0x21:
    case 0x31:
        reg_a &= mem_read(ea);
        set_nz(reg_a);
        break;
    case 0x09:
    case 0x05:
    case 0x15:
    case 0x0D:
    case 0x1D:
    case 0x19:
    case 0x01:
    case 0x11:
        reg_a |= mem_read(ea);
        set_nz(reg_a);
        break;
    case 0x49:
    case 0x45:
    case 0x55:
    case 0x4D:
    case 0x5D:
    case 0x59:
    case 0x41:
    case 0x51:
        reg_a ^= mem_read(ea);
        set_nz(reg_a);
        break;
    case 0xC9:
    case 0xC5:
    case 0xD5:
    case 0xCD:
    case 0xDD:
    case 0xD9:
    case 0xC1:
    case 0xD1:
        do_cmp(reg_a, mem_read(ea));
        break;
    case 0xE0:
    case 0xE4:
    case 0xEC:
        do_cmp(reg_x, mem_read(ea));
        break;
    case 0xC0:
    case 0xC4:
    case 0xCC:
        do_cmp(reg_y, mem_read(ea));
        break;
    case 0xE6:
    case 0xF6:
    case 0xEE:
    case 0xFE:
        v = mem_read(ea) + 1;
        mem_write(ea, v);
        set_nz(v);
        break;
    case 0xC6:
    case 0xD6:
    case 0xCE:
    case 0xDE:
        v = mem_read(ea) - 1;
        mem_write(ea, v);
        set_nz(v);
        break;
    case 0x0A:
        reg_p = (reg_p & ~FLAG_C) | ((reg_a >> 7) & FLAG_C);
        reg_a <<= 1;
        set_nz(reg_a);
        break;
    case 0x06:
    case 0x16:
    case 0x0E:
    case 0x1E:
        v = mem_read(ea);
        reg_p = (reg_p & ~FLAG_C) | ((v >> 7) & FLAG_C);
        v <<= 1;
        mem_write(ea, v);
        set_nz(v);
        break;
    case 0x4A:
        reg_p = (reg_p & ~FLAG_C) | (reg_a & FLAG_C);
        reg_a >>= 1;
        set_nz(reg_a);
        break;
    case 0x46:
    case 0x56:
    case 0x4E:
    case 0x5E:
        v = mem_read(ea);
        reg_p = (reg_p & ~FLAG_C) | (v & FLAG_C);
        v >>= 1;
        mem_write(ea, v);
        set_nz(v);
        break;
    case 0x2A:
        r = (reg_a << 1) | (reg_p & FLAG_C);
        reg_p = (reg_p & ~FLAG_C) | ((reg_a >> 7) & FLAG_C);
        reg_a = r;
        set_nz(reg_a);
        break;
    case 0x26:
    case 0x36:
    case 0x2E:
    case 0x3E:
        v = mem_read(ea);
        r = (v << 1) | (reg_p & FLAG_C);
        reg_p = (reg_p & ~FLAG_C) | ((v >> 7) & FLAG_C);
        mem_write(ea, r);
        set_nz(r);
        break;
    case 0x6A:
        r = (reg_a >> 1) | ((reg_p & FLAG_C) << 7);
        reg_p = (reg_p & ~FLAG_C) | (reg_a & FLAG_C);
        reg_a = r;
        set_nz(reg_a);
        break;
    case 0x66:
    case 0x76:
    case 0x6E:
    case 0x7E:
        v = mem_read(ea);
        r = (v >> 1) | ((reg_p & FLAG_C) << 7);
        reg_p = (reg_p & ~FLAG_C) | (v & FLAG_C);
        mem_write(ea, r);
        set_nz(r);
        break;
    case 0x24:
    case 0x2C:
        v = mem_read(ea);
        reg_p = (reg_p & ~(FLAG_N | FLAG_V | FLAG_Z)) | (v & (FLAG_N | FLAG_V));
        if (!(reg_a & v))
            reg_p |= FLAG_Z;
        break;
    case 0x10:
        if (!(reg_p & FLAG_N))
            {
            reg_pc = ea;
            br = 1;
            }
        break;
    case 0x30:
        if ((reg_p & FLAG_N))
            {
            reg_pc = ea;
            br = 1;
            }
        break;
    case 0x50:
        if (!(reg_p & FLAG_V))
            {
            reg_pc = ea;
            br = 1;
            }
        break;
    case 0x70:
        if ((reg_p & FLAG_V))
            {
            reg_pc = ea;
            br = 1;
            }
        break;
    case 0x90:
        if (!(reg_p & FLAG_C))
            {
            reg_pc = ea;
            br = 1;
            }
        break;
    case 0xB0:
        if ((reg_p & FLAG_C))
            {
            reg_pc = ea;
            br = 1;
            }
        break;
    case 0xD0:
        if (!(reg_p & FLAG_Z))
            {
            reg_pc = ea;
            br = 1;
            }
        break;
    case 0xF0:
        if ((reg_p & FLAG_Z))
            {
            reg_pc = ea;
            br = 1;
            }
        break;
    case 0x4C:
    case 0x6C:
            /* JMP $abs / JMP ($ind). Treat a self-targeted absolute
         * JMP (PC unchanged after dispatch) as program-end —
         * that's the shape of `_quit_loop: JMP _quit_loop` the
         * runtime emits after main returns. Without this the
         * sim would burn through insn_limit each run before
         * stopping, multiplying sweep time across configs. */
            {
            uint16_t old_pc = reg_pc;
            reg_pc = ea;
            br = 1;
            if (opc == 0x4C && reg_pc == old_pc)
                {
                if (!opt_dump)
                    printf("A=%02X X=%02X Y=%02X SP=%03X %s  *** halt: JMP self ***\n",
                           reg_a, reg_x, reg_y, reg_sp, fa);
                g_exit_code = reg_a; /* program's DOS return value */
                return 0;
                }
            }
        break;
    case 0x20:
        push16(reg_pc + 2);
        reg_pc = ea;
        br = 1;
        break;
    case 0x60:
        /* RTS with nothing on the stack is the program returning to its
         * loader. Atari DOS starts a program with `JSR (RUNAD)`, so on the
         * machine this RTS lands back in DOS; here the run started at an
         * empty stack (SP = $FFF), so the same RTS ends the run, with main's
         * value in A as the exit status (the xt6502 `-Q rts` quit style). */
        if (!loading && reg_sp == 0xFFF)
            {
            format_flags(fa, reg_p);
            if (!opt_dump)
                printf("A=%02X X=%02X Y=%02X SP=%03X %s  *** return to DOS ***\n",
                       reg_a, reg_x, reg_y, reg_sp, fa);
            g_exit_code = reg_a; /* program's DOS return value */
            return 0;
            }
        reg_pc = pop16() + 1;
        br = 1;
        break;
    case 0x40:
        reg_p = pop8() | 0x20;
        reg_pc = pop16();
        br = 1;
        break;
    case 0xAA:
        reg_x = reg_a;
        set_nz(reg_x);
        break;
    case 0xA8:
        reg_y = reg_a;
        set_nz(reg_y);
        break;
    case 0x8A:
        reg_a = reg_x;
        set_nz(reg_a);
        break;
    case 0x98:
        reg_a = reg_y;
        set_nz(reg_a);
        break;
    case 0xBA:
        reg_x = (uint8_t)(reg_sp & 0xFF);
        set_nz(reg_x);
        break; // TSX — SP[7:0], high bits lost
    case 0x9A:
        reg_sp = (reg_sp & 0xF00) | reg_x;
        break; // TXS — write SP[7:0], preserve SP[11:8]
    case 0x48:
        push8(reg_a);
        break;
    case 0x68:
        reg_a = pop8();
        set_nz(reg_a);
        break;
    case 0x08:
        push8(reg_p | 0x30);
        break;
    case 0x28:
        reg_p = pop8() | 0x20;
        break;
    case 0x18:
        reg_p &= ~FLAG_C;
        break;
    case 0x38:
        reg_p |= FLAG_C;
        break;
    case 0x58:
        reg_p &= ~FLAG_I;
        break;
    case 0x78:
        reg_p |= FLAG_I;
        break;
    case 0xD8:
        reg_p &= ~FLAG_D;
        break;
    case 0xF8:
        reg_p |= FLAG_D;
        break;
    case 0xB8:
        reg_p &= ~FLAG_V;
        break;
    case 0xE8:
        reg_x++;
        set_nz(reg_x);
        break;
    case 0xCA:
        reg_x--;
        set_nz(reg_x);
        break;
    case 0xC8:
        reg_y++;
        set_nz(reg_y);
        break;
    case 0x88:
        reg_y--;
        set_nz(reg_y);
        break;
    case 0xEA:
        break;

    /* ── xt CPU additions (docs/6502/6502-embellishments.md) ─── */
    /* SP-relative loads / stores / arith (§2). Operand byte is a
     * signed-8-bit offset; address is (SP + offset) within the 4 KB
     * hidden stack. Bytes always come from / go to hidden_stack,
     * never main memory. */
    /* LDA d,SP */
    case 0xB2:
        {
        int8_t d = (int8_t)mem_read(reg_pc + 1);
        opbytes = 2;
        reg_a = hidden_stack_read((reg_sp + d) & 0xFFF);
        set_nz(reg_a);
        break;
        }
    /* STA d,SP */
    case 0x92:
        {
        int8_t d = (int8_t)mem_read(reg_pc + 1);
        opbytes = 2;
        hidden_stack_write((reg_sp + d) & 0xFFF, reg_a);
        break;
        }
    /* LDX d,SP */
    case 0x42:
        {
        int8_t d = (int8_t)mem_read(reg_pc + 1);
        opbytes = 2;
        reg_x = hidden_stack_read((reg_sp + d) & 0xFFF);
        set_nz(reg_x);
        break;
        }
    /* STX d,SP */
    case 0x02:
        {
        int8_t d = (int8_t)mem_read(reg_pc + 1);
        opbytes = 2;
        hidden_stack_write((reg_sp + d) & 0xFFF, reg_x);
        break;
        }
    /* LDY d,SP */
    case 0x52:
        {
        int8_t d = (int8_t)mem_read(reg_pc + 1);
        opbytes = 2;
        reg_y = hidden_stack_read((reg_sp + d) & 0xFFF);
        set_nz(reg_y);
        break;
        }
    /* STY d,SP */
    case 0x12:
        {
        int8_t d = (int8_t)mem_read(reg_pc + 1);
        opbytes = 2;
        hidden_stack_write((reg_sp + d) & 0xFFF, reg_y);
        break;
        }
    /* ADC d,SP */
    case 0x72:
        {
        int8_t d = (int8_t)mem_read(reg_pc + 1);
        opbytes = 2;
        do_adc(hidden_stack_read((reg_sp + d) & 0xFFF));
        break;
        }
    /* SBC d,SP */
    case 0xF2:
        {
        int8_t d = (int8_t)mem_read(reg_pc + 1);
        opbytes = 2;
        do_sbc(hidden_stack_read((reg_sp + d) & 0xFFF));
        break;
        }
    /* CMP d,SP */
    case 0xD2:
        {
        int8_t d = (int8_t)mem_read(reg_pc + 1);
        opbytes = 2;
        do_cmp(reg_a, hidden_stack_read((reg_sp + d) & 0xFFF));
        break;
        }

    /* Stack-pointer indirect / indexed (§2b). The 16-bit pointer (for
     * (d,SP),Y) is fetched from the hidden stack at SP+d / SP+d+1, then
     * post-indexed by Y; the resulting access hits MAIN memory. d,SP,X
     * folds X into the stack address — the access stays in the hidden
     * stack. Both d are signed-8-bit; stack addresses mask to 12 bits
     * like the scalar §2 modes. */
    /* LDA (d,SP),Y */
    case 0x03:
        {
        int8_t d = (int8_t)mem_read(reg_pc + 1);
        opbytes = 2;
        uint16_t loA = (reg_sp + d) & 0xFFF, hiA = (loA + 1) & 0xFFF;
        uint16_t ptr = hidden_stack_read(loA) | (hidden_stack_read(hiA) << 8);
        reg_a = mem_read((uint16_t)(ptr + reg_y));
        set_nz(reg_a);
        break;
        }
    /* STA (d,SP),Y */
    case 0x13:
        {
        int8_t d = (int8_t)mem_read(reg_pc + 1);
        opbytes = 2;
        uint16_t loA = (reg_sp + d) & 0xFFF, hiA = (loA + 1) & 0xFFF;
        uint16_t ptr = hidden_stack_read(loA) | (hidden_stack_read(hiA) << 8);
        uint16_t target = (uint16_t)(ptr + reg_y);
        /* PROBE: log all STA (d,SP),Y writes during execution */
        if (!loading)
            {
            static int sta_spy_cnt = 0;
            if (sta_spy_cnt++ < 30)
                fprintf(stderr, "STA_SPY PC=$%04X d=%d loA=$%03X hiA=$%03X lo=%02X hi=%02X ptr=$%04X Y=$%02X target=$%04X A=$%02X $83=$%02X SP=$%03X\n",
                        reg_pc, d, loA, hiA, hidden_stack_read(loA), hidden_stack_read(hiA), ptr, reg_y, target, reg_a, mem[0x83], reg_sp);
            }
        /* PROBE: log writes to ZP below $82 — that's reserved space */
        if (target < 0x82 && !loading)
            {
            fprintf(stderr, "ZP_WRITE target=$%04X ptr=$%04X Y=$%02X A=$%02X PC=$%04X d=$%02X SP=%03X\n",
                    target, ptr, reg_y, reg_a, reg_pc, d, reg_sp);
            /* Dump the stack frame around the pointer to understand */
            fprintf(stderr, "  SP+0D=%02X SP+0E=%02X SP+0F=%02X SP+10=%02X\n",
                    hidden_stack_read((reg_sp + 0x0D) & 0xFFF),
                    hidden_stack_read((reg_sp + 0x0E) & 0xFFF),
                    hidden_stack_read((reg_sp + 0x0F) & 0xFFF),
                    hidden_stack_read((reg_sp + 0x10) & 0xFFF));
            fprintf(stderr, "  SP+13=%02X SP+14=%02X SP+15=%02X SP+16=%02X\n",
                    hidden_stack_read((reg_sp + 0x13) & 0xFFF),
                    hidden_stack_read((reg_sp + 0x14) & 0xFFF),
                    hidden_stack_read((reg_sp + 0x15) & 0xFFF),
                    hidden_stack_read((reg_sp + 0x16) & 0xFFF));
            fprintf(stderr, "  SP+17=%02X SP+18=%02X SP+19=%02X SP+1A=%02X\n",
                    hidden_stack_read((reg_sp + 0x17) & 0xFFF),
                    hidden_stack_read((reg_sp + 0x18) & 0xFFF),
                    hidden_stack_read((reg_sp + 0x19) & 0xFFF),
                    hidden_stack_read((reg_sp + 0x1A) & 0xFFF));
            fprintf(stderr, "  mem[82]=%02X mem[83]=%02X mem[84]=%02X\n",
                    mem[0x82], mem[0x83], mem[0x84]);
            }
        mem_write(target, reg_a);
        break;
        }
    /* LDA d,SP,X */
    case 0x23:
        {
        int8_t d = (int8_t)mem_read(reg_pc + 1);
        opbytes = 2;
        reg_a = hidden_stack_read((reg_sp + d + reg_x) & 0xFFF);
        set_nz(reg_a);
        break;
        }
    /* STA d,SP,X */
    case 0x33:
        {
        int8_t d = (int8_t)mem_read(reg_pc + 1);
        opbytes = 2;
        hidden_stack_write((reg_sp + d + reg_x) & 0xFFF, reg_a);
        break;
        }

    /* ADD SP, #signed8 — §2 "Stack adjustment".
     * Clamps to $000..$FFF (saturates rather than wrapping). No flags
     * modified. */
    case 0x22:
        {
        int8_t d = (int8_t)mem_read(reg_pc + 1);
        opbytes = 2;
        int32_t newSp = (int32_t)reg_sp + d;
        if (newSp < 0)
            newSp = 0;
        else if (newSp > 0xFFF)
            newSp = 0xFFF;
        reg_sp = (uint16_t)newSp;
        break;
        }

    /* PSH #N — §3 "Housekeeping". Allocates frame_size = N + 7 bytes
     * (1 guard byte + 6 saved-register slots + N locals), then writes
     * the 6 saved-register slots at fixed offsets ABOVE the guard byte:
     * +1 P, +2 SP_lo, +3 SP_hi, +4 Y, +5 X, +6 A. SP+0 is the GUARD
     * byte — left unwritten and free for the next push, so a nested
     * JSR/PHA/IRQ return-address push lands there instead of clobbering
     * saved P (private:docs/bugs/005, fixed in sally; the guard byte). Atomic
     * w.r.t. interrupts; simulated by executing inline. */
    case 0x32:
        {
        uint8_t N = mem_read(reg_pc + 1);
        opbytes = 2;
        uint16_t entry_sp = reg_sp;
        uint32_t frame_size = (uint32_t)N + 7;
        int32_t newSp = (int32_t)reg_sp - (int32_t)frame_size;
        if (newSp < 0)
            newSp = 0;
        reg_sp = (uint16_t)newSp;
        hidden_stack_write((reg_sp + 6) & 0xFFF, reg_a);
        hidden_stack_write((reg_sp + 5) & 0xFFF, reg_x);
        hidden_stack_write((reg_sp + 4) & 0xFFF, reg_y);
        hidden_stack_write((reg_sp + 3) & 0xFFF, (entry_sp >> 8) & 0x0F);
        hidden_stack_write((reg_sp + 2) & 0xFFF, entry_sp & 0xFF);
        hidden_stack_write((reg_sp + 1) & 0xFFF, reg_p | 0x20);
        /* stack8(SP+0) = guard byte, intentionally left unwritten. */
        break;
        }
    /* PLL #N — restore the 6 saved-register slots (SP+1..SP+6), then
     * deallocate the frame. SP_lo / SP_hi are saved for diagnostics
     * only; PLL computes the final SP as SP += (N + 7) (incl. the guard
     * byte), relying on body pushes/pops to be balanced. */
    case 0x62:
        {
        uint8_t N = mem_read(reg_pc + 1);
        opbytes = 2;
        reg_p = hidden_stack_read((reg_sp + 1) & 0xFFF) | 0x20;
        (void)hidden_stack_read((reg_sp + 2) & 0xFFF); /* saved SP_lo, diagnostic only */
        (void)hidden_stack_read((reg_sp + 3) & 0xFFF); /* saved SP_hi, diagnostic only */
        reg_y = hidden_stack_read((reg_sp + 4) & 0xFFF);
        reg_x = hidden_stack_read((reg_sp + 5) & 0xFFF);
        reg_a = hidden_stack_read((reg_sp + 6) & 0xFFF);
        uint32_t frame_size = (uint32_t)N + 7;
        int32_t newSp = (int32_t)reg_sp + (int32_t)frame_size;
        if (newSp > 0xFFF)
            newSp = 0xFFF;
        reg_sp = (uint16_t)newSp;
        break;
        }

    /* Direct push/pop of X and Y (§2). POP Y resolved to $74 (not
     * $64 as the doc draft listed — see STACK-ABI.md §9). */
    case 0x44:
        push8(reg_x);
        break; /* PHX */
    case 0x54:
        push8(reg_y);
        break; /* PHY */
    case 0x64:
        reg_x = pop8();
        set_nz(reg_x);
        break; /* PLX */
    case 0x74:
        reg_y = pop8();
        set_nz(reg_y);
        break; /* PLY */

    /* BRA — 65C02-style unconditional branch (§2). Signed-8-bit
     * relative, target = PC + 2 + offset. Address-mode AM_REL
     * already computed `ea` into the dispatch's `ea` global. */
    case 0x80:
        reg_pc = ea;
        br = 1;
        break;

    case 0x00:
        format_flags(fa, reg_p);
        if (!opt_dump)
            printf("A=%02X X=%02X Y=%02X SP=%03X %s  *** BRK ***\n", reg_a, reg_x, reg_y, reg_sp, fa);
        g_exit_code = reg_a; /* program's DOS return value */
        return 0;
    default:
        format_flags(fa, reg_p);
        if (!opt_dump)
            printf("A=%02X X=%02X Y=%02X SP=%03X %s  ??? $%02X\n", reg_a, reg_x, reg_y, reg_sp, fa, opc);
        fprintf(stderr, "xts: illegal opcode $%02X at $%04X — run aborted\n", opc, reg_pc);
        g_exit_code = XTS_EXIT_ILLEGAL_OPCODE;
        return -1;
        }

    format_flags(fa, reg_p);
    if (!opt_dump)
        printf("A=%02X X=%02X Y=%02X SP=%03X %s\n", reg_a, reg_x, reg_y, reg_sp, fa);
    if (!br)
        reg_pc += opbytes;
    insn_count++;
    if (insn_limit && insn_count >= insn_limit)
        {
        fprintf(stderr, "sim6502: instruction limit %llu exceeded\n",
                (unsigned long long)insn_limit);
        g_exit_code = XTS_EXIT_INSN_LIMIT;
        return -1;
        }
    return 1;
    }

/* ── Screen dump ───────────────────────────────────────────────────── */

static char screen_code_to_ascii(uint8_t sc)
    {
    /* Atari internal screen codes to ASCII:
       $00-$1F → ATASCII $20-$3F → ASCII space!"#$%&'()*+,-./0-9:;<=>?
       $20-$3F → ATASCII $40-$5F → ASCII @A-Z[\]^_
       $40-$5F → ATASCII $00-$1F → control chars (graphics blocks) → '.'
       $60-$7F → ATASCII $60-$7F → ASCII `a-z{|}~
       $80-$FF → inverse video of $00-$7F */
    sc &= 0x7F;
    char ch;
    if (sc < 0x20)
        ch = (char)(sc + 0x20); /* $00-$1F → space-? */
    else if (sc < 0x40)
        ch = (char)(sc + 0x20); /* $20-$3F → @A-Z[\]^_ */
    else if (sc < 0x60)
        ch = '.'; /* $40-$5F → graphics */
    else
        ch = (char)(sc); /* $60-$7F → lowercase */
    if (ch < 0x20 || ch > 0x7E)
        ch = '.';
    return ch;
    }

static void dump_screen(void)
    {
    uint16_t base = mem[0x58] | ((uint16_t)mem[0x59] << 8);
    printf("\n+----------------------------------------+\n");
    for (int row = 0; row < 24; row++)
        {
        printf("|");
        for (int col = 0; col < 40; col++)
            {
            uint8_t sc = mem[base + row * 40 + col];
            printf("%c", screen_code_to_ascii(sc));
            }
        printf("|\n");
        }
    printf("+----------------------------------------+\n");
    }

/* ── Loaders ───────────────────────────────────────────────────────── */

static uint16_t run_addr = 0;

/* Run the code at `addr` as if it were a JSR'd subroutine: push a
 * sentinel return address, set PC=addr, step until RTS pops the
 * sentinel. Used by load_xex to execute INITAD after each segment;
 * in xt mode this is a preload stub that sets `$82/$83` to the
 * bank id for the NEXT segment so its bytes stream straight into
 * bank[bid] through mem_write.
 */
static void run_until_return(uint16_t addr)
    {
    /* Push a sentinel return address — RTS adds 1 to what it
     * pops, so pushing $FFFE here leaves PC=$FFFF on return. */
    push8(0xFF);
    push8(0xFE);
    int saved_dump = opt_dump;
    opt_dump = 1; /* squelch the insn trace during INITAD runs */
    reg_pc = addr;
    for (int steps = 0; steps < 1000000; steps++)
        {
        if (reg_pc == 0xFFFF)
            break;
        if (step() <= 0)
            break; /* 0 = clean halt, -1 = abnormal stop */
        }
    opt_dump = saved_dump;
    }

/* Scan a preload-stub-shaped segment buffer for `STA <addr>`
   instructions. The xta XEX writer emits stubs of the form
   `LDA #imm / STA <bankReg> [/ ...] / RTS` for every banked page,
   so the addresses written are the program's bank-select registers.
   Records up to 4 distinct addresses into `out[]`; returns the
   number found. Used by the auto-detect pass below. */
static int extract_stub_sta_addrs(const uint8_t* buf, size_t len,
                                  uint16_t out[4])
    {
    int found = 0;
    size_t i = 0;
    while (i < len)
        {
        uint8_t op = buf[i];
        if (op == 0xA9 && i + 1 < len)
            {
            i += 2; /* LDA #imm */
            }
        else if (op == 0x85 && i + 1 < len)
            {
            uint16_t a = buf[i + 1];
            if (found < 4)
                out[found++] = a;
            i += 2; /* STA zp */
            }
        else if (op == 0x8D && i + 2 < len)
            {
            uint16_t a = buf[i + 1] | ((uint16_t)buf[i + 2] << 8);
            if (found < 4)
                out[found++] = a;
            i += 3; /* STA abs */
            }
        else if (op == 0x60)
            {
            break; /* RTS */
            }
        else
            {
            i++; /* other opcodes — give up gracefully */
            }
        }
    return found;
    }

static int load_xex(const char* fn)
    {
    FILE* f = fopen(fn, "rb");
    if (!f)
        {
        fprintf(stderr, "sim6502: cannot open '%s'\n", fn);
        return 0;
        }
    loading = 1;
    int seg4 = 0;
    /* Auto-detect bank register addresses from preload stubs.
       Each xta-emitted stub at $03FD writes one or two bank
       registers in sequence — we record the addresses observed
       across all stubs and pick the most-frequent two as
       code/data. Skipped when the user passed --code-reg /
       --data-reg / --regc-reg (bank_reg_addrs_explicit). */
    uint16_t observed[16] = {0};
    int observed_count[16] = {0};
    int observed_n = 0;
    /* INITAD is latched when a segment writes to $02E2/$02E3. After
     * each subsequent segment load (other than the one that just
     * set it) Atari DOS calls that address to run init code. The
     * xt XEX writer uses a preload INITAD stub on every banked
     * segment: the stub sets $82/$83 to the target bank id, then
     * the following segment's bytes stream into the $4000-$7FFF
     * window and mem_write routes them into bank[bid] because
     * banked_mode is on. */
    int have_initad = 0;
    uint16_t initad_addr = 0;
    while (!feof(f))
        {
        uint8_t h[4];
        if (fread(h, 1, 2, f) != 2)
            break;
        if (h[0] == 0xFF && h[1] == 0xFF)
            {
            if (fread(h, 1, 4, f) != 4)
                break;
            }
        else
            {
            if (fread(h + 2, 1, 2, f) != 2)
                break;
            }
        uint16_t s = h[0] | ((uint16_t)h[1] << 8), e = h[2] | ((uint16_t)h[3] << 8);
        if (e < s)
            continue; /* placeholder 0-byte segments */
        /* A segment targeting $4000-$7FFF is a banked page payload;
         * flip banked_mode so mem_write routes its bytes through
         * bank[current_bank()]. The preload INITAD stub that ran
         * before this segment has already set $82/$83 to the bank
         * id. */
        if (s >= 0x4000 && s < 0x8000 && !banked_mode && !bank_mode_explicit)
            {
            banked_mode = 1;
            if (bank_mode == BANK_NONE)
                bank_mode = BANK_XT;
            /* Banked models use main code at $A000-$BFFF, so the
               default $BC00 screen would collide. Move SAVMSC down
               into the $8000-$9FFF reserved region. xl programs
               keep the $BC00 default. */
            mem[0x58] = 0x00;
            mem[0x59] = 0x80;
            }
        if (s >= 0x4000 && s < 0x8000)
            seg4++;
        /* If this segment is a preload stub (loaded into $03FD,
           length 5-10 bytes), peek at its STA opcodes to record
           which bank registers it touches. */
        if (s == 0x03FD && (e - s + 1) <= 12 && !bank_reg_addrs_explicit)
            {
            /* The two-register code+data stub (LDA/STA $D5C0, LDA/STA $D5C1,
               RTS) is 11 bytes — the old `<= 10` bound skipped it, so only the
               6-byte code-only stub was seen and the DATA reg was never
               detected (stayed at the legacy $83). Widened to 12. (bug 020) */
            uint8_t buf[12];
            long bookmark = ftell(f);
            size_t got = fread(buf, 1, e - s + 1, f);
            fseek(f, bookmark, SEEK_SET);
            uint16_t addrs[4];
            int n = extract_stub_sta_addrs(buf, got, addrs);
            for (int k = 0; k < n; k++)
                {
                int found = 0;
                for (int j = 0; j < observed_n; j++)
                    {
                    if (observed[j] == addrs[k])
                        {
                        observed_count[j]++;
                        found = 1;
                        break;
                        }
                    }
                if (!found && observed_n < 16)
                    {
                    observed[observed_n] = addrs[k];
                    observed_count[observed_n] = 1;
                    observed_n++;
                    }
                }
            /* Apply the observed registers IMMEDIATELY — before the banked
               payload segments stream in below (mem_write routes them through
               bank[current_bank()], which reads code_reg_addr). If it's still
               the $82 default when a payload streams, current_bank() reads $82
               (=0) and the code loads into bank 0 instead of the stub's target
               bank → the banked function is missing at run time and a bare
               `xts file.xex` BRKs. `-m xt` set the regs up front, which is why
               it worked. The final resolve after the load loop confirms them.
               (bug 020) */
            if (code_reg_addr == 0x82 && observed_n >= 1 && observed[0] != PORTB_ADDR)
                {
                code_reg_addr = observed[0];
                if (observed_n >= 2 && observed[1] != PORTB_ADDR)
                    data_reg_addr = observed[1];
                else if (observed[0] == 0xD5C0) /* xt: data reg is code+1 */
                    data_reg_addr = 0xD5C1;
                }
            }
        for (uint16_t i = 0; i <= e - s; i++)
            {
            uint8_t b;
            if (fread(&b, 1, 1, f) != 1)
                break;
            mem_write(s + i, b);
            }
        if (s <= 0x02E0 && e >= 0x02E1)
            run_addr = mem[0x02E0] | ((uint16_t)mem[0x02E1] << 8);
        if (s <= 0x02E2 && e >= 0x02E3)
            {
            have_initad = 1;
            initad_addr = mem[0x02E2] | ((uint16_t)mem[0x02E3] << 8);
            }
        else if (have_initad)
            {
            /* A segment that isn't the INITAD pointer itself: run
             * the latched init routine. The copier has an RTS and
             * our fake return address lands in the $FFFF sentinel
             * watched for by run_until_return. */
            run_until_return(initad_addr);
            }
        }
    fclose(f);
    loading = 0;
    /* Resolve auto-detected bank registers. Pick the two most-
       written addresses as code + data (in observation order, so
       code = first observed = first stub's first STA), and any
       remaining as regC lo/hi. The xta stub layout writes code-
       page stubs first when present, so this matches the codegen
       convention. PORTB ($D301) is treated as xe and ignored
       here (it's its own well-known address — we don't tunnel
       PORTB-banking through the xt code/data slots). */
    if (!bank_reg_addrs_explicit && observed_n > 0)
        {
        uint16_t cands[16];
        int cn = 0;
        for (int j = 0; j < observed_n; j++)
            {
            if (observed[j] == PORTB_ADDR)
                continue;
            cands[cn++] = observed[j];
            }
        if (cn >= 1)
            code_reg_addr = cands[0];
        if (cn >= 2)
            data_reg_addr = cands[1];
        if (cn >= 3)
            regc_reg_lo_addr = cands[2];
        if (cn >= 4)
            regc_reg_hi_addr = cands[3];
        if (code_reg_addr != 0x82 || data_reg_addr != 0x83 ||
            regc_reg_lo_addr != 0x84 || regc_reg_hi_addr != 0x85)
            {
            fprintf(stderr,
                    "sim6502: auto-detected bank regs:"
                    " code=$%04X data=$%04X",
                    code_reg_addr, data_reg_addr);
            if (cn >= 3)
                {
                fprintf(stderr, " regC=$%04X", regc_reg_lo_addr);
                if (cn >= 4 && regc_reg_hi_addr != regc_reg_lo_addr)
                    {
                    fprintf(stderr, ":$%04X", regc_reg_hi_addr);
                    }
                }
            fprintf(stderr, "\n");
            }
        }
    if (seg4 > 0 && !bank_mode_explicit)
        {
        banked_mode = 1;
        if (bank_mode == BANK_NONE)
            bank_mode = BANK_XT;
        const char* modeName = (bank_mode == BANK_XE) ? "xe" : "xt";
        fprintf(stderr, "sim6502: %s mode (%d bank segments)\n",
                modeName, seg4);
        }
    return 1;
    }

/* Parse a numeric literal supporting $hex, 0xhex, decimal, octal. */
static unsigned long parse_num(const char* s, char** ep)
    {
    if (*s == '$')
        {
        return strtoul(s + 1, ep, 16);
        }
    return strtoul(s, ep, 0);
    }

static void load_map(const char* fn)
    {
    FILE* f = fopen(fn, "r");
    if (!f)
        {
        fprintf(stderr, "xts: cannot open map '%s'\n", fn);
        return;
        }
    uint16_t addr = 0;
    int ha = 0;
    char buf[4096];
    while (fgets(buf, sizeof(buf), f))
        {
        char* p = buf;
        while (*p)
            {
            while (*p && isspace(*p))
                p++;
            if (!*p || *p == '#')
                break;
            char* c = strchr(p, ':');
            if (c && c > p)
                {
                char ns[64];
                int l = (int)(c - p);
                if (l > 63)
                    l = 63;
                strncpy(ns, p, l);
                ns[l] = 0;
                addr = (uint16_t)parse_num(ns, NULL);
                ha = 1;
                p = c + 1;
                continue;
                }
            if (!ha)
                {
                p++;
                continue;
                }
            char* ep;
            unsigned long v = parse_num(p, &ep);
            if (ep == p)
                {
                p++;
                continue;
                }
            mem[addr++] = (uint8_t)(v & 0xFF);
            p = ep;
            }
        }
    fclose(f);
    }

/* Load an Atari OS ROM image (10KB, mapped at $D800-$FFFF).
   Also seeds mem[] so that code loaded before the ROM (e.g. the
   startup's vector writes at $FFFA-$FFFF) ends up in shadow RAM,
   while the rom[] array holds the OS image for read-back when ROM
   is enabled. */
static int load_rom(const char* fn)
    {
    FILE* f = fopen(fn, "rb");
    if (!f)
        {
        fprintf(stderr, "xts: cannot open ROM '%s'\n", fn);
        return 0;
        }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz != ROM_SIZE)
        {
        fprintf(stderr, "xts: ROM '%s' is %ld bytes, expected %d\n",
                fn, sz, ROM_SIZE);
        fclose(f);
        return 0;
        }
    if (fread(rom, 1, ROM_SIZE, f) != ROM_SIZE)
        {
        fprintf(stderr, "xts: short read on ROM '%s'\n", fn);
        fclose(f);
        return 0;
        }
    fclose(f);
    // Copy ROM into mem[] so the OS vectors are visible at boot
    // (before the startup code banks out ROM and installs
    // shadow-RAM vectors, the CPU sees ROM at $D800-$FFFF).
    memcpy(&mem[ROM_BASE], rom, ROM_SIZE);
    rom_loaded = 1;
    return 1;
    }

/* ── Main ──────────────────────────────────────────────────────────── */

static void sigint_handler(int s)
    {
    (void)s;
    running = 0;
    }

static void print_usage(FILE* f)
    {
    fprintf(f,
            "Usage: xts [options] <file.xex> [map]\n"
            "\n"
            "A 6502 simulator for Atari XEX binaries produced by xtc/xta.\n"
            "\n"
            "Arguments:\n"
            "  <file.xex>     Atari XEX binary to load and execute.\n"
            "  [map]          Optional memory prefill file. Lines have the form\n"
            "                 'ADDR: b0 b1 b2 ...' where ADDR is a hex ($xx or\n"
            "                 0xXX), decimal, or octal address and each byte is\n"
            "                 written sequentially starting at ADDR. '#' starts\n"
            "                 a comment. Use this to seed OS variables, I/O\n"
            "                 registers, or test fixtures before execution.\n"
            "\n"
            "Options:\n"
            "  -h, --help        Show this help message and exit.\n"
            "  -v, --version     Print version and exit.\n"
            "  -g0               After execution, dump the Atari GR.0 text screen\n"
            "                    (40x24) read from screen memory at SAVMSC ($9C00).\n"
            "  --cycles         Print instruction count at exit (even with -d).\n"
            "  -d, --dump-output Suppress the instruction trace and screen border.\n"
            "                    Bytes written to screen memory are decoded and\n"
            "                    streamed to stdout in order, with newlines emitted\n"
            "                    for row transitions and spaces for column gaps.\n"
            "                    Intended for tests that print 'PASS' or 'FAIL'.\n"
            "  -r, --rom <file>  Load an Atari OS ROM image (10KB) into $D800-$FFFF.\n"
            "                    Enables shadow-mode simulation: PORTB bits control\n"
            "                    whether reads from that range return ROM or RAM.\n"
            "  --shadow-mask <hex>  PORTB bitmask for shadow ROM control (default $01).\n"
            "                    When the masked bit(s) are SET, ROM is visible;\n"
            "                    when CLEARED, shadow RAM is exposed underneath.\n"
            "  --nmi-interval <N>  Fire a simulated NMI every N instructions.\n"
            "                    Tests the shadow-mode NMI trampoline. 0 = off.\n"
            "  --code-reg <hex>  Bank register for the code half of the bank window.\n"
            "                    Default $82 (the standard Atari xt convention).\n"
            "                    Use to simulate cart-mapped layouts where the\n"
            "                    register lives outside zero page (e.g. $C300).\n"
            "  --data-reg <hex>  Bank register for the data half. Default $83.\n"
            "  --regc-reg <addr> Bank register for region C. Pass either a single\n"
            "                    address ($XX), or two ($XX:$YY) for a 16-bit pair.\n"
            "                    Default $84:$85.\n"
            "                    When the program's preload stubs touch the bank\n"
            "                    registers (the xta-emitted ones do), the loader\n"
            "                    auto-detects the addresses; the flags only need\n"
            "                    to be set explicitly when auto-detect can't.\n"
            "  -m, --memory-model <spec>  Force a memory model. Accepts:\n"
            "                    xl (flat), xt (one 16 KB code-bank window at\n"
            "                    $6000-$9FFF via $D5C0, $A000-$CFFF data window\n"
            "                    via $D5C1, screen at $4000-$5FFF),\n"
            "                    xe[:size:mask].\n"
            "  -z, --zp-banking  Enable hardware ZP banking (xt only).\n"
            "                    Writes to the code selector atomically swap three\n"
            "                    16-byte ZP\n"
            "                    regions ($A0-$AF, $C0-$CF, $D0-$DF) along with\n"
            "                    the code window. Off by default until the\n"
            "                    codegen migrates globals out of $C0-$DF.\n"
            "\n"
            "Execution:\n"
            "  The simulator starts at the XEX RUNAD (or $2000 if unset) and runs\n"
            "  until the program ends or Ctrl-C, printing an instruction trace to\n"
            "  stdout along with register state. The program ends at an RTS with\n"
            "  an empty stack (a return to the loader), a BRK, or a JMP to itself;\n"
            "  A is then the exit status. Instruction count is reported on exit.\n");
    }

/* Patch mn_modes and mn_names for the xt CPU additions. The
 * vanilla 6502 dispatch slots are unchanged; we only register
 * addressing modes and disassembly mnemonics for the previously-JAM
 * opcodes the xt CPU repurposes. */
static void install_xt_opcode_modes(void)
    {
    /* §2b stack-indirect / indexed — 2-byte signed offset operand. */
    mn_modes[0x03] = AM_IMM;
    mn_names[0x03] = "LDA"; /* LDA (d,SP),Y */
    mn_modes[0x13] = AM_IMM;
    mn_names[0x13] = "STA"; /* STA (d,SP),Y */
    mn_modes[0x23] = AM_IMM;
    mn_names[0x23] = "LDA"; /* LDA d,SP,X */
    mn_modes[0x33] = AM_IMM;
    mn_names[0x33] = "STA"; /* STA d,SP,X */
    mn_modes[0x02] = AM_IMM;
    mn_names[0x02] = "STX"; /* STX d,SP */
    mn_modes[0x12] = AM_IMM;
    mn_names[0x12] = "STY"; /* STY d,SP */
    mn_modes[0x22] = AM_IMM;
    mn_names[0x22] = "ADD"; /* ADD SP,#imm */
    mn_modes[0x32] = AM_IMM;
    mn_names[0x32] = "PSH";
    mn_modes[0x42] = AM_IMM;
    mn_names[0x42] = "LDX"; /* LDX d,SP */
    /* $44, $54, $64, $74 (PHX/PHY/PLX/PLY) are already AM_IMP. */
    mn_names[0x44] = "PHX";
    mn_names[0x54] = "PHY";
    mn_names[0x64] = "PLX";
    mn_names[0x74] = "PLY";
    mn_modes[0x52] = AM_IMM;
    mn_names[0x52] = "LDY"; /* LDY d,SP */
    mn_modes[0x62] = AM_IMM;
    mn_names[0x62] = "PLL";
    mn_modes[0x72] = AM_IMM;
    mn_names[0x72] = "ADC"; /* ADC d,SP */
    mn_modes[0x80] = AM_REL;
    mn_names[0x80] = "BRA";
    mn_modes[0x92] = AM_IMM;
    mn_names[0x92] = "STA"; /* STA d,SP */
    mn_modes[0xB2] = AM_IMM;
    mn_names[0xB2] = "LDA"; /* LDA d,SP */
    mn_modes[0xD2] = AM_IMM;
    mn_names[0xD2] = "CMP"; /* CMP d,SP */
    mn_modes[0xF2] = AM_IMM;
    mn_names[0xF2] = "SBC"; /* SBC d,SP */
    }

int main(int argc, char* argv[])
    {
    install_xt_opcode_modes();
    /* Targeted instruction trace (task #122) — env-gated, see globals. */
    if (getenv("XTS_ITRACE"))
        itrace_enabled = 1;
    if (getenv("XTS_ITRACE_TRIGGER"))
        {
        itrace_has_trig = 1;
        itrace_trigger = (uint16_t)strtoul(getenv("XTS_ITRACE_TRIGGER"), NULL, 16);
        }
    if (getenv("XTS_ITRACE_STOP"))
        {
        itrace_has_stop = 1;
        itrace_stop = (uint16_t)strtoul(getenv("XTS_ITRACE_STOP"), NULL, 16);
        }
    if (getenv("XTS_ITRACE_MAX"))
        itrace_max = strtoull(getenv("XTS_ITRACE_MAX"), NULL, 0);
    if (getenv("XTS_ITRACE_AFTER"))
        itrace_after = strtoull(getenv("XTS_ITRACE_AFTER"), NULL, 0);
    if (getenv("XTS_WATCH_SP"))
        {
        watch_sp_on = 1;
        watch_sp_addr = (uint16_t)(strtoul(getenv("XTS_WATCH_SP"), NULL, 16) & 0xFFF);
        }
    if (getenv("XTS_RTCLOK_INSNS"))
        {
        rtclok_insns_per_tick = strtoull(getenv("XTS_RTCLOK_INSNS"), NULL, 0);
        }
    itrace_active = itrace_enabled;
    const char *xex = NULL, *mapf = NULL;
    for (int i = 1; i < argc; i++)
        {
        if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help"))
            {
            print_usage(stdout);
            return 0;
            }
        else if (!strcmp(argv[i], "-v") || !strcmp(argv[i], "--version"))
            {
            printf("xts %s\n", XTC_VERSION);
            return 0;
            }
        else if (!strcmp(argv[i], "-d") || !strcmp(argv[i], "--dump-output"))
            opt_dump = 1;
        else if (!strcmp(argv[i], "-g0"))
            opt_g0 = 1;
        else if (!strcmp(argv[i], "--cycles"))
            opt_cycles = 1;
        else if (!strcmp(argv[i], "-z") || !strcmp(argv[i], "--zp-banking"))
            zp_banking_enabled = 1;
        else if (!strcmp(argv[i], "-M") || !strcmp(argv[i], "--max-insns"))
            {
            if (i + 1 >= argc)
                {
                fprintf(stderr, "xts: -M requires an argument\n");
                return 1;
                }
            insn_limit = strtoull(argv[++i], NULL, 0);
            }
        else if (!strcmp(argv[i], "-m") || !strcmp(argv[i], "--memory-model"))
            {
            /* `xt` is the default (auto-detected). For xe, the spec
               is `xe:<hex-mask>` — the mask names the PORTB bits
               the runtime writes to select banks. We don't care
               about the size field here, only the mask. */
            if (i + 1 >= argc)
                {
                fprintf(stderr, "xts: -m requires an argument\n");
                return 1;
                }
            const char* spec = argv[++i];
            if (!strcmp(spec, "xt") || !strcmp(spec, "xl"))
                {
                /* xt: one 16 KB code-bank window at $6000-$9FFF via the
                   8-bit code selector ($D5C0, 4 MB), plus the $A000-$CFFF
                   data window via $D5C1. Screen RAM at $4000-$5FFF, SAVMSC
                   = $4000. xl is unbanked. */
                if (spec[1] == 't')
                    {
                    bank_mode = BANK_XT;
                    banked_mode = 1;
                    mem[0x58] = 0x00;
                    mem[0x59] = 0x40;
                    /* The xt core fixes the bank selectors at $D5C0 (code)
                       / $D5C1 (data) — memory-mapped registers in
                       cartridge-control space (read/writable, no CCTL
                       effect), out of ZP so the boot RAM-clear can't zero
                       them. Anchor the defaults here; a banked .xex's
                       preload stubs confirm them via the load-time scan,
                       and --code-reg / --data-reg still override. */
                    if (!bank_reg_addrs_explicit)
                        {
                        code_reg_addr = 0xD5C0;
                        data_reg_addr = 0xD5C1;
                        }
                    }
                else
                    {
                    bank_mode = BANK_NONE;
                    }
                bank_mode_explicit = 1;
                }
            else if (!strncmp(spec, "xe", 2))
                {
                /* Accept `xe`, `xe:<mask>`, `xe:<size>:<mask>`. */
                const char* p = strchr(spec, ':');
                uint8_t mask = 0x0C; /* default for bare `xe` */
                if (p)
                    {
                    const char* q = strchr(p + 1, ':');
                    const char* maskStr = q ? q + 1 : p + 1;
                    char* ep;
                    mask = (uint8_t)strtoul(maskStr, &ep, 16);
                    if (*ep)
                        {
                        fprintf(stderr, "xts: bad xe mask '%s'\n", maskStr);
                        return 1;
                        }
                    }
                bank_mode = BANK_XE;
                xe_mask = mask;
                /* Note: don't set bank_mode_explicit here. The xe
                   load path relies on the auto-detect post-load step
                   to wire up banked_mode + SAVMSC ($58/$59), which
                   the explicit-skip would bypass. xe-shadow doesn't
                   need the explicit skip because its staging segment
                   at $4000 IS a real banked write (bank 0 = main RAM
                   on xe with banking off). */
                }
            else
                {
                fprintf(stderr, "xts: unknown memory model '%s'\n", spec);
                return 1;
                }
            }
        else if (!strcmp(argv[i], "-r") || !strcmp(argv[i], "--rom"))
            {
            if (i + 1 >= argc)
                {
                fprintf(stderr, "xts: -r requires a filename\n");
                return 1;
                }
            if (!load_rom(argv[++i]))
                return 1;
            }
        else if (!strcmp(argv[i], "--shadow-mask"))
            {
            if (i + 1 >= argc)
                {
                fprintf(stderr, "xts: --shadow-mask requires a hex value\n");
                return 1;
                }
            shadow_mask = (uint8_t)strtoul(argv[++i], NULL, 16);
            }
        else if (!strcmp(argv[i], "--nmi-interval"))
            {
            if (i + 1 >= argc)
                {
                fprintf(stderr, "xts: --nmi-interval requires a number\n");
                return 1;
                }
            nmi_interval = strtoull(argv[++i], NULL, 0);
            }
        else if (!strcmp(argv[i], "--code-reg"))
            {
            if (i + 1 >= argc)
                {
                fprintf(stderr, "xts: --code-reg requires a hex addr\n");
                return 1;
                }
            code_reg_addr = (uint16_t)strtoul(argv[++i], NULL, 16);
            bank_reg_addrs_explicit = 1;
            }
        else if (!strcmp(argv[i], "--data-reg"))
            {
            if (i + 1 >= argc)
                {
                fprintf(stderr, "xts: --data-reg requires a hex addr\n");
                return 1;
                }
            data_reg_addr = (uint16_t)strtoul(argv[++i], NULL, 16);
            bank_reg_addrs_explicit = 1;
            }
        else if (!strcmp(argv[i], "--regc-reg"))
            {
            /* Accept "$lo" or "$lo:$hi" for the 16-bit pair. */
            if (i + 1 >= argc)
                {
                fprintf(stderr, "xts: --regc-reg requires a hex addr or addr:addr\n");
                return 1;
                }
            const char* spec = argv[++i];
            char* p;
            regc_reg_lo_addr = (uint16_t)strtoul(spec, &p, 16);
            if (*p == ':')
                {
                regc_reg_hi_addr = (uint16_t)strtoul(p + 1, NULL, 16);
                }
            bank_reg_addrs_explicit = 1;
            }
        else if (argv[i][0] == '-')
            {
            fprintf(stderr, "xts: unknown option '%s'\n", argv[i]);
            print_usage(stderr);
            return 1;
            }
        else if (!xex)
            xex = argv[i];
        else if (!mapf)
            mapf = argv[i];
        }
    if (!xex)
        {
        print_usage(stderr);
        return 1;
        }

    memset(mem, 0, sizeof(mem));
    /* Default SAVMSC at $BC00 for xl, bumped to $8000 for any
       banked target. xl programs have code/data spanning
       $2000-$9FFF, so their screen has to sit above $9FFF
       (we pick $BC00). xt/xe have main code at $A000-$BFFF (and
       $A000-$CFFF on shadow variants), so their screen goes in
       the reserved $8000-$9FFF region instead. Earlier we
       defaulted to $BC00 for everyone, which silently corrupted
       xt/xe main code once the scrolling dumper's row-14 cursor
       crossed $BE30 and printf started writing `4`/`5` characters
       into what was actually the middle of a u16Div instruction.
       The auto-detect path in load_xex bumps SAVMSC for `-m xl`
       (no banking) when it spots a $4000+ segment; the explicit
       `-m xt`/`-m xe...` paths set bank_mode_explicit before
       reaching here, so we honour that ahead of the default. */
    if (bank_mode_explicit && bank_mode == BANK_XT)
        {
        /* xt: screen RAM at $4000-$5FFF (task #60). */
        mem[0x57] = 0;
        mem[0x58] = 0x00;
        mem[0x59] = 0x40;
        }
    else if (bank_mode_explicit && bank_mode != BANK_NONE)
        {
        mem[0x57] = 0;
        mem[0x58] = 0x00;
        mem[0x59] = 0x80;
        }
    else
        {
        mem[0x57] = 0;
        mem[0x58] = 0x00;
        mem[0x59] = 0xBC;
        }

    if (!load_xex(xex))
        return 1;
    if (mapf)
        load_map(mapf);
    if (!run_addr)
        run_addr = 0x2000;

    // Default shadow mask to $01 (Atari OS ROM bit) when ROM is
    // loaded and no explicit --shadow-mask was given.
    if (rom_loaded && !shadow_mask)
        shadow_mask = 0x01;
    // Ensure PORTB starts with ROM enabled (all shadow bits set)
    // plus BASIC off, ANTIC on main RAM, banking off.
    if (rom_loaded)
        mem[PORTB_ADDR] |= shadow_mask | 0x32;

    if (!opt_dump)
        {
        fprintf(stderr, "sim6502: starting at $%04X%s", run_addr, banked_mode ? " (banked)" : "");
        if (rom_loaded)
            fprintf(stderr, " (ROM loaded, shadow mask $%02X)", shadow_mask);
        fprintf(stderr, "\n");
        }
        /* After heap init completes, dump bank 1 header to verify init worked.
       The init writes at PC=$32E7 for each bank — we'll dump after the
       restore at $330E after the last bank ($10). */
        {
        static int heap_dump_done = 0; /* fallthrough */
        }

    reg_pc = run_addr;
    reg_sp = 0xFFF;
    reg_a = reg_x = reg_y = 0;
    reg_p = 0x24;
    signal(SIGINT, sigint_handler);

        {
        static uint64_t last_report = 0;
        while (running)
            {
            if (step() <= 0)
                break; /* 0 = clean halt, -1 = abnormal stop */
            // Tick RTCLOK ($12 / $13 / $14, 24-bit big-endian-word
            // counter) at the configured rate. Atari OS standard:
            // increment LSB first, carry up.
            if (rtclok_insns_per_tick != 0)
                {
                rtclok_step_counter++;
                if (rtclok_step_counter >= rtclok_insns_per_tick)
                    {
                    rtclok_step_counter = 0;
                    if (++mem[0x14] == 0)
                        {
                        if (++mem[0x13] == 0)
                            {
                            ++mem[0x12];
                            }
                        }
                    }
                }
            // Periodic progress report (every 500K instructions)
            if ((insn_count - last_report) >= 500000)
                {
                last_report = insn_count;
                fprintf(stderr, "[sim6502] %llu insns, PC=$%04X\n",
                        (unsigned long long)insn_count, reg_pc);
                }
            // Heap walker debug: when in _hf_walk ($3510-$3554), dump state
            if (reg_pc >= 0x3510 && reg_pc <= 0x3554 && insn_count < 3000000)
                {
                static uint64_t last_hf_dump = 0;
                if (insn_count - last_hf_dump >= 10000)
                    {
                    last_hf_dump = insn_count;
                    uint8_t hdr_lo = mem_read(0xA000);
                    uint8_t hdr_hi = mem_read(0xA001);
                    uint8_t end_lo = mem_read(0x3710);
                    uint8_t end_hi = mem_read(0x3711);
                    fprintf(stderr, "[HFWALK] insns=%llu PC=$%04X A=$%02X X=$%02X Y=$%02X "
                                    "$96=$%02X%02X $98=$%02X%02X "
                                    "hdr@A000=$%02X%02X end=$%02X%02X "
                                    "$83=$%02X $84=$%02X $82=$%02X\n",
                            (unsigned long long)insn_count, reg_pc, reg_a, reg_x, reg_y,
                            mem[0x97], mem[0x96], mem[0x99], mem[0x98],
                            hdr_lo, hdr_hi, end_lo, end_hi,
                            mem[0x83], mem[0x84], mem[code_reg_addr]);
                    }
                }
            // NMI injection for shadow-mode testing
            if (nmi_interval && ++nmi_counter >= nmi_interval)
                {
                nmi_counter = 0;
                // Push PCH, PCL, P — same as hardware NMI
                mem_write(0x0100 | reg_sp, (uint8_t)(reg_pc >> 8));
                reg_sp--;
                mem_write(0x0100 | reg_sp, (uint8_t)(reg_pc & 0xFF));
                reg_sp--;
                mem_write(0x0100 | reg_sp, reg_p);
                reg_sp--;
                // Vector through NMI vector at $FFFA/$FFFB
                reg_pc = (uint16_t)(mem_read(0xFFFA) | (mem_read(0xFFFB) << 8));
                }
            }
        }

    if (!opt_dump || opt_cycles)
        fprintf(stderr, "\nsim6502: %llu instructions executed\n", insn_count);

    if (opt_g0 && !opt_dump)
        dump_screen();
    if (opt_dump && dump_last_row >= 0)
        putchar('\n');

    /* Surface the 6502 program's own exit code (main's return low byte, left
       in A at the clean halt), or a reserved code on an abnormal stop. */
    return g_exit_code;
    }
