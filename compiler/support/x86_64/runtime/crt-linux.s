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
# crt-linux.s — process entry for a statically-linked, libc-free x86-64 Linux
# binary produced by the self-hosted toolchain (xtcln-x86_64 + XTElfWriter).
#
# The kernel hands control here with rsp pointing at argc, followed by argv[],
# a NULL, then envp[]. Nothing is set up for us: no libc init, no atexit, no
# stack alignment beyond the initial 16 bytes. We only need argc/argv and a way
# to leave, so this stays small on purpose.
	.text
	.globl	_start
	.type	_start, @function
_start:
	xor	ebp, ebp		# outermost frame: a null rbp ends backtraces
	# Give THIS thread a context block before anything can read one. The
	# kernel sets `fs` for every thread it clones for us (CLONE_SETTLS), but
	# the one the process starts with has fs unset — and `fs:[0]` on an unset
	# base reads linear address zero and dies, rather than reading zero. One
	# arch_prctl at startup means thread-local storage needs no "am I the
	# first thread?" test on any later path.
	#
	# rsp still points at argc here, so the pointer is saved across the call.
	push	rsp
	lea	rsi, [rip + _xt_main_tcb]
	mov	qword ptr [rsi], rsi	# the block's self-pointer, at offset 0
	mov	edi, 0x1002		# ARCH_SET_FS
	mov	eax, 158		# __NR_arch_prctl
	syscall
	pop	rsp

	mov	rdi, [rsp]		# argc
	lea	rsi, [rsp+8]		# argv
	# envp = &argv[argc + 1], and musl's pooled members read it through
	# __environ (getenv.lo — finding #17's second half: the reloc relaxed
	# fine and getenv then answered NULL for everything, because nothing
	# ever told libc where the environment was).
	lea	rdx, [rsi + rdi*8 + 8]
	mov	[rip + __environ], rdx
	# auxv sits one past envp's terminating NULL. musl's mallocng walks
	# libc.auxv DIRECTLY (glue.h get_random_secret reads AT_RANDOM) — it
	# does not go through getauxval — so the field must hold the real
	# vector or the first malloc dies dereferencing NULL, which is what a
	# static libpq link showed. Offset 8 is `size_t *auxv` in musl 1.2.5's
	# struct __libc (internal/libc.h); offset 48 is page_size, set for the
	# sysconf-style readers. The struct itself is defined below.
	mov	rax, rdx
.Lfind_auxv:
	mov	rcx, [rax]
	add	rax, 8
	test	rcx, rcx
	jnz	.Lfind_auxv
	lea	rcx, [rip + __libc]
	mov	[rcx + 8], rax
	mov	qword ptr [rcx + 48], 4096
	# Static local-exec TLS: the linker filled __xt_tls_hdr with [R][image]
	# when any input carried .tdata/.tbss (R = 0 otherwise, and this loop is
	# skipped). The per-thread block sits at [%fs - R, %fs), so copy the
	# image to just below the main tcb; _xt_tcb_alloc does the same for
	# spawned threads. mimalloc's __thread heap pointer is why this exists.
	push	rdi			# argc/argv live here already; the copy
	push	rsi			#   below needs the string registers
	lea	rax, [rip + __xt_tls_hdr]
	mov	rcx, [rax]		# R (0, or 16..240, always 16-aligned)
	test	rcx, rcx
	jz	.Lno_tls
	lea	rsi, [rax + 8]		# image
	lea	rdi, [rip + _xt_main_tcb]
	sub	rdi, rcx
.Ltls_copy:
	mov	al, [rsi]
	mov	[rdi], al
	add	rsi, 1
	add	rdi, 1
	sub	rcx, 1
	jnz	.Ltls_copy
.Lno_tls:
	pop	rsi
	pop	rdi
	lea	rcx, [rip + __libc]
	# The main thread's tcb doubles as musl's struct pthread (fs:[0] is the
	# self pointer both sides expect). Its locale field — byte 168 in musl
	# 1.2.5 — must point at __libc's global_locale (byte 56) before any musl
	# member calls strerror/gettext: __lctrans_cur dereferences it with no
	# null check. Spawned threads get the same store in _xt_thread_create.
	lea	rax, [rip + _xt_main_tcb]
	add	rcx, 56
	mov	[rax + 168], rcx
	# tsd (byte 128) backs pthread_{set,get}specific — mimalloc registers a
	# thread-exit key and musl faults on a NULL array.
	lea	rcx, [rip + _xt_main_tsd]
	mov	[rax + 128], rcx
	# prev (byte 16) / next (byte 24): the main thread must be a circular
	# thread list of one (musl's __init_tp sets self->prev = self->next =
	# self). Left NULL, any code that walks the list — pthread_key_delete's
	# `do td->tsd[k]=0; while ((td=td->next)!=self)`, and pthread_create's
	# list insert — dereferences NULL on the second node. libpq exposed it:
	# OpenSSL registers a key-cleanup via atexit and it faulted at exit.
	mov	[rax + 16], rax
	mov	[rax + 24], rax
	mov	[rip + _xt_saved_argc], edi	# Process.arguments() reads these back
	mov	[rip + _xt_saved_argv], rsi	#   (rtfiles-linux.s, CI task #81)
	and	rsp, -16		# the ABI wants rsp 16-aligned before a call,
	# Load-time constructors (bug 134): the back end lays the module's
	# pointers between __xt_ctors_start and __xt_ctors_end in .data; walk
	# them before main, the way a libc start walks .init_array. argc/argv/envp
	# ride in callee-saved registers across the calls.
	mov	r12, rdi
	mov	r13, rsi
	mov	r14, rdx
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
	call	main			#   so that main sees rsp%16 == 8 on entry
	mov	edi, eax		# main's return value becomes the exit status
	call	exit			# the LIBC exit, not a raw exit_group: musl's
					#   exit(3) runs atexit handlers and then
					#   __stdio_exit, the only thing that flushes
					#   stdio — a raw syscall here lost every byte
					#   still buffered on a piped stdout (task #30).
					#   A link with no libc pool gets `exit` from
					#   exitstub-linux.s, which IS the raw
					#   exit_group(2).
	hlt				# unreachable; faults loudly if exit ever returns

# musl's pooled members reach the environment through __environ (getenv,
# and friends). Defined HERE so a freestanding program that never links the
# libc pool still resolves it: first definition wins, and both writers agree
# on the slot — the startup stores envp, libc reads it. In .data, NOT text:
# the store above faults on a read-only page otherwise.
	.data
	.globl	__environ
	.p2align	3, 0x0
__environ:
	.zero	8
	.size	__environ, 8

# musl's internal state block (struct __libc, internal/libc.h — 104 bytes in
# 1.2.5, reserved with headroom). Defined HERE for the same reason __environ
# is: the startup code above must write auxv into it whether or not the libc
# pool is linked, and first definition wins, so musl's own libc.lo copy steps
# aside and every member reads the one the startup filled in. All-zero is
# exactly the state musl's copy would have, since none of its init runs here.
	.globl	__libc
	.p2align	3, 0x0
__libc:
	.zero	128
	.size	__libc, 128

# Static-TLS header: [0..8) = R, the per-thread block size (16-aligned, <= 240),
# then R bytes of initialisation image. All-zero unless the LINKER installs an
# image into it (xtcln-x86_64, when an input carries .tdata/.tbss) — defined
# HERE like __environ/__libc so a TLS-free link changes nothing and the
# self-hosted linker, which has no archive/TLS support, still links the same
# runtime byte-for-byte.
	.globl	__xt_tls_hdr
	.p2align	4, 0x0
__xt_tls_hdr:
	.zero	248
	.size	__xt_tls_hdr, 248

# The main thread's pthread_setspecific slots (PTHREAD_KEYS_MAX = 128).
	.globl	_xt_main_tsd
	.p2align	3, 0x0
_xt_main_tsd:
	.zero	1024
	.size	_xt_main_tsd, 1024

# Address getters for the generated runtime (rt-freestanding.c): PIC-compiled
# C reaching extern DATA needs a GOT, which the in-house .s path has none of —
# a call is model-neutral.
	.text
	.globl	_xt_libc_addr
	.type	_xt_libc_addr, @function
_xt_libc_addr:
	lea	rax, [rip + __libc]
	ret
	.globl	_xt_tls_hdr_addr
	.type	_xt_tls_hdr_addr, @function
_xt_tls_hdr_addr:
	lea	rax, [rip + __xt_tls_hdr]
	ret
