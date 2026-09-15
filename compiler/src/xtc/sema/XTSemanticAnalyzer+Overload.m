/****************************************************************************\
|* XTSemanticAnalyzer+Overload.m
\****************************************************************************/
#import "XTSemanticAnalyzer+Private.h"

/****************************************************************************\
|* The element type of a typed collection receiver — the `String` in
|* `Array<String>* a`. nil for everything else, which is the common case and
|* costs one field read.
\****************************************************************************/
static XTType* XTCollectionElementOf(XTType* recvType)
    {
    XTType* carrier = nil;
    if ([recvType isKindOfClass:[XTPointerType class]])
        {
        carrier = ((XTPointerType*)recvType).pointeeType;
        }
    else if (recvType && recvType.kind == XTTypeKindClass)
        {
        carrier = recvType;
        }
    return carrier.collectionElementType;
    }

/****************************************************************************\
|* YES for `Object*` — the erased element type a container's signature uses.
|* That spelling is what a typed collection substitutes AWAY: it is the only
|* thing in a container's interface that means "whatever you put in".
\****************************************************************************/
static BOOL XTIsErasedElementType(XTType* t)
    {
    if (![t isKindOfClass:[XTPointerType class]])
        return NO;
    XTType* pointee = ((XTPointerType*)t).pointeeType;
    return pointee && pointee.kind == XTTypeKindClass && [pointee.displayName isEqualToString:@"Object"];
    }

/****************************************************************************\
|* The KEY of a two-argument collection — the `K` in `Map<K, V>`, or nil.
\****************************************************************************/
static XTType* XTCollectionKeyOf(XTType* recvType)
    {
    XTType* carrier = nil;
    if ([recvType isKindOfClass:[XTPointerType class]])
        {
        carrier = ((XTPointerType*)recvType).pointeeType;
        }
    else if (recvType && recvType.kind == XTTypeKindClass)
        {
        carrier = recvType;
        }
    return carrier.collectionKeyType;
    }

/****************************************************************************\
|* YES for `Hashable*` — what a keyed container's signature erases its KEY to,
|* the way `Object*` erases its value. Checked only when a second type argument
|* was actually written: `Map<V>` and `Set<T>` leave these positions alone, so
|* neither changes meaning. private:docs/bugs/049.
\****************************************************************************/
static BOOL XTIsErasedKeyType(XTType* t)
    {
    if (![t isKindOfClass:[XTPointerType class]])
        return NO;
    XTType* pointee = ((XTPointerType*)t).pointeeType;
    return pointee && pointee.kind == XTTypeKindClass && [pointee.displayName isEqualToString:@"Hashable"];
    }

@implementation XTSemanticAnalyzer (Overload)

#pragma mark - Overload Resolution

/****************************************************************************\
|* Returns a conversion rank for matching `argType` against `paramType`,
|* or NSIntegerMax if no conversion exists. Lower is better.
|* `litFits` is YES when the argument is an integer literal whose value
|* fits the paramType — that promotes the pair to rank 1.
\****************************************************************************/
- (NSInteger)conversionRankFrom:(XTType*)argType
                             to:(XTType*)paramType
                       isIntLit:(BOOL)isIntLit
                       litValue:(int64_t)litValue
    {
    if (!argType || !paramType)
        return NSIntegerMax;
    if (argType.kind == paramType.kind)
        {
        // PR4 upcast check: two class-typed values at the same kind
        // slot still need a hierarchy check — unrelated classes
        // mustn't implicitly convert even though their `kind` bit
        // matches. PR9: typed pointer pairs also need pointee
        // inspection so class-pointer mismatches (and protocol-
        // constraint violations) get rejected here. The generic
        // `pointer` type (plain XTType with kind=Pointer, no
        // pointee) keeps the scalar same-kind shortcut; scalar
        // same-kind pairs do too.
        if (argType.kind != XTTypeKindClass)
            {
            BOOL bothTypedPointers =
                [argType isKindOfClass:[XTPointerType class]] &&
                [paramType isKindOfClass:[XTPointerType class]];
            if (!bothTypedPointers)
                return 0;
            }
        }
    // `string` and `u8@` are interchangeable — both are pointer-to-u8.
    if (argType.kind == XTTypeKindPointer && paramType.kind == XTTypeKindPointer)
        {
        XTType* a = ((XTPointerType*)argType).pointeeType;
        XTType* b = ((XTPointerType*)paramType).pointeeType;
        // PR4: class-pointer compatibility — exact match is rank 0,
        // upcast (RHS descendant of LHS) is rank 1 so exact still
        // wins in overload resolution, unrelated classes are
        // rejected. Non-class pointers keep the pre-PR4 kind
        // equality rule.
        if (a.kind == XTTypeKindClass && b.kind == XTTypeKindClass)
            {
            // PR9: if the destination carries a protocol constraint
            // (a `Proto@` parameter), accept any argument whose class
            // (or an ancestor) conforms to the protocol. Otherwise
            // fall through to the PR4 exact-name / upcast rule.
            NSString* destProto = b.protocolConstraint;
            if (destProto.length > 0)
                {
                // The argument is ALSO the same protocol type (`P@` → `P@`) — e.g.
                // forwarding a protocol-typed parameter, as `super.m(p)` does.
                // classesByName has no entry for a protocol NAME, so the class-
                // conformance lookup below would wrongly reject it; accept an exact
                // protocol match directly.
                NSString* argProto = a.protocolConstraint.length ? a.protocolConstraint
                                                                 : a.displayName;
                if ([argProto isEqualToString:destProto])
                    return 0;
                XTClassDeclNode* argCls = self.classesByName[a.displayName];
                if (argCls && [self class:argCls conformsToProtocol:destProto])
                    {
                    return 1;
                    }
                return NSIntegerMax;
                }
            if ([a.displayName isEqualToString:b.displayName])
                return 0;
            XTClassDeclNode* argCls = self.classesByName[a.displayName];
            XTClassDeclNode* parCls = self.classesByName[b.displayName];
            if (argCls && parCls &&
                [self class:argCls
                    inheritsFromOrEquals:parCls])
                {
                return 1;
                }
            return NSIntegerMax;
            }
        if (a.kind == b.kind)
            return 0;
        if (a.kind == XTTypeKindVoid || b.kind == XTTypeKindVoid)
            return 5;
        return NSIntegerMax;
        }
    // Bare class value (stack-instance) → same check as the pointer
    // form above. Unrelated class names can't silently alias.
    if (argType.kind == XTTypeKindClass && paramType.kind == XTTypeKindClass)
        {
        if ([argType.displayName isEqualToString:paramType.displayName])
            return 0;
        XTClassDeclNode* argCls = self.classesByName[argType.displayName];
        XTClassDeclNode* parCls = self.classesByName[paramType.displayName];
        if (argCls && parCls &&
            [self class:argCls
                inheritsFromOrEquals:parCls])
            {
            return 1;
            }
        return NSIntegerMax;
        }
    if (argType.kind == XTTypeKindBool && (paramType.kind == XTTypeKindU8 ||
                                           paramType.kind == XTTypeKindI8))
        return 1;
    if (argType.kind == XTTypeKindEnum && (paramType.kind == XTTypeKindU8 ||
                                           paramType.kind == XTTypeKindU16 || paramType.kind == XTTypeKindU32 ||
                                           paramType.kind == XTTypeKindI8 || paramType.kind == XTTypeKindI16 ||
                                           paramType.kind == XTTypeKindI32))
        return 1;
    // The REVERSE: an integer argument into an ENUM-typed parameter. An enum
    // CONSTANT resolves as u8 (that is how the members register), so without
    // this the natural call — `withEncodedBytes(b, n, ENC_UTF8)` — scored
    // no-match the moment the callee was overloaded, while the same argument
    // sailed through a non-overloaded call. u8 is the enum's own width, so it
    // converts at the same rank the enum→int direction already gets; an
    // in-range literal likewise. Wider integers still need a cast, which is
    // the honest place for a real narrowing.
    if (paramType.kind == XTTypeKindEnum)
        {
        if (argType.kind == XTTypeKindU8)
            return 1;
        if (isIntLit && litValue >= 0 && litValue <= 0xFF)
            return 1;
        }

    // Integer literal: fits any integer type big enough. Prefer the
    // smallest fitting type by giving a rank that grows with width.
    if (isIntLit)
        {
        NSInteger widthRank = NSIntegerMax;
        switch (paramType.kind)
            {
        case XTTypeKindU8:
            if (litValue >= 0 && litValue <= 0xFF)
                widthRank = 1;
            break;
        case XTTypeKindI8:
            if (litValue >= -128 && litValue <= 127)
                widthRank = 1;
            break;
        case XTTypeKindU16:
            if (litValue >= 0 && litValue <= 0xFFFF)
                widthRank = 2;
            break;
        case XTTypeKindI16:
            if (litValue >= -32768 && litValue <= 32767)
                widthRank = 2;
            break;
        case XTTypeKindU32:
            if (litValue >= 0 && litValue <= 0xFFFFFFFFLL)
                widthRank = 3;
            break;
        case XTTypeKindI32:
            widthRank = 3;
            break;
        case XTTypeKindFloat:
            widthRank = 4;
            break;
        case XTTypeKindDouble:
            widthRank = 5;
            break;
        default:
            break;
            }
        if (widthRank != NSIntegerMax)
            return widthRank;
        }

    // Integer widening (both signed or both unsigned).
    BOOL aSigned = (argType.kind == XTTypeKindI8 || argType.kind == XTTypeKindI16 || argType.kind == XTTypeKindI32);
    BOOL aUnsigned = (argType.kind == XTTypeKindU8 || argType.kind == XTTypeKindU16 || argType.kind == XTTypeKindU32);
    BOOL pSigned = (paramType.kind == XTTypeKindI8 || paramType.kind == XTTypeKindI16 || paramType.kind == XTTypeKindI32);
    BOOL pUnsigned = (paramType.kind == XTTypeKindU8 || paramType.kind == XTTypeKindU16 || paramType.kind == XTTypeKindU32);
    NSInteger aWidth = 0, pWidth = 0;
    switch (argType.kind)
        {
    case XTTypeKindI8:
    case XTTypeKindU8:
        aWidth = 1;
        break;
    case XTTypeKindI16:
    case XTTypeKindU16:
        aWidth = 2;
        break;
    case XTTypeKindI32:
    case XTTypeKindU32:
        aWidth = 4;
        break;
    default:
        break;
        }
    switch (paramType.kind)
        {
    case XTTypeKindI8:
    case XTTypeKindU8:
        pWidth = 1;
        break;
    case XTTypeKindI16:
    case XTTypeKindU16:
        pWidth = 2;
        break;
    case XTTypeKindI32:
    case XTTypeKindU32:
        pWidth = 4;
        break;
    default:
        break;
        }
    if (aWidth && pWidth && pWidth >= aWidth)
        {
        if ((aSigned && pSigned) || (aUnsigned && pUnsigned))
            return 2;
        // Unsigned -> signed of strictly larger width is lossless.
        if (aUnsigned && pSigned && pWidth > aWidth)
            return 3;
        // Signed -> unsigned requires value >= 0; without literal info we reject.
        }
    // Integer NARROWING (arg wider than param). Lossy but valid — matches C,
    // where a wider value (e.g. an arithmetic result, now 32-bit under integer
    // promotion) truncates to a narrower parameter at the call. Ranked by
    // width-closeness (least narrowing wins — u32→u16 beats u32→u8, recovering
    // the likely-intended width) and BELOW int→float/double, so an int argument
    // always prefers an int parameter over a float one. Only ever better than
    // the "no match" it replaces; lossless widening/exact still win.
    // Ranks: diff 1 → 3, diff 2 → 4, diff 3 → 5  (float=6, double=7 below).
    if (aWidth && pWidth && pWidth < aWidth && (aSigned || aUnsigned) && (pSigned || pUnsigned))
        return 2 + (NSInteger)(aWidth - pWidth);
    // Integer -> float / double. Bumped above integer narrowing (an int arg with
    // both an int-narrowing and a float overload should pick the int one).
    if ((aSigned || aUnsigned) && paramType.kind == XTTypeKindFloat)
        return 6;
    if ((aSigned || aUnsigned) && paramType.kind == XTTypeKindDouble)
        return 7;
    // Float -> double widening.
    if (argType.kind == XTTypeKindFloat && paramType.kind == XTTypeKindDouble)
        return 3;

    // Autoboxing: a primitive integer / float / pointer-to-u8 (string)
    // argument can box into a Foundation wrapper class — Number for
    // numeric primitives, String for u8@ — when the parameter expects
    // an Object@ / protocol@ / matching wrapper. Rank 8 puts it
    // strictly worse than every direct conversion above (max 5), so
    // any non-boxing overload wins on a tie. The actual factory call
    // is spliced into the argument list AFTER overload resolution
    // picks this candidate; see `applyAutoboxToArguments:`.
    if ([self autoboxClassNameForArgType:argType toParamType:paramType])
        {
        return 8;
        }
    // Unboxing — the symmetric path. A class-pointer argument
    // (typed Number@ / Object@ / Hashable@ etc, but expected to
    // carry a Number at runtime) can unbox into a primitive when
    // the parameter is i8…u64 / float / double. Rank 9 — even
    // worse than autobox (8) so explicit `arr.add(Number@)` and
    // direct primitive overloads both win on a tie. Rewrite to
    // `((Number@)arg).asXXX()` happens after overload resolution
    // via `applyUnboxToArguments:`.
    if ([self canUnboxRhsType:argType toLhsType:paramType])
        {
        return 9;
        }
    return NSIntegerMax;
    }

/****************************************************************************\
|* If `argType` can be autoboxed into a Foundation wrapper class
|* whose pointer is assignable to `paramType`, return the wrapper
|* class name (`@"Number"` / `@"String"`). Otherwise nil.
|*
|* Eligible argument shapes:
|*   * any integer scalar (i8/u8/i16/u16/i32/u32/i64/u64) → Number
|*   * float or double scalar                              → Number
|*   * pointer-to-u8 (`u8@` / `string`)            → String
|*
|* Eligible parameter shapes: pointer-to-class, where the wrapper
|* class can convert to the pointee — either the wrapper IS the
|* pointee (Number@ → Number@), inherits from the pointee
|* (Number@ → Object@), or conforms to the pointee's protocol
|* constraint (Number@ → Hashable@).
|*
|* Returns nil when the wrapper class hasn't been imported (the
|* program isn't using Foundation's wrappers, so we silently skip
|* the autobox path rather than synthesise a call to a class that
|* doesn't exist).
\****************************************************************************/
- (NSString*)autoboxClassNameForArgType:(XTType*)argType
                            toParamType:(XTType*)paramType
    {
    if (!argType || !paramType)
        return nil;
    if (![paramType isKindOfClass:[XTPointerType class]])
        return nil;
    XTType* pointee = ((XTPointerType*)paramType).pointeeType;
    if (!pointee || pointee.kind != XTTypeKindClass)
        return nil;

    NSString* boxedClass = nil;
    switch (argType.kind)
        {
    case XTTypeKindI8:
    case XTTypeKindU8:
    case XTTypeKindI16:
    case XTTypeKindU16:
    case XTTypeKindI32:
    case XTTypeKindU32:
    // The 64-bit widths and double. Boxing and UNBOXING have to grow
    // together: with the accessor added but not this, `a.add((i64)7)`
    // stored the raw 64-bit value where a pointer belonged, `get` handed
    // it back as one, and the unbox dereferenced it — a segfault rather
    // than a wrong number, which is at least the honest failure.
    case XTTypeKindI64:
    case XTTypeKindU64:
    case XTTypeKindFloat:
    case XTTypeKindDouble:
        boxedClass = @"Number";
        break;
    case XTTypeKindPointer:
        if ([argType isKindOfClass:[XTPointerType class]])
            {
            XTType* ap = ((XTPointerType*)argType).pointeeType;
            if (ap && ap.kind == XTTypeKindU8)
                boxedClass = @"String";
            }
        break;
    default:
        break;
        }
    if (!boxedClass)
        return nil;
    XTClassDeclNode* boxedCls = self.classesByName[boxedClass];
    if (!boxedCls)
        return nil;

    // Don't double-box: if the arg is already pointer-to-the-boxed-
    // class (e.g. an existing `String@` value being passed where
    // `Object@` is expected), the standard upcast path handles it
    // and there's no autobox to do here. The kind check above only
    // triggers on raw u8@ for String, so this is a pure safety check
    // covering future extensions (Data, etc.).
    if ([argType isKindOfClass:[XTPointerType class]])
        {
        XTType* ap = ((XTPointerType*)argType).pointeeType;
        if (ap && ap.kind == XTTypeKindClass &&
            [ap.displayName isEqualToString:boxedClass])
            {
            return nil;
            }
        }

    NSString* destProto = pointee.protocolConstraint;
    if (destProto.length > 0)
        {
        if ([self class:boxedCls conformsToProtocol:destProto])
            return boxedClass;
        return nil;
        }
    XTClassDeclNode* destCls = self.classesByName[pointee.displayName];
    if (destCls && [self class:boxedCls inheritsFromOrEquals:destCls])
        {
        return boxedClass;
        }
    return nil;
    }

/****************************************************************************\
|* After overload resolution picks a candidate, walk the argument
|* list against the chosen `paramTypes` and replace every primitive
|* / u8@ argument that needs autoboxing with a synthesised
|* `Number.with(arg)` / `String.withCString(arg)` MethodCallExpr
|* node, then re-analyse the wrapper so its `resolvedType` /
|* `resolvedMangledName` / class lookup all settle. Mutates the
|* call node's `arguments` array in place. No-op when no arg needs
|* boxing or when the call node isn't a free-call / method-call.
\****************************************************************************/
- (void)applyAutoboxToArguments:(XTASTNode*)callNode
                     paramTypes:(NSArray<XTType*>*)paramTypes
    {
    NSArray<XTASTNode*>* args = nil;
    if ([callNode isKindOfClass:[XTCallExprNode class]])
        {
        args = ((XTCallExprNode*)callNode).arguments;
        }
    else if ([callNode isKindOfClass:[XTMethodCallExprNode class]])
        {
        args = ((XTMethodCallExprNode*)callNode).arguments;
        }
    else
        {
        return;
        }
    NSUInteger n = MIN(paramTypes.count, args.count);
    NSMutableArray<XTASTNode*>* out = nil;
    for (NSUInteger i = 0; i < n; i++)
        {
        XTASTNode* arg = args[i];
        XTType* pt = paramTypes[i];
        XTType* at = arg.resolvedType;
        NSString* boxed = [self autoboxClassNameForArgType:at toParamType:pt];
        if (!boxed)
            continue;
        NSString* factory = [boxed isEqualToString:@"String"]
                                ? @"withCString"
                                : @"with";
        XTIdentifierNode* recv =
            [[XTIdentifierNode alloc] initWithName:boxed
                                          location:arg.location];
        XTMethodCallExprNode* wrap =
            [[XTMethodCallExprNode alloc] initWithReceiver:recv
                                                methodName:factory
                                                 arguments:@[ arg ]
                                                  location:arg.location];
        [self analyzeNode:wrap];
        if (!out)
            out = [args mutableCopy];
        out[i] = wrap;
        }
    if (!out)
        return;
    if ([callNode isKindOfClass:[XTCallExprNode class]])
        {
        ((XTCallExprNode*)callNode).arguments = out;
        }
    else
        {
        ((XTMethodCallExprNode*)callNode).arguments = out;
        }
    }

/****************************************************************************\
|* Map a primitive numeric LHS type to the Number accessor method
|* whose return type matches. Returns nil for non-numeric LHS — the
|* caller's branch is the only reason to call this, so the nil case
|* is a clean "no unbox here" signal.
\****************************************************************************/
- (NSString*)numberAccessorForLhsType:(XTType*)lhsType
    {
    if (!lhsType)
        return nil;
    switch (lhsType.kind)
        {
    case XTTypeKindI8:
        return @"asI8";
    case XTTypeKindU8:
        return @"asU8";
    case XTTypeKindI16:
        return @"asI16";
    case XTTypeKindU16:
        return @"asU16";
    case XTTypeKindI32:
        return @"asI32";
    case XTTypeKindU32:
        return @"asU32";
    // The 64-bit widths and double were missing, so `Array<i64>` and
    // `Array<double>` could not unbox through ANY path — not for-in and
    // not `i64 v = a.get(i)` — because a box that cannot be read back is
    // not a box. Part of the i64/u64 work rather than a separate item:
    // supporting a type in a collection is supporting the type.
    case XTTypeKindI64:
        return @"asI64";
    case XTTypeKindU64:
        return @"asU64";
    case XTTypeKindFloat:
        return @"asFloat";
    case XTTypeKindDouble:
        return @"asDouble";
    default:
        return nil;
        }
    }

/****************************************************************************\
|* YES when the class whose method is currently being analysed — or any of its
|* ancestors — declares a method with this name. Used to keep member scope
|* ahead of the free-function overload set for an unqualified call (bug 040).
|*
|* The NAME alone decides, not the signature. Overload resolution among the
|* class's own methods happens later, on the self-method path; letting a global
|* back in when no member overload fits would resurrect exactly the capture
|* this prevents, and would make which function runs depend on argument types
|* across two unrelated scopes.
\****************************************************************************/
- (BOOL)enclosingClassChainDeclaresMethodNamed:(NSString*)name
    {
    if (!name.length)
        return NO;
    // The ONE case where the free-function layer must still run first: a method
    // calling its OWN name. That is how a wrapper reaches the C function it
    // wraps — `static double sqrt(double v) { return sqrt(v); }` in Math means
    // libc's `sqrt`, not unbounded recursion — and there is no qualified
    // spelling for a free function to say it any other way.
    //
    // The test is the NAME, not the method identity. Identity is not enough:
    // a wrapper that also has sibling overloads (`sqrt(float)` beside
    // `sqrt(double)`) would still find a member that is not itself, and capture
    // the call back into the class.
    //
    // A method whose name matches no free function is unaffected — the layer
    // simply finds nothing and falls through to the self-method path below, so
    // ordinary recursion still works.
    if ([name isEqualToString:self.currentMethod.methodName])
        return NO;
    for (XTClassDeclNode* c = self.currentClassNode; c != nil; c = c.parentClass)
        for (XTMethodDeclNode* m in c.methods)
            if ([m.methodName isEqualToString:name])
                return YES;
    return NO;
    }

/****************************************************************************\
|* YES when an `rhsType → lhsType` conversion can be expressed by
|* unboxing a Number-bearing class pointer into a primitive. Three
|* preconditions:
|*   • lhsType is one of the eight Number-supported scalar widths
|*     (`numberAccessorForLhsType:` returns non-nil),
|*   • rhsType is a pointer-to-class — Number@ exact, or any
|*     supertype/protocol it conforms to (Object@, Hashable@, …),
|*   • the Number class is in scope (`self.classesByName[@"Number"]`).
|* Hard-coded to Number for now; if Foundation grows additional
|* primitive wrappers (Bool wrapper, etc.) the lookup generalises to
|* a name → accessor table.
\****************************************************************************/
- (BOOL)canUnboxRhsType:(XTType*)rhsType
              toLhsType:(XTType*)lhsType
    {
    if (![self numberAccessorForLhsType:lhsType])
        return NO;
    if (![rhsType isKindOfClass:[XTPointerType class]])
        return NO;
    XTType* pointee = ((XTPointerType*)rhsType).pointeeType;
    if (!pointee || pointee.kind != XTTypeKindClass)
        return NO;
    XTClassDeclNode* numberCls = self.classesByName[@"Number"];
    if (!numberCls)
        return NO;
    NSString* destProto = pointee.protocolConstraint;
    if (destProto.length > 0)
        {
        return [self class:numberCls conformsToProtocol:destProto];
        }
    XTClassDeclNode* destCls = self.classesByName[pointee.displayName];
    if (!destCls)
        return NO;
    // Number@ → Number@ exact, OR Number@ → any ancestor (Object).
    return [self class:numberCls inheritsFromOrEquals:destCls];
    }

/****************************************************************************\
|* Synthesise the `((Number@)rhs).asXXX()` rewrite — a cast to
|* Number@ (skipped when rhs is already typed Number@) followed by
|* a method call to the matching accessor. Caller stamps the
|* returned node back onto the AST in place of the original rhs.
|* Returns nil when the rewrite isn't applicable (caller's
|* `canUnboxRhsType:toLhsType:` should already have ruled that out).
\****************************************************************************/
- (XTASTNode*)unboxRhs:(XTASTNode*)rhs
             toLhsType:(XTType*)lhsType
    {
    NSString* accessor = [self numberAccessorForLhsType:lhsType];
    if (!accessor)
        return nil;
    if (![self canUnboxRhsType:rhs.resolvedType toLhsType:lhsType])
        return nil;
    XTType* pointee = ((XTPointerType*)rhs.resolvedType).pointeeType;
    XTASTNode* receiver = rhs;
    if (!pointee || ![pointee.displayName isEqualToString:@"Number"])
        {
        XTType* numberType = [self.typeTable typeForName:@"Number"];
        if (!numberType)
            return nil;
        XTType* numberPtrType = [XTPointerType pointerToType:numberType];
        receiver = [[XTCastExprNode alloc] initWithType:numberPtrType
                                                operand:rhs
                                               location:rhs.location];
        }
    XTMethodCallExprNode* call =
        [[XTMethodCallExprNode alloc] initWithReceiver:receiver
                                            methodName:accessor
                                             arguments:@[]
                                              location:rhs.location];
    [self analyzeNode:call];
    return call;
    }

/****************************************************************************\
|* Unbox an expression that READS AN ELEMENT out of a typed collection whose
|* element type is a primitive.
|*
|* `Array<i32>* a` holds boxed `Number`s, so `a.get(i)` comes back as a
|* pointer. Sema turned that into `((Number@)a.get(i)).asI32()` in the four
|* places that happened to need it — declaration, assignment, return, typed
|* call argument — and NOWHERE else, so `a.get(i) + 1` added to a pointer,
|* `a.get(i) == 70` compared one and quietly answered false, and `%ld` printed
|* one. Three of seven contexts silently wrong, and no rule a reader could
|* predict; see private:docs/bugs/046.
|*
|* The decision belongs to the EXPRESSION, not to its context: `a` was declared
|* to hold `i32`, so `a.get(i)` is an `i32` wherever it appears. This helper is
|* that decision in one place, for any consumer to apply to a child it is about
|* to take the value of.
|*
|* @param  e  Any analysed expression.
|* @return    The unboxing rewrite, or `e` unchanged when it is not a
|*            primitive-element collection read.
\****************************************************************************/
- (XTASTNode*)unboxCollectionElement:(XTASTNode*)e
    {
    if (![e isKindOfClass:[XTMethodCallExprNode class]])
        return e;
    XTMethodCallExprNode* mc = (XTMethodCallExprNode*)e;
    if (!XTIsErasedElementType(mc.resolvedType))
        return e;
    // `Object*` is the erasure convention for "the element", and `copy` breaks
    // it: `Copying` declares `Object* copy(void)`, so a collection's own copy
    // is spelled the same as one of its elements and there is nothing in the
    // types to tell them apart. Excluded by name, which is exactly as narrow as
    // the problem. (The CLASS-element substitution below has the same hole and
    // types `Array<String>*.copy()` as a `String*` — bug 051.)
    if ([mc.methodName isEqualToString:@"copy"])
        return e;
    XTType* elem = XTCollectionElementOf(mc.receiver.resolvedType);
    if (!elem || !(elem.isInteger || elem.isFloating))
        return e;
    return [self unboxRhs:e toLhsType:elem] ?: e;
    }

/****************************************************************************\
|* Symmetric to `applyAutoboxToArguments:`. After overload
|* resolution picks a candidate, walk arg/param pairs and replace
|* every class-pointer argument that needs unboxing into a primitive
|* with the synthesised `((Number@)arg).asXXX()` rewrite.
\****************************************************************************/
- (void)applyUnboxToArguments:(XTASTNode*)callNode
                   paramTypes:(NSArray<XTType*>*)paramTypes
    {
    NSArray<XTASTNode*>* args = nil;
    if ([callNode isKindOfClass:[XTCallExprNode class]])
        {
        args = ((XTCallExprNode*)callNode).arguments;
        }
    else if ([callNode isKindOfClass:[XTMethodCallExprNode class]])
        {
        args = ((XTMethodCallExprNode*)callNode).arguments;
        }
    else
        {
        return;
        }
    NSUInteger n = MIN(paramTypes.count, args.count);
    NSMutableArray<XTASTNode*>* out = nil;
    for (NSUInteger i = 0; i < n; i++)
        {
        XTASTNode* arg = args[i];
        XTType* pt = paramTypes[i];
        XTType* at = arg.resolvedType;
        if (![self canUnboxRhsType:at toLhsType:pt])
            continue;
        XTASTNode* unboxed = [self unboxRhs:arg toLhsType:pt];
        if (!unboxed)
            continue;
        if (!out)
            out = [args mutableCopy];
        out[i] = unboxed;
        }
    // Arguments PAST the declared parameters are varargs: there is no param
    // type to key the unbox off, so `printf("%ld", a.get(i))` packed the box
    // and printed a pointer. The element type is decided by the collection,
    // not by the slot it is passed in, so this needs no target type (bug 046).
    for (NSUInteger i = n; i < args.count; i++)
        {
        XTASTNode* unboxed = [self unboxCollectionElement:args[i]];
        if (unboxed == args[i])
            continue;
        if (!out)
            out = [args mutableCopy];
        out[i] = unboxed;
        }
    if (!out)
        return;
    if ([callNode isKindOfClass:[XTCallExprNode class]])
        {
        ((XTCallExprNode*)callNode).arguments = out;
        }
    else
        {
        ((XTMethodCallExprNode*)callNode).arguments = out;
        }
    }

/****************************************************************************\
|* Score an overload candidate against a list of call arguments. Returns the
|* worst (highest) conversion rank across all parameters, or NSIntegerMax if
|* any parameter has no valid conversion. Varargs candidates receive a +10
|* penalty so non-varargs overloads are preferred.
|* @param paramTypes  The candidate's declared parameter types.
|* @param isVarArgs   YES if the candidate accepts varargs.
|* @param args        The argument expressions from the call site.
|* @return  The conversion score (lower is better), or NSIntegerMax if invalid.
\****************************************************************************/
- (NSInteger)scoreCandidateParamTypes:(NSArray<XTType*>*)paramTypes
                            isVarArgs:(BOOL)isVarArgs
                            arguments:(NSArray<XTASTNode*>*)args
    {
    NSUInteger fixed = paramTypes.count;
    if (isVarArgs)
        {
        if (args.count < fixed)
            return NSIntegerMax;
        }
    else
        {
        if (args.count != fixed)
            return NSIntegerMax;
        }
    NSInteger worst = 0;
    for (NSUInteger i = 0; i < fixed; i++)
        {
        XTType* pt = paramTypes[i];
        XTASTNode* arg = args[i];
        XTType* at = arg.resolvedType;
        BOOL isLit = [arg isKindOfClass:[XTLiteralIntNode class]];
        int64_t lv = isLit ? ((XTLiteralIntNode*)arg).intValue : 0;
        NSInteger r = [self conversionRankFrom:at to:pt isIntLit:isLit litValue:lv];
        if (r == NSIntegerMax)
            return NSIntegerMax;
        if (r > worst)
            worst = r;
        }
    if (isVarArgs)
        worst += 10; // penalise so non-varargs wins.
    return worst;
    }

/****************************************************************************\
|* Catch `&stackInstance` (or a bare stack-class ident whose resolved
|* type is class-value) being passed into a strong class-pointer
|* parameter. Under ARC the callee's prologue retains the pointer,
|* which would bump the refcount at (stack-addr - 1) — that byte is
|* arbitrary zero-page, not a heap block header, so the retain
|* corrupts unrelated state and the matching scope-exit release would
|* eventually try to free a non-heap address. Fires only under
|* `-farc`; the Phase-0 path (`-farc=off`) leaves parameter retains
|* as the user's responsibility and the check would fire falsely.
\****************************************************************************/
// A BLOCK argument may not land in a bound-method ('^') parameter — uxkit/030.
//
// Folded in beside the stack-instance check because it needs the same three
// things (the parameter types, the arguments, and a name for the message) and
// is wanted at exactly the same call sites. The assignment form is caught in
// checkClassPointerAssign; a `^` PARAMETER is the other half, and it is the
// worse one: the assignment form read back null and did nothing, while this
// one type-checked, stored a live-looking value, and took SIGBUS inside the
// callee.
- (void)checkBlockIntoBoundMethodArgs:(NSArray<XTType*>*)paramTypes
                            arguments:(NSArray<XTASTNode*>*)arguments
                           calleeDesc:(NSString*)calleeDesc
                             location:(XTSourceLocation*)loc
    {
    NSUInteger n = MIN(paramTypes.count, arguments.count);
    for (NSUInteger i = 0; i < n; i++)
        {
        XTType* pt = paramTypes[i];
        XTType* at = arguments[i].resolvedType;
        if (!pt || !at)
            continue;
        if (pt.boundMethodSignature == nil || at.boundMethodSignature != nil)
            continue;
        if (![at isKindOfClass:[XTPointerType class]])
            continue;
        XTType* pe = ((XTPointerType*)at).pointeeType;
        if (!pe || pe.kind != XTTypeKindClass || ![pe.displayName hasPrefix:@"Blk$"])
            continue;
        [self.diagnostics emitError:[NSString stringWithFormat:
                                                  @"argument %lu of %@: a block cannot be passed where a bound method "
                                                  @"('^') is expected — a block is a class reference and a '^' is a "
                                                  @"(receiver, code) pair, so the callee would call garbage. Pass "
                                                  @"'&obj.method', or take a block parameter instead.",
                                                  (unsigned long)(i + 1), calleeDesc]
                                 at:loc];
        }
    }

- (void)checkStackInstanceStrongParamArgs:(NSArray<XTType*>*)paramTypes
                                arguments:(NSArray<XTASTNode*>*)arguments
                               calleeDesc:(NSString*)calleeDesc
                                 location:(XTSourceLocation*)loc
    {
    NSUInteger n = MIN(paramTypes.count, arguments.count);
    for (NSUInteger i = 0; i < n; i++)
        {
        XTType* pt = paramTypes[i];
        if (![pt isKindOfClass:[XTPointerType class]])
            continue;
        XTType* pointee = ((XTPointerType*)pt).pointeeType;
        if (!pointee || pointee.kind != XTTypeKindClass)
            continue;
        XTASTNode* arg = arguments[i];
        NSString* instName = nil;
        if ([arg isKindOfClass:[XTUnaryExprNode class]])
            {
            XTUnaryExprNode* u = (XTUnaryExprNode*)arg;
            if (u.op != XTUnaryOpAddrOf)
                continue;
            XTType* ot = u.operand.resolvedType;
            if (!ot || ot.kind != XTTypeKindClass)
                continue;
            if ([u.operand isKindOfClass:[XTIdentifierNode class]])
                {
                instName = ((XTIdentifierNode*)u.operand).identName;
                }
            else
                {
                instName = @"<stack instance>";
                }
            }
        else
            {
            continue;
            }
        [self.diagnostics emitError:[NSString stringWithFormat:
                                                  @"cannot pass stack-allocated instance '%@' as strong pointer parameter of %@ — "
                                                   "the callee would retain a non-heap address; use `new %@(...)` or `%@.clone()` instead",
                                                  instName, calleeDesc, pointee.displayName, instName]
                                 at:loc];
        }
    }

/****************************************************************************\
|* Suggest a covariant return where a method declares the type it INHERITED
|* rather than the one it actually returns.
|*
|* `class Bag : Object <Copying> { Object* copy(void) { … return bag; } }` is
|* legal and compiles, but it throws away what it knows: every caller must cast,
|* and — because type arguments substitute positionally against erased
|* spellings — an `Object*` return on a container is read as "one of my
|* elements", so `Bag<String>*.copy()` silently types a Bag as a String
|* (private:docs/bugs/051, 055).
|*
|* Returns are covariant, so the fix is one word at the declaration:
|* `Bag* copy(void)`. This says so.
|*
|* Fires only when all of:
|*   - an ANCESTOR class or a CONFORMED PROTOCOL declares the same method with
|*     the same return type — so it is genuinely an inherited spelling, not a
|*     free choice;
|*   - every `return` in the body yields one class, and it is a strict subclass
|*     of the declared one;
|*   - the class is USED with a type argument somewhere in this unit, which is
|*     where the silent mistyping actually happens. Without that gate this
|*     fires on every `Object* copy` in the program, most of which are fine.
\****************************************************************************/
- (void)checkCovariantReturnOpportunities
    {
    for (NSString* clsName in self.classesUsedWithTypeArgument)
        {
        XTClassDeclNode* cls = self.classesByName[clsName];
        if (!cls)
            continue;
        for (XTMethodDeclNode* m in cls.methods)
            {
            NSString* observed = m.observedReturnClass;
            if (!observed || [observed isEqualToString:@"?"])
                continue;
            XTType* decl = m.returnTypes.firstObject;
            if (![decl isKindOfClass:[XTPointerType class]])
                continue;
            XTType* declPointee = ((XTPointerType*)decl).pointeeType;
            if (!declPointee || declPointee.kind != XTTypeKindClass)
                continue;
            NSString* declName = declPointee.displayName;
            if ([declName isEqualToString:observed])
                continue; // already narrow

            // The observed class must actually BE a subclass of the declared
            // one; anything else is a different diagnostic, not this one.
            XTClassDeclNode* obs = self.classesByName[observed];
            XTClassDeclNode* dcl = self.classesByName[declName];
            if (!obs || !dcl || ![self class:obs inheritsFromOrEquals:dcl])
                continue;

            NSString* inheritedFrom = [self declarerOfMethod:m.methodName
                                                   returning:declName
                                                    forClass:cls];
            if (!inheritedFrom)
                continue;

            [self.diagnostics emitWarning:[NSString stringWithFormat:
                                                        @"'%@.%@' returns a '%@*' but declares %@'s '%@*' — declare it "
                                                        @"'%@* %@(...)'. Returns are covariant, and an inherited "
                                                        @"'Object*' on a class used with a type argument is read as its "
                                                        @"element type",
                                                        clsName, m.methodName, observed, inheritedFrom, declName,
                                                        observed, m.methodName]
                                 category:XTWarnCovariantReturn
                                       at:m.location];
            }
        }
    }

/****************************************************************************\
|* The ancestor class or conformed protocol that declares `name` with return
|* `retClass`, or nil. Protocols are checked too — `Copying` is the case this
|* exists for, and a protocol requirement is inherited exactly as a parent's
|* method is.
\****************************************************************************/
- (nullable NSString*)declarerOfMethod:(NSString*)name
                             returning:(NSString*)retClass
                              forClass:(XTClassDeclNode*)cls
    {
    for (XTClassDeclNode* a = self.classesByName[cls.parentName]; a;
         a = self.classesByName[a.parentName])
        {
        for (XTMethodDeclNode* am in a.methods)
            {
            if (![am.methodName isEqualToString:name])
                continue;
            XTType* ar = am.returnTypes.firstObject;
            if (![ar isKindOfClass:[XTPointerType class]])
                continue;
            XTType* ap = ((XTPointerType*)ar).pointeeType;
            if (ap && [ap.displayName isEqualToString:retClass])
                return a.className;
            }
        }
    for (NSString* pn in cls.protocolNames)
        {
        XTProtocolDeclNode* proto = self.protocolsByName[pn];
        for (XTMethodDeclNode* pm in proto.methods)
            {
            if (![pm.methodName isEqualToString:name])
                continue;
            XTType* pr = pm.returnTypes.firstObject;
            if (![pr isKindOfClass:[XTPointerType class]])
                continue;
            XTType* pp = ((XTPointerType*)pr).pointeeType;
            if (pp && [pp.displayName isEqualToString:retClass])
                return pn;
            }
        }
    return nil;
    }

/****************************************************************************\
|* Check a literal `...` written as a call argument — the forwarding form.
|*
|* Legal only inside a function declared `...`, and only when that function
|* does not read its OWN varargs. Both facts are already tracked: `isVarArgs`
|* on the decl, and `variadicFunctionsUsingVaList` (populated when `va_start` is
|* seen), which is the same set `validateVariadicNonReentrance` consults to
|* decide a pure forwarder is safe.
|*
|* The rule is the user's: if A(...) and B(...) both call C(...) and neither
|* reads its own tail, nothing can clobber anything — A never repacks, so the
|* original caller's pack is still what C reads.
|*
|* @param args  The call's argument list.
|* @param loc   Where to report.
|* @return  YES if the list contains a forwarding marker.
\****************************************************************************/
/****************************************************************************\
|* Record a call that PACKS its own variadic arguments, and diagnose it against
|* a forward in the same function — private:docs/bugs/050.
|*
|* On every target but arm9 a variadic's arguments live in ONE shared buffer,
|* filled by the caller. A forwarder works precisely because it does not touch
|* that buffer. Calling anything variadic WITH arguments overwrites it, and the
|* pending caller's pack is what gets overwritten:
|*
|*     void logIt(string fmt, ...) {
|*         Stdio.printf("[%d] ", (u16)9);   // packs 9 into slot 0
|*         Stdio.printf(fmt, ...);          // the caller's slot 0 is gone
|*     }
|*     logIt("a=%d b=%d\n", (u16)222, (u16)333);   ->   [9] a=9 b=333
|*
|* `b=333` survives because the inner call packed one slot, which is what made
|* it read as a formatting bug rather than a clobber. Either order is wrong, so
|* both facts are recorded and whichever arrives second reports.
\****************************************************************************/
- (void)notePackingVariadicCall:(NSString*)callee at:(XTSourceLocation*)loc
    {
    if (self.fnPackingCallee)
        return; // the first one is the report
    self.fnPackingCallee = callee;
    self.fnPackingCallLoc = loc;
    if (self.fnForwardsVarargs)
        [self reportVarargPackVsForwardAt:loc];
    }

- (void)reportVarargPackVsForwardAt:(XTSourceLocation*)loc
    {
    [self.diagnostics emitError:[NSString stringWithFormat:
                                              @"'%@' packs its own variadic arguments, and this function also "
                                              @"forwards with '...' — they share one argument buffer, so the packing "
                                              @"call overwrites the arguments being forwarded. Move the packing call "
                                              @"into a separate function, or build the text with String.withFormat "
                                              @"and print that",
                                              self.fnPackingCallee ?: @"a variadic call"]
                             at:loc];
    }

- (void)checkVarargForwardAt:(XTSourceLocation*)loc
    {
    BOOL inVariadic = (self.currentFunction && self.currentFunction.isVarArgs) || (self.currentMethod && self.currentMethod.isVarArgs);
    if (!inVariadic)
        {
        [self.diagnostics emitError:
                              @"'...' as an argument forwards the enclosing function's variadic "
                              @"arguments — but this function does not declare '...'"
                                 at:loc];
        return;
        }
    // A function that reads its own tail has consumed the buffer the forward
    // would pass on; the two cannot both be true.
    if (self.currentFunctionLabel && [self.variadicFunctionsUsingVaList containsObject:self.currentFunctionLabel])
        {
        [self.diagnostics emitError:
                              @"'...' cannot forward from a function that reads its own variadic "
                              @"arguments — 'va_start' here has already consumed them"
                                 at:loc];
        return;
        }
    // Record it on the enclosing function. Five targets need nothing — their
    // varargs never left the caller's pack buffer, so forwarding is emitting no
    // repack. arm9 passes them in REGISTERS, so its back end has to home them
    // and re-lay them out for the callee; the flag is how it finds out.
    if (self.currentFunction)
        self.currentFunction.forwardsVarargs = YES;
    if (self.currentMethod)
        self.currentMethod.forwardsVarargs = YES;
    self.fnForwardsVarargs = YES;
    if (self.fnPackingCallee)
        [self reportVarargPackVsForwardAt:self.fnPackingCallLoc ?: loc];
    }

/****************************************************************************\
|* The checked effect, for a METHOD call: something declared `throws` must be
|* called inside a `try`, or from a caller that is itself `throws`.
|*
|* The rule was enforced for free functions (off `throwingFunctionKeys`) and
|* for `super.foo` (off the decl), and for nothing else — so an ordinary
|* `p.parse(c)` fell through to IR lowering, which rejects it with
|* "ABANDON|lowering: call to a 'throws' function …" and NO source location and
|* NO name. The guarantee was intact; the diagnostic was unusable, and on the
|* majority of call sites, since real code is overwhelmingly methods.
|*
|* Checked off the decl rather than the effect table, because the table is
|* populated from the free-function pre-pass only.
\****************************************************************************/
- (void)checkThrowsEffectForMethod:(XTMethodDeclNode*)chosen
                                at:(XTSourceLocation*)loc
    {
    if (!chosen.throwsError)
        return;
    if (self.tryDepth != 0 || self.currentFunctionThrows)
        return;
    [self.diagnostics emitError:[NSString stringWithFormat:
                                              @"'%@' is declared 'throws' — wrap the call in try { } catch (e) { }, "
                                              @"or declare the caller 'throws' to propagate",
                                              chosen.methodName]
                             at:loc];
    }

/****************************************************************************\
|* Return-type-aware tiebreaker. Given a list of candidates that all
|* tied on parameter-type match, pick the one whose first return type
|* matches the current `self.expectedType`. Falls back to the float-
|* returning candidate when the context gives no hint (vararg slot,
|* standalone expression statement, etc.) — matches the "default to
|* float" rule for ambiguous zero-arg calls in printf-like contexts.
|*
|* `candidates` is an array of objects; `returnTypeOfCandidate` maps
|* each to its first return type. Returns the chosen candidate, or
|* nil if no unique winner exists.
\****************************************************************************/
- (id)tiebreakOverloadCandidates:(NSArray*)candidates
               returnTypeOfBlock:(XTType* (^)(id))returnTypeOf
    {
    if (candidates.count <= 1)
        return candidates.firstObject;
    // First try matching the expected type exactly (by displayName).
    if (self.expectedType)
        {
        NSString* want = self.expectedType.displayName;
        for (id c in candidates)
            {
            XTType* rt = returnTypeOf(c);
            if (rt && [rt.displayName isEqualToString:want])
                return c;
            }
        }
    // No expected type (or no match among candidates): prefer the
    // float-returning candidate. This is the "printf defaults to
    // float" rule — when no context drives the choice, keep the
    // pre-dp behaviour that existing code depends on.
    for (id c in candidates)
        {
        XTType* rt = returnTypeOf(c);
        if (rt && rt.kind == XTTypeKindFloat)
            return c;
        }
    return nil;
    }

/****************************************************************************\
|* Format argument types as a comma-separated string for diagnostics.
|* @param args  The call argument AST nodes.
|* @return  A string like "u8, u16, pointer".
\****************************************************************************/
- (NSString*)describeArgTypes:(NSArray<XTASTNode*>*)args
    {
    NSMutableArray* parts = [NSMutableArray array];
    for (XTASTNode* a in args)
        [parts addObject:(a.resolvedType.displayName ?: @"?")];
    return [parts componentsJoinedByString:@", "];
    }

/****************************************************************************\
|* Side-effect-free probe: would a `use`-promoted static method resolve this
|* bare call? Used to give libc (and any free function) LOWEST precedence — a
|* non-matching free-function candidate (e.g. the auto-imported libc
|* `rand(void)` proto) must not block a matching `use`-promoted class method
|* like `Math.rand(u8)`. Mirrors the scoring in the `use Klass;` fallback and
|* is gated the same way (only outside a class body, where use-promotion
|* applies), so it never makes a library method self-resolve.
\****************************************************************************/
- (BOOL)hasUsePromotedMatchForCall:(XTCallExprNode*)node
    {
    // A name the enclosing class chain DECLARES is member scope, not a
    // use-promoted call — the same rule the free-function set uses (bug 147:
    // 145 made use-promotion reachable inside class bodies, which then
    // captured a self-method call named like a use-promoted function and
    // dropped the receiver-kind mark; a declared name never reaches here).
    if ([self enclosingClassChainDeclaresMethodNamed:node.calleeName])
        return NO;
    // Inside a class body too (bug 145): `use` promotes a class's statics
    // into the bare-call space for the whole FILE, and a block literal is a
    // method of a synthesised class — `printf` inside a block was "undeclared"
    // here while the shipped compiler accepted it. Implicit-self methods and
    // free functions are still tried first; this is the last resort.
    if (self.usedClassNames.count == 0)
        return NO;
    for (NSString* useClassName in self.usedClassNames)
        {
        XTClassDeclNode* cls = self.classesByName[useClassName];
        if (!cls)
            continue;
        for (XTMethodDeclNode* m in cls.methods)
            {
            if (![m.methodName isEqualToString:node.calleeName])
                continue;
            NSMutableArray<XTType*>* pt = [NSMutableArray array];
            for (XTParamNode* p in m.parameters)
                [pt addObject:p.paramType];
            if ([self scoreCandidateParamTypes:pt
                                     isVarArgs:m.isVarArgs
                                     arguments:node.arguments] != NSIntegerMax)
                return YES;
            }
        }
    return NO;
    }

/****************************************************************************\
|* Recognise a call to one of the varargs intrinsics. Returns YES when
|* the call is an intrinsic (handled here, sema done); NO otherwise, so
|* visitCallExpr falls through to normal function-lookup resolution.
|*
|* The intrinsics are name-matched. Every one takes a single u8 argument
|* (the cursor value) — va_start resets it to 0, va_arg_<T> reads the
|* current position and advances the cursor by T's width, va_end is a
|* no-op kept for portability. Codegen knows the enclosing function's
|* varargs-slot buffer base and emits direct absolute-addressed reads
|* against it; no runtime buffer pointer is ever synthesised.
|*
|* Usable only inside a function/method that was itself declared with
|* `...` — anything else is an error, because without a slot there is
|* no buffer to read from.
\****************************************************************************/
- (BOOL)resolveVarargsIntrinsic:(XTCallExprNode*)node
    {
    NSDictionary<NSString*, NSNumber*>* table = @{
        @"va_start" : @(XTTypeKindVoid),
        @"va_end" : @(XTTypeKindVoid),
        @"va_arg_u8" : @(XTTypeKindU8),
        @"va_arg_i8" : @(XTTypeKindI8),
        @"va_arg_u16" : @(XTTypeKindU16),
        @"va_arg_i16" : @(XTTypeKindI16),
        @"va_arg_u32" : @(XTTypeKindU32),
        @"va_arg_i32" : @(XTTypeKindI32),
        // The 64-bit widths. `va_arg_double` already proves an 8-byte vararg
        // slot works end to end, so these are the same machinery — without
        // them `%lld` had nothing to read the argument WITH.
        @"va_arg_u64" : @(XTTypeKindU64),
        @"va_arg_i64" : @(XTTypeKindI64),
        @"va_arg_float" : @(XTTypeKindFloat),
        @"va_arg_double" : @(XTTypeKindDouble),
        @"va_arg_string" : @(XTTypeKindPointer), // string is u8@
        @"va_arg_ptr" : @(XTTypeKindPointer),
        // Struct-pointer form: the parser emitted this for
        // `va_arg(ap, T@)` where T is a user-defined struct, and
        // stamped node.vaArgStructType with the pointee type. Return
        // type is `T@` (typed pointer into the pack buffer); the
        // cursor-advance width is sizeof(T), handled by codegen.
        @"va_arg_struct_ptr" : @(XTTypeKindPointer),
    };
    NSNumber* retKindNum = table[node.calleeName];
    if (!retKindNum)
        return NO;

    // Resolve inside-a-varargs-function guard. Either self.currentFunction
    // or the current class's current method must be varargs.
    BOOL inVarargsCtx = NO;
    if (self.currentFunction && self.currentFunction.isVarArgs)
        inVarargsCtx = YES;
    if (self.currentMethod && self.currentMethod.isVarArgs)
        inVarargsCtx = YES;
    // Stage-4c-follow-up: record that the enclosing variadic actually
    // reads its own va_list, so the reentrance check can distinguish
    // pure forwarders (no va_start → safe to call another variadic)
    // from real consumers (va_start → calling another variadic would
    // clobber the cursor's buffer).
    if (inVarargsCtx && self.currentFunctionLabel &&
        [node.calleeName isEqualToString:@"va_start"])
        {
        [self.variadicFunctionsUsingVaList addObject:self.currentFunctionLabel];
        }
    if (!inVarargsCtx)
        {
        [self.diagnostics emitError:
                              [NSString stringWithFormat:
                                            @"'%@' can only be used inside a function declared with '...'",
                                            node.calleeName]
                                 at:node.location];
        node.resolvedType = [XTType u8Type];
        node.resolvedMangledName = [@"__intrinsic_" stringByAppendingString:node.calleeName];
        return YES;
        }

    if (node.arguments.count != 1)
        {
        [self.diagnostics emitError:
                              [NSString stringWithFormat:
                                            @"'%@' expects exactly 1 argument (va_list cursor), got %lu",
                                            node.calleeName, (unsigned long)node.arguments.count]
                                 at:node.location];
        node.resolvedType = [XTType u8Type];
        node.resolvedMangledName = [@"__intrinsic_" stringByAppendingString:node.calleeName];
        return YES;
        }

    XTASTNode* cursor = node.arguments.firstObject;
    if (![cursor isKindOfClass:[XTIdentifierNode class]])
        {
        [self.diagnostics emitError:
                              [NSString stringWithFormat:
                                            @"'%@' cursor argument must be a plain u8 variable (va_list)",
                                            node.calleeName]
                                 at:node.location];
        node.resolvedType = [XTType u8Type];
        node.resolvedMangledName = [@"__intrinsic_" stringByAppendingString:node.calleeName];
        return YES;
        }
    // The cursor is a u8 (an offset into the $04B0 pack buffer) on pack-buffer
    // targets, or a pointer (a native AAPCS va_list) on arm9 where va_start
    // yields a real va_list to hand to libc vprintf. Accept either.
    XTType* ct = cursor.resolvedType;
    if (!ct || (ct.kind != XTTypeKindU8 && ct.kind != XTTypeKindPointer))
        {
        [self.diagnostics emitError:
                              [NSString stringWithFormat:
                                            @"'%@' cursor argument must be u8 or a pointer (va_list); got %@",
                                            node.calleeName, ct ? ct.displayName : @"<unresolved>"]
                                 at:node.location];
        }

    XTTypeKind retKind = (XTTypeKind)retKindNum.integerValue;
    switch (retKind)
        {
    case XTTypeKindVoid:
        node.resolvedType = [XTType voidType];
        break;
    case XTTypeKindU8:
        node.resolvedType = [XTType u8Type];
        break;
    case XTTypeKindI8:
        node.resolvedType = [XTType i8Type];
        break;
    case XTTypeKindU16:
        node.resolvedType = [XTType u16Type];
        break;
    case XTTypeKindI16:
        node.resolvedType = [XTType i16Type];
        break;
    case XTTypeKindU32:
        node.resolvedType = [XTType u32Type];
        break;
    case XTTypeKindI32:
        node.resolvedType = [XTType i32Type];
        break;
    // Without these the table entry above resolved to the `default:` u8 —
    // `va_arg_i64` typed U8 and the declaration then ZExt'd it, so `%lld`
    // printed 0 while consuming the right number of bytes. Two tables have
    // to agree; adding to one is the same as adding to neither.
    case XTTypeKindU64:
        node.resolvedType = [XTType u64Type];
        break;
    case XTTypeKindI64:
        node.resolvedType = [XTType i64Type];
        break;
    case XTTypeKindFloat:
        node.resolvedType = [XTType floatType];
        break;
    case XTTypeKindDouble:
        node.resolvedType = [XTType doubleType];
        break;
    case XTTypeKindPointer:
        // va_arg_struct_ptr: parser stamped the pointee type on
        // node.vaArgStructType. Return `T@` so the user can do
        // `(@sp).field` without casting. va_arg_ptr falls back
        // to u8@ (pointer of unknown pointee).
        if ([node.calleeName isEqualToString:@"va_arg_struct_ptr"] && node.vaArgStructType)
            {
            node.resolvedType =
                [XTPointerType pointerToType:node.vaArgStructType];
            }
        else if ([node.calleeName isEqualToString:@"va_arg_ptr"] && node.vaArgStructType && node.vaArgStructType.kind == XTTypeKindClass)
            {
            // `va_arg(ap, Object*)` means an Object reference, and saying
            // u8* here made the raw-vs-class assignment check fire on the
            // library's own %@ handler.
            node.resolvedType =
                [XTPointerType pointerToType:node.vaArgStructType];
            }
        else
            {
            node.resolvedType = [XTPointerType pointerToType:[XTType u8Type]];
            }
        break;
    default:
        node.resolvedType = [XTType u8Type];
        break;
        }
    // Tag with a sentinel so codegen can distinguish intrinsic calls
    // from genuine undeclared-function errors.
    node.resolvedMangledName = [@"__intrinsic_" stringByAppendingString:node.calleeName];
    return YES;
    }

/****************************************************************************\
|* Recognise the library-level ARC primitives `__arc_retain(p)` /
|* `__arc_release(p)`. These lower to the same XTIROpRetain / XTIROpRelease
|* the compiler inserts for typed strong references — but exposed as a
|* call so container code can refcount the type-erased `pointer` slots ARC
|* can't see (a Map/Set/Array stores `pointer`, not `T@`, so the compiler
|* never tracks those cells; the container manages them by hand).
|*
|* This is deliberately the ONE sanctioned manual-refcount escape under
|* ARC: the `retain` / `release` *statements* stay rejected (they
|* double-free against compiler-inserted ARC on a typed reference), but a
|* container managing its own raw cells has no typed reference to fight
|* with. Both backends lower it identically — no inline asm, so it works
|* on arm64 where the old `JSR _obj_retain` inline-asm helpers were no-ops.
|*
|* Shape: exactly one pointer-typed argument; returns void.
\****************************************************************************/
- (BOOL)resolveArcIntrinsic:(XTCallExprNode*)node
    {
    BOOL isRetain = [node.calleeName isEqualToString:@"__arc_retain"];
    BOOL isRelease = [node.calleeName isEqualToString:@"__arc_release"];
    if (!isRetain && !isRelease)
        return NO;

    node.resolvedType = [XTType voidType];
    node.resolvedMangledName = [@"__intrinsic_" stringByAppendingString:node.calleeName];

    if (node.arguments.count != 1)
        {
        [self.diagnostics emitError:
                              [NSString stringWithFormat:
                                            @"'%@' expects exactly 1 pointer argument, got %lu",
                                            node.calleeName, (unsigned long)node.arguments.count]
                                 at:node.location];
        return YES;
        }
    XTType* at = node.arguments.firstObject.resolvedType;
    if (at && at.kind != XTTypeKindPointer)
        {
        [self.diagnostics emitError:
                              [NSString stringWithFormat:
                                            @"'%@' argument must be a pointer; got %@",
                                            node.calleeName, at.displayName]
                                 at:node.location];
        }
    return YES;
    }

/****************************************************************************\
|* Recognise a call to the `bank(BANK_TYPE, idx)` builtin. Returns YES
|* when the call is the builtin (handled here, sema done); NO otherwise.
|*
|* The builtin returns a `raw:u8@` — a 3-byte (low addr, high addr, bank)
|* pointer that addresses byte 0 of the requested window in the named
|* bank. BANK_TYPE selects the window: BANK_DATA / BANK_CODE / BANK_C
|* (preprocessor-defined as 0/1/2). The actual window base address is
|* target-dependent and resolved at codegen time against the memory
|* model — which also gates non-banking targets with an error.
|*
|* Sema validates shape only: two arguments, both integer-typed, with
|* arg[0] preferably a compile-time constant in [0,2]. Non-constant
|* BANK_TYPE is rejected here because codegen needs the window base
|* at emit time.
\****************************************************************************/
- (BOOL)resolveBankBuiltin:(XTCallExprNode*)node
    {
    if (![node.calleeName isEqualToString:@"bank"])
        return NO;

    if (node.arguments.count != 2)
        {
        [self.diagnostics emitError:
                              [NSString stringWithFormat:
                                            @"'bank' expects 2 arguments (BANK_TYPE, idx), got %lu",
                                            (unsigned long)node.arguments.count]
                                 at:node.location];
        node.resolvedType = [XTPointerType pointerToType:[XTType u8Type]
                                               placement:XTPointerPlacementRaw];
        node.resolvedMangledName = @"__intrinsic_bank";
        return YES;
        }

    XTASTNode* typeArg = node.arguments[0];
    XTASTNode* idxArg = node.arguments[1];

    if (!typeArg.resolvedType || !typeArg.resolvedType.isInteger)
        {
        [self.diagnostics emitError:
                              [NSString stringWithFormat:
                                            @"'bank' first argument must be one of BANK_DATA / BANK_CODE / BANK_C; got %@",
                                            typeArg.resolvedType ? typeArg.resolvedType.displayName : @"<unresolved>"]
                                 at:node.location];
        }
    if (!idxArg.resolvedType || !idxArg.resolvedType.isInteger)
        {
        [self.diagnostics emitError:
                              [NSString stringWithFormat:
                                            @"'bank' second argument (bank index) must be an integer; got %@",
                                            idxArg.resolvedType ? idxArg.resolvedType.displayName : @"<unresolved>"]
                                 at:node.location];
        }

    // BANK_TYPE has to be a literal int at this point. The
    // BANK_DATA / BANK_CODE / BANK_C macros expand to 0/1/2 in the
    // preprocessor, so the parser sees a bare XTLiteralIntNode here.
    // Anything more dynamic (a variable) is rejected because codegen
    // needs the window base address at emit time.
    if (![typeArg isKindOfClass:[XTLiteralIntNode class]])
        {
        [self.diagnostics emitError:
                              @"'bank' first argument must be a compile-time constant (BANK_DATA / BANK_CODE / BANK_C)"
                                 at:node.location];
        }
    else
        {
        int64_t bankType = ((XTLiteralIntNode*)typeArg).intValue;
        if (bankType < 0 || bankType > 2)
            {
            [self.diagnostics emitError:
                                  [NSString stringWithFormat:
                                                @"'bank' first argument must be BANK_DATA (0), BANK_CODE (1), or BANK_C (2); got %lld",
                                                (long long)bankType]
                                     at:node.location];
            }
        }

    node.resolvedType = [XTPointerType pointerToType:[XTType u8Type]
                                           placement:XTPointerPlacementRaw];
    node.resolvedMangledName = @"__intrinsic_bank";
    return YES;
    }

/****************************************************************************\
|* Visit a function call expression: analyse arguments, resolve overloads,
|* handle implicit self-method calls inside classes, and report case-mismatch
|* suggestions for undeclared functions.
|* @param node  The call expression node.
\****************************************************************************/
- (void)visitCallExpr:(XTCallExprNode*)node
    {
    // A trailing `...` is checked, then DROPPED: on every target but arm9 the
    // arguments never left the caller's pack buffer, so forwarding is emitting
    // no repack — which is what an argument list without it already does. The
    // marker exists so the intent is written down and checkable, not so
    // lowering has something to build. private:docs/bugs/047.
    if (node.forwardsVarargs)
        [self checkVarargForwardAt:node.location];
    for (XTASTNode* arg in node.arguments)
        [self analyzeNode:arg];
    // Intercept varargs intrinsics (va_start / va_end / va_arg_*) before
    // the normal function-lookup path. The intrinsics share no
    // declaration with user code — they're recognised by name and
    // emitted inline by codegen.
    if ([self resolveVarargsIntrinsic:node])
        return;
    // Library-level ARC primitives __arc_retain / __arc_release — the
    // sanctioned manual-refcount path for container code managing
    // type-erased `pointer` slots ARC can't see.
    if ([self resolveArcIntrinsic:node])
        return;
    // Same shape for the `bank(BANK_TYPE, idx)` builtin: a name-
    // matched intrinsic that returns a 3-byte raw bank pointer.
    // Codegen handles the target-banking gate (it has the memory
    // model and the window base addresses) and emits the literal
    // 3-byte pointer.
    if ([self resolveBankBuiltin:node])
        return;
    // A callee that is an EXPRESSION rather than a name — `tbl[0](5)`,
    // `makeCb()(6)`. The kind of call is decided by the expression's TYPE,
    // exactly as the by-name path decides it from the variable's type; only
    // "where the callee's value comes from" differs, and lowering handles
    // that. private:docs/bugs/074.
    if (node.calleeExpr)
        {
        [self analyzeNode:node.calleeExpr];
        XTType* ct = node.calleeExpr.resolvedType;
        if (ct && ct.boundMethodSignature != nil)
            {
            XTFunctionType* ft = (XTFunctionType*)ct.boundMethodSignature;
            node.isIndirectCall = YES;
            node.isBoundCall = YES;
            node.resolvedType = ft.returnTypes.firstObject ?: [XTType voidType];
            return;
            }
        if ([ct isKindOfClass:[XTPointerType class]] && [((XTPointerType*)ct).pointeeType isKindOfClass:[XTFunctionType class]])
            {
            XTFunctionType* ft = (XTFunctionType*)((XTPointerType*)ct).pointeeType;
            node.isIndirectCall = YES;
            node.resolvedType = ft.returnTypes.firstObject ?: [XTType voidType];
            return;
            }
        // A BLOCK is a pointer to its `Blk$…` impl class and a block call is
        // `.invoke` dispatch — the rewrite the parser does for a block LOCAL,
        // which a callee EXPRESSION never reached.
        if ([ct isKindOfClass:[XTPointerType class]])
            {
            XTType* pe = ((XTPointerType*)ct).pointeeType;
            if (pe && pe.kind == XTTypeKindClass && [pe.displayName hasPrefix:@"Blk$"])
                {
                XTMethodCallExprNode* inv =
                    [[XTMethodCallExprNode alloc] initWithReceiver:node.calleeExpr
                                                        methodName:@"invoke"
                                                         arguments:node.arguments
                                                          location:node.location];
                [self analyzeNode:inv];
                node.indirectRewrite = inv;
                node.resolvedType = inv.resolvedType;
                return;
                }
            }
        // Name what is actually wrong. The old path reported "Call to
        // undeclared function '<indirect>'" — a name the user never wrote.
        [self.diagnostics emitError:[NSString stringWithFormat:
                                                  @"this expression is not callable%@",
                                                  ct ? [NSString stringWithFormat:@" (it is `%@`)", ct.displayName] : @""]
                                 at:node.location];
        node.resolvedType = [XTType u8Type];
        return;
        }
        // Indirect call through a pointer-to-function variable. Shadowing
        // follows normal C semantics: a local fn-pointer named the same as
        // a global function wins here (the user's local name is explicit).
        // The free-function overload lookup below only finds function
        // SYMBOLS, so fp-typed variables don't collide; but sema must check
        // the variable-symbol path first so `fp(args)` dispatches through
        // the pointer instead of erroring as "no function named fp".
        {
        XTSymbol* varSym = [[self currentScope] lookupSymbol:node.calleeName];
        if (varSym && varSym.storageClass != XTStorageClassFunction &&
            [varSym.symbolType isKindOfClass:[XTPointerType class]])
            {
            XTType* pointee = ((XTPointerType*)varSym.symbolType).pointeeType;
            if ([pointee isKindOfClass:[XTFunctionType class]])
                {
                XTFunctionType* ft = (XTFunctionType*)pointee;
                node.isIndirectCall = YES;
                node.resolvedType = ft.returnTypes.firstObject ?: [XTType voidType];
                return;
                }
            }
        // `h(args…)` where h is a bound method (`^`): an indirect call through
        // h.code with h.recv prepended as the implicit self. Flagged separately
        // so lowering knows to supply the receiver — a plain fn-pointer call
        // has no receiver to prepend.
        if (varSym && varSym.storageClass != XTStorageClassFunction &&
            varSym.symbolType.boundMethodSignature != nil)
            {
            XTFunctionType* ft =
                (XTFunctionType*)varSym.symbolType.boundMethodSignature;
            node.isIndirectCall = YES;
            node.isBoundCall = YES;
            node.resolvedType = ft.returnTypes.firstObject ?: [XTType voidType];
            for (XTASTNode* arg in node.arguments)
                [self analyzeNode:arg];
            return;
            }
        }
    // Resolve over the free-function overload set — but NOT when the enclosing
    // class already declares the name. Member scope is searched first, as it is
    // in every other language with methods: inside `Bag.twice`, a bare `add(v)`
    // means `self.add(v)`, whatever else is in the file.
    //
    // Without this a global function silently CAPTURED the call. It broke two
    // ways, both bad: when the global did not fit it errored ("'add' takes 2
    // arguments; 1 given") pointing INSIDE the standard library, and when it
    // did fit the class's own method simply never ran. Since the library is
    // full of ordinary names — add, get, set, count, remove, contains, hash —
    // one global in the user's program could break code they had not touched
    // (bug 040).
    NSArray<XTSymbol*>* cands =
        [self enclosingClassChainDeclaresMethodNamed:node.calleeName]
            ? @[]
            : [[self currentScope] lookupFunctionCandidates:node.calleeName];
    if (cands.count > 0)
        {
        XTSymbol* best = nil;
        NSInteger bestScore = NSIntegerMax;
        NSMutableArray<XTSymbol*>* tied = [NSMutableArray array];
        for (XTSymbol* s in cands)
            {
            if (![s.symbolType isKindOfClass:[XTFunctionType class]])
                continue;
            XTFunctionType* ft = (XTFunctionType*)s.symbolType;
            NSInteger sc = [self scoreCandidateParamTypes:ft.paramTypes
                                                isVarArgs:ft.isVarArgs
                                                arguments:node.arguments];
            if (sc == NSIntegerMax)
                continue;
            if (sc < bestScore)
                {
                best = s;
                bestScore = sc;
                [tied removeAllObjects];
                [tied addObject:s];
                }
            else if (sc == bestScore)
                {
                [tied addObject:s];
                }
            }
        BOOL ambiguous = tied.count > 1;
        // Return-type-aware tiebreaker: prefer the overload whose
        // return type matches the current expected-type context.
        // Falls back to float when no context is available.
        if (ambiguous)
            {
            XTSymbol* picked = [self tiebreakOverloadCandidates:tied
                                              returnTypeOfBlock:^XTType*(id c) {
                                                return ((XTFunctionType*)((XTSymbol*)c).symbolType).returnTypes.firstObject;
                                              }];
            if (picked)
                {
                best = picked;
                ambiguous = NO;
                }
            }
        // An auto-imported C proto is the LOWEST-precedence layer: libc's
        // variadic printf fits ANY argument list, so it would otherwise beat
        // a matching `use`-promoted static (`#use Stdio` + bare `printf` on
        // arm9 printed host-style hex instead of the contract's). Demote it
        // when a use-promoted method matches; explicit user declarations
        // never enter cImportFunctionNames, so only the import defers.
        if (best && !ambiguous && [self.cImportFunctionNames containsObject:node.calleeName] && [best.mangledName isEqualToString:node.calleeName] && [self hasUsePromotedMatchForCall:node])
            {
            best = nil;
            }
        if (best && !ambiguous)
            {
            node.resolvedMangledName = best.mangledName;
            XTFunctionType* ft = (XTFunctionType*)best.symbolType;
            node.resolvedType = ft.returnTypes.firstObject ?: [XTType voidType];
            [self applyAutoboxToArguments:node paramTypes:ft.paramTypes];
            [self applyUnboxToArguments:node paramTypes:ft.paramTypes];
            NSString* key = best.mangledName ?: node.calleeName;
            // Checked effects: a call that can raise must be inside a `try`, or
            // the caller must itself be `throws` so the error can propagate.
            if ([self.throwingFunctionKeys containsObject:key] && self.tryDepth == 0 && !self.currentFunctionThrows)
                {
                [self.diagnostics emitError:[NSString stringWithFormat:
                                                          @"'%@' is declared 'throws' — wrap the call in try { } catch (e) { }, "
                                                          @"or declare the caller 'throws' to propagate",
                                                          node.calleeName]
                                         at:node.location];
                }
            NSString* calleeLbl = [@"_fn_" stringByAppendingString:key];
            [self recordCallEdgeToLabel:calleeLbl];
            [self recordFnPointerArgs:node.arguments
                           paramTypes:ft.paramTypes
                          calleeLabel:calleeLbl];
            [self checkStackInstanceStrongParamArgs:ft.paramTypes
                                          arguments:node.arguments
                                         calleeDesc:[NSString stringWithFormat:@"'%@'", node.calleeName]
                                           location:node.location];
            [self checkBlockIntoBoundMethodArgs:ft.paramTypes
                                      arguments:node.arguments
                                     calleeDesc:[NSString stringWithFormat:@"'%@'", node.calleeName]
                                       location:node.location];
            return;
            }
        if (best && ambiguous)
            {
            [self.diagnostics emitError:[NSString stringWithFormat:@"Call to '%@(%@)' is ambiguous among %lu overloads",
                                                                   node.calleeName, [self describeArgTypes:node.arguments], (unsigned long)cands.count]
                                     at:node.location];
            node.resolvedType = [XTType u8Type];
            return;
            }
        // No free-function candidate fit (best == nil). libc/free functions are
        // the lowest-precedence layer for a bare call: if a `use`-promoted class
        // method matches instead (e.g. `Math.rand(u8)` for `rand(100)` when only
        // libc's `rand(void)` proto is in the free set), fall through to the
        // `use Klass;` resolution below rather than erroring on the misfit here.
        // end `if (!hasUsePromotedMatchForCall)` — else fall through to `use`
        if (![self hasUsePromotedMatchForCall:node])
            {
            if (cands.count == 1)
                {
                // Single candidate but no conversion: still record the name and let
                // downstream checks catch arg mismatches. Keeps the old behaviour
                // where a shallow call was accepted.
                XTSymbol* s = cands.firstObject;
                if ([s.symbolType isKindOfClass:[XTFunctionType class]])
                    {
                    XTFunctionType* ft = (XTFunctionType*)s.symbolType;
                    // Validate argument count up front. Same trap as the
                    // method-call path: silently accepting a count
                    // mismatch pushes / pops mismatched bytes around the
                    // JSR and the post-call RTS lands at a corrupted PC.
                    NSUInteger fixed = ft.paramTypes.count;
                    BOOL countOK = ft.isVarArgs
                                       ? (node.arguments.count >= fixed)
                                       : (node.arguments.count == fixed);
                    if (!countOK)
                        {
                        [self.diagnostics emitError:[NSString stringWithFormat:
                                                                  @"'%@' takes %@%lu argument%@; %lu given",
                                                                  node.calleeName,
                                                                  ft.isVarArgs ? @"at least " : @"",
                                                                  (unsigned long)fixed,
                                                                  fixed == 1 ? @"" : @"s",
                                                                  (unsigned long)node.arguments.count]
                                                 at:node.location];
                        node.resolvedType = [XTType u8Type];
                        return;
                        }
                    node.resolvedMangledName = s.mangledName;
                    node.resolvedType = ft.returnTypes.firstObject ?: [XTType voidType];
                    NSString* key = s.mangledName ?: node.calleeName;
                    NSString* calleeLbl = [@"_fn_" stringByAppendingString:key];
                    [self recordCallEdgeToLabel:calleeLbl];
                    [self recordFnPointerArgs:node.arguments
                                   paramTypes:ft.paramTypes
                                  calleeLabel:calleeLbl];
                    [self checkStackInstanceStrongParamArgs:ft.paramTypes
                                                  arguments:node.arguments
                                                 calleeDesc:[NSString stringWithFormat:@"'%@'", node.calleeName]
                                                   location:node.location];
                    [self checkBlockIntoBoundMethodArgs:ft.paramTypes
                                              arguments:node.arguments
                                             calleeDesc:[NSString stringWithFormat:@"'%@'", node.calleeName]
                                               location:node.location];
                    // PR4/PR9: the scorer may have rejected this single
                    // candidate on class-pointer subtype or protocol-
                    // conformance grounds — surface those errors instead
                    // of silently accepting. Other mismatches (width,
                    // unrelated scalar kinds) still fall through to the
                    // older shallow-accept behaviour.
                    NSUInteger np = MIN(ft.paramTypes.count, node.arguments.count);
                    for (NSUInteger i = 0; i < np; i++)
                        {
                        XTType* pt = ft.paramTypes[i];
                        XTASTNode* arg = node.arguments[i];
                        // A bound method is TWO words. It must never marshal into a
                        // slot that isn't a `^` — most sharply at a C boundary,
                        // where there is no C-ABI equivalent and it would arrive as
                        // garbage. (A plain function pointer `@`, and
                        // `&Class.staticMethod`, are single words and stay legal.)
                        if (arg.resolvedType.boundMethodSignature != nil && pt.boundMethodSignature == nil)
                            {
                            [self.diagnostics emitError:[NSString stringWithFormat:
                                                                      @"argument %lu of '%@': cannot pass a bound method "
                                                                      @"('^') where '%@' is expected — a '^' is two words "
                                                                      @"and has no equivalent there (a C function cannot "
                                                                      @"take one). Pass a plain function pointer ('@').",
                                                                      (unsigned long)(i + 1), node.calleeName,
                                                                      pt.displayName ?: @"?"]
                                                     at:node.location];
                            continue;
                            }
                        [self checkClassPointerAssign:pt
                                              rhsType:arg.resolvedType
                                              rhsNode:arg
                                                 site:[NSString stringWithFormat:
                                                                    @"argument %lu of '%@'",
                                                                    (unsigned long)(i + 1), node.calleeName]
                                             location:node.location];
                        }
                    return;
                    }
                }
            [self.diagnostics emitError:[NSString stringWithFormat:@"No overload of '%@' matches argument types (%@)",
                                                                   node.calleeName, [self describeArgTypes:node.arguments]]
                                     at:node.location];
            node.resolvedType = [XTType u8Type];
            return;
            }
        }
        {
        // `use Klass;` fallback — a bare call like `printf(...)` after
        // a `use Stdio;` directive resolves to Stdio.printf. Walk the
        // declared-use list (in source order) collecting candidate
        // static methods named the same as the callee from each
        // promoted class. Score across the union with the standard
        // overload scorer; if exactly one wins, stamp the call with
        // the owning class so codegen emits `_cls_<class>_<mangled>`
        // instead of `_fn_<callee>`. Multiple matches across
        // different used classes → ambiguity error.
        // member scope wins (147)
        if (self.usedClassNames.count > 0 && ![self enclosingClassChainDeclaresMethodNamed:node.calleeName])
            {
            NSMutableArray<XTMethodDeclNode*>* useCands = [NSMutableArray array];
            NSMutableArray<NSString*>* useCandClasses = [NSMutableArray array];
            for (NSString* useClassName in self.usedClassNames)
                {
                XTClassDeclNode* cls = self.classesByName[useClassName];
                if (!cls)
                    continue;
                for (XTMethodDeclNode* m in cls.methods)
                    {
                    if (![m.methodName isEqualToString:node.calleeName])
                        continue;
                    [useCands addObject:m];
                    [useCandClasses addObject:useClassName];
                    }
                }
            if (useCands.count > 0)
                {
                XTMethodDeclNode* bestM = nil;
                NSString* bestClass = nil;
                NSInteger bestScore = NSIntegerMax;
                BOOL amb = NO;
                for (NSUInteger ci = 0; ci < useCands.count; ci++)
                    {
                    XTMethodDeclNode* m = useCands[ci];
                    NSMutableArray<XTType*>* pt = [NSMutableArray array];
                    for (XTParamNode* p in m.parameters)
                        [pt addObject:p.paramType];
                    NSInteger sc = [self scoreCandidateParamTypes:pt
                                                        isVarArgs:m.isVarArgs
                                                        arguments:node.arguments];
                    if (sc == NSIntegerMax)
                        continue;
                    if (sc < bestScore)
                        {
                        bestM = m;
                        bestClass = useCandClasses[ci];
                        bestScore = sc;
                        amb = NO;
                        }
                    else if (sc == bestScore)
                        {
                        amb = YES;
                        }
                    }
                if (bestM && !amb)
                    {
                    // The BARE spelling of Stdio.printf/printfAt (via `use`)
                    // gets the SAME literal-format treatment as the explicit
                    // one: the type-directed %d/%u/%x → %l upgrade for
                    // statically-32-bit arguments, then the format check.
                    // Without this the two spellings DISAGREED at runtime —
                    // bare printed a u32's low 16 bits where explicit
                    // upgraded to the full value (finding #8).
                    if ([bestClass isEqualToString:@"Stdio"] &&
                        ([bestM.methodName isEqualToString:@"printf"] ||
                         [bestM.methodName isEqualToString:@"printfAt"]))
                        {
                        NSUInteger fmtIdx =
                            [bestM.methodName isEqualToString:@"printfAt"] ? 2 : 0;
                        if (node.arguments.count > fmtIdx &&
                            [node.arguments[fmtIdx] isKindOfClass:[XTLiteralStringNode class]])
                            {
                            XTLiteralStringNode* lit =
                                (XTLiteralStringNode*)node.arguments[fmtIdx];
                            NSString* rewritten =
                                [self typeDirectedFormatString:lit.stringValue
                                                     arguments:node.arguments
                                                    firstVaIdx:fmtIdx + 1];
                            if (rewritten)
                                {
                                XTLiteralStringNode* newLit =
                                    [[XTLiteralStringNode alloc] initWithString:rewritten
                                                                       location:lit.location];
                                newLit.resolvedType = lit.resolvedType;
                                NSMutableArray* newArgs = [node.arguments mutableCopy];
                                newArgs[fmtIdx] = newLit;
                                node.arguments = newArgs;
                                }
                            NSString* fmt =
                                ((XTLiteralStringNode*)node.arguments[fmtIdx]).stringValue;
                            [self checkPrintfFormat:fmt
                                          arguments:node.arguments
                                         firstVaIdx:fmtIdx + 1
                                           location:node.location
                                           callName:[NSString stringWithFormat:
                                                                  @"%@ (Stdio.%@ via use)",
                                                                  node.calleeName, bestM.methodName]];
                            }
                        }
                    [self checkThrowsEffectForMethod:bestM at:node.location];
                    node.resolvedMangledName = bestM.mangledName;
                    node.resolvedClassName = bestClass;
                    if (bestM.returnTypes.count > 0)
                        {
                        node.resolvedType = bestM.returnTypes.firstObject;
                        }
                    NSString* key = bestM.mangledName ?: bestM.methodName;
                    NSString* calleeLbl = [NSString stringWithFormat:
                                                        @"_cls_%@_%@", bestClass, key];
                    [self recordCallEdgeToLabel:calleeLbl];
                    NSMutableArray<XTType*>* pt = [NSMutableArray array];
                    for (XTParamNode* p in bestM.parameters)
                        {
                        [pt addObject:p.paramType];
                        }
                    [self recordFnPointerArgs:node.arguments
                                   paramTypes:pt
                                  calleeLabel:calleeLbl];
                    [self checkStackInstanceStrongParamArgs:pt
                                                  arguments:node.arguments
                                                 calleeDesc:[NSString stringWithFormat:
                                                                          @"'%@.%@' (via use)",
                                                                          bestClass, bestM.methodName]
                                                   location:node.location];
                    [self checkBlockIntoBoundMethodArgs:pt
                                              arguments:node.arguments
                                             calleeDesc:[NSString stringWithFormat:
                                                                      @"'%@.%@' (via use)",
                                                                      bestClass, bestM.methodName]
                                               location:node.location];
                    return;
                    }
                if (amb)
                    {
                    [self.diagnostics emitError:[NSString stringWithFormat:
                                                              @"Call to '%@' is ambiguous across `use`-promoted classes — multiple static methods match (%@)",
                                                              node.calleeName, [self describeArgTypes:node.arguments]]
                                             at:node.location];
                    node.resolvedType = [XTType u8Type];
                    return;
                    }
                }
            }

        // Check if this is an implicit self-method call within a class.
        // PR3: walk the parent chain — a bare call like `describe()`
        // inside a Dog method must resolve to Animal.describe if Dog
        // doesn't declare one. Candidate collection stops at the first
        // ancestor that declares the name so we never mix overloads
        // across hierarchy levels.
        BOOL isSelfMethod = NO;
        XTClassDeclNode* ownerCls = nil;
        if (self.currentClassNode)
            {
            NSMutableArray<XTMethodDeclNode*>* mcands = [NSMutableArray array];
            for (XTClassDeclNode* c = self.currentClassNode; c != nil; c = c.parentClass)
                {
                for (XTMethodDeclNode* m in c.methods)
                    {
                    if ([m.methodName isEqualToString:node.calleeName])
                        {
                        [mcands addObject:m];
                        }
                    }
                if (mcands.count > 0)
                    {
                    ownerCls = c;
                    break;
                    }
                }
            if (mcands.count > 0)
                {
                isSelfMethod = YES;
                XTMethodDeclNode* bestM = nil;
                NSInteger bestScore = NSIntegerMax;
                BOOL amb = NO;
                for (XTMethodDeclNode* m in mcands)
                    {
                    NSMutableArray<XTType*>* pt = [NSMutableArray array];
                    for (XTParamNode* p in m.parameters)
                        [pt addObject:p.paramType];
                    NSInteger sc = [self scoreCandidateParamTypes:pt isVarArgs:m.isVarArgs arguments:node.arguments];
                    if (sc == NSIntegerMax)
                        continue;
                    if (sc < bestScore)
                        {
                        bestM = m;
                        bestScore = sc;
                        amb = NO;
                        }
                    else if (sc == bestScore)
                        amb = YES;
                    }
                XTMethodDeclNode* chosen = nil;
                if (bestM && !amb)
                    {
                    node.resolvedMangledName = bestM.mangledName;
                    if (bestM.returnTypes.count > 0)
                        node.resolvedType = bestM.returnTypes.firstObject;
                    chosen = bestM;
                    }
                else if (mcands.count == 1)
                    {
                    // The single candidate scored as a misfit. Accepting it
                    // shallowly is the old behaviour and stays — a width or
                    // scalar-kind mismatch is a conversion, not a crash — but
                    // the ARGUMENT COUNT is checked, because getting that wrong
                    // pushes the wrong number of bytes and the callee reads its
                    // parameters from the wrong slots. That is not a subtle
                    // wrong answer; it is a null pointer in argument one.
                    XTMethodDeclNode* only = mcands.firstObject;
                    BOOL countOK = only.isVarArgs
                                       ? (node.arguments.count >= only.parameters.count)
                                       : (node.arguments.count == only.parameters.count);
                    if (!countOK)
                        {
                        [self.diagnostics emitError:[NSString stringWithFormat:
                                                                  @"'%@' takes %@%lu argument%@; %lu given",
                                                                  node.calleeName,
                                                                  only.isVarArgs ? @"at least " : @"",
                                                                  (unsigned long)only.parameters.count,
                                                                  only.parameters.count == 1 ? @"" : @"s",
                                                                  (unsigned long)node.arguments.count]
                                                 at:node.location];
                        node.resolvedType = [XTType u8Type];
                        return;
                        }
                    node.resolvedMangledName = only.mangledName;
                    if (only.returnTypes.count > 0)
                        node.resolvedType = only.returnTypes.firstObject;
                    chosen = only;
                    }
                if (chosen)
                    {
                    [self checkThrowsEffectForMethod:chosen at:node.location];
                    NSString* key = chosen.mangledName ?: chosen.methodName;
                    // Stamp the OWNING CLASS, not just the mangled name. A
                    // method's mangled name is unqualified, so `add` inside
                    // Bag.twice reached lowering as the bare name `add` — and
                    // lowering resolves a bare name against the free-function
                    // table first, where a global `add` was waiting. Sema had
                    // already chosen the method; the class name is what lets
                    // lowering honour that (bug 040). The use-promoted path a
                    // few lines up has always set both fields.
                    node.resolvedClassName =
                        ownerCls ? ownerCls.className : self.currentClassNode.className;
                    // PR3: call-graph edge points at the owning class's
                    // label so cross-unit static-frame analysis lines up
                    // with what codegen actually emits.
                    NSString* cls = ownerCls ? ownerCls.className : (self.currentClassNode.className ?: @"?");
                    NSString* calleeLbl =
                        [NSString stringWithFormat:@"_cls_%@_%@", cls, key];
                    [self recordCallEdgeToLabel:calleeLbl];
                    // PR8: virtual dispatch picks the right body at
                    // runtime; bare `foo()` inside a method body that
                    // resolves to an overridden method emits the
                    // _virtual_dispatch helper in codegen.
                    NSMutableArray<XTType*>* pt = [NSMutableArray array];
                    for (XTParamNode* p in chosen.parameters)
                        {
                        [pt addObject:p.paramType];
                        }
                    [self recordFnPointerArgs:node.arguments
                                   paramTypes:pt
                                  calleeLabel:calleeLbl];
                    [self checkStackInstanceStrongParamArgs:pt
                                                  arguments:node.arguments
                                                 calleeDesc:[NSString stringWithFormat:@"'%@.%@'", cls, chosen.methodName]
                                                   location:node.location];
                    [self checkBlockIntoBoundMethodArgs:pt
                                              arguments:node.arguments
                                             calleeDesc:[NSString stringWithFormat:@"'%@.%@'", cls, chosen.methodName]
                                               location:node.location];
                    // ARC 2d: a bare `self.x()` call propagates the
                    // outer method's receiver kind. We don't yet know
                    // the outer method's resolved bits at sema time,
                    // so conservatively mark the target as potentially
                    // non-heap — codegen will then skip the self retain
                    // on the target, losing the optimisation but keeping
                    // correctness.
                    chosen.hasNonHeapReceiver = YES;
                    }
                }
            }
        if (!isSelfMethod)
            {
            // Check for case mismatch — scan all symbols for a near-match
            NSString* suggestion = nil;
            for (NSString* key in [self currentScope].symbolNames)
                {
                if ([key caseInsensitiveCompare:node.calleeName] == NSOrderedSame)
                    {
                    suggestion = key;
                    break;
                    }
                }
            if (!suggestion && self.globalScope)
                {
                for (NSString* key in self.globalScope.symbolNames)
                    {
                    if ([key caseInsensitiveCompare:node.calleeName] == NSOrderedSame)
                        {
                        suggestion = key;
                        break;
                        }
                    }
                }
            if (suggestion)
                {
                [self.diagnostics emitError:[NSString stringWithFormat:@"No function named '%@'; did you mean '%@'?",
                                                                       node.calleeName, suggestion]
                                         at:node.location];
                }
            else
                {
                [self.diagnostics emitError:[NSString stringWithFormat:@"Call to undeclared function '%@'",
                                                                       node.calleeName]
                                         at:node.location];
                }
            node.resolvedType = [XTType u8Type];
            }
        }
    }

/****************************************************************************\
|* printf format-string checking. Parses the fmt string, walks the %-specifiers,
|* and matches each against the corresponding vararg's resolved type. Emits
|* category XTWarnPrintfFormat warnings (suppressible via -Wno-printf-format)
|* for every mismatch and for argument-count disagreement.
|*
|* Specifier → expected arg type:
|*   %d %u %x           narrow int (≤ 2 bytes). u32/i32/float/double/ptr warn.
|*   %ld %lu %lx        wide int   (4 bytes). float/double/ptr warn.
|*   %f                 float (exactly 5 bytes — width mismatch against double).
|*   %lf                double (exactly 8 bytes — width mismatch against float).
|*   %c                 narrow int (u8/i8/u16/i16 all accepted).
|*   %s                 pointer-to-u8 (string).
|*   %@                 class/struct pointer or class value.
|*
|* Non-literal format strings skip checking silently. %% consumes no arg.
\****************************************************************************/
- (void)checkPrintfFormat:(NSString*)fmt
                arguments:(NSArray<XTASTNode*>*)args
               firstVaIdx:(NSUInteger)firstVaIdx
                 location:(XTSourceLocation*)loc
                 callName:(NSString*)callName
    {
    NSMutableArray<NSString*>* specs = [NSMutableArray array];
    NSUInteger i = 0;
    NSUInteger n = fmt.length;
    while (i < n)
        {
        unichar c = [fmt characterAtIndex:i++];
        if (c != '%' || i >= n)
            continue;
        unichar s = [fmt characterAtIndex:i++];
        if (s == '%')
            continue;
        if (s == 'l')
            {
            if (i >= n)
                {
                [specs addObject:@"l?"];
                break;
                }
            unichar sub = [fmt characterAtIndex:i++];
            // `%ll<spec>` — 64-bit
            if (sub == 'l')
                {
                if (i >= n)
                    {
                    [specs addObject:@"ll?"];
                    break;
                    }
                unichar sub2 = [fmt characterAtIndex:i++];
                [specs addObject:[NSString stringWithFormat:@"ll%C", sub2]];
                continue;
                }
            [specs addObject:[NSString stringWithFormat:@"l%C", sub]];
            continue;
            }
        [specs addObject:[NSString stringWithFormat:@"%C", s]];
        }

    NSUInteger argCount = (args.count > firstVaIdx) ? args.count - firstVaIdx : 0;
    if (argCount != specs.count)
        {
        [self.diagnostics emitWarning:[NSString stringWithFormat:
                                                    @"%@: format string expects %lu argument%s, %lu supplied",
                                                    callName, (unsigned long)specs.count,
                                                    specs.count == 1 ? "" : "s",
                                                    (unsigned long)argCount]
                             category:XTWarnPrintfFormat
                                   at:loc];
        }

    NSUInteger pairs = MIN(specs.count, argCount);
    for (NSUInteger k = 0; k < pairs; k++)
        {
        NSString* spec = specs[k];
        XTASTNode* a = args[firstVaIdx + k];
        XTType* at = a.resolvedType;
        if (!at)
            continue;
        XTTypeKind kd = at.kind;

        BOOL isNarrowInt = (kd == XTTypeKindI8 || kd == XTTypeKindU8 ||
                            kd == XTTypeKindI16 || kd == XTTypeKindU16 ||
                            kd == XTTypeKindBool);
        BOOL isWideInt = (kd == XTTypeKindI32 || kd == XTTypeKindU32);
        BOOL isVeryWideInt = (kd == XTTypeKindI64 || kd == XTTypeKindU64);
        BOOL isInt = isNarrowInt || isWideInt || isVeryWideInt;
        BOOL isFloat = (kd == XTTypeKindFloat);
        BOOL isDouble = (kd == XTTypeKindDouble);
        BOOL isPointer = (kd == XTTypeKindPointer);
        BOOL isStruct = (kd == XTTypeKindStruct || kd == XTTypeKindClass);

        NSString* hint = nil;
        NSString* spelling = [NSString stringWithFormat:@"%%%@", spec];

        if ([spec isEqualToString:@"d"] || [spec isEqualToString:@"u"] ||
            [spec isEqualToString:@"x"])
            {
            if (isVeryWideInt)
                hint = @"use %ll<specifier> for 64-bit integers";
            else if (isWideInt)
                hint = @"use %l<specifier> for 32-bit integers";
            else if (isFloat || isDouble)
                hint = @"use %f or %lf for floating-point";
            else if (isPointer || isStruct)
                hint = nil;
            else if (isInt)
                continue; // OK, narrow int
            else
                hint = nil;
            }
        else if ([spec isEqualToString:@"ld"] || [spec isEqualToString:@"lu"] ||
                 [spec isEqualToString:@"lx"])
            {
            if (isVeryWideInt)
                hint = @"use %ll<specifier> for 64-bit integers";
            else if (isFloat || isDouble)
                hint = @"use %f or %lf for floating-point";
            else if (isInt)
                continue; // any int is fine; narrower widen in pack
            else
                hint = nil;
            }
        else if ([spec isEqualToString:@"lld"] || [spec isEqualToString:@"llu"] ||
                 [spec isEqualToString:@"llx"])
            {
            // The pack widens a narrower int into the 8-byte slot, so any
            // integer is readable here; only a non-integer is a mistake.
            if (isFloat || isDouble)
                hint = @"use %f or %lf for floating-point";
            else if (isInt)
                continue;
            else
                hint = nil;
            }
        else if ([spec isEqualToString:@"f"])
            {
            if (isDouble)
                hint = @"use %lf for double";
            else if (isFloat)
                continue;
            else
                hint = nil;
            }
        else if ([spec isEqualToString:@"lf"])
            {
            if (isFloat)
                hint = @"use %f for float";
            else if (isDouble)
                continue;
            else
                hint = nil;
            }
        else if ([spec isEqualToString:@"c"])
            {
            if (isNarrowInt)
                continue;
            hint = nil;
            }
        else if ([spec isEqualToString:@"s"])
            {
            // Accept pointer-to-u8/i8. displayName of `string` resolves
            // through XTPointerType; just require the kind.
            if (isPointer)
                continue;
            hint = nil;
            }
        else if ([spec isEqualToString:@"@"])
            {
            if (isStruct || isPointer)
                continue;
            hint = nil;
            }
        else
            {
            // Unknown specifier — printf itself will ignore it at runtime;
            // no diagnostic.
            continue;
            }

        NSString* msg = [NSString stringWithFormat:
                                      @"%@: '%@' expects %@ but argument %lu is %@%@%@",
                                      callName, spelling,
                                      [self expectedTypeForSpec:spec],
                                      (unsigned long)(k + 1),
                                      at.displayName,
                                      hint ? @" (" : @"",
                                      hint ? [hint stringByAppendingString:@")"] : @""];
        [self.diagnostics emitWarning:msg category:XTWarnPrintfFormat at:loc];
        }
    }

/****************************************************************************\
|* Parse a format string and return one XTType per conversion specifier,
|* suitable for use as an `self.expectedType` hint when resolving the
|* matching vararg. Unknown specifiers get a nil entry (sema treats
|* nil as "no hint" and falls back to the default tiebreaker).
\****************************************************************************/
- (NSArray*)fmtArgTypesForFormatString:(NSString*)fmt
    {
    // Returns one entry per conversion specifier, either an XTType
    // (overload-resolution hint) or NSNull if the specifier has no
    // useful hint (e.g. %s / %@ where the arg is a pointer / struct
    // and there's nothing to tiebreak).
    NSMutableArray* types = [NSMutableArray array];
    NSUInteger i = 0;
    NSUInteger n = fmt.length;
    while (i < n)
        {
        unichar c = [fmt characterAtIndex:i++];
        if (c != '%' || i >= n)
            continue;
        unichar s = [fmt characterAtIndex:i++];
        if (s == '%')
            continue;
        XTType* t = nil;
        if (s == 'l')
            {
            if (i >= n)
                break;
            unichar sub = [fmt characterAtIndex:i++];
            if (sub == 'd')
                t = [XTType i32Type];
            else if (sub == 'u')
                t = [XTType u32Type];
            else if (sub == 'x')
                t = [XTType u32Type];
            else if (sub == 'f')
                t = [XTType doubleType];
            }
        else if (s == 'd')
            t = [XTType i16Type];
        else if (s == 'u')
            t = [XTType u16Type];
        else if (s == 'x')
            t = [XTType u16Type];
        else if (s == 'f')
            t = [XTType floatType];
        else if (s == 'c')
            t = [XTType u8Type];
        [types addObject:(t ?: (id)[NSNull null])];
        }
    return types;
    }

/****************************************************************************\
|* Type-directed printf: given a LITERAL format string and the actual
|* variadic argument nodes (already analysed, so their resolvedType is set),
|* upgrade each 16-bit integer conversion whose argument is statically 32-bit
|* to its `l` (long) form — `%d`→`%ld`, `%u`→`%lu`, `%x`→`%lx` — so
|* `Stdio.printf("%d", w * h)` prints the full promoted product instead of
|* truncating to the low 16 bits. Conservative: mirrors Stdio.xc's own spec
|* grammar and bails (returns nil) on anything unrecognised or if the args
|* run out, rather than risk desynchronising the arg stream. Returns the
|* rewritten string only when a conversion was widened; nil otherwise.
\****************************************************************************/
- (nullable NSString*)typeDirectedFormatString:(NSString*)fmt
                                     arguments:(NSArray<XTASTNode*>*)args
                                    firstVaIdx:(NSUInteger)firstVa
    {
    NSMutableString* out = [NSMutableString string];
    NSUInteger i = 0, n = fmt.length, va = firstVa;
    BOOL changed = NO;
    while (i < n)
        {
        unichar c = [fmt characterAtIndex:i];
        if (c != '%')
            {
            [out appendFormat:@"%C", c];
            i++;
            continue;
            }
        [out appendString:@"%"];
        i++;
        if (i >= n)
            return nil;
        unichar s = [fmt characterAtIndex:i];
        if (s == '.')
            {
            [out appendString:@"."];
            i++;
            while (i < n)
                {
                unichar d = [fmt characterAtIndex:i];
                if (d < '0' || d > '9')
                    break;
                [out appendFormat:@"%C", d];
                i++;
                }
            if (i >= n)
                return nil;
            s = [fmt characterAtIndex:i];
            }
        if (s == '%')
            {
            [out appendString:@"%"];
            i++;
            continue;
            }
        if (s == 'd' || s == 'u' || s == 'x')
            {
            if (va >= args.count)
                return nil;
            XTType* at = args[va].resolvedType;
            // 8 bytes upgrades twice — `%d` on an i64 becomes `%lld`, not the
            // `%ld` that would still truncate. Same rule, one more width.
            if (at && at.isInteger && at.byteWidth >= 8)
                {
                [out appendString:@"ll"];
                changed = YES;
                }
            else if (at && at.isInteger && at.byteWidth >= 4)
                {
                [out appendString:@"l"];
                changed = YES;
                }
            [out appendFormat:@"%C", s];
            i++;
            va++;
            continue;
            }
        if (s == 'l')
            {
            [out appendString:@"l"];
            i++;
            if (i >= n)
                return nil;
            unichar sub = [fmt characterAtIndex:i];
            // an explicit `%ll<spec>`
            if (sub == 'l')
                {
                [out appendString:@"l"];
                i++;
                if (i >= n)
                    return nil;
                unichar sub2 = [fmt characterAtIndex:i];
                if (sub2 != 'd' && sub2 != 'u' && sub2 != 'x')
                    return nil;
                [out appendFormat:@"%C", sub2];
                i++;
                va++;
                continue;
                }
            // `%ld` on a 64-bit argument still truncates, so widen it too.
            if (sub == 'd' || sub == 'u' || sub == 'x')
                {
                XTType* lat = (va < args.count) ? args[va].resolvedType : nil;
                if (lat && lat.isInteger && lat.byteWidth >= 8)
                    {
                    [out appendString:@"l"];
                    changed = YES;
                    }
                }
            if (sub != 'd' && sub != 'u' && sub != 'x' && sub != 'f')
                return nil;
            [out appendFormat:@"%C", sub];
            i++;
            va++;
            continue;
            }
        if (s == 'c' || s == 's' || s == 'f' || s == 'e' || s == '@')
            {
            [out appendFormat:@"%C", s];
            i++;
            va++;
            continue;
            }
        return nil;
        }
    return changed ? out : nil;
    }

/****************************************************************************\
|* Human-readable expected-type string for a printf specifier.
\****************************************************************************/
- (NSString*)expectedTypeForSpec:(NSString*)spec
    {
    if ([spec isEqualToString:@"d"])
        return @"16-bit signed integer";
    if ([spec isEqualToString:@"u"])
        return @"16-bit unsigned integer";
    if ([spec isEqualToString:@"x"])
        return @"16-bit unsigned integer";
    if ([spec isEqualToString:@"ld"])
        return @"32-bit signed integer";
    if ([spec isEqualToString:@"lld"])
        return @"64-bit signed integer";
    if ([spec isEqualToString:@"llu"])
        return @"64-bit unsigned integer";
    if ([spec isEqualToString:@"llx"])
        return @"64-bit hex";
    if ([spec isEqualToString:@"lu"])
        return @"32-bit unsigned integer";
    if ([spec isEqualToString:@"lx"])
        return @"32-bit unsigned integer";
    if ([spec isEqualToString:@"f"])
        return @"float";
    if ([spec isEqualToString:@"lf"])
        return @"double";
    if ([spec isEqualToString:@"c"])
        return @"character";
    if ([spec isEqualToString:@"s"])
        return @"string";
    if ([spec isEqualToString:@"@"])
        return @"struct/class";
    return @"?";
    }

/****************************************************************************\
|* Visit a method call expression: analyse receiver and arguments, resolve
|* the target method on the receiver's class (static or instance), and set
|* the resolved return type and mangled name for codegen.
|* @param node  The method call expression node.
\****************************************************************************/
/****************************************************************************\
|* `w.onChange(7)` / `s.fn(6)`: the member named here is a FIELD holding
|* something callable, not a method. Rewrite the node into an ordinary
|* indirect call whose callee is the member access, and let the shared call
|* machinery do the rest.
|*
|* The parser cannot make this call — `base.member(args)` is one shape and it
|* has no types. Sema does, which is why the decision lives here rather than
|* in a second parser heuristic.
|*
|* A real METHOD of the same name always wins: this only fires when the class
|* chain declares no such method, so no existing program changes meaning.
|*
|* @return YES when the node was rewritten (the caller must return).
\****************************************************************************/
- (BOOL)rewriteFieldCallIfNeeded:(XTMethodCallExprNode*)node
    {
    XTType* recvType = node.receiver.resolvedType;
    if (!recvType)
        return NO;

    // Peel one pointer level: `w.onChange` and `p->onChange` reach the same
    // field, and a struct is usually held by pointer.
    XTType* base = recvType;
    if ([base isKindOfClass:[XTPointerType class]])
        base = ((XTPointerType*)base).pointeeType;
    if (!base)
        return NO;

    XTType* fieldType = nil;
    if (base.kind == XTTypeKindClass)
        {
        NSString* cn = base.displayName;
        XTClassDeclNode* cls = self.classesByName[cn];
        if (!cls)
            return NO;
        // A method of this name anywhere up the chain takes precedence.
        for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
            for (XTMethodDeclNode* m in c.methods)
                if ([m.methodName isEqualToString:node.methodName])
                    return NO;
        for (XTClassDeclNode* c = cls; c != nil && !fieldType; c = c.parentClass)
            for (XTVariableDeclNode* iv in c.ivars)
                if ([iv.varName isEqualToString:node.methodName])
                    {
                    fieldType = iv.declaredType;
                    break;
                    }
        }
    else if ([base isKindOfClass:[XTStructType class]])
        {
        XTStructField* f = [(XTStructType*)base fieldNamed:node.methodName];
        fieldType = f.fieldType;
        }
    if (!fieldType)
        return NO;

    // A BLOCK field is a pointer to its `Blk$…` impl class, and a block call
    // is `.invoke` dispatch — which is what the parser rewrites `b(1,2)` into
    // for a block LOCAL. Through a field it never got the chance, so do the
    // same rewrite here.
    if ([fieldType isKindOfClass:[XTPointerType class]])
        {
        XTType* pe = ((XTPointerType*)fieldType).pointeeType;
        if (pe && pe.kind == XTTypeKindClass && [pe.displayName hasPrefix:@"Blk$"])
            {
            XTMemberAccessNode* bma =
                [[XTMemberAccessNode alloc] initWithBase:node.receiver
                                              memberName:node.methodName
                                                 isArrow:NO
                                                location:node.location];
            XTMethodCallExprNode* inv =
                [[XTMethodCallExprNode alloc] initWithReceiver:bma
                                                    methodName:@"invoke"
                                                     arguments:node.arguments
                                                      location:node.location];
            [self analyzeNode:inv];
            node.indirectRewrite = inv;
            node.resolvedType = inv.resolvedType;
            return YES;
            }
        }

    BOOL callable = fieldType.boundMethodSignature != nil || ([fieldType isKindOfClass:[XTPointerType class]] && [((XTPointerType*)fieldType).pointeeType isKindOfClass:[XTFunctionType class]]);
    if (!callable)
        return NO;

    XTMemberAccessNode* ma =
        [[XTMemberAccessNode alloc] initWithBase:node.receiver
                                      memberName:node.methodName
                                         isArrow:NO
                                        location:node.location];
    XTCallExprNode* call = [[XTCallExprNode alloc] initWithCallee:@"<indirect>"
                                                        arguments:node.arguments
                                                         location:node.location];
    call.calleeExpr = ma;
    [self analyzeNode:call];
    node.indirectRewrite = call;
    node.resolvedType = call.resolvedType;
    return YES;
    }

- (void)visitMethodCallExpr:(XTMethodCallExprNode*)node
    {
    // See visitCallExpr: — checked, then dropped.
    if (node.forwardsVarargs)
        [self checkVarargForwardAt:node.location];
    // PR5: `super.method(args)` — dispatched directly to the parent
    // class's body with the current self pointer. Detect here
    // BEFORE the receiver is analysed so we don't emit a spurious
    // "undefined identifier 'super'" diagnostic. `super` isn't a
    // value — it's a call-prefix only, so any use outside this
    // method-call shape is still rejected by the identifier path.
    BOOL isSuperCall =
        [node.receiver isKindOfClass:[XTIdentifierNode class]] &&
        [((XTIdentifierNode*)node.receiver).identName isEqualToString:@"super"];
    if (isSuperCall)
        {
        if (!self.currentClassNode)
            {
            [self.diagnostics emitError:@"'super' is only valid inside a class method body"
                                     at:node.location];
            node.resolvedType = [XTType u8Type];
            return;
            }
        if (!self.currentClassNode.parentClass)
            {
            [self.diagnostics emitError:[NSString stringWithFormat:
                                                      @"Class '%@' has no parent to super-call",
                                                      self.currentClassNode.className]
                                     at:node.location];
            node.resolvedType = [XTType u8Type];
            return;
            }
        for (XTASTNode* arg in node.arguments)
            [self analyzeNode:arg];
        XTClassDeclNode* parent = self.currentClassNode.parentClass;
        NSMutableArray<XTMethodDeclNode*>* mcands = [NSMutableArray array];
        XTClassDeclNode* ownerCls = nil;
        for (XTClassDeclNode* c = parent; c != nil; c = c.parentClass)
            {
            for (XTMethodDeclNode* m in c.methods)
                {
                if ([m.methodName isEqualToString:node.methodName])
                    {
                    [mcands addObject:m];
                    }
                }
            if (mcands.count > 0)
                {
                ownerCls = c;
                break;
                }
            }
        if (mcands.count == 0)
            {
            [self.diagnostics emitError:[NSString stringWithFormat:
                                                      @"No method '%@' on super-chain of '%@'",
                                                      node.methodName, self.currentClassNode.className]
                                     at:node.location];
            node.resolvedType = [XTType u8Type];
            return;
            }
        XTMethodDeclNode* chosen = nil;
        NSInteger bestScore = NSIntegerMax;
        for (XTMethodDeclNode* m in mcands)
            {
            NSMutableArray<XTType*>* pt = [NSMutableArray array];
            for (XTParamNode* p in m.parameters)
                [pt addObject:p.paramType];
            NSInteger sc = [self scoreCandidateParamTypes:pt
                                                isVarArgs:m.isVarArgs
                                                arguments:node.arguments];
            if (sc < bestScore)
                {
                chosen = m;
                bestScore = sc;
                }
            }
        if (!chosen)
            {
            [self.diagnostics emitError:[NSString stringWithFormat:
                                                      @"No overload of 'super.%@' matches (%@)",
                                                      node.methodName, [self describeArgTypes:node.arguments]]
                                     at:node.location];
            node.resolvedType = [XTType u8Type];
            return;
            }
        node.resolvedMangledName = chosen.mangledName;
        node.resolvedClassName = ownerCls.className;
        // Same checked-effect rule as a free-function call: a method that can
        // raise must be called inside a `try`, or from a `throws` caller.
        // Checked off the DECL rather than the effect table, because the table
        // is populated from the free-function pre-pass only.
        if (chosen.throwsError && self.tryDepth == 0 && !self.currentFunctionThrows)
            {
            [self.diagnostics emitError:[NSString stringWithFormat:
                                                      @"'%@' is declared 'throws' — wrap the call in try { } catch (e) { }, "
                                                      @"or declare the caller 'throws' to propagate",
                                                      node.methodName]
                                     at:node.location];
            }
        NSString* key = chosen.mangledName ?: chosen.methodName;
        NSString* calleeLbl =
            [NSString stringWithFormat:@"_cls_%@_%@", ownerCls.className, key];
        [self recordCallEdgeToLabel:calleeLbl];
        // `super.foo` intentionally bypasses the override guard —
        // the user's writing `super.foo` is the whole point of
        // non-virtual dispatch.
        node.resolvedType = chosen.returnTypes.firstObject ?: [XTType voidType];
        return;
        }

    [self analyzeNode:node.receiver];

    // Not a method call at all — the member is a field holding a callback or
    // a function pointer. private:docs/bugs/074.
    if ([self rewriteFieldCallIfNeeded:node])
        return;

    // Stdio.printf / Stdio.printfAt with a literal format string:
    // propagate the expected-type for each vararg down into its
    // resolution so `Stdio.printf("%lf", Math.PI())` picks the
    // double overload of PI (and not the tiebreaker float). The
    // generic arg-visit below still runs for anything not caught
    // here (runtime-computed format strings, non-Stdio methods,
    // fixed params).
    NSArray* fmtArgTypes = nil;
    NSUInteger fmtFirstVaIdx = 0;
        {
        // Which literal-format calls get the expected-type hints and the
        // type-directed upgrade: Stdio.printf/printfAt, and (finding #8's
        // fallout) String.withFormat / appendFormat — the four formatters
        // share one width contract, so they must share one treatment. The
        // instance case keys off the RECEIVER'S resolved class, not its
        // spelling.
        BOOL isFmt = NO;
        NSUInteger fmtIdx = 0;
        BOOL recvIsStdio = [node.receiver isKindOfClass:[XTIdentifierNode class]] &&
                           [((XTIdentifierNode*)node.receiver).identName isEqualToString:@"Stdio"];
        BOOL recvIsStringCls = [node.receiver isKindOfClass:[XTIdentifierNode class]] &&
                               [((XTIdentifierNode*)node.receiver).identName isEqualToString:@"String"];
        if (recvIsStdio && ([node.methodName isEqualToString:@"printf"] ||
                            [node.methodName isEqualToString:@"printfAt"]))
            {
            isFmt = YES;
            fmtIdx = [node.methodName isEqualToString:@"printfAt"] ? 2 : 0;
            }
        else if (recvIsStringCls && [node.methodName isEqualToString:@"withFormat"])
            {
            isFmt = YES;
            }
        else if ([node.methodName isEqualToString:@"appendFormat"])
            {
            XTType* rt = node.receiver.resolvedType;
            XTType* pointee = [rt isKindOfClass:[XTPointerType class]]
                                  ? ((XTPointerType*)rt).pointeeType
                                  : rt;
            if ([pointee.displayName isEqualToString:@"String"])
                isFmt = YES;
            }
        if (isFmt && node.arguments.count > fmtIdx &&
            [node.arguments[fmtIdx] isKindOfClass:[XTLiteralStringNode class]])
            {
            NSString* fmt = ((XTLiteralStringNode*)node.arguments[fmtIdx]).stringValue;
            fmtArgTypes = [self fmtArgTypesForFormatString:fmt];
            fmtFirstVaIdx = fmtIdx + 1;
            }
        }

    if (fmtArgTypes)
        {
        for (NSUInteger i = 0; i < node.arguments.count; i++)
            {
            XTASTNode* arg = node.arguments[i];
            XTType* hint = nil;
            if (i >= fmtFirstVaIdx)
                {
                NSUInteger specIdx = i - fmtFirstVaIdx;
                if (specIdx < fmtArgTypes.count)
                    {
                    id entry = fmtArgTypes[specIdx];
                    if (entry != [NSNull null])
                        hint = (XTType*)entry;
                    }
                }
            XTType* prev = self.expectedType;
            if (hint)
                self.expectedType = hint;
            [self analyzeNode:arg];
            self.expectedType = prev;
            }
        // Type-directed format upgrade: widen `%d/%u/%x` to their `l` form
        // where the argument is statically 32-bit (integer promotion makes
        // `w * h` a u32). Replace the format-string node with a fresh literal
        // carrying the rewritten text.
        if (fmtFirstVaIdx > 0 &&
            [node.arguments[fmtFirstVaIdx - 1] isKindOfClass:[XTLiteralStringNode class]])
            {
            NSUInteger fmtIdx = fmtFirstVaIdx - 1;
            XTLiteralStringNode* lit = (XTLiteralStringNode*)node.arguments[fmtIdx];
            NSString* rewritten = [self typeDirectedFormatString:lit.stringValue
                                                       arguments:node.arguments
                                                      firstVaIdx:fmtFirstVaIdx];
            if (rewritten)
                {
                XTLiteralStringNode* newLit =
                    [[XTLiteralStringNode alloc] initWithString:rewritten
                                                       location:lit.location];
                newLit.resolvedType = lit.resolvedType;
                NSMutableArray* newArgs = [node.arguments mutableCopy];
                newArgs[fmtIdx] = newLit;
                node.arguments = newArgs;
                }
            }
        }
    else
        {
        for (XTASTNode* arg in node.arguments)
            [self analyzeNode:arg];
        }

    // Resolve the return type by looking up the target method on the
    // receiver's class. Works for both static calls (receiver is a class
    // name) and instance calls (receiver is a variable of a class type).
    XTType* resolved = nil;
    NSString* className = nil;
    // ARC 2d receiver-kind classification. Heap = pointer-to-class
    // receiver (safe to retain self inside the method). Non-heap =
    // bare class-value (stack instance — retain would touch ZP
    // bytes) or class-name identifier (static method; the method
    // doesn't use self anyway, but tagging it lets the codegen gate
    // cheaply).
    BOOL recvIsHeap = NO;
    BOOL recvIsNonHeap = NO;
    if ([node.receiver isKindOfClass:[XTIdentifierNode class]])
        {
        NSString* recvName = ((XTIdentifierNode*)node.receiver).identName;
        if (self.classesByName[recvName])
            {
            className = recvName;
            recvIsNonHeap = YES; // static method dispatch
            }
        else
            {
            XTType* recvType = node.receiver.resolvedType;
            if (recvType)
                {
                // Prefer pointee type when the receiver is a pointer
                // — strips any `banked:`/`shadow:`/`main:` placement
                // prefix from the display name that would otherwise
                // fail the self.classesByName lookup.
                NSString* tn = nil;
                if ([recvType isKindOfClass:[XTPointerType class]])
                    {
                    XTType* pointee = ((XTPointerType*)recvType).pointeeType;
                    if (pointee && pointee.kind == XTTypeKindClass)
                        {
                        tn = pointee.displayName;
                        recvIsHeap = YES;
                        }
                    }
                if (tn == nil)
                    {
                    tn = recvType.displayName;
                    if ([tn hasSuffix:@"@"])
                        tn = [tn substringToIndex:tn.length - 1];
                    if (recvType.kind == XTTypeKindClass)
                        {
                        recvIsNonHeap = YES; // bare stack-allocated class
                        }
                    }
                if (self.classesByName[tn])
                    className = tn;
                }
            }
        }
    else
        {
        // Non-identifier receiver (e.g. `(expr).method()`, chained call
        // results). Fall back to resolvedType; assume heap if pointer-
        // to-class, non-heap otherwise. Static dispatch only reaches
        // here via a class identifier so the non-heap fallback is
        // conservative-correct.
        XTType* recvType = node.receiver.resolvedType;
        if (recvType)
            {
            if ([recvType isKindOfClass:[XTPointerType class]])
                {
                XTType* pointee = ((XTPointerType*)recvType).pointeeType;
                if (pointee && pointee.kind == XTTypeKindClass)
                    {
                    className = pointee.displayName;
                    recvIsHeap = YES;
                    }
                }
            else if (recvType.kind == XTTypeKindClass)
                {
                className = recvType.displayName;
                recvIsNonHeap = YES;
                }
            }
        }

        // PR9: protocol-constrained receiver. The receiver's resolved
        // type carries a `protocolConstraint` set by parseType when the
        // user writes a bare protocol name as a type (`Drawable@`); the
        // method resolution walks the protocol's method list on a hit
        // and stamps the protocol's vtable slot on the AST so codegen
        // emits a virtual dispatch keyed by the instance's class-id
        // byte rather than a concrete class label.
        {
        XTType* rt = node.receiver.resolvedType;
        XTType* constraintCarrier = nil;
        if ([rt isKindOfClass:[XTPointerType class]])
            {
            constraintCarrier = ((XTPointerType*)rt).pointeeType;
            }
        else if (rt && rt.kind == XTTypeKindClass)
            {
            constraintCarrier = rt;
            }
        NSString* protoName = constraintCarrier.protocolConstraint;
        if (protoName.length > 0)
            {
            XTProtocolDeclNode* proto = self.protocolsByName[protoName];
            if (!proto)
                {
                [self.diagnostics emitError:[NSString stringWithFormat:
                                                          @"Unknown protocol '%@' in receiver type", protoName]
                                         at:node.location];
                node.resolvedType = [XTType u8Type];
                return;
                }
            XTMethodDeclNode* match = nil;
            for (XTMethodDeclNode* m in proto.methods)
                {
                if ([m.methodName isEqualToString:node.methodName])
                    {
                    match = m;
                    break;
                    }
                }
            if (!match)
                {
                [self.diagnostics emitError:[NSString stringWithFormat:
                                                          @"Protocol '%@' has no method '%@'",
                                                          protoName, node.methodName]
                                         at:node.location];
                node.resolvedType = [XTType u8Type];
                return;
                }
            // An optional method may have an empty (null) vtable slot, so a
            // direct call could jump through zero. Force the caller through
            // `&recv.method` + a null test — which also covers a null
            // receiver. See private:docs/Design/bound-methods.md.
            if (match.isOptional)
                {
                NSString* recvName = @"recv";
                if (node.receiver.nodeKind == XTASTNodeKindIdentifier)
                    recvName = ((XTIdentifierNode*)node.receiver).identName;
                [self.diagnostics emitError:[NSString stringWithFormat:
                                                          @"'%@' is optional on protocol '%@' — it may not be "
                                                          @"implemented, so it cannot be called directly. Take "
                                                          @"'&%@.%@' and test it before calling.",
                                                          node.methodName, protoName, recvName, node.methodName]
                                         at:node.location];
                node.resolvedType = match.returnTypes.firstObject ?: [XTType voidType];
                return;
                }
            for (XTASTNode* arg in node.arguments)
                [self analyzeNode:arg];
            NSNumber* slotNum = self.protocolMethodSlots[protoName][node.methodName];
            if (slotNum)
                {
                node.resolvedVirtualSlot = slotNum;
                }
            // The protocol-relative identity, which needs no cross-module agreement.
            node.resolvedProtocolName = protoName;
            NSUInteger mi = 0;
            for (XTMethodDeclNode* pm in proto.methods)
                {
                if ([pm.methodName isEqualToString:node.methodName])
                    {
                    node.resolvedProtocolIndex = @(mi);
                    break;
                    }
                mi++;
                }
            node.resolvedType = match.returnTypes.firstObject ?: [XTType voidType];
            return;
            }
        }

    // Auto-recognised clone() on any class: no user method declaration
    // required, the compiler emits a byte-for-byte copy at the call
    // site. The return value is a class-value (bare XTTypeKindClass
    // marker), which is valid as a declaration-initialiser or copy-
    // assignment RHS. Other contexts will be rejected by the codegen
    // until full class return-by-value is wired up.
    if (className && [node.methodName isEqualToString:@"clone"] &&
        node.arguments.count == 0)
        {
        XTClassDeclNode* cls = self.classesByName[className];
        BOOL userHasClone = NO;
        for (XTMethodDeclNode* m in cls.methods)
            {
            if ([m.methodName isEqualToString:@"clone"] &&
                m.parameters.count == 0)
                {
                userHasClone = YES;
                break;
                }
            }
        if (!userHasClone)
            {
            node.resolvedType = [self.typeTable typeForName:className];
            return;
            }
        // If the user defined their own clone(), fall through to the
        // normal method-resolution path so their version is called.
        }

    if (className)
        {
        XTClassDeclNode* cls = self.classesByName[className];
        // PR3: walk the parent chain for method lookup. Subclass's own
        // methods take priority; missing ones fall back to the nearest
        // ancestor that defines them. `ownerCls` tracks the class that
        // actually declared the winning method — codegen reads it to
        // emit `_cls_<owner>_<mangled>` so inherited calls land on
        // the parent's body. Until PR8 introduces link-time dispatch
        // inference, every call statically resolves to a single owner.
        NSMutableArray<XTMethodDeclNode*>* mcands = [NSMutableArray array];
        XTClassDeclNode* ownerCls = nil;
        for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
            {
            for (XTMethodDeclNode* m in c.methods)
                {
                if ([m.methodName isEqualToString:node.methodName])
                    {
                    if (![self memberVisibleUnderMigrate:m ofClass:c])
                        continue;
                    [mcands addObject:m];
                    }
                }
            if (mcands.count > 0)
                {
                ownerCls = c;
                break;
                }
            }
        if (mcands.count == 0)
            {
            [self.diagnostics emitError:[NSString stringWithFormat:@"No method '%@' on class '%@'",
                                                                   node.methodName, className]
                                     at:node.location];
            }
        else
            {
            XTMethodDeclNode* bestM = nil;
            NSInteger bestScore = NSIntegerMax;
            NSMutableArray<XTMethodDeclNode*>* tied = [NSMutableArray array];
            for (XTMethodDeclNode* m in mcands)
                {
                NSMutableArray<XTType*>* pt = [NSMutableArray array];
                for (XTParamNode* p in m.parameters)
                    [pt addObject:p.paramType];
                NSInteger sc = [self scoreCandidateParamTypes:pt isVarArgs:m.isVarArgs arguments:node.arguments];
                if (sc == NSIntegerMax)
                    continue;
                if (sc < bestScore)
                    {
                    bestM = m;
                    bestScore = sc;
                    [tied removeAllObjects];
                    [tied addObject:m];
                    }
                else if (sc == bestScore)
                    [tied addObject:m];
                }
            BOOL amb = tied.count > 1;
            if (amb)
                {
                XTMethodDeclNode* picked = [self tiebreakOverloadCandidates:tied
                                                          returnTypeOfBlock:^XTType*(id c) {
                                                            return ((XTMethodDeclNode*)c).returnTypes.firstObject;
                                                          }];
                if (picked)
                    {
                    bestM = picked;
                    amb = NO;
                    }
                }
            XTMethodDeclNode* chosen = nil;
            if (bestM && !amb)
                {
                node.resolvedMangledName = bestM.mangledName;
                if (bestM.returnTypes.count > 0)
                    resolved = bestM.returnTypes.firstObject;
                chosen = bestM;
                }
            else if (mcands.count == 1)
                {
                // Single candidate by name. Validate the argument
                // count BEFORE accepting — `scoreCandidateParamTypes`
                // would have returned NSIntegerMax for a mismatch
                // (skipping it during overload scoring), but this
                // fallback path still wants to accept a single
                // unique candidate. Without the check, calling
                // `g.bezier(0,0,0,0,0,0,0,0)` on a 6-param method
                // pushes 8 args, the callee pops 6, and the 2 extra
                // i16 (4 bytes) on the hardware stack make RTS pop
                // the wrong return address — landing PC in the
                // stack page = CIM at runtime.
                XTMethodDeclNode* only = mcands.firstObject;
                NSUInteger fixed = only.parameters.count;
                BOOL countOK = only.isVarArgs
                                   ? (node.arguments.count >= fixed)
                                   : (node.arguments.count == fixed);
                if (countOK)
                    {
                    node.resolvedMangledName = only.mangledName;
                    if (only.returnTypes.count > 0)
                        resolved = only.returnTypes.firstObject;
                    chosen = only;
                    }
                else
                    {
                    [self.diagnostics emitError:[NSString stringWithFormat:
                                                              @"'%@.%@' takes %@%lu argument%@; %lu given",
                                                              className, node.methodName,
                                                              only.isVarArgs ? @"at least " : @"",
                                                              (unsigned long)fixed,
                                                              fixed == 1 ? @"" : @"s",
                                                              (unsigned long)node.arguments.count]
                                             at:node.location];
                    }
                }
            else if (amb)
                {
                [self.diagnostics emitError:[NSString stringWithFormat:@"Call to '%@.%@(%@)' is ambiguous",
                                                                       className, node.methodName,
                                                                       [self describeArgTypes:node.arguments]]
                                         at:node.location];
                }
            else
                {
                [self.diagnostics emitError:[NSString stringWithFormat:@"No overload of '%@.%@' matches argument types (%@)",
                                                                       className, node.methodName,
                                                                       [self describeArgTypes:node.arguments]]
                                         at:node.location];
                }
            if (chosen)
                {
                [self checkThrowsEffectForMethod:chosen at:node.location];
                // private:docs/bugs/050 — a call that supplies MORE than the callee's
                // named parameters writes the shared vararg buffer.
                if (chosen.isVarArgs && !node.forwardsVarargs && node.arguments.count > chosen.parameters.count)
                    {
                    [self notePackingVariadicCall:
                              [NSString stringWithFormat:@"%@.%@", className ?: @"", node.methodName]
                                               at:node.location];
                    }
                // PR3: when the call resolves to an inherited method,
                // stamp the owning class on the AST so codegen builds
                // the correct `_cls_<owner>_<mangled>` label. Falls
                // back to the receiver's class name on a local hit —
                // ownerCls == cls in that case — keeping pre-PR3
                // emission unchanged for non-inherited calls.
                NSString* ownerName = ownerCls ? ownerCls.className : className;
                if (ownerCls && ownerCls != cls)
                    {
                    node.resolvedClassName = ownerName;
                    }
                NSString* key = chosen.mangledName ?: chosen.methodName;
                NSString* calleeLbl =
                    [NSString stringWithFormat:@"_cls_%@_%@", ownerName, key];
                [self recordCallEdgeToLabel:calleeLbl];
                // PR8: calls resolving to a method that's overridden
                // somewhere in the program pick up a vtable slot;
                // codegen detects that via `virtualSlotByLabel` and
                // emits the _virtual_dispatch helper rather than a
                // direct JSR. No sema-side diagnostic any more —
                // the dispatch works.
                NSMutableArray<XTType*>* pt = [NSMutableArray array];
                for (XTParamNode* p in chosen.parameters)
                    {
                    [pt addObject:p.paramType];
                    }
                    // Typed collection: a parameter the container declares as
                    // `Object*` means "an element", so it reads as the element type
                    // here — putting a Dog into an `Array<String>*` is an error at
                    // the call, not a surprise at the far end. Reuses the ordinary
                    // class-pointer assignability rule, so a SUBCLASS of the
                    // element type is accepted and so is a conforming class when
                    // the element type is a protocol.
                    {
                    // An erased position only means "the element" in a method
                    // the CONTAINER declares. The ones inherited from the root
                    // `Object` — `equals(Object*)`, `hash`, `description` — mean
                    // "any object" and "myself", and reading them as the element
                    // is wrong in both directions: it REFUSED `a.equals(b)` on
                    // two `Array<String>*` (private:docs/bugs/055) and silently retyped
                    // `copy()` as the element (private:docs/bugs/051).
                    //
                    // Tested by WHERE the method is declared, not by its name.
                    // `get`/`add`/`first`/`enumAt` are declared on Array, so
                    // they substitute; anything found only on Object does not,
                    // and a method added to Object later is covered without
                    // touching a list. A container that wants a typed `copy`
                    // declares its own — returns are covariant (051).
                    BOOL fromRoot = ownerCls && [ownerCls.className isEqualToString:@"Object"];
                    XTType* recvT = node.receiver.resolvedType;
                    XTType* carrier = [recvT isKindOfClass:[XTPointerType class]]
                                          ? ((XTPointerType*)recvT).pointeeType
                                          : recvT;
                    if (carrier.collectionElementType && carrier.displayName)
                        [self.classesUsedWithTypeArgument addObject:carrier.displayName];
                    XTType* elem = fromRoot ? nil
                                            : XTCollectionElementOf(node.receiver.resolvedType);
                    if (elem)
                        {
                        NSString* site = [NSString stringWithFormat:
                                                       @"'%@.%@' element", className, chosen.methodName];
                        for (NSUInteger ai = 0; ai < pt.count && ai < node.arguments.count; ai++)
                            {
                            if (!XTIsErasedElementType(pt[ai]))
                                continue;
                            XTASTNode* arg = node.arguments[ai];
                            if (elem.kind == XTTypeKindClass)
                                {
                                [self checkClassPointerAssign:[XTPointerType pointerToType:elem]
                                                      rhsType:arg.resolvedType
                                                      rhsNode:arg
                                                         site:site
                                                     location:node.location];
                                continue;
                                }
                            // A PRIMITIVE element type. The value still travels
                            // boxed — sema's autobox wraps it in a Number, and
                            // `i32 v = a.get(i)` unboxes on the way out — but
                            // conformance is judged by the DECLARED type, so an
                            // `Array<i32>` refuses a float even though both box
                            // into the same Number.
                            XTType* at = arg.resolvedType;
                            if (!at || !(at.isInteger || at.isFloating))
                                continue;
                            if (at.isFloating != elem.isFloating)
                                {
                                [self.diagnostics emitError:[NSString stringWithFormat:
                                                                          @"%@: '%@' cannot be stored in a collection of '%@'",
                                                                          site, at.displayName, elem.displayName]
                                                         at:node.location];
                                }
                            }
                        }
                    // The KEY, when one was written. `Map<String, Point>` means
                    // `set(String*, Point*)`; before this the key position was
                    // erased to `Hashable*` and accepted anything hashable, so
                    // half of a two-argument map went unchecked.
                    XTType* keyT = fromRoot ? nil
                                            : XTCollectionKeyOf(node.receiver.resolvedType);
                    if (keyT && keyT.kind == XTTypeKindClass)
                        {
                        NSString* ksite = [NSString stringWithFormat:
                                                        @"'%@.%@' key", className, chosen.methodName];
                        for (NSUInteger ai = 0; ai < pt.count && ai < node.arguments.count; ai++)
                            {
                            if (!XTIsErasedKeyType(pt[ai]))
                                continue;
                            XTASTNode* arg = node.arguments[ai];
                            [self checkClassPointerAssign:[XTPointerType pointerToType:keyT]
                                                  rhsType:arg.resolvedType
                                                  rhsNode:arg
                                                     site:ksite
                                                 location:node.location];
                            }
                        }
                    }
                [self applyAutoboxToArguments:node paramTypes:pt];
                [self applyUnboxToArguments:node paramTypes:pt];
                [self recordFnPointerArgs:node.arguments
                               paramTypes:pt
                              calleeLabel:calleeLbl];
                [self checkStackInstanceStrongParamArgs:pt
                                              arguments:node.arguments
                                             calleeDesc:[NSString stringWithFormat:@"'%@.%@'", className, chosen.methodName]
                                               location:node.location];
                [self checkBlockIntoBoundMethodArgs:pt
                                          arguments:node.arguments
                                         calleeDesc:[NSString stringWithFormat:@"'%@.%@'", className, chosen.methodName]
                                           location:node.location];
                // ARC 2d: OR this call site's receiver kind into the
                // target method's bits. Codegen's method prologue reads
                // these to decide whether it's safe to retain `self`.
                if (recvIsHeap)
                    chosen.hasHeapReceiver = YES;
                if (recvIsNonHeap)
                    chosen.hasNonHeapReceiver = YES;
                }
            }
        }
        // Typed collection: a call on an `Array<String>*` reads its own element
        // type back rather than the erased `Object*`, so `a.get(i)` is a `String*`
        // with no cast at the use site. Substitution rather than instantiation —
        // there is still exactly one Array, holding Object* as it always did.
        {
        XTType* elem = XTCollectionElementOf(node.receiver.resolvedType);
        // Only a CLASS element substitutes. A primitive one still comes back
        // boxed — the value in the collection really is a `Number`, and sema's
        // existing unbox turns `i32 v = a.get(i)` into
        // `((Number*)a.get(i)).asI32()`. Rewriting the return to `i32*` would
        // describe a pointer to an integer, which is not what is there, and it
        // stops the unbox firing because that keys off `Object*`.
        // `Object*` in a container's signature means "one of my elements" —
        // that IS the erasure convention, and it is why substitution is sound.
        // Anything that means something else must SAY so: returns are
        // covariant, so `Array.copy` declares `Array*` rather than inheriting
        // `Copying`'s `Object*`. It used to inherit it, and this substituted —
        // `Array<String>.copy()` was typed `String*`, so the assignment check
        // never saw an Array at all. Fixed in the library, where the type was
        // wrong, rather than by excluding a method name here. private:docs/bugs/051.
        if (elem && elem.kind == XTTypeKindClass && XTIsErasedElementType(resolved))
            {
            // Keep the PLACEMENT of the pointer the callee actually returns and
            // swap only the pointee. Placement is part of a pointer's width, so
            // building a default-placement pointer here silently narrowed the
            // value on targets where the two differ, and the object header was
            // then read through a truncated pointer.
            XTPointerPlacement place = ((XTPointerType*)resolved).placement;
            // Remember what the callee REALLY returns. Lowering types the Call
            // by that and bitcasts to the substituted type; without it the IR
            // would claim `Array$get` returns a String, and the inliner would
            // paste the body in against the wrong aggregate layout.
            node.erasedReturnType = resolved;
            resolved = [XTPointerType pointerToType:elem placement:place];
            }
        }

    node.resolvedType = resolved ?: [XTType u8Type];

    // Stdio.printf / Stdio.printfAt / String.withFormat / String.appendFormat
    // — check format specifiers against argument types. The check fires only
    // when the format argument is a compile-time string literal (anything
    // computed at runtime is unknowable at sema time). String's formatters
    // share Stdio's width contract (%d/%u = 16-bit, %ld = 32, %lld = 64), and
    // were UNCOVERED — a u32 against %u silently printed its low 16 bits
    // (finding #14's second half), which this warning is exactly for.
    BOOL fmtCheck = ([className isEqualToString:@"Stdio"] &&
                     ([node.methodName isEqualToString:@"printf"] ||
                      [node.methodName isEqualToString:@"printfAt"])) ||
                    ([className isEqualToString:@"String"] &&
                     ([node.methodName isEqualToString:@"withFormat"] ||
                      [node.methodName isEqualToString:@"appendFormat"]));
    if (fmtCheck)
        {
        NSUInteger fmtIdx = [node.methodName isEqualToString:@"printfAt"] ? 2 : 0;
        if (node.arguments.count > fmtIdx)
            {
            XTASTNode* fmtArg = node.arguments[fmtIdx];
            if ([fmtArg isKindOfClass:[XTLiteralStringNode class]])
                {
                NSString* fmt = ((XTLiteralStringNode*)fmtArg).stringValue;
                [self checkPrintfFormat:fmt
                              arguments:node.arguments
                             firstVaIdx:fmtIdx + 1
                               location:node.location
                               callName:[NSString stringWithFormat:@"%@.%@", className, node.methodName]];
                }
            }
        }
    }

/****************************************************************************\
|* Visit a subscript expression: analyse base and index, resolve element type.
|* @param node  The subscript expression node.
\****************************************************************************/
- (void)visitSubscriptExpr:(XTSubscriptExprNode*)node
    {
    [self analyzeNode:node.base];
    [self analyzeNode:node.index];
    XTType* baseType = node.base.resolvedType;
    if ([baseType isKindOfClass:[XTArrayType class]])
        {
        node.resolvedType = ((XTArrayType*)baseType).elementType;
        }
    else if ([baseType isKindOfClass:[XTPointerType class]])
        {
        node.resolvedType = ((XTPointerType*)baseType).pointeeType;
        }
    else
        {
        node.resolvedType = [XTType u8Type];
        }
    }

/****************************************************************************\
|* Visit a slice expression: analyse base + bounds, resolve to the element
|* type for now (since slices today only appear as the iterable of a
|* for-in loop, where the loop body sees one element at a time). Sema
|* doesn't reject the slice in other positions here; the for-in
|* lowering in codegen is the only consumer that knows how to emit
|* one, so a stray slice elsewhere will surface as missing-codegen
|* later. Future PR may introduce a real slice value type.
\****************************************************************************/
- (void)visitSliceExpr:(XTSliceExprNode*)node
    {
    [self analyzeNode:node.base];
    if (node.startExpr)
        [self analyzeNode:node.startExpr];
    if (node.endExpr)
        [self analyzeNode:node.endExpr];
    XTType* baseType = node.base.resolvedType;
    if ([baseType isKindOfClass:[XTArrayType class]])
        {
        node.resolvedType = ((XTArrayType*)baseType).elementType;
        }
    else if ([baseType isKindOfClass:[XTPointerType class]])
        {
        node.resolvedType = ((XTPointerType*)baseType).pointeeType;
        }
    else
        {
        node.resolvedType = [XTType u8Type];
        }
    }

/****************************************************************************\
|* Visit a range expression (`start..end` / `start...end`). Resolves
|* the bounds, picks the wider integer type as the range's value
|* type. Used today only as the initialiser of a fixed-size array;
|* the array-init codegen iterates start → end and writes each
|* value into the matching slot.
\****************************************************************************/
- (void)visitRangeExpr:(XTRangeExprNode*)node
    {
    [self analyzeNode:node.startExpr];
    [self analyzeNode:node.endExpr];
    // A range is SYNTAX, not a value: `for … in` desugars it in the parser and
    // an array initialiser consumes it here, and there is no third thing it can
    // become. Reaching sema anywhere else used to survive to lowering and
    // abandon with "unsupported expression kind 33" — an internal node number,
    // naming neither ranges nor where they are allowed. private:docs/bugs/048.
    if (!self.rangeInInitialiserPosition)
        {
        [self.diagnostics emitError:
                              @"a range is only valid as a `for … in` collection or as an array "
                              @"initialiser — it is not a value, so it cannot be assigned, "
                              @"passed or returned"
                                 at:node.location];
        }
    NSUInteger sw = node.startExpr.resolvedType
                        ? node.startExpr.resolvedType.byteWidth
                        : 1;
    NSUInteger ew = node.endExpr.resolvedType
                        ? node.endExpr.resolvedType.byteWidth
                        : 1;
    NSUInteger w = MAX(sw, ew);
    if (w >= 4)
        node.resolvedType = [XTType u32Type];
    else if (w >= 2)
        node.resolvedType = [XTType u16Type];
    else
        node.resolvedType = [XTType u8Type];
    }

/****************************************************************************\
|* Visit a member access expression (`.` or `->`): analyse the base, unwrap
|* pointer types, and resolve the member's type from a struct or class.
|* @param node  The member access node.
\****************************************************************************/
- (void)visitMemberAccess:(XTMemberAccessNode*)node
    {
    [self analyzeNode:node.base];
    XTType* rawBase = node.base.resolvedType;

    // `.length` pseudo-property. Works on:
    //   - any fixed-size array type — resolves at codegen time to the
    //     array's elementCount as a compile-time u16 constant.
    //   - a pointer that lowering RECORDED a length for: `new T[N]` with a
    //     constant N, assigned to a named local, read in the same function.
    //     That is a compile-time map keyed on the variable name, NOT the
    //     runtime header read this comment used to claim — a runtime count
    //     has no entry and fails in lowering. private:docs/bugs/045.
    if ([node.memberName isEqualToString:@"length"] &&
        ([rawBase isKindOfClass:[XTArrayType class]] ||
         [rawBase isKindOfClass:[XTPointerType class]]))
        {
        node.resolvedType = [XTType u16Type];
        return;
        }

    XTType* baseType = rawBase;
    // Unwrap pointer bases for both `.` and `->`: a variable of class
    // type is modeled as a pointer-to-class-marker, so `eg.field` and
    // `ptr->field` share the same field-lookup path.
    if ([baseType isKindOfClass:[XTPointerType class]])
        {
        baseType = ((XTPointerType*)baseType).pointeeType;
        }
    if ([baseType isKindOfClass:[XTStructType class]])
        {
        XTStructType* st = (XTStructType*)baseType;
        XTStructField* field = [st fieldNamed:node.memberName];
        if (!field)
            {
            // A field that doesn't exist is a semantic ERROR, not something to
            // shrug at. This used to resolve silently to u8; lowering then
            // couldn't find the field, emitted a NOTE, abandoned the construct
            // — and the compile SUCCEEDED with the store dropped. For a
            // DWARF-imported C struct that's lethal: renaming a field in a C
            // header turns every write to the old name into a silently-lost
            // store instead of a build failure.
            NSMutableArray<NSString*>* names = [NSMutableArray array];
            for (XTStructField* f in st.fields)
                [names addObject:f.fieldName];
            NSString* known = names.count
                                  ? [NSString stringWithFormat:@" (has: %@)",
                                                               [names componentsJoinedByString:@", "]]
                                  : @"";
            [self.diagnostics emitError:[NSString stringWithFormat:
                                                      @"struct '%@' has no field '%@'%@",
                                                      st.structName ?: st.displayName, node.memberName, known]
                                     at:node.location];
            }
        node.resolvedType = field ? field.fieldType : [XTType u8Type];
        return;
        }
    if (baseType && baseType.kind == XTTypeKindClass)
        {
        XTClassDeclNode* cls = self.classesByName[baseType.displayName];
        // Property-accessor rewrite: on a read (not an LHS of an
        // assignment), a zero-arg method whose name matches the
        // member name wins over a same-named ivar. The rewrite
        // stamps `resolvedGetterMethod` so codegen emits a method
        // call; `resolvedType` is set to the getter's return type
        // rather than the ivar's type. Static and varargs methods
        // don't qualify.
        if (!self.memberAccessAsLValue && cls)
            {
            NSString* ownerCls = nil;
            XTMethodDeclNode* getter =
                [self zeroArgMethodNamed:node.memberName
                                 inClass:cls
                           ownerClassOut:&ownerCls];
            if (getter)
                {
                node.resolvedGetterMethod = getter;
                node.resolvedGetterClass = ownerCls;
                node.resolvedType = getter.returnTypes.firstObject
                                        ?: [XTType voidType];
                return;
                }
            }
        // PR2: inherited ivars are reachable through a pointer/instance
        // of the subclass. Walk the parent chain after failing the leaf
        // lookup so `dog.legs` (Animal ivar) resolves when `dog` is
        // typed Dog@.
        for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
            {
            for (XTVariableDeclNode* ivar in c.ivars)
                {
                if ([ivar.varName isEqualToString:node.memberName])
                    {
                    node.resolvedType = ivar.declaredType ?: [XTType u8Type];
                    return;
                    }
                }
            }
        // Same hazard as the struct case above: an ivar that doesn't exist used
        // to resolve silently to u8, lowering emitted a NOTE, and the compile
        // SUCCEEDED with the store dropped. Only diagnosed when we actually
        // resolved the class — an unresolved base has its own diagnostic.
        if (cls)
            {
            // A PROPERTY is not a typo. On the LHS (`b.full = 7`) the
            // getter rewrite above is skipped, so a property backed by
            // `full()` / `setFull(v)` reaches here with no matching ivar —
            // the assignment lowers it through the setter. Accept the member
            // if any method in the chain answers to the name, or to its
            // derived setter name.
            NSString* setterName = [self propertySetterNameFor:node.memberName];
            for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
                {
                for (XTMethodDeclNode* m in c.methods)
                    {
                    if ([m.methodName isEqualToString:node.memberName] || [m.methodName isEqualToString:setterName])
                        {
                        node.resolvedType = [XTType u8Type];
                        return;
                        }
                    }
                }
            NSMutableArray<NSString*>* names = [NSMutableArray array];
            for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
                for (XTVariableDeclNode* ivar in c.ivars)
                    [names addObject:ivar.varName];
            NSString* known = names.count
                                  ? [NSString stringWithFormat:@" (has: %@)",
                                                               [names componentsJoinedByString:@", "]]
                                  : @"";
            [self.diagnostics emitError:[NSString stringWithFormat:
                                                      @"class '%@' has no ivar '%@'%@",
                                                      cls.className, node.memberName, known]
                                     at:node.location];
            }
        }
    node.resolvedType = [XTType u8Type];
    }

/****************************************************************************\
|* Visit a ternary expression: analyse all three branches and widen the
|* result type from then/else arms.
|* @param node  The ternary expression node.
\****************************************************************************/
- (void)visitTernaryExpr:(XTTernaryExprNode*)node
    {
    [self analyzeNode:node.condition];
    [self analyzeNode:node.thenExpr];
    [self analyzeNode:node.elseExpr];
    // Both arms are values this expression yields, so a boxed element read in
    // either one has to become the element type before the arms are widened
    // together — otherwise the ternary types itself as a pointer (bug 046).
    [node replaceThenExpr:[self unboxCollectionElement:node.thenExpr]];
    [node replaceElseExpr:[self unboxCollectionElement:node.elseExpr]];
    XTType* t1 = node.thenExpr.resolvedType;
    XTType* t2 = node.elseExpr.resolvedType;
    node.resolvedType = (t1 && t2) ? [XTType widenType:t1 with:t2] : t1 ?
                                                                 : t2   ?
                                                                        : [XTType u8Type];
    }

/****************************************************************************\
|* Visit an identifier: look up the symbol in scope and set the resolved type.
|* Emits "Undefined identifier" if the name is not found and is not a type.
|* @param node  The identifier node.
\****************************************************************************/
- (void)visitIdentifier:(XTIdentifierNode*)node
    {
    XTSymbol* sym = [[self currentScope] lookupSymbol:node.identName];
    if (sym)
        {
        node.resolvedType = sym.symbolType;
        }
    else if ([node.identName isEqualToString:@"self"] && self.currentClassNode && self.currentMethod && !self.currentMethod.isStatic)
        {
        // `self` — the receiver pointer of the enclosing instance method,
        // typed as a pointer to the current class. Lets a method read its
        // own pointer portably (e.g. `self == other`, fold(self)) instead
        // of the inline-6502-asm `__self` workaround, which is a no-op on
        // arm64. (Static methods have no receiver; scope lookup wins if a
        // user happens to bind a `self` symbol.)
        XTType* clsType = [self.typeTable typeForName:self.currentClassNode.className];
        node.resolvedType = clsType ? [XTPointerType pointerToType:clsType]
                                    : [XTType pointerType];
        }
    else if ([self.typeTable isTypeName:node.identName])
        {
        // Class name used as a receiver for static method calls — not an error
        node.resolvedType = [self.typeTable typeForName:node.identName] ?: [XTType u8Type];
        }
    else
        {
        [self.diagnostics emitError:[NSString stringWithFormat:@"Undefined identifier '%@'", node.identName]
                                 at:node.location];
        node.resolvedType = [XTType u8Type];
        }
    }

/****************************************************************************\
|* Visit an integer literal: resolve to the narrowest fitting type.
|* @param node  The integer literal node.
\****************************************************************************/
- (void)visitLiteralInt:(XTLiteralIntNode*)node
    {
    int64_t v = node.intValue;
    if (v >= 0)
        {
        if (v <= 255)
            node.resolvedType = [XTType u8Type];
        else if (v <= 65535)
            node.resolvedType = [XTType u16Type];
        else if (v <= 0xFFFFFFFFLL)
            node.resolvedType = [XTType u32Type];
        // A literal too wide for 32 bits types as 64-bit rather than silently
        // wrapping. The lexer already carries the full int64_t; before this it
        // was labelled u32 and `(u64)1000000000000` came out as its low half.
        else
            node.resolvedType = [XTType u64Type];
        }
    else
        {
        if (v >= -128)
            node.resolvedType = [XTType i8Type];
        else if (v >= -32768)
            node.resolvedType = [XTType i16Type];
        else if (v >= -2147483648LL)
            node.resolvedType = [XTType i32Type];
        else
            node.resolvedType = [XTType i64Type];
        }
    }

/****************************************************************************\
|* Visit a float/double literal: resolve type from the encoded payload
|* length (5 bytes = float, 8 bytes = double).
|* @param node  The float literal node.
\****************************************************************************/
- (void)visitLiteralFloat:(XTLiteralFloatNode*)node
    {
    node.resolvedType = node.floatData.length == 8
                            ? [XTType doubleType]
                            : [XTType floatType];
    }

/****************************************************************************\
|* Visit a string literal: resolve type to u8@ (pointer to u8).
|* @param node  The string literal node.
\****************************************************************************/
- (void)visitLiteralString:(XTLiteralStringNode*)node
    {
    node.resolvedType = [XTPointerType pointerToType:[XTType u8Type]];
    }

/****************************************************************************\
|* Visit a char literal: resolve type to u8.
|* @param node  The char literal node.
\****************************************************************************/
- (void)visitLiteralChar:(XTLiteralCharNode*)node
    {
    node.resolvedType = [XTType u8Type];
    }

/****************************************************************************\
|* Visit a bool literal: resolve type to bool.
|* @param node  The bool literal node.
\****************************************************************************/
- (void)visitLiteralBool:(XTLiteralBoolNode*)node
    {
    node.resolvedType = [XTType boolType];
    }

/****************************************************************************\
|* Visit a new expression: analyse arguments, resolve the class type to a
|* pointer-to-class type for the heap allocation.
|* @param node  The new expression node.
\****************************************************************************/
- (void)visitNewExpr:(XTNewExprNode*)node
    {
    for (XTASTNode* arg in node.arguments)
        [self analyzeNode:arg];
    if (node.countExpr)
        [self analyzeNode:node.countExpr];

    // Resolve the element type. Accepts keyword types (u8, u16, …,
    // float, bool, pointer) and user-defined names (class / struct).
    XTType* elemType = [self.typeTable typeForName:node.className];
    if (!elemType)
        {
        [self.diagnostics emitError:
                              [NSString stringWithFormat:@"`new` on unknown type '%@'", node.className]
                                 at:node.location];
        node.resolvedType = [XTType pointerType];
        return;
        }

    // Args are only legal when the element type is a class (the
    // args become the init() parameters). For primitives, structs,
    // or array allocations, reject them.
    if (node.arguments.count > 0 && elemType.kind != XTTypeKindClass)
        {
        [self.diagnostics emitError:
                              [NSString stringWithFormat:
                                            @"`new %@(…)` arguments only valid for class types",
                                            node.className]
                                 at:node.location];
        }
    if (node.arguments.count > 0 && node.countExpr != nil)
        {
        [self.diagnostics emitError:
                              @"`new T[N](…)` is not supported — array elements are zero-filled"
                                 at:node.location];
        }

    // Pointer type for the result. On banked-heap targets the
    // allocator hands out 2-byte heap pointers — the bank is
    // implicit (always `heap_bank_first`), so the codegen can
    // bracket loads/stores without the pointer carrying a runtime
    // bank byte. The old 3-byte XTPointerPlacementBanked form is
    // still available for explicit `banked:T@` in user code that
    // needs to address multiple user data banks. Flat-heap
    // targets stay on plain 2-byte main pointers. `new u8[10]`
    // is still a u8@; the array-ness is carried by delete only
    // via the heap block header (size), not in the static type.
    XTPointerPlacement placement = (self.heapBank != 0)
                                       ? XTPointerPlacementHeap
                                       : XTPointerPlacementMain;
    node.resolvedType = [XTPointerType pointerToType:elemType
                                           placement:placement];

    // Tag the class as heap-allocated. On banked-heap targets the
    // codegen uses this to default the class's methods to :main
    // placement (so (self),Y inside a body reaches the heap bank
    // instead of the method's own bank). A user can override per
    // method with an explicit :banked / :shadow annotation.
    if (elemType.kind == XTTypeKindClass)
        {
        XTClassDeclNode* cls = self.classesByName[node.className];
        // PR4: propagate usedByNew up the parent chain. On banked-heap
        // targets the codegen flips a usedByNew class's methods to
        // :main placement so (self),Y inside the body reaches the heap
        // bank instead of the method's own bank. When a subclass
        // `new Dog()` lives on the heap, a `Animal@` handle pointing
        // at it dispatches into Animal's methods too — those methods
        // need the same :main promotion or they read garbage through
        // the banked self pointer.
        for (XTClassDeclNode* c = cls; c != nil; c = c.parentClass)
            {
            c.usedByNew = YES;
            }
        // Resolve which init() overload `new ClassName(args)` should
        // call. Pre-fix the codegen picked the first init by arity,
        // skipping the conversionRank scoring used at every other
        // call site — so e.g. `new Gfx8(buf)` (buf is u8@) silently
        // routed to init(u8 n) when init(u8) was declared first,
        // truncating the pointer to a small int. Now we run the
        // standard scoreCandidateParamTypes against every init that
        // matches the call's arity and stamp the winner's mangled
        // name on the node for emitNewExpr to use.
        if (cls && node.countExpr == nil)
            {
            NSMutableArray<XTMethodDeclNode*>* candidates =
                [NSMutableArray array];
            for (XTMethodDeclNode* m in cls.methods)
                {
                if (![m.methodName isEqualToString:@"init"])
                    continue;
                if (m.parameters.count != node.arguments.count)
                    continue;
                [candidates addObject:m];
                }
            if (candidates.count > 0)
                {
                XTMethodDeclNode* chosen = nil;
                NSInteger bestScore = NSIntegerMax;
                BOOL tied = NO;
                for (XTMethodDeclNode* m in candidates)
                    {
                    NSMutableArray<XTType*>* pt = [NSMutableArray array];
                    for (XTParamNode* p in m.parameters)
                        {
                        [pt addObject:p.paramType];
                        }
                    NSInteger sc =
                        [self scoreCandidateParamTypes:pt
                                             isVarArgs:m.isVarArgs
                                             arguments:node.arguments];
                    if (sc < bestScore)
                        {
                        chosen = m;
                        bestScore = sc;
                        tied = NO;
                        }
                    else if (sc == bestScore && sc != NSIntegerMax)
                        {
                        tied = YES;
                        }
                    }
                if (chosen && bestScore != NSIntegerMax)
                    {
                    if (tied)
                        {
                        [self.diagnostics emitError:[NSString stringWithFormat:
                                                                  @"Ambiguous `new %@(...)` call — multiple init "
                                                                  @"overloads match",
                                                                  node.className]
                                                 at:node.location];
                        }
                    node.resolvedInitMangledName = chosen.mangledName;
                    NSString* initLabel = [NSString stringWithFormat:
                                                        @"_cls_%@_%@", node.className, chosen.mangledName];
                    [self recordCallEdgeToLabel:initLabel];
                    }
                }
            }
        }
    // Zero-arg `new T()` — record the call edge to the bare
    // `_cls_T_init` label the codegen will JSR. Without this the
    // init never enters the call graph, so static-frame
    // eligibility analysis ignores it and auto-cloak inference
    // can't promote it. On canonical xe (stack-in-bank-0) that
    // matters: `:main` inits' frame save runs with PORTB pointing
    // at the alloc bank (the new-expr emit pre-switches PORTB so
    // ivar writes reach the heap), and `STA ($82),Y` corrupts the
    // freshly-allocated block instead of pushing to the bank-0
    // stack. Promoting init to `:cloaked` sidesteps the conflict
    // — cloaked bodies use static-frame slots and bracket each
    // ivar access with PORTB save/switch/restore.
    if (elemType.kind == XTTypeKindClass && node.arguments.count == 0 && node.countExpr == nil)
        {
        XTClassDeclNode* cls2 = self.classesByName[node.className];
        if (cls2)
            {
            for (XTMethodDeclNode* m in cls2.methods)
                {
                if ([m.methodName isEqualToString:@"init"] &&
                    m.parameters.count == 0)
                    {
                    NSString* initLabel = m.mangledName
                                              ? [NSString stringWithFormat:@"_cls_%@_%@",
                                                                           node.className, m.mangledName]
                                              : [NSString stringWithFormat:@"_cls_%@_init",
                                                                           node.className];
                    [self recordCallEdgeToLabel:initLabel];
                    break;
                    }
                }
            }
        }
    }

/****************************************************************************\
|* Visit a sizeof expression: analyse the operand and resolve to u16 (the
|* result type of sizeof on a 6502 target).
|* @param node  The sizeof expression node.
\****************************************************************************/
- (void)visitSizeofExpr:(XTSizeofExprNode*)node
    {
    if ([node.operand isKindOfClass:[XTASTNode class]])
        {
        [self analyzeNode:(XTASTNode*)node.operand];
        }
    node.resolvedType = [XTType u16Type];
    }

/****************************************************************************\
|* Visit a cast expression. Push the cast's target type as the expected
|* type before visiting the operand so overloaded calls inside the
|* cast pick the overload matching the cast. Without this,
|* `(double)Math.PI()` fell through to the default (float) overload
|* and then fpToDp-widened the float-precision PI — printing with
|* float's 7 digits of precision instead of double's 10+.
\****************************************************************************/
- (void)visitCastExpr:(XTCastExprNode*)node
    {
    XTType* prev = self.expectedType;
    self.expectedType = node.castType;
    [self analyzeNode:(XTASTNode*)node.operand];
    self.expectedType = prev;
    // `(u16)a.get(i)` converts the VALUE, so a boxed element read unboxes
    // first. Only for a cast to a PRIMITIVE: a cast to a class pointer is how
    // the unbox rewrite itself is spelled — `((Number*)e).asI32()` — and
    // unboxing there would recurse (bug 046).
    if (node.castType && (node.castType.isInteger || node.castType.isFloating))
        {
        [node replaceOperand:[self unboxCollectionElement:node.operand]];
        }
    // Cast's resolvedType was set at construction (to castType); no
    // need to touch it.

    // Class-pointer downcast detection: a cast that takes
    // `SomeClass@` (or an ancestor) to `OtherClass@` where
    // OtherClass descends from SomeClass is a downcast and needs
    // a runtime class-id check. Stamping `targetClassName` on the
    // node is what tells codegen to emit the walk. `isFailable`
    // (set by the parser when the user wrote `(T@ ?)`) picks the
    // null-on-fail variant over the trap-on-fail default.
    XTType* operandT = node.operand.resolvedType;
    XTType* targetT = node.castType;
    XTType* opPointee = nil;
    XTType* tgPointee = nil;
    if ([operandT isKindOfClass:[XTPointerType class]])
        {
        opPointee = ((XTPointerType*)operandT).pointeeType;
        }
    if ([targetT isKindOfClass:[XTPointerType class]])
        {
        tgPointee = ((XTPointerType*)targetT).pointeeType;
        }
    if (node.isFailable && (!tgPointee || tgPointee.kind != XTTypeKindClass))
        {
        [self.diagnostics emitError:
                              @"'?' failable-cast modifier is only valid on class-pointer casts"
                                 at:node.location];
        return;
        }
    if (!opPointee || opPointee.kind != XTTypeKindClass ||
        !tgPointee || tgPointee.kind != XTTypeKindClass)
        {
        return; // non-class-pointer cast — nothing to check.
        }
    NSString* opName = opPointee.displayName;
    NSString* tgName = tgPointee.displayName;
    if ([opName isEqualToString:tgName])
        return; // same-class no-op.
    XTClassDeclNode* opCls = self.classesByName[opName];
    XTClassDeclNode* tgCls = self.classesByName[tgName];

    // Cast to a PROTOCOL: the class must actually declare conformance. A protocol
    // marker is class-KINDED but is not in classesByName, so this used to fall into
    // the "unresolved side — stay silent" return below, and `(P@)n` on a class that
    // never listed <P> compiled clean. Its vtable has nothing in P's slot, so the
    // dispatch read whatever was there and jumped to it — a DATA-ABORT, at runtime,
    // far from the cast. Having a method of the right NAME is not conformance.
    if (tgPointee.protocolConstraint.length)
        {
        NSString* proto = tgPointee.protocolConstraint;
        BOOL conforms = NO;
        for (XTClassDeclNode* c = opCls; c != nil && !conforms; c = c.parentClass)
            for (NSString* pn in c.protocolNames)
                if ([pn isEqualToString:proto])
                    {
                    conforms = YES;
                    break;
                    }
        if (conforms)
            return; // statically proven → a plain upcast, no runtime check.
        // The object's DYNAMIC class may still conform (a descendant of opCls, or
        // opCls itself when it is the universal `Object`). On a backend that carries
        // the conformance itable, stamp the protocol for a runtime downcast — `(P@ ?)`
        // yields null on a miss, plain `(P@)` traps (#9). Where there is no runtime
        // marker (xt6502/m68k) it stays a hard error, and the class must declare it.
        if (self.itableProtocols || self.vtableConforms)
            {
            node.targetProtocolName = proto;
            }
        else
            {
            [self.diagnostics emitError:[NSString stringWithFormat:
                                                      @"Class '%@' does not conform to protocol '%@' — declare it as "
                                                      @"`class %@ <%@>`",
                                                      opName, proto, opName, proto]
                                     at:node.location];
            }
        return;
        }
    if (!tgCls || !opCls)
        return; // unresolved side — stay silent.
    // Upcast (target is ancestor of operand) always succeeds; no
    // runtime check needed and `?` is a redundant modifier we
    // silently accept.
    if ([self class:opCls inheritsFromOrEquals:tgCls])
        return;
    // Downcast (target is descendant of operand): stamp so codegen
    // emits the class-id walk.
    if ([self class:tgCls inheritsFromOrEquals:opCls])
        {
        node.targetClassName = tgName;
        return;
        }
    // Unrelated class trees — can never succeed at runtime. The
    // failable form is still rejected because a null result would
    // mean "always null", which the user probably doesn't intend.
    [self.diagnostics emitError:[NSString stringWithFormat:
                                              @"'%@' and '%@' are unrelated classes — the cast can never succeed",
                                              opName, tgName]
                             at:node.location];
    }

@end
