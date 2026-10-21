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
	.globl	_xt_stack_guard_init            # -- Begin function _xt_stack_guard_init
	.p2align	4, 0x90
	.type	_xt_stack_guard_init,@function
_xt_stack_guard_init:                   # @_xt_stack_guard_init
# %bb.0:
	push	rbx
	sub	rsp, 16
	mov	qword ptr [rsp + 8], 0
	lea	rbx, [rsp + 8]
	mov	esi, 8
	mov	rdi, rbx
	xor	edx, edx
	call	getrandom@PLT
	cmp	rax, 8
	je	.LBB13_2
# %bb.1:
	mov	qword ptr [rsp + 8], 0
.LBB13_2:
	cmp	qword ptr [rsp + 8], 0
	jne	.LBB13_4
# %bb.3:
	#APP

	rdtsc

	#NO_APP
                                        # kill: def $edx killed $edx def $rdx
	shl	rdx, 32
	mov	eax, eax
	or	rax, rdx
	movabs	rcx, -7046029254386353131
	imul	rcx, rax
	mov	rax, rbx
	shl	rax, 17
	shr	rbx, 13
	xor	rbx, rax
	xor	rbx, rcx
	movabs	rax, -4417276706812531889
	imul	rax, qword ptr [rip + _xt_stack_guard_init@GOTPCREL]
	xor	rax, rbx
	mov	rcx, rax
	shr	rcx, 31
	xor	rcx, rax
	movabs	rax, -7723592293110705685
	imul	rax, rcx
	mov	rcx, rax
	shr	rcx, 29
	xor	rcx, rax
	mov	qword ptr [rsp + 8], rcx
.LBB13_4:
	mov	rax, -256
	and	rax, qword ptr [rsp + 8]
	movabs	rcx, 6364786164175470592
	cmovne	rcx, rax
	mov	qword ptr [rip + __xt_stack_guard], rcx
	add	rsp, 16
	pop	rbx
	ret
.Lfunc_end13:
	.size	_xt_stack_guard_init, .Lfunc_end13-_xt_stack_guard_init
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
.Lfunc_end14:
	.size	__xt_stack_fail, .Lfunc_end14-__xt_stack_fail
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
	je	.LBB15_3
# %bb.1:
	mov	rax, -1048577
	xor	edx, edx
	div	r15
	cmp	rax, r14
	jae	.LBB15_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB15_3:
	mov	rax, r15
	imul	rax, r14
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB15_4
# %bb.5:
	mov	dword ptr [rax], 1481920322
	mov	qword ptr [rax + 4], r15
	mov	qword ptr [rax + 12], r14
	mov	qword ptr [rax + 20], rbx
	mov	qword ptr [rax + 28], 0
	mov	dword ptr [rax + 36], 1
	add	rax, 40
	jmp	.LBB15_6
.LBB15_4:
	xor	eax, eax
.LBB15_6:
	pop	rbx
	pop	r14
	pop	r15
	ret
.Lfunc_end15:
	.size	_xtc_alloc, .Lfunc_end15-_xtc_alloc
                                        # -- End function
	.globl	_xtc_simd_register              # -- Begin function _xtc_simd_register
	.p2align	4, 0x90
	.type	_xtc_simd_register,@function
_xtc_simd_register:                     # @_xtc_simd_register
# %bb.0:
	test	rdi, rdi
	je	.LBB16_76
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
	je	.LBB16_75
# %bb.2:
	mov	r14, rdi
	mov	eax, r14d
	or	eax, ebx
	and	eax, 4095
	jne	.LBB16_75
# %bb.3:
	mov	r12, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [r12], 0
	je	.LBB16_6
	.p2align	4, 0x90
.LBB16_4:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB16_5 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB16_6
.LBB16_5:                               #   Parent Loop BB16_4 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB16_5
	jmp	.LBB16_4
.LBB16_6:
	mov	rax, qword ptr [rip + xt_simd_cap]
	cmp	qword ptr [rip + xt_simd_n], rax
	jne	.LBB16_66
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
	jne	.LBB16_17
# %bb.8:
	mov	rax, qword ptr [rip + xt_simd_n]
	mov	rcx, rax
	add	rcx, rax
	je	.LBB16_11
# %bb.9:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	esi, esi
	.p2align	4, 0x90
.LBB16_10:                              # =>This Inner Loop Header: Depth=1
	mov	rdi, qword ptr [rdx + 8*rsi]
	mov	qword ptr [r13 + 8*rsi], rdi
	inc	rsi
	cmp	rcx, rsi
	jne	.LBB16_10
.LBB16_11:
	test	rax, rax
	je	.LBB16_14
# %bb.12:
	mov	rcx, qword ptr [rip + xt_simd_flag]
	xor	edx, edx
	.p2align	4, 0x90
.LBB16_13:                              # =>This Inner Loop Header: Depth=1
	movzx	esi, byte ptr [rcx + rdx]
	mov	byte ptr [r15 + rdx], sil
	inc	rdx
	cmp	rax, rdx
	jne	.LBB16_13
.LBB16_14:
	mov	rdi, qword ptr [rip + xt_simd_tab]
	test	rdi, rdi
	je	.LBB16_36
# %bb.15:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	.LBB16_16
# %bb.20:
	mov	rcx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rcx], 0
	jne	.LBB16_22
	jmp	.LBB16_23
	.p2align	4, 0x90
.LBB16_21:                              #   Parent Loop BB16_22 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB16_21
.LBB16_22:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB16_21 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB16_21
.LBB16_23:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB16_34
# %bb.24:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB16_16
# %bb.25:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB16_16:
	call	free@PLT
.LBB16_36:
	mov	rdi, qword ptr [rip + xt_simd_flag]
	test	rdi, rdi
	je	.LBB16_60
# %bb.37:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	.LBB16_38
# %bb.39:
	mov	rcx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rcx], 0
	jne	.LBB16_41
	jmp	.LBB16_42
	.p2align	4, 0x90
.LBB16_40:                              #   Parent Loop BB16_41 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB16_40
.LBB16_41:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB16_40 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB16_40
.LBB16_42:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB16_58
# %bb.43:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB16_38
# %bb.44:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB16_38:
	call	free@PLT
.LBB16_60:
	mov	qword ptr [rip + xt_simd_tab], r13
	mov	qword ptr [rip + xt_simd_flag], r15
	mov	qword ptr [rip + xt_simd_cap], r12
	mov	r12, qword ptr [rip + _xt_threads_active@GOTPCREL]
	jmp	.LBB16_65
.LBB16_17:
	test	r13, r13
	mov	r12, qword ptr [rip + _xt_threads_active@GOTPCREL]
	je	.LBB16_48
# %bb.18:
	mov	rdi, r13
	add	rdi, -8
	mov	rax, qword ptr [r13 - 8]
	cmp	rax, 64
	jae	.LBB16_19
# %bb.27:
	cmp	dword ptr [r12], 0
	jne	.LBB16_29
	jmp	.LBB16_30
	.p2align	4, 0x90
.LBB16_28:                              #   Parent Loop BB16_29 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB16_28
.LBB16_29:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB16_28 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB16_28
.LBB16_30:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB16_46
# %bb.31:
	cmp	dword ptr [r12], 0
	je	.LBB16_19
# %bb.32:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB16_19:
	call	free@PLT
.LBB16_48:
	test	r15, r15
	je	.LBB16_63
# %bb.49:
	mov	rdi, r15
	add	rdi, -8
	mov	rax, qword ptr [r15 - 8]
	cmp	rax, 64
	jae	.LBB16_50
# %bb.51:
	cmp	dword ptr [r12], 0
	jne	.LBB16_53
	jmp	.LBB16_54
	.p2align	4, 0x90
.LBB16_52:                              #   Parent Loop BB16_53 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB16_52
.LBB16_53:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB16_52 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB16_52
.LBB16_54:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB16_61
# %bb.55:
	cmp	dword ptr [r12], 0
	je	.LBB16_50
# %bb.56:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB16_50:
	call	free@PLT
.LBB16_63:
	cmp	dword ptr [r12], 0
	je	.LBB16_65
# %bb.64:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB16_65:
	test	bpl, bpl
	je	.LBB16_75
.LBB16_66:
	mov	rax, qword ptr [rip + xt_simd_n]
	test	rax, rax
	je	.LBB16_70
# %bb.67:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	ecx, ecx
	movabs	rsi, 2305843009213693950
	mov	rdi, rax
	.p2align	4, 0x90
.LBB16_68:                              # =>This Inner Loop Header: Depth=1
	lea	r8, [rdi + rcx]
	mov	r9, r8
	shr	r9
	and	r8, rsi
	cmp	qword ptr [rdx + 8*r8], r14
	lea	r8, [r9 + 1]
	cmova	rdi, r9
	cmovbe	rcx, r8
	cmp	rcx, rdi
	jb	.LBB16_68
# %bb.69:
	cmp	rax, rcx
	ja	.LBB16_71
	jmp	.LBB16_73
.LBB16_70:
	xor	ecx, ecx
	cmp	rax, rcx
	jbe	.LBB16_73
.LBB16_71:
	mov	rdx, qword ptr [rip + xt_simd_flag]
	mov	rdi, rax
	shl	rdi, 4
	add	rdi, qword ptr [rip + xt_simd_tab]
	mov	rsi, rax
	.p2align	4, 0x90
.LBB16_72:                              # =>This Inner Loop Header: Depth=1
	movups	xmm0, xmmword ptr [rdi - 16]
	movups	xmmword ptr [rdi], xmm0
	add	rdi, -16
	movzx	r8d, byte ptr [rdx + rsi - 1]
	mov	byte ptr [rdx + rsi], r8b
	dec	rsi
	cmp	rsi, rcx
	ja	.LBB16_72
.LBB16_73:
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
	je	.LBB16_75
# %bb.74:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB16_75:
	add	rsp, 8
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	pop	rbp
.LBB16_76:
	ret
.LBB16_34:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB16_36
# %bb.35:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB16_36
.LBB16_58:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB16_60
# %bb.59:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB16_60
.LBB16_46:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [r12], 0
	je	.LBB16_48
# %bb.47:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB16_48
.LBB16_61:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [r12], 0
	je	.LBB16_63
# %bb.62:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB16_63
.Lfunc_end16:
	.size	_xtc_simd_register, .Lfunc_end16-_xtc_simd_register
                                        # -- End function
	.globl	_xtc_simd_base                  # -- Begin function _xtc_simd_base
	.p2align	4, 0x90
	.type	_xtc_simd_base,@function
_xtc_simd_base:                         # @_xtc_simd_base
# %bb.0:
	mov	rcx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rcx], 0
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
	mov	rdx, qword ptr [rip + xt_simd_n]
	test	rdx, rdx
	je	.LBB17_9
# %bb.4:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	xor	eax, eax
	movabs	r8, 2305843009213693950
	.p2align	4, 0x90
.LBB17_5:                               # =>This Inner Loop Header: Depth=1
	lea	r9, [rdx + rax]
	mov	r10, r9
	shr	r10
	and	r9, r8
	cmp	qword ptr [rsi + 8*r9], rdi
	lea	r9, [r10 + 1]
	cmova	rdx, r10
	cmovbe	rax, r9
	cmp	rax, rdx
	jb	.LBB17_5
# %bb.6:
	test	rax, rax
	jne	.LBB17_7
	jmp	.LBB17_10
.LBB17_9:
	xor	eax, eax
	test	rax, rax
	je	.LBB17_10
.LBB17_7:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	shl	rax, 4
	cmp	qword ptr [rdx + rax - 8], rdi
	jbe	.LBB17_10
# %bb.8:
	mov	rax, qword ptr [rdx + rax - 16]
	cmp	dword ptr [rcx], 0
	jne	.LBB17_11
	jmp	.LBB17_12
.LBB17_10:
	xor	eax, eax
	cmp	dword ptr [rcx], 0
	je	.LBB17_12
.LBB17_11:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB17_12:
	ret
.Lfunc_end17:
	.size	_xtc_simd_base, .Lfunc_end17-_xtc_simd_base
                                        # -- End function
	.globl	_xt_rt_lock                     # -- Begin function _xt_rt_lock
	.p2align	4, 0x90
	.type	_xt_rt_lock,@function
_xt_rt_lock:                            # @_xt_rt_lock
# %bb.0:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
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
	ret
.Lfunc_end18:
	.size	_xt_rt_lock, .Lfunc_end18-_xt_rt_lock
                                        # -- End function
	.globl	_xt_rt_unlock                   # -- Begin function _xt_rt_unlock
	.p2align	4, 0x90
	.type	_xt_rt_unlock,@function
_xt_rt_unlock:                          # @_xt_rt_unlock
# %bb.0:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB19_2
# %bb.1:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB19_2:
	ret
.Lfunc_end19:
	.size	_xt_rt_unlock, .Lfunc_end19-_xt_rt_unlock
                                        # -- End function
	.globl	_xtc_simd_span                  # -- Begin function _xtc_simd_span
	.p2align	4, 0x90
	.type	_xtc_simd_span,@function
_xtc_simd_span:                         # @_xtc_simd_span
# %bb.0:
	mov	rcx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rcx], 0
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
	mov	rax, qword ptr [rip + xt_simd_n]
	test	rax, rax
	je	.LBB20_4
# %bb.5:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	xor	edx, edx
	movabs	r8, 2305843009213693950
	.p2align	4, 0x90
.LBB20_6:                               # =>This Inner Loop Header: Depth=1
	lea	r9, [rax + rdx]
	mov	r10, r9
	shr	r10
	and	r9, r8
	cmp	qword ptr [rsi + 8*r9], rdi
	lea	r9, [r10 + 1]
	cmova	rax, r10
	cmovbe	rdx, r9
	cmp	rdx, rax
	jb	.LBB20_6
	jmp	.LBB20_7
.LBB20_4:
	xor	edx, edx
.LBB20_7:
	mov	rax, -1
	test	rdx, rdx
	je	.LBB20_10
# %bb.8:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	shl	rdx, 4
	mov	rdx, qword ptr [rsi + rdx - 8]
	sub	rdx, rdi
	jbe	.LBB20_10
# %bb.9:
	mov	rax, rdx
.LBB20_10:
	cmp	dword ptr [rcx], 0
	je	.LBB20_12
# %bb.11:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB20_12:
	ret
.Lfunc_end20:
	.size	_xtc_simd_span, .Lfunc_end20-_xtc_simd_span
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
	xor	ebx, ebx
	test	rax, rax
	je	.LBB21_4
# %bb.5:
	mov	rcx, qword ptr [rip + xt_simd_tab]
	xor	r12d, r12d
	movabs	rdx, 2305843009213693950
	.p2align	4, 0x90
.LBB21_6:                               # =>This Inner Loop Header: Depth=1
	lea	rsi, [rax + r12]
	mov	r8, rsi
	shr	r8
	and	rsi, rdx
	cmp	qword ptr [rcx + 8*rsi], rdi
	lea	rsi, [r8 + 1]
	cmova	rax, r8
	cmovbe	r12, rsi
	cmp	r12, rax
	jb	.LBB21_6
# %bb.7:
	test	r12, r12
	jne	.LBB21_8
	jmp	.LBB21_13
.LBB21_4:
	xor	r12d, r12d
	test	r12, r12
	je	.LBB21_13
.LBB21_8:
	mov	rax, qword ptr [rip + xt_simd_tab]
	dec	r12
	mov	r13, r12
	shl	r13, 4
	cmp	qword ptr [rax + r13], rdi
	jne	.LBB21_13
# %bb.9:
	cmp	byte ptr [rip + xt_simd_installed], 0
	jne	.LBB21_11
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
.LBB21_11:
	mov	rax, qword ptr [rip + xt_simd_tab]
	mov	rsi, qword ptr [rax + r13 + 8]
	sub	rsi, qword ptr [rax + r13]
	add	rsi, 16383
	and	rsi, -16384
	mov	edx, 1
	call	mprotect@PLT
	test	eax, eax
	jne	.LBB21_13
# %bb.12:
	mov	rax, qword ptr [rip + xt_simd_flag]
	or	byte ptr [rax + r12], 1
	mov	ebx, 1
.LBB21_13:
	cmp	dword ptr [r15], 0
	je	.LBB21_15
# %bb.14:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB21_15:
	mov	eax, ebx
	add	rsp, 40
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	pop	rbp
	ret
.Lfunc_end21:
	.size	_xtc_simd_watch, .Lfunc_end21-_xtc_simd_watch
                                        # -- End function
	.globl	_xtc_simd_unwatch               # -- Begin function _xtc_simd_unwatch
	.p2align	4, 0x90
	.type	_xtc_simd_unwatch,@function
_xtc_simd_unwatch:                      # @_xtc_simd_unwatch
# %bb.0:
	push	rbx
	mov	rbx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rbx], 0
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
	mov	rcx, qword ptr [rip + xt_simd_n]
	test	rcx, rcx
	je	.LBB22_4
# %bb.5:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	eax, eax
	movabs	rsi, 2305843009213693950
	.p2align	4, 0x90
.LBB22_6:                               # =>This Inner Loop Header: Depth=1
	lea	r8, [rcx + rax]
	mov	r9, r8
	shr	r9
	and	r8, rsi
	cmp	qword ptr [rdx + 8*r8], rdi
	lea	r8, [r9 + 1]
	cmova	rcx, r9
	cmovbe	rax, r8
	cmp	rax, rcx
	jb	.LBB22_6
# %bb.7:
	test	rax, rax
	jne	.LBB22_8
	jmp	.LBB22_11
.LBB22_4:
	xor	eax, eax
	test	rax, rax
	je	.LBB22_11
.LBB22_8:
	mov	rcx, qword ptr [rip + xt_simd_tab]
	dec	rax
	mov	rdx, rax
	shl	rdx, 4
	cmp	qword ptr [rcx + rdx], rdi
	jne	.LBB22_11
# %bb.9:
	mov	rsi, qword ptr [rip + xt_simd_flag]
	movzx	r8d, byte ptr [rsi + rax]
	test	r8b, 1
	je	.LBB22_11
# %bb.10:
	and	r8b, -2
	mov	byte ptr [rsi + rax], r8b
	mov	rsi, qword ptr [rcx + rdx + 8]
	sub	rsi, qword ptr [rcx + rdx]
	add	rsi, 16383
	and	rsi, -16384
	mov	edx, 3
	call	mprotect@PLT
.LBB22_11:
	cmp	dword ptr [rbx], 0
	je	.LBB22_13
# %bb.12:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB22_13:
	pop	rbx
	ret
.Lfunc_end22:
	.size	_xtc_simd_unwatch, .Lfunc_end22-_xtc_simd_unwatch
                                        # -- End function
	.globl	_xtc_simd_dirty                 # -- Begin function _xtc_simd_dirty
	.p2align	4, 0x90
	.type	_xtc_simd_dirty,@function
_xtc_simd_dirty:                        # @_xtc_simd_dirty
# %bb.0:
	mov	rcx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rcx], 0
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
	mov	rax, qword ptr [rip + xt_simd_n]
	test	rax, rax
	je	.LBB23_4
# %bb.5:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	xor	edx, edx
	movabs	r8, 2305843009213693950
	.p2align	4, 0x90
.LBB23_6:                               # =>This Inner Loop Header: Depth=1
	lea	r9, [rax + rdx]
	mov	r10, r9
	shr	r10
	and	r9, r8
	cmp	qword ptr [rsi + 8*r9], rdi
	lea	r9, [r10 + 1]
	cmova	rax, r10
	cmovbe	rdx, r9
	cmp	rdx, rax
	jb	.LBB23_6
	jmp	.LBB23_7
.LBB23_4:
	xor	edx, edx
.LBB23_7:
	mov	eax, 1
	test	rdx, rdx
	je	.LBB23_10
# %bb.8:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	dec	rdx
	mov	r8, rdx
	shl	r8, 4
	cmp	qword ptr [rsi + r8], rdi
	jne	.LBB23_10
# %bb.9:
	mov	rax, qword ptr [rip + xt_simd_flag]
	movzx	eax, byte ptr [rax + rdx]
	not	eax
	and	eax, 1
.LBB23_10:
	cmp	dword ptr [rcx], 0
	je	.LBB23_12
# %bb.11:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB23_12:
	ret
.Lfunc_end23:
	.size	_xtc_simd_dirty, .Lfunc_end23-_xtc_simd_dirty
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
	je	.LBB24_3
# %bb.1:
	mov	rax, -1048577
	xor	edx, edx
	div	r12
	cmp	rax, r15
	jae	.LBB24_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB24_3:
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
	je	.LBB24_18
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
	je	.LBB24_7
	.p2align	4, 0x90
.LBB24_5:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB24_6 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB24_7
.LBB24_6:                               #   Parent Loop BB24_5 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB24_6
	jmp	.LBB24_5
.LBB24_7:
	mov	rax, qword ptr [rip + xt_simd_cap]
	cmp	qword ptr [rip + xt_simd_n], rax
	jne	.LBB24_68
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
	jne	.LBB24_19
# %bb.9:
	mov	rax, qword ptr [rip + xt_simd_n]
	mov	rcx, rax
	add	rcx, rax
	je	.LBB24_12
# %bb.10:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	esi, esi
	.p2align	4, 0x90
.LBB24_11:                              # =>This Inner Loop Header: Depth=1
	mov	rdi, qword ptr [rdx + 8*rsi]
	mov	qword ptr [r12 + 8*rsi], rdi
	inc	rsi
	cmp	rcx, rsi
	jne	.LBB24_11
.LBB24_12:
	test	rax, rax
	je	.LBB24_15
# %bb.13:
	mov	rcx, qword ptr [rip + xt_simd_flag]
	xor	edx, edx
	.p2align	4, 0x90
.LBB24_14:                              # =>This Inner Loop Header: Depth=1
	movzx	esi, byte ptr [rcx + rdx]
	mov	byte ptr [r14 + rdx], sil
	inc	rdx
	cmp	rax, rdx
	jne	.LBB24_14
.LBB24_15:
	mov	rdi, qword ptr [rip + xt_simd_tab]
	test	rdi, rdi
	je	.LBB24_38
# %bb.16:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	.LBB24_17
# %bb.22:
	mov	rcx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rcx], 0
	jne	.LBB24_24
	jmp	.LBB24_25
	.p2align	4, 0x90
.LBB24_23:                              #   Parent Loop BB24_24 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB24_23
.LBB24_24:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB24_23 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB24_23
.LBB24_25:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB24_36
# %bb.26:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB24_17
# %bb.27:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB24_17:
	call	free@PLT
.LBB24_38:
	mov	rdi, qword ptr [rip + xt_simd_flag]
	test	rdi, rdi
	je	.LBB24_62
# %bb.39:
	mov	rax, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rax, 64
	jae	.LBB24_40
# %bb.41:
	mov	rcx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rcx], 0
	jne	.LBB24_43
	jmp	.LBB24_44
	.p2align	4, 0x90
.LBB24_42:                              #   Parent Loop BB24_43 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB24_42
.LBB24_43:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB24_42 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB24_42
.LBB24_44:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB24_60
# %bb.45:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB24_40
# %bb.46:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB24_40:
	call	free@PLT
.LBB24_62:
	mov	qword ptr [rip + xt_simd_tab], r12
	mov	qword ptr [rip + xt_simd_flag], r14
	mov	qword ptr [rip + xt_simd_cap], r15
	mov	r15, qword ptr [rip + _xt_threads_active@GOTPCREL]
	jmp	.LBB24_67
.LBB24_18:
	xor	ebx, ebx
	jmp	.LBB24_77
.LBB24_19:
	test	r12, r12
	mov	r15, qword ptr [rip + _xt_threads_active@GOTPCREL]
	je	.LBB24_50
# %bb.20:
	mov	rdi, r12
	add	rdi, -8
	mov	rax, qword ptr [r12 - 8]
	cmp	rax, 64
	jae	.LBB24_21
# %bb.29:
	cmp	dword ptr [r15], 0
	jne	.LBB24_31
	jmp	.LBB24_32
	.p2align	4, 0x90
.LBB24_30:                              #   Parent Loop BB24_31 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB24_30
.LBB24_31:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB24_30 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB24_30
.LBB24_32:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB24_48
# %bb.33:
	cmp	dword ptr [r15], 0
	je	.LBB24_21
# %bb.34:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB24_21:
	call	free@PLT
.LBB24_50:
	test	r14, r14
	je	.LBB24_65
# %bb.51:
	mov	rdi, r14
	add	rdi, -8
	mov	rax, qword ptr [r14 - 8]
	cmp	rax, 64
	jae	.LBB24_52
# %bb.53:
	cmp	dword ptr [r15], 0
	jne	.LBB24_55
	jmp	.LBB24_56
	.p2align	4, 0x90
.LBB24_54:                              #   Parent Loop BB24_55 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_alloc_spin]
	test	ecx, ecx
	jne	.LBB24_54
.LBB24_55:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB24_54 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_alloc_spin], ecx
	test	ecx, ecx
	jne	.LBB24_54
.LBB24_56:
	lea	rcx, [rip + xt_cache_n]
	mov	edx, dword ptr [rcx + 4*rax]
	cmp	edx, 64
	jb	.LBB24_63
# %bb.57:
	cmp	dword ptr [r15], 0
	je	.LBB24_52
# %bb.58:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB24_52:
	call	free@PLT
.LBB24_65:
	cmp	dword ptr [r15], 0
	je	.LBB24_67
# %bb.66:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB24_67:
	test	bpl, bpl
	je	.LBB24_77
.LBB24_68:
	mov	rax, qword ptr [rip + xt_simd_n]
	test	rax, rax
	je	.LBB24_72
# %bb.69:
	mov	rdx, qword ptr [rip + xt_simd_tab]
	xor	ecx, ecx
	movabs	rsi, 2305843009213693950
	mov	rdi, rax
	.p2align	4, 0x90
.LBB24_70:                              # =>This Inner Loop Header: Depth=1
	lea	r8, [rdi + rcx]
	mov	r9, r8
	shr	r9
	and	r8, rsi
	cmp	qword ptr [rdx + 8*r8], rbx
	lea	r8, [r9 + 1]
	cmova	rdi, r9
	cmovbe	rcx, r8
	cmp	rcx, rdi
	jb	.LBB24_70
# %bb.71:
	cmp	rax, rcx
	ja	.LBB24_73
	jmp	.LBB24_75
.LBB24_72:
	xor	ecx, ecx
	cmp	rax, rcx
	jbe	.LBB24_75
.LBB24_73:
	mov	rdx, qword ptr [rip + xt_simd_flag]
	mov	rdi, rax
	shl	rdi, 4
	add	rdi, qword ptr [rip + xt_simd_tab]
	mov	rsi, rax
	.p2align	4, 0x90
.LBB24_74:                              # =>This Inner Loop Header: Depth=1
	movups	xmm0, xmmword ptr [rdi - 16]
	movups	xmmword ptr [rdi], xmm0
	add	rdi, -16
	movzx	r8d, byte ptr [rdx + rsi - 1]
	mov	byte ptr [rdx + rsi], r8b
	dec	rsi
	cmp	rsi, rcx
	ja	.LBB24_74
.LBB24_75:
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
	je	.LBB24_77
# %bb.76:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB24_77:
	mov	rax, rbx
	add	rsp, 8
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	pop	rbp
	ret
.LBB24_36:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB24_38
# %bb.37:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB24_38
.LBB24_60:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB24_62
# %bb.61:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB24_62
.LBB24_48:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [r15], 0
	je	.LBB24_50
# %bb.49:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB24_50
.LBB24_63:
	lea	rsi, [rip + xt_cache]
	mov	r8, qword ptr [rsi + 8*rax]
	mov	qword ptr [rdi], r8
	mov	qword ptr [rsi + 8*rax], rdi
	inc	edx
	mov	dword ptr [rcx + 4*rax], edx
	cmp	dword ptr [r15], 0
	je	.LBB24_65
# %bb.64:
	mov	dword ptr [rip + xt_alloc_spin], 0
	jmp	.LBB24_65
.Lfunc_end24:
	.size	_xtc_alloc_aligned, .Lfunc_end24-_xtc_alloc_aligned
                                        # -- End function
	.globl	_xtc_new_simd_u8                # -- Begin function _xtc_new_simd_u8
	.p2align	4, 0x90
	.type	_xtc_new_simd_u8,@function
_xtc_new_simd_u8:                       # @_xtc_new_simd_u8
# %bb.0:
	mov	esi, 1
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end25:
	.size	_xtc_new_simd_u8, .Lfunc_end25-_xtc_new_simd_u8
                                        # -- End function
	.globl	_xtc_new_simd_i8                # -- Begin function _xtc_new_simd_i8
	.p2align	4, 0x90
	.type	_xtc_new_simd_i8,@function
_xtc_new_simd_i8:                       # @_xtc_new_simd_i8
# %bb.0:
	mov	esi, 1
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end26:
	.size	_xtc_new_simd_i8, .Lfunc_end26-_xtc_new_simd_i8
                                        # -- End function
	.globl	_xtc_new_simd_bool              # -- Begin function _xtc_new_simd_bool
	.p2align	4, 0x90
	.type	_xtc_new_simd_bool,@function
_xtc_new_simd_bool:                     # @_xtc_new_simd_bool
# %bb.0:
	mov	esi, 1
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end27:
	.size	_xtc_new_simd_bool, .Lfunc_end27-_xtc_new_simd_bool
                                        # -- End function
	.globl	_xtc_new_simd_u16               # -- Begin function _xtc_new_simd_u16
	.p2align	4, 0x90
	.type	_xtc_new_simd_u16,@function
_xtc_new_simd_u16:                      # @_xtc_new_simd_u16
# %bb.0:
	mov	esi, 2
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end28:
	.size	_xtc_new_simd_u16, .Lfunc_end28-_xtc_new_simd_u16
                                        # -- End function
	.globl	_xtc_new_simd_i16               # -- Begin function _xtc_new_simd_i16
	.p2align	4, 0x90
	.type	_xtc_new_simd_i16,@function
_xtc_new_simd_i16:                      # @_xtc_new_simd_i16
# %bb.0:
	mov	esi, 2
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end29:
	.size	_xtc_new_simd_i16, .Lfunc_end29-_xtc_new_simd_i16
                                        # -- End function
	.globl	_xtc_new_simd_u32               # -- Begin function _xtc_new_simd_u32
	.p2align	4, 0x90
	.type	_xtc_new_simd_u32,@function
_xtc_new_simd_u32:                      # @_xtc_new_simd_u32
# %bb.0:
	mov	esi, 4
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end30:
	.size	_xtc_new_simd_u32, .Lfunc_end30-_xtc_new_simd_u32
                                        # -- End function
	.globl	_xtc_new_simd_i32               # -- Begin function _xtc_new_simd_i32
	.p2align	4, 0x90
	.type	_xtc_new_simd_i32,@function
_xtc_new_simd_i32:                      # @_xtc_new_simd_i32
# %bb.0:
	mov	esi, 4
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end31:
	.size	_xtc_new_simd_i32, .Lfunc_end31-_xtc_new_simd_i32
                                        # -- End function
	.globl	_xtc_new_simd_float             # -- Begin function _xtc_new_simd_float
	.p2align	4, 0x90
	.type	_xtc_new_simd_float,@function
_xtc_new_simd_float:                    # @_xtc_new_simd_float
# %bb.0:
	mov	esi, 4
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end32:
	.size	_xtc_new_simd_float, .Lfunc_end32-_xtc_new_simd_float
                                        # -- End function
	.globl	_xtc_new_simd_u64               # -- Begin function _xtc_new_simd_u64
	.p2align	4, 0x90
	.type	_xtc_new_simd_u64,@function
_xtc_new_simd_u64:                      # @_xtc_new_simd_u64
# %bb.0:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end33:
	.size	_xtc_new_simd_u64, .Lfunc_end33-_xtc_new_simd_u64
                                        # -- End function
	.globl	_xtc_new_simd_i64               # -- Begin function _xtc_new_simd_i64
	.p2align	4, 0x90
	.type	_xtc_new_simd_i64,@function
_xtc_new_simd_i64:                      # @_xtc_new_simd_i64
# %bb.0:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end34:
	.size	_xtc_new_simd_i64, .Lfunc_end34-_xtc_new_simd_i64
                                        # -- End function
	.globl	_xtc_new_simd_double            # -- Begin function _xtc_new_simd_double
	.p2align	4, 0x90
	.type	_xtc_new_simd_double,@function
_xtc_new_simd_double:                   # @_xtc_new_simd_double
# %bb.0:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end35:
	.size	_xtc_new_simd_double, .Lfunc_end35-_xtc_new_simd_double
                                        # -- End function
	.globl	_xtc_new_simd_pointer           # -- Begin function _xtc_new_simd_pointer
	.p2align	4, 0x90
	.type	_xtc_new_simd_pointer,@function
_xtc_new_simd_pointer:                  # @_xtc_new_simd_pointer
# %bb.0:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end36:
	.size	_xtc_new_simd_pointer, .Lfunc_end36-_xtc_new_simd_pointer
                                        # -- End function
	.globl	_xtc_new_simd_string            # -- Begin function _xtc_new_simd_string
	.p2align	4, 0x90
	.type	_xtc_new_simd_string,@function
_xtc_new_simd_string:                   # @_xtc_new_simd_string
# %bb.0:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.Lfunc_end37:
	.size	_xtc_new_simd_string, .Lfunc_end37-_xtc_new_simd_string
                                        # -- End function
	.globl	_xtc_new_u8                     # -- Begin function _xtc_new_u8
	.p2align	4, 0x90
	.type	_xtc_new_u8,@function
_xtc_new_u8:                            # @_xtc_new_u8
# %bb.0:
	cmp	rdi, 65536
	jb	.LBB38_1
# %bb.5:
	mov	esi, 1
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.LBB38_1:
	push	rbx
	cmp	rdi, 17
	mov	eax, 16
	mov	rbx, rdi
	cmovae	rax, rdi
	add	rax, 40
	mov	rdi, rax
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB38_2
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
.LBB38_2:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end38:
	.size	_xtc_new_u8, .Lfunc_end38-_xtc_new_u8
                                        # -- End function
	.globl	_xtc_new_i8                     # -- Begin function _xtc_new_i8
	.p2align	4, 0x90
	.type	_xtc_new_i8,@function
_xtc_new_i8:                            # @_xtc_new_i8
# %bb.0:
	cmp	rdi, 65536
	jb	.LBB39_1
# %bb.5:
	mov	esi, 1
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.LBB39_1:
	push	rbx
	cmp	rdi, 17
	mov	eax, 16
	mov	rbx, rdi
	cmovae	rax, rdi
	add	rax, 40
	mov	rdi, rax
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB39_2
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
.LBB39_2:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end39:
	.size	_xtc_new_i8, .Lfunc_end39-_xtc_new_i8
                                        # -- End function
	.globl	_xtc_new_u16                    # -- Begin function _xtc_new_u16
	.p2align	4, 0x90
	.type	_xtc_new_u16,@function
_xtc_new_u16:                           # @_xtc_new_u16
# %bb.0:
	movabs	rax, 9223372036854251519
	lea	rcx, [rax + 491521]
	test	rdi, rcx
	je	.LBB40_1
# %bb.7:
	mov	esi, 2
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
	lea	rax, [rdi + rdi]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB40_4
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
.LBB40_4:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end40:
	.size	_xtc_new_u16, .Lfunc_end40-_xtc_new_u16
                                        # -- End function
	.globl	_xtc_new_i16                    # -- Begin function _xtc_new_i16
	.p2align	4, 0x90
	.type	_xtc_new_i16,@function
_xtc_new_i16:                           # @_xtc_new_i16
# %bb.0:
	movabs	rax, 9223372036854251519
	lea	rcx, [rax + 491521]
	test	rdi, rcx
	je	.LBB41_1
# %bb.7:
	mov	esi, 2
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
	lea	rax, [rdi + rdi]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB41_4
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
.LBB41_4:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end41:
	.size	_xtc_new_i16, .Lfunc_end41-_xtc_new_i16
                                        # -- End function
	.globl	_xtc_new_u32                    # -- Begin function _xtc_new_u32
	.p2align	4, 0x90
	.type	_xtc_new_u32,@function
_xtc_new_u32:                           # @_xtc_new_u32
# %bb.0:
	movabs	rax, 4611686018427125759
	lea	rcx, [rax + 245761]
	test	rdi, rcx
	je	.LBB42_1
# %bb.7:
	mov	esi, 4
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.LBB42_1:
	push	rbx
	cmp	rdi, rax
	jbe	.LBB42_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	rbx, rdi
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
	mov	rdi, rbx
.LBB42_3:
	mov	rbx, rdi
	lea	rax, [4*rdi]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB42_4
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
.LBB42_4:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end42:
	.size	_xtc_new_u32, .Lfunc_end42-_xtc_new_u32
                                        # -- End function
	.globl	_xtc_new_i32                    # -- Begin function _xtc_new_i32
	.p2align	4, 0x90
	.type	_xtc_new_i32,@function
_xtc_new_i32:                           # @_xtc_new_i32
# %bb.0:
	movabs	rax, 4611686018427125759
	lea	rcx, [rax + 245761]
	test	rdi, rcx
	je	.LBB43_1
# %bb.7:
	mov	esi, 4
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
	lea	rax, [4*rdi]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB43_4
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
.LBB43_4:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end43:
	.size	_xtc_new_i32, .Lfunc_end43-_xtc_new_i32
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
	jb	.LBB44_2
# %bb.1:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB44_2:
	lea	rax, [8*rbx]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB44_3
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
.LBB44_3:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end44:
	.size	_xtc_new_pointer, .Lfunc_end44-_xtc_new_pointer
                                        # -- End function
	.globl	_xtc_new_u64                    # -- Begin function _xtc_new_u64
	.p2align	4, 0x90
	.type	_xtc_new_u64,@function
_xtc_new_u64:                           # @_xtc_new_u64
# %bb.0:
	movabs	rax, 2305843009213562879
	lea	rcx, [rax + 122881]
	test	rdi, rcx
	je	.LBB45_1
# %bb.7:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.LBB45_1:
	push	rbx
	cmp	rdi, rax
	jbe	.LBB45_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	rbx, rdi
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
	mov	rdi, rbx
.LBB45_3:
	mov	rbx, rdi
	lea	rax, [8*rdi]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB45_4
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
.LBB45_4:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end45:
	.size	_xtc_new_u64, .Lfunc_end45-_xtc_new_u64
                                        # -- End function
	.globl	_xtc_new_i64                    # -- Begin function _xtc_new_i64
	.p2align	4, 0x90
	.type	_xtc_new_i64,@function
_xtc_new_i64:                           # @_xtc_new_i64
# %bb.0:
	movabs	rax, 2305843009213562879
	lea	rcx, [rax + 122881]
	test	rdi, rcx
	je	.LBB46_1
# %bb.7:
	mov	esi, 8
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
	lea	rax, [8*rdi]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB46_4
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
.LBB46_4:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end46:
	.size	_xtc_new_i64, .Lfunc_end46-_xtc_new_i64
                                        # -- End function
	.globl	_xtc_new_bool                   # -- Begin function _xtc_new_bool
	.p2align	4, 0x90
	.type	_xtc_new_bool,@function
_xtc_new_bool:                          # @_xtc_new_bool
# %bb.0:
	cmp	rdi, 65536
	jb	.LBB47_1
# %bb.5:
	mov	esi, 1
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.LBB47_1:
	push	rbx
	cmp	rdi, 17
	mov	eax, 16
	mov	rbx, rdi
	cmovae	rax, rdi
	add	rax, 40
	mov	rdi, rax
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB47_2
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
.LBB47_2:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end47:
	.size	_xtc_new_bool, .Lfunc_end47-_xtc_new_bool
                                        # -- End function
	.globl	_xtc_new_float                  # -- Begin function _xtc_new_float
	.p2align	4, 0x90
	.type	_xtc_new_float,@function
_xtc_new_float:                         # @_xtc_new_float
# %bb.0:
	movabs	rax, 4611686018427125759
	lea	rcx, [rax + 245761]
	test	rdi, rcx
	je	.LBB48_1
# %bb.7:
	mov	esi, 4
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.LBB48_1:
	push	rbx
	cmp	rdi, rax
	jbe	.LBB48_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	rbx, rdi
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
	mov	rdi, rbx
.LBB48_3:
	mov	rbx, rdi
	lea	rax, [4*rdi]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB48_4
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
.LBB48_4:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end48:
	.size	_xtc_new_float, .Lfunc_end48-_xtc_new_float
                                        # -- End function
	.globl	_xtc_new_double                 # -- Begin function _xtc_new_double
	.p2align	4, 0x90
	.type	_xtc_new_double,@function
_xtc_new_double:                        # @_xtc_new_double
# %bb.0:
	movabs	rax, 2305843009213562879
	lea	rcx, [rax + 122881]
	test	rdi, rcx
	je	.LBB49_1
# %bb.7:
	mov	esi, 8
	xor	edx, edx
	jmp	_xtc_alloc_aligned@PLT          # TAILCALL
.LBB49_1:
	push	rbx
	cmp	rdi, rax
	jbe	.LBB49_3
# %bb.2:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	rbx, rdi
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
	mov	rdi, rbx
.LBB49_3:
	mov	rbx, rdi
	lea	rax, [8*rdi]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB49_4
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
.LBB49_4:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end49:
	.size	_xtc_new_double, .Lfunc_end49-_xtc_new_double
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
	jb	.LBB50_2
# %bb.1:
	lea	rsi, [rip + xt_size_check.msg]
	mov	edx, 38
	mov	edi, 2
	call	write@PLT
	mov	edi, 134
	call	_xt_exit@PLT
.LBB50_2:
	lea	rax, [8*rbx]
	cmp	rax, 17
	mov	edi, 16
	cmovae	rdi, rax
	add	rdi, 40
	call	_xt_calloc@PLT
	test	rax, rax
	je	.LBB50_3
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
.LBB50_3:
	xor	eax, eax
	pop	rbx
	ret
.Lfunc_end50:
	.size	_xtc_new_string, .Lfunc_end50-_xtc_new_string
                                        # -- End function
	.globl	_xtc_count                      # -- Begin function _xtc_count
	.p2align	4, 0x90
	.type	_xtc_count,@function
_xtc_count:                             # @_xtc_count
# %bb.0:
	mov	eax, dword ptr [rdi - 28]
	ret
.Lfunc_end51:
	.size	_xtc_count, .Lfunc_end51-_xtc_count
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
	je	.LBB52_9
# %bb.1:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB52_4
	.p2align	4, 0x90
.LBB52_2:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB52_3 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_rt_spin], ecx
	test	ecx, ecx
	je	.LBB52_4
.LBB52_3:                               #   Parent Loop BB52_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_rt_spin]
	test	ecx, ecx
	jne	.LBB52_3
	jmp	.LBB52_2
.LBB52_4:
	mov	rcx, qword ptr [rbx - 12]
	test	rcx, rcx
	je	.LBB52_7
# %bb.5:
	xorps	xmm0, xmm0
	.p2align	4, 0x90
.LBB52_6:                               # =>This Inner Loop Header: Depth=1
	mov	rdx, qword ptr [rcx - 8]
	movups	xmmword ptr [rcx - 16], xmm0
	mov	qword ptr [rcx], 0
	mov	rcx, rdx
	test	rdx, rdx
	jne	.LBB52_6
.LBB52_7:
	mov	qword ptr [rbx - 12], 0
	cmp	dword ptr [rax], 0
	je	.LBB52_9
# %bb.8:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB52_9:
	mov	r15, qword ptr [rbx - 20]
	cmp	dword ptr [rbx - 40], 1481920323
	jne	.LBB52_36
# %bb.10:
	test	r15, r15
	je	.LBB52_12
# %bb.11:
	mov	rdi, rbx
	call	r15
.LBB52_12:
	mov	rdi, rbx
	call	_xtc_simd_unwatch@PLT
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB52_15
	.p2align	4, 0x90
.LBB52_13:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB52_14 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_rt_spin], ecx
	test	ecx, ecx
	je	.LBB52_15
.LBB52_14:                              #   Parent Loop BB52_13 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_rt_spin]
	test	ecx, ecx
	jne	.LBB52_14
	jmp	.LBB52_13
.LBB52_36:
	test	r15, r15
	je	.LBB52_40
# %bb.37:
	mov	r12, qword ptr [rbx - 36]
	mov	r13, qword ptr [rbx - 28]
	mov	dword ptr [rbx - 4], -2147483648
	test	r13, r13
	je	.LBB52_40
# %bb.38:
	mov	r14, rbx
	.p2align	4, 0x90
.LBB52_39:                              # =>This Inner Loop Header: Depth=1
	mov	rdi, r14
	call	r15
	add	r14, r12
	dec	r13
	jne	.LBB52_39
.LBB52_40:
	mov	rax, qword ptr [rbx - 48]
	add	rbx, -48
	cmp	rax, 64
	jae	.LBB52_41
# %bb.43:
	mov	rcx, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rcx], 0
	jne	.LBB52_44
	jmp	.LBB52_46
	.p2align	4, 0x90
.LBB52_45:                              #   Parent Loop BB52_44 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	edx, dword ptr [rip + xt_alloc_spin]
	test	edx, edx
	jne	.LBB52_45
.LBB52_44:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB52_45 Depth 2
	mov	edx, 1
	xchg	dword ptr [rip + xt_alloc_spin], edx
	test	edx, edx
	jne	.LBB52_45
.LBB52_46:
	lea	rdx, [rip + xt_cache_n]
	mov	esi, dword ptr [rdx + 4*rax]
	cmp	esi, 64
	jb	.LBB52_49
# %bb.47:
	cmp	dword ptr [rcx], 0
	je	.LBB52_41
# %bb.48:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB52_41:
	mov	rdi, rbx
	jmp	.LBB52_42
.LBB52_15:
	mov	rcx, qword ptr [rip + xt_simd_n]
	test	rcx, rcx
	je	.LBB52_16
# %bb.17:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	xor	edx, edx
	movabs	rdi, 2305843009213693950
	mov	r8, rcx
	.p2align	4, 0x90
.LBB52_18:                              # =>This Inner Loop Header: Depth=1
	lea	r9, [r8 + rdx]
	mov	r10, r9
	shr	r10
	and	r9, rdi
	cmp	qword ptr [rsi + 8*r9], rbx
	lea	r9, [r10 + 1]
	cmova	r8, r10
	cmovbe	rdx, r9
	cmp	rdx, r8
	jb	.LBB52_18
# %bb.19:
	test	rdx, rdx
	jne	.LBB52_20
	jmp	.LBB52_25
.LBB52_16:
	xor	edx, edx
	test	rdx, rdx
	je	.LBB52_25
.LBB52_20:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	mov	r8, rdx
	shl	r8, 4
	cmp	qword ptr [rsi + r8 - 16], rbx
	jne	.LBB52_25
# %bb.21:
	cmp	rdx, rcx
	jae	.LBB52_24
# %bb.22:
	mov	rdi, qword ptr [rip + xt_simd_flag]
	add	rsi, r8
	.p2align	4, 0x90
.LBB52_23:                              # =>This Inner Loop Header: Depth=1
	movups	xmm0, xmmword ptr [rsi]
	movups	xmmword ptr [rsi - 16], xmm0
	movzx	r8d, byte ptr [rdi + rdx]
	mov	byte ptr [rdi + rdx - 1], r8b
	inc	rdx
	add	rsi, 16
	cmp	rcx, rdx
	jne	.LBB52_23
.LBB52_24:
	dec	rcx
	mov	qword ptr [rip + xt_simd_n], rcx
.LBB52_25:
	cmp	dword ptr [rax], 0
	je	.LBB52_27
# %bb.26:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB52_27:
	mov	rdi, qword ptr [rbx - 48]
	test	rdi, rdi
	je	.LBB52_51
# %bb.28:
	mov	rcx, qword ptr [rdi - 8]
	add	rdi, -8
	cmp	rcx, 64
	jae	.LBB52_42
# %bb.29:
	cmp	dword ptr [rax], 0
	je	.LBB52_32
	.p2align	4, 0x90
.LBB52_30:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB52_31 Depth 2
	mov	edx, 1
	xchg	dword ptr [rip + xt_alloc_spin], edx
	test	edx, edx
	je	.LBB52_32
.LBB52_31:                              #   Parent Loop BB52_30 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	edx, dword ptr [rip + xt_alloc_spin]
	test	edx, edx
	jne	.LBB52_31
	jmp	.LBB52_30
.LBB52_32:
	lea	rdx, [rip + xt_cache_n]
	mov	esi, dword ptr [rdx + 4*rcx]
	cmp	esi, 64
	jb	.LBB52_35
# %bb.33:
	cmp	dword ptr [rax], 0
	je	.LBB52_42
# %bb.34:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB52_42:
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	jmp	free@PLT                        # TAILCALL
.LBB52_49:
	lea	rdi, [rip + xt_cache]
	mov	r8, qword ptr [rdi + 8*rax]
	mov	qword ptr [rbx], r8
	mov	qword ptr [rdi + 8*rax], rbx
	inc	esi
	mov	dword ptr [rdx + 4*rax], esi
	cmp	dword ptr [rcx], 0
	je	.LBB52_51
.LBB52_50:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB52_51:
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	ret
.LBB52_35:
	lea	r8, [rip + xt_cache]
	mov	r9, qword ptr [r8 + 8*rcx]
	mov	qword ptr [rdi], r9
	mov	qword ptr [r8 + 8*rcx], rdi
	inc	esi
	mov	dword ptr [rdx + 4*rcx], esi
	cmp	dword ptr [rax], 0
	jne	.LBB52_50
	jmp	.LBB52_51
.Lfunc_end52:
	.size	_xtc_dealloc, .Lfunc_end52-_xtc_dealloc
                                        # -- End function
	.globl	_xtc_weak_zero_for              # -- Begin function _xtc_weak_zero_for
	.p2align	4, 0x90
	.type	_xtc_weak_zero_for,@function
_xtc_weak_zero_for:                     # @_xtc_weak_zero_for
# %bb.0:
	test	rdi, rdi
	je	.LBB53_9
# %bb.1:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB53_4
	.p2align	4, 0x90
.LBB53_2:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB53_3 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_rt_spin], ecx
	test	ecx, ecx
	je	.LBB53_4
.LBB53_3:                               #   Parent Loop BB53_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_rt_spin]
	test	ecx, ecx
	jne	.LBB53_3
	jmp	.LBB53_2
.LBB53_4:
	mov	rcx, qword ptr [rdi - 12]
	test	rcx, rcx
	je	.LBB53_7
# %bb.5:
	xorps	xmm0, xmm0
	.p2align	4, 0x90
.LBB53_6:                               # =>This Inner Loop Header: Depth=1
	mov	rdx, qword ptr [rcx - 8]
	movups	xmmword ptr [rcx - 16], xmm0
	mov	qword ptr [rcx], 0
	mov	rcx, rdx
	test	rdx, rdx
	jne	.LBB53_6
.LBB53_7:
	mov	qword ptr [rdi - 12], 0
	cmp	dword ptr [rax], 0
	je	.LBB53_9
# %bb.8:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB53_9:
	ret
.Lfunc_end53:
	.size	_xtc_weak_zero_for, .Lfunc_end53-_xtc_weak_zero_for
                                        # -- End function
	.globl	_xtc_weak_unregister            # -- Begin function _xtc_weak_unregister
	.p2align	4, 0x90
	.type	_xtc_weak_unregister,@function
_xtc_weak_unregister:                   # @_xtc_weak_unregister
# %bb.0:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB54_3
	.p2align	4, 0x90
.LBB54_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB54_2 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_rt_spin], ecx
	test	ecx, ecx
	je	.LBB54_3
.LBB54_2:                               #   Parent Loop BB54_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_rt_spin]
	test	ecx, ecx
	jne	.LBB54_2
	jmp	.LBB54_1
.LBB54_3:
	mov	rcx, qword ptr [rdi - 16]
	test	rcx, rcx
	je	.LBB54_8
# %bb.4:
	lea	rdx, [rdi - 16]
	cmp	qword ptr [rcx], rdi
	jne	.LBB54_7
# %bb.5:
	mov	rsi, qword ptr [rdi - 8]
	mov	qword ptr [rcx], rsi
	test	rsi, rsi
	je	.LBB54_7
# %bb.6:
	mov	qword ptr [rsi - 16], rcx
.LBB54_7:
	xorps	xmm0, xmm0
	movups	xmmword ptr [rdx], xmm0
.LBB54_8:
	cmp	dword ptr [rax], 0
	je	.LBB54_10
# %bb.9:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB54_10:
	ret
.Lfunc_end54:
	.size	_xtc_weak_unregister, .Lfunc_end54-_xtc_weak_unregister
                                        # -- End function
	.globl	_xtc_weak_register              # -- Begin function _xtc_weak_register
	.p2align	4, 0x90
	.type	_xtc_weak_register,@function
_xtc_weak_register:                     # @_xtc_weak_register
# %bb.0:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	cmp	dword ptr [rax], 0
	je	.LBB55_3
	.p2align	4, 0x90
.LBB55_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB55_2 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_rt_spin], ecx
	test	ecx, ecx
	je	.LBB55_3
.LBB55_2:                               #   Parent Loop BB55_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_rt_spin]
	test	ecx, ecx
	jne	.LBB55_2
	jmp	.LBB55_1
.LBB55_3:
	mov	rcx, qword ptr [rdi - 16]
	test	rcx, rcx
	je	.LBB55_8
# %bb.4:
	lea	rdx, [rdi - 16]
	cmp	qword ptr [rcx], rdi
	jne	.LBB55_7
# %bb.5:
	mov	r8, qword ptr [rdi - 8]
	mov	qword ptr [rcx], r8
	test	r8, r8
	je	.LBB55_7
# %bb.6:
	mov	qword ptr [r8 - 16], rcx
.LBB55_7:
	xorps	xmm0, xmm0
	movups	xmmword ptr [rdx], xmm0
.LBB55_8:
	test	rsi, rsi
	je	.LBB55_13
# %bb.9:
	cmp	dword ptr [rsi - 40], 1481920322
	jne	.LBB55_13
# %bb.10:
	mov	rcx, qword ptr [rsi - 12]
	add	rsi, -12
	mov	qword ptr [rdi - 16], rsi
	mov	qword ptr [rdi - 8], rcx
	test	rcx, rcx
	je	.LBB55_12
# %bb.11:
	lea	rdx, [rdi - 8]
	mov	qword ptr [rcx - 16], rdx
.LBB55_12:
	mov	qword ptr [rsi], rdi
.LBB55_13:
	cmp	dword ptr [rax], 0
	je	.LBB55_15
# %bb.14:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB55_15:
	ret
.Lfunc_end55:
	.size	_xtc_weak_register, .Lfunc_end55-_xtc_weak_register
                                        # -- End function
	.globl	_xtc_weak_load                  # -- Begin function _xtc_weak_load
	.p2align	4, 0x90
	.type	_xtc_weak_load,@function
_xtc_weak_load:                         # @_xtc_weak_load
# %bb.0:
	mov	rax, qword ptr [rdi]
	ret
.Lfunc_end56:
	.size	_xtc_weak_load, .Lfunc_end56-_xtc_weak_load
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
.Lfunc_end57:
	.size	srandom, .Lfunc_end57-srandom
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
.Lfunc_end58:
	.size	random, .Lfunc_end58-random
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
.Lfunc_end59:
	.size	_xt_srand, .Lfunc_end59-_xt_srand
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
.Lfunc_end60:
	.size	_xt_rand_u32, .Lfunc_end60-_xt_rand_u32
                                        # -- End function
	.section	.rodata.cst4,"aM",@progbits,4
	.p2align	2, 0x0                          # -- Begin function _xt_rand_f
.LCPI61_0:
	.long	0x30000000                      # float 4.65661287E-10
.LCPI61_1:
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
	mulss	xmm0, dword ptr [rip + .LCPI61_0]
	movss	xmm1, dword ptr [rip + .LCPI61_1] # xmm1 = [5.0E-1,0.0E+0,0.0E+0,0.0E+0]
	mulss	xmm0, xmm1
	addss	xmm0, xmm1
	ret
.Lfunc_end61:
	.size	_xt_rand_f, .Lfunc_end61-_xt_rand_f
                                        # -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          # -- Begin function _xt_rand_d
.LCPI62_0:
	.quad	0x3e00000000000000              # double 4.6566128730773926E-10
.LCPI62_1:
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
	mulsd	xmm0, qword ptr [rip + .LCPI62_0]
	movsd	xmm1, qword ptr [rip + .LCPI62_1] # xmm1 = [5.0E-1,0.0E+0]
	mulsd	xmm0, xmm1
	addsd	xmm0, xmm1
	ret
.Lfunc_end62:
	.size	_xt_rand_d, .Lfunc_end62-_xt_rand_d
                                        # -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          # -- Begin function _xt_clk_reset
.LCPI63_0:
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
	mulsd	xmm1, qword ptr [rip + .LCPI63_0]
	addsd	xmm1, xmm0
	movsd	qword ptr [rip + xt_clk_origin], xmm1
	add	rsp, 24
	ret
.Lfunc_end63:
	.size	_xt_clk_reset, .Lfunc_end63-_xt_clk_reset
                                        # -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          # -- Begin function _xt_clk_ticks
.LCPI64_0:
	.quad	0x3e112e0be826d695              # double 1.0000000000000001E-9
.LCPI64_1:
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
	mulsd	xmm1, qword ptr [rip + .LCPI64_0]
	addsd	xmm1, xmm0
	subsd	xmm1, qword ptr [rip + xt_clk_origin]
	mulsd	xmm1, qword ptr [rip + .LCPI64_1]
	cvttsd2si	rax, xmm1
                                        # kill: def $eax killed $eax killed $rax
	add	rsp, 24
	ret
.Lfunc_end64:
	.size	_xt_clk_ticks, .Lfunc_end64-_xt_clk_ticks
                                        # -- End function
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0                          # -- Begin function _xt_clk_delay
.LCPI65_0:
	.quad	0x404e000000000000              # double 60
.LCPI65_1:
	.quad	0x41cdcd6500000000              # double 1.0E+9
.LCPI65_2:
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
	divsd	xmm0, qword ptr [rip + .LCPI65_0]
	mulsd	xmm0, qword ptr [rip + .LCPI65_1]
	cvttsd2si	rax, xmm0
	mov	rcx, rax
	sar	rcx, 63
	subsd	xmm0, qword ptr [rip + .LCPI65_2]
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
.Lfunc_end65:
	.size	_xt_clk_delay, .Lfunc_end65-_xt_clk_delay
                                        # -- End function
	.globl	_xtc_bank                       # -- Begin function _xtc_bank
	.p2align	4, 0x90
	.type	_xtc_bank,@function
_xtc_bank:                              # @_xtc_bank
# %bb.0:
	cmp	dil, 1
	jbe	.LBB66_2
# %bb.1:
	xor	eax, eax
	ret
.LBB66_2:
	push	rbx
	movzx	eax, dil
	shl	eax, 11
	lea	rcx, [rip + xt_bank_regions]
	add	rcx, rax
	movzx	eax, sil
	lea	rbx, [rcx + 8*rax]
	cmp	qword ptr [rcx + 8*rax], 0
	jne	.LBB66_7
# %bb.3:
	mov	edi, 1
	mov	esi, 12296
	call	calloc@PLT
	test	rax, rax
	je	.LBB66_4
# %bb.5:
	mov	qword ptr [rax], 64
	add	rax, 8
	jmp	.LBB66_6
.LBB66_4:
	xor	eax, eax
.LBB66_6:
	mov	qword ptr [rbx], rax
.LBB66_7:
	mov	rax, qword ptr [rbx]
	pop	rbx
	ret
.Lfunc_end66:
	.size	_xtc_bank, .Lfunc_end66-_xtc_bank
                                        # -- End function
	.globl	_xt_threads_multi               # -- Begin function _xt_threads_multi
	.p2align	4, 0x90
	.type	_xt_threads_multi,@function
_xt_threads_multi:                      # @_xt_threads_multi
# %bb.0:
	mov	rax, qword ptr [rip + _xt_threads_active@GOTPCREL]
	mov	eax, dword ptr [rax]
	ret
.Lfunc_end67:
	.size	_xt_threads_multi, .Lfunc_end67-_xt_threads_multi
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
	je	.LBB68_4
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
	jne	.LBB68_3
# %bb.2:
	mov	qword ptr [r14], r12
	mov	qword ptr [r14 + 8], r15
	lea	rdx, [rip + xt_gthread_entry]
	mov	rdi, rbx
	xor	esi, esi
	mov	rcx, r14
	call	pthread_create@PLT
	test	eax, eax
	je	.LBB68_5
.LBB68_3:
	mov	rdi, r14
	call	free@PLT
	mov	rdi, rbx
	call	free@PLT
.LBB68_4:
	xor	ebx, ebx
.LBB68_5:
	mov	rax, rbx
	add	rsp, 8
	pop	rbx
	pop	r12
	pop	r14
	pop	r15
	ret
.Lfunc_end68:
	.size	_xt_thread_create, .Lfunc_end68-_xt_thread_create
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
	je	.LBB69_2
# %bb.1:
	mov	rdi, rbx
	call	r14
.LBB69_2:
	xor	eax, eax
	add	rsp, 8
	pop	rbx
	pop	r14
	ret
.Lfunc_end69:
	.size	xt_gthread_entry, .Lfunc_end69-xt_gthread_entry
                                        # -- End function
	.globl	_xt_thread_join                 # -- Begin function _xt_thread_join
	.p2align	4, 0x90
	.type	_xt_thread_join,@function
_xt_thread_join:                        # @_xt_thread_join
# %bb.0:
	test	rdi, rdi
	je	.LBB70_1
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
.LBB70_1:
	mov	eax, -1
	ret
.Lfunc_end70:
	.size	_xt_thread_join, .Lfunc_end70-_xt_thread_join
                                        # -- End function
	.globl	_xt_thread_detach               # -- Begin function _xt_thread_detach
	.p2align	4, 0x90
	.type	_xt_thread_detach,@function
_xt_thread_detach:                      # @_xt_thread_detach
# %bb.0:
	test	rdi, rdi
	je	.LBB71_1
# %bb.2:
	push	rbx
	mov	rax, qword ptr [rdi]
	mov	rbx, rdi
	mov	rdi, rax
	call	pthread_detach@PLT
	mov	rdi, rbx
	pop	rbx
	jmp	free@PLT                        # TAILCALL
.LBB71_1:
	ret
.Lfunc_end71:
	.size	_xt_thread_detach, .Lfunc_end71-_xt_thread_detach
                                        # -- End function
	.globl	_xt_thread_yield                # -- Begin function _xt_thread_yield
	.p2align	4, 0x90
	.type	_xt_thread_yield,@function
_xt_thread_yield:                       # @_xt_thread_yield
# %bb.0:
	jmp	sched_yield@PLT                 # TAILCALL
.Lfunc_end72:
	.size	_xt_thread_yield, .Lfunc_end72-_xt_thread_yield
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
.Lfunc_end73:
	.size	_xt_thread_sleep_ms, .Lfunc_end73-_xt_thread_sleep_ms
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
.Lfunc_end74:
	.size	_xt_thread_self_id, .Lfunc_end74-_xt_thread_self_id
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
.Lfunc_end75:
	.size	_xt_thread_cpu_count, .Lfunc_end75-_xt_thread_cpu_count
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
	je	.LBB76_4
# %bb.1:
	mov	rbx, rax
	mov	rdi, rax
	xor	esi, esi
	call	pthread_mutex_init@PLT
	test	eax, eax
	je	.LBB76_2
# %bb.3:
	mov	rdi, rbx
	call	free@PLT
	xor	eax, eax
.LBB76_4:
	pop	rbx
	ret
.LBB76_2:
	mov	rax, rbx
	pop	rbx
	ret
.Lfunc_end76:
	.size	_xt_mutex_new, .Lfunc_end76-_xt_mutex_new
                                        # -- End function
	.globl	_xt_mutex_free                  # -- Begin function _xt_mutex_free
	.p2align	4, 0x90
	.type	_xt_mutex_free,@function
_xt_mutex_free:                         # @_xt_mutex_free
# %bb.0:
	test	rdi, rdi
	je	.LBB77_1
# %bb.2:
	push	rbx
	mov	rbx, rdi
	call	pthread_mutex_destroy@PLT
	mov	rdi, rbx
	pop	rbx
	jmp	free@PLT                        # TAILCALL
.LBB77_1:
	ret
.Lfunc_end77:
	.size	_xt_mutex_free, .Lfunc_end77-_xt_mutex_free
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
.Lfunc_end78:
	.size	_xt_mutex_lock, .Lfunc_end78-_xt_mutex_lock
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
.Lfunc_end79:
	.size	_xt_mutex_unlock, .Lfunc_end79-_xt_mutex_unlock
                                        # -- End function
	.globl	_xt_mutex_trylock               # -- Begin function _xt_mutex_trylock
	.p2align	4, 0x90
	.type	_xt_mutex_trylock,@function
_xt_mutex_trylock:                      # @_xt_mutex_trylock
# %bb.0:
	test	rdi, rdi
	je	.LBB80_1
# %bb.2:
	push	rax
	call	pthread_mutex_trylock@PLT
	mov	ecx, eax
	xor	eax, eax
	test	ecx, ecx
	sete	al
	add	rsp, 8
	ret
.LBB80_1:
	xor	eax, eax
	ret
.Lfunc_end80:
	.size	_xt_mutex_trylock, .Lfunc_end80-_xt_mutex_trylock
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
	je	.LBB81_4
# %bb.1:
	mov	rbx, rax
	mov	rdi, rax
	xor	esi, esi
	call	pthread_cond_init@PLT
	test	eax, eax
	je	.LBB81_2
# %bb.3:
	mov	rdi, rbx
	call	free@PLT
	xor	eax, eax
.LBB81_4:
	pop	rbx
	ret
.LBB81_2:
	mov	rax, rbx
	pop	rbx
	ret
.Lfunc_end81:
	.size	_xt_cond_new, .Lfunc_end81-_xt_cond_new
                                        # -- End function
	.globl	_xt_cond_free                   # -- Begin function _xt_cond_free
	.p2align	4, 0x90
	.type	_xt_cond_free,@function
_xt_cond_free:                          # @_xt_cond_free
# %bb.0:
	test	rdi, rdi
	je	.LBB82_1
# %bb.2:
	push	rbx
	mov	rbx, rdi
	call	pthread_cond_destroy@PLT
	mov	rdi, rbx
	pop	rbx
	jmp	free@PLT                        # TAILCALL
.LBB82_1:
	ret
.Lfunc_end82:
	.size	_xt_cond_free, .Lfunc_end82-_xt_cond_free
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
.Lfunc_end83:
	.size	_xt_cond_wait, .Lfunc_end83-_xt_cond_wait
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
.Lfunc_end84:
	.size	_xt_cond_signal, .Lfunc_end84-_xt_cond_signal
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
.Lfunc_end85:
	.size	_xt_cond_broadcast, .Lfunc_end85-_xt_cond_broadcast
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
	je	.LBB86_2
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
.LBB86_2:
	mov	rax, rbx
	pop	rbx
	pop	r14
	pop	rbp
	ret
.Lfunc_end86:
	.size	_xt_sem_new, .Lfunc_end86-_xt_sem_new
                                        # -- End function
	.globl	_xt_sem_free                    # -- Begin function _xt_sem_free
	.p2align	4, 0x90
	.type	_xt_sem_free,@function
_xt_sem_free:                           # @_xt_sem_free
# %bb.0:
	test	rdi, rdi
	je	.LBB87_1
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
.LBB87_1:
	ret
.Lfunc_end87:
	.size	_xt_sem_free, .Lfunc_end87-_xt_sem_free
                                        # -- End function
	.globl	_xt_sem_wait                    # -- Begin function _xt_sem_wait
	.p2align	4, 0x90
	.type	_xt_sem_wait,@function
_xt_sem_wait:                           # @_xt_sem_wait
# %bb.0:
	test	rdi, rdi
	je	.LBB88_5
# %bb.1:
	push	r14
	push	rbx
	push	rax
	mov	rbx, rdi
	call	pthread_mutex_lock@PLT
	mov	eax, dword ptr [rbx + 88]
	test	eax, eax
	jg	.LBB88_4
# %bb.2:
	lea	r14, [rbx + 40]
	.p2align	4, 0x90
.LBB88_3:                               # =>This Inner Loop Header: Depth=1
	mov	rdi, r14
	mov	rsi, rbx
	call	pthread_cond_wait@PLT
	mov	eax, dword ptr [rbx + 88]
	test	eax, eax
	jle	.LBB88_3
.LBB88_4:
	dec	eax
	mov	dword ptr [rbx + 88], eax
	mov	rdi, rbx
	add	rsp, 8
	pop	rbx
	pop	r14
	jmp	pthread_mutex_unlock@PLT        # TAILCALL
.LBB88_5:
	ret
.Lfunc_end88:
	.size	_xt_sem_wait, .Lfunc_end88-_xt_sem_wait
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
	je	.LBB89_1
# %bb.2:
	mov	rbx, rdi
	call	pthread_mutex_lock@PLT
	mov	eax, dword ptr [rbx + 88]
	test	eax, eax
	jle	.LBB89_3
# %bb.4:
	dec	eax
	mov	dword ptr [rbx + 88], eax
	mov	ebp, 1
	jmp	.LBB89_5
.LBB89_1:
	xor	ebp, ebp
	jmp	.LBB89_6
.LBB89_3:
	xor	ebp, ebp
.LBB89_5:
	mov	rdi, rbx
	call	pthread_mutex_unlock@PLT
.LBB89_6:
	mov	eax, ebp
	add	rsp, 8
	pop	rbx
	pop	rbp
	ret
.Lfunc_end89:
	.size	_xt_sem_trywait, .Lfunc_end89-_xt_sem_trywait
                                        # -- End function
	.globl	_xt_sem_post                    # -- Begin function _xt_sem_post
	.p2align	4, 0x90
	.type	_xt_sem_post,@function
_xt_sem_post:                           # @_xt_sem_post
# %bb.0:
	test	rdi, rdi
	je	.LBB90_1
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
.LBB90_1:
	ret
.Lfunc_end90:
	.size	_xt_sem_post, .Lfunc_end90-_xt_sem_post
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
.Lfunc_end91:
	.size	_xt_tls_new, .Lfunc_end91-_xt_tls_new
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
.Lfunc_end92:
	.size	_xt_tls_set, .Lfunc_end92-_xt_tls_set
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
.Lfunc_end93:
	.size	_xt_tls_get, .Lfunc_end93-_xt_tls_get
                                        # -- End function
	.globl	_xt_atomic_load_i32             # -- Begin function _xt_atomic_load_i32
	.p2align	4, 0x90
	.type	_xt_atomic_load_i32,@function
_xt_atomic_load_i32:                    # @_xt_atomic_load_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB94_1
# %bb.2:
	mov	eax, dword ptr [rdi]
	ret
.LBB94_1:
	xor	eax, eax
	ret
.Lfunc_end94:
	.size	_xt_atomic_load_i32, .Lfunc_end94-_xt_atomic_load_i32
                                        # -- End function
	.globl	_xt_atomic_store_i32            # -- Begin function _xt_atomic_store_i32
	.p2align	4, 0x90
	.type	_xt_atomic_store_i32,@function
_xt_atomic_store_i32:                   # @_xt_atomic_store_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB95_2
# %bb.1:
	xchg	dword ptr [rdi], esi
.LBB95_2:
	ret
.Lfunc_end95:
	.size	_xt_atomic_store_i32, .Lfunc_end95-_xt_atomic_store_i32
                                        # -- End function
	.globl	_xt_atomic_add_i32              # -- Begin function _xt_atomic_add_i32
	.p2align	4, 0x90
	.type	_xt_atomic_add_i32,@function
_xt_atomic_add_i32:                     # @_xt_atomic_add_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB96_1
# %bb.2:
	mov	eax, esi
	lock		xadd	dword ptr [rdi], eax
	add	eax, esi
	ret
.LBB96_1:
	xor	eax, eax
	ret
.Lfunc_end96:
	.size	_xt_atomic_add_i32, .Lfunc_end96-_xt_atomic_add_i32
                                        # -- End function
	.globl	_xt_atomic_xchg_i32             # -- Begin function _xt_atomic_xchg_i32
	.p2align	4, 0x90
	.type	_xt_atomic_xchg_i32,@function
_xt_atomic_xchg_i32:                    # @_xt_atomic_xchg_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB97_1
# %bb.2:
	mov	eax, esi
	xchg	dword ptr [rdi], eax
	ret
.LBB97_1:
	xor	eax, eax
	ret
.Lfunc_end97:
	.size	_xt_atomic_xchg_i32, .Lfunc_end97-_xt_atomic_xchg_i32
                                        # -- End function
	.globl	_xt_atomic_cas_i32              # -- Begin function _xt_atomic_cas_i32
	.p2align	4, 0x90
	.type	_xt_atomic_cas_i32,@function
_xt_atomic_cas_i32:                     # @_xt_atomic_cas_i32
# %bb.0:
	test	rdi, rdi
	je	.LBB98_1
# %bb.2:
	mov	eax, esi
	lock		cmpxchg	dword ptr [rdi], edx
	mov	eax, 0
	sete	al
	ret
.LBB98_1:
	xor	eax, eax
	ret
.Lfunc_end98:
	.size	_xt_atomic_cas_i32, .Lfunc_end98-_xt_atomic_cas_i32
                                        # -- End function
	.globl	_xt_atomic_load_ptr             # -- Begin function _xt_atomic_load_ptr
	.p2align	4, 0x90
	.type	_xt_atomic_load_ptr,@function
_xt_atomic_load_ptr:                    # @_xt_atomic_load_ptr
# %bb.0:
	test	rdi, rdi
	je	.LBB99_1
# %bb.2:
	mov	rax, qword ptr [rdi]
	ret
.LBB99_1:
	xor	eax, eax
	ret
.Lfunc_end99:
	.size	_xt_atomic_load_ptr, .Lfunc_end99-_xt_atomic_load_ptr
                                        # -- End function
	.globl	_xt_atomic_store_ptr            # -- Begin function _xt_atomic_store_ptr
	.p2align	4, 0x90
	.type	_xt_atomic_store_ptr,@function
_xt_atomic_store_ptr:                   # @_xt_atomic_store_ptr
# %bb.0:
	test	rdi, rdi
	je	.LBB100_2
# %bb.1:
	xchg	qword ptr [rdi], rsi
.LBB100_2:
	ret
.Lfunc_end100:
	.size	_xt_atomic_store_ptr, .Lfunc_end100-_xt_atomic_store_ptr
                                        # -- End function
	.globl	_xt_atomic_cas_ptr              # -- Begin function _xt_atomic_cas_ptr
	.p2align	4, 0x90
	.type	_xt_atomic_cas_ptr,@function
_xt_atomic_cas_ptr:                     # @_xt_atomic_cas_ptr
# %bb.0:
	test	rdi, rdi
	je	.LBB101_1
# %bb.2:
	mov	rax, rsi
	lock		cmpxchg	qword ptr [rdi], rdx
	mov	eax, 0
	sete	al
	ret
.LBB101_1:
	xor	eax, eax
	ret
.Lfunc_end101:
	.size	_xt_atomic_cas_ptr, .Lfunc_end101-_xt_atomic_cas_ptr
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
	jne	.LBB102_4
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
	jne	.LBB102_4
# %bb.2:
	xor	r15d, r15d
	mov	eax, 7
	xor	ecx, ecx
	#APP

	.byte	15
	.byte	162

	#NO_APP
	test	bl, 32
	je	.LBB102_4
# %bb.3:
	not	ebx
	and	ebx, -1073545216
	and	esi, 224
	xor	r15d, r15d
	or	esi, ebx
	sete	r15b
	inc	r15d
.LBB102_4:
	lea	rdi, [rip + .L.str]
	call	getenv@PLT
	test	rax, rax
	je	.LBB102_27
# %bb.5:
	movzx	ecx, byte ptr [rax]
	test	cl, cl
	je	.LBB102_6
# %bb.7:
	lea	rsi, [rax + 1]
	lea	rdx, [rip + .L.str.1]
	mov	edi, ecx
	.p2align	4, 0x90
.LBB102_8:                              # =>This Inner Loop Header: Depth=1
	cmp	dil, byte ptr [rdx]
	jne	.LBB102_10
# %bb.9:                                #   in Loop: Header=BB102_8 Depth=1
	inc	rdx
	movzx	edi, byte ptr [rsi]
	inc	rsi
	test	dil, dil
	jne	.LBB102_8
	jmp	.LBB102_10
.LBB102_6:
	lea	rdx, [rip + .L.str.1]
	mov	edi, ecx
.LBB102_10:
	xor	esi, esi
	cmp	dil, byte ptr [rdx]
	cmovne	esi, r15d
	je	.LBB102_28
# %bb.11:
	test	cl, cl
	je	.LBB102_12
# %bb.13:
	lea	rdi, [rax + 1]
	lea	rdx, [rip + .L.str.2]
	mov	esi, ecx
	.p2align	4, 0x90
.LBB102_14:                             # =>This Inner Loop Header: Depth=1
	cmp	sil, byte ptr [rdx]
	jne	.LBB102_16
# %bb.15:                               #   in Loop: Header=BB102_14 Depth=1
	inc	rdx
	movzx	esi, byte ptr [rdi]
	inc	rdi
	test	sil, sil
	jne	.LBB102_14
.LBB102_16:
	cmp	sil, byte ptr [rdx]
	jne	.LBB102_19
.LBB102_17:
	mov	esi, 1
	test	r15d, r15d
	jne	.LBB102_28
# %bb.18:
	lea	rsi, [rip + xt_simd_pick.msg]
	mov	edx, 66
	mov	edi, 2
	call	write@PLT
	xor	esi, esi
	jmp	.LBB102_28
.LBB102_12:
	lea	rdx, [rip + .L.str.2]
	mov	esi, ecx
	cmp	sil, byte ptr [rdx]
	je	.LBB102_17
.LBB102_19:
	test	cl, cl
	je	.LBB102_20
# %bb.21:
	inc	rax
	lea	rdx, [rip + .L.str.3]
	.p2align	4, 0x90
.LBB102_22:                             # =>This Inner Loop Header: Depth=1
	cmp	cl, byte ptr [rdx]
	jne	.LBB102_24
# %bb.23:                               #   in Loop: Header=BB102_22 Depth=1
	inc	rdx
	movzx	ecx, byte ptr [rax]
	inc	rax
	test	cl, cl
	jne	.LBB102_22
	jmp	.LBB102_24
.LBB102_20:
	lea	rdx, [rip + .L.str.3]
.LBB102_24:
	cmp	r15d, 1
	ja	.LBB102_27
# %bb.25:
	cmp	cl, byte ptr [rdx]
	jne	.LBB102_27
# %bb.26:
	lea	rsi, [rip + xt_simd_pick.msg.4]
	mov	edx, 82
	mov	edi, 2
	call	write@PLT
.LBB102_27:
	mov	esi, r15d
.LBB102_28:
	xor	eax, eax
	test	esi, esi
	setne	al
	mov	rcx, qword ptr [rip + _xt_simd_level@GOTPCREL]
	mov	dword ptr [rcx], eax
	test	ebp, ebp
	je	.LBB102_31
# %bb.29:
	cmp	esi, 1
	mov	eax, 1
	sbb	eax, -1
	mov	ecx, ebp
	lea	rcx, [rcx + 2*rcx]
	xor	edx, edx
	.p2align	4, 0x90
.LBB102_30:                             # =>This Inner Loop Header: Depth=1
	mov	esi, edx
	mov	rsi, qword ptr [r14 + 8*rsi]
	lea	edi, [rax + rdx]
	mov	rdi, qword ptr [r14 + 8*rdi]
	mov	qword ptr [rsi], rdi
	add	rdx, 3
	cmp	rcx, rdx
	jne	.LBB102_30
.LBB102_31:
	add	rsp, 8
	pop	rbx
	pop	r14
	pop	r15
	pop	rbp
	ret
.Lfunc_end102:
	.size	_xt_simd_select, .Lfunc_end102-_xt_simd_select
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
	jne	.LBB103_4
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
	jne	.LBB103_4
# %bb.2:
	xor	r15d, r15d
	mov	eax, 7
	xor	ecx, ecx
	#APP

	.byte	15
	.byte	162

	#NO_APP
	test	bl, 32
	je	.LBB103_4
# %bb.3:
	not	ebx
	and	ebx, -1073545216
	and	esi, 224
	xor	r15d, r15d
	or	esi, ebx
	sete	r15b
	inc	r15d
.LBB103_4:
	lea	rdi, [rip + .L.str]
	call	getenv@PLT
	test	rax, rax
	je	.LBB103_27
# %bb.5:
	movzx	ecx, byte ptr [rax]
	test	cl, cl
	je	.LBB103_6
# %bb.7:
	lea	rsi, [rax + 1]
	lea	rdx, [rip + .L.str.1]
	mov	edi, ecx
	.p2align	4, 0x90
.LBB103_8:                              # =>This Inner Loop Header: Depth=1
	cmp	dil, byte ptr [rdx]
	jne	.LBB103_10
# %bb.9:                                #   in Loop: Header=BB103_8 Depth=1
	inc	rdx
	movzx	edi, byte ptr [rsi]
	inc	rsi
	test	dil, dil
	jne	.LBB103_8
	jmp	.LBB103_10
.LBB103_6:
	lea	rdx, [rip + .L.str.1]
	mov	edi, ecx
.LBB103_10:
	xor	esi, esi
	cmp	dil, byte ptr [rdx]
	cmovne	esi, r15d
	je	.LBB103_28
# %bb.11:
	test	cl, cl
	je	.LBB103_12
# %bb.13:
	lea	rdi, [rax + 1]
	lea	rdx, [rip + .L.str.2]
	mov	esi, ecx
	.p2align	4, 0x90
.LBB103_14:                             # =>This Inner Loop Header: Depth=1
	cmp	sil, byte ptr [rdx]
	jne	.LBB103_16
# %bb.15:                               #   in Loop: Header=BB103_14 Depth=1
	inc	rdx
	movzx	esi, byte ptr [rdi]
	inc	rdi
	test	sil, sil
	jne	.LBB103_14
.LBB103_16:
	cmp	sil, byte ptr [rdx]
	jne	.LBB103_19
.LBB103_17:
	mov	esi, 1
	test	r15d, r15d
	jne	.LBB103_28
# %bb.18:
	lea	rsi, [rip + xt_simd_pick.msg]
	mov	edx, 66
	mov	edi, 2
	call	write@PLT
	xor	esi, esi
	jmp	.LBB103_28
.LBB103_12:
	lea	rdx, [rip + .L.str.2]
	mov	esi, ecx
	cmp	sil, byte ptr [rdx]
	je	.LBB103_17
.LBB103_19:
	test	cl, cl
	je	.LBB103_20
# %bb.21:
	inc	rax
	lea	rdx, [rip + .L.str.3]
	.p2align	4, 0x90
.LBB103_22:                             # =>This Inner Loop Header: Depth=1
	cmp	cl, byte ptr [rdx]
	jne	.LBB103_24
# %bb.23:                               #   in Loop: Header=BB103_22 Depth=1
	inc	rdx
	movzx	ecx, byte ptr [rax]
	inc	rax
	test	cl, cl
	jne	.LBB103_22
	jmp	.LBB103_24
.LBB103_20:
	lea	rdx, [rip + .L.str.3]
.LBB103_24:
	cmp	r15d, 1
	ja	.LBB103_27
# %bb.25:
	cmp	cl, byte ptr [rdx]
	jne	.LBB103_27
# %bb.26:
	lea	rsi, [rip + xt_simd_pick.msg.4]
	mov	edx, 82
	mov	edi, 2
	call	write@PLT
.LBB103_27:
	mov	esi, r15d
.LBB103_28:
	mov	rax, qword ptr [rip + _xt_simd_level@GOTPCREL]
	mov	dword ptr [rax], esi
	test	ebp, ebp
	je	.LBB103_31
# %bb.29:
	mov	eax, ebp
	mov	ecx, esi
	inc	rcx
	shl	rax, 2
	xor	edx, edx
	.p2align	4, 0x90
.LBB103_30:                             # =>This Inner Loop Header: Depth=1
	mov	esi, edx
	mov	rsi, qword ptr [r14 + 8*rsi]
	lea	edi, [rcx + rdx]
	mov	rdi, qword ptr [r14 + 8*rdi]
	mov	qword ptr [rsi], rdi
	add	rdx, 4
	cmp	rax, rdx
	jne	.LBB103_30
.LBB103_31:
	add	rsp, 8
	pop	rbx
	pop	r14
	pop	r15
	pop	rbp
	ret
.Lfunc_end103:
	.size	_xt_simd_select4, .Lfunc_end103-_xt_simd_select4
                                        # -- End function
	.globl	_xtc_sinit_run                  # -- Begin function _xtc_sinit_run
	.p2align	4, 0x90
	.type	_xtc_sinit_run,@function
_xtc_sinit_run:                         # @_xtc_sinit_run
# %bb.0:
	test	rdi, rdi
	je	.LBB104_36
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
	jmp	.LBB104_2
	.p2align	4, 0x90
.LBB104_14:                             #   in Loop: Header=BB104_2 Depth=1
	call	sched_yield@PLT
	xor	eax, eax
.LBB104_21:                             #   in Loop: Header=BB104_2 Depth=1
	test	eax, eax
	jne	.LBB104_22
.LBB104_2:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB104_3 Depth 2
                                        #       Child Loop BB104_4 Depth 3
                                        #     Child Loop BB104_9 Depth 2
	cmp	dword ptr [r12], 0
	je	.LBB104_5
	.p2align	4, 0x90
.LBB104_3:                              #   Parent Loop BB104_2 Depth=1
                                        # =>  This Loop Header: Depth=2
                                        #       Child Loop BB104_4 Depth 3
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB104_5
.LBB104_4:                              #   Parent Loop BB104_2 Depth=1
                                        #     Parent Loop BB104_3 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB104_4
	jmp	.LBB104_3
	.p2align	4, 0x90
.LBB104_5:                              #   in Loop: Header=BB104_2 Depth=1
	movzx	eax, byte ptr [rbx]
	test	eax, eax
	je	.LBB104_15
# %bb.6:                                #   in Loop: Header=BB104_2 Depth=1
	cmp	eax, 2
	jne	.LBB104_7
.LBB104_18:                             #   in Loop: Header=BB104_2 Depth=1
	mov	eax, 1
	cmp	dword ptr [r12], 0
	jne	.LBB104_20
	jmp	.LBB104_21
	.p2align	4, 0x90
.LBB104_15:                             #   in Loop: Header=BB104_2 Depth=1
	mov	byte ptr [rbx], 1
	movsxd	rax, dword ptr [rip + xt_sinit_n]
	cmp	rax, 31
	jg	.LBB104_17
# %bb.16:                               #   in Loop: Header=BB104_2 Depth=1
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
.LBB104_17:                             #   in Loop: Header=BB104_2 Depth=1
	mov	eax, 2
	cmp	dword ptr [r12], 0
	je	.LBB104_21
.LBB104_20:                             #   in Loop: Header=BB104_2 Depth=1
	mov	dword ptr [rip + xt_rt_spin], 0
	jmp	.LBB104_21
	.p2align	4, 0x90
.LBB104_7:                              #   in Loop: Header=BB104_2 Depth=1
	call	pthread_self@PLT
	movsxd	rcx, dword ptr [rip + xt_sinit_n]
	test	rcx, rcx
	jle	.LBB104_12
# %bb.8:                                #   in Loop: Header=BB104_2 Depth=1
	mov	rdx, rax
	shr	rdx, 4
	shr	rax, 32
	xor	edx, eax
	shl	rcx, 3
	xor	eax, eax
	mov	rsi, rbp
	jmp	.LBB104_9
	.p2align	4, 0x90
.LBB104_11:                             #   in Loop: Header=BB104_9 Depth=2
	add	rsi, 4
	add	rax, 8
	cmp	rcx, rax
	je	.LBB104_12
.LBB104_9:                              #   Parent Loop BB104_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	qword ptr [rax + r13], rbx
	jne	.LBB104_11
# %bb.10:                               #   in Loop: Header=BB104_9 Depth=2
	cmp	dword ptr [rsi], edx
	jne	.LBB104_11
	jmp	.LBB104_18
	.p2align	4, 0x90
.LBB104_12:                             #   in Loop: Header=BB104_2 Depth=1
	cmp	dword ptr [r12], 0
	je	.LBB104_14
# %bb.13:                               #   in Loop: Header=BB104_2 Depth=1
	mov	dword ptr [rip + xt_rt_spin], 0
	jmp	.LBB104_14
.LBB104_22:
	cmp	eax, 1
	je	.LBB104_35
# %bb.23:
	test	r14, r14
	je	.LBB104_25
# %bb.24:
	mov	rdi, r15
	call	r14
.LBB104_25:
	cmp	dword ptr [r12], 0
	je	.LBB104_28
	.p2align	4, 0x90
.LBB104_26:                             # =>This Loop Header: Depth=1
                                        #     Child Loop BB104_27 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB104_28
.LBB104_27:                             #   Parent Loop BB104_26 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB104_27
	jmp	.LBB104_26
.LBB104_28:
	mov	byte ptr [rbx], 2
	movsxd	rax, dword ptr [rip + xt_sinit_n]
	test	rax, rax
	jle	.LBB104_33
# %bb.29:
	lea	rdx, [4*rax]
	xor	ecx, ecx
	.p2align	4, 0x90
.LBB104_31:                             # =>This Inner Loop Header: Depth=1
	cmp	qword ptr [r13], rbx
	je	.LBB104_32
# %bb.30:                               #   in Loop: Header=BB104_31 Depth=1
	add	rcx, 4
	add	r13, 8
	cmp	rdx, rcx
	jne	.LBB104_31
.LBB104_33:
	cmp	dword ptr [r12], 0
	je	.LBB104_35
.LBB104_34:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB104_35:
	add	rsp, 8
	pop	rbx
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	pop	rbp
.LBB104_36:
	ret
.LBB104_32:
	lea	edx, [rax - 1]
	mov	dword ptr [rip + xt_sinit_n], edx
	lea	rdx, [rip + xt_sinit_flag]
	mov	rdx, qword ptr [rdx + 8*rax - 8]
	mov	qword ptr [r13], rdx
	lea	rdx, [rip + xt_sinit_owner]
	mov	eax, dword ptr [rdx + 4*rax - 4]
	mov	dword ptr [rcx + rdx], eax
	cmp	dword ptr [r12], 0
	jne	.LBB104_34
	jmp	.LBB104_35
.Lfunc_end104:
	.size	_xtc_sinit_run, .Lfunc_end104-_xtc_sinit_run
                                        # -- End function
	.globl	_xt_thread_exiting              # -- Begin function _xt_thread_exiting
	.p2align	4, 0x90
	.type	_xt_thread_exiting,@function
_xt_thread_exiting:                     # @_xt_thread_exiting
# %bb.0:
	ret
.Lfunc_end105:
	.size	_xt_thread_exiting, .Lfunc_end105-_xt_thread_exiting
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
	je	.LBB106_3
	.p2align	4, 0x90
.LBB106_1:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB106_2 Depth 2
	mov	ecx, 1
	xchg	dword ptr [rip + xt_rt_spin], ecx
	test	ecx, ecx
	je	.LBB106_3
.LBB106_2:                              #   Parent Loop BB106_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	ecx, dword ptr [rip + xt_rt_spin]
	test	ecx, ecx
	jne	.LBB106_2
	jmp	.LBB106_1
.LBB106_3:
	mov	rdx, qword ptr [rip + xt_simd_n]
	test	rdx, rdx
	je	.LBB106_4
# %bb.5:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	xor	ecx, ecx
	movabs	r8, 2305843009213693950
	.p2align	4, 0x90
.LBB106_6:                              # =>This Inner Loop Header: Depth=1
	lea	r9, [rdx + rcx]
	mov	r10, r9
	shr	r10
	and	r9, r8
	cmp	qword ptr [rsi + 8*r9], rax
	lea	r9, [r10 + 1]
	cmova	rdx, r10
	cmovbe	rcx, r9
	cmp	rcx, rdx
	jb	.LBB106_6
	jmp	.LBB106_7
.LBB106_4:
	xor	ecx, ecx
.LBB106_7:
	mov	dl, 1
	test	rcx, rcx
	je	.LBB106_11
# %bb.8:
	mov	rsi, qword ptr [rip + xt_simd_tab]
	lea	r8, [2*rcx - 2]
	cmp	qword ptr [rsi + 8*r8 + 8], rax
	jbe	.LBB106_11
# %bb.9:
	lea	rax, [rcx - 1]
	mov	r9, qword ptr [rip + xt_simd_flag]
	movzx	r10d, byte ptr [r9 + rax]
	test	r10b, 1
	je	.LBB106_11
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
.LBB106_11:
	cmp	dword ptr [rbx], 0
	je	.LBB106_13
# %bb.12:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB106_13:
	test	dl, dl
	je	.LBB106_14
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
.LBB106_14:
	add	rsp, 8
	pop	rbx
	pop	rbp
	ret
.Lfunc_end106:
	.size	xt_simd_fault, .Lfunc_end106-xt_simd_fault
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
	.addrsig_sym _xt_stack_guard_init
	.addrsig_sym xt_gthread_entry
	.addrsig_sym xt_simd_fault
	.addrsig_sym xt_sigrestore
	.addrsig_sym xt_empty
	.addrsig_sym __xt_stack_fail.msg
	.addrsig_sym xt_rt_spin
	.addrsig_sym xt_alloc_spin
	.addrsig_sym xt_size_check.msg
	.addrsig_sym xt_simd_old
	.addrsig_sym xt_simd_pick.msg
	.addrsig_sym xt_simd_pick.msg.4
