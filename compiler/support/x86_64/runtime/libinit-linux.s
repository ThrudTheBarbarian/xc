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
# libinit-linux.s — hands a shared library's load-time constructors to the
# program that loads it. The drivers link it into a library whose module has
# a constructor table (__xt_ctors_start .. __xt_ctors_end); crt-linux.s is the
# other half.
#
# The constructors cannot run from the loader's own init call. That call
# comes before the program's _start, and the runtime they use is set up
# there: musl's malloc reads the auxiliary vector _start stores, and _start
# installs the thread block. So the loader's init call only REGISTERS the
# table: __xt_lib_register appends this library's node to the program's list
# (__xt_lib_ctors, in crt-linux.s), and _start runs every listed table, in
# list order, before the program's own constructors and main. The loader
# initialises a library after the libraries it needs, so the list is in
# dependency order.
#
# The writer points DT_INIT_ARRAY at __xt_init_array_start ..
# __xt_init_array_end. The loader calls the entry with argc, argv and envp;
# they are not used, and only rax, rcx and rdx are written.
	.text
__xt_lib_register:
	mov	rcx, qword ptr [rip + __xt_lib_ctors@GOTPCREL]	# {head, last}
	lea	rax, [rip + __xt_lib_node]
	mov	rdx, qword ptr [rcx + 8]
	test	rdx, rdx
	jz	.Lfirst
	mov	qword ptr [rdx], rax		# last->next = node
	jmp	.Llast
.Lfirst:
	mov	qword ptr [rcx], rax		# head = node
.Llast:
	mov	qword ptr [rcx + 8], rax	# last = node
	ret

	.data
	.p2align	3, 0x0
# {next, table start, table end}
__xt_lib_node:
	.quad	0
	.quad	__xt_ctors_start
	.quad	__xt_ctors_end
__xt_init_array_start:
	.quad	__xt_lib_register
__xt_init_array_end:
