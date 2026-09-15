/* rt-checked.c — the checked-build runtime (private:docs/Design/memory-safety.md).
 *
 * SEPARATE from rt.c on purpose, and compiled -fno-omit-frame-pointer while
 * rt.c is compiled -fomit-frame-pointer. The backtrace walks from its own
 * frame, which only works if it HAS one.
 *
 * Linked ONLY into a checked build, so an ordinary build carries none of this
 * — no reporter, no table lookup, no isatty.
 *
 * BUILD FLAGS ARE PART OF THE CONTRACT:
 *   clang -O0 -fno-omit-frame-pointer
 * -fno-omit-frame-pointer because the walk starts from this file's own frame.
 * -O0 because at -O1 the reporter's helpers INLINE into each other and the
 * "skip our own frame" step then skips the wrong one — the walk reported a
 * single bogus frame where three real ones existed. Slow is fine here; the
 * program is already stopping.
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

/* The parameter map the back end emits: [count][fnAddr, nparams, paramsPtr]*,
 * and two words per parameter — frame offset from x29, and (kind<<8)|width.
 * Weak: an ordinary build has no map, and the reporter must still link. */
/* NOT weak, and never null-tested: the address of an array is never null,
 * so a `if (!__xt_ms_fns)` guard folds away and the reporter then reads an
 * unresolved symbol. The back end emits this table whenever the module is
 * checked — empty if need be — so it is always defined here. */
/* HIDDEN visibility is load-bearing. Without it clang addresses this through
 * the GOT (adrp @GOTPAGE / ldr @GOTPAGEOFF), and the in-house linker emits the
 * table as a LOCAL symbol with no GOT entry — so the indirection loaded garbage
 * and the reporter segfaulted while reporting. Hidden says "not preemptible",
 * which lets clang use a direct adrp/add. Everything here is concatenated into
 * one assembly unit anyway, so there is nothing to preempt. */
extern const unsigned long __xt_ms_fns[] __attribute__((visibility("hidden")));

/* Read one frame's arguments. `fp` is that FUNCTION'S frame pointer, so a slot
 * recorded at offset N sits at fp+N — the prologue does `mov x29, sp` and the
 * allocator numbers slots from sp.
 *
 * An offset of ~0 means the allocator kept the parameter in a register: there
 * is nothing in the frame to read, and it is printed as such. A confident wrong
 * argument would be worse than an absent one — that is the whole reason the
 * design says this must be LABELLED (memory-safety.md §4). */
/* Registers recovered so far, walking inner -> outer. Callee-saved registers
 * are the only place arguments live (the allocator homes essentially every
 * parameter in one and spills none), and they are recoverable precisely
 * because they are callee-saved:
 *
 *   - for the INNERMOST xtc frame they are still LIVE IN THE CPU — nothing
 *     between it and this reporter may clobber them — so they are snapshotted
 *     on entry;
 *   - for every frame further out, the callee-save area of a frame INSIDE it
 *     holds them, and the walk has already passed through that frame.
 */
static unsigned long long __xt_ms_reg[32];
static unsigned char      __xt_ms_regKnown[32];

static void __xt_ms_args(uintptr_t fnStart, void **fp){
    if (!fp) return;
    unsigned long n = __xt_ms_fns[0];
    /* A garbage count walks the scan straight off the end of the map and into
     * unmapped memory — a reporter that segfaults while reporting is worse than
     * one that prints less. No module has a million functions. */
    if (n == 0 || n > 1000000UL) { fprintf(stderr, "         args: <map unreadable>\n"); return; }
    const unsigned long *rec = &__xt_ms_fns[1];
    for (unsigned long i = 0; i < n; i++, rec += 5){
        if ((uintptr_t)rec[0] != fnStart) continue;
        unsigned long np = rec[1];
        const unsigned long *ps = (const unsigned long *)rec[2];
        if (!np || !ps) return;
        /* Defensive: this walks a stack that is already known to be in a bad
         * state, and a reporter that segfaults tells the programmer nothing at
         * all. A frame pointer is 8-aligned, a slot offset fits a frame. */
        if (((uintptr_t)fp & 7) || np > 32) return;
        fprintf(stderr, "         args:");
        for (unsigned long k = 0; k < np; k++){
            unsigned long off = ps[k*3], kw = ps[k*3+1], reg = ps[k*3+2];
            unsigned kind = (unsigned)(kw >> 8), width = (unsigned)(kw & 0xFF);
            if (off == ~0UL){
                /* Homed in a register: recoverable if the walk has passed a
                 * frame that saved it, or if it is still live from the CPU
                 * snapshot. */
                if (reg < 32 && __xt_ms_regKnown[reg]){
                    unsigned long long v = __xt_ms_reg[reg];
                    if (width && width < 8) v &= (~0ULL >> (64 - width*8));
                    if (kind == 2)      fprintf(stderr, " arg%lu=%p", k, (void *)(uintptr_t)v);
                    else if (kind == 3) fprintf(stderr, " arg%lu=<float>", k);
                    else                fprintf(stderr, " arg%lu=%llu", k, v);
                } else {
                    fprintf(stderr, " arg%lu=<in a register, not recovered>", k);
                }
                continue;
            }
            if (off > 65535 || width == 0 || width > 8){
                fprintf(stderr, " arg%lu=<unavailable>", k); continue; }
            const unsigned char *slot = (const unsigned char *)fp + off;
            unsigned long long v = 0;
            for (unsigned b = 0; b < width && b < 8; b++)
                v |= (unsigned long long)slot[b] << (8*b);
            if (kind == 2)      fprintf(stderr, " arg%lu=%p", k, (void *)(uintptr_t)v);
            else if (kind == 3) fprintf(stderr, " arg%lu=<float>", k);
            else                fprintf(stderr, " arg%lu=%llu", k, v);
        }
        fprintf(stderr, "\n");
        return;
    }
}

/* Overlay one frame's callee-save area. A frame saves its CALLER's registers,
 * so applying this as the walk leaves the frame is what makes the next frame
 * out readable. Register k of the saved list sits at saveBase + k*8, which is
 * how emitCalleeSaves lays the pairs down. */
static void __xt_ms_applySaves(uintptr_t fnStart, void **fp){
    if (!fp) return;
    unsigned long n = __xt_ms_fns[0];
    if (n == 0 || n > 1000000UL) return;
    const unsigned long *rec = &__xt_ms_fns[1];
    for (unsigned long i = 0; i < n; i++, rec += 5){
        if ((uintptr_t)rec[0] != fnStart) continue;
        unsigned long base = rec[3];
        const long *sv = (const long *)rec[4];
        if (!sv || base > 65535) return;
        for (unsigned long k = 0; sv[k] >= 0 && k < 32; k++){
            long r = sv[k];
            if (r < 0 || r >= 32) continue;                 /* d-regs: skipped */
            const unsigned char *slot = (const unsigned char *)fp + base + k*8;
            unsigned long long v = 0;
            for (unsigned b = 0; b < 8; b++) v |= (unsigned long long)slot[b] << (8*b);
            __xt_ms_reg[r] = v; __xt_ms_regKnown[r] = 1;
        }
        return;
    }
}

/* ── Naming a frame ──────────────────────────────────────────────────────────
 *
 * dladdr is not enough: it resolves only EXPORTED symbols, and the in-house
 * linker emits xtc functions as LOCAL ones (`t`, not `T` in nm). Every name is
 * present in the symbol table — 3073 of them in a hello-world — just not in the
 * dynamic export table dladdr consults.
 *
 * So the reporter reads its own LC_SYMTAB, the way a debugger would. That needs
 * no compiler change and no separate name+range table: the names the linker
 * already writes ARE the table. Nearest-symbol-at-or-below wins, which is the
 * standard way to attribute a return address to a function.
 */
static const char *__xt_ms_symbolise(const void *addr, unsigned long *offset,
                                    uintptr_t *fnStart){
    const struct mach_header_64 *hdr =
        (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!hdr) return 0;
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    const struct load_command *lc = (const struct load_command *)(hdr + 1);
    for (uint32_t i = 0; i < hdr->ncmds; i++){
        if (lc->cmd == LC_SYMTAB){
            const struct symtab_command *st = (const struct symtab_command *)lc;
            /* __LINKEDIT holds the symbol and string tables; find its slide. */
            const struct load_command *l2 = (const struct load_command *)(hdr + 1);
            const struct segment_command_64 *link = 0;
            for (uint32_t j = 0; j < hdr->ncmds; j++){
                if (l2->cmd == LC_SEGMENT_64){
                    const struct segment_command_64 *sg =
                        (const struct segment_command_64 *)l2;
                    if (!strcmp(sg->segname, "__LINKEDIT")) { link = sg; break; }
                }
                l2 = (const struct load_command *)((const char *)l2 + l2->cmdsize);
            }
            if (!link) return 0;
            /* Section indices are global and 1-based across all segments, so
             * the __text index has to be counted, not assumed. Restricting to
             * it drops data symbols — one frame was attributed to a vtable,
             * +2157557376 bytes in, which is a nonsense a reader would have to
             * decode rather than a name. */
            uint8_t textSect = 0, sectIdx = 0;
            const struct load_command *l3 = (const struct load_command *)(hdr + 1);
            for (uint32_t j = 0; j < hdr->ncmds && !textSect; j++){
                if (l3->cmd == LC_SEGMENT_64){
                    const struct segment_command_64 *sg =
                        (const struct segment_command_64 *)l3;
                    const struct section_64 *sec =
                        (const struct section_64 *)(sg + 1);
                    for (uint32_t n = 0; n < sg->nsects; n++, sec++){
                        sectIdx++;
                        if (!strcmp(sec->sectname, "__text")
                            && !strcmp(sec->segname, "__TEXT")) { textSect = sectIdx; break; }
                    }
                }
                l3 = (const struct load_command *)((const char *)l3 + l3->cmdsize);
            }
            if (!textSect) return 0;
            uintptr_t base = (uintptr_t)link->vmaddr + slide - link->fileoff;
            const struct nlist_64 *syms =
                (const struct nlist_64 *)(base + st->symoff);
            const char *strs = (const char *)(base + st->stroff);
            uintptr_t want = (uintptr_t)addr, bestAddr = 0;
            const char *best = 0;
            for (uint32_t k = 0; k < st->nsyms; k++){
                if ((syms[k].n_type & N_STAB) || !(syms[k].n_type & N_SECT)) continue;
                if (syms[k].n_sect != textSect) continue;   /* code only */
                const char *nm = strs + syms[k].n_un.n_strx;
                /* Our linker writes BASIC-BLOCK labels into the symbol table —
                 * Lmain_bb_6_..., Lchk_BB2_5 — and nearest-below happily picks
                 * one over the function containing it. 'L' is the Mach-O
                 * assembler-local convention, so it is exactly the right
                 * discriminator: skip them and the enclosing function wins. */
                if (nm[0] == 'L') continue;
                uintptr_t a = (uintptr_t)syms[k].n_value + slide;
                if (a <= want && a > bestAddr){
                    bestAddr = a; best = nm;
                }
            }
            if (best && offset)  *offset  = (unsigned long)(want - bestAddr);
            if (best && fnStart) *fnStart = bestAddr;
            return best;
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    return 0;
}

/* ── Checked builds: the bounds trap (private:docs/Design/memory-safety.md) ──────────
 *
 * ONE reporter, called from every check site, so a checked build does not carry
 * custom reporting code per site. The site passes only a CONSTANT descriptor
 * index plus the two dynamic values; everything textual lives in the table the
 * compiler emits as `__xt_ms_sites`.
 *
 * Bounds need no new metadata: every heap block already carries
 * {magic, stride, count} at payload-40, so the element count is recoverable
 * from the pointer alone. A pointer with the wrong magic is not a heap block —
 * reported as such rather than guessed at.
 */
/* The site is a POOLED STRING the compiler emits per check site —
 * "file:line:col expr" — not a per-site struct. String literals are machinery
 * that already exists and already pools, so this needs no relocatable data
 * table to be useful today. The richer descriptor (variable name, declared
 * type, and the per-FUNCTION local tables the design calls for) needs data
 * relocations and comes next; this is the shape that works now. */

/* Walks from THIS function's own frame. That is only sound because this file
 * is compiled -fno-omit-frame-pointer, unlike rt.c — which is exactly why the
 * checked runtime is a separate translation unit.
 *
 * The first attempt lived in rt.c and read x29 directly, reasoning that a
 * function with no frame leaves x29 pointing at its caller's. It does not:
 * -fomit-frame-pointer frees the compiler to use x29 as a GENERAL REGISTER, and
 * the walk returned one bogus frame instead of four real ones. The alternative
 * was to have every check site pass its frame pointer, which would have needed
 * a way to read x29 from the IR — a new opcode, for something a build flag
 * solves. */
__attribute__((noinline)) static void __xt_ms_backtrace(void){
    void **fp = (void **)__builtin_frame_address(0);
    fp = (void **)fp[0];                       /* skip our own frame */
    fprintf(stderr, "  stack:\n");
    for (int d = 0; d < 24 && fp; d++){
        void *ret = fp[1], *next = fp[0];
        if (!ret) break;
        unsigned long off = 0;
        uintptr_t fnStart = 0;
        const char *name = __xt_ms_symbolise(ret, &off, &fnStart);
        /* An address OUTSIDE our image still matches the last symbol below it,
         * which produced "_xtc_obj_conforms +2090163632" for a libSystem
         * frame — a name that is worse than no name, because it reads as ours.
         * A plausible function is not two gigabytes long. */
        if (name && off > (1UL << 20)) name = 0;
        if (name){
            /* Leading underscore is the ABI's, not the programmer's. */
            if (*name == '_') name++;
            fprintf(stderr, "    #%-2d %s +%lu\n", d, name, off);
            /* `next` is the frame belonging to the function just named: a
             * frame holds [caller's x29, return-into-caller], so the return
             * address names the CALLER while the frame is the CALLEE's. */
            if (next > (void *)fp) {
                __xt_ms_args(fnStart, (void **)next);
                /* Leaving this frame: its save area holds the NEXT frame's
                 * registers, so apply it before moving out. */
                __xt_ms_applySaves(fnStart, (void **)next);
            }
        } else {
            fprintf(stderr, "    #%-2d %p\n", d, ret);
        }
        if (next <= (void *)fp) break;         /* stack grows down; stop if not */
        fp = (void **)next;
    }
}

void _xt_trap_bounds(const char *site, void *ptr, unsigned long index){
    fprintf(stderr, "\n=== xcc: out-of-bounds access ===\n");
    if (site) fprintf(stderr, "  at %s\n", site);
    if (ptr){
        unsigned char *h = (unsigned char *)ptr - 40;   /* XT_HDR — see rt.c */
        unsigned int magic = *(unsigned int *)(h + 0);
        if (magic == 0x58544F42U){
            unsigned long stride = *(unsigned long *)(h + 4);
            unsigned long count  = *(unsigned long *)(h + 12);
            fprintf(stderr, "  %s: index %lu, but the allocation holds %lu "
                            "element%s of %lu byte%s\n",
                    "array", index, count,
                    count == 1 ? "" : "s", stride, stride == 1 ? "" : "s");
        } else {
            /* The magic is the only thing that distinguishes a heap block from
             * a stack local, a global, or a wild pointer. Say which it is
             * rather than printing a confident count read out of nowhere. */
            fprintf(stderr, "  %p is not a heap allocation (no header) — its "
                            "extent is unknown, so only the access was checked\n", ptr);
        }
    }
    __xt_ms_backtrace();
    /* A non-tty stdin must ABORT, never block: a test suite that hangs at a
     * trap is a worse failure than the bug that caused it. */
    if (isatty(0)){
        fprintf(stderr, "  [c] continue (the offending access is SUPPRESSED, "
                        "not performed), any other key aborts: ");
        fflush(stderr);
        int c = getchar();
        if (c == 'c' || c == 'C'){ fprintf(stderr, "  continuing\n"); return; }
    }
    fprintf(stderr, "  aborting\n");
    abort();
}

/* The CHECK itself, called from every subscript in a checked build.
 *
 * A call rather than inline compare-and-branch, deliberately: the limit lives
 * in the allocation header, so an inline form still needs the load — and one
 * `bl` is FEWER bytes at the site than compare + branch + the trap call it
 * would still need. A checked build optimises for size and simplicity at the
 * site; it is not trying to be fast.
 *
 * A pointer with no header cannot be range-checked at all, so it passes: the
 * extent is genuinely unknown, and refusing every non-heap pointer would make
 * the mode unusable rather than safe. */
/* Capture x19-x28 while they still belong to the xtc caller.
 *
 * This has to happen HERE, in the check, not in the reporter: _xt_check_bounds
 * is compiled -O0 and touches none of x19-x28, so on entry they are exactly
 * what the calling function had. By the time the backtrace runs, clang's own
 * prologues have reused them — the first attempt snapshotted there with
 * `register __asm__("x19")` and read the reporter's values, printing
 * arg1=58208 where 11 was expected.
 *
 * Index 19 of an 8-byte array is byte 152; the pairs follow every 16. */
#define XT_MS_CAPTURE() do { \
    __asm__ volatile("stp x19, x20, [%0, #152]\n\t" \
                     "stp x21, x22, [%0, #168]\n\t" \
                     "stp x23, x24, [%0, #184]\n\t" \
                     "stp x25, x26, [%0, #200]\n\t" \
                     "stp x27, x28, [%0, #216]\n\t" \
                     : : "r"(__xt_ms_reg) : "memory"); \
    for (int _r = 19; _r <= 28; _r++) __xt_ms_regKnown[_r] = 1; \
} while (0)

void _xt_check_bounds(void *ptr, unsigned long index, const char *site){
    if (!ptr) { XT_MS_CAPTURE(); _xt_trap_bounds(site, ptr, index); return; }
    unsigned char *h = (unsigned char *)ptr - 40;   /* XT_HDR — see rt.c */
    if (*(unsigned int *)(h + 0) != 0x58544F42U) return;   /* not a heap block */
    if (index >= *(unsigned long *)(h + 12)) {
        XT_MS_CAPTURE();
        _xt_trap_bounds(site, ptr, index);
    }
}


