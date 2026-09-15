	.intel_syntax noprefix
# ldx86-rt-shim.s — HARNESS-ONLY calloc/free for ldx86-diff.
#
# The real link satisfies the runtime's calloc/free from the musl archive
# pool (the heap delegates to libc so a whole-image override like mimalloc
# owns every allocation). The self-hosted linker under test links .s only —
# no archive reader — so the differential supplies this two-function stand-in
# to BOTH linkers instead: a page-granular mmap bump with a no-op free.
# Byte-identical input on both sides keeps the comparison exact; nothing
# outside the harness ever links this file.
	.text
	.globl	calloc
	.type	calloc, @function
calloc:					# calloc(n, size) -> zeroed memory
	mov	rax, rdi
	mul	rsi			# rax = n*size (harness sizes are tiny)
	add	rax, 4095
	and	rax, -4096
	mov	rsi, rax		# length
	xor	edi, edi		# addr = NULL
	mov	edx, 3			# PROT_READ|PROT_WRITE
	mov	r10d, 0x22		# MAP_PRIVATE|MAP_ANONYMOUS
	mov	r8, -1
	xor	r9d, r9d
	mov	eax, 9			# __NR_mmap
	syscall
	cmp	rax, -4095
	jae	.Lcalloc_fail		# errno range: report NULL
	ret
.Lcalloc_fail:
	xor	eax, eax
	ret

	.globl	free
	.type	free, @function
free:					# free(p): the harness never reuses, so a
	ret				#   no-op is honest here

	.globl	exit
	.type	exit, @function
exit:					# exit(code): straight to exit_group.
	mov	edi, edi		#   musl's exit(3) runs atexit handlers and
	mov	eax, 231		#   flushes stdio; nothing the harness links
	syscall				#   registers either, so the syscall is the
	hlt				#   whole of it.

	.globl	isatty
	.type	isatty, @function
isatty:					# isatty(fd) -> 0
	xor	eax, eax		# Log.xc probes this to decide on colour.
	ret				#   Output here goes to a file, so "no" is
					#   both the truthful answer and the one
					#   that keeps the compared bytes stable.

# getenv, for the same reason. The runtime's `_xt_getenv` tail-calls it
# (private:docs/bugs/101) and a real link takes it from the musl pool; this link has
# no pool, so without a stand-in EVERY file in the sweep failed to link and
# the harness reported BROKEN — 0 compared, 890 skipped. Returning NULL is
# the honest answer here: the harness compares two linkers' OUTPUT and never
# runs the image, so what the environment says is not information it uses.
	.globl	getenv
	.type	getenv, @function
getenv:
	xor	eax, eax
	ret
