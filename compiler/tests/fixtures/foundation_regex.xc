//xtc-na: xt6502 — Regex is not available on xt6502
// foundation_regex.xc — Regex: literals, classes, anchors, groups and
// captures, greedy and lazy quantifiers, counts, word boundaries, options,
// UTF-8 characters, find-all, replace, split, escape and pattern errors.
#import "Foundation.xc"
#import "Regex.xc"

String* S(u8* c)
    {
    return String.withCString(c);
    }
Regex* RE(u8* p, u8 opts)
    {
    try
        {
        return Regex.compileWith(S(p), opts);
        }
    catch (RegexError e)
        {
        Stdio.printf("compile %s: %s\n", p, e.message().cString());
        }
    return (Regex*)0;
    }
// The first match and its groups.
void find(u8* p, u8* text)
    {
    Regex* re = RE(p, (u8)0);
    if (re == 0)
        return;
    RegexMatch* m = re.firstMatch(S(text));
    Stdio.printf("%s in \"%s\": ", p, text);
    if (m == 0)
        {
        Stdio.printf("none\n");
        return;
        }
    for (u32 g = (u32)0; g <= m.groupCount(); g++)
        {
        String* s = m.group(g);
        Stdio.printf(g > (u32)0 ? " $%u=" : "$%u=", g);
        Stdio.printf(s == 0 ? "-" : "[%s]", s == 0 ? (u8*)"" : s.cString());
        }
    Range* r = m.range();
    Stdio.printf(" @%d+%d\n", r.loc, r.len);
    }
void whole(u8* p, u8* text, u8 opts)
    {
    Regex* re = RE(p, opts);
    if (re != 0)
        Stdio.printf("%s matches \"%s\": %d\n", p, text, (i32)(re.matches(S(text)) ? 1 : 0));
    }
void bad(u8* p)
    {
    try
        {
        Regex.compile(S(p));
        Stdio.printf("%s: compiled\n", p);
        }
    catch (RegexError e)
        {
        Stdio.printf("%s: %s\n", p, e.message().cString());
        }
    }

i32 main(void)
    {
    find("b+", "aabbbcc");
    find("(\\w+)@(\\w+)\\.com", "mail ada@example.com now");
    find("^\\d{3}-\\d{4}$", "555-1234");
    find("^\\d{3}-\\d{4}$", "555-12345");
    find("a.c", "abc a\nc");
    find("[^a-c]+", "abcxyzabc");
    find("<.+>", "<a><b>");
    find("<.+?>", "<a><b>");
    find("a{2,3}", "aaaa");
    find("a{2,3}?", "aaaa");
    find("x{2,}", "xxxxx");
    find("(a|ab)(c|bcd)(d*)", "abcd");
    find("(a)|(b)", "b");
    find("\\bcat\\b", "concat cat");
    find("\\Bcat", "concat cat");
    find("(?:ab)+", "ababab");
    find("colou?r", "my color");
    find("[\\d.]+", "v1.25b");
    find("caf.", "un café noir");
    find("[é]+", "ééé!");
    find("[^a]", "é");
    find("(a*)*b", "aaab");
    find("(a*)+$", "aa");
    find("", "abc");
    find("\\x41\\t", "xA\ty");
    find("a{,2}", "a{,2}");

    whole("[a-z]+", "hello", (u8)0);
    whole("[a-z]+", "Hello", (u8)0);
    whole("[a-z]+", "Hello", Regex.caseInsensitive());
    whole("HELLO", "hello", Regex.caseInsensitive());
    whole("a|ab", "ab", (u8)0);
    whole("a.b", "a\nb", Regex.dotAll());

    Regex* ml = RE("^\\w+$", Regex.multiline());
    Array* lines = ml.allMatches(S("one\ntwo\nthree"));
    Stdio.printf("multiline lines: %u\n", lines.count());
    Regex* digits = RE("\\d+", (u8)0);
    Array* all = digits.allMatches(S("a1b22c333"));
    Stdio.printf("all digits:");
    for (u32 i = (u32)0; i < all.count(); i++)
        Stdio.printf(" %s", ((RegexMatch*)all.get(i)).group((u32)0).cString());
    Stdio.printf("\n");
    Regex* empty = RE("x*", (u8)0);
    Stdio.printf("empty matches in \"aé\": %u\n", empty.allMatches(S("aé")).count());

    Regex* email = RE("(\\w+)@(\\w+)\\.com", (u8)0);
    Stdio.printf("%s\n", email.replace(S("ada@example.com, bob@example.com"), S("$2:$1 ($$)")).cString());
    Stdio.printf("%s\n", email.replaceFirst(S("ada@example.com, bob@example.com"), S("<$0>")).cString());
    Regex* comma = RE("\\s*,\\s*", (u8)0);
    Array* parts = comma.split(S("a , b,c ,,d"));
    Stdio.printf("split:");
    for (u32 i = (u32)0; i < parts.count(); i++)
        Stdio.printf(" [%s]", ((String*)parts.get(i)).cString());
    Stdio.printf("\n");
    Stdio.printf("escape: %s\n", Regex.escape(S("1+1=2? (yes) [x] $5.00")).cString());
    whole(Regex.escape(S("1+1=2?")).cString(), "1+1=2?", (u8)0);

    bad("(ab");
    bad("ab)");
    bad("[abc");
    bad("*a");
    bad("a{3,2}");
    bad("[z-a]");
    bad("\\q");
    bad("(?=x)");
    bad("x{2000}");
    return (i32)0;
    }
