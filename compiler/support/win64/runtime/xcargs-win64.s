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
// `python3 tools/regen-runtimes.py xcargs-win64`; do not edit.
// regenerated with: Apple clang version 17.0.0 (clang-1700.3.19.1)
	.text
	.def	@feat.00;
	.scl	3;
	.type	0;
	.endef
	.globl	@feat.00
.set @feat.00, 0
	.intel_syntax noprefix
	.file	"rt-xcargs.c"
	.def	_xt_xcargs;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_xcargs                      # -- Begin function _xt_xcargs
	.p2align	4, 0x90
_xt_xcargs:                             # @_xt_xcargs
# %bb.0:
	push	r15
	push	r14
	push	r13
	push	r12
	push	rsi
	push	rdi
	push	rbp
	push	rbx
	sub	rsp, 2744
	call	GetCommandLineW
	mov	rdi, rax
	call	GetCommandLineA
	test	rdi, rdi
	je	.Lxa_BB0_158
# %bb.1:
	mov	rsi, rax
	lea	r12, [rsp + 690]
	xor	r15d, r15d
	lea	rbp, [rsp + 149]
	lea	r11, [rip + .Lxa_.str]
	xor	eax, eax
	xor	r13d, r13d
	mov	dword ptr [rsp + 44], 0         # 4-byte Folded Spill
	xor	r14d, r14d
	jmp	.Lxa_BB0_2
	.p2align	4, 0x90
.Lxa_BB0_22:                               #   in Loop: Header=BB0_2 Depth=1
	inc	r15d
.Lxa_BB0_115:                              #   in Loop: Header=BB0_2 Depth=1
	test	r8b, r8b
	jne	.Lxa_BB0_117
.Lxa_BB0_116:                              #   in Loop: Header=BB0_2 Depth=1
	lea	ecx, [r15 + 1]
	cmp	r15d, 255
	mov	r15d, ecx
	jge	.Lxa_BB0_117
.Lxa_BB0_2:                                # =>This Loop Header: Depth=1
                                        #     Child Loop BB0_3 Depth 2
                                        #     Child Loop BB0_7 Depth 2
                                        #     Child Loop BB0_17 Depth 2
                                        #     Child Loop BB0_30 Depth 2
                                        #     Child Loop BB0_35 Depth 2
                                        #     Child Loop BB0_40 Depth 2
                                        #     Child Loop BB0_44 Depth 2
                                        #     Child Loop BB0_46 Depth 2
                                        #       Child Loop BB0_47 Depth 3
                                        #       Child Loop BB0_51 Depth 3
                                        #       Child Loop BB0_56 Depth 3
                                        #       Child Loop BB0_60 Depth 3
                                        #       Child Loop BB0_64 Depth 3
                                        #     Child Loop BB0_69 Depth 2
                                        #     Child Loop BB0_75 Depth 2
                                        #     Child Loop BB0_86 Depth 2
                                        #     Child Loop BB0_89 Depth 2
                                        #       Child Loop BB0_91 Depth 3
                                        #       Child Loop BB0_95 Depth 3
                                        #       Child Loop BB0_103 Depth 3
                                        #     Child Loop BB0_113 Depth 2
	mov	ecx, r14d
	jmp	.Lxa_BB0_3
	.p2align	4, 0x90
.Lxa_BB0_164:                              #   in Loop: Header=BB0_3 Depth=2
	inc	ecx
.Lxa_BB0_3:                                #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	edx, ecx
	movzx	edx, word ptr [rdi + 2*rdx]
	cmp	edx, 9
	je	.Lxa_BB0_164
# %bb.4:                                #   in Loop: Header=BB0_3 Depth=2
	cmp	edx, 32
	je	.Lxa_BB0_164
# %bb.5:                                #   in Loop: Header=BB0_2 Depth=1
	test	edx, edx
	jne	.Lxa_BB0_6
# %bb.12:                               #   in Loop: Header=BB0_2 Depth=1
	mov	dl, 1
	test	dl, dl
	je	.Lxa_BB0_14
	jmp	.Lxa_BB0_117
	.p2align	4, 0x90
.Lxa_BB0_6:                                #   in Loop: Header=BB0_2 Depth=1
	xor	r8d, r8d
	mov	r14d, ecx
	jmp	.Lxa_BB0_7
	.p2align	4, 0x90
.Lxa_BB0_10:                               #   in Loop: Header=BB0_7 Depth=2
	xor	r9d, r9d
	test	r8d, r8d
	sete	r9b
	cmp	dx, 34
	cmove	r8d, r9d
	inc	r14d
	movzx	edx, word ptr [rdi + 2*r14]
	test	dx, dx
	je	.Lxa_BB0_11
.Lxa_BB0_7:                                #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	test	r8d, r8d
	jne	.Lxa_BB0_10
# %bb.8:                                #   in Loop: Header=BB0_7 Depth=2
	cmp	dx, 9
	je	.Lxa_BB0_11
# %bb.9:                                #   in Loop: Header=BB0_7 Depth=2
	movzx	r9d, dx
	cmp	r9d, 32
	jne	.Lxa_BB0_10
.Lxa_BB0_11:                               #   in Loop: Header=BB0_2 Depth=1
	xor	edx, edx
	mov	dword ptr [rsp + 44], ecx       # 4-byte Spill
	mov	r13d, r14d
	test	dl, dl
	jne	.Lxa_BB0_117
.Lxa_BB0_14:                               #   in Loop: Header=BB0_2 Depth=1
	movsxd	rcx, r15d
	mov	byte ptr [rsp + rcx + 432], 0
	test	ecx, ecx
	jle	.Lxa_BB0_116
# %bb.15:                               #   in Loop: Header=BB0_2 Depth=1
	mov	qword ptr [rsp + 72], rcx       # 8-byte Spill
	xor	r10d, r10d
	cmp	dword ptr [rsp + 44], r13d      # 4-byte Folded Reload
	jae	.Lxa_BB0_21
# %bb.16:                               #   in Loop: Header=BB0_2 Depth=1
	mov	ecx, dword ptr [rsp + 44]       # 4-byte Reload
	mov	edx, r13d
	inc	rcx
	xor	r10d, r10d
	mov	r8d, 1
	.p2align	4, 0x90
.Lxa_BB0_17:                               #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	movzx	r9d, word ptr [rdi + 2*rcx - 2]
	cmp	r9w, 34
	je	.Lxa_BB0_19
# %bb.18:                               #   in Loop: Header=BB0_17 Depth=2
	mov	r10d, r10d
	mov	word ptr [rsp + 2*r10 + 688], r9w
	mov	r10d, r8d
.Lxa_BB0_19:                               #   in Loop: Header=BB0_17 Depth=2
	cmp	rcx, rdx
	jae	.Lxa_BB0_21
# %bb.20:                               #   in Loop: Header=BB0_17 Depth=2
	lea	r8d, [r10 + 1]
	inc	rcx
	cmp	r8d, 1024
	jb	.Lxa_BB0_17
.Lxa_BB0_21:                               #   in Loop: Header=BB0_2 Depth=1
	mov	ecx, r10d
	mov	word ptr [rsp + 2*rcx + 688], 0
	cmp	r10d, 2
	sete	r8b
	movzx	edx, word ptr [rsp + 688]
	movzx	ecx, word ptr [rsp + 690]
	cmp	dx, 45
	sete	r9b
	and	r9b, r8b
	cmp	cx, 45
	sete	r8b
	and	r8b, r9b
	cmp	r8b, 1
	je	.Lxa_BB0_22
# %bb.23:                               #   in Loop: Header=BB0_2 Depth=1
	cmp	r10d, 5
	jb	.Lxa_BB0_115
# %bb.24:                               #   in Loop: Header=BB0_2 Depth=1
	cmp	dx, 45
	jne	.Lxa_BB0_115
# %bb.25:                               #   in Loop: Header=BB0_2 Depth=1
	cmp	cx, 45
	jne	.Lxa_BB0_115
# %bb.26:                               #   in Loop: Header=BB0_2 Depth=1
	cmp	word ptr [rsp + 692], 120
	jne	.Lxa_BB0_115
# %bb.27:                               #   in Loop: Header=BB0_2 Depth=1
	cmp	word ptr [rsp + 694], 99
	jne	.Lxa_BB0_115
# %bb.28:                               #   in Loop: Header=BB0_2 Depth=1
	cmp	word ptr [rsp + 696], 45
	jne	.Lxa_BB0_115
# %bb.29:                               #   in Loop: Header=BB0_2 Depth=1
	mov	byte ptr [rsp + 43], r8b        # 1-byte Spill
	cmp	r10d, 127
	mov	eax, 127
	cmovb	eax, r10d
	xor	ecx, ecx
	.p2align	4, 0x90
.Lxa_BB0_30:                               #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	movzx	edx, word ptr [rsp + 2*rcx + 688]
	cmp	dx, 61
	je	.Lxa_BB0_32
# %bb.31:                               #   in Loop: Header=BB0_30 Depth=2
	movzx	r8d, dx
	cmp	r8d, 128
	mov	r8d, 63
	cmovae	edx, r8d
	mov	byte ptr [rsp + rcx + 144], dl
	inc	rcx
	cmp	rax, rcx
	jne	.Lxa_BB0_30
	jmp	.Lxa_BB0_33
.Lxa_BB0_32:                               #   in Loop: Header=BB0_2 Depth=1
	mov	eax, ecx
.Lxa_BB0_33:                               #   in Loop: Header=BB0_2 Depth=1
	mov	byte ptr [rsp + rcx + 144], 0
	mov	ecx, 5
	cmp	eax, 6
	jb	.Lxa_BB0_38
# %bb.34:                               #   in Loop: Header=BB0_2 Depth=1
	mov	eax, eax
	mov	ecx, 5
	.p2align	4, 0x90
.Lxa_BB0_35:                               #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	byte ptr [rsp + rcx + 144], 61
	je	.Lxa_BB0_38
# %bb.36:                               #   in Loop: Header=BB0_35 Depth=2
	inc	rcx
	cmp	rax, rcx
	jne	.Lxa_BB0_35
# %bb.37:                               #   in Loop: Header=BB0_2 Depth=1
	mov	ecx, eax
.Lxa_BB0_38:                               #   in Loop: Header=BB0_2 Depth=1
	mov	qword ptr [rsp + 48], rcx       # 8-byte Spill
	cmp	ecx, 9
	mov	qword ptr [rsp + 56], r10       # 8-byte Spill
	jne	.Lxa_BB0_67
# %bb.39:                               #   in Loop: Header=BB0_2 Depth=1
	xor	eax, eax
	.p2align	4, 0x90
.Lxa_BB0_40:                               #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	rax, 4
	je	.Lxa_BB0_43
# %bb.41:                               #   in Loop: Header=BB0_40 Depth=2
	movzx	ecx, byte ptr [rax + r11]
	lea	rdx, [rax + 1]
	cmp	byte ptr [rsp + rax + 149], cl
	mov	rax, rdx
	je	.Lxa_BB0_40
# %bb.42:                               #   in Loop: Header=BB0_2 Depth=1
	test	cl, cl
	jne	.Lxa_BB0_67
.Lxa_BB0_43:                               #   in Loop: Header=BB0_2 Depth=1
	mov	qword ptr [rsp + 64], r15       # 8-byte Spill
	mov	dword ptr [rsp + 272], 0
	mov	ecx, -11
	call	GetStdHandle
	mov	r8d, -1
	lea	rdx, [rip + .Lxa_.str.2]
	.p2align	4, 0x90
.Lxa_BB0_44:                               #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	inc	r8d
	cmp	byte ptr [r8 + rdx], 0
	jne	.Lxa_BB0_44
# %bb.45:                               #   in Loop: Header=BB0_2 Depth=1
	mov	qword ptr [rsp + 32], 0
	mov	rcx, rax
                                        # kill: def $r8d killed $r8d killed $r8
	lea	r9, [rsp + 272]
	call	WriteFile
	lea	rbp, [rip + xt_xa_table]
	.p2align	4, 0x90
.Lxa_BB0_46:                               #   Parent Loop BB0_2 Depth=1
                                        # =>  This Loop Header: Depth=2
                                        #       Child Loop BB0_47 Depth 3
                                        #       Child Loop BB0_51 Depth 3
                                        #       Child Loop BB0_56 Depth 3
                                        #       Child Loop BB0_60 Depth 3
                                        #       Child Loop BB0_64 Depth 3
	xor	r15d, r15d
	mov	ecx, 1537
	jmp	.Lxa_BB0_47
	.p2align	4, 0x90
.Lxa_BB0_49:                               #   in Loop: Header=BB0_47 Depth=3
	inc	r15d
.Lxa_BB0_47:                               #   Parent Loop BB0_2 Depth=1
                                        #     Parent Loop BB0_46 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	mov	r15d, r15d
	movzx	eax, byte ptr [rbp + r15]
	cmp	eax, 10
	ja	.Lxa_BB0_49
# %bb.48:                               #   in Loop: Header=BB0_47 Depth=3
	bt	ecx, eax
	jae	.Lxa_BB0_49
# %bb.50:                               #   in Loop: Header=BB0_46 Depth=2
	lea	r12, [r15 + rbp]
	inc	r12
	xor	ebx, ebx
	jmp	.Lxa_BB0_51
	.p2align	4, 0x90
.Lxa_BB0_53:                               #   in Loop: Header=BB0_51 Depth=3
	inc	ebx
.Lxa_BB0_51:                               #   Parent Loop BB0_2 Depth=1
                                        #     Parent Loop BB0_46 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	mov	ebx, ebx
	movzx	eax, byte ptr [r12 + rbx]
	cmp	eax, 10
	ja	.Lxa_BB0_53
# %bb.52:                               #   in Loop: Header=BB0_51 Depth=3
	bt	ecx, eax
	jae	.Lxa_BB0_53
# %bb.54:                               #   in Loop: Header=BB0_46 Depth=2
	mov	dword ptr [rsp + 32], 7
	lea	rcx, [rsp + 272]
	xor	edx, edx
	mov	r8d, 160
	lea	r9, [rip + .Lxa_.str.3]
	call	xt_xa_cat
                                        # kill: def $eax killed $eax def $rax
	test	r15, r15
	setne	cl
	cmp	eax, 158
	setb	dl
	and	dl, cl
	cmp	dl, 1
	mov	r10d, 45
	jne	.Lxa_BB0_57
# %bb.55:                               #   in Loop: Header=BB0_46 Depth=2
	mov	eax, eax
	mov	ecx, 1
	.p2align	4, 0x90
.Lxa_BB0_56:                               #   Parent Loop BB0_2 Depth=1
                                        #     Parent Loop BB0_46 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	movzx	edx, byte ptr [rbp + rcx - 1]
	lea	r8d, [rdx - 65]
	lea	r9d, [rdx + 32]
	cmp	r8b, 26
	movzx	r8d, r9b
	cmovae	r8d, edx
	cmp	dl, 95
	cmove	r8d, r10d
	mov	rdx, rax
	mov	byte ptr [rsp + rax + 272], r8b
	inc	rax
	cmp	rdx, 156
	ja	.Lxa_BB0_57
# %bb.166:                              #   in Loop: Header=BB0_56 Depth=3
	lea	rdx, [rcx + 1]
	cmp	rcx, r15
	mov	rcx, rdx
	jb	.Lxa_BB0_56
.Lxa_BB0_57:                               #   in Loop: Header=BB0_46 Depth=2
	mov	ecx, eax
	test	rbx, rbx
	je	.Lxa_BB0_63
# %bb.58:                               #   in Loop: Header=BB0_46 Depth=2
	cmp	eax, 157
	ja	.Lxa_BB0_63
# %bb.59:                               #   in Loop: Header=BB0_46 Depth=2
	add	rbp, r15
	mov	eax, 1
	.p2align	4, 0x90
.Lxa_BB0_60:                               #   Parent Loop BB0_2 Depth=1
                                        #     Parent Loop BB0_46 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	mov	rdx, rcx
	movzx	ecx, byte ptr [rbp + rax]
	mov	byte ptr [rsp + rdx + 272], cl
	lea	rcx, [rdx + 1]
	cmp	rdx, 156
	ja	.Lxa_BB0_62
# %bb.61:                               #   in Loop: Header=BB0_60 Depth=3
	lea	rdx, [rax + 1]
	cmp	rax, rbx
	mov	rax, rdx
	jb	.Lxa_BB0_60
.Lxa_BB0_62:                               #   in Loop: Header=BB0_46 Depth=2
	mov	eax, ecx
.Lxa_BB0_63:                               #   in Loop: Header=BB0_46 Depth=2
	add	r12, rbx
	mov	eax, eax
	mov	byte ptr [rsp + rcx + 272], 10
	lea	rcx, [rsp + 272]
	mov	byte ptr [rax + rcx + 1], 0
	mov	dword ptr [rsp + 80], 0
	mov	ecx, -11
	call	GetStdHandle
	mov	r8d, -1
	.p2align	4, 0x90
.Lxa_BB0_64:                               #   Parent Loop BB0_2 Depth=1
                                        #     Parent Loop BB0_46 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	inc	r8d
	cmp	byte ptr [rsp + r8 + 272], 0
	jne	.Lxa_BB0_64
# %bb.65:                               #   in Loop: Header=BB0_46 Depth=2
	mov	qword ptr [rsp + 32], 0
	mov	rcx, rax
	lea	rdx, [rsp + 272]
                                        # kill: def $r8d killed $r8d killed $r8
	lea	r9, [rsp + 80]
	call	WriteFile
	lea	rbp, [r12 + 1]
	cmp	byte ptr [r12 + 1], 0
	jne	.Lxa_BB0_46
# %bb.66:                               #   in Loop: Header=BB0_2 Depth=1
	mov	dword ptr [rsp + 80], 0
	mov	ecx, -11
	call	GetStdHandle
	mov	qword ptr [rsp + 32], 0
	mov	rcx, rax
	lea	rdx, [rip + .Lxa_.str.4]
	mov	r8d, 92
	lea	r9, [rsp + 80]
	call	WriteFile
	xor	ecx, ecx
	call	ExitProcess
	mov	r15, qword ptr [rsp + 64]       # 8-byte Reload
	lea	r12, [rsp + 690]
	lea	rbp, [rsp + 149]
.Lxa_BB0_67:                               #   in Loop: Header=BB0_2 Depth=1
	mov	rax, qword ptr [rsp + 48]       # 8-byte Reload
	add	eax, -5
	mov	rcx, rbp
	cmp	eax, 5
	jne	.Lxa_BB0_73
# %bb.68:                               #   in Loop: Header=BB0_2 Depth=1
	xor	eax, eax
	lea	r8, [rip + .Lxa_.str.5]
	.p2align	4, 0x90
.Lxa_BB0_69:                               #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	rax, 5
	je	.Lxa_BB0_70
# %bb.71:                               #   in Loop: Header=BB0_69 Depth=2
	movzx	ecx, byte ptr [rsp + rax + 149]
	lea	rdx, [rax + 1]
	cmp	cl, byte ptr [rax + r8]
	mov	rax, rdx
	je	.Lxa_BB0_69
# %bb.72:                               #   in Loop: Header=BB0_2 Depth=1
	mov	eax, 5
	mov	rcx, rbp
	jmp	.Lxa_BB0_73
.Lxa_BB0_70:                               #   in Loop: Header=BB0_2 Depth=1
	mov	eax, 9
	lea	rcx, [rip + .Lxa_.str.6]
.Lxa_BB0_73:                               #   in Loop: Header=BB0_2 Depth=1
	test	eax, eax
	sete	dl
	lea	r8d, [rax - 61]
	cmp	r8d, -65
	setb	r8b
	or	r8b, dl
	je	.Lxa_BB0_74
.Lxa_BB0_82:                               #   in Loop: Header=BB0_2 Depth=1
	lea	rcx, [rsp + 144]
	mov	rdx, qword ptr [rsp + 48]       # 8-byte Reload
                                        # kill: def $edx killed $edx killed $rdx
	lea	r8, [rip + .Lxa_.str.1]
	call	xt_xa_fail
	jmp	.Lxa_BB0_83
.Lxa_BB0_74:                               #   in Loop: Header=BB0_2 Depth=1
	mov	word ptr [rsp + 80], 17240
	mov	byte ptr [rsp + 82], 95
	mov	edx, eax
	mov	r8, rdx
	neg	r8
	mov	r10b, 1
	mov	r9d, 1
	jmp	.Lxa_BB0_75
	.p2align	4, 0x90
.Lxa_BB0_76:                               #   in Loop: Header=BB0_75 Depth=2
	add	r11b, -32
.Lxa_BB0_79:                               #   in Loop: Header=BB0_75 Depth=2
	lea	r10d, [r9 + 2]
	mov	byte ptr [rsp + r10 + 80], r11b
	cmp	r9, rdx
	setb	r10b
	lea	r11, [r8 + r9]
	inc	r11
	inc	r9
	cmp	r11, 1
	je	.Lxa_BB0_81
.Lxa_BB0_75:                               #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	movzx	r11d, byte ptr [rcx + r9 - 1]
	lea	ebx, [r11 - 97]
	cmp	bl, 25
	jbe	.Lxa_BB0_76
# %bb.77:                               #   in Loop: Header=BB0_75 Depth=2
	lea	ebx, [r11 - 48]
	cmp	bl, 10
	jb	.Lxa_BB0_79
# %bb.78:                               #   in Loop: Header=BB0_75 Depth=2
	cmp	r11b, 45
	mov	r11b, 95
	je	.Lxa_BB0_79
# %bb.80:                               #   in Loop: Header=BB0_2 Depth=1
	test	r10b, 1
	jne	.Lxa_BB0_82
.Lxa_BB0_81:                               #   in Loop: Header=BB0_2 Depth=1
	add	eax, 3
	mov	byte ptr [rsp + rax + 80], 0
.Lxa_BB0_83:                               #   in Loop: Header=BB0_2 Depth=1
	cmp	byte ptr [rsp + 80], 88
	mov	r11d, 1537
	mov	r10, qword ptr [rsp + 56]       # 8-byte Reload
	jne	.Lxa_BB0_88
# %bb.84:                               #   in Loop: Header=BB0_2 Depth=1
	mov	eax, 1
	.p2align	4, 0x90
.Lxa_BB0_86:                               #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	rax, 14
	je	.Lxa_BB0_87
# %bb.85:                               #   in Loop: Header=BB0_86 Depth=2
	movzx	ecx, byte ptr [rsp + rax + 80]
	lea	rdx, [rax + 1]
	lea	r8, [rip + .Lxa_.str.9]
	cmp	cl, byte ptr [rax + r8]
	mov	rax, rdx
	je	.Lxa_BB0_86
	jmp	.Lxa_BB0_88
.Lxa_BB0_87:                               #   in Loop: Header=BB0_2 Depth=1
	lea	rcx, [rsp + 144]
	mov	rdx, qword ptr [rsp + 48]       # 8-byte Reload
                                        # kill: def $edx killed $edx killed $rdx
	lea	r8, [rip + .Lxa_.str.10]
	call	xt_xa_fail
	mov	r10, qword ptr [rsp + 56]       # 8-byte Reload
	mov	r11d, 1537
.Lxa_BB0_88:                               #   in Loop: Header=BB0_2 Depth=1
	lea	rax, [rip + xt_xa_table]
	jmp	.Lxa_BB0_89
.Lxa_BB0_101:                              #   in Loop: Header=BB0_89 Depth=2
	xor	edx, edx
	test	dl, dl
	je	.Lxa_BB0_108
	.p2align	4, 0x90
.Lxa_BB0_89:                               #   Parent Loop BB0_2 Depth=1
                                        # =>  This Loop Header: Depth=2
                                        #       Child Loop BB0_91 Depth 3
                                        #       Child Loop BB0_95 Depth 3
                                        #       Child Loop BB0_103 Depth 3
	movzx	ecx, byte ptr [rax]
	test	cl, cl
	je	.Lxa_BB0_109
# %bb.90:                               #   in Loop: Header=BB0_89 Depth=2
	xor	edx, edx
	jmp	.Lxa_BB0_91
	.p2align	4, 0x90
.Lxa_BB0_93:                               #   in Loop: Header=BB0_91 Depth=3
	inc	edx
.Lxa_BB0_91:                               #   Parent Loop BB0_2 Depth=1
                                        #     Parent Loop BB0_89 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	mov	r8d, edx
	movzx	r9d, byte ptr [rax + r8]
	cmp	r9d, 10
	ja	.Lxa_BB0_93
# %bb.92:                               #   in Loop: Header=BB0_91 Depth=3
	bt	r11d, r9d
	jae	.Lxa_BB0_93
# %bb.94:                               #   in Loop: Header=BB0_89 Depth=2
	xor	r9d, r9d
	test	edx, edx
	je	.Lxa_BB0_99
	.p2align	4, 0x90
.Lxa_BB0_95:                               #   Parent Loop BB0_2 Depth=1
                                        #     Parent Loop BB0_89 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	movzx	r10d, byte ptr [rsp + r9 + 83]
	cmp	r10b, byte ptr [rax + r9]
	jne	.Lxa_BB0_98
# %bb.96:                               #   in Loop: Header=BB0_95 Depth=3
	inc	r9
	cmp	r8, r9
	jne	.Lxa_BB0_95
# %bb.97:                               #   in Loop: Header=BB0_89 Depth=2
	mov	r9d, edx
.Lxa_BB0_98:                               #   in Loop: Header=BB0_89 Depth=2
	mov	r10, qword ptr [rsp + 56]       # 8-byte Reload
.Lxa_BB0_99:                               #   in Loop: Header=BB0_89 Depth=2
	cmp	r9d, edx
	jne	.Lxa_BB0_102
# %bb.100:                              #   in Loop: Header=BB0_89 Depth=2
	cmp	byte ptr [rsp + r8 + 83], 0
	je	.Lxa_BB0_101
.Lxa_BB0_102:                              #   in Loop: Header=BB0_89 Depth=2
	inc	edx
	add	rax, rdx
	mov	edx, 1
	jmp	.Lxa_BB0_103
	.p2align	4, 0x90
.Lxa_BB0_105:                              #   in Loop: Header=BB0_103 Depth=3
	inc	edx
.Lxa_BB0_103:                              #   Parent Loop BB0_2 Depth=1
                                        #     Parent Loop BB0_89 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	lea	r8d, [rdx - 1]
	movzx	r8d, byte ptr [rax + r8]
	cmp	r8d, 10
	ja	.Lxa_BB0_105
# %bb.104:                              #   in Loop: Header=BB0_103 Depth=3
	bt	r11d, r8d
	jae	.Lxa_BB0_105
# %bb.106:                              #   in Loop: Header=BB0_89 Depth=2
	mov	edx, edx
	add	rax, rdx
	mov	dl, 1
	test	dl, dl
	jne	.Lxa_BB0_89
.Lxa_BB0_108:                              #   in Loop: Header=BB0_2 Depth=1
	test	cl, cl
	jne	.Lxa_BB0_110
.Lxa_BB0_109:                              #   in Loop: Header=BB0_2 Depth=1
	lea	rcx, [rsp + 144]
	mov	rdx, qword ptr [rsp + 48]       # 8-byte Reload
                                        # kill: def $edx killed $edx killed $rdx
	lea	r8, [rip + .Lxa_.str.1]
	call	xt_xa_fail
	mov	r10, qword ptr [rsp + 56]       # 8-byte Reload
.Lxa_BB0_110:                              #   in Loop: Header=BB0_2 Depth=1
	movzx	ecx, byte ptr [rsp + 80]
	test	cl, cl
	je	.Lxa_BB0_111
# %bb.112:                              #   in Loop: Header=BB0_2 Depth=1
	mov	eax, 1
	xor	edx, edx
	.p2align	4, 0x90
.Lxa_BB0_113:                              #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	movsx	ecx, cl
	mov	word ptr [rsp + 2*rdx + 272], cx
	mov	edx, eax
	movzx	ecx, byte ptr [rsp + rdx + 80]
	inc	eax
	test	cl, cl
	jne	.Lxa_BB0_113
	jmp	.Lxa_BB0_114
.Lxa_BB0_111:                              #   in Loop: Header=BB0_2 Depth=1
	xor	edx, edx
.Lxa_BB0_114:                              #   in Loop: Header=BB0_2 Depth=1
	mov	word ptr [rsp + 2*rdx + 272], 0
	mov	rax, qword ptr [rsp + 48]       # 8-byte Reload
	cmp	eax, r10d
	mov	eax, eax
	lea	rdx, [r12 + 2*rax]
	lea	rax, [rip + _xt_xcargs.one]
	cmovae	rdx, rax
	lea	rcx, [rsp + 272]
	call	SetEnvironmentVariableW
	mov	rax, qword ptr [rsp + 72]       # 8-byte Reload
	mov	byte ptr [rsp + rax + 432], 1
	mov	eax, 1
	lea	r11, [rip + .Lxa_.str]
	movzx	r8d, byte ptr [rsp + 43]        # 1-byte Folded Reload
	jmp	.Lxa_BB0_115
.Lxa_BB0_117:
	test	eax, eax
	je	.Lxa_BB0_158
# %bb.118:
	movsxd	rax, r15d
	xor	r8d, r8d
	xor	r9d, r9d
	xor	edx, edx
	xor	ecx, ecx
	jmp	.Lxa_BB0_119
	.p2align	4, 0x90
.Lxa_BB0_150:                              #   in Loop: Header=BB0_119 Depth=1
	inc	r8
	mov	edx, r13d
.Lxa_BB0_119:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB0_120 Depth 2
                                        #     Child Loop BB0_124 Depth 2
                                        #     Child Loop BB0_149 Depth 2
	mov	ebx, r9d
	jmp	.Lxa_BB0_120
	.p2align	4, 0x90
.Lxa_BB0_165:                              #   in Loop: Header=BB0_120 Depth=2
	inc	ebx
.Lxa_BB0_120:                              #   Parent Loop BB0_119 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	r10d, ebx
	movzx	r10d, word ptr [rdi + 2*r10]
	cmp	r10d, 9
	je	.Lxa_BB0_165
# %bb.121:                              #   in Loop: Header=BB0_120 Depth=2
	cmp	r10d, 32
	je	.Lxa_BB0_165
# %bb.122:                              #   in Loop: Header=BB0_119 Depth=1
	test	r10d, r10d
	jne	.Lxa_BB0_123
# %bb.129:                              #   in Loop: Header=BB0_119 Depth=1
	mov	r10b, 1
	test	r10b, r10b
	je	.Lxa_BB0_146
	jmp	.Lxa_BB0_131
	.p2align	4, 0x90
.Lxa_BB0_123:                              #   in Loop: Header=BB0_119 Depth=1
	xor	r11d, r11d
	mov	r9d, ebx
	jmp	.Lxa_BB0_124
	.p2align	4, 0x90
.Lxa_BB0_127:                              #   in Loop: Header=BB0_124 Depth=2
	xor	ebx, ebx
	test	r11d, r11d
	sete	bl
	cmp	r10w, 34
	cmove	r11d, ebx
	inc	r9d
	movzx	r10d, word ptr [rdi + 2*r9]
	test	r10w, r10w
	je	.Lxa_BB0_128
.Lxa_BB0_124:                              #   Parent Loop BB0_119 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	test	r11d, r11d
	jne	.Lxa_BB0_127
# %bb.125:                              #   in Loop: Header=BB0_124 Depth=2
	cmp	r10w, 9
	je	.Lxa_BB0_128
# %bb.126:                              #   in Loop: Header=BB0_124 Depth=2
	movzx	ebx, r10w
	cmp	ebx, 32
	jne	.Lxa_BB0_127
.Lxa_BB0_128:                              #   in Loop: Header=BB0_119 Depth=1
	xor	r10d, r10d
	mov	r13d, r9d
	test	r10b, r10b
	jne	.Lxa_BB0_131
.Lxa_BB0_146:                              #   in Loop: Header=BB0_119 Depth=1
	cmp	r8, rax
	jge	.Lxa_BB0_149
# %bb.147:                              #   in Loop: Header=BB0_119 Depth=1
	cmp	byte ptr [rsp + r8 + 432], 0
	je	.Lxa_BB0_149
	jmp	.Lxa_BB0_150
	.p2align	4, 0x90
.Lxa_BB0_148:                              #   in Loop: Header=BB0_149 Depth=2
	mov	r10d, edx
	movzx	r10d, word ptr [rdi + 2*r10]
	mov	r11d, ecx
	inc	ecx
	mov	word ptr [rdi + 2*r11], r10w
	inc	edx
.Lxa_BB0_149:                              #   Parent Loop BB0_119 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	edx, r13d
	jb	.Lxa_BB0_148
	jmp	.Lxa_BB0_150
.Lxa_BB0_131:
	mov	r8d, edx
	movzx	r8d, word ptr [rdi + 2*r8]
	test	r8w, r8w
	je	.Lxa_BB0_134
# %bb.132:
	inc	edx
	.p2align	4, 0x90
.Lxa_BB0_133:                              # =>This Inner Loop Header: Depth=1
	mov	r9d, ecx
	inc	ecx
	mov	word ptr [rdi + 2*r9], r8w
	mov	r8d, edx
	movzx	r8d, word ptr [rdi + 2*r8]
	inc	edx
	test	r8w, r8w
	jne	.Lxa_BB0_133
.Lxa_BB0_134:
	mov	ecx, ecx
	mov	word ptr [rdi + 2*rcx], 0
	test	rsi, rsi
	je	.Lxa_BB0_158
# %bb.135:
	xor	r8d, r8d
	xor	r9d, r9d
	xor	edx, edx
	xor	ecx, ecx
	jmp	.Lxa_BB0_136
	.p2align	4, 0x90
.Lxa_BB0_163:                              #   in Loop: Header=BB0_136 Depth=1
	inc	r8
	mov	edx, r13d
.Lxa_BB0_136:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB0_137 Depth 2
                                        #     Child Loop BB0_141 Depth 2
                                        #     Child Loop BB0_162 Depth 2
	mov	edi, r9d
	jmp	.Lxa_BB0_137
	.p2align	4, 0x90
.Lxa_BB0_151:                              #   in Loop: Header=BB0_137 Depth=2
	inc	edi
.Lxa_BB0_137:                              #   Parent Loop BB0_136 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	r10d, edi
	movzx	r10d, byte ptr [rsi + r10]
	cmp	r10d, 9
	je	.Lxa_BB0_151
# %bb.138:                              #   in Loop: Header=BB0_137 Depth=2
	cmp	r10d, 32
	je	.Lxa_BB0_151
# %bb.139:                              #   in Loop: Header=BB0_136 Depth=1
	test	r10d, r10d
	jne	.Lxa_BB0_140
# %bb.152:                              #   in Loop: Header=BB0_136 Depth=1
	mov	r10b, 1
	test	r10b, r10b
	je	.Lxa_BB0_159
	jmp	.Lxa_BB0_154
	.p2align	4, 0x90
.Lxa_BB0_140:                              #   in Loop: Header=BB0_136 Depth=1
	xor	r11d, r11d
	mov	r9d, edi
	jmp	.Lxa_BB0_141
	.p2align	4, 0x90
.Lxa_BB0_144:                              #   in Loop: Header=BB0_141 Depth=2
	xor	edi, edi
	test	r11d, r11d
	sete	dil
	cmp	r10b, 34
	cmove	r11d, edi
	inc	r9d
	movzx	r10d, byte ptr [rsi + r9]
	test	r10b, r10b
	je	.Lxa_BB0_145
.Lxa_BB0_141:                              #   Parent Loop BB0_136 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	test	r11d, r11d
	jne	.Lxa_BB0_144
# %bb.142:                              #   in Loop: Header=BB0_141 Depth=2
	cmp	r10b, 9
	je	.Lxa_BB0_145
# %bb.143:                              #   in Loop: Header=BB0_141 Depth=2
	movzx	edi, r10b
	cmp	edi, 32
	jne	.Lxa_BB0_144
.Lxa_BB0_145:                              #   in Loop: Header=BB0_136 Depth=1
	xor	r10d, r10d
	mov	r13d, r9d
	test	r10b, r10b
	jne	.Lxa_BB0_154
.Lxa_BB0_159:                              #   in Loop: Header=BB0_136 Depth=1
	cmp	r8, rax
	jge	.Lxa_BB0_162
# %bb.160:                              #   in Loop: Header=BB0_136 Depth=1
	cmp	byte ptr [rsp + r8 + 432], 0
	je	.Lxa_BB0_162
	jmp	.Lxa_BB0_163
	.p2align	4, 0x90
.Lxa_BB0_161:                              #   in Loop: Header=BB0_162 Depth=2
	mov	r10d, edx
	movzx	r10d, byte ptr [rsi + r10]
	mov	r11d, ecx
	inc	ecx
	mov	byte ptr [rsi + r11], r10b
	inc	edx
.Lxa_BB0_162:                              #   Parent Loop BB0_136 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	edx, r13d
	jb	.Lxa_BB0_161
	jmp	.Lxa_BB0_163
.Lxa_BB0_154:
	mov	eax, edx
	movzx	eax, byte ptr [rsi + rax]
	test	al, al
	je	.Lxa_BB0_157
# %bb.155:
	inc	edx
	.p2align	4, 0x90
.Lxa_BB0_156:                              # =>This Inner Loop Header: Depth=1
	mov	r8d, ecx
	inc	ecx
	mov	byte ptr [rsi + r8], al
	mov	eax, edx
	movzx	eax, byte ptr [rsi + rax]
	inc	edx
	test	al, al
	jne	.Lxa_BB0_156
.Lxa_BB0_157:
	mov	eax, ecx
	mov	byte ptr [rsi + rax], 0
.Lxa_BB0_158:
	add	rsp, 2744
	pop	rbx
	pop	rbp
	pop	rdi
	pop	rsi
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	ret
                                        # -- End function
	.def	xt_xa_fail;
	.scl	3;
	.type	32;
	.endef
	.p2align	4, 0x90                         # -- Begin function xt_xa_fail
xt_xa_fail:                             # @xt_xa_fail
# %bb.0:
	push	r14
	push	rsi
	push	rdi
	push	rbx
	sub	rsp, 312
	mov	rdi, r8
	mov	ebx, edx
	mov	r14, rcx
	mov	dword ptr [rsp + 32], 4
	lea	r9, [rip + .Lxa_.str.7]
	lea	rsi, [rsp + 48]
	mov	rcx, rsi
	xor	edx, edx
	mov	r8d, 256
	call	xt_xa_cat
	mov	dword ptr [rsp + 32], ebx
	mov	rcx, rsi
	mov	edx, eax
	mov	r8d, 120
	mov	r9, r14
	call	xt_xa_cat
	mov	dword ptr [rsp + 32], 256
	mov	rcx, rsi
	mov	edx, eax
	mov	r8d, 256
	mov	r9, rdi
	call	xt_xa_cat
	mov	dword ptr [rsp + 32], 1
	lea	r9, [rip + .Lxa_.str.8]
	mov	rcx, rsi
	mov	edx, eax
	mov	r8d, 256
	call	xt_xa_cat
	mov	dword ptr [rsp + 44], 0
	mov	ecx, -12
	call	GetStdHandle
	mov	r8d, -1
	.p2align	4, 0x90
.Lxa_BB1_1:                                # =>This Inner Loop Header: Depth=1
	inc	r8d
	cmp	byte ptr [rsp + r8 + 48], 0
	jne	.Lxa_BB1_1
# %bb.2:
	mov	qword ptr [rsp + 32], 0
	lea	rdx, [rsp + 48]
	lea	r9, [rsp + 44]
	mov	rcx, rax
                                        # kill: def $r8d killed $r8d killed $r8
	call	WriteFile
	mov	ecx, 2
	call	ExitProcess
	add	rsp, 312
	pop	rbx
	pop	rdi
	pop	rsi
	pop	r14
	ret
                                        # -- End function
	.def	xt_xa_cat;
	.scl	3;
	.type	32;
	.endef
	.p2align	4, 0x90                         # -- Begin function xt_xa_cat
xt_xa_cat:                              # @xt_xa_cat
# %bb.0:
	push	rsi
	push	rdi
	push	rbx
	mov	eax, edx
	mov	esi, dword ptr [rsp + 64]
	test	esi, esi
	je	.Lxa_BB2_6
# %bb.1:
	mov	r11d, eax
	mov	edx, r8d
	lea	r10d, [rax + 1]
	cmp	r8d, r10d
	cmova	r10d, r8d
	dec	r10d
	add	eax, esi
	mov	r8d, esi
	xor	esi, esi
	.p2align	4, 0x90
.Lxa_BB2_2:                                # =>This Inner Loop Header: Depth=1
	movzx	ebx, byte ptr [r9 + rsi]
	test	bl, bl
	je	.Lxa_BB2_5
# %bb.3:                                #   in Loop: Header=BB2_2 Depth=1
	lea	rdi, [r11 + 1]
	cmp	rdi, rdx
	jae	.Lxa_BB2_4
# %bb.7:                                #   in Loop: Header=BB2_2 Depth=1
	mov	byte ptr [rcx + r11], bl
	inc	rsi
	mov	r11, rdi
	cmp	r8d, esi
	jne	.Lxa_BB2_2
	jmp	.Lxa_BB2_6
.Lxa_BB2_5:
	mov	eax, r11d
	jmp	.Lxa_BB2_6
.Lxa_BB2_4:
	mov	eax, r10d
.Lxa_BB2_6:
	mov	edx, eax
	mov	byte ptr [rcx + rdx], 0
                                        # kill: def $eax killed $eax killed $rax
	pop	rbx
	pop	rdi
	pop	rsi
	ret
                                        # -- End function
	.section	.rdata,"dr"
	.p2align	1, 0x0                          # @_xt_xcargs.one
_xt_xcargs.one:
	.short	49                              # 0x31
	.short	0                               # 0x0

.Lxa_.str:                                 # @.str
	.asciz	"help"

.Lxa_.str.1:                               # @.str.1
	.asciz	": unknown option (--xc-help lists them)"

.Lxa_.str.2:                               # @.str.2
	.asciz	"Options for the par runtime, taken out of the arguments before main.\nEach sets the variable it names (--xc-par-report is XC_PAR_REPORT=1),\noverriding the environment. Arguments after -- are left alone.\n\n"

	.p2align	4, 0x0                          # @xt_xa_table
xt_xa_table:
	.asciz	"PAR\t=cpu|gpu|gpus|all|auto  where every par block runs\nPAR_THREADS\t=<n>  threads a block on the CPU uses\nPAR_REPORT\t[=2]  print where each block ran and what auto measured\nPAR_FORGET\t  remove what auto learned, so it measures again\nPAR_PROBE\t  measure every worker on a block's first run (also --xc-probe)\nPAR_GPU\t=cuda|vulkan  the GPU interface where both exist\nPAR_VULKAN_DEVICE\t=<n>  the Vulkan device, by index\nPAR_CUDA_DEVICES\t=<n,...>  the CUDA cards that take tiles\nPAR_WORKERS\t=cpu,cuda,metal,vulkan,remote  the devices that share tiles\nPAR_TILES\t=0  run each block in one piece\nPAR_TILE_MB\t=<n>  megabytes a tile moves each way\nPAR_TRACE\t[=<file>|<host:port>]  record each run's tiles\nPAR_PIN\t=0  Linux: leave the CPU threads unpinned\nPAR_REMOTE\t=<host[:port],...>|mdns|none  the xcd daemons to use\nPAR_POOL\t=<name>  find the daemons of that pool by mDNS\nPAR_VERIFY\t=0|all  how many remote tiles are checked on the CPU\nTLS_LIB\t=<file>  the TLS library for connections to daemons\nPAR_VARIANT\t=<name>  test: the kernel variant a device runs\nPAR_VK_FULL\t=0  test: leave out Vulkan's full-dispatch form\nPAR_VULKAN_LOSE\t=<n>  test: the Vulkan device reads as lost after n submits\nPAR_DIE_AFTER\t=<n>  test: drop a remote connection after n tiles\nPAR_MACHINE\t=<name>  test: the machine name a daemon gives\n"

.Lxa_.str.3:                               # @.str.3
	.asciz	"  --xc-"

.Lxa_.str.4:                               # @.str.4
	.asciz	"  --xc-help  this list\n\nXC_PAR_SECRET has no option: a process listing shows the arguments.\n"

.Lxa_.str.5:                               # @.str.5
	.asciz	"probe"

.Lxa_.str.6:                               # @.str.6
	.asciz	"par-probe"

.Lxa_.str.7:                               # @.str.7
	.asciz	"xc: "

.Lxa_.str.8:                               # @.str.8
	.asciz	"\n"

.Lxa_.str.9:                               # @.str.9
	.asciz	"XC_PAR_SECRET"

.Lxa_.str.10:                              # @.str.10
	.asciz	": refused, a process listing shows the arguments; set XC_PAR_SECRET in the environment"

	.addrsig
	.addrsig_sym _xt_xcargs.one
