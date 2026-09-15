; crt0.s — Atari ST/TT GEMDOS program entry (canonical reference).
;
; GEMDOS (Pexec) enters a program at the first byte of its TEXT segment
; with 4(sp) = basepage pointer. This stub calls the compiled `main` and
; terminates via Pterm, passing main's return value (in d0) as the
; process exit code.
;
; NOTE: for the bootstrap, XTM68kBackend emits an equivalent _start
; inline at the top of its output (so a standalone .s assembles without a
; separate link step). This file is the canonical source; a later
; milestone wires support-tree linking so the backend stops embedding it.

	.text
	.globl	_start
_start:
	jsr	main			; call user main()
	move.w	d0,-(sp)		; exit code = main() return value
	move.w	#$4c,-(sp)		; GEMDOS Pterm
	trap	#1
	; (does not return)
