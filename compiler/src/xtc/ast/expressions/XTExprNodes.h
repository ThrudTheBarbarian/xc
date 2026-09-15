#import "XTASTNode.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, XTBinaryOp) {
    XTBinaryOpAdd,    // +
    XTBinaryOpSub,    // -
    XTBinaryOpMul,    // *
    XTBinaryOpDiv,    // /
    XTBinaryOpMod,    // %
    XTBinaryOpBitAnd, // &
    XTBinaryOpBitOr,  // |
    XTBinaryOpBitXor, // ^
    XTBinaryOpShl,    // <<
    XTBinaryOpShr,    // >>
    XTBinaryOpRol,    // <:
    XTBinaryOpRor,    // :>
    XTBinaryOpLogAnd, // &&
    XTBinaryOpLogOr,  // ||
    XTBinaryOpEq,     // ==
    XTBinaryOpNeq,    // !=
    XTBinaryOpLt,     // <
    XTBinaryOpGt,     // >
    XTBinaryOpLe,     // <=
    XTBinaryOpGe,     // >=
};

typedef NS_ENUM(NSInteger, XTUnaryOp) {
    XTUnaryOpNeg,    // -  (negate)
    XTUnaryOpBitNot, // ~
    XTUnaryOpLogNot, // !
    XTUnaryOpAddrOf, // &
    XTUnaryOpDeref,  // @
    XTUnaryOpPreInc, // ++ (prefix)
    XTUnaryOpPreDec, // -- (prefix)
    XTUnaryOpLoByte, // <  (asm byte extraction)
    XTUnaryOpHiByte, // >
    XTUnaryOpByte2,  // >>
    XTUnaryOpByte3,  // >>>
};

typedef NS_ENUM(NSInteger, XTPostfixOp) {
    XTPostfixOpInc, // ++
    XTPostfixOpDec, // --
};

typedef NS_ENUM(NSInteger, XTAssignOp) {
    XTAssignOpAssign, // =
    XTAssignOpAdd,    // +=
    XTAssignOpSub,    // -=
    XTAssignOpMul,    // *=
    XTAssignOpDiv,    // /=
    XTAssignOpMod,    // %=
    XTAssignOpBitAnd, // &=
    XTAssignOpBitOr,  // |=
    XTAssignOpBitXor, // ^=
    XTAssignOpShl,    // <<=
    XTAssignOpShr,    // >>=
    XTAssignOpRol,    // <:=
    XTAssignOpRor,    // :>=
};

// ─────────────────────────────────────────────────────────────────────────────
@interface XTBinaryExprNode : XTASTNode
@property(nonatomic, readonly) XTBinaryOp op;
@property(nonatomic, readonly) XTASTNode* left;
@property(nonatomic, readonly) XTASTNode* right;
/****************************************************************************\
|* Used by sema's unbox rewrite. An operand that reads a primitive element out
|* of a typed collection comes back as the BOX, so it has to be replaced with
|* the `((Number@)e).asI32()` accessor call before the operator types itself —
|* otherwise `a.get(i) == 70` compares a pointer and quietly answers false.
\****************************************************************************/
- (void)replaceLeft:(XTASTNode*)left;
- (void)replaceRight:(XTASTNode*)right;
/****************************************************************************\
|* Create a binary expression node (e.g. a + b, x == y).
|* @param op        The binary operator.
|* @param left      The left-hand operand expression.
|* @param right     The right-hand operand expression.
|* @param location  Source location of the operator token.
|* @return A new binary expression node.
\****************************************************************************/
- (instancetype)initWithOp:(XTBinaryOp)op left:(XTASTNode*)left right:(XTASTNode*)right location:(XTSourceLocation*)location;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface XTUnaryExprNode : XTASTNode
@property(nonatomic, readonly) XTUnaryOp op;
@property(nonatomic, readonly) XTASTNode* operand;
/****************************************************************************\
|* Create a unary (prefix) expression node (e.g. -x, !flag, &var).
|* @param op        The unary operator.
|* @param operand   The operand expression.
|* @param location  Source location of the operator token.
|* @return A new unary expression node.
\****************************************************************************/
- (instancetype)initWithOp:(XTUnaryOp)op operand:(XTASTNode*)operand location:(XTSourceLocation*)location;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface XTPostfixExprNode : XTASTNode
@property(nonatomic, readonly) XTPostfixOp postfixOp;
@property(nonatomic, readonly) XTASTNode* operand;
/****************************************************************************\
|* Create a postfix expression node (i++ or i--).
|* @param op        The postfix operator (increment or decrement).
|* @param operand   The operand expression.
|* @param location  Source location of the operator token.
|* @return A new postfix expression node.
\****************************************************************************/
- (instancetype)initWithOp:(XTPostfixOp)op operand:(XTASTNode*)operand location:(XTSourceLocation*)location;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface XTAssignExprNode : XTASTNode
@property(nonatomic, readonly) XTAssignOp assignOp;
@property(nonatomic, readonly) XTASTNode* lhs;
@property(nonatomic, readonly) XTASTNode* rhs;
/****************************************************************************\
|* Property-setter rewrite. When the LHS is a class-member access and
|* the class (or an ancestor) declares a one-arg `set<Name>` method
|* whose parameter accepts the RHS type, sema stamps the resolved
|* setter here so codegen emits `receiver.set<Name>(rhs)` instead of
|* a direct ivar store. nil when the assignment targets a plain ivar,
|* a non-class LHS, or when no matching setter exists.
\****************************************************************************/
@property(nonatomic, strong, nullable) id resolvedSetterMethod;
@property(nonatomic, copy, nullable) NSString* resolvedSetterName;
@property(nonatomic, copy, nullable) NSString* resolvedSetterClass;
/****************************************************************************\
|* Create an assignment expression node (=, +=, -=, etc.).
|* @param op        The assignment operator variant.
|* @param lhs       The left-hand side (target) expression.
|* @param rhs       The right-hand side (value) expression.
|* @param location  Source location of the operator token.
|* @return A new assignment expression node.
\****************************************************************************/
- (instancetype)initWithOp:(XTAssignOp)op lhs:(XTASTNode*)lhs rhs:(XTASTNode*)rhs location:(XTSourceLocation*)location;
/****************************************************************************\
|* Used by sema to desugar `x.prop OP= v` into `x.prop = (x.prop OP v)`
|* when the LHS resolves to a class-member with a setter. Collapses
|* the assignOp back to `=` and swaps in the synthesised RHS; kept as
|* an explicit method so the readonly property declarations stay
|* honest for every other caller.
\****************************************************************************/
- (void)collapseToPlainAssignWithRhs:(XTASTNode*)rhs;
/****************************************************************************\
|* Used by sema's unbox rewrite to replace the RHS with an
|* `((Number@)expr).asI32()`-style accessor call when the LHS type
|* is a primitive numeric and the RHS is a class pointer. Leaves the
|* operator alone (unlike `collapseToPlainAssignWithRhs:`).
\****************************************************************************/
- (void)replaceRhs:(XTASTNode*)rhs;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface XTCallExprNode : XTASTNode
/****************************************************************************\
|* A literal `...` was written as the last ARGUMENT: `printf(fmt, ...)`, the
|* forwarding form. A FLAG rather than a node in the argument list, because it
|* names no value and because the AST must stay identical to the same call
|* without it — on every target but arm9 the arguments were packed by the
|* original caller and never left that buffer, so forwarding is the ABSENCE of
|* a repack, which is exactly what an argument list without it already emits.
|* private:docs/bugs/047.
\****************************************************************************/
@property(nonatomic) BOOL forwardsVarargs;

@property(nonatomic, readonly) NSString* calleeName;
@property(nonatomic) NSArray<XTASTNode*>* arguments;
@property(nonatomic) BOOL forceInline;
/****************************************************************************\
|* Sema stamps the resolved-overload label here. Codegen prefers
|* this over `calleeName` for the JSR label, falling back to
|* `calleeName` when nil (non-overloaded calls).
\****************************************************************************/
@property(nonatomic, copy, nullable) NSString* resolvedMangledName;
/****************************************************************************\
|* Pointee type captured by the parser when the call is the
|* `va_arg(ap, T@)` sugar and T is a user-defined struct. Used by
|* sema to stamp the resolved return type as `T@` (typed pointer)
|* instead of the generic `u8@` that `va_arg_ptr` would yield, and
|* by codegen to size the cursor advance correctly — the packed
|* argument is the struct's raw bytes at full struct width, not a
|* 2-byte pointer. nil for every other call form.
\****************************************************************************/
@property(nonatomic, nullable) XTType* vaArgStructType;
/****************************************************************************\
|* YES when sema resolved this call as an indirect call through a
|* pointer-to-function variable (calleeName names a local/global
|* whose type is `FuncType@`, not a function symbol). Codegen uses
|* this to emit a trampoline-based indirect JSR instead of the
|* direct `JSR _fn_<mangled>`. The pointee's signature is still
|* available on the node for arg-type checking via the variable's
|* resolved type.
\****************************************************************************/
@property(nonatomic) BOOL isIndirectCall;
/****************************************************************************\
|* Call through a bound method (`^`). Implies isIndirectCall, but tells
|* lowering to dispatch through the fat pointer's `code` word with its `recv`
|* word prepended as the implicit self — a plain function-pointer call has no
|* receiver to prepend. See private:docs/Design/bound-methods.md.
\****************************************************************************/
@property(nonatomic) BOOL isBoundCall;
/****************************************************************************\
|* The callee as an EXPRESSION, for a call whose callee is not a name:
|* `tbl[0](5)`, `s.fn(6)`, `obj.cbIvar(7)`, `makeCallback()(8)`. nil for the
|* ordinary `name(args)` forms, which stay name-resolved.
|*
|* A call used to be modelled by NAME alone, so any other callee shape was
|* parsed as a call to the literal name `<indirect>` and then failed as an
|* undeclared function — a message naming something the user never wrote
|* (private:docs/bugs/074). Sema types this expression and sets isBoundCall /
|* isIndirectCall from ITS type; lowering evaluates it in place of the
|* symbol lookup. Everything downstream of "get the callee's value" is
|* shared with the by-name path.
\****************************************************************************/
@property(nonatomic, nullable) XTASTNode* calleeExpr;
/****************************************************************************\
|* A BLOCK-typed callee expression — `t[0](10)`. A block call is `.invoke`
|* dispatch, so sema rewrites it into that method call and hangs the result
|* here; lowering runs it in place of the indirect-call path. Not printed by
|* the dumper: the node stays what the user wrote.
\****************************************************************************/
@property(nonatomic, nullable) XTASTNode* indirectRewrite;
/****************************************************************************\
|* When non-nil, this bare-identifier call has been resolved through
|* a `use Klass;` directive to the named class's static method.
|* Codegen emits `_cls_<resolvedClassName>_<resolvedMangledName>` as
|* the JSR target instead of the usual `_fn_<mangled>` for free
|* functions. nil for ordinary free-function calls.
\****************************************************************************/
@property(nonatomic, copy, nullable) NSString* resolvedClassName;
/****************************************************************************\
|* Create a function call expression node.
|* @param callee    The name of the function being called.
|* @param args      Array of argument expressions.
|* @param location  Source location of the callee identifier.
|* @return A new call expression node.
\****************************************************************************/
- (instancetype)initWithCallee:(NSString*)callee arguments:(NSArray<XTASTNode*>*)args location:(XTSourceLocation*)location;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface XTMethodCallExprNode : XTASTNode
/****************************************************************************\
|* A literal `...` was written as the last ARGUMENT: `printf(fmt, ...)`, the
|* forwarding form. A FLAG rather than a node in the argument list, because it
|* names no value and because the AST must stay identical to the same call
|* without it — on every target but arm9 the arguments were packed by the
|* original caller and never left that buffer, so forwarding is the ABSENCE of
|* a repack, which is exactly what an argument list without it already emits.
|* private:docs/bugs/047.
\****************************************************************************/
@property(nonatomic) BOOL forwardsVarargs;

@property(nonatomic, readonly) XTASTNode* receiver;
@property(nonatomic, readonly) NSString* methodName;
@property(nonatomic) NSArray<XTASTNode*>* arguments;
/****************************************************************************\
|* `w.onChange(7)` / `s.fn(6)` — the "method name" is really a FIELD holding
|* something callable, so this is not a method call at all. The parser cannot
|* tell (it has no types); sema does, and rewrites the node into an ordinary
|* indirect call whose callee expression is the member access. Lowering then
|* delegates to that, so the whole dispatch is shared with `f(…)`.
|*
|* A BLOCK-typed field takes the same route to a different destination: a
|* block call is `.invoke` dispatch, so the rewrite is a method call on the
|* member rather than an indirect one. Same cause, same hook, so both are
|* fixed by one rule instead of one of them being fixed and the other
|* staying broken in a way nobody notices.
|*
|* Without it, calling a callback stored in another object's ivar reported
|* "No method 'onChange' on class 'V'" — denying the existence of a member
|* that is right there — and a struct field abandoned lowering with "method
|* call on non-class receiver". private:docs/bugs/074.
\****************************************************************************/
@property(nonatomic, nullable) XTASTNode* indirectRewrite;
/****************************************************************************\
|* Sema stamps the resolved-overload label here.
\****************************************************************************/
@property(nonatomic, copy, nullable) NSString* resolvedMangledName;
/****************************************************************************\
|* The return type the CALLEE actually has, when it differs from this node's
|* resolvedType. Set only for a typed collection: `Array<String>*.get()` is
|* declared to return `Object*` and does, but the call site reads it as
|* `String*`.
|*
|* Lowering must type the Call by THIS and then Bitcast to resolvedType, which
|* is exactly the shape an explicit `(String*)a.get(i)` produces. Typing the
|* Call itself by the substituted type instead makes the IR claim the callee
|* returns something it does not — harmless until the inliner pastes the body
|* in at -O2 and the two aggregate layouts disagree.
|*
|* nil on every ordinary call.
\****************************************************************************/
@property(nonatomic, strong, nullable) XTType* erasedReturnType;
/****************************************************************************\
|* Name of the class that actually owns the resolved method — may be
|* an ancestor of the receiver's static type when the method is
|* inherited. Codegen uses this to build the `_cls_<owner>_<mangled>`
|* JSR label so `dog.speak()` with speak declared on Animal emits
|* `_cls_Animal_speak` even though the receiver is typed Dog@.
|* nil until sema's method-resolution pass assigns it; downstream
|* codegen falls back to the receiver's class name for pre-PR3
|* behaviour.
\****************************************************************************/
@property(nonatomic, copy, nullable) NSString* resolvedClassName;
/****************************************************************************\
|* PR9: set by sema when the call's receiver is a protocol-
|* constrained type (`Object@<Drawable>`). Carries the virtual
|* vtable slot picked for the protocol method, so codegen emits
|* `LDY #0 / LDA (zpTmp),Y / LDX #slot*2 / JSR _virtual_dispatch`
|* without needing a concrete `_cls_<X>_method` label. nil for
|* non-protocol calls (codegen falls through to the usual
|* label-based slot lookup).
\****************************************************************************/
@property(nonatomic, copy, nullable) NSNumber* resolvedVirtualSlot;
/****************************************************************************\
|* A call dispatched through a PROTOCOL, identified without a global slot.
|*
|* `resolvedProtocolName` is the protocol; `resolvedProtocolIndex` is the
|* method's position in that protocol's OWN declaration — which depends on
|* nothing but the declaration, so every module derives it identically with no
|* coordination. That is what makes two independently built libraries composable:
|* a shared slot NUMBER could never be agreed, but a within-protocol INDEX needs
|* no agreeing. See private:docs/Design/protocol-slot-collisions.md.
\****************************************************************************/
@property(nonatomic, copy, nullable) NSString* resolvedProtocolName;
@property(nonatomic, copy, nullable) NSNumber* resolvedProtocolIndex;
/****************************************************************************\
|* `inline:receiver.method(args)` at the call site. When YES, codegen
|* must paste the resolved method body in place of the JSR — see
|* emitInlineMethodCall in XTCodeGenerator+ExprCalls.m. Only valid
|* when the receiver's static type uniquely identifies the dispatch
|* target (concrete leaf class, or a base class whose subclasses
|* don't override the method); sema diagnoses otherwise.
\****************************************************************************/
@property(nonatomic) BOOL forceInline;
/****************************************************************************\
|* Create a method call expression node (receiver.method(args)).
|* @param receiver    The receiver expression (object the method is called on).
|* @param methodName  The method name being invoked.
|* @param args        Array of argument expressions.
|* @param location    Source location of the method name.
|* @return A new method call expression node.
\****************************************************************************/
- (instancetype)initWithReceiver:(XTASTNode*)receiver methodName:(NSString*)methodName arguments:(NSArray<XTASTNode*>*)args location:(XTSourceLocation*)location;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface XTSubscriptExprNode : XTASTNode
@property(nonatomic, readonly) XTASTNode* base;
@property(nonatomic, readonly) XTASTNode* index;
/****************************************************************************\
|* Create a subscript (array indexing) expression node.
|* @param base      The array or pointer expression.
|* @param index     The index expression.
|* @param location  Source location of the opening bracket.
|* @return A new subscript expression node.
\****************************************************************************/
- (instancetype)initWithBase:(XTASTNode*)base index:(XTASTNode*)index location:(XTSourceLocation*)location;
@end

// ─────────────────────────────────────────────────────────────────────────────
/****************************************************************************\
|* Slice expression — `arr[m..n]` / `arr[..n]` / `arr[m..]` /
|* `arr[m...n]`. Represents a half-open or closed range over an array
|* or pointer base. `startExpr` nil means "from the beginning"
|* (effectively 0); `endExpr` nil means "to the end" (the base's
|* `.length`). `inclusive` is YES for `...`, NO for `..`.
|*
|* Today only valid as the iterable of a `for-in` loop; sema rejects
|* the node anywhere else. Codegen lowers it to a counted loop with
|* slice-aware bounds, reusing the for-in fixed-array / heap-pointer
|* element-load paths.
\****************************************************************************/
@interface XTSliceExprNode : XTASTNode
@property(nonatomic, readonly) XTASTNode* base;
@property(nonatomic, readonly, nullable) XTASTNode* startExpr;
@property(nonatomic, readonly, nullable) XTASTNode* endExpr;
@property(nonatomic, readonly) BOOL inclusive;

- (instancetype)initWithBase:(XTASTNode*)base
                   startExpr:(nullable XTASTNode*)startExpr
                     endExpr:(nullable XTASTNode*)endExpr
                   inclusive:(BOOL)inclusive
                    location:(XTSourceLocation*)location;
@end

// ─────────────────────────────────────────────────────────────────────────────
/****************************************************************************\
|* Range expression — `start..end` / `start...end`. Distinct from
|* `XTSliceExprNode` (which carries an array base): a range is a
|* pure value form, used today as the initialiser of a fixed-size
|* array (`u8 buf[10] = 0..10`). Both bounds are required — open
|* forms only make sense bound to an array, and that's what slices
|* are for.
|*
|* Sema requires the range to appear as an array initialiser; codegen
|* emits a fill loop that writes start, start+1, …, end-1 (or
|* end-inclusive) into successive elements. A future PR may lift
|* this gate to allow first-class range values once a `Range` type
|* with a defined ABI is settled.
\****************************************************************************/
@interface XTRangeExprNode : XTASTNode
@property(nonatomic, readonly) XTASTNode* startExpr;
@property(nonatomic, readonly) XTASTNode* endExpr;
@property(nonatomic, readonly) BOOL inclusive;

- (instancetype)initWithStart:(XTASTNode*)startExpr
                          end:(XTASTNode*)endExpr
                    inclusive:(BOOL)inclusive
                     location:(XTSourceLocation*)location;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface XTMemberAccessNode : XTASTNode
@property(nonatomic, readonly) XTASTNode* base;
@property(nonatomic, readonly) NSString* memberName;
@property(nonatomic, readonly) BOOL isArrow; // YES for ->
/****************************************************************************\
|* Property-getter rewrite. When the member name resolves to a
|* zero-arg method on the base's class (or an ancestor), sema
|* stamps the resolved method decl node here and codegen emits a
|* method-call JSR in place of the usual ivar load. nil when the
|* member is a plain ivar, a struct field, or a non-class base.
\****************************************************************************/
@property(nonatomic, strong, nullable) id resolvedGetterMethod;
@property(nonatomic, copy, nullable) NSString* resolvedGetterClass;
/****************************************************************************\
|* Bound-method reference: `&obj.method`, the {recv, code} fat pointer.
|*
|* Set by sema when a member access is the operand of a unary `&` and the
|* member names a METHOD rather than an ivar. This takes precedence over the
|* property-getter rewrite above — for a zero-arg method, `obj.m` would
|* otherwise mean "call m", so `&obj.m` would be the address of the RESULT
|* rather than a reference to the method.
|*
|* resolvedBoundSlot is the vtable slot when the method has one, else nil:
|*   slot     → lowering emits VTblLoad(recv, slot), so the `^` picks up the
|*              receiver's RUNTIME override, and comes back null when the
|*              method is an unimplemented `optional` protocol method.
|*   no slot  → lowering emits AddrOf(Class$method), a direct symbol.
|* See private:docs/Design/bound-methods.md.
\****************************************************************************/
@property(nonatomic, strong, nullable) id resolvedBoundMethod;
@property(nonatomic, copy, nullable) NSString* resolvedBoundClass;
@property(nonatomic, copy, nullable) NSNumber* resolvedBoundSlot;
/// Separate-compilation §4.2: set instead of resolvedBoundSlot when the method
/// came from a category on a class in another module. The two are exclusive —
/// such a method has a chain slot and no vtable slot — and the lowering reads
/// the code word out of the receiver's category chain rather than its vtable.
@property(nonatomic, copy, nullable) NSNumber* resolvedBoundChainSlot;
@property(nonatomic, copy, nullable) NSString* resolvedBoundChainHost;
/// §4.3b: the owner-anchor symbol of the host's fallback table
/// (`<Host>$cat$<names>`), set with the two above — dispatch compares the
/// receiver's chain-table [0] against its address to decide "mine or not".
@property(nonatomic, copy, nullable) NSString* resolvedBoundChainAnchor;
/// Set when the bound method is reached through a PROTOCOL receiver
/// (`&delegate.method`): the protocol, and the method's index in that
/// protocol's own declaration. See resolvedProtocolName on the call node.
@property(nonatomic, copy, nullable) NSString* resolvedBoundProtocol;
@property(nonatomic, copy, nullable) NSNumber* resolvedBoundProtoIndex;
/****************************************************************************\
|* Create a member-access expression node (dot or arrow).
|* @param base      The struct/class expression.
|* @param member    The name of the member being accessed.
|* @param isArrow   YES for '->' (pointer dereference + access), NO for '.'.
|* @param location  Source location of the dot or arrow token.
|* @return A new member access node.
\****************************************************************************/
- (instancetype)initWithBase:(XTASTNode*)base memberName:(NSString*)member isArrow:(BOOL)isArrow location:(XTSourceLocation*)location;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface XTTernaryExprNode : XTASTNode
@property(nonatomic, readonly) XTASTNode* condition;
@property(nonatomic, readonly) XTASTNode* thenExpr;
@property(nonatomic, readonly) XTASTNode* elseExpr;
/****************************************************************************\
|* Used by sema's unbox rewrite — see -[XTBinaryExprNode replaceLeft:].
\****************************************************************************/
- (void)replaceThenExpr:(XTASTNode*)thenExpr;
- (void)replaceElseExpr:(XTASTNode*)elseExpr;
/****************************************************************************\
|* Create a ternary conditional expression node (cond ? then : else).
|* @param condition  The boolean condition expression.
|* @param thenExpr   The expression evaluated when the condition is true.
|* @param elseExpr   The expression evaluated when the condition is false.
|* @param location   Source location of the '?' token.
|* @return A new ternary expression node.
\****************************************************************************/
- (instancetype)initWithCondition:(XTASTNode*)condition thenExpr:(XTASTNode*)thenExpr elseExpr:(XTASTNode*)elseExpr location:(XTSourceLocation*)location;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface XTCastExprNode : XTASTNode
@property(nonatomic, readonly) XTType* castType;
@property(nonatomic, readonly) XTASTNode* operand;
/****************************************************************************\
|* Used by sema's unbox rewrite — see -[XTBinaryExprNode replaceLeft:].
|* `(u16)a.get(i)` casts the VALUE, so a boxed element read has to be unboxed
|* before the conversion, or the cast narrows a pointer.
\****************************************************************************/
- (void)replaceOperand:(XTASTNode*)operand;
/****************************************************************************\
|* Create a type-cast expression node. Sets resolvedType to castType immediately.
|* @param type      The target type to cast to.
|* @param operand   The expression being cast.
|* @param location  Source location of the cast.
|* @return A new cast expression node.
\****************************************************************************/
- (instancetype)initWithType:(XTType*)type operand:(XTASTNode*)operand location:(XTSourceLocation*)location;
/****************************************************************************\
|* Failable class-pointer downcast syntax: `(T@ ?) expr`. Parsed by
|* accepting a trailing `?` inside the cast parens; the parser sets
|* `isFailable = YES` on the node. Sema detects any class-pointer
|* downcast (failable or not) and stamps `targetClassName` so
|* codegen emits the runtime class-id walk:
|*   - plain `(T@) expr` → trap (BRK) on mismatch.
|*   - `(T@ ?) expr`     → null pointer on mismatch.
|* Upcasts and same-class casts are compile-time no-ops; unrelated
|* class-pointer pairs are rejected at sema. Non-class-pointer
|* casts are unaffected — existing `(u8@) p` / `(u16) x` traffic
|* still runs as pure reinterpretation.
\****************************************************************************/
@property(nonatomic) BOOL isFailable;
@property(nonatomic, copy, nullable) NSString* targetClassName;
// Runtime protocol conformance downcast `(P@ ?) obj` (#9): the object's dynamic
// class may or may not conform to P. Sema stamps the protocol name when the source
// isn't statically proven to conform (and the backend supports the runtime check);
// codegen asks the object's vtable itable whether it carries P's id (null-on-miss
// failable / trap-on-miss plain).
@property(nonatomic, copy, nullable) NSString* targetProtocolName;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface XTIdentifierNode : XTASTNode
@property(nonatomic, readonly) NSString* identName;
/****************************************************************************\
|* Create an identifier reference node.
|* @param name      The identifier string.
|* @param location  Source location of the identifier.
|* @return A new identifier node.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name location:(XTSourceLocation*)location;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface XTLiteralIntNode : XTASTNode
@property(nonatomic, readonly) int64_t intValue;
/****************************************************************************\
|* Create an integer literal node.
|* @param value     The parsed 64-bit integer value.
|* @param location  Source location of the literal.
|* @return A new integer literal node.
\****************************************************************************/
- (instancetype)initWithValue:(int64_t)value location:(XTSourceLocation*)location;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface XTLiteralFloatNode : XTASTNode
/****************************************************************************\
|* 5-byte encoded form.
\****************************************************************************/
@property(nonatomic, readonly) NSData* floatData;
/****************************************************************************\
|* Create a float literal node from pre-encoded 5-byte data.
|* @param data      The 5-byte encoded float data (produced at lex time).
|* @param location  Source location of the literal.
|* @return A new float literal node.
\****************************************************************************/
- (instancetype)initWithFloatData:(NSData*)data location:(XTSourceLocation*)location;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface XTLiteralStringNode : XTASTNode
@property(nonatomic, readonly) NSString* stringValue;
/****************************************************************************\
|* Create a string literal node.
|* @param value     The string content (escape sequences already resolved).
|* @param location  Source location of the opening quote.
|* @return A new string literal node.
\****************************************************************************/
- (instancetype)initWithString:(NSString*)value location:(XTSourceLocation*)location;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface XTLiteralCharNode : XTASTNode
@property(nonatomic, readonly) uint8_t charValue;
/****************************************************************************\
|* Create a character literal node.
|* @param value     The character value as an unsigned byte.
|* @param location  Source location of the opening quote.
|* @return A new character literal node.
\****************************************************************************/
- (instancetype)initWithChar:(uint8_t)value location:(XTSourceLocation*)location;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface XTLiteralBoolNode : XTASTNode
@property(nonatomic, readonly) BOOL boolValue;
/****************************************************************************\
|* Create a boolean literal node (true or false).
|* @param value     The boolean value.
|* @param location  Source location of the literal.
|* @return A new boolean literal node.
\****************************************************************************/
- (instancetype)initWithBool:(BOOL)value location:(XTSourceLocation*)location;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface XTNewExprNode : XTASTNode
@property(nonatomic, readonly) NSString* className;
@property(nonatomic, readonly) NSArray<XTASTNode*>* arguments;
/****************************************************************************\
|* Optional array count: `new T[N]` stores N here. nil for scalar
|* allocations (the classic `new Foo()` / `new Foo` / `new u16`).
\****************************************************************************/
@property(nonatomic, readonly, nullable) XTASTNode* countExpr;
/****************************************************************************\
|* Sema-stamped mangled init label. Sema runs the same overload-
|* resolution scoring used at every call site against the class's
|* init methods that match the call's arity, then writes the
|* winner's mangled name here. emitNewExpr reads this directly
|* instead of re-picking by arity (which dropped exact-type-match
|* preference and routed e.g. `new Gfx8(u8@buf)` into init(u8) by
|* declaration order).
\****************************************************************************/
@property(nonatomic, copy, nullable) NSString* resolvedInitMangledName;
/****************************************************************************\
|* Create a 'new' heap-allocation expression node.
|* @param name      Type name to instantiate (class, struct, or keyword).
|* @param args      Constructor argument expressions (empty for non-class).
|* @param count     Array length expression, or nil for a scalar allocation.
|* @param location  Source location of the 'new' keyword.
|* @return A new 'new' expression node.
\****************************************************************************/
- (instancetype)initWithClassName:(NSString*)name
                        arguments:(NSArray<XTASTNode*>*)args
                        countExpr:(nullable XTASTNode*)count
                         location:(XTSourceLocation*)location;
// Convenience without countExpr — scalar allocation.
- (instancetype)initWithClassName:(NSString*)name arguments:(NSArray<XTASTNode*>*)args location:(XTSourceLocation*)location;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface XTSizeofExprNode : XTASTNode
/****************************************************************************\
|* Either an XTType* (for sizeof(type)) or an XTASTNode* (for sizeof(expr)).
\****************************************************************************/
@property(nonatomic, readonly) id operand;
/****************************************************************************\
|* Create a sizeof expression node.
|* @param operand   Either an XTType (for sizeof(type)) or an XTASTNode
|*                  (for sizeof(expr)).
|* @param location  Source location of the 'sizeof' keyword.
|* @return A new sizeof expression node.
\****************************************************************************/
- (instancetype)initWithOperand:(id)operand location:(XTSourceLocation*)location;
@end

NS_ASSUME_NONNULL_END
