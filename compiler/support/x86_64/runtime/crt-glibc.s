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
# crt-glibc.s — process entry for `-A x86_64 -dynamic` (a dynamically linked
# glibc executable). Hand-written; the musl twin is crt-linux.s.
#
# Under glibc, ld.so has already set up %fs, TLS, the environment and libc by
# the time _start runs, so this does NONE of what crt-linux.s does to a musl
# image. It hands the process to __libc_start_main exactly as glibc's own
# Scrt1.o does, with _xt_glibc_main standing in for `main`: that saves argc/argv
# for Process.arguments(), runs the load-time constructor lists, and calls the
# program's main. Its return value goes back to glibc, whose exit() runs atexit
# handlers and flushes C stdio — which matters once GTK or libGL share the
# process.
	.intel_syntax noprefix
	.text
	.globl	_start
	.type	_start, @function
_start:
	xor	ebp, ebp		# the outermost frame, for unwinders
	mov	r9, rdx			# rtld_fini, from ld.so
	pop	rsi			# argc
	mov	rdx, rsp		# argv
	and	rsp, -16
	push	rax			# keep rsp 16-aligned across the next push
	push	rsp			# stack_end
	xor	r8d, r8d		# fini: none (glibc runs DT_FINI_ARRAY itself)
	xor	ecx, ecx		# init: none
	lea	rdi, [rip + _xt_glibc_main]
	call	__libc_start_main	# does not return
	hlt

	.type	_xt_glibc_main, @function
_xt_glibc_main:				# (argc, argv, envp), called by glibc
	push	rbx			# entered with rsp%16 == 8; five pushes
	push	r12			#   leave it 16-aligned for the calls below
	push	r13
	push	r14
	push	r15
	mov	[rip + _xt_saved_argc], edi	# Process.arguments() reads these back
	mov	[rip + _xt_saved_argv], rsi	#   (rtfiles-linux.s)
	mov	r12, rdi
	mov	r13, rsi
	mov	r14, rdx
	# Shared libraries' constructor tables first (libinit-linux.s appends a
	# {next, start, end} node per library), then the program's own, which the
	# back end lays between __xt_ctors_start and __xt_ctors_end.
	mov	rbx, [rip + __xt_lib_ctors]
.Llibs:
	test	rbx, rbx
	jz	.Llibs_done
	push	rbx
	push	rbx			# two pushes keep rsp 16-aligned
	mov	r15, [rbx + 16]
	mov	rbx, [rbx + 8]
.Llib_ctors:
	cmp	rbx, r15
	jae	.Llib_done
	call	qword ptr [rbx]
	add	rbx, 8
	jmp	.Llib_ctors
.Llib_done:
	pop	rbx
	pop	rbx
	mov	rbx, [rbx]		# next
	jmp	.Llibs
.Llibs_done:
	lea	rbx, [rip + __xt_ctors_start]
	lea	r15, [rip + __xt_ctors_end]
.Lctors:
	cmp	rbx, r15
	jae	.Lctors_done
	call	qword ptr [rbx]
	add	rbx, 8
	jmp	.Lctors
.Lctors_done:
	mov	rdi, r12
	mov	rsi, r13
	mov	rdx, r14
	call	main
	pop	r15
	pop	r14
	pop	r13
	pop	r12
	pop	rbx
	ret				# to __libc_start_main, which calls exit(eax)

	.data
	.p2align 3
# The list head libinit-linux.s links each xc-built library's table into.
	.globl	__xt_lib_ctors
__xt_lib_ctors:
	.quad	0
