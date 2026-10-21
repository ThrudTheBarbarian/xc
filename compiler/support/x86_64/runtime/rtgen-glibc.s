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

# rtgen-glibc.s — GENERATED from src/xtc/support-src/rt-freestanding.c by the
# glibc recipe at the top of that file (Apple clang version 17.0.0), for
# `xcc -A x86_64 -dynamic`. No hand-applied pieces: regenerate and keep this header.
// regenerated with: Apple clang version 17.0.0 (clang-1700.3.19.1)
	.text
	.intel_syntax noprefix
	.file	"rt-freestanding.c"
                                        # Start of file scope inline assembly
	.globl	xt_sigrestore
	.type	xt_sigrestore,@function
xt_sigrestore:
	mov	eax, 15
	syscall

                                        # End of file scope inline assembly
	.globl	_sys_read                       # -- Begin function _sys_read
	.p2align	4, 0x90
	.type	_sys_read,@function
_sys_read:                              # @_sys_read
# %bb.0:
	push	rax
                                        # kill: def $edi killed $edi killed $rdi
	call	read@PLT
	test	rax, rax
	js	.LBB0_1
# %bb.2:
	pop	rcx
	ret
.LBB0_1:
	call	__errno_location@PLT
	movsxd	rax, dword ptr [rax]
	neg	rax
	pop	rcx
	ret
.Lfunc_end0:
	.size	_sys_read, .Lfunc_end0-_sys_read
                                        # -- End function
	.globl	_sys_open                       # -- Begin function _sys_open
	.p2align	4, 0x90
	.type	_sys_open,@function
_sys_open:                              # @_sys_open
# %bb.0:
	push	rax
                                        # kill: def $esi killed $esi killed $rsi
                                        # kill: def $edx killed $edx killed $rdx
	xor	eax, eax
	call	open@PLT
	test	eax, eax
	js	.LBB1_2
# %bb.1:
	cdqe
	pop	rcx
	ret
.LBB1_2:
	call	__errno_location@PLT
	movsxd	rax, dword ptr [rax]
	neg	rax
	pop	rcx
	ret
.Lfunc_end1:
	.size	_sys_open, .Lfunc_end1-_sys_open
                                        # -- End function
	.globl	_sys_close                      # -- Begin function _sys_close
	.p2align	4, 0x90
	.type	_sys_close,@function
_sys_close:                             # @_sys_close
# %bb.0:
	push	rax
                                        # kill: def $edi killed $edi killed $rdi
	call	close@PLT
	test	eax, eax
	js	.LBB2_2
# %bb.1:
	cdqe
	pop	rcx
	ret
.LBB2_2:
	call	__errno_location@PLT
	movsxd	rax, dword ptr [rax]
	neg	rax
	pop	rcx
	ret
.Lfunc_end2:
	.size	_sys_close, .Lfunc_end2-_sys_close
                                        # -- End function
	.globl	_sys_lseek                      # -- Begin function _sys_lseek
	.p2align	4, 0x90
	.type	_sys_lseek,@function
_sys_lseek:                             # @_sys_lseek
# %bb.0:
	push	rax
                                        # kill: def $edi killed $edi killed $rdi
                                        # kill: def $edx killed $edx killed $rdx
	call	lseek@PLT
	test	rax, rax
	js	.LBB3_1
# %bb.2:
	pop	rcx
	ret
.LBB3_1:
	call	__errno_location@PLT
	movsxd	rax, dword ptr [rax]
	neg	rax
	pop	rcx
	ret
.Lfunc_end3:
	.size	_sys_lseek, .Lfunc_end3-_sys_lseek
                                        # -- End function
	.globl	_sys_mkdir                      # -- Begin function _sys_mkdir
	.p2align	4, 0x90
	.type	_sys_mkdir,@function
_sys_mkdir:                             # @_sys_mkdir
# %bb.0:
	push	rax
                                        # kill: def $esi killed $esi killed $rsi
	call	mkdir@PLT
	test	eax, eax
	js	.LBB4_2
# %bb.1:
	cdqe
	pop	rcx
	ret
.LBB4_2:
	call	__errno_location@PLT
	movsxd	rax, dword ptr [rax]
	neg	rax
	pop	rcx
	ret
.Lfunc_end4:
	.size	_sys_mkdir, .Lfunc_end4-_sys_mkdir
                                        # -- End function
	.globl	_sys_chmod                      # -- Begin function _sys_chmod
	.p2align	4, 0x90
	.type	_sys_chmod,@function
_sys_chmod:                             # @_sys_chmod
# %bb.0:
	push	rax
                                        # kill: def $esi killed $esi killed $rsi
	call	chmod@PLT
	test	eax, eax
	js	.LBB5_2
# %bb.1:
	cdqe
	pop	rcx
	ret
.LBB5_2:
	call	__errno_location@PLT
	movsxd	rax, dword ptr [rax]
	neg	rax
	pop	rcx
	ret
.Lfunc_end5:
	.size	_sys_chmod, .Lfunc_end5-_sys_chmod
                                        # -- End function
	.globl	_sys_exit                       # -- Begin function _sys_exit
	.p2align	4, 0x90
	.type	_sys_exit,@function
_sys_exit:                              # @_sys_exit
# %bb.0:
	push	rax
                                        # kill: def $edi killed $edi killed $rdi
	call	exit@PLT
.Lfunc_end6:
	.size	_sys_exit, .Lfunc_end6-_sys_exit
                                        # -- End function
	.globl	_xt_getenv                      # -- Begin function _xt_getenv
	.p2align	4, 0x90
	.type	_xt_getenv,@function
_xt_getenv:                             # @_xt_getenv
# %bb.0:
	test	rdi, rdi
	je	.LBB7_1
# %bb.2:
	push	rax
	call	getenv@PLT
	add	rsp, 8
	jmp	.LBB7_3
.LBB7_1:
	xor	eax, eax
.LBB7_3:
	test	rax, rax
	lea	rcx, [rip + xt_empty]
	cmovne	rcx, rax
	mov	rax, rcx
	ret
.Lfunc_end7:
	.size	_xt_getenv, .Lfunc_end7-_xt_getenv
                                        # -- End function
	.globl	_xt_calloc                      # -- Begin function _xt_calloc
	.p2align	4, 0x90
	.type	_xt_calloc,@function
_xt_calloc:                             # @_xt_calloc
# %bb.0:
	push	r14
	push	rbx
	push	rax
	lea	rsi, [rdi + 8]
	cmp	rsi, 1025
	jb	.LBB8_3
# %bb.1:
	mov	edi, 1
	call	calloc@PLT
	test	rax, rax
	je	.LBB8_15
# %bb.2:
	mov	qword ptr [rax], 64
	add	rax, 8
	jmp	.LBB8_16
.LBB8_3:
	mov	rbx, rdi
	add	rdi, 23
	mov	r14, rdi
	shr	r14, 4
	mov	rcx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rcx], 0
	je	.LBB8_6
	.p2align	4, 0x90
.LBB8_4:                                # =>This Loop Header: Depth=1
                                        #     Child Loop BB8_5 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB8_6
.LBB8_5:                                #   Parent Loop BB8_4 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB8_5
	jmp	.LBB8_4
.LBB8_6:
	lea	rdx, [rip + xt_cache]
	mov	rax, qword ptr [rdx + 8*r14 - 8]
	test	rax, rax
	je	.LBB8_10
# %bb.7:
	mov	rsi, qword ptr [rax]
	lea	rdi, [rip + xt_cache_n]
	dec	dword ptr [rdi + 4*r14 - 4]
	mov	qword ptr [rdx + 8*r14 - 8], rsi
	cmp	dword ptr [rcx], 0
	je	.LBB8_13
# %bb.8:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB8_13
.LBB8_10:
	and	rdi, -16
	cmp	dword ptr [rcx], 0
	je	.LBB8_12
# %bb.11:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB8_12:
	call	malloc@PLT
	test	rax, rax
	je	.LBB8_15
.LBB8_13:
	dec	r14
	mov	qword ptr [rax], r14
	add	rax, 8
	test	rbx, rbx
	je	.LBB8_16
# %bb.14:
	mov	rdi, rax
	xor	esi, esi
	mov	rdx, rbx
	add	rsp, 8
	pop	rbx
	pop	r14
	jmp	memset@PLT                      # TAILCALL
.LBB8_15:
	xor	eax, eax
.LBB8_16:
	add	rsp, 8
	pop	rbx
	pop	r14
	ret
.Lfunc_end8:
	.size	_xt_calloc, .Lfunc_end8-_xt_calloc
                                        # -- End function
	.globl	_xt_alloc_lock                  # -- Begin function _xt_alloc_lock
	.p2align	4, 0x90
	.type	_xt_alloc_lock,@function
_xt_alloc_lock:                         # @_xt_alloc_lock
# %bb.0:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB9_3
	.p2align	4, 0x90
.LBB9_1:                                # =>This Loop Header: Depth=1
                                        #     Child Loop BB9_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB9_3
.LBB9_2:                                #   Parent Loop BB9_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB9_2
	jmp	.LBB9_1
.LBB9_3:
	ret
.Lfunc_end9:
	.size	_xt_alloc_lock, .Lfunc_end9-_xt_alloc_lock
                                        # -- End function
	.globl	_xt_alloc_unlock                # -- Begin function _xt_alloc_unlock
	.p2align	4, 0x90
	.type	_xt_alloc_unlock,@function
_xt_alloc_unlock:                       # @_xt_alloc_unlock
# %bb.0:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB10_2
# %bb.1:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB10_2:
	ret
.Lfunc_end10:
	.size	_xt_alloc_unlock, .Lfunc_end10-_xt_alloc_unlock
                                        # -- End function
	.globl	_xt_free                        # -- Begin function _xt_free
	.p2align	4, 0x90
	.type	_xt_free,@function
_xt_free:                               # @_xt_free
# %bb.0:
	test	rdi, rdi
	je	.LBB11_10
# %bb.1:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	free@PLT                        # TAILCALL
# %bb.2:
	mov	rcx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rcx], 0
	je	.LBB11_5
	.p2align	4, 0x90
.LBB11_3:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB11_4 Depth 2
	mov	edx, 1
	xchg	dword ptr [rip + xt_alloc_spin], edx
	test	edx, edx
	je	.LBB11_5
.LBB11_4:                               #   Parent Loop BB11_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	edx, dword ptr [rip + xt_alloc_spin]
	test	edx, edx
	jne	.LBB11_4
	jmp	.LBB11_3
.LBB11_5:
	lea	rdx, [rip + xt_cache_n]
	mov	esi, dword ptr [rdx + 4*rax]
	cmp	esi, 64
	jb	.LBB11_8
# %bb.6:
	cmp	dword ptr [rcx], 0
	je	free@PLT                        # TAILCALL
# %bb.7:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	free@PLT                        # TAILCALL
.LBB11_8:
	lea	r8, [rip + xt_cache]
	mov	r9, qword ptr [r8 + 8*rax]
	mov	qword ptr [rdi], r9
	mov	qword ptr [r8 + 8*rax], rdi
	inc	esi
	mov	dword ptr [rdx + 4*rax], esi
	cmp	dword ptr [rcx], 0
	je	.LBB11_10
# %bb.9:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB11_10:
	ret
.Lfunc_end11:
	.size	_xt_free, .Lfunc_end11-_xt_free
                                        # -- End function
	.section	.rodata.cst16,"aM",@progbits,16
	.p2align	4, 0x0                          # -- Begin function _xt_fmt_f
.LCPI12_0:
	.quad	0x8000000000000000              # double -0
	.quad	0x8000000000000000              # double -0
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0
.LCPI12_1:
	.quad	0x4024000000000000              # double 10
	.text
	.globl	_xt_fmt_f
	.p2align	4, 0x90
	.type	_xt_fmt_f,@function
_xt_fmt_f:                              # @_xt_fmt_f
# %bb.0:
	push	rbx
	xor	eax, eax
	test	ecx, ecx
	cmovg	eax, ecx
	cmp	eax, 24
	mov	r9d, 24
	cmovl	r9d, eax
	xorpd	xmm1, xmm1
	ucomisd	xmm1, xmm0
	jbe	.LBB12_1
# %bb.2:
	lea	rsi, [rdi + 1]
	mov	byte ptr [rdi], 45
	xorpd	xmm0, xmmword ptr [rip + .LCPI12_0]
	jmp	.LBB12_3
.LBB12_1:
	mov	rsi, rdi
.LBB12_3:
	cvttsd2si	rdx, xmm0
	xorps	xmm1, xmm1
	cvtsi2sd	xmm1, rdx
	xor	r10d, r10d
	movabs	r11, -3689348814741910323
	.p2align	4, 0x90
.LBB12_4:                               # =>This Inner Loop Header: Depth=1
	mov	r8, rdx
	mov	rax, rdx
	mul	r11
	shr	rdx, 3
	lea	eax, [rdx + rdx]
	lea	eax, [rax + 4*rax]
	mov	ebx, r8d
	sub	ebx, eax
	or	bl, 48
	lea	rax, [r10 + 1]
	mov	byte ptr [rsp + r10 - 32], bl
	cmp	r8, 10
	jb	.LBB12_6
# %bb.5:                                #   in Loop: Header=BB12_4 Depth=1
	cmp	r10, 23
	mov	r10, rax
	jb	.LBB12_4
	.p2align	4, 0x90
.LBB12_6:                               # =>This Inner Loop Header: Depth=1
	lea	rdx, [rax - 1]
	mov	r8d, edx
	movzx	r8d, byte ptr [rsp + r8 - 32]
	mov	byte ptr [rsi], r8b
	inc	rsi
	cmp	rax, 1
	mov	rax, rdx
	jg	.LBB12_6
# %bb.7:
	test	ecx, ecx
	jle	.LBB12_11
# %bb.8:
	subsd	xmm0, xmm1
	mov	byte ptr [rsi], 46
	neg	r9d
	mov	eax, 1
	movsd	xmm1, qword ptr [rip + .LCPI12_1] # xmm1 = [1.0E+1,0.0E+0]
	mov	ecx, 9
	xor	edx, edx
	.p2align	4, 0x90
.LBB12_9:                               # =>This Inner Loop Header: Depth=1
	mulsd	xmm0, xmm1
	cvttsd2si	r8d, xmm0
	cmp	r8d, 9
	cmovge	r8d, ecx
	test	r8d, r8d
	cmovle	r8d, edx
	xorps	xmm2, xmm2
	cvtsi2sd	xmm2, r8d
                                        # kill: def $r8b killed $r8b killed $r8d
	or	r8b, 48
	mov	byte ptr [rsi + rax], r8b
	subsd	xmm0, xmm2
	inc	rax
	lea	r8d, [r9 + rax]
	cmp	r8d, 1
	jne	.LBB12_9
# %bb.10:
	add	rsi, rax
.LBB12_11:
	mov	byte ptr [rsi], 0
	sub	esi, edi
	mov	eax, esi
	pop	rbx
	ret
.Lfunc_end12:
	.size	_xt_fmt_f, .Lfunc_end12-_xt_fmt_f
                                        # -- End function
	.globl	_xtc_alloc                      # -- Begin function _xtc_alloc
	.p2align	4, 0x90
	.type	_xtc_alloc,@function
_xtc_alloc:                             # @_xtc_alloc
# %bb.0:
	push	r15
	push	r14
	push	rbx
	mov	rbx, rdx
	mov	r15, rsi
	mov	r14, rdi
	test	rsi, rsi
	je	.LBB13_3
# %bb.1:
	mov	rax, -1048577
	xor	edx, edx
	div	r15
	cmp	rax, r14
	jae	.LBB13_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB13_3:
	mov	rax, r15
	imul	rax, r14
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB13_4
# %bb.5:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], r15
	mov	qword ptr [rax + 12], r14
	mov	qword ptr [rax + 20], rbx
	mov	qword ptr [rax + 28], 0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	jmp	.LBB13_6
.LBB13_4:
	xor	eax, eax
.LBB13_6:
	pop	rbx
	pop	r14
	pop	r15
	ret
.Lfunc_end13:
	.size	_xtc_alloc, .Lfunc_end13-_xtc_alloc
                                        # -- End function
	.globl	_xtc_simd_register              # -- Begin function _xtc_simd_register
	.p2align	4, 0x90
	.type	_xtc_simd_register,@function
_xtc_simd_register:                     # @_xtc_simd_register
# %bb.0:
	test	rdi, rdi
	je	.LBB14_76
# %bb.1:
	push	rbp
	push	r15
	push	r14
	push	r13
	push	r12
	push	rbx
	push	rax
	mov	rbx, rsi
	test	rsi, rsi
	je	.LBB14_75
# %bb.2:
	mov	r14, rdi
	mov	eax, r14d
	or	eax, ebx
	and	eax, 4095
	jne	.LBB14_75
# %bb.3:
	mov	r12, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [r12], 0
	je	.LBB14_6
	.p2align	4, 0x90
.LBB14_4:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB14_5 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB14_6
.LBB14_5:                               #   Parent Loop BB14_4 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB14_5
	jmp	.LBB14_4
.LBB14_6:
	mov	rax, qword ptr [rip + xt_simd_cap]
	cmp	qword ptr [rip + xt_simd_n], rax
	jne	.LBB14_66
# %bb.7:
	lea	rcx, [rax + rax]
	test	rax, rax
	mov	r12d, 64
	cmovne	r12, rcx
	mov	rdi, r12
	shl	rdi, 4
	call	_xt_calloc@PLT
	mov	r13, rax
	mov	rdi, r12
	call	_xt_calloc@PLT
	mov	r15, rax
	test	r13, r13
	setne	al
	test	r15, r15
	setne	bpl
	and	bpl, al
	cmp	bpl, 1
	jne	.LBB14_17
# %bb.8:
	mov	rax, qword ptr [rip + xt_simd_n]
	mov	rcx, rax
	add	rcx, rax
	je	.LBB14_11
# %bb.9:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	esi, esi
	.p2align	4, 0x90
.LBB14_10:                              # =>This Inner Loop Header: Depth=1
	mov	rdi, qword ptr [rdx + 8*rsi]
	mov	qword ptr [r13 + 8*rsi], rdi
	inc	rsi
	cmp	rcx, rsi
	jne	.LBB14_10
.LBB14_11:
	test	rax, rax
	je	.LBB14_14
# %bb.12:
	mov	rcx, qword ptr [rip + xt_simd_flag]
	xor	edx, edx
	.p2align	4, 0x90
.LBB14_13:                              # =>This Inner Loop Header: Depth=1
	movzx	esi, byte ptr [rcx + rdx]
	mov	byte ptr [r15 + rdx], sil
	inc	rdx
	cmp	rax, rdx
	jne	.LBB14_13
.LBB14_14:
	mov	rdi, qword ptr [rip + xt_simd_tab]
	test	rdi, rdi
	je	.LBB14_36
# %bb.15:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	.LBB14_16
# %bb.20:
	mov	rcx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rcx], 0
	jne	.LBB14_22
	jmp	.LBB14_23
	.p2align	4, 0x90
.LBB14_21:                              #   Parent Loop BB14_22 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB14_21
.LBB14_22:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB14_21 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB14_21
.LBB14_23:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB14_34
# %bb.24:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB14_16
# %bb.25:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB14_16:
	call	free@PLT
.LBB14_36:
	mov	rdi, qword ptr [rip + xt_simd_flag]
	test	rdi, rdi
	je	.LBB14_60
# %bb.37:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	.LBB14_38
# %bb.39:
	mov	rcx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rcx], 0
	jne	.LBB14_41
	jmp	.LBB14_42
	.p2align	4, 0x90
.LBB14_40:                              #   Parent Loop BB14_41 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB14_40
.LBB14_41:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB14_40 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB14_40
.LBB14_42:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB14_58
# %bb.43:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB14_38
# %bb.44:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB14_38:
	call	free@PLT
.LBB14_60:
	mov	qword ptr [rip + xt_simd_tab], r13
	mov	qword ptr [rip + xt_simd_flag], r15
	mov	qword ptr [rip + xt_simd_cap], r12
	mov	r12, qword ptr [rip + _xt_threads_active@GOTPCREL]
	jmp	.LBB14_65
.LBB14_17:
	test	r13, r13
	mov	r12, qword ptr [rip + _xt_threads_active@GOTPCREL]
	je	.LBB14_48
# %bb.18:
	mov	rdi, r13
	add	rdi, -8
	mov	rax, qword ptr [r13 - 8]
	cmp	rax, 64
	jae	.LBB14_19
# %bb.27:
	cmp	dword ptr [r12], 0
	jne	.LBB14_29
	jmp	.LBB14_30
	.p2align	4, 0x90
.LBB14_28:                              #   Parent Loop BB14_29 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB14_28
.LBB14_29:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB14_28 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB14_28
.LBB14_30:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB14_46
# %bb.31:
	cmp	dword ptr [r12], 0
	je	.LBB14_19
# %bb.32:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB14_19:
	call	free@PLT
.LBB14_48:
	test	r15, r15
	je	.LBB14_63
# %bb.49:
	mov	rdi, r15
	add	rdi, -8
	mov	rax, qword ptr [r15 - 8]
	cmp	rax, 64
	jae	.LBB14_50
# %bb.51:
	cmp	dword ptr [r12], 0
	jne	.LBB14_53
	jmp	.LBB14_54
	.p2align	4, 0x90
.LBB14_52:                              #   Parent Loop BB14_53 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB14_52
.LBB14_53:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB14_52 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB14_52
.LBB14_54:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB14_61
# %bb.55:
	cmp	dword ptr [r12], 0
	je	.LBB14_50
# %bb.56:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB14_50:
	call	free@PLT
.LBB14_63:
	cmp	dword ptr [r12], 0
	je	.LBB14_65
# %bb.64:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB14_65:
	test	bpl, bpl
	je	.LBB14_75
.LBB14_66:
	mov	rax, qword ptr [rip + xt_simd_n]
	test	rax, rax
	je	.LBB14_70
# %bb.67:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	ecx, ecx
	movabs	rsi, 2305843009213693950
	mov	rdi, rax
	.p2align	4, 0x90
.LBB14_68:                              # =>This Inner Loop Header: Depth=1
	lea	r8, [rdi + rcx]
	mov	r9, r8
	shr	r9
	and	r8, rsi
	cmp	qword ptr [rdx + 8*r8], r14
	lea	r8, [r9 + 1]
	cmova	rdi, r9
	cmovbe	rcx, r8
	cmp	rcx, rdi
	jb	.LBB14_68
# %bb.69:
	cmp	rax, rcx
	ja	.LBB14_71
	jmp	.LBB14_73
.LBB14_70:
	xor	ecx, ecx
	cmp	rax, rcx
	jbe	.LBB14_73
.LBB14_71:
	mov	rdx, qword ptr [rip + xt_simd_flag]
	mov	rdi, rax
	shl	rdi, 4
	add	rdi, qword ptr [rip + xt_simd_tab]
	mov	rsi, rax
	.p2align	4, 0x90
.LBB14_72:                              # =>This Inner Loop Header: Depth=1
	movups	xmm0, xmmword ptr [rdi - 16]
	movups	xmmword ptr [rdi], xmm0
	add	rdi, -16
	movzx	r8d, byte ptr [rdx + rsi - 1]
	mov	byte ptr [rdx + rsi], r8b
	dec	rsi
	cmp	rsi, rcx
	ja	.LBB14_72
.LBB14_73:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	mov	rsi, rcx
	shl	rsi, 4
	mov	qword ptr [rdx + rsi], r14
	add	rbx, r14
	mov	qword ptr [rdx + rsi + 8], rbx
	mov	rdx, qword ptr [rip + xt_simd_flag]
	mov	byte ptr [rdx + rcx], 0
	inc	rax
	mov	qword ptr [rip + xt_simd_n], rax
	cmp	dword ptr [r12], 0
	je	.LBB14_75
# %bb.74:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB14_75:
	add	rsp, 8
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	pop	rbp
.LBB14_76:
	ret
.LBB14_34:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB14_36
# %bb.35:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB14_36
.LBB14_58:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB14_60
# %bb.59:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB14_60
.LBB14_46:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [r12], 0
	je	.LBB14_48
# %bb.47:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB14_48
.LBB14_61:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [r12], 0
	je	.LBB14_63
# %bb.62:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB14_63
.Lfunc_end14:
	.size	_xtc_simd_register, .Lfunc_end14-_xtc_simd_register
                                        # -- End function
	.globl	_xtc_simd_base                  # -- Begin function _xtc_simd_base
	.p2align	4, 0x90
	.type	_xtc_simd_base,@function
_xtc_simd_base:                         # @_xtc_simd_base
# %bb.0:
	mov	rcx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rcx], 0
	je	.LBB15_3
	.p2align	4, 0x90
.LBB15_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB15_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB15_3
.LBB15_2:                               #   Parent Loop BB15_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB15_2
	jmp	.LBB15_1
.LBB15_3:
	mov	rdx, qword ptr [rip + xt_simd_n]
	test	rdx, rdx
	je	.LBB15_9
# %bb.4:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	xor	eax, eax
	movabs	r8, 2305843009213693950
	.p2align	4, 0x90
.LBB15_5:                               # =>This Inner Loop Header: Depth=1
	lea	r9, [rdx + rax]
	mov	r10, r9
	shr	r10
	and	r9, r8
	cmp	qword ptr [rsi + 8*r9], rdi
	lea	r9, [r10 + 1]
	cmova	rdx, r10
	cmovbe	rax, r9
	cmp	rax, rdx
	jb	.LBB15_5
# %bb.6:
	test	rax, rax
	jne	.LBB15_7
	jmp	.LBB15_10
.LBB15_9:
	xor	eax, eax
	test	rax, rax
	je	.LBB15_10
.LBB15_7:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	shl	rax, 4
	cmp	qword ptr [rdx + rax - 8], rdi
	jbe	.LBB15_10
# %bb.8:
	mov	rax, qword ptr [rdx + rax - 16]
	cmp	dword ptr [rcx], 0
	jne	.LBB15_11
	jmp	.LBB15_12
.LBB15_10:
	xor	eax, eax
	cmp	dword ptr [rcx], 0
	je	.LBB15_12
.LBB15_11:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB15_12:
	ret
.Lfunc_end15:
	.size	_xtc_simd_base, .Lfunc_end15-_xtc_simd_base
                                        # -- End function
	.globl	_xt_rt_lock                     # -- Begin function _xt_rt_lock
	.p2align	4, 0x90
	.type	_xt_rt_lock,@function
_xt_rt_lock:                            # @_xt_rt_lock
# %bb.0:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB16_3
	.p2align	4, 0x90
.LBB16_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB16_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB16_3
.LBB16_2:                               #   Parent Loop BB16_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB16_2
	jmp	.LBB16_1
.LBB16_3:
	ret
.Lfunc_end16:
	.size	_xt_rt_lock, .Lfunc_end16-_xt_rt_lock
                                        # -- End function
	.globl	_xt_rt_unlock                   # -- Begin function _xt_rt_unlock
	.p2align	4, 0x90
	.type	_xt_rt_unlock,@function
_xt_rt_unlock:                          # @_xt_rt_unlock
# %bb.0:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB17_2
# %bb.1:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB17_2:
	ret
.Lfunc_end17:
	.size	_xt_rt_unlock, .Lfunc_end17-_xt_rt_unlock
                                        # -- End function
	.globl	_xtc_simd_span                  # -- Begin function _xtc_simd_span
	.p2align	4, 0x90
	.type	_xtc_simd_span,@function
_xtc_simd_span:                         # @_xtc_simd_span
# %bb.0:
	mov	rcx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rcx], 0
	je	.LBB18_3
	.p2align	4, 0x90
.LBB18_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB18_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB18_3
.LBB18_2:                               #   Parent Loop BB18_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB18_2
	jmp	.LBB18_1
.LBB18_3:
	mov	rax, qword ptr [rip + xt_simd_n]
	test	rax, rax
	je	.LBB18_4
# %bb.5:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	xor	edx, edx
	movabs	r8, 2305843009213693950
	.p2align	4, 0x90
.LBB18_6:                               # =>This Inner Loop Header: Depth=1
	lea	r9, [rax + rdx]
	mov	r10, r9
	shr	r10
	and	r9, r8
	cmp	qword ptr [rsi + 8*r9], rdi
	lea	r9, [r10 + 1]
	cmova	rax, r10
	cmovbe	rdx, r9
	cmp	rdx, rax
	jb	.LBB18_6
	jmp	.LBB18_7
.LBB18_4:
	xor	edx, edx
.LBB18_7:
	mov	rax, -1
	test	rdx, rdx
	je	.LBB18_10
# %bb.8:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	shl	rdx, 4
	mov	rdx, qword ptr [rsi + rdx - 8]
	sub	rdx, rdi
	jbe	.LBB18_10
# %bb.9:
	mov	rax, rdx
.LBB18_10:
	cmp	dword ptr [rcx], 0
	je	.LBB18_12
# %bb.11:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB18_12:
	ret
.Lfunc_end18:
	.size	_xtc_simd_span, .Lfunc_end18-_xtc_simd_span
                                        # -- End function
	.globl	_xtc_simd_watch                 # -- Begin function _xtc_simd_watch
	.p2align	4, 0x90
	.type	_xtc_simd_watch,@function
_xtc_simd_watch:                        # @_xtc_simd_watch
# %bb.0:
	push	rbp
	push	r15
	push	r14
	push	r13
	push	r12
	push	rbx
	sub	rsp, 40
	mov	r15, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [r15], 0
	je	.LBB19_3
	.p2align	4, 0x90
.LBB19_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB19_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB19_3
.LBB19_2:                               #   Parent Loop BB19_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB19_2
	jmp	.LBB19_1
.LBB19_3:
	mov	rax, qword ptr [rip + xt_simd_n]
	xor	ebx, ebx
	test	rax, rax
	je	.LBB19_4
# %bb.5:
	mov	rcx, qword ptr [rip + xt_simd_tab]
	xor	r12d, r12d
	movabs	rdx, 2305843009213693950
	.p2align	4, 0x90
.LBB19_6:                               # =>This Inner Loop Header: Depth=1
	lea	rsi, [rax + r12]
	mov	r8, rsi
	shr	r8
	and	rsi, rdx
	cmp	qword ptr [rcx + 8*rsi], rdi
	lea	rsi, [r8 + 1]
	cmova	rax, r8
	cmovbe	r12, rsi
	cmp	r12, rax
	jb	.LBB19_6
# %bb.7:
	test	r12, r12
	jne	.LBB19_8
	jmp	.LBB19_13
.LBB19_4:
	xor	r12d, r12d
	test	r12, r12
	je	.LBB19_13
.LBB19_8:
	mov	rax, qword ptr [rip + xt_simd_tab]
	dec	r12
	mov	r13, r12
	shl	r13, 4
	cmp	qword ptr [rax + r13], rdi
	jne	.LBB19_13
# %bb.9:
	cmp	byte ptr [rip + xt_simd_installed], 0
	jne	.LBB19_11
# %bb.10:
	lea	rax, [rip + xt_simd_fault]
	mov	qword ptr [rsp + 8], rax
	mov	qword ptr [rsp + 16], 1140850692
	mov	rax, qword ptr [rip + xt_sigrestore@GOTPCREL]
	mov	qword ptr [rsp + 24], rax
	mov	qword ptr [rsp + 32], 0
	lea	rcx, [rip + xt_simd_old]
	lea	r14, [rsp + 8]
	mov	rbp, rdi
	mov	edi, 13
	mov	esi, 11
	mov	r8d, 8
	mov	rdx, r14
	xor	eax, eax
	call	syscall@PLT
	lea	rcx, [rip + xt_simd_old+32]
	mov	edi, 13
	mov	esi, 7
	mov	r8d, 8
	mov	rdx, r14
	xor	eax, eax
	call	syscall@PLT
	mov	rdi, rbp
	mov	byte ptr [rip + xt_simd_installed], 1
.LBB19_11:
	mov	rax, qword ptr [rip + xt_simd_tab]
	mov	rsi, qword ptr [rax + r13 + 8]
	sub	rsi, qword ptr [rax + r13]
	add	rsi, 16383
	and	rsi, -16384
	mov	edx, 1
	call	mprotect@PLT
	test	eax, eax
	jne	.LBB19_13
# %bb.12:
	mov	rax, qword ptr [rip + xt_simd_flag]
	or	byte ptr [rax + r12], 1
	mov	ebx, 1
.LBB19_13:
	cmp	dword ptr [r15], 0
	je	.LBB19_15
# %bb.14:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB19_15:
	mov	eax, ebx
	add	rsp, 40
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	pop	rbp
	ret
.Lfunc_end19:
	.size	_xtc_simd_watch, .Lfunc_end19-_xtc_simd_watch
                                        # -- End function
	.globl	_xtc_simd_unwatch               # -- Begin function _xtc_simd_unwatch
	.p2align	4, 0x90
	.type	_xtc_simd_unwatch,@function
_xtc_simd_unwatch:                      # @_xtc_simd_unwatch
# %bb.0:
	push	rbx
	mov	rbx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rbx], 0
	je	.LBB20_3
	.p2align	4, 0x90
.LBB20_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB20_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB20_3
.LBB20_2:                               #   Parent Loop BB20_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB20_2
	jmp	.LBB20_1
.LBB20_3:
	mov	rcx, qword ptr [rip + xt_simd_n]
	test	rcx, rcx
	je	.LBB20_4
# %bb.5:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	eax, eax
	movabs	rsi, 2305843009213693950
	.p2align	4, 0x90
.LBB20_6:                               # =>This Inner Loop Header: Depth=1
	lea	r8, [rcx + rax]
	mov	r9, r8
	shr	r9
	and	r8, rsi
	cmp	qword ptr [rdx + 8*r8], rdi
	lea	r8, [r9 + 1]
	cmova	rcx, r9
	cmovbe	rax, r8
	cmp	rax, rcx
	jb	.LBB20_6
# %bb.7:
	test	rax, rax
	jne	.LBB20_8
	jmp	.LBB20_11
.LBB20_4:
	xor	eax, eax
	test	rax, rax
	je	.LBB20_11
.LBB20_8:
	mov	rcx, qword ptr [rip + xt_simd_tab]
	dec	rax
	mov	rdx, rax
	shl	rdx, 4
	cmp	qword ptr [rcx + rdx], rdi
	jne	.LBB20_11
# %bb.9:
	mov	rsi, qword ptr [rip + xt_simd_flag]
	movzx	r8d, byte ptr [rsi + rax]
	test	r8b, 1
	je	.LBB20_11
# %bb.10:
	and	r8b, -2
	mov	byte ptr [rsi + rax], r8b
	mov	rsi, qword ptr [rcx + rdx + 8]
	sub	rsi, qword ptr [rcx + rdx]
	add	rsi, 16383
	and	rsi, -16384
	mov	edx, 3
	call	mprotect@PLT
.LBB20_11:
	cmp	dword ptr [rbx], 0
	je	.LBB20_13
# %bb.12:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB20_13:
	pop	rbx
	ret
.Lfunc_end20:
	.size	_xtc_simd_unwatch, .Lfunc_end20-_xtc_simd_unwatch
                                        # -- End function
	.globl	_xtc_simd_dirty                 # -- Begin function _xtc_simd_dirty
	.p2align	4, 0x90
	.type	_xtc_simd_dirty,@function
_xtc_simd_dirty:                        # @_xtc_simd_dirty
# %bb.0:
	mov	rcx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rcx], 0
	je	.LBB21_3
	.p2align	4, 0x90
.LBB21_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB21_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB21_3
.LBB21_2:                               #   Parent Loop BB21_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB21_2
	jmp	.LBB21_1
.LBB21_3:
	mov	rax, qword ptr [rip + xt_simd_n]
	test	rax, rax
	je	.LBB21_4
# %bb.5:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	xor	edx, edx
	movabs	r8, 2305843009213693950
	.p2align	4, 0x90
.LBB21_6:                               # =>This Inner Loop Header: Depth=1
	lea	r9, [rax + rdx]
	mov	r10, r9
	shr	r10
	and	r9, r8
	cmp	qword ptr [rsi + 8*r9], rdi
	lea	r9, [r10 + 1]
	cmova	rax, r10
	cmovbe	rdx, r9
	cmp	rdx, rax
	jb	.LBB21_6
	jmp	.LBB21_7
.LBB21_4:
	xor	edx, edx
.LBB21_7:
	mov	eax, 1
	test	rdx, rdx
	je	.LBB21_10
# %bb.8:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	dec	rdx
	mov	r8, rdx
	shl	r8, 4
	cmp	qword ptr [rsi + r8], rdi
	jne	.LBB21_10
# %bb.9:
	mov	rax, qword ptr [rip + xt_simd_flag]
	movzx	eax, byte ptr [rax + rdx]
	not	eax
	and	eax, 1
.LBB21_10:
	cmp	dword ptr [rcx], 0
	je	.LBB21_12
# %bb.11:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB21_12:
	ret
.Lfunc_end21:
	.size	_xtc_simd_dirty, .Lfunc_end21-_xtc_simd_dirty
                                        # -- End function
	.globl	_xtc_alloc_aligned              # -- Begin function _xtc_alloc_aligned
	.p2align	4, 0x90
	.type	_xtc_alloc_aligned,@function
_xtc_alloc_aligned:                     # @_xtc_alloc_aligned
# %bb.0:
	push	rbp
	push	r15
	push	r14
	push	r13
	push	r12
	push	rbx
	push	rax
	mov	r14, rdx
	mov	r12, rsi
	mov	r15, rdi
	test	rsi, rsi
	je	.LBB22_3
# %bb.1:
	mov	rax, -1048577
	xor	edx, edx
	div	r12
	cmp	rax, r15
	jae	.LBB22_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB22_3:
	mov	r13, r12
	imul	r13, r15
	cmp	r13, 17
	mov	edi, 16
	cmovae	rdi, r13
	add	rdi, 16383
	and	rdi, -16384
	add	rdi, 16432
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB22_18
# %bb.4:
	mov	rbx, rax
	add	rbx, 16431
	and	rbx, -16384
	mov	dword ptr [rbx - 40], 1481920323
	mov	qword ptr [rbx - 36], r12
	mov	qword ptr [rbx - 28], r15
	mov	qword ptr [rbx - 20], r14
	mov	qword ptr [rbx - 12], 0
	mov	dword ptr [rbx - 4], 1
	mov	qword ptr [rbx - 48], rax
	mov	r15, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [r15], 0
	je	.LBB22_7
	.p2align	4, 0x90
.LBB22_5:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB22_6 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB22_7
.LBB22_6:                               #   Parent Loop BB22_5 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB22_6
	jmp	.LBB22_5
.LBB22_7:
	mov	rax, qword ptr [rip + xt_simd_cap]
	cmp	qword ptr [rip + xt_simd_n], rax
	jne	.LBB22_68
# %bb.8:
	lea	rcx, [rax + rax]
	test	rax, rax
	mov	r15d, 64
	cmovne	r15, rcx
	mov	rdi, r15
	shl	rdi, 4
	call	_xt_calloc@PLT
	mov	r12, rax
	mov	rdi, r15
	call	_xt_calloc@PLT
	mov	r14, rax
	test	r12, r12
	setne	al
	test	r14, r14
	setne	bpl
	and	bpl, al
	cmp	bpl, 1
	jne	.LBB22_19
# %bb.9:
	mov	rax, qword ptr [rip + xt_simd_n]
	mov	rcx, rax
	add	rcx, rax
	je	.LBB22_12
# %bb.10:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	esi, esi
	.p2align	4, 0x90
.LBB22_11:                              # =>This Inner Loop Header: Depth=1
	mov	rdi, qword ptr [rdx + 8*rsi]
	mov	qword ptr [r12 + 8*rsi], rdi
	inc	rsi
	cmp	rcx, rsi
	jne	.LBB22_11
.LBB22_12:
	test	rax, rax
	je	.LBB22_15
# %bb.13:
	mov	rcx, qword ptr [rip + xt_simd_flag]
	xor	edx, edx
	.p2align	4, 0x90
.LBB22_14:                              # =>This Inner Loop Header: Depth=1
	movzx	esi, byte ptr [rcx + rdx]
	mov	byte ptr [r14 + rdx], sil
	inc	rdx
	cmp	rax, rdx
	jne	.LBB22_14
.LBB22_15:
	mov	rdi, qword ptr [rip + xt_simd_tab]
	test	rdi, rdi
	je	.LBB22_38
# %bb.16:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	.LBB22_17
# %bb.22:
	mov	rcx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rcx], 0
	jne	.LBB22_24
	jmp	.LBB22_25
	.p2align	4, 0x90
.LBB22_23:                              #   Parent Loop BB22_24 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB22_23
.LBB22_24:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB22_23 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB22_23
.LBB22_25:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB22_36
# %bb.26:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB22_17
# %bb.27:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB22_17:
	call	free@PLT
.LBB22_38:
	mov	rdi, qword ptr [rip + xt_simd_flag]
	test	rdi, rdi
	je	.LBB22_62
# %bb.39:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	.LBB22_40
# %bb.41:
	mov	rcx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rcx], 0
	jne	.LBB22_43
	jmp	.LBB22_44
	.p2align	4, 0x90
.LBB22_42:                              #   Parent Loop BB22_43 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB22_42
.LBB22_43:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB22_42 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB22_42
.LBB22_44:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB22_60
# %bb.45:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB22_40
# %bb.46:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB22_40:
	call	free@PLT
.LBB22_62:
	mov	qword ptr [rip + xt_simd_tab], r12
	mov	qword ptr [rip + xt_simd_flag], r14
	mov	qword ptr [rip + xt_simd_cap], r15
	mov	r15, qword ptr [rip + _xt_threads_active@GOTPCREL]
	jmp	.LBB22_67
.LBB22_18:
	xor	ebx, ebx
	jmp	.LBB22_77
.LBB22_19:
	test	r12, r12
	mov	r15, qword ptr [rip + _xt_threads_active@GOTPCREL]
	je	.LBB22_50
# %bb.20:
	mov	rdi, r12
	add	rdi, -8
	mov	rax, qword ptr [r12 - 8]
	cmp	rax, 64
	jae	.LBB22_21
# %bb.29:
	cmp	dword ptr [r15], 0
	jne	.LBB22_31
	jmp	.LBB22_32
	.p2align	4, 0x90
.LBB22_30:                              #   Parent Loop BB22_31 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB22_30
.LBB22_31:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB22_30 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB22_30
.LBB22_32:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB22_48
# %bb.33:
	cmp	dword ptr [r15], 0
	je	.LBB22_21
# %bb.34:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB22_21:
	call	free@PLT
.LBB22_50:
	test	r14, r14
	je	.LBB22_65
# %bb.51:
	mov	rdi, r14
	add	rdi, -8
	mov	rax, qword ptr [r14 - 8]
	cmp	rax, 64
	jae	.LBB22_52
# %bb.53:
	cmp	dword ptr [r15], 0
	jne	.LBB22_55
	jmp	.LBB22_56
	.p2align	4, 0x90
.LBB22_54:                              #   Parent Loop BB22_55 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB22_54
.LBB22_55:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB22_54 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB22_54
.LBB22_56:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB22_63
# %bb.57:
	cmp	dword ptr [r15], 0
	je	.LBB22_52
# %bb.58:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB22_52:
	call	free@PLT
.LBB22_65:
	cmp	dword ptr [r15], 0
	je	.LBB22_67
# %bb.66:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB22_67:
	test	bpl, bpl
	je	.LBB22_77
.LBB22_68:
	mov	rax, qword ptr [rip + xt_simd_n]
	test	rax, rax
	je	.LBB22_72
# %bb.69:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	ecx, ecx
	movabs	rsi, 2305843009213693950
	mov	rdi, rax
	.p2align	4, 0x90
.LBB22_70:                              # =>This Inner Loop Header: Depth=1
	lea	r8, [rdi + rcx]
	mov	r9, r8
	shr	r9
	and	r8, rsi
	cmp	qword ptr [rdx + 8*r8], rbx
	lea	r8, [r9 + 1]
	cmova	rdi, r9
	cmovbe	rcx, r8
	cmp	rcx, rdi
	jb	.LBB22_70
# %bb.71:
	cmp	rax, rcx
	ja	.LBB22_73
	jmp	.LBB22_75
.LBB22_72:
	xor	ecx, ecx
	cmp	rax, rcx
	jbe	.LBB22_75
.LBB22_73:
	mov	rdx, qword ptr [rip + xt_simd_flag]
	mov	rdi, rax
	shl	rdi, 4
	add	rdi, qword ptr [rip + xt_simd_tab]
	mov	rsi, rax
	.p2align	4, 0x90
.LBB22_74:                              # =>This Inner Loop Header: Depth=1
	movups	xmm0, xmmword ptr [rdi - 16]
	movups	xmmword ptr [rdi], xmm0
	add	rdi, -16
	movzx	r8d, byte ptr [rdx + rsi - 1]
	mov	byte ptr [rdx + rsi], r8b
	dec	rsi
	cmp	rsi, rcx
	ja	.LBB22_74
.LBB22_75:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	mov	rsi, rcx
	shl	rsi, 4
	mov	qword ptr [rdx + rsi], rbx
	add	r13, rbx
	mov	qword ptr [rdx + rsi + 8], r13
	mov	rdx, qword ptr [rip + xt_simd_flag]
	mov	byte ptr [rdx + rcx], 0
	inc	rax
	mov	qword ptr [rip + xt_simd_n], rax
	cmp	dword ptr [r15], 0
	je	.LBB22_77
# %bb.76:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB22_77:
	mov	rax, rbx
	add	rsp, 8
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	pop	rbp
	ret
.LBB22_36:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB22_38
# %bb.37:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB22_38
.LBB22_60:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB22_62
# %bb.61:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB22_62
.LBB22_48:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [r15], 0
	je	.LBB22_50
# %bb.49:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB22_50
.LBB22_63:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [r15], 0
	je	.LBB22_65
# %bb.64:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB22_65
.Lfunc_end22:
	.size	_xtc_alloc_aligned, .Lfunc_end22-_xtc_alloc_aligned
                                        # -- End function
	.globl	_xtc_new_simd_u8                # -- Begin function _xtc_new_simd_u8
	.p2align	4, 0x90
	.type	_xtc_new_simd_u8,@function
_xtc_new_simd_u8:                       # @_xtc_new_simd_u8
# %bb.0:
	mov	esi, 1
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end23:
	.size	_xtc_new_simd_u8, .Lfunc_end23-_xtc_new_simd_u8
                                        # -- End function
	.globl	_xtc_new_simd_i8                # -- Begin function _xtc_new_simd_i8
	.p2align	4, 0x90
	.type	_xtc_new_simd_i8,@function
_xtc_new_simd_i8:                       # @_xtc_new_simd_i8
# %bb.0:
	mov	esi, 1
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end24:
	.size	_xtc_new_simd_i8, .Lfunc_end24-_xtc_new_simd_i8
                                        # -- End function
	.globl	_xtc_new_simd_bool              # -- Begin function _xtc_new_simd_bool
	.p2align	4, 0x90
	.type	_xtc_new_simd_bool,@function
_xtc_new_simd_bool:                     # @_xtc_new_simd_bool
# %bb.0:
	mov	esi, 1
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end25:
	.size	_xtc_new_simd_bool, .Lfunc_end25-_xtc_new_simd_bool
                                        # -- End function
	.globl	_xtc_new_simd_u16               # -- Begin function _xtc_new_simd_u16
	.p2align	4, 0x90
	.type	_xtc_new_simd_u16,@function
_xtc_new_simd_u16:                      # @_xtc_new_simd_u16
# %bb.0:
	mov	esi, 2
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end26:
	.size	_xtc_new_simd_u16, .Lfunc_end26-_xtc_new_simd_u16
                                        # -- End function
	.globl	_xtc_new_simd_i16               # -- Begin function _xtc_new_simd_i16
	.p2align	4, 0x90
	.type	_xtc_new_simd_i16,@function
_xtc_new_simd_i16:                      # @_xtc_new_simd_i16
# %bb.0:
	mov	esi, 2
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end27:
	.size	_xtc_new_simd_i16, .Lfunc_end27-_xtc_new_simd_i16
                                        # -- End function
	.globl	_xtc_new_simd_u32               # -- Begin function _xtc_new_simd_u32
	.p2align	4, 0x90
	.type	_xtc_new_simd_u32,@function
_xtc_new_simd_u32:                      # @_xtc_new_simd_u32
# %bb.0:
	mov	esi, 4
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end28:
	.size	_xtc_new_simd_u32, .Lfunc_end28-_xtc_new_simd_u32
                                        # -- End function
	.globl	_xtc_new_simd_i32               # -- Begin function _xtc_new_simd_i32
	.p2align	4, 0x90
	.type	_xtc_new_simd_i32,@function
_xtc_new_simd_i32:                      # @_xtc_new_simd_i32
# %bb.0:
	mov	esi, 4
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end29:
	.size	_xtc_new_simd_i32, .Lfunc_end29-_xtc_new_simd_i32
                                        # -- End function
	.globl	_xtc_new_simd_float             # -- Begin function _xtc_new_simd_float
	.p2align	4, 0x90
	.type	_xtc_new_simd_float,@function
_xtc_new_simd_float:                    # @_xtc_new_simd_float
# %bb.0:
	mov	esi, 4
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end30:
	.size	_xtc_new_simd_float, .Lfunc_end30-_xtc_new_simd_float
                                        # -- End function
	.globl	_xtc_new_simd_u64               # -- Begin function _xtc_new_simd_u64
	.p2align	4, 0x90
	.type	_xtc_new_simd_u64,@function
_xtc_new_simd_u64:                      # @_xtc_new_simd_u64
# %bb.0:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end31:
	.size	_xtc_new_simd_u64, .Lfunc_end31-_xtc_new_simd_u64
                                        # -- End function
	.globl	_xtc_new_simd_i64               # -- Begin function _xtc_new_simd_i64
	.p2align	4, 0x90
	.type	_xtc_new_simd_i64,@function
_xtc_new_simd_i64:                      # @_xtc_new_simd_i64
# %bb.0:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end32:
	.size	_xtc_new_simd_i64, .Lfunc_end32-_xtc_new_simd_i64
                                        # -- End function
	.globl	_xtc_new_simd_double            # -- Begin function _xtc_new_simd_double
	.p2align	4, 0x90
	.type	_xtc_new_simd_double,@function
_xtc_new_simd_double:                   # @_xtc_new_simd_double
# %bb.0:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end33:
	.size	_xtc_new_simd_double, .Lfunc_end33-_xtc_new_simd_double
                                        # -- End function
	.globl	_xtc_new_simd_pointer           # -- Begin function _xtc_new_simd_pointer
	.p2align	4, 0x90
	.type	_xtc_new_simd_pointer,@function
_xtc_new_simd_pointer:                  # @_xtc_new_simd_pointer
# %bb.0:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end34:
	.size	_xtc_new_simd_pointer, .Lfunc_end34-_xtc_new_simd_pointer
                                        # -- End function
	.globl	_xtc_new_simd_string            # -- Begin function _xtc_new_simd_string
	.p2align	4, 0x90
	.type	_xtc_new_simd_string,@function
_xtc_new_simd_string:                   # @_xtc_new_simd_string
# %bb.0:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end35:
	.size	_xtc_new_simd_string, .Lfunc_end35-_xtc_new_simd_string
                                        # -- End function
	.globl	_xtc_new_u8                     # -- Begin function _xtc_new_u8
	.p2align	4, 0x90
	.type	_xtc_new_u8,@function
_xtc_new_u8:                            # @_xtc_new_u8
# %bb.0:
	cmp	rdi, 65536
	jb	.LBB36_1
# %bb.5:
	mov	esi, 1
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.LBB36_1:
	push	rbx
	cmp	rdi, 17
	mov	eax, 16
	mov	rbx, rdi
	cmovae	rax, rdi
	add	rax, 40
	mov	rdi, rax
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB36_2
# %bb.3:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 1
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB36_2:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end36:
	.size	_xtc_new_u8, .Lfunc_end36-_xtc_new_u8
                                        # -- End function
	.globl	_xtc_new_i8                     # -- Begin function _xtc_new_i8
	.p2align	4, 0x90
	.type	_xtc_new_i8,@function
_xtc_new_i8:                            # @_xtc_new_i8
# %bb.0:
	cmp	rdi, 65536
	jb	.LBB37_1
# %bb.5:
	mov	esi, 1
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.LBB37_1:
	push	rbx
	cmp	rdi, 17
	mov	eax, 16
	mov	rbx, rdi
	cmovae	rax, rdi
	add	rax, 40
	mov	rdi, rax
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB37_2
# %bb.3:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 1
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB37_2:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end37:
	.size	_xtc_new_i8, .Lfunc_end37-_xtc_new_i8
                                        # -- End function
	.globl	_xtc_new_u16                    # -- Begin function _xtc_new_u16
	.p2align	4, 0x90
	.type	_xtc_new_u16,@function
_xtc_new_u16:                           # @_xtc_new_u16
# %bb.0:
	movabs	rax, 9223372036854251519
	lea	rcx, [rax + 491521]
	test	rdi, rcx
	je	.LBB38_1
# %bb.7:
	mov	esi, 2
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.LBB38_1:
	push	rbx
	cmp	rdi, rax
	jbe	.LBB38_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	rbx, rdi
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
	mov	rdi, rbx
.LBB38_3:
	mov	rbx, rdi
	lea	rax, [rdi + rdi]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB38_4
# %bb.5:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 2
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB38_4:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end38:
	.size	_xtc_new_u16, .Lfunc_end38-_xtc_new_u16
                                        # -- End function
	.globl	_xtc_new_i16                    # -- Begin function _xtc_new_i16
	.p2align	4, 0x90
	.type	_xtc_new_i16,@function
_xtc_new_i16:                           # @_xtc_new_i16
# %bb.0:
	movabs	rax, 9223372036854251519
	lea	rcx, [rax + 491521]
	test	rdi, rcx
	je	.LBB39_1
# %bb.7:
	mov	esi, 2
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.LBB39_1:
	push	rbx
	cmp	rdi, rax
	jbe	.LBB39_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	rbx, rdi
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
	mov	rdi, rbx
.LBB39_3:
	mov	rbx, rdi
	lea	rax, [rdi + rdi]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB39_4
# %bb.5:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 2
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB39_4:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end39:
	.size	_xtc_new_i16, .Lfunc_end39-_xtc_new_i16
                                        # -- End function
	.globl	_xtc_new_u32                    # -- Begin function _xtc_new_u32
	.p2align	4, 0x90
	.type	_xtc_new_u32,@function
_xtc_new_u32:                           # @_xtc_new_u32
# %bb.0:
	movabs	rax, 4611686018427125759
	lea	rcx, [rax + 245761]
	test	rdi, rcx
	je	.LBB40_1
# %bb.7:
	mov	esi, 4
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.LBB40_1:
	push	rbx
	cmp	rdi, rax
	jbe	.LBB40_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	rbx, rdi
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
	mov	rdi, rbx
.LBB40_3:
	mov	rbx, rdi
	lea	rax, [4*rdi]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB40_4
# %bb.5:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 4
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB40_4:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end40:
	.size	_xtc_new_u32, .Lfunc_end40-_xtc_new_u32
                                        # -- End function
	.globl	_xtc_new_i32                    # -- Begin function _xtc_new_i32
	.p2align	4, 0x90
	.type	_xtc_new_i32,@function
_xtc_new_i32:                           # @_xtc_new_i32
# %bb.0:
	movabs	rax, 4611686018427125759
	lea	rcx, [rax + 245761]
	test	rdi, rcx
	je	.LBB41_1
# %bb.7:
	mov	esi, 4
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.LBB41_1:
	push	rbx
	cmp	rdi, rax
	jbe	.LBB41_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	rbx, rdi
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
	mov	rdi, rbx
.LBB41_3:
	mov	rbx, rdi
	lea	rax, [4*rdi]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB41_4
# %bb.5:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 4
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB41_4:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end41:
	.size	_xtc_new_i32, .Lfunc_end41-_xtc_new_i32
                                        # -- End function
	.globl	_xtc_new_pointer                # -- Begin function _xtc_new_pointer
	.p2align	4, 0x90
	.type	_xtc_new_pointer,@function
_xtc_new_pointer:                       # @_xtc_new_pointer
# %bb.0:
	push	rbx
	mov	rbx, rdi
	movabs	rax, 2305843009213562880
	cmp	rdi, rax
	jb	.LBB42_2
# %bb.1:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB42_2:
	lea	rax, [8*rbx]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB42_3
# %bb.4:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 8
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB42_3:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end42:
	.size	_xtc_new_pointer, .Lfunc_end42-_xtc_new_pointer
                                        # -- End function
	.globl	_xtc_new_u64                    # -- Begin function _xtc_new_u64
	.p2align	4, 0x90
	.type	_xtc_new_u64,@function
_xtc_new_u64:                           # @_xtc_new_u64
# %bb.0:
	movabs	rax, 2305843009213562879
	lea	rcx, [rax + 122881]
	test	rdi, rcx
	je	.LBB43_1
# %bb.7:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.LBB43_1:
	push	rbx
	cmp	rdi, rax
	jbe	.LBB43_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	rbx, rdi
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
	mov	rdi, rbx
.LBB43_3:
	mov	rbx, rdi
	lea	rax, [8*rdi]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB43_4
# %bb.5:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 8
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB43_4:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end43:
	.size	_xtc_new_u64, .Lfunc_end43-_xtc_new_u64
                                        # -- End function
	.globl	_xtc_new_i64                    # -- Begin function _xtc_new_i64
	.p2align	4, 0x90
	.type	_xtc_new_i64,@function
_xtc_new_i64:                           # @_xtc_new_i64
# %bb.0:
	movabs	rax, 2305843009213562879
	lea	rcx, [rax + 122881]
	test	rdi, rcx
	je	.LBB44_1
# %bb.7:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.LBB44_1:
	push	rbx
	cmp	rdi, rax
	jbe	.LBB44_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	rbx, rdi
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
	mov	rdi, rbx
.LBB44_3:
	mov	rbx, rdi
	lea	rax, [8*rdi]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB44_4
# %bb.5:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 8
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB44_4:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end44:
	.size	_xtc_new_i64, .Lfunc_end44-_xtc_new_i64
                                        # -- End function
	.globl	_xtc_new_bool                   # -- Begin function _xtc_new_bool
	.p2align	4, 0x90
	.type	_xtc_new_bool,@function
_xtc_new_bool:                          # @_xtc_new_bool
# %bb.0:
	cmp	rdi, 65536
	jb	.LBB45_1
# %bb.5:
	mov	esi, 1
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.LBB45_1:
	push	rbx
	cmp	rdi, 17
	mov	eax, 16
	mov	rbx, rdi
	cmovae	rax, rdi
	add	rax, 40
	mov	rdi, rax
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB45_2
# %bb.3:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 1
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB45_2:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end45:
	.size	_xtc_new_bool, .Lfunc_end45-_xtc_new_bool
                                        # -- End function
	.globl	_xtc_new_float                  # -- Begin function _xtc_new_float
	.p2align	4, 0x90
	.type	_xtc_new_float,@function
_xtc_new_float:                         # @_xtc_new_float
# %bb.0:
	movabs	rax, 4611686018427125759
	lea	rcx, [rax + 245761]
	test	rdi, rcx
	je	.LBB46_1
# %bb.7:
	mov	esi, 4
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.LBB46_1:
	push	rbx
	cmp	rdi, rax
	jbe	.LBB46_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	rbx, rdi
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
	mov	rdi, rbx
.LBB46_3:
	mov	rbx, rdi
	lea	rax, [4*rdi]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB46_4
# %bb.5:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 4
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB46_4:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end46:
	.size	_xtc_new_float, .Lfunc_end46-_xtc_new_float
                                        # -- End function
	.globl	_xtc_new_double                 # -- Begin function _xtc_new_double
	.p2align	4, 0x90
	.type	_xtc_new_double,@function
_xtc_new_double:                        # @_xtc_new_double
# %bb.0:
	movabs	rax, 2305843009213562879
	lea	rcx, [rax + 122881]
	test	rdi, rcx
	je	.LBB47_1
# %bb.7:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.LBB47_1:
	push	rbx
	cmp	rdi, rax
	jbe	.LBB47_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	rbx, rdi
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
	mov	rdi, rbx
.LBB47_3:
	mov	rbx, rdi
	lea	rax, [8*rdi]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB47_4
# %bb.5:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 8
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB47_4:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end47:
	.size	_xtc_new_double, .Lfunc_end47-_xtc_new_double
                                        # -- End function
	.globl	_xtc_new_string                 # -- Begin function _xtc_new_string
	.p2align	4, 0x90
	.type	_xtc_new_string,@function
_xtc_new_string:                        # @_xtc_new_string
# %bb.0:
	push	rbx
	mov	rbx, rdi
	movabs	rax, 2305843009213562880
	cmp	rdi, rax
	jb	.LBB48_2
# %bb.1:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB48_2:
	lea	rax, [8*rbx]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB48_3
# %bb.4:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 8
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB48_3:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end48:
	.size	_xtc_new_string, .Lfunc_end48-_xtc_new_string
                                        # -- End function
	.globl	_xtc_count                      # -- Begin function _xtc_count
	.p2align	4, 0x90
	.type	_xtc_count,@function
_xtc_count:                             # @_xtc_count
# %bb.0:
	mov	eax, dword ptr [rdi - 28]
	ret
.Lfunc_end49:
	.size	_xtc_count, .Lfunc_end49-_xtc_count
                                        # -- End function
	.globl	_xtc_dealloc                    # -- Begin function _xtc_dealloc
	.p2align	4, 0x90
	.type	_xtc_dealloc,@function
_xtc_dealloc:                           # @_xtc_dealloc
# %bb.0:
	push	r15
	push	r14
	push	r13
	push	r12
	push	rbx
	mov	rbx, rdi
	test	rdi, rdi
	je	.LBB50_9
# %bb.1:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB50_4
	.p2align	4, 0x90
.LBB50_2:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB50_3 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_rt_spin], ecx
	test	ecx, ecx
	je	.LBB50_4
.LBB50_3:                               #   Parent Loop BB50_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_rt_spin]
	test	ecx, ecx
	jne	.LBB50_3
	jmp	.LBB50_2
.LBB50_4:
	mov	rcx, qword ptr [rbx - 12]
	test	rcx, rcx
	je	.LBB50_7
# %bb.5:
	xorps	xmm0, xmm0
	.p2align	4, 0x90
.LBB50_6:                               # =>This Inner Loop Header: Depth=1
	mov	rdx, qword ptr [rcx - 8]
	movups	xmmword ptr [rcx - 16], xmm0
	mov	qword ptr [rcx], 0
	mov	rcx, rdx
	test	rdx, rdx
	jne	.LBB50_6
.LBB50_7:
	mov	qword ptr [rbx - 12], 0
	cmp	dword ptr [rax], 0
	je	.LBB50_9
# %bb.8:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB50_9:
	mov	r15, qword ptr [rbx - 20]
	cmp	dword ptr [rbx - 40], 1481920323
	jne	.LBB50_36
# %bb.10:
	test	r15, r15
	je	.LBB50_12
# %bb.11:
	mov	rdi, rbx
	call	r15
.LBB50_12:
	mov	rdi, rbx
	call	_xtc_simd_unwatch@PLT
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB50_15
	.p2align	4, 0x90
.LBB50_13:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB50_14 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_rt_spin], ecx
	test	ecx, ecx
	je	.LBB50_15
.LBB50_14:                              #   Parent Loop BB50_13 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_rt_spin]
	test	ecx, ecx
	jne	.LBB50_14
	jmp	.LBB50_13
.LBB50_36:
	test	r15, r15
	je	.LBB50_40
# %bb.37:
	mov	r12, qword ptr [rbx - 36]
	mov	r13, qword ptr [rbx - 28]
	mov	dword ptr [rbx - 4], -2147483648
	test	r13, r13
	je	.LBB50_40
# %bb.38:
	mov	r14, rbx
	.p2align	4, 0x90
.LBB50_39:                              # =>This Inner Loop Header: Depth=1
	mov	rdi, r14
	call	r15
	add	r14, r12
	dec	r13
	jne	.LBB50_39
.LBB50_40:
	mov	rax, qword ptr [rbx - 48]
	add	rbx, -48
	cmp	rax, 64
	jae	.LBB50_41
# %bb.43:
	mov	rcx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rcx], 0
	jne	.LBB50_44
	jmp	.LBB50_46
	.p2align	4, 0x90
.LBB50_45:                              #   Parent Loop BB50_44 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	edx, dword ptr [rip + xt_alloc_spin]
	test	edx, edx
	jne	.LBB50_45
.LBB50_44:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB50_45 Depth 2
	mov	edx, 1
	xchg	dword ptr [rip + xt_alloc_spin], edx
	test	edx, edx
	jne	.LBB50_45
.LBB50_46:
	lea	rdx, [rip + xt_cache_n]
	mov	esi, dword ptr [rdx + 4*rax]
	cmp	esi, 64
	jb	.LBB50_49
# %bb.47:
	cmp	dword ptr [rcx], 0
	je	.LBB50_41
# %bb.48:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB50_41:
	mov	rdi, rbx
	jmp	.LBB50_42
.LBB50_15:
	mov	rcx, qword ptr [rip + xt_simd_n]
	test	rcx, rcx
	je	.LBB50_16
# %bb.17:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	xor	edx, edx
	movabs	rdi, 2305843009213693950
	mov	r8, rcx
	.p2align	4, 0x90
.LBB50_18:                              # =>This Inner Loop Header: Depth=1
	lea	r9, [r8 + rdx]
	mov	r10, r9
	shr	r10
	and	r9, rdi
	cmp	qword ptr [rsi + 8*r9], rbx
	lea	r9, [r10 + 1]
	cmova	r8, r10
	cmovbe	rdx, r9
	cmp	rdx, r8
	jb	.LBB50_18
# %bb.19:
	test	rdx, rdx
	jne	.LBB50_20
	jmp	.LBB50_25
.LBB50_16:
	xor	edx, edx
	test	rdx, rdx
	je	.LBB50_25
.LBB50_20:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	mov	r8, rdx
	shl	r8, 4
	cmp	qword ptr [rsi + r8 - 16], rbx
	jne	.LBB50_25
# %bb.21:
	cmp	rdx, rcx
	jae	.LBB50_24
# %bb.22:
	mov	rdi, qword ptr [rip + xt_simd_flag]
	add	rsi, r8
	.p2align	4, 0x90
.LBB50_23:                              # =>This Inner Loop Header: Depth=1
	movups	xmm0, xmmword ptr [rsi]
	movups	xmmword ptr [rsi - 16], xmm0
	movzx	r8d, byte ptr [rdi + rdx]
	mov	byte ptr [rdi + rdx - 1], r8b
	inc	rdx
	add	rsi, 16
	cmp	rcx, rdx
	jne	.LBB50_23
.LBB50_24:
	dec	rcx
	mov	qword ptr [rip + xt_simd_n], rcx
.LBB50_25:
	cmp	dword ptr [rax], 0
	je	.LBB50_27
# %bb.26:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB50_27:
	mov	rdi, qword ptr [rbx - 48]
	test	rdi, rdi
	je	.LBB50_51
# %bb.28:
	mov	rcx, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rcx, 64
	jae	.LBB50_42
# %bb.29:
	cmp	dword ptr [rax], 0
	je	.LBB50_32
	.p2align	4, 0x90
.LBB50_30:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB50_31 Depth 2
	mov	edx, 1
	xchg	dword ptr [rip + xt_alloc_spin], edx
	test	edx, edx
	je	.LBB50_32
.LBB50_31:                              #   Parent Loop BB50_30 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	edx, dword ptr [rip + xt_alloc_spin]
	test	edx, edx
	jne	.LBB50_31
	jmp	.LBB50_30
.LBB50_32:
	lea	rdx, [rip + xt_cache_n]
	mov	esi, dword ptr [rdx + 4*rcx]
	cmp	esi, 64
	jb	.LBB50_35
# %bb.33:
	cmp	dword ptr [rax], 0
	je	.LBB50_42
# %bb.34:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB50_42:
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	jmp	free@PLT                        # TAILCALL
.LBB50_49:
	lea	rdi, [rip + xt_cache]
	mov	r8, qword ptr [rdi + 8*rax]
	mov	qword ptr [rbx], r8
	mov	qword ptr [rdi + 8*rax], rbx
	inc	esi
	mov	dword ptr [rdx + 4*rax], esi
	cmp	dword ptr [rcx], 0
	je	.LBB50_51
.LBB50_50:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB50_51:
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	ret
.LBB50_35:
	lea	r8, [rip + xt_cache]
	mov	r9, qword ptr [r8 + 8*rcx]
	mov	qword ptr [rdi], r9
	mov	qword ptr [r8 + 8*rcx], rdi
	inc	esi
	mov	dword ptr [rdx + 4*rcx], esi
	cmp	dword ptr [rax], 0
	jne	.LBB50_50
	jmp	.LBB50_51
.Lfunc_end50:
	.size	_xtc_dealloc, .Lfunc_end50-_xtc_dealloc
                                        # -- End function
	.globl	_xtc_weak_zero_for              # -- Begin function _xtc_weak_zero_for
	.p2align	4, 0x90
	.type	_xtc_weak_zero_for,@function
_xtc_weak_zero_for:                     # @_xtc_weak_zero_for
# %bb.0:
	test	rdi, rdi
	je	.LBB51_9
# %bb.1:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB51_4
	.p2align	4, 0x90
.LBB51_2:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB51_3 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_rt_spin], ecx
	test	ecx, ecx
	je	.LBB51_4
.LBB51_3:                               #   Parent Loop BB51_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_rt_spin]
	test	ecx, ecx
	jne	.LBB51_3
	jmp	.LBB51_2
.LBB51_4:
	mov	rcx, qword ptr [rdi - 12]
	test	rcx, rcx
	je	.LBB51_7
# %bb.5:
	xorps	xmm0, xmm0
	.p2align	4, 0x90
.LBB51_6:                               # =>This Inner Loop Header: Depth=1
	mov	rdx, qword ptr [rcx - 8]
	movups	xmmword ptr [rcx - 16], xmm0
	mov	qword ptr [rcx], 0
	mov	rcx, rdx
	test	rdx, rdx
	jne	.LBB51_6
.LBB51_7:
	mov	qword ptr [rdi - 12], 0
	cmp	dword ptr [rax], 0
	je	.LBB51_9
# %bb.8:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB51_9:
	ret
.Lfunc_end51:
	.size	_xtc_weak_zero_for, .Lfunc_end51-_xtc_weak_zero_for
                                        # -- End function
	.globl	_xtc_weak_unregister            # -- Begin function _xtc_weak_unregister
	.p2align	4, 0x90
	.type	_xtc_weak_unregister,@function
_xtc_weak_unregister:                   # @_xtc_weak_unregister
# %bb.0:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB52_3
	.p2align	4, 0x90
.LBB52_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB52_2 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_rt_spin], ecx
	test	ecx, ecx
	je	.LBB52_3
.LBB52_2:                               #   Parent Loop BB52_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_rt_spin]
	test	ecx, ecx
	jne	.LBB52_2
	jmp	.LBB52_1
.LBB52_3:
	mov	rcx, qword ptr [rdi - 16]
	test	rcx, rcx
	je	.LBB52_8
# %bb.4:
	lea	rdx, [rdi - 16]
	cmp	qword ptr [rcx], rdi
	jne	.LBB52_7
# %bb.5:
	mov	rsi, qword ptr [rdi - 8]
	mov	qword ptr [rcx], rsi
	test	rsi, rsi
	je	.LBB52_7
# %bb.6:
	mov	qword ptr [rsi - 16], rcx
.LBB52_7:
	xorps	xmm0, xmm0
	movups	xmmword ptr [rdx], xmm0
.LBB52_8:
	cmp	dword ptr [rax], 0
	je	.LBB52_10
# %bb.9:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB52_10:
	ret
.Lfunc_end52:
	.size	_xtc_weak_unregister, .Lfunc_end52-_xtc_weak_unregister
                                        # -- End function
	.globl	_xtc_weak_register              # -- Begin function _xtc_weak_register
	.p2align	4, 0x90
	.type	_xtc_weak_register,@function
_xtc_weak_register:                     # @_xtc_weak_register
# %bb.0:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB53_3
	.p2align	4, 0x90
.LBB53_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB53_2 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_rt_spin], ecx
	test	ecx, ecx
	je	.LBB53_3
.LBB53_2:                               #   Parent Loop BB53_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_rt_spin]
	test	ecx, ecx
	jne	.LBB53_2
	jmp	.LBB53_1
.LBB53_3:
	mov	rcx, qword ptr [rdi - 16]
	test	rcx, rcx
	je	.LBB53_8
# %bb.4:
	lea	rdx, [rdi - 16]
	cmp	qword ptr [rcx], rdi
	jne	.LBB53_7
# %bb.5:
	mov	r8, qword ptr [rdi - 8]
	mov	qword ptr [rcx], r8
	test	r8, r8
	je	.LBB53_7
# %bb.6:
	mov	qword ptr [r8 - 16], rcx
.LBB53_7:
	xorps	xmm0, xmm0
	movups	xmmword ptr [rdx], xmm0
.LBB53_8:
	test	rsi, rsi
	je	.LBB53_13
# %bb.9:
	cmp	dword ptr [rsi - 40], 1481920322
	jne	.LBB53_13
# %bb.10:
	mov	rcx, qword ptr [rsi - 12]
	add	rsi, -12
	mov	qword ptr [rdi - 16], rsi
	mov	qword ptr [rdi - 8], rcx
	test	rcx, rcx
	je	.LBB53_12
# %bb.11:
	lea	rdx, [rdi - 8]
	mov	qword ptr [rcx - 16], rdx
.LBB53_12:
	mov	qword ptr [rsi], rdi
.LBB53_13:
	cmp	dword ptr [rax], 0
	je	.LBB53_15
# %bb.14:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB53_15:
	ret
.Lfunc_end53:
	.size	_xtc_weak_register, .Lfunc_end53-_xtc_weak_register
                                        # -- End function
	.globl	_xtc_weak_load                  # -- Begin function _xtc_weak_load
	.p2align	4, 0x90
	.type	_xtc_weak_load,@function
_xtc_weak_load:                         # @_xtc_weak_load
# %bb.0:
	mov	rax, qword ptr [rdi]
	ret
.Lfunc_end54:
	.size	_xtc_weak_load, .Lfunc_end54-_xtc_weak_load
                                        # -- End function
	.globl	srandom                         # -- Begin function srandom
	.p2align	4, 0x90
	.type	srandom,@function
srandom:                                # @srandom
# %bb.0:
                                        # kill: def $edi killed $edi def $rdi
	cmp	edi, 1
	adc	edi, 0
	mov	qword ptr [rip + xt_rand_state], rdi
	ret
.Lfunc_end55:
	.size	srandom, .Lfunc_end55-srandom
                                        # -- End function
	.globl	random                          # -- Begin function random
	.p2align	4, 0x90
	.type	random,@function
random:                                 # @random
# %bb.0:
	mov	rax, qword ptr [rip + xt_rand_state]
	mov	rcx, rax
	shl	rcx, 13
	xor	rcx, rax
	mov	rdx, rcx
	shr	rdx, 7
	xor	rdx, rcx
	mov	rax, rdx
	shl	rax, 17
	xor	rax, rdx
	mov	qword ptr [rip + xt_rand_state], rax
	shr	rax, 17
	and	eax, 2147483647
	ret
.Lfunc_end56:
	.size	random, .Lfunc_end56-random
                                        # -- End function
	.globl	_xt_srand                       # -- Begin function _xt_srand
	.p2align	4, 0x90
	.type	_xt_srand,@function
_xt_srand:                              # @_xt_srand
# %bb.0:
                                        # kill: def $edi killed $edi def $rdi
	cmp	edi, 1
	adc	edi, 0
	mov	qword ptr [rip + xt_rand_state], rdi
	ret
.Lfunc_end57:
	.size	_xt_srand, .Lfunc_end57-_xt_srand
                                        # -- End function
	.globl	_xt_rand_u32                    # -- Begin function _xt_rand_u32
	.p2align	4, 0x90
	.type	_xt_rand_u32,@function
_xt_rand_u32:                           # @_xt_rand_u32
# %bb.0:
	mov	rax, qword ptr [rip + xt_rand_state]
	mov	rcx, rax
	shl	rcx, 13
	xor	rcx, rax
	mov	rax, rcx
	shr	rax, 7
	xor	rax, rcx
	mov	rcx, rax
	shl	rcx, 17
	xor	rcx, rax
	mov	rax, rcx
	shl	rax, 13
	xor	rax, rcx
	shr	rcx
	and	ecx, -65536
	mov	rdx, rax
	shr	rdx, 7
	xor	rdx, rax
	mov	rax, rdx
	shl	rax, 17
	xor	rax, rdx
	mov	qword ptr [rip + xt_rand_state], rax
	shr	rax, 17
	and	eax, 2147483647
	xor	eax, ecx
                                        # kill: def $eax killed $eax killed $rax
	ret
.Lfunc_end58:
	.size	_xt_rand_u32, .Lfunc_end58-_xt_rand_u32
                                        # -- End function
	.section	.rodata.cst4,"aM",@progbits,4
	.p2align	2, 0x0                          # -- Begin function _xt_rand_f
.LCPI59_0:
	.long	0x30000000                      # float 4.65661287E-10
.LCPI59_1:
	.long	0x3f000000                      # float 0.5
	.text
	.globl	_xt_rand_f
	.p2align	4, 0x90
	.type	_xt_rand_f,@function
_xt_rand_f:                             # @_xt_rand_f
# %bb.0:
	mov	rax, qword ptr [rip + xt_rand_state]
	mov	rcx, rax
	shl	rcx, 13
	xor	rcx, rax
	mov	rax, rcx
	shr	rax, 7
	xor	rax, rcx
	mov	rcx, rax
	shl	rcx, 17
	xor	rcx, rax
	mov	qword ptr [rip + xt_rand_state], rcx
	shr	rcx, 17
	and	ecx, 2147483647
	cvtsi2ss	xmm0, ecx
	mulss	xmm0, dword ptr [rip + .LCPI59_0]
	movss	xmm1, dword ptr [rip + .LCPI59_1] # xmm1 = [5.0E-1,0.0E+0,0.0E+0,0.0E+0]
	mulss	xmm0, xmm1
	addss	xmm0, xmm1
	ret
.Lfunc_end59:
	.size	_xt_rand_f, .Lfunc_end59-_xt_rand_f
                                        # -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          # -- Begin function _xt_rand_d
.LCPI60_0:
	.quad	0x3e00000000000000              # double 4.6566128730773926E-10
.LCPI60_1:
	.quad	0x3fe0000000000000              # double 0.5
	.text
	.globl	_xt_rand_d
	.p2align	4, 0x90
	.type	_xt_rand_d,@function
_xt_rand_d:                             # @_xt_rand_d
# %bb.0:
	mov	rax, qword ptr [rip + xt_rand_state]
	mov	rcx, rax
	shl	rcx, 13
	xor	rcx, rax
	mov	rax, rcx
	shr	rax, 7
	xor	rax, rcx
	mov	rcx, rax
	shl	rcx, 17
	xor	rcx, rax
	mov	qword ptr [rip + xt_rand_state], rcx
	shr	rcx, 17
	and	ecx, 2147483647
	cvtsi2sd	xmm0, ecx
	mulsd	xmm0, qword ptr [rip + .LCPI60_0]
	movsd	xmm1, qword ptr [rip + .LCPI60_1] # xmm1 = [5.0E-1,0.0E+0]
	mulsd	xmm0, xmm1
	addsd	xmm0, xmm1
	ret
.Lfunc_end60:
	.size	_xt_rand_d, .Lfunc_end60-_xt_rand_d
                                        # -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          # -- Begin function _xt_clk_reset
.LCPI61_0:
	.quad	0x3e112e0be826d695              # double 1.0000000000000001E-9
	.text
	.globl	_xt_clk_reset
	.p2align	4, 0x90
	.type	_xt_clk_reset,@function
_xt_clk_reset:                          # @_xt_clk_reset
# %bb.0:
	sub	rsp, 24
	mov	rsi, rsp
	mov	edi, 1
	call	clock_gettime@PLT
	cvtsi2sd	xmm0, qword ptr [rsp]
	cvtsi2sd	xmm1, qword ptr [rsp + 8]
	mulsd	xmm1, qword ptr [rip + .LCPI61_0]
	addsd	xmm1, xmm0
	movsd	qword ptr [rip + xt_clk_origin], xmm1
	add	rsp, 24
	ret
.Lfunc_end61:
	.size	_xt_clk_reset, .Lfunc_end61-_xt_clk_reset
                                        # -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          # -- Begin function _xt_clk_ticks
.LCPI62_0:
	.quad	0x3e112e0be826d695              # double 1.0000000000000001E-9
.LCPI62_1:
	.quad	0x412e848000000000              # double 1.0E+6
	.text
	.globl	_xt_clk_ticks
	.p2align	4, 0x90
	.type	_xt_clk_ticks,@function
_xt_clk_ticks:                          # @_xt_clk_ticks
# %bb.0:
	sub	rsp, 24
	mov	rsi, rsp
	mov	edi, 1
	call	clock_gettime@PLT
	cvtsi2sd	xmm0, qword ptr [rsp]
	cvtsi2sd	xmm1, qword ptr [rsp + 8]
	mulsd	xmm1, qword ptr [rip + .LCPI62_0]
	addsd	xmm1, xmm0
	subsd	xmm1, qword ptr [rip + xt_clk_origin]
	mulsd	xmm1, qword ptr [rip + .LCPI62_1]
	cvttsd2si	rax, xmm1
                                        # kill: def $eax killed $eax killed $rax
	add	rsp, 24
	ret
.Lfunc_end62:
	.size	_xt_clk_ticks, .Lfunc_end62-_xt_clk_ticks
                                        # -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          # -- Begin function _xt_clk_delay
.LCPI63_0:
	.quad	0x404e000000000000              # double 60
.LCPI63_1:
	.quad	0x41cdcd6500000000              # double 1.0E+9
.LCPI63_2:
	.quad	0x43e0000000000000              # double 9.2233720368547758E+18
	.text
	.globl	_xt_clk_delay
	.p2align	4, 0x90
	.type	_xt_clk_delay,@function
_xt_clk_delay:                          # @_xt_clk_delay
# %bb.0:
	sub	rsp, 24
	mov	eax, edi
	cvtsi2sd	xmm0, rax
	divsd	xmm0, qword ptr [rip + .LCPI63_0]
	mulsd	xmm0, qword ptr [rip + .LCPI63_1]
	cvttsd2si	rax, xmm0
	mov	rcx, rax
	sar	rcx, 63
	subsd	xmm0, qword ptr [rip + .LCPI63_2]
	cvttsd2si	rsi, xmm0
	and	rsi, rcx
	or	rsi, rax
	mov	rax, rsi
	shr	rax, 9
	movabs	rcx, 19342813113834067
	mul	rcx
	shr	rdx, 11
	mov	qword ptr [rsp], rdx
	imul	rax, rdx, 1000000000
	sub	rsi, rax
	mov	qword ptr [rsp + 8], rsi
	mov	rdi, rsp
	xor	esi, esi
	call	nanosleep@PLT
	add	rsp, 24
	ret
.Lfunc_end63:
	.size	_xt_clk_delay, .Lfunc_end63-_xt_clk_delay
                                        # -- End function
	.globl	_xtc_bank                       # -- Begin function _xtc_bank
	.p2align	4, 0x90
	.type	_xtc_bank,@function
_xtc_bank:                              # @_xtc_bank
# %bb.0:
	cmp	dil, 1
	jbe	.LBB64_2
# %bb.1:
	xor	eax, eax
	ret
.LBB64_2:
	push	rbx
	movzx	eax, dil
	shl	eax, 11
	lea	rcx, [rip + xt_bank_regions]
	add	rcx, rax
	movzx	eax, sil
	lea	rbx, [rcx + 8*rax]
	cmp	qword ptr [rcx + 8*rax], 0
	jne	.LBB64_7
# %bb.3:
	mov	edi, 1
	mov	esi, 12296
	call	calloc@PLT
	test	rax, rax
	je	.LBB64_4
# %bb.5:
	mov	qword ptr [rax], 64
	add	rax, 8
	jmp	.LBB64_6
.LBB64_4:
	xor	eax, eax
.LBB64_6:
	mov	qword ptr [rbx], rax
.LBB64_7:
	mov	rax, qword ptr [rbx]
	pop	rbx
	ret
.Lfunc_end64:
	.size	_xtc_bank, .Lfunc_end64-_xtc_bank
                                        # -- End function
	.globl	_xt_threads_multi               # -- Begin function _xt_threads_multi
	.p2align	4, 0x90
	.type	_xt_threads_multi,@function
_xt_threads_multi:                      # @_xt_threads_multi
# %bb.0:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	mov	eax, dword ptr [rax]
	ret
.Lfunc_end65:
	.size	_xt_threads_multi, .Lfunc_end65-_xt_threads_multi
                                        # -- End function
	.globl	_xt_thread_create               # -- Begin function _xt_thread_create
	.p2align	4, 0x90
	.type	_xt_thread_create,@function
_xt_thread_create:                      # @_xt_thread_create
# %bb.0:
	push	r15
	push	r14
	push	r12
	push	rbx
	push	rax
	test	rdi, rdi
	je	.LBB66_4
# %bb.1:
	mov	r15, rsi
	mov	r12, rdi
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	mov	dword ptr [rax], 1
	mov	edi, 16
	call	malloc@PLT
	mov	r14, rax
	mov	edi, 8
	call	malloc@PLT
	mov	rbx, rax
	test	r14, r14
	sete	al
	test	rbx, rbx
	sete	cl
	or	cl, al
	jne	.LBB66_3
# %bb.2:
	mov	qword ptr [r14], r12
	mov	qword ptr [r14 + 8], r15
	lea	rdx, [rip + xt_gthread_entry]
	mov	rdi, rbx
	xor	esi, esi
	mov	rcx, r14
	call	pthread_create@PLT
	test	eax, eax
	je	.LBB66_5
.LBB66_3:
	mov	rdi, r14
	call	free@PLT
	mov	rdi, rbx
	call	free@PLT
.LBB66_4:
	xor	ebx, ebx
.LBB66_5:
	mov	rax, rbx
	add	rsp, 8
	pop	rbx
	pop	r12
	pop	r14
	pop	r15
	ret
.Lfunc_end66:
	.size	_xt_thread_create, .Lfunc_end66-_xt_thread_create
                                        # -- End function
	.p2align	4, 0x90                         # -- Begin function xt_gthread_entry
	.type	xt_gthread_entry,@function
xt_gthread_entry:                       # @xt_gthread_entry
# %bb.0:
	push	r14
	push	rbx
	push	rax
	mov	r14, qword ptr [rdi]
	mov	rbx, qword ptr [rdi + 8]
	call	free@PLT
	test	r14, r14
	je	.LBB67_2
# %bb.1:
	mov	rdi, rbx
	call	r14
.LBB67_2:
	xor	eax, eax
	add	rsp, 8
	pop	rbx
	pop	r14
	ret
.Lfunc_end67:
	.size	xt_gthread_entry, .Lfunc_end67-xt_gthread_entry
                                        # -- End function
	.globl	_xt_thread_join                 # -- Begin function _xt_thread_join
	.p2align	4, 0x90
	.type	_xt_thread_join,@function
_xt_thread_join:                        # @_xt_thread_join
# %bb.0:
	test	rdi, rdi
	je	.LBB68_1
# %bb.2:
	push	rbp
	push	rbx
	push	rax
	mov	qword ptr [rsp], 0
	mov	rax, qword ptr [rdi]
	mov	rsi, rsp
	mov	rbx, rdi
	mov	rdi, rax
	call	pthread_join@PLT
	mov	ebp, eax
	mov	rdi, rbx
	call	free@PLT
	xor	eax, eax
	neg	ebp
	sbb	eax, eax
	add	rsp, 8
	pop	rbx
	pop	rbp
	ret
.LBB68_1:
	mov	eax, -1
	ret
.Lfunc_end68:
	.size	_xt_thread_join, .Lfunc_end68-_xt_thread_join
                                        # -- End function
	.globl	_xt_thread_detach               # -- Begin function _xt_thread_detach
	.p2align	4, 0x90
	.type	_xt_thread_detach,@function
_xt_thread_detach:                      # @_xt_thread_detach
# %bb.0:
	test	rdi, rdi
	je	.LBB69_1
# %bb.2:
	push	rbx
	mov	rax, qword ptr [rdi]
	mov	rbx, rdi
	mov	rdi, rax
	call	pthread_detach@PLT
	mov	rdi, rbx
	pop	rbx
	jmp	free@PLT                        # TAILCALL
.LBB69_1:
	ret
.Lfunc_end69:
	.size	_xt_thread_detach, .Lfunc_end69-_xt_thread_detach
                                        # -- End function
	.globl	_xt_thread_yield                # -- Begin function _xt_thread_yield
	.p2align	4, 0x90
	.type	_xt_thread_yield,@function
_xt_thread_yield:                       # @_xt_thread_yield
# %bb.0:
	jmp	sched_yield@PLT                 # TAILCALL
.Lfunc_end70:
	.size	_xt_thread_yield, .Lfunc_end70-_xt_thread_yield
                                        # -- End function
	.globl	_xt_thread_sleep_ms             # -- Begin function _xt_thread_sleep_ms
	.p2align	4, 0x90
	.type	_xt_thread_sleep_ms,@function
_xt_thread_sleep_ms:                    # @_xt_thread_sleep_ms
# %bb.0:
	sub	rsp, 24
	mov	ecx, edi
	movabs	rdx, 18446744073709552
	mov	rax, rcx
	mul	rdx
	imul	rcx, rcx, 1000000
	mov	qword ptr [rsp], rdx
	movabs	rdx, 4835703278458517
	mov	rax, rcx
	mul	rdx
	shr	rdx, 18
	imul	rax, rdx, 1000000000
	sub	rcx, rax
	mov	qword ptr [rsp + 8], rcx
	mov	rdi, rsp
	xor	esi, esi
	call	nanosleep@PLT
	add	rsp, 24
	ret
.Lfunc_end71:
	.size	_xt_thread_sleep_ms, .Lfunc_end71-_xt_thread_sleep_ms
                                        # -- End function
	.globl	_xt_thread_self_id              # -- Begin function _xt_thread_self_id
	.p2align	4, 0x90
	.type	_xt_thread_self_id,@function
_xt_thread_self_id:                     # @_xt_thread_self_id
# %bb.0:
	push	rax
	call	pthread_self@PLT
	mov	rcx, rax
	shr	rcx, 4
	shr	rax, 32
	xor	eax, ecx
                                        # kill: def $eax killed $eax killed $rax
	pop	rcx
	ret
.Lfunc_end72:
	.size	_xt_thread_self_id, .Lfunc_end72-_xt_thread_self_id
                                        # -- End function
	.globl	_xt_thread_cpu_count            # -- Begin function _xt_thread_cpu_count
	.p2align	4, 0x90
	.type	_xt_thread_cpu_count,@function
_xt_thread_cpu_count:                   # @_xt_thread_cpu_count
# %bb.0:
	push	rax
	mov	edi, 84
	call	sysconf@PLT
	test	rax, rax
	mov	ecx, 1
	cmovle	eax, ecx
                                        # kill: def $eax killed $eax killed $rax
	pop	rcx
	ret
.Lfunc_end73:
	.size	_xt_thread_cpu_count, .Lfunc_end73-_xt_thread_cpu_count
                                        # -- End function
	.globl	_xt_mutex_new                   # -- Begin function _xt_mutex_new
	.p2align	4, 0x90
	.type	_xt_mutex_new,@function
_xt_mutex_new:                          # @_xt_mutex_new
# %bb.0:
	push	rbx
	mov	edi, 40
	call	malloc@PLT
	test	rax, rax
	je	.LBB74_4
# %bb.1:
	mov	rbx, rax
	mov	rdi, rax
	xor	esi, esi
	call	pthread_mutex_init@PLT
	test	eax, eax
	je	.LBB74_2
# %bb.3:
	mov	rdi, rbx
	call	free@PLT
	xor	eax, eax
.LBB74_4:
	pop	rbx
	ret
.LBB74_2:
	mov	rax, rbx
	pop	rbx
	ret
.Lfunc_end74:
	.size	_xt_mutex_new, .Lfunc_end74-_xt_mutex_new
                                        # -- End function
	.globl	_xt_mutex_free                  # -- Begin function _xt_mutex_free
	.p2align	4, 0x90
	.type	_xt_mutex_free,@function
_xt_mutex_free:                         # @_xt_mutex_free
# %bb.0:
	test	rdi, rdi
	je	.LBB75_1
# %bb.2:
	push	rbx
	mov	rbx, rdi
	call	pthread_mutex_destroy@PLT
	mov	rdi, rbx
	pop	rbx
	jmp	free@PLT                        # TAILCALL
.LBB75_1:
	ret
.Lfunc_end75:
	.size	_xt_mutex_free, .Lfunc_end75-_xt_mutex_free
                                        # -- End function
	.globl	_xt_mutex_lock                  # -- Begin function _xt_mutex_lock
	.p2align	4, 0x90
	.type	_xt_mutex_lock,@function
_xt_mutex_lock:                         # @_xt_mutex_lock
# %bb.0:
	test	rdi, rdi
	jne	pthread_mutex_lock@PLT          # TAILCALL
# %bb.1:
	ret
.Lfunc_end76:
	.size	_xt_mutex_lock, .Lfunc_end76-_xt_mutex_lock
                                        # -- End function
	.globl	_xt_mutex_unlock                # -- Begin function _xt_mutex_unlock
	.p2align	4, 0x90
	.type	_xt_mutex_unlock,@function
_xt_mutex_unlock:                       # @_xt_mutex_unlock
# %bb.0:
	test	rdi, rdi
	jne	pthread_mutex_unlock@PLT        # TAILCALL
# %bb.1:
	ret
.Lfunc_end77:
	.size	_xt_mutex_unlock, .Lfunc_end77-_xt_mutex_unlock
                                        # -- End function
	.globl	_xt_mutex_trylock               # -- Begin function _xt_mutex_trylock
	.p2align	4, 0x90
	.type	_xt_mutex_trylock,@function
_xt_mutex_trylock:                      # @_xt_mutex_trylock
# %bb.0:
	test	rdi, rdi
	je	.LBB78_1
# %bb.2:
	push	rax
	call	pthread_mutex_trylock@PLT
	mov	ecx, eax
	xor	eax, eax
	test	ecx, ecx
	sete	al
	add	rsp, 8
	ret
.LBB78_1:
	xor	eax, eax
	ret
.Lfunc_end78:
	.size	_xt_mutex_trylock, .Lfunc_end78-_xt_mutex_trylock
                                        # -- End function
	.globl	_xt_cond_new                    # -- Begin function _xt_cond_new
	.p2align	4, 0x90
	.type	_xt_cond_new,@function
_xt_cond_new:                           # @_xt_cond_new
# %bb.0:
	push	rbx
	mov	edi, 48
	call	malloc@PLT
	test	rax, rax
	je	.LBB79_4
# %bb.1:
	mov	rbx, rax
	mov	rdi, rax
	xor	esi, esi
	call	pthread_cond_init@PLT
	test	eax, eax
	je	.LBB79_2
# %bb.3:
	mov	rdi, rbx
	call	free@PLT
	xor	eax, eax
.LBB79_4:
	pop	rbx
	ret
.LBB79_2:
	mov	rax, rbx
	pop	rbx
	ret
.Lfunc_end79:
	.size	_xt_cond_new, .Lfunc_end79-_xt_cond_new
                                        # -- End function
	.globl	_xt_cond_free                   # -- Begin function _xt_cond_free
	.p2align	4, 0x90
	.type	_xt_cond_free,@function
_xt_cond_free:                          # @_xt_cond_free
# %bb.0:
	test	rdi, rdi
	je	.LBB80_1
# %bb.2:
	push	rbx
	mov	rbx, rdi
	call	pthread_cond_destroy@PLT
	mov	rdi, rbx
	pop	rbx
	jmp	free@PLT                        # TAILCALL
.LBB80_1:
	ret
.Lfunc_end80:
	.size	_xt_cond_free, .Lfunc_end80-_xt_cond_free
                                        # -- End function
	.globl	_xt_cond_wait                   # -- Begin function _xt_cond_wait
	.p2align	4, 0x90
	.type	_xt_cond_wait,@function
_xt_cond_wait:                          # @_xt_cond_wait
# %bb.0:
	test	rdi, rdi
	sete	al
	test	rsi, rsi
	sete	cl
	or	cl, al
	je	pthread_cond_wait@PLT           # TAILCALL
# %bb.1:
	ret
.Lfunc_end81:
	.size	_xt_cond_wait, .Lfunc_end81-_xt_cond_wait
                                        # -- End function
	.globl	_xt_cond_signal                 # -- Begin function _xt_cond_signal
	.p2align	4, 0x90
	.type	_xt_cond_signal,@function
_xt_cond_signal:                        # @_xt_cond_signal
# %bb.0:
	test	rdi, rdi
	jne	pthread_cond_signal@PLT         # TAILCALL
# %bb.1:
	ret
.Lfunc_end82:
	.size	_xt_cond_signal, .Lfunc_end82-_xt_cond_signal
                                        # -- End function
	.globl	_xt_cond_broadcast              # -- Begin function _xt_cond_broadcast
	.p2align	4, 0x90
	.type	_xt_cond_broadcast,@function
_xt_cond_broadcast:                     # @_xt_cond_broadcast
# %bb.0:
	test	rdi, rdi
	jne	pthread_cond_broadcast@PLT      # TAILCALL
# %bb.1:
	ret
.Lfunc_end83:
	.size	_xt_cond_broadcast, .Lfunc_end83-_xt_cond_broadcast
                                        # -- End function
	.globl	_xt_sem_new                     # -- Begin function _xt_sem_new
	.p2align	4, 0x90
	.type	_xt_sem_new,@function
_xt_sem_new:                            # @_xt_sem_new
# %bb.0:
	push	rbp
	push	r14
	push	rbx
	mov	ebp, edi
	mov	edi, 96
	call	malloc@PLT
	xor	ebx, ebx
	test	rax, rax
	je	.LBB84_2
# %bb.1:
	mov	rdi, rax
	xor	esi, esi
	mov	r14, rax
	call	pthread_mutex_init@PLT
	mov	rdi, r14
	add	rdi, 40
	xor	esi, esi
	call	pthread_cond_init@PLT
	test	ebp, ebp
	cmovg	ebx, ebp
	mov	dword ptr [r14 + 88], ebx
	mov	rbx, r14
.LBB84_2:
	mov	rax, rbx
	pop	rbx
	pop	r14
	pop	rbp
	ret
.Lfunc_end84:
	.size	_xt_sem_new, .Lfunc_end84-_xt_sem_new
                                        # -- End function
	.globl	_xt_sem_free                    # -- Begin function _xt_sem_free
	.p2align	4, 0x90
	.type	_xt_sem_free,@function
_xt_sem_free:                           # @_xt_sem_free
# %bb.0:
	test	rdi, rdi
	je	.LBB85_1
# %bb.2:
	push	rbx
	lea	rax, [rdi + 40]
	mov	rbx, rdi
	mov	rdi, rax
	call	pthread_cond_destroy@PLT
	mov	rdi, rbx
	call	pthread_mutex_destroy@PLT
	mov	rdi, rbx
	pop	rbx
	jmp	free@PLT                        # TAILCALL
.LBB85_1:
	ret
.Lfunc_end85:
	.size	_xt_sem_free, .Lfunc_end85-_xt_sem_free
                                        # -- End function
	.globl	_xt_sem_wait                    # -- Begin function _xt_sem_wait
	.p2align	4, 0x90
	.type	_xt_sem_wait,@function
_xt_sem_wait:                           # @_xt_sem_wait
# %bb.0:
	test	rdi, rdi
	je	.LBB86_5
# %bb.1:
	push	r14
	push	rbx
	push	rax
	mov	rbx, rdi
	call	pthread_mutex_lock@PLT
	mov	eax, dword ptr [rbx + 88]
	test	eax, eax
	jg	.LBB86_4
# %bb.2:
	lea	r14, [rbx + 40]
	.p2align	4, 0x90
.LBB86_3:                               # =>This Inner Loop Header: Depth=1
	mov	rdi, r14
	mov	rsi, rbx
	call	pthread_cond_wait@PLT
	mov	eax, dword ptr [rbx + 88]
	test	eax, eax
	jle	.LBB86_3
.LBB86_4:
	dec	eax
	mov	dword ptr [rbx + 88], eax
	mov	rdi, rbx
	add	rsp, 8
	pop	rbx
	pop	r14
	jmp	pthread_mutex_unlock@PLT        # TAILCALL
.LBB86_5:
	ret
.Lfunc_end86:
	.size	_xt_sem_wait, .Lfunc_end86-_xt_sem_wait
                                        # -- End function
	.globl	_xt_sem_trywait                 # -- Begin function _xt_sem_trywait
	.p2align	4, 0x90
	.type	_xt_sem_trywait,@function
_xt_sem_trywait:                        # @_xt_sem_trywait
# %bb.0:
	push	rbp
	push	rbx
	push	rax
	test	rdi, rdi
	je	.LBB87_1
# %bb.2:
	mov	rbx, rdi
	call	pthread_mutex_lock@PLT
	mov	eax, dword ptr [rbx + 88]
	test	eax, eax
	jle	.LBB87_3
# %bb.4:
	dec	eax
	mov	dword ptr [rbx + 88], eax
	mov	ebp, 1
	jmp	.LBB87_5
.LBB87_1:
	xor	ebp, ebp
	jmp	.LBB87_6
.LBB87_3:
	xor	ebp, ebp
.LBB87_5:
	mov	rdi, rbx
	call	pthread_mutex_unlock@PLT
.LBB87_6:
	mov	eax, ebp
	add	rsp, 8
	pop	rbx
	pop	rbp
	ret
.Lfunc_end87:
	.size	_xt_sem_trywait, .Lfunc_end87-_xt_sem_trywait
                                        # -- End function
	.globl	_xt_sem_post                    # -- Begin function _xt_sem_post
	.p2align	4, 0x90
	.type	_xt_sem_post,@function
_xt_sem_post:                           # @_xt_sem_post
# %bb.0:
	test	rdi, rdi
	je	.LBB88_1
# %bb.2:
	push	rbx
	mov	rbx, rdi
	call	pthread_mutex_lock@PLT
	inc	dword ptr [rbx + 88]
	lea	rdi, [rbx + 40]
	call	pthread_cond_signal@PLT
	mov	rdi, rbx
	pop	rbx
	jmp	pthread_mutex_unlock@PLT        # TAILCALL
.LBB88_1:
	ret
.Lfunc_end88:
	.size	_xt_sem_post, .Lfunc_end88-_xt_sem_post
                                        # -- End function
	.globl	_xt_tls_new                     # -- Begin function _xt_tls_new
	.p2align	4, 0x90
	.type	_xt_tls_new,@function
_xt_tls_new:                            # @_xt_tls_new
# %bb.0:
	push	rbx
	sub	rsp, 16
	xor	ebx, ebx
	lea	rdi, [rsp + 12]
	xor	esi, esi
	call	pthread_key_create@PLT
	neg	eax
	sbb	ebx, ebx
	or	ebx, dword ptr [rsp + 12]
	mov	eax, ebx
	add	rsp, 16
	pop	rbx
	ret
.Lfunc_end89:
	.size	_xt_tls_new, .Lfunc_end89-_xt_tls_new
                                        # -- End function
	.globl	_xt_tls_set                     # -- Begin function _xt_tls_set
	.p2align	4, 0x90
	.type	_xt_tls_set,@function
_xt_tls_set:                            # @_xt_tls_set
# %bb.0:
	cmp	edi, -1
	jne	pthread_setspecific@PLT         # TAILCALL
# %bb.1:
	ret
.Lfunc_end90:
	.size	_xt_tls_set, .Lfunc_end90-_xt_tls_set
                                        # -- End function
	.globl	_xt_tls_get                     # -- Begin function _xt_tls_get
	.p2align	4, 0x90
	.type	_xt_tls_get,@function
_xt_tls_get:                            # @_xt_tls_get
# %bb.0:
	cmp	edi, -1
	jne	pthread_getspecific@PLT         # TAILCALL
# %bb.1:
	xor	eax, eax
	ret
.Lfunc_end91:
	.size	_xt_tls_get, .Lfunc_end91-_xt_tls_get
                                        # -- End function
	.globl	_xt_atomic_load_i32             # -- Begin function _xt_atomic_load_i32
	.p2align	4, 0x90
	.type	_xt_atomic_load_i32,@function
_xt_atomic_load_i32:                    # @_xt_atomic_load_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB92_1
# %bb.2:
	mov	eax, dword ptr [rdi]
	ret
.LBB92_1:
	xor	eax, eax
	ret
.Lfunc_end92:
	.size	_xt_atomic_load_i32, .Lfunc_end92-_xt_atomic_load_i32
                                        # -- End function
	.globl	_xt_atomic_store_i32            # -- Begin function _xt_atomic_store_i32
	.p2align	4, 0x90
	.type	_xt_atomic_store_i32,@function
_xt_atomic_store_i32:                   # @_xt_atomic_store_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB93_2
# %bb.1:
	xchg	dword ptr [rdi], esi
.LBB93_2:
	ret
.Lfunc_end93:
	.size	_xt_atomic_store_i32, .Lfunc_end93-_xt_atomic_store_i32
                                        # -- End function
	.globl	_xt_atomic_add_i32              # -- Begin function _xt_atomic_add_i32
	.p2align	4, 0x90
	.type	_xt_atomic_add_i32,@function
_xt_atomic_add_i32:                     # @_xt_atomic_add_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB94_1
# %bb.2:
	mov	eax, esi
	lock		xadd	dword ptr [rdi], eax
	add	eax, esi
	ret
.LBB94_1:
	xor	eax, eax
	ret
.Lfunc_end94:
	.size	_xt_atomic_add_i32, .Lfunc_end94-_xt_atomic_add_i32
                                        # -- End function
	.globl	_xt_atomic_xchg_i32             # -- Begin function _xt_atomic_xchg_i32
	.p2align	4, 0x90
	.type	_xt_atomic_xchg_i32,@function
_xt_atomic_xchg_i32:                    # @_xt_atomic_xchg_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB95_1
# %bb.2:
	mov	eax, esi
	xchg	dword ptr [rdi], eax
	ret
.LBB95_1:
	xor	eax, eax
	ret
.Lfunc_end95:
	.size	_xt_atomic_xchg_i32, .Lfunc_end95-_xt_atomic_xchg_i32
                                        # -- End function
	.globl	_xt_atomic_cas_i32              # -- Begin function _xt_atomic_cas_i32
	.p2align	4, 0x90
	.type	_xt_atomic_cas_i32,@function
_xt_atomic_cas_i32:                     # @_xt_atomic_cas_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB96_1
# %bb.2:
	mov	eax, esi
	lock		cmpxchg	dword ptr [rdi], edx
	mov	eax, 0
	sete	al
	ret
.LBB96_1:
	xor	eax, eax
	ret
.Lfunc_end96:
	.size	_xt_atomic_cas_i32, .Lfunc_end96-_xt_atomic_cas_i32
                                        # -- End function
	.globl	_xt_atomic_load_ptr             # -- Begin function _xt_atomic_load_ptr
	.p2align	4, 0x90
	.type	_xt_atomic_load_ptr,@function
_xt_atomic_load_ptr:                    # @_xt_atomic_load_ptr
# %bb.0:
	test	rdi, rdi
	je	.LBB97_1
# %bb.2:
	mov	rax, qword ptr [rdi]
	ret
.LBB97_1:
	xor	eax, eax
	ret
.Lfunc_end97:
	.size	_xt_atomic_load_ptr, .Lfunc_end97-_xt_atomic_load_ptr
                                        # -- End function
	.globl	_xt_atomic_store_ptr            # -- Begin function _xt_atomic_store_ptr
	.p2align	4, 0x90
	.type	_xt_atomic_store_ptr,@function
_xt_atomic_store_ptr:                   # @_xt_atomic_store_ptr
# %bb.0:
	test	rdi, rdi
	je	.LBB98_2
# %bb.1:
	xchg	qword ptr [rdi], rsi
.LBB98_2:
	ret
.Lfunc_end98:
	.size	_xt_atomic_store_ptr, .Lfunc_end98-_xt_atomic_store_ptr
                                        # -- End function
	.globl	_xt_atomic_cas_ptr              # -- Begin function _xt_atomic_cas_ptr
	.p2align	4, 0x90
	.type	_xt_atomic_cas_ptr,@function
_xt_atomic_cas_ptr:                     # @_xt_atomic_cas_ptr
# %bb.0:
	test	rdi, rdi
	je	.LBB99_1
# %bb.2:
	mov	rax, rsi
	lock		cmpxchg	qword ptr [rdi], rdx
	mov	eax, 0
	sete	al
	ret
.LBB99_1:
	xor	eax, eax
	ret
.Lfunc_end99:
	.size	_xt_atomic_cas_ptr, .Lfunc_end99-_xt_atomic_cas_ptr
                                        # -- End function
	.globl	_xt_simd_select                 # -- Begin function _xt_simd_select
	.p2align	4, 0x90
	.type	_xt_simd_select,@function
_xt_simd_select:                        # @_xt_simd_select
# %bb.0:
	push	rbp
	push	r15
	push	r14
	push	rbx
	push	rax
	mov	ebp, esi
	mov	r14, rdi
	mov	eax, 1
	xor	ecx, ecx
	#APP

	.byte	15
	.byte	162

	#NO_APP
	xor	r15d, r15d
	not	ecx
	test	ecx, 402653184
	jne	.LBB100_4
# %bb.1:
	xor	r15d, r15d
	xor	ecx, ecx
	#APP

	.byte	15
	.byte	1
	.byte	208

	#NO_APP
	mov	esi, eax
	not	esi
	test	sil, 6
	jne	.LBB100_4
# %bb.2:
	xor	r15d, r15d
	mov	eax, 7
	xor	ecx, ecx
	#APP

	.byte	15
	.byte	162

	#NO_APP
	test	bl, 32
	je	.LBB100_4
# %bb.3:
	not	ebx
	and	ebx, -1073545216
	and	esi, 224
	xor	r15d, r15d
	or	esi, ebx
	sete	r15b
	inc	r15d
.LBB100_4:
	lea	rdi, [rip + .L.str]
	call	getenv@PLT
	test	rax, rax
	je	.LBB100_27
# %bb.5:
	movzx	ecx, byte ptr [rax]
	test	cl, cl
	je	.LBB100_6
# %bb.7:
	lea	rsi, [rax + 1]
	lea	rdx, [rip + .L.str.1]
	mov	edi, ecx
	.p2align	4, 0x90
.LBB100_8:                              # =>This Inner Loop Header: Depth=1
	cmp	dil, byte ptr [rdx]
	jne	.LBB100_10
# %bb.9:                                #   in Loop: Header=BB100_8 Depth=1
	inc	rdx
	movzx	edi, byte ptr [rsi]
	inc	rsi
	test	dil, dil
	jne	.LBB100_8
	jmp	.LBB100_10
.LBB100_6:
	lea	rdx, [rip + .L.str.1]
	mov	edi, ecx
.LBB100_10:
	xor	esi, esi
	cmp	dil, byte ptr [rdx]
	cmovne	esi, r15d
	je	.LBB100_28
# %bb.11:
	test	cl, cl
	je	.LBB100_12
# %bb.13:
	lea	rdi, [rax + 1]
	lea	rdx, [rip + .L.str.2]
	mov	esi, ecx
	.p2align	4, 0x90
.LBB100_14:                             # =>This Inner Loop Header: Depth=1
	cmp	sil, byte ptr [rdx]
	jne	.LBB100_16
# %bb.15:                               #   in Loop: Header=BB100_14 Depth=1
	inc	rdx
	movzx	esi, byte ptr [rdi]
	inc	rdi
	test	sil, sil
	jne	.LBB100_14
.LBB100_16:
	cmp	sil, byte ptr [rdx]
	jne	.LBB100_19
.LBB100_17:
	mov	esi, 1
	test	r15d, r15d
	jne	.LBB100_28
# %bb.18:
	lea	rsi, [rip + xt_simd_pick.msg]
	mov	edx, 66
	mov	edi, 2
	call	write@PLT
	xor	esi, esi
	jmp	.LBB100_28
.LBB100_12:
	lea	rdx, [rip + .L.str.2]
	mov	esi, ecx
	cmp	sil, byte ptr [rdx]
	je	.LBB100_17
.LBB100_19:
	test	cl, cl
	je	.LBB100_20
# %bb.21:
	inc	rax
	lea	rdx, [rip + .L.str.3]
	.p2align	4, 0x90
.LBB100_22:                             # =>This Inner Loop Header: Depth=1
	cmp	cl, byte ptr [rdx]
	jne	.LBB100_24
# %bb.23:                               #   in Loop: Header=BB100_22 Depth=1
	inc	rdx
	movzx	ecx, byte ptr [rax]
	inc	rax
	test	cl, cl
	jne	.LBB100_22
	jmp	.LBB100_24
.LBB100_20:
	lea	rdx, [rip + .L.str.3]
.LBB100_24:
	cmp	r15d, 1
	ja	.LBB100_27
# %bb.25:
	cmp	cl, byte ptr [rdx]
	jne	.LBB100_27
# %bb.26:
	lea	rsi, [rip + xt_simd_pick.msg.4]
	mov	edx, 82
	mov	edi, 2
	call	write@PLT
.LBB100_27:
	mov	esi, r15d
.LBB100_28:
	xor	eax, eax
	test	esi, esi
	setne	al
	mov	rcx, qword ptr [rip + _xt_simd_level@GOTPCREL]
	mov	dword ptr [rcx], eax
	test	ebp, ebp
	je	.LBB100_31
# %bb.29:
	cmp	esi, 1
	mov	eax, 1
	sbb	eax, -1
	mov	ecx, ebp
	lea	rcx, [rcx + 2*rcx]
	xor	edx, edx
	.p2align	4, 0x90
.LBB100_30:                             # =>This Inner Loop Header: Depth=1
	mov	esi, edx
	mov	rsi, qword ptr [r14 + 8*rsi]
	lea	edi, [rax + rdx]
	mov	rdi, qword ptr [r14 + 8*rdi]
	mov	qword ptr [rsi], rdi
	add	rdx, 3
	cmp	rcx, rdx
	jne	.LBB100_30
.LBB100_31:
	add	rsp, 8
	pop	rbx
	pop	r14
	pop	r15
	pop	rbp
	ret
.Lfunc_end100:
	.size	_xt_simd_select, .Lfunc_end100-_xt_simd_select
                                        # -- End function
	.globl	_xt_simd_select4                # -- Begin function _xt_simd_select4
	.p2align	4, 0x90
	.type	_xt_simd_select4,@function
_xt_simd_select4:                       # @_xt_simd_select4
# %bb.0:
	push	rbp
	push	r15
	push	r14
	push	rbx
	push	rax
	mov	ebp, esi
	mov	r14, rdi
	mov	eax, 1
	xor	ecx, ecx
	#APP

	.byte	15
	.byte	162

	#NO_APP
	xor	r15d, r15d
	not	ecx
	test	ecx, 402653184
	jne	.LBB101_4
# %bb.1:
	xor	r15d, r15d
	xor	ecx, ecx
	#APP

	.byte	15
	.byte	1
	.byte	208

	#NO_APP
	mov	esi, eax
	not	esi
	test	sil, 6
	jne	.LBB101_4
# %bb.2:
	xor	r15d, r15d
	mov	eax, 7
	xor	ecx, ecx
	#APP

	.byte	15
	.byte	162

	#NO_APP
	test	bl, 32
	je	.LBB101_4
# %bb.3:
	not	ebx
	and	ebx, -1073545216
	and	esi, 224
	xor	r15d, r15d
	or	esi, ebx
	sete	r15b
	inc	r15d
.LBB101_4:
	lea	rdi, [rip + .L.str]
	call	getenv@PLT
	test	rax, rax
	je	.LBB101_27
# %bb.5:
	movzx	ecx, byte ptr [rax]
	test	cl, cl
	je	.LBB101_6
# %bb.7:
	lea	rsi, [rax + 1]
	lea	rdx, [rip + .L.str.1]
	mov	edi, ecx
	.p2align	4, 0x90
.LBB101_8:                              # =>This Inner Loop Header: Depth=1
	cmp	dil, byte ptr [rdx]
	jne	.LBB101_10
# %bb.9:                                #   in Loop: Header=BB101_8 Depth=1
	inc	rdx
	movzx	edi, byte ptr [rsi]
	inc	rsi
	test	dil, dil
	jne	.LBB101_8
	jmp	.LBB101_10
.LBB101_6:
	lea	rdx, [rip + .L.str.1]
	mov	edi, ecx
.LBB101_10:
	xor	esi, esi
	cmp	dil, byte ptr [rdx]
	cmovne	esi, r15d
	je	.LBB101_28
# %bb.11:
	test	cl, cl
	je	.LBB101_12
# %bb.13:
	lea	rdi, [rax + 1]
	lea	rdx, [rip + .L.str.2]
	mov	esi, ecx
	.p2align	4, 0x90
.LBB101_14:                             # =>This Inner Loop Header: Depth=1
	cmp	sil, byte ptr [rdx]
	jne	.LBB101_16
# %bb.15:                               #   in Loop: Header=BB101_14 Depth=1
	inc	rdx
	movzx	esi, byte ptr [rdi]
	inc	rdi
	test	sil, sil
	jne	.LBB101_14
.LBB101_16:
	cmp	sil, byte ptr [rdx]
	jne	.LBB101_19
.LBB101_17:
	mov	esi, 1
	test	r15d, r15d
	jne	.LBB101_28
# %bb.18:
	lea	rsi, [rip + xt_simd_pick.msg]
	mov	edx, 66
	mov	edi, 2
	call	write@PLT
	xor	esi, esi
	jmp	.LBB101_28
.LBB101_12:
	lea	rdx, [rip + .L.str.2]
	mov	esi, ecx
	cmp	sil, byte ptr [rdx]
	je	.LBB101_17
.LBB101_19:
	test	cl, cl
	je	.LBB101_20
# %bb.21:
	inc	rax
	lea	rdx, [rip + .L.str.3]
	.p2align	4, 0x90
.LBB101_22:                             # =>This Inner Loop Header: Depth=1
	cmp	cl, byte ptr [rdx]
	jne	.LBB101_24
# %bb.23:                               #   in Loop: Header=BB101_22 Depth=1
	inc	rdx
	movzx	ecx, byte ptr [rax]
	inc	rax
	test	cl, cl
	jne	.LBB101_22
	jmp	.LBB101_24
.LBB101_20:
	lea	rdx, [rip + .L.str.3]
.LBB101_24:
	cmp	r15d, 1
	ja	.LBB101_27
# %bb.25:
	cmp	cl, byte ptr [rdx]
	jne	.LBB101_27
# %bb.26:
	lea	rsi, [rip + xt_simd_pick.msg.4]
	mov	edx, 82
	mov	edi, 2
	call	write@PLT
.LBB101_27:
	mov	esi, r15d
.LBB101_28:
	mov	rax, qword ptr [rip + _xt_simd_level@GOTPCREL]
	mov	dword ptr [rax], esi
	test	ebp, ebp
	je	.LBB101_31
# %bb.29:
	mov	eax, ebp
	mov	ecx, esi
	inc	rcx
	shl	rax, 2
	xor	edx, edx
	.p2align	4, 0x90
.LBB101_30:                             # =>This Inner Loop Header: Depth=1
	mov	esi, edx
	mov	rsi, qword ptr [r14 + 8*rsi]
	lea	edi, [rcx + rdx]
	mov	rdi, qword ptr [r14 + 8*rdi]
	mov	qword ptr [rsi], rdi
	add	rdx, 4
	cmp	rax, rdx
	jne	.LBB101_30
.LBB101_31:
	add	rsp, 8
	pop	rbx
	pop	r14
	pop	r15
	pop	rbp
	ret
.Lfunc_end101:
	.size	_xt_simd_select4, .Lfunc_end101-_xt_simd_select4
                                        # -- End function
	.globl	_xtc_sinit_run                  # -- Begin function _xtc_sinit_run
	.p2align	4, 0x90
	.type	_xtc_sinit_run,@function
_xtc_sinit_run:                         # @_xtc_sinit_run
# %bb.0:
	test	rdi, rdi
	je	.LBB102_36
# %bb.1:
	push	rbp
	push	r15
	push	r14
	push	r13
	push	r12
	push	rbx
	push	rax
	mov	r15, rdx
	mov	r14, rsi
	mov	rbx, rdi
	mov	r12, qword ptr [rip + _xt_threads_active@GOTPCREL]
	lea	r13, [rip + xt_sinit_flag]
	lea	rbp, [rip + xt_sinit_owner]
	jmp	.LBB102_2
	.p2align	4, 0x90
.LBB102_14:                             #   in Loop: Header=BB102_2 Depth=1
	call	sched_yield@PLT
	xor	eax, eax
.LBB102_21:                             #   in Loop: Header=BB102_2 Depth=1
	test	eax, eax
	jne	.LBB102_22
.LBB102_2:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB102_3 Depth 2
                                        #       Child Loop BB102_4 Depth 3
                                        #     Child Loop BB102_9 Depth 2
	cmp	dword ptr [r12], 0
	je	.LBB102_5
	.p2align	4, 0x90
.LBB102_3:                              #   Parent Loop BB102_2 Depth=1
                                        # =>  This Loop Header: Depth=2
                                        #       Child Loop BB102_4 Depth 3
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB102_5
.LBB102_4:                              #   Parent Loop BB102_2 Depth=1
                                        #     Parent Loop BB102_3 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB102_4
	jmp	.LBB102_3
	.p2align	4, 0x90
.LBB102_5:                              #   in Loop: Header=BB102_2 Depth=1
	movzx	eax, byte ptr [rbx]
	test	eax, eax
	je	.LBB102_15
# %bb.6:                                #   in Loop: Header=BB102_2 Depth=1
	cmp	eax, 2
	jne	.LBB102_7
.LBB102_18:                             #   in Loop: Header=BB102_2 Depth=1
	mov	eax, 1
	cmp	dword ptr [r12], 0
	jne	.LBB102_20
	jmp	.LBB102_21
	.p2align	4, 0x90
.LBB102_15:                             #   in Loop: Header=BB102_2 Depth=1
	mov	byte ptr [rbx], 1
	movsxd	rax, dword ptr [rip + xt_sinit_n]
	cmp	rax, 31
	jg	.LBB102_17
# %bb.16:                               #   in Loop: Header=BB102_2 Depth=1
	mov	qword ptr [r13 + 8*rax], rbx
	call	pthread_self@PLT
	mov	rcx, rax
	shr	rcx, 4
	shr	rax, 32
	xor	ecx, eax
	movsxd	rax, dword ptr [rip + xt_sinit_n]
	mov	dword ptr [rbp + 4*rax], ecx
	inc	eax
	mov	dword ptr [rip + xt_sinit_n], eax
.LBB102_17:                             #   in Loop: Header=BB102_2 Depth=1
	mov	eax, 2
	cmp	dword ptr [r12], 0
	je	.LBB102_21
.LBB102_20:                             #   in Loop: Header=BB102_2 Depth=1
	mov	dword ptr [rip + xt_rt_spin], 0
	jmp	.LBB102_21
	.p2align	4, 0x90
.LBB102_7:                              #   in Loop: Header=BB102_2 Depth=1
	call	pthread_self@PLT
	movsxd	rcx, dword ptr [rip + xt_sinit_n]
	test	rcx, rcx
	jle	.LBB102_12
# %bb.8:                                #   in Loop: Header=BB102_2 Depth=1
	mov	rdx, rax
	shr	rdx, 4
	shr	rax, 32
	xor	edx, eax
	shl	rcx, 3
	xor	eax, eax
	mov	rsi, rbp
	jmp	.LBB102_9
	.p2align	4, 0x90
.LBB102_11:                             #   in Loop: Header=BB102_9 Depth=2
	add	rsi, 4
	add	rax, 8
	cmp	rcx, rax
	je	.LBB102_12
.LBB102_9:                              #   Parent Loop BB102_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	qword ptr [rax + r13], rbx
	jne	.LBB102_11
# %bb.10:                               #   in Loop: Header=BB102_9 Depth=2
	cmp	dword ptr [rsi], edx
	jne	.LBB102_11
	jmp	.LBB102_18
	.p2align	4, 0x90
.LBB102_12:                             #   in Loop: Header=BB102_2 Depth=1
	cmp	dword ptr [r12], 0
	je	.LBB102_14
# %bb.13:                               #   in Loop: Header=BB102_2 Depth=1
	mov	dword ptr [rip + xt_rt_spin], 0
	jmp	.LBB102_14
.LBB102_22:
	cmp	eax, 1
	je	.LBB102_35
# %bb.23:
	test	r14, r14
	je	.LBB102_25
# %bb.24:
	mov	rdi, r15
	call	r14
.LBB102_25:
	cmp	dword ptr [r12], 0
	je	.LBB102_28
	.p2align	4, 0x90
.LBB102_26:                             # =>This Loop Header: Depth=1
                                        #     Child Loop BB102_27 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB102_28
.LBB102_27:                             #   Parent Loop BB102_26 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB102_27
	jmp	.LBB102_26
.LBB102_28:
	mov	byte ptr [rbx], 2
	movsxd	rax, dword ptr [rip + xt_sinit_n]
	test	rax, rax
	jle	.LBB102_33
# %bb.29:
	lea	rdx, [4*rax]
	xor	ecx, ecx
	.p2align	4, 0x90
.LBB102_31:                             # =>This Inner Loop Header: Depth=1
	cmp	qword ptr [r13], rbx
	je	.LBB102_32
# %bb.30:                               #   in Loop: Header=BB102_31 Depth=1
	add	rcx, 4
	add	r13, 8
	cmp	rdx, rcx
	jne	.LBB102_31
.LBB102_33:
	cmp	dword ptr [r12], 0
	je	.LBB102_35
.LBB102_34:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB102_35:
	add	rsp, 8
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	pop	rbp
.LBB102_36:
	ret
.LBB102_32:
	lea	edx, [rax - 1]
	mov	dword ptr [rip + xt_sinit_n], edx
	lea	rdx, [rip + xt_sinit_flag]
	mov	rdx, qword ptr [rdx + 8*rax - 8]
	mov	qword ptr [r13], rdx
	lea	rdx, [rip + xt_sinit_owner]
	mov	eax, dword ptr [rdx + 4*rax - 4]
	mov	dword ptr [rcx + rdx], eax
	cmp	dword ptr [r12], 0
	jne	.LBB102_34
	jmp	.LBB102_35
.Lfunc_end102:
	.size	_xtc_sinit_run, .Lfunc_end102-_xtc_sinit_run
                                        # -- End function
	.globl	_xt_thread_exiting              # -- Begin function _xt_thread_exiting
	.p2align	4, 0x90
	.type	_xt_thread_exiting,@function
_xt_thread_exiting:                     # @_xt_thread_exiting
# %bb.0:
	ret
.Lfunc_end103:
	.size	_xt_thread_exiting, .Lfunc_end103-_xt_thread_exiting
                                        # -- End function
	.p2align	4, 0x90                         # -- Begin function xt_simd_fault
	.type	xt_simd_fault,@function
xt_simd_fault:                          # @xt_simd_fault
# %bb.0:
	push	rbp
	push	rbx
	push	rax
	mov	rax, qword ptr [rsi + 16]
	mov	rbx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rbx], 0
	je	.LBB104_3
	.p2align	4, 0x90
.LBB104_1:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB104_2 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_rt_spin], ecx
	test	ecx, ecx
	je	.LBB104_3
.LBB104_2:                              #   Parent Loop BB104_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_rt_spin]
	test	ecx, ecx
	jne	.LBB104_2
	jmp	.LBB104_1
.LBB104_3:
	mov	rdx, qword ptr [rip + xt_simd_n]
	test	rdx, rdx
	je	.LBB104_4
# %bb.5:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	xor	ecx, ecx
	movabs	r8, 2305843009213693950
	.p2align	4, 0x90
.LBB104_6:                              # =>This Inner Loop Header: Depth=1
	lea	r9, [rdx + rcx]
	mov	r10, r9
	shr	r10
	and	r9, r8
	cmp	qword ptr [rsi + 8*r9], rax
	lea	r9, [r10 + 1]
	cmova	rdx, r10
	cmovbe	rcx, r9
	cmp	rcx, rdx
	jb	.LBB104_6
	jmp	.LBB104_7
.LBB104_4:
	xor	ecx, ecx
.LBB104_7:
	mov	dl, 1
	test	rcx, rcx
	je	.LBB104_11
# %bb.8:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	lea	r8, [2*rcx - 2]
	cmp	qword ptr [rsi + 8*r8 + 8], rax
	jbe	.LBB104_11
# %bb.9:
	lea	rax, [rcx - 1]
	mov	r9, qword ptr [rip + xt_simd_flag]
	movzx	r10d, byte ptr [r9 + rax]
	test	r10b, 1
	je	.LBB104_11
# %bb.10:
	lea	rcx, [2*rcx - 1]
	and	r10b, -2
	mov	byte ptr [r9 + rax], r10b
	mov	rax, qword ptr [rsi + 8*r8]
	mov	rsi, qword ptr [rsi + 8*rcx]
	sub	rsi, rax
	add	rsi, 16383
	and	rsi, -16384
	mov	ebp, edi
	mov	rdi, rax
	mov	edx, 3
	call	mprotect@PLT
	mov	edi, ebp
	xor	edx, edx
.LBB104_11:
	cmp	dword ptr [rbx], 0
	je	.LBB104_13
# %bb.12:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB104_13:
	test	dl, dl
	je	.LBB104_14
# %bb.15:
	movsxd	rsi, edi
	xor	eax, eax
	cmp	esi, 11
	setne	al
	shl	eax, 5
	lea	rdx, [rip + xt_simd_old]
	add	rdx, rax
	mov	edi, 13
	mov	r8d, 8
	xor	ecx, ecx
	xor	eax, eax
	add	rsp, 8
	pop	rbx
	pop	rbp
	jmp	syscall@PLT                     # TAILCALL
.LBB104_14:
	add	rsp, 8
	pop	rbx
	pop	rbp
	ret
.Lfunc_end104:
	.size	xt_simd_fault, .Lfunc_end104-xt_simd_fault
                                        # -- End function
	.type	xt_empty,@object                # @xt_empty
	.section	.rodata,"a",@progbits
xt_empty:
	.zero	1
	.size	xt_empty, 1

	.type	xt_cache,@object                # @xt_cache
	.local	xt_cache
	.comm	xt_cache,512,16
	.type	xt_cache_n,@object              # @xt_cache_n
	.local	xt_cache_n
	.comm	xt_cache_n,256,16
	.type	xt_simd_tab,@object             # @xt_simd_tab
	.local	xt_simd_tab
	.comm	xt_simd_tab,8,8
	.type	xt_simd_flag,@object            # @xt_simd_flag
	.local	xt_simd_flag
	.comm	xt_simd_flag,8,8
	.type	xt_rand_state,@object           # @xt_rand_state
	.data
	.p2align	3, 0x0
xt_rand_state:
	.quad	1                               # 0x1
	.size	xt_rand_state, 8

	.type	xt_clk_origin,@object           # @xt_clk_origin
	.local	xt_clk_origin
	.comm	xt_clk_origin,8,8
	.type	xt_bank_regions,@object         # @xt_bank_regions
	.local	xt_bank_regions
	.comm	xt_bank_regions,6144,16
	.type	_xt_threads_active,@object      # @_xt_threads_active
	.bss
	.globl	_xt_threads_active
	.p2align	2, 0x0
_xt_threads_active:
	.long	0                               # 0x0
	.size	_xt_threads_active, 4

	.type	xt_rt_spin,@object              # @xt_rt_spin
	.local	xt_rt_spin
	.comm	xt_rt_spin,4,4
	.type	xt_alloc_spin,@object           # @xt_alloc_spin
	.local	xt_alloc_spin
	.comm	xt_alloc_spin,4,4
	.type	_xt_simd_level,@object          # @_xt_simd_level
	.data
	.globl	_xt_simd_level
	.p2align	2, 0x0
_xt_simd_level:
	.long	4294967295                      # 0xffffffff
	.size	_xt_simd_level, 4

	.type	xt_sinit_n,@object              # @xt_sinit_n
	.local	xt_sinit_n
	.comm	xt_sinit_n,4,4
	.type	xt_sinit_flag,@object           # @xt_sinit_flag
	.local	xt_sinit_flag
	.comm	xt_sinit_flag,256,16
	.type	xt_sinit_owner,@object          # @xt_sinit_owner
	.local	xt_sinit_owner
	.comm	xt_sinit_owner,128,16
	.type	xt_size_check.msg,@object       # @xt_size_check.msg
	.section	.rodata,"a",@progbits
	.p2align	4, 0x0
xt_size_check.msg:
	.asciz	"xcc: an allocation overflows its size\n"
	.size	xt_size_check.msg, 39

	.type	xt_simd_n,@object               # @xt_simd_n
	.local	xt_simd_n
	.comm	xt_simd_n,8,8
	.type	xt_simd_cap,@object             # @xt_simd_cap
	.local	xt_simd_cap
	.comm	xt_simd_cap,8,8
	.type	xt_simd_installed,@object       # @xt_simd_installed
	.local	xt_simd_installed
	.comm	xt_simd_installed,1,4
	.type	xt_simd_old,@object             # @xt_simd_old
	.local	xt_simd_old
	.comm	xt_simd_old,64,16
	.type	.L.str,@object                  # @.str
	.section	.rodata.str1.1,"aMS",@progbits,1
.L.str:
	.asciz	"XC_SIMD"
	.size	.L.str, 8

	.type	.L.str.1,@object                # @.str.1
.L.str.1:
	.asciz	"base"
	.size	.L.str.1, 5

	.type	.L.str.2,@object                # @.str.2
.L.str.2:
	.asciz	"avx2"
	.size	.L.str.2, 5

	.type	xt_simd_pick.msg,@object        # @xt_simd_pick.msg
	.section	.rodata,"a",@progbits
	.p2align	4, 0x0
xt_simd_pick.msg:
	.asciz	"xc: XC_SIMD=avx2, but this machine has no usable AVX2; using base\n"
	.size	xt_simd_pick.msg, 67

	.type	.L.str.3,@object                # @.str.3
	.section	.rodata.str1.1,"aMS",@progbits,1
.L.str.3:
	.asciz	"avx512"
	.size	.L.str.3, 7

	.type	xt_simd_pick.msg.4,@object      # @xt_simd_pick.msg.4
	.section	.rodata,"a",@progbits
	.p2align	4, 0x0
xt_simd_pick.msg.4:
	.asciz	"xc: XC_SIMD=avx512, but this machine has no usable AVX-512; using the best it has\n"
	.size	xt_simd_pick.msg.4, 83

	.ident	"Apple clang version 17.0.0 (clang-1700.3.19.1)"
	.section	".note.GNU-stack","",@progbits
	.addrsig
	.addrsig_sym xt_gthread_entry
	.addrsig_sym xt_simd_fault
	.addrsig_sym xt_sigrestore
	.addrsig_sym xt_empty
	.addrsig_sym xt_rt_spin
	.addrsig_sym xt_alloc_spin
	.addrsig_sym xt_size_check.msg
	.addrsig_sym xt_simd_old
	.addrsig_sym xt_simd_pick.msg
	.addrsig_sym xt_simd_pick.msg.4
