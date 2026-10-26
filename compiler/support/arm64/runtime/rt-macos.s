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
	mov	w22, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB0_4
; %bb.3:
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
	adrp	x1, l_.str.6@PAGE
Lloh9:
	add	x1, x1, l_.str.6@PAGEOFF
	bl	_fprintf
	bl	_abort
	.loh AdrpAdd	Lloh3, Lloh4
	.loh AdrpLdrGotLdr	Lloh0, Lloh1, Lloh2
	.loh AdrpAdd	Lloh8, Lloh9
	.loh AdrpLdrGotLdr	Lloh5, Lloh6, Lloh7
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_u8                    ; -- Begin function _xtc_new_u8
	.p2align	2
__xtc_new_u8:                           ; @_xtc_new_u8
	.cfi_startproc
; %bb.0:
	mov	w1, #1                          ; =0x1
	cmp	x0, #16, lsl #12                ; =65536
	b.lo	LBB1_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB1_2:
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
	mov	x21, x1
	mov	x20, x0
	cbz	x1, LBB2_2
; %bb.1:
	mov	x8, #-1048577                   ; =0xffffffffffefffff
	udiv	x8, x8, x21
	cmp	x8, x20
	b.lo	LBB2_28
LBB2_2:
	mul	x23, x21, x20
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
	cbz	x0, LBB2_27
; %bb.3:
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
	cbz	w8, LBB2_5
; %bb.4:
Lloh10:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh11:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB2_5:
	adrp	x25, _xt_simd_n@PAGE
	ldr	x24, [x25, _xt_simd_n@PAGEOFF]
	adrp	x28, _xt_simd_cap@PAGE
	ldr	x8, [x28, _xt_simd_cap@PAGEOFF]
	adrp	x27, _xt_simd_tab@PAGE
	adrp	x21, _xt_simd_flag@PAGE
	cmp	x24, x8
	b.ne	LBB2_17
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
	b.eq	LBB2_14
; %bb.7:
	lsl	x8, x24, #1
	cbz	x8, LBB2_10
; %bb.8:
	ldr	x9, [x27, _xt_simd_tab@PAGEOFF]
	mov	x10, x21
LBB2_9:                                 ; =>This Inner Loop Header: Depth=1
	ldr	x11, [x9], #8
	str	x11, [x10], #8
	subs	x8, x8, #1
	b.ne	LBB2_9
LBB2_10:
	cbz	x24, LBB2_13
; %bb.11:
Lloh12:
	adrp	x8, _xt_simd_flag@PAGE
Lloh13:
	ldr	x8, [x8, _xt_simd_flag@PAGEOFF]
	mov	x9, x22
LBB2_12:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w10, [x8], #1
	strb	w10, [x9], #1
	subs	x24, x24, #1
	b.ne	LBB2_12
LBB2_13:
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
	b	LBB2_16
LBB2_14:
	mov	x0, x21
	bl	_free
	mov	x0, x22
	bl	_free
	adrp	x20, __xt_threads_active@PAGE
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	adrp	x21, _xt_simd_flag@PAGE
	cbz	w8, LBB2_16
; %bb.15:
Lloh14:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh15:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB2_16:
	cbz	w26, LBB2_26
LBB2_17:
	ldr	x8, [x25, _xt_simd_n@PAGEOFF]
	cbz	x8, LBB2_21
; %bb.18:
	mov	x9, #0                          ; =0x0
	ldr	x10, [x27, _xt_simd_tab@PAGEOFF]
	mov	x11, x8
LBB2_19:                                ; =>This Inner Loop Header: Depth=1
	add	x12, x11, x9
	lsr	x13, x12, #1
	and	x12, x12, #0x1ffffffffffffffe
	ldr	x12, [x10, x12, lsl #3]
	cmp	x12, x19
	csel	x11, x13, x11, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x11
	b.lo	LBB2_19
; %bb.20:
	cmp	x8, x9
	b.hi	LBB2_22
	b	LBB2_24
LBB2_21:
	mov	x9, #0                          ; =0x0
	cmp	x8, x9
	b.ls	LBB2_24
LBB2_22:
	ldr	x11, [x27, _xt_simd_tab@PAGEOFF]
	ldr	x12, [x21, _xt_simd_flag@PAGEOFF]
	sub	x10, x8, #1
	add	x13, x12, x8
	add	x14, x11, x8, lsl #4
	mov	x11, x14
	mov	x12, x13
LBB2_23:                                ; =>This Inner Loop Header: Depth=1
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
	b.hi	LBB2_23
LBB2_24:
	ldr	x10, [x27, _xt_simd_tab@PAGEOFF]
	add	x10, x10, x9, lsl #4
	add	x11, x19, x23
	stp	x19, x11, [x10]
	ldr	x10, [x21, _xt_simd_flag@PAGEOFF]
	strb	wzr, [x10, x9]
	add	x8, x8, #1
	str	x8, [x25, _xt_simd_n@PAGEOFF]
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB2_26
; %bb.25:
Lloh16:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh17:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB2_26:
	mov	x0, x19
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #64]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #48]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #32]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
LBB2_27:
Lloh18:
	adrp	x8, ___stderrp@GOTPAGE
Lloh19:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh20:
	ldr	x0, [x8]
	stp	x20, x21, [sp]
Lloh21:
	adrp	x1, l_.str@PAGE
Lloh22:
	add	x1, x1, l_.str@PAGEOFF
	bl	_fprintf
	bl	_abort
LBB2_28:
Lloh23:
	adrp	x8, ___stderrp@GOTPAGE
Lloh24:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh25:
	ldr	x0, [x8]
	stp	x20, x21, [sp]
Lloh26:
	adrp	x1, l_.str.6@PAGE
Lloh27:
	add	x1, x1, l_.str.6@PAGEOFF
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
	.globl	__xtc_new_i8                    ; -- Begin function _xtc_new_i8
	.p2align	2
__xtc_new_i8:                           ; @_xtc_new_i8
	.cfi_startproc
; %bb.0:
	mov	w1, #1                          ; =0x1
	cmp	x0, #16, lsl #12                ; =65536
	b.lo	LBB3_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB3_2:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_u16                   ; -- Begin function _xtc_new_u16
	.p2align	2
__xtc_new_u16:                          ; @_xtc_new_u16
	.cfi_startproc
; %bb.0:
	mov	w1, #2                          ; =0x2
	tst	x0, #0x7fffffffffff8000
	b.eq	LBB4_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB4_2:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_i16                   ; -- Begin function _xtc_new_i16
	.p2align	2
__xtc_new_i16:                          ; @_xtc_new_i16
	.cfi_startproc
; %bb.0:
	mov	w1, #2                          ; =0x2
	tst	x0, #0x7fffffffffff8000
	b.eq	LBB5_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB5_2:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_u32                   ; -- Begin function _xtc_new_u32
	.p2align	2
__xtc_new_u32:                          ; @_xtc_new_u32
	.cfi_startproc
; %bb.0:
	mov	w1, #4                          ; =0x4
	tst	x0, #0x3fffffffffffc000
	b.eq	LBB6_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB6_2:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_i32                   ; -- Begin function _xtc_new_i32
	.p2align	2
__xtc_new_i32:                          ; @_xtc_new_i32
	.cfi_startproc
; %bb.0:
	mov	w1, #4                          ; =0x4
	tst	x0, #0x3fffffffffffc000
	b.eq	LBB7_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB7_2:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_u64                   ; -- Begin function _xtc_new_u64
	.p2align	2
__xtc_new_u64:                          ; @_xtc_new_u64
	.cfi_startproc
; %bb.0:
	mov	w1, #8                          ; =0x8
	tst	x0, #0x1fffffffffffe000
	b.eq	LBB8_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB8_2:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_i64                   ; -- Begin function _xtc_new_i64
	.p2align	2
__xtc_new_i64:                          ; @_xtc_new_i64
	.cfi_startproc
; %bb.0:
	mov	w1, #8                          ; =0x8
	tst	x0, #0x1fffffffffffe000
	b.eq	LBB9_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB9_2:
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
	b.lo	LBB11_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB11_2:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_float                 ; -- Begin function _xtc_new_float
	.p2align	2
__xtc_new_float:                        ; @_xtc_new_float
	.cfi_startproc
; %bb.0:
	mov	w1, #4                          ; =0x4
	tst	x0, #0x3fffffffffffc000
	b.eq	LBB12_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB12_2:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_new_double                ; -- Begin function _xtc_new_double
	.p2align	2
__xtc_new_double:                       ; @_xtc_new_double
	.cfi_startproc
; %bb.0:
	mov	w1, #8                          ; =0x8
	tst	x0, #0x1fffffffffffe000
	b.eq	LBB13_2
; %bb.1:
	mov	x2, #0                          ; =0x0
	b	__xtc_alloc_aligned
LBB13_2:
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
	cbz	x0, LBB15_26
; %bb.1:
	mov	x20, x1
	cbz	x1, LBB15_26
; %bb.2:
	mov	x19, x0
	orr	w8, w19, w20
	and	x8, x8, #0xfff
	cbnz	x8, LBB15_26
; %bb.3:
	adrp	x21, __xt_threads_active@PAGE
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB15_5
; %bb.4:
Lloh28:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh29:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB15_5:
	adrp	x25, _xt_simd_n@PAGE
	ldr	x24, [x25, _xt_simd_n@PAGEOFF]
	adrp	x28, _xt_simd_cap@PAGE
	ldr	x8, [x28, _xt_simd_cap@PAGEOFF]
	adrp	x27, _xt_simd_tab@PAGE
	adrp	x22, _xt_simd_flag@PAGE
	cmp	x24, x8
	b.ne	LBB15_17
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
	b.eq	LBB15_14
; %bb.7:
	lsl	x8, x24, #1
	cbz	x8, LBB15_10
; %bb.8:
	ldr	x9, [x27, _xt_simd_tab@PAGEOFF]
	mov	x10, x22
LBB15_9:                                ; =>This Inner Loop Header: Depth=1
	ldr	x11, [x9], #8
	str	x11, [x10], #8
	subs	x8, x8, #1
	b.ne	LBB15_9
LBB15_10:
	cbz	x24, LBB15_13
; %bb.11:
Lloh30:
	adrp	x8, _xt_simd_flag@PAGE
Lloh31:
	ldr	x8, [x8, _xt_simd_flag@PAGEOFF]
	mov	x9, x23
LBB15_12:                               ; =>This Inner Loop Header: Depth=1
	ldrb	w10, [x8], #1
	strb	w10, [x9], #1
	subs	x24, x24, #1
	b.ne	LBB15_12
LBB15_13:
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
	b	LBB15_16
LBB15_14:
	mov	x0, x22
	bl	_free
	mov	x0, x23
	bl	_free
	adrp	x21, __xt_threads_active@PAGE
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	adrp	x22, _xt_simd_flag@PAGE
	cbz	w8, LBB15_16
; %bb.15:
Lloh32:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh33:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB15_16:
	cbz	w26, LBB15_26
LBB15_17:
	ldr	x8, [x25, _xt_simd_n@PAGEOFF]
	cbz	x8, LBB15_21
; %bb.18:
	mov	x9, #0                          ; =0x0
	ldr	x10, [x27, _xt_simd_tab@PAGEOFF]
	mov	x11, x8
LBB15_19:                               ; =>This Inner Loop Header: Depth=1
	add	x12, x11, x9
	lsr	x13, x12, #1
	and	x12, x12, #0x1ffffffffffffffe
	ldr	x12, [x10, x12, lsl #3]
	cmp	x12, x19
	csel	x11, x13, x11, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x11
	b.lo	LBB15_19
; %bb.20:
	cmp	x8, x9
	b.hi	LBB15_22
	b	LBB15_24
LBB15_21:
	mov	x9, #0                          ; =0x0
	cmp	x8, x9
	b.ls	LBB15_24
LBB15_22:
	ldr	x11, [x27, _xt_simd_tab@PAGEOFF]
	ldr	x12, [x22, _xt_simd_flag@PAGEOFF]
	sub	x10, x8, #1
	add	x13, x12, x8
	add	x14, x11, x8, lsl #4
	mov	x11, x14
	mov	x12, x13
LBB15_23:                               ; =>This Inner Loop Header: Depth=1
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
	b.hi	LBB15_23
LBB15_24:
	ldr	x10, [x27, _xt_simd_tab@PAGEOFF]
	add	x10, x10, x9, lsl #4
	add	x11, x19, x20
	stp	x19, x11, [x10]
	ldr	x10, [x22, _xt_simd_flag@PAGEOFF]
	strb	wzr, [x10, x9]
	add	x8, x8, #1
	str	x8, [x25, _xt_simd_n@PAGEOFF]
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB15_26
; %bb.25:
Lloh34:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh35:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #80]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #64]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp], #96             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB15_26:
	ldp	x29, x30, [sp, #80]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #64]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp], #96             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh28, Lloh29
	.loh AdrpLdr	Lloh30, Lloh31
	.loh AdrpAdd	Lloh32, Lloh33
	.loh AdrpAdd	Lloh34, Lloh35
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
	cbz	w8, LBB16_2
; %bb.1:
Lloh36:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh37:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB16_2:
Lloh38:
	adrp	x8, _xt_simd_n@PAGE
Lloh39:
	ldr	x10, [x8, _xt_simd_n@PAGEOFF]
Lloh40:
	adrp	x8, _xt_simd_tab@PAGE
	mov	x9, #0                          ; =0x0
	cbz	x10, LBB16_5
; %bb.3:
	ldr	x11, [x8, _xt_simd_tab@PAGEOFF]
LBB16_4:                                ; =>This Inner Loop Header: Depth=1
	add	x12, x10, x9
	lsr	x13, x12, #1
	and	x12, x12, #0x1ffffffffffffffe
	ldr	x12, [x11, x12, lsl #3]
	cmp	x12, x19
	csel	x10, x13, x10, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x10
	b.lo	LBB16_4
LBB16_5:
	cbz	x9, LBB16_8
; %bb.6:
	ldr	x8, [x8, _xt_simd_tab@PAGEOFF]
	add	x8, x8, x9, lsl #4
	ldur	x9, [x8, #-8]
	cmp	x9, x19
	b.ls	LBB16_8
; %bb.7:
	ldur	x19, [x8, #-16]
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbnz	w8, LBB16_9
	b	LBB16_10
LBB16_8:
	mov	x19, #0                         ; =0x0
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB16_10
LBB16_9:
Lloh41:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh42:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB16_10:
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh36, Lloh37
	.loh AdrpAdrp	Lloh38, Lloh40
	.loh AdrpLdr	Lloh38, Lloh39
	.loh AdrpAdd	Lloh41, Lloh42
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_rt_lock                    ; -- Begin function _xt_rt_lock
	.p2align	2
__xt_rt_lock:                           ; @_xt_rt_lock
	.cfi_startproc
; %bb.0:
Lloh43:
	adrp	x8, __xt_threads_active@PAGE
Lloh44:
	ldr	w8, [x8, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB17_2
; %bb.1:
Lloh45:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh46:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	b	_pthread_mutex_lock
LBB17_2:
	ret
	.loh AdrpLdr	Lloh43, Lloh44
	.loh AdrpAdd	Lloh45, Lloh46
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_rt_unlock                  ; -- Begin function _xt_rt_unlock
	.p2align	2
__xt_rt_unlock:                         ; @_xt_rt_unlock
	.cfi_startproc
; %bb.0:
Lloh47:
	adrp	x8, __xt_threads_active@PAGE
Lloh48:
	ldr	w8, [x8, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB18_2
; %bb.1:
Lloh49:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh50:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	b	_pthread_mutex_unlock
LBB18_2:
	ret
	.loh AdrpLdr	Lloh47, Lloh48
	.loh AdrpAdd	Lloh49, Lloh50
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
	cbz	w8, LBB19_2
; %bb.1:
Lloh51:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh52:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB19_2:
Lloh53:
	adrp	x8, _xt_simd_n@PAGE
Lloh54:
	ldr	x10, [x8, _xt_simd_n@PAGEOFF]
Lloh55:
	adrp	x8, _xt_simd_tab@PAGE
	mov	x9, #0                          ; =0x0
	cbz	x10, LBB19_5
; %bb.3:
	ldr	x11, [x8, _xt_simd_tab@PAGEOFF]
LBB19_4:                                ; =>This Inner Loop Header: Depth=1
	add	x12, x10, x9
	lsr	x13, x12, #1
	and	x12, x12, #0x1ffffffffffffffe
	ldr	x12, [x11, x12, lsl #3]
	cmp	x12, x19
	csel	x10, x13, x10, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x10
	b.lo	LBB19_4
LBB19_5:
	cbz	x9, LBB19_7
; %bb.6:
	ldr	x8, [x8, _xt_simd_tab@PAGEOFF]
	add	x8, x8, x9, lsl #4
	ldur	x8, [x8, #-8]
	subs	x19, x8, x19
	b.hi	LBB19_8
LBB19_7:
	mov	x19, #-1                        ; =0xffffffffffffffff
LBB19_8:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB19_10
; %bb.9:
Lloh56:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh57:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB19_10:
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh51, Lloh52
	.loh AdrpAdrp	Lloh53, Lloh55
	.loh AdrpLdr	Lloh53, Lloh54
	.loh AdrpAdd	Lloh56, Lloh57
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
	cbz	w8, LBB20_2
; %bb.1:
Lloh58:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh59:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB20_2:
Lloh60:
	adrp	x8, _xt_simd_n@PAGE
Lloh61:
	ldr	x9, [x8, _xt_simd_n@PAGEOFF]
	adrp	x22, _xt_simd_tab@PAGE
	mov	x8, #0                          ; =0x0
	cbz	x9, LBB20_5
; %bb.3:
	ldr	x10, [x22, _xt_simd_tab@PAGEOFF]
LBB20_4:                                ; =>This Inner Loop Header: Depth=1
	add	x11, x9, x8
	lsr	x12, x11, #1
	and	x11, x11, #0x1ffffffffffffffe
	ldr	x11, [x10, x11, lsl #3]
	cmp	x11, x19
	csel	x9, x12, x9, hi
	csinc	x8, x8, x12, hi
	cmp	x8, x9
	b.lo	LBB20_4
LBB20_5:
	cbz	x8, LBB20_10
; %bb.6:
	ldr	x9, [x22, _xt_simd_tab@PAGEOFF]
	sub	x23, x8, #1
	lsl	x8, x23, #4
	ldr	x8, [x9, x8]
	cmp	x8, x19
	b.ne	LBB20_10
; %bb.7:
	adrp	x24, _xt_simd_installed@PAGE
	ldrb	w8, [x24, _xt_simd_installed@PAGEOFF]
	tbnz	w8, #0, LBB20_9
; %bb.8:
Lloh62:
	adrp	x8, _xt_simd_fault@PAGE
Lloh63:
	add	x8, x8, _xt_simd_fault@PAGEOFF
	mov	x9, #343597383680               ; =0x5000000000
	stp	x8, x9, [sp]
Lloh64:
	adrp	x20, _xt_simd_old@PAGE
Lloh65:
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
LBB20_9:
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
	cbz	w0, LBB20_13
LBB20_10:
	mov	w19, #0                         ; =0x0
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB20_12
LBB20_11:
Lloh66:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh67:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB20_12:
	mov	x0, x19
	ldp	x29, x30, [sp, #64]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #48]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #32]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #80
	ret
LBB20_13:
Lloh68:
	adrp	x8, _xt_simd_flag@PAGE
Lloh69:
	ldr	x8, [x8, _xt_simd_flag@PAGEOFF]
	ldrb	w9, [x8, x23]
	orr	w9, w9, #0x1
	strb	w9, [x8, x23]
	mov	w19, #1                         ; =0x1
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbnz	w8, LBB20_11
	b	LBB20_12
	.loh AdrpAdd	Lloh58, Lloh59
	.loh AdrpLdr	Lloh60, Lloh61
	.loh AdrpAdd	Lloh64, Lloh65
	.loh AdrpAdd	Lloh62, Lloh63
	.loh AdrpAdd	Lloh66, Lloh67
	.loh AdrpLdr	Lloh68, Lloh69
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
	cbz	w8, LBB21_2
; %bb.1:
Lloh70:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh71:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB21_2:
Lloh72:
	adrp	x8, _xt_simd_n@PAGE
Lloh73:
	ldr	x10, [x8, _xt_simd_n@PAGEOFF]
Lloh74:
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
	cmp	x12, x21
	csel	x10, x13, x10, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x10
	b.lo	LBB21_4
LBB21_5:
	cbz	x9, LBB21_11
; %bb.6:
	ldr	x8, [x8, _xt_simd_tab@PAGEOFF]
	sub	x10, x9, #1
	add	x9, x8, x10, lsl #4
	ldr	x9, [x9, #8]
	cmp	x21, x9
	b.hs	LBB21_11
; %bb.7:
Lloh75:
	adrp	x11, _xt_simd_flag@PAGE
Lloh76:
	ldr	x11, [x11, _xt_simd_flag@PAGEOFF]
	ldrb	w12, [x11, x10]
	tbz	w12, #0, LBB21_9
; %bb.8:
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
LBB21_9:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB21_14
; %bb.10:
Lloh77:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh78:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB21_11:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB21_13
; %bb.12:
Lloh79:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh80:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB21_13:
	cmp	w19, #11
	cset	w8, ne
Lloh81:
	adrp	x9, _xt_simd_old@PAGE
Lloh82:
	add	x9, x9, _xt_simd_old@PAGEOFF
	add	x1, x9, w8, uxtw #4
	mov	x0, x19
	mov	x2, #0                          ; =0x0
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	b	_sigaction
LBB21_14:
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh70, Lloh71
	.loh AdrpAdrp	Lloh72, Lloh74
	.loh AdrpLdr	Lloh72, Lloh73
	.loh AdrpLdr	Lloh75, Lloh76
	.loh AdrpAdd	Lloh77, Lloh78
	.loh AdrpAdd	Lloh79, Lloh80
	.loh AdrpAdd	Lloh81, Lloh82
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
	cbz	w8, LBB22_2
; %bb.1:
Lloh83:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh84:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB22_2:
Lloh85:
	adrp	x8, _xt_simd_n@PAGE
Lloh86:
	ldr	x10, [x8, _xt_simd_n@PAGEOFF]
Lloh87:
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
	cbz	x9, LBB22_9
; %bb.6:
	ldr	x8, [x8, _xt_simd_tab@PAGEOFF]
	sub	x9, x9, #1
	lsl	x10, x9, #4
	ldr	x10, [x8, x10]
	cmp	x10, x19
	b.ne	LBB22_9
; %bb.7:
Lloh88:
	adrp	x10, _xt_simd_flag@PAGE
Lloh89:
	ldr	x10, [x10, _xt_simd_flag@PAGEOFF]
	ldrb	w11, [x10, x9]
	tbz	w11, #0, LBB22_9
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
LBB22_9:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB22_11
; %bb.10:
Lloh90:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh91:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB22_11:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh83, Lloh84
	.loh AdrpAdrp	Lloh85, Lloh87
	.loh AdrpLdr	Lloh85, Lloh86
	.loh AdrpLdr	Lloh88, Lloh89
	.loh AdrpAdd	Lloh90, Lloh91
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
	cbz	w8, LBB23_2
; %bb.1:
Lloh92:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh93:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB23_2:
Lloh94:
	adrp	x8, _xt_simd_n@PAGE
Lloh95:
	ldr	x10, [x8, _xt_simd_n@PAGEOFF]
Lloh96:
	adrp	x8, _xt_simd_tab@PAGE
	mov	x9, #0                          ; =0x0
	cbz	x10, LBB23_5
; %bb.3:
	ldr	x11, [x8, _xt_simd_tab@PAGEOFF]
LBB23_4:                                ; =>This Inner Loop Header: Depth=1
	add	x12, x10, x9
	lsr	x13, x12, #1
	and	x12, x12, #0x1ffffffffffffffe
	ldr	x12, [x11, x12, lsl #3]
	cmp	x12, x19
	csel	x10, x13, x10, hi
	csinc	x9, x9, x13, hi
	cmp	x9, x10
	b.lo	LBB23_4
LBB23_5:
	cbz	x9, LBB23_8
; %bb.6:
	ldr	x10, [x8, _xt_simd_tab@PAGEOFF]
	sub	x8, x9, #1
	lsl	x9, x8, #4
	ldr	x9, [x10, x9]
	mov	w20, #1                         ; =0x1
	cmp	x9, x19
	b.ne	LBB23_9
; %bb.7:
Lloh97:
	adrp	x9, _xt_simd_flag@PAGE
Lloh98:
	ldr	x9, [x9, _xt_simd_flag@PAGEOFF]
	ldrb	w8, [x9, x8]
	bic	w20, w20, w8
	b	LBB23_9
LBB23_8:
	mov	w20, #1                         ; =0x1
LBB23_9:
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB23_11
; %bb.10:
Lloh99:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh100:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB23_11:
	mov	x0, x20
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh92, Lloh93
	.loh AdrpAdrp	Lloh94, Lloh96
	.loh AdrpLdr	Lloh94, Lloh95
	.loh AdrpLdr	Lloh97, Lloh98
	.loh AdrpAdd	Lloh99, Lloh100
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
	cbz	x0, LBB38_7
; %bb.1:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB38_3
; %bb.2:
Lloh101:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh102:
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
	cbz	w8, LBB38_7
; %bb.6:
Lloh103:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh104:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB38_7:
	mov	x0, x19
	ldr	w8, [x0, #-40]!
	ldur	x21, [x0, #20]
	mov	w9, #20291                      ; =0x4f43
	movk	w9, #22612, lsl #16
	cmp	w8, w9
	b.ne	LBB38_24
; %bb.8:
	cbz	x21, LBB38_10
; %bb.9:
	mov	x0, x19
	blr	x21
LBB38_10:
	mov	x0, x19
	bl	__xtc_simd_unwatch
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB38_12
; %bb.11:
Lloh105:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh106:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB38_12:
	adrp	x8, _xt_simd_n@PAGE
	ldr	x9, [x8, _xt_simd_n@PAGEOFF]
	adrp	x11, _xt_simd_tab@PAGE
	mov	x10, #0                         ; =0x0
	cbz	x9, LBB38_15
; %bb.13:
	ldr	x12, [x11, _xt_simd_tab@PAGEOFF]
	mov	x13, x9
LBB38_14:                               ; =>This Inner Loop Header: Depth=1
	add	x14, x13, x10
	lsr	x15, x14, #1
	and	x14, x14, #0x1ffffffffffffffe
	ldr	x14, [x12, x14, lsl #3]
	cmp	x14, x19
	csel	x13, x15, x13, hi
	csinc	x10, x10, x15, hi
	cmp	x10, x13
	b.lo	LBB38_14
LBB38_15:
	cbz	x10, LBB38_21
; %bb.16:
	ldr	x11, [x11, _xt_simd_tab@PAGEOFF]
	add	x11, x11, x10, lsl #4
	ldur	x12, [x11, #-16]
	cmp	x12, x19
	b.ne	LBB38_21
; %bb.17:
	subs	x12, x9, x10
	b.ls	LBB38_20
; %bb.18:
Lloh107:
	adrp	x13, _xt_simd_flag@PAGE
Lloh108:
	ldr	x13, [x13, _xt_simd_flag@PAGEOFF]
	add	x10, x13, x10
LBB38_19:                               ; =>This Inner Loop Header: Depth=1
	ldp	x13, x14, [x11]
	stp	x13, x14, [x11, #-16]
	ldrb	w13, [x10]
	sturb	w13, [x10, #-1]
	add	x10, x10, #1
	add	x11, x11, #16
	subs	x12, x12, #1
	b.ne	LBB38_19
LBB38_20:
	sub	x9, x9, #1
	str	x9, [x8, _xt_simd_n@PAGEOFF]
LBB38_21:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB38_23
; %bb.22:
Lloh109:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh110:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB38_23:
	ldur	x0, [x19, #-48]
	b	LBB38_29
LBB38_24:
	cbz	x21, LBB38_29
; %bb.25:
	ldur	x20, [x0, #4]
	ldur	x22, [x0, #12]
	mov	w8, #-2147483648                ; =0x80000000
	stur	w8, [x19, #-4]
	cbz	x22, LBB38_29
; %bb.26:
	mov	x23, x0
LBB38_27:                               ; =>This Inner Loop Header: Depth=1
	mov	x0, x19
	blr	x21
	add	x19, x19, x20
	subs	x22, x22, #1
	b.ne	LBB38_27
; %bb.28:
	mov	x0, x23
LBB38_29:
	ldp	x29, x30, [sp, #48]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #32]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #16]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp], #64             ; 16-byte Folded Reload
	b	_free
	.loh AdrpAdd	Lloh101, Lloh102
	.loh AdrpAdd	Lloh103, Lloh104
	.loh AdrpAdd	Lloh105, Lloh106
	.loh AdrpLdr	Lloh107, Lloh108
	.loh AdrpAdd	Lloh109, Lloh110
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_weak_zero_for             ; -- Begin function _xtc_weak_zero_for
	.p2align	2
__xtc_weak_zero_for:                    ; @_xtc_weak_zero_for
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB39_7
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
	cbz	w8, LBB39_3
; %bb.2:
Lloh111:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh112:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB39_3:
	ldur	x8, [x19, #-12]
	cbz	x8, LBB39_5
LBB39_4:                                ; =>This Inner Loop Header: Depth=1
	ldur	x9, [x8, #-8]
	stp	xzr, xzr, [x8, #-8]
	stur	xzr, [x8, #-16]
	mov	x8, x9
	cbnz	x9, LBB39_4
LBB39_5:
	stur	xzr, [x19, #-12]
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	cbz	w8, LBB39_7
; %bb.6:
Lloh113:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh114:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	b	_pthread_mutex_unlock
LBB39_7:
	ret
	.loh AdrpAdd	Lloh111, Lloh112
	.loh AdrpAdd	Lloh113, Lloh114
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
	cbz	w8, LBB40_2
; %bb.1:
Lloh115:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh116:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB40_2:
	mov	x8, x19
	ldr	x9, [x8, #-16]!
	cbz	x9, LBB40_7
; %bb.3:
	ldr	x10, [x9]
	cmp	x10, x19
	b.ne	LBB40_6
; %bb.4:
	ldur	x10, [x19, #-8]
	str	x10, [x9]
	cbz	x10, LBB40_6
; %bb.5:
	stur	x9, [x10, #-16]
LBB40_6:
	stp	xzr, xzr, [x8]
LBB40_7:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB40_9
; %bb.8:
Lloh117:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh118:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB40_9:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh115, Lloh116
	.loh AdrpAdd	Lloh117, Lloh118
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
	cbz	w8, LBB41_2
; %bb.1:
Lloh119:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh120:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB41_2:
	mov	x8, x20
	ldr	x9, [x8, #-16]!
	cbz	x9, LBB41_7
; %bb.3:
	ldr	x10, [x9]
	cmp	x10, x20
	b.ne	LBB41_6
; %bb.4:
	ldur	x10, [x20, #-8]
	str	x10, [x9]
	cbz	x10, LBB41_6
; %bb.5:
	stur	x9, [x10, #-16]
LBB41_6:
	stp	xzr, xzr, [x8]
LBB41_7:
	cbz	x19, LBB41_12
; %bb.8:
	ldur	w8, [x19, #-40]
	mov	w9, #10145                      ; =0x27a1
	movk	w9, #11306, lsl #16
	cmp	w9, w8, lsr #1
	b.ne	LBB41_12
; %bb.9:
	ldr	x8, [x19, #-12]!
	mov	x9, x20
	str	x8, [x9, #-8]!
	stur	x19, [x9, #-8]
	cbz	x8, LBB41_11
; %bb.10:
	stur	x9, [x8, #-16]
LBB41_11:
	str	x20, [x19]
LBB41_12:
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB41_14
; %bb.13:
Lloh121:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh122:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB41_14:
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh119, Lloh120
	.loh AdrpAdd	Lloh121, Lloh122
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
Lloh123:
	adrp	x2, l_.str.1@PAGE
Lloh124:
	add	x2, x2, l_.str.1@PAGEOFF
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
	.loh AdrpAdd	Lloh123, Lloh124
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
Lloh125:
	adrp	x2, l_.str.2@PAGE
Lloh126:
	add	x2, x2, l_.str.2@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB45_1:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB45_1
; %bb.2:
	sub	x2, x8, #1
	add	x1, sp, #16
	mov	w0, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.loh AdrpAdd	Lloh125, Lloh126
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
	cbz	w0, LBB46_7
; %bb.1:
	add	w8, w0, #1
	str	d0, [sp, #8]
	str	x8, [sp]
Lloh127:
	adrp	x2, l_.str.7@PAGE
Lloh128:
	add	x2, x2, l_.str.7@PAGEOFF
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
Lloh129:
	adrp	x2, l_.str.1@PAGE
Lloh130:
	add	x2, x2, l_.str.1@PAGEOFF
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
	.loh AdrpAdd	Lloh127, Lloh128
	.loh AdrpAdd	Lloh129, Lloh130
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
	cbz	w0, LBB47_7
; %bb.1:
	add	w8, w0, #1
	str	d0, [sp, #8]
	str	x8, [sp]
Lloh131:
	adrp	x2, l_.str.7@PAGE
Lloh132:
	add	x2, x2, l_.str.7@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB47_2:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB47_2
; %bb.3:
	cmp	x8, #1
	b.eq	LBB47_5
; %bb.4:
	add	x9, sp, #16
	add	x8, x9, x8
	sturb	wzr, [x8, #-2]
LBB47_5:
	mov	x8, #0                          ; =0x0
	add	x9, sp, #16
LBB47_6:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w10, [x9, x8]
	add	x8, x8, #1
	cbnz	w10, LBB47_6
	b	LBB47_9
LBB47_7:
	str	d0, [sp]
Lloh133:
	adrp	x2, l_.str.2@PAGE
Lloh134:
	add	x2, x2, l_.str.2@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB47_8:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB47_8
LBB47_9:
	sub	x2, x8, #1
	add	x1, sp, #16
	mov	w0, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.loh AdrpAdd	Lloh131, Lloh132
	.loh AdrpAdd	Lloh133, Lloh134
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
	tbnz	w8, #0, LBB65_2
; %bb.1:
	mov	w20, #1                         ; =0x1
	mov	w0, #1                          ; =0x1
	bl	_srandom
	strb	w20, [x19, _xt_rand_seeded@PAGEOFF]
LBB65_2:
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
	tbnz	w8, #0, LBB66_2
; %bb.1:
	mov	w20, #1                         ; =0x1
	mov	w0, #1                          ; =0x1
	bl	_srandom
	strb	w20, [x19, _xt_rand_seeded@PAGEOFF]
LBB66_2:
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
	tbnz	w8, #0, LBB67_2
; %bb.1:
	mov	w20, #1                         ; =0x1
	mov	w0, #1                          ; =0x1
	bl	_srandom
	strb	w20, [x19, _xt_rand_seeded@PAGEOFF]
LBB67_2:
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
Lloh135:
	adrp	x8, _xt_clk_origin@PAGE
Lloh136:
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
	.loh AdrpLdr	Lloh135, Lloh136
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
	b.ls	LBB71_2
; %bb.1:
	mov	x0, #0                          ; =0x0
	ret
LBB71_2:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	w8, w0
Lloh137:
	adrp	x9, __xtc_bank_regions@PAGE
Lloh138:
	add	x9, x9, __xtc_bank_regions@PAGEOFF
	add	x19, x9, x8, lsl #11
	ldr	x8, [x19, w1, uxtw #3]
	cbnz	x8, LBB71_4
; %bb.3:
	mov	w0, #1                          ; =0x1
	mov	x20, x1
	mov	w1, #12288                      ; =0x3000
	bl	_calloc
	mov	x1, x20
	str	x0, [x19, w20, uxtw #3]
LBB71_4:
	ldr	x0, [x19, w1, uxtw #3]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh137, Lloh138
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
Lloh139:
	adrp	x20, _xt_files@PAGE
Lloh140:
	add	x20, x20, _xt_files@PAGEOFF
LBB72_1:                                ; =>This Inner Loop Header: Depth=1
	ldr	x8, [x20, x19, lsl #3]
	cbz	x8, LBB72_3
; %bb.2:                                ;   in Loop: Header=BB72_1 Depth=1
	add	x19, x19, #1
	cmp	x19, #8
	b.ne	LBB72_1
	b	LBB72_5
LBB72_3:
	bl	_fopen
	cbz	x0, LBB72_5
; %bb.4:
	str	x0, [x20, x19, lsl #3]
	b	LBB72_6
LBB72_5:
	mov	w19, #-1                        ; =0xffffffff
LBB72_6:
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh139, Lloh140
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_read                  ; -- Begin function _xt_file_read
	.p2align	2
__xt_file_read:                         ; @_xt_file_read
	.cfi_startproc
; %bb.0:
	cmp	w0, #7
	b.hi	LBB73_3
; %bb.1:
Lloh141:
	adrp	x8, _xt_files@PAGE
Lloh142:
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
	bl	_fread
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
                                        ; kill: def $w0 killed $w0 killed $x0
	ret
LBB73_3:
	mov	w0, #-1                         ; =0xffffffff
                                        ; kill: def $w0 killed $w0 killed $x0
	ret
	.loh AdrpAdd	Lloh141, Lloh142
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_write                 ; -- Begin function _xt_file_write
	.p2align	2
__xt_file_write:                        ; @_xt_file_write
	.cfi_startproc
; %bb.0:
	cmp	w0, #7
	b.hi	LBB74_3
; %bb.1:
Lloh143:
	adrp	x8, _xt_files@PAGE
Lloh144:
	add	x8, x8, _xt_files@PAGEOFF
	ldr	x3, [x8, w0, uxtw #3]
	cbz	x3, LBB74_3
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
LBB74_3:
	mov	w0, #-1                         ; =0xffffffff
                                        ; kill: def $w0 killed $w0 killed $x0
	ret
	.loh AdrpAdd	Lloh143, Lloh144
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_close                 ; -- Begin function _xt_file_close
	.p2align	2
__xt_file_close:                        ; @_xt_file_close
	.cfi_startproc
; %bb.0:
	cmp	w0, #7
	b.hi	LBB75_4
; %bb.1:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
Lloh145:
	adrp	x19, _xt_files@PAGE
Lloh146:
	add	x19, x19, _xt_files@PAGEOFF
	ldr	x8, [x19, w0, uxtw #3]
	cbz	x8, LBB75_3
; %bb.2:
	mov	x20, x0
	mov	x0, x8
	bl	_fclose
	str	xzr, [x19, w20, uxtw #3]
LBB75_3:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
LBB75_4:
	ret
	.loh AdrpAdd	Lloh145, Lloh146
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
Lloh147:
	adrp	x1, l_.str.3@PAGE
Lloh148:
	add	x1, x1, l_.str.3@PAGEOFF
	bl	_fopen
	cbz	x0, LBB76_3
; %bb.1:
	mov	x19, x0
	mov	x1, #0                          ; =0x0
	mov	w2, #2                          ; =0x2
	bl	_fseek
	cbz	w0, LBB76_4
; %bb.2:
	mov	x0, x19
	bl	_fclose
LBB76_3:
	mov	w0, #-1                         ; =0xffffffff
	b	LBB76_5
LBB76_4:
	mov	x0, x19
	bl	_ftell
	mov	x20, x0
	mov	x0, x19
	bl	_fclose
	cmp	x20, #0
	csinv	w0, w20, wzr, ge
LBB76_5:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh147, Lloh148
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
Lloh149:
	adrp	x1, l_.str.3@PAGE
Lloh150:
	add	x1, x1, l_.str.3@PAGEOFF
	bl	_fopen
	cbz	x0, LBB77_2
; %bb.1:
	bl	_fclose
	mov	w0, #1                          ; =0x1
LBB77_2:
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh149, Lloh150
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
Lloh151:
	adrp	x8, l_.str.4@PAGE
Lloh152:
	add	x8, x8, l_.str.4@PAGEOFF
	cmp	x0, #0
	csel	x0, x8, x0, eq
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh151, Lloh152
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
	cbz	w0, LBB79_2
; %bb.1:
	bl	___error
	ldr	w8, [x0]
	cmp	w8, #17
	cset	w0, eq
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
LBB79_2:
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
Lloh153:
	adrp	x8, ___stderrp@GOTPAGE
Lloh154:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh155:
	ldr	x3, [x8]
Lloh156:
	adrp	x0, l_.str.5@PAGE
Lloh157:
	add	x0, x0, l_.str.5@PAGEOFF
	mov	w1, #70                         ; =0x46
	mov	w2, #1                          ; =0x1
	bl	_fwrite
	bl	_abort
	.loh AdrpAdd	Lloh156, Lloh157
	.loh AdrpLdrGotLdr	Lloh153, Lloh154, Lloh155
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_set_args                   ; -- Begin function _xt_set_args
	.p2align	2
__xt_set_args:                          ; @_xt_set_args
	.cfi_startproc
; %bb.0:
Lloh158:
	adrp	x8, _xt_argc_v@PAGE
	str	w0, [x8, _xt_argc_v@PAGEOFF]
Lloh159:
	adrp	x8, _xt_argv_v@PAGE
	str	x1, [x8, _xt_argv_v@PAGEOFF]
	ret
	.loh AdrpAdrp	Lloh158, Lloh159
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_argc                       ; -- Begin function _xt_argc
	.p2align	2
__xt_argc:                              ; @_xt_argc
	.cfi_startproc
; %bb.0:
Lloh160:
	adrp	x8, _xt_argc_v@PAGE
Lloh161:
	ldr	w0, [x8, _xt_argc_v@PAGEOFF]
	ret
	.loh AdrpLdr	Lloh160, Lloh161
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_argv                       ; -- Begin function _xt_argv
	.p2align	2
__xt_argv:                              ; @_xt_argv
	.cfi_startproc
; %bb.0:
	tbnz	w0, #31, LBB85_2
; %bb.1:
Lloh162:
	adrp	x8, _xt_argc_v@PAGE
Lloh163:
	ldr	w9, [x8, _xt_argc_v@PAGEOFF]
Lloh164:
	adrp	x8, _xt_argv_v@PAGE
Lloh165:
	ldr	x8, [x8, _xt_argv_v@PAGEOFF]
	cmp	w9, w0
	ccmp	x8, #0, #4, gt
	b.ne	LBB85_3
LBB85_2:
Lloh166:
	adrp	x0, l_.str.4@PAGE
Lloh167:
	add	x0, x0, l_.str.4@PAGEOFF
	ret
LBB85_3:
	ldr	x0, [x8, w0, uxtw #3]
	ret
	.loh AdrpLdr	Lloh164, Lloh165
	.loh AdrpAdrp	Lloh162, Lloh164
	.loh AdrpLdr	Lloh162, Lloh163
	.loh AdrpAdd	Lloh166, Lloh167
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
	cbz	x0, LBB87_4
; %bb.1:
	sub	x21, x0, x20
	cmp	x21, #1023
	b.hi	LBB87_11
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
	b.ne	LBB87_6
; %bb.3:
	mov	w8, #47                         ; =0x2f
	b	LBB87_5
LBB87_4:
	mov	w8, #46                         ; =0x2e
LBB87_5:
	strb	w8, [sp]
	strb	wzr, [sp, #1]
LBB87_6:
	mov	x0, sp
	bl	_opendir
	cbz	x0, LBB87_11
; %bb.7:
	mov	x20, x0
LBB87_8:                                ; =>This Inner Loop Header: Depth=1
	mov	x0, x20
	bl	_readdir
	cbz	x0, LBB87_12
; %bb.9:                                ;   in Loop: Header=BB87_8 Depth=1
	add	x0, x0, #21
	mov	x1, x19
	bl	_strcmp
	cbnz	w0, LBB87_8
; %bb.10:
	mov	w19, #1                         ; =0x1
	b	LBB87_13
LBB87_11:
	mov	w19, #0                         ; =0x0
	b	LBB87_14
LBB87_12:
	mov	w19, #0                         ; =0x0
LBB87_13:
	mov	x0, x20
	bl	_closedir
LBB87_14:
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
Lloh168:
	adrp	x8, __xt_threads_active@PAGE
Lloh169:
	ldr	w0, [x8, __xt_threads_active@PAGEOFF]
	ret
	.loh AdrpLdr	Lloh168, Lloh169
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_thread_create              ; -- Begin function _xt_thread_create
	.p2align	2
__xt_thread_create:                     ; @_xt_thread_create
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB89_11
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
	cbnz	w8, LBB89_3
; %bb.2:
Lloh170:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh171:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	mov	x1, #0                          ; =0x0
	bl	_pthread_mutex_init
	mov	w8, #1                          ; =0x1
	str	w8, [x19, __xt_threads_active@PAGEOFF]
LBB89_3:
	mov	w0, #16                         ; =0x10
	bl	_malloc
	cbz	x0, LBB89_10
; %bb.4:
	mov	x19, x0
	stp	x21, x20, [x0]
	mov	w0, #8                          ; =0x8
	bl	_malloc
	cbz	x0, LBB89_7
; %bb.5:
Lloh172:
	adrp	x2, _xt_thread_entry@PAGE
Lloh173:
	add	x2, x2, _xt_thread_entry@PAGEOFF
	mov	x20, x0
	mov	x1, #0                          ; =0x0
	mov	x3, x19
	bl	_pthread_create
	cbz	w0, LBB89_9
; %bb.6:
	mov	x0, x19
	bl	_free
	mov	x0, x20
	b	LBB89_8
LBB89_7:
	mov	x0, x19
LBB89_8:
	bl	_free
	mov	x0, #0                          ; =0x0
	b	LBB89_10
LBB89_9:
	mov	x0, x20
LBB89_10:
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
LBB89_11:
	ret
	.loh AdrpAdd	Lloh170, Lloh171
	.loh AdrpAdd	Lloh172, Lloh173
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
	cbz	x20, LBB90_2
; %bb.1:
	mov	x0, x19
	blr	x20
LBB90_2:
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
	cbz	x0, LBB91_2
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
LBB91_2:
	mov	w0, #-1                         ; =0xffffffff
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_thread_detach              ; -- Begin function _xt_thread_detach
	.p2align	2
__xt_thread_detach:                     ; @_xt_thread_detach
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB92_2
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
LBB92_2:
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
	cbz	x0, LBB97_4
; %bb.1:
	mov	x19, x0
	mov	x1, #0                          ; =0x0
	bl	_pthread_mutex_init
	cbz	w0, LBB97_3
; %bb.2:
	mov	x0, x19
	bl	_free
	mov	x0, #0                          ; =0x0
	b	LBB97_4
LBB97_3:
	mov	x0, x19
LBB97_4:
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
	cbz	x0, LBB98_2
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
LBB98_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_mutex_lock                 ; -- Begin function _xt_mutex_lock
	.p2align	2
__xt_mutex_lock:                        ; @_xt_mutex_lock
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB99_2
; %bb.1:
	b	_pthread_mutex_lock
LBB99_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_mutex_unlock               ; -- Begin function _xt_mutex_unlock
	.p2align	2
__xt_mutex_unlock:                      ; @_xt_mutex_unlock
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB100_2
; %bb.1:
	b	_pthread_mutex_unlock
LBB100_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_mutex_trylock              ; -- Begin function _xt_mutex_trylock
	.p2align	2
__xt_mutex_trylock:                     ; @_xt_mutex_trylock
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB101_2
; %bb.1:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	.cfi_def_cfa_offset 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	bl	_pthread_mutex_trylock
	cmp	w0, #0
	cset	w0, eq
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
LBB101_2:
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
	cbz	x0, LBB102_4
; %bb.1:
	mov	x19, x0
	mov	x1, #0                          ; =0x0
	bl	_pthread_cond_init
	cbz	w0, LBB102_3
; %bb.2:
	mov	x0, x19
	bl	_free
	mov	x0, #0                          ; =0x0
	b	LBB102_4
LBB102_3:
	mov	x0, x19
LBB102_4:
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
	cbz	x0, LBB103_2
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
LBB103_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_cond_wait                  ; -- Begin function _xt_cond_wait
	.p2align	2
__xt_cond_wait:                         ; @_xt_cond_wait
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB104_3
; %bb.1:
	cbz	x1, LBB104_3
; %bb.2:
	b	_pthread_cond_wait
LBB104_3:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_cond_signal                ; -- Begin function _xt_cond_signal
	.p2align	2
__xt_cond_signal:                       ; @_xt_cond_signal
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB105_2
; %bb.1:
	b	_pthread_cond_signal
LBB105_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_cond_broadcast             ; -- Begin function _xt_cond_broadcast
	.p2align	2
__xt_cond_broadcast:                    ; @_xt_cond_broadcast
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB106_2
; %bb.1:
	b	_pthread_cond_broadcast
LBB106_2:
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
	cbz	x0, LBB107_5
; %bb.1:
	mov	x20, x0
	mov	x1, #0                          ; =0x0
	bl	_pthread_mutex_init
	cbnz	w0, LBB107_4
; %bb.2:
	add	x0, x20, #64
	mov	x1, #0                          ; =0x0
	bl	_pthread_cond_init
	cbz	w0, LBB107_6
; %bb.3:
	mov	x0, x20
	bl	_pthread_mutex_destroy
LBB107_4:
	mov	x0, x20
	bl	_free
	mov	x0, #0                          ; =0x0
LBB107_5:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB107_6:
	bic	w8, w19, w19, asr #31
	mov	x0, x20
	str	w8, [x20, #112]
	b	LBB107_5
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_sem_free                   ; -- Begin function _xt_sem_free
	.p2align	2
__xt_sem_free:                          ; @_xt_sem_free
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
	add	x0, x0, #64
	bl	_pthread_cond_destroy
	mov	x0, x19
	bl	_pthread_mutex_destroy
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_free
LBB108_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_sem_wait                   ; -- Begin function _xt_sem_wait
	.p2align	2
__xt_sem_wait:                          ; @_xt_sem_wait
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB109_4
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
	b.gt	LBB109_3
LBB109_2:                               ; =>This Inner Loop Header: Depth=1
	add	x0, x19, #64
	mov	x1, x19
	bl	_pthread_cond_wait
	ldr	w8, [x19, #112]
	cmp	w8, #1
	b.lt	LBB109_2
LBB109_3:
	sub	w8, w8, #1
	str	w8, [x19, #112]
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB109_4:
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
	cbz	x0, LBB110_3
; %bb.1:
	mov	x19, x0
	bl	_pthread_mutex_lock
	ldr	w8, [x19, #112]
	subs	w8, w8, #1
	b.lt	LBB110_4
; %bb.2:
	str	w8, [x19, #112]
	mov	w20, #1                         ; =0x1
	b	LBB110_5
LBB110_3:
	mov	w20, #0                         ; =0x0
	b	LBB110_6
LBB110_4:
	mov	w20, #0                         ; =0x0
LBB110_5:
	mov	x0, x19
	bl	_pthread_mutex_unlock
LBB110_6:
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
	cbz	x0, LBB111_2
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
LBB111_2:
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
	b.eq	LBB113_2
; %bb.1:
	mov	w0, w0
	b	_pthread_setspecific
LBB113_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_tls_get                    ; -- Begin function _xt_tls_get
	.p2align	2
__xt_tls_get:                           ; @_xt_tls_get
	.cfi_startproc
; %bb.0:
	cmn	w0, #1
	b.eq	LBB114_2
; %bb.1:
	mov	w0, w0
	b	_pthread_getspecific
LBB114_2:
	mov	x0, #0                          ; =0x0
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_load_i32            ; -- Begin function _xt_atomic_load_i32
	.p2align	2
__xt_atomic_load_i32:                   ; @_xt_atomic_load_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB115_2
; %bb.1:
	ldar	w0, [x0]
LBB115_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_store_i32           ; -- Begin function _xt_atomic_store_i32
	.p2align	2
__xt_atomic_store_i32:                  ; @_xt_atomic_store_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB116_2
; %bb.1:
	stlr	w1, [x0]
LBB116_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_add_i32             ; -- Begin function _xt_atomic_add_i32
	.p2align	2
__xt_atomic_add_i32:                    ; @_xt_atomic_add_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB117_2
; %bb.1:
	ldaddal	w1, w8, [x0]
	add	w0, w8, w1
LBB117_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_xchg_i32            ; -- Begin function _xt_atomic_xchg_i32
	.p2align	2
__xt_atomic_xchg_i32:                   ; @_xt_atomic_xchg_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB118_2
; %bb.1:
	swpal	w1, w0, [x0]
LBB118_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_cas_i32             ; -- Begin function _xt_atomic_cas_i32
	.p2align	2
__xt_atomic_cas_i32:                    ; @_xt_atomic_cas_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB119_2
; %bb.1:
	mov	x8, x1
	casal	w8, w2, [x0]
	cmp	w8, w1
	cset	w0, eq
LBB119_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_load_ptr            ; -- Begin function _xt_atomic_load_ptr
	.p2align	2
__xt_atomic_load_ptr:                   ; @_xt_atomic_load_ptr
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB120_2
; %bb.1:
	ldar	x0, [x0]
LBB120_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_store_ptr           ; -- Begin function _xt_atomic_store_ptr
	.p2align	2
__xt_atomic_store_ptr:                  ; @_xt_atomic_store_ptr
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB121_2
; %bb.1:
	stlr	x1, [x0]
LBB121_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_cas_ptr             ; -- Begin function _xt_atomic_cas_ptr
	.p2align	2
__xt_atomic_cas_ptr:                    ; @_xt_atomic_cas_ptr
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB122_2
; %bb.1:
	mov	x8, x1
	casal	x8, x2, [x0]
	cmp	x8, x1
	cset	w0, eq
LBB122_2:
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
	cbz	x0, LBB123_35
; %bb.1:
	mov	x21, x2
	mov	x20, x1
	mov	x19, x0
	adrp	x23, __xt_threads_active@PAGE
	mov	w25, #1                         ; =0x1
	adrp	x24, _xt_sinit_n@PAGE
Lloh174:
	adrp	x26, _xt_sinit_flag@PAGE
Lloh175:
	add	x26, x26, _xt_sinit_flag@PAGEOFF
Lloh176:
	adrp	x27, _xt_sinit_owner@PAGE
Lloh177:
	add	x27, x27, _xt_sinit_owner@PAGEOFF
Lloh178:
	adrp	x22, _xt_rt_mtx@PAGE
Lloh179:
	add	x22, x22, _xt_rt_mtx@PAGEOFF
	b	LBB123_4
LBB123_2:                               ;   in Loop: Header=BB123_4 Depth=1
	mov	w8, #1                          ; =0x1
LBB123_3:                               ;   in Loop: Header=BB123_4 Depth=1
	cbnz	w8, LBB123_23
LBB123_4:                               ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB123_17 Depth 2
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB123_6
; %bb.5:                                ;   in Loop: Header=BB123_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_lock
LBB123_6:                               ;   in Loop: Header=BB123_4 Depth=1
	ldrb	w8, [x19]
	cbz	w8, LBB123_10
; %bb.7:                                ;   in Loop: Header=BB123_4 Depth=1
	cmp	w8, #2
	b.ne	LBB123_14
LBB123_8:                               ;   in Loop: Header=BB123_4 Depth=1
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB123_2
; %bb.9:                                ;   in Loop: Header=BB123_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_unlock
	b	LBB123_2
LBB123_10:                              ;   in Loop: Header=BB123_4 Depth=1
	strb	w25, [x19]
	ldrsw	x8, [x24, _xt_sinit_n@PAGEOFF]
	cmp	w8, #31
	b.gt	LBB123_12
; %bb.11:                               ;   in Loop: Header=BB123_4 Depth=1
	str	x19, [x26, x8, lsl #3]
	bl	_pthread_self
	lsr	x8, x0, #4
	lsr	x9, x0, #32
	eor	w8, w8, w9
	ldrsw	x9, [x24, _xt_sinit_n@PAGEOFF]
	str	w8, [x27, x9, lsl #2]
	add	w8, w9, #1
	str	w8, [x24, _xt_sinit_n@PAGEOFF]
LBB123_12:                              ;   in Loop: Header=BB123_4 Depth=1
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB123_22
; %bb.13:                               ;   in Loop: Header=BB123_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_unlock
	mov	w8, #2                          ; =0x2
	b	LBB123_3
LBB123_14:                              ;   in Loop: Header=BB123_4 Depth=1
	bl	_pthread_self
	ldr	w8, [x24, _xt_sinit_n@PAGEOFF]
	cmp	w8, #1
	b.lt	LBB123_19
; %bb.15:                               ;   in Loop: Header=BB123_4 Depth=1
	lsr	x9, x0, #4
	lsr	x10, x0, #32
	eor	w9, w9, w10
	mov	x10, x26
	mov	x11, x27
	b	LBB123_17
LBB123_16:                              ;   in Loop: Header=BB123_17 Depth=2
	add	x11, x11, #4
	add	x10, x10, #8
	subs	x8, x8, #1
	b.eq	LBB123_19
LBB123_17:                              ;   Parent Loop BB123_4 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldr	x12, [x10]
	cmp	x12, x19
	b.ne	LBB123_16
; %bb.18:                               ;   in Loop: Header=BB123_17 Depth=2
	ldr	w12, [x11]
	cmp	w12, w9
	b.ne	LBB123_16
	b	LBB123_8
LBB123_19:                              ;   in Loop: Header=BB123_4 Depth=1
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB123_21
; %bb.20:                               ;   in Loop: Header=BB123_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_unlock
LBB123_21:                              ;   in Loop: Header=BB123_4 Depth=1
	bl	_sched_yield
	mov	w8, #0                          ; =0x0
	b	LBB123_3
LBB123_22:                              ;   in Loop: Header=BB123_4 Depth=1
	mov	w8, #2                          ; =0x2
	b	LBB123_3
LBB123_23:
	cmp	w8, #1
	b.eq	LBB123_35
; %bb.24:
	cbz	x20, LBB123_26
; %bb.25:
	mov	x0, x21
	blr	x20
LBB123_26:
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB123_28
; %bb.27:
Lloh180:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh181:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB123_28:
	mov	w8, #2                          ; =0x2
	strb	w8, [x19]
	ldr	w8, [x24, _xt_sinit_n@PAGEOFF]
	cmp	w8, #1
	b.lt	LBB123_32
; %bb.29:
Lloh182:
	adrp	x9, _xt_sinit_owner@PAGE
Lloh183:
	add	x9, x9, _xt_sinit_owner@PAGEOFF
Lloh184:
	adrp	x10, _xt_sinit_flag@PAGE
Lloh185:
	add	x10, x10, _xt_sinit_flag@PAGEOFF
	mov	x13, x8
	mov	x12, x10
	mov	x11, x9
LBB123_30:                              ; =>This Inner Loop Header: Depth=1
	ldr	x14, [x12]
	cmp	x14, x19
	b.eq	LBB123_34
; %bb.31:                               ;   in Loop: Header=BB123_30 Depth=1
	add	x11, x11, #4
	add	x12, x12, #8
	subs	x13, x13, #1
	b.ne	LBB123_30
LBB123_32:
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB123_35
LBB123_33:
Lloh186:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh187:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #80]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #64]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp], #96             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB123_34:
	sxtw	x8, w8
	sub	x8, x8, #1
	str	w8, [x24, _xt_sinit_n@PAGEOFF]
	ldr	x10, [x10, x8, lsl #3]
	str	x10, [x12]
	ldr	w8, [x9, x8, lsl #2]
	str	w8, [x11]
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbnz	w8, LBB123_33
LBB123_35:
	ldp	x29, x30, [sp, #80]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #64]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp], #96             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh178, Lloh179
	.loh AdrpAdd	Lloh176, Lloh177
	.loh AdrpAdd	Lloh174, Lloh175
	.loh AdrpAdd	Lloh180, Lloh181
	.loh AdrpAdd	Lloh184, Lloh185
	.loh AdrpAdd	Lloh182, Lloh183
	.loh AdrpAdd	Lloh186, Lloh187
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

	.private_extern	___xt_stack_guard       ; @__xt_stack_guard
	.comm	___xt_stack_guard,8,3
l_.str.5:                               ; @.str.5
	.asciz	"xcc: stack smashing detected (a local array was written past its end)\n"

.zerofill __DATA,__bss,_xt_argc_v,4,2   ; @xt_argc_v
.zerofill __DATA,__bss,_xt_argv_v,8,3   ; @xt_argv_v
	.globl	__xt_threads_active             ; @_xt_threads_active
.zerofill __DATA,__common,__xt_threads_active,4,2
.zerofill __DATA,__bss,_xt_rt_mtx,64,3  ; @xt_rt_mtx
.zerofill __DATA,__bss,_xt_sinit_n,4,2  ; @xt_sinit_n
.zerofill __DATA,__bss,_xt_sinit_flag,256,3 ; @xt_sinit_flag
.zerofill __DATA,__bss,_xt_sinit_owner,128,2 ; @xt_sinit_owner
l_.str.6:                               ; @.str.6
	.asciz	"xcc: an allocation of %lu x %lu bytes overflows\n"

.zerofill __DATA,__bss,_xt_simd_n,8,3   ; @xt_simd_n
.zerofill __DATA,__bss,_xt_simd_cap,8,3 ; @xt_simd_cap
l_.str.7:                               ; @.str.7
	.asciz	"%.*f"

.subsections_via_symbols
