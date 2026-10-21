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

// rt-android.s — the self-hosted arm64/Android runtime (ARC/heap/weak +
// print + math + threads + files). GENERATED from src/xtc/support-src/rt.c
// by tools/regen-runtimes.py (android) — do not hand-edit; regenerate.
//
// The Android twin of rt-macos.s, and generated the same way: clang runs
// ONCE, here, and never during a user compile — XAArm64Assembler assembles
// this text like any other, which is what keeps `-A android` free of the NDK.
// It must come from the NDK clang rather than the host one because
// Darwin/arm64 passes varargs on the STACK and AAPCS64 passes them in
// registers, so a macOS-generated runtime would hand Android's printf its
// arguments in the wrong places.
//
// Object header = 38 bytes, magic 0x58544F42 at base, refcount u16 at obj-2,
// weak head at obj-10 — the same contract every other target uses. Imports
// (bionic): libc.so for calloc/free/stdio/pthread, libm.so for the _xm_*
// wrappers' tail calls.
// regenerated with: Android (12027248, +pgo, -bolt, +lto, -mlgo, based on r522817) clang version 18.0.1 (https://android.googlesource.com/toolchain/llvm-project d8003a456d14a3deb8054cdaa529ffbf02d9b262)
	.text
	.file	"rt.c"
	.globl	_xtc_alloc                      // -- Begin function _xtc_alloc
	.p2align	2
	.type	_xtc_alloc,@function
_xtc_alloc:                             // @_xtc_alloc
// %bb.0:
	str	x30, [sp, #-48]!                // 8-byte Folded Spill
	mul	x8, x1, x0
	mov	w9, #16                         // =0x10
	stp	x20, x19, [sp, #32]             // 16-byte Folded Spill
	mov	x20, x1
	mov	x19, x0
	mov	w0, #1                          // =0x1
	stp	x22, x21, [sp, #16]             // 16-byte Folded Spill
	mov	x21, x2
	mov	w22, #1                         // =0x1
	cmp	x8, #16
	csel	x8, x8, x9, hi
	add	x1, x8, #40
	bl	calloc
	cbz	x0, .Lrt_BB0_2
// %bb.1:
	mov	x8, x0
	mov	w9, #20290                      // =0x4f42
	stur	x20, [x0, #4]
	stur	x19, [x0, #12]
	ldp	x20, x19, [sp, #32]             // 16-byte Folded Reload
	stur	x21, [x0, #20]
	movk	w9, #22612, lsl #16
	str	w22, [x8, #36]
	ldp	x22, x21, [sp, #16]             // 16-byte Folded Reload
	str	w9, [x0]
	stur	xzr, [x0, #28]
	add	x0, x0, #40
	ldr	x30, [sp], #48                  // 8-byte Folded Reload
	ret
.Lrt_BB0_2:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str
	add	x1, x1, :lo12:.Lrt_.str
	ldr	x8, [x8, :got_lo12:stderr]
	mov	x2, x19
	mov	x3, x20
	ldr	x0, [x8]
	bl	fprintf
	bl	abort
.Lrt_func_end0:
	.size	_xtc_alloc, .Lrt_func_end0-_xtc_alloc
                                        // -- End function
	.globl	_xtc_new_u8                     // -- Begin function _xtc_new_u8
	.p2align	2
	.type	_xtc_new_u8,@function
_xtc_new_u8:                            // @_xtc_new_u8
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	cmp	x0, #16, lsl #12                // =65536
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	b.lo	.Lrt_BB1_2
// %bb.1:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	mov	w1, #1                          // =0x1
	mov	x2, xzr
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	b	_xtc_alloc_aligned
.Lrt_BB1_2:
	cmp	x0, #16
	mov	w8, #16                         // =0x10
	mov	x19, x0
	csel	x8, x0, x8, hi
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	add	x1, x8, #40
	bl	calloc
	cbz	x0, .Lrt_BB1_4
// %bb.3:
	mov	x8, x0
	mov	w9, #20290                      // =0x4f42
	stur	x20, [x0, #4]
	stur	x19, [x0, #12]
	movk	w9, #22612, lsl #16
	str	w20, [x8, #36]
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	str	w9, [x0]
	stur	xzr, [x0, #28]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_BB1_4:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str
	add	x1, x1, :lo12:.Lrt_.str
	ldr	x8, [x8, :got_lo12:stderr]
	mov	x2, x19
	mov	w3, #1                          // =0x1
	ldr	x0, [x8]
	bl	fprintf
	bl	abort
.Lrt_func_end1:
	.size	_xtc_new_u8, .Lrt_func_end1-_xtc_new_u8
                                        // -- End function
	.globl	_xtc_alloc_aligned              // -- Begin function _xtc_alloc_aligned
	.p2align	2
	.type	_xtc_alloc_aligned,@function
_xtc_alloc_aligned:                     // @_xtc_alloc_aligned
// %bb.0:
	stp	x29, x30, [sp, #-96]!           // 16-byte Folded Spill
	stp	x24, x23, [sp, #48]             // 16-byte Folded Spill
	mul	x23, x1, x0
	mov	w8, #16                         // =0x10
	mov	w9, #16383                      // =0x3fff
	stp	x22, x21, [sp, #64]             // 16-byte Folded Spill
	mov	x21, x1
	mov	x22, x0
	mov	w0, #1                          // =0x1
	stp	x28, x27, [sp, #16]             // 16-byte Folded Spill
	stp	x26, x25, [sp, #32]             // 16-byte Folded Spill
	mov	w24, #1                         // =0x1
	stp	x20, x19, [sp, #80]             // 16-byte Folded Spill
	mov	x20, x2
	cmp	x23, #16
	csel	x8, x23, x8, hi
	add	x8, x8, x9
	mov	w9, #16432                      // =0x4030
	and	x8, x8, #0xffffffffffffc000
	add	x1, x8, x9
	bl	calloc
	cbz	x0, .Lrt_BB2_25
// %bb.1:
	mov	w8, #16431                      // =0x402f
	mov	w9, #20291                      // =0x4f43
	add	x8, x0, x8
	movk	w9, #22612, lsl #16
	and	x19, x8, #0xffffffffffffc000
	stur	w9, [x19, #-40]
	stur	x21, [x19, #-36]
	adrp	x21, _xt_threads_active
	stur	w24, [x19, #-4]
	ldr	w8, [x21, :lo12:_xt_threads_active]
	stur	x22, [x19, #-28]
	stur	x20, [x19, #-20]
	stur	xzr, [x19, #-12]
	stur	x0, [x19, #-48]
	cbz	w8, .Lrt_BB2_3
// %bb.2:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB2_3:
	adrp	x25, xt_simd_n
	adrp	x28, xt_simd_cap
	adrp	x27, xt_simd_tab
	ldr	x24, [x25, :lo12:xt_simd_n]
	ldr	x8, [x28, :lo12:xt_simd_cap]
	adrp	x26, xt_simd_flag
	cmp	x24, x8
	b.ne	.Lrt_BB2_15
// %bb.4:
	lsl	x9, x8, #1
	cmp	x8, #0
	mov	w8, #64                         // =0x40
	mov	w1, #8                          // =0x8
	csel	x20, x8, x9, eq
	lsl	x0, x20, #1
	bl	calloc
	mov	x21, x0
	mov	x0, x20
	mov	w1, #1                          // =0x1
	bl	calloc
	cmp	x21, #0
	mov	x22, x0
	ccmp	x0, #0, #4, ne
	cset	w29, ne
	b.eq	.Lrt_BB2_12
// %bb.5:
	lsl	x8, x24, #1
	cbz	x8, .Lrt_BB2_8
// %bb.6:
	ldr	x9, [x27, :lo12:xt_simd_tab]
	mov	x10, x21
.Lrt_BB2_7:                                // =>This Inner Loop Header: Depth=1
	ldr	x11, [x9], #8
	subs	x8, x8, #1
	str	x11, [x10], #8
	b.ne	.Lrt_BB2_7
.Lrt_BB2_8:
	cbz	x24, .Lrt_BB2_11
// %bb.9:
	ldr	x8, [x26, :lo12:xt_simd_flag]
	mov	x9, x22
.Lrt_BB2_10:                               // =>This Inner Loop Header: Depth=1
	ldrb	w10, [x8], #1
	subs	x24, x24, #1
	strb	w10, [x9], #1
	b.ne	.Lrt_BB2_10
.Lrt_BB2_11:
	ldr	x0, [x27, :lo12:xt_simd_tab]
	bl	free
	ldr	x0, [x26, :lo12:xt_simd_flag]
	bl	free
	str	x21, [x27, :lo12:xt_simd_tab]
	adrp	x21, _xt_threads_active
	str	x22, [x26, :lo12:xt_simd_flag]
	str	x20, [x28, :lo12:xt_simd_cap]
	b	.Lrt_BB2_14
.Lrt_BB2_12:
	mov	x0, x21
	bl	free
	mov	x0, x22
	bl	free
	adrp	x21, _xt_threads_active
	ldr	w8, [x21, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB2_14
// %bb.13:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB2_14:
	cbz	w29, .Lrt_BB2_24
.Lrt_BB2_15:
	ldr	x8, [x25, :lo12:xt_simd_n]
	cbz	x8, .Lrt_BB2_19
// %bb.16:
	ldr	x10, [x27, :lo12:xt_simd_tab]
	mov	x9, xzr
	mov	x11, x8
.Lrt_BB2_17:                               // =>This Inner Loop Header: Depth=1
	add	x12, x11, x9
	and	x13, x12, #0x1ffffffffffffffe
	lsr	x12, x12, #1
	ldr	x13, [x10, x13, lsl #3]
	cmp	x13, x19
	csel	x11, x12, x11, hi
	csinc	x9, x9, x12, hi
	cmp	x9, x11
	b.lo	.Lrt_BB2_17
// %bb.18:
	cmp	x8, x9
	b.hi	.Lrt_BB2_20
	b	.Lrt_BB2_22
.Lrt_BB2_19:
	mov	x9, xzr
	cmp	x8, x9
	b.ls	.Lrt_BB2_22
.Lrt_BB2_20:
	ldr	x10, [x27, :lo12:xt_simd_tab]
	mov	x11, x8
	add	x13, x10, x8, lsl #4
	ldr	x10, [x26, :lo12:xt_simd_flag]
	mov	x12, x13
.Lrt_BB2_21:                               // =>This Inner Loop Header: Depth=1
	ldr	x14, [x12, #-16]!
	ldur	x15, [x13, #-8]
	stp	x14, x15, [x13]
	add	x13, x10, x11
	sub	x11, x11, #1
	ldurb	w14, [x13, #-1]
	cmp	x11, x9
	strb	w14, [x13]
	mov	x13, x12
	b.hi	.Lrt_BB2_21
.Lrt_BB2_22:
	ldr	x10, [x27, :lo12:xt_simd_tab]
	add	x11, x19, x23
	add	x8, x8, #1
	add	x10, x10, x9, lsl #4
	stp	x19, x11, [x10]
	ldr	x10, [x26, :lo12:xt_simd_flag]
	strb	wzr, [x10, x9]
	ldr	w9, [x21, :lo12:_xt_threads_active]
	str	x8, [x25, :lo12:xt_simd_n]
	cbz	w9, .Lrt_BB2_24
// %bb.23:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB2_24:
	mov	x0, x19
	ldp	x20, x19, [sp, #80]             // 16-byte Folded Reload
	ldp	x22, x21, [sp, #64]             // 16-byte Folded Reload
	ldp	x24, x23, [sp, #48]             // 16-byte Folded Reload
	ldp	x26, x25, [sp, #32]             // 16-byte Folded Reload
	ldp	x28, x27, [sp, #16]             // 16-byte Folded Reload
	ldp	x29, x30, [sp], #96             // 16-byte Folded Reload
	ret
.Lrt_BB2_25:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str
	add	x1, x1, :lo12:.Lrt_.str
	ldr	x8, [x8, :got_lo12:stderr]
	mov	x2, x22
	mov	x3, x21
	ldr	x0, [x8]
	bl	fprintf
	bl	abort
.Lrt_func_end2:
	.size	_xtc_alloc_aligned, .Lrt_func_end2-_xtc_alloc_aligned
                                        // -- End function
	.globl	_xtc_new_i8                     // -- Begin function _xtc_new_i8
	.p2align	2
	.type	_xtc_new_i8,@function
_xtc_new_i8:                            // @_xtc_new_i8
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	cmp	x0, #16, lsl #12                // =65536
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	b.lo	.Lrt_BB3_2
// %bb.1:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	mov	w1, #1                          // =0x1
	mov	x2, xzr
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	b	_xtc_alloc_aligned
.Lrt_BB3_2:
	cmp	x0, #16
	mov	w8, #16                         // =0x10
	mov	x19, x0
	csel	x8, x0, x8, hi
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	add	x1, x8, #40
	bl	calloc
	cbz	x0, .Lrt_BB3_4
// %bb.3:
	mov	x8, x0
	mov	w9, #20290                      // =0x4f42
	stur	x20, [x0, #4]
	stur	x19, [x0, #12]
	movk	w9, #22612, lsl #16
	str	w20, [x8, #36]
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	str	w9, [x0]
	stur	xzr, [x0, #28]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_BB3_4:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str
	add	x1, x1, :lo12:.Lrt_.str
	ldr	x8, [x8, :got_lo12:stderr]
	mov	x2, x19
	mov	w3, #1                          // =0x1
	ldr	x0, [x8]
	bl	fprintf
	bl	abort
.Lrt_func_end3:
	.size	_xtc_new_i8, .Lrt_func_end3-_xtc_new_i8
                                        // -- End function
	.globl	_xtc_new_u16                    // -- Begin function _xtc_new_u16
	.p2align	2
	.type	_xtc_new_u16,@function
_xtc_new_u16:                           // @_xtc_new_u16
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	tst	x0, #0x7fffffffffff8000
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	b.eq	.Lrt_BB4_2
// %bb.1:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	mov	w1, #2                          // =0x2
	mov	x2, xzr
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	b	_xtc_alloc_aligned
.Lrt_BB4_2:
	lsl	x8, x0, #1
	mov	w9, #16                         // =0x10
	mov	x19, x0
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	cmp	x8, #16
	csel	x8, x8, x9, hi
	add	x1, x8, #40
	bl	calloc
	cbz	x0, .Lrt_BB4_4
// %bb.3:
	mov	x8, x0
	mov	w9, #20290                      // =0x4f42
	stur	x19, [x0, #12]
	str	w20, [x8, #36]
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	movk	w9, #22612, lsl #16
	mov	w10, #2                         // =0x2
	stur	xzr, [x0, #28]
	str	w9, [x0]
	stur	x10, [x0, #4]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_BB4_4:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str
	add	x1, x1, :lo12:.Lrt_.str
	ldr	x8, [x8, :got_lo12:stderr]
	mov	x2, x19
	mov	w3, #2                          // =0x2
	ldr	x0, [x8]
	bl	fprintf
	bl	abort
.Lrt_func_end4:
	.size	_xtc_new_u16, .Lrt_func_end4-_xtc_new_u16
                                        // -- End function
	.globl	_xtc_new_i16                    // -- Begin function _xtc_new_i16
	.p2align	2
	.type	_xtc_new_i16,@function
_xtc_new_i16:                           // @_xtc_new_i16
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	tst	x0, #0x7fffffffffff8000
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	b.eq	.Lrt_BB5_2
// %bb.1:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	mov	w1, #2                          // =0x2
	mov	x2, xzr
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	b	_xtc_alloc_aligned
.Lrt_BB5_2:
	lsl	x8, x0, #1
	mov	w9, #16                         // =0x10
	mov	x19, x0
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	cmp	x8, #16
	csel	x8, x8, x9, hi
	add	x1, x8, #40
	bl	calloc
	cbz	x0, .Lrt_BB5_4
// %bb.3:
	mov	x8, x0
	mov	w9, #20290                      // =0x4f42
	stur	x19, [x0, #12]
	str	w20, [x8, #36]
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	movk	w9, #22612, lsl #16
	mov	w10, #2                         // =0x2
	stur	xzr, [x0, #28]
	str	w9, [x0]
	stur	x10, [x0, #4]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_BB5_4:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str
	add	x1, x1, :lo12:.Lrt_.str
	ldr	x8, [x8, :got_lo12:stderr]
	mov	x2, x19
	mov	w3, #2                          // =0x2
	ldr	x0, [x8]
	bl	fprintf
	bl	abort
.Lrt_func_end5:
	.size	_xtc_new_i16, .Lrt_func_end5-_xtc_new_i16
                                        // -- End function
	.globl	_xtc_new_u32                    // -- Begin function _xtc_new_u32
	.p2align	2
	.type	_xtc_new_u32,@function
_xtc_new_u32:                           // @_xtc_new_u32
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	tst	x0, #0x3fffffffffffc000
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	b.eq	.Lrt_BB6_2
// %bb.1:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	mov	w1, #4                          // =0x4
	mov	x2, xzr
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	b	_xtc_alloc_aligned
.Lrt_BB6_2:
	lsl	x8, x0, #2
	mov	w9, #16                         // =0x10
	mov	x19, x0
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	cmp	x8, #16
	csel	x8, x8, x9, hi
	add	x1, x8, #40
	bl	calloc
	cbz	x0, .Lrt_BB6_4
// %bb.3:
	mov	x8, x0
	mov	w9, #20290                      // =0x4f42
	stur	x19, [x0, #12]
	str	w20, [x8, #36]
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	movk	w9, #22612, lsl #16
	mov	w10, #4                         // =0x4
	stur	xzr, [x0, #28]
	str	w9, [x0]
	stur	x10, [x0, #4]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_BB6_4:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str
	add	x1, x1, :lo12:.Lrt_.str
	ldr	x8, [x8, :got_lo12:stderr]
	mov	x2, x19
	mov	w3, #4                          // =0x4
	ldr	x0, [x8]
	bl	fprintf
	bl	abort
.Lrt_func_end6:
	.size	_xtc_new_u32, .Lrt_func_end6-_xtc_new_u32
                                        // -- End function
	.globl	_xtc_new_i32                    // -- Begin function _xtc_new_i32
	.p2align	2
	.type	_xtc_new_i32,@function
_xtc_new_i32:                           // @_xtc_new_i32
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	tst	x0, #0x3fffffffffffc000
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	b.eq	.Lrt_BB7_2
// %bb.1:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	mov	w1, #4                          // =0x4
	mov	x2, xzr
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	b	_xtc_alloc_aligned
.Lrt_BB7_2:
	lsl	x8, x0, #2
	mov	w9, #16                         // =0x10
	mov	x19, x0
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	cmp	x8, #16
	csel	x8, x8, x9, hi
	add	x1, x8, #40
	bl	calloc
	cbz	x0, .Lrt_BB7_4
// %bb.3:
	mov	x8, x0
	mov	w9, #20290                      // =0x4f42
	stur	x19, [x0, #12]
	str	w20, [x8, #36]
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	movk	w9, #22612, lsl #16
	mov	w10, #4                         // =0x4
	stur	xzr, [x0, #28]
	str	w9, [x0]
	stur	x10, [x0, #4]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_BB7_4:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str
	add	x1, x1, :lo12:.Lrt_.str
	ldr	x8, [x8, :got_lo12:stderr]
	mov	x2, x19
	mov	w3, #4                          // =0x4
	ldr	x0, [x8]
	bl	fprintf
	bl	abort
.Lrt_func_end7:
	.size	_xtc_new_i32, .Lrt_func_end7-_xtc_new_i32
                                        // -- End function
	.globl	_xtc_new_u64                    // -- Begin function _xtc_new_u64
	.p2align	2
	.type	_xtc_new_u64,@function
_xtc_new_u64:                           // @_xtc_new_u64
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	tst	x0, #0x1fffffffffffe000
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	b.eq	.Lrt_BB8_2
// %bb.1:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	mov	w1, #8                          // =0x8
	mov	x2, xzr
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	b	_xtc_alloc_aligned
.Lrt_BB8_2:
	lsl	x8, x0, #3
	mov	w9, #16                         // =0x10
	mov	x19, x0
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	cmp	x8, #16
	csel	x8, x8, x9, hi
	add	x1, x8, #40
	bl	calloc
	cbz	x0, .Lrt_BB8_4
// %bb.3:
	mov	x8, x0
	mov	w9, #20290                      // =0x4f42
	stur	x19, [x0, #12]
	str	w20, [x8, #36]
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	movk	w9, #22612, lsl #16
	mov	w10, #8                         // =0x8
	stur	xzr, [x0, #28]
	str	w9, [x0]
	stur	x10, [x0, #4]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_BB8_4:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str
	add	x1, x1, :lo12:.Lrt_.str
	ldr	x8, [x8, :got_lo12:stderr]
	mov	x2, x19
	mov	w3, #8                          // =0x8
	ldr	x0, [x8]
	bl	fprintf
	bl	abort
.Lrt_func_end8:
	.size	_xtc_new_u64, .Lrt_func_end8-_xtc_new_u64
                                        // -- End function
	.globl	_xtc_new_i64                    // -- Begin function _xtc_new_i64
	.p2align	2
	.type	_xtc_new_i64,@function
_xtc_new_i64:                           // @_xtc_new_i64
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	tst	x0, #0x1fffffffffffe000
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	b.eq	.Lrt_BB9_2
// %bb.1:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	mov	w1, #8                          // =0x8
	mov	x2, xzr
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	b	_xtc_alloc_aligned
.Lrt_BB9_2:
	lsl	x8, x0, #3
	mov	w9, #16                         // =0x10
	mov	x19, x0
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	cmp	x8, #16
	csel	x8, x8, x9, hi
	add	x1, x8, #40
	bl	calloc
	cbz	x0, .Lrt_BB9_4
// %bb.3:
	mov	x8, x0
	mov	w9, #20290                      // =0x4f42
	stur	x19, [x0, #12]
	str	w20, [x8, #36]
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	movk	w9, #22612, lsl #16
	mov	w10, #8                         // =0x8
	stur	xzr, [x0, #28]
	str	w9, [x0]
	stur	x10, [x0, #4]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_BB9_4:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str
	add	x1, x1, :lo12:.Lrt_.str
	ldr	x8, [x8, :got_lo12:stderr]
	mov	x2, x19
	mov	w3, #8                          // =0x8
	ldr	x0, [x8]
	bl	fprintf
	bl	abort
.Lrt_func_end9:
	.size	_xtc_new_i64, .Lrt_func_end9-_xtc_new_i64
                                        // -- End function
	.globl	_xtc_new_pointer                // -- Begin function _xtc_new_pointer
	.p2align	2
	.type	_xtc_new_pointer,@function
_xtc_new_pointer:                       // @_xtc_new_pointer
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	lsl	x9, x0, #3
	mov	w8, #16                         // =0x10
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	mov	x19, x0
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	cmp	x9, #16
	csel	x8, x9, x8, hi
	add	x1, x8, #40
	bl	calloc
	cbz	x0, .Lrt_BB10_2
// %bb.1:
	mov	x8, x0
	mov	w9, #20290                      // =0x4f42
	stur	x19, [x0, #12]
	str	w20, [x8, #36]
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	movk	w9, #22612, lsl #16
	mov	w10, #8                         // =0x8
	stur	xzr, [x0, #28]
	str	w9, [x0]
	stur	x10, [x0, #4]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_BB10_2:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str
	add	x1, x1, :lo12:.Lrt_.str
	ldr	x8, [x8, :got_lo12:stderr]
	mov	x2, x19
	mov	w3, #8                          // =0x8
	ldr	x0, [x8]
	bl	fprintf
	bl	abort
.Lrt_func_end10:
	.size	_xtc_new_pointer, .Lrt_func_end10-_xtc_new_pointer
                                        // -- End function
	.globl	_xtc_new_bool                   // -- Begin function _xtc_new_bool
	.p2align	2
	.type	_xtc_new_bool,@function
_xtc_new_bool:                          // @_xtc_new_bool
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	cmp	x0, #16, lsl #12                // =65536
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	b.lo	.Lrt_BB11_2
// %bb.1:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	mov	w1, #1                          // =0x1
	mov	x2, xzr
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	b	_xtc_alloc_aligned
.Lrt_BB11_2:
	cmp	x0, #16
	mov	w8, #16                         // =0x10
	mov	x19, x0
	csel	x8, x0, x8, hi
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	add	x1, x8, #40
	bl	calloc
	cbz	x0, .Lrt_BB11_4
// %bb.3:
	mov	x8, x0
	mov	w9, #20290                      // =0x4f42
	stur	x20, [x0, #4]
	stur	x19, [x0, #12]
	movk	w9, #22612, lsl #16
	str	w20, [x8, #36]
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	str	w9, [x0]
	stur	xzr, [x0, #28]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_BB11_4:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str
	add	x1, x1, :lo12:.Lrt_.str
	ldr	x8, [x8, :got_lo12:stderr]
	mov	x2, x19
	mov	w3, #1                          // =0x1
	ldr	x0, [x8]
	bl	fprintf
	bl	abort
.Lrt_func_end11:
	.size	_xtc_new_bool, .Lrt_func_end11-_xtc_new_bool
                                        // -- End function
	.globl	_xtc_new_float                  // -- Begin function _xtc_new_float
	.p2align	2
	.type	_xtc_new_float,@function
_xtc_new_float:                         // @_xtc_new_float
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	tst	x0, #0x3fffffffffffc000
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	b.eq	.Lrt_BB12_2
// %bb.1:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	mov	w1, #4                          // =0x4
	mov	x2, xzr
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	b	_xtc_alloc_aligned
.Lrt_BB12_2:
	lsl	x8, x0, #2
	mov	w9, #16                         // =0x10
	mov	x19, x0
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	cmp	x8, #16
	csel	x8, x8, x9, hi
	add	x1, x8, #40
	bl	calloc
	cbz	x0, .Lrt_BB12_4
// %bb.3:
	mov	x8, x0
	mov	w9, #20290                      // =0x4f42
	stur	x19, [x0, #12]
	str	w20, [x8, #36]
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	movk	w9, #22612, lsl #16
	mov	w10, #4                         // =0x4
	stur	xzr, [x0, #28]
	str	w9, [x0]
	stur	x10, [x0, #4]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_BB12_4:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str
	add	x1, x1, :lo12:.Lrt_.str
	ldr	x8, [x8, :got_lo12:stderr]
	mov	x2, x19
	mov	w3, #4                          // =0x4
	ldr	x0, [x8]
	bl	fprintf
	bl	abort
.Lrt_func_end12:
	.size	_xtc_new_float, .Lrt_func_end12-_xtc_new_float
                                        // -- End function
	.globl	_xtc_new_double                 // -- Begin function _xtc_new_double
	.p2align	2
	.type	_xtc_new_double,@function
_xtc_new_double:                        // @_xtc_new_double
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	tst	x0, #0x1fffffffffffe000
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	b.eq	.Lrt_BB13_2
// %bb.1:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	mov	w1, #8                          // =0x8
	mov	x2, xzr
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	b	_xtc_alloc_aligned
.Lrt_BB13_2:
	lsl	x8, x0, #3
	mov	w9, #16                         // =0x10
	mov	x19, x0
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	cmp	x8, #16
	csel	x8, x8, x9, hi
	add	x1, x8, #40
	bl	calloc
	cbz	x0, .Lrt_BB13_4
// %bb.3:
	mov	x8, x0
	mov	w9, #20290                      // =0x4f42
	stur	x19, [x0, #12]
	str	w20, [x8, #36]
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	movk	w9, #22612, lsl #16
	mov	w10, #8                         // =0x8
	stur	xzr, [x0, #28]
	str	w9, [x0]
	stur	x10, [x0, #4]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_BB13_4:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str
	add	x1, x1, :lo12:.Lrt_.str
	ldr	x8, [x8, :got_lo12:stderr]
	mov	x2, x19
	mov	w3, #8                          // =0x8
	ldr	x0, [x8]
	bl	fprintf
	bl	abort
.Lrt_func_end13:
	.size	_xtc_new_double, .Lrt_func_end13-_xtc_new_double
                                        // -- End function
	.globl	_xtc_new_string                 // -- Begin function _xtc_new_string
	.p2align	2
	.type	_xtc_new_string,@function
_xtc_new_string:                        // @_xtc_new_string
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	lsl	x9, x0, #3
	mov	w8, #16                         // =0x10
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	mov	x19, x0
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	cmp	x9, #16
	csel	x8, x9, x8, hi
	add	x1, x8, #40
	bl	calloc
	cbz	x0, .Lrt_BB14_2
// %bb.1:
	mov	x8, x0
	mov	w9, #20290                      // =0x4f42
	stur	x19, [x0, #12]
	str	w20, [x8, #36]
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	movk	w9, #22612, lsl #16
	mov	w10, #8                         // =0x8
	stur	xzr, [x0, #28]
	str	w9, [x0]
	stur	x10, [x0, #4]
	stur	xzr, [x0, #20]
	add	x0, x0, #40
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_BB14_2:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str
	add	x1, x1, :lo12:.Lrt_.str
	ldr	x8, [x8, :got_lo12:stderr]
	mov	x2, x19
	mov	w3, #8                          // =0x8
	ldr	x0, [x8]
	bl	fprintf
	bl	abort
.Lrt_func_end14:
	.size	_xtc_new_string, .Lrt_func_end14-_xtc_new_string
                                        // -- End function
	.globl	_xtc_simd_register              // -- Begin function _xtc_simd_register
	.p2align	2
	.type	_xtc_simd_register,@function
_xtc_simd_register:                     // @_xtc_simd_register
// %bb.0:
	stp	x29, x30, [sp, #-96]!           // 16-byte Folded Spill
	stp	x28, x27, [sp, #16]             // 16-byte Folded Spill
	stp	x26, x25, [sp, #32]             // 16-byte Folded Spill
	stp	x24, x23, [sp, #48]             // 16-byte Folded Spill
	stp	x22, x21, [sp, #64]             // 16-byte Folded Spill
	stp	x20, x19, [sp, #80]             // 16-byte Folded Spill
	cbz	x0, .Lrt_BB15_26
// %bb.1:
	mov	x20, x1
	cbz	x1, .Lrt_BB15_26
// %bb.2:
	mov	x19, x0
	orr	w8, w19, w20
	and	x8, x8, #0xfff
	cbnz	x8, .Lrt_BB15_26
// %bb.3:
	adrp	x21, _xt_threads_active
	ldr	w8, [x21, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB15_5
// %bb.4:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB15_5:
	adrp	x25, xt_simd_n
	adrp	x28, xt_simd_cap
	adrp	x27, xt_simd_tab
	ldr	x24, [x25, :lo12:xt_simd_n]
	ldr	x8, [x28, :lo12:xt_simd_cap]
	adrp	x26, xt_simd_flag
	cmp	x24, x8
	b.ne	.Lrt_BB15_17
// %bb.6:
	lsl	x9, x8, #1
	cmp	x8, #0
	mov	w8, #64                         // =0x40
	mov	w1, #8                          // =0x8
	csel	x21, x8, x9, eq
	lsl	x0, x21, #1
	bl	calloc
	mov	x22, x0
	mov	x0, x21
	mov	w1, #1                          // =0x1
	bl	calloc
	cmp	x22, #0
	mov	x23, x0
	ccmp	x0, #0, #4, ne
	cset	w29, ne
	b.eq	.Lrt_BB15_14
// %bb.7:
	lsl	x8, x24, #1
	cbz	x8, .Lrt_BB15_10
// %bb.8:
	ldr	x9, [x27, :lo12:xt_simd_tab]
	mov	x10, x22
.Lrt_BB15_9:                               // =>This Inner Loop Header: Depth=1
	ldr	x11, [x9], #8
	subs	x8, x8, #1
	str	x11, [x10], #8
	b.ne	.Lrt_BB15_9
.Lrt_BB15_10:
	cbz	x24, .Lrt_BB15_13
// %bb.11:
	ldr	x8, [x26, :lo12:xt_simd_flag]
	mov	x9, x23
.Lrt_BB15_12:                              // =>This Inner Loop Header: Depth=1
	ldrb	w10, [x8], #1
	subs	x24, x24, #1
	strb	w10, [x9], #1
	b.ne	.Lrt_BB15_12
.Lrt_BB15_13:
	ldr	x0, [x27, :lo12:xt_simd_tab]
	bl	free
	ldr	x0, [x26, :lo12:xt_simd_flag]
	bl	free
	str	x22, [x27, :lo12:xt_simd_tab]
	str	x23, [x26, :lo12:xt_simd_flag]
	str	x21, [x28, :lo12:xt_simd_cap]
	adrp	x21, _xt_threads_active
	b	.Lrt_BB15_16
.Lrt_BB15_14:
	mov	x0, x22
	bl	free
	mov	x0, x23
	bl	free
	adrp	x21, _xt_threads_active
	ldr	w8, [x21, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB15_16
// %bb.15:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB15_16:
	cbz	w29, .Lrt_BB15_26
.Lrt_BB15_17:
	ldr	x8, [x25, :lo12:xt_simd_n]
	cbz	x8, .Lrt_BB15_21
// %bb.18:
	ldr	x10, [x27, :lo12:xt_simd_tab]
	mov	x9, xzr
	mov	x11, x8
.Lrt_BB15_19:                              // =>This Inner Loop Header: Depth=1
	add	x12, x11, x9
	and	x13, x12, #0x1ffffffffffffffe
	lsr	x12, x12, #1
	ldr	x13, [x10, x13, lsl #3]
	cmp	x13, x19
	csel	x11, x12, x11, hi
	csinc	x9, x9, x12, hi
	cmp	x9, x11
	b.lo	.Lrt_BB15_19
// %bb.20:
	cmp	x8, x9
	b.hi	.Lrt_BB15_22
	b	.Lrt_BB15_24
.Lrt_BB15_21:
	mov	x9, xzr
	cmp	x8, x9
	b.ls	.Lrt_BB15_24
.Lrt_BB15_22:
	ldr	x10, [x27, :lo12:xt_simd_tab]
	mov	x11, x8
	add	x13, x10, x8, lsl #4
	ldr	x10, [x26, :lo12:xt_simd_flag]
	mov	x12, x13
.Lrt_BB15_23:                              // =>This Inner Loop Header: Depth=1
	ldr	x14, [x12, #-16]!
	ldur	x15, [x13, #-8]
	stp	x14, x15, [x13]
	add	x13, x10, x11
	sub	x11, x11, #1
	ldurb	w14, [x13, #-1]
	cmp	x11, x9
	strb	w14, [x13]
	mov	x13, x12
	b.hi	.Lrt_BB15_23
.Lrt_BB15_24:
	ldr	x10, [x27, :lo12:xt_simd_tab]
	add	x11, x19, x20
	add	x8, x8, #1
	add	x10, x10, x9, lsl #4
	stp	x19, x11, [x10]
	ldr	x10, [x26, :lo12:xt_simd_flag]
	strb	wzr, [x10, x9]
	ldr	w9, [x21, :lo12:_xt_threads_active]
	str	x8, [x25, :lo12:xt_simd_n]
	cbz	w9, .Lrt_BB15_26
// %bb.25:
	ldp	x20, x19, [sp, #80]             // 16-byte Folded Reload
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	ldp	x22, x21, [sp, #64]             // 16-byte Folded Reload
	ldp	x24, x23, [sp, #48]             // 16-byte Folded Reload
	ldp	x26, x25, [sp, #32]             // 16-byte Folded Reload
	ldp	x28, x27, [sp, #16]             // 16-byte Folded Reload
	ldp	x29, x30, [sp], #96             // 16-byte Folded Reload
	b	pthread_mutex_unlock
.Lrt_BB15_26:
	ldp	x20, x19, [sp, #80]             // 16-byte Folded Reload
	ldp	x22, x21, [sp, #64]             // 16-byte Folded Reload
	ldp	x24, x23, [sp, #48]             // 16-byte Folded Reload
	ldp	x26, x25, [sp, #32]             // 16-byte Folded Reload
	ldp	x28, x27, [sp, #16]             // 16-byte Folded Reload
	ldp	x29, x30, [sp], #96             // 16-byte Folded Reload
	ret
.Lrt_func_end15:
	.size	_xtc_simd_register, .Lrt_func_end15-_xtc_simd_register
                                        // -- End function
	.globl	_xtc_simd_base                  // -- Begin function _xtc_simd_base
	.p2align	2
	.type	_xtc_simd_base,@function
_xtc_simd_base:                         // @_xtc_simd_base
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	adrp	x20, _xt_threads_active
	mov	x19, x0
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB16_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB16_2:
	adrp	x8, xt_simd_n
	ldr	x9, [x8, :lo12:xt_simd_n]
	adrp	x8, xt_simd_tab
	cbz	x9, .Lrt_BB16_6
// %bb.3:
	ldr	x11, [x8, :lo12:xt_simd_tab]
	mov	x10, xzr
.Lrt_BB16_4:                               // =>This Inner Loop Header: Depth=1
	add	x12, x9, x10
	and	x13, x12, #0x1ffffffffffffffe
	lsr	x12, x12, #1
	ldr	x13, [x11, x13, lsl #3]
	cmp	x13, x19
	csel	x9, x12, x9, hi
	csinc	x10, x10, x12, hi
	cmp	x10, x9
	b.lo	.Lrt_BB16_4
// %bb.5:
	cbnz	x10, .Lrt_BB16_7
	b	.Lrt_BB16_9
.Lrt_BB16_6:
	mov	x10, xzr
	cbz	x10, .Lrt_BB16_9
.Lrt_BB16_7:
	ldr	x8, [x8, :lo12:xt_simd_tab]
	add	x8, x8, x10, lsl #4
	ldur	x9, [x8, #-8]
	cmp	x9, x19
	b.ls	.Lrt_BB16_9
// %bb.8:
	ldur	x19, [x8, #-16]
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbnz	w8, .Lrt_BB16_10
	b	.Lrt_BB16_11
.Lrt_BB16_9:
	mov	x19, xzr
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB16_11
.Lrt_BB16_10:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB16_11:
	mov	x0, x19
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end16:
	.size	_xtc_simd_base, .Lrt_func_end16-_xtc_simd_base
                                        // -- End function
	.globl	_xt_rt_lock                     // -- Begin function _xt_rt_lock
	.p2align	2
	.type	_xt_rt_lock,@function
_xt_rt_lock:                            // @_xt_rt_lock
// %bb.0:
	adrp	x8, _xt_threads_active
	ldr	w8, [x8, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB17_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	b	pthread_mutex_lock
.Lrt_BB17_2:
	ret
.Lrt_func_end17:
	.size	_xt_rt_lock, .Lrt_func_end17-_xt_rt_lock
                                        // -- End function
	.globl	_xt_rt_unlock                   // -- Begin function _xt_rt_unlock
	.p2align	2
	.type	_xt_rt_unlock,@function
_xt_rt_unlock:                          // @_xt_rt_unlock
// %bb.0:
	adrp	x8, _xt_threads_active
	ldr	w8, [x8, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB18_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	b	pthread_mutex_unlock
.Lrt_BB18_2:
	ret
.Lrt_func_end18:
	.size	_xt_rt_unlock, .Lrt_func_end18-_xt_rt_unlock
                                        // -- End function
	.globl	_xtc_simd_span                  // -- Begin function _xtc_simd_span
	.p2align	2
	.type	_xtc_simd_span,@function
_xtc_simd_span:                         // @_xtc_simd_span
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	adrp	x20, _xt_threads_active
	mov	x19, x0
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB19_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB19_2:
	adrp	x8, xt_simd_n
	ldr	x9, [x8, :lo12:xt_simd_n]
	adrp	x8, xt_simd_tab
	cbz	x9, .Lrt_BB19_6
// %bb.3:
	ldr	x11, [x8, :lo12:xt_simd_tab]
	mov	x10, xzr
.Lrt_BB19_4:                               // =>This Inner Loop Header: Depth=1
	add	x12, x9, x10
	and	x13, x12, #0x1ffffffffffffffe
	lsr	x12, x12, #1
	ldr	x13, [x11, x13, lsl #3]
	cmp	x13, x19
	csel	x9, x12, x9, hi
	csinc	x10, x10, x12, hi
	cmp	x10, x9
	b.lo	.Lrt_BB19_4
// %bb.5:
	cbnz	x10, .Lrt_BB19_7
	b	.Lrt_BB19_8
.Lrt_BB19_6:
	mov	x10, xzr
	cbz	x10, .Lrt_BB19_8
.Lrt_BB19_7:
	ldr	x8, [x8, :lo12:xt_simd_tab]
	add	x8, x8, x10, lsl #4
	ldur	x8, [x8, #-8]
	subs	x19, x8, x19
	b.hi	.Lrt_BB19_9
.Lrt_BB19_8:
	mov	x19, #-1                        // =0xffffffffffffffff
.Lrt_BB19_9:
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB19_11
// %bb.10:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB19_11:
	mov	x0, x19
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end19:
	.size	_xtc_simd_span, .Lrt_func_end19-_xtc_simd_span
                                        // -- End function
	.globl	_xtc_simd_watch                 // -- Begin function _xtc_simd_watch
	.p2align	2
	.type	_xtc_simd_watch,@function
_xtc_simd_watch:                        // @_xtc_simd_watch
// %bb.0:
	sub	sp, sp, #96
	stp	x22, x21, [sp, #64]             // 16-byte Folded Spill
	adrp	x21, _xt_threads_active
	ldr	w8, [x21, :lo12:_xt_threads_active]
	stp	x20, x19, [sp, #80]             // 16-byte Folded Spill
	mov	x19, x0
	stp	x30, x25, [sp, #32]             // 16-byte Folded Spill
	stp	x24, x23, [sp, #48]             // 16-byte Folded Spill
	cbz	w8, .Lrt_BB20_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB20_2:
	adrp	x8, xt_simd_n
	adrp	x22, xt_simd_tab
	ldr	x8, [x8, :lo12:xt_simd_n]
	cbz	x8, .Lrt_BB20_6
// %bb.3:
	ldr	x10, [x22, :lo12:xt_simd_tab]
	mov	x9, xzr
.Lrt_BB20_4:                               // =>This Inner Loop Header: Depth=1
	add	x11, x8, x9
	and	x12, x11, #0x1ffffffffffffffe
	lsr	x11, x11, #1
	ldr	x12, [x10, x12, lsl #3]
	cmp	x12, x19
	csel	x8, x11, x8, hi
	csinc	x9, x9, x11, hi
	cmp	x9, x8
	b.lo	.Lrt_BB20_4
// %bb.5:
	cbnz	x9, .Lrt_BB20_7
	b	.Lrt_BB20_11
.Lrt_BB20_6:
	mov	x9, xzr
	cbz	x9, .Lrt_BB20_11
.Lrt_BB20_7:
	sub	x23, x9, #1
	ldr	x8, [x22, :lo12:xt_simd_tab]
	lsl	x9, x23, #4
	ldr	x8, [x8, x9]
	cmp	x8, x19
	b.ne	.Lrt_BB20_11
// %bb.8:
	adrp	x25, xt_simd_installed
	lsl	x24, x23, #1
	ldrb	w8, [x25, :lo12:xt_simd_installed]
	tbnz	w8, #0, .Lrt_BB20_10
// %bb.9:
	adrp	x8, xt_simd_fault
	add	x8, x8, :lo12:xt_simd_fault
	str	x8, [sp, #8]
	mov	w8, #4                          // =0x4
	movk	w8, #16384, lsl #16
	str	w8, [sp]
	mov	x8, sp
	add	x0, x8, #16
	bl	sigemptyset
	adrp	x20, xt_simd_old
	add	x20, x20, :lo12:xt_simd_old
	mov	x1, sp
	mov	w0, #11                         // =0xb
	mov	x2, x20
	str	xzr, [sp, #24]
	bl	sigaction
	mov	x1, sp
	add	x2, x20, #32
	mov	w0, #7                          // =0x7
	bl	sigaction
	mov	w8, #1                          // =0x1
	strb	w8, [x25, :lo12:xt_simd_installed]
.Lrt_BB20_10:
	lsl	x8, x24, #3
	ldr	x9, [x22, :lo12:xt_simd_tab]
	mov	x0, x19
	mov	w2, #1                          // =0x1
	orr	x10, x8, #0x8
	ldr	x8, [x9, x8]
	ldr	x10, [x9, x10]
	mov	w9, #16383                      // =0x3fff
	sub	x8, x10, x8
	add	x8, x8, x9
	and	x1, x8, #0xffffffffffffc000
	bl	mprotect
	cbz	w0, .Lrt_BB20_14
.Lrt_BB20_11:
	mov	w19, wzr
	ldr	w8, [x21, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB20_13
.Lrt_BB20_12:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB20_13:
	mov	w0, w19
	ldp	x20, x19, [sp, #80]             // 16-byte Folded Reload
	ldp	x22, x21, [sp, #64]             // 16-byte Folded Reload
	ldp	x24, x23, [sp, #48]             // 16-byte Folded Reload
	ldp	x30, x25, [sp, #32]             // 16-byte Folded Reload
	add	sp, sp, #96
	ret
.Lrt_BB20_14:
	adrp	x8, xt_simd_flag
	mov	w19, #1                         // =0x1
	ldr	x8, [x8, :lo12:xt_simd_flag]
	ldrb	w9, [x8, x23]
	orr	w9, w9, #0x1
	strb	w9, [x8, x23]
	ldr	w8, [x21, :lo12:_xt_threads_active]
	cbnz	w8, .Lrt_BB20_12
	b	.Lrt_BB20_13
.Lrt_func_end20:
	.size	_xtc_simd_watch, .Lrt_func_end20-_xtc_simd_watch
                                        // -- End function
	.p2align	2                               // -- Begin function xt_simd_fault
	.type	xt_simd_fault,@function
xt_simd_fault:                          // @xt_simd_fault
// %bb.0:
	stp	x30, x21, [sp, #-32]!           // 16-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	adrp	x20, _xt_threads_active
	ldr	x21, [x1, #16]
	ldr	w8, [x20, :lo12:_xt_threads_active]
	mov	w19, w0
	cbz	w8, .Lrt_BB21_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB21_2:
	adrp	x8, xt_simd_n
	ldr	x9, [x8, :lo12:xt_simd_n]
	adrp	x8, xt_simd_tab
	cbz	x9, .Lrt_BB21_6
// %bb.3:
	ldr	x11, [x8, :lo12:xt_simd_tab]
	mov	x10, xzr
.Lrt_BB21_4:                               // =>This Inner Loop Header: Depth=1
	add	x12, x9, x10
	and	x13, x12, #0x1ffffffffffffffe
	lsr	x12, x12, #1
	ldr	x13, [x11, x13, lsl #3]
	cmp	x13, x21
	csel	x9, x12, x9, hi
	csinc	x10, x10, x12, hi
	cmp	x10, x9
	b.lo	.Lrt_BB21_4
// %bb.5:
	cbnz	x10, .Lrt_BB21_7
	b	.Lrt_BB21_9
.Lrt_BB21_6:
	mov	x10, xzr
	cbz	x10, .Lrt_BB21_9
.Lrt_BB21_7:
	ldr	x8, [x8, :lo12:xt_simd_tab]
	sub	x9, x10, #1
	add	x10, x8, x9, lsl #4
	ldr	x10, [x10, #8]
	cmp	x21, x10
	b.hs	.Lrt_BB21_9
// %bb.8:
	adrp	x11, xt_simd_flag
	ldr	x11, [x11, :lo12:xt_simd_flag]
	ldrb	w12, [x11, x9]
	tbnz	w12, #0, .Lrt_BB21_12
.Lrt_BB21_9:
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB21_11
// %bb.10:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB21_11:
	cmp	w19, #11
	mov	w0, w19
	adrp	x9, xt_simd_old
	add	x9, x9, :lo12:xt_simd_old
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	cset	w8, ne
	mov	x2, xzr
	add	x1, x9, x8, lsl #5
	ldp	x30, x21, [sp], #32             // 16-byte Folded Reload
	b	sigaction
.Lrt_BB21_12:
	lsl	x13, x9, #1
	and	w12, w12, #0xfe
	strb	w12, [x11, x9]
	mov	w9, #16383                      // =0x3fff
	mov	w2, #3                          // =0x3
	ldr	x0, [x8, x13, lsl #3]
	sub	x8, x10, x0
	add	x8, x8, x9
	and	x1, x8, #0xffffffffffffc000
	bl	mprotect
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB21_14
// %bb.13:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	ldp	x30, x21, [sp], #32             // 16-byte Folded Reload
	b	pthread_mutex_unlock
.Lrt_BB21_14:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldp	x30, x21, [sp], #32             // 16-byte Folded Reload
	ret
.Lrt_func_end21:
	.size	xt_simd_fault, .Lrt_func_end21-xt_simd_fault
                                        // -- End function
	.globl	_xtc_simd_unwatch               // -- Begin function _xtc_simd_unwatch
	.p2align	2
	.type	_xtc_simd_unwatch,@function
_xtc_simd_unwatch:                      // @_xtc_simd_unwatch
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	adrp	x20, _xt_threads_active
	mov	x19, x0
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB22_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB22_2:
	adrp	x8, xt_simd_n
	ldr	x9, [x8, :lo12:xt_simd_n]
	adrp	x8, xt_simd_tab
	cbz	x9, .Lrt_BB22_6
// %bb.3:
	ldr	x11, [x8, :lo12:xt_simd_tab]
	mov	x10, xzr
.Lrt_BB22_4:                               // =>This Inner Loop Header: Depth=1
	add	x12, x9, x10
	and	x13, x12, #0x1ffffffffffffffe
	lsr	x12, x12, #1
	ldr	x13, [x11, x13, lsl #3]
	cmp	x13, x19
	csel	x9, x12, x9, hi
	csinc	x10, x10, x12, hi
	cmp	x10, x9
	b.lo	.Lrt_BB22_4
// %bb.5:
	cbnz	x10, .Lrt_BB22_7
	b	.Lrt_BB22_10
.Lrt_BB22_6:
	mov	x10, xzr
	cbz	x10, .Lrt_BB22_10
.Lrt_BB22_7:
	sub	x9, x10, #1
	ldr	x8, [x8, :lo12:xt_simd_tab]
	lsl	x10, x9, #4
	ldr	x10, [x8, x10]
	cmp	x10, x19
	b.ne	.Lrt_BB22_10
// %bb.8:
	adrp	x11, xt_simd_flag
	ldr	x11, [x11, :lo12:xt_simd_flag]
	ldrb	w12, [x11, x9]
	tbz	w12, #0, .Lrt_BB22_10
// %bb.9:
	lsl	x13, x9, #1
	and	w12, w12, #0xfe
	strb	w12, [x11, x9]
	mov	x0, x19
	mov	w2, #3                          // =0x3
	lsl	x13, x13, #3
	orr	x9, x13, #0x8
	ldr	x8, [x8, x9]
	mov	w9, #16383                      // =0x3fff
	sub	x8, x8, x10
	add	x8, x8, x9
	and	x1, x8, #0xffffffffffffc000
	bl	mprotect
.Lrt_BB22_10:
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB22_12
// %bb.11:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	b	pthread_mutex_unlock
.Lrt_BB22_12:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end22:
	.size	_xtc_simd_unwatch, .Lrt_func_end22-_xtc_simd_unwatch
                                        // -- End function
	.globl	_xtc_simd_dirty                 // -- Begin function _xtc_simd_dirty
	.p2align	2
	.type	_xtc_simd_dirty,@function
_xtc_simd_dirty:                        // @_xtc_simd_dirty
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	adrp	x20, _xt_threads_active
	mov	x19, x0
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB23_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB23_2:
	adrp	x8, xt_simd_n
	ldr	x9, [x8, :lo12:xt_simd_n]
	adrp	x8, xt_simd_tab
	cbz	x9, .Lrt_BB23_8
// %bb.3:
	ldr	x11, [x8, :lo12:xt_simd_tab]
	mov	x10, xzr
.Lrt_BB23_4:                               // =>This Inner Loop Header: Depth=1
	add	x12, x9, x10
	and	x13, x12, #0x1ffffffffffffffe
	lsr	x12, x12, #1
	ldr	x13, [x11, x13, lsl #3]
	cmp	x13, x19
	csel	x9, x12, x9, hi
	csinc	x10, x10, x12, hi
	cmp	x10, x9
	b.lo	.Lrt_BB23_4
// %bb.5:
	cbz	x10, .Lrt_BB23_9
.Lrt_BB23_6:
	sub	x9, x10, #1
	ldr	x8, [x8, :lo12:xt_simd_tab]
	lsl	x10, x9, #4
	ldr	x8, [x8, x10]
	cmp	x8, x19
	mov	w19, #1                         // =0x1
	b.ne	.Lrt_BB23_10
// %bb.7:
	adrp	x8, xt_simd_flag
	ldr	x8, [x8, :lo12:xt_simd_flag]
	ldrb	w8, [x8, x9]
	bic	w19, w19, w8
	b	.Lrt_BB23_10
.Lrt_BB23_8:
	mov	x10, xzr
	cbnz	x10, .Lrt_BB23_6
.Lrt_BB23_9:
	mov	w19, #1                         // =0x1
.Lrt_BB23_10:
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB23_12
// %bb.11:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB23_12:
	mov	w0, w19
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end23:
	.size	_xtc_simd_dirty, .Lrt_func_end23-_xtc_simd_dirty
                                        // -- End function
	.globl	_xtc_new_simd_u8                // -- Begin function _xtc_new_simd_u8
	.p2align	2
	.type	_xtc_new_simd_u8,@function
_xtc_new_simd_u8:                       // @_xtc_new_simd_u8
// %bb.0:
	mov	w1, #1                          // =0x1
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end24:
	.size	_xtc_new_simd_u8, .Lrt_func_end24-_xtc_new_simd_u8
                                        // -- End function
	.globl	_xtc_new_simd_i8                // -- Begin function _xtc_new_simd_i8
	.p2align	2
	.type	_xtc_new_simd_i8,@function
_xtc_new_simd_i8:                       // @_xtc_new_simd_i8
// %bb.0:
	mov	w1, #1                          // =0x1
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end25:
	.size	_xtc_new_simd_i8, .Lrt_func_end25-_xtc_new_simd_i8
                                        // -- End function
	.globl	_xtc_new_simd_bool              // -- Begin function _xtc_new_simd_bool
	.p2align	2
	.type	_xtc_new_simd_bool,@function
_xtc_new_simd_bool:                     // @_xtc_new_simd_bool
// %bb.0:
	mov	w1, #1                          // =0x1
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end26:
	.size	_xtc_new_simd_bool, .Lrt_func_end26-_xtc_new_simd_bool
                                        // -- End function
	.globl	_xtc_new_simd_u16               // -- Begin function _xtc_new_simd_u16
	.p2align	2
	.type	_xtc_new_simd_u16,@function
_xtc_new_simd_u16:                      // @_xtc_new_simd_u16
// %bb.0:
	mov	w1, #2                          // =0x2
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end27:
	.size	_xtc_new_simd_u16, .Lrt_func_end27-_xtc_new_simd_u16
                                        // -- End function
	.globl	_xtc_new_simd_i16               // -- Begin function _xtc_new_simd_i16
	.p2align	2
	.type	_xtc_new_simd_i16,@function
_xtc_new_simd_i16:                      // @_xtc_new_simd_i16
// %bb.0:
	mov	w1, #2                          // =0x2
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end28:
	.size	_xtc_new_simd_i16, .Lrt_func_end28-_xtc_new_simd_i16
                                        // -- End function
	.globl	_xtc_new_simd_u32               // -- Begin function _xtc_new_simd_u32
	.p2align	2
	.type	_xtc_new_simd_u32,@function
_xtc_new_simd_u32:                      // @_xtc_new_simd_u32
// %bb.0:
	mov	w1, #4                          // =0x4
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end29:
	.size	_xtc_new_simd_u32, .Lrt_func_end29-_xtc_new_simd_u32
                                        // -- End function
	.globl	_xtc_new_simd_i32               // -- Begin function _xtc_new_simd_i32
	.p2align	2
	.type	_xtc_new_simd_i32,@function
_xtc_new_simd_i32:                      // @_xtc_new_simd_i32
// %bb.0:
	mov	w1, #4                          // =0x4
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end30:
	.size	_xtc_new_simd_i32, .Lrt_func_end30-_xtc_new_simd_i32
                                        // -- End function
	.globl	_xtc_new_simd_float             // -- Begin function _xtc_new_simd_float
	.p2align	2
	.type	_xtc_new_simd_float,@function
_xtc_new_simd_float:                    // @_xtc_new_simd_float
// %bb.0:
	mov	w1, #4                          // =0x4
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end31:
	.size	_xtc_new_simd_float, .Lrt_func_end31-_xtc_new_simd_float
                                        // -- End function
	.globl	_xtc_new_simd_u64               // -- Begin function _xtc_new_simd_u64
	.p2align	2
	.type	_xtc_new_simd_u64,@function
_xtc_new_simd_u64:                      // @_xtc_new_simd_u64
// %bb.0:
	mov	w1, #8                          // =0x8
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end32:
	.size	_xtc_new_simd_u64, .Lrt_func_end32-_xtc_new_simd_u64
                                        // -- End function
	.globl	_xtc_new_simd_i64               // -- Begin function _xtc_new_simd_i64
	.p2align	2
	.type	_xtc_new_simd_i64,@function
_xtc_new_simd_i64:                      // @_xtc_new_simd_i64
// %bb.0:
	mov	w1, #8                          // =0x8
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end33:
	.size	_xtc_new_simd_i64, .Lrt_func_end33-_xtc_new_simd_i64
                                        // -- End function
	.globl	_xtc_new_simd_double            // -- Begin function _xtc_new_simd_double
	.p2align	2
	.type	_xtc_new_simd_double,@function
_xtc_new_simd_double:                   // @_xtc_new_simd_double
// %bb.0:
	mov	w1, #8                          // =0x8
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end34:
	.size	_xtc_new_simd_double, .Lrt_func_end34-_xtc_new_simd_double
                                        // -- End function
	.globl	_xtc_new_simd_pointer           // -- Begin function _xtc_new_simd_pointer
	.p2align	2
	.type	_xtc_new_simd_pointer,@function
_xtc_new_simd_pointer:                  // @_xtc_new_simd_pointer
// %bb.0:
	mov	w1, #8                          // =0x8
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end35:
	.size	_xtc_new_simd_pointer, .Lrt_func_end35-_xtc_new_simd_pointer
                                        // -- End function
	.globl	_xtc_new_simd_string            // -- Begin function _xtc_new_simd_string
	.p2align	2
	.type	_xtc_new_simd_string,@function
_xtc_new_simd_string:                   // @_xtc_new_simd_string
// %bb.0:
	mov	w1, #8                          // =0x8
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end36:
	.size	_xtc_new_simd_string, .Lrt_func_end36-_xtc_new_simd_string
                                        // -- End function
	.globl	_xtc_count                      // -- Begin function _xtc_count
	.p2align	2
	.type	_xtc_count,@function
_xtc_count:                             // @_xtc_count
// %bb.0:
	ldur	x0, [x0, #-28]
	ret
.Lrt_func_end37:
	.size	_xtc_count, .Lrt_func_end37-_xtc_count
                                        // -- End function
	.globl	_xtc_dealloc                    // -- Begin function _xtc_dealloc
	.p2align	2
	.type	_xtc_dealloc,@function
_xtc_dealloc:                           // @_xtc_dealloc
// %bb.0:
	stp	x30, x23, [sp, #-48]!           // 16-byte Folded Spill
	stp	x20, x19, [sp, #32]             // 16-byte Folded Spill
	mov	x19, x0
	adrp	x20, _xt_threads_active
	stp	x22, x21, [sp, #16]             // 16-byte Folded Spill
	cbz	x0, .Lrt_BB38_7
// %bb.1:
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB38_3
// %bb.2:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB38_3:
	ldur	x8, [x19, #-12]
	cbz	x8, .Lrt_BB38_5
.Lrt_BB38_4:                               // =>This Inner Loop Header: Depth=1
	ldur	x9, [x8, #-8]
	stp	xzr, xzr, [x8, #-8]
	stur	xzr, [x8, #-16]
	mov	x8, x9
	cbnz	x9, .Lrt_BB38_4
.Lrt_BB38_5:
	ldr	w8, [x20, :lo12:_xt_threads_active]
	stur	xzr, [x19, #-12]
	cbz	w8, .Lrt_BB38_7
// %bb.6:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB38_7:
	mov	x0, x19
	mov	w9, #20291                      // =0x4f43
	ldr	w8, [x0, #-40]!
	movk	w9, #22612, lsl #16
	ldur	x21, [x0, #20]
	cmp	w8, w9
	b.ne	.Lrt_BB38_24
// %bb.8:
	cbz	x21, .Lrt_BB38_10
// %bb.9:
	mov	x0, x19
	blr	x21
.Lrt_BB38_10:
	mov	x0, x19
	bl	_xtc_simd_unwatch
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB38_12
// %bb.11:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB38_12:
	adrp	x8, xt_simd_n
	adrp	x11, xt_simd_tab
	mov	x10, xzr
	ldr	x9, [x8, :lo12:xt_simd_n]
	cbz	x9, .Lrt_BB38_15
// %bb.13:
	ldr	x12, [x11, :lo12:xt_simd_tab]
	mov	x13, x9
.Lrt_BB38_14:                              // =>This Inner Loop Header: Depth=1
	add	x14, x13, x10
	and	x15, x14, #0x1ffffffffffffffe
	lsr	x14, x14, #1
	ldr	x15, [x12, x15, lsl #3]
	cmp	x15, x19
	csel	x13, x14, x13, hi
	csinc	x10, x10, x14, hi
	cmp	x10, x13
	b.lo	.Lrt_BB38_14
.Lrt_BB38_15:
	cbz	x10, .Lrt_BB38_21
// %bb.16:
	ldr	x11, [x11, :lo12:xt_simd_tab]
	add	x11, x11, x10, lsl #4
	ldur	x12, [x11, #-16]
	cmp	x12, x19
	b.ne	.Lrt_BB38_21
// %bb.17:
	subs	x12, x9, x10
	b.ls	.Lrt_BB38_20
// %bb.18:
	adrp	x13, xt_simd_flag
	ldr	x13, [x13, :lo12:xt_simd_flag]
	add	x10, x13, x10
.Lrt_BB38_19:                              // =>This Inner Loop Header: Depth=1
	ldp	x13, x14, [x11]
	subs	x12, x12, #1
	stp	x13, x14, [x11, #-16]
	add	x11, x11, #16
	ldrb	w13, [x10]
	sturb	w13, [x10, #-1]
	add	x10, x10, #1
	b.ne	.Lrt_BB38_19
.Lrt_BB38_20:
	sub	x9, x9, #1
	str	x9, [x8, :lo12:xt_simd_n]
.Lrt_BB38_21:
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB38_23
// %bb.22:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB38_23:
	ldur	x0, [x19, #-48]
	b	.Lrt_BB38_29
.Lrt_BB38_24:
	cbz	x21, .Lrt_BB38_29
// %bb.25:
	ldur	x20, [x0, #12]
	ldur	x22, [x0, #4]
	mov	w8, #-2147483648                // =0x80000000
	stur	w8, [x19, #-4]
	cbz	x20, .Lrt_BB38_29
// %bb.26:
	mov	x23, x0
.Lrt_BB38_27:                              // =>This Inner Loop Header: Depth=1
	mov	x0, x19
	blr	x21
	subs	x20, x20, #1
	add	x19, x19, x22
	b.ne	.Lrt_BB38_27
// %bb.28:
	mov	x0, x23
.Lrt_BB38_29:
	ldp	x20, x19, [sp, #32]             // 16-byte Folded Reload
	ldp	x22, x21, [sp, #16]             // 16-byte Folded Reload
	ldp	x30, x23, [sp], #48             // 16-byte Folded Reload
	b	free
.Lrt_func_end38:
	.size	_xtc_dealloc, .Lrt_func_end38-_xtc_dealloc
                                        // -- End function
	.globl	_xtc_weak_zero_for              // -- Begin function _xtc_weak_zero_for
	.p2align	2
	.type	_xtc_weak_zero_for,@function
_xtc_weak_zero_for:                     // @_xtc_weak_zero_for
// %bb.0:
	cbz	x0, .Lrt_BB39_7
// %bb.1:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	adrp	x20, _xt_threads_active
	mov	x19, x0
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB39_3
// %bb.2:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB39_3:
	ldur	x8, [x19, #-12]
	cbz	x8, .Lrt_BB39_5
.Lrt_BB39_4:                               // =>This Inner Loop Header: Depth=1
	ldur	x9, [x8, #-8]
	stp	xzr, xzr, [x8, #-8]
	stur	xzr, [x8, #-16]
	mov	x8, x9
	cbnz	x9, .Lrt_BB39_4
.Lrt_BB39_5:
	ldr	w8, [x20, :lo12:_xt_threads_active]
	stur	xzr, [x19, #-12]
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	cbz	w8, .Lrt_BB39_7
// %bb.6:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	b	pthread_mutex_unlock
.Lrt_BB39_7:
	ret
.Lrt_func_end39:
	.size	_xtc_weak_zero_for, .Lrt_func_end39-_xtc_weak_zero_for
                                        // -- End function
	.globl	_xtc_weak_unregister            // -- Begin function _xtc_weak_unregister
	.p2align	2
	.type	_xtc_weak_unregister,@function
_xtc_weak_unregister:                   // @_xtc_weak_unregister
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	adrp	x20, _xt_threads_active
	mov	x19, x0
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB40_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB40_2:
	mov	x8, x19
	ldr	x9, [x8, #-16]!
	cbz	x9, .Lrt_BB40_7
// %bb.3:
	ldr	x10, [x9]
	cmp	x10, x19
	b.ne	.Lrt_BB40_6
// %bb.4:
	ldur	x10, [x19, #-8]
	str	x10, [x9]
	cbz	x10, .Lrt_BB40_6
// %bb.5:
	stur	x9, [x10, #-16]
.Lrt_BB40_6:
	stp	xzr, xzr, [x8]
.Lrt_BB40_7:
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB40_9
// %bb.8:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	b	pthread_mutex_unlock
.Lrt_BB40_9:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end40:
	.size	_xtc_weak_unregister, .Lrt_func_end40-_xtc_weak_unregister
                                        // -- End function
	.globl	_xtc_weak_register              // -- Begin function _xtc_weak_register
	.p2align	2
	.type	_xtc_weak_register,@function
_xtc_weak_register:                     // @_xtc_weak_register
// %bb.0:
	stp	x30, x21, [sp, #-32]!           // 16-byte Folded Spill
	adrp	x21, _xt_threads_active
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	mov	x19, x1
	ldr	w8, [x21, :lo12:_xt_threads_active]
	mov	x20, x0
	cbz	w8, .Lrt_BB41_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB41_2:
	mov	x8, x20
	ldr	x9, [x8, #-16]!
	cbz	x9, .Lrt_BB41_7
// %bb.3:
	ldr	x10, [x9]
	cmp	x10, x20
	b.ne	.Lrt_BB41_6
// %bb.4:
	ldur	x10, [x20, #-8]
	str	x10, [x9]
	cbz	x10, .Lrt_BB41_6
// %bb.5:
	stur	x9, [x10, #-16]
.Lrt_BB41_6:
	stp	xzr, xzr, [x8]
.Lrt_BB41_7:
	cbz	x19, .Lrt_BB41_13
// %bb.8:
	ldur	w8, [x19, #-40]
	mov	w9, #10145                      // =0x27a1
	movk	w9, #11306, lsl #16
	cmp	w9, w8, lsr #1
	b.ne	.Lrt_BB41_13
// %bb.9:
	ldr	x8, [x19, #-12]!
	mov	x9, x20
	str	x8, [x9, #-8]!
	stur	x19, [x9, #-8]
	cbz	x8, .Lrt_BB41_11
// %bb.10:
	stur	x9, [x8, #-16]
.Lrt_BB41_11:
	ldr	w8, [x21, :lo12:_xt_threads_active]
	str	x20, [x19]
	cbnz	w8, .Lrt_BB41_14
.Lrt_BB41_12:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldp	x30, x21, [sp], #32             // 16-byte Folded Reload
	ret
.Lrt_BB41_13:
	ldr	w8, [x21, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB41_12
.Lrt_BB41_14:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	ldp	x30, x21, [sp], #32             // 16-byte Folded Reload
	b	pthread_mutex_unlock
.Lrt_func_end41:
	.size	_xtc_weak_register, .Lrt_func_end41-_xtc_weak_register
                                        // -- End function
	.globl	_xtc_weak_load                  // -- Begin function _xtc_weak_load
	.p2align	2
	.type	_xtc_weak_load,@function
_xtc_weak_load:                         // @_xtc_weak_load
// %bb.0:
	ldr	x0, [x0]
	ret
.Lrt_func_end42:
	.size	_xtc_weak_load, .Lrt_func_end42-_xtc_weak_load
                                        // -- End function
	.globl	_putc                           // -- Begin function _putc
	.p2align	2
	.type	_putc,@function
_putc:                                  // @_putc
// %bb.0:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	strb	w0, [sp, #12]
	add	x1, sp, #12
	mov	w0, #1                          // =0x1
	mov	w2, #1                          // =0x1
	bl	write
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
	ret
.Lrt_func_end43:
	.size	_putc, .Lrt_func_end43-_putc
                                        // -- End function
	.globl	_xtc_pf                         // -- Begin function _xtc_pf
	.p2align	2
	.type	_xtc_pf,@function
_xtc_pf:                                // @_xtc_pf
// %bb.0:
	sub	sp, sp, #80
	fcvt	d0, s0
	adrp	x2, .Lrt_.str.1
	add	x2, x2, :lo12:.Lrt_.str.1
	mov	x0, sp
	mov	w1, #64                         // =0x40
	stp	x30, x19, [sp, #64]             // 16-byte Folded Spill
	mov	x19, sp
	bl	snprintf
	mov	x8, xzr
.Lrt_BB44_1:                               // =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, .Lrt_BB44_1
// %bb.2:
	sub	x2, x8, #1
	mov	x1, sp
	mov	w0, #1                          // =0x1
	bl	write
	ldp	x30, x19, [sp, #64]             // 16-byte Folded Reload
	add	sp, sp, #80
	ret
.Lrt_func_end44:
	.size	_xtc_pf, .Lrt_func_end44-_xtc_pf
                                        // -- End function
	.globl	_xtc_pd                         // -- Begin function _xtc_pd
	.p2align	2
	.type	_xtc_pd,@function
_xtc_pd:                                // @_xtc_pd
// %bb.0:
	sub	sp, sp, #80
	adrp	x2, .Lrt_.str.2
	add	x2, x2, :lo12:.Lrt_.str.2
	mov	x0, sp
	mov	w1, #64                         // =0x40
	stp	x30, x19, [sp, #64]             // 16-byte Folded Spill
	mov	x19, sp
	bl	snprintf
	mov	x8, xzr
.Lrt_BB45_1:                               // =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, .Lrt_BB45_1
// %bb.2:
	sub	x2, x8, #1
	mov	x1, sp
	mov	w0, #1                          // =0x1
	bl	write
	ldp	x30, x19, [sp, #64]             // 16-byte Folded Reload
	add	sp, sp, #80
	ret
.Lrt_func_end45:
	.size	_xtc_pd, .Lrt_func_end45-_xtc_pd
                                        // -- End function
	.globl	_xtc_pfp                        // -- Begin function _xtc_pfp
	.p2align	2
	.type	_xtc_pfp,@function
_xtc_pfp:                               // @_xtc_pfp
// %bb.0:
	sub	sp, sp, #80
	fcvt	d0, s0
	tst	w0, #0xff
	stp	x30, x19, [sp, #64]             // 16-byte Folded Spill
	b.eq	.Lrt_BB46_7
// %bb.1:
	and	w8, w0, #0xff
	adrp	x2, .Lrt_.str.5
	add	x2, x2, :lo12:.Lrt_.str.5
	mov	x0, sp
	add	w3, w8, #1
	mov	w1, #64                         // =0x40
	mov	x19, sp
	bl	snprintf
	mov	x8, xzr
.Lrt_BB46_2:                               // =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, .Lrt_BB46_2
// %bb.3:
	cmp	x8, #1
	b.eq	.Lrt_BB46_5
// %bb.4:
	mov	x9, sp
	add	x8, x9, x8
	sturb	wzr, [x8, #-2]
.Lrt_BB46_5:
	mov	x8, xzr
	mov	x9, sp
.Lrt_BB46_6:                               // =>This Inner Loop Header: Depth=1
	ldrb	w10, [x9, x8]
	add	x8, x8, #1
	cbnz	w10, .Lrt_BB46_6
	b	.Lrt_BB46_9
.Lrt_BB46_7:
	adrp	x2, .Lrt_.str.1
	add	x2, x2, :lo12:.Lrt_.str.1
	mov	x0, sp
	mov	w1, #64                         // =0x40
	mov	x19, sp
	bl	snprintf
	mov	x8, xzr
.Lrt_BB46_8:                               // =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, .Lrt_BB46_8
.Lrt_BB46_9:
	sub	x2, x8, #1
	mov	x1, sp
	mov	w0, #1                          // =0x1
	bl	write
	ldp	x30, x19, [sp, #64]             // 16-byte Folded Reload
	add	sp, sp, #80
	ret
.Lrt_func_end46:
	.size	_xtc_pfp, .Lrt_func_end46-_xtc_pfp
                                        // -- End function
	.globl	_xtc_pdp                        // -- Begin function _xtc_pdp
	.p2align	2
	.type	_xtc_pdp,@function
_xtc_pdp:                               // @_xtc_pdp
// %bb.0:
	sub	sp, sp, #80
	tst	w0, #0xff
	stp	x30, x19, [sp, #64]             // 16-byte Folded Spill
	b.eq	.Lrt_BB47_7
// %bb.1:
	and	w8, w0, #0xff
	adrp	x2, .Lrt_.str.5
	add	x2, x2, :lo12:.Lrt_.str.5
	mov	x0, sp
	add	w3, w8, #1
	mov	w1, #64                         // =0x40
	mov	x19, sp
	bl	snprintf
	mov	x8, xzr
.Lrt_BB47_2:                               // =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, .Lrt_BB47_2
// %bb.3:
	cmp	x8, #1
	b.eq	.Lrt_BB47_5
// %bb.4:
	mov	x9, sp
	add	x8, x9, x8
	sturb	wzr, [x8, #-2]
.Lrt_BB47_5:
	mov	x8, xzr
	mov	x9, sp
.Lrt_BB47_6:                               // =>This Inner Loop Header: Depth=1
	ldrb	w10, [x9, x8]
	add	x8, x8, #1
	cbnz	w10, .Lrt_BB47_6
	b	.Lrt_BB47_9
.Lrt_BB47_7:
	adrp	x2, .Lrt_.str.2
	add	x2, x2, :lo12:.Lrt_.str.2
	mov	x0, sp
	mov	w1, #64                         // =0x40
	mov	x19, sp
	bl	snprintf
	mov	x8, xzr
.Lrt_BB47_8:                               // =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, .Lrt_BB47_8
.Lrt_BB47_9:
	sub	x2, x8, #1
	mov	x1, sp
	mov	w0, #1                          // =0x1
	bl	write
	ldp	x30, x19, [sp, #64]             // 16-byte Folded Reload
	add	sp, sp, #80
	ret
.Lrt_func_end47:
	.size	_xtc_pdp, .Lrt_func_end47-_xtc_pdp
                                        // -- End function
	.globl	_xm_sqrtf                       // -- Begin function _xm_sqrtf
	.p2align	2
	.type	_xm_sqrtf,@function
_xm_sqrtf:                              // @_xm_sqrtf
// %bb.0:
	fsqrt	s0, s0
	ret
.Lrt_func_end48:
	.size	_xm_sqrtf, .Lrt_func_end48-_xm_sqrtf
                                        // -- End function
	.globl	_xm_sqrt                        // -- Begin function _xm_sqrt
	.p2align	2
	.type	_xm_sqrt,@function
_xm_sqrt:                               // @_xm_sqrt
// %bb.0:
	fsqrt	d0, d0
	ret
.Lrt_func_end49:
	.size	_xm_sqrt, .Lrt_func_end49-_xm_sqrt
                                        // -- End function
	.globl	_xm_sinf                        // -- Begin function _xm_sinf
	.p2align	2
	.type	_xm_sinf,@function
_xm_sinf:                               // @_xm_sinf
// %bb.0:
	b	sinf
.Lrt_func_end50:
	.size	_xm_sinf, .Lrt_func_end50-_xm_sinf
                                        // -- End function
	.globl	_xm_sin                         // -- Begin function _xm_sin
	.p2align	2
	.type	_xm_sin,@function
_xm_sin:                                // @_xm_sin
// %bb.0:
	b	sin
.Lrt_func_end51:
	.size	_xm_sin, .Lrt_func_end51-_xm_sin
                                        // -- End function
	.globl	_xm_cosf                        // -- Begin function _xm_cosf
	.p2align	2
	.type	_xm_cosf,@function
_xm_cosf:                               // @_xm_cosf
// %bb.0:
	b	cosf
.Lrt_func_end52:
	.size	_xm_cosf, .Lrt_func_end52-_xm_cosf
                                        // -- End function
	.globl	_xm_cos                         // -- Begin function _xm_cos
	.p2align	2
	.type	_xm_cos,@function
_xm_cos:                                // @_xm_cos
// %bb.0:
	b	cos
.Lrt_func_end53:
	.size	_xm_cos, .Lrt_func_end53-_xm_cos
                                        // -- End function
	.globl	_xm_tanf                        // -- Begin function _xm_tanf
	.p2align	2
	.type	_xm_tanf,@function
_xm_tanf:                               // @_xm_tanf
// %bb.0:
	b	tanf
.Lrt_func_end54:
	.size	_xm_tanf, .Lrt_func_end54-_xm_tanf
                                        // -- End function
	.globl	_xm_tan                         // -- Begin function _xm_tan
	.p2align	2
	.type	_xm_tan,@function
_xm_tan:                                // @_xm_tan
// %bb.0:
	b	tan
.Lrt_func_end55:
	.size	_xm_tan, .Lrt_func_end55-_xm_tan
                                        // -- End function
	.globl	_xm_atanf                       // -- Begin function _xm_atanf
	.p2align	2
	.type	_xm_atanf,@function
_xm_atanf:                              // @_xm_atanf
// %bb.0:
	b	atanf
.Lrt_func_end56:
	.size	_xm_atanf, .Lrt_func_end56-_xm_atanf
                                        // -- End function
	.globl	_xm_atan                        // -- Begin function _xm_atan
	.p2align	2
	.type	_xm_atan,@function
_xm_atan:                               // @_xm_atan
// %bb.0:
	b	atan
.Lrt_func_end57:
	.size	_xm_atan, .Lrt_func_end57-_xm_atan
                                        // -- End function
	.globl	_xm_lnf                         // -- Begin function _xm_lnf
	.p2align	2
	.type	_xm_lnf,@function
_xm_lnf:                                // @_xm_lnf
// %bb.0:
	b	logf
.Lrt_func_end58:
	.size	_xm_lnf, .Lrt_func_end58-_xm_lnf
                                        // -- End function
	.globl	_xm_ln                          // -- Begin function _xm_ln
	.p2align	2
	.type	_xm_ln,@function
_xm_ln:                                 // @_xm_ln
// %bb.0:
	b	log
.Lrt_func_end59:
	.size	_xm_ln, .Lrt_func_end59-_xm_ln
                                        // -- End function
	.globl	_xm_expf                        // -- Begin function _xm_expf
	.p2align	2
	.type	_xm_expf,@function
_xm_expf:                               // @_xm_expf
// %bb.0:
	b	expf
.Lrt_func_end60:
	.size	_xm_expf, .Lrt_func_end60-_xm_expf
                                        // -- End function
	.globl	_xm_exp                         // -- Begin function _xm_exp
	.p2align	2
	.type	_xm_exp,@function
_xm_exp:                                // @_xm_exp
// %bb.0:
	b	exp
.Lrt_func_end61:
	.size	_xm_exp, .Lrt_func_end61-_xm_exp
                                        // -- End function
	.globl	_xm_powf                        // -- Begin function _xm_powf
	.p2align	2
	.type	_xm_powf,@function
_xm_powf:                               // @_xm_powf
// %bb.0:
	b	powf
.Lrt_func_end62:
	.size	_xm_powf, .Lrt_func_end62-_xm_powf
                                        // -- End function
	.globl	_xm_pow                         // -- Begin function _xm_pow
	.p2align	2
	.type	_xm_pow,@function
_xm_pow:                                // @_xm_pow
// %bb.0:
	b	pow
.Lrt_func_end63:
	.size	_xm_pow, .Lrt_func_end63-_xm_pow
                                        // -- End function
	.globl	_xt_srand                       // -- Begin function _xt_srand
	.p2align	2
	.type	_xt_srand,@function
_xt_srand:                              // @_xt_srand
// %bb.0:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	bl	srandom
	adrp	x8, xt_rand_seeded
	mov	w9, #1                          // =0x1
	strb	w9, [x8, :lo12:xt_rand_seeded]
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
	ret
.Lrt_func_end64:
	.size	_xt_srand, .Lrt_func_end64-_xt_srand
                                        // -- End function
	.globl	_xt_rand_u32                    // -- Begin function _xt_rand_u32
	.p2align	2
	.type	_xt_rand_u32,@function
_xt_rand_u32:                           // @_xt_rand_u32
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	adrp	x19, xt_rand_seeded
	ldrb	w8, [x19, :lo12:xt_rand_seeded]
	tbnz	w8, #0, .Lrt_BB65_2
// %bb.1:
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	bl	srandom
	strb	w20, [x19, :lo12:xt_rand_seeded]
.Lrt_BB65_2:
	bl	random
	mov	x19, x0
	bl	random
	eor	w0, w0, w19, lsl #16
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end65:
	.size	_xt_rand_u32, .Lrt_func_end65-_xt_rand_u32
                                        // -- End function
	.globl	_xt_rand_f                      // -- Begin function _xt_rand_f
	.p2align	2
	.type	_xt_rand_f,@function
_xt_rand_f:                             // @_xt_rand_f
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	adrp	x19, xt_rand_seeded
	ldrb	w8, [x19, :lo12:xt_rand_seeded]
	tbnz	w8, #0, .Lrt_BB66_2
// %bb.1:
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	bl	srandom
	strb	w20, [x19, :lo12:xt_rand_seeded]
.Lrt_BB66_2:
	bl	random
	scvtf	s0, x0, #31
	fmov	s1, #0.50000000
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	fmadd	s0, s0, s1, s1
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end66:
	.size	_xt_rand_f, .Lrt_func_end66-_xt_rand_f
                                        // -- End function
	.globl	_xt_rand_d                      // -- Begin function _xt_rand_d
	.p2align	2
	.type	_xt_rand_d,@function
_xt_rand_d:                             // @_xt_rand_d
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	adrp	x19, xt_rand_seeded
	ldrb	w8, [x19, :lo12:xt_rand_seeded]
	tbnz	w8, #0, .Lrt_BB67_2
// %bb.1:
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	bl	srandom
	strb	w20, [x19, :lo12:xt_rand_seeded]
.Lrt_BB67_2:
	bl	random
	scvtf	d0, x0, #31
	fmov	d1, #0.50000000
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	fmadd	d0, d0, d1, d1
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end67:
	.size	_xt_rand_d, .Lrt_func_end67-_xt_rand_d
                                        // -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          // -- Begin function _xt_clk_reset
.Lrt_CPI68_0:
	.xword	0x3e112e0be826d695              // double 1.0000000000000001E-9
	.text
	.globl	_xt_clk_reset
	.p2align	2
	.type	_xt_clk_reset,@function
_xt_clk_reset:                          // @_xt_clk_reset
// %bb.0:
	sub	sp, sp, #32
	mov	x1, sp
	mov	w0, #1                          // =0x1
	str	x30, [sp, #16]                  // 8-byte Folded Spill
	bl	clock_gettime
	ldp	d0, d1, [sp]
	adrp	x8, .Lrt_CPI68_0
	ldr	d2, [x8, :lo12:.Lrt_CPI68_0]
	adrp	x8, xt_clk_origin
	ldr	x30, [sp, #16]                  // 8-byte Folded Reload
	scvtf	d0, d0
	scvtf	d1, d1
	fmadd	d0, d1, d2, d0
	str	d0, [x8, :lo12:xt_clk_origin]
	add	sp, sp, #32
	ret
.Lrt_func_end68:
	.size	_xt_clk_reset, .Lrt_func_end68-_xt_clk_reset
                                        // -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          // -- Begin function _xt_clk_ticks
.Lrt_CPI69_0:
	.xword	0x3e112e0be826d695              // double 1.0000000000000001E-9
	.text
	.globl	_xt_clk_ticks
	.p2align	2
	.type	_xt_clk_ticks,@function
_xt_clk_ticks:                          // @_xt_clk_ticks
// %bb.0:
	sub	sp, sp, #32
	mov	x1, sp
	mov	w0, #1                          // =0x1
	str	x30, [sp, #16]                  // 8-byte Folded Spill
	bl	clock_gettime
	ldp	d0, d1, [sp]
	adrp	x8, .Lrt_CPI69_0
	ldr	d2, [x8, :lo12:.Lrt_CPI69_0]
	adrp	x8, xt_clk_origin
	ldr	x30, [sp, #16]                  // 8-byte Folded Reload
	scvtf	d0, d0
	scvtf	d1, d1
	fmadd	d0, d1, d2, d0
	ldr	d1, [x8, :lo12:xt_clk_origin]
	mov	x8, #145685290680320            // =0x848000000000
	movk	x8, #16686, lsl #48
	fsub	d0, d0, d1
	fmov	d1, x8
	fmul	d0, d0, d1
	fcvtzu	w0, d0
	add	sp, sp, #32
	ret
.Lrt_func_end69:
	.size	_xt_clk_ticks, .Lrt_func_end69-_xt_clk_ticks
                                        // -- End function
	.globl	_xt_clk_delay                   // -- Begin function _xt_clk_delay
	.p2align	2
	.type	_xt_clk_delay,@function
_xt_clk_delay:                          // @_xt_clk_delay
// %bb.0:
	ucvtf	d0, w0
	mov	x8, #4633641066610819072        // =0x404e000000000000
	fmov	d1, x8
	mov	x8, #225833675390976            // =0xcd6500000000
	movk	x8, #16845, lsl #48
	fmov	d2, x8
	fdiv	d0, d0, d1
	fcvtzs	d1, d0
	fcvtzs	x8, d0
	scvtf	d1, d1
	fsub	d1, d0, d1
	fmul	d1, d1, d2
	fcvtzs	x9, d1
	str	x8, [sp, #-32]!
	mov	x0, sp
	mov	x1, xzr
	stp	x9, x30, [sp, #8]               // 8-byte Folded Spill
	bl	nanosleep
	ldr	x30, [sp, #16]                  // 8-byte Folded Reload
	add	sp, sp, #32
	ret
.Lrt_func_end70:
	.size	_xt_clk_delay, .Lrt_func_end70-_xt_clk_delay
                                        // -- End function
	.globl	_xtc_bank                       // -- Begin function _xtc_bank
	.p2align	2
	.type	_xtc_bank,@function
_xtc_bank:                              // @_xtc_bank
// %bb.0:
                                        // kill: def $w0 killed $w0 def $x0
	and	w8, w0, #0xff
                                        // kill: def $w1 killed $w1 def $x1
	cmp	w8, #1
	b.ls	.Lrt_BB71_2
// %bb.1:
	mov	x0, xzr
	ret
.Lrt_BB71_2:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	and	x8, x0, #0xff
	adrp	x9, _xtc_bank_regions
	add	x9, x9, :lo12:_xtc_bank_regions
	add	x8, x9, x8, lsl #11
	add	x19, x8, w1, uxtb #3
	ldr	x8, [x19]
	cbnz	x8, .Lrt_BB71_4
// %bb.3:
	mov	w0, #1                          // =0x1
	mov	w1, #12288                      // =0x3000
	bl	calloc
	str	x0, [x19]
.Lrt_BB71_4:
	ldr	x0, [x19]
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	ret
.Lrt_func_end71:
	.size	_xtc_bank, .Lrt_func_end71-_xtc_bank
                                        // -- End function
	.globl	_xt_file_open                   // -- Begin function _xt_file_open
	.p2align	2
	.type	_xt_file_open,@function
_xt_file_open:                          // @_xt_file_open
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	mov	x19, xzr
	adrp	x20, xt_files
	add	x20, x20, :lo12:xt_files
.Lrt_BB72_1:                               // =>This Inner Loop Header: Depth=1
	ldr	x8, [x20, x19, lsl #3]
	cbz	x8, .Lrt_BB72_3
// %bb.2:                               //   in Loop: Header=BB72_1 Depth=1
	add	x19, x19, #1
	cmp	x19, #8
	b.ne	.Lrt_BB72_1
	b	.Lrt_BB72_5
.Lrt_BB72_3:
	bl	fopen
	cbz	x0, .Lrt_BB72_5
// %bb.4:
	str	x0, [x20, x19, lsl #3]
	b	.Lrt_BB72_6
.Lrt_BB72_5:
	mov	w19, #-1                        // =0xffffffff
.Lrt_BB72_6:
	mov	w0, w19
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end72:
	.size	_xt_file_open, .Lrt_func_end72-_xt_file_open
                                        // -- End function
	.globl	_xt_file_read                   // -- Begin function _xt_file_read
	.p2align	2
	.type	_xt_file_read,@function
_xt_file_read:                          // @_xt_file_read
// %bb.0:
	cmp	w0, #7
	b.hi	.Lrt_BB73_3
// %bb.1:
	adrp	x8, xt_files
	add	x8, x8, :lo12:xt_files
	ldr	x3, [x8, w0, uxtw #3]
	cbz	x3, .Lrt_BB73_3
// %bb.2:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	mov	w2, w2
	mov	x0, x1
	mov	w1, #1                          // =0x1
	bl	fread
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
                                        // kill: def $w0 killed $w0 killed $x0
	ret
.Lrt_BB73_3:
	mov	w0, #-1                         // =0xffffffff
                                        // kill: def $w0 killed $w0 killed $x0
	ret
.Lrt_func_end73:
	.size	_xt_file_read, .Lrt_func_end73-_xt_file_read
                                        // -- End function
	.globl	_xt_file_write                  // -- Begin function _xt_file_write
	.p2align	2
	.type	_xt_file_write,@function
_xt_file_write:                         // @_xt_file_write
// %bb.0:
	cmp	w0, #7
	b.hi	.Lrt_BB74_3
// %bb.1:
	adrp	x8, xt_files
	add	x8, x8, :lo12:xt_files
	ldr	x3, [x8, w0, uxtw #3]
	cbz	x3, .Lrt_BB74_3
// %bb.2:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	mov	w2, w2
	mov	x0, x1
	mov	w1, #1                          // =0x1
	bl	fwrite
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
                                        // kill: def $w0 killed $w0 killed $x0
	ret
.Lrt_BB74_3:
	mov	w0, #-1                         // =0xffffffff
                                        // kill: def $w0 killed $w0 killed $x0
	ret
.Lrt_func_end74:
	.size	_xt_file_write, .Lrt_func_end74-_xt_file_write
                                        // -- End function
	.globl	_xt_file_close                  // -- Begin function _xt_file_close
	.p2align	2
	.type	_xt_file_close,@function
_xt_file_close:                         // @_xt_file_close
// %bb.0:
	cmp	w0, #7
	b.hi	.Lrt_BB75_4
// %bb.1:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	adrp	x19, xt_files
	add	x19, x19, :lo12:xt_files
	ldr	x8, [x19, w0, uxtw #3]
	cbz	x8, .Lrt_BB75_3
// %bb.2:
	mov	w20, w0
	mov	x0, x8
	bl	fclose
	str	xzr, [x19, w20, uxtw #3]
.Lrt_BB75_3:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
.Lrt_BB75_4:
	ret
.Lrt_func_end75:
	.size	_xt_file_close, .Lrt_func_end75-_xt_file_close
                                        // -- End function
	.globl	_xt_file_size                   // -- Begin function _xt_file_size
	.p2align	2
	.type	_xt_file_size,@function
_xt_file_size:                          // @_xt_file_size
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	adrp	x1, .Lrt_.str.3
	add	x1, x1, :lo12:.Lrt_.str.3
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	bl	fopen
	cbz	x0, .Lrt_BB76_3
// %bb.1:
	mov	x1, xzr
	mov	w2, #2                          // =0x2
	mov	x19, x0
	bl	fseek
	cbz	w0, .Lrt_BB76_4
// %bb.2:
	mov	x0, x19
	bl	fclose
.Lrt_BB76_3:
	mov	w0, #-1                         // =0xffffffff
	b	.Lrt_BB76_5
.Lrt_BB76_4:
	mov	x0, x19
	bl	ftell
	mov	x20, x0
	mov	x0, x19
	bl	fclose
	cmp	x20, #0
	csinv	w0, w20, wzr, ge
.Lrt_BB76_5:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end76:
	.size	_xt_file_size, .Lrt_func_end76-_xt_file_size
                                        // -- End function
	.globl	_xt_file_exists                 // -- Begin function _xt_file_exists
	.p2align	2
	.type	_xt_file_exists,@function
_xt_file_exists:                        // @_xt_file_exists
// %bb.0:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	adrp	x1, .Lrt_.str.3
	add	x1, x1, :lo12:.Lrt_.str.3
	bl	fopen
	cbz	x0, .Lrt_BB77_2
// %bb.1:
	bl	fclose
	mov	w0, #1                          // =0x1
.Lrt_BB77_2:
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
	ret
.Lrt_func_end77:
	.size	_xt_file_exists, .Lrt_func_end77-_xt_file_exists
                                        // -- End function
	.globl	_xt_getenv                      // -- Begin function _xt_getenv
	.p2align	2
	.type	_xt_getenv,@function
_xt_getenv:                             // @_xt_getenv
// %bb.0:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	bl	getenv
	cmp	x0, #0
	adrp	x8, .Lrt_.str.4
	add	x8, x8, :lo12:.Lrt_.str.4
	csel	x0, x8, x0, eq
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
	ret
.Lrt_func_end78:
	.size	_xt_getenv, .Lrt_func_end78-_xt_getenv
                                        // -- End function
	.globl	_xt_mkdir                       // -- Begin function _xt_mkdir
	.p2align	2
	.type	_xt_mkdir,@function
_xt_mkdir:                              // @_xt_mkdir
// %bb.0:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	mov	w1, #448                        // =0x1c0
	bl	mkdir
	cbz	w0, .Lrt_BB79_2
// %bb.1:
	bl	__errno
	ldr	w8, [x0]
	cmp	w8, #17
	cset	w0, eq
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
	ret
.Lrt_BB79_2:
	mov	w0, #1                          // =0x1
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
	ret
.Lrt_func_end79:
	.size	_xt_mkdir, .Lrt_func_end79-_xt_mkdir
                                        // -- End function
	.globl	_xt_file_chmod_exec             // -- Begin function _xt_file_chmod_exec
	.p2align	2
	.type	_xt_file_chmod_exec,@function
_xt_file_chmod_exec:                    // @_xt_file_chmod_exec
// %bb.0:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	mov	w1, #493                        // =0x1ed
	bl	chmod
	cmp	w0, #0
	cset	w0, eq
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
	ret
.Lrt_func_end80:
	.size	_xt_file_chmod_exec, .Lrt_func_end80-_xt_file_chmod_exec
                                        // -- End function
	.globl	_xt_set_args                    // -- Begin function _xt_set_args
	.p2align	2
	.type	_xt_set_args,@function
_xt_set_args:                           // @_xt_set_args
// %bb.0:
	adrp	x8, xt_argc_v
	adrp	x9, xt_argv_v
	str	w0, [x8, :lo12:xt_argc_v]
	str	x1, [x9, :lo12:xt_argv_v]
	ret
.Lrt_func_end81:
	.size	_xt_set_args, .Lrt_func_end81-_xt_set_args
                                        // -- End function
	.globl	_xt_argc                        // -- Begin function _xt_argc
	.p2align	2
	.type	_xt_argc,@function
_xt_argc:                               // @_xt_argc
// %bb.0:
	adrp	x8, xt_argc_v
	ldr	w0, [x8, :lo12:xt_argc_v]
	ret
.Lrt_func_end82:
	.size	_xt_argc, .Lrt_func_end82-_xt_argc
                                        // -- End function
	.globl	_xt_argv                        // -- Begin function _xt_argv
	.p2align	2
	.type	_xt_argv,@function
_xt_argv:                               // @_xt_argv
// %bb.0:
	tbnz	w0, #31, .Lrt_BB83_4
// %bb.1:
	adrp	x9, xt_argc_v
	mov	w8, w0
	ldr	w9, [x9, :lo12:xt_argc_v]
	cmp	w9, w0
	adrp	x0, .Lrt_.str.4
	add	x0, x0, :lo12:.Lrt_.str.4
	b.le	.Lrt_BB83_5
// %bb.2:
	adrp	x9, xt_argv_v
	ldr	x9, [x9, :lo12:xt_argv_v]
	cbz	x9, .Lrt_BB83_5
// %bb.3:
	ldr	x0, [x9, w8, uxtw #3]
	ret
.Lrt_BB83_4:
	adrp	x0, .Lrt_.str.4
	add	x0, x0, :lo12:.Lrt_.str.4
.Lrt_BB83_5:
	ret
.Lrt_func_end83:
	.size	_xt_argv, .Lrt_func_end83-_xt_argv
                                        // -- End function
	.globl	_xt_exit                        // -- Begin function _xt_exit
	.p2align	2
	.type	_xt_exit,@function
_xt_exit:                               // @_xt_exit
// %bb.0:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	mov	w19, w0
	mov	x0, xzr
	bl	fflush
	mov	w0, w19
	bl	_exit
.Lrt_func_end84:
	.size	_xt_exit, .Lrt_func_end84-_xt_exit
                                        // -- End function
	.globl	_xt_file_exists_exact           // -- Begin function _xt_file_exists_exact
	.p2align	2
	.type	_xt_file_exists_exact,@function
_xt_file_exists_exact:                  // @_xt_file_exists_exact
// %bb.0:
	str	x29, [sp, #-64]!                // 8-byte Folded Spill
	stp	x30, x23, [sp, #16]             // 16-byte Folded Spill
	stp	x22, x21, [sp, #32]             // 16-byte Folded Spill
	stp	x20, x19, [sp, #48]             // 16-byte Folded Spill
	sub	sp, sp, #1024
	mov	w1, #47                         // =0x2f
	mov	x20, x0
	bl	strrchr
	cmp	x0, #0
	csinc	x19, x20, x0, eq
	cbz	x0, .Lrt_BB85_4
// %bb.1:
	sub	x21, x0, x20
	cmp	x21, #1023
	b.hi	.Lrt_BB85_11
// %bb.2:
	mov	x22, x0
	mov	x0, sp
	mov	x1, x20
	mov	x2, x21
	mov	x23, sp
	bl	memcpy
	cmp	x22, x20
	strb	wzr, [x23, x21]
	b.ne	.Lrt_BB85_6
// %bb.3:
	mov	w8, #47                         // =0x2f
	b	.Lrt_BB85_5
.Lrt_BB85_4:
	mov	w8, #46                         // =0x2e
.Lrt_BB85_5:
	strb	w8, [sp]
	strb	wzr, [sp, #1]
.Lrt_BB85_6:
	mov	x0, sp
	bl	opendir
	cbz	x0, .Lrt_BB85_11
// %bb.7:
	mov	x20, x0
.Lrt_BB85_8:                               // =>This Inner Loop Header: Depth=1
	mov	x0, x20
	bl	readdir
	cbz	x0, .Lrt_BB85_12
// %bb.9:                               //   in Loop: Header=BB85_8 Depth=1
	add	x0, x0, #19
	mov	x1, x19
	bl	strcmp
	cbnz	w0, .Lrt_BB85_8
// %bb.10:
	mov	w19, #1                         // =0x1
	b	.Lrt_BB85_13
.Lrt_BB85_11:
	mov	w19, wzr
	b	.Lrt_BB85_14
.Lrt_BB85_12:
	mov	w19, wzr
.Lrt_BB85_13:
	mov	x0, x20
	bl	closedir
.Lrt_BB85_14:
	mov	w0, w19
	add	sp, sp, #1024
	ldp	x20, x19, [sp, #48]             // 16-byte Folded Reload
	ldp	x22, x21, [sp, #32]             // 16-byte Folded Reload
	ldp	x30, x23, [sp, #16]             // 16-byte Folded Reload
	ldr	x29, [sp], #64                  // 8-byte Folded Reload
	ret
.Lrt_func_end85:
	.size	_xt_file_exists_exact, .Lrt_func_end85-_xt_file_exists_exact
                                        // -- End function
	.globl	_xt_threads_multi               // -- Begin function _xt_threads_multi
	.p2align	2
	.type	_xt_threads_multi,@function
_xt_threads_multi:                      // @_xt_threads_multi
// %bb.0:
	adrp	x8, _xt_threads_active
	ldr	w0, [x8, :lo12:_xt_threads_active]
	ret
.Lrt_func_end86:
	.size	_xt_threads_multi, .Lrt_func_end86-_xt_threads_multi
                                        // -- End function
	.globl	_xt_thread_create               // -- Begin function _xt_thread_create
	.p2align	2
	.type	_xt_thread_create,@function
_xt_thread_create:                      // @_xt_thread_create
// %bb.0:
	cbz	x0, .Lrt_BB87_11
// %bb.1:
	stp	x30, x21, [sp, #-32]!           // 16-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	adrp	x19, _xt_threads_active
	mov	x20, x0
	ldr	w8, [x19, :lo12:_xt_threads_active]
	mov	x21, x1
	cbnz	w8, .Lrt_BB87_3
// %bb.2:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	mov	x1, xzr
	bl	pthread_mutex_init
	mov	w8, #1                          // =0x1
	str	w8, [x19, :lo12:_xt_threads_active]
.Lrt_BB87_3:
	mov	w0, #16                         // =0x10
	bl	malloc
	cbz	x0, .Lrt_BB87_10
// %bb.4:
	mov	x19, x0
	stp	x20, x21, [x0]
	mov	w0, #8                          // =0x8
	bl	malloc
	cbz	x0, .Lrt_BB87_7
// %bb.5:
	adrp	x2, xt_thread_entry
	add	x2, x2, :lo12:xt_thread_entry
	mov	x1, xzr
	mov	x3, x19
	mov	x20, x0
	bl	pthread_create
	cbz	w0, .Lrt_BB87_9
// %bb.6:
	mov	x0, x19
	bl	free
	mov	x0, x20
	b	.Lrt_BB87_8
.Lrt_BB87_7:
	mov	x0, x19
.Lrt_BB87_8:
	bl	free
	mov	x0, xzr
	b	.Lrt_BB87_10
.Lrt_BB87_9:
	mov	x0, x20
.Lrt_BB87_10:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldp	x30, x21, [sp], #32             // 16-byte Folded Reload
.Lrt_BB87_11:
	ret
.Lrt_func_end87:
	.size	_xt_thread_create, .Lrt_func_end87-_xt_thread_create
                                        // -- End function
	.p2align	2                               // -- Begin function xt_thread_entry
	.type	xt_thread_entry,@function
xt_thread_entry:                        // @xt_thread_entry
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	ldp	x20, x19, [x0]
	bl	free
	cbz	x20, .Lrt_BB88_2
// %bb.1:
	mov	x0, x19
	blr	x20
.Lrt_BB88_2:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	mov	x0, xzr
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end88:
	.size	xt_thread_entry, .Lrt_func_end88-xt_thread_entry
                                        // -- End function
	.globl	_xt_thread_join                 // -- Begin function _xt_thread_join
	.p2align	2
	.type	_xt_thread_join,@function
_xt_thread_join:                        // @_xt_thread_join
// %bb.0:
	cbz	x0, .Lrt_BB89_2
// %bb.1:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	ldr	x8, [x0]
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	add	x1, sp, #8
	mov	x19, x0
	str	xzr, [sp, #8]
	mov	x0, x8
	bl	pthread_join
	mov	w20, w0
	mov	x0, x19
	bl	free
	cmp	w20, #0
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	csetm	w0, ne
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_BB89_2:
	mov	w0, #-1                         // =0xffffffff
	ret
.Lrt_func_end89:
	.size	_xt_thread_join, .Lrt_func_end89-_xt_thread_join
                                        // -- End function
	.globl	_xt_thread_detach               // -- Begin function _xt_thread_detach
	.p2align	2
	.type	_xt_thread_detach,@function
_xt_thread_detach:                      // @_xt_thread_detach
// %bb.0:
	cbz	x0, .Lrt_BB90_2
// %bb.1:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	ldr	x8, [x0]
	mov	x19, x0
	mov	x0, x8
	bl	pthread_detach
	mov	x0, x19
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	b	free
.Lrt_BB90_2:
	ret
.Lrt_func_end90:
	.size	_xt_thread_detach, .Lrt_func_end90-_xt_thread_detach
                                        // -- End function
	.globl	_xt_thread_yield                // -- Begin function _xt_thread_yield
	.p2align	2
	.type	_xt_thread_yield,@function
_xt_thread_yield:                       // @_xt_thread_yield
// %bb.0:
	b	sched_yield
.Lrt_func_end91:
	.size	_xt_thread_yield, .Lrt_func_end91-_xt_thread_yield
                                        // -- End function
	.globl	_xt_thread_sleep_ms             // -- Begin function _xt_thread_sleep_ms
	.p2align	2
	.type	_xt_thread_sleep_ms,@function
_xt_thread_sleep_ms:                    // @_xt_thread_sleep_ms
// %bb.0:
	mov	w8, #19923                      // =0x4dd3
	mov	w9, #1000                       // =0x3e8
	mov	w10, #16960                     // =0x4240
	movk	w8, #4194, lsl #16
	movk	w10, #15, lsl #16
	umull	x8, w0, w8
	lsr	x8, x8, #38
	msub	w9, w8, w9, w0
	mul	w9, w9, w10
	str	x8, [sp, #-32]!
	mov	x0, sp
	mov	x1, xzr
	stp	x9, x30, [sp, #8]               // 8-byte Folded Spill
	bl	nanosleep
	ldr	x30, [sp, #16]                  // 8-byte Folded Reload
	add	sp, sp, #32
	ret
.Lrt_func_end92:
	.size	_xt_thread_sleep_ms, .Lrt_func_end92-_xt_thread_sleep_ms
                                        // -- End function
	.globl	_xt_thread_self_id              // -- Begin function _xt_thread_self_id
	.p2align	2
	.type	_xt_thread_self_id,@function
_xt_thread_self_id:                     // @_xt_thread_self_id
// %bb.0:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	bl	pthread_self
	lsr	x8, x0, #4
	lsr	x9, x0, #32
	eor	w0, w8, w9
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
	ret
.Lrt_func_end93:
	.size	_xt_thread_self_id, .Lrt_func_end93-_xt_thread_self_id
                                        // -- End function
	.globl	_xt_thread_cpu_count            // -- Begin function _xt_thread_cpu_count
	.p2align	2
	.type	_xt_thread_cpu_count,@function
_xt_thread_cpu_count:                   // @_xt_thread_cpu_count
// %bb.0:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	mov	w0, #97                         // =0x61
	bl	sysconf
	cmp	x0, #0
	csinc	w0, w0, wzr, gt
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
	ret
.Lrt_func_end94:
	.size	_xt_thread_cpu_count, .Lrt_func_end94-_xt_thread_cpu_count
                                        // -- End function
	.globl	_xt_mutex_new                   // -- Begin function _xt_mutex_new
	.p2align	2
	.type	_xt_mutex_new,@function
_xt_mutex_new:                          // @_xt_mutex_new
// %bb.0:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	mov	w0, #40                         // =0x28
	bl	malloc
	cbz	x0, .Lrt_BB95_3
// %bb.1:
	mov	x1, xzr
	mov	x19, x0
	bl	pthread_mutex_init
	cbz	w0, .Lrt_BB95_4
// %bb.2:
	mov	x0, x19
	bl	free
	mov	x0, xzr
.Lrt_BB95_3:
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	ret
.Lrt_BB95_4:
	mov	x0, x19
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	ret
.Lrt_func_end95:
	.size	_xt_mutex_new, .Lrt_func_end95-_xt_mutex_new
                                        // -- End function
	.globl	_xt_mutex_free                  // -- Begin function _xt_mutex_free
	.p2align	2
	.type	_xt_mutex_free,@function
_xt_mutex_free:                         // @_xt_mutex_free
// %bb.0:
	cbz	x0, .Lrt_BB96_2
// %bb.1:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	mov	x19, x0
	bl	pthread_mutex_destroy
	mov	x0, x19
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	b	free
.Lrt_BB96_2:
	ret
.Lrt_func_end96:
	.size	_xt_mutex_free, .Lrt_func_end96-_xt_mutex_free
                                        // -- End function
	.globl	_xt_mutex_lock                  // -- Begin function _xt_mutex_lock
	.p2align	2
	.type	_xt_mutex_lock,@function
_xt_mutex_lock:                         // @_xt_mutex_lock
// %bb.0:
	cbz	x0, .Lrt_BB97_2
// %bb.1:
	b	pthread_mutex_lock
.Lrt_BB97_2:
	ret
.Lrt_func_end97:
	.size	_xt_mutex_lock, .Lrt_func_end97-_xt_mutex_lock
                                        // -- End function
	.globl	_xt_mutex_unlock                // -- Begin function _xt_mutex_unlock
	.p2align	2
	.type	_xt_mutex_unlock,@function
_xt_mutex_unlock:                       // @_xt_mutex_unlock
// %bb.0:
	cbz	x0, .Lrt_BB98_2
// %bb.1:
	b	pthread_mutex_unlock
.Lrt_BB98_2:
	ret
.Lrt_func_end98:
	.size	_xt_mutex_unlock, .Lrt_func_end98-_xt_mutex_unlock
                                        // -- End function
	.globl	_xt_mutex_trylock               // -- Begin function _xt_mutex_trylock
	.p2align	2
	.type	_xt_mutex_trylock,@function
_xt_mutex_trylock:                      // @_xt_mutex_trylock
// %bb.0:
	cbz	x0, .Lrt_BB99_2
// %bb.1:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	bl	pthread_mutex_trylock
	cmp	w0, #0
	cset	w0, eq
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
.Lrt_BB99_2:
	ret
.Lrt_func_end99:
	.size	_xt_mutex_trylock, .Lrt_func_end99-_xt_mutex_trylock
                                        // -- End function
	.globl	_xt_cond_new                    // -- Begin function _xt_cond_new
	.p2align	2
	.type	_xt_cond_new,@function
_xt_cond_new:                           // @_xt_cond_new
// %bb.0:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	mov	w0, #48                         // =0x30
	bl	malloc
	cbz	x0, .Lrt_BB100_3
// %bb.1:
	mov	x1, xzr
	mov	x19, x0
	bl	pthread_cond_init
	cbz	w0, .Lrt_BB100_4
// %bb.2:
	mov	x0, x19
	bl	free
	mov	x0, xzr
.Lrt_BB100_3:
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	ret
.Lrt_BB100_4:
	mov	x0, x19
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	ret
.Lrt_func_end100:
	.size	_xt_cond_new, .Lrt_func_end100-_xt_cond_new
                                        // -- End function
	.globl	_xt_cond_free                   // -- Begin function _xt_cond_free
	.p2align	2
	.type	_xt_cond_free,@function
_xt_cond_free:                          // @_xt_cond_free
// %bb.0:
	cbz	x0, .Lrt_BB101_2
// %bb.1:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	mov	x19, x0
	bl	pthread_cond_destroy
	mov	x0, x19
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	b	free
.Lrt_BB101_2:
	ret
.Lrt_func_end101:
	.size	_xt_cond_free, .Lrt_func_end101-_xt_cond_free
                                        // -- End function
	.globl	_xt_cond_wait                   // -- Begin function _xt_cond_wait
	.p2align	2
	.type	_xt_cond_wait,@function
_xt_cond_wait:                          // @_xt_cond_wait
// %bb.0:
	cbz	x0, .Lrt_BB102_3
// %bb.1:
	cbz	x1, .Lrt_BB102_3
// %bb.2:
	b	pthread_cond_wait
.Lrt_BB102_3:
	ret
.Lrt_func_end102:
	.size	_xt_cond_wait, .Lrt_func_end102-_xt_cond_wait
                                        // -- End function
	.globl	_xt_cond_signal                 // -- Begin function _xt_cond_signal
	.p2align	2
	.type	_xt_cond_signal,@function
_xt_cond_signal:                        // @_xt_cond_signal
// %bb.0:
	cbz	x0, .Lrt_BB103_2
// %bb.1:
	b	pthread_cond_signal
.Lrt_BB103_2:
	ret
.Lrt_func_end103:
	.size	_xt_cond_signal, .Lrt_func_end103-_xt_cond_signal
                                        // -- End function
	.globl	_xt_cond_broadcast              // -- Begin function _xt_cond_broadcast
	.p2align	2
	.type	_xt_cond_broadcast,@function
_xt_cond_broadcast:                     // @_xt_cond_broadcast
// %bb.0:
	cbz	x0, .Lrt_BB104_2
// %bb.1:
	b	pthread_cond_broadcast
.Lrt_BB104_2:
	ret
.Lrt_func_end104:
	.size	_xt_cond_broadcast, .Lrt_func_end104-_xt_cond_broadcast
                                        // -- End function
	.globl	_xt_sem_new                     // -- Begin function _xt_sem_new
	.p2align	2
	.type	_xt_sem_new,@function
_xt_sem_new:                            // @_xt_sem_new
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	mov	w19, w0
	mov	w0, #92                         // =0x5c
	bl	malloc
	cbz	x0, .Lrt_BB105_5
// %bb.1:
	mov	x1, xzr
	mov	x20, x0
	bl	pthread_mutex_init
	cbnz	w0, .Lrt_BB105_4
// %bb.2:
	add	x0, x20, #40
	mov	x1, xzr
	bl	pthread_cond_init
	cbz	w0, .Lrt_BB105_6
// %bb.3:
	mov	x0, x20
	bl	pthread_mutex_destroy
.Lrt_BB105_4:
	mov	x0, x20
	bl	free
	mov	x0, xzr
.Lrt_BB105_5:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_BB105_6:
	bic	w8, w19, w19, asr #31
	mov	x0, x20
	str	w8, [x20, #88]
	b	.Lrt_BB105_5
.Lrt_func_end105:
	.size	_xt_sem_new, .Lrt_func_end105-_xt_sem_new
                                        // -- End function
	.globl	_xt_sem_free                    // -- Begin function _xt_sem_free
	.p2align	2
	.type	_xt_sem_free,@function
_xt_sem_free:                           // @_xt_sem_free
// %bb.0:
	cbz	x0, .Lrt_BB106_2
// %bb.1:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	mov	x19, x0
	add	x0, x0, #40
	bl	pthread_cond_destroy
	mov	x0, x19
	bl	pthread_mutex_destroy
	mov	x0, x19
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	b	free
.Lrt_BB106_2:
	ret
.Lrt_func_end106:
	.size	_xt_sem_free, .Lrt_func_end106-_xt_sem_free
                                        // -- End function
	.globl	_xt_sem_wait                    // -- Begin function _xt_sem_wait
	.p2align	2
	.type	_xt_sem_wait,@function
_xt_sem_wait:                           // @_xt_sem_wait
// %bb.0:
	cbz	x0, .Lrt_BB107_4
// %bb.1:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	mov	x19, x0
	bl	pthread_mutex_lock
	ldr	w8, [x19, #88]
	cmp	w8, #0
	b.gt	.Lrt_BB107_3
.Lrt_BB107_2:                              // =>This Inner Loop Header: Depth=1
	add	x0, x19, #40
	mov	x1, x19
	bl	pthread_cond_wait
	ldr	w8, [x19, #88]
	cmp	w8, #1
	b.lt	.Lrt_BB107_2
.Lrt_BB107_3:
	sub	w8, w8, #1
	mov	x0, x19
	str	w8, [x19, #88]
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	b	pthread_mutex_unlock
.Lrt_BB107_4:
	ret
.Lrt_func_end107:
	.size	_xt_sem_wait, .Lrt_func_end107-_xt_sem_wait
                                        // -- End function
	.globl	_xt_sem_trywait                 // -- Begin function _xt_sem_trywait
	.p2align	2
	.type	_xt_sem_trywait,@function
_xt_sem_trywait:                        // @_xt_sem_trywait
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	cbz	x0, .Lrt_BB108_3
// %bb.1:
	mov	x19, x0
	bl	pthread_mutex_lock
	ldr	w8, [x19, #88]
	subs	w8, w8, #1
	b.lt	.Lrt_BB108_4
// %bb.2:
	mov	w20, #1                         // =0x1
	str	w8, [x19, #88]
	b	.Lrt_BB108_5
.Lrt_BB108_3:
	mov	w20, wzr
	b	.Lrt_BB108_6
.Lrt_BB108_4:
	mov	w20, wzr
.Lrt_BB108_5:
	mov	x0, x19
	bl	pthread_mutex_unlock
.Lrt_BB108_6:
	mov	w0, w20
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end108:
	.size	_xt_sem_trywait, .Lrt_func_end108-_xt_sem_trywait
                                        // -- End function
	.globl	_xt_sem_post                    // -- Begin function _xt_sem_post
	.p2align	2
	.type	_xt_sem_post,@function
_xt_sem_post:                           // @_xt_sem_post
// %bb.0:
	cbz	x0, .Lrt_BB109_2
// %bb.1:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	mov	x19, x0
	bl	pthread_mutex_lock
	ldr	w8, [x19, #88]
	add	x0, x19, #40
	add	w8, w8, #1
	str	w8, [x19, #88]
	bl	pthread_cond_signal
	mov	x0, x19
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	b	pthread_mutex_unlock
.Lrt_BB109_2:
	ret
.Lrt_func_end109:
	.size	_xt_sem_post, .Lrt_func_end109-_xt_sem_post
                                        // -- End function
	.globl	_xt_tls_new                     // -- Begin function _xt_tls_new
	.p2align	2
	.type	_xt_tls_new,@function
_xt_tls_new:                            // @_xt_tls_new
// %bb.0:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	add	x0, sp, #12
	mov	x1, xzr
	bl	pthread_key_create
	ldr	w8, [sp, #12]
	cmp	w0, #0
	csinv	w0, w8, wzr, eq
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
	ret
.Lrt_func_end110:
	.size	_xt_tls_new, .Lrt_func_end110-_xt_tls_new
                                        // -- End function
	.globl	_xt_tls_set                     // -- Begin function _xt_tls_set
	.p2align	2
	.type	_xt_tls_set,@function
_xt_tls_set:                            // @_xt_tls_set
// %bb.0:
	cmn	w0, #1
	b.eq	.Lrt_BB111_2
// %bb.1:
	b	pthread_setspecific
.Lrt_BB111_2:
	ret
.Lrt_func_end111:
	.size	_xt_tls_set, .Lrt_func_end111-_xt_tls_set
                                        // -- End function
	.globl	_xt_tls_get                     // -- Begin function _xt_tls_get
	.p2align	2
	.type	_xt_tls_get,@function
_xt_tls_get:                            // @_xt_tls_get
// %bb.0:
	cmn	w0, #1
	b.eq	.Lrt_BB112_2
// %bb.1:
	b	pthread_getspecific
.Lrt_BB112_2:
	mov	x0, xzr
	ret
.Lrt_func_end112:
	.size	_xt_tls_get, .Lrt_func_end112-_xt_tls_get
                                        // -- End function
	.globl	_xt_atomic_load_i32             // -- Begin function _xt_atomic_load_i32
	.p2align	2
	.type	_xt_atomic_load_i32,@function
_xt_atomic_load_i32:                    // @_xt_atomic_load_i32
// %bb.0:
	cbz	x0, .Lrt_BB113_2
// %bb.1:
	ldar	w0, [x0]
.Lrt_BB113_2:
	ret
.Lrt_func_end113:
	.size	_xt_atomic_load_i32, .Lrt_func_end113-_xt_atomic_load_i32
                                        // -- End function
	.globl	_xt_atomic_store_i32            // -- Begin function _xt_atomic_store_i32
	.p2align	2
	.type	_xt_atomic_store_i32,@function
_xt_atomic_store_i32:                   // @_xt_atomic_store_i32
// %bb.0:
	cbz	x0, .Lrt_BB114_2
// %bb.1:
	stlr	w1, [x0]
.Lrt_BB114_2:
	ret
.Lrt_func_end114:
	.size	_xt_atomic_store_i32, .Lrt_func_end114-_xt_atomic_store_i32
                                        // -- End function
	.globl	_xt_atomic_add_i32              // -- Begin function _xt_atomic_add_i32
	.p2align	2
	.type	_xt_atomic_add_i32,@function
_xt_atomic_add_i32:                     // @_xt_atomic_add_i32
// %bb.0:
	cbz	x0, .Lrt_BB115_3
.Lrt_BB115_1:                              // =>This Inner Loop Header: Depth=1
	ldaxr	w8, [x0]
	add	w8, w8, w1
	stlxr	w9, w8, [x0]
	cbnz	w9, .Lrt_BB115_1
// %bb.2:
	mov	w0, w8
	ret
.Lrt_BB115_3:
	mov	w0, wzr
	ret
.Lrt_func_end115:
	.size	_xt_atomic_add_i32, .Lrt_func_end115-_xt_atomic_add_i32
                                        // -- End function
	.globl	_xt_atomic_xchg_i32             // -- Begin function _xt_atomic_xchg_i32
	.p2align	2
	.type	_xt_atomic_xchg_i32,@function
_xt_atomic_xchg_i32:                    // @_xt_atomic_xchg_i32
// %bb.0:
	cbz	x0, .Lrt_BB116_3
// %bb.1:
	mov	x8, x0
.Lrt_BB116_2:                              // =>This Inner Loop Header: Depth=1
	ldaxr	w0, [x8]
	stlxr	w9, w1, [x8]
	cbnz	w9, .Lrt_BB116_2
.Lrt_BB116_3:
                                        // kill: def $w0 killed $w0 killed $x0
	ret
.Lrt_func_end116:
	.size	_xt_atomic_xchg_i32, .Lrt_func_end116-_xt_atomic_xchg_i32
                                        // -- End function
	.globl	_xt_atomic_cas_i32              // -- Begin function _xt_atomic_cas_i32
	.p2align	2
	.type	_xt_atomic_cas_i32,@function
_xt_atomic_cas_i32:                     // @_xt_atomic_cas_i32
// %bb.0:
	cbz	x0, .Lrt_BB117_5
.Lrt_BB117_1:                              // =>This Inner Loop Header: Depth=1
	ldaxr	w8, [x0]
	cmp	w8, w1
	b.ne	.Lrt_BB117_4
// %bb.2:                               //   in Loop: Header=BB117_1 Depth=1
	stlxr	w8, w2, [x0]
	cbnz	w8, .Lrt_BB117_1
// %bb.3:
	mov	w0, #1                          // =0x1
	ret
.Lrt_BB117_4:
	mov	w0, wzr
	clrex
.Lrt_BB117_5:
	ret
.Lrt_func_end117:
	.size	_xt_atomic_cas_i32, .Lrt_func_end117-_xt_atomic_cas_i32
                                        // -- End function
	.globl	_xt_atomic_load_ptr             // -- Begin function _xt_atomic_load_ptr
	.p2align	2
	.type	_xt_atomic_load_ptr,@function
_xt_atomic_load_ptr:                    // @_xt_atomic_load_ptr
// %bb.0:
	cbz	x0, .Lrt_BB118_2
// %bb.1:
	ldar	x0, [x0]
.Lrt_BB118_2:
	ret
.Lrt_func_end118:
	.size	_xt_atomic_load_ptr, .Lrt_func_end118-_xt_atomic_load_ptr
                                        // -- End function
	.globl	_xt_atomic_store_ptr            // -- Begin function _xt_atomic_store_ptr
	.p2align	2
	.type	_xt_atomic_store_ptr,@function
_xt_atomic_store_ptr:                   // @_xt_atomic_store_ptr
// %bb.0:
	cbz	x0, .Lrt_BB119_2
// %bb.1:
	stlr	x1, [x0]
.Lrt_BB119_2:
	ret
.Lrt_func_end119:
	.size	_xt_atomic_store_ptr, .Lrt_func_end119-_xt_atomic_store_ptr
                                        // -- End function
	.globl	_xt_atomic_cas_ptr              // -- Begin function _xt_atomic_cas_ptr
	.p2align	2
	.type	_xt_atomic_cas_ptr,@function
_xt_atomic_cas_ptr:                     // @_xt_atomic_cas_ptr
// %bb.0:
	cbz	x0, .Lrt_BB120_5
.Lrt_BB120_1:                              // =>This Inner Loop Header: Depth=1
	ldaxr	x8, [x0]
	cmp	x8, x1
	b.ne	.Lrt_BB120_4
// %bb.2:                               //   in Loop: Header=BB120_1 Depth=1
	stlxr	w8, x2, [x0]
	cbnz	w8, .Lrt_BB120_1
// %bb.3:
	mov	w0, #1                          // =0x1
	ret
.Lrt_BB120_4:
	mov	w0, wzr
	clrex
.Lrt_BB120_5:
	ret
.Lrt_func_end120:
	.size	_xt_atomic_cas_ptr, .Lrt_func_end120-_xt_atomic_cas_ptr
                                        // -- End function
	.globl	_xtc_sinit_run                  // -- Begin function _xtc_sinit_run
	.p2align	2
	.type	_xtc_sinit_run,@function
_xtc_sinit_run:                         // @_xtc_sinit_run
// %bb.0:
	str	x30, [sp, #-96]!                // 8-byte Folded Spill
	stp	x28, x27, [sp, #16]             // 16-byte Folded Spill
	stp	x26, x25, [sp, #32]             // 16-byte Folded Spill
	stp	x24, x23, [sp, #48]             // 16-byte Folded Spill
	stp	x22, x21, [sp, #64]             // 16-byte Folded Spill
	stp	x20, x19, [sp, #80]             // 16-byte Folded Spill
	cbz	x0, .Lrt_BB121_35
// %bb.1:
	mov	x20, x2
	mov	x19, x0
	mov	x21, x1
	adrp	x23, _xt_threads_active
	adrp	x25, xt_sinit_flag
	add	x25, x25, :lo12:xt_sinit_flag
	mov	w26, #1                         // =0x1
	adrp	x27, xt_sinit_owner
	add	x27, x27, :lo12:xt_sinit_owner
	adrp	x24, xt_sinit_n
	adrp	x22, xt_rt_mtx
	add	x22, x22, :lo12:xt_rt_mtx
	b	.Lrt_BB121_4
.Lrt_BB121_2:                              //   in Loop: Header=BB121_4 Depth=1
	mov	w8, #1                          // =0x1
.Lrt_BB121_3:                              //   in Loop: Header=BB121_4 Depth=1
	cbnz	w8, .Lrt_BB121_23
.Lrt_BB121_4:                              // =>This Loop Header: Depth=1
                                        //     Child Loop BB121_17 Depth 2
	ldr	w8, [x23, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB121_6
// %bb.5:                               //   in Loop: Header=BB121_4 Depth=1
	mov	x0, x22
	bl	pthread_mutex_lock
.Lrt_BB121_6:                              //   in Loop: Header=BB121_4 Depth=1
	ldrb	w8, [x19]
	cbz	w8, .Lrt_BB121_10
// %bb.7:                               //   in Loop: Header=BB121_4 Depth=1
	cmp	w8, #2
	b.ne	.Lrt_BB121_14
.Lrt_BB121_8:                              //   in Loop: Header=BB121_4 Depth=1
	ldr	w8, [x23, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB121_2
// %bb.9:                               //   in Loop: Header=BB121_4 Depth=1
	mov	x0, x22
	bl	pthread_mutex_unlock
	b	.Lrt_BB121_2
.Lrt_BB121_10:                             //   in Loop: Header=BB121_4 Depth=1
	strb	w26, [x19]
	ldrsw	x28, [x24, :lo12:xt_sinit_n]
	cmp	w28, #31
	b.gt	.Lrt_BB121_12
// %bb.11:                              //   in Loop: Header=BB121_4 Depth=1
	str	x19, [x25, x28, lsl #3]
	bl	pthread_self
	lsr	x9, x0, #4
	lsr	x10, x0, #32
	add	w8, w28, #1
	str	w8, [x24, :lo12:xt_sinit_n]
	eor	w9, w9, w10
	str	w9, [x27, x28, lsl #2]
.Lrt_BB121_12:                             //   in Loop: Header=BB121_4 Depth=1
	ldr	w8, [x23, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB121_22
// %bb.13:                              //   in Loop: Header=BB121_4 Depth=1
	mov	x0, x22
	bl	pthread_mutex_unlock
	mov	w8, #2                          // =0x2
	b	.Lrt_BB121_3
.Lrt_BB121_14:                             //   in Loop: Header=BB121_4 Depth=1
	bl	pthread_self
	ldr	w8, [x24, :lo12:xt_sinit_n]
	cmp	w8, #1
	b.lt	.Lrt_BB121_19
// %bb.15:                              //   in Loop: Header=BB121_4 Depth=1
	lsr	x9, x0, #4
	lsr	x10, x0, #32
	mov	x11, x27
	eor	w9, w9, w10
	mov	x10, x25
	b	.Lrt_BB121_17
.Lrt_BB121_16:                             //   in Loop: Header=BB121_17 Depth=2
	subs	x8, x8, #1
	add	x11, x11, #4
	add	x10, x10, #8
	b.eq	.Lrt_BB121_19
.Lrt_BB121_17:                             //   Parent Loop BB121_4 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldr	x12, [x10]
	cmp	x12, x19
	b.ne	.Lrt_BB121_16
// %bb.18:                              //   in Loop: Header=BB121_17 Depth=2
	ldr	w12, [x11]
	cmp	w12, w9
	b.ne	.Lrt_BB121_16
	b	.Lrt_BB121_8
.Lrt_BB121_19:                             //   in Loop: Header=BB121_4 Depth=1
	ldr	w8, [x23, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB121_21
// %bb.20:                              //   in Loop: Header=BB121_4 Depth=1
	mov	x0, x22
	bl	pthread_mutex_unlock
.Lrt_BB121_21:                             //   in Loop: Header=BB121_4 Depth=1
	bl	sched_yield
	mov	w8, wzr
	b	.Lrt_BB121_3
.Lrt_BB121_22:                             //   in Loop: Header=BB121_4 Depth=1
	mov	w8, #2                          // =0x2
	b	.Lrt_BB121_3
.Lrt_BB121_23:
	cmp	w8, #1
	b.eq	.Lrt_BB121_35
// %bb.24:
	cbz	x21, .Lrt_BB121_26
// %bb.25:
	mov	x0, x20
	blr	x21
.Lrt_BB121_26:
	ldr	w8, [x23, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB121_28
// %bb.27:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB121_28:
	mov	w8, #2                          // =0x2
	strb	w8, [x19]
	ldr	w8, [x24, :lo12:xt_sinit_n]
	cmp	w8, #1
	b.lt	.Lrt_BB121_32
// %bb.29:
	adrp	x9, xt_sinit_owner
	add	x9, x9, :lo12:xt_sinit_owner
	adrp	x12, xt_sinit_flag
	add	x12, x12, :lo12:xt_sinit_flag
	mov	x13, x8
	mov	x11, x9
	mov	x10, x12
.Lrt_BB121_30:                             // =>This Inner Loop Header: Depth=1
	ldr	x14, [x10]
	cmp	x14, x19
	b.eq	.Lrt_BB121_34
// %bb.31:                              //   in Loop: Header=BB121_30 Depth=1
	subs	x13, x13, #1
	add	x11, x11, #4
	add	x10, x10, #8
	b.ne	.Lrt_BB121_30
.Lrt_BB121_32:
	ldr	w8, [x23, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB121_35
.Lrt_BB121_33:
	ldp	x20, x19, [sp, #80]             // 16-byte Folded Reload
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	ldp	x22, x21, [sp, #64]             // 16-byte Folded Reload
	ldp	x24, x23, [sp, #48]             // 16-byte Folded Reload
	ldp	x26, x25, [sp, #32]             // 16-byte Folded Reload
	ldp	x28, x27, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #96                  // 8-byte Folded Reload
	b	pthread_mutex_unlock
.Lrt_BB121_34:
	sxtw	x8, w8
	sub	x8, x8, #1
	ldr	x12, [x12, x8, lsl #3]
	str	w8, [x24, :lo12:xt_sinit_n]
	ldr	w8, [x9, x8, lsl #2]
	str	x12, [x10]
	str	w8, [x11]
	ldr	w8, [x23, :lo12:_xt_threads_active]
	cbnz	w8, .Lrt_BB121_33
.Lrt_BB121_35:
	ldp	x20, x19, [sp, #80]             // 16-byte Folded Reload
	ldp	x22, x21, [sp, #64]             // 16-byte Folded Reload
	ldp	x24, x23, [sp, #48]             // 16-byte Folded Reload
	ldp	x26, x25, [sp, #32]             // 16-byte Folded Reload
	ldp	x28, x27, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #96                  // 8-byte Folded Reload
	ret
.Lrt_func_end121:
	.size	_xtc_sinit_run, .Lrt_func_end121-_xtc_sinit_run
                                        // -- End function
	.globl	_xt_thread_exiting              // -- Begin function _xt_thread_exiting
	.p2align	2
	.type	_xt_thread_exiting,@function
_xt_thread_exiting:                     // @_xt_thread_exiting
// %bb.0:
	ret
.Lrt_func_end122:
	.size	_xt_thread_exiting, .Lrt_func_end122-_xt_thread_exiting
                                        // -- End function
	.type	.Lrt_.str,@object                  // @.str
	.section	.rodata.str1.1,"aMS",@progbits,1
.Lrt_.str:
	.asciz	"xcc: out of memory allocating %lu x %lu bytes\n"
	.size	.Lrt_.str, 47

	.type	xt_simd_tab,@object             // @xt_simd_tab
	.local	xt_simd_tab
	.comm	xt_simd_tab,8,8
	.type	xt_simd_installed,@object       // @xt_simd_installed
	.local	xt_simd_installed
	.comm	xt_simd_installed,1,4
	.type	xt_simd_old,@object             // @xt_simd_old
	.local	xt_simd_old
	.comm	xt_simd_old,64,8
	.type	xt_simd_flag,@object            // @xt_simd_flag
	.local	xt_simd_flag
	.comm	xt_simd_flag,8,8
	.type	.Lrt_.str.1,@object                // @.str.1
.Lrt_.str.1:
	.asciz	"%.6f"
	.size	.Lrt_.str.1, 5

	.type	.Lrt_.str.2,@object                // @.str.2
.Lrt_.str.2:
	.asciz	"%.10f"
	.size	.Lrt_.str.2, 6

	.type	xt_rand_seeded,@object          // @xt_rand_seeded
	.local	xt_rand_seeded
	.comm	xt_rand_seeded,1,4
	.type	xt_clk_origin,@object           // @xt_clk_origin
	.local	xt_clk_origin
	.comm	xt_clk_origin,8,8
	.type	_xtc_bank_regions,@object       // @_xtc_bank_regions
	.local	_xtc_bank_regions
	.comm	_xtc_bank_regions,6144,8
	.type	xt_files,@object                // @xt_files
	.local	xt_files
	.comm	xt_files,64,8
	.type	.Lrt_.str.3,@object                // @.str.3
.Lrt_.str.3:
	.asciz	"rb"
	.size	.Lrt_.str.3, 3

	.type	.Lrt_.str.4,@object                // @.str.4
.Lrt_.str.4:
	.zero	1
	.size	.Lrt_.str.4, 1

	.type	xt_argc_v,@object               // @xt_argc_v
	.local	xt_argc_v
	.comm	xt_argc_v,4,4
	.type	xt_argv_v,@object               // @xt_argv_v
	.local	xt_argv_v
	.comm	xt_argv_v,8,8
	.type	_xt_threads_active,@object      // @_xt_threads_active
	.bss
	.globl	_xt_threads_active
	.p2align	2, 0x0
_xt_threads_active:
	.word	0                               // 0x0
	.size	_xt_threads_active, 4

	.type	xt_rt_mtx,@object               // @xt_rt_mtx
	.local	xt_rt_mtx
	.comm	xt_rt_mtx,40,4
	.type	xt_sinit_n,@object              // @xt_sinit_n
	.local	xt_sinit_n
	.comm	xt_sinit_n,4,4
	.type	xt_sinit_flag,@object           // @xt_sinit_flag
	.local	xt_sinit_flag
	.comm	xt_sinit_flag,256,8
	.type	xt_sinit_owner,@object          // @xt_sinit_owner
	.local	xt_sinit_owner
	.comm	xt_sinit_owner,128,4
	.type	xt_simd_n,@object               // @xt_simd_n
	.local	xt_simd_n
	.comm	xt_simd_n,8,8
	.type	xt_simd_cap,@object             // @xt_simd_cap
	.local	xt_simd_cap
	.comm	xt_simd_cap,8,8
	.type	.Lrt_.str.5,@object                // @.str.5
	.section	.rodata.str1.1,"aMS",@progbits,1
.Lrt_.str.5:
	.asciz	"%.*f"
	.size	.Lrt_.str.5, 5

	.ident	"Android (12027248, +pgo, -bolt, +lto, -mlgo, based on r522817) clang version 18.0.1 (https://android.googlesource.com/toolchain/llvm-project d8003a456d14a3deb8054cdaa529ffbf02d9b262)"
	.section	".note.GNU-stack","",@progbits
