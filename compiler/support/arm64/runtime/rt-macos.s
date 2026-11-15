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

// rt-macos.s — the self-hosted arm64/macOS runtime (ARC/heap/weak + print + math
// + threads). GENERATED from src/xtc/support-src/rt.c by tools/regen-runtimes.py
// (macos; the recipe: clang -S -O1 -fno-stack-protector -fomit-frame-pointer -arch arm64)
// then checked in. clang never touches a USER compile — this .s is assembled by
// XAArm64Assembler like any other, so the toolchain stays self-hosted. Regenerate
// from src/xtc/support-src/rt.c if the object layout / runtime contract changes.
// Provides: _xtc_alloc, _xtc_new_<prim>, _xtc_dealloc, _xtc_weak_*, _putc,
// _xtc_pf/pd/pfp/pdp, _xm_* (libm wrappers), _xt_getenv, _xt_mkdir, and the _xt_thread/mutex/cond/sem/
// atomic/tls primitives (from support/arm64/runtime/xt-threads.c, which the
// clang-path libxt.c includes too). Object header = 40 bytes, magic 0x58544F42
// at base, refcount u32 at obj-4, weak head at obj-12.
// regenerated with: Apple clang version 17.0.0 (clang-1700.3.19.1)
	.section	__TEXT,__text,regular,pure_instructions
	.build_version macos, 15, 0	sdk_version 26, 0
	.globl	__xtc_alloc                     ; -- Begin function _xtc_alloc
	.p2align	2
__xtc_alloc:                            ; @_xtc_alloc
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #64
	stp	x22, x21, [sp, #16]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #32]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #48]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 64
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	mov	x21, x2
	mov	x20, x1
	mov	x19, x0
	cbz	x1, LBB0_2
; %bb.1:
	mov	x8, #-1048577                   ; =0xffffffffffefffff
	udiv	x8, x8, x20
	cmp	x8, x19
	b.lo	LBB0_5
LBB0_2:
	mul	x8, x20, x19
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB0_4
; %bb.3:
	mov	x8, x0
	mov	x9, #20290                      ; =0x4f42
	movk	x9, #22612, lsl #16
	movk	x9, #1, lsl #32
	str	x9, [x0, #32]
	stp	x20, x19, [x0], #40
	stp	x21, xzr, [x8, #16]
	ldp	x29, x30, [sp, #48]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #32]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #64
	ret
LBB0_4:
Lloh0:
	adrp	x8, ___stderrp@GOTPAGE
Lloh1:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh2:
	ldr	x0, [x8]
	stp	x19, x20, [sp]
Lloh3:
	adrp	x1, l_.str@PAGE
Lloh4:
	add	x1, x1, l_.str@PAGEOFF
	bl	_fprintf
	bl	_abort
LBB0_5:
Lloh5:
	adrp	x8, ___stderrp@GOTPAGE
Lloh6:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh7:
	ldr	x0, [x8]
	stp	x19, x20, [sp]
Lloh8:
	adrp	x1, l_.str.7@PAGE
Lloh9:
	add	x1, x1, l_.str.7@PAGEOFF
	bl	_fprintf
	bl	_abort
	.loh AdrpAdd	Lloh3, Lloh4
	.loh AdrpLdrGotLdr	Lloh0, Lloh1, Lloh2
	.loh AdrpAdd	Lloh8, Lloh9
	.loh AdrpLdrGotLdr	Lloh5, Lloh6, Lloh7
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_alloc_object              ; -- Begin function _xtc_alloc_object
	.p2align	2
__xtc_alloc_object:                     ; @_xtc_alloc_object
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	x19, x0
	cmn	x0, #256, lsl #12               ; =1048576
	b.hs	LBB1_3
; %bb.1:
	add	x1, x19, #8
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB1_4
; %bb.2:
	mov	x8, #20302                      ; =0x4f4e
	movk	x8, #22612, lsl #16
	movk	x8, #1, lsl #32
	str	x8, [x0], #8
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB1_3:
	mov	x0, x19
	bl	__xtc_alloc_object.cold.2
LBB1_4:
	mov	x0, x19
	bl	__xtc_alloc_object.cold.1
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_u8                    ; -- Begin function _xtc_new_u8
	.p2align	2
__xtc_new_u8:                           ; @_xtc_new_u8
	.cfi_startproc
; %bb.0:
	mov	w1, #1                          ; =0x1
	cmp	x0, #16, lsl #12                ; =65536
	b.lo	LBB2_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB2_2:
	cmp	x0, #1024
	b.lo	LBB2_4
; %bb.3:
	b	__xtc_alloc_line
LBB2_4:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_alloc_aligned             ; -- Begin function _xtc_alloc_aligned
	.p2align	2
__xtc_alloc_aligned:                    ; @_xtc_alloc_aligned
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #112
	stp	x28, x27, [sp, #16]             ; 16-byte Folded Spill
	stp	x26, x25, [sp, #32]             ; 16-byte Folded Spill
	stp	x24, x23, [sp, #48]             ; 16-byte Folded Spill
	stp	x22, x21, [sp, #64]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #80]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #96]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 112
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	.cfi_offset w23, -56
	.cfi_offset w24, -64
	.cfi_offset w25, -72
	.cfi_offset w26, -80
	.cfi_offset w27, -88
	.cfi_offset w28, -96
	mov	x22, x2
	mov	x20, x1
	mov	x21, x0
	cbz	x1, LBB3_2
; %bb.1:
	mov	x8, #-1048577                   ; =0xffffffffffefffff
	udiv	x8, x8, x20
	cmp	x8, x21
	b.lo	LBB3_28
LBB3_2:
	mul	x23, x20, x21
	mov	w8, #16                         ; =0x10
	cmp	x23, #16
	csel	x8, x23, x8, hi
	mov	w9, #16383                      ; =0x3fff
	add	x8, x8, x9
	and	x8, x8, #0xffffffffffffc000
	mov	w9, #16432                      ; =0x4030
	add	x1, x8, x9
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB3_27
; %bb.3:
	mov	w8, #16431                      ; =0x402f
	add	x8, x0, x8
	and	x19, x8, #0xffffffffffffc000
	mov	x8, #20291                      ; =0x4f43
	movk	x8, #22612, lsl #16
	movk	x8, #1, lsl #32
	stp	x21, x22, [x19, #-32]
	stp	xzr, x8, [x19, #-16]
	stp	x0, x20, [x19, #-48]
	adrp	x20, __xt_threads_active@PAGE
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB3_5
; %bb.4:
Lloh10:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh11:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB3_5:
	adrp	x25, _xt_simd_n@PAGE
	ldr	x24, [x25, _xt_simd_n@PAGEOFF]
	adrp	x28, _xt_simd_cap@PAGE
	ldr	x8, [x28, _xt_simd_cap@PAGEOFF]
	adrp	x27, _xt_simd_tab@PAGE
	adrp	x21, _xt_simd_flag@PAGE
	cmp	x24, x8
	b.ne	LBB3_17
; %bb.6:
	lsl	x9, x8, #1
	mov	w10, #64                        ; =0x40
	cmp	x8, #0
	csel	x20, x10, x9, eq
	lsl	x0, x20, #1
	mov	w1, #8                          ; =0x8
	bl	_calloc
	mov	x21, x0
	mov	x0, x20
	mov	w1, #1                          ; =0x1
	bl	_calloc
	mov	x22, x0
	cmp	x21, #0
	ccmp	x0, #0, #4, ne
	cset	w26, ne
	b.eq	LBB3_14
; %bb.7:
	lsl	x8, x24, #1
	cbz	x8, LBB3_10
; %bb.8:
	ldr	x9, [x27, _xt_simd_tab@PAGEOFF]
	mov	x10, x21
LBB3_9:                                 ; =>This Inner Loop Header: Depth=1
	ldr	x11, [x9], #8
	str	x11, [x10], #8
	subs	x8, x8, #1
	b.ne	LBB3_9
LBB3_10:
	cbz	x24, LBB3_13
; %bb.11:
Lloh12:
	adrp	x8, _xt_simd_flag@PAGE
Lloh13:
	ldr	x8, [x8, _xt_simd_flag@PAGEOFF]
	mov	x9, x22
LBB3_12:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w10, [x8], #1
	strb	w10, [x9], #1
	subs	x24, x24, #1
	b.ne	LBB3_12
LBB3_13:
	ldr	x0, [x27, _xt_simd_tab@PAGEOFF]
	bl	_free
	adrp	x24, _xt_simd_flag@PAGE
	ldr	x0, [x24, _xt_simd_flag@PAGEOFF]
	bl	_free
	str	x21, [x27, _xt_simd_tab@PAGEOFF]
	mov	x21, x24
	str	x22, [x24, _xt_simd_flag@PAGEOFF]
	str	x20, [x28, _xt_simd_cap@PAGEOFF]
	adrp	x20, __xt_threads_active@PAGE
	b	LBB3_16
LBB3_14:
	mov	x0, x21
	bl	_free
	mov	x0, x22
	bl	_free
	adrp	x20, __xt_threads_active@PAGE
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	adrp	x21, _xt_simd_flag@PAGE
	cbz	w8, LBB3_16
; %bb.15:
Lloh14:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh15:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB3_16:
	cbz	w26, LBB3_26
LBB3_17:
	ldr	x8, [x25, _xt_simd_n@PAGEOFF]
	cbz	x8, LBB3_21
; %bb.18:
	mov	x9, #0                          ; =0x0
	ldr	x10, [x27, _xt_simd_tab@PAGEOFF]
	mov	x11, x8
LBB3_19:                                ; =>This Inner Loop Header: Depth=1
	add	x12, x11, x9
	lsr	x13, x12, #1
	and	x12, x12, #0x1ffffffffffffffe
	ldr	x12, [x10, x12, lsl #3]
	cmp	x12, x19
	csel	x11, x13, x11, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x11
	b.lo	LBB3_19
; %bb.20:
	cmp	x8, x9
	b.hi	LBB3_22
	b	LBB3_24
LBB3_21:
	mov	x9, #0                          ; =0x0
	cmp	x8, x9
	b.ls	LBB3_24
LBB3_22:
	ldr	x11, [x27, _xt_simd_tab@PAGEOFF]
	ldr	x12, [x21, _xt_simd_flag@PAGEOFF]
	sub	x10, x8, #1
	add	x13, x12, x8
	add	x14, x11, x8, lsl #4
	mov	x11, x14
	mov	x12, x13
LBB3_23:                                ; =>This Inner Loop Header: Depth=1
	ldr	x15, [x11, #-16]!
	ldur	x16, [x14, #-8]
	stp	x15, x16, [x14]
	ldrb	w14, [x12, #-1]!
	strb	w14, [x13]
	sub	x15, x10, #1
	mov	x14, x11
	mov	x13, x12
	cmp	x10, x9
	mov	x10, x15
	b.hi	LBB3_23
LBB3_24:
	ldr	x10, [x27, _xt_simd_tab@PAGEOFF]
	add	x10, x10, x9, lsl #4
	add	x11, x19, x23
	stp	x19, x11, [x10]
	ldr	x10, [x21, _xt_simd_flag@PAGEOFF]
	strb	wzr, [x10, x9]
	add	x8, x8, #1
	str	x8, [x25, _xt_simd_n@PAGEOFF]
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB3_26
; %bb.25:
Lloh16:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh17:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB3_26:
	mov	x0, x19
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #64]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #48]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #32]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
LBB3_27:
Lloh18:
	adrp	x8, ___stderrp@GOTPAGE
Lloh19:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh20:
	ldr	x0, [x8]
	stp	x21, x20, [sp]
Lloh21:
	adrp	x1, l_.str@PAGE
Lloh22:
	add	x1, x1, l_.str@PAGEOFF
	bl	_fprintf
	bl	_abort
LBB3_28:
Lloh23:
	adrp	x8, ___stderrp@GOTPAGE
Lloh24:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh25:
	ldr	x0, [x8]
	stp	x21, x20, [sp]
Lloh26:
	adrp	x1, l_.str.7@PAGE
Lloh27:
	add	x1, x1, l_.str.7@PAGEOFF
	bl	_fprintf
	bl	_abort
	.loh AdrpAdd	Lloh10, Lloh11
	.loh AdrpLdr	Lloh12, Lloh13
	.loh AdrpAdd	Lloh14, Lloh15
	.loh AdrpAdd	Lloh16, Lloh17
	.loh AdrpAdd	Lloh21, Lloh22
	.loh AdrpLdrGotLdr	Lloh18, Lloh19, Lloh20
	.loh AdrpAdd	Lloh26, Lloh27
	.loh AdrpLdrGotLdr	Lloh23, Lloh24, Lloh25
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_alloc_line                ; -- Begin function _xtc_alloc_line
	.p2align	2
__xtc_alloc_line:                       ; @_xtc_alloc_line
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #48
	stp	x20, x19, [sp, #16]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #32]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 48
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	x19, x1
	mov	x20, x0
	cbz	x1, LBB4_2
; %bb.1:
	mov	x8, #-1048577                   ; =0xffffffffffefffff
	udiv	x8, x8, x19
	cmp	x8, x20
	b.lo	LBB4_5
LBB4_2:
	mov	x8, #112                        ; =0x70
	madd	x1, x19, x20, x8
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB4_4
; %bb.3:
	add	x8, x0, #111
	and	x8, x8, #0xffffffffffffffc0
	mov	x9, #20291                      ; =0x4f43
	movk	x9, #22612, lsl #16
	movk	x9, #1, lsl #32
	stp	xzr, x9, [x8, #-16]
	stp	x20, xzr, [x8, #-32]
	stp	x0, x19, [x8, #-48]
	mov	x0, x8
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #48
	ret
LBB4_4:
Lloh28:
	adrp	x8, ___stderrp@GOTPAGE
Lloh29:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh30:
	ldr	x0, [x8]
	stp	x20, x19, [sp]
Lloh31:
	adrp	x1, l_.str@PAGE
Lloh32:
	add	x1, x1, l_.str@PAGEOFF
	bl	_fprintf
	bl	_abort
LBB4_5:
Lloh33:
	adrp	x8, ___stderrp@GOTPAGE
Lloh34:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh35:
	ldr	x0, [x8]
	stp	x20, x19, [sp]
Lloh36:
	adrp	x1, l_.str.7@PAGE
Lloh37:
	add	x1, x1, l_.str.7@PAGEOFF
	bl	_fprintf
	bl	_abort
	.loh AdrpAdd	Lloh31, Lloh32
	.loh AdrpLdrGotLdr	Lloh28, Lloh29, Lloh30
	.loh AdrpAdd	Lloh36, Lloh37
	.loh AdrpLdrGotLdr	Lloh33, Lloh34, Lloh35
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_i8                    ; -- Begin function _xtc_new_i8
	.p2align	2
__xtc_new_i8:                           ; @_xtc_new_i8
	.cfi_startproc
; %bb.0:
	mov	w1, #1                          ; =0x1
	cmp	x0, #16, lsl #12                ; =65536
	b.lo	LBB5_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB5_2:
	cmp	x0, #1024
	b.lo	LBB5_4
; %bb.3:
	b	__xtc_alloc_line
LBB5_4:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_u16                   ; -- Begin function _xtc_new_u16
	.p2align	2
__xtc_new_u16:                          ; @_xtc_new_u16
	.cfi_startproc
; %bb.0:
	lsl	x8, x0, #1
	mov	w1, #2                          ; =0x2
	cmp	x8, #16, lsl #12                ; =65536
	b.lo	LBB6_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB6_2:
	cmp	x8, #1024
	b.lo	LBB6_4
; %bb.3:
	b	__xtc_alloc_line
LBB6_4:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_i16                   ; -- Begin function _xtc_new_i16
	.p2align	2
__xtc_new_i16:                          ; @_xtc_new_i16
	.cfi_startproc
; %bb.0:
	lsl	x8, x0, #1
	mov	w1, #2                          ; =0x2
	cmp	x8, #16, lsl #12                ; =65536
	b.lo	LBB7_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB7_2:
	cmp	x8, #1024
	b.lo	LBB7_4
; %bb.3:
	b	__xtc_alloc_line
LBB7_4:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_u32                   ; -- Begin function _xtc_new_u32
	.p2align	2
__xtc_new_u32:                          ; @_xtc_new_u32
	.cfi_startproc
; %bb.0:
	lsl	x8, x0, #2
	mov	w1, #4                          ; =0x4
	cmp	x8, #16, lsl #12                ; =65536
	b.lo	LBB8_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB8_2:
	cmp	x8, #1024
	b.lo	LBB8_4
; %bb.3:
	b	__xtc_alloc_line
LBB8_4:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_i32                   ; -- Begin function _xtc_new_i32
	.p2align	2
__xtc_new_i32:                          ; @_xtc_new_i32
	.cfi_startproc
; %bb.0:
	lsl	x8, x0, #2
	mov	w1, #4                          ; =0x4
	cmp	x8, #16, lsl #12                ; =65536
	b.lo	LBB9_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB9_2:
	cmp	x8, #1024
	b.lo	LBB9_4
; %bb.3:
	b	__xtc_alloc_line
LBB9_4:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_u64                   ; -- Begin function _xtc_new_u64
	.p2align	2
__xtc_new_u64:                          ; @_xtc_new_u64
	.cfi_startproc
; %bb.0:
	lsl	x8, x0, #3
	mov	w1, #8                          ; =0x8
	cmp	x8, #16, lsl #12                ; =65536
	b.lo	LBB10_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB10_2:
	cmp	x8, #1024
	b.lo	LBB10_4
; %bb.3:
	b	__xtc_alloc_line
LBB10_4:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_i64                   ; -- Begin function _xtc_new_i64
	.p2align	2
__xtc_new_i64:                          ; @_xtc_new_i64
	.cfi_startproc
; %bb.0:
	lsl	x8, x0, #3
	mov	w1, #8                          ; =0x8
	cmp	x8, #16, lsl #12                ; =65536
	b.lo	LBB11_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB11_2:
	cmp	x8, #1024
	b.lo	LBB11_4
; %bb.3:
	b	__xtc_alloc_line
LBB11_4:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_pointer               ; -- Begin function _xtc_new_pointer
	.p2align	2
__xtc_new_pointer:                      ; @_xtc_new_pointer
	.cfi_startproc
; %bb.0:
	mov	w1, #8                          ; =0x8
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_bool                  ; -- Begin function _xtc_new_bool
	.p2align	2
__xtc_new_bool:                         ; @_xtc_new_bool
	.cfi_startproc
; %bb.0:
	mov	w1, #1                          ; =0x1
	cmp	x0, #16, lsl #12                ; =65536
	b.lo	LBB13_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB13_2:
	cmp	x0, #1024
	b.lo	LBB13_4
; %bb.3:
	b	__xtc_alloc_line
LBB13_4:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_float                 ; -- Begin function _xtc_new_float
	.p2align	2
__xtc_new_float:                        ; @_xtc_new_float
	.cfi_startproc
; %bb.0:
	lsl	x8, x0, #2
	mov	w1, #4                          ; =0x4
	cmp	x8, #16, lsl #12                ; =65536
	b.lo	LBB14_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB14_2:
	cmp	x8, #1024
	b.lo	LBB14_4
; %bb.3:
	b	__xtc_alloc_line
LBB14_4:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_double                ; -- Begin function _xtc_new_double
	.p2align	2
__xtc_new_double:                       ; @_xtc_new_double
	.cfi_startproc
; %bb.0:
	lsl	x8, x0, #3
	mov	w1, #8                          ; =0x8
	cmp	x8, #16, lsl #12                ; =65536
	b.lo	LBB15_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB15_2:
	cmp	x8, #1024
	b.lo	LBB15_4
; %bb.3:
	b	__xtc_alloc_line
LBB15_4:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_string                ; -- Begin function _xtc_new_string
	.p2align	2
__xtc_new_string:                       ; @_xtc_new_string
	.cfi_startproc
; %bb.0:
	mov	w1, #8                          ; =0x8
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_simd_register             ; -- Begin function _xtc_simd_register
	.p2align	2
__xtc_simd_register:                    ; @_xtc_simd_register
	.cfi_startproc
; %bb.0:
	stp	x28, x27, [sp, #-96]!           ; 16-byte Folded Spill
	stp	x26, x25, [sp, #16]             ; 16-byte Folded Spill
	stp	x24, x23, [sp, #32]             ; 16-byte Folded Spill
	stp	x22, x21, [sp, #48]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #64]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #80]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 96
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	.cfi_offset w23, -56
	.cfi_offset w24, -64
	.cfi_offset w25, -72
	.cfi_offset w26, -80
	.cfi_offset w27, -88
	.cfi_offset w28, -96
	cbz	x0, LBB17_26
; %bb.1:
	mov	x20, x1
	cbz	x1, LBB17_26
; %bb.2:
	mov	x19, x0
	orr	w8, w19, w20
	and	x8, x8, #0xfff
	cbnz	x8, LBB17_26
; %bb.3:
	adrp	x21, __xt_threads_active@PAGE
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB17_5
; %bb.4:
Lloh38:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh39:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB17_5:
	adrp	x25, _xt_simd_n@PAGE
	ldr	x24, [x25, _xt_simd_n@PAGEOFF]
	adrp	x28, _xt_simd_cap@PAGE
	ldr	x8, [x28, _xt_simd_cap@PAGEOFF]
	adrp	x27, _xt_simd_tab@PAGE
	adrp	x22, _xt_simd_flag@PAGE
	cmp	x24, x8
	b.ne	LBB17_17
; %bb.6:
	lsl	x9, x8, #1
	mov	w10, #64                        ; =0x40
	cmp	x8, #0
	csel	x21, x10, x9, eq
	lsl	x0, x21, #1
	mov	w1, #8                          ; =0x8
	bl	_calloc
	mov	x22, x0
	mov	x0, x21
	mov	w1, #1                          ; =0x1
	bl	_calloc
	mov	x23, x0
	cmp	x22, #0
	ccmp	x0, #0, #4, ne
	cset	w26, ne
	b.eq	LBB17_14
; %bb.7:
	lsl	x8, x24, #1
	cbz	x8, LBB17_10
; %bb.8:
	ldr	x9, [x27, _xt_simd_tab@PAGEOFF]
	mov	x10, x22
LBB17_9:                                ; =>This Inner Loop Header: Depth=1
	ldr	x11, [x9], #8
	str	x11, [x10], #8
	subs	x8, x8, #1
	b.ne	LBB17_9
LBB17_10:
	cbz	x24, LBB17_13
; %bb.11:
Lloh40:
	adrp	x8, _xt_simd_flag@PAGE
Lloh41:
	ldr	x8, [x8, _xt_simd_flag@PAGEOFF]
	mov	x9, x23
LBB17_12:                               ; =>This Inner Loop Header: Depth=1
	ldrb	w10, [x8], #1
	strb	w10, [x9], #1
	subs	x24, x24, #1
	b.ne	LBB17_12
LBB17_13:
	ldr	x0, [x27, _xt_simd_tab@PAGEOFF]
	bl	_free
	adrp	x24, _xt_simd_flag@PAGE
	ldr	x0, [x24, _xt_simd_flag@PAGEOFF]
	bl	_free
	str	x22, [x27, _xt_simd_tab@PAGEOFF]
	mov	x22, x24
	str	x23, [x24, _xt_simd_flag@PAGEOFF]
	str	x21, [x28, _xt_simd_cap@PAGEOFF]
	adrp	x21, __xt_threads_active@PAGE
	b	LBB17_16
LBB17_14:
	mov	x0, x22
	bl	_free
	mov	x0, x23
	bl	_free
	adrp	x21, __xt_threads_active@PAGE
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	adrp	x22, _xt_simd_flag@PAGE
	cbz	w8, LBB17_16
; %bb.15:
Lloh42:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh43:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB17_16:
	cbz	w26, LBB17_26
LBB17_17:
	ldr	x8, [x25, _xt_simd_n@PAGEOFF]
	cbz	x8, LBB17_21
; %bb.18:
	mov	x9, #0                          ; =0x0
	ldr	x10, [x27, _xt_simd_tab@PAGEOFF]
	mov	x11, x8
LBB17_19:                               ; =>This Inner Loop Header: Depth=1
	add	x12, x11, x9
	lsr	x13, x12, #1
	and	x12, x12, #0x1ffffffffffffffe
	ldr	x12, [x10, x12, lsl #3]
	cmp	x12, x19
	csel	x11, x13, x11, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x11
	b.lo	LBB17_19
; %bb.20:
	cmp	x8, x9
	b.hi	LBB17_22
	b	LBB17_24
LBB17_21:
	mov	x9, #0                          ; =0x0
	cmp	x8, x9
	b.ls	LBB17_24
LBB17_22:
	ldr	x11, [x27, _xt_simd_tab@PAGEOFF]
	ldr	x12, [x22, _xt_simd_flag@PAGEOFF]
	sub	x10, x8, #1
	add	x13, x12, x8
	add	x14, x11, x8, lsl #4
	mov	x11, x14
	mov	x12, x13
LBB17_23:                               ; =>This Inner Loop Header: Depth=1
	ldr	x15, [x11, #-16]!
	ldur	x16, [x14, #-8]
	stp	x15, x16, [x14]
	ldrb	w14, [x12, #-1]!
	strb	w14, [x13]
	sub	x15, x10, #1
	mov	x14, x11
	mov	x13, x12
	cmp	x10, x9
	mov	x10, x15
	b.hi	LBB17_23
LBB17_24:
	ldr	x10, [x27, _xt_simd_tab@PAGEOFF]
	add	x10, x10, x9, lsl #4
	add	x11, x19, x20
	stp	x19, x11, [x10]
	ldr	x10, [x22, _xt_simd_flag@PAGEOFF]
	strb	wzr, [x10, x9]
	add	x8, x8, #1
	str	x8, [x25, _xt_simd_n@PAGEOFF]
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB17_26
; %bb.25:
Lloh44:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh45:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #80]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #64]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp], #96             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB17_26:
	ldp	x29, x30, [sp, #80]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #64]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp], #96             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh38, Lloh39
	.loh AdrpLdr	Lloh40, Lloh41
	.loh AdrpAdd	Lloh42, Lloh43
	.loh AdrpAdd	Lloh44, Lloh45
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_simd_base                 ; -- Begin function _xtc_simd_base
	.p2align	2
__xtc_simd_base:                        ; @_xtc_simd_base
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	x19, x0
	adrp	x20, __xt_threads_active@PAGE
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB18_2
; %bb.1:
Lloh46:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh47:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB18_2:
Lloh48:
	adrp	x8, _xt_simd_n@PAGE
Lloh49:
	ldr	x10, [x8, _xt_simd_n@PAGEOFF]
Lloh50:
	adrp	x8, _xt_simd_tab@PAGE
	mov	x9, #0                          ; =0x0
	cbz	x10, LBB18_5
; %bb.3:
	ldr	x11, [x8, _xt_simd_tab@PAGEOFF]
LBB18_4:                                ; =>This Inner Loop Header: Depth=1
	add	x12, x10, x9
	lsr	x13, x12, #1
	and	x12, x12, #0x1ffffffffffffffe
	ldr	x12, [x11, x12, lsl #3]
	cmp	x12, x19
	csel	x10, x13, x10, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x10
	b.lo	LBB18_4
LBB18_5:
	cbz	x9, LBB18_8
; %bb.6:
	ldr	x8, [x8, _xt_simd_tab@PAGEOFF]
	add	x8, x8, x9, lsl #4
	ldur	x9, [x8, #-8]
	cmp	x9, x19
	b.ls	LBB18_8
; %bb.7:
	ldur	x19, [x8, #-16]
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbnz	w8, LBB18_9
	b	LBB18_10
LBB18_8:
	mov	x19, #0                         ; =0x0
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB18_10
LBB18_9:
Lloh51:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh52:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB18_10:
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh46, Lloh47
	.loh AdrpAdrp	Lloh48, Lloh50
	.loh AdrpLdr	Lloh48, Lloh49
	.loh AdrpAdd	Lloh51, Lloh52
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_rt_lock                    ; -- Begin function _xt_rt_lock
	.p2align	2
__xt_rt_lock:                           ; @_xt_rt_lock
	.cfi_startproc
; %bb.0:
Lloh53:
	adrp	x8, __xt_threads_active@PAGE
Lloh54:
	ldr	w8, [x8, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB19_2
; %bb.1:
Lloh55:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh56:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	b	_pthread_mutex_lock
LBB19_2:
	ret
	.loh AdrpLdr	Lloh53, Lloh54
	.loh AdrpAdd	Lloh55, Lloh56
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_rt_unlock                  ; -- Begin function _xt_rt_unlock
	.p2align	2
__xt_rt_unlock:                         ; @_xt_rt_unlock
	.cfi_startproc
; %bb.0:
Lloh57:
	adrp	x8, __xt_threads_active@PAGE
Lloh58:
	ldr	w8, [x8, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB20_2
; %bb.1:
Lloh59:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh60:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	b	_pthread_mutex_unlock
LBB20_2:
	ret
	.loh AdrpLdr	Lloh57, Lloh58
	.loh AdrpAdd	Lloh59, Lloh60
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_simd_span                 ; -- Begin function _xtc_simd_span
	.p2align	2
__xtc_simd_span:                        ; @_xtc_simd_span
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	x19, x0
	adrp	x20, __xt_threads_active@PAGE
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB21_2
; %bb.1:
Lloh61:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh62:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB21_2:
Lloh63:
	adrp	x8, _xt_simd_n@PAGE
Lloh64:
	ldr	x10, [x8, _xt_simd_n@PAGEOFF]
Lloh65:
	adrp	x8, _xt_simd_tab@PAGE
	mov	x9, #0                          ; =0x0
	cbz	x10, LBB21_5
; %bb.3:
	ldr	x11, [x8, _xt_simd_tab@PAGEOFF]
LBB21_4:                                ; =>This Inner Loop Header: Depth=1
	add	x12, x10, x9
	lsr	x13, x12, #1
	and	x12, x12, #0x1ffffffffffffffe
	ldr	x12, [x11, x12, lsl #3]
	cmp	x12, x19
	csel	x10, x13, x10, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x10
	b.lo	LBB21_4
LBB21_5:
	cbz	x9, LBB21_7
; %bb.6:
	ldr	x8, [x8, _xt_simd_tab@PAGEOFF]
	add	x8, x8, x9, lsl #4
	ldur	x8, [x8, #-8]
	subs	x19, x8, x19
	b.hi	LBB21_8
LBB21_7:
	mov	x19, #-1                        ; =0xffffffffffffffff
LBB21_8:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB21_10
; %bb.9:
Lloh66:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh67:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB21_10:
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh61, Lloh62
	.loh AdrpAdrp	Lloh63, Lloh65
	.loh AdrpLdr	Lloh63, Lloh64
	.loh AdrpAdd	Lloh66, Lloh67
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_simd_on_fetch             ; -- Begin function _xtc_simd_on_fetch
	.p2align	2
__xtc_simd_on_fetch:                    ; @_xtc_simd_on_fetch
	.cfi_startproc
; %bb.0:
Lloh68:
	adrp	x8, _xt_simd_hook_recv@PAGE
	str	x1, [x8, _xt_simd_hook_recv@PAGEOFF]
Lloh69:
	adrp	x8, _xt_simd_hook_code@PAGE
	str	x0, [x8, _xt_simd_hook_code@PAGEOFF]
	ret
	.loh AdrpAdrp	Lloh68, Lloh69
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_simd_watch                ; -- Begin function _xtc_simd_watch
	.p2align	2
__xtc_simd_watch:                       ; @_xtc_simd_watch
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #96
	stp	x26, x25, [sp, #16]             ; 16-byte Folded Spill
	stp	x24, x23, [sp, #32]             ; 16-byte Folded Spill
	stp	x22, x21, [sp, #48]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #64]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #80]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 96
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	.cfi_offset w23, -56
	.cfi_offset w24, -64
	.cfi_offset w25, -72
	.cfi_offset w26, -80
	mov	x19, x0
	adrp	x21, __xt_threads_active@PAGE
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB23_2
; %bb.1:
Lloh70:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh71:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB23_2:
Lloh72:
	adrp	x8, _xt_simd_n@PAGE
Lloh73:
	ldr	x9, [x8, _xt_simd_n@PAGEOFF]
	adrp	x22, _xt_simd_tab@PAGE
	mov	x8, #0                          ; =0x0
	cbz	x9, LBB23_5
; %bb.3:
	ldr	x10, [x22, _xt_simd_tab@PAGEOFF]
LBB23_4:                                ; =>This Inner Loop Header: Depth=1
	add	x11, x9, x8
	lsr	x12, x11, #1
	and	x11, x11, #0x1ffffffffffffffe
	ldr	x11, [x10, x11, lsl #3]
	cmp	x11, x19
	csel	x9, x12, x9, hi
	csinc	x8, x8, x12, hi
	cmp	x8, x9
	b.lo	LBB23_4
LBB23_5:
	cbz	x8, LBB23_11
; %bb.6:
	ldr	x9, [x22, _xt_simd_tab@PAGEOFF]
	sub	x23, x8, #1
	lsl	x8, x23, #4
	ldr	x8, [x9, x8]
	cmp	x8, x19
	b.ne	LBB23_11
; %bb.7:
	adrp	x24, _xt_simd_flag@PAGE
	ldr	x8, [x24, _xt_simd_flag@PAGEOFF]
	ldrb	w8, [x8, x23]
	tbnz	w8, #1, LBB23_11
; %bb.8:
	adrp	x25, _xt_simd_installed@PAGE
	ldrb	w8, [x25, _xt_simd_installed@PAGEOFF]
	tbnz	w8, #0, LBB23_10
; %bb.9:
Lloh74:
	adrp	x8, _xt_simd_fault@PAGE
Lloh75:
	add	x8, x8, _xt_simd_fault@PAGEOFF
	mov	x9, #343597383680               ; =0x5000000000
	stp	x8, x9, [sp]
Lloh76:
	adrp	x20, _xt_simd_old@PAGE
Lloh77:
	add	x20, x20, _xt_simd_old@PAGEOFF
	mov	x1, sp
	mov	w0, #11                         ; =0xb
	mov	x2, x20
	bl	_sigaction
	mov	x1, sp
	add	x2, x20, #16
	mov	w0, #10                         ; =0xa
	bl	_sigaction
	mov	w8, #1                          ; =0x1
	strb	w8, [x25, _xt_simd_installed@PAGEOFF]
LBB23_10:
	ldr	x8, [x22, _xt_simd_tab@PAGEOFF]
	add	x8, x8, x23, lsl #4
	ldp	x8, x9, [x8]
	mov	w10, #16383                     ; =0x3fff
	sub	x8, x9, x8
	add	x8, x8, x10
	and	x1, x8, #0xffffffffffffc000
	mov	x0, x19
	mov	w2, #1                          ; =0x1
	bl	_mprotect
	cbz	w0, LBB23_14
LBB23_11:
	mov	w19, #0                         ; =0x0
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB23_13
LBB23_12:
Lloh78:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh79:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB23_13:
	mov	x0, x19
	ldp	x29, x30, [sp, #80]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #64]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #96
	ret
LBB23_14:
	ldr	x8, [x24, _xt_simd_flag@PAGEOFF]
	ldrb	w9, [x8, x23]
	orr	w9, w9, #0x1
	strb	w9, [x8, x23]
	mov	w19, #1                         ; =0x1
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbnz	w8, LBB23_12
	b	LBB23_13
	.loh AdrpAdd	Lloh70, Lloh71
	.loh AdrpLdr	Lloh72, Lloh73
	.loh AdrpAdd	Lloh76, Lloh77
	.loh AdrpAdd	Lloh74, Lloh75
	.loh AdrpAdd	Lloh78, Lloh79
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_simd_park                 ; -- Begin function _xtc_simd_park
	.p2align	2
__xtc_simd_park:                        ; @_xtc_simd_park
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #80
	stp	x24, x23, [sp, #16]             ; 16-byte Folded Spill
	stp	x22, x21, [sp, #32]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #48]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #64]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 80
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	.cfi_offset w23, -56
	.cfi_offset w24, -64
	mov	x19, x0
	adrp	x21, __xt_threads_active@PAGE
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB24_2
; %bb.1:
Lloh80:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh81:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB24_2:
Lloh82:
	adrp	x8, _xt_simd_n@PAGE
Lloh83:
	ldr	x9, [x8, _xt_simd_n@PAGEOFF]
	adrp	x22, _xt_simd_tab@PAGE
	mov	x8, #0                          ; =0x0
	cbz	x9, LBB24_5
; %bb.3:
	ldr	x10, [x22, _xt_simd_tab@PAGEOFF]
LBB24_4:                                ; =>This Inner Loop Header: Depth=1
	add	x11, x9, x8
	lsr	x12, x11, #1
	and	x11, x11, #0x1ffffffffffffffe
	ldr	x11, [x10, x11, lsl #3]
	cmp	x11, x19
	csel	x9, x12, x9, hi
	csinc	x8, x8, x12, hi
	cmp	x8, x9
	b.lo	LBB24_4
LBB24_5:
	cbz	x8, LBB24_10
; %bb.6:
	ldr	x9, [x22, _xt_simd_tab@PAGEOFF]
	sub	x23, x8, #1
	lsl	x8, x23, #4
	ldr	x8, [x9, x8]
	cmp	x8, x19
	b.ne	LBB24_10
; %bb.7:
	adrp	x24, _xt_simd_installed@PAGE
	ldrb	w8, [x24, _xt_simd_installed@PAGEOFF]
	tbnz	w8, #0, LBB24_9
; %bb.8:
Lloh84:
	adrp	x8, _xt_simd_fault@PAGE
Lloh85:
	add	x8, x8, _xt_simd_fault@PAGEOFF
	mov	x9, #343597383680               ; =0x5000000000
	stp	x8, x9, [sp]
Lloh86:
	adrp	x20, _xt_simd_old@PAGE
Lloh87:
	add	x20, x20, _xt_simd_old@PAGEOFF
	mov	x1, sp
	mov	w0, #11                         ; =0xb
	mov	x2, x20
	bl	_sigaction
	mov	x1, sp
	add	x2, x20, #16
	mov	w0, #10                         ; =0xa
	bl	_sigaction
	mov	w8, #1                          ; =0x1
	strb	w8, [x24, _xt_simd_installed@PAGEOFF]
LBB24_9:
	ldr	x8, [x22, _xt_simd_tab@PAGEOFF]
	add	x8, x8, x23, lsl #4
	ldp	x8, x9, [x8]
	mov	w10, #16383                     ; =0x3fff
	sub	x8, x9, x8
	add	x8, x8, x10
	and	x1, x8, #0xffffffffffffc000
	mov	x0, x19
	mov	w2, #0                          ; =0x0
	bl	_mprotect
	cbz	w0, LBB24_13
LBB24_10:
	mov	w19, #0                         ; =0x0
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB24_12
LBB24_11:
Lloh88:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh89:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB24_12:
	mov	x0, x19
	ldp	x29, x30, [sp, #64]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #48]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #32]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #80
	ret
LBB24_13:
Lloh90:
	adrp	x8, _xt_simd_flag@PAGE
Lloh91:
	ldr	x8, [x8, _xt_simd_flag@PAGEOFF]
	ldrb	w9, [x8, x23]
	and	w9, w9, #0xfc
	orr	w9, w9, #0x2
	strb	w9, [x8, x23]
	mov	w19, #1                         ; =0x1
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbnz	w8, LBB24_11
	b	LBB24_12
	.loh AdrpAdd	Lloh80, Lloh81
	.loh AdrpLdr	Lloh82, Lloh83
	.loh AdrpAdd	Lloh86, Lloh87
	.loh AdrpAdd	Lloh84, Lloh85
	.loh AdrpAdd	Lloh88, Lloh89
	.loh AdrpLdr	Lloh90, Lloh91
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_simd_unpark               ; -- Begin function _xtc_simd_unpark
	.p2align	2
__xtc_simd_unpark:                      ; @_xtc_simd_unpark
	.cfi_startproc
; %bb.0:
	stp	x22, x21, [sp, #-48]!           ; 16-byte Folded Spill
	stp	x20, x19, [sp, #16]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #32]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 48
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	mov	x19, x0
	adrp	x20, __xt_threads_active@PAGE
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB25_2
; %bb.1:
Lloh92:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh93:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB25_2:
Lloh94:
	adrp	x8, _xt_simd_n@PAGE
Lloh95:
	ldr	x10, [x8, _xt_simd_n@PAGEOFF]
Lloh96:
	adrp	x8, _xt_simd_tab@PAGE
	mov	x9, #0                          ; =0x0
	cbz	x10, LBB25_5
; %bb.3:
	ldr	x11, [x8, _xt_simd_tab@PAGEOFF]
LBB25_4:                                ; =>This Inner Loop Header: Depth=1
	add	x12, x10, x9
	lsr	x13, x12, #1
	and	x12, x12, #0x1ffffffffffffffe
	ldr	x12, [x11, x12, lsl #3]
	cmp	x12, x19
	csel	x10, x13, x10, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x10
	b.lo	LBB25_4
LBB25_5:
	cbz	x9, LBB25_9
; %bb.6:
	ldr	x8, [x8, _xt_simd_tab@PAGEOFF]
	sub	x21, x9, #1
	lsl	x9, x21, #4
	ldr	x9, [x8, x9]
	cmp	x9, x19
	b.ne	LBB25_9
; %bb.7:
	adrp	x22, _xt_simd_flag@PAGE
	ldr	x9, [x22, _xt_simd_flag@PAGEOFF]
	ldrb	w9, [x9, x21]
	tbz	w9, #1, LBB25_9
; %bb.8:
	add	x8, x8, x21, lsl #4
	ldp	x8, x9, [x8]
	mov	w10, #16383                     ; =0x3fff
	sub	x8, x9, x8
	add	x8, x8, x10
	and	x1, x8, #0xffffffffffffc000
	mov	x0, x19
	mov	w2, #3                          ; =0x3
	bl	_mprotect
	ldr	x8, [x22, _xt_simd_flag@PAGEOFF]
	ldrb	w9, [x8, x21]
	and	w9, w9, #0xfffffffd
	strb	w9, [x8, x21]
LBB25_9:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB25_11
; %bb.10:
Lloh97:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh98:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB25_11:
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh92, Lloh93
	.loh AdrpAdrp	Lloh94, Lloh96
	.loh AdrpLdr	Lloh94, Lloh95
	.loh AdrpAdd	Lloh97, Lloh98
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_simd_unwatch              ; -- Begin function _xtc_simd_unwatch
	.p2align	2
__xtc_simd_unwatch:                     ; @_xtc_simd_unwatch
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	x19, x0
	adrp	x20, __xt_threads_active@PAGE
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB26_2
; %bb.1:
Lloh99:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh100:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB26_2:
Lloh101:
	adrp	x8, _xt_simd_n@PAGE
Lloh102:
	ldr	x10, [x8, _xt_simd_n@PAGEOFF]
Lloh103:
	adrp	x8, _xt_simd_tab@PAGE
	mov	x9, #0                          ; =0x0
	cbz	x10, LBB26_5
; %bb.3:
	ldr	x11, [x8, _xt_simd_tab@PAGEOFF]
LBB26_4:                                ; =>This Inner Loop Header: Depth=1
	add	x12, x10, x9
	lsr	x13, x12, #1
	and	x12, x12, #0x1ffffffffffffffe
	ldr	x12, [x11, x12, lsl #3]
	cmp	x12, x19
	csel	x10, x13, x10, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x10
	b.lo	LBB26_4
LBB26_5:
	cbz	x9, LBB26_9
; %bb.6:
	ldr	x8, [x8, _xt_simd_tab@PAGEOFF]
	sub	x9, x9, #1
	lsl	x10, x9, #4
	ldr	x10, [x8, x10]
	cmp	x10, x19
	b.ne	LBB26_9
; %bb.7:
Lloh104:
	adrp	x10, _xt_simd_flag@PAGE
Lloh105:
	ldr	x10, [x10, _xt_simd_flag@PAGEOFF]
	ldrb	w11, [x10, x9]
	tbz	w11, #0, LBB26_9
; %bb.8:
	and	w11, w11, #0xfe
	strb	w11, [x10, x9]
	add	x8, x8, x9, lsl #4
	ldp	x8, x9, [x8]
	mov	w10, #16383                     ; =0x3fff
	sub	x8, x9, x8
	add	x8, x8, x10
	and	x1, x8, #0xffffffffffffc000
	mov	x0, x19
	mov	w2, #3                          ; =0x3
	bl	_mprotect
LBB26_9:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB26_11
; %bb.10:
Lloh106:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh107:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB26_11:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh99, Lloh100
	.loh AdrpAdrp	Lloh101, Lloh103
	.loh AdrpLdr	Lloh101, Lloh102
	.loh AdrpLdr	Lloh104, Lloh105
	.loh AdrpAdd	Lloh106, Lloh107
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_simd_dirty                ; -- Begin function _xtc_simd_dirty
	.p2align	2
__xtc_simd_dirty:                       ; @_xtc_simd_dirty
	.cfi_startproc
; %bb.0:
	stp	x22, x21, [sp, #-48]!           ; 16-byte Folded Spill
	stp	x20, x19, [sp, #16]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #32]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 48
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	mov	x19, x0
	adrp	x21, __xt_threads_active@PAGE
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB27_2
; %bb.1:
Lloh108:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh109:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB27_2:
Lloh110:
	adrp	x8, _xt_simd_n@PAGE
Lloh111:
	ldr	x10, [x8, _xt_simd_n@PAGEOFF]
Lloh112:
	adrp	x8, _xt_simd_tab@PAGE
	mov	x9, #0                          ; =0x0
	cbz	x10, LBB27_5
; %bb.3:
	ldr	x11, [x8, _xt_simd_tab@PAGEOFF]
LBB27_4:                                ; =>This Inner Loop Header: Depth=1
	add	x12, x10, x9
	lsr	x13, x12, #1
	and	x12, x12, #0x1ffffffffffffffe
	ldr	x12, [x11, x12, lsl #3]
	cmp	x12, x19
	csel	x10, x13, x10, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x10
	b.lo	LBB27_4
LBB27_5:
	cbz	x9, LBB27_8
; %bb.6:
	ldr	x10, [x8, _xt_simd_tab@PAGEOFF]
	sub	x8, x9, #1
	lsl	x9, x8, #4
	ldr	x9, [x10, x9]
	mov	w20, #1                         ; =0x1
	cmp	x9, x19
	b.ne	LBB27_9
; %bb.7:
Lloh113:
	adrp	x9, _xt_simd_flag@PAGE
Lloh114:
	ldr	x9, [x9, _xt_simd_flag@PAGEOFF]
	ldrb	w8, [x9, x8]
	bic	w20, w20, w8
	b	LBB27_9
LBB27_8:
	mov	w20, #1                         ; =0x1
LBB27_9:
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB27_11
; %bb.10:
Lloh115:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh116:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB27_11:
	mov	x0, x20
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh108, Lloh109
	.loh AdrpAdrp	Lloh110, Lloh112
	.loh AdrpLdr	Lloh110, Lloh111
	.loh AdrpLdr	Lloh113, Lloh114
	.loh AdrpAdd	Lloh115, Lloh116
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_simd_u8               ; -- Begin function _xtc_new_simd_u8
	.p2align	2
__xtc_new_simd_u8:                      ; @_xtc_new_simd_u8
	.cfi_startproc
; %bb.0:
	mov	w1, #1                          ; =0x1
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_simd_i8               ; -- Begin function _xtc_new_simd_i8
	.p2align	2
__xtc_new_simd_i8:                      ; @_xtc_new_simd_i8
	.cfi_startproc
; %bb.0:
	mov	w1, #1                          ; =0x1
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_simd_bool             ; -- Begin function _xtc_new_simd_bool
	.p2align	2
__xtc_new_simd_bool:                    ; @_xtc_new_simd_bool
	.cfi_startproc
; %bb.0:
	mov	w1, #1                          ; =0x1
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_simd_u16              ; -- Begin function _xtc_new_simd_u16
	.p2align	2
__xtc_new_simd_u16:                     ; @_xtc_new_simd_u16
	.cfi_startproc
; %bb.0:
	mov	w1, #2                          ; =0x2
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_simd_i16              ; -- Begin function _xtc_new_simd_i16
	.p2align	2
__xtc_new_simd_i16:                     ; @_xtc_new_simd_i16
	.cfi_startproc
; %bb.0:
	mov	w1, #2                          ; =0x2
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_simd_u32              ; -- Begin function _xtc_new_simd_u32
	.p2align	2
__xtc_new_simd_u32:                     ; @_xtc_new_simd_u32
	.cfi_startproc
; %bb.0:
	mov	w1, #4                          ; =0x4
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_simd_i32              ; -- Begin function _xtc_new_simd_i32
	.p2align	2
__xtc_new_simd_i32:                     ; @_xtc_new_simd_i32
	.cfi_startproc
; %bb.0:
	mov	w1, #4                          ; =0x4
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_simd_float            ; -- Begin function _xtc_new_simd_float
	.p2align	2
__xtc_new_simd_float:                   ; @_xtc_new_simd_float
	.cfi_startproc
; %bb.0:
	mov	w1, #4                          ; =0x4
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_simd_u64              ; -- Begin function _xtc_new_simd_u64
	.p2align	2
__xtc_new_simd_u64:                     ; @_xtc_new_simd_u64
	.cfi_startproc
; %bb.0:
	mov	w1, #8                          ; =0x8
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_simd_i64              ; -- Begin function _xtc_new_simd_i64
	.p2align	2
__xtc_new_simd_i64:                     ; @_xtc_new_simd_i64
	.cfi_startproc
; %bb.0:
	mov	w1, #8                          ; =0x8
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_simd_double           ; -- Begin function _xtc_new_simd_double
	.p2align	2
__xtc_new_simd_double:                  ; @_xtc_new_simd_double
	.cfi_startproc
; %bb.0:
	mov	w1, #8                          ; =0x8
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_simd_pointer          ; -- Begin function _xtc_new_simd_pointer
	.p2align	2
__xtc_new_simd_pointer:                 ; @_xtc_new_simd_pointer
	.cfi_startproc
; %bb.0:
	mov	w1, #8                          ; =0x8
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_simd_string           ; -- Begin function _xtc_new_simd_string
	.p2align	2
__xtc_new_simd_string:                  ; @_xtc_new_simd_string
	.cfi_startproc
; %bb.0:
	mov	w1, #8                          ; =0x8
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_block_note                ; -- Begin function _xtc_block_note
	.p2align	2
__xtc_block_note:                       ; @_xtc_block_note
	.cfi_startproc
; %bb.0:
	stp	x22, x21, [sp, #-48]!           ; 16-byte Folded Spill
	stp	x20, x19, [sp, #16]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #32]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 48
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	mov	x19, x0
Lloh117:
	adrp	x20, _xt_btab@PAGE
Lloh118:
	add	x20, x20, _xt_btab@PAGEOFF
	ldar	x8, [x20]
	cbnz	x8, LBB41_6
; %bb.1:
	mov	w0, #1                          ; =0x1
	mov	w1, #524288                     ; =0x80000
	bl	_calloc
	cbz	x0, LBB41_5
; %bb.2:
	mov	x21, #0                         ; =0x0
	casal	x21, x0, [x20]
	mov	x8, x0
	cmp	x21, #0
	b.eq	LBB41_4
; %bb.3:
	mov	x20, x0
	bl	_free
	mov	x0, x20
	mov	x8, x21
LBB41_4:
	cbnz	x0, LBB41_6
	b	LBB41_10
LBB41_5:
	mov	x8, #0                          ; =0x0
	cbz	x0, LBB41_10
LBB41_6:
	mov	x9, #31765                      ; =0x7c15
	movk	x9, #32586, lsl #16
	movk	x9, #31161, lsl #32
	movk	x9, #40503, lsl #48
	ldp	x11, x10, [x19, #-40]
	mul	x10, x11, x10
	lsr	x12, x19, #16
	subs	x10, x10, #1
	csel	x10, xzr, x10, lo
	add	x10, x10, x19
	lsr	x13, x10, #16
	sub	x11, x13, x12
	cmp	x11, #1, lsl #12                ; =4096
	mul	x10, x12, x9
	lsr	x14, x10, #45
	and	x14, x14, #0x7fff8
	ldr	x14, [x8, x14]
	ccmp	x13, x12, #2, lo
	cset	w12, lo
	cmp	x14, x19
	b.eq	LBB41_10
; %bb.7:
	tbnz	w12, #0, LBB41_10
; %bb.8:
	mov	w12, #4095                      ; =0xfff
	cmp	x11, #4095
	csel	x11, x11, x12, lo
	mvn	x11, x11
LBB41_9:                                ; =>This Inner Loop Header: Depth=1
	lsr	x12, x10, #45
	and	x12, x12, #0x7fff8
	str	x19, [x8, x12]
	add	x10, x10, x9
	adds	x11, x11, #1
	b.lo	LBB41_9
LBB41_10:
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh117, Lloh118
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_block_find                ; -- Begin function _xtc_block_find
	.p2align	2
__xtc_block_find:                       ; @_xtc_block_find
	.cfi_startproc
; %bb.0:
Lloh119:
	adrp	x8, _xt_btab@PAGE
Lloh120:
	add	x8, x8, _xt_btab@PAGEOFF
	ldar	x8, [x8]
	cbz	x8, LBB42_3
; %bb.1:
	lsr	x9, x0, #16
	mov	x10, #31765                     ; =0x7c15
	movk	x10, #32586, lsl #16
	movk	x10, #31161, lsl #32
	movk	x10, #40503, lsl #48
	mul	x9, x9, x10
	lsr	x9, x9, #45
	and	x9, x9, #0x7fff8
	ldr	x8, [x8, x9]
	sub	x9, x8, #1
	cmp	x9, x0
	b.hs	LBB42_3
; %bb.2:
	ldp	x10, x9, [x8, #-40]
	mul	x9, x10, x9
	sub	x10, x0, x8
	cmp	x10, x9
	csel	x0, xzr, x8, hi
	ret
LBB42_3:
	mov	x0, #0                          ; =0x0
	ret
	.loh AdrpAdd	Lloh119, Lloh120
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_count                     ; -- Begin function _xtc_count
	.p2align	2
__xtc_count:                            ; @_xtc_count
	.cfi_startproc
; %bb.0:
	ldur	x0, [x0, #-32]
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_dealloc                   ; -- Begin function _xtc_dealloc
	.p2align	2
__xtc_dealloc:                          ; @_xtc_dealloc
	.cfi_startproc
; %bb.0:
	stp	x24, x23, [sp, #-64]!           ; 16-byte Folded Spill
	stp	x22, x21, [sp, #16]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #32]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #48]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 64
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	.cfi_offset w23, -56
	.cfi_offset w24, -64
	mov	x19, x0
	mov	w21, #20291                     ; =0x4f43
	movk	w21, #22612, lsl #16
	mov	x20, x0
	ldr	w8, [x20, #-8]!
	and	w9, w8, #0xfffffffe
	add	w10, w21, #11
	cmp	w9, w10
	b.ne	LBB44_5
; %bb.1:
	add	w9, w21, #12
	cmp	w8, w9
	b.ne	LBB44_3
; %bb.2:
	mov	x0, x19
	bl	__xtc_weak_zero_for
LBB44_3:
	ldr	x8, [x19]
	ldr	x8, [x8, #24]
	cbz	x8, LBB44_31
; %bb.4:
	mov	w9, #-2147483648                ; =0x80000000
	stur	w9, [x19, #-4]
	mov	x0, x19
	blr	x8
	b	LBB44_31
LBB44_5:
	mov	x0, x19
	bl	__xtc_weak_zero_for
Lloh121:
	adrp	x8, _xt_btab@PAGE
Lloh122:
	add	x8, x8, _xt_btab@PAGEOFF
	ldar	x8, [x8]
	cbz	x8, LBB44_10
; %bb.6:
	ldp	x10, x9, [x19, #-40]
	mul	x9, x10, x9
	lsr	x11, x19, #16
	subs	x9, x9, #1
	csel	x9, xzr, x9, lo
	add	x9, x9, x19
	lsr	x9, x9, #16
	subs	x10, x9, x11
	b.hs	LBB44_8
; %bb.7:
	cmp	x10, #1, lsl #12                ; =4096
	b.lo	LBB44_10
LBB44_8:
	mov	x9, #31765                      ; =0x7c15
	movk	x9, #32586, lsl #16
	movk	x9, #31161, lsl #32
	movk	x9, #40503, lsl #48
	mov	w12, #4095                      ; =0xfff
	cmp	x10, #4095
	csel	x10, x10, x12, lo
	mvn	x10, x10
	mul	x11, x11, x9
LBB44_9:                                ; =>This Inner Loop Header: Depth=1
	lsr	x12, x11, #48
	add	x12, x8, x12, lsl #3
	mov	x13, x19
	casal	x13, xzr, [x12]
	add	x11, x11, x9
	adds	x10, x10, #1
	b.lo	LBB44_9
LBB44_10:
	mov	x20, x19
	ldr	x23, [x20, #-40]!
	ldr	x22, [x20, #16]
	ldr	w8, [x20, #32]
	cmp	w8, w21
	b.ne	LBB44_28
; %bb.11:
	cbz	x22, LBB44_13
; %bb.12:
	mov	x0, x19
	blr	x22
LBB44_13:
	tst	x19, #0x3fff
	b.ne	LBB44_27
; %bb.14:
	mov	x0, x19
	bl	__xtc_simd_unwatch
	adrp	x20, __xt_threads_active@PAGE
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB44_16
; %bb.15:
Lloh123:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh124:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB44_16:
	adrp	x8, _xt_simd_n@PAGE
	ldr	x9, [x8, _xt_simd_n@PAGEOFF]
	adrp	x11, _xt_simd_tab@PAGE
	mov	x10, #0                         ; =0x0
	cbz	x9, LBB44_19
; %bb.17:
	ldr	x12, [x11, _xt_simd_tab@PAGEOFF]
	mov	x13, x9
LBB44_18:                               ; =>This Inner Loop Header: Depth=1
	add	x14, x13, x10
	lsr	x15, x14, #1
	and	x14, x14, #0x1ffffffffffffffe
	ldr	x14, [x12, x14, lsl #3]
	cmp	x14, x19
	csel	x13, x15, x13, hi
	csinc	x10, x10, x15, hi
	cmp	x10, x13
	b.lo	LBB44_18
LBB44_19:
	cbz	x10, LBB44_25
; %bb.20:
	ldr	x11, [x11, _xt_simd_tab@PAGEOFF]
	add	x11, x11, x10, lsl #4
	ldur	x12, [x11, #-16]
	cmp	x12, x19
	b.ne	LBB44_25
; %bb.21:
	subs	x12, x9, x10
	b.ls	LBB44_24
; %bb.22:
Lloh125:
	adrp	x13, _xt_simd_flag@PAGE
Lloh126:
	ldr	x13, [x13, _xt_simd_flag@PAGEOFF]
	add	x10, x13, x10
LBB44_23:                               ; =>This Inner Loop Header: Depth=1
	ldp	x13, x14, [x11]
	stp	x13, x14, [x11, #-16]
	ldrb	w13, [x10]
	sturb	w13, [x10, #-1]
	add	x10, x10, #1
	add	x11, x11, #16
	subs	x12, x12, #1
	b.ne	LBB44_23
LBB44_24:
	sub	x9, x9, #1
	str	x9, [x8, _xt_simd_n@PAGEOFF]
LBB44_25:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB44_27
; %bb.26:
Lloh127:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh128:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB44_27:
	ldur	x20, [x19, #-48]
	b	LBB44_31
LBB44_28:
	cbz	x22, LBB44_31
; %bb.29:
	ldr	x21, [x20, #8]
	mov	w8, #-2147483648                ; =0x80000000
	stur	w8, [x19, #-4]
	cbz	x21, LBB44_31
LBB44_30:                               ; =>This Inner Loop Header: Depth=1
	mov	x0, x19
	blr	x22
	add	x19, x19, x23
	subs	x21, x21, #1
	b.ne	LBB44_30
LBB44_31:
	mov	x0, x20
	ldp	x29, x30, [sp, #48]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #32]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #16]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp], #64             ; 16-byte Folded Reload
	b	_free
	.loh AdrpAdd	Lloh121, Lloh122
	.loh AdrpAdd	Lloh123, Lloh124
	.loh AdrpLdr	Lloh125, Lloh126
	.loh AdrpAdd	Lloh127, Lloh128
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_weak_zero_for             ; -- Begin function _xtc_weak_zero_for
	.p2align	2
__xtc_weak_zero_for:                    ; @_xtc_weak_zero_for
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB45_18
; %bb.1:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	x19, x0
	adrp	x20, __xt_threads_active@PAGE
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB45_3
; %bb.2:
Lloh129:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh130:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB45_3:
	mov	w8, #20290                      ; =0x4f42
	movk	w8, #22612, lsl #16
	ldur	w9, [x19, #-8]
	mov	w10, #13                        ; =0xd
	orr	w10, w8, w10
	cmp	w9, w10
	b.ne	LBB45_8
; %bb.4:
Lloh131:
	adrp	x8, _xt_wtab_cap@PAGE
Lloh132:
	ldr	x8, [x8, _xt_wtab_cap@PAGEOFF]
	cbz	x8, LBB45_12
; %bb.5:
	lsr	x9, x19, #3
	eor	x9, x9, x19, lsr #20
	mov	w10, #54459                     ; =0xd4bb
	movk	w10, #60762, lsl #16
	mul	x9, x9, x10
	eor	x9, x9, x9, lsr #11
	sub	x8, x8, #1
	and	x10, x8, x9
Lloh133:
	adrp	x9, _xt_wtab@PAGE
Lloh134:
	ldr	x11, [x9, _xt_wtab@PAGEOFF]
	mov	w12, #1                         ; =0x1
                                        ; implicit-def: $x9
LBB45_6:                                ; =>This Inner Loop Header: Depth=1
	add	x13, x11, x10, lsl #4
	ldr	x14, [x13]
	add	x15, x10, #1
	and	x15, x15, x8
	cmp	x14, #0
	csel	x15, x10, x15, eq
	csel	x9, xzr, x9, eq
	csel	w16, wzr, w12, eq
	cmp	x14, x19
	csel	x10, x10, x15, eq
	csel	x9, x13, x9, eq
	csel	w13, wzr, w16, eq
	tbnz	w13, #0, LBB45_6
; %bb.7:
	cbnz	x9, LBB45_13
	b	LBB45_16
LBB45_8:
	and	w9, w9, #0xfffffffe
	cmp	w9, w8
	b.ne	LBB45_16
; %bb.9:
	ldur	x8, [x19, #-16]
	cbz	x8, LBB45_11
LBB45_10:                               ; =>This Inner Loop Header: Depth=1
	ldur	x9, [x8, #-8]
	stp	xzr, xzr, [x8, #-8]
	stur	xzr, [x8, #-16]
	mov	x8, x9
	cbnz	x9, LBB45_10
LBB45_11:
	stur	xzr, [x19, #-16]
	b	LBB45_16
LBB45_12:
	mov	x9, #0                          ; =0x0
	cbz	x9, LBB45_16
LBB45_13:
	ldr	x8, [x9, #8]
	mov	w10, #1                         ; =0x1
	stp	x10, xzr, [x9]
	adrp	x9, _xt_wtab_n@PAGE
	ldr	x10, [x9, _xt_wtab_n@PAGEOFF]
	sub	x10, x10, #1
	str	x10, [x9, _xt_wtab_n@PAGEOFF]
	ldr	x9, [x8]
	cbz	x9, LBB45_15
LBB45_14:                               ; =>This Inner Loop Header: Depth=1
	ldur	x10, [x9, #-8]
	stp	xzr, xzr, [x9, #-8]
	stur	xzr, [x9, #-16]
	mov	x9, x10
	cbnz	x10, LBB45_14
LBB45_15:
	str	xzr, [x8]
	adrp	x9, _xt_wcell_free@PAGE
	ldr	x10, [x9, _xt_wcell_free@PAGEOFF]
	str	x10, [x8]
	str	x8, [x9, _xt_wcell_free@PAGEOFF]
LBB45_16:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	cbz	w8, LBB45_18
; %bb.17:
Lloh135:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh136:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	b	_pthread_mutex_unlock
LBB45_18:
	ret
	.loh AdrpAdd	Lloh129, Lloh130
	.loh AdrpLdr	Lloh131, Lloh132
	.loh AdrpLdr	Lloh133, Lloh134
	.loh AdrpAdd	Lloh135, Lloh136
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_weak_unregister           ; -- Begin function _xtc_weak_unregister
	.p2align	2
__xtc_weak_unregister:                  ; @_xtc_weak_unregister
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	x19, x0
	adrp	x20, __xt_threads_active@PAGE
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB46_2
; %bb.1:
Lloh137:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh138:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB46_2:
	mov	x8, x19
	ldr	x9, [x8, #-16]!
	cbz	x9, LBB46_7
; %bb.3:
	ldr	x10, [x9]
	cmp	x10, x19
	b.ne	LBB46_6
; %bb.4:
	ldur	x10, [x19, #-8]
	str	x10, [x9]
	cbz	x10, LBB46_6
; %bb.5:
	stur	x9, [x10, #-16]
LBB46_6:
	stp	xzr, xzr, [x8]
LBB46_7:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB46_9
; %bb.8:
Lloh139:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh140:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB46_9:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh137, Lloh138
	.loh AdrpAdd	Lloh139, Lloh140
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_weak_register             ; -- Begin function _xtc_weak_register
	.p2align	2
__xtc_weak_register:                    ; @_xtc_weak_register
	.cfi_startproc
; %bb.0:
	stp	x24, x23, [sp, #-64]!           ; 16-byte Folded Spill
	stp	x22, x21, [sp, #16]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #32]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #48]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 64
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	.cfi_offset w23, -56
	.cfi_offset w24, -64
	mov	x20, x1
	mov	x19, x0
	adrp	x22, __xt_threads_active@PAGE
	ldr	w8, [x22, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB47_2
; %bb.1:
Lloh141:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh142:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB47_2:
	mov	x8, x19
	ldr	x9, [x8, #-16]!
	cbz	x9, LBB47_7
; %bb.3:
	ldr	x10, [x9]
	cmp	x10, x19
	b.ne	LBB47_6
; %bb.4:
	ldur	x10, [x19, #-8]
	str	x10, [x9]
	cbz	x10, LBB47_6
; %bb.5:
	stur	x9, [x10, #-16]
LBB47_6:
	stp	xzr, xzr, [x8]
LBB47_7:
	cbz	x20, LBB47_10
; %bb.8:
	ldur	w9, [x20, #-8]
	and	w8, w9, #0xfffffffe
	mov	w10, #20302                     ; =0x4f4e
	movk	w10, #22612, lsl #16
	cmp	w8, w10
	b.eq	LBB47_11
; %bb.9:
	mov	w9, #20290                      ; =0x4f42
	movk	w9, #22612, lsl #16
	sub	x10, x20, #16
	cmp	w8, w9
	csel	x21, xzr, x10, ne
	cbnz	x21, LBB47_25
	b	LBB47_28
LBB47_10:
	mov	x21, #0                         ; =0x0
	cbnz	x21, LBB47_25
	b	LBB47_28
LBB47_11:
	mov	w23, #20303                     ; =0x4f4f
	movk	w23, #22612, lsl #16
	cmp	w9, w23
	b.ne	LBB47_15
; %bb.12:
Lloh143:
	adrp	x8, _xt_wtab_cap@PAGE
Lloh144:
	ldr	x8, [x8, _xt_wtab_cap@PAGEOFF]
	cbz	x8, LBB47_18
; %bb.13:
	lsr	x9, x20, #3
	eor	x9, x9, x20, lsr #20
	mov	w10, #54459                     ; =0xd4bb
	movk	w10, #60762, lsl #16
	mul	x9, x9, x10
	eor	x9, x9, x9, lsr #11
	sub	x8, x8, #1
	and	x9, x8, x9
Lloh145:
	adrp	x10, _xt_wtab@PAGE
Lloh146:
	ldr	x10, [x10, _xt_wtab@PAGEOFF]
	mov	w12, #1                         ; =0x1
                                        ; implicit-def: $x11
LBB47_14:                               ; =>This Inner Loop Header: Depth=1
	add	x13, x10, x9, lsl #4
	ldr	x14, [x13]
	add	x15, x9, #1
	and	x15, x15, x8
	cmp	x14, #0
	csel	x15, x9, x15, eq
	csel	x11, xzr, x11, eq
	csel	w16, wzr, w12, eq
	cmp	x14, x20
	csel	x9, x9, x15, eq
	csel	x11, x13, x11, eq
	csel	w13, wzr, w16, eq
	tbnz	w13, #0, LBB47_14
	b	LBB47_16
LBB47_15:
	mov	x11, #0                         ; =0x0
LBB47_16:
	cbz	x11, LBB47_19
LBB47_17:
	ldr	x21, [x11, #8]
	cbnz	x21, LBB47_25
	b	LBB47_28
LBB47_18:
	mov	x11, #0                         ; =0x0
	cbnz	x11, LBB47_17
LBB47_19:
	adrp	x24, _xt_wcell_free@PAGE
	ldr	x8, [x24, _xt_wcell_free@PAGEOFF]
	cbnz	x8, LBB47_24
; %bb.20:
	mov	w0, #512                        ; =0x200
	mov	w1, #8                          ; =0x8
	bl	_calloc
	cbz	x0, LBB47_31
; %bb.21:
	mov	x8, #0                          ; =0x0
LBB47_22:                               ; =>This Inner Loop Header: Depth=1
	add	x9, x0, x8
	add	x10, x9, #8
	str	x10, [x9]
	add	x8, x8, #8
	cmp	x8, #4088
	b.ne	LBB47_22
; %bb.23:
	str	xzr, [x0, #4088]
	str	x0, [x24, _xt_wcell_free@PAGEOFF]
LBB47_24:
	ldr	x21, [x24, _xt_wcell_free@PAGEOFF]
	ldr	x8, [x21]
	str	x8, [x24, _xt_wcell_free@PAGEOFF]
	str	xzr, [x21]
	mov	x0, x20
	mov	x1, x21
	bl	_xt_wtab_put
	stur	w23, [x20, #-8]
	cbz	x21, LBB47_28
LBB47_25:
	ldr	x8, [x21]
	mov	x9, x19
	str	x8, [x9, #-8]!
	stur	x21, [x9, #-8]
	cbz	x8, LBB47_27
; %bb.26:
	stur	x9, [x8, #-16]
LBB47_27:
	str	x19, [x21]
LBB47_28:
	ldr	w8, [x22, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB47_30
; %bb.29:
Lloh147:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh148:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #48]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #32]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #16]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp], #64             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB47_30:
	ldp	x29, x30, [sp, #48]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #32]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #16]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp], #64             ; 16-byte Folded Reload
	ret
LBB47_31:
	bl	__xtc_weak_register.cold.1
	.loh AdrpAdd	Lloh141, Lloh142
	.loh AdrpLdr	Lloh143, Lloh144
	.loh AdrpLdr	Lloh145, Lloh146
	.loh AdrpAdd	Lloh147, Lloh148
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_weak_load                 ; -- Begin function _xtc_weak_load
	.p2align	2
__xtc_weak_load:                        ; @_xtc_weak_load
	.cfi_startproc
; %bb.0:
	ldr	x0, [x0]
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__putc                          ; -- Begin function _putc
	.p2align	2
__putc:                                 ; @_putc
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	strb	w0, [sp, #15]
	add	x1, sp, #15
	mov	w0, #1                          ; =0x1
	mov	w2, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #32
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_pf                        ; -- Begin function _xtc_pf
	.p2align	2
__xtc_pf:                               ; @_xtc_pf
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #112
	stp	x20, x19, [sp, #80]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #96]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 112
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	fcvt	d0, s0
	str	d0, [sp]
Lloh149:
	adrp	x2, l_.str.2@PAGE
Lloh150:
	add	x2, x2, l_.str.2@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB50_1:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB50_1
; %bb.2:
	sub	x2, x8, #1
	add	x1, sp, #16
	mov	w0, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.loh AdrpAdd	Lloh149, Lloh150
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_pd                        ; -- Begin function _xtc_pd
	.p2align	2
__xtc_pd:                               ; @_xtc_pd
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #112
	stp	x20, x19, [sp, #80]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #96]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 112
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	str	d0, [sp]
Lloh151:
	adrp	x2, l_.str.3@PAGE
Lloh152:
	add	x2, x2, l_.str.3@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB51_1:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB51_1
; %bb.2:
	sub	x2, x8, #1
	add	x1, sp, #16
	mov	w0, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.loh AdrpAdd	Lloh151, Lloh152
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_pfp                       ; -- Begin function _xtc_pfp
	.p2align	2
__xtc_pfp:                              ; @_xtc_pfp
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #112
	stp	x20, x19, [sp, #80]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #96]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 112
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	fcvt	d0, s0
	cbz	w0, LBB52_7
; %bb.1:
	add	w8, w0, #1
	str	d0, [sp, #8]
	str	x8, [sp]
Lloh153:
	adrp	x2, l_.str.9@PAGE
Lloh154:
	add	x2, x2, l_.str.9@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB52_2:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB52_2
; %bb.3:
	cmp	x8, #1
	b.eq	LBB52_5
; %bb.4:
	add	x9, sp, #16
	add	x8, x9, x8
	sturb	wzr, [x8, #-2]
LBB52_5:
	mov	x8, #0                          ; =0x0
	add	x9, sp, #16
LBB52_6:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w10, [x9, x8]
	add	x8, x8, #1
	cbnz	w10, LBB52_6
	b	LBB52_9
LBB52_7:
	str	d0, [sp]
Lloh155:
	adrp	x2, l_.str.2@PAGE
Lloh156:
	add	x2, x2, l_.str.2@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB52_8:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB52_8
LBB52_9:
	sub	x2, x8, #1
	add	x1, sp, #16
	mov	w0, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.loh AdrpAdd	Lloh153, Lloh154
	.loh AdrpAdd	Lloh155, Lloh156
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_pdp                       ; -- Begin function _xtc_pdp
	.p2align	2
__xtc_pdp:                              ; @_xtc_pdp
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #112
	stp	x20, x19, [sp, #80]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #96]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 112
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	cbz	w0, LBB53_7
; %bb.1:
	add	w8, w0, #1
	str	d0, [sp, #8]
	str	x8, [sp]
Lloh157:
	adrp	x2, l_.str.9@PAGE
Lloh158:
	add	x2, x2, l_.str.9@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB53_2:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB53_2
; %bb.3:
	cmp	x8, #1
	b.eq	LBB53_5
; %bb.4:
	add	x9, sp, #16
	add	x8, x9, x8
	sturb	wzr, [x8, #-2]
LBB53_5:
	mov	x8, #0                          ; =0x0
	add	x9, sp, #16
LBB53_6:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w10, [x9, x8]
	add	x8, x8, #1
	cbnz	w10, LBB53_6
	b	LBB53_9
LBB53_7:
	str	d0, [sp]
Lloh159:
	adrp	x2, l_.str.3@PAGE
Lloh160:
	add	x2, x2, l_.str.3@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB53_8:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB53_8
LBB53_9:
	sub	x2, x8, #1
	add	x1, sp, #16
	mov	w0, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.loh AdrpAdd	Lloh157, Lloh158
	.loh AdrpAdd	Lloh159, Lloh160
	.cfi_endproc
                                        ; -- End function
	.globl	__xm_sqrtf                      ; -- Begin function _xm_sqrtf
	.p2align	2
__xm_sqrtf:                             ; @_xm_sqrtf
	.cfi_startproc
; %bb.0:
	fsqrt	s0, s0
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xm_sqrt                       ; -- Begin function _xm_sqrt
	.p2align	2
__xm_sqrt:                              ; @_xm_sqrt
	.cfi_startproc
; %bb.0:
	fsqrt	d0, d0
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xm_sinf                       ; -- Begin function _xm_sinf
	.p2align	2
__xm_sinf:                              ; @_xm_sinf
	.cfi_startproc
; %bb.0:
	b	_sinf
	.cfi_endproc
                                        ; -- End function
	.globl	__xm_sin                        ; -- Begin function _xm_sin
	.p2align	2
__xm_sin:                               ; @_xm_sin
	.cfi_startproc
; %bb.0:
	b	_sin
	.cfi_endproc
                                        ; -- End function
	.globl	__xm_cosf                       ; -- Begin function _xm_cosf
	.p2align	2
__xm_cosf:                              ; @_xm_cosf
	.cfi_startproc
; %bb.0:
	b	_cosf
	.cfi_endproc
                                        ; -- End function
	.globl	__xm_cos                        ; -- Begin function _xm_cos
	.p2align	2
__xm_cos:                               ; @_xm_cos
	.cfi_startproc
; %bb.0:
	b	_cos
	.cfi_endproc
                                        ; -- End function
	.globl	__xm_tanf                       ; -- Begin function _xm_tanf
	.p2align	2
__xm_tanf:                              ; @_xm_tanf
	.cfi_startproc
; %bb.0:
	b	_tanf
	.cfi_endproc
                                        ; -- End function
	.globl	__xm_tan                        ; -- Begin function _xm_tan
	.p2align	2
__xm_tan:                               ; @_xm_tan
	.cfi_startproc
; %bb.0:
	b	_tan
	.cfi_endproc
                                        ; -- End function
	.globl	__xm_atanf                      ; -- Begin function _xm_atanf
	.p2align	2
__xm_atanf:                             ; @_xm_atanf
	.cfi_startproc
; %bb.0:
	b	_atanf
	.cfi_endproc
                                        ; -- End function
	.globl	__xm_atan                       ; -- Begin function _xm_atan
	.p2align	2
__xm_atan:                              ; @_xm_atan
	.cfi_startproc
; %bb.0:
	b	_atan
	.cfi_endproc
                                        ; -- End function
	.globl	__xm_lnf                        ; -- Begin function _xm_lnf
	.p2align	2
__xm_lnf:                               ; @_xm_lnf
	.cfi_startproc
; %bb.0:
	b	_logf
	.cfi_endproc
                                        ; -- End function
	.globl	__xm_ln                         ; -- Begin function _xm_ln
	.p2align	2
__xm_ln:                                ; @_xm_ln
	.cfi_startproc
; %bb.0:
	b	_log
	.cfi_endproc
                                        ; -- End function
	.globl	__xm_expf                       ; -- Begin function _xm_expf
	.p2align	2
__xm_expf:                              ; @_xm_expf
	.cfi_startproc
; %bb.0:
	b	_expf
	.cfi_endproc
                                        ; -- End function
	.globl	__xm_exp                        ; -- Begin function _xm_exp
	.p2align	2
__xm_exp:                               ; @_xm_exp
	.cfi_startproc
; %bb.0:
	b	_exp
	.cfi_endproc
                                        ; -- End function
	.globl	__xm_powf                       ; -- Begin function _xm_powf
	.p2align	2
__xm_powf:                              ; @_xm_powf
	.cfi_startproc
; %bb.0:
	b	_powf
	.cfi_endproc
                                        ; -- End function
	.globl	__xm_pow                        ; -- Begin function _xm_pow
	.p2align	2
__xm_pow:                               ; @_xm_pow
	.cfi_startproc
; %bb.0:
	b	_pow
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_srand                      ; -- Begin function _xt_srand
	.p2align	2
__xt_srand:                             ; @_xt_srand
	.cfi_startproc
; %bb.0:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	.cfi_def_cfa_offset 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	bl	_srandom
	mov	w8, #1                          ; =0x1
	adrp	x9, _xt_rand_seeded@PAGE
	strb	w8, [x9, _xt_rand_seeded@PAGEOFF]
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_rand_u32                   ; -- Begin function _xt_rand_u32
	.p2align	2
__xt_rand_u32:                          ; @_xt_rand_u32
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	adrp	x19, _xt_rand_seeded@PAGE
	ldrb	w8, [x19, _xt_rand_seeded@PAGEOFF]
	tbnz	w8, #0, LBB71_2
; %bb.1:
	mov	w20, #1                         ; =0x1
	mov	w0, #1                          ; =0x1
	bl	_srandom
	strb	w20, [x19, _xt_rand_seeded@PAGEOFF]
LBB71_2:
	bl	_random
	mov	x19, x0
	bl	_random
	eor	w0, w0, w19, lsl #16
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_rand_f                     ; -- Begin function _xt_rand_f
	.p2align	2
__xt_rand_f:                            ; @_xt_rand_f
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	adrp	x19, _xt_rand_seeded@PAGE
	ldrb	w8, [x19, _xt_rand_seeded@PAGEOFF]
	tbnz	w8, #0, LBB72_2
; %bb.1:
	mov	w20, #1                         ; =0x1
	mov	w0, #1                          ; =0x1
	bl	_srandom
	strb	w20, [x19, _xt_rand_seeded@PAGEOFF]
LBB72_2:
	bl	_random
	scvtf	s0, x0, #31
	fmov	s1, #0.50000000
	fmadd	s0, s0, s1, s1
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_rand_d                     ; -- Begin function _xt_rand_d
	.p2align	2
__xt_rand_d:                            ; @_xt_rand_d
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	adrp	x19, _xt_rand_seeded@PAGE
	ldrb	w8, [x19, _xt_rand_seeded@PAGEOFF]
	tbnz	w8, #0, LBB73_2
; %bb.1:
	mov	w20, #1                         ; =0x1
	mov	w0, #1                          ; =0x1
	bl	_srandom
	strb	w20, [x19, _xt_rand_seeded@PAGEOFF]
LBB73_2:
	bl	_random
	scvtf	d0, x0, #31
	fmov	d1, #0.50000000
	fmadd	d0, d0, d1, d1
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_clk_reset                  ; -- Begin function _xt_clk_reset
	.p2align	2
__xt_clk_reset:                         ; @_xt_clk_reset
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	mov	x1, sp
	mov	w0, #6                          ; =0x6
	bl	_clock_gettime
	ldp	d0, d1, [sp]
	scvtf	d0, d0
	scvtf	d1, d1
	mov	x8, #54933                      ; =0xd695
	movk	x8, #59430, lsl #16
	movk	x8, #11787, lsl #32
	movk	x8, #15889, lsl #48
	fmov	d2, x8
	fmadd	d0, d1, d2, d0
	adrp	x8, _xt_clk_origin@PAGE
	str	d0, [x8, _xt_clk_origin@PAGEOFF]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #32
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_clk_ticks                  ; -- Begin function _xt_clk_ticks
	.p2align	2
__xt_clk_ticks:                         ; @_xt_clk_ticks
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	mov	x1, sp
	mov	w0, #6                          ; =0x6
	bl	_clock_gettime
	ldp	d0, d1, [sp]
	scvtf	d0, d0
	scvtf	d1, d1
	mov	x8, #54933                      ; =0xd695
	movk	x8, #59430, lsl #16
	movk	x8, #11787, lsl #32
	movk	x8, #15889, lsl #48
	fmov	d2, x8
	fmadd	d0, d1, d2, d0
Lloh161:
	adrp	x8, _xt_clk_origin@PAGE
Lloh162:
	ldr	d1, [x8, _xt_clk_origin@PAGEOFF]
	fsub	d0, d0, d1
	mov	x8, #145685290680320            ; =0x848000000000
	movk	x8, #16686, lsl #48
	fmov	d1, x8
	fmul	d0, d0, d1
	fcvtzu	w0, d0
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #32
	ret
	.loh AdrpLdr	Lloh161, Lloh162
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_clk_delay                  ; -- Begin function _xt_clk_delay
	.p2align	2
__xt_clk_delay:                         ; @_xt_clk_delay
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	ucvtf	d0, w0
	mov	x8, #4633641066610819072        ; =0x404e000000000000
	fmov	d1, x8
	fdiv	d0, d0, d1
	fcvtzs	x8, d0
	fcvtzs	d1, d0
	scvtf	d1, d1
	fsub	d0, d0, d1
	mov	x9, #225833675390976            ; =0xcd6500000000
	movk	x9, #16845, lsl #48
	fmov	d1, x9
	fmul	d0, d0, d1
	fcvtzs	x9, d0
	stp	x8, x9, [sp]
	mov	x0, sp
	mov	x1, #0                          ; =0x0
	bl	_nanosleep
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #32
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_bank                      ; -- Begin function _xtc_bank
	.p2align	2
__xtc_bank:                             ; @_xtc_bank
	.cfi_startproc
; %bb.0:
	cmp	w0, #1
	b.ls	LBB77_2
; %bb.1:
	mov	x0, #0                          ; =0x0
	ret
LBB77_2:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	w8, w0
Lloh163:
	adrp	x9, __xtc_bank_regions@PAGE
Lloh164:
	add	x9, x9, __xtc_bank_regions@PAGEOFF
	add	x19, x9, x8, lsl #11
	ldr	x8, [x19, w1, uxtw #3]
	cbnz	x8, LBB77_4
; %bb.3:
	mov	w0, #1                          ; =0x1
	mov	x20, x1
	mov	w1, #12288                      ; =0x3000
	bl	_calloc
	mov	x1, x20
	str	x0, [x19, w20, uxtw #3]
LBB77_4:
	ldr	x0, [x19, w1, uxtw #3]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh163, Lloh164
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_open                  ; -- Begin function _xt_file_open
	.p2align	2
__xt_file_open:                         ; @_xt_file_open
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	x19, #0                         ; =0x0
Lloh165:
	adrp	x20, _xt_files@PAGE
Lloh166:
	add	x20, x20, _xt_files@PAGEOFF
LBB78_1:                                ; =>This Inner Loop Header: Depth=1
	ldr	x8, [x20, x19, lsl #3]
	cbz	x8, LBB78_3
; %bb.2:                                ;   in Loop: Header=BB78_1 Depth=1
	add	x19, x19, #1
	cmp	x19, #8
	b.ne	LBB78_1
	b	LBB78_5
LBB78_3:
	bl	_fopen
	cbz	x0, LBB78_5
; %bb.4:
	str	x0, [x20, x19, lsl #3]
	b	LBB78_6
LBB78_5:
	mov	w19, #-1                        ; =0xffffffff
LBB78_6:
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh165, Lloh166
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_read                  ; -- Begin function _xt_file_read
	.p2align	2
__xt_file_read:                         ; @_xt_file_read
	.cfi_startproc
; %bb.0:
	cmp	w0, #7
	b.hi	LBB79_3
; %bb.1:
Lloh167:
	adrp	x8, _xt_files@PAGE
Lloh168:
	add	x8, x8, _xt_files@PAGEOFF
	ldr	x3, [x8, w0, uxtw #3]
	cbz	x3, LBB79_3
; %bb.2:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	.cfi_def_cfa_offset 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	mov	w2, w2
	mov	x0, x1
	mov	w1, #1                          ; =0x1
	bl	_fread
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
                                        ; kill: def $w0 killed $w0 killed $x0
	ret
LBB79_3:
	mov	w0, #-1                         ; =0xffffffff
                                        ; kill: def $w0 killed $w0 killed $x0
	ret
	.loh AdrpAdd	Lloh167, Lloh168
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_write                 ; -- Begin function _xt_file_write
	.p2align	2
__xt_file_write:                        ; @_xt_file_write
	.cfi_startproc
; %bb.0:
	cmp	w0, #7
	b.hi	LBB80_3
; %bb.1:
Lloh169:
	adrp	x8, _xt_files@PAGE
Lloh170:
	add	x8, x8, _xt_files@PAGEOFF
	ldr	x3, [x8, w0, uxtw #3]
	cbz	x3, LBB80_3
; %bb.2:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	.cfi_def_cfa_offset 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	mov	w2, w2
	mov	x0, x1
	mov	w1, #1                          ; =0x1
	bl	_fwrite
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
                                        ; kill: def $w0 killed $w0 killed $x0
	ret
LBB80_3:
	mov	w0, #-1                         ; =0xffffffff
                                        ; kill: def $w0 killed $w0 killed $x0
	ret
	.loh AdrpAdd	Lloh169, Lloh170
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_close                 ; -- Begin function _xt_file_close
	.p2align	2
__xt_file_close:                        ; @_xt_file_close
	.cfi_startproc
; %bb.0:
	cmp	w0, #7
	b.hi	LBB81_4
; %bb.1:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
Lloh171:
	adrp	x19, _xt_files@PAGE
Lloh172:
	add	x19, x19, _xt_files@PAGEOFF
	ldr	x8, [x19, w0, uxtw #3]
	cbz	x8, LBB81_3
; %bb.2:
	mov	x20, x0
	mov	x0, x8
	bl	_fclose
	str	xzr, [x19, w20, uxtw #3]
LBB81_3:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
LBB81_4:
	ret
	.loh AdrpAdd	Lloh171, Lloh172
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_size                  ; -- Begin function _xt_file_size
	.p2align	2
__xt_file_size:                         ; @_xt_file_size
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
Lloh173:
	adrp	x1, l_.str.4@PAGE
Lloh174:
	add	x1, x1, l_.str.4@PAGEOFF
	bl	_fopen
	cbz	x0, LBB82_3
; %bb.1:
	mov	x19, x0
	mov	x1, #0                          ; =0x0
	mov	w2, #2                          ; =0x2
	bl	_fseek
	cbz	w0, LBB82_4
; %bb.2:
	mov	x0, x19
	bl	_fclose
LBB82_3:
	mov	w0, #-1                         ; =0xffffffff
	b	LBB82_5
LBB82_4:
	mov	x0, x19
	bl	_ftell
	mov	x20, x0
	mov	x0, x19
	bl	_fclose
	cmp	x20, #0
	csinv	w0, w20, wzr, ge
LBB82_5:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh173, Lloh174
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_exists                ; -- Begin function _xt_file_exists
	.p2align	2
__xt_file_exists:                       ; @_xt_file_exists
	.cfi_startproc
; %bb.0:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	.cfi_def_cfa_offset 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh175:
	adrp	x1, l_.str.4@PAGE
Lloh176:
	add	x1, x1, l_.str.4@PAGEOFF
	bl	_fopen
	cbz	x0, LBB83_2
; %bb.1:
	bl	_fclose
	mov	w0, #1                          ; =0x1
LBB83_2:
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh175, Lloh176
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_getenv                     ; -- Begin function _xt_getenv
	.p2align	2
__xt_getenv:                            ; @_xt_getenv
	.cfi_startproc
; %bb.0:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	.cfi_def_cfa_offset 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	bl	_getenv
Lloh177:
	adrp	x8, l_.str.5@PAGE
Lloh178:
	add	x8, x8, l_.str.5@PAGEOFF
	cmp	x0, #0
	csel	x0, x8, x0, eq
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh177, Lloh178
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_mkdir                      ; -- Begin function _xt_mkdir
	.p2align	2
__xt_mkdir:                             ; @_xt_mkdir
	.cfi_startproc
; %bb.0:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	.cfi_def_cfa_offset 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	mov	w1, #448                        ; =0x1c0
	bl	_mkdir
	cbz	w0, LBB85_2
; %bb.1:
	bl	___error
	ldr	w8, [x0]
	cmp	w8, #17
	cset	w0, eq
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
LBB85_2:
	mov	w0, #1                          ; =0x1
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_chmod_exec            ; -- Begin function _xt_file_chmod_exec
	.p2align	2
__xt_file_chmod_exec:                   ; @_xt_file_chmod_exec
	.cfi_startproc
; %bb.0:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	.cfi_def_cfa_offset 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	mov	w1, #493                        ; =0x1ed
	bl	_chmod
	cmp	w0, #0
	cset	w0, eq
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_stack_guard_init           ; -- Begin function _xt_stack_guard_init
	.p2align	2
__xt_stack_guard_init:                  ; @_xt_stack_guard_init
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	str	xzr, [sp, #8]
	add	x0, sp, #8
	mov	w1, #8                          ; =0x8
	bl	_arc4random_buf
	ldr	x8, [sp, #8]
	ands	x8, x8, #0xffffffffffffff00
	mov	x9, #1392508928                 ; =0x53000000
	movk	x9, #17227, lsl #32
	movk	x9, #22612, lsl #48
	csel	x8, x9, x8, eq
	adrp	x9, ___xt_stack_guard@PAGE
	str	x8, [x9, ___xt_stack_guard@PAGEOFF]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #32
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	___xt_stack_fail                ; -- Begin function __xt_stack_fail
	.p2align	2
___xt_stack_fail:                       ; @__xt_stack_fail
	.cfi_startproc
; %bb.0:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	.cfi_def_cfa_offset 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh179:
	adrp	x8, ___stderrp@GOTPAGE
Lloh180:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh181:
	ldr	x3, [x8]
Lloh182:
	adrp	x0, l_.str.6@PAGE
Lloh183:
	add	x0, x0, l_.str.6@PAGEOFF
	mov	w1, #70                         ; =0x46
	mov	w2, #1                          ; =0x1
	bl	_fwrite
	bl	_abort
	.loh AdrpAdd	Lloh182, Lloh183
	.loh AdrpLdrGotLdr	Lloh179, Lloh180, Lloh181
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_set_args                   ; -- Begin function _xt_set_args
	.p2align	2
__xt_set_args:                          ; @_xt_set_args
	.cfi_startproc
; %bb.0:
Lloh184:
	adrp	x8, _xt_argc_v@PAGE
	str	w0, [x8, _xt_argc_v@PAGEOFF]
Lloh185:
	adrp	x8, _xt_argv_v@PAGE
	str	x1, [x8, _xt_argv_v@PAGEOFF]
	ret
	.loh AdrpAdrp	Lloh184, Lloh185
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_argc                       ; -- Begin function _xt_argc
	.p2align	2
__xt_argc:                              ; @_xt_argc
	.cfi_startproc
; %bb.0:
Lloh186:
	adrp	x8, _xt_argc_v@PAGE
Lloh187:
	ldr	w0, [x8, _xt_argc_v@PAGEOFF]
	ret
	.loh AdrpLdr	Lloh186, Lloh187
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_argv                       ; -- Begin function _xt_argv
	.p2align	2
__xt_argv:                              ; @_xt_argv
	.cfi_startproc
; %bb.0:
	tbnz	w0, #31, LBB91_2
; %bb.1:
Lloh188:
	adrp	x8, _xt_argc_v@PAGE
Lloh189:
	ldr	w9, [x8, _xt_argc_v@PAGEOFF]
Lloh190:
	adrp	x8, _xt_argv_v@PAGE
Lloh191:
	ldr	x8, [x8, _xt_argv_v@PAGEOFF]
	cmp	w9, w0
	ccmp	x8, #0, #4, gt
	b.ne	LBB91_3
LBB91_2:
Lloh192:
	adrp	x0, l_.str.5@PAGE
Lloh193:
	add	x0, x0, l_.str.5@PAGEOFF
	ret
LBB91_3:
	ldr	x0, [x8, w0, uxtw #3]
	ret
	.loh AdrpLdr	Lloh190, Lloh191
	.loh AdrpAdrp	Lloh188, Lloh190
	.loh AdrpLdr	Lloh188, Lloh189
	.loh AdrpAdd	Lloh192, Lloh193
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_exit                       ; -- Begin function _xt_exit
	.p2align	2
__xt_exit:                              ; @_xt_exit
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	x19, x0
	mov	x0, #0                          ; =0x0
	bl	_fflush
	mov	x0, x19
	bl	__exit
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_exists_exact          ; -- Begin function _xt_file_exists_exact
	.p2align	2
__xt_file_exists_exact:                 ; @_xt_file_exists_exact
	.cfi_startproc
; %bb.0:
	stp	x24, x23, [sp, #-64]!           ; 16-byte Folded Spill
	stp	x22, x21, [sp, #16]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #32]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #48]             ; 16-byte Folded Spill
	sub	sp, sp, #1024
	.cfi_def_cfa_offset 1088
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	.cfi_offset w23, -56
	.cfi_offset w24, -64
	mov	x20, x0
	mov	w1, #47                         ; =0x2f
	bl	_strrchr
	cmp	x0, #0
	csinc	x19, x20, x0, eq
	cbz	x0, LBB93_4
; %bb.1:
	sub	x21, x0, x20
	cmp	x21, #1023
	b.hi	LBB93_11
; %bb.2:
	mov	x22, sp
	mov	x23, x0
	mov	x0, sp
	mov	x1, x20
	mov	x2, x21
	mov	w3, #1024                       ; =0x400
	bl	___memcpy_chk
	strb	wzr, [x22, x21]
	cmp	x23, x20
	b.ne	LBB93_6
; %bb.3:
	mov	w8, #47                         ; =0x2f
	b	LBB93_5
LBB93_4:
	mov	w8, #46                         ; =0x2e
LBB93_5:
	strb	w8, [sp]
	strb	wzr, [sp, #1]
LBB93_6:
	mov	x0, sp
	bl	_opendir
	cbz	x0, LBB93_11
; %bb.7:
	mov	x20, x0
LBB93_8:                                ; =>This Inner Loop Header: Depth=1
	mov	x0, x20
	bl	_readdir
	cbz	x0, LBB93_12
; %bb.9:                                ;   in Loop: Header=BB93_8 Depth=1
	add	x0, x0, #21
	mov	x1, x19
	bl	_strcmp
	cbnz	w0, LBB93_8
; %bb.10:
	mov	w19, #1                         ; =0x1
	b	LBB93_13
LBB93_11:
	mov	w19, #0                         ; =0x0
	b	LBB93_14
LBB93_12:
	mov	w19, #0                         ; =0x0
LBB93_13:
	mov	x0, x20
	bl	_closedir
LBB93_14:
	mov	x0, x19
	add	sp, sp, #1024
	ldp	x29, x30, [sp, #48]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #32]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #16]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp], #64             ; 16-byte Folded Reload
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_threads_multi              ; -- Begin function _xt_threads_multi
	.p2align	2
__xt_threads_multi:                     ; @_xt_threads_multi
	.cfi_startproc
; %bb.0:
Lloh194:
	adrp	x8, __xt_threads_active@PAGE
Lloh195:
	ldr	w0, [x8, __xt_threads_active@PAGEOFF]
	ret
	.loh AdrpLdr	Lloh194, Lloh195
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_thread_create              ; -- Begin function _xt_thread_create
	.p2align	2
__xt_thread_create:                     ; @_xt_thread_create
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB95_11
; %bb.1:
	stp	x22, x21, [sp, #-48]!           ; 16-byte Folded Spill
	stp	x20, x19, [sp, #16]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #32]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 48
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	mov	x20, x1
	mov	x21, x0
	adrp	x19, __xt_threads_active@PAGE
	ldr	w8, [x19, __xt_threads_active@PAGEOFF]
	cbnz	w8, LBB95_3
; %bb.2:
Lloh196:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh197:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	mov	x1, #0                          ; =0x0
	bl	_pthread_mutex_init
	mov	w8, #1                          ; =0x1
	str	w8, [x19, __xt_threads_active@PAGEOFF]
LBB95_3:
	mov	w0, #16                         ; =0x10
	bl	_malloc
	cbz	x0, LBB95_10
; %bb.4:
	mov	x19, x0
	stp	x21, x20, [x0]
	mov	w0, #8                          ; =0x8
	bl	_malloc
	cbz	x0, LBB95_7
; %bb.5:
Lloh198:
	adrp	x2, _xt_thread_entry@PAGE
Lloh199:
	add	x2, x2, _xt_thread_entry@PAGEOFF
	mov	x20, x0
	mov	x1, #0                          ; =0x0
	mov	x3, x19
	bl	_pthread_create
	cbz	w0, LBB95_9
; %bb.6:
	mov	x0, x19
	bl	_free
	mov	x0, x20
	b	LBB95_8
LBB95_7:
	mov	x0, x19
LBB95_8:
	bl	_free
	mov	x0, #0                          ; =0x0
	b	LBB95_10
LBB95_9:
	mov	x0, x20
LBB95_10:
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
LBB95_11:
	ret
	.loh AdrpAdd	Lloh196, Lloh197
	.loh AdrpAdd	Lloh198, Lloh199
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function xt_thread_entry
_xt_thread_entry:                       ; @xt_thread_entry
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	ldp	x20, x19, [x0]
	bl	_free
	cbz	x20, LBB96_2
; %bb.1:
	mov	x0, x19
	blr	x20
LBB96_2:
	mov	x0, #0                          ; =0x0
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_thread_join                ; -- Begin function _xt_thread_join
	.p2align	2
__xt_thread_join:                       ; @_xt_thread_join
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB97_2
; %bb.1:
	sub	sp, sp, #48
	stp	x20, x19, [sp, #16]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #32]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 48
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	str	xzr, [sp, #8]
	ldr	x8, [x0]
	add	x1, sp, #8
	mov	x19, x0
	mov	x0, x8
	bl	_pthread_join
	mov	x20, x0
	mov	x0, x19
	bl	_free
	cmp	w20, #0
	csetm	w0, ne
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #48
	ret
LBB97_2:
	mov	w0, #-1                         ; =0xffffffff
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_thread_detach              ; -- Begin function _xt_thread_detach
	.p2align	2
__xt_thread_detach:                     ; @_xt_thread_detach
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB98_2
; %bb.1:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	ldr	x8, [x0]
	mov	x19, x0
	mov	x0, x8
	bl	_pthread_detach
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_free
LBB98_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_thread_yield               ; -- Begin function _xt_thread_yield
	.p2align	2
__xt_thread_yield:                      ; @_xt_thread_yield
	.cfi_startproc
; %bb.0:
	b	_sched_yield
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_thread_sleep_ms            ; -- Begin function _xt_thread_sleep_ms
	.p2align	2
__xt_thread_sleep_ms:                   ; @_xt_thread_sleep_ms
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	mov	w8, #19923                      ; =0x4dd3
	movk	w8, #4194, lsl #16
	umull	x8, w0, w8
	lsr	x8, x8, #38
	mov	w9, #1000                       ; =0x3e8
	msub	w9, w8, w9, w0
	mov	w10, #16960                     ; =0x4240
	movk	w10, #15, lsl #16
	mul	w9, w9, w10
	stp	x8, x9, [sp]
	mov	x0, sp
	mov	x1, #0                          ; =0x0
	bl	_nanosleep
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #32
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_thread_self_id             ; -- Begin function _xt_thread_self_id
	.p2align	2
__xt_thread_self_id:                    ; @_xt_thread_self_id
	.cfi_startproc
; %bb.0:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	.cfi_def_cfa_offset 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	bl	_pthread_self
	lsr	x8, x0, #4
	lsr	x9, x0, #32
	eor	w0, w8, w9
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_thread_cpu_count           ; -- Begin function _xt_thread_cpu_count
	.p2align	2
__xt_thread_cpu_count:                  ; @_xt_thread_cpu_count
	.cfi_startproc
; %bb.0:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	.cfi_def_cfa_offset 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	mov	w0, #58                         ; =0x3a
	bl	_sysconf
	cmp	x0, #0
	csinc	w0, w0, wzr, gt
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_mutex_new                  ; -- Begin function _xt_mutex_new
	.p2align	2
__xt_mutex_new:                         ; @_xt_mutex_new
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	w0, #64                         ; =0x40
	bl	_malloc
	cbz	x0, LBB103_4
; %bb.1:
	mov	x19, x0
	mov	x1, #0                          ; =0x0
	bl	_pthread_mutex_init
	cbz	w0, LBB103_3
; %bb.2:
	mov	x0, x19
	bl	_free
	mov	x0, #0                          ; =0x0
	b	LBB103_4
LBB103_3:
	mov	x0, x19
LBB103_4:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_mutex_free                 ; -- Begin function _xt_mutex_free
	.p2align	2
__xt_mutex_free:                        ; @_xt_mutex_free
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB104_2
; %bb.1:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	x19, x0
	bl	_pthread_mutex_destroy
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_free
LBB104_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_mutex_lock                 ; -- Begin function _xt_mutex_lock
	.p2align	2
__xt_mutex_lock:                        ; @_xt_mutex_lock
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB105_2
; %bb.1:
	b	_pthread_mutex_lock
LBB105_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_mutex_unlock               ; -- Begin function _xt_mutex_unlock
	.p2align	2
__xt_mutex_unlock:                      ; @_xt_mutex_unlock
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB106_2
; %bb.1:
	b	_pthread_mutex_unlock
LBB106_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_mutex_trylock              ; -- Begin function _xt_mutex_trylock
	.p2align	2
__xt_mutex_trylock:                     ; @_xt_mutex_trylock
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB107_2
; %bb.1:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	.cfi_def_cfa_offset 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	bl	_pthread_mutex_trylock
	cmp	w0, #0
	cset	w0, eq
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
LBB107_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_cond_new                   ; -- Begin function _xt_cond_new
	.p2align	2
__xt_cond_new:                          ; @_xt_cond_new
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	w0, #48                         ; =0x30
	bl	_malloc
	cbz	x0, LBB108_4
; %bb.1:
	mov	x19, x0
	mov	x1, #0                          ; =0x0
	bl	_pthread_cond_init
	cbz	w0, LBB108_3
; %bb.2:
	mov	x0, x19
	bl	_free
	mov	x0, #0                          ; =0x0
	b	LBB108_4
LBB108_3:
	mov	x0, x19
LBB108_4:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_cond_free                  ; -- Begin function _xt_cond_free
	.p2align	2
__xt_cond_free:                         ; @_xt_cond_free
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB109_2
; %bb.1:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	x19, x0
	bl	_pthread_cond_destroy
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_free
LBB109_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_cond_wait                  ; -- Begin function _xt_cond_wait
	.p2align	2
__xt_cond_wait:                         ; @_xt_cond_wait
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB110_3
; %bb.1:
	cbz	x1, LBB110_3
; %bb.2:
	b	_pthread_cond_wait
LBB110_3:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_cond_signal                ; -- Begin function _xt_cond_signal
	.p2align	2
__xt_cond_signal:                       ; @_xt_cond_signal
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB111_2
; %bb.1:
	b	_pthread_cond_signal
LBB111_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_cond_broadcast             ; -- Begin function _xt_cond_broadcast
	.p2align	2
__xt_cond_broadcast:                    ; @_xt_cond_broadcast
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB112_2
; %bb.1:
	b	_pthread_cond_broadcast
LBB112_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_sem_new                    ; -- Begin function _xt_sem_new
	.p2align	2
__xt_sem_new:                           ; @_xt_sem_new
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	x19, x0
	mov	w0, #120                        ; =0x78
	bl	_malloc
	cbz	x0, LBB113_5
; %bb.1:
	mov	x20, x0
	mov	x1, #0                          ; =0x0
	bl	_pthread_mutex_init
	cbnz	w0, LBB113_4
; %bb.2:
	add	x0, x20, #64
	mov	x1, #0                          ; =0x0
	bl	_pthread_cond_init
	cbz	w0, LBB113_6
; %bb.3:
	mov	x0, x20
	bl	_pthread_mutex_destroy
LBB113_4:
	mov	x0, x20
	bl	_free
	mov	x0, #0                          ; =0x0
LBB113_5:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB113_6:
	bic	w8, w19, w19, asr #31
	mov	x0, x20
	str	w8, [x20, #112]
	b	LBB113_5
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_sem_free                   ; -- Begin function _xt_sem_free
	.p2align	2
__xt_sem_free:                          ; @_xt_sem_free
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB114_2
; %bb.1:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	x19, x0
	add	x0, x0, #64
	bl	_pthread_cond_destroy
	mov	x0, x19
	bl	_pthread_mutex_destroy
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_free
LBB114_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_sem_wait                   ; -- Begin function _xt_sem_wait
	.p2align	2
__xt_sem_wait:                          ; @_xt_sem_wait
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB115_4
; %bb.1:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	x19, x0
	bl	_pthread_mutex_lock
	ldr	w8, [x19, #112]
	cmp	w8, #0
	b.gt	LBB115_3
LBB115_2:                               ; =>This Inner Loop Header: Depth=1
	add	x0, x19, #64
	mov	x1, x19
	bl	_pthread_cond_wait
	ldr	w8, [x19, #112]
	cmp	w8, #1
	b.lt	LBB115_2
LBB115_3:
	sub	w8, w8, #1
	str	w8, [x19, #112]
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB115_4:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_sem_trywait                ; -- Begin function _xt_sem_trywait
	.p2align	2
__xt_sem_trywait:                       ; @_xt_sem_trywait
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	cbz	x0, LBB116_3
; %bb.1:
	mov	x19, x0
	bl	_pthread_mutex_lock
	ldr	w8, [x19, #112]
	subs	w8, w8, #1
	b.lt	LBB116_4
; %bb.2:
	str	w8, [x19, #112]
	mov	w20, #1                         ; =0x1
	b	LBB116_5
LBB116_3:
	mov	w20, #0                         ; =0x0
	b	LBB116_6
LBB116_4:
	mov	w20, #0                         ; =0x0
LBB116_5:
	mov	x0, x19
	bl	_pthread_mutex_unlock
LBB116_6:
	mov	x0, x20
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_sem_post                   ; -- Begin function _xt_sem_post
	.p2align	2
__xt_sem_post:                          ; @_xt_sem_post
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB117_2
; %bb.1:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	x19, x0
	bl	_pthread_mutex_lock
	ldr	w8, [x19, #112]
	add	w8, w8, #1
	str	w8, [x19, #112]
	add	x0, x19, #64
	bl	_pthread_cond_signal
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB117_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_tls_new                    ; -- Begin function _xt_tls_new
	.p2align	2
__xt_tls_new:                           ; @_xt_tls_new
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	add	x0, sp, #8
	mov	x1, #0                          ; =0x0
	bl	_pthread_key_create
	ldr	w8, [sp, #8]
	cmp	w0, #0
	csinv	w0, w8, wzr, eq
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #32
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_tls_set                    ; -- Begin function _xt_tls_set
	.p2align	2
__xt_tls_set:                           ; @_xt_tls_set
	.cfi_startproc
; %bb.0:
	cmn	w0, #1
	b.eq	LBB119_2
; %bb.1:
	mov	w0, w0
	b	_pthread_setspecific
LBB119_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_tls_get                    ; -- Begin function _xt_tls_get
	.p2align	2
__xt_tls_get:                           ; @_xt_tls_get
	.cfi_startproc
; %bb.0:
	cmn	w0, #1
	b.eq	LBB120_2
; %bb.1:
	mov	w0, w0
	b	_pthread_getspecific
LBB120_2:
	mov	x0, #0                          ; =0x0
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_load_i32            ; -- Begin function _xt_atomic_load_i32
	.p2align	2
__xt_atomic_load_i32:                   ; @_xt_atomic_load_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB121_2
; %bb.1:
	ldar	w0, [x0]
LBB121_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_store_i32           ; -- Begin function _xt_atomic_store_i32
	.p2align	2
__xt_atomic_store_i32:                  ; @_xt_atomic_store_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB122_2
; %bb.1:
	stlr	w1, [x0]
LBB122_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_add_i32             ; -- Begin function _xt_atomic_add_i32
	.p2align	2
__xt_atomic_add_i32:                    ; @_xt_atomic_add_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB123_2
; %bb.1:
	ldaddal	w1, w8, [x0]
	add	w0, w8, w1
LBB123_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_xchg_i32            ; -- Begin function _xt_atomic_xchg_i32
	.p2align	2
__xt_atomic_xchg_i32:                   ; @_xt_atomic_xchg_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB124_2
; %bb.1:
	swpal	w1, w0, [x0]
LBB124_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_cas_i32             ; -- Begin function _xt_atomic_cas_i32
	.p2align	2
__xt_atomic_cas_i32:                    ; @_xt_atomic_cas_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB125_2
; %bb.1:
	mov	x8, x1
	casal	w8, w2, [x0]
	cmp	w8, w1
	cset	w0, eq
LBB125_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_load_ptr            ; -- Begin function _xt_atomic_load_ptr
	.p2align	2
__xt_atomic_load_ptr:                   ; @_xt_atomic_load_ptr
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB126_2
; %bb.1:
	ldar	x0, [x0]
LBB126_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_store_ptr           ; -- Begin function _xt_atomic_store_ptr
	.p2align	2
__xt_atomic_store_ptr:                  ; @_xt_atomic_store_ptr
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB127_2
; %bb.1:
	stlr	x1, [x0]
LBB127_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_cas_ptr             ; -- Begin function _xt_atomic_cas_ptr
	.p2align	2
__xt_atomic_cas_ptr:                    ; @_xt_atomic_cas_ptr
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB128_2
; %bb.1:
	mov	x8, x1
	casal	x8, x2, [x0]
	cmp	x8, x1
	cset	w0, eq
LBB128_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_sinit_run                 ; -- Begin function _xtc_sinit_run
	.p2align	2
__xtc_sinit_run:                        ; @_xtc_sinit_run
	.cfi_startproc
; %bb.0:
	stp	x28, x27, [sp, #-96]!           ; 16-byte Folded Spill
	stp	x26, x25, [sp, #16]             ; 16-byte Folded Spill
	stp	x24, x23, [sp, #32]             ; 16-byte Folded Spill
	stp	x22, x21, [sp, #48]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #64]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #80]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 96
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	.cfi_offset w23, -56
	.cfi_offset w24, -64
	.cfi_offset w25, -72
	.cfi_offset w26, -80
	.cfi_offset w27, -88
	.cfi_offset w28, -96
	cbz	x0, LBB129_35
; %bb.1:
	mov	x21, x2
	mov	x20, x1
	mov	x19, x0
	adrp	x23, __xt_threads_active@PAGE
	mov	w25, #1                         ; =0x1
	adrp	x24, _xt_sinit_n@PAGE
Lloh200:
	adrp	x26, _xt_sinit_flag@PAGE
Lloh201:
	add	x26, x26, _xt_sinit_flag@PAGEOFF
Lloh202:
	adrp	x27, _xt_sinit_owner@PAGE
Lloh203:
	add	x27, x27, _xt_sinit_owner@PAGEOFF
Lloh204:
	adrp	x22, _xt_rt_mtx@PAGE
Lloh205:
	add	x22, x22, _xt_rt_mtx@PAGEOFF
	b	LBB129_4
LBB129_2:                               ;   in Loop: Header=BB129_4 Depth=1
	mov	w8, #1                          ; =0x1
LBB129_3:                               ;   in Loop: Header=BB129_4 Depth=1
	cbnz	w8, LBB129_23
LBB129_4:                               ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB129_17 Depth 2
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB129_6
; %bb.5:                                ;   in Loop: Header=BB129_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_lock
LBB129_6:                               ;   in Loop: Header=BB129_4 Depth=1
	ldrb	w8, [x19]
	cbz	w8, LBB129_10
; %bb.7:                                ;   in Loop: Header=BB129_4 Depth=1
	cmp	w8, #2
	b.ne	LBB129_14
LBB129_8:                               ;   in Loop: Header=BB129_4 Depth=1
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB129_2
; %bb.9:                                ;   in Loop: Header=BB129_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_unlock
	b	LBB129_2
LBB129_10:                              ;   in Loop: Header=BB129_4 Depth=1
	strb	w25, [x19]
	ldrsw	x8, [x24, _xt_sinit_n@PAGEOFF]
	cmp	w8, #31
	b.gt	LBB129_12
; %bb.11:                               ;   in Loop: Header=BB129_4 Depth=1
	str	x19, [x26, x8, lsl #3]
	bl	_pthread_self
	lsr	x8, x0, #4
	lsr	x9, x0, #32
	eor	w8, w8, w9
	ldrsw	x9, [x24, _xt_sinit_n@PAGEOFF]
	str	w8, [x27, x9, lsl #2]
	add	w8, w9, #1
	str	w8, [x24, _xt_sinit_n@PAGEOFF]
LBB129_12:                              ;   in Loop: Header=BB129_4 Depth=1
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB129_22
; %bb.13:                               ;   in Loop: Header=BB129_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_unlock
	mov	w8, #2                          ; =0x2
	b	LBB129_3
LBB129_14:                              ;   in Loop: Header=BB129_4 Depth=1
	bl	_pthread_self
	ldr	w8, [x24, _xt_sinit_n@PAGEOFF]
	cmp	w8, #1
	b.lt	LBB129_19
; %bb.15:                               ;   in Loop: Header=BB129_4 Depth=1
	lsr	x9, x0, #4
	lsr	x10, x0, #32
	eor	w9, w9, w10
	mov	x10, x26
	mov	x11, x27
	b	LBB129_17
LBB129_16:                              ;   in Loop: Header=BB129_17 Depth=2
	add	x11, x11, #4
	add	x10, x10, #8
	subs	x8, x8, #1
	b.eq	LBB129_19
LBB129_17:                              ;   Parent Loop BB129_4 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldr	x12, [x10]
	cmp	x12, x19
	b.ne	LBB129_16
; %bb.18:                               ;   in Loop: Header=BB129_17 Depth=2
	ldr	w12, [x11]
	cmp	w12, w9
	b.ne	LBB129_16
	b	LBB129_8
LBB129_19:                              ;   in Loop: Header=BB129_4 Depth=1
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB129_21
; %bb.20:                               ;   in Loop: Header=BB129_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_unlock
LBB129_21:                              ;   in Loop: Header=BB129_4 Depth=1
	bl	_sched_yield
	mov	w8, #0                          ; =0x0
	b	LBB129_3
LBB129_22:                              ;   in Loop: Header=BB129_4 Depth=1
	mov	w8, #2                          ; =0x2
	b	LBB129_3
LBB129_23:
	cmp	w8, #1
	b.eq	LBB129_35
; %bb.24:
	cbz	x20, LBB129_26
; %bb.25:
	mov	x0, x21
	blr	x20
LBB129_26:
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB129_28
; %bb.27:
Lloh206:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh207:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB129_28:
	mov	w8, #2                          ; =0x2
	strb	w8, [x19]
	ldr	w8, [x24, _xt_sinit_n@PAGEOFF]
	cmp	w8, #1
	b.lt	LBB129_32
; %bb.29:
Lloh208:
	adrp	x9, _xt_sinit_owner@PAGE
Lloh209:
	add	x9, x9, _xt_sinit_owner@PAGEOFF
Lloh210:
	adrp	x10, _xt_sinit_flag@PAGE
Lloh211:
	add	x10, x10, _xt_sinit_flag@PAGEOFF
	mov	x13, x8
	mov	x12, x10
	mov	x11, x9
LBB129_30:                              ; =>This Inner Loop Header: Depth=1
	ldr	x14, [x12]
	cmp	x14, x19
	b.eq	LBB129_34
; %bb.31:                               ;   in Loop: Header=BB129_30 Depth=1
	add	x11, x11, #4
	add	x12, x12, #8
	subs	x13, x13, #1
	b.ne	LBB129_30
LBB129_32:
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB129_35
LBB129_33:
Lloh212:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh213:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #80]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #64]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp], #96             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB129_34:
	sxtw	x8, w8
	sub	x8, x8, #1
	str	w8, [x24, _xt_sinit_n@PAGEOFF]
	ldr	x10, [x10, x8, lsl #3]
	str	x10, [x12]
	ldr	w8, [x9, x8, lsl #2]
	str	w8, [x11]
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbnz	w8, LBB129_33
LBB129_35:
	ldp	x29, x30, [sp, #80]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #64]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp], #96             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh204, Lloh205
	.loh AdrpAdd	Lloh202, Lloh203
	.loh AdrpAdd	Lloh200, Lloh201
	.loh AdrpAdd	Lloh206, Lloh207
	.loh AdrpAdd	Lloh210, Lloh211
	.loh AdrpAdd	Lloh208, Lloh209
	.loh AdrpAdd	Lloh212, Lloh213
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_thread_exiting             ; -- Begin function _xt_thread_exiting
	.p2align	2
__xt_thread_exiting:                    ; @_xt_thread_exiting
	.cfi_startproc
; %bb.0:
	ret
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function xt_simd_fault
_xt_simd_fault:                         ; @xt_simd_fault
	.cfi_startproc
; %bb.0:
	stp	x22, x21, [sp, #-48]!           ; 16-byte Folded Spill
	stp	x20, x19, [sp, #16]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #32]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 48
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	mov	x19, x0
	ldr	x20, [x1, #24]
	adrp	x21, __xt_threads_active@PAGE
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB131_2
; %bb.1:
Lloh214:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh215:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB131_2:
Lloh216:
	adrp	x8, _xt_simd_n@PAGE
Lloh217:
	ldr	x10, [x8, _xt_simd_n@PAGEOFF]
Lloh218:
	adrp	x8, _xt_simd_tab@PAGE
	mov	x9, #0                          ; =0x0
	cbz	x10, LBB131_5
; %bb.3:
	ldr	x11, [x8, _xt_simd_tab@PAGEOFF]
LBB131_4:                               ; =>This Inner Loop Header: Depth=1
	add	x12, x10, x9
	lsr	x13, x12, #1
	and	x12, x12, #0x1ffffffffffffffe
	ldr	x12, [x11, x12, lsl #3]
	cmp	x12, x20
	csel	x10, x13, x10, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x10
	b.lo	LBB131_4
LBB131_5:
	cbz	x9, LBB131_11
; %bb.6:
	ldr	x8, [x8, _xt_simd_tab@PAGEOFF]
	sub	x10, x9, #1
	add	x9, x8, x10, lsl #4
	ldr	x9, [x9, #8]
	cmp	x20, x9
	b.hs	LBB131_11
; %bb.7:
	lsl	x11, x10, #1
Lloh219:
	adrp	x12, _xt_simd_flag@PAGE
Lloh220:
	ldr	x12, [x12, _xt_simd_flag@PAGEOFF]
	ldrb	w13, [x12, x10]
	tbnz	w13, #1, LBB131_20
; %bb.8:
	tbz	w13, #0, LBB131_10
; %bb.9:
	and	w13, w13, #0xfc
	strb	w13, [x12, x10]
	ldr	x0, [x8, x11, lsl #3]
	mov	w8, #16383                      ; =0x3fff
	sub	x9, x9, x0
	add	x8, x9, x8
	and	x1, x8, #0xffffffffffffc000
	mov	w2, #3                          ; =0x3
	bl	_mprotect
LBB131_10:
	mov	x20, #0                         ; =0x0
	b	LBB131_21
LBB131_11:
	mov	x20, #0                         ; =0x0
	mov	w22, #0                         ; =0x0
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB131_13
LBB131_12:
Lloh221:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh222:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB131_13:
	cbz	x20, LBB131_17
; %bb.14:
Lloh223:
	adrp	x8, _xt_simd_hook_code@PAGE
Lloh224:
	ldr	x8, [x8, _xt_simd_hook_code@PAGEOFF]
	cbz	x8, LBB131_16
; %bb.15:
Lloh225:
	adrp	x9, _xt_simd_hook_recv@PAGE
Lloh226:
	ldr	x0, [x9, _xt_simd_hook_recv@PAGEOFF]
	mov	x1, x20
	mov	w2, #0                          ; =0x0
	blr	x8
	cbnz	w0, LBB131_17
LBB131_16:
	mov	w22, #0                         ; =0x0
LBB131_17:
	cbz	w22, LBB131_19
; %bb.18:
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	ret
LBB131_19:
	cmp	w19, #11
	cset	w8, ne
Lloh227:
	adrp	x9, _xt_simd_old@PAGE
Lloh228:
	add	x9, x9, _xt_simd_old@PAGEOFF
	add	x1, x9, w8, uxtw #4
	mov	x0, x19
	mov	x2, #0                          ; =0x0
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	b	_sigaction
LBB131_20:
	ldr	x20, [x8, x11, lsl #3]
LBB131_21:
	mov	w22, #1                         ; =0x1
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbnz	w8, LBB131_12
	b	LBB131_13
	.loh AdrpAdd	Lloh214, Lloh215
	.loh AdrpAdrp	Lloh216, Lloh218
	.loh AdrpLdr	Lloh216, Lloh217
	.loh AdrpLdr	Lloh219, Lloh220
	.loh AdrpAdd	Lloh221, Lloh222
	.loh AdrpLdr	Lloh223, Lloh224
	.loh AdrpLdr	Lloh225, Lloh226
	.loh AdrpAdd	Lloh227, Lloh228
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function xt_wtab_put
_xt_wtab_put:                           ; @xt_wtab_put
	.cfi_startproc
; %bb.0:
	stp	x28, x27, [sp, #-96]!           ; 16-byte Folded Spill
	stp	x26, x25, [sp, #16]             ; 16-byte Folded Spill
	stp	x24, x23, [sp, #32]             ; 16-byte Folded Spill
	stp	x22, x21, [sp, #48]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #64]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #80]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 96
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	.cfi_offset w23, -56
	.cfi_offset w24, -64
	.cfi_offset w25, -72
	.cfi_offset w26, -80
	.cfi_offset w27, -88
	.cfi_offset w28, -96
	mov	x19, x1
	mov	x20, x0
	adrp	x22, _xt_wtab_used@PAGE
	ldr	x8, [x22, _xt_wtab_used@PAGEOFF]
	lsl	x8, x8, #1
	add	x8, x8, #2
	adrp	x24, _xt_wtab_cap@PAGE
	ldr	x26, [x24, _xt_wtab_cap@PAGEOFF]
	adrp	x25, _xt_wtab@PAGE
	adrp	x23, _xt_wtab_n@PAGE
	cmp	x8, x26
	b.ls	LBB132_10
; %bb.1:
	ldr	x21, [x25, _xt_wtab@PAGEOFF]
	lsl	x8, x26, #1
	mov	w9, #64                         ; =0x40
	cmp	x26, #0
	csel	x8, x9, x8, eq
	ldr	x9, [x23, _xt_wtab_n@PAGEOFF]
	lsl	x9, x9, #1
LBB132_2:                               ; =>This Inner Loop Header: Depth=1
	mov	x0, x8
	lsl	x8, x8, #1
	cmp	x9, x0
	b.hs	LBB132_2
; %bb.3:
	str	x0, [x24, _xt_wtab_cap@PAGEOFF]
	mov	w1, #16                         ; =0x10
	bl	_calloc
	str	x0, [x25, _xt_wtab@PAGEOFF]
	cbz	x0, LBB132_15
; %bb.4:
	str	xzr, [x23, _xt_wtab_n@PAGEOFF]
	str	xzr, [x22, _xt_wtab_used@PAGEOFF]
	cbz	x26, LBB132_9
; %bb.5:
	add	x27, x21, #8
	b	LBB132_7
LBB132_6:                               ;   in Loop: Header=BB132_7 Depth=1
	add	x27, x27, #16
	subs	x26, x26, #1
	b.eq	LBB132_9
LBB132_7:                               ; =>This Inner Loop Header: Depth=1
	ldur	x0, [x27, #-8]
	cmp	x0, #2
	b.lo	LBB132_6
; %bb.8:                                ;   in Loop: Header=BB132_7 Depth=1
	ldr	x1, [x27]
	bl	_xt_wtab_put
	b	LBB132_6
LBB132_9:
	mov	x0, x21
	bl	_free
LBB132_10:
	lsr	x8, x20, #3
	eor	x8, x8, x20, lsr #20
	mov	w9, #54459                      ; =0xd4bb
	movk	w9, #60762, lsl #16
	mul	x8, x8, x9
	eor	x10, x8, x8, lsr #11
	ldr	x8, [x24, _xt_wtab_cap@PAGEOFF]
	sub	x9, x8, #1
	ldr	x8, [x25, _xt_wtab@PAGEOFF]
LBB132_11:                              ; =>This Inner Loop Header: Depth=1
	and	x12, x10, x9
	lsl	x10, x12, #4
	ldr	x11, [x8, x10]
	add	x10, x12, #1
	cmp	x11, #1
	b.hi	LBB132_11
; %bb.12:
	add	x8, x8, x12, lsl #4
	cbnz	x11, LBB132_14
; %bb.13:
	ldr	x9, [x22, _xt_wtab_used@PAGEOFF]
	add	x9, x9, #1
	str	x9, [x22, _xt_wtab_used@PAGEOFF]
LBB132_14:
	stp	x20, x19, [x8]
	ldr	x8, [x23, _xt_wtab_n@PAGEOFF]
	add	x8, x8, #1
	str	x8, [x23, _xt_wtab_n@PAGEOFF]
	ldp	x29, x30, [sp, #80]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #64]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp], #96             ; 16-byte Folded Reload
	ret
LBB132_15:
	bl	_xt_wtab_put.cold.1
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function _xtc_alloc_object.cold.1
__xtc_alloc_object.cold.1:              ; @_xtc_alloc_object.cold.1
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh229:
	adrp	x8, ___stderrp@GOTPAGE
Lloh230:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh231:
	ldr	x8, [x8]
	str	x0, [sp]
Lloh232:
	adrp	x1, l_.str.1@PAGE
Lloh233:
	add	x1, x1, l_.str.1@PAGEOFF
	mov	x0, x8
	bl	_fprintf
	bl	_abort
	.loh AdrpAdd	Lloh232, Lloh233
	.loh AdrpLdrGotLdr	Lloh229, Lloh230, Lloh231
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function _xtc_alloc_object.cold.2
__xtc_alloc_object.cold.2:              ; @_xtc_alloc_object.cold.2
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh234:
	adrp	x8, ___stderrp@GOTPAGE
Lloh235:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh236:
	ldr	x8, [x8]
	mov	w9, #1                          ; =0x1
	stp	x9, x0, [sp]
Lloh237:
	adrp	x1, l_.str.7@PAGE
Lloh238:
	add	x1, x1, l_.str.7@PAGEOFF
	mov	x0, x8
	bl	_fprintf
	bl	_abort
	.loh AdrpAdd	Lloh237, Lloh238
	.loh AdrpLdrGotLdr	Lloh234, Lloh235, Lloh236
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function _xtc_weak_register.cold.1
__xtc_weak_register.cold.1:             ; @_xtc_weak_register.cold.1
	.cfi_startproc
; %bb.0:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	.cfi_def_cfa_offset 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh239:
	adrp	x8, ___stderrp@GOTPAGE
Lloh240:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh241:
	ldr	x3, [x8]
Lloh242:
	adrp	x0, l_.str.8@PAGE
Lloh243:
	add	x0, x0, l_.str.8@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh242, Lloh243
	.loh AdrpLdrGotLdr	Lloh239, Lloh240, Lloh241
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function xt_wtab_put.cold.1
_xt_wtab_put.cold.1:                    ; @xt_wtab_put.cold.1
	.cfi_startproc
; %bb.0:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	.cfi_def_cfa_offset 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh244:
	adrp	x8, ___stderrp@GOTPAGE
Lloh245:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh246:
	ldr	x3, [x8]
Lloh247:
	adrp	x0, l_.str.8@PAGE
Lloh248:
	add	x0, x0, l_.str.8@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh247, Lloh248
	.loh AdrpLdrGotLdr	Lloh244, Lloh245, Lloh246
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function OUTLINED_FUNCTION_0
_OUTLINED_FUNCTION_0:                   ; @OUTLINED_FUNCTION_0 Thunk
	.cfi_startproc
; %bb.0:
	mov	w1, #37                         ; =0x25
	mov	w2, #1                          ; =0x1
	b	_fwrite
	.cfi_endproc
                                        ; -- End function
	.section	__TEXT,__cstring,cstring_literals
l_.str:                                 ; @.str
	.asciz	"xcc: out of memory allocating %lu x %lu bytes\n"

l_.str.1:                               ; @.str.1
	.asciz	"xcc: out of memory allocating %lu bytes\n"

.zerofill __DATA,__bss,_xt_simd_tab,8,3 ; @xt_simd_tab
.zerofill __DATA,__bss,_xt_simd_hook_recv,8,3 ; @xt_simd_hook_recv
.zerofill __DATA,__bss,_xt_simd_hook_code,8,3 ; @xt_simd_hook_code
.zerofill __DATA,__bss,_xt_simd_flag,8,3 ; @xt_simd_flag
.zerofill __DATA,__bss,_xt_btab,8,3     ; @xt_btab
.zerofill __DATA,__bss,_xt_wtab_n,8,3   ; @xt_wtab_n
l_.str.2:                               ; @.str.2
	.asciz	"%.6f"

l_.str.3:                               ; @.str.3
	.asciz	"%.10f"

.zerofill __DATA,__bss,_xt_rand_seeded,1,2 ; @xt_rand_seeded
.zerofill __DATA,__bss,_xt_clk_origin,8,3 ; @xt_clk_origin
.zerofill __DATA,__bss,__xtc_bank_regions,6144,3 ; @_xtc_bank_regions
.zerofill __DATA,__bss,_xt_files,64,3   ; @xt_files
l_.str.4:                               ; @.str.4
	.asciz	"rb"

l_.str.5:                               ; @.str.5
	.space	1

	.private_extern	___xt_stack_guard       ; @__xt_stack_guard
	.comm	___xt_stack_guard,8,3
l_.str.6:                               ; @.str.6
	.asciz	"xcc: stack smashing detected (a local array was written past its end)\n"

.zerofill __DATA,__bss,_xt_argc_v,4,2   ; @xt_argc_v
.zerofill __DATA,__bss,_xt_argv_v,8,3   ; @xt_argv_v
	.globl	__xt_threads_active             ; @_xt_threads_active
.zerofill __DATA,__common,__xt_threads_active,4,2
.zerofill __DATA,__bss,_xt_rt_mtx,64,3  ; @xt_rt_mtx
.zerofill __DATA,__bss,_xt_sinit_n,4,2  ; @xt_sinit_n
.zerofill __DATA,__bss,_xt_sinit_flag,256,3 ; @xt_sinit_flag
.zerofill __DATA,__bss,_xt_sinit_owner,128,2 ; @xt_sinit_owner
l_.str.7:                               ; @.str.7
	.asciz	"xcc: an allocation of %lu x %lu bytes overflows\n"

.zerofill __DATA,__bss,_xt_simd_n,8,3   ; @xt_simd_n
.zerofill __DATA,__bss,_xt_simd_cap,8,3 ; @xt_simd_cap
.zerofill __DATA,__bss,_xt_simd_installed,1,2 ; @xt_simd_installed
.zerofill __DATA,__bss,_xt_simd_old,32,3 ; @xt_simd_old
.zerofill __DATA,__bss,_xt_wcell_free,8,3 ; @xt_wcell_free
l_.str.8:                               ; @.str.8
	.asciz	"xcc: out of memory (weak references)\n"

.zerofill __DATA,__bss,_xt_wtab_used,8,3 ; @xt_wtab_used
.zerofill __DATA,__bss,_xt_wtab_cap,8,3 ; @xt_wtab_cap
.zerofill __DATA,__bss,_xt_wtab,8,3     ; @xt_wtab
l_.str.9:                               ; @.str.9
	.asciz	"%.*f"

.subsections_via_symbols
