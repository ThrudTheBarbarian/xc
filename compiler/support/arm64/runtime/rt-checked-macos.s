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

// rt-checked-macos.s — GENERATED from src/xtc/support-src/rt-checked.c with
//   clang -S -O0 -fno-omit-frame-pointer -fno-stack-protector -arch arm64
// then LBB -> Lchk_BB and l_.str -> l_chk.str.
//
// Linked ONLY into a checked build (-fbounds-check), concatenated with
// rt-macos.s into ONE assembly unit — so its clang-generated local labels MUST
// be namespaced or they collide with the 300 LBB labels rt-macos.s already has.
// The assembler makes a duplicate label a hard error, which is how this was
// caught rather than silently mislinked.
//
// The flags are load-bearing: -fno-omit-frame-pointer because the reporter
// walks from its own frame; -O0 because at -O1 its helpers inline and the
// frame-skip goes wrong.
	.section	__TEXT,__text,regular,pure_instructions
	.section	__TEXT,__text,regular,pure_instructions
	.build_version macos, 15, 0	sdk_version 26, 0
	.globl	__xt_trap_bounds                ; -- Begin function _xt_trap_bounds
	.p2align	2
__xt_trap_bounds:                       ; @_xt_trap_bounds
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #144
	stp	x29, x30, [sp, #128]            ; 16-byte Folded Spill
	add	x29, sp, #128
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	stur	x0, [x29, #-8]
	stur	x1, [x29, #-16]
	stur	x2, [x29, #-24]
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	adrp	x1, l_chk.str@PAGE
	add	x1, x1, l_chk.str@PAGEOFF
	bl	_fprintf
	ldur	x8, [x29, #-8]
	cbz	x8, Lchk_BB0_2
	b	Lchk_BB0_1
Lchk_BB0_1:
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	ldur	x8, [x29, #-8]
	mov	x9, sp
	str	x8, [x9]
	adrp	x1, l_chk.str.1@PAGE
	add	x1, x1, l_chk.str.1@PAGEOFF
	bl	_fprintf
	b	Lchk_BB0_2
Lchk_BB0_2:
	ldur	x8, [x29, #-16]
	cbz	x8, Lchk_BB0_7
	b	Lchk_BB0_3
Lchk_BB0_3:
	ldur	x8, [x29, #-16]
	subs	x8, x8, #40
	stur	x8, [x29, #-32]
	ldur	x8, [x29, #-32]
	ldr	w8, [x8]
	stur	w8, [x29, #-36]
	ldur	w8, [x29, #-36]
	mov	w9, #20290                      ; =0x4f42
	movk	w9, #22612, lsl #16
	subs	w8, w8, w9
	b.ne	Lchk_BB0_5
	b	Lchk_BB0_4
Lchk_BB0_4:
	ldur	x8, [x29, #-32]
	ldur	x8, [x8, #4]
	stur	x8, [x29, #-48]
	ldur	x8, [x29, #-32]
	ldur	x8, [x8, #12]
	stur	x8, [x29, #-56]
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	ldur	x13, [x29, #-24]
	ldur	x12, [x29, #-56]
	ldur	x10, [x29, #-56]
	adrp	x9, l_chk.str.5@PAGE
	add	x9, x9, l_chk.str.5@PAGEOFF
	adrp	x8, l_chk.str.4@PAGE
	add	x8, x8, l_chk.str.4@PAGEOFF
	subs	x10, x10, #1
	csel	x11, x8, x9, eq
	ldur	x10, [x29, #-48]
	ldur	x14, [x29, #-48]
	subs	x14, x14, #1
	csel	x8, x8, x9, eq
	mov	x9, sp
	adrp	x14, l_chk.str.3@PAGE
	add	x14, x14, l_chk.str.3@PAGEOFF
	str	x14, [x9]
	str	x13, [x9, #8]
	str	x12, [x9, #16]
	str	x11, [x9, #24]
	str	x10, [x9, #32]
	str	x8, [x9, #40]
	adrp	x1, l_chk.str.2@PAGE
	add	x1, x1, l_chk.str.2@PAGEOFF
	bl	_fprintf
	b	Lchk_BB0_6
Lchk_BB0_5:
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	ldur	x8, [x29, #-16]
	mov	x9, sp
	str	x8, [x9]
	adrp	x1, l_chk.str.6@PAGE
	add	x1, x1, l_chk.str.6@PAGEOFF
	bl	_fprintf
	b	Lchk_BB0_6
Lchk_BB0_6:
	b	Lchk_BB0_7
Lchk_BB0_7:
	bl	___xt_ms_backtrace
	mov	w0, #0                          ; =0x0
	bl	_isatty
	cbz	w0, Lchk_BB0_12
	b	Lchk_BB0_8
Lchk_BB0_8:
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	str	x8, [sp, #56]                   ; 8-byte Folded Spill
	ldr	x0, [x8]
	adrp	x1, l_chk.str.7@PAGE
	add	x1, x1, l_chk.str.7@PAGEOFF
	bl	_fprintf
	ldr	x8, [sp, #56]                   ; 8-byte Folded Reload
	ldr	x0, [x8]
	bl	_fflush
	bl	_getchar
	stur	w0, [x29, #-60]
	ldur	w8, [x29, #-60]
	subs	w8, w8, #99
	b.eq	Lchk_BB0_10
	b	Lchk_BB0_9
Lchk_BB0_9:
	ldur	w8, [x29, #-60]
	subs	w8, w8, #67
	b.ne	Lchk_BB0_11
	b	Lchk_BB0_10
Lchk_BB0_10:
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	adrp	x1, l_chk.str.8@PAGE
	add	x1, x1, l_chk.str.8@PAGEOFF
	bl	_fprintf
	ldp	x29, x30, [sp, #128]            ; 16-byte Folded Reload
	add	sp, sp, #144
	ret
Lchk_BB0_11:
	b	Lchk_BB0_12
Lchk_BB0_12:
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	adrp	x1, l_chk.str.9@PAGE
	add	x1, x1, l_chk.str.9@PAGEOFF
	bl	_fprintf
	bl	_abort
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function __xt_ms_backtrace
___xt_ms_backtrace:                     ; @__xt_ms_backtrace
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #112
	stp	x29, x30, [sp, #96]             ; 16-byte Folded Spill
	add	x29, sp, #96
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	mov	x8, x29
	stur	x8, [x29, #-8]
	ldur	x8, [x29, #-8]
	ldr	x8, [x8]
	stur	x8, [x29, #-8]
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	adrp	x1, l_chk.str.10@PAGE
	add	x1, x1, l_chk.str.10@PAGEOFF
	bl	_fprintf
	stur	wzr, [x29, #-12]
	b	Lchk_BB1_1
Lchk_BB1_1:                                 ; =>This Inner Loop Header: Depth=1
	ldur	w9, [x29, #-12]
	mov	w8, #0                          ; =0x0
	subs	w9, w9, #24
	str	w8, [sp, #36]                   ; 4-byte Folded Spill
	b.ge	Lchk_BB1_3
	b	Lchk_BB1_2
Lchk_BB1_2:                                 ;   in Loop: Header=BB1_1 Depth=1
	ldur	x8, [x29, #-8]
	subs	x8, x8, #0
	cset	w8, ne
	str	w8, [sp, #36]                   ; 4-byte Folded Spill
	b	Lchk_BB1_3
Lchk_BB1_3:                                 ;   in Loop: Header=BB1_1 Depth=1
	ldr	w8, [sp, #36]                   ; 4-byte Folded Reload
	tbz	w8, #0, Lchk_BB1_20
	b	Lchk_BB1_4
Lchk_BB1_4:                                 ;   in Loop: Header=BB1_1 Depth=1
	ldur	x8, [x29, #-8]
	ldr	x8, [x8, #8]
	stur	x8, [x29, #-24]
	ldur	x8, [x29, #-8]
	ldr	x8, [x8]
	stur	x8, [x29, #-32]
	ldur	x8, [x29, #-24]
	cbnz	x8, Lchk_BB1_6
	b	Lchk_BB1_5
Lchk_BB1_5:
	b	Lchk_BB1_20
Lchk_BB1_6:                                 ;   in Loop: Header=BB1_1 Depth=1
	sub	x1, x29, #40
	stur	xzr, [x29, #-40]
	add	x2, sp, #48
	str	xzr, [sp, #48]
	ldur	x0, [x29, #-24]
	bl	___xt_ms_symbolise
	str	x0, [sp, #40]
	ldr	x8, [sp, #40]
	cbz	x8, Lchk_BB1_9
	b	Lchk_BB1_7
Lchk_BB1_7:                                 ;   in Loop: Header=BB1_1 Depth=1
	ldur	x8, [x29, #-40]
	subs	x8, x8, #256, lsl #12           ; =1048576
	b.ls	Lchk_BB1_9
	b	Lchk_BB1_8
Lchk_BB1_8:                                 ;   in Loop: Header=BB1_1 Depth=1
                                        ; kill: def $x8 killed $xzr
	str	xzr, [sp, #40]
	b	Lchk_BB1_9
Lchk_BB1_9:                                 ;   in Loop: Header=BB1_1 Depth=1
	ldr	x8, [sp, #40]
	cbz	x8, Lchk_BB1_15
	b	Lchk_BB1_10
Lchk_BB1_10:                                ;   in Loop: Header=BB1_1 Depth=1
	ldr	x8, [sp, #40]
	ldrsb	w8, [x8]
	subs	w8, w8, #95
	b.ne	Lchk_BB1_12
	b	Lchk_BB1_11
Lchk_BB1_11:                                ;   in Loop: Header=BB1_1 Depth=1
	ldr	x8, [sp, #40]
	add	x8, x8, #1
	str	x8, [sp, #40]
	b	Lchk_BB1_12
Lchk_BB1_12:                                ;   in Loop: Header=BB1_1 Depth=1
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	ldur	w8, [x29, #-12]
	mov	x11, x8
	ldr	x10, [sp, #40]
	ldur	x8, [x29, #-40]
	mov	x9, sp
	str	x11, [x9]
	str	x10, [x9, #8]
	str	x8, [x9, #16]
	adrp	x1, l_chk.str.11@PAGE
	add	x1, x1, l_chk.str.11@PAGEOFF
	bl	_fprintf
	ldur	x8, [x29, #-32]
	ldur	x9, [x29, #-8]
	subs	x8, x8, x9
	b.ls	Lchk_BB1_14
	b	Lchk_BB1_13
Lchk_BB1_13:                                ;   in Loop: Header=BB1_1 Depth=1
	ldr	x0, [sp, #48]
	ldur	x1, [x29, #-32]
	bl	___xt_ms_args
	ldr	x0, [sp, #48]
	ldur	x1, [x29, #-32]
	bl	___xt_ms_applySaves
	b	Lchk_BB1_14
Lchk_BB1_14:                                ;   in Loop: Header=BB1_1 Depth=1
	b	Lchk_BB1_16
Lchk_BB1_15:                                ;   in Loop: Header=BB1_1 Depth=1
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	ldur	w8, [x29, #-12]
	mov	x10, x8
	ldur	x8, [x29, #-24]
	mov	x9, sp
	str	x10, [x9]
	str	x8, [x9, #8]
	adrp	x1, l_chk.str.12@PAGE
	add	x1, x1, l_chk.str.12@PAGEOFF
	bl	_fprintf
	b	Lchk_BB1_16
Lchk_BB1_16:                                ;   in Loop: Header=BB1_1 Depth=1
	ldur	x8, [x29, #-32]
	ldur	x9, [x29, #-8]
	subs	x8, x8, x9
	b.hi	Lchk_BB1_18
	b	Lchk_BB1_17
Lchk_BB1_17:
	b	Lchk_BB1_20
Lchk_BB1_18:                                ;   in Loop: Header=BB1_1 Depth=1
	ldur	x8, [x29, #-32]
	stur	x8, [x29, #-8]
	b	Lchk_BB1_19
Lchk_BB1_19:                                ;   in Loop: Header=BB1_1 Depth=1
	ldur	w8, [x29, #-12]
	add	w8, w8, #1
	stur	w8, [x29, #-12]
	b	Lchk_BB1_1
Lchk_BB1_20:
	ldp	x29, x30, [sp, #96]             ; 16-byte Folded Reload
	add	sp, sp, #112
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_check_bounds               ; -- Begin function _xt_check_bounds
	.p2align	2
__xt_check_bounds:                      ; @_xt_check_bounds
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #64
	stp	x29, x30, [sp, #48]             ; 16-byte Folded Spill
	add	x29, sp, #48
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	stur	x0, [x29, #-8]
	stur	x1, [x29, #-16]
	str	x2, [sp, #24]
	ldur	x8, [x29, #-8]
	cbnz	x8, Lchk_BB2_8
	b	Lchk_BB2_1
Lchk_BB2_1:
	b	Lchk_BB2_2
Lchk_BB2_2:
	adrp	x8, ___xt_ms_reg@PAGE
	add	x8, x8, ___xt_ms_reg@PAGEOFF
	; InlineAsm Start
	stp	x19, x20, [x8, #152]
	stp	x21, x22, [x8, #168]
	stp	x23, x24, [x8, #184]
	stp	x25, x26, [x8, #200]
	stp	x27, x28, [x8, #216]

	; InlineAsm End
	mov	w8, #19                         ; =0x13
	str	w8, [sp, #20]
	b	Lchk_BB2_3
Lchk_BB2_3:                                 ; =>This Inner Loop Header: Depth=1
	ldr	w8, [sp, #20]
	subs	w8, w8, #28
	b.gt	Lchk_BB2_6
	b	Lchk_BB2_4
Lchk_BB2_4:                                 ;   in Loop: Header=BB2_3 Depth=1
	ldrsw	x9, [sp, #20]
	adrp	x8, ___xt_ms_regKnown@PAGE
	add	x8, x8, ___xt_ms_regKnown@PAGEOFF
	add	x9, x8, x9
	mov	w8, #1                          ; =0x1
	strb	w8, [x9]
	b	Lchk_BB2_5
Lchk_BB2_5:                                 ;   in Loop: Header=BB2_3 Depth=1
	ldr	w8, [sp, #20]
	add	w8, w8, #1
	str	w8, [sp, #20]
	b	Lchk_BB2_3
Lchk_BB2_6:
	b	Lchk_BB2_7
Lchk_BB2_7:
	ldr	x0, [sp, #24]
	ldur	x1, [x29, #-8]
	ldur	x2, [x29, #-16]
	bl	__xt_trap_bounds
	b	Lchk_BB2_18
Lchk_BB2_8:
	ldur	x8, [x29, #-8]
	subs	x8, x8, #40
	str	x8, [sp, #8]
	ldr	x8, [sp, #8]
	ldr	w8, [x8]
	mov	w9, #20290                      ; =0x4f42
	movk	w9, #22612, lsl #16
	subs	w8, w8, w9
	b.eq	Lchk_BB2_10
	b	Lchk_BB2_9
Lchk_BB2_9:
	b	Lchk_BB2_18
Lchk_BB2_10:
	ldur	x8, [x29, #-16]
	ldr	x9, [sp, #8]
	ldur	x9, [x9, #12]
	subs	x8, x8, x9
	b.lo	Lchk_BB2_18
	b	Lchk_BB2_11
Lchk_BB2_11:
	b	Lchk_BB2_12
Lchk_BB2_12:
	adrp	x8, ___xt_ms_reg@PAGE
	add	x8, x8, ___xt_ms_reg@PAGEOFF
	; InlineAsm Start
	stp	x19, x20, [x8, #152]
	stp	x21, x22, [x8, #168]
	stp	x23, x24, [x8, #184]
	stp	x25, x26, [x8, #200]
	stp	x27, x28, [x8, #216]

	; InlineAsm End
	mov	w8, #19                         ; =0x13
	str	w8, [sp, #4]
	b	Lchk_BB2_13
Lchk_BB2_13:                                ; =>This Inner Loop Header: Depth=1
	ldr	w8, [sp, #4]
	subs	w8, w8, #28
	b.gt	Lchk_BB2_16
	b	Lchk_BB2_14
Lchk_BB2_14:                                ;   in Loop: Header=BB2_13 Depth=1
	ldrsw	x9, [sp, #4]
	adrp	x8, ___xt_ms_regKnown@PAGE
	add	x8, x8, ___xt_ms_regKnown@PAGEOFF
	add	x9, x8, x9
	mov	w8, #1                          ; =0x1
	strb	w8, [x9]
	b	Lchk_BB2_15
Lchk_BB2_15:                                ;   in Loop: Header=BB2_13 Depth=1
	ldr	w8, [sp, #4]
	add	w8, w8, #1
	str	w8, [sp, #4]
	b	Lchk_BB2_13
Lchk_BB2_16:
	b	Lchk_BB2_17
Lchk_BB2_17:
	ldr	x0, [sp, #24]
	ldur	x1, [x29, #-8]
	ldur	x2, [x29, #-16]
	bl	__xt_trap_bounds
	b	Lchk_BB2_18
Lchk_BB2_18:
	ldp	x29, x30, [sp, #48]             ; 16-byte Folded Reload
	add	sp, sp, #64
	ret
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function __xt_ms_symbolise
___xt_ms_symbolise:                     ; @__xt_ms_symbolise
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #272
	stp	x28, x27, [sp, #240]            ; 16-byte Folded Spill
	stp	x29, x30, [sp, #256]            ; 16-byte Folded Spill
	add	x29, sp, #256
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w27, -24
	.cfi_offset w28, -32
	stur	x0, [x29, #-32]
	stur	x1, [x29, #-40]
	stur	x2, [x29, #-48]
	mov	w0, #0                          ; =0x0
	bl	__dyld_get_image_header
	stur	x0, [x29, #-56]
	ldur	x8, [x29, #-56]
	cbnz	x8, Lchk_BB3_2
	b	Lchk_BB3_1
Lchk_BB3_1:
                                        ; kill: def $x8 killed $xzr
	stur	xzr, [x29, #-24]
	b	Lchk_BB3_56
Lchk_BB3_2:
	mov	w0, #0                          ; =0x0
	bl	__dyld_get_image_vmaddr_slide
	stur	x0, [x29, #-64]
	ldur	x8, [x29, #-56]
	add	x8, x8, #32
	stur	x8, [x29, #-72]
	stur	wzr, [x29, #-76]
	b	Lchk_BB3_3
Lchk_BB3_3:                                 ; =>This Inner Loop Header: Depth=1
	ldur	w8, [x29, #-76]
	ldur	x9, [x29, #-56]
	ldr	w9, [x9, #16]
	subs	w8, w8, w9
	b.hs	Lchk_BB3_55
	b	Lchk_BB3_4
Lchk_BB3_4:                                 ;   in Loop: Header=BB3_3 Depth=1
	ldur	x8, [x29, #-72]
	ldr	w8, [x8]
	subs	w8, w8, #2
	b.ne	Lchk_BB3_53
	b	Lchk_BB3_5
Lchk_BB3_5:
	ldur	x8, [x29, #-72]
	stur	x8, [x29, #-88]
	ldur	x8, [x29, #-56]
	add	x8, x8, #32
	stur	x8, [x29, #-96]
                                        ; kill: def $x8 killed $xzr
	stur	xzr, [x29, #-104]
	stur	wzr, [x29, #-108]
	b	Lchk_BB3_6
Lchk_BB3_6:                                 ; =>This Inner Loop Header: Depth=1
	ldur	w8, [x29, #-108]
	ldur	x9, [x29, #-56]
	ldr	w9, [x9, #16]
	subs	w8, w8, w9
	b.hs	Lchk_BB3_13
	b	Lchk_BB3_7
Lchk_BB3_7:                                 ;   in Loop: Header=BB3_6 Depth=1
	ldur	x8, [x29, #-96]
	ldr	w8, [x8]
	subs	w8, w8, #25
	b.ne	Lchk_BB3_11
	b	Lchk_BB3_8
Lchk_BB3_8:                                 ;   in Loop: Header=BB3_6 Depth=1
	ldur	x8, [x29, #-96]
	stur	x8, [x29, #-120]
	ldur	x8, [x29, #-120]
	add	x0, x8, #8
	adrp	x1, l_chk.str.13@PAGE
	add	x1, x1, l_chk.str.13@PAGEOFF
	bl	_strcmp
	cbnz	w0, Lchk_BB3_10
	b	Lchk_BB3_9
Lchk_BB3_9:
	ldur	x8, [x29, #-120]
	stur	x8, [x29, #-104]
	b	Lchk_BB3_13
Lchk_BB3_10:                                ;   in Loop: Header=BB3_6 Depth=1
	b	Lchk_BB3_11
Lchk_BB3_11:                                ;   in Loop: Header=BB3_6 Depth=1
	ldur	x8, [x29, #-96]
	ldur	x9, [x29, #-96]
	ldr	w9, [x9, #4]
                                        ; kill: def $x9 killed $w9
	add	x8, x8, x9
	stur	x8, [x29, #-96]
	b	Lchk_BB3_12
Lchk_BB3_12:                                ;   in Loop: Header=BB3_6 Depth=1
	ldur	w8, [x29, #-108]
	add	w8, w8, #1
	stur	w8, [x29, #-108]
	b	Lchk_BB3_6
Lchk_BB3_13:
	ldur	x8, [x29, #-104]
	cbnz	x8, Lchk_BB3_15
	b	Lchk_BB3_14
Lchk_BB3_14:
                                        ; kill: def $x8 killed $xzr
	stur	xzr, [x29, #-24]
	b	Lchk_BB3_56
Lchk_BB3_15:
	sturb	wzr, [x29, #-121]
	sturb	wzr, [x29, #-122]
	ldur	x8, [x29, #-56]
	add	x8, x8, #32
	str	x8, [sp, #120]
	str	wzr, [sp, #116]
	b	Lchk_BB3_16
Lchk_BB3_16:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB3_21 Depth 2
	ldr	w9, [sp, #116]
	ldur	x8, [x29, #-56]
	ldr	w10, [x8, #16]
	mov	w8, #0                          ; =0x0
	subs	w9, w9, w10
	str	w8, [sp, #12]                   ; 4-byte Folded Spill
	b.hs	Lchk_BB3_18
	b	Lchk_BB3_17
Lchk_BB3_17:                                ;   in Loop: Header=BB3_16 Depth=1
	ldurb	w8, [x29, #-121]
	subs	w8, w8, #0
	cset	w8, eq
	str	w8, [sp, #12]                   ; 4-byte Folded Spill
	b	Lchk_BB3_18
Lchk_BB3_18:                                ;   in Loop: Header=BB3_16 Depth=1
	ldr	w8, [sp, #12]                   ; 4-byte Folded Reload
	tbz	w8, #0, Lchk_BB3_30
	b	Lchk_BB3_19
Lchk_BB3_19:                                ;   in Loop: Header=BB3_16 Depth=1
	ldr	x8, [sp, #120]
	ldr	w8, [x8]
	subs	w8, w8, #25
	b.ne	Lchk_BB3_28
	b	Lchk_BB3_20
Lchk_BB3_20:                                ;   in Loop: Header=BB3_16 Depth=1
	ldr	x8, [sp, #120]
	str	x8, [sp, #104]
	ldr	x8, [sp, #104]
	add	x8, x8, #72
	str	x8, [sp, #96]
	str	wzr, [sp, #92]
	b	Lchk_BB3_21
Lchk_BB3_21:                                ;   Parent Loop BB3_16 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldr	w8, [sp, #92]
	ldr	x9, [sp, #104]
	ldr	w9, [x9, #64]
	subs	w8, w8, w9
	b.hs	Lchk_BB3_27
	b	Lchk_BB3_22
Lchk_BB3_22:                                ;   in Loop: Header=BB3_21 Depth=2
	ldurb	w8, [x29, #-122]
	add	w8, w8, #1
	sturb	w8, [x29, #-122]
	ldr	x0, [sp, #96]
	adrp	x1, l_chk.str.14@PAGE
	add	x1, x1, l_chk.str.14@PAGEOFF
	bl	_strcmp
	cbnz	w0, Lchk_BB3_25
	b	Lchk_BB3_23
Lchk_BB3_23:                                ;   in Loop: Header=BB3_21 Depth=2
	ldr	x8, [sp, #96]
	add	x0, x8, #16
	adrp	x1, l_chk.str.15@PAGE
	add	x1, x1, l_chk.str.15@PAGEOFF
	bl	_strcmp
	cbnz	w0, Lchk_BB3_25
	b	Lchk_BB3_24
Lchk_BB3_24:                                ;   in Loop: Header=BB3_16 Depth=1
	ldurb	w8, [x29, #-122]
	sturb	w8, [x29, #-121]
	b	Lchk_BB3_27
Lchk_BB3_25:                                ;   in Loop: Header=BB3_21 Depth=2
	b	Lchk_BB3_26
Lchk_BB3_26:                                ;   in Loop: Header=BB3_21 Depth=2
	ldr	w8, [sp, #92]
	add	w8, w8, #1
	str	w8, [sp, #92]
	ldr	x8, [sp, #96]
	add	x8, x8, #80
	str	x8, [sp, #96]
	b	Lchk_BB3_21
Lchk_BB3_27:                                ;   in Loop: Header=BB3_16 Depth=1
	b	Lchk_BB3_28
Lchk_BB3_28:                                ;   in Loop: Header=BB3_16 Depth=1
	ldr	x8, [sp, #120]
	ldr	x9, [sp, #120]
	ldr	w9, [x9, #4]
                                        ; kill: def $x9 killed $w9
	add	x8, x8, x9
	str	x8, [sp, #120]
	b	Lchk_BB3_29
Lchk_BB3_29:                                ;   in Loop: Header=BB3_16 Depth=1
	ldr	w8, [sp, #116]
	add	w8, w8, #1
	str	w8, [sp, #116]
	b	Lchk_BB3_16
Lchk_BB3_30:
	ldurb	w8, [x29, #-121]
	cbnz	w8, Lchk_BB3_32
	b	Lchk_BB3_31
Lchk_BB3_31:
                                        ; kill: def $x8 killed $xzr
	stur	xzr, [x29, #-24]
	b	Lchk_BB3_56
Lchk_BB3_32:
	ldur	x8, [x29, #-104]
	ldr	x8, [x8, #24]
	ldur	x9, [x29, #-64]
	add	x8, x8, x9
	ldur	x9, [x29, #-104]
	ldr	x9, [x9, #40]
	subs	x8, x8, x9
	str	x8, [sp, #80]
	ldr	x8, [sp, #80]
	ldur	x9, [x29, #-88]
	ldr	w9, [x9, #8]
                                        ; kill: def $x9 killed $w9
	add	x8, x8, x9
	str	x8, [sp, #72]
	ldr	x8, [sp, #80]
	ldur	x9, [x29, #-88]
	ldr	w9, [x9, #16]
                                        ; kill: def $x9 killed $w9
	add	x8, x8, x9
	str	x8, [sp, #64]
	ldur	x8, [x29, #-32]
	str	x8, [sp, #56]
	str	xzr, [sp, #48]
                                        ; kill: def $x8 killed $xzr
	str	xzr, [sp, #40]
	str	wzr, [sp, #36]
	b	Lchk_BB3_33
Lchk_BB3_33:                                ; =>This Inner Loop Header: Depth=1
	ldr	w8, [sp, #36]
	ldur	x9, [x29, #-88]
	ldr	w9, [x9, #12]
	subs	w8, w8, w9
	b.hs	Lchk_BB3_46
	b	Lchk_BB3_34
Lchk_BB3_34:                                ;   in Loop: Header=BB3_33 Depth=1
	ldr	x8, [sp, #72]
	ldr	w9, [sp, #36]
                                        ; kill: def $x9 killed $w9
	add	x8, x8, x9, lsl #4
	ldrb	w8, [x8, #4]
	and	w8, w8, #0xe0
	cbnz	w8, Lchk_BB3_36
	b	Lchk_BB3_35
Lchk_BB3_35:                                ;   in Loop: Header=BB3_33 Depth=1
	ldr	x8, [sp, #72]
	ldr	w9, [sp, #36]
                                        ; kill: def $x9 killed $w9
	add	x8, x8, x9, lsl #4
	ldrb	w8, [x8, #4]
	and	w8, w8, #0xe
	cbnz	w8, Lchk_BB3_37
	b	Lchk_BB3_36
Lchk_BB3_36:                                ;   in Loop: Header=BB3_33 Depth=1
	b	Lchk_BB3_45
Lchk_BB3_37:                                ;   in Loop: Header=BB3_33 Depth=1
	ldr	x8, [sp, #72]
	ldr	w9, [sp, #36]
                                        ; kill: def $x9 killed $w9
	add	x8, x8, x9, lsl #4
	ldrb	w8, [x8, #5]
	ldurb	w9, [x29, #-121]
	subs	w8, w8, w9
	b.eq	Lchk_BB3_39
	b	Lchk_BB3_38
Lchk_BB3_38:                                ;   in Loop: Header=BB3_33 Depth=1
	b	Lchk_BB3_45
Lchk_BB3_39:                                ;   in Loop: Header=BB3_33 Depth=1
	ldr	x8, [sp, #64]
	ldr	x9, [sp, #72]
	ldr	w10, [sp, #36]
                                        ; kill: def $x10 killed $w10
	lsl	x10, x10, #4
	ldr	w9, [x9, x10]
                                        ; kill: def $x9 killed $w9
	add	x8, x8, x9
	str	x8, [sp, #24]
	ldr	x8, [sp, #24]
	ldrsb	w8, [x8]
	subs	w8, w8, #76
	b.ne	Lchk_BB3_41
	b	Lchk_BB3_40
Lchk_BB3_40:                                ;   in Loop: Header=BB3_33 Depth=1
	b	Lchk_BB3_45
Lchk_BB3_41:                                ;   in Loop: Header=BB3_33 Depth=1
	ldr	x8, [sp, #72]
	ldr	w9, [sp, #36]
                                        ; kill: def $x9 killed $w9
	add	x8, x8, x9, lsl #4
	ldr	x8, [x8, #8]
	ldur	x9, [x29, #-64]
	add	x8, x8, x9
	str	x8, [sp, #16]
	ldr	x8, [sp, #16]
	ldr	x9, [sp, #56]
	subs	x8, x8, x9
	b.hi	Lchk_BB3_44
	b	Lchk_BB3_42
Lchk_BB3_42:                                ;   in Loop: Header=BB3_33 Depth=1
	ldr	x8, [sp, #16]
	ldr	x9, [sp, #48]
	subs	x8, x8, x9
	b.ls	Lchk_BB3_44
	b	Lchk_BB3_43
Lchk_BB3_43:                                ;   in Loop: Header=BB3_33 Depth=1
	ldr	x8, [sp, #16]
	str	x8, [sp, #48]
	ldr	x8, [sp, #24]
	str	x8, [sp, #40]
	b	Lchk_BB3_44
Lchk_BB3_44:                                ;   in Loop: Header=BB3_33 Depth=1
	b	Lchk_BB3_45
Lchk_BB3_45:                                ;   in Loop: Header=BB3_33 Depth=1
	ldr	w8, [sp, #36]
	add	w8, w8, #1
	str	w8, [sp, #36]
	b	Lchk_BB3_33
Lchk_BB3_46:
	ldr	x8, [sp, #40]
	cbz	x8, Lchk_BB3_49
	b	Lchk_BB3_47
Lchk_BB3_47:
	ldur	x8, [x29, #-40]
	cbz	x8, Lchk_BB3_49
	b	Lchk_BB3_48
Lchk_BB3_48:
	ldr	x8, [sp, #56]
	ldr	x9, [sp, #48]
	subs	x8, x8, x9
	ldur	x9, [x29, #-40]
	str	x8, [x9]
	b	Lchk_BB3_49
Lchk_BB3_49:
	ldr	x8, [sp, #40]
	cbz	x8, Lchk_BB3_52
	b	Lchk_BB3_50
Lchk_BB3_50:
	ldur	x8, [x29, #-48]
	cbz	x8, Lchk_BB3_52
	b	Lchk_BB3_51
Lchk_BB3_51:
	ldr	x8, [sp, #48]
	ldur	x9, [x29, #-48]
	str	x8, [x9]
	b	Lchk_BB3_52
Lchk_BB3_52:
	ldr	x8, [sp, #40]
	stur	x8, [x29, #-24]
	b	Lchk_BB3_56
Lchk_BB3_53:                                ;   in Loop: Header=BB3_3 Depth=1
	ldur	x8, [x29, #-72]
	ldur	x9, [x29, #-72]
	ldr	w9, [x9, #4]
                                        ; kill: def $x9 killed $w9
	add	x8, x8, x9
	stur	x8, [x29, #-72]
	b	Lchk_BB3_54
Lchk_BB3_54:                                ;   in Loop: Header=BB3_3 Depth=1
	ldur	w8, [x29, #-76]
	add	w8, w8, #1
	stur	w8, [x29, #-76]
	b	Lchk_BB3_3
Lchk_BB3_55:
                                        ; kill: def $x8 killed $xzr
	stur	xzr, [x29, #-24]
	b	Lchk_BB3_56
Lchk_BB3_56:
	ldur	x0, [x29, #-24]
	ldp	x29, x30, [sp, #256]            ; 16-byte Folded Reload
	ldp	x28, x27, [sp, #240]            ; 16-byte Folded Reload
	add	sp, sp, #272
	ret
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function __xt_ms_args
___xt_ms_args:                          ; @__xt_ms_args
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #160
	stp	x29, x30, [sp, #144]            ; 16-byte Folded Spill
	add	x29, sp, #144
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	stur	x0, [x29, #-8]
	stur	x1, [x29, #-16]
	ldur	x8, [x29, #-16]
	cbnz	x8, Lchk_BB4_2
	b	Lchk_BB4_1
Lchk_BB4_1:
	b	Lchk_BB4_52
Lchk_BB4_2:
	adrp	x8, ___xt_ms_fns@PAGE
	ldr	x8, [x8, ___xt_ms_fns@PAGEOFF]
	stur	x8, [x29, #-24]
	ldur	x8, [x29, #-24]
	cbz	x8, Lchk_BB4_4
	b	Lchk_BB4_3
Lchk_BB4_3:
	ldur	x8, [x29, #-24]
	mov	x9, #16960                      ; =0x4240
	movk	x9, #15, lsl #16
	subs	x8, x8, x9
	b.ls	Lchk_BB4_5
	b	Lchk_BB4_4
Lchk_BB4_4:
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	adrp	x1, l_chk.str.16@PAGE
	add	x1, x1, l_chk.str.16@PAGEOFF
	bl	_fprintf
	b	Lchk_BB4_52
Lchk_BB4_5:
	adrp	x8, ___xt_ms_fns@PAGE
	add	x8, x8, ___xt_ms_fns@PAGEOFF
	add	x8, x8, #8
	stur	x8, [x29, #-32]
	stur	xzr, [x29, #-40]
	b	Lchk_BB4_6
Lchk_BB4_6:                                 ; =>This Inner Loop Header: Depth=1
	ldur	x8, [x29, #-40]
	ldur	x9, [x29, #-24]
	subs	x8, x8, x9
	b.hs	Lchk_BB4_52
	b	Lchk_BB4_7
Lchk_BB4_7:                                 ;   in Loop: Header=BB4_6 Depth=1
	ldur	x8, [x29, #-32]
	ldr	x8, [x8]
	ldur	x9, [x29, #-8]
	subs	x8, x8, x9
	b.eq	Lchk_BB4_9
	b	Lchk_BB4_8
Lchk_BB4_8:                                 ;   in Loop: Header=BB4_6 Depth=1
	b	Lchk_BB4_51
Lchk_BB4_9:
	ldur	x8, [x29, #-32]
	ldr	x8, [x8, #8]
	stur	x8, [x29, #-48]
	ldur	x8, [x29, #-32]
	ldr	x8, [x8, #16]
	stur	x8, [x29, #-56]
	ldur	x8, [x29, #-48]
	cbz	x8, Lchk_BB4_11
	b	Lchk_BB4_10
Lchk_BB4_10:
	ldur	x8, [x29, #-56]
	cbnz	x8, Lchk_BB4_12
	b	Lchk_BB4_11
Lchk_BB4_11:
	b	Lchk_BB4_52
Lchk_BB4_12:
	ldur	x8, [x29, #-16]
	and	x8, x8, #0x7
	cbnz	x8, Lchk_BB4_14
	b	Lchk_BB4_13
Lchk_BB4_13:
	ldur	x8, [x29, #-48]
	subs	x8, x8, #32
	b.ls	Lchk_BB4_15
	b	Lchk_BB4_14
Lchk_BB4_14:
	b	Lchk_BB4_52
Lchk_BB4_15:
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	adrp	x1, l_chk.str.17@PAGE
	add	x1, x1, l_chk.str.17@PAGEOFF
	bl	_fprintf
	stur	xzr, [x29, #-64]
	b	Lchk_BB4_16
Lchk_BB4_16:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB4_37 Depth 2
	ldur	x8, [x29, #-64]
	ldur	x9, [x29, #-48]
	subs	x8, x8, x9
	b.hs	Lchk_BB4_50
	b	Lchk_BB4_17
Lchk_BB4_17:                                ;   in Loop: Header=BB4_16 Depth=1
	ldur	x8, [x29, #-56]
	ldur	x9, [x29, #-64]
	mov	x10, #3                         ; =0x3
	mul	x9, x9, x10
	ldr	x8, [x8, x9, lsl #3]
	str	x8, [sp, #72]
	ldur	x8, [x29, #-56]
	ldur	x9, [x29, #-64]
	mul	x9, x9, x10
	add	x9, x9, #1
	ldr	x8, [x8, x9, lsl #3]
	str	x8, [sp, #64]
	ldur	x8, [x29, #-56]
	ldur	x9, [x29, #-64]
	mul	x9, x9, x10
	add	x9, x9, #2
	ldr	x8, [x8, x9, lsl #3]
	str	x8, [sp, #56]
	ldr	x8, [sp, #64]
	lsr	x8, x8, #8
                                        ; kill: def $w8 killed $w8 killed $x8
	str	w8, [sp, #52]
	ldrb	w8, [sp, #64]
                                        ; kill: def $x8 killed $w8
                                        ; kill: def $w8 killed $w8 killed $x8
	str	w8, [sp, #48]
	ldr	x8, [sp, #72]
	adds	x8, x8, #1
	b.ne	Lchk_BB4_32
	b	Lchk_BB4_18
Lchk_BB4_18:                                ;   in Loop: Header=BB4_16 Depth=1
	ldr	x8, [sp, #56]
	subs	x8, x8, #32
	b.hs	Lchk_BB4_30
	b	Lchk_BB4_19
Lchk_BB4_19:                                ;   in Loop: Header=BB4_16 Depth=1
	ldr	x9, [sp, #56]
	adrp	x8, ___xt_ms_regKnown@PAGE
	add	x8, x8, ___xt_ms_regKnown@PAGEOFF
	ldrb	w8, [x8, x9]
	cbz	w8, Lchk_BB4_30
	b	Lchk_BB4_20
Lchk_BB4_20:                                ;   in Loop: Header=BB4_16 Depth=1
	ldr	x9, [sp, #56]
	adrp	x8, ___xt_ms_reg@PAGE
	add	x8, x8, ___xt_ms_reg@PAGEOFF
	ldr	x8, [x8, x9, lsl #3]
	str	x8, [sp, #40]
	ldr	w8, [sp, #48]
	cbz	w8, Lchk_BB4_23
	b	Lchk_BB4_21
Lchk_BB4_21:                                ;   in Loop: Header=BB4_16 Depth=1
	ldr	w8, [sp, #48]
	subs	w8, w8, #8
	b.hs	Lchk_BB4_23
	b	Lchk_BB4_22
Lchk_BB4_22:                                ;   in Loop: Header=BB4_16 Depth=1
	ldr	w9, [sp, #48]
	mov	w8, #64                         ; =0x40
	subs	w9, w8, w9, lsl #3
	mov	x8, #-1                         ; =0xffffffffffffffff
                                        ; kill: def $x9 killed $w9
	lsr	x9, x8, x9
	ldr	x8, [sp, #40]
	and	x8, x8, x9
	str	x8, [sp, #40]
	b	Lchk_BB4_23
Lchk_BB4_23:                                ;   in Loop: Header=BB4_16 Depth=1
	ldr	w8, [sp, #52]
	subs	w8, w8, #2
	b.ne	Lchk_BB4_25
	b	Lchk_BB4_24
Lchk_BB4_24:                                ;   in Loop: Header=BB4_16 Depth=1
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	ldur	x10, [x29, #-64]
	ldr	x8, [sp, #40]
	mov	x9, sp
	str	x10, [x9]
	str	x8, [x9, #8]
	adrp	x1, l_chk.str.18@PAGE
	add	x1, x1, l_chk.str.18@PAGEOFF
	bl	_fprintf
	b	Lchk_BB4_29
Lchk_BB4_25:                                ;   in Loop: Header=BB4_16 Depth=1
	ldr	w8, [sp, #52]
	subs	w8, w8, #3
	b.ne	Lchk_BB4_27
	b	Lchk_BB4_26
Lchk_BB4_26:                                ;   in Loop: Header=BB4_16 Depth=1
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	ldur	x8, [x29, #-64]
	mov	x9, sp
	str	x8, [x9]
	adrp	x1, l_chk.str.19@PAGE
	add	x1, x1, l_chk.str.19@PAGEOFF
	bl	_fprintf
	b	Lchk_BB4_28
Lchk_BB4_27:                                ;   in Loop: Header=BB4_16 Depth=1
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	ldur	x10, [x29, #-64]
	ldr	x8, [sp, #40]
	mov	x9, sp
	str	x10, [x9]
	str	x8, [x9, #8]
	adrp	x1, l_chk.str.20@PAGE
	add	x1, x1, l_chk.str.20@PAGEOFF
	bl	_fprintf
	b	Lchk_BB4_28
Lchk_BB4_28:                                ;   in Loop: Header=BB4_16 Depth=1
	b	Lchk_BB4_29
Lchk_BB4_29:                                ;   in Loop: Header=BB4_16 Depth=1
	b	Lchk_BB4_31
Lchk_BB4_30:                                ;   in Loop: Header=BB4_16 Depth=1
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	ldur	x8, [x29, #-64]
	mov	x9, sp
	str	x8, [x9]
	adrp	x1, l_chk.str.21@PAGE
	add	x1, x1, l_chk.str.21@PAGEOFF
	bl	_fprintf
	b	Lchk_BB4_31
Lchk_BB4_31:                                ;   in Loop: Header=BB4_16 Depth=1
	b	Lchk_BB4_49
Lchk_BB4_32:                                ;   in Loop: Header=BB4_16 Depth=1
	ldr	x8, [sp, #72]
	subs	x8, x8, #16, lsl #12            ; =65536
	b.hs	Lchk_BB4_35
	b	Lchk_BB4_33
Lchk_BB4_33:                                ;   in Loop: Header=BB4_16 Depth=1
	ldr	w8, [sp, #48]
	cbz	w8, Lchk_BB4_35
	b	Lchk_BB4_34
Lchk_BB4_34:                                ;   in Loop: Header=BB4_16 Depth=1
	ldr	w8, [sp, #48]
	subs	w8, w8, #8
	b.ls	Lchk_BB4_36
	b	Lchk_BB4_35
Lchk_BB4_35:                                ;   in Loop: Header=BB4_16 Depth=1
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	ldur	x8, [x29, #-64]
	mov	x9, sp
	str	x8, [x9]
	adrp	x1, l_chk.str.22@PAGE
	add	x1, x1, l_chk.str.22@PAGEOFF
	bl	_fprintf
	b	Lchk_BB4_49
Lchk_BB4_36:                                ;   in Loop: Header=BB4_16 Depth=1
	ldur	x8, [x29, #-16]
	ldr	x9, [sp, #72]
	add	x8, x8, x9
	str	x8, [sp, #32]
	str	xzr, [sp, #24]
	str	wzr, [sp, #20]
	b	Lchk_BB4_37
Lchk_BB4_37:                                ;   Parent Loop BB4_16 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldr	w9, [sp, #20]
	ldr	w10, [sp, #48]
	mov	w8, #0                          ; =0x0
	subs	w9, w9, w10
	str	w8, [sp, #16]                   ; 4-byte Folded Spill
	b.hs	Lchk_BB4_39
	b	Lchk_BB4_38
Lchk_BB4_38:                                ;   in Loop: Header=BB4_37 Depth=2
	ldr	w8, [sp, #20]
	subs	w8, w8, #8
	cset	w8, lo
	str	w8, [sp, #16]                   ; 4-byte Folded Spill
	b	Lchk_BB4_39
Lchk_BB4_39:                                ;   in Loop: Header=BB4_37 Depth=2
	ldr	w8, [sp, #16]                   ; 4-byte Folded Reload
	tbz	w8, #0, Lchk_BB4_42
	b	Lchk_BB4_40
Lchk_BB4_40:                                ;   in Loop: Header=BB4_37 Depth=2
	ldr	x8, [sp, #32]
	ldr	w9, [sp, #20]
                                        ; kill: def $x9 killed $w9
	ldrb	w8, [x8, x9]
                                        ; kill: def $x8 killed $w8
	ldr	w10, [sp, #20]
	mov	w9, #8                          ; =0x8
	mul	w9, w9, w10
                                        ; kill: def $x9 killed $w9
	lsl	x9, x8, x9
	ldr	x8, [sp, #24]
	orr	x8, x8, x9
	str	x8, [sp, #24]
	b	Lchk_BB4_41
Lchk_BB4_41:                                ;   in Loop: Header=BB4_37 Depth=2
	ldr	w8, [sp, #20]
	add	w8, w8, #1
	str	w8, [sp, #20]
	b	Lchk_BB4_37
Lchk_BB4_42:                                ;   in Loop: Header=BB4_16 Depth=1
	ldr	w8, [sp, #52]
	subs	w8, w8, #2
	b.ne	Lchk_BB4_44
	b	Lchk_BB4_43
Lchk_BB4_43:                                ;   in Loop: Header=BB4_16 Depth=1
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	ldur	x10, [x29, #-64]
	ldr	x8, [sp, #24]
	mov	x9, sp
	str	x10, [x9]
	str	x8, [x9, #8]
	adrp	x1, l_chk.str.18@PAGE
	add	x1, x1, l_chk.str.18@PAGEOFF
	bl	_fprintf
	b	Lchk_BB4_48
Lchk_BB4_44:                                ;   in Loop: Header=BB4_16 Depth=1
	ldr	w8, [sp, #52]
	subs	w8, w8, #3
	b.ne	Lchk_BB4_46
	b	Lchk_BB4_45
Lchk_BB4_45:                                ;   in Loop: Header=BB4_16 Depth=1
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	ldur	x8, [x29, #-64]
	mov	x9, sp
	str	x8, [x9]
	adrp	x1, l_chk.str.19@PAGE
	add	x1, x1, l_chk.str.19@PAGEOFF
	bl	_fprintf
	b	Lchk_BB4_47
Lchk_BB4_46:                                ;   in Loop: Header=BB4_16 Depth=1
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	ldur	x10, [x29, #-64]
	ldr	x8, [sp, #24]
	mov	x9, sp
	str	x10, [x9]
	str	x8, [x9, #8]
	adrp	x1, l_chk.str.20@PAGE
	add	x1, x1, l_chk.str.20@PAGEOFF
	bl	_fprintf
	b	Lchk_BB4_47
Lchk_BB4_47:                                ;   in Loop: Header=BB4_16 Depth=1
	b	Lchk_BB4_48
Lchk_BB4_48:                                ;   in Loop: Header=BB4_16 Depth=1
	b	Lchk_BB4_49
Lchk_BB4_49:                                ;   in Loop: Header=BB4_16 Depth=1
	ldur	x8, [x29, #-64]
	add	x8, x8, #1
	stur	x8, [x29, #-64]
	b	Lchk_BB4_16
Lchk_BB4_50:
	adrp	x8, ___stderrp@GOTPAGE
	ldr	x8, [x8, ___stderrp@GOTPAGEOFF]
	ldr	x0, [x8]
	adrp	x1, l_chk.str.23@PAGE
	add	x1, x1, l_chk.str.23@PAGEOFF
	bl	_fprintf
	b	Lchk_BB4_52
Lchk_BB4_51:                                ;   in Loop: Header=BB4_6 Depth=1
	ldur	x8, [x29, #-40]
	add	x8, x8, #1
	stur	x8, [x29, #-40]
	ldur	x8, [x29, #-32]
	add	x8, x8, #40
	stur	x8, [x29, #-32]
	b	Lchk_BB4_6
Lchk_BB4_52:
	ldp	x29, x30, [sp, #144]            ; 16-byte Folded Reload
	add	sp, sp, #160
	ret
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function __xt_ms_applySaves
___xt_ms_applySaves:                    ; @__xt_ms_applySaves
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #96
	.cfi_def_cfa_offset 96
	str	x0, [sp, #88]
	str	x1, [sp, #80]
	ldr	x8, [sp, #80]
	cbnz	x8, Lchk_BB5_2
	b	Lchk_BB5_1
Lchk_BB5_1:
	b	Lchk_BB5_27
Lchk_BB5_2:
	adrp	x8, ___xt_ms_fns@PAGE
	ldr	x8, [x8, ___xt_ms_fns@PAGEOFF]
	str	x8, [sp, #72]
	ldr	x8, [sp, #72]
	cbz	x8, Lchk_BB5_4
	b	Lchk_BB5_3
Lchk_BB5_3:
	ldr	x8, [sp, #72]
	mov	x9, #16960                      ; =0x4240
	movk	x9, #15, lsl #16
	subs	x8, x8, x9
	b.ls	Lchk_BB5_5
	b	Lchk_BB5_4
Lchk_BB5_4:
	b	Lchk_BB5_27
Lchk_BB5_5:
	adrp	x8, ___xt_ms_fns@PAGE
	add	x8, x8, ___xt_ms_fns@PAGEOFF
	add	x8, x8, #8
	str	x8, [sp, #64]
	str	xzr, [sp, #56]
	b	Lchk_BB5_6
Lchk_BB5_6:                                 ; =>This Inner Loop Header: Depth=1
	ldr	x8, [sp, #56]
	ldr	x9, [sp, #72]
	subs	x8, x8, x9
	b.hs	Lchk_BB5_27
	b	Lchk_BB5_7
Lchk_BB5_7:                                 ;   in Loop: Header=BB5_6 Depth=1
	ldr	x8, [sp, #64]
	ldr	x8, [x8]
	ldr	x9, [sp, #88]
	subs	x8, x8, x9
	b.eq	Lchk_BB5_9
	b	Lchk_BB5_8
Lchk_BB5_8:                                 ;   in Loop: Header=BB5_6 Depth=1
	b	Lchk_BB5_26
Lchk_BB5_9:
	ldr	x8, [sp, #64]
	ldr	x8, [x8, #24]
	str	x8, [sp, #48]
	ldr	x8, [sp, #64]
	ldr	x8, [x8, #32]
	str	x8, [sp, #40]
	ldr	x8, [sp, #40]
	cbz	x8, Lchk_BB5_11
	b	Lchk_BB5_10
Lchk_BB5_10:
	ldr	x8, [sp, #48]
	subs	x8, x8, #16, lsl #12            ; =65536
	b.lo	Lchk_BB5_12
	b	Lchk_BB5_11
Lchk_BB5_11:
	b	Lchk_BB5_27
Lchk_BB5_12:
	str	xzr, [sp, #32]
	b	Lchk_BB5_13
Lchk_BB5_13:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB5_20 Depth 2
	ldr	x8, [sp, #40]
	ldr	x9, [sp, #32]
	ldr	x8, [x8, x9, lsl #3]
	mov	w9, #0                          ; =0x0
	str	w9, [sp]                        ; 4-byte Folded Spill
	tbnz	x8, #63, Lchk_BB5_15
	b	Lchk_BB5_14
Lchk_BB5_14:                                ;   in Loop: Header=BB5_13 Depth=1
	ldr	x8, [sp, #32]
	subs	x8, x8, #32
	cset	w8, lo
	str	w8, [sp]                        ; 4-byte Folded Spill
	b	Lchk_BB5_15
Lchk_BB5_15:                                ;   in Loop: Header=BB5_13 Depth=1
	ldr	w8, [sp]                        ; 4-byte Folded Reload
	tbz	w8, #0, Lchk_BB5_25
	b	Lchk_BB5_16
Lchk_BB5_16:                                ;   in Loop: Header=BB5_13 Depth=1
	ldr	x8, [sp, #40]
	ldr	x9, [sp, #32]
	ldr	x8, [x8, x9, lsl #3]
	str	x8, [sp, #24]
	ldr	x8, [sp, #24]
	tbnz	x8, #63, Lchk_BB5_18
	b	Lchk_BB5_17
Lchk_BB5_17:                                ;   in Loop: Header=BB5_13 Depth=1
	ldr	x8, [sp, #24]
	subs	x8, x8, #32
	b.lt	Lchk_BB5_19
	b	Lchk_BB5_18
Lchk_BB5_18:                                ;   in Loop: Header=BB5_13 Depth=1
	b	Lchk_BB5_24
Lchk_BB5_19:                                ;   in Loop: Header=BB5_13 Depth=1
	ldr	x8, [sp, #80]
	ldr	x9, [sp, #48]
	add	x8, x8, x9
	ldr	x9, [sp, #32]
	add	x8, x8, x9, lsl #3
	str	x8, [sp, #16]
	str	xzr, [sp, #8]
	str	wzr, [sp, #4]
	b	Lchk_BB5_20
Lchk_BB5_20:                                ;   Parent Loop BB5_13 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldr	w8, [sp, #4]
	subs	w8, w8, #8
	b.hs	Lchk_BB5_23
	b	Lchk_BB5_21
Lchk_BB5_21:                                ;   in Loop: Header=BB5_20 Depth=2
	ldr	x8, [sp, #16]
	ldr	w9, [sp, #4]
                                        ; kill: def $x9 killed $w9
	ldrb	w8, [x8, x9]
                                        ; kill: def $x8 killed $w8
	ldr	w10, [sp, #4]
	mov	w9, #8                          ; =0x8
	mul	w9, w9, w10
                                        ; kill: def $x9 killed $w9
	lsl	x9, x8, x9
	ldr	x8, [sp, #8]
	orr	x8, x8, x9
	str	x8, [sp, #8]
	b	Lchk_BB5_22
Lchk_BB5_22:                                ;   in Loop: Header=BB5_20 Depth=2
	ldr	w8, [sp, #4]
	add	w8, w8, #1
	str	w8, [sp, #4]
	b	Lchk_BB5_20
Lchk_BB5_23:                                ;   in Loop: Header=BB5_13 Depth=1
	ldr	x8, [sp, #8]
	ldr	x10, [sp, #24]
	adrp	x9, ___xt_ms_reg@PAGE
	add	x9, x9, ___xt_ms_reg@PAGEOFF
	str	x8, [x9, x10, lsl #3]
	ldr	x9, [sp, #24]
	adrp	x8, ___xt_ms_regKnown@PAGE
	add	x8, x8, ___xt_ms_regKnown@PAGEOFF
	add	x9, x8, x9
	mov	w8, #1                          ; =0x1
	strb	w8, [x9]
	b	Lchk_BB5_24
Lchk_BB5_24:                                ;   in Loop: Header=BB5_13 Depth=1
	ldr	x8, [sp, #32]
	add	x8, x8, #1
	str	x8, [sp, #32]
	b	Lchk_BB5_13
Lchk_BB5_25:
	b	Lchk_BB5_27
Lchk_BB5_26:                                ;   in Loop: Header=BB5_6 Depth=1
	ldr	x8, [sp, #56]
	add	x8, x8, #1
	str	x8, [sp, #56]
	ldr	x8, [sp, #64]
	add	x8, x8, #40
	str	x8, [sp, #64]
	b	Lchk_BB5_6
Lchk_BB5_27:
	add	sp, sp, #96
	ret
	.cfi_endproc
                                        ; -- End function
	.section	__TEXT,__cstring,cstring_literals
l_chk.str:                                 ; @.str
	.asciz	"\n=== xcc: out-of-bounds access ===\n"

l_chk.str.1:                               ; @.str.1
	.asciz	"  at %s\n"

l_chk.str.2:                               ; @.str.2
	.asciz	"  %s: index %lu, but the allocation holds %lu element%s of %lu byte%s\n"

l_chk.str.3:                               ; @.str.3
	.asciz	"array"

l_chk.str.4:                               ; @.str.4
	.space	1

l_chk.str.5:                               ; @.str.5
	.asciz	"s"

l_chk.str.6:                               ; @.str.6
	.asciz	"  %p is not a heap allocation (no header) \342\200\224 its extent is unknown, so only the access was checked\n"

l_chk.str.7:                               ; @.str.7
	.asciz	"  [c] continue (the offending access is SUPPRESSED, not performed), any other key aborts: "

l_chk.str.8:                               ; @.str.8
	.asciz	"  continuing\n"

l_chk.str.9:                               ; @.str.9
	.asciz	"  aborting\n"

.zerofill __DATA,__bss,___xt_ms_reg,256,3 ; @__xt_ms_reg
.zerofill __DATA,__bss,___xt_ms_regKnown,32,0 ; @__xt_ms_regKnown
l_chk.str.10:                              ; @.str.10
	.asciz	"  stack:\n"

l_chk.str.11:                              ; @.str.11
	.asciz	"    #%-2d %s +%lu\n"

l_chk.str.12:                              ; @.str.12
	.asciz	"    #%-2d %p\n"

l_chk.str.13:                              ; @.str.13
	.asciz	"__LINKEDIT"

l_chk.str.14:                              ; @.str.14
	.asciz	"__text"

l_chk.str.15:                              ; @.str.15
	.asciz	"__TEXT"

l_chk.str.16:                              ; @.str.16
	.asciz	"         args: <map unreadable>\n"

l_chk.str.17:                              ; @.str.17
	.asciz	"         args:"

l_chk.str.18:                              ; @.str.18
	.asciz	" arg%lu=%p"

l_chk.str.19:                              ; @.str.19
	.asciz	" arg%lu=<float>"

l_chk.str.20:                              ; @.str.20
	.asciz	" arg%lu=%llu"

l_chk.str.21:                              ; @.str.21
	.asciz	" arg%lu=<in a register, not recovered>"

l_chk.str.22:                              ; @.str.22
	.asciz	" arg%lu=<unavailable>"

l_chk.str.23:                              ; @.str.23
	.asciz	"\n"

.subsections_via_symbols
