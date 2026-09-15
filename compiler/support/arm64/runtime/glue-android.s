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

// glue-android.s — the NativeActivity entry point, as assembly.
// GENERATED from android-glue.c by gen-glue-android.sh — do not hand-edit.
//
// Checked in so `-A android --emit-apk` needs no NDK clang: XAArm64Assembler
// assembles this like any other text. Read android-glue.c for what it does and
// why it is not the NDK's android_native_app_glue.c.
//
// Exports exactly one symbol, ANativeActivity_onCreate, which is what the
// framework dlsym()s out of the packaged library. Imports (bionic): libc.so for
// pipe/dup2/pthread/stdio, liblog.so for __android_log_write, libandroid.so for
// ANativeActivity_finish.
	.text
	.file	"android-glue.c"
	.globl	ANativeActivity_onCreate        // -- Begin function ANativeActivity_onCreate
	.p2align	2
	.type	ANativeActivity_onCreate,@function
ANativeActivity_onCreate:               // @ANativeActivity_onCreate
// %bb.0:
	sub	sp, sp, #80
	stp	x30, x19, [sp, #64]             // 16-byte Folded Spill
	mov	x19, x0
	add	x0, sp, #8
	bl	pthread_attr_init
	add	x0, sp, #8
	mov	w1, #1                          // =0x1
	bl	pthread_attr_setdetachstate
	adrp	x2, xt_activity_main
	add	x2, x2, :lo12:xt_activity_main
	mov	x0, sp
	add	x1, sp, #8
	mov	x3, x19
	bl	pthread_create
	add	x0, sp, #8
	bl	pthread_attr_destroy
	ldp	x30, x19, [sp, #64]             // 16-byte Folded Reload
	add	sp, sp, #80
	ret
.Lglue_func_end0:
	.size	ANativeActivity_onCreate, .Lglue_func_end0-ANativeActivity_onCreate
                                        // -- End function
	.p2align	2                               // -- Begin function xt_activity_main
	.type	xt_activity_main,@function
xt_activity_main:                       // @xt_activity_main
// %bb.0:
	sub	sp, sp, #48
	stp	x20, x19, [sp, #32]             // 16-byte Folded Spill
	mov	x19, x0
	add	x0, sp, #24
	str	x30, [sp, #16]                  // 8-byte Folded Spill
	bl	pipe
	cbnz	w0, .Lglue_BB1_2
// %bb.1:
	ldr	w0, [sp, #28]
	mov	w1, #1                          // =0x1
	bl	dup2
	ldr	w0, [sp, #28]
	mov	w1, #2                          // =0x2
	bl	dup2
	adrp	x8, :got:stdout
	mov	x1, xzr
	mov	w2, #1                          // =0x1
	ldr	x8, [x8, :got_lo12:stdout]
	mov	x3, xzr
	ldr	x0, [x8]
	bl	setvbuf
	adrp	x8, :got:stderr
	mov	x1, xzr
	mov	w2, #2                          // =0x2
	ldr	x8, [x8, :got_lo12:stderr]
	mov	x3, xzr
	ldr	x0, [x8]
	bl	setvbuf
	ldrsw	x3, [sp, #24]
	adrp	x2, xt_log_pump
	add	x2, x2, :lo12:xt_log_pump
	add	x0, sp, #8
	mov	x1, xzr
	bl	pthread_create
.Lglue_BB1_2:
	adrp	x20, .Lglue_.str
	add	x20, x20, :lo12:.Lglue_.str
	adrp	x2, .Lglue_.str.1
	add	x2, x2, :lo12:.Lglue_.str.1
	mov	w0, #4                          // =0x4
	mov	x1, x20
	bl	__android_log_write
	bl	xt_main
	mov	x0, xzr
	bl	fflush
	mov	w0, #3392                       // =0xd40
	movk	w0, #3, lsl #16
	bl	usleep
	adrp	x2, .Lglue_.str.2
	add	x2, x2, :lo12:.Lglue_.str.2
	mov	w0, #4                          // =0x4
	mov	x1, x20
	bl	__android_log_write
	mov	x0, x19
	bl	ANativeActivity_finish
	ldp	x20, x19, [sp, #32]             // 16-byte Folded Reload
	mov	x0, xzr
	ldr	x30, [sp, #16]                  // 8-byte Folded Reload
	add	sp, sp, #48
	ret
.Lglue_func_end1:
	.size	xt_activity_main, .Lglue_func_end1-xt_activity_main
                                        // -- End function
	.p2align	2                               // -- Begin function xt_log_pump
	.type	xt_log_pump,@function
xt_log_pump:                            // @xt_log_pump
// %bb.0:
	stp	x29, x30, [sp, #-80]!           // 16-byte Folded Spill
	stp	x26, x25, [sp, #16]             // 16-byte Folded Spill
	stp	x24, x23, [sp, #32]             // 16-byte Folded Spill
	stp	x22, x21, [sp, #48]             // 16-byte Folded Spill
	stp	x20, x19, [sp, #64]             // 16-byte Folded Spill
	sub	sp, sp, #1536
	add	x1, sp, #1024
	mov	w2, #512                        // =0x200
	mov	x19, x0
	add	x21, sp, #1024
	bl	read
	cmp	x0, #1
	b.lt	.Lglue_BB2_11
// %bb.1:
	mov	x23, xzr
	mov	x22, sp
	adrp	x20, .Lglue_.str
	add	x20, x20, :lo12:.Lglue_.str
	b	.Lglue_BB2_3
.Lglue_BB2_2:                                //   in Loop: Header=BB2_3 Depth=1
	add	x1, sp, #1024
	mov	w0, w19
	mov	w2, #512                        // =0x200
	bl	read
	cmp	x0, #1
	b.lt	.Lglue_BB2_12
.Lglue_BB2_3:                                // =>This Loop Header: Depth=1
                                        //     Child Loop BB2_6 Depth 2
	cmp	x0, #1
	mov	x24, xzr
	csinc	x25, x0, xzr, hi
	b	.Lglue_BB2_6
.Lglue_BB2_4:                                //   in Loop: Header=BB2_6 Depth=2
	add	x8, x23, #1
	strb	w26, [x22, x23]
	mov	x23, x8
.Lglue_BB2_5:                                //   in Loop: Header=BB2_6 Depth=2
	add	x24, x24, #1
	cmp	x25, x24
	b.eq	.Lglue_BB2_2
.Lglue_BB2_6:                                //   Parent Loop BB2_3 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldrb	w26, [x21, x24]
	cmp	w26, #10
	b.eq	.Lglue_BB2_8
// %bb.7:                               //   in Loop: Header=BB2_6 Depth=2
	cmp	x23, #1023
	b.ne	.Lglue_BB2_4
.Lglue_BB2_8:                                //   in Loop: Header=BB2_6 Depth=2
	mov	x2, sp
	mov	w0, #4                          // =0x4
	mov	x1, x20
	strb	wzr, [x22, x23]
	bl	__android_log_write
	cmp	w26, #10
	b.ne	.Lglue_BB2_10
// %bb.9:                               //   in Loop: Header=BB2_6 Depth=2
	mov	x23, xzr
	b	.Lglue_BB2_5
.Lglue_BB2_10:                               //   in Loop: Header=BB2_6 Depth=2
	strb	w26, [sp]
	mov	w23, #1                         // =0x1
	b	.Lglue_BB2_5
.Lglue_BB2_11:
	mov	x23, xzr
.Lglue_BB2_12:
	cbz	x23, .Lglue_BB2_14
// %bb.13:
	mov	x8, sp
	adrp	x1, .Lglue_.str
	add	x1, x1, :lo12:.Lglue_.str
	mov	x2, sp
	mov	w0, #4                          // =0x4
	strb	wzr, [x8, x23]
	bl	__android_log_write
.Lglue_BB2_14:
	mov	x0, xzr
	add	sp, sp, #1536
	ldp	x20, x19, [sp, #64]             // 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             // 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             // 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             // 16-byte Folded Reload
	ldp	x29, x30, [sp], #80             // 16-byte Folded Reload
	ret
.Lglue_func_end2:
	.size	xt_log_pump, .Lglue_func_end2-xt_log_pump
                                        // -- End function
	.type	.Lglue_.str,@object                  // @.str
	.section	.rodata.str1.1,"aMS",@progbits,1
.Lglue_.str:
	.asciz	"xcapp"
	.size	.Lglue_.str, 6

	.type	.Lglue_.str.1,@object                // @.str.1
.Lglue_.str.1:
	.asciz	"=== xc start ==="
	.size	.Lglue_.str.1, 17

	.type	.Lglue_.str.2,@object                // @.str.2
.Lglue_.str.2:
	.asciz	"=== xc finished ==="
	.size	.Lglue_.str.2, 20

	.ident	"Android (12027248, +pgo, -bolt, +lto, -mlgo, based on r522817) clang version 18.0.1 (https://android.googlesource.com/toolchain/llvm-project d8003a456d14a3deb8054cdaa529ffbf02d9b262)"
	.section	".note.GNU-stack","",@progbits
