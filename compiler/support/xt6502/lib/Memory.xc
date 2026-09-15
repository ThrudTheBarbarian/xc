// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

// Memory.xc — fast bulk-fill primitives. **xt6502 only.**
//
// This lived in generic/lib for a while, which was wrong: its bodies are inline
// 6502 assembly, so importing it on any other target failed to assemble. A
// directory named `generic` has to mean "works everywhere" or it means nothing,
// and a reader picking a class out of it should not have to check.
//
// There is deliberately no stub in generic/lib. A missing-class error naming
// the file is a better outcome than a class that exists, compiles, and does
// nothing — the caller wanted a bulk fill, and silence would be the one
// response that cannot be right.
//
// Static class. Two API entry points:
//
//   Memory.memset(u16 addr, u8 val, u16 len)
//     Set `len` bytes starting at `addr` to `val`. Handles arbitrary
//     [addr, len) — leading bytes to the next page boundary use a
//     simple per-byte loop, the page-aligned middle uses an unrolled
//     16-STA inner loop, the trailing bytes use the simple loop
//     again. ~5.7 cycles/byte for the bulk middle vs ~11 cycles/byte
//     for a naive (ptr),Y loop.
//
//   Memory.memclr(u16 addr, u16 len)
//     Sugar for memset(addr, 0, len).
//
// Implementation note: the middle path patches the high byte of
// 16 STA-absolute,Y instructions once per page and walks Y from 15
// down to 0 to cover all 256 bytes of the page. The patching
// requires the inline-asm STAs to live in writable memory; xtc emits
// methods into RAM regardless of placement (main, banked, shadow),
// so this works everywhere.
//
// Reachability: programs that never call Memory.memset or
// Memory.memclr get the methods stripped at link time. Importing
// the file alone costs nothing.

class Memory
    {
    static void memset(u16 addr, u8 val, u16 len)
        {
        if (len == (u16)0)
            return;

        asm
        {
            // Stage pointer + remaining count into B0..B3 (runtime
            // params region). Fill value goes into A and stays
            // there for the duration of the simple-loop runs.
            LDA addr
            STA $B0
            LDA addr+1
            STA $B1
            LDA len
            STA $B2
            LDA len+1
            STA $B3
            LDA val

                        // ── Phase 1: lead bytes to next page boundary ──
                        // If ptr.lo == 0 we're already aligned; skip.
            LDX $B0
            BEQ _ms_phase2

                                // Lead-loop: store one byte at a time, decrement
                                // remaining count, increment ptr.lo. When ptr.lo
                                // wraps to 0, we've hit a page boundary — bail out.
        _ms_lead_loop:
            LDY #$00
            STA ($B0),Y
            INC $B0
            BEQ _ms_lead_aligned                    // ptr.lo wrapped → aligned
                                                                  // Decrement remaining count.
            LDX $B2
            BNE _ms_lead_dec_lo
            LDX $B3
            BEQ _ms_done // count was 0 already → done
            DEC $B3
        _ms_lead_dec_lo:
            DEC $B2
                // Check if count exhausted (B2 == 0 AND B3 == 0).
            LDX $B2
            BNE _ms_lead_loop
            LDX $B3
            BNE _ms_lead_loop
            JMP _ms_done

        _ms_lead_aligned:
            // ptr.lo just rolled to 0 → ptr.hi must increment.
            INC $B1
                // Decrement remaining count for the byte we just stored.
            LDX $B2
            BNE _ms_lead_post_dec_lo
            LDX $B3
            BEQ _ms_done
            DEC $B3
        _ms_lead_post_dec_lo:
            DEC $B2

        _ms_phase2:
            // ── Phase 2: full pages, unrolled (16 STAs/iter) ──
            // pageCount = remaining count >> 8 = $B3.
            // tailCount = remaining count & $FF = $B2 (handled in
            // phase 3 after the page run).
            LDX $B3
            BEQ _ms_phase3 // no full pages

                    // Patch the high byte of all 16 absolute,Y STAs in the
                    // inner loop to the current ptr.hi. (Re-patched each
                    // iteration of the page loop after INC $B1.)
            STA $B4                                                                                                                                                                                                                                                                                                                                               // stash fill (A) so we can
                        // reuse A for the patches
        _ms_pageloop:
            LDA $B1
            STA _ms_s0 + 2
            STA _ms_s16 + 2
            STA _ms_s32 + 2
            STA _ms_s48 + 2
            STA _ms_s64 + 2
            STA _ms_s80 + 2
            STA _ms_s96 + 2
            STA _ms_s112 + 2
            STA _ms_s128 + 2
            STA _ms_s144 + 2
            STA _ms_s160 + 2
            STA _ms_s176 + 2
            STA _ms_s192 + 2
            STA _ms_s208 + 2
            STA _ms_s224 + 2
            STA _ms_s240 + 2

            LDA $B4 // restore fill
            LDY #$0F // Y = 15, count down to 0
        _ms_inner:
        _ms_s0:
            STA $0000,Y // patched: hi = current page
        _ms_s16:
            STA $0010,Y
        _ms_s32:
            STA $0020,Y
        _ms_s48:
            STA $0030,Y
        _ms_s64:
            STA $0040,Y
        _ms_s80:
            STA $0050,Y
        _ms_s96:
            STA $0060,Y
        _ms_s112:
            STA $0070,Y
        _ms_s128:
            STA $0080,Y
        _ms_s144:
            STA $0090,Y
        _ms_s160:
            STA $00A0,Y
        _ms_s176:
            STA $00B0,Y
        _ms_s192:
            STA $00C0,Y
        _ms_s208:
            STA $00D0,Y
        _ms_s224:
            STA $00E0,Y
        _ms_s240:
            STA $00F0,Y
            DEY
            BPL _ms_inner

            INC $B1 // next page
            DEX // one fewer page to clear
            BNE _ms_pageloop
                                                                                                                                                                                                                                                                                                                                                                             // A still holds fill (last LDA $B4 was after this
                                                                                                                                                                                                                                                                                                                                                                             // point on the loop entry; on the first iteration
                                                                                                                                                                                                                                                                                                                                                                             // we re-loaded and looped). Reload to be safe in
                                                                                                                                                                                                                                                                                                                                                                             // case the compiler ever re-orders.
            LDA $B4

        _ms_phase3:
            // ── Phase 3: trailing partial page ──
            // tailCount = $B2 (was the lo byte of the original
            // remaining count after lead-trim, untouched by the
            // page loop).
            LDX $B2
            BEQ _ms_done
            LDY #$00
        _ms_tail:
            STA ($B0),Y
            INY
            DEX
            BNE _ms_tail

        _ms_done:
        }
        return;
        }

    static void memclr(u16 addr, u16 len)
        {
        Memory.memset(addr, $00, len);
        return;
        }

    // Copy `len` bytes from `src` to `dst`. Source and dest **must
    // not overlap** — use Memory.memmove() if overlap is possible
    // or unknown.
    //
    // Two paths. When src.lo == 0 AND dst.lo == 0 (both addresses
    // page-aligned), each full page goes through an unrolled
    // 16×(LDA+STA)-absolute,Y inner loop with the high bytes of all
    // 32 instructions patched once per page → ~10 cycles/byte.
    // Otherwise (or for the trailing partial page) the simple
    // indirect-Y loop runs at ~16 cycles/byte. The misalignment
    // check (`ORA src.lo, dst.lo / BNE`) costs 4 cycles per call,
    // so the SMC fast path pays back as soon as a copy spans even
    // one full page-aligned chunk.
    //
    // Same self-modifying caveat as memset: the inline-asm
    // instructions are patched in place, so the method body must
    // live in writable RAM (xtc methods always do).
    static void memcpy(u16 dst, u16 src, u16 len)
        {
        if (len == (u16)0)
            return;

        asm
        {
            // Stage src/dst/len into B0..B5.
            LDA src
            STA $B0
            LDA src+1
            STA $B1
            LDA dst
            STA $B2
            LDA dst+1
            STA $B3
            LDA len
            STA $B4 // tail count (len lo)
            LDA len+1
            STA $B5 // page count (len hi)

                    // Misalignment check: SMC unroll only works when both
                    // src and dst sit on page boundaries (else the 16
                    // absolute-addressed STAs cross a page mid-loop).
            LDA $B0
            ORA $B2
            BNE _mc_simple

                                // ── Aligned: full pages via SMC, then tail ──
            LDX $B5
            BEQ _mc_tail

        _mc_pageloop:
            // Patch the 16 LDA-abs,Y high bytes with src page.
            LDA $B1
            STA _mc_l0 + 2
            STA _mc_l16 + 2
            STA _mc_l32 + 2
            STA _mc_l48 + 2
            STA _mc_l64 + 2
            STA _mc_l80 + 2
            STA _mc_l96 + 2
            STA _mc_l112 + 2
            STA _mc_l128 + 2
            STA _mc_l144 + 2
            STA _mc_l160 + 2
            STA _mc_l176 + 2
            STA _mc_l192 + 2
            STA _mc_l208 + 2
            STA _mc_l224 + 2
            STA _mc_l240 + 2
                // Patch the 16 STA-abs,Y high bytes with dst page.
            LDA $B3
            STA _mc_t0 + 2
            STA _mc_t16 + 2
            STA _mc_t32 + 2
            STA _mc_t48 + 2
            STA _mc_t64 + 2
            STA _mc_t80 + 2
            STA _mc_t96 + 2
            STA _mc_t112 + 2
            STA _mc_t128 + 2
            STA _mc_t144 + 2
            STA _mc_t160 + 2
            STA _mc_t176 + 2
            STA _mc_t192 + 2
            STA _mc_t208 + 2
            STA _mc_t224 + 2
            STA _mc_t240 + 2

            LDY #$0F
        _mc_inner:
        _mc_l0:
            LDA $0000,Y
        _mc_t0:
            STA $0000,Y
        _mc_l16:
            LDA $0010,Y
        _mc_t16:
            STA $0010,Y
        _mc_l32:
            LDA $0020,Y
        _mc_t32:
            STA $0020,Y
        _mc_l48:
            LDA $0030,Y
        _mc_t48:
            STA $0030,Y
        _mc_l64:
            LDA $0040,Y
        _mc_t64:
            STA $0040,Y
        _mc_l80:
            LDA $0050,Y
        _mc_t80:
            STA $0050,Y
        _mc_l96:
            LDA $0060,Y
        _mc_t96:
            STA $0060,Y
        _mc_l112:
            LDA $0070,Y
        _mc_t112:
            STA $0070,Y
        _mc_l128:
            LDA $0080,Y
        _mc_t128:
            STA $0080,Y
        _mc_l144:
            LDA $0090,Y
        _mc_t144:
            STA $0090,Y
        _mc_l160:
            LDA $00A0,Y
        _mc_t160:
            STA $00A0,Y
        _mc_l176:
            LDA $00B0,Y
        _mc_t176:
            STA $00B0,Y
        _mc_l192:
            LDA $00C0,Y
        _mc_t192:
            STA $00C0,Y
        _mc_l208:
            LDA $00D0,Y
        _mc_t208:
            STA $00D0,Y
        _mc_l224:
            LDA $00E0,Y
        _mc_t224:
            STA $00E0,Y
        _mc_l240:
            LDA $00F0,Y
        _mc_t240:
            STA $00F0,Y
            DEY
            BPL _mc_inner

            INC $B1 // advance src page
            INC $B3 // advance dst page
            DEX
            BNE _mc_pageloop
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                // Fall through to tail.

        _mc_tail:
            // Trailing partial page via simple indirect-Y. $B0/$B1
            // and $B2/$B3 already point at the right addresses
            // (lo == 0, hi advanced past all full pages).
            LDX $B4
            BEQ _mc_done
            LDY #$00
        _mc_tailloop:
            LDA ($B0),Y
            STA ($B2),Y
            INY
            DEX
            BNE _mc_tailloop
            JMP _mc_done

                                                               // ── Misaligned: simple indirect-Y for everything ──
        _mc_simple:
            LDX $B5
            BEQ _mc_simple_tail
        _mc_simple_pages:
            LDY #$00
        _mc_simple_inner:
            LDA ($B0),Y
            STA ($B2),Y
            INY
            BNE _mc_simple_inner
            INC $B1
            INC $B3
            DEX
            BNE _mc_simple_pages
        _mc_simple_tail:
            LDX $B4
            BEQ _mc_done
            LDY #$00
        _mc_simple_tailloop:
            LDA ($B0),Y
            STA ($B2),Y
            INY
            DEX
            BNE _mc_simple_tailloop

        _mc_done:
        }
        return;
        }

    // Copy `len` bytes from `src` to `dst`, handling overlap. When
    // dst <= src (or no overlap), forwards the call to memcpy. When
    // dst > src and the regions might overlap, walks backward from
    // the highest byte downward so the source isn't clobbered
    // mid-copy. The backward path is simple indirect-Y (no SMC) —
    // overlapping copies are typically small in-buffer shifts where
    // the page-aligned SMC win wouldn't apply anyway.
    static void memmove(u16 dst, u16 src, u16 len)
        {
        if (len == (u16)0)
            return;
        if (dst <= src)
            {
            Memory.memcpy(dst, src, len);
            return;
            }

        asm
        {
            // Stage src/dst as base addresses. ZP pointers will be
            // advanced to "start of last partial page" first, then
            // walked backward page by page.
            LDA src
            STA $B0
            LDA src+1
            CLC
            ADC len+1
            STA $B1 // src.hi + pages
            LDA dst
            STA $B2
            LDA dst+1
            CLC
            ADC len+1
            STA $B3 // dst.hi + pages
            LDA len
            STA $B4 // tail
            LDA len+1
            STA $B5 // pages

                    // ── Phase 1: trailing partial page (highest bytes) ──
                    // src.lo + tail-1 might cross a page boundary if
                    // src.lo + tail > 256. That can't happen here: $B0/$B1
                    // points at src + pages*256 (i.e. start of the tail
                    // region), and tail < 256 by definition, so all bytes
                    // [B0..B0+tail-1] live in the same page.
            LDX $B4
            BEQ _mm_pages
            LDY $B4
            DEY // Y = tail - 1
        _mm_tailloop:
            LDA ($B0),Y
            STA ($B2),Y
            DEY
            CPY #$FF
            BNE _mm_tailloop

                                                                        // ── Phase 2: full pages, highest first ──
        _mm_pages:
            LDX $B5
            BEQ _mm_done
        _mm_pageloop:
            DEC $B1 // back up to start of previous page
            DEC $B3
            LDY #$FF
        _mm_pageinner:
            LDA ($B0),Y
            STA ($B2),Y
            DEY
            CPY #$FF
            BNE _mm_pageinner
            DEX
            BNE _mm_pageloop

        _mm_done:
        }
        return;
        }
    }
