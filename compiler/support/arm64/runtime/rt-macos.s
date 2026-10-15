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
	cbz	x0, LBB2_22
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
	adrp	x21, __xt_threads_active@PAGE
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB2_3
; %bb.2:
Lloh5:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh6:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB2_3:
	adrp	x22, _xt_simd_n@PAGE
	ldr	x27, [x22, _xt_simd_n@PAGEOFF]
	adrp	x25, _xt_simd_cap@PAGE
	ldr	x8, [x25, _xt_simd_cap@PAGEOFF]
	adrp	x24, _xt_simd_tab@PAGE
	cmp	x27, x8
	b.ne	LBB2_12
; %bb.4:
	lsl	x9, x8, #1
	mov	w10, #64                        ; =0x40
	cmp	x8, #0
	csel	x26, x10, x9, eq
	lsl	x0, x26, #1
	mov	w1, #8                          ; =0x8
	bl	_calloc
	mov	x20, x0
	cbz	x0, LBB2_9
; %bb.5:
	lsl	x8, x27, #1
	cbz	x8, LBB2_8
; %bb.6:
	ldr	x9, [x24, _xt_simd_tab@PAGEOFF]
	mov	x10, x20
LBB2_7:                                 ; =>This Inner Loop Header: Depth=1
	ldr	x11, [x9], #8
	str	x11, [x10], #8
	subs	x8, x8, #1
	b.ne	LBB2_7
LBB2_8:
	ldr	x0, [x24, _xt_simd_tab@PAGEOFF]
	bl	_free
	str	x20, [x24, _xt_simd_tab@PAGEOFF]
	str	x26, [x25, _xt_simd_cap@PAGEOFF]
	b	LBB2_11
LBB2_9:
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB2_11
; %bb.10:
Lloh7:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh8:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB2_11:
	cbz	x20, LBB2_21
LBB2_12:
	ldr	x8, [x22, _xt_simd_n@PAGEOFF]
	cbz	x8, LBB2_16
; %bb.13:
	mov	x9, #0                          ; =0x0
	ldr	x10, [x24, _xt_simd_tab@PAGEOFF]
	mov	x11, x8
LBB2_14:                                ; =>This Inner Loop Header: Depth=1
	add	x12, x11, x9
	lsr	x13, x12, #1
	and	x12, x12, #0x1ffffffffffffffe
	ldr	x12, [x10, x12, lsl #3]
	cmp	x12, x19
	csel	x11, x13, x11, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x11
	b.lo	LBB2_14
; %bb.15:
	cmp	x8, x9
	b.hi	LBB2_17
	b	LBB2_19
LBB2_16:
	mov	x9, #0                          ; =0x0
	cmp	x8, x9
	b.ls	LBB2_19
LBB2_17:
	ldr	x10, [x24, _xt_simd_tab@PAGEOFF]
	add	x12, x10, x8, lsl #4
	mov	x10, x8
	mov	x11, x12
LBB2_18:                                ; =>This Inner Loop Header: Depth=1
	ldr	x13, [x11, #-16]!
	ldur	x14, [x12, #-8]
	stp	x13, x14, [x12]
	sub	x10, x10, #1
	mov	x12, x11
	cmp	x10, x9
	b.hi	LBB2_18
LBB2_19:
	ldr	x10, [x24, _xt_simd_tab@PAGEOFF]
	add	x9, x10, x9, lsl #4
	add	x10, x19, x23
	stp	x19, x10, [x9]
	add	x8, x8, #1
	str	x8, [x22, _xt_simd_n@PAGEOFF]
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB2_21
; %bb.20:
Lloh9:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh10:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB2_21:
	mov	x0, x19
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #64]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #48]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #32]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
LBB2_22:
Lloh11:
	adrp	x8, ___stderrp@GOTPAGE
Lloh12:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh13:
	ldr	x0, [x8]
	stp	x20, x21, [sp]
Lloh14:
	adrp	x1, l_.str@PAGE
Lloh15:
	add	x1, x1, l_.str@PAGEOFF
	bl	_fprintf
	bl	_abort
	.loh AdrpAdd	Lloh5, Lloh6
	.loh AdrpAdd	Lloh7, Lloh8
	.loh AdrpAdd	Lloh9, Lloh10
	.loh AdrpAdd	Lloh14, Lloh15
	.loh AdrpLdrGotLdr	Lloh11, Lloh12, Lloh13
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
Lloh16:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh17:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB15_2:
Lloh18:
	adrp	x8, _xt_simd_n@PAGE
Lloh19:
	ldr	x10, [x8, _xt_simd_n@PAGEOFF]
Lloh20:
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
Lloh21:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh22:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB15_10:
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh16, Lloh17
	.loh AdrpAdrp	Lloh18, Lloh20
	.loh AdrpLdr	Lloh18, Lloh19
	.loh AdrpAdd	Lloh21, Lloh22
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_rt_lock                    ; -- Begin function _xt_rt_lock
	.p2align	2
__xt_rt_lock:                           ; @_xt_rt_lock
	.cfi_startproc
; %bb.0:
Lloh23:
	adrp	x8, __xt_threads_active@PAGE
Lloh24:
	ldr	w8, [x8, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB16_2
; %bb.1:
Lloh25:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh26:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	b	_pthread_mutex_lock
LBB16_2:
	ret
	.loh AdrpLdr	Lloh23, Lloh24
	.loh AdrpAdd	Lloh25, Lloh26
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_rt_unlock                  ; -- Begin function _xt_rt_unlock
	.p2align	2
__xt_rt_unlock:                         ; @_xt_rt_unlock
	.cfi_startproc
; %bb.0:
Lloh27:
	adrp	x8, __xt_threads_active@PAGE
Lloh28:
	ldr	w8, [x8, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB17_2
; %bb.1:
Lloh29:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh30:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	b	_pthread_mutex_unlock
LBB17_2:
	ret
	.loh AdrpLdr	Lloh27, Lloh28
	.loh AdrpAdd	Lloh29, Lloh30
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
Lloh31:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh32:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB18_2:
Lloh33:
	adrp	x8, _xt_simd_n@PAGE
Lloh34:
	ldr	x10, [x8, _xt_simd_n@PAGEOFF]
Lloh35:
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
Lloh36:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh37:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB18_10:
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh31, Lloh32
	.loh AdrpAdrp	Lloh33, Lloh35
	.loh AdrpLdr	Lloh33, Lloh34
	.loh AdrpAdd	Lloh36, Lloh37
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
	cbz	x0, LBB33_7
; %bb.1:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB33_3
; %bb.2:
Lloh38:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh39:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB33_3:
	ldur	x8, [x19, #-12]
	cbz	x8, LBB33_5
LBB33_4:                                ; =>This Inner Loop Header: Depth=1
	ldur	x9, [x8, #-8]
	stp	xzr, xzr, [x8, #-8]
	stur	xzr, [x8, #-16]
	mov	x8, x9
	cbnz	x9, LBB33_4
LBB33_5:
	stur	xzr, [x19, #-12]
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB33_7
; %bb.6:
Lloh40:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh41:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB33_7:
	mov	x0, x19
	ldr	w8, [x0, #-40]!
	ldur	x21, [x0, #20]
	mov	w9, #20291                      ; =0x4f43
	movk	w9, #22612, lsl #16
	cmp	w8, w9
	b.ne	LBB33_23
; %bb.8:
	cbz	x21, LBB33_10
; %bb.9:
	mov	x0, x19
	blr	x21
LBB33_10:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB33_12
; %bb.11:
Lloh42:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh43:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB33_12:
	adrp	x8, _xt_simd_n@PAGE
	ldr	x9, [x8, _xt_simd_n@PAGEOFF]
	adrp	x11, _xt_simd_tab@PAGE
	mov	x10, #0                         ; =0x0
	cbz	x9, LBB33_15
; %bb.13:
	ldr	x12, [x11, _xt_simd_tab@PAGEOFF]
	mov	x13, x9
LBB33_14:                               ; =>This Inner Loop Header: Depth=1
	add	x14, x13, x10
	lsr	x15, x14, #1
	and	x14, x14, #0x1ffffffffffffffe
	ldr	x14, [x12, x14, lsl #3]
	cmp	x14, x19
	csel	x13, x15, x13, hi
	csinc	x10, x10, x15, hi
	cmp	x10, x13
	b.lo	LBB33_14
LBB33_15:
	cbz	x10, LBB33_20
; %bb.16:
	ldr	x11, [x11, _xt_simd_tab@PAGEOFF]
	add	x11, x11, x10, lsl #4
	ldur	x12, [x11, #-16]
	cmp	x12, x19
	b.ne	LBB33_20
; %bb.17:
	subs	x10, x9, x10
	b.ls	LBB33_19
LBB33_18:                               ; =>This Inner Loop Header: Depth=1
	ldp	x12, x13, [x11]
	stp	x12, x13, [x11, #-16]
	add	x11, x11, #16
	subs	x10, x10, #1
	b.ne	LBB33_18
LBB33_19:
	sub	x9, x9, #1
	str	x9, [x8, _xt_simd_n@PAGEOFF]
LBB33_20:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB33_22
; %bb.21:
Lloh44:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh45:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB33_22:
	ldur	x0, [x19, #-48]
	b	LBB33_28
LBB33_23:
	cbz	x21, LBB33_28
; %bb.24:
	ldur	x20, [x0, #4]
	ldur	x22, [x0, #12]
	mov	w8, #-2147483648                ; =0x80000000
	stur	w8, [x19, #-4]
	cbz	x22, LBB33_28
; %bb.25:
	mov	x23, x0
LBB33_26:                               ; =>This Inner Loop Header: Depth=1
	mov	x0, x19
	blr	x21
	add	x19, x19, x20
	subs	x22, x22, #1
	b.ne	LBB33_26
; %bb.27:
	mov	x0, x23
LBB33_28:
	ldp	x29, x30, [sp, #48]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #32]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #16]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp], #64             ; 16-byte Folded Reload
	b	_free
	.loh AdrpAdd	Lloh38, Lloh39
	.loh AdrpAdd	Lloh40, Lloh41
	.loh AdrpAdd	Lloh42, Lloh43
	.loh AdrpAdd	Lloh44, Lloh45
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_weak_zero_for             ; -- Begin function _xtc_weak_zero_for
	.p2align	2
__xtc_weak_zero_for:                    ; @_xtc_weak_zero_for
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB34_7
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
	cbz	w8, LBB34_3
; %bb.2:
Lloh46:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh47:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB34_3:
	ldur	x8, [x19, #-12]
	cbz	x8, LBB34_5
LBB34_4:                                ; =>This Inner Loop Header: Depth=1
	ldur	x9, [x8, #-8]
	stp	xzr, xzr, [x8, #-8]
	stur	xzr, [x8, #-16]
	mov	x8, x9
	cbnz	x9, LBB34_4
LBB34_5:
	stur	xzr, [x19, #-12]
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	cbz	w8, LBB34_7
; %bb.6:
Lloh48:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh49:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	b	_pthread_mutex_unlock
LBB34_7:
	ret
	.loh AdrpAdd	Lloh46, Lloh47
	.loh AdrpAdd	Lloh48, Lloh49
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
	cbz	w8, LBB35_2
; %bb.1:
Lloh50:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh51:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB35_2:
	mov	x8, x19
	ldr	x9, [x8, #-16]!
	cbz	x9, LBB35_7
; %bb.3:
	ldr	x10, [x9]
	cmp	x10, x19
	b.ne	LBB35_6
; %bb.4:
	ldur	x10, [x19, #-8]
	str	x10, [x9]
	cbz	x10, LBB35_6
; %bb.5:
	stur	x9, [x10, #-16]
LBB35_6:
	stp	xzr, xzr, [x8]
LBB35_7:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB35_9
; %bb.8:
Lloh52:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh53:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB35_9:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh50, Lloh51
	.loh AdrpAdd	Lloh52, Lloh53
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
	cbz	w8, LBB36_2
; %bb.1:
Lloh54:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh55:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB36_2:
	mov	x8, x20
	ldr	x9, [x8, #-16]!
	cbz	x9, LBB36_7
; %bb.3:
	ldr	x10, [x9]
	cmp	x10, x20
	b.ne	LBB36_6
; %bb.4:
	ldur	x10, [x20, #-8]
	str	x10, [x9]
	cbz	x10, LBB36_6
; %bb.5:
	stur	x9, [x10, #-16]
LBB36_6:
	stp	xzr, xzr, [x8]
LBB36_7:
	cbz	x19, LBB36_12
; %bb.8:
	ldur	w8, [x19, #-40]
	mov	w9, #10145                      ; =0x27a1
	movk	w9, #11306, lsl #16
	cmp	w9, w8, lsr #1
	b.ne	LBB36_12
; %bb.9:
	ldr	x8, [x19, #-12]!
	mov	x9, x20
	str	x8, [x9, #-8]!
	stur	x19, [x9, #-8]
	cbz	x8, LBB36_11
; %bb.10:
	stur	x9, [x8, #-16]
LBB36_11:
	str	x20, [x19]
LBB36_12:
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB36_14
; %bb.13:
Lloh56:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh57:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB36_14:
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh54, Lloh55
	.loh AdrpAdd	Lloh56, Lloh57
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
Lloh58:
	adrp	x2, l_.str.1@PAGE
Lloh59:
	add	x2, x2, l_.str.1@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB39_1:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB39_1
; %bb.2:
	sub	x2, x8, #1
	add	x1, sp, #16
	mov	w0, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.loh AdrpAdd	Lloh58, Lloh59
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
Lloh60:
	adrp	x2, l_.str.2@PAGE
Lloh61:
	add	x2, x2, l_.str.2@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB40_1:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB40_1
; %bb.2:
	sub	x2, x8, #1
	add	x1, sp, #16
	mov	w0, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.loh AdrpAdd	Lloh60, Lloh61
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
	cbz	w0, LBB41_7
; %bb.1:
	add	w8, w0, #1
	str	d0, [sp, #8]
	str	x8, [sp]
Lloh62:
	adrp	x2, l_.str.5@PAGE
Lloh63:
	add	x2, x2, l_.str.5@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB41_2:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB41_2
; %bb.3:
	cmp	x8, #1
	b.eq	LBB41_5
; %bb.4:
	add	x9, sp, #16
	add	x8, x9, x8
	sturb	wzr, [x8, #-2]
LBB41_5:
	mov	x8, #0                          ; =0x0
	add	x9, sp, #16
LBB41_6:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w10, [x9, x8]
	add	x8, x8, #1
	cbnz	w10, LBB41_6
	b	LBB41_9
LBB41_7:
	str	d0, [sp]
Lloh64:
	adrp	x2, l_.str.1@PAGE
Lloh65:
	add	x2, x2, l_.str.1@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB41_8:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB41_8
LBB41_9:
	sub	x2, x8, #1
	add	x1, sp, #16
	mov	w0, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.loh AdrpAdd	Lloh62, Lloh63
	.loh AdrpAdd	Lloh64, Lloh65
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
	cbz	w0, LBB42_7
; %bb.1:
	add	w8, w0, #1
	str	d0, [sp, #8]
	str	x8, [sp]
Lloh66:
	adrp	x2, l_.str.5@PAGE
Lloh67:
	add	x2, x2, l_.str.5@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB42_2:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB42_2
; %bb.3:
	cmp	x8, #1
	b.eq	LBB42_5
; %bb.4:
	add	x9, sp, #16
	add	x8, x9, x8
	sturb	wzr, [x8, #-2]
LBB42_5:
	mov	x8, #0                          ; =0x0
	add	x9, sp, #16
LBB42_6:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w10, [x9, x8]
	add	x8, x8, #1
	cbnz	w10, LBB42_6
	b	LBB42_9
LBB42_7:
	str	d0, [sp]
Lloh68:
	adrp	x2, l_.str.2@PAGE
Lloh69:
	add	x2, x2, l_.str.2@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB42_8:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB42_8
LBB42_9:
	sub	x2, x8, #1
	add	x1, sp, #16
	mov	w0, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.loh AdrpAdd	Lloh66, Lloh67
	.loh AdrpAdd	Lloh68, Lloh69
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
	tbnz	w8, #0, LBB60_2
; %bb.1:
	mov	w20, #1                         ; =0x1
	mov	w0, #1                          ; =0x1
	bl	_srandom
	strb	w20, [x19, _xt_rand_seeded@PAGEOFF]
LBB60_2:
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
	tbnz	w8, #0, LBB61_2
; %bb.1:
	mov	w20, #1                         ; =0x1
	mov	w0, #1                          ; =0x1
	bl	_srandom
	strb	w20, [x19, _xt_rand_seeded@PAGEOFF]
LBB61_2:
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
	tbnz	w8, #0, LBB62_2
; %bb.1:
	mov	w20, #1                         ; =0x1
	mov	w0, #1                          ; =0x1
	bl	_srandom
	strb	w20, [x19, _xt_rand_seeded@PAGEOFF]
LBB62_2:
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
Lloh70:
	adrp	x8, _xt_clk_origin@PAGE
Lloh71:
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
	.loh AdrpLdr	Lloh70, Lloh71
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
	b.ls	LBB66_2
; %bb.1:
	mov	x0, #0                          ; =0x0
	ret
LBB66_2:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	w8, w0
Lloh72:
	adrp	x9, __xtc_bank_regions@PAGE
Lloh73:
	add	x9, x9, __xtc_bank_regions@PAGEOFF
	add	x19, x9, x8, lsl #11
	ldr	x8, [x19, w1, uxtw #3]
	cbnz	x8, LBB66_4
; %bb.3:
	mov	w0, #1                          ; =0x1
	mov	x20, x1
	mov	w1, #12288                      ; =0x3000
	bl	_calloc
	mov	x1, x20
	str	x0, [x19, w20, uxtw #3]
LBB66_4:
	ldr	x0, [x19, w1, uxtw #3]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh72, Lloh73
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
Lloh74:
	adrp	x20, _xt_files@PAGE
Lloh75:
	add	x20, x20, _xt_files@PAGEOFF
LBB67_1:                                ; =>This Inner Loop Header: Depth=1
	ldr	x8, [x20, x19, lsl #3]
	cbz	x8, LBB67_3
; %bb.2:                                ;   in Loop: Header=BB67_1 Depth=1
	add	x19, x19, #1
	cmp	x19, #8
	b.ne	LBB67_1
	b	LBB67_5
LBB67_3:
	bl	_fopen
	cbz	x0, LBB67_5
; %bb.4:
	str	x0, [x20, x19, lsl #3]
	b	LBB67_6
LBB67_5:
	mov	w19, #-1                        ; =0xffffffff
LBB67_6:
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh74, Lloh75
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_read                  ; -- Begin function _xt_file_read
	.p2align	2
__xt_file_read:                         ; @_xt_file_read
	.cfi_startproc
; %bb.0:
	cmp	w0, #7
	b.hi	LBB68_3
; %bb.1:
Lloh76:
	adrp	x8, _xt_files@PAGE
Lloh77:
	add	x8, x8, _xt_files@PAGEOFF
	ldr	x3, [x8, w0, uxtw #3]
	cbz	x3, LBB68_3
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
LBB68_3:
	mov	w0, #-1                         ; =0xffffffff
                                        ; kill: def $w0 killed $w0 killed $x0
	ret
	.loh AdrpAdd	Lloh76, Lloh77
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_write                 ; -- Begin function _xt_file_write
	.p2align	2
__xt_file_write:                        ; @_xt_file_write
	.cfi_startproc
; %bb.0:
	cmp	w0, #7
	b.hi	LBB69_3
; %bb.1:
Lloh78:
	adrp	x8, _xt_files@PAGE
Lloh79:
	add	x8, x8, _xt_files@PAGEOFF
	ldr	x3, [x8, w0, uxtw #3]
	cbz	x3, LBB69_3
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
LBB69_3:
	mov	w0, #-1                         ; =0xffffffff
                                        ; kill: def $w0 killed $w0 killed $x0
	ret
	.loh AdrpAdd	Lloh78, Lloh79
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_close                 ; -- Begin function _xt_file_close
	.p2align	2
__xt_file_close:                        ; @_xt_file_close
	.cfi_startproc
; %bb.0:
	cmp	w0, #7
	b.hi	LBB70_4
; %bb.1:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
Lloh80:
	adrp	x19, _xt_files@PAGE
Lloh81:
	add	x19, x19, _xt_files@PAGEOFF
	ldr	x8, [x19, w0, uxtw #3]
	cbz	x8, LBB70_3
; %bb.2:
	mov	x20, x0
	mov	x0, x8
	bl	_fclose
	str	xzr, [x19, w20, uxtw #3]
LBB70_3:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
LBB70_4:
	ret
	.loh AdrpAdd	Lloh80, Lloh81
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
Lloh82:
	adrp	x1, l_.str.3@PAGE
Lloh83:
	add	x1, x1, l_.str.3@PAGEOFF
	bl	_fopen
	cbz	x0, LBB71_3
; %bb.1:
	mov	x19, x0
	mov	x1, #0                          ; =0x0
	mov	w2, #2                          ; =0x2
	bl	_fseek
	cbz	w0, LBB71_4
; %bb.2:
	mov	x0, x19
	bl	_fclose
LBB71_3:
	mov	w0, #-1                         ; =0xffffffff
	b	LBB71_5
LBB71_4:
	mov	x0, x19
	bl	_ftell
	mov	x20, x0
	mov	x0, x19
	bl	_fclose
	cmp	x20, #0
	csinv	w0, w20, wzr, ge
LBB71_5:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh82, Lloh83
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
Lloh84:
	adrp	x1, l_.str.3@PAGE
Lloh85:
	add	x1, x1, l_.str.3@PAGEOFF
	bl	_fopen
	cbz	x0, LBB72_2
; %bb.1:
	bl	_fclose
	mov	w0, #1                          ; =0x1
LBB72_2:
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh84, Lloh85
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
Lloh86:
	adrp	x8, l_.str.4@PAGE
Lloh87:
	add	x8, x8, l_.str.4@PAGEOFF
	cmp	x0, #0
	csel	x0, x8, x0, eq
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh86, Lloh87
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
	cbz	w0, LBB74_2
; %bb.1:
	bl	___error
	ldr	w8, [x0]
	cmp	w8, #17
	cset	w0, eq
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
LBB74_2:
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
Lloh88:
	adrp	x8, _xt_argc_v@PAGE
	str	w0, [x8, _xt_argc_v@PAGEOFF]
Lloh89:
	adrp	x8, _xt_argv_v@PAGE
	str	x1, [x8, _xt_argv_v@PAGEOFF]
	ret
	.loh AdrpAdrp	Lloh88, Lloh89
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_argc                       ; -- Begin function _xt_argc
	.p2align	2
__xt_argc:                              ; @_xt_argc
	.cfi_startproc
; %bb.0:
Lloh90:
	adrp	x8, _xt_argc_v@PAGE
Lloh91:
	ldr	w0, [x8, _xt_argc_v@PAGEOFF]
	ret
	.loh AdrpLdr	Lloh90, Lloh91
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_argv                       ; -- Begin function _xt_argv
	.p2align	2
__xt_argv:                              ; @_xt_argv
	.cfi_startproc
; %bb.0:
	tbnz	w0, #31, LBB78_2
; %bb.1:
Lloh92:
	adrp	x8, _xt_argc_v@PAGE
Lloh93:
	ldr	w9, [x8, _xt_argc_v@PAGEOFF]
Lloh94:
	adrp	x8, _xt_argv_v@PAGE
Lloh95:
	ldr	x8, [x8, _xt_argv_v@PAGEOFF]
	cmp	w9, w0
	ccmp	x8, #0, #4, gt
	b.ne	LBB78_3
LBB78_2:
Lloh96:
	adrp	x0, l_.str.4@PAGE
Lloh97:
	add	x0, x0, l_.str.4@PAGEOFF
	ret
LBB78_3:
	ldr	x0, [x8, w0, uxtw #3]
	ret
	.loh AdrpLdr	Lloh94, Lloh95
	.loh AdrpAdrp	Lloh92, Lloh94
	.loh AdrpLdr	Lloh92, Lloh93
	.loh AdrpAdd	Lloh96, Lloh97
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
	cbz	x0, LBB80_4
; %bb.1:
	sub	x21, x0, x20
	cmp	x21, #1023
	b.hi	LBB80_11
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
	b.ne	LBB80_6
; %bb.3:
	mov	w8, #47                         ; =0x2f
	b	LBB80_5
LBB80_4:
	mov	w8, #46                         ; =0x2e
LBB80_5:
	strb	w8, [sp]
	strb	wzr, [sp, #1]
LBB80_6:
	mov	x0, sp
	bl	_opendir
	cbz	x0, LBB80_11
; %bb.7:
	mov	x20, x0
LBB80_8:                                ; =>This Inner Loop Header: Depth=1
	mov	x0, x20
	bl	_readdir
	cbz	x0, LBB80_12
; %bb.9:                                ;   in Loop: Header=BB80_8 Depth=1
	add	x0, x0, #21
	mov	x1, x19
	bl	_strcmp
	cbnz	w0, LBB80_8
; %bb.10:
	mov	w19, #1                         ; =0x1
	b	LBB80_13
LBB80_11:
	mov	w19, #0                         ; =0x0
	b	LBB80_14
LBB80_12:
	mov	w19, #0                         ; =0x0
LBB80_13:
	mov	x0, x20
	bl	_closedir
LBB80_14:
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
Lloh98:
	adrp	x8, __xt_threads_active@PAGE
Lloh99:
	ldr	w0, [x8, __xt_threads_active@PAGEOFF]
	ret
	.loh AdrpLdr	Lloh98, Lloh99
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_thread_create              ; -- Begin function _xt_thread_create
	.p2align	2
__xt_thread_create:                     ; @_xt_thread_create
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB82_11
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
	cbnz	w8, LBB82_3
; %bb.2:
Lloh100:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh101:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	mov	x1, #0                          ; =0x0
	bl	_pthread_mutex_init
	mov	w8, #1                          ; =0x1
	str	w8, [x19, __xt_threads_active@PAGEOFF]
LBB82_3:
	mov	w0, #16                         ; =0x10
	bl	_malloc
	cbz	x0, LBB82_10
; %bb.4:
	mov	x19, x0
	stp	x21, x20, [x0]
	mov	w0, #8                          ; =0x8
	bl	_malloc
	cbz	x0, LBB82_7
; %bb.5:
Lloh102:
	adrp	x2, _xt_thread_entry@PAGE
Lloh103:
	add	x2, x2, _xt_thread_entry@PAGEOFF
	mov	x20, x0
	mov	x1, #0                          ; =0x0
	mov	x3, x19
	bl	_pthread_create
	cbz	w0, LBB82_9
; %bb.6:
	mov	x0, x19
	bl	_free
	mov	x0, x20
	b	LBB82_8
LBB82_7:
	mov	x0, x19
LBB82_8:
	bl	_free
	mov	x0, #0                          ; =0x0
	b	LBB82_10
LBB82_9:
	mov	x0, x20
LBB82_10:
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
LBB82_11:
	ret
	.loh AdrpAdd	Lloh100, Lloh101
	.loh AdrpAdd	Lloh102, Lloh103
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
	cbz	x20, LBB83_2
; %bb.1:
	mov	x0, x19
	blr	x20
LBB83_2:
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
	cbz	x0, LBB84_2
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
LBB84_2:
	mov	w0, #-1                         ; =0xffffffff
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_thread_detach              ; -- Begin function _xt_thread_detach
	.p2align	2
__xt_thread_detach:                     ; @_xt_thread_detach
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB85_2
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
LBB85_2:
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
	cbz	x0, LBB90_4
; %bb.1:
	mov	x19, x0
	mov	x1, #0                          ; =0x0
	bl	_pthread_mutex_init
	cbz	w0, LBB90_3
; %bb.2:
	mov	x0, x19
	bl	_free
	mov	x0, #0                          ; =0x0
	b	LBB90_4
LBB90_3:
	mov	x0, x19
LBB90_4:
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
	cbz	x0, LBB91_2
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
LBB91_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_mutex_lock                 ; -- Begin function _xt_mutex_lock
	.p2align	2
__xt_mutex_lock:                        ; @_xt_mutex_lock
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB92_2
; %bb.1:
	b	_pthread_mutex_lock
LBB92_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_mutex_unlock               ; -- Begin function _xt_mutex_unlock
	.p2align	2
__xt_mutex_unlock:                      ; @_xt_mutex_unlock
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB93_2
; %bb.1:
	b	_pthread_mutex_unlock
LBB93_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_mutex_trylock              ; -- Begin function _xt_mutex_trylock
	.p2align	2
__xt_mutex_trylock:                     ; @_xt_mutex_trylock
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB94_2
; %bb.1:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	.cfi_def_cfa_offset 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	bl	_pthread_mutex_trylock
	cmp	w0, #0
	cset	w0, eq
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
LBB94_2:
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
	cbz	x0, LBB95_4
; %bb.1:
	mov	x19, x0
	mov	x1, #0                          ; =0x0
	bl	_pthread_cond_init
	cbz	w0, LBB95_3
; %bb.2:
	mov	x0, x19
	bl	_free
	mov	x0, #0                          ; =0x0
	b	LBB95_4
LBB95_3:
	mov	x0, x19
LBB95_4:
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
	cbz	x0, LBB96_2
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
LBB96_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_cond_wait                  ; -- Begin function _xt_cond_wait
	.p2align	2
__xt_cond_wait:                         ; @_xt_cond_wait
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB97_3
; %bb.1:
	cbz	x1, LBB97_3
; %bb.2:
	b	_pthread_cond_wait
LBB97_3:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_cond_signal                ; -- Begin function _xt_cond_signal
	.p2align	2
__xt_cond_signal:                       ; @_xt_cond_signal
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB98_2
; %bb.1:
	b	_pthread_cond_signal
LBB98_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_cond_broadcast             ; -- Begin function _xt_cond_broadcast
	.p2align	2
__xt_cond_broadcast:                    ; @_xt_cond_broadcast
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB99_2
; %bb.1:
	b	_pthread_cond_broadcast
LBB99_2:
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
	cbz	x0, LBB100_5
; %bb.1:
	mov	x20, x0
	mov	x1, #0                          ; =0x0
	bl	_pthread_mutex_init
	cbnz	w0, LBB100_4
; %bb.2:
	add	x0, x20, #64
	mov	x1, #0                          ; =0x0
	bl	_pthread_cond_init
	cbz	w0, LBB100_6
; %bb.3:
	mov	x0, x20
	bl	_pthread_mutex_destroy
LBB100_4:
	mov	x0, x20
	bl	_free
	mov	x0, #0                          ; =0x0
LBB100_5:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB100_6:
	bic	w8, w19, w19, asr #31
	mov	x0, x20
	str	w8, [x20, #112]
	b	LBB100_5
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_sem_free                   ; -- Begin function _xt_sem_free
	.p2align	2
__xt_sem_free:                          ; @_xt_sem_free
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB101_2
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
LBB101_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_sem_wait                   ; -- Begin function _xt_sem_wait
	.p2align	2
__xt_sem_wait:                          ; @_xt_sem_wait
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB102_4
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
	b.gt	LBB102_3
LBB102_2:                               ; =>This Inner Loop Header: Depth=1
	add	x0, x19, #64
	mov	x1, x19
	bl	_pthread_cond_wait
	ldr	w8, [x19, #112]
	cmp	w8, #1
	b.lt	LBB102_2
LBB102_3:
	sub	w8, w8, #1
	str	w8, [x19, #112]
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB102_4:
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
	cbz	x0, LBB103_3
; %bb.1:
	mov	x19, x0
	bl	_pthread_mutex_lock
	ldr	w8, [x19, #112]
	subs	w8, w8, #1
	b.lt	LBB103_4
; %bb.2:
	str	w8, [x19, #112]
	mov	w20, #1                         ; =0x1
	b	LBB103_5
LBB103_3:
	mov	w20, #0                         ; =0x0
	b	LBB103_6
LBB103_4:
	mov	w20, #0                         ; =0x0
LBB103_5:
	mov	x0, x19
	bl	_pthread_mutex_unlock
LBB103_6:
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
LBB104_2:
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
	b.eq	LBB106_2
; %bb.1:
	mov	w0, w0
	b	_pthread_setspecific
LBB106_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_tls_get                    ; -- Begin function _xt_tls_get
	.p2align	2
__xt_tls_get:                           ; @_xt_tls_get
	.cfi_startproc
; %bb.0:
	cmn	w0, #1
	b.eq	LBB107_2
; %bb.1:
	mov	w0, w0
	b	_pthread_getspecific
LBB107_2:
	mov	x0, #0                          ; =0x0
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_load_i32            ; -- Begin function _xt_atomic_load_i32
	.p2align	2
__xt_atomic_load_i32:                   ; @_xt_atomic_load_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB108_2
; %bb.1:
	ldar	w0, [x0]
LBB108_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_store_i32           ; -- Begin function _xt_atomic_store_i32
	.p2align	2
__xt_atomic_store_i32:                  ; @_xt_atomic_store_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB109_2
; %bb.1:
	stlr	w1, [x0]
LBB109_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_add_i32             ; -- Begin function _xt_atomic_add_i32
	.p2align	2
__xt_atomic_add_i32:                    ; @_xt_atomic_add_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB110_2
; %bb.1:
	ldaddal	w1, w8, [x0]
	add	w0, w8, w1
LBB110_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_xchg_i32            ; -- Begin function _xt_atomic_xchg_i32
	.p2align	2
__xt_atomic_xchg_i32:                   ; @_xt_atomic_xchg_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB111_2
; %bb.1:
	swpal	w1, w0, [x0]
LBB111_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_cas_i32             ; -- Begin function _xt_atomic_cas_i32
	.p2align	2
__xt_atomic_cas_i32:                    ; @_xt_atomic_cas_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB112_2
; %bb.1:
	mov	x8, x1
	casal	w8, w2, [x0]
	cmp	w8, w1
	cset	w0, eq
LBB112_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_load_ptr            ; -- Begin function _xt_atomic_load_ptr
	.p2align	2
__xt_atomic_load_ptr:                   ; @_xt_atomic_load_ptr
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB113_2
; %bb.1:
	ldar	x0, [x0]
LBB113_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_store_ptr           ; -- Begin function _xt_atomic_store_ptr
	.p2align	2
__xt_atomic_store_ptr:                  ; @_xt_atomic_store_ptr
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB114_2
; %bb.1:
	stlr	x1, [x0]
LBB114_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_cas_ptr             ; -- Begin function _xt_atomic_cas_ptr
	.p2align	2
__xt_atomic_cas_ptr:                    ; @_xt_atomic_cas_ptr
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB115_2
; %bb.1:
	mov	x8, x1
	casal	x8, x2, [x0]
	cmp	x8, x1
	cset	w0, eq
LBB115_2:
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
	cbz	x0, LBB116_35
; %bb.1:
	mov	x21, x2
	mov	x20, x1
	mov	x19, x0
	adrp	x23, __xt_threads_active@PAGE
	mov	w25, #1                         ; =0x1
	adrp	x24, _xt_sinit_n@PAGE
Lloh104:
	adrp	x26, _xt_sinit_flag@PAGE
Lloh105:
	add	x26, x26, _xt_sinit_flag@PAGEOFF
Lloh106:
	adrp	x27, _xt_sinit_owner@PAGE
Lloh107:
	add	x27, x27, _xt_sinit_owner@PAGEOFF
Lloh108:
	adrp	x22, _xt_rt_mtx@PAGE
Lloh109:
	add	x22, x22, _xt_rt_mtx@PAGEOFF
	b	LBB116_4
LBB116_2:                               ;   in Loop: Header=BB116_4 Depth=1
	mov	w8, #1                          ; =0x1
LBB116_3:                               ;   in Loop: Header=BB116_4 Depth=1
	cbnz	w8, LBB116_23
LBB116_4:                               ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB116_17 Depth 2
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB116_6
; %bb.5:                                ;   in Loop: Header=BB116_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_lock
LBB116_6:                               ;   in Loop: Header=BB116_4 Depth=1
	ldrb	w8, [x19]
	cbz	w8, LBB116_10
; %bb.7:                                ;   in Loop: Header=BB116_4 Depth=1
	cmp	w8, #2
	b.ne	LBB116_14
LBB116_8:                               ;   in Loop: Header=BB116_4 Depth=1
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB116_2
; %bb.9:                                ;   in Loop: Header=BB116_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_unlock
	b	LBB116_2
LBB116_10:                              ;   in Loop: Header=BB116_4 Depth=1
	strb	w25, [x19]
	ldrsw	x8, [x24, _xt_sinit_n@PAGEOFF]
	cmp	w8, #31
	b.gt	LBB116_12
; %bb.11:                               ;   in Loop: Header=BB116_4 Depth=1
	str	x19, [x26, x8, lsl #3]
	bl	_pthread_self
	lsr	x8, x0, #4
	lsr	x9, x0, #32
	eor	w8, w8, w9
	ldrsw	x9, [x24, _xt_sinit_n@PAGEOFF]
	str	w8, [x27, x9, lsl #2]
	add	w8, w9, #1
	str	w8, [x24, _xt_sinit_n@PAGEOFF]
LBB116_12:                              ;   in Loop: Header=BB116_4 Depth=1
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB116_22
; %bb.13:                               ;   in Loop: Header=BB116_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_unlock
	mov	w8, #2                          ; =0x2
	b	LBB116_3
LBB116_14:                              ;   in Loop: Header=BB116_4 Depth=1
	bl	_pthread_self
	ldr	w8, [x24, _xt_sinit_n@PAGEOFF]
	cmp	w8, #1
	b.lt	LBB116_19
; %bb.15:                               ;   in Loop: Header=BB116_4 Depth=1
	lsr	x9, x0, #4
	lsr	x10, x0, #32
	eor	w9, w9, w10
	mov	x10, x26
	mov	x11, x27
	b	LBB116_17
LBB116_16:                              ;   in Loop: Header=BB116_17 Depth=2
	add	x11, x11, #4
	add	x10, x10, #8
	subs	x8, x8, #1
	b.eq	LBB116_19
LBB116_17:                              ;   Parent Loop BB116_4 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldr	x12, [x10]
	cmp	x12, x19
	b.ne	LBB116_16
; %bb.18:                               ;   in Loop: Header=BB116_17 Depth=2
	ldr	w12, [x11]
	cmp	w12, w9
	b.ne	LBB116_16
	b	LBB116_8
LBB116_19:                              ;   in Loop: Header=BB116_4 Depth=1
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB116_21
; %bb.20:                               ;   in Loop: Header=BB116_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_unlock
LBB116_21:                              ;   in Loop: Header=BB116_4 Depth=1
	bl	_sched_yield
	mov	w8, #0                          ; =0x0
	b	LBB116_3
LBB116_22:                              ;   in Loop: Header=BB116_4 Depth=1
	mov	w8, #2                          ; =0x2
	b	LBB116_3
LBB116_23:
	cmp	w8, #1
	b.eq	LBB116_35
; %bb.24:
	cbz	x20, LBB116_26
; %bb.25:
	mov	x0, x21
	blr	x20
LBB116_26:
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB116_28
; %bb.27:
Lloh110:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh111:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB116_28:
	mov	w8, #2                          ; =0x2
	strb	w8, [x19]
	ldr	w8, [x24, _xt_sinit_n@PAGEOFF]
	cmp	w8, #1
	b.lt	LBB116_32
; %bb.29:
Lloh112:
	adrp	x9, _xt_sinit_owner@PAGE
Lloh113:
	add	x9, x9, _xt_sinit_owner@PAGEOFF
Lloh114:
	adrp	x10, _xt_sinit_flag@PAGE
Lloh115:
	add	x10, x10, _xt_sinit_flag@PAGEOFF
	mov	x13, x8
	mov	x12, x10
	mov	x11, x9
LBB116_30:                              ; =>This Inner Loop Header: Depth=1
	ldr	x14, [x12]
	cmp	x14, x19
	b.eq	LBB116_34
; %bb.31:                               ;   in Loop: Header=BB116_30 Depth=1
	add	x11, x11, #4
	add	x12, x12, #8
	subs	x13, x13, #1
	b.ne	LBB116_30
LBB116_32:
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB116_35
LBB116_33:
Lloh116:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh117:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #80]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #64]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp], #96             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB116_34:
	sxtw	x8, w8
	sub	x8, x8, #1
	str	w8, [x24, _xt_sinit_n@PAGEOFF]
	ldr	x10, [x10, x8, lsl #3]
	str	x10, [x12]
	ldr	w8, [x9, x8, lsl #2]
	str	w8, [x11]
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbnz	w8, LBB116_33
LBB116_35:
	ldp	x29, x30, [sp, #80]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #64]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp], #96             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh108, Lloh109
	.loh AdrpAdd	Lloh106, Lloh107
	.loh AdrpAdd	Lloh104, Lloh105
	.loh AdrpAdd	Lloh110, Lloh111
	.loh AdrpAdd	Lloh114, Lloh115
	.loh AdrpAdd	Lloh112, Lloh113
	.loh AdrpAdd	Lloh116, Lloh117
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
Lloh118:
	adrp	x8, ___stderrp@GOTPAGE
Lloh119:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh120:
	ldr	x8, [x8]
	mov	w9, #1                          ; =0x1
	stp	x0, x9, [sp]
Lloh121:
	adrp	x1, l_.str@PAGE
Lloh122:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh121, Lloh122
	.loh AdrpLdrGotLdr	Lloh118, Lloh119, Lloh120
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
Lloh123:
	adrp	x8, ___stderrp@GOTPAGE
Lloh124:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh125:
	ldr	x8, [x8]
	mov	w9, #1                          ; =0x1
	stp	x0, x9, [sp]
Lloh126:
	adrp	x1, l_.str@PAGE
Lloh127:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh126, Lloh127
	.loh AdrpLdrGotLdr	Lloh123, Lloh124, Lloh125
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
Lloh128:
	adrp	x8, ___stderrp@GOTPAGE
Lloh129:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh130:
	ldr	x8, [x8]
	mov	w9, #2                          ; =0x2
	stp	x0, x9, [sp]
Lloh131:
	adrp	x1, l_.str@PAGE
Lloh132:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh131, Lloh132
	.loh AdrpLdrGotLdr	Lloh128, Lloh129, Lloh130
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
Lloh133:
	adrp	x8, ___stderrp@GOTPAGE
Lloh134:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh135:
	ldr	x8, [x8]
	mov	w9, #2                          ; =0x2
	stp	x0, x9, [sp]
Lloh136:
	adrp	x1, l_.str@PAGE
Lloh137:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh136, Lloh137
	.loh AdrpLdrGotLdr	Lloh133, Lloh134, Lloh135
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
Lloh138:
	adrp	x8, ___stderrp@GOTPAGE
Lloh139:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh140:
	ldr	x8, [x8]
	mov	w9, #4                          ; =0x4
	stp	x0, x9, [sp]
Lloh141:
	adrp	x1, l_.str@PAGE
Lloh142:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh141, Lloh142
	.loh AdrpLdrGotLdr	Lloh138, Lloh139, Lloh140
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
Lloh143:
	adrp	x8, ___stderrp@GOTPAGE
Lloh144:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh145:
	ldr	x8, [x8]
	mov	w9, #4                          ; =0x4
	stp	x0, x9, [sp]
Lloh146:
	adrp	x1, l_.str@PAGE
Lloh147:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh146, Lloh147
	.loh AdrpLdrGotLdr	Lloh143, Lloh144, Lloh145
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
Lloh148:
	adrp	x8, ___stderrp@GOTPAGE
Lloh149:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh150:
	ldr	x8, [x8]
	mov	w9, #8                          ; =0x8
	stp	x0, x9, [sp]
Lloh151:
	adrp	x1, l_.str@PAGE
Lloh152:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh151, Lloh152
	.loh AdrpLdrGotLdr	Lloh148, Lloh149, Lloh150
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
Lloh153:
	adrp	x8, ___stderrp@GOTPAGE
Lloh154:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh155:
	ldr	x8, [x8]
	mov	w9, #8                          ; =0x8
	stp	x0, x9, [sp]
Lloh156:
	adrp	x1, l_.str@PAGE
Lloh157:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh156, Lloh157
	.loh AdrpLdrGotLdr	Lloh153, Lloh154, Lloh155
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
Lloh158:
	adrp	x8, ___stderrp@GOTPAGE
Lloh159:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh160:
	ldr	x8, [x8]
	mov	w9, #8                          ; =0x8
	stp	x0, x9, [sp]
Lloh161:
	adrp	x1, l_.str@PAGE
Lloh162:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh161, Lloh162
	.loh AdrpLdrGotLdr	Lloh158, Lloh159, Lloh160
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
Lloh163:
	adrp	x8, ___stderrp@GOTPAGE
Lloh164:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh165:
	ldr	x8, [x8]
	mov	w9, #1                          ; =0x1
	stp	x0, x9, [sp]
Lloh166:
	adrp	x1, l_.str@PAGE
Lloh167:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh166, Lloh167
	.loh AdrpLdrGotLdr	Lloh163, Lloh164, Lloh165
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
Lloh168:
	adrp	x8, ___stderrp@GOTPAGE
Lloh169:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh170:
	ldr	x8, [x8]
	mov	w9, #4                          ; =0x4
	stp	x0, x9, [sp]
Lloh171:
	adrp	x1, l_.str@PAGE
Lloh172:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh171, Lloh172
	.loh AdrpLdrGotLdr	Lloh168, Lloh169, Lloh170
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
Lloh173:
	adrp	x8, ___stderrp@GOTPAGE
Lloh174:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh175:
	ldr	x8, [x8]
	mov	w9, #8                          ; =0x8
	stp	x0, x9, [sp]
Lloh176:
	adrp	x1, l_.str@PAGE
Lloh177:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh176, Lloh177
	.loh AdrpLdrGotLdr	Lloh173, Lloh174, Lloh175
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
Lloh178:
	adrp	x8, ___stderrp@GOTPAGE
Lloh179:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh180:
	ldr	x8, [x8]
	mov	w9, #8                          ; =0x8
	stp	x0, x9, [sp]
Lloh181:
	adrp	x1, l_.str@PAGE
Lloh182:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh181, Lloh182
	.loh AdrpLdrGotLdr	Lloh178, Lloh179, Lloh180
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
