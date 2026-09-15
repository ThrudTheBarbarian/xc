// comments.xc — exercises the lexer's comment handling. The body is
// deliberately portable (no Atari hardware pokes): the point is that
// line, trailing, and block comments all lex away cleanly on every
// target, leaving valid code behind that still computes a real result.
#import "Stdio.xc"

void main(void)
{
    // A distinctive seed value
    u8 color = $5A;   // 90 decimal (trailing comment)

    /* A block comment
       spanning several lines
       must be skipped entirely. */
    u8 next = color + (u8)$28;   // $5A + $28 = $82 (130)

    // print the surviving result to prove the comments lexed away
    Stdio.printf("%d\n", (u16)next);
}
