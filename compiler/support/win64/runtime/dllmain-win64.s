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
# dllmain-win64.s — the entry point of a DLL built by `xcc -A win64 --emit-lib`.
# It takes the place crt-win64.s has in a program: a DLL has no main, and the
# loader calls this with (hinstDLL, reason, reserved) in rcx, edx and r8.
#
# On DLL_PROCESS_ATTACH (reason 1) it runs the library's load-time
# constructors, the table the back end lays between __xt_ctors_start and
# __xt_ctors_end. Unlike an ELF library it can run them here rather than hand
# them to the program: the runtime needs nothing the program sets up (the heap
# is kernel32's process heap), and the loader initialises a DLL after the DLLs
# it imports, so the constructors run in dependency order, before the
# program's own. Every other reason is a no-op. The return value is TRUE:
# returning FALSE from an attach would make the load fail.
#
# The label is not .globl, so the DLL does not export it.
	.text
_xt_dll_main:
	cmp	edx, 1
	jne	.Ldll_ret
	push	rbx
	push	rsi
	sub	rsp, 40			# 32 shadow + 8: rsp is 16-aligned at each call
	lea	rbx, [rip + __xt_ctors_start]
	lea	rsi, [rip + __xt_ctors_end]
.Ldll_ctors:
	cmp	rbx, rsi
	jae	.Ldll_done
	call	qword ptr [rbx]
	add	rbx, 8
	jmp	.Ldll_ctors
.Ldll_done:
	add	rsp, 40
	pop	rsi
	pop	rbx
.Ldll_ret:
	mov	eax, 1
	ret
