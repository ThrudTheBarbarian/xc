; xcc runtime library.
;
; Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
;
; This file is part of the xcc runtime library: the code that is combined
; with a program when xcc compiles it. It is free software; you can
; redistribute it and/or modify it under the terms of the GNU General Public
; License as published by the Free Software Foundation, either version 3 of
; the License, or (at your option) any later version.
;
; Under Section 7 of GPL version 3, you are granted additional permissions
; described in the GCC Runtime Library Exception, version 3.1, as published
; by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
; parent.
;
; The effect of that exception is the point: a program compiled by xcc
; contains parts of this file, and the exception is what leaves that program
; under whatever licence its author chooses, including a proprietary one.
;
; This file is distributed in the hope that it will be useful, but WITHOUT
; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
; FITNESS FOR A PARTICULAR PURPOSE.

; xt6502-corpus-harness.asm — generic per-fixture stub for the
; dual-backend corpus sweep, on the REAL xt map (task #60).
;
; Memory map (xt):
;   $0500-$07FF  software stack (STACK-ABI §11.3 spill frames)
;   $0800-$1FFF  bump heap (flat, unbanked; banked heap lives at $A000-$D000)
;   $2400-$3FFF  entry + runtime stubs + _xcall trampoline  (unbanked)
;   $4000-$5FFF  screen RAM (SAVMSC = $4000)                (unbanked)
;   $6000-$9FFF  code-bank window via $D5C0 (__bank_code_reg)   (banked)
;   $A000-$CFFF  data-bank window via $D5C1 (__bank_data_reg; banked heap — corpus only)
;   $D800-$FFF9  generated unbanked code + data
;
; The generated unbanked code+data spans $A000-$CFFF then auto-spills
; into $D800-$FFF9 (~22 KB total) — enough for a large entry function
; (which must stay unbanked, reached by the harness's direct JSR). The
; heap + software stack live in low RAM so they don't compete with that
; budget. Banking kicks in when code overflows ~22 KB; small programs
; stay entirely in bank 0 (the proven flat path). Cross-bank calls route
; through the re-entrant `_xcall` trampoline below (unbanked).
;
; Bank-select registers (memory-mapped, NOT zero page):
;   $D5C0   — code-bank selector  (symbol __bank_code_reg)
;   $D5C1   — data-bank selector  (symbol __bank_data_reg)
;   (relocated out of ZP $82/$83 so the boot RAM-clear can't zero them;
;    $82-$84 are now free ZP. See private:docs/bugs/006-bank-reg-relocation.md.)
;
; ZP layout (avoids the codegen's $A0-$FF allocator window):
;   $58/$59 — SAVMSC (screen base, = $4000)
;   $8A/$8B — software-stack pointer (SSP)
;   $8C/$8D — frame pointer (FP)
;   $90/$91 — __xtc_retain/release scratch (ptr - 1)
;   $92/$93 — bump-allocator heap pointer
;   $94     — print column counter
;   $95     — dealloc counter

.org $2400
; ── Unified unbanked code_regions (task #121) ──────────────────────
; The runtime stubs below + the backend's unbanked generated code form
; ONE contiguous unbanked block. xta auto-spills it across the screen
; ($4000-$5FFF), the code-bank window ($6000-$9FFF), and the banked heap
; ($A000-$CFFF) into the high unbanked region. Both ranges are declared
; HERE (rather than letting the backend emit a second `.code_regions`,
; which resets xta's region list and re-splits the two blocks) so the
; whole thing stays guarded — without it the ~11 KB float/double runtime
; silently overran $3FFF into screen RAM and corrupted every printed-
; output oracle even though the computation was correct.
.code_regions $2400-$3FFF, $D800-$FFF9

; XT register-unlock master switch (PBI window, decoded unconditionally).
; This models the hardware's register-unlock design. Reset leaves xt_unlock = 0
; (fully locked / bone-stock Atari), so the $D5C0/$D5C1 bank selectors are
; open bus until the BANK group (bit 3) is unlocked. The A9 launcher is
; supposed to unlock BANK pre-launch, but the xtc runtime depends on banking
; (_xcall, the banked heap, per-deref __bank_data_reg writes) so we self-
; unlock it defensively here — $D1DF is the always-honored 6502 write port,
; with no permission gate. Read-modify-write to preserve any other groups
; (GEM/SPRITE/…) the A9 may already have unlocked.
xt_unlock_reg = $D1DF
UNLK_BANK     = $08         ; bit 3 — $D5C0/$D5C1 code/data bank select

start:
    LDA xt_unlock_reg
    ORA #UNLK_BANK
    STA xt_unlock_reg       ; unlock XT banking before any $D5C0/$D5C1 use

    LDA #$00
    STA $58
    LDA #$40
    STA $59             ; SAVMSC = $4000 (xt screen)
    LDA #0
    STA $94             ; print column = 0

    LDA #0
    STA $95             ; dealloc counter = 0
; @@LL-HEAPINIT-BEGIN@@ (driver strips this block when the program uses no heap/ARC)
    JSR _heap_init      ; init the banked free-list heap ($A000-$D000, embedded
                        ; heap.asm + bank-xt.asm) — the real -falloc=heap allocator + ARC
; @@LL-HEAPINIT-END@@

    ; Software-stack pointer (STACK-ABI §11.3) = $0500 (low RAM, above
    ; the $03FD-$047F preload-stub cassette buffer). Low RAM is below
    ; the $4000..$5F40 screen-write window, so frame/heap writes are
    ; never decoded as screen output, and it leaves $A000-$FFF9 free for
    ; the generated unbanked code+data.
    LDA #$00
    STA $8A
    STA $8C
    LDA #$05
    STA $8B
    STA $8D             ; SSP = FP = $0500

    ; What happens when main returns (xcc -Q). `rts`, the default, returns to
    ; the loader with main's value in A: Atari DOS starts a program with a
    ; JSR to its run address, so this RTS goes back to DOS. `-Q loop` has the
    ; compiler replace the RTS with a jump to itself, so the machine spins.
    JSR _xt_main
    RTS

; ── _xcall: re-entrant cross-bank trampoline (unbanked, task #60) ─
; A banked call site stages the callee address in _xcall_vec and its
; bank id in _xc_bank, then JSRs here. The trampoline saves $82 onto a
; LIFO save-stack (re-entrant across nested cross-bank calls), selects
; the callee's bank, RTS-jumps to it (no indirect JMP → no page-bug),
; and on return restores $82 + re-pushes the caller return. The callee
; sees a clean [callee_ret][args] stack, so its PSH/SP-relative param
; offsets match a direct call.
_xc_sp:     .byte $00
_xc_a:      .byte $00
_xc_x:      .byte $00
_xc_y:      .byte $00
_xc_bank:   .byte $00
_xcall_vec: .word $0000
_xc_stk:    .space 240
; __xtc_release's private LIFO: saves the caller's data-bank selector ($83)
; across the descriptor read / dispatch / free (which repoint it). Not the
; hardware stack — avoids shifting SP under a dispatched dealloc's frame.
; 1 byte / release-nesting level.
_rel_sp:    .byte $00
_rel_stk:   .space 64

_xcall:
    LDX _xc_sp
    PLA
    STA _xc_stk,X
    INX
    PLA
    STA _xc_stk,X
    INX
    LDA __bank_code_reg
    STA _xc_stk,X
    INX
    STX _xc_sp
    LDA _xc_bank
    STA __bank_code_reg
    LDA #>_xc_res_m1
    PHA
    LDA #<_xc_res_m1
    PHA
    LDA _xcall_vec
    SEC
    SBC #1
    TAX
    LDA _xcall_vec+1
    SBC #0
    PHA
    TXA
    PHA
    RTS
_xc_res_m1:
    NOP
_xc_res:
    STA _xc_a
    STX _xc_x
    STY _xc_y
    LDX _xc_sp
    DEX
    LDA _xc_stk,X
    STA __bank_code_reg
    DEX
    LDA _xc_stk,X
    PHA
    DEX
    LDA _xc_stk,X
    STX _xc_sp
    PHA
    LDY _xc_y
    LDX _xc_x
    LDA _xc_a
    RTS

; ── ARC runtime stubs ────────────────────────────────────────────
; A:X = object pointer. The codegen-emitted ARC ops route through the
; REAL free-list ARC (_obj_retain / _obj_decref / _heap_free, embedded
; below) so the corpus tests the shipping reference-counting + allocator.
; $95 is the corpus's dealloc counter — bumped on each actual free so the
; arc_* fixtures' dealloc-count asserts still hold.

; Fixed payload offset of the 3-byte dealloc descriptor that
; `_xtc_new_<Class>` stages and `__xtc_release` reads (task #122). Past
; every released class's ivars, inside the conservative 64-byte payload.
xtc_desc_off = 60

; @@LL-ARC-BEGIN@@ (driver strips the ARC retain/release/dealloc stubs when
; the program performs no retain/release — they pull in retain.asm)
__xtc_retain:
    JMP _obj_retain          ; tail-call (A:X:Y = ptr, bank in Y)

__xtc_release:
    STA $90                  ; save ptr lo
    STX $91                  ; save ptr hi
    STY $92                  ; save bank
    JSR _obj_decref          ; decrement refcount (A:X:Y still = ptr; $83-safe)
    BCC rel_done             ; carry clear → still referenced; $83 untouched
    INC $95                  ; diagnostic: bump 8-bit counter
    ; Preserve the caller's data-bank selector ($83) across the descriptor
    ; read + dispatch + free below. The shipping ARC runtime is $83-neutral;
    ; this stub repoints $83 (object bank for the descriptor read, then 0 for
    ; a banked dealloc's bank-0 ivar view), and the codegen sets $83 = a
    ; banked pointer's bank byte per access, so a caller holding a heap-bank
    ; pointer expects $83 left as it was — NOT forced to 0. Leaving it at 0
    ; sent the caller's next heap access to the wrong bank (Map/Set.removeAll
    ; releases an element in a loop, then reads its own _count → corruption).
    ; Saved on a private LIFO (not the hardware stack → no SP shift, so the
    ; dispatched dealloc's SP-relative self-read is unaffected; re-entrant
    ; across a nested release). _heap_free is itself $83-callee-saved, so
    ; restoring before it (and never touching $83 on the BCC path) suffices.
    LDX _rel_sp
    LDA __bank_data_reg
    STA _rel_stk,X
    INX
    STX _rel_sp
    ; Refcount reached 0 — find the dealloc descriptor (3 bytes at obj+60:
    ; [dealloc-bank, addr-lo, addr-hi]; all-zero → no destructor). Read needs
    ; $83 = the object's bank ($A000-$CFFF data window); then $83 = 0 for the
    ; bank-0 ivar view a banked dealloc runs against. See private:docs/bugs/003-004.
    LDY $92                  ; object bank
    STY __bank_data_reg      ; select object's data bank
    LDA $90
    STA $98                  ; ZP pointer lo
    LDA $91
    STA $99                  ; ZP pointer hi
    LDY #xtc_desc_off        ; descriptor at object + 60
    LDA ($98),Y              ; descriptor: dealloc code bank
    STA _xc_bank
    INY
    LDA ($98),Y              ; addr-lo
    STA $85
    INY
    LDA ($98),Y              ; addr-hi
    STA $86
    ; Array cookie (written by the class allocator): elemSize at obj+56,
    ; element count at obj+58 — read while $83 still selects the object's
    ; bank. count=1 for a scalar `new T()`. Stashed in free ZP temps; the
    ; dispatch loop below moves them into a hardware-stack frame.
    LDY #56
    LDA ($98),Y              ; elemSize lo
    STA $87
    INY
    LDA ($98),Y              ; elemSize hi
    STA $88
    INY                      ; Y = 58
    LDA ($98),Y              ; count lo
    STA $89
    INY
    LDA ($98),Y              ; count hi
    STA $84
    LDA #$00
    STA __bank_data_reg      ; back to main-RAM bank for the dispatch
    ; Sentinel check: all three bytes zero → class has no dealloc.
    LDA _xc_bank
    ORA $85
    ORA $86
    BEQ rel_free
    ; Array-aware dispatch: run dealloc(self) once per element, self =
    ; base + i*elemSize. The dispatched dealloc is compiled code that
    ; clobbers ZP and the descriptor scratch ($85/$86/_xc_bank), so all
    ; loop state lives in a 13-byte hardware-stack frame, reloaded each
    ; iteration. SALLY `d,SP` addressing reads it; the frame survives the
    ; dealloc (which sits above it) and nested re-entrant releases.
    ;
    ; Frame (SP+1 = top, after the 13 pushes):
    ;   +1/+2/+3   running self ptr (lo/hi/bank), stepped by elemSize
    ;   +4/+5      count remaining (16-bit, decremented)
    ;   +6/+7      elemSize (16-bit step)
    ;   +8/+9/+10  base ptr (lo/hi/bank) — for the final _heap_free
    ;   +11/+12    descriptor addr (lo/hi)  → $85/$86 per dispatch
    ;   +13        descriptor code bank     → _xc_bank per dispatch
    LDA _xc_bank
    PHA                      ; +13 desc bank
    LDA $86
    PHA                      ; +12 desc addr-hi
    LDA $85
    PHA                      ; +11 desc addr-lo
    LDA $92
    PHA                      ; +10 base bank
    LDA $91
    PHA                      ; +9  base hi
    LDA $90
    PHA                      ; +8  base lo
    LDA $88
    PHA                      ; +7  elemSize hi
    LDA $87
    PHA                      ; +6  elemSize lo
    LDA $84
    PHA                      ; +5  count hi
    LDA $89
    PHA                      ; +4  count lo
    LDA $92
    PHA                      ; +3  runptr bank (= base bank)
    LDA $91
    PHA                      ; +2  runptr hi
    LDA $90
    PHA                      ; +1  runptr lo
    ; Only LDA/STA support the `d,SP` mode (not ORA/ADC/SBC), so frame
    ; values are copied to ZP scratch ($87/$88) for any arithmetic.
rel_loop:
    LDA +5,SP                ; count remaining == 0 ?  (hi first)
    BNE rel_loop_go
    LDA +4,SP                ; count lo
    BEQ rel_loop_done
rel_loop_go:
    LDA +11,SP
    STA $85                  ; reload descriptor for __xt_indcall
    LDA +12,SP
    STA $86
    LDA +13,SP
    STA _xc_bank
    ; push self = running ptr (bank/hi/lo); +3,SP reads bank, then hi, lo
    ; as the SP shifts under each PHA (same trick the codegen uses).
    LDA +3,SP
    PHA
    LDA +3,SP
    PHA
    LDA +3,SP
    PHA
    JSR __xt_indcall
    ADD SP, #3               ; discard the 3 self args (runptr kept in frame)
    LDA +6,SP                ; running ptr += elemSize (16-bit, via ZP)
    STA $87
    LDA +7,SP
    STA $88
    CLC
    LDA +1,SP
    ADC $87
    STA +1,SP
    LDA +2,SP
    ADC $88
    STA +2,SP
    SEC                      ; count -= 1 (16-bit)
    LDA +4,SP
    SBC #1
    STA +4,SP
    LDA +5,SP
    SBC #0
    STA +5,SP
    JMP rel_loop
rel_loop_done:
    LDA +8,SP                ; reload base ptr for the free
    STA $90
    LDA +9,SP
    STA $91
    LDA +10,SP
    STA $92
    ADD SP, #13              ; pop the loop frame
rel_free:
    ; Free path (no-dealloc BEQ and post-dispatch fall-through). Restore the
    ; caller's $83 first; _heap_free is $83-callee-saved, so the tail-call
    ; leaves it intact on return.
    LDX _rel_sp
    DEX
    LDA _rel_stk,X
    STA __bank_data_reg
    STX _rel_sp
    LDA $90
    LDX $91
    LDY $92
    JMP _heap_free           ; tail-call (A:X:Y = ptr + bank)
rel_done:
    RTS

__xtc_dealloc:
    INC $95                  ; diagnostic: bump 8-bit counter
    JMP _heap_free           ; A:X:Y = ptr + bank, preserved through INC
; @@LL-ARC-END@@

; ── Indirect-call trampolines (used by __xtc_release's dealloc dispatch
; and by the codegen's VTblDispatch / CallIndirect).  These are normally
; emitted by the codegen only when needed; we pre-define them here so the
; dealloc path in __xtc_release always has them available.
__xt_indjmp:
    JMP ($85)                ; flat indirect jump

__xt_indcall:
    LDA _xc_bank
    BNE __xt_indcall_b
    JMP ($85)                ; unbanked: raw indirect jump
__xt_indcall_b:
    LDA $85
    STA _xcall_vec
    LDA $86
    STA _xcall_vec+1
    JMP _xcall               ; banked: route through the _xcall trampoline

; ── Weak references — degenerate no-ops (no side table). ────────
__xtc_weak_register:
    RTS
__xtc_weak_unregister:
    RTS
__xtc_weak_load:
    LDA #0
    LDX #0
    TAY
    RTS

; ── MemCopy / MemSet — bare-minimum stubs. ──────────────────────
__xtc_memcpy:
    RTS
__xtc_memset:
    RTS

; ── Integer arithmetic runtime — the REAL routines from the 6502-arch
; tree (support/xt6502/asm/). They take operands in $B0-$B7 and leave the
; result at $B0.., matching the backend's helper ABI. Resolved via the
; corpus's `-I .` so these project-root paths work from build/corpus/<n>/.
; (Pulled in wholesale: the signed routines JSR the unsigned ones, so the
; set is dependency-closed.)
.include "xt6502/asm/u8/u8Mul.asm"
.include "xt6502/asm/u8/u8Div.asm"
.include "xt6502/asm/u8/u8Mod.asm"
.include "xt6502/asm/u16/u16Mul.asm"
.include "xt6502/asm/u16/u16Div.asm"
.include "xt6502/asm/u16/u16Mod.asm"
.include "xt6502/asm/u32/u32Mul.asm"
.include "xt6502/asm/u32/u32Div.asm"
.include "xt6502/asm/u32/u32Mod.asm"
.include "xt6502/asm/i8/i8Mul.asm"
.include "xt6502/asm/i8/i8Div.asm"
.include "xt6502/asm/i8/i8Mod.asm"
.include "xt6502/asm/i16/i16Mul.asm"
.include "xt6502/asm/i16/i16Div.asm"
.include "xt6502/asm/i16/i16Mod.asm"
.include "xt6502/asm/i32/i32Mul.asm"
.include "xt6502/asm/i32/i32Div.asm"
.include "xt6502/asm/i32/i32Mod.asm"

; Float + double arithmetic runtime: now BANKED (task #121). The float
; pack, the float-extras (trig/sqrt/abs/mod), and the double pack are no
; longer .include'd unbanked here — buildXt6502Stub places their bodies in
; the `.org` runtime page after the generated code and emits unbanked
; `_<name>` thunks for them, freeing ~10 KB of unbanked budget. The integer
; mul/div/mod pack above stays unbanked (small; same $B0-$B7 ABI).

; Alias the backend's `_`-prefixed names to the routines' bare labels.
; (Float/double aliases are now thunks emitted by buildXt6502Stub.)
_u8Mul  = u8Mul
_u8Div  = u8Div
_u8Mod  = u8Mod
_i8Mul  = i8Mul
_i8Div  = i8Div
_i8Mod  = i8Mod
_u16Mul = u16Mul
_u16Div = u16Div
_u16Mod = u16Mod
_i16Mul = i16Mul
_i16Div = i16Div
_i16Mod = i16Mod
_u32Mul = u32Mul
_u32Div = u32Div
_u32Mod = u32Mod
_i32Mul = i32Mul
_i32Div = i32Div
_i32Mod = i32Mod
; Float/double `_<name>` routes are unbanked thunks emitted by
; buildXt6502Stub (task #121), not aliases — they trampoline into the
; banked runtime page via _xcall.

; ── 8-bit shifts ────────────────────────────────────────
;   $B0 = value, $B1 = count, result at $B0
_u8Shl:
    LDX $B1
    BEQ _u8_ret
    LDA $B0
_u8Shl_l:
    ASL A
    DEX
    BNE _u8Shl_l
    STA $B0
_u8_ret:
    RTS

_u8LShr:
    LDX $B1
    BEQ _u8_ret
    LDA $B0
_u8LShr_l:
    LSR A
    DEX
    BNE _u8LShr_l
    STA $B0
    RTS

_u8AShr:
    LDX $B1
    BEQ _u8_ret
    LDA $B0
_u8AShr_l:
    CMP #$80        ; set carry if sign bit set (arithmetic)
    ROR A
    DEX
    BNE _u8AShr_l
    STA $B0
    RTS

_u8Rol:
    LDX $B1
    BEQ _u8_ret
    LDA $B0
_u8Rol_l:
    ROL A
    DEX
    BNE _u8Rol_l
    STA $B0
    RTS

_u8Ror:
    LDX $B1
    BEQ _u8_ret
    LDA $B0
_u8Ror_l:
    ROR A
    DEX
    BNE _u8Ror_l
    STA $B0
    RTS

; ── 16-bit shifts ───────────────────────────────────────
;   $B0-$B1 = value (LE), $B2 = count, result at $B0-$B1
_u16Shl:
    LDX $B2
    BEQ _u16_ret
_u16Shl_l:
    ASL $B0
    ROL $B1
    DEX
    BNE _u16Shl_l
_u16_ret:
    RTS

_u16LShr:
    LDX $B2
    BEQ _u16_ret
_u16LShr_l:
    LSR $B1
    ROR $B0
    DEX
    BNE _u16LShr_l
    RTS

_u16AShr:
    LDX $B2
    BEQ _u16_ret
_u16AShr_l:
    LDA $B1
    AND #$80        ; isolate sign bit
    STA $B3         ; save in temp ($B3 unused by u16)
    LSR $B1         ; high byte >> 1
    ROR $B0         ; low byte >> 1
    LDA $B1
    ORA $B3         ; restore sign extension
    STA $B1
    DEX
    BNE _u16AShr_l
    RTS

_u16Rol:
    LDX $B2
    BEQ _u16_ret
_u16Rol_l:
    ROL $B0
    ROL $B1
    DEX
    BNE _u16Rol_l
    RTS

_u16Ror:
    LDX $B2
    BEQ _u16_ret
_u16Ror_l:
    ROR $B1
    ROR $B0
    DEX
    BNE _u16Ror_l
    RTS

; ── 32-bit shifts ───────────────────────────────────────
;   $B0-$B3 = value (LE), $B4 = count, result at $B0-$B3
_u32Shl:
    LDX $B4
    BEQ _u32_ret
_u32Shl_l:
    ASL $B0
    ROL $B1
    ROL $B2
    ROL $B3
    DEX
    BNE _u32Shl_l
_u32_ret:
    RTS

_u32LShr:
    LDX $B4
    BEQ _u32_ret
_u32LShr_l:
    LSR $B3
    ROR $B2
    ROR $B1
    ROR $B0
    DEX
    BNE _u32LShr_l
    RTS

_u32AShr:
    LDX $B4
    BEQ _u32_ret
_u32AShr_l:
    LDA $B3
    AND #$80        ; isolate sign bit
    STA $B5         ; save in temp ($B5 unused by u32)
    LSR $B3         ; high byte >> 1
    ROR $B2
    ROR $B1
    ROR $B0
    LDA $B3
    ORA $B5         ; restore sign extension
    STA $B3
    DEX
    BNE _u32AShr_l
    RTS


_u32Rol:
    LDX $B4
    BEQ _u32_ret
_u32Rol_l:
    ROL $B0
    ROL $B1
    ROL $B2
    ROL $B3
    DEX
    BNE _u32Rol_l
    RTS

_u32Ror:
    LDX $B4
    BEQ _u32_ret
_u32Ror_l:
    ROR $B3
    ROR $B2
    ROR $B1
    ROR $B0
    DEX
    BNE _u32Ror_l
    RTS

; The free-list ARC ABI (_obj_retain / _obj_decref / _heap_free /
; heap_bank_first / _heap_free_bank) and the allocator (_heap_init /
; _heap_alloc16) are now the REAL runtime — heap.asm + retain.asm,
; template-expanded for the flat $0800-$1FFF config and embedded by
; buildXt6502Stub right after the __xtc_new_<T> allocators. They land in
; this unbanked runtime region and are reachable by a plain JSR.
