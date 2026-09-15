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
# crt-win64.s — process entry for a self-hosted x86-64 Windows binary produced by
# xtcln-win64 + XTPEWriter.
#
# Windows hands control here with no arguments in registers: argc/argv are not on
# the stack the way the Linux kernel leaves them, they come from
# GetCommandLineA, parsed once by the runtime (rt-files.c) and handed to main
# as argc/argv (bug 143 — main used to be called with whatever the registers
# held, which read as garbage argc).
#
# Two calling-convention obligations that have no Linux counterpart:
#   * 32 bytes of SHADOW SPACE must be reserved above the return address for any
#     call — the callee may spill its first four register arguments there.
#   * rsp must be 16-aligned at the point of a `call`, i.e. 8 mod 16 on entry to
#     the callee. Windows enters at an aligned rsp, so `sub rsp, 40` (32 shadow +
#     8) restores that after the implicit push of the return address.
	.text

	.globl	_start
_start:
	sub	rsp, 40
	# Load-time constructors (bug 134): the table the back end lays between
	# __xt_ctors_start and __xt_ctors_end in .data, walked before main. The
	# mingw `__attribute__((constructor))` stub that used to do this went with
	# the mingw fallback. rbx and rsi are callee-saved under the Microsoft ABI.
	lea	rbx, [rip + __xt_ctors_start]
	lea	rsi, [rip + __xt_ctors_end]
.Lctors:
	cmp	rbx, rsi
	jae	.Lctors_done
	call	qword ptr [rbx]
	add	rbx, 8
	jmp	.Lctors
.Lctors_done:
	# argc/argv (bug 143): the runtime parses GetCommandLineA once; rdi is
	# callee-saved under the Microsoft ABI, so it carries argc across the
	# second call. main(int argc, char **argv) takes them in ecx and rdx.
	call	_xt_argc
	mov	edi, eax
	call	_xt_argv_table
	mov	rdx, rax
	mov	ecx, edi
	call	main
	mov	ecx, eax		# main's return value becomes the exit status;
	call	ExitProcess		#   arg0 is rcx under the Microsoft ABI
	hlt				# unreachable; faults loudly if ExitProcess returns
