// comments.s — both comment spellings, and neither one inside a string.
//
// The in-house assembler took `@` only, so every arm9 self-host link died on
// the first line of the runtime's licence header with
// `unsupported ARM assembly: //`. The other six files here are written in the
// `@` style, so the oracle agreed with us on all of them and the gap stayed
// green. This file is the one that would have caught it.
//
// `;` is deliberately absent: on ARM32 it SEPARATES statements rather than
// starting a comment, so an assembler that cut there would drop real code.

        .text
        .global comments
        .type   comments, %function
comments:
        mov     r0, #1          // a trailing slash comment
        mov     r1, #2          @ a trailing at comment
// a whole-line slash comment
@ a whole-line at comment
        add     r0, r0, r1
        bx      lr
        .size   comments, .-comments

        .data
// A comment marker inside a string is data, not a comment: the oracle keeps
// both of these whole, so the assembler must respect quotes when it cuts.
slashes:
        .asciz  "http://example/x"
atsign:
        .asciz  "user@host"
