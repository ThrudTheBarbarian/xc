; ijsr.asm — indirect JSR trampoline for function-pointer calls.
;
; The standard 6502 has no `JSR (addr)` instruction — only `JMP (addr)`.
; Call sites that invoke a function through a pointer can't jump
; directly; they set up the target in a fixed ZP pair and JSR here.
;
; Calling convention:
;   Caller: LDA <fp>   : STA _xtc_ijsr_target
;           LDA <fp>+1 : STA _xtc_ijsr_target+1
;           JSR _xtc_ijsr
;   Target: runs normally, eventually RTS
;   Return: the target's RTS pops the caller's JSR-return, so control
;           resumes at the instruction after `JSR _xtc_ijsr` — same as
;           a direct call.
;
; The target pair lives in ZP ($00BE-$00BF) so `JMP ($00BE)` is entirely
; within page 0 and sidesteps the 6502 JMP-indirect page-boundary bug
; (which fires when the low byte is $FF — reads high from $XX00, not
; $XY00). ZP is 256 bytes and can't cross a page.
;
; $BE-$BF is part of the $B0-$BF runtime-params region. fp2Asc /
; dp2Asc stage inputs at $B0-$B9 and stage output pointers at
; $B5-$B6 / $B8-$B9; $BE-$BF stays untouched by every current runtime
; routine, so reusing it for the indirect-call target has no conflict.

_xtc_ijsr_target = $BE

_xtc_ijsr:
    JMP (_xtc_ijsr_target)
