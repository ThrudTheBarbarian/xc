#import "XTParser+Private.h"
#import "XTFunctionType.h"
#import "XTArrayType.h"

/****************************************************************************\
|* `callback` — the named spelling of a bound method (0.5).
|*
|* `^` is the old sigil form: `typedef void act_t(i32); act_t^ f;` — the type
|* has to be named by a typedef first, and the sigil binds to that name. The
|* new form mirrors `block` exactly, so THE NAME IS THE SECOND TOKEN and the
|* signature trails it:
|*
|*     callback f void(i32 sender);        // declaration
|*     f = &c.onClick;                     // bound method
|*     if (f) { f(3); }                    // auto-zeroed when the receiver dies
|*
|* This is NEW SYNTAX FOR AN EXISTING TYPE, not a new type. It ends in the same
|* `boundMethodTypeForSignature:` the sigil form ends in, and that interns by
|* signature — so `callback f void(i32)` and `act_t^ f` resolve to the SAME type
|* object. Nothing downstream changes: no sema rule, no lowering, no back end,
|* no ABI. The two spellings are interchangeable by construction, which is what
|* makes `^` keepable as a transitional form rather than a parallel system.
|*
|* `callback` is deliberately NOT a `block`. They have opposite ownership — a
|* block OWNS its captures, a callback never owns its receiver and auto-zeroes
|* when stored — and that difference is the reason both exist. See
|* private:docs/Design/bound-methods.md §7.
\****************************************************************************/

@implementation XTParser (Callbacks)

/****************************************************************************\
|* YES when the cursor begins a callback declaration: `callback` followed by
|* a type-start, or by an identifier (the declared name) then a type-start.
|*
|* Deliberately as narrow as blkKeywordAhead, and for the same reason: this is
|* a CONTEXTUAL keyword, so a program that already uses `callback` as an
|* ordinary identifier must keep working. `callback = 3;` and `foo(callback)`
|* are not declarations and must not be read as one.
\****************************************************************************/
- (BOOL)cbKeywordAhead
    {
    XTToken* cur = [self currentToken];
    if (cur.type != XTTokenIdentifier || ![cur.value isEqualToString:@"callback"])
        return NO;
    XTToken* t1 = [self peekToken:1];
    BOOL t1Type = t1.isTypeKeyword || t1.type == XTTokenVoid || [self.typeTable isTypeName:t1.value];
    if (t1Type)
        return YES;
    if (t1.type != XTTokenIdentifier)
        return NO;
    XTToken* t2 = [self peekToken:2];
    // `callback tbl[2] i32(i32)` — the array declarator sits between the name
    // and the signature, so the token after the name is `[`, not a type.
    if (t2.type == XTTokenLBracket)
        return YES;
    return t2.isTypeKeyword || t2.type == XTTokenVoid || [self.typeTable isTypeName:t2.value];
    }

/****************************************************************************\
|* Parse `callback [name] RET ( params )` from the keyword and return the
|* variable TYPE — the interned two-word {recv, code} bound-method struct.
|*
|* The declared name goes out through the same side channel the block header
|* uses (lastBlockDeclName). That is deliberate rather than lazy: the
|* declaration site's job is identical for both — take the name the header
|* found and bind it — so a second channel would be a second thing to keep in
|* step for no gain.
\****************************************************************************/
- (nullable XTType*)cbParseTypeHeader
    {
    XTSourceLocation* loc = [self currentLocation];
    [self advance]; // consume `callback`
    self.lastBlockDeclName = nil;

    // Held locally: the parseType calls below clear the side channel on entry,
    // so stamping it early would lose the name to our own recursion — the same
    // trap the block header documents.
    NSString* declName = nil;
    XTToken* maybeName = [self currentToken];
    if (maybeName.type == XTTokenIdentifier && ![self.typeTable isTypeName:maybeName.value] && !maybeName.isTypeKeyword)
        {
        declName = maybeName.value;
        [self advance];
        }

    // `callback tbl[2] i32(i32 n)` — an ARRAY of callbacks. The suffix binds
    // to the declared NAME, where a C declarator puts it, so it is read here
    // rather than after the signature.
    //
    // Without it the name-second header had no declarator slot at all, and an
    // array of callbacks could only be spelled with the `^` sigil — the
    // TRANSITIONAL form expressing something its replacement could not, which
    // is a thing that has to be false before `^` can be retired.
    BOOL isArray = NO;
    NSUInteger arrayCount = 0;
    if (declName && [self match:XTTokenLBracket])
        {
        isArray = YES;
        if (![self check:XTTokenRBracket])
            {
            XTASTNode* sizeExpr = [self parseExpression];
            arrayCount = [self resolveArraySizeExpr:sizeExpr];
            }
        [self expect:XTTokenRBracket];
        }

    XTType* ret = nil;
    if ([self check:XTTokenVoid] && [self peekToken:1].type == XTTokenLParen)
        {
        [self advance];
        ret = [XTType voidType];
        }
    else
        {
        ret = [self parseType];
        }
    if (!ret)
        return nil;

    if (![self match:XTTokenLParen])
        {
        [self.diagnostics emitError:@"expected '(' after a callback's return type"
                                 at:loc];
        return nil;
        }

    NSMutableArray<XTType*>* paramTypes = [NSMutableArray array];
    if ([self check:XTTokenVoid] && [self peekToken:1].type == XTTokenRParen)
        {
        [self advance]; // `(void)` — no params
        }
    else if (![self check:XTTokenRParen])
        {
        while (![self check:XTTokenRParen] && ![self check:XTTokenEOF])
            {
            // A trailing `...` — a VARIADIC callback (`callback void(u8* a0, ...)`,
            // the shape c2xc emits for a variadic C function pointer). A callback
            // is erased to a 2-word bound PAIR whatever its signature, and the xc
            // side only ever stores/forwards the handle (the C side does the
            // variadic call), so the marker adds nothing to the stored type: it
            // types exactly like its non-variadic prefix. Consume it and stop —
            // `...` is always last. The self-hosted parser does the same.
            if ([self match:XTTokenEllipsis])
                break;
            XTType* pt = [self parseType];
            if (!pt)
                return nil;
            // A parameter NAME is allowed and ignored, exactly as in the block
            // form: it is part of the contract a reader sees, not of the type.
            if ([self check:XTTokenIdentifier])
                [self advance];
            [paramTypes addObject:pt];
            if (![self match:XTTokenComma])
                break;
            }
        }
    [self expect:XTTokenRParen];

    XTFunctionType* fn = [XTFunctionType functionWithReturnTypes:@[ ret ]
                                                      paramTypes:paramTypes
                                                       isVarArgs:NO];
    self.lastBlockDeclName = declName;
    XTType* bm = [self boundMethodTypeForSignature:fn];
    if (bm && isArray)
        bm = [XTArrayType arrayOfType:bm count:arrayCount];
    return bm;
    }

@end
