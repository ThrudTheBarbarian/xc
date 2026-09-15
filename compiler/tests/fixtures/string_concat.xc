// string_concat.xc — adjacent string literals concatenate, as in C.
//
// `"ab" "cd"` is `"abcd"`, and a newline between the pieces makes no
// difference. Done in the PARSER rather than the lexer, so the token stream is
// unchanged and lexer-diff still compares the same thing.
//
// It earns its keep on long diagnostic strings: without it a message is one
// unbreakable source line as wide as the message itself.
#import "Foundation.xc"
#import "Stdio.xc"

i32 main(void)
{
    Stdio.print("one" "two\n");
    Stdio.print("split across "
                "a newline, "
                "three pieces\n");
    // Through a variable, and inside a call's argument list.
    string s = "held" " in" " a variable\n";
    Stdio.print(s);
    Stdio.printf("%s|%d\n", "fmt" "joined", (u16)7);
    // Escapes still work across a join. (No tab here: the xt6502 console
    // renders one differently from a host stdout, and the point being made is
    // the join, not the escape.)
    Stdio.print("esc:\\" "|end\n");
    return 0;
}
