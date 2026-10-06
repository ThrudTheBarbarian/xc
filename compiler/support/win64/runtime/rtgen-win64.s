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
	sub	rsp, 40
	mov	rsi, r8
	mov	rbx, rdx
	mov	rdi, rcx
	mov	rax, rdx
	imul	rax, rcx
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
	je	.LBB6_1
# %bb.2:
	mov	dword ptr [rax + 8], 1481920322
	mov	qword ptr [rax + 12], rbx
	mov	qword ptr [rax + 20], rdi
	mov	qword ptr [rax + 28], rsi
	mov	qword ptr [rax + 36], 0
	mov	dword ptr [rax + 44], 1
	add	rax, 48
	jmp	.LBB6_3
.LBB6_1:
	xor	eax, eax
.LBB6_3:
	add	rsp, 40
	pop	rbx
	pop	rdi
	pop	rsi
	pop	r14
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
	push	rdi
	sub	rsp, 40
	mov	rsi, rcx
	cmp	rcx, 257
	mov	edi, 256
	cmovae	rdi, rcx
	call	GetProcessHeap
	add	rdi, 48
	mov	rcx, rax
	mov	edx, 8
	mov	r8, rdi
	call	HeapAlloc
	test	rax, rax
	je	.LBB7_1
# %bb.2:
	mov	dword ptr [rax + 8], 1481920322
	mov	qword ptr [rax + 12], 1
	mov	qword ptr [rax + 20], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 28], xmm0
	mov	dword ptr [rax + 44], 1
	add	rax, 48
	jmp	.LBB7_3
.LBB7_1:
	xor	eax, eax
.LBB7_3:
	add	rsp, 40
	pop	rdi
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
	push	rdi
	sub	rsp, 40
	mov	rsi, rcx
	cmp	rcx, 257
	mov	edi, 256
	cmovae	rdi, rcx
	call	GetProcessHeap
	add	rdi, 48
	mov	rcx, rax
	mov	edx, 8
	mov	r8, rdi
	call	HeapAlloc
	test	rax, rax
	je	.LBB8_1
# %bb.2:
	mov	dword ptr [rax + 8], 1481920322
	mov	qword ptr [rax + 12], 1
	mov	qword ptr [rax + 20], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 28], xmm0
	mov	dword ptr [rax + 44], 1
	add	rax, 48
	jmp	.LBB8_3
.LBB8_1:
	xor	eax, eax
.LBB8_3:
	add	rsp, 40
	pop	rdi
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
	push	rdi
	sub	rsp, 40
	mov	rsi, rcx
	lea	rax, [rcx + rcx]
	cmp	rax, 257
	mov	edi, 256
	cmovae	rdi, rax
	call	GetProcessHeap
	add	rdi, 48
	mov	rcx, rax
	mov	edx, 8
	mov	r8, rdi
	call	HeapAlloc
	test	rax, rax
	je	.LBB9_1
# %bb.2:
	mov	dword ptr [rax + 8], 1481920322
	mov	qword ptr [rax + 12], 2
	mov	qword ptr [rax + 20], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 28], xmm0
	mov	dword ptr [rax + 44], 1
	add	rax, 48
	jmp	.LBB9_3
.LBB9_1:
	xor	eax, eax
.LBB9_3:
	add	rsp, 40
	pop	rdi
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
	push	rdi
	sub	rsp, 40
	mov	rsi, rcx
	lea	rax, [rcx + rcx]
	cmp	rax, 257
	mov	edi, 256
	cmovae	rdi, rax
	call	GetProcessHeap
	add	rdi, 48
	mov	rcx, rax
	mov	edx, 8
	mov	r8, rdi
	call	HeapAlloc
	test	rax, rax
	je	.LBB10_1
# %bb.2:
	mov	dword ptr [rax + 8], 1481920322
	mov	qword ptr [rax + 12], 2
	mov	qword ptr [rax + 20], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 28], xmm0
	mov	dword ptr [rax + 44], 1
	add	rax, 48
	jmp	.LBB10_3
.LBB10_1:
	xor	eax, eax
.LBB10_3:
	add	rsp, 40
	pop	rdi
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
	push	rdi
	sub	rsp, 40
	mov	rsi, rcx
	lea	rax, [4*rcx]
	cmp	rax, 257
	mov	edi, 256
	cmovae	rdi, rax
	call	GetProcessHeap
	add	rdi, 48
	mov	rcx, rax
	mov	edx, 8
	mov	r8, rdi
	call	HeapAlloc
	test	rax, rax
	je	.LBB11_1
# %bb.2:
	mov	dword ptr [rax + 8], 1481920322
	mov	qword ptr [rax + 12], 4
	mov	qword ptr [rax + 20], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 28], xmm0
	mov	dword ptr [rax + 44], 1
	add	rax, 48
	jmp	.LBB11_3
.LBB11_1:
	xor	eax, eax
.LBB11_3:
	add	rsp, 40
	pop	rdi
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
	push	rdi
	sub	rsp, 40
	mov	rsi, rcx
	lea	rax, [4*rcx]
	cmp	rax, 257
	mov	edi, 256
	cmovae	rdi, rax
	call	GetProcessHeap
	add	rdi, 48
	mov	rcx, rax
	mov	edx, 8
	mov	r8, rdi
	call	HeapAlloc
	test	rax, rax
	je	.LBB12_1
# %bb.2:
	mov	dword ptr [rax + 8], 1481920322
	mov	qword ptr [rax + 12], 4
	mov	qword ptr [rax + 20], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 28], xmm0
	mov	dword ptr [rax + 44], 1
	add	rax, 48
	jmp	.LBB12_3
.LBB12_1:
	xor	eax, eax
.LBB12_3:
	add	rsp, 40
	pop	rdi
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
	push	rdi
	sub	rsp, 40
	mov	rsi, rcx
	lea	rax, [8*rcx]
	cmp	rax, 257
	mov	edi, 256
	cmovae	rdi, rax
	call	GetProcessHeap
	add	rdi, 48
	mov	rcx, rax
	mov	edx, 8
	mov	r8, rdi
	call	HeapAlloc
	test	rax, rax
	je	.LBB13_1
# %bb.2:
	mov	dword ptr [rax + 8], 1481920322
	mov	qword ptr [rax + 12], 8
	mov	qword ptr [rax + 20], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 28], xmm0
	mov	dword ptr [rax + 44], 1
	add	rax, 48
	jmp	.LBB13_3
.LBB13_1:
	xor	eax, eax
.LBB13_3:
	add	rsp, 40
	pop	rdi
	pop	rsi
	ret
                                        # -- End function
	.def	_xtc_new_u64;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_u64                    # -- Begin function _xtc_new_u64
	.p2align	4, 0x90
_xtc_new_u64:                           # @_xtc_new_u64
# %bb.0:
	push	rsi
	push	rdi
	sub	rsp, 40
	mov	rsi, rcx
	lea	rax, [8*rcx]
	cmp	rax, 257
	mov	edi, 256
	cmovae	rdi, rax
	call	GetProcessHeap
	add	rdi, 48
	mov	rcx, rax
	mov	edx, 8
	mov	r8, rdi
	call	HeapAlloc
	test	rax, rax
	je	.LBB14_1
# %bb.2:
	mov	dword ptr [rax + 8], 1481920322
	mov	qword ptr [rax + 12], 8
	mov	qword ptr [rax + 20], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 28], xmm0
	mov	dword ptr [rax + 44], 1
	add	rax, 48
	jmp	.LBB14_3
.LBB14_1:
	xor	eax, eax
.LBB14_3:
	add	rsp, 40
	pop	rdi
	pop	rsi
	ret
                                        # -- End function
	.def	_xtc_new_i64;
	.scl	2;
	.type	32;
	.endef
	.globl	_xtc_new_i64                    # -- Begin function _xtc_new_i64
	.p2align	4, 0x90
_xtc_new_i64:                           # @_xtc_new_i64
# %bb.0:
	push	rsi
	push	rdi
	sub	rsp, 40
	mov	rsi, rcx
	lea	rax, [8*rcx]
	cmp	rax, 257
	mov	edi, 256
	cmovae	rdi, rax
	call	GetProcessHeap
	add	rdi, 48
	mov	rcx, rax
	mov	edx, 8
	mov	r8, rdi
	call	HeapAlloc
	test	rax, rax
	je	.LBB15_1
# %bb.2:
	mov	dword ptr [rax + 8], 1481920322
	mov	qword ptr [rax + 12], 8
	mov	qword ptr [rax + 20], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 28], xmm0
	mov	dword ptr [rax + 44], 1
	add	rax, 48
	jmp	.LBB15_3
.LBB15_1:
	xor	eax, eax
.LBB15_3:
	add	rsp, 40
	pop	rdi
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
	push	rdi
	sub	rsp, 40
	mov	rsi, rcx
	cmp	rcx, 257
	mov	edi, 256
	cmovae	rdi, rcx
	call	GetProcessHeap
	add	rdi, 48
	mov	rcx, rax
	mov	edx, 8
	mov	r8, rdi
	call	HeapAlloc
	test	rax, rax
	je	.LBB16_1
# %bb.2:
	mov	dword ptr [rax + 8], 1481920322
	mov	qword ptr [rax + 12], 1
	mov	qword ptr [rax + 20], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 28], xmm0
	mov	dword ptr [rax + 44], 1
	add	rax, 48
	jmp	.LBB16_3
.LBB16_1:
	xor	eax, eax
.LBB16_3:
	add	rsp, 40
	pop	rdi
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
	push	rdi
	sub	rsp, 40
	mov	rsi, rcx
	lea	rax, [4*rcx]
	cmp	rax, 257
	mov	edi, 256
	cmovae	rdi, rax
	call	GetProcessHeap
	add	rdi, 48
	mov	rcx, rax
	mov	edx, 8
	mov	r8, rdi
	call	HeapAlloc
	test	rax, rax
	je	.LBB17_1
# %bb.2:
	mov	dword ptr [rax + 8], 1481920322
	mov	qword ptr [rax + 12], 4
	mov	qword ptr [rax + 20], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 28], xmm0
	mov	dword ptr [rax + 44], 1
	add	rax, 48
	jmp	.LBB17_3
.LBB17_1:
	xor	eax, eax
.LBB17_3:
	add	rsp, 40
	pop	rdi
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
	push	rdi
	sub	rsp, 40
	mov	rsi, rcx
	lea	rax, [8*rcx]
	cmp	rax, 257
	mov	edi, 256
	cmovae	rdi, rax
	call	GetProcessHeap
	add	rdi, 48
	mov	rcx, rax
	mov	edx, 8
	mov	r8, rdi
	call	HeapAlloc
	test	rax, rax
	je	.LBB18_1
# %bb.2:
	mov	dword ptr [rax + 8], 1481920322
	mov	qword ptr [rax + 12], 8
	mov	qword ptr [rax + 20], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 28], xmm0
	mov	dword ptr [rax + 44], 1
	add	rax, 48
	jmp	.LBB18_3
.LBB18_1:
	xor	eax, eax
.LBB18_3:
	add	rsp, 40
	pop	rdi
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
	push	rdi
	sub	rsp, 40
	mov	rsi, rcx
	lea	rax, [8*rcx]
	cmp	rax, 257
	mov	edi, 256
	cmovae	rdi, rax
	call	GetProcessHeap
	add	rdi, 48
	mov	rcx, rax
	mov	edx, 8
	mov	r8, rdi
	call	HeapAlloc
	test	rax, rax
	je	.LBB19_1
# %bb.2:
	mov	dword ptr [rax + 8], 1481920322
	mov	qword ptr [rax + 12], 8
	mov	qword ptr [rax + 20], rsi
	xorps	xmm0, xmm0
	movups	xmmword ptr [rax + 28], xmm0
	mov	dword ptr [rax + 44], 1
	add	rax, 48
	jmp	.LBB19_3
.LBB19_1:
	xor	eax, eax
.LBB19_3:
	add	rsp, 40
	pop	rdi
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
	mov	rax, qword ptr [rsi - 12]
	test	rax, rax
	je	.LBB21_7
# %bb.5:
	xorps	xmm0, xmm0
	.p2align	4, 0x90
.LBB21_6:                               # =>This Inner Loop Header: Depth=1
	mov	rcx, qword ptr [rax - 8]
	movups	xmmword ptr [rax - 16], xmm0
	mov	qword ptr [rax], 0
	mov	rax, rcx
	test	rcx, rcx
	jne	.LBB21_6
.LBB21_7:
	mov	qword ptr [rsi - 12], 0
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB21_9
# %bb.8:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB21_9:
	mov	rbx, qword ptr [rsi - 20]
	test	rbx, rbx
	je	.LBB21_13
# %bb.10:
	mov	r14, qword ptr [rsi - 36]
	mov	r15, qword ptr [rsi - 28]
	mov	dword ptr [rsi - 4], -2147483648
	test	r15, r15
	je	.LBB21_13
# %bb.11:
	mov	rdi, rsi
	.p2align	4, 0x90
.LBB21_12:                              # =>This Inner Loop Header: Depth=1
	mov	rcx, rdi
	call	rbx
	add	rdi, r14
	dec	r15
	jne	.LBB21_12
.LBB21_13:
	call	GetProcessHeap
	add	rsi, -48
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
	je	.LBB22_9
# %bb.1:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB22_4
	.p2align	4, 0x90
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
	mov	rax, qword ptr [rcx - 12]
	test	rax, rax
	je	.LBB22_7
# %bb.5:
	xorps	xmm0, xmm0
	.p2align	4, 0x90
.LBB22_6:                               # =>This Inner Loop Header: Depth=1
	mov	rdx, qword ptr [rax - 8]
	movups	xmmword ptr [rax - 16], xmm0
	mov	qword ptr [rax], 0
	mov	rax, rdx
	test	rdx, rdx
	jne	.LBB22_6
.LBB22_7:
	mov	qword ptr [rcx - 12], 0
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB22_9
# %bb.8:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB22_9:
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
	mov	rax, qword ptr [rcx - 16]
	test	rax, rax
	je	.LBB23_8
# %bb.4:
	lea	rdx, [rcx - 16]
	cmp	qword ptr [rax], rcx
	jne	.LBB23_7
# %bb.5:
	mov	rcx, qword ptr [rcx - 8]
	mov	qword ptr [rax], rcx
	test	rcx, rcx
	je	.LBB23_7
# %bb.6:
	mov	qword ptr [rcx - 16], rax
.LBB23_7:
	xorps	xmm0, xmm0
	movups	xmmword ptr [rdx], xmm0
.LBB23_8:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB23_10
# %bb.9:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB23_10:
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
	je	.LBB24_3
	.p2align	4, 0x90
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
	je	.LBB25_2
# %bb.1:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB25_2:
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
	je	.LBB26_3
	.p2align	4, 0x90
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
	mov	rax, qword ptr [rcx - 16]
	test	rax, rax
	je	.LBB26_8
# %bb.4:
	lea	r8, [rcx - 16]
	cmp	qword ptr [rax], rcx
	jne	.LBB26_7
# %bb.5:
	mov	r9, qword ptr [rcx - 8]
	mov	qword ptr [rax], r9
	test	r9, r9
	je	.LBB26_7
# %bb.6:
	mov	qword ptr [r9 - 16], rax
.LBB26_7:
	xorps	xmm0, xmm0
	movups	xmmword ptr [r8], xmm0
.LBB26_8:
	test	rdx, rdx
	je	.LBB26_13
# %bb.9:
	cmp	dword ptr [rdx - 40], 1481920322
	jne	.LBB26_13
# %bb.10:
	mov	rax, qword ptr [rdx - 12]
	add	rdx, -12
	mov	qword ptr [rcx - 16], rdx
	mov	qword ptr [rcx - 8], rax
	test	rax, rax
	je	.LBB26_12
# %bb.11:
	lea	r8, [rcx - 8]
	mov	qword ptr [rax - 16], r8
.LBB26_12:
	mov	qword ptr [rdx], rcx
.LBB26_13:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB26_15
# %bb.14:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB26_15:
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
.LCPI32_0:
	.long	0x30000000                      # float 4.65661287E-10
.LCPI32_1:
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
	mulss	xmm0, dword ptr [rip + .LCPI32_0]
	movss	xmm1, dword ptr [rip + .LCPI32_1] # xmm1 = [5.0E-1,0.0E+0,0.0E+0,0.0E+0]
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
.LCPI33_0:
	.quad	0x3e00000000000000              # double 4.6566128730773926E-10
.LCPI33_1:
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
	mulsd	xmm0, qword ptr [rip + .LCPI33_0]
	movsd	xmm1, qword ptr [rip + .LCPI33_1] # xmm1 = [5.0E-1,0.0E+0]
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
	unpcklps	xmm0, xmmword ptr [rip + .LCPI34_0] # xmm0 = xmm0[0],mem[0],xmm0[1],mem[1]
	subpd	xmm0, xmmword ptr [rip + .LCPI34_1]
	movapd	xmm1, xmm0
	unpckhpd	xmm1, xmm0                      # xmm1 = xmm1[1],xmm0[1]
	addsd	xmm1, xmm0
	mulsd	xmm1, qword ptr [rip + .LCPI34_2]
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
.LCPI35_0:
	.long	1127219200                      # 0x43300000
	.long	1160773632                      # 0x45300000
	.long	0                               # 0x0
	.long	0                               # 0x0
.LCPI35_1:
	.quad	0x4330000000000000              # double 4503599627370496
	.quad	0x4530000000000000              # double 1.9342813113834067E+25
.LCPI35_2:
	.quad	0x3e7ad7f29abcaf48              # double 9.9999999999999995E-8
.LCPI35_3:
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
	unpcklps	xmm0, xmmword ptr [rip + .LCPI35_0] # xmm0 = xmm0[0],mem[0],xmm0[1],mem[1]
	subpd	xmm0, xmmword ptr [rip + .LCPI35_1]
	movapd	xmm1, xmm0
	unpckhpd	xmm1, xmm0                      # xmm1 = xmm1[1],xmm0[1]
	addsd	xmm1, xmm0
	mulsd	xmm1, qword ptr [rip + .LCPI35_2]
	subsd	xmm1, qword ptr [rip + xt_clk_origin]
	mulsd	xmm1, qword ptr [rip + .LCPI35_3]
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
.LCPI36_0:
	.quad	0x404e000000000000              # double 60
.LCPI36_1:
	.quad	0x41cdcd6500000000              # double 1.0E+9
.LCPI36_2:
	.quad	0x43e0000000000000              # double 9.2233720368547758E+18
	.text
	.globl	_xt_clk_delay
	.p2align	4, 0x90
_xt_clk_delay:                          # @_xt_clk_delay
# %bb.0:
	mov	eax, ecx
	cvtsi2sd	xmm0, rax
	divsd	xmm0, qword ptr [rip + .LCPI36_0]
	mulsd	xmm0, qword ptr [rip + .LCPI36_1]
	cvttsd2si	rcx, xmm0
	mov	rdx, rcx
	sar	rdx, 63
	subsd	xmm0, qword ptr [rip + .LCPI36_2]
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
	jbe	.LBB37_2
# %bb.1:
	xor	eax, eax
	jmp	.LBB37_5
.LBB37_2:
	movzx	eax, cl
	shl	eax, 11
	lea	rcx, [rip + xt_bank_regions]
	add	rcx, rax
	movzx	eax, dl
	lea	rsi, [rcx + 8*rax]
	cmp	qword ptr [rcx + 8*rax], 0
	jne	.LBB37_4
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
.LBB37_4:
	mov	rax, qword ptr [rsi]
.LBB37_5:
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
	je	.LBB39_3
	.p2align	4, 0x90
.LBB39_1:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB39_2 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_alloc_spin], eax
	test	eax, eax
	je	.LBB39_3
.LBB39_2:                               #   Parent Loop BB39_1 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_alloc_spin]
	test	eax, eax
	jne	.LBB39_2
	jmp	.LBB39_1
.LBB39_3:
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
	je	.LBB40_2
# %bb.1:
	mov	dword ptr [rip + xt_alloc_spin], 0
.LBB40_2:
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
	je	.LBB41_4
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
	je	.LBB41_4
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
	jne	.LBB41_5
# %bb.3:
	call	GetProcessHeap
	add	rsi, -8
	mov	rcx, rax
	xor	edx, edx
	mov	r8, rsi
	call	HeapFree
.LBB41_4:
	xor	eax, eax
.LBB41_5:
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
	je	.LBB42_2
# %bb.1:
	mov	rcx, rsi
	call	rbx
.LBB42_2:
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
	je	.LBB43_1
# %bb.2:
	mov	rsi, rcx
	mov	edx, -1
	call	WaitForSingleObject
	mov	rcx, rsi
	call	CloseHandle
	xor	eax, eax
	jmp	.LBB43_3
.LBB43_1:
	mov	eax, -1
.LBB43_3:
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
	je	.LBB49_2
# %bb.1:
	mov	rcx, rsi
	call	InitializeSRWLock
.LBB49_2:
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
	je	.LBB50_1
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
.LBB50_1:
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
	je	.LBB53_1
# %bb.2:
	call	TryAcquireSRWLockExclusive
	mov	ecx, eax
	xor	eax, eax
	test	cl, cl
	setne	al
	add	rsp, 40
	ret
.LBB53_1:
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
	je	.LBB54_2
# %bb.1:
	mov	rcx, rsi
	call	InitializeConditionVariable
.LBB54_2:
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
	je	.LBB55_1
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
.LBB55_1:
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
	jne	.LBB56_1
# %bb.2:
	mov	r8d, -1
	xor	r9d, r9d
	jmp	SleepConditionVariableSRW       # TAILCALL
.LBB56_1:
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
	je	.LBB61_1
# %bb.2:
	mov	edx, -1
	jmp	WaitForSingleObject             # TAILCALL
.LBB61_1:
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
	je	.LBB62_1
# %bb.2:
	mov	edx, 1
	xor	r8d, r8d
	jmp	ReleaseSemaphore                # TAILCALL
.LBB62_1:
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
	je	.LBB63_1
# %bb.2:
	xor	edx, edx
	call	WaitForSingleObject
	mov	ecx, eax
	xor	eax, eax
	test	ecx, ecx
	sete	al
	add	rsp, 40
	ret
.LBB63_1:
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
	je	.LBB67_1
# %bb.2:
	mov	eax, dword ptr [rcx]
	ret
.LBB67_1:
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
	je	.LBB68_2
# %bb.1:
	xchg	dword ptr [rcx], edx
.LBB68_2:
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
	je	.LBB69_1
# %bb.2:
	mov	eax, edx
	lock		xadd	dword ptr [rcx], eax
	add	eax, edx
	ret
.LBB69_1:
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
	je	.LBB70_1
# %bb.2:
	mov	eax, edx
	xchg	dword ptr [rcx], eax
	ret
.LBB70_1:
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
	je	.LBB71_1
# %bb.2:
	mov	eax, edx
	lock		cmpxchg	dword ptr [rcx], r8d
	mov	eax, 0
	sete	al
	ret
.LBB71_1:
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
	je	.LBB72_1
# %bb.2:
	mov	rax, qword ptr [rcx]
	ret
.LBB72_1:
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
	je	.LBB73_2
# %bb.1:
	xchg	qword ptr [rcx], rdx
.LBB73_2:
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
	je	.LBB74_1
# %bb.2:
	mov	rax, rdx
	lock		cmpxchg	qword ptr [rcx], r8
	mov	eax, 0
	sete	al
	ret
.LBB74_1:
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
	test	ecx, 402653184
	jne	.LBB75_4
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
	jne	.LBB75_4
# %bb.2:
	xor	ebp, ebp
	mov	eax, 7
	xor	ecx, ecx
	#APP

	.byte	15
	.byte	162

	#NO_APP
	test	bl, 32
	je	.LBB75_4
# %bb.3:
	not	ebx
	and	ebx, -1073545216
	and	r8d, 224
	xor	ebp, ebp
	or	r8d, ebx
	sete	bpl
	inc	ebp
.LBB75_4:
	lea	rcx, [rip + .L.str]
	lea	rbx, [rip + xt_env.buf]
	mov	rdx, rbx
	mov	r8d, 32
	call	GetEnvironmentVariableA
	add	eax, -32
	xor	ecx, ecx
	cmp	eax, -31
	cmovae	rcx, rbx
	jae	.LBB75_5
.LBB75_27:
	mov	r8d, ebp
	jmp	.LBB75_28
.LBB75_5:
	movzx	eax, byte ptr [rcx]
	test	al, al
	je	.LBB75_6
# %bb.7:
	lea	r8, [rcx + 1]
	lea	rdx, [rip + .L.str.1]
	mov	r9d, eax
	.p2align	4, 0x90
.LBB75_8:                               # =>This Inner Loop Header: Depth=1
	cmp	r9b, byte ptr [rdx]
	jne	.LBB75_10
# %bb.9:                                #   in Loop: Header=BB75_8 Depth=1
	inc	rdx
	movzx	r9d, byte ptr [r8]
	inc	r8
	test	r9b, r9b
	jne	.LBB75_8
	jmp	.LBB75_10
.LBB75_6:
	lea	rdx, [rip + .L.str.1]
	mov	r9d, eax
.LBB75_10:
	xor	r8d, r8d
	cmp	r9b, byte ptr [rdx]
	cmovne	r8d, ebp
	je	.LBB75_28
# %bb.11:
	test	al, al
	je	.LBB75_12
# %bb.13:
	lea	r9, [rcx + 1]
	lea	rdx, [rip + .L.str.2]
	mov	r8d, eax
	.p2align	4, 0x90
.LBB75_14:                              # =>This Inner Loop Header: Depth=1
	cmp	r8b, byte ptr [rdx]
	jne	.LBB75_16
# %bb.15:                               #   in Loop: Header=BB75_14 Depth=1
	inc	rdx
	movzx	r8d, byte ptr [r9]
	inc	r9
	test	r8b, r8b
	jne	.LBB75_14
.LBB75_16:
	cmp	r8b, byte ptr [rdx]
	jne	.LBB75_19
.LBB75_17:
	mov	r8d, 1
	test	ebp, ebp
	jne	.LBB75_28
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
.LBB75_28:
	xor	eax, eax
	test	r8d, r8d
	setne	al
	mov	dword ptr [rip + _xt_simd_level], eax
	test	edi, edi
	je	.LBB75_31
# %bb.29:
	cmp	r8d, 1
	mov	eax, 1
	sbb	eax, -1
	mov	ecx, edi
	lea	rcx, [rcx + 2*rcx]
	xor	edx, edx
	.p2align	4, 0x90
.LBB75_30:                              # =>This Inner Loop Header: Depth=1
	mov	r8d, edx
	mov	r8, qword ptr [rsi + 8*r8]
	lea	r9d, [rax + rdx]
	mov	r9, qword ptr [rsi + 8*r9]
	mov	qword ptr [r8], r9
	add	rdx, 3
	cmp	rcx, rdx
	jne	.LBB75_30
.LBB75_31:
	add	rsp, 56
	pop	rbx
	pop	rbp
	pop	rdi
	pop	rsi
	ret
.LBB75_12:
	lea	rdx, [rip + .L.str.2]
	mov	r8d, eax
	cmp	r8b, byte ptr [rdx]
	je	.LBB75_17
.LBB75_19:
	test	al, al
	je	.LBB75_20
# %bb.21:
	inc	rcx
	lea	rdx, [rip + .L.str.3]
	.p2align	4, 0x90
.LBB75_22:                              # =>This Inner Loop Header: Depth=1
	cmp	al, byte ptr [rdx]
	jne	.LBB75_24
# %bb.23:                               #   in Loop: Header=BB75_22 Depth=1
	inc	rdx
	movzx	eax, byte ptr [rcx]
	inc	rcx
	test	al, al
	jne	.LBB75_22
	jmp	.LBB75_24
.LBB75_20:
	lea	rdx, [rip + .L.str.3]
.LBB75_24:
	cmp	ebp, 1
	ja	.LBB75_27
# %bb.25:
	cmp	al, byte ptr [rdx]
	jne	.LBB75_27
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
	jmp	.LBB75_27
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
	test	ecx, 402653184
	jne	.LBB76_4
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
	jne	.LBB76_4
# %bb.2:
	xor	ebp, ebp
	mov	eax, 7
	xor	ecx, ecx
	#APP

	.byte	15
	.byte	162

	#NO_APP
	test	bl, 32
	je	.LBB76_4
# %bb.3:
	not	ebx
	and	ebx, -1073545216
	and	r8d, 224
	xor	ebp, ebp
	or	r8d, ebx
	sete	bpl
	inc	ebp
.LBB76_4:
	lea	rcx, [rip + .L.str]
	lea	rbx, [rip + xt_env.buf]
	mov	rdx, rbx
	mov	r8d, 32
	call	GetEnvironmentVariableA
	add	eax, -32
	xor	ecx, ecx
	cmp	eax, -31
	cmovae	rcx, rbx
	jae	.LBB76_5
.LBB76_27:
	mov	r8d, ebp
	jmp	.LBB76_28
.LBB76_5:
	movzx	eax, byte ptr [rcx]
	test	al, al
	je	.LBB76_6
# %bb.7:
	lea	r8, [rcx + 1]
	lea	rdx, [rip + .L.str.1]
	mov	r9d, eax
	.p2align	4, 0x90
.LBB76_8:                               # =>This Inner Loop Header: Depth=1
	cmp	r9b, byte ptr [rdx]
	jne	.LBB76_10
# %bb.9:                                #   in Loop: Header=BB76_8 Depth=1
	inc	rdx
	movzx	r9d, byte ptr [r8]
	inc	r8
	test	r9b, r9b
	jne	.LBB76_8
	jmp	.LBB76_10
.LBB76_6:
	lea	rdx, [rip + .L.str.1]
	mov	r9d, eax
.LBB76_10:
	xor	r8d, r8d
	cmp	r9b, byte ptr [rdx]
	cmovne	r8d, ebp
	je	.LBB76_28
# %bb.11:
	test	al, al
	je	.LBB76_12
# %bb.13:
	lea	r9, [rcx + 1]
	lea	rdx, [rip + .L.str.2]
	mov	r8d, eax
	.p2align	4, 0x90
.LBB76_14:                              # =>This Inner Loop Header: Depth=1
	cmp	r8b, byte ptr [rdx]
	jne	.LBB76_16
# %bb.15:                               #   in Loop: Header=BB76_14 Depth=1
	inc	rdx
	movzx	r8d, byte ptr [r9]
	inc	r9
	test	r8b, r8b
	jne	.LBB76_14
.LBB76_16:
	cmp	r8b, byte ptr [rdx]
	jne	.LBB76_19
.LBB76_17:
	mov	r8d, 1
	test	ebp, ebp
	jne	.LBB76_28
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
.LBB76_28:
	mov	dword ptr [rip + _xt_simd_level], r8d
	test	edi, edi
	je	.LBB76_31
# %bb.29:
	mov	eax, edi
	mov	ecx, r8d
	inc	rcx
	shl	rax, 2
	xor	edx, edx
	.p2align	4, 0x90
.LBB76_30:                              # =>This Inner Loop Header: Depth=1
	mov	r8d, edx
	mov	r8, qword ptr [rsi + 8*r8]
	lea	r9d, [rcx + rdx]
	mov	r9, qword ptr [rsi + 8*r9]
	mov	qword ptr [r8], r9
	add	rdx, 4
	cmp	rax, rdx
	jne	.LBB76_30
.LBB76_31:
	add	rsp, 56
	pop	rbx
	pop	rbp
	pop	rdi
	pop	rsi
	ret
.LBB76_12:
	lea	rdx, [rip + .L.str.2]
	mov	r8d, eax
	cmp	r8b, byte ptr [rdx]
	je	.LBB76_17
.LBB76_19:
	test	al, al
	je	.LBB76_20
# %bb.21:
	inc	rcx
	lea	rdx, [rip + .L.str.3]
	.p2align	4, 0x90
.LBB76_22:                              # =>This Inner Loop Header: Depth=1
	cmp	al, byte ptr [rdx]
	jne	.LBB76_24
# %bb.23:                               #   in Loop: Header=BB76_22 Depth=1
	inc	rdx
	movzx	eax, byte ptr [rcx]
	inc	rcx
	test	al, al
	jne	.LBB76_22
	jmp	.LBB76_24
.LBB76_20:
	lea	rdx, [rip + .L.str.3]
.LBB76_24:
	cmp	ebp, 1
	ja	.LBB76_27
# %bb.25:
	cmp	al, byte ptr [rdx]
	jne	.LBB76_27
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
	jmp	.LBB76_27
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
	je	.LBB77_35
# %bb.1:
	mov	rbx, r8
	mov	rdi, rdx
	mov	rsi, rcx
	lea	r14, [rip + xt_sinit_flag]
	lea	r15, [rip + xt_sinit_owner]
	jmp	.LBB77_2
	.p2align	4, 0x90
.LBB77_14:                              #   in Loop: Header=BB77_2 Depth=1
	call	SwitchToThread
	xor	eax, eax
.LBB77_21:                              #   in Loop: Header=BB77_2 Depth=1
	test	eax, eax
	jne	.LBB77_22
.LBB77_2:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB77_3 Depth 2
                                        #       Child Loop BB77_4 Depth 3
                                        #     Child Loop BB77_9 Depth 2
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB77_5
	.p2align	4, 0x90
.LBB77_3:                               #   Parent Loop BB77_2 Depth=1
                                        # =>  This Loop Header: Depth=2
                                        #       Child Loop BB77_4 Depth 3
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB77_5
.LBB77_4:                               #   Parent Loop BB77_2 Depth=1
                                        #     Parent Loop BB77_3 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB77_4
	jmp	.LBB77_3
	.p2align	4, 0x90
.LBB77_5:                               #   in Loop: Header=BB77_2 Depth=1
	movzx	eax, byte ptr [rsi]
	test	eax, eax
	je	.LBB77_15
# %bb.6:                                #   in Loop: Header=BB77_2 Depth=1
	cmp	eax, 2
	jne	.LBB77_7
.LBB77_18:                              #   in Loop: Header=BB77_2 Depth=1
	mov	eax, 1
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB77_20
	jmp	.LBB77_21
	.p2align	4, 0x90
.LBB77_15:                              #   in Loop: Header=BB77_2 Depth=1
	mov	byte ptr [rsi], 1
	movsxd	rax, dword ptr [rip + xt_sinit_n]
	cmp	rax, 31
	jg	.LBB77_17
# %bb.16:                               #   in Loop: Header=BB77_2 Depth=1
	mov	qword ptr [r14 + 8*rax], rsi
	call	GetCurrentThreadId
	movsxd	rcx, dword ptr [rip + xt_sinit_n]
	mov	dword ptr [r15 + 4*rcx], eax
	lea	eax, [rcx + 1]
	mov	dword ptr [rip + xt_sinit_n], eax
.LBB77_17:                              #   in Loop: Header=BB77_2 Depth=1
	mov	eax, 2
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB77_21
.LBB77_20:                              #   in Loop: Header=BB77_2 Depth=1
	mov	dword ptr [rip + xt_rt_spin], 0
	jmp	.LBB77_21
	.p2align	4, 0x90
.LBB77_7:                               #   in Loop: Header=BB77_2 Depth=1
	call	GetCurrentThreadId
	movsxd	rcx, dword ptr [rip + xt_sinit_n]
	test	rcx, rcx
	jle	.LBB77_12
# %bb.8:                                #   in Loop: Header=BB77_2 Depth=1
	shl	rcx, 3
	xor	edx, edx
	mov	r8, r15
	jmp	.LBB77_9
	.p2align	4, 0x90
.LBB77_11:                              #   in Loop: Header=BB77_9 Depth=2
	add	r8, 4
	add	rdx, 8
	cmp	rcx, rdx
	je	.LBB77_12
.LBB77_9:                               #   Parent Loop BB77_2 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	cmp	qword ptr [rdx + r14], rsi
	jne	.LBB77_11
# %bb.10:                               #   in Loop: Header=BB77_9 Depth=2
	cmp	dword ptr [r8], eax
	jne	.LBB77_11
	jmp	.LBB77_18
	.p2align	4, 0x90
.LBB77_12:                              #   in Loop: Header=BB77_2 Depth=1
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB77_14
# %bb.13:                               #   in Loop: Header=BB77_2 Depth=1
	mov	dword ptr [rip + xt_rt_spin], 0
	jmp	.LBB77_14
.LBB77_22:
	cmp	eax, 1
	je	.LBB77_35
# %bb.23:
	test	rdi, rdi
	je	.LBB77_25
# %bb.24:
	mov	rcx, rbx
	call	rdi
.LBB77_25:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB77_28
	.p2align	4, 0x90
.LBB77_26:                              # =>This Loop Header: Depth=1
                                        #     Child Loop BB77_27 Depth 2
	mov	eax, 1
	xchg	dword ptr [rip + xt_rt_spin], eax
	test	eax, eax
	je	.LBB77_28
.LBB77_27:                              #   Parent Loop BB77_26 Depth=1
                                        # =>  This Inner Loop Header: Depth=2
	mov	eax, dword ptr [rip + xt_rt_spin]
	test	eax, eax
	jne	.LBB77_27
	jmp	.LBB77_26
.LBB77_28:
	mov	byte ptr [rsi], 2
	movsxd	rax, dword ptr [rip + xt_sinit_n]
	test	rax, rax
	jle	.LBB77_33
# %bb.29:
	lea	rdx, [4*rax]
	xor	ecx, ecx
	.p2align	4, 0x90
.LBB77_31:                              # =>This Inner Loop Header: Depth=1
	cmp	qword ptr [r14], rsi
	je	.LBB77_32
# %bb.30:                               #   in Loop: Header=BB77_31 Depth=1
	add	rcx, 4
	add	r14, 8
	cmp	rdx, rcx
	jne	.LBB77_31
.LBB77_33:
	cmp	dword ptr [rip + _xt_threads_active], 0
	je	.LBB77_35
.LBB77_34:
	mov	dword ptr [rip + xt_rt_spin], 0
.LBB77_35:
	add	rsp, 32
	pop	rbx
	pop	rdi
	pop	rsi
	pop	r14
	pop	r15
	ret
.LBB77_32:
	lea	edx, [rax - 1]
	mov	dword ptr [rip + xt_sinit_n], edx
	lea	rdx, [rip + xt_sinit_flag]
	mov	rdx, qword ptr [rdx + 8*rax - 8]
	mov	qword ptr [r14], rdx
	lea	rdx, [rip + xt_sinit_owner]
	mov	eax, dword ptr [rdx + 4*rax - 4]
	mov	dword ptr [rcx + rdx], eax
	cmp	dword ptr [rip + _xt_threads_active], 0
	jne	.LBB77_34
	jmp	.LBB77_35
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
	.addrsig
	.addrsig_sym xt_thread_entry
	.addrsig_sym xt_rt_spin
	.addrsig_sym xt_alloc_spin
	.addrsig_sym xt_simd_pick.msg
	.addrsig_sym xt_simd_pick.msg.4
	.addrsig_sym xt_env.buf
