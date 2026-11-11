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
// `python3 tools/regen-runtimes.py xcargs-macos`; do not edit.
// regenerated with: Apple clang version 17.0.0 (clang-1700.3.19.1)
	.section	__TEXT,__text,regular,pure_instructions
	.build_version macos, 15, 0	sdk_version 26, 0
	.globl	__xt_xcargs                     ; -- Begin function _xt_xcargs
	.p2align	2
__xt_xcargs:                            ; @_xt_xcargs
; %bb.0:
	cmp	w0, #1
	b.lt	Lxa_BB0_101
; %bb.1:
	sub	sp, sp, #400
	stp	x28, x27, [sp, #304]            ; 16-byte Folded Spill
	stp	x26, x25, [sp, #320]            ; 16-byte Folded Spill
	stp	x24, x23, [sp, #336]            ; 16-byte Folded Spill
	stp	x22, x21, [sp, #352]            ; 16-byte Folded Spill
	stp	x20, x19, [sp, #368]            ; 16-byte Folded Spill
	stp	x29, x30, [sp, #384]            ; 16-byte Folded Spill
	mov	x21, x1
	cbz	x1, Lxa_BB0_100
; %bb.2:
	mov	w25, #1                         ; =0x1
	mov	w22, #1                         ; =0x1
	cmp	w0, #2
	b.lt	Lxa_BB0_92
; %bb.3:
	add	x8, sp, #80
	add	x24, x8, #3
	str	w0, [sp, #20]                   ; 4-byte Folded Spill
	mov	w8, w0
	str	x8, [sp, #40]                   ; 8-byte Folded Spill
	mov	w19, #1537                      ; =0x601
	add	x28, sp, #144
	mov	w20, #45                        ; =0x2d
Lxa_loh0:
	adrp	x12, l_xa.str.2@PAGE
Lxa_loh1:
	add	x12, x12, l_xa.str.2@PAGEOFF
Lxa_loh2:
	adrp	x14, l_xa.str.11@PAGE
Lxa_loh3:
	add	x14, x14, l_xa.str.11@PAGEOFF
	mov	w11, #1                         ; =0x1
Lxa_loh4:
	adrp	x13, l_xa.str@PAGE
Lxa_loh5:
	add	x13, x13, l_xa.str@PAGEOFF
	str	x21, [sp, #24]                  ; 8-byte Folded Spill
Lxa_BB0_4:                                 ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB0_8 Depth 2
                                        ;     Child Loop BB0_13 Depth 2
                                        ;     Child Loop BB0_15 Depth 2
                                        ;     Child Loop BB0_20 Depth 2
                                        ;     Child Loop BB0_24 Depth 2
                                        ;     Child Loop BB0_26 Depth 2
                                        ;       Child Loop BB0_27 Depth 3
                                        ;       Child Loop BB0_30 Depth 3
                                        ;       Child Loop BB0_35 Depth 3
                                        ;       Child Loop BB0_41 Depth 3
                                        ;       Child Loop BB0_45 Depth 3
                                        ;     Child Loop BB0_50 Depth 2
                                        ;     Child Loop BB0_59 Depth 2
                                        ;     Child Loop BB0_69 Depth 2
                                        ;     Child Loop BB0_74 Depth 2
                                        ;       Child Loop BB0_76 Depth 3
                                        ;       Child Loop BB0_79 Depth 3
                                        ;       Child Loop BB0_84 Depth 3
	ldr	x15, [x21, x11, lsl #3]
	ldrb	w8, [x15]
	cmp	w8, #45
	b.ne	Lxa_BB0_7
; %bb.5:                                ;   in Loop: Header=BB0_4 Depth=1
	ldrb	w8, [x15, #1]
	cmp	w8, #45
	b.ne	Lxa_BB0_7
; %bb.6:                                ;   in Loop: Header=BB0_4 Depth=1
	ldrb	w8, [x15, #2]
	cbz	w8, Lxa_BB0_63
Lxa_BB0_7:                                 ;   in Loop: Header=BB0_4 Depth=1
	mov	x8, #0                          ; =0x0
Lxa_BB0_8:                                 ;   Parent Loop BB0_4 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	cmp	x8, #5
	b.eq	Lxa_BB0_12
; %bb.9:                                ;   in Loop: Header=BB0_8 Depth=2
	ldrb	w9, [x13, x8]
	ldrb	w10, [x15, x8]
	add	x8, x8, #1
	cmp	w10, w9
	b.eq	Lxa_BB0_8
; %bb.10:                               ;   in Loop: Header=BB0_4 Depth=1
	cbz	w9, Lxa_BB0_12
; %bb.11:                               ;   in Loop: Header=BB0_4 Depth=1
	mov	w8, #0                          ; =0x0
	str	x15, [x21, w22, sxtw #3]
	add	w22, w22, #1
	b	Lxa_BB0_89
Lxa_BB0_12:                                ;   in Loop: Header=BB0_4 Depth=1
	mov	x9, #0                          ; =0x0
Lxa_BB0_13:                                ;   Parent Loop BB0_4 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x8, x9
	ldrb	w10, [x15, x9]
	add	x9, x9, #1
	cbnz	w10, Lxa_BB0_13
; %bb.14:                               ;   in Loop: Header=BB0_4 Depth=1
	sub	x10, x9, #1
	cmp	x10, #6
	str	x10, [sp, #48]                  ; 8-byte Folded Spill
	mov	w16, #5                         ; =0x5
	b.lo	Lxa_BB0_18
Lxa_BB0_15:                                ;   Parent Loop BB0_4 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrb	w9, [x15, x16]
	cmp	w9, #61
	b.eq	Lxa_BB0_18
; %bb.16:                               ;   in Loop: Header=BB0_15 Depth=2
	add	x16, x16, #1
	cmp	x8, x16
	b.ne	Lxa_BB0_15
; %bb.17:                               ;   in Loop: Header=BB0_4 Depth=1
	mov	x16, x10
Lxa_BB0_18:                                ;   in Loop: Header=BB0_4 Depth=1
	cmp	x16, #9
	stp	x11, x16, [sp, #56]             ; 16-byte Folded Spill
	str	x15, [sp, #72]                  ; 8-byte Folded Spill
	b.ne	Lxa_BB0_48
; %bb.19:                               ;   in Loop: Header=BB0_4 Depth=1
	mov	x8, #0                          ; =0x0
	add	x9, x15, #5
Lxa_BB0_20:                                ;   Parent Loop BB0_4 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	cmp	x8, #4
	b.eq	Lxa_BB0_23
; %bb.21:                               ;   in Loop: Header=BB0_20 Depth=2
	ldrb	w10, [x12, x8]
	ldrb	w11, [x9, x8]
	add	x8, x8, #1
	cmp	w11, w10
	b.eq	Lxa_BB0_20
; %bb.22:                               ;   in Loop: Header=BB0_4 Depth=1
	cbnz	w10, Lxa_BB0_48
Lxa_BB0_23:                                ;   in Loop: Header=BB0_4 Depth=1
	str	w22, [sp, #36]                  ; 4-byte Folded Spill
	mov	x8, #0                          ; =0x0
Lxa_loh6:
	adrp	x1, l_xa.str.4@PAGE
Lxa_loh7:
	add	x1, x1, l_xa.str.4@PAGEOFF
Lxa_BB0_24:                                ;   Parent Loop BB0_4 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrb	w9, [x1, x8]
	add	x8, x8, #1
	cbnz	w9, Lxa_BB0_24
; %bb.25:                               ;   in Loop: Header=BB0_4 Depth=1
	sub	x2, x8, #1
	mov	w0, #1                          ; =0x1
	bl	_write
Lxa_loh8:
	adrp	x22, _xt_xa_table@PAGE
Lxa_loh9:
	add	x22, x22, _xt_xa_table@PAGEOFF
Lxa_BB0_26:                                ;   Parent Loop BB0_4 Depth=1
                                        ; =>  This Loop Header: Depth=2
                                        ;       Child Loop BB0_27 Depth 3
                                        ;       Child Loop BB0_30 Depth 3
                                        ;       Child Loop BB0_35 Depth 3
                                        ;       Child Loop BB0_41 Depth 3
                                        ;       Child Loop BB0_45 Depth 3
	mov	x26, #0                         ; =0x0
	add	x21, x22, #2
	add	x23, x22, #1
Lxa_BB0_27:                                ;   Parent Loop BB0_4 Depth=1
                                        ;     Parent Loop BB0_26 Depth=2
                                        ; =>    This Inner Loop Header: Depth=3
	ldrb	w8, [x22, x26]
	cmp	w8, #10
	lsl	w8, w25, w8
	and	w8, w8, w19
	ccmp	w8, #0, #4, ls
	b.ne	Lxa_BB0_29
; %bb.28:                               ;   in Loop: Header=BB0_27 Depth=3
	add	x26, x26, #1
	add	x21, x21, #1
	add	x23, x23, #1
	b	Lxa_BB0_27
Lxa_BB0_29:                                ;   in Loop: Header=BB0_26 Depth=2
	mov	x27, #0                         ; =0x0
Lxa_BB0_30:                                ;   Parent Loop BB0_4 Depth=1
                                        ;     Parent Loop BB0_26 Depth=2
                                        ; =>    This Inner Loop Header: Depth=3
	ldurb	w8, [x21, #-1]
	cmp	w8, #10
	lsl	w8, w25, w8
	and	w8, w8, w19
	ccmp	w8, #0, #4, ls
	b.ne	Lxa_BB0_32
; %bb.31:                               ;   in Loop: Header=BB0_30 Depth=3
	add	x21, x21, #1
	sub	x27, x27, #1
	b	Lxa_BB0_30
Lxa_BB0_32:                                ;   in Loop: Header=BB0_26 Depth=2
	add	x0, sp, #144
	mov	x1, #0                          ; =0x0
	mov	w2, #160                        ; =0xa0
Lxa_loh10:
	adrp	x3, l_xa.str.5@PAGE
Lxa_loh11:
	add	x3, x3, l_xa.str.5@PAGEOFF
	mov	w4, #7                          ; =0x7
	bl	_xt_xa_cat
	cbz	x26, Lxa_BB0_38
; %bb.33:                               ;   in Loop: Header=BB0_26 Depth=2
	cmp	x0, #157
	b.hi	Lxa_BB0_38
; %bb.34:                               ;   in Loop: Header=BB0_26 Depth=2
	mov	x9, #0                          ; =0x0
	add	x8, x28, x0
Lxa_BB0_35:                                ;   Parent Loop BB0_4 Depth=1
                                        ;     Parent Loop BB0_26 Depth=2
                                        ; =>    This Inner Loop Header: Depth=3
	ldrb	w10, [x22, x9]
	sub	w11, w10, #65
	add	w12, w10, #32
	cmp	w11, #26
	csel	w11, w12, w10, lo
	cmp	w10, #95
	csel	w10, w20, w11, eq
	strb	w10, [x8, x9]
	add	x10, x9, #1
	cmp	x10, x26
	b.hs	Lxa_BB0_37
; %bb.36:                               ;   in Loop: Header=BB0_35 Depth=3
	add	x11, x0, x9
	mov	x9, x10
	cmp	x11, #157
	b.lo	Lxa_BB0_35
Lxa_BB0_37:                                ;   in Loop: Header=BB0_26 Depth=2
	add	x0, x0, x10
Lxa_BB0_38:                                ;   in Loop: Header=BB0_26 Depth=2
	cbz	x27, Lxa_BB0_44
; %bb.39:                               ;   in Loop: Header=BB0_26 Depth=2
	cmp	x0, #157
	b.hi	Lxa_BB0_44
; %bb.40:                               ;   in Loop: Header=BB0_26 Depth=2
	mov	x10, #0                         ; =0x0
	neg	x8, x27
	add	x9, x28, x0
Lxa_BB0_41:                                ;   Parent Loop BB0_4 Depth=1
                                        ;     Parent Loop BB0_26 Depth=2
                                        ; =>    This Inner Loop Header: Depth=3
	ldrb	w11, [x23], #1
	strb	w11, [x9, x10]
	add	x11, x10, #1
	cmp	x11, x8
	b.hs	Lxa_BB0_43
; %bb.42:                               ;   in Loop: Header=BB0_41 Depth=3
	add	x12, x0, x10
	mov	x10, x11
	cmp	x12, #157
	b.lo	Lxa_BB0_41
Lxa_BB0_43:                                ;   in Loop: Header=BB0_26 Depth=2
	add	x0, x0, x11
Lxa_BB0_44:                                ;   in Loop: Header=BB0_26 Depth=2
	mov	x8, #0                          ; =0x0
	mov	w9, #10                         ; =0xa
	strh	w9, [x28, x0]
Lxa_BB0_45:                                ;   Parent Loop BB0_4 Depth=1
                                        ;     Parent Loop BB0_26 Depth=2
                                        ; =>    This Inner Loop Header: Depth=3
	ldrb	w9, [x28, x8]
	add	x8, x8, #1
	cbnz	w9, Lxa_BB0_45
; %bb.46:                               ;   in Loop: Header=BB0_26 Depth=2
	sub	x2, x8, #1
	add	x1, sp, #144
	mov	w0, #1                          ; =0x1
	bl	_write
	ldrb	w8, [x21]
	mov	x22, x21
	cbnz	w8, Lxa_BB0_26
; %bb.47:                               ;   in Loop: Header=BB0_4 Depth=1
	mov	w0, #1                          ; =0x1
Lxa_loh12:
	adrp	x1, l_xa.str.6@PAGE
Lxa_loh13:
	add	x1, x1, l_xa.str.6@PAGEOFF
	mov	w2, #92                         ; =0x5c
	bl	_write
	mov	w0, #0                          ; =0x0
	bl	_exit
	ldr	x21, [sp, #24]                  ; 8-byte Folded Reload
	ldr	w22, [sp, #36]                  ; 4-byte Folded Reload
Lxa_loh14:
	adrp	x14, l_xa.str.11@PAGE
Lxa_loh15:
	add	x14, x14, l_xa.str.11@PAGEOFF
	ldp	x16, x15, [sp, #64]             ; 16-byte Folded Reload
Lxa_BB0_48:                                ;   in Loop: Header=BB0_4 Depth=1
	add	x8, x15, #5
	sub	x9, x16, #5
	cmp	x9, #5
	b.ne	Lxa_BB0_53
; %bb.49:                               ;   in Loop: Header=BB0_4 Depth=1
	mov	x9, #0                          ; =0x0
Lxa_loh16:
	adrp	x12, l_xa.str.7@PAGE
Lxa_loh17:
	add	x12, x12, l_xa.str.7@PAGEOFF
Lxa_BB0_50:                                ;   Parent Loop BB0_4 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	cmp	x9, #5
	b.eq	Lxa_BB0_54
; %bb.51:                               ;   in Loop: Header=BB0_50 Depth=2
	ldrb	w10, [x12, x9]
	ldrb	w11, [x8, x9]
	add	x9, x9, #1
	cmp	w11, w10
	b.eq	Lxa_BB0_50
; %bb.52:                               ;   in Loop: Header=BB0_4 Depth=1
	mov	w9, #5                          ; =0x5
Lxa_BB0_53:                                ;   in Loop: Header=BB0_4 Depth=1
	cbnz	x9, Lxa_BB0_55
	b	Lxa_BB0_65
Lxa_BB0_54:                                ;   in Loop: Header=BB0_4 Depth=1
	mov	w9, #9                          ; =0x9
Lxa_loh18:
	adrp	x8, l_xa.str.8@PAGE
Lxa_loh19:
	add	x8, x8, l_xa.str.8@PAGEOFF
	cbz	x9, Lxa_BB0_65
Lxa_BB0_55:                                ;   in Loop: Header=BB0_4 Depth=1
	sub	x10, x9, #61
	cmn	x10, #65
	b.lo	Lxa_BB0_65
; %bb.56:                               ;   in Loop: Header=BB0_4 Depth=1
	mov	x10, #0                         ; =0x0
	mov	w11, #17240                     ; =0x4358
	strh	w11, [sp, #80]
	mov	w11, #95                        ; =0x5f
	strb	w11, [sp, #82]
	mov	w11, #1                         ; =0x1
	b	Lxa_BB0_59
Lxa_BB0_57:                                ;   in Loop: Header=BB0_59 Depth=2
	sub	w12, w12, #32
Lxa_BB0_58:                                ;   in Loop: Header=BB0_59 Depth=2
	strb	w12, [x24, x10]
	add	x10, x10, #1
	cmp	x10, x9
	cset	w11, lo
	cmp	x9, x10
	b.eq	Lxa_BB0_66
Lxa_BB0_59:                                ;   Parent Loop BB0_4 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrb	w12, [x8, x10]
	sub	w13, w12, #97
	cmp	w13, #25
	b.ls	Lxa_BB0_57
; %bb.60:                               ;   in Loop: Header=BB0_59 Depth=2
	sub	w13, w12, #48
	cmp	w13, #10
	b.lo	Lxa_BB0_58
; %bb.61:                               ;   in Loop: Header=BB0_59 Depth=2
	cmp	w12, #45
	b.ne	Lxa_BB0_64
; %bb.62:                               ;   in Loop: Header=BB0_59 Depth=2
	mov	w12, #95                        ; =0x5f
	b	Lxa_BB0_58
Lxa_BB0_63:                                ;   in Loop: Header=BB0_4 Depth=1
	mov	w8, #1                          ; =0x1
	b	Lxa_BB0_89
Lxa_BB0_64:                                ;   in Loop: Header=BB0_4 Depth=1
	tbz	w11, #0, Lxa_BB0_66
Lxa_BB0_65:                                ;   in Loop: Header=BB0_4 Depth=1
	ldp	x1, x0, [sp, #64]               ; 16-byte Folded Reload
Lxa_loh20:
	adrp	x2, l_xa.str.3@PAGE
Lxa_loh21:
	add	x2, x2, l_xa.str.3@PAGEOFF
	bl	_xt_xa_fail
	ldp	x16, x15, [sp, #64]             ; 16-byte Folded Reload
Lxa_loh22:
	adrp	x14, l_xa.str.11@PAGE
Lxa_loh23:
	add	x14, x14, l_xa.str.11@PAGEOFF
	b	Lxa_BB0_67
Lxa_BB0_66:                                ;   in Loop: Header=BB0_4 Depth=1
	strb	wzr, [x24, x9]
Lxa_BB0_67:                                ;   in Loop: Header=BB0_4 Depth=1
	add	x11, sp, #80
	ldrb	w8, [sp, #80]
	cmp	w8, #88
	b.ne	Lxa_BB0_72
; %bb.68:                               ;   in Loop: Header=BB0_4 Depth=1
	mov	w8, #1                          ; =0x1
Lxa_BB0_69:                                ;   Parent Loop BB0_4 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	cmp	x8, #14
	b.eq	Lxa_BB0_71
; %bb.70:                               ;   in Loop: Header=BB0_69 Depth=2
	ldrb	w9, [x11, x8]
	ldrb	w10, [x14, x8]
	add	x8, x8, #1
	cmp	w9, w10
	b.eq	Lxa_BB0_69
	b	Lxa_BB0_72
Lxa_BB0_71:                                ;   in Loop: Header=BB0_4 Depth=1
	ldp	x1, x0, [sp, #64]               ; 16-byte Folded Reload
Lxa_loh24:
	adrp	x2, l_xa.str.12@PAGE
Lxa_loh25:
	add	x2, x2, l_xa.str.12@PAGEOFF
	bl	_xt_xa_fail
	ldp	x16, x15, [sp, #64]             ; 16-byte Folded Reload
Lxa_BB0_72:                                ;   in Loop: Header=BB0_4 Depth=1
Lxa_loh26:
	adrp	x9, _xt_xa_table@PAGE
Lxa_loh27:
	add	x9, x9, _xt_xa_table@PAGEOFF
	b	Lxa_BB0_74
Lxa_BB0_73:                                ;   in Loop: Header=BB0_74 Depth=2
	mov	w10, #0                         ; =0x0
	tbz	w10, #0, Lxa_BB0_86
Lxa_BB0_74:                                ;   Parent Loop BB0_4 Depth=1
                                        ; =>  This Loop Header: Depth=2
                                        ;       Child Loop BB0_76 Depth 3
                                        ;       Child Loop BB0_79 Depth 3
                                        ;       Child Loop BB0_84 Depth 3
	ldrb	w8, [x9]
	cbz	w8, Lxa_BB0_87
; %bb.75:                               ;   in Loop: Header=BB0_74 Depth=2
	mov	x11, #0                         ; =0x0
	add	x10, x9, #2
Lxa_BB0_76:                                ;   Parent Loop BB0_4 Depth=1
                                        ;     Parent Loop BB0_74 Depth=2
                                        ; =>    This Inner Loop Header: Depth=3
	ldrb	w12, [x9, x11]
	cmp	w12, #10
	lsl	w12, w25, w12
	and	w12, w12, w19
	ccmp	w12, #0, #4, ls
	b.ne	Lxa_BB0_78
; %bb.77:                               ;   in Loop: Header=BB0_76 Depth=3
	add	x11, x11, #1
	add	x10, x10, #1
	b	Lxa_BB0_76
Lxa_BB0_78:                                ;   in Loop: Header=BB0_74 Depth=2
	mov	x12, #0                         ; =0x0
	cbz	x11, Lxa_BB0_82
Lxa_BB0_79:                                ;   Parent Loop BB0_4 Depth=1
                                        ;     Parent Loop BB0_74 Depth=2
                                        ; =>    This Inner Loop Header: Depth=3
	ldrb	w13, [x24, x12]
	ldrb	w14, [x9, x12]
	cmp	w13, w14
	b.ne	Lxa_BB0_82
; %bb.80:                               ;   in Loop: Header=BB0_79 Depth=3
	add	x12, x12, #1
	cmp	x11, x12
	b.ne	Lxa_BB0_79
; %bb.81:                               ;   in Loop: Header=BB0_74 Depth=2
	mov	x12, x11
Lxa_BB0_82:                                ;   in Loop: Header=BB0_74 Depth=2
	cmp	x12, x11
	b.ne	Lxa_BB0_84
; %bb.83:                               ;   in Loop: Header=BB0_74 Depth=2
	ldrb	w11, [x24, x11]
	cbz	w11, Lxa_BB0_73
Lxa_BB0_84:                                ;   Parent Loop BB0_4 Depth=1
                                        ;     Parent Loop BB0_74 Depth=2
                                        ; =>    This Inner Loop Header: Depth=3
	mov	x9, x10
	ldurb	w11, [x10, #-1]
	add	x10, x10, #1
	cmp	w11, #10
	lsl	w11, w25, w11
	and	w11, w11, w19
	ccmp	w11, #0, #4, ls
	b.eq	Lxa_BB0_84
; %bb.85:                               ;   in Loop: Header=BB0_74 Depth=2
	mov	w10, #1                         ; =0x1
	tbnz	w10, #0, Lxa_BB0_74
Lxa_BB0_86:                                ;   in Loop: Header=BB0_4 Depth=1
	cbnz	w8, Lxa_BB0_88
Lxa_BB0_87:                                ;   in Loop: Header=BB0_4 Depth=1
	ldp	x1, x0, [sp, #64]               ; 16-byte Folded Reload
Lxa_loh28:
	adrp	x2, l_xa.str.3@PAGE
Lxa_loh29:
	add	x2, x2, l_xa.str.3@PAGEOFF
	bl	_xt_xa_fail
	ldp	x16, x15, [sp, #64]             ; 16-byte Folded Reload
Lxa_BB0_88:                                ;   in Loop: Header=BB0_4 Depth=1
	add	x8, x15, x16
	ldr	x9, [sp, #48]                   ; 8-byte Folded Reload
	cmp	x16, x9
Lxa_loh30:
	adrp	x9, l_xa.str.1@PAGE
Lxa_loh31:
	add	x9, x9, l_xa.str.1@PAGEOFF
	csinc	x1, x9, x8, hs
	add	x0, sp, #80
	mov	w2, #1                          ; =0x1
	bl	_setenv
Lxa_loh32:
	adrp	x14, l_xa.str.11@PAGE
Lxa_loh33:
	add	x14, x14, l_xa.str.11@PAGEOFF
	mov	w8, #0                          ; =0x0
Lxa_loh34:
	adrp	x12, l_xa.str.2@PAGE
Lxa_loh35:
	add	x12, x12, l_xa.str.2@PAGEOFF
	ldr	x11, [sp, #56]                  ; 8-byte Folded Reload
Lxa_loh36:
	adrp	x13, l_xa.str@PAGE
Lxa_loh37:
	add	x13, x13, l_xa.str@PAGEOFF
Lxa_BB0_89:                                ;   in Loop: Header=BB0_4 Depth=1
	tbnz	w8, #0, Lxa_BB0_93
; %bb.90:                               ;   in Loop: Header=BB0_4 Depth=1
	add	x11, x11, #1
	ldr	x8, [sp, #40]                   ; 8-byte Folded Reload
	cmp	x11, x8
	b.ne	Lxa_BB0_4
; %bb.91:
	ldr	w0, [sp, #20]                   ; 4-byte Folded Reload
	mov	x25, x0
Lxa_BB0_92:
	subs	w8, w0, w25
	b.gt	Lxa_BB0_94
	b	Lxa_BB0_96
Lxa_BB0_93:
	mov	x25, x11
	ldr	w0, [sp, #20]                   ; 4-byte Folded Reload
	subs	w8, w0, w25
	b.le	Lxa_BB0_96
Lxa_BB0_94:
	add	x9, x21, w22, sxtw #3
	add	w10, w22, w0
	sub	w22, w10, w25
	add	x10, x21, w25, uxtw #3
Lxa_BB0_95:                                ; =>This Inner Loop Header: Depth=1
	ldr	x11, [x10], #8
	str	x11, [x9], #8
	subs	w8, w8, #1
	b.ne	Lxa_BB0_95
Lxa_BB0_96:
	cmp	w22, w0
	b.ge	Lxa_BB0_99
; %bb.97:
	mov	w9, w0
	add	x8, x21, w22, sxtw #3
	sub	x9, x9, w22, sxtw
Lxa_BB0_98:                                ; =>This Inner Loop Header: Depth=1
	str	xzr, [x8], #8
	subs	x9, x9, #1
	b.ne	Lxa_BB0_98
Lxa_BB0_99:
	mov	x0, x22
Lxa_BB0_100:
	ldp	x29, x30, [sp, #384]            ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #368]            ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #352]            ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #336]            ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #320]            ; 16-byte Folded Reload
	ldp	x28, x27, [sp, #304]            ; 16-byte Folded Reload
	add	sp, sp, #400
Lxa_BB0_101:
	ret
	.loh AdrpAdd	Lxa_loh4, Lxa_loh5
	.loh AdrpAdd	Lxa_loh2, Lxa_loh3
	.loh AdrpAdd	Lxa_loh0, Lxa_loh1
	.loh AdrpAdd	Lxa_loh6, Lxa_loh7
	.loh AdrpAdd	Lxa_loh8, Lxa_loh9
	.loh AdrpAdd	Lxa_loh10, Lxa_loh11
	.loh AdrpAdd	Lxa_loh14, Lxa_loh15
	.loh AdrpAdd	Lxa_loh12, Lxa_loh13
	.loh AdrpAdd	Lxa_loh16, Lxa_loh17
	.loh AdrpAdd	Lxa_loh18, Lxa_loh19
	.loh AdrpAdd	Lxa_loh22, Lxa_loh23
	.loh AdrpAdd	Lxa_loh20, Lxa_loh21
	.loh AdrpAdd	Lxa_loh24, Lxa_loh25
	.loh AdrpAdd	Lxa_loh26, Lxa_loh27
	.loh AdrpAdd	Lxa_loh28, Lxa_loh29
	.loh AdrpAdd	Lxa_loh36, Lxa_loh37
	.loh AdrpAdd	Lxa_loh34, Lxa_loh35
	.loh AdrpAdd	Lxa_loh32, Lxa_loh33
	.loh AdrpAdd	Lxa_loh30, Lxa_loh31
                                        ; -- End function
	.p2align	2                               ; -- Begin function xt_xa_fail
_xt_xa_fail:                            ; @xt_xa_fail
; %bb.0:
	sub	sp, sp, #320
	stp	x28, x27, [sp, #256]            ; 16-byte Folded Spill
	stp	x22, x21, [sp, #272]            ; 16-byte Folded Spill
	stp	x20, x19, [sp, #288]            ; 16-byte Folded Spill
	stp	x29, x30, [sp, #304]            ; 16-byte Folded Spill
	mov	x19, x2
	mov	x20, x1
	mov	x21, x0
Lxa_loh38:
	adrp	x3, l_xa.str.9@PAGE
Lxa_loh39:
	add	x3, x3, l_xa.str.9@PAGEOFF
	mov	x22, sp
	mov	x0, sp
	mov	x1, #0                          ; =0x0
	mov	w2, #256                        ; =0x100
	mov	w4, #4                          ; =0x4
	bl	_xt_xa_cat
	mov	x1, x0
	mov	x0, sp
	mov	w2, #120                        ; =0x78
	mov	x3, x21
	mov	x4, x20
	bl	_xt_xa_cat
	mov	x1, x0
	mov	x0, sp
	mov	w2, #256                        ; =0x100
	mov	x3, x19
	mov	w4, #256                        ; =0x100
	bl	_xt_xa_cat
	mov	x1, x0
Lxa_loh40:
	adrp	x3, l_xa.str.10@PAGE
Lxa_loh41:
	add	x3, x3, l_xa.str.10@PAGEOFF
	mov	x0, sp
	mov	w2, #256                        ; =0x100
	mov	w4, #1                          ; =0x1
	bl	_xt_xa_cat
	mov	x8, #0                          ; =0x0
Lxa_BB1_1:                                 ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x22, x8]
	add	x8, x8, #1
	cbnz	w9, Lxa_BB1_1
; %bb.2:
	sub	x2, x8, #1
	mov	x1, sp
	mov	w0, #2                          ; =0x2
	bl	_write
	mov	w0, #2                          ; =0x2
	bl	_exit
	ldp	x29, x30, [sp, #304]            ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #288]            ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #272]            ; 16-byte Folded Reload
	ldp	x28, x27, [sp, #256]            ; 16-byte Folded Reload
	add	sp, sp, #320
	ret
	.loh AdrpAdd	Lxa_loh40, Lxa_loh41
	.loh AdrpAdd	Lxa_loh38, Lxa_loh39
                                        ; -- End function
	.p2align	2                               ; -- Begin function xt_xa_cat
_xt_xa_cat:                             ; @xt_xa_cat
; %bb.0:
	cbz	x4, Lxa_BB2_3
Lxa_BB2_1:                                 ; =>This Inner Loop Header: Depth=1
	ldrb	w9, [x3], #1
	cmp	w9, #0
	add	x8, x1, #1
	ccmp	x8, x2, #2, ne
	b.hs	Lxa_BB2_3
; %bb.2:                                ;   in Loop: Header=BB2_1 Depth=1
	strb	w9, [x0, x1]
	mov	x1, x8
	subs	x4, x4, #1
	b.ne	Lxa_BB2_1
	b	Lxa_BB2_4
Lxa_BB2_3:
	mov	x8, x1
Lxa_BB2_4:
	strb	wzr, [x0, x8]
	mov	x0, x8
	ret
                                        ; -- End function
	.section	__TEXT,__cstring,cstring_literals
l_xa.str:                                 ; @.str
	.asciz	"--xc-"

l_xa.str.1:                               ; @.str.1
	.asciz	"1"

l_xa.str.2:                               ; @.str.2
	.asciz	"help"

l_xa.str.3:                               ; @.str.3
	.asciz	": unknown option (--xc-help lists them)"

l_xa.str.4:                               ; @.str.4
	.asciz	"Options for the par runtime, taken out of the arguments before main.\nEach sets the variable it names (--xc-par-report is XC_PAR_REPORT=1),\noverriding the environment. Arguments after -- are left alone.\n\n"

_xt_xa_table:                           ; @xt_xa_table
	.asciz	"PAR\t=cpu|gpu|gpus|all|auto  where every par block runs\nPAR_THREADS\t=<n>  threads a block on the CPU uses\nPAR_REPORT\t[=2]  print where each block ran and what auto measured\nPAR_FORGET\t  remove what auto learned, so it measures again\nPAR_PROBE\t  measure every worker on a block's first run (also --xc-probe)\nPAR_GPU\t=cuda|vulkan  the GPU interface where both exist\nPAR_VULKAN_DEVICE\t=<n>  the Vulkan device, by index\nPAR_CUDA_DEVICES\t=<n,...>  the CUDA cards that take tiles\nPAR_WORKERS\t=cpu,cuda,metal,vulkan,remote  the devices that share tiles\nPAR_TILES\t=0  run each block in one piece\nPAR_TILE_MB\t=<n>  megabytes a tile moves each way\nPAR_TRACE\t[=<file>|<host:port>]  record each run's tiles\nPAR_PIN\t=0  Linux: leave the CPU threads unpinned\nPAR_REMOTE\t=<host[:port],...>|mdns|none  the xcd daemons to use\nPAR_POOL\t=<name>  find the daemons of that pool by mDNS\nPAR_VERIFY\t=0|all  how many remote tiles are checked on the CPU\nTLS_LIB\t=<file>  the TLS library for connections to daemons\nPAR_VARIANT\t=<name>  test: the kernel variant a device runs\nPAR_VK_FULL\t=0  test: leave out Vulkan's full-dispatch form\nPAR_VULKAN_LOSE\t=<n>  test: the Vulkan device reads as lost after n submits\nPAR_DIE_AFTER\t=<n>  test: drop a remote connection after n tiles\nPAR_MACHINE\t=<name>  test: the machine name a daemon gives\n"

l_xa.str.5:                               ; @.str.5
	.asciz	"  --xc-"

l_xa.str.6:                               ; @.str.6
	.asciz	"  --xc-help  this list\n\nXC_PAR_SECRET has no option: a process listing shows the arguments.\n"

l_xa.str.7:                               ; @.str.7
	.asciz	"probe"

l_xa.str.8:                               ; @.str.8
	.asciz	"par-probe"

l_xa.str.9:                               ; @.str.9
	.asciz	"xc: "

l_xa.str.10:                              ; @.str.10
	.asciz	"\n"

l_xa.str.11:                              ; @.str.11
	.asciz	"XC_PAR_SECRET"

l_xa.str.12:                              ; @.str.12
	.asciz	": refused, a process listing shows the arguments; set XC_PAR_SECRET in the environment"

.subsections_via_symbols
