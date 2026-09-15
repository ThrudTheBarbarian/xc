/*
 * sim68k — instrumented Motorola 68000/68030 simulator for xtc output
 *          targeting the Atari ST/TT.
 *
 * Companion to `xts` (the 6502 simulator). Loads a GEMDOS executable
 * ($601A "PRG"/"TOS"/"TTP"/"ACC" — all the same format) and runs it,
 * high-level-emulating the GEMDOS (trap #1), BIOS (trap #13) and XBIOS
 * (trap #14) calls a console program makes. No TOS ROM is required;
 * the trap ABI is implemented faithfully so the same binary runs
 * identically on real ST hardware.
 *
 *   Usage: xst [options] <file.prg> [mapfile]
 *
 * Instrumentation mirrors xts's XTS_* conventions under the XST_ prefix:
 *   XST_ITRACE / XST_ITRACE_TRIGGER / XST_ITRACE_STOP / XST_ITRACE_MAX
 *   XST_WATCH      — log writes to an address
 *   XST_TRAPTRACE  — log every GEMDOS/BIOS/XBIOS call (args + return)
 *
 * 68k is big-endian; all multi-byte memory access goes through the
 * accessors below so byte order lives in exactly one place.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <signal.h>
#include <ctype.h>
#include <fcntl.h>
#if defined(_WIN32)
#include <io.h> // _read/_write/_open/_close — the POSIX names below
#include <basetsd.h>
typedef SSIZE_T ssize_t;
typedef long off_t;
#define read _read
#define write _write
#define open _open
#define close _close
#define lseek _lseek
#else
#include <unistd.h>
#endif
#include <errno.h>
#include <math.h>

#ifndef XTC_VERSION
#define XTC_VERSION "0.0"
#endif

/* ── Memory ─────────────────────────────────────────────────────────
 * A single flat big-endian RAM image. Default 4 MB (a fully expanded
 * ST). The program (basepage + text + data + bss) loads at LOAD_BASE,
 * leaving low memory for the CPU exception vectors and ST system
 * variables, and a reserved screen framebuffer high up.
 */
#define DEFAULT_MEM_BYTES (4u * 1024u * 1024u)
#define LOAD_BASE 0x00010000u /* basepage / TPA start              */
#define FB_BASE 0x00080000u   /* reserved screen framebuffer       */
#define FB_BYTES 0x00008000u  /* 32000 bytes ST screen (rounded)   */

static uint8_t* mem = NULL;
static uint32_t mem_bytes = DEFAULT_MEM_BYTES;

static int opt_dump = 0;     /* -d : stream console to stdout      */
static int opt_cycles = 0;   /* --cycles                           */
static int cpu_kind = 68000; /* --cpu 68000|68030                  */

/* mem_bound: returns 1 and clamps for in-range, 0 for out-of-range.
   Out-of-range reads yield 0, writes are dropped (with an optional
   warning) — this keeps stray I/O / ROM probes from crashing us. */
static int oob_warned = 0;
static inline int in_range(uint32_t a, uint32_t n)
    {
    return (uint64_t)a + n <= mem_bytes;
    }

static inline uint8_t rd8(uint32_t a)
    {
    a &= 0x00FFFFFF; /* 68000 has a 24-bit address bus    */
    if (a < mem_bytes)
        return mem[a];
    return 0;
    }
static inline uint16_t rd16(uint32_t a)
    {
    return (uint16_t)((rd8(a) << 8) | rd8(a + 1));
    }
static inline uint32_t rd32(uint32_t a)
    {
    return ((uint32_t)rd16(a) << 16) | rd16(a + 2);
    }

static void watch_write(uint32_t a, uint32_t v, int size); /* fwd */

static inline void wr8(uint32_t a, uint8_t v)
    {
    a &= 0x00FFFFFF;
    if (a < mem_bytes)
        {
        mem[a] = v;
        }
    else if (!oob_warned)
        {
        fprintf(stderr, "sim68k: write out of range @ $%06X (suppressed)\n", a);
        oob_warned = 1;
        }
    }
static inline void wr16(uint32_t a, uint16_t v)
    {
    wr8(a, v >> 8);
    wr8(a + 1, v & 0xFF);
    }
static inline void wr32(uint32_t a, uint32_t v)
    {
    wr16(a, v >> 16);
    wr16(a + 2, v & 0xFFFF);
    }

/* Instrumented stores (used by the execute path so watchpoints fire). */
static inline void store8(uint32_t a, uint8_t v)
    {
    watch_write(a, v, 1);
    wr8(a, v);
    }
static inline void store16(uint32_t a, uint16_t v)
    {
    watch_write(a, v, 2);
    wr16(a, v);
    }
static inline void store32(uint32_t a, uint32_t v)
    {
    watch_write(a, v, 4);
    wr32(a, v);
    }

/* ── CPU state ──────────────────────────────────────────────────────── */
static uint32_t D[8];
static uint32_t A[8];      /* A[7] = active stack pointer        */
static double FP[8];       /* 68881/68882 FP registers (host f64) */
static int fpcc_n, fpcc_z; /* FPU condition: N (less), Z (equal)  */
static uint32_t PC;
static int flag_c, flag_v, flag_z, flag_n, flag_x;
static int flag_s = 1; /* supervisor (programs start super-ish)*/
static uint64_t insn_count = 0;
static int running = 1;
static int exit_code = 0;
/* Set only by Pterm/Pterm0. Every other way out of the run loop — an illegal
 * instruction, an unimplemented opcode, divide-by-zero, ^C — is an ABNORMAL
 * stop, and must not be reported to the shell as a successful run. Without
 * this the simulator exited 0 after refusing to execute the program.        */
static int terminated_via_pterm = 0;

/* ── Size helpers ───────────────────────────────────────────────────── */
static inline uint32_t size_mask(int sz)
    {
    return sz == 1 ? 0xFFu : sz == 2 ? 0xFFFFu
                                     : 0xFFFFFFFFu;
    }
static inline int msb_set(uint32_t v, int sz)
    {
    return (v >> (sz * 8 - 1)) & 1;
    }
static inline int32_t sign_ext(uint32_t v, int sz)
    {
    if (sz == 1)
        return (int8_t)v;
    if (sz == 2)
        return (int16_t)v;
    return (int32_t)v;
    }

/* ── Flag computation ───────────────────────────────────────────────── */
static void set_logic_flags(uint32_t r, int sz)
    {
    flag_n = msb_set(r, sz);
    flag_z = (r & size_mask(sz)) == 0;
    flag_v = 0;
    flag_c = 0;
    }
static void set_add_flags(uint32_t s, uint32_t d, uint32_t r, int sz)
    {
    int sm = msb_set(s, sz), dm = msb_set(d, sz), rm = msb_set(r, sz);
    flag_n = rm;
    flag_z = (r & size_mask(sz)) == 0;
    flag_v = (sm && dm && !rm) || (!sm && !dm && rm);
    flag_c = (sm && dm) || (!rm && dm) || (sm && !rm);
    flag_x = flag_c;
    }
static void set_sub_flags(uint32_t s, uint32_t d, uint32_t r, int sz)
    {
    /* r = d - s */
    int sm = msb_set(s, sz), dm = msb_set(d, sz), rm = msb_set(r, sz);
    flag_n = rm;
    flag_z = (r & size_mask(sz)) == 0;
    flag_v = (!sm && dm && !rm) || (sm && !dm && rm);
    flag_c = (sm && !dm) || (rm && !dm) || (sm && rm);
    flag_x = flag_c;
    }
static void set_cmp_flags(uint32_t s, uint32_t d, uint32_t r, int sz)
    {
    /* like sub but X is unaffected */
    int x = flag_x;
    set_sub_flags(s, d, r, sz);
    flag_x = x;
    }

static uint16_t get_sr(void)
    {
    uint16_t ccr = (flag_c ? 1 : 0) | (flag_v ? 2 : 0) | (flag_z ? 4 : 0) | (flag_n ? 8 : 0) | (flag_x ? 16 : 0);
    return ccr | (flag_s ? 0x2000 : 0);
    }
static void set_ccr(uint16_t v)
    {
    flag_c = v & 1;
    flag_v = (v >> 1) & 1;
    flag_z = (v >> 2) & 1;
    flag_n = (v >> 3) & 1;
    flag_x = (v >> 4) & 1;
    }
static void set_sr(uint16_t v)
    {
    set_ccr(v & 0x1F);
    flag_s = (v >> 13) & 1;
    }

/* ── Instruction stream fetch (from PC) ─────────────────────────────── */
static inline uint16_t fetch16(void)
    {
    uint16_t w = rd16(PC);
    PC += 2;
    return w;
    }
static inline uint32_t fetch32(void)
    {
    uint32_t l = rd32(PC);
    PC += 4;
    return l;
    }

/* ── Effective-address decoding ─────────────────────────────────────── *
 * Decoded once per operand; predecrement/postincrement adjust An here so
 * the address is captured exactly once. Byte access to A7 adjusts by 2
 * to keep the stack word-aligned.
 */
enum
    {
    EA_DREG,
    EA_AREG,
    EA_MEM,
    EA_IMM
    };
typedef struct
    {
    int kind;
    uint32_t addr;
    uint32_t imm;
    int reg;
    } EA;

/* A 68020+ construct decoded while running the 68000 core means the binary was
 * built for the wrong CPU. Say so and stop, rather than executing something
 * that merely *resembles* what was intended.
 *
 * This matters most for the scaled index: a real 68000 IGNORES bits 9-10 of a
 * brief extension word, so `(a0,d5.l*4)` from a `-A 68030` build does not
 * fault there — it silently degrades to scale x1. Element 0 still reads
 * correctly (0 * anything == 0) and every later element reads a wild address,
 * which looks exactly like a compiler miscompiling a loop. It cost a day of
 * bisecting once; it should never be silent again. */
static void require_68020(const char* what)
    {
    fprintf(stderr,
            "sim68k: %s requires a 68020+ core, but this is a 68000.\n"
            "sim68k: the binary was built for 68020+ (xtc -A 68030). Either run\n"
            "sim68k: `xst --cpu 68030`, or rebuild for this CPU with `xtc -A m68k`\n"
            "sim68k: (add -mpic if the program is too large for 16-bit PC-relative).\n",
            what);
    exit(2);
    }

static uint32_t brief_index(uint32_t base)
    {
    /* d8(An,Xn) / d8(PC,Xn) brief extension word. 68000 form. */
    uint16_t ext = fetch16();
    int ridx = (ext >> 12) & 7;
    int is_a = (ext >> 15) & 1;
    int is_long = (ext >> 11) & 1;
    int32_t xn = is_a ? (int32_t)A[ridx] : (int32_t)D[ridx];
    if (!is_long)
        xn = (int16_t)xn;
    /* 68020+ full extension word (bit 8 set) — not decodable as a brief one. */
    if ((ext & 0x0100) && cpu_kind < 68020)
        require_68020("a full-format extension word");
    /* 68020+ scale (bits 9-10). A real 68000 ignores these, so a scaled index
     * from a 68030 build would run here and quietly address the wrong element. */
    if (((ext >> 9) & 3) && cpu_kind < 68020)
        require_68020("a scaled index (Xn*2/4/8)");
    int scale = (cpu_kind >= 68020) ? ((ext >> 9) & 3) : 0;
    xn <<= scale;
    int8_t disp = (int8_t)(ext & 0xFF);
    return base + (uint32_t)xn + (uint32_t)(int32_t)disp;
    }

static EA decode_ea(int mode, int reg, int sz)
    {
    EA e;
    e.kind = EA_MEM;
    e.addr = 0;
    e.imm = 0;
    e.reg = reg;
    switch (mode)
        {
    case 0:
        e.kind = EA_DREG;
        e.reg = reg;
        break;
    case 1:
        e.kind = EA_AREG;
        e.reg = reg;
        break;
    case 2:
        e.addr = A[reg];
        break; /* (An)        */
    case 3:    /* (An)+       */
        e.addr = A[reg];
        A[reg] += (reg == 7 && sz == 1) ? 2 : sz;
        break;
    case 4: /* -(An)       */
        A[reg] -= (reg == 7 && sz == 1) ? 2 : sz;
        e.addr = A[reg];
        break;
    /* d16(An)     */
    case 5:
        {
        int16_t d = (int16_t)fetch16();
        e.addr = A[reg] + (int32_t)d;
        break;
        }
    case 6:
        e.addr = brief_index(A[reg]);
        break; /* d8(An,Xn)   */
    case 7:
        switch (reg)
            {
        case 0:
            e.addr = (int16_t)fetch16();
            break; /* abs.w       */
        case 1:
            e.addr = fetch32();
            break; /* abs.l       */
        case 2:
            {
            int16_t d = (int16_t)fetch16(); /* d16(PC)     */
            e.addr = (PC - 2) + (int32_t)d;
            break;
            }
        /* (d8,PC,Xn) or (bd,PC) full */
        case 3:
            {
            uint16_t ext = rd16(PC);
            /* full format (68020+) */
            if (ext & 0x0100)
                {
                uint32_t base = PC;
                PC += 2;                     /* base = ext-word addr */
                int bdsize = (ext >> 4) & 3; /* 2=word, 3=long */
                int32_t bd = (bdsize == 3)   ? (int32_t)fetch32()
                             : (bdsize == 2) ? (int16_t)fetch16()
                                             : 0;
                e.addr = base + bd; /* IS=1, BS=0: PC + bd, no index */
                }
            else
                {
                uint32_t base = PC;
                e.addr = brief_index(base);
                }
            break;
            }
        case 4: /* #imm        */
            e.kind = EA_IMM;
            if (sz == 1)
                e.imm = fetch16() & 0xFF;
            else if (sz == 2)
                e.imm = fetch16();
            else
                e.imm = fetch32();
            break;
            }
        break;
        }
    return e;
    }

static uint32_t ea_load(EA* e, int sz)
    {
    switch (e->kind)
        {
    case EA_DREG:
        return D[e->reg] & size_mask(sz);
    case EA_AREG:
        return (sz == 2) ? (uint32_t)(int16_t)A[e->reg] : A[e->reg];
    case EA_IMM:
        return e->imm & size_mask(sz);
    default:
        return sz == 1 ? rd8(e->addr) : sz == 2 ? rd16(e->addr)
                                                : rd32(e->addr);
        }
    }
static void ea_store(EA* e, int sz, uint32_t v)
    {
    switch (e->kind)
        {
    case EA_DREG:
        D[e->reg] = (D[e->reg] & ~size_mask(sz)) | (v & size_mask(sz));
        break;
    case EA_AREG:
        A[e->reg] = (sz == 2) ? (uint32_t)(int16_t)v : v;
        break;
    case EA_IMM:
        break; /* not writable */
    default:
        if (sz == 1)
            store8(e->addr, v);
        else if (sz == 2)
            store16(e->addr, v);
        else
            store32(e->addr, v);
        }
    }

/* Compute an EA's address only (LEA/PEA/JMP/JSR control modes). */
static uint32_t ea_address(int mode, int reg)
    {
    EA e = decode_ea(mode, reg, 4);
    return e.addr;
    }

/* ── 68881/68882 FPU helpers (IEEE) ─────────────────────────────────── *
 * FP registers are modelled as host doubles. Memory/integer operands are
 * read/written in the IEEE format named by the instruction's source
 * specifier: 0=Long(int32), 1=Single(f32), 5=Double(f64), 4=Word, 6=Byte.
 */
static int fpu_fmt_bytes(int fmt)
    {
    return fmt == 1 ? 4 : fmt == 5 ? 8
                      : fmt == 0   ? 4
                      : fmt == 4   ? 2
                                   : 1;
    }
static double fpu_read(EA* e, int fmt)
    {
    if (e->kind == EA_DREG)
        {
        uint32_t v = D[e->reg];
        if (fmt == 1)
            {
            float f;
            memcpy(&f, &v, 4);
            return (double)f;
            }
        if (fmt == 4)
            return (double)(int16_t)v;
        if (fmt == 6)
            return (double)(int8_t)v;
        return (double)(int32_t)v; /* Long */
        }
    uint32_t a = e->addr;
    if (fmt == 1)
        {
        uint32_t b = rd32(a);
        float f;
        memcpy(&f, &b, 4);
        return (double)f;
        }
    if (fmt == 5)
        {
        uint64_t b = ((uint64_t)rd32(a) << 32) | rd32(a + 4);
        double d;
        memcpy(&d, &b, 8);
        return d;
        }
    if (fmt == 4)
        return (double)(int16_t)rd16(a);
    if (fmt == 6)
        return (double)(int8_t)rd8(a);
    return (double)(int32_t)rd32(a); /* Long */
    }
static void fpu_write(EA* e, int fmt, double val)
    {
    if (e->kind == EA_DREG)
        {
        if (fmt == 1)
            {
            float f = (float)val;
            uint32_t v;
            memcpy(&v, &f, 4);
            D[e->reg] = v;
            }
        else
            D[e->reg] = (uint32_t)(int32_t)val; /* Long: truncate (C cast) */
        return;
        }
    uint32_t a = e->addr;
    if (fmt == 1)
        {
        float f = (float)val;
        uint32_t v;
        memcpy(&v, &f, 4);
        store32(a, v);
        }
    else if (fmt == 5)
        {
        uint64_t b;
        memcpy(&b, &val, 8);
        store32(a, b >> 32);
        store32(a + 4, b & 0xFFFFFFFF);
        }
    else if (fmt == 4)
        store16(a, (uint16_t)(int16_t)val);
    else if (fmt == 6)
        store8(a, (uint8_t)(int8_t)val);
    else
        store32(a, (uint32_t)(int32_t)val); /* Long: truncate */
    }

/* IEEE FP conditional predicate → truth, from the FPCC (N=less, Z=equal). */
static int fpu_cond(int pred)
    {
    switch (pred)
        {
    case 0x00:
        return 0; /* F  */
    case 0x0F:
        return 1; /* T  */
    case 0x01:
        return fpcc_z; /* EQ */
    case 0x0E:
        return !fpcc_z; /* NE */
    case 0x12:
        return !fpcc_n && !fpcc_z; /* GT */
    case 0x13:
        return !fpcc_n; /* GE */
    case 0x14:
        return fpcc_n && !fpcc_z; /* LT */
    case 0x15:
        return fpcc_n || fpcc_z; /* LE */
    default:
        return 0;
        }
    }

/* Execute one 68881 line-F instruction (word1 already fetched as `op`). */
static int fpu_step(uint16_t op)
    {
    uint16_t w2 = fetch16();
    int eamode = (op >> 3) & 7, eareg = op & 7;
    /* FMOVE FPn -> <ea>  (store) */
    if ((w2 & 0xE000) == 0x6000)
        {
        int fmt = (w2 >> 10) & 7, fpn = (w2 >> 7) & 7;
        EA e = decode_ea(eamode, eareg, fpu_fmt_bytes(fmt));
        fpu_write(&e, fmt, FP[fpn]);
        return 0;
        }
    /* general: <ea>/FPm -> FPn */
    if ((w2 & 0x8000) == 0)
        {
        int rm = (w2 >> 14) & 1, spec = (w2 >> 10) & 7, fpn = (w2 >> 7) & 7;
        int opmode = w2 & 0x7F;
        double src;
        if (rm == 0)
            src = FP[spec]; /* FPm */
        else
            {
            EA e = decode_ea(eamode, eareg, fpu_fmt_bytes(spec));
            src = fpu_read(&e, spec);
            }
        switch (opmode)
            {
        case 0x00:
            FP[fpn] = src;
            break; /* FMOVE */
        case 0x22:
            FP[fpn] += src;
            break; /* FADD */
        case 0x28:
            FP[fpn] -= src;
            break; /* FSUB */
        case 0x23:
            FP[fpn] *= src;
            break; /* FMUL */
        case 0x20:
            FP[fpn] /= src;
            break; /* FDIV */
        case 0x1A:
            FP[fpn] = -src;
            break; /* FNEG */
        case 0x18:
            FP[fpn] = src < 0 ? -src : src;
            break; /* FABS */
        case 0x04:
            FP[fpn] = sqrt(src);
            break; /* FSQRT */
        /* 68881 transcendentals -> host libm. On the Zynq m68k JIT these
           map onto native libm too (the doc's "shorter path to the A9 FP"). */
        case 0x0E:
            FP[fpn] = sin(src);
            break; /* FSIN   */
        case 0x1D:
            FP[fpn] = cos(src);
            break; /* FCOS   */
        case 0x0F:
            FP[fpn] = tan(src);
            break; /* FTAN   */
        case 0x0C:
            FP[fpn] = asin(src);
            break; /* FASIN  */
        case 0x1C:
            FP[fpn] = acos(src);
            break; /* FACOS  */
        case 0x0A:
            FP[fpn] = atan(src);
            break; /* FATAN  */
        case 0x10:
            FP[fpn] = exp(src);
            break; /* FETOX  (e^x)  */
        case 0x14:
            FP[fpn] = log(src);
            break; /* FLOGN  (ln)   */
        case 0x15:
            FP[fpn] = log10(src);
            break; /* FLOG10 */
        case 0x16:
            FP[fpn] = log2(src);
            break; /* FLOG2  */
        case 0x11:
            FP[fpn] = exp2(src);
            break; /* FTWOTOX (2^x) */
        case 0x12:
            FP[fpn] = pow(10.0, src);
            break; /* FTENTOX (10^x)*/
        case 0x02:
            FP[fpn] = sinh(src);
            break; /* FSINH  */
        case 0x19:
            FP[fpn] = cosh(src);
            break; /* FCOSH  */
        case 0x09:
            FP[fpn] = tanh(src);
            break; /* FTANH  */
        case 0x01:
        case 0x03: /* FINT / FINTRZ */
            FP[fpn] = (double)(long)src;
            break;
        case 0x38: /* FCMP: FPn - src */
            fpcc_z = (FP[fpn] == src);
            fpcc_n = (FP[fpn] < src);
            break;
        case 0x3A: /* FTST: test src */
            fpcc_z = (src == 0);
            fpcc_n = (src < 0);
            break;
        default:
            fprintf(stderr, "sim68k: unimplemented FPU opmode $%02X at $%06X\n", opmode, PC);
            return 1;
            }
        return 0;
        }
    fprintf(stderr, "sim68k: unimplemented FPU word2 $%04X at $%06X\n", w2, PC);
    return 1;
    }

/* ── Condition codes for Bcc/Scc/DBcc ───────────────────────────────── */
static int cond_true(int cc)
    {
    int C = flag_c, V = flag_v, Z = flag_z, N = flag_n;
    switch (cc)
        {
    case 0:
        return 1; /* T  */
    case 1:
        return 0; /* F  */
    case 2:
        return !C && !Z; /* HI */
    case 3:
        return C || Z; /* LS */
    case 4:
        return !C; /* CC/HS */
    case 5:
        return C; /* CS/LO */
    case 6:
        return !Z; /* NE */
    case 7:
        return Z; /* EQ */
    case 8:
        return !V; /* VC */
    case 9:
        return V; /* VS */
    case 10:
        return !N; /* PL */
    case 11:
        return N; /* MI */
    case 12:
        return N == V; /* GE */
    case 13:
        return N != V; /* LT */
    case 14:
        return !Z && (N == V); /* GT */
    case 15:
        return Z || (N != V); /* LE */
        }
    return 0;
    }

/* ── Trap HLE (GEMDOS / BIOS / XBIOS) ───────────────────────────────── */
static void do_trap(int vec);

/* ── Instrumentation ────────────────────────────────────────────────── */
static int itrace_enabled = 0, itrace_active = 0;
static int itrace_has_trig = 0, itrace_has_stop = 0;
static uint32_t itrace_trigger = 0, itrace_stop = 0;
static uint64_t itrace_max = 200000, itrace_emitted = 0;
static int watch_enabled = 0;
static uint32_t watch_addr = 0;
static int traptrace = 0;

static void watch_write(uint32_t a, uint32_t v, int size)
    {
    if (watch_enabled && a == watch_addr)
        fprintf(stderr, "[watch] PC=$%06X *$%06X <- $%0*X (%d)\n",
                PC, a, size * 2, v, size);
    }

static void trace_line(uint16_t op)
    {
    fprintf(stderr,
            "%8llu PC=$%06X op=%04X "
            "D0=%08X D1=%08X D2=%08X A0=%08X A1=%08X A6=%08X A7=%08X %c%c%c%c%c\n",
            (unsigned long long)insn_count, PC, op,
            D[0], D[1], D[2], A[0], A[1], A[6], A[7],
            flag_x ? 'X' : '-', flag_n ? 'N' : '-', flag_z ? 'Z' : '-', flag_v ? 'V' : '-', flag_c ? 'C' : '-');
    }

/* ── Line-A math HLE ─────────────────────────────────────────────────── *
 * FPU-less m68k (soft-float, or 68000 32-bit int mul/div) compiles each math
 * helper's body to `dc.w $A0<sel>; rts` (see private:docs/Design/m68k-math-hle.md).
 * We recognise the line-A opcode, run the operation on host math honouring the
 * m68k C ABI — args in d0/d1 or on the stack, result in d0(:d1) — and touch NO
 * other register, so d2-d7/a2-a6 are preserved by construction (which is what
 * lets the m68k backend's register allocator home values there). Execution
 * falls through to the trailing `rts`.
 */
static inline float la_f32(uint32_t b)
    {
    float f;
    memcpy(&f, &b, 4);
    return f;
    }
static inline uint32_t la_f32b(float f)
    {
    uint32_t b;
    memcpy(&b, &f, 4);
    return b;
    }
static inline double la_f64(uint32_t hi, uint32_t lo)
    {
    uint64_t b = ((uint64_t)hi << 32) | lo;
    double d;
    memcpy(&d, &b, 8);
    return d;
    }
static inline void la_f64d(double d, uint32_t* hi, uint32_t* lo)
    {
    uint64_t b;
    memcpy(&b, &d, 8);
    *hi = (uint32_t)(b >> 32);
    *lo = (uint32_t)b;
    }
static inline void la_u64d(uint64_t v, uint32_t* hi, uint32_t* lo)
    {
    *hi = (uint32_t)(v >> 32);
    *lo = (uint32_t)v;
    }

static int line_a_step(uint16_t op)
    {
    int sel = op & 0x0FFF;
    uint32_t sp = A[7]; /* 0(sp)=retaddr; f64 args follow */
    /* f64 stack args (high word first): a=4(sp):8(sp), b=12(sp):16(sp) */
    double a64 = la_f64(rd32(sp + 4), rd32(sp + 8));
    double b64 = la_f64(rd32(sp + 12), rd32(sp + 16));
    double r64;
    /* Same two stack slots read as integers, for the 64-bit integer pack. */
    uint64_t la_u64a = ((uint64_t)rd32(sp + 4) << 32) | rd32(sp + 8);
    uint64_t la_u64b = ((uint64_t)rd32(sp + 12) << 32) | rd32(sp + 16);
    switch (sel)
        {
    /* f32 binary: a=d0, b=d1 -> d0 */
    case 0x00:
        D[0] = la_f32b(la_f32(D[0]) + la_f32(D[1]));
        break; /* addsf3 */
    case 0x01:
        D[0] = la_f32b(la_f32(D[0]) - la_f32(D[1]));
        break; /* subsf3 */
    case 0x02:
        D[0] = la_f32b(la_f32(D[0]) * la_f32(D[1]));
        break; /* mulsf3 */
    case 0x03:
        D[0] = la_f32b(la_f32(D[0]) / la_f32(D[1]));
        break; /* divsf3 */
    case 0x05:
        {
        float a = la_f32(D[0]), b = la_f32(D[1]); /* cmpsf2 */
        D[0] = (uint32_t)(int32_t)(a < b ? -1 : a > b ? 1
                                            : a == b  ? 0
                                                      : 1);
        break;
        }
    /* f64 binary: a=4(sp):8(sp), b=12(sp):16(sp) -> d0:d1 */
    case 0x08:
        r64 = a64 + b64;
        la_f64d(r64, &D[0], &D[1]);
        break; /* adddf3 */
    case 0x09:
        r64 = a64 - b64;
        la_f64d(r64, &D[0], &D[1]);
        break; /* subdf3 */
    case 0x0A:
        r64 = a64 * b64;
        la_f64d(r64, &D[0], &D[1]);
        break; /* muldf3 */
    case 0x0B:
        r64 = a64 / b64;
        la_f64d(r64, &D[0], &D[1]);
        break; /* divdf3 */
    case 0x0D:
        D[0] = (uint32_t)(int32_t)(a64 < b64 ? -1 : a64 > b64 ? 1
                                                : a64 == b64  ? 0
                                                              : 1);
        break; /* cmpdf2 */
    /* conversions */
    case 0x10:
        D[0] = (uint32_t)(int32_t)la_f32(D[0]);
        break; /* fixsfsi  f32 d0 -> i32 d0 */
    case 0x11:
        D[0] = (uint32_t)(int32_t)a64;
        break; /* fixdfsi  f64 (sp) -> i32 d0 */
    case 0x12:
        D[0] = la_f32b((float)(int32_t)D[0]);
        break; /* floatsisf i32 d0 -> f32 d0 */
    case 0x13:
        la_f64d((double)(int32_t)D[0], &D[0], &D[1]);
        break; /* floatsidf i32 d0 -> f64 d0:d1 */
    case 0x14:
        la_f64d((double)la_f32(D[0]), &D[0], &D[1]);
        break; /* extendsfdf2 f32 d0 -> f64 d0:d1 */
    case 0x15:
        D[0] = la_f32b((float)a64);
        break; /* truncdfsf2 f64 (sp) -> f32 d0 */
    /* 32-bit integer: a=d0, b=d1 -> d0 (divide-by-zero yields 0) */
    case 0x18:
        D[0] = (uint32_t)((int32_t)D[0] * (int32_t)D[1]);
        break; /* mulsi3  */
    case 0x19:
        D[0] = (int32_t)D[1] ? (uint32_t)((int32_t)D[0] / (int32_t)D[1]) : 0;
        break; /* divsi3  */
    case 0x1A:
        D[0] = D[1] ? (D[0] / D[1]) : 0;
        break; /* udivsi3 */
    case 0x1B:
        D[0] = (int32_t)D[1] ? (uint32_t)((int32_t)D[0] % (int32_t)D[1]) : 0;
        break; /* modsi3 */
    case 0x1C:
        D[0] = D[1] ? (D[0] % D[1]) : 0;
        break; /* umodsi3 */
    /* 64-bit integer: both operands on the stack high word first, exactly as
     * the f64 ops above — a=4(sp):8(sp), b=12(sp):16(sp) -> d0:d1. Divide and
     * modulo by zero yield 0, matching the 32-bit cases rather than trapping. */
    case 0x20:
        la_u64d(la_u64a + la_u64b, &D[0], &D[1]);
        break; /* adddi3  */
    case 0x21:
        la_u64d(la_u64a - la_u64b, &D[0], &D[1]);
        break; /* subdi3  */
    case 0x22:
        la_u64d(la_u64a * la_u64b, &D[0], &D[1]);
        break; /* muldi3  */
    case 0x23:
        la_u64d(la_u64b ? (uint64_t)((int64_t)la_u64a / (int64_t)la_u64b) : 0,
                &D[0], &D[1]);
        break; /* divdi3  */
    case 0x24:
        la_u64d(la_u64b ? (la_u64a / la_u64b) : 0, &D[0], &D[1]);
        break; /* udivdi3 */
    case 0x25:
        la_u64d(la_u64b ? (uint64_t)((int64_t)la_u64a % (int64_t)la_u64b) : 0,
                &D[0], &D[1]);
        break; /* moddi3  */
    case 0x26:
        la_u64d(la_u64b ? (la_u64a % la_u64b) : 0, &D[0], &D[1]);
        break; /* umoddi3 */
    /* A shift COUNT arrives as a 64-bit value like any other operand; only its
     * low bits can matter, and a count >= 64 is undefined in C, so it is masked
     * rather than left to the host's shift instruction. */
    case 0x27:
        la_u64d(la_u64a << (la_u64b & 63), &D[0], &D[1]);
        break; /* ashldi3 */
    case 0x28:
        la_u64d(la_u64a >> (la_u64b & 63), &D[0], &D[1]);
        break; /* lshrdi3 */
    case 0x29:
        la_u64d((uint64_t)((int64_t)la_u64a >> (la_u64b & 63)),
                &D[0], &D[1]);
        break; /* ashrdi3 */
    case 0x2A:
        la_u64d(la_u64a & la_u64b, &D[0], &D[1]);
        break; /* anddi3  */
    case 0x2B:
        la_u64d(la_u64a | la_u64b, &D[0], &D[1]);
        break; /* ordi3   */
    case 0x2C:
        la_u64d(la_u64a ^ la_u64b, &D[0], &D[1]);
        break; /* xordi3  */
    /* Compare, returning sign(a-b) in d0 as the soft-float __cmpdf2 does. A
     * 64-bit compare cannot be one cmp.l, and comparing only the high longs
     * made `7 == 0` true. */
    case 0x2D:
        D[0] = (uint32_t)((int64_t)la_u64a < (int64_t)la_u64b ? -1
                                                              : ((int64_t)la_u64a > (int64_t)la_u64b ? 1 : 0));
        break; /* cmpdi2  */
    case 0x2E:
        D[0] = (uint32_t)(la_u64a < la_u64b ? -1
                                            : (la_u64a > la_u64b ? 1 : 0));
        break; /* ucmpdi2 */
    /* 64-bit integer <-> floating point. These exist for BOTH float modes,
     * unlike every other conversion above: the 68881 converts .b/.w/.l only,
     * so even -mhard-float has no instruction for a 64-bit integer and has to
     * come through here. Argument on the stack (high word first) like the rest
     * of the 64-bit pack; f32 results in d0, f64 and 64-bit ints in d0:d1. */
    case 0x2F:
        la_f64d((double)(int64_t)la_u64a, &D[0], &D[1]);
        break; /* floatdidf   i64 -> f64 */
    case 0x30:
        la_f64d((double)la_u64a, &D[0], &D[1]);
        break; /* floatundidf u64 -> f64 */
    case 0x31:
        D[0] = la_f32b((float)(int64_t)la_u64a);
        break; /* floatdisf   i64 -> f32 */
    case 0x32:
        D[0] = la_f32b((float)la_u64a);
        break; /* floatundisf u64 -> f32 */
    /* Out-of-range float->int saturates to 0, matching LANGUAGE-SPEC §3.1 and
     * what the 32-bit fixdfsi path above does. */
    case 0x33:
        la_u64d((a64 >= -9223372036854775808.0 && a64 < 9223372036854775808.0)
                    ? (uint64_t)(int64_t)a64
                    : 0,
                &D[0], &D[1]);
        break; /* fixdfdi    f64 -> i64 */
    case 0x34:
        la_u64d((a64 >= 0.0 && a64 < 18446744073709551616.0)
                    ? (uint64_t)a64
                    : 0,
                &D[0], &D[1]);
        break; /* fixunsdfdi f64 -> u64 */
    /* fixsfdi   f32 -> i64 */
    case 0x35:
        {
        float f = la_f32(D[0]);
        la_u64d((f >= -9223372036854775808.0f && f < 9223372036854775808.0f)
                    ? (uint64_t)(int64_t)f
                    : 0,
                &D[0], &D[1]);
        break;
        }
    /* fixunssfdi f32 -> u64 */
    case 0x36:
        {
        float f = la_f32(D[0]);
        la_u64d((f >= 0.0f && f < 18446744073709551616.0f)
                    ? (uint64_t)f
                    : 0,
                &D[0], &D[1]);
        break;
        }
    default:
        fprintf(stderr, "[line-a] unknown math selector $%03X at PC=$%06X\n", sel, PC - 2);
        return 1; /* halt: unimplemented HLE op */
        }
    if (traptrace)
        fprintf(stderr, "[line-a $%03X] -> D0=$%08X D1=$%08X\n", sel, D[0], D[1]);
    return 0;
    }

/* ── The execute step ───────────────────────────────────────────────── */
/* Returns 0 normally, nonzero to stop. */
static int step(void)
    {
    uint32_t op_pc = PC;
    uint16_t op = fetch16();

    if (itrace_has_trig && op_pc == itrace_trigger)
        itrace_active = 1;
    if (itrace_active && itrace_has_stop && op_pc == itrace_stop)
        itrace_active = 0;
    if ((itrace_enabled || itrace_active) && itrace_emitted < itrace_max)
        {
        PC = op_pc; /* show pre-decode PC */
        uint16_t shown = op;
        PC = op_pc + 2;
        (void)shown;
        /* re-emit with PC pointing at the opcode */
        uint32_t save = PC;
        PC = op_pc;
        trace_line(op);
        PC = save;
        itrace_emitted++;
        }

    insn_count++;

    /* $4AFC is ILLEGAL, the architecturally-guaranteed illegal instruction,
     * which the code generator emits for `Unreachable` — a failed CHECKED
     * downcast. It has to be caught HERE, ahead of the dispatch: its high
     * nibble is 4, so `case 0x4` (line-4 miscellaneous) claims it first and
     * mis-decodes it as a TAS with an invalid mode, silently stepping over it
     * six bytes later. Real hardware takes vector 4; this reports the abort.  */
    if (op == 0x4AFC)
        {
        fprintf(stderr, "sim68k: illegal instruction at $%06X — aborted "
                        "(failed checked downcast, or a reached "
                        "`unreachable`)\n",
                op_pc);
        running = 0;
        return 1;
        }

    int top = (op >> 12) & 0xF;

    switch (top)
        {

    /* ---- 0001/0010/0011 : MOVE.B / MOVE.L / MOVE.W ------------------ */
    case 1:
    case 2:
    case 3:
        {
        int sz = (top == 1) ? 1 : (top == 2) ? 4
                                             : 2;
        int src_mode = (op >> 3) & 7, src_reg = op & 7;
        int dst_reg = (op >> 9) & 7, dst_mode = (op >> 6) & 7;
        EA s = decode_ea(src_mode, src_reg, sz);
        uint32_t v = ea_load(&s, sz);
        /* MOVEA — sign-extend, no flags */
        if (dst_mode == 1)
            {
            A[dst_reg] = (sz == 2) ? (uint32_t)(int16_t)v : v;
            }
        else
            {
            EA d = decode_ea(dst_mode, dst_reg, sz);
            ea_store(&d, sz, v);
            set_logic_flags(v, sz);
            }
        break;
        }

    /* ---- 0111 : MOVEQ ---------------------------------------------- */
    case 7:
        {
        int reg = (op >> 9) & 7;
        int32_t v = (int8_t)(op & 0xFF);
        D[reg] = (uint32_t)v;
        set_logic_flags((uint32_t)v, 4);
        break;
        }

    /* ---- 0110 : Bcc / BRA / BSR ------------------------------------ */
    case 6:
        {
        int cc = (op >> 8) & 0xF;
        int32_t disp = (int8_t)(op & 0xFF);
        uint32_t base = PC; /* PC after opcode word */
        if ((op & 0xFF) == 0x00)
            disp = (int16_t)fetch16();
        else if ((op & 0xFF) == 0xFF)
            disp = (int32_t)fetch32();
        /* BSR */
        if (cc == 1)
            {
            A[7] -= 4;
            store32(A[7], PC);
            PC = base + disp;
            }
        else if (cond_true(cc))
            {
            PC = base + disp;
            }
        break;
        }

    /* ---- 0101 : ADDQ / SUBQ / Scc / DBcc --------------------------- */
    case 5:
        {
        int mode = (op >> 3) & 7, reg = op & 7;
        if (((op >> 6) & 3) == 3)
            {
            int cc = (op >> 8) & 0xF;
            /* DBcc */
            if (mode == 1)
                {
                int32_t disp = (int16_t)fetch16();
                uint32_t base = PC - 2;
                if (!cond_true(cc))
                    {
                    uint16_t cnt = (D[reg] & 0xFFFF) - 1;
                    D[reg] = (D[reg] & 0xFFFF0000) | cnt;
                    if (cnt != 0xFFFF)
                        PC = base + disp;
                    }
                }
            /* Scc */
            else
                {
                EA e = decode_ea(mode, reg, 1);
                ea_store(&e, 1, cond_true(cc) ? 0xFF : 0x00);
                }
            }
        else
            {
            int sz = (op >> 6) & 3;
            sz = sz == 0 ? 1 : sz == 1 ? 2
                                       : 4;
            int data = (op >> 9) & 7;
            if (data == 0)
                data = 8;
            int is_sub = (op >> 8) & 1;
            EA e = decode_ea(mode, reg, sz);
            /* ADDQ/SUBQ to An: full 32-bit, no flags */
            if (e.kind == EA_AREG)
                {
                if (is_sub)
                    A[e.reg] -= data;
                else
                    A[e.reg] += data;
                }
            else
                {
                uint32_t d = ea_load(&e, sz), r;
                if (is_sub)
                    {
                    r = d - data;
                    set_sub_flags(data, d, r, sz);
                    }
                else
                    {
                    r = d + data;
                    set_add_flags(data, d, r, sz);
                    }
                ea_store(&e, sz, r);
                }
            }
        break;
        }

    /* ---- 0100 : misc ----------------------------------------------- */
    case 4:
        {
        /* LEA: 0100 aaa 111 mmmrrr  (opmode field bits 8-6 == 111) */
        if ((op & 0xF1C0) == 0x41C0)
            {
            int areg = (op >> 9) & 7;
            A[areg] = ea_address((op >> 3) & 7, op & 7);
            break;
            }
        /* PEA: 0100 1000 01 mmmrrr — only control modes (>=2); mode 0
           in this range is SWAP, handled just below. */
        /* PEA */
        if ((op & 0xFFC0) == 0x4840 && ((op >> 3) & 7) >= 2)
            {
            uint32_t a = ea_address((op >> 3) & 7, op & 7);
            A[7] -= 4;
            store32(A[7], a);
            break;
            }
        /* EXT */
        if ((op & 0xFFB8) == 0x4880)
            {
            int reg = op & 7, sz = (op & 0x40) ? 4 : 2;
            if (sz == 2)
                {
                int16_t v = (int8_t)(D[reg] & 0xFF);
                D[reg] = (D[reg] & 0xFFFF0000) | (uint16_t)v;
                set_logic_flags((uint16_t)v, 2);
                }
            else
                {
                int32_t v = (int16_t)(D[reg] & 0xFFFF);
                D[reg] = (uint32_t)v;
                set_logic_flags((uint32_t)v, 4);
                }
            break;
            }
        /* SWAP */
        if ((op & 0xFFF8) == 0x4840)
            {
            int reg = op & 7;
            D[reg] = (D[reg] << 16) | (D[reg] >> 16);
            set_logic_flags(D[reg], 4);
            break;
            }
        /* CLR */
        if ((op & 0xFF00) == 0x4200)
            {
            int sz = (op >> 6) & 3;
            sz = sz == 0 ? 1 : sz == 1 ? 2
                                       : 4;
            EA e = decode_ea((op >> 3) & 7, op & 7, sz);
            ea_store(&e, sz, 0);
            flag_n = 0;
            flag_z = 1;
            flag_v = 0;
            flag_c = 0;
            break;
            }
        /* NEG */
        if ((op & 0xFF00) == 0x4400)
            {
            int sz = (op >> 6) & 3;
            sz = sz == 0 ? 1 : sz == 1 ? 2
                                       : 4;
            EA e = decode_ea((op >> 3) & 7, op & 7, sz);
            uint32_t d = ea_load(&e, sz), r = 0 - d;
            set_sub_flags(d, 0, r, sz);
            ea_store(&e, sz, r);
            break;
            }
        /* NOT */
        if ((op & 0xFF00) == 0x4600)
            {
            int sz = (op >> 6) & 3;
            sz = sz == 0 ? 1 : sz == 1 ? 2
                                       : 4;
            EA e = decode_ea((op >> 3) & 7, op & 7, sz);
            uint32_t r = ~ea_load(&e, sz);
            ea_store(&e, sz, r);
            set_logic_flags(r, sz);
            break;
            }
        /* TST */
        if ((op & 0xFF00) == 0x4A00)
            {
            int sz = (op >> 6) & 3;
            sz = sz == 0 ? 1 : sz == 1 ? 2
                                       : 4;
            EA e = decode_ea((op >> 3) & 7, op & 7, sz);
            set_logic_flags(ea_load(&e, sz), sz);
            break;
            }
        /* JSR */
        if ((op & 0xFFC0) == 0x4E80)
            {
            uint32_t a = ea_address((op >> 3) & 7, op & 7);
            A[7] -= 4;
            store32(A[7], PC);
            PC = a;
            break;
            }
        /* JMP */
        if ((op & 0xFFC0) == 0x4EC0)
            {
            PC = ea_address((op >> 3) & 7, op & 7);
            break;
            }
        /* TRAP #n */
        if ((op & 0xFFF0) == 0x4E40)
            {
            do_trap(op & 0xF);
            break;
            }
        /* LINK */
        if ((op & 0xFFF8) == 0x4E50)
            {
            int areg = op & 7;
            int16_t disp = (int16_t)fetch16();
            A[7] -= 4;
            store32(A[7], A[areg]);
            A[areg] = A[7];
            A[7] += (int32_t)disp;
            break;
            }
        /* UNLK */
        if ((op & 0xFFF8) == 0x4E58)
            {
            int areg = op & 7;
            A[7] = A[areg];
            A[areg] = rd32(A[7]);
            A[7] += 4;
            break;
            }
        /* RTS */
        if (op == 0x4E75)
            {
            PC = rd32(A[7]);
            A[7] += 4;
            break;
            }
        /* RTR */
        if (op == 0x4E77)
            {
            set_ccr(rd16(A[7]));
            A[7] += 2;
            PC = rd32(A[7]);
            A[7] += 4;
            break;
            }
        /* RTE */
        if (op == 0x4E73)
            {
            set_sr(rd16(A[7]));
            A[7] += 2;
            PC = rd32(A[7]);
            A[7] += 4;
            break;
            }
        if (op == 0x4E71)
            break; /* NOP */
        /* STOP #imm */
        if (op == 0x4E72)
            {
            (void)fetch16();
            running = 0;
            return 1;
            }
        /* MOVE from SR */
        if ((op & 0xFFC0) == 0x40C0)
            {
            EA e = decode_ea((op >> 3) & 7, op & 7, 2);
            ea_store(&e, 2, get_sr());
            break;
            }
        /* MOVE to CCR */
        if ((op & 0xFFC0) == 0x44C0)
            {
            EA e = decode_ea((op >> 3) & 7, op & 7, 2);
            set_ccr(ea_load(&e, 2));
            break;
            }
        /* MOVE to SR */
        if ((op & 0xFFC0) == 0x46C0)
            {
            EA e = decode_ea((op >> 3) & 7, op & 7, 2);
            set_sr(ea_load(&e, 2));
            break;
            }
        /* MOVEM */
        if ((op & 0xFB80) == 0x4880)
            {
            int dr = (op >> 10) & 1; /* 0 = reg->mem, 1 = mem->reg */
            int sz = (op & 0x40) ? 4 : 2;
            int mode = (op >> 3) & 7, reg = op & 7;
            uint16_t list = fetch16();
            /* predecrement reg->mem */
            if (dr == 0 && mode == 4)
                {
                uint32_t a = A[reg];
                for (int i = 0; i < 16; i++)
                    if (list & (1 << i))
                        {
                        /* order: A7..A0,D7..D0 mapped to bits 0..15 */
                        int rn = 15 - i;
                        uint32_t val = (rn < 8) ? D[rn] : A[rn - 8];
                        a -= sz;
                        if (sz == 4)
                            wr32(a, val);
                        else
                            wr16(a, val);
                        }
                A[reg] = a;
                }
            /* postincrement mem->reg */
            else if (dr == 1 && mode == 3)
                {
                uint32_t a = A[reg];
                for (int i = 0; i < 16; i++)
                    if (list & (1 << i))
                        {
                        uint32_t val = (sz == 4) ? rd32(a) : (uint32_t)(int16_t)rd16(a);
                        if (i < 8)
                            D[i] = (sz == 4) ? val : (D[i] & 0xFFFF0000) | (val & 0xFFFF);
                        else
                            A[i - 8] = val;
                        a += sz;
                        }
                A[reg] = a;
                }
            /* control modes */
            else
                {
                uint32_t a = ea_address(mode, reg);
                for (int i = 0; i < 16; i++)
                    if (list & (1 << i))
                        {
                        if (dr == 0)
                            {
                            uint32_t val = (i < 8) ? D[i] : A[i - 8];
                            if (sz == 4)
                                wr32(a, val);
                            else
                                wr16(a, val);
                            }
                        else
                            {
                            uint32_t val = (sz == 4) ? rd32(a) : (uint32_t)(int16_t)rd16(a);
                            if (i < 8)
                                D[i] = (sz == 4) ? val : (D[i] & 0xFFFF0000) | (val & 0xFFFF);
                            else
                                A[i - 8] = val;
                            }
                        a += sz;
                        }
                }
            break;
            }
        /* CHK (treat as no-trap bounds, set flags only) */
        if ((op & 0xF1C0) == 0x4180)
            {
            int dn = (op >> 9) & 7;
            EA e = decode_ea((op >> 3) & 7, op & 7, 2);
            int16_t bound = (int16_t)ea_load(&e, 2);
            int16_t val = (int16_t)(D[dn] & 0xFFFF);
            flag_n = (val < 0);
            (void)bound;
            break;
            }
        if (op == 0x4E76)
            {
            /* TRAPV */
            if (flag_v)
                {
                }
            break;
            }
        /* MULU.L / MULS.L (68020+, 32x32->32) */
        if ((op & 0xFFC0) == 0x4C00)
            {
            if (cpu_kind < 68020)
                require_68020("MULS.L/MULU.L");
            uint16_t ext = fetch16();
            int dl = (ext >> 12) & 7, is_signed = (ext >> 11) & 1;
            EA e = decode_ea((op >> 3) & 7, op & 7, 4);
            uint32_t s = ea_load(&e, 4);
            D[dl] = is_signed ? (uint32_t)((int32_t)D[dl] * (int32_t)s) : D[dl] * s;
            set_logic_flags(D[dl], 4);
            break;
            }
        /* DIVU.L / DIVS.L (68020+, 32/32->32) */
        if ((op & 0xFFC0) == 0x4C40)
            {
            if (cpu_kind < 68020)
                require_68020("DIVS.L/DIVU.L");
            uint16_t ext = fetch16();
            int dq = (ext >> 12) & 7, dr = ext & 7, is_signed = (ext >> 11) & 1;
            EA e = decode_ea((op >> 3) & 7, op & 7, 4);
            uint32_t s = ea_load(&e, 4);
            if (s == 0)
                {
                do_trap(5);
                break;
                }
            if (is_signed)
                {
                int32_t q = (int32_t)D[dq] / (int32_t)s, rm = (int32_t)D[dq] % (int32_t)s;
                D[dq] = (uint32_t)q;
                if (dr != dq)
                    D[dr] = (uint32_t)rm;
                }
            else
                {
                uint32_t q = D[dq] / s, rm = D[dq] % s;
                D[dq] = q;
                if (dr != dq)
                    D[dr] = rm;
                }
            set_logic_flags(D[dq], 4);
            break;
            }
        /* Unknown 0100-group opcode */
        fprintf(stderr, "sim68k: unimplemented opcode $%04X at $%06X\n", op, op_pc);
        running = 0;
        return 1;
        }

    /* ---- 1101 : ADD / ADDA ; 1001 : SUB / SUBA --------------------- */
    case 0x9:
    case 0xD:
        {
        int is_add = (top == 0xD);
        int reg = (op >> 9) & 7, opmode = (op >> 6) & 7;
        int mode = (op >> 3) & 7, ea_reg = op & 7;
        /* ADDA/SUBA */
        if (opmode == 3 || opmode == 7)
            {
            int sz = (opmode == 3) ? 2 : 4;
            EA e = decode_ea(mode, ea_reg, sz);
            uint32_t v = ea_load(&e, sz);
            if (sz == 2)
                v = (uint32_t)(int16_t)v;
            if (is_add)
                A[reg] += v;
            else
                A[reg] -= v;
            }
        else
            {
            int sz = opmode & 3;
            sz = sz == 0 ? 1 : sz == 1 ? 2
                                       : 4;
            int dir = (opmode >> 2) & 1; /* 0: <ea>+Dn->Dn, 1: Dn+<ea>-><ea> */
            /* ADDX/SUBX Dy,Dx (register form) */
            if (dir == 1 && mode == 0)
                {
                uint32_t s = D[ea_reg] & size_mask(sz);
                uint32_t dd = D[reg] & size_mask(sz);
                uint32_t x = flag_x ? 1u : 0u, r;
                int oldz = flag_z;
                if (is_add)
                    {
                    r = s + dd + x;
                    set_add_flags(s, dd, r, sz);
                    }
                else
                    {
                    r = dd - s - x;
                    set_sub_flags(s, dd, r, sz);
                    }
                /* X-form Z is sticky: cleared on nonzero, else unchanged */
                flag_z = (r & size_mask(sz)) ? 0 : oldz;
                D[reg] = (D[reg] & ~size_mask(sz)) | (r & size_mask(sz));
                break;
                }
            EA e = decode_ea(mode, ea_reg, sz);
            uint32_t s, d, r;
            if (dir == 0)
                {
                s = ea_load(&e, sz);
                d = D[reg] & size_mask(sz);
                }
            else
                {
                s = D[reg] & size_mask(sz);
                d = ea_load(&e, sz);
                }
            if (is_add)
                {
                r = s + d;
                set_add_flags(s, d, r, sz);
                }
            else
                {
                r = d - s;
                set_sub_flags(s, d, r, sz);
                }
            if (dir == 0)
                D[reg] = (D[reg] & ~size_mask(sz)) | (r & size_mask(sz));
            else
                ea_store(&e, sz, r);
            }
        break;
        }

    /* ---- 1100 : AND / MULU / MULS / EXG ; 1000 : OR / DIVU / DIVS --- */
    case 0x8:
    case 0xC:
        {
        int is_and = (top == 0xC);
        int reg = (op >> 9) & 7, opmode = (op >> 6) & 7;
        int mode = (op >> 3) & 7, ea_reg = op & 7;
        /* EXG */
        if (is_and && (opmode == 5 || opmode == 6) && mode == 0)
            {
            int rx = reg, ry = ea_reg;
            if (opmode == 5)
                {
                uint32_t t = D[rx];
                D[rx] = D[ry];
                D[ry] = t;
                }
            else if (opmode == 6)
                {
                uint32_t t = D[rx];
                D[rx] = A[ry];
                A[ry] = t;
                }
            break;
            }
        /* MULU.W (0xC) — unsigned; opmode 3 is never signed */
        if (opmode == 3)
            {
            EA e = decode_ea(mode, ea_reg, 2);
            uint32_t s = ea_load(&e, 2);
            D[reg] = (uint32_t)((D[reg] & 0xFFFF) * (s & 0xFFFF));
            set_logic_flags(D[reg], 4);
            break;
            }
        /* MULS.W (0xC) — signed */
        if (opmode == 7 && is_and)
            {
            EA e = decode_ea(mode, ea_reg, 2);
            int32_t s = (int32_t)(int16_t)ea_load(&e, 2);
            D[reg] = (uint32_t)((int32_t)(int16_t)(D[reg] & 0xFFFF) * s);
            set_logic_flags(D[reg], 4);
            break;
            }
        /* DIVS (word) */
        if (opmode == 7)
            {
            EA e = decode_ea(mode, ea_reg, 2);
            int32_t s = (int32_t)(int16_t)ea_load(&e, 2);
            /* zero divide -> trap vec 5 */
            if (s == 0)
                {
                do_trap(5);
                break;
                }
            int32_t dv = (int32_t)D[reg];
            int32_t q = dv / s, r = dv % s;
            flag_c = 0;
            if (q < -32768 || q > 32767)
                {
                flag_v = 1;
                }
            else
                {
                flag_v = 0;
                D[reg] = ((uint32_t)(r & 0xFFFF) << 16) | (uint16_t)q;
                flag_n = (q < 0);
                flag_z = (q == 0);
                }
            break;
            }
        /* DIVU (word) */
        if (opmode == 6 && !is_and)
            {
            EA e = decode_ea(mode, ea_reg, 2);
            uint32_t s = ea_load(&e, 2) & 0xFFFF;
            if (s == 0)
                {
                do_trap(5);
                break;
                }
            uint32_t dv = D[reg];
            uint32_t q = dv / s, r = dv % s;
            flag_c = 0;
            if (q > 0xFFFF)
                {
                flag_v = 1;
                }
            else
                {
                flag_v = 0;
                D[reg] = (r << 16) | (q & 0xFFFF);
                flag_n = (q & 0x8000) != 0;
                flag_z = (q == 0);
                }
            break;
            }
        /* AND / OR */
        int sz = opmode & 3;
        sz = sz == 0 ? 1 : sz == 1 ? 2
                                   : 4;
        int dir = (opmode >> 2) & 1;
        EA e = decode_ea(mode, ea_reg, sz);
        uint32_t s, d, r;
        if (dir == 0)
            {
            s = ea_load(&e, sz);
            d = D[reg] & size_mask(sz);
            }
        else
            {
            s = D[reg] & size_mask(sz);
            d = ea_load(&e, sz);
            }
        r = is_and ? (s & d) : (s | d);
        if (dir == 0)
            D[reg] = (D[reg] & ~size_mask(sz)) | (r & size_mask(sz));
        else
            ea_store(&e, sz, r);
        set_logic_flags(r, sz);
        break;
        }

    /* ---- 1011 : CMP / CMPA / EOR / CMPM ---------------------------- */
    case 0xB:
        {
        int reg = (op >> 9) & 7, opmode = (op >> 6) & 7;
        int mode = (op >> 3) & 7, ea_reg = op & 7;
        /* CMPA */
        if (opmode == 3 || opmode == 7)
            {
            int sz = (opmode == 3) ? 2 : 4;
            EA e = decode_ea(mode, ea_reg, sz);
            uint32_t s = ea_load(&e, sz);
            if (sz == 2)
                s = (uint32_t)(int16_t)s;
            uint32_t d = A[reg], r = d - s;
            set_cmp_flags(s, d, r, 4);
            break;
            }
        int sz = opmode & 3;
        sz = sz == 0 ? 1 : sz == 1 ? 2
                                   : 4;
        /* CMP */
        if ((opmode & 4) == 0)
            {
            EA e = decode_ea(mode, ea_reg, sz);
            uint32_t s = ea_load(&e, sz), d = D[reg] & size_mask(sz), r = d - s;
            set_cmp_flags(s, d, r, sz);
            }
        /* CMPM (An)+,(An)+ */
        else if (mode == 1)
            {
            EA se = decode_ea(3, ea_reg, sz), de = decode_ea(3, reg, sz);
            uint32_t s = ea_load(&se, sz), d = ea_load(&de, sz), r = d - s;
            set_cmp_flags(s, d, r, sz);
            }
        /* EOR */
        else
            {
            EA e = decode_ea(mode, ea_reg, sz);
            uint32_t r = ea_load(&e, sz) ^ (D[reg] & size_mask(sz));
            ea_store(&e, sz, r);
            set_logic_flags(r, sz);
            }
        break;
        }

    /* ---- 0000 : immediates + bit ops ------------------------------- */
    case 0x0:
        {
        int mode = (op >> 3) & 7, ea_reg = op & 7;
        /* Static bit ops: 0000 1000 ssmmmrrr, bit# in following word */
        if ((op & 0xFF00) == 0x0800)
            {
            int btype = (op >> 6) & 3; /* 0 BTST 1 BCHG 2 BCLR 3 BSET */
            uint16_t bit = fetch16();
            int sz = (mode == 0) ? 4 : 1;
            EA e = decode_ea(mode, ea_reg, sz);
            bit &= (sz == 4) ? 31 : 7;
            uint32_t v = ea_load(&e, sz);
            flag_z = ((v >> bit) & 1) == 0;
            if (btype == 1)
                v ^= (1u << bit);
            else if (btype == 2)
                v &= ~(1u << bit);
            else if (btype == 3)
                v |= (1u << bit);
            if (btype != 0)
                ea_store(&e, sz, v);
            break;
            }
        /* Dynamic bit ops: 0000 rrr1 ttmmmrrr */
        if ((op & 0xF100) == 0x0100)
            {
            int dn = (op >> 9) & 7, btype = (op >> 6) & 3;
            int sz = (mode == 0) ? 4 : 1;
            EA e = decode_ea(mode, ea_reg, sz);
            int bit = D[dn] & (sz == 4 ? 31 : 7);
            uint32_t v = ea_load(&e, sz);
            flag_z = ((v >> bit) & 1) == 0;
            if (btype == 1)
                v ^= (1u << bit);
            else if (btype == 2)
                v &= ~(1u << bit);
            else if (btype == 3)
                v |= (1u << bit);
            if (btype != 0)
                ea_store(&e, sz, v);
            break;
            }
        /* Immediate ALU: ORI/ANDI/SUBI/ADDI/EORI/CMPI */
        int kind = (op >> 9) & 7;
        int sz = (op >> 6) & 3;
        sz = sz == 0 ? 1 : sz == 1 ? 2
                                   : 4;
        uint32_t imm = (sz == 4) ? fetch32() : (uint32_t)fetch16() & size_mask(sz);
        /* ORI/ANDI/EORI to CCR/SR special forms */
        /* #imm,CCR */
        if ((op & 0x00FF) == 0x003C)
            {
            uint16_t c = get_sr() & 0x1F;
            if (kind == 0)
                c |= imm;
            else if (kind == 1)
                c &= imm;
            else if (kind == 5)
                c ^= imm;
            set_ccr(c);
            break;
            }
        /* #imm,SR */
        if ((op & 0x00FF) == 0x007C)
            {
            uint16_t s = get_sr();
            if (kind == 0)
                s |= imm;
            else if (kind == 1)
                s &= imm;
            else if (kind == 5)
                s ^= imm;
            set_sr(s);
            break;
            }
        EA e = decode_ea(mode, ea_reg, sz);
        uint32_t d = ea_load(&e, sz), r;
        switch (kind)
            {
        case 0:
            r = d | imm;
            ea_store(&e, sz, r);
            set_logic_flags(r, sz);
            break; /* ORI */
        case 1:
            r = d & imm;
            ea_store(&e, sz, r);
            set_logic_flags(r, sz);
            break; /* ANDI */
        case 2:
            r = d - imm;
            ea_store(&e, sz, r);
            set_sub_flags(imm, d, r, sz);
            break; /* SUBI */
        case 3:
            r = d + imm;
            ea_store(&e, sz, r);
            set_add_flags(imm, d, r, sz);
            break; /* ADDI */
        case 5:
            r = d ^ imm;
            ea_store(&e, sz, r);
            set_logic_flags(r, sz);
            break; /* EORI */
        case 6:
            r = d - imm;
            set_cmp_flags(imm, d, r, sz);
            break; /* CMPI */
        default:
            fprintf(stderr, "sim68k: bad immediate group $%04X at $%06X\n", op, op_pc);
            running = 0;
            return 1;
            }
        break;
        }

    /* ---- 1110 : shifts / rotates ----------------------------------- */
    case 0xE:
        {
        int mode_mem = ((op >> 6) & 3) == 3;
        /* memory shift by 1 */
        if (mode_mem)
            {
            int type = (op >> 9) & 3, dir = (op >> 8) & 1;
            EA e = decode_ea((op >> 3) & 7, op & 7, 2);
            uint32_t v = ea_load(&e, 2);
            uint32_t r;
            /* AS */
            if (type == 0)
                {
                if (dir)
                    {
                    r = (v << 1);
                    }
                else
                    {
                    r = ((int16_t)v) >> 1;
                    }
                }
            /* LS */
            else if (type == 1)
                {
                r = dir ? (v << 1) : (v >> 1);
                }
            /* ROX */
            else if (type == 2)
                {
                r = dir ? ((v << 1) | flag_x) : ((v >> 1) | (flag_x << 15));
                }
            /* RO */
            else
                {
                r = dir ? ((v << 1) | (v >> 15)) : ((v >> 1) | (v << 15));
                }
            ea_store(&e, 2, r);
            set_logic_flags(r, 2);
            flag_c = dir ? msb_set(v, 2) : (v & 1);
            break;
            }
        int count_in_reg = (op >> 5) & 1;
        int type = (op >> 3) & 3, dir = (op >> 8) & 1;
        int sz = (op >> 6) & 3;
        sz = sz == 0 ? 1 : sz == 1 ? 2
                                   : 4;
        int reg = op & 7;
        int cnt = (op >> 9) & 7;
        if (count_in_reg)
            cnt = D[cnt] & 63;
        else if (cnt == 0)
            cnt = 8;
        uint32_t v = D[reg] & size_mask(sz);
        int last_c = flag_c;
        for (int i = 0; i < cnt; i++)
            {
            /* ASL/ASR */
            if (type == 0)
                {
                if (dir)
                    {
                    last_c = msb_set(v, sz);
                    v = (v << 1) & size_mask(sz);
                    }
                else
                    {
                    last_c = v & 1;
                    v = (uint32_t)(sign_ext(v, sz) >> 1) & size_mask(sz);
                    }
                }
            /* LSL/LSR */
            else if (type == 1)
                {
                if (dir)
                    {
                    last_c = msb_set(v, sz);
                    v = (v << 1) & size_mask(sz);
                    }
                else
                    {
                    last_c = v & 1;
                    v = (v >> 1) & size_mask(sz);
                    }
                }
            /* ROL/ROR */
            else if (type == 3)
                {
                if (dir)
                    {
                    last_c = msb_set(v, sz);
                    v = ((v << 1) | last_c) & size_mask(sz);
                    }
                else
                    {
                    last_c = v & 1;
                    v = ((v >> 1) | ((uint32_t)last_c << (sz * 8 - 1))) & size_mask(sz);
                    }
                }
            /* ROXL/ROXR */
            else
                {
                if (dir)
                    {
                    int nc = msb_set(v, sz);
                    v = ((v << 1) | flag_x) & size_mask(sz);
                    flag_x = nc;
                    last_c = nc;
                    }
                else
                    {
                    int nc = v & 1;
                    v = ((v >> 1) | ((uint32_t)flag_x << (sz * 8 - 1))) & size_mask(sz);
                    flag_x = nc;
                    last_c = nc;
                    }
                }
            }
        D[reg] = (D[reg] & ~size_mask(sz)) | (v & size_mask(sz));
        flag_n = msb_set(v, sz);
        flag_z = (v == 0);
        flag_v = 0;
        if (cnt)
            {
            flag_c = last_c;
            if (type != 2)
                flag_x = (type == 3) ? flag_x : last_c;
            }
        else
            flag_c = 0;
        break;
        }

    /* ---- 1010 : line-A math HLE (FPU-less soft-float / int mul-div) - */
    case 0xA:
        if (line_a_step(op))
            {
            running = 0;
            return 1;
            }
        break;

    /* ---- 1111 : 68881/68882 FPU (line-F, coprocessor id 1) ---------- */
    case 0xF:
        {
        if ((op & 0xFFC0) == 0xF200) /* general / FMOVE */
            {
            if (fpu_step(op))
                {
                running = 0;
                return 1;
                }
            break;
            }
        /* FScc <ea> */
        if ((op & 0xFFC0) == 0xF240)
            {
            uint16_t pred = fetch16() & 0x3F;
            int t = fpu_cond(pred);
            EA e = decode_ea((op >> 3) & 7, op & 7, 1);
            ea_store(&e, 1, t ? 0xFF : 0x00);
            break;
            }
        /* FBcc (word displacement) */
        if ((op & 0xFF80) == 0xF280)
            {
            uint16_t pred = op & 0x3F;
            int32_t disp = (int16_t)fetch16();
            uint32_t base = PC - 2;
            if (fpu_cond(pred))
                PC = base + disp;
            break;
            }
        fprintf(stderr, "sim68k: unimplemented FPU opcode $%04X at $%06X\n", op, op_pc);
        running = 0;
        return 1;
        }

    default:
        /* ILLEGAL ($4AFC) never reaches here — it is caught ahead of the
         * dispatch, because line-4 would claim it first. See the top of step().  */
        fprintf(stderr, "sim68k: unimplemented opcode $%04X at $%06X\n", op, op_pc);
        running = 0;
        return 1;
        }

    return running ? 0 : 1;
    }

/* ════════════════════════════════════════════════════════════════════
 *  GEMDOS / BIOS / XBIOS — high-level trap emulation (ABI-faithful)
 * ════════════════════════════════════════════════════════════════════
 * On TRAP the user-mode caller has pushed [fn.w][args...] onto its
 * stack; A7 points at fn. We read args off A7, set the result in D0,
 * and resume after the trap. The caller cleans up its own arguments.
 */
static uint32_t sp_base; /* A7 at the trap instruction */
static inline uint16_t arg16(int off)
    {
    return rd16(sp_base + off);
    }
static inline uint32_t arg32(int off)
    {
    return rd32(sp_base + off);
    }

/* Simple host-file handle table: ST handle -> host fd. 0-5 reserved
   (con/aux/prn std handles). */
#define HFIRST 6
#define HMAX 64
static int host_fd[HMAX];

/* Bump allocator within the TPA for Malloc. */
static uint32_t heap_ptr = 0, heap_end = 0;

static void put_console(int c)
    {
    putchar(c);
    }

static void gemdos_call(void)
    {
    uint16_t fn = arg16(0);
    switch (fn)
        {
    case 0x00: /* Pterm0 */
        running = 0;
        terminated_via_pterm = 1;
        exit_code = 0;
        return;
    case 0x4C: /* Pterm */
        running = 0;
        terminated_via_pterm = 1;
        exit_code = (int16_t)arg16(2);
        return;
    /* Cconin (with echo) */
    case 0x01:
        {
        int c = getchar();
        if (c == EOF)
            c = 0;
        put_console(c);
        D[0] = (uint32_t)(c & 0xFF);
        break;
        }
    case 0x07:
    /* Crawcin / Cnecin (no echo) */
    case 0x08:
        {
        int c = getchar();
        if (c == EOF)
            c = 0;
        D[0] = (uint32_t)(c & 0xFF);
        break;
        }
    case 0x02: /* Cconout */
        put_console(arg16(2) & 0xFF);
        D[0] = 0;
        break;
    /* Cconws */
    case 0x09:
        {
        uint32_t p = arg32(2);
        uint32_t n = 0;
        uint8_t ch;
        while ((ch = rd8(p++)) != 0)
            {
            put_console(ch);
            n++;
            }
        D[0] = n;
        break;
        }
    /* Cconrs - read string (rare) */
    case 0x10:
        {
        D[0] = 0;
        (void)arg32(2);
        break;
        }
    case 0x20: /* Super */
        /* query/toggle supervisor; return a benign old-stack value */
        D[0] = 0;
        break;
    case 0x2A: /* Tgetdate (fixed, deterministic) */
        D[0] = ((2026 - 1980) << 9) | (6 << 5) | 25;
        break;
    case 0x2C: /* Tgettime */
        D[0] = (12 << 11) | (0 << 5) | 0;
        break;
    case 0x30: /* Sversion */
        D[0] = 0x1900;
        break;
    /* Malloc */
    case 0x48:
        {
        uint32_t amt = arg32(2);
        if (amt == 0xFFFFFFFF)
            {
            D[0] = heap_end - heap_ptr;
            break;
            }
        if (heap_ptr + amt > heap_end)
            {
            D[0] = 0;
            break;
            }
        D[0] = heap_ptr;
        heap_ptr += (amt + 1) & ~1u;
        break;
        }
    case 0x49: /* Mfree */
        D[0] = 0;
        break;
    /* Mshrink(dummy.w, block.l, newsize.l) */
    case 0x4A:
        {
        uint32_t block = arg32(4), newsize = arg32(8);
        /* Keep [block, block+newsize); the heap (Malloc) lives above it so it
           doesn't collide with the program's new stack inside the kept TPA. */
        uint32_t kept_end = block + newsize;
        if (kept_end > heap_ptr && kept_end < heap_end)
            heap_ptr = kept_end;
        D[0] = 0;
        break;
        }
    /* Fcreate */
    case 0x3C:
        {
        char path[1024];
        uint32_t p = arg32(2);
        int i = 0;
        while (i < 1023 && (path[i] = rd8(p + i)))
            i++;
        path[i] = 0;
        int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
        if (fd < 0)
            {
            D[0] = (uint32_t)-33;
            break;
            }
        int h = -1;
        for (int k = HFIRST; k < HMAX; k++)
            if (host_fd[k] < 0)
                {
                host_fd[k] = fd;
                h = k;
                break;
                }
        if (h < 0)
            {
            close(fd);
            D[0] = (uint32_t)-35;
            break;
            }
        D[0] = h;
        break;
        }
    /* Fopen */
    case 0x3D:
        {
        char path[1024];
        uint32_t p = arg32(2);
        int mode = arg16(6);
        int i = 0;
        while (i < 1023 && (path[i] = rd8(p + i)))
            i++;
        path[i] = 0;
        int flags = (mode == 0) ? O_RDONLY : (mode == 1) ? O_WRONLY
                                                         : O_RDWR;
        int fd = open(path, flags);
        if (fd < 0)
            {
            D[0] = (uint32_t)-33;
            break;
            }
        int h = -1;
        for (int k = HFIRST; k < HMAX; k++)
            if (host_fd[k] < 0)
                {
                host_fd[k] = fd;
                h = k;
                break;
                }
        if (h < 0)
            {
            close(fd);
            D[0] = (uint32_t)-35;
            break;
            }
        D[0] = h;
        break;
        }
    /* Fclose */
    case 0x3E:
        {
        int h = (int16_t)arg16(2);
        if (h >= HFIRST && h < HMAX && host_fd[h] >= 0)
            {
            close(host_fd[h]);
            host_fd[h] = -1;
            D[0] = 0;
            }
        else
            D[0] = (uint32_t)-37;
        break;
        }
    /* Fread(handle, count, buf) */
    case 0x3F:
        {
        int h = (int16_t)arg16(2);
        uint32_t cnt = arg32(4), buf = arg32(8);
        /* stdin */
        if (h == 0)
            {
            uint32_t n = 0;
            while (n < cnt)
                {
                int c = getchar();
                if (c == EOF)
                    break;
                wr8(buf + n, c);
                n++;
                }
            D[0] = n;
            break;
            }
        if (h < HFIRST || h >= HMAX || host_fd[h] < 0)
            {
            D[0] = (uint32_t)-37;
            break;
            }
        uint8_t* tmp = malloc(cnt ? cnt : 1);
        ssize_t got = read(host_fd[h], tmp, cnt);
        for (ssize_t k = 0; k < got; k++)
            wr8(buf + k, tmp[k]);
        free(tmp);
        D[0] = (got < 0) ? 0 : (uint32_t)got;
        break;
        }
    /* Fwrite(handle, count, buf) */
    case 0x40:
        {
        int h = (int16_t)arg16(2);
        uint32_t cnt = arg32(4), buf = arg32(8);
        if (h == 1 || h == 2)
            {
            for (uint32_t k = 0; k < cnt; k++)
                put_console(rd8(buf + k));
            D[0] = cnt;
            break;
            }
        if (h < HFIRST || h >= HMAX || host_fd[h] < 0)
            {
            D[0] = (uint32_t)-37;
            break;
            }
        uint8_t* tmp = malloc(cnt ? cnt : 1);
        for (uint32_t k = 0; k < cnt; k++)
            tmp[k] = rd8(buf + k);
        ssize_t put = write(host_fd[h], tmp, cnt);
        free(tmp);
        D[0] = (put < 0) ? 0 : (uint32_t)put;
        break;
        }
    /* Fseek(offset, handle, mode) */
    case 0x42:
        {
        int32_t off = (int32_t)arg32(2);
        int h = (int16_t)arg16(6);
        int mode = arg16(8);
        if (h < HFIRST || h >= HMAX || host_fd[h] < 0)
            {
            D[0] = (uint32_t)-37;
            break;
            }
        off_t r = lseek(host_fd[h], off, mode);
        D[0] = (uint32_t)r;
        break;
        }
    case 0x19: /* Dgetdrv */
        D[0] = 0;
        break;
    default:
        if (traptrace)
            fprintf(stderr, "[gemdos] UNHANDLED fn=$%02X\n", fn);
        D[0] = (uint32_t)-32; /* EINVFN */
        break;
        }
    if (traptrace)
        fprintf(stderr, "[gemdos] fn=$%02X -> D0=$%08X\n", fn, D[0]);
    }

static void bios_call(void)
    {
    uint16_t fn = arg16(0);
    switch (fn)
        {
    case 0x01: /* Bconstat */
        D[0] = 0;
        break; /* no input pending */
    /* Bconin */
    case 0x02:
        {
        int c = getchar();
        if (c == EOF)
            c = 0;
        D[0] = (uint32_t)(c & 0xFF);
        break;
        }
    /* Bconout(dev, c) */
    case 0x03:
        {
        put_console(arg16(4) & 0xFF);
        D[0] = 0;
        break;
        }
    case 0x07: /* Getbpb */
        D[0] = 0;
        break;
    case 0x0A: /* Drvmap */
        D[0] = 0x3;
        break; /* drives A: and C: */
    case 0x0B: /* Kbshift */
        D[0] = 0;
        break;
    default:
        if (traptrace)
            fprintf(stderr, "[bios] UNHANDLED fn=$%02X\n", fn);
        D[0] = 0;
        break;
        }
    if (traptrace)
        fprintf(stderr, "[bios] fn=$%02X -> D0=$%08X\n", fn, D[0]);
    }

static void xbios_call(void)
    {
    uint16_t fn = arg16(0);
    switch (fn)
        {
    case 0x02:
        D[0] = FB_BASE;
        break; /* Physbase */
    case 0x03:
        D[0] = FB_BASE;
        break; /* Logbase  */
    case 0x04:
        D[0] = 2;
        break; /* Getrez -> high-res mono */
    case 0x05:
        D[0] = 0;
        break; /* Setscreen (no-op) */
    case 0x06:
        D[0] = 0;
        break; /* Setpalette */
    case 0x07:
        D[0] = 0;
        break; /* Setcolor */
    case 0x25:
        D[0] = 0;
        break; /* Vsync (no-op) */
    /* Random — deterministic LCG */
    case 0x11:
        {
        static uint32_t seed = 0x12345678u;
        seed = seed * 1103515245u + 12345u;
        D[0] = (seed >> 8) & 0xFFFFFF;
        break;
        }
    default:
        if (traptrace)
            fprintf(stderr, "[xbios] UNHANDLED fn=$%02X\n", fn);
        D[0] = 0;
        break;
        }
    if (traptrace)
        fprintf(stderr, "[xbios] fn=$%02X -> D0=$%08X\n", fn, D[0]);
    }

static void do_trap(int vec)
    {
    sp_base = A[7];
    switch (vec)
        {
    case 1:
        if (traptrace)
            fprintf(stderr, "[trap#1 gemdos] ");
        gemdos_call();
        break;
    case 13:
        if (traptrace)
            fprintf(stderr, "[trap#13 bios] ");
        bios_call();
        break;
    case 14:
        if (traptrace)
            fprintf(stderr, "[trap#14 xbios] ");
        xbios_call();
        break;
    case 2: /* AES/VDI — reserved for the XT GEM graphics backend (TODO) */
        if (traptrace)
            fprintf(stderr, "[trap#2 aes/vdi] (stub)\n");
        D[0] = 0;
        break;
    case 5:
        fprintf(stderr, "sim68k: integer divide-by-zero\n");
        running = 0;
        break;
    default:
        if (traptrace)
            fprintf(stderr, "[trap#%d] (stub)\n", vec);
        break;
        }
    }

/* ════════════════════════════════════════════════════════════════════
 *  GEMDOS executable ($601A) loader
 * ════════════════════════════════════════════════════════════════════ */
static int load_prg(const char* fn, const char* cmdline)
    {
    FILE* f = fopen(fn, "rb");
    if (!f)
        {
        fprintf(stderr, "sim68k: cannot open '%s'\n", fn);
        return -1;
        }
    fseek(f, 0, SEEK_END);
    long flen = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t* buf = malloc(flen);
    if (fread(buf, 1, flen, f) != (size_t)flen)
        {
        fclose(f);
        free(buf);
        return -1;
        }
    fclose(f);

    if (flen < 28 || buf[0] != 0x60 || buf[1] != 0x1A)
        {
        fprintf(stderr, "sim68k: '%s' is not a GEMDOS ($601A) executable\n", fn);
        free(buf);
        return -1;
        }
#define BE32(p) (((uint32_t)(p)[0] << 24) | ((p)[1] << 16) | ((p)[2] << 8) | (p)[3])
    uint32_t tsize = BE32(buf + 2);
    uint32_t dsize = BE32(buf + 6);
    uint32_t bsize = BE32(buf + 10);
    uint32_t ssize = BE32(buf + 14);
    uint16_t absflag = (buf[26] << 8) | buf[27];

    uint32_t tbase = LOAD_BASE + 0x100; /* text after basepage */
    uint32_t dbase = tbase + tsize;
    uint32_t bbase = dbase + dsize;

    if (!in_range(tbase, tsize + dsize + bsize))
        {
        fprintf(stderr, "sim68k: program too large for %u MB of RAM\n", mem_bytes >> 20);
        free(buf);
        return -1;
        }
    /* TEXT + DATA */
    for (uint32_t i = 0; i < tsize; i++)
        wr8(tbase + i, buf[28 + i]);
    for (uint32_t i = 0; i < dsize; i++)
        wr8(dbase + i, buf[28 + tsize + i]);
    /* BSS */
    for (uint32_t i = 0; i < bsize; i++)
        wr8(bbase + i, 0);

    /* Relocation: a longword (offset of first fixup) then a byte stream. */
    if (!absflag)
        {
        uint32_t roff = 28 + tsize + dsize + ssize;
        if (roff + 4 <= (uint32_t)flen)
            {
            uint32_t first = BE32(buf + roff);
            roff += 4;
            uint32_t delta = tbase; /* linked at 0 -> loaded at tbase */
            if (first != 0)
                {
                uint32_t addr = tbase + first;
                wr32(addr, rd32(addr) + delta);
                while (roff < (uint32_t)flen)
                    {
                    uint8_t b = buf[roff++];
                    if (b == 0)
                        break;
                    if (b == 1)
                        {
                        addr += 254;
                        continue;
                        }
                    addr += b;
                    wr32(addr, rd32(addr) + delta);
                    }
                }
            }
        }
    free(buf);

    /* Basepage at LOAD_BASE (256 bytes). */
    uint32_t bp = LOAD_BASE;
    uint32_t tpa_end = mem_bytes - 0x100; /* leave a guard at top */
    uint32_t envp = tpa_end - 4;
    wr8(envp, 0); /* empty environment */
    memset(mem + bp, 0, 0x100);
    wr32(bp + 0x00, bp);      /* p_lowtpa */
    wr32(bp + 0x04, tpa_end); /* p_hitpa  */
    wr32(bp + 0x08, tbase);
    wr32(bp + 0x0C, tsize);
    wr32(bp + 0x10, dbase);
    wr32(bp + 0x14, dsize);
    wr32(bp + 0x18, bbase);
    wr32(bp + 0x1C, bsize);
    wr32(bp + 0x24, 0);    /* p_parent */
    wr32(bp + 0x2C, envp); /* p_env    */
    /* command line: Pascal string at +0x80 */
    int clen = cmdline ? (int)strlen(cmdline) : 0;
    if (clen > 125)
        clen = 125;
    wr8(bp + 0x80, clen);
    for (int i = 0; i < clen; i++)
        wr8(bp + 0x81 + i, cmdline[i]);

    /* heap (Malloc) lives above bss, below the stack. */
    heap_ptr = (bbase + bsize + 1) & ~1u;
    heap_end = tpa_end - 0x4000; /* reserve 16 KB for stack */

    /* Stack + entry: 4(sp) = basepage. */
    uint32_t sp = tpa_end - 0x10;
    sp -= 4;
    wr32(sp, bp); /* basepage pointer */
    sp -= 4;
    wr32(sp, 0); /* fake return addr */
    A[7] = sp;
    PC = tbase;
    return 0;
    }

/* ── Memory-prefill map loader (same format as xts) ─────────────────── */
static unsigned long parse_num(const char* s, char** ep)
    {
    while (*s == ' ' || *s == '\t')
        s++;
    if (s[0] == '$')
        return strtoul(s + 1, ep, 16);
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
        return strtoul(s + 2, ep, 16);
    return strtoul(s, ep, 0);
    }
static void load_map(const char* fn)
    {
    FILE* f = fopen(fn, "r");
    if (!f)
        {
        fprintf(stderr, "sim68k: cannot open map '%s'\n", fn);
        return;
        }
    char line[1024];
    while (fgets(line, sizeof line, f))
        {
        char* h = strchr(line, '#');
        if (h)
            *h = 0;
        char* colon = strchr(line, ':');
        if (!colon)
            continue;
        char* ep;
        unsigned long addr = parse_num(line, &ep);
        char* p = colon + 1;
        while (*p)
            {
            while (*p == ' ' || *p == '\t' || *p == ',')
                p++;
            if (!*p || *p == '\n')
                break;
            unsigned long byte = parse_num(p, &ep);
            if (ep == p)
                break;
            wr8((uint32_t)addr++, (uint8_t)byte);
            p = ep;
            }
        }
    fclose(f);
    }

/* ── CLI ─────────────────────────────────────────────────────────────── */
static void sigint_handler(int s)
    {
    (void)s;
    running = 0;
    }

static void print_usage(FILE* f)
    {
    fprintf(f,
            "Usage: xst [options] <file.prg> [mapfile]\n"
            "\n"
            "A Motorola 68000/68030 simulator for Atari ST GEMDOS executables\n"
            "($601A .PRG/.TOS/.TTP/.ACC) produced by xtc. GEMDOS/BIOS/XBIOS calls\n"
            "are high-level-emulated; console output streams to stdout.\n"
            "\n"
            "Arguments:\n"
            "  <file.prg>     GEMDOS executable to load and run.\n"
            "  [mapfile]      Optional memory prefill: lines 'ADDR: b0 b1 ...'.\n"
            "\n"
            "Options:\n"
            "  -h, --help        Show this help and exit.\n"
            "  -v, --version     Print version and exit.\n"
            "  -d, --dump-output Stream console output to stdout (oracle mode).\n"
            "  --cycles          Print the instruction count at exit.\n"
            "  --cpu <n>         CPU variant: 68000 (default) or 68030.\n"
            "  --mem <MB>        RAM size in megabytes (default 4).\n"
            "  --args \"...\"      Command line passed to the program (basepage).\n"
            "\n"
            "Instrumentation (environment variables):\n"
            "  XST_ITRACE=1            Trace every instruction to stderr.\n"
            "  XST_ITRACE_TRIGGER=hex  Begin tracing when PC reaches this address.\n"
            "  XST_ITRACE_STOP=hex     Stop tracing at this address.\n"
            "  XST_ITRACE_MAX=dec      Cap on traced instructions (default 200000).\n"
            "  XST_WATCH=hex           Log every write to this address.\n"
            "  XST_TRAPTRACE=1         Log every GEMDOS/BIOS/XBIOS call.\n");
    }

int main(int argc, char** argv)
    {
    const char *prog = NULL, *mapf = NULL, *cmdline = "";
    uint32_t mem_mb = 4;

    for (int i = 1; i < argc; i++)
        {
        const char* a = argv[i];
        if (!strcmp(a, "-h") || !strcmp(a, "--help"))
            {
            print_usage(stdout);
            return 0;
            }
        else if (!strcmp(a, "-v") || !strcmp(a, "--version"))
            {
            printf("xst %s\n", XTC_VERSION);
            return 0;
            }
        else if (!strcmp(a, "-d") || !strcmp(a, "--dump-output"))
            opt_dump = 1;
        else if (!strcmp(a, "--cycles"))
            opt_cycles = 1;
        else if (!strcmp(a, "--cpu") && i + 1 < argc)
            cpu_kind = atoi(argv[++i]);
        else if (!strcmp(a, "--mem") && i + 1 < argc)
            mem_mb = atoi(argv[++i]);
        else if (!strcmp(a, "--args") && i + 1 < argc)
            cmdline = argv[++i];
        else if (a[0] == '-')
            {
            fprintf(stderr, "sim68k: unknown option '%s'\n", a);
            return 2;
            }
        else if (!prog)
            prog = a;
        else if (!mapf)
            mapf = a;
        }
    if (!prog)
        {
        print_usage(stderr);
        return 2;
        }

    mem_bytes = mem_mb * 1024u * 1024u;
    mem = calloc(mem_bytes, 1);
    if (!mem)
        {
        fprintf(stderr, "sim68k: out of memory (%u MB)\n", mem_mb);
        return 1;
        }

    for (int i = 0; i < HMAX; i++)
        host_fd[i] = -1;

    /* Instrumentation from the environment. */
    const char* e;
    if ((e = getenv("XST_ITRACE")) && atoi(e))
        itrace_enabled = 1;
    if ((e = getenv("XST_ITRACE_TRIGGER")))
        {
        itrace_has_trig = 1;
        itrace_trigger = (uint32_t)strtoul(e, NULL, 16);
        }
    if ((e = getenv("XST_ITRACE_STOP")))
        {
        itrace_has_stop = 1;
        itrace_stop = (uint32_t)strtoul(e, NULL, 16);
        }
    if ((e = getenv("XST_ITRACE_MAX")))
        itrace_max = strtoull(e, NULL, 10);
    if ((e = getenv("XST_WATCH")))
        {
        watch_enabled = 1;
        watch_addr = (uint32_t)strtoul(e, NULL, 16);
        }
    if ((e = getenv("XST_TRAPTRACE")) && atoi(e))
        traptrace = 1;

    if (load_prg(prog, cmdline) != 0)
        {
        free(mem);
        return 1;
        }
    if (mapf)
        load_map(mapf);

    signal(SIGINT, sigint_handler);

    while (running)
        {
        if (step())
            break;
        /* runaway guard */
        if (insn_count > 2000000000ull)
            {
            fprintf(stderr, "sim68k: instruction cap reached\n");
            break;
            }
        }

    fflush(stdout);
    if (opt_cycles)
        fprintf(stderr, "sim68k: %llu instructions\n", (unsigned long long)insn_count);
    free(mem);
    /* 134 = 128 + SIGABRT, the shell's spelling of "the program was killed".  */
    return terminated_via_pterm ? exit_code : 134;
    }
