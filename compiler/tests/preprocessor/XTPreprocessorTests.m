#import <Foundation/Foundation.h>
#import "XTPreprocessor.h"
#import "XTDiagnosticEngine.h"

#define ASSERT_EQ(a, b, msg) do { if (![a isEqualToString:b]) { fprintf(stderr, "  FAIL: %s\n    expected: '%s'\n    got:      '%s'\n", msg, (b).UTF8String, (a).UTF8String); failures++; } else { fprintf(stderr, "  PASS: %s\n", msg); } } while(0)
#define ASSERT_TRUE(cond, msg) do { if (!(cond)) { fprintf(stderr, "  FAIL: %s\n", msg); failures++; } else { fprintf(stderr, "  PASS: %s\n", msg); } } while(0)

int runPreprocessorTests(void) {
    int failures = 0;

    // Test 1: Simple object-like define
    {
        XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
        XTPreprocessor *pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
        [pp defineMacro:@"MAX" value:@"255"];
        NSString *result = [pp preprocessSource:@"u8 x = MAX;" filename:@"test.xc"];
        ASSERT_TRUE([result containsString:@"u8 x = 255;"], "Object-like macro expansion");
    }

    // Test 2: Function-like define
    {
        XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
        XTPreprocessor *pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
        NSString *src = @"#define ADD(a,b) a+b\nu8 x = ADD(3,4);";
        NSString *result = [pp preprocessSource:src filename:@"test.xc"];
        ASSERT_TRUE([result containsString:@"3+4"], "Function-like macro expansion");
    }

    // Test 3: Nested macro expansion
    {
        XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
        XTPreprocessor *pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
        NSString *src = @"#define A 5\n#define B A\nu8 x = B;";
        NSString *result = [pp preprocessSource:src filename:@"test.xc"];
        ASSERT_TRUE([result containsString:@"5"], "Nested macro expansion");
    }

    // Test 4: #warning emits warning
    {
        XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
        XTPreprocessor *pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
        [pp preprocessSource:@"#warning test msg" filename:@"test.xc"];
        ASSERT_TRUE(diag.warningCount == 1, "#warning produces a warning");
    }

    // Test 5: #error emits error
    {
        XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
        XTPreprocessor *pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
        [pp preprocessSource:@"#error fatal msg" filename:@"test.xc"];
        ASSERT_TRUE(diag.hasFatalError, "#error produces a fatal error");
    }

    // Test 6: -D injection
    {
        XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
        XTPreprocessor *pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
        [pp defineMacro:@"DEBUG" value:@"1"];
        NSString *result = [pp preprocessSource:@"u8 x = DEBUG;" filename:@"test.xc"];
        ASSERT_TRUE([result containsString:@"1"], "-D macro injection");
    }

    // Test 7: Varargs macro
    {
        XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
        XTPreprocessor *pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
        NSString *src = @"#define LOG(fmt, ...) print(fmt, __VA_ARGS__)\nLOG(\"hi\", 1, 2);";
        NSString *result = [pp preprocessSource:src filename:@"test.xc"];
        ASSERT_TRUE([result containsString:@"1, 2"], "Varargs macro expansion");
    }

    // Test 8: `##` token paste, through the two-level CAT idiom. The outer
    // macro expands its arguments; only the inner one pastes them.
    {
        XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
        XTPreprocessor *pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
        NSString *src = @"#define CAT2(a,b) a##b\n#define CAT(a,b) CAT2(a,b)\n#define VER 7\n"
                         "u16 v = CAT(x, VER);";
        NSString *result = [pp preprocessSource:src filename:@"test.xc"];
        ASSERT_TRUE([result containsString:@"u16 v = x7;"], "## pastes expanded arguments");
    }

    // Test 9: `#` stringizes the RAW argument — one level must not expand it.
    {
        XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
        XTPreprocessor *pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
        NSString *src = @"#define STR2(x) #x\n#define STR(x) STR2(x)\n#define VER 7\n"
                         "a = STR(VER); b = STR2(VER);";
        NSString *result = [pp preprocessSource:src filename:@"test.xc"];
        ASSERT_TRUE([result containsString:@"a = \"7\";"],   "# stringizes the expanded arg (two levels)");
        ASSERT_TRUE([result containsString:@"b = \"VER\";"], "# stringizes the raw arg (one level)");
    }

    // Test 10: substitution is TOKEN-aware. A parameter must not be replaced
    // where its letters merely occur inside a longer identifier — `a` in
    // `abs_val` used to be, silently mangling the body.
    {
        XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
        XTPreprocessor *pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
        NSString *src = @"#define ABS_OK(a) a + abs_val\nu16 x = ABS_OK(1);";
        NSString *result = [pp preprocessSource:src filename:@"test.xc"];
        ASSERT_TRUE([result containsString:@"1 + abs_val"], "param not substituted inside an identifier");
    }

    // Test 11: …nor inside a string literal, which failed SILENTLY.
    {
        XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
        XTPreprocessor *pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
        NSString *src = @"#define INSTR(a) \"a is here\"\nx = INSTR(zz);";
        NSString *result = [pp preprocessSource:src filename:@"test.xc"];
        ASSERT_TRUE([result containsString:@"\"a is here\""], "param not substituted inside a string literal");
    }

    // Test 12: a comma inside a string argument is not an argument separator.
    {
        XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
        XTPreprocessor *pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
        NSString *src = @"#define P(s) print(s)\nP(\"a,b\");";
        NSString *result = [pp preprocessSource:src filename:@"test.xc"];
        ASSERT_TRUE([result containsString:@"print(\"a,b\")"], "comma inside a string arg does not split the call");
    }

    // Test 13: GNU `, ## __VA_ARGS__` — an empty variadic tail eats the comma.
    {
        XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
        XTPreprocessor *pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
        NSString *src = @"#define LOG(fmt, ...) print(fmt, ##__VA_ARGS__)\nLOG(\"hi\");";
        NSString *result = [pp preprocessSource:src filename:@"test.xc"];
        ASSERT_TRUE([result containsString:@"print(\"hi\")"], ", ## __VA_ARGS__ swallows the comma when empty");
    }

    // Test 14: an object-like macro whose body pastes.
    {
        XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
        XTPreprocessor *pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
        NSString *src = @"#define J foo##bar\nx = J;";
        NSString *result = [pp preprocessSource:src filename:@"test.xc"];
        ASSERT_TRUE([result containsString:@"x = foobar;"], "## in an object-like macro body");
    }

    // Test 15: a LIBRARY file's quoted import resolves through the search
    // order (platform lib, then generic), NOT against its own directory.
    //
    // This is what lets one shared library file serve every target. If
    // generic/lib/Object.xc's `#import "String.xc"` resolved to its own
    // neighbour, a 6502 build would get generic's 32-bit String alongside the
    // platform's own — two definitions of one class. A file that lives in a
    // search directory gets no head start for its own directory.
    {
        NSString *tmp = NSTemporaryDirectory();
        NSString *plat = [tmp stringByAppendingPathComponent:@"xtpp_plat"];
        NSString *gen  = [tmp stringByAppendingPathComponent:@"xtpp_generic"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:plat withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:gen  withIntermediateDirectories:YES attributes:nil error:nil];

        // The same filename in both dirs; the platform one must win.
        [@"PLATFORM_WIDTH\n" writeToFile:[plat stringByAppendingPathComponent:@"Width.xc"]
                              atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"GENERIC_WIDTH\n"  writeToFile:[gen stringByAppendingPathComponent:@"Width.xc"]
                              atomically:YES encoding:NSUTF8StringEncoding error:nil];
        // A shared file that lives in generic/ and imports the duplicated one.
        [@"#import \"Width.xc\"\n" writeToFile:[gen stringByAppendingPathComponent:@"Shared.xc"]
                                     atomically:YES encoding:NSUTF8StringEncoding error:nil];

        XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
        XTPreprocessor *pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
        pp.includePaths = @[plat, gen];
        NSString *result = [pp preprocessSource:@"#import \"Shared.xc\"" filename:@"main.xc"];

        ASSERT_TRUE([result containsString:@"PLATFORM_WIDTH"],
                    "library file's import resolves platform-first, not same-dir-first");
        ASSERT_TRUE(![result containsString:@"GENERIC_WIDTH"],
                    "...and does NOT pull its own directory's copy");

        [fm removeItemAtPath:plat error:nil];
        [fm removeItemAtPath:gen error:nil];
    }

    // `#use <X>` sugar: expands to an #import of X (source X.xc or binary libX,
    // by what the resolver finds) followed by `use X;`. Here the resolver finds
    // a source Widget.xc via the bare-name `.xc` fallback, and the `use Widget;`
    // promotion line is emitted.
    {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"xtc-use-%u", arc4random()]];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [@"class Widget { static void ping(void) {} }\n"
            writeToFile:[dir stringByAppendingPathComponent:@"Widget.xc"]
            atomically:YES encoding:NSUTF8StringEncoding error:nil];

        XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
        XTPreprocessor *pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
        pp.includePaths = @[dir];
        NSString *result = [pp preprocessSource:@"#use <Widget>\nvoid main(void){}"
                                       filename:@"test.xc"];
        ASSERT_TRUE([result containsString:@"use Widget;"],
                    "#use <X> emits the `use X;` promotion");
        ASSERT_TRUE([result containsString:@"class Widget"],
                    "#use <X> resolves source Widget.xc via bare-name .xc fallback");
        ASSERT_TRUE(!diag.hasFatalError, "#use <X> resolved without error");

        [fm removeItemAtPath:dir error:nil];
    }

    return failures;
}
