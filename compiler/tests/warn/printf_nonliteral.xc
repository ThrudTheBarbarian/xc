//xtc-warn: Stdio.printf: the format is not a string literal and takes no arguments
//xtc-warn: printf (Stdio.printf via use): the format is not a string literal and takes no arguments
// Text printed AS a format (the security review, 2026-10-21): a format that is
// not a literal, with nothing after it, reads the stack when the text holds a
// `%x` or a `%p`. A literal format, or a built one given its arguments, is not
// reported (printf_nonliteral_ok.xc).
#use Stdio

i32 main(i32 argc, u8** argv)
    {
    u8* text = argv[0];
    Stdio.printf(text);
    printf(text);
    return 0;
    }
