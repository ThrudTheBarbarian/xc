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
	mov	x20, x2
	mov	x19, x1
	cmp	x0, #1
	csinc	x21, x0, xzr, hi
	mul	x8, x21, x1
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
	stur	x19, [x0, #4]
	stur	x21, [x0, #12]
	stur	x20, [x0, #20]
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
	stp	x21, x19, [sp]
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
	cmp	x0, #1
	csinc	x19, x0, xzr, hi
	mov	w8, #16                         ; =0x10
	cmp	x0, #16
	csel	x8, x0, x8, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB1_2
; %bb.1:
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
LBB1_2:
	mov	x0, x19
	bl	__xtc_new_u8.cold.1
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
	cmp	x0, #1
	csinc	x19, x0, xzr, hi
	mov	w8, #16                         ; =0x10
	cmp	x0, #16
	csel	x8, x0, x8, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB2_2
; %bb.1:
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
LBB2_2:
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
	cmp	x0, #1
	csinc	x19, x0, xzr, hi
	lsl	x8, x19, #1
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB3_2
; %bb.1:
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
LBB3_2:
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
	cmp	x0, #1
	csinc	x19, x0, xzr, hi
	lsl	x8, x19, #1
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB4_2
; %bb.1:
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
LBB4_2:
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
	cmp	x0, #1
	csinc	x19, x0, xzr, hi
	lsl	x8, x19, #2
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB5_2
; %bb.1:
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
LBB5_2:
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
	cmp	x0, #1
	csinc	x19, x0, xzr, hi
	lsl	x8, x19, #2
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB6_2
; %bb.1:
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
LBB6_2:
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
	cmp	x0, #1
	csinc	x19, x0, xzr, hi
	lsl	x8, x19, #3
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB7_2
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
LBB7_2:
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
	cmp	x0, #1
	csinc	x19, x0, xzr, hi
	lsl	x8, x19, #3
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB8_2
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
LBB8_2:
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
	cmp	x0, #1
	csinc	x19, x0, xzr, hi
	lsl	x8, x19, #3
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB9_2
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
LBB9_2:
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
	cmp	x0, #1
	csinc	x19, x0, xzr, hi
	mov	w8, #16                         ; =0x10
	cmp	x0, #16
	csel	x8, x0, x8, hi
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
	stur	x20, [x0, #4]
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
	cmp	x0, #1
	csinc	x19, x0, xzr, hi
	lsl	x8, x19, #2
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB11_2
; %bb.1:
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
LBB11_2:
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
	cmp	x0, #1
	csinc	x19, x0, xzr, hi
	lsl	x8, x19, #3
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB12_2
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
LBB12_2:
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
	cmp	x0, #1
	csinc	x19, x0, xzr, hi
	lsl	x8, x19, #3
	mov	w9, #16                         ; =0x10
	cmp	x8, #16
	csel	x8, x8, x9, hi
	mov	w20, #1                         ; =0x1
	add	x1, x8, #40
	mov	w0, #1                          ; =0x1
	bl	_calloc
	cbz	x0, LBB13_2
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
LBB13_2:
	mov	x0, x19
	bl	__xtc_new_string.cold.1
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
	cbz	x0, LBB15_7
; %bb.1:
	adrp	x20, __xt_threads_active@PAGE
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB15_3
; %bb.2:
Lloh5:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh6:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB15_3:
	ldur	x8, [x19, #-12]
	cbz	x8, LBB15_5
LBB15_4:                                ; =>This Inner Loop Header: Depth=1
	ldur	x9, [x8, #-8]
	stp	xzr, xzr, [x8, #-8]
	stur	xzr, [x8, #-16]
	mov	x8, x9
	cbnz	x9, LBB15_4
LBB15_5:
	stur	xzr, [x19, #-12]
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB15_7
; %bb.6:
Lloh7:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh8:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_unlock
LBB15_7:
	ldur	x21, [x19, #-20]
	cbz	x21, LBB15_11
; %bb.8:
	ldur	x22, [x19, #-36]
	ldur	x23, [x19, #-28]
	mov	w8, #-2147483648                ; =0x80000000
	stur	w8, [x19, #-4]
	cbz	x23, LBB15_11
; %bb.9:
	mov	x20, x19
LBB15_10:                               ; =>This Inner Loop Header: Depth=1
	mov	x0, x20
	blr	x21
	add	x20, x20, x22
	subs	x23, x23, #1
	b.ne	LBB15_10
LBB15_11:
	sub	x0, x19, #40
	ldp	x29, x30, [sp, #48]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #32]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #16]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp], #64             ; 16-byte Folded Reload
	b	_free
	.loh AdrpAdd	Lloh5, Lloh6
	.loh AdrpAdd	Lloh7, Lloh8
	.cfi_endproc
                                        ; -- End function
	.globl	__xtc_weak_zero_for             ; -- Begin function _xtc_weak_zero_for
	.p2align	2
__xtc_weak_zero_for:                    ; @_xtc_weak_zero_for
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB16_7
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
	cbz	w8, LBB16_3
; %bb.2:
Lloh9:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh10:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB16_3:
	ldur	x8, [x19, #-12]
	cbz	x8, LBB16_5
LBB16_4:                                ; =>This Inner Loop Header: Depth=1
	ldur	x9, [x8, #-8]
	stp	xzr, xzr, [x8, #-8]
	stur	xzr, [x8, #-16]
	mov	x8, x9
	cbnz	x9, LBB16_4
LBB16_5:
	stur	xzr, [x19, #-12]
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	cbz	w8, LBB16_7
; %bb.6:
Lloh11:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh12:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	b	_pthread_mutex_unlock
LBB16_7:
	ret
	.loh AdrpAdd	Lloh9, Lloh10
	.loh AdrpAdd	Lloh11, Lloh12
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
	cbz	w8, LBB17_2
; %bb.1:
Lloh13:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh14:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB17_2:
	mov	x8, x19
	ldr	x9, [x8, #-16]!
	cbz	x9, LBB17_7
; %bb.3:
	ldr	x10, [x9]
	cmp	x10, x19
	b.ne	LBB17_6
; %bb.4:
	ldur	x10, [x19, #-8]
	str	x10, [x9]
	cbz	x10, LBB17_6
; %bb.5:
	stur	x9, [x10, #-16]
LBB17_6:
	stp	xzr, xzr, [x8]
LBB17_7:
	ldr	w8, [x20, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB17_9
; %bb.8:
Lloh15:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh16:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB17_9:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh13, Lloh14
	.loh AdrpAdd	Lloh15, Lloh16
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_rt_lock                    ; -- Begin function _xt_rt_lock
	.p2align	2
__xt_rt_lock:                           ; @_xt_rt_lock
	.cfi_startproc
; %bb.0:
Lloh17:
	adrp	x8, __xt_threads_active@PAGE
Lloh18:
	ldr	w8, [x8, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB18_2
; %bb.1:
Lloh19:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh20:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	b	_pthread_mutex_lock
LBB18_2:
	ret
	.loh AdrpLdr	Lloh17, Lloh18
	.loh AdrpAdd	Lloh19, Lloh20
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_rt_unlock                  ; -- Begin function _xt_rt_unlock
	.p2align	2
__xt_rt_unlock:                         ; @_xt_rt_unlock
	.cfi_startproc
; %bb.0:
Lloh21:
	adrp	x8, __xt_threads_active@PAGE
Lloh22:
	ldr	w8, [x8, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB19_2
; %bb.1:
Lloh23:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh24:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	b	_pthread_mutex_unlock
LBB19_2:
	ret
	.loh AdrpLdr	Lloh21, Lloh22
	.loh AdrpAdd	Lloh23, Lloh24
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
	cbz	w8, LBB20_2
; %bb.1:
Lloh25:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh26:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB20_2:
	mov	x8, x20
	ldr	x9, [x8, #-16]!
	cbz	x9, LBB20_7
; %bb.3:
	ldr	x10, [x9]
	cmp	x10, x20
	b.ne	LBB20_6
; %bb.4:
	ldur	x10, [x20, #-8]
	str	x10, [x9]
	cbz	x10, LBB20_6
; %bb.5:
	stur	x9, [x10, #-16]
LBB20_6:
	stp	xzr, xzr, [x8]
LBB20_7:
	cbz	x19, LBB20_12
; %bb.8:
	ldur	w8, [x19, #-40]
	mov	w9, #20290                      ; =0x4f42
	movk	w9, #22612, lsl #16
	cmp	w8, w9
	b.ne	LBB20_12
; %bb.9:
	ldr	x8, [x19, #-12]!
	mov	x9, x20
	str	x8, [x9, #-8]!
	stur	x19, [x9, #-8]
	cbz	x8, LBB20_11
; %bb.10:
	stur	x9, [x8, #-16]
LBB20_11:
	str	x20, [x19]
LBB20_12:
	ldr	w8, [x21, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB20_14
; %bb.13:
Lloh27:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh28:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB20_14:
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh25, Lloh26
	.loh AdrpAdd	Lloh27, Lloh28
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
Lloh29:
	adrp	x2, l_.str.1@PAGE
Lloh30:
	add	x2, x2, l_.str.1@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB23_1:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB23_1
; %bb.2:
	sub	x2, x8, #1
	add	x1, sp, #16
	mov	w0, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.loh AdrpAdd	Lloh29, Lloh30
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
Lloh31:
	adrp	x2, l_.str.2@PAGE
Lloh32:
	add	x2, x2, l_.str.2@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB24_1:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB24_1
; %bb.2:
	sub	x2, x8, #1
	add	x1, sp, #16
	mov	w0, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.loh AdrpAdd	Lloh31, Lloh32
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
	cbz	w0, LBB25_7
; %bb.1:
	add	w8, w0, #1
	str	d0, [sp, #8]
	str	x8, [sp]
Lloh33:
	adrp	x2, l_.str.5@PAGE
Lloh34:
	add	x2, x2, l_.str.5@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB25_2:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB25_2
; %bb.3:
	cmp	x8, #1
	b.eq	LBB25_5
; %bb.4:
	add	x9, sp, #16
	add	x8, x9, x8
	sturb	wzr, [x8, #-2]
LBB25_5:
	mov	x8, #0                          ; =0x0
	add	x9, sp, #16
LBB25_6:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w10, [x9, x8]
	add	x8, x8, #1
	cbnz	w10, LBB25_6
	b	LBB25_9
LBB25_7:
	str	d0, [sp]
Lloh35:
	adrp	x2, l_.str.1@PAGE
Lloh36:
	add	x2, x2, l_.str.1@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB25_8:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB25_8
LBB25_9:
	sub	x2, x8, #1
	add	x1, sp, #16
	mov	w0, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.loh AdrpAdd	Lloh33, Lloh34
	.loh AdrpAdd	Lloh35, Lloh36
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
	cbz	w0, LBB26_7
; %bb.1:
	add	w8, w0, #1
	str	d0, [sp, #8]
	str	x8, [sp]
Lloh37:
	adrp	x2, l_.str.5@PAGE
Lloh38:
	add	x2, x2, l_.str.5@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB26_2:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB26_2
; %bb.3:
	cmp	x8, #1
	b.eq	LBB26_5
; %bb.4:
	add	x9, sp, #16
	add	x8, x9, x8
	sturb	wzr, [x8, #-2]
LBB26_5:
	mov	x8, #0                          ; =0x0
	add	x9, sp, #16
LBB26_6:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w10, [x9, x8]
	add	x8, x8, #1
	cbnz	w10, LBB26_6
	b	LBB26_9
LBB26_7:
	str	d0, [sp]
Lloh39:
	adrp	x2, l_.str.2@PAGE
Lloh40:
	add	x2, x2, l_.str.2@PAGEOFF
	add	x19, sp, #16
	add	x0, sp, #16
	mov	w1, #64                         ; =0x40
	bl	_snprintf
	mov	x8, #0                          ; =0x0
LBB26_8:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, LBB26_8
LBB26_9:
	sub	x2, x8, #1
	add	x1, sp, #16
	mov	w0, #1                          ; =0x1
	bl	_write
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.loh AdrpAdd	Lloh37, Lloh38
	.loh AdrpAdd	Lloh39, Lloh40
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
	tbnz	w8, #0, LBB44_2
; %bb.1:
	mov	w20, #1                         ; =0x1
	mov	w0, #1                          ; =0x1
	bl	_srandom
	strb	w20, [x19, _xt_rand_seeded@PAGEOFF]
LBB44_2:
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
	tbnz	w8, #0, LBB45_2
; %bb.1:
	mov	w20, #1                         ; =0x1
	mov	w0, #1                          ; =0x1
	bl	_srandom
	strb	w20, [x19, _xt_rand_seeded@PAGEOFF]
LBB45_2:
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
	tbnz	w8, #0, LBB46_2
; %bb.1:
	mov	w20, #1                         ; =0x1
	mov	w0, #1                          ; =0x1
	bl	_srandom
	strb	w20, [x19, _xt_rand_seeded@PAGEOFF]
LBB46_2:
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
Lloh41:
	adrp	x8, _xt_clk_origin@PAGE
Lloh42:
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
	.loh AdrpLdr	Lloh41, Lloh42
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
	b.ls	LBB50_2
; %bb.1:
	mov	x0, #0                          ; =0x0
	ret
LBB50_2:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov	w8, w0
Lloh43:
	adrp	x9, __xtc_bank_regions@PAGE
Lloh44:
	add	x9, x9, __xtc_bank_regions@PAGEOFF
	add	x19, x9, x8, lsl #11
	ldr	x8, [x19, w1, uxtw #3]
	cbnz	x8, LBB50_4
; %bb.3:
	mov	w0, #1                          ; =0x1
	mov	x20, x1
	mov	w1, #12288                      ; =0x3000
	bl	_calloc
	mov	x1, x20
	str	x0, [x19, w20, uxtw #3]
LBB50_4:
	ldr	x0, [x19, w1, uxtw #3]
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh43, Lloh44
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
Lloh45:
	adrp	x20, _xt_files@PAGE
Lloh46:
	add	x20, x20, _xt_files@PAGEOFF
LBB51_1:                                ; =>This Inner Loop Header: Depth=1
	ldr	x8, [x20, x19, lsl #3]
	cbz	x8, LBB51_3
; %bb.2:                                ;   in Loop: Header=BB51_1 Depth=1
	add	x19, x19, #1
	cmp	x19, #8
	b.ne	LBB51_1
	b	LBB51_5
LBB51_3:
	bl	_fopen
	cbz	x0, LBB51_5
; %bb.4:
	str	x0, [x20, x19, lsl #3]
	b	LBB51_6
LBB51_5:
	mov	w19, #-1                        ; =0xffffffff
LBB51_6:
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh45, Lloh46
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_read                  ; -- Begin function _xt_file_read
	.p2align	2
__xt_file_read:                         ; @_xt_file_read
	.cfi_startproc
; %bb.0:
	cmp	w0, #7
	b.hi	LBB52_3
; %bb.1:
Lloh47:
	adrp	x8, _xt_files@PAGE
Lloh48:
	add	x8, x8, _xt_files@PAGEOFF
	ldr	x3, [x8, w0, uxtw #3]
	cbz	x3, LBB52_3
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
LBB52_3:
	mov	w0, #-1                         ; =0xffffffff
                                        ; kill: def $w0 killed $w0 killed $x0
	ret
	.loh AdrpAdd	Lloh47, Lloh48
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_write                 ; -- Begin function _xt_file_write
	.p2align	2
__xt_file_write:                        ; @_xt_file_write
	.cfi_startproc
; %bb.0:
	cmp	w0, #7
	b.hi	LBB53_3
; %bb.1:
Lloh49:
	adrp	x8, _xt_files@PAGE
Lloh50:
	add	x8, x8, _xt_files@PAGEOFF
	ldr	x3, [x8, w0, uxtw #3]
	cbz	x3, LBB53_3
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
LBB53_3:
	mov	w0, #-1                         ; =0xffffffff
                                        ; kill: def $w0 killed $w0 killed $x0
	ret
	.loh AdrpAdd	Lloh49, Lloh50
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_file_close                 ; -- Begin function _xt_file_close
	.p2align	2
__xt_file_close:                        ; @_xt_file_close
	.cfi_startproc
; %bb.0:
	cmp	w0, #7
	b.hi	LBB54_4
; %bb.1:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
Lloh51:
	adrp	x19, _xt_files@PAGE
Lloh52:
	add	x19, x19, _xt_files@PAGEOFF
	ldr	x8, [x19, w0, uxtw #3]
	cbz	x8, LBB54_3
; %bb.2:
	mov	x20, x0
	mov	x0, x8
	bl	_fclose
	str	xzr, [x19, w20, uxtw #3]
LBB54_3:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
LBB54_4:
	ret
	.loh AdrpAdd	Lloh51, Lloh52
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
Lloh53:
	adrp	x1, l_.str.3@PAGE
Lloh54:
	add	x1, x1, l_.str.3@PAGEOFF
	bl	_fopen
	cbz	x0, LBB55_3
; %bb.1:
	mov	x19, x0
	mov	x1, #0                          ; =0x0
	mov	w2, #2                          ; =0x2
	bl	_fseek
	cbz	w0, LBB55_4
; %bb.2:
	mov	x0, x19
	bl	_fclose
LBB55_3:
	mov	w0, #-1                         ; =0xffffffff
	b	LBB55_5
LBB55_4:
	mov	x0, x19
	bl	_ftell
	mov	x20, x0
	mov	x0, x19
	bl	_fclose
	cmp	x20, #0
	csinv	w0, w20, wzr, ge
LBB55_5:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh53, Lloh54
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
Lloh55:
	adrp	x1, l_.str.3@PAGE
Lloh56:
	add	x1, x1, l_.str.3@PAGEOFF
	bl	_fopen
	cbz	x0, LBB56_2
; %bb.1:
	bl	_fclose
	mov	w0, #1                          ; =0x1
LBB56_2:
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh55, Lloh56
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
Lloh57:
	adrp	x8, l_.str.4@PAGE
Lloh58:
	add	x8, x8, l_.str.4@PAGEOFF
	cmp	x0, #0
	csel	x0, x8, x0, eq
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh57, Lloh58
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
	cbz	w0, LBB58_2
; %bb.1:
	bl	___error
	ldr	w8, [x0]
	cmp	w8, #17
	cset	w0, eq
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
	ret
LBB58_2:
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
Lloh59:
	adrp	x8, _xt_argc_v@PAGE
	str	w0, [x8, _xt_argc_v@PAGEOFF]
Lloh60:
	adrp	x8, _xt_argv_v@PAGE
	str	x1, [x8, _xt_argv_v@PAGEOFF]
	ret
	.loh AdrpAdrp	Lloh59, Lloh60
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_argc                       ; -- Begin function _xt_argc
	.p2align	2
__xt_argc:                              ; @_xt_argc
	.cfi_startproc
; %bb.0:
Lloh61:
	adrp	x8, _xt_argc_v@PAGE
Lloh62:
	ldr	w0, [x8, _xt_argc_v@PAGEOFF]
	ret
	.loh AdrpLdr	Lloh61, Lloh62
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_argv                       ; -- Begin function _xt_argv
	.p2align	2
__xt_argv:                              ; @_xt_argv
	.cfi_startproc
; %bb.0:
	tbnz	w0, #31, LBB62_2
; %bb.1:
Lloh63:
	adrp	x8, _xt_argc_v@PAGE
Lloh64:
	ldr	w9, [x8, _xt_argc_v@PAGEOFF]
Lloh65:
	adrp	x8, _xt_argv_v@PAGE
Lloh66:
	ldr	x8, [x8, _xt_argv_v@PAGEOFF]
	cmp	w9, w0
	ccmp	x8, #0, #4, gt
	b.ne	LBB62_3
LBB62_2:
Lloh67:
	adrp	x0, l_.str.4@PAGE
Lloh68:
	add	x0, x0, l_.str.4@PAGEOFF
	ret
LBB62_3:
	ldr	x0, [x8, w0, uxtw #3]
	ret
	.loh AdrpLdr	Lloh65, Lloh66
	.loh AdrpAdrp	Lloh63, Lloh65
	.loh AdrpLdr	Lloh63, Lloh64
	.loh AdrpAdd	Lloh67, Lloh68
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
	cbz	x0, LBB64_4
; %bb.1:
	sub	x21, x0, x20
	cmp	x21, #1023
	b.hi	LBB64_11
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
	b.ne	LBB64_6
; %bb.3:
	mov	w8, #47                         ; =0x2f
	b	LBB64_5
LBB64_4:
	mov	w8, #46                         ; =0x2e
LBB64_5:
	strb	w8, [sp]
	strb	wzr, [sp, #1]
LBB64_6:
	mov	x0, sp
	bl	_opendir
	cbz	x0, LBB64_11
; %bb.7:
	mov	x20, x0
LBB64_8:                                ; =>This Inner Loop Header: Depth=1
	mov	x0, x20
	bl	_readdir
	cbz	x0, LBB64_12
; %bb.9:                                ;   in Loop: Header=BB64_8 Depth=1
	add	x0, x0, #21
	mov	x1, x19
	bl	_strcmp
	cbnz	w0, LBB64_8
; %bb.10:
	mov	w19, #1                         ; =0x1
	b	LBB64_13
LBB64_11:
	mov	w19, #0                         ; =0x0
	b	LBB64_14
LBB64_12:
	mov	w19, #0                         ; =0x0
LBB64_13:
	mov	x0, x20
	bl	_closedir
LBB64_14:
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
Lloh69:
	adrp	x8, __xt_threads_active@PAGE
Lloh70:
	ldr	w0, [x8, __xt_threads_active@PAGEOFF]
	ret
	.loh AdrpLdr	Lloh69, Lloh70
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_thread_create              ; -- Begin function _xt_thread_create
	.p2align	2
__xt_thread_create:                     ; @_xt_thread_create
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB66_11
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
	cbnz	w8, LBB66_3
; %bb.2:
Lloh71:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh72:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	mov	x1, #0                          ; =0x0
	bl	_pthread_mutex_init
	mov	w8, #1                          ; =0x1
	str	w8, [x19, __xt_threads_active@PAGEOFF]
LBB66_3:
	mov	w0, #16                         ; =0x10
	bl	_malloc
	cbz	x0, LBB66_10
; %bb.4:
	mov	x19, x0
	stp	x21, x20, [x0]
	mov	w0, #8                          ; =0x8
	bl	_malloc
	cbz	x0, LBB66_7
; %bb.5:
Lloh73:
	adrp	x2, _xt_thread_entry@PAGE
Lloh74:
	add	x2, x2, _xt_thread_entry@PAGEOFF
	mov	x20, x0
	mov	x1, #0                          ; =0x0
	mov	x3, x19
	bl	_pthread_create
	cbz	w0, LBB66_9
; %bb.6:
	mov	x0, x19
	bl	_free
	mov	x0, x20
	b	LBB66_8
LBB66_7:
	mov	x0, x19
LBB66_8:
	bl	_free
	mov	x0, #0                          ; =0x0
	b	LBB66_10
LBB66_9:
	mov	x0, x20
LBB66_10:
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
LBB66_11:
	ret
	.loh AdrpAdd	Lloh71, Lloh72
	.loh AdrpAdd	Lloh73, Lloh74
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
	cbz	x20, LBB67_2
; %bb.1:
	mov	x0, x19
	blr	x20
LBB67_2:
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
	cbz	x0, LBB68_2
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
LBB68_2:
	mov	w0, #-1                         ; =0xffffffff
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_thread_detach              ; -- Begin function _xt_thread_detach
	.p2align	2
__xt_thread_detach:                     ; @_xt_thread_detach
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB69_2
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
LBB69_2:
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
	cbz	x0, LBB74_4
; %bb.1:
	mov	x19, x0
	mov	x1, #0                          ; =0x0
	bl	_pthread_mutex_init
	cbz	w0, LBB74_3
; %bb.2:
	mov	x0, x19
	bl	_free
	mov	x0, #0                          ; =0x0
	b	LBB74_4
LBB74_3:
	mov	x0, x19
LBB74_4:
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
	cbz	x0, LBB75_2
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
LBB75_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_mutex_lock                 ; -- Begin function _xt_mutex_lock
	.p2align	2
__xt_mutex_lock:                        ; @_xt_mutex_lock
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB76_2
; %bb.1:
	b	_pthread_mutex_lock
LBB76_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_mutex_unlock               ; -- Begin function _xt_mutex_unlock
	.p2align	2
__xt_mutex_unlock:                      ; @_xt_mutex_unlock
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB77_2
; %bb.1:
	b	_pthread_mutex_unlock
LBB77_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_mutex_trylock              ; -- Begin function _xt_mutex_trylock
	.p2align	2
__xt_mutex_trylock:                     ; @_xt_mutex_trylock
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB78_2
; %bb.1:
	stp	x29, x30, [sp, #-16]!           ; 16-byte Folded Spill
	.cfi_def_cfa_offset 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	bl	_pthread_mutex_trylock
	cmp	w0, #0
	cset	w0, eq
	ldp	x29, x30, [sp], #16             ; 16-byte Folded Reload
LBB78_2:
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
	cbz	x0, LBB79_4
; %bb.1:
	mov	x19, x0
	mov	x1, #0                          ; =0x0
	bl	_pthread_cond_init
	cbz	w0, LBB79_3
; %bb.2:
	mov	x0, x19
	bl	_free
	mov	x0, #0                          ; =0x0
	b	LBB79_4
LBB79_3:
	mov	x0, x19
LBB79_4:
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
	cbz	x0, LBB80_2
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
LBB80_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_cond_wait                  ; -- Begin function _xt_cond_wait
	.p2align	2
__xt_cond_wait:                         ; @_xt_cond_wait
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB81_3
; %bb.1:
	cbz	x1, LBB81_3
; %bb.2:
	b	_pthread_cond_wait
LBB81_3:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_cond_signal                ; -- Begin function _xt_cond_signal
	.p2align	2
__xt_cond_signal:                       ; @_xt_cond_signal
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB82_2
; %bb.1:
	b	_pthread_cond_signal
LBB82_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_cond_broadcast             ; -- Begin function _xt_cond_broadcast
	.p2align	2
__xt_cond_broadcast:                    ; @_xt_cond_broadcast
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB83_2
; %bb.1:
	b	_pthread_cond_broadcast
LBB83_2:
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
	cbz	x0, LBB84_5
; %bb.1:
	mov	x20, x0
	mov	x1, #0                          ; =0x0
	bl	_pthread_mutex_init
	cbnz	w0, LBB84_4
; %bb.2:
	add	x0, x20, #64
	mov	x1, #0                          ; =0x0
	bl	_pthread_cond_init
	cbz	w0, LBB84_6
; %bb.3:
	mov	x0, x20
	bl	_pthread_mutex_destroy
LBB84_4:
	mov	x0, x20
	bl	_free
	mov	x0, #0                          ; =0x0
LBB84_5:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB84_6:
	bic	w8, w19, w19, asr #31
	mov	x0, x20
	str	w8, [x20, #112]
	b	LBB84_5
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_sem_free                   ; -- Begin function _xt_sem_free
	.p2align	2
__xt_sem_free:                          ; @_xt_sem_free
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
	mov	x19, x0
	add	x0, x0, #64
	bl	_pthread_cond_destroy
	mov	x0, x19
	bl	_pthread_mutex_destroy
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_free
LBB85_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_sem_wait                   ; -- Begin function _xt_sem_wait
	.p2align	2
__xt_sem_wait:                          ; @_xt_sem_wait
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB86_4
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
	b.gt	LBB86_3
LBB86_2:                                ; =>This Inner Loop Header: Depth=1
	add	x0, x19, #64
	mov	x1, x19
	bl	_pthread_cond_wait
	ldr	w8, [x19, #112]
	cmp	w8, #1
	b.lt	LBB86_2
LBB86_3:
	sub	w8, w8, #1
	str	w8, [x19, #112]
	mov	x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB86_4:
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
	cbz	x0, LBB87_3
; %bb.1:
	mov	x19, x0
	bl	_pthread_mutex_lock
	ldr	w8, [x19, #112]
	subs	w8, w8, #1
	b.lt	LBB87_4
; %bb.2:
	str	w8, [x19, #112]
	mov	w20, #1                         ; =0x1
	b	LBB87_5
LBB87_3:
	mov	w20, #0                         ; =0x0
	b	LBB87_6
LBB87_4:
	mov	w20, #0                         ; =0x0
LBB87_5:
	mov	x0, x19
	bl	_pthread_mutex_unlock
LBB87_6:
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
	cbz	x0, LBB88_2
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
LBB88_2:
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
	b.eq	LBB90_2
; %bb.1:
	mov	w0, w0
	b	_pthread_setspecific
LBB90_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_tls_get                    ; -- Begin function _xt_tls_get
	.p2align	2
__xt_tls_get:                           ; @_xt_tls_get
	.cfi_startproc
; %bb.0:
	cmn	w0, #1
	b.eq	LBB91_2
; %bb.1:
	mov	w0, w0
	b	_pthread_getspecific
LBB91_2:
	mov	x0, #0                          ; =0x0
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_load_i32            ; -- Begin function _xt_atomic_load_i32
	.p2align	2
__xt_atomic_load_i32:                   ; @_xt_atomic_load_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB92_2
; %bb.1:
	ldar	w0, [x0]
LBB92_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_store_i32           ; -- Begin function _xt_atomic_store_i32
	.p2align	2
__xt_atomic_store_i32:                  ; @_xt_atomic_store_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB93_2
; %bb.1:
	stlr	w1, [x0]
LBB93_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_add_i32             ; -- Begin function _xt_atomic_add_i32
	.p2align	2
__xt_atomic_add_i32:                    ; @_xt_atomic_add_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB94_2
; %bb.1:
	ldaddal	w1, w8, [x0]
	add	w0, w8, w1
LBB94_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_xchg_i32            ; -- Begin function _xt_atomic_xchg_i32
	.p2align	2
__xt_atomic_xchg_i32:                   ; @_xt_atomic_xchg_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB95_2
; %bb.1:
	swpal	w1, w0, [x0]
LBB95_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_cas_i32             ; -- Begin function _xt_atomic_cas_i32
	.p2align	2
__xt_atomic_cas_i32:                    ; @_xt_atomic_cas_i32
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB96_2
; %bb.1:
	mov	x8, x1
	casal	w8, w2, [x0]
	cmp	w8, w1
	cset	w0, eq
LBB96_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_load_ptr            ; -- Begin function _xt_atomic_load_ptr
	.p2align	2
__xt_atomic_load_ptr:                   ; @_xt_atomic_load_ptr
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB97_2
; %bb.1:
	ldar	x0, [x0]
LBB97_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_store_ptr           ; -- Begin function _xt_atomic_store_ptr
	.p2align	2
__xt_atomic_store_ptr:                  ; @_xt_atomic_store_ptr
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB98_2
; %bb.1:
	stlr	x1, [x0]
LBB98_2:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_atomic_cas_ptr             ; -- Begin function _xt_atomic_cas_ptr
	.p2align	2
__xt_atomic_cas_ptr:                    ; @_xt_atomic_cas_ptr
	.cfi_startproc
; %bb.0:
	cbz	x0, LBB99_2
; %bb.1:
	mov	x8, x1
	casal	x8, x2, [x0]
	cmp	x8, x1
	cset	w0, eq
LBB99_2:
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
	cbz	x0, LBB100_35
; %bb.1:
	mov	x21, x2
	mov	x20, x1
	mov	x19, x0
	adrp	x23, __xt_threads_active@PAGE
	mov	w25, #1                         ; =0x1
	adrp	x24, _xt_sinit_n@PAGE
Lloh75:
	adrp	x26, _xt_sinit_flag@PAGE
Lloh76:
	add	x26, x26, _xt_sinit_flag@PAGEOFF
Lloh77:
	adrp	x27, _xt_sinit_owner@PAGE
Lloh78:
	add	x27, x27, _xt_sinit_owner@PAGEOFF
Lloh79:
	adrp	x22, _xt_rt_mtx@PAGE
Lloh80:
	add	x22, x22, _xt_rt_mtx@PAGEOFF
	b	LBB100_4
LBB100_2:                               ;   in Loop: Header=BB100_4 Depth=1
	mov	w8, #1                          ; =0x1
LBB100_3:                               ;   in Loop: Header=BB100_4 Depth=1
	cbnz	w8, LBB100_23
LBB100_4:                               ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB100_17 Depth 2
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB100_6
; %bb.5:                                ;   in Loop: Header=BB100_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_lock
LBB100_6:                               ;   in Loop: Header=BB100_4 Depth=1
	ldrb	w8, [x19]
	cbz	w8, LBB100_10
; %bb.7:                                ;   in Loop: Header=BB100_4 Depth=1
	cmp	w8, #2
	b.ne	LBB100_14
LBB100_8:                               ;   in Loop: Header=BB100_4 Depth=1
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB100_2
; %bb.9:                                ;   in Loop: Header=BB100_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_unlock
	b	LBB100_2
LBB100_10:                              ;   in Loop: Header=BB100_4 Depth=1
	strb	w25, [x19]
	ldrsw	x8, [x24, _xt_sinit_n@PAGEOFF]
	cmp	w8, #31
	b.gt	LBB100_12
; %bb.11:                               ;   in Loop: Header=BB100_4 Depth=1
	str	x19, [x26, x8, lsl #3]
	bl	_pthread_self
	lsr	x8, x0, #4
	lsr	x9, x0, #32
	eor	w8, w8, w9
	ldrsw	x9, [x24, _xt_sinit_n@PAGEOFF]
	str	w8, [x27, x9, lsl #2]
	add	w8, w9, #1
	str	w8, [x24, _xt_sinit_n@PAGEOFF]
LBB100_12:                              ;   in Loop: Header=BB100_4 Depth=1
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB100_22
; %bb.13:                               ;   in Loop: Header=BB100_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_unlock
	mov	w8, #2                          ; =0x2
	b	LBB100_3
LBB100_14:                              ;   in Loop: Header=BB100_4 Depth=1
	bl	_pthread_self
	ldr	w8, [x24, _xt_sinit_n@PAGEOFF]
	cmp	w8, #1
	b.lt	LBB100_19
; %bb.15:                               ;   in Loop: Header=BB100_4 Depth=1
	lsr	x9, x0, #4
	lsr	x10, x0, #32
	eor	w9, w9, w10
	mov	x10, x26
	mov	x11, x27
	b	LBB100_17
LBB100_16:                              ;   in Loop: Header=BB100_17 Depth=2
	add	x11, x11, #4
	add	x10, x10, #8
	subs	x8, x8, #1
	b.eq	LBB100_19
LBB100_17:                              ;   Parent Loop BB100_4 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldr	x12, [x10]
	cmp	x12, x19
	b.ne	LBB100_16
; %bb.18:                               ;   in Loop: Header=BB100_17 Depth=2
	ldr	w12, [x11]
	cmp	w12, w9
	b.ne	LBB100_16
	b	LBB100_8
LBB100_19:                              ;   in Loop: Header=BB100_4 Depth=1
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB100_21
; %bb.20:                               ;   in Loop: Header=BB100_4 Depth=1
	mov	x0, x22
	bl	_pthread_mutex_unlock
LBB100_21:                              ;   in Loop: Header=BB100_4 Depth=1
	bl	_sched_yield
	mov	w8, #0                          ; =0x0
	b	LBB100_3
LBB100_22:                              ;   in Loop: Header=BB100_4 Depth=1
	mov	w8, #2                          ; =0x2
	b	LBB100_3
LBB100_23:
	cmp	w8, #1
	b.eq	LBB100_35
; %bb.24:
	cbz	x20, LBB100_26
; %bb.25:
	mov	x0, x21
	blr	x20
LBB100_26:
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB100_28
; %bb.27:
Lloh81:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh82:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	bl	_pthread_mutex_lock
LBB100_28:
	mov	w8, #2                          ; =0x2
	strb	w8, [x19]
	ldr	w8, [x24, _xt_sinit_n@PAGEOFF]
	cmp	w8, #1
	b.lt	LBB100_32
; %bb.29:
Lloh83:
	adrp	x9, _xt_sinit_owner@PAGE
Lloh84:
	add	x9, x9, _xt_sinit_owner@PAGEOFF
Lloh85:
	adrp	x10, _xt_sinit_flag@PAGE
Lloh86:
	add	x10, x10, _xt_sinit_flag@PAGEOFF
	mov	x13, x8
	mov	x12, x10
	mov	x11, x9
LBB100_30:                              ; =>This Inner Loop Header: Depth=1
	ldr	x14, [x12]
	cmp	x14, x19
	b.eq	LBB100_34
; %bb.31:                               ;   in Loop: Header=BB100_30 Depth=1
	add	x11, x11, #4
	add	x12, x12, #8
	subs	x13, x13, #1
	b.ne	LBB100_30
LBB100_32:
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbz	w8, LBB100_35
LBB100_33:
Lloh87:
	adrp	x0, _xt_rt_mtx@PAGE
Lloh88:
	add	x0, x0, _xt_rt_mtx@PAGEOFF
	ldp	x29, x30, [sp, #80]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #64]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp], #96             ; 16-byte Folded Reload
	b	_pthread_mutex_unlock
LBB100_34:
	sxtw	x8, w8
	sub	x8, x8, #1
	str	w8, [x24, _xt_sinit_n@PAGEOFF]
	ldr	x10, [x10, x8, lsl #3]
	str	x10, [x12]
	ldr	w8, [x9, x8, lsl #2]
	str	w8, [x11]
	ldr	w8, [x23, __xt_threads_active@PAGEOFF]
	cbnz	w8, LBB100_33
LBB100_35:
	ldp	x29, x30, [sp, #80]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #64]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp], #96             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh79, Lloh80
	.loh AdrpAdd	Lloh77, Lloh78
	.loh AdrpAdd	Lloh75, Lloh76
	.loh AdrpAdd	Lloh81, Lloh82
	.loh AdrpAdd	Lloh85, Lloh86
	.loh AdrpAdd	Lloh83, Lloh84
	.loh AdrpAdd	Lloh87, Lloh88
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
Lloh89:
	adrp	x8, ___stderrp@GOTPAGE
Lloh90:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh91:
	ldr	x8, [x8]
	mov	w9, #1                          ; =0x1
	stp	x0, x9, [sp]
Lloh92:
	adrp	x1, l_.str@PAGE
Lloh93:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh92, Lloh93
	.loh AdrpLdrGotLdr	Lloh89, Lloh90, Lloh91
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
Lloh94:
	adrp	x8, ___stderrp@GOTPAGE
Lloh95:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh96:
	ldr	x8, [x8]
	mov	w9, #1                          ; =0x1
	stp	x0, x9, [sp]
Lloh97:
	adrp	x1, l_.str@PAGE
Lloh98:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh97, Lloh98
	.loh AdrpLdrGotLdr	Lloh94, Lloh95, Lloh96
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
Lloh99:
	adrp	x8, ___stderrp@GOTPAGE
Lloh100:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh101:
	ldr	x8, [x8]
	mov	w9, #2                          ; =0x2
	stp	x0, x9, [sp]
Lloh102:
	adrp	x1, l_.str@PAGE
Lloh103:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh102, Lloh103
	.loh AdrpLdrGotLdr	Lloh99, Lloh100, Lloh101
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
Lloh104:
	adrp	x8, ___stderrp@GOTPAGE
Lloh105:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh106:
	ldr	x8, [x8]
	mov	w9, #2                          ; =0x2
	stp	x0, x9, [sp]
Lloh107:
	adrp	x1, l_.str@PAGE
Lloh108:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh107, Lloh108
	.loh AdrpLdrGotLdr	Lloh104, Lloh105, Lloh106
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
Lloh109:
	adrp	x8, ___stderrp@GOTPAGE
Lloh110:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh111:
	ldr	x8, [x8]
	mov	w9, #4                          ; =0x4
	stp	x0, x9, [sp]
Lloh112:
	adrp	x1, l_.str@PAGE
Lloh113:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh112, Lloh113
	.loh AdrpLdrGotLdr	Lloh109, Lloh110, Lloh111
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
Lloh114:
	adrp	x8, ___stderrp@GOTPAGE
Lloh115:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh116:
	ldr	x8, [x8]
	mov	w9, #4                          ; =0x4
	stp	x0, x9, [sp]
Lloh117:
	adrp	x1, l_.str@PAGE
Lloh118:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh117, Lloh118
	.loh AdrpLdrGotLdr	Lloh114, Lloh115, Lloh116
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
Lloh119:
	adrp	x8, ___stderrp@GOTPAGE
Lloh120:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh121:
	ldr	x8, [x8]
	mov	w9, #8                          ; =0x8
	stp	x0, x9, [sp]
Lloh122:
	adrp	x1, l_.str@PAGE
Lloh123:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh122, Lloh123
	.loh AdrpLdrGotLdr	Lloh119, Lloh120, Lloh121
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
Lloh124:
	adrp	x8, ___stderrp@GOTPAGE
Lloh125:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh126:
	ldr	x8, [x8]
	mov	w9, #8                          ; =0x8
	stp	x0, x9, [sp]
Lloh127:
	adrp	x1, l_.str@PAGE
Lloh128:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh127, Lloh128
	.loh AdrpLdrGotLdr	Lloh124, Lloh125, Lloh126
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
Lloh129:
	adrp	x8, ___stderrp@GOTPAGE
Lloh130:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh131:
	ldr	x8, [x8]
	mov	w9, #8                          ; =0x8
	stp	x0, x9, [sp]
Lloh132:
	adrp	x1, l_.str@PAGE
Lloh133:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh132, Lloh133
	.loh AdrpLdrGotLdr	Lloh129, Lloh130, Lloh131
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
Lloh134:
	adrp	x8, ___stderrp@GOTPAGE
Lloh135:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh136:
	ldr	x8, [x8]
	mov	w9, #1                          ; =0x1
	stp	x0, x9, [sp]
Lloh137:
	adrp	x1, l_.str@PAGE
Lloh138:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh137, Lloh138
	.loh AdrpLdrGotLdr	Lloh134, Lloh135, Lloh136
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
Lloh139:
	adrp	x8, ___stderrp@GOTPAGE
Lloh140:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh141:
	ldr	x8, [x8]
	mov	w9, #4                          ; =0x4
	stp	x0, x9, [sp]
Lloh142:
	adrp	x1, l_.str@PAGE
Lloh143:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh142, Lloh143
	.loh AdrpLdrGotLdr	Lloh139, Lloh140, Lloh141
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
Lloh144:
	adrp	x8, ___stderrp@GOTPAGE
Lloh145:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh146:
	ldr	x8, [x8]
	mov	w9, #8                          ; =0x8
	stp	x0, x9, [sp]
Lloh147:
	adrp	x1, l_.str@PAGE
Lloh148:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh147, Lloh148
	.loh AdrpLdrGotLdr	Lloh144, Lloh145, Lloh146
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
Lloh149:
	adrp	x8, ___stderrp@GOTPAGE
Lloh150:
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
Lloh151:
	ldr	x8, [x8]
	mov	w9, #8                          ; =0x8
	stp	x0, x9, [sp]
Lloh152:
	adrp	x1, l_.str@PAGE
Lloh153:
	add	x1, x1, l_.str@PAGEOFF
	bl	_OUTLINED_FUNCTION_0
	bl	_abort
	.loh AdrpAdd	Lloh152, Lloh153
	.loh AdrpLdrGotLdr	Lloh149, Lloh150, Lloh151
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
l_.str.5:                               ; @.str.5
	.asciz	"%.*f"

.subsections_via_symbols
