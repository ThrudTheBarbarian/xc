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

	.text
	.def	@feat.00;
	.scl	3;
	.type	0;
	.endef
	.globl	@feat.00
.set @feat.00, 0
	.intel_syntax noprefix
	.file	"rt-freestanding.c"
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
	push	r14
	push	rsi
	push	rdi
	push	rbx
	sub	rsp, 40
	lea	rdx, [rcx + 8]
	cmp	rdx, 17
	setae	al
	jb	.LBB1_6
# %bb.1:
	mov	ebx, 16
	xor	r8d, r8d
	.p2align	4, 0x90
.LBB1_2:                                # =>This Inner Loop Header: Depth=1
	add	rbx, rbx
	lea	rdi, [r8 + 1]
	cmp	rbx, rdx
	setb	al
	jae	.LBB1_4
# %bb.3:                                #   in Loop: Header=BB1_2 Depth=1
	cmp	r8d, 26
	mov	r8, rdi
	jb	.LBB1_2
.LBB1_4:
	test	al, al
	je	.LBB1_7
	jmp	.LBB1_21
.LBB1_6:
	xor	edi, edi
	mov	ebx, 16
	test	al, al
	jne	.LBB1_21
.LBB1_7:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB1_10
	.p2align	4, 0x90
.LBB1_8:                                # =>This Loop Header: Depth=1
                                        #     Child Loop BB1_9 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB1_10
.LBB1_9:                                #   Parent Loop BB1_8 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB1_9
	jmp	.LBB1_8
.LBB1_10:
	lea	rdx, [rip + xt_freelist]
	mov	rax, qword ptr [rdx + 8*rdi]
	test	rax, rax
	je	.LBB1_12
# %bb.11:
	mov	r8, qword ptr [rax]
	mov	qword ptr [rdx + 8*rdi], r8
	jmp	.LBB1_16
.LBB1_12:
	mov	rax, qword ptr [rip + xt_cur]
	add	rax, rbx
	cmp	rax, qword ptr [rip + xt_end]
	jbe	.LBB1_15
# %bb.13:
	lea	eax, [rbx + 1048575]
	and	eax, -1048576
	mov	esi, 1048576
	cmovne	rsi, rax
	mov	r14, rcx
	xor	ecx, ecx
	mov	rdx, rsi
	mov	r8d, 12288
	mov	r9d, 4
	call	VirtualAlloc
	mov	rcx, r14
	mov	rdx, rax
	xor	eax, eax
	test	rdx, rdx
	je	.LBB1_16
# %bb.14:
	mov	qword ptr [rip + xt_cur], rdx
	add	rsi, rdx
	mov	qword ptr [rip + xt_end], rsi
.LBB1_15:
	mov	rax, qword ptr [rip + xt_cur]
	add	rbx, rax
	mov	qword ptr [rip + xt_cur], rbx
.LBB1_16:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB1_18
# %bb.17:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB1_18:
	test	rax, rax
	je	.LBB1_21
# %bb.19:
	mov	qword ptr [rax], rdi
	add	rax, 8
	test	rcx, rcx
	je	.LBB1_22
# %bb.20:
	mov	r8, rcx
	mov	rcx, rax
	xor	edx, edx
	add	rsp, 40
	pop	rbx
	pop	rdi
	pop	rsi
	pop	r14
	jmp	memset                          # TAILCALL
.LBB1_21:
	xor	eax, eax
.LBB1_22:
	add	rsp, 40
	pop	rbx
	pop	rdi
	pop	rsi
	pop	r14
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
	je	.LBB2_3
	.p2align	4, 0x90
.LBB2_1:                                # =>This Loop Header: Depth=1
                                        #     Child Loop BB2_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB2_3
.LBB2_2:                                #   Parent Loop BB2_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB2_2
	jmp	.LBB2_1
.LBB2_3:
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
	je	.LBB3_2
# %bb.1:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB3_2:
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
	test	rcx, rcx
	je	.LBB4_7
# %bb.1:
	mov	rax, qword ptr [rcx - 8]
	cmp	rax, 27
	ja	.LBB4_7
# %bb.2:
	add	rcx, -8
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB4_5
	.p2align	4, 0x90
.LBB4_3:                                # =>This Loop Header: Depth=1
                                        #     Child Loop BB4_4 Depth 2
	mov	edx, 1
	xchg	dword ptr [rip + xt_alloc_spin], edx
	test	edx, edx
	je	.LBB4_5
.LBB4_4:                                #   Parent Loop BB4_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	edx, dword ptr [rip + xt_alloc_spin]
	test	edx, edx
	jne	.LBB4_4
	jmp	.LBB4_3
.LBB4_5:
	lea	rdx, [rip + xt_freelist]
	mov	r8, qword ptr [rdx + 8*rax]
	mov	qword ptr [rcx], r8
	mov	qword ptr [rdx + 8*rax], rcx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB4_7
# %bb.6:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB4_7:
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
	je	.LBB5_3
# %bb.1:
	xor	ecx, ecx
	.p2align	4, 0x90
.LBB5_2:                                # =>This Inner Loop Header: Depth=1
	mov	byte ptr [rax + rcx], dl
	inc	rcx
	cmp	r8, rcx
	jne	.LBB5_2
.LBB5_3:
	ret
                                        # -- End function
	.def	_xt_fmt_f;
	.scl	2;
	.type	32;
	.endef
	.section	.rdata,"dr"
	.p2align	4, 0x0                          # -- Begin function _xt_fmt_f
.LCPI6_0:
	.quad	0x8000000000000000              # double -0
	.quad	0x8000000000000000              # double -0
.LCPI6_1:
	.quad	0x4024000000000000              # double 10
	.text
	.globl	_xt_fmt_f
	.p2align	4, 0x90
_xt_fmt_f:                               # @_xt_fmt_f
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
	jbe	.LBB6_1
# %bb.2:
	lea	r8, [rcx + 1]
	mov	byte ptr [rcx], 45
	xorpd	xmm0, xmmword ptr [rip + .LCPI6_0]
	jmp	.LBB6_3
.LBB6_1:
	mov	r8, rcx
.LBB6_3:
	cvttsd2si	rdx, xmm0
	xorps	xmm1, xmm1
	cvtsi2sd	xmm1, rdx
	xor	esi, esi
	movabs	rdi, -3689348814741910323
	.p2align	4, 0x90
.LBB6_4:                                # =>This Inner Loop Header: Depth=1
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
	jb	.LBB6_6
# %bb.5:                                #   in Loop: Header=BB6_4 Depth=1
	cmp	rsi, 23
	mov	rsi, rax
	jb	.LBB6_4
	.p2align	4, 0x90
.LBB6_6:                                # =>This Inner Loop Header: Depth=1
	lea	rdx, [rax - 1]
	mov	r10d, edx
	movzx	r10d, byte ptr [rsp + r10]
	mov	byte ptr [r8], r10b
	inc	r8
	cmp	rax, 1
	mov	rax, rdx
	jg	.LBB6_6
# %bb.7:
	test	r9d, r9d
	jle	.LBB6_11
# %bb.8:
	subsd	xmm0, xmm1
	mov	byte ptr [r8], 46
	neg	r11d
	mov	eax, 1
	movsd	xmm1, qword ptr [rip + .LCPI6_1] # xmm1 = [1.0E+1,0.0E+0]
	mov	edx, 9
	xor	r9d, r9d
	.p2align	4, 0x90
.LBB6_9:                                # =>This Inner Loop Header: Depth=1
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
	jne	.LBB6_9
# %bb.10:
	add	r8, rax
.LBB6_11:
	mov	byte ptr [r8], 0
	sub	r8d, ecx
	mov	eax, r8d
	add	rsp, 32
	pop	rbx
	pop	rdi
	pop	rsi
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
	push	rsi
	push	rdi
	push	rbx
	sub	rsp, 32
	mov	rsi, r8
	mov	rdi, rcx
	cmp	rcx, 1
	adc	rdi, 0
	mov	rbx, rdx
	mov	rax, rdi
	imul	rax, rdx
	cmp	rax, 257
	mov	ecx, 256
	cmovae	rcx, rax
	add	rcx, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB7_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], rbx
	mov	qword ptr [rax + 12], rdi
	mov	qword ptr [rax + 20], rsi
	mov	qword ptr [rax + 28], 0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	jmp	.LBB7_3
.LBB7_1:
	xor	eax, eax
.LBB7_3:
	add	rsp, 32
	pop	rbx
	pop	rdi
	pop	rsi
	ret
                                        # -- End function
	.def	_xtc_new_u8;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_u8                     # -- Begin function _xtc_new_u8
	.p2align	4, 0x90
_xtc_new_u8:                            # @_xtc_new_u8
# %bb.0:
	push	rsi
	sub	rsp, 32
	mov	rsi, rcx
	cmp	rcx, 257
	mov	ecx, 256
	cmovae	rcx, rsi
	add	rcx, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB8_1
# %bb.2:
	cmp	rsi, 1
	adc	rsi, 0
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 1
	mov	qword ptr [rax + 12], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	jmp	.LBB8_3
.LBB8_1:
	xor	eax, eax
.LBB8_3:
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xtc_new_i8;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_i8                     # -- Begin function _xtc_new_i8
	.p2align	4, 0x90
_xtc_new_i8:                            # @_xtc_new_i8
# %bb.0:
	push	rsi
	sub	rsp, 32
	mov	rsi, rcx
	cmp	rcx, 257
	mov	ecx, 256
	cmovae	rcx, rsi
	add	rcx, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB9_1
# %bb.2:
	cmp	rsi, 1
	adc	rsi, 0
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 1
	mov	qword ptr [rax + 12], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	jmp	.LBB9_3
.LBB9_1:
	xor	eax, eax
.LBB9_3:
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xtc_new_u16;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_u16                    # -- Begin function _xtc_new_u16
	.p2align	4, 0x90
_xtc_new_u16:                           # @_xtc_new_u16
# %bb.0:
	push	rsi
	sub	rsp, 32
	mov	rsi, rcx
	cmp	rcx, 1
	adc	rsi, 0
	lea	rax, [rsi + rsi]
	cmp	rax, 257
	mov	ecx, 256
	cmovae	rcx, rax
	add	rcx, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB10_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 2
	mov	qword ptr [rax + 12], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	jmp	.LBB10_3
.LBB10_1:
	xor	eax, eax
.LBB10_3:
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xtc_new_i16;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_i16                    # -- Begin function _xtc_new_i16
	.p2align	4, 0x90
_xtc_new_i16:                           # @_xtc_new_i16
# %bb.0:
	push	rsi
	sub	rsp, 32
	mov	rsi, rcx
	cmp	rcx, 1
	adc	rsi, 0
	lea	rax, [rsi + rsi]
	cmp	rax, 257
	mov	ecx, 256
	cmovae	rcx, rax
	add	rcx, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB11_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 2
	mov	qword ptr [rax + 12], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	jmp	.LBB11_3
.LBB11_1:
	xor	eax, eax
.LBB11_3:
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xtc_new_u32;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_u32                    # -- Begin function _xtc_new_u32
	.p2align	4, 0x90
_xtc_new_u32:                           # @_xtc_new_u32
# %bb.0:
	push	rsi
	sub	rsp, 32
	mov	rsi, rcx
	cmp	rcx, 1
	adc	rsi, 0
	lea	rax, [4*rsi]
	cmp	rax, 257
	mov	ecx, 256
	cmovae	rcx, rax
	add	rcx, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB12_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 4
	mov	qword ptr [rax + 12], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	jmp	.LBB12_3
.LBB12_1:
	xor	eax, eax
.LBB12_3:
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xtc_new_i32;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_i32                    # -- Begin function _xtc_new_i32
	.p2align	4, 0x90
_xtc_new_i32:                           # @_xtc_new_i32
# %bb.0:
	push	rsi
	sub	rsp, 32
	mov	rsi, rcx
	cmp	rcx, 1
	adc	rsi, 0
	lea	rax, [4*rsi]
	cmp	rax, 257
	mov	ecx, 256
	cmovae	rcx, rax
	add	rcx, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB13_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 4
	mov	qword ptr [rax + 12], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	jmp	.LBB13_3
.LBB13_1:
	xor	eax, eax
.LBB13_3:
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xtc_new_pointer;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_pointer                # -- Begin function _xtc_new_pointer
	.p2align	4, 0x90
_xtc_new_pointer:                       # @_xtc_new_pointer
# %bb.0:
	push	rsi
	sub	rsp, 32
	mov	rsi, rcx
	cmp	rcx, 1
	adc	rsi, 0
	lea	rax, [8*rsi]
	cmp	rax, 257
	mov	ecx, 256
	cmovae	rcx, rax
	add	rcx, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB14_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 8
	mov	qword ptr [rax + 12], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	jmp	.LBB14_3
.LBB14_1:
	xor	eax, eax
.LBB14_3:
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xtc_new_bool;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_bool                   # -- Begin function _xtc_new_bool
	.p2align	4, 0x90
_xtc_new_bool:                          # @_xtc_new_bool
# %bb.0:
	push	rsi
	sub	rsp, 32
	mov	rsi, rcx
	cmp	rcx, 257
	mov	ecx, 256
	cmovae	rcx, rsi
	add	rcx, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB15_1
# %bb.2:
	cmp	rsi, 1
	adc	rsi, 0
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 1
	mov	qword ptr [rax + 12], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	jmp	.LBB15_3
.LBB15_1:
	xor	eax, eax
.LBB15_3:
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xtc_new_float;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_float                  # -- Begin function _xtc_new_float
	.p2align	4, 0x90
_xtc_new_float:                         # @_xtc_new_float
# %bb.0:
	push	rsi
	sub	rsp, 32
	mov	rsi, rcx
	cmp	rcx, 1
	adc	rsi, 0
	lea	rax, [4*rsi]
	cmp	rax, 257
	mov	ecx, 256
	cmovae	rcx, rax
	add	rcx, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB16_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 4
	mov	qword ptr [rax + 12], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	jmp	.LBB16_3
.LBB16_1:
	xor	eax, eax
.LBB16_3:
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xtc_new_double;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_double                 # -- Begin function _xtc_new_double
	.p2align	4, 0x90
_xtc_new_double:                        # @_xtc_new_double
# %bb.0:
	push	rsi
	sub	rsp, 32
	mov	rsi, rcx
	cmp	rcx, 1
	adc	rsi, 0
	lea	rax, [8*rsi]
	cmp	rax, 257
	mov	ecx, 256
	cmovae	rcx, rax
	add	rcx, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB17_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 8
	mov	qword ptr [rax + 12], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	jmp	.LBB17_3
.LBB17_1:
	xor	eax, eax
.LBB17_3:
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xtc_new_string;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_string                 # -- Begin function _xtc_new_string
	.p2align	4, 0x90
_xtc_new_string:                        # @_xtc_new_string
# %bb.0:
	push	rsi
	sub	rsp, 32
	mov	rsi, rcx
	cmp	rcx, 1
	adc	rsi, 0
	lea	rax, [8*rsi]
	cmp	rax, 257
	mov	ecx, 256
	cmovae	rcx, rax
	add	rcx, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB18_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 8
	mov	qword ptr [rax + 12], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	jmp	.LBB18_3
.LBB18_1:
	xor	eax, eax
.LBB18_3:
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xtc_count;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_count                      # -- Begin function _xtc_count
	.p2align	4, 0x90
_xtc_count:                             # @_xtc_count
# %bb.0:
	movzx	eax, word ptr [rcx - 28]
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
	je	.LBB20_9
# %bb.1:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB20_4
	.p2align	4, 0x90
.LBB20_2:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB20_3 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB20_4
.LBB20_3:                               #   Parent Loop BB20_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB20_3
	jmp	.LBB20_2
.LBB20_4:
	mov	rax, qword ptr [rsi - 12]
	test	rax, rax
	je	.LBB20_7
# %bb.5:
	xorps	xmm0, xmm0
	.p2align	4, 0x90
.LBB20_6:                               # =>This Inner Loop Header: Depth=1
	mov	rcx, qword ptr [rax - 8]
	movups	xmmword ptr [rax - 16], xmm0
	mov	qword ptr [rax], 0
	mov	rax, rcx
	test	rcx, rcx
	jne	.LBB20_6
.LBB20_7:
	mov	qword ptr [rsi - 12], 0
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB20_9
# %bb.8:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB20_9:
	mov	rbx, qword ptr [rsi - 20]
	test	rbx, rbx
	je	.LBB20_13
# %bb.10:
	mov	r14, qword ptr [rsi - 36]
	mov	r15, qword ptr [rsi - 28]
	mov	dword ptr [rsi - 4], -2147483648
	test	r15, r15
	je	.LBB20_13
# %bb.11:
	mov	rdi, rsi
	.p2align	4, 0x90
.LBB20_12:                              # =>This Inner Loop Header: Depth=1
	mov	rcx, rdi
	call	rbx
	add	rdi, r14
	dec	r15
	jne	.LBB20_12
.LBB20_13:
	mov	rax, qword ptr [rsi - 48]
	cmp	rax, 27
	ja	.LBB20_19
# %bb.14:
	add	rsi, -48
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB20_17
	.p2align	4, 0x90
.LBB20_15:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB20_16 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB20_17
.LBB20_16:                              #   Parent Loop BB20_15 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB20_16
	jmp	.LBB20_15
.LBB20_17:
	lea	rcx, [rip + xt_freelist]
	mov	rdx, qword ptr [rcx + 8*rax]
	mov	qword ptr [rsi], rdx
	mov	qword ptr [rcx + 8*rax], rsi
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB20_19
# %bb.18:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB20_19:
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
	je	.LBB21_9
# %bb.1:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB21_4
	.p2align	4, 0x90
.LBB21_2:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB21_3 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB21_4
.LBB21_3:                               #   Parent Loop BB21_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB21_3
	jmp	.LBB21_2
.LBB21_4:
	mov	rax, qword ptr [rcx - 12]
	test	rax, rax
	je	.LBB21_7
# %bb.5:
	xorps	xmm0, xmm0
	.p2align	4, 0x90
.LBB21_6:                               # =>This Inner Loop Header: Depth=1
	mov	rdx, qword ptr [rax - 8]
	movups	xmmword ptr [rax - 16], xmm0
	mov	qword ptr [rax], 0
	mov	rax, rdx
	test	rdx, rdx
	jne	.LBB21_6
.LBB21_7:
	mov	qword ptr [rcx - 12], 0
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB21_9
# %bb.8:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB21_9:
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
	je	.LBB22_3
	.p2align	4, 0x90
.LBB22_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB22_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB22_3
.LBB22_2:                               #   Parent Loop BB22_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB22_2
	jmp	.LBB22_1
.LBB22_3:
	mov	rax, qword ptr [rcx - 16]
	test	rax, rax
	je	.LBB22_7
# %bb.4:
	mov	rdx, qword ptr [rcx - 8]
	add	rcx, -16
	mov	qword ptr [rax], rdx
	test	rdx, rdx
	je	.LBB22_6
# %bb.5:
	mov	qword ptr [rdx - 16], rax
.LBB22_6:
	xorps	xmm0, xmm0
	movups	xmmword ptr [rcx], xmm0
.LBB22_7:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB22_9
# %bb.8:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB22_9:
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
	je	.LBB23_3
	.p2align	4, 0x90
.LBB23_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB23_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB23_3
.LBB23_2:                               #   Parent Loop BB23_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB23_2
	jmp	.LBB23_1
.LBB23_3:
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
	je	.LBB24_2
# %bb.1:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB24_2:
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
	je	.LBB25_3
	.p2align	4, 0x90
.LBB25_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB25_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB25_3
.LBB25_2:                               #   Parent Loop BB25_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB25_2
	jmp	.LBB25_1
.LBB25_3:
	mov	rax, qword ptr [rcx - 16]
	test	rax, rax
	je	.LBB25_7
# %bb.4:
	lea	r8, [rcx - 16]
	mov	r9, qword ptr [rcx - 8]
	mov	qword ptr [rax], r9
	test	r9, r9
	je	.LBB25_6
# %bb.5:
	mov	qword ptr [r9 - 16], rax
.LBB25_6:
	xorps	xmm0, xmm0
	movups	xmmword ptr [r8], xmm0
.LBB25_7:
	test	rdx, rdx
	je	.LBB25_12
# %bb.8:
	cmp	dword ptr [rdx - 40], 1481920322
	jne	.LBB25_12
# %bb.9:
	mov	rax, qword ptr [rdx - 12]
	add	rdx, -12
	mov	qword ptr [rcx - 16], rdx
	mov	qword ptr [rcx - 8], rax
	test	rax, rax
	je	.LBB25_11
# %bb.10:
	lea	r8, [rcx - 8]
	mov	qword ptr [rax - 16], r8
.LBB25_11:
	mov	qword ptr [rdx], rcx
.LBB25_12:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB25_14
# %bb.13:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB25_14:
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
.LCPI31_0:
	.long	0x30000000                      # float 4.65661287E-10
.LCPI31_1:
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
	mulss	xmm0, dword ptr [rip + .LCPI31_0]
	movss	xmm1, dword ptr [rip + .LCPI31_1] # xmm1 = [5.0E-1,0.0E+0,0.0E+0,0.0E+0]
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
.LCPI32_0:
	.quad	0x3e00000000000000              # double 4.6566128730773926E-10
.LCPI32_1:
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
	mulsd	xmm0, qword ptr [rip + .LCPI32_0]
	movsd	xmm1, qword ptr [rip + .LCPI32_1] # xmm1 = [5.0E-1,0.0E+0]
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
.LCPI33_0:
	.long	1127219200                      # 0x43300000
	.long	1160773632                      # 0x45300000
	.long	0                               # 0x0
	.long	0                               # 0x0
.LCPI33_1:
	.quad	0x4330000000000000              # double 4503599627370496
	.quad	0x4530000000000000              # double 1.9342813113834067E+25
.LCPI33_2:
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
	unpcklps	xmm0, xmmword ptr [rip + .LCPI33_0] # xmm0 = xmm0[0],mem[0],xmm0[1],mem[1]
	subpd	xmm0, xmmword ptr [rip + .LCPI33_1]
	movapd	xmm1, xmm0
	unpckhpd	xmm1, xmm0                      # xmm1 = xmm1[1],xmm0[1]
	addsd	xmm1, xmm0
	mulsd	xmm1, qword ptr [rip + .LCPI33_2]
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
.LCPI34_0:
	.long	1127219200                      # 0x43300000
	.long	1160773632                      # 0x45300000
	.long	0                               # 0x0
	.long	0                               # 0x0
.LCPI34_1:
	.quad	0x4330000000000000              # double 4503599627370496
	.quad	0x4530000000000000              # double 1.9342813113834067E+25
.LCPI34_2:
	.quad	0x3e7ad7f29abcaf48              # double 9.9999999999999995E-8
.LCPI34_3:
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
	unpcklps	xmm0, xmmword ptr [rip + .LCPI34_0] # xmm0 = xmm0[0],mem[0],xmm0[1],mem[1]
	subpd	xmm0, xmmword ptr [rip + .LCPI34_1]
	movapd	xmm1, xmm0
	unpckhpd	xmm1, xmm0                      # xmm1 = xmm1[1],xmm0[1]
	addsd	xmm1, xmm0
	mulsd	xmm1, qword ptr [rip + .LCPI34_2]
	subsd	xmm1, qword ptr [rip + xt_clk_origin]
	mulsd	xmm1, qword ptr [rip + .LCPI34_3]
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
.LCPI35_0:
	.quad	0x404e000000000000              # double 60
.LCPI35_1:
	.quad	0x41cdcd6500000000              # double 1.0E+9
.LCPI35_2:
	.quad	0x43e0000000000000              # double 9.2233720368547758E+18
	.text
	.globl	_xt_clk_delay
	.p2align	4, 0x90
_xt_clk_delay:                          # @_xt_clk_delay
# %bb.0:
	mov	eax, ecx
	cvtsi2sd	xmm0, rax
	divsd	xmm0, qword ptr [rip + .LCPI35_0]
	mulsd	xmm0, qword ptr [rip + .LCPI35_1]
	cvttsd2si	rcx, xmm0
	mov	rdx, rcx
	sar	rdx, 63
	subsd	xmm0, qword ptr [rip + .LCPI35_2]
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
	jbe	.LBB36_2
# %bb.1:
	xor	eax, eax
	jmp	.LBB36_5
.LBB36_2:
	movzx	eax, cl
	shl	eax, 11
	lea	rcx, [rip + xt_bank_regions]
	add	rcx, rax
	movzx	eax, dl
	lea	rsi, [rcx + 8*rax]
	cmp	qword ptr [rcx + 8*rax], 0
	jne	.LBB36_4
# %bb.3:
	mov	ecx, 12288
	call	_xt_calloc
	mov	qword ptr [rsi], rax
.LBB36_4:
	mov	rax, qword ptr [rsi]
.LBB36_5:
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
	je	.LBB38_9
# %bb.1:
	mov	rdi, rdx
	mov	rbx, rcx
	mov	dword ptr [rip + _xt_threads_active], 1
	mov	ecx, 16
	call	_xt_calloc
	test	rax, rax
	je	.LBB38_9
# %bb.2:
	mov	rsi, rax
	mov	qword ptr [rax], rbx
	mov	qword ptr [rax + 8], rdi
	mov	qword ptr [rsp + 40], 0
	mov	dword ptr [rsp + 32], 0
	lea	r8, [rip + xt_thread_entry]
	xor	ecx, ecx
	xor	edx, edx
	mov	r9, rax
	call	CreateThread
	test	rax, rax
	jne	.LBB38_10
# %bb.3:
	mov	rax, qword ptr [rsi - 8]
	cmp	rax, 27
	ja	.LBB38_9
# %bb.4:
	add	rsi, -8
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB38_7
	.p2align	4, 0x90
.LBB38_5:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB38_6 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB38_7
.LBB38_6:                               #   Parent Loop BB38_5 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB38_6
	jmp	.LBB38_5
.LBB38_7:
	lea	rcx, [rip + xt_freelist]
	mov	rdx, qword ptr [rcx + 8*rax]
	mov	qword ptr [rsi], rdx
	mov	qword ptr [rcx + 8*rax], rsi
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB38_9
# %bb.8:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB38_9:
	xor	eax, eax
.LBB38_10:
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
	sub	rsp, 40
	mov	rax, rcx
	mov	r8, qword ptr [rcx - 8]
	mov	rdx, qword ptr [rcx]
	mov	rcx, qword ptr [rcx + 8]
	cmp	r8, 27
	ja	.LBB39_6
# %bb.1:
	add	rax, -8
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_4
	.p2align	4, 0x90
.LBB39_2:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB39_3 Depth 2
	mov	r9d, 1
	xchg	dword ptr [rip + xt_alloc_spin], r9d
	test	r9d, r9d
	je	.LBB39_4
.LBB39_3:                               #   Parent Loop BB39_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	r9d, dword ptr [rip + xt_alloc_spin]
	test	r9d, r9d
	jne	.LBB39_3
	jmp	.LBB39_2
.LBB39_4:
	lea	r9, [rip + xt_freelist]
	mov	r10, qword ptr [r9 + 8*r8]
	mov	qword ptr [rax], r10
	mov	qword ptr [r9 + 8*r8], rax
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_6
# %bb.5:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB39_6:
	test	rdx, rdx
	je	.LBB39_8
# %bb.7:
	call	rdx
.LBB39_8:
	xor	eax, eax
	add	rsp, 40
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
	je	.LBB40_1
# %bb.2:
	mov	rsi, rcx
	mov	edx, -1
	call	WaitForSingleObject
	mov	rcx, rsi
	call	CloseHandle
	xor	eax, eax
	jmp	.LBB40_3
.LBB40_1:
	mov	eax, -1
.LBB40_3:
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
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB46_3
	.p2align	4, 0x90
.LBB46_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB46_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB46_3
.LBB46_2:                               #   Parent Loop BB46_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB46_2
	jmp	.LBB46_1
.LBB46_3:
	mov	rsi, qword ptr [rip + xt_freelist]
	test	rsi, rsi
	je	.LBB46_5
# %bb.4:
	mov	rax, qword ptr [rsi]
	mov	qword ptr [rip + xt_freelist], rax
	jmp	.LBB46_9
.LBB46_5:
	mov	rax, qword ptr [rip + xt_cur]
	add	rax, 16
	cmp	rax, qword ptr [rip + xt_end]
	jbe	.LBB46_8
# %bb.6:
	xor	esi, esi
	mov	edx, 1048576
	xor	ecx, ecx
	mov	r8d, 12288
	mov	r9d, 4
	call	VirtualAlloc
	test	rax, rax
	je	.LBB46_9
# %bb.7:
	mov	qword ptr [rip + xt_cur], rax
	add	rax, 1048576
	mov	qword ptr [rip + xt_end], rax
.LBB46_8:
	mov	rsi, qword ptr [rip + xt_cur]
	lea	rax, [rsi + 16]
	mov	qword ptr [rip + xt_cur], rax
.LBB46_9:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB46_11
# %bb.10:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB46_11:
	test	rsi, rsi
	je	.LBB46_12
# %bb.13:
	xorps	xmm0, xmm0
	movups	xmmword ptr [rsi], xmm0
	add	rsi, 8
	test	rsi, rsi
	je	.LBB46_16
.LBB46_15:
	mov	rcx, rsi
	call	InitializeSRWLock
.LBB46_16:
	mov	rax, rsi
	add	rsp, 32
	pop	rsi
	ret
.LBB46_12:
	xor	esi, esi
	test	rsi, rsi
	jne	.LBB46_15
	jmp	.LBB46_16
                                        # -- End function
	.def	_xt_mutex_free;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_mutex_free                  # -- Begin function _xt_mutex_free
	.p2align	4, 0x90
_xt_mutex_free:                         # @_xt_mutex_free
# %bb.0:
	test	rcx, rcx
	je	.LBB47_7
# %bb.1:
	mov	rax, qword ptr [rcx - 8]
	cmp	rax, 27
	ja	.LBB47_7
# %bb.2:
	add	rcx, -8
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB47_5
	.p2align	4, 0x90
.LBB47_3:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB47_4 Depth 2
	mov	edx, 1
	xchg	dword ptr [rip + xt_alloc_spin], edx
	test	edx, edx
	je	.LBB47_5
.LBB47_4:                               #   Parent Loop BB47_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	edx, dword ptr [rip + xt_alloc_spin]
	test	edx, edx
	jne	.LBB47_4
	jmp	.LBB47_3
.LBB47_5:
	lea	rdx, [rip + xt_freelist]
	mov	r8, qword ptr [rdx + 8*rax]
	mov	qword ptr [rcx], r8
	mov	qword ptr [rdx + 8*rax], rcx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB47_7
# %bb.6:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB47_7:
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
	je	.LBB50_1
# %bb.2:
	call	TryAcquireSRWLockExclusive
	mov	ecx, eax
	xor	eax, eax
	test	cl, cl
	setne	al
	add	rsp, 40
	ret
.LBB50_1:
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
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB51_3
	.p2align	4, 0x90
.LBB51_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB51_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB51_3
.LBB51_2:                               #   Parent Loop BB51_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB51_2
	jmp	.LBB51_1
.LBB51_3:
	mov	rsi, qword ptr [rip + xt_freelist]
	test	rsi, rsi
	je	.LBB51_5
# %bb.4:
	mov	rax, qword ptr [rsi]
	mov	qword ptr [rip + xt_freelist], rax
	jmp	.LBB51_9
.LBB51_5:
	mov	rax, qword ptr [rip + xt_cur]
	add	rax, 16
	cmp	rax, qword ptr [rip + xt_end]
	jbe	.LBB51_8
# %bb.6:
	xor	esi, esi
	mov	edx, 1048576
	xor	ecx, ecx
	mov	r8d, 12288
	mov	r9d, 4
	call	VirtualAlloc
	test	rax, rax
	je	.LBB51_9
# %bb.7:
	mov	qword ptr [rip + xt_cur], rax
	add	rax, 1048576
	mov	qword ptr [rip + xt_end], rax
.LBB51_8:
	mov	rsi, qword ptr [rip + xt_cur]
	lea	rax, [rsi + 16]
	mov	qword ptr [rip + xt_cur], rax
.LBB51_9:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB51_11
# %bb.10:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB51_11:
	test	rsi, rsi
	je	.LBB51_12
# %bb.13:
	xorps	xmm0, xmm0
	movups	xmmword ptr [rsi], xmm0
	add	rsi, 8
	test	rsi, rsi
	je	.LBB51_16
.LBB51_15:
	mov	rcx, rsi
	call	InitializeConditionVariable
.LBB51_16:
	mov	rax, rsi
	add	rsp, 32
	pop	rsi
	ret
.LBB51_12:
	xor	esi, esi
	test	rsi, rsi
	jne	.LBB51_15
	jmp	.LBB51_16
                                        # -- End function
	.def	_xt_cond_free;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_cond_free                   # -- Begin function _xt_cond_free
	.p2align	4, 0x90
_xt_cond_free:                          # @_xt_cond_free
# %bb.0:
	test	rcx, rcx
	je	.LBB52_7
# %bb.1:
	mov	rax, qword ptr [rcx - 8]
	cmp	rax, 27
	ja	.LBB52_7
# %bb.2:
	add	rcx, -8
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB52_5
	.p2align	4, 0x90
.LBB52_3:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB52_4 Depth 2
	mov	edx, 1
	xchg	dword ptr [rip + xt_alloc_spin], edx
	test	edx, edx
	je	.LBB52_5
.LBB52_4:                               #   Parent Loop BB52_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	edx, dword ptr [rip + xt_alloc_spin]
	test	edx, edx
	jne	.LBB52_4
	jmp	.LBB52_3
.LBB52_5:
	lea	rdx, [rip + xt_freelist]
	mov	r8, qword ptr [rdx + 8*rax]
	mov	qword ptr [rcx], r8
	mov	qword ptr [rdx + 8*rax], rcx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB52_7
# %bb.6:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB52_7:
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
	jne	.LBB53_1
# %bb.2:
	mov	r8d, -1
	xor	r9d, r9d
	jmp	SleepConditionVariableSRW       # TAILCALL
.LBB53_1:
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
	je	.LBB58_1
# %bb.2:
	mov	edx, -1
	jmp	WaitForSingleObject             # TAILCALL
.LBB58_1:
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
	je	.LBB59_1
# %bb.2:
	mov	edx, 1
	xor	r8d, r8d
	jmp	ReleaseSemaphore                # TAILCALL
.LBB59_1:
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
	je	.LBB60_1
# %bb.2:
	xor	edx, edx
	call	WaitForSingleObject
	mov	ecx, eax
	xor	eax, eax
	test	ecx, ecx
	sete	al
	add	rsp, 40
	ret
.LBB60_1:
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
	je	.LBB64_1
# %bb.2:
	mov	eax, dword ptr [rcx]
	ret
.LBB64_1:
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
	je	.LBB65_2
# %bb.1:
	xchg	dword ptr [rcx], edx
.LBB65_2:
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
	je	.LBB66_1
# %bb.2:
	mov	eax, edx
	lock		xadd	dword ptr [rcx], eax
	add	eax, edx
	ret
.LBB66_1:
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
	je	.LBB67_1
# %bb.2:
	mov	eax, edx
	xchg	dword ptr [rcx], eax
	ret
.LBB67_1:
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
	je	.LBB68_1
# %bb.2:
	mov	eax, edx
	lock		cmpxchg	dword ptr [rcx], r8d
	mov	eax, 0
	sete	al
	ret
.LBB68_1:
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
	je	.LBB69_1
# %bb.2:
	mov	rax, qword ptr [rcx]
	ret
.LBB69_1:
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
	je	.LBB70_2
# %bb.1:
	xchg	qword ptr [rcx], rdx
.LBB70_2:
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
	je	.LBB71_1
# %bb.2:
	mov	rax, rdx
	lock		cmpxchg	qword ptr [rcx], r8
	mov	eax, 0
	sete	al
	ret
.LBB71_1:
	xor	eax, eax
	ret
                                        # -- End function
	.lcomm	xt_freelist,224,16              # @xt_freelist
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
	.lcomm	xt_cur,8,8                      # @xt_cur
	.lcomm	xt_end,8,8                      # @xt_end
	.addrsig
	.addrsig_sym xt_thread_entry
	.addrsig_sym xt_rt_spin
	.addrsig_sym xt_alloc_spin

// ── _xtc_sinit_run ─────────────────────────────────────────────────────────
// The race-free static-init once (support/generic/runtime/xt-sinit.c), emitted
// by lowering only for modules that thread. APPENDED rather than regenerated
// with the rest of this file: a fresh `clang -S` of the whole runtime emits
// instructions the in-house assemblers do not all implement.
//
// This tail carried the OLD two-call shape (_xtc_sinit_enter / _xtc_sinit_done)
// long after lowering moved to the single `_xtc_sinit_run` — so the runtime
// defined two symbols nothing called and lacked the one everything did. It went
// unnoticed while the in-house path was opt-in and no threads fixture ran
// through it. A checked-in generated file is only as current as the last time
// somebody regenerated it.
//
// Every `.L` local label is renamed `.Lsi_`, or two concatenated clang outputs
// collide on them. Regenerate with
//   clang --target=x86_64-pc-windows-gnu -S -O1 -masm=intel \
//         -fno-stack-protector -fomit-frame-pointer \
//         support/generic/runtime/xt-sinit.c
// then re-apply `.L` -> `.Lsi_`.
	.text
	.def	@feat.00;
	.scl	3;
	.type	0;
	.endef
	.globl	@feat.00
.set @feat.00, 0
	.intel_syntax noprefix
	.file	"xt-sinit.c"
	.def	_xtc_sinit_run;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_sinit_run                  # -- Begin function _xtc_sinit_run
	.p2align	4, 0x90
_xtc_sinit_run:                         # @_xtc_sinit_run
.seh_proc _xtc_sinit_run
# %bb.0:
	push	r15
	.seh_pushreg r15
	push	r14
	.seh_pushreg r14
	push	rsi
	.seh_pushreg rsi
	push	rdi
	.seh_pushreg rdi
	push	rbx
	.seh_pushreg rbx
	sub	rsp, 32
	.seh_stackalloc 32
	.seh_endprologue
	test	rcx, rcx
	je	.Lsi_BB0_24
# %bb.1:
	mov	rbx, r8
	mov	rdi, rdx
	mov	rsi, rcx
	lea	r14, [rip + xt_sinit_flag]
	lea	r15, [rip + xt_sinit_owner]
	jmp	.Lsi_BB0_2
	.p2align	4, 0x90
.Lsi_BB0_4:                                #   in Loop: Header=BB0_2 Depth=1
	call	_xt_rt_unlock
	mov	eax, 1
.Lsi_BB0_14:                               #   in Loop: Header=BB0_2 Depth=1
	test	eax, eax
	jne	.Lsi_BB0_15
.Lsi_BB0_2:                                # =>This Loop Header: Depth=1
                                        #     Child Loop BB0_10 Depth 2
	call	_xt_rt_lock
	movzx	eax, byte ptr [rsi]
	test	eax, eax
	je	.Lsi_BB0_5
# %bb.3:                                #   in Loop: Header=BB0_2 Depth=1
	cmp	eax, 2
	je	.Lsi_BB0_4
# %bb.8:                                #   in Loop: Header=BB0_2 Depth=1
	call	_xt_thread_self_id
	movsxd	rcx, dword ptr [rip + xt_sinit_n]
	test	rcx, rcx
	jle	.Lsi_BB0_13
# %bb.9:                                #   in Loop: Header=BB0_2 Depth=1
	shl	rcx, 3
	xor	edx, edx
	mov	r8, r15
	jmp	.Lsi_BB0_10
	.p2align	4, 0x90
.Lsi_BB0_12:                               #   in Loop: Header=BB0_10 Depth=2
	add	r8, 4
	add	rdx, 8
	cmp	rcx, rdx
	je	.Lsi_BB0_13
.Lsi_BB0_10:                               #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	qword ptr [rdx + r14], rsi
	jne	.Lsi_BB0_12
# %bb.11:                               #   in Loop: Header=BB0_10 Depth=2
	cmp	dword ptr [r8], eax
	jne	.Lsi_BB0_12
	jmp	.Lsi_BB0_4
	.p2align	4, 0x90
.Lsi_BB0_5:                                #   in Loop: Header=BB0_2 Depth=1
	mov	byte ptr [rsi], 1
	movsxd	rax, dword ptr [rip + xt_sinit_n]
	cmp	rax, 31
	jg	.Lsi_BB0_7
# %bb.6:                                #   in Loop: Header=BB0_2 Depth=1
	mov	qword ptr [r14 + 8*rax], rsi
	call	_xt_thread_self_id
	movsxd	rcx, dword ptr [rip + xt_sinit_n]
	mov	dword ptr [r15 + 4*rcx], eax
	lea	eax, [rcx + 1]
	mov	dword ptr [rip + xt_sinit_n], eax
.Lsi_BB0_7:                                #   in Loop: Header=BB0_2 Depth=1
	call	_xt_rt_unlock
	mov	eax, 2
	jmp	.Lsi_BB0_14
	.p2align	4, 0x90
.Lsi_BB0_13:                               #   in Loop: Header=BB0_2 Depth=1
	call	_xt_rt_unlock
	call	_xt_thread_yield
	xor	eax, eax
	jmp	.Lsi_BB0_14
.Lsi_BB0_15:
	cmp	eax, 1
	jne	.Lsi_BB0_16
.Lsi_BB0_24:
	add	rsp, 32
	pop	rbx
	pop	rdi
	pop	rsi
	pop	r14
	pop	r15
	ret
.Lsi_BB0_16:
	test	rdi, rdi
	je	.Lsi_BB0_18
# %bb.17:
	mov	rcx, rbx
	call	rdi
.Lsi_BB0_18:
	call	_xt_rt_lock
	mov	byte ptr [rsi], 2
	movsxd	rax, dword ptr [rip + xt_sinit_n]
	test	rax, rax
	jle	.Lsi_BB0_23
# %bb.19:
	lea	rdx, [4*rax]
	xor	ecx, ecx
	.p2align	4, 0x90
.Lsi_BB0_21:                               # =>This Inner Loop Header: Depth=1
	cmp	qword ptr [r14], rsi
	je	.Lsi_BB0_22
# %bb.20:                               #   in Loop: Header=BB0_21 Depth=1
	add	rcx, 4
	add	r14, 8
	cmp	rdx, rcx
	jne	.Lsi_BB0_21
	jmp	.Lsi_BB0_23
.Lsi_BB0_22:
	lea	edx, [rax - 1]
	mov	dword ptr [rip + xt_sinit_n], edx
	lea	rdx, [rip + xt_sinit_flag]
	mov	rdx, qword ptr [rdx + 8*rax - 8]
	mov	qword ptr [r14], rdx
	lea	rdx, [rip + xt_sinit_owner]
	mov	eax, dword ptr [rdx + 4*rax - 4]
	mov	dword ptr [rcx + rdx], eax
.Lsi_BB0_23:
	add	rsp, 32
	pop	rbx
	pop	rdi
	pop	rsi
	pop	r14
	pop	r15
	jmp	_xt_rt_unlock                   # TAILCALL
	.seh_endproc
                                        # -- End function
	.lcomm	xt_sinit_n,4,4                  # @xt_sinit_n
	.lcomm	xt_sinit_flag,256,16            # @xt_sinit_flag
	.lcomm	xt_sinit_owner,128,16           # @xt_sinit_owner
	.addrsig

// ── getpid ─────────────────────────────────────────────────────────────────
// POSIX getpid, bridged to kernel32's GetCurrentProcessId (see the XT_WIN64
// block in rt-freestanding.c). APPENDED rather than regenerated with the rest
// of this file for the same reason the _xtc_sinit_run tail is: the checked-in
// body came from a different clang, and a full `clang -S` today rewrites ~780
// lines of unrelated register allocation. This is byte-for-byte what clang
// emits for the C above, so a future full regeneration produces the same thing.
//
// mingw's libc used to supply getpid, so the gap only appeared when the
// in-house path stopped falling back to mingw — `tests/fixtures/extern_redeclare.xc`
// failed to link with "undefined symbol 'getpid'".
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
