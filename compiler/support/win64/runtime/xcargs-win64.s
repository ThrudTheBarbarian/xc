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
	je	.Lxa_BB0_167
# %bb.1:
	mov	rsi, rax
	lea	r12, [rsp + 690]
	xor	r15d, r15d
	lea	r11, [rip + .Lxa_.str]
	xor	eax, eax
	xor	r13d, r13d
	mov	dword ptr [rsp + 44], 0         # 4-byte Folded Spill
	xor	r14d, r14d
	jmp	.Lxa_BB0_2
	.p2align	4, 0x90
.Lxa_BB0_22:                               #   in Loop: Header=BB0_2 Depth=1
	inc	r15d
.Lxa_BB0_124:                              #   in Loop: Header=BB0_2 Depth=1
	test	r8b, r8b
	jne	.Lxa_BB0_126
.Lxa_BB0_125:                              #   in Loop: Header=BB0_2 Depth=1
	lea	ecx, [r15 + 1]
	cmp	r15d, 255
	mov	r15d, ecx
	jge	.Lxa_BB0_126
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
                                        #       Child Loop BB0_65 Depth 3
                                        #       Child Loop BB0_69 Depth 3
                                        #       Child Loop BB0_73 Depth 3
                                        #     Child Loop BB0_79 Depth 2
                                        #     Child Loop BB0_85 Depth 2
                                        #     Child Loop BB0_96 Depth 2
                                        #     Child Loop BB0_99 Depth 2
                                        #       Child Loop BB0_101 Depth 3
                                        #       Child Loop BB0_105 Depth 3
                                        #       Child Loop BB0_112 Depth 3
                                        #     Child Loop BB0_122 Depth 2
	mov	ecx, r14d
	jmp	.Lxa_BB0_3
	.p2align	4, 0x90
.Lxa_BB0_173:                              #   in Loop: Header=BB0_3 Depth=2
	inc	ecx
.Lxa_BB0_3:                                #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	edx, ecx
	movzx	edx, word ptr [rdi + 2*rdx]
	cmp	edx, 9
	je	.Lxa_BB0_173
# %bb.4:                                #   in Loop: Header=BB0_3 Depth=2
	cmp	edx, 32
	je	.Lxa_BB0_173
# %bb.5:                                #   in Loop: Header=BB0_2 Depth=1
	test	edx, edx
	jne	.Lxa_BB0_6
# %bb.12:                               #   in Loop: Header=BB0_2 Depth=1
	mov	dl, 1
	test	dl, dl
	je	.Lxa_BB0_14
	jmp	.Lxa_BB0_126
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
	jne	.Lxa_BB0_126
.Lxa_BB0_14:                               #   in Loop: Header=BB0_2 Depth=1
	movsxd	rcx, r15d
	mov	byte ptr [rsp + rcx + 432], 0
	test	ecx, ecx
	jle	.Lxa_BB0_125
# %bb.15:                               #   in Loop: Header=BB0_2 Depth=1
	mov	qword ptr [rsp + 64], rcx       # 8-byte Spill
	xor	ebp, ebp
	cmp	dword ptr [rsp + 44], r13d      # 4-byte Folded Reload
	jae	.Lxa_BB0_21
# %bb.16:                               #   in Loop: Header=BB0_2 Depth=1
	mov	ecx, dword ptr [rsp + 44]       # 4-byte Reload
	mov	edx, r13d
	inc	rcx
	xor	ebp, ebp
	mov	r8d, 1
	.p2align	4, 0x90
.Lxa_BB0_17:                               #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	movzx	r9d, word ptr [rdi + 2*rcx - 2]
	cmp	r9w, 34
	je	.Lxa_BB0_19
# %bb.18:                               #   in Loop: Header=BB0_17 Depth=2
	mov	r10d, ebp
	mov	word ptr [rsp + 2*r10 + 688], r9w
	mov	ebp, r8d
.Lxa_BB0_19:                               #   in Loop: Header=BB0_17 Depth=2
	cmp	rcx, rdx
	jae	.Lxa_BB0_21
# %bb.20:                               #   in Loop: Header=BB0_17 Depth=2
	lea	r8d, [rbp + 1]
	inc	rcx
	cmp	r8d, 1024
	jb	.Lxa_BB0_17
.Lxa_BB0_21:                               #   in Loop: Header=BB0_2 Depth=1
	mov	ecx, ebp
	mov	word ptr [rsp + 2*rcx + 688], 0
	cmp	ebp, 2
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
	cmp	ebp, 5
	jb	.Lxa_BB0_124
# %bb.24:                               #   in Loop: Header=BB0_2 Depth=1
	cmp	dx, 45
	jne	.Lxa_BB0_124
# %bb.25:                               #   in Loop: Header=BB0_2 Depth=1
	cmp	cx, 45
	jne	.Lxa_BB0_124
# %bb.26:                               #   in Loop: Header=BB0_2 Depth=1
	cmp	word ptr [rsp + 692], 120
	jne	.Lxa_BB0_124
# %bb.27:                               #   in Loop: Header=BB0_2 Depth=1
	cmp	word ptr [rsp + 694], 99
	jne	.Lxa_BB0_124
# %bb.28:                               #   in Loop: Header=BB0_2 Depth=1
	cmp	word ptr [rsp + 696], 45
	jne	.Lxa_BB0_124
# %bb.29:                               #   in Loop: Header=BB0_2 Depth=1
	mov	byte ptr [rsp + 43], r8b        # 1-byte Spill
	cmp	ebp, 127
	mov	eax, 127
	cmovb	eax, ebp
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
	jne	.Lxa_BB0_77
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
	jne	.Lxa_BB0_77
.Lxa_BB0_43:                               #   in Loop: Header=BB0_2 Depth=1
	mov	qword ptr [rsp + 56], r15       # 8-byte Spill
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
	lea	r12, [rip + xt_xa_table]
	mov	r9d, 1537
	mov	qword ptr [rsp + 72], rbp       # 8-byte Spill
	jmp	.Lxa_BB0_46
	.p2align	4, 0x90
.Lxa_BB0_62:                               #   in Loop: Header=BB0_46 Depth=2
	test	r8d, r8d
	je	.Lxa_BB0_63
.Lxa_BB0_75:                               #   in Loop: Header=BB0_46 Depth=2
	add	rbx, rbp
	lea	r12, [rbx + 1]
	cmp	byte ptr [rbx + 1], 0
	mov	rbp, qword ptr [rsp + 72]       # 8-byte Reload
	je	.Lxa_BB0_76
.Lxa_BB0_46:                               #   Parent Loop BB0_2 Depth=1
                                        # =>  This Loop Header: Depth=2
                                        #       Child Loop BB0_47 Depth 3
                                        #       Child Loop BB0_51 Depth 3
                                        #       Child Loop BB0_56 Depth 3
                                        #       Child Loop BB0_65 Depth 3
                                        #       Child Loop BB0_69 Depth 3
                                        #       Child Loop BB0_73 Depth 3
	xor	r15d, r15d
	jmp	.Lxa_BB0_47
	.p2align	4, 0x90
.Lxa_BB0_49:                               #   in Loop: Header=BB0_47 Depth=3
	inc	r15d
.Lxa_BB0_47:                               #   Parent Loop BB0_2 Depth=1
                                        #     Parent Loop BB0_46 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	mov	r15d, r15d
	movzx	eax, byte ptr [r12 + r15]
	cmp	eax, 10
	ja	.Lxa_BB0_49
# %bb.48:                               #   in Loop: Header=BB0_47 Depth=3
	bt	r9d, eax
	jae	.Lxa_BB0_49
# %bb.50:                               #   in Loop: Header=BB0_46 Depth=2
	lea	rbx, [r12 + r15]
	inc	rbx
	xor	ebp, ebp
	mov	eax, 1
	jmp	.Lxa_BB0_51
	.p2align	4, 0x90
.Lxa_BB0_53:                               #   in Loop: Header=BB0_51 Depth=3
	inc	ebp
	inc	eax
.Lxa_BB0_51:                               #   Parent Loop BB0_2 Depth=1
                                        #     Parent Loop BB0_46 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	mov	ebp, ebp
	movzx	ecx, byte ptr [rbx + rbp]
	cmp	ecx, 10
	ja	.Lxa_BB0_53
# %bb.52:                               #   in Loop: Header=BB0_51 Depth=3
	bt	r9d, ecx
	jae	.Lxa_BB0_53
# %bb.54:                               #   in Loop: Header=BB0_46 Depth=2
	cmp	ebp, 5
	jae	.Lxa_BB0_55
.Lxa_BB0_63:                               #   in Loop: Header=BB0_46 Depth=2
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
	jne	.Lxa_BB0_66
# %bb.64:                               #   in Loop: Header=BB0_46 Depth=2
	mov	eax, eax
	mov	ecx, 1
	.p2align	4, 0x90
.Lxa_BB0_65:                               #   Parent Loop BB0_2 Depth=1
                                        #     Parent Loop BB0_46 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	movzx	edx, byte ptr [r12 + rcx - 1]
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
	ja	.Lxa_BB0_66
# %bb.175:                              #   in Loop: Header=BB0_65 Depth=3
	lea	rdx, [rcx + 1]
	cmp	rcx, r15
	mov	rcx, rdx
	jb	.Lxa_BB0_65
.Lxa_BB0_66:                               #   in Loop: Header=BB0_46 Depth=2
	mov	ecx, eax
	test	rbp, rbp
	je	.Lxa_BB0_72
# %bb.67:                               #   in Loop: Header=BB0_46 Depth=2
	cmp	eax, 157
	ja	.Lxa_BB0_72
# %bb.68:                               #   in Loop: Header=BB0_46 Depth=2
	add	r12, r15
	mov	eax, 1
	.p2align	4, 0x90
.Lxa_BB0_69:                               #   Parent Loop BB0_2 Depth=1
                                        #     Parent Loop BB0_46 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	mov	rdx, rcx
	movzx	ecx, byte ptr [r12 + rax]
	mov	byte ptr [rsp + rdx + 272], cl
	lea	rcx, [rdx + 1]
	cmp	rdx, 156
	ja	.Lxa_BB0_71
# %bb.70:                               #   in Loop: Header=BB0_69 Depth=3
	lea	rdx, [rax + 1]
	cmp	rax, rbp
	mov	rax, rdx
	jb	.Lxa_BB0_69
.Lxa_BB0_71:                               #   in Loop: Header=BB0_46 Depth=2
	mov	eax, ecx
.Lxa_BB0_72:                               #   in Loop: Header=BB0_46 Depth=2
	mov	eax, eax
	mov	byte ptr [rsp + rcx + 272], 10
	lea	rcx, [rsp + 272]
	mov	byte ptr [rax + rcx + 1], 0
	mov	dword ptr [rsp + 80], 0
	mov	ecx, -11
	call	GetStdHandle
	mov	r8d, -1
	.p2align	4, 0x90
.Lxa_BB0_73:                               #   Parent Loop BB0_2 Depth=1
                                        #     Parent Loop BB0_46 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	inc	r8d
	cmp	byte ptr [rsp + r8 + 272], 0
	jne	.Lxa_BB0_73
# %bb.74:                               #   in Loop: Header=BB0_46 Depth=2
	mov	qword ptr [rsp + 32], 0
	mov	rcx, rax
	lea	rdx, [rsp + 272]
                                        # kill: def $r8d killed $r8d killed $r8
	lea	r9, [rsp + 80]
	call	WriteFile
	mov	r9d, 1537
	jmp	.Lxa_BB0_75
	.p2align	4, 0x90
.Lxa_BB0_55:                               #   in Loop: Header=BB0_46 Depth=2
	cmp	eax, 7
	mov	ecx, 6
	cmovb	eax, ecx
	add	eax, -5
	lea	rcx, [r12 + r15]
	add	rcx, 5
	xor	edx, edx
	xor	r8d, r8d
	jmp	.Lxa_BB0_56
	.p2align	4, 0x90
.Lxa_BB0_61:                               #   in Loop: Header=BB0_56 Depth=3
	inc	rdx
	cmp	rax, rdx
	je	.Lxa_BB0_62
.Lxa_BB0_56:                               #   Parent Loop BB0_2 Depth=1
                                        #     Parent Loop BB0_46 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	cmp	byte ptr [rcx + rdx - 4], 116
	jne	.Lxa_BB0_61
# %bb.57:                               #   in Loop: Header=BB0_56 Depth=3
	cmp	byte ptr [rcx + rdx - 3], 101
	jne	.Lxa_BB0_61
# %bb.58:                               #   in Loop: Header=BB0_56 Depth=3
	cmp	byte ptr [rcx + rdx - 2], 115
	jne	.Lxa_BB0_61
# %bb.59:                               #   in Loop: Header=BB0_56 Depth=3
	cmp	byte ptr [rcx + rdx - 1], 116
	jne	.Lxa_BB0_61
# %bb.60:                               #   in Loop: Header=BB0_56 Depth=3
	cmp	byte ptr [rcx + rdx], 58
	mov	r10d, 1
	cmove	r8d, r10d
	jmp	.Lxa_BB0_61
.Lxa_BB0_76:                               #   in Loop: Header=BB0_2 Depth=1
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
	mov	r15, qword ptr [rsp + 56]       # 8-byte Reload
	lea	r12, [rsp + 690]
.Lxa_BB0_77:                               #   in Loop: Header=BB0_2 Depth=1
	mov	rax, qword ptr [rsp + 48]       # 8-byte Reload
	add	eax, -5
	lea	rcx, [rsp + 149]
	cmp	eax, 5
	jne	.Lxa_BB0_83
# %bb.78:                               #   in Loop: Header=BB0_2 Depth=1
	xor	eax, eax
	lea	r8, [rip + .Lxa_.str.5]
	.p2align	4, 0x90
.Lxa_BB0_79:                               #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	rax, 5
	je	.Lxa_BB0_80
# %bb.81:                               #   in Loop: Header=BB0_79 Depth=2
	movzx	ecx, byte ptr [rsp + rax + 149]
	lea	rdx, [rax + 1]
	cmp	cl, byte ptr [rax + r8]
	mov	rax, rdx
	je	.Lxa_BB0_79
# %bb.82:                               #   in Loop: Header=BB0_2 Depth=1
	mov	eax, 5
	lea	rcx, [rsp + 149]
	jmp	.Lxa_BB0_83
.Lxa_BB0_80:                               #   in Loop: Header=BB0_2 Depth=1
	mov	eax, 9
	lea	rcx, [rip + .Lxa_.str.6]
.Lxa_BB0_83:                               #   in Loop: Header=BB0_2 Depth=1
	test	eax, eax
	sete	dl
	lea	r8d, [rax - 61]
	cmp	r8d, -65
	setb	r8b
	or	r8b, dl
	je	.Lxa_BB0_84
.Lxa_BB0_92:                               #   in Loop: Header=BB0_2 Depth=1
	lea	rcx, [rsp + 144]
	mov	rdx, qword ptr [rsp + 48]       # 8-byte Reload
                                        # kill: def $edx killed $edx killed $rdx
	lea	r8, [rip + .Lxa_.str.1]
	call	xt_xa_fail
	jmp	.Lxa_BB0_93
.Lxa_BB0_84:                               #   in Loop: Header=BB0_2 Depth=1
	mov	word ptr [rsp + 80], 17240
	mov	byte ptr [rsp + 82], 95
	mov	edx, eax
	mov	r8, rdx
	neg	r8
	mov	r10b, 1
	mov	r9d, 1
	jmp	.Lxa_BB0_85
	.p2align	4, 0x90
.Lxa_BB0_86:                               #   in Loop: Header=BB0_85 Depth=2
	add	r11b, -32
.Lxa_BB0_89:                               #   in Loop: Header=BB0_85 Depth=2
	lea	r10d, [r9 + 2]
	mov	byte ptr [rsp + r10 + 80], r11b
	cmp	r9, rdx
	setb	r10b
	lea	r11, [r8 + r9]
	inc	r11
	inc	r9
	cmp	r11, 1
	je	.Lxa_BB0_91
.Lxa_BB0_85:                               #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	movzx	r11d, byte ptr [rcx + r9 - 1]
	lea	ebx, [r11 - 97]
	cmp	bl, 25
	jbe	.Lxa_BB0_86
# %bb.87:                               #   in Loop: Header=BB0_85 Depth=2
	lea	ebx, [r11 - 48]
	cmp	bl, 10
	jb	.Lxa_BB0_89
# %bb.88:                               #   in Loop: Header=BB0_85 Depth=2
	cmp	r11b, 45
	mov	r11b, 95
	je	.Lxa_BB0_89
# %bb.90:                               #   in Loop: Header=BB0_2 Depth=1
	test	r10b, 1
	jne	.Lxa_BB0_92
.Lxa_BB0_91:                               #   in Loop: Header=BB0_2 Depth=1
	add	eax, 3
	mov	byte ptr [rsp + rax + 80], 0
.Lxa_BB0_93:                               #   in Loop: Header=BB0_2 Depth=1
	cmp	byte ptr [rsp + 80], 88
	mov	r11d, 1537
	jne	.Lxa_BB0_98
# %bb.94:                               #   in Loop: Header=BB0_2 Depth=1
	mov	eax, 1
	.p2align	4, 0x90
.Lxa_BB0_96:                               #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	rax, 14
	je	.Lxa_BB0_97
# %bb.95:                               #   in Loop: Header=BB0_96 Depth=2
	movzx	ecx, byte ptr [rsp + rax + 80]
	lea	rdx, [rax + 1]
	lea	r8, [rip + .Lxa_.str.9]
	cmp	cl, byte ptr [rax + r8]
	mov	rax, rdx
	je	.Lxa_BB0_96
	jmp	.Lxa_BB0_98
.Lxa_BB0_97:                               #   in Loop: Header=BB0_2 Depth=1
	lea	rcx, [rsp + 144]
	mov	rdx, qword ptr [rsp + 48]       # 8-byte Reload
                                        # kill: def $edx killed $edx killed $rdx
	lea	r8, [rip + .Lxa_.str.10]
	call	xt_xa_fail
	mov	r11d, 1537
.Lxa_BB0_98:                               #   in Loop: Header=BB0_2 Depth=1
	lea	rax, [rip + xt_xa_table]
	jmp	.Lxa_BB0_99
.Lxa_BB0_110:                              #   in Loop: Header=BB0_99 Depth=2
	xor	edx, edx
	test	dl, dl
	je	.Lxa_BB0_117
	.p2align	4, 0x90
.Lxa_BB0_99:                               #   Parent Loop BB0_2 Depth=1
                                        # =>  This Loop Header: Depth=2
                                        #       Child Loop BB0_101 Depth 3
                                        #       Child Loop BB0_105 Depth 3
                                        #       Child Loop BB0_112 Depth 3
	movzx	ecx, byte ptr [rax]
	test	cl, cl
	je	.Lxa_BB0_118
# %bb.100:                              #   in Loop: Header=BB0_99 Depth=2
	xor	edx, edx
	jmp	.Lxa_BB0_101
	.p2align	4, 0x90
.Lxa_BB0_103:                              #   in Loop: Header=BB0_101 Depth=3
	inc	edx
.Lxa_BB0_101:                              #   Parent Loop BB0_2 Depth=1
                                        #     Parent Loop BB0_99 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	mov	r8d, edx
	movzx	r9d, byte ptr [rax + r8]
	cmp	r9d, 10
	ja	.Lxa_BB0_103
# %bb.102:                              #   in Loop: Header=BB0_101 Depth=3
	bt	r11d, r9d
	jae	.Lxa_BB0_103
# %bb.104:                              #   in Loop: Header=BB0_99 Depth=2
	xor	r9d, r9d
	test	edx, edx
	je	.Lxa_BB0_108
	.p2align	4, 0x90
.Lxa_BB0_105:                              #   Parent Loop BB0_2 Depth=1
                                        #     Parent Loop BB0_99 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	movzx	r10d, byte ptr [rsp + r9 + 83]
	cmp	r10b, byte ptr [rax + r9]
	jne	.Lxa_BB0_108
# %bb.106:                              #   in Loop: Header=BB0_105 Depth=3
	inc	r9
	cmp	r8, r9
	jne	.Lxa_BB0_105
# %bb.107:                              #   in Loop: Header=BB0_99 Depth=2
	mov	r9d, edx
.Lxa_BB0_108:                              #   in Loop: Header=BB0_99 Depth=2
	cmp	r9d, edx
	jne	.Lxa_BB0_111
# %bb.109:                              #   in Loop: Header=BB0_99 Depth=2
	cmp	byte ptr [rsp + r8 + 83], 0
	je	.Lxa_BB0_110
.Lxa_BB0_111:                              #   in Loop: Header=BB0_99 Depth=2
	inc	edx
	add	rax, rdx
	mov	edx, 1
	jmp	.Lxa_BB0_112
	.p2align	4, 0x90
.Lxa_BB0_114:                              #   in Loop: Header=BB0_112 Depth=3
	inc	edx
.Lxa_BB0_112:                              #   Parent Loop BB0_2 Depth=1
                                        #     Parent Loop BB0_99 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	lea	r8d, [rdx - 1]
	movzx	r8d, byte ptr [rax + r8]
	cmp	r8d, 10
	ja	.Lxa_BB0_114
# %bb.113:                              #   in Loop: Header=BB0_112 Depth=3
	bt	r11d, r8d
	jae	.Lxa_BB0_114
# %bb.115:                              #   in Loop: Header=BB0_99 Depth=2
	mov	edx, edx
	add	rax, rdx
	mov	dl, 1
	test	dl, dl
	jne	.Lxa_BB0_99
.Lxa_BB0_117:                              #   in Loop: Header=BB0_2 Depth=1
	test	cl, cl
	jne	.Lxa_BB0_119
.Lxa_BB0_118:                              #   in Loop: Header=BB0_2 Depth=1
	lea	rcx, [rsp + 144]
	mov	rdx, qword ptr [rsp + 48]       # 8-byte Reload
                                        # kill: def $edx killed $edx killed $rdx
	lea	r8, [rip + .Lxa_.str.1]
	call	xt_xa_fail
.Lxa_BB0_119:                              #   in Loop: Header=BB0_2 Depth=1
	movzx	ecx, byte ptr [rsp + 80]
	test	cl, cl
	je	.Lxa_BB0_120
# %bb.121:                              #   in Loop: Header=BB0_2 Depth=1
	mov	eax, 1
	xor	edx, edx
	.p2align	4, 0x90
.Lxa_BB0_122:                              #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	movsx	ecx, cl
	mov	word ptr [rsp + 2*rdx + 272], cx
	mov	edx, eax
	movzx	ecx, byte ptr [rsp + rdx + 80]
	inc	eax
	test	cl, cl
	jne	.Lxa_BB0_122
	jmp	.Lxa_BB0_123
.Lxa_BB0_120:                              #   in Loop: Header=BB0_2 Depth=1
	xor	edx, edx
.Lxa_BB0_123:                              #   in Loop: Header=BB0_2 Depth=1
	mov	word ptr [rsp + 2*rdx + 272], 0
	mov	rax, qword ptr [rsp + 48]       # 8-byte Reload
	cmp	eax, ebp
	mov	eax, eax
	lea	rdx, [r12 + 2*rax]
	lea	rax, [rip + _xt_xcargs.one]
	cmovae	rdx, rax
	lea	rcx, [rsp + 272]
	call	SetEnvironmentVariableW
	mov	rax, qword ptr [rsp + 64]       # 8-byte Reload
	mov	byte ptr [rsp + rax + 432], 1
	mov	eax, 1
	lea	r11, [rip + .Lxa_.str]
	movzx	r8d, byte ptr [rsp + 43]        # 1-byte Folded Reload
	jmp	.Lxa_BB0_124
.Lxa_BB0_126:
	test	eax, eax
	je	.Lxa_BB0_167
# %bb.127:
	movsxd	rax, r15d
	xor	r8d, r8d
	xor	r9d, r9d
	xor	edx, edx
	xor	ecx, ecx
	jmp	.Lxa_BB0_128
	.p2align	4, 0x90
.Lxa_BB0_159:                              #   in Loop: Header=BB0_128 Depth=1
	inc	r8
	mov	edx, r13d
.Lxa_BB0_128:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB0_129 Depth 2
                                        #     Child Loop BB0_133 Depth 2
                                        #     Child Loop BB0_158 Depth 2
	mov	ebx, r9d
	jmp	.Lxa_BB0_129
	.p2align	4, 0x90
.Lxa_BB0_174:                              #   in Loop: Header=BB0_129 Depth=2
	inc	ebx
.Lxa_BB0_129:                              #   Parent Loop BB0_128 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	r10d, ebx
	movzx	r10d, word ptr [rdi + 2*r10]
	cmp	r10d, 9
	je	.Lxa_BB0_174
# %bb.130:                              #   in Loop: Header=BB0_129 Depth=2
	cmp	r10d, 32
	je	.Lxa_BB0_174
# %bb.131:                              #   in Loop: Header=BB0_128 Depth=1
	test	r10d, r10d
	jne	.Lxa_BB0_132
# %bb.138:                              #   in Loop: Header=BB0_128 Depth=1
	mov	r10b, 1
	test	r10b, r10b
	je	.Lxa_BB0_155
	jmp	.Lxa_BB0_140
	.p2align	4, 0x90
.Lxa_BB0_132:                              #   in Loop: Header=BB0_128 Depth=1
	xor	r11d, r11d
	mov	r9d, ebx
	jmp	.Lxa_BB0_133
	.p2align	4, 0x90
.Lxa_BB0_136:                              #   in Loop: Header=BB0_133 Depth=2
	xor	ebx, ebx
	test	r11d, r11d
	sete	bl
	cmp	r10w, 34
	cmove	r11d, ebx
	inc	r9d
	movzx	r10d, word ptr [rdi + 2*r9]
	test	r10w, r10w
	je	.Lxa_BB0_137
.Lxa_BB0_133:                              #   Parent Loop BB0_128 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	test	r11d, r11d
	jne	.Lxa_BB0_136
# %bb.134:                              #   in Loop: Header=BB0_133 Depth=2
	cmp	r10w, 9
	je	.Lxa_BB0_137
# %bb.135:                              #   in Loop: Header=BB0_133 Depth=2
	movzx	ebx, r10w
	cmp	ebx, 32
	jne	.Lxa_BB0_136
.Lxa_BB0_137:                              #   in Loop: Header=BB0_128 Depth=1
	xor	r10d, r10d
	mov	r13d, r9d
	test	r10b, r10b
	jne	.Lxa_BB0_140
.Lxa_BB0_155:                              #   in Loop: Header=BB0_128 Depth=1
	cmp	r8, rax
	jge	.Lxa_BB0_158
# %bb.156:                              #   in Loop: Header=BB0_128 Depth=1
	cmp	byte ptr [rsp + r8 + 432], 0
	je	.Lxa_BB0_158
	jmp	.Lxa_BB0_159
	.p2align	4, 0x90
.Lxa_BB0_157:                              #   in Loop: Header=BB0_158 Depth=2
	mov	r10d, edx
	movzx	r10d, word ptr [rdi + 2*r10]
	mov	r11d, ecx
	inc	ecx
	mov	word ptr [rdi + 2*r11], r10w
	inc	edx
.Lxa_BB0_158:                              #   Parent Loop BB0_128 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	edx, r13d
	jb	.Lxa_BB0_157
	jmp	.Lxa_BB0_159
.Lxa_BB0_140:
	mov	r8d, edx
	movzx	r8d, word ptr [rdi + 2*r8]
	test	r8w, r8w
	je	.Lxa_BB0_143
# %bb.141:
	inc	edx
	.p2align	4, 0x90
.Lxa_BB0_142:                              # =>This Inner Loop Header: Depth=1
	mov	r9d, ecx
	inc	ecx
	mov	word ptr [rdi + 2*r9], r8w
	mov	r8d, edx
	movzx	r8d, word ptr [rdi + 2*r8]
	inc	edx
	test	r8w, r8w
	jne	.Lxa_BB0_142
.Lxa_BB0_143:
	mov	ecx, ecx
	mov	word ptr [rdi + 2*rcx], 0
	test	rsi, rsi
	je	.Lxa_BB0_167
# %bb.144:
	xor	r8d, r8d
	xor	r9d, r9d
	xor	edx, edx
	xor	ecx, ecx
	jmp	.Lxa_BB0_145
	.p2align	4, 0x90
.Lxa_BB0_172:                              #   in Loop: Header=BB0_145 Depth=1
	inc	r8
	mov	edx, r13d
.Lxa_BB0_145:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB0_146 Depth 2
                                        #     Child Loop BB0_150 Depth 2
                                        #     Child Loop BB0_171 Depth 2
	mov	edi, r9d
	jmp	.Lxa_BB0_146
	.p2align	4, 0x90
.Lxa_BB0_160:                              #   in Loop: Header=BB0_146 Depth=2
	inc	edi
.Lxa_BB0_146:                              #   Parent Loop BB0_145 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	r10d, edi
	movzx	r10d, byte ptr [rsi + r10]
	cmp	r10d, 9
	je	.Lxa_BB0_160
# %bb.147:                              #   in Loop: Header=BB0_146 Depth=2
	cmp	r10d, 32
	je	.Lxa_BB0_160
# %bb.148:                              #   in Loop: Header=BB0_145 Depth=1
	test	r10d, r10d
	jne	.Lxa_BB0_149
# %bb.161:                              #   in Loop: Header=BB0_145 Depth=1
	mov	r10b, 1
	test	r10b, r10b
	je	.Lxa_BB0_168
	jmp	.Lxa_BB0_163
	.p2align	4, 0x90
.Lxa_BB0_149:                              #   in Loop: Header=BB0_145 Depth=1
	xor	r11d, r11d
	mov	r9d, edi
	jmp	.Lxa_BB0_150
	.p2align	4, 0x90
.Lxa_BB0_153:                              #   in Loop: Header=BB0_150 Depth=2
	xor	edi, edi
	test	r11d, r11d
	sete	dil
	cmp	r10b, 34
	cmove	r11d, edi
	inc	r9d
	movzx	r10d, byte ptr [rsi + r9]
	test	r10b, r10b
	je	.Lxa_BB0_154
.Lxa_BB0_150:                              #   Parent Loop BB0_145 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	test	r11d, r11d
	jne	.Lxa_BB0_153
# %bb.151:                              #   in Loop: Header=BB0_150 Depth=2
	cmp	r10b, 9
	je	.Lxa_BB0_154
# %bb.152:                              #   in Loop: Header=BB0_150 Depth=2
	movzx	edi, r10b
	cmp	edi, 32
	jne	.Lxa_BB0_153
.Lxa_BB0_154:                              #   in Loop: Header=BB0_145 Depth=1
	xor	r10d, r10d
	mov	r13d, r9d
	test	r10b, r10b
	jne	.Lxa_BB0_163
.Lxa_BB0_168:                              #   in Loop: Header=BB0_145 Depth=1
	cmp	r8, rax
	jge	.Lxa_BB0_171
# %bb.169:                              #   in Loop: Header=BB0_145 Depth=1
	cmp	byte ptr [rsp + r8 + 432], 0
	je	.Lxa_BB0_171
	jmp	.Lxa_BB0_172
	.p2align	4, 0x90
.Lxa_BB0_170:                              #   in Loop: Header=BB0_171 Depth=2
	mov	r10d, edx
	movzx	r10d, byte ptr [rsi + r10]
	mov	r11d, ecx
	inc	ecx
	mov	byte ptr [rsi + r11], r10b
	inc	edx
.Lxa_BB0_171:                              #   Parent Loop BB0_145 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	edx, r13d
	jb	.Lxa_BB0_170
	jmp	.Lxa_BB0_172
.Lxa_BB0_163:
	mov	eax, edx
	movzx	eax, byte ptr [rsi + rax]
	test	al, al
	je	.Lxa_BB0_166
# %bb.164:
	inc	edx
	.p2align	4, 0x90
.Lxa_BB0_165:                              # =>This Inner Loop Header: Depth=1
	mov	r8d, ecx
	inc	ecx
	mov	byte ptr [rsi + r8], al
	mov	eax, edx
	movzx	eax, byte ptr [rsi + rax]
	inc	edx
	test	al, al
	jne	.Lxa_BB0_165
.Lxa_BB0_166:
	mov	eax, ecx
	mov	byte ptr [rsi + rax], 0
.Lxa_BB0_167:
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
	.asciz	"PAR\t=cpu|gpu|gpus|all|auto  where every par block runs\nPAR_THREADS\t=<n>  threads a block on the CPU uses\nPAR_REPORT\t[=2]  print where each block ran and what auto measured\nPAR_FORGET\t  remove what auto learned, so it measures again\nPAR_PROBE\t  measure every block to the end on its first run (also --xc-probe)\nPAR_GPU\t=cuda|vulkan  the GPU interface where both exist\nPAR_VULKAN_DEVICE\t=<n>  the Vulkan device, by index\nPAR_CUDA_DEVICES\t=<n,...>  the CUDA cards that take tiles\nPAR_WORKERS\t=cpu,cuda,metal,vulkan,remote  the devices that share tiles\nPAR_TILES\t=0  run each block in one piece\nPAR_TILE_MB\t=<n>  megabytes a tile moves each way\nPAR_TRACE\t[=<file>|<host:port>]  record each run's tiles\nPAR_PIN\t=0  Linux: leave the CPU threads unpinned\nPAR_REMOTE\t=<host[:port],...>|mdns|none  the xcd daemons to use\nPAR_POOL\t=<name>  find the daemons of that pool by mDNS\nPAR_VERIFY\t=0|all  how many remote tiles are checked on the CPU\nTLS_LIB\t=<file>  the TLS library for connections to daemons\nPAR_VARIANT\t=<name>  test: the kernel variant a device runs\nPAR_VK_FULL\t=0  test: leave out Vulkan's full-dispatch form\nPAR_VULKAN_LOSE\t=<n>  test: the Vulkan device reads as lost after n submits\nPAR_DIE_AFTER\t=<n>  test: drop a remote connection after n tiles\nPAR_MACHINE\t=<name>  test: the machine name a daemon gives\n"

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
