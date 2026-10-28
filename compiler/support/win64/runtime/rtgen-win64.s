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

# Generated from src/xtc/support-src/rt-freestanding.c (-DXT_WIN64) with the
# win64 command in that file's header, and NOT edited by hand. Keep it that
# way: this file was hand-maintained for a while and fell behind the C (bug
# 604), so a fix made in the C reached win64 only if someone re-applied it
# here (bug 601 was one). What used to be hand-applied now comes from the C:
# the process-heap allocator (HeapAlloc/HeapFree, shared by a program and its
# DLLs), _xtc_sinit_run, getpid. To change the win64 runtime, change the C and
# regenerate; then put this header and the licence back on top.
// regenerated with: Apple clang version 17.0.0 (clang-1700.3.19.1)
	.text
	.def	@feat.00;
	.scl	3;
	.type	0;
	.endef
	.globl	@feat.00
.set @feat.00, 0
	.intel_syntax noprefix
	.file	"rt-freestanding.c"
	.def	getpid;
	.scl	2;
	.type	32;
	.endef
	.globl	getpid                          # -- Begin function getpid
	.p2align	4, 0x90
getpid:                                 # @getpid
# %bb.0:
	jmp	GetCurrentProcessId             # TAILCALL
                                        # -- End function
	.def	write;
	.scl	2;
	.type	32;
	.endef
	.globl	write                           # -- Begin function write
	.p2align	4, 0x90
write:                                  # @write
# %bb.0:
	push	rsi
	push	rdi
	sub	rsp, 56
	mov	rsi, r8
	mov	rdi, rdx
	mov	dword ptr [rsp + 52], 0
	xor	eax, eax
	cmp	ecx, 2
	sete	al
	xor	eax, -11
	mov	ecx, eax
	call	GetStdHandle
	mov	qword ptr [rsp + 32], 0
	lea	r9, [rsp + 52]
	mov	rcx, rax
	mov	rdx, rdi
	mov	r8d, esi
	call	WriteFile
	mov	eax, dword ptr [rsp + 52]
	add	rsp, 56
	pop	rdi
	pop	rsi
	ret
                                        # -- End function
	.def	_xt_calloc;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_calloc                      # -- Begin function _xt_calloc
	.p2align	4, 0x90
_xt_calloc:                             # @_xt_calloc
# %bb.0:
	push	rsi
	sub	rsp, 32
	mov	rsi, rcx
	call	GetProcessHeap
	add	rsi, 8
	mov	rcx, rax
	mov	edx, 8
	mov	r8, rsi
	call	HeapAlloc
	lea	rcx, [rax + 8]
	test	rax, rax
	cmovne	rax, rcx
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xt_free;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_free                        # -- Begin function _xt_free
	.p2align	4, 0x90
_xt_free:                               # @_xt_free
# %bb.0:
	push	rsi
	sub	rsp, 32
	test	rcx, rcx
	je	.LBB3_1
# %bb.2:
	mov	rsi, rcx
	call	GetProcessHeap
	add	rsi, -8
	mov	rcx, rax
	xor	edx, edx
	mov	r8, rsi
	add	rsp, 32
	pop	rsi
	jmp	HeapFree                        # TAILCALL
.LBB3_1:
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	memset;
	.scl	2;
	.type	32;
	.endef
	.globl	memset                          # -- Begin function memset
	.p2align	4, 0x90
memset:                                 # @memset
# %bb.0:
	mov	rax, rcx
	test	r8, r8
	je	.LBB4_3
# %bb.1:
	xor	ecx, ecx
	.p2align	4, 0x90
.LBB4_2:                                # =>This Inner Loop Header: Depth=1
	mov	byte ptr [rax + rcx], dl
	inc	rcx
	cmp	r8, rcx
	jne	.LBB4_2
.LBB4_3:
	ret
                                        # -- End function
	.def	_xt_fmt_f;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	4, 0x0                          # -- Begin function _xt_fmt_f
.LCPI5_0:
	.quad	0x8000000000000000              # double -0
	.quad	0x8000000000000000              # double -0
.LCPI5_1:
	.quad	0x4024000000000000              # double 10
	.text
	.globl	_xt_fmt_f
	.p2align	4, 0x90
_xt_fmt_f:                              # @_xt_fmt_f
# %bb.0:
	push	rsi
	push	rdi
	push	rbx
	sub	rsp, 32
	xor	eax, eax
	test	r9d, r9d
	cmovg	eax, r9d
	cmp	eax, 24
	mov	r11d, 24
	cmovl	r11d, eax
	movsd	xmm0, qword ptr [rsp + 96]      # xmm0 = mem[0],zero
	xorpd	xmm1, xmm1
	ucomisd	xmm1, xmm0
	jbe	.LBB5_1
# %bb.2:
	lea	r8, [rcx + 1]
	mov	byte ptr [rcx], 45
	xorpd	xmm0, xmmword ptr [rip + .LCPI5_0]
	jmp	.LBB5_3
.LBB5_1:
	mov	r8, rcx
.LBB5_3:
	cvttsd2si	rdx, xmm0
	xorps	xmm1, xmm1
	cvtsi2sd	xmm1, rdx
	xor	esi, esi
	movabs	rdi, -3689348814741910323
	.p2align	4, 0x90
.LBB5_4:                                # =>This Inner Loop Header: Depth=1
	mov	r10, rdx
	mov	rax, rdx
	mul	rdi
	shr	rdx, 3
	lea	eax, [rdx + rdx]
	lea	eax, [rax + 4*rax]
	mov	ebx, r10d
	sub	ebx, eax
	or	bl, 48
	lea	rax, [rsi + 1]
	mov	byte ptr [rsp + rsi], bl
	cmp	r10, 10
	jb	.LBB5_6
# %bb.5:                                #   in Loop: Header=BB5_4 Depth=1
	cmp	rsi, 23
	mov	rsi, rax
	jb	.LBB5_4
	.p2align	4, 0x90
.LBB5_6:                                # =>This Inner Loop Header: Depth=1
	lea	rdx, [rax - 1]
	mov	r10d, edx
	movzx	r10d, byte ptr [rsp + r10]
	mov	byte ptr [r8], r10b
	inc	r8
	cmp	rax, 1
	mov	rax, rdx
	jg	.LBB5_6
# %bb.7:
	test	r9d, r9d
	jle	.LBB5_11
# %bb.8:
	subsd	xmm0, xmm1
	mov	byte ptr [r8], 46
	neg	r11d
	mov	eax, 1
	movsd	xmm1, qword ptr [rip + .LCPI5_1] # xmm1 = [1.0E+1,0.0E+0]
	mov	edx, 9
	xor	r9d, r9d
	.p2align	4, 0x90
.LBB5_9:                                # =>This Inner Loop Header: Depth=1
	mulsd	xmm0, xmm1
	cvttsd2si	r10d, xmm0
	cmp	r10d, 9
	cmovge	r10d, edx
	test	r10d, r10d
	cmovle	r10d, r9d
	xorps	xmm2, xmm2
	cvtsi2sd	xmm2, r10d
                                        # kill: def $r10b killed $r10b killed $r10d
	or	r10b, 48
	mov	byte ptr [r8 + rax], r10b
	subsd	xmm0, xmm2
	inc	rax
	lea	r10d, [r11 + rax]
	cmp	r10d, 1
	jne	.LBB5_9
# %bb.10:
	add	r8, rax
.LBB5_11:
	mov	byte ptr [r8], 0
	sub	r8d, ecx
	mov	eax, r8d
	add	rsp, 32
	pop	rbx
	pop	rdi
	pop	rsi
	ret
                                        # -- End function
	.def	_xt_stack_guard_init;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_stack_guard_init            # -- Begin function _xt_stack_guard_init
	.p2align	4, 0x90
_xt_stack_guard_init:                   # @_xt_stack_guard_init
# %bb.0:
	push	rax
	mov	qword ptr [rsp], 0
	#APP

	.byte	15
	.byte	49

	#NO_APP
                                        # kill: def $edx killed $edx def $rdx
	shl	rdx, 32
	mov	eax, eax
	or	rax, rdx
	movabs	rcx, -7046029254386353131
	imul	rcx, rax
	mov	rax, rsp
	mov	rdx, rax
	shl	rdx, 17
	shr	rax, 13
	xor	rax, rdx
	lea	rdx, [rip + _xt_stack_guard_init]
	movabs	r8, -4417276706812531889
	imul	r8, rdx
	xor	r8, rax
	xor	r8, rcx
	mov	rax, r8
	shr	rax, 31
	xor	rax, r8
	movabs	rcx, -7723592293110705685
	imul	rcx, rax
	mov	rax, rcx
	shr	rax, 29
	xor	rax, rcx
	and	rax, -256
	movabs	rcx, 6364786164175470592
	cmovne	rcx, rax
	mov	qword ptr [rip + __xt_stack_guard], rcx
	pop	rax
	ret
                                        # -- End function
	.def	__xt_stack_fail;
	.scl	2;
	.type	32;
	.endef
	.globl	__xt_stack_fail                 # -- Begin function __xt_stack_fail
	.p2align	4, 0x90
__xt_stack_fail:                        # @__xt_stack_fail
# %bb.0:
	sub	rsp, 56
	mov	dword ptr [rsp + 52], 0
	mov	ecx, -12
	call	GetStdHandle
	mov	qword ptr [rsp + 32], 0
	lea	rdx, [rip + __xt_stack_fail.msg]
	lea	r9, [rsp + 52]
	mov	rcx, rax
	mov	r8d, 70
	call	WriteFile
	mov	ecx, 134
	call	_xt_exit
	add	rsp, 56
	ret
                                        # -- End function
	.def	_xtc_alloc;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_alloc                      # -- Begin function _xtc_alloc
	.p2align	4, 0x90
_xtc_alloc:                             # @_xtc_alloc
# %bb.0:
	push	r14
	push	rsi
	push	rdi
	push	rbx
	sub	rsp, 56
	mov	rsi, r8
	mov	rbx, rdx
	mov	rdi, rcx
	test	rdx, rdx
	je	.LBB8_3
# %bb.1:
	mov	rax, -1048577
	xor	edx, edx
	div	rbx
	cmp	rax, rdi
	jae	.LBB8_3
# %bb.2:
	mov	dword ptr [rsp + 52], 0
	mov	ecx, -12
	call	GetStdHandle
	mov	qword ptr [rsp + 32], 0
	lea	rdx, [rip + xt_size_check.msg]
	lea	r9, [rsp + 52]
	mov	rcx, rax
	mov	r8d, 38
	call	WriteFile
	mov	ecx, 134
	call	_xt_exit
.LBB8_3:
	mov	rax, rbx
	imul	rax, rdi
	cmp	rax, 257
	mov	r14d, 256
	cmovae	r14, rax
	call	GetProcessHeap
	add	r14, 48
	mov	rcx, rax
	mov	edx, 8
	mov	r8, r14
	call	HeapAlloc
	test	rax, rax
	je	.LBB8_4
# %bb.5:
	mov	dword ptr [rax + 8], 1481920322
	mov	qword ptr [rax + 12], rbx
	mov	qword ptr [rax + 20], rdi
	mov	qword ptr [rax + 28], rsi
	mov	qword ptr [rax + 36], 0
	mov	dword ptr [rax + 44], 1
	add	rax, 48
	jmp	.LBB8_6
.LBB8_4:
	xor	eax, eax
.LBB8_6:
	add	rsp, 56
	pop	rbx
	pop	rdi
	pop	rsi
	pop	r14
	ret
                                        # -- End function
	.def	_xtc_simd_register;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_simd_register              # -- Begin function _xtc_simd_register
	.p2align	4, 0x90
_xtc_simd_register:                     # @_xtc_simd_register
# %bb.0:
	push	r15
	push	r14
	push	r13
	push	r12
	push	rsi
	push	rdi
	push	rbp
	push	rbx
	sub	rsp, 40
	test	rcx, rcx
	je	.LBB9_35
# %bb.1:
	mov	rsi, rdx
	test	rdx, rdx
	je	.LBB9_35
# %bb.2:
	mov	rdi, rcx
	mov	eax, edi
	or	eax, esi
	and	eax, 4095
	jne	.LBB9_35
# %bb.3:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB9_6
	.p2align	4, 0x90
.LBB9_4:                                # =>This Loop Header: Depth=1
                                        #     Child Loop BB9_5 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB9_6
.LBB9_5:                                #   Parent Loop BB9_4 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB9_5
	jmp	.LBB9_4
.LBB9_6:
	mov	rax, qword ptr [rip + xt_simd_cap]
	cmp	qword ptr [rip + xt_simd_n], rax
	jne	.LBB9_26
# %bb.7:
	lea	rcx, [rax + rax]
	test	rax, rax
	mov	r12d, 64
	cmovne	r12, rcx
	mov	rbx, r12
	shl	rbx, 4
	call	GetProcessHeap
	or	rbx, 8
	mov	rcx, rax
	mov	edx, 8
	mov	r8, rbx
	call	HeapAlloc
	mov	r15, rax
	lea	r14, [rax + 8]
	test	rax, rax
	setne	r13b
	cmove	r14, rax
	call	GetProcessHeap
	lea	r8, [r12 + 8]
	mov	rcx, rax
	mov	edx, 8
	call	HeapAlloc
	lea	rbx, [rax + 8]
	test	rax, rax
	setne	bpl
	cmove	rbx, rax
	and	bpl, r13b
	cmp	bpl, 1
	jne	.LBB9_19
# %bb.8:
	mov	rax, qword ptr [rip + xt_simd_n]
	mov	rcx, rax
	add	rcx, rax
	je	.LBB9_11
# %bb.9:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	r8d, r8d
	.p2align	4, 0x90
.LBB9_10:                               # =>This Inner Loop Header: Depth=1
	mov	r9, qword ptr [rdx + 8*r8]
	mov	qword ptr [r14 + 8*r8], r9
	inc	r8
	cmp	rcx, r8
	jne	.LBB9_10
.LBB9_11:
	test	rax, rax
	je	.LBB9_14
# %bb.12:
	mov	rcx, qword ptr [rip + xt_simd_flag]
	xor	edx, edx
	.p2align	4, 0x90
.LBB9_13:                               # =>This Inner Loop Header: Depth=1
	movzx	r8d, byte ptr [rcx + rdx]
	mov	byte ptr [rbx + rdx], r8b
	inc	rdx
	cmp	rax, rdx
	jne	.LBB9_13
.LBB9_14:
	mov	r15, qword ptr [rip + xt_simd_tab]
	test	r15, r15
	je	.LBB9_16
# %bb.15:
	call	GetProcessHeap
	add	r15, -8
	mov	rcx, rax
	xor	edx, edx
	mov	r8, r15
	call	HeapFree
.LBB9_16:
	mov	r15, qword ptr [rip + xt_simd_flag]
	test	r15, r15
	je	.LBB9_18
# %bb.17:
	call	GetProcessHeap
	add	r15, -8
	mov	rcx, rax
	xor	edx, edx
	mov	r8, r15
	call	HeapFree
.LBB9_18:
	mov	qword ptr [rip + xt_simd_tab], r14
	mov	qword ptr [rip + xt_simd_flag], rbx
	mov	qword ptr [rip + xt_simd_cap], r12
	jmp	.LBB9_25
.LBB9_19:
	test	r15, r15
	je	.LBB9_21
# %bb.20:
	mov	r15, rax
	call	GetProcessHeap
	add	r14, -8
	mov	rcx, rax
	xor	edx, edx
	mov	r8, r14
	call	HeapFree
	mov	rax, r15
.LBB9_21:
	test	rax, rax
	je	.LBB9_23
# %bb.22:
	call	GetProcessHeap
	add	rbx, -8
	mov	rcx, rax
	xor	edx, edx
	mov	r8, rbx
	call	HeapFree
.LBB9_23:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB9_25
# %bb.24:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB9_25:
	test	bpl, bpl
	je	.LBB9_35
.LBB9_26:
	mov	rax, qword ptr [rip + xt_simd_n]
	test	rax, rax
	je	.LBB9_27
# %bb.28:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	ecx, ecx
	movabs	r8, 2305843009213693950
	mov	r9, rax
	.p2align	4, 0x90
.LBB9_29:                               # =>This Inner Loop Header: Depth=1
	lea	r10, [r9 + rcx]
	mov	r11, r10
	shr	r11
	and	r10, r8
	cmp	qword ptr [rdx + 8*r10], rdi
	lea	r10, [r11 + 1]
	cmova	r9, r11
	cmovbe	rcx, r10
	cmp	rcx, r9
	jb	.LBB9_29
# %bb.30:
	cmp	rax, rcx
	ja	.LBB9_31
	jmp	.LBB9_33
.LBB9_27:
	xor	ecx, ecx
	cmp	rax, rcx
	jbe	.LBB9_33
.LBB9_31:
	mov	rdx, qword ptr [rip + xt_simd_flag]
	mov	r9, rax
	shl	r9, 4
	add	r9, qword ptr [rip + xt_simd_tab]
	mov	r8, rax
	.p2align	4, 0x90
.LBB9_32:                               # =>This Inner Loop Header: Depth=1
	movups	xmm0, xmmword ptr [r9 - 16]
	movups	xmmword ptr [r9], xmm0
	add	r9, -16
	movzx	r10d, byte ptr [rdx + r8 - 1]
	mov	byte ptr [rdx + r8], r10b
	dec	r8
	cmp	r8, rcx
	ja	.LBB9_32
.LBB9_33:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	mov	r8, rcx
	shl	r8, 4
	mov	qword ptr [rdx + r8], rdi
	add	rsi, rdi
	mov	qword ptr [rdx + r8 + 8], rsi
	mov	rdx, qword ptr [rip + xt_simd_flag]
	mov	byte ptr [rdx + rcx], 0
	inc	rax
	mov	qword ptr [rip + xt_simd_n], rax
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB9_35
# %bb.34:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB9_35:
	add	rsp, 40
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
	.def	_xtc_simd_base;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_simd_base                  # -- Begin function _xtc_simd_base
	.p2align	4, 0x90
_xtc_simd_base:                         # @_xtc_simd_base
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB10_3
	.p2align	4, 0x90
.LBB10_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB10_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB10_3
.LBB10_2:                               #   Parent Loop BB10_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB10_2
	jmp	.LBB10_1
.LBB10_3:
	mov	rdx, qword ptr [rip + xt_simd_n]
	test	rdx, rdx
	je	.LBB10_9
# %bb.4:
	mov	r8, qword ptr [rip + xt_simd_tab]
	xor	eax, eax
	movabs	r9, 2305843009213693950
	.p2align	4, 0x90
.LBB10_5:                               # =>This Inner Loop Header: Depth=1
	lea	r10, [rdx + rax]
	mov	r11, r10
	shr	r11
	and	r10, r9
	cmp	qword ptr [r8 + 8*r10], rcx
	lea	r10, [r11 + 1]
	cmova	rdx, r11
	cmovbe	rax, r10
	cmp	rax, rdx
	jb	.LBB10_5
# %bb.6:
	test	rax, rax
	jne	.LBB10_7
	jmp	.LBB10_10
.LBB10_9:
	xor	eax, eax
	test	rax, rax
	je	.LBB10_10
.LBB10_7:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	shl	rax, 4
	cmp	qword ptr [rdx + rax - 8], rcx
	jbe	.LBB10_10
# %bb.8:
	mov	rax, qword ptr [rdx + rax - 16]
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB10_11
	jmp	.LBB10_12
.LBB10_10:
	xor	eax, eax
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB10_12
.LBB10_11:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB10_12:
	ret
                                        # -- End function
	.def	_xt_rt_lock;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_rt_lock                     # -- Begin function _xt_rt_lock
	.p2align	4, 0x90
_xt_rt_lock:                            # @_xt_rt_lock
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB11_3
	.p2align	4, 0x90
.LBB11_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB11_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB11_3
.LBB11_2:                               #   Parent Loop BB11_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB11_2
	jmp	.LBB11_1
.LBB11_3:
	ret
                                        # -- End function
	.def	_xt_rt_unlock;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_rt_unlock                   # -- Begin function _xt_rt_unlock
	.p2align	4, 0x90
_xt_rt_unlock:                          # @_xt_rt_unlock
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB12_2
# %bb.1:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB12_2:
	ret
                                        # -- End function
	.def	_xtc_simd_span;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_simd_span                  # -- Begin function _xtc_simd_span
	.p2align	4, 0x90
_xtc_simd_span:                         # @_xtc_simd_span
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB13_3
	.p2align	4, 0x90
.LBB13_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB13_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB13_3
.LBB13_2:                               #   Parent Loop BB13_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB13_2
	jmp	.LBB13_1
.LBB13_3:
	mov	rax, qword ptr [rip + xt_simd_n]
	test	rax, rax
	je	.LBB13_4
# %bb.5:
	mov	r8, qword ptr [rip + xt_simd_tab]
	xor	edx, edx
	movabs	r9, 2305843009213693950
	.p2align	4, 0x90
.LBB13_6:                               # =>This Inner Loop Header: Depth=1
	lea	r10, [rax + rdx]
	mov	r11, r10
	shr	r11
	and	r10, r9
	cmp	qword ptr [r8 + 8*r10], rcx
	lea	r10, [r11 + 1]
	cmova	rax, r11
	cmovbe	rdx, r10
	cmp	rdx, rax
	jb	.LBB13_6
	jmp	.LBB13_7
.LBB13_4:
	xor	edx, edx
.LBB13_7:
	mov	rax, -1
	test	rdx, rdx
	je	.LBB13_10
# %bb.8:
	mov	r8, qword ptr [rip + xt_simd_tab]
	shl	rdx, 4
	mov	rdx, qword ptr [r8 + rdx - 8]
	sub	rdx, rcx
	jbe	.LBB13_10
# %bb.9:
	mov	rax, rdx
.LBB13_10:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB13_12
# %bb.11:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB13_12:
	ret
                                        # -- End function
	.def	_xtc_simd_watch;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_simd_watch                 # -- Begin function _xtc_simd_watch
	.p2align	4, 0x90
_xtc_simd_watch:                        # @_xtc_simd_watch
# %bb.0:
	push	r14
	push	rsi
	push	rdi
	push	rbx
	sub	rsp, 40
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB14_3
	.p2align	4, 0x90
.LBB14_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB14_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB14_3
.LBB14_2:                               #   Parent Loop BB14_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB14_2
	jmp	.LBB14_1
.LBB14_3:
	mov	rax, qword ptr [rip + xt_simd_n]
	xor	esi, esi
	test	rax, rax
	je	.LBB14_4
# %bb.5:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	edi, edi
	movabs	r8, 2305843009213693950
	.p2align	4, 0x90
.LBB14_6:                               # =>This Inner Loop Header: Depth=1
	lea	r9, [rax + rdi]
	mov	r10, r9
	shr	r10
	and	r9, r8
	cmp	qword ptr [rdx + 8*r9], rcx
	lea	r9, [r10 + 1]
	cmova	rax, r10
	cmovbe	rdi, r9
	cmp	rdi, rax
	jb	.LBB14_6
# %bb.7:
	test	rdi, rdi
	jne	.LBB14_8
	jmp	.LBB14_13
.LBB14_4:
	xor	edi, edi
	test	rdi, rdi
	je	.LBB14_13
.LBB14_8:
	mov	rax, qword ptr [rip + xt_simd_tab]
	dec	rdi
	mov	rbx, rdi
	shl	rbx, 4
	cmp	qword ptr [rax + rbx], rcx
	jne	.LBB14_13
# %bb.9:
	cmp	byte ptr [rip + xt_simd_installed], 0
	jne	.LBB14_11
# %bb.10:
	lea	rdx, [rip + xt_simd_veh]
	mov	r14, rcx
	mov	ecx, 1
	call	AddVectoredExceptionHandler
	mov	rcx, r14
	mov	byte ptr [rip + xt_simd_installed], 1
.LBB14_11:
	mov	rax, qword ptr [rip + xt_simd_tab]
	mov	rdx, qword ptr [rax + rbx + 8]
	sub	rdx, qword ptr [rax + rbx]
	add	rdx, 16383
	and	rdx, -16384
	mov	dword ptr [rsp + 36], 0
	lea	r9, [rsp + 36]
	mov	r8d, 2
	call	VirtualProtect
	test	eax, eax
	je	.LBB14_13
# %bb.12:
	mov	rax, qword ptr [rip + xt_simd_flag]
	or	byte ptr [rax + rdi], 1
	mov	esi, 1
.LBB14_13:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB14_15
# %bb.14:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB14_15:
	mov	eax, esi
	add	rsp, 40
	pop	rbx
	pop	rdi
	pop	rsi
	pop	r14
	ret
                                        # -- End function
	.def	_xtc_simd_unwatch;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_simd_unwatch               # -- Begin function _xtc_simd_unwatch
	.p2align	4, 0x90
_xtc_simd_unwatch:                      # @_xtc_simd_unwatch
# %bb.0:
	sub	rsp, 40
	cmp	dword ptr [rip + _xt_threads_active], 0
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
	je	.LBB15_4
# %bb.5:
	mov	r8, qword ptr [rip + xt_simd_tab]
	xor	eax, eax
	movabs	r9, 2305843009213693950
	.p2align	4, 0x90
.LBB15_6:                               # =>This Inner Loop Header: Depth=1
	lea	r10, [rdx + rax]
	mov	r11, r10
	shr	r11
	and	r10, r9
	cmp	qword ptr [r8 + 8*r10], rcx
	lea	r10, [r11 + 1]
	cmova	rdx, r11
	cmovbe	rax, r10
	cmp	rax, rdx
	jb	.LBB15_6
# %bb.7:
	test	rax, rax
	jne	.LBB15_8
	jmp	.LBB15_11
.LBB15_4:
	xor	eax, eax
	test	rax, rax
	je	.LBB15_11
.LBB15_8:
	mov	r8, qword ptr [rip + xt_simd_tab]
	dec	rax
	mov	r9, rax
	shl	r9, 4
	cmp	qword ptr [r8 + r9], rcx
	jne	.LBB15_11
# %bb.9:
	mov	rdx, qword ptr [rip + xt_simd_flag]
	movzx	r10d, byte ptr [rdx + rax]
	test	r10b, 1
	je	.LBB15_11
# %bb.10:
	and	r10b, -2
	mov	byte ptr [rdx + rax], r10b
	mov	rdx, qword ptr [r8 + r9 + 8]
	sub	rdx, qword ptr [r8 + r9]
	add	rdx, 16383
	and	rdx, -16384
	mov	dword ptr [rsp + 36], 0
	lea	r9, [rsp + 36]
	mov	r8d, 4
	call	VirtualProtect
.LBB15_11:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB15_13
# %bb.12:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB15_13:
	add	rsp, 40
	ret
                                        # -- End function
	.def	_xtc_simd_dirty;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_simd_dirty                 # -- Begin function _xtc_simd_dirty
	.p2align	4, 0x90
_xtc_simd_dirty:                        # @_xtc_simd_dirty
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
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
	mov	rax, qword ptr [rip + xt_simd_n]
	test	rax, rax
	je	.LBB16_4
# %bb.5:
	mov	r8, qword ptr [rip + xt_simd_tab]
	xor	edx, edx
	movabs	r9, 2305843009213693950
	.p2align	4, 0x90
.LBB16_6:                               # =>This Inner Loop Header: Depth=1
	lea	r10, [rax + rdx]
	mov	r11, r10
	shr	r11
	and	r10, r9
	cmp	qword ptr [r8 + 8*r10], rcx
	lea	r10, [r11 + 1]
	cmova	rax, r11
	cmovbe	rdx, r10
	cmp	rdx, rax
	jb	.LBB16_6
	jmp	.LBB16_7
.LBB16_4:
	xor	edx, edx
.LBB16_7:
	mov	eax, 1
	test	rdx, rdx
	je	.LBB16_10
# %bb.8:
	mov	r8, qword ptr [rip + xt_simd_tab]
	dec	rdx
	mov	r9, rdx
	shl	r9, 4
	cmp	qword ptr [r8 + r9], rcx
	jne	.LBB16_10
# %bb.9:
	mov	rax, qword ptr [rip + xt_simd_flag]
	movzx	eax, byte ptr [rax + rdx]
	not	eax
	and	eax, 1
.LBB16_10:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB16_12
# %bb.11:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB16_12:
	ret
                                        # -- End function
	.def	_xtc_alloc_aligned;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_alloc_aligned              # -- Begin function _xtc_alloc_aligned
	.p2align	4, 0x90
_xtc_alloc_aligned:                     # @_xtc_alloc_aligned
# %bb.0:
	push	r15
	push	r14
	push	r13
	push	r12
	push	rsi
	push	rdi
	push	rbp
	push	rbx
	sub	rsp, 56
	mov	rsi, r8
	mov	rbx, rdx
	mov	rdi, rcx
	test	rdx, rdx
	je	.LBB17_3
# %bb.1:
	mov	rax, -1048577
	xor	edx, edx
	div	rbx
	cmp	rax, rdi
	jae	.LBB17_3
# %bb.2:
	mov	dword ptr [rsp + 52], 0
	mov	ecx, -12
	call	GetStdHandle
	mov	qword ptr [rsp + 32], 0
	lea	rdx, [rip + xt_size_check.msg]
	lea	r9, [rsp + 52]
	mov	rcx, rax
	mov	r8d, 38
	call	WriteFile
	mov	ecx, 134
	call	_xt_exit
.LBB17_3:
	mov	r15, rbx
	imul	r15, rdi
	cmp	r15, 17
	mov	r14d, 16
	cmovae	r14, r15
	add	r14, 16383
	and	r14, -16384
	call	GetProcessHeap
	add	r14, 16440
	mov	rcx, rax
	mov	edx, 8
	mov	r8, r14
	call	HeapAlloc
	test	rax, rax
	je	.LBB17_4
# %bb.5:
	lea	rcx, [rax + 8]
	add	rax, 16439
	and	rax, -16384
	mov	dword ptr [rax - 40], 1481920323
	mov	qword ptr [rax - 36], rbx
	mov	qword ptr [rax - 28], rdi
	mov	qword ptr [rax - 20], rsi
	mov	qword ptr [rax - 12], 0
	mov	dword ptr [rax - 4], 1
	mov	qword ptr [rax - 48], rcx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB17_8
	.p2align	4, 0x90
.LBB17_6:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB17_7 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_rt_spin], ecx
	test	ecx, ecx
	je	.LBB17_8
.LBB17_7:                               #   Parent Loop BB17_6 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_rt_spin]
	test	ecx, ecx
	jne	.LBB17_7
	jmp	.LBB17_6
.LBB17_8:
	mov	rcx, qword ptr [rip + xt_simd_cap]
	cmp	qword ptr [rip + xt_simd_n], rcx
	jne	.LBB17_28
# %bb.9:
	mov	r14, rax
	lea	rax, [rcx + rcx]
	test	rcx, rcx
	mov	r12d, 64
	cmovne	r12, rax
	mov	rsi, r12
	shl	rsi, 4
	call	GetProcessHeap
	or	rsi, 8
	mov	rcx, rax
	mov	edx, 8
	mov	r8, rsi
	call	HeapAlloc
	mov	rbx, rax
	lea	rdi, [rax + 8]
	test	rax, rax
	setne	r13b
	cmove	rdi, rax
	call	GetProcessHeap
	lea	r8, [r12 + 8]
	mov	rcx, rax
	mov	edx, 8
	call	HeapAlloc
	lea	rsi, [rax + 8]
	test	rax, rax
	setne	bpl
	cmove	rsi, rax
	and	bpl, r13b
	cmp	bpl, 1
	jne	.LBB17_21
# %bb.10:
	mov	rcx, qword ptr [rip + xt_simd_n]
	mov	rax, rcx
	add	rax, rcx
	je	.LBB17_13
# %bb.11:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	r8d, r8d
	.p2align	4, 0x90
.LBB17_12:                              # =>This Inner Loop Header: Depth=1
	mov	r9, qword ptr [rdx + 8*r8]
	mov	qword ptr [rdi + 8*r8], r9
	inc	r8
	cmp	rax, r8
	jne	.LBB17_12
.LBB17_13:
	test	rcx, rcx
	mov	rax, r14
	je	.LBB17_16
# %bb.14:
	mov	rdx, qword ptr [rip + xt_simd_flag]
	xor	r8d, r8d
	.p2align	4, 0x90
.LBB17_15:                              # =>This Inner Loop Header: Depth=1
	movzx	r9d, byte ptr [rdx + r8]
	mov	byte ptr [rsi + r8], r9b
	inc	r8
	cmp	rcx, r8
	jne	.LBB17_15
.LBB17_16:
	mov	rbx, qword ptr [rip + xt_simd_tab]
	test	rbx, rbx
	je	.LBB17_18
# %bb.17:
	call	GetProcessHeap
	add	rbx, -8
	mov	rcx, rax
	xor	edx, edx
	mov	r8, rbx
	call	HeapFree
	mov	rax, r14
.LBB17_18:
	mov	rbx, qword ptr [rip + xt_simd_flag]
	test	rbx, rbx
	je	.LBB17_20
# %bb.19:
	call	GetProcessHeap
	add	rbx, -8
	mov	rcx, rax
	xor	edx, edx
	mov	r8, rbx
	call	HeapFree
	mov	rax, r14
.LBB17_20:
	mov	qword ptr [rip + xt_simd_tab], rdi
	mov	qword ptr [rip + xt_simd_flag], rsi
	mov	qword ptr [rip + xt_simd_cap], r12
	jmp	.LBB17_27
.LBB17_4:
	xor	eax, eax
	jmp	.LBB17_37
.LBB17_21:
	test	rbx, rbx
	je	.LBB17_23
# %bb.22:
	mov	rbx, rax
	call	GetProcessHeap
	add	rdi, -8
	mov	rcx, rax
	xor	edx, edx
	mov	r8, rdi
	call	HeapFree
	mov	rax, rbx
.LBB17_23:
	test	rax, rax
	je	.LBB17_25
# %bb.24:
	call	GetProcessHeap
	add	rsi, -8
	mov	rcx, rax
	xor	edx, edx
	mov	r8, rsi
	call	HeapFree
.LBB17_25:
	cmp	dword ptr [rip + _xt_threads_active], 0
	mov	rax, r14
	je	.LBB17_27
# %bb.26:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB17_27:
	test	bpl, bpl
	je	.LBB17_37
.LBB17_28:
	mov	rcx, qword ptr [rip + xt_simd_n]
	test	rcx, rcx
	je	.LBB17_29
# %bb.30:
	mov	r8, qword ptr [rip + xt_simd_tab]
	xor	edx, edx
	movabs	r9, 2305843009213693950
	mov	r10, rcx
	.p2align	4, 0x90
.LBB17_31:                              # =>This Inner Loop Header: Depth=1
	lea	r11, [r10 + rdx]
	mov	rsi, r11
	shr	rsi
	and	r11, r9
	cmp	qword ptr [r8 + 8*r11], rax
	lea	r11, [rsi + 1]
	cmova	r10, rsi
	cmovbe	rdx, r11
	cmp	rdx, r10
	jb	.LBB17_31
# %bb.32:
	cmp	rcx, rdx
	ja	.LBB17_33
	jmp	.LBB17_35
.LBB17_29:
	xor	edx, edx
	cmp	rcx, rdx
	jbe	.LBB17_35
.LBB17_33:
	mov	r8, qword ptr [rip + xt_simd_flag]
	mov	r10, rcx
	shl	r10, 4
	add	r10, qword ptr [rip + xt_simd_tab]
	mov	r9, rcx
	.p2align	4, 0x90
.LBB17_34:                              # =>This Inner Loop Header: Depth=1
	movups	xmm0, xmmword ptr [r10 - 16]
	movups	xmmword ptr [r10], xmm0
	add	r10, -16
	movzx	r11d, byte ptr [r8 + r9 - 1]
	mov	byte ptr [r8 + r9], r11b
	dec	r9
	cmp	r9, rdx
	ja	.LBB17_34
.LBB17_35:
	mov	r8, qword ptr [rip + xt_simd_tab]
	mov	r9, rdx
	shl	r9, 4
	mov	qword ptr [r8 + r9], rax
	add	r15, rax
	mov	qword ptr [r8 + r9 + 8], r15
	mov	r8, qword ptr [rip + xt_simd_flag]
	mov	byte ptr [r8 + rdx], 0
	inc	rcx
	mov	qword ptr [rip + xt_simd_n], rcx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB17_37
# %bb.36:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB17_37:
	add	rsp, 56
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
	.def	_xtc_alloc_line;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_alloc_line                 # -- Begin function _xtc_alloc_line
	.p2align	4, 0x90
_xtc_alloc_line:                        # @_xtc_alloc_line
# %bb.0:
	push	rsi
	push	rdi
	push	rbx
	sub	rsp, 48
	mov	rdi, rdx
	mov	rsi, rcx
	test	rdx, rdx
	je	.LBB18_3
# %bb.1:
	mov	rax, -1048577
	xor	edx, edx
	div	rdi
	cmp	rax, rsi
	jae	.LBB18_3
# %bb.2:
	mov	dword ptr [rsp + 44], 0
	mov	ecx, -12
	call	GetStdHandle
	mov	qword ptr [rsp + 32], 0
	lea	rdx, [rip + xt_size_check.msg]
	lea	r9, [rsp + 44]
	mov	rcx, rax
	mov	r8d, 38
	call	WriteFile
	mov	ecx, 134
	call	_xt_exit
.LBB18_3:
	mov	rbx, rdi
	imul	rbx, rsi
	call	GetProcessHeap
	add	rbx, 120
	mov	rcx, rax
	mov	edx, 8
	mov	r8, rbx
	call	HeapAlloc
	test	rax, rax
	je	.LBB18_4
# %bb.5:
	lea	rcx, [rax + 8]
	add	rax, 119
	and	rax, -64
	mov	dword ptr [rax - 40], 1481920323
	mov	qword ptr [rax - 36], rdi
	mov	qword ptr [rax - 28], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax - 20], xmm0
	mov	dword ptr [rax - 4], 1
	mov	qword ptr [rax - 48], rcx
	jmp	.LBB18_6
.LBB18_4:
	xor	eax, eax
.LBB18_6:
	add	rsp, 48
	pop	rbx
	pop	rdi
	pop	rsi
	ret
                                        # -- End function
	.def	_xtc_new_simd_u8;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_simd_u8                # -- Begin function _xtc_new_simd_u8
	.p2align	4, 0x90
_xtc_new_simd_u8:                       # @_xtc_new_simd_u8
# %bb.0:
	mov	edx, 1
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
                                        # -- End function
	.def	_xtc_new_simd_i8;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_simd_i8                # -- Begin function _xtc_new_simd_i8
	.p2align	4, 0x90
_xtc_new_simd_i8:                       # @_xtc_new_simd_i8
# %bb.0:
	mov	edx, 1
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
                                        # -- End function
	.def	_xtc_new_simd_bool;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_simd_bool              # -- Begin function _xtc_new_simd_bool
	.p2align	4, 0x90
_xtc_new_simd_bool:                     # @_xtc_new_simd_bool
# %bb.0:
	mov	edx, 1
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
                                        # -- End function
	.def	_xtc_new_simd_u16;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_simd_u16               # -- Begin function _xtc_new_simd_u16
	.p2align	4, 0x90
_xtc_new_simd_u16:                      # @_xtc_new_simd_u16
# %bb.0:
	mov	edx, 2
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
                                        # -- End function
	.def	_xtc_new_simd_i16;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_simd_i16               # -- Begin function _xtc_new_simd_i16
	.p2align	4, 0x90
_xtc_new_simd_i16:                      # @_xtc_new_simd_i16
# %bb.0:
	mov	edx, 2
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
                                        # -- End function
	.def	_xtc_new_simd_u32;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_simd_u32               # -- Begin function _xtc_new_simd_u32
	.p2align	4, 0x90
_xtc_new_simd_u32:                      # @_xtc_new_simd_u32
# %bb.0:
	mov	edx, 4
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
                                        # -- End function
	.def	_xtc_new_simd_i32;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_simd_i32               # -- Begin function _xtc_new_simd_i32
	.p2align	4, 0x90
_xtc_new_simd_i32:                      # @_xtc_new_simd_i32
# %bb.0:
	mov	edx, 4
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
                                        # -- End function
	.def	_xtc_new_simd_float;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_simd_float             # -- Begin function _xtc_new_simd_float
	.p2align	4, 0x90
_xtc_new_simd_float:                    # @_xtc_new_simd_float
# %bb.0:
	mov	edx, 4
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
                                        # -- End function
	.def	_xtc_new_simd_u64;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_simd_u64               # -- Begin function _xtc_new_simd_u64
	.p2align	4, 0x90
_xtc_new_simd_u64:                      # @_xtc_new_simd_u64
# %bb.0:
	mov	edx, 8
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
                                        # -- End function
	.def	_xtc_new_simd_i64;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_simd_i64               # -- Begin function _xtc_new_simd_i64
	.p2align	4, 0x90
_xtc_new_simd_i64:                      # @_xtc_new_simd_i64
# %bb.0:
	mov	edx, 8
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
                                        # -- End function
	.def	_xtc_new_simd_double;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_simd_double            # -- Begin function _xtc_new_simd_double
	.p2align	4, 0x90
_xtc_new_simd_double:                   # @_xtc_new_simd_double
# %bb.0:
	mov	edx, 8
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
                                        # -- End function
	.def	_xtc_new_simd_pointer;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_simd_pointer           # -- Begin function _xtc_new_simd_pointer
	.p2align	4, 0x90
_xtc_new_simd_pointer:                  # @_xtc_new_simd_pointer
# %bb.0:
	mov	edx, 8
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
                                        # -- End function
	.def	_xtc_new_simd_string;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_simd_string            # -- Begin function _xtc_new_simd_string
	.p2align	4, 0x90
_xtc_new_simd_string:                   # @_xtc_new_simd_string
# %bb.0:
	mov	edx, 8
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
                                        # -- End function
	.def	_xtc_new_u8;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_u8                     # -- Begin function _xtc_new_u8
	.p2align	4, 0x90
_xtc_new_u8:                            # @_xtc_new_u8
# %bb.0:
	mov	edx, 1
	cmp	rcx, 65536
	jb	.LBB32_1
# %bb.3:
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB32_1:
	cmp	rcx, 1024
	jae	_xtc_alloc_line                 # TAILCALL
# %bb.2:
	xor	r8d, r8d
	jmp	_xtc_alloc                      # TAILCALL
                                        # -- End function
	.def	_xtc_new_i8;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_i8                     # -- Begin function _xtc_new_i8
	.p2align	4, 0x90
_xtc_new_i8:                            # @_xtc_new_i8
# %bb.0:
	mov	edx, 1
	cmp	rcx, 65536
	jb	.LBB33_1
# %bb.3:
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB33_1:
	cmp	rcx, 1024
	jae	_xtc_alloc_line                 # TAILCALL
# %bb.2:
	xor	r8d, r8d
	jmp	_xtc_alloc                      # TAILCALL
                                        # -- End function
	.def	_xtc_new_u16;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_u16                    # -- Begin function _xtc_new_u16
	.p2align	4, 0x90
_xtc_new_u16:                           # @_xtc_new_u16
# %bb.0:
	lea	rax, [rcx + rcx]
	mov	edx, 2
	cmp	rax, 65536
	jb	.LBB34_1
# %bb.3:
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB34_1:
	cmp	rax, 1024
	jae	_xtc_alloc_line                 # TAILCALL
# %bb.2:
	xor	r8d, r8d
	jmp	_xtc_alloc                      # TAILCALL
                                        # -- End function
	.def	_xtc_new_i16;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_i16                    # -- Begin function _xtc_new_i16
	.p2align	4, 0x90
_xtc_new_i16:                           # @_xtc_new_i16
# %bb.0:
	lea	rax, [rcx + rcx]
	mov	edx, 2
	cmp	rax, 65536
	jb	.LBB35_1
# %bb.3:
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB35_1:
	cmp	rax, 1024
	jae	_xtc_alloc_line                 # TAILCALL
# %bb.2:
	xor	r8d, r8d
	jmp	_xtc_alloc                      # TAILCALL
                                        # -- End function
	.def	_xtc_new_u32;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_u32                    # -- Begin function _xtc_new_u32
	.p2align	4, 0x90
_xtc_new_u32:                           # @_xtc_new_u32
# %bb.0:
	lea	rax, [4*rcx]
	mov	edx, 4
	cmp	rax, 65536
	jb	.LBB36_1
# %bb.3:
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB36_1:
	cmp	rax, 1024
	jae	_xtc_alloc_line                 # TAILCALL
# %bb.2:
	xor	r8d, r8d
	jmp	_xtc_alloc                      # TAILCALL
                                        # -- End function
	.def	_xtc_new_i32;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_i32                    # -- Begin function _xtc_new_i32
	.p2align	4, 0x90
_xtc_new_i32:                           # @_xtc_new_i32
# %bb.0:
	lea	rax, [4*rcx]
	mov	edx, 4
	cmp	rax, 65536
	jb	.LBB37_1
# %bb.3:
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB37_1:
	cmp	rax, 1024
	jae	_xtc_alloc_line                 # TAILCALL
# %bb.2:
	xor	r8d, r8d
	jmp	_xtc_alloc                      # TAILCALL
                                        # -- End function
	.def	_xtc_new_pointer;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_pointer                # -- Begin function _xtc_new_pointer
	.p2align	4, 0x90
_xtc_new_pointer:                       # @_xtc_new_pointer
# %bb.0:
	mov	edx, 8
	xor	r8d, r8d
	jmp	_xtc_alloc                      # TAILCALL
                                        # -- End function
	.def	_xtc_new_u64;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_u64                    # -- Begin function _xtc_new_u64
	.p2align	4, 0x90
_xtc_new_u64:                           # @_xtc_new_u64
# %bb.0:
	lea	rax, [8*rcx]
	mov	edx, 8
	cmp	rax, 65536
	jb	.LBB39_1
# %bb.3:
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB39_1:
	cmp	rax, 1024
	jae	_xtc_alloc_line                 # TAILCALL
# %bb.2:
	xor	r8d, r8d
	jmp	_xtc_alloc                      # TAILCALL
                                        # -- End function
	.def	_xtc_new_i64;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_i64                    # -- Begin function _xtc_new_i64
	.p2align	4, 0x90
_xtc_new_i64:                           # @_xtc_new_i64
# %bb.0:
	lea	rax, [8*rcx]
	mov	edx, 8
	cmp	rax, 65536
	jb	.LBB40_1
# %bb.3:
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB40_1:
	cmp	rax, 1024
	jae	_xtc_alloc_line                 # TAILCALL
# %bb.2:
	xor	r8d, r8d
	jmp	_xtc_alloc                      # TAILCALL
                                        # -- End function
	.def	_xtc_new_bool;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_bool                   # -- Begin function _xtc_new_bool
	.p2align	4, 0x90
_xtc_new_bool:                          # @_xtc_new_bool
# %bb.0:
	mov	edx, 1
	cmp	rcx, 65536
	jb	.LBB41_1
# %bb.3:
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB41_1:
	cmp	rcx, 1024
	jae	_xtc_alloc_line                 # TAILCALL
# %bb.2:
	xor	r8d, r8d
	jmp	_xtc_alloc                      # TAILCALL
                                        # -- End function
	.def	_xtc_new_float;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_float                  # -- Begin function _xtc_new_float
	.p2align	4, 0x90
_xtc_new_float:                         # @_xtc_new_float
# %bb.0:
	lea	rax, [4*rcx]
	mov	edx, 4
	cmp	rax, 65536
	jb	.LBB42_1
# %bb.3:
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB42_1:
	cmp	rax, 1024
	jae	_xtc_alloc_line                 # TAILCALL
# %bb.2:
	xor	r8d, r8d
	jmp	_xtc_alloc                      # TAILCALL
                                        # -- End function
	.def	_xtc_new_double;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_double                 # -- Begin function _xtc_new_double
	.p2align	4, 0x90
_xtc_new_double:                        # @_xtc_new_double
# %bb.0:
	lea	rax, [8*rcx]
	mov	edx, 8
	cmp	rax, 65536
	jb	.LBB43_1
# %bb.3:
	xor	r8d, r8d
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB43_1:
	cmp	rax, 1024
	jae	_xtc_alloc_line                 # TAILCALL
# %bb.2:
	xor	r8d, r8d
	jmp	_xtc_alloc                      # TAILCALL
                                        # -- End function
	.def	_xtc_new_string;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_string                 # -- Begin function _xtc_new_string
	.p2align	4, 0x90
_xtc_new_string:                        # @_xtc_new_string
# %bb.0:
	mov	edx, 8
	xor	r8d, r8d
	jmp	_xtc_alloc                      # TAILCALL
                                        # -- End function
	.def	_xtc_count;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_count                      # -- Begin function _xtc_count
	.p2align	4, 0x90
_xtc_count:                             # @_xtc_count
# %bb.0:
	mov	eax, dword ptr [rcx - 28]
	ret
                                        # -- End function
	.def	_xtc_dealloc;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_dealloc                    # -- Begin function _xtc_dealloc
	.p2align	4, 0x90
_xtc_dealloc:                           # @_xtc_dealloc
# %bb.0:
	push	r15
	push	r14
	push	rsi
	push	rdi
	push	rbx
	sub	rsp, 32
	mov	rsi, rcx
	test	rcx, rcx
	je	.LBB46_9
# %bb.1:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB46_4
	.p2align	4, 0x90
.LBB46_2:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB46_3 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB46_4
.LBB46_3:                               #   Parent Loop BB46_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB46_3
	jmp	.LBB46_2
.LBB46_4:
	mov	rax, qword ptr [rsi - 12]
	test	rax, rax
	je	.LBB46_7
# %bb.5:
	xorps	xmm0, xmm0
	.p2align	4, 0x90
.LBB46_6:                               # =>This Inner Loop Header: Depth=1
	mov	rcx, qword ptr [rax - 8]
	movups	xmmword ptr [rax - 16], xmm0
	mov	qword ptr [rax], 0
	mov	rax, rcx
	test	rcx, rcx
	jne	.LBB46_6
.LBB46_7:
	mov	qword ptr [rsi - 12], 0
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB46_9
# %bb.8:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB46_9:
	mov	rbx, qword ptr [rsi - 20]
	cmp	dword ptr [rsi - 40], 1481920323
	jne	.LBB46_31
# %bb.10:
	test	rbx, rbx
	je	.LBB46_12
# %bb.11:
	mov	rcx, rsi
	call	rbx
.LBB46_12:
	mov	rax, rsi
	shl	rax, 50
	jne	.LBB46_28
# %bb.13:
	mov	rcx, rsi
	call	_xtc_simd_unwatch
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB46_16
	.p2align	4, 0x90
.LBB46_14:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB46_15 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB46_16
.LBB46_15:                              #   Parent Loop BB46_14 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB46_15
	jmp	.LBB46_14
.LBB46_31:
	test	rbx, rbx
	je	.LBB46_35
# %bb.32:
	mov	r14, qword ptr [rsi - 36]
	mov	r15, qword ptr [rsi - 28]
	mov	dword ptr [rsi - 4], -2147483648
	test	r15, r15
	je	.LBB46_35
# %bb.33:
	mov	rdi, rsi
	.p2align	4, 0x90
.LBB46_34:                              # =>This Inner Loop Header: Depth=1
	mov	rcx, rdi
	call	rbx
	add	rdi, r14
	dec	r15
	jne	.LBB46_34
.LBB46_35:
	call	GetProcessHeap
	add	rsi, -48
	jmp	.LBB46_30
.LBB46_16:
	mov	rax, qword ptr [rip + xt_simd_n]
	test	rax, rax
	je	.LBB46_17
# %bb.18:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	ecx, ecx
	movabs	r8, 2305843009213693950
	mov	r9, rax
	.p2align	4, 0x90
.LBB46_19:                              # =>This Inner Loop Header: Depth=1
	lea	r10, [r9 + rcx]
	mov	r11, r10
	shr	r11
	and	r10, r8
	cmp	qword ptr [rdx + 8*r10], rsi
	lea	r10, [r11 + 1]
	cmova	r9, r11
	cmovbe	rcx, r10
	cmp	rcx, r9
	jb	.LBB46_19
# %bb.20:
	test	rcx, rcx
	jne	.LBB46_21
	jmp	.LBB46_26
.LBB46_17:
	xor	ecx, ecx
	test	rcx, rcx
	je	.LBB46_26
.LBB46_21:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	mov	r9, rcx
	shl	r9, 4
	cmp	qword ptr [rdx + r9 - 16], rsi
	jne	.LBB46_26
# %bb.22:
	cmp	rcx, rax
	jae	.LBB46_25
# %bb.23:
	mov	r8, qword ptr [rip + xt_simd_flag]
	add	rdx, r9
	.p2align	4, 0x90
.LBB46_24:                              # =>This Inner Loop Header: Depth=1
	movups	xmm0, xmmword ptr [rdx]
	movups	xmmword ptr [rdx - 16], xmm0
	movzx	r9d, byte ptr [r8 + rcx]
	mov	byte ptr [r8 + rcx - 1], r9b
	inc	rcx
	add	rdx, 16
	cmp	rax, rcx
	jne	.LBB46_24
.LBB46_25:
	dec	rax
	mov	qword ptr [rip + xt_simd_n], rax
.LBB46_26:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB46_28
# %bb.27:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB46_28:
	mov	rsi, qword ptr [rsi - 48]
	test	rsi, rsi
	je	.LBB46_36
# %bb.29:
	call	GetProcessHeap
	add	rsi, -8
.LBB46_30:
	mov	rcx, rax
	xor	edx, edx
	mov	r8, rsi
	add	rsp, 32
	pop	rbx
	pop	rdi
	pop	rsi
	pop	r14
	pop	r15
	jmp	HeapFree                        # TAILCALL
.LBB46_36:
	add	rsp, 32
	pop	rbx
	pop	rdi
	pop	rsi
	pop	r14
	pop	r15
	ret
                                        # -- End function
	.def	_xtc_weak_zero_for;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_weak_zero_for              # -- Begin function _xtc_weak_zero_for
	.p2align	4, 0x90
_xtc_weak_zero_for:                     # @_xtc_weak_zero_for
# %bb.0:
	test	rcx, rcx
	je	.LBB47_9
# %bb.1:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB47_4
	.p2align	4, 0x90
.LBB47_2:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB47_3 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB47_4
.LBB47_3:                               #   Parent Loop BB47_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB47_3
	jmp	.LBB47_2
.LBB47_4:
	mov	rax, qword ptr [rcx - 12]
	test	rax, rax
	je	.LBB47_7
# %bb.5:
	xorps	xmm0, xmm0
	.p2align	4, 0x90
.LBB47_6:                               # =>This Inner Loop Header: Depth=1
	mov	rdx, qword ptr [rax - 8]
	movups	xmmword ptr [rax - 16], xmm0
	mov	qword ptr [rax], 0
	mov	rax, rdx
	test	rdx, rdx
	jne	.LBB47_6
.LBB47_7:
	mov	qword ptr [rcx - 12], 0
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB47_9
# %bb.8:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB47_9:
	ret
                                        # -- End function
	.def	_xtc_weak_unregister;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_weak_unregister            # -- Begin function _xtc_weak_unregister
	.p2align	4, 0x90
_xtc_weak_unregister:                   # @_xtc_weak_unregister
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB48_3
	.p2align	4, 0x90
.LBB48_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB48_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB48_3
.LBB48_2:                               #   Parent Loop BB48_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB48_2
	jmp	.LBB48_1
.LBB48_3:
	mov	rax, qword ptr [rcx - 16]
	test	rax, rax
	je	.LBB48_8
# %bb.4:
	lea	rdx, [rcx - 16]
	cmp	qword ptr [rax], rcx
	jne	.LBB48_7
# %bb.5:
	mov	rcx, qword ptr [rcx - 8]
	mov	qword ptr [rax], rcx
	test	rcx, rcx
	je	.LBB48_7
# %bb.6:
	mov	qword ptr [rcx - 16], rax
.LBB48_7:
	xorps	xmm0, xmm0
	movups	xmmword ptr [rdx], xmm0
.LBB48_8:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB48_10
# %bb.9:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB48_10:
	ret
                                        # -- End function
	.def	_xtc_weak_register;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_weak_register              # -- Begin function _xtc_weak_register
	.p2align	4, 0x90
_xtc_weak_register:                     # @_xtc_weak_register
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB49_3
	.p2align	4, 0x90
.LBB49_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB49_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB49_3
.LBB49_2:                               #   Parent Loop BB49_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB49_2
	jmp	.LBB49_1
.LBB49_3:
	mov	rax, qword ptr [rcx - 16]
	test	rax, rax
	je	.LBB49_8
# %bb.4:
	lea	r8, [rcx - 16]
	cmp	qword ptr [rax], rcx
	jne	.LBB49_7
# %bb.5:
	mov	r9, qword ptr [rcx - 8]
	mov	qword ptr [rax], r9
	test	r9, r9
	je	.LBB49_7
# %bb.6:
	mov	qword ptr [r9 - 16], rax
.LBB49_7:
	xorps	xmm0, xmm0
	movups	xmmword ptr [r8], xmm0
.LBB49_8:
	test	rdx, rdx
	je	.LBB49_13
# %bb.9:
	cmp	dword ptr [rdx - 40], 1481920322
	jne	.LBB49_13
# %bb.10:
	mov	rax, qword ptr [rdx - 12]
	add	rdx, -12
	mov	qword ptr [rcx - 16], rdx
	mov	qword ptr [rcx - 8], rax
	test	rax, rax
	je	.LBB49_12
# %bb.11:
	lea	r8, [rcx - 8]
	mov	qword ptr [rax - 16], r8
.LBB49_12:
	mov	qword ptr [rdx], rcx
.LBB49_13:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB49_15
# %bb.14:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB49_15:
	ret
                                        # -- End function
	.def	_xtc_weak_load;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_weak_load                  # -- Begin function _xtc_weak_load
	.p2align	4, 0x90
_xtc_weak_load:                         # @_xtc_weak_load
# %bb.0:
	mov	rax, qword ptr [rcx]
	ret
                                        # -- End function
	.def	srandom;
	.scl	2;
	.type	32;
	.endef
	.globl	srandom                         # -- Begin function srandom
	.p2align	4, 0x90
srandom:                                # @srandom
# %bb.0:
                                        # kill: def $ecx killed $ecx def $rcx
	cmp	ecx, 1
	adc	ecx, 0
	mov	qword ptr [rip + xt_rand_state], rcx
	ret
                                        # -- End function
	.def	random;
	.scl	2;
	.type	32;
	.endef
	.globl	random                          # -- Begin function random
	.p2align	4, 0x90
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
                                        # kill: def $eax killed $eax killed $rax
	ret
                                        # -- End function
	.def	_xt_srand;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_srand                       # -- Begin function _xt_srand
	.p2align	4, 0x90
_xt_srand:                              # @_xt_srand
# %bb.0:
                                        # kill: def $ecx killed $ecx def $rcx
	cmp	ecx, 1
	adc	ecx, 0
	mov	qword ptr [rip + xt_rand_state], rcx
	ret
                                        # -- End function
	.def	_xt_rand_u32;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_rand_u32                    # -- Begin function _xt_rand_u32
	.p2align	4, 0x90
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
                                        # -- End function
	.def	_xt_rand_f;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	2, 0x0                          # -- Begin function _xt_rand_f
.LCPI55_0:
	.long	0x30000000                      # float 4.65661287E-10
.LCPI55_1:
	.long	0x3f000000                      # float 0.5
	.text
	.globl	_xt_rand_f
	.p2align	4, 0x90
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
	mulss	xmm0, dword ptr [rip + .LCPI55_0]
	movss	xmm1, dword ptr [rip + .LCPI55_1] # xmm1 = [5.0E-1,0.0E+0,0.0E+0,0.0E+0]
	mulss	xmm0, xmm1
	addss	xmm0, xmm1
	ret
                                        # -- End function
	.def	_xt_rand_d;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	3, 0x0                          # -- Begin function _xt_rand_d
.LCPI56_0:
	.quad	0x3e00000000000000              # double 4.6566128730773926E-10
.LCPI56_1:
	.quad	0x3fe0000000000000              # double 0.5
	.text
	.globl	_xt_rand_d
	.p2align	4, 0x90
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
	mulsd	xmm0, qword ptr [rip + .LCPI56_0]
	movsd	xmm1, qword ptr [rip + .LCPI56_1] # xmm1 = [5.0E-1,0.0E+0]
	mulsd	xmm0, xmm1
	addsd	xmm0, xmm1
	ret
                                        # -- End function
	.def	_xt_clk_reset;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	4, 0x0                          # -- Begin function _xt_clk_reset
.LCPI57_0:
	.long	1127219200                      # 0x43300000
	.long	1160773632                      # 0x45300000
	.long	0                               # 0x0
	.long	0                               # 0x0
.LCPI57_1:
	.quad	0x4330000000000000              # double 4503599627370496
	.quad	0x4530000000000000              # double 1.9342813113834067E+25
.LCPI57_2:
	.quad	0x3e7ad7f29abcaf48              # double 9.9999999999999995E-8
	.text
	.globl	_xt_clk_reset
	.p2align	4, 0x90
_xt_clk_reset:                          # @_xt_clk_reset
# %bb.0:
	sub	rsp, 40
	mov	qword ptr [rsp + 32], 0
	lea	rcx, [rsp + 32]
	call	GetSystemTimeAsFileTime
	movsd	xmm0, qword ptr [rsp + 32]      # xmm0 = mem[0],zero
	unpcklps	xmm0, xmmword ptr [rip + .LCPI57_0] # xmm0 = xmm0[0],mem[0],xmm0[1],mem[1]
	subpd	xmm0, xmmword ptr [rip + .LCPI57_1]
	movapd	xmm1, xmm0
	unpckhpd	xmm1, xmm0                      # xmm1 = xmm1[1],xmm0[1]
	addsd	xmm1, xmm0
	mulsd	xmm1, qword ptr [rip + .LCPI57_2]
	movsd	qword ptr [rip + xt_clk_origin], xmm1
	add	rsp, 40
	ret
                                        # -- End function
	.def	_xt_clk_ticks;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	4, 0x0                          # -- Begin function _xt_clk_ticks
.LCPI58_0:
	.long	1127219200                      # 0x43300000
	.long	1160773632                      # 0x45300000
	.long	0                               # 0x0
	.long	0                               # 0x0
.LCPI58_1:
	.quad	0x4330000000000000              # double 4503599627370496
	.quad	0x4530000000000000              # double 1.9342813113834067E+25
.LCPI58_2:
	.quad	0x3e7ad7f29abcaf48              # double 9.9999999999999995E-8
.LCPI58_3:
	.quad	0x412e848000000000              # double 1.0E+6
	.text
	.globl	_xt_clk_ticks
	.p2align	4, 0x90
_xt_clk_ticks:                          # @_xt_clk_ticks
# %bb.0:
	sub	rsp, 40
	mov	qword ptr [rsp + 32], 0
	lea	rcx, [rsp + 32]
	call	GetSystemTimeAsFileTime
	movsd	xmm0, qword ptr [rsp + 32]      # xmm0 = mem[0],zero
	unpcklps	xmm0, xmmword ptr [rip + .LCPI58_0] # xmm0 = xmm0[0],mem[0],xmm0[1],mem[1]
	subpd	xmm0, xmmword ptr [rip + .LCPI58_1]
	movapd	xmm1, xmm0
	unpckhpd	xmm1, xmm0                      # xmm1 = xmm1[1],xmm0[1]
	addsd	xmm1, xmm0
	mulsd	xmm1, qword ptr [rip + .LCPI58_2]
	subsd	xmm1, qword ptr [rip + xt_clk_origin]
	mulsd	xmm1, qword ptr [rip + .LCPI58_3]
	cvttsd2si	rax, xmm1
                                        # kill: def $eax killed $eax killed $rax
	add	rsp, 40
	ret
                                        # -- End function
	.def	_xt_clk_delay;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	3, 0x0                          # -- Begin function _xt_clk_delay
.LCPI59_0:
	.quad	0x404e000000000000              # double 60
.LCPI59_1:
	.quad	0x41cdcd6500000000              # double 1.0E+9
.LCPI59_2:
	.quad	0x43e0000000000000              # double 9.2233720368547758E+18
	.text
	.globl	_xt_clk_delay
	.p2align	4, 0x90
_xt_clk_delay:                          # @_xt_clk_delay
# %bb.0:
	mov	eax, ecx
	cvtsi2sd	xmm0, rax
	divsd	xmm0, qword ptr [rip + .LCPI59_0]
	mulsd	xmm0, qword ptr [rip + .LCPI59_1]
	cvttsd2si	rcx, xmm0
	mov	rdx, rcx
	sar	rdx, 63
	subsd	xmm0, qword ptr [rip + .LCPI59_2]
	cvttsd2si	rax, xmm0
	and	rax, rdx
	or	rax, rcx
	movabs	rcx, 4835703278458516699
	mul	rcx
	mov	rcx, rdx
	shr	rcx, 18
                                        # kill: def $ecx killed $ecx killed $rcx
	jmp	Sleep                           # TAILCALL
                                        # -- End function
	.def	_xtc_bank;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_bank                       # -- Begin function _xtc_bank
	.p2align	4, 0x90
_xtc_bank:                              # @_xtc_bank
# %bb.0:
	push	rsi
	sub	rsp, 32
	cmp	cl, 1
	jbe	.LBB60_2
# %bb.1:
	xor	eax, eax
	jmp	.LBB60_5
.LBB60_2:
	movzx	eax, cl
	shl	eax, 11
	lea	rcx, [rip + xt_bank_regions]
	add	rcx, rax
	movzx	eax, dl
	lea	rsi, [rcx + 8*rax]
	cmp	qword ptr [rcx + 8*rax], 0
	jne	.LBB60_4
# %bb.3:
	call	GetProcessHeap
	mov	r8d, 12296
	mov	rcx, rax
	mov	edx, 8
	call	HeapAlloc
	lea	rcx, [rax + 8]
	test	rax, rax
	cmove	rcx, rax
	mov	qword ptr [rsi], rcx
.LBB60_4:
	mov	rax, qword ptr [rsi]
.LBB60_5:
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xt_threads_multi;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_threads_multi               # -- Begin function _xt_threads_multi
	.p2align	4, 0x90
_xt_threads_multi:                      # @_xt_threads_multi
# %bb.0:
	mov	eax, dword ptr [rip + _xt_threads_active]
	ret
                                        # -- End function
	.def	_xt_alloc_lock;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_alloc_lock                  # -- Begin function _xt_alloc_lock
	.p2align	4, 0x90
_xt_alloc_lock:                         # @_xt_alloc_lock
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB62_3
	.p2align	4, 0x90
.LBB62_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB62_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB62_3
.LBB62_2:                               #   Parent Loop BB62_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB62_2
	jmp	.LBB62_1
.LBB62_3:
	ret
                                        # -- End function
	.def	_xt_alloc_unlock;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_alloc_unlock                # -- Begin function _xt_alloc_unlock
	.p2align	4, 0x90
_xt_alloc_unlock:                       # @_xt_alloc_unlock
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_2
# %bb.1:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB63_2:
	ret
                                        # -- End function
	.def	_xt_thread_create;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_thread_create               # -- Begin function _xt_thread_create
	.p2align	4, 0x90
_xt_thread_create:                      # @_xt_thread_create
# %bb.0:
	push	rsi
	push	rdi
	push	rbx
	sub	rsp, 48
	test	rcx, rcx
	je	.LBB64_4
# %bb.1:
	mov	rdi, rdx
	mov	rbx, rcx
	mov	dword ptr [rip + _xt_threads_active], 1
	call	GetProcessHeap
	mov	r8d, 24
	mov	rcx, rax
	mov	edx, 8
	call	HeapAlloc
	lea	rsi, [rax + 8]
	test	rax, rax
	cmove	rsi, rax
	je	.LBB64_4
# %bb.2:
	mov	qword ptr [rsi], rbx
	mov	qword ptr [rsi + 8], rdi
	mov	qword ptr [rsp + 40], 0
	mov	dword ptr [rsp + 32], 0
	lea	r8, [rip + xt_thread_entry]
	xor	ecx, ecx
	xor	edx, edx
	mov	r9, rsi
	call	CreateThread
	test	rax, rax
	jne	.LBB64_5
# %bb.3:
	call	GetProcessHeap
	add	rsi, -8
	mov	rcx, rax
	xor	edx, edx
	mov	r8, rsi
	call	HeapFree
.LBB64_4:
	xor	eax, eax
.LBB64_5:
	add	rsp, 48
	pop	rbx
	pop	rdi
	pop	rsi
	ret
                                        # -- End function
	.def	xt_thread_entry;
	.scl	3;
	.type	32;
	.endef
	.p2align	4, 0x90                         # -- Begin function xt_thread_entry
xt_thread_entry:                        # @xt_thread_entry
# %bb.0:
	push	rsi
	push	rdi
	push	rbx
	sub	rsp, 32
	mov	rdi, rcx
	mov	rbx, qword ptr [rcx]
	mov	rsi, qword ptr [rcx + 8]
	call	GetProcessHeap
	add	rdi, -8
	mov	rcx, rax
	xor	edx, edx
	mov	r8, rdi
	call	HeapFree
	test	rbx, rbx
	je	.LBB65_2
# %bb.1:
	mov	rcx, rsi
	call	rbx
.LBB65_2:
	xor	eax, eax
	add	rsp, 32
	pop	rbx
	pop	rdi
	pop	rsi
	ret
                                        # -- End function
	.def	_xt_thread_join;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_thread_join                 # -- Begin function _xt_thread_join
	.p2align	4, 0x90
_xt_thread_join:                        # @_xt_thread_join
# %bb.0:
	push	rsi
	sub	rsp, 32
	test	rcx, rcx
	je	.LBB66_1
# %bb.2:
	mov	rsi, rcx
	mov	edx, -1
	call	WaitForSingleObject
	mov	rcx, rsi
	call	CloseHandle
	xor	eax, eax
	jmp	.LBB66_3
.LBB66_1:
	mov	eax, -1
.LBB66_3:
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xt_thread_detach;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_thread_detach               # -- Begin function _xt_thread_detach
	.p2align	4, 0x90
_xt_thread_detach:                      # @_xt_thread_detach
# %bb.0:
	test	rcx, rcx
	jne	CloseHandle                     # TAILCALL
# %bb.1:
	ret
                                        # -- End function
	.def	_xt_thread_yield;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_thread_yield                # -- Begin function _xt_thread_yield
	.p2align	4, 0x90
_xt_thread_yield:                       # @_xt_thread_yield
# %bb.0:
	jmp	SwitchToThread                  # TAILCALL
                                        # -- End function
	.def	_xt_thread_sleep_ms;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_thread_sleep_ms             # -- Begin function _xt_thread_sleep_ms
	.p2align	4, 0x90
_xt_thread_sleep_ms:                    # @_xt_thread_sleep_ms
# %bb.0:
	jmp	Sleep                           # TAILCALL
                                        # -- End function
	.def	_xt_thread_self_id;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_thread_self_id              # -- Begin function _xt_thread_self_id
	.p2align	4, 0x90
_xt_thread_self_id:                     # @_xt_thread_self_id
# %bb.0:
	jmp	GetCurrentThreadId              # TAILCALL
                                        # -- End function
	.def	_xt_thread_cpu_count;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_thread_cpu_count            # -- Begin function _xt_thread_cpu_count
	.p2align	4, 0x90
_xt_thread_cpu_count:                   # @_xt_thread_cpu_count
# %bb.0:
	sub	rsp, 104
	xorps	xmm0, xmm0
	movaps	xmmword ptr [rsp + 80], xmm0
	movaps	xmmword ptr [rsp + 64], xmm0
	movaps	xmmword ptr [rsp + 48], xmm0
	movaps	xmmword ptr [rsp + 32], xmm0
	lea	rcx, [rsp + 32]
	call	GetSystemInfo
	mov	eax, dword ptr [rsp + 64]
	cmp	eax, 1
	adc	eax, 0
	add	rsp, 104
	ret
                                        # -- End function
	.def	_xt_mutex_new;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_mutex_new                   # -- Begin function _xt_mutex_new
	.p2align	4, 0x90
_xt_mutex_new:                          # @_xt_mutex_new
# %bb.0:
	push	rsi
	sub	rsp, 32
	call	GetProcessHeap
	mov	r8d, 16
	mov	rcx, rax
	mov	edx, 8
	call	HeapAlloc
	lea	rsi, [rax + 8]
	test	rax, rax
	cmove	rsi, rax
	je	.LBB72_2
# %bb.1:
	mov	rcx, rsi
	call	InitializeSRWLock
.LBB72_2:
	mov	rax, rsi
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xt_mutex_free;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_mutex_free                  # -- Begin function _xt_mutex_free
	.p2align	4, 0x90
_xt_mutex_free:                         # @_xt_mutex_free
# %bb.0:
	push	rsi
	sub	rsp, 32
	test	rcx, rcx
	je	.LBB73_1
# %bb.2:
	mov	rsi, rcx
	call	GetProcessHeap
	add	rsi, -8
	mov	rcx, rax
	xor	edx, edx
	mov	r8, rsi
	add	rsp, 32
	pop	rsi
	jmp	HeapFree                        # TAILCALL
.LBB73_1:
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xt_mutex_lock;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_mutex_lock                  # -- Begin function _xt_mutex_lock
	.p2align	4, 0x90
_xt_mutex_lock:                         # @_xt_mutex_lock
# %bb.0:
	test	rcx, rcx
	jne	AcquireSRWLockExclusive         # TAILCALL
# %bb.1:
	ret
                                        # -- End function
	.def	_xt_mutex_unlock;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_mutex_unlock                # -- Begin function _xt_mutex_unlock
	.p2align	4, 0x90
_xt_mutex_unlock:                       # @_xt_mutex_unlock
# %bb.0:
	test	rcx, rcx
	jne	ReleaseSRWLockExclusive         # TAILCALL
# %bb.1:
	ret
                                        # -- End function
	.def	_xt_mutex_trylock;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_mutex_trylock               # -- Begin function _xt_mutex_trylock
	.p2align	4, 0x90
_xt_mutex_trylock:                      # @_xt_mutex_trylock
# %bb.0:
	sub	rsp, 40
	test	rcx, rcx
	je	.LBB76_1
# %bb.2:
	call	TryAcquireSRWLockExclusive
	mov	ecx, eax
	xor	eax, eax
	test	cl, cl
	setne	al
	add	rsp, 40
	ret
.LBB76_1:
	xor	eax, eax
	add	rsp, 40
	ret
                                        # -- End function
	.def	_xt_cond_new;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_cond_new                    # -- Begin function _xt_cond_new
	.p2align	4, 0x90
_xt_cond_new:                           # @_xt_cond_new
# %bb.0:
	push	rsi
	sub	rsp, 32
	call	GetProcessHeap
	mov	r8d, 16
	mov	rcx, rax
	mov	edx, 8
	call	HeapAlloc
	lea	rsi, [rax + 8]
	test	rax, rax
	cmove	rsi, rax
	je	.LBB77_2
# %bb.1:
	mov	rcx, rsi
	call	InitializeConditionVariable
.LBB77_2:
	mov	rax, rsi
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xt_cond_free;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_cond_free                   # -- Begin function _xt_cond_free
	.p2align	4, 0x90
_xt_cond_free:                          # @_xt_cond_free
# %bb.0:
	push	rsi
	sub	rsp, 32
	test	rcx, rcx
	je	.LBB78_1
# %bb.2:
	mov	rsi, rcx
	call	GetProcessHeap
	add	rsi, -8
	mov	rcx, rax
	xor	edx, edx
	mov	r8, rsi
	add	rsp, 32
	pop	rsi
	jmp	HeapFree                        # TAILCALL
.LBB78_1:
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xt_cond_wait;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_cond_wait                   # -- Begin function _xt_cond_wait
	.p2align	4, 0x90
_xt_cond_wait:                          # @_xt_cond_wait
# %bb.0:
	test	rcx, rcx
	sete	al
	test	rdx, rdx
	sete	r8b
	or	r8b, al
	jne	.LBB79_1
# %bb.2:
	mov	r8d, -1
	xor	r9d, r9d
	jmp	SleepConditionVariableSRW       # TAILCALL
.LBB79_1:
	ret
                                        # -- End function
	.def	_xt_cond_signal;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_cond_signal                 # -- Begin function _xt_cond_signal
	.p2align	4, 0x90
_xt_cond_signal:                        # @_xt_cond_signal
# %bb.0:
	test	rcx, rcx
	jne	WakeConditionVariable           # TAILCALL
# %bb.1:
	ret
                                        # -- End function
	.def	_xt_cond_broadcast;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_cond_broadcast              # -- Begin function _xt_cond_broadcast
	.p2align	4, 0x90
_xt_cond_broadcast:                     # @_xt_cond_broadcast
# %bb.0:
	test	rcx, rcx
	jne	WakeAllConditionVariable        # TAILCALL
# %bb.1:
	ret
                                        # -- End function
	.def	_xt_sem_new;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_sem_new                     # -- Begin function _xt_sem_new
	.p2align	4, 0x90
_xt_sem_new:                            # @_xt_sem_new
# %bb.0:
	mov	edx, ecx
	xor	eax, eax
	test	ecx, ecx
	cmovle	edx, eax
	xor	ecx, ecx
	mov	r8d, 2147483647
	xor	r9d, r9d
	jmp	CreateSemaphoreA                # TAILCALL
                                        # -- End function
	.def	_xt_sem_free;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_sem_free                    # -- Begin function _xt_sem_free
	.p2align	4, 0x90
_xt_sem_free:                           # @_xt_sem_free
# %bb.0:
	test	rcx, rcx
	jne	CloseHandle                     # TAILCALL
# %bb.1:
	ret
                                        # -- End function
	.def	_xt_sem_wait;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_sem_wait                    # -- Begin function _xt_sem_wait
	.p2align	4, 0x90
_xt_sem_wait:                           # @_xt_sem_wait
# %bb.0:
	test	rcx, rcx
	je	.LBB84_1
# %bb.2:
	mov	edx, -1
	jmp	WaitForSingleObject             # TAILCALL
.LBB84_1:
	ret
                                        # -- End function
	.def	_xt_sem_post;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_sem_post                    # -- Begin function _xt_sem_post
	.p2align	4, 0x90
_xt_sem_post:                           # @_xt_sem_post
# %bb.0:
	test	rcx, rcx
	je	.LBB85_1
# %bb.2:
	mov	edx, 1
	xor	r8d, r8d
	jmp	ReleaseSemaphore                # TAILCALL
.LBB85_1:
	ret
                                        # -- End function
	.def	_xt_sem_trywait;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_sem_trywait                 # -- Begin function _xt_sem_trywait
	.p2align	4, 0x90
_xt_sem_trywait:                        # @_xt_sem_trywait
# %bb.0:
	sub	rsp, 40
	test	rcx, rcx
	je	.LBB86_1
# %bb.2:
	xor	edx, edx
	call	WaitForSingleObject
	mov	ecx, eax
	xor	eax, eax
	test	ecx, ecx
	sete	al
	add	rsp, 40
	ret
.LBB86_1:
	xor	eax, eax
	add	rsp, 40
	ret
                                        # -- End function
	.def	_xt_tls_new;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_tls_new                     # -- Begin function _xt_tls_new
	.p2align	4, 0x90
_xt_tls_new:                            # @_xt_tls_new
# %bb.0:
	jmp	TlsAlloc                        # TAILCALL
                                        # -- End function
	.def	_xt_tls_set;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_tls_set                     # -- Begin function _xt_tls_set
	.p2align	4, 0x90
_xt_tls_set:                            # @_xt_tls_set
# %bb.0:
	jmp	TlsSetValue                     # TAILCALL
                                        # -- End function
	.def	_xt_tls_get;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_tls_get                     # -- Begin function _xt_tls_get
	.p2align	4, 0x90
_xt_tls_get:                            # @_xt_tls_get
# %bb.0:
	jmp	TlsGetValue                     # TAILCALL
                                        # -- End function
	.def	_xt_atomic_load_i32;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_atomic_load_i32             # -- Begin function _xt_atomic_load_i32
	.p2align	4, 0x90
_xt_atomic_load_i32:                    # @_xt_atomic_load_i32
# %bb.0:
	test	rcx, rcx
	je	.LBB90_1
# %bb.2:
	mov	eax, dword ptr [rcx]
	ret
.LBB90_1:
	xor	eax, eax
	ret
                                        # -- End function
	.def	_xt_atomic_store_i32;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_atomic_store_i32            # -- Begin function _xt_atomic_store_i32
	.p2align	4, 0x90
_xt_atomic_store_i32:                   # @_xt_atomic_store_i32
# %bb.0:
	test	rcx, rcx
	je	.LBB91_2
# %bb.1:
	xchg	dword ptr [rcx], edx
.LBB91_2:
	ret
                                        # -- End function
	.def	_xt_atomic_add_i32;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_atomic_add_i32              # -- Begin function _xt_atomic_add_i32
	.p2align	4, 0x90
_xt_atomic_add_i32:                     # @_xt_atomic_add_i32
# %bb.0:
	test	rcx, rcx
	je	.LBB92_1
# %bb.2:
	mov	eax, edx
	lock		xadd	dword ptr [rcx], eax
	add	eax, edx
	ret
.LBB92_1:
	xor	eax, eax
	ret
                                        # -- End function
	.def	_xt_atomic_xchg_i32;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_atomic_xchg_i32             # -- Begin function _xt_atomic_xchg_i32
	.p2align	4, 0x90
_xt_atomic_xchg_i32:                    # @_xt_atomic_xchg_i32
# %bb.0:
	test	rcx, rcx
	je	.LBB93_1
# %bb.2:
	mov	eax, edx
	xchg	dword ptr [rcx], eax
	ret
.LBB93_1:
	xor	eax, eax
	ret
                                        # -- End function
	.def	_xt_atomic_cas_i32;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_atomic_cas_i32              # -- Begin function _xt_atomic_cas_i32
	.p2align	4, 0x90
_xt_atomic_cas_i32:                     # @_xt_atomic_cas_i32
# %bb.0:
	test	rcx, rcx
	je	.LBB94_1
# %bb.2:
	mov	eax, edx
	lock		cmpxchg	dword ptr [rcx], r8d
	mov	eax, 0
	sete	al
	ret
.LBB94_1:
	xor	eax, eax
	ret
                                        # -- End function
	.def	_xt_atomic_load_ptr;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_atomic_load_ptr             # -- Begin function _xt_atomic_load_ptr
	.p2align	4, 0x90
_xt_atomic_load_ptr:                    # @_xt_atomic_load_ptr
# %bb.0:
	test	rcx, rcx
	je	.LBB95_1
# %bb.2:
	mov	rax, qword ptr [rcx]
	ret
.LBB95_1:
	xor	eax, eax
	ret
                                        # -- End function
	.def	_xt_atomic_store_ptr;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_atomic_store_ptr            # -- Begin function _xt_atomic_store_ptr
	.p2align	4, 0x90
_xt_atomic_store_ptr:                   # @_xt_atomic_store_ptr
# %bb.0:
	test	rcx, rcx
	je	.LBB96_2
# %bb.1:
	xchg	qword ptr [rcx], rdx
.LBB96_2:
	ret
                                        # -- End function
	.def	_xt_atomic_cas_ptr;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_atomic_cas_ptr              # -- Begin function _xt_atomic_cas_ptr
	.p2align	4, 0x90
_xt_atomic_cas_ptr:                     # @_xt_atomic_cas_ptr
# %bb.0:
	test	rcx, rcx
	je	.LBB97_1
# %bb.2:
	mov	rax, rdx
	lock		cmpxchg	qword ptr [rcx], r8
	mov	eax, 0
	sete	al
	ret
.LBB97_1:
	xor	eax, eax
	ret
                                        # -- End function
	.def	_xt_simd_select;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_simd_select                 # -- Begin function _xt_simd_select
	.p2align	4, 0x90
_xt_simd_select:                        # @_xt_simd_select
# %bb.0:
	push	rsi
	push	rdi
	push	rbp
	push	rbx
	sub	rsp, 56
	mov	edi, edx
	mov	rsi, rcx
	mov	eax, 1
	xor	ecx, ecx
	#APP

	.byte	15
	.byte	162

	#NO_APP
	xor	ebp, ebp
	not	ecx
	test	ecx, 402657280
	jne	.LBB98_4
# %bb.1:
	xor	ebp, ebp
	xor	ecx, ecx
	#APP

	.byte	15
	.byte	1
	.byte	208

	#NO_APP
	mov	r8d, eax
	not	r8d
	test	r8b, 6
	jne	.LBB98_4
# %bb.2:
	xor	ebp, ebp
	mov	eax, 7
	xor	ecx, ecx
	#APP

	.byte	15
	.byte	162

	#NO_APP
	test	bl, 32
	je	.LBB98_4
# %bb.3:
	not	ebx
	and	ebx, -1073545216
	and	r8d, 224
	xor	ebp, ebp
	or	r8d, ebx
	sete	bpl
	inc	ebp
.LBB98_4:
	lea	rcx, [rip + .L.str]
	lea	rbx, [rip + xt_env.buf]
	mov	rdx, rbx
	mov	r8d, 32
	call	GetEnvironmentVariableA
	add	eax, -32
	xor	ecx, ecx
	cmp	eax, -31
	cmovae	rcx, rbx
	jae	.LBB98_5
.LBB98_27:
	mov	r8d, ebp
	jmp	.LBB98_28
.LBB98_5:
	movzx	eax, byte ptr [rcx]
	test	al, al
	je	.LBB98_6
# %bb.7:
	lea	r8, [rcx + 1]
	lea	rdx, [rip + .L.str.1]
	mov	r9d, eax
	.p2align	4, 0x90
.LBB98_8:                               # =>This Inner Loop Header: Depth=1
	cmp	r9b, byte ptr [rdx]
	jne	.LBB98_10
# %bb.9:                                #   in Loop: Header=BB98_8 Depth=1
	inc	rdx
	movzx	r9d, byte ptr [r8]
	inc	r8
	test	r9b, r9b
	jne	.LBB98_8
	jmp	.LBB98_10
.LBB98_6:
	lea	rdx, [rip + .L.str.1]
	mov	r9d, eax
.LBB98_10:
	xor	r8d, r8d
	cmp	r9b, byte ptr [rdx]
	cmovne	r8d, ebp
	je	.LBB98_28
# %bb.11:
	test	al, al
	je	.LBB98_12
# %bb.13:
	lea	r9, [rcx + 1]
	lea	rdx, [rip + .L.str.2]
	mov	r8d, eax
	.p2align	4, 0x90
.LBB98_14:                              # =>This Inner Loop Header: Depth=1
	cmp	r8b, byte ptr [rdx]
	jne	.LBB98_16
# %bb.15:                               #   in Loop: Header=BB98_14 Depth=1
	inc	rdx
	movzx	r8d, byte ptr [r9]
	inc	r9
	test	r8b, r8b
	jne	.LBB98_14
.LBB98_16:
	cmp	r8b, byte ptr [rdx]
	jne	.LBB98_19
.LBB98_17:
	mov	r8d, 1
	test	ebp, ebp
	jne	.LBB98_28
# %bb.18:
	mov	dword ptr [rsp + 48], 0
	mov	ecx, -12
	call	GetStdHandle
	mov	qword ptr [rsp + 32], 0
	lea	rdx, [rip + xt_simd_pick.msg]
	lea	r9, [rsp + 48]
	mov	rcx, rax
	mov	r8d, 66
	call	WriteFile
	xor	r8d, r8d
.LBB98_28:
	xor	eax, eax
	test	r8d, r8d
	setne	al
	mov	dword ptr [rip + _xt_simd_level], eax
	test	edi, edi
	je	.LBB98_31
# %bb.29:
	cmp	r8d, 1
	mov	eax, 1
	sbb	eax, -1
	mov	ecx, edi
	lea	rcx, [rcx + 2*rcx]
	xor	edx, edx
	.p2align	4, 0x90
.LBB98_30:                              # =>This Inner Loop Header: Depth=1
	mov	r8d, edx
	mov	r8, qword ptr [rsi + 8*r8]
	lea	r9d, [rax + rdx]
	mov	r9, qword ptr [rsi + 8*r9]
	mov	qword ptr [r8], r9
	add	rdx, 3
	cmp	rcx, rdx
	jne	.LBB98_30
.LBB98_31:
	add	rsp, 56
	pop	rbx
	pop	rbp
	pop	rdi
	pop	rsi
	ret
.LBB98_12:
	lea	rdx, [rip + .L.str.2]
	mov	r8d, eax
	cmp	r8b, byte ptr [rdx]
	je	.LBB98_17
.LBB98_19:
	test	al, al
	je	.LBB98_20
# %bb.21:
	inc	rcx
	lea	rdx, [rip + .L.str.3]
	.p2align	4, 0x90
.LBB98_22:                              # =>This Inner Loop Header: Depth=1
	cmp	al, byte ptr [rdx]
	jne	.LBB98_24
# %bb.23:                               #   in Loop: Header=BB98_22 Depth=1
	inc	rdx
	movzx	eax, byte ptr [rcx]
	inc	rcx
	test	al, al
	jne	.LBB98_22
	jmp	.LBB98_24
.LBB98_20:
	lea	rdx, [rip + .L.str.3]
.LBB98_24:
	cmp	ebp, 1
	ja	.LBB98_27
# %bb.25:
	cmp	al, byte ptr [rdx]
	jne	.LBB98_27
# %bb.26:
	mov	dword ptr [rsp + 52], 0
	mov	ecx, -12
	call	GetStdHandle
	mov	qword ptr [rsp + 32], 0
	lea	rdx, [rip + xt_simd_pick.msg.4]
	lea	r9, [rsp + 52]
	mov	rcx, rax
	mov	r8d, 82
	call	WriteFile
	jmp	.LBB98_27
                                        # -- End function
	.def	_xt_simd_select4;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_simd_select4                # -- Begin function _xt_simd_select4
	.p2align	4, 0x90
_xt_simd_select4:                       # @_xt_simd_select4
# %bb.0:
	push	rsi
	push	rdi
	push	rbp
	push	rbx
	sub	rsp, 56
	mov	edi, edx
	mov	rsi, rcx
	mov	eax, 1
	xor	ecx, ecx
	#APP

	.byte	15
	.byte	162

	#NO_APP
	xor	ebp, ebp
	not	ecx
	test	ecx, 402657280
	jne	.LBB99_4
# %bb.1:
	xor	ebp, ebp
	xor	ecx, ecx
	#APP

	.byte	15
	.byte	1
	.byte	208

	#NO_APP
	mov	r8d, eax
	not	r8d
	test	r8b, 6
	jne	.LBB99_4
# %bb.2:
	xor	ebp, ebp
	mov	eax, 7
	xor	ecx, ecx
	#APP

	.byte	15
	.byte	162

	#NO_APP
	test	bl, 32
	je	.LBB99_4
# %bb.3:
	not	ebx
	and	ebx, -1073545216
	and	r8d, 224
	xor	ebp, ebp
	or	r8d, ebx
	sete	bpl
	inc	ebp
.LBB99_4:
	lea	rcx, [rip + .L.str]
	lea	rbx, [rip + xt_env.buf]
	mov	rdx, rbx
	mov	r8d, 32
	call	GetEnvironmentVariableA
	add	eax, -32
	xor	ecx, ecx
	cmp	eax, -31
	cmovae	rcx, rbx
	jae	.LBB99_5
.LBB99_27:
	mov	r8d, ebp
	jmp	.LBB99_28
.LBB99_5:
	movzx	eax, byte ptr [rcx]
	test	al, al
	je	.LBB99_6
# %bb.7:
	lea	r8, [rcx + 1]
	lea	rdx, [rip + .L.str.1]
	mov	r9d, eax
	.p2align	4, 0x90
.LBB99_8:                               # =>This Inner Loop Header: Depth=1
	cmp	r9b, byte ptr [rdx]
	jne	.LBB99_10
# %bb.9:                                #   in Loop: Header=BB99_8 Depth=1
	inc	rdx
	movzx	r9d, byte ptr [r8]
	inc	r8
	test	r9b, r9b
	jne	.LBB99_8
	jmp	.LBB99_10
.LBB99_6:
	lea	rdx, [rip + .L.str.1]
	mov	r9d, eax
.LBB99_10:
	xor	r8d, r8d
	cmp	r9b, byte ptr [rdx]
	cmovne	r8d, ebp
	je	.LBB99_28
# %bb.11:
	test	al, al
	je	.LBB99_12
# %bb.13:
	lea	r9, [rcx + 1]
	lea	rdx, [rip + .L.str.2]
	mov	r8d, eax
	.p2align	4, 0x90
.LBB99_14:                              # =>This Inner Loop Header: Depth=1
	cmp	r8b, byte ptr [rdx]
	jne	.LBB99_16
# %bb.15:                               #   in Loop: Header=BB99_14 Depth=1
	inc	rdx
	movzx	r8d, byte ptr [r9]
	inc	r9
	test	r8b, r8b
	jne	.LBB99_14
.LBB99_16:
	cmp	r8b, byte ptr [rdx]
	jne	.LBB99_19
.LBB99_17:
	mov	r8d, 1
	test	ebp, ebp
	jne	.LBB99_28
# %bb.18:
	mov	dword ptr [rsp + 48], 0
	mov	ecx, -12
	call	GetStdHandle
	mov	qword ptr [rsp + 32], 0
	lea	rdx, [rip + xt_simd_pick.msg]
	lea	r9, [rsp + 48]
	mov	rcx, rax
	mov	r8d, 66
	call	WriteFile
	xor	r8d, r8d
.LBB99_28:
	mov	dword ptr [rip + _xt_simd_level], r8d
	test	edi, edi
	je	.LBB99_31
# %bb.29:
	mov	eax, edi
	mov	ecx, r8d
	inc	rcx
	shl	rax, 2
	xor	edx, edx
	.p2align	4, 0x90
.LBB99_30:                              # =>This Inner Loop Header: Depth=1
	mov	r8d, edx
	mov	r8, qword ptr [rsi + 8*r8]
	lea	r9d, [rcx + rdx]
	mov	r9, qword ptr [rsi + 8*r9]
	mov	qword ptr [r8], r9
	add	rdx, 4
	cmp	rax, rdx
	jne	.LBB99_30
.LBB99_31:
	add	rsp, 56
	pop	rbx
	pop	rbp
	pop	rdi
	pop	rsi
	ret
.LBB99_12:
	lea	rdx, [rip + .L.str.2]
	mov	r8d, eax
	cmp	r8b, byte ptr [rdx]
	je	.LBB99_17
.LBB99_19:
	test	al, al
	je	.LBB99_20
# %bb.21:
	inc	rcx
	lea	rdx, [rip + .L.str.3]
	.p2align	4, 0x90
.LBB99_22:                              # =>This Inner Loop Header: Depth=1
	cmp	al, byte ptr [rdx]
	jne	.LBB99_24
# %bb.23:                               #   in Loop: Header=BB99_22 Depth=1
	inc	rdx
	movzx	eax, byte ptr [rcx]
	inc	rcx
	test	al, al
	jne	.LBB99_22
	jmp	.LBB99_24
.LBB99_20:
	lea	rdx, [rip + .L.str.3]
.LBB99_24:
	cmp	ebp, 1
	ja	.LBB99_27
# %bb.25:
	cmp	al, byte ptr [rdx]
	jne	.LBB99_27
# %bb.26:
	mov	dword ptr [rsp + 52], 0
	mov	ecx, -12
	call	GetStdHandle
	mov	qword ptr [rsp + 32], 0
	lea	rdx, [rip + xt_simd_pick.msg.4]
	lea	r9, [rsp + 52]
	mov	rcx, rax
	mov	r8d, 82
	call	WriteFile
	jmp	.LBB99_27
                                        # -- End function
	.def	_xtc_sinit_run;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_sinit_run                  # -- Begin function _xtc_sinit_run
	.p2align	4, 0x90
_xtc_sinit_run:                         # @_xtc_sinit_run
# %bb.0:
	push	r15
	push	r14
	push	rsi
	push	rdi
	push	rbx
	sub	rsp, 32
	test	rcx, rcx
	je	.LBB100_35
# %bb.1:
	mov	rbx, r8
	mov	rdi, rdx
	mov	rsi, rcx
	lea	r14, [rip + xt_sinit_flag]
	lea	r15, [rip + xt_sinit_owner]
	jmp	.LBB100_2
	.p2align	4, 0x90
.LBB100_14:                             #   in Loop: Header=BB100_2 Depth=1
	call	SwitchToThread
	xor	eax, eax
.LBB100_21:                             #   in Loop: Header=BB100_2 Depth=1
	test	eax, eax
	jne	.LBB100_22
.LBB100_2:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB100_3 Depth 2
                                        #       Child Loop BB100_4 Depth 3
                                        #     Child Loop BB100_9 Depth 2
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB100_5
	.p2align	4, 0x90
.LBB100_3:                              #   Parent Loop BB100_2 Depth=1
                                        # =>  This Loop Header: Depth=2
                                        #       Child Loop BB100_4 Depth 3
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB100_5
.LBB100_4:                              #   Parent Loop BB100_2 Depth=1
                                        #     Parent Loop BB100_3 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB100_4
	jmp	.LBB100_3
	.p2align	4, 0x90
.LBB100_5:                              #   in Loop: Header=BB100_2 Depth=1
	movzx	eax, byte ptr [rsi]
	test	eax, eax
	je	.LBB100_15
# %bb.6:                                #   in Loop: Header=BB100_2 Depth=1
	cmp	eax, 2
	jne	.LBB100_7
.LBB100_18:                             #   in Loop: Header=BB100_2 Depth=1
	mov	eax, 1
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB100_20
	jmp	.LBB100_21
	.p2align	4, 0x90
.LBB100_15:                             #   in Loop: Header=BB100_2 Depth=1
	mov	byte ptr [rsi], 1
	movsxd	rax, dword ptr [rip + xt_sinit_n]
	cmp	rax, 31
	jg	.LBB100_17
# %bb.16:                               #   in Loop: Header=BB100_2 Depth=1
	mov	qword ptr [r14 + 8*rax], rsi
	call	GetCurrentThreadId
	movsxd	rcx, dword ptr [rip + xt_sinit_n]
	mov	dword ptr [r15 + 4*rcx], eax
	lea	eax, [rcx + 1]
	mov	dword ptr [rip + xt_sinit_n], eax
.LBB100_17:                             #   in Loop: Header=BB100_2 Depth=1
	mov	eax, 2
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB100_21
.LBB100_20:                             #   in Loop: Header=BB100_2 Depth=1
	mov	dword ptr [rip + xt_rt_spin], 0
	jmp	.LBB100_21
	.p2align	4, 0x90
.LBB100_7:                              #   in Loop: Header=BB100_2 Depth=1
	call	GetCurrentThreadId
	movsxd	rcx, dword ptr [rip + xt_sinit_n]
	test	rcx, rcx
	jle	.LBB100_12
# %bb.8:                                #   in Loop: Header=BB100_2 Depth=1
	shl	rcx, 3
	xor	edx, edx
	mov	r8, r15
	jmp	.LBB100_9
	.p2align	4, 0x90
.LBB100_11:                             #   in Loop: Header=BB100_9 Depth=2
	add	r8, 4
	add	rdx, 8
	cmp	rcx, rdx
	je	.LBB100_12
.LBB100_9:                              #   Parent Loop BB100_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	qword ptr [rdx + r14], rsi
	jne	.LBB100_11
# %bb.10:                               #   in Loop: Header=BB100_9 Depth=2
	cmp	dword ptr [r8], eax
	jne	.LBB100_11
	jmp	.LBB100_18
	.p2align	4, 0x90
.LBB100_12:                             #   in Loop: Header=BB100_2 Depth=1
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB100_14
# %bb.13:                               #   in Loop: Header=BB100_2 Depth=1
	mov	dword ptr [rip + xt_rt_spin], 0
	jmp	.LBB100_14
.LBB100_22:
	cmp	eax, 1
	je	.LBB100_35
# %bb.23:
	test	rdi, rdi
	je	.LBB100_25
# %bb.24:
	mov	rcx, rbx
	call	rdi
.LBB100_25:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB100_28
	.p2align	4, 0x90
.LBB100_26:                             # =>This Loop Header: Depth=1
                                        #     Child Loop BB100_27 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB100_28
.LBB100_27:                             #   Parent Loop BB100_26 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB100_27
	jmp	.LBB100_26
.LBB100_28:
	mov	byte ptr [rsi], 2
	movsxd	rax, dword ptr [rip + xt_sinit_n]
	test	rax, rax
	jle	.LBB100_33
# %bb.29:
	lea	rdx, [4*rax]
	xor	ecx, ecx
	.p2align	4, 0x90
.LBB100_31:                             # =>This Inner Loop Header: Depth=1
	cmp	qword ptr [r14], rsi
	je	.LBB100_32
# %bb.30:                               #   in Loop: Header=BB100_31 Depth=1
	add	rcx, 4
	add	r14, 8
	cmp	rdx, rcx
	jne	.LBB100_31
.LBB100_33:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB100_35
.LBB100_34:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB100_35:
	add	rsp, 32
	pop	rbx
	pop	rdi
	pop	rsi
	pop	r14
	pop	r15
	ret
.LBB100_32:
	lea	edx, [rax - 1]
	mov	dword ptr [rip + xt_sinit_n], edx
	lea	rdx, [rip + xt_sinit_flag]
	mov	rdx, qword ptr [rdx + 8*rax - 8]
	mov	qword ptr [r14], rdx
	lea	rdx, [rip + xt_sinit_owner]
	mov	eax, dword ptr [rdx + 4*rax - 4]
	mov	dword ptr [rcx + rdx], eax
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB100_34
	jmp	.LBB100_35
                                        # -- End function
	.def	_xt_thread_exiting;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_thread_exiting              # -- Begin function _xt_thread_exiting
	.p2align	4, 0x90
_xt_thread_exiting:                     # @_xt_thread_exiting
# %bb.0:
	ret
                                        # -- End function
	.def	xt_simd_veh;
	.scl	3;
	.type	32;
	.endef
	.p2align	4, 0x90                         # -- Begin function xt_simd_veh
xt_simd_veh:                            # @xt_simd_veh
# %bb.0:
	push	rsi
	sub	rsp, 48
	mov	rax, qword ptr [rcx]
	xor	esi, esi
	cmp	dword ptr [rax], -1073741819
	jne	.LBB102_15
# %bb.1:
	cmp	qword ptr [rax + 32], 1
	jne	.LBB102_15
# %bb.2:
	mov	rax, qword ptr [rax + 40]
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB102_5
	.p2align	4, 0x90
.LBB102_3:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB102_4 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_rt_spin], ecx
	test	ecx, ecx
	je	.LBB102_5
.LBB102_4:                              #   Parent Loop BB102_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_rt_spin]
	test	ecx, ecx
	jne	.LBB102_4
	jmp	.LBB102_3
.LBB102_5:
	mov	rdx, qword ptr [rip + xt_simd_n]
	xor	esi, esi
	test	rdx, rdx
	je	.LBB102_6
# %bb.7:
	mov	r8, qword ptr [rip + xt_simd_tab]
	xor	ecx, ecx
	movabs	r9, 2305843009213693950
	.p2align	4, 0x90
.LBB102_8:                              # =>This Inner Loop Header: Depth=1
	lea	r10, [rdx + rcx]
	mov	r11, r10
	shr	r11
	and	r10, r9
	cmp	qword ptr [r8 + 8*r10], rax
	lea	r10, [r11 + 1]
	cmova	rdx, r11
	cmovbe	rcx, r10
	cmp	rcx, rdx
	jb	.LBB102_8
# %bb.9:
	test	rcx, rcx
	jne	.LBB102_10
	jmp	.LBB102_13
.LBB102_6:
	xor	ecx, ecx
	test	rcx, rcx
	je	.LBB102_13
.LBB102_10:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	lea	r8, [2*rcx - 2]
	cmp	qword ptr [rdx + 8*r8 + 8], rax
	jbe	.LBB102_13
# %bb.11:
	lea	rax, [rcx - 1]
	mov	r9, qword ptr [rip + xt_simd_flag]
	movzx	r10d, byte ptr [r9 + rax]
	mov	esi, -1
	test	r10b, 1
	je	.LBB102_13
# %bb.12:
	lea	r11, [2*rcx - 1]
	and	r10b, -2
	mov	byte ptr [r9 + rax], r10b
	mov	rcx, qword ptr [rdx + 8*r8]
	mov	rdx, qword ptr [rdx + 8*r11]
	sub	rdx, rcx
	add	rdx, 16383
	and	rdx, -16384
	mov	dword ptr [rsp + 44], 0
	lea	r9, [rsp + 44]
	mov	r8d, 4
	call	VirtualProtect
.LBB102_13:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB102_15
# %bb.14:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB102_15:
	mov	eax, esi
	add	rsp, 48
	pop	rsi
	ret
                                        # -- End function
	.bss
	.globl	__xt_stack_guard                # @__xt_stack_guard
	.p2align	3, 0x0
__xt_stack_guard:
	.quad	0                               # 0x0

	.section	.rdata,"dr"
	.p2align	4, 0x0                          # @__xt_stack_fail.msg
__xt_stack_fail.msg:
	.asciz	"xcc: stack smashing detected (a local array was written past its end)\n"

	.lcomm	xt_simd_tab,8,8                 # @xt_simd_tab
	.lcomm	xt_simd_flag,8,8                # @xt_simd_flag
	.data
	.p2align	3, 0x0                          # @xt_rand_state
xt_rand_state:
	.quad	1                               # 0x1

	.lcomm	xt_clk_origin,8,8               # @xt_clk_origin
	.lcomm	xt_bank_regions,6144,16         # @xt_bank_regions
	.bss
	.globl	_xt_threads_active              # @_xt_threads_active
	.p2align	2, 0x0
_xt_threads_active:
	.long	0                               # 0x0

	.lcomm	xt_rt_spin,4,4                  # @xt_rt_spin
	.lcomm	xt_alloc_spin,4,4               # @xt_alloc_spin
	.data
	.globl	_xt_simd_level                  # @_xt_simd_level
	.p2align	2, 0x0
_xt_simd_level:
	.long	4294967295                      # 0xffffffff

	.lcomm	xt_sinit_n,4,4                  # @xt_sinit_n
	.lcomm	xt_sinit_flag,256,16            # @xt_sinit_flag
	.lcomm	xt_sinit_owner,128,16           # @xt_sinit_owner
	.section	.rdata,"dr"
	.p2align	4, 0x0                          # @xt_size_check.msg
xt_size_check.msg:
	.asciz	"xcc: an allocation overflows its size\n"

	.lcomm	xt_simd_n,8,8                   # @xt_simd_n
	.lcomm	xt_simd_cap,8,8                 # @xt_simd_cap
	.lcomm	xt_simd_installed,1,4           # @xt_simd_installed
.L.str:                                 # @.str
	.asciz	"XC_SIMD"

.L.str.1:                               # @.str.1
	.asciz	"base"

.L.str.2:                               # @.str.2
	.asciz	"avx2"

	.p2align	4, 0x0                          # @xt_simd_pick.msg
xt_simd_pick.msg:
	.asciz	"xc: XC_SIMD=avx2, but this machine has no usable AVX2; using base\n"

.L.str.3:                               # @.str.3
	.asciz	"avx512"

	.p2align	4, 0x0                          # @xt_simd_pick.msg.4
xt_simd_pick.msg.4:
	.asciz	"xc: XC_SIMD=avx512, but this machine has no usable AVX-512; using the best it has\n"

	.lcomm	xt_env.buf,32,16                # @xt_env.buf
	.section	.drectve,"yni"
	.ascii	" -exclude-symbols:__xt_stack_guard"
	.addrsig
	.addrsig_sym _xt_stack_guard_init
	.addrsig_sym xt_thread_entry
	.addrsig_sym xt_simd_veh
	.addrsig_sym __xt_stack_fail.msg
	.addrsig_sym xt_rt_spin
	.addrsig_sym xt_alloc_spin
	.addrsig_sym xt_size_check.msg
	.addrsig_sym xt_simd_pick.msg
	.addrsig_sym xt_simd_pick.msg.4
	.addrsig_sym xt_env.buf
