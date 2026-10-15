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
// + threads). GENERATED from src/xtc/support-src/rt.c with
//   clang -S -O1 -fno-stack-protector -fomit-frame-pointer -arch arm64
// then checked in. clang never touches a USER compile — this .s is assembled by
// XAArm64Assembler like any other, so the toolchain stays self-hosted. Regenerate
// from src/xtc/support-src/rt.c if the object layout / runtime contract changes.
// Provides: _xtc_alloc, _xtc_new_<prim>, _xtc_dealloc, _xtc_weak_*, _putc,
// _xtc_pf/pd/pfp/pdp, _xm_* (libm wrappers), _xt_getenv, _xt_mkdir, and the _xt_thread/mutex/cond/sem/
// atomic/tls primitives (from support/arm64/runtime/xt-threads.c, which the
// clang-path libxt.c includes too). Object header = 40 bytes, magic 0x58544F42
// at base, refcount u32 at obj-4, weak head at obj-12.
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
	mul	x8, x1, x0
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w22, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB0_2
; %bb.1:
	mov	x8, x0
	mov	w9, #20290                      ; =0x4f42
	movk	w9, #22612, lsl #16
	str	w9, [x0]
	stur	x20, [x0, #4]
	stur	x19, [x0, #12]
	stur	x21, [x0, #20]
	stur	xzr, [x0, #28]
	add	x0, x0, #40
	str	w22, [x8, #36]
	ldp	x29, x30, [sp, #48]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #32]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #64
	ret
LBB0_2:
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
	.loh AdrpAdd	Lloh3, Lloh4
	.loh AdrpLdrGotLdr	Lloh0, Lloh1, Lloh2
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_u8                    ; -- Begin function _xtc_new_u8
	.p2align	2
__xtc_new_u8:                           ; @_xtc_new_u8
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	cmp	x0, #16, lsl #12                ; =65536
	b.lo	LBB1_2
; %bb.1:
	mov	w1, #1                          ; =0x1
	mov	x2, #0                          ; =0x0
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	__xtc_alloc_aligned
LBB1_2:
	mov	w8, #16                         ; =0x10
	cmp	x0, #16
	mov	x19, x0
	csel	x8, x0, x8, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB1_4
; %bb.3:
	mov	x8, x0
	mov	w9, #20290                      ; =0x4f42
	movk	w9, #22612, lsl #16
	str	w9, [x0]
	stur	x20, [x0, #4]
	stur	x19, [x0, #12]
	stur	xzr, [x0, #28]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	str	w20, [x8, #36]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB1_4:
	mov	x0, x19
	bl	__xtc_new_u8.cold.1
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
	mov	x21, x1
	mov	x20, x0
	mul	x23, x1, x0
	mov	w8, #16                         ; =0x10
	cmp	x23, #16
	csel	x8, x23, x8, hi
	mov	w9, #16383                      ; =0x3fff
	add	x8, x8, x9
	and	x8, x8, #0xffffffffffffc000
	mov	w9, #16432                      ; =0x4030
	mov	w24, #1                         ; =0x1
	add	x1, x8, x9
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB2_25
; %bb.1:
	mov	w8, #16431                      ; =0x402f
	add	x8, x0, x8
	and	x19, x8, #0xffffffffffffc000
	mov	w8, #20291                      ; =0x4f43
	movk	w8, #22612, lsl #16
	stur	w8, [x19, #-40]
	stur	x21, [x19, #-36]
	stur	x20, [x19, #-28]
	stur	x22, [x19, #-20]
	stur	xzr, [x19, #-12]
	stur	w24, [x19, #-4]
	stur	x0, [x19, #-48]
	adrp	x20, __xt_threads_active@PAGE
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB2_3
; %bb.2:
Lloh5:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh6:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB2_3:
	adrp	x25, _xt_simd_n@PAGE
	ldr	x24, [x25, _xt_simd_n@PAGEOFF]
	adrp	x28, _xt_simd_cap@PAGE
	ldr	x8, [x28, _xt_simd_cap@PAGEOFF]
	adrp	x27, _xt_simd_tab@PAGE
	adrp	x21, _xt_simd_flag@PAGE
	cmp	x24, x8
	b.ne	LBB2_15
; %bb.4:
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
	b.eq	LBB2_12
; %bb.5:
	lsl	x8, x24, #1
	cbz	x8, LBB2_8
; %bb.6:
	ldr	x9, [x27, _xt_simd_tab@PAGEOFF]
	mov	x10, x21
LBB2_7:                                 ; =>This Inner Loop Header: Depth=1
	ldr	x11, [x9], #8
	str	x11, [x10], #8
	subs	x8, x8, #1
	b.ne	LBB2_7
LBB2_8:
	cbz	x24, LBB2_11
; %bb.9:
Lloh7:
	adrp	x8, _xt_simd_flag@PAGE
Lloh8:
	ldr	x8, [x8, _xt_simd_flag@PAGEOFF]
	mov	x9, x22
LBB2_10:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w10, [x8], #1
	strb	w10, [x9], #1
	subs	x24, x24, #1
	b.ne	LBB2_10
LBB2_11:
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
	b	LBB2_14
LBB2_12:
	mov	x0, x21
	bl	_free
	mov	x0, x22
	bl	_free
	adrp	x20, __xt_threads_active@PAGE
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	adrp	x21, _xt_simd_flag@PAGE
	cbz	w8, LBB2_14
; %bb.13:
Lloh9:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh10:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB2_14:
	cbz	w26, LBB2_24
LBB2_15:
	ldr	x8, [x25, _xt_simd_n@PAGEOFF]
	cbz	x8, LBB2_19
; %bb.16:
	mov	x9, #0                          ; =0x0
	ldr	x10, [x27, _xt_simd_tab@PAGEOFF]
	mov	x11, x8
LBB2_17:                                ; =>This Inner Loop Header: Depth=1
	add	x12, x11, x9
	lsr	x13, x12, #1
	and	x12, x12, #0x1ffffffffffffffe
	ldr	x12, [x10, x12, lsl #3]
	cmp	x12, x19
	csel	x11, x13, x11, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x11
	b.lo	LBB2_17
; %bb.18:
	cmp	x8, x9
	b.hi	LBB2_20
	b	LBB2_22
LBB2_19:
	mov	x9, #0                          ; =0x0
	cmp	x8, x9
	b.ls	LBB2_22
LBB2_20:
	ldr	x10, [x27, _xt_simd_tab@PAGEOFF]
	ldr	x11, [x21, _xt_simd_flag@PAGEOFF]
	add	x13, x10, x8, lsl #4
	sub	x10, x11, #1
	mov	x11, x8
	mov	x12, x13
LBB2_21:                                ; =>This Inner Loop Header: Depth=1
	ldr	x14, [x12, #-16]!
	ldur	x15, [x13, #-8]
	stp	x14, x15, [x13]
	add	x13, x10, x11
	ldrb	w14, [x13]
	strb	w14, [x13, #1]
	sub	x11, x11, #1
	mov	x13, x12
	cmp	x11, x9
	b.hi	LBB2_21
LBB2_22:
	ldr	x10, [x27, _xt_simd_tab@PAGEOFF]
	add	x10, x10, x9, lsl #4
	add	x11, x19, x23
	stp	x19, x11, [x10]
	ldr	x10, [x21, _xt_simd_flag@PAGEOFF]
	strb	wzr, [x10, x9]
	add	x8, x8, #1
	str	x8, [x25, _xt_simd_n@PAGEOFF]
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB2_24
; %bb.23:
Lloh11:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh12:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB2_24:
	mov	x0, x19
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #64]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #48]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #32]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
LBB2_25:
Lloh13:
	adrp	x8, ___stderrp@GOTPAGE
Lloh14:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh15:
	ldr	x0, [x8]
	stp	x20, x21, [sp]
Lloh16:
	adrp	x1, l_.str@PAGE
Lloh17:
	add	x1, x1, l_.str@PAGEOFF
	bl	_fprintf
	bl	_abort
	.loh AdrpAdd	Lloh5, Lloh6
	.loh AdrpLdr	Lloh7, Lloh8
	.loh AdrpAdd	Lloh9, Lloh10
	.loh AdrpAdd	Lloh11, Lloh12
	.loh AdrpAdd	Lloh16, Lloh17
	.loh AdrpLdrGotLdr	Lloh13, Lloh14, Lloh15
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_i8                    ; -- Begin function _xtc_new_i8
	.p2align	2
__xtc_new_i8:                           ; @_xtc_new_i8
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	cmp	x0, #16, lsl #12                ; =65536
	b.lo	LBB3_2
; %bb.1:
	mov	w1, #1                          ; =0x1
	mov	x2, #0                          ; =0x0
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	__xtc_alloc_aligned
LBB3_2:
	mov	w8, #16                         ; =0x10
	cmp	x0, #16
	mov	x19, x0
	csel	x8, x0, x8, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB3_4
; %bb.3:
	mov	x8, x0
	mov	w9, #20290                      ; =0x4f42
	movk	w9, #22612, lsl #16
	str	w9, [x0]
	stur	x20, [x0, #4]
	stur	x19, [x0, #12]
	stur	xzr, [x0, #28]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	str	w20, [x8, #36]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB3_4:
	mov	x0, x19
	bl	__xtc_new_i8.cold.1
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_u16                   ; -- Begin function _xtc_new_u16
	.p2align	2
__xtc_new_u16:                          ; @_xtc_new_u16
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	tst	x0, #0x7fffffffffff8000
	b.eq	LBB4_2
; %bb.1:
	mov	w1, #2                          ; =0x2
	mov	x2, #0                          ; =0x0
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	__xtc_alloc_aligned
LBB4_2:
	mov	x19, x0
	lsl	x8, x0, #1
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB4_4
; %bb.3:
	mov	x8, x0
	mov	w9, #20290                      ; =0x4f42
	movk	w9, #22612, lsl #16
	str	w9, [x0]
	mov	w9, #2                          ; =0x2
	stur	x9, [x0, #4]
	stur	x19, [x0, #12]
	stur	xzr, [x0, #28]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	str	w20, [x8, #36]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB4_4:
	mov	x0, x19
	bl	__xtc_new_u16.cold.1
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_i16                   ; -- Begin function _xtc_new_i16
	.p2align	2
__xtc_new_i16:                          ; @_xtc_new_i16
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	tst	x0, #0x7fffffffffff8000
	b.eq	LBB5_2
; %bb.1:
	mov	w1, #2                          ; =0x2
	mov	x2, #0                          ; =0x0
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	__xtc_alloc_aligned
LBB5_2:
	mov	x19, x0
	lsl	x8, x0, #1
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB5_4
; %bb.3:
	mov	x8, x0
	mov	w9, #20290                      ; =0x4f42
	movk	w9, #22612, lsl #16
	str	w9, [x0]
	mov	w9, #2                          ; =0x2
	stur	x9, [x0, #4]
	stur	x19, [x0, #12]
	stur	xzr, [x0, #28]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	str	w20, [x8, #36]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB5_4:
	mov	x0, x19
	bl	__xtc_new_i16.cold.1
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_u32                   ; -- Begin function _xtc_new_u32
	.p2align	2
__xtc_new_u32:                          ; @_xtc_new_u32
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	tst	x0, #0x3fffffffffffc000
	b.eq	LBB6_2
; %bb.1:
	mov	w1, #4                          ; =0x4
	mov	x2, #0                          ; =0x0
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	__xtc_alloc_aligned
LBB6_2:
	mov	x19, x0
	lsl	x8, x0, #2
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB6_4
; %bb.3:
	mov	x8, x0
	mov	w9, #20290                      ; =0x4f42
	movk	w9, #22612, lsl #16
	str	w9, [x0]
	mov	w9, #4                          ; =0x4
	stur	x9, [x0, #4]
	stur	x19, [x0, #12]
	stur	xzr, [x0, #28]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	str	w20, [x8, #36]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB6_4:
	mov	x0, x19
	bl	__xtc_new_u32.cold.1
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_i32                   ; -- Begin function _xtc_new_i32
	.p2align	2
__xtc_new_i32:                          ; @_xtc_new_i32
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	tst	x0, #0x3fffffffffffc000
	b.eq	LBB7_2
; %bb.1:
	mov	w1, #4                          ; =0x4
	mov	x2, #0                          ; =0x0
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	__xtc_alloc_aligned
LBB7_2:
	mov	x19, x0
	lsl	x8, x0, #2
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB7_4
; %bb.3:
	mov	x8, x0
	mov	w9, #20290                      ; =0x4f42
	movk	w9, #22612, lsl #16
	str	w9, [x0]
	mov	w9, #4                          ; =0x4
	stur	x9, [x0, #4]
	stur	x19, [x0, #12]
	stur	xzr, [x0, #28]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	str	w20, [x8, #36]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB7_4:
	mov	x0, x19
	bl	__xtc_new_i32.cold.1
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_u64                   ; -- Begin function _xtc_new_u64
	.p2align	2
__xtc_new_u64:                          ; @_xtc_new_u64
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	tst	x0, #0x1fffffffffffe000
	b.eq	LBB8_2
; %bb.1:
	mov	w1, #8                          ; =0x8
	mov	x2, #0                          ; =0x0
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	__xtc_alloc_aligned
LBB8_2:
	mov	x19, x0
	lsl	x8, x0, #3
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB8_4
; %bb.3:
	mov	x8, x0
	mov	w9, #20290                      ; =0x4f42
	movk	w9, #22612, lsl #16
	str	w9, [x0]
	mov	w9, #8                          ; =0x8
	stur	x9, [x0, #4]
	stur	x19, [x0, #12]
	stur	xzr, [x0, #28]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	str	w20, [x8, #36]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB8_4:
	mov	x0, x19
	bl	__xtc_new_u64.cold.1
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_i64                   ; -- Begin function _xtc_new_i64
	.p2align	2
__xtc_new_i64:                          ; @_xtc_new_i64
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	tst	x0, #0x1fffffffffffe000
	b.eq	LBB9_2
; %bb.1:
	mov	w1, #8                          ; =0x8
	mov	x2, #0                          ; =0x0
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	__xtc_alloc_aligned
LBB9_2:
	mov	x19, x0
	lsl	x8, x0, #3
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB9_4
; %bb.3:
	mov	x8, x0
	mov	w9, #20290                      ; =0x4f42
	movk	w9, #22612, lsl #16
	str	w9, [x0]
	mov	w9, #8                          ; =0x8
	stur	x9, [x0, #4]
	stur	x19, [x0, #12]
	stur	xzr, [x0, #28]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	str	w20, [x8, #36]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB9_4:
	mov	x0, x19
	bl	__xtc_new_i64.cold.1
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_pointer               ; -- Begin function _xtc_new_pointer
	.p2align	2
__xtc_new_pointer:                      ; @_xtc_new_pointer
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
	lsl	x8, x0, #3
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB10_2
; %bb.1:
	mov	x8, x0
	mov	w9, #20290                      ; =0x4f42
	movk	w9, #22612, lsl #16
	str	w9, [x0]
	mov	w9, #8                          ; =0x8
	stur	x9, [x0, #4]
	stur	x19, [x0, #12]
	stur	xzr, [x0, #28]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	str	w20, [x8, #36]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB10_2:
	mov	x0, x19
	bl	__xtc_new_pointer.cold.1
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_bool                  ; -- Begin function _xtc_new_bool
	.p2align	2
__xtc_new_bool:                         ; @_xtc_new_bool
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	cmp	x0, #16, lsl #12                ; =65536
	b.lo	LBB11_2
; %bb.1:
	mov	w1, #1                          ; =0x1
	mov	x2, #0                          ; =0x0
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	__xtc_alloc_aligned
LBB11_2:
	mov	w8, #16                         ; =0x10
	cmp	x0, #16
	mov	x19, x0
	csel	x8, x0, x8, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB11_4
; %bb.3:
	mov	x8, x0
	mov	w9, #20290                      ; =0x4f42
	movk	w9, #22612, lsl #16
	str	w9, [x0]
	stur	x20, [x0, #4]
	stur	x19, [x0, #12]
	stur	xzr, [x0, #28]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	str	w20, [x8, #36]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB11_4:
	mov	x0, x19
	bl	__xtc_new_bool.cold.1
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_float                 ; -- Begin function _xtc_new_float
	.p2align	2
__xtc_new_float:                        ; @_xtc_new_float
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	tst	x0, #0x3fffffffffffc000
	b.eq	LBB12_2
; %bb.1:
	mov	w1, #4                          ; =0x4
	mov	x2, #0                          ; =0x0
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	__xtc_alloc_aligned
LBB12_2:
	mov	x19, x0
	lsl	x8, x0, #2
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB12_4
; %bb.3:
	mov	x8, x0
	mov	w9, #20290                      ; =0x4f42
	movk	w9, #22612, lsl #16
	str	w9, [x0]
	mov	w9, #4                          ; =0x4
	stur	x9, [x0, #4]
	stur	x19, [x0, #12]
	stur	xzr, [x0, #28]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	str	w20, [x8, #36]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB12_4:
	mov	x0, x19
	bl	__xtc_new_float.cold.1
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_double                ; -- Begin function _xtc_new_double
	.p2align	2
__xtc_new_double:                       ; @_xtc_new_double
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	tst	x0, #0x1fffffffffffe000
	b.eq	LBB13_2
; %bb.1:
	mov	w1, #8                          ; =0x8
	mov	x2, #0                          ; =0x0
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	__xtc_alloc_aligned
LBB13_2:
	mov	x19, x0
	lsl	x8, x0, #3
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB13_4
; %bb.3:
	mov	x8, x0
	mov	w9, #20290                      ; =0x4f42
	movk	w9, #22612, lsl #16
	str	w9, [x0]
	mov	w9, #8                          ; =0x8
	stur	x9, [x0, #4]
	stur	x19, [x0, #12]
	stur	xzr, [x0, #28]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	str	w20, [x8, #36]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB13_4:
	mov	x0, x19
	bl	__xtc_new_double.cold.1
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_string                ; -- Begin function _xtc_new_string
	.p2align	2
__xtc_new_string:                       ; @_xtc_new_string
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
	lsl	x8, x0, #3
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB14_2
; %bb.1:
	mov	x8, x0
	mov	w9, #20290                      ; =0x4f42
	movk	w9, #22612, lsl #16
	str	w9, [x0]
	mov	w9, #8                          ; =0x8
	stur	x9, [x0, #4]
	stur	x19, [x0, #12]
	stur	xzr, [x0, #28]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	str	w20, [x8, #36]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB14_2:
	mov	x0, x19
	bl	__xtc_new_string.cold.1
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
	cbz	w8, LBB15_2
; %bb.1:
Lloh18:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh19:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB15_2:
Lloh20:
	adrp	x8, _xt_simd_n@PAGE
Lloh21:
	ldr	x10, [x8, _xt_simd_n@PAGEOFF]
Lloh22:
	adrp	x8, _xt_simd_tab@PAGE
	mov	x9, #0                          ; =0x0
	cbz	x10, LBB15_5
; %bb.3:
	ldr	x11, [x8, _xt_simd_tab@PAGEOFF]
LBB15_4:                                ; =>This Inner Loop Header: Depth=1
	add	x12, x10, x9
	lsr	x13, x12, #1
	and	x12, x12, #0x1ffffffffffffffe
	ldr	x12, [x11, x12, lsl #3]
	cmp	x12, x19
	csel	x10, x13, x10, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x10
	b.lo	LBB15_4
LBB15_5:
	cbz	x9, LBB15_8
; %bb.6:
	ldr	x8, [x8, _xt_simd_tab@PAGEOFF]
	add	x8, x8, x9, lsl #4
	ldur	x9, [x8, #-8]
	cmp	x9, x19
	b.ls	LBB15_8
; %bb.7:
	ldur	x19, [x8, #-16]
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbnz	w8, LBB15_9
	b	LBB15_10
LBB15_8:
	mov	x19, #0                         ; =0x0
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB15_10
LBB15_9:
Lloh23:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh24:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB15_10:
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh18, Lloh19
	.loh AdrpAdrp	Lloh20, Lloh22
	.loh AdrpLdr	Lloh20, Lloh21
	.loh AdrpAdd	Lloh23, Lloh24
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_rt_lock                    ; -- Begin function _xt_rt_lock
	.p2align	2
__xt_rt_lock:                           ; @_xt_rt_lock
	.cfi_startproc
; %bb.0:
Lloh25:
	adrp	x8, __xt_threads_active@PAGE
Lloh26:
	ldr	w8, [x8, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB16_2
; %bb.1:
Lloh27:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh28:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	b	_pthread_mutex_lock
LBB16_2:
	ret
	.loh AdrpLdr	Lloh25, Lloh26
	.loh AdrpAdd	Lloh27, Lloh28
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_rt_unlock                  ; -- Begin function _xt_rt_unlock
	.p2align	2
__xt_rt_unlock:                         ; @_xt_rt_unlock
	.cfi_startproc
; %bb.0:
Lloh29:
	adrp	x8, __xt_threads_active@PAGE
Lloh30:
	ldr	w8, [x8, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB17_2
; %bb.1:
Lloh31:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh32:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	b	_pthread_mutex_unlock
LBB17_2:
	ret
	.loh AdrpLdr	Lloh29, Lloh30
	.loh AdrpAdd	Lloh31, Lloh32
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
	cbz	w8, LBB18_2
; %bb.1:
Lloh33:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh34:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB18_2:
Lloh35:
	adrp	x8, _xt_simd_n@PAGE
Lloh36:
	ldr	x10, [x8, _xt_simd_n@PAGEOFF]
Lloh37:
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
	cbz	x9, LBB18_7
; %bb.6:
	ldr	x8, [x8, _xt_simd_tab@PAGEOFF]
	add	x8, x8, x9, lsl #4
	ldur	x8, [x8, #-8]
	subs	x19, x8, x19
	b.hi	LBB18_8
LBB18_7:
	mov	x19, #-1                        ; =0xffffffffffffffff
LBB18_8:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB18_10
; %bb.9:
Lloh38:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh39:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB18_10:
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh33, Lloh34
	.loh AdrpAdrp	Lloh35, Lloh37
	.loh AdrpLdr	Lloh35, Lloh36
	.loh AdrpAdd	Lloh38, Lloh39
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_simd_watch                ; -- Begin function _xtc_simd_watch
	.p2align	2
__xtc_simd_watch:                       ; @_xtc_simd_watch
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
	cbz	w8, LBB19_2
; %bb.1:
Lloh40:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh41:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB19_2:
Lloh42:
	adrp	x8, _xt_simd_n@PAGE
Lloh43:
	ldr	x9, [x8, _xt_simd_n@PAGEOFF]
	adrp	x22, _xt_simd_tab@PAGE
	mov	x8, #0                          ; =0x0
	cbz	x9, LBB19_5
; %bb.3:
	ldr	x10, [x22, _xt_simd_tab@PAGEOFF]
LBB19_4:                                ; =>This Inner Loop Header: Depth=1
	add	x11, x9, x8
	lsr	x12, x11, #1
	and	x11, x11, #0x1ffffffffffffffe
	ldr	x11, [x10, x11, lsl #3]
	cmp	x11, x19
	csel	x9, x12, x9, hi
	csinc	x8, x8, x12, hi
	cmp	x8, x9
	b.lo	LBB19_4
LBB19_5:
	cbz	x8, LBB19_10
; %bb.6:
	ldr	x9, [x22, _xt_simd_tab@PAGEOFF]
	sub	x23, x8, #1
	lsl	x8, x23, #4
	ldr	x8, [x9, x8]
	cmp	x8, x19
	b.ne	LBB19_10
; %bb.7:
	adrp	x24, _xt_simd_installed@PAGE
	ldrb	w8, [x24, _xt_simd_installed@PAGEOFF]
	tbnz	w8, #0, LBB19_9
; %bb.8:
Lloh44:
	adrp	x8, _xt_simd_fault@PAGE
Lloh45:
	add	x8, x8, _xt_simd_fault@PAGEOFF
	mov	x9, #343597383680               ; =0x5000000000
	stp	x8, x9, [sp]
Lloh46:
	adrp	x20, _xt_simd_old@PAGE
Lloh47:
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
LBB19_9:
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
	cbz	w0, LBB19_13
LBB19_10:
	mov	w19, #0                         ; =0x0
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB19_12
LBB19_11:
Lloh48:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh49:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB19_12:
	mov	x0, x19
	ldp	x29, x30, [sp, #64]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #48]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #32]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #80
	ret
LBB19_13:
Lloh50:
	adrp	x8, _xt_simd_flag@PAGE
Lloh51:
	ldr	x8, [x8, _xt_simd_flag@PAGEOFF]
	ldrb	w9, [x8, x23]
	orr	w9, w9, #0x1
	strb	w9, [x8, x23]
	mov	w19, #1                         ; =0x1
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbnz	w8, LBB19_11
	b	LBB19_12
	.loh AdrpAdd	Lloh40, Lloh41
	.loh AdrpLdr	Lloh42, Lloh43
	.loh AdrpAdd	Lloh46, Lloh47
	.loh AdrpAdd	Lloh44, Lloh45
	.loh AdrpAdd	Lloh48, Lloh49
	.loh AdrpLdr	Lloh50, Lloh51
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
	ldr	x21, [x1, #24]
	adrp	x20, __xt_threads_active@PAGE
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB20_2
; %bb.1:
Lloh52:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh53:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB20_2:
Lloh54:
	adrp	x8, _xt_simd_n@PAGE
Lloh55:
	ldr	x10, [x8, _xt_simd_n@PAGEOFF]
Lloh56:
	adrp	x8, _xt_simd_tab@PAGE
	mov	x9, #0                          ; =0x0
	cbz	x10, LBB20_5
; %bb.3:
	ldr	x11, [x8, _xt_simd_tab@PAGEOFF]
LBB20_4:                                ; =>This Inner Loop Header: Depth=1
	add	x12, x10, x9
	lsr	x13, x12, #1
	and	x12, x12, #0x1ffffffffffffffe
	ldr	x12, [x11, x12, lsl #3]
	cmp	x12, x21
	csel	x10, x13, x10, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x10
	b.lo	LBB20_4
LBB20_5:
	cbz	x9, LBB20_8
; %bb.6:
	ldr	x8, [x8, _xt_simd_tab@PAGEOFF]
	sub	x10, x9, #1
	add	x9, x8, x10, lsl #4
	ldr	x9, [x9, #8]
	cmp	x21, x9
	b.hs	LBB20_8
; %bb.7:
Lloh57:
	adrp	x11, _xt_simd_flag@PAGE
Lloh58:
	ldr	x11, [x11, _xt_simd_flag@PAGEOFF]
	ldrb	w12, [x11, x10]
	tbnz	w12, #0, LBB20_11
LBB20_8:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB20_10
; %bb.9:
Lloh59:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh60:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB20_10:
	cmp	w19, #11
	cset	w8, ne
Lloh61:
	adrp	x9, _xt_simd_old@PAGE
Lloh62:
	add	x9, x9, _xt_simd_old@PAGEOFF
	add	x1, x9, w8, uxtw #4
	mov	x0, x19
	mov	x2, #0                          ; =0x0
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	b	_sigaction
LBB20_11:
	and	w12, w12, #0xfe
	strb	w12, [x11, x10]
	lsl	x10, x10, #1
	ldr	x0, [x8, x10, lsl #3]
	mov	w8, #16383                      ; =0x3fff
	sub	x9, x9, x0
	add	x8, x9, x8
	and	x1, x8, #0xffffffffffffc000
	mov	w2, #3                          ; =0x3
	bl	_mprotect
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB20_13
; %bb.12:
Lloh63:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh64:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB20_13:
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh52, Lloh53
	.loh AdrpAdrp	Lloh54, Lloh56
	.loh AdrpLdr	Lloh54, Lloh55
	.loh AdrpLdr	Lloh57, Lloh58
	.loh AdrpAdd	Lloh59, Lloh60
	.loh AdrpAdd	Lloh61, Lloh62
	.loh AdrpAdd	Lloh63, Lloh64
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
	cbz	w8, LBB21_2
; %bb.1:
Lloh65:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh66:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB21_2:
Lloh67:
	adrp	x8, _xt_simd_n@PAGE
Lloh68:
	ldr	x10, [x8, _xt_simd_n@PAGEOFF]
Lloh69:
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
	cbz	x9, LBB21_9
; %bb.6:
	ldr	x8, [x8, _xt_simd_tab@PAGEOFF]
	sub	x9, x9, #1
	lsl	x10, x9, #4
	ldr	x10, [x8, x10]
	cmp	x10, x19
	b.ne	LBB21_9
; %bb.7:
Lloh70:
	adrp	x10, _xt_simd_flag@PAGE
Lloh71:
	ldr	x10, [x10, _xt_simd_flag@PAGEOFF]
	ldrb	w11, [x10, x9]
	tbz	w11, #0, LBB21_9
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
LBB21_9:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB21_11
; %bb.10:
Lloh72:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh73:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB21_11:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh65, Lloh66
	.loh AdrpAdrp	Lloh67, Lloh69
	.loh AdrpLdr	Lloh67, Lloh68
	.loh AdrpLdr	Lloh70, Lloh71
	.loh AdrpAdd	Lloh72, Lloh73
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
	cbz	w8, LBB22_2
; %bb.1:
Lloh74:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh75:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB22_2:
Lloh76:
	adrp	x8, _xt_simd_n@PAGE
Lloh77:
	ldr	x10, [x8, _xt_simd_n@PAGEOFF]
Lloh78:
	adrp	x8, _xt_simd_tab@PAGE
	mov	x9, #0                          ; =0x0
	cbz	x10, LBB22_5
; %bb.3:
	ldr	x11, [x8, _xt_simd_tab@PAGEOFF]
LBB22_4:                                ; =>This Inner Loop Header: Depth=1
	add	x12, x10, x9
	lsr	x13, x12, #1
	and	x12, x12, #0x1ffffffffffffffe
	ldr	x12, [x11, x12, lsl #3]
	cmp	x12, x19
	csel	x10, x13, x10, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x10
	b.lo	LBB22_4
LBB22_5:
	cbz	x9, LBB22_8
; %bb.6:
	ldr	x10, [x8, _xt_simd_tab@PAGEOFF]
	sub	x8, x9, #1
	lsl	x9, x8, #4
	ldr	x9, [x10, x9]
	mov	w20, #1                         ; =0x1
	cmp	x9, x19
	b.ne	LBB22_9
; %bb.7:
Lloh79:
	adrp	x9, _xt_simd_flag@PAGE
Lloh80:
	ldr	x9, [x9, _xt_simd_flag@PAGEOFF]
	ldrb	w8, [x9, x8]
	bic	w20, w20, w8
	b	LBB22_9
LBB22_8:
	mov	w20, #1                         ; =0x1
LBB22_9:
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB22_11
; %bb.10:
Lloh81:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh82:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB22_11:
	mov	x0, x20
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh74, Lloh75
	.loh AdrpAdrp	Lloh76, Lloh78
	.loh AdrpLdr	Lloh76, Lloh77
	.loh AdrpLdr	Lloh79, Lloh80
	.loh AdrpAdd	Lloh81, Lloh82
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
	.globl	__xtc_count                     ; -- Begin function _xtc_count
	.p2align	2
__xtc_count:                            ; @_xtc_count
	.cfi_startproc
; %bb.0:
	ldur	x0, [x0, #-28]
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
	adrp	x20, __xt_threads_active@PAGE
	cbz	x0, LBB37_7
; %bb.1:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB37_3
; %bb.2:
Lloh83:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh84:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB37_3:
	ldur	x8, [x19, #-12]
	cbz	x8, LBB37_5
LBB37_4:                                ; =>This Inner Loop Header: Depth=1
	ldur	x9, [x8, #-8]
	stp	xzr, xzr, [x8, #-8]
	stur	xzr, [x8, #-16]
	mov	x8, x9
	cbnz	x9, LBB37_4
LBB37_5:
	stur	xzr, [x19, #-12]
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB37_7
; %bb.6:
Lloh85:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh86:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB37_7:
	mov	x0, x19
	ldr	w8, [x0, #-40]!
	ldur	x21, [x0, #20]
	mov	w9, #20291                      ; =0x4f43
	movk	w9, #22612, lsl #16
	cmp	w8, w9
	b.ne	LBB37_24
; %bb.8:
	cbz	x21, LBB37_10
; %bb.9:
	mov	x0, x19
	blr	x21
LBB37_10:
	mov	x0, x19
	bl	__xtc_simd_unwatch
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB37_12
; %bb.11:
Lloh87:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh88:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB37_12:
	adrp	x8, _xt_simd_n@PAGE
	ldr	x9, [x8, _xt_simd_n@PAGEOFF]
	adrp	x11, _xt_simd_tab@PAGE
	mov	x10, #0                         ; =0x0
	cbz	x9, LBB37_15
; %bb.13:
	ldr	x12, [x11, _xt_simd_tab@PAGEOFF]
	mov	x13, x9
LBB37_14:                               ; =>This Inner Loop Header: Depth=1
	add	x14, x13, x10
	lsr	x15, x14, #1
	and	x14, x14, #0x1ffffffffffffffe
	ldr	x14, [x12, x14, lsl #3]
	cmp	x14, x19
	csel	x13, x15, x13, hi
	csinc	x10, x10, x15, hi
	cmp	x10, x13
	b.lo	LBB37_14
LBB37_15:
	cbz	x10, LBB37_21
; %bb.16:
	ldr	x11, [x11, _xt_simd_tab@PAGEOFF]
	add	x11, x11, x10, lsl #4
	ldur	x12, [x11, #-16]
	cmp	x12, x19
	b.ne	LBB37_21
; %bb.17:
	subs	x12, x9, x10
	b.ls	LBB37_20
; %bb.18:
Lloh89:
	adrp	x13, _xt_simd_flag@PAGE
Lloh90:
	ldr	x13, [x13, _xt_simd_flag@PAGEOFF]
	add	x10, x13, x10
LBB37_19:                               ; =>This Inner Loop Header: Depth=1
	ldp	x13, x14, [x11]
	stp	x13, x14, [x11, #-16]
	ldrb	w13, [x10]
	sturb	w13, [x10, #-1]
	add	x10, x10, #1
	add	x11, x11, #16
	subs	x12, x12, #1
	b.ne	LBB37_19
LBB37_20:
	sub	x9, x9, #1
	str	x9, [x8, _xt_simd_n@PAGEOFF]
LBB37_21:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB37_23
; %bb.22:
Lloh91:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh92:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB37_23:
	ldur	x0, [x19, #-48]
	b	LBB37_29
LBB37_24:
	cbz	x21, LBB37_29
; %bb.25:
	ldur	x20, [x0, #4]
	ldur	x22, [x0, #12]
	mov	w8, #-2147483648                ; =0x80000000
	stur	w8, [x19, #-4]
	cbz	x22, LBB37_29
; %bb.26:
	mov	x23, x0
LBB37_27:                               ; =>This Inner Loop Header: Depth=1
	mov	x0, x19
	blr	x21
	add	x19, x19, x20
	subs	x22, x22, #1
	b.ne	LBB37_27
; %bb.28:
	mov	x0, x23
LBB37_29:
	ldp	x29, x30, [sp, #48]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #32]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #16]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp], #64             ; 16-byte Folded Reload
	b	_free
	.loh AdrpAdd	Lloh83, Lloh84
	.loh AdrpAdd	Lloh85, Lloh86
	.loh AdrpAdd	Lloh87, Lloh88
	.loh AdrpLdr	Lloh89, Lloh90
	.loh AdrpAdd	Lloh91, Lloh92
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_weak_zero_for             ; -- Begin function _xtc_weak_zero_for
	.p2align	2
__xtc_weak_zero_for:                    ; @_xtc_weak_zero_for
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB38_7
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
	cbz	w8, LBB38_3
; %bb.2:
Lloh93:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh94:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB38_3:
	ldur	x8, [x19, #-12]
	cbz	x8, LBB38_5
LBB38_4:                                ; =>This Inner Loop Header: Depth=1
	ldur	x9, [x8, #-8]
	stp	xzr, xzr, [x8, #-8]
	stur	xzr, [x8, #-16]
	mov	x8, x9
	cbnz	x9, LBB38_4
LBB38_5:
	stur	xzr, [x19, #-12]
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	cbz	w8, LBB38_7
; %bb.6:
Lloh95:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh96:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	b	_pthread_mutex_unlock
LBB38_7:
	ret
	.loh AdrpAdd	Lloh93, Lloh94
	.loh AdrpAdd	Lloh95, Lloh96
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
	cbz	w8, LBB39_2
; %bb.1:
Lloh97:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh98:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB39_2:
	mov	x8, x19
	ldr	x9, [x8, #-16]!
	cbz	x9, LBB39_7
; %bb.3:
	ldr	x10, [x9]
	cmp	x10, x19
	b.ne	LBB39_6
; %bb.4:
	ldur	x10, [x19, #-8]
	str	x10, [x9]
	cbz	x10, LBB39_6
; %bb.5:
	stur	x9, [x10, #-16]
LBB39_6:
	stp	xzr, xzr, [x8]
LBB39_7:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB39_9
; %bb.8:
Lloh99:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh100:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB39_9:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh97, Lloh98
	.loh AdrpAdd	Lloh99, Lloh100
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_weak_register             ; -- Begin function _xtc_weak_register
	.p2align	2
__xtc_weak_register:                    ; @_xtc_weak_register
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
	mov	x19, x1
	mov	x20, x0
	adrp	x21, __xt_threads_active@PAGE
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB40_2
; %bb.1:
Lloh101:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh102:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB40_2:
	mov	x8, x20
	ldr	x9, [x8, #-16]!
	cbz	x9, LBB40_7
; %bb.3:
	ldr	x10, [x9]
	cmp	x10, x20
	b.ne	LBB40_6
; %bb.4:
	ldur	x10, [x20, #-8]
	str	x10, [x9]
	cbz	x10, LBB40_6
; %bb.5:
	stur	x9, [x10, #-16]
LBB40_6:
	stp	xzr, xzr, [x8]
LBB40_7:
	cbz	x19, LBB40_12
; %bb.8:
	ldur	w8, [x19, #-40]
	mov	w9, #10145                      ; =0x27a1
	movk	w9, #11306, lsl #16
	cmp	w9, w8, lsr #1
	b.ne	LBB40_12
; %bb.9:
	ldr	x8, [x19, #-12]!
	mov	x9, x20
	str	x8, [x9, #-8]!
	stur	x19, [x9, #-8]
	cbz	x8, LBB40_11
; %bb.10:
	stur	x9, [x8, #-16]
LBB40_11:
	str	x20, [x19]
LBB40_12:
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB40_14
; %bb.13:
Lloh103:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh104:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB40_14:
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh101, Lloh102
	.loh AdrpAdd	Lloh103, Lloh104
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
Lloh105:
	adrp	x2, l_.str.1@PAGE
Lloh106:
	add	x2, x2, l_.str.1@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB43_1:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB43_1
; %bb.2:
	sub	x2, x8, #1
	add	x1, sp, #16
	mov	w0, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.loh AdrpAdd	Lloh105, Lloh106
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
Lloh107:
	adrp	x2, l_.str.2@PAGE
Lloh108:
	add	x2, x2, l_.str.2@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB44_1:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB44_1
; %bb.2:
	sub	x2, x8, #1
	add	x1, sp, #16
	mov	w0, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.loh AdrpAdd	Lloh107, Lloh108
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
	cbz	w0, LBB45_7
; %bb.1:
	add	w8, w0, #1
	str	d0, [sp, #8]
	str	x8, [sp]
Lloh109:
	adrp	x2, l_.str.5@PAGE
Lloh110:
	add	x2, x2, l_.str.5@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB45_2:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB45_2
; %bb.3:
	cmp	x8, #1
	b.eq	LBB45_5
; %bb.4:
	add	x9, sp, #16
	add	x8, x9, x8
	sturb	wzr, [x8, #-2]
LBB45_5:
	mov	x8, #0                          ; =0x0
	add	x9, sp, #16
LBB45_6:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w10, [x9, x8]
	add	x8, x8, #1
	cbnz	w10, LBB45_6
	b	LBB45_9
LBB45_7:
	str	d0, [sp]
Lloh111:
	adrp	x2, l_.str.1@PAGE
Lloh112:
	add	x2, x2, l_.str.1@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB45_8:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB45_8
LBB45_9:
	sub	x2, x8, #1
	add	x1, sp, #16
	mov	w0, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.loh AdrpAdd	Lloh109, Lloh110
	.loh AdrpAdd	Lloh111, Lloh112
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
	cbz	w0, LBB46_7
; %bb.1:
	add	w8, w0, #1
	str	d0, [sp, #8]
	str	x8, [sp]
Lloh113:
	adrp	x2, l_.str.5@PAGE
Lloh114:
	add	x2, x2, l_.str.5@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB46_2:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB46_2
; %bb.3:
	cmp	x8, #1
	b.eq	LBB46_5
; %bb.4:
	add	x9, sp, #16
	add	x8, x9, x8
	sturb	wzr, [x8, #-2]
LBB46_5:
	mov	x8, #0                          ; =0x0
	add	x9, sp, #16
LBB46_6:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w10, [x9, x8]
	add	x8, x8, #1
	cbnz	w10, LBB46_6
	b	LBB46_9
LBB46_7:
	str	d0, [sp]
Lloh115:
	adrp	x2, l_.str.2@PAGE
Lloh116:
	add	x2, x2, l_.str.2@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB46_8:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB46_8
LBB46_9:
	sub	x2, x8, #1
	add	x1, sp, #16
	mov	w0, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.loh AdrpAdd	Lloh113, Lloh114
	.loh AdrpAdd	Lloh115, Lloh116
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
	tbnz	w8, #0, LBB64_2
; %bb.1:
	mov	w20, #1                         ; =0x1
	mov	w0, #1                          ; =0x1
	bl	_srandom
	strb	w20, [x19, _xt_rand_seeded@PAGEOFF]
LBB64_2:
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
	tbnz	w8, #0, LBB65_2
; %bb.1:
	mov	w20, #1                         ; =0x1
	mov	w0, #1                          ; =0x1
	bl	_srandom
	strb	w20, [x19, _xt_rand_seeded@PAGEOFF]
LBB65_2:
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
	tbnz	w8, #0, LBB66_2
; %bb.1:
	mov	w20, #1                         ; =0x1
	mov	w0, #1                          ; =0x1
	bl	_srandom
	strb	w20, [x19, _xt_rand_seeded@PAGEOFF]
LBB66_2:
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
Lloh117:
	adrp	x8, _xt_clk_origin@PAGE
Lloh118:
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
	.loh AdrpLdr	Lloh117, Lloh118
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
	b.ls	LBB70_2
; %bb.1:
	mov	x0, #0                          ; =0x0
	ret
LBB70_2:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	w8, w0
Lloh119:
	adrp	x9, __xtc_bank_regions@PAGE
Lloh120:
	add	x9, x9, __xtc_bank_regions@PAGEOFF
	add	x19, x9, x8, lsl #11
	ldr	x8, [x19, w1, uxtw #3]
	cbnz	x8, LBB70_4
; %bb.3:
	mov	w0, #1                          ; =0x1
	mov	x20, x1
	mov	w1, #12288                      ; =0x3000
	bl	_calloc
	mov	x1, x20
	str	x0, [x19, w20, uxtw #3]
LBB70_4:
	ldr	x0, [x19, w1, uxtw #3]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh119, Lloh120
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
Lloh121:
	adrp	x20, _xt_files@PAGE
Lloh122:
	add	x20, x20, _xt_files@PAGEOFF
LBB71_1:                                ; =>This Inner Loop Header: Depth=1
	ldr	x8, [x20, x19, lsl #3]
	cbz	x8, LBB71_3
; %bb.2:                                ;   in Loop: Header=BB71_1 Depth=1
	add	x19, x19, #1
	cmp	x19, #8
	b.ne	LBB71_1
	b	LBB71_5
LBB71_3:
	bl	_fopen
	cbz	x0, LBB71_5
; %bb.4:
	str	x0, [x20, x19, lsl #3]
	b	LBB71_6
LBB71_5:
	mov	w19, #-1                        ; =0xffffffff
LBB71_6:
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh121, Lloh122
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_read                  ; -- Begin function _xt_file_read
	.p2align	2
__xt_file_read:                         ; @_xt_file_read
	.cfi_startproc
; %bb.0:
	cmp	w0, #7
	b.hi	LBB72_3
; %bb.1:
Lloh123:
	adrp	x8, _xt_files@PAGE
Lloh124:
	add	x8, x8, _xt_files@PAGEOFF
	ldr	x3, [x8, w0, uxtw #3]
	cbz	x3, LBB72_3
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
LBB72_3:
	mov	w0, #-1                         ; =0xffffffff
                                        ; kill: def $w0 killed $w0 killed $x0
	ret
	.loh AdrpAdd	Lloh123, Lloh124
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_write                 ; -- Begin function _xt_file_write
	.p2align	2
__xt_file_write:                        ; @_xt_file_write
	.cfi_startproc
; %bb.0:
	cmp	w0, #7
	b.hi	LBB73_3
; %bb.1:
Lloh125:
	adrp	x8, _xt_files@PAGE
Lloh126:
	add	x8, x8, _xt_files@PAGEOFF
	ldr	x3, [x8, w0, uxtw #3]
	cbz	x3, LBB73_3
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
LBB73_3:
	mov	w0, #-1                         ; =0xffffffff
                                        ; kill: def $w0 killed $w0 killed $x0
	ret
	.loh AdrpAdd	Lloh125, Lloh126
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_close                 ; -- Begin function _xt_file_close
	.p2align	2
__xt_file_close:                        ; @_xt_file_close
	.cfi_startproc
; %bb.0:
	cmp	w0, #7
	b.hi	LBB74_4
; %bb.1:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
Lloh127:
	adrp	x19, _xt_files@PAGE
Lloh128:
	add	x19, x19, _xt_files@PAGEOFF
	ldr	x8, [x19, w0, uxtw #3]
	cbz	x8, LBB74_3
; %bb.2:
	mov	x20, x0
	mov	x0, x8
	bl	_fclose
	str	xzr, [x19, w20, uxtw #3]
LBB74_3:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
LBB74_4:
	ret
	.loh AdrpAdd	Lloh127, Lloh128
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
Lloh129:
	adrp	x1, l_.str.3@PAGE
Lloh130:
	add	x1, x1, l_.str.3@PAGEOFF
	bl	_fopen
	cbz	x0, LBB75_3
; %bb.1:
	mov	x19, x0
	mov	x1, #0                          ; =0x0
	mov	w2, #2                          ; =0x2
	bl	_fseek
	cbz	w0, LBB75_4
; %bb.2:
	mov	x0, x19
	bl	_fclose
LBB75_3:
	mov	w0, #-1                         ; =0xffffffff
	b	LBB75_5
LBB75_4:
	mov	x0, x19
	bl	_ftell
	mov	x20, x0
	mov	x0, x19
	bl	_fclose
	cmp	x20, #0
	csinv	w0, w20, wzr, ge
LBB75_5:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh129, Lloh130
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
Lloh131:
	adrp	x1, l_.str.3@PAGE
Lloh132:
	add	x1, x1, l_.str.3@PAGEOFF
	bl	_fopen
	cbz	x0, LBB76_2
; %bb.1:
	bl	_fclose
	mov	w0, #1                          ; =0x1
LBB76_2:
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh131, Lloh132
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
Lloh133:
	adrp	x8, l_.str.4@PAGE
Lloh134:
	add	x8, x8, l_.str.4@PAGEOFF
	cmp	x0, #0
	csel	x0, x8, x0, eq
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh133, Lloh134
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
	cbz	w0, LBB78_2
; %bb.1:
	bl	___error
	ldr	w8, [x0]
	cmp	w8, #17
	cset	w0, eq
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
LBB78_2:
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
	.globl	__xt_set_args                   ; -- Begin function _xt_set_args
	.p2align	2
__xt_set_args:                          ; @_xt_set_args
	.cfi_startproc
; %bb.0:
Lloh135:
	adrp	x8, _xt_argc_v@PAGE
	str	w0, [x8, _xt_argc_v@PAGEOFF]
Lloh136:
	adrp	x8, _xt_argv_v@PAGE
	str	x1, [x8, _xt_argv_v@PAGEOFF]
	ret
	.loh AdrpAdrp	Lloh135, Lloh136
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_argc                       ; -- Begin function _xt_argc
	.p2align	2
__xt_argc:                              ; @_xt_argc
	.cfi_startproc
; %bb.0:
Lloh137:
	adrp	x8, _xt_argc_v@PAGE
Lloh138:
	ldr	w0, [x8, _xt_argc_v@PAGEOFF]
	ret
	.loh AdrpLdr	Lloh137, Lloh138
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_argv                       ; -- Begin function _xt_argv
	.p2align	2
__xt_argv:                              ; @_xt_argv
	.cfi_startproc
; %bb.0:
	tbnz	w0, #31, LBB82_2
; %bb.1:
Lloh139:
	adrp	x8, _xt_argc_v@PAGE
Lloh140:
	ldr	w9, [x8, _xt_argc_v@PAGEOFF]
Lloh141:
	adrp	x8, _xt_argv_v@PAGE
Lloh142:
	ldr	x8, [x8, _xt_argv_v@PAGEOFF]
	cmp	w9, w0
	ccmp	x8, #0, #4, gt
	b.ne	LBB82_3
LBB82_2:
Lloh143:
	adrp	x0, l_.str.4@PAGE
Lloh144:
	add	x0, x0, l_.str.4@PAGEOFF
	ret
LBB82_3:
	ldr	x0, [x8, w0, uxtw #3]
	ret
	.loh AdrpLdr	Lloh141, Lloh142
	.loh AdrpAdrp	Lloh139, Lloh141
	.loh AdrpLdr	Lloh139, Lloh140
	.loh AdrpAdd	Lloh143, Lloh144
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
	cbz	x0, LBB84_4
; %bb.1:
	sub	x21, x0, x20
	cmp	x21, #1023
	b.hi	LBB84_11
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
	b.ne	LBB84_6
; %bb.3:
	mov	w8, #47                         ; =0x2f
	b	LBB84_5
LBB84_4:
	mov	w8, #46                         ; =0x2e
LBB84_5:
	strb	w8, [sp]
	strb	wzr, [sp, #1]
LBB84_6:
	mov	x0, sp
	bl	_opendir
	cbz	x0, LBB84_11
; %bb.7:
	mov	x20, x0
LBB84_8:                                ; =>This Inner Loop Header: Depth=1
	mov	x0, x20
	bl	_readdir
	cbz	x0, LBB84_12
; %bb.9:                                ;   in Loop: Header=BB84_8 Depth=1
	add	x0, x0, #21
	mov	x1, x19
	bl	_strcmp
	cbnz	w0, LBB84_8
; %bb.10:
	mov	w19, #1                         ; =0x1
	b	LBB84_13
LBB84_11:
	mov	w19, #0                         ; =0x0
	b	LBB84_14
LBB84_12:
	mov	w19, #0                         ; =0x0
LBB84_13:
	mov	x0, x20
	bl	_closedir
LBB84_14:
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
Lloh145:
	adrp	x8, __xt_threads_active@PAGE
Lloh146:
	ldr	w0, [x8, __xt_threads_active@PAGEOFF]
	ret
	.loh AdrpLdr	Lloh145, Lloh146
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_thread_create              ; -- Begin function _xt_thread_create
	.p2align	2
__xt_thread_create:                     ; @_xt_thread_create
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB86_11
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
	cbnz	w8, LBB86_3
; %bb.2:
Lloh147:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh148:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	mov	x1, #0                          ; =0x0
	bl	_pthread_mutex_init
	mov	w8, #1                          ; =0x1
	str	w8, [x19, __xt_threads_active@PAGEOFF]
LBB86_3:
	mov	w0, #16                         ; =0x10
	bl	_malloc
	cbz	x0, LBB86_10
; %bb.4:
	mov	x19, x0
	stp	x21, x20, [x0]
	mov	w0, #8                          ; =0x8
	bl	_malloc
	cbz	x0, LBB86_7
; %bb.5:
Lloh149:
	adrp	x2, _xt_thread_entry@PAGE
Lloh150:
	add	x2, x2, _xt_thread_entry@PAGEOFF
	mov	x20, x0
	mov	x1, #0                          ; =0x0
	mov	x3, x19
	bl	_pthread_create
	cbz	w0, LBB86_9
; %bb.6:
	mov	x0, x19
	bl	_free
	mov	x0, x20
	b	LBB86_8
LBB86_7:
	mov	x0, x19
LBB86_8:
	bl	_free
	mov	x0, #0                          ; =0x0
	b	LBB86_10
LBB86_9:
	mov	x0, x20
LBB86_10:
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
LBB86_11:
	ret
	.loh AdrpAdd	Lloh147, Lloh148
	.loh AdrpAdd	Lloh149, Lloh150
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
	cbz	x20, LBB87_2
; %bb.1:
	mov	x0, x19
	blr	x20
LBB87_2:
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
	cbz	x0, LBB88_2
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
LBB88_2:
	mov	w0, #-1                         ; =0xffffffff
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_thread_detach              ; -- Begin function _xt_thread_detach
	.p2align	2
__xt_thread_detach:                     ; @_xt_thread_detach
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB89_2
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
LBB89_2:
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
	cbz	x0, LBB94_4
; %bb.1:
	mov	x19, x0
	mov	x1, #0                          ; =0x0
	bl	_pthread_mutex_init
	cbz	w0, LBB94_3
; %bb.2:
	mov	x0, x19
	bl	_free
	mov	x0, #0                          ; =0x0
	b	LBB94_4
LBB94_3:
	mov	x0, x19
LBB94_4:
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
	cbz	x0, LBB95_2
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
LBB95_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_mutex_lock                 ; -- Begin function _xt_mutex_lock
	.p2align	2
__xt_mutex_lock:                        ; @_xt_mutex_lock
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB96_2
; %bb.1:
	b	_pthread_mutex_lock
LBB96_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_mutex_unlock               ; -- Begin function _xt_mutex_unlock
	.p2align	2
__xt_mutex_unlock:                      ; @_xt_mutex_unlock
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB97_2
; %bb.1:
	b	_pthread_mutex_unlock
LBB97_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_mutex_trylock              ; -- Begin function _xt_mutex_trylock
	.p2align	2
__xt_mutex_trylock:                     ; @_xt_mutex_trylock
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB98_2
; %bb.1:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	.cfi_def_cfa_offset 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	bl	_pthread_mutex_trylock
	cmp	w0, #0
	cset	w0, eq
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
LBB98_2:
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
	cbz	x0, LBB99_4
; %bb.1:
	mov	x19, x0
	mov	x1, #0                          ; =0x0
	bl	_pthread_cond_init
	cbz	w0, LBB99_3
; %bb.2:
	mov	x0, x19
	bl	_free
	mov	x0, #0                          ; =0x0
	b	LBB99_4
LBB99_3:
	mov	x0, x19
LBB99_4:
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
	cbz	x0, LBB100_2
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
LBB100_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_cond_wait                  ; -- Begin function _xt_cond_wait
	.p2align	2
__xt_cond_wait:                         ; @_xt_cond_wait
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB101_3
; %bb.1:
	cbz	x1, LBB101_3
; %bb.2:
	b	_pthread_cond_wait
LBB101_3:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_cond_signal                ; -- Begin function _xt_cond_signal
	.p2align	2
__xt_cond_signal:                       ; @_xt_cond_signal
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB102_2
; %bb.1:
	b	_pthread_cond_signal
LBB102_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_cond_broadcast             ; -- Begin function _xt_cond_broadcast
	.p2align	2
__xt_cond_broadcast:                    ; @_xt_cond_broadcast
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB103_2
; %bb.1:
	b	_pthread_cond_broadcast
LBB103_2:
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
	cbz	x0, LBB104_5
; %bb.1:
	mov	x20, x0
	mov	x1, #0                          ; =0x0
	bl	_pthread_mutex_init
	cbnz	w0, LBB104_4
; %bb.2:
	add	x0, x20, #64
	mov	x1, #0                          ; =0x0
	bl	_pthread_cond_init
	cbz	w0, LBB104_6
; %bb.3:
	mov	x0, x20
	bl	_pthread_mutex_destroy
LBB104_4:
	mov	x0, x20
	bl	_free
	mov	x0, #0                          ; =0x0
LBB104_5:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB104_6:
	bic	w8, w19, w19, asr #31
	mov	x0, x20
	str	w8, [x20, #112]
	b	LBB104_5
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_sem_free                   ; -- Begin function _xt_sem_free
	.p2align	2
__xt_sem_free:                          ; @_xt_sem_free
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB105_2
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
LBB105_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_sem_wait                   ; -- Begin function _xt_sem_wait
	.p2align	2
__xt_sem_wait:                          ; @_xt_sem_wait
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB106_4
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
	b.gt	LBB106_3
LBB106_2:                               ; =>This Inner Loop Header: Depth=1
	add	x0, x19, #64
	mov	x1, x19
	bl	_pthread_cond_wait
	ldr	w8, [x19, #112]
	cmp	w8, #1
	b.lt	LBB106_2
LBB106_3:
	sub	w8, w8, #1
	str	w8, [x19, #112]
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB106_4:
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
	cbz	x0, LBB107_3
; %bb.1:
	mov	x19, x0
	bl	_pthread_mutex_lock
	ldr	w8, [x19, #112]
	subs	w8, w8, #1
	b.lt	LBB107_4
; %bb.2:
	str	w8, [x19, #112]
	mov	w20, #1                         ; =0x1
	b	LBB107_5
LBB107_3:
	mov	w20, #0                         ; =0x0
	b	LBB107_6
LBB107_4:
	mov	w20, #0                         ; =0x0
LBB107_5:
	mov	x0, x19
	bl	_pthread_mutex_unlock
LBB107_6:
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
	cbz	x0, LBB108_2
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
LBB108_2:
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
	b.eq	LBB110_2
; %bb.1:
	mov	w0, w0
	b	_pthread_setspecific
LBB110_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_tls_get                    ; -- Begin function _xt_tls_get
	.p2align	2
__xt_tls_get:                           ; @_xt_tls_get
	.cfi_startproc
; %bb.0:
	cmn	w0, #1
	b.eq	LBB111_2
; %bb.1:
	mov	w0, w0
	b	_pthread_getspecific
LBB111_2:
	mov	x0, #0                          ; =0x0
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_load_i32            ; -- Begin function _xt_atomic_load_i32
	.p2align	2
__xt_atomic_load_i32:                   ; @_xt_atomic_load_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB112_2
; %bb.1:
	ldar	w0, [x0]
LBB112_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_store_i32           ; -- Begin function _xt_atomic_store_i32
	.p2align	2
__xt_atomic_store_i32:                  ; @_xt_atomic_store_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB113_2
; %bb.1:
	stlr	w1, [x0]
LBB113_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_add_i32             ; -- Begin function _xt_atomic_add_i32
	.p2align	2
__xt_atomic_add_i32:                    ; @_xt_atomic_add_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB114_2
; %bb.1:
	ldaddal	w1, w8, [x0]
	add	w0, w8, w1
LBB114_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_xchg_i32            ; -- Begin function _xt_atomic_xchg_i32
	.p2align	2
__xt_atomic_xchg_i32:                   ; @_xt_atomic_xchg_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB115_2
; %bb.1:
	swpal	w1, w0, [x0]
LBB115_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_cas_i32             ; -- Begin function _xt_atomic_cas_i32
	.p2align	2
__xt_atomic_cas_i32:                    ; @_xt_atomic_cas_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB116_2
; %bb.1:
	mov	x8, x1
	casal	w8, w2, [x0]
	cmp	w8, w1
	cset	w0, eq
LBB116_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_load_ptr            ; -- Begin function _xt_atomic_load_ptr
	.p2align	2
__xt_atomic_load_ptr:                   ; @_xt_atomic_load_ptr
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB117_2
; %bb.1:
	ldar	x0, [x0]
LBB117_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_store_ptr           ; -- Begin function _xt_atomic_store_ptr
	.p2align	2
__xt_atomic_store_ptr:                  ; @_xt_atomic_store_ptr
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB118_2
; %bb.1:
	stlr	x1, [x0]
LBB118_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_cas_ptr             ; -- Begin function _xt_atomic_cas_ptr
	.p2align	2
__xt_atomic_cas_ptr:                    ; @_xt_atomic_cas_ptr
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB119_2
; %bb.1:
	mov	x8, x1
	casal	x8, x2, [x0]
	cmp	x8, x1
	cset	w0, eq
LBB119_2:
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
	cbz	x0, LBB120_35
; %bb.1:
	mov	x21, x2
	mov	x20, x1
	mov	x19, x0
	adrp	x23, __xt_threads_active@PAGE
	mov	w25, #1                         ; =0x1
	adrp	x24, _xt_sinit_n@PAGE
Lloh151:
	adrp	x26, _xt_sinit_flag@PAGE
Lloh152:
	add	x26, x26, _xt_sinit_flag@PAGEOFF
Lloh153:
	adrp	x27, _xt_sinit_owner@PAGE
Lloh154:
	add	x27, x27, _xt_sinit_owner@PAGEOFF
Lloh155:
	adrp	x22, _xt_rt_mtx@PAGE
Lloh156:
	add	x22, x22, _xt_rt_mtx@PAGEOFF
	b	LBB120_4
LBB120_2:                               ;   in Loop: Header=BB120_4 Depth=1
	mov	w8, #1                          ; =0x1
LBB120_3:                               ;   in Loop: Header=BB120_4 Depth=1
	cbnz	w8, LBB120_23
LBB120_4:                               ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB120_17 Depth 2
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB120_6
; %bb.5:                                ;   in Loop: Header=BB120_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_lock
LBB120_6:                               ;   in Loop: Header=BB120_4 Depth=1
	ldrb	w8, [x19]
	cbz	w8, LBB120_10
; %bb.7:                                ;   in Loop: Header=BB120_4 Depth=1
	cmp	w8, #2
	b.ne	LBB120_14
LBB120_8:                               ;   in Loop: Header=BB120_4 Depth=1
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB120_2
; %bb.9:                                ;   in Loop: Header=BB120_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_unlock
	b	LBB120_2
LBB120_10:                              ;   in Loop: Header=BB120_4 Depth=1
	strb	w25, [x19]
	ldrsw	x8, [x24, _xt_sinit_n@PAGEOFF]
	cmp	w8, #31
	b.gt	LBB120_12
; %bb.11:                               ;   in Loop: Header=BB120_4 Depth=1
	str	x19, [x26, x8, lsl #3]
	bl	_pthread_self
	lsr	x8, x0, #4
	lsr	x9, x0, #32
	eor	w8, w8, w9
	ldrsw	x9, [x24, _xt_sinit_n@PAGEOFF]
	str	w8, [x27, x9, lsl #2]
	add	w8, w9, #1
	str	w8, [x24, _xt_sinit_n@PAGEOFF]
LBB120_12:                              ;   in Loop: Header=BB120_4 Depth=1
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB120_22
; %bb.13:                               ;   in Loop: Header=BB120_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_unlock
	mov	w8, #2                          ; =0x2
	b	LBB120_3
LBB120_14:                              ;   in Loop: Header=BB120_4 Depth=1
	bl	_pthread_self
	ldr	w8, [x24, _xt_sinit_n@PAGEOFF]
	cmp	w8, #1
	b.lt	LBB120_19
; %bb.15:                               ;   in Loop: Header=BB120_4 Depth=1
	lsr	x9, x0, #4
	lsr	x10, x0, #32
	eor	w9, w9, w10
	mov	x10, x26
	mov	x11, x27
	b	LBB120_17
LBB120_16:                              ;   in Loop: Header=BB120_17 Depth=2
	add	x11, x11, #4
	add	x10, x10, #8
	subs	x8, x8, #1
	b.eq	LBB120_19
LBB120_17:                              ;   Parent Loop BB120_4 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldr	x12, [x10]
	cmp	x12, x19
	b.ne	LBB120_16
; %bb.18:                               ;   in Loop: Header=BB120_17 Depth=2
	ldr	w12, [x11]
	cmp	w12, w9
	b.ne	LBB120_16
	b	LBB120_8
LBB120_19:                              ;   in Loop: Header=BB120_4 Depth=1
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB120_21
; %bb.20:                               ;   in Loop: Header=BB120_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_unlock
LBB120_21:                              ;   in Loop: Header=BB120_4 Depth=1
	bl	_sched_yield
	mov	w8, #0                          ; =0x0
	b	LBB120_3
LBB120_22:                              ;   in Loop: Header=BB120_4 Depth=1
	mov	w8, #2                          ; =0x2
	b	LBB120_3
LBB120_23:
	cmp	w8, #1
	b.eq	LBB120_35
; %bb.24:
	cbz	x20, LBB120_26
; %bb.25:
	mov	x0, x21
	blr	x20
LBB120_26:
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB120_28
; %bb.27:
Lloh157:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh158:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB120_28:
	mov	w8, #2                          ; =0x2
	strb	w8, [x19]
	ldr	w8, [x24, _xt_sinit_n@PAGEOFF]
	cmp	w8, #1
	b.lt	LBB120_32
; %bb.29:
Lloh159:
	adrp	x9, _xt_sinit_owner@PAGE
Lloh160:
	add	x9, x9, _xt_sinit_owner@PAGEOFF
Lloh161:
	adrp	x10, _xt_sinit_flag@PAGE
Lloh162:
	add	x10, x10, _xt_sinit_flag@PAGEOFF
	mov	x13, x8
	mov	x12, x10
	mov	x11, x9
LBB120_30:                              ; =>This Inner Loop Header: Depth=1
	ldr	x14, [x12]
	cmp	x14, x19
	b.eq	LBB120_34
; %bb.31:                               ;   in Loop: Header=BB120_30 Depth=1
	add	x11, x11, #4
	add	x12, x12, #8
	subs	x13, x13, #1
	b.ne	LBB120_30
LBB120_32:
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB120_35
LBB120_33:
Lloh163:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh164:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #80]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #64]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp], #96             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB120_34:
	sxtw	x8, w8
	sub	x8, x8, #1
	str	w8, [x24, _xt_sinit_n@PAGEOFF]
	ldr	x10, [x10, x8, lsl #3]
	str	x10, [x12]
	ldr	w8, [x9, x8, lsl #2]
	str	w8, [x11]
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbnz	w8, LBB120_33
LBB120_35:
	ldp	x29, x30, [sp, #80]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #64]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp], #96             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh155, Lloh156
	.loh AdrpAdd	Lloh153, Lloh154
	.loh AdrpAdd	Lloh151, Lloh152
	.loh AdrpAdd	Lloh157, Lloh158
	.loh AdrpAdd	Lloh161, Lloh162
	.loh AdrpAdd	Lloh159, Lloh160
	.loh AdrpAdd	Lloh163, Lloh164
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
	.p2align	2                               ; -- Begin function _xtc_new_u8.cold.1
__xtc_new_u8.cold.1:                    ; @_xtc_new_u8.cold.1
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh165:
	adrp	x8, ___stderrp@GOTPAGE
Lloh166:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh167:
	ldr	x8, [x8]
	mov	w9, #1                          ; =0x1
	stp	x0, x9, [sp]
Lloh168:
	adrp	x1, l_.str@PAGE
Lloh169:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh168, Lloh169
	.loh AdrpLdrGotLdr	Lloh165, Lloh166, Lloh167
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function _xtc_new_i8.cold.1
__xtc_new_i8.cold.1:                    ; @_xtc_new_i8.cold.1
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh170:
	adrp	x8, ___stderrp@GOTPAGE
Lloh171:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh172:
	ldr	x8, [x8]
	mov	w9, #1                          ; =0x1
	stp	x0, x9, [sp]
Lloh173:
	adrp	x1, l_.str@PAGE
Lloh174:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh173, Lloh174
	.loh AdrpLdrGotLdr	Lloh170, Lloh171, Lloh172
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function _xtc_new_u16.cold.1
__xtc_new_u16.cold.1:                   ; @_xtc_new_u16.cold.1
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh175:
	adrp	x8, ___stderrp@GOTPAGE
Lloh176:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh177:
	ldr	x8, [x8]
	mov	w9, #2                          ; =0x2
	stp	x0, x9, [sp]
Lloh178:
	adrp	x1, l_.str@PAGE
Lloh179:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh178, Lloh179
	.loh AdrpLdrGotLdr	Lloh175, Lloh176, Lloh177
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function _xtc_new_i16.cold.1
__xtc_new_i16.cold.1:                   ; @_xtc_new_i16.cold.1
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh180:
	adrp	x8, ___stderrp@GOTPAGE
Lloh181:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh182:
	ldr	x8, [x8]
	mov	w9, #2                          ; =0x2
	stp	x0, x9, [sp]
Lloh183:
	adrp	x1, l_.str@PAGE
Lloh184:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh183, Lloh184
	.loh AdrpLdrGotLdr	Lloh180, Lloh181, Lloh182
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function _xtc_new_u32.cold.1
__xtc_new_u32.cold.1:                   ; @_xtc_new_u32.cold.1
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh185:
	adrp	x8, ___stderrp@GOTPAGE
Lloh186:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh187:
	ldr	x8, [x8]
	mov	w9, #4                          ; =0x4
	stp	x0, x9, [sp]
Lloh188:
	adrp	x1, l_.str@PAGE
Lloh189:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh188, Lloh189
	.loh AdrpLdrGotLdr	Lloh185, Lloh186, Lloh187
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function _xtc_new_i32.cold.1
__xtc_new_i32.cold.1:                   ; @_xtc_new_i32.cold.1
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh190:
	adrp	x8, ___stderrp@GOTPAGE
Lloh191:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh192:
	ldr	x8, [x8]
	mov	w9, #4                          ; =0x4
	stp	x0, x9, [sp]
Lloh193:
	adrp	x1, l_.str@PAGE
Lloh194:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh193, Lloh194
	.loh AdrpLdrGotLdr	Lloh190, Lloh191, Lloh192
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function _xtc_new_u64.cold.1
__xtc_new_u64.cold.1:                   ; @_xtc_new_u64.cold.1
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh195:
	adrp	x8, ___stderrp@GOTPAGE
Lloh196:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh197:
	ldr	x8, [x8]
	mov	w9, #8                          ; =0x8
	stp	x0, x9, [sp]
Lloh198:
	adrp	x1, l_.str@PAGE
Lloh199:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh198, Lloh199
	.loh AdrpLdrGotLdr	Lloh195, Lloh196, Lloh197
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function _xtc_new_i64.cold.1
__xtc_new_i64.cold.1:                   ; @_xtc_new_i64.cold.1
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh200:
	adrp	x8, ___stderrp@GOTPAGE
Lloh201:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh202:
	ldr	x8, [x8]
	mov	w9, #8                          ; =0x8
	stp	x0, x9, [sp]
Lloh203:
	adrp	x1, l_.str@PAGE
Lloh204:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh203, Lloh204
	.loh AdrpLdrGotLdr	Lloh200, Lloh201, Lloh202
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function _xtc_new_pointer.cold.1
__xtc_new_pointer.cold.1:               ; @_xtc_new_pointer.cold.1
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh205:
	adrp	x8, ___stderrp@GOTPAGE
Lloh206:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh207:
	ldr	x8, [x8]
	mov	w9, #8                          ; =0x8
	stp	x0, x9, [sp]
Lloh208:
	adrp	x1, l_.str@PAGE
Lloh209:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh208, Lloh209
	.loh AdrpLdrGotLdr	Lloh205, Lloh206, Lloh207
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function _xtc_new_bool.cold.1
__xtc_new_bool.cold.1:                  ; @_xtc_new_bool.cold.1
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh210:
	adrp	x8, ___stderrp@GOTPAGE
Lloh211:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh212:
	ldr	x8, [x8]
	mov	w9, #1                          ; =0x1
	stp	x0, x9, [sp]
Lloh213:
	adrp	x1, l_.str@PAGE
Lloh214:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh213, Lloh214
	.loh AdrpLdrGotLdr	Lloh210, Lloh211, Lloh212
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function _xtc_new_float.cold.1
__xtc_new_float.cold.1:                 ; @_xtc_new_float.cold.1
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh215:
	adrp	x8, ___stderrp@GOTPAGE
Lloh216:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh217:
	ldr	x8, [x8]
	mov	w9, #4                          ; =0x4
	stp	x0, x9, [sp]
Lloh218:
	adrp	x1, l_.str@PAGE
Lloh219:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh218, Lloh219
	.loh AdrpLdrGotLdr	Lloh215, Lloh216, Lloh217
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function _xtc_new_double.cold.1
__xtc_new_double.cold.1:                ; @_xtc_new_double.cold.1
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh220:
	adrp	x8, ___stderrp@GOTPAGE
Lloh221:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh222:
	ldr	x8, [x8]
	mov	w9, #8                          ; =0x8
	stp	x0, x9, [sp]
Lloh223:
	adrp	x1, l_.str@PAGE
Lloh224:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh223, Lloh224
	.loh AdrpLdrGotLdr	Lloh220, Lloh221, Lloh222
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function _xtc_new_string.cold.1
__xtc_new_string.cold.1:                ; @_xtc_new_string.cold.1
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Lloh225:
	adrp	x8, ___stderrp@GOTPAGE
Lloh226:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh227:
	ldr	x8, [x8]
	mov	w9, #8                          ; =0x8
	stp	x0, x9, [sp]
Lloh228:
	adrp	x1, l_.str@PAGE
Lloh229:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh228, Lloh229
	.loh AdrpLdrGotLdr	Lloh225, Lloh226, Lloh227
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function OUTLINED_FUNCTION_0
_OUTLINED_FUNCTION_0:                   ; @OUTLINED_FUNCTION_0 Thunk
	.cfi_startproc
; %bb.0:
	mov	x0, x8
	b	_fprintf
	.cfi_endproc
                                        ; -- End function
	.section	__TEXT,__cstring,cstring_literals
l_.str:                                 ; @.str
	.asciz	"xcc: out of memory allocating %lu x %lu bytes\n"

.zerofill __DATA,__bss,_xt_simd_tab,8,3 ; @xt_simd_tab
.zerofill __DATA,__bss,_xt_simd_installed,1,2 ; @xt_simd_installed
.zerofill __DATA,__bss,_xt_simd_old,32,3 ; @xt_simd_old
.zerofill __DATA,__bss,_xt_simd_flag,8,3 ; @xt_simd_flag
l_.str.1:                               ; @.str.1
	.asciz	"%.6f"

l_.str.2:                               ; @.str.2
	.asciz	"%.10f"

.zerofill __DATA,__bss,_xt_rand_seeded,1,2 ; @xt_rand_seeded
.zerofill __DATA,__bss,_xt_clk_origin,8,3 ; @xt_clk_origin
.zerofill __DATA,__bss,__xtc_bank_regions,6144,3 ; @_xtc_bank_regions
.zerofill __DATA,__bss,_xt_files,64,3   ; @xt_files
l_.str.3:                               ; @.str.3
	.asciz	"rb"

l_.str.4:                               ; @.str.4
	.space	1

.zerofill __DATA,__bss,_xt_argc_v,4,2   ; @xt_argc_v
.zerofill __DATA,__bss,_xt_argv_v,8,3   ; @xt_argv_v
	.globl	__xt_threads_active             ; @_xt_threads_active
.zerofill __DATA,__common,__xt_threads_active,4,2
.zerofill __DATA,__bss,_xt_rt_mtx,64,3  ; @xt_rt_mtx
.zerofill __DATA,__bss,_xt_sinit_n,4,2  ; @xt_sinit_n
.zerofill __DATA,__bss,_xt_sinit_flag,256,3 ; @xt_sinit_flag
.zerofill __DATA,__bss,_xt_sinit_owner,128,2 ; @xt_sinit_owner
.zerofill __DATA,__bss,_xt_simd_n,8,3   ; @xt_simd_n
.zerofill __DATA,__bss,_xt_simd_cap,8,3 ; @xt_simd_cap
l_.str.5:                               ; @.str.5
	.asciz	"%.*f"

.subsections_via_symbols
