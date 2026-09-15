/****************************************************************************\
|* XTSemanticAnalyzer+Private.h
|*
|* Shared private interface — class extension and helper imports.
\****************************************************************************/
#import "XTSemanticAnalyzer.h"
#import "XTDeclNodes.h"
#import "XTStmtNodes.h"
#import "XTExprNodes.h"
#import "XTPointerType.h"
#import "XTArrayType.h"
#import "XTStructType.h"
#import "XTEnumType.h"
#import "XTFunctionType.h"
#import "XTSymbol.h"
#import "XTFloatEncoding.h"
#import "XTLabelGenerator.h"
#import "XTRuntimeRoutineInfo.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"

@interface XTSemanticAnalyzer ()
    {
    // Explicit ivar declarations matching public-header readonly
    // properties. Declaring them here makes the ivars visible to
    // category .m files via `self->_ivar`, so categories can use the
    // concrete mutable types and call -addObject:/-setObject:forKey:
    // (the public-h NSSet/NSDictionary types are readonly and don't
    // expose mutation methods).
    NSMutableSet<NSString*>* _addressTakenFunctions;
    NSMutableSet<NSString*>* _recursiveFunctions;
    NSMutableDictionary<NSString*, NSNumber*>* _staticFrameEligible;
    NSMutableDictionary<NSString*, NSNumber*>* _maxCallDepth;
    NSMutableDictionary<NSString*, NSNumber*>* _classIdsByName;
    NSMutableDictionary<NSString*, NSNumber*>* _virtualSlotByLabel;
    // Separate-compilation §4.2. A method label that dispatches through the
    // CATEGORY CHAIN rather than a vtable slot: its chain slot, the extended
    // class whose numbering it belongs to, and how many slots each such class
    // ended up with (the size of every `<Class>$cat` table in that family).
    NSMutableDictionary<NSString*, NSNumber*>* _chainSlotByLabel;
    NSMutableDictionary<NSString*, NSString*>* _chainHostByLabel;
    NSDictionary<NSString*, NSNumber*>* _chainSlotCountByHost;
    // §4.3b: host class → the CATEGORY NAMES this compilation adds to it
    // (an anonymous method-only extension contributes `_ext`), and host →
    // the anchor symbol `<Host>$cat$<names sorted>` built from them.
    NSMutableDictionary<NSString*, NSMutableSet<NSString*>*>* _catNamesByHost;
    NSDictionary<NSString*, NSString*>* _chainAnchorByHost;
    NSMutableDictionary<NSString*, NSMutableDictionary<NSNumber*, NSString*>*>* _virtualImplByClassAndSlot;
    NSMutableSet<NSString*>* _regionCLocallyUsing;
    NSMutableSet<NSString*>* _regionCUsing;
    NSMutableDictionary<NSString*, NSNumber*>* _cloakInferredSafe;
    }
@property(nonatomic, readwrite) XTScope* globalScope;
@property(nonatomic, readwrite) NSUInteger totalVirtualSlots;

@property(nonatomic) XTTypeTable* typeTable;
@property(nonatomic) XTDiagnosticEngine* diagnostics;
@property(nonatomic) NSMutableArray<XTScope*>* scopeStack;
@property(nonatomic) NSMutableSet<NSString*>* registeredEnumNames;
@property(nonatomic, nullable) XTFunctionDeclNode* currentFunction;
@property(nonatomic, nullable) XTMethodDeclNode* currentMethod;
@property(nonatomic, nullable) XTClassDeclNode* currentClassNode;
// --migrate=<base>:<to>: hide members whose since(...) is newer than <base>
// from code that is not itself versioned past <base> and is outside the
// declaring class — so a 0.3 program compiled under 0.4 fails LOUDLY at
// every site where a name was renamed or repurposed (charAt), instead of
// silently changing meaning. nil = off.
@property(nonatomic, copy, nullable) NSString* migrateBase;
- (BOOL)memberVisibleUnderMigrate:(XTMethodDeclNode*)m
                          ofClass:(XTClassDeclNode*)owner;
/****************************************************************************\
|* Return types of whatever function-or-method body is currently
|* being analysed. visitFunctionDecl and visitMethodDecl both set
|* this on entry / clear it on exit, so visitReturn can look up the
|* expected return type without caring which kind of decl it's in.
\****************************************************************************/
@property(nonatomic, nullable) NSArray<XTType*>* currentReturnTypes;
// Mangled keys of functions declared `throws` — the effect table (E1).
@property(nonatomic, nullable) NSMutableSet<NSString*>* throwingFunctionKeys;
// Depth of enclosing `try` blocks, and whether the function being analysed is
// itself `throws`. A call to a throwing function needs one or the other.
// YES while analysing the initialiser of an ARRAY declaration — the only
// position a range expression may appear in as anything other than a `for … in`
// collection, which the parser desugars before sema ever sees it. private:docs/bugs/048.
// Per-function state for the vararg-forwarding hazard (private:docs/bugs/050): a
// forwarder relies on the caller's pack still being in the shared buffer, so a
// call that PACKS its own arguments anywhere in the same function destroys it.
// Both facts are recorded as they are seen, because either order is wrong, and
// the pair is validated the moment the second one appears.
@property(nonatomic) BOOL fnForwardsVarargs;
@property(nonatomic, copy, nullable) NSString* fnPackingCallee;
@property(nonatomic, strong, nullable) XTSourceLocation* fnPackingCallLoc;
// Classes written with a type argument somewhere in this unit — `Array<String>`
// records "Array". The covariant-return suggestion is gated on this, because it
// is where an inherited `Object*` actually causes harm; without the gate it
// fires on every `Object* copy` in the program, most of which are fine.
@property(nonatomic) NSMutableSet<NSString*>* classesUsedWithTypeArgument;
@property(nonatomic) BOOL rangeInInitialiserPosition;
@property(nonatomic) NSInteger tryDepth;
@property(nonatomic) BOOL currentFunctionThrows;
/****************************************************************************\
|* The expected return type for the expression currently being analysed,
|* derived from the enclosing context. Drives return-type-aware overload
|* resolution — when `scoreCandidateParamTypes:` leaves multiple
|* candidates tied on argument match, the resolver picks the one whose
|* return type matches this hint. nil means "no context hint" (vararg
|* position, standalone expression statement, etc.), in which case the
|* tiebreaker falls back to preferring a float-returning candidate.
|*
|* Set at context-entry points:
|*   • variable-decl initialiser → declaredType
|*   • assignment RHS → LHS type
|*   • return expression → enclosing function's return type
|*   • binary-op operands → inherited from outside the binop
|*
|* Callers MUST save the previous value before overwriting and restore
|* it on the way out — the field is thread-stack-shaped and analysis
|* is recursive.
\****************************************************************************/
@property(nonatomic, nullable) XTType* expectedType;
// Property-accessor feature: when visitAssignExpr analyses its LHS,
// it sets this flag so visitMemberAccess skips the zero-arg-method
// "getter" rewrite — the LHS is a write target, not a read, and the
// setter path kicks in instead. Saved and restored around the LHS
// analysis so nested assigns don't lose context.
@property(nonatomic) BOOL memberAccessAsLValue;
@property(nonatomic) NSMutableDictionary<NSString*, XTClassDeclNode*>* classesByName;

// Escape-analysis transient state — reset per function/method body.
@property(nonatomic, nullable) NSMutableDictionary<NSString*, NSNumber*>* escStackClassDepth; // local varName → block depth at decl
@property(nonatomic, nullable) NSMutableDictionary<NSString*, NSString*>* escAliasOf;         // pointer local → origin stack-class local
@property(nonatomic) NSInteger escBlockDepth;

// Stage-4c transitive ZP-safety analysis state.
// `_stackUsingFunctions` holds labels (`_fn_<mangled>` /
// `_cls_<Class>_<mangled>`) of every function or method whose own body
// locally touches the xtc software stack — varargs pop, new/delete/
// retain/release, struct return via retbuf, inline asm referencing the
// xtc SP, large locals that spill past the ZP budget, or a non-stackSafe
// runtime helper referenced from inline asm. Seeds Pass B's backward BFS.
// `_callEdges` is a caller-to-callees graph built at resolution time in
// visitCallExpr / visitMethodCallExpr / visitAsmBlock (for JSR targets
// that name non-stackSafe runtime helpers). `_currentFunctionLabel`
// tracks the label of whichever function or method body we're currently
// inside; both visitFunctionDecl and visitMethodDecl push/pop it.
@property(nonatomic) NSMutableSet<NSString*>* stackUsingFunctions;
// Snapshot of `_stackUsingFunctions` taken just before the transitive
// BFS runs. Preserves only the "locally" stack-using labels so Pass C's
// chain-walker can recognise a leaf (a label in this set is the place
// that actually touches the xtc stack; any label added by the BFS after
// this snapshot is an intermediate caller).
@property(nonatomic) NSMutableSet<NSString*>* locallyStackUsingFunctions;
// regionCLocallyUsing / regionCUsing — see public-h decl
// (readonly NSSet) and the {  } block above. Categories use
// self->_regionCLocallyUsing / self->_regionCUsing for
// mutation. PR1 wiring; PR2 adds packer-driven flagging.
// Short human-readable phrase describing WHY a label is locally stack
// using — attached when Pass A flags the label. Pass C's chain emitter
// reads from here to render the trailing note ("uses 'new' …", "has a
// local > 16 bytes", …). Absent key = transitively flagged only.
@property(nonatomic) NSMutableDictionary<NSString*, NSString*>* stackUseReasons;
// Pretty display name for each label (e.g. "foo" for _fn_foo, or
// "Stdio.printf" for _cls_Stdio_printf). Chain notes read this so the
// user sees source-level identifiers rather than mangled labels.
@property(nonatomic) NSMutableDictionary<NSString*, NSString*>* labelDisplayNames;
@property(nonatomic) NSMutableDictionary<NSString*, NSMutableSet<NSString*>*>* callEdges;
@property(nonatomic, nullable) NSString* currentFunctionLabel;
// List of (label, placement, name, location) tuples for every :cloaked
// decl, captured during Pass A. Pass C iterates this list to emit a
// chain error when the transitive closure put the decl's label into
// `_stackUsingFunctions`.
@property(nonatomic) NSMutableArray<NSDictionary*>* cloakedDecls;
// Variadic-reentrance analysis state. `_variadicLabels` holds every
// variadic function's call-graph label for O(1) membership tests;
// `_variadicDecls` parallels `_cloakedDecls` with {label, name,
// location} tuples for the post-analysis chain emitter. The shared
// varargs-pack buffer at $04B0 cannot hold two live va_lists at
// once — sema walks each variadic's transitive callees and flags
// any variadic→variadic edge (including self-recursion).
@property(nonatomic) NSMutableSet<NSString*>* variadicLabels;
@property(nonatomic) NSMutableArray<NSDictionary*>* variadicDecls;
// Subset of `_variadicLabels` — variadic functions whose body actually
// calls `va_start` (and therefore reads its own va_list). Pure-forwarder
// variadics like Stdio.printfAt — declared variadic so callers can pack
// through them into slot 0, but never touching va_arg_* themselves —
// are safe to call another variadic because the pack buffer they pass
// through is never read after the inner call's re-packing. The
// reentrance check only fires for variadics in this set.
@property(nonatomic) NSMutableSet<NSString*>* variadicFunctionsUsingVaList;

// Static-frame allocation analysis (13a — detection only; slot
// assignment lives in codegen).
//   `_addressTakenFunctions`  — labels whose address has been taken
//                                via `&funcName`. Can be invoked
//                                through a function pointer, so the
//                                call graph is incomplete for them.
//   `_externalFunctions`      — labels declared but not defined in
//                                this translation unit (body == nil
//                                forward decls). Frame size + call
//                                graph are unknown.
//   `_recursiveFunctions`     — labels in a call-graph cycle (direct
//                                self-loop or any SCC ≥ 2). Depth
//                                diverges; cannot use static frames.
//   `_staticFrameEligible`    — final per-function YES/NO flag. A
//                                function is eligible iff it is
//                                neither address-taken, external, nor
//                                recursive. Eligibility is a local
//                                property — a function can be eligible
//                                even if it calls an ineligible one,
//                                because the two frame-save systems
//                                (static buffer vs. xtc-stack) use
//                                disjoint physical memory.
// addressTakenFunctions, recursiveFunctions redeclared above as
// readwrite of the public-h readonly properties.
@property(nonatomic) NSMutableSet<NSString*>* externalFunctions;
// PR4 temporary override guard. Labels of class methods that a
// subclass overrides (same mangled signature). Consumed by PR8's
// virtual-dispatch emission — any method in this set ends up in
// a vtable slot; call sites that statically resolve to it emit
// the _virtual_dispatch runtime helper rather than a direct JSR.
@property(nonatomic) NSMutableSet<NSString*>* overriddenMethodLabels;
// classIdsByName, virtualSlotByLabel, virtualImplByClassAndSlot,
// totalVirtualSlots — redeclared above as readwrite of the public-h
// readonly properties.
// PR9 protocol table: name → XTProtocolDeclNode, populated at
// class-pre-scan time alongside `_classesByName`. Consumed by
// `verifyProtocolConformance` to check each class provides the
// declared methods, and by `visitMethodCallExpr` to resolve calls
// through protocol-typed receivers (a parameter of type `Proto@`).
@property(nonatomic) NSMutableDictionary<NSString*, XTProtocolDeclNode*>* protocolsByName;
// PR9: per-protocol method → global vtable slot. Shared with the
// PR8 slot pool — every protocol method gets a slot, and every
// conforming class's matching method picks up the same slot.
@property(nonatomic) NSMutableDictionary<NSString*, NSMutableDictionary<NSString*, NSNumber*>*>* protocolMethodSlots;
// staticFrameEligible redeclared above.
// Longest-acyclic-forward-path depth per label (0 = leaf). Populated
// after `detectRecursiveFunctions` so cycles don't inflate the
// counter; recursive labels are left unset rather than filled with a
// sentinel. Consumed by the manifest emitter and — eventually — a
// stack-frame-buffer budget check.
// maxCallDepth redeclared above.

// Stage-2 call-site-local CFA: per-function set of functions that
// could be reached via an indirect `fp(...)` call from inside this
// function. Populated by:
//   • direct assignments/inits `<fnptr-var> = &funcName;` inside the
//     function — funcName joins the enclosing function's target set.
//   • call arguments `f(..., &funcName, ...)` where f's matching
//     parameter is fn-pointer-typed — funcName joins f's target set
//     (inter-procedural propagation, so qsort's `cmp` parameter
//     receives the candidates from every qsort call site).
// At eligibility time, each entry becomes a virtual edge in
// _callEdges so the existing transitive analysis catches any
// recursion through indirect dispatch.
@property(nonatomic) NSMutableDictionary<NSString*, NSMutableSet<NSString*>*>* indirectCallTargets;
// Subset of `_addressTakenFunctions` whose &-of uses are all in
// CFA-tracked contexts (the three simple patterns above). Functions
// in this set get normal static-frame treatment; address-taken
// functions that WEREN'T cleanly tracked (e.g. &F stored in a
// struct field or returned from another function) stay on the
// xtc-stack fallback path — we couldn't prove who might call them.
@property(nonatomic) NSMutableSet<NSString*>* addressTakenCleanly;
// Ordered list of class names brought into bare-call scope by
// `use Klass;` directives. visitCallExpr falls back through this
// list (in source order) when ordinary free-function lookup
// misses, looking for a static method named the same as the
// callee. First match wins; if multiple use'd classes have a
// matching static, sema reports the ambiguity. Populated by
// visitUseDecl as the AST is walked, so use directives only
// affect calls textually after them.
@property(nonatomic) NSMutableArray<NSString*>* usedClassNames;
// Function names whose only free declaration is an AUTO-IMPORTED C proto
// (XTFunctionDeclNode.isCImport — the DWARF libc import). Bare-call
// resolution demotes these below a matching `use`-promoted static: libc's
// variadic printf FITS any argument list, so without the demotion it beat
// `#use Stdio`'s printf on every target that auto-imports libc (arm9
// printed host-style `aa` where the contract says `00AA`).
@property(nonatomic) NSMutableSet<NSString*>* cImportFunctionNames;
@end

// Cross-category method declarations — Obj-C accepts redundant matching
// declarations without complaint. Wrapped in #pragma to silence
// nullability-completeness on the bulk redecls.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"

@interface XTSemanticAnalyzer ()
- (instancetype)initWithTypeTable:(XTTypeTable*)typeTable
                      diagnostics:(XTDiagnosticEngine*)diagnostics;
- (nullable NSString*)addressTakenFunctionLabelFromNode:(XTASTNode*)node;
- (void)recordIndirectCallTarget:(NSString*)target
                 forFromFunction:(NSString*)fromFunction;
- (void)recordFnPointerArgs:(NSArray<XTASTNode*>*)args
                 paramTypes:(nullable NSArray<XTType*>*)paramTypes
                calleeLabel:(NSString*)calleeLabel;
- (XTScope*)currentScope;
- (void)pushScope;
- (void)popScope;
- (void)defineSymbol:(XTSymbol*)sym;
- (void)defineSymbol:(XTSymbol*)sym at:(nullable XTSourceLocation*)loc;
- (void)visitProgram:(XTProgramNode*)node;
- (void)visitFunctionDecl:(XTFunctionDeclNode*)node;
- (void)visitMethodDecl:(XTMethodDeclNode*)node;
- (void)checkCloakedDecl:(NSString*)name
               isVarArgs:(BOOL)isVarArgs
                    body:(nullable XTASTNode*)body
                location:(XTSourceLocation*)loc;
- (void)scanCloakedBody:(XTASTNode*)node funcName:(NSString*)name;
- (void)runEscapeAnalysisOnBody:(XTASTNode*)body;
- (void)runGuardCheckOnBody:(XTASTNode*)body;
- (nullable NSString*)escOriginOfExpr:(nullable XTASTNode*)expr;
- (nullable NSString*)escRootOfLvalue:(nullable XTASTNode*)expr;
- (void)escWalkStmt:(nullable XTASTNode*)node;
- (void)escWalkExpr:(nullable XTASTNode*)expr;
- (void)escClassifyAssignTarget:(XTASTNode*)lhs
                         origin:(NSString*)origin
                       location:(XTSourceLocation*)loc;
@end

#pragma clang diagnostic pop
