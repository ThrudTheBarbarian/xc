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
# exitstub-linux.s — `exit` for an x86-64 link that carries NO libc pool.
#
# crt-linux.s leaves the process through `call exit` so that a link with musl
# in it runs the real exit(3): atexit handlers, then __stdio_exit — the only
# thing that flushes stdio's buffers. A raw exit_group there lost every byte
# still buffered on a piped stdout (task #30). When the driver finds no libc.a
# to pool (freestanding static, or the dynamic-PIE link, whose libraries are
# our own .so files), it appends THIS file instead: nothing in such a program
# buffers, so exit_group(2) is the whole job.
#
# Never link this alongside the musl pool — a second definition of `exit`
# would keep the archive member from being pulled, and the flush with it.
	.text
	.globl	exit
	.type	exit, @function
exit:
	mov	eax, 231		# __NR_exit_group — ends every thread;
	syscall				#   edi already holds the exit status
	hlt				# unreachable
