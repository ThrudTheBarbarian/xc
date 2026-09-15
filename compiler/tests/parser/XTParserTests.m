#import <Foundation/Foundation.h>
#import "XTLexer.h"
#import "XTParser.h"
#import "XTDiagnosticEngine.h"
#import "XTDeclNodes.h"
#import "XTStmtNodes.h"
#import "XTExprNodes.h"
#import "XTTypeTable.h"

#define ASSERT_TRUE(cond, msg) do { if (!(cond)) { fprintf(stderr, "  FAIL: %s\n", msg); failures++; } else { fprintf(stderr, "  PASS: %s\n", msg); } } while(0)

static XTProgramNode *parseSourceCollecting(NSString *source, NSUInteger *errorsOut) {
    XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
    XTLexer *lexer = [[XTLexer alloc] initWithSource:source filename:@"test.xc" diagnostics:diag];
    NSArray<XTToken *> *tokens = [lexer tokenise];
    XTTypeTable *tt = [[XTTypeTable alloc] init];
    XTParser *parser = [[XTParser alloc] initWithTokens:tokens typeTable:tt diagnostics:diag];
    XTProgramNode *ast = [parser parse];
    if (errorsOut) *errorsOut = diag.errorCount;
    return ast;
}

static XTProgramNode *parseSource(NSString *source) {
    return parseSourceCollecting(source, NULL);
}

int runParserTests(void) {
    int failures = 0;

    // Test 1: Simple function declaration
    {
        XTProgramNode *ast = parseSource(@"void main(void) { return; }");
        ASSERT_TRUE(ast != nil, "Parse simple function");
        ASSERT_TRUE(ast.declarations.count == 1, "One declaration");
        ASSERT_TRUE([ast.declarations[0] isKindOfClass:[XTFunctionDeclNode class]], "Is FunctionDecl");
        XTFunctionDeclNode *fn = (XTFunctionDeclNode *)ast.declarations[0];
        ASSERT_TRUE([fn.funcName isEqualToString:@"main"], "Function name is main");
    }

    // Test 2: Variable declaration with initialiser
    {
        XTProgramNode *ast = parseSource(@"u8 x = 5;");
        ASSERT_TRUE(ast.declarations.count == 1, "One var decl");
        ASSERT_TRUE([ast.declarations[0] isKindOfClass:[XTVariableDeclNode class]], "Is VarDecl");
        XTVariableDeclNode *vd = (XTVariableDeclNode *)ast.declarations[0];
        ASSERT_TRUE([vd.varName isEqualToString:@"x"], "Var name is x");
        ASSERT_TRUE(vd.initialiser != nil, "Has initialiser");
    }

    // Test 3: `(( ))` is no longer a block delimiter.
    //
    // It used to be an alternative to `{ }`, which forced the LEXER to fuse
    // adjacent parens into one token and the parser to split them back apart
    // by lookahead — and `((T@)p).f = v;` was read as a block until a
    // heuristic was added to tell the two apart. Removing the syntax removes
    // both. What matters now is that `((` is simply two parens: a cast at
    // statement start parses, and a function body written `(( ))` is rejected
    // rather than quietly accepted.
    {
        NSUInteger errors = 0;
        parseSourceCollecting(@"void foo(void) (( return; ))", &errors);
        ASSERT_TRUE(errors > 0, "(( )) no longer opens a block");
    }
    {
        NSUInteger errors = 0;
        parseSourceCollecting(@"struct S { i16 a; }\n"
                              @"void f(u8@ p) { ((S@)p).a = (i16)7; }", &errors);
        ASSERT_TRUE(errors == 0, "Cast as an lvalue at statement start parses");
    }

    // Test 4: If-else statement
    {
        XTProgramNode *ast = parseSource(@"void f(void) { if (x) { y; } else { z; } }");
        ASSERT_TRUE(ast != nil, "Parse if-else");
        XTFunctionDeclNode *fn = (XTFunctionDeclNode *)ast.declarations[0];
        XTBlockNode *block = (XTBlockNode *)fn.body;
        ASSERT_TRUE(block.statements.count == 1, "One statement in body");
        ASSERT_TRUE([block.statements[0] isKindOfClass:[XTIfNode class]], "Is IfNode");
        XTIfNode *ifn = (XTIfNode *)block.statements[0];
        ASSERT_TRUE(ifn.elseBlock != nil, "Has else block");
    }

    // Test 5: For-in loop
    {
        XTProgramNode *ast = parseSource(@"void f(void) { for (u8 x in arr) { x; } }");
        ASSERT_TRUE(ast != nil, "Parse for-in");
        XTFunctionDeclNode *fn = (XTFunctionDeclNode *)ast.declarations[0];
        XTBlockNode *block = (XTBlockNode *)fn.body;
        ASSERT_TRUE([block.statements[0] isKindOfClass:[XTForInNode class]], "Is ForInNode");
    }

    // Test 6: C-style for loop
    {
        XTProgramNode *ast = parseSource(@"void f(void) { for (u8 i = 0; i < 10; i++) { i; } }");
        ASSERT_TRUE(ast != nil, "Parse C-style for");
        XTFunctionDeclNode *fn = (XTFunctionDeclNode *)ast.declarations[0];
        XTBlockNode *block = (XTBlockNode *)fn.body;
        ASSERT_TRUE([block.statements[0] isKindOfClass:[XTForCStyleNode class]], "Is ForCStyleNode");
    }

    // Test 7: Struct declaration
    {
        XTProgramNode *ast = parseSource(@"struct Point { u16 x; u8 y; };");
        ASSERT_TRUE(ast != nil, "Parse struct");
        ASSERT_TRUE([ast.declarations[0] isKindOfClass:[XTStructDeclNode class]], "Is StructDecl");
        XTStructDeclNode *sd = (XTStructDeclNode *)ast.declarations[0];
        ASSERT_TRUE(sd.fields.count == 2, "Struct has 2 fields");
    }

    // Test 8: Enum declaration
    {
        XTProgramNode *ast = parseSource(@"enum suits = {hearts, clubs, diamonds, spades};");
        ASSERT_TRUE(ast != nil, "Parse enum");
        ASSERT_TRUE([ast.declarations[0] isKindOfClass:[XTEnumDeclNode class]], "Is EnumDecl");
        XTEnumDeclNode *ed = (XTEnumDeclNode *)ast.declarations[0];
        ASSERT_TRUE(ed.members.count == 4, "Enum has 4 members");
        ASSERT_TRUE(ed.members[0].resolvedValue == 0, "hearts = 0");
        ASSERT_TRUE(ed.members[3].resolvedValue == 3, "spades = 3");
    }

    // Test 9: Enum with explicit values
    {
        XTProgramNode *ast = parseSource(@"enum suits = {hearts=5, clubs, diamonds, spades};");
        XTEnumDeclNode *ed = (XTEnumDeclNode *)ast.declarations[0];
        ASSERT_TRUE(ed.members[0].resolvedValue == 5, "hearts = 5");
        ASSERT_TRUE(ed.members[1].resolvedValue == 6, "clubs = 6");
    }

    // Test 10: Multi-return function
    {
        XTProgramNode *ast = parseSource(@"u8,u16 dual(void) { return 1,2; }");
        ASSERT_TRUE(ast != nil, "Parse multi-return function");
        XTFunctionDeclNode *fn = (XTFunctionDeclNode *)ast.declarations[0];
        ASSERT_TRUE(fn.returnTypes.count == 2, "Two return types");
    }

    // Test 11: Asm block
    {
        XTProgramNode *ast = parseSource(@"void f(void) { asm { LDA #$00 } }");
        ASSERT_TRUE(ast != nil, "Parse asm block");
        XTFunctionDeclNode *fn = (XTFunctionDeclNode *)ast.declarations[0];
        XTBlockNode *block = (XTBlockNode *)fn.body;
        ASSERT_TRUE([block.statements[0] isKindOfClass:[XTAsmBlockNode class]], "Is AsmBlock");
    }

    // Test 12: Ternary expression
    {
        XTProgramNode *ast = parseSource(@"u8 x = a ? 1 : 0;");
        ASSERT_TRUE(ast != nil, "Parse ternary");
        XTVariableDeclNode *vd = (XTVariableDeclNode *)ast.declarations[0];
        ASSERT_TRUE([vd.initialiser isKindOfClass:[XTTernaryExprNode class]], "Initialiser is ternary");
    }

    // Test 13: Pointer type with @
    {
        XTProgramNode *ast = parseSource(@"u8 @ ptr = $400;");
        ASSERT_TRUE(ast != nil, "Parse pointer type");
    }

    // Test 14: Typedef struct
    {
        XTProgramNode *ast = parseSource(@"typedef struct { u16 x; u8 y; } Cursor;");
        ASSERT_TRUE(ast != nil, "Parse typedef struct");
        ASSERT_TRUE([ast.declarations[0] isKindOfClass:[XTTypedefNode class]], "Is TypedefNode");
        XTTypedefNode *td = (XTTypedefNode *)ast.declarations[0];
        ASSERT_TRUE([td.aliasName isEqualToString:@"Cursor"], "Alias is Cursor");
    }

    // Test 15: Varargs function
    {
        XTProgramNode *ast = parseSource(@"u8 myFunc(string fmt, ...) { return 0; }");
        ASSERT_TRUE(ast != nil, "Parse varargs function");
        XTFunctionDeclNode *fn = (XTFunctionDeclNode *)ast.declarations[0];
        ASSERT_TRUE(fn.isVarArgs, "Function is varargs");
    }

    // Test 16: Class declaration
    {
        XTProgramNode *ast = parseSource(@"class Colour { u8 red; u8 green; u8 blue; void set(u8 r, u8 g, u8 b) { red = r; } }");
        ASSERT_TRUE(ast != nil, "Parse class");
        ASSERT_TRUE([ast.declarations[0] isKindOfClass:[XTClassDeclNode class]], "Is ClassDecl");
        XTClassDeclNode *cd = (XTClassDeclNode *)ast.declarations[0];
        ASSERT_TRUE(cd.ivars.count == 3, "3 ivars");
        ASSERT_TRUE(cd.methods.count == 1, "1 method");
    }

    return failures;
}
