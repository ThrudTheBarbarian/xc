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
	.p2align	4, 0x90
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
	.p2align	4, 0x90
	.type	_xt_alloc_lock,@function
_xt_alloc_lock:                         # @_xt_alloc_lock
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB1_3
	.p2align	4, 0x90
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
	.p2align	4, 0x90
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
	.p2align	4, 0x90
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
	.p2align	4, 0x90
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
	.p2align	4, 0x90
	.type	memset,@function
memset:                                 # @memset
# %bb.0:
	mov	rax, rdi
	test	rdx, rdx
	je	.LBB4_3
# %bb.1:
	xor	ecx, ecx
	.p2align	4, 0x90
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
	jbe	.LBB5_1
# %bb.2:
	lea	rsi, [rdi + 1]
	mov	byte ptr [rdi], 45
	xorpd	xmm0, xmmword ptr [rip + .LCPI5_0]
	jmp	.LBB5_3
.LBB5_1:
	mov	rsi, rdi
.LBB5_3:
	cvttsd2si	rdx, xmm0
	xorps	xmm1, xmm1
	cvtsi2sd	xmm1, rdx
	xor	r10d, r10d
	movabs	r11, -3689348814741910323
	.p2align	4, 0x90
.LBB5_4:                                # =>This Inner Loop Header: Depth=1
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
	jb	.LBB5_6
# %bb.5:                                #   in Loop: Header=BB5_4 Depth=1
	cmp	r10, 23
	mov	r10, rax
	jb	.LBB5_4
	.p2align	4, 0x90
.LBB5_6:                                # =>This Inner Loop Header: Depth=1
	lea	rdx, [rax - 1]
	mov	r8d, edx
	movzx	r8d, byte ptr [rsp + r8 - 32]
	mov	byte ptr [rsi], r8b
	inc	rsi
	cmp	rax, 1
	mov	rax, rdx
	jg	.LBB5_6
# %bb.7:
	test	ecx, ecx
	jle	.LBB5_11
# %bb.8:
	subsd	xmm0, xmm1
	mov	byte ptr [rsi], 46
	neg	r9d
	mov	eax, 1
	movsd	xmm1, qword ptr [rip + .LCPI5_1] # xmm1 = [1.0E+1,0.0E+0]
	mov	ecx, 9
	xor	edx, edx
	.p2align	4, 0x90
.LBB5_9:                                # =>This Inner Loop Header: Depth=1
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
	jne	.LBB5_9
# %bb.10:
	add	rsi, rax
.LBB5_11:
	mov	byte ptr [rsi], 0
	sub	esi, edi
	mov	eax, esi
	pop	rbx
	ret
.Lfunc_end5:
	.size	_xt_fmt_f, .Lfunc_end5-_xt_fmt_f
                                        # -- End function
	.globl	_xt_stack_guard_init            # -- Begin function _xt_stack_guard_init
	.p2align	4, 0x90
	.type	_xt_stack_guard_init,@function
_xt_stack_guard_init:                   # @_xt_stack_guard_init
# %bb.0:
	mov	qword ptr [rsp - 8], 0
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
	lea	rax, [rsp - 8]
	mov	rdx, rax
	shl	rdx, 17
	shr	rax, 13
	xor	rax, rdx
	lea	rdx, [rip + _xt_stack_guard_init]
	movabs	rsi, -4417276706812531889
	imul	rsi, rdx
	xor	rsi, rax
	xor	rsi, rcx
	mov	rax, rsi
	shr	rax, 31
	xor	rax, rsi
	movabs	rcx, -7723592293110705685
	imul	rcx, rax
	mov	rax, rcx
	shr	rax, 29
	xor	rax, rcx
	and	rax, -256
	movabs	rcx, 6364786164175470592
	cmovne	rcx, rax
	mov	qword ptr [rip + __xt_stack_guard], rcx
	ret
.Lfunc_end6:
	.size	_xt_stack_guard_init, .Lfunc_end6-_xt_stack_guard_init
                                        # -- End function
	.globl	__xt_stack_fail                 # -- Begin function __xt_stack_fail
	.p2align	4, 0x90
	.type	__xt_stack_fail,@function
__xt_stack_fail:                        # @__xt_stack_fail
# %bb.0:
	push	rax
	lea	rsi, [rip + __xt_stack_fail.msg]
	mov	edx, 70
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	pop	rax
	jmp	_xt_exit@PLT                    # TAILCALL
.Lfunc_end7:
	.size	__xt_stack_fail, .Lfunc_end7-__xt_stack_fail
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
	je	.LBB8_3
# %bb.1:
	mov	rax, -1048577
	xor	edx, edx
	div	r15
	cmp	rax, r14
	jae	.LBB8_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB8_3:
	mov	rax, r15
	imul	rax, r14
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB8_4
# %bb.5:
	movabs	rcx, 5776887618
	mov	qword ptr [rax + 32], rcx
	mov	qword ptr [rax], r15
	mov	qword ptr [rax + 8], r14
	mov	qword ptr [rax + 16], rbx
	mov	qword ptr [rax + 24], 0
	add	rax, 40
	jmp	.LBB8_6
.LBB8_4:
	xor	eax, eax
.LBB8_6:
	pop	rbx
	pop	r14
	pop	r15
	ret
.Lfunc_end8:
	.size	_xtc_alloc, .Lfunc_end8-_xtc_alloc
                                        # -- End function
	.globl	_xtc_alloc_object               # -- Begin function _xtc_alloc_object
	.p2align	4, 0x90
	.type	_xtc_alloc_object,@function
_xtc_alloc_object:                      # @_xtc_alloc_object
# %bb.0:
	push	rbx
	cmp	rdi, -1048576
	jb	.LBB9_2
# %bb.1:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	rbx, rdi
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
	mov	rdi, rbx
.LBB9_2:
	add	rdi, 8
	call	_xt_calloc
	test	rax, rax
	je	.LBB9_3
# %bb.4:
	movabs	rcx, 5776887630
	mov	qword ptr [rax], rcx
	add	rax, 8
	pop	rbx
	ret
.LBB9_3:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end9:
	.size	_xtc_alloc_object, .Lfunc_end9-_xtc_alloc_object
                                        # -- End function
	.globl	_xtc_simd_register              # -- Begin function _xtc_simd_register
	.p2align	4, 0x90
	.type	_xtc_simd_register,@function
_xtc_simd_register:                     # @_xtc_simd_register
# %bb.0:
	test	rdi, rdi
	je	.LBB10_76
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
	je	.LBB10_75
# %bb.2:
	mov	r14, rdi
	mov	eax, r14d
	or	eax, ebx
	and	eax, 4095
	jne	.LBB10_75
# %bb.3:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB10_6
	.p2align	4, 0x90
.LBB10_4:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB10_5 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB10_6
.LBB10_5:                               #   Parent Loop BB10_4 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB10_5
	jmp	.LBB10_4
.LBB10_6:
	mov	rax, qword ptr [rip + xt_simd_cap]
	cmp	qword ptr [rip + xt_simd_n], rax
	jne	.LBB10_66
# %bb.7:
	lea	rcx, [rax + rax]
	test	rax, rax
	mov	r12d, 64
	cmovne	r12, rcx
	mov	rdi, r12
	shl	rdi, 4
	call	_xt_calloc
	mov	r13, rax
	mov	rdi, r12
	call	_xt_calloc
	mov	r15, rax
	test	r13, r13
	setne	al
	test	r15, r15
	setne	bpl
	and	bpl, al
	cmp	bpl, 1
	jne	.LBB10_17
# %bb.8:
	mov	rax, qword ptr [rip + xt_simd_n]
	mov	rcx, rax
	add	rcx, rax
	je	.LBB10_11
# %bb.9:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	esi, esi
	.p2align	4, 0x90
.LBB10_10:                              # =>This Inner Loop Header: Depth=1
	mov	rdi, qword ptr [rdx + 8*rsi]
	mov	qword ptr [r13 + 8*rsi], rdi
	inc	rsi
	cmp	rcx, rsi
	jne	.LBB10_10
.LBB10_11:
	test	rax, rax
	je	.LBB10_14
# %bb.12:
	mov	rcx, qword ptr [rip + xt_simd_flag]
	xor	edx, edx
	.p2align	4, 0x90
.LBB10_13:                              # =>This Inner Loop Header: Depth=1
	movzx	esi, byte ptr [rcx + rdx]
	mov	byte ptr [r15 + rdx], sil
	inc	rdx
	cmp	rax, rdx
	jne	.LBB10_13
.LBB10_14:
	mov	rdi, qword ptr [rip + xt_simd_tab]
	test	rdi, rdi
	je	.LBB10_36
# %bb.15:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	.LBB10_16
# %bb.20:
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB10_22
	jmp	.LBB10_23
	.p2align	4, 0x90
.LBB10_21:                              #   Parent Loop BB10_22 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB10_21
.LBB10_22:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB10_21 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB10_21
.LBB10_23:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB10_34
# %bb.24:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB10_16
# %bb.25:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB10_16:
	call	free@PLT
.LBB10_36:
	mov	rdi, qword ptr [rip + xt_simd_flag]
	test	rdi, rdi
	je	.LBB10_60
# %bb.37:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	.LBB10_38
# %bb.39:
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB10_41
	jmp	.LBB10_42
	.p2align	4, 0x90
.LBB10_40:                              #   Parent Loop BB10_41 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB10_40
.LBB10_41:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB10_40 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB10_40
.LBB10_42:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB10_58
# %bb.43:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB10_38
# %bb.44:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB10_38:
	call	free@PLT
.LBB10_60:
	mov	qword ptr [rip + xt_simd_tab], r13
	mov	qword ptr [rip + xt_simd_flag], r15
	mov	qword ptr [rip + xt_simd_cap], r12
	jmp	.LBB10_65
.LBB10_17:
	test	r13, r13
	je	.LBB10_48
# %bb.18:
	mov	rdi, r13
	add	rdi, -8
	mov	rax, qword ptr [r13 - 8]
	cmp	rax, 64
	jae	.LBB10_19
# %bb.27:
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB10_29
	jmp	.LBB10_30
	.p2align	4, 0x90
.LBB10_28:                              #   Parent Loop BB10_29 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB10_28
.LBB10_29:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB10_28 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB10_28
.LBB10_30:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB10_46
# %bb.31:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB10_19
# %bb.32:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB10_19:
	call	free@PLT
.LBB10_48:
	test	r15, r15
	je	.LBB10_63
# %bb.49:
	mov	rdi, r15
	add	rdi, -8
	mov	rax, qword ptr [r15 - 8]
	cmp	rax, 64
	jae	.LBB10_50
# %bb.51:
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB10_53
	jmp	.LBB10_54
	.p2align	4, 0x90
.LBB10_52:                              #   Parent Loop BB10_53 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB10_52
.LBB10_53:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB10_52 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB10_52
.LBB10_54:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB10_61
# %bb.55:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB10_50
# %bb.56:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB10_50:
	call	free@PLT
.LBB10_63:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB10_65
# %bb.64:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB10_65:
	test	bpl, bpl
	je	.LBB10_75
.LBB10_66:
	mov	rax, qword ptr [rip + xt_simd_n]
	test	rax, rax
	je	.LBB10_70
# %bb.67:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	ecx, ecx
	movabs	rsi, 2305843009213693950
	mov	rdi, rax
	.p2align	4, 0x90
.LBB10_68:                              # =>This Inner Loop Header: Depth=1
	lea	r8, [rdi + rcx]
	mov	r9, r8
	shr	r9
	and	r8, rsi
	cmp	qword ptr [rdx + 8*r8], r14
	lea	r8, [r9 + 1]
	cmova	rdi, r9
	cmovbe	rcx, r8
	cmp	rcx, rdi
	jb	.LBB10_68
# %bb.69:
	cmp	rax, rcx
	ja	.LBB10_71
	jmp	.LBB10_73
.LBB10_70:
	xor	ecx, ecx
	cmp	rax, rcx
	jbe	.LBB10_73
.LBB10_71:
	mov	rdx, qword ptr [rip + xt_simd_flag]
	mov	rdi, rax
	shl	rdi, 4
	add	rdi, qword ptr [rip + xt_simd_tab]
	mov	rsi, rax
	.p2align	4, 0x90
.LBB10_72:                              # =>This Inner Loop Header: Depth=1
	movups	xmm0, xmmword ptr [rdi - 16]
	movups	xmmword ptr [rdi], xmm0
	add	rdi, -16
	movzx	r8d, byte ptr [rdx + rsi - 1]
	mov	byte ptr [rdx + rsi], r8b
	dec	rsi
	cmp	rsi, rcx
	ja	.LBB10_72
.LBB10_73:
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
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB10_75
# %bb.74:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB10_75:
	add	rsp, 8
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	pop	rbp
.LBB10_76:
	ret
.LBB10_34:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB10_36
# %bb.35:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB10_36
.LBB10_58:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB10_60
# %bb.59:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB10_60
.LBB10_46:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB10_48
# %bb.47:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB10_48
.LBB10_61:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB10_63
# %bb.62:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB10_63
.Lfunc_end10:
	.size	_xtc_simd_register, .Lfunc_end10-_xtc_simd_register
                                        # -- End function
	.globl	_xtc_simd_base                  # -- Begin function _xtc_simd_base
	.p2align	4, 0x90
	.type	_xtc_simd_base,@function
_xtc_simd_base:                         # @_xtc_simd_base
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
	mov	rcx, qword ptr [rip + xt_simd_n]
	test	rcx, rcx
	je	.LBB11_9
# %bb.4:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	eax, eax
	movabs	rsi, 2305843009213693950
	.p2align	4, 0x90
.LBB11_5:                               # =>This Inner Loop Header: Depth=1
	lea	r8, [rcx + rax]
	mov	r9, r8
	shr	r9
	and	r8, rsi
	cmp	qword ptr [rdx + 8*r8], rdi
	lea	r8, [r9 + 1]
	cmova	rcx, r9
	cmovbe	rax, r8
	cmp	rax, rcx
	jb	.LBB11_5
# %bb.6:
	test	rax, rax
	jne	.LBB11_7
	jmp	.LBB11_10
.LBB11_9:
	xor	eax, eax
	test	rax, rax
	je	.LBB11_10
.LBB11_7:
	mov	rcx, qword ptr [rip + xt_simd_tab]
	shl	rax, 4
	cmp	qword ptr [rcx + rax - 8], rdi
	jbe	.LBB11_10
# %bb.8:
	mov	rax, qword ptr [rcx + rax - 16]
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB11_11
	jmp	.LBB11_12
.LBB11_10:
	xor	eax, eax
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB11_12
.LBB11_11:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB11_12:
	ret
.Lfunc_end11:
	.size	_xtc_simd_base, .Lfunc_end11-_xtc_simd_base
                                        # -- End function
	.globl	_xt_rt_lock                     # -- Begin function _xt_rt_lock
	.p2align	4, 0x90
	.type	_xt_rt_lock,@function
_xt_rt_lock:                            # @_xt_rt_lock
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB12_3
	.p2align	4, 0x90
.LBB12_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB12_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB12_3
.LBB12_2:                               #   Parent Loop BB12_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB12_2
	jmp	.LBB12_1
.LBB12_3:
	ret
.Lfunc_end12:
	.size	_xt_rt_lock, .Lfunc_end12-_xt_rt_lock
                                        # -- End function
	.globl	_xt_rt_unlock                   # -- Begin function _xt_rt_unlock
	.p2align	4, 0x90
	.type	_xt_rt_unlock,@function
_xt_rt_unlock:                          # @_xt_rt_unlock
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB13_2
# %bb.1:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB13_2:
	ret
.Lfunc_end13:
	.size	_xt_rt_unlock, .Lfunc_end13-_xt_rt_unlock
                                        # -- End function
	.globl	_xtc_simd_span                  # -- Begin function _xtc_simd_span
	.p2align	4, 0x90
	.type	_xtc_simd_span,@function
_xtc_simd_span:                         # @_xtc_simd_span
# %bb.0:
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
	test	rax, rax
	je	.LBB14_4
# %bb.5:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	ecx, ecx
	movabs	rsi, 2305843009213693950
	.p2align	4, 0x90
.LBB14_6:                               # =>This Inner Loop Header: Depth=1
	lea	r8, [rax + rcx]
	mov	r9, r8
	shr	r9
	and	r8, rsi
	cmp	qword ptr [rdx + 8*r8], rdi
	lea	r8, [r9 + 1]
	cmova	rax, r9
	cmovbe	rcx, r8
	cmp	rcx, rax
	jb	.LBB14_6
	jmp	.LBB14_7
.LBB14_4:
	xor	ecx, ecx
.LBB14_7:
	mov	rax, -1
	test	rcx, rcx
	je	.LBB14_10
# %bb.8:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	shl	rcx, 4
	mov	rcx, qword ptr [rdx + rcx - 8]
	sub	rcx, rdi
	jbe	.LBB14_10
# %bb.9:
	mov	rax, rcx
.LBB14_10:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB14_12
# %bb.11:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB14_12:
	ret
.Lfunc_end14:
	.size	_xtc_simd_span, .Lfunc_end14-_xtc_simd_span
                                        # -- End function
	.globl	_xtc_simd_watch                 # -- Begin function _xtc_simd_watch
	.p2align	4, 0x90
	.type	_xtc_simd_watch,@function
_xtc_simd_watch:                        # @_xtc_simd_watch
# %bb.0:
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
	push	r15
	push	r14
	push	r13
	push	r12
	push	rbx
	sub	rsp, 32
	mov	rax, qword ptr [rip + xt_simd_n]
	xor	ebx, ebx
	test	rax, rax
	je	.LBB15_4
# %bb.5:
	mov	rcx, qword ptr [rip + xt_simd_tab]
	xor	r15d, r15d
	movabs	rdx, 2305843009213693950
	.p2align	4, 0x90
.LBB15_6:                               # =>This Inner Loop Header: Depth=1
	lea	rsi, [rax + r15]
	mov	r8, rsi
	shr	r8
	and	rsi, rdx
	cmp	qword ptr [rcx + 8*rsi], rdi
	lea	rsi, [r8 + 1]
	cmova	rax, r8
	cmovbe	r15, rsi
	cmp	r15, rax
	jb	.LBB15_6
# %bb.7:
	test	r15, r15
	jne	.LBB15_8
	jmp	.LBB15_13
.LBB15_4:
	xor	r15d, r15d
	test	r15, r15
	je	.LBB15_13
.LBB15_8:
	mov	rax, qword ptr [rip + xt_simd_tab]
	dec	r15
	mov	r12, r15
	shl	r12, 4
	cmp	qword ptr [rax + r12], rdi
	jne	.LBB15_13
# %bb.9:
	cmp	byte ptr [rip + xt_simd_installed], 0
	jne	.LBB15_11
# %bb.10:
	lea	rax, [rip + xt_simd_fault]
	mov	qword ptr [rsp], rax
	mov	qword ptr [rsp + 8], 1140850692
	mov	rax, qword ptr [rip + xt_sigrestore@GOTPCREL]
	mov	qword ptr [rsp + 16], rax
	mov	qword ptr [rsp + 24], 0
	lea	rdx, [rip + xt_simd_old]
	mov	r14, rsp
	mov	r13, rdi
	mov	edi, 11
	mov	ecx, 8
	mov	rsi, r14
	call	_sys_rt_sigaction@PLT
	lea	rdx, [rip + xt_simd_old+32]
	mov	edi, 7
	mov	ecx, 8
	mov	rsi, r14
	call	_sys_rt_sigaction@PLT
	mov	rdi, r13
	mov	byte ptr [rip + xt_simd_installed], 1
.LBB15_11:
	mov	rax, qword ptr [rip + xt_simd_tab]
	mov	rsi, qword ptr [rax + r12 + 8]
	sub	rsi, qword ptr [rax + r12]
	add	rsi, 16383
	and	rsi, -16384
	mov	edx, 1
	call	_sys_mprotect@PLT
	test	rax, rax
	jne	.LBB15_13
# %bb.12:
	mov	rax, qword ptr [rip + xt_simd_flag]
	or	byte ptr [rax + r15], 1
	mov	ebx, 1
.LBB15_13:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB15_15
# %bb.14:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB15_15:
	mov	eax, ebx
	add	rsp, 32
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	ret
.Lfunc_end15:
	.size	_xtc_simd_watch, .Lfunc_end15-_xtc_simd_watch
                                        # -- End function
	.globl	_xtc_simd_unwatch               # -- Begin function _xtc_simd_unwatch
	.p2align	4, 0x90
	.type	_xtc_simd_unwatch,@function
_xtc_simd_unwatch:                      # @_xtc_simd_unwatch
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
	push	rax
	mov	rcx, qword ptr [rip + xt_simd_n]
	test	rcx, rcx
	je	.LBB16_4
# %bb.5:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	eax, eax
	movabs	rsi, 2305843009213693950
	.p2align	4, 0x90
.LBB16_6:                               # =>This Inner Loop Header: Depth=1
	lea	r8, [rcx + rax]
	mov	r9, r8
	shr	r9
	and	r8, rsi
	cmp	qword ptr [rdx + 8*r8], rdi
	lea	r8, [r9 + 1]
	cmova	rcx, r9
	cmovbe	rax, r8
	cmp	rax, rcx
	jb	.LBB16_6
# %bb.7:
	test	rax, rax
	jne	.LBB16_8
	jmp	.LBB16_11
.LBB16_4:
	xor	eax, eax
	test	rax, rax
	je	.LBB16_11
.LBB16_8:
	mov	rcx, qword ptr [rip + xt_simd_tab]
	dec	rax
	mov	rdx, rax
	shl	rdx, 4
	cmp	qword ptr [rcx + rdx], rdi
	jne	.LBB16_11
# %bb.9:
	mov	rsi, qword ptr [rip + xt_simd_flag]
	movzx	r8d, byte ptr [rsi + rax]
	test	r8b, 1
	je	.LBB16_11
# %bb.10:
	and	r8b, -2
	mov	byte ptr [rsi + rax], r8b
	mov	rsi, qword ptr [rcx + rdx + 8]
	sub	rsi, qword ptr [rcx + rdx]
	add	rsi, 16383
	and	rsi, -16384
	mov	edx, 3
	call	_sys_mprotect@PLT
.LBB16_11:
	cmp	dword ptr [rip + _xt_threads_active], 0
	lea	rsp, [rsp + 8]
	je	.LBB16_13
# %bb.12:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB16_13:
	ret
.Lfunc_end16:
	.size	_xtc_simd_unwatch, .Lfunc_end16-_xtc_simd_unwatch
                                        # -- End function
	.globl	_xtc_simd_dirty                 # -- Begin function _xtc_simd_dirty
	.p2align	4, 0x90
	.type	_xtc_simd_dirty,@function
_xtc_simd_dirty:                        # @_xtc_simd_dirty
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB17_3
	.p2align	4, 0x90
.LBB17_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB17_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB17_3
.LBB17_2:                               #   Parent Loop BB17_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB17_2
	jmp	.LBB17_1
.LBB17_3:
	mov	rax, qword ptr [rip + xt_simd_n]
	test	rax, rax
	je	.LBB17_4
# %bb.5:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	ecx, ecx
	movabs	rsi, 2305843009213693950
	.p2align	4, 0x90
.LBB17_6:                               # =>This Inner Loop Header: Depth=1
	lea	r8, [rax + rcx]
	mov	r9, r8
	shr	r9
	and	r8, rsi
	cmp	qword ptr [rdx + 8*r8], rdi
	lea	r8, [r9 + 1]
	cmova	rax, r9
	cmovbe	rcx, r8
	cmp	rcx, rax
	jb	.LBB17_6
	jmp	.LBB17_7
.LBB17_4:
	xor	ecx, ecx
.LBB17_7:
	mov	eax, 1
	test	rcx, rcx
	je	.LBB17_10
# %bb.8:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	dec	rcx
	mov	rsi, rcx
	shl	rsi, 4
	cmp	qword ptr [rdx + rsi], rdi
	jne	.LBB17_10
# %bb.9:
	mov	rax, qword ptr [rip + xt_simd_flag]
	movzx	eax, byte ptr [rax + rcx]
	not	eax
	and	eax, 1
.LBB17_10:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB17_12
# %bb.11:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB17_12:
	ret
.Lfunc_end17:
	.size	_xtc_simd_dirty, .Lfunc_end17-_xtc_simd_dirty
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
	je	.LBB18_3
# %bb.1:
	mov	rax, -1048577
	xor	edx, edx
	div	r12
	cmp	rax, r15
	jae	.LBB18_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB18_3:
	mov	r13, r12
	imul	r13, r15
	cmp	r13, 17
	mov	edi, 16
	cmovae	rdi, r13
	add	rdi, 16383
	and	rdi, -16384
	add	rdi, 16432
	call	_xt_calloc
	test	rax, rax
	je	.LBB18_18
# %bb.4:
	mov	rbx, rax
	add	rbx, 16431
	and	rbx, -16384
	movabs	rcx, 5776887619
	mov	qword ptr [rbx - 8], rcx
	mov	qword ptr [rbx - 40], r12
	mov	qword ptr [rbx - 32], r15
	mov	qword ptr [rbx - 24], r14
	mov	qword ptr [rbx - 16], 0
	mov	qword ptr [rbx - 48], rax
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB18_7
	.p2align	4, 0x90
.LBB18_5:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB18_6 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB18_7
.LBB18_6:                               #   Parent Loop BB18_5 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB18_6
	jmp	.LBB18_5
.LBB18_7:
	mov	rax, qword ptr [rip + xt_simd_cap]
	cmp	qword ptr [rip + xt_simd_n], rax
	jne	.LBB18_68
# %bb.8:
	lea	rcx, [rax + rax]
	test	rax, rax
	mov	r15d, 64
	cmovne	r15, rcx
	mov	rdi, r15
	shl	rdi, 4
	call	_xt_calloc
	mov	r12, rax
	mov	rdi, r15
	call	_xt_calloc
	mov	r14, rax
	test	r12, r12
	setne	al
	test	r14, r14
	setne	bpl
	and	bpl, al
	cmp	bpl, 1
	jne	.LBB18_19
# %bb.9:
	mov	rax, qword ptr [rip + xt_simd_n]
	mov	rcx, rax
	add	rcx, rax
	je	.LBB18_12
# %bb.10:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	esi, esi
	.p2align	4, 0x90
.LBB18_11:                              # =>This Inner Loop Header: Depth=1
	mov	rdi, qword ptr [rdx + 8*rsi]
	mov	qword ptr [r12 + 8*rsi], rdi
	inc	rsi
	cmp	rcx, rsi
	jne	.LBB18_11
.LBB18_12:
	test	rax, rax
	je	.LBB18_15
# %bb.13:
	mov	rcx, qword ptr [rip + xt_simd_flag]
	xor	edx, edx
	.p2align	4, 0x90
.LBB18_14:                              # =>This Inner Loop Header: Depth=1
	movzx	esi, byte ptr [rcx + rdx]
	mov	byte ptr [r14 + rdx], sil
	inc	rdx
	cmp	rax, rdx
	jne	.LBB18_14
.LBB18_15:
	mov	rdi, qword ptr [rip + xt_simd_tab]
	test	rdi, rdi
	je	.LBB18_38
# %bb.16:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	.LBB18_17
# %bb.22:
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB18_24
	jmp	.LBB18_25
	.p2align	4, 0x90
.LBB18_23:                              #   Parent Loop BB18_24 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB18_23
.LBB18_24:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB18_23 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB18_23
.LBB18_25:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB18_36
# %bb.26:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB18_17
# %bb.27:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB18_17:
	call	free@PLT
.LBB18_38:
	mov	rdi, qword ptr [rip + xt_simd_flag]
	test	rdi, rdi
	je	.LBB18_62
# %bb.39:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	.LBB18_40
# %bb.41:
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB18_43
	jmp	.LBB18_44
	.p2align	4, 0x90
.LBB18_42:                              #   Parent Loop BB18_43 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB18_42
.LBB18_43:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB18_42 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB18_42
.LBB18_44:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB18_60
# %bb.45:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB18_40
# %bb.46:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB18_40:
	call	free@PLT
.LBB18_62:
	mov	qword ptr [rip + xt_simd_tab], r12
	mov	qword ptr [rip + xt_simd_flag], r14
	mov	qword ptr [rip + xt_simd_cap], r15
	jmp	.LBB18_67
.LBB18_18:
	xor	ebx, ebx
	jmp	.LBB18_77
.LBB18_19:
	test	r12, r12
	je	.LBB18_50
# %bb.20:
	mov	rdi, r12
	add	rdi, -8
	mov	rax, qword ptr [r12 - 8]
	cmp	rax, 64
	jae	.LBB18_21
# %bb.29:
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB18_31
	jmp	.LBB18_32
	.p2align	4, 0x90
.LBB18_30:                              #   Parent Loop BB18_31 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB18_30
.LBB18_31:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB18_30 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB18_30
.LBB18_32:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB18_48
# %bb.33:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB18_21
# %bb.34:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB18_21:
	call	free@PLT
.LBB18_50:
	test	r14, r14
	je	.LBB18_65
# %bb.51:
	mov	rdi, r14
	add	rdi, -8
	mov	rax, qword ptr [r14 - 8]
	cmp	rax, 64
	jae	.LBB18_52
# %bb.53:
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB18_55
	jmp	.LBB18_56
	.p2align	4, 0x90
.LBB18_54:                              #   Parent Loop BB18_55 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB18_54
.LBB18_55:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB18_54 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB18_54
.LBB18_56:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB18_63
# %bb.57:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB18_52
# %bb.58:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB18_52:
	call	free@PLT
.LBB18_65:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB18_67
# %bb.66:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB18_67:
	test	bpl, bpl
	je	.LBB18_77
.LBB18_68:
	mov	rax, qword ptr [rip + xt_simd_n]
	test	rax, rax
	je	.LBB18_72
# %bb.69:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	ecx, ecx
	movabs	rsi, 2305843009213693950
	mov	rdi, rax
	.p2align	4, 0x90
.LBB18_70:                              # =>This Inner Loop Header: Depth=1
	lea	r8, [rdi + rcx]
	mov	r9, r8
	shr	r9
	and	r8, rsi
	cmp	qword ptr [rdx + 8*r8], rbx
	lea	r8, [r9 + 1]
	cmova	rdi, r9
	cmovbe	rcx, r8
	cmp	rcx, rdi
	jb	.LBB18_70
# %bb.71:
	cmp	rax, rcx
	ja	.LBB18_73
	jmp	.LBB18_75
.LBB18_72:
	xor	ecx, ecx
	cmp	rax, rcx
	jbe	.LBB18_75
.LBB18_73:
	mov	rdx, qword ptr [rip + xt_simd_flag]
	mov	rdi, rax
	shl	rdi, 4
	add	rdi, qword ptr [rip + xt_simd_tab]
	mov	rsi, rax
	.p2align	4, 0x90
.LBB18_74:                              # =>This Inner Loop Header: Depth=1
	movups	xmm0, xmmword ptr [rdi - 16]
	movups	xmmword ptr [rdi], xmm0
	add	rdi, -16
	movzx	r8d, byte ptr [rdx + rsi - 1]
	mov	byte ptr [rdx + rsi], r8b
	dec	rsi
	cmp	rsi, rcx
	ja	.LBB18_74
.LBB18_75:
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
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB18_77
# %bb.76:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB18_77:
	mov	rax, rbx
	add	rsp, 8
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	pop	rbp
	ret
.LBB18_36:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB18_38
# %bb.37:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB18_38
.LBB18_60:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB18_62
# %bb.61:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB18_62
.LBB18_48:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB18_50
# %bb.49:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB18_50
.LBB18_63:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB18_65
# %bb.64:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB18_65
.Lfunc_end18:
	.size	_xtc_alloc_aligned, .Lfunc_end18-_xtc_alloc_aligned
                                        # -- End function
	.globl	_xtc_alloc_line                 # -- Begin function _xtc_alloc_line
	.p2align	4, 0x90
	.type	_xtc_alloc_line,@function
_xtc_alloc_line:                        # @_xtc_alloc_line
# %bb.0:
	push	r14
	push	rbx
	push	rax
	mov	r14, rsi
	mov	rbx, rdi
	test	rsi, rsi
	je	.LBB19_3
# %bb.1:
	mov	rax, -1048577
	xor	edx, edx
	div	r14
	cmp	rax, rbx
	jae	.LBB19_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB19_3:
	mov	rdi, r14
	imul	rdi, rbx
	add	rdi, 112
	call	_xt_calloc
	test	rax, rax
	je	.LBB19_4
# %bb.5:
	mov	rcx, rax
	add	rax, 111
	and	rax, -64
	movabs	rdx, 5776887619
	mov	qword ptr [rax - 8], rdx
	mov	qword ptr [rax - 40], r14
	mov	qword ptr [rax - 32], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax - 24], xmm0
	mov	qword ptr [rax - 48], rcx
	jmp	.LBB19_6
.LBB19_4:
	xor	eax, eax
.LBB19_6:
	add	rsp, 8
	pop	rbx
	pop	r14
	ret
.Lfunc_end19:
	.size	_xtc_alloc_line, .Lfunc_end19-_xtc_alloc_line
                                        # -- End function
	.globl	_xtc_new_simd_u8                # -- Begin function _xtc_new_simd_u8
	.p2align	4, 0x90
	.type	_xtc_new_simd_u8,@function
_xtc_new_simd_u8:                       # @_xtc_new_simd_u8
# %bb.0:
	mov	esi, 1
	xor	edx, edx
	jmp	_xtc_alloc_aligned              # TAILCALL
.Lfunc_end20:
	.size	_xtc_new_simd_u8, .Lfunc_end20-_xtc_new_simd_u8
                                        # -- End function
	.globl	_xtc_new_simd_i8                # -- Begin function _xtc_new_simd_i8
	.p2align	4, 0x90
	.type	_xtc_new_simd_i8,@function
_xtc_new_simd_i8:                       # @_xtc_new_simd_i8
# %bb.0:
	mov	esi, 1
	xor	edx, edx
	jmp	_xtc_alloc_aligned              # TAILCALL
.Lfunc_end21:
	.size	_xtc_new_simd_i8, .Lfunc_end21-_xtc_new_simd_i8
                                        # -- End function
	.globl	_xtc_new_simd_bool              # -- Begin function _xtc_new_simd_bool
	.p2align	4, 0x90
	.type	_xtc_new_simd_bool,@function
_xtc_new_simd_bool:                     # @_xtc_new_simd_bool
# %bb.0:
	mov	esi, 1
	xor	edx, edx
	jmp	_xtc_alloc_aligned              # TAILCALL
.Lfunc_end22:
	.size	_xtc_new_simd_bool, .Lfunc_end22-_xtc_new_simd_bool
                                        # -- End function
	.globl	_xtc_new_simd_u16               # -- Begin function _xtc_new_simd_u16
	.p2align	4, 0x90
	.type	_xtc_new_simd_u16,@function
_xtc_new_simd_u16:                      # @_xtc_new_simd_u16
# %bb.0:
	mov	esi, 2
	xor	edx, edx
	jmp	_xtc_alloc_aligned              # TAILCALL
.Lfunc_end23:
	.size	_xtc_new_simd_u16, .Lfunc_end23-_xtc_new_simd_u16
                                        # -- End function
	.globl	_xtc_new_simd_i16               # -- Begin function _xtc_new_simd_i16
	.p2align	4, 0x90
	.type	_xtc_new_simd_i16,@function
_xtc_new_simd_i16:                      # @_xtc_new_simd_i16
# %bb.0:
	mov	esi, 2
	xor	edx, edx
	jmp	_xtc_alloc_aligned              # TAILCALL
.Lfunc_end24:
	.size	_xtc_new_simd_i16, .Lfunc_end24-_xtc_new_simd_i16
                                        # -- End function
	.globl	_xtc_new_simd_u32               # -- Begin function _xtc_new_simd_u32
	.p2align	4, 0x90
	.type	_xtc_new_simd_u32,@function
_xtc_new_simd_u32:                      # @_xtc_new_simd_u32
# %bb.0:
	mov	esi, 4
	xor	edx, edx
	jmp	_xtc_alloc_aligned              # TAILCALL
.Lfunc_end25:
	.size	_xtc_new_simd_u32, .Lfunc_end25-_xtc_new_simd_u32
                                        # -- End function
	.globl	_xtc_new_simd_i32               # -- Begin function _xtc_new_simd_i32
	.p2align	4, 0x90
	.type	_xtc_new_simd_i32,@function
_xtc_new_simd_i32:                      # @_xtc_new_simd_i32
# %bb.0:
	mov	esi, 4
	xor	edx, edx
	jmp	_xtc_alloc_aligned              # TAILCALL
.Lfunc_end26:
	.size	_xtc_new_simd_i32, .Lfunc_end26-_xtc_new_simd_i32
                                        # -- End function
	.globl	_xtc_new_simd_float             # -- Begin function _xtc_new_simd_float
	.p2align	4, 0x90
	.type	_xtc_new_simd_float,@function
_xtc_new_simd_float:                    # @_xtc_new_simd_float
# %bb.0:
	mov	esi, 4
	xor	edx, edx
	jmp	_xtc_alloc_aligned              # TAILCALL
.Lfunc_end27:
	.size	_xtc_new_simd_float, .Lfunc_end27-_xtc_new_simd_float
                                        # -- End function
	.globl	_xtc_new_simd_u64               # -- Begin function _xtc_new_simd_u64
	.p2align	4, 0x90
	.type	_xtc_new_simd_u64,@function
_xtc_new_simd_u64:                      # @_xtc_new_simd_u64
# %bb.0:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned              # TAILCALL
.Lfunc_end28:
	.size	_xtc_new_simd_u64, .Lfunc_end28-_xtc_new_simd_u64
                                        # -- End function
	.globl	_xtc_new_simd_i64               # -- Begin function _xtc_new_simd_i64
	.p2align	4, 0x90
	.type	_xtc_new_simd_i64,@function
_xtc_new_simd_i64:                      # @_xtc_new_simd_i64
# %bb.0:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned              # TAILCALL
.Lfunc_end29:
	.size	_xtc_new_simd_i64, .Lfunc_end29-_xtc_new_simd_i64
                                        # -- End function
	.globl	_xtc_new_simd_double            # -- Begin function _xtc_new_simd_double
	.p2align	4, 0x90
	.type	_xtc_new_simd_double,@function
_xtc_new_simd_double:                   # @_xtc_new_simd_double
# %bb.0:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned              # TAILCALL
.Lfunc_end30:
	.size	_xtc_new_simd_double, .Lfunc_end30-_xtc_new_simd_double
                                        # -- End function
	.globl	_xtc_new_simd_pointer           # -- Begin function _xtc_new_simd_pointer
	.p2align	4, 0x90
	.type	_xtc_new_simd_pointer,@function
_xtc_new_simd_pointer:                  # @_xtc_new_simd_pointer
# %bb.0:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned              # TAILCALL
.Lfunc_end31:
	.size	_xtc_new_simd_pointer, .Lfunc_end31-_xtc_new_simd_pointer
                                        # -- End function
	.globl	_xtc_new_simd_string            # -- Begin function _xtc_new_simd_string
	.p2align	4, 0x90
	.type	_xtc_new_simd_string,@function
_xtc_new_simd_string:                   # @_xtc_new_simd_string
# %bb.0:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned              # TAILCALL
.Lfunc_end32:
	.size	_xtc_new_simd_string, .Lfunc_end32-_xtc_new_simd_string
                                        # -- End function
	.globl	_xtc_new_u8                     # -- Begin function _xtc_new_u8
	.p2align	4, 0x90
	.type	_xtc_new_u8,@function
_xtc_new_u8:                            # @_xtc_new_u8
# %bb.0:
	cmp	rdi, 65536
	jb	.LBB33_2
# %bb.1:
	mov	esi, 1
	xor	edx, edx
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB33_2:
	push	rbx
	cmp	rdi, 1024
	jb	.LBB33_5
# %bb.3:
	mov	rbx, rdi
	add	rdi, 112
	call	_xt_calloc
	test	rax, rax
	je	.LBB33_8
# %bb.4:
	mov	rcx, rax
	add	rax, 111
	and	rax, -64
	movabs	rdx, 5776887619
	mov	qword ptr [rax - 8], rdx
	mov	qword ptr [rax - 40], 1
	mov	qword ptr [rax - 32], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax - 24], xmm0
	mov	qword ptr [rax - 48], rcx
	pop	rbx
	ret
.LBB33_5:
	cmp	rdi, 17
	mov	eax, 16
	mov	rbx, rdi
	cmovae	rax, rdi
	add	rax, 40
	mov	rdi, rax
	call	_xt_calloc
	test	rax, rax
	je	.LBB33_8
# %bb.6:
	movabs	rcx, 5776887618
	mov	qword ptr [rax + 32], rcx
	mov	qword ptr [rax], 1
	mov	qword ptr [rax + 8], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 16], xmm0
	add	rax, 40
	pop	rbx
	ret
.LBB33_8:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end33:
	.size	_xtc_new_u8, .Lfunc_end33-_xtc_new_u8
                                        # -- End function
	.globl	_xtc_new_i8                     # -- Begin function _xtc_new_i8
	.p2align	4, 0x90
	.type	_xtc_new_i8,@function
_xtc_new_i8:                            # @_xtc_new_i8
# %bb.0:
	cmp	rdi, 65536
	jb	.LBB34_2
# %bb.1:
	mov	esi, 1
	xor	edx, edx
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB34_2:
	push	rbx
	cmp	rdi, 1024
	jb	.LBB34_5
# %bb.3:
	mov	rbx, rdi
	add	rdi, 112
	call	_xt_calloc
	test	rax, rax
	je	.LBB34_8
# %bb.4:
	mov	rcx, rax
	add	rax, 111
	and	rax, -64
	movabs	rdx, 5776887619
	mov	qword ptr [rax - 8], rdx
	mov	qword ptr [rax - 40], 1
	mov	qword ptr [rax - 32], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax - 24], xmm0
	mov	qword ptr [rax - 48], rcx
	pop	rbx
	ret
.LBB34_5:
	cmp	rdi, 17
	mov	eax, 16
	mov	rbx, rdi
	cmovae	rax, rdi
	add	rax, 40
	mov	rdi, rax
	call	_xt_calloc
	test	rax, rax
	je	.LBB34_8
# %bb.6:
	movabs	rcx, 5776887618
	mov	qword ptr [rax + 32], rcx
	mov	qword ptr [rax], 1
	mov	qword ptr [rax + 8], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 16], xmm0
	add	rax, 40
	pop	rbx
	ret
.LBB34_8:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end34:
	.size	_xtc_new_i8, .Lfunc_end34-_xtc_new_i8
                                        # -- End function
	.globl	_xtc_new_u16                    # -- Begin function _xtc_new_u16
	.p2align	4, 0x90
	.type	_xtc_new_u16,@function
_xtc_new_u16:                           # @_xtc_new_u16
# %bb.0:
	push	r14
	push	rbx
	push	rax
	lea	rbx, [rdi + rdi]
	cmp	rbx, 65536
	jb	.LBB35_2
# %bb.1:
	mov	esi, 2
	xor	edx, edx
	add	rsp, 8
	pop	rbx
	pop	r14
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB35_2:
	movabs	rax, 9223372036854251520
	mov	r14, rdi
	cmp	rbx, 1024
	jb	.LBB35_7
# %bb.3:
	cmp	rdi, rax
	jb	.LBB35_5
# %bb.4:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB35_5:
	add	rbx, 112
	mov	rdi, rbx
	call	_xt_calloc
	test	rax, rax
	je	.LBB35_12
# %bb.6:
	mov	rcx, rax
	add	rax, 111
	and	rax, -64
	movabs	rdx, 5776887619
	mov	qword ptr [rax - 8], rdx
	mov	qword ptr [rax - 40], 2
	mov	qword ptr [rax - 32], r14
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax - 24], xmm0
	mov	qword ptr [rax - 48], rcx
	jmp	.LBB35_13
.LBB35_7:
	cmp	rdi, rax
	jb	.LBB35_9
# %bb.8:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB35_9:
	cmp	rbx, 17
	mov	edi, 16
	cmovae	rdi, rbx
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB35_12
# %bb.10:
	movabs	rcx, 5776887618
	mov	qword ptr [rax + 32], rcx
	mov	qword ptr [rax], 2
	mov	qword ptr [rax + 8], r14
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 16], xmm0
	add	rax, 40
	jmp	.LBB35_13
.LBB35_12:
	xor	eax, eax
.LBB35_13:
	add	rsp, 8
	pop	rbx
	pop	r14
	ret
.Lfunc_end35:
	.size	_xtc_new_u16, .Lfunc_end35-_xtc_new_u16
                                        # -- End function
	.globl	_xtc_new_i16                    # -- Begin function _xtc_new_i16
	.p2align	4, 0x90
	.type	_xtc_new_i16,@function
_xtc_new_i16:                           # @_xtc_new_i16
# %bb.0:
	push	r14
	push	rbx
	push	rax
	lea	rbx, [rdi + rdi]
	cmp	rbx, 65536
	jb	.LBB36_2
# %bb.1:
	mov	esi, 2
	xor	edx, edx
	add	rsp, 8
	pop	rbx
	pop	r14
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB36_2:
	movabs	rax, 9223372036854251520
	mov	r14, rdi
	cmp	rbx, 1024
	jb	.LBB36_7
# %bb.3:
	cmp	rdi, rax
	jb	.LBB36_5
# %bb.4:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB36_5:
	add	rbx, 112
	mov	rdi, rbx
	call	_xt_calloc
	test	rax, rax
	je	.LBB36_12
# %bb.6:
	mov	rcx, rax
	add	rax, 111
	and	rax, -64
	movabs	rdx, 5776887619
	mov	qword ptr [rax - 8], rdx
	mov	qword ptr [rax - 40], 2
	mov	qword ptr [rax - 32], r14
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax - 24], xmm0
	mov	qword ptr [rax - 48], rcx
	jmp	.LBB36_13
.LBB36_7:
	cmp	rdi, rax
	jb	.LBB36_9
# %bb.8:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB36_9:
	cmp	rbx, 17
	mov	edi, 16
	cmovae	rdi, rbx
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB36_12
# %bb.10:
	movabs	rcx, 5776887618
	mov	qword ptr [rax + 32], rcx
	mov	qword ptr [rax], 2
	mov	qword ptr [rax + 8], r14
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 16], xmm0
	add	rax, 40
	jmp	.LBB36_13
.LBB36_12:
	xor	eax, eax
.LBB36_13:
	add	rsp, 8
	pop	rbx
	pop	r14
	ret
.Lfunc_end36:
	.size	_xtc_new_i16, .Lfunc_end36-_xtc_new_i16
                                        # -- End function
	.globl	_xtc_new_u32                    # -- Begin function _xtc_new_u32
	.p2align	4, 0x90
	.type	_xtc_new_u32,@function
_xtc_new_u32:                           # @_xtc_new_u32
# %bb.0:
	push	r14
	push	rbx
	push	rax
	lea	rbx, [4*rdi]
	cmp	rbx, 65536
	jb	.LBB37_2
# %bb.1:
	mov	esi, 4
	xor	edx, edx
	add	rsp, 8
	pop	rbx
	pop	r14
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB37_2:
	movabs	rax, 4611686018427125760
	mov	r14, rdi
	cmp	rbx, 1024
	jb	.LBB37_7
# %bb.3:
	cmp	rdi, rax
	jb	.LBB37_5
# %bb.4:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB37_5:
	add	rbx, 112
	mov	rdi, rbx
	call	_xt_calloc
	test	rax, rax
	je	.LBB37_12
# %bb.6:
	mov	rcx, rax
	add	rax, 111
	and	rax, -64
	movabs	rdx, 5776887619
	mov	qword ptr [rax - 8], rdx
	mov	qword ptr [rax - 40], 4
	mov	qword ptr [rax - 32], r14
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax - 24], xmm0
	mov	qword ptr [rax - 48], rcx
	jmp	.LBB37_13
.LBB37_7:
	cmp	rdi, rax
	jb	.LBB37_9
# %bb.8:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB37_9:
	cmp	rbx, 17
	mov	edi, 16
	cmovae	rdi, rbx
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB37_12
# %bb.10:
	movabs	rcx, 5776887618
	mov	qword ptr [rax + 32], rcx
	mov	qword ptr [rax], 4
	mov	qword ptr [rax + 8], r14
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 16], xmm0
	add	rax, 40
	jmp	.LBB37_13
.LBB37_12:
	xor	eax, eax
.LBB37_13:
	add	rsp, 8
	pop	rbx
	pop	r14
	ret
.Lfunc_end37:
	.size	_xtc_new_u32, .Lfunc_end37-_xtc_new_u32
                                        # -- End function
	.globl	_xtc_new_i32                    # -- Begin function _xtc_new_i32
	.p2align	4, 0x90
	.type	_xtc_new_i32,@function
_xtc_new_i32:                           # @_xtc_new_i32
# %bb.0:
	push	r14
	push	rbx
	push	rax
	lea	rbx, [4*rdi]
	cmp	rbx, 65536
	jb	.LBB38_2
# %bb.1:
	mov	esi, 4
	xor	edx, edx
	add	rsp, 8
	pop	rbx
	pop	r14
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB38_2:
	movabs	rax, 4611686018427125760
	mov	r14, rdi
	cmp	rbx, 1024
	jb	.LBB38_7
# %bb.3:
	cmp	rdi, rax
	jb	.LBB38_5
# %bb.4:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB38_5:
	add	rbx, 112
	mov	rdi, rbx
	call	_xt_calloc
	test	rax, rax
	je	.LBB38_12
# %bb.6:
	mov	rcx, rax
	add	rax, 111
	and	rax, -64
	movabs	rdx, 5776887619
	mov	qword ptr [rax - 8], rdx
	mov	qword ptr [rax - 40], 4
	mov	qword ptr [rax - 32], r14
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax - 24], xmm0
	mov	qword ptr [rax - 48], rcx
	jmp	.LBB38_13
.LBB38_7:
	cmp	rdi, rax
	jb	.LBB38_9
# %bb.8:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB38_9:
	cmp	rbx, 17
	mov	edi, 16
	cmovae	rdi, rbx
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB38_12
# %bb.10:
	movabs	rcx, 5776887618
	mov	qword ptr [rax + 32], rcx
	mov	qword ptr [rax], 4
	mov	qword ptr [rax + 8], r14
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 16], xmm0
	add	rax, 40
	jmp	.LBB38_13
.LBB38_12:
	xor	eax, eax
.LBB38_13:
	add	rsp, 8
	pop	rbx
	pop	r14
	ret
.Lfunc_end38:
	.size	_xtc_new_i32, .Lfunc_end38-_xtc_new_i32
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
	jb	.LBB39_2
# %bb.1:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB39_2:
	lea	rax, [8*rbx]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB39_3
# %bb.4:
	movabs	rcx, 5776887618
	mov	qword ptr [rax + 32], rcx
	mov	qword ptr [rax], 8
	mov	qword ptr [rax + 8], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 16], xmm0
	add	rax, 40
	pop	rbx
	ret
.LBB39_3:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end39:
	.size	_xtc_new_pointer, .Lfunc_end39-_xtc_new_pointer
                                        # -- End function
	.globl	_xtc_new_u64                    # -- Begin function _xtc_new_u64
	.p2align	4, 0x90
	.type	_xtc_new_u64,@function
_xtc_new_u64:                           # @_xtc_new_u64
# %bb.0:
	push	r14
	push	rbx
	push	rax
	lea	rbx, [8*rdi]
	cmp	rbx, 65536
	jb	.LBB40_2
# %bb.1:
	mov	esi, 8
	xor	edx, edx
	add	rsp, 8
	pop	rbx
	pop	r14
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB40_2:
	movabs	rax, 2305843009213562880
	mov	r14, rdi
	cmp	rbx, 1024
	jb	.LBB40_7
# %bb.3:
	cmp	rdi, rax
	jb	.LBB40_5
# %bb.4:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB40_5:
	add	rbx, 112
	mov	rdi, rbx
	call	_xt_calloc
	test	rax, rax
	je	.LBB40_12
# %bb.6:
	mov	rcx, rax
	add	rax, 111
	and	rax, -64
	movabs	rdx, 5776887619
	mov	qword ptr [rax - 8], rdx
	mov	qword ptr [rax - 40], 8
	mov	qword ptr [rax - 32], r14
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax - 24], xmm0
	mov	qword ptr [rax - 48], rcx
	jmp	.LBB40_13
.LBB40_7:
	cmp	rdi, rax
	jb	.LBB40_9
# %bb.8:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB40_9:
	cmp	rbx, 17
	mov	edi, 16
	cmovae	rdi, rbx
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB40_12
# %bb.10:
	movabs	rcx, 5776887618
	mov	qword ptr [rax + 32], rcx
	mov	qword ptr [rax], 8
	mov	qword ptr [rax + 8], r14
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 16], xmm0
	add	rax, 40
	jmp	.LBB40_13
.LBB40_12:
	xor	eax, eax
.LBB40_13:
	add	rsp, 8
	pop	rbx
	pop	r14
	ret
.Lfunc_end40:
	.size	_xtc_new_u64, .Lfunc_end40-_xtc_new_u64
                                        # -- End function
	.globl	_xtc_new_i64                    # -- Begin function _xtc_new_i64
	.p2align	4, 0x90
	.type	_xtc_new_i64,@function
_xtc_new_i64:                           # @_xtc_new_i64
# %bb.0:
	push	r14
	push	rbx
	push	rax
	lea	rbx, [8*rdi]
	cmp	rbx, 65536
	jb	.LBB41_2
# %bb.1:
	mov	esi, 8
	xor	edx, edx
	add	rsp, 8
	pop	rbx
	pop	r14
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB41_2:
	movabs	rax, 2305843009213562880
	mov	r14, rdi
	cmp	rbx, 1024
	jb	.LBB41_7
# %bb.3:
	cmp	rdi, rax
	jb	.LBB41_5
# %bb.4:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB41_5:
	add	rbx, 112
	mov	rdi, rbx
	call	_xt_calloc
	test	rax, rax
	je	.LBB41_12
# %bb.6:
	mov	rcx, rax
	add	rax, 111
	and	rax, -64
	movabs	rdx, 5776887619
	mov	qword ptr [rax - 8], rdx
	mov	qword ptr [rax - 40], 8
	mov	qword ptr [rax - 32], r14
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax - 24], xmm0
	mov	qword ptr [rax - 48], rcx
	jmp	.LBB41_13
.LBB41_7:
	cmp	rdi, rax
	jb	.LBB41_9
# %bb.8:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB41_9:
	cmp	rbx, 17
	mov	edi, 16
	cmovae	rdi, rbx
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB41_12
# %bb.10:
	movabs	rcx, 5776887618
	mov	qword ptr [rax + 32], rcx
	mov	qword ptr [rax], 8
	mov	qword ptr [rax + 8], r14
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 16], xmm0
	add	rax, 40
	jmp	.LBB41_13
.LBB41_12:
	xor	eax, eax
.LBB41_13:
	add	rsp, 8
	pop	rbx
	pop	r14
	ret
.Lfunc_end41:
	.size	_xtc_new_i64, .Lfunc_end41-_xtc_new_i64
                                        # -- End function
	.globl	_xtc_new_bool                   # -- Begin function _xtc_new_bool
	.p2align	4, 0x90
	.type	_xtc_new_bool,@function
_xtc_new_bool:                          # @_xtc_new_bool
# %bb.0:
	cmp	rdi, 65536
	jb	.LBB42_2
# %bb.1:
	mov	esi, 1
	xor	edx, edx
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB42_2:
	push	rbx
	cmp	rdi, 1024
	jb	.LBB42_5
# %bb.3:
	mov	rbx, rdi
	add	rdi, 112
	call	_xt_calloc
	test	rax, rax
	je	.LBB42_8
# %bb.4:
	mov	rcx, rax
	add	rax, 111
	and	rax, -64
	movabs	rdx, 5776887619
	mov	qword ptr [rax - 8], rdx
	mov	qword ptr [rax - 40], 1
	mov	qword ptr [rax - 32], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax - 24], xmm0
	mov	qword ptr [rax - 48], rcx
	pop	rbx
	ret
.LBB42_5:
	cmp	rdi, 17
	mov	eax, 16
	mov	rbx, rdi
	cmovae	rax, rdi
	add	rax, 40
	mov	rdi, rax
	call	_xt_calloc
	test	rax, rax
	je	.LBB42_8
# %bb.6:
	movabs	rcx, 5776887618
	mov	qword ptr [rax + 32], rcx
	mov	qword ptr [rax], 1
	mov	qword ptr [rax + 8], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 16], xmm0
	add	rax, 40
	pop	rbx
	ret
.LBB42_8:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end42:
	.size	_xtc_new_bool, .Lfunc_end42-_xtc_new_bool
                                        # -- End function
	.globl	_xtc_new_float                  # -- Begin function _xtc_new_float
	.p2align	4, 0x90
	.type	_xtc_new_float,@function
_xtc_new_float:                         # @_xtc_new_float
# %bb.0:
	push	r14
	push	rbx
	push	rax
	lea	rbx, [4*rdi]
	cmp	rbx, 65536
	jb	.LBB43_2
# %bb.1:
	mov	esi, 4
	xor	edx, edx
	add	rsp, 8
	pop	rbx
	pop	r14
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB43_2:
	movabs	rax, 4611686018427125760
	mov	r14, rdi
	cmp	rbx, 1024
	jb	.LBB43_7
# %bb.3:
	cmp	rdi, rax
	jb	.LBB43_5
# %bb.4:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB43_5:
	add	rbx, 112
	mov	rdi, rbx
	call	_xt_calloc
	test	rax, rax
	je	.LBB43_12
# %bb.6:
	mov	rcx, rax
	add	rax, 111
	and	rax, -64
	movabs	rdx, 5776887619
	mov	qword ptr [rax - 8], rdx
	mov	qword ptr [rax - 40], 4
	mov	qword ptr [rax - 32], r14
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax - 24], xmm0
	mov	qword ptr [rax - 48], rcx
	jmp	.LBB43_13
.LBB43_7:
	cmp	rdi, rax
	jb	.LBB43_9
# %bb.8:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB43_9:
	cmp	rbx, 17
	mov	edi, 16
	cmovae	rdi, rbx
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB43_12
# %bb.10:
	movabs	rcx, 5776887618
	mov	qword ptr [rax + 32], rcx
	mov	qword ptr [rax], 4
	mov	qword ptr [rax + 8], r14
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 16], xmm0
	add	rax, 40
	jmp	.LBB43_13
.LBB43_12:
	xor	eax, eax
.LBB43_13:
	add	rsp, 8
	pop	rbx
	pop	r14
	ret
.Lfunc_end43:
	.size	_xtc_new_float, .Lfunc_end43-_xtc_new_float
                                        # -- End function
	.globl	_xtc_new_double                 # -- Begin function _xtc_new_double
	.p2align	4, 0x90
	.type	_xtc_new_double,@function
_xtc_new_double:                        # @_xtc_new_double
# %bb.0:
	push	r14
	push	rbx
	push	rax
	lea	rbx, [8*rdi]
	cmp	rbx, 65536
	jb	.LBB44_2
# %bb.1:
	mov	esi, 8
	xor	edx, edx
	add	rsp, 8
	pop	rbx
	pop	r14
	jmp	_xtc_alloc_aligned              # TAILCALL
.LBB44_2:
	movabs	rax, 2305843009213562880
	mov	r14, rdi
	cmp	rbx, 1024
	jb	.LBB44_7
# %bb.3:
	cmp	rdi, rax
	jb	.LBB44_5
# %bb.4:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB44_5:
	add	rbx, 112
	mov	rdi, rbx
	call	_xt_calloc
	test	rax, rax
	je	.LBB44_12
# %bb.6:
	mov	rcx, rax
	add	rax, 111
	and	rax, -64
	movabs	rdx, 5776887619
	mov	qword ptr [rax - 8], rdx
	mov	qword ptr [rax - 40], 8
	mov	qword ptr [rax - 32], r14
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax - 24], xmm0
	mov	qword ptr [rax - 48], rcx
	jmp	.LBB44_13
.LBB44_7:
	cmp	rdi, rax
	jb	.LBB44_9
# %bb.8:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB44_9:
	cmp	rbx, 17
	mov	edi, 16
	cmovae	rdi, rbx
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB44_12
# %bb.10:
	movabs	rcx, 5776887618
	mov	qword ptr [rax + 32], rcx
	mov	qword ptr [rax], 8
	mov	qword ptr [rax + 8], r14
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 16], xmm0
	add	rax, 40
	jmp	.LBB44_13
.LBB44_12:
	xor	eax, eax
.LBB44_13:
	add	rsp, 8
	pop	rbx
	pop	r14
	ret
.Lfunc_end44:
	.size	_xtc_new_double, .Lfunc_end44-_xtc_new_double
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
	jb	.LBB45_2
# %bb.1:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB45_2:
	lea	rax, [8*rbx]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc
	test	rax, rax
	je	.LBB45_3
# %bb.4:
	movabs	rcx, 5776887618
	mov	qword ptr [rax + 32], rcx
	mov	qword ptr [rax], 8
	mov	qword ptr [rax + 8], rbx
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 16], xmm0
	add	rax, 40
	pop	rbx
	ret
.LBB45_3:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end45:
	.size	_xtc_new_string, .Lfunc_end45-_xtc_new_string
                                        # -- End function
	.globl	_xtc_count                      # -- Begin function _xtc_count
	.p2align	4, 0x90
	.type	_xtc_count,@function
_xtc_count:                             # @_xtc_count
# %bb.0:
	mov	eax, dword ptr [rdi - 32]
	ret
.Lfunc_end46:
	.size	_xtc_count, .Lfunc_end46-_xtc_count
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
	mov	eax, dword ptr [rdi - 8]
	mov	ecx, eax
	and	ecx, -2
	cmp	ecx, 1481920334
	jne	.LBB47_9
# %bb.1:
	cmp	eax, 1481920335
	jne	.LBB47_3
# %bb.2:
	mov	rdi, rbx
	call	_xtc_weak_zero_for
.LBB47_3:
	mov	rax, qword ptr [rbx]
	mov	rax, qword ptr [rax + 24]
	test	rax, rax
	je	.LBB47_5
# %bb.4:
	mov	dword ptr [rbx - 4], -2147483648
	mov	rdi, rbx
	call	rax
.LBB47_5:
	mov	rax, qword ptr [rbx - 16]
	add	rbx, -16
	cmp	rax, 64
	jae	.LBB47_36
# %bb.6:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB47_20
	.p2align	4, 0x90
.LBB47_7:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB47_8 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB47_20
.LBB47_8:                               #   Parent Loop BB47_7 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB47_8
	jmp	.LBB47_7
.LBB47_9:
	mov	rdi, rbx
	call	_xtc_weak_zero_for
	mov	r15, qword ptr [rbx - 24]
	cmp	dword ptr [rbx - 8], 1481920323
	jne	.LBB47_25
# %bb.10:
	test	r15, r15
	je	.LBB47_12
# %bb.11:
	mov	rdi, rbx
	call	r15
.LBB47_12:
	mov	rax, rbx
	shl	rax, 50
	jne	.LBB47_46
# %bb.13:
	mov	rdi, rbx
	call	_xtc_simd_unwatch
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB47_15
	jmp	.LBB47_16
	.p2align	4, 0x90
.LBB47_14:                              #   Parent Loop BB47_15 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB47_14
.LBB47_15:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB47_14 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	jne	.LBB47_14
.LBB47_16:
	mov	rax, qword ptr [rip + xt_simd_n]
	test	rax, rax
	je	.LBB47_38
# %bb.17:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	ecx, ecx
	movabs	rsi, 2305843009213693950
	mov	rdi, rax
	.p2align	4, 0x90
.LBB47_18:                              # =>This Inner Loop Header: Depth=1
	lea	r8, [rdi + rcx]
	mov	r9, r8
	shr	r9
	and	r8, rsi
	cmp	qword ptr [rdx + 8*r8], rbx
	lea	r8, [r9 + 1]
	cmova	rdi, r9
	cmovbe	rcx, r8
	cmp	rcx, rdi
	jb	.LBB47_18
# %bb.19:
	test	rcx, rcx
	jne	.LBB47_39
	jmp	.LBB47_44
.LBB47_25:
	test	r15, r15
	je	.LBB47_29
# %bb.26:
	mov	r12, qword ptr [rbx - 40]
	mov	r13, qword ptr [rbx - 32]
	mov	dword ptr [rbx - 4], -2147483648
	test	r13, r13
	je	.LBB47_29
# %bb.27:
	mov	r14, rbx
	.p2align	4, 0x90
.LBB47_28:                              # =>This Inner Loop Header: Depth=1
	mov	rdi, r14
	call	r15
	add	r14, r12
	dec	r13
	jne	.LBB47_28
.LBB47_29:
	mov	rax, qword ptr [rbx - 48]
	add	rbx, -48
	cmp	rax, 64
	jae	.LBB47_36
# %bb.30:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB47_20
	.p2align	4, 0x90
.LBB47_31:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB47_32 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB47_20
.LBB47_32:                              #   Parent Loop BB47_31 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB47_32
	jmp	.LBB47_31
.LBB47_20:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB47_21
# %bb.34:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB47_36
# %bb.35:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB47_36:
	mov	rdi, rbx
.LBB47_37:
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	jmp	free@PLT                        # TAILCALL
.LBB47_21:
	lea	rsi, [rip + xt_cache]
	mov	rdi, qword ptr [rsi + 8*rax]
	mov	qword ptr [rbx], rdi
	mov	qword ptr [rsi + 8*rax], rbx
.LBB47_22:
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB47_24
# %bb.23:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB47_24
.LBB47_38:
	xor	ecx, ecx
	test	rcx, rcx
	je	.LBB47_44
.LBB47_39:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	mov	rdi, rcx
	shl	rdi, 4
	cmp	qword ptr [rdx + rdi - 16], rbx
	jne	.LBB47_44
# %bb.40:
	cmp	rcx, rax
	jae	.LBB47_43
# %bb.41:
	mov	rsi, qword ptr [rip + xt_simd_flag]
	add	rdx, rdi
	.p2align	4, 0x90
.LBB47_42:                              # =>This Inner Loop Header: Depth=1
	movups	xmm0, xmmword ptr [rdx]
	movups	xmmword ptr [rdx - 16], xmm0
	movzx	edi, byte ptr [rsi + rcx]
	mov	byte ptr [rsi + rcx - 1], dil
	inc	rcx
	add	rdx, 16
	cmp	rax, rcx
	jne	.LBB47_42
.LBB47_43:
	dec	rax
	mov	qword ptr [rip + xt_simd_n], rax
.LBB47_44:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB47_46
# %bb.45:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB47_46:
	mov	rdi, qword ptr [rbx - 48]
	test	rdi, rdi
	je	.LBB47_24
# %bb.47:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	.LBB47_37
# %bb.48:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB47_51
	.p2align	4, 0x90
.LBB47_49:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB47_50 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB47_51
.LBB47_50:                              #   Parent Loop BB47_49 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB47_50
	jmp	.LBB47_49
.LBB47_24:
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	ret
.LBB47_51:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB47_54
# %bb.52:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB47_37
# %bb.53:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB47_37
.LBB47_54:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	jmp	.LBB47_22
.Lfunc_end47:
	.size	_xtc_dealloc, .Lfunc_end47-_xtc_dealloc
                                        # -- End function
	.globl	_xtc_weak_zero_for              # -- Begin function _xtc_weak_zero_for
	.p2align	4, 0x90
	.type	_xtc_weak_zero_for,@function
_xtc_weak_zero_for:                     # @_xtc_weak_zero_for
# %bb.0:
	test	rdi, rdi
	je	.LBB48_27
# %bb.1:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB48_4
	.p2align	4, 0x90
.LBB48_2:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB48_3 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB48_4
.LBB48_3:                               #   Parent Loop BB48_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB48_3
	jmp	.LBB48_2
.LBB48_4:
	mov	ecx, dword ptr [rdi - 8]
	mov	al, 1
	cmp	ecx, 1481920322
	je	.LBB48_14
# %bb.5:
	cmp	ecx, 1481920335
	jne	.LBB48_19
# %bb.6:
	mov	rcx, qword ptr [rip + xt_wtab_cap]
	test	rcx, rcx
	je	.LBB48_16
# %bb.7:
	mov	rdx, rdi
	shr	rdx, 3
	mov	rsi, rdi
	shr	rsi, 20
	xor	rsi, rdx
	mov	r8d, 3982152891
	imul	r8, rsi
	mov	rdx, r8
	shr	rdx, 11
	xor	rdx, r8
	dec	rcx
	and	rdx, rcx
	mov	r8, qword ptr [rip + xt_wtab]
                                        # implicit-def: $rsi
	jmp	.LBB48_10
	.p2align	4, 0x90
.LBB48_8:                               #   in Loop: Header=BB48_10 Depth=1
	add	r10, r8
	xor	r9d, r9d
	mov	rsi, r10
.LBB48_9:                               #   in Loop: Header=BB48_10 Depth=1
	test	r9b, r9b
	je	.LBB48_17
.LBB48_10:                              # =>This Inner Loop Header: Depth=1
	mov	r10, rdx
	shl	r10, 4
	mov	r9, qword ptr [r8 + r10]
	cmp	r9, rdi
	je	.LBB48_8
# %bb.11:                               #   in Loop: Header=BB48_10 Depth=1
	test	r9, r9
	je	.LBB48_13
# %bb.12:                               #   in Loop: Header=BB48_10 Depth=1
	inc	rdx
	and	rdx, rcx
	mov	r9b, 1
	jmp	.LBB48_9
	.p2align	4, 0x90
.LBB48_13:                              #   in Loop: Header=BB48_10 Depth=1
	xor	esi, esi
	xor	r9d, r9d
	jmp	.LBB48_9
.LBB48_14:
	add	rdi, -16
	test	rdi, rdi
	jne	.LBB48_20
	jmp	.LBB48_25
.LBB48_16:
	xor	esi, esi
.LBB48_17:
	test	rsi, rsi
	je	.LBB48_19
# %bb.18:
	mov	rdi, qword ptr [rsi + 8]
	mov	qword ptr [rsi], 1
	mov	qword ptr [rsi + 8], 0
	dec	qword ptr [rip + xt_wtab_n]
	xor	eax, eax
	test	rdi, rdi
	jne	.LBB48_20
	jmp	.LBB48_25
.LBB48_19:
	xor	edi, edi
	test	rdi, rdi
	je	.LBB48_25
.LBB48_20:
	mov	rcx, qword ptr [rdi]
	test	rcx, rcx
	je	.LBB48_23
# %bb.21:
	xorps	xmm0, xmm0
	.p2align	4, 0x90
.LBB48_22:                              # =>This Inner Loop Header: Depth=1
	mov	rdx, qword ptr [rcx - 8]
	movups	xmmword ptr [rcx - 16], xmm0
	mov	qword ptr [rcx], 0
	mov	rcx, rdx
	test	rdx, rdx
	jne	.LBB48_22
.LBB48_23:
	mov	qword ptr [rdi], 0
	test	al, al
	jne	.LBB48_25
# %bb.24:
	mov	rax, qword ptr [rip + xt_wcell_free]
	mov	qword ptr [rdi], rax
	mov	qword ptr [rip + xt_wcell_free], rdi
.LBB48_25:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB48_27
# %bb.26:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB48_27:
	ret
.Lfunc_end48:
	.size	_xtc_weak_zero_for, .Lfunc_end48-_xtc_weak_zero_for
                                        # -- End function
	.globl	_xtc_weak_unregister            # -- Begin function _xtc_weak_unregister
	.p2align	4, 0x90
	.type	_xtc_weak_unregister,@function
_xtc_weak_unregister:                   # @_xtc_weak_unregister
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
	mov	rax, qword ptr [rdi - 16]
	test	rax, rax
	je	.LBB49_8
# %bb.4:
	lea	rcx, [rdi - 16]
	cmp	qword ptr [rax], rdi
	jne	.LBB49_7
# %bb.5:
	mov	rdx, qword ptr [rdi - 8]
	mov	qword ptr [rax], rdx
	test	rdx, rdx
	je	.LBB49_7
# %bb.6:
	mov	qword ptr [rdx - 16], rax
.LBB49_7:
	xorps	xmm0, xmm0
	movups	xmmword ptr [rcx], xmm0
.LBB49_8:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB49_10
# %bb.9:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB49_10:
	ret
.Lfunc_end49:
	.size	_xtc_weak_unregister, .Lfunc_end49-_xtc_weak_unregister
                                        # -- End function
	.globl	_xtc_weak_register              # -- Begin function _xtc_weak_register
	.p2align	4, 0x90
	.type	_xtc_weak_register,@function
_xtc_weak_register:                     # @_xtc_weak_register
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB50_3
	.p2align	4, 0x90
.LBB50_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB50_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB50_3
.LBB50_2:                               #   Parent Loop BB50_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB50_2
	jmp	.LBB50_1
.LBB50_3:
	push	r15
	push	r14
	push	rbx
	mov	rax, qword ptr [rdi - 16]
	test	rax, rax
	je	.LBB50_8
# %bb.4:
	lea	rcx, [rdi - 16]
	cmp	qword ptr [rax], rdi
	jne	.LBB50_7
# %bb.5:
	mov	rdx, qword ptr [rdi - 8]
	mov	qword ptr [rax], rdx
	test	rdx, rdx
	je	.LBB50_7
# %bb.6:
	mov	qword ptr [rdx - 16], rax
.LBB50_7:
	xorps	xmm0, xmm0
	movups	xmmword ptr [rcx], xmm0
.LBB50_8:
	test	rsi, rsi
	je	.LBB50_11
# %bb.9:
	mov	eax, dword ptr [rsi - 8]
	cmp	eax, 1481920322
	jne	.LBB50_12
# %bb.10:
	add	rsi, -16
	test	rsi, rsi
	jne	.LBB50_35
	jmp	.LBB50_38
.LBB50_12:
	mov	ecx, eax
	and	ecx, -2
	cmp	ecx, 1481920334
	jne	.LBB50_11
# %bb.13:
	cmp	eax, 1481920335
	jne	.LBB50_23
# %bb.14:
	mov	rax, qword ptr [rip + xt_wtab_cap]
	test	rax, rax
	je	.LBB50_26
# %bb.15:
	mov	rcx, rsi
	shr	rcx, 3
	mov	rdx, rsi
	shr	rdx, 20
	xor	rdx, rcx
	mov	r8d, 3982152891
	imul	r8, rdx
	mov	rcx, r8
	shr	rcx, 11
	xor	rcx, r8
	dec	rax
	and	rcx, rax
	mov	r8, qword ptr [rip + xt_wtab]
                                        # implicit-def: $rdx
	jmp	.LBB50_18
	.p2align	4, 0x90
.LBB50_16:                              #   in Loop: Header=BB50_18 Depth=1
	add	r10, r8
	xor	r9d, r9d
	mov	rdx, r10
.LBB50_17:                              #   in Loop: Header=BB50_18 Depth=1
	test	r9b, r9b
	je	.LBB50_24
.LBB50_18:                              # =>This Inner Loop Header: Depth=1
	mov	r10, rcx
	shl	r10, 4
	mov	r9, qword ptr [r8 + r10]
	cmp	r9, rsi
	je	.LBB50_16
# %bb.19:                               #   in Loop: Header=BB50_18 Depth=1
	test	r9, r9
	je	.LBB50_21
# %bb.20:                               #   in Loop: Header=BB50_18 Depth=1
	inc	rcx
	and	rcx, rax
	mov	r9b, 1
	jmp	.LBB50_17
	.p2align	4, 0x90
.LBB50_21:                              #   in Loop: Header=BB50_18 Depth=1
	xor	edx, edx
	xor	r9d, r9d
	jmp	.LBB50_17
.LBB50_11:
	xor	esi, esi
	test	rsi, rsi
	je	.LBB50_38
.LBB50_35:
	mov	rax, qword ptr [rsi]
	mov	qword ptr [rdi - 16], rsi
	mov	qword ptr [rdi - 8], rax
	test	rax, rax
	je	.LBB50_37
# %bb.36:
	lea	rcx, [rdi - 8]
	mov	qword ptr [rax - 16], rcx
.LBB50_37:
	mov	qword ptr [rsi], rdi
.LBB50_38:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB50_40
# %bb.39:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB50_40:
	pop	rbx
	pop	r14
	pop	r15
	ret
.LBB50_23:
	xor	edx, edx
.LBB50_24:
	test	rdx, rdx
	je	.LBB50_27
.LBB50_25:
	mov	rsi, qword ptr [rdx + 8]
	test	rsi, rsi
	jne	.LBB50_35
	jmp	.LBB50_38
.LBB50_26:
	xor	edx, edx
	test	rdx, rdx
	jne	.LBB50_25
.LBB50_27:
	mov	r14, rdi
	cmp	qword ptr [rip + xt_wcell_free], 0
	jne	.LBB50_34
# %bb.28:
	mov	rbx, rsi
	mov	edi, 1
	mov	esi, 4104
	call	calloc@PLT
	test	rax, rax
	je	.LBB50_30
# %bb.29:
	mov	qword ptr [rax], 64
	add	rax, 8
	jmp	.LBB50_31
.LBB50_30:
	xor	eax, eax
.LBB50_31:
	lea	rcx, [rax + 8]
	mov	edx, 511
	mov	rsi, rbx
	.p2align	4, 0x90
.LBB50_32:                              # =>This Inner Loop Header: Depth=1
	mov	qword ptr [rcx - 8], rcx
	add	rcx, 8
	dec	rdx
	jne	.LBB50_32
# %bb.33:
	mov	qword ptr [rax + 4088], 0
	mov	qword ptr [rip + xt_wcell_free], rax
.LBB50_34:
	mov	rbx, qword ptr [rip + xt_wcell_free]
	mov	rax, qword ptr [rbx]
	mov	qword ptr [rip + xt_wcell_free], rax
	mov	qword ptr [rbx], 0
	mov	rdi, rsi
	mov	r15, rsi
	mov	rsi, rbx
	call	xt_wtab_put
	mov	rsi, rbx
	mov	dword ptr [r15 - 8], 1481920335
	mov	rdi, r14
	test	rsi, rsi
	jne	.LBB50_35
	jmp	.LBB50_38
.Lfunc_end50:
	.size	_xtc_weak_register, .Lfunc_end50-_xtc_weak_register
                                        # -- End function
	.globl	_xtc_weak_load                  # -- Begin function _xtc_weak_load
	.p2align	4, 0x90
	.type	_xtc_weak_load,@function
_xtc_weak_load:                         # @_xtc_weak_load
# %bb.0:
	mov	rax, qword ptr [rdi]
	ret
.Lfunc_end51:
	.size	_xtc_weak_load, .Lfunc_end51-_xtc_weak_load
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
.Lfunc_end52:
	.size	srandom, .Lfunc_end52-srandom
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
.Lfunc_end53:
	.size	random, .Lfunc_end53-random
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
.Lfunc_end54:
	.size	_xt_srand, .Lfunc_end54-_xt_srand
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
.Lfunc_end55:
	.size	_xt_rand_u32, .Lfunc_end55-_xt_rand_u32
                                        # -- End function
	.section	.rodata.cst4,"aM",@progbits,4
	.p2align	2, 0x0                          # -- Begin function _xt_rand_f
.LCPI56_0:
	.long	0x30000000                      # float 4.65661287E-10
.LCPI56_1:
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
	mulss	xmm0, dword ptr [rip + .LCPI56_0]
	movss	xmm1, dword ptr [rip + .LCPI56_1] # xmm1 = [5.0E-1,0.0E+0,0.0E+0,0.0E+0]
	mulss	xmm0, xmm1
	addss	xmm0, xmm1
	ret
.Lfunc_end56:
	.size	_xt_rand_f, .Lfunc_end56-_xt_rand_f
                                        # -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          # -- Begin function _xt_rand_d
.LCPI57_0:
	.quad	0x3e00000000000000              # double 4.6566128730773926E-10
.LCPI57_1:
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
	mulsd	xmm0, qword ptr [rip + .LCPI57_0]
	movsd	xmm1, qword ptr [rip + .LCPI57_1] # xmm1 = [5.0E-1,0.0E+0]
	mulsd	xmm0, xmm1
	addsd	xmm0, xmm1
	ret
.Lfunc_end57:
	.size	_xt_rand_d, .Lfunc_end57-_xt_rand_d
                                        # -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          # -- Begin function _xt_clk_reset
.LCPI58_0:
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
	call	_sys_clock_gettime@PLT
	cvtsi2sd	xmm0, qword ptr [rsp]
	cvtsi2sd	xmm1, qword ptr [rsp + 8]
	mulsd	xmm1, qword ptr [rip + .LCPI58_0]
	addsd	xmm1, xmm0
	movsd	qword ptr [rip + xt_clk_origin], xmm1
	add	rsp, 24
	ret
.Lfunc_end58:
	.size	_xt_clk_reset, .Lfunc_end58-_xt_clk_reset
                                        # -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          # -- Begin function _xt_clk_ticks
.LCPI59_0:
	.quad	0x3e112e0be826d695              # double 1.0000000000000001E-9
.LCPI59_1:
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
	call	_sys_clock_gettime@PLT
	cvtsi2sd	xmm0, qword ptr [rsp]
	cvtsi2sd	xmm1, qword ptr [rsp + 8]
	mulsd	xmm1, qword ptr [rip + .LCPI59_0]
	addsd	xmm1, xmm0
	subsd	xmm1, qword ptr [rip + xt_clk_origin]
	mulsd	xmm1, qword ptr [rip + .LCPI59_1]
	cvttsd2si	rax, xmm1
                                        # kill: def $eax killed $eax killed $rax
	add	rsp, 24
	ret
.Lfunc_end59:
	.size	_xt_clk_ticks, .Lfunc_end59-_xt_clk_ticks
                                        # -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          # -- Begin function _xt_clk_delay
.LCPI60_0:
	.quad	0x404e000000000000              # double 60
.LCPI60_1:
	.quad	0x41cdcd6500000000              # double 1.0E+9
.LCPI60_2:
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
	divsd	xmm0, qword ptr [rip + .LCPI60_0]
	mulsd	xmm0, qword ptr [rip + .LCPI60_1]
	cvttsd2si	rax, xmm0
	mov	rcx, rax
	sar	rcx, 63
	subsd	xmm0, qword ptr [rip + .LCPI60_2]
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
.Lfunc_end60:
	.size	_xt_clk_delay, .Lfunc_end60-_xt_clk_delay
                                        # -- End function
	.globl	_xtc_bank                       # -- Begin function _xtc_bank
	.p2align	4, 0x90
	.type	_xtc_bank,@function
_xtc_bank:                              # @_xtc_bank
# %bb.0:
	cmp	dil, 1
	jbe	.LBB61_2
# %bb.1:
	xor	eax, eax
	ret
.LBB61_2:
	push	rbx
	movzx	eax, dil
	shl	eax, 11
	lea	rcx, [rip + xt_bank_regions]
	add	rcx, rax
	movzx	eax, sil
	lea	rbx, [rcx + 8*rax]
	cmp	qword ptr [rcx + 8*rax], 0
	jne	.LBB61_7
# %bb.3:
	mov	edi, 1
	mov	esi, 12296
	call	calloc@PLT
	test	rax, rax
	je	.LBB61_4
# %bb.5:
	mov	qword ptr [rax], 64
	add	rax, 8
	jmp	.LBB61_6
.LBB61_4:
	xor	eax, eax
.LBB61_6:
	mov	qword ptr [rbx], rax
.LBB61_7:
	mov	rax, qword ptr [rbx]
	pop	rbx
	ret
.Lfunc_end61:
	.size	_xtc_bank, .Lfunc_end61-_xtc_bank
                                        # -- End function
	.globl	_xt_threads_multi               # -- Begin function _xt_threads_multi
	.p2align	4, 0x90
	.type	_xt_threads_multi,@function
_xt_threads_multi:                      # @_xt_threads_multi
# %bb.0:
	mov	eax, dword ptr [rip + _xt_threads_active]
	ret
.Lfunc_end62:
	.size	_xt_threads_multi, .Lfunc_end62-_xt_threads_multi
                                        # -- End function
	.globl	_xt_thread_create               # -- Begin function _xt_thread_create
	.p2align	4, 0x90
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
	je	.LBB63_74
# %bb.1:
	mov	r12, rsi
	mov	r13, rdi
	call	_xt_libc_addr@PLT
	mov	byte ptr [rax + 1], 1
	mov	byte ptr [rax + 3], 1
	mov	dword ptr [rax + 4], 1
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_3
# %bb.2:
	call	xt_reap_sweep
.LBB63_3:
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
	jb	.LBB63_75
# %bb.4:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_7
	.p2align	4, 0x90
.LBB63_5:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB63_6 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB63_7
.LBB63_6:                               #   Parent Loop BB63_5 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB63_6
	jmp	.LBB63_5
.LBB63_7:
	mov	rax, qword ptr [rip + xt_cache+16]
	test	rax, rax
	je	.LBB63_10
# %bb.8:
	mov	rcx, qword ptr [rax]
	dec	dword ptr [rip + xt_cache_n+8]
	mov	qword ptr [rip + xt_cache+16], rcx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_13
# %bb.9:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB63_13
.LBB63_10:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_12
# %bb.11:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB63_12:
	mov	edi, 48
	call	malloc@PLT
	test	rax, rax
	je	.LBB63_52
.LBB63_13:
	mov	qword ptr [rax], 2
	lea	rbx, [rax + 8]
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 8], xmm0
	movups	xmmword ptr [rax + 24], xmm0
	mov	qword ptr [rax + 40], 0
	test	rbx, rbx
	je	.LBB63_74
.LBB63_14:
	mov	qword ptr [rbx + 8], r14
	mov	qword ptr [rbx + 16], 1048576
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_17
	.p2align	4, 0x90
.LBB63_15:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB63_16 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB63_17
.LBB63_16:                              #   Parent Loop BB63_15 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB63_16
	jmp	.LBB63_15
.LBB63_17:
	mov	r15, qword ptr [rip + xt_cache+8]
	test	r15, r15
	je	.LBB63_20
# %bb.18:
	mov	rax, qword ptr [r15]
	dec	dword ptr [rip + xt_cache_n+4]
	mov	qword ptr [rip + xt_cache+8], rax
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_23
# %bb.19:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB63_23
.LBB63_20:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_22
# %bb.21:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB63_22:
	mov	edi, 32
	call	malloc@PLT
	mov	r15, rax
	test	rax, rax
	je	.LBB63_53
.LBB63_23:
	mov	qword ptr [r15], 1
	xorps	xmm0, xmm0
	movups	xmmword ptr [r15 + 8], xmm0
	add	r15, 8
	test	r15, r15
	je	.LBB63_74
.LBB63_24:
	mov	qword ptr [r15], r13
	mov	qword ptr [r15 + 8], r12
	mov	edi, 1
	mov	esi, 1792
	call	calloc@PLT
	test	rax, rax
	je	.LBB63_35
# %bb.25:
	mov	r13, rax
	mov	qword ptr [rax], 64
	add	r13, 8
	test	r13, r13
	je	.LBB63_36
.LBB63_26:
	lea	r12, [r13 + 256]
	call	_xt_tls_hdr_addr@PLT
	mov	rcx, qword ptr [rax]
	test	rcx, rcx
	je	.LBB63_29
# %bb.27:
	mov	rdx, r12
	sub	rdx, rcx
	xor	esi, esi
	.p2align	4, 0x90
.LBB63_28:                              # =>This Inner Loop Header: Depth=1
	movzx	edi, byte ptr [rax + rsi + 8]
	mov	byte ptr [rdx + rsi], dil
	inc	rsi
	cmp	rcx, rsi
	jne	.LBB63_28
.LBB63_29:
	lea	rbp, [r13 + 760]
	call	_xt_libc_addr@PLT
	add	rax, 56
	mov	qword ptr [r13 + 424], rax
	mov	qword ptr [r13 + 384], rbp
	test	r12, r12
	je	.LBB63_37
.LBB63_30:
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
	jns	.LBB63_75
# %bb.31:
	mov	rax, qword ptr [r15 - 8]
	add	r15, -8
	cmp	rax, 64
	jae	.LBB63_57
# %bb.32:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_54
.LBB63_33:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB63_34 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB63_54
.LBB63_34:                              #   Parent Loop BB63_33 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB63_34
	jmp	.LBB63_33
.LBB63_35:
	xor	r13d, r13d
	test	r13, r13
	jne	.LBB63_26
.LBB63_36:
	xor	r12d, r12d
	test	r12, r12
	jne	.LBB63_30
.LBB63_37:
	mov	rax, qword ptr [r15 - 8]
	add	r15, -8
	cmp	rax, 64
	jae	.LBB63_44
# %bb.38:
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB63_40
	jmp	.LBB63_41
	.p2align	4, 0x90
.LBB63_39:                              #   Parent Loop BB63_40 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB63_39
.LBB63_40:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB63_39 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB63_39
.LBB63_41:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB63_76
# %bb.42:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_44
# %bb.43:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB63_44:
	mov	rdi, r15
	call	free@PLT
.LBB63_45:
	mov	rax, qword ptr [rbx - 8]
	add	rbx, -8
	cmp	rax, 64
	jae	.LBB63_73
# %bb.46:
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB63_48
	jmp	.LBB63_49
	.p2align	4, 0x90
.LBB63_47:                              #   Parent Loop BB63_48 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB63_47
.LBB63_48:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB63_47 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB63_47
	jmp	.LBB63_49
.LBB63_52:
	xor	ebx, ebx
	test	rbx, rbx
	jne	.LBB63_14
	jmp	.LBB63_74
.LBB63_53:
	xor	r15d, r15d
	test	r15, r15
	jne	.LBB63_24
	jmp	.LBB63_74
.LBB63_54:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB63_78
# %bb.55:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_57
# %bb.56:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB63_57:
	mov	rdi, r15
	call	free@PLT
.LBB63_58:
	mov	rax, qword ptr [r12 - 264]
	add	r12, -264
	cmp	rax, 64
	jae	.LBB63_65
# %bb.59:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_62
.LBB63_60:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB63_61 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB63_62
.LBB63_61:                              #   Parent Loop BB63_60 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB63_61
	jmp	.LBB63_60
.LBB63_62:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB63_80
# %bb.63:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_65
# %bb.64:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB63_65:
	mov	rdi, r12
	call	free@PLT
.LBB63_66:
	mov	rax, qword ptr [rbx - 8]
	add	rbx, -8
	cmp	rax, 64
	jae	.LBB63_73
# %bb.67:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_49
.LBB63_68:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB63_69 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB63_49
.LBB63_69:                              #   Parent Loop BB63_68 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB63_69
	jmp	.LBB63_68
.LBB63_49:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB63_50
# %bb.71:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_73
# %bb.72:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB63_73:
	mov	rdi, rbx
	call	free@PLT
.LBB63_74:
	xor	ebx, ebx
.LBB63_75:
	mov	rax, rbx
	add	rsp, 8
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	pop	rbp
	ret
.LBB63_50:
	lea	rsi, [rip + xt_cache]
	mov	rdi, qword ptr [rsi + 8*rax]
	mov	qword ptr [rbx], rdi
	mov	qword ptr [rsi + 8*rax], rbx
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_74
# %bb.51:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB63_74
.LBB63_76:
	lea	rsi, [rip + xt_cache]
	mov	rdi, qword ptr [rsi + 8*rax]
	mov	qword ptr [r15], rdi
	mov	qword ptr [rsi + 8*rax], r15
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_45
# %bb.77:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB63_45
.LBB63_78:
	lea	rsi, [rip + xt_cache]
	mov	rdi, qword ptr [rsi + 8*rax]
	mov	qword ptr [r15], rdi
	mov	qword ptr [rsi + 8*rax], r15
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_58
# %bb.79:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB63_58
.LBB63_80:
	lea	rsi, [rip + xt_cache]
	mov	rdi, qword ptr [rsi + 8*rax]
	mov	qword ptr [r12], rdi
	mov	qword ptr [rsi + 8*rax], r12
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB63_66
# %bb.81:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB63_66
.Lfunc_end63:
	.size	_xt_thread_create, .Lfunc_end63-_xt_thread_create
                                        # -- End function
	.p2align	4, 0x90                         # -- Begin function xt_reap_sweep
	.type	xt_reap_sweep,@function
xt_reap_sweep:                          # @xt_reap_sweep
# %bb.0:
	.p2align	4, 0x90
.LBB64_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB64_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_reap_spin], eax
	test	eax, eax
	je	.LBB64_3
.LBB64_2:                               #   Parent Loop BB64_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_reap_spin]
	test	eax, eax
	jne	.LBB64_2
	jmp	.LBB64_1
.LBB64_3:
	push	r15
	push	r14
	push	r12
	push	rbx
	push	rax
	mov	rbx, qword ptr [rip + xt_reap_head]
	test	rbx, rbx
	je	.LBB64_32
# %bb.4:
	lea	r12, [rip + xt_reap_head]
	lea	r14, [rip + xt_cache_n]
	lea	r15, [rip + xt_cache]
	jmp	.LBB64_7
	.p2align	4, 0x90
.LBB64_5:                               #   in Loop: Header=BB64_7 Depth=1
	add	rbx, 24
	mov	r12, rbx
.LBB64_6:                               #   in Loop: Header=BB64_7 Depth=1
	mov	rbx, qword ptr [r12]
	test	rbx, rbx
	je	.LBB64_32
.LBB64_7:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB64_14 Depth 2
                                        #       Child Loop BB64_15 Depth 3
                                        #     Child Loop BB64_24 Depth 2
                                        #       Child Loop BB64_25 Depth 3
	mov	eax, dword ptr [rbx]
	test	eax, eax
	jne	.LBB64_5
# %bb.8:                                #   in Loop: Header=BB64_7 Depth=1
	mov	rax, qword ptr [rbx + 24]
	mov	qword ptr [r12], rax
	mov	rdi, qword ptr [rbx + 8]
	test	rdi, rdi
	je	.LBB64_10
# %bb.9:                                #   in Loop: Header=BB64_7 Depth=1
	mov	rsi, qword ptr [rbx + 16]
	call	_sys_munmap@PLT
.LBB64_10:                              #   in Loop: Header=BB64_7 Depth=1
	mov	rdi, qword ptr [rbx + 32]
	test	rdi, rdi
	je	.LBB64_22
# %bb.11:                               #   in Loop: Header=BB64_7 Depth=1
	mov	rax, qword ptr [rdi - 264]
	add	rdi, -264
	cmp	rax, 64
	jae	.LBB64_12
# %bb.13:                               #   in Loop: Header=BB64_7 Depth=1
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB64_16
	.p2align	4, 0x90
.LBB64_14:                              #   Parent Loop BB64_7 Depth=1
                                        # =>  This Loop Header: Depth=2
                                        #       Child Loop BB64_15 Depth 3
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB64_16
.LBB64_15:                              #   Parent Loop BB64_7 Depth=1
                                        #     Parent Loop BB64_14 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB64_15
	jmp	.LBB64_14
.LBB64_16:                              #   in Loop: Header=BB64_7 Depth=1
	mov	ecx, dword ptr [r14 + 4*rax]
	cmp	ecx, 64
	jb	.LBB64_20
# %bb.17:                               #   in Loop: Header=BB64_7 Depth=1
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB64_12
# %bb.18:                               #   in Loop: Header=BB64_7 Depth=1
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB64_12:                              #   in Loop: Header=BB64_7 Depth=1
	call	free@PLT
.LBB64_22:                              #   in Loop: Header=BB64_7 Depth=1
	mov	rax, qword ptr [rbx - 8]
	add	rbx, -8
	cmp	rax, 64
	jae	.LBB64_29
# %bb.23:                               #   in Loop: Header=BB64_7 Depth=1
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB64_26
	.p2align	4, 0x90
.LBB64_24:                              #   Parent Loop BB64_7 Depth=1
                                        # =>  This Loop Header: Depth=2
                                        #       Child Loop BB64_25 Depth 3
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB64_26
.LBB64_25:                              #   Parent Loop BB64_7 Depth=1
                                        #     Parent Loop BB64_24 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB64_25
	jmp	.LBB64_24
.LBB64_26:                              #   in Loop: Header=BB64_7 Depth=1
	mov	ecx, dword ptr [r14 + 4*rax]
	cmp	ecx, 64
	jb	.LBB64_30
# %bb.27:                               #   in Loop: Header=BB64_7 Depth=1
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB64_29
# %bb.28:                               #   in Loop: Header=BB64_7 Depth=1
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB64_29:                              #   in Loop: Header=BB64_7 Depth=1
	mov	rdi, rbx
	call	free@PLT
	jmp	.LBB64_6
.LBB64_30:                              #   in Loop: Header=BB64_7 Depth=1
	mov	rdx, qword ptr [r15 + 8*rax]
	mov	qword ptr [rbx], rdx
	mov	qword ptr [r15 + 8*rax], rbx
	inc	ecx
	mov	dword ptr [r14 + 4*rax], ecx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB64_6
# %bb.31:                               #   in Loop: Header=BB64_7 Depth=1
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB64_6
.LBB64_20:                              #   in Loop: Header=BB64_7 Depth=1
	mov	rdx, qword ptr [r15 + 8*rax]
	mov	qword ptr [rdi], rdx
	mov	qword ptr [r15 + 8*rax], rdi
	inc	ecx
	mov	dword ptr [r14 + 4*rax], ecx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB64_22
# %bb.21:                               #   in Loop: Header=BB64_7 Depth=1
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB64_22
.LBB64_32:
	mov	dword ptr [rip + xt_reap_spin], 0
	add	rsp, 8
	pop	rbx
	pop	r12
	pop	r14
	pop	r15
	ret
.Lfunc_end64:
	.size	xt_reap_sweep, .Lfunc_end64-xt_reap_sweep
                                        # -- End function
	.p2align	4, 0x90                         # -- Begin function xt_thread_entry
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
	jb	.LBB65_2
# %bb.1:
	mov	r14, r9
	jmp	.LBB65_8
.LBB65_2:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB65_5
	.p2align	4, 0x90
.LBB65_3:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB65_4 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB65_5
.LBB65_4:                               #   Parent Loop BB65_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB65_4
	jmp	.LBB65_3
.LBB65_5:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB65_9
# %bb.6:
	mov	r14, r9
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB65_8
# %bb.7:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB65_8:
	call	free@PLT
	mov	r9, r14
.LBB65_11:
	test	r9, r9
	je	.LBB65_12
# %bb.13:
	mov	rdi, rbx
	add	rsp, 8
	pop	rbx
	pop	r14
	jmp	r9                              # TAILCALL
.LBB65_12:
	add	rsp, 8
	pop	rbx
	pop	r14
	ret
.LBB65_9:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB65_11
# %bb.10:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB65_11
.Lfunc_end65:
	.size	xt_thread_entry, .Lfunc_end65-xt_thread_entry
                                        # -- End function
	.globl	_xt_thread_join                 # -- Begin function _xt_thread_join
	.p2align	4, 0x90
	.type	_xt_thread_join,@function
_xt_thread_join:                        # @_xt_thread_join
# %bb.0:
	test	rdi, rdi
	je	.LBB66_9
# %bb.1:
	push	rbx
	mov	rbx, rdi
	.p2align	4, 0x90
.LBB66_2:                               # =>This Inner Loop Header: Depth=1
	mov	eax, dword ptr [rbx]
	test	eax, eax
	je	.LBB66_4
# %bb.3:                                #   in Loop: Header=BB66_2 Depth=1
	movsxd	rdx, eax
	mov	rdi, rbx
	xor	esi, esi
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	call	_sys_futex@PLT
	jmp	.LBB66_2
.LBB66_4:
	mov	rdi, qword ptr [rbx + 8]
	test	rdi, rdi
	je	.LBB66_6
# %bb.5:
	mov	rsi, qword ptr [rbx + 16]
	call	_sys_munmap@PLT
.LBB66_6:
	mov	rdi, qword ptr [rbx + 32]
	test	rdi, rdi
	je	.LBB66_19
# %bb.7:
	mov	rax, qword ptr [rdi - 264]
	add	rdi, -264
	cmp	rax, 64
	jae	.LBB66_8
# %bb.10:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB66_13
	.p2align	4, 0x90
.LBB66_11:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB66_12 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB66_13
.LBB66_12:                              #   Parent Loop BB66_11 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB66_12
	jmp	.LBB66_11
.LBB66_9:
	mov	eax, -1
	ret
.LBB66_13:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB66_17
# %bb.14:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB66_8
# %bb.15:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB66_8:
	call	free@PLT
.LBB66_19:
	mov	rax, qword ptr [rbx - 8]
	add	rbx, -8
	cmp	rax, 64
	jae	.LBB66_26
# %bb.20:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB66_23
	.p2align	4, 0x90
.LBB66_21:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB66_22 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB66_23
.LBB66_22:                              #   Parent Loop BB66_21 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB66_22
	jmp	.LBB66_21
.LBB66_23:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB66_27
# %bb.24:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB66_26
# %bb.25:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB66_26:
	mov	rdi, rbx
	call	free@PLT
	xor	eax, eax
	pop	rbx
	ret
.LBB66_27:
	lea	rsi, [rip + xt_cache]
	mov	rdi, qword ptr [rsi + 8*rax]
	mov	qword ptr [rbx], rdi
	mov	qword ptr [rsi + 8*rax], rbx
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	xor	eax, eax
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB66_29
# %bb.28:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB66_29:
	pop	rbx
	ret
.LBB66_17:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB66_19
# %bb.18:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB66_19
.Lfunc_end66:
	.size	_xt_thread_join, .Lfunc_end66-_xt_thread_join
                                        # -- End function
	.globl	_xt_thread_detach               # -- Begin function _xt_thread_detach
	.p2align	4, 0x90
	.type	_xt_thread_detach,@function
_xt_thread_detach:                      # @_xt_thread_detach
# %bb.0:
	test	rdi, rdi
	je	.LBB67_25
# %bb.1:
	mov	eax, dword ptr [rdi]
	test	eax, eax
	je	.LBB67_2
	.p2align	4, 0x90
.LBB67_26:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB67_27 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_reap_spin], eax
	test	eax, eax
	je	.LBB67_28
.LBB67_27:                              #   Parent Loop BB67_26 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_reap_spin]
	test	eax, eax
	jne	.LBB67_27
	jmp	.LBB67_26
.LBB67_28:
	mov	rax, qword ptr [rip + xt_reap_head]
	mov	qword ptr [rdi + 24], rax
	mov	qword ptr [rip + xt_reap_head], rdi
	mov	dword ptr [rip + xt_reap_spin], 0
	jmp	xt_reap_sweep                   # TAILCALL
.LBB67_2:
	push	rbx
	mov	rax, qword ptr [rdi + 8]
	test	rax, rax
	je	.LBB67_4
# %bb.3:
	mov	rsi, qword ptr [rdi + 16]
	mov	rbx, rdi
	mov	rdi, rax
	call	_sys_munmap@PLT
	mov	rdi, rbx
.LBB67_4:
	mov	rax, qword ptr [rdi + 32]
	test	rax, rax
	je	.LBB67_16
# %bb.5:
	mov	rcx, qword ptr [rax - 264]
	add	rax, -264
	cmp	rcx, 64
	jb	.LBB67_7
# %bb.6:
	mov	rbx, rdi
	jmp	.LBB67_13
.LBB67_7:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB67_10
	.p2align	4, 0x90
.LBB67_8:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB67_9 Depth 2
	mov	edx, 1
	xchg	dword ptr [rip + xt_alloc_spin], edx
	test	edx, edx
	je	.LBB67_10
.LBB67_9:                               #   Parent Loop BB67_8 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	edx, dword ptr [rip + xt_alloc_spin]
	test	edx, edx
	jne	.LBB67_9
	jmp	.LBB67_8
.LBB67_10:
	lea	rdx, [rip + xt_cache_n]
	mov	esi, dword ptr [rdx + 4*rcx]
	cmp	esi, 64
	jb	.LBB67_14
# %bb.11:
	mov	rbx, rdi
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB67_13
# %bb.12:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB67_13:
	mov	rdi, rax
	call	free@PLT
	mov	rdi, rbx
.LBB67_16:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	pop	rbx
	jae	free@PLT                        # TAILCALL
# %bb.17:
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB67_18
	jmp	.LBB67_20
	.p2align	4, 0x90
.LBB67_19:                              #   Parent Loop BB67_18 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB67_19
.LBB67_18:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB67_19 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB67_19
.LBB67_20:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB67_23
# %bb.21:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	free@PLT                        # TAILCALL
# %bb.22:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	free@PLT                        # TAILCALL
.LBB67_23:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB67_25
# %bb.24:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB67_25:
	ret
.LBB67_14:
	lea	r8, [rip + xt_cache]
	mov	r9, qword ptr [r8 + 8*rcx]
	mov	qword ptr [rax], r9
	mov	qword ptr [r8 + 8*rcx], rax
	inc	esi
	mov	dword ptr [rdx + 4*rcx], esi
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB67_16
# %bb.15:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB67_16
.Lfunc_end67:
	.size	_xt_thread_detach, .Lfunc_end67-_xt_thread_detach
                                        # -- End function
	.globl	_xt_thread_yield                # -- Begin function _xt_thread_yield
	.p2align	4, 0x90
	.type	_xt_thread_yield,@function
_xt_thread_yield:                       # @_xt_thread_yield
# %bb.0:
	jmp	_sys_sched_yield@PLT            # TAILCALL
.Lfunc_end68:
	.size	_xt_thread_yield, .Lfunc_end68-_xt_thread_yield
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
	call	_sys_nanosleep@PLT
	add	rsp, 24
	ret
.Lfunc_end69:
	.size	_xt_thread_sleep_ms, .Lfunc_end69-_xt_thread_sleep_ms
                                        # -- End function
	.globl	_xt_thread_self_id              # -- Begin function _xt_thread_self_id
	.p2align	4, 0x90
	.type	_xt_thread_self_id,@function
_xt_thread_self_id:                     # @_xt_thread_self_id
# %bb.0:
	jmp	_sys_gettid@PLT                 # TAILCALL
.Lfunc_end70:
	.size	_xt_thread_self_id, .Lfunc_end70-_xt_thread_self_id
                                        # -- End function
	.globl	_xt_thread_cpu_count            # -- Begin function _xt_thread_cpu_count
	.p2align	4, 0x90
	.type	_xt_thread_cpu_count,@function
_xt_thread_cpu_count:                   # @_xt_thread_cpu_count
# %bb.0:
	push	rbx
	sub	rsp, 128
	xorps	xmm0, xmm0
	movaps	xmmword ptr [rsp + 112], xmm0
	movaps	xmmword ptr [rsp + 96], xmm0
	movaps	xmmword ptr [rsp + 80], xmm0
	movaps	xmmword ptr [rsp + 64], xmm0
	movaps	xmmword ptr [rsp + 48], xmm0
	movaps	xmmword ptr [rsp + 32], xmm0
	movaps	xmmword ptr [rsp + 16], xmm0
	movaps	xmmword ptr [rsp], xmm0
	xor	ebx, ebx
	mov	rdx, rsp
	mov	esi, 128
	xor	edi, edi
	call	_sys_sched_getaffinity@PLT
	test	rax, rax
	jle	.LBB71_1
# %bb.2:
	mov	rdx, rax
	shr	rdx, 3
	cmp	rdx, 16
	mov	ecx, 16
	cmovb	rcx, rdx
	cmp	rax, 8
	jb	.LBB71_7
# %bb.3:
	xor	eax, eax
	xor	ebx, ebx
	.p2align	4, 0x90
.LBB71_4:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB71_5 Depth 2
	mov	rdx, qword ptr [rsp + 8*rax]
	xor	esi, esi
	.p2align	4, 0x90
.LBB71_5:                               #   Parent Loop BB71_4 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	bt	rdx, rsi
	adc	ebx, 0
	inc	rsi
	cmp	rsi, 64
	jne	.LBB71_5
# %bb.6:                                #   in Loop: Header=BB71_4 Depth=1
	inc	rax
	cmp	rax, rcx
	jne	.LBB71_4
.LBB71_7:
	cmp	ebx, 2
	mov	eax, 1
	cmovge	eax, ebx
	jmp	.LBB71_8
.LBB71_1:
	mov	eax, 1
.LBB71_8:
	add	rsp, 128
	pop	rbx
	ret
.Lfunc_end71:
	.size	_xt_thread_cpu_count, .Lfunc_end71-_xt_thread_cpu_count
                                        # -- End function
	.globl	_xt_mutex_new                   # -- Begin function _xt_mutex_new
	.p2align	4, 0x90
	.type	_xt_mutex_new,@function
_xt_mutex_new:                          # @_xt_mutex_new
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB72_3
	.p2align	4, 0x90
.LBB72_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB72_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB72_3
.LBB72_2:                               #   Parent Loop BB72_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB72_2
	jmp	.LBB72_1
.LBB72_3:
	push	rax
	mov	rax, qword ptr [rip + xt_cache]
	test	rax, rax
	je	.LBB72_7
# %bb.4:
	mov	rcx, qword ptr [rax]
	dec	dword ptr [rip + xt_cache_n]
	mov	qword ptr [rip + xt_cache], rcx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB72_6
# %bb.5:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB72_6
.LBB72_7:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB72_9
# %bb.8:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB72_9:
	mov	edi, 16
	call	malloc@PLT
	test	rax, rax
	je	.LBB72_10
.LBB72_6:
	mov	qword ptr [rax], 0
	mov	dword ptr [rax + 8], 0
	add	rax, 8
	pop	rcx
	ret
.LBB72_10:
	xor	eax, eax
	pop	rcx
	ret
.Lfunc_end72:
	.size	_xt_mutex_new, .Lfunc_end72-_xt_mutex_new
                                        # -- End function
	.globl	_xt_mutex_free                  # -- Begin function _xt_mutex_free
	.p2align	4, 0x90
	.type	_xt_mutex_free,@function
_xt_mutex_free:                         # @_xt_mutex_free
# %bb.0:
	test	rdi, rdi
	je	.LBB73_10
# %bb.1:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	free@PLT                        # TAILCALL
# %bb.2:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB73_5
	.p2align	4, 0x90
.LBB73_3:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB73_4 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB73_5
.LBB73_4:                               #   Parent Loop BB73_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB73_4
	jmp	.LBB73_3
.LBB73_5:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB73_8
# %bb.6:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	free@PLT                        # TAILCALL
# %bb.7:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	free@PLT                        # TAILCALL
.LBB73_8:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB73_10
# %bb.9:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB73_10:
	ret
.Lfunc_end73:
	.size	_xt_mutex_free, .Lfunc_end73-_xt_mutex_free
                                        # -- End function
	.globl	_xt_mutex_lock                  # -- Begin function _xt_mutex_lock
	.p2align	4, 0x90
	.type	_xt_mutex_lock,@function
_xt_mutex_lock:                         # @_xt_mutex_lock
# %bb.0:
	test	rdi, rdi
	je	.LBB74_6
# %bb.1:
	push	rbx
	mov	rbx, rdi
	mov	ecx, 1
	xor	eax, eax
	lock		cmpxchg	dword ptr [rdi], ecx
	je	.LBB74_5
# %bb.2:
	cmp	eax, 2
	jne	.LBB74_4
.LBB74_3:
	mov	edx, 2
	mov	rdi, rbx
	xor	esi, esi
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	call	_sys_futex@PLT
.LBB74_4:
	mov	eax, 2
	xchg	dword ptr [rbx], eax
	test	eax, eax
	jne	.LBB74_3
.LBB74_5:
	pop	rbx
.LBB74_6:
	ret
.Lfunc_end74:
	.size	_xt_mutex_lock, .Lfunc_end74-_xt_mutex_lock
                                        # -- End function
	.globl	_xt_mutex_unlock                # -- Begin function _xt_mutex_unlock
	.p2align	4, 0x90
	.type	_xt_mutex_unlock,@function
_xt_mutex_unlock:                       # @_xt_mutex_unlock
# %bb.0:
	test	rdi, rdi
	je	.LBB75_2
# %bb.1:
	lock		dec	dword ptr [rdi]
	jne	.LBB75_3
.LBB75_2:
	ret
.LBB75_3:
	mov	dword ptr [rdi], 0
	mov	esi, 1
	mov	edx, 1
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	jmp	_sys_futex@PLT                  # TAILCALL
.Lfunc_end75:
	.size	_xt_mutex_unlock, .Lfunc_end75-_xt_mutex_unlock
                                        # -- End function
	.globl	_xt_mutex_trylock               # -- Begin function _xt_mutex_trylock
	.p2align	4, 0x90
	.type	_xt_mutex_trylock,@function
_xt_mutex_trylock:                      # @_xt_mutex_trylock
# %bb.0:
	test	rdi, rdi
	je	.LBB76_1
# %bb.2:
	mov	ecx, 1
	xor	eax, eax
	lock		cmpxchg	dword ptr [rdi], ecx
	mov	eax, 0
	sete	al
	ret
.LBB76_1:
	xor	eax, eax
	ret
.Lfunc_end76:
	.size	_xt_mutex_trylock, .Lfunc_end76-_xt_mutex_trylock
                                        # -- End function
	.globl	_xt_cond_new                    # -- Begin function _xt_cond_new
	.p2align	4, 0x90
	.type	_xt_cond_new,@function
_xt_cond_new:                           # @_xt_cond_new
# %bb.0:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB77_3
	.p2align	4, 0x90
.LBB77_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB77_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB77_3
.LBB77_2:                               #   Parent Loop BB77_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB77_2
	jmp	.LBB77_1
.LBB77_3:
	push	rax
	mov	rax, qword ptr [rip + xt_cache]
	test	rax, rax
	je	.LBB77_7
# %bb.4:
	mov	rcx, qword ptr [rax]
	dec	dword ptr [rip + xt_cache_n]
	mov	qword ptr [rip + xt_cache], rcx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB77_6
# %bb.5:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB77_6
.LBB77_7:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB77_9
# %bb.8:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB77_9:
	mov	edi, 16
	call	malloc@PLT
	test	rax, rax
	je	.LBB77_10
.LBB77_6:
	mov	qword ptr [rax], 0
	mov	dword ptr [rax + 8], 0
	add	rax, 8
	pop	rcx
	ret
.LBB77_10:
	xor	eax, eax
	pop	rcx
	ret
.Lfunc_end77:
	.size	_xt_cond_new, .Lfunc_end77-_xt_cond_new
                                        # -- End function
	.globl	_xt_cond_free                   # -- Begin function _xt_cond_free
	.p2align	4, 0x90
	.type	_xt_cond_free,@function
_xt_cond_free:                          # @_xt_cond_free
# %bb.0:
	test	rdi, rdi
	je	.LBB78_10
# %bb.1:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	free@PLT                        # TAILCALL
# %bb.2:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB78_5
	.p2align	4, 0x90
.LBB78_3:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB78_4 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB78_5
.LBB78_4:                               #   Parent Loop BB78_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB78_4
	jmp	.LBB78_3
.LBB78_5:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB78_8
# %bb.6:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	free@PLT                        # TAILCALL
# %bb.7:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	free@PLT                        # TAILCALL
.LBB78_8:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB78_10
# %bb.9:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB78_10:
	ret
.Lfunc_end78:
	.size	_xt_cond_free, .Lfunc_end78-_xt_cond_free
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
	jne	.LBB79_8
# %bb.1:
	push	r15
	push	r14
	push	rbx
	mov	rbx, rsi
	mov	eax, dword ptr [rdi]
	movsxd	r14, eax
	lock		dec	dword ptr [rsi]
	je	.LBB79_3
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
.LBB79_3:
	xor	esi, esi
	mov	rdx, r14
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	call	_sys_futex@PLT
	mov	ecx, 1
	xor	eax, eax
	lock		cmpxchg	dword ptr [rbx], ecx
	je	.LBB79_7
# %bb.4:
	cmp	eax, 2
	jne	.LBB79_6
.LBB79_5:
	mov	edx, 2
	mov	rdi, rbx
	xor	esi, esi
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	call	_sys_futex@PLT
.LBB79_6:
	mov	eax, 2
	xchg	dword ptr [rbx], eax
	test	eax, eax
	jne	.LBB79_5
.LBB79_7:
	pop	rbx
	pop	r14
	pop	r15
.LBB79_8:
	ret
.Lfunc_end79:
	.size	_xt_cond_wait, .Lfunc_end79-_xt_cond_wait
                                        # -- End function
	.globl	_xt_cond_signal                 # -- Begin function _xt_cond_signal
	.p2align	4, 0x90
	.type	_xt_cond_signal,@function
_xt_cond_signal:                        # @_xt_cond_signal
# %bb.0:
	test	rdi, rdi
	je	.LBB80_1
# %bb.2:
	lock		inc	dword ptr [rdi]
	mov	esi, 1
	mov	edx, 1
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	jmp	_sys_futex@PLT                  # TAILCALL
.LBB80_1:
	ret
.Lfunc_end80:
	.size	_xt_cond_signal, .Lfunc_end80-_xt_cond_signal
                                        # -- End function
	.globl	_xt_cond_broadcast              # -- Begin function _xt_cond_broadcast
	.p2align	4, 0x90
	.type	_xt_cond_broadcast,@function
_xt_cond_broadcast:                     # @_xt_cond_broadcast
# %bb.0:
	test	rdi, rdi
	je	.LBB81_1
# %bb.2:
	lock		inc	dword ptr [rdi]
	mov	esi, 1
	mov	edx, 2147483647
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	jmp	_sys_futex@PLT                  # TAILCALL
.LBB81_1:
	ret
.Lfunc_end81:
	.size	_xt_cond_broadcast, .Lfunc_end81-_xt_cond_broadcast
                                        # -- End function
	.globl	_xt_sem_new                     # -- Begin function _xt_sem_new
	.p2align	4, 0x90
	.type	_xt_sem_new,@function
_xt_sem_new:                            # @_xt_sem_new
# %bb.0:
	push	rbx
	mov	ebx, edi
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB82_3
	.p2align	4, 0x90
.LBB82_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB82_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB82_3
.LBB82_2:                               #   Parent Loop BB82_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB82_2
	jmp	.LBB82_1
.LBB82_3:
	mov	rax, qword ptr [rip + xt_cache]
	test	rax, rax
	je	.LBB82_7
# %bb.4:
	mov	rcx, qword ptr [rax]
	dec	dword ptr [rip + xt_cache_n]
	mov	qword ptr [rip + xt_cache], rcx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB82_6
# %bb.5:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB82_6
.LBB82_7:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB82_9
# %bb.8:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB82_9:
	mov	edi, 16
	call	malloc@PLT
	test	rax, rax
	je	.LBB82_10
.LBB82_6:
	mov	qword ptr [rax], 0
	mov	dword ptr [rax + 8], 0
	add	rax, 8
	test	rax, rax
	je	.LBB82_13
.LBB82_12:
	xor	ecx, ecx
	test	ebx, ebx
	cmovg	ecx, ebx
	mov	dword ptr [rax], ecx
.LBB82_13:
	pop	rbx
	ret
.LBB82_10:
	xor	eax, eax
	test	rax, rax
	jne	.LBB82_12
	jmp	.LBB82_13
.Lfunc_end82:
	.size	_xt_sem_new, .Lfunc_end82-_xt_sem_new
                                        # -- End function
	.globl	_xt_sem_free                    # -- Begin function _xt_sem_free
	.p2align	4, 0x90
	.type	_xt_sem_free,@function
_xt_sem_free:                           # @_xt_sem_free
# %bb.0:
	test	rdi, rdi
	je	.LBB83_10
# %bb.1:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	free@PLT                        # TAILCALL
# %bb.2:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB83_5
	.p2align	4, 0x90
.LBB83_3:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB83_4 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB83_5
.LBB83_4:                               #   Parent Loop BB83_3 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB83_4
	jmp	.LBB83_3
.LBB83_5:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB83_8
# %bb.6:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	free@PLT                        # TAILCALL
# %bb.7:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	free@PLT                        # TAILCALL
.LBB83_8:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB83_10
# %bb.9:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB83_10:
	ret
.Lfunc_end83:
	.size	_xt_sem_free, .Lfunc_end83-_xt_sem_free
                                        # -- End function
	.globl	_xt_sem_wait                    # -- Begin function _xt_sem_wait
	.p2align	4, 0x90
	.type	_xt_sem_wait,@function
_xt_sem_wait:                           # @_xt_sem_wait
# %bb.0:
	test	rdi, rdi
	je	.LBB84_8
# %bb.1:
	push	r14
	push	rbx
	push	rax
	mov	rbx, rdi
	.p2align	4, 0x90
.LBB84_2:                               # =>This Inner Loop Header: Depth=1
	mov	eax, dword ptr [rbx]
	test	eax, eax
	jle	.LBB84_4
# %bb.3:                                #   in Loop: Header=BB84_2 Depth=1
	lea	ecx, [rax - 1]
	xor	edx, edx
                                        # kill: def $eax killed $eax killed $rax
	lock		cmpxchg	dword ptr [rbx], ecx
	setne	dl
	lea	r14d, [2*rdx + 1]
	test	r14d, r14d
	jne	.LBB84_6
	jmp	.LBB84_2
	.p2align	4, 0x90
.LBB84_4:                               #   in Loop: Header=BB84_2 Depth=1
	xor	r14d, r14d
	mov	rdi, rbx
	xor	esi, esi
	xor	edx, edx
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	call	_sys_futex@PLT
	test	r14d, r14d
	je	.LBB84_2
.LBB84_6:                               #   in Loop: Header=BB84_2 Depth=1
	cmp	r14d, 3
	je	.LBB84_2
# %bb.7:
	add	rsp, 8
	pop	rbx
	pop	r14
.LBB84_8:
	ret
.Lfunc_end84:
	.size	_xt_sem_wait, .Lfunc_end84-_xt_sem_wait
                                        # -- End function
	.globl	_xt_sem_trywait                 # -- Begin function _xt_sem_trywait
	.p2align	4, 0x90
	.type	_xt_sem_trywait,@function
_xt_sem_trywait:                        # @_xt_sem_trywait
# %bb.0:
	test	rdi, rdi
	je	.LBB85_1
# %bb.2:
	mov	edx, 1
                                        # implicit-def: $ecx
	jmp	.LBB85_3
	.p2align	4, 0x90
.LBB85_5:                               #   in Loop: Header=BB85_3 Depth=1
	lea	esi, [rax - 1]
                                        # kill: def $eax killed $eax killed $rax
	lock		cmpxchg	dword ptr [rdi], esi
	setne	al
	cmove	ecx, edx
	test	al, al
	je	.LBB85_7
.LBB85_3:                               # =>This Inner Loop Header: Depth=1
	mov	eax, dword ptr [rdi]
	test	eax, eax
	jg	.LBB85_5
# %bb.4:                                #   in Loop: Header=BB85_3 Depth=1
	xor	eax, eax
	xor	ecx, ecx
	test	al, al
	jne	.LBB85_3
.LBB85_7:
	mov	eax, ecx
	ret
.LBB85_1:
	xor	eax, eax
	ret
.Lfunc_end85:
	.size	_xt_sem_trywait, .Lfunc_end85-_xt_sem_trywait
                                        # -- End function
	.globl	_xt_sem_post                    # -- Begin function _xt_sem_post
	.p2align	4, 0x90
	.type	_xt_sem_post,@function
_xt_sem_post:                           # @_xt_sem_post
# %bb.0:
	test	rdi, rdi
	je	.LBB86_1
# %bb.2:
	lock		inc	dword ptr [rdi]
	mov	esi, 1
	mov	edx, 1
	xor	ecx, ecx
	xor	r8d, r8d
	xor	r9d, r9d
	jmp	_sys_futex@PLT                  # TAILCALL
.LBB86_1:
	ret
.Lfunc_end86:
	.size	_xt_sem_post, .Lfunc_end86-_xt_sem_post
                                        # -- End function
	.globl	_xt_tls_new                     # -- Begin function _xt_tls_new
	.p2align	4, 0x90
	.type	_xt_tls_new,@function
_xt_tls_new:                            # @_xt_tls_new
# %bb.0:
	.p2align	4, 0x90
.LBB87_2:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB87_1 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_tls_keyspin], eax
	test	eax, eax
	je	.LBB87_3
.LBB87_1:                               #   Parent Loop BB87_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_tls_keyspin]
	test	eax, eax
	jne	.LBB87_1
	jmp	.LBB87_2
.LBB87_3:
	mov	ecx, dword ptr [rip + xt_tls_next_key]
	mov	eax, -1
	cmp	ecx, 61
	ja	.LBB87_5
# %bb.4:
	lea	eax, [rcx + 1]
	mov	dword ptr [rip + xt_tls_next_key], eax
	mov	eax, ecx
.LBB87_5:
	mov	dword ptr [rip + xt_tls_keyspin], 0
	ret
.Lfunc_end87:
	.size	_xt_tls_new, .Lfunc_end87-_xt_tls_new
                                        # -- End function
	.globl	_xt_tls_set                     # -- Begin function _xt_tls_set
	.p2align	4, 0x90
	.type	_xt_tls_set,@function
_xt_tls_set:                            # @_xt_tls_set
# %bb.0:
	cmp	edi, 61
	ja	.LBB88_2
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
.LBB88_2:
	ret
.Lfunc_end88:
	.size	_xt_tls_set, .Lfunc_end88-_xt_tls_set
                                        # -- End function
	.globl	_xt_tls_get                     # -- Begin function _xt_tls_get
	.p2align	4, 0x90
	.type	_xt_tls_get,@function
_xt_tls_get:                            # @_xt_tls_get
# %bb.0:
	cmp	edi, 61
	jbe	.LBB89_2
# %bb.1:
	xor	eax, eax
	ret
.LBB89_2:
	push	rbx
	mov	ebx, edi
	call	_xt_tcb_get@PLT
	mov	ecx, ebx
	mov	rax, qword ptr [rax + 8*rcx + 8]
	pop	rbx
	ret
.Lfunc_end89:
	.size	_xt_tls_get, .Lfunc_end89-_xt_tls_get
                                        # -- End function
	.globl	_xt_atomic_load_i32             # -- Begin function _xt_atomic_load_i32
	.p2align	4, 0x90
	.type	_xt_atomic_load_i32,@function
_xt_atomic_load_i32:                    # @_xt_atomic_load_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB90_1
# %bb.2:
	mov	eax, dword ptr [rdi]
	ret
.LBB90_1:
	xor	eax, eax
	ret
.Lfunc_end90:
	.size	_xt_atomic_load_i32, .Lfunc_end90-_xt_atomic_load_i32
                                        # -- End function
	.globl	_xt_atomic_store_i32            # -- Begin function _xt_atomic_store_i32
	.p2align	4, 0x90
	.type	_xt_atomic_store_i32,@function
_xt_atomic_store_i32:                   # @_xt_atomic_store_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB91_2
# %bb.1:
	xchg	dword ptr [rdi], esi
.LBB91_2:
	ret
.Lfunc_end91:
	.size	_xt_atomic_store_i32, .Lfunc_end91-_xt_atomic_store_i32
                                        # -- End function
	.globl	_xt_atomic_add_i32              # -- Begin function _xt_atomic_add_i32
	.p2align	4, 0x90
	.type	_xt_atomic_add_i32,@function
_xt_atomic_add_i32:                     # @_xt_atomic_add_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB92_1
# %bb.2:
	mov	eax, esi
	lock		xadd	dword ptr [rdi], eax
	add	eax, esi
	ret
.LBB92_1:
	xor	eax, eax
	ret
.Lfunc_end92:
	.size	_xt_atomic_add_i32, .Lfunc_end92-_xt_atomic_add_i32
                                        # -- End function
	.globl	_xt_atomic_xchg_i32             # -- Begin function _xt_atomic_xchg_i32
	.p2align	4, 0x90
	.type	_xt_atomic_xchg_i32,@function
_xt_atomic_xchg_i32:                    # @_xt_atomic_xchg_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB93_1
# %bb.2:
	mov	eax, esi
	xchg	dword ptr [rdi], eax
	ret
.LBB93_1:
	xor	eax, eax
	ret
.Lfunc_end93:
	.size	_xt_atomic_xchg_i32, .Lfunc_end93-_xt_atomic_xchg_i32
                                        # -- End function
	.globl	_xt_atomic_cas_i32              # -- Begin function _xt_atomic_cas_i32
	.p2align	4, 0x90
	.type	_xt_atomic_cas_i32,@function
_xt_atomic_cas_i32:                     # @_xt_atomic_cas_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB94_1
# %bb.2:
	mov	eax, esi
	lock		cmpxchg	dword ptr [rdi], edx
	mov	eax, 0
	sete	al
	ret
.LBB94_1:
	xor	eax, eax
	ret
.Lfunc_end94:
	.size	_xt_atomic_cas_i32, .Lfunc_end94-_xt_atomic_cas_i32
                                        # -- End function
	.globl	_xt_atomic_load_ptr             # -- Begin function _xt_atomic_load_ptr
	.p2align	4, 0x90
	.type	_xt_atomic_load_ptr,@function
_xt_atomic_load_ptr:                    # @_xt_atomic_load_ptr
# %bb.0:
	test	rdi, rdi
	je	.LBB95_1
# %bb.2:
	mov	rax, qword ptr [rdi]
	ret
.LBB95_1:
	xor	eax, eax
	ret
.Lfunc_end95:
	.size	_xt_atomic_load_ptr, .Lfunc_end95-_xt_atomic_load_ptr
                                        # -- End function
	.globl	_xt_atomic_store_ptr            # -- Begin function _xt_atomic_store_ptr
	.p2align	4, 0x90
	.type	_xt_atomic_store_ptr,@function
_xt_atomic_store_ptr:                   # @_xt_atomic_store_ptr
# %bb.0:
	test	rdi, rdi
	je	.LBB96_2
# %bb.1:
	xchg	qword ptr [rdi], rsi
.LBB96_2:
	ret
.Lfunc_end96:
	.size	_xt_atomic_store_ptr, .Lfunc_end96-_xt_atomic_store_ptr
                                        # -- End function
	.globl	_xt_atomic_cas_ptr              # -- Begin function _xt_atomic_cas_ptr
	.p2align	4, 0x90
	.type	_xt_atomic_cas_ptr,@function
_xt_atomic_cas_ptr:                     # @_xt_atomic_cas_ptr
# %bb.0:
	test	rdi, rdi
	je	.LBB97_1
# %bb.2:
	mov	rax, rsi
	lock		cmpxchg	qword ptr [rdi], rdx
	mov	eax, 0
	sete	al
	ret
.LBB97_1:
	xor	eax, eax
	ret
.Lfunc_end97:
	.size	_xt_atomic_cas_ptr, .Lfunc_end97-_xt_atomic_cas_ptr
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
	test	ecx, 402657280
	jne	.LBB98_4
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
	jne	.LBB98_4
# %bb.2:
	xor	r15d, r15d
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
	and	esi, 224
	xor	r15d, r15d
	or	esi, ebx
	sete	r15b
	inc	r15d
.LBB98_4:
	lea	rdi, [rip + .L.str]
	call	getenv@PLT
	test	rax, rax
	je	.LBB98_27
# %bb.5:
	movzx	ecx, byte ptr [rax]
	test	cl, cl
	je	.LBB98_6
# %bb.7:
	lea	rsi, [rax + 1]
	lea	rdx, [rip + .L.str.1]
	mov	edi, ecx
	.p2align	4, 0x90
.LBB98_8:                               # =>This Inner Loop Header: Depth=1
	cmp	dil, byte ptr [rdx]
	jne	.LBB98_10
# %bb.9:                                #   in Loop: Header=BB98_8 Depth=1
	inc	rdx
	movzx	edi, byte ptr [rsi]
	inc	rsi
	test	dil, dil
	jne	.LBB98_8
	jmp	.LBB98_10
.LBB98_6:
	lea	rdx, [rip + .L.str.1]
	mov	edi, ecx
.LBB98_10:
	xor	esi, esi
	cmp	dil, byte ptr [rdx]
	cmovne	esi, r15d
	je	.LBB98_28
# %bb.11:
	test	cl, cl
	je	.LBB98_12
# %bb.13:
	lea	rdi, [rax + 1]
	lea	rdx, [rip + .L.str.2]
	mov	esi, ecx
	.p2align	4, 0x90
.LBB98_14:                              # =>This Inner Loop Header: Depth=1
	cmp	sil, byte ptr [rdx]
	jne	.LBB98_16
# %bb.15:                               #   in Loop: Header=BB98_14 Depth=1
	inc	rdx
	movzx	esi, byte ptr [rdi]
	inc	rdi
	test	sil, sil
	jne	.LBB98_14
.LBB98_16:
	cmp	sil, byte ptr [rdx]
	jne	.LBB98_19
.LBB98_17:
	mov	esi, 1
	test	r15d, r15d
	jne	.LBB98_28
# %bb.18:
	lea	rsi, [rip + xt_simd_pick.msg]
	mov	edx, 66
	mov	edi, 2
	call	write@PLT
	xor	esi, esi
	jmp	.LBB98_28
.LBB98_12:
	lea	rdx, [rip + .L.str.2]
	mov	esi, ecx
	cmp	sil, byte ptr [rdx]
	je	.LBB98_17
.LBB98_19:
	test	cl, cl
	je	.LBB98_20
# %bb.21:
	inc	rax
	lea	rdx, [rip + .L.str.3]
	.p2align	4, 0x90
.LBB98_22:                              # =>This Inner Loop Header: Depth=1
	cmp	cl, byte ptr [rdx]
	jne	.LBB98_24
# %bb.23:                               #   in Loop: Header=BB98_22 Depth=1
	inc	rdx
	movzx	ecx, byte ptr [rax]
	inc	rax
	test	cl, cl
	jne	.LBB98_22
	jmp	.LBB98_24
.LBB98_20:
	lea	rdx, [rip + .L.str.3]
.LBB98_24:
	cmp	r15d, 1
	ja	.LBB98_27
# %bb.25:
	cmp	cl, byte ptr [rdx]
	jne	.LBB98_27
# %bb.26:
	lea	rsi, [rip + xt_simd_pick.msg.4]
	mov	edx, 82
	mov	edi, 2
	call	write@PLT
.LBB98_27:
	mov	esi, r15d
.LBB98_28:
	xor	eax, eax
	test	esi, esi
	setne	al
	mov	dword ptr [rip + _xt_simd_level], eax
	test	ebp, ebp
	je	.LBB98_31
# %bb.29:
	cmp	esi, 1
	mov	eax, 1
	sbb	eax, -1
	mov	ecx, ebp
	lea	rcx, [rcx + 2*rcx]
	xor	edx, edx
	.p2align	4, 0x90
.LBB98_30:                              # =>This Inner Loop Header: Depth=1
	mov	esi, edx
	mov	rsi, qword ptr [r14 + 8*rsi]
	lea	edi, [rax + rdx]
	mov	rdi, qword ptr [r14 + 8*rdi]
	mov	qword ptr [rsi], rdi
	add	rdx, 3
	cmp	rcx, rdx
	jne	.LBB98_30
.LBB98_31:
	add	rsp, 8
	pop	rbx
	pop	r14
	pop	r15
	pop	rbp
	ret
.Lfunc_end98:
	.size	_xt_simd_select, .Lfunc_end98-_xt_simd_select
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
	test	ecx, 402657280
	jne	.LBB99_4
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
	jne	.LBB99_4
# %bb.2:
	xor	r15d, r15d
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
	and	esi, 224
	xor	r15d, r15d
	or	esi, ebx
	sete	r15b
	inc	r15d
.LBB99_4:
	lea	rdi, [rip + .L.str]
	call	getenv@PLT
	test	rax, rax
	je	.LBB99_27
# %bb.5:
	movzx	ecx, byte ptr [rax]
	test	cl, cl
	je	.LBB99_6
# %bb.7:
	lea	rsi, [rax + 1]
	lea	rdx, [rip + .L.str.1]
	mov	edi, ecx
	.p2align	4, 0x90
.LBB99_8:                               # =>This Inner Loop Header: Depth=1
	cmp	dil, byte ptr [rdx]
	jne	.LBB99_10
# %bb.9:                                #   in Loop: Header=BB99_8 Depth=1
	inc	rdx
	movzx	edi, byte ptr [rsi]
	inc	rsi
	test	dil, dil
	jne	.LBB99_8
	jmp	.LBB99_10
.LBB99_6:
	lea	rdx, [rip + .L.str.1]
	mov	edi, ecx
.LBB99_10:
	xor	esi, esi
	cmp	dil, byte ptr [rdx]
	cmovne	esi, r15d
	je	.LBB99_28
# %bb.11:
	test	cl, cl
	je	.LBB99_12
# %bb.13:
	lea	rdi, [rax + 1]
	lea	rdx, [rip + .L.str.2]
	mov	esi, ecx
	.p2align	4, 0x90
.LBB99_14:                              # =>This Inner Loop Header: Depth=1
	cmp	sil, byte ptr [rdx]
	jne	.LBB99_16
# %bb.15:                               #   in Loop: Header=BB99_14 Depth=1
	inc	rdx
	movzx	esi, byte ptr [rdi]
	inc	rdi
	test	sil, sil
	jne	.LBB99_14
.LBB99_16:
	cmp	sil, byte ptr [rdx]
	jne	.LBB99_19
.LBB99_17:
	mov	esi, 1
	test	r15d, r15d
	jne	.LBB99_28
# %bb.18:
	lea	rsi, [rip + xt_simd_pick.msg]
	mov	edx, 66
	mov	edi, 2
	call	write@PLT
	xor	esi, esi
	jmp	.LBB99_28
.LBB99_12:
	lea	rdx, [rip + .L.str.2]
	mov	esi, ecx
	cmp	sil, byte ptr [rdx]
	je	.LBB99_17
.LBB99_19:
	test	cl, cl
	je	.LBB99_20
# %bb.21:
	inc	rax
	lea	rdx, [rip + .L.str.3]
	.p2align	4, 0x90
.LBB99_22:                              # =>This Inner Loop Header: Depth=1
	cmp	cl, byte ptr [rdx]
	jne	.LBB99_24
# %bb.23:                               #   in Loop: Header=BB99_22 Depth=1
	inc	rdx
	movzx	ecx, byte ptr [rax]
	inc	rax
	test	cl, cl
	jne	.LBB99_22
	jmp	.LBB99_24
.LBB99_20:
	lea	rdx, [rip + .L.str.3]
.LBB99_24:
	cmp	r15d, 1
	ja	.LBB99_27
# %bb.25:
	cmp	cl, byte ptr [rdx]
	jne	.LBB99_27
# %bb.26:
	lea	rsi, [rip + xt_simd_pick.msg.4]
	mov	edx, 82
	mov	edi, 2
	call	write@PLT
.LBB99_27:
	mov	esi, r15d
.LBB99_28:
	mov	dword ptr [rip + _xt_simd_level], esi
	test	ebp, ebp
	je	.LBB99_31
# %bb.29:
	mov	eax, ebp
	mov	ecx, esi
	inc	rcx
	shl	rax, 2
	xor	edx, edx
	.p2align	4, 0x90
.LBB99_30:                              # =>This Inner Loop Header: Depth=1
	mov	esi, edx
	mov	rsi, qword ptr [r14 + 8*rsi]
	lea	edi, [rcx + rdx]
	mov	rdi, qword ptr [r14 + 8*rdi]
	mov	qword ptr [rsi], rdi
	add	rdx, 4
	cmp	rax, rdx
	jne	.LBB99_30
.LBB99_31:
	add	rsp, 8
	pop	rbx
	pop	r14
	pop	r15
	pop	rbp
	ret
.Lfunc_end99:
	.size	_xt_simd_select4, .Lfunc_end99-_xt_simd_select4
                                        # -- End function
	.globl	_xt_thread_exiting              # -- Begin function _xt_thread_exiting
	.p2align	4, 0x90
	.type	_xt_thread_exiting,@function
_xt_thread_exiting:                     # @_xt_thread_exiting
# %bb.0:
	ret
.Lfunc_end100:
	.size	_xt_thread_exiting, .Lfunc_end100-_xt_thread_exiting
                                        # -- End function
	.p2align	4, 0x90                         # -- Begin function xt_simd_fault
	.type	xt_simd_fault,@function
xt_simd_fault:                          # @xt_simd_fault
# %bb.0:
	mov	rax, qword ptr [rsi + 16]
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB101_3
	.p2align	4, 0x90
.LBB101_1:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB101_2 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_rt_spin], ecx
	test	ecx, ecx
	je	.LBB101_3
.LBB101_2:                              #   Parent Loop BB101_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_rt_spin]
	test	ecx, ecx
	jne	.LBB101_2
	jmp	.LBB101_1
.LBB101_3:
	push	rbx
	mov	rdx, qword ptr [rip + xt_simd_n]
	test	rdx, rdx
	je	.LBB101_4
# %bb.5:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	xor	ecx, ecx
	movabs	r8, 2305843009213693950
	.p2align	4, 0x90
.LBB101_6:                              # =>This Inner Loop Header: Depth=1
	lea	r9, [rdx + rcx]
	mov	r10, r9
	shr	r10
	and	r9, r8
	cmp	qword ptr [rsi + 8*r9], rax
	lea	r9, [r10 + 1]
	cmova	rdx, r10
	cmovbe	rcx, r9
	cmp	rcx, rdx
	jb	.LBB101_6
	jmp	.LBB101_7
.LBB101_4:
	xor	ecx, ecx
.LBB101_7:
	mov	dl, 1
	test	rcx, rcx
	je	.LBB101_12
# %bb.8:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	lea	r8, [2*rcx - 2]
	cmp	qword ptr [rsi + 8*r8 + 8], rax
	jbe	.LBB101_12
# %bb.9:
	lea	rax, [rcx - 1]
	mov	rdx, qword ptr [rip + xt_simd_flag]
	movzx	r9d, byte ptr [rdx + rax]
	test	r9b, 1
	je	.LBB101_11
# %bb.10:
	lea	rcx, [2*rcx - 1]
	and	r9b, -2
	mov	byte ptr [rdx + rax], r9b
	mov	rax, qword ptr [rsi + 8*r8]
	mov	rsi, qword ptr [rsi + 8*rcx]
	sub	rsi, rax
	add	rsi, 16383
	and	rsi, -16384
	mov	edx, 3
	mov	ebx, edi
	mov	rdi, rax
	call	_sys_mprotect@PLT
	mov	edi, ebx
.LBB101_11:
	xor	edx, edx
.LBB101_12:
	cmp	dword ptr [rip + _xt_threads_active], 0
	pop	rbx
	je	.LBB101_14
# %bb.13:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB101_14:
	test	dl, dl
	je	.LBB101_15
# %bb.16:
	movsxd	rdi, edi
	xor	eax, eax
	cmp	edi, 11
	setne	al
	shl	eax, 5
	lea	rsi, [rip + xt_simd_old]
	add	rsi, rax
	mov	ecx, 8
	xor	edx, edx
	jmp	_sys_rt_sigaction@PLT           # TAILCALL
.LBB101_15:
	ret
.Lfunc_end101:
	.size	xt_simd_fault, .Lfunc_end101-xt_simd_fault
                                        # -- End function
	.p2align	4, 0x90                         # -- Begin function xt_wtab_put
	.type	xt_wtab_put,@function
xt_wtab_put:                            # @xt_wtab_put
# %bb.0:
	push	r15
	push	r14
	push	r13
	push	r12
	push	rbx
	mov	rbx, rsi
	mov	r14, rdi
	mov	rax, qword ptr [rip + xt_wtab_used]
	lea	rax, [2*rax + 2]
	mov	r12, qword ptr [rip + xt_wtab_cap]
	cmp	rax, r12
	jbe	.LBB102_19
# %bb.1:
	mov	r15, qword ptr [rip + xt_wtab]
	lea	rcx, [r12 + r12]
	test	r12, r12
	mov	eax, 64
	cmovne	rax, rcx
	mov	rcx, qword ptr [rip + xt_wtab_n]
	add	rcx, rcx
	.p2align	4, 0x90
.LBB102_2:                              # =>This Inner Loop Header: Depth=1
	mov	rdi, rax
	add	rax, rax
	cmp	rcx, rdi
	jae	.LBB102_2
# %bb.3:
	mov	qword ptr [rip + xt_wtab_cap], rdi
	shl	rdi, 4
	call	_xt_calloc
	mov	qword ptr [rip + xt_wtab], rax
	mov	qword ptr [rip + xt_wtab_n], 0
	mov	qword ptr [rip + xt_wtab_used], 0
	test	r12, r12
	je	.LBB102_8
# %bb.4:
	lea	r13, [r15 + 8]
	jmp	.LBB102_5
	.p2align	4, 0x90
.LBB102_7:                              #   in Loop: Header=BB102_5 Depth=1
	add	r13, 16
	dec	r12
	je	.LBB102_8
.LBB102_5:                              # =>This Inner Loop Header: Depth=1
	mov	rdi, qword ptr [r13 - 8]
	cmp	rdi, 2
	jb	.LBB102_7
# %bb.6:                                #   in Loop: Header=BB102_5 Depth=1
	mov	rsi, qword ptr [r13]
	call	xt_wtab_put
	jmp	.LBB102_7
.LBB102_8:
	test	r15, r15
	je	.LBB102_19
# %bb.9:
	mov	rax, qword ptr [r15 - 8]
	add	r15, -8
	cmp	rax, 64
	jae	.LBB102_10
# %bb.11:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB102_14
	.p2align	4, 0x90
.LBB102_12:                             # =>This Loop Header: Depth=1
                                        #     Child Loop BB102_13 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	je	.LBB102_14
.LBB102_13:                             #   Parent Loop BB102_12 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB102_13
	jmp	.LBB102_12
.LBB102_14:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB102_17
# %bb.15:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB102_10
# %bb.16:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB102_10:
	mov	rdi, r15
	call	free@PLT
.LBB102_19:
	mov	rax, r14
	shr	rax, 3
	mov	rcx, r14
	shr	rcx, 20
	xor	rcx, rax
	mov	eax, 3982152891
	imul	rax, rcx
	mov	rcx, rax
	shr	rcx, 11
	xor	rcx, rax
	mov	rsi, qword ptr [rip + xt_wtab_cap]
	dec	rsi
	mov	rax, qword ptr [rip + xt_wtab]
	.p2align	4, 0x90
.LBB102_20:                             # =>This Inner Loop Header: Depth=1
	and	rcx, rsi
	mov	rdx, rcx
	shl	rdx, 4
	mov	rdi, qword ptr [rax + rdx]
	inc	rcx
	cmp	rdi, 1
	ja	.LBB102_20
# %bb.21:
	lea	rcx, [rax + rdx]
	test	rdi, rdi
	jne	.LBB102_23
# %bb.22:
	inc	qword ptr [rip + xt_wtab_used]
.LBB102_23:
	mov	qword ptr [rcx], r14
	mov	qword ptr [rax + rdx + 8], rbx
	inc	qword ptr [rip + xt_wtab_n]
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	ret
.LBB102_17:
	lea	rsi, [rip + xt_cache]
	mov	rdi, qword ptr [rsi + 8*rax]
	mov	qword ptr [r15], rdi
	mov	qword ptr [rsi + 8*rax], r15
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB102_19
# %bb.18:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB102_19
.Lfunc_end102:
	.size	xt_wtab_put, .Lfunc_end102-xt_wtab_put
                                        # -- End function
	.type	xt_cache,@object                # @xt_cache
	.local	xt_cache
	.comm	xt_cache,512,16
	.type	xt_cache_n,@object              # @xt_cache_n
	.local	xt_cache_n
	.comm	xt_cache_n,256,16
	.hidden	__xt_stack_guard                # @__xt_stack_guard
	.type	__xt_stack_guard,@object
	.bss
	.globl	__xt_stack_guard
	.p2align	3, 0x0
__xt_stack_guard:
	.quad	0                               # 0x0
	.size	__xt_stack_guard, 8

	.type	__xt_stack_fail.msg,@object     # @__xt_stack_fail.msg
	.section	.rodata,"a",@progbits
	.p2align	4, 0x0
__xt_stack_fail.msg:
	.asciz	"xcc: stack smashing detected (a local array was written past its end)\n"
	.size	__xt_stack_fail.msg, 71

	.type	xt_simd_tab,@object             # @xt_simd_tab
	.local	xt_simd_tab
	.comm	xt_simd_tab,8,8
	.type	xt_simd_flag,@object            # @xt_simd_flag
	.local	xt_simd_flag
	.comm	xt_simd_flag,8,8
	.type	xt_wtab_n,@object               # @xt_wtab_n
	.local	xt_wtab_n
	.comm	xt_wtab_n,8,8
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

	.type	_xt_simd_level,@object          # @_xt_simd_level
	.globl	_xt_simd_level
	.p2align	2, 0x0
_xt_simd_level:
	.long	4294967295                      # 0xffffffff
	.size	_xt_simd_level, 4

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
	.type	xt_wcell_free,@object           # @xt_wcell_free
	.local	xt_wcell_free
	.comm	xt_wcell_free,8,8
	.type	xt_wtab_used,@object            # @xt_wtab_used
	.local	xt_wtab_used
	.comm	xt_wtab_used,8,8
	.type	xt_wtab_cap,@object             # @xt_wtab_cap
	.local	xt_wtab_cap
	.comm	xt_wtab_cap,8,8
	.type	xt_wtab,@object                 # @xt_wtab
	.local	xt_wtab
	.comm	xt_wtab,8,8
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
	.addrsig_sym _xt_stack_guard_init
	.addrsig_sym xt_thread_entry
	.addrsig_sym xt_simd_fault
	.addrsig_sym xt_sigrestore
	.addrsig_sym __xt_stack_fail.msg
	.addrsig_sym xt_rt_spin
	.addrsig_sym xt_alloc_spin
	.addrsig_sym xt_reap_spin
	.addrsig_sym xt_tls_keyspin
	.addrsig_sym xt_size_check.msg
	.addrsig_sym xt_simd_old
	.addrsig_sym xt_simd_pick.msg
	.addrsig_sym xt_simd_pick.msg.4

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
