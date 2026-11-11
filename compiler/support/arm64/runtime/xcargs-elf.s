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
// by the Free Software Foundation -- see COPYING.RUNTIME in support/
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.
//
// GENERATED from src/xtc/support-src/rt-xcargs.c by
// `python3 tools/regen-runtimes.py xcargs-arm64`; do not edit.
// regenerated with: Apple clang version 17.0.0 (clang-1700.3.19.1)
	.text
	.file	"rt-xcargs.c"
	.globl	_xt_xcargs                      // -- Begin function _xt_xcargs
	.p2align	2
	.type	_xt_xcargs,@function
_xt_xcargs:                             // @_xt_xcargs
// %bb.0:
	cmp	w0, #1
	b.lt	.Lxa_BB0_111
// %bb.1:
	sub	sp, sp, #384
	stp	x22, x21, [sp, #352]            // 16-byte Folded Spill
	mov	x21, x1
	stp	x29, x30, [sp, #288]            // 16-byte Folded Spill
	stp	x28, x27, [sp, #304]            // 16-byte Folded Spill
	stp	x26, x25, [sp, #320]            // 16-byte Folded Spill
	stp	x24, x23, [sp, #336]            // 16-byte Folded Spill
	stp	x20, x19, [sp, #368]            // 16-byte Folded Spill
	cbz	x1, .Lxa_BB0_110
// %bb.2:
	cmp	w0, #2
	mov	w29, #1                         // =0x1
	mov	w22, #1                         // =0x1
	b.lt	.Lxa_BB0_102
// %bb.3:
	add	x8, sp, #64
	adrp	x23, .Lxa_.str.4
	add	x23, x23, :lo12:.Lxa_.str.4
	adrp	x25, xt_xa_table
	add	x25, x25, :lo12:xt_xa_table
	orr	x24, x8, #0x3
	adrp	x12, .Lxa_.str.2
	add	x12, x12, :lo12:.Lxa_.str.2
	mov	w8, w0
	mov	w19, #1537                      // =0x601
	add	x20, sp, #128
	adrp	x14, .Lxa_.str.11
	add	x14, x14, :lo12:.Lxa_.str.11
	adrp	x13, .Lxa_.str
	add	x13, x13, :lo12:.Lxa_.str
	mov	w11, #1                         // =0x1
	str	w0, [sp, #20]                   // 4-byte Folded Spill
	str	x8, [sp, #40]                   // 8-byte Folded Spill
	str	x21, [sp, #24]                  // 8-byte Folded Spill
.Lxa_BB0_4:                                // =>This Loop Header: Depth=1
                                        //     Child Loop BB0_8 Depth 2
                                        //     Child Loop BB0_13 Depth 2
                                        //     Child Loop BB0_15 Depth 2
                                        //     Child Loop BB0_20 Depth 2
                                        //     Child Loop BB0_24 Depth 2
                                        //     Child Loop BB0_28 Depth 2
                                        //       Child Loop BB0_29 Depth 3
                                        //       Child Loop BB0_32 Depth 3
                                        //       Child Loop BB0_52 Depth 3
                                        //       Child Loop BB0_38 Depth 3
                                        //       Child Loop BB0_44 Depth 3
                                        //       Child Loop BB0_48 Depth 3
                                        //     Child Loop BB0_60 Depth 2
                                        //     Child Loop BB0_69 Depth 2
                                        //     Child Loop BB0_79 Depth 2
                                        //     Child Loop BB0_84 Depth 2
                                        //       Child Loop BB0_86 Depth 3
                                        //       Child Loop BB0_89 Depth 3
                                        //       Child Loop BB0_94 Depth 3
	ldr	x26, [x21, x11, lsl #3]
	ldrb	w8, [x26]
	cmp	w8, #45
	b.ne	.Lxa_BB0_7
// %bb.5:                               //   in Loop: Header=BB0_4 Depth=1
	ldrb	w8, [x26, #1]
	cmp	w8, #45
	b.ne	.Lxa_BB0_7
// %bb.6:                               //   in Loop: Header=BB0_4 Depth=1
	ldrb	w8, [x26, #2]
	cbz	w8, .Lxa_BB0_73
.Lxa_BB0_7:                                //   in Loop: Header=BB0_4 Depth=1
	mov	x8, xzr
.Lxa_BB0_8:                                //   Parent Loop BB0_4 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	cmp	x8, #5
	b.eq	.Lxa_BB0_12
// %bb.9:                               //   in Loop: Header=BB0_8 Depth=2
	ldrb	w9, [x13, x8]
	ldrb	w10, [x26, x8]
	add	x8, x8, #1
	cmp	w10, w9
	b.eq	.Lxa_BB0_8
// %bb.10:                              //   in Loop: Header=BB0_4 Depth=1
	cbz	w9, .Lxa_BB0_12
// %bb.11:                              //   in Loop: Header=BB0_4 Depth=1
	add	w9, w22, #1
	mov	w8, wzr
	str	x26, [x21, w22, sxtw #3]
	mov	w22, w9
	b	.Lxa_BB0_99
.Lxa_BB0_12:                               //   in Loop: Header=BB0_4 Depth=1
	mov	x9, xzr
.Lxa_BB0_13:                               //   Parent Loop BB0_4 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldrb	w10, [x26, x9]
	mov	x8, x9
	add	x9, x9, #1
	cbnz	w10, .Lxa_BB0_13
// %bb.14:                              //   in Loop: Header=BB0_4 Depth=1
	sub	x10, x9, #1
	mov	w27, #5                         // =0x5
	cmp	x10, #6
	stp	x10, x11, [sp, #48]             // 16-byte Folded Spill
	b.lo	.Lxa_BB0_18
.Lxa_BB0_15:                               //   Parent Loop BB0_4 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldrb	w9, [x26, x27]
	cmp	w9, #61
	b.eq	.Lxa_BB0_18
// %bb.16:                              //   in Loop: Header=BB0_15 Depth=2
	add	x27, x27, #1
	cmp	x8, x27
	b.ne	.Lxa_BB0_15
// %bb.17:                              //   in Loop: Header=BB0_4 Depth=1
	mov	x27, x10
.Lxa_BB0_18:                               //   in Loop: Header=BB0_4 Depth=1
	cmp	x27, #9
	b.ne	.Lxa_BB0_58
// %bb.19:                              //   in Loop: Header=BB0_4 Depth=1
	mov	x8, xzr
	add	x9, x26, #5
.Lxa_BB0_20:                               //   Parent Loop BB0_4 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	cmp	x8, #4
	b.eq	.Lxa_BB0_23
// %bb.21:                              //   in Loop: Header=BB0_20 Depth=2
	ldrb	w10, [x12, x8]
	ldrb	w11, [x9, x8]
	add	x8, x8, #1
	cmp	w11, w10
	b.eq	.Lxa_BB0_20
// %bb.22:                              //   in Loop: Header=BB0_4 Depth=1
	cbnz	w10, .Lxa_BB0_58
.Lxa_BB0_23:                               //   in Loop: Header=BB0_4 Depth=1
	mov	x8, xzr
	str	w22, [sp, #36]                  // 4-byte Folded Spill
.Lxa_BB0_24:                               //   Parent Loop BB0_4 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldrb	w9, [x23, x8]
	add	x8, x8, #1
	cbnz	w9, .Lxa_BB0_24
// %bb.25:                              //   in Loop: Header=BB0_4 Depth=1
	sub	x2, x8, #1
	mov	w0, #1                          // =0x1
	mov	x1, x23
	bl	write
	mov	x23, x25
	b	.Lxa_BB0_28
.Lxa_BB0_26:                               //   in Loop: Header=BB0_28 Depth=2
	cbz	w9, .Lxa_BB0_35
.Lxa_BB0_27:                               //   in Loop: Header=BB0_28 Depth=2
	add	x8, x23, x21
	add	x23, x8, x28
	ldrb	w8, [x23, #1]!
	cbz	w8, .Lxa_BB0_57
.Lxa_BB0_28:                               //   Parent Loop BB0_4 Depth=1
                                        // =>  This Loop Header: Depth=2
                                        //       Child Loop BB0_29 Depth 3
                                        //       Child Loop BB0_32 Depth 3
                                        //       Child Loop BB0_52 Depth 3
                                        //       Child Loop BB0_38 Depth 3
                                        //       Child Loop BB0_44 Depth 3
                                        //       Child Loop BB0_48 Depth 3
	mov	x21, xzr
	add	x8, x23, #5
	add	x25, x23, #1
.Lxa_BB0_29:                               //   Parent Loop BB0_4 Depth=1
                                        //     Parent Loop BB0_28 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldrb	w9, [x23, x21]
	lsl	w10, w29, w9
	cmp	w9, #10
	and	w9, w10, w19
	ccmp	w9, #0, #4, ls
	b.ne	.Lxa_BB0_31
// %bb.30:                              //   in Loop: Header=BB0_29 Depth=3
	add	x21, x21, #1
	add	x8, x8, #1
	add	x25, x25, #1
	b	.Lxa_BB0_29
.Lxa_BB0_31:                               //   in Loop: Header=BB0_28 Depth=2
	add	x9, x23, x21
	mov	w28, #1                         // =0x1
.Lxa_BB0_32:                               //   Parent Loop BB0_4 Depth=1
                                        //     Parent Loop BB0_28 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldrb	w10, [x9, x28]
	lsl	w11, w29, w10
	cmp	w10, #10
	and	w10, w11, w19
	ccmp	w10, #0, #4, ls
	b.ne	.Lxa_BB0_34
// %bb.33:                              //   in Loop: Header=BB0_32 Depth=3
	add	x28, x28, #1
	b	.Lxa_BB0_32
.Lxa_BB0_34:                               //   in Loop: Header=BB0_28 Depth=2
	sub	x22, x28, #1
	cmp	x22, #5
	b.hs	.Lxa_BB0_50
.Lxa_BB0_35:                               //   in Loop: Header=BB0_28 Depth=2
	add	x0, sp, #128
	mov	x1, xzr
	mov	w2, #160                        // =0xa0
	adrp	x3, .Lxa_.str.5
	add	x3, x3, :lo12:.Lxa_.str.5
	mov	w4, #7                          // =0x7
	bl	xt_xa_cat
	cbz	x21, .Lxa_BB0_41
// %bb.36:                              //   in Loop: Header=BB0_28 Depth=2
	cmp	x0, #157
	mov	w13, #45                        // =0x2d
	b.hi	.Lxa_BB0_41
// %bb.37:                              //   in Loop: Header=BB0_28 Depth=2
	mov	x9, xzr
	add	x8, x20, x0
.Lxa_BB0_38:                               //   Parent Loop BB0_4 Depth=1
                                        //     Parent Loop BB0_28 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldrb	w10, [x23, x9]
	sub	w11, w10, #65
	add	w12, w10, #32
	cmp	w11, #26
	csel	w11, w12, w10, lo
	cmp	w10, #95
	add	x10, x9, #1
	csel	w11, w13, w11, eq
	cmp	x10, x21
	strb	w11, [x8, x9]
	b.hs	.Lxa_BB0_40
// %bb.39:                              //   in Loop: Header=BB0_38 Depth=3
	add	x9, x0, x9
	cmp	x9, #157
	mov	x9, x10
	b.lo	.Lxa_BB0_38
.Lxa_BB0_40:                               //   in Loop: Header=BB0_28 Depth=2
	add	x0, x0, x10
.Lxa_BB0_41:                               //   in Loop: Header=BB0_28 Depth=2
	cmp	x28, #1
	b.eq	.Lxa_BB0_47
// %bb.42:                              //   in Loop: Header=BB0_28 Depth=2
	cmp	x0, #157
	b.hi	.Lxa_BB0_47
// %bb.43:                              //   in Loop: Header=BB0_28 Depth=2
	mov	x9, xzr
	add	x8, x20, x0
.Lxa_BB0_44:                               //   Parent Loop BB0_4 Depth=1
                                        //     Parent Loop BB0_28 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	add	x10, x9, #1
	ldrb	w11, [x25], #1
	cmp	x10, x22
	strb	w11, [x8, x9]
	b.hs	.Lxa_BB0_46
// %bb.45:                              //   in Loop: Header=BB0_44 Depth=3
	add	x9, x0, x9
	cmp	x9, #157
	mov	x9, x10
	b.lo	.Lxa_BB0_44
.Lxa_BB0_46:                               //   in Loop: Header=BB0_28 Depth=2
	add	x0, x0, x10
.Lxa_BB0_47:                               //   in Loop: Header=BB0_28 Depth=2
	mov	x8, xzr
	mov	w9, #10                         // =0xa
	strh	w9, [x20, x0]
.Lxa_BB0_48:                               //   Parent Loop BB0_4 Depth=1
                                        //     Parent Loop BB0_28 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldrb	w9, [x20, x8]
	add	x8, x8, #1
	cbnz	w9, .Lxa_BB0_48
// %bb.49:                              //   in Loop: Header=BB0_28 Depth=2
	sub	x2, x8, #1
	add	x1, sp, #128
	mov	w0, #1                          // =0x1
	bl	write
	b	.Lxa_BB0_27
.Lxa_BB0_50:                               //   in Loop: Header=BB0_28 Depth=2
	cmp	x28, #6
	mov	w10, #6                         // =0x6
	mov	w9, wzr
	csel	x10, x28, x10, hi
	sub	x10, x10, #5
	b	.Lxa_BB0_52
.Lxa_BB0_51:                               //   in Loop: Header=BB0_52 Depth=3
	subs	x10, x10, #1
	add	x8, x8, #1
	b.eq	.Lxa_BB0_26
.Lxa_BB0_52:                               //   Parent Loop BB0_4 Depth=1
                                        //     Parent Loop BB0_28 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldurb	w11, [x8, #-4]
	cmp	w11, #116
	b.ne	.Lxa_BB0_51
// %bb.53:                              //   in Loop: Header=BB0_52 Depth=3
	ldurb	w11, [x8, #-3]
	cmp	w11, #101
	b.ne	.Lxa_BB0_51
// %bb.54:                              //   in Loop: Header=BB0_52 Depth=3
	ldurb	w11, [x8, #-2]
	cmp	w11, #115
	b.ne	.Lxa_BB0_51
// %bb.55:                              //   in Loop: Header=BB0_52 Depth=3
	ldurb	w11, [x8, #-1]
	cmp	w11, #116
	b.ne	.Lxa_BB0_51
// %bb.56:                              //   in Loop: Header=BB0_52 Depth=3
	ldrb	w11, [x8]
	cmp	w11, #58
	csinc	w9, w9, wzr, ne
	b	.Lxa_BB0_51
.Lxa_BB0_57:                               //   in Loop: Header=BB0_4 Depth=1
	mov	w0, #1                          // =0x1
	adrp	x1, .Lxa_.str.6
	add	x1, x1, :lo12:.Lxa_.str.6
	mov	w2, #92                         // =0x5c
	bl	write
	mov	w0, wzr
	bl	exit
	ldr	x21, [sp, #24]                  // 8-byte Folded Reload
	ldr	w22, [sp, #36]                  // 4-byte Folded Reload
	adrp	x23, .Lxa_.str.4
	add	x23, x23, :lo12:.Lxa_.str.4
	adrp	x25, xt_xa_table
	add	x25, x25, :lo12:xt_xa_table
	adrp	x14, .Lxa_.str.11
	add	x14, x14, :lo12:.Lxa_.str.11
.Lxa_BB0_58:                               //   in Loop: Header=BB0_4 Depth=1
	sub	x9, x27, #5
	add	x8, x26, #5
	cmp	x9, #5
	b.ne	.Lxa_BB0_63
// %bb.59:                              //   in Loop: Header=BB0_4 Depth=1
	mov	x9, xzr
	adrp	x12, .Lxa_.str.7
	add	x12, x12, :lo12:.Lxa_.str.7
.Lxa_BB0_60:                               //   Parent Loop BB0_4 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	cmp	x9, #5
	b.eq	.Lxa_BB0_64
// %bb.61:                              //   in Loop: Header=BB0_60 Depth=2
	ldrb	w10, [x12, x9]
	ldrb	w11, [x8, x9]
	add	x9, x9, #1
	cmp	w11, w10
	b.eq	.Lxa_BB0_60
// %bb.62:                              //   in Loop: Header=BB0_4 Depth=1
	mov	w9, #5                          // =0x5
.Lxa_BB0_63:                               //   in Loop: Header=BB0_4 Depth=1
	cbnz	x9, .Lxa_BB0_65
	b	.Lxa_BB0_75
.Lxa_BB0_64:                               //   in Loop: Header=BB0_4 Depth=1
	mov	w9, #9                          // =0x9
	adrp	x8, .Lxa_.str.8
	add	x8, x8, :lo12:.Lxa_.str.8
	cbz	x9, .Lxa_BB0_75
.Lxa_BB0_65:                               //   in Loop: Header=BB0_4 Depth=1
	sub	x10, x9, #61
	cmn	x10, #65
	b.lo	.Lxa_BB0_75
// %bb.66:                              //   in Loop: Header=BB0_4 Depth=1
	mov	w11, #17240                     // =0x4358
	mov	x10, xzr
	mov	w12, #95                        // =0x5f
	strh	w11, [sp, #64]
	mov	w11, #1                         // =0x1
	strb	w12, [sp, #66]
	b	.Lxa_BB0_69
.Lxa_BB0_67:                               //   in Loop: Header=BB0_69 Depth=2
	sub	w12, w12, #32
.Lxa_BB0_68:                               //   in Loop: Header=BB0_69 Depth=2
	strb	w12, [x24, x10]
	add	x10, x10, #1
	cmp	x10, x9
	cset	w11, lo
	cmp	x9, x10
	b.eq	.Lxa_BB0_76
.Lxa_BB0_69:                               //   Parent Loop BB0_4 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldrb	w12, [x8, x10]
	sub	w13, w12, #97
	cmp	w13, #25
	b.ls	.Lxa_BB0_67
// %bb.70:                              //   in Loop: Header=BB0_69 Depth=2
	sub	w13, w12, #48
	cmp	w13, #10
	b.lo	.Lxa_BB0_68
// %bb.71:                              //   in Loop: Header=BB0_69 Depth=2
	cmp	w12, #45
	b.ne	.Lxa_BB0_74
// %bb.72:                              //   in Loop: Header=BB0_69 Depth=2
	mov	w12, #95                        // =0x5f
	b	.Lxa_BB0_68
.Lxa_BB0_73:                               //   in Loop: Header=BB0_4 Depth=1
	mov	w8, #1                          // =0x1
	b	.Lxa_BB0_99
.Lxa_BB0_74:                               //   in Loop: Header=BB0_4 Depth=1
	tbz	w11, #0, .Lxa_BB0_76
.Lxa_BB0_75:                               //   in Loop: Header=BB0_4 Depth=1
	mov	x0, x26
	mov	x1, x27
	adrp	x2, .Lxa_.str.3
	add	x2, x2, :lo12:.Lxa_.str.3
	bl	xt_xa_fail
	adrp	x14, .Lxa_.str.11
	add	x14, x14, :lo12:.Lxa_.str.11
	b	.Lxa_BB0_77
.Lxa_BB0_76:                               //   in Loop: Header=BB0_4 Depth=1
	strb	wzr, [x24, x9]
.Lxa_BB0_77:                               //   in Loop: Header=BB0_4 Depth=1
	ldrb	w8, [sp, #64]
	add	x11, sp, #64
	cmp	w8, #88
	b.ne	.Lxa_BB0_82
// %bb.78:                              //   in Loop: Header=BB0_4 Depth=1
	mov	w8, #1                          // =0x1
.Lxa_BB0_79:                               //   Parent Loop BB0_4 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	cmp	x8, #14
	b.eq	.Lxa_BB0_81
// %bb.80:                              //   in Loop: Header=BB0_79 Depth=2
	ldrb	w9, [x11, x8]
	ldrb	w10, [x14, x8]
	add	x8, x8, #1
	cmp	w9, w10
	b.eq	.Lxa_BB0_79
	b	.Lxa_BB0_82
.Lxa_BB0_81:                               //   in Loop: Header=BB0_4 Depth=1
	mov	x0, x26
	mov	x1, x27
	adrp	x2, .Lxa_.str.12
	add	x2, x2, :lo12:.Lxa_.str.12
	bl	xt_xa_fail
.Lxa_BB0_82:                               //   in Loop: Header=BB0_4 Depth=1
	mov	x9, x25
	b	.Lxa_BB0_84
.Lxa_BB0_83:                               //   in Loop: Header=BB0_84 Depth=2
	mov	w10, wzr
	tbz	w10, #0, .Lxa_BB0_96
.Lxa_BB0_84:                               //   Parent Loop BB0_4 Depth=1
                                        // =>  This Loop Header: Depth=2
                                        //       Child Loop BB0_86 Depth 3
                                        //       Child Loop BB0_89 Depth 3
                                        //       Child Loop BB0_94 Depth 3
	ldrb	w8, [x9]
	cbz	w8, .Lxa_BB0_97
// %bb.85:                              //   in Loop: Header=BB0_84 Depth=2
	mov	x11, xzr
	add	x10, x9, #2
.Lxa_BB0_86:                               //   Parent Loop BB0_4 Depth=1
                                        //     Parent Loop BB0_84 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldrb	w12, [x9, x11]
	lsl	w13, w29, w12
	cmp	w12, #10
	and	w12, w13, w19
	ccmp	w12, #0, #4, ls
	b.ne	.Lxa_BB0_88
// %bb.87:                              //   in Loop: Header=BB0_86 Depth=3
	add	x11, x11, #1
	add	x10, x10, #1
	b	.Lxa_BB0_86
.Lxa_BB0_88:                               //   in Loop: Header=BB0_84 Depth=2
	mov	x12, xzr
	cbz	x11, .Lxa_BB0_92
.Lxa_BB0_89:                               //   Parent Loop BB0_4 Depth=1
                                        //     Parent Loop BB0_84 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldrb	w13, [x24, x12]
	ldrb	w14, [x9, x12]
	cmp	w13, w14
	b.ne	.Lxa_BB0_92
// %bb.90:                              //   in Loop: Header=BB0_89 Depth=3
	add	x12, x12, #1
	cmp	x11, x12
	b.ne	.Lxa_BB0_89
// %bb.91:                              //   in Loop: Header=BB0_84 Depth=2
	mov	x12, x11
.Lxa_BB0_92:                               //   in Loop: Header=BB0_84 Depth=2
	cmp	x12, x11
	b.ne	.Lxa_BB0_94
// %bb.93:                              //   in Loop: Header=BB0_84 Depth=2
	ldrb	w11, [x24, x11]
	cbz	w11, .Lxa_BB0_83
.Lxa_BB0_94:                               //   Parent Loop BB0_4 Depth=1
                                        //     Parent Loop BB0_84 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	mov	x9, x10
	ldurb	w10, [x10, #-1]
	lsl	w11, w29, w10
	cmp	w10, #10
	and	w10, w11, w19
	ccmp	w10, #0, #4, ls
	add	x10, x9, #1
	b.eq	.Lxa_BB0_94
// %bb.95:                              //   in Loop: Header=BB0_84 Depth=2
	mov	w10, #1                         // =0x1
	tbnz	w10, #0, .Lxa_BB0_84
.Lxa_BB0_96:                               //   in Loop: Header=BB0_4 Depth=1
	cbnz	w8, .Lxa_BB0_98
.Lxa_BB0_97:                               //   in Loop: Header=BB0_4 Depth=1
	mov	x0, x26
	mov	x1, x27
	adrp	x2, .Lxa_.str.3
	add	x2, x2, :lo12:.Lxa_.str.3
	bl	xt_xa_fail
.Lxa_BB0_98:                               //   in Loop: Header=BB0_4 Depth=1
	ldr	x9, [sp, #48]                   // 8-byte Folded Reload
	add	x8, x26, x27
	add	x0, sp, #64
	mov	w2, #1                          // =0x1
	cmp	x27, x9
	adrp	x9, .Lxa_.str.1
	add	x9, x9, :lo12:.Lxa_.str.1
	csinc	x1, x9, x8, hs
	bl	setenv
	ldr	x11, [sp, #56]                  // 8-byte Folded Reload
	adrp	x14, .Lxa_.str.11
	add	x14, x14, :lo12:.Lxa_.str.11
	mov	w8, wzr
	adrp	x12, .Lxa_.str.2
	add	x12, x12, :lo12:.Lxa_.str.2
	adrp	x13, .Lxa_.str
	add	x13, x13, :lo12:.Lxa_.str
.Lxa_BB0_99:                               //   in Loop: Header=BB0_4 Depth=1
	tbnz	w8, #0, .Lxa_BB0_103
// %bb.100:                             //   in Loop: Header=BB0_4 Depth=1
	ldr	x8, [sp, #40]                   // 8-byte Folded Reload
	add	x11, x11, #1
	cmp	x11, x8
	b.ne	.Lxa_BB0_4
// %bb.101:
	ldr	w0, [sp, #20]                   // 4-byte Folded Reload
	mov	w29, w0
.Lxa_BB0_102:
	subs	w8, w0, w29
	b.gt	.Lxa_BB0_104
	b	.Lxa_BB0_106
.Lxa_BB0_103:
	ldr	w0, [sp, #20]                   // 4-byte Folded Reload
	mov	w29, w11
	subs	w8, w0, w29
	b.le	.Lxa_BB0_106
.Lxa_BB0_104:
	add	x9, x21, w29, uxtw #3
	add	x10, x21, w22, sxtw #3
	add	w11, w22, w0
	sub	w22, w11, w29
.Lxa_BB0_105:                              // =>This Inner Loop Header: Depth=1
	ldr	x11, [x9], #8
	subs	w8, w8, #1
	str	x11, [x10], #8
	b.ne	.Lxa_BB0_105
.Lxa_BB0_106:
	cmp	w22, w0
	b.ge	.Lxa_BB0_109
// %bb.107:
	mov	w9, w0
	add	x8, x21, w22, sxtw #3
	sub	x9, x9, w22, sxtw
.Lxa_BB0_108:                              // =>This Inner Loop Header: Depth=1
	subs	x9, x9, #1
	str	xzr, [x8], #8
	b.ne	.Lxa_BB0_108
.Lxa_BB0_109:
	mov	w0, w22
.Lxa_BB0_110:
	ldp	x20, x19, [sp, #368]            // 16-byte Folded Reload
	ldp	x22, x21, [sp, #352]            // 16-byte Folded Reload
	ldp	x24, x23, [sp, #336]            // 16-byte Folded Reload
	ldp	x26, x25, [sp, #320]            // 16-byte Folded Reload
	ldp	x28, x27, [sp, #304]            // 16-byte Folded Reload
	ldp	x29, x30, [sp, #288]            // 16-byte Folded Reload
	add	sp, sp, #384
.Lxa_BB0_111:
	ret
.Lxa_func_end0:
	.size	_xt_xcargs, .Lxa_func_end0-_xt_xcargs
                                        // -- End function
	.p2align	2                               // -- Begin function xt_xa_fail
	.type	xt_xa_fail,@function
xt_xa_fail:                             // @xt_xa_fail
// %bb.0:
	sub	sp, sp, #304
	stp	x22, x21, [sp, #272]            // 16-byte Folded Spill
	mov	x21, x0
	adrp	x3, .Lxa_.str.9
	add	x3, x3, :lo12:.Lxa_.str.9
	stp	x20, x19, [sp, #288]            // 16-byte Folded Spill
	mov	x19, x2
	mov	x20, x1
	mov	x0, sp
	mov	x1, xzr
	mov	w2, #256                        // =0x100
	mov	w4, #4                          // =0x4
	stp	x29, x30, [sp, #256]            // 16-byte Folded Spill
	mov	x22, sp
	bl	xt_xa_cat
	mov	x1, x0
	mov	x0, sp
	mov	w2, #120                        // =0x78
	mov	x3, x21
	mov	x4, x20
	bl	xt_xa_cat
	mov	x1, x0
	mov	x0, sp
	mov	w2, #256                        // =0x100
	mov	x3, x19
	mov	w4, #256                        // =0x100
	bl	xt_xa_cat
	mov	x1, x0
	adrp	x3, .Lxa_.str.10
	add	x3, x3, :lo12:.Lxa_.str.10
	mov	x0, sp
	mov	w2, #256                        // =0x100
	mov	w4, #1                          // =0x1
	bl	xt_xa_cat
	mov	x8, xzr
.Lxa_BB1_1:                                // =>This Inner Loop Header: Depth=1
	ldrb	w9, [x22, x8]
	add	x8, x8, #1
	cbnz	w9, .Lxa_BB1_1
// %bb.2:
	sub	x2, x8, #1
	mov	x1, sp
	mov	w0, #2                          // =0x2
	bl	write
	mov	w0, #2                          // =0x2
	bl	exit
	ldp	x20, x19, [sp, #288]            // 16-byte Folded Reload
	ldp	x22, x21, [sp, #272]            // 16-byte Folded Reload
	ldp	x29, x30, [sp, #256]            // 16-byte Folded Reload
	add	sp, sp, #304
	ret
.Lxa_func_end1:
	.size	xt_xa_fail, .Lxa_func_end1-xt_xa_fail
                                        // -- End function
	.p2align	2                               // -- Begin function xt_xa_cat
	.type	xt_xa_cat,@function
xt_xa_cat:                              // @xt_xa_cat
// %bb.0:
	mov	x8, x0
	cbz	x4, .Lxa_BB2_5
.Lxa_BB2_1:                                // =>This Inner Loop Header: Depth=1
	ldrb	w9, [x3], #1
	cbz	w9, .Lxa_BB2_5
// %bb.2:                               //   in Loop: Header=BB2_1 Depth=1
	add	x0, x1, #1
	cmp	x0, x2
	b.hs	.Lxa_BB2_5
// %bb.3:                               //   in Loop: Header=BB2_1 Depth=1
	subs	x4, x4, #1
	strb	w9, [x8, x1]
	mov	x1, x0
	b.ne	.Lxa_BB2_1
// %bb.4:
	strb	wzr, [x8, x0]
	ret
.Lxa_BB2_5:
	mov	x0, x1
	strb	wzr, [x8, x0]
	ret
.Lxa_func_end2:
	.size	xt_xa_cat, .Lxa_func_end2-xt_xa_cat
                                        // -- End function
	.type	.Lxa_.str,@object                  // @.str
	.section	.rodata.str1.1,"aMS",@progbits,1
.Lxa_.str:
	.asciz	"--xc-"
	.size	.Lxa_.str, 6

	.type	.Lxa_.str.1,@object                // @.str.1
.Lxa_.str.1:
	.asciz	"1"
	.size	.Lxa_.str.1, 2

	.type	.Lxa_.str.2,@object                // @.str.2
.Lxa_.str.2:
	.asciz	"help"
	.size	.Lxa_.str.2, 5

	.type	.Lxa_.str.3,@object                // @.str.3
.Lxa_.str.3:
	.asciz	": unknown option (--xc-help lists them)"
	.size	.Lxa_.str.3, 40

	.type	.Lxa_.str.4,@object                // @.str.4
.Lxa_.str.4:
	.asciz	"Options for the par runtime, taken out of the arguments before main.\nEach sets the variable it names (--xc-par-report is XC_PAR_REPORT=1),\noverriding the environment. Arguments after -- are left alone.\n\n"
	.size	.Lxa_.str.4, 204

	.type	xt_xa_table,@object             // @xt_xa_table
xt_xa_table:
	.asciz	"PAR\t=cpu|gpu|gpus|all|auto  where every par block runs\nPAR_THREADS\t=<n>  threads a block on the CPU uses\nPAR_REPORT\t[=2]  print where each block ran and what auto measured\nPAR_FORGET\t  remove what auto learned, so it measures again\nPAR_PROBE\t  measure every block to the end on its first run (also --xc-probe)\nPAR_GPU\t=cuda|vulkan  the GPU interface where both exist\nPAR_VULKAN_DEVICE\t=<n>  the Vulkan device, by index\nPAR_CUDA_DEVICES\t=<n,...>  the CUDA cards that take tiles\nPAR_WORKERS\t=cpu,cuda,metal,vulkan,remote  the devices that share tiles\nPAR_TILES\t=0  run each block in one piece\nPAR_TILE_MB\t=<n>  megabytes a tile moves each way\nPAR_TRACE\t[=<file>|<host:port>]  record each run's tiles\nPAR_PIN\t=0  Linux: leave the CPU threads unpinned\nPAR_REMOTE\t=<host[:port],...>|mdns|none  the xcd daemons to use\nPAR_POOL\t=<name>  find the daemons of that pool by mDNS\nPAR_VERIFY\t=0|all  how many remote tiles are checked on the CPU\nTLS_LIB\t=<file>  the TLS library for connections to daemons\nPAR_VARIANT\t=<name>  test: the kernel variant a device runs\nPAR_VK_FULL\t=0  test: leave out Vulkan's full-dispatch form\nPAR_VULKAN_LOSE\t=<n>  test: the Vulkan device reads as lost after n submits\nPAR_DIE_AFTER\t=<n>  test: drop a remote connection after n tiles\nPAR_MACHINE\t=<name>  test: the machine name a daemon gives\n"
	.size	xt_xa_table, 1313

	.type	.Lxa_.str.5,@object                // @.str.5
.Lxa_.str.5:
	.asciz	"  --xc-"
	.size	.Lxa_.str.5, 8

	.type	.Lxa_.str.6,@object                // @.str.6
.Lxa_.str.6:
	.asciz	"  --xc-help  this list\n\nXC_PAR_SECRET has no option: a process listing shows the arguments.\n"
	.size	.Lxa_.str.6, 93

	.type	.Lxa_.str.7,@object                // @.str.7
.Lxa_.str.7:
	.asciz	"probe"
	.size	.Lxa_.str.7, 6

	.type	.Lxa_.str.8,@object                // @.str.8
.Lxa_.str.8:
	.asciz	"par-probe"
	.size	.Lxa_.str.8, 10

	.type	.Lxa_.str.9,@object                // @.str.9
.Lxa_.str.9:
	.asciz	"xc: "
	.size	.Lxa_.str.9, 5

	.type	.Lxa_.str.10,@object               // @.str.10
.Lxa_.str.10:
	.asciz	"\n"
	.size	.Lxa_.str.10, 2

	.type	.Lxa_.str.11,@object               // @.str.11
.Lxa_.str.11:
	.asciz	"XC_PAR_SECRET"
	.size	.Lxa_.str.11, 14

	.type	.Lxa_.str.12,@object               // @.str.12
.Lxa_.str.12:
	.asciz	": refused, a process listing shows the arguments; set XC_PAR_SECRET in the environment"
	.size	.Lxa_.str.12, 87

	.ident	"Apple clang version 17.0.0 (clang-1700.3.19.1)"
	.section	".note.GNU-stack","",@progbits
