#import "XTDesignableSynthesis.h"
#import "XTLexer.h"
#import "XTParser.h"

static NSString* XTStripTypeQualifiers(NSString* disp)
    {
    static NSArray<NSString*>* quals = nil;
    if (!quals)
        quals = @[ @"main:", @"shadow:", @"banked:", @"raw:", @"weak:", @"outlet:" ];
    BOOL changed = YES;
    while (changed)
        {
        changed = NO;
        for (NSString* q in quals)
            {
            if ([disp hasPrefix:q])
                {
                disp = [disp substringFromIndex:q.length];
                changed = YES;
                }
            }
        }
    return disp;
    }

@implementation XTDesignableSynthesis

+ (XTProgramNode*)run:(XTProgramNode*)ast
            typeTable:(XTTypeTable*)tt
                arm64:(BOOL)arm64
          diagnostics:(XTDiagnosticEngine*)_diagnostics
    {
    // 1. Collect local designable classes (imported classes already carry their
    //    synthesised bodies in the .so — never re-synthesise across a module).
    NSMutableArray<XTClassDeclNode*>* designable = [NSMutableArray array];
    for (XTASTNode* d in ast.declarations)
        {
        if (![d isKindOfClass:[XTClassDeclNode class]])
            continue;
        XTClassDeclNode* c = (XTClassDeclNode*)d;
        if (c.isExternal)
            continue;
        BOOL any = NO;
        for (XTVariableDeclNode* v in c.ivars)
            if (v.isOutlet)
                {
                any = YES;
                break;
                }
        if (!any)
            for (XTMethodDeclNode* m in c.methods)
                if (m.isAction)
                    {
                    any = YES;
                    break;
                    }
        if (any)
            [designable addObject:c];
        }
    if (designable.count == 0)
        return ast;

    // 2. The binding protocol must be in scope: a class cannot conform to a
    //    protocol it cannot see, and the loader adopts the framework's itable
    //    slots. The NAMES are discovered rather than hard-coded — the framework
    //    was XG and is now UXKit (uxkit/026), and a compiler that knows only one
    //    spelling silently stops synthesising the moment the other is imported.
    //    Whichever is in scope wins; both are accepted so a mixed tree builds.
    NSString* protoName = nil;   // UXDesignable | UIDesignable
    NSString* nibClass = nil;    // UXNib        | XGNib
    NSString* controlType = nil; // UXControl    | XGControl
    for (XTASTNode* d in ast.declarations)
        {
        if ([d isKindOfClass:[XTProtocolDeclNode class]])
            {
            NSString* n = ((XTProtocolDeclNode*)d).protocolName;
            if (!protoName && ([n isEqualToString:@"UXDesignable"] ||
                               [n isEqualToString:@"UIDesignable"]))
                protoName = n;
            }
        else if ([d isKindOfClass:[XTClassDeclNode class]])
            {
            NSString* n = ((XTClassDeclNode*)d).className;
            if (!nibClass && ([n isEqualToString:@"UXNib"] ||
                              [n isEqualToString:@"XGNib"]))
                nibClass = n;
            if (!controlType && ([n isEqualToString:@"UXControl"] ||
                                 [n isEqualToString:@"XGControl"]))
                controlType = n;
            }
        }
    if (!protoName)
        {
        [_diagnostics emitError:@"a class with an `outlet` field or `:action` method must "
                                @"import the UI framework — it auto-conforms to the UXDesignable protocol "
                                @"declared there (`#import <UXKit>`; the legacy UIDesignable is also accepted)"
                             at:designable.firstObject.location];
        return ast;
        }
    // wireAction's parameter type. Falling back to Object keeps a designable
    // class with outlets but no actions compiling in a tree that has the
    // protocol but no control class.
    if (!controlType)
        controlType = @"Object";

    // 3. Validate every `:action` method: void return + exactly one object-pointer
    //    param (the sender). A malformed action can't be wired, so reject at source.
    for (XTClassDeclNode* c in designable)
        {
        for (XTMethodDeclNode* m in c.methods)
            {
            if (!m.isAction)
                continue;
            BOOL voidRet = (m.returnTypes.count == 0) ||
                           (m.returnTypes.count == 1 && [m.returnTypes.firstObject.displayName isEqualToString:@"void"]);
            // The sender must be a POINTER. Tested on the sigil the spelling
            // ends with, not on `@` appearing anywhere in it: display names
            // have rendered pointers as `*` since the sigil migration, so the
            // old `containsString:@"@"` was false for every well-formed action
            // and this validator rejected the entire feature. Nothing caught it
            // because nothing in this tree exercised `:action` at all.
            NSString* pdisp = m.parameters.firstObject.paramType.displayName ?: @"";
            BOOL oneObjParam = (m.parameters.count == 1) &&
                               ([pdisp hasSuffix:@"*"] || [pdisp hasSuffix:@"@"]);
            if (!voidRet || !oneObjParam)
                {
                [_diagnostics emitError:[NSString stringWithFormat:
                                                      @"`:action` method '%@' must return void and take exactly one "
                                                      @"object-pointer parameter (the sender)",
                                                      m.methodName]
                                     at:m.location];
                }
            }
        }
    if (_diagnostics.errorCount > 0)
        return ast;

    // 4. Generate the synthesis source. A module-level `_xtc_streq` (u8@ == is a
    //    pointer compare, so name-matching needs a byte compare), a per-module
    //    `_xtc_nibNew` factory, and one throwaway `__xtc_synth_<C>` class per
    //    designable class holding its setOutlet/wireAction bodies.
    NSMutableString* src = [NSMutableString string];
    [src appendString:
             @"bool _xtc_streq(u8@ a, u8@ b) {\n"
             @"  i32 i = (i32)0;\n"
             @"  while (a[i] != (u8)0 && a[i] == b[i]) { i = i + (i32)1; }\n"
             @"  return a[i] == b[i];\n"
             @"}\n"];
    [src appendFormat:@"%@@ _xtc_nibNew(u8@ name) {\n", protoName];
    for (XTClassDeclNode* c in designable)
        [src appendFormat:@"  if (_xtc_streq(name, (u8@)\"%@\")) return (%@@)new %@();\n",
                          c.className, protoName, c.className];
    [src appendFormat:@"  return (%@@)0;\n}\n", protoName];
    // A load-time constructor registers the factory with the loader, so nibs
    // resolve this module's classes with no per-app code. Only when the nib
    // class is in scope (imported) — otherwise the factory is still generated
    // but unwired (e.g. a self-contained test that calls _xtc_nibNew directly).
    if (nibClass)
        {
        [src appendFormat:
                 @"void _xtc_nib_register(void) {\n"
                 @"  %@.registerObjectFactory((pointer)&_xtc_nibNew);\n"
                 @"}\n",
                 nibClass];
        }
    for (XTClassDeclNode* c in designable)
        {
        [src appendFormat:@"class __xtc_synth_%@ {\n", c.className];
        [src appendString:@"  bool setOutlet(u8@ name, Object@ value) {\n"];
        for (XTVariableDeclNode* v in c.ivars)
            {
            if (!v.isOutlet)
                continue;
            NSString* ty = XTStripTypeQualifiers(v.declaredType.displayName ?: @"Object@");
            [src appendFormat:
                     @"    if (_xtc_streq(name, (u8@)\"%@\")) { %@ = (%@ ?)value; "
                     @"return %@ != (%@)0 || value == (Object@)0; }\n",
                     v.varName, v.varName, ty, v.varName, ty];
            }
        [src appendString:@"    return false;\n  }\n"];
        [src appendFormat:@"  bool wireAction(u8@ name, %@@ control) {\n", controlType];
        for (XTMethodDeclNode* m in c.methods)
            {
            if (!m.isAction)
                continue;
            [src appendFormat:
                     @"    if (_xtc_streq(name, (u8@)\"%@\")) { control.setAction(&self.%@); return true; }\n",
                     m.methodName, m.methodName];
            }
        [src appendString:@"    return false;\n  }\n"];
        [src appendString:@"}\n"];
        }

    // 5. Lex + parse the synthesis source against the SAME type table (so `new C()`,
    //    the outlet class types, the control type, Object and the protocol all
    //    resolve).
    XTLexer* lexer = [[XTLexer alloc] initWithSource:src
                                            filename:@"<xg-nib-synth>"
                                         diagnostics:_diagnostics];
    NSArray<XTToken*>* toks = nil;
    toks = [lexer tokenise];
    XTParser* parser = [[XTParser alloc] initWithTokens:toks typeTable:tt diagnostics:_diagnostics];
    parser.defaultPointerPlacement = arm64 ? XTPointerPlacementMain : XTPointerPlacementHeap;
    XTProgramNode* synth = nil;
    synth = [parser parse];
    if (!synth || _diagnostics.errorCount > 0)
        return ast;

    // 6. Transplant: free functions (_xtc_streq, _xtc_nibNew) → program; each
    //    __xtc_synth_<C> method → real class C + append the protocol conformance.
    NSMutableDictionary<NSString*, XTClassDeclNode*>* byName = [NSMutableDictionary dictionary];
    for (XTClassDeclNode* c in designable)
        byName[c.className] = c;
    NSMutableArray<XTASTNode*>* newDecls = [ast.declarations mutableCopy];
    for (XTASTNode* d in synth.declarations)
        {
        if ([d isKindOfClass:[XTFunctionDeclNode class]])
            {
            XTFunctionDeclNode* fn = (XTFunctionDeclNode*)d;
            // Mark the registration function as a load-time constructor so the
            // backend emits it into the target constructor list.
            if ([fn.funcName isEqualToString:@"_xtc_nib_register"])
                fn.isModuleInit = YES;
            [newDecls addObject:d];
            }
        else if ([d isKindOfClass:[XTClassDeclNode class]])
            {
            XTClassDeclNode* sc = (XTClassDeclNode*)d;
            NSString* real = [sc.className stringByReplacingOccurrencesOfString:@"__xtc_synth_"
                                                                     withString:@""];
            XTClassDeclNode* rc = byName[real];
            if (!rc)
                continue;
            for (XTMethodDeclNode* m in sc.methods)
                [rc appendSynthesisedMethod:m];
            [rc appendProtocolConformance:protoName];
            }
        }
    return [[XTProgramNode alloc] initWithDeclarations:newDecls location:ast.location];
    }

@end
