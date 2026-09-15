// preproc_paste.xc — the `##` token-paste and `#` stringize operators, and
// the token-boundary discipline that has to hold for them to mean anything.
//
// `##` was simply not recognised — the `#` characters survived into the token
// stream and the parser choked. But the deeper bug was underneath it:
// parameter substitution was a raw TEXTUAL replace of the parameter name over
// the macro body, with no token boundaries at all. So
//
//     #define ABS_OK(a)  a + abs_val
//
// substituted the argument inside `abs_val` and produced `<arg>bs_v<arg>l`.
// That one at least fails loudly. Substitution inside a STRING LITERAL did not:
//
//     #define INSTR(a)   "a is here"     →  INSTR(zz)  gave  "zz is here"
//
// Test surface:
//   T1  ##            two-level CAT: arguments expand, then paste
//   T2  #             stringize the EXPANDED argument (via a second level)
//   T3  #             stringize the RAW argument (one level — no expansion)
//   T4  boundaries    a param must not be substituted inside a longer identifier
//   T5  boundaries    a param must not be substituted inside a string literal
//   T6  ##            pasting in an OBJECT-like macro body
//   T7  , ## __VA_ARGS__   empty variadic tail swallows the comma
//   T8  args          a comma inside a string argument does not split the call

#import "Stdio.xc"

#define CAT2(a,b)   a##b
#define CAT(a,b)    CAT2(a,b)
#define VER         7

#define STR2(x)     #x
#define STR(x)      STR2(x)

#define ABS_OK(a)   a + abs_val
#define INSTR(a)    "a is here"

#define OBJPASTE    CAT2(x, 7)

#define LOG(fmt, ...)  Stdio.printf(fmt, ##__VA_ARGS__)

#define TAKES(s, n)    Stdio.printf(s, n)

u16 x7      = (u16)55;
u16 abs_val = (u16)3;

i16 main(void)
{
    // T1: CAT expands its args (VER → 7), then CAT2 pastes → x7.
    Stdio.printf("%d\n", CAT(x, VER));

    // T2 / T3: the # operand is the RAW argument, so only a second level
    // (which expands first) yields "7". One level must yield "VER".
    Stdio.printf("%s\n", STR(VER));
    Stdio.printf("%s\n", STR2(VER));

    // T4: `a` must not be substituted inside `abs_val`.
    Stdio.printf("%d\n", ABS_OK((u16)1));

    // T5: `a` must not be substituted inside the string literal.
    Stdio.printf("%s\n", INSTR(zz));

    // T6: an object-like macro whose body pastes.
    Stdio.printf("%d\n", OBJPASTE);

    // T7: no variadic arguments — the comma before __VA_ARGS__ is swallowed.
    LOG("novarargs\n");
    LOG("%d\n", (u16)222);

    // T8: the comma inside the string argument is not an argument separator.
    TAKES("a,b=%d\n", (u16)9);

    return 0;
}
