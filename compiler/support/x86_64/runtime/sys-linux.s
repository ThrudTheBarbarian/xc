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
# sys-linux.s — raw Linux syscall stubs for the self-hosted x86-64 target.
#
# Assembly is needed here and nowhere else: everything above these stubs is
# written in xtc (support/x86_64/runtime/rt-linux.xt). The System V call ABI
# passes arguments in rdi, rsi, rdx, rcx, r8, r9 and the Linux syscall ABI in
# rdi, rsi, rdx, r10, r8, r9 — identical for the first three, so a stub with
# three or fewer arguments is just "load the number and go". Only the fourth
# argument needs moving, rcx -> r10, because `syscall` itself clobbers rcx (it
# saves the return address there) along with r11. Both are caller-saved under
# System V, so no stub has to preserve anything.
#
# A negative return is -errno; callers that care check for it.
	.text

	.globl	write
	.type	write, @function
write:					# write(fd, buf, count)
	mov	eax, 1
	syscall
	ret

	.globl	_sys_read
	.type	_sys_read, @function
_sys_read:				# read(fd, buf, count)
	xor	eax, eax
	syscall
	ret

	.globl	_sys_mmap
	.type	_sys_mmap, @function
_sys_mmap:				# mmap(addr, len, prot, flags, fd, off)
	mov	r10, rcx		# 4th arg: syscall ABI wants r10, not rcx
	mov	eax, 9
	syscall
	ret

	.globl	_sys_munmap
	.type	_sys_munmap, @function
_sys_munmap:				# munmap(addr, len)
	mov	eax, 11
	syscall
	ret

	.globl	_sys_clock_gettime
	.type	_sys_clock_gettime, @function
_sys_clock_gettime:			# clock_gettime(clockid, timespec*)
	mov	eax, 228
	syscall
	ret

	.globl	_sys_nanosleep
	.type	_sys_nanosleep, @function
_sys_nanosleep:				# nanosleep(req, rem)
	mov	eax, 35
	syscall
	ret

	# ── files and directories, for rtfiles-linux.s (CI task #81) ──
	.globl	_sys_open
	.type	_sys_open, @function
_sys_open:				# open(path, flags, mode)
	mov	eax, 2
	syscall
	ret

	.globl	_sys_close
	.type	_sys_close, @function
_sys_close:				# close(fd)
	mov	eax, 3
	syscall
	ret

	.globl	_sys_lseek
	.type	_sys_lseek, @function
_sys_lseek:				# lseek(fd, offset, whence)
	mov	eax, 8
	syscall
	ret

	.globl	_sys_mkdir
	.type	_sys_mkdir, @function
_sys_mkdir:				# mkdir(path, mode)
	mov	eax, 83
	syscall
	ret

	.globl	_sys_chmod
	.type	_sys_chmod, @function
_sys_chmod:				# chmod(path, mode)
	mov	eax, 90
	syscall
	ret

	.globl	_sys_exit
	.type	_sys_exit, @function
_sys_exit:				# exit_group(status) — never returns
	mov	eax, 231
	syscall
	hlt

# ── threading (private:docs/Design/threading.md Phase 2) ──

	.globl	_sys_futex
	.type	_sys_futex, @function
_sys_futex:				# futex(uaddr, op, val, timeout, uaddr2, val3)
	mov	r10, rcx
	mov	eax, 202
	syscall
	ret

	.globl	_sys_gettid
	.type	_sys_gettid, @function
_sys_gettid:				# gettid()
	mov	eax, 186
	syscall
	ret

	.globl	_sys_arch_prctl
	.type	_sys_arch_prctl, @function
_sys_arch_prctl:			# arch_prctl(code, addr)
	mov	eax, 158
	syscall
	ret

# The per-thread context pointer, read straight out of the thread register.
#
# `fs` is what makes thread-local storage a LOAD rather than a lookup: the
# kernel sets its base per thread — at clone time via CLONE_SETTLS for a spawned
# thread, and via arch_prctl for the one the process started with — so
# `fs:[0]` is that thread's block and nobody else's, with no key, no table, no
# lock and no syscall. Three instructions, and the reason the tid-keyed table
# this replaced could go.
	.globl	_xt_tcb_get
	.type	_xt_tcb_get, @function
_xt_tcb_get:
	mov	rax, qword ptr fs:[0]
	ret

	.globl	_sys_sched_getaffinity
	.type	_sys_sched_getaffinity, @function
_sys_sched_getaffinity:			# sched_getaffinity(pid, cpusetsize, mask)
	mov	eax, 204
	syscall
	ret

	.globl	_sys_sched_yield
	.type	_sys_sched_yield, @function
_sys_sched_yield:			# sched_yield()
	mov	eax, 24
	syscall
	ret

# _sys_clone_thread(stack_top, flags, tidptr, entry, arg, tls) -> tid, or -errno.
#
# The one stub that is more than "load the number and go", because clone returns
# TWICE: in the parent with the child's tid, and in the child with 0 and a fresh
# stack — where there is no return address to return to, and no C prologue can
# help because the child must not touch the parent's frame.
#
# So the entry and its argument are pushed onto the CHILD's stack first; after
# the syscall the child finds them by popping, calls the body, and then exits
# ITSELF (SYS_exit, 60 — not exit_group, which would take the process down).
#
# `tidptr` is handed to the kernel as BOTH ptid and ctid, which is what makes
# join work without a libc: with CLONE_PARENT_SETTID the kernel writes the tid
# there before clone returns to US, and with CLONE_CHILD_CLEARTID it zeroes the
# same word and futex-wakes it when the thread dies. Passing only ctid (the
# first cut) left the word at its initial zero, so join saw "already exited"
# immediately and returned before the thread had run.
	.globl	_sys_clone_thread
	.type	_sys_clone_thread, @function
_sys_clone_thread:
	# In:  rdi=stack_top  rsi=flags  rdx=tidptr  rcx=entry  r8=arg  r9=tls
	# Out: rdi=flags  rsi=child_stack  rdx=ptid  r10=ctid  r8=tls
	#
	# Six arguments, so ALL of them arrive in registers — `tls` is r9, not a
	# stack slot, and r9 is also the obvious scratch here. Reading it after
	# using it as scratch is how the first cut handed the kernel a garbage
	# thread pointer and every thread died on its first thread-local access.
	sub	rdi, 16			# make room on the child stack
	mov	[rdi], rcx		# [sp+0] = entry
	mov	[rdi+8], r8		# [sp+8] = arg
	mov	r8, r9			# tls (5th) — BEFORE r9 is touched
	mov	r10, rdx		# ctid (4th); rdx stays ptid (3rd)
	mov	rax, rdi		# child stack, out of rdi's way
	mov	rdi, rsi		# flags (1st)
	mov	rsi, rax		# child stack (2nd)
	mov	eax, 56			# SYS_clone
	syscall
	test	rax, rax
	jz	.Lclone_child		# rax == 0 → we are the child
	ret				# parent: tid (or -errno) already in rax
	# A NAMED label, not `1:`: the in-house assembler has no numeric local
	# labels, and this file is assembled by it on the self-hosted path.
.Lclone_child:
	pop	rax			# child: entry
	pop	rdi			# child: arg
	call	rax			# run the thread body
	xor	edi, edi		# body returned → exit THIS thread
	mov	eax, 60			# SYS_exit
	syscall
	hlt

# _xt_getenv — the host primitive PlatformCore.getenv is declared against.
#
# On Linux this IS libc's getenv: same argument, same return, so the wrapper is
# a tail call and musl's member is pulled in by the reference below.
#
# It was missing entirely until 2026-09-01, and nothing noticed because an
# EXECUTABLE that never calls getenv has `PlatformCore.getenv` eliminated
# before the link. A LIBRARY does not: --emit-lib keeps every function it
# defines, so the first .so built here referenced `_xt_getenv`, no x86-64
# definition existed, and the failure landed on whoever LOADED the library
# rather than on whoever built it.
# NULL for "unset" is musl's answer; rt.c's (and PlatformCore's) contract is
# "" — String.withCString(NULL) is a crash, not an empty string — so the
# wrapper is a call, not a tail call.
	.globl	_xt_getenv
_xt_getenv:
	sub	rsp, 8
	call	getenv
	add	rsp, 8
	test	rax, rax
	jnz	.Lgetenv_done
	lea	rax, [rip + .Lgetenv_empty]
.Lgetenv_done:
	ret
.Lgetenv_empty:
	.byte	0
