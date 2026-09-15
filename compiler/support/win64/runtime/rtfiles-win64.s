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

	.def	@feat.00;
	.scl	3;
	.type	0;
	.endef
	.globl	@feat.00
@feat.00 = 0
	.intel_syntax noprefix
	.file	"rt-files.c"
	.def	_xt_file_open;
	.scl	2;
	.type	32;
	.endef
	.text
	.globl	_xt_file_open                   # -- Begin function _xt_file_open
	.p2align	4
_xt_file_open:                          # @_xt_file_open
# %bb.0:
	push	rsi
	push	rdi
	sub	rsp, 56
	movzx	eax, byte ptr [rdx]
	mov	esi, -1
	cmp	eax, 97
	je	.LBB0_5
# %bb.1:
	mov	dil, 1
	cmp	eax, 114
	je	.LBB0_2
# %bb.3:
	cmp	eax, 119
	jne	.LBB0_19
# %bb.4:
	mov	r8d, 2
	mov	r9d, 1073741824
	jmp	.LBB0_6
.LBB0_2:
	mov	r8d, 3
	mov	r9d, -2147483648
	jmp	.LBB0_6
.LBB0_5:
	mov	r8d, 4
	mov	r9d, 1073741824
	xor	edi, edi
.LBB0_6:
	movzx	r10d, byte ptr [rdx + 1]
	test	r10d, r10d
	je	.LBB0_9
# %bb.7:
	mov	eax, -1073741824
	cmp	r10d, 43
	je	.LBB0_10
# %bb.8:
	cmp	byte ptr [rdx + 2], 43
	cmove	r9d, eax
.LBB0_9:
	mov	eax, r9d
.LBB0_10:
	mov	dword ptr [rsp + 32], r8d
	mov	qword ptr [rsp + 48], 0
	mov	dword ptr [rsp + 40], 128
	mov	edx, eax
	mov	r8d, 3
	xor	r9d, r9d
	call	CreateFileA
	cmp	rax, -1
	je	.LBB0_19
# %bb.11:
	test	dil, dil
	jne	.LBB0_13
# %bb.12:
	mov	rcx, rax
	xor	edx, edx
	xor	r8d, r8d
	mov	r9d, 2
	mov	rsi, rax
	call	SetFilePointerEx
	mov	rax, rsi
.LBB0_13:
	mov	esi, 3
	xor	ecx, ecx
	lea	rdx, [rip + xt_files]
	.p2align	4
.LBB0_14:                               # =>This Inner Loop Header: Depth=1
	mov	r8, qword ptr [rcx + rdx]
	test	r8, r8
	je	.LBB0_15
# %bb.16:                               #   in Loop: Header=BB0_14 Depth=1
	inc	esi
	add	rcx, 8
	cmp	rcx, 512
	jne	.LBB0_14
# %bb.17:
	test	r8, r8
	je	.LBB0_19
.LBB0_18:
	mov	rcx, rax
	call	CloseHandle
	mov	esi, -1
.LBB0_19:
	mov	eax, esi
	add	rsp, 56
	pop	rdi
	pop	rsi
	ret
.LBB0_15:
	mov	qword ptr [rcx + rdx], rax
	test	r8, r8
	jne	.LBB0_18
	jmp	.LBB0_19
                                        # -- End function
	.def	_xt_file_read;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_file_read                   # -- Begin function _xt_file_read
	.p2align	4
_xt_file_read:                          # @_xt_file_read
# %bb.0:
	sub	rsp, 56
                                        # kill: def $ecx killed $ecx def $rcx
	lea	eax, [rcx - 67]
	cmp	eax, -64
	jae	.LBB1_2
# %bb.1:
	xor	ecx, ecx
	jmp	.LBB1_3
.LBB1_2:
	mov	eax, ecx
	lea	rcx, [rip + xt_files]
	mov	rcx, qword ptr [rcx + 8*rax - 24]
.LBB1_3:
	mov	dword ptr [rsp + 52], 0
	test	rcx, rcx
	je	.LBB1_4
# %bb.5:
	mov	qword ptr [rsp + 32], 0
	lea	r9, [rsp + 52]
	call	ReadFile
	mov	ecx, eax
	xor	eax, eax
	cmp	ecx, 1
	sbb	eax, eax
	or	eax, dword ptr [rsp + 52]
	add	rsp, 56
	ret
.LBB1_4:
	mov	eax, -1
	add	rsp, 56
	ret
                                        # -- End function
	.def	_xt_file_write;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_file_write                  # -- Begin function _xt_file_write
	.p2align	4
_xt_file_write:                         # @_xt_file_write
# %bb.0:
	sub	rsp, 56
                                        # kill: def $ecx killed $ecx def $rcx
	lea	eax, [rcx - 67]
	cmp	eax, -64
	jae	.LBB2_2
# %bb.1:
	xor	ecx, ecx
	jmp	.LBB2_3
.LBB2_2:
	mov	eax, ecx
	lea	rcx, [rip + xt_files]
	mov	rcx, qword ptr [rcx + 8*rax - 24]
.LBB2_3:
	mov	dword ptr [rsp + 52], 0
	test	rcx, rcx
	je	.LBB2_4
# %bb.5:
	mov	qword ptr [rsp + 32], 0
	lea	r9, [rsp + 52]
	call	WriteFile
	mov	ecx, eax
	xor	eax, eax
	cmp	ecx, 1
	sbb	eax, eax
	or	eax, dword ptr [rsp + 52]
	add	rsp, 56
	ret
.LBB2_4:
	mov	eax, -1
	add	rsp, 56
	ret
                                        # -- End function
	.def	_xt_file_close;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_file_close                  # -- Begin function _xt_file_close
	.p2align	4
_xt_file_close:                         # @_xt_file_close
# %bb.0:
	push	rsi
	sub	rsp, 32
	mov	esi, ecx
	lea	eax, [rsi - 67]
	cmp	eax, -64
	jae	.LBB3_2
# %bb.1:
	xor	ecx, ecx
	test	rcx, rcx
	jne	.LBB3_4
	jmp	.LBB3_5
.LBB3_2:
	mov	eax, esi
	lea	rcx, [rip + xt_files]
	mov	rcx, qword ptr [rcx + 8*rax - 24]
	test	rcx, rcx
	je	.LBB3_5
.LBB3_4:
	call	CloseHandle
	movsxd	rax, esi
	lea	rcx, [rip + xt_files]
	mov	qword ptr [rcx + 8*rax - 24], 0
.LBB3_5:
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xt_file_size;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_file_size                   # -- Begin function _xt_file_size
	.p2align	4
_xt_file_size:                          # @_xt_file_size
# %bb.0:
	push	rsi
	sub	rsp, 64
	mov	qword ptr [rsp + 48], 0
	mov	dword ptr [rsp + 40], 128
	mov	dword ptr [rsp + 32], 3
	mov	edx, -2147483648
	mov	r8d, 3
	xor	r9d, r9d
	call	CreateFileA
	cmp	rax, -1
	je	.LBB4_1
# %bb.2:
	mov	rsi, rax
	mov	qword ptr [rsp + 56], -1
	lea	rdx, [rsp + 56]
	mov	rcx, rax
	call	GetFileSizeEx
	test	eax, eax
	jne	.LBB4_4
# %bb.3:
	mov	qword ptr [rsp + 56], -1
.LBB4_4:
	mov	rcx, rsi
	call	CloseHandle
	mov	rcx, qword ptr [rsp + 56]
	cmp	rcx, 2147483647
	mov	eax, -1
	cmovbe	eax, ecx
	jmp	.LBB4_5
.LBB4_1:
	mov	eax, -1
.LBB4_5:
	add	rsp, 64
	pop	rsi
	ret
                                        # -- End function
	.def	_xt_file_exists;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_file_exists                 # -- Begin function _xt_file_exists
	.p2align	4
_xt_file_exists:                        # @_xt_file_exists
# %bb.0:
	sub	rsp, 40
	call	GetFileAttributesA
	xor	ecx, ecx
	cmp	eax, -1
	setne	cl
	mov	eax, ecx
	add	rsp, 40
	ret
                                        # -- End function
	.def	_xt_file_exists_exact;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_file_exists_exact           # -- Begin function _xt_file_exists_exact
	.p2align	4
_xt_file_exists_exact:                  # @_xt_file_exists_exact
# %bb.0:
	sub	rsp, 40
	call	GetFileAttributesA
	xor	ecx, ecx
	cmp	eax, -1
	setne	cl
	mov	eax, ecx
	add	rsp, 40
	ret
                                        # -- End function
	.def	_xt_file_chmod_exec;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_file_chmod_exec             # -- Begin function _xt_file_chmod_exec
	.p2align	4
_xt_file_chmod_exec:                    # @_xt_file_chmod_exec
# %bb.0:
	xor	eax, eax
	ret
                                        # -- End function
	.def	_xt_mkdir;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_mkdir                       # -- Begin function _xt_mkdir
	.p2align	4
_xt_mkdir:                              # @_xt_mkdir
# %bb.0:
	push	rsi
	sub	rsp, 32
	xor	esi, esi
	xor	edx, edx
	call	CreateDirectoryA
	cmp	eax, 1
	sbb	esi, esi
	mov	eax, esi
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xt_argc;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_argc                        # -- Begin function _xt_argc
	.p2align	4
_xt_argc:                               # @_xt_argc
# %bb.0:
	sub	rsp, 40
	call	xt_parse_args
	mov	eax, dword ptr [rip + xt_argc_v]
	add	rsp, 40
	ret
                                        # -- End function
	.def	xt_parse_args;
	.scl	3;
	.type	32;
	.endef
	.p2align	4                               # -- Begin function xt_parse_args
xt_parse_args:                          # @xt_parse_args
# %bb.0:
	push	rsi
	push	rdi
	sub	rsp, 40
	cmp	dword ptr [rip + xt_argc_v], 0
	jns	.LBB10_30
# %bb.1:
	call	GetCommandLineA
	cmp	byte ptr [rax], 0
	je	.LBB10_28
# %bb.2:
	xor	r8d, r8d
	lea	rcx, [rip + xt_cmd]
	lea	rdx, [rip + xt_argv_v]
	xor	r9d, r9d
	jmp	.LBB10_4
	.p2align	4
.LBB10_3:                               #   in Loop: Header=BB10_4 Depth=1
	inc	rax
.LBB10_4:                               # =>This Loop Header: Depth=1
                                        #     Child Loop BB10_9 Depth 2
                                        #       Child Loop BB10_11 Depth 3
	movzx	r10d, byte ptr [rax]
	cmp	r10d, 9
	je	.LBB10_3
# %bb.5:                                #   in Loop: Header=BB10_4 Depth=1
	cmp	r10d, 32
	je	.LBB10_3
# %bb.6:                                #   in Loop: Header=BB10_4 Depth=1
	test	r10d, r10d
	je	.LBB10_27
# %bb.7:                                #   in Loop: Header=BB10_4 Depth=1
	movsxd	r10, r9d
	add	r10, rcx
	mov	qword ptr [rdx + 8*r8], r10
	movzx	r10d, byte ptr [rax]
	test	r10b, r10b
	je	.LBB10_21
# %bb.8:                                #   in Loop: Header=BB10_4 Depth=1
	xor	r11d, r11d
.LBB10_9:                               #   Parent Loop BB10_4 Depth=1
                                        # =>  This Loop Header: Depth=2
                                        #       Child Loop BB10_11 Depth 3
	mov	rsi, rax
	inc	rax
	jmp	.LBB10_11
	.p2align	4
.LBB10_10:                              #   in Loop: Header=BB10_11 Depth=3
	xor	r11d, 1
	inc	rsi
	movzx	r10d, byte ptr [rax]
	inc	rax
	test	r10b, r10b
	je	.LBB10_20
.LBB10_11:                              #   Parent Loop BB10_4 Depth=1
                                        #     Parent Loop BB10_9 Depth=2
                                        # =>    This Inner Loop Header: Depth=3
	test	r11d, r11d
	je	.LBB10_14
# %bb.12:                               #   in Loop: Header=BB10_11 Depth=3
	cmp	r9d, 4094
	jg	.LBB10_20
# %bb.13:                               #   in Loop: Header=BB10_11 Depth=3
	cmp	r10b, 34
	je	.LBB10_10
	jmp	.LBB10_18
	.p2align	4
.LBB10_14:                              #   in Loop: Header=BB10_11 Depth=3
	cmp	r9d, 4094
	jg	.LBB10_24
# %bb.15:                               #   in Loop: Header=BB10_11 Depth=3
	cmp	r10b, 34
	je	.LBB10_10
# %bb.16:                               #   in Loop: Header=BB10_9 Depth=2
	movzx	edi, r10b
	cmp	edi, 9
	je	.LBB10_24
# %bb.17:                               #   in Loop: Header=BB10_9 Depth=2
	xor	r11d, r11d
	cmp	edi, 32
	je	.LBB10_24
	jmp	.LBB10_19
.LBB10_18:                              #   in Loop: Header=BB10_9 Depth=2
	mov	r11d, 1
.LBB10_19:                              #   in Loop: Header=BB10_9 Depth=2
	movsxd	rsi, r9d
	inc	r9d
	mov	byte ptr [rsi + rcx], r10b
	movzx	r10d, byte ptr [rax]
	test	r10b, r10b
	jne	.LBB10_9
	jmp	.LBB10_21
.LBB10_20:                              #   in Loop: Header=BB10_4 Depth=1
	dec	rax
	jmp	.LBB10_21
.LBB10_24:                              #   in Loop: Header=BB10_4 Depth=1
	mov	rax, rsi
.LBB10_21:                              #   in Loop: Header=BB10_4 Depth=1
	lea	r10, [r8 + 1]
	movsxd	r11, r9d
	mov	byte ptr [r11 + rcx], 0
	cmp	byte ptr [rax], 0
	je	.LBB10_29
# %bb.22:                               #   in Loop: Header=BB10_4 Depth=1
	cmp	r8, 62
	ja	.LBB10_29
# %bb.23:                               #   in Loop: Header=BB10_4 Depth=1
	inc	r9d
	mov	r8, r10
	cmp	r9d, 4095
	jl	.LBB10_4
	jmp	.LBB10_29
.LBB10_27:
	mov	r10d, r8d
	jmp	.LBB10_29
.LBB10_28:
	xor	r10d, r10d
.LBB10_29:
	mov	dword ptr [rip + xt_argc_v], r10d
.LBB10_30:
	add	rsp, 40
	pop	rdi
	pop	rsi
	ret
                                        # -- End function
	.def	_xt_argv;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_argv                        # -- Begin function _xt_argv
	.p2align	4
_xt_argv:                               # @_xt_argv
# %bb.0:
	push	rsi
	sub	rsp, 32
	mov	esi, ecx
	call	xt_parse_args
	lea	rax, [rip + .L.str]
	test	esi, esi
	js	.LBB11_3
# %bb.1:
	cmp	esi, dword ptr [rip + xt_argc_v]
	jge	.LBB11_3
# %bb.2:
	mov	eax, esi
	lea	rcx, [rip + xt_argv_v]
	mov	rax, qword ptr [rcx + 8*rax]
.LBB11_3:
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.def	_xt_argv_table;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_argv_table                  # -- Begin function _xt_argv_table
	.p2align	4
_xt_argv_table:                         # @_xt_argv_table
# %bb.0:
	sub	rsp, 40
	call	xt_parse_args
	lea	rax, [rip + xt_argv_v]
	add	rsp, 40
	ret
                                        # -- End function
	.def	_xt_exit;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_exit                        # -- Begin function _xt_exit
	.p2align	4
_xt_exit:                               # @_xt_exit
# %bb.0:
	sub	rsp, 40
	call	ExitProcess
	.p2align	4
.LBB13_1:                               # =>This Inner Loop Header: Depth=1
	jmp	.LBB13_1
                                        # -- End function
	.def	_xt_getenv;
	.scl	2;
	.type	32;
	.endef
	.globl	_xt_getenv                      # -- Begin function _xt_getenv
	.p2align	4
_xt_getenv:                             # @_xt_getenv
# %bb.0:
	push	rsi
	sub	rsp, 32
	lea	rsi, [rip + xt_env]
	mov	rdx, rsi
	mov	r8d, 4096
	call	GetEnvironmentVariableA
	add	eax, -4096
	cmp	eax, -4095
	lea	rax, [rip + .L.str]
	cmovae	rax, rsi
	add	rsp, 32
	pop	rsi
	ret
                                        # -- End function
	.lcomm	xt_files,512,16                 # @xt_files
	.data
	.p2align	2, 0x0                          # @xt_argc_v
xt_argc_v:
	.long	4294967295                      # 0xffffffff

	.section	.rdata,"dr"
.L.str:                                 # @.str
	.zero	1

	.lcomm	xt_argv_v,512,16                # @xt_argv_v
	.lcomm	xt_env,4096,16                  # @xt_env
	.lcomm	xt_cmd,4096,16                  # @xt_cmd
	.section	.debug$S,"dr"
	.p2align	2, 0x0
	.long	4                               # Debug section magic
	.long	241
	.long	.Ltmp1-.Ltmp0                   # Subsection size
.Ltmp0:
	.short	.Ltmp3-.Ltmp2                   # Record length
.Ltmp2:
	.short	4353                            # Record kind: S_OBJNAME
	.long	0                               # Signature
	.byte	0                               # Object name
	.p2align	2, 0x0
.Ltmp3:
	.short	.Ltmp5-.Ltmp4                   # Record length
.Ltmp4:
	.short	4412                            # Record kind: S_COMPILE3
	.long	0                               # Flags and language
	.short	208                             # CPUType
	.short	22                              # Frontend version
	.short	1
	.short	3
	.short	0
	.short	22013                           # Backend version
	.short	0
	.short	0
	.short	0
	.asciz	"Homebrew clang version 22.1.3" # Null-terminated compiler version string
	.p2align	2, 0x0
.Ltmp5:
.Ltmp1:
	.p2align	2, 0x0
	.addrsig
	.addrsig_sym xt_argv_v
	.addrsig_sym xt_env
	.addrsig_sym xt_cmd
