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
// rt-glibc.s — the arm64 Linux (glibc) runtime: src/xtc/support-src/rt.c compiled by
// clang for aarch64-linux-gnu against glibc's own headers (on the Linux host), the
// flags rt-android.s takes: -S -O1 -fno-asynchronous-unwind-tables -fno-addrsig
// -mno-outline-atomics -mbranch-protection=none -fno-stack-protector -fomit-frame-pointer;
// local labels renamed .L -> .Lrt_. Regenerate with tools/regen-runtimes.py glibc-arm64.
// regenerated with: Debian clang version 19.1.7 (3+b1)
	.text
	.file	"rt.c"
	.globl	_xtc_alloc                      // -- Begin function _xtc_alloc
	.p2align	2
	.type	_xtc_alloc,@function
_xtc_alloc:                             // @_xtc_alloc
// %bb.0:
	stp	x30, x21, [sp, #-32]!           // 16-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	mov	x21, x2
	mov	x19, x1
	mov	x20, x0
	cbz	x1, .Lrt_BB0_2
// %bb.1:
	mov	x8, #-1048577                   // =0xffffffffffefffff
	udiv	x8, x8, x19
	cmp	x8, x20
	b.lo	.Lrt_BB0_5
.Lrt_BB0_2:
	mul	x8, x19, x20
	mov	w9, #16                         // =0x10
	mov	w0, #1                          // =0x1
	cmp	x8, #16
	csel	x8, x8, x9, hi
	add	x1, x8, #40
	bl	calloc
	cbz	x0, .Lrt_BB0_4
// %bb.3:
	mov	x9, #20290                      // =0x4f42
	mov	x8, x0
	movk	x9, #22612, lsl #16
	stp	x21, xzr, [x8, #16]
	movk	x9, #1, lsl #32
	str	x9, [x0, #32]
	stp	x19, x20, [x0], #40
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldp	x30, x21, [sp], #32             // 16-byte Folded Reload
	ret
.Lrt_BB0_4:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str
	add	x1, x1, :lo12:.Lrt_.str
	b	.Lrt_BB0_6
.Lrt_BB0_5:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str.7
	add	x1, x1, :lo12:.Lrt_.str.7
.Lrt_BB0_6:
	ldr	x8, [x8, :got_lo12:stderr]
	ldr	x0, [x8]
	mov	x2, x20
	mov	x3, x19
	bl	fprintf
	bl	abort
.Lrt_func_end0:
	.size	_xtc_alloc, .Lrt_func_end0-_xtc_alloc
                                        // -- End function
	.globl	_xtc_alloc_object               // -- Begin function _xtc_alloc_object
	.p2align	2
	.type	_xtc_alloc_object,@function
_xtc_alloc_object:                      // @_xtc_alloc_object
// %bb.0:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	mov	x19, x0
	cmn	x0, #256, lsl #12               // =1048576
	b.hs	.Lrt_BB1_3
// %bb.1:
	add	x1, x19, #8
	mov	w0, #1                          // =0x1
	bl	calloc
	cbz	x0, .Lrt_BB1_4
// %bb.2:
	mov	x8, #20302                      // =0x4f4e
	movk	x8, #22612, lsl #16
	movk	x8, #1, lsl #32
	str	x8, [x0], #8
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	ret
.Lrt_BB1_3:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str.7
	add	x1, x1, :lo12:.Lrt_.str.7
	ldr	x8, [x8, :got_lo12:stderr]
	mov	w2, #1                          // =0x1
	mov	x3, x19
	ldr	x0, [x8]
	bl	fprintf
	bl	abort
.Lrt_BB1_4:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str.1
	add	x1, x1, :lo12:.Lrt_.str.1
	ldr	x8, [x8, :got_lo12:stderr]
	mov	x2, x19
	ldr	x0, [x8]
	bl	fprintf
	bl	abort
.Lrt_func_end1:
	.size	_xtc_alloc_object, .Lrt_func_end1-_xtc_alloc_object
                                        // -- End function
	.globl	_xtc_new_u8                     // -- Begin function _xtc_new_u8
	.p2align	2
	.type	_xtc_new_u8,@function
_xtc_new_u8:                            // @_xtc_new_u8
// %bb.0:
	mov	w1, #1                          // =0x1
	cmp	x0, #16, lsl #12                // =65536
	b.lo	.Lrt_BB2_2
// %bb.1:
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_BB2_2:
	cmp	x0, #1024
	b.lo	.Lrt_BB2_4
// %bb.3:
	b	_xtc_alloc_line
.Lrt_BB2_4:
	mov	x2, xzr
	b	_xtc_alloc
.Lrt_func_end2:
	.size	_xtc_new_u8, .Lrt_func_end2-_xtc_new_u8
                                        // -- End function
	.globl	_xtc_alloc_aligned              // -- Begin function _xtc_alloc_aligned
	.p2align	2
	.type	_xtc_alloc_aligned,@function
_xtc_alloc_aligned:                     // @_xtc_alloc_aligned
// %bb.0:
	stp	x29, x30, [sp, #-96]!           // 16-byte Folded Spill
	stp	x22, x21, [sp, #64]             // 16-byte Folded Spill
	mov	x22, x2
	mov	x21, x0
	stp	x20, x19, [sp, #80]             // 16-byte Folded Spill
	mov	x20, x1
	stp	x28, x27, [sp, #16]             // 16-byte Folded Spill
	stp	x26, x25, [sp, #32]             // 16-byte Folded Spill
	stp	x24, x23, [sp, #48]             // 16-byte Folded Spill
	cbz	x1, .Lrt_BB3_2
// %bb.1:
	mov	x8, #-1048577                   // =0xffffffffffefffff
	udiv	x8, x8, x20
	cmp	x8, x21
	b.lo	.Lrt_BB3_28
.Lrt_BB3_2:
	mul	x23, x20, x21
	mov	w8, #16                         // =0x10
	mov	w9, #16383                      // =0x3fff
	mov	w0, #1                          // =0x1
	cmp	x23, #16
	csel	x8, x23, x8, hi
	add	x8, x8, x9
	mov	w9, #16432                      // =0x4030
	and	x8, x8, #0xffffffffffffc000
	add	x1, x8, x9
	bl	calloc
	cbz	x0, .Lrt_BB3_27
// %bb.3:
	mov	w8, #16431                      // =0x402f
	add	x8, x0, x8
	and	x19, x8, #0xffffffffffffc000
	mov	x8, #20291                      // =0x4f43
	movk	x8, #22612, lsl #16
	stp	x21, x22, [x19, #-32]
	adrp	x21, _xt_threads_active
	movk	x8, #1, lsl #32
	stp	x0, x20, [x19, #-48]
	stp	xzr, x8, [x19, #-16]
	ldr	w8, [x21, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB3_5
// %bb.4:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB3_5:
	adrp	x25, xt_simd_n
	adrp	x28, xt_simd_cap
	adrp	x27, xt_simd_tab
	ldr	x24, [x25, :lo12:xt_simd_n]
	ldr	x8, [x28, :lo12:xt_simd_cap]
	adrp	x26, xt_simd_flag
	cmp	x24, x8
	b.ne	.Lrt_BB3_17
// %bb.6:
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
	b.eq	.Lrt_BB3_14
// %bb.7:
	lsl	x8, x24, #1
	cbz	x8, .Lrt_BB3_10
// %bb.8:
	ldr	x9, [x27, :lo12:xt_simd_tab]
	mov	x10, x21
.Lrt_BB3_9:                                // =>This Inner Loop Header: Depth=1
	ldr	x11, [x9], #8
	subs	x8, x8, #1
	str	x11, [x10], #8
	b.ne	.Lrt_BB3_9
.Lrt_BB3_10:
	cbz	x24, .Lrt_BB3_13
// %bb.11:
	ldr	x8, [x26, :lo12:xt_simd_flag]
	mov	x9, x22
.Lrt_BB3_12:                               // =>This Inner Loop Header: Depth=1
	ldrb	w10, [x8], #1
	subs	x24, x24, #1
	strb	w10, [x9], #1
	b.ne	.Lrt_BB3_12
.Lrt_BB3_13:
	ldr	x0, [x27, :lo12:xt_simd_tab]
	bl	free
	ldr	x0, [x26, :lo12:xt_simd_flag]
	bl	free
	str	x21, [x27, :lo12:xt_simd_tab]
	adrp	x21, _xt_threads_active
	str	x22, [x26, :lo12:xt_simd_flag]
	str	x20, [x28, :lo12:xt_simd_cap]
	b	.Lrt_BB3_16
.Lrt_BB3_14:
	mov	x0, x21
	bl	free
	mov	x0, x22
	bl	free
	adrp	x21, _xt_threads_active
	ldr	w8, [x21, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB3_16
// %bb.15:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB3_16:
	cbz	w29, .Lrt_BB3_26
.Lrt_BB3_17:
	ldr	x8, [x25, :lo12:xt_simd_n]
	cbz	x8, .Lrt_BB3_21
// %bb.18:
	ldr	x10, [x27, :lo12:xt_simd_tab]
	mov	x9, xzr
	mov	x11, x8
.Lrt_BB3_19:                               // =>This Inner Loop Header: Depth=1
	add	x12, x11, x9
	and	x13, x12, #0x1ffffffffffffffe
	lsr	x12, x12, #1
	ldr	x13, [x10, x13, lsl #3]
	cmp	x13, x19
	csel	x11, x12, x11, hi
	csinc	x9, x9, x12, hi
	cmp	x9, x11
	b.lo	.Lrt_BB3_19
// %bb.20:
	cmp	x8, x9
	b.hi	.Lrt_BB3_22
	b	.Lrt_BB3_24
.Lrt_BB3_21:
	mov	x9, xzr
	cmp	x8, x9
	b.ls	.Lrt_BB3_24
.Lrt_BB3_22:
	ldr	x10, [x27, :lo12:xt_simd_tab]
	ldr	x11, [x26, :lo12:xt_simd_flag]
	sub	x13, x8, #1
	add	x14, x10, x8, lsl #4
	add	x11, x11, x8
	mov	x12, x11
	mov	x10, x14
.Lrt_BB3_23:                               // =>This Inner Loop Header: Depth=1
	ldr	x15, [x10, #-16]!
	ldur	x16, [x14, #-8]
	cmp	x13, x9
	sub	x13, x13, #1
	stp	x15, x16, [x14]
	ldrb	w14, [x12, #-1]!
	strb	w14, [x11]
	mov	x14, x10
	mov	x11, x12
	b.hi	.Lrt_BB3_23
.Lrt_BB3_24:
	ldr	x10, [x27, :lo12:xt_simd_tab]
	add	x11, x19, x23
	add	x8, x8, #1
	add	x10, x10, x9, lsl #4
	stp	x19, x11, [x10]
	ldr	x10, [x26, :lo12:xt_simd_flag]
	strb	wzr, [x10, x9]
	ldr	w9, [x21, :lo12:_xt_threads_active]
	str	x8, [x25, :lo12:xt_simd_n]
	cbz	w9, .Lrt_BB3_26
// %bb.25:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB3_26:
	mov	x0, x19
	ldp	x20, x19, [sp, #80]             // 16-byte Folded Reload
	ldp	x22, x21, [sp, #64]             // 16-byte Folded Reload
	ldp	x24, x23, [sp, #48]             // 16-byte Folded Reload
	ldp	x26, x25, [sp, #32]             // 16-byte Folded Reload
	ldp	x28, x27, [sp, #16]             // 16-byte Folded Reload
	ldp	x29, x30, [sp], #96             // 16-byte Folded Reload
	ret
.Lrt_BB3_27:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str
	add	x1, x1, :lo12:.Lrt_.str
	b	.Lrt_BB3_29
.Lrt_BB3_28:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str.7
	add	x1, x1, :lo12:.Lrt_.str.7
.Lrt_BB3_29:
	ldr	x8, [x8, :got_lo12:stderr]
	ldr	x0, [x8]
	mov	x2, x21
	mov	x3, x20
	bl	fprintf
	bl	abort
.Lrt_func_end3:
	.size	_xtc_alloc_aligned, .Lrt_func_end3-_xtc_alloc_aligned
                                        // -- End function
	.globl	_xtc_alloc_line                 // -- Begin function _xtc_alloc_line
	.p2align	2
	.type	_xtc_alloc_line,@function
_xtc_alloc_line:                        // @_xtc_alloc_line
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	mov	x19, x1
	mov	x20, x0
	cbz	x1, .Lrt_BB4_2
// %bb.1:
	mov	x8, #-1048577                   // =0xffffffffffefffff
	udiv	x8, x8, x19
	cmp	x8, x20
	b.lo	.Lrt_BB4_5
.Lrt_BB4_2:
	mov	x8, #112                        // =0x70
	madd	x1, x19, x20, x8
	mov	w0, #1                          // =0x1
	bl	calloc
	cbz	x0, .Lrt_BB4_4
// %bb.3:
	add	x9, x0, #111
	mov	x8, x0
	mov	x10, #20291                     // =0x4f43
	and	x0, x9, #0xffffffffffffffc0
	movk	x10, #22612, lsl #16
	stp	x20, xzr, [x0, #-32]
	movk	x10, #1, lsl #32
	stp	x8, x19, [x0, #-48]
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	stp	xzr, x10, [x0, #-16]
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_BB4_4:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str
	add	x1, x1, :lo12:.Lrt_.str
	b	.Lrt_BB4_6
.Lrt_BB4_5:
	adrp	x8, :got:stderr
	adrp	x1, .Lrt_.str.7
	add	x1, x1, :lo12:.Lrt_.str.7
.Lrt_BB4_6:
	ldr	x8, [x8, :got_lo12:stderr]
	ldr	x0, [x8]
	mov	x2, x20
	mov	x3, x19
	bl	fprintf
	bl	abort
.Lrt_func_end4:
	.size	_xtc_alloc_line, .Lrt_func_end4-_xtc_alloc_line
                                        // -- End function
	.globl	_xtc_new_i8                     // -- Begin function _xtc_new_i8
	.p2align	2
	.type	_xtc_new_i8,@function
_xtc_new_i8:                            // @_xtc_new_i8
// %bb.0:
	mov	w1, #1                          // =0x1
	cmp	x0, #16, lsl #12                // =65536
	b.lo	.Lrt_BB5_2
// %bb.1:
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_BB5_2:
	cmp	x0, #1024
	b.lo	.Lrt_BB5_4
// %bb.3:
	b	_xtc_alloc_line
.Lrt_BB5_4:
	mov	x2, xzr
	b	_xtc_alloc
.Lrt_func_end5:
	.size	_xtc_new_i8, .Lrt_func_end5-_xtc_new_i8
                                        // -- End function
	.globl	_xtc_new_u16                    // -- Begin function _xtc_new_u16
	.p2align	2
	.type	_xtc_new_u16,@function
_xtc_new_u16:                           // @_xtc_new_u16
// %bb.0:
	lsl	x8, x0, #1
	mov	w1, #2                          // =0x2
	cmp	x8, #16, lsl #12                // =65536
	b.lo	.Lrt_BB6_2
// %bb.1:
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_BB6_2:
	cmp	x8, #1024
	b.lo	.Lrt_BB6_4
// %bb.3:
	b	_xtc_alloc_line
.Lrt_BB6_4:
	mov	x2, xzr
	b	_xtc_alloc
.Lrt_func_end6:
	.size	_xtc_new_u16, .Lrt_func_end6-_xtc_new_u16
                                        // -- End function
	.globl	_xtc_new_i16                    // -- Begin function _xtc_new_i16
	.p2align	2
	.type	_xtc_new_i16,@function
_xtc_new_i16:                           // @_xtc_new_i16
// %bb.0:
	lsl	x8, x0, #1
	mov	w1, #2                          // =0x2
	cmp	x8, #16, lsl #12                // =65536
	b.lo	.Lrt_BB7_2
// %bb.1:
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_BB7_2:
	cmp	x8, #1024
	b.lo	.Lrt_BB7_4
// %bb.3:
	b	_xtc_alloc_line
.Lrt_BB7_4:
	mov	x2, xzr
	b	_xtc_alloc
.Lrt_func_end7:
	.size	_xtc_new_i16, .Lrt_func_end7-_xtc_new_i16
                                        // -- End function
	.globl	_xtc_new_u32                    // -- Begin function _xtc_new_u32
	.p2align	2
	.type	_xtc_new_u32,@function
_xtc_new_u32:                           // @_xtc_new_u32
// %bb.0:
	lsl	x8, x0, #2
	mov	w1, #4                          // =0x4
	cmp	x8, #16, lsl #12                // =65536
	b.lo	.Lrt_BB8_2
// %bb.1:
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_BB8_2:
	cmp	x8, #1024
	b.lo	.Lrt_BB8_4
// %bb.3:
	b	_xtc_alloc_line
.Lrt_BB8_4:
	mov	x2, xzr
	b	_xtc_alloc
.Lrt_func_end8:
	.size	_xtc_new_u32, .Lrt_func_end8-_xtc_new_u32
                                        // -- End function
	.globl	_xtc_new_i32                    // -- Begin function _xtc_new_i32
	.p2align	2
	.type	_xtc_new_i32,@function
_xtc_new_i32:                           // @_xtc_new_i32
// %bb.0:
	lsl	x8, x0, #2
	mov	w1, #4                          // =0x4
	cmp	x8, #16, lsl #12                // =65536
	b.lo	.Lrt_BB9_2
// %bb.1:
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_BB9_2:
	cmp	x8, #1024
	b.lo	.Lrt_BB9_4
// %bb.3:
	b	_xtc_alloc_line
.Lrt_BB9_4:
	mov	x2, xzr
	b	_xtc_alloc
.Lrt_func_end9:
	.size	_xtc_new_i32, .Lrt_func_end9-_xtc_new_i32
                                        // -- End function
	.globl	_xtc_new_u64                    // -- Begin function _xtc_new_u64
	.p2align	2
	.type	_xtc_new_u64,@function
_xtc_new_u64:                           // @_xtc_new_u64
// %bb.0:
	lsl	x8, x0, #3
	mov	w1, #8                          // =0x8
	cmp	x8, #16, lsl #12                // =65536
	b.lo	.Lrt_BB10_2
// %bb.1:
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_BB10_2:
	cmp	x8, #1024
	b.lo	.Lrt_BB10_4
// %bb.3:
	b	_xtc_alloc_line
.Lrt_BB10_4:
	mov	x2, xzr
	b	_xtc_alloc
.Lrt_func_end10:
	.size	_xtc_new_u64, .Lrt_func_end10-_xtc_new_u64
                                        // -- End function
	.globl	_xtc_new_i64                    // -- Begin function _xtc_new_i64
	.p2align	2
	.type	_xtc_new_i64,@function
_xtc_new_i64:                           // @_xtc_new_i64
// %bb.0:
	lsl	x8, x0, #3
	mov	w1, #8                          // =0x8
	cmp	x8, #16, lsl #12                // =65536
	b.lo	.Lrt_BB11_2
// %bb.1:
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_BB11_2:
	cmp	x8, #1024
	b.lo	.Lrt_BB11_4
// %bb.3:
	b	_xtc_alloc_line
.Lrt_BB11_4:
	mov	x2, xzr
	b	_xtc_alloc
.Lrt_func_end11:
	.size	_xtc_new_i64, .Lrt_func_end11-_xtc_new_i64
                                        // -- End function
	.globl	_xtc_new_pointer                // -- Begin function _xtc_new_pointer
	.p2align	2
	.type	_xtc_new_pointer,@function
_xtc_new_pointer:                       // @_xtc_new_pointer
// %bb.0:
	mov	w1, #8                          // =0x8
	mov	x2, xzr
	b	_xtc_alloc
.Lrt_func_end12:
	.size	_xtc_new_pointer, .Lrt_func_end12-_xtc_new_pointer
                                        // -- End function
	.globl	_xtc_new_bool                   // -- Begin function _xtc_new_bool
	.p2align	2
	.type	_xtc_new_bool,@function
_xtc_new_bool:                          // @_xtc_new_bool
// %bb.0:
	mov	w1, #1                          // =0x1
	cmp	x0, #16, lsl #12                // =65536
	b.lo	.Lrt_BB13_2
// %bb.1:
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_BB13_2:
	cmp	x0, #1024
	b.lo	.Lrt_BB13_4
// %bb.3:
	b	_xtc_alloc_line
.Lrt_BB13_4:
	mov	x2, xzr
	b	_xtc_alloc
.Lrt_func_end13:
	.size	_xtc_new_bool, .Lrt_func_end13-_xtc_new_bool
                                        // -- End function
	.globl	_xtc_new_float                  // -- Begin function _xtc_new_float
	.p2align	2
	.type	_xtc_new_float,@function
_xtc_new_float:                         // @_xtc_new_float
// %bb.0:
	lsl	x8, x0, #2
	mov	w1, #4                          // =0x4
	cmp	x8, #16, lsl #12                // =65536
	b.lo	.Lrt_BB14_2
// %bb.1:
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_BB14_2:
	cmp	x8, #1024
	b.lo	.Lrt_BB14_4
// %bb.3:
	b	_xtc_alloc_line
.Lrt_BB14_4:
	mov	x2, xzr
	b	_xtc_alloc
.Lrt_func_end14:
	.size	_xtc_new_float, .Lrt_func_end14-_xtc_new_float
                                        // -- End function
	.globl	_xtc_new_double                 // -- Begin function _xtc_new_double
	.p2align	2
	.type	_xtc_new_double,@function
_xtc_new_double:                        // @_xtc_new_double
// %bb.0:
	lsl	x8, x0, #3
	mov	w1, #8                          // =0x8
	cmp	x8, #16, lsl #12                // =65536
	b.lo	.Lrt_BB15_2
// %bb.1:
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_BB15_2:
	cmp	x8, #1024
	b.lo	.Lrt_BB15_4
// %bb.3:
	b	_xtc_alloc_line
.Lrt_BB15_4:
	mov	x2, xzr
	b	_xtc_alloc
.Lrt_func_end15:
	.size	_xtc_new_double, .Lrt_func_end15-_xtc_new_double
                                        // -- End function
	.globl	_xtc_new_string                 // -- Begin function _xtc_new_string
	.p2align	2
	.type	_xtc_new_string,@function
_xtc_new_string:                        // @_xtc_new_string
// %bb.0:
	mov	w1, #8                          // =0x8
	mov	x2, xzr
	b	_xtc_alloc
.Lrt_func_end16:
	.size	_xtc_new_string, .Lrt_func_end16-_xtc_new_string
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
	cbz	x0, .Lrt_BB17_26
// %bb.1:
	mov	x20, x1
	cbz	x1, .Lrt_BB17_26
// %bb.2:
	mov	x19, x0
	orr	w8, w19, w20
	and	x8, x8, #0xfff
	cbnz	x8, .Lrt_BB17_26
// %bb.3:
	adrp	x21, _xt_threads_active
	ldr	w8, [x21, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB17_5
// %bb.4:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB17_5:
	adrp	x25, xt_simd_n
	adrp	x28, xt_simd_cap
	adrp	x27, xt_simd_tab
	ldr	x24, [x25, :lo12:xt_simd_n]
	ldr	x8, [x28, :lo12:xt_simd_cap]
	adrp	x26, xt_simd_flag
	cmp	x24, x8
	b.ne	.Lrt_BB17_17
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
	b.eq	.Lrt_BB17_14
// %bb.7:
	lsl	x8, x24, #1
	cbz	x8, .Lrt_BB17_10
// %bb.8:
	ldr	x9, [x27, :lo12:xt_simd_tab]
	mov	x10, x22
.Lrt_BB17_9:                               // =>This Inner Loop Header: Depth=1
	ldr	x11, [x9], #8
	subs	x8, x8, #1
	str	x11, [x10], #8
	b.ne	.Lrt_BB17_9
.Lrt_BB17_10:
	cbz	x24, .Lrt_BB17_13
// %bb.11:
	ldr	x8, [x26, :lo12:xt_simd_flag]
	mov	x9, x23
.Lrt_BB17_12:                              // =>This Inner Loop Header: Depth=1
	ldrb	w10, [x8], #1
	subs	x24, x24, #1
	strb	w10, [x9], #1
	b.ne	.Lrt_BB17_12
.Lrt_BB17_13:
	ldr	x0, [x27, :lo12:xt_simd_tab]
	bl	free
	ldr	x0, [x26, :lo12:xt_simd_flag]
	bl	free
	str	x22, [x27, :lo12:xt_simd_tab]
	str	x23, [x26, :lo12:xt_simd_flag]
	str	x21, [x28, :lo12:xt_simd_cap]
	adrp	x21, _xt_threads_active
	b	.Lrt_BB17_16
.Lrt_BB17_14:
	mov	x0, x22
	bl	free
	mov	x0, x23
	bl	free
	adrp	x21, _xt_threads_active
	ldr	w8, [x21, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB17_16
// %bb.15:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB17_16:
	cbz	w29, .Lrt_BB17_26
.Lrt_BB17_17:
	ldr	x8, [x25, :lo12:xt_simd_n]
	cbz	x8, .Lrt_BB17_21
// %bb.18:
	ldr	x10, [x27, :lo12:xt_simd_tab]
	mov	x9, xzr
	mov	x11, x8
.Lrt_BB17_19:                              // =>This Inner Loop Header: Depth=1
	add	x12, x11, x9
	and	x13, x12, #0x1ffffffffffffffe
	lsr	x12, x12, #1
	ldr	x13, [x10, x13, lsl #3]
	cmp	x13, x19
	csel	x11, x12, x11, hi
	csinc	x9, x9, x12, hi
	cmp	x9, x11
	b.lo	.Lrt_BB17_19
// %bb.20:
	cmp	x8, x9
	b.hi	.Lrt_BB17_22
	b	.Lrt_BB17_24
.Lrt_BB17_21:
	mov	x9, xzr
	cmp	x8, x9
	b.ls	.Lrt_BB17_24
.Lrt_BB17_22:
	ldr	x10, [x27, :lo12:xt_simd_tab]
	ldr	x11, [x26, :lo12:xt_simd_flag]
	sub	x13, x8, #1
	add	x14, x10, x8, lsl #4
	add	x11, x11, x8
	mov	x12, x11
	mov	x10, x14
.Lrt_BB17_23:                              // =>This Inner Loop Header: Depth=1
	ldr	x15, [x10, #-16]!
	ldur	x16, [x14, #-8]
	cmp	x13, x9
	sub	x13, x13, #1
	stp	x15, x16, [x14]
	ldrb	w14, [x12, #-1]!
	strb	w14, [x11]
	mov	x14, x10
	mov	x11, x12
	b.hi	.Lrt_BB17_23
.Lrt_BB17_24:
	ldr	x10, [x27, :lo12:xt_simd_tab]
	add	x11, x19, x20
	add	x8, x8, #1
	add	x10, x10, x9, lsl #4
	stp	x19, x11, [x10]
	ldr	x10, [x26, :lo12:xt_simd_flag]
	strb	wzr, [x10, x9]
	ldr	w9, [x21, :lo12:_xt_threads_active]
	str	x8, [x25, :lo12:xt_simd_n]
	cbz	w9, .Lrt_BB17_26
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
.Lrt_BB17_26:
	ldp	x20, x19, [sp, #80]             // 16-byte Folded Reload
	ldp	x22, x21, [sp, #64]             // 16-byte Folded Reload
	ldp	x24, x23, [sp, #48]             // 16-byte Folded Reload
	ldp	x26, x25, [sp, #32]             // 16-byte Folded Reload
	ldp	x28, x27, [sp, #16]             // 16-byte Folded Reload
	ldp	x29, x30, [sp], #96             // 16-byte Folded Reload
	ret
.Lrt_func_end17:
	.size	_xtc_simd_register, .Lrt_func_end17-_xtc_simd_register
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
	cbz	w8, .Lrt_BB18_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB18_2:
	adrp	x8, xt_simd_n
	ldr	x9, [x8, :lo12:xt_simd_n]
	adrp	x8, xt_simd_tab
	cbz	x9, .Lrt_BB18_6
// %bb.3:
	ldr	x11, [x8, :lo12:xt_simd_tab]
	mov	x10, xzr
.Lrt_BB18_4:                               // =>This Inner Loop Header: Depth=1
	add	x12, x9, x10
	and	x13, x12, #0x1ffffffffffffffe
	lsr	x12, x12, #1
	ldr	x13, [x11, x13, lsl #3]
	cmp	x13, x19
	csel	x9, x12, x9, hi
	csinc	x10, x10, x12, hi
	cmp	x10, x9
	b.lo	.Lrt_BB18_4
// %bb.5:
	cbnz	x10, .Lrt_BB18_7
	b	.Lrt_BB18_9
.Lrt_BB18_6:
	mov	x10, xzr
	cbz	x10, .Lrt_BB18_9
.Lrt_BB18_7:
	ldr	x8, [x8, :lo12:xt_simd_tab]
	add	x8, x8, x10, lsl #4
	ldur	x9, [x8, #-8]
	cmp	x9, x19
	b.ls	.Lrt_BB18_9
// %bb.8:
	ldur	x19, [x8, #-16]
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbnz	w8, .Lrt_BB18_10
	b	.Lrt_BB18_11
.Lrt_BB18_9:
	mov	x19, xzr
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB18_11
.Lrt_BB18_10:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB18_11:
	mov	x0, x19
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end18:
	.size	_xtc_simd_base, .Lrt_func_end18-_xtc_simd_base
                                        // -- End function
	.globl	_xt_rt_lock                     // -- Begin function _xt_rt_lock
	.p2align	2
	.type	_xt_rt_lock,@function
_xt_rt_lock:                            // @_xt_rt_lock
// %bb.0:
	adrp	x8, _xt_threads_active
	ldr	w8, [x8, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB19_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	b	pthread_mutex_lock
.Lrt_BB19_2:
	ret
.Lrt_func_end19:
	.size	_xt_rt_lock, .Lrt_func_end19-_xt_rt_lock
                                        // -- End function
	.globl	_xt_rt_unlock                   // -- Begin function _xt_rt_unlock
	.p2align	2
	.type	_xt_rt_unlock,@function
_xt_rt_unlock:                          // @_xt_rt_unlock
// %bb.0:
	adrp	x8, _xt_threads_active
	ldr	w8, [x8, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB20_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	b	pthread_mutex_unlock
.Lrt_BB20_2:
	ret
.Lrt_func_end20:
	.size	_xt_rt_unlock, .Lrt_func_end20-_xt_rt_unlock
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
	cmp	x13, x19
	csel	x9, x12, x9, hi
	csinc	x10, x10, x12, hi
	cmp	x10, x9
	b.lo	.Lrt_BB21_4
// %bb.5:
	cbnz	x10, .Lrt_BB21_7
	b	.Lrt_BB21_8
.Lrt_BB21_6:
	mov	x10, xzr
	cbz	x10, .Lrt_BB21_8
.Lrt_BB21_7:
	ldr	x8, [x8, :lo12:xt_simd_tab]
	add	x8, x8, x10, lsl #4
	ldur	x8, [x8, #-8]
	subs	x19, x8, x19
	b.hi	.Lrt_BB21_9
.Lrt_BB21_8:
	mov	x19, #-1                        // =0xffffffffffffffff
.Lrt_BB21_9:
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB21_11
// %bb.10:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB21_11:
	mov	x0, x19
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end21:
	.size	_xtc_simd_span, .Lrt_func_end21-_xtc_simd_span
                                        // -- End function
	.globl	_xtc_simd_watch                 // -- Begin function _xtc_simd_watch
	.p2align	2
	.type	_xtc_simd_watch,@function
_xtc_simd_watch:                        // @_xtc_simd_watch
// %bb.0:
	sub	sp, sp, #224
	stp	x22, x21, [sp, #192]            // 16-byte Folded Spill
	adrp	x21, _xt_threads_active
	ldr	w8, [x21, :lo12:_xt_threads_active]
	stp	x20, x19, [sp, #208]            // 16-byte Folded Spill
	mov	x19, x0
	str	x30, [sp, #160]                 // 8-byte Folded Spill
	stp	x24, x23, [sp, #176]            // 16-byte Folded Spill
	cbz	w8, .Lrt_BB22_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB22_2:
	adrp	x8, xt_simd_n
	adrp	x22, xt_simd_tab
	ldr	x8, [x8, :lo12:xt_simd_n]
	cbz	x8, .Lrt_BB22_6
// %bb.3:
	ldr	x10, [x22, :lo12:xt_simd_tab]
	mov	x9, xzr
.Lrt_BB22_4:                               // =>This Inner Loop Header: Depth=1
	add	x11, x8, x9
	and	x12, x11, #0x1ffffffffffffffe
	lsr	x11, x11, #1
	ldr	x12, [x10, x12, lsl #3]
	cmp	x12, x19
	csel	x8, x11, x8, hi
	csinc	x9, x9, x11, hi
	cmp	x9, x8
	b.lo	.Lrt_BB22_4
// %bb.5:
	cbnz	x9, .Lrt_BB22_7
	b	.Lrt_BB22_11
.Lrt_BB22_6:
	mov	x9, xzr
	cbz	x9, .Lrt_BB22_11
.Lrt_BB22_7:
	sub	x23, x9, #1
	ldr	x8, [x22, :lo12:xt_simd_tab]
	lsl	x9, x23, #4
	ldr	x8, [x8, x9]
	cmp	x8, x19
	b.ne	.Lrt_BB22_11
// %bb.8:
	adrp	x24, xt_simd_installed
	ldrb	w8, [x24, :lo12:xt_simd_installed]
	tbnz	w8, #0, .Lrt_BB22_10
// %bb.9:
	adrp	x8, xt_simd_fault
	add	x8, x8, :lo12:xt_simd_fault
	str	x8, [sp, #8]
	mov	w8, #4                          // =0x4
	movk	w8, #16384, lsl #16
	str	w8, [sp, #144]
	add	x8, sp, #8
	add	x0, x8, #8
	bl	sigemptyset
	adrp	x20, xt_simd_old
	add	x20, x20, :lo12:xt_simd_old
	add	x1, sp, #8
	mov	w0, #11                         // =0xb
	mov	x2, x20
	str	xzr, [sp, #152]
	bl	sigaction
	add	x1, sp, #8
	add	x2, x20, #152
	mov	w0, #7                          // =0x7
	bl	sigaction
	mov	w8, #1                          // =0x1
	strb	w8, [x24, :lo12:xt_simd_installed]
.Lrt_BB22_10:
	ldr	x8, [x22, :lo12:xt_simd_tab]
	mov	x0, x19
	mov	w2, #1                          // =0x1
	add	x8, x8, x23, lsl #4
	ldp	x8, x9, [x8]
	sub	x8, x9, x8
	mov	w9, #16383                      // =0x3fff
	add	x8, x8, x9
	and	x1, x8, #0xffffffffffffc000
	bl	mprotect
	cbz	w0, .Lrt_BB22_14
.Lrt_BB22_11:
	mov	w19, wzr
	ldr	w8, [x21, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB22_13
.Lrt_BB22_12:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB22_13:
	mov	w0, w19
	ldp	x20, x19, [sp, #208]            // 16-byte Folded Reload
	ldp	x22, x21, [sp, #192]            // 16-byte Folded Reload
	ldr	x30, [sp, #160]                 // 8-byte Folded Reload
	ldp	x24, x23, [sp, #176]            // 16-byte Folded Reload
	add	sp, sp, #224
	ret
.Lrt_BB22_14:
	adrp	x8, xt_simd_flag
	mov	w19, #1                         // =0x1
	ldr	x8, [x8, :lo12:xt_simd_flag]
	ldrb	w9, [x8, x23]
	orr	w9, w9, #0x1
	strb	w9, [x8, x23]
	ldr	w8, [x21, :lo12:_xt_threads_active]
	cbnz	w8, .Lrt_BB22_12
	b	.Lrt_BB22_13
.Lrt_func_end22:
	.size	_xtc_simd_watch, .Lrt_func_end22-_xtc_simd_watch
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
	cbz	w8, .Lrt_BB23_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB23_2:
	adrp	x8, xt_simd_n
	ldr	x9, [x8, :lo12:xt_simd_n]
	adrp	x8, xt_simd_tab
	cbz	x9, .Lrt_BB23_6
// %bb.3:
	ldr	x11, [x8, :lo12:xt_simd_tab]
	mov	x10, xzr
.Lrt_BB23_4:                               // =>This Inner Loop Header: Depth=1
	add	x12, x9, x10
	and	x13, x12, #0x1ffffffffffffffe
	lsr	x12, x12, #1
	ldr	x13, [x11, x13, lsl #3]
	cmp	x13, x21
	csel	x9, x12, x9, hi
	csinc	x10, x10, x12, hi
	cmp	x10, x9
	b.lo	.Lrt_BB23_4
// %bb.5:
	cbnz	x10, .Lrt_BB23_7
	b	.Lrt_BB23_12
.Lrt_BB23_6:
	mov	x10, xzr
	cbz	x10, .Lrt_BB23_12
.Lrt_BB23_7:
	ldr	x8, [x8, :lo12:xt_simd_tab]
	sub	x9, x10, #1
	add	x10, x8, x9, lsl #4
	ldr	x10, [x10, #8]
	cmp	x21, x10
	b.hs	.Lrt_BB23_12
// %bb.8:
	adrp	x11, xt_simd_flag
	ldr	x11, [x11, :lo12:xt_simd_flag]
	ldrb	w12, [x11, x9]
	tbz	w12, #0, .Lrt_BB23_10
// %bb.9:
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
.Lrt_BB23_10:
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB23_15
// %bb.11:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	ldp	x30, x21, [sp], #32             // 16-byte Folded Reload
	b	pthread_mutex_unlock
.Lrt_BB23_12:
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB23_14
// %bb.13:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB23_14:
	cmp	w19, #11
	mov	w0, w19
	mov	w9, #152                        // =0x98
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	cset	w8, ne
	adrp	x10, xt_simd_old
	add	x10, x10, :lo12:xt_simd_old
	umaddl	x1, w8, w9, x10
	mov	x2, xzr
	ldp	x30, x21, [sp], #32             // 16-byte Folded Reload
	b	sigaction
.Lrt_BB23_15:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldp	x30, x21, [sp], #32             // 16-byte Folded Reload
	ret
.Lrt_func_end23:
	.size	xt_simd_fault, .Lrt_func_end23-xt_simd_fault
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
	cbz	w8, .Lrt_BB24_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB24_2:
	adrp	x8, xt_simd_n
	ldr	x9, [x8, :lo12:xt_simd_n]
	adrp	x8, xt_simd_tab
	cbz	x9, .Lrt_BB24_6
// %bb.3:
	ldr	x11, [x8, :lo12:xt_simd_tab]
	mov	x10, xzr
.Lrt_BB24_4:                               // =>This Inner Loop Header: Depth=1
	add	x12, x9, x10
	and	x13, x12, #0x1ffffffffffffffe
	lsr	x12, x12, #1
	ldr	x13, [x11, x13, lsl #3]
	cmp	x13, x19
	csel	x9, x12, x9, hi
	csinc	x10, x10, x12, hi
	cmp	x10, x9
	b.lo	.Lrt_BB24_4
// %bb.5:
	cbnz	x10, .Lrt_BB24_7
	b	.Lrt_BB24_10
.Lrt_BB24_6:
	mov	x10, xzr
	cbz	x10, .Lrt_BB24_10
.Lrt_BB24_7:
	sub	x9, x10, #1
	ldr	x8, [x8, :lo12:xt_simd_tab]
	lsl	x10, x9, #4
	ldr	x10, [x8, x10]
	cmp	x10, x19
	b.ne	.Lrt_BB24_10
// %bb.8:
	adrp	x10, xt_simd_flag
	ldr	x10, [x10, :lo12:xt_simd_flag]
	ldrb	w11, [x10, x9]
	tbz	w11, #0, .Lrt_BB24_10
// %bb.9:
	add	x8, x8, x9, lsl #4
	and	w11, w11, #0xfe
	strb	w11, [x10, x9]
	mov	x0, x19
	mov	w2, #3                          // =0x3
	ldp	x8, x9, [x8]
	sub	x8, x9, x8
	mov	w9, #16383                      // =0x3fff
	add	x8, x8, x9
	and	x1, x8, #0xffffffffffffc000
	bl	mprotect
.Lrt_BB24_10:
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB24_12
// %bb.11:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	b	pthread_mutex_unlock
.Lrt_BB24_12:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end24:
	.size	_xtc_simd_unwatch, .Lrt_func_end24-_xtc_simd_unwatch
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
	cbz	w8, .Lrt_BB25_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB25_2:
	adrp	x8, xt_simd_n
	ldr	x9, [x8, :lo12:xt_simd_n]
	adrp	x8, xt_simd_tab
	cbz	x9, .Lrt_BB25_8
// %bb.3:
	ldr	x11, [x8, :lo12:xt_simd_tab]
	mov	x10, xzr
.Lrt_BB25_4:                               // =>This Inner Loop Header: Depth=1
	add	x12, x9, x10
	and	x13, x12, #0x1ffffffffffffffe
	lsr	x12, x12, #1
	ldr	x13, [x11, x13, lsl #3]
	cmp	x13, x19
	csel	x9, x12, x9, hi
	csinc	x10, x10, x12, hi
	cmp	x10, x9
	b.lo	.Lrt_BB25_4
// %bb.5:
	cbz	x10, .Lrt_BB25_9
.Lrt_BB25_6:
	sub	x9, x10, #1
	ldr	x8, [x8, :lo12:xt_simd_tab]
	lsl	x10, x9, #4
	ldr	x8, [x8, x10]
	cmp	x8, x19
	mov	w19, #1                         // =0x1
	b.ne	.Lrt_BB25_10
// %bb.7:
	adrp	x8, xt_simd_flag
	ldr	x8, [x8, :lo12:xt_simd_flag]
	ldrb	w8, [x8, x9]
	bic	w19, w19, w8
	b	.Lrt_BB25_10
.Lrt_BB25_8:
	mov	x10, xzr
	cbnz	x10, .Lrt_BB25_6
.Lrt_BB25_9:
	mov	w19, #1                         // =0x1
.Lrt_BB25_10:
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB25_12
// %bb.11:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB25_12:
	mov	w0, w19
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end25:
	.size	_xtc_simd_dirty, .Lrt_func_end25-_xtc_simd_dirty
                                        // -- End function
	.globl	_xtc_new_simd_u8                // -- Begin function _xtc_new_simd_u8
	.p2align	2
	.type	_xtc_new_simd_u8,@function
_xtc_new_simd_u8:                       // @_xtc_new_simd_u8
// %bb.0:
	mov	w1, #1                          // =0x1
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end26:
	.size	_xtc_new_simd_u8, .Lrt_func_end26-_xtc_new_simd_u8
                                        // -- End function
	.globl	_xtc_new_simd_i8                // -- Begin function _xtc_new_simd_i8
	.p2align	2
	.type	_xtc_new_simd_i8,@function
_xtc_new_simd_i8:                       // @_xtc_new_simd_i8
// %bb.0:
	mov	w1, #1                          // =0x1
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end27:
	.size	_xtc_new_simd_i8, .Lrt_func_end27-_xtc_new_simd_i8
                                        // -- End function
	.globl	_xtc_new_simd_bool              // -- Begin function _xtc_new_simd_bool
	.p2align	2
	.type	_xtc_new_simd_bool,@function
_xtc_new_simd_bool:                     // @_xtc_new_simd_bool
// %bb.0:
	mov	w1, #1                          // =0x1
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end28:
	.size	_xtc_new_simd_bool, .Lrt_func_end28-_xtc_new_simd_bool
                                        // -- End function
	.globl	_xtc_new_simd_u16               // -- Begin function _xtc_new_simd_u16
	.p2align	2
	.type	_xtc_new_simd_u16,@function
_xtc_new_simd_u16:                      // @_xtc_new_simd_u16
// %bb.0:
	mov	w1, #2                          // =0x2
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end29:
	.size	_xtc_new_simd_u16, .Lrt_func_end29-_xtc_new_simd_u16
                                        // -- End function
	.globl	_xtc_new_simd_i16               // -- Begin function _xtc_new_simd_i16
	.p2align	2
	.type	_xtc_new_simd_i16,@function
_xtc_new_simd_i16:                      // @_xtc_new_simd_i16
// %bb.0:
	mov	w1, #2                          // =0x2
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end30:
	.size	_xtc_new_simd_i16, .Lrt_func_end30-_xtc_new_simd_i16
                                        // -- End function
	.globl	_xtc_new_simd_u32               // -- Begin function _xtc_new_simd_u32
	.p2align	2
	.type	_xtc_new_simd_u32,@function
_xtc_new_simd_u32:                      // @_xtc_new_simd_u32
// %bb.0:
	mov	w1, #4                          // =0x4
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end31:
	.size	_xtc_new_simd_u32, .Lrt_func_end31-_xtc_new_simd_u32
                                        // -- End function
	.globl	_xtc_new_simd_i32               // -- Begin function _xtc_new_simd_i32
	.p2align	2
	.type	_xtc_new_simd_i32,@function
_xtc_new_simd_i32:                      // @_xtc_new_simd_i32
// %bb.0:
	mov	w1, #4                          // =0x4
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end32:
	.size	_xtc_new_simd_i32, .Lrt_func_end32-_xtc_new_simd_i32
                                        // -- End function
	.globl	_xtc_new_simd_float             // -- Begin function _xtc_new_simd_float
	.p2align	2
	.type	_xtc_new_simd_float,@function
_xtc_new_simd_float:                    // @_xtc_new_simd_float
// %bb.0:
	mov	w1, #4                          // =0x4
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end33:
	.size	_xtc_new_simd_float, .Lrt_func_end33-_xtc_new_simd_float
                                        // -- End function
	.globl	_xtc_new_simd_u64               // -- Begin function _xtc_new_simd_u64
	.p2align	2
	.type	_xtc_new_simd_u64,@function
_xtc_new_simd_u64:                      // @_xtc_new_simd_u64
// %bb.0:
	mov	w1, #8                          // =0x8
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end34:
	.size	_xtc_new_simd_u64, .Lrt_func_end34-_xtc_new_simd_u64
                                        // -- End function
	.globl	_xtc_new_simd_i64               // -- Begin function _xtc_new_simd_i64
	.p2align	2
	.type	_xtc_new_simd_i64,@function
_xtc_new_simd_i64:                      // @_xtc_new_simd_i64
// %bb.0:
	mov	w1, #8                          // =0x8
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end35:
	.size	_xtc_new_simd_i64, .Lrt_func_end35-_xtc_new_simd_i64
                                        // -- End function
	.globl	_xtc_new_simd_double            // -- Begin function _xtc_new_simd_double
	.p2align	2
	.type	_xtc_new_simd_double,@function
_xtc_new_simd_double:                   // @_xtc_new_simd_double
// %bb.0:
	mov	w1, #8                          // =0x8
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end36:
	.size	_xtc_new_simd_double, .Lrt_func_end36-_xtc_new_simd_double
                                        // -- End function
	.globl	_xtc_new_simd_pointer           // -- Begin function _xtc_new_simd_pointer
	.p2align	2
	.type	_xtc_new_simd_pointer,@function
_xtc_new_simd_pointer:                  // @_xtc_new_simd_pointer
// %bb.0:
	mov	w1, #8                          // =0x8
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end37:
	.size	_xtc_new_simd_pointer, .Lrt_func_end37-_xtc_new_simd_pointer
                                        // -- End function
	.globl	_xtc_new_simd_string            // -- Begin function _xtc_new_simd_string
	.p2align	2
	.type	_xtc_new_simd_string,@function
_xtc_new_simd_string:                   // @_xtc_new_simd_string
// %bb.0:
	mov	w1, #8                          // =0x8
	mov	x2, xzr
	b	_xtc_alloc_aligned
.Lrt_func_end38:
	.size	_xtc_new_simd_string, .Lrt_func_end38-_xtc_new_simd_string
                                        // -- End function
	.globl	_xtc_count                      // -- Begin function _xtc_count
	.p2align	2
	.type	_xtc_count,@function
_xtc_count:                             // @_xtc_count
// %bb.0:
	ldur	x0, [x0, #-32]
	ret
.Lrt_func_end39:
	.size	_xtc_count, .Lrt_func_end39-_xtc_count
                                        // -- End function
	.globl	_xtc_dealloc                    // -- Begin function _xtc_dealloc
	.p2align	2
	.type	_xtc_dealloc,@function
_xtc_dealloc:                           // @_xtc_dealloc
// %bb.0:
	stp	x30, x23, [sp, #-48]!           // 16-byte Folded Spill
	stp	x20, x19, [sp, #32]             // 16-byte Folded Spill
	mov	x20, x0
	mov	w23, #20291                     // =0x4f43
	ldr	w8, [x20, #-8]!
	movk	w23, #22612, lsl #16
	add	w10, w23, #11
	mov	x19, x0
	stp	x22, x21, [sp, #16]             // 16-byte Folded Spill
	and	w9, w8, #0xfffffffe
	cmp	w9, w10
	b.ne	.Lrt_BB40_5
// %bb.1:
	add	w9, w23, #12
	cmp	w8, w9
	b.ne	.Lrt_BB40_3
// %bb.2:
	mov	x0, x19
	bl	_xtc_weak_zero_for
.Lrt_BB40_3:
	ldr	x8, [x19]
	ldr	x8, [x8, #24]
	cbz	x8, .Lrt_BB40_26
// %bb.4:
	mov	w9, #-2147483648                // =0x80000000
	mov	x0, x19
	stur	w9, [x19, #-4]
	blr	x8
	b	.Lrt_BB40_26
.Lrt_BB40_5:
	mov	x0, x19
	bl	_xtc_weak_zero_for
	mov	x20, x19
	ldr	x22, [x20, #-40]!
	ldr	w8, [x20, #32]
	ldr	x21, [x20, #16]
	cmp	w8, w23
	b.ne	.Lrt_BB40_23
// %bb.6:
	cbz	x21, .Lrt_BB40_8
// %bb.7:
	mov	x0, x19
	blr	x21
.Lrt_BB40_8:
	tst	x19, #0x3fff
	b.ne	.Lrt_BB40_22
// %bb.9:
	mov	x0, x19
	bl	_xtc_simd_unwatch
	adrp	x20, _xt_threads_active
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB40_11
// %bb.10:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB40_11:
	adrp	x8, xt_simd_n
	adrp	x11, xt_simd_tab
	mov	x10, xzr
	ldr	x9, [x8, :lo12:xt_simd_n]
	cbz	x9, .Lrt_BB40_14
// %bb.12:
	ldr	x12, [x11, :lo12:xt_simd_tab]
	mov	x13, x9
.Lrt_BB40_13:                              // =>This Inner Loop Header: Depth=1
	add	x14, x13, x10
	and	x15, x14, #0x1ffffffffffffffe
	lsr	x14, x14, #1
	ldr	x15, [x12, x15, lsl #3]
	cmp	x15, x19
	csel	x13, x14, x13, hi
	csinc	x10, x10, x14, hi
	cmp	x10, x13
	b.lo	.Lrt_BB40_13
.Lrt_BB40_14:
	cbz	x10, .Lrt_BB40_20
// %bb.15:
	ldr	x11, [x11, :lo12:xt_simd_tab]
	add	x11, x11, x10, lsl #4
	ldur	x12, [x11, #-16]
	cmp	x12, x19
	b.ne	.Lrt_BB40_20
// %bb.16:
	subs	x12, x9, x10
	b.ls	.Lrt_BB40_19
// %bb.17:
	adrp	x13, xt_simd_flag
	ldr	x13, [x13, :lo12:xt_simd_flag]
	add	x10, x13, x10
.Lrt_BB40_18:                              // =>This Inner Loop Header: Depth=1
	ldp	x13, x14, [x11]
	subs	x12, x12, #1
	stp	x13, x14, [x11, #-16]
	add	x11, x11, #16
	ldrb	w13, [x10]
	sturb	w13, [x10, #-1]
	add	x10, x10, #1
	b.ne	.Lrt_BB40_18
.Lrt_BB40_19:
	sub	x9, x9, #1
	str	x9, [x8, :lo12:xt_simd_n]
.Lrt_BB40_20:
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB40_22
// %bb.21:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_unlock
.Lrt_BB40_22:
	ldur	x20, [x19, #-48]
	b	.Lrt_BB40_26
.Lrt_BB40_23:
	cbz	x21, .Lrt_BB40_26
// %bb.24:
	ldr	x23, [x20, #8]
	mov	w8, #-2147483648                // =0x80000000
	stur	w8, [x19, #-4]
	cbz	x23, .Lrt_BB40_26
.Lrt_BB40_25:                              // =>This Inner Loop Header: Depth=1
	mov	x0, x19
	blr	x21
	subs	x23, x23, #1
	add	x19, x19, x22
	b.ne	.Lrt_BB40_25
.Lrt_BB40_26:
	mov	x0, x20
	ldp	x20, x19, [sp, #32]             // 16-byte Folded Reload
	ldp	x22, x21, [sp, #16]             // 16-byte Folded Reload
	ldp	x30, x23, [sp], #48             // 16-byte Folded Reload
	b	free
.Lrt_func_end40:
	.size	_xtc_dealloc, .Lrt_func_end40-_xtc_dealloc
                                        // -- End function
	.globl	_xtc_weak_zero_for              // -- Begin function _xtc_weak_zero_for
	.p2align	2
	.type	_xtc_weak_zero_for,@function
_xtc_weak_zero_for:                     // @_xtc_weak_zero_for
// %bb.0:
	cbz	x0, .Lrt_BB41_18
// %bb.1:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	adrp	x20, _xt_threads_active
	mov	x19, x0
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB41_3
// %bb.2:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB41_3:
	mov	w8, #20290                      // =0x4f42
	ldur	w9, [x19, #-8]
	mov	w10, #13                        // =0xd
	movk	w8, #22612, lsl #16
	orr	w10, w8, w10
	cmp	w9, w10
	b.ne	.Lrt_BB41_8
// %bb.4:
	adrp	x8, xt_wtab_cap
	ldr	x8, [x8, :lo12:xt_wtab_cap]
	cbz	x8, .Lrt_BB41_12
// %bb.5:
	lsr	x9, x19, #3
	mov	w10, #54459                     // =0xd4bb
	sub	x8, x8, #1
	movk	w10, #60762, lsl #16
	mov	w12, #1                         // =0x1
	eor	x9, x9, x19, lsr #20
	mul	x9, x9, x10
	adrp	x10, xt_wtab
	ldr	x10, [x10, :lo12:xt_wtab]
	eor	x9, x9, x9, lsr #11
	and	x11, x8, x9
                                        // implicit-def: $x9
.Lrt_BB41_6:                               // =>This Inner Loop Header: Depth=1
	add	x13, x10, x11, lsl #4
	add	x15, x11, #1
	and	x15, x15, x8
	ldr	x14, [x13]
	cmp	x14, #0
	csel	x15, x11, x15, eq
	csel	x9, xzr, x9, eq
	csel	w16, wzr, w12, eq
	cmp	x14, x19
	csel	w14, wzr, w16, eq
	csel	x11, x11, x15, eq
	csel	x9, x13, x9, eq
	tbnz	w14, #0, .Lrt_BB41_6
// %bb.7:
	cbnz	x9, .Lrt_BB41_13
	b	.Lrt_BB41_16
.Lrt_BB41_8:
	and	w9, w9, #0xfffffffe
	cmp	w9, w8
	b.ne	.Lrt_BB41_16
// %bb.9:
	ldur	x8, [x19, #-16]
	cbz	x8, .Lrt_BB41_11
.Lrt_BB41_10:                              // =>This Inner Loop Header: Depth=1
	ldur	x9, [x8, #-8]
	stp	xzr, xzr, [x8, #-8]
	stur	xzr, [x8, #-16]
	mov	x8, x9
	cbnz	x9, .Lrt_BB41_10
.Lrt_BB41_11:
	stur	xzr, [x19, #-16]
	b	.Lrt_BB41_16
.Lrt_BB41_12:
	mov	x9, xzr
	cbz	x9, .Lrt_BB41_16
.Lrt_BB41_13:
	mov	w10, #1                         // =0x1
	ldr	x8, [x9, #8]
	adrp	x11, xt_wtab_n
	stp	x10, xzr, [x9]
	ldr	x10, [x11, :lo12:xt_wtab_n]
	ldr	x9, [x8]
	sub	x10, x10, #1
	str	x10, [x11, :lo12:xt_wtab_n]
	cbz	x9, .Lrt_BB41_15
.Lrt_BB41_14:                              // =>This Inner Loop Header: Depth=1
	ldur	x10, [x9, #-8]
	stp	xzr, xzr, [x9, #-8]
	stur	xzr, [x9, #-16]
	mov	x9, x10
	cbnz	x10, .Lrt_BB41_14
.Lrt_BB41_15:
	str	xzr, [x8]
	adrp	x9, xt_wcell_free
	ldr	x10, [x9, :lo12:xt_wcell_free]
	str	x10, [x8]
	str	x8, [x9, :lo12:xt_wcell_free]
.Lrt_BB41_16:
	ldr	w8, [x20, :lo12:_xt_threads_active]
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	cbz	w8, .Lrt_BB41_18
// %bb.17:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	b	pthread_mutex_unlock
.Lrt_BB41_18:
	ret
.Lrt_func_end41:
	.size	_xtc_weak_zero_for, .Lrt_func_end41-_xtc_weak_zero_for
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
	cbz	w8, .Lrt_BB42_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB42_2:
	mov	x8, x19
	ldr	x9, [x8, #-16]!
	cbz	x9, .Lrt_BB42_7
// %bb.3:
	ldr	x10, [x9]
	cmp	x10, x19
	b.ne	.Lrt_BB42_6
// %bb.4:
	ldur	x10, [x19, #-8]
	str	x10, [x9]
	cbz	x10, .Lrt_BB42_6
// %bb.5:
	stur	x9, [x10, #-16]
.Lrt_BB42_6:
	stp	xzr, xzr, [x8]
.Lrt_BB42_7:
	ldr	w8, [x20, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB42_9
// %bb.8:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	b	pthread_mutex_unlock
.Lrt_BB42_9:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end42:
	.size	_xtc_weak_unregister, .Lrt_func_end42-_xtc_weak_unregister
                                        // -- End function
	.globl	_xtc_weak_register              // -- Begin function _xtc_weak_register
	.p2align	2
	.type	_xtc_weak_register,@function
_xtc_weak_register:                     // @_xtc_weak_register
// %bb.0:
	str	x30, [sp, #-64]!                // 8-byte Folded Spill
	stp	x22, x21, [sp, #32]             // 16-byte Folded Spill
	adrp	x22, _xt_threads_active
	ldr	w8, [x22, :lo12:_xt_threads_active]
	stp	x20, x19, [sp, #48]             // 16-byte Folded Spill
	mov	x20, x1
	mov	x19, x0
	stp	x24, x23, [sp, #16]             // 16-byte Folded Spill
	cbz	w8, .Lrt_BB43_2
// %bb.1:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB43_2:
	mov	x8, x19
	ldr	x9, [x8, #-16]!
	cbz	x9, .Lrt_BB43_7
// %bb.3:
	ldr	x10, [x9]
	cmp	x10, x19
	b.ne	.Lrt_BB43_6
// %bb.4:
	ldur	x10, [x19, #-8]
	str	x10, [x9]
	cbz	x10, .Lrt_BB43_6
// %bb.5:
	stur	x9, [x10, #-16]
.Lrt_BB43_6:
	stp	xzr, xzr, [x8]
.Lrt_BB43_7:
	cbz	x20, .Lrt_BB43_13
// %bb.8:
	ldur	w8, [x20, #-8]
	mov	w10, #20302                     // =0x4f4e
	movk	w10, #22612, lsl #16
	and	w9, w8, #0xfffffffe
	cmp	w9, w10
	b.eq	.Lrt_BB43_18
// %bb.9:
	mov	w8, #20290                      // =0x4f42
	movk	w8, #22612, lsl #16
	cmp	w9, w8
	b.ne	.Lrt_BB43_13
// %bb.10:
	sub	x21, x20, #16
	cbnz	x21, .Lrt_BB43_14
.Lrt_BB43_11:
	ldr	w8, [x22, :lo12:_xt_threads_active]
	cbnz	w8, .Lrt_BB43_17
.Lrt_BB43_12:
	ldp	x20, x19, [sp, #48]             // 16-byte Folded Reload
	ldp	x22, x21, [sp, #32]             // 16-byte Folded Reload
	ldp	x24, x23, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #64                  // 8-byte Folded Reload
	ret
.Lrt_BB43_13:
	mov	x21, xzr
	cbz	x21, .Lrt_BB43_11
.Lrt_BB43_14:
	ldr	x8, [x21]
	mov	x9, x19
	str	x8, [x9, #-8]!
	stur	x21, [x9, #-8]
	cbz	x8, .Lrt_BB43_16
// %bb.15:
	stur	x9, [x8, #-16]
.Lrt_BB43_16:
	ldr	w8, [x22, :lo12:_xt_threads_active]
	str	x19, [x21]
	cbz	w8, .Lrt_BB43_12
.Lrt_BB43_17:
	ldp	x20, x19, [sp, #48]             // 16-byte Folded Reload
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	ldp	x22, x21, [sp, #32]             // 16-byte Folded Reload
	ldp	x24, x23, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #64                  // 8-byte Folded Reload
	b	pthread_mutex_unlock
.Lrt_BB43_18:
	mov	w23, #20303                     // =0x4f4f
	movk	w23, #22612, lsl #16
	cmp	w8, w23
	b.ne	.Lrt_BB43_24
// %bb.19:
	adrp	x8, xt_wtab_cap
	ldr	x8, [x8, :lo12:xt_wtab_cap]
	cbz	x8, .Lrt_BB43_31
// %bb.20:
	lsr	x9, x20, #3
	mov	w10, #54459                     // =0xd4bb
	sub	x8, x8, #1
	movk	w10, #60762, lsl #16
	mov	w11, #1                         // =0x1
                                        // implicit-def: $x12
	eor	x9, x9, x20, lsr #20
	mul	x9, x9, x10
	eor	x10, x9, x9, lsr #11
	adrp	x9, xt_wtab
	ldr	x9, [x9, :lo12:xt_wtab]
	and	x10, x8, x10
.Lrt_BB43_21:                              // =>This Inner Loop Header: Depth=1
	add	x13, x9, x10, lsl #4
	add	x15, x10, #1
	and	x15, x15, x8
	ldr	x14, [x13]
	cmp	x14, #0
	csel	x15, x10, x15, eq
	csel	x12, xzr, x12, eq
	csel	w16, wzr, w11, eq
	cmp	x14, x20
	csel	w14, wzr, w16, eq
	csel	x10, x10, x15, eq
	csel	x12, x13, x12, eq
	tbnz	w14, #0, .Lrt_BB43_21
// %bb.22:
	cbz	x12, .Lrt_BB43_25
.Lrt_BB43_23:
	ldr	x21, [x12, #8]
	cbnz	x21, .Lrt_BB43_14
	b	.Lrt_BB43_11
.Lrt_BB43_24:
	mov	x12, xzr
	cbnz	x12, .Lrt_BB43_23
.Lrt_BB43_25:
	adrp	x24, xt_wcell_free
	ldr	x8, [x24, :lo12:xt_wcell_free]
	cbnz	x8, .Lrt_BB43_30
// %bb.26:
	mov	w0, #512                        // =0x200
	mov	w1, #8                          // =0x8
	bl	calloc
	cbz	x0, .Lrt_BB43_32
// %bb.27:
	mov	x8, xzr
.Lrt_BB43_28:                              // =>This Inner Loop Header: Depth=1
	add	x9, x0, x8
	add	x8, x8, #8
	add	x10, x9, #8
	cmp	x8, #4088
	str	x10, [x9]
	b.ne	.Lrt_BB43_28
// %bb.29:
	str	xzr, [x0, #4088]
	str	x0, [x24, :lo12:xt_wcell_free]
.Lrt_BB43_30:
	ldr	x21, [x24, :lo12:xt_wcell_free]
	mov	x0, x20
	ldr	x8, [x21]
	mov	x1, x21
	str	x8, [x24, :lo12:xt_wcell_free]
	str	xzr, [x21]
	bl	xt_wtab_put
	stur	w23, [x20, #-8]
	cbnz	x21, .Lrt_BB43_14
	b	.Lrt_BB43_11
.Lrt_BB43_31:
	mov	x12, xzr
	cbnz	x12, .Lrt_BB43_23
	b	.Lrt_BB43_25
.Lrt_BB43_32:
	adrp	x8, :got:stderr
	adrp	x0, .Lrt_.str.8
	add	x0, x0, :lo12:.Lrt_.str.8
	ldr	x8, [x8, :got_lo12:stderr]
	mov	w1, #37                         // =0x25
	mov	w2, #1                          // =0x1
	ldr	x3, [x8]
	bl	fwrite
	bl	abort
.Lrt_func_end43:
	.size	_xtc_weak_register, .Lrt_func_end43-_xtc_weak_register
                                        // -- End function
	.globl	_xtc_weak_load                  // -- Begin function _xtc_weak_load
	.p2align	2
	.type	_xtc_weak_load,@function
_xtc_weak_load:                         // @_xtc_weak_load
// %bb.0:
	ldr	x0, [x0]
	ret
.Lrt_func_end44:
	.size	_xtc_weak_load, .Lrt_func_end44-_xtc_weak_load
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
.Lrt_func_end45:
	.size	_putc, .Lrt_func_end45-_putc
                                        // -- End function
	.globl	_xtc_pf                         // -- Begin function _xtc_pf
	.p2align	2
	.type	_xtc_pf,@function
_xtc_pf:                                // @_xtc_pf
// %bb.0:
	sub	sp, sp, #80
	fcvt	d0, s0
	adrp	x2, .Lrt_.str.2
	add	x2, x2, :lo12:.Lrt_.str.2
	mov	x0, sp
	mov	w1, #64                         // =0x40
	stp	x30, x19, [sp, #64]             // 16-byte Folded Spill
	mov	x19, sp
	bl	snprintf
	mov	x8, xzr
.Lrt_BB46_1:                               // =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, .Lrt_BB46_1
// %bb.2:
	sub	x2, x8, #1
	mov	x1, sp
	mov	w0, #1                          // =0x1
	bl	write
	ldp	x30, x19, [sp, #64]             // 16-byte Folded Reload
	add	sp, sp, #80
	ret
.Lrt_func_end46:
	.size	_xtc_pf, .Lrt_func_end46-_xtc_pf
                                        // -- End function
	.globl	_xtc_pd                         // -- Begin function _xtc_pd
	.p2align	2
	.type	_xtc_pd,@function
_xtc_pd:                                // @_xtc_pd
// %bb.0:
	sub	sp, sp, #80
	adrp	x2, .Lrt_.str.3
	add	x2, x2, :lo12:.Lrt_.str.3
	mov	x0, sp
	mov	w1, #64                         // =0x40
	stp	x30, x19, [sp, #64]             // 16-byte Folded Spill
	mov	x19, sp
	bl	snprintf
	mov	x8, xzr
.Lrt_BB47_1:                               // =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, .Lrt_BB47_1
// %bb.2:
	sub	x2, x8, #1
	mov	x1, sp
	mov	w0, #1                          // =0x1
	bl	write
	ldp	x30, x19, [sp, #64]             // 16-byte Folded Reload
	add	sp, sp, #80
	ret
.Lrt_func_end47:
	.size	_xtc_pd, .Lrt_func_end47-_xtc_pd
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
	b.eq	.Lrt_BB48_7
// %bb.1:
	and	w8, w0, #0xff
	adrp	x2, .Lrt_.str.9
	add	x2, x2, :lo12:.Lrt_.str.9
	mov	x0, sp
	add	w3, w8, #1
	mov	w1, #64                         // =0x40
	mov	x19, sp
	bl	snprintf
	mov	x8, xzr
.Lrt_BB48_2:                               // =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, .Lrt_BB48_2
// %bb.3:
	cmp	x8, #1
	b.eq	.Lrt_BB48_5
// %bb.4:
	mov	x9, sp
	add	x8, x9, x8
	sturb	wzr, [x8, #-2]
.Lrt_BB48_5:
	mov	x8, xzr
	mov	x9, sp
.Lrt_BB48_6:                               // =>This Inner Loop Header: Depth=1
	ldrb	w10, [x9, x8]
	add	x8, x8, #1
	cbnz	w10, .Lrt_BB48_6
	b	.Lrt_BB48_9
.Lrt_BB48_7:
	adrp	x2, .Lrt_.str.2
	add	x2, x2, :lo12:.Lrt_.str.2
	mov	x0, sp
	mov	w1, #64                         // =0x40
	mov	x19, sp
	bl	snprintf
	mov	x8, xzr
.Lrt_BB48_8:                               // =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, .Lrt_BB48_8
.Lrt_BB48_9:
	sub	x2, x8, #1
	mov	x1, sp
	mov	w0, #1                          // =0x1
	bl	write
	ldp	x30, x19, [sp, #64]             // 16-byte Folded Reload
	add	sp, sp, #80
	ret
.Lrt_func_end48:
	.size	_xtc_pfp, .Lrt_func_end48-_xtc_pfp
                                        // -- End function
	.globl	_xtc_pdp                        // -- Begin function _xtc_pdp
	.p2align	2
	.type	_xtc_pdp,@function
_xtc_pdp:                               // @_xtc_pdp
// %bb.0:
	sub	sp, sp, #80
	tst	w0, #0xff
	stp	x30, x19, [sp, #64]             // 16-byte Folded Spill
	b.eq	.Lrt_BB49_7
// %bb.1:
	and	w8, w0, #0xff
	adrp	x2, .Lrt_.str.9
	add	x2, x2, :lo12:.Lrt_.str.9
	mov	x0, sp
	add	w3, w8, #1
	mov	w1, #64                         // =0x40
	mov	x19, sp
	bl	snprintf
	mov	x8, xzr
.Lrt_BB49_2:                               // =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, .Lrt_BB49_2
// %bb.3:
	cmp	x8, #1
	b.eq	.Lrt_BB49_5
// %bb.4:
	mov	x9, sp
	add	x8, x9, x8
	sturb	wzr, [x8, #-2]
.Lrt_BB49_5:
	mov	x8, xzr
	mov	x9, sp
.Lrt_BB49_6:                               // =>This Inner Loop Header: Depth=1
	ldrb	w10, [x9, x8]
	add	x8, x8, #1
	cbnz	w10, .Lrt_BB49_6
	b	.Lrt_BB49_9
.Lrt_BB49_7:
	adrp	x2, .Lrt_.str.3
	add	x2, x2, :lo12:.Lrt_.str.3
	mov	x0, sp
	mov	w1, #64                         // =0x40
	mov	x19, sp
	bl	snprintf
	mov	x8, xzr
.Lrt_BB49_8:                               // =>This Inner Loop Header: Depth=1
	ldrb	w9, [x19, x8]
	add	x8, x8, #1
	cbnz	w9, .Lrt_BB49_8
.Lrt_BB49_9:
	sub	x2, x8, #1
	mov	x1, sp
	mov	w0, #1                          // =0x1
	bl	write
	ldp	x30, x19, [sp, #64]             // 16-byte Folded Reload
	add	sp, sp, #80
	ret
.Lrt_func_end49:
	.size	_xtc_pdp, .Lrt_func_end49-_xtc_pdp
                                        // -- End function
	.globl	_xm_sqrtf                       // -- Begin function _xm_sqrtf
	.p2align	2
	.type	_xm_sqrtf,@function
_xm_sqrtf:                              // @_xm_sqrtf
// %bb.0:
	fsqrt	s1, s0
	fcmp	s1, s1
	b.vs	.Lrt_BB50_2
// %bb.1:
	fmov	s0, s1
	ret
.Lrt_BB50_2:
	b	sqrtf
.Lrt_func_end50:
	.size	_xm_sqrtf, .Lrt_func_end50-_xm_sqrtf
                                        // -- End function
	.globl	_xm_sqrt                        // -- Begin function _xm_sqrt
	.p2align	2
	.type	_xm_sqrt,@function
_xm_sqrt:                               // @_xm_sqrt
// %bb.0:
	fsqrt	d1, d0
	fcmp	d1, d1
	b.vs	.Lrt_BB51_2
// %bb.1:
	fmov	d0, d1
	ret
.Lrt_BB51_2:
	b	sqrt
.Lrt_func_end51:
	.size	_xm_sqrt, .Lrt_func_end51-_xm_sqrt
                                        // -- End function
	.globl	_xm_sinf                        // -- Begin function _xm_sinf
	.p2align	2
	.type	_xm_sinf,@function
_xm_sinf:                               // @_xm_sinf
// %bb.0:
	b	sinf
.Lrt_func_end52:
	.size	_xm_sinf, .Lrt_func_end52-_xm_sinf
                                        // -- End function
	.globl	_xm_sin                         // -- Begin function _xm_sin
	.p2align	2
	.type	_xm_sin,@function
_xm_sin:                                // @_xm_sin
// %bb.0:
	b	sin
.Lrt_func_end53:
	.size	_xm_sin, .Lrt_func_end53-_xm_sin
                                        // -- End function
	.globl	_xm_cosf                        // -- Begin function _xm_cosf
	.p2align	2
	.type	_xm_cosf,@function
_xm_cosf:                               // @_xm_cosf
// %bb.0:
	b	cosf
.Lrt_func_end54:
	.size	_xm_cosf, .Lrt_func_end54-_xm_cosf
                                        // -- End function
	.globl	_xm_cos                         // -- Begin function _xm_cos
	.p2align	2
	.type	_xm_cos,@function
_xm_cos:                                // @_xm_cos
// %bb.0:
	b	cos
.Lrt_func_end55:
	.size	_xm_cos, .Lrt_func_end55-_xm_cos
                                        // -- End function
	.globl	_xm_tanf                        // -- Begin function _xm_tanf
	.p2align	2
	.type	_xm_tanf,@function
_xm_tanf:                               // @_xm_tanf
// %bb.0:
	b	tanf
.Lrt_func_end56:
	.size	_xm_tanf, .Lrt_func_end56-_xm_tanf
                                        // -- End function
	.globl	_xm_tan                         // -- Begin function _xm_tan
	.p2align	2
	.type	_xm_tan,@function
_xm_tan:                                // @_xm_tan
// %bb.0:
	b	tan
.Lrt_func_end57:
	.size	_xm_tan, .Lrt_func_end57-_xm_tan
                                        // -- End function
	.globl	_xm_atanf                       // -- Begin function _xm_atanf
	.p2align	2
	.type	_xm_atanf,@function
_xm_atanf:                              // @_xm_atanf
// %bb.0:
	b	atanf
.Lrt_func_end58:
	.size	_xm_atanf, .Lrt_func_end58-_xm_atanf
                                        // -- End function
	.globl	_xm_atan                        // -- Begin function _xm_atan
	.p2align	2
	.type	_xm_atan,@function
_xm_atan:                               // @_xm_atan
// %bb.0:
	b	atan
.Lrt_func_end59:
	.size	_xm_atan, .Lrt_func_end59-_xm_atan
                                        // -- End function
	.globl	_xm_lnf                         // -- Begin function _xm_lnf
	.p2align	2
	.type	_xm_lnf,@function
_xm_lnf:                                // @_xm_lnf
// %bb.0:
	b	logf
.Lrt_func_end60:
	.size	_xm_lnf, .Lrt_func_end60-_xm_lnf
                                        // -- End function
	.globl	_xm_ln                          // -- Begin function _xm_ln
	.p2align	2
	.type	_xm_ln,@function
_xm_ln:                                 // @_xm_ln
// %bb.0:
	b	log
.Lrt_func_end61:
	.size	_xm_ln, .Lrt_func_end61-_xm_ln
                                        // -- End function
	.globl	_xm_expf                        // -- Begin function _xm_expf
	.p2align	2
	.type	_xm_expf,@function
_xm_expf:                               // @_xm_expf
// %bb.0:
	b	expf
.Lrt_func_end62:
	.size	_xm_expf, .Lrt_func_end62-_xm_expf
                                        // -- End function
	.globl	_xm_exp                         // -- Begin function _xm_exp
	.p2align	2
	.type	_xm_exp,@function
_xm_exp:                                // @_xm_exp
// %bb.0:
	b	exp
.Lrt_func_end63:
	.size	_xm_exp, .Lrt_func_end63-_xm_exp
                                        // -- End function
	.globl	_xm_powf                        // -- Begin function _xm_powf
	.p2align	2
	.type	_xm_powf,@function
_xm_powf:                               // @_xm_powf
// %bb.0:
	b	powf
.Lrt_func_end64:
	.size	_xm_powf, .Lrt_func_end64-_xm_powf
                                        // -- End function
	.globl	_xm_pow                         // -- Begin function _xm_pow
	.p2align	2
	.type	_xm_pow,@function
_xm_pow:                                // @_xm_pow
// %bb.0:
	b	pow
.Lrt_func_end65:
	.size	_xm_pow, .Lrt_func_end65-_xm_pow
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
.Lrt_func_end66:
	.size	_xt_srand, .Lrt_func_end66-_xt_srand
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
	tbnz	w8, #0, .Lrt_BB67_2
// %bb.1:
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	bl	srandom
	strb	w20, [x19, :lo12:xt_rand_seeded]
.Lrt_BB67_2:
	bl	random
	mov	x19, x0
	bl	random
	eor	w0, w0, w19, lsl #16
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end67:
	.size	_xt_rand_u32, .Lrt_func_end67-_xt_rand_u32
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
	tbnz	w8, #0, .Lrt_BB68_2
// %bb.1:
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	bl	srandom
	strb	w20, [x19, :lo12:xt_rand_seeded]
.Lrt_BB68_2:
	bl	random
	scvtf	s0, x0, #31
	fmov	s1, #0.50000000
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	fmadd	s0, s0, s1, s1
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end68:
	.size	_xt_rand_f, .Lrt_func_end68-_xt_rand_f
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
	tbnz	w8, #0, .Lrt_BB69_2
// %bb.1:
	mov	w0, #1                          // =0x1
	mov	w20, #1                         // =0x1
	bl	srandom
	strb	w20, [x19, :lo12:xt_rand_seeded]
.Lrt_BB69_2:
	bl	random
	scvtf	d0, x0, #31
	fmov	d1, #0.50000000
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	fmadd	d0, d0, d1, d1
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end69:
	.size	_xt_rand_d, .Lrt_func_end69-_xt_rand_d
                                        // -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          // -- Begin function _xt_clk_reset
.Lrt_CPI70_0:
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
	adrp	x8, .Lrt_CPI70_0
	ldr	d2, [x8, :lo12:.Lrt_CPI70_0]
	adrp	x8, xt_clk_origin
	ldr	x30, [sp, #16]                  // 8-byte Folded Reload
	scvtf	d0, d0
	scvtf	d1, d1
	fmadd	d0, d1, d2, d0
	str	d0, [x8, :lo12:xt_clk_origin]
	add	sp, sp, #32
	ret
.Lrt_func_end70:
	.size	_xt_clk_reset, .Lrt_func_end70-_xt_clk_reset
                                        // -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          // -- Begin function _xt_clk_ticks
.Lrt_CPI71_0:
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
	adrp	x8, .Lrt_CPI71_0
	ldr	d2, [x8, :lo12:.Lrt_CPI71_0]
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
.Lrt_func_end71:
	.size	_xt_clk_ticks, .Lrt_func_end71-_xt_clk_ticks
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
.Lrt_func_end72:
	.size	_xt_clk_delay, .Lrt_func_end72-_xt_clk_delay
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
	b.ls	.Lrt_BB73_2
// %bb.1:
	mov	x0, xzr
	ret
.Lrt_BB73_2:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	and	x8, x0, #0xff
	adrp	x9, _xtc_bank_regions
	add	x9, x9, :lo12:_xtc_bank_regions
	add	x8, x9, x8, lsl #11
	add	x19, x8, w1, uxtb #3
	ldr	x8, [x19]
	cbnz	x8, .Lrt_BB73_4
// %bb.3:
	mov	w0, #1                          // =0x1
	mov	w1, #12288                      // =0x3000
	bl	calloc
	str	x0, [x19]
.Lrt_BB73_4:
	ldr	x0, [x19]
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	ret
.Lrt_func_end73:
	.size	_xtc_bank, .Lrt_func_end73-_xtc_bank
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
.Lrt_BB74_1:                               // =>This Inner Loop Header: Depth=1
	ldr	x8, [x20, x19, lsl #3]
	cbz	x8, .Lrt_BB74_3
// %bb.2:                               //   in Loop: Header=BB74_1 Depth=1
	add	x19, x19, #1
	cmp	x19, #8
	b.ne	.Lrt_BB74_1
	b	.Lrt_BB74_5
.Lrt_BB74_3:
	bl	fopen
	cbz	x0, .Lrt_BB74_5
// %bb.4:
	str	x0, [x20, x19, lsl #3]
	b	.Lrt_BB74_6
.Lrt_BB74_5:
	mov	w19, #-1                        // =0xffffffff
.Lrt_BB74_6:
	mov	w0, w19
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end74:
	.size	_xt_file_open, .Lrt_func_end74-_xt_file_open
                                        // -- End function
	.globl	_xt_file_read                   // -- Begin function _xt_file_read
	.p2align	2
	.type	_xt_file_read,@function
_xt_file_read:                          // @_xt_file_read
// %bb.0:
	cmp	w0, #7
	b.hi	.Lrt_BB75_3
// %bb.1:
	adrp	x8, xt_files
	add	x8, x8, :lo12:xt_files
	ldr	x3, [x8, w0, uxtw #3]
	cbz	x3, .Lrt_BB75_3
// %bb.2:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	mov	w2, w2
	mov	x0, x1
	mov	w1, #1                          // =0x1
	bl	fread
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
                                        // kill: def $w0 killed $w0 killed $x0
	ret
.Lrt_BB75_3:
	mov	w0, #-1                         // =0xffffffff
                                        // kill: def $w0 killed $w0 killed $x0
	ret
.Lrt_func_end75:
	.size	_xt_file_read, .Lrt_func_end75-_xt_file_read
                                        // -- End function
	.globl	_xt_file_write                  // -- Begin function _xt_file_write
	.p2align	2
	.type	_xt_file_write,@function
_xt_file_write:                         // @_xt_file_write
// %bb.0:
	cmp	w0, #7
	b.hi	.Lrt_BB76_3
// %bb.1:
	adrp	x8, xt_files
	add	x8, x8, :lo12:xt_files
	ldr	x3, [x8, w0, uxtw #3]
	cbz	x3, .Lrt_BB76_3
// %bb.2:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	mov	w2, w2
	mov	x0, x1
	mov	w1, #1                          // =0x1
	bl	fwrite
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
                                        // kill: def $w0 killed $w0 killed $x0
	ret
.Lrt_BB76_3:
	mov	w0, #-1                         // =0xffffffff
                                        // kill: def $w0 killed $w0 killed $x0
	ret
.Lrt_func_end76:
	.size	_xt_file_write, .Lrt_func_end76-_xt_file_write
                                        // -- End function
	.globl	_xt_file_close                  // -- Begin function _xt_file_close
	.p2align	2
	.type	_xt_file_close,@function
_xt_file_close:                         // @_xt_file_close
// %bb.0:
	cmp	w0, #7
	b.hi	.Lrt_BB77_4
// %bb.1:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	adrp	x19, xt_files
	add	x19, x19, :lo12:xt_files
	ldr	x8, [x19, w0, uxtw #3]
	cbz	x8, .Lrt_BB77_3
// %bb.2:
	mov	w20, w0
	mov	x0, x8
	bl	fclose
	str	xzr, [x19, w20, uxtw #3]
.Lrt_BB77_3:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
.Lrt_BB77_4:
	ret
.Lrt_func_end77:
	.size	_xt_file_close, .Lrt_func_end77-_xt_file_close
                                        // -- End function
	.globl	_xt_file_size                   // -- Begin function _xt_file_size
	.p2align	2
	.type	_xt_file_size,@function
_xt_file_size:                          // @_xt_file_size
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	adrp	x1, .Lrt_.str.4
	add	x1, x1, :lo12:.Lrt_.str.4
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	bl	fopen
	cbz	x0, .Lrt_BB78_3
// %bb.1:
	mov	x1, xzr
	mov	w2, #2                          // =0x2
	mov	x19, x0
	bl	fseek
	cbz	w0, .Lrt_BB78_4
// %bb.2:
	mov	x0, x19
	bl	fclose
.Lrt_BB78_3:
	mov	w0, #-1                         // =0xffffffff
	b	.Lrt_BB78_5
.Lrt_BB78_4:
	mov	x0, x19
	bl	ftell
	mov	x20, x0
	mov	x0, x19
	bl	fclose
	cmp	x20, #0
	csinv	w0, w20, wzr, ge
.Lrt_BB78_5:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end78:
	.size	_xt_file_size, .Lrt_func_end78-_xt_file_size
                                        // -- End function
	.globl	_xt_file_exists                 // -- Begin function _xt_file_exists
	.p2align	2
	.type	_xt_file_exists,@function
_xt_file_exists:                        // @_xt_file_exists
// %bb.0:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	adrp	x1, .Lrt_.str.4
	add	x1, x1, :lo12:.Lrt_.str.4
	bl	fopen
	cbz	x0, .Lrt_BB79_2
// %bb.1:
	bl	fclose
	mov	w0, #1                          // =0x1
.Lrt_BB79_2:
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
	ret
.Lrt_func_end79:
	.size	_xt_file_exists, .Lrt_func_end79-_xt_file_exists
                                        // -- End function
	.globl	_xt_getenv                      // -- Begin function _xt_getenv
	.p2align	2
	.type	_xt_getenv,@function
_xt_getenv:                             // @_xt_getenv
// %bb.0:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	bl	getenv
	cmp	x0, #0
	adrp	x8, .Lrt_.str.5
	add	x8, x8, :lo12:.Lrt_.str.5
	csel	x0, x8, x0, eq
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
	ret
.Lrt_func_end80:
	.size	_xt_getenv, .Lrt_func_end80-_xt_getenv
                                        // -- End function
	.globl	_xt_mkdir                       // -- Begin function _xt_mkdir
	.p2align	2
	.type	_xt_mkdir,@function
_xt_mkdir:                              // @_xt_mkdir
// %bb.0:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	mov	w1, #448                        // =0x1c0
	bl	mkdir
	cbz	w0, .Lrt_BB81_2
// %bb.1:
	bl	__errno_location
	ldr	w8, [x0]
	cmp	w8, #17
	cset	w0, eq
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
	ret
.Lrt_BB81_2:
	mov	w0, #1                          // =0x1
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
	ret
.Lrt_func_end81:
	.size	_xt_mkdir, .Lrt_func_end81-_xt_mkdir
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
.Lrt_func_end82:
	.size	_xt_file_chmod_exec, .Lrt_func_end82-_xt_file_chmod_exec
                                        // -- End function
	.globl	_xt_stack_guard_init            // -- Begin function _xt_stack_guard_init
	.p2align	2
	.type	_xt_stack_guard_init,@function
_xt_stack_guard_init:                   // @_xt_stack_guard_init
// %bb.0:
	stp	x30, xzr, [sp, #-16]!           // 8-byte Folded Spill
	add	x0, sp, #8
	mov	w1, #8                          // =0x8
	bl	arc4random_buf
	ldr	x8, [sp, #8]
	mov	x9, #1392508928                 // =0x53000000
	movk	x9, #17227, lsl #32
	ands	x8, x8, #0xffffffffffffff00
	movk	x9, #22612, lsl #48
	csel	x8, x9, x8, eq
	adrp	x9, __xt_stack_guard
	str	x8, [x9, :lo12:__xt_stack_guard]
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
	ret
.Lrt_func_end83:
	.size	_xt_stack_guard_init, .Lrt_func_end83-_xt_stack_guard_init
                                        // -- End function
	.globl	__xt_stack_fail                 // -- Begin function __xt_stack_fail
	.p2align	2
	.type	__xt_stack_fail,@function
__xt_stack_fail:                        // @__xt_stack_fail
// %bb.0:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	adrp	x8, :got:stderr
	adrp	x0, .Lrt_.str.6
	add	x0, x0, :lo12:.Lrt_.str.6
	ldr	x8, [x8, :got_lo12:stderr]
	mov	w1, #70                         // =0x46
	mov	w2, #1                          // =0x1
	ldr	x3, [x8]
	bl	fwrite
	bl	abort
.Lrt_func_end84:
	.size	__xt_stack_fail, .Lrt_func_end84-__xt_stack_fail
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
.Lrt_func_end85:
	.size	_xt_set_args, .Lrt_func_end85-_xt_set_args
                                        // -- End function
	.globl	_xt_argc                        // -- Begin function _xt_argc
	.p2align	2
	.type	_xt_argc,@function
_xt_argc:                               // @_xt_argc
// %bb.0:
	adrp	x8, xt_argc_v
	ldr	w0, [x8, :lo12:xt_argc_v]
	ret
.Lrt_func_end86:
	.size	_xt_argc, .Lrt_func_end86-_xt_argc
                                        // -- End function
	.globl	_xt_argv                        // -- Begin function _xt_argv
	.p2align	2
	.type	_xt_argv,@function
_xt_argv:                               // @_xt_argv
// %bb.0:
	tbnz	w0, #31, .Lrt_BB87_4
// %bb.1:
	adrp	x9, xt_argc_v
	mov	w8, w0
	ldr	w9, [x9, :lo12:xt_argc_v]
	cmp	w9, w0
	adrp	x0, .Lrt_.str.5
	add	x0, x0, :lo12:.Lrt_.str.5
	b.le	.Lrt_BB87_5
// %bb.2:
	adrp	x9, xt_argv_v
	ldr	x9, [x9, :lo12:xt_argv_v]
	cbz	x9, .Lrt_BB87_5
// %bb.3:
	ldr	x0, [x9, w8, uxtw #3]
	ret
.Lrt_BB87_4:
	adrp	x0, .Lrt_.str.5
	add	x0, x0, :lo12:.Lrt_.str.5
.Lrt_BB87_5:
	ret
.Lrt_func_end87:
	.size	_xt_argv, .Lrt_func_end87-_xt_argv
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
.Lrt_func_end88:
	.size	_xt_exit, .Lrt_func_end88-_xt_exit
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
	cbz	x0, .Lrt_BB89_4
// %bb.1:
	sub	x21, x0, x20
	cmp	x21, #1023
	b.hi	.Lrt_BB89_11
// %bb.2:
	mov	x22, x0
	mov	x0, sp
	mov	x1, x20
	mov	x2, x21
	mov	x23, sp
	bl	memcpy
	cmp	x22, x20
	strb	wzr, [x23, x21]
	b.ne	.Lrt_BB89_6
// %bb.3:
	mov	w8, #47                         // =0x2f
	b	.Lrt_BB89_5
.Lrt_BB89_4:
	mov	w8, #46                         // =0x2e
.Lrt_BB89_5:
	strb	w8, [sp]
	strb	wzr, [sp, #1]
.Lrt_BB89_6:
	mov	x0, sp
	bl	opendir
	cbz	x0, .Lrt_BB89_11
// %bb.7:
	mov	x20, x0
.Lrt_BB89_8:                               // =>This Inner Loop Header: Depth=1
	mov	x0, x20
	bl	readdir
	cbz	x0, .Lrt_BB89_12
// %bb.9:                               //   in Loop: Header=BB89_8 Depth=1
	add	x0, x0, #19
	mov	x1, x19
	bl	strcmp
	cbnz	w0, .Lrt_BB89_8
// %bb.10:
	mov	w19, #1                         // =0x1
	b	.Lrt_BB89_13
.Lrt_BB89_11:
	mov	w19, wzr
	b	.Lrt_BB89_14
.Lrt_BB89_12:
	mov	w19, wzr
.Lrt_BB89_13:
	mov	x0, x20
	bl	closedir
.Lrt_BB89_14:
	mov	w0, w19
	add	sp, sp, #1024
	ldp	x20, x19, [sp, #48]             // 16-byte Folded Reload
	ldp	x22, x21, [sp, #32]             // 16-byte Folded Reload
	ldp	x30, x23, [sp, #16]             // 16-byte Folded Reload
	ldr	x29, [sp], #64                  // 8-byte Folded Reload
	ret
.Lrt_func_end89:
	.size	_xt_file_exists_exact, .Lrt_func_end89-_xt_file_exists_exact
                                        // -- End function
	.globl	_xt_threads_multi               // -- Begin function _xt_threads_multi
	.p2align	2
	.type	_xt_threads_multi,@function
_xt_threads_multi:                      // @_xt_threads_multi
// %bb.0:
	adrp	x8, _xt_threads_active
	ldr	w0, [x8, :lo12:_xt_threads_active]
	ret
.Lrt_func_end90:
	.size	_xt_threads_multi, .Lrt_func_end90-_xt_threads_multi
                                        // -- End function
	.globl	_xt_thread_create               // -- Begin function _xt_thread_create
	.p2align	2
	.type	_xt_thread_create,@function
_xt_thread_create:                      // @_xt_thread_create
// %bb.0:
	cbz	x0, .Lrt_BB91_11
// %bb.1:
	stp	x30, x21, [sp, #-32]!           // 16-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	adrp	x19, _xt_threads_active
	mov	x20, x0
	ldr	w8, [x19, :lo12:_xt_threads_active]
	mov	x21, x1
	cbnz	w8, .Lrt_BB91_3
// %bb.2:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	mov	x1, xzr
	bl	pthread_mutex_init
	mov	w8, #1                          // =0x1
	str	w8, [x19, :lo12:_xt_threads_active]
.Lrt_BB91_3:
	mov	w0, #16                         // =0x10
	bl	malloc
	cbz	x0, .Lrt_BB91_10
// %bb.4:
	mov	x19, x0
	stp	x20, x21, [x0]
	mov	w0, #8                          // =0x8
	bl	malloc
	cbz	x0, .Lrt_BB91_7
// %bb.5:
	adrp	x2, xt_thread_entry
	add	x2, x2, :lo12:xt_thread_entry
	mov	x1, xzr
	mov	x3, x19
	mov	x20, x0
	bl	pthread_create
	cbz	w0, .Lrt_BB91_9
// %bb.6:
	mov	x0, x19
	bl	free
	mov	x0, x20
	b	.Lrt_BB91_8
.Lrt_BB91_7:
	mov	x0, x19
.Lrt_BB91_8:
	bl	free
	mov	x0, xzr
	b	.Lrt_BB91_10
.Lrt_BB91_9:
	mov	x0, x20
.Lrt_BB91_10:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldp	x30, x21, [sp], #32             // 16-byte Folded Reload
.Lrt_BB91_11:
	ret
.Lrt_func_end91:
	.size	_xt_thread_create, .Lrt_func_end91-_xt_thread_create
                                        // -- End function
	.p2align	2                               // -- Begin function xt_thread_entry
	.type	xt_thread_entry,@function
xt_thread_entry:                        // @xt_thread_entry
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	ldp	x20, x19, [x0]
	bl	free
	cbz	x20, .Lrt_BB92_2
// %bb.1:
	mov	x0, x19
	blr	x20
.Lrt_BB92_2:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	mov	x0, xzr
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end92:
	.size	xt_thread_entry, .Lrt_func_end92-xt_thread_entry
                                        // -- End function
	.globl	_xt_thread_join                 // -- Begin function _xt_thread_join
	.p2align	2
	.type	_xt_thread_join,@function
_xt_thread_join:                        // @_xt_thread_join
// %bb.0:
	cbz	x0, .Lrt_BB93_2
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
.Lrt_BB93_2:
	mov	w0, #-1                         // =0xffffffff
	ret
.Lrt_func_end93:
	.size	_xt_thread_join, .Lrt_func_end93-_xt_thread_join
                                        // -- End function
	.globl	_xt_thread_detach               // -- Begin function _xt_thread_detach
	.p2align	2
	.type	_xt_thread_detach,@function
_xt_thread_detach:                      // @_xt_thread_detach
// %bb.0:
	cbz	x0, .Lrt_BB94_2
// %bb.1:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	ldr	x8, [x0]
	mov	x19, x0
	mov	x0, x8
	bl	pthread_detach
	mov	x0, x19
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	b	free
.Lrt_BB94_2:
	ret
.Lrt_func_end94:
	.size	_xt_thread_detach, .Lrt_func_end94-_xt_thread_detach
                                        // -- End function
	.globl	_xt_thread_yield                // -- Begin function _xt_thread_yield
	.p2align	2
	.type	_xt_thread_yield,@function
_xt_thread_yield:                       // @_xt_thread_yield
// %bb.0:
	b	sched_yield
.Lrt_func_end95:
	.size	_xt_thread_yield, .Lrt_func_end95-_xt_thread_yield
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
.Lrt_func_end96:
	.size	_xt_thread_sleep_ms, .Lrt_func_end96-_xt_thread_sleep_ms
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
.Lrt_func_end97:
	.size	_xt_thread_self_id, .Lrt_func_end97-_xt_thread_self_id
                                        // -- End function
	.globl	_xt_thread_cpu_count            // -- Begin function _xt_thread_cpu_count
	.p2align	2
	.type	_xt_thread_cpu_count,@function
_xt_thread_cpu_count:                   // @_xt_thread_cpu_count
// %bb.0:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	mov	w0, #84                         // =0x54
	bl	sysconf
	cmp	x0, #0
	csinc	w0, w0, wzr, gt
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
	ret
.Lrt_func_end98:
	.size	_xt_thread_cpu_count, .Lrt_func_end98-_xt_thread_cpu_count
                                        // -- End function
	.globl	_xt_mutex_new                   // -- Begin function _xt_mutex_new
	.p2align	2
	.type	_xt_mutex_new,@function
_xt_mutex_new:                          // @_xt_mutex_new
// %bb.0:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	mov	w0, #48                         // =0x30
	bl	malloc
	cbz	x0, .Lrt_BB99_3
// %bb.1:
	mov	x1, xzr
	mov	x19, x0
	bl	pthread_mutex_init
	cbz	w0, .Lrt_BB99_4
// %bb.2:
	mov	x0, x19
	bl	free
	mov	x0, xzr
.Lrt_BB99_3:
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	ret
.Lrt_BB99_4:
	mov	x0, x19
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	ret
.Lrt_func_end99:
	.size	_xt_mutex_new, .Lrt_func_end99-_xt_mutex_new
                                        // -- End function
	.globl	_xt_mutex_free                  // -- Begin function _xt_mutex_free
	.p2align	2
	.type	_xt_mutex_free,@function
_xt_mutex_free:                         // @_xt_mutex_free
// %bb.0:
	cbz	x0, .Lrt_BB100_2
// %bb.1:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	mov	x19, x0
	bl	pthread_mutex_destroy
	mov	x0, x19
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	b	free
.Lrt_BB100_2:
	ret
.Lrt_func_end100:
	.size	_xt_mutex_free, .Lrt_func_end100-_xt_mutex_free
                                        // -- End function
	.globl	_xt_mutex_lock                  // -- Begin function _xt_mutex_lock
	.p2align	2
	.type	_xt_mutex_lock,@function
_xt_mutex_lock:                         // @_xt_mutex_lock
// %bb.0:
	cbz	x0, .Lrt_BB101_2
// %bb.1:
	b	pthread_mutex_lock
.Lrt_BB101_2:
	ret
.Lrt_func_end101:
	.size	_xt_mutex_lock, .Lrt_func_end101-_xt_mutex_lock
                                        // -- End function
	.globl	_xt_mutex_unlock                // -- Begin function _xt_mutex_unlock
	.p2align	2
	.type	_xt_mutex_unlock,@function
_xt_mutex_unlock:                       // @_xt_mutex_unlock
// %bb.0:
	cbz	x0, .Lrt_BB102_2
// %bb.1:
	b	pthread_mutex_unlock
.Lrt_BB102_2:
	ret
.Lrt_func_end102:
	.size	_xt_mutex_unlock, .Lrt_func_end102-_xt_mutex_unlock
                                        // -- End function
	.globl	_xt_mutex_trylock               // -- Begin function _xt_mutex_trylock
	.p2align	2
	.type	_xt_mutex_trylock,@function
_xt_mutex_trylock:                      // @_xt_mutex_trylock
// %bb.0:
	cbz	x0, .Lrt_BB103_2
// %bb.1:
	str	x30, [sp, #-16]!                // 8-byte Folded Spill
	bl	pthread_mutex_trylock
	cmp	w0, #0
	cset	w0, eq
	ldr	x30, [sp], #16                  // 8-byte Folded Reload
.Lrt_BB103_2:
	ret
.Lrt_func_end103:
	.size	_xt_mutex_trylock, .Lrt_func_end103-_xt_mutex_trylock
                                        // -- End function
	.globl	_xt_cond_new                    // -- Begin function _xt_cond_new
	.p2align	2
	.type	_xt_cond_new,@function
_xt_cond_new:                           // @_xt_cond_new
// %bb.0:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	mov	w0, #48                         // =0x30
	bl	malloc
	cbz	x0, .Lrt_BB104_3
// %bb.1:
	mov	x1, xzr
	mov	x19, x0
	bl	pthread_cond_init
	cbz	w0, .Lrt_BB104_4
// %bb.2:
	mov	x0, x19
	bl	free
	mov	x0, xzr
.Lrt_BB104_3:
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	ret
.Lrt_BB104_4:
	mov	x0, x19
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	ret
.Lrt_func_end104:
	.size	_xt_cond_new, .Lrt_func_end104-_xt_cond_new
                                        // -- End function
	.globl	_xt_cond_free                   // -- Begin function _xt_cond_free
	.p2align	2
	.type	_xt_cond_free,@function
_xt_cond_free:                          // @_xt_cond_free
// %bb.0:
	cbz	x0, .Lrt_BB105_2
// %bb.1:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	mov	x19, x0
	bl	pthread_cond_destroy
	mov	x0, x19
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	b	free
.Lrt_BB105_2:
	ret
.Lrt_func_end105:
	.size	_xt_cond_free, .Lrt_func_end105-_xt_cond_free
                                        // -- End function
	.globl	_xt_cond_wait                   // -- Begin function _xt_cond_wait
	.p2align	2
	.type	_xt_cond_wait,@function
_xt_cond_wait:                          // @_xt_cond_wait
// %bb.0:
	cbz	x0, .Lrt_BB106_3
// %bb.1:
	cbz	x1, .Lrt_BB106_3
// %bb.2:
	b	pthread_cond_wait
.Lrt_BB106_3:
	ret
.Lrt_func_end106:
	.size	_xt_cond_wait, .Lrt_func_end106-_xt_cond_wait
                                        // -- End function
	.globl	_xt_cond_signal                 // -- Begin function _xt_cond_signal
	.p2align	2
	.type	_xt_cond_signal,@function
_xt_cond_signal:                        // @_xt_cond_signal
// %bb.0:
	cbz	x0, .Lrt_BB107_2
// %bb.1:
	b	pthread_cond_signal
.Lrt_BB107_2:
	ret
.Lrt_func_end107:
	.size	_xt_cond_signal, .Lrt_func_end107-_xt_cond_signal
                                        // -- End function
	.globl	_xt_cond_broadcast              // -- Begin function _xt_cond_broadcast
	.p2align	2
	.type	_xt_cond_broadcast,@function
_xt_cond_broadcast:                     // @_xt_cond_broadcast
// %bb.0:
	cbz	x0, .Lrt_BB108_2
// %bb.1:
	b	pthread_cond_broadcast
.Lrt_BB108_2:
	ret
.Lrt_func_end108:
	.size	_xt_cond_broadcast, .Lrt_func_end108-_xt_cond_broadcast
                                        // -- End function
	.globl	_xt_sem_new                     // -- Begin function _xt_sem_new
	.p2align	2
	.type	_xt_sem_new,@function
_xt_sem_new:                            // @_xt_sem_new
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	mov	w19, w0
	mov	w0, #104                        // =0x68
	bl	malloc
	cbz	x0, .Lrt_BB109_5
// %bb.1:
	mov	x1, xzr
	mov	x20, x0
	bl	pthread_mutex_init
	cbnz	w0, .Lrt_BB109_4
// %bb.2:
	add	x0, x20, #48
	mov	x1, xzr
	bl	pthread_cond_init
	cbz	w0, .Lrt_BB109_6
// %bb.3:
	mov	x0, x20
	bl	pthread_mutex_destroy
.Lrt_BB109_4:
	mov	x0, x20
	bl	free
	mov	x0, xzr
.Lrt_BB109_5:
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_BB109_6:
	bic	w8, w19, w19, asr #31
	mov	x0, x20
	str	w8, [x20, #96]
	b	.Lrt_BB109_5
.Lrt_func_end109:
	.size	_xt_sem_new, .Lrt_func_end109-_xt_sem_new
                                        // -- End function
	.globl	_xt_sem_free                    // -- Begin function _xt_sem_free
	.p2align	2
	.type	_xt_sem_free,@function
_xt_sem_free:                           // @_xt_sem_free
// %bb.0:
	cbz	x0, .Lrt_BB110_2
// %bb.1:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	mov	x19, x0
	add	x0, x0, #48
	bl	pthread_cond_destroy
	mov	x0, x19
	bl	pthread_mutex_destroy
	mov	x0, x19
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	b	free
.Lrt_BB110_2:
	ret
.Lrt_func_end110:
	.size	_xt_sem_free, .Lrt_func_end110-_xt_sem_free
                                        // -- End function
	.globl	_xt_sem_wait                    // -- Begin function _xt_sem_wait
	.p2align	2
	.type	_xt_sem_wait,@function
_xt_sem_wait:                           // @_xt_sem_wait
// %bb.0:
	cbz	x0, .Lrt_BB111_4
// %bb.1:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	mov	x19, x0
	bl	pthread_mutex_lock
	ldr	w8, [x19, #96]
	cmp	w8, #0
	b.gt	.Lrt_BB111_3
.Lrt_BB111_2:                              // =>This Inner Loop Header: Depth=1
	add	x0, x19, #48
	mov	x1, x19
	bl	pthread_cond_wait
	ldr	w8, [x19, #96]
	cmp	w8, #1
	b.lt	.Lrt_BB111_2
.Lrt_BB111_3:
	sub	w8, w8, #1
	mov	x0, x19
	str	w8, [x19, #96]
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	b	pthread_mutex_unlock
.Lrt_BB111_4:
	ret
.Lrt_func_end111:
	.size	_xt_sem_wait, .Lrt_func_end111-_xt_sem_wait
                                        // -- End function
	.globl	_xt_sem_trywait                 // -- Begin function _xt_sem_trywait
	.p2align	2
	.type	_xt_sem_trywait,@function
_xt_sem_trywait:                        // @_xt_sem_trywait
// %bb.0:
	str	x30, [sp, #-32]!                // 8-byte Folded Spill
	stp	x20, x19, [sp, #16]             // 16-byte Folded Spill
	cbz	x0, .Lrt_BB112_3
// %bb.1:
	mov	x19, x0
	bl	pthread_mutex_lock
	ldr	w8, [x19, #96]
	subs	w8, w8, #1
	b.lt	.Lrt_BB112_4
// %bb.2:
	mov	w20, #1                         // =0x1
	str	w8, [x19, #96]
	b	.Lrt_BB112_5
.Lrt_BB112_3:
	mov	w20, wzr
	b	.Lrt_BB112_6
.Lrt_BB112_4:
	mov	w20, wzr
.Lrt_BB112_5:
	mov	x0, x19
	bl	pthread_mutex_unlock
.Lrt_BB112_6:
	mov	w0, w20
	ldp	x20, x19, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #32                  // 8-byte Folded Reload
	ret
.Lrt_func_end112:
	.size	_xt_sem_trywait, .Lrt_func_end112-_xt_sem_trywait
                                        // -- End function
	.globl	_xt_sem_post                    // -- Begin function _xt_sem_post
	.p2align	2
	.type	_xt_sem_post,@function
_xt_sem_post:                           // @_xt_sem_post
// %bb.0:
	cbz	x0, .Lrt_BB113_2
// %bb.1:
	stp	x30, x19, [sp, #-16]!           // 16-byte Folded Spill
	mov	x19, x0
	bl	pthread_mutex_lock
	ldr	w8, [x19, #96]
	add	x0, x19, #48
	add	w8, w8, #1
	str	w8, [x19, #96]
	bl	pthread_cond_signal
	mov	x0, x19
	ldp	x30, x19, [sp], #16             // 16-byte Folded Reload
	b	pthread_mutex_unlock
.Lrt_BB113_2:
	ret
.Lrt_func_end113:
	.size	_xt_sem_post, .Lrt_func_end113-_xt_sem_post
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
.Lrt_func_end114:
	.size	_xt_tls_new, .Lrt_func_end114-_xt_tls_new
                                        // -- End function
	.globl	_xt_tls_set                     // -- Begin function _xt_tls_set
	.p2align	2
	.type	_xt_tls_set,@function
_xt_tls_set:                            // @_xt_tls_set
// %bb.0:
	cmn	w0, #1
	b.eq	.Lrt_BB115_2
// %bb.1:
	b	pthread_setspecific
.Lrt_BB115_2:
	ret
.Lrt_func_end115:
	.size	_xt_tls_set, .Lrt_func_end115-_xt_tls_set
                                        // -- End function
	.globl	_xt_tls_get                     // -- Begin function _xt_tls_get
	.p2align	2
	.type	_xt_tls_get,@function
_xt_tls_get:                            // @_xt_tls_get
// %bb.0:
	cmn	w0, #1
	b.eq	.Lrt_BB116_2
// %bb.1:
	b	pthread_getspecific
.Lrt_BB116_2:
	mov	x0, xzr
	ret
.Lrt_func_end116:
	.size	_xt_tls_get, .Lrt_func_end116-_xt_tls_get
                                        // -- End function
	.globl	_xt_atomic_load_i32             // -- Begin function _xt_atomic_load_i32
	.p2align	2
	.type	_xt_atomic_load_i32,@function
_xt_atomic_load_i32:                    // @_xt_atomic_load_i32
// %bb.0:
	cbz	x0, .Lrt_BB117_2
// %bb.1:
	ldar	w0, [x0]
.Lrt_BB117_2:
	ret
.Lrt_func_end117:
	.size	_xt_atomic_load_i32, .Lrt_func_end117-_xt_atomic_load_i32
                                        // -- End function
	.globl	_xt_atomic_store_i32            // -- Begin function _xt_atomic_store_i32
	.p2align	2
	.type	_xt_atomic_store_i32,@function
_xt_atomic_store_i32:                   // @_xt_atomic_store_i32
// %bb.0:
	cbz	x0, .Lrt_BB118_2
// %bb.1:
	stlr	w1, [x0]
.Lrt_BB118_2:
	ret
.Lrt_func_end118:
	.size	_xt_atomic_store_i32, .Lrt_func_end118-_xt_atomic_store_i32
                                        // -- End function
	.globl	_xt_atomic_add_i32              // -- Begin function _xt_atomic_add_i32
	.p2align	2
	.type	_xt_atomic_add_i32,@function
_xt_atomic_add_i32:                     // @_xt_atomic_add_i32
// %bb.0:
	cbz	x0, .Lrt_BB119_3
.Lrt_BB119_1:                              // =>This Inner Loop Header: Depth=1
	ldaxr	w8, [x0]
	add	w8, w8, w1
	stlxr	w9, w8, [x0]
	cbnz	w9, .Lrt_BB119_1
// %bb.2:
	mov	w0, w8
	ret
.Lrt_BB119_3:
	mov	w0, wzr
	ret
.Lrt_func_end119:
	.size	_xt_atomic_add_i32, .Lrt_func_end119-_xt_atomic_add_i32
                                        // -- End function
	.globl	_xt_atomic_xchg_i32             // -- Begin function _xt_atomic_xchg_i32
	.p2align	2
	.type	_xt_atomic_xchg_i32,@function
_xt_atomic_xchg_i32:                    // @_xt_atomic_xchg_i32
// %bb.0:
	cbz	x0, .Lrt_BB120_3
// %bb.1:
	mov	x8, x0
.Lrt_BB120_2:                              // =>This Inner Loop Header: Depth=1
	ldaxr	w0, [x8]
	stlxr	w9, w1, [x8]
	cbnz	w9, .Lrt_BB120_2
.Lrt_BB120_3:
                                        // kill: def $w0 killed $w0 killed $x0
	ret
.Lrt_func_end120:
	.size	_xt_atomic_xchg_i32, .Lrt_func_end120-_xt_atomic_xchg_i32
                                        // -- End function
	.globl	_xt_atomic_cas_i32              // -- Begin function _xt_atomic_cas_i32
	.p2align	2
	.type	_xt_atomic_cas_i32,@function
_xt_atomic_cas_i32:                     // @_xt_atomic_cas_i32
// %bb.0:
	cbz	x0, .Lrt_BB121_5
.Lrt_BB121_1:                              // =>This Inner Loop Header: Depth=1
	ldaxr	w8, [x0]
	cmp	w8, w1
	b.ne	.Lrt_BB121_4
// %bb.2:                               //   in Loop: Header=BB121_1 Depth=1
	stlxr	w8, w2, [x0]
	cbnz	w8, .Lrt_BB121_1
// %bb.3:
	mov	w0, #1                          // =0x1
	ret
.Lrt_BB121_4:
	mov	w0, wzr
	clrex
.Lrt_BB121_5:
	ret
.Lrt_func_end121:
	.size	_xt_atomic_cas_i32, .Lrt_func_end121-_xt_atomic_cas_i32
                                        // -- End function
	.globl	_xt_atomic_load_ptr             // -- Begin function _xt_atomic_load_ptr
	.p2align	2
	.type	_xt_atomic_load_ptr,@function
_xt_atomic_load_ptr:                    // @_xt_atomic_load_ptr
// %bb.0:
	cbz	x0, .Lrt_BB122_2
// %bb.1:
	ldar	x0, [x0]
.Lrt_BB122_2:
	ret
.Lrt_func_end122:
	.size	_xt_atomic_load_ptr, .Lrt_func_end122-_xt_atomic_load_ptr
                                        // -- End function
	.globl	_xt_atomic_store_ptr            // -- Begin function _xt_atomic_store_ptr
	.p2align	2
	.type	_xt_atomic_store_ptr,@function
_xt_atomic_store_ptr:                   // @_xt_atomic_store_ptr
// %bb.0:
	cbz	x0, .Lrt_BB123_2
// %bb.1:
	stlr	x1, [x0]
.Lrt_BB123_2:
	ret
.Lrt_func_end123:
	.size	_xt_atomic_store_ptr, .Lrt_func_end123-_xt_atomic_store_ptr
                                        // -- End function
	.globl	_xt_atomic_cas_ptr              // -- Begin function _xt_atomic_cas_ptr
	.p2align	2
	.type	_xt_atomic_cas_ptr,@function
_xt_atomic_cas_ptr:                     // @_xt_atomic_cas_ptr
// %bb.0:
	cbz	x0, .Lrt_BB124_5
.Lrt_BB124_1:                              // =>This Inner Loop Header: Depth=1
	ldaxr	x8, [x0]
	cmp	x8, x1
	b.ne	.Lrt_BB124_4
// %bb.2:                               //   in Loop: Header=BB124_1 Depth=1
	stlxr	w8, x2, [x0]
	cbnz	w8, .Lrt_BB124_1
// %bb.3:
	mov	w0, #1                          // =0x1
	ret
.Lrt_BB124_4:
	mov	w0, wzr
	clrex
.Lrt_BB124_5:
	ret
.Lrt_func_end124:
	.size	_xt_atomic_cas_ptr, .Lrt_func_end124-_xt_atomic_cas_ptr
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
	cbz	x0, .Lrt_BB125_35
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
	b	.Lrt_BB125_4
.Lrt_BB125_2:                              //   in Loop: Header=BB125_4 Depth=1
	mov	w8, #1                          // =0x1
.Lrt_BB125_3:                              //   in Loop: Header=BB125_4 Depth=1
	cbnz	w8, .Lrt_BB125_23
.Lrt_BB125_4:                              // =>This Loop Header: Depth=1
                                        //     Child Loop BB125_17 Depth 2
	ldr	w8, [x23, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB125_6
// %bb.5:                               //   in Loop: Header=BB125_4 Depth=1
	mov	x0, x22
	bl	pthread_mutex_lock
.Lrt_BB125_6:                              //   in Loop: Header=BB125_4 Depth=1
	ldrb	w8, [x19]
	cbz	w8, .Lrt_BB125_10
// %bb.7:                               //   in Loop: Header=BB125_4 Depth=1
	cmp	w8, #2
	b.ne	.Lrt_BB125_14
.Lrt_BB125_8:                              //   in Loop: Header=BB125_4 Depth=1
	ldr	w8, [x23, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB125_2
// %bb.9:                               //   in Loop: Header=BB125_4 Depth=1
	mov	x0, x22
	bl	pthread_mutex_unlock
	b	.Lrt_BB125_2
.Lrt_BB125_10:                             //   in Loop: Header=BB125_4 Depth=1
	strb	w26, [x19]
	ldrsw	x28, [x24, :lo12:xt_sinit_n]
	cmp	w28, #31
	b.gt	.Lrt_BB125_12
// %bb.11:                              //   in Loop: Header=BB125_4 Depth=1
	str	x19, [x25, x28, lsl #3]
	bl	pthread_self
	lsr	x9, x0, #4
	lsr	x10, x0, #32
	add	w8, w28, #1
	str	w8, [x24, :lo12:xt_sinit_n]
	eor	w9, w9, w10
	str	w9, [x27, x28, lsl #2]
.Lrt_BB125_12:                             //   in Loop: Header=BB125_4 Depth=1
	ldr	w8, [x23, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB125_22
// %bb.13:                              //   in Loop: Header=BB125_4 Depth=1
	mov	x0, x22
	bl	pthread_mutex_unlock
	mov	w8, #2                          // =0x2
	b	.Lrt_BB125_3
.Lrt_BB125_14:                             //   in Loop: Header=BB125_4 Depth=1
	bl	pthread_self
	ldr	w8, [x24, :lo12:xt_sinit_n]
	cmp	w8, #1
	b.lt	.Lrt_BB125_19
// %bb.15:                              //   in Loop: Header=BB125_4 Depth=1
	lsr	x9, x0, #4
	lsr	x10, x0, #32
	mov	x11, x27
	eor	w9, w9, w10
	mov	x10, x25
	b	.Lrt_BB125_17
.Lrt_BB125_16:                             //   in Loop: Header=BB125_17 Depth=2
	subs	x8, x8, #1
	add	x11, x11, #4
	add	x10, x10, #8
	b.eq	.Lrt_BB125_19
.Lrt_BB125_17:                             //   Parent Loop BB125_4 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldr	x12, [x10]
	cmp	x12, x19
	b.ne	.Lrt_BB125_16
// %bb.18:                              //   in Loop: Header=BB125_17 Depth=2
	ldr	w12, [x11]
	cmp	w12, w9
	b.ne	.Lrt_BB125_16
	b	.Lrt_BB125_8
.Lrt_BB125_19:                             //   in Loop: Header=BB125_4 Depth=1
	ldr	w8, [x23, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB125_21
// %bb.20:                              //   in Loop: Header=BB125_4 Depth=1
	mov	x0, x22
	bl	pthread_mutex_unlock
.Lrt_BB125_21:                             //   in Loop: Header=BB125_4 Depth=1
	bl	sched_yield
	mov	w8, wzr
	b	.Lrt_BB125_3
.Lrt_BB125_22:                             //   in Loop: Header=BB125_4 Depth=1
	mov	w8, #2                          // =0x2
	b	.Lrt_BB125_3
.Lrt_BB125_23:
	cmp	w8, #1
	b.eq	.Lrt_BB125_35
// %bb.24:
	cbz	x21, .Lrt_BB125_26
// %bb.25:
	mov	x0, x20
	blr	x21
.Lrt_BB125_26:
	ldr	w8, [x23, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB125_28
// %bb.27:
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	bl	pthread_mutex_lock
.Lrt_BB125_28:
	mov	w8, #2                          // =0x2
	strb	w8, [x19]
	ldr	w8, [x24, :lo12:xt_sinit_n]
	cmp	w8, #1
	b.lt	.Lrt_BB125_32
// %bb.29:
	adrp	x9, xt_sinit_owner
	add	x9, x9, :lo12:xt_sinit_owner
	adrp	x12, xt_sinit_flag
	add	x12, x12, :lo12:xt_sinit_flag
	mov	x13, x8
	mov	x11, x9
	mov	x10, x12
.Lrt_BB125_30:                             // =>This Inner Loop Header: Depth=1
	ldr	x14, [x10]
	cmp	x14, x19
	b.eq	.Lrt_BB125_34
// %bb.31:                              //   in Loop: Header=BB125_30 Depth=1
	subs	x13, x13, #1
	add	x11, x11, #4
	add	x10, x10, #8
	b.ne	.Lrt_BB125_30
.Lrt_BB125_32:
	ldr	w8, [x23, :lo12:_xt_threads_active]
	cbz	w8, .Lrt_BB125_35
.Lrt_BB125_33:
	ldp	x20, x19, [sp, #80]             // 16-byte Folded Reload
	adrp	x0, xt_rt_mtx
	add	x0, x0, :lo12:xt_rt_mtx
	ldp	x22, x21, [sp, #64]             // 16-byte Folded Reload
	ldp	x24, x23, [sp, #48]             // 16-byte Folded Reload
	ldp	x26, x25, [sp, #32]             // 16-byte Folded Reload
	ldp	x28, x27, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #96                  // 8-byte Folded Reload
	b	pthread_mutex_unlock
.Lrt_BB125_34:
	sxtw	x8, w8
	sub	x8, x8, #1
	ldr	x12, [x12, x8, lsl #3]
	str	w8, [x24, :lo12:xt_sinit_n]
	ldr	w8, [x9, x8, lsl #2]
	str	x12, [x10]
	str	w8, [x11]
	ldr	w8, [x23, :lo12:_xt_threads_active]
	cbnz	w8, .Lrt_BB125_33
.Lrt_BB125_35:
	ldp	x20, x19, [sp, #80]             // 16-byte Folded Reload
	ldp	x22, x21, [sp, #64]             // 16-byte Folded Reload
	ldp	x24, x23, [sp, #48]             // 16-byte Folded Reload
	ldp	x26, x25, [sp, #32]             // 16-byte Folded Reload
	ldp	x28, x27, [sp, #16]             // 16-byte Folded Reload
	ldr	x30, [sp], #96                  // 8-byte Folded Reload
	ret
.Lrt_func_end125:
	.size	_xtc_sinit_run, .Lrt_func_end125-_xtc_sinit_run
                                        // -- End function
	.globl	_xt_thread_exiting              // -- Begin function _xt_thread_exiting
	.p2align	2
	.type	_xt_thread_exiting,@function
_xt_thread_exiting:                     // @_xt_thread_exiting
// %bb.0:
	ret
.Lrt_func_end126:
	.size	_xt_thread_exiting, .Lrt_func_end126-_xt_thread_exiting
                                        // -- End function
	.p2align	2                               // -- Begin function xt_wtab_put
	.type	xt_wtab_put,@function
xt_wtab_put:                            // @xt_wtab_put
// %bb.0:
	stp	x30, x27, [sp, #-80]!           // 16-byte Folded Spill
	stp	x22, x21, [sp, #48]             // 16-byte Folded Spill
	adrp	x22, xt_wtab_used
	ldr	x8, [x22, :lo12:xt_wtab_used]
	stp	x24, x23, [sp, #32]             // 16-byte Folded Spill
	adrp	x24, xt_wtab_cap
	stp	x26, x25, [sp, #16]             // 16-byte Folded Spill
	ldr	x26, [x24, :lo12:xt_wtab_cap]
	adrp	x25, xt_wtab
	lsl	x8, x8, #1
	stp	x20, x19, [sp, #64]             // 16-byte Folded Spill
	mov	x19, x1
	mov	x20, x0
	adrp	x23, xt_wtab_n
	add	x8, x8, #2
	cmp	x8, x26
	b.ls	.Lrt_BB127_10
// %bb.1:
	ldr	x8, [x23, :lo12:xt_wtab_n]
	lsl	x9, x26, #1
	ldr	x21, [x25, :lo12:xt_wtab]
	cmp	x26, #0
	mov	w10, #64                        // =0x40
	lsl	x8, x8, #1
	csel	x9, x10, x9, eq
.Lrt_BB127_2:                              // =>This Inner Loop Header: Depth=1
	mov	x0, x9
	lsl	x9, x9, #1
	cmp	x8, x0
	b.hs	.Lrt_BB127_2
// %bb.3:
	mov	w1, #16                         // =0x10
	str	x0, [x24, :lo12:xt_wtab_cap]
	bl	calloc
	str	x0, [x25, :lo12:xt_wtab]
	cbz	x0, .Lrt_BB127_15
// %bb.4:
	str	xzr, [x23, :lo12:xt_wtab_n]
	str	xzr, [x22, :lo12:xt_wtab_used]
	cbz	x26, .Lrt_BB127_9
// %bb.5:
	add	x27, x21, #8
	b	.Lrt_BB127_7
.Lrt_BB127_6:                              //   in Loop: Header=BB127_7 Depth=1
	subs	x26, x26, #1
	add	x27, x27, #16
	b.eq	.Lrt_BB127_9
.Lrt_BB127_7:                              // =>This Inner Loop Header: Depth=1
	ldur	x0, [x27, #-8]
	cmp	x0, #2
	b.lo	.Lrt_BB127_6
// %bb.8:                               //   in Loop: Header=BB127_7 Depth=1
	ldr	x1, [x27]
	bl	xt_wtab_put
	b	.Lrt_BB127_6
.Lrt_BB127_9:
	mov	x0, x21
	bl	free
.Lrt_BB127_10:
	lsr	x8, x20, #3
	mov	w9, #54459                      // =0xd4bb
	movk	w9, #60762, lsl #16
	eor	x8, x8, x20, lsr #20
	mul	x8, x8, x9
	ldr	x9, [x24, :lo12:xt_wtab_cap]
	sub	x10, x9, #1
	eor	x11, x8, x8, lsr #11
	ldr	x8, [x25, :lo12:xt_wtab]
.Lrt_BB127_11:                             // =>This Inner Loop Header: Depth=1
	and	x9, x11, x10
	lsl	x11, x9, #4
	ldr	x12, [x8, x11]
	add	x11, x9, #1
	cmp	x12, #1
	b.hi	.Lrt_BB127_11
// %bb.12:
	cbnz	x12, .Lrt_BB127_14
// %bb.13:
	ldr	x10, [x22, :lo12:xt_wtab_used]
	add	x10, x10, #1
	str	x10, [x22, :lo12:xt_wtab_used]
.Lrt_BB127_14:
	add	x8, x8, x9, lsl #4
	ldr	x9, [x23, :lo12:xt_wtab_n]
	ldp	x22, x21, [sp, #48]             // 16-byte Folded Reload
	stp	x20, x19, [x8]
	add	x8, x9, #1
	str	x8, [x23, :lo12:xt_wtab_n]
	ldp	x20, x19, [sp, #64]             // 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             // 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             // 16-byte Folded Reload
	ldp	x30, x27, [sp], #80             // 16-byte Folded Reload
	ret
.Lrt_BB127_15:
	adrp	x8, :got:stderr
	adrp	x0, .Lrt_.str.8
	add	x0, x0, :lo12:.Lrt_.str.8
	ldr	x8, [x8, :got_lo12:stderr]
	mov	w1, #37                         // =0x25
	mov	w2, #1                          // =0x1
	ldr	x3, [x8]
	bl	fwrite
	bl	abort
.Lrt_func_end127:
	.size	xt_wtab_put, .Lrt_func_end127-xt_wtab_put
                                        // -- End function
	.type	.Lrt_.str,@object                  // @.str
	.section	.rodata.str1.1,"aMS",@progbits,1
.Lrt_.str:
	.asciz	"xcc: out of memory allocating %lu x %lu bytes\n"
	.size	.Lrt_.str, 47

	.type	.Lrt_.str.1,@object                // @.str.1
.Lrt_.str.1:
	.asciz	"xcc: out of memory allocating %lu bytes\n"
	.size	.Lrt_.str.1, 41

	.type	xt_simd_tab,@object             // @xt_simd_tab
	.local	xt_simd_tab
	.comm	xt_simd_tab,8,8
	.type	xt_simd_installed,@object       // @xt_simd_installed
	.local	xt_simd_installed
	.comm	xt_simd_installed,1,4
	.type	xt_simd_old,@object             // @xt_simd_old
	.local	xt_simd_old
	.comm	xt_simd_old,304,8
	.type	xt_simd_flag,@object            // @xt_simd_flag
	.local	xt_simd_flag
	.comm	xt_simd_flag,8,8
	.type	xt_wtab_n,@object               // @xt_wtab_n
	.local	xt_wtab_n
	.comm	xt_wtab_n,8,8
	.type	.Lrt_.str.2,@object                // @.str.2
.Lrt_.str.2:
	.asciz	"%.6f"
	.size	.Lrt_.str.2, 5

	.type	.Lrt_.str.3,@object                // @.str.3
.Lrt_.str.3:
	.asciz	"%.10f"
	.size	.Lrt_.str.3, 6

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
	.type	.Lrt_.str.4,@object                // @.str.4
.Lrt_.str.4:
	.asciz	"rb"
	.size	.Lrt_.str.4, 3

	.type	.Lrt_.str.5,@object                // @.str.5
.Lrt_.str.5:
	.zero	1
	.size	.Lrt_.str.5, 1

	.hidden	__xt_stack_guard                // @__xt_stack_guard
	.type	__xt_stack_guard,@object
	.bss
	.globl	__xt_stack_guard
	.p2align	3, 0x0
__xt_stack_guard:
	.xword	0                               // 0x0
	.size	__xt_stack_guard, 8

	.type	.Lrt_.str.6,@object                // @.str.6
	.section	.rodata.str1.1,"aMS",@progbits,1
.Lrt_.str.6:
	.asciz	"xcc: stack smashing detected (a local array was written past its end)\n"
	.size	.Lrt_.str.6, 71

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
	.comm	xt_rt_mtx,48,8
	.type	xt_sinit_n,@object              // @xt_sinit_n
	.local	xt_sinit_n
	.comm	xt_sinit_n,4,4
	.type	xt_sinit_flag,@object           // @xt_sinit_flag
	.local	xt_sinit_flag
	.comm	xt_sinit_flag,256,8
	.type	xt_sinit_owner,@object          // @xt_sinit_owner
	.local	xt_sinit_owner
	.comm	xt_sinit_owner,128,4
	.type	.Lrt_.str.7,@object                // @.str.7
	.section	.rodata.str1.1,"aMS",@progbits,1
.Lrt_.str.7:
	.asciz	"xcc: an allocation of %lu x %lu bytes overflows\n"
	.size	.Lrt_.str.7, 49

	.type	xt_simd_n,@object               // @xt_simd_n
	.local	xt_simd_n
	.comm	xt_simd_n,8,8
	.type	xt_simd_cap,@object             // @xt_simd_cap
	.local	xt_simd_cap
	.comm	xt_simd_cap,8,8
	.type	xt_wcell_free,@object           // @xt_wcell_free
	.local	xt_wcell_free
	.comm	xt_wcell_free,8,8
	.type	.Lrt_.str.8,@object                // @.str.8
.Lrt_.str.8:
	.asciz	"xcc: out of memory (weak references)\n"
	.size	.Lrt_.str.8, 38

	.type	xt_wtab_used,@object            // @xt_wtab_used
	.local	xt_wtab_used
	.comm	xt_wtab_used,8,8
	.type	xt_wtab_cap,@object             // @xt_wtab_cap
	.local	xt_wtab_cap
	.comm	xt_wtab_cap,8,8
	.type	xt_wtab,@object                 // @xt_wtab
	.local	xt_wtab
	.comm	xt_wtab,8,8
	.type	.Lrt_.str.9,@object                // @.str.9
.Lrt_.str.9:
	.asciz	"%.*f"
	.size	.Lrt_.str.9, 5

	.ident	"Debian clang version 19.1.7 (3+b1)"
	.section	".note.GNU-stack","",@progbits
