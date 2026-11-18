// printf_at_unformatted.xc — `%@` that is not in a format. In this comment, a
// `%@` would print an object's description; below, it sits in a string that
// is printed through `%s` and never read as a format. Neither turns on the
// `%@` support in Stdio (HAS_ATFMT), which follows the formats the program
// passes to the printf family (tests/driver/runtime-switches.sh checks the
// assembly).
#import "Stdio.xc"

i32 main(void)
    {
    string s = "100%@ text";
    Stdio.printf("%d %s\n", (i32)42, s);
    return 0;
    }
