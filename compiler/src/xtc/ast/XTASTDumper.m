#import "XTASTDumper.h"
#import "XTDeclNodes.h"
#import "XTStmtNodes.h"
#import "XTExprNodes.h"
#import "XTType.h"

// Operator spellings. The dump prints the SOURCE spelling of an operator rather
// than its enum value, because the two implementations share the language, not
// the enum: the xtc parser's own operator numbering is its business, and a
// spelling cannot drift silently the way two numberings can.
static NSString* binOpName(XTBinaryOp op)
    {
    switch (op)
        {
    case XTBinaryOpAdd:
        return @"+";
    case XTBinaryOpSub:
        return @"-";
    case XTBinaryOpMul:
        return @"*";
    case XTBinaryOpDiv:
        return @"/";
    case XTBinaryOpMod:
        return @"%";
    case XTBinaryOpBitAnd:
        return @"&";
    case XTBinaryOpBitOr:
        return @"|";
    case XTBinaryOpBitXor:
        return @"^";
    case XTBinaryOpShl:
        return @"<<";
    case XTBinaryOpShr:
        return @">>";
    case XTBinaryOpRol:
        return @"<:";
    case XTBinaryOpRor:
        return @":>";
    case XTBinaryOpLogAnd:
        return @"&&";
    case XTBinaryOpLogOr:
        return @"||";
    case XTBinaryOpEq:
        return @"==";
    case XTBinaryOpNeq:
        return @"!=";
    case XTBinaryOpLt:
        return @"<";
    case XTBinaryOpGt:
        return @">";
    case XTBinaryOpLe:
        return @"<=";
    case XTBinaryOpGe:
        return @">=";
        }
    return @"?";
    }

static NSString* unOpName(XTUnaryOp op)
    {
    switch (op)
        {
    case XTUnaryOpNeg:
        return @"-";
    case XTUnaryOpBitNot:
        return @"~";
    case XTUnaryOpLogNot:
        return @"!";
    case XTUnaryOpAddrOf:
        return @"&";
    case XTUnaryOpDeref:
        return @"*";
    case XTUnaryOpPreInc:
        return @"++";
    case XTUnaryOpPreDec:
        return @"--";
    case XTUnaryOpLoByte:
        return @"<";
    case XTUnaryOpHiByte:
        return @">";
    case XTUnaryOpByte2:
        return @">>";
    case XTUnaryOpByte3:
        return @">>>";
        }
    return @"?";
    }

static NSString* assignOpName(XTAssignOp op)
    {
    switch (op)
        {
    case XTAssignOpAssign:
        return @"=";
    case XTAssignOpAdd:
        return @"+=";
    case XTAssignOpSub:
        return @"-=";
    case XTAssignOpMul:
        return @"*=";
    case XTAssignOpDiv:
        return @"/=";
    case XTAssignOpMod:
        return @"%=";
    case XTAssignOpBitAnd:
        return @"&=";
    case XTAssignOpBitOr:
        return @"|=";
    case XTAssignOpBitXor:
        return @"^=";
    case XTAssignOpShl:
        return @"<<=";
    case XTAssignOpShr:
        return @">>=";
    case XTAssignOpRol:
        return @"<:=";
    case XTAssignOpRor:
        return @":>=";
        }
    return @"?";
    }

// A type as the SOURCE spells it. `displayName` is what the type table built
// from the declaration, so `u16@` comes back as "u16@" — which is exactly what
// the xtc parser records verbatim, since it does no type resolution.
static NSString* typeName(XTType* t)
    {
    return t ? (t.displayName ?: @"?") : @"-";
    }

// Escape a value that goes into a field: one node is one line, and a string
// literal may contain anything at all.
static NSString* esc(NSString* s)
    {
    if (!s)
        return @"-";
    NSData* utf8 = [s dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char* b = utf8.bytes;
    NSMutableString* out = [NSMutableString stringWithCapacity:s.length + 4];
    for (NSUInteger i = 0; i < utf8.length; i++)
        {
        unsigned c = b[i];
        switch (c)
            {
        case '\\':
            [out appendString:@"\\\\"];
            break;
        case '\n':
            [out appendString:@"\\n"];
            break;
        case '\t':
            [out appendString:@"\\t"];
            break;
        case '\r':
            [out appendString:@"\\r"];
            break;
        case ' ':
            [out appendString:@"\\s"];
            break;
        default:
            if (c < 32 || c > 126)
                [out appendFormat:@"\\x%02X", c];
            else
                [out appendFormat:@"%c", (char)c];
            }
        }
    return out;
    }

// ── Sema annotations ────────────────────────────────────────────────────────
//
// The M6 oracle. Everything below is stamped onto the tree by the semantic
// analyser, never by the parser, so it appears only in --dump-sema output —
// selfhost/tools/sema-diff.sh compares that, and ast-diff.sh keeps comparing
// the parser-only form. Both come out of ONE walk so the two formats cannot
// drift apart: the annotation is spliced onto the end of a node's first line,
// which is why no case below has to know about it.
//
// What goes in is what a later stage READS: resolved types, the symbol a call
// resolved to, virtual slots, inferred storage. What stays out is anything
// derived (a type's byte width — that is the backend's business) or
// order-dependent (symbol-table identity).
static BOOL sDumpSema = NO;

static NSString* semaAnnotation(XTASTNode* node)
    {
    if (!sDumpSema || !node)
        return @"";
    NSMutableString* a = [NSMutableString string];
    if (node.resolvedType)
        [a appendFormat:@" ty=%@", typeName(node.resolvedType)];

    switch (node.nodeKind)
        {
    case XTASTNodeKindCallExpr:
        {
        XTCallExprNode* n = (XTCallExprNode*)node;
        if (n.resolvedMangledName)
            [a appendFormat:@" sym=%@", n.resolvedMangledName];
        if (n.isIndirectCall)
            [a appendString:@" indirect=1"];
        if (n.isBoundCall)
            [a appendString:@" bound=1"];
        break;
        }
    case XTASTNodeKindMethodCallExpr:
        {
        XTMethodCallExprNode* n = (XTMethodCallExprNode*)node;
        if (n.resolvedMangledName)
            [a appendFormat:@" sym=%@", n.resolvedMangledName];
        if (n.resolvedClassName)
            [a appendFormat:@" cls=%@", n.resolvedClassName];
        if (n.resolvedVirtualSlot)
            [a appendFormat:@" vslot=%@", n.resolvedVirtualSlot];
        if (n.resolvedProtocolName)
            [a appendFormat:@" proto=%@", n.resolvedProtocolName];
        if (n.resolvedProtocolIndex)
            [a appendFormat:@" protoidx=%@", n.resolvedProtocolIndex];
        break;
        }
    case XTASTNodeKindNewExpr:
        {
        XTNewExprNode* n = (XTNewExprNode*)node;
        if (n.resolvedInitMangledName)
            [a appendFormat:@" init=%@", n.resolvedInitMangledName];
        break;
        }
    case XTASTNodeKindMemberAccess:
        {
        XTMemberAccessNode* n = (XTMemberAccessNode*)node;
        // resolvedGetterMethod / resolvedBoundMethod hold the resolved DECL
        // node; its mangled name is the comparable fact, not the object.
        XTMethodDeclNode* g = (XTMethodDeclNode*)n.resolvedGetterMethod;
        if (g.mangledName)
            [a appendFormat:@" get=%@", g.mangledName];
        if (n.resolvedGetterClass)
            [a appendFormat:@" getcls=%@", n.resolvedGetterClass];
        XTMethodDeclNode* b = (XTMethodDeclNode*)n.resolvedBoundMethod;
        if (b.mangledName)
            [a appendFormat:@" bound=%@", b.mangledName];
        if (n.resolvedBoundClass)
            [a appendFormat:@" boundcls=%@", n.resolvedBoundClass];
        if (n.resolvedBoundSlot)
            [a appendFormat:@" boundslot=%@", n.resolvedBoundSlot];
        if (n.resolvedBoundProtocol)
            [a appendFormat:@" boundproto=%@", n.resolvedBoundProtocol];
        if (n.resolvedBoundProtoIndex)
            [a appendFormat:@" boundprotoidx=%@", n.resolvedBoundProtoIndex];
        break;
        }
    case XTASTNodeKindAssignExpr:
        {
        XTAssignExprNode* n = (XTAssignExprNode*)node;
        if (n.resolvedSetterName)
            [a appendFormat:@" set=%@", n.resolvedSetterName];
        if (n.resolvedSetterClass)
            [a appendFormat:@" setcls=%@", n.resolvedSetterClass];
        break;
        }
    case XTASTNodeKindFunctionDecl:
        {
        XTFunctionDeclNode* n = (XTFunctionDeclNode*)node;
        if (n.mangledName)
            [a appendFormat:@" sym=%@", n.mangledName];
        break;
        }
    case XTASTNodeKindMethodDecl:
        {
        XTMethodDeclNode* n = (XTMethodDeclNode*)node;
        if (n.mangledName)
            [a appendFormat:@" sym=%@", n.mangledName];
        if (n.hasHeapReceiver)
            [a appendString:@" heaprecv=1"];
        if (n.hasNonHeapReceiver)
            [a appendString:@" stackrecv=1"];
        if (n.autoSuperInit)
            [a appendString:@" autosuperinit=1"];
        break;
        }
    case XTASTNodeKindClassDecl:
        {
        XTClassDeclNode* n = (XTClassDeclNode*)node;
        if (n.usedByNew)
            [a appendString:@" usedbynew=1"];
        if (n.vtableSlotSymbols.count)
            [a appendFormat:@" vslots=%lu",
                            (unsigned long)n.vtableSlotSymbols.count];
        // Sorted by SLOT, then name — a dictionary's own order is not a fact
        // about the program and would make the dump non-deterministic.
        if (n.vtableMethodSlots.count)
            {
            NSArray* keys = [n.vtableMethodSlots.allKeys sortedArrayUsingComparator:
                                                             ^NSComparisonResult(NSString* x, NSString* y) {
                                                               NSComparisonResult c = [n.vtableMethodSlots[x] compare:n.vtableMethodSlots[y]];
                                                               return c == NSOrderedSame ? [x compare:y] : c;
                                                             }];
            [a appendString:@" slots=["];
            for (NSUInteger i = 0; i < keys.count; i++)
                {
                if (i)
                    [a appendString:@","];
                [a appendFormat:@"%@:%@", keys[i], n.vtableMethodSlots[keys[i]]];
                }
            [a appendString:@"]"];
            }
        if (n.vtableSymbolSlots.count)
            {
            NSArray* keys = [n.vtableSymbolSlots.allKeys sortedArrayUsingComparator:
                                                             ^NSComparisonResult(NSString* x, NSString* y) {
                                                               NSComparisonResult c = [n.vtableSymbolSlots[x] compare:n.vtableSymbolSlots[y]];
                                                               return c == NSOrderedSame ? [x compare:y] : c;
                                                             }];
            [a appendString:@" syms=["];
            for (NSUInteger i = 0; i < keys.count; i++)
                {
                if (i)
                    [a appendString:@","];
                [a appendFormat:@"%@:%@", keys[i], n.vtableSymbolSlots[keys[i]]];
                }
            [a appendString:@"]"];
            }
        break;
        }
    default:
        break;
        }
    return a;
    }

@implementation XTASTDumper

+ (NSString*)dump:(XTASTNode*)node
    {
    NSMutableString* out = [NSMutableString string];
    sDumpSema = NO;
    [self emit:node into:out indent:0];
    return out;
    }

+ (NSString*)dumpWithSema:(XTASTNode*)node
    {
    NSMutableString* out = [NSMutableString string];
    sDumpSema = YES;
    [self emit:node into:out indent:0];
    sDumpSema = NO;
    return out;
    }

+ (void)line:(NSString*)text into:(NSMutableString*)out indent:(NSUInteger)ind
    {
    for (NSUInteger i = 0; i < ind; i++)
        [out appendString:@"  "];
    [out appendString:text];
    [out appendString:@"\n"];
    }

+ (void)emitChildren:(NSArray*)kids into:(NSMutableString*)out indent:(NSUInteger)ind
    {
    for (XTASTNode* k in kids)
        [self emit:k into:out indent:ind];
    }

+ (void)emit:(XTASTNode*)node into:(NSMutableString*)out indent:(NSUInteger)ind
    {
    if (!node)
        return;
    // Where this node's own first line begins. In --dump-sema mode the
    // annotation is spliced onto the end of it once the switch has run, so
    // every case stays exactly as the parser oracle wrote it.
    NSUInteger lineStart = out.length;
    [self emitNode:node into:out indent:ind];
    if (!sDumpSema)
        return;
    NSString* ann = semaAnnotation(node);
    if (!ann.length || lineStart >= out.length)
        return;
    NSRange nl = [out rangeOfString:@"\n"
                            options:0
                              range:NSMakeRange(lineStart, out.length - lineStart)];
    if (nl.location != NSNotFound)
        [out insertString:ann atIndex:nl.location];
    }

+ (void)emitNode:(XTASTNode*)node into:(NSMutableString*)out indent:(NSUInteger)ind
    {
    if (!node)
        return;
    switch (node.nodeKind)
        {

    // ── Declarations ────────────────────────────────────────────────────────
    case XTASTNodeKindProgram:
        {
        XTProgramNode* n = (XTProgramNode*)node;
        [self line:@"Program" into:out indent:ind];
        [self emitChildren:n.declarations into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindFunctionDecl:
        {
        XTFunctionDeclNode* n = (XTFunctionDeclNode*)node;
        NSMutableString* rets = [NSMutableString string];
        for (XTType* t in n.returnTypes)
            {
            if (rets.length)
                [rets appendString:@","];
            [rets appendString:typeName(t)];
            }
        [self line:[NSString stringWithFormat:@"FunctionDecl name=%@ ret=%@ varargs=%d throws=%d",
                                              esc(n.funcName), rets.length ? rets : @"-", n.isVarArgs ? 1 : 0,
                                              n.throwsError ? 1 : 0]
              into:out
            indent:ind];
        [self emitChildren:n.parameters into:out indent:ind + 1];
        [self emit:n.body into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindParam:
        {
        XTParamNode* n = (XTParamNode*)node;
        [self line:[NSString stringWithFormat:@"Param name=%@ type=%@",
                                              esc(n.paramName), typeName(n.paramType)]
              into:out
            indent:ind];
        break;
        }
    case XTASTNodeKindVariableDecl:
        {
        XTVariableDeclNode* n = (XTVariableDeclNode*)node;
        [self line:[NSString stringWithFormat:
                                 @"VariableDecl name=%@ type=%@ static=%d global=%d extern=%d volatile=%d register=%d",
                                 esc(n.varName), typeName(n.declaredType), n.isStatic ? 1 : 0,
                                 n.isGlobal ? 1 : 0, n.isExternalGlobal ? 1 : 0, n.isVolatile ? 1 : 0,
                                 n.isRegister ? 1 : 0]
              into:out
            indent:ind];
        [self emit:n.initialiser into:out indent:ind + 1];
        [self emitChildren:n.constructorArgs into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindStructDecl:
        {
        XTStructDeclNode* n = (XTStructDeclNode*)node;
        // packed only when SET — golden dumps of unpacked structs unchanged.
        [self line:[NSString stringWithFormat:@"StructDecl name=%@%@", esc(n.structName),
                                              n.isPacked ? @" packed=1" : @""]
              into:out
            indent:ind];
        [self emitChildren:n.fields into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindTypedefDecl:
        {
        XTTypedefNode* n = (XTTypedefNode*)node;
        [self line:[NSString stringWithFormat:@"TypedefDecl name=%@ type=%@",
                                              esc(n.aliasName), typeName(n.targetType)]
              into:out
            indent:ind];
        break;
        }
    case XTASTNodeKindEnumDecl:
        {
        XTEnumDeclNode* n = (XTEnumDeclNode*)node;
        [self line:[NSString stringWithFormat:@"EnumDecl name=%@", esc(n.enumName)]
              into:out
            indent:ind];
        [self emitChildren:n.members into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindEnumMember:
        {
        XTEnumMemberNode* n = (XTEnumMemberNode*)node;
        [self line:[NSString stringWithFormat:@"EnumMember name=%@ value=%@",
                                              esc(n.memberName),
                                              n.explicitValue ? n.explicitValue.stringValue : @"-"]
              into:out
            indent:ind];
        break;
        }
    case XTASTNodeKindUseDecl:
        {
        XTUseDeclNode* n = (XTUseDeclNode*)node;
        [self line:[NSString stringWithFormat:@"UseDecl name=%@", esc(n.className)]
              into:out
            indent:ind];
        break;
        }
    case XTASTNodeKindClassDecl:
        {
        XTClassDeclNode* n = (XTClassDeclNode*)node;
        NSString* protos = n.protocolNames.count
                               ? [n.protocolNames componentsJoinedByString:@","]
                               : @"-";
        [self line:[NSString stringWithFormat:@"ClassDecl name=%@ super=%@ protocols=%@",
                                              esc(n.className), esc(n.parentName ?: @"-"), esc(protos)]
              into:out
            indent:ind];
        [self emitChildren:n.ivars into:out indent:ind + 1];
        [self emitChildren:n.methods into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindProtocolDecl:
        {
        XTProtocolDeclNode* n = (XTProtocolDeclNode*)node;
        [self line:[NSString stringWithFormat:@"ProtocolDecl name=%@", esc(n.protocolName)]
              into:out
            indent:ind];
        [self emitChildren:n.methods into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindMethodDecl:
        {
        XTMethodDeclNode* n = (XTMethodDeclNode*)node;
        NSMutableString* rets = [NSMutableString string];
        for (XTType* t in n.returnTypes)
            {
            if (rets.length)
                [rets appendString:@","];
            [rets appendString:typeName(t)];
            }
        // `since` prints only when set, so every pre-0.4 dump byte-matches.
        [self line:[NSString stringWithFormat:
                                 @"MethodDecl name=%@ ret=%@ static=%d varargs=%d throws=%d optional=%d final=%d%@",
                                 esc(n.methodName), rets.length ? rets : @"-", n.isStatic ? 1 : 0,
                                 n.isVarArgs ? 1 : 0, n.throwsError ? 1 : 0, n.isOptional ? 1 : 0,
                                 n.isFinal ? 1 : 0,
                                 n.sinceVersion.length
                                     ? [NSString stringWithFormat:@" since=%@", n.sinceVersion]
                                     : @""]
              into:out
            indent:ind];
        [self emitChildren:n.parameters into:out indent:ind + 1];
        [self emit:n.body into:out indent:ind + 1];
        break;
        }

    // ── Statements ──────────────────────────────────────────────────────────
    case XTASTNodeKindBlock:
        {
        XTBlockNode* n = (XTBlockNode*)node;
        [self line:@"Block" into:out indent:ind];
        [self emitChildren:n.statements into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindIf:
        {
        XTIfNode* n = (XTIfNode*)node;
        [self line:@"If" into:out indent:ind];
        [self emit:n.condition into:out indent:ind + 1];
        [self emit:n.thenBlock into:out indent:ind + 1];
        [self emit:n.elseBlock into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindWhile:
        {
        XTWhileNode* n = (XTWhileNode*)node;
        [self line:@"While" into:out indent:ind];
        [self emit:n.condition into:out indent:ind + 1];
        [self emit:n.body into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindForCStyle:
        {
        XTForCStyleNode* n = (XTForCStyleNode*)node;
        [self line:@"ForCStyle" into:out indent:ind];
        [self line:@"init" into:out indent:ind + 1];
        [self emit:n.loopInit into:out indent:ind + 2];
        [self line:@"cond" into:out indent:ind + 1];
        [self emit:n.condition into:out indent:ind + 2];
        [self line:@"step" into:out indent:ind + 1];
        [self emit:n.increment into:out indent:ind + 2];
        [self emit:n.body into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindForIn:
        {
        XTForInNode* n = (XTForInNode*)node;
        [self line:@"ForIn" into:out indent:ind];
        [self emit:n.loopVar into:out indent:ind + 1];
        [self emit:n.collection into:out indent:ind + 1];
        [self emit:n.body into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindReturn:
        {
        XTReturnNode* n = (XTReturnNode*)node;
        [self line:@"Return" into:out indent:ind];
        [self emitChildren:n.values into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindBreak:
        [self line:@"Break" into:out indent:ind];
        break;
    case XTASTNodeKindContinue:
        [self line:@"Continue" into:out indent:ind];
        break;
    case XTASTNodeKindSwitch:
        {
        XTSwitchNode* n = (XTSwitchNode*)node;
        [self line:@"Switch" into:out indent:ind];
        [self emit:n.subject into:out indent:ind + 1];
        for (XTSwitchCase* c in n.cases)
            {
            [self line:[NSString stringWithFormat:@"Case default=%d", c.isDefault ? 1 : 0]
                  into:out
                indent:ind + 1];
            for (XTCaseLabel* l in c.labels)
                {
                [self line:[NSString stringWithFormat:@"Label range=%d", l.isRange ? 1 : 0]
                      into:out
                    indent:ind + 2];
                [self emit:l.singleValue into:out indent:ind + 3];
                [self emit:l.rangeLo into:out indent:ind + 3];
                [self emit:l.rangeHi into:out indent:ind + 3];
                }
            [self emitChildren:c.body into:out indent:ind + 2];
            }
        break;
        }
    case XTASTNodeKindAsmBlock:
        {
        XTAsmBlockNode* n = (XTAsmBlockNode*)node;
        [self line:[NSString stringWithFormat:@"AsmBlock lines=%lu",
                                              (unsigned long)n.lines.count]
              into:out
            indent:ind];
        for (NSString* l in n.lines)
            [self line:[NSString stringWithFormat:@"AsmLine %@", esc(l)]
                  into:out
                indent:ind + 1];
        break;
        }
    case XTASTNodeKindExprStatement:
        {
        XTExpressionStatementNode* n = (XTExpressionStatementNode*)node;
        [self line:@"ExprStatement" into:out indent:ind];
        [self emit:n.expression into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindTupleAssign:
        {
        XTTupleAssignNode* n = (XTTupleAssignNode*)node;
        [self line:@"TupleAssign" into:out indent:ind];
        [self emitChildren:n.targets into:out indent:ind + 1];
        [self emit:n.sourceExpr into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindDelete:
        {
        XTDeleteNode* n = (XTDeleteNode*)node;
        [self line:[NSString stringWithFormat:@"Delete op=%ld", (long)n.op]
              into:out
            indent:ind];
        [self emit:n.operand into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindDefer:
        {
        XTDeferNode* n = (XTDeferNode*)node;
        [self line:@"Defer" into:out indent:ind];
        [self emit:n.body into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindThrow:
        {
        XTThrowNode* n = (XTThrowNode*)node;
        [self line:@"Throw" into:out indent:ind];
        [self emit:n.operand into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindTry:
        {
        XTTryNode* n = (XTTryNode*)node;
        [self line:@"Try" into:out indent:ind];
        [self emit:n.tryBlock into:out indent:ind + 1];
        for (XTCatchClause* c in n.catchClauses)
            {
            [self line:[NSString stringWithFormat:@"Catch type=%@ var=%@",
                                                  esc(c.typeName ?: @"-"), esc(c.varName)]
                  into:out
                indent:ind + 1];
            [self emit:c.block into:out indent:ind + 2];
            }
        break;
        }

    // ── Expressions ─────────────────────────────────────────────────────────
    case XTASTNodeKindBinaryExpr:
        {
        XTBinaryExprNode* n = (XTBinaryExprNode*)node;
        [self line:[NSString stringWithFormat:@"Binary op=%@", binOpName(n.op)]
              into:out
            indent:ind];
        [self emit:n.left into:out indent:ind + 1];
        [self emit:n.right into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindUnaryExpr:
        {
        XTUnaryExprNode* n = (XTUnaryExprNode*)node;
        [self line:[NSString stringWithFormat:@"Unary op=%@", unOpName(n.op)]
              into:out
            indent:ind];
        [self emit:n.operand into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindPostfixExpr:
        {
        XTPostfixExprNode* n = (XTPostfixExprNode*)node;
        [self line:[NSString stringWithFormat:@"Postfix op=%@",
                                              n.postfixOp == XTPostfixOpInc ? @"++" : @"--"]
              into:out
            indent:ind];
        [self emit:n.operand into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindAssignExpr:
        {
        XTAssignExprNode* n = (XTAssignExprNode*)node;
        [self line:[NSString stringWithFormat:@"Assign op=%@", assignOpName(n.assignOp)]
              into:out
            indent:ind];
        [self emit:n.lhs into:out indent:ind + 1];
        [self emit:n.rhs into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindCallExpr:
        {
        XTCallExprNode* n = (XTCallExprNode*)node;
        [self line:[NSString stringWithFormat:@"Call name=%@ args=%lu",
                                              esc(n.calleeName), (unsigned long)n.arguments.count]
              into:out
            indent:ind];
        [self emitChildren:n.arguments into:out indent:ind + 1];
        // The callee EXPRESSION, when the callee is not a name, prints AFTER
        // the arguments — which is where the ported parser keeps it (the last
        // kid), so the two dumps stay identical. private:docs/bugs/074.
        if (n.calleeExpr)
            [self emit:n.calleeExpr into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindMethodCallExpr:
        {
        XTMethodCallExprNode* n = (XTMethodCallExprNode*)node;
        [self line:[NSString stringWithFormat:@"MethodCall name=%@ args=%lu",
                                              esc(n.methodName), (unsigned long)n.arguments.count]
              into:out
            indent:ind];
        [self emit:n.receiver into:out indent:ind + 1];
        [self emitChildren:n.arguments into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindSubscriptExpr:
        {
        XTSubscriptExprNode* n = (XTSubscriptExprNode*)node;
        [self line:@"Subscript" into:out indent:ind];
        [self emit:n.base into:out indent:ind + 1];
        [self emit:n.index into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindSliceExpr:
        {
        XTSliceExprNode* n = (XTSliceExprNode*)node;
        [self line:[NSString stringWithFormat:@"Slice inclusive=%d", n.inclusive ? 1 : 0]
              into:out
            indent:ind];
        [self emit:n.base into:out indent:ind + 1];
        [self emit:n.startExpr into:out indent:ind + 1];
        [self emit:n.endExpr into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindRangeExpr:
        {
        XTRangeExprNode* n = (XTRangeExprNode*)node;
        [self line:[NSString stringWithFormat:@"Range inclusive=%d", n.inclusive ? 1 : 0]
              into:out
            indent:ind];
        [self emit:n.startExpr into:out indent:ind + 1];
        [self emit:n.endExpr into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindMemberAccess:
        {
        XTMemberAccessNode* n = (XTMemberAccessNode*)node;
        [self line:[NSString stringWithFormat:@"Member name=%@ arrow=%d",
                                              esc(n.memberName), n.isArrow ? 1 : 0]
              into:out
            indent:ind];
        [self emit:n.base into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindTernaryExpr:
        {
        XTTernaryExprNode* n = (XTTernaryExprNode*)node;
        [self line:@"Ternary" into:out indent:ind];
        [self emit:n.condition into:out indent:ind + 1];
        [self emit:n.thenExpr into:out indent:ind + 1];
        [self emit:n.elseExpr into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindCastExpr:
        {
        XTCastExprNode* n = (XTCastExprNode*)node;
        [self line:[NSString stringWithFormat:@"Cast type=%@ failable=%d",
                                              typeName(n.castType), n.isFailable ? 1 : 0]
              into:out
            indent:ind];
        [self emit:n.operand into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindIdentifier:
        {
        XTIdentifierNode* n = (XTIdentifierNode*)node;
        [self line:[NSString stringWithFormat:@"Ident %@", esc(n.identName)]
              into:out
            indent:ind];
        break;
        }
    case XTASTNodeKindLiteralInt:
        {
        XTLiteralIntNode* n = (XTLiteralIntNode*)node;
        [self line:[NSString stringWithFormat:@"Int %lld", (long long)n.intValue]
              into:out
            indent:ind];
        break;
        }
    case XTASTNodeKindLiteralFloat:
        {
        // The literal's IEEE-754 bytes as hex, little-endian — 8 for a double,
        // 4 for a single. The node keeps no source text (the lexer converts at
        // lex time), so this is what there is to compare, and it is the
        // strictest form: a differing rounding shows up immediately.
        XTLiteralFloatNode* n = (XTLiteralFloatNode*)node;
        NSMutableString* hex = [NSMutableString string];
        const unsigned char* fb = n.floatData.bytes;
        for (NSUInteger i = 0; i < n.floatData.length; i++)
            [hex appendFormat:@"%02X", fb[i]];
        [self line:[NSString stringWithFormat:@"Float %@", hex.length ? hex : @"-"]
              into:out
            indent:ind];
        break;
        }
    case XTASTNodeKindLiteralString:
        {
        XTLiteralStringNode* n = (XTLiteralStringNode*)node;
        [self line:[NSString stringWithFormat:@"Str %@", esc(n.stringValue)]
              into:out
            indent:ind];
        break;
        }
    case XTASTNodeKindLiteralChar:
        {
        XTLiteralCharNode* n = (XTLiteralCharNode*)node;
        [self line:[NSString stringWithFormat:@"Char %d", (int)n.charValue]
              into:out
            indent:ind];
        break;
        }
    case XTASTNodeKindLiteralBool:
        {
        XTLiteralBoolNode* n = (XTLiteralBoolNode*)node;
        [self line:[NSString stringWithFormat:@"Bool %d", n.boolValue ? 1 : 0]
              into:out
            indent:ind];
        break;
        }
    case XTASTNodeKindNewExpr:
        {
        XTNewExprNode* n = (XTNewExprNode*)node;
        [self line:[NSString stringWithFormat:@"New type=%@ args=%lu",
                                              esc(n.className), (unsigned long)n.arguments.count]
              into:out
            indent:ind];
        [self emit:n.countExpr into:out indent:ind + 1];
        [self emitChildren:n.arguments into:out indent:ind + 1];
        break;
        }
    case XTASTNodeKindSizeofExpr:
        {
        // The operand is EITHER a type or an expression, so the dump says
        // which: `sizeof(u16@)` and `sizeof(p)` are different questions.
        XTSizeofExprNode* n = (XTSizeofExprNode*)node;
        if ([n.operand isKindOfClass:[XTType class]])
            {
            [self line:[NSString stringWithFormat:@"Sizeof type=%@", typeName(n.operand)]
                  into:out
                indent:ind];
            }
        else
            {
            [self line:@"Sizeof type=-" into:out indent:ind];
            [self emit:n.operand into:out indent:ind + 1];
            }
        break;
        }

    default:
        [self line:[NSString stringWithFormat:@"Unknown kind=%ld", (long)node.nodeKind]
              into:out
            indent:ind];
        break;
        }
    }

@end
