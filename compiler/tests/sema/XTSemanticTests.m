#import <Foundation/Foundation.h>
#import "XTLexer.h"
#import "XTParser.h"
#import "XTSemanticAnalyzer.h"
#import "XTDiagnosticEngine.h"
#import "XTDeclNodes.h"
#import "XTExprNodes.h"
#import "XTTypeTable.h"
#import "XTType.h"
#import "XTPointerType.h"

#define ASSERT_TRUE(cond, msg) do { if (!(cond)) { fprintf(stderr, "  FAIL: %s\n", msg); failures++; } else { fprintf(stderr, "  PASS: %s\n", msg); } } while(0)

static void analyzeSource(NSString *source, XTDiagnosticEngine **outDiag, XTProgramNode **outAST) {
    XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
    XTLexer *lexer = [[XTLexer alloc] initWithSource:source filename:@"test.xc" diagnostics:diag];
    NSArray<XTToken *> *tokens = [lexer tokenise];
    XTTypeTable *tt = [[XTTypeTable alloc] init];
    XTParser *parser = [[XTParser alloc] initWithTokens:tokens typeTable:tt diagnostics:diag];
    XTProgramNode *ast = [parser parse];
    if (ast && !diag.hasFatalError) {
        XTSemanticAnalyzer *sema = [[XTSemanticAnalyzer alloc] initWithTypeTable:tt diagnostics:diag];
        [sema analyzeProgram:ast];
    }
    *outDiag = diag;
    *outAST = ast;
}

int runSemanticTests(void) {
    int failures = 0;

    // Test 1: Auto type inference from integer literal
    {
        XTDiagnosticEngine *diag; XTProgramNode *ast;
        analyzeSource(@"auto x = 3;", &diag, &ast);
        ASSERT_TRUE(!diag.hasFatalError, "auto u8 inference no error");
        XTVariableDeclNode *vd = (XTVariableDeclNode *)ast.declarations[0];
        ASSERT_TRUE(vd.declaredType.kind == XTTypeKindU8, "auto infers u8 for 3");
    }

    // Test 2: Auto type inference negative → signed
    {
        XTDiagnosticEngine *diag; XTProgramNode *ast;
        analyzeSource(@"auto x = -3;", &diag, &ast);
        // -3 is a unary minus on 3; the resolved type should be i8
        ASSERT_TRUE(!diag.hasFatalError, "auto i8 inference no error");
    }

    // Test 3: Auto type inference for u16
    {
        XTDiagnosticEngine *diag; XTProgramNode *ast;
        analyzeSource(@"auto x = 257;", &diag, &ast);
        ASSERT_TRUE(!diag.hasFatalError, "auto u16 inference no error");
        XTVariableDeclNode *vd = (XTVariableDeclNode *)ast.declarations[0];
        ASSERT_TRUE(vd.declaredType.kind == XTTypeKindU16, "auto infers u16 for 257");
    }

    // Test 4: Auto from string literal
    {
        XTDiagnosticEngine *diag; XTProgramNode *ast;
        analyzeSource(@"auto x = \"hi\";", &diag, &ast);
        ASSERT_TRUE(!diag.hasFatalError, "auto string inference no error");
        XTVariableDeclNode *vd = (XTVariableDeclNode *)ast.declarations[0];
        ASSERT_TRUE(vd.declaredType.isPointerLike, "auto infers pointer for string");
    }

    // Test 5: Auto from float literal
    {
        XTDiagnosticEngine *diag; XTProgramNode *ast;
        analyzeSource(@"auto x = 4.5;", &diag, &ast);
        ASSERT_TRUE(!diag.hasFatalError, "auto float inference no error");
        XTVariableDeclNode *vd = (XTVariableDeclNode *)ast.declarations[0];
        ASSERT_TRUE(vd.declaredType.kind == XTTypeKindFloat, "auto infers float for 4.5");
    }

    // Test 6: Auto from bool literal
    {
        XTDiagnosticEngine *diag; XTProgramNode *ast;
        analyzeSource(@"auto x = true;", &diag, &ast);
        ASSERT_TRUE(!diag.hasFatalError, "auto bool inference no error");
        XTVariableDeclNode *vd = (XTVariableDeclNode *)ast.declarations[0];
        ASSERT_TRUE(vd.declaredType.kind == XTTypeKindBool, "auto infers bool for true");
    }

    // Test 7: Duplicate enum name error
    {
        XTDiagnosticEngine *diag; XTProgramNode *ast;
        analyzeSource(@"enum a = {x, y}; enum a = {p, q};", &diag, &ast);
        ASSERT_TRUE(diag.hasFatalError, "Duplicate enum name produces error");
    }

    // Test 8: Undefined variable error
    {
        XTDiagnosticEngine *diag; XTProgramNode *ast;
        analyzeSource(@"void f(void) { u8 y = undefined_var; }", &diag, &ast);
        ASSERT_TRUE(diag.errorCount > 0, "Undefined variable produces error");
    }

    // Test 9: Binary expression type widening
    {
        XTDiagnosticEngine *diag; XTProgramNode *ast;
        analyzeSource(@"void f(void) { u8 a = 1; u16 b = 500; auto c = a + b; }", &diag, &ast);
        ASSERT_TRUE(!diag.hasFatalError, "Type widening no fatal error");
    }

    // Test 10: Function return type inference
    {
        XTDiagnosticEngine *diag; XTProgramNode *ast;
        analyzeSource(@"u8 foo(void) { return 5; } void bar(void) { auto x = foo(); }", &diag, &ast);
        ASSERT_TRUE(!diag.hasFatalError, "Function return type inference works");
    }

    // Test 11: Struct field offset calculation
    {
        XTDiagnosticEngine *diag; XTProgramNode *ast;
        analyzeSource(@"struct S { u16 a; u8 b; u16 c; };", &diag, &ast);
        ASSERT_TRUE(!diag.hasFatalError, "Struct parsed without error");
    }

    // Test 12: Scope isolation — for loop variable not visible outside
    {
        XTDiagnosticEngine *diag; XTProgramNode *ast;
        analyzeSource(@"void f(void) { for (u8 i = 0; i < 10; i++) {} u8 x = i; }", &diag, &ast);
        ASSERT_TRUE(diag.errorCount > 0, "Loop variable 'i' not visible outside for");
    }

    // ── xt extended-RAM analysis (PR1) ──────────────────────────────
    // Test: legacy programs leave both extended-RAM sets empty.
    {
        XTDiagnosticEngine *diag = [XTDiagnosticEngine new];
        XTLexer *lexer = [[XTLexer alloc] initWithSource:@"void f(void) { u8 x = 1; }"
                                                filename:@"test.xc"
                                              diagnostics:diag];
        NSArray<XTToken *> *tokens = [lexer tokenise];
        XTTypeTable *tt = [XTTypeTable new];
        XTParser *parser = [[XTParser alloc] initWithTokens:tokens
                                                  typeTable:tt
                                                 diagnostics:diag];
        XTProgramNode *ast = [parser parse];
        XTSemanticAnalyzer *sema = [[XTSemanticAnalyzer alloc]
                                    initWithTypeTable:tt diagnostics:diag];
        [sema analyzeProgram:ast];
        ASSERT_TRUE(sema.regionCLocallyUsing.count == 0,
                    "PR1: legacy program → regionCLocallyUsing empty");
        ASSERT_TRUE(sema.regionCUsing.count == 0,
                    "PR1: legacy program → regionCUsing empty");
    }

    // Test: a function with inline asm referencing $84 lands in
    // regionCLocallyUsing, and (because the closure includes
    // locally-using as a base) regionCUsing.
    {
        XTDiagnosticEngine *diag = [XTDiagnosticEngine new];
        NSString *src =
            @"void touchExt(void) {\n"
            @"    asm {\n"
            @"        LDA #$05\n"
            @"        STA $84\n"
            @"    }\n"
            @"}\n";
        XTLexer *lexer = [[XTLexer alloc] initWithSource:src
                                                filename:@"test.xc"
                                              diagnostics:diag];
        NSArray<XTToken *> *tokens = [lexer tokenise];
        XTTypeTable *tt = [XTTypeTable new];
        XTParser *parser = [[XTParser alloc] initWithTokens:tokens
                                                  typeTable:tt
                                                 diagnostics:diag];
        XTProgramNode *ast = [parser parse];
        XTSemanticAnalyzer *sema = [[XTSemanticAnalyzer alloc]
                                    initWithTypeTable:tt diagnostics:diag];
        [sema analyzeProgram:ast];
        ASSERT_TRUE([sema.regionCLocallyUsing containsObject:@"_fn_touchExt"],
                    "PR1: $84 in inline asm → flagged locally-using");
        ASSERT_TRUE([sema.regionCUsing containsObject:@"_fn_touchExt"],
                    "PR1: closure includes locally-using seed");
    }

    // Test: $85 also flags.
    {
        XTDiagnosticEngine *diag = [XTDiagnosticEngine new];
        NSString *src =
            @"void touchExtHi(void) {\n"
            @"    asm { STA $85 }\n"
            @"}\n";
        XTLexer *lexer = [[XTLexer alloc] initWithSource:src
                                                filename:@"test.xc"
                                              diagnostics:diag];
        NSArray<XTToken *> *tokens = [lexer tokenise];
        XTTypeTable *tt = [XTTypeTable new];
        XTParser *parser = [[XTParser alloc] initWithTokens:tokens
                                                  typeTable:tt
                                                 diagnostics:diag];
        XTProgramNode *ast = [parser parse];
        XTSemanticAnalyzer *sema = [[XTSemanticAnalyzer alloc]
                                    initWithTypeTable:tt diagnostics:diag];
        [sema analyzeProgram:ast];
        ASSERT_TRUE([sema.regionCLocallyUsing containsObject:@"_fn_touchExtHi"],
                    "PR1: $85 in inline asm → flagged locally-using");
    }

    // Test: comments mentioning $84 don't trigger the flag.
    {
        XTDiagnosticEngine *diag = [XTDiagnosticEngine new];
        NSString *src =
            @"void noTouch(void) {\n"
            @"    asm {\n"
            @"        LDA #$05  ; no real reference to $84 here\n"
            @"        STA $80\n"
            @"    }\n"
            @"}\n";
        XTLexer *lexer = [[XTLexer alloc] initWithSource:src
                                                filename:@"test.xc"
                                              diagnostics:diag];
        NSArray<XTToken *> *tokens = [lexer tokenise];
        XTTypeTable *tt = [XTTypeTable new];
        XTParser *parser = [[XTParser alloc] initWithTokens:tokens
                                                  typeTable:tt
                                                 diagnostics:diag];
        XTProgramNode *ast = [parser parse];
        XTSemanticAnalyzer *sema = [[XTSemanticAnalyzer alloc]
                                    initWithTypeTable:tt diagnostics:diag];
        [sema analyzeProgram:ast];
        ASSERT_TRUE(![sema.regionCLocallyUsing containsObject:@"_fn_noTouch"],
                    "PR1: $84 only in comment → not flagged");
    }

    return failures;
}
