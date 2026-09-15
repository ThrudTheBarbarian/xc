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

	.section	__TEXT,__text,regular,pure_instructions
	.build_version iossimulator, 15, 0	sdk_version 26, 0
	.globl	__xt_ios_log                    ; -- Begin function _xt_ios_log
	.p2align	2
__xt_ios_log:                           ; @_xt_ios_log
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #32
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	.cfi_def_cfa_offset 32
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	cmp	w0, #1
	mov	w8, #4                          ; =0x4
	cinc	w8, w8, ne
	mov	w9, #3                          ; =0x3
	cmp	w0, #2
	csel	w0, w9, w8, eq
	str	x1, [sp]
LIOSloh0:
	adrp	x1, lios_.str@PAGE
LIOSloh1:
	add	x1, x1, lios_.str@PAGEOFF
	bl	_syslog
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	add	sp, sp, #32
	ret
	.loh AdrpAdd	LIOSloh0, LIOSloh1
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_ios_free                   ; -- Begin function _xt_ios_free
	.p2align	2
__xt_ios_free:                          ; @_xt_ios_free
	.cfi_startproc
; %bb.0:
	b	_free
	.cfi_endproc
                                        ; -- End function
	.globl	__xt_ios_fetch                  ; -- Begin function _xt_ios_fetch
	.p2align	2
__xt_ios_fetch:                         ; @_xt_ios_fetch
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #144
	stp	x22, x21, [sp, #96]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #112]            ; 16-byte Folded Spill
	stp	x29, x30, [sp, #128]            ; 16-byte Folded Spill
	.cfi_def_cfa_offset 144
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	mov	x19, x2
	mov	x20, x1
	mov	x21, x0
	str	wzr, [x1]
	str	wzr, [x2]
LIOSloh2:
	adrp	x0, lios_.str.1@PAGE
LIOSloh3:
	add	x0, x0, lios_.str.1@PAGEOFF
	bl	_objc_getClass
	mov	x22, x0
LIOSloh4:
	adrp	x0, lios_.str.2@PAGE
LIOSloh5:
	add	x0, x0, lios_.str.2@PAGEOFF
	bl	_sel_registerName
	mov	x1, x0
	mov	x0, x22
	mov	x2, x21
	bl	_objc_msgSend
	mov	x21, x0
LIOSloh6:
	adrp	x0, lios_.str.3@PAGE
LIOSloh7:
	add	x0, x0, lios_.str.3@PAGEOFF
	bl	_objc_getClass
	mov	x22, x0
LIOSloh8:
	adrp	x0, lios_.str.4@PAGE
LIOSloh9:
	add	x0, x0, lios_.str.4@PAGEOFF
	bl	_sel_registerName
	mov	x1, x0
	mov	x0, x22
	mov	x2, x21
	bl	_objc_msgSend
	cbz	x0, LIOSBB2_3
; %bb.1:
	mov	x21, x0
LIOSloh10:
	adrp	x0, lios_.str.5@PAGE
LIOSloh11:
	add	x0, x0, lios_.str.5@PAGEOFF
	bl	_objc_getClass
	mov	x22, x0
LIOSloh12:
	adrp	x0, lios_.str.6@PAGE
LIOSloh13:
	add	x0, x0, lios_.str.6@PAGEOFF
	bl	_sel_registerName
	mov	x1, x0
	mov	x0, x22
	bl	_objc_msgSend
	mov	x22, x0
	stp	xzr, xzr, [sp, #80]
	stp	xzr, xzr, [sp, #64]
	mov	x0, #0                          ; =0x0
	bl	_dispatch_semaphore_create
	str	x0, [sp, #88]
	mov	w8, #40                         ; =0x28
	stp	xzr, x8, [sp, #48]
LIOSloh14:
	adrp	x8, __NSConcreteStackBlock@GOTPAGE
LIOSloh15:
	ldr	x8, [x8, __NSConcreteStackBlock@GOTPAGEOFF]
LIOSloh16:
	adrp	x9, _xt_fetch_done@PAGE
LIOSloh17:
	add	x9, x9, _xt_fetch_done@PAGEOFF
	stp	x8, xzr, [sp, #8]
	add	x8, sp, #48
	stp	x9, x8, [sp, #24]
	add	x8, sp, #64
	str	x8, [sp, #40]
LIOSloh18:
	adrp	x0, lios_.str.7@PAGE
LIOSloh19:
	add	x0, x0, lios_.str.7@PAGEOFF
	bl	_sel_registerName
	mov	x1, x0
	add	x3, sp, #8
	mov	x0, x22
	mov	x2, x21
	bl	_objc_msgSend
	cbz	x0, LIOSBB2_3
; %bb.2:
	mov	x21, x0
LIOSloh20:
	adrp	x0, lios_.str.8@PAGE
LIOSloh21:
	add	x0, x0, lios_.str.8@PAGEOFF
	bl	_sel_registerName
	mov	x1, x0
	mov	x0, x21
	bl	_objc_msgSend
	ldr	x0, [sp, #88]
	mov	x1, #-1                         ; =0xffffffffffffffff
	bl	_dispatch_semaphore_wait
	ldp	w9, w8, [sp, #72]
	str	w8, [x20]
	str	w9, [x19]
	ldr	x0, [sp, #64]
LIOSBB2_3:
	ldp	x29, x30, [sp, #128]            ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #112]            ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #96]             ; 16-byte Folded Reload
	add	sp, sp, #144
	ret
	.loh AdrpAdd	LIOSloh8, LIOSloh9
	.loh AdrpAdd	LIOSloh6, LIOSloh7
	.loh AdrpAdd	LIOSloh4, LIOSloh5
	.loh AdrpAdd	LIOSloh2, LIOSloh3
	.loh AdrpAdd	LIOSloh18, LIOSloh19
	.loh AdrpAdd	LIOSloh16, LIOSloh17
	.loh AdrpLdrGot	LIOSloh14, LIOSloh15
	.loh AdrpAdd	LIOSloh12, LIOSloh13
	.loh AdrpAdd	LIOSloh10, LIOSloh11
	.loh AdrpAdd	LIOSloh20, LIOSloh21
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function xt_fetch_done
_xt_fetch_done:                         ; @xt_fetch_done
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
	ldr	x22, [x0, #32]
	stp	xzr, xzr, [x22]
	cbz	x1, LIOSBB3_9
; %bb.1:
	cbnz	x3, LIOSBB3_9
; %bb.2:
	mov	x19, x2
	mov	x21, x1
LIOSloh22:
	adrp	x0, lios_.str.9@PAGE
LIOSloh23:
	add	x0, x0, lios_.str.9@PAGEOFF
	bl	_sel_registerName
	mov	x1, x0
	mov	x0, x21
	bl	_objc_msgSend
	mov	x20, x0
LIOSloh24:
	adrp	x0, lios_.str.10@PAGE
LIOSloh25:
	add	x0, x0, lios_.str.10@PAGEOFF
	bl	_sel_registerName
	mov	x1, x0
	mov	x0, x21
	bl	_objc_msgSend
	mov	x21, x0
	add	w0, w20, #1
	bl	_malloc
	str	x0, [x22]
	cbz	x0, LIOSBB3_6
; %bb.3:
	cbz	w20, LIOSBB3_5
; %bb.4:
	mov	w2, w20
	mov	x1, x21
	bl	_memcpy
LIOSBB3_5:
	ldr	x8, [x22]
	strb	wzr, [x8, w20, uxtw]
	str	w20, [x22, #8]
LIOSBB3_6:
	mov	w8, #200                        ; =0xc8
	str	w8, [x22, #12]
	cbz	x19, LIOSBB3_9
; %bb.7:
LIOSloh26:
	adrp	x0, lios_.str.11@PAGE
LIOSloh27:
	add	x0, x0, lios_.str.11@PAGEOFF
	bl	_objc_getClass
	mov	x20, x0
LIOSloh28:
	adrp	x0, lios_.str.12@PAGE
LIOSloh29:
	add	x0, x0, lios_.str.12@PAGEOFF
	bl	_sel_registerName
	mov	x1, x0
	mov	x0, x19
	mov	x2, x20
	bl	_objc_msgSend
	cbz	w0, LIOSBB3_9
; %bb.8:
LIOSloh30:
	adrp	x0, lios_.str.13@PAGE
LIOSloh31:
	add	x0, x0, lios_.str.13@PAGEOFF
	bl	_sel_registerName
	mov	x1, x0
	mov	x0, x19
	bl	_objc_msgSend
	str	w0, [x22, #12]
LIOSBB3_9:
	mov	w8, #1                          ; =0x1
	str	w8, [x22, #16]
	ldr	x0, [x22, #24]
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	b	_dispatch_semaphore_signal
	.loh AdrpAdd	LIOSloh24, LIOSloh25
	.loh AdrpAdd	LIOSloh22, LIOSloh23
	.loh AdrpAdd	LIOSloh28, LIOSloh29
	.loh AdrpAdd	LIOSloh26, LIOSloh27
	.loh AdrpAdd	LIOSloh30, LIOSloh31
	.cfi_endproc
                                        ; -- End function
	.section	__TEXT,__cstring,cstring_literals
lios_.str:                                 ; @.str
	.asciz	"%s"

lios_.str.1:                               ; @.str.1
	.asciz	"NSString"

lios_.str.2:                               ; @.str.2
	.asciz	"stringWithUTF8String:"

lios_.str.3:                               ; @.str.3
	.asciz	"NSURL"

lios_.str.4:                               ; @.str.4
	.asciz	"URLWithString:"

lios_.str.5:                               ; @.str.5
	.asciz	"NSURLSession"

lios_.str.6:                               ; @.str.6
	.asciz	"sharedSession"

	.section	__TEXT,__literal16,16byte_literals
	.p2align	3, 0x0                          ; @__const._xt_ios_fetch.desc
l___const._xt_ios_fetch.desc:
	.quad	0                               ; 0x0
	.quad	40                              ; 0x28

	.section	__TEXT,__cstring,cstring_literals
lios_.str.7:                               ; @.str.7
	.asciz	"dataTaskWithURL:completionHandler:"

lios_.str.8:                               ; @.str.8
	.asciz	"resume"

lios_.str.9:                               ; @.str.9
	.asciz	"length"

lios_.str.10:                              ; @.str.10
	.asciz	"bytes"

lios_.str.11:                              ; @.str.11
	.asciz	"NSHTTPURLResponse"

lios_.str.12:                              ; @.str.12
	.asciz	"isKindOfClass:"

lios_.str.13:                              ; @.str.13
	.asciz	"statusCode"

.subsections_via_symbols
