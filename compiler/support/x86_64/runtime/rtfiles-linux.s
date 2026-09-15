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

	.intel_syntax noprefix
	.file	"rt-files.c"
	.text
	.globl	_xt_file_open                   # -- Begin function _xt_file_open
	.p2align	4
	.type	_xt_file_open,@function
_xt_file_open:                          # @_xt_file_open
# %bb.0:
	movzx	ecx, byte ptr [rsi]
	cmp	ecx, 97
	je	.LBB0_11
# %bb.1:
	cmp	ecx, 119
	je	.LBB0_7
# %bb.2:
	mov	eax, -1
	cmp	ecx, 114
	jne	.LBB0_16
# %bb.3:
	movzx	ecx, byte ptr [rsi + 1]
	test	ecx, ecx
	je	.LBB0_6
# %bb.4:
	mov	rax, rsi
	mov	esi, 2
	cmp	ecx, 43
	je	.LBB0_15
# %bb.5:
	xor	esi, esi
	cmp	byte ptr [rax + 2], 43
	sete	sil
	add	esi, esi
	jmp	.LBB0_15
.LBB0_7:
	movzx	ecx, byte ptr [rsi + 1]
	test	ecx, ecx
	je	.LBB0_10
# %bb.8:
	mov	rax, rsi
	mov	esi, 578
	cmp	ecx, 43
	je	.LBB0_15
# %bb.9:
	xor	esi, esi
	cmp	byte ptr [rax + 2], 43
	sete	sil
	add	rsi, 577
	jmp	.LBB0_15
.LBB0_11:
	movzx	ecx, byte ptr [rsi + 1]
	test	ecx, ecx
	je	.LBB0_14
# %bb.12:
	mov	rax, rsi
	mov	esi, 1090
	cmp	ecx, 43
	je	.LBB0_15
# %bb.13:
	xor	esi, esi
	cmp	byte ptr [rax + 2], 43
	sete	sil
	add	rsi, 1089
	jmp	.LBB0_15
.LBB0_10:
	mov	esi, 577
	jmp	.LBB0_15
.LBB0_14:
	mov	esi, 1089
	jmp	.LBB0_15
.LBB0_6:
	xor	esi, esi
.LBB0_15:
	push	rax
	mov	edx, 420
	call	_sys_open@PLT
	mov	rcx, rax
	test	rax, rax
	mov	eax, -1
	cmovns	eax, ecx
	add	rsp, 8
.LBB0_16:
	ret
.Lfunc_end0:
	.size	_xt_file_open, .Lfunc_end0-_xt_file_open
                                        # -- End function
	.globl	_xt_file_read                   # -- Begin function _xt_file_read
	.p2align	4
	.type	_xt_file_read,@function
_xt_file_read:                          # @_xt_file_read
# %bb.0:
	push	rax
	movsxd	rdi, edi
	mov	edx, edx
	call	_sys_read@PLT
	test	rax, rax
	mov	ecx, -1
	cmovs	eax, ecx
                                        # kill: def $eax killed $eax killed $rax
	pop	rcx
	ret
.Lfunc_end1:
	.size	_xt_file_read, .Lfunc_end1-_xt_file_read
                                        # -- End function
	.globl	_xt_file_write                  # -- Begin function _xt_file_write
	.p2align	4
	.type	_xt_file_write,@function
_xt_file_write:                         # @_xt_file_write
# %bb.0:
	push	rax
	mov	edx, edx
	call	write@PLT
	test	rax, rax
	mov	ecx, -1
	cmovs	eax, ecx
                                        # kill: def $eax killed $eax killed $rax
	pop	rcx
	ret
.Lfunc_end2:
	.size	_xt_file_write, .Lfunc_end2-_xt_file_write
                                        # -- End function
	.globl	_xt_file_close                  # -- Begin function _xt_file_close
	.p2align	4
	.type	_xt_file_close,@function
_xt_file_close:                         # @_xt_file_close
# %bb.0:
	movsxd	rdi, edi
	jmp	_sys_close@PLT                  # TAILCALL
.Lfunc_end3:
	.size	_xt_file_close, .Lfunc_end3-_xt_file_close
                                        # -- End function
	.globl	_xt_file_size                   # -- Begin function _xt_file_size
	.p2align	4
	.type	_xt_file_size,@function
_xt_file_size:                          # @_xt_file_size
# %bb.0:
	push	r14
	push	rbx
	push	rax
	xor	esi, esi
	xor	edx, edx
	call	_sys_open@PLT
	test	rax, rax
	js	.LBB4_1
# %bb.2:
	mov	rbx, rax
	mov	edx, 2
	mov	rdi, rax
	xor	esi, esi
	call	_sys_lseek@PLT
	mov	r14, rax
	mov	rdi, rbx
	call	_sys_close@PLT
	cmp	r14, 2147483647
	mov	eax, -1
	cmovbe	eax, r14d
	jmp	.LBB4_3
.LBB4_1:
	mov	eax, -1
.LBB4_3:
	add	rsp, 8
	pop	rbx
	pop	r14
	ret
.Lfunc_end4:
	.size	_xt_file_size, .Lfunc_end4-_xt_file_size
                                        # -- End function
	.globl	_xt_file_exists                 # -- Begin function _xt_file_exists
	.p2align	4
	.type	_xt_file_exists,@function
_xt_file_exists:                        # @_xt_file_exists
# %bb.0:
	push	rbx
	xor	ebx, ebx
	xor	esi, esi
	xor	edx, edx
	call	_sys_open@PLT
	test	rax, rax
	js	.LBB5_2
# %bb.1:
	mov	rdi, rax
	call	_sys_close@PLT
	mov	ebx, 1
.LBB5_2:
	mov	eax, ebx
	pop	rbx
	ret
.Lfunc_end5:
	.size	_xt_file_exists, .Lfunc_end5-_xt_file_exists
                                        # -- End function
	.globl	_xt_file_exists_exact           # -- Begin function _xt_file_exists_exact
	.p2align	4
	.type	_xt_file_exists_exact,@function
_xt_file_exists_exact:                  # @_xt_file_exists_exact
# %bb.0:
	push	rbx
	xor	ebx, ebx
	xor	esi, esi
	xor	edx, edx
	call	_sys_open@PLT
	test	rax, rax
	js	.LBB6_2
# %bb.1:
	mov	rdi, rax
	call	_sys_close@PLT
	mov	ebx, 1
.LBB6_2:
	mov	eax, ebx
	pop	rbx
	ret
.Lfunc_end6:
	.size	_xt_file_exists_exact, .Lfunc_end6-_xt_file_exists_exact
                                        # -- End function
	.globl	_xt_file_chmod_exec             # -- Begin function _xt_file_chmod_exec
	.p2align	4
	.type	_xt_file_chmod_exec,@function
_xt_file_chmod_exec:                    # @_xt_file_chmod_exec
# %bb.0:
	push	rax
	mov	esi, 493
	call	_sys_chmod@PLT
	sar	rax, 63
                                        # kill: def $eax killed $eax killed $rax
	pop	rcx
	ret
.Lfunc_end7:
	.size	_xt_file_chmod_exec, .Lfunc_end7-_xt_file_chmod_exec
                                        # -- End function
	.globl	_xt_mkdir                       # -- Begin function _xt_mkdir
	.p2align	4
	.type	_xt_mkdir,@function
_xt_mkdir:                              # @_xt_mkdir
# %bb.0:
	push	rax
	mov	esi, 493
	call	_sys_mkdir@PLT
	sar	rax, 63
                                        # kill: def $eax killed $eax killed $rax
	pop	rcx
	ret
.Lfunc_end8:
	.size	_xt_mkdir, .Lfunc_end8-_xt_mkdir
                                        # -- End function
	.globl	_xt_argc                        # -- Begin function _xt_argc
	.p2align	4
	.type	_xt_argc,@function
_xt_argc:                               # @_xt_argc
# %bb.0:
	mov	eax, dword ptr [rip + _xt_saved_argc]
	ret
.Lfunc_end9:
	.size	_xt_argc, .Lfunc_end9-_xt_argc
                                        # -- End function
	.globl	_xt_argv                        # -- Begin function _xt_argv
	.p2align	4
	.type	_xt_argv,@function
_xt_argv:                               # @_xt_argv
# %bb.0:
	lea	rax, [rip + .L.str]
	test	edi, edi
	js	.LBB10_3
# %bb.1:
	cmp	edi, dword ptr [rip + _xt_saved_argc]
	setl	dl
	mov	rcx, qword ptr [rip + _xt_saved_argv]
	test	rcx, rcx
	setne	sil
	and	sil, dl
	cmp	sil, 1
	jne	.LBB10_3
# %bb.2:
	mov	eax, edi
	mov	rax, qword ptr [rcx + 8*rax]
.LBB10_3:
	ret
.Lfunc_end10:
	.size	_xt_argv, .Lfunc_end10-_xt_argv
                                        # -- End function
	.globl	_xt_exit                        # -- Begin function _xt_exit
	.p2align	4
	.type	_xt_exit,@function
_xt_exit:                               # @_xt_exit
# %bb.0:
	push	rax
	movsxd	rdi, edi
	call	_sys_exit@PLT
	.p2align	4
.LBB11_1:                               # =>This Inner Loop Header: Depth=1
	jmp	.LBB11_1
.Lfunc_end11:
	.size	_xt_exit, .Lfunc_end11-_xt_exit
                                        # -- End function
	.type	_xt_saved_argc,@object          # @_xt_saved_argc
	.bss
	.globl	_xt_saved_argc
	.p2align	2, 0x0
_xt_saved_argc:
	.long	0                               # 0x0
	.size	_xt_saved_argc, 4

	.type	.L.str,@object                  # @.str
	.section	.rodata.str1.1,"aMS",@progbits,1
.L.str:
	.zero	1
	.size	.L.str, 1

	.type	_xt_saved_argv,@object          # @_xt_saved_argv
	.bss
	.globl	_xt_saved_argv
	.p2align	3, 0x0
_xt_saved_argv:
	.quad	0
	.size	_xt_saved_argv, 8

	.ident	"Homebrew clang version 22.1.3"
	.section	".note.GNU-stack","",@progbits
	.addrsig
