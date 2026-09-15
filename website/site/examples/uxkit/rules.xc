// rules.xc — UXRegex, UXValidator and UXExpression: the three ways a value is
// checked or computed without a window anywhere.
//
// All pure logic, so a form's Submit gate can be tested without typing.
#import <Stdio.xc>
#import "UXRegex.xc"
#import "UXValidator.xc"
#import "UXExpression.xc"

void tryMatch(u8* pattern, u8* subject) {
    UXRegex* re = UXRegex.compile(pattern);
    if (!re.isValid()) { Stdio.printf("  %s : INVALID PATTERN\n", pattern); return; }
    i32 at = re.search(subject);
    Stdio.printf("  /%s/ on '%s': matches=%d test=%d at=%d len=%d\n",
                 pattern, subject,
                 re.matches(subject) ? 1 : 0, re.test(subject) ? 1 : 0,
                 at, at >= (i32)0 ? re.matchLength() : (i32)0);
}

void check(UXValidator* v, u8* value) {
    u8* err = v.firstError(value);
    Stdio.printf("  '%s': %s\n", value,
                 err == (u8*)0 ? (u8*)"ok" : err);
}

void calc(u8* src, UXBindings* b) {
    UXExpression* e = UXExpression.parse(src);
    if (!e.isValid()) { Stdio.printf("  %s = INVALID\n", src); return; }
    Stdio.printf("  %s = %d\n", src, e.evaluate(b));
}

void main(void) {
    // ---- regex ------------------------------------------------------------
    Stdio.printf("regex:\n");

    // matches() is the WHOLE string; test()/search() look anywhere.
    tryMatch((u8*)"\\d+", (u8*)"42");
    tryMatch((u8*)"\\d+", (u8*)"x 42 y");
    tryMatch((u8*)"^\\d+-[a-z]+$", (u8*)"42-hello");
    tryMatch((u8*)"^\\d+-[a-z]+$", (u8*)"42-Hello");

    // Classes, negation, alternation, groups and the three quantifiers.
    tryMatch((u8*)"[A-Za-z_][A-Za-z0-9_]*", (u8*)"9lives");
    tryMatch((u8*)"^[^0-9]+$", (u8*)"letters");
    tryMatch((u8*)"^(cat|dog)s?$", (u8*)"dogs");
    tryMatch((u8*)"^a.c$", (u8*)"abc");
    tryMatch((u8*)"^ab?c$", (u8*)"ac");

    // Greedy: * takes as much as it can and gives back only on failure.
    tryMatch((u8*)"<.*>", (u8*)"<a> and <b>");

    // A malformed pattern is reported rather than matching oddly.
    tryMatch((u8*)"[a-", (u8*)"anything");

    // But {n,m} is NOT a quantifier here: the braces are literal characters,
    // so the pattern is valid and simply never matches what you meant.
    tryMatch((u8*)"^\\d{2}$", (u8*)"42");
    tryMatch((u8*)"^\\d\\d$", (u8*)"42");

    // ---- validator --------------------------------------------------------
    Stdio.printf("validator:\n");

    UXValidator* name = new UXValidator();
    name.requireNonEmpty((u8*)"a name is required");
    name.requireMinLength((i32)2, (u8*)"at least 2 characters");
    name.requireMaxLength((i32)8, (u8*)"at most 8 characters");

    check(name, (u8*)"");
    check(name, (u8*)"J");
    check(name, (u8*)"Jonathan Smith");
    check(name, (u8*)"Alice");

    // A regex rule is a WHOLE-string match, which is what a field wants.
    UXValidator* code = new UXValidator();
    code.requireMatch((u8*)"^[A-Z][A-Z]-\\d\\d$", (u8*)"format is XX-99");
    check(code, (u8*)"GB-42");
    check(code, (u8*)"gb-42");
    check(code, (u8*)"see GB-42 here");

    // Rules run in order, so the ORDER is the message priority.
    UXValidator* age = new UXValidator();
    age.requireNonEmpty((u8*)"age is required");
    age.requireIntRange((i32)18, (i32)120, (u8*)"must be 18 to 120");
    check(age, (u8*)"");
    check(age, (u8*)"17");
    check(age, (u8*)"42");

    // An integer range reads the value with a lenient parser: text that is not
    // a number reads as 0, so it passes whenever 0 is inside the range.
    UXValidator* score = new UXValidator();
    score.requireIntRange((i32)0, (i32)100, (u8*)"0 to 100");
    check(score, (u8*)"55");
    check(score, (u8*)"banana");

    // A validator with no rules passes everything.
    Stdio.printf("  empty validator rules=%d passes=%d\n",
                 (new UXValidator()).ruleCount(),
                 (new UXValidator()).validate((u8*)"") ? 1 : 0);

    // ---- expressions ------------------------------------------------------
    Stdio.printf("expression:\n");

    UXBindings* b = new UXBindings();
    b.set((u8*)"qty",   (i32)3);
    b.set((u8*)"price", (i32)200);
    b.set((u8*)"tax",   (i32)50);

    calc((u8*)"qty * price + tax", b);
    calc((u8*)"(qty + 1) * price", b);
    calc((u8*)"-qty * 10", b);
    calc((u8*)"7 / 2", b);
    calc((u8*)"7 % 2", b);

    // Comparisons yield 1/0, so an expression is also a predicate.
    calc((u8*)"qty * price > 500", b);
    calc((u8*)"qty == 3", b);

    // Division and modulo by zero give 0 rather than trapping.
    calc((u8*)"qty / 0", b);
    calc((u8*)"qty % 0", b);

    // An unbound name reads as 0.
    calc((u8*)"qty + missing", b);

    // Rebinding re-evaluates; the expression is parsed once.
    UXExpression* e = UXExpression.parse((u8*)"qty * price");
    Stdio.printf("  before: %d\n", e.evaluate(b));
    b.set((u8*)"qty", (i32)10);
    Stdio.printf("  after qty=10: %d\n", e.evaluate(b));

    // A malformed expression is reported by isValid(), not by a null.
    calc((u8*)"qty * ", b);
    calc((u8*)"1 + 2)", b);
}
