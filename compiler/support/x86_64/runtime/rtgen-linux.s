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

# rtgen-linux.s — GENERATED from src/xtc/support-src/rt-freestanding.c by the
# recipe at the top of that file (Homebrew clang 22.1.3,
# -DXT_SINIT_C_INCLUDED=1 -DXT_NO_WEAK_SEAM=1), plus two hand-applied pieces:
#   * _xt_main_tls_pad — 240 reserved bytes below the main tcb (static TLS)
#   * the _xtc_sinit_run tail, appended per the convention documented there
	.intel_syntax noprefix
	.file	"rt-freestanding.c"
	.text
	.globl	_xt_calloc                      # -- Begin function _xt_calloc
	.p2align	4
	.type	_xt_calloc,@function
_xt_calloc:                             # @_xt_calloc
# %bb.0:
	push	r14
	push	rbx
	push	rax
	lea	rsi, [rdi + 8]
	cmp	rsi, 1025
	jb	.LBB0_3
# %bb.1:
	mov	edi, 1
	call	calloc@PLT
	test	rax, rax
	je	.LBB0_15
# %bb.2:
	mov	qword ptr [rax], 64
	add	rax, 8
	jmp	.LBB0_16
.LBB0_3:
	mov	rbx, rdi
	add	rdi, 23
	mov	r14, rdi
	shr	r14, 4
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB0_6
	.p2align	4
.LBB0_4:                                # =>This Loop Header: Depth=1
                                        #     Child Loop BB0_5 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB0_6
.LBB0_5:                                #   Parent Loop BB0_4 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB0_5
	jmp	.LBB0_4
.LBB0_6:
	lea	rcx, [rip + xt_cache]
	mov	rax, qword ptr [rcx + 8*r14 - 8]
	test	rax, rax
	je	.LBB0_10
# %bb.7:
	mov	rdx, qword ptr [rax]
	lea	rsi, [rip + xt_cache_n]
	dec	dword ptr [rsi + 4*r14 - 4]
	mov	qword ptr [rcx + 8*r14 - 8], rdx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB0_13
# %bb.8:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB0_13
.LBB0_10:
	and	rdi, -16
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB0_12
# %bb.11:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB0_12:
	call	malloc@PLT
	test	rax, rax
	je	.LBB0_15
.LBB0_13:
	dec	r14
	mov	qword ptr [rax], r14
	add	rax, 8
	test	rbx, rbx
	je	.LBB0_16
# %bb.14:
	mov	rdi, rax
	xor	esi, esi
	mov	rdx, rbx
	add	rsp, 8
	pop	rbx
	pop	r14
	jmp	memset@PLT                      # TAILCALL
.LBB0_15:
	xor	eax, eax
.LBB0_16:
	add	rsp, 8
	pop	rbx
	pop	r14
	ret
.Lfunc_end0:
	.size	_xt_calloc, .Lfunc_end0-_xt_calloc
                                        # -- End function
	.globl	_xt_alloc_lock                  # -- Begin function _xt_alloc_lock
	.p2align	4
	.type	_xt_alloc_lock,@function
_xt_alloc_lock:                         # @_xt_alloc_lock
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB1_3
	.p2align	4
.LBB1_1:                                # =>This Loop Header: Depth=1
                                        #     Child Loop BB1_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB1_3
.LBB1_2:                                #   Parent Loop BB1_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB1_2
	jmp	.LBB1_1
.LBB1_3:
	ret
.Lfunc_end1:
	.size	_xt_alloc_lock, .Lfunc_end1-_xt_alloc_lock
                                        # -- End function
	.globl	_xt_alloc_unlock                # -- Begin function _xt_alloc_unlock
	.p2align	4
	.type	_xt_alloc_unlock,@function
_xt_alloc_unlock:                       # @_xt_alloc_unlock
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB2_2
# %bb.1:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB2_2:
	ret
.Lfunc_end2:
	.size	_xt_alloc_unlock, .Lfunc_end2-_xt_alloc_unlock
                                        # -- End function
	.globl	_xt_free                        # -- Begin function _xt_free
	.p2align	4
	.type	_xt_free,@function
_xt_free:                               # @_xt_free
# %bb.0:
	test	rdi, rdi
	je	.LBB3_10
# %bb.1:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	free@PLT                        # TAILCALL
# %bb.2:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB3_5
	.p2align	4
.LBB3_3:                                # =>This Loop Header: Depth=1
                                        #     Child Loop BB3_4 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB3_5
.LBB3_4:                                #   Parent Loop BB3_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB3_4
	jmp	.LBB3_3
.LBB3_5:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB3_8
# %bb.6:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	free@PLT                        # TAILCALL
# %bb.7:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	free@PLT                        # TAILCALL
.LBB3_8:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB3_10
# %bb.9:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB3_10:
	ret
.Lfunc_end3:
	.size	_xt_free, .Lfunc_end3-_xt_free
                                        # -- End function
	.globl	memset                          # -- Begin function memset
	.p2align	4
	.type	memset,@function
memset:                                 # @memset
# %bb.0:
	mov	rax, rdi
	test	rdx, rdx
	je	.LBB4_3
# %bb.1:
	xor	ecx, ecx
	.p2align	4
.LBB4_2:                                # =>This Inner Loop Header: Depth=1
	mov	byte ptr [rax + rcx], sil
	inc	rcx
	cmp	rdx, rcx
	jne	.LBB4_2
.LBB4_3:
	ret
.Lfunc_end4:
	.size	memset, .Lfunc_end4-memset
                                        # -- End function
	.section	.rodata.cst16,"aM",@progbits,16
	.p2align	4, 0x0                          # -- Begin function _xt_fmt_f
.LCPI5_0:
	.quad	0x8000000000000000              # double -0
	.quad	0x8000000000000000              # double -0
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0
.LCPI5_1:
	.quad	0x4024000000000000              # double 10
	.text
	.globl	_xt_fmt_f
	.p2align	4
	.type	_xt_fmt_f,@function
_xt_fmt_f:                              # @_xt_fmt_f
# %bb.0:
	push	rbp
	push	rbx
	xor	eax, eax
	test	ecx, ecx
	cmovg	eax, ecx
	cmp	eax, 24
	mov	r9d, 24
	cmovl	r9d, eax
	xorpd	xmm1, xmm1
	ucomisd	xmm1, xmm0
	jbe	.LBB5_1
# %bb.2:
	lea	rsi, [rdi + 1]
	mov	byte ptr [rdi], 45
	xorpd	xmm0, xmmword ptr [rip + .LCPI5_0]
	jmp	.LBB5_3
.LBB5_1:
	mov	rsi, rdi
.LBB5_3:
	cvttsd2si	r10, xmm0
	xor	r11d, r11d
	movabs	rbx, -3689348814741910323
	mov	rdx, r10
	.p2align	4
.LBB5_4:                                # =>This Inner Loop Header: Depth=1
	mov	r8, rdx
	mov	rax, rdx
	mul	rbx
	shr	rdx, 3
	lea	eax, [rdx + rdx]
	lea	eax, [rax + 4*rax]
	mov	ebp, r8d
	sub	ebp, eax
	or	bpl, 48
	lea	rax, [r11 + 1]
	mov	byte ptr [rsp + r11 - 24], bpl
	cmp	r8, 10
	jb	.LBB5_6
# %bb.5:                                #   in Loop: Header=BB5_4 Depth=1
	cmp	r11, 23
	mov	r11, rax
	jb	.LBB5_4
	.p2align	4
.LBB5_6:                                # =>This Inner Loop Header: Depth=1
	dec	rax
	movzx	edx, byte ptr [rsp + rax - 24]
	mov	byte ptr [rsi], dl
	lea	rsi, [rsi + 1]
	jg	.LBB5_6
# %bb.7:
	test	ecx, ecx
	jle	.LBB5_11
# %bb.8:
	xorps	xmm1, xmm1
	cvtsi2sd	xmm1, r10
	subsd	xmm0, xmm1
	mov	byte ptr [rsi], 46
	neg	r9d
	mov	eax, 1
	movsd	xmm1, qword ptr [rip + .LCPI5_1] # xmm1 = [1.0E+1,0.0E+0]
	xor	ecx, ecx
	mov	edx, 9
	.p2align	4
.LBB5_9:                                # =>This Inner Loop Header: Depth=1
	mulsd	xmm0, xmm1
	cvttsd2si	r8d, xmm0
	test	r8d, r8d
	cmovle	r8d, ecx
	cmp	r8d, 9
	cmovge	r8d, edx
	xorps	xmm2, xmm2
	cvtsi2sd	xmm2, r8d
                                        # kill: def $r8b killed $r8b killed $r8d
	or	r8b, 48
	mov	byte ptr [rsi + rax], r8b
	subsd	xmm0, xmm2
	inc	rax
	lea	r8d, [r9 + rax]
	cmp	r8d, 1
	jne	.LBB5_9
# %bb.10:
	add	rsi, rax
.LBB5_11:
	mov	byte ptr [rsi], 0
	sub	esi, edi
	mov	eax, esi
	pop	rbx
	pop	rbp
	ret
.Lfunc_end5:
	.size	_xt_fmt_f, .Lfunc_end5-_xt_fmt_f
                                        # -- End function
	.globl	_xtc_alloc                      # -- Begin function _xtc_alloc
	.p2align	4
	.type	_xtc_alloc,@function
_xtc_alloc:                             # @_xtc_alloc
# %bb.0:
	push	r15
	push	r14
	push	rbx
	mov	rbx, rdx
	mov	r14, rdi
	cmp	rdi, 1
	adc	r14, 0
	mov	r15, rsi
	mov	rax, r14
	imul	rax, rsi
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB6_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], r15
	mov	qword ptr [rax + 12], r14
	mov	qword ptr [rax + 20], rbx
	mov	qword ptr [rax + 28], 0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	jmp	.LBB6_3
.LBB6_1:
	xor	eax, eax
.LBB6_3:
	pop	rbx
	pop	r14
	pop	r15
	ret
.Lfunc_end6:
	.size	_xtc_alloc, .Lfunc_end6-_xtc_alloc
                                        # -- End function
	.globl	_xtc_new_u8                     # -- Begin function _xtc_new_u8
	.p2align	4
	.type	_xtc_new_u8,@function
_xtc_new_u8:                            # @_xtc_new_u8
# %bb.0:
	push	rbx
	mov	rbx, rdi
	cmp	rdi, 17
	mov	edi, 16
	cmovae	rdi, rbx
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB7_1
# %bb.2:
	cmp	rbx, 1
	adc	rbx, 0
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 1
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB7_1:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end7:
	.size	_xtc_new_u8, .Lfunc_end7-_xtc_new_u8
                                        # -- End function
	.globl	_xtc_new_i8                     # -- Begin function _xtc_new_i8
	.p2align	4
	.type	_xtc_new_i8,@function
_xtc_new_i8:                            # @_xtc_new_i8
# %bb.0:
	push	rbx
	mov	rbx, rdi
	cmp	rdi, 17
	mov	edi, 16
	cmovae	rdi, rbx
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB8_1
# %bb.2:
	cmp	rbx, 1
	adc	rbx, 0
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 1
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB8_1:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end8:
	.size	_xtc_new_i8, .Lfunc_end8-_xtc_new_i8
                                        # -- End function
	.globl	_xtc_new_u16                    # -- Begin function _xtc_new_u16
	.p2align	4
	.type	_xtc_new_u16,@function
_xtc_new_u16:                           # @_xtc_new_u16
# %bb.0:
	push	rbx
	mov	rbx, rdi
	cmp	rdi, 1
	adc	rbx, 0
	lea	rax, [rbx + rbx]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB9_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 2
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB9_1:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end9:
	.size	_xtc_new_u16, .Lfunc_end9-_xtc_new_u16
                                        # -- End function
	.globl	_xtc_new_i16                    # -- Begin function _xtc_new_i16
	.p2align	4
	.type	_xtc_new_i16,@function
_xtc_new_i16:                           # @_xtc_new_i16
# %bb.0:
	push	rbx
	mov	rbx, rdi
	cmp	rdi, 1
	adc	rbx, 0
	lea	rax, [rbx + rbx]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB10_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 2
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB10_1:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end10:
	.size	_xtc_new_i16, .Lfunc_end10-_xtc_new_i16
                                        # -- End function
	.globl	_xtc_new_u32                    # -- Begin function _xtc_new_u32
	.p2align	4
	.type	_xtc_new_u32,@function
_xtc_new_u32:                           # @_xtc_new_u32
# %bb.0:
	push	rbx
	mov	rbx, rdi
	cmp	rdi, 1
	adc	rbx, 0
	lea	rax, [4*rbx]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB11_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 4
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB11_1:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end11:
	.size	_xtc_new_u32, .Lfunc_end11-_xtc_new_u32
                                        # -- End function
	.globl	_xtc_new_i32                    # -- Begin function _xtc_new_i32
	.p2align	4
	.type	_xtc_new_i32,@function
_xtc_new_i32:                           # @_xtc_new_i32
# %bb.0:
	push	rbx
	mov	rbx, rdi
	cmp	rdi, 1
	adc	rbx, 0
	lea	rax, [4*rbx]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB12_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 4
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB12_1:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end12:
	.size	_xtc_new_i32, .Lfunc_end12-_xtc_new_i32
                                        # -- End function
	.globl	_xtc_new_pointer                # -- Begin function _xtc_new_pointer
	.p2align	4
	.type	_xtc_new_pointer,@function
_xtc_new_pointer:                       # @_xtc_new_pointer
# %bb.0:
	push	rbx
	mov	rbx, rdi
	cmp	rdi, 1
	adc	rbx, 0
	lea	rax, [8*rbx]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB13_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 8
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB13_1:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end13:
	.size	_xtc_new_pointer, .Lfunc_end13-_xtc_new_pointer
                                        # -- End function
	.globl	_xtc_new_u64                    # -- Begin function _xtc_new_u64
	.p2align	4
	.type	_xtc_new_u64,@function
_xtc_new_u64:                           # @_xtc_new_u64
# %bb.0:
	push	rbx
	mov	rbx, rdi
	cmp	rdi, 1
	adc	rbx, 0
	lea	rax, [8*rbx]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB14_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 8
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB14_1:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end14:
	.size	_xtc_new_u64, .Lfunc_end14-_xtc_new_u64
                                        # -- End function
	.globl	_xtc_new_i64                    # -- Begin function _xtc_new_i64
	.p2align	4
	.type	_xtc_new_i64,@function
_xtc_new_i64:                           # @_xtc_new_i64
# %bb.0:
	push	rbx
	mov	rbx, rdi
	cmp	rdi, 1
	adc	rbx, 0
	lea	rax, [8*rbx]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB15_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 8
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB15_1:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end15:
	.size	_xtc_new_i64, .Lfunc_end15-_xtc_new_i64
                                        # -- End function
	.globl	_xtc_new_bool                   # -- Begin function _xtc_new_bool
	.p2align	4
	.type	_xtc_new_bool,@function
_xtc_new_bool:                          # @_xtc_new_bool
# %bb.0:
	push	rbx
	mov	rbx, rdi
	cmp	rdi, 17
	mov	edi, 16
	cmovae	rdi, rbx
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB16_1
# %bb.2:
	cmp	rbx, 1
	adc	rbx, 0
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 1
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB16_1:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end16:
	.size	_xtc_new_bool, .Lfunc_end16-_xtc_new_bool
                                        # -- End function
	.globl	_xtc_new_float                  # -- Begin function _xtc_new_float
	.p2align	4
	.type	_xtc_new_float,@function
_xtc_new_float:                         # @_xtc_new_float
# %bb.0:
	push	rbx
	mov	rbx, rdi
	cmp	rdi, 1
	adc	rbx, 0
	lea	rax, [4*rbx]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB17_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 4
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB17_1:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end17:
	.size	_xtc_new_float, .Lfunc_end17-_xtc_new_float
                                        # -- End function
	.globl	_xtc_new_double                 # -- Begin function _xtc_new_double
	.p2align	4
	.type	_xtc_new_double,@function
_xtc_new_double:                        # @_xtc_new_double
# %bb.0:
	push	rbx
	mov	rbx, rdi
	cmp	rdi, 1
	adc	rbx, 0
	lea	rax, [8*rbx]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB18_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 8
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB18_1:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end18:
	.size	_xtc_new_double, .Lfunc_end18-_xtc_new_double
                                        # -- End function
	.globl	_xtc_new_string                 # -- Begin function _xtc_new_string
	.p2align	4
	.type	_xtc_new_string,@function
_xtc_new_string:                        # @_xtc_new_string
# %bb.0:
	push	rbx
	mov	rbx, rdi
	cmp	rdi, 1
	adc	rbx, 0
	lea	rax, [8*rbx]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB19_1
# %bb.2:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], 8
	mov	qword ptr [rax + 12], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 20], xmm0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	pop	rbx
	ret
.LBB19_1:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end19:
	.size	_xtc_new_string, .Lfunc_end19-_xtc_new_string
                                        # -- End function
	.globl	_xtc_count                      # -- Begin function _xtc_count
	.p2align	4
	.type	_xtc_count,@function
_xtc_count:                             # @_xtc_count
# %bb.0:
	mov	eax, dword ptr [rdi - 28]
	ret
.Lfunc_end20:
	.size	_xtc_count, .Lfunc_end20-_xtc_count
                                        # -- End function
	.globl	_xtc_dealloc                    # -- Begin function _xtc_dealloc
	.p2align	4
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
	je	.LBB21_9
# %bb.1:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB21_4
	.p2align	4
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
	mov	rax, qword ptr [rbx - 12]
	test	rax, rax
	je	.LBB21_7
# %bb.5:
	xorps	xmm0, xmm0
	.p2align	4
.LBB21_6:                               # =>This Inner Loop Header: Depth=1
	mov	rcx, qword ptr [rax - 8]
	movups	xmmword ptr [rax - 16], xmm0
	mov	qword ptr [rax], 0
	mov	rax, rcx
	test	rcx, rcx
	jne	.LBB21_6
.LBB21_7:
	mov	qword ptr [rbx - 12], 0
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB21_9
# %bb.8:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB21_9:
	mov	r15, qword ptr [rbx - 20]
	test	r15, r15
	je	.LBB21_13
# %bb.10:
	mov	r12, qword ptr [rbx - 36]
	mov	r13, qword ptr [rbx - 28]
	mov	dword ptr [rbx - 4], -2147483648
	test	r13, r13
	je	.LBB21_13
# %bb.11:
	mov	r14, rbx
	.p2align	4
.LBB21_12:                              # =>This Inner Loop Header: Depth=1
	mov	rdi, r14
	call	r15
	add	r14, r12
	dec	r13
	jne	.LBB21_12
.LBB21_13:
	mov	rax, qword ptr [rbx - 48]
	add	rbx, -48
	cmp	rax, 64
	jae	.LBB21_20
# %bb.14:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB21_17
	.p2align	4
.LBB21_15:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB21_16 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB21_17
.LBB21_16:                              #   Parent Loop BB21_15 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB21_16
	jmp	.LBB21_15
.LBB21_17:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB21_21
# %bb.18:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB21_20
# %bb.19:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB21_20:
	mov	rdi, rbx
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	jmp	free@PLT                        # TAILCALL
.LBB21_21:
	lea	rsi, [rip + xt_cache]
	mov	rdi, qword ptr [rsi + 8*rax]
	mov	qword ptr [rbx], rdi
	mov	qword ptr [rsi + 8*rax], rbx
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB21_23
# %bb.22:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB21_23:
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	ret
.Lfunc_end21:
	.size	_xtc_dealloc, .Lfunc_end21-_xtc_dealloc
                                        # -- End function
	.globl	_xtc_weak_zero_for              # -- Begin function _xtc_weak_zero_for
	.p2align	4
	.type	_xtc_weak_zero_for,@function
_xtc_weak_zero_for:                     # @_xtc_weak_zero_for
# %bb.0:
	test	rdi, rdi
	je	.LBB22_9
# %bb.1:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB22_4
	.p2align	4
.LBB22_2:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB22_3 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB22_4
.LBB22_3:                               #   Parent Loop BB22_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB22_3
	jmp	.LBB22_2
.LBB22_4:
	mov	rax, qword ptr [rdi - 12]
	test	rax, rax
	je	.LBB22_7
# %bb.5:
	xorps	xmm0, xmm0
	.p2align	4
.LBB22_6:                               # =>This Inner Loop Header: Depth=1
	mov	rcx, qword ptr [rax - 8]
	movups	xmmword ptr [rax - 16], xmm0
	mov	qword ptr [rax], 0
	mov	rax, rcx
	test	rcx, rcx
	jne	.LBB22_6
.LBB22_7:
	mov	qword ptr [rdi - 12], 0
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB22_9
# %bb.8:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB22_9:
	ret
.Lfunc_end22:
	.size	_xtc_weak_zero_for, .Lfunc_end22-_xtc_weak_zero_for
                                        # -- End function
	.globl	_xtc_weak_unregister            # -- Begin function _xtc_weak_unregister
	.p2align	4
	.type	_xtc_weak_unregister,@function
_xtc_weak_unregister:                   # @_xtc_weak_unregister
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB23_3
	.p2align	4
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
	mov	rax, qword ptr [rdi - 16]
	test	rax, rax
	je	.LBB23_8
# %bb.4:
	lea	rcx, [rdi - 16]
	cmp	qword ptr [rax], rdi
	jne	.LBB23_7
# %bb.5:
	mov	rdx, qword ptr [rdi - 8]
	mov	qword ptr [rax], rdx
	test	rdx, rdx
	je	.LBB23_7
# %bb.6:
	mov	qword ptr [rdx - 16], rax
.LBB23_7:
	xorps	xmm0, xmm0
	movups	xmmword ptr [rcx], xmm0
.LBB23_8:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB23_10
# %bb.9:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB23_10:
	ret
.Lfunc_end23:
	.size	_xtc_weak_unregister, .Lfunc_end23-_xtc_weak_unregister
                                        # -- End function
	.globl	_xt_rt_lock                     # -- Begin function _xt_rt_lock
	.p2align	4
	.type	_xt_rt_lock,@function
_xt_rt_lock:                            # @_xt_rt_lock
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB24_3
	.p2align	4
.LBB24_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB24_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB24_3
.LBB24_2:                               #   Parent Loop BB24_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB24_2
	jmp	.LBB24_1
.LBB24_3:
	ret
.Lfunc_end24:
	.size	_xt_rt_lock, .Lfunc_end24-_xt_rt_lock
                                        # -- End function
	.globl	_xt_rt_unlock                   # -- Begin function _xt_rt_unlock
	.p2align	4
	.type	_xt_rt_unlock,@function
_xt_rt_unlock:                          # @_xt_rt_unlock
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB25_2
# %bb.1:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB25_2:
	ret
.Lfunc_end25:
	.size	_xt_rt_unlock, .Lfunc_end25-_xt_rt_unlock
                                        # -- End function
	.globl	_xtc_weak_register              # -- Begin function _xtc_weak_register
	.p2align	4
	.type	_xtc_weak_register,@function
_xtc_weak_register:                     # @_xtc_weak_register
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB26_3
	.p2align	4
.LBB26_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB26_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB26_3
.LBB26_2:                               #   Parent Loop BB26_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB26_2
	jmp	.LBB26_1
.LBB26_3:
	mov	rax, qword ptr [rdi - 16]
	test	rax, rax
	je	.LBB26_8
# %bb.4:
	lea	rcx, [rdi - 16]
	cmp	qword ptr [rax], rdi
	jne	.LBB26_7
# %bb.5:
	mov	rdx, qword ptr [rdi - 8]
	mov	qword ptr [rax], rdx
	test	rdx, rdx
	je	.LBB26_7
# %bb.6:
	mov	qword ptr [rdx - 16], rax
.LBB26_7:
	xorps	xmm0, xmm0
	movups	xmmword ptr [rcx], xmm0
.LBB26_8:
	test	rsi, rsi
	je	.LBB26_13
# %bb.9:
	cmp	dword ptr [rsi - 40], 1481920322
	jne	.LBB26_13
# %bb.10:
	mov	rax, qword ptr [rsi - 12]
	add	rsi, -12
	mov	qword ptr [rdi - 16], rsi
	mov	qword ptr [rdi - 8], rax
	test	rax, rax
	je	.LBB26_12
# %bb.11:
	lea	rcx, [rdi - 8]
	mov	qword ptr [rax - 16], rcx
.LBB26_12:
	mov	qword ptr [rsi], rdi
.LBB26_13:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB26_15
# %bb.14:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB26_15:
	ret
.Lfunc_end26:
	.size	_xtc_weak_register, .Lfunc_end26-_xtc_weak_register
                                        # -- End function
	.globl	_xtc_weak_load                  # -- Begin function _xtc_weak_load
	.p2align	4
	.type	_xtc_weak_load,@function
_xtc_weak_load:                         # @_xtc_weak_load
# %bb.0:
	mov	rax, qword ptr [rdi]
	ret
.Lfunc_end27:
	.size	_xtc_weak_load, .Lfunc_end27-_xtc_weak_load
                                        # -- End function
	.globl	srandom                         # -- Begin function srandom
	.p2align	4
	.type	srandom,@function
srandom:                                # @srandom
# %bb.0:
                                        # kill: def $edi killed $edi def $rdi
	cmp	edi, 1
	adc	edi, 0
	mov	qword ptr [rip + xt_rand_state], rdi
	ret
.Lfunc_end28:
	.size	srandom, .Lfunc_end28-srandom
                                        # -- End function
	.globl	random                          # -- Begin function random
	.p2align	4
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
.Lfunc_end29:
	.size	random, .Lfunc_end29-random
                                        # -- End function
	.globl	_xt_srand                       # -- Begin function _xt_srand
	.p2align	4
	.type	_xt_srand,@function
_xt_srand:                              # @_xt_srand
# %bb.0:
                                        # kill: def $edi killed $edi def $rdi
	cmp	edi, 1
	adc	edi, 0
	mov	qword ptr [rip + xt_rand_state], rdi
	ret
.Lfunc_end30:
	.size	_xt_srand, .Lfunc_end30-_xt_srand
                                        # -- End function
	.globl	_xt_rand_u32                    # -- Begin function _xt_rand_u32
	.p2align	4
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
.Lfunc_end31:
	.size	_xt_rand_u32, .Lfunc_end31-_xt_rand_u32
                                        # -- End function
	.section	.rodata.cst4,"aM",@progbits,4
	.p2align	2, 0x0                          # -- Begin function _xt_rand_f
.LCPI32_0:
	.long	0x30000000                      # float 4.65661287E-10
.LCPI32_1:
	.long	0x3f000000                      # float 0.5
	.text
	.globl	_xt_rand_f
	.p2align	4
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
	mulss	xmm0, dword ptr [rip + .LCPI32_0]
	movss	xmm1, dword ptr [rip + .LCPI32_1] # xmm1 = [5.0E-1,0.0E+0,0.0E+0,0.0E+0]
	mulss	xmm0, xmm1
	addss	xmm0, xmm1
	ret
.Lfunc_end32:
	.size	_xt_rand_f, .Lfunc_end32-_xt_rand_f
                                        # -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          # -- Begin function _xt_rand_d
.LCPI33_0:
	.quad	0x3e00000000000000              # double 4.6566128730773926E-10
.LCPI33_1:
	.quad	0x3fe0000000000000              # double 0.5
	.text
	.globl	_xt_rand_d
	.p2align	4
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
	mulsd	xmm0, qword ptr [rip + .LCPI33_0]
	movsd	xmm1, qword ptr [rip + .LCPI33_1] # xmm1 = [5.0E-1,0.0E+0]
	mulsd	xmm0, xmm1
	addsd	xmm0, xmm1
	ret
.Lfunc_end33:
	.size	_xt_rand_d, .Lfunc_end33-_xt_rand_d
                                        # -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          # -- Begin function _xt_clk_reset
.LCPI34_0:
	.quad	0x3e112e0be826d695              # double 1.0000000000000001E-9
	.text
	.globl	_xt_clk_reset
	.p2align	4
	.type	_xt_clk_reset,@function
_xt_clk_reset:                          # @_xt_clk_reset
# %bb.0:
	sub	rsp, 24
	mov	rsi, rsp
	mov	edi, 1
	call	_sys_clock_gettime@PLT
	cvtsi2sd	xmm0, qword ptr [rsp]
	cvtsi2sd	xmm1, qword ptr [rsp + 8]
	mulsd	xmm1, qword ptr [rip + .LCPI34_0]
	addsd	xmm1, xmm0
	movsd	qword ptr [rip + xt_clk_origin], xmm1
	add	rsp, 24
	ret
.Lfunc_end34:
	.size	_xt_clk_reset, .Lfunc_end34-_xt_clk_reset
                                        # -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          # -- Begin function _xt_clk_ticks
.LCPI35_0:
	.quad	0x3e112e0be826d695              # double 1.0000000000000001E-9
.LCPI35_1:
	.quad	0x412e848000000000              # double 1.0E+6
	.text
	.globl	_xt_clk_ticks
	.p2align	4
	.type	_xt_clk_ticks,@function
_xt_clk_ticks:                          # @_xt_clk_ticks
# %bb.0:
	sub	rsp, 24
	mov	rsi, rsp
	mov	edi, 1
	call	_sys_clock_gettime@PLT
	cvtsi2sd	xmm0, qword ptr [rsp]
	cvtsi2sd	xmm1, qword ptr [rsp + 8]
	mulsd	xmm1, qword ptr [rip + .LCPI35_0]
	addsd	xmm1, xmm0
	subsd	xmm1, qword ptr [rip + xt_clk_origin]
	mulsd	xmm1, qword ptr [rip + .LCPI35_1]
	cvttsd2si	rax, xmm1
                                        # kill: def $eax killed $eax killed $rax
	add	rsp, 24
	ret
.Lfunc_end35:
	.size	_xt_clk_ticks, .Lfunc_end35-_xt_clk_ticks
                                        # -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          # -- Begin function _xt_clk_delay
.LCPI36_0:
	.quad	0x404e000000000000              # double 60
.LCPI36_1:
	.quad	0x41cdcd6500000000              # double 1.0E+9
.LCPI36_2:
	.quad	0x43e0000000000000              # double 9.2233720368547758E+18
	.text
	.globl	_xt_clk_delay
	.p2align	4
	.type	_xt_clk_delay,@function
_xt_clk_delay:                          # @_xt_clk_delay
# %bb.0:
	sub	rsp, 24
	mov	eax, edi
	cvtsi2sd	xmm0, rax
	divsd	xmm0, qword ptr [rip + .LCPI36_0]
	mulsd	xmm0, qword ptr [rip + .LCPI36_1]
	cvttsd2si	rax, xmm0
	mov	rcx, rax
	sar	rcx, 63
	subsd	xmm0, qword ptr [rip + .LCPI36_2]
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
	call	_sys_nanosleep@PLT
	add	rsp, 24
	ret
.Lfunc_end36:
	.size	_xt_clk_delay, .Lfunc_end36-_xt_clk_delay
                                        # -- End function
	.globl	_xtc_bank                       # -- Begin function _xtc_bank
	.p2align	4
	.type	_xtc_bank,@function
_xtc_bank:                              # @_xtc_bank
# %bb.0:
	cmp	dil, 1
	jbe	.LBB37_2
# %bb.1:
	xor	eax, eax
	ret
.LBB37_2:
	push	r14
	push	rbx
	push	rax
	movzx	eax, dil
	shl	eax, 11
	lea	rbx, [rip + xt_bank_regions]
	add	rbx, rax
	movzx	r14d, sil
	cmp	qword ptr [rbx + 8*r14], 0
	jne	.LBB37_7
# %bb.3:
	mov	edi, 1
	mov	esi, 12296
	call	calloc@PLT
	test	rax, rax
	je	.LBB37_4
# %bb.5:
	mov	qword ptr [rax], 64
	add	rax, 8
	jmp	.LBB37_6
.LBB37_4:
	xor	eax, eax
.LBB37_6:
	mov	qword ptr [rbx + 8*r14], rax
.LBB37_7:
	mov	rax, qword ptr [rbx + 8*r14]
	add	rsp, 8
	pop	rbx
	pop	r14
	ret
.Lfunc_end37:
	.size	_xtc_bank, .Lfunc_end37-_xtc_bank
                                        # -- End function
	.globl	_xt_threads_multi               # -- Begin function _xt_threads_multi
	.p2align	4
	.type	_xt_threads_multi,@function
_xt_threads_multi:                      # @_xt_threads_multi
# %bb.0:
	mov	eax, dword ptr [rip + _xt_threads_active]
	ret
.Lfunc_end38:
	.size	_xt_threads_multi, .Lfunc_end38-_xt_threads_multi
                                        # -- End function
	.globl	_xt_thread_create               # -- Begin function _xt_thread_create
	.p2align	4
	.type	_xt_thread_create,@function
_xt_thread_create:                      # @_xt_thread_create
# %bb.0:
	push	rbp
	push	r15
	push	r14
	push	r13
	push	r12
	push	rbx
	push	rax
	test	rdi, rdi
	je	.LBB39_74
# %bb.1:
	mov	r12, rsi
	mov	r13, rdi
	call	_xt_libc_addr@PLT
	mov	byte ptr [rax + 1], 1
	mov	byte ptr [rax + 3], 1
	mov	dword ptr [rax + 4], 1
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_3
# %bb.2:
	call	xt_reap_sweep
.LBB39_3:
	mov	dword ptr [rip + _xt_threads_active], 1
	xor	ebx, ebx
	mov	esi, 1048576
	mov	edx, 3
	mov	ecx, 34
	xor	edi, edi
	mov	r8, -1
	xor	r9d, r9d
	call	_sys_mmap@PLT
	mov	r14, rax
	add	rax, 4095
	cmp	rax, 4096
	jb	.LBB39_75
# %bb.4:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_7
	.p2align	4
.LBB39_5:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB39_6 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB39_7
.LBB39_6:                               #   Parent Loop BB39_5 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB39_6
	jmp	.LBB39_5
.LBB39_7:
	mov	rax, qword ptr [rip + xt_cache+16]
	test	rax, rax
	je	.LBB39_10
# %bb.8:
	mov	rcx, qword ptr [rax]
	dec	dword ptr [rip + xt_cache_n+8]
	mov	qword ptr [rip + xt_cache+16], rcx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_13
# %bb.9:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB39_13
.LBB39_10:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_12
# %bb.11:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB39_12:
	mov	edi, 48
	call	malloc@PLT
	test	rax, rax
	je	.LBB39_52
.LBB39_13:
	mov	qword ptr [rax], 2
	lea	rbx, [rax + 8]
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 8], xmm0
	movups	xmmword ptr [rax + 24], xmm0
	mov	qword ptr [rax + 40], 0
	test	rbx, rbx
	je	.LBB39_74
.LBB39_14:
	mov	qword ptr [rbx + 8], r14
	mov	qword ptr [rbx + 16], 1048576
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_17
	.p2align	4
.LBB39_15:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB39_16 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB39_17
.LBB39_16:                              #   Parent Loop BB39_15 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB39_16
	jmp	.LBB39_15
.LBB39_17:
	mov	r15, qword ptr [rip + xt_cache+8]
	test	r15, r15
	je	.LBB39_20
# %bb.18:
	mov	rax, qword ptr [r15]
	dec	dword ptr [rip + xt_cache_n+4]
	mov	qword ptr [rip + xt_cache+8], rax
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_23
# %bb.19:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB39_23
.LBB39_20:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_22
# %bb.21:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB39_22:
	mov	edi, 32
	call	malloc@PLT
	mov	r15, rax
	test	rax, rax
	je	.LBB39_53
.LBB39_23:
	mov	qword ptr [r15], 1
	xorps	xmm0, xmm0
	movups	xmmword ptr [r15 + 8], xmm0
	add	r15, 8
	test	r15, r15
	je	.LBB39_74
.LBB39_24:
	mov	qword ptr [r15], r13
	mov	qword ptr [r15 + 8], r12
	mov	edi, 1
	mov	esi, 1792
	call	calloc@PLT
	test	rax, rax
	je	.LBB39_35
# %bb.25:
	mov	r13, rax
	mov	qword ptr [rax], 64
	add	r13, 8
	test	r13, r13
	je	.LBB39_36
.LBB39_26:
	lea	r12, [r13 + 256]
	call	_xt_tls_hdr_addr@PLT
	mov	rcx, qword ptr [rax]
	test	rcx, rcx
	je	.LBB39_29
# %bb.27:
	mov	rdx, r12
	sub	rdx, rcx
	xor	esi, esi
	.p2align	4
.LBB39_28:                              # =>This Inner Loop Header: Depth=1
	movzx	edi, byte ptr [rax + rsi + 8]
	mov	byte ptr [rdx + rsi], dil
	inc	rsi
	cmp	rcx, rsi
	jne	.LBB39_28
.LBB39_29:
	lea	rbp, [r13 + 760]
	call	_xt_libc_addr@PLT
	add	rax, 56
	mov	qword ptr [r13 + 424], rax
	mov	qword ptr [r13 + 384], rbp
	test	r12, r12
	je	.LBB39_37
.LBB39_30:
	mov	qword ptr [r12], r12
	mov	qword ptr [rbx + 32], r12
	add	r14, 1048576
	and	r14, -16
	lea	rcx, [rip + xt_thread_entry]
	mov	esi, 4001536
	mov	rdi, r14
	mov	rdx, rbx
	mov	r8, r15
	mov	r9, r12
	call	_sys_clone_thread@PLT
	test	rax, rax
	jns	.LBB39_75
# %bb.31:
	mov	rax, qword ptr [r15 - 8]
	add	r15, -8
	cmp	rax, 64
	jae	.LBB39_57
# %bb.32:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_54
.LBB39_33:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB39_34 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB39_54
.LBB39_34:                              #   Parent Loop BB39_33 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB39_34
	jmp	.LBB39_33
.LBB39_35:
	xor	r13d, r13d
	test	r13, r13
	jne	.LBB39_26
.LBB39_36:
	xor	r12d, r12d
	test	r12, r12
	jne	.LBB39_30
.LBB39_37:
	mov	rax, qword ptr [r15 - 8]
	add	r15, -8
	cmp	rax, 64
	jae	.LBB39_44
# %bb.38:
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB39_40
	jmp	.LBB39_41
	.p2align	4
.LBB39_39:                              #   Parent Loop BB39_40 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB39_39
.LBB39_40:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB39_39 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB39_39
.LBB39_41:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB39_76
# %bb.42:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_44
# %bb.43:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB39_44:
	mov	rdi, r15
	call	free@PLT
.LBB39_45:
	mov	rax, qword ptr [rbx - 8]
	add	rbx, -8
	cmp	rax, 64
	jae	.LBB39_73
# %bb.46:
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB39_48
	jmp	.LBB39_49
	.p2align	4
.LBB39_47:                              #   Parent Loop BB39_48 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB39_47
.LBB39_48:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB39_47 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB39_47
	jmp	.LBB39_49
.LBB39_52:
	xor	ebx, ebx
	test	rbx, rbx
	jne	.LBB39_14
	jmp	.LBB39_74
.LBB39_53:
	xor	r15d, r15d
	test	r15, r15
	jne	.LBB39_24
	jmp	.LBB39_74
.LBB39_54:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB39_78
# %bb.55:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_57
# %bb.56:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB39_57:
	mov	rdi, r15
	call	free@PLT
.LBB39_58:
	mov	rax, qword ptr [r12 - 264]
	add	r12, -264
	cmp	rax, 64
	jae	.LBB39_65
# %bb.59:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_62
.LBB39_60:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB39_61 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB39_62
.LBB39_61:                              #   Parent Loop BB39_60 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB39_61
	jmp	.LBB39_60
.LBB39_62:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB39_80
# %bb.63:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_65
# %bb.64:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB39_65:
	mov	rdi, r12
	call	free@PLT
.LBB39_66:
	mov	rax, qword ptr [rbx - 8]
	add	rbx, -8
	cmp	rax, 64
	jae	.LBB39_73
# %bb.67:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_49
.LBB39_68:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB39_69 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB39_49
.LBB39_69:                              #   Parent Loop BB39_68 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB39_69
	jmp	.LBB39_68
.LBB39_49:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB39_50
# %bb.71:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_73
# %bb.72:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB39_73:
	mov	rdi, rbx
	call	free@PLT
.LBB39_74:
	xor	ebx, ebx
.LBB39_75:
	mov	rax, rbx
	add	rsp, 8
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	pop	rbp
	ret
.LBB39_50:
	lea	rsi, [rip + xt_cache]
	mov	rdi, qword ptr [rsi + 8*rax]
	mov	qword ptr [rbx], rdi
	mov	qword ptr [rsi + 8*rax], rbx
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_74
# %bb.51:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB39_74
.LBB39_76:
	lea	rsi, [rip + xt_cache]
	mov	rdi, qword ptr [rsi + 8*rax]
	mov	qword ptr [r15], rdi
	mov	qword ptr [rsi + 8*rax], r15
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_45
# %bb.77:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB39_45
.LBB39_78:
	lea	rsi, [rip + xt_cache]
	mov	rdi, qword ptr [rsi + 8*rax]
	mov	qword ptr [r15], rdi
	mov	qword ptr [rsi + 8*rax], r15
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_58
# %bb.79:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB39_58
.LBB39_80:
	lea	rsi, [rip + xt_cache]
	mov	rdi, qword ptr [rsi + 8*rax]
	mov	qword ptr [r12], rdi
	mov	qword ptr [rsi + 8*rax], r12
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB39_66
# %bb.81:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB39_66
.Lfunc_end39:
	.size	_xt_thread_create, .Lfunc_end39-_xt_thread_create
                                        # -- End function
	.p2align	4                               # -- Begin function xt_reap_sweep
	.type	xt_reap_sweep,@function
xt_reap_sweep:                          # @xt_reap_sweep
# %bb.0:
	.p2align	4
.LBB40_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB40_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_reap_spin], eax
	test	eax, eax
	je	.LBB40_3
.LBB40_2:                               #   Parent Loop BB40_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_reap_spin]
	test	eax, eax
	jne	.LBB40_2
	jmp	.LBB40_1
.LBB40_3:
	push	r15
	push	r14
	push	r12
	push	rbx
	push	rax
	mov	rbx, qword ptr [rip + xt_reap_head]
	test	rbx, rbx
	je	.LBB40_32
# %bb.4:
	lea	r12, [rip + xt_reap_head]
	lea	r14, [rip + xt_cache_n]
	lea	r15, [rip + xt_cache]
	jmp	.LBB40_7
	.p2align	4
.LBB40_5:                               #   in Loop: Header=BB40_7 Depth=1
	add	rbx, 24
	mov	r12, rbx
.LBB40_6:                               #   in Loop: Header=BB40_7 Depth=1
	mov	rbx, qword ptr [r12]
	test	rbx, rbx
	je	.LBB40_32
.LBB40_7:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB40_14 Depth 2
                                        #       Child Loop BB40_15 Depth 3
                                        #     Child Loop BB40_24 Depth 2
                                        #       Child Loop BB40_25 Depth 3
	mov	eax, dword ptr [rbx]
	test	eax, eax
	jne	.LBB40_5
# %bb.8:                                #   in Loop: Header=BB40_7 Depth=1
	mov	rax, qword ptr [rbx + 24]
	mov	qword ptr [r12], rax
	mov	rdi, qword ptr [rbx + 8]
	test	rdi, rdi
	je	.LBB40_10
# %bb.9:                                #   in Loop: Header=BB40_7 Depth=1
	mov	rsi, qword ptr [rbx + 16]
	call	_sys_munmap@PLT
.LBB40_10:                              #   in Loop: Header=BB40_7 Depth=1
	mov	rdi, qword ptr [rbx + 32]
	test	rdi, rdi
	je	.LBB40_22
# %bb.11:                               #   in Loop: Header=BB40_7 Depth=1
	mov	rax, qword ptr [rdi - 264]
	add	rdi, -264
	cmp	rax, 64
	jae	.LBB40_12
# %bb.13:                               #   in Loop: Header=BB40_7 Depth=1
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB40_16
	.p2align	4
.LBB40_14:                              #   Parent Loop BB40_7 Depth=1
                                        # =>  This Loop Header: Depth=2
                                        #       Child Loop BB40_15 Depth 3
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB40_16
.LBB40_15:                              #   Parent Loop BB40_7 Depth=1
                                        #     Parent Loop BB40_14 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB40_15
	jmp	.LBB40_14
.LBB40_16:                              #   in Loop: Header=BB40_7 Depth=1
	mov	ecx, dword ptr [r14 + 4*rax]
	cmp	ecx, 64
	jb	.LBB40_20
# %bb.17:                               #   in Loop: Header=BB40_7 Depth=1
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB40_12
# %bb.18:                               #   in Loop: Header=BB40_7 Depth=1
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB40_12:                              #   in Loop: Header=BB40_7 Depth=1
	call	free@PLT
.LBB40_22:                              #   in Loop: Header=BB40_7 Depth=1
	mov	rax, qword ptr [rbx - 8]
	add	rbx, -8
	cmp	rax, 64
	jae	.LBB40_29
# %bb.23:                               #   in Loop: Header=BB40_7 Depth=1
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB40_26
	.p2align	4
.LBB40_24:                              #   Parent Loop BB40_7 Depth=1
                                        # =>  This Loop Header: Depth=2
                                        #       Child Loop BB40_25 Depth 3
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB40_26
.LBB40_25:                              #   Parent Loop BB40_7 Depth=1
                                        #     Parent Loop BB40_24 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB40_25
	jmp	.LBB40_24
.LBB40_26:                              #   in Loop: Header=BB40_7 Depth=1
	mov	ecx, dword ptr [r14 + 4*rax]
	cmp	ecx, 64
	jb	.LBB40_30
# %bb.27:                               #   in Loop: Header=BB40_7 Depth=1
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB40_29
# %bb.28:                               #   in Loop: Header=BB40_7 Depth=1
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB40_29:                              #   in Loop: Header=BB40_7 Depth=1
	mov	rdi, rbx
	call	free@PLT
	jmp	.LBB40_6
.LBB40_30:                              #   in Loop: Header=BB40_7 Depth=1
	mov	rdx, qword ptr [r15 + 8*rax]
	mov	qword ptr [rbx], rdx
	mov	qword ptr [r15 + 8*rax], rbx
	inc	ecx
	mov	dword ptr [r14 + 4*rax], ecx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB40_6
# %bb.31:                               #   in Loop: Header=BB40_7 Depth=1
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB40_6
.LBB40_20:                              #   in Loop: Header=BB40_7 Depth=1
	mov	rdx, qword ptr [r15 + 8*rax]
	mov	qword ptr [rdi], rdx
	mov	qword ptr [r15 + 8*rax], rdi
	inc	ecx
	mov	dword ptr [r14 + 4*rax], ecx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB40_22
# %bb.21:                               #   in Loop: Header=BB40_7 Depth=1
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB40_22
.LBB40_32:
	mov	dword ptr [rip + xt_reap_spin], 0
	add	rsp, 8
	pop	rbx
	pop	r12
	pop	r14
	pop	r15
	ret
.Lfunc_end40:
	.size	xt_reap_sweep, .Lfunc_end40-xt_reap_sweep
                                        # -- End function
	.p2align	4                               # -- Begin function xt_thread_entry
	.type	xt_thread_entry,@function
xt_thread_entry:                        # @xt_thread_entry
# %bb.0:
	push	r14
	push	rbx
	push	rax
	mov	rax, qword ptr [rdi - 8]
	mov	r9, qword ptr [rdi]
	mov	rbx, qword ptr [rdi + 8]
	add	rdi, -8
	cmp	rax, 64
	jb	.LBB41_2
# %bb.1:
	mov	r14, r9
	jmp	.LBB41_8
.LBB41_2:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB41_5
	.p2align	4
.LBB41_3:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB41_4 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB41_5
.LBB41_4:                               #   Parent Loop BB41_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB41_4
	jmp	.LBB41_3
.LBB41_5:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB41_9
# %bb.6:
	mov	r14, r9
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB41_8
# %bb.7:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB41_8:
	call	free@PLT
	mov	r9, r14
.LBB41_11:
	test	r9, r9
	je	.LBB41_12
# %bb.13:
	mov	rdi, rbx
	add	rsp, 8
	pop	rbx
	pop	r14
	jmp	r9                              # TAILCALL
.LBB41_12:
	add	rsp, 8
	pop	rbx
	pop	r14
	ret
.LBB41_9:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB41_11
# %bb.10:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB41_11
.Lfunc_end41:
	.size	xt_thread_entry, .Lfunc_end41-xt_thread_entry
                                        # -- End function
	.globl	_xt_thread_join                 # -- Begin function _xt_thread_join
	.p2align	4
	.type	_xt_thread_join,@function
_xt_thread_join:                        # @_xt_thread_join
# %bb.0:
	test	rdi, rdi
	je	.LBB42_9
# %bb.1:
	push	rbx
	mov	rbx, rdi
	.p2align	4
.LBB42_2:                               # =>This Inner Loop Header: Depth=1
	mov	eax, dword ptr [rbx]
	test	eax, eax
	je	.LBB42_4
# %bb.3:                                #   in Loop: Header=BB42_2 Depth=1
	movsxd	rdx, eax
	mov	rdi, rbx
	xor	esi, esi
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	call	_sys_futex@PLT
	jmp	.LBB42_2
.LBB42_4:
	mov	rdi, qword ptr [rbx + 8]
	test	rdi, rdi
	je	.LBB42_6
# %bb.5:
	mov	rsi, qword ptr [rbx + 16]
	call	_sys_munmap@PLT
.LBB42_6:
	mov	rdi, qword ptr [rbx + 32]
	test	rdi, rdi
	je	.LBB42_19
# %bb.7:
	mov	rax, qword ptr [rdi - 264]
	add	rdi, -264
	cmp	rax, 64
	jae	.LBB42_8
# %bb.10:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB42_13
	.p2align	4
.LBB42_11:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB42_12 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB42_13
.LBB42_12:                              #   Parent Loop BB42_11 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB42_12
	jmp	.LBB42_11
.LBB42_9:
	mov	eax, -1
	ret
.LBB42_13:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB42_17
# %bb.14:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB42_8
# %bb.15:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB42_8:
	call	free@PLT
.LBB42_19:
	mov	rax, qword ptr [rbx - 8]
	add	rbx, -8
	cmp	rax, 64
	jae	.LBB42_26
# %bb.20:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB42_23
	.p2align	4
.LBB42_21:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB42_22 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB42_23
.LBB42_22:                              #   Parent Loop BB42_21 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB42_22
	jmp	.LBB42_21
.LBB42_23:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB42_27
# %bb.24:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB42_26
# %bb.25:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB42_26:
	mov	rdi, rbx
	call	free@PLT
	xor	eax, eax
	pop	rbx
	ret
.LBB42_27:
	lea	rsi, [rip + xt_cache]
	mov	rdi, qword ptr [rsi + 8*rax]
	mov	qword ptr [rbx], rdi
	mov	qword ptr [rsi + 8*rax], rbx
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	xor	eax, eax
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB42_29
# %bb.28:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB42_29:
	pop	rbx
	ret
.LBB42_17:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB42_19
# %bb.18:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB42_19
.Lfunc_end42:
	.size	_xt_thread_join, .Lfunc_end42-_xt_thread_join
                                        # -- End function
	.globl	_xt_thread_detach               # -- Begin function _xt_thread_detach
	.p2align	4
	.type	_xt_thread_detach,@function
_xt_thread_detach:                      # @_xt_thread_detach
# %bb.0:
	test	rdi, rdi
	je	.LBB43_25
# %bb.1:
	mov	eax, dword ptr [rdi]
	test	eax, eax
	je	.LBB43_2
	.p2align	4
.LBB43_26:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB43_27 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_reap_spin], eax
	test	eax, eax
	je	.LBB43_28
.LBB43_27:                              #   Parent Loop BB43_26 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_reap_spin]
	test	eax, eax
	jne	.LBB43_27
	jmp	.LBB43_26
.LBB43_28:
	mov	rax, qword ptr [rip + xt_reap_head]
	mov	qword ptr [rdi + 24], rax
	mov	qword ptr [rip + xt_reap_head], rdi
	mov	dword ptr [rip + xt_reap_spin], 0
	jmp	xt_reap_sweep                   # TAILCALL
.LBB43_2:
	push	rbx
	mov	rax, qword ptr [rdi + 8]
	test	rax, rax
	je	.LBB43_4
# %bb.3:
	mov	rsi, qword ptr [rdi + 16]
	mov	rbx, rdi
	mov	rdi, rax
	call	_sys_munmap@PLT
	mov	rdi, rbx
.LBB43_4:
	mov	rax, qword ptr [rdi + 32]
	test	rax, rax
	je	.LBB43_16
# %bb.5:
	mov	rcx, qword ptr [rax - 264]
	add	rax, -264
	cmp	rcx, 64
	jb	.LBB43_7
# %bb.6:
	mov	rbx, rdi
	jmp	.LBB43_13
.LBB43_7:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB43_10
	.p2align	4
.LBB43_8:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB43_9 Depth 2
	mov	edx, 1
	xchg	dword ptr [rip + xt_alloc_spin], edx
	test	edx, edx
	je	.LBB43_10
.LBB43_9:                               #   Parent Loop BB43_8 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	edx, dword ptr [rip + xt_alloc_spin]
	test	edx, edx
	jne	.LBB43_9
	jmp	.LBB43_8
.LBB43_10:
	lea	rdx, [rip + xt_cache_n]
	mov	esi, dword ptr [rdx + 4*rcx]
	cmp	esi, 64
	jb	.LBB43_14
# %bb.11:
	mov	rbx, rdi
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB43_13
# %bb.12:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB43_13:
	mov	rdi, rax
	call	free@PLT
	mov	rdi, rbx
.LBB43_16:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	pop	rbx
	jae	free@PLT                        # TAILCALL
# %bb.17:
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB43_18
	jmp	.LBB43_20
	.p2align	4
.LBB43_19:                              #   Parent Loop BB43_18 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB43_19
.LBB43_18:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB43_19 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB43_19
.LBB43_20:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB43_23
# %bb.21:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	free@PLT                        # TAILCALL
# %bb.22:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	free@PLT                        # TAILCALL
.LBB43_23:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB43_25
# %bb.24:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB43_25:
	ret
.LBB43_14:
	lea	r8, [rip + xt_cache]
	mov	r9, qword ptr [r8 + 8*rcx]
	mov	qword ptr [rax], r9
	mov	qword ptr [r8 + 8*rcx], rax
	inc	esi
	mov	dword ptr [rdx + 4*rcx], esi
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB43_16
# %bb.15:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB43_16
.Lfunc_end43:
	.size	_xt_thread_detach, .Lfunc_end43-_xt_thread_detach
                                        # -- End function
	.globl	_xt_thread_yield                # -- Begin function _xt_thread_yield
	.p2align	4
	.type	_xt_thread_yield,@function
_xt_thread_yield:                       # @_xt_thread_yield
# %bb.0:
	jmp	_sys_sched_yield@PLT            # TAILCALL
.Lfunc_end44:
	.size	_xt_thread_yield, .Lfunc_end44-_xt_thread_yield
                                        # -- End function
	.globl	_xt_thread_sleep_ms             # -- Begin function _xt_thread_sleep_ms
	.p2align	4
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
	call	_sys_nanosleep@PLT
	add	rsp, 24
	ret
.Lfunc_end45:
	.size	_xt_thread_sleep_ms, .Lfunc_end45-_xt_thread_sleep_ms
                                        # -- End function
	.globl	_xt_thread_self_id              # -- Begin function _xt_thread_self_id
	.p2align	4
	.type	_xt_thread_self_id,@function
_xt_thread_self_id:                     # @_xt_thread_self_id
# %bb.0:
	jmp	_sys_gettid@PLT                 # TAILCALL
.Lfunc_end46:
	.size	_xt_thread_self_id, .Lfunc_end46-_xt_thread_self_id
                                        # -- End function
	.globl	_xt_thread_cpu_count            # -- Begin function _xt_thread_cpu_count
	.p2align	4
	.type	_xt_thread_cpu_count,@function
_xt_thread_cpu_count:                   # @_xt_thread_cpu_count
# %bb.0:
	sub	rsp, 136
	xorps	xmm0, xmm0
	movaps	xmmword ptr [rsp + 112], xmm0
	movaps	xmmword ptr [rsp + 96], xmm0
	movaps	xmmword ptr [rsp + 80], xmm0
	movaps	xmmword ptr [rsp + 64], xmm0
	movaps	xmmword ptr [rsp + 48], xmm0
	movaps	xmmword ptr [rsp + 32], xmm0
	movaps	xmmword ptr [rsp + 16], xmm0
	movaps	xmmword ptr [rsp], xmm0
	mov	rdx, rsp
	mov	esi, 128
	xor	edi, edi
	call	_sys_sched_getaffinity@PLT
	mov	rcx, rax
	mov	eax, 1
	test	rcx, rcx
	jle	.LBB47_7
# %bb.1:
	shr	rcx, 3
	je	.LBB47_7
# %bb.2:
	cmp	rcx, 16
	mov	eax, 16
	cmovb	rax, rcx
	xor	ecx, ecx
	xor	edx, edx
	.p2align	4
.LBB47_3:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB47_4 Depth 2
	mov	rsi, qword ptr [rsp + 8*rdx]
	xor	edi, edi
	.p2align	4
.LBB47_4:                               #   Parent Loop BB47_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	bt	rsi, rdi
	adc	ecx, 0
	inc	rdi
	cmp	rdi, 64
	jne	.LBB47_4
# %bb.5:                                #   in Loop: Header=BB47_3 Depth=1
	inc	rdx
	cmp	rdx, rax
	jne	.LBB47_3
# %bb.6:
	cmp	ecx, 2
	mov	eax, 1
	cmovge	eax, ecx
.LBB47_7:
	add	rsp, 136
	ret
.Lfunc_end47:
	.size	_xt_thread_cpu_count, .Lfunc_end47-_xt_thread_cpu_count
                                        # -- End function
	.globl	_xt_mutex_new                   # -- Begin function _xt_mutex_new
	.p2align	4
	.type	_xt_mutex_new,@function
_xt_mutex_new:                          # @_xt_mutex_new
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB48_3
	.p2align	4
.LBB48_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB48_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB48_3
.LBB48_2:                               #   Parent Loop BB48_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB48_2
	jmp	.LBB48_1
.LBB48_3:
	push	rax
	mov	rax, qword ptr [rip + xt_cache]
	test	rax, rax
	je	.LBB48_7
# %bb.4:
	mov	rcx, qword ptr [rax]
	dec	dword ptr [rip + xt_cache_n]
	mov	qword ptr [rip + xt_cache], rcx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB48_6
# %bb.5:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB48_6
.LBB48_7:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB48_9
# %bb.8:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB48_9:
	mov	edi, 16
	call	malloc@PLT
	test	rax, rax
	je	.LBB48_10
.LBB48_6:
	mov	qword ptr [rax], 0
	mov	dword ptr [rax + 8], 0
	add	rax, 8
	pop	rcx
	ret
.LBB48_10:
	xor	eax, eax
	pop	rcx
	ret
.Lfunc_end48:
	.size	_xt_mutex_new, .Lfunc_end48-_xt_mutex_new
                                        # -- End function
	.globl	_xt_mutex_free                  # -- Begin function _xt_mutex_free
	.p2align	4
	.type	_xt_mutex_free,@function
_xt_mutex_free:                         # @_xt_mutex_free
# %bb.0:
	test	rdi, rdi
	je	.LBB49_10
# %bb.1:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	free@PLT                        # TAILCALL
# %bb.2:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB49_5
	.p2align	4
.LBB49_3:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB49_4 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB49_5
.LBB49_4:                               #   Parent Loop BB49_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB49_4
	jmp	.LBB49_3
.LBB49_5:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB49_8
# %bb.6:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	free@PLT                        # TAILCALL
# %bb.7:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	free@PLT                        # TAILCALL
.LBB49_8:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB49_10
# %bb.9:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB49_10:
	ret
.Lfunc_end49:
	.size	_xt_mutex_free, .Lfunc_end49-_xt_mutex_free
                                        # -- End function
	.globl	_xt_mutex_lock                  # -- Begin function _xt_mutex_lock
	.p2align	4
	.type	_xt_mutex_lock,@function
_xt_mutex_lock:                         # @_xt_mutex_lock
# %bb.0:
	test	rdi, rdi
	je	.LBB50_6
# %bb.1:
	push	rbx
	mov	rbx, rdi
	mov	ecx, 1
	xor	eax, eax
	lock		cmpxchg	dword ptr [rdi], ecx
	je	.LBB50_5
# %bb.2:
	cmp	eax, 2
	jne	.LBB50_4
.LBB50_3:
	mov	edx, 2
	mov	rdi, rbx
	xor	esi, esi
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	call	_sys_futex@PLT
.LBB50_4:
	mov	eax, 2
	xchg	dword ptr [rbx], eax
	test	eax, eax
	jne	.LBB50_3
.LBB50_5:
	pop	rbx
.LBB50_6:
	ret
.Lfunc_end50:
	.size	_xt_mutex_lock, .Lfunc_end50-_xt_mutex_lock
                                        # -- End function
	.globl	_xt_mutex_unlock                # -- Begin function _xt_mutex_unlock
	.p2align	4
	.type	_xt_mutex_unlock,@function
_xt_mutex_unlock:                       # @_xt_mutex_unlock
# %bb.0:
	test	rdi, rdi
	je	.LBB51_2
# %bb.1:
	lock		dec	dword ptr [rdi]
	jne	.LBB51_3
.LBB51_2:
	ret
.LBB51_3:
	mov	dword ptr [rdi], 0
	mov	esi, 1
	mov	edx, 1
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	jmp	_sys_futex@PLT                  # TAILCALL
.Lfunc_end51:
	.size	_xt_mutex_unlock, .Lfunc_end51-_xt_mutex_unlock
                                        # -- End function
	.globl	_xt_mutex_trylock               # -- Begin function _xt_mutex_trylock
	.p2align	4
	.type	_xt_mutex_trylock,@function
_xt_mutex_trylock:                      # @_xt_mutex_trylock
# %bb.0:
	test	rdi, rdi
	je	.LBB52_1
# %bb.2:
	mov	ecx, 1
	xor	eax, eax
	lock		cmpxchg	dword ptr [rdi], ecx
	mov	eax, 0
	sete	al
	ret
.LBB52_1:
	xor	eax, eax
	ret
.Lfunc_end52:
	.size	_xt_mutex_trylock, .Lfunc_end52-_xt_mutex_trylock
                                        # -- End function
	.globl	_xt_cond_new                    # -- Begin function _xt_cond_new
	.p2align	4
	.type	_xt_cond_new,@function
_xt_cond_new:                           # @_xt_cond_new
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB53_3
	.p2align	4
.LBB53_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB53_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB53_3
.LBB53_2:                               #   Parent Loop BB53_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB53_2
	jmp	.LBB53_1
.LBB53_3:
	push	rax
	mov	rax, qword ptr [rip + xt_cache]
	test	rax, rax
	je	.LBB53_7
# %bb.4:
	mov	rcx, qword ptr [rax]
	dec	dword ptr [rip + xt_cache_n]
	mov	qword ptr [rip + xt_cache], rcx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB53_6
# %bb.5:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB53_6
.LBB53_7:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB53_9
# %bb.8:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB53_9:
	mov	edi, 16
	call	malloc@PLT
	test	rax, rax
	je	.LBB53_10
.LBB53_6:
	mov	qword ptr [rax], 0
	mov	dword ptr [rax + 8], 0
	add	rax, 8
	pop	rcx
	ret
.LBB53_10:
	xor	eax, eax
	pop	rcx
	ret
.Lfunc_end53:
	.size	_xt_cond_new, .Lfunc_end53-_xt_cond_new
                                        # -- End function
	.globl	_xt_cond_free                   # -- Begin function _xt_cond_free
	.p2align	4
	.type	_xt_cond_free,@function
_xt_cond_free:                          # @_xt_cond_free
# %bb.0:
	test	rdi, rdi
	je	.LBB54_10
# %bb.1:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	free@PLT                        # TAILCALL
# %bb.2:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB54_5
	.p2align	4
.LBB54_3:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB54_4 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB54_5
.LBB54_4:                               #   Parent Loop BB54_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB54_4
	jmp	.LBB54_3
.LBB54_5:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB54_8
# %bb.6:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	free@PLT                        # TAILCALL
# %bb.7:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	free@PLT                        # TAILCALL
.LBB54_8:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB54_10
# %bb.9:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB54_10:
	ret
.Lfunc_end54:
	.size	_xt_cond_free, .Lfunc_end54-_xt_cond_free
                                        # -- End function
	.globl	_xt_cond_wait                   # -- Begin function _xt_cond_wait
	.p2align	4
	.type	_xt_cond_wait,@function
_xt_cond_wait:                          # @_xt_cond_wait
# %bb.0:
	test	rdi, rdi
	sete	al
	test	rsi, rsi
	sete	cl
	or	cl, al
	jne	.LBB55_8
# %bb.1:
	push	r15
	push	r14
	push	rbx
	mov	rbx, rsi
	mov	eax, dword ptr [rdi]
	movsxd	r14, eax
	lock		dec	dword ptr [rsi]
	je	.LBB55_3
# %bb.2:
	mov	dword ptr [rbx], 0
	mov	esi, 1
	mov	edx, 1
	mov	r15, rdi
	mov	rdi, rbx
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	call	_sys_futex@PLT
	mov	rdi, r15
.LBB55_3:
	xor	esi, esi
	mov	rdx, r14
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	call	_sys_futex@PLT
	mov	ecx, 1
	xor	eax, eax
	lock		cmpxchg	dword ptr [rbx], ecx
	je	.LBB55_7
# %bb.4:
	cmp	eax, 2
	jne	.LBB55_6
.LBB55_5:
	mov	edx, 2
	mov	rdi, rbx
	xor	esi, esi
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	call	_sys_futex@PLT
.LBB55_6:
	mov	eax, 2
	xchg	dword ptr [rbx], eax
	test	eax, eax
	jne	.LBB55_5
.LBB55_7:
	pop	rbx
	pop	r14
	pop	r15
.LBB55_8:
	ret
.Lfunc_end55:
	.size	_xt_cond_wait, .Lfunc_end55-_xt_cond_wait
                                        # -- End function
	.globl	_xt_cond_signal                 # -- Begin function _xt_cond_signal
	.p2align	4
	.type	_xt_cond_signal,@function
_xt_cond_signal:                        # @_xt_cond_signal
# %bb.0:
	test	rdi, rdi
	je	.LBB56_1
# %bb.2:
	lock		inc	dword ptr [rdi]
	mov	esi, 1
	mov	edx, 1
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	jmp	_sys_futex@PLT                  # TAILCALL
.LBB56_1:
	ret
.Lfunc_end56:
	.size	_xt_cond_signal, .Lfunc_end56-_xt_cond_signal
                                        # -- End function
	.globl	_xt_cond_broadcast              # -- Begin function _xt_cond_broadcast
	.p2align	4
	.type	_xt_cond_broadcast,@function
_xt_cond_broadcast:                     # @_xt_cond_broadcast
# %bb.0:
	test	rdi, rdi
	je	.LBB57_1
# %bb.2:
	lock		inc	dword ptr [rdi]
	mov	esi, 1
	mov	edx, 2147483647
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	jmp	_sys_futex@PLT                  # TAILCALL
.LBB57_1:
	ret
.Lfunc_end57:
	.size	_xt_cond_broadcast, .Lfunc_end57-_xt_cond_broadcast
                                        # -- End function
	.globl	_xt_sem_new                     # -- Begin function _xt_sem_new
	.p2align	4
	.type	_xt_sem_new,@function
_xt_sem_new:                            # @_xt_sem_new
# %bb.0:
	push	rbx
	mov	ebx, edi
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB58_3
	.p2align	4
.LBB58_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB58_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB58_3
.LBB58_2:                               #   Parent Loop BB58_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB58_2
	jmp	.LBB58_1
.LBB58_3:
	mov	rax, qword ptr [rip + xt_cache]
	test	rax, rax
	je	.LBB58_7
# %bb.4:
	mov	rcx, qword ptr [rax]
	dec	dword ptr [rip + xt_cache_n]
	mov	qword ptr [rip + xt_cache], rcx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB58_6
# %bb.5:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB58_6
.LBB58_7:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB58_9
# %bb.8:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB58_9:
	mov	edi, 16
	call	malloc@PLT
	test	rax, rax
	je	.LBB58_10
.LBB58_6:
	mov	qword ptr [rax], 0
	mov	dword ptr [rax + 8], 0
	add	rax, 8
	test	rax, rax
	je	.LBB58_13
.LBB58_12:
	xor	ecx, ecx
	test	ebx, ebx
	cmovg	ecx, ebx
	mov	dword ptr [rax], ecx
.LBB58_13:
	pop	rbx
	ret
.LBB58_10:
	xor	eax, eax
	test	rax, rax
	jne	.LBB58_12
	jmp	.LBB58_13
.Lfunc_end58:
	.size	_xt_sem_new, .Lfunc_end58-_xt_sem_new
                                        # -- End function
	.globl	_xt_sem_free                    # -- Begin function _xt_sem_free
	.p2align	4
	.type	_xt_sem_free,@function
_xt_sem_free:                           # @_xt_sem_free
# %bb.0:
	test	rdi, rdi
	je	.LBB59_10
# %bb.1:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	free@PLT                        # TAILCALL
# %bb.2:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB59_5
	.p2align	4
.LBB59_3:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB59_4 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB59_5
.LBB59_4:                               #   Parent Loop BB59_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB59_4
	jmp	.LBB59_3
.LBB59_5:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB59_8
# %bb.6:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	free@PLT                        # TAILCALL
# %bb.7:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	free@PLT                        # TAILCALL
.LBB59_8:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB59_10
# %bb.9:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB59_10:
	ret
.Lfunc_end59:
	.size	_xt_sem_free, .Lfunc_end59-_xt_sem_free
                                        # -- End function
	.globl	_xt_sem_wait                    # -- Begin function _xt_sem_wait
	.p2align	4
	.type	_xt_sem_wait,@function
_xt_sem_wait:                           # @_xt_sem_wait
# %bb.0:
	test	rdi, rdi
	je	.LBB60_8
# %bb.1:
	push	r14
	push	rbx
	push	rax
	mov	rbx, rdi
	.p2align	4
.LBB60_2:                               # =>This Inner Loop Header: Depth=1
	mov	eax, dword ptr [rbx]
	test	eax, eax
	jle	.LBB60_4
# %bb.3:                                #   in Loop: Header=BB60_2 Depth=1
	lea	ecx, [rax - 1]
	xor	edx, edx
                                        # kill: def $eax killed $eax killed $rax
	lock		cmpxchg	dword ptr [rbx], ecx
	setne	dl
	lea	r14d, [2*rdx + 1]
	test	r14d, r14d
	jne	.LBB60_6
	jmp	.LBB60_2
	.p2align	4
.LBB60_4:                               #   in Loop: Header=BB60_2 Depth=1
	xor	r14d, r14d
	mov	rdi, rbx
	xor	esi, esi
	xor	edx, edx
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	call	_sys_futex@PLT
	test	r14d, r14d
	je	.LBB60_2
.LBB60_6:                               #   in Loop: Header=BB60_2 Depth=1
	cmp	r14d, 3
	je	.LBB60_2
# %bb.7:
	add	rsp, 8
	pop	rbx
	pop	r14
.LBB60_8:
	ret
.Lfunc_end60:
	.size	_xt_sem_wait, .Lfunc_end60-_xt_sem_wait
                                        # -- End function
	.globl	_xt_sem_trywait                 # -- Begin function _xt_sem_trywait
	.p2align	4
	.type	_xt_sem_trywait,@function
_xt_sem_trywait:                        # @_xt_sem_trywait
# %bb.0:
	test	rdi, rdi
	je	.LBB61_1
# %bb.2:
	mov	edx, 1
                                        # implicit-def: $ecx
	jmp	.LBB61_3
	.p2align	4
.LBB61_5:                               #   in Loop: Header=BB61_3 Depth=1
	lea	esi, [rax - 1]
                                        # kill: def $eax killed $eax killed $rax
	lock		cmpxchg	dword ptr [rdi], esi
	setne	al
	cmove	ecx, edx
	test	al, al
	je	.LBB61_7
.LBB61_3:                               # =>This Inner Loop Header: Depth=1
	mov	eax, dword ptr [rdi]
	test	eax, eax
	jg	.LBB61_5
# %bb.4:                                #   in Loop: Header=BB61_3 Depth=1
	xor	eax, eax
	xor	ecx, ecx
	test	al, al
	jne	.LBB61_3
.LBB61_7:
	mov	eax, ecx
	ret
.LBB61_1:
	xor	eax, eax
	ret
.Lfunc_end61:
	.size	_xt_sem_trywait, .Lfunc_end61-_xt_sem_trywait
                                        # -- End function
	.globl	_xt_sem_post                    # -- Begin function _xt_sem_post
	.p2align	4
	.type	_xt_sem_post,@function
_xt_sem_post:                           # @_xt_sem_post
# %bb.0:
	test	rdi, rdi
	je	.LBB62_1
# %bb.2:
	lock		inc	dword ptr [rdi]
	mov	esi, 1
	mov	edx, 1
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	jmp	_sys_futex@PLT                  # TAILCALL
.LBB62_1:
	ret
.Lfunc_end62:
	.size	_xt_sem_post, .Lfunc_end62-_xt_sem_post
                                        # -- End function
	.globl	_xt_tls_new                     # -- Begin function _xt_tls_new
	.p2align	4
	.type	_xt_tls_new,@function
_xt_tls_new:                            # @_xt_tls_new
# %bb.0:
	.p2align	4
.LBB63_2:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB63_1 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_tls_keyspin], eax
	test	eax, eax
	je	.LBB63_3
.LBB63_1:                               #   Parent Loop BB63_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_tls_keyspin]
	test	eax, eax
	jne	.LBB63_1
	jmp	.LBB63_2
.LBB63_3:
	mov	ecx, dword ptr [rip + xt_tls_next_key]
	mov	eax, -1
	cmp	ecx, 61
	ja	.LBB63_5
# %bb.4:
	lea	eax, [rcx + 1]
	mov	dword ptr [rip + xt_tls_next_key], eax
	mov	eax, ecx
.LBB63_5:
	mov	dword ptr [rip + xt_tls_keyspin], 0
	ret
.Lfunc_end63:
	.size	_xt_tls_new, .Lfunc_end63-_xt_tls_new
                                        # -- End function
	.globl	_xt_tls_set                     # -- Begin function _xt_tls_set
	.p2align	4
	.type	_xt_tls_set,@function
_xt_tls_set:                            # @_xt_tls_set
# %bb.0:
	cmp	edi, 61
	ja	.LBB64_2
# %bb.1:
	push	rbp
	push	rbx
	push	rax
	mov	rbx, rsi
	mov	ebp, edi
	call	_xt_tcb_get@PLT
	mov	ecx, ebp
	mov	qword ptr [rax + 8*rcx + 8], rbx
	add	rsp, 8
	pop	rbx
	pop	rbp
.LBB64_2:
	ret
.Lfunc_end64:
	.size	_xt_tls_set, .Lfunc_end64-_xt_tls_set
                                        # -- End function
	.globl	_xt_tls_get                     # -- Begin function _xt_tls_get
	.p2align	4
	.type	_xt_tls_get,@function
_xt_tls_get:                            # @_xt_tls_get
# %bb.0:
	cmp	edi, 61
	jbe	.LBB65_2
# %bb.1:
	xor	eax, eax
	ret
.LBB65_2:
	push	rbx
	mov	ebx, edi
	call	_xt_tcb_get@PLT
	mov	ecx, ebx
	mov	rax, qword ptr [rax + 8*rcx + 8]
	pop	rbx
	ret
.Lfunc_end65:
	.size	_xt_tls_get, .Lfunc_end65-_xt_tls_get
                                        # -- End function
	.globl	_xt_atomic_load_i32             # -- Begin function _xt_atomic_load_i32
	.p2align	4
	.type	_xt_atomic_load_i32,@function
_xt_atomic_load_i32:                    # @_xt_atomic_load_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB66_1
# %bb.2:
	mov	eax, dword ptr [rdi]
	ret
.LBB66_1:
	xor	eax, eax
	ret
.Lfunc_end66:
	.size	_xt_atomic_load_i32, .Lfunc_end66-_xt_atomic_load_i32
                                        # -- End function
	.globl	_xt_atomic_store_i32            # -- Begin function _xt_atomic_store_i32
	.p2align	4
	.type	_xt_atomic_store_i32,@function
_xt_atomic_store_i32:                   # @_xt_atomic_store_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB67_2
# %bb.1:
	xchg	dword ptr [rdi], esi
.LBB67_2:
	ret
.Lfunc_end67:
	.size	_xt_atomic_store_i32, .Lfunc_end67-_xt_atomic_store_i32
                                        # -- End function
	.globl	_xt_atomic_add_i32              # -- Begin function _xt_atomic_add_i32
	.p2align	4
	.type	_xt_atomic_add_i32,@function
_xt_atomic_add_i32:                     # @_xt_atomic_add_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB68_1
# %bb.2:
	mov	eax, esi
	lock		xadd	dword ptr [rdi], eax
	add	eax, esi
	ret
.LBB68_1:
	xor	eax, eax
	ret
.Lfunc_end68:
	.size	_xt_atomic_add_i32, .Lfunc_end68-_xt_atomic_add_i32
                                        # -- End function
	.globl	_xt_atomic_xchg_i32             # -- Begin function _xt_atomic_xchg_i32
	.p2align	4
	.type	_xt_atomic_xchg_i32,@function
_xt_atomic_xchg_i32:                    # @_xt_atomic_xchg_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB69_1
# %bb.2:
	mov	eax, esi
	xchg	dword ptr [rdi], eax
	ret
.LBB69_1:
	xor	eax, eax
	ret
.Lfunc_end69:
	.size	_xt_atomic_xchg_i32, .Lfunc_end69-_xt_atomic_xchg_i32
                                        # -- End function
	.globl	_xt_atomic_cas_i32              # -- Begin function _xt_atomic_cas_i32
	.p2align	4
	.type	_xt_atomic_cas_i32,@function
_xt_atomic_cas_i32:                     # @_xt_atomic_cas_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB70_1
# %bb.2:
	mov	eax, esi
	lock		cmpxchg	dword ptr [rdi], edx
	mov	eax, 0
	sete	al
	ret
.LBB70_1:
	xor	eax, eax
	ret
.Lfunc_end70:
	.size	_xt_atomic_cas_i32, .Lfunc_end70-_xt_atomic_cas_i32
                                        # -- End function
	.globl	_xt_atomic_load_ptr             # -- Begin function _xt_atomic_load_ptr
	.p2align	4
	.type	_xt_atomic_load_ptr,@function
_xt_atomic_load_ptr:                    # @_xt_atomic_load_ptr
# %bb.0:
	test	rdi, rdi
	je	.LBB71_1
# %bb.2:
	mov	rax, qword ptr [rdi]
	ret
.LBB71_1:
	xor	eax, eax
	ret
.Lfunc_end71:
	.size	_xt_atomic_load_ptr, .Lfunc_end71-_xt_atomic_load_ptr
                                        # -- End function
	.globl	_xt_atomic_store_ptr            # -- Begin function _xt_atomic_store_ptr
	.p2align	4
	.type	_xt_atomic_store_ptr,@function
_xt_atomic_store_ptr:                   # @_xt_atomic_store_ptr
# %bb.0:
	test	rdi, rdi
	je	.LBB72_2
# %bb.1:
	xchg	qword ptr [rdi], rsi
.LBB72_2:
	ret
.Lfunc_end72:
	.size	_xt_atomic_store_ptr, .Lfunc_end72-_xt_atomic_store_ptr
                                        # -- End function
	.globl	_xt_atomic_cas_ptr              # -- Begin function _xt_atomic_cas_ptr
	.p2align	4
	.type	_xt_atomic_cas_ptr,@function
_xt_atomic_cas_ptr:                     # @_xt_atomic_cas_ptr
# %bb.0:
	test	rdi, rdi
	je	.LBB73_1
# %bb.2:
	mov	rax, rsi
	lock		cmpxchg	qword ptr [rdi], rdx
	mov	eax, 0
	sete	al
	ret
.LBB73_1:
	xor	eax, eax
	ret
.Lfunc_end73:
	.size	_xt_atomic_cas_ptr, .Lfunc_end73-_xt_atomic_cas_ptr
                                        # -- End function
	.globl	_xt_thread_exiting              # -- Begin function _xt_thread_exiting
	.p2align	4
	.type	_xt_thread_exiting,@function
_xt_thread_exiting:                     # @_xt_thread_exiting
# %bb.0:
	ret
.Lfunc_end74:
	.size	_xt_thread_exiting, .Lfunc_end74-_xt_thread_exiting
                                        # -- End function
	.type	xt_cache,@object                # @xt_cache
	.local	xt_cache
	.comm	xt_cache,512,16
	.type	xt_cache_n,@object              # @xt_cache_n
	.local	xt_cache_n
	.comm	xt_cache_n,256,16
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
	.type	xt_reap_spin,@object            # @xt_reap_spin
	.local	xt_reap_spin
	.comm	xt_reap_spin,4,4
	.type	xt_reap_head,@object            # @xt_reap_head
	.local	xt_reap_head
	.comm	xt_reap_head,8,8
	.type	xt_tls_keyspin,@object          # @xt_tls_keyspin
	.local	xt_tls_keyspin
	.comm	xt_tls_keyspin,4,4
	.type	xt_tls_next_key,@object         # @xt_tls_next_key
	.data
	.p2align	2, 0x0
xt_tls_next_key:
	.long	25                              # 0x19
	.size	xt_tls_next_key, 4

	.type	_xt_main_tls_pad,@object
	.bss
# 240 bytes reserved BELOW the main tcb (hand-applied): the static-TLS block
# lives at [%fs - R, %fs) and the crt copies __xt_tls_hdr's image here. The
# linker caps R at 240; 240 is a multiple of 16, so the tcb that follows
# contiguously inherits the 16-alignment the TLS block base needs.
	.local	_xt_main_tls_pad
	.p2align	4, 0x0
_xt_main_tls_pad:
	.zero	240
	.size	_xt_main_tls_pad, 240
	.type	_xt_main_tcb,@object            # @_xt_main_tcb
	.globl	_xt_main_tcb
_xt_main_tcb:
	.zero	504
	.size	_xt_main_tcb, 504

	.ident	"Homebrew clang version 22.1.3"
	.section	".note.GNU-stack","",@progbits
	.addrsig
	.addrsig_sym xt_thread_entry
	.addrsig_sym xt_rt_spin
	.addrsig_sym xt_alloc_spin
	.addrsig_sym xt_reap_spin
	.addrsig_sym xt_tls_keyspin

// ── _xtc_sinit_run ─────────────────────────────────────────────────────────
// The race-free static-init once (support/generic/runtime/xt-sinit.c), emitted
// by lowering only for modules that thread. APPENDED rather than regenerated
// with the rest of this file: a fresh `clang -S` of the whole runtime emits
// instructions the in-house assemblers do not all implement.
//
// This tail carried the OLD two-call shape (_xtc_sinit_enter / _xtc_sinit_done)
// long after lowering moved to the single `_xtc_sinit_run`, so the freestanding
// runtime defined two symbols nothing called and lacked the one everything did.
// Nothing noticed because the in-house path was opt-in and no threads fixture
// ran through it; the moment it became the default, every threads_* fixture
// failed to link. A checked-in generated file is only as current as the last
// time somebody regenerated it.
//
// Every `.L` local label is renamed `.Lsi_`. Concatenating two separately
// compiled clang outputs collides on them, and the in-house linker refuses
// rather than silently picking one. Regenerate with
//   clang --target=x86_64-unknown-linux-gnu -S -O1 -masm=intel \
//         -fno-stack-protector -fomit-frame-pointer \
//         support/generic/runtime/xt-sinit.c
// then re-apply `.L` -> `.Lsi_`.
	.text
	.intel_syntax noprefix
	.file	"xt-sinit.c"
	.globl	_xtc_sinit_run                  # -- Begin function _xtc_sinit_run
	.p2align	4, 0x90
	.type	_xtc_sinit_run,@function
_xtc_sinit_run:                         # @_xtc_sinit_run
	.cfi_startproc
# %bb.0:
	push	r15
	.cfi_def_cfa_offset 16
	push	r14
	.cfi_def_cfa_offset 24
	push	r13
	.cfi_def_cfa_offset 32
	push	r12
	.cfi_def_cfa_offset 40
	push	rbx
	.cfi_def_cfa_offset 48
	.cfi_offset rbx, -48
	.cfi_offset r12, -40
	.cfi_offset r13, -32
	.cfi_offset r14, -24
	.cfi_offset r15, -16
	test	rdi, rdi
	je	.Lsi_BB0_24
# %bb.1:
	mov	r15, rdx
	mov	r14, rsi
	mov	rbx, rdi
	lea	r12, [rip + xt_sinit_flag]
	lea	r13, [rip + xt_sinit_owner]
	jmp	.Lsi_BB0_2
	.p2align	4, 0x90
.Lsi_BB0_4:                                #   in Loop: Header=BB0_2 Depth=1
	call	_xt_rt_unlock@PLT
	mov	eax, 1
.Lsi_BB0_14:                               #   in Loop: Header=BB0_2 Depth=1
	test	eax, eax
	jne	.Lsi_BB0_15
.Lsi_BB0_2:                                # =>This Loop Header: Depth=1
                                        #     Child Loop BB0_10 Depth 2
	call	_xt_rt_lock@PLT
	movzx	eax, byte ptr [rbx]
	test	eax, eax
	je	.Lsi_BB0_5
# %bb.3:                                #   in Loop: Header=BB0_2 Depth=1
	cmp	eax, 2
	je	.Lsi_BB0_4
# %bb.8:                                #   in Loop: Header=BB0_2 Depth=1
	call	_xt_thread_self_id@PLT
	movsxd	rcx, dword ptr [rip + xt_sinit_n]
	test	rcx, rcx
	jle	.Lsi_BB0_13
# %bb.9:                                #   in Loop: Header=BB0_2 Depth=1
	shl	rcx, 3
	xor	edx, edx
	mov	rsi, r13
	jmp	.Lsi_BB0_10
	.p2align	4, 0x90
.Lsi_BB0_12:                               #   in Loop: Header=BB0_10 Depth=2
	add	rsi, 4
	add	rdx, 8
	cmp	rcx, rdx
	je	.Lsi_BB0_13
.Lsi_BB0_10:                               #   Parent Loop BB0_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	qword ptr [rdx + r12], rbx
	jne	.Lsi_BB0_12
# %bb.11:                               #   in Loop: Header=BB0_10 Depth=2
	cmp	dword ptr [rsi], eax
	jne	.Lsi_BB0_12
	jmp	.Lsi_BB0_4
	.p2align	4, 0x90
.Lsi_BB0_5:                                #   in Loop: Header=BB0_2 Depth=1
	mov	byte ptr [rbx], 1
	movsxd	rax, dword ptr [rip + xt_sinit_n]
	cmp	rax, 31
	jg	.Lsi_BB0_7
# %bb.6:                                #   in Loop: Header=BB0_2 Depth=1
	mov	qword ptr [r12 + 8*rax], rbx
	call	_xt_thread_self_id@PLT
	movsxd	rcx, dword ptr [rip + xt_sinit_n]
	mov	dword ptr [r13 + 4*rcx], eax
	lea	eax, [rcx + 1]
	mov	dword ptr [rip + xt_sinit_n], eax
.Lsi_BB0_7:                                #   in Loop: Header=BB0_2 Depth=1
	call	_xt_rt_unlock@PLT
	mov	eax, 2
	jmp	.Lsi_BB0_14
	.p2align	4, 0x90
.Lsi_BB0_13:                               #   in Loop: Header=BB0_2 Depth=1
	call	_xt_rt_unlock@PLT
	call	_xt_thread_yield@PLT
	xor	eax, eax
	jmp	.Lsi_BB0_14
.Lsi_BB0_15:
	cmp	eax, 1
	jne	.Lsi_BB0_16
.Lsi_BB0_24:
	pop	rbx
	.cfi_def_cfa_offset 40
	pop	r12
	.cfi_def_cfa_offset 32
	pop	r13
	.cfi_def_cfa_offset 24
	pop	r14
	.cfi_def_cfa_offset 16
	pop	r15
	.cfi_def_cfa_offset 8
	ret
.Lsi_BB0_16:
	.cfi_def_cfa_offset 48
	test	r14, r14
	je	.Lsi_BB0_18
# %bb.17:
	mov	rdi, r15
	call	r14
.Lsi_BB0_18:
	call	_xt_rt_lock@PLT
	mov	byte ptr [rbx], 2
	movsxd	rax, dword ptr [rip + xt_sinit_n]
	test	rax, rax
	jle	.Lsi_BB0_23
# %bb.19:
	lea	rdx, [4*rax]
	xor	ecx, ecx
	.p2align	4, 0x90
.Lsi_BB0_21:                               # =>This Inner Loop Header: Depth=1
	cmp	qword ptr [r12], rbx
	je	.Lsi_BB0_22
# %bb.20:                               #   in Loop: Header=BB0_21 Depth=1
	add	rcx, 4
	add	r12, 8
	cmp	rdx, rcx
	jne	.Lsi_BB0_21
	jmp	.Lsi_BB0_23
.Lsi_BB0_22:
	lea	edx, [rax - 1]
	mov	dword ptr [rip + xt_sinit_n], edx
	lea	rdx, [rip + xt_sinit_flag]
	mov	rdx, qword ptr [rdx + 8*rax - 8]
	mov	qword ptr [r12], rdx
	lea	rdx, [rip + xt_sinit_owner]
	mov	eax, dword ptr [rdx + 4*rax - 4]
	mov	dword ptr [rcx + rdx], eax
.Lsi_BB0_23:
	pop	rbx
	.cfi_def_cfa_offset 40
	pop	r12
	.cfi_def_cfa_offset 32
	pop	r13
	.cfi_def_cfa_offset 24
	pop	r14
	.cfi_def_cfa_offset 16
	pop	r15
	.cfi_def_cfa_offset 8
	jmp	_xt_rt_unlock@PLT               # TAILCALL
.Lsi_func_end0:
	.size	_xtc_sinit_run, .Lsi_func_end0-_xtc_sinit_run
	.cfi_endproc
                                        # -- End function
	.type	xt_sinit_n,@object              # @xt_sinit_n
	.local	xt_sinit_n
	.comm	xt_sinit_n,4,4
	.type	xt_sinit_flag,@object           # @xt_sinit_flag
	.local	xt_sinit_flag
	.comm	xt_sinit_flag,256,16
	.type	xt_sinit_owner,@object          # @xt_sinit_owner
	.local	xt_sinit_owner
	.comm	xt_sinit_owner,128,16
	.ident	"Apple clang version 17.0.0 (clang-1700.3.19.1)"
	.section	".note.GNU-stack","",@progbits
	.addrsig
