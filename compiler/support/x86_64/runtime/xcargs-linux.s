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
// `python3 tools/regen-runtimes.py xcargs-linux`; do not edit.
// regenerated with: Apple clang version 17.0.0 (clang-1700.3.19.1)
	.text
	.intel_syntax noprefix
	.file	"rt-xcargs.c"
	.globl	_xt_xcargs                      # -- Begin function _xt_xcargs
	.p2align	4, 0x90
	.type	_xt_xcargs,@function
_xt_xcargs:                             # @_xt_xcargs
# %bb.0:
	push	rbp
	push	r15
	push	r14
	push	r13
	push	r12
	push	rbx
	sub	rsp, 232
	mov	ebp, edi
	test	edi, edi
	setle	al
	test	rsi, rsi
	sete	cl
	or	cl, al
	jne	.Lxa_BB0_100
# %bb.1:
	mov	rbx, rsi
	mov	esi, 1
	mov	r14d, 1
	cmp	ebp, 2
	jl	.Lxa_BB0_92
# %bb.2:
	mov	eax, ebp
	mov	qword ptr [rsp + 40], rax       # 8-byte Spill
	mov	esi, 1
	mov	r10d, 1537
	lea	rdi, [rip + .Lxa_.str.2]
	lea	r8, [rip + .Lxa_.str]
	mov	qword ptr [rsp + 32], rbx       # 8-byte Spill
	mov	dword ptr [rsp + 24], ebp       # 4-byte Spill
	.p2align	4, 0x90
.Lxa_BB0_3:                                # =>This Loop Header: Depth=1
                                        #     Child Loop BB0_8 Depth 2
                                        #     Child Loop BB0_13 Depth 2
                                        #     Child Loop BB0_15 Depth 2
                                        #     Child Loop BB0_20 Depth 2
                                        #     Child Loop BB0_24 Depth 2
                                        #     Child Loop BB0_26 Depth 2
                                        #       Child Loop BB0_27 Depth 3
                                        #       Child Loop BB0_31 Depth 3
                                        #       Child Loop BB0_36 Depth 3
                                        #       Child Loop BB0_40 Depth 3
                                        #       Child Loop BB0_44 Depth 3
                                        #     Child Loop BB0_49 Depth 2
                                        #     Child Loop BB0_55 Depth 2
                                        #     Child Loop BB0_66 Depth 2
                                        #     Child Loop BB0_69 Depth 2
                                        #       Child Loop BB0_71 Depth 3
                                        #       Child Loop BB0_75 Depth 3
                                        #       Child Loop BB0_81 Depth 3
	mov	r11, qword ptr [rbx + 8*rsi]
	cmp	byte ptr [r11], 45
	jne	.Lxa_BB0_7
# %bb.4:                                #   in Loop: Header=BB0_3 Depth=1
	cmp	byte ptr [r11 + 1], 45
	jne	.Lxa_BB0_7
# %bb.5:                                #   in Loop: Header=BB0_3 Depth=1
	cmp	byte ptr [r11 + 2], 0
	je	.Lxa_BB0_6
	.p2align	4, 0x90
.Lxa_BB0_7:                                #   in Loop: Header=BB0_3 Depth=1
	xor	eax, eax
	.p2align	4, 0x90
.Lxa_BB0_8:                                #   Parent Loop BB0_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	rax, 5
	je	.Lxa_BB0_12
# %bb.9:                                #   in Loop: Header=BB0_8 Depth=2
	movzx	ecx, byte ptr [rax + r8]
	lea	rdx, [rax + 1]
	cmp	byte ptr [r11 + rax], cl
	mov	rax, rdx
	je	.Lxa_BB0_8
# %bb.10:                               #   in Loop: Header=BB0_3 Depth=1
	test	cl, cl
	je	.Lxa_BB0_12
# %bb.11:                               #   in Loop: Header=BB0_3 Depth=1
	movsxd	rax, r14d
	inc	r14d
	mov	qword ptr [rbx + 8*rax], r11
	xor	eax, eax
	test	al, al
	je	.Lxa_BB0_90
	jmp	.Lxa_BB0_92
	.p2align	4, 0x90
.Lxa_BB0_12:                               #   in Loop: Header=BB0_3 Depth=1
	mov	r15, -1
	mov	rcx, -5
	.p2align	4, 0x90
.Lxa_BB0_13:                               #   Parent Loop BB0_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	rax, rcx
	cmp	byte ptr [r11 + r15 + 1], 0
	lea	r15, [r15 + 1]
	lea	rcx, [rcx + 1]
	jne	.Lxa_BB0_13
# %bb.14:                               #   in Loop: Header=BB0_3 Depth=1
	mov	ecx, 5
	cmp	r15, 6
	jb	.Lxa_BB0_18
	.p2align	4, 0x90
.Lxa_BB0_15:                               #   Parent Loop BB0_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	byte ptr [r11 + rcx], 61
	je	.Lxa_BB0_18
# %bb.16:                               #   in Loop: Header=BB0_15 Depth=2
	inc	rcx
	dec	rax
	jne	.Lxa_BB0_15
# %bb.17:                               #   in Loop: Header=BB0_3 Depth=1
	mov	rcx, r15
.Lxa_BB0_18:                               #   in Loop: Header=BB0_3 Depth=1
	mov	qword ptr [rsp + 8], rcx        # 8-byte Spill
	cmp	rcx, 9
	mov	qword ptr [rsp + 48], rsi       # 8-byte Spill
	mov	qword ptr [rsp + 16], r11       # 8-byte Spill
	jne	.Lxa_BB0_47
# %bb.19:                               #   in Loop: Header=BB0_3 Depth=1
	xor	eax, eax
	.p2align	4, 0x90
.Lxa_BB0_20:                               #   Parent Loop BB0_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	rax, 4
	je	.Lxa_BB0_23
# %bb.21:                               #   in Loop: Header=BB0_20 Depth=2
	movzx	ecx, byte ptr [rax + rdi]
	lea	rdx, [rax + 1]
	cmp	byte ptr [r11 + rax + 5], cl
	mov	rax, rdx
	je	.Lxa_BB0_20
# %bb.22:                               #   in Loop: Header=BB0_3 Depth=1
	test	cl, cl
	jne	.Lxa_BB0_47
.Lxa_BB0_23:                               #   in Loop: Header=BB0_3 Depth=1
	mov	dword ptr [rsp + 28], r14d      # 4-byte Spill
	mov	rdx, -1
	lea	rsi, [rip + .Lxa_.str.4]
	.p2align	4, 0x90
.Lxa_BB0_24:                               #   Parent Loop BB0_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	byte ptr [rdx + rsi + 1], 0
	lea	rdx, [rdx + 1]
	jne	.Lxa_BB0_24
# %bb.25:                               #   in Loop: Header=BB0_3 Depth=1
	mov	edi, 1
	call	write@PLT
	lea	r14, [rip + xt_xa_table]
	mov	qword ptr [rsp + 56], r15       # 8-byte Spill
	.p2align	4, 0x90
.Lxa_BB0_26:                               #   Parent Loop BB0_3 Depth=1
                                        # =>  This Loop Header: Depth=2
                                        #       Child Loop BB0_27 Depth 3
                                        #       Child Loop BB0_31 Depth 3
                                        #       Child Loop BB0_36 Depth 3
                                        #       Child Loop BB0_40 Depth 3
                                        #       Child Loop BB0_44 Depth 3
	lea	rbx, [r14 + 2]
	lea	r12, [r14 + 1]
	mov	r15d, 2
	mov	ecx, 1537
	jmp	.Lxa_BB0_27
	.p2align	4, 0x90
.Lxa_BB0_29:                               #   in Loop: Header=BB0_27 Depth=3
	inc	r15
	inc	rbx
	inc	r12
.Lxa_BB0_27:                               #   Parent Loop BB0_3 Depth=1
                                        #     Parent Loop BB0_26 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	movzx	eax, byte ptr [r14 + r15 - 2]
	cmp	eax, 10
	ja	.Lxa_BB0_29
# %bb.28:                               #   in Loop: Header=BB0_27 Depth=3
	bt	ecx, eax
	jae	.Lxa_BB0_29
# %bb.30:                               #   in Loop: Header=BB0_26 Depth=2
	lea	rbp, [r15 - 2]
	xor	r13d, r13d
	jmp	.Lxa_BB0_31
	.p2align	4, 0x90
.Lxa_BB0_33:                               #   in Loop: Header=BB0_31 Depth=3
	inc	rbx
	dec	r13
.Lxa_BB0_31:                               #   Parent Loop BB0_3 Depth=1
                                        #     Parent Loop BB0_26 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	movzx	eax, byte ptr [rbx - 1]
	cmp	eax, 10
	ja	.Lxa_BB0_33
# %bb.32:                               #   in Loop: Header=BB0_31 Depth=3
	bt	ecx, eax
	jae	.Lxa_BB0_33
# %bb.34:                               #   in Loop: Header=BB0_26 Depth=2
	mov	edx, 160
	mov	r8d, 7
	lea	rdi, [rsp + 64]
	xor	esi, esi
	lea	rcx, [rip + .Lxa_.str.5]
	call	xt_xa_cat
	cmp	r15, 2
	setne	cl
	cmp	rax, 158
	setb	dl
	and	dl, cl
	cmp	dl, 1
	mov	r9d, 45
	mov	r15, qword ptr [rsp + 56]       # 8-byte Reload
	jne	.Lxa_BB0_38
# %bb.35:                               #   in Loop: Header=BB0_26 Depth=2
	lea	rcx, [rsp + rax]
	add	rcx, 64
	xor	edx, edx
	.p2align	4, 0x90
.Lxa_BB0_36:                               #   Parent Loop BB0_3 Depth=1
                                        #     Parent Loop BB0_26 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	movzx	esi, byte ptr [r14 + rdx]
	lea	edi, [rsi - 65]
	lea	r8d, [rsi + 32]
	cmp	dil, 26
	movzx	edi, r8b
	cmovae	edi, esi
	cmp	sil, 95
	cmove	edi, r9d
	mov	byte ptr [rcx + rdx], dil
	lea	rsi, [rdx + 1]
	cmp	rsi, rbp
	jae	.Lxa_BB0_37
# %bb.101:                              #   in Loop: Header=BB0_36 Depth=3
	add	rdx, rax
	cmp	rdx, 157
	mov	rdx, rsi
	jb	.Lxa_BB0_36
.Lxa_BB0_37:                               #   in Loop: Header=BB0_26 Depth=2
	add	rax, rsi
.Lxa_BB0_38:                               #   in Loop: Header=BB0_26 Depth=2
	test	r13, r13
	setne	cl
	cmp	rax, 158
	setb	dl
	and	dl, cl
	cmp	dl, 1
	jne	.Lxa_BB0_43
# %bb.39:                               #   in Loop: Header=BB0_26 Depth=2
	neg	r13
	lea	rcx, [rsp + rax]
	add	rcx, 64
	xor	edx, edx
	.p2align	4, 0x90
.Lxa_BB0_40:                               #   Parent Loop BB0_3 Depth=1
                                        #     Parent Loop BB0_26 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	movzx	esi, byte ptr [r12]
	mov	byte ptr [rcx + rdx], sil
	lea	rsi, [rdx + 1]
	cmp	rsi, r13
	jae	.Lxa_BB0_42
# %bb.41:                               #   in Loop: Header=BB0_40 Depth=3
	add	rdx, rax
	inc	r12
	cmp	rdx, 157
	mov	rdx, rsi
	jb	.Lxa_BB0_40
.Lxa_BB0_42:                               #   in Loop: Header=BB0_26 Depth=2
	add	rax, rsi
.Lxa_BB0_43:                               #   in Loop: Header=BB0_26 Depth=2
	mov	word ptr [rsp + rax + 64], 10
	mov	rdx, -1
	.p2align	4, 0x90
.Lxa_BB0_44:                               #   Parent Loop BB0_3 Depth=1
                                        #     Parent Loop BB0_26 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	cmp	byte ptr [rsp + rdx + 65], 0
	lea	rdx, [rdx + 1]
	jne	.Lxa_BB0_44
# %bb.45:                               #   in Loop: Header=BB0_26 Depth=2
	mov	edi, 1
	lea	rsi, [rsp + 64]
	call	write@PLT
	cmp	byte ptr [rbx], 0
	mov	r14, rbx
	jne	.Lxa_BB0_26
# %bb.46:                               #   in Loop: Header=BB0_3 Depth=1
	mov	edx, 92
	mov	edi, 1
	lea	rsi, [rip + .Lxa_.str.6]
	call	write@PLT
	xor	edi, edi
	call	exit@PLT
	mov	rbx, qword ptr [rsp + 32]       # 8-byte Reload
	mov	ebp, dword ptr [rsp + 24]       # 4-byte Reload
	mov	r14d, dword ptr [rsp + 28]      # 4-byte Reload
	mov	r10d, 1537
	mov	r11, qword ptr [rsp + 16]       # 8-byte Reload
.Lxa_BB0_47:                               #   in Loop: Header=BB0_3 Depth=1
	lea	rax, [r11 + 5]
	mov	rcx, qword ptr [rsp + 8]        # 8-byte Reload
	add	rcx, -5
	cmp	rcx, 5
	jne	.Lxa_BB0_53
# %bb.48:                               #   in Loop: Header=BB0_3 Depth=1
	xor	ecx, ecx
	lea	rdi, [rip + .Lxa_.str.7]
	.p2align	4, 0x90
.Lxa_BB0_49:                               #   Parent Loop BB0_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	rcx, 5
	je	.Lxa_BB0_50
# %bb.51:                               #   in Loop: Header=BB0_49 Depth=2
	movzx	edx, byte ptr [rax + rcx]
	lea	rsi, [rcx + 1]
	cmp	dl, byte ptr [rcx + rdi]
	mov	rcx, rsi
	je	.Lxa_BB0_49
# %bb.52:                               #   in Loop: Header=BB0_3 Depth=1
	mov	ecx, 5
	jmp	.Lxa_BB0_53
.Lxa_BB0_50:                               #   in Loop: Header=BB0_3 Depth=1
	mov	ecx, 9
	lea	rax, [rip + .Lxa_.str.8]
.Lxa_BB0_53:                               #   in Loop: Header=BB0_3 Depth=1
	test	rcx, rcx
	sete	dl
	lea	rsi, [rcx - 61]
	cmp	rsi, -65
	setb	sil
	or	sil, dl
	je	.Lxa_BB0_54
.Lxa_BB0_62:                               #   in Loop: Header=BB0_3 Depth=1
	mov	rdi, r11
	mov	rsi, qword ptr [rsp + 8]        # 8-byte Reload
	lea	rdx, [rip + .Lxa_.str.3]
	call	xt_xa_fail
	mov	r11, qword ptr [rsp + 16]       # 8-byte Reload
	mov	r10d, 1537
	jmp	.Lxa_BB0_63
	.p2align	4, 0x90
.Lxa_BB0_54:                               #   in Loop: Header=BB0_3 Depth=1
	mov	word ptr [rsp + 64], 17240
	mov	byte ptr [rsp + 66], 95
	mov	rdx, rcx
	neg	rdx
	mov	dil, 1
	mov	esi, 1
	jmp	.Lxa_BB0_55
	.p2align	4, 0x90
.Lxa_BB0_56:                               #   in Loop: Header=BB0_55 Depth=2
	add	r8b, -32
.Lxa_BB0_59:                               #   in Loop: Header=BB0_55 Depth=2
	mov	byte ptr [rsp + rsi + 66], r8b
	cmp	rsi, rcx
	setb	dil
	lea	r8, [rdx + rsi]
	inc	r8
	inc	rsi
	cmp	r8, 1
	je	.Lxa_BB0_61
.Lxa_BB0_55:                               #   Parent Loop BB0_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	movzx	r8d, byte ptr [rax + rsi - 1]
	lea	r9d, [r8 - 97]
	cmp	r9b, 25
	jbe	.Lxa_BB0_56
# %bb.57:                               #   in Loop: Header=BB0_55 Depth=2
	lea	r9d, [r8 - 48]
	cmp	r9b, 10
	jb	.Lxa_BB0_59
# %bb.58:                               #   in Loop: Header=BB0_55 Depth=2
	cmp	r8b, 45
	mov	r8b, 95
	je	.Lxa_BB0_59
# %bb.60:                               #   in Loop: Header=BB0_3 Depth=1
	test	dil, 1
	jne	.Lxa_BB0_62
	.p2align	4, 0x90
.Lxa_BB0_61:                               #   in Loop: Header=BB0_3 Depth=1
	mov	byte ptr [rsp + rcx + 67], 0
.Lxa_BB0_63:                               #   in Loop: Header=BB0_3 Depth=1
	lea	rsi, [rip + .Lxa_.str.11]
	cmp	byte ptr [rsp + 64], 88
	jne	.Lxa_BB0_68
# %bb.64:                               #   in Loop: Header=BB0_3 Depth=1
	mov	eax, 1
	.p2align	4, 0x90
.Lxa_BB0_66:                               #   Parent Loop BB0_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	rax, 14
	je	.Lxa_BB0_67
# %bb.65:                               #   in Loop: Header=BB0_66 Depth=2
	movzx	ecx, byte ptr [rsp + rax + 64]
	lea	rdx, [rax + 1]
	cmp	cl, byte ptr [rax + rsi]
	mov	rax, rdx
	je	.Lxa_BB0_66
	jmp	.Lxa_BB0_68
.Lxa_BB0_67:                               #   in Loop: Header=BB0_3 Depth=1
	mov	rdi, r11
	mov	rsi, qword ptr [rsp + 8]        # 8-byte Reload
	lea	rdx, [rip + .Lxa_.str.12]
	call	xt_xa_fail
	mov	r11, qword ptr [rsp + 16]       # 8-byte Reload
	mov	r10d, 1537
.Lxa_BB0_68:                               #   in Loop: Header=BB0_3 Depth=1
	lea	rcx, [rip + xt_xa_table]
	jmp	.Lxa_BB0_69
	.p2align	4, 0x90
.Lxa_BB0_85:                               #   in Loop: Header=BB0_69 Depth=2
	test	sil, sil
	je	.Lxa_BB0_86
.Lxa_BB0_69:                               #   Parent Loop BB0_3 Depth=1
                                        # =>  This Loop Header: Depth=2
                                        #       Child Loop BB0_71 Depth 3
                                        #       Child Loop BB0_75 Depth 3
                                        #       Child Loop BB0_81 Depth 3
	movzx	eax, byte ptr [rcx]
	test	al, al
	je	.Lxa_BB0_87
# %bb.70:                               #   in Loop: Header=BB0_69 Depth=2
	lea	rdx, [rcx + 2]
	xor	esi, esi
	jmp	.Lxa_BB0_71
	.p2align	4, 0x90
.Lxa_BB0_73:                               #   in Loop: Header=BB0_71 Depth=3
	inc	rsi
	inc	rdx
.Lxa_BB0_71:                               #   Parent Loop BB0_3 Depth=1
                                        #     Parent Loop BB0_69 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	movzx	edi, byte ptr [rcx + rsi]
	cmp	edi, 10
	ja	.Lxa_BB0_73
# %bb.72:                               #   in Loop: Header=BB0_71 Depth=3
	bt	r10d, edi
	jae	.Lxa_BB0_73
# %bb.74:                               #   in Loop: Header=BB0_69 Depth=2
	xor	edi, edi
	test	rsi, rsi
	je	.Lxa_BB0_78
	.p2align	4, 0x90
.Lxa_BB0_75:                               #   Parent Loop BB0_3 Depth=1
                                        #     Parent Loop BB0_69 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	movzx	r8d, byte ptr [rsp + rdi + 67]
	cmp	r8b, byte ptr [rcx + rdi]
	jne	.Lxa_BB0_78
# %bb.76:                               #   in Loop: Header=BB0_75 Depth=3
	inc	rdi
	cmp	rsi, rdi
	jne	.Lxa_BB0_75
# %bb.77:                               #   in Loop: Header=BB0_69 Depth=2
	mov	rdi, rsi
.Lxa_BB0_78:                               #   in Loop: Header=BB0_69 Depth=2
	cmp	rdi, rsi
	jne	.Lxa_BB0_81
# %bb.79:                               #   in Loop: Header=BB0_69 Depth=2
	cmp	byte ptr [rsp + rsi + 67], 0
	jne	.Lxa_BB0_81
# %bb.80:                               #   in Loop: Header=BB0_69 Depth=2
	xor	esi, esi
	jmp	.Lxa_BB0_85
	.p2align	4, 0x90
.Lxa_BB0_83:                               #   in Loop: Header=BB0_81 Depth=3
	inc	rdx
.Lxa_BB0_81:                               #   Parent Loop BB0_3 Depth=1
                                        #     Parent Loop BB0_69 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	movzx	ecx, byte ptr [rdx - 1]
	cmp	ecx, 10
	ja	.Lxa_BB0_83
# %bb.82:                               #   in Loop: Header=BB0_81 Depth=3
	bt	r10d, ecx
	jae	.Lxa_BB0_83
# %bb.84:                               #   in Loop: Header=BB0_69 Depth=2
	mov	sil, 1
	mov	rcx, rdx
	jmp	.Lxa_BB0_85
	.p2align	4, 0x90
.Lxa_BB0_86:                               #   in Loop: Header=BB0_3 Depth=1
	test	al, al
	jne	.Lxa_BB0_88
.Lxa_BB0_87:                               #   in Loop: Header=BB0_3 Depth=1
	mov	rdi, r11
	mov	rsi, qword ptr [rsp + 8]        # 8-byte Reload
	lea	rdx, [rip + .Lxa_.str.3]
	call	xt_xa_fail
	mov	r11, qword ptr [rsp + 16]       # 8-byte Reload
.Lxa_BB0_88:                               #   in Loop: Header=BB0_3 Depth=1
	mov	rax, qword ptr [rsp + 8]        # 8-byte Reload
	cmp	rax, r15
	lea	rsi, [r11 + rax + 1]
	lea	rax, [rip + .Lxa_.str.1]
	cmovae	rsi, rax
	lea	rdi, [rsp + 64]
	mov	edx, 1
	call	setenv@PLT
	mov	r10d, 1537
	xor	eax, eax
	mov	rsi, qword ptr [rsp + 48]       # 8-byte Reload
	lea	rdi, [rip + .Lxa_.str.2]
	lea	r8, [rip + .Lxa_.str]
	test	al, al
	jne	.Lxa_BB0_92
.Lxa_BB0_90:                               #   in Loop: Header=BB0_3 Depth=1
	inc	rsi
	cmp	rsi, qword ptr [rsp + 40]       # 8-byte Folded Reload
	jne	.Lxa_BB0_3
	jmp	.Lxa_BB0_91
.Lxa_BB0_6:                                #   in Loop: Header=BB0_3 Depth=1
	mov	al, 1
	test	al, al
	je	.Lxa_BB0_90
	jmp	.Lxa_BB0_92
.Lxa_BB0_91:
	mov	esi, ebp
.Lxa_BB0_92:
	mov	eax, ebp
	sub	eax, esi
	jle	.Lxa_BB0_96
# %bb.93:
	movsxd	rcx, r14d
	mov	edx, esi
	lea	rdx, [rbx + 8*rdx]
	lea	rsi, [rbx + 8*rcx]
	xor	ecx, ecx
	.p2align	4, 0x90
.Lxa_BB0_94:                               # =>This Inner Loop Header: Depth=1
	mov	rdi, qword ptr [rdx + 8*rcx]
	mov	qword ptr [rsi + 8*rcx], rdi
	inc	rcx
	cmp	eax, ecx
	jne	.Lxa_BB0_94
# %bb.95:
	add	r14d, ecx
.Lxa_BB0_96:
	cmp	r14d, ebp
	jge	.Lxa_BB0_99
# %bb.97:
	movsxd	rax, r14d
	mov	ecx, ebp
	.p2align	4, 0x90
.Lxa_BB0_98:                               # =>This Inner Loop Header: Depth=1
	mov	qword ptr [rbx + 8*rax], 0
	inc	rax
	cmp	rcx, rax
	jne	.Lxa_BB0_98
.Lxa_BB0_99:
	mov	ebp, r14d
.Lxa_BB0_100:
	mov	eax, ebp
	add	rsp, 232
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	pop	rbp
	ret
.Lxa_func_end0:
	.size	_xt_xcargs, .Lxa_func_end0-_xt_xcargs
                                        # -- End function
	.p2align	4, 0x90                         # -- Begin function xt_xa_fail
	.type	xt_xa_fail,@function
xt_xa_fail:                             # @xt_xa_fail
# %bb.0:
	push	r15
	push	r14
	push	r12
	push	rbx
	sub	rsp, 264
	mov	r14, rdx
	mov	r15, rsi
	mov	r12, rdi
	lea	rcx, [rip + .Lxa_.str.9]
	mov	rbx, rsp
	mov	edx, 256
	mov	r8d, 4
	mov	rdi, rbx
	xor	esi, esi
	call	xt_xa_cat
	mov	edx, 120
	mov	rdi, rbx
	mov	rsi, rax
	mov	rcx, r12
	mov	r8, r15
	call	xt_xa_cat
	mov	edx, 256
	mov	r8d, 256
	mov	rdi, rbx
	mov	rsi, rax
	mov	rcx, r14
	call	xt_xa_cat
	lea	rcx, [rip + .Lxa_.str.10]
	mov	edx, 256
	mov	r8d, 1
	mov	rdi, rbx
	mov	rsi, rax
	call	xt_xa_cat
	mov	rdx, -1
	.p2align	4, 0x90
.Lxa_BB1_1:                                # =>This Inner Loop Header: Depth=1
	cmp	byte ptr [rsp + rdx + 1], 0
	lea	rdx, [rdx + 1]
	jne	.Lxa_BB1_1
# %bb.2:
	mov	rsi, rsp
	mov	edi, 2
	call	write@PLT
	mov	edi, 2
	call	exit@PLT
	add	rsp, 264
	pop	rbx
	pop	r12
	pop	r14
	pop	r15
	ret
.Lxa_func_end1:
	.size	xt_xa_fail, .Lxa_func_end1-xt_xa_fail
                                        # -- End function
	.p2align	4, 0x90                         # -- Begin function xt_xa_cat
	.type	xt_xa_cat,@function
xt_xa_cat:                              # @xt_xa_cat
# %bb.0:
	test	r8, r8
	je	.Lxa_BB2_4
# %bb.1:
	neg	r8
	mov	r9d, 1
	.p2align	4, 0x90
.Lxa_BB2_2:                                # =>This Inner Loop Header: Depth=1
	movzx	r10d, byte ptr [rcx + r9 - 1]
	test	r10b, r10b
	je	.Lxa_BB2_4
# %bb.3:                                #   in Loop: Header=BB2_2 Depth=1
	lea	rax, [rsi + 1]
	cmp	rax, rdx
	jae	.Lxa_BB2_4
# %bb.6:                                #   in Loop: Header=BB2_2 Depth=1
	mov	byte ptr [rdi + rsi], r10b
	lea	r10, [r8 + r9]
	inc	r10
	inc	r9
	mov	rsi, rax
	cmp	r10, 1
	jne	.Lxa_BB2_2
# %bb.5:
	mov	byte ptr [rdi + rax], 0
	ret
.Lxa_BB2_4:
	mov	rax, rsi
	mov	byte ptr [rdi + rax], 0
	ret
.Lxa_func_end2:
	.size	xt_xa_cat, .Lxa_func_end2-xt_xa_cat
                                        # -- End function
	.type	.Lxa_.str,@object                  # @.str
	.section	.rodata.str1.1,"aMS",@progbits,1
.Lxa_.str:
	.asciz	"--xc-"
	.size	.Lxa_.str, 6

	.type	.Lxa_.str.1,@object                # @.str.1
.Lxa_.str.1:
	.asciz	"1"
	.size	.Lxa_.str.1, 2

	.type	.Lxa_.str.2,@object                # @.str.2
.Lxa_.str.2:
	.asciz	"help"
	.size	.Lxa_.str.2, 5

	.type	.Lxa_.str.3,@object                # @.str.3
.Lxa_.str.3:
	.asciz	": unknown option (--xc-help lists them)"
	.size	.Lxa_.str.3, 40

	.type	.Lxa_.str.4,@object                # @.str.4
.Lxa_.str.4:
	.asciz	"Options for the par runtime, taken out of the arguments before main.\nEach sets the variable it names (--xc-par-report is XC_PAR_REPORT=1),\noverriding the environment. Arguments after -- are left alone.\n\n"
	.size	.Lxa_.str.4, 204

	.type	xt_xa_table,@object             # @xt_xa_table
	.section	.rodata.str1.16,"aMS",@progbits,1
	.p2align	4, 0x0
xt_xa_table:
	.asciz	"PAR\t=cpu|gpu|gpus|all|auto  where every par block runs\nPAR_THREADS\t=<n>  threads a block on the CPU uses\nPAR_REPORT\t[=2]  print where each block ran and what auto measured\nPAR_FORGET\t  remove what auto learned, so it measures again\nPAR_PROBE\t  measure every worker on a block's first run (also --xc-probe)\nPAR_GPU\t=cuda|vulkan  the GPU interface where both exist\nPAR_VULKAN_DEVICE\t=<n>  the Vulkan device, by index\nPAR_CUDA_DEVICES\t=<n,...>  the CUDA cards that take tiles\nPAR_WORKERS\t=cpu,cuda,metal,vulkan,remote  the devices that share tiles\nPAR_TILES\t=0  run each block in one piece\nPAR_TILE_MB\t=<n>  megabytes a tile moves each way\nPAR_TRACE\t[=<file>|<host:port>]  record each run's tiles\nPAR_PIN\t=0  Linux: leave the CPU threads unpinned\nPAR_REMOTE\t=<host[:port],...>|mdns|none  the xcd daemons to use\nPAR_POOL\t=<name>  find the daemons of that pool by mDNS\nPAR_VERIFY\t=0|all  how many remote tiles are checked on the CPU\nTLS_LIB\t=<file>  the TLS library for connections to daemons\nPAR_VARIANT\t=<name>  test: the kernel variant a device runs\nPAR_VK_FULL\t=0  test: leave out Vulkan's full-dispatch form\nPAR_VULKAN_LOSE\t=<n>  test: the Vulkan device reads as lost after n submits\nPAR_DIE_AFTER\t=<n>  test: drop a remote connection after n tiles\nPAR_MACHINE\t=<name>  test: the machine name a daemon gives\n"
	.size	xt_xa_table, 1309

	.type	.Lxa_.str.5,@object                # @.str.5
	.section	.rodata.str1.1,"aMS",@progbits,1
.Lxa_.str.5:
	.asciz	"  --xc-"
	.size	.Lxa_.str.5, 8

	.type	.Lxa_.str.6,@object                # @.str.6
.Lxa_.str.6:
	.asciz	"  --xc-help  this list\n\nXC_PAR_SECRET has no option: a process listing shows the arguments.\n"
	.size	.Lxa_.str.6, 93

	.type	.Lxa_.str.7,@object                # @.str.7
.Lxa_.str.7:
	.asciz	"probe"
	.size	.Lxa_.str.7, 6

	.type	.Lxa_.str.8,@object                # @.str.8
.Lxa_.str.8:
	.asciz	"par-probe"
	.size	.Lxa_.str.8, 10

	.type	.Lxa_.str.9,@object                # @.str.9
.Lxa_.str.9:
	.asciz	"xc: "
	.size	.Lxa_.str.9, 5

	.type	.Lxa_.str.10,@object               # @.str.10
.Lxa_.str.10:
	.asciz	"\n"
	.size	.Lxa_.str.10, 2

	.type	.Lxa_.str.11,@object               # @.str.11
.Lxa_.str.11:
	.asciz	"XC_PAR_SECRET"
	.size	.Lxa_.str.11, 14

	.type	.Lxa_.str.12,@object               # @.str.12
.Lxa_.str.12:
	.asciz	": refused, a process listing shows the arguments; set XC_PAR_SECRET in the environment"
	.size	.Lxa_.str.12, 87

	.ident	"Apple clang version 17.0.0 (clang-1700.3.19.1)"
	.section	".note.GNU-stack","",@progbits
	.addrsig
