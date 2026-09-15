// test_regex.xc — UXRegex: parse -> bytecode -> backtracking VM.
#import <Stdio.xc>
#import "UXRegex.xc"

i32 gFails;
void expect(u8* pat, u8* s, i32 wantMatch, i32 wantTest)
    {
    UXRegex* re = UXRegex.compile(pat);
    i32 m = re.matches(s) ? (i32)1 : (i32)0;
    i32 t = re.test(s) ? (i32)1 : (i32)0;
    bool good = (m == wantMatch && t == wantTest);
    if (good)
        {
        Stdio.printf("  ok   /%s/ ~ \"%s\"  match=%d test=%d\n", pat, s, (i16)m, (i16)t);
        }
    else
        {
        Stdio.printf("  FAIL /%s/ ~ \"%s\"  match=%d(want %d) test=%d(want %d)\n",
                     pat, s, (i16)m, (i16)wantMatch, (i16)t, (i16)wantTest);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;

    // literals
    expect((u8*)"abc", (u8*)"abc", (i32)1, (i32)1);
    expect((u8*)"abc", (u8*)"abcd", (i32)0, (i32)1); // not a full match, but occurs
    expect((u8*)"abc", (u8*)"xabcx", (i32)0, (i32)1);
    expect((u8*)"abc", (u8*)"abx", (i32)0, (i32)0);

    // '.' any
    expect((u8*)"a.c", (u8*)"axc", (i32)1, (i32)1);
    expect((u8*)"a.c", (u8*)"ac", (i32)0, (i32)0);

    // quantifiers
    expect((u8*)"ab*c", (u8*)"ac", (i32)1, (i32)1); // zero b's
    expect((u8*)"ab*c", (u8*)"abbbc", (i32)1, (i32)1);
    expect((u8*)"ab+c", (u8*)"ac", (i32)0, (i32)0); // needs >=1 b
    expect((u8*)"ab+c", (u8*)"abc", (i32)1, (i32)1);
    expect((u8*)"ab?c", (u8*)"ac", (i32)1, (i32)1);
    expect((u8*)"ab?c", (u8*)"abc", (i32)1, (i32)1);
    expect((u8*)"a*", (u8*)"aaaa", (i32)1, (i32)1); // greedy consumes all
    expect((u8*)"a*", (u8*)"", (i32)1, (i32)1);

    // classes
    expect((u8*)"[abc]+", (u8*)"cabba", (i32)1, (i32)1);
    expect((u8*)"[a-z]+", (u8*)"hello", (i32)1, (i32)1);
    expect((u8*)"[a-z]+", (u8*)"Hello", (i32)0, (i32)1); // full-match fails on 'H', but "ello" occurs
    expect((u8*)"[^0-9]+", (u8*)"abc", (i32)1, (i32)1);
    expect((u8*)"[^0-9]+", (u8*)"12", (i32)0, (i32)0);

    // predefined classes
    expect((u8*)"\\d+", (u8*)"2026", (i32)1, (i32)1);
    expect((u8*)"\\d+", (u8*)"nope", (i32)0, (i32)0);
    expect((u8*)"\\w+", (u8*)"a_1", (i32)1, (i32)1);
    expect((u8*)"\\s", (u8*)"a b", (i32)0, (i32)1); // a space occurs

    // anchors
    expect((u8*)"^abc$", (u8*)"abc", (i32)1, (i32)1);
    expect((u8*)"^\\d+$", (u8*)"123", (i32)1, (i32)1);
    expect((u8*)"^\\d+$", (u8*)"12a", (i32)0, (i32)0);

    // alternation + groups
    expect((u8*)"cat|dog", (u8*)"dog", (i32)1, (i32)1);
    expect((u8*)"cat|dog", (u8*)"cow", (i32)0, (i32)0);
    expect((u8*)"gr(a|e)y", (u8*)"grey", (i32)1, (i32)1);
    expect((u8*)"gr(a|e)y", (u8*)"gray", (i32)1, (i32)1);
    expect((u8*)"gr(a|e)y", (u8*)"groy", (i32)0, (i32)0);
    expect((u8*)"(ab)+", (u8*)"ababab", (i32)1, (i32)1);
    expect((u8*)"(ab)+", (u8*)"aba", (i32)0, (i32)1); // "abab" needed for full; "ab" occurs

    // a realistic one: a simple identifier, and a date-ish shape
    expect((u8*)"^[a-zA-Z_]\\w*$", (u8*)"foo_bar9", (i32)1, (i32)1);
    expect((u8*)"^[a-zA-Z_]\\w*$", (u8*)"9foo", (i32)0, (i32)0); // ^ pins to start; '9' there -> no match at all
    expect((u8*)"^\\d\\d\\d\\d-\\d\\d-\\d\\d$", (u8*)"2026-07-25", (i32)1, (i32)1);

    // search index + length
    UXRegex* re = UXRegex.compile((u8*)"\\d+");
    i32 at = re.search((u8*)"abc 42 xy");
    if (at == (i32)4 && re.matchLength() == (i32)6)
        {
        Stdio.printf("  ok   search found \\d+ at 4, end 6\n");
        }
    else
        {
        Stdio.printf("  FAIL search at=%d end=%d (want 4,6)\n", (i16)at, (i16)re.matchLength());
        gFails = gFails + (i32)1;
        }

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXRegex — literals, ., quantifiers, classes, \\d\\w\\s, anchors, alternation, groups.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
