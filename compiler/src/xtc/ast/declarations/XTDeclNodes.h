#import "XTASTNode.h"
#import "XTType.h"
#import "XTFunctionType.h"

NS_ASSUME_NONNULL_BEGIN

/****************************************************************************\
|* XTProgramNode — root of the AST
\****************************************************************************/
@interface XTProgramNode : XTASTNode
@property(nonatomic, readonly) NSArray<XTASTNode*>* declarations;
/****************************************************************************\
|* Create the program root node with its top-level declarations.
|* @param declarations  Array of top-level declaration nodes.
|* @param location      Source location for the start of the program.
|* @return A new program node.
\****************************************************************************/
- (instancetype)initWithDeclarations:(NSArray<XTASTNode*>*)declarations
                            location:(XTSourceLocation*)location;
// Drop declarations that a pass has consumed. Used for category/extension
// nodes once sema has merged them into their class: the part is SPENT, and
// four separate passes walk this list (sema, reachability, the interface
// serialiser and IR lowering), so leaving it here means each of them has to
// know to skip it — and the one that forgets lowers the same method twice and
// dies on "append after terminator". Removing it once is the honest fix.
- (void)removeDeclarations:(NSSet<XTASTNode*>*)spent;
@end

/****************************************************************************\
|* XTParamNode — a function/method parameter
\****************************************************************************/
@interface XTParamNode : XTASTNode
@property(nonatomic, readonly) XTType* paramType;
@property(nonatomic, readonly) NSString* paramName;
/****************************************************************************\
|* Create a parameter node with an explicit type and name.
|* @param type      The declared type of the parameter.
|* @param name      The parameter name as it appears in source.
|* @param location  Source location of the parameter declaration.
|* @return A new parameter node.
\****************************************************************************/
- (instancetype)initWithType:(XTType*)type
                        name:(NSString*)name
                    location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* Stack convention for function calls
\****************************************************************************/
typedef NS_ENUM(NSInteger, XTStackConvention) {
    XTStackDefault, // use whatever the global setting says
    XTStack6502,    // force 6502 hardware stack (PHA/PLA)
    XTStackXtc,     // force xtc software stack (via SP at $82/$83 or $89/$8A)
};

/****************************************************************************\
|* XTFunctionDeclNode
\****************************************************************************/
@interface XTFunctionDeclNode : XTASTNode
@property(nonatomic, readonly) NSString* funcName;
/****************************************************************************\
|* Large-struct return lowering (done at codegen time) needs to
|* swap the return type to void and prepend a hidden __retbuf
|* parameter, so these are readwrite rather than readonly. See the
|* large-struct return pass in XTCodeGenerator.
\****************************************************************************/
@property(nonatomic) NSArray<XTType*>* returnTypes;
@property(nonatomic) NSArray<XTParamNode*>* parameters;
@property(nonatomic, readonly) BOOL isVarArgs;
/****************************************************************************\
|* YES when this function's body contains `f(a, ...)` — the vararg forwarding
|* form. Set by sema, carried into the IR as the `vaforward` symbol attribute,
|* and read by the arm9 back end, which is the one target that has to DO
|* something: its varargs travel in registers, so a forwarder must home them and
|* re-lay them out for the callee. private:docs/bugs/047.
\****************************************************************************/
@property(nonatomic) BOOL forwardsVarargs;
/****************************************************************************\
|* `extern` on a DEFINITION (§6 of wasm-target.md): external linkage — the
|* function is part of the module's public surface. On wasm32 it appears in
|* the export section and roots dead-function elimination; elsewhere it is
|* ordinary external linkage. Strictly additive: `extern` on a bodyless
|* function stays the (already-implicit) import spelling.
\****************************************************************************/
@property(nonatomic) BOOL isExported;
/****************************************************************************\
|* The host package a bodyless (imported) function binds to, set by the
|* `#package <name>` directive in force at the declaration site. nil = the
|* default package ("env" on wasm32). Wasm imports are (module, name)
|* pairs; this is the module half.
\****************************************************************************/
@property(nonatomic, copy, nullable) NSString* importPackage;
/****************************************************************************\
|* The class every `return` in this method actually yields, when they agree —
|* used to suggest a covariant return where the declared type is the inherited
|* one. `@"?"` once two returns disagree, nil when nothing was observed.
\****************************************************************************/
@property(nonatomic, copy, nullable) NSString* observedReturnClass;

/****************************************************************************\
|* Slot index into the shared varargs pack buffer at $04B0-$04EF. Always
|* 0 in the post-stage-4c collapsed pool (every variadic shares the same
|* slot; the reentrance check guarantees only one is live at a time).
|* -1 means "not assigned" (not a varargs function). Kept as an int for
|* call-site compatibility with `varargsSlotBase:`.
\****************************************************************************/
@property(nonatomic) NSInteger varargsSlot;
/****************************************************************************\
|* For overloaded functions, the parameter-type-suffixed label used
|* by codegen (e.g. `print__u32`). Defaults to `funcName`.
\****************************************************************************/
@property(nonatomic, copy) NSString* mangledName;
@property(nonatomic) XTStackConvention stackConvention;
/****************************************************************************\
|* Naked functions have no register save/restore or stack frame. For interrupt handlers.
\****************************************************************************/
@property(nonatomic) BOOL isNaked;
/****************************************************************************\
|* Declared `throws`: this function may raise an Error@, so it carries a hidden
|* trailing error out-parameter and every call site must either handle the error
|* or itself be `throws`. See private:docs/Design/exceptions-and-defer.md.
\****************************************************************************/
@property(nonatomic) BOOL throwsError;
/****************************************************************************\
|* Function calls OS ROM — on shadow targets the codegen wraps call sites
|* with a ROM-enable/disable pair.
\****************************************************************************/
@property(nonatomic) BOOL needsOS;
/****************************************************************************\
|* Hardware-interrupt handler. Like :naked (no frame save / param convention)
|* but the epilogue is RTI instead of RTS so the 6502 pops the saved flags
|* + return PC pushed by the IRQ.
\****************************************************************************/
@property(nonatomic) BOOL isIrq;
/****************************************************************************\
|* VBI handler. The prologue pushes A/X/Y so the VBI body can clobber them
|* freely; the epilogue restores them and JMPs to XITVBV ($E462) so the OS
|* finishes the interrupt — the immediate vs deferred choice happens at
|* register-time via the Vbi.xc library, not in the codegen.
\****************************************************************************/
@property(nonatomic) BOOL isVbi;
/****************************************************************************\
|* `:action` — an XG-NIB target/action method (designable surface). void
|* return + one object param (the sender); drives UIDesignable.wireAction.
\****************************************************************************/
@property(nonatomic) BOOL isAction;
/****************************************************************************\
|* A load-time constructor: its name is recorded in the module's
|* moduleInitFunctionNames so each backend emits a pointer to it in the
|* target constructor list, running it before `main`. Set on the
|* compiler-synthesised XG-NIB factory-registration function.
\****************************************************************************/
@property(nonatomic) BOOL isModuleInit;
/****************************************************************************\
|* Code placement preference, set by :banked / :shadow / :main / :cloaked
|* annotations. `default` lets the codegen pick (auto-bank free funcs on
|* xt/xe; main otherwise). The other values are user requests; the codegen
|* warns and falls through to default if the target can't honour the choice.
|* :cloaked is xe-family only — the body is emitted into the 16 KB library
|* bank at $4000-$7FFF and called with banking off (PORTB = $30).
\****************************************************************************/
typedef NS_ENUM(NSInteger, XTPlacement) {
    XTPlacementDefault = 0,
    XTPlacementBanked,  // :banked  — bank window
    XTPlacementShadow,  // :shadow  — main RAM under OS ROM
    XTPlacementMain,    // :main    — main RAM, not under ROM, not banked
    XTPlacementCloaked, // :cloaked — xe library code region(s)
};
@property(nonatomic) XTPlacement placement;
/****************************************************************************\
|* Region id for `:cloaked(<id>)` annotations. When `placement ==
|* XTPlacementCloaked` and this is non-nil, the codegen pins the decl
|* to the layout's cloaked region with the matching `id`. nil means
|* "any cloaked region" — the packer picks (first declared region
|* with room, falling through to overflow handling).
\****************************************************************************/
@property(nonatomic, copy, nullable) NSString* cloakedRegionId;
/****************************************************************************\
|* Set on a prototype synthesised from a `#import <lib>` shared-library
|* metadata import: the function follows the C / platform ABI, not xtc's
|* internal conventions. In particular a C-ABI VARIADIC callee (printf) takes
|* its args per AAPCS (registers + stack), so the lowering must NOT pack them
|* into xtc's `__xtc_va_buf` the way it does for an xtc-authored variadic.
\****************************************************************************/
@property(nonatomic) BOOL isCImport;
/****************************************************************************\
|* nil for forward declarations.
\****************************************************************************/
@property(nonatomic, readonly, nullable) XTASTNode* body;
/****************************************************************************\
|* Create a function declaration (or forward declaration if body is nil).
|* @param name         The unmangled function name.
|* @param returnTypes  Array of return types (multiple for tuple returns).
|* @param parameters   Array of XTParamNode for the function signature.
|* @param isVarArgs    YES if the function accepts variadic arguments.
|* @param body         The function body block, or nil for a forward declaration.
|* @param location     Source location of the function declaration.
|* @return A new function declaration node.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name
                 returnTypes:(NSArray<XTType*>*)returnTypes
                  parameters:(NSArray<XTParamNode*>*)parameters
                   isVarArgs:(BOOL)isVarArgs
                        body:(nullable XTASTNode*)body
                    location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTVariableDeclNode
\****************************************************************************/
@interface XTVariableDeclNode : XTASTNode
@property(nonatomic, readonly) NSString* varName;
/****************************************************************************\
|* nil when declared with 'auto'.
\****************************************************************************/
@property(nonatomic, nullable) XTType* declaredType;
/****************************************************************************\
|* nil when no initialiser.
\****************************************************************************/
@property(nonatomic, nullable) XTASTNode* initialiser;
/****************************************************************************\
|* Parameterised stack-class construction — `Myclass c(a, b);`
|* parses into a decl with constructorArgs = [a, b] and no
|* initialiser. The codegen's stack-instance branch uses these
|* args to resolve the matching init() overload and pass them
|* through. Nil for any other declaration form.
\****************************************************************************/
@property(nonatomic, nullable) NSArray<XTASTNode*>* constructorArgs;
@property(nonatomic) BOOL isGlobal; // visible across files (with static)
@property(nonatomic) BOOL isVolatile;
@property(nonatomic) BOOL isRegister; // force ZP allocation
@property(nonatomic) BOOL isStatic;   // persists across scope exits
@property(nonatomic) BOOL isOutlet;   // `outlet` qualifier — designable-surface field (XG nibs)
/****************************************************************************\
|* `extern u16 gCounter;` — the global is DEFINED IN ANOTHER MODULE. Reserve no
|* storage; emit a reference and let the linker resolve it.
|*
|* Globals are otherwise scoped to the module they are compiled in, which is why
|* an imported library's globals could not be used at all: injecting a plain decl
|* would have DEFINED A SECOND COPY in the client, whose writes never reach the
|* library's — and nothing would have said so. `extern` is the word for exactly
|* that distinction.
\****************************************************************************/
@property(nonatomic) BOOL isExternalGlobal;
/****************************************************************************\
|* `extern` on a global WITH an initialiser (§6): an exported definition —
|* this module owns the storage and publishes it. On wasm32 the global's
|* linear-memory address is exported; elsewhere ordinary external linkage.
\****************************************************************************/
@property(nonatomic) BOOL isExported;
/****************************************************************************\
|* Create a variable declaration node.
|* @param name         The variable name.
|* @param type         The declared type, or nil when declared with 'auto'.
|* @param initialiser  The initialiser expression, or nil when absent.
|* @param location     Source location of the variable declaration.
|* @return A new variable declaration node.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name
                        type:(nullable XTType*)type
                 initialiser:(nullable XTASTNode*)initialiser
                    location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTStructDeclNode
\****************************************************************************/
@interface XTStructDeclNode : XTASTNode
/****************************************************************************\
|* nil for anonymous structs.
\****************************************************************************/
@property(nonatomic, readonly, nullable) NSString* structName;
@property(nonatomic, readonly) NSArray<XTVariableDeclNode*>* fields;
// `struct Name :packed { … }` — total size is the raw field-width sum, no
// tail rounding to natural alignment. Offsets are tight either way.
@property(nonatomic) BOOL isPacked;
/****************************************************************************\
|* Create a struct declaration node.
|* @param name      The struct tag name, or nil for anonymous structs.
|* @param fields    Array of field declarations.
|* @param location  Source location of the struct keyword.
|* @return A new struct declaration node.
\****************************************************************************/
- (instancetype)initWithName:(nullable NSString*)name
                      fields:(NSArray<XTVariableDeclNode*>*)fields
                    location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTTypedefNode
\****************************************************************************/
@interface XTTypedefNode : XTASTNode
@property(nonatomic, readonly) NSString* aliasName;
@property(nonatomic, nullable) XTType* targetType;
/****************************************************************************\
|* For typedef struct { ... } Name; the struct decl is here.
\****************************************************************************/
@property(nonatomic, readonly, nullable) XTStructDeclNode* structDecl;
/****************************************************************************\
|* Create a typedef node.
|* @param alias       The new alias name being introduced.
|* @param targetType  The existing type being aliased, or nil when a struct decl follows.
|* @param structDecl  An inline struct declaration, or nil when aliasing an existing type.
|* @param location    Source location of the typedef keyword.
|* @return A new typedef declaration node.
\****************************************************************************/
- (instancetype)initWithAliasName:(NSString*)alias
                       targetType:(nullable XTType*)targetType
                       structDecl:(nullable XTStructDeclNode*)structDecl
                         location:(XTSourceLocation*)location;
@end

// ─────────────────────────────────────────────────────────────────────────────
/****************************************************************************\
|* Top-level `use Klass;` directive: promotes the named class's static
|* methods so the user can call them as bare identifiers within the
|* file scope (e.g. `printf(...)` instead of `Stdio.printf(...)` after
|* `use Stdio;`). The class must already be declared / imported by the
|* time sema visits the use directive.
\****************************************************************************/
@interface XTUseDeclNode : XTASTNode
@property(nonatomic, readonly) NSString* className;
- (instancetype)initWithClassName:(NSString*)className
                         location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTEnumMemberNode
\****************************************************************************/
@interface XTEnumMemberNode : XTASTNode
@property(nonatomic, readonly) NSString* memberName;
/****************************************************************************\
|* nil = auto-assigned during sema pass.
\****************************************************************************/
@property(nonatomic, nullable) NSNumber* explicitValue;
@property(nonatomic) int64_t resolvedValue;
/****************************************************************************\
|* Create an enum member node.
|* @param name   The member identifier.
|* @param value  The explicit integer value, or nil for auto-assignment by sema.
|* @param location  Source location of the member name.
|* @return A new enum member node.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name
               explicitValue:(nullable NSNumber*)value
                    location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTEnumDeclNode
\****************************************************************************/
@interface XTEnumDeclNode : XTASTNode
@property(nonatomic, readonly) NSString* enumName;
@property(nonatomic, readonly) NSArray<XTEnumMemberNode*>* members;
/****************************************************************************\
|* Create an enum declaration node.
|* @param name      The enum tag name.
|* @param members   Array of XTEnumMemberNode values.
|* @param location  Source location of the enum keyword.
|* @return A new enum declaration node.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name
                     members:(NSArray<XTEnumMemberNode*>*)members
                    location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTMethodDeclNode
\****************************************************************************/
@interface XTMethodDeclNode : XTASTNode
@property(nonatomic, readonly) NSString* methodName;
@property(nonatomic) NSArray<XTType*>* returnTypes;
@property(nonatomic) NSArray<XTParamNode*>* parameters;
@property(nonatomic, readonly) BOOL isStatic;
@property(nonatomic, readonly) BOOL isVarArgs;
/****************************************************************************\
|* YES when this function's body contains `f(a, ...)` — the vararg forwarding
|* form. Set by sema, carried into the IR as the `vaforward` symbol attribute,
|* and read by the arm9 back end, which is the one target that has to DO
|* something: its varargs travel in registers, so a forwarder must home them and
|* re-lay them out for the callee. private:docs/bugs/047.
\****************************************************************************/
@property(nonatomic) BOOL forwardsVarargs;
/****************************************************************************\
|* The class every `return` in this method actually yields, when they agree —
|* used to suggest a covariant return where the declared type is the inherited
|* one. `@"?"` once two returns disagree, nil when nothing was observed.
\****************************************************************************/
@property(nonatomic, copy, nullable) NSString* observedReturnClass;

/****************************************************************************\
|* `optional` on a protocol method: a conforming class may omit it, so its
|* vtable slot stays 0. Meaningless (and unset) on a class method — only
|* XTProtocolDeclNode.methods ever carry it. Two consequences in sema:
|* conformance checking skips it, and a *direct* call through a
|* protocol-typed receiver is rejected (it would jump through a zero slot);
|* callers must go through `&d.m` and test the result. See
|* private:docs/Design/bound-methods.md.
\****************************************************************************/
@property(nonatomic) BOOL isOptional;
// `since("0.4")` before the declaration: the library version that introduced
// this member. nil = present since forever. --migrate=<base>:<to> hides
// members newer than <base> from OLD code so a repurposed name (charAt, 0.4)
// fails loudly at every call site instead of silently changing meaning.
@property(nonatomic, copy, nullable) NSString* sinceVersion;
/****************************************************************************\
|* `final` — no subclass may override this method (enforced).
|*
|* Its purpose is --emit-lib: because the program isn't whole there, EVERY
|* exported instance method is made an override root and given a vtable slot
|* (task #586). `final` is the author asserting "no client overrides this", which
|* opts it back out — restoring the direct call and keeping the vtable small.
|* That second part is load-bearing on xt6502, which hard-errors above slot 84.
|*
|* Needs no codegen: a method with no slot already lowers to a direct call.
\****************************************************************************/
@property(nonatomic) BOOL isFinal;
/****************************************************************************\
|* Declared `throws` — same effect as on a free function. Must be copied from
|* the parsed signature or a `throw` in the body has no channel to store into.
\****************************************************************************/
@property(nonatomic) BOOL throwsError;
/****************************************************************************\
|* Slot index (0..4) into the varargs-pack buffer pool at $04B0-$05EF.
|* -1 means "no slot assigned". Sema's assignVarargsSlots pass writes this.
\****************************************************************************/
@property(nonatomic) NSInteger varargsSlot;
/****************************************************************************\
|* For overloaded methods, the parameter-type-suffixed label used
|* by codegen. Defaults to `methodName`.
\****************************************************************************/
@property(nonatomic, copy) NSString* mangledName;
/****************************************************************************\
|* Method calls OS ROM — on shadow targets the codegen wraps call sites.
\****************************************************************************/
@property(nonatomic) BOOL needsOS;
@property(nonatomic) BOOL isAction; // `:action` — XG-NIB designable target/action method
/****************************************************************************\
|* Separate-compilation §4.2: the class this method was added to by a
|* `class C (Cat) { … }` whose C came from ANOTHER module. nil for every
|* ordinary method, and for a category on a class compiled here (that one
|* merges into the vtable — §4.1). Such a method may not take a vtable slot:
|* the class's vtable is already emitted in a library we cannot relink, so it
|* is numbered in the category-chain slot space instead.
\****************************************************************************/
@property(nonatomic, copy, nullable) NSString* importedCategoryHost;
/****************************************************************************\
|* §4.3b: this method occupies a CATEGORY-CHAIN slot (stamped by sema when the
|* slot is assigned, and round-tripped through .xtc.iface as `chain`). A
|* client importing the class sees the flag and REFUSES to override the
|* method: the interface does not carry the chain's shape (anchor, slot
|* count), so a client-side override could only be mis-slotted.
\****************************************************************************/
@property(nonatomic) BOOL isChainMethod;
/****************************************************************************\
|* Placement annotation (:main / :banked / :shadow), same semantics as
|* on XTFunctionDeclNode. Lets a class pin individual methods into a
|* specific region regardless of the class's default placement — used
|* by e.g. Heap.xc to keep its runtime-allocator calls in main RAM on
|* banked targets so they work without an intervening bank switch.
\****************************************************************************/
@property(nonatomic) XTPlacement placement;
/****************************************************************************\
|* `:cloaked(<id>)` region pin — see XTFunctionDeclNode.cloakedRegionId.
\****************************************************************************/
@property(nonatomic, copy, nullable) NSString* cloakedRegionId;
/****************************************************************************\
|* ARC 2d: receiver-kind summary across every observed call site. Set by
|* sema's visitMethodCallExpr as it visits the AST; consumed by codegen's
|* method-emission prologue to decide whether it's safe to retain `self`
|* on entry. The retain is only safe when every receiver is a heap block
|* — retaining a stack instance or a static-data-block receiver would
|* touch bytes before the payload that aren't a refcount header. When
|* `hasNonHeapReceiver` is YES the prologue skips the self retain; when
|* NO and at least one heap call site was seen, the prologue emits the
|* retain + adds self to the scope-exit cleanup list.
\****************************************************************************/
@property(nonatomic) BOOL hasHeapReceiver;
@property(nonatomic) BOOL hasNonHeapReceiver;
/****************************************************************************\
|* PR5: set by sema when an `init` method needs a compiler-inserted
|* `super.init()` call at the top of its body. Triggered only on a
|* subclass init that (a) doesn't already call super.init explicitly
|* and (b) whose parent class declares a no-arg init. Codegen
|* consumes it in emitSingleMethodDecl by emitting the super JSR
|* before the rest of the body runs.
\****************************************************************************/
@property(nonatomic) BOOL autoSuperInit;
/****************************************************************************\
|* PR6: set by sema when a `dealloc` method needs a compiler-inserted
|* `super.dealloc()` call at the END of its body (child-first
|* teardown). Triggered on a subclass dealloc that doesn't already
|* call super.dealloc explicitly when any ancestor has a dealloc
|* method. Codegen emits the super JSR after the body runs and
|* before the ARC fallthrough cleanup, inside emitSingleMethodDecl.
\****************************************************************************/
@property(nonatomic) BOOL autoSuperDealloc;
@property(nonatomic, readonly, nullable) XTASTNode* body;
/****************************************************************************\
|* Create a method declaration node.
|* @param name         The unmangled method name.
|* @param returnTypes  Array of return types.
|* @param parameters   Array of XTParamNode for the method signature.
|* @param isStatic     YES if this is a class-level (static) method.
|* @param isVarArgs    YES if the method accepts variadic arguments.
|* @param body         The method body block, or nil for a forward declaration.
|* @param location     Source location of the method declaration.
|* @return A new method declaration node.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name
                 returnTypes:(NSArray<XTType*>*)returnTypes
                  parameters:(NSArray<XTParamNode*>*)parameters
                    isStatic:(BOOL)isStatic
                   isVarArgs:(BOOL)isVarArgs
                        body:(nullable XTASTNode*)body
                    location:(XTSourceLocation*)location;
@end

/****************************************************************************\
|* XTClassDeclNode
\****************************************************************************/
@interface XTClassDeclNode : XTASTNode
@property(nonatomic, readonly) NSString* className;
@property(nonatomic, readonly) NSArray<XTVariableDeclNode*>* ivars;
@property(nonatomic, readonly) NSArray<XTMethodDeclNode*>* methods;
/****************************************************************************\
|* Parent class name as written in source (`class Dog : Animal` →
|* `parentName = @"Animal"`). nil for a class with no explicit parent.
|* Set by the parser; resolved by sema into `parentClass` below.
\****************************************************************************/
@property(nonatomic, readonly, nullable) NSString* parentName;
/****************************************************************************\
|* PR9: names of protocols this class conforms to, in source order
|* (`class Sprite : Object, Drawable, Comparable` →
|* `protocolNames = @[@"Drawable", @"Comparable"]`). The first name
|* after `:` is the parent class (or Object) and lives in
|* `parentName`; every subsequent identifier lands here. Sema
|* verifies each protocol exists and that the class implements its
|* methods; codegen piggybacks on the PR8 vtable machinery by
|* allocating a virtual slot per protocol method and routing
|* protocol-typed call sites through it.
\****************************************************************************/
@property(nonatomic, readonly) NSArray<NSString*>* protocolNames;
/****************************************************************************\
|* protocol name → the impl method symbols for that protocol's methods, in the
|* protocol's DECLARATION order (`@""` for an unimplemented `optional`). Sema
|* fills it; the lowering emits it as this class's itable.
|*
|* Indexing by declaration order rather than by a global slot is the whole point:
|* the index depends on nothing but the protocol's own declaration, so every
|* module derives it identically and two independently built libraries compose.
\****************************************************************************/
@property(nonatomic, copy, nullable) NSDictionary<NSString*, NSArray<NSString*>*>* protocolImplSymbols;
/****************************************************************************\
|* Resolved parent class AST node. Wired up by sema during the
|* class pre-scan: looks up `parentName` in the class registry,
|* emits an error on unknown-parent / circular inheritance, and
|* leaves this nil on failure. Downstream passes should treat a nil
|* `parentClass` on a class with a non-nil `parentName` as "sema
|* already diagnosed; skip this chain".
\****************************************************************************/
@property(nonatomic, nullable, weak) XTClassDeclNode* parentClass;
/****************************************************************************\
|* Set by sema when it observes at least one `new ClassName(…)` site.
|* On banked-heap targets the codegen uses this to auto-place methods
|* with no explicit :main / :banked annotation in main RAM, so (self),Y
|* stores inside method bodies reach the heap bank instead of the
|* method's own bank.
\****************************************************************************/
@property(nonatomic) BOOL usedByNew;
/****************************************************************************\
|* Category / extension marker. `class Shape (Drawing) { … }` is a CATEGORY —
|* methods only, merged into the class of that name. `class Shape () { … }` is
|* an EXTENSION, which may also add ivars but only in the same artifact as the
|* class, which is ObjC's rule and for ObjC's reason: a class in a prebuilt
|* library has already had its size and layout baked into everything that
|* allocates it. nil = an ordinary class declaration.
|*   categoryName == nil   -> not a category
|*   categoryName == @""   -> extension, `()`
|*   otherwise             -> named category
|* private:docs/Design/separate-compilation.md §4.
\****************************************************************************/
@property(nonatomic, copy, nullable) NSString* categoryName;
@property(nonatomic, readonly) BOOL isCategory;
- (void)appendIvar:(XTVariableDeclNode*)ivar;
// Reconstructed from a binary xtc library's `.xtc.iface` (B1): every method is
// external (body lives in the .so), so the pre-scan registers each as an extern
// symbol (Class$method) rather than skipping it for want of a body.
@property(nonatomic) BOOL isExternal;
// W2 (wasm32 multi-module): the package namespace an external class's symbols
// import from — the library's name, stamped by the driver when the class came
// out of a `lib<X>.wasm`'s interface. Rides into the IR as pkg_<X> attributes
// on the Class$method shells and the Class$vtbl symbol, so the backend turns
// every reference into a wasm import in package "<X>". nil elsewhere.
@property(nonatomic, copy, nullable) NSString* importPackage;
/****************************************************************************\
|* The authoritative virtual-method-table layout for this class, stamped by
|* the semantic analyzer's `computeVirtualMethodTables`. The IR lowering
|* builds the class's vtable and `methodSlot` from these so the vtable's
|* slot N holds the impl that `resolvedVirtualSlot == N` dispatches to —
|* otherwise the lowering's declaration-order numbering disagrees with
|* sema's (override-roots-then-protocol-methods) numbering and dispatch
|* hits the wrong body.
|*
|* `vtableSlotSymbols[slot]` = the impl method-function symbol
|* (`<implClass>$<mangled>`) this class places at `slot`, or `@""` for a
|* slot this class doesn't fill. Its count is the program-wide
|* `totalVirtualSlots`. `vtableMethodSlots[methodName]` = the slot a virtual
|* call named `methodName` on this class dispatches through. Both nil when
|* the program has no virtual/protocol dispatch.
|*
|* `vtableSymbolSlots[symbol]` = the slot a call that resolved to the method
|* `symbol` (`<implClass>$<mangled>`, as seen from this class) dispatches
|* through. A name can have several overloads, each in its own slot, so the
|* name map cannot answer for a call; this one can.
\****************************************************************************/
@property(nonatomic, nullable) NSArray<NSString*>* vtableSlotSymbols;
@property(nonatomic, nullable) NSDictionary<NSString*, NSNumber*>* vtableMethodSlots;
@property(nonatomic, nullable) NSDictionary<NSString*, NSNumber*>* vtableSymbolSlots;
/****************************************************************************\
|* The CATEGORY-CHAIN table for this class (separate-compilation §4.2), also
|* stamped by `computeVirtualMethodTables`. A category on a class that came
|* from another module cannot take a vtable slot — that vtable is already
|* emitted, in a library we cannot relink — so its methods are numbered in a
|* chain slot space of their own and emitted as `<Class>$cat`, reached through
|* vtable header word 2.
|*
|* `categoryChainSymbols[k]` = the impl symbol this class places at chain slot
|* k (`@""` for one it doesn't fill); `categoryChainHost` = the extended class
|* that owns the numbering (the fallback table a dispatch site names when the
|* receiver's chain word is null); `categoryChainMethodSlots[name]` = the chain
|* slot a call named `name` on this class goes through. All nil unless this
|* class is, or descends from, an extended class.
\****************************************************************************/
@property(nonatomic, nullable) NSArray<NSString*>* categoryChainSymbols;
@property(nonatomic, copy, nullable) NSString* categoryChainHost;
@property(nonatomic, nullable) NSDictionary<NSString*, NSNumber*>* categoryChainMethodSlots;
/****************************************************************************\
|* §4.3b: the OWNER ANCHOR — the symbol name of this compilation's fallback
|* table for `categoryChainHost`, i.e. `<Host>$cat$<Cat1>[$<Cat2>…]` over the
|* sorted category names this compilation adds to the host. Entry [0] of every
|* table in the family holds its address (self-referential in the fallback
|* itself), and a dispatch site compares it to decide "is this receiver's
|* chain table MINE" — which is what lets two independent modules extend one
|* class without a registry to order them. Nil when categoryChainHost is.
\****************************************************************************/
@property(nonatomic, copy, nullable) NSString* categoryChainAnchor;
/****************************************************************************\
|* Create a class declaration node.
|* @param name       The class name.
|* @param parentName The parent class name (from `class X : Y`), or nil.
|* @param ivars      Array of instance-variable declarations.
|* @param methods    Array of method declarations.
|* @param location   Source location of the class keyword.
|* @return A new class declaration node.
\****************************************************************************/
- (instancetype)initWithName:(NSString*)name
                  parentName:(nullable NSString*)parentName
               protocolNames:(NSArray<NSString*>*)protocolNames
                       ivars:(NSArray<XTVariableDeclNode*>*)ivars
                     methods:(NSArray<XTMethodDeclNode*>*)methods
                    location:(XTSourceLocation*)location;
// Append an auto-synthesised method (e.g. the sema-time per-class
// `description()` body emitted by synthesizeClassDescriptions).
// Rebuilds the underlying methods array so the readonly `methods`
// property stays a snapshot; existing visitors / IR lowering pick
// the new method up unchanged.
- (void)appendSynthesisedMethod:(XTMethodDeclNode*)method;
// Add a protocol conformance (e.g. auto-applied `UIDesignable`). No-op if
// already present, so hand-written `<UIDesignable>` and the auto-apply agree.
- (void)appendProtocolConformance:(NSString*)protocolName;
@end

/****************************************************************************\
|* XTProtocolDeclNode — PR9 protocol declaration. Declares a named
|* interface: a set of method signatures with no bodies. Conforming
|* classes (via `class X [: Parent] <Proto>`) must supply an
|* implementation with a matching signature for every declared
|* method. Dispatch through a `Proto@` pointer routes through the
|* PR8 vtable machinery — one virtual slot per protocol method,
|* shared across every conforming class's impl.
\****************************************************************************/
@interface XTProtocolDeclNode : XTASTNode
@property(nonatomic, readonly) NSString* protocolName;
@property(nonatomic, readonly) NSArray<XTMethodDeclNode*>* methods;
- (instancetype)initWithName:(NSString*)name
                     methods:(NSArray<XTMethodDeclNode*>*)methods
                    location:(XTSourceLocation*)location;
@end

NS_ASSUME_NONNULL_END
